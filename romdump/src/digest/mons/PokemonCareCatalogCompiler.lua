-- Projection of the source breeding and move-tutor tables into the semantic
-- care catalog: the PMS egg-species table (ReadFromPersonalPmsNarc), the
-- personal egg-move list (LoadEggMoves), the source incense pairs, and the
-- Frontier move-tutor inventory with its per-species compatibility bit fields
-- (src/field/scrcmd_move_tutor.c). Native species, move, and item identities
-- resolve through the shared producer catalogs; no offsets, member indexes or
-- bit fields survive into the payload. Publish through the care cache paths.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local ItemSources = require("romdump.src.config.ItemSources")
local MonSources = require("romdump.src.config.MonSources")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareSources = require("romdump.src.config.PokemonCareSources")
local UiAssetHelpers = require("romdump.src.digest.ui.UiAssetHelpers")

---@class PokemonCareCatalogCompiler
local PokemonCareCatalogCompiler = {}

local EGG_SPECIES = PokemonCareSources.eggSpeciesSource
local EGG_MOVES = PokemonCareSources.eggMoveSource
local TRADE_TABLE = PokemonCareSources.tradeTable
local TRADE_MESSAGES = PokemonCareSources.tradeMessages
local TUTOR_MOVES = PokemonCareSources.tutorMoves
local TUTOR_LEARNSETS = PokemonCareSources.tutorLearnsets

local SPECIES_KEYS = {}
for _, key in pairs(MonSources.speciesKeys) do
  SPECIES_KEYS[key] = true
end
local ITEM_KEYS = {}
for _, key in pairs(ItemSources.itemKeys) do
  ITEM_KEYS[key] = true
end
local MOVE_KEYS = {}
for _, key in pairs(MonSources.moveKeys) do
  MOVE_KEYS[key] = true
end
local TUTOR_NPCS = {}
for _, name in pairs(PokemonCareSources.tutorNpcNames) do
  TUTOR_NPCS[name] = true
end

---@param code string
---@param message string
---@param context table<string, unknown>
---@return Errors.Error
local function sourceError(code, message, context)
  return Errors.new(code, message, context)
end

---@param speciesId integer
---@param context table<string, unknown>
---@return string|nil, Errors.Error|nil
local function speciesKey(speciesId, context)
  local key = MonSources.speciesKeys[speciesId]
  if key == nil then
    return nil, sourceError("POKEMON_CARE_BAD_SPECIES", "unknown species identity " .. tostring(speciesId), context)
  end
  return key
end

-- The shared UI producer helpers report through a message/context callback
-- rather than this compiler's code-first signature.
---@param message string
---@param context table<string, unknown>?
local function uiSourceError(message, context)
  sourceError("POKEMON_CARE_SOURCE_INVALID", message, context or {})
end

---@param archive table<string, unknown>
---@param memberId integer
---@param role string
---@param dependencies table<string, unknown>[]
---@param archiveLabel string
---@return string
local function readMember(archive, memberId, role, dependencies, archiveLabel)
  return UiAssetHelpers.readMember(archive, memberId, role, dependencies, archiveLabel, uiSourceError)
end

-- ReadFromPersonalPmsNarc: one u16 per species at species * 2.
---@param romFs table<string, unknown>
---@return { [string]: string }|nil, Errors.Error|nil
local function readEggSpeciesTable(romFs)
  local bytes, readErr = romFs:readSourcePath(EGG_SPECIES.path)
  if bytes == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the personal egg-species table is unavailable", {
        path = EGG_SPECIES.path,
        cause = readErr,
      })
  end
  local reader = BinaryReader.new(bytes, EGG_SPECIES.path)
  local count = #bytes / EGG_SPECIES.entrySize
  if count <= EGG_SPECIES.lastSpecies then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_TRUNCATED", "the personal egg-species table ends before its last species", {
        path = EGG_SPECIES.path,
        entries = count,
      })
  end
  local eggSpecies = {}
  for speciesId = EGG_SPECIES.firstSpecies, EGG_SPECIES.lastSpecies do
    local motherKey, keyErr = speciesKey(speciesId, { table = EGG_SPECIES.path, species = speciesId })
    assert(motherKey ~= nil, keyErr)
    local eggId = reader:u16le(speciesId * EGG_SPECIES.entrySize)
    local eggKey, eggErr = speciesKey(eggId, { table = EGG_SPECIES.path, species = speciesId, eggSpecies = eggId })
    if eggKey == nil then
      return nil, eggErr
    end
    eggSpecies[motherKey] = eggKey
  end
  return eggSpecies
end

-- LoadEggMoves: headers encode `species + headerBase`; a block runs until the
-- next header, bounded by the source's own block width.
---@param member string
---@return { [string]: string[] }|nil, Errors.Error|nil
local function decodeEggMoves(member)
  if #member % 2 ~= 0 then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_TRUNCATED", "the egg-move list has a halfword remainder", {
        path = EGG_MOVES.path,
        size = #member,
      })
  end
  local reader = BinaryReader.new(member, EGG_MOVES.path)
  local count = #member / 2
  local eggMoves = {}
  local index = 0
  -- LoadEggMoves scans at most scanLimit entries for a species header, so a
  -- trailing entry past that bound never opens a block.
  local scanLimit = math.min(count, EGG_MOVES.scanLimit)
  while index < scanLimit do
    local header = reader:u16le(index * 2)
    if header <= EGG_MOVES.headerBase then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the egg-move list starts without a species header", {
          path = EGG_MOVES.path,
          index = index,
        })
    end
    local speciesId = header - EGG_MOVES.headerBase
    local key, keyErr = speciesKey(speciesId, { table = EGG_MOVES.path, index = index, species = speciesId })
    if key == nil then
      return nil, keyErr
    end
    if eggMoves[key] ~= nil then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the egg-move list repeats a species block", {
          path = EGG_MOVES.path,
          index = index,
          species = key,
        })
    end
    local moves = {}
    index = index + 1
    while index < count and #moves < EGG_MOVES.maxMoves do
      local moveId = reader:u16le(index * 2)
      if moveId > EGG_MOVES.headerBase then
        break
      end
      local moveKey = MonSources.moveKeys[moveId]
      if moveKey == nil then
        return nil,
          sourceError("POKEMON_CARE_BAD_MOVE", "the egg-move list references an unknown move", {
            path = EGG_MOVES.path,
            index = index,
            move = moveId,
          })
      end
      moves[#moves + 1] = moveKey
      index = index + 1
    end
    if #moves == 0 then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "an egg-move block names no move", {
          path = EGG_MOVES.path,
          species = key,
        })
    end
    if index < count and #moves == EGG_MOVES.maxMoves and reader:u16le(index * 2) <= EGG_MOVES.headerBase then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "an egg-move block exceeds the source block width", {
          path = EGG_MOVES.path,
          species = key,
          index = index,
        })
    end
    eggMoves[key] = moves
  end
  return eggMoves
end

---@param romFs table<string, unknown>
---@return { [string]: string[] }|nil, Errors.Error|nil
local function readEggMoves(romFs)
  local archive, openErr = romFs:openNarc(EGG_MOVES.alias)
  if archive == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the personal egg-move archive is unavailable", {
        archive = EGG_MOVES.alias,
        cause = openErr,
      })
  end
  local member, memberErr = archive:readMember(EGG_MOVES.memberId)
  if member == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the egg-move archive has no list member", {
        archive = EGG_MOVES.alias,
        memberId = EGG_MOVES.memberId,
        cause = memberErr,
      })
  end
  return decodeEggMoves(member)
end

---@return table<string, unknown>[]|nil, Errors.Error|nil
local function checkIncenseRows()
  local rows = {}
  for index, row in ipairs(PokemonCareSources.incenseRows) do
    for _, field in ipairs({ "baby", "parent" }) do
      if not SPECIES_KEYS[row[field]] then
        return nil,
          sourceError("POKEMON_CARE_BAD_SPECIES", "the incense table names an unknown species", {
            row = index,
            species = row[field],
          })
      end
    end
    if not ITEM_KEYS[row.item] then
      return nil,
        sourceError("POKEMON_CARE_BAD_ITEM", "the incense table names an unknown item", {
          row = index,
          item = row.item,
        })
    end
    rows[#rows + 1] = { baby = row.baby, item = row.item, parent = row.parent }
  end
  assert(#rows > 0, "the source incense table carries its rows")
  return rows
end

-- The source NPC trade table (_CreateTradeMon, src/npc_trade.c): one fixed
-- member per NpcTradeNum holding 21 ints -- offered species, the six
-- individual values, the unused ability, the OT id, the five contest values,
-- the fixed personality, the held item, the OT gender, the unused sheen, the
-- language, the requested species and the unused flag. The nickname and the
-- OT name are message bank 200 entries at the trade's own index and at
-- NPC_TRADE_OT_NUM(tradeNum). The source's unused ability and sheen columns are
-- deliberately not published: ordinary creation derives the ability and the
-- sheen stays zero.
---@param tokens table<string, unknown>[]
---@param role string
---@param bankId integer
---@param index integer
---@return string|nil, Errors.Error|nil
local function tradeName(tokens, role, bankId, index)
  local pieces = {}
  for _, token in ipairs(tokens) do
    local typed = token --[[@as table<string, unknown>]]
    if typed.kind == "glyph" then
      local text = typed.text
      if type(text) ~= "string" then
        return nil,
          sourceError("POKEMON_CARE_SOURCE_INVALID", "the trade name glyph carries no text", {
            role = role,
            bank = bankId,
            index = index,
          })
      end
      assert(type(text) == "string")
      pieces[#pieces + 1] = text
    elseif typed.kind == "eos" then
      break
    else
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the trade name carries an unsupported token", {
          role = role,
          bank = bankId,
          index = index,
          kind = typed.kind,
        })
    end
  end
  local name = table.concat(pieces)
  if name:match("^%s*$") ~= nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_INVALID", "the trade name prints nothing", {
        role = role,
        bank = bankId,
        index = index,
      })
  end
  return name
end

---@param romFs table<string, unknown>
---@param dependencies table<string, unknown>[]
---@return table<string, unknown>[]|nil, Errors.Error|nil
local function readTrades(romFs, dependencies)
  local archive, openErr = romFs:openNarc(TRADE_TABLE.alias)
  if archive == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the NPC trade archive is unavailable", {
        archive = TRADE_TABLE.alias,
        cause = openErr,
      })
  end
  assert(archive ~= nil, "missing trade archives fail above")
  local messagesArchive, messagesErr = romFs:openNarc(TRADE_MESSAGES.alias)
  if messagesArchive == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the trade message archive is unavailable", {
        archive = TRADE_MESSAGES.alias,
        cause = messagesErr,
      })
  end
  assert(messagesArchive ~= nil, "missing message archives fail above")
  local bank = UiAssetHelpers.readMessageBank(
    messagesArchive,
    TRADE_MESSAGES.memberId,
    "trade-names",
    dependencies,
    "trade",
    uiSourceError
  )
  local trades = {}
  for tradeId = 0, TRADE_TABLE.count - 1 do
    local role = "trade-" .. tradeId
    local member = readMember(archive, tradeId, role, dependencies, "trade-table")
    if #member < TRADE_TABLE.entrySize then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_TRUNCATED", "the trade record is shorter than its source layout", {
          table = TRADE_TABLE.path,
          memberId = tradeId,
          size = #member,
        })
    end
    local reader = BinaryReader.new(member, TRADE_TABLE.path .. ":" .. tradeId)
    ---@param index integer zero-based int column
    ---@return integer
    local function column(index)
      return reader:u32le(index * 4)
    end
    local context = { table = TRADE_TABLE.path, memberId = tradeId }
    local offered, offeredErr = speciesKey(column(0), context)
    if offered == nil then
      return nil, offeredErr
    end
    local requested, requestedErr = speciesKey(column(19), context)
    if requested == nil then
      return nil, requestedErr
    end
    local heldItem = ItemSources.itemKeys[column(15)]
    if heldItem == nil then
      return nil,
        sourceError("POKEMON_CARE_BAD_ITEM", "the trade record names an unknown held item", {
          table = TRADE_TABLE.path,
          memberId = tradeId,
          item = column(15),
        })
    end
    local language = PokemonCareSources.tradeLanguages[column(18)]
    if language == nil then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the trade record names an unknown language", {
          table = TRADE_TABLE.path,
          memberId = tradeId,
          language = column(18),
        })
    end
    local otGender = column(16)
    if otGender ~= 0 and otGender ~= 1 then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the trade record names an unknown OT gender", {
          table = TRADE_TABLE.path,
          memberId = tradeId,
          gender = otGender,
        })
    end
    local nickname, nicknameErr = tradeName(
      UiAssetHelpers.messageTokens(bank, TRADE_MESSAGES.memberId, tradeId, role .. "-nickname", "trade", uiSourceError),
      role .. "-nickname",
      TRADE_MESSAGES.memberId,
      tradeId
    )
    if nickname == nil then
      return nil, nicknameErr
    end
    local otIndex = tradeId + TRADE_MESSAGES.otNameOffset
    local otName, otNameErr = tradeName(
      UiAssetHelpers.messageTokens(bank, TRADE_MESSAGES.memberId, otIndex, role .. "-ot-name", "trade", uiSourceError),
      role .. "-ot-name",
      TRADE_MESSAGES.memberId,
      otIndex
    )
    if otName == nil then
      return nil, otNameErr
    end
    trades[#trades + 1] = {
      offeredSpecies = offered,
      requestedSpecies = requested,
      personality = column(14),
      otId = column(8),
      ivs = {
        hp = column(1),
        attack = column(2),
        defense = column(3),
        speed = column(4),
        specialAttack = column(5),
        specialDefense = column(6),
      },
      contest = {
        cool = column(9),
        beauty = column(10),
        cute = column(11),
        smart = column(12),
        tough = column(13),
      },
      heldItem = heldItem,
      otGender = otGender,
      language = language,
      nickname = nickname,
      otName = otName,
      unusedFlag = column(20),
    }
  end
  if #trades ~= TRADE_TABLE.count then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_INVALID", "the trade archive does not carry every source record", {
        table = TRADE_TABLE.path,
        count = #trades,
      })
  end
  assert(#trades > 0, "the trade table carries its records")
  return trades
end

-- sTutorMoves in source order: the catalog publishes the inventory itself, so
-- the runtime never derives an offer, a price, or a page from a second table.
---@return table<string, unknown>[]|nil, Errors.Error|nil
local function checkTutorMoves()
  local rows = {}
  for index, row in ipairs(TUTOR_MOVES) do
    if not MOVE_KEYS[row.move] then
      return nil,
        sourceError("POKEMON_CARE_BAD_MOVE", "the move tutor inventory names an unknown move", {
          row = index,
          move = row.move,
        })
    end
    if type(row.cost) ~= "number" or row.cost % 1 ~= 0 or row.cost < 0 then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the move tutor inventory names an invalid price", {
          row = index,
          move = row.move,
          cost = row.cost,
        })
    end
    if TUTOR_NPCS[row.npc] ~= true then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the move tutor inventory names an unknown tutor", {
          row = index,
          move = row.move,
          npc = row.npc,
        })
    end
    rows[#rows + 1] = { move = row.move, cost = row.cost, npc = row.npc }
  end
  assert(#rows > 0, "the source tutor inventory carries its rows")
  return rows
end

-- GetMoveTutorLearnsetIndex: the compatibility file is indexed by species
-- identity with SPECIES_EGG and SPECIES_BAD_EGG removed, so the form
-- pseudo-species that follow them shift up by the two missing rows.
---@param member integer source species identity of the tutor row
---@return integer zero-based file row
local function learnsetRow(member)
  local baseRows = TUTOR_LEARNSETS.lastSpecies - TUTOR_LEARNSETS.firstSpecies + 1
  if member <= TUTOR_LEARNSETS.lastSpecies then
    return member - TUTOR_LEARNSETS.firstSpecies
  end
  return baseRows + member - TUTOR_LEARNSETS.badEggSpecies - 1
end

-- GetLearnableTutorMoves reads bit j of the row to decide whether inventory row
-- j is learnable. The payload names the learnable moves in inventory order, so
-- the raw bit field stays producer-side.
---@param bytes string
---@param offset integer
---@param inventory table<string, unknown>[]
---@return string[]
local function decodeLearnset(bytes, offset, inventory)
  local moves = {}
  for index = 0, #inventory - 1 do
    local byte = string.byte(bytes, offset + math.floor(index / 8) + 1)
    assert(type(byte) == "number", "the tutor row carries its eight bytes")
    if math.floor(byte / 2 ^ (index % 8)) % 2 == 1 then
      moves[#moves + 1] = inventory[index + 1].move
    end
  end
  return moves
end

-- One row per species the player can own, with a form-specific row only where
-- the source resolves a distinct compatibility member. Every other form reads
-- its species' own row (GetMoveTutorLearnsetIndex leaves the index at the
-- species identity), so the payload stores the base list once.
---@param bytes string
---@param inventory table<string, unknown>[]
---@return { [string]: string[][] }|nil, Errors.Error|nil
local function decodeLearnsets(bytes, inventory)
  local expected = (TUTOR_LEARNSETS.speciesCount - 2) * TUTOR_LEARNSETS.entrySize
  if #bytes ~= expected then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_TRUNCATED", "the move tutor table is not one row per species", {
        path = TUTOR_LEARNSETS.path,
        size = #bytes,
        expected = expected,
      })
  end
  local learnsets = {}
  for speciesId = TUTOR_LEARNSETS.firstSpecies, TUTOR_LEARNSETS.lastSpecies do
    local key, keyErr = speciesKey(speciesId, { table = TUTOR_LEARNSETS.path, species = speciesId })
    if key == nil then
      return nil, keyErr
    end
    local forms = {}
    local base
    for _, form in ipairs(MonSources.runtimeForms(speciesId)) do
      local member = MonSources.resolvePersonalMember(speciesId, form)
      assert(
        member >= TUTOR_LEARNSETS.firstSpecies and member <= TUTOR_LEARNSETS.lastFormSpecies,
        "the tutor row member is a real species identity"
      )
      local moves = decodeLearnset(bytes, learnsetRow(member) * TUTOR_LEARNSETS.entrySize, inventory)
      if form == 0 then
        base = moves
        forms[1] = moves
      elseif member ~= speciesId then
        forms[form + 1] = moves
      end
    end
    assert(base ~= nil, "every species carries its base tutor row")
    for index = 1, #forms do
      assert(forms[index] ~= nil, "the tutor form lists stay dense")
    end
    learnsets[key] = forms
  end
  return learnsets
end

-- Compile the care catalog from one cartridge view.
---@param romFs table<string, unknown>
---@return table<string, unknown>|nil, Errors.Error|nil
function PokemonCareCatalogCompiler.compile(romFs)
  assert(type(romFs) == "table", "care compilation requires a source reader")
  local eggSpecies, speciesErr = readEggSpeciesTable(romFs)
  if eggSpecies == nil then
    return nil, speciesErr
  end
  local eggMoves, movesErr = readEggMoves(romFs)
  if eggMoves == nil then
    return nil, movesErr
  end
  local incense, incenseErr = checkIncenseRows()
  if incense == nil then
    return nil, incenseErr
  end
  local trades, tradesErr = readTrades(romFs, {})
  if trades == nil then
    return nil, tradesErr
  end
  local tutorMoves, tutorMovesErr = checkTutorMoves()
  if tutorMoves == nil then
    return nil, tutorMovesErr
  end
  local tutorBytes, tutorReadErr = romFs:readSourcePath(TUTOR_LEARNSETS.path)
  if tutorBytes == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the move tutor compatibility table is unavailable", {
        path = TUTOR_LEARNSETS.path,
        cause = tutorReadErr,
      })
  end
  local tutorLearnsets, tutorLearnsetsErr = decodeLearnsets(tutorBytes, tutorMoves)
  if tutorLearnsets == nil then
    return nil, tutorLearnsetsErr
  end
  local catalog = {
    schema = PokemonCareAssetSchema.CATALOG_SCHEMA,
    eggSpecies = eggSpecies,
    eggMoves = eggMoves,
    incense = incense,
    trades = trades,
    tutors = { moves = tutorMoves, learnsets = tutorLearnsets },
  }
  local valid, validationErr = pcall(PokemonCareAssetSchema.assertCatalog, catalog)
  if not valid then
    return nil,
      sourceError("POKEMON_CARE_CATALOG_INVALID", "the compiled care catalog is invalid", {
        cause = tostring(validationErr),
      })
  end
  return catalog
end

return PokemonCareCatalogCompiler
