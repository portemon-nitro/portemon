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
  local blackoutSpawns = assert(bundle.index.blackoutSpawns, "v2 publishes blackout destinations")
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
