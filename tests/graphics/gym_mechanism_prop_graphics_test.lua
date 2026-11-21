-- Graphics regression for the gym mechanisms' runtime-loaded source props. The
-- test loads the canonical generated car and Spinarak definitions through the
-- production GPU pool and story-effect adapter, then draws them over a bright
-- target: the models render, and their published world transform decides where
-- on screen they land.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local StoryEffectRenderer = require("libs.hgss.src.presentation.StoryEffectRenderer")

local T = {}

local BACKGROUND = { 0.2, 0.7, 0.9 }

local function runtime()
  local fogTable = {}
  for i = 1, 32 do
    fogTable[i] = 0
  end
  return {
    mapDraws = {},
    buildingDraws = {},
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
end

-- Renders one snapshot and answers the changed-pixel box and centroid.
local function drawSnapshot(fieldRenderer, camera, items, canvas)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
  fieldRenderer:draw(runtime(), camera, { items }, nil, FieldViewport.new(256, 192, { mode = "strict" }), nil, 3)
  love.graphics.setCanvas()
  local image = canvas:newImageData()
  local changed, sumX, sumY = 0, 0, 0
  local minX, minY = image:getWidth(), image:getHeight()
  local maxX, maxY = -1, -1
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local r, g, b = image:getPixel(x, y)
      local isBackground = math.abs(r - BACKGROUND[1]) < 0.02
        and math.abs(g - BACKGROUND[2]) < 0.02
        and math.abs(b - BACKGROUND[3]) < 0.02
      if not isBackground then
        changed = changed + 1
        sumX, sumY = sumX + x, sumY + y
        minX, minY = math.min(minX, x), math.min(minY, y)
        maxX, maxY = math.max(maxX, x), math.max(maxY, y)
      end
    end
  end
  return {
    changed = changed,
    centroidX = changed > 0 and sumX / changed or 0,
    centroidY = changed > 0 and sumY / changed or 0,
    minX = minX,
    minY = minY,
    maxX = maxX,
    maxY = maxY,
  }
end

local function canonicalAssets(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local versionId = nil
  for _, candidate in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(candidate) then
      versionId = candidate
      break
    end
  end
  if versionId == nil then
    context:skip("canonical field-effect model is unavailable")
    return nil
  end
  local cache = CacheFs.forVersion(versionId)
  if not cache:exists(FieldEffectAssetCache.indexPath()) then
    context:skip("canonical field-effect model is unavailable")
    return nil
  end
  local index = assert(cache:loadLua(FieldEffectAssetCache.indexPath()))
  local car = assert(index.effects.violet_gym_car, "field-effect index is missing the car")
  local spider = assert(index.effects.azalea_gym_spinarak, "field-effect index is missing the Spinarak")
  return cache, {
    car = assert(cache:loadLua(car.path)),
    spider = assert(cache:loadLua(spider.path)),
  }
end

function T.the_car_and_spider_models_render_at_their_published_transform(scope, context)
  local cache, definitions = canonicalAssets(context)
  if cache == nil then
    return
  end
  local imagePool = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      imagePool:dispose()
    end,
  })
  local pool = scope:own(GpuAssetPool.new(cache, { imageAssets = imagePool }))
  local renderer = StoryEffectRenderer.new(definitions, pool)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local car = renderer:newCar()
  scope:own({
    release = function()
      car:dispose()
    end,
  })
  for slot = 1, 4 do
    local spider = renderer:newSpider(slot)
    scope:own({
      release = function()
        spider:dispose()
      end,
    })
  end
  local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local camera = FieldCamera.new(cameraProfiles.profiles[0], { canonicalAspect = 4 / 3 })
  local fieldRenderer = scope:own(FieldRenderer.new({ clearColor = { BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1 } }))
  local canvas = scope:own(love.graphics.newCanvas(256, 192))

  local base = drawSnapshot(
    fieldRenderer,
    camera,
    renderer:drawItems({ car = { x = 0, y = 0, z = 0, rotationDegrees = 0 } }),
    canvas
  )
  Assert.isTrue(base.changed > 0, "the canonical elevator car must render visible pixels")

  local lifted = drawSnapshot(
    fieldRenderer,
    camera,
    renderer:drawItems({ car = { x = 0, y = 2, z = 0, rotationDegrees = 0 } }),
    canvas
  )
  Assert.isTrue(lifted.changed > 0, "the raised car must render visible pixels")
  Assert.isTrue(lifted.centroidY < base.centroidY, "a raised car draws higher on screen")

  local moved = drawSnapshot(
    fieldRenderer,
    camera,
    renderer:drawItems({ car = { x = 2, y = 0, z = 0, rotationDegrees = 0 } }),
    canvas
  )
  Assert.isTrue(moved.centroidX > base.centroidX, "a car placed two tiles east draws further right")

  local spiderItems = renderer:drawItems({
    spiders = {
      { slot = 1, x = 0, y = 0, z = 0, rotationDegrees = 0 },
      { slot = 2, x = 2, y = 0, z = 0, rotationDegrees = 0 },
    },
  })
  local spider = drawSnapshot(fieldRenderer, camera, spiderItems, canvas)
  Assert.isTrue(spider.changed > 0, "the canonical Spinarak must render visible pixels")
  Assert.isTrue(
    spider.maxX - spider.minX > moved.maxX - moved.minX,
    "two placed spiders cover more columns than one car"
  )
end

return GraphicsSmoke.suite(T)
