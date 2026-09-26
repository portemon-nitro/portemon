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
  Assert.equal(bundle.index.schema, "g4-field-spawn-index-v1")
  Assert.equal(bundle.index.schema, FieldMapDataCache.SPAWN_INDEX_SCHEMA)
  Assert.isTrue(FieldMapDataCache.hasSpawnDestinations(bundle.index.spawns))
  local count = 0
  for _ in pairs(bundle.index.spawns) do
    count = count + 1
  end
  Assert.equal(count, 30, "all thirty cited spawns publish")
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
