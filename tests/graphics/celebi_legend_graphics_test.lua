-- Exercises the generated Celebi model through its real GPU model path.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local CelebiTimeTravelRenderer = require("libs.hgss.src.presentation.CelebiTimeTravelRenderer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function status(frame)
  return {
    active = true,
    modelVisible = true,
    animationFrame = frame,
    swirlFrame = nil,
    modelPosition = { x = 12.5, y = 3, z = -8 },
    blurActive = false,
    sequence = 1,
  }
end

local function freshGame(versionId)
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = { mapSymbol = "MAP_NEW_BARK", fieldX = 10, fieldZ = 10, facing = "south" },
    playerData = {
      profile = {
        name = "GOLD",
        gender = 0,
        trainerId = 1,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
      },
      options = { textSpeed = "fastest", textFrame = 1 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(versionId),
    bag = require("libs.hgss.src.save.BagSave").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
end

local T = GraphicsSmoke.suite({
  ["FieldState captures its composed world, legend, and billboards"] = function(scope)
    local versionId = readyVersions()[1]
    Assert.notNil(versionId, "a ready imported game version is required")
    local state = FieldState.new(freshGame(versionId), {
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    })
    local scene = state.runtime.celebiTimeTravelScene
    local originalSceneStatus = scene.status
    scope:own({
      release = function()
        scene.status = originalSceneStatus
        state:dispose()
      end,
    })
    for _ = 1, 120 do
      if state.runtime.session.mapEntryStage == nil then
        break
      end
      state:draw()
      state:update(1 / 60)
    end
    Assert.isNil(state.runtime.session.mapEntryStage, "production field entry settles before capture")
    local sceneStatus = status(30)
    sceneStatus.blurActive = true
    sceneStatus.swirlFrame = 1
    scene.status = function()
      return sceneStatus
    end

    local graphics = love.graphics
    local width, height = state.runtime.viewport.width, state.runtime.viewport.height
    local target = scope:own(graphics.newCanvas(width, height, { format = "rgba8", readable = true, dpiscale = 1 }))
    graphics.setCanvas(target)
    graphics.clear(0, 0, 0, 1)
    state:draw()
    graphics.setCanvas()

    Assert.notNil(state._celebiBlur, "the production field draw enters its capture presenter")
    Assert.notNil(state._celebiBlur._scene, "FieldState captures into its transient scene target")
    Assert.notNil(state._celebiBlur._historyA, "FieldState publishes native feedback history")
    Assert.isTrue(#state.worldParts[12] > 0, "the real field queue includes the animated legend")
    Assert.isTrue(#state.spriteItems > 0, "the real field draw includes billboard actors")
    Assert.isTrue(
      state.presentationResources.renderer.stats.geometrySubmissions > 0,
      "the real field renderer submits captured world geometry"
    )

    local pixels = target:newImageData()
    local varied = false
    local first = { pixels:getPixel(128, 96) }
    for _, point in ipairs({ { 32, 32 }, { 128, 64 }, { 224, 160 } }) do
      local pixel = { pixels:getPixel(point[1], point[2]) }
      varied = varied or pixel[1] ~= first[1] or pixel[2] ~= first[2] or pixel[3] ~= first[3]
    end
    pixels:release()
    graphics.setCanvas()
    Assert.isTrue(varied, "the production-composed field capture reaches the framebuffer")
  end,
  ["original Celebi model draws with three source-clocked clips"] = function(scope)
    local versions = readyVersions()
    Assert.isTrue(#versions > 0, "a ready imported game version is required")
    for _, versionId in ipairs(versions) do
      local cache = CacheFs.forVersion(versionId)
      local record = assert(cache:loadLua(FieldEffectAssetCache.definitionPath("celebi_time_travel")))
      Assert.isTrue(type(record.model) == "table", versionId .. " publishes the Celebi model")
      local definition = ModelDefinition.fromNitroDescriptor(record.model, { key = "field-effect:celebi_time_travel" })
      local joint = assert(definition:animation("celebi.joint"))
      local pattern = assert(definition:animation("celebi.pattern"))
      local srt = assert(definition:animation("celebi.srt"))
      Assert.equal(pattern.name, joint.name, "pattern clip retains the shared Nitro dictionary name")
      Assert.equal(srt.name, joint.name, "SRT clip retains the shared Nitro dictionary name")
      local presenter = scope:own(CelebiTimeTravelRenderer.new(cache))
      local firstItems = presenter:drawItems(status(0))
      Assert.isTrue(#firstItems > 0, "the source model produces 3D draw items at frame zero")
      Assert.isTrue(firstItems[1].worldSpace, "the model enters the world render queue")
      Assert.equal(firstItems[1].fieldEffect, "celebi_time_travel", "draw items retain semantic diagnostics")
      local first = firstItems[1]
      local initial = {}
      for index, item in ipairs(firstItems) do
        initial[index] = {
          transform = { table.unpack(item.transform) },
          image = item.material and item.material.image,
          texMatrix = item.material and { table.unpack(item.material.texMatrix) } or nil,
        }
      end
      local repeatedItems = presenter:drawItems(status(0))
      Assert.equal(repeatedItems[1].transform[13], first.transform[13], "repeated draw does not advance X")

      local changed = false
      for frame = 1, 210 do
        local frameItems = presenter:drawItems(status(frame))
        Assert.isTrue(#frameItems > 0, "the model remains drawable during its beat")
        for itemIndex, item in ipairs(frameItems) do
          local initialItem = initial[itemIndex]
          local matrixChanged = false
          for index = 1, #initialItem.transform do
            if item.transform[index] ~= initialItem.transform[index] then
              matrixChanged = true
              break
            end
          end
          local textureChanged = item.material ~= nil and item.material.image ~= initialItem.image
          local uvChanged = false
          if item.material ~= nil and initialItem.texMatrix ~= nil then
            for index = 1, #initialItem.texMatrix do
              if item.material.texMatrix[index] ~= initialItem.texMatrix[index] then
                uvChanged = true
                break
              end
            end
          end
          changed = changed or matrixChanged or textureChanged or uvChanged
        end
      end
      Assert.isTrue(changed, "source animation changes model pose or material state")

      local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
      local camera = FieldCamera.new(cameraProfiles.profiles[0], { canonicalAspect = 4 / 3 })
      local renderer = scope:own(FieldRenderer.new({ clearColor = { 0, 0, 0, 1 } }))
      local viewport = FieldViewport.new(256, 192, { mode = "strict" })
      local target = scope:own(love.graphics.newCanvas(256, 192))
      local edgeColors, fogTable = {}, {}
      for index = 0, 7 do
        edgeColors[index] = 0
      end
      for index = 1, 32 do
        fogTable[index] = 0
      end
      love.graphics.setCanvas(target)
      renderer:draw({
        edgeColors = edgeColors,
        fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
      }, camera, { presenter:drawItems(status(210)) }, nil, viewport, 0, 3)
      love.graphics.setCanvas()
      Assert.isTrue(renderer.stats.geometrySubmissions > 0, "Celebi reaches the real field graphics draw")
    end
  end,
}, { capabilities = { "graphics", "derived_assets" } })
T.metadata.derivedAssets = {
  "audio-bank:700",
  "audio-bank:702",
  "audio-bank:709",
  "audio-bank:750",
  "field-effects:global",
  "field-runtime",
  "map-data:31",
  "map-data:33",
  "map-data:47",
  "map-data:48",
  "map-data:60",
  "map:60",
}

return T
