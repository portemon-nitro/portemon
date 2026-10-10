-- FieldMapDataCache field-use readiness tests: the v10 record requires
-- the semantic field-use policy; an absent or partial policy fails
-- readiness instead of reading as an empty feature. Scenarios compile
-- through the real production compiler and publish through the real
-- family writer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local Fixture = require("tests.support.FieldMapDataFixture")

local T = {}

local function compile(map)
  local bundle, err = FieldMapDataCompiler.compile(Fixture.build(), map or 60)
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  return assert(bundle)
end

local function publishedCache(bundle)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMapDataCacheWriter.write(cache, bundle)
  return cache
end

function T.current_policy_passes_readiness()
  local bundle = compile(60)
  Assert.equal(bundle.field.schema, "g4-field-map-v13")
  Assert.isTrue(FieldMapDataCache.hasFieldUsePolicy(bundle.field.fieldUse))
  Assert.isTrue(FieldMapDataCache.hasEncounterMember(bundle.field.wildEncounterMemberId))
  Assert.isTrue(FieldMapDataCache.isReady(publishedCache(bundle), 60, bundle.marker))
end

function T.absent_encounter_member_fails_readiness()
  local bundle = compile(60)
  bundle.field.wildEncounterMemberId = nil
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMapDataCacheWriter.write(cache, bundle)
  Assert.isFalse(FieldMapDataCache.hasEncounterMember(nil))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.absent_policy_fails_readiness()
  local bundle = compile(60)
  bundle.field.fieldUse = nil
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMapDataCacheWriter.write(cache, bundle)
  Assert.isFalse(FieldMapDataCache.hasFieldUsePolicy(nil))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.partial_policy_fails_readiness()
  local bundle = compile(60)
  bundle.field.fieldUse.cave = nil
  Assert.isFalse(FieldMapDataCache.hasFieldUsePolicy(bundle.field.fieldUse))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMapDataCacheWriter.write(cache, bundle)
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.old_schema_fails_readiness()
  local bundle = compile(60)
  bundle.field.schema = "g4-field-map-v10"
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(FieldMapDataCache.fieldPath(60), LuaWriter.encode(bundle.field))
  cache:write(FieldMapDataCache.dependenciesPath(60), LuaWriter.encode(bundle.dependencies))
  cache:write(FieldMapDataCache.markerPath(60), bundle.marker)
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

return { tests = T }
