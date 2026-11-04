-- Graphics contract for the scrolling Options application: the per-open
-- renderer prepares pooled native art without acquiring in draw, the pane
-- backing stays opaque while host pixels outside stay untouched, prepared
-- art is reused across draws with every lease released on failure paths,
-- a failed open hands its pooled renderer back for a fresh open, a failed
-- confirm paints a bounded header note until retry, the corrected screen
-- reads clean on every layout, and the composition gate proves the real
-- window and source art path. One divider test pins the laid-out control
-- boundary; detailed art shapes live with the ROM producer suite.

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
  local stateOk, ScreenState = pcall(require, "game.hgss.src.options.OptionsScreenState")
  Assert.isTrue(stateOk, "OptionsScreenState missing: " .. tostring(ScreenState))
  return Interface, Renderer, ScreenState
end

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Private worker-readable namespace for this suite's synthetic option art.
-- Never a real game version: the pool worker resolves every image through
-- this version's love-backend root, and teardown removes only this root
-- after pool disposal, so suites never share staged bytes or touch ROM
-- derived files.
local ISOLATED_VERSION = "test-options-menu"

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
  FieldUiFixture.addNamingSemantics(manifest)
  FieldUiFixture.addStartMenuIconContract(manifest)
  FieldUiFixture.addOptionsContract(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  FieldUiFixture.writeOptionsPngs(CacheFs.forVersion(ISOLATED_VERSION))
  return cache, manifest
end

-- Source token text collaborators behind direct renderer construction: they
-- record positioned glyph-stream and plain draws with the same fake glyph
-- advances the draw path measures with, so origins stay observable and
-- consistent without GPU text.
local function joinGlyphs(tokens)
  local out = {}
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      out[#out + 1] = token.text
    end
  end
  return table.concat(out)
end

local function fakeMeasure(tokens)
  local count = 0
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      count = count + 1
    end
  end
  return count * 8
end

local function recordingText()
  local text = { draws = 0, lines = {}, background = { 0.1, 0.2, 0.3, 1 } }
  function text.drawTextWithPalette(_, line, _, _, _)
    text.draws = text.draws + 1
    text.lines[#text.lines + 1] = line
  end
  function text.drawTokens(_, tokens, _, _, _)
    text.draws = text.draws + 1
    text.lines[#text.lines + 1] = joinGlyphs(tokens)
  end
  function text.drawPlain(_, line, _, _, _)
    text.draws = text.draws + 1
    text.lines[#text.lines + 1] = line
  end
  function text.measureTokens(_, tokens)
    return fakeMeasure(tokens)
  end
  function text.measurePlain(_, str)
    return #str * 8
  end
  function text.drawPreviewTokens(_, _, _, _)
    text.draws = text.draws + 1
  end
  function text.textWidth(_, str)
    return #str * 8
  end
  function text.windowBackgroundColor()
    return text.background
  end
  return text
end

local function recordingPlacedText()
  local text = { draws = {}, background = { 0.1, 0.2, 0.3, 1 } }
  function text.drawTextWithPalette(_, line, x, y, _)
    text.draws[#text.draws + 1] = { line = line, x = x, y = y }
  end
  function text.drawTokens(_, tokens, x, y, _)
    text.draws[#text.draws + 1] = { line = joinGlyphs(tokens), x = x, y = y }
  end
  function text.drawPlain(_, line, x, y, _)
    text.draws[#text.draws + 1] = { line = line, x = x, y = y }
  end
  function text.measureTokens(_, tokens)
    return fakeMeasure(tokens)
  end
  function text.measurePlain(_, str)
    return #str * 8
  end
  function text.drawPreviewTokens(_, _, _, _) end
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

local function sampleView(focusId, scrollOffset)
  local Interface = (modules())
  local rows = {}
  local ids = { "textSpeed", "battleScene", "battleStyle", "soundMode", "volume", "battleSpeed", "textFrame" }
  for _, id in ipairs(ids) do
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
    focusId = focusId or "textSpeed",
    scrollOffset = scrollOffset or 0,
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



function T.tests.preparing_renderer_paints_and_returns_leases_to_baseline(scope)
  local _, Renderer = modules()
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local before = pool:stats()
  local renderer = Renderer.new({
    cacheFs = cache,
    manifest = manifest,
    imagePool = pool,
    sliderThumb = FieldUiFixture.optionsSliderThumbVisual(),
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




local function drawPlan(scope, renderer, view, plan, width, height, prepaint)
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  if prepaint ~= nil then
    love.graphics.setColor(prepaint[1], prepaint[2], prepaint[3], prepaint[4])
    love.graphics.rectangle("fill", 0, 0, width, height)
    love.graphics.setColor(1, 1, 1, 1)
  else
    love.graphics.clear(0, 0, 0, 0)
  end
  renderer:draw(view, plan)
  love.graphics.setCanvas()
  return canvas
end

local function preparedPlacedPainter(scope)
  local _, Renderer = modules()
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local text = recordingPlacedText()
  local window = recordingWindow()
  local renderer = Renderer.new({
    cacheFs = cache,
    manifest = manifest,
    imagePool = pool,
    sliderThumb = FieldUiFixture.optionsSliderThumbVisual(),
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
  return renderer, text, window, pool
end

local function quantizePixel(data, x, y)
  local r, g, b, a = data:getPixel(x, y)
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  return { quantize(r), quantize(g), quantize(b), quantize(a) }
end

-- Collaborator recording both plain-string draws and glyph-stream draws
-- with their logical origins, so source-label placement is observable
-- without GPU text.
local function tokenRecordingText()
  local text = { plain = {}, tokens = {}, tokenLines = {}, background = { 0.1, 0.2, 0.3, 1 } }
  function text.drawTextWithPalette(_, line, x, y, _)
    text.plain[#text.plain + 1] = { line = line, x = x, y = y }
  end
  function text.drawLineWithPalette(_, tokens, x, y, palette)
    text.tokens[#text.tokens + 1] = { tokens = tokens, x = x, y = y, palette = palette }
  end
  function text.drawTokens(_, tokens, x, y, role)
    text.tokens[#text.tokens + 1] = { tokens = tokens, x = x, y = y, role = role }
  end
  function text.drawPlain(_, line, x, y, role)
    text.plain[#text.plain + 1] = { line = line, x = x, y = y, role = role }
  end
  function text.measureTokens(_, tokens)
    return fakeMeasure(tokens)
  end
  function text.measurePlain(_, str)
    return #str * 8
  end
  function text.drawPreviewTokens(_, tokens, x, y)
    text.tokenLines[#text.tokenLines + 1] = { tokens = tokens, x = x, y = y }
  end
  function text.textWidth(_, str)
    return #str * 8
  end
  function text.windowBackgroundColor()
    return text.background
  end
  return text
end

-- Production screen snapshot over the synthetic source-shaped labels: the
-- same semantic view the presented path resolves and paints.
local function headlessSourceView(overrides, navigateToQuit)
  local _, _, ScreenState = modules()
  local playerOptions = {
    textSpeed = "mid",
    battleScene = true,
    battleStyle = "shift",
    soundMode = "stereo",
    textFrame = 0,
    battleSpeed = 1,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      playerOptions[key] = value
    end
  end
  local port = {
    read = function()
      return 80
    end,
    preview = function(_) end,
    commit = function(_) end,
    restore = function() end,
  }
  local state = ScreenState.new({
    playerOptions = playerOptions,
    volume = 80,
    preparePlayerOptions = function()
      return {
        apply = function() end,
        rollback = function() end,
      }
    end,
    audioPreferences = port,
    applyChannelMode = function(_) end,
    effect = function(_) end,
    semantic = FieldUiFixture.optionsSourceSemantic(),
  })
  if navigateToQuit then
    for _ = 1, 7 do
      state:updateFixed({ { type = "navigate", direction = "down" } })
    end
    state:updateFixed({ { type = "navigate", direction = "right" } })
    Assert.equal(state:status().focusId, "quit", "the footer Quit action focuses")
  end
  return state:status()
end

local function joinRecordedGlyphs(tokens)
  local out = {}
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      out[#out + 1] = token.text
    end
  end
  return table.concat(out)
end

local function findPlacedLine(draws, line)
  for _, draw in ipairs(draws) do
    if draw.line == line then
      return draw
    end
  end
  return nil
end

-- The source header and footer keep their own windows: the title paints at
-- its header origin, each footer action hit-tests and paints inside its
-- own label window without covering the other, the selected-row strip
-- backs only scrolled rows (never the footer), and the staged migration
-- note sits right of the title instead of over it.

-- Choice chrome follows the row, not the stop count: the three-stop and
-- first two-stop rows wear the narrow pill while the remaining two-stop
-- rows wear the wide pill, sprite anchors and touch regions match per row,
-- arrows sit at their own anchors, and the frame value centers about its
-- position instead of starting there.

-- Choice chrome layers like the source screen: every stop paints its
-- opaque printed face, and the chosen stop paints its selected sprite
-- over that same print, so transparent sprite pixels reveal the print
-- instead of the scrubbed plate and the backing never changes with the
-- value. Unselected stops paint exactly one face each.

-- The two-stop Battle Scene row is the narrow exception: it wears the small
-- pill like the three-stop row while the other two-stop rows wear the
-- wide pill. Anchors, touch regions, and chrome colors agree per row.

-- The menu-local sample paginates from the preview font definition: opening
-- presented options loads the preview font for its printer metrics instead
-- of reusing the menu font.

-- Labels paint once from their own chrome: no duplicated shadow pass, no
-- footer or arrow chrome lingering at the old broad rectangles once the
-- native anchors move in.




function T.tests.pane_backing_stays_opaque_while_host_pixels_outside_stay_untouched(scope)
  local Interface, Renderer = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local renderer = Renderer.new({
    cacheFs = cache,
    manifest = manifest,
    imagePool = pool,
    sliderThumb = FieldUiFixture.optionsSliderThumbVisual(),
    text = recordingPlacedText(),
    window = recordingWindow(),
  })
  local ready, failure = renderer:prepare()
  local spins = 0
  while ready == false do
    spins = spins + 1
    Assert.isTrue(spins < 10000, "backdrops resolve through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    ready, failure = renderer:prepare()
  end
  Assert.isTrue(ready == true, "the painter prepares: " .. tostring(failure))
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = sampleView("textSpeed", 0)
  local plan = resolvers.wide(contextFor("wide", measurements), view)
  local placement = assert(plan.panes[1].placement, "the wide plan places its pane")
  local canvas = drawPlan(scope, renderer, view, plan, 960, 540, { 1, 0, 1, 1 })
  local data = scope:own(canvas:newImageData())
  local hx, hy = LayoutGeometry.logicalToHost(placement, 6, 190)
  Assert.deepEqual(
    quantizePixel(data, hx, hy),
    { 190, 80, 30, 255 },
    "every footer-shell pixel is source-backed opaque"
  )
  Assert.deepEqual(
    quantizePixel(data, 5, 5),
    { 255, 0, 255, 255 },
    "host pixels outside the pane keep their prepainted color"
  )
  renderer:dispose()
end


function T.tests.prepared_art_is_reused_across_draws_and_failures_release_everything(scope)
  local Interface, Renderer = modules()
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local baseline = pool:stats()
  local realNewQuad = love.graphics.newQuad
  local quadCalls = 0
  love.graphics.newQuad = function(...)
    quadCalls = quadCalls + 1
    return realNewQuad(...)
  end
  local outcome = nil
  local function run()
    local renderer = Renderer.new({
      cacheFs = cache,
      manifest = manifest,
      imagePool = pool,
      sliderThumb = FieldUiFixture.optionsSliderThumbVisual(),
      text = recordingText(),
      window = recordingWindow(),
    })
    local ready = renderer:prepare()
    local spins = 0
    while ready == false do
      spins = spins + 1
      Assert.isTrue(spins < 10000, "chrome resolves through the pool worker")
      if love.timer ~= nil then
        love.timer.sleep(0.001)
      end
      ready = renderer:prepare()
    end
    Assert.isTrue(ready == true, "the painter prepares")
    local built = quadCalls
    Assert.isTrue(built > 0, "preparation prebuilds the chrome quads")
    local requestsAfterPrepare = pool:stats().requests
    local topView = sampleView("textSpeed", 0)
    drawPlan(scope, renderer, topView, resolvers.nativeLike(contextFor("nativeLike", measurements), topView), 512, 384)
    local movedView = sampleView("textSpeed", 48)
    drawPlan(
      scope,
      renderer,
      movedView,
      resolvers.nativeLike(contextFor("nativeLike", measurements), movedView),
      512,
      384
    )
    local dualView = sampleView("volume", 0)
    dualView.preview = { textSpeed = "mid", textFrame = 1 }
    drawPlan(
      scope,
      renderer,
      dualView,
      resolvers.dualDisplay(contextFor("dualDisplay", measurements), dualView),
      512,
      192
    )
    Assert.equal(quadCalls, built, "repeated draws reuse prepared quads, including scroll changes")
    Assert.equal(pool:stats().requests, requestsAfterPrepare, "draws acquire no new image leases")
    renderer:dispose()
    renderer:dispose()
    local settled = pool:stats()
    Assert.equal(settled.staged, 0, "disposal leaves no staged interest")
    Assert.equal(settled.ready, 0, "disposal leaves no ready tickets")
    Assert.equal(settled.failed, 0, "disposal leaves no failed tickets")
    Assert.equal(settled.pinnedBytes, baseline.pinnedBytes, "disposing twice returns every lease")
  end
  local ok, err = pcall(run)
  love.graphics.newQuad = realNewQuad
  Assert.isTrue(ok, "the reuse check runs: " .. tostring(err))
  local cache2, manifest2 = optionsCache()
  local pool2 = ImageAssetPool.new(cache2)
  scope:own({
    release = function()
      pool2:dispose()
    end,
  })
  local baseline2 = pool2:stats()
  local failingNewQuad = love.graphics.newQuad
  local failingCalls = 0
  love.graphics.newQuad = function(...)
    failingCalls = failingCalls + 1
    if failingCalls == 3 then
      error("injected quad failure", 0)
    end
    return failingNewQuad(...)
  end
  local failed = nil
  local brokenOk, brokenErr = pcall(function()
    local broken = Renderer.new({
      cacheFs = cache2,
      manifest = manifest2,
      imagePool = pool2,
      sliderThumb = FieldUiFixture.optionsSliderThumbVisual(),
      text = recordingText(),
      window = recordingWindow(),
    })
    local spins = 0
    while failed == nil do
      spins = spins + 1
      Assert.isTrue(spins < 10000, "the failing preparation terminates")
      local stepOk, stepResult = pcall(function()
        return broken:prepare()
      end)
      if not stepOk then
        failed = stepResult
        break
      end
      if stepResult == true then
        break
      end
      if love.timer ~= nil then
        love.timer.sleep(0.001)
      end
    end
    broken:dispose()
  end)
  love.graphics.newQuad = failingNewQuad
  Assert.isTrue(brokenOk, "the failure check runs: " .. tostring(brokenErr))
  Assert.isTrue(failed ~= nil, "a later quad failure surfaces instead of half-ready rendering")
  Assert.isTrue(tostring(failed):find("injected quad failure", 1, true) ~= nil, "the original quad cause propagates")
  local cleaned = pool2:stats()
  Assert.equal(cleaned.staged, 0, "a failed preparation leaves no staged interest")
  Assert.equal(cleaned.ready, 0, "a failed preparation leaves no ready tickets")
  Assert.equal(cleaned.failed, 0, "a failed preparation leaves no failed tickets")
  Assert.equal(cleaned.pinnedBytes, baseline2.pinnedBytes, "a failed preparation unwinds earlier leases")
  local fresh = Renderer.new({
    cacheFs = cache2,
    manifest = manifest2,
    imagePool = pool2,
    sliderThumb = FieldUiFixture.optionsSliderThumbVisual(),
    text = recordingText(),
    window = recordingWindow(),
  })
  local freshReady = fresh:prepare()
  local freshSpins = 0
  while freshReady == false do
    freshSpins = freshSpins + 1
    Assert.isTrue(freshSpins < 10000, "a fresh renderer resolves through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    freshReady = fresh:prepare()
  end
  Assert.isTrue(freshReady == true, "a fresh renderer prepares after the failure")
  local freshView = sampleView("textSpeed", 0)
  drawPlan(scope, fresh, freshView, resolvers.nativeLike(contextFor("nativeLike", measurements), freshView), 512, 384)
  fresh:dispose()
  local resettled = pool2:stats()
  Assert.equal(resettled.pinnedBytes, baseline2.pinnedBytes, "the fresh renderer releases its leases")
end


-- A failed open hands its pooled renderer back: the retained per-open
-- owner clears, every lease returns, and a fresh open paints normally.


-- A failed open hands its pooled renderer back: the retained per-open
-- owner clears, every lease returns, and a fresh open paints normally.
function T.tests.failed_open_returns_the_pooled_renderer_for_a_fresh_open(scope)
  local Resources = require("game.hgss.src.field.FieldPresentationResources")
  local Coordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
  local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local stubText = {
    fontDef = {
      glyphs = { [0] = { advance = 8 } },
      letterSpacing = 0,
      charmap = {},
      palette = {
        [1] = { r = 0, g = 0, b = 0 },
        [2] = { r = 1, g = 0, b = 0 },
        [3] = { r = 0, g = 1, b = 0 },
        [16] = { r = 0, g = 0, b = 1 },
      },
    },
  }
  function stubText.drawTextWithPalette(_, _, _, _, _) end
  function stubText.drawLine(_, _, _, _)
    return "drawn"
  end
  function stubText.textWidth(_, _)
    return 8
  end
  function stubText.windowBackgroundColor()
    return { 0.1, 0.2, 0.3, 1 }
  end
  local stubWindow = {}
  function stubWindow.drawWindow(_, _, _, _) end
  function stubWindow.drawApplicationFrame(_, _, _) end
  local resources = setmetatable({
    cacheFs = cache,
    uiManifest = manifest,
    bagManifest = {
      interactive = {
        overlays = {
          quantity = {
            visuals = {
              decrement = {
                pressed = FieldUiFixture.optionsSliderThumbVisual(),
              },
            },
          },
        },
      },
    },
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
  local baseline = pool:stats().pinnedBytes
  FieldUiFixture.writeFont(cache, 1)
  local frameIndexes = {}
  for slot = 0, 19 do
    frameIndexes[slot] = true
  end
  local runtime = {
    cacheFs = cache,
    playerData = {
      profile = {},
      options = {
        textSpeed = "mid",
        textFrame = 0,
        battleStyle = "shift",
        battleScene = true,
        soundMode = "stereo",
        battleSpeed = 1,
      },
    },
    playerDataContext = { frameIndexes = frameIndexes },
    audioPreferences = {
      read = function()
        return 80
      end,
      preview = function(_) end,
      commit = function(_) end,
      restore = function() end,
    },
    uiManifest = {
      options = {},
      dialogueFrames = { continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 } },
    },
    fontDef = { glyphs = { [0] = { advance = 8 } } },
    presentationDisplay = topologies().nativeLike,
  }
  runtime.optionsPresentationFactory = function()
    return resources:openOptionsPresentation()
  end
  local coordinator = Coordinator.new(runtime)
  local factory = nil
  for _, descriptor in ipairs(coordinator:applicationDescriptors()) do
    if descriptor.id == FieldApplicationIds.OPTIONS then
      factory = descriptor.factory
    end
  end
  Assert.notNil(factory, "the field catalogue registers the options destination")
  local ok, err = pcall(factory)
  Assert.isFalse(ok, "a missing generated preview message fails the open")
  Assert.isTrue(err ~= nil, "the failure propagates its cause")
  Assert.isNil(resources._optionsRenderer, "the failed open retains no per-open renderer")
  Assert.equal(pool:stats().pinnedBytes, baseline, "the failed open returns every lease")
  runtime.uiManifest.options = {
    labels = manifest.options.labels,
    framePreviewText = {
      [0] = {
        text = "HI",
        tokens = {
          { kind = "glyph", text = "H", code = 1 },
          { kind = "glyph", text = "I", code = 1 },
          { kind = "eos" },
        },
      },
    },
  }
  local screen = factory()
  Assert.isTrue(screen:status().open, "a fresh open works after the failure")
  Assert.notNil(resources._optionsRenderer, "the fresh open retains its renderer while open")
  screen:dispose()
  Assert.isNil(resources._optionsRenderer, "disposal releases the fresh renderer")
  Assert.equal(pool:stats().pinnedBytes, baseline, "the fresh disposal returns every lease")
end

-- The closing sample scrolls with its own row on every display case:
-- one tall viewport, one pinned footer, no fixed copy, and a decorative
-- upper pane. Hidden at the top, fully shown at the far end.

-- Every suite stages its own complete synthetic image set under its own
-- disposable namespace: the namespace starts clean without another suite
-- having run first, carries every required role (chrome, header/footer
-- shell bands, preview, strip, and row plates) where the pool worker
-- reads them, and never equals a real game version.


-- Every suite stages its own complete synthetic image set under its own
-- disposable namespace: the namespace starts clean without another suite
-- having run first, carries every required role (chrome, header/footer
-- shell bands, preview, strip, and row plates) where the pool worker
-- reads them, and never equals a real game version.
function T.tests.stages_a_private_complete_image_set(scope)
  local workerVisible = CacheFs.forVersion(ISOLATED_VERSION)
  workerVisible:removeTree("")
  Assert.isNil(
    workerVisible:read(FieldUiFixture.OPTIONS_HEADER_BACKGROUND_PATH),
    "the private namespace starts clean without another suite running first"
  )
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  Assert.equal(cache.versionId, ISOLATED_VERSION, "the staged cache carries the private namespace")
  Assert.isTrue(ISOLATED_VERSION ~= "heartgold", "the private namespace is not the HeartGold cache")
  Assert.isTrue(ISOLATED_VERSION ~= "soulsilver", "the private namespace is not the SoulSilver cache")
  Assert.equal(manifest.options.version, 7, "the staged section carries its indicator contract")
  Assert.equal(
    manifest.options.selectionOverlay,
    FieldUiFixture.optionsSelectionOverlayKey(),
    "the staged section indexes its selected-row strip"
  )
  for _, path in ipairs({
    FieldUiFixture.OPTIONS_CHROME_PATH,
    FieldUiFixture.OPTIONS_HEADER_BACKGROUND_PATH,
    FieldUiFixture.OPTIONS_FOOTER_BACKGROUND_PATH,
    FieldUiFixture.OPTIONS_PREVIEW_BACKGROUND_PATH,
    FieldUiFixture.OPTIONS_SELECTION_OVERLAY_PATH,
    FieldUiFixture.OPTIONS_ROW_ODD_PATH,
    FieldUiFixture.OPTIONS_ROW_EVEN_PATH,
    FieldUiFixture.OPTIONS_ROW_FRAME_PATH,
    FieldUiFixture.OPTIONS_SLIDER_THUMB_PATH,
  }) do
    Assert.notNil(workerVisible:read(path), "the worker-readable namespace stages " .. path)
  end
  local overlay =
    assert(manifest.assets[FieldUiFixture.optionsSelectionOverlayKey()], "the selected-row strip asset is indexed")
  Assert.equal(overlay.width, 256, "the selected-row strip width")
  Assert.equal(overlay.height, 30, "the selected-row strip height")
end

-- Held, quick, and cancelled presses paint the exact compiled source
-- frames: the held arrow advances through its pressed sequence in source
-- ticks, the tapped footer shows its pressed action state, and a press
-- with no visual record falls back to idle art.

-- A rejected confirmation paints a bounded failure note in the reserved
-- header band beside the intact title, suppresses the migration note,
-- and disappears once the retry succeeds.


-- A rejected confirmation paints a bounded failure note in the reserved
-- header band beside the intact title, suppresses the migration note,
-- and disappears once the retry succeeds.
function T.tests.failed_confirm_paints_a_bounded_header_note_until_retry(scope)
  local Interface = modules()
  local renderer, text, _ = preparedPlacedPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = headlessSourceView()
  view.legacyNote = true
  view.error = "SAVE_WRITE_FAILED: disk is full"
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  text.draws = {}
  drawPlan(scope, renderer, view, plan, 512, 384)
  local title = findPlacedLine(text.draws, "OPTIONS")
  Assert.notNil(title, "the title survives a failed confirm")
  Assert.equal(title.x, 10, "the title keeps its header origin beside the failure note")
  Assert.equal(title.y, 5, "the title keeps its header row")
  local failed = findPlacedLine(text.draws, "APPLY FAILED")
  Assert.notNil(failed, "a failed confirm paints its bounded header note")
  Assert.isTrue(failed.x >= 116, "the failure note stays right of the title")
  Assert.isTrue(failed.x + #failed.line * 8 <= 248, "the failure note stays inside the header band")
  Assert.isTrue(failed.y >= 4 and failed.y <= 22, "the failure note stays inside the fixed header")
  local retry = findPlacedLine(text.draws, "RETRY")
  Assert.notNil(retry, "the failure note names its retry")
  Assert.isTrue(retry.x >= 116, "the retry hint stays right of the title")
  Assert.isTrue(retry.x + #retry.line * 8 <= 248, "the retry hint stays inside the header band")
  Assert.isTrue(retry.y >= 4 and retry.y <= 22, "the retry hint stays inside the fixed header")
  Assert.isNil(findPlacedLine(text.draws, "SLOW BECOMES MID"), "the failure note overrides the migration note")
  local cleared = headlessSourceView()
  local clearPlan = resolvers.nativeLike(contextFor("nativeLike", measurements), cleared)
  text.draws = {}
  drawPlan(scope, renderer, cleared, clearPlan, 512, 384)
  Assert.isNil(findPlacedLine(text.draws, "APPLY FAILED"), "a retried confirm clears the header note")
  Assert.notNil(findPlacedLine(text.draws, "OPTIONS"), "the title paints without a failure")
  renderer:dispose()
end

-- The full corrected screen reads clean on every layout: the title at
-- its header origin, all seven row labels inside their bands, distinct
-- footer actions, the frame value and its sample only when revealed, the
-- bounded failure note when set, and no diagnostic marker text.


-- The full corrected screen reads clean on every layout: the title at
-- its header origin, all seven row labels inside their bands, distinct
-- footer actions, the frame value and its sample only when revealed, the
-- bounded failure note when set, and no diagnostic marker text.
function T.tests.corrected_options_screen_reads_clean_on_every_layout(scope)
  local Interface = modules()
  local renderer, text, window = preparedPlacedPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local expectedLabels = {
    "TEXT SPEED",
    "BATTLE SCENE",
    "BATTLE STYLE",
    "SOUND",
    "FRAME",
    "VOLUME",
    "BATTLE SPEED",
  }
  for _, case in ipairs({ "dualDisplay", "nativeLike", "wide", "tall" }) do
    local context = contextFor(case, measurements)
    local top = headlessSourceView()
    local topPlan = resolvers[case](context, top)
    local content = assert(topPlan.content, case .. " publishes its list")
    Assert.equal(#content.rows, 7, case .. " lays out all seven settings")
    Assert.equal(content.footer.y, 168, case .. " pins its footer")
    text.draws = {}
    window.draws = 0
    drawPlan(scope, renderer, top, topPlan, measurements[case].width, measurements[case].height)
    local title = findPlacedLine(text.draws, "OPTIONS")
    Assert.notNil(title, case .. " paints its title at the top")
    Assert.equal(title.x, 10, case .. " keeps the title header origin")
    Assert.equal(title.y, 5, case .. " keeps the title header row")
    for _, label in ipairs(expectedLabels) do
      local drawn = findPlacedLine(text.draws, label)
      if label == "FRAME" then
        Assert.isNil(drawn, case .. " clips the frame row at the top")
      else
        Assert.notNil(drawn, case .. " paints " .. label)
        Assert.isTrue(drawn.x >= 12 and drawn.x <= 112, case .. " keeps " .. label .. " in its band")
      end
    end
    local confirm = findPlacedLine(text.draws, "CONFIRM")
    local quit = findPlacedLine(text.draws, "QUIT")
    Assert.notNil(confirm, case .. " paints its confirm action")
    Assert.notNil(quit, case .. " paints its quit action")
    Assert.isTrue(confirm.x < quit.x, case .. " keeps its footer actions distinct")
    Assert.isTrue(confirm.y >= 168 and quit.y >= 168, case .. " keeps its footer below the list")
    for _, draw in ipairs(text.draws) do
      Assert.isNil(draw.line:find("{", 1, true), case .. " paints no diagnostic marker")
    end
    Assert.equal(window.draws, 0, case .. " hides the sample at the top")
    local bottom = headlessSourceView()
    bottom.focusId = "textFrame"
    bottom.scrollOffset = 72
    bottom.error = "SAVE_WRITE_FAILED: disk is full"
    local bottomPlan = resolvers[case](contextFor(case, measurements), bottom)
    text.draws = {}
    window.draws = 0
    drawPlan(scope, renderer, bottom, bottomPlan, measurements[case].width, measurements[case].height)
    local frameLabel = findPlacedLine(text.draws, "FRAME")
    Assert.notNil(frameLabel, case .. " paints its frame row when revealed")
    local value = findPlacedLine(text.draws, "TYPE 1")
    Assert.notNil(value, case .. " paints its frame value when revealed")
    Assert.equal(value.x + math.floor(#"TYPE 1" * 8 / 2), 180, case .. " centers its frame value about 180")
    Assert.equal(window.draws, 1, case .. " paints the revealed sample exactly once")
    Assert.deepEqual(
      { x = window.lastBox.x, y = window.lastBox.y, width = window.lastBox.width, height = window.lastBox.height },
      { x = 16, y = 176, width = 216, height = 32 },
      case .. " nests the revealed sample in its row"
    )
    local failed = findPlacedLine(text.draws, "APPLY FAILED")
    Assert.notNil(failed, case .. " keeps its failure note on the corrected screen")
    Assert.isTrue(failed.x >= 116 and failed.x + #failed.line * 8 <= 248, case .. " bounds its failure note")
  end
  renderer:dispose()
end

-- The scrolling list paints moving source row plates over the stale base:
-- odd, even, and frame plates track their content rows at every offset,
-- so no stationary face art leaks through the sliders or scrolled rows.

-- The row replacement never moves the fixed chrome: the header, footer,
-- and upper preview keep their source pixels while only the clipped list
-- scrolls beneath them.

-- The focused indicator paints over its row's plates and chrome: the
-- 30px border box centers on the focused selector band at any offset so
-- both side bars survive opaque pill faces, the overhanging bottom edge
-- lands on the next row, and footer focus hides the list strip entirely.

-- The added plates join the pooled lifecycle without regressing it:
-- preparation acquires them once, repeated draws reuse them, disposal
-- returns every lease, and an incomplete plate class fails visibly.

-- Slider values keep a measured window clear of their rail: every
-- supported volume and speed label paints right-aligned inside its own
-- slot from the text collaborator's advances, while rails and thumbs stay
-- inside their own track with a gap between the regions, in either focus.
-- Composition gate: the production renderer over source-shaped art must keep
-- every choice center on its decomp window-relative glyph center, clip
-- 32px-tall face art to its own row, center the borrowed slider thumb on
-- the track with no white square remnant, reveal the full 72px frame item at
-- maximum scroll, and paint only shell bands over a hostile base. The
-- renderer draws through the real field window renderer here (never the
-- recording stub), so the sample window paints production frame art.
-- This single real-window composition subsumes the retired offset/layout
-- matrices; cheap unit tests keep stop arithmetic and pointer state.

-- Composition gate: the production renderer over source-shaped art must keep
-- every choice center on its decomp window-relative glyph center, clip
-- 32px-tall face art to its own row, center the borrowed slider thumb on
-- the track with no white square remnant, reveal the full 72px frame item at
-- maximum scroll, and paint only shell bands over a hostile base. The
-- renderer draws through the real field window renderer here (never the
-- recording stub), so the sample window paints production frame art.
-- This single real-window composition subsumes the retired offset/layout
-- matrices; cheap unit tests keep stop arithmetic and pointer state.
function T.tests.options_composition_gate_uses_real_window_and_source_art(scope)
  local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
  local Interface, Renderer = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local Widgets = require("game.hgss.src.ui.OptionsWidgets")
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local cache, manifest = optionsCache()
  CacheFs.forVersion(ISOLATED_VERSION):write(FieldUiFixture.STRIP_PATH, FieldUiFixture.stripBytes())
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local text = tokenRecordingText()
  local window = scope:own(FieldWindowRenderer.new({ cacheFs = CacheFs.forVersion(ISOLATED_VERSION), manifest = manifest }))
  local renderer = Renderer.new({
    cacheFs = cache,
    manifest = manifest,
    imagePool = pool,
    sliderThumb = FieldUiFixture.optionsSliderThumbVisual(),
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
  local oddR, oddG, oddB = FieldUiFixture.optionsRowOddColor()
  local evenR, evenG, evenB = FieldUiFixture.optionsRowEvenColor()
  local frameR, frameG, frameB = FieldUiFixture.optionsRowFrameColor()
  local headR, headG, headB = FieldUiFixture.optionsHeaderBackgroundColor()
  local footR, footG, footB = FieldUiFixture.optionsFooterBackgroundColor()
  local borderR, borderG, borderB = FieldUiFixture.optionsSelectionOverlayBorderColor()
  local thumbInk = { 20, 170, 190, 255 }
  local function planFor(view, case)
    return resolvers[case](contextFor(case, measurements), view)
  end
  local function at(data, placement, lx, ly)
    local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
    return quantizePixel(data, hx, hy)
  end
  local function centerOf(draw)
    local width
    if draw.tokens ~= nil then
      width = text:measureTokens(draw.tokens)
    else
      width = text:measurePlain(draw.line)
    end
    return draw.x + math.floor(width / 2)
  end
  local function findDraw(word)
    for _, draw in ipairs(text.tokens) do
      if joinRecordedGlyphs(draw.tokens) == word then
        return draw
      end
    end
    for _, draw in ipairs(text.plain) do
      if draw.line == word then
        return draw
      end
    end
    return nil
  end
  -- (a) Choice glyph-ink centers match the decomp screen centers
  -- (window origin x=8, centers window-relative +8): text speed
  -- {132,180,228}, battle scene {132,180}, battle style and sound
  -- {140,220}, frame value 180. The constants below are the decomp
  -- truth, never recomputed from the production hit bands.
  local defaultView = headlessSourceView()
  local defaultPlan = planFor(defaultView, "nativeLike")
  text.tokens = {}
  text.plain = {}
  drawPlan(scope, renderer, defaultView, defaultPlan, 512, 384)
  for _, stop in ipairs({
    { word = "MID", center = 132, label = "text-speed stop 1" },
    { word = "FAST", center = 180, label = "text-speed stop 2" },
    { word = "ON", center = 132, label = "battle-scene stop 1" },
    { word = "OFF", center = 180, label = "battle-scene stop 2" },
    { word = "SHIFT", center = 140, label = "battle-style stop 1" },
    { word = "SET", center = 220, label = "battle-style stop 2" },
    { word = "STEREO", center = 140, label = "sound stop 1" },
    { word = "MONO", center = 220, label = "sound stop 2" },
  }) do
    local draw = assert(findDraw(stop.word), stop.label .. " paints " .. stop.word)
    Assert.equal(centerOf(draw), stop.center, stop.label .. " centers glyph ink about " .. stop.center)
  end
  -- The frame value only paints once its row scrolls into view.
  local frameView = headlessSourceView()
  frameView.focusId = "textFrame"
  frameView.scrollOffset = 72
  local framePlan = planFor(frameView, "nativeLike")
  text.tokens = {}
  text.plain = {}
  drawPlan(scope, renderer, frameView, framePlan, 512, 384)
  local frameValue = assert(findDraw("TYPE 1"), "frame value paints TYPE 1")
  Assert.equal(centerOf(frameValue), 180, "frame value centers glyph ink about 180")
  local turboView = headlessSourceView({ textSpeed = "fastest" })
  local turboPlan = planFor(turboView, "nativeLike")
  text.tokens = {}
  text.plain = {}
  drawPlan(scope, renderer, turboView, turboPlan, 512, 384)
  local turbo = assert(findDraw("TURBO"), "turbo paints its selected stop")
  Assert.equal(centerOf(turbo), 228, "the narrow turbo stop centers glyph ink about 228")
  -- (b) 32px-tall face art never spills into a neighbor: the focused
  -- row's top edge and gap pixels keep their own plate or strip border
  -- while the row above would paint its own face colors there.
  for _, offset in ipairs({ 0, 32 }) do
    local view = headlessSourceView()
    view.focusId = "battleStyle"
    view.scrollOffset = offset
    local plan = planFor(view, "nativeLike")
    local placement = assert(plan.panes[1].placement, "the native plan places its pane at offset " .. offset)
    local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
    local data = scope:own(canvas:newImageData())
    local shift = offset
    Assert.deepEqual(
      at(data, placement, 120, 72 - shift),
      { 200, 200, 40, 255 },
      "the focused wide row keeps its selected face at offset " .. offset
    )
    Assert.deepEqual(
      at(data, placement, 200, 72 - shift),
      { 40, 40, 200, 255 },
      "the focused wide row keeps its unselected face at offset " .. offset
    )
    Assert.deepEqual(
      at(data, placement, 184, 72 - shift),
      { oddR, oddG, oddB, 255 },
      "the focused face gap keeps its own plate where the box middle stays transparent at offset " .. offset
    )
    Assert.deepEqual(
      at(data, placement, 2, 84 - shift),
      { borderR, borderG, borderB, 255 },
      "the focused left bar paints over the plate at offset " .. offset
    )
    Assert.deepEqual(
      at(data, placement, 184, 76 - shift),
      { oddR, oddG, oddB, 255 },
      "the focused face gap keeps its own plate below the strip at offset " .. offset
    )
    -- The second row keeps mid-row plate where the text-speed stop 3
    -- would spill without the clip (mid-row stays inside the viewport
    -- at both offsets, unlike the clipped row top at offset 32).
    Assert.deepEqual(
      at(data, placement, 220, 60 - shift),
      { evenR, evenG, evenB, 255 },
      "the narrow second row keeps its own plate above the spill at offset " .. offset
    )
    Assert.deepEqual(
      at(data, placement, 120, 122 - shift),
      { oddR, oddG, oddB, 255 },
      "the slider band top keeps its plate below the wide spill at offset " .. offset
    )
    Assert.deepEqual(
      at(data, placement, 200, 122 - shift),
      { oddR, oddG, oddB, 255 },
      "the slider band keeps its plate clear of the neighbor faces at offset " .. offset
    )
  end
  -- (c) The borrowed thumb centers on the track value at
  -- the first, middle, and last volume stops; the thumb fills its row
  -- and no white square pixels remain anywhere near the stop.
  for _, stop in ipairs({ { index = 1 }, { index = 51 }, { index = 101 } }) do
    local view = headlessSourceView()
    for _, row in ipairs(view.rows) do
      if row.id == "volume" then
        row.valueIndex = stop.index
      end
    end
    local plan = planFor(view, "nativeLike")
    local content = assert(plan.content, "the plan carries its list")
    local volumeRow = nil
    for _, row in ipairs(content.rows) do
      if row.id == "volume" then
        volumeRow = row
      end
    end
    local slider = assert(volumeRow ~= nil and volumeRow.control.slider, "the volume row carries its rail")
    local stopX = math.floor(slider.thumbRect.x + slider.thumbRect.width / 2)
    local railY = math.floor(slider.centerY + content.listViewport.y - content.scrollOffset)
    local placement = assert(plan.panes[1].placement, "the native plan places its pane")
    local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
    local data = scope:own(canvas:newImageData())
    Assert.deepEqual(
      at(data, placement, stopX, railY),
      thumbInk,
      "the thumb centers on the track at volume stop " .. stop.index
    )
    Assert.deepEqual(
      at(data, placement, stopX, railY - 4),
      thumbInk,
      "the thumb body covers the rail at volume stop " .. stop.index
    )
    Assert.deepEqual(
      at(data, placement, stopX, railY - 11),
      thumbInk,
      "the thumb reaches its top edge above the rail at volume stop " .. stop.index
    )
    Assert.deepEqual(
      at(data, placement, stopX, railY + 11),
      thumbInk,
      "the thumb reaches its bottom edge below the rail at volume stop " .. stop.index
    )
    Assert.deepEqual(
      at(data, placement, stopX - 20, railY - 8),
      { oddR, oddG, oddB, 255 },
      "the plate stays clear beside the thumb at volume stop " .. stop.index
    )
    local white, whiteAt = false, ""
    for ly = railY - 14, railY - 2 do
      for lx = stopX - 12, stopX + 12 do
        local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
        local sampled = quantizePixel(data, hx, hy)
        if sampled[1] >= 240 and sampled[2] >= 240 and sampled[3] >= 240 and sampled[4] == 255 then
          white, whiteAt = true, lx .. "," .. ly
          break
        end
      end
      if white then
        break
      end
    end
    Assert.isFalse(white, "no white square pixels remain near volume stop " .. stop.index .. " at " .. whiteAt)
  end
  -- (d) The full 72px frame item is revealed at maximum scroll on the
  -- native and one resized topology: the plate's top 8px band shows
  -- clear of the row chrome, and the sample window's own top and bottom
  -- 8px span borders (draft frame 0 tiles 2 and 14 over the synthetic
  -- frame strip) paint intact above the fixed footer.
  for _, case in ipairs({ "nativeLike", "wide" }) do
    local view = headlessSourceView()
    view.focusId = "confirm"
    view.scrollOffset = 72
    local plan = planFor(view, case)
    local placement = assert(plan.panes[1].placement, case .. " places its pane")
    local canvas = drawPlan(scope, renderer, view, plan, measurements[case].width, measurements[case].height)
    local data = scope:own(canvas:newImageData())
    for _, edgeY in ipairs({ 96, 99, 102 }) do
      for _, edgeX in ipairs({ 2, 250, 252 }) do
        Assert.deepEqual(
          at(data, placement, edgeX, edgeY),
          { frameR, frameG, frameB, 255 },
          case .. " keeps the frame plate band at " .. edgeX .. "," .. edgeY
        )
      end
    end
    for _, spanX in ipairs({ 64, 128, 192 }) do
      Assert.deepEqual(
        at(data, placement, spanX, 124),
        { 26, 154, 233, 255 },
        case .. " keeps the sample top span border at " .. spanX
      )
      Assert.deepEqual(
        at(data, placement, spanX, 164),
        { 182, 148, 221, 255 },
        case .. " keeps the sample bottom span border at " .. spanX
      )
    end
    Assert.deepEqual(
      at(data, placement, 100, 175),
      { footR, footG, footB, 255 },
      case .. " keeps the footer shell below the revealed frame"
    )
  end
  -- (e) Hostile base check: a hostile color beneath the list never shows
  -- through, no stale control faces appear, and the shell bands keep
  -- their own colors.
  do
    local view = headlessSourceView()
    local plan = planFor(view, "nativeLike")
    local placement = assert(plan.panes[1].placement, "the native plan places its pane")
    local canvas = drawPlan(scope, renderer, view, plan, 512, 384, { 1, 0, 1, 1 })
    local data = scope:own(canvas:newImageData())
    Assert.deepEqual(
      at(data, placement, 6, 10),
      { headR, headG, headB, 255 },
      "the header shell keeps its band over the hostile base"
    )
    Assert.deepEqual(
      at(data, placement, 6, 180),
      { footR, footG, footB, 255 },
      "the footer shell keeps its band over the hostile base"
    )
    Assert.deepEqual(
      at(data, placement, 50, 36),
      { oddR, oddG, oddB, 255 },
      "the list plates cover the hostile base"
    )
    for ly = 24, 167, 4 do
      for lx = 0, 255, 8 do
        local sampled = at(data, placement, lx, ly)
        Assert.isFalse(
          sampled[1] == 255 and sampled[2] == 0 and sampled[3] == 255,
          "no hostile pixel shows through the list at " .. lx .. "," .. ly
        )
        Assert.isFalse(
          sampled[1] == 24 and sampled[2] == 120 and sampled[3] == 200,
          "no stale control face survives at " .. lx .. "," .. ly
        )
      end
    end
  end
  renderer:dispose()
end

-- The window frame owns containment: every visible row repaints its own
-- right border over pills but beneath the focus strip, so edge-reaching
-- chrome never opens the frame. The wide battle-style pills reach the
-- plate edge, so the border sample only passes when the border paints
-- after contents.

-- The label/control divider follows the layout instead of baked pixels:
-- every row paints its band's audited divider ink at the control
-- boundary, so relocated controls keep their separator. Both control
-- rects start at x112, so the divider samples only pass when each band
-- paints its own ink at the laid-out boundary. Stock fixture plates keep
-- this test honest: no custom art carries the divider.


-- The label/control divider follows the layout instead of baked pixels:
-- every row paints its band's audited divider ink at the control
-- boundary, so relocated controls keep their separator. Both control
-- rects start at x112, so the divider samples only pass when each band
-- paints its own ink at the laid-out boundary. Stock fixture plates keep
-- this test honest: no custom art carries the divider.
function T.tests.row_dividers_follow_the_control_boundary(scope)
  local Interface = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer = preparedPlacedPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = sampleView("confirm", 0)
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  local placement = assert(plan.panes[1].placement, "the plan places its pane")
  local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  local data = scope:own(canvas:newImageData())
  local function at(lx, ly)
    local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
    return quantizePixel(data, hx, hy)
  end
  local oddR, oddG, oddB = FieldUiFixture.optionsRowOddColor()
  local evenR, evenG, evenB = FieldUiFixture.optionsRowEvenColor()
  Assert.deepEqual(at(100, 84), { oddR, oddG, oddB, 255 }, "the probe sits on odd plate interior")
  Assert.deepEqual(at(100, 108), { evenR, evenG, evenB, 255 }, "the probe sits on even plate interior")
  Assert.deepEqual(at(103, 84), { 0x42, 0x9C, 0xE6, 255 }, "the odd divider paints its audited ink")
  Assert.deepEqual(at(103, 108), { 0x3A, 0x84, 0xC5, 255 }, "the even divider paints its audited ink")
  -- The divider never crosses another frame: the row separators above and
  -- below the battle-style row keep their plate pixels.
  Assert.deepEqual(at(103, 72), { oddR, oddG, oddB, 255 }, "the divider stops above the separator")
  Assert.deepEqual(at(103, 95), { oddR, oddG, oddB, 255 }, "the divider stops below the separator")
  renderer:dispose()
end

-- The divider stops at the frame row's sample window: it separates the
-- label and arrow controls above the window but never crosses its frame.
-- The scrolled plan brings the 72px frame item into view with footer
-- focus, so no selection strip interferes with either sample.

return GraphicsSmoke.suite(T.tests)
