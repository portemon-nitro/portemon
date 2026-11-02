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
  local stateOk, ScreenState = pcall(require, "game.hgss.src.options.OptionsScreenState")
  Assert.isTrue(stateOk, "OptionsScreenState missing: " .. tostring(ScreenState))
  return Interface, Renderer, ScreenState
end

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

local function optionsCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addOptionsContract(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  CacheFs.forVersion("heartgold"):write(FieldUiFixture.OPTIONS_CHROME_PATH, FieldUiFixture.optionsChromeBytes())
  CacheFs.forVersion("heartgold"):write(
    FieldUiFixture.OPTIONS_CONTROLS_BACKGROUND_PATH,
    FieldUiFixture.optionsControlsBackgroundBytes()
  )
  CacheFs.forVersion("heartgold"):write(
    FieldUiFixture.OPTIONS_PREVIEW_BACKGROUND_PATH,
    FieldUiFixture.optionsPreviewBackgroundBytes()
  )
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

local function recordingPlacedText()
  local text = { draws = {}, background = { 0.1, 0.2, 0.3, 1 } }
  function text.drawTextWithPalette(_, line, x, y, _)
    text.draws[#text.draws + 1] = { line = line, x = x, y = y }
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

local function sampleView(focusId, scrollOffset)
  local Interface = (modules())
  local rows = {}
  local ids = { "textSpeed", "battleScene", "battleStyle", "soundMode", "textFrame", "volume", "battleSpeed" }
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
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  local text = recordingPlacedText()
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
  return renderer, text, window, pool
end

local function quantizePixel(data, x, y)
  local r, g, b, a = data:getPixel(x, y)
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  return { quantize(r), quantize(g), quantize(b), quantize(a) }
end

function T.tests.scrolled_rows_paint_at_their_hit_tested_positions(scope)
  local Interface, _, ScreenState = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, text = preparedPlacedPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local function planFor(view)
    return resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  end
  local function hasDraw(line, x, y)
    for _, draw in ipairs(text.draws) do
      if draw.line == line and draw.x == x and draw.y == y then
        return true
      end
    end
    return false
  end
  -- Scans one painted band for the first logical point hitting the wanted
  -- pill, then resolves that point to host pixels for sampling.
  local function pillHost(plan, targetId, index, bandY, dx)
    local lx = nil
    for x = 112, 247 do
      local hit = Interface.hitTest(plan.content, x, bandY)
      if hit ~= nil and hit.target == targetId and hit.index == index then
        lx = x
        break
      end
    end
    Assert.notNil(lx, targetId .. " pill " .. index .. " hit-tests in its painted band")
    local placement = assert(plan.panes[1].placement, "the plan places its pane")
    local hx, hy = LayoutGeometry.logicalToHost(placement, lx + dx, bandY)
    return hx, hy, lx
  end
  local topView = sampleView("textSpeed", 0)
  local top = planFor(topView)
  local canvas0 = drawPlan(scope, renderer, topView, top, 512, 384)
  local data0 = scope:own(canvas0:newImageData())
  Assert.isTrue(hasDraw("TEXTSPEED", 12, 4), "the first row draws its label at zero scroll")
  Assert.isTrue(hasDraw("CONFIRM", 24, 172), "the footer stays pinned at zero scroll")
  local hx, hy, lx = pillHost(top, "textSpeed", 1, 36, 12)
  Assert.deepEqual(
    quantizePixel(data0, hx, hy),
    { 200, 200, 40, 255 },
    "the first row paints its selected pill at the top of the list at zero scroll"
  )
  text.draws = {}
  local scrolledView = sampleView("textSpeed", 48)
  local moving = planFor(scrolledView)
  local canvas48 = drawPlan(scope, renderer, scrolledView, moving, 512, 384)
  local data48 = scope:own(canvas48:newImageData())
  Assert.isTrue(not hasDraw("TEXTSPEED", 12, 4), "a row scrolled out of the list draws nothing")
  Assert.isTrue(hasDraw("BATTLESTYLE", 12, 52), "the third row still draws after scrolling 48")
  Assert.isTrue(hasDraw("CONFIRM", 24, 172), "the footer stays fixed while the list scrolls")
  Assert.deepEqual(
    quantizePixel(data48, hx, hy),
    { 40, 200, 40, 255 },
    "the same pixels now paint the third row after scrolling 48"
  )
  local hit = Interface.hitTest(moving.content, lx + 12, 36)
  Assert.isTrue(hit ~= nil, "the painted pill position hit-tests")
  Assert.equal(hit.target, "battleStyle", "the painted position belongs to the painted row")
  Assert.equal(hit.index, 1, "the painted pill position selects the painted stop")
  local port = {
    read = function()
      return 80
    end,
    preview = function() end,
    commit = function() end,
    restore = function() end,
  }
  local state = ScreenState.new({
    playerOptions = {
      textSpeed = "mid",
      battleScene = true,
      battleStyle = "shift",
      soundMode = "stereo",
      textFrame = 0,
      battleSpeed = 1,
    },
    volume = 80,
    preparePlayerOptions = function()
      return { apply = function() end, rollback = function() end }
    end,
    audioPreferences = port,
    applyChannelMode = function() end,
    effect = function() end,
  })
  state:updateFixed({ { type = "scroll", delta = 48 } })
  Assert.equal(state:status().scrollOffset, 48, "the wheel scroll carries the headless list")
  local tapHit = nil
  for x = 112, 247 do
    local candidate = Interface.hitTest(moving.content, x, 36)
    if candidate ~= nil and candidate.target == "battleStyle" and candidate.index == 2 then
      tapHit = candidate
      break
    end
  end
  Assert.isTrue(tapHit ~= nil, "the painted row hit-tests its second pill")
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", hit = tapHit } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", hit = tapHit } })
  local edited = nil
  for _, row in ipairs(state:status().rows) do
    if row.id == "battleStyle" then
      edited = row.value
    end
  end
  Assert.equal(edited, "set", "a tap on the painted row edits that same row")
  text.draws = {}
  local maxView = sampleView("volume", 80)
  local maxPlan = planFor(maxView)
  local canvasMax = drawPlan(scope, renderer, maxView, maxPlan, 512, 384)
  local dataMax = scope:own(canvasMax:newImageData())
  local thumb = assert(maxPlan.content.rows[7].control.slider, "the last row carries its slider geometry")
  local centerX = math.floor(thumb.thumbRect.x + thumb.thumbRect.width / 2)
  local painted = assert(maxPlan.content.listViewport, "the plan carries its list viewport")
  local thumbHx, thumbHy = LayoutGeometry.logicalToHost(
    assert(maxPlan.panes[1].placement, "the plan places its pane"),
    centerX,
    thumb.centerY + painted.y - maxPlan.content.scrollOffset
  )
  Assert.deepEqual(
    quantizePixel(dataMax, thumbHx, thumbHy),
    { 242, 242, 242, 255 },
    "the last row stays reachable at maximum scroll"
  )
  renderer:dispose()
end

function T.tests.dual_panes_keep_the_preview_window_on_the_upper_pane(scope)
  local Interface = modules()
  local renderer, _, window = preparedPlacedPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = sampleView("textSpeed", 0)
  view.preview = { textSpeed = "mid", textFrame = 3 }
  local plan = resolvers.dualDisplay(contextFor("dualDisplay", measurements), view)
  Assert.deepEqual(
    plan.content.preview,
    { x = 16, y = 152, width = 216, height = 32 },
    "the dual preview window stays inside the upper pane"
  )
  local canvas = drawPlan(scope, renderer, view, plan, 512, 192)
  local data = scope:own(canvas:newImageData())
  Assert.deepEqual(
    quantizePixel(data, 10, 10),
    { 210, 110, 30, 255 },
    "the upper pane paints the preview backdrop"
  )
  Assert.deepEqual(
    quantizePixel(data, 266, 10),
    { 24, 120, 200, 255 },
    "the lower pane paints the controls backdrop"
  )
  Assert.deepEqual(
    { x = window.lastBox.x, y = window.lastBox.y, width = window.lastBox.width, height = window.lastBox.height },
    { x = 16, y = 152, width = 216, height = 32 },
    "the sample window paints only in the preview pane"
  )
  Assert.deepEqual(
    quantizePixel(data, 506, 180),
    { 24, 120, 200, 255 },
    "no preview window overpaints the lower controls"
  )
  renderer:dispose()
end

function T.tests.pane_backing_stays_opaque_while_host_pixels_outside_stay_untouched(scope)
  local Interface, Renderer = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  local renderer = Renderer.new({
    cacheFs = cache,
    manifest = manifest,
    imagePool = pool,
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
  local hx, hy = LayoutGeometry.logicalToHost(placement, 250, 190)
  Assert.deepEqual(
    quantizePixel(data, hx, hy),
    { 24, 120, 200, 255 },
    "every controls-pane pixel is source-backed opaque"
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
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
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
  Assert.isTrue(
    tostring(failed):find("injected quad failure", 1, true) ~= nil,
    "the original quad cause propagates"
  )
  local cleaned = pool2:stats()
  Assert.equal(cleaned.staged, 0, "a failed preparation leaves no staged interest")
  Assert.equal(cleaned.ready, 0, "a failed preparation leaves no ready tickets")
  Assert.equal(cleaned.failed, 0, "a failed preparation leaves no failed tickets")
  Assert.equal(cleaned.pinnedBytes, baseline2.pinnedBytes, "a failed preparation unwinds earlier leases")
  local fresh = Renderer.new({
    cacheFs = cache2,
    manifest = manifest2,
    imagePool = pool2,
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
  drawPlan(
    scope,
    fresh,
    freshView,
    resolvers.nativeLike(contextFor("nativeLike", measurements), freshView),
    512,
    384
  )
  fresh:dispose()
  local resettled = pool2:stats()
  Assert.equal(resettled.pinnedBytes, baseline2.pinnedBytes, "the fresh renderer releases its leases")
end

local function recordingTokenText()
  local text = { tokenDraws = {}, draws = {}, background = { 0.1, 0.2, 0.3, 1 } }
  function text.drawTextWithPalette(_, line, x, y, _)
    text.draws[#text.draws + 1] = { line = line, x = x, y = y }
  end
  function text.textWidth(_, str)
    return #str * 8
  end
  function text.drawTokenLine(_, tokens, x, y)
    text.tokenDraws[#text.tokenDraws + 1] = { tokens = tokens, x = x, y = y }
  end
  function text.windowBackgroundColor()
    return text.background
  end
  return text
end

local function sourceLine(word)
  local tokens = {}
  for index = 1, #word do
    tokens[#tokens + 1] = { kind = "glyph", code = 0x0120 + index, text = word:sub(index, index) }
  end
  return tokens
end

local function tokenPainter(scope)
  local _, Renderer = modules()
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  local text = recordingTokenText()
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

local function assertNoStaticSample(text)
  for _, draw in ipairs(text.draws) do
    Assert.isTrue(draw.line ~= "SAMPLE", "no static sample text paints")
  end
end

function T.tests.frame_preview_paints_live_token_lines_without_static_text(scope)
  local Interface = modules()
  local renderer, text, window = tokenPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = sampleView("textFrame")
  view.preview = {
    textSpeed = "mid",
    textFrame = 0,
    visibleLines = { sourceLine("ZERO"), sourceLine("AB") },
    lineHeight = 16,
    lineSpacing = 2,
  }
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  local preview = assert(plan.content.preview, "the native plan carries its preview")
  drawPlan(scope, renderer, view, plan, 512, 384)
  Assert.equal(window.lastFrame, 0, "the preview border uses the draft frame")
  Assert.equal(#text.tokenDraws, 2, "every visible token line draws once")
  Assert.equal(text.tokenDraws[1].tokens[1].text, "Z", "frame zero paints its own source glyphs")
  Assert.equal(text.tokenDraws[1].x, preview.x + 4, "token lines keep the preview inset")
  Assert.equal(text.tokenDraws[1].y, preview.y + 4, "the first line starts at the preview top")
  Assert.equal(
    text.tokenDraws[2].y,
    preview.y + 4 + 16 + 2,
    "later lines advance by the printer line geometry"
  )
  assertNoStaticSample(text)
  text.tokenDraws = {}
  text.draws = {}
  view.preview = {
    textSpeed = "mid",
    textFrame = 7,
    visibleLines = { sourceLine("SEVEN") },
    lineHeight = 16,
    lineSpacing = 2,
  }
  local plan7 = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  drawPlan(scope, renderer, view, plan7, 512, 384)
  Assert.equal(window.lastFrame, 7, "the frame edit repaints the draft border")
  Assert.equal(#text.tokenDraws, 1, "the new frame paints its own visible lines")
  Assert.equal(text.tokenDraws[1].tokens[1].text, "S", "frame seven paints distinct source glyphs")
  assertNoStaticSample(text)
  text.tokenDraws = {}
  text.draws = {}
  local dualPlan = resolvers.dualDisplay(contextFor("dualDisplay", measurements), view)
  Assert.deepEqual(
    dualPlan.content.preview,
    { x = 16, y = 152, width = 216, height = 32 },
    "the dual preview window stays inside the upper pane"
  )
  drawPlan(scope, renderer, view, dualPlan, 512, 192)
  Assert.equal(window.lastFrame, 7, "the dual preview keeps the draft border")
  Assert.equal(#text.tokenDraws, 1, "the dual preview pane paints the sample once")
  Assert.equal(text.tokenDraws[1].tokens[1].text, "S", "the dual preview paints the same source glyphs")
  Assert.isTrue(
    text.tokenDraws[1].x >= 16 and text.tokenDraws[1].x < 16 + 216,
    "dual token lines stay inside the upper preview pane"
  )
  assertNoStaticSample(text)
  text.tokenDraws = {}
  text.draws = {}
  view.preview = { textSpeed = "mid", textFrame = 7 }
  local unrevealed = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  drawPlan(scope, renderer, view, unrevealed, 512, 384)
  Assert.equal(#text.tokenDraws, 0, "an unrevealed sample draws a blank framed window")
  assertNoStaticSample(text)
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

-- A failed open hands its pooled renderer back: the retained per-open
-- owner clears, every lease returns, and a fresh open paints normally.
function T.tests.failed_open_returns_the_pooled_renderer_for_a_fresh_open(scope)
  local Resources = require("game.hgss.src.field.FieldPresentationResources")
  local Coordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
  local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  local stubText = {}
  function stubText.drawTextWithPalette(_, _, _, _, _) end
  function stubText.drawLine(_, _, _, _)
    return "drawn"
  end
  function stubText.textWidth(_, _)
    return 8
  end
  function stubText.drawTokenLine(_, _, _, _) end
  function stubText.windowBackgroundColor()
    return { 0.1, 0.2, 0.3, 1 }
  end
  local stubWindow = {}
  function stubWindow.drawWindow(_, _, _, _) end
  function stubWindow.drawApplicationFrame(_, _, _) end
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
  local baseline = pool:stats().pinnedBytes
  local frameIndexes = {}
  for slot = 0, 19 do
    frameIndexes[slot] = true
  end
  local runtime = {
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

return GraphicsSmoke.suite(T.tests)
