-- Original Bell Tower cutscene models must reach the production field renderer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local HoOhAppearanceRenderer = require("libs.hgss.src.presentation.HoOhAppearanceRenderer")
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

local function runVersion(scope, versionId)
  local cache = CacheFs.forVersion(versionId)
  local index = assert(cache:loadLua(FieldEffectAssetCache.indexPath()))
  assert(index.effects.ho_oh_appearance, "the cache index publishes original Ho-Oh models")
  local images = ImageAssetPool.new(cache)
  local function releaseImages()
    images:dispose()
  end
  scope:own({ release = releaseImages })
  local renderer = HoOhAppearanceRenderer.new(cache, images)
  local function releaseHoOhRenderer()
    renderer:dispose()
  end
  scope:own({ release = releaseHoOhRenderer })
  local profiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local camera = FieldCamera.new(profiles.profiles[0], { canonicalAspect = 4 / 3 })
  local fieldRenderer = FieldRenderer.new({ clearColor = { 0.1, 0.2, 0.3, 1 } })
  local function releaseFieldRenderer()
    fieldRenderer:release()
  end
  scope:own({ release = releaseFieldRenderer })
  local viewport = FieldViewport.new(256, 192, { mode = "strict" })
  local target = scope:own(love.graphics.newCanvas(256, 192))
  local baseStatus = {
    active = true,
    sequence = 1,
    versionId = versionId,
    origin = { x = 0, y = 0, z = 0 },
    bellStage = "shimmer",
    bellFrame = 0,
    loopFrame = 0,
    bellVisible = false,
    shimmerFrame = 0,
    shimmerClearBellOnly = false,
    cornerOffsets = versionId == "heartgold"
        and { { 12.5, -4.5625, 9 }, { -12.375, -4.5625, 9 }, { 12.5, -4.5625, -16.875 }, { -12.375, -4.5625, -16.875 } }
      or { { 8, 2, -11.25 }, { -8, 2, -11.25 } },
    effectsActive = versionId == "soulsilver",
    effectFrame = 0,
    leavesActive = versionId == "heartgold",
    leafFrame = 0,
  }
  local idleItems = renderer:drawItems({
    active = true,
    sequence = 1,
    versionId = versionId,
    origin = { x = 0, y = 0, z = 0 },
    bellStage = "idle",
    bellFrame = 0,
    bellVisible = false,
  })
  local idleVisible = false
  for _, item in ipairs(idleItems) do
    if item.fieldEffectRole == "clear_bell_rising" then
      idleVisible = true
    end
  end
  Assert.isFalse(idleVisible, versionId .. " keeps the Clear Bell hidden before it rises")
  local riseItems = renderer:drawItems({
    active = true,
    sequence = 1,
    versionId = versionId,
    origin = { x = 0, y = 0, z = 0 },
    bellStage = "rise",
    bellFrame = 0,
    bellVisible = true,
  })
  local riseVisible = false
  for _, item in ipairs(riseItems) do
    if item.fieldEffectRole == "clear_bell_rising" then
      riseVisible = true
    end
  end
  Assert.isTrue(riseVisible, versionId .. " draws the Clear Bell while it rises")
  local function bellSize(items, role)
    local size = 0
    for _, item in ipairs(items) do
      if item.fieldEffectRole == role then
        local t = item.transform
        size = math.max(size, math.sqrt(t[1] ^ 2 + t[2] ^ 2 + t[3] ^ 2))
      end
    end
    return size
  end
  local function bellStatus(fields)
    local status = { active = true, sequence = 1, versionId = versionId, origin = { x = 0, y = 0, z = 0 } }
    for key, value in pairs(fields) do
      status[key] = value
    end
    return status
  end
  local grownSize = bellSize(
    renderer:drawItems(bellStatus({ bellStage = "rise", bellFrame = 60, bellVisible = true })),
    "clear_bell_rising"
  )
  local loopSize = bellSize(
    renderer:drawItems(bellStatus({ bellStage = "idle", bellFrame = 61, loopFrame = 1, bellVisible = true })),
    "clear_bell_rising"
  )
  Assert.isTrue(grownSize > 0, versionId .. " Clear Bell has a size when fully grown")
  Assert.equal(loopSize, grownSize, versionId .. " Clear Bell keeps its grown size in the idle loop")
  local items = renderer:drawItems(baseStatus)
  local roles = {}
  for _, item in ipairs(items) do
    roles[item.fieldEffectRole] = true
  end
  local cornerCount = 0
  for role in pairs(roles) do
    if role:match("^corner_bells_%d+$") then
      cornerCount = cornerCount + 1
    end
  end
  Assert.isNil(roles.clear_bell_rising, versionId .. " hides the rising bell while its shimmer model is active")
  Assert.isTrue(roles.clear_bell_shimmer, versionId .. " draws the shimmer model")
  Assert.equal(
    cornerCount,
    versionId == "heartgold" and 4 or 2,
    versionId .. " keeps each corner bell as a separate draw"
  )
  if versionId == "soulsilver" then
    Assert.isTrue(roles.waves, "SoulSilver draws the original animated waves model")
  end
  love.graphics.setCanvas(target)
  fieldRenderer:draw(sceneRuntime(), camera, { items }, nil, viewport, 0, 3)
  if versionId == "heartgold" then
    renderer:drawLeaves(baseStatus, viewport)
    local leafCanvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(leafCanvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:drawLeaves(baseStatus, viewport)
    love.graphics.setCanvas()
    local pixels = leafCanvas:newImageData()
    local hasLeafColor = false
    for y = 0, pixels:getHeight() - 1 do
      for x = 0, pixels:getWidth() - 1 do
        local red, green, blue, alpha = pixels:getPixel(x, y)
        if alpha > 0.5 and red > 0.5 and green > 0.2 and blue > 0.05 then
          hasLeafColor = true
          break
        end
      end
      if hasLeafColor then
        break
      end
    end
    local _, _, _, emptyAlpha = pixels:getPixel(0, 0)
    pixels:release()
    Assert.isTrue(hasLeafColor, "HeartGold leaf layers render their source orange colors")
    Assert.equal(emptyAlpha, 0, "HeartGold leaf layers preserve transparent pixels")
  end
  local cinematicTarget = scope:own(love.graphics.newCanvas(256, 192))
  local cinematicClear = { 0.3, 0.3, 0.3, 1 }
  fieldRenderer.clearColor = cinematicClear
  local visibleShots = {}
  for _, shot in ipairs({ "first", "second" }) do
    for variant = 0, 2 do
      local cinematicItems = renderer:drawItems({
        active = true,
        sequence = 1,
        versionId = versionId,
        origin = { x = 0, y = 0, z = 0 },
        cinematicShot = shot,
        cinematicVariant = variant,
        cinematicModelFrame = shot == "first" and 129 or 1,
      })
      Assert.isTrue(#cinematicItems > 0, versionId .. " Ho-Oh " .. shot .. " shot creates model draws")
      if shot == "first" and variant == 0 then
        local firstProgram = renderer.definitions["cinematic.first.0"].descriptor.dynamic.transformProgram
        for _, node in ipairs(firstProgram.nodes) do
          if not node.scaleOne then
            Assert.notNil(node.inverseScale, "cached cinematic model retains each Maya inverse scale")
          end
        end
      end
      camera:setCutscenePose(
        shot == "first" and { x = 0x0025A7F4 / 65536, y = 0x0024282F / 65536, z = -0x0025CE83 / 65536 }
          or { x = -75511 / 65536, y = -134660 / 65536, z = 241555 / 65536 },
        shot == "first" and 0x004B4152 / 4096 / 16 or 0x001BA152 / 4096 / 16,
        shot == "first" and 0x0C80 or 0xECA2,
        shot == "first" and 0x0881 or 0x0381,
        { x = 0, y = 0, z = 0 },
        shot == "first" and 0xD8E0 or 0x8380,
        shot == "first" and 0x00009000 / 4096 / 16 or 0x00096000 / 4096 / 16,
        0x006A4000 / 4096 / 16
      )
      love.graphics.setCanvas(cinematicTarget)
      love.graphics.clear(cinematicClear[1], cinematicClear[2], cinematicClear[3], cinematicClear[4])
      fieldRenderer:draw(sceneRuntime(), camera, { cinematicItems }, nil, viewport, 0, 3)
      love.graphics.setCanvas()
      local pixels = cinematicTarget:newImageData()
      local visiblePixels = 0
      for y = 0, pixels:getHeight() - 1 do
        for x = 0, pixels:getWidth() - 1 do
          local red, green, blue = pixels:getPixel(x, y)
          if
            math.abs(red - cinematicClear[1])
              + math.abs(green - cinematicClear[2])
              + math.abs(blue - cinematicClear[3])
            > 0.05
          then
            visiblePixels = visiblePixels + 1
          end
        end
      end
      pixels:release()
      visibleShots[shot] = visibleShots[shot] or visiblePixels > 0
    end
  end
  Assert.isTrue(visibleShots.first, versionId .. " first Ho-Oh cinematic shot draws visible pixels")
  Assert.isTrue(visibleShots.second, versionId .. " second Ho-Oh cinematic shot draws visible pixels")
  love.graphics.setCanvas()
  Assert.isTrue(fieldRenderer.stats.geometrySubmissions > 0, versionId .. " cutscene models reach a real GPU draw")
end

local function testAppearanceModelsReachFieldRenderer(scope)
  local versions = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions = versions + 1
      runVersion(scope, versionId)
    end
  end
  Assert.isTrue(versions > 0, "a ready imported game version is required")
end

-- The scroll wraps every 256 ticks and the six-frame animation every 36, so the
-- overlay repeats exactly after their least common multiple.
local LEAF_CYCLE_TICKS = 2304

-- Renders the HeartGold leaf overlay into a fresh canvas for one viewport and
-- returns its pixels.
local function renderLeaves(scope, renderer, width, height, mode, frame)
  local viewport = FieldViewport.new(width, height, { mode = mode })
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.15, 0.15, 0.3, 1)
  renderer:drawLeaves({ leavesActive = true, leafFrame = frame }, viewport)
  love.graphics.setCanvas()
  return canvas:newImageData()
end

local function samePixel(left, leftX, leftY, right, rightX, rightY)
  local lr, lg, lb = left:getPixel(leftX, leftY)
  local rr, rg, rb = right:getPixel(rightX, rightY)
  return math.abs(lr - rr) + math.abs(lg - rg) + math.abs(lb - rb) < 0.01
end

local function testLeafOverlayFollowsTheFieldViewport(scope)
  if not RomImporter.isReady("heartgold") then
    return
  end
  local cache = CacheFs.forVersion("heartgold")
  local images = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      images:dispose()
    end,
  })
  local renderer = HoOhAppearanceRenderer.new(cache, images)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  renderer:drawItems({
    active = true,
    sequence = 1,
    versionId = "heartgold",
    origin = { x = 0, y = 0, z = 0 },
    bellStage = "idle",
    bellFrame = 0,
    bellVisible = false,
  })
  for _, frame in ipairs({ 0, 40, 100 }) do
    local native = renderLeaves(scope, renderer, 256, 192, "strict", frame)
    local scaled = renderLeaves(scope, renderer, 1024, 768, "strict", frame)
    local expanded = renderLeaves(scope, renderer, 1500, 768, "expanded", frame)
    local reference = renderLeaves(scope, renderer, 1024, 768, "strict", frame)
    local wrapped = renderLeaves(scope, renderer, 1024, 768, "strict", frame + LEAF_CYCLE_TICKS)
    local nativeMatchesScaled, expandedMatchesReference, wrapMatches = true, true, true
    for y = 0, 191 do
      for x = 0, 255 do
        nativeMatchesScaled = nativeMatchesScaled and samePixel(native, x, y, scaled, x * 4 + 2, y * 4 + 2)
      end
    end
    for y = 0, 767 do
      for x = 0, 1023 do
        expandedMatchesReference = expandedMatchesReference and samePixel(expanded, x + 238, y, reference, x, y)
      end
    end
    for y = 0, 767, 3 do
      for x = 0, 1023, 3 do
        wrapMatches = wrapMatches and samePixel(scaled, x, y, wrapped, x, y)
      end
    end
    Assert.isTrue(nativeMatchesScaled, "frame " .. frame .. ": leaves scale uniformly from the native DS frame")
    Assert.isTrue(expandedMatchesReference, "frame " .. frame .. ": expanded viewports keep the 4:3 frame pixel-exact")
    Assert.isTrue(
      wrapMatches,
      "frame " .. frame .. ": the leaf overlay repeats after one full scroll and animation cycle"
    )
    native:release()
    scaled:release()
    expanded:release()
    reference:release()
    wrapped:release()
  end
end

local function testLeafOverlayCoversExpandedViewports(scope)
  if not RomImporter.isReady("heartgold") then
    return
  end
  local cache = CacheFs.forVersion("heartgold")
  local images = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      images:dispose()
    end,
  })
  local renderer = HoOhAppearanceRenderer.new(cache, images)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  renderer:drawItems({
    active = true,
    sequence = 1,
    versionId = "heartgold",
    origin = { x = 0, y = 0, z = 0 },
    bellStage = "idle",
    bellFrame = 0,
    bellVisible = false,
  })
  local sizes = { { 1920, 600 }, { 500, 1200 } }
  for _, size in ipairs(sizes) do
    local covered = { margin = false }
    for _, frame in ipairs({ 0, 30, 60, 90, 120, 150 }) do
      local pixels = renderLeaves(scope, renderer, size[1], size[2], "expanded", frame)
      local frameWidth = math.min(size[1], size[2] * 4 / 3)
      local frameHeight = frameWidth * 3 / 4
      for y = 0, size[2] - 1 do
        for x = 0, size[1] - 1 do
          local outside = x < (size[1] - frameWidth) / 2 - 2
            or x > (size[1] + frameWidth) / 2 + 2
            or y < (size[2] - frameHeight) / 2 - 2
            or y > (size[2] + frameHeight) / 2 + 2
          if outside then
            local red = pixels:getPixel(x, y)
            covered.margin = covered.margin or red > 0.5
          end
        end
      end
      pixels:release()
    end
    Assert.isTrue(covered.margin, size[1] .. "x" .. size[2] .. ": leaves also cover the area outside the 4:3 frame")
  end
end

local T = GraphicsSmoke.suite({
  ["Ho-Oh cutscene models use the generated source assets in the field render pass"] = testAppearanceModelsReachFieldRenderer,
  ["HeartGold leaf overlay follows the field viewport"] = testLeafOverlayFollowsTheFieldViewport,
  ["HeartGold leaf overlay covers expanded viewports"] = testLeafOverlayCoversExpandedViewports,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "field-effects:global", "field-camera:global" }
T.metadata.tags = { "field", "ho-oh", "materials" }
return T
