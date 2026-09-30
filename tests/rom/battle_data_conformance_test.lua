-- Dump-backed conformance for the native battle inputs: the trainer archive,
-- the version encounter tables, and the move table of the ready user-owned
-- dump decode through the battle-data compilers, every supported identity
-- resolves with cross-reference validity, recompilation is deterministic,
-- and the results pass the shared semantic schemas. Assertions are coverage
-- relationships and validity, never catalog snapshots or committed
-- commercial payloads.

local Assert = require("tests.support.Assert")
local MonSources = require("romdump.src.config.MonSources")
local ItemSources = require("romdump.src.config.ItemSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local compiledBattleByVersion = {}
local compiledTrainersByVersion = {}
local compiledEncountersByVersion = {}

local function compileBattleData(romFs, versionId)
  if compiledBattleByVersion[versionId] == nil then
    local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
    compiledBattleByVersion[versionId] = assert(BattleDataCompiler.compileFromDump(romFs, { versionId = versionId }))
  end
  return compiledBattleByVersion[versionId]
end

local function compileTrainers(romFs, versionId)
  if compiledTrainersByVersion[versionId] == nil then
    local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
    compiledTrainersByVersion[versionId] = assert(TrainerCatalogCompiler.compileFromDump(romFs, { versionId = versionId }))
  end
  return compiledTrainersByVersion[versionId]
end

local function compileEncounters(romFs, versionId)
  if compiledEncountersByVersion[versionId] == nil then
    local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
    compiledEncountersByVersion[versionId] =
      assert(EncounterCatalogCompiler.compileFromDump(romFs, { versionId = versionId }))
  end
  return compiledEncountersByVersion[versionId]
end

local function countKeys(record)
  local count = 0
  for _ in pairs(record) do
    count = count + 1
  end
  return count
end

function T.every_usable_move_carries_exactly_one_behavior_binding(romFs, versionId)
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local compiled = compileBattleData(romFs, versionId)
  assert(BattleDataSchema.assertBattleData(compiled) ~= false, "the compiled battle data passes the semantic schema")
  local seen = {}
  for key, facts in pairs(compiled.moves) do
    Assert.isTrue(type(key) == "string" and key ~= "", "move keys must be non-empty strings")
    Assert.isNil(seen[key], "move " .. key .. " must resolve exactly once")
    seen[key] = true
    Assert.isTrue(type(facts.behavior.key) == "string" and facts.behavior.key ~= "", key .. " needs a behavior key")
    Assert.isTrue(type(facts.moveType) == "string", key .. " keeps its lower-case type key")
    Assert.isTrue(type(facts.basePp) == "number" and facts.basePp >= 0, key .. " keeps its source PP")
  end
  Assert.isNil(seen["NONE"], "the NONE sentinel is not a usable combat move")
  local nativeCount = 0
  for moveId = 1, MonSources.NUM_MOVES do
    nativeCount = nativeCount + 1
    local key = MonSources.moveKeys[moveId]
    Assert.notNil(seen[key], "native move " .. moveId .. " (" .. tostring(key) .. ") must resolve")
  end
  Assert.equal(countKeys(compiled.moves), nativeCount, "every usable native move resolves exactly once")
end

function T.trainer_parties_keep_ordered_templates_and_named_policies(romFs, versionId)
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local compiled = compileTrainers(romFs, versionId)
  assert(BattleDataSchema.assertTrainerCatalog(compiled) ~= false, "the trainer catalog passes the semantic schema")
  Assert.isTrue(countKeys(compiled.trainers) > 0, "the dump must yield at least one trainer record")
  local rivalSeen = false
  for trainerIndex, record in pairs(compiled.trainers) do
    Assert.isTrue(type(record.party) == "table" and #record.party > 0, "trainer " .. trainerIndex .. " keeps a party")
    for slotIndex, template in ipairs(record.party) do
      Assert.isTrue(type(template.species) == "string", "trainer " .. trainerIndex .. " slot " .. slotIndex .. " resolves")
      Assert.isTrue(type(template.level) == "number", "trainer " .. trainerIndex .. " slot " .. slotIndex .. " keeps a level")
      if template.moves ~= nil then
        for _, moveKey in ipairs(template.moves) do
          Assert.isTrue(type(moveKey) == "string", "custom moves stay semantic keys")
        end
      end
      Assert.isTrue(
        ItemSources.itemKeys ~= nil and type(template.heldItem) == "string",
        "trainer " .. trainerIndex .. " slot " .. slotIndex .. " keeps a held-item key"
      )
    end
    Assert.isTrue(type(record.aiPasses) == "table", "trainer " .. trainerIndex .. " keeps named AI passes")
    if record.trainerClass == 23 then
      rivalSeen = true
      Assert.isTrue(
        record.nameReference ~= nil and record.nameReference.rival == true,
        "the rival record keeps its save-name indirection"
      )
    end
  end
  Assert.isTrue(rivalSeen, "the dump must yield the rival class for the indirection check")
end

function T.encounter_tables_keep_slots_replacements_and_the_supported_game(romFs, versionId)
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local compiled = compileEncounters(romFs, versionId)
  assert(BattleDataSchema.assertEncounterCatalog(compiled) ~= false, "the encounter catalog passes the schema")
  Assert.isTrue(countKeys(compiled.tables) > 0, "the dump must yield at least one encounter table")
  for memberId, mapTable in pairs(compiled.tables) do
    Assert.equal(#mapTable.land.morning, 12, "member " .. memberId .. " keeps twelve morning slots")
    Assert.equal(#mapTable.land.day, 12, "member " .. memberId .. " keeps twelve day slots")
    Assert.equal(#mapTable.land.night, 12, "member " .. memberId .. " keeps twelve night slots")
    for _, replacement in pairs(mapTable.replacements) do
      Assert.equal(replacement.game, versionId, "member " .. memberId .. " replacements name the supported game")
      Assert.isTrue(type(replacement.slot) == "number", "member " .. memberId .. " replacements point at native slots")
    end
  end
end

function T.native_compilation_is_deterministic(romFs, versionId)
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local battle = compileBattleData(romFs, versionId)
  local trainers = compileTrainers(romFs, versionId)
  local encounters = compileEncounters(romFs, versionId)
  local battleAgain = assert(BattleDataCompiler.compileFromDump(romFs, { versionId = versionId }))
  local trainersAgain = assert(TrainerCatalogCompiler.compileFromDump(romFs, { versionId = versionId }))
  local encountersAgain = assert(EncounterCatalogCompiler.compileFromDump(romFs, { versionId = versionId }))
  Assert.equal(countKeys(battleAgain.moves), countKeys(battle.moves), "battle-data recompilation is stable")
  Assert.equal(countKeys(trainersAgain.trainers), countKeys(trainers.trainers), "trainer recompilation is stable")
  Assert.equal(countKeys(encountersAgain.tables), countKeys(encounters.tables), "encounter recompilation is stable")
  local sampleTrainer, sampleIndex = nil, nil
  for trainerIndex, record in pairs(trainers.trainers) do
    sampleTrainer, sampleIndex = record, trainerIndex
    break
  end
  Assert.notNil(sampleTrainer, "the dump must yield a trainer to sample")
  Assert.deepEqual(trainersAgain.trainers[sampleIndex], sampleTrainer, "the sampled trainer recompiles exactly")
end

-- Decodes one little-endian s32 without the production codec, so the
-- conformance below re-derives the weight facts independently.
local function s32le(bytes, offset)
  local b0, b1, b2, b3 = string.byte(bytes, offset + 1, offset + 4)
  local unsigned = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
  if unsigned >= 2147483648 then
    return unsigned - 4294967296
  end
  return unsigned
end

function T.mon_weights_follow_the_species_weight_table(romFs, versionId)
  local MonSources = require("romdump.src.config.MonSources")
  local BattleSources = require("romdump.src.config.BattleSources")
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local pin = BattleSources.weightSources
  local narc = assert(romFs:openNarc(pin.symbol), "the pinned weight archive must resolve")
  Assert.isTrue(narc:memberCount() > pin.memberId, "the pinned weight member must exist")
  local member = assert(narc:readMember(pin.memberId))
  Assert.equal(#member % 4, 0, "the weight member must size as an s32 table")
  Assert.equal(
    #member / 4,
    MonSources.MAX_SPECIES + 1,
    "the weight table spans exactly the species range"
  )
  local expected = {}
  for speciesId = 0, MonSources.MAX_SPECIES do
    local weight = s32le(member, speciesId * 4)
    Assert.isTrue(
      type(weight) == "number" and weight % 1 == 0 and weight >= 0,
      "species " .. speciesId .. " carries a non-negative weight"
    )
    expected[speciesId] = weight
  end
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  Assert.isTrue(MonAssetSchema.isValidCatalog(catalog), "the enriched mon catalog passes the shared schema")
  local seen = 0
  for key, species in pairs(catalog.species) do
    if species.nativeId >= 0 and species.nativeId <= MonSources.MAX_SPECIES then
      Assert.equal(
        species.weight,
        expected[species.nativeId],
        "species " .. key .. " carries its table weight in hectograms"
      )
      seen = seen + 1
    else
      Assert.isNil(species.weight, "sentinel species " .. key .. " carries no invented weight")
    end
  end
  Assert.equal(seen, MonSources.MAX_SPECIES + 1, "every tabled species resolves exactly once")
end

function T.item_throw_facts_follow_the_source_bytes(romFs, versionId)
  local MonSources = require("romdump.src.config.MonSources")
  local ItemSources = require("romdump.src.config.ItemSources")
  local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
  local ItemCatalogCompiler = require("romdump.src.digest.items.ItemCatalogCompiler")
  local catalog = assert(ItemCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  Assert.isTrue(ItemAssetSchema.isValidCatalog(catalog), "the enriched item catalog passes the shared schema")
  local itemData = assert(romFs:openNarc("item_data"))
  local checked = 0
  for nativeId = 0, 536 do
    local key = ItemSources.itemKeys[nativeId]
    local record = assert(catalog.items[key], "item " .. nativeId .. " (" .. tostring(key) .. ") must resolve")
    local member = assert(itemData:readMember(ItemSources.itemDataMember(nativeId)))
    -- 1-based string positions 6-8 carry the 0-based offsets 5-7.
    local flingEffect, flingPower = string.byte(member, 6), string.byte(member, 7)
    local giftPower = string.byte(member, 8)
    local word = string.byte(member, 8 + 1) + string.byte(member, 8 + 2) * 256
    local giftType = word % 32
    Assert.equal(record.fling.effect, flingEffect, key .. " keeps its source fling effect")
    Assert.equal(record.fling.power, flingPower, key .. " keeps its source fling power")
    Assert.equal(record.naturalGift.power, giftPower, key .. " keeps its source natural-gift power")
    Assert.equal(record.naturalGift.typeId, giftType, key .. " keeps its source natural-gift type bits")
    local typeKey = MonSources.typeKeys[giftType]
    if typeKey == nil then
      Assert.isNil(
        record.naturalGift.type,
        key .. " names no gift type outside the source type range"
      )
    else
      Assert.equal(record.naturalGift.type, typeKey, key .. " resolves its gift type key")
    end
    checked = checked + 1
  end
  Assert.equal(checked, 537, "every source item identity resolves exactly once")
end

return RomSuite.fromFacts(T)
