-- Synthetic encounter-table projection: hand-built native encounter members
-- (pret/pokeheartgold include/wild_encounter.h EncounterData, 0xC4 bytes)
-- decode through the encounter compiler into version-specific semantic
-- tables, ordered slots never merge, radio/swarm/night-fishing replacements
-- keep pointing at their original native slots and game, and truncated or
-- unknown members fail with attributed errors. Vectors are specified here
-- from the source layout; they are never produced by the compiler.

local Assert = require("tests.support.Assert")

local T = {}

local MEMBER_SIZE = 0xC4
local LAND_SLOTS = 12
local SURF_SLOTS = 5
local ROCK_SLOTS = 2
local ROD_SLOTS = 5

local function u8(v)
  return string.char(v % 256)
end

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function repeatByte(value, count)
  local bytes = {}
  for _ = 1, count do
    bytes[#bytes + 1] = u8(value)
  end
  return table.concat(bytes)
end

local function u16List(values)
  local bytes = {}
  for _, value in ipairs(values) do
    bytes[#bytes + 1] = u16(value)
  end
  return table.concat(bytes)
end

-- One water/rock/rod slot: level_min u8, level_max u8, species u16.
local function waterSlot(minLevel, maxLevel, speciesId)
  return u8(minLevel) .. u8(maxLevel) .. u16(speciesId)
end

-- Builds a complete 0xC4-byte member. Land levels are shared across times
-- of day; each time of day carries its own twelve-species array.
local function encounterMember(fields)
  local landLevels = fields.landLevels or repeatByte(5, LAND_SLOTS)
  local parts = {
    u8(fields.walkRate or 20),
    u8(fields.surfRate or 10),
    u8(fields.rockRate or 0),
    u8(fields.oldRate or 15),
    u8(fields.goodRate or 20),
    u8(fields.superRate or 25),
    u8(0),
    u8(0),
    landLevels,
    u16List(fields.morning or {}),
    u16List(fields.day or {}),
    u16List(fields.night or {}),
    u16List(fields.radioHoenn or { 0, 0 }),
    u16List(fields.radioSinnoh or { 0, 0 }),
  }
  for _, slot in ipairs(fields.surf or {}) do
    parts[#parts + 1] = waterSlot(slot[1], slot[2], slot[3])
  end
  for _, slot in ipairs(fields.rock or {}) do
    parts[#parts + 1] = waterSlot(slot[1], slot[2], slot[3])
  end
  for _, slot in ipairs(fields.oldRod or {}) do
    parts[#parts + 1] = waterSlot(slot[1], slot[2], slot[3])
  end
  for _, slot in ipairs(fields.goodRod or {}) do
    parts[#parts + 1] = waterSlot(slot[1], slot[2], slot[3])
  end
  for _, slot in ipairs(fields.superRod or {}) do
    parts[#parts + 1] = waterSlot(slot[1], slot[2], slot[3])
  end
  parts[#parts + 1] = u16(fields.landSwarm or 0)
  parts[#parts + 1] = u16(fields.surfSwarm or 0)
  parts[#parts + 1] = u16(fields.nightFish or 0)
  parts[#parts + 1] = u16(fields.fishSwarm or 0)
  return table.concat(parts)
end

local function defaultWaters(speciesId)
  local slots = {}
  for _ = 1, SURF_SLOTS do
    slots[#slots + 1] = { 10, 20, speciesId }
  end
  return slots
end

local function defaultRocks(speciesId)
  return { { 15, 25, speciesId }, { 20, 30, speciesId } }
end

local function defaultRods(speciesId)
  local slots = {}
  for _ = 1, ROD_SLOTS do
    slots[#slots + 1] = { 5, 15, speciesId }
  end
  return slots
end

local function baseFields(overrides)
  local fields = {
    morning = { 16, 16, 19, 19, 25, 25, 41, 41, 74, 74, 16, 19 },
    day = { 16, 16, 19, 19, 25, 25, 41, 41, 74, 74, 16, 19 },
    night = { 19, 19, 41, 41, 41, 41, 16, 16, 74, 74, 19, 41 },
    radioHoenn = { 25, 16 },
    radioSinnoh = { 19, 41 },
    surf = defaultWaters(72),
    rock = defaultRocks(74),
    oldRod = defaultRods(129),
    goodRod = defaultRods(129),
    superRod = defaultRods(129),
  }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  return fields
end

local function nativeInput(versionId, members)
  return { versionId = versionId, members = members }
end

function T.member_layout_matches_the_native_record_size()
  local member = encounterMember(baseFields())
  Assert.equal(#member, MEMBER_SIZE, "the synthetic member must fill the 0xC4-byte native record")
end

function T.version_tables_keep_their_own_replacement_slots()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local heartgold = encounterMember(baseFields({ landSwarm = 25, surfSwarm = 72, nightFish = 129, fishSwarm = 72 }))
  local soulsilver = encounterMember(baseFields({ landSwarm = 16, surfSwarm = 129, nightFish = 72, fishSwarm = 129 }))
  local goldCompiled = assert(EncounterCatalogCompiler.compile(nativeInput("heartgold", { [7] = heartgold })))
  local silverCompiled = assert(EncounterCatalogCompiler.compile(nativeInput("soulsilver", { [7] = soulsilver })))
  local goldTable = assert(goldCompiled.tables[7], "map member 7 must survive the heartgold projection")
  local silverTable = assert(silverCompiled.tables[7], "map member 7 must survive the soulsilver projection")
  Assert.equal(goldTable.replacements.landSwarm.species, "PIKACHU", "the heartgold swarm keeps its species")
  Assert.equal(silverTable.replacements.landSwarm.species, "PIDGEY", "the soulsilver swarm keeps its own species")
  Assert.equal(goldTable.replacements.nightFish.species, "MAGIKARP", "the heartgold night catch keeps its species")
  Assert.equal(silverTable.replacements.nightFish.species, "TENTACOOL", "the soulsilver night catch keeps its own species")
  Assert.deepEqual(goldTable.replacements.landSwarm.game, "heartgold", "replacements name their supported game")
  Assert.deepEqual(silverTable.replacements.landSwarm.game, "soulsilver", "replacements name their supported game")
  Assert.equal(#goldTable.land.morning, LAND_SLOTS, "the morning array keeps all twelve slots")
  Assert.equal(#goldTable.land.day, LAND_SLOTS, "the day array keeps all twelve slots")
  Assert.equal(#goldTable.land.night, LAND_SLOTS, "the night array keeps all twelve slots")
  Assert.equal(goldTable.rates.walking, 20, "the walking rate survives projection")
  Assert.equal(goldTable.rates.surfing, 10, "the surfing rate survives projection")
  assert(BattleDataSchema.assertEncounterCatalog(goldCompiled) ~= false, "the catalog passes the semantic schema")
  assert(BattleDataSchema.assertEncounterCatalog(silverCompiled) ~= false, "the catalog passes the semantic schema")
end

function T.equal_species_slots_stay_distinct_with_their_level_windows()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local levels = repeatByte(5, 4) .. u8(8) .. u8(8) .. repeatByte(5, 6)
  local morning = { 19, 19, 19, 19, 19, 19, 16, 16, 16, 16, 16, 16 }
  local member = encounterMember(baseFields({ landLevels = levels, morning = morning, day = morning, night = morning }))
  local compiled = assert(EncounterCatalogCompiler.compile(nativeInput("heartgold", { [7] = member })))
  local land = assert(compiled.tables[7], "map member 7 must survive projection").land
  local rattata = {}
  for index, slot in ipairs(land.morning) do
    if slot.species == "RATTATA" then
      rattata[#rattata + 1] = { index = index, slot = slot }
    end
  end
  Assert.equal(#rattata, 6, "equal-species slots must not merge")
  Assert.equal(rattata[1].slot.minLevel, 5, "the first equal-species slot keeps its level window")
  Assert.equal(rattata[1].slot.maxLevel, 5, "the first equal-species slot keeps its level window")
  Assert.equal(rattata[5].slot.minLevel, 8, "the later equal-species slot keeps its own level window")
  Assert.equal(rattata[5].slot.maxLevel, 8, "the later equal-species slot keeps its own level window")
  Assert.isTrue(rattata[1].index < rattata[5].index, "slot order follows the native order")
  for index, slot in ipairs(land.morning) do
    Assert.isTrue(slot.weight ~= nil, "slot " .. index .. " keeps its native interval weight")
  end
end

function T.replacements_point_at_their_original_native_slots()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local member = encounterMember(baseFields({ landSwarm = 25, surfSwarm = 72, nightFish = 129, fishSwarm = 72 }))
  local compiled = assert(EncounterCatalogCompiler.compile(nativeInput("soulsilver", { [7] = member })))
  local replacements = assert(compiled.tables[7], "map member 7 must survive projection").replacements
  for name, replacement in pairs(replacements) do
    Assert.isTrue(type(replacement.slot) == "number", name .. " must point at its original native slot")
    Assert.isTrue(
      replacement.slot >= 0,
      name .. " slot references use the zero-based native identity, got: " .. tostring(replacement.slot)
    )
    Assert.equal(replacement.game, "soulsilver", name .. " must name the supported game")
    Assert.isTrue(type(replacement.species) == "string", name .. " must resolve its replacement species")
  end
  Assert.notNil(replacements.landSwarm, "the land swarm replacement survives")
  Assert.notNil(replacements.surfSwarm, "the surfing swarm replacement survives")
  Assert.notNil(replacements.nightFish, "the night-fishing replacement survives")
  Assert.notNil(replacements.fishSwarm, "the fishing-swarm replacement survives")
  Assert.notNil(replacements.radioHoenn, "the radio replacement survives")
  Assert.notNil(replacements.radioSinnoh, "the radio replacement survives")
end

function T.per_method_tables_keep_rates_slots_and_levels()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local member = encounterMember(baseFields())
  local compiled = assert(EncounterCatalogCompiler.compile(nativeInput("heartgold", { [7] = member })))
  local mapTable = assert(compiled.tables[7], "map member 7 must survive projection")
  Assert.equal(#mapTable.surf, SURF_SLOTS, "surfing keeps its five slots")
  Assert.equal(#mapTable.rockSmash, ROCK_SLOTS, "rock smash keeps its two slots")
  Assert.equal(#mapTable.oldRod, ROD_SLOTS, "the old rod keeps its five slots")
  Assert.equal(#mapTable.goodRod, ROD_SLOTS, "the good rod keeps its five slots")
  Assert.equal(#mapTable.superRod, ROD_SLOTS, "the super rod keeps its five slots")
  for index, slot in ipairs(mapTable.surf) do
    Assert.equal(slot.species, "TENTACOOL", "surf slot " .. index .. " keeps its species")
    Assert.equal(slot.minLevel, 10, "surf slot " .. index .. " keeps its minimum level")
    Assert.equal(slot.maxLevel, 20, "surf slot " .. index .. " keeps its maximum level")
  end
  Assert.equal(mapTable.oldRod[1].species, "MAGIKARP", "rod slots keep their species")
  Assert.equal(mapTable.rates.oldRod, 15, "the old-rod bite rate survives")
  Assert.equal(mapTable.rates.goodRod, 20, "the good-rod bite rate survives")
  Assert.equal(mapTable.rates.superRod, 25, "the super-rod bite rate survives")
  Assert.equal(mapTable.rates.rockSmash, 0, "a zero rock-smash rate survives instead of gaining a default")
end

function T.tables_round_trip_through_the_owned_cache_paths()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local compiled = assert(
    EncounterCatalogCompiler.compile(nativeInput("heartgold", { [7] = encounterMember(baseFields()) }))
  )
  assert(BattleDataSchema.assertEncounterCatalog(compiled) ~= false, "the catalog passes the semantic schema")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local paths = BattleDataCache.paths()
  cacheFs:writeLua(assert(paths.encounters, "the cache must publish an encounter path"), compiled)
  local loaded = BattleDataCache.loadEncounters(cacheFs)
  Assert.deepEqual(loaded, compiled, "the loaded tables exactly match the compiled tables")
  local land = assert(loaded.tables[7], "map member 7 must survive the round trip").land
  Assert.equal(#land.morning, LAND_SLOTS, "the round trip keeps all twelve morning slots")
end

function T.truncated_or_unknown_members_fail_with_attributed_errors()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local member = encounterMember(baseFields())
  local short = member:sub(1, MEMBER_SIZE - 1)
  Assert.equal(#short, MEMBER_SIZE - 1, "the truncated fixture must be one byte short of 0xC4")
  local compiled, shortErr = EncounterCatalogCompiler.compile(nativeInput("heartgold", { [7] = short }))
  Assert.isNil(compiled, "a truncated member must not compile")
  Assert.isTrue(
    tostring(assert(shortErr, "a truncated member must report a typed error").message):find("7", 1, true) ~= nil,
    "the size failure must name the member identity"
  )
  local badMorning = { 16, 16, 19, 19, 25, 25, 41, 41, 74, 74, 16, 600 }
  local badCompiled, badErr = EncounterCatalogCompiler.compile(
    nativeInput("heartgold", { [7] = encounterMember(baseFields({ morning = badMorning })) })
  )
  Assert.isNil(badCompiled, "an unknown slot species must not compile")
  Assert.isTrue(
    tostring(assert(badErr, "an unknown species must report a typed error").message):find("7", 1, true) ~= nil,
    "the species failure must name the member identity"
  )
end

function T.inverted_water_level_windows_fail()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local surf = defaultWaters(72)
  surf[2] = { 20, 10, 72 }
  local compiled, err =
    EncounterCatalogCompiler.compile(nativeInput("heartgold", { [7] = encounterMember(baseFields({ surf = surf })) }))
  Assert.isNil(compiled, "an inverted water level window must not compile")
  Assert.isTrue(
    tostring(assert(err, "an inverted window must report a typed error").message):find("7", 1, true) ~= nil,
    "the level failure must name the member identity"
  )
end

function T.empty_slots_project_to_the_none_sentinel_in_order()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local fields = baseFields({ walkRate = 0 })
  fields.landLevels = repeatByte(0, LAND_SLOTS)
  fields.morning = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  fields.day = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  fields.night = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  fields.landSwarm = 0
  fields.surfSwarm = 0
  fields.nightFish = 0
  fields.fishSwarm = 0
  local compiled = assert(EncounterCatalogCompiler.compile(nativeInput("heartgold", { [7] = encounterMember(fields) })))
  local mapTable = assert(compiled.tables[7], "map member 7 must survive projection")
  Assert.equal(#mapTable.land.morning, LAND_SLOTS, "empty slots keep their count and order")
  for index, slot in ipairs(mapTable.land.morning) do
    Assert.equal(slot.species, "NONE", "empty land slot " .. index .. " projects to the NONE sentinel")
    Assert.equal(slot.minLevel, 0, "an empty slot keeps its zero minimum")
    Assert.equal(slot.maxLevel, 0, "an empty slot keeps its zero maximum")
  end
  Assert.equal(mapTable.replacements.landSwarm.species, "NONE", "an absent swarm stays the NONE sentinel")
  Assert.equal(mapTable.rates.walking, 0, "a zero walking rate survives instead of gaining a default")
end

function T.unknown_replacement_species_fail()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local compiled, err =
    EncounterCatalogCompiler.compile(nativeInput("heartgold", { [7] = encounterMember(baseFields({ landSwarm = 600 })) }))
  Assert.isNil(compiled, "an unknown swarm species must not compile")
  Assert.isTrue(
    tostring(assert(err, "an unknown swarm must report a typed error").message):find("7", 1, true) ~= nil,
    "the swarm failure must name the member identity"
  )
end

function T.high_rates_survive_without_import_clamping()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local fields = baseFields({ walkRate = 200, surfRate = 255 })
  local compiled = assert(EncounterCatalogCompiler.compile(nativeInput("soulsilver", { [7] = encounterMember(fields) })))
  local mapTable = assert(compiled.tables[7], "map member 7 must survive projection")
  Assert.equal(mapTable.rates.walking, 200, "the walking rate survives verbatim for runtime clamping")
  Assert.equal(mapTable.rates.surfing, 255, "the surfing rate survives verbatim for runtime clamping")
end

function T.encounter_projection_is_stable_across_compilations()
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local input = nativeInput("heartgold", { [7] = encounterMember(baseFields()) })
  local first = assert(EncounterCatalogCompiler.compile(input))
  local second = assert(EncounterCatalogCompiler.compile(input))
  Assert.deepEqual(second, first, "projection is a pure function of its input")
end

function T.successful_encounter_job_stages_publishes_and_reads_ready()
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local member = encounterMember(baseFields())
  local fakeRomFs = {
    version = function()
      return "soulsilver"
    end,
    metadata = function()
      return { sha1 = string.rep("b", 40) }
    end,
    openNarc = function(_, alias)
      Assert.equal(alias, "encounters", "the encounter job reads the version-neutral archive")
      return {
        memberCount = function()
          return 1
        end,
        readMember = function(_, memberId)
          Assert.equal(memberId, 0, "the single member resolves by map identity")
          return member
        end,
      }
    end,
  }
  local generationId = "encounter-success-generation"
  local stageName = "encounter-success-stage"
  local cacheFs = CacheFs.forVersion("soulsilver", FakeCache.new())
  local receipt = assert(ArtifactJobs.execute({
    kind = "encounters",
    key = "global",
    generationId = generationId,
    producerFingerprint = "encounter-success-fixture",
    stageName = stageName,
    epoch = 1,
  }, { cacheFs = cacheFs, romFs = fakeRomFs, versionId = "soulsilver" }))
  Assert.isTrue(type(receipt.result.marker) == "string", "execution seals a receipt marker")
  local staged = PreparedArtifact.open({
    cacheFs = cacheFs,
    generationId = generationId,
    epoch = 1,
    kind = "encounters",
    key = "global",
    jobKey = "encounters:global",
    stageName = stageName,
  })
  Assert.isTrue(staged:publish({
    generationId = generationId,
    epoch = 1,
    kind = "encounters",
    key = "global",
    jobKey = "encounters:global",
  }), "the staged generation publishes")
  Assert.isTrue(
    ArtifactJobs.validate(cacheFs, generationId, "encounters", "global", {}, nil),
    "the published stage reads ready"
  )
  local expected = assert(EncounterCatalogCompiler.compile(nativeInput("soulsilver", { [0] = member })))
  Assert.deepEqual(BattleDataCache.loadEncounters(cacheFs), expected, "the published tables load exactly")
end

return { tests = T }
