-- Presented Options text wiring: openOptionsPresentation adapts the shared
-- palette-triple field text renderer to the option-widget collaborator, so
-- every label draw forwards a byte-valued foreground/shadow/background
-- triple instead of the widget's flat 0..1 ink color. Each pass paints its
-- glyph shape solid (foreground and shadow slots agree) over transparent
-- glyph background; the widget's 1px shadow offset remains the only shadow.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = { capabilities = { "graphics" }, tags = { "options", "presentation" } },
  tests = {},
}

local function optionsCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addOptionsContract(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  CacheFs.forVersion("heartgold"):write(FieldUiFixture.OPTIONS_CHROME_PATH, FieldUiFixture.optionsChromeBytes())
  return cache, manifest
end

local function measurement()
  return {
    width = 512,
    height = 384,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "options-wiring",
  }
end

local function sampleView()
  local rows = {}
  for _, id in ipairs({ "textSpeed", "battleScene", "battleStyle", "soundMode", "textFrame", "volume", "battleSpeed" }) do
    rows[#rows + 1] = { id = id, label = id:upper(), valueLabel = "V", value = 1, valueIndex = 1, valueCount = 2 }
  end
  return {
    open = true,
    rows = rows,
    focusId = "textSpeed",
    scrollOffset = 0,
    footer = { confirm = { enabled = true }, quit = {} },
  }
end

local function preparedWiring(scope)
  local Resources = require("game.hgss.src.field.FieldPresentationResources")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  local palettes = {}
  local stubText = {}
  function stubText:drawTextWithPalette(_, _, _, palette)
    palettes[#palettes + 1] = palette
  end
  function stubText:windowBackgroundColor()
    return { 0.1, 0.2, 0.3, 1 }
  end
  local stubWindow = {}
  function stubWindow:drawWindow(_, _, _) end
  local resources = setmetatable({
    cacheFs = cache,
    uiManifest = manifest,
    _imagePool = pool,
    textRenderer = stubText,
    windowRenderer = stubWindow,
  }, Resources)
  scope:own({
    release = function()
      if resources._optionsRenderer ~= nil then
        resources._optionsRenderer:dispose()
        resources._optionsRenderer = nil
      end
    end,
  })
  local port = resources:openOptionsPresentation()
  local ready = port.prepare()
  local spins = 0
  while ready == false do
    spins = spins + 1
    Assert.isTrue(spins < 10000, "chrome resolves through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    ready = port.prepare()
  end
  return resources, palettes
end

local function drawNative(scope, renderer, view)
  local Interface = require("game.hgss.src.options.OptionsInterface")
  local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
  local resolvers = Interface.defaults()
  local m = measurement()
  local selection = ApplicationLayout.selectSurfaces(m)
  local plan = resolvers.nativeLike({
    measurement = m,
    configuration = "nativeLike",
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = resolvers.nativeLike,
  }, view)
  local canvas = scope:own(love.graphics.newCanvas(512, 384))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(view, plan)
  love.graphics.setCanvas()
end

function T.tests.label_draws_forward_byte_valued_palette_triples(scope)
  local resources, palettes = preparedWiring(scope)
  drawNative(scope, assert(resources._optionsRenderer, "open presentation retains its renderer"), sampleView())
  Assert.isTrue(#palettes > 0, "options draw paints labels through the text renderer")
  for index, palette in ipairs(palettes) do
    Assert.isTrue(type(palette) == "table", "label draw " .. index .. " forwards a palette record")
    for _, slot in ipairs({ "foreground", "shadow", "background" }) do
      local color = assert(
        type(palette[slot]) == "table" and palette[slot],
        "label draw " .. index .. " carries " .. slot
      )
      for _, channel in ipairs({ "r", "g", "b" }) do
        local value = color[channel]
        Assert.isTrue(
          type(value) == "number" and value >= 0 and value <= 255,
          "label draw " .. index .. " " .. slot .. "." .. channel .. " is byte-valued"
        )
      end
    end
    Assert.equal(palette.background.a, 0, "label draw " .. index .. " keeps glyph background transparent")
  end
end

function T.tests.shadow_pass_paints_black_before_the_white_face(scope)
  local resources, palettes = preparedWiring(scope)
  drawNative(scope, assert(resources._optionsRenderer, "open presentation retains its renderer"), sampleView())
  Assert.isTrue(#palettes >= 2, "the first row paints its shadow offset before its face")
  Assert.deepEqual(
    { r = palettes[1].foreground.r, g = palettes[1].foreground.g, b = palettes[1].foreground.b },
    { r = 0, g = 0, b = 0 },
    "the shadow pass paints the glyph shape solid black"
  )
  Assert.deepEqual(
    { r = palettes[2].foreground.r, g = palettes[2].foreground.g, b = palettes[2].foreground.b },
    { r = 255, g = 255, b = 255 },
    "the face pass paints the glyph shape solid white"
  )
end

return GraphicsSmoke.suite(T.tests)
