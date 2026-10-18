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
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local MonCache = require("libs.assets.src.MonCache")
local MonBucket = require("tests.support.MonBucket")
local MonsSave = require("libs.mons.src.MonsSave")
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
  local cache = CacheFs.forVersion(versionId)
  local fontDef = FieldFontLoader.load(cache)
  local service = HgssMonService.new({
    catalog = MonBucket.openCatalogs(versionId),
    bucket = MonsSave.empty(7),
    profile = { name = "GOLD", gender = 0, trainerId = 1 },
    game = versionId,
    language = MonCache.loadCatalog(cache).version.language,
    charmap = assert(fontDef.charmap, "production font carries the charmap"),
    mapSection = function()
      return 60
    end,
    date = { year = 2000, month = 1, day = 1 },
  })
  Assert.isTrue(
    service:giveMon({ species = "CYNDAQUIL", level = 5, location = 60 }),
    "the field starts with a production-created follower"
  )
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
    mons = service:capture(),
    bag = require("libs.hgss.src.save.BagSave").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
end

local function detachedStatus(source, modelVisible)
  return {
    active = source.active,
    modelVisible = modelVisible,
    animationFrame = source.animationFrame,
    swirlFrame = source.swirlFrame,
    modelPosition = { x = source.modelPosition.x, y = source.modelPosition.y, z = source.modelPosition.z },
    blurActive = source.blurActive,
    sequence = source.sequence,
  }
end

local function capture(state, scope)
  local graphics = love.graphics
  local viewport = state.runtime.viewport
  local target = scope:own(graphics.newCanvas(viewport.width, viewport.height, {
    format = "rgba8",
    readable = true,
    dpiscale = 1,
  }))
  graphics.setCanvas(target)
  graphics.clear(0, 0, 0, 1)
  state:draw()
  graphics.setCanvas()
  return scope:own(target:newImageData())
end

local function pixelDifferenceCount(a, b, bounds, threshold)
  local different = 0
  for y = bounds.y, bounds.y + bounds.height - 1 do
    for x = bounds.x, bounds.x + bounds.width - 1 do
      local ar, ag, ab = a:getPixel(x, y)
      local br, bg, bb = b:getPixel(x, y)
      if math.abs(ar - br) > threshold or math.abs(ag - bg) > threshold or math.abs(ab - bb) > threshold then
        different = different + 1
      end
    end
  end
  return different
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
        local aborted, abortError = pcall(function()
          if scene:status().active then
            scene:abort()
          end
        end)
        local disposed, disposeError = pcall(function()
          state:dispose()
        end)
        if not aborted then
          error(abortError, 0)
        end
        if not disposed then
          error(disposeError, 0)
        end
      end,
    })
    for _ = 1, 120 do
      local followingMon = state.runtime.followingMon
      if
        state.runtime.session.mapEntryStage == nil
        and followingMon:partnerActorId() ~= nil
        and followingMon:isPartnerVisible()
      then
        break
      end
      state:draw()
      state:update(1 / 30)
    end
    Assert.isNil(state.runtime.session.mapEntryStage, "production field entry settles before capture")
    Assert.notNil(state.runtime.followingMon:partnerActorId(), "production field entry installs the gifted follower")
    Assert.isTrue(state.runtime.followingMon:isPartnerVisible(), "the installed follower is visible before replacement")
    local followerId = assert(state.runtime.followingMon:partnerActorId(), "the field installs the gifted follower")
    local follower = assert(state.runtime.actors:getById(followerId), "the installed follower actor remains live")
    scene:beginModel()
    scene:setAnimationFrame(31)
    local liveStatus = scene:status()
    local followerPosition = follower:getWorldPosition()
    Assert.equal(liveStatus.modelPosition.x, followerPosition.x, "the replacement captures follower world X")
    Assert.equal(liveStatus.modelPosition.y, followerPosition.y, "the replacement captures follower world Y")
    Assert.equal(liveStatus.modelPosition.z, followerPosition.z, "the replacement captures follower world Z")
    Assert.isFalse(
      state.runtime.followingMon:isPartnerVisible(),
      "the scene hides the real follower during replacement"
    )
    local function captureModelState(visible)
      scene.status = function()
        return detachedStatus(liveStatus, visible)
      end
      return capture(state, scope)
    end
    local baselineBefore = captureModelState(false)
    local modelVisible = captureModelState(true)
    local baselineAfter = captureModelState(false)
    scene.status = originalSceneStatus

    local viewport = state.runtime.viewport
    local world = viewport.worldViewport
    local fullViewport = { x = 0, y = 0, width = viewport.width, height = viewport.height }
    local stablePixels = pixelDifferenceCount(baselineBefore, baselineAfter, fullViewport, 1 / 255)
    local modelPixels = pixelDifferenceCount(baselineBefore, modelVisible, world, 2 / 255)
    Assert.equal(stablePixels, 0, "model-off captures bracket an unchanged production frame")
    Assert.isTrue(modelPixels > 0, "the source model contributes visible RGB pixels inside the main world viewport")

    scene:beginSwirl()
    scene:setSwirlFrame(1)
    local composed = capture(state, scope)

    Assert.notNil(state._celebiBlur, "the production field draw enters its capture presenter")
    Assert.notNil(state._celebiBlur._scene, "FieldState captures into its transient scene target")
    Assert.notNil(state._celebiBlur._historyA, "FieldState publishes native feedback history")
    Assert.isTrue(#state.worldParts[12] > 0, "the real field queue includes the animated legend")
    Assert.isTrue(#state.spriteItems > 0, "the real field draw includes billboard actors")
    Assert.isTrue(
      state.presentationResources.renderer.stats.geometrySubmissions > 0,
      "the real field renderer submits captured world geometry"
    )

    local varied = false
    local first = { composed:getPixel(world.x + 128, world.y + 96) }
    for _, point in ipairs({ { 32, 32 }, { 128, 64 }, { 224, 160 } }) do
      local pixel = { composed:getPixel(world.x + point[1], world.y + point[2]) }
      varied = varied or pixel[1] ~= first[1] or pixel[2] ~= first[2] or pixel[3] ~= first[3]
    end
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
      local imageAssets = ImageAssetPool.new(cache)
      scope:own({
        release = function()
          imageAssets:dispose()
        end,
      })
      local presenter = scope:own(CelebiTimeTravelRenderer.new(cache, imageAssets))
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
      for frame = 1, 211 do
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
      }, camera, { presenter:drawItems(status(211)) }, nil, viewport, 0, 3)
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
