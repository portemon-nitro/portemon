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

-- Private worker-readable namespace for this suite's synthetic option art.
-- Never a real game version: the pool worker resolves every image through
-- this version's love-backend root, and teardown removes only this root
-- after pool disposal, so suites never share staged bytes or touch ROM
-- derived files.
local ISOLATED_VERSION = "test-options-wiring"

local function ownPool(scope, pool)
  scope:own({
    release = function()
      pcall(function()
        pool:dispose()
      end)
      CacheFs.forVersion(ISOLATED_VERSION):removeTree("")
    end,
  })
end

local function optionsCache()
  local cache = CacheFs.forVersion(ISOLATED_VERSION, FakeCache.new())
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addOptionsContract(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  FieldUiFixture.writeOptionsPngs(CacheFs.forVersion(ISOLATED_VERSION))
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
  local Interface = require("game.hgss.src.options.OptionsInterface")
  local rows = {}
  for _, id in ipairs({ "textSpeed", "battleScene", "battleStyle", "soundMode", "textFrame", "volume", "battleSpeed" }) do
    local choiceLabels = nil
    if Interface.rowKind(id) == "choice" then
      choiceLabels = {}
      for stop = 1, Interface.valueCount(id) do
        choiceLabels[stop] = id:upper() .. "_S" .. stop
      end
    end
    rows[#rows + 1] = {
      id = id,
      label = id:upper(),
      valueLabel = "V",
      value = 1,
      valueIndex = 1,
      valueCount = Interface.valueCount(id),
      choiceLabels = choiceLabels,
    }
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
  ownPool(scope, pool)
  local palettes = {}
  local tokenLines = {}
  local stubText = {}
  function stubText:drawTextWithPalette(_, _, _, palette)
    palettes[#palettes + 1] = palette
  end
  function stubText:drawLine(tokens, x, y)
    tokenLines[#tokenLines + 1] = { tokens = tokens, x = x, y = y }
    return "drawn"
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
  return resources, palettes, tokenLines
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

function T.tests.token_lines_forward_to_the_shared_glyph_renderer(scope)
  local resources, _, tokenLines = preparedWiring(scope)
  local adapter = assert(
    resources._optionsRenderer and resources._optionsRenderer._text,
    "open presentation retains its text adapter"
  )
  Assert.equal(type(adapter.drawTokenLine), "function", "the options adapter draws token lines")
  local tokens = { { kind = "glyph", code = 1, text = "A" } }
  local result = adapter:drawTokenLine(tokens, 7, 9)
  Assert.equal(result, "drawn", "the adapter returns the shared renderer result")
  Assert.equal(#tokenLines, 1, "one token line forwards to the shared renderer")
  Assert.isTrue(tokenLines[1].tokens == tokens, "tokens forward without copying")
  Assert.equal(tokenLines[1].x, 7, "the line keeps its horizontal origin")
  Assert.equal(tokenLines[1].y, 9, "the line keeps its vertical origin")
end

-- This suite stages its own complete synthetic image set under its own
-- disposable namespace: the namespace starts clean without the other suite
-- having run first, carries all four required roles where the pool worker
-- reads them, and never equals a real game version.
function T.tests.stages_a_private_complete_image_set(scope)
  local workerVisible = CacheFs.forVersion(ISOLATED_VERSION)
  workerVisible:removeTree("")
  Assert.isNil(
    workerVisible:read(FieldUiFixture.OPTIONS_CONTROLS_BACKGROUND_PATH),
    "the private namespace starts clean without another suite running first"
  )
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  Assert.equal(cache.versionId, ISOLATED_VERSION, "the staged cache carries the private namespace")
  Assert.isTrue(ISOLATED_VERSION ~= "heartgold", "the private namespace is not the HeartGold cache")
  Assert.isTrue(ISOLATED_VERSION ~= "soulsilver", "the private namespace is not the SoulSilver cache")
  Assert.equal(manifest.options.version, 3, "the staged section carries its selection-layer contract")
  Assert.equal(
    manifest.options.selectionOverlay,
    FieldUiFixture.optionsSelectionOverlayKey(),
    "the staged section indexes its selected-row strip"
  )
  for _, path in ipairs({
    FieldUiFixture.OPTIONS_CHROME_PATH,
    FieldUiFixture.OPTIONS_CONTROLS_BACKGROUND_PATH,
    FieldUiFixture.OPTIONS_PREVIEW_BACKGROUND_PATH,
    FieldUiFixture.OPTIONS_SELECTION_OVERLAY_PATH,
  }) do
    Assert.notNil(workerVisible:read(path), "the worker-readable namespace stages " .. path)
  end
  local overlay = assert(
    manifest.assets[FieldUiFixture.optionsSelectionOverlayKey()],
    "the selected-row strip asset is indexed"
  )
  Assert.equal(overlay.width, 256, "the selected-row strip width")
  Assert.equal(overlay.height, 24, "the selected-row strip height")
end

return GraphicsSmoke.suite(T.tests)
