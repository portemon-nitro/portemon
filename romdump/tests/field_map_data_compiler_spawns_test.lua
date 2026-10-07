-- Spawn landing index compiler tests: the family-level teleport record
-- projects every cited producer destination with the current schema, and
-- the bundle marker binds the ROM identity and the content hash through
-- the real production compiler and writer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMoveSources = require("romdump.src.config.FieldMoveSources")
local Fixture = require("tests.support.FieldMapDataFixture")

local T = {}

local function compile()
  local bundle, err = FieldMapDataCompiler.compileSpawnDestinations(Fixture.build())
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  return assert(bundle)
end

local function publishedCache(bundle)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMapDataCacheWriter.writeSpawnIndex(cache, bundle)
  return cache
end

function T.spawn_index_carries_the_current_schema_and_all_destinations()
  local bundle = compile()
  Assert.equal(bundle.index.schema, FieldMapDataCache.SPAWN_INDEX_SCHEMA)
  Assert.isFalse(bundle.index.schema == "g4-field-spawn-index-v1", "the old outdoor-only contract is stale")
  Assert.isTrue(FieldMapDataCache.hasSpawnDestinations(bundle.index.spawns))
  local count = 0
  for _ in pairs(bundle.index.spawns) do
    count = count + 1
  end
  Assert.equal(count, 30, "all thirty cited spawns publish")
end

function T.spawn_index_compiles_separate_north_facing_blackout_destinations()
  local bundle = compile()
  local blackoutSpawns = assert(bundle.index.blackoutSpawns, "the current schema publishes blackout destinations")
  local count = 0
  for spawnKey, source in pairs(FieldMoveSources.BLACKOUT_DESTINATIONS) do
    local compiled = assert(blackoutSpawns[spawnKey], "compiled blackout record exists for " .. spawnKey)
    Assert.deepEqual(compiled, source, spawnKey .. " preserves its semantic destination")
    Assert.equal(compiled.facing, "north", spawnKey .. " uses source north facing")
    count = count + 1
  end
  Assert.equal(count, 30, "all semantic death destinations compile")

  local compiledCount = 0
  for spawnKey in pairs(blackoutSpawns) do
    Assert.notNil(FieldMoveSources.BLACKOUT_DESTINATIONS[spawnKey], "no extra blackout key is compiled")
    compiledCount = compiledCount + 1
  end
  Assert.equal(compiledCount, count, "source and compiled blackout keys have parity")
  Assert.deepEqual(bundle.index.spawns.SPAWN_NEW_BARK, {
    map = "MAP_NEW_BARK",
    fieldX = 695,
    fieldZ = 397,
  }, "the existing outdoor return record remains independent")
  Assert.deepEqual(blackoutSpawns.SPAWN_NEW_BARK, {
    map = "MAP_NEW_BARK_PLAYER_HOUSE_1F",
    fieldX = 6,
    fieldZ = 8,
    facing = "north",
  })
  Assert.deepEqual(blackoutSpawns.SPAWN_CHERRYGROVE, {
    map = "MAP_CHERRYGROVE_POKECENTER_1F",
    fieldX = 8,
    fieldZ = 13,
    facing = "north",
  })
end

function T.spawn_index_publishes_independent_south_facing_special_destinations()
  local bundle = compile()
  Assert.equal(bundle.index.schema, "g4-field-spawn-index-v3", "the spawn family carries the special namespace")
  local specialSpawns = bundle.index.specialSpawns
  Assert.notNil(specialSpawns, "the compiled index carries special destinations")
  assert(type(specialSpawns) == "table")
  local count = 0
  for spawnKey in pairs(FieldMoveSources.SPAWN_DESTINATIONS) do
    local compiled = specialSpawns[spawnKey]
    Assert.notNil(compiled, "compiled special record exists for " .. spawnKey)
    assert(type(compiled) == "table")
    Assert.isTrue(type(compiled.map) == "string" and compiled.map ~= "", spawnKey .. " names a map")
    Assert.isTrue(
      type(compiled.fieldX) == "number" and compiled.fieldX % 1 == 0 and compiled.fieldX >= 0,
      spawnKey .. " carries a tile x"
    )
    Assert.isTrue(
      type(compiled.fieldZ) == "number" and compiled.fieldZ % 1 == 0 and compiled.fieldZ >= 0,
      spawnKey .. " carries a tile z"
    )
    Assert.equal(compiled.warpId, -1, spawnKey .. " uses the unset warp id")
    Assert.equal(compiled.direction, "south", spawnKey .. " uses the standard arrival facing")
    count = count + 1
  end
  Assert.equal(count, 30, "all thirty semantic spawn keys publish a special record")
  local compiledCount = 0
  for spawnKey in pairs(specialSpawns) do
    Assert.notNil(FieldMoveSources.SPAWN_DESTINATIONS[spawnKey], "no extra special key is compiled")
    compiledCount = compiledCount + 1
  end
  Assert.equal(compiledCount, count, "outdoor and special keys have parity")
end

function T.spawn_index_pins_divergent_special_records()
  local bundle = compile()
  local specialSpawns = assert(bundle.index.specialSpawns, "the compiled index carries special destinations")
  Assert.deepEqual(specialSpawns.SPAWN_FRONTIER, {
    map = "MAP_ROUTE_40",
    fieldX = 237,
    fieldZ = 267,
    warpId = -1,
    direction = "south",
  }, "the frontier special record leaves the fly GND outside")
  Assert.deepEqual(specialSpawns.SPAWN_POKEATHLON, {
    map = "MAP_ROUTE_35",
    fieldX = 362,
    fieldZ = 267,
    warpId = -1,
    direction = "south",
  }, "the pokeathlon special record leaves the dome outside")
  Assert.equal(specialSpawns.SPAWN_GOLDENROD.map, "MAP_GOLDENROD")
  Assert.equal(specialSpawns.SPAWN_ECRUTEAK.map, "MAP_ECRUTEAK")
  Assert.equal(specialSpawns.SPAWN_OLIVINE.map, "MAP_OLIVINE")
  Assert.equal(specialSpawns.SPAWN_CIANWOOD.map, "MAP_CIANWOOD")
  Assert.deepEqual(bundle.index.spawns.SPAWN_FRONTIER, {
    map = "MAP_BATTLE_FRONTIER_FRONTIER_ACCESS",
    fieldX = 8,
    fieldZ = 15,
  }, "the outdoor fly record is unchanged")
  Assert.deepEqual(bundle.index.spawns.SPAWN_POKEATHLON, {
    map = "MAP_POKEATHLON_DOME",
    fieldX = 42,
    fieldZ = 23,
  }, "the pokeathlon fly record is unchanged")
end

function T.spawn_index_marker_hash_covers_the_special_namespace()
  local seen = nil
  local bundle, err = FieldMapDataCompiler.compileSpawnDestinations(Fixture.build(), function(value)
    seen = value
    return "test-hash"
  end)
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  Assert.notNil(seen, "the marker hash observes the compiled namespaces")
  assert(type(seen) == "table")
  Assert.notNil(seen.spawns, "the marker hash covers outdoor destinations")
  Assert.notNil(seen.blackoutSpawns, "the marker hash covers blackout destinations")
  Assert.notNil(seen.specialSpawns, "the marker hash covers special destinations")
end

function T.spawn_index_keeps_source_rows_five_through_eight_on_semantic_keys()
  local blackoutSpawns = compile().index.blackoutSpawns
  Assert.equal(blackoutSpawns.SPAWN_GOLDENROD.map, "MAP_GOLDENROD_POKECENTER_1F")
  Assert.equal(blackoutSpawns.SPAWN_ECRUTEAK.map, "MAP_ECRUTEAK_POKECENTER_1F")
  Assert.equal(blackoutSpawns.SPAWN_OLIVINE.map, "MAP_OLIVINE_POKECENTER_1F")
  Assert.equal(blackoutSpawns.SPAWN_CIANWOOD.map, "MAP_CIANWOOD_POKECENTER_1F")
end

function T.spawn_index_pins_mother_and_updated_history()
  local bundle = compile()
  Assert.deepEqual(bundle.index.spawns.SPAWN_NEW_BARK, { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 })
  Assert.deepEqual(bundle.index.spawns.SPAWN_GOLDENROD, { map = "MAP_GOLDENROD", fieldX = 352, fieldZ = 369 })
end

function T.spawn_index_marker_binds_rom_and_content()
  local bundle = compile()
  Assert.equal(type(bundle.marker), "string")
  Assert.notNil(bundle.marker:find("rom-sha", 1, true), "the marker names the ROM identity")
  Assert.isTrue(
    FieldMapDataCache.isSpawnIndexReady(publishedCache(bundle), bundle.marker),
    "the published index passes readiness under its own marker"
  )
end

function T.spawn_index_rejects_stale_markers_and_partial_records()
  local bundle = compile()
  local cache = publishedCache(bundle)
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "stale-marker"), "a stale marker never reads as ready")
  Assert.isFalse(FieldMapDataCache.hasSpawnDestinations(nil), "no table is no index")
  Assert.isFalse(FieldMapDataCache.hasSpawnDestinations({}), "an empty table is no index")
  local partial = { SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695 } }
  Assert.isFalse(FieldMapDataCache.hasSpawnDestinations(partial), "a destination without tiles is malformed")
end

return { tests = T }
