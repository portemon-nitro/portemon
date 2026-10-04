-- Synthetic trainer-data projection: hand-built native trainer records for every
-- party-member variant (pret/pokeheartgold include/trainer_data.h TRDATA and
-- the four TRPOKE shapes selected by constants/trainers.h TRTYPE_* bits)
-- decode through the trainer compiler into ordered templates, custom moves
-- survive exactly, default movesets stay unbuilt, the rival name stays an
-- indirection, AI flags become named passes, malformed records fail with
-- attributed errors, and a throwing trainer emission through the production
-- derived-cache job path preserves producer context while publishing
-- nothing ready. Vectors are specified here from the source layout; they
-- are never produced by the compiler.

local Assert = require("tests.support.Assert")

local T = {}

-- TRTYPE_* selection bits: bit 0 custom moves, bit 1 held item.
local TRTYPE_MON = 0
local TRTYPE_MON_MOVES = 1
local TRTYPE_MON_ITEM = 2
local TRTYPE_MON_ITEM_MOVES = 3

-- Trainer classes: YOUNGSTER decodes through the message bank while RIVAL
-- resolves its name from the save rival name instead.
local CLASS_YOUNGSTER = 2
local CLASS_RIVAL = 23

local function u8(v)
  return string.char(v % 256)
end

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  return string.char(
    v % 256,
    math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256,
    math.floor(v / 16777216) % 256
  )
end

-- 20-byte TRDATA: trainerType, class, unk_2, npoke, items[4] u16, aiFlags
-- u32, doubleBattle u32.
local function trdata(trainerType, class, npoke, items, aiFlags, doubleBattle)
  local bytes = u8(trainerType) .. u8(class) .. u8(0) .. u8(npoke)
  for index = 1, 4 do
    bytes = bytes .. u16(items[index] or 0)
  end
  return bytes .. u32(aiFlags or 0) .. u32(doubleBattle or 0)
end

-- Species word: bits 0-9 species id, bits 10-15 form id.
local function speciesWord(speciesId, form)
  return u16(speciesId + (form or 0) * 1024)
end

local function memberHead(difficulty, genderAbility, level, speciesId, form)
  return u8(difficulty) .. u8(genderAbility) .. u16(level) .. speciesWord(speciesId, form)
end

local function moveList(moveIds)
  local bytes = ""
  for _, moveId in ipairs(moveIds) do
    bytes = bytes .. u16(moveId)
  end
  return bytes
end

-- 8-byte TRPOKE without item or custom moves.
local function plainMember(difficulty, level, speciesId)
  return memberHead(difficulty, 0, level, speciesId, 0) .. u16(0)
end

-- 16-byte TRPOKE with custom moves.
local function movesMember(difficulty, level, speciesId, moves)
  assert(#moves == 4, "a custom-moves member carries exactly four move slots")
  return memberHead(difficulty, 0, level, speciesId, 0) .. moveList(moves) .. u16(0)
end

-- 10-byte TRPOKE with a held item.
local function itemMember(difficulty, level, speciesId, itemId)
  return memberHead(difficulty, 0, level, speciesId, 0) .. u16(itemId) .. u16(0)
end

-- 18-byte TRPOKE with a held item and custom moves.
local function itemMovesMember(difficulty, level, speciesId, itemId, moves)
  assert(#moves == 4, "an item custom-moves member carries exactly four move slots")
  return memberHead(difficulty, 0, level, speciesId, 0) .. u16(itemId) .. moveList(moves) .. u16(0)
end

local function nativeInput(records)
  return { versionId = "heartgold", trainers = records }
end

local function assertTemplateShape(template, label)
  Assert.isTrue(type(template.species) == "string" and template.species ~= "", label .. " needs a species key")
  Assert.isTrue(type(template.form) == "number", label .. " needs a form identity")
  Assert.isTrue(type(template.level) == "number", label .. " needs a level")
  Assert.isTrue(type(template.difficulty) == "number", label .. " needs a difficulty")
  Assert.isTrue(type(template.heldItem) == "string", label .. " needs a held-item key")
  Assert.isTrue(type(template.identityPolicy) == "string", label .. " needs an identity policy")
  Assert.notNil(template.identityParams, label .. " needs identity parameters")
end

function T.every_party_member_variant_decodes_to_an_ordered_template()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local records = {
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 2, {}, 0, 0),
      members = plainMember(30, 5, 19) .. plainMember(40, 7, 16),
    },
    [4] = {
      data = trdata(TRTYPE_MON_MOVES, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = movesMember(50, 9, 25, { 33, 45, 0, 0 }),
    },
    [5] = {
      data = trdata(TRTYPE_MON_ITEM, CLASS_YOUNGSTER, 1, { 17 }, 0, 0),
      members = itemMember(60, 12, 41, 155),
    },
    [6] = {
      data = trdata(TRTYPE_MON_ITEM_MOVES, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = itemMovesMember(70, 14, 74, 234, { 10, 33, 0, 0 }),
    },
  }
  local compiled = assert(TrainerCatalogCompiler.compile(nativeInput(records)))
  local plain = assert(compiled.trainers[8], "trainer 8 must survive projection")
  Assert.equal(#plain.party, 2, "both party slots stay ordered and distinct")
  Assert.equal(plain.party[1].species, "RATTATA", "slot one keeps its species key")
  Assert.equal(plain.party[1].level, 5, "slot one keeps its level")
  Assert.equal(plain.party[1].difficulty, 30, "slot one keeps its difficulty")
  Assert.equal(plain.party[2].species, "PIDGEY", "slot two keeps its species key")
  Assert.equal(plain.party[2].level, 7, "slot two keeps its level")
  Assert.isNil(plain.party[1].moves, "a default-moves member leaves moves unbuilt for initial-learnset construction")
  Assert.equal(plain.party[1].heldItem, "NONE", "a member without an item keeps the NONE key")
  for _, template in ipairs(plain.party) do
    assertTemplateShape(template, "trainer 8 slot")
  end
  local custom = assert(compiled.trainers[4], "trainer 4 must survive projection").party[1]
  Assert.equal(custom.species, "PIKACHU", "the custom-moves member keeps its species key")
  Assert.deepEqual(custom.moves, { "TACKLE", "GROWL" }, "custom moves survive exactly, trailing empty slots dropped")
  local held = assert(compiled.trainers[5], "trainer 5 must survive projection").party[1]
  Assert.equal(held.species, "ZUBAT", "the held-item member keeps its species key")
  Assert.equal(held.heldItem, "ORAN_BERRY", "the held-item member keeps its item key")
  Assert.isNil(held.moves, "a held-item default-moves member still leaves moves unbuilt")
  local both = assert(compiled.trainers[6], "trainer 6 must survive projection").party[1]
  Assert.equal(both.species, "GEODUDE", "the item custom-moves member keeps its species key")
  Assert.equal(both.heldItem, "LEFTOVERS", "the item custom-moves member keeps its item key")
  Assert.deepEqual(both.moves, { "SCRATCH", "TACKLE" }, "item custom moves survive exactly in order")
  assert(BattleDataSchema.assertTrainerCatalog(compiled) ~= false, "the projected catalog passes the semantic schema")
end

function T.rival_names_stay_an_indirection_while_other_names_reference_the_bank()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local records = {
    [1] = {
      data = trdata(TRTYPE_MON, CLASS_RIVAL, 1, {}, 0, 0),
      members = plainMember(50, 5, 25),
    },
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = plainMember(30, 5, 19),
    },
  }
  local compiled = assert(TrainerCatalogCompiler.compile(nativeInput(records)))
  local rival = assert(compiled.trainers[1], "the rival record must survive projection")
  local youngster = assert(compiled.trainers[8], "the youngster record must survive projection")
  Assert.isTrue(
    rival.nameReference ~= nil and rival.nameReference.rival == true,
    "the rival name stays a save-name indirection instead of a bank lookup"
  )
  Assert.isTrue(
    youngster.nameReference ~= nil and youngster.nameReference.trainerIndex == 8,
    "an ordinary trainer keeps its message-bank name reference"
  )
  Assert.isNil(rival.name, "no concrete rival name is invented during import")
  Assert.equal(rival.trainerClass, CLASS_RIVAL, "the rival class survives projection")
end

function T.ai_flags_project_to_named_passes_without_inventing_policy()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local records = {
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = plainMember(30, 5, 19),
    },
    [9] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 3, 1),
      members = plainMember(30, 5, 19),
    },
  }
  local compiled = assert(TrainerCatalogCompiler.compile(nativeInput(records)))
  local quiet = assert(compiled.trainers[8], "trainer 8 must survive projection")
  local aggressive = assert(compiled.trainers[9], "trainer 9 must survive projection")
  Assert.deepEqual(quiet.aiPasses, {}, "clear AI flags project to an empty pass list, not a nil")
  Assert.isTrue(
    type(aggressive.aiPasses) == "table" and #aggressive.aiPasses > 0,
    "set AI flags project to a non-empty named pass list"
  )
  for _, pass in ipairs(aggressive.aiPasses) do
    Assert.isTrue(type(pass) == "string" and pass ~= "", "every AI pass must be a named string")
  end
  Assert.isTrue(aggressive.doubleBattle == true, "the doubles flag survives projection")
  Assert.isTrue(quiet.doubleBattle == false, "a singles trainer must not gain doubles play")
end

function T.trainer_item_slots_keep_all_four_source_positions()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local records = {
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, { 17, 0, 26, 0 }, 0, 0),
      members = plainMember(30, 5, 19),
    },
  }
  local compiled = assert(TrainerCatalogCompiler.compile(nativeInput(records)))
  local trainer = assert(compiled.trainers[8], "trainer 8 must survive projection")
  Assert.deepEqual(
    trainer.items,
    { "POTION", "NONE", "SUPER_POTION", "NONE" },
    "empty source positions stay as explicit gaps in source order"
  )
end

function T.trainer_catalogs_require_exactly_four_item_slots()
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local function catalogWith(items)
    return {
      schema = "trainer-schema-fixture",
      version = { id = "heartgold" },
      trainers = {
        [8] = {
          trainerClass = CLASS_YOUNGSTER,
          nameReference = { trainerIndex = 8 },
          party = {},
          aiPasses = {},
          doubleBattle = false,
          items = items,
          prizeMoney = { trainerClass = CLASS_YOUNGSTER, classRate = 4 },
          messageSelectors = { intro = 0, lose = 1, after = 2 },
        },
      },
    }
  end
  Assert.isTrue(
    BattleDataSchema.assertTrainerCatalog(catalogWith({ "POTION", "NONE", "SUPER_POTION", "NONE" })),
    "four source-ordered slots pass the semantic schema"
  )
  local compiled = assert(TrainerCatalogCompiler.compile(nativeInput({
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = plainMember(30, 5, 19),
    },
  })))
  Assert.deepEqual(
    assert(compiled.trainers[8], "trainer 8 must survive projection").items,
    { "NONE", "NONE", "NONE", "NONE" },
    "an itemless trainer still carries four explicit gaps"
  )
  for _, items in ipairs({
    { "POTION", "NONE", "SUPER_POTION" },
    { "POTION", "NONE", "SUPER_POTION", "NONE", "POTION" },
  }) do
    local failure = Assert.throws(function()
      BattleDataSchema.assertTrainerCatalog(catalogWith(items))
    end, "a trainer item list with " .. #items .. " slots must fail")
    Assert.equal(failure.code, "BATTLE_DATA_INVALID", "the failure names the data contract")
  end
end

function T.trainer_prize_and_message_selectors_survive_projection()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local records = {
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, { 17, 0, 0, 0 }, 0, 0),
      members = plainMember(30, 5, 19),
    },
  }
  local compiled = assert(TrainerCatalogCompiler.compile(nativeInput(records)))
  local trainer = assert(compiled.trainers[8], "trainer 8 must survive projection")
  Assert.equal(trainer.trainerClass, CLASS_YOUNGSTER, "the class identity survives projection")
  Assert.isTrue(type(trainer.prizeMoney) == "table", "prize-money class data survives projection")
  Assert.equal(trainer.prizeMoney.trainerClass, CLASS_YOUNGSTER, "the prize record keeps its class")
  Assert.equal(trainer.prizeMoney.classRate, 4, "the prize record carries the pinned class rate")
  Assert.isTrue(type(trainer.messageSelectors) == "table", "message selectors survive projection")
  Assert.deepEqual(
    trainer.items,
    { "POTION", "NONE", "NONE", "NONE" },
    "held trainer items resolve to item keys in source order with explicit gaps"
  )
end

function T.trainer_class_rates_cover_every_native_class_without_fallback()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local rates = assert(BattleSources.prizeMoneyRates, "the pinned payout table must exist")
  for class = 0, 128 do
    local rate = rates[class]
    Assert.isTrue(
      type(rate) == "number" and rate % 1 == 0 and rate >= 0,
      "class " .. class .. " carries a pinned non-negative integer rate"
    )
  end
  Assert.equal(rates[2], 4, "the youngster rate matches the source table")
  Assert.equal(rates[34], 50, "the gentleman rate matches the source table")
  Assert.equal(rates[44], 1, "the tuber rate matches the source table")
  Assert.equal(rates[0], 0, "the player-stand-in class awards nothing")
  Assert.equal(rates[124], 45, "the rocket-boss rate matches the source table")
  Assert.equal(rates[109], 50, "the red rate matches the source table")
  Assert.equal(rates[110], 40, "the blue rate matches the source table")
  -- A class outside the pinned table never compiles: unknown classes fail
  -- instead of borrowing another class's rate.
  local bad, badErr = TrainerCatalogCompiler.compile(nativeInput({
    [8] = { data = trdata(TRTYPE_MON, 200, 1, {}, 0, 0), members = plainMember(30, 5, 19) },
  }))
  Assert.isNil(bad, "a class outside the pinned payout table must not compile")
  Assert.isTrue(badErr ~= nil, "the unknown class must report a typed error")
end

function T.malformed_trainer_records_fail_with_attributed_errors()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local shortData = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0):sub(1, 19)
  Assert.equal(#shortData, 19, "the truncated TRDATA fixture must be one byte short of 20")
  local compiled, shortErr = TrainerCatalogCompiler.compile(nativeInput({
    [8] = { data = shortData, members = plainMember(30, 5, 19) },
  }))
  Assert.isNil(compiled, "a truncated trainer header must not compile")
  Assert.isTrue(
    tostring(assert(shortErr, "a truncated header must report a typed error").message):find("8", 1, true) ~= nil,
    "the size failure must name the trainer index"
  )
  local shortMembers = plainMember(30, 5, 19):sub(1, 7)
  local truncated, memberErr = TrainerCatalogCompiler.compile(nativeInput({
    [8] = { data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0), members = shortMembers },
  }))
  Assert.isNil(truncated, "a truncated party member must not compile")
  Assert.isTrue(
    tostring(assert(memberErr, "a truncated member must report a typed error").message):find("8", 1, true) ~= nil,
    "the member failure must name the trainer index"
  )
  local unknownSpecies = memberHead(30, 0, 5, 0, 0):sub(1, 4) .. speciesWord(600, 0) .. u16(0)
  local badSpecies, speciesErr = TrainerCatalogCompiler.compile(nativeInput({
    [8] = { data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0), members = unknownSpecies },
  }))
  Assert.isNil(badSpecies, "an unknown species reference must not compile")
  Assert.isTrue(
    tostring(assert(speciesErr, "an unknown species must report a typed error").message):find("8", 1, true) ~= nil,
    "the species failure must name the trainer index"
  )
  local unknownMove = movesMember(50, 9, 25, { 33, 999, 0, 0 })
  local badMove, moveErr = TrainerCatalogCompiler.compile(nativeInput({
    [4] = { data = trdata(TRTYPE_MON_MOVES, CLASS_YOUNGSTER, 1, {}, 0, 0), members = unknownMove },
  }))
  Assert.isNil(badMove, "an unknown custom-move reference must not compile")
  Assert.notNil(moveErr, "an unknown custom move must report a typed error")
end

function T.failed_trainer_emission_keeps_the_prior_generation_readable()
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local generationId = "trainer-ready-generation"
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  -- A previous ready generation, staged through the compiler and the owned
  -- cache paths, stays byte-identical across the failed rebuild below.
  local ready = assert(TrainerCatalogCompiler.compile(nativeInput({
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = plainMember(30, 5, 19),
    },
  })))
  assert(BattleDataSchema.assertTrainerCatalog(ready) ~= false, "the ready catalog passes the semantic schema")
  local paths = BattleDataCache.paths()
  local catalogPath = assert(paths.trainers, "the cache must publish a trainer-catalog path")
  cacheFs:writeLua(catalogPath, ready)
  local before = cacheFs:read(catalogPath)
  local throwingRomFs = setmetatable({}, {
    __index = function(_, key)
      error("trainer emission reached the native archive reader for " .. tostring(key), 0)
    end,
  })
  local context = { cacheFs = cacheFs, romFs = throwingRomFs, versionId = "heartgold" }
  local ok, failure = pcall(ArtifactJobs.execute, {
    kind = "trainers",
    key = "global",
    generationId = generationId,
    producerFingerprint = "trainer-emission-fixture",
    stageName = "trainer-failure-stage",
    epoch = 1,
  }, context)
  Assert.isFalse(ok, "a trainer emission that throws must fail the job")
  Assert.isTrue(
    tostring(failure):find("trainer", 1, true) ~= nil,
    "the failure must preserve producer context, got: " .. tostring(failure)
  )
  Assert.equal(cacheFs:read(catalogPath), before, "the prior ready generation stays readable")
  local readyCheck, readinessErr = ArtifactJobs.validate(cacheFs, generationId, "trainers", "global", {}, nil)
  Assert.isFalse(readyCheck, "the incomplete stage must not read as ready: " .. tostring(readinessErr))
  local loaded = BattleDataCache.loadTrainers(cacheFs)
  Assert.deepEqual(loaded, ready, "the surviving generation still loads exactly")
end

function T.overrides_form_and_capsule_survive_projection()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  -- Gender byte 0x21 forces female with the second ability; the species
  -- word carries form 1 for PIKACHU; the capsule word stays opaque.
  local member = u8(50) .. u8(0x21) .. u16(9) .. u16(25 + 1024) .. u16(0)
  local compiled = assert(TrainerCatalogCompiler.compile(nativeInput({
    [4] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = member,
    },
  })))
  local template = assert(compiled.trainers[4], "trainer 4 must survive projection").party[1]
  Assert.equal(template.species, "PIKACHU", "the species identity survives beside its form")
  Assert.equal(template.form, 1, "form bits decode to the integer form identity")
  Assert.equal(template.identityPolicy, "native_pid", "overrides keep the native identity policy")
  Assert.deepEqual(
    template.identityParams,
    { genderOverride = 1, abilityOverride = 2, capsule = 0 },
    "gender/ability overrides decode to their source nibbles with the capsule"
  )
  local capsuleMember = u8(50) .. u8(0) .. u16(9) .. u16(25) .. u16(0x1234)
  local capsuleCompiled = assert(TrainerCatalogCompiler.compile(nativeInput({
    [4] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = capsuleMember,
    },
  })))
  local capsuleTemplate = assert(capsuleCompiled.trainers[4], "trainer 4 must survive projection").party[1]
  Assert.equal(capsuleTemplate.identityParams.capsule, 0x1234, "the capsule word survives verbatim")
  local badForm = u8(50) .. u8(0) .. u16(9) .. u16(1023) .. u16(0)
  local bad, err = TrainerCatalogCompiler.compile(nativeInput({
    [4] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = badForm,
    },
  }))
  Assert.isNil(bad, "an out-of-universe species never compiles, form bits or not")
  Assert.isTrue(
    tostring(assert(err, "an unknown species must report a typed error").message):find("4", 1, true) ~= nil,
    "the species failure names the trainer index"
  )
end

function T.all_zero_custom_moves_project_to_an_empty_list()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local compiled = assert(TrainerCatalogCompiler.compile(nativeInput({
    [4] = {
      data = trdata(TRTYPE_MON_MOVES, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = movesMember(50, 9, 25, { 0, 0, 0, 0 }),
    },
  })))
  local template = assert(compiled.trainers[4], "trainer 4 must survive projection").party[1]
  Assert.notNil(template.moves, "a custom-moves variant keeps its moves list even when empty")
  Assert.deepEqual(template.moves, {}, "all-empty move slots project to no custom moves")
end

function T.unknown_item_references_fail_with_attributed_errors()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local badMember, memberErr = TrainerCatalogCompiler.compile(nativeInput({
    [5] = {
      data = trdata(TRTYPE_MON_ITEM, CLASS_YOUNGSTER, 1, {}, 0, 0),
      members = itemMember(60, 12, 41, 999),
    },
  }))
  Assert.isNil(badMember, "an unknown held-item reference must not compile")
  Assert.isTrue(
    tostring(assert(memberErr, "an unknown held item must report a typed error").message):find("5", 1, true)
      ~= nil,
    "the held-item failure names the trainer index"
  )
  local badTrainerItem, trainerErr = TrainerCatalogCompiler.compile(nativeInput({
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, { 999, 0, 0, 0 }, 0, 0),
      members = plainMember(30, 5, 19),
    },
  }))
  Assert.isNil(badTrainerItem, "an unknown trainer-item reference must not compile")
  Assert.isTrue(
    tostring(assert(trainerErr, "an unknown trainer item must report a typed error").message):find("8", 1, true)
      ~= nil,
    "the trainer-item failure names the trainer index"
  )
end

function T.trainer_projection_is_stable_across_compilations()
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local input = nativeInput({
    [8] = {
      data = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 2, { 17 }, 3, 1),
      members = plainMember(30, 5, 19) .. plainMember(40, 7, 16),
    },
  })
  local first = assert(TrainerCatalogCompiler.compile(input))
  local second = assert(TrainerCatalogCompiler.compile(input))
  Assert.deepEqual(second, first, "projection is a pure function of its input")
end

function T.successful_trainer_job_stages_publishes_and_reads_ready()
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local header = trdata(TRTYPE_MON, CLASS_YOUNGSTER, 1, {}, 0, 0)
  local members = plainMember(30, 5, 19)
  local emptyHeader = string.rep("\0", 20)
  local narcFor = function(member, count)
    return {
      memberCount = function()
        return count
      end,
      readMember = function(_, memberId)
        if memberId == 8 then
          return member
        end
        return emptyHeader
      end,
    }
  end
  local fakeRomFs = {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, alias)
      if alias == "trainer_data" then
        return narcFor(header, 9)
      end
      if alias == "trainer_parties" then
        return narcFor(members, 9)
      end
      return nil, "unknown archive " .. tostring(alias)
    end,
  }
  local generationId = "trainer-success-generation"
  local stageName = "trainer-success-stage"
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local receipt, executeErr = ArtifactJobs.execute({
    kind = "trainers",
    key = "global",
    generationId = generationId,
    producerFingerprint = "trainer-success-fixture",
    stageName = stageName,
    epoch = 1,
  }, { cacheFs = cacheFs, romFs = fakeRomFs, versionId = "heartgold" })
  Assert.isTrue(executeErr == nil, "the trainer job executes: " .. tostring(receipt))
  Assert.isTrue(type(receipt.result.marker) == "string", "execution seals a receipt marker")
  local staged = PreparedArtifact.open({
    cacheFs = cacheFs,
    generationId = generationId,
    epoch = 1,
    kind = "trainers",
    key = "global",
    jobKey = "trainers:global",
    stageName = stageName,
  })
  Assert.isTrue(staged:publish({
    generationId = generationId,
    epoch = 1,
    kind = "trainers",
    key = "global",
    jobKey = "trainers:global",
  }), "the staged generation publishes")
  Assert.isTrue(
    ArtifactJobs.validate(cacheFs, generationId, "trainers", "global", {}, nil),
    "the published stage reads ready"
  )
  local expected = assert(TrainerCatalogCompiler.compile(nativeInput({
    [8] = { data = header, members = members },
  })))
  assert(BattleDataSchema.assertTrainerCatalog(expected) ~= false, "the expected catalog passes the schema")
  Assert.deepEqual(BattleDataCache.loadTrainers(cacheFs), expected, "the published catalog loads exactly")
end

return { tests = T }
