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

function T.special_destinations_resolve_to_fresh_records()
  Assert.isTrue(
    type(FieldMapDataCache.specialSpawnDestination) == "function",
    "the cache exposes a special destination reader"
  )
  local cache = publishedCache()
  local first = assert(FieldMapDataCache.specialSpawnDestination(cache, "SPAWN_NEW_BARK"), "mother special resolves")
  Assert.equal(first.warpId, -1, "special records carry the unset warp id")
  Assert.equal(first.direction, "south", "special records carry the standard arrival facing")
  first.map = "MAP_MUTATED"
  local second =
    assert(FieldMapDataCache.specialSpawnDestination(cache, "SPAWN_NEW_BARK"), "mother special resolves again")
  Assert.isTrue(second.map ~= "MAP_MUTATED", "special records are copied for callers")
  Assert.isNil(
    FieldMapDataCache.specialSpawnDestination(cache, "SPAWN_NOWHERE"),
    "an uncited special spawn is nil for the caller to refuse loudly"
  )
end

function T.divergent_special_records_stay_distinct_from_death_and_outdoor()
  Assert.isTrue(
    type(FieldMapDataCache.specialSpawnDestination) == "function",
    "the cache exposes a special destination reader"
  )
  local cache = publishedCache()
  local frontierSpecial = assert(FieldMapDataCache.specialSpawnDestination(cache, "SPAWN_FRONTIER"))
  Assert.deepEqual(frontierSpecial, {
    map = "MAP_ROUTE_40",
    fieldX = 237,
    fieldZ = 267,
    warpId = -1,
    direction = "south",
  })
  local pokeathlonSpecial = assert(FieldMapDataCache.specialSpawnDestination(cache, "SPAWN_POKEATHLON"))
  Assert.deepEqual(pokeathlonSpecial, {
    map = "MAP_ROUTE_35",
    fieldX = 362,
    fieldZ = 267,
    warpId = -1,
    direction = "south",
  })
  local frontierDeath = assert(FieldMapDataCache.blackoutDestination(cache, "SPAWN_FRONTIER"))
  Assert.equal(frontierDeath.map, "MAP_FRONTIER_ACCESS_POKECENTER_1F", "death relocation is unchanged")
  local pokeathlonDeath = assert(FieldMapDataCache.blackoutDestination(cache, "SPAWN_POKEATHLON"))
  Assert.equal(pokeathlonDeath.map, "MAP_POKEATHLON_DOME", "pokeathlon death relocation is unchanged")
  local frontierOutdoor = assert(FieldMapDataCache.spawnDestination(cache, "SPAWN_FRONTIER"))
  Assert.equal(frontierOutdoor.map, "MAP_BATTLE_FRONTIER_FRONTIER_ACCESS", "outdoor return is unchanged")
end

function T.special_namespace_validator_rejects_malformed_records()
  Assert.isTrue(
    type(FieldMapDataCache.hasSpecialSpawnDestinations) == "function",
    "the cache exposes a special namespace validator"
  )
  Assert.isFalse(FieldMapDataCache.hasSpecialSpawnDestinations(nil), "no table is no namespace")
  Assert.isFalse(FieldMapDataCache.hasSpecialSpawnDestinations({}), "an empty table is no namespace")
  local function valid()
    return { SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" } }
  end
  Assert.isTrue(FieldMapDataCache.hasSpecialSpawnDestinations(valid()))
  local missingMap = valid()
  missingMap.SPAWN_NEW_BARK.map = ""
  Assert.isFalse(FieldMapDataCache.hasSpecialSpawnDestinations(missingMap))
  local negativeTile = valid()
  negativeTile.SPAWN_NEW_BARK.fieldX = -1
  Assert.isFalse(FieldMapDataCache.hasSpecialSpawnDestinations(negativeTile))
  local fractionalTile = valid()
  fractionalTile.SPAWN_NEW_BARK.fieldZ = 1.5
  Assert.isFalse(FieldMapDataCache.hasSpecialSpawnDestinations(fractionalTile))
  local wrongWarp = valid()
  wrongWarp.SPAWN_NEW_BARK.warpId = "-1"
  Assert.isFalse(FieldMapDataCache.hasSpecialSpawnDestinations(wrongWarp))
  local wrongWarpValue = valid()
  wrongWarpValue.SPAWN_NEW_BARK.warpId = 3
  Assert.isFalse(FieldMapDataCache.hasSpecialSpawnDestinations(wrongWarpValue))
  local badDirection = valid()
  badDirection.SPAWN_NEW_BARK.direction = "north"
  Assert.isFalse(FieldMapDataCache.hasSpecialSpawnDestinations(badDirection))
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
  assertInvalidDestination(cache, FieldMapDataCache.specialSpawnDestination, "SPAWN_NEW_BARK")
end

function T.old_two_namespace_spawn_index_is_not_ready_or_readable()
  local cache, bundle = publishedCache()
  local index = bundle.index
  writeIndex(cache, { schema = index.schema, spawns = index.spawns, blackoutSpawns = index.blackoutSpawns })
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "a two-namespace index is stale")
  assertInvalidDestination(cache, FieldMapDataCache.spawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.specialSpawnDestination, "SPAWN_NEW_BARK")
end

function T.current_index_requires_all_three_well_formed_namespaces()
  local cache, bundle = publishedCache()
  local index = bundle.index

  local missingBlackout = { schema = index.schema, spawns = index.spawns, specialSpawns = index.specialSpawns }
  writeIndex(cache, missingBlackout)
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "blackout namespace is required")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.spawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.specialSpawnDestination, "SPAWN_NEW_BARK")

  writeIndex(cache, { schema = index.schema, blackoutSpawns = index.blackoutSpawns, specialSpawns = index.specialSpawns })
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "outdoor namespace is required")
  assertInvalidDestination(cache, FieldMapDataCache.spawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.specialSpawnDestination, "SPAWN_NEW_BARK")

  writeIndex(cache, { schema = index.schema, spawns = index.spawns, blackoutSpawns = index.blackoutSpawns })
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "special namespace is required")
  assertInvalidDestination(cache, FieldMapDataCache.specialSpawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.spawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")

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
    specialSpawns = index.specialSpawns,
  })
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "malformed facing is rejected")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.spawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.specialSpawnDestination, "SPAWN_NEW_BARK")

  local malformedSpecial = {}
  for spawnKey, destination in pairs(index.specialSpawns) do
    malformedSpecial[spawnKey] = destination
  end
  malformedSpecial.SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397, warpId = 0, direction = "south" }
  writeIndex(cache, {
    schema = index.schema,
    spawns = index.spawns,
    blackoutSpawns = index.blackoutSpawns,
    specialSpawns = malformedSpecial,
  })
  Assert.isFalse(FieldMapDataCache.isSpawnIndexReady(cache, "test-marker"), "a set warp id is rejected")
  assertInvalidDestination(cache, FieldMapDataCache.specialSpawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.spawnDestination, "SPAWN_NEW_BARK")
  assertInvalidDestination(cache, FieldMapDataCache.blackoutDestination, "SPAWN_NEW_BARK")
end

function T.spawn_index_writer_refuses_a_partial_namespace_bundle()
  local _, bundle = publishedCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local partial = {
    schema = bundle.index.schema,
    spawns = bundle.index.spawns,
    blackoutSpawns = bundle.index.blackoutSpawns,
  }
  local ok, err =
    pcall(FieldMapDataCacheWriter.writeSpawnIndex, cache, { index = partial, marker = bundle.marker })
  Assert.isFalse(ok, "a bundle without the special namespace must not publish")
  Assert.isTrue(Errors.is(err), "the refused publish carries a structured error")
end

return { tests = T }
