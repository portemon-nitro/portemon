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
  ownPool(scope, pool)
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
  Assert.isNil(Interface.hitTest(content, last.rect.x + 4, outsideY), "a clipped row region never hit-tests")
  local footer = assert(content.footer, "the plan publishes its footer")
  local hit = Interface.hitTest(content, footer.confirmRect.x + 2, footer.confirmRect.y + 2)
  Assert.isTrue(hit ~= nil and hit.target == "confirm", "the fixed footer stays interactive")
end

local function preparedPainter(scope)
  local _, Renderer = modules()
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
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
  local view = sampleView("textFrame", 64)
  view.preview = { textSpeed = "fastest", textFrame = 7 }
  local plan = drawNative(scope, renderer, view)
  Assert.isNil(plan.content.preview, "the native plan keeps no fixed preview")
  local frameRow = nil
  for _, row in ipairs(plan.content.rows) do
    if row.id == "textFrame" then
      frameRow = row
    else
      Assert.isNil(row.previewRect, "only the closing row carries a sample")
    end
  end
  local preview = assert(frameRow ~= nil and frameRow.previewRect, "the closing row carries its sample")
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
  ownPool(scope, pool)
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

local function preparedSourcePainter(scope)
  local _, Renderer = modules()
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local text = tokenRecordingText()
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
  return renderer, text
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

local function findRecordedToken(draws, word)
  for _, draw in ipairs(draws) do
    if joinRecordedGlyphs(draw.tokens) == word then
      return draw
    end
  end
  return nil
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
function T.tests.options_title_and_footer_keep_their_source_windows(scope)
  local Interface = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, text = preparedSourcePainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = headlessSourceView()
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  local content = assert(plan.content, "the native plan carries its options content")
  local function hitAt(x, y)
    return Interface.hitTest(content, x, y)
  end
  local confirmHit = hitAt(140, 180)
  Assert.isTrue(
    confirmHit ~= nil and confirmHit.target == "confirm",
    "the native Confirm action does not hit-test inside its drawn window"
  )
  Assert.isNil(hitAt(26, 174), "a press far left of the Confirm art still arms Confirm")
  local quitHit = hitAt(200, 180)
  Assert.isTrue(quitHit ~= nil and quitHit.target == "quit", "the native Quit action misses its drawn window")
  local placement = assert(plan.panes[1].placement, "the plan places its pane")
  local function sampleLogical(logicalX, logicalY, drawnView, drawnPlan)
    local canvas = drawPlan(scope, renderer, drawnView, drawnPlan, 512, 384)
    local data = scope:own(canvas:newImageData())
    local hx, hy = LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
    return quantizePixel(data, hx, hy)
  end
  Assert.deepEqual(
    sampleLogical(2, 26, view, plan),
    { 140, 40, 180, 255 },
    "the selected-row strip never composites behind the focused row"
  )
  local title = findRecordedToken(text.tokens, "OPTIONS")
  Assert.notNil(title, "the OPTIONS title never reaches the glyph renderer")
  Assert.equal(title.x, 10, "the title misses its header origin")
  Assert.equal(title.y, 5, "the title misses its header row")
  local confirm = findRecordedToken(text.tokens, "CONFIRM")
  Assert.notNil(confirm, "footer Confirm never reaches the glyph renderer")
  Assert.isTrue(confirm.x >= 120 and confirm.x < 120 + 56, "footer Confirm escapes its label window")
  local quit = findRecordedToken(text.tokens, "QUIT")
  Assert.notNil(quit, "footer Quit never reaches the glyph renderer")
  Assert.isTrue(quit.x >= 192 and quit.x < 192 + 56, "footer Quit escapes its label window")
  Assert.isTrue(confirm.x < 183 and quit.x >= 183, "the two footer actions share one window instead of their own")
  local quitView = headlessSourceView(nil, true)
  local quitPlan = resolvers.nativeLike(contextFor("nativeLike", measurements), quitView)
  Assert.deepEqual(
    sampleLogical(2, 26, quitView, quitPlan),
    { 250, 230, 180, 255 },
    "no selected-row strip paints while the footer holds focus; the odd row plate shows"
  )
  text.plain = {}
  text.tokens = {}
  local notedView = headlessSourceView({ textSpeed = "slow" })
  local notedPlan = resolvers.nativeLike(contextFor("nativeLike", measurements), notedView)
  drawPlan(scope, renderer, notedView, notedPlan, 512, 384)
  local note = findPlacedLine(text.plain, "SLOW BECOMES MID")
  Assert.notNil(note, "the staged migration note never paints")
  Assert.isTrue(note.x >= 104, "the migration note paints over the title window")
  renderer:dispose()
end

-- Choice chrome follows the row, not the stop count: the three-stop and
-- first two-stop rows wear the narrow pill while the remaining two-stop
-- rows wear the wide pill, sprite anchors and touch regions match per row,
-- arrows sit at their own anchors, and the frame value centers about its
-- position instead of starting there.
function T.tests.choice_rows_use_their_source_pill_family_and_geometry(scope)
  local Interface = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, text = preparedSourcePainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = headlessSourceView()
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  local content = assert(plan.content, "the native plan carries its options content")
  Assert.isNil(Interface.hitTest(content, 155, 36), "a press between text-speed pills selects a stop")
  Assert.isNil(Interface.hitTest(content, 180, 84), "a press between battle-style pills selects a stop")
  local first = Interface.hitTest(content, 220, 36)
  Assert.isTrue(first ~= nil and first.target == "textSpeed" and first.index == 3, "the last text-speed pill misses")
  local second = Interface.hitTest(content, 200, 84)
  Assert.isTrue(
    second ~= nil and second.target == "battleStyle" and second.index == 2,
    "the second battle-style pill misses"
  )
  local frameView = headlessSourceView()
  frameView.scrollOffset = 64
  local framePlan = resolvers.nativeLike(contextFor("nativeLike", measurements), frameView)
  local frameContent = assert(framePlan.content, "the scrolled plan carries its options content")
  local left = Interface.hitTest(frameContent, 140, 116)
  Assert.isTrue(left ~= nil and left.control == "left", "a press on the left frame arrow edits the value")
  local right = Interface.hitTest(frameContent, 230, 116)
  Assert.isTrue(right ~= nil and right.control == "right", "a press on the right frame arrow edits the value")
  local placement = assert(plan.panes[1].placement, "the plan places its pane")
  local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  local data = scope:own(canvas:newImageData())
  local function samplePill(logicalX, logicalY)
    local hx, hy = LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
    return quantizePixel(data, hx, hy)
  end
  Assert.deepEqual(samplePill(118, 36), { 40, 200, 40, 255 }, "the three-stop text-speed row wears the wide pill")
  Assert.deepEqual(samplePill(118, 84), { 200, 200, 40, 255 }, "the two-stop battle-style row wears the narrow pill")
  drawPlan(scope, renderer, frameView, framePlan, 512, 384)
  local valueDraw = findPlacedLine(text.plain, "TYPE 1") or findRecordedToken(text.tokens, "TYPE 1")
  Assert.notNil(valueDraw, "the frame value never paints")
  Assert.isTrue(valueDraw.x < 172, "the frame value paints its center as a left origin instead of centering about it")
  renderer:dispose()
end

-- The two-stop Battle Scene row is the narrow exception: it wears the small
-- pill like the three-stop row while the other two-stop rows wear the
-- wide pill. Anchors, touch regions, and chrome colors agree per row.
function T.tests.battle_scene_two_stop_row_wears_the_narrow_pill_while_sound_uses_the_wide(scope)
  local OptionsRows = require("game.hgss.src.options.OptionsRows")
  Assert.equal(OptionsRows.chromeKind("textSpeed"), "small", "text speed wears the narrow pill")
  Assert.equal(OptionsRows.chromeKind("battleScene"), "small", "the two-stop battle scene wears the narrow pill")
  Assert.equal(OptionsRows.chromeKind("battleStyle"), "wide", "battle style wears the wide pill")
  Assert.equal(OptionsRows.chromeKind("soundMode"), "wide", "sound wears the wide pill")
  Assert.isNil(OptionsRows.chromeKind("textFrame"), "the frame row wears no choice pill")
  local Interface = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, _ = preparedSourcePainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = headlessSourceView()
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  local content = assert(plan.content, "the native plan carries its options content")
  Assert.isNil(Interface.hitTest(content, 155, 60), "a press between battle-scene pills selects a stop")
  local sceneSecond = Interface.hitTest(content, 200, 60)
  Assert.isTrue(
    sceneSecond ~= nil and sceneSecond.target == "battleScene" and sceneSecond.index == 2,
    "the second battle-scene pill misses"
  )
  local soundSecond = Interface.hitTest(content, 200, 108)
  Assert.isTrue(
    soundSecond ~= nil and soundSecond.target == "soundMode" and soundSecond.index == 2,
    "the second sound pill misses"
  )
  local placement = assert(plan.panes[1].placement, "the plan places its pane")
  local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  local data = scope:own(canvas:newImageData())
  local function samplePill(logicalX, logicalY)
    local hx, hy = LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
    return quantizePixel(data, hx, hy)
  end
  Assert.deepEqual(
    samplePill(118, 60),
    { 40, 200, 40, 255 },
    "the two-stop battle-scene row paints the selected narrow pill"
  )
  Assert.deepEqual(samplePill(118, 108), { 200, 200, 40, 255 }, "the two-stop sound row paints the selected wide pill")
  renderer:dispose()
end

-- The menu-local sample paginates from the preview font definition: opening
-- presented options loads the preview font for its printer metrics instead
-- of reusing the menu font.
function T.tests.options_preview_printer_paginates_with_the_preview_font_definition(scope)
  local Coordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
  local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
  local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
  local realCache = CacheFs.forVersion("test-options-preview-font", FakeCache.new())
  scope:own({
    release = function()
      CacheFs.forVersion("test-options-preview-font"):removeTree("")
    end,
  })
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addOptionsContract(manifest)
  manifest.options = FieldUiFixture.optionsSourceSemantic()
  manifest.dialogueFrames = {
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
  }
  FieldUiFixture.writeFont(realCache, 0)
  FieldUiFixture.writeFont(realCache, 1)
  local loadedPaths = {}
  local proxy = { versionId = realCache.versionId }
  function proxy.loadLua(_, path)
    loadedPaths[#loadedPaths + 1] = path
    return realCache:loadLua(path)
  end
  setmetatable(proxy, { __index = realCache })
  local frameIndexes = {}
  for slot = 0, 19 do
    frameIndexes[slot] = true
  end
  local audioPreferences = {
    read = function()
      return 80
    end,
    preview = function(_) end,
    commit = function(_) end,
    restore = function() end,
  }
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
    audioPreferences = audioPreferences,
    uiManifest = manifest,
    fontDef = { glyphs = { [0] = { advance = 8 } } },
    presentationDisplay = topologies().nativeLike,
    cacheFs = proxy,
  }
  local coordinator = Coordinator.new(runtime)
  local factory = nil
  for _, descriptor in ipairs(coordinator:applicationDescriptors()) do
    if descriptor.id == FieldApplicationIds.OPTIONS then
      factory = descriptor.factory
    end
  end
  Assert.notNil(factory, "the field catalogue registers the options destination")
  local screen = factory()
  Assert.isTrue(screen:status().open, "presented options opens with the staged preview font")
  screen:dispose()
  local wanted = FieldFontCache.defPath(1)
  local seen = false
  for _, path in ipairs(loadedPaths) do
    if path == wanted then
      seen = true
    end
  end
  Assert.isTrue(seen, "the preview printer never loads the preview-font definition")
end

-- Labels paint once from their own chrome: no duplicated shadow pass, no
-- footer or arrow chrome lingering at the old broad rectangles once the
-- native anchors move in.
function T.tests.options_paints_single_pass_labels_without_chrome_overflow(scope)
  local Interface = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, text = preparedSourcePainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = headlessSourceView()
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  local placement = assert(plan.panes[1].placement, "the plan places its pane")
  local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  local data = scope:own(canvas:newImageData())
  local function sampleChrome(logicalX, logicalY)
    local hx, hy = LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
    return quantizePixel(data, hx, hy)
  end
  local counts = {}
  for _, draw in ipairs(text.plain) do
    counts[draw.line] = (counts[draw.line] or 0) + 1
  end
  for _, draw in ipairs(text.tokens) do
    local word = joinRecordedGlyphs(draw.tokens)
    counts[word] = (counts[word] or 0) + 1
  end
  for _, line in ipairs({ "TEXT SPEED", "CONFIRM", "QUIT", "MID" }) do
    Assert.equal(counts[line], 1, "label paints its shadow and face as two text passes: " .. line)
  end
  Assert.deepEqual(
    sampleChrome(26, 176),
    { 24, 120, 200, 255 },
    "footer action chrome still spans the broad pre-source rectangle"
  )
  Assert.deepEqual(
    sampleChrome(113, 130),
    { 250, 230, 180, 255 },
    "the odd row plate backs the slider row without chrome overflow"
  )
  Assert.deepEqual(
    sampleChrome(247, 130),
    { 250, 230, 180, 255 },
    "the odd row plate reaches the control edge without chrome overflow"
  )
  renderer:dispose()
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
  Assert.isTrue(hasDraw("TEXTSPEED", 12, 5), "the first row draws its label at zero scroll")
  Assert.isTrue(hasDraw("CONFIRM", 120, 174), "the footer stays pinned at zero scroll")
  local hx, hy, lx = pillHost(top, "textSpeed", 1, 36, 12)
  Assert.deepEqual(
    quantizePixel(data0, hx, hy),
    { 40, 200, 40, 255 },
    "the first row paints its selected narrow pill at the top of the list at zero scroll"
  )
  text.draws = {}
  local scrolledView = sampleView("textSpeed", 48)
  local moving = planFor(scrolledView)
  local canvas48 = drawPlan(scope, renderer, scrolledView, moving, 512, 384)
  local data48 = scope:own(canvas48:newImageData())
  Assert.isTrue(not hasDraw("TEXTSPEED", 12, 5), "a row scrolled out of the list draws nothing")
  Assert.isTrue(hasDraw("BATTLESTYLE", 12, 53), "the third row still draws after scrolling 48")
  Assert.isTrue(hasDraw("CONFIRM", 120, 174), "the footer stays fixed while the list scrolls")
  Assert.deepEqual(
    quantizePixel(data48, hx, hy),
    { 200, 200, 40, 255 },
    "the same pixels now paint the third row selected wide pill after scrolling 48"
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
  local maxView = sampleView("textFrame", 64)
  local maxPlan = planFor(maxView)
  local canvasMax = drawPlan(scope, renderer, maxView, maxPlan, 512, 384)
  local dataMax = scope:own(canvasMax:newImageData())
  local speedRow = nil
  for _, row in ipairs(maxPlan.content.rows) do
    if row.id == "battleSpeed" then
      speedRow = row
    end
  end
  local thumb = assert(speedRow ~= nil and speedRow.control.slider, "the battle-speed row carries its slider geometry")
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
    "the battle-speed row stays reachable at maximum scroll"
  )
  renderer:dispose()
end

function T.tests.dual_upper_pane_stays_decorative_while_the_sample_scrolls_in_the_lower_list(scope)
  local Interface = modules()
  local renderer, _, window = preparedPlacedPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local hidden = sampleView("textSpeed", 0)
  hidden.preview = { textSpeed = "mid", textFrame = 3 }
  local hiddenPlan = resolvers.dualDisplay(contextFor("dualDisplay", measurements), hidden)
  Assert.isNil(hiddenPlan.content.preview, "the dual plan keeps no fixed preview")
  local hiddenFrame = nil
  for _, row in ipairs(hiddenPlan.content.rows) do
    if row.id == "textFrame" then
      hiddenFrame = row
    end
  end
  Assert.deepEqual(
    assert(hiddenFrame ~= nil and hiddenFrame.previewRect, "the closing row carries its sample"),
    { x = 16, y = 172, width = 216, height = 32 },
    "the sample lives inside the closing row"
  )
  window.draws = 0
  local hiddenCanvas = drawPlan(scope, renderer, hidden, hiddenPlan, 512, 192)
  local hiddenData = scope:own(hiddenCanvas:newImageData())
  Assert.equal(window.draws, 0, "the upper pane stays decorative while the sample is scrolled away")
  Assert.deepEqual(
    quantizePixel(hiddenData, 10, 10),
    { 210, 110, 30, 255 },
    "the upper pane paints the preview backdrop"
  )
  Assert.deepEqual(
    quantizePixel(hiddenData, 266, 10),
    { 24, 120, 200, 255 },
    "the lower pane paints the controls backdrop"
  )
  local shown = sampleView("textFrame", 64)
  shown.preview = { textSpeed = "mid", textFrame = 3 }
  local plan = resolvers.dualDisplay(contextFor("dualDisplay", measurements), shown)
  Assert.isNil(plan.content.preview, "the revealed plan keeps no fixed preview")
  window.draws = 0
  local canvas = drawPlan(scope, renderer, shown, plan, 512, 192)
  local data = scope:own(canvas:newImageData())
  Assert.deepEqual(quantizePixel(data, 10, 10), { 210, 110, 30, 255 }, "the upper pane paints the preview backdrop")
  Assert.deepEqual(quantizePixel(data, 266, 10), { 24, 120, 200, 255 }, "the lower pane paints the controls backdrop")
  Assert.equal(window.draws, 1, "the revealed sample paints once in the lower list")
  Assert.deepEqual(
    { x = window.lastBox.x, y = window.lastBox.y, width = window.lastBox.width, height = window.lastBox.height },
    { x = 16, y = 172, width = 216, height = 32 },
    "the sample window paints with its row in the lower pane"
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
  ownPool(scope, pool)
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

local function recordingTokenText()
  local text = { tokenDraws = {}, draws = {}, background = { 0.1, 0.2, 0.3, 1 } }
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
  function text.textWidth(_, str)
    return #str * 8
  end
  function text.drawPreviewTokens(_, tokens, x, y)
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
  ownPool(scope, pool)
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
  local view = sampleView("textFrame", 64)
  view.preview = {
    textSpeed = "mid",
    textFrame = 0,
    visibleLines = { sourceLine("ZERO"), sourceLine("AB") },
    lineHeight = 16,
    lineSpacing = 2,
  }
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  Assert.isNil(plan.content.preview, "the native plan keeps no fixed preview")
  local frameRow = nil
  for _, row in ipairs(plan.content.rows) do
    if row.id == "textFrame" then
      frameRow = row
    end
  end
  local preview = assert(frameRow ~= nil and frameRow.previewRect, "the closing row carries its sample")
  Assert.deepEqual(preview, { x = 16, y = 172, width = 216, height = 32 }, "the sample lives inside the closing row")
  drawPlan(scope, renderer, view, plan, 512, 384)
  Assert.equal(window.lastFrame, 0, "the preview border uses the draft frame")
  Assert.equal(#text.tokenDraws, 2, "every visible token line draws once")
  Assert.equal(text.tokenDraws[1].tokens[1].text, "Z", "frame zero paints its own source glyphs")
  Assert.equal(text.tokenDraws[1].x, preview.x + 4, "token lines keep the preview inset")
  Assert.equal(text.tokenDraws[1].y, preview.y + 4, "the first line starts at the preview top")
  Assert.equal(text.tokenDraws[2].y, preview.y + 4 + 16 + 2, "later lines advance by the printer line geometry")
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
  Assert.isNil(dualPlan.content.preview, "the dual plan keeps no fixed preview")
  local dualFrame = nil
  for _, row in ipairs(dualPlan.content.rows) do
    if row.id == "textFrame" then
      dualFrame = row
    end
  end
  Assert.deepEqual(
    assert(dualFrame ~= nil and dualFrame.previewRect, "the dual closing row carries its sample"),
    { x = 16, y = 172, width = 216, height = 32 },
    "the dual sample lives inside the closing row"
  )
  drawPlan(scope, renderer, view, dualPlan, 512, 192)
  Assert.equal(window.lastFrame, 7, "the dual preview keeps the draft border")
  Assert.equal(#text.tokenDraws, 1, "the lower list paints the sample once")
  Assert.equal(text.tokenDraws[1].tokens[1].text, "S", "the lower list paints the same source glyphs")
  Assert.isTrue(
    text.tokenDraws[1].x >= 16 and text.tokenDraws[1].x < 16 + 216,
    "lower token lines stay inside the row sample"
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
function T.tests.sample_scrolls_with_its_row_once_on_every_layout(scope)
  local Interface = modules()
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local starts = { 0, 24, 48, 72, 96, 120, 144 }
  local heights = { 24, 24, 24, 24, 24, 24, 64 }
  for _, case in ipairs({ "dualDisplay", "nativeLike", "wide", "tall" }) do
    local context = contextFor(case, measurements)
    local view = sampleView("textSpeed", 0)
    view.preview = { textSpeed = "mid", textFrame = 3 }
    local plan = resolvers[case](context, view)
    local content = assert(plan.content, case .. " publishes its list")
    Assert.deepEqual(
      content.listViewport,
      { x = 0, y = 24, width = 256, height = 144 },
      case .. " shares one tall viewport"
    )
    Assert.equal(content.footer.y, 168, case .. " pins its footer")
    Assert.equal(content.scrollMax, 64, case .. " shares the scroll limit")
    Assert.isNil(content.preview, case .. " keeps no fixed preview")
    Assert.equal(#content.rows, 7, case .. " lays out seven rows")
    Assert.equal(content.rows[7].id, "textFrame", case .. " closes with the frame")
    for position, row in ipairs(content.rows) do
      Assert.equal(row.rect.y, starts[position], case .. " keeps the row offset")
      Assert.equal(row.rect.height, heights[position], case .. " keeps the row height")
    end
    local frame = content.rows[7]
    Assert.deepEqual(
      frame.rect,
      { x = 0, y = 144, width = 256, height = 64 },
      case .. " gives the closing row its tall item"
    )
    Assert.deepEqual(
      frame.previewRect,
      { x = 16, y = 172, width = 216, height = 32 },
      case .. " nests the sample inside the closing row"
    )
  end
  local renderer, _, window = preparedPlacedPainter(scope)
  local hiddenView = sampleView("textSpeed", 0)
  hiddenView.preview = { textSpeed = "mid", textFrame = 3 }
  local hiddenPlan = resolvers.nativeLike(contextFor("nativeLike", measurements), hiddenView)
  window.draws = 0
  drawPlan(scope, renderer, hiddenView, hiddenPlan, 512, 384)
  Assert.equal(window.draws, 0, "the sample stays hidden at the top")
  local shownView = sampleView("textFrame", 64)
  shownView.preview = { textSpeed = "mid", textFrame = 3 }
  local shownPlan = resolvers.nativeLike(contextFor("nativeLike", measurements), shownView)
  window.draws = 0
  drawPlan(scope, renderer, shownView, shownPlan, 512, 384)
  Assert.equal(window.draws, 1, "the revealed sample paints once")
  Assert.deepEqual(
    { x = window.lastBox.x, y = window.lastBox.y, width = window.lastBox.width, height = window.lastBox.height },
    { x = 16, y = 172, width = 216, height = 32 },
    "the revealed sample covers its row rect"
  )
  local dualHidden = sampleView("textSpeed", 0)
  dualHidden.preview = { textSpeed = "mid", textFrame = 3 }
  local dualHiddenPlan = resolvers.dualDisplay(contextFor("dualDisplay", measurements), dualHidden)
  window.draws = 0
  drawPlan(scope, renderer, dualHidden, dualHiddenPlan, 512, 192)
  Assert.equal(window.draws, 0, "no upper copy appears while scrolled away")
  local dualShown = sampleView("textFrame", 64)
  dualShown.preview = { textSpeed = "mid", textFrame = 3 }
  local dualShownPlan = resolvers.dualDisplay(contextFor("dualDisplay", measurements), dualShown)
  window.draws = 0
  drawPlan(scope, renderer, dualShown, dualShownPlan, 512, 192)
  Assert.equal(window.draws, 1, "the lower list paints the one sample")
  Assert.deepEqual(
    { x = window.lastBox.x, y = window.lastBox.y, width = window.lastBox.width, height = window.lastBox.height },
    { x = 16, y = 172, width = 216, height = 32 },
    "the dual sample paints with its row below"
  )
  renderer:dispose()
end

-- Every suite stages its own complete synthetic image set under its own
-- disposable namespace: the namespace starts clean without another suite
-- having run first, carries all four required roles where the pool worker
-- reads them, and never equals a real game version.
function T.tests.stages_a_private_complete_image_set(scope)
  local workerVisible = CacheFs.forVersion(ISOLATED_VERSION)
  workerVisible:removeTree("")
  Assert.isNil(
    workerVisible:read(FieldUiFixture.OPTIONS_CHROME_PATH),
    "the private namespace starts clean without another suite running first"
  )
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  Assert.equal(cache.versionId, ISOLATED_VERSION, "the staged cache carries the private namespace")
  Assert.isTrue(ISOLATED_VERSION ~= "heartgold", "the private namespace is not the HeartGold cache")
  Assert.isTrue(ISOLATED_VERSION ~= "soulsilver", "the private namespace is not the SoulSilver cache")
  Assert.equal(manifest.options.version, 4, "the staged section carries its row-plate contract")
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
    FieldUiFixture.OPTIONS_ROW_ODD_PATH,
    FieldUiFixture.OPTIONS_ROW_EVEN_PATH,
    FieldUiFixture.OPTIONS_ROW_FRAME_PATH,
  }) do
    Assert.notNil(workerVisible:read(path), "the worker-readable namespace stages " .. path)
  end
  local overlay =
    assert(manifest.assets[FieldUiFixture.optionsSelectionOverlayKey()], "the selected-row strip asset is indexed")
  Assert.equal(overlay.width, 256, "the selected-row strip width")
  Assert.equal(overlay.height, 24, "the selected-row strip height")
end

-- Held, quick, and cancelled presses paint the exact compiled source
-- frames: the held arrow advances through its pressed sequence in source
-- ticks, the tapped footer shows its pressed action state, and a press
-- with no visual record falls back to idle art.
function T.tests.held_quick_and_cancelled_presses_paint_exact_source_frames(scope)
  local Interface = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, text = preparedSourcePainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local view = headlessSourceView()
  view.focusId = "textFrame"
  view.scrollOffset = 64
  local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  local placement = assert(plan.panes[1].placement, "the native plan places its pane")
  local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  local data = scope:own(canvas:newImageData())
  local function sample(lx, ly)
    local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
    return quantizePixel(data, hx, hy)
  end
  Assert.deepEqual(sample(123, 112), { 200, 40, 200, 255 }, "the idle arrow paints its idle frame")
  Assert.deepEqual(sample(132, 176), { 90, 90, 200, 255 }, "the idle footer paints its normal frame")
  view.pressVisual = { kind = "arrow", side = "left", ageTicks = 0, held = true, focused = true }
  plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  placement = assert(plan.panes[1].placement, "the pressed plan places its pane")
  canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  data = scope:own(canvas:newImageData())
  Assert.deepEqual(sample(123, 112), { 40, 200, 200, 255 }, "a held arrow paints its first pressed frame")
  Assert.deepEqual(sample(221, 112), { 80, 20, 150, 255 }, "the opposite arrow stays idle during the press")
  view.pressVisual = { kind = "arrow", side = "left", ageTicks = 4, held = true, focused = true }
  plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  data = scope:own(canvas:newImageData())
  Assert.deepEqual(sample(123, 112), { 150, 80, 20, 255 }, "the held arrow advances to its second pressed frame")
  view.focusId = "confirm"
  view.pressVisual = { kind = "footer", actionId = "confirm", ageTicks = 0, held = true, focused = true }
  plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  placement = assert(plan.panes[1].placement, "the footer plan places its pane")
  canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  data = scope:own(canvas:newImageData())
  Assert.deepEqual(sample(132, 176), { 90, 90, 90, 255 }, "a pressed footer paints its first pressed frame")
  view.pressVisual = { kind = "footer", actionId = "confirm", ageTicks = 3, held = false, focused = true }
  plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  data = scope:own(canvas:newImageData())
  Assert.deepEqual(sample(132, 176), { 220, 140, 60, 255 }, "the footer tap advances to its second pressed frame")
  view.pressVisual = nil
  plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
  canvas = drawPlan(scope, renderer, view, plan, 512, 384)
  data = scope:own(canvas:newImageData())
  Assert.deepEqual(sample(132, 176), { 200, 90, 90, 255 }, "a cancelled press falls back to idle art")
  renderer:dispose()
end

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
    bottom.scrollOffset = 64
    bottom.error = "SAVE_WRITE_FAILED: disk is full"
    local bottomPlan = resolvers[case](contextFor(case, measurements), bottom)
    text.draws = {}
    window.draws = 0
    drawPlan(scope, renderer, bottom, bottomPlan, measurements[case].width, measurements[case].height)
    local frameLabel = findPlacedLine(text.draws, "FRAME")
    Assert.notNil(frameLabel, case .. " paints its frame row when revealed")
    local value = findPlacedLine(text.draws, "TYPE 1")
    Assert.notNil(value, case .. " paints its frame value when revealed")
    Assert.isTrue(value.x >= 140 and value.x <= 172, case .. " centers its frame value")
    Assert.equal(window.draws, 1, case .. " paints the revealed sample exactly once")
    Assert.deepEqual(
      { x = window.lastBox.x, y = window.lastBox.y, width = window.lastBox.width, height = window.lastBox.height },
      { x = 16, y = 172, width = 216, height = 32 },
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
function T.tests.scrolling_list_paints_moving_row_plates_over_stale_faces(scope)
  local Interface, Renderer = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local cache, manifest = optionsCache()
  FieldUiFixture.addRowBackings(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  FieldUiFixture.writeRowPlatePngs(CacheFs.forVersion(ISOLATED_VERSION))
  Assert.isTrue(FieldUiAssetCache.validateManifest(manifest), "the row-plate manifest validates before paint")
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
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
    Assert.isTrue(spins < 10000, "row plates resolve through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    ready, failure = renderer:prepare()
  end
  Assert.isTrue(ready == true, "the row-plate painter prepares: " .. tostring(failure))
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local oddR, oddG, oddB = FieldUiFixture.optionsRowOddColor()
  local evenR, evenG, evenB = FieldUiFixture.optionsRowEvenColor()
  local frameR, frameG, frameB = FieldUiFixture.optionsRowFrameColor()
  local function sampleLogical(view, scrollOffset, lx, ly)
    local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
    local placement = assert(plan.panes[1].placement, "the native plan places its pane")
    local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
    local data = scope:own(canvas:newImageData())
    local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
    return quantizePixel(data, hx, hy)
  end
  local top = sampleView("textSpeed", 0)
  Assert.deepEqual(
    sampleLogical(top, 0, 6, 36),
    { oddR, oddG, oddB, 255 },
    "the first row paints its odd plate at the top"
  )
  Assert.deepEqual(
    sampleLogical(top, 0, 6, 60),
    { evenR, evenG, evenB, 255 },
    "the second row paints its even plate at the top"
  )
  local middle = sampleView("battleStyle", 32)
  Assert.deepEqual(
    sampleLogical(middle, 32, 6, 36),
    { evenR, evenG, evenB, 255 },
    "the scrolled second row keeps its even plate in the middle"
  )
  Assert.deepEqual(
    sampleLogical(middle, 32, 6, 52),
    { oddR, oddG, oddB, 255 },
    "the scrolled third row keeps its odd plate in the middle"
  )
  local bottom = sampleView("textFrame", 64)
  bottom.preview = { textSpeed = "mid", textFrame = 1 }
  Assert.deepEqual(
    sampleLogical(bottom, 64, 6, 140),
    { frameR, frameG, frameB, 255 },
    "the revealed frame item paints its compound plate at maximum scroll"
  )
  renderer:dispose()
end

-- The row replacement never moves the fixed chrome: the header, footer,
-- and upper preview keep their source pixels while only the clipped list
-- scrolls beneath them.
function T.tests.list_replacement_keeps_header_footer_and_preview_fixed(scope)
  local Interface, Renderer = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local cache, manifest = optionsCache()
  FieldUiFixture.addRowBackings(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  FieldUiFixture.writeRowPlatePngs(CacheFs.forVersion(ISOLATED_VERSION))
  Assert.isTrue(FieldUiAssetCache.validateManifest(manifest), "the row-plate manifest validates before paint")
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
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
    Assert.isTrue(spins < 10000, "row plates resolve through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    ready, failure = renderer:prepare()
  end
  Assert.isTrue(ready == true, "the row-plate painter prepares: " .. tostring(failure))
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local oddR, oddG, oddB = FieldUiFixture.optionsRowOddColor()
  local function sampleNative(view)
    local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
    local placement = assert(plan.panes[1].placement, "the native plan places its pane")
    local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
    local data = scope:own(canvas:newImageData())
    local function at(lx, ly)
      local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
      return quantizePixel(data, hx, hy)
    end
    return at
  end
  for _, offset in ipairs({ 0, 64 }) do
    local focus = offset == 0 and "textSpeed" or "textFrame"
    local view = sampleView(focus, offset)
    view.preview = { textSpeed = "mid", textFrame = 1 }
    local at = sampleNative(view)
    Assert.deepEqual(at(6, 10), { 24, 120, 200, 255 }, "the header keeps its source base at offset " .. offset)
    Assert.deepEqual(at(6, 180), { 24, 120, 200, 255 }, "the footer keeps its source base at offset " .. offset)
    if offset == 0 then
      Assert.deepEqual(at(6, 36), { oddR, oddG, oddB, 255 }, "the list paints plates below the fixed header")
    else
      local frameR, frameG, frameB = FieldUiFixture.optionsRowFrameColor()
      Assert.deepEqual(at(6, 140), { frameR, frameG, frameB, 255 }, "the list paints plates above the fixed footer")
    end
  end
  local dualMeasurements = topologies()
  local dualView = sampleView("textSpeed", 0)
  dualView.preview = { textSpeed = "mid", textFrame = 1 }
  local dualPlan = resolvers.dualDisplay(contextFor("dualDisplay", dualMeasurements), dualView)
  local dualPlacement = assert(dualPlan.panes[1].placement, "the dual plan places its pane")
  local dualCanvas = drawPlan(scope, renderer, dualView, dualPlan, 512, 192)
  local dualData = scope:own(dualCanvas:newImageData())
  local upperHx, upperHy = LayoutGeometry.logicalToHost(dualPlacement, 10, 10)
  Assert.deepEqual(
    quantizePixel(dualData, upperHx, upperHy),
    { 210, 110, 30, 255 },
    "the upper pane keeps its decorative preview base"
  )
  renderer:dispose()
end

-- The focused strip paints between its own moving background and the row
-- foreground: the border follows the focused selector band at any offset
-- and footer focus hides the list strip entirely.
function T.tests.focused_strip_paints_between_plate_and_row_content(scope)
  local Interface, Renderer = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local cache, manifest = optionsCache()
  FieldUiFixture.addRowBackings(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  FieldUiFixture.writeRowPlatePngs(CacheFs.forVersion(ISOLATED_VERSION))
  Assert.isTrue(FieldUiAssetCache.validateManifest(manifest), "the row-plate manifest validates before paint")
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
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
    Assert.isTrue(spins < 10000, "row plates resolve through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    ready, failure = renderer:prepare()
  end
  Assert.isTrue(ready == true, "the row-plate painter prepares: " .. tostring(failure))
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local borderR, borderG, borderB = FieldUiFixture.optionsSelectionOverlayBorderColor()
  local oddR, oddG, oddB = FieldUiFixture.optionsRowOddColor()
  local function sampleNative(view)
    local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
    local placement = assert(plan.panes[1].placement, "the native plan places its pane")
    local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
    local data = scope:own(canvas:newImageData())
    return function(lx, ly)
      local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
      return quantizePixel(data, hx, hy)
    end,
      plan
  end
  local topAt = sampleNative(sampleView("textSpeed", 0))
  Assert.deepEqual(topAt(2, 26), { borderR, borderG, borderB, 255 }, "the strip backs the focused first row")
  Assert.deepEqual(topAt(6, 36), { oddR, oddG, oddB, 255 }, "the strip center leaves the odd plate visible")
  local scrolledView = sampleView("battleStyle", 32)
  local scrolledAt, scrolledPlan = sampleNative(scrolledView)
  local scrolledContent = assert(scrolledPlan.content, "the scrolled plan carries its list")
  local focusedRect = nil
  for _, row in ipairs(scrolledContent.rows) do
    if row.id == "battleStyle" then
      focusedRect = row.rect
    end
  end
  Assert.notNil(focusedRect, "the focused scrolled row keeps its content rect")
  local stripTop = scrolledContent.listViewport.y + focusedRect.y - scrolledContent.scrollOffset
  Assert.deepEqual(
    scrolledAt(2, stripTop + 2),
    { borderR, borderG, borderB, 255 },
    "the strip follows its row away from the static source band"
  )
  local footerView = sampleView("confirm", 64)
  footerView.preview = { textSpeed = "mid", textFrame = 1 }
  local footerAt = sampleNative(footerView)
  Assert.deepEqual(footerAt(2, 26), { oddR, oddG, oddB, 255 }, "footer focus hides the list strip")
  renderer:dispose()
end

-- The added plates join the pooled lifecycle without regressing it:
-- preparation acquires them once, repeated draws reuse them, disposal
-- returns every lease, and an incomplete plate class fails visibly.
function T.tests.row_plate_leases_prepare_draw_and_release_cleanly(scope)
  local Interface, Renderer = modules()
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local cache, manifest = optionsCache()
  FieldUiFixture.addRowBackings(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  FieldUiFixture.writeRowPlatePngs(CacheFs.forVersion(ISOLATED_VERSION))
  Assert.isTrue(FieldUiAssetCache.validateManifest(manifest), "the row-plate manifest validates before paint")
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local baseline = pool:stats()
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
    Assert.isTrue(spins < 10000, "row plates resolve through the pool worker")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
    ready, failure = renderer:prepare()
  end
  Assert.isTrue(ready == true, "the row-plate painter prepares: " .. tostring(failure))
  local requestsAfterPrepare = pool:stats().requests
  local topView = sampleView("textSpeed", 0)
  drawPlan(scope, renderer, topView, resolvers.nativeLike(contextFor("nativeLike", measurements), topView), 512, 384)
  local movedView = sampleView("textFrame", 64)
  movedView.preview = { textSpeed = "mid", textFrame = 1 }
  drawPlan(
    scope,
    renderer,
    movedView,
    resolvers.nativeLike(contextFor("nativeLike", measurements), movedView),
    512,
    384
  )
  Assert.equal(pool:stats().requests, requestsAfterPrepare, "draws acquire no new image leases")
  renderer:dispose()
  renderer:dispose()
  local settled = pool:stats()
  Assert.equal(settled.staged, 0, "disposal leaves no staged interest")
  Assert.equal(settled.ready, 0, "disposal leaves no ready tickets")
  Assert.equal(settled.failed, 0, "disposal leaves no failed tickets")
  Assert.equal(settled.pinnedBytes, baseline.pinnedBytes, "disposing returns every plate lease")
  local brokenCache = CacheFs.forVersion(ISOLATED_VERSION, FakeCache.new())
  local brokenManifest = FieldUiFixture.manifest()
  FieldUiFixture.addOptionsContract(brokenManifest)
  FieldUiFixture.addRowBackings(brokenManifest)
  brokenManifest.assets[FieldUiFixture.OPTIONS_ROW_FRAME_KEY] = nil
  brokenManifest.options.rowBackings.frame = nil
  brokenCache:writeLua(FieldUiAssetCache.manifestPath(), brokenManifest)
  FieldUiFixture.writeOptionsPngs(brokenCache)
  FieldUiFixture.writeRowPlatePngs(CacheFs.forVersion(ISOLATED_VERSION))
  local brokenValid = FieldUiAssetCache.validateManifest(brokenManifest)
  Assert.isFalse(brokenValid, "an incomplete plate class fails strict validation")
end

-- Slider values keep a measured window clear of their rail: every
-- supported volume and speed label paints right-aligned inside its own
-- slot from the text collaborator's advances, while rails and thumbs stay
-- inside their own track with a gap between the regions, in either focus.
function T.tests.slider_values_keep_a_measured_window_clear_of_their_rail(scope)
  local Interface = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, text, _ = preparedPlacedPainter(scope)
  local baseMeasure = text.measurePlain
  local measured = {}
  text.measurePlain = function(selfArg, line)
    measured[#measured + 1] = line
    return baseMeasure(selfArg, line)
  end
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local oddR, oddG, oddB = FieldUiFixture.optionsRowOddColor()
  local evenR, evenG, evenB = FieldUiFixture.optionsRowEvenColor()
  local cases = {
    { volume = "0%", volumeIndex = 1, speedValue = 1, speed = "1x", speedIndex = 1 },
    { volume = "80%", volumeIndex = 81, speedValue = 2, speed = "2x", speedIndex = 2 },
    { volume = "100%", volumeIndex = 101, speedValue = 4, speed = "4x", speedIndex = 3 },
  }
  for _, case in ipairs(cases) do
    for _, focusId in ipairs({ "volume", "battleSpeed" }) do
      local view = headlessSourceView({ battleSpeed = case.speedValue })
      for _, row in ipairs(view.rows) do
        if row.id == "volume" then
          row.valueLabel = case.volume
          row.valueIndex = case.volumeIndex
        end
      end
      view.focusId = focusId
      local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
      local content = assert(plan.content, "the native plan carries its list")
      local rowsById = {}
      for _, row in ipairs(content.rows) do
        rowsById[row.id] = row
      end
      for _, id in ipairs({ "volume", "battleSpeed" }) do
        local row = assert(rowsById[id], id .. " keeps its row")
        local control = assert(row.control, id .. " carries its control")
        Assert.isTrue(control.valueWindow ~= nil, id .. " carries its numeric window")
        Assert.deepEqual(
          control.valueWindow,
          { x = 112, y = row.rect.y + 5, width = 44, height = 18 },
          id .. " keeps its value inside the reserved slot"
        )
        local slider = assert(control.slider, id .. " carries its resolved rail")
        Assert.deepEqual(
          slider.rect,
          { x = 164, y = row.rect.y + 6, width = 80, height = 12 },
          id .. " keeps its rail clear of the numeric slot"
        )
        Assert.equal(
          control.valueWindow.x + control.valueWindow.width + 8,
          slider.rect.x,
          id .. " leaves a gap between the value and the rail"
        )
        Assert.isTrue(
          slider.thumbRect.x >= slider.rect.x
            and slider.thumbRect.x + slider.thumbRect.width <= slider.rect.x + slider.rect.width,
          id .. " keeps its thumb inside its rail"
        )
      end
      text.draws = {}
      measured = {}
      local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
      local volumeDraw = findPlacedLine(text.draws, case.volume)
      Assert.isTrue(volumeDraw ~= nil, "the volume value paints: " .. case.volume)
      local volumeWidth = baseMeasure(text, case.volume)
      Assert.isTrue(volumeWidth <= 44, "the measured value fits its window: " .. case.volume)
      Assert.equal(
        volumeDraw.x,
        112 + 44 - volumeWidth,
        "the volume value right-aligns from measured advances: " .. case.volume
      )
      Assert.equal(volumeDraw.y, rowsById.volume.rect.y + 5, "the volume value keeps its row band")
      Assert.isTrue(volumeDraw.x + volumeWidth <= 156, "the volume value never reaches the rail")
      local speedDraw = findPlacedLine(text.draws, case.speed)
      Assert.isTrue(speedDraw ~= nil, "the speed value paints: " .. case.speed)
      local speedWidth = baseMeasure(text, case.speed)
      Assert.isTrue(speedWidth <= 44, "the measured speed fits its window: " .. case.speed)
      Assert.equal(
        speedDraw.x,
        112 + 44 - speedWidth,
        "the speed value right-aligns from measured advances: " .. case.speed
      )
      Assert.equal(speedDraw.y, rowsById.battleSpeed.rect.y + 5, "the speed value keeps its row band")
      local seenVolume, seenSpeed = false, false
      for _, line in ipairs(measured) do
        if line == case.volume then
          seenVolume = true
        end
        if line == case.speed then
          seenSpeed = true
        end
      end
      Assert.isTrue(seenVolume, "the volume origin comes from a measured advance: " .. case.volume)
      Assert.isTrue(seenSpeed, "the speed origin comes from a measured advance: " .. case.speed)
      local titleDraw = findPlacedLine(text.draws, "VOLUME")
      Assert.isTrue(titleDraw ~= nil, "the volume row paints its title")
      Assert.isTrue(
        titleDraw.x + #"VOLUME" * 8 < 112,
        "the row title never reaches the numeric slot"
      )
      local placement = assert(plan.panes[1].placement, "the native plan places its pane")
      local data = scope:own(canvas:newImageData())
      local function at(lx, ly)
        local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
        return quantizePixel(data, hx, hy)
      end
      Assert.deepEqual(
        at(160, 132),
        { oddR, oddG, oddB, 255 },
        "the volume gap keeps its row plate at " .. case.volume
      )
      Assert.deepEqual(
        at(130, 132),
        { oddR, oddG, oddB, 255 },
        "the volume slot holds no rail paint at " .. case.volume
      )
      Assert.deepEqual(
        at(160, 156),
        { evenR, evenG, evenB, 255 },
        "the speed gap keeps its row plate at " .. case.speed
      )
      local volumeSlider = assert(rowsById.volume.control.slider, "the volume row carries its rail")
      local volumeCx = math.floor(volumeSlider.thumbRect.x + volumeSlider.thumbRect.width / 2)
      local volumeHx, volumeHy = LayoutGeometry.logicalToHost(
        placement,
        volumeCx,
        volumeSlider.centerY + content.listViewport.y - content.scrollOffset
      )
      Assert.deepEqual(
        quantizePixel(data, volumeHx, volumeHy),
        { 242, 242, 242, 255 },
        "the volume thumb paints inside its own rail at " .. case.volume
      )
      local speedSlider = assert(rowsById.battleSpeed.control.slider, "the speed row carries its rail")
      local speedCx = math.floor(speedSlider.thumbRect.x + speedSlider.thumbRect.width / 2)
      local speedHx, speedHy = LayoutGeometry.logicalToHost(
        placement,
        speedCx,
        speedSlider.centerY + content.listViewport.y - content.scrollOffset
      )
      Assert.deepEqual(
        quantizePixel(data, speedHx, speedHy),
        { 242, 242, 242, 255 },
        "the speed thumb paints inside its own rail at " .. case.speed
      )
    end
  end
  renderer:dispose()
end

-- Slider values and rails travel together without bleed: at every list
-- offset the measured slot and the resolved track keep their gap, move
-- with their row, stay out of neighboring rows and the fixed footer, and
-- the focused row keeps its strip.
function T.tests.slider_value_and_rail_travel_together_without_bleed(scope)
  local Interface = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, text, _ = preparedPlacedPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local oddR, oddG, oddB = FieldUiFixture.optionsRowOddColor()
  local evenR, evenG, evenB = FieldUiFixture.optionsRowEvenColor()
  for _, offset in ipairs({ 0, 32, 64 }) do
    for _, focusId in ipairs({ "volume", "battleSpeed" }) do
      local view = headlessSourceView({ battleSpeed = 2 })
      view.focusId = focusId
      view.scrollOffset = offset
      local plan = resolvers.nativeLike(contextFor("nativeLike", measurements), view)
      local content = assert(plan.content, "the native plan carries its list at offset " .. offset)
      Assert.equal(content.scrollOffset, offset, "the plan carries offset " .. offset)
      Assert.equal(content.footer.y, 168, "the footer stays pinned at offset " .. offset)
      local rowsById = {}
      for _, row in ipairs(content.rows) do
        rowsById[row.id] = row
      end
      for _, id in ipairs({ "volume", "battleSpeed" }) do
        local row = assert(rowsById[id], id .. " keeps its row at offset " .. offset)
        local control = assert(row.control, id .. " carries its control at offset " .. offset)
        Assert.deepEqual(
          assert(control.valueWindow, id .. " carries its numeric window at offset " .. offset),
          { x = 112, y = row.rect.y + 5, width = 44, height = 18 },
          id .. " keeps content-space geometry at offset " .. offset
        )
        Assert.deepEqual(
          assert(control.slider, id .. " carries its resolved rail at offset " .. offset).rect,
          { x = 164, y = row.rect.y + 6, width = 80, height = 12 },
          id .. " keeps its content-space rail at offset " .. offset
        )
      end
      text.draws = {}
      local canvas = drawPlan(scope, renderer, view, plan, 512, 384)
      local volumeDraw = findPlacedLine(text.draws, "80%")
      Assert.isTrue(volumeDraw ~= nil, "the volume value paints at offset " .. offset)
      Assert.equal(
        volumeDraw.x,
        112 + 44 - text:measurePlain("80%"),
        "the volume value right-aligns at offset " .. offset
      )
      Assert.equal(
        volumeDraw.y,
        rowsById.volume.rect.y + 5,
        "the volume value shares the row transform at offset " .. offset
      )
      local speedDraw = findPlacedLine(text.draws, "2x")
      Assert.isTrue(speedDraw ~= nil, "the speed value paints at offset " .. offset)
      Assert.equal(
        speedDraw.x,
        112 + 44 - text:measurePlain("2x"),
        "the speed value right-aligns at offset " .. offset
      )
      Assert.equal(
        speedDraw.y,
        rowsById.battleSpeed.rect.y + 5,
        "the speed value shares the row transform at offset " .. offset
      )
      local footerDraw = findPlacedLine(text.draws, "CONFIRM")
      Assert.isTrue(footerDraw ~= nil, "the footer paints at offset " .. offset)
      Assert.isTrue(footerDraw.y >= 168, "the footer stays below the list at offset " .. offset)
      local placement = assert(plan.panes[1].placement, "the native plan places its pane")
      local data = scope:own(canvas:newImageData())
      local volumeCenter = content.listViewport.y + (rowsById.volume.rect.y + 12 - offset)
      local speedCenter = content.listViewport.y + (rowsById.battleSpeed.rect.y + 12 - offset)
      local function at(lx, ly)
        local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
        return quantizePixel(data, hx, hy)
      end
      Assert.deepEqual(
        at(160, volumeCenter),
        { oddR, oddG, oddB, 255 },
        "the volume gap keeps its plate at offset " .. offset
      )
      Assert.deepEqual(
        at(130, volumeCenter),
        { oddR, oddG, oddB, 255 },
        "the volume slot holds no rail paint at offset " .. offset
      )
      Assert.deepEqual(
        at(160, speedCenter),
        { evenR, evenG, evenB, 255 },
        "the speed gap keeps its plate at offset " .. offset
      )
      Assert.deepEqual(
        at(130, speedCenter),
        { evenR, evenG, evenB, 255 },
        "the speed slot holds no rail paint at offset " .. offset
      )
      local volumeSlider = assert(rowsById.volume.control.slider, "the volume row carries its rail")
      local volumeCx = math.floor(volumeSlider.thumbRect.x + volumeSlider.thumbRect.width / 2)
      local volumeHx, volumeHy = LayoutGeometry.logicalToHost(
        placement,
        volumeCx,
        volumeSlider.centerY + content.listViewport.y - offset
      )
      Assert.deepEqual(
        quantizePixel(data, volumeHx, volumeHy),
        { 242, 242, 242, 255 },
        "the volume thumb travels with its row at offset " .. offset
      )
      local speedSlider = assert(rowsById.battleSpeed.control.slider, "the speed row carries its rail")
      local speedCx = math.floor(speedSlider.thumbRect.x + speedSlider.thumbRect.width / 2)
      local speedHx, speedHy = LayoutGeometry.logicalToHost(
        placement,
        speedCx,
        speedSlider.centerY + content.listViewport.y - offset
      )
      Assert.deepEqual(
        quantizePixel(data, speedHx, speedHy),
        { 242, 242, 242, 255 },
        "the speed thumb travels with its row at offset " .. offset
      )
    end
  end
  renderer:dispose()
end

-- The completed screen stays coherent in one composition: at every
-- scroll position the moving plates cover the list, the focused row wears
-- only the source strip, slider values never touch their rails, no extra
-- slider outline paints, the frame sample co-scrolls, and the header and
-- footer stay fixed on all four display arrangements.
function T.tests.touched_rows_keep_one_strip_across_offsets_sliders_and_layouts(scope)
  local Interface, Renderer = modules()
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renderer, text, window = preparedPlacedPainter(scope)
  local measurements = topologies()
  local resolvers = Interface.defaults()
  local borderR, borderG, borderB = FieldUiFixture.optionsSelectionOverlayBorderColor()
  local oddR, oddG, oddB = FieldUiFixture.optionsRowOddColor()
  local evenR, evenG, evenB = FieldUiFixture.optionsRowEvenColor()
  local frameR, frameG, frameB = FieldUiFixture.optionsRowFrameColor()
  local fullMatrix = {
    { offset = 0, focus = "textSpeed", volume = "80%", volumeIndex = 81, speed = "2x", speedValue = 2, speedIndex = 2 },
    { offset = 32, focus = "volume", volume = "0%", volumeIndex = 1, speed = "1x", speedValue = 1, speedIndex = 1 },
    { offset = 32, focus = "battleSpeed", volume = "100%", volumeIndex = 101, speed = "4x", speedValue = 4, speedIndex = 3 },
    { offset = 64, focus = "textFrame", volume = "80%", volumeIndex = 81, speed = "2x", speedValue = 2, speedIndex = 2 },
    { offset = 64, focus = "confirm", volume = "80%", volumeIndex = 81, speed = "2x", speedValue = 2, speedIndex = 2 },
  }
  local compactMatrix = {
    { offset = 0, focus = "textSpeed", volume = "80%", volumeIndex = 81, speed = "2x", speedValue = 2, speedIndex = 2 },
    { offset = 32, focus = "volume", volume = "0%", volumeIndex = 1, speed = "1x", speedValue = 1, speedIndex = 1 },
    { offset = 64, focus = "confirm", volume = "100%", volumeIndex = 101, speed = "4x", speedValue = 4, speedIndex = 3 },
  }
  local function plateFor(rowId, position)
    if rowId == "textFrame" then
      return { frameR, frameG, frameB, 255 }
    end
    if position % 2 == 1 then
      return { oddR, oddG, oddB, 255 }
    end
    return { evenR, evenG, evenB, 255 }
  end
  for _, case in ipairs({ "nativeLike", "wide", "tall", "dualDisplay" }) do
    local matrix = case == "nativeLike" and fullMatrix or compactMatrix
    for _, scenario in ipairs(matrix) do
      local tag = case .. " offset " .. scenario.offset .. " focus " .. scenario.focus
      local view = headlessSourceView({ battleSpeed = scenario.speedValue })
      for _, row in ipairs(view.rows) do
        if row.id == "volume" then
          row.valueLabel = scenario.volume
          row.valueIndex = scenario.volumeIndex
        end
        if row.id == "battleSpeed" then
          row.valueLabel = scenario.speed
          row.valueIndex = scenario.speedIndex
        end
      end
      view.focusId = scenario.focus
      view.scrollOffset = scenario.offset
      if scenario.offset == 64 then
        view.preview = { textSpeed = "mid", textFrame = 1 }
      end
      local plan = resolvers[case](contextFor(case, measurements), view)
      local content = assert(plan.content, tag .. " carries its list")
      Assert.equal(content.scrollOffset, scenario.offset, tag .. " keeps its scroll")
      Assert.equal(content.footer.y, 168, tag .. " pins its footer")
      local placement = nil
      for _, pane in ipairs(assert(plan.panes, tag .. " carries its panes")) do
        if pane.id == "controls" or pane.id == "content" then
          placement = pane.placement
        end
      end
      placement = assert(placement, tag .. " places its list pane")
      local rowsById = {}
      for _, row in ipairs(content.rows) do
        rowsById[row.id] = row
      end
      text.draws = {}
      window.draws = 0
      local canvas = drawPlan(scope, renderer, view, plan, measurements[case].width, measurements[case].height)
      local data = scope:own(canvas:newImageData())
      local function at(lx, ly)
        local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
        return quantizePixel(data, hx, hy)
      end
      Assert.deepEqual(at(6, 10), { 24, 120, 200, 255 }, tag .. " keeps its header base")
      Assert.deepEqual(at(6, 180), { 24, 120, 200, 255 }, tag .. " keeps its footer base")
      local volumeRow = assert(rowsById.volume, tag .. " keeps its volume row")
      local speedRow = assert(rowsById.battleSpeed, tag .. " keeps its speed row")
      local volumeDraw = findPlacedLine(text.draws, scenario.volume)
      Assert.isTrue(volumeDraw ~= nil, tag .. " paints " .. scenario.volume)
      Assert.equal(
        volumeDraw.x,
        112 + 44 - text:measurePlain(scenario.volume),
        tag .. " right-aligns " .. scenario.volume
      )
      Assert.equal(volumeDraw.y, volumeRow.rect.y + 5, tag .. " keeps the volume band")
      local speedDraw = findPlacedLine(text.draws, scenario.speed)
      Assert.isTrue(speedDraw ~= nil, tag .. " paints " .. scenario.speed)
      Assert.equal(
        speedDraw.x,
        112 + 44 - text:measurePlain(scenario.speed),
        tag .. " right-aligns " .. scenario.speed
      )
      Assert.equal(speedDraw.y, speedRow.rect.y + 5, tag .. " keeps the speed band")
      local volumeSlider = assert(volumeRow.control.slider, tag .. " carries its volume rail")
      local volumeCx = math.floor(volumeSlider.thumbRect.x + volumeSlider.thumbRect.width / 2)
      local volumeHx, volumeHy = LayoutGeometry.logicalToHost(
        placement,
        volumeCx,
        volumeSlider.centerY + content.listViewport.y - scenario.offset
      )
      Assert.deepEqual(
        quantizePixel(data, volumeHx, volumeHy),
        { 242, 242, 242, 255 },
        tag .. " keeps the volume thumb inside its rail"
      )
      for _, checked in ipairs({ { id = "volume", row = volumeRow }, { id = "battleSpeed", row = speedRow } }) do
        local edgeY = content.listViewport.y + checked.row.rect.y + 4 - scenario.offset
        local leaked = false
        for x = 162, 246 do
          local hx, hy = LayoutGeometry.logicalToHost(placement, x, edgeY)
          local sampled = quantizePixel(data, hx, hy)
          if sampled[1] == 255 and sampled[2] == 217 and sampled[3] == 51 and sampled[4] == 255 then
            leaked = true
            break
          end
        end
        Assert.isFalse(leaked, tag .. " paints no extra outline around the " .. checked.id .. " rail")
        local midHx, midHy = LayoutGeometry.logicalToHost(placement, 204, edgeY)
        Assert.deepEqual(
          quantizePixel(data, midHx, midHy),
          plateFor(checked.id, checked.row.position),
          tag .. " keeps the " .. checked.id .. " outline band on its row plate"
        )
      end
      if scenario.focus == "confirm" or scenario.focus == "quit" then
        Assert.deepEqual(at(2, 26), { oddR, oddG, oddB, 255 }, tag .. " hides the list strip")
      else
        local focusedRow = assert(rowsById[scenario.focus], tag .. " keeps its focused row")
        local stripTop = content.listViewport.y + focusedRow.rect.y - scenario.offset
        Assert.deepEqual(
          at(2, stripTop + 2),
          { borderR, borderG, borderB, 255 },
          tag .. " backs the touched row with the strip"
        )
        local expectedPlate = plateFor(scenario.focus, focusedRow.position)
        Assert.deepEqual(
          at(6, stripTop + 12),
          expectedPlate,
          tag .. " leaves the strip center on the row plate"
        )
      end
      if scenario.offset == 0 then
        Assert.equal(window.draws, 0, tag .. " hides the sample at the top")
      else
        Assert.equal(window.draws, 1, tag .. " paints the co-scrolling sample exactly once")
      end
      if scenario.offset == 64 then
        Assert.deepEqual(
          { x = window.lastBox.x, y = window.lastBox.y, width = window.lastBox.width, height = window.lastBox.height },
          { x = 16, y = 172, width = 216, height = 32 },
          tag .. " nests the revealed sample in its row"
        )
      end
      if case == "dualDisplay" and scenario.offset == 0 then
        local upperPlacement = nil
        for _, pane in ipairs(assert(plan.panes, tag .. " carries its panes")) do
          if pane.id == "preview" then
            upperPlacement = pane.placement
          end
        end
        if upperPlacement ~= nil then
          local upperHx, upperHy = LayoutGeometry.logicalToHost(upperPlacement, 10, 10)
          Assert.deepEqual(
            quantizePixel(data, upperHx, upperHy),
            { 210, 110, 30, 255 },
            tag .. " keeps the upper pane decorative"
          )
        end
      end
    end
  end
  renderer:dispose()
end

return GraphicsSmoke.suite(T.tests)
