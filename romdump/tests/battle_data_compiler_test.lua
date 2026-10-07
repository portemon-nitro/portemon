-- Synthetic battle-metadata compilation: hand-built native move-table entries
-- (pret/pokeheartgold include/move.h MoveTbl, 16 bytes) project through the
-- battle-data compiler into source-independent facts, malformed entries fail
-- with attributed errors before anything is published, the native behavior
-- inventory covers every usable binding with no silent fallback, and loading
-- needs neither a native decoder nor the dump. Vectors are specified here
-- from the source layout; they are never produced by the compiler.

local Assert = require("tests.support.Assert")

local T = {}

local function u8(v)
  return string.char(v % 256)
end

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function s8(v)
  if v < 0 then
    v = v + 256
  end
  return string.char(v % 256)
end

-- One 16-byte MoveTbl entry: effect u16, category u8, power u8, type u8,
-- accuracy u8, pp u8, effectChance u8, range u16, priority s8, then four
-- source-only bytes the semantic projection must not leak.
local function moveEntry(fields)
  local tail = string.rep("\0", 4)
  return u16(fields.effect)
    .. u8(fields.category)
    .. u8(fields.power)
    .. u8(fields.moveType)
    .. u8(fields.accuracy)
    .. u8(fields.pp)
    .. u8(fields.effectChance or 0)
    .. u16(fields.range or 0)
    .. s8(fields.priority or 0)
    .. u8(0)
    .. tail
end

-- Plain damaging move: TACKLE (move 33), effect 0, physical, normal.
local function tackleEntry()
  return moveEntry({
    effect = 0,
    category = 0,
    power = 35,
    moveType = 0,
    accuracy = 95,
    pp = 35,
  })
end

-- Self stat-stage move: SWORDS_DANCE (move 14), effect 10, status class.
local function swordsDanceEntry()
  return moveEntry({
    effect = 10,
    category = 2,
    power = 0,
    moveType = 0,
    accuracy = 0,
    pp = 30,
  })
end

local function nativeInput(entries)
  return {
    versionId = "heartgold",
    moveEntries = entries,
  }
end

local function copyInventory(inventory)
  local copy = {}
  for family, bindings in pairs(inventory) do
    local familyCopy = {}
    for key, binding in pairs(bindings) do
      familyCopy[key] = binding
    end
    copy[family] = familyCopy
  end
  return copy
end

local function removeFirstKeyed(bindings, candidates)
  for _, candidate in ipairs(candidates) do
    if bindings[candidate] ~= nil then
      local removed = bindings[candidate]
      bindings[candidate] = nil
      return candidate, removed
    end
  end
  for key in pairs(bindings) do
    local removed = bindings[key]
    bindings[key] = nil
    return key, removed
  end
  return nil, nil
end

local function assertNamedFlags(flags, moveKey)
  Assert.isTrue(type(flags) == "table", moveKey .. " must carry a named flag table")
  for name, value in pairs(flags) do
    Assert.isTrue(type(name) == "string" and name ~= "", moveKey .. " flag names must be strings")
    Assert.isTrue(type(value) == "boolean", moveKey .. " flag " .. name .. " must be a boolean")
  end
end

function T.move_facts_keep_identity_numbers_and_carry_typed_execution_metadata()
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local compiled = assert(
    BattleDataCompiler.compile(nativeInput({ [33] = tackleEntry(), [14] = swordsDanceEntry() }), {
      inventory = BattleSources,
    })
  )
  local tackle = assert(compiled.moves["TACKLE"], "move 33 must resolve to TACKLE")
  Assert.equal(tackle.power, 35, "TACKLE keeps its source power")
  Assert.equal(tackle.accuracy, 95, "TACKLE keeps its source accuracy")
  Assert.equal(tackle.basePp, 35, "TACKLE keeps its source PP under the retained field name")
  Assert.equal(tackle.moveType, "normal", "type id 0 resolves to the lower-case source key")
  Assert.equal(tackle.priority, 0, "TACKLE keeps its source priority")
  Assert.isTrue(type(tackle.behavior.key) == "string" and tackle.behavior.key ~= "", "TACKLE needs a bound behavior key")
  Assert.isTrue(type(tackle.behavior.params) == "table", "TACKLE needs behavior parameters")
  Assert.isTrue(type(tackle.target) == "string" and tackle.target ~= "", "TACKLE needs a named target")
  assertNamedFlags(tackle.flags, "TACKLE")
  local dance = assert(compiled.moves["SWORDS_DANCE"], "move 14 must resolve to SWORDS_DANCE")
  Assert.equal(dance.power, 0, "a stat-stage move keeps its zero power instead of gaining a default")
  Assert.equal(dance.accuracy, 0, "a bypass move keeps its zero accuracy instead of gaining a default")
  Assert.equal(dance.basePp, 30, "SWORDS_DANCE keeps its source PP")
  Assert.isTrue(
    dance.behavior.key ~= tackle.behavior.key,
    "distinct native effects must not collapse onto one behavior key"
  )
  assert(BattleDataSchema.assertBattleData(compiled) ~= false, "the compiled facts pass the semantic schema")
  Assert.isTrue(
    BattleDataCompiler.validateCoverage(BattleSources) ~= false,
    "the complete native inventory passes coverage"
  )
end

function T.truncated_entries_and_unknown_references_fail_before_publication()
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local short = tackleEntry():sub(1, 15)
  Assert.equal(#short, 15, "the truncated fixture must be one byte short of the 16-byte entry")
  local compiled, shortErr = BattleDataCompiler.compile(nativeInput({ [33] = short }), {
    inventory = BattleSources,
  })
  Assert.isNil(compiled, "a truncated entry must not compile")
  local typed = assert(shortErr, "a truncated entry must report a typed error")
  Assert.isTrue(type(typed.code) == "string", "the size failure must carry an error code")
  Assert.isTrue(
    tostring(typed.message):find("33", 1, true) ~= nil,
    "the size failure must name the offending move identity, got: " .. tostring(typed.message)
  )
  local badType = moveEntry({
    effect = 0,
    category = 0,
    power = 35,
    moveType = 99,
    accuracy = 95,
    pp = 35,
  })
  local badCompiled, badErr = BattleDataCompiler.compile(nativeInput({ [33] = badType }), {
    inventory = BattleSources,
  })
  Assert.isNil(badCompiled, "an unknown type id must not compile")
  Assert.isTrue(
    tostring(assert(badErr, "an unknown type id must report a typed error").message):find("33", 1, true) ~= nil,
    "the reference failure must name the offending move identity"
  )
end

function T.unbound_effects_have_no_generic_fallback()
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local inventory = copyInventory(BattleSources)
  local removedKey = removeFirstKeyed(inventory.moveBindings, { "TACKLE", 33 })
  Assert.notNil(removedKey, "the inventory fixture must carry a removable TACKLE move binding")
  local compiled, err = BattleDataCompiler.compile(nativeInput({ [33] = tackleEntry() }), {
    inventory = inventory,
  })
  Assert.isNil(compiled, "a move without a binding must not compile into a fallback")
  Assert.isTrue(
    tostring(assert(err, "an unbound effect must report a typed error").message):find("TACKLE", 1, true) ~= nil,
    "the coverage failure must name the unbound move identity"
  )
end

function T.complete_inventory_passes_and_each_removal_names_its_owner()
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  Assert.isTrue(
    BattleDataCompiler.validateCoverage(BattleSources) ~= false,
    "the complete native inventory passes coverage"
  )
  Assert.isNil(BattleSources.moveBindings["NONE"], "the NONE sentinel is not a usable binding")
  local cases = {
    { family = "moveBindings", candidates = { "TACKLE", 33 }, identity = "TACKLE" },
    { family = "abilityBindings", candidates = { "STENCH", 1 }, identity = "STENCH" },
    { family = "heldItemBindings", candidates = { "LEFTOVERS", 234 }, identity = "LEFTOVERS" },
  }
  for _, case in ipairs(cases) do
    local inventory = copyInventory(BattleSources)
    local removed = removeFirstKeyed(inventory[case.family], case.candidates)
    Assert.notNil(removed, "the inventory fixture must carry a removable " .. case.identity .. " binding")
    local ok, err = pcall(BattleDataCompiler.validateCoverage, inventory)
    Assert.isFalse(ok, "removing the " .. case.identity .. " binding must fail coverage")
    Assert.isTrue(
      tostring(err):find(case.identity, 1, true) ~= nil,
      "the coverage failure must name " .. case.identity .. ", got: " .. tostring(err)
    )
  end
end

function T.loading_needs_neither_a_native_decoder_nor_the_dump()
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local compiled = assert(
    BattleDataCompiler.compile(nativeInput({ [33] = tackleEntry(), [14] = swordsDanceEntry() }), {
      inventory = BattleSources,
    })
  )
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local paths = BattleDataCache.paths()
  cacheFs:writeLua(assert(paths.battleData, "the cache must publish a battle-data path"), compiled)
  local realRequire = require
  local poisoned = false
  local function guardedRequire(name)
    if type(name) == "string" and name:find("^romdump%.") ~= nil then
      poisoned = true
      error("runtime load must not import native producer code: " .. name, 0)
    end
    return realRequire(name)
  end
  local loaded
  local ok, loadErr = xpcall(function()
    local saved = _G.require
    _G.require = guardedRequire
    local status, result = pcall(BattleDataCache.loadBattleData, cacheFs)
    _G.require = saved
    if not status then
      error(result, 0)
    end
    loaded = result
  end, function(failure)
    _G.require = realRequire
    return failure
  end)
  Assert.isTrue(ok, "loading staged battle data must succeed without native imports: " .. tostring(loadErr))
  Assert.isFalse(poisoned, "the load path must never reach for native producer code")
  Assert.deepEqual(loaded, compiled, "the loaded facts must exactly match the compiled facts")
  assert(BattleDataSchema.assertBattleData(loaded) ~= false, "the loaded facts still pass the semantic schema")
end

function T.move_id_bounds_reject_sentinels_and_overflow()
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local first = assert(
    BattleDataCompiler.compile(nativeInput({ [1] = tackleEntry() }), { inventory = BattleSources })
  )
  Assert.notNil(first.moves["POUND"], "move 1 resolves to POUND")
  local last = assert(
    BattleDataCompiler.compile(nativeInput({ [467] = tackleEntry() }), { inventory = BattleSources })
  )
  Assert.notNil(last.moves["SHADOW_FORCE"], "move 467 resolves to SHADOW_FORCE")
  local sentinel, sentinelErr = BattleDataCompiler.compile(nativeInput({ [0] = tackleEntry() }), {
    inventory = BattleSources,
  })
  Assert.isNil(sentinel, "the NONE sentinel is not a compilable move")
  Assert.isTrue(
    tostring(assert(sentinelErr, "sentinel input must report a typed error").message):find("0", 1, true) ~= nil,
    "the sentinel failure names its identity"
  )
  local overflow, overflowErr = BattleDataCompiler.compile(nativeInput({ [468] = tackleEntry() }), {
    inventory = BattleSources,
  })
  Assert.isNil(overflow, "past-range identities never compile")
  Assert.isTrue(
    tostring(assert(overflowErr, "overflow input must report a typed error").message):find("468", 1, true) ~= nil,
    "the overflow failure names its identity"
  )
end

function T.extreme_values_survive_projection_exactly()
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local entry = moveEntry({
    effect = 65535,
    category = 1,
    power = 255,
    moveType = 10,
    accuracy = 100,
    pp = 40,
    effectChance = 100,
    range = 65535,
    priority = -128,
  })
  local compiled = assert(
    BattleDataCompiler.compile(nativeInput({ [53] = entry }), { inventory = BattleSources })
  )
  local facts = assert(compiled.moves["FLAMETHROWER"], "move 53 resolves to FLAMETHROWER")
  Assert.equal(facts.power, 255, "maximum power survives")
  Assert.equal(facts.accuracy, 100, "maximum accuracy survives")
  Assert.equal(facts.basePp, 40, "maximum PP survives")
  Assert.equal(facts.priority, -128, "minimum priority survives the signed wrap")
  Assert.equal(facts.moveType, "fire", "type id 10 resolves to fire")
  Assert.equal(facts.effect, 65535, "maximum effect id survives")
  Assert.equal(facts.range, 65535, "maximum range survives")
  Assert.equal(facts.effectChance, 100, "maximum effect chance survives")
  local wrapped = assert(
    BattleDataCompiler.compile(nativeInput({ [33] = moveEntry({
      effect = 0,
      category = 0,
      power = 35,
      moveType = 0,
      accuracy = 95,
      pp = 35,
      priority = 255,
    }) }), { inventory = BattleSources })
  )
  Assert.equal(wrapped.moves["TACKLE"].priority, -1, "priority byte 255 wraps to -1")
  assert(BattleDataSchema.assertBattleData(compiled) ~= false, "extreme facts pass the semantic schema")
end

function T.unknown_categories_fail_while_compilation_stays_repeatable()
  local BattleDataCompiler = require("romdump.src.digest.battle.BattleDataCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local bad = moveEntry({
    effect = 0,
    category = 99,
    power = 35,
    moveType = 0,
    accuracy = 95,
    pp = 35,
  })
  local compiled, err = BattleDataCompiler.compile(nativeInput({ [33] = bad }), { inventory = BattleSources })
  Assert.isNil(compiled, "an unknown damage category must not compile")
  Assert.isTrue(
    tostring(assert(err, "an unknown category must report a typed error").message):find("33", 1, true) ~= nil,
    "the category failure names the move identity"
  )
  local input = nativeInput({ [33] = tackleEntry(), [14] = swordsDanceEntry() })
  local first = assert(BattleDataCompiler.compile(input, { inventory = BattleSources }))
  local second = assert(BattleDataCompiler.compile(input, { inventory = BattleSources }))
  Assert.deepEqual(second, first, "compilation is a pure function of its input and inventory")
  Assert.isTrue(BattleSources.moveBindings["TACKLE"] ~= nil, "a failed compile leaves the inventory untouched")
end

-- Species weight projection: member 1 of the pokedex weight NARC is an s32
-- array indexed by species id carrying hectograms
-- (src/battle/battle_command.c GetMonWeight). The vector below is a
-- hand-built table in that layout, never bytes copied from a dump.
local function s32entry(value)
  local unsigned = value
  if unsigned < 0 then
    unsigned = unsigned + 4294967296
  end
  return string.char(
    unsigned % 256,
    math.floor(unsigned / 256) % 256,
    math.floor(unsigned / 65536) % 256,
    math.floor(unsigned / 16777216) % 256
  )
end

local function weightTableWith(entries)
  local MonSources = require("romdump.src.config.MonSources")
  local parts = {}
  for speciesId = 0, MonSources.MAX_SPECIES do
    parts[#parts + 1] = s32entry(entries[speciesId] or (100 + speciesId))
  end
  return table.concat(parts)
end

function T.species_weights_decode_as_species_indexed_hectograms()
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local MonSources = require("romdump.src.config.MonSources")
  local member = weightTableWith({ [0] = 69, [1] = 69, [2] = 130 })
  Assert.equal(#member, (MonSources.MAX_SPECIES + 1) * 4, "the fixture spans one s32 per species")
  local weights = assert(
    MonCatalogCompiler.decodeWeightTable(member, { archive = "zukan_data", memberId = 1 })
  )
  Assert.equal(weights[0], 69, "species 0 keeps its source weight")
  Assert.equal(weights[1], 69, "species 1 keeps its source weight")
  Assert.equal(weights[2], 130, "species 2 keeps its source weight")
  Assert.equal(
    weights[MonSources.MAX_SPECIES],
    100 + MonSources.MAX_SPECIES,
    "the last species keeps its source weight"
  )
  local count = 0
  for _ in pairs(weights) do
    count = count + 1
  end
  Assert.equal(count, MonSources.MAX_SPECIES + 1, "every species id resolves exactly once")
end

function T.species_weight_tables_reject_truncation_and_negative_weights()
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local short = weightTableWith({}):sub(1, -5)
  local truncated, sizeErr = MonCatalogCompiler.decodeWeightTable(short, {
    archive = "zukan_data",
    memberId = 1,
  })
  Assert.isNil(truncated, "a truncated weight table must not decode")
  local typedSize = assert(sizeErr, "a truncated table must report a typed error")
  Assert.equal(typedSize.code, "MON_WEIGHT_BAD_SIZE")
  local ragged, raggedErr =
    MonCatalogCompiler.decodeWeightTable(weightTableWith({}) .. "\0", {
      archive = "zukan_data",
      memberId = 1,
    })
  Assert.isNil(ragged, "a table with a trailing byte must not decode")
  Assert.equal(assert(raggedErr, "ragged input must report a typed error").code, "MON_WEIGHT_BAD_SIZE")
  local corrupt = weightTableWith({ [5] = -1 })
  local negative, valueErr = MonCatalogCompiler.decodeWeightTable(corrupt, {
    archive = "zukan_data",
    memberId = 1,
  })
  Assert.isNil(negative, "a negative weight is corrupt input and must not decode")
  local typedValue = assert(valueErr, "a negative weight must report a typed error")
  Assert.equal(typedValue.code, "MON_WEIGHT_BAD_VALUE")
  Assert.isTrue(
    tostring(typedValue.message):find("5", 1, true) ~= nil,
    "the value failure must name the offending species index, got: " .. tostring(typedValue.message)
  )
end

-- Item throw facts: struct ItemData bytes carry pluckEffect@4,
-- flingEffect@5, flingPower@6, naturalGiftPower@7, and the bitfield u16@8
-- with naturalGiftType:5 at bits 0-4 (include/item.h). Hand-built member,
-- never dump bytes.
function T.item_fling_and_natural_gift_decode_from_source_bytes()
  local ItemCatalogCompiler = require("romdump.src.digest.items.ItemCatalogCompiler")
  local giftType = 10
  local fieldPocket = 4
  local word = giftType + fieldPocket * 128
  local member = string.char(
      100,
      0,
      0,
      0,
      1,
      2,
      30,
      60,
      word % 256,
      math.floor(word / 256) % 256,
      0,
      0,
      0,
      0
    ) .. string.rep("\0", 20)
  Assert.equal(#member, 34, "the fixture spans one full item_data row")
  local decoded = assert(
    ItemCatalogCompiler.decodeItemData(member, { archive = "item_data", memberId = 149 })
  )
  Assert.equal(decoded.flingEffect, 2, "flingEffect decodes from offset 5")
  Assert.equal(decoded.flingPower, 30, "flingPower decodes from offset 6")
  Assert.equal(decoded.naturalGiftPower, 60, "naturalGiftPower decodes from offset 7")
  Assert.equal(decoded.naturalGiftType, 10, "naturalGiftType decodes from bitfield bits 0-4")
  Assert.equal(decoded.fieldPocket, 4, "the shared word still selects the pocket")
end

return { tests = T }
