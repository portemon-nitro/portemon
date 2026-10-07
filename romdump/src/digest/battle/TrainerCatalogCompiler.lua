-- Projection of native trainer records into ordered semantic templates.
-- Headers follow the TrainerData layout in include/trainer_data.h and party
-- members follow the four TRPOKE shapes selected by the TRTYPE_* moves/item
-- bits in include/constants/trainers.h
-- (pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981): all four
-- variants decode through one normalized template schema preserving species
-- and form identities, difficulty, level, held items, explicit custom moves,
-- gender/ability overrides, and capsule facts. Default movesets stay
-- unbuilt (nil marks native initial-learnset construction); the rival name
-- stays a save indirection while other names reference the message bank;
-- AI flags become named passes without inventing policy. No LOVE objects or
-- filesystem writes; callers publish through the battle-data cache paths.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local MonSources = require("romdump.src.config.MonSources")
local ItemSources = require("romdump.src.config.ItemSources")
local BattleSources = require("romdump.src.config.BattleSources")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")

---@class TrainerCatalogCompiler
local TrainerCatalogCompiler = {}

local SOURCES = BattleSources.trainerSources
local SUPPORTED_VERSIONS = { heartgold = true, soulsilver = true }

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

-- Decode one 20-byte TRDATA header into normalized source values.
---@param trainerIndex integer
---@param data string
---@return table<string, unknown>|nil, Errors.Error|nil
function TrainerCatalogCompiler.decodeHeader(trainerIndex, data)
  if #data ~= SOURCES.recordSize then
    return nil,
      Errors.new(
        "TRAINER_HEADER_BAD_SIZE",
        "trainer " .. trainerIndex .. " header is " .. #data .. " bytes, expected " .. SOURCES.recordSize,
        { trainer = trainerIndex, size = #data, expected = SOURCES.recordSize }
      )
  end
  local reader = BinaryReader.new(data, "trainer " .. trainerIndex)
  local items = {}
  for slot = 0, 3 do
    items[#items + 1] = reader:u16le(4 + slot * 2)
  end
  return {
    trainerType = reader:u8(0),
    trainerClass = reader:u8(1),
    memberCount = reader:u8(3),
    items = items,
    aiFlags = reader:u32le(12),
    doubleBattle = reader:u32le(16),
  }
end

---@param trainerIndex integer
---@param itemId integer
---@return string|nil, Errors.Error|nil
local function resolveItem(trainerIndex, itemId)
  local key = ItemSources.itemKeys[itemId]
  if key == nil then
    return nil,
      Errors.new("TRAINER_BAD_ITEM", "trainer " .. trainerIndex .. " references unknown item " .. itemId, {
        trainer = trainerIndex,
        item = itemId,
      })
  end
  return key
end

-- Decode one party member of the given TRTYPE variant. Members carry
-- difficulty, gender/ability overrides, level, the packed species word, an
-- optional held item, optional custom moves, and capsule facts. Zero move
-- slots are empty, never a move; unknown species, item, or move references
-- fail naming the trainer.
---@param trainerIndex integer
---@param trainerType integer
---@param member string
---@return table<string, unknown>|nil, Errors.Error|nil
function TrainerCatalogCompiler.decodeMember(trainerIndex, trainerType, member)
  local expected = SOURCES.memberSizes[trainerType]
  if expected == nil then
    return nil,
      Errors.new("TRAINER_BAD_TYPE", "trainer " .. trainerIndex .. " selects unknown party variant " .. trainerType, {
        trainer = trainerIndex,
        trainerType = trainerType,
      })
  end
  if #member ~= expected then
    return nil,
      Errors.new(
        "TRAINER_MEMBER_BAD_SIZE",
        "trainer " .. trainerIndex .. " member is " .. #member .. " bytes, expected " .. expected,
        { trainer = trainerIndex, size = #member, expected = expected }
      )
  end
  local reader = BinaryReader.new(member, "trainer " .. trainerIndex .. " member")
  local difficulty = reader:u8(0)
  local genderAbility = reader:u8(1)
  local level = reader:u16le(2)
  local speciesWord = reader:u16le(4)
  local speciesId = speciesWord % 1024
  local form = math.floor(speciesWord / 1024)
  local speciesKey = MonSources.speciesKeys[speciesId]
  if speciesKey == nil then
    return nil,
      Errors.new("TRAINER_BAD_SPECIES", "trainer " .. trainerIndex .. " references unknown species " .. speciesId, {
        trainer = trainerIndex,
        species = speciesId,
      })
  end
  local cursor = 6
  local heldItem = "NONE"
  if trainerType == 2 or trainerType == 3 then
    local itemId = reader:u16le(cursor)
    cursor = cursor + 2
    local key, itemErr = resolveItem(trainerIndex, itemId)
    if key == nil then
      return nil, itemErr
    end
    heldItem = key
  end
  local moves = nil
  if trainerType == 1 or trainerType == 3 then
    local custom = {}
    for _ = 1, 4 do
      local moveId = reader:u16le(cursor)
      cursor = cursor + 2
      if moveId ~= 0 then
        local moveKey = MonSources.moveKeys[moveId]
        if moveKey == nil then
          return nil,
            Errors.new("TRAINER_BAD_MOVE", "trainer " .. trainerIndex .. " references unknown move " .. moveId, {
              trainer = trainerIndex,
              move = moveId,
            })
        end
        custom[#custom + 1] = moveKey
      end
    end
    moves = custom
  end
  local capsule = reader:u16le(cursor)
  local genderOverride = genderAbility % 16
  local abilityOverride = math.floor(genderAbility / 16) % 16
  return {
    species = speciesKey,
    form = form,
    level = level,
    difficulty = difficulty,
    heldItem = heldItem,
    moves = moves,
    identityPolicy = "native_pid",
    identityParams = {
      genderOverride = genderOverride,
      abilityOverride = abilityOverride,
      capsule = capsule,
    },
  }
end

-- Project AI flags into named selection passes. Each set bit names its own
-- pass; the doubles bit instead drives the doubles fact. No policy is
-- invented: pass resolution belongs to the battle consumer.
---@param aiFlags integer
---@return string[]
local function projectAiPasses(aiFlags)
  local passes = {}
  local bit = 0
  local remaining = aiFlags
  while remaining ~= 0 do
    if remaining % 2 == 1 and bit ~= SOURCES.aiDoublesBit then
      passes[#passes + 1] = "ai_pass_" .. bit
    end
    remaining = math.floor(remaining / 2)
    bit = bit + 1
  end
  return passes
end

-- Compile synthetic native input into the trainer catalog. The input carries
-- one header plus its concatenated party members per trainer index with its
-- supported game. Malformed headers, truncated members, and unknown
-- references fail before anything is published.
---@param nativeInput { versionId: string, trainers: table<integer, { data: string, members: string }> }
---@return table<string, unknown>|nil, Errors.Error|nil
function TrainerCatalogCompiler.compile(nativeInput)
  local versionId = nativeInput.versionId
  if SUPPORTED_VERSIONS[versionId] ~= true then
    return nil,
      Errors.new("TRAINER_VERSION_UNSUPPORTED", "trainer data has no source contract for " .. tostring(versionId), {
        versionId = versionId,
      })
  end
  if type(nativeInput.trainers) ~= "table" then
    return nil, Errors.new("TRAINER_INPUT_INVALID", "trainer input carries no trainer records", {})
  end
  local trainers = {}
  local ok, result = pcall(function()
    for trainerIndex, record in pairs(nativeInput.trainers) do
      if type(trainerIndex) ~= "number" or trainerIndex % 1 ~= 0 then
        error(Errors.new("TRAINER_INPUT_INVALID", "trainer identities must be integers", {}), 0)
      end
      if type(record) ~= "table" or type(record.data) ~= "string" or type(record.members) ~= "string" then
        error(
          Errors.new("TRAINER_INPUT_INVALID", "trainer " .. trainerIndex .. " carries no header and members", {
            trainer = trainerIndex,
          }),
          0
        )
      end
      local header = must(TrainerCatalogCompiler.decodeHeader(trainerIndex, record.data))
      local memberSize = must(
        SOURCES.memberSizes[header.trainerType],
        Errors.new(
          "TRAINER_BAD_TYPE",
          "trainer " .. trainerIndex .. " selects unknown party variant " .. header.trainerType,
          { trainer = trainerIndex }
        )
      )
      local expectedBytes = header.memberCount * memberSize
      -- Item-variant parties may trail NARC alignment packing the native
      -- reader never indexes; anything else is a truncated member.
      local alignedBytes = expectedBytes
        + ((SOURCES.memberAlignment - expectedBytes % SOURCES.memberAlignment) % SOURCES.memberAlignment)
      if #record.members ~= expectedBytes and #record.members ~= alignedBytes then
        error(
          Errors.new(
            "TRAINER_MEMBER_BAD_SIZE",
            "trainer " .. trainerIndex .. " party is " .. #record.members .. " bytes, expected " .. expectedBytes,
            { trainer = trainerIndex, size = #record.members, expected = expectedBytes }
          ),
          0
        )
      end
      local party = {}
      for slot = 0, header.memberCount - 1 do
        local bytes = record.members:sub(slot * memberSize + 1, (slot + 1) * memberSize)
        party[#party + 1] = must(TrainerCatalogCompiler.decodeMember(trainerIndex, header.trainerType, bytes))
      end
      -- Only nonzero source identities survive: empty positions
      -- compact away in source order because the battle initializer
      -- discards them before item selection.
      local items = {}
      for _, itemId in ipairs(header.items) do
        if itemId ~= 0 then
          items[#items + 1] = must(resolveItem(trainerIndex, itemId))
        end
      end
      local nameReference
      if header.trainerClass == SOURCES.rivalClass then
        nameReference = { rival = true }
      else
        nameReference = { trainerIndex = trainerIndex }
      end
      -- The prize rate comes from the pinned class payout table: a class
      -- outside that table fails here instead of borrowing another
      -- class's rate.
      local classRate = BattleSources.prizeMoneyRates[header.trainerClass]
      if classRate == nil then
        error(
          Errors.new(
            "TRAINER_BAD_CLASS",
            "trainer " .. trainerIndex .. " names class " .. header.trainerClass .. " outside the pinned payout table",
            {
              trainer = trainerIndex,
              trainerClass = header.trainerClass,
            }
          ),
          0
        )
      end
      trainers[trainerIndex] = {
        trainerClass = header.trainerClass,
        nameReference = nameReference,
        party = party,
        aiPasses = projectAiPasses(header.aiFlags),
        doubleBattle = header.doubleBattle ~= 0,
        items = items,
        prizeMoney = { trainerClass = header.trainerClass, classRate = classRate },
        messageSelectors = { intro = 0, lose = 1, after = 2 },
      }
    end
    local compiled = {
      schema = BattleDataCache.TRAINER_SCHEMA,
      version = { id = versionId },
      trainers = trainers,
    }
    must(BattleDataSchema.assertTrainerCatalog(compiled))
    return compiled
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

-- Compile the trainer catalog from a supported dump. Archive members resolve
-- by trainer index through the existing source inventory; member 0 and empty
-- parties are sentinels (TRAINER_NONE), never trainers.
---@param romFs RomFs
---@param opts { versionId: string|nil }|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function TrainerCatalogCompiler.compileFromDump(romFs, opts)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  if SUPPORTED_VERSIONS[versionId] ~= true then
    return nil,
      Errors.new("TRAINER_VERSION_UNSUPPORTED", "trainer data has no source contract for " .. tostring(versionId), {
        versionId = versionId,
      })
  end
  local headers, headersErr = romFs:openNarc("trainer_data")
  if headers == nil then
    return nil, headersErr
  end
  local parties, partiesErr = romFs:openNarc("trainer_parties")
  if parties == nil then
    return nil, partiesErr
  end
  local ok, result = pcall(function()
    local records = {}
    local count = headers:memberCount()
    for trainerIndex = 0, count - 1 do
      local data = must(headers:readMember(trainerIndex))
      local header = must(TrainerCatalogCompiler.decodeHeader(trainerIndex, data))
      if header.memberCount ~= 0 then
        local members = must(parties:readMember(trainerIndex))
        records[trainerIndex] = { data = data, members = members }
      end
    end
    return must(TrainerCatalogCompiler.compile({ versionId = versionId, trainers = records }))
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

return TrainerCatalogCompiler
