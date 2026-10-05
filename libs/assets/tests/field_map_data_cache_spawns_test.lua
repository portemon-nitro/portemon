-- Spawn landing index reader tests: resolution answers fresh records
-- for cited keys, nil for unknown keys, and corrupt generated data
-- raises instead of warping somewhere convenient. Published through the
-- real family writer over an isolated fake cache.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local Fixture = require("tests.support.FieldMapDataFixture")

local T = {}

local function publishedCache()
  local bundle, err = FieldMapDataCompiler.compileSpawnDestinations(Fixture.build())
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  bundle = assert(bundle)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMapDataCacheWriter.writeSpawnIndex(cache, bundle)
  return cache, bundle
end

local function writeIndex(cache, index)
  cache:write(FieldMapDataCache.spawnIndexPath(), LuaWriter.encode(index))
  cache:write(FieldMapDataCache.spawnIndexMarkerPath(), "test-marker")
end

local function assertInvalidDestination(cache, resolve, spawnKey)
  local ok, err = pcall(resolve, cache, spawnKey)
  Assert.isFalse(ok, "malformed generated spawn data must not resolve")
  Assert.isTrue(Errors.is(err), "invalid generated spawn data has a structured error")
end

function T.known_spawns_resolve_to_fresh_records()
  local cache = publishedCache()
  local first = assert(FieldMapDataCache.spawnDestination(cache, "SPAWN_NEW_BARK"), "mother spawn resolves")
  Assert.deepEqual(first, { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 })
  first.map = "MAP_MUTATED"
  local second = assert(FieldMapDataCache.spawnDestination(cache, "SPAWN_NEW_BARK"), "mother spawn resolves again")
  Assert.equal(second.map, "MAP_NEW_BARK", "callers receive copies, never the live record")
end

function T.known_blackout_spawns_resolve_to_fresh_records()
  local cache = publishedCache()
  local first = assert(FieldMapDataCache.blackoutDestination(cache, "SPAWN_NEW_BARK"), "mother blackout spawn resolves")
  Assert.deepEqual(first, {
    map = "MAP_NEW_BARK_PLAYER_HOUSE_1F",
    fieldX = 6,
    fieldZ = 8,
    facing = "north",
  })
  first.map = "MAP_MUTATED"
  local second =
    assert(FieldMapDataCache.blackoutDestination(cache, "SPAWN_NEW_BARK"), "mother blackout spawn resolves again")
  Assert.equal(second.map, "MAP_NEW_BARK_PLAYER_HOUSE_1F", "blackout records are copied for callers")
end

function T.unknown_spawn_keys_resolve_to_nil()
  local cache = publishedCache()
  Assert.isNil(
    FieldMapDataCache.spawnDestination(cache, "SPAWN_NOWHERE"),
    "an uncited spawn is nil for the caller to refuse loudly"
  )
end

function T.missing_index_raises_for_rebuild()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ok, err = pcall(function()
    FieldMapDataCache.spawnDestination(cache, "SPAWN_NEW_BARK")
  end)
  Assert.isFalse(ok, "a missing index must not resolve")
  Assert.isTrue(Errors.is(err))
end

function T.malformed_index_raises_for_rebuild()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(FieldMapDataCache.spawnIndexPath(), LuaWriter.encode({ schema = "stale-schema", spawns = {} }))
  local ok, err = pcall(function()
    FieldMapDataCache.spawnDestination(cache, "SPAWN_NEW_BARK")
  end)
  Assert.isFalse(ok, "a malformed index must not resolve")
  Assert.isTrue(Errors.is(err))
end

function T.old_outdoor_only_spawn_index_is_not_ready_or_readable()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeIndex(cache, {
    schema = "g4-field-spawn-index-v1",
    spawns = { SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 } },
  })

  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "v1 lacks blackout records")
  assertInvalidDestination(cache, FieldMapDataCache.spawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")
end

function T.v2_spawn_index_requires_well_formed_blackout_destinations()
  local cache, bundle = publishedCache()
  local index = bundle.index

  local missing = { schema = index.schema, spawns = index.spawns }
  writeIndex(cache, missing)
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "blackout namespace is required")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")

  writeIndex(cache, { schema = index.schema, blackoutSpawns = index.blackoutSpawns })
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "outdoor namespace is required")
  assertInvalidDestination(cache, FieldMapDataCache.spawnDestination, "SPAWN_NEW_BARK")

  local malformedBlackout = {}
  for spawnKey, destination in pairs(index.blackoutSpawns) do
    malformedBlackout[spawnKey] = destination
  end
  malformedBlackout.SPAWN_NEW_BARK = {
    map = "MAP_NEW_BARK_PLAYER_HOUSE_1F",
    fieldX = 6,
    fieldZ = 8,
  }
  writeIndex(cache, {
    schema = index.schema,
    spawns = index.spawns,
    blackoutSpawns = malformedBlackout,
  })
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "malformed facing is rejected")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")
end

return { tests = T }
