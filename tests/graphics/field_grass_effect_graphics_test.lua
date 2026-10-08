-- Real generated grass presentation through the model, material, and GPU
-- paths. The assertions inspect stable material identity and a real draw.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController")
local FieldTerrainEffectRenderer = require("libs.hgss.src.presentation.FieldTerrainEffectRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local Matrix4 = require("libs.math.src.Matrix4")
local RomImporter = require("romdump.src.source.RomImporter")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local function updateWithOwner(controller, owner)
  local update = controller.updateFixed
  ---@cast update fun(self: table, owner: table)
  return update(controller, owner)
end

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

local function runVersion(scope, versionId)
  local cache = CacheFs.forVersion(versionId)
  local index = assert(cache:loadLua(FieldEffectAssetCache.indexPath()))
  local assets = { effects = {} }
  for _, kind in ipairs({ "tall_grass", "very_tall_grass", "trainer_reveal" }) do
    assets.effects[kind] = assert(cache:loadLua(index.effects[kind].path))
  end

  Assert.equal(Contract.fieldEffects.cacheFormat, "field-effect-cache-v9")
  local pool = scope:own(GpuAssetPool.new(cache))
  local renderer = FieldTerrainEffectRenderer.new(assets, pool)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local controller = FieldTerrainEffectController.new({
    effects = assets.effects,
    modelFactory = function(kind)
      return renderer:newInstance(kind)
    end,
  })
  local runtimeMap = {
    projectPhysicalPoint = function()
      return { worldX = 0, worldY = 0, worldZ = 0 }
    end,
  }
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
  local effectKind = "tall_grass"

  for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
    effectKind = kind
    controller:clear()
    controller:emit({
      kind = effectKind,
      fieldX = 0,
      fieldZ = 0,
      worldY = 0,
      cellKey = "0:0",
      sourceSurfaceId = 0,
    })
    local firstItems = renderer:drawItems(controller:status(), runtimeMap)
    Assert.isTrue(#firstItems > 0, kind .. " must produce a real draw item at frame zero")
    local firstImage = firstItems[1].material.image
    local changed = false
    local frameItems = firstItems
    for _ = 1, 12 do
      updateWithOwner(controller, { fieldX = 0, fieldZ = 0, facing = "north" })
      frameItems = renderer:drawItems(controller:status(), runtimeMap)
      Assert.isTrue(#frameItems > 0, kind .. " must remain drawable during its intro")
      if frameItems[1].material.image ~= firstImage then
        changed = true
      end
    end
    Assert.isTrue(changed, kind .. " must change its effective material during the intro")
    local heldImage = frameItems[1].material.image
    for _ = 1, 3 do
      updateWithOwner(controller, { fieldX = 0, fieldZ = 0, facing = "north" })
    end
    local heldItems = renderer:drawItems(controller:status(), runtimeMap)
    Assert.isTrue(#heldItems > 0, kind .. " must remain drawable after the intro")
    Assert.equal(heldItems[1].material.image, heldImage, kind .. " must hold its final material")

    love.graphics.setCanvas(target)
    fieldRenderer:draw(sceneRuntime(), camera, { heldItems }, nil, viewport, 0, 3)
    love.graphics.setCanvas()
    Assert.isTrue(fieldRenderer.stats.geometrySubmissions > 0, kind .. " must reach a real graphics draw")
  end
end

local function loadEffectAssets(cache)
  local index = assert(cache:loadLua(FieldEffectAssetCache.indexPath()))
  local assets = { effects = {} }
  for _, kind in ipairs({ "tall_grass", "very_tall_grass", "trainer_reveal" }) do
    assets.effects[kind] = assert(cache:loadLua(index.effects[kind].path))
  end
  return assets
end

local function composedEffects(scope, versionId)
  local cache = CacheFs.forVersion(versionId)
  local assets = loadEffectAssets(cache)
  local pool = scope:own(GpuAssetPool.new(cache))
  local renderer = FieldTerrainEffectRenderer.new(assets, pool)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local controller = FieldTerrainEffectController.new({
    effects = assets.effects,
    modelFactory = function(kind)
      return renderer:newInstance(kind)
    end,
  })
  return assets, renderer, controller
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local T = GraphicsSmoke.suite({
  ["generated grass changes material and remains drawable at its held frame"] = function(scope)
    local versions = 0
    for _, versionId in ipairs(GameVersion.ORDER) do
      if RomImporter.isReady(versionId) then
        versions = versions + 1
        runVersion(scope, versionId)
      end
    end
    Assert.isTrue(versions > 0, "a ready imported game version is required")
  end,
  ["streamed effect keeps its source-projected anchor"] = function(scope)
    for _, versionId in ipairs(readyVersions()) do
      local assets, renderer, controller = composedEffects(scope, versionId)
      local calls = {}
      local runtimeMap = {
        projectPhysicalPoint = function(_, fieldX, fieldZ, cellKey, sourceSurfaceId)
          calls[#calls + 1] = {
            fieldX = fieldX,
            fieldZ = fieldZ,
            cellKey = cellKey,
            sourceSurfaceId = sourceSurfaceId,
          }
          return { worldX = 11, worldY = 22, worldZ = 33 }
        end,
      }
      controller:emit({
        kind = "tall_grass",
        fieldX = 0,
        fieldZ = 0,
        worldY = 99,
        cellKey = "0:0",
        sourceSurfaceId = 0,
      })
      local items = renderer:drawItems(controller:status(), runtimeMap)
      Assert.isTrue(#items > 0, "a streamed effect must produce a real draw item")
      Assert.equal(#calls, 1, "stable projection must consult the physical projector exactly once")
      Assert.deepEqual(calls[1], {
        fieldX = 0,
        fieldZ = 0,
        cellKey = "0:0",
        sourceSurfaceId = 0,
      })
      local offset = assets.effects.tall_grass.placementOffset
      local transform = assert(controller:status().instances[1]).modelInstance.transform
      Assert.deepEqual(
        transform,
        Matrix4.translate(11 + offset.x, 22 + offset.y, 33 + offset.z),
        "the draw transform must use the projected position rather than the stored world height"
      )
    end
    Assert.isTrue(#readyVersions() > 0, "a ready imported game version is required")
  end,
  ["local effect renders from committed coordinates without source projection"] = function(scope)
    for _, versionId in ipairs(readyVersions()) do
      local assets, renderer, controller = composedEffects(scope, versionId)
      local runtimeMap = {
        coordinateOrigin = { x = 1, z = 2 },
        collision = {
          containsLocal = function()
            return true
          end,
        },
      }
      Assert.isNil(
        runtimeMap.projectPhysicalPoint,
        "the local map must expose no physical projector"
      )
      controller:emit({ kind = "tall_grass", fieldX = 4, fieldZ = 6, worldY = 3 })
      local items = renderer:drawItems(controller:status(), runtimeMap)
      Assert.isTrue(#items > 0, "a local effect must produce a real draw item")
      Assert.equal(items[1].fieldEffect, "tall_grass", "the draw item must carry the emitted effect kind")
      local gridX, gridZ = FieldGrid.tileCenterToWorld(4 - 1, 6 - 2)
      local offset = assets.effects.tall_grass.placementOffset
      local transform = assert(controller:status().instances[1]).modelInstance.transform
      Assert.deepEqual(
        transform,
        Matrix4.translate(gridX + offset.x, 3 + offset.y, gridZ + offset.z),
        "the draw transform must convert the committed local anchor rather than project a source surface"
      )
    end
    Assert.isTrue(#readyVersions() > 0, "a ready imported game version is required")
  end,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "field-effects:global", "field-camera:global" }
T.metadata.tags = { "field", "grass", "materials" }
return T
