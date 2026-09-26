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

function T.known_spawns_resolve_to_fresh_records()
  local cache = publishedCache()
  local first = assert(FieldMapDataCache.spawnDestination(cache, "SPAWN_NEW_BARK"), "mother spawn resolves")
  Assert.deepEqual(first, { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 })
  first.map = "MAP_MUTATED"
  local second = assert(FieldMapDataCache.spawnDestination(cache, "SPAWN_NEW_BARK"), "mother spawn resolves again")
  Assert.equal(second.map, "MAP_NEW_BARK", "callers receive copies, never the live record")
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

return { tests = T }
