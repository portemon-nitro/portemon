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
local CelebiTimeTravelBlur = require("libs.hgss.src.presentation.CelebiTimeTravelBlur")
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
    scope:own({ release = function()
      scene.status = originalSceneStatus
      state:dispose()
    end })
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
    Assert.isTrue(state.presentationResources.renderer.stats.geometrySubmissions > 0,
      "the real field renderer submits captured world geometry")

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
  ["field capture recursively blends the composed main scene once per source frame"] = function(scope)
    local graphics = love.graphics
    local viewport = {
      width = 320,
      height = 240,
      worldViewport = { x = 32, y = 24, width = 256, height = 192 },
    }
    local target = scope:own(graphics.newCanvas(320, 240, { format = "rgba8", readable = true, dpiscale = 1 }))
    local blur = CelebiTimeTravelBlur.new()
    local currentColor, actorX = { 208, 0, 0 }, 64
    local function drawWorld()
      graphics.setColor(currentColor[1] / 255, currentColor[2] / 255, currentColor[3] / 255, 1)
      graphics.rectangle("fill", 32, 24, 256, 192)
      graphics.setColor(1, 1, 1, 1)
      graphics.rectangle("fill", actorX, 72, 16, 16)
    end
    local function drawFrame(frame, sequence)
      graphics.setCanvas(target)
      graphics.clear(25 / 255, 34 / 255, 43 / 255, 1)
      blur:draw({ active = true, blurActive = true, sequence = sequence or 1, swirlFrame = frame }, viewport, drawWorld)
    end
    local function pixel(x, y)
      graphics.setCanvas()
      local data = target:newImageData()
      local r, g, b, a = data:getPixel(x, y)
      data:release()
      return { r * 255, g * 255, b * 255, a * 255 }
    end
    local function near(channel, expected, message)
      Assert.near(channel, expected, 2, message)
    end

    drawFrame(1)
    local first = pixel(40, 32)
    near(first[1], 208, "first capture copies current world without old-frame residue")
    near(first[2], 0, "first capture has no prior green channel")

    currentColor, actorX = { 0, 208, 0 }, 112
    drawFrame(2)
    local second = pixel(40, 32)
    near(second[1], 169, "second capture uses thirteen parts of previous red output")
    near(second[2], 39, "second capture uses three parts of current green world")
    local actorTrail = pixel(68, 76)
    Assert.isTrue(actorTrail[1] > 190 and actorTrail[2] > 220, "the previous billboard silhouette contributes to capture")
    graphics.setCanvas(target)
    graphics.setColor(1, 0, 1, 1)
    graphics.rectangle("fill", 200, 100, 20, 20)
    local uiPixel = pixel(205, 105)
    near(uiPixel[1], 255, "UI drawn after capture remains sharp red")
    near(uiPixel[2], 0, "UI drawn after capture remains sharp green")
    near(uiPixel[3], 255, "UI drawn after capture remains sharp blue")

    drawFrame(2)
    local duplicate = pixel(40, 32)
    near(duplicate[1], 169, "repeated draw does not compound history red")
    near(duplicate[2], 39, "repeated draw does not compound history green")

    currentColor, actorX = { 0, 0, 208 }, 160
    drawFrame(3)
    local third = pixel(40, 32)
    near(third[1], 137, "third capture recursively retains blended red history")
    near(third[2], 32, "third capture recursively retains blended green history")
    near(third[3], 39, "third capture adds current blue world")
    local cleanUiHistory = pixel(205, 105)
    near(cleanUiHistory[1], 137, "prior UI red never enters capture history")
    near(cleanUiHistory[2], 32, "prior UI green never enters capture history")
    near(cleanUiHistory[3], 39, "prior UI blue never enters capture history")
    local outside = pixel(5, 5)
    near(outside[1], 25, "outside the main viewport retains caller red")
    near(outside[2], 34, "outside the main viewport retains caller green")
    near(outside[3], 43, "outside the main viewport retains caller blue")

    currentColor = { 48, 64, 80 }
    drawFrame(1, 2)
    local restarted = pixel(40, 32)
    near(restarted[1], 48, "new scene sequence resets red history")
    near(restarted[2], 64, "new scene sequence resets green history")
    near(restarted[3], 80, "new scene sequence resets blue history")

    viewport = { width = 400, height = 300, worldViewport = { x = 72, y = 54, width = 256, height = 192 } }
    local replacementTarget = scope:own(graphics.newCanvas(400, 300, { format = "rgba8", readable = true, dpiscale = 1 }))
    target = replacementTarget
    drawFrame(1, 3)
    local scene, historyA, historyB, shader = blur._scene, blur._historyA, blur._historyB, blur._shader
    blur:release()
    graphics.setCanvas()
    Assert.isFalse(pcall(function()
      scene:newImageData()
    end), "release invalidates the full-scene target")
    Assert.isFalse(pcall(function()
      historyA:newImageData()
    end), "release invalidates the first history target")
    Assert.isFalse(pcall(function()
      historyB:newImageData()
    end), "release invalidates the second history target")
    Assert.isFalse(pcall(function()
      shader:send("hasPrevious", false)
    end), "release invalidates the capture shader")
    Assert.isNil(blur._scene, "idle presenter owns no scene canvas")
    Assert.isNil(blur._shader, "idle presenter owns no shader")

    local originalNewCanvas = graphics.newCanvas
    local allocatedCanvas
    local allocationCount = 0
    graphics.newCanvas = function(width, height, options)
      allocationCount = allocationCount + 1
      if allocationCount == 2 then
        error("synthetic history canvas allocation failure")
      end
      allocatedCanvas = originalNewCanvas(width, height, options)
      return allocatedCanvas
    end
    local stagedBlur = CelebiTimeTravelBlur.new()
    local staged = pcall(function()
      stagedBlur:draw({ active = true, blurActive = true, sequence = 4, swirlFrame = 1 }, viewport, drawWorld)
    end)
    graphics.newCanvas = originalNewCanvas
    Assert.isFalse(staged, "history acquisition failure propagates")
    graphics.setCanvas()
    Assert.isFalse(pcall(function()
      allocatedCanvas:newImageData()
    end), "failed staging releases the earlier canvas")
    Assert.isNil(stagedBlur._scene, "failed staging publishes no partial target set")

    local failedBlur = CelebiTimeTravelBlur.new()
    graphics.setCanvas(target)
    graphics.setColor(0.2, 0.3, 0.4, 0.5)
    local failed = pcall(function()
      failedBlur:draw({ active = true, blurActive = true, sequence = 4, swirlFrame = 1 }, viewport, function()
        error("synthetic field render failure")
      end)
    end)
    Assert.isFalse(failed, "capture rendering errors propagate")
    Assert.equal(graphics.getCanvas(), target, "capture failure restores the caller canvas")
    local red, green, blue, alpha = graphics.getColor()
    Assert.near(red, 0.2, 1e-6, "capture failure restores caller red")
    Assert.near(green, 0.3, 1e-6, "capture failure restores caller green")
    Assert.near(blue, 0.4, 1e-6, "capture failure restores caller blue")
    Assert.near(alpha, 0.5, 1e-6, "capture failure restores caller alpha")
    Assert.isNil(failedBlur._scene, "capture failure releases staged scene resources")
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
