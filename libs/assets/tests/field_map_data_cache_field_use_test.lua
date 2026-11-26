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
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = {}

local function compile(map)
  local bundle, err = FieldMapDataCompiler.compile(Fixture.build(), map or 60)
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  return assert(bundle)
end

local function publishedCache(bundle)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  ResidentArtifactFixture.publish(cache, "map-data", tostring(bundle.mapId), function(artifact)
    return FieldMapDataCacheWriter.stage(artifact, bundle)
  end)
  return cache
end

function T.current_policy_passes_readiness()
  local bundle = compile(60)
  Assert.isTrue(FieldMapDataCache.hasFieldUsePolicy(bundle.field.fieldUse))
  Assert.isTrue(FieldMapDataCache.hasEncounterMember(bundle.field.wildEncounterMemberId))
  Assert.isTrue(FieldMapDataCache.isReady(publishedCache(bundle), 60, bundle.marker))
end

function T.absent_encounter_member_fails_readiness()
  local bundle = compile(60)
  bundle.field.wildEncounterMemberId = nil
  local cache = publishedCache(bundle)
  Assert.isFalse(FieldMapDataCache.hasEncounterMember(nil))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.absent_or_partial_move_encounter_records_fail_readiness()
  local bundle = compile(60)
  Assert.isTrue(FieldMapDataCache.hasRockSmash(bundle.field.rockSmash))
  Assert.isTrue(FieldMapDataCache.hasHeadbutt(bundle.field.headbutt))
  Assert.isFalse(FieldMapDataCache.hasRockSmash(nil))
  Assert.isFalse(FieldMapDataCache.hasRockSmash({ odds = 101, items = bundle.field.rockSmash.items }))
  Assert.isFalse(FieldMapDataCache.hasRockSmash({ odds = 5, items = { "MAX_ETHER" } }))
  Assert.isFalse(FieldMapDataCache.hasHeadbutt(nil))
  Assert.isFalse(FieldMapDataCache.hasHeadbutt({ regularTrees = {}, secretTrees = {} }))
  for _, field in ipairs({ "rockSmash", "headbutt" }) do
    local broken = compile(60)
    broken.field[field] = nil
    -- The stage proves its own marker, so a record missing its move policy is
    -- published but never reads ready.
    local cache = publishedCache(broken)
    Assert.isFalse(FieldMapDataCache.isReady(cache, 60, broken.marker), field)
  end
end

function T.absent_policy_fails_readiness()
  local bundle = compile(60)
  bundle.field.fieldUse = nil
  local cache = publishedCache(bundle)
  Assert.isFalse(FieldMapDataCache.hasFieldUsePolicy(nil))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.partial_policy_fails_readiness()
  local bundle = compile(60)
  bundle.field.fieldUse.cave = nil
  Assert.isFalse(FieldMapDataCache.hasFieldUsePolicy(bundle.field.fieldUse))
  local cache = publishedCache(bundle)
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

-- A produced trainer object carries its closed subject record (native
-- identity, engagement-pair slot, authored sight, shared approach scene) and
-- the map carries its native region. Both are generated-data contracts: a
-- record with an extra key, a broken identity, or no region is corruption and
-- fails readiness instead of reading as an untrained object or an unknown
-- region.
local function trainerBundle()
  local Builder = require("tests.support.ZoneEventsBuilder")
  local member = Builder.build({
    objectEvents = {
      {
        objectEventId = 5,
        spriteId = 348,
        movement = 0,
        type = 1,
        eventFlag = 0,
        scriptId = 3046,
        facingDirection = 1,
        param0 = 3,
        param1 = 0,
        param2 = 0,
        xRange = 0,
        yRange = 0,
        x = 4,
        z = 6,
        y = 0,
      },
    },
  })
  local bundle, err = FieldMapDataCompiler.compile(Fixture.build({ zoneEventsMember = member }), 60)
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  return assert(bundle)
end

function T.trainer_subject_and_region_pass_readiness()
  local bundle = trainerBundle()
  local object = assert(bundle.field.events.objects[1])
  Assert.equal(object.trainer.trainerId, 47)
  Assert.isTrue(FieldMapDataCache.hasRequiredEvents(bundle.field.events))
  Assert.isTrue(FieldMapDataCache.hasRegion(bundle.field.region))
  Assert.isTrue(FieldMapDataCache.isReady(publishedCache(bundle), 60, bundle.marker))
end

function T.malformed_trainer_subject_fails_readiness()
  local mutations = {
    function(trainer)
      trainer.extra = 1
    end,
    function(trainer)
      trainer.partner = "third"
    end,
    function(trainer)
      trainer.trainerId = 0
    end,
    function(trainer)
      trainer.approachScript = nil
    end,
    function(trainer)
      trainer.sightType = 4
    end,
  }
  for index, mutate in ipairs(mutations) do
    local bundle = trainerBundle()
    mutate(bundle.field.events.objects[1].trainer)
    Assert.isFalse(FieldMapDataCache.hasRequiredEvents(bundle.field.events), "mutation " .. index)
    Assert.isFalse(FieldMapDataCache.isReady(publishedCache(bundle), 60, bundle.marker), "mutation " .. index)
  end
end

function T.absent_region_fails_readiness()
  local bundle = compile(60)
  bundle.field.region = nil
  local cache = publishedCache(bundle)
  Assert.isFalse(FieldMapDataCache.hasRegion(nil))
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
