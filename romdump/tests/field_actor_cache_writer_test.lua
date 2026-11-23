-- Marker-last transaction tests for the field-actor cache writer, against an
-- in-memory cache and a synthetic bundle. Covers readiness, rollback on a failed
-- write, and the incomplete-bundle rejection.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorCacheWriter = require("romdump.src.digest.actor.FieldActorCacheWriter")
local ApricornSources = require("romdump.src.config.ApricornSources")

local T = {}

local FieldActorFixture = require("tests.support.FieldActorFixture")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local function visual(spriteId)
  return FieldActorFixture.visual(spriteId, { frameCount = 8 })
end

local AVATAR_STATE_KEYS = {
  "walking",
  "cycling",
  "surfing",
  "rocket",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

local function avatarCapability(id, gender, spriteIds)
  local states = {}
  for i, name in ipairs(AVATAR_STATE_KEYS) do
    states[name] = spriteIds[((i - 1) % #spriteIds) + 1]
  end
  return { id = id, gender = gender, states = states }
end

local function bundle(spriteIds)
  local visuals, atlases = {}, {}
  local indexedSpriteIds = {}
  for _, spriteId in ipairs(spriteIds) do
    indexedSpriteIds[#indexedSpriteIds + 1] = spriteId
  end
  for spriteId = 262, 276 do
    indexedSpriteIds[#indexedSpriteIds + 1] = spriteId
  end
  for _, spriteId in ipairs(indexedSpriteIds) do
    visuals[spriteId] = visual(spriteId)
    atlases[spriteId] = { width = 4, height = 1, pixels = string.rep("\0", 16) }
  end
  visuals[ApricornSources.depletedTreeSpriteId].gestures = {
    apricorn_tree_wiggle = {
      pose = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
    apricorn_tree_expel = {
      pose = { frames = { { frameIndex = 1, ticks = 1 } }, loop = false, durationTicks = 1 },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
  }
  return {
    marker = FieldActorCache.marker("abc", "dep"),
    index = {
      schema = FieldActorCache.INDEX_SCHEMA,
      romVersion = "heartgold",
      spriteIds = indexedSpriteIds,
      variableSprites = {},
      recordCount = 3,
      runtime = {
        avatars = { avatarCapability("hero", 0, spriteIds), avatarCapability("heroine", 1, spriteIds) },
        variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
        apricorn = {
          depletedTreeSpriteId = ApricornSources.depletedTreeSpriteId,
          treeSpriteIdByKey = ApricornSources.treeSpriteIdByKey,
          fruitSpriteIdByKey = ApricornSources.fruitSpriteIdByKey,
        },
      },
    },
    visuals = visuals,
    atlases = atlases,
    provenance = { schema = "g4-field-actor-provenance-v1" },
    dependencies = {},
  }
end

function T.writes_visuals_atlases_and_marker()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0, 29 })
  Assert.equal(
    ResidentArtifactFixture.publish(cache, "actors", "global", function(artifact)
      return FieldActorCacheWriter.stage(artifact, b)
    end),
    b.marker
  )
  Assert.isTrue(FieldActorCache.isReady(cache, b.marker), "ready after write")
  Assert.isTrue(cache:exists(FieldActorCache.atlasPath(29), "file"))
  Assert.equal(cache:loadLua(FieldActorCache.visualPath(0)).spriteId, 0)
  Assert.deepEqual(cache:loadLua(FieldActorCache.indexPath()).runtime.avatars, b.index.runtime.avatars)
end

function T.is_not_ready_for_a_different_marker()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0 })
  ResidentArtifactFixture.publish(cache, "actors", "global", function(artifact)
    return FieldActorCacheWriter.stage(artifact, b)
  end)
  Assert.isFalse(FieldActorCache.isReady(cache, FieldActorCache.marker("abc", "other")))
end

function T.is_not_ready_when_an_atlas_is_missing()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0, 29 })
  ResidentArtifactFixture.publish(cache, "actors", "global", function(artifact)
    return FieldActorCacheWriter.stage(artifact, b)
  end)
  cache:remove(FieldActorCache.atlasPath(29))
  Assert.isFalse(FieldActorCache.isReady(cache, b.marker))
end

function T.rejects_a_bundle_missing_an_indexed_sprite()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0 })
  b.index.spriteIds = { 0, 99 }
  local err = Assert.throws(function()
    ResidentArtifactFixture.publish(cache, "actors", "global", function(artifact)
      return FieldActorCacheWriter.stage(artifact, b)
    end)
  end)
  Assert.isTrue(Errors.is(err), "expected an Errors object")
  Assert.equal(err.code, "FIELD_ACTOR_BUNDLE_INCOMPLETE")
  Assert.isNil(cache:read(FieldActorCache.markerPath()))
end

function T.rolls_back_the_actor_subtree_on_a_failed_write()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local original = backend.write
  backend.write = function(self, path, data)
    if path:find("0029.png", 1, true) then
      error("injected write failure")
    end
    return original(self, path, data)
  end
  Assert.throws(function()
    ResidentArtifactFixture.publish(cache, "actors", "global", function(artifact)
      return FieldActorCacheWriter.stage(artifact, bundle({ 0, 29 }))
    end)
  end)
  Assert.isNil(cache:read(FieldActorCache.markerPath()))
  Assert.isFalse(cache:exists(FieldActorCache.visualPath(0), "file"), "a partial build leaves no visual behind")
end

function T.failed_rebuild_preserves_the_previous_artifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local first = bundle({ 0, 29 })
  ResidentArtifactFixture.publish(cache, "actors", "global", function(artifact)
    return FieldActorCacheWriter.stage(artifact, first)
  end)
  -- A rebuild whose bundle cannot produce a complete class fails while it
  -- stages: the private output is discarded and the published class keeps
  -- both its marker and its payload.
  local second = bundle({ 0, 29 })
  second.marker = FieldActorCache.marker("abc", "new-dep")
  second.visuals[29] = nil
  local failed = ResidentArtifactFixture.new(cache, "actors", "global")
  Assert.throws(function()
    FieldActorCacheWriter.stage(failed, second)
  end)
  failed:abort()
  Assert.isTrue(FieldActorCache.isReady(cache, first.marker), "the previous artifact remains ready")
  Assert.equal(cache:loadLua(FieldActorCache.visualPath(29)).spriteId, 29)
  Assert.equal(cache:read(FieldActorCache.markerPath()), first.marker, "the new marker never reached the live tree")
  local retry = bundle({ 0, 29 })
  retry.marker = FieldActorCache.marker("abc", "new-dep")
  ResidentArtifactFixture.publish(cache, "actors", "global", function(artifact)
    return FieldActorCacheWriter.stage(artifact, retry)
  end)
  Assert.isTrue(FieldActorCache.isReady(cache, retry.marker), "a successful retry publishes the new artifact")
end

return { tests = T }
