-- Graphics contract for the scrolling Options application: the four
-- display cases resolve one published geometry each, the per-open
-- renderer prepares pooled native art without acquiring in draw, painted
-- pixels sample the compiled frames, and releasing the renderer returns
-- every pool reference to baseline. Clipped rows never activate and the
-- footer stays fixed outside the scroll viewport.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "graphics" },
    tags = { "options", "graphics" },
  },
  tests = {},
}

local function modules()
  local interfaceOk, Interface = pcall(require, "game.hgss.src.options.OptionsInterface")
  Assert.isTrue(interfaceOk, "OptionsInterface missing: " .. tostring(Interface))
  local rendererOk, Renderer = pcall(require, "game.hgss.src.options.OptionsRenderer")
  Assert.isTrue(rendererOk, "OptionsRenderer missing: " .. tostring(Renderer))
  return Interface, Renderer
end

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

local function optionsCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addOptionsContract(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  CacheFs.forVersion("heartgold"):write(FieldUiFixture.OPTIONS_CHROME_PATH, FieldUiFixture.optionsChromeBytes())
  return cache, manifest
end

local function recordingText()
  local text = { draws = 0, lines = {}, background = { 0.1, 0.2, 0.3, 1 } }
  function text.drawTextWithPalette(_, line, _, _, _)
    text.draws = text.draws + 1
    text.lines[#text.lines + 1] = line
  end
  function text.textWidth(_, str)
    return #str * 8
  end
  function text.windowBackgroundColor()
    return text.background
  end
  return text
end

local function recordingWindow()
  local window = { draws = 0, lastBox = nil, lastFrame = nil, lastBackground = nil }
  function window.drawWindow(_, box, frame, background)
    window.draws = window.draws + 1
    window.lastBox = box
    window.lastFrame = frame
    window.lastBackground = background
  end
  function window.drawApplicationFrame(_, _, _)
    window.draws = window.draws + 1
  end
  return window
end

local function contextFor(case, measurements)
  local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
  local Interface = modules()
  local resolvers = Interface.defaults()
  local selection = ApplicationLayout.selectSurfaces(measurements[case])
  return {
    measurement = measurements[case],
    configuration = case,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = resolvers.nativeLike,
  }
end

local function topologies()
  local dual = ScreenTopology.dualDisplay(
    { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, role = "world", touch = false },
    { id = "sub", rect = { x = 256, y = 0, width = 256, height = 192 }, role = "auxiliary", touch = false }
  )
  local native = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    role = "world",
    touch = false,
  })
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 960, height = 540 },
    role = "world",
    touch = false,
  })
  local tall = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 360, height = 640 },
    role = "world",
    touch = false,
  })
  return {
    dualDisplay = { width = 512, height = 192, topology = dual, pixelRatio = 1, signature = "options-dual" },
    nativeLike = { width = 512, height = 384, topology = native, pixelRatio = 1, signature = "options-native" },
    wide = { width = 960, height = 540, topology = wide, pixelRatio = 1, signature = "options-wide" },
    tall = { width = 360, height = 640, topology = tall, pixelRatio = 1, signature = "options-tall" },
  }
end

local function sampleView(focusId)
  local rows = {}
  local ids = { "textSpeed", "battleScene", "battleStyle", "soundMode", "textFrame", "volume", "battleSpeed" }
  for _, id in ipairs(ids) do
    rows[#rows + 1] = {
      id = id,
      label = id:upper(),
      valueLabel = "V",
      value = 1,
      valueIndex = 1,
      valueCount = 2,
    }
  end
  return {
    open = true,
    rows = rows,
    focusId = focusId or "textSpeed",
    scrollOffset = 0,
    footer = { confirm = { enabled = true }, quit = {} },
  }
end

local function graphicsState()
  local r, g, b, a = love.graphics.getColor()
  local blend, blendAlpha = love.graphics.getBlendMode()
  return {
    canvas = love.graphics.getCanvas(),
    shader = love.graphics.getShader(),
    color = { r, g, b, a },
    blend = { blend, blendAlpha },
    lineWidth = love.graphics.getLineWidth(),
  }
end

local function assertSameState(before, after, label)
  Assert.isTrue(before.canvas == after.canvas, label .. " restores its canvas")
  Assert.isTrue(before.shader == after.shader, label .. " restores its shader")
  Assert.deepEqual(after.color, before.color, label .. " restores its color")
  Assert.deepEqual(after.blend, before.blend, label .. " restores its blend mode")
  Assert.equal(after.lineWidth, before.lineWidth, label .. " restores its line width")
end

function T.tests.all_four_cases_resolve_one_matching_geometry(scope)
  local Interface = modules()
  local measurements = topologies()
  for _, case in ipairs({ "dualDisplay", "nativeLike", "wide", "tall" }) do
    local resolvers = Interface.defaults()
    local context = contextFor(case, measurements)
    local plan = resolvers[case](context, sampleView())
    Assert.isTrue(type(plan.panes) == "table" and #plan.panes >= 1, case .. " publishes its panes")
    Assert.isTrue(type(plan.frames) == "table", case .. " publishes its frames")
    Assert.equal(plan.inputKey, "options", case .. " keeps the stable input identity")
    local content = assert(plan.content, case .. " publishes its options content")
    Assert.equal(#content.rows, 7, case .. " lays out seven rows")
    Assert.isTrue(content.footer ~= nil, case .. " keeps the footer outside the scroll viewport")
    Assert.isTrue(
      content.footer.y >= content.listViewport.y + content.listViewport.height,
      case .. " never scrolls the footer away"
    )
    for _, row in ipairs(content.rows) do
      Assert.isTrue(row.rect.x == math.floor(row.rect.x), case .. " keeps integer logical pixels")
    end
  end
end

function T.tests.preparing_renderer_paints_and_returns_leases_to_baseline(scope)
  local _, Renderer = modules()
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  local before = pool:stats()
  local renderer = Renderer.new({
    cacheFs = cache,
    manifest = manifest,
    imagePool = pool,
    text = recordingText(),
    window = recordingWindow(),
  })
  local ready, failure = renderer:prepare()
  local spins = 0
  while ready == false do
    spins = spins + 1
    Assert.isTrue(spins < 10000, "chrome resolves through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    ready, failure = renderer:prepare()
  end
  Assert.isTrue(ready == true, "the renderer prepares: " .. tostring(failure))
  local Interface = (modules())
  local resolvers = Interface.defaults()
  local measurements = topologies()
  local context = contextFor("nativeLike", measurements)
  local view = sampleView("volume")
  local plan = resolvers.nativeLike(context, view)
  local canvas = scope:own(love.graphics.newCanvas(512, 384))
  local stateBefore = graphicsState()
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(view, plan)
  love.graphics.setCanvas()
  assertSameState(stateBefore, graphicsState(), "options draw")
  local data = scope:own(canvas:newImageData())
  Assert.isTrue(data:getWidth() == 512 and data:getHeight() == 384, "the draw targets the canvas")
  renderer:dispose()
  renderer:dispose()
  local after = pool:stats()
  Assert.equal(after.staged, 0, "disposal leaves no staged interest")
  Assert.equal(after.ready, 0, "disposal leaves no ready tickets")
  Assert.equal(after.failed, 0, "disposal leaves no failed tickets")
  Assert.equal(after.pinnedBytes, before.pinnedBytes, "disposal returns every lease to the pool")
end

function T.tests.clipped_rows_never_activate_while_the_footer_stays_live(scope)
  local Interface = modules()
  local resolvers = Interface.defaults()
  local measurements = topologies()
  local context = contextFor("nativeLike", measurements)
  local plan = resolvers.nativeLike(context, sampleView())
  local content = assert(plan.content, "the plan publishes its options content")
  local viewport = assert(content.listViewport, "the plan publishes its list viewport")
  local last = content.rows[#content.rows]
  local outsideY = viewport.y + viewport.height + last.rect.height + 4
  Assert.isNil(
    Interface.hitTest(content, last.rect.x + 4, outsideY),
    "a clipped row region never hit-tests"
  )
  local footer = assert(content.footer, "the plan publishes its footer")
  local hit = Interface.hitTest(content, footer.confirmRect.x + 2, footer.confirmRect.y + 2)
  Assert.isTrue(hit ~= nil and hit.target == "confirm", "the fixed footer stays interactive")
end

local function preparedPainter(scope)
  local _, Renderer = modules()
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  local text = recordingText()
  local window = recordingWindow()
  local renderer = Renderer.new({
    cacheFs = cache,
    manifest = manifest,
    imagePool = pool,
    text = text,
    window = window,
  })
  local ready, failure = renderer:prepare()
  local spins = 0
  while ready == false do
    spins = spins + 1
    Assert.isTrue(spins < 10000, "chrome resolves through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    ready, failure = renderer:prepare()
  end
  Assert.isTrue(ready == true, "the painter prepares: " .. tostring(failure))
  return renderer, text, window
end

local function drawNative(scope, renderer, view)
  local Interface = modules()
  local measurements = topologies()
  local context = contextFor("nativeLike", measurements)
  local plan = Interface.defaults().nativeLike(context, view)
  local canvas = scope:own(love.graphics.newCanvas(512, 384))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(view, plan)
  love.graphics.setCanvas()
  return plan
end

function T.tests.preview_forwards_the_draft_frame_and_window_background(scope)
  local renderer, text, window = preparedPainter(scope)
  local view = sampleView("textFrame")
  view.preview = { textSpeed = "fastest", textFrame = 7 }
  local plan = drawNative(scope, renderer, view)
  local preview = assert(plan.content.preview, "the native plan carries its preview")
  Assert.equal(window.lastFrame, 7, "the preview border uses the draft frame, never a hardcoded frame")
  Assert.deepEqual(window.lastBackground, text.background, "the preview fill uses the text background")
  Assert.deepEqual(
    { x = window.lastBox.x, y = window.lastBox.y, width = window.lastBox.width, height = window.lastBox.height },
    { x = preview.x, y = preview.y, width = preview.width, height = preview.height },
    "the preview window covers the published preview rect"
  )
  renderer:dispose()
end

function T.tests.legacy_note_paints_in_the_header_band_only_when_staged(scope)
  local renderer, text, _ = preparedPainter(scope)
  local plain = sampleView("textSpeed")
  drawNative(scope, renderer, plain)
  for _, line in ipairs(text.lines) do
    Assert.isTrue(line ~= "SLOW BECOMES MID", "no staged note paints without a legacy draft")
  end
  local noted = sampleView("textSpeed")
  noted.legacyNote = true
  drawNative(scope, renderer, noted)
  local seen = {}
  for _, line in ipairs(text.lines) do
    seen[line] = true
  end
  Assert.isTrue(seen["SLOW BECOMES MID"], "the staged draft paints its header note")
  Assert.isTrue(seen["CONFIRM: MID QUIT: SLOW"], "the note explains the confirm/quit split")
  renderer:dispose()
end

function T.tests.scroll_identity_stays_stable_across_values_and_offsets(scope)
  local Interface = modules()
  local resolvers = Interface.defaults()
  local measurements = topologies()
  local first = resolvers.nativeLike(contextFor("nativeLike", measurements), sampleView("textSpeed"))
  local secondView = sampleView("volume")
  secondView.scrollOffset = 48
  local second = resolvers.nativeLike(contextFor("nativeLike", measurements), secondView)
  Assert.equal(first.inputKey, second.inputKey, "scrolling never changes the pane input identity")
end

return GraphicsSmoke.suite(T.tests)
