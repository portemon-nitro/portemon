-- Real follower-transition presentation through the model, material,
-- and GPU paths. Both source effect phases render from the generated
-- transition definition with no substitute geometry, and each phase reaches
-- a real draw. Frame timing stays with the semantic lifecycle tests; this
-- suite proves the exact resources are renderable.

local Assert = require("tests.support.Assert")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local SelectedAssetRuntimeFixture = require("tests.support.SelectedAssetRuntimeFixture")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local FollowingMonTransitionRenderer = require("libs.hgss.src.presentation.FollowingMonTransitionRenderer")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local RomImporter = require("romdump.src.source.RomImporter")

local function sceneRuntime()
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  return {
    mapDraws = {},
    buildingDraws = {},
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
end

local function runtimeMap()
  return {
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function()
        return true
      end,
    },
  }
end

local function runVersion(scope, versionId)
  local cache = GeneratedCacheFixture.reader(versionId)
  local index = assert(cache:loadLua(FieldEffectAssetCache.indexPath()))
  local entry = assert(index.effects.follower_transition, "the generated index must carry the transition effect")
  local compiled = assert(cache:loadLua(entry.path), "the generated transition definition must load")
  Assert.isTrue(type(compiled.models) == "table", "the transition definition carries its source models")
  Assert.isTrue(type(compiled.placementOffset) == "table", "the transition definition carries its placement")

  -- The session image owner borrows the selected CPU pair: one worker and one

  -- decoded budget for the test lifetime, released after the pool.

  local imagePoolRuntime = SelectedAssetRuntimeFixture.new(cache, scope)

  local imagePool =
    ImageAssetPool.new(cache, { queue = imagePoolRuntime.preparationQueue, decoded = imagePoolRuntime.decoded })
  scope:own({
    release = function()
      imagePool:dispose()
    end,
  })
  local pool = scope:own(GpuAssetPool.new(cache, { imageAssets = imagePool }))
  local renderer = FollowingMonTransitionRenderer.new({ transition = compiled }, pool)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local camera = FieldCamera.new(cameraProfiles.profiles[0], { canonicalAspect = 4 / 3 })
  local fieldRenderer = FieldRenderer.new({ clearColor = { 0.1, 0.2, 0.3, 1 } })
  scope:own({
    release = function()
      fieldRenderer:release()
    end,
  })
  local viewport = FieldViewport.new(256, 192, { mode = "strict" })
  local target = scope:own(love.graphics.newCanvas(256, 192))
  local map = runtimeMap()

  for _, phase in ipairs({ "prelude", "animated", "recall_ball" }) do
    local part = phase == "animated" and "animated" or "initial"
    local instances = {}
    local balls = {}
    if phase == "recall_ball" then
      balls[1] = {
        visible = true,
        fieldX = 2,
        fieldZ = 5,
        worldY = 3,
        offset = { x = 1, y = 15 / 16, z = -12 / 16 },
      }
    else
      instances[1] = {
        phase = phase,
        fieldX = 2,
        fieldZ = 5,
        worldY = 3,
        initialInstance = renderer:newInstance("initial"),
        animatedInstance = renderer:newInstance("animated"),
      }
    end
    local items = renderer:drawItems({ instances = instances, balls = balls }, map)
    Assert.isTrue(#items > 0, phase .. " must produce a real draw item from generated resources")
    Assert.equal(items[1].transitionPart, part, phase .. " must draw its own source part")
    love.graphics.setCanvas(target)
    fieldRenderer:draw(sceneRuntime(), camera, { items }, nil, viewport, 0, 3)
    love.graphics.setCanvas()
    Assert.isTrue(fieldRenderer.stats.geometrySubmissions > 0, phase .. " must reach a real graphics draw")
  end
end

local T = GraphicsSmoke.suite({
  ["generated transition renders both source phases and reaches a real draw"] = function(scope)
    local versions = 0
    for _, versionId in ipairs(GameVersion.ORDER) do
      if RomImporter.isReady(versionId) then
        versions = versions + 1
        runVersion(scope, versionId)
      end
    end
    Assert.isTrue(versions > 0, "a ready imported game version is required")
  end,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "field-effects:global", "field-camera:global" }
T.metadata.tags = { "field", "transition", "materials" }
return T
