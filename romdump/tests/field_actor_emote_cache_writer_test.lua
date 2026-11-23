local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local Writer = require("romdump.src.digest.actor.FieldActorEmoteCacheWriter")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = { tests = {} }

---@param cacheFs table<string, unknown>
---@param bundle table<string, unknown>
---@return string marker
local function publish(cacheFs, bundle)
  return (
    ResidentArtifactFixture.publish(cacheFs, "field-emotes", "global", function(artifact)
      return Writer.stage(artifact, bundle)
    end)
  )
end

local MESH_BANK = "G4GX-bank-bytes"
local TEXTURE_BANK = "G4TX-bank-bytes"

local function modelAsset()
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-emote:exclamation",
    kind = "static",
    batches = {
      {
        geometry = { file = FieldEmoteAssetCache.geometryPath("mesh-key"), drawIndex = 0 },
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 5,
        fogEnabled = false,
      },
    },
    materials = {
      {
        id = 0,
        name = "exclamation",
        texture = { file = FieldEmoteAssetCache.texturePath("texture-key"), textureName = "exclamation" },
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
end

local function model()
  return {
    schema = "g4-field-emote-v3",
    model = modelAsset(),
  }
end

T.tests["publishes field-emote descriptor and referenced assets under owned roots"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local meshPath = FieldEmoteAssetCache.geometryPath("mesh-key")
  local texturePath = FieldEmoteAssetCache.texturePath("texture-key")
  local bundle = {
    marker = "field-emotes-cache-v4:rom:dep",
    model = model(),
    meshes = { ["mesh-key"] = MESH_BANK },
    textures = { ["texture-key"] = TEXTURE_BANK },
  }
  local ok, err = pcall(publish, cache, bundle)
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(cache:exists(FieldEmoteAssetCache.exclamationDescriptorPath(), "file"))
  Assert.equal(cache:read(FieldEmoteAssetCache.markerPath()), bundle.marker)
  Assert.equal(cache:read(meshPath), MESH_BANK, "the model bank travels verbatim")
  Assert.equal(cache:read(texturePath), TEXTURE_BANK, "the texture bank travels verbatim")
end

T.tests["aborts before publication when the canonical descriptor is invalid"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ok = pcall(publish, cache, {
    marker = "field-emotes-cache-v4:rom:dep",
    model = { schema = "g4-field-emote-v3", model = {} },
    meshes = {},
    textures = {},
  })
  Assert.isFalse(ok)
  Assert.isFalse(cache:exists(FieldEmoteAssetCache.markerPath(), "file"))
  Assert.isFalse(cache:exists(FieldEmoteAssetCache.exclamationDescriptorPath(), "file"))
end

return T
