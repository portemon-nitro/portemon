-- Original Whirl Islands eye-glimmer and Lugia cinematic models must reach
-- the production field renderer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local LugiaAppearanceRenderer = require("libs.hgss.src.presentation.LugiaAppearanceRenderer")
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

local function status(fields)
  local base = { active = true, sequence = 1, versionId = "soulsilver", origin = { x = 0, y = 0, z = 0 } }
  for key, value in pairs(fields) do
    base[key] = value
  end
  return base
end

local function runVersion(scope)
  local cache = CacheFs.forVersion("soulsilver")
  local index = assert(cache:loadLua(FieldEffectAssetCache.indexPath()))
  assert(index.effects.lugia_appearance, "the cache index publishes original Lugia reveal models")
  local images = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      images:dispose()
    end,
  })
  local renderer = LugiaAppearanceRenderer.new(cache, images)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local profiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local camera = FieldCamera.new(profiles.profiles[0], { canonicalAspect = 4 / 3 })
  local fieldRenderer = FieldRenderer.new({ clearColor = { 0.1, 0.2, 0.3, 1 } })
  scope:own({
    release = function()
      fieldRenderer:release()
    end,
  })
  local viewport = FieldViewport.new(256, 192, { mode = "strict" })
  local target = scope:own(love.graphics.newCanvas(256, 192))
  local idleItems = renderer:drawItems(status({}))
  Assert.equal(#idleItems, 0, "an idle reveal status draws nothing")
  local glimmerItems = renderer:drawItems(status({ eyeGlimmerFrame = 0 }))
  local glimmerRoles = {}
  for _, item in ipairs(glimmerItems) do
    glimmerRoles[item.fieldEffectRole] = true
  end
  Assert.isTrue(glimmerRoles.eye_glimmer, "the eye glimmer draws its model")
  Assert.equal(glimmerItems[1].fieldEffect, "lugia_appearance", "glimmer draws carry the Lugia effect tag")
  local cinematicItems = renderer:drawItems(status({ cinematicShot = "lugia", cinematicModelFrame = 145 }))
  local cinematicRoles = {}
  for _, item in ipairs(cinematicItems) do
    cinematicRoles[item.fieldEffectRole] = true
  end
  Assert.isTrue(cinematicRoles.lugia_cinematic, "the Lugia cinematic draws its near model")
  Assert.isTrue(cinematicRoles.lugia_cinematic_far, "the Lugia cinematic draws its far model")
  for _, shot in ipairs({ "first", "second" }) do
    local foreign = renderer:drawItems(status({ cinematicShot = shot, cinematicVariant = 0, cinematicModelFrame = 1 }))
    Assert.equal(#foreign, 0, "the Lugia renderer ignores the Ho-Oh " .. shot .. " shot")
  end
  local cinematicClear = { 0.3, 0.3, 0.3, 1 }
  fieldRenderer.clearColor = cinematicClear
  camera:setCutscenePose(
    { x = 0x00004DEC / 65536, y = 0x000803CD / 65536, z = 0x0002B2F5 / 65536 },
    0x00153B51 / 4096 / 16,
    0x0982,
    0x0A01,
    { x = 0, y = 0, z = 0 },
    0x1E20,
    0x0007B000 / 4096 / 16,
    0x006A4000 / 4096 / 16
  )
  love.graphics.setCanvas(target)
  love.graphics.clear(cinematicClear[1], cinematicClear[2], cinematicClear[3], cinematicClear[4])
  fieldRenderer:draw(sceneRuntime(), camera, { cinematicItems }, nil, viewport, 0, 3)
  love.graphics.setCanvas()
  local pixels = target:newImageData()
  local visiblePixels = 0
  for y = 0, pixels:getHeight() - 1 do
    for x = 0, pixels:getWidth() - 1 do
      local red, green, blue = pixels:getPixel(x, y)
      if
        math.abs(red - cinematicClear[1]) + math.abs(green - cinematicClear[2]) + math.abs(blue - cinematicClear[3])
        > 0.05
      then
        visiblePixels = visiblePixels + 1
      end
    end
  end
  pixels:release()
  Assert.isTrue(visiblePixels > 0, "the Lugia cinematic shot draws visible pixels")
  Assert.isTrue(fieldRenderer.stats.geometrySubmissions > 0, "Lugia reveal models reach a real GPU draw")
  love.graphics.setCanvas()
end

local function testAppearanceModelsReachFieldRenderer(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("soulsilver dump not owned; Lugia reveal coverage needs its derived assets")
  end
  runVersion(scope)
end

local T = GraphicsSmoke.suite({
  ["Lugia reveal models use the generated source assets in the field render pass"] = testAppearanceModelsReachFieldRenderer,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "field-effects:global", "field-camera:global" }
T.metadata.tags = { "field", "lugia", "materials" }
return T
