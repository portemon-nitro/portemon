-- Compiles the HGSS follower interaction tables in overlay_02_02248728.s and
-- the reaction selector table in overlay_01_02203A18.s at the pinned source.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")
local InteractionCache = require("libs.assets.src.field.FollowerInteractionCache")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local Hashing = require("romdump.src.digest.Hashing")
local Sources = require("romdump.src.config.FollowerInteractionSources")
local FieldEffects = require("romdump.src.config.FieldEffects")
local FieldEffectPatternAnimation = require("romdump.src.digest.field.FieldEffectPatternAnimation")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local charmap = require("romdump.src.reference.hgss.charmap")

local Compiler = {}
local SOUND_EFFECT_END = 2378

local function signed(value, modulus)
  return value >= modulus / 2 and value - modulus or value
end

local function readMember(narc, memberId, label)
  local bytes, err = narc:readMember(memberId)
  if not bytes then
    error(err)
  end
  assert(type(bytes) == "string", label .. " member must be bytes")
  return bytes
end

local function requireSize(bytes, expected, label, memberId)
  if #bytes ~= expected then
    Errors.raise("FOLLOWER_INTERACTION_SOURCE_SIZE", label .. " member has an unexpected size", {
      memberId = memberId,
      expected = expected,
      actual = #bytes,
    })
  end
end

local function decodeRule(bytes)
  -- Matcher reads are in ov02_0224F108; the criteria helpers are in
  -- ov02_0224F4BC, ov02_0224F5FC, ov02_0224F644, ov02_0224F64C,
  -- ov02_0224F6AC, ov02_0224F728, and ov02_0224F76C.
  local reader = BinaryReader.new(bytes, "follower-interaction-rule")
  assert(reader:length() == Sources.RULE_SIZE, "rule decoder requires one complete source row")
  local selector = reader:u16le(0x0A)
  local requiredFlagId = reader:u16le(0x12)
  local mapIdValue = reader:u16le(0x0C)
  local metatileBehaviorId = reader:u16le(0x0E)
  local rule = {
    interactionId = math.floor(selector / 64),
    percentage = reader:u8(0x11),
    requiredFlagId = requiredFlagId ~= 0 and requiredFlagId or nil,
    criteria = {
      hpClass = reader:u8(0),
      moodClass = reader:u8(1) % 16,
      friendshipClass = math.floor(reader:u8(1) / 16),
      natureClass = reader:u8(2) % 8,
      genderClass = math.floor(reader:u8(2) / 8) % 4,
      statusClass = math.floor(reader:u8(2) / 32),
      heldItemClass = reader:u8(3) % 32,
      typeClass = reader:u8(4) % 32,
      pokeathlonClass = math.floor(reader:u8(4) / 32),
      encounterClass = reader:u8(5),
      mapClass = reader:u8(6),
      leafClass = reader:u8(7),
      weatherClass = reader:u8(8) % 8,
      facingClass = math.floor(reader:u8(9) / 32),
      nearbyObjectClass = selector % 8,
      timeClass = math.floor(selector / 8) % 8,
      levelClass = math.floor(reader:u8(0x10) / 2) % 4,
      specialSpriteClass = math.floor(reader:u8(0x10) / 8) % 4,
      hiddenItemClass = math.floor(reader:u8(0x10) / 32),
    },
  }
  if mapIdValue ~= 0 then
    rule.criteria.mapId = mapIdValue - 1
  end
  if metatileBehaviorId ~= 0 then
    rule.criteria.metatileBehaviorId = metatileBehaviorId
  end
  return rule
end

local function decodeProgramMember(bytes)
  -- Task_FollowMonInteract and ov02_0224F880 consume these DF records.
  requireSize(bytes, Sources.PROGRAM_SIZE, "program", -1)
  local reader = BinaryReader.new(bytes, "follower-interaction-program")
  local steps = {}
  for index = 0, 4 do
    local offset = index * 8
    local motionId = reader:u16le(offset)
    if motionId == 0xFFFF then
      break
    end
    local reactionId = reader:u8(offset + 6)
    if reactionId > 14 then
      Errors.raise("FOLLOWER_INTERACTION_SELECTOR_INVALID", "program reaction selector is out of range", {
        selector = reactionId,
        step = index,
      })
    end
    local rawMessageId = reader:u16le(offset + 2)
    local rawSound = reader:u16le(offset + 4)
    local sound
    if rawSound > 0 and rawSound <= SOUND_EFFECT_END then
      sound = { kind = "effect", id = rawSound }
    elseif rawSound == SOUND_EFFECT_END + 1 then
      sound = { kind = "cry", pattern = 0 }
    elseif rawSound > SOUND_EFFECT_END + 1 then
      sound = { kind = "cry", pattern = 11 }
    end
    steps[#steps + 1] = {
      motionId = motionId ~= 0 and motionId or nil,
      messageId = rawMessageId ~= 0 and rawMessageId - 1 or nil,
      sound = sound,
      reactionId = reactionId,
      delayTicks = reader:u8(offset + 7),
    }
  end
  local continuationGate = reader:u8(0x28)
  local continuation = nil
  if continuationGate ~= 0 then
    local choice0InteractionId = reader:u16le(0x2C)
    local choice1InteractionId = reader:u16le(0x2E)
    if choice0InteractionId > 1023 or choice1InteractionId > 1023 then
      Errors.raise("FOLLOWER_INTERACTION_CONTINUATION_INVALID", "program continuation is outside the source archive", {
        choice0InteractionId = choice0InteractionId,
        choice1InteractionId = choice1InteractionId,
      })
    end
    continuation = {
      choice0InteractionId = choice0InteractionId,
      choice1InteractionId = choice1InteractionId,
    }
  end
  local accessory = reader:u8(0x32)
  local leaf = reader:u8(0x33)
  if accessory > 100 or leaf > 5 then
    Errors.raise("FOLLOWER_INTERACTION_REWARD_INVALID", "program reward selector is out of range", {
      accessory = accessory,
      leaf = leaf,
    })
  end
  return {
    steps = steps,
    continuation = continuation,
    friendshipDelta = signed(reader:u8(0x30), 256),
    moodDelta = signed(reader:u8(0x31), 256),
    fashionAccessoryId = accessory > 0 and accessory - 1 or nil,
    shinyLeafId = leaf > 0 and leaf or nil,
  }
end

local function decodeMotionMember(bytes)
  -- ov02_02250004 loads a 1-based motion selector from NARC a/2/2/2.
  requireSize(bytes, Sources.MOTION_SIZE, "motion", -1)
  local reader = BinaryReader.new(bytes, "follower-interaction-motion")
  local records = {}
  for index = 0, 9 do
    local offset = index * 8
    local facing = reader:u8(offset)
    if facing == 0xFF then
      break
    end
    records[#records + 1] = {
      facing = facing,
      ticks = reader:u8(offset + 1),
      x = signed(reader:u8(offset + 2), 256) / 16,
      y = signed(reader:u8(offset + 3), 256) / 16,
      z = signed(reader:u8(offset + 4), 256) / 16,
      sound = reader:u8(offset + 5) ~= 0,
    }
  end
  return records
end

local function decodeReactionDescriptor(bytes)
  -- sub_02026E18 and sub_02026DE0 decode the companion selector table.
  requireSize(bytes, 20, "reaction descriptor", -1)
  local reader = BinaryReader.new(bytes, "follower-reaction-descriptor")
  local count = reader:u32le(0)
  if count ~= 4 then
    Errors.raise("FOLLOWER_REACTION_DESCRIPTOR_INVALID", "reaction descriptor must contain four frames", {
      count = count,
    })
  end
  local decoded, err = FieldEffectPatternAnimation.decode(bytes, {
    alias = "field_static_models",
    section = "follower-reaction-pattern",
  })
  if not decoded then
    Errors.raise("FOLLOWER_REACTION_DESCRIPTOR_INVALID", "reaction descriptor could not be decoded", {
      error = err,
    })
  end
  assert(decoded)
  assert(#decoded.keys == count, "reaction descriptor decoder must preserve the source key count")
  return decoded
end

local function decodeMessage(bytes, bankId, messageId)
  local bank, err = FieldMessageBank.decode(bytes, { label = "message-bank-" .. bankId })
  if not bank then
    error(err)
  end
  local message = bank.messages[messageId + 1]
  if not message then
    Errors.raise("FOLLOWER_INTERACTION_MESSAGE_MISSING", "required display name is missing", {
      bankId = bankId,
      messageId = messageId,
    })
  end
  local tokens, tokenizeErr = FieldMessageTokenizer.tokenize(message.raw, charmap, {
    bankId = bankId,
    messageId = messageId,
  })
  if not tokens then
    error(tokenizeErr)
  end
  return FieldMessageText.tokensToText(tokens), bank.messageCount
end

local function checkedArchive(romFs, alias, expectedCount)
  local narc = assert(romFs:openNarc(alias), alias .. " archive must be available")
  if narc:memberCount() ~= expectedCount then
    Errors.raise("FOLLOWER_INTERACTION_ARCHIVE_COUNT", alias .. " archive has an unexpected member count", {
      archive = alias,
      expected = expectedCount,
      actual = narc:memberCount(),
    })
  end
  return narc
end

local function decodeRules(ruleNarc)
  local commonFirst = {}
  local commonTail = {}
  local commonBytes = readMember(ruleNarc, 0, Sources.ARCHIVES.rules)
  requireSize(commonBytes, Sources.COMMON_RULE_COUNT * Sources.RULE_SIZE, "common rules", 0)
  for row = 0, Sources.COMMON_RULE_COUNT - 1 do
    local offset = row * Sources.RULE_SIZE
    local decoded = decodeRule(commonBytes:sub(offset + 1, offset + Sources.RULE_SIZE))
    if decoded.interactionId ~= 0 then
      local segment = row < 12 and commonFirst or commonTail
      segment[#segment + 1] = decoded
    end
  end
  local bySection = {}
  for sectionId = 0, 235 do
    local rows = {}
    if sectionId > 0 then
      local bytes = readMember(ruleNarc, sectionId, Sources.ARCHIVES.rules)
      requireSize(bytes, Sources.SECTION_RULE_COUNT * Sources.RULE_SIZE, "section rules", sectionId)
      for row = 0, Sources.SECTION_RULE_COUNT - 1 do
        local offset = row * Sources.RULE_SIZE
        local decoded = decodeRule(bytes:sub(offset + 1, offset + Sources.RULE_SIZE))
        if decoded.interactionId ~= 0 then
          rows[#rows + 1] = decoded
        end
      end
    end
    local ordered = {}
    for _, rule in ipairs(commonFirst) do
      ordered[#ordered + 1] = rule
    end
    for _, rule in ipairs(rows) do
      ordered[#ordered + 1] = rule
    end
    for _, rule in ipairs(commonTail) do
      ordered[#ordered + 1] = rule
    end
    bySection[sectionId] = ordered
  end
  return bySection
end

local function decodePrograms(ruleNarc, programNarc, motionNarc)
  local interactionIds, queue = {}, {}
  for _, rules in pairs(ruleNarc) do
    for _, rule in ipairs(rules) do
      if not interactionIds[rule.interactionId] then
        interactionIds[rule.interactionId] = true
        queue[#queue + 1] = rule.interactionId
      end
    end
  end
  local programs, motionIds, reactionIds = {}, {}, {}
  for selector = 1, motionNarc:memberCount() do
    motionIds[selector] = true
  end
  local queueIndex = 1
  while queueIndex <= #queue do
    local interactionId = queue[queueIndex]
    queueIndex = queueIndex + 1
    local memberId = interactionId - 1
    local bytes = readMember(programNarc, memberId, Sources.ARCHIVES.programs)
    local program = decodeProgramMember(bytes)
    programs[interactionId] = program
    for _, step in ipairs(program.steps) do
      if step.motionId ~= nil then
        motionIds[step.motionId] = true
      end
      if step.reactionId ~= 0 then
        reactionIds[step.reactionId] = true
      end
    end
    if program.continuation then
      for _, nextId in ipairs({
        program.continuation.choice0InteractionId,
        program.continuation.choice1InteractionId,
      }) do
        if nextId ~= 0 and not interactionIds[nextId] then
          interactionIds[nextId] = true
          queue[#queue + 1] = nextId
        end
      end
    end
  end
  local motions = {}
  for motionId in pairs(motionIds) do
    if motionId > motionNarc:memberCount() then
      Errors.raise("FOLLOWER_INTERACTION_MOTION_MISSING", "program references a missing motion", {
        motionId = motionId,
      })
    end
    motions[motionId] = decodeMotionMember(readMember(motionNarc, motionId - 1, Sources.ARCHIVES.motions))
  end
  return programs, motions, reactionIds
end

local function decodeMapClasses(mapClassNarc)
  local bytes = readMember(mapClassNarc, 0, Sources.ARCHIVES.mapClasses)
  requireSize(bytes, Sources.MAP_CLASS_TABLE_SIZE, "map classes", 0)
  local mapClassByMapId = {}
  for mapId = 1, #bytes do
    mapClassByMapId[mapId] = bytes:byte(mapId)
  end
  return mapClassByMapId
end

local function decodeNames(romFs)
  local messages = assert(romFs:openNarc("messages"), "message archive must be available")
  local bankBytes = {}
  local bankHashes = {}
  local function bank(bankId)
    if bankBytes[bankId] == nil then
      bankBytes[bankId] = readMember(messages, bankId, "messages")
      bankHashes[bankId] = Hashing.sha1hex(bankBytes[bankId])
    end
    return bankBytes[bankId]
  end
  local fashionNames = {}
  for accessoryId = 0, 99 do
    fashionNames[accessoryId] = {
      name = decodeMessage(bank(Sources.PLAIN_ACCESSORY_BANK), Sources.PLAIN_ACCESSORY_BANK, accessoryId),
      nameWithArticle = decodeMessage(
        bank(Sources.ARTICLE_ACCESSORY_BANK),
        Sources.ARTICLE_ACCESSORY_BANK,
        accessoryId
      ),
    }
  end
  local sectionIds = {}
  for map in MapCatalog.all() do
    sectionIds[map.mapSectionNativeId] = true
  end
  local locationNames = {}
  for sectionId in pairs(sectionIds) do
    local bankId, messageId
    if sectionId == 0 then
      bankId, messageId = 281, 0
    else
      bankId, messageId = 279, sectionId
    end
    locationNames[sectionId] = decodeMessage(bank(bankId), bankId, messageId)
  end
  return locationNames, fashionNames, bankHashes
end

function Compiler.decodeProgramMember(bytes)
  return decodeProgramMember(bytes)
end

function Compiler.decodeRuleMember(bytes)
  return decodeRule(bytes)
end

function Compiler.decodeMotionMember(bytes)
  return decodeMotionMember(bytes)
end

function Compiler.decodeReactionDescriptor(bytes)
  return decodeReactionDescriptor(bytes)
end

function Compiler.compile(romFs)
  assert(romFs and romFs.openNarc and romFs.version, "interaction compiler requires RomFs")
  local rulesArchive = checkedArchive(romFs, Sources.ARCHIVES.rules, 236)
  local programArchive = checkedArchive(romFs, Sources.ARCHIVES.programs, 1023)
  local motionArchive = checkedArchive(romFs, Sources.ARCHIVES.motions, 108)
  local mapClassArchive = checkedArchive(romFs, Sources.ARCHIVES.mapClasses, 1)
  local mapSections = decodeRules(rulesArchive)
  local programs, motions, usedReactions = decodePrograms(mapSections, programArchive, motionArchive)
  local reactions = {}
  for selector = 1, 14 do
    local definition = "follower_reaction_" .. selector
    reactions[selector] = {
      definition = definition,
      resourceKey = FieldEffectAssetCache.definitionPath(definition),
    }
  end
  for selector in pairs(usedReactions) do
    if selector < 1 or selector > 14 then
      Errors.raise("FOLLOWER_INTERACTION_SELECTOR_INVALID", "rule program references an invalid reaction", {
        selector = selector,
      })
    end
  end
  local mapClassByMapId = decodeMapClasses(mapClassArchive)
  local locationNames, fashionNames, nameBanks = decodeNames(romFs)
  local catalog = {
    schema = Contract.followerInteractions.schema,
    version = romFs:version(),
    rulesByMapSection = mapSections,
    programs = programs,
    motions = motions,
    reactions = reactions,
    mapClassByMapId = mapClassByMapId,
    locationNames = locationNames,
    fashionNames = fashionNames,
  }
  local valid, err = InteractionCache.validateCatalog(catalog)
  if not valid then
    error(err)
  end
  local provenance = {
    source = "pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36",
    files = {
      "overlay_02_02248728.s",
      "overlay_01_02203A18.s",
      "asm/unk_02026DE0.s",
      "src/message_format.c",
    },
    archives = {
      rules = Sources.ARCHIVES.rules,
      programs = Sources.ARCHIVES.programs,
      motions = Sources.ARCHIVES.motions,
      mapClasses = Sources.ARCHIVES.mapClasses,
    },
  }
  local dependencies = {
    version = romFs:version(),
    provenance = provenance,
    memberCounts = {
      rules = rulesArchive:memberCount(),
      programs = programArchive:memberCount(),
      motions = motionArchive:memberCount(),
      mapClasses = mapClassArchive:memberCount(),
    },
    nameBanks = nameBanks,
    catalog = catalog,
    fieldReactions = FieldEffects.followerReactions,
  }
  return {
    catalog = catalog,
    provenance = provenance,
    marker = InteractionCache.marker(romFs:metadata().sha1, Hashing.hashLua(dependencies)),
  }
end

return Compiler
