-- Production-composed graphics coverage for both Apricorn Box modes.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local ApricornBoxRenderer = require("libs.hgss.src.ui.ApricornBoxRenderer")
local ApricornBoxScreenState = require("game.hgss.src.apricorn.ApricornBoxScreenState")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}
local BACKGROUND = { 0.08, 0.08, 0.1 }

local function measurement(topology, width, height, signature)
  return { width = width, height = height, topology = topology, pixelRatio = 1, signature = signature }
end

local function stock(manifest)
  local apricorns = {}
  for index, row in ipairs(manifest.rows) do
    apricorns[row.apricornKey] = index * 3
  end
  return {
    capture = function()
      return { apricorns = apricorns }
    end,
  }
end

local function messageProvider(cacheFs)
  local provider = require("libs.hgss.src.interaction.FieldMessageProvider").new(cacheFs)
  return provider
end

local function makeTopology(name)
  if name == "dual" then
    return ScreenTopology.dualDisplay(
      { id = "world", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "aux", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
      512,
      384
  end
  local width, height =
    name == "native" and 512 or name == "wide" and 1000 or 600,
    name == "native" and 384 or name == "wide" and 600 or 1000
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  }),
    width,
    height
end

local function writeCapture(image, filename)
  local directory = os.getenv("PORTEMON_APRICORN_BOX_CAPTURE_DIR")
  if directory == nil then
    return
  end
  local encoded = image:encode("png")
  local file = assert(io.open(directory .. "/" .. filename, "wb"))
  assert(file:write(encoded:getString()))
  assert(file:close())
end

local function assertVisiblePixels(pixels)
  local backgroundRed = math.floor(BACKGROUND[1] * 255 + 0.5)
  local backgroundGreen = math.floor(BACKGROUND[2] * 255 + 0.5)
  local backgroundBlue = math.floor(BACKGROUND[3] * 255 + 0.5)
  local changedPixels = 0
  for index = 1, #pixels, 4 do
    local red, green, blue = pixels:byte(index, index + 2)
    if
      math.abs(red - backgroundRed) > 8
      or math.abs(green - backgroundGreen) > 8
      or math.abs(blue - backgroundBlue) > 8
    then
      changedPixels = changedPixels + 1
    end
  end
  Assert.isTrue(changedPixels >= 1024, "the rendered capture contains at least 1024 visible pixels")
end

local function render(scope, cacheFs, manifest, renderer, window, topologyName, mode)
  local topology, width, height = makeTopology(topologyName)
  local currentMeasurement = measurement(topology, width, height, topologyName)
  local provider = messageProvider(cacheFs)
  local screen = ApricornBoxScreenState.new({
    mode = mode,
    service = stock(manifest),
    effect = function() end,
    manifest = manifest,
    messageProvider = provider,
    measureDisplay = function()
      return currentMeasurement
    end,
  })
  scope:own({
    release = function()
      screen:dispose()
    end,
  })
  screen:updateFixed({ { type = "confirm" } })
  if mode == "kurt_select" then
    for _ = 1, 4 do
      screen:updateFixed({})
    end
  end
  local view = screen:status()
  Assert.equal(view.phase, "actions", "capture shows the source action menu")
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
  view.presentation.render({ graphics = love.graphics, apricornBoxRenderer = renderer }, view, view.presentation)
  for _, frame in ipairs(view.presentation.frames) do
    LogicalSurface.draw(love.graphics, frame.placement, function()
      window:drawApplicationFrame(frame.contentBox, 0)
    end)
  end
  love.graphics.setCanvas()
  local image = scope:own(canvas:newImageData())
  assertVisiblePixels(image:getString())
  writeCapture(image, mode .. "-" .. topologyName .. ".png")
end

function T.source_box_renders_browse_and_kurt_modes_for_each_layout(scope)
  local cacheFs = CacheFs.forVersion("heartgold")
  local manifest = ApricornBoxAssetCache.loadManifest(cacheFs)
  Assert.isTrue(ApricornBoxAssetCache.isManifestValid(manifest), "the prepared ROM supplies the strict source manifest")
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, graphics = love.graphics }))
  local uiManifest = assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()))
  local window = scope:own(FieldWindowRenderer.new({
    cacheFs = cacheFs,
    manifest = uiManifest,
    graphics = love.graphics,
  }))
  local renderer = scope:own(ApricornBoxRenderer.new({
    cacheFs = cacheFs,
    manifest = manifest,
    text = text,
    graphics = love.graphics,
  }))
  for _, topology in ipairs({ "native", "wide", "tall", "dual" }) do
    for _, mode in ipairs({ "browse", "kurt_select" }) do
      render(scope, cacheFs, manifest, renderer, window, topology, mode)
    end
  end
end

return GraphicsSmoke.suite(T, {
  tags = { "apricorn" },
  capabilities = { "derived_assets" },
  derivedAssets = { "apricorn-box:global", "field-font:global", "field-ui:global" },
})
