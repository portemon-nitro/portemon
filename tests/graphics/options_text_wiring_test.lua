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
  for _, id in ipairs({ "textSpeed", "battleScene", "battleStyle", "soundMode", "volume", "battleSpeed", "textFrame" }) do
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

-- Synthetic Font0 definition behind the wiring stubs: normalized palette
-- slots with distinct selected/normal ink and an 8px fallback advance, so
-- source role palettes resolve to exact byte triples in assertions.
local function testFontDef()
  return {
    glyphs = { [0] = { advance = 8 } },
    letterSpacing = 0,
    charmap = {},
    palette = {
      [1] = { r = 0, g = 0, b = 0 },
      [2] = { r = 1, g = 0, b = 0 },
      [3] = { r = 0, g = 1, b = 0 },
      [16] = { r = 0, g = 0, b = 1 },
    },
  }
end

local function preparedWiring(scope)
  local Resources = require("game.hgss.src.field.FieldPresentationResources")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local palettes = {}
  local drawnLines = {}
  local tokenLines = {}
  local stubText = { fontDef = testFontDef() }
  function stubText:drawTextWithPalette(line, _, _, palette)
    palettes[#palettes + 1] = palette
    drawnLines[#drawnLines + 1] = line
  end
  function stubText:drawLine(tokens, x, y)
    tokenLines[#tokenLines + 1] = { tokens = tokens, x = x, y = y }
    return "drawn"
  end
  function stubText:drawLineWithPalette(tokens, x, y, palette)
    tokenLines[#tokenLines + 1] = { tokens = tokens, x = x, y = y, palette = palette }
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
  return resources, palettes, tokenLines, drawnLines
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
      local color =
        assert(type(palette[slot]) == "table" and palette[slot], "label draw " .. index .. " carries " .. slot)
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

function T.tests.labels_paint_a_single_source_palette_pass(scope)
  local resources, palettes, _, drawnLines = preparedWiring(scope)
  local renderer = assert(resources._optionsRenderer, "open presentation retains its renderer")
  drawNative(scope, renderer, sampleView())
  local counts = {}
  for _, line in ipairs(drawnLines) do
    counts[line] = (counts[line] or 0) + 1
  end
  -- The top of the list reveals the six ordinary rows; the footer is
  -- always pinned. Each visible label paints exactly one palette pass.
  for _, label in ipairs({
    "TEXTSPEED",
    "BATTLESCENE",
    "BATTLESTYLE",
    "SOUNDMODE",
    "VOLUME",
    "BATTLESPEED",
    "CONFIRM",
    "QUIT",
  }) do
    Assert.equal(counts[label], 1, "label paints exactly one palette pass: " .. label)
  end
  -- Scrolling to the bottom reveals the closing frame row; it paints once
  -- there and never at the top.
  local bottomed = sampleView()
  bottomed.scrollOffset = 72
  drawNative(scope, renderer, bottomed)
  local bottomCounts = {}
  for _, line in ipairs(drawnLines) do
    bottomCounts[line] = (bottomCounts[line] or 0) + 1
  end
  for _, label in ipairs({ "TEXTFRAME" }) do
    Assert.equal(bottomCounts[label], 1, "scrolled label paints exactly one palette pass: " .. label)
    Assert.isTrue(counts[label] == nil, "scrolled label paints nothing at the top: " .. label)
  end
  local normal = {
    foreground = { r = 0, g = 0, b = 255 },
    shadow = { r = 0, g = 255, b = 0 },
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
  local selected = {
    foreground = { r = 255, g = 0, b = 0 },
    shadow = { r = 0, g = 255, b = 0 },
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
  local byLine = {}
  for index, line in ipairs(drawnLines) do
    if byLine[line] == nil then
      byLine[line] = palettes[index]
    end
  end
  Assert.deepEqual(byLine["TEXTSPEED_S1"], selected, "the current stop paints the selected source triple")
  Assert.deepEqual(byLine["TEXTSPEED_S2"], normal, "another stop paints the unselected source triple")
  Assert.deepEqual(byLine["CONFIRM"], normal, "footer actions paint the unselected source triple")
  Assert.deepEqual(byLine["TEXTSPEED"], normal, "row names paint the unselected source triple")
end

function T.tests.token_draws_forward_to_the_shared_glyph_renderer(scope)
  local resources, _, tokenLines = preparedWiring(scope)
  local adapter = assert(
    resources._optionsRenderer and resources._optionsRenderer._text,
    "open presentation retains its text adapter"
  )
  Assert.equal(type(adapter.drawTokens), "function", "the options adapter draws token glyphs")
  local tokens = { { kind = "glyph", code = 1, text = "A" } }
  local result = adapter:drawTokens(tokens, 7, 9, "normal", "test role")
  Assert.equal(result, "drawn", "the adapter returns the shared renderer result")
  Assert.equal(#tokenLines, 1, "one token draw forwards to the shared renderer")
  Assert.isTrue(tokenLines[1].tokens == tokens, "tokens forward without copying")
  Assert.equal(tokenLines[1].x, 7, "the draw keeps its horizontal origin")
  Assert.equal(tokenLines[1].y, 9, "the draw keeps its vertical origin")
  Assert.isTrue(type(tokenLines[1].palette) == "table", "the draw carries the source role palette")
end

-- Presented source labels carry a reversible diagnostic serialization beside
-- their glyph stream. The presenter must paint only the glyphs: a footer
-- record with a centering prefix and one with a cursor prefix exercise the
-- prefix path, while the choice values stay plain. The adapter and the
-- renderer share one recording stub standing in for the field text owner,
-- so plain-string draws, token draws, and their palettes are all visible.
local function recordingSourceText()
  local stub = { plain = {}, tokenPath = {}, tokenLines = {}, fontDef = testFontDef() }
  function stub:drawTextWithPalette(line, x, y, palette)
    stub.plain[#stub.plain + 1] = { line = line, x = x, y = y, palette = palette }
  end
  function stub:drawLineWithPalette(tokens, x, y, palette)
    stub.tokenPath[#stub.tokenPath + 1] = { tokens = tokens, x = x, y = y, palette = palette }
  end
  function stub:drawLine(tokens, x, y)
    stub.tokenLines[#stub.tokenLines + 1] = { tokens = tokens, x = x, y = y }
    return "drawn"
  end
  function stub:textWidth(text)
    return #text * 8
  end
  function stub:windowBackgroundColor()
    return { 0.1, 0.2, 0.3, 1 }
  end
  return stub
end

local function headlessSourceView(overrides)
  local ScreenState = require("game.hgss.src.options.OptionsScreenState")
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
  return state:status()
end

local function preparedSourceWiring(scope)
  local Resources = require("game.hgss.src.field.FieldPresentationResources")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local stub = recordingSourceText()
  local stubWindow = {}
  function stubWindow:drawWindow(_, _, _) end
  local resources = setmetatable({
    cacheFs = cache,
    uiManifest = manifest,
    _imagePool = pool,
    textRenderer = stub,
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
  Assert.isTrue(ready == true, "the painter prepares")
  return resources, stub
end

local function drawSourceView(scope, renderer, view)
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
  return plan
end

local function joinGlyphs(tokens)
  local out = {}
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      out[#out + 1] = token.text
    end
  end
  return table.concat(out)
end

local function findTokenDraw(draws, word)
  for _, draw in ipairs(draws) do
    if joinGlyphs(draw.tokens) == word then
      return draw
    end
  end
  return nil
end

-- Source label records must paint as positioned glyphs, never as their
-- diagnostic serialization: the footer Confirm/Quit records carry layout
-- prefixes that serialize into brace markers, and only the glyph stream
-- may reach player pixels. Selected and unselected values use distinct
-- source palette roles, and every glyph origin is measured from the same
-- advances the draw uses, inside its bounded label window.
function T.tests.source_control_prefixes_render_as_glyphs_never_as_markers(scope)
  local resources, stub = preparedSourceWiring(scope)
  local renderer = assert(resources._optionsRenderer, "open presentation retains its renderer")
  local view = headlessSourceView()
  drawSourceView(scope, renderer, view)
  for _, draw in ipairs(stub.plain) do
    Assert.isTrue(
      draw.line:find("{", 1, true) == nil,
      "a diagnostic control marker paints as player text: " .. draw.line
    )
  end
  for _, draw in ipairs(stub.tokenPath) do
    Assert.isTrue(joinGlyphs(draw.tokens):find("{", 1, true) == nil, "a control token paints as a visible glyph")
  end
  local confirm = findTokenDraw(stub.tokenPath, "CONFIRM")
  Assert.notNil(confirm, "footer Confirm tokens never reach the shared glyph renderer")
  local quit = findTokenDraw(stub.tokenPath, "QUIT")
  Assert.notNil(quit, "footer Quit tokens never reach the shared glyph renderer")
  local mid = findTokenDraw(stub.tokenPath, "MID")
  Assert.notNil(mid, "the selected choice value never reaches the shared glyph renderer")
  local fast = findTokenDraw(stub.tokenPath, "FAST")
  Assert.notNil(fast, "an unselected choice value never reaches the shared glyph renderer")
  local function inkTriple(palette, slot)
    local color = assert(palette[slot], "glyph draws carry their " .. slot .. " ink")
    return string.format("%s/%s/%s", tostring(color.r), tostring(color.g), tostring(color.b))
  end
  Assert.isTrue(
    inkTriple(mid.palette, "foreground") ~= inkTriple(fast.palette, "foreground")
      or inkTriple(mid.palette, "shadow") ~= inkTriple(fast.palette, "shadow"),
    "the selected value paints no distinct source palette role from unselected values"
  )
  for _, draw in ipairs(stub.tokenPath) do
    Assert.equal(draw.palette.background.a, 0, "glyph background stays transparent over the source backing")
  end
  local adapter = assert(renderer._text, "open presentation retains its text adapter")
  local measure = adapter.measureSource or adapter.measureTokens
  Assert.isTrue(
    type(measure) == "function",
    "source labels have no measured-glyph layout path; origins cannot come from glyph advances"
  )
  local semantic = FieldUiFixture.optionsSourceSemantic()
  local function measuredWidth(word)
    for _, key in ipairs({ "confirm", "quit" }) do
      if semantic.labels[key] ~= nil and joinGlyphs(semantic.labels[key].tokens) == word then
        return measure(adapter, semantic.labels[key].tokens)
      end
    end
    for _, group in ipairs({ "textSpeedValues", "battleSceneValues", "battleStyleValues", "soundModeValues" }) do
      for _, record in pairs(semantic.labels[group]) do
        if joinGlyphs(record.tokens) == word then
          return measure(adapter, record.tokens)
        end
      end
    end
    for slot = 0, 19 do
      if joinGlyphs(semantic.labels.frameValues[slot].tokens) == word then
        return measure(adapter, semantic.labels.frameValues[slot].tokens)
      end
    end
    error("no source record spells " .. word, 0)
  end
  local function assertCentered(word, centerX, label)
    local draw = assert(findTokenDraw(stub.tokenPath, word), label .. " never reaches the shared glyph renderer")
    Assert.equal(
      draw.x + math.floor(measuredWidth(word) / 2),
      centerX,
      label .. " glyphs are not centered about their source position"
    )
  end
  -- Screen label centers are window-relative +8 from the decomp ground
  -- truth (window origin x=8): text speed stops center on 132/180/228.
  assertCentered("MID", 132, "the first text-speed stop")
  assertCentered("FAST", 180, "the second text-speed stop")
  assertCentered("CONFIRM", 148, "footer Confirm")
  Assert.isTrue(quit.x >= 192 and quit.x < 192 + 56, "footer Quit glyphs escape their source label window")
end

-- The scrolling sample window prints through the preview printer font, not
-- the menu font: the adapter exposes a dedicated preview token path bound
-- to the field-owned preview text renderer, and the menu renderer never
-- sees preview glyphs.
function T.tests.menu_preview_prints_through_the_dedicated_preview_font_path(scope)
  local Resources = require("game.hgss.src.field.FieldPresentationResources")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local menuText = recordingSourceText()
  local previewText = recordingSourceText()
  local stubWindow = {}
  function stubWindow:drawWindow(_, _, _) end
  local resources = setmetatable({
    cacheFs = cache,
    uiManifest = manifest,
    _imagePool = pool,
    textRenderer = menuText,
    battleTextRenderers = { narration = previewText },
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
  resources:openOptionsPresentation()
  local adapter = assert(resources._optionsRenderer._text, "open presentation retains its text adapter")
  Assert.isTrue(
    type(adapter.drawPreviewTokens) == "function",
    "the menu sample has no dedicated preview-font token path; the menu font backs the preview"
  )
  local tokens = { { kind = "glyph", code = 1, text = "W" } }
  adapter:drawPreviewTokens(tokens, 30, 40)
  Assert.equal(#previewText.tokenPath + #previewText.tokenLines, 1, "one preview line reaches the preview font")
  local routed = previewText.tokenPath[1] or previewText.tokenLines[1]
  Assert.isTrue(routed.tokens == tokens, "preview tokens forward without copying")
  Assert.equal(routed.x, 30, "the preview line keeps its horizontal origin")
  Assert.equal(routed.y, 40, "the preview line keeps its vertical origin")
  Assert.equal(
    #menuText.tokenPath + #menuText.tokenLines + #menuText.plain,
    0,
    "no preview glyph leaks into the menu font"
  )
end

-- Unsupported substitutions never paint as text: a STRVAR control in a
-- menu label record fails the draw at its semantic role instead of
-- printing its diagnostic marker, and no brace marker reaches the shared
-- glyph renderer on any path.
function T.tests.unsupported_substitutions_fail_explicitly_without_printing_markers(scope)
  local MessageText = require("libs.assets.src.field.FieldMessageText")
  local resources, stub = preparedSourceWiring(scope)
  local adapter = assert(resources._optionsRenderer._text, "open presentation retains its text adapter")
  local bad = {
    { kind = "glyph", code = 1, text = "A" },
    { kind = "substitution", control = MessageText.STRVAR_1 + 1, args = { 1, 0, 0 } },
    { kind = "eos" },
  }
  local ok, err = pcall(function()
    return adapter:drawTokens(bad, 0, 0, "normal", "footer confirm")
  end)
  Assert.isFalse(ok, "an unsupported substitution must fail instead of painting")
  Assert.isTrue(
    tostring(err):find("footer confirm", 1, true) ~= nil and tostring(err):find("STRVAR_1", 1, true) ~= nil,
    "the failure names its semantic role and control: " .. tostring(err)
  )
  local measureOk, measureErr = pcall(function()
    return adapter:measureTokens(bad, "footer confirm")
  end)
  Assert.isFalse(measureOk, "measuring an unsupported substitution must fail")
  Assert.isTrue(
    tostring(measureErr):find("footer confirm", 1, true) ~= nil,
    "the measure failure names its semantic role"
  )
  local semantic = FieldUiFixture.optionsSourceSemantic()
  local corrupted = { labels = {}, framePreviewText = semantic.framePreviewText }
  for key, record in pairs(semantic.labels) do
    corrupted.labels[key] = record
  end
  local confirmTokens = {}
  confirmTokens[1] = { kind = "substitution", control = MessageText.STRVAR_1 + 2, args = { 2, 0, 0 } }
  for _, token in ipairs(semantic.labels.confirm.tokens) do
    confirmTokens[#confirmTokens + 1] = token
  end
  confirmTokens[#confirmTokens + 1] = { kind = "eos" }
  corrupted.labels.confirm = { text = semantic.labels.confirm.text, tokens = confirmTokens }
  local ScreenState = require("game.hgss.src.options.OptionsScreenState")
  local port = {
    read = function()
      return 80
    end,
    preview = function(_) end,
    commit = function(_) end,
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
    applyChannelMode = function(_) end,
    effect = function(_) end,
    semantic = corrupted,
  })
  local renderer = assert(resources._optionsRenderer, "open presentation retains its renderer")
  -- LogicalSurface scopes intentionally stay pushed when a draw callback fails
  -- (pinned shared contract): unwind to the pre-draw depth plus the canvas
  -- and scissor the failed draw skipped, so this intentional failure cannot
  -- clip later suites in the same process.
  local stackDepth = love.graphics.getStackDepth()
  local scissorX, scissorY, scissorWidth, scissorHeight = love.graphics.getScissor()
  local drawn, drawErr = pcall(drawSourceView, scope, renderer, state:status())
  while love.graphics.getStackDepth() > stackDepth do
    love.graphics.pop()
  end
  if scissorX ~= nil then
    love.graphics.setScissor(scissorX, scissorY, scissorWidth, scissorHeight)
  else
    love.graphics.setScissor()
  end
  love.graphics.setCanvas()
  Assert.isFalse(drawn, "a corrupted footer record must fail the draw")
  Assert.isTrue(tostring(drawErr):find("footer confirm", 1, true) ~= nil, "the draw failure names its semantic role")
  for _, draw in ipairs(stub.plain) do
    Assert.isTrue(draw.line:find("{", 1, true) == nil, "no diagnostic marker paints as player text")
  end
  state:dispose()
end

-- Menu and preview rendering use their own font advances and palette
-- slots: measuring follows the Font0 definition while preview lines
-- route to the Font1 renderer with the preview triple.
function T.tests.menu_and_preview_measures_use_their_own_font_advances(scope)
  local Resources = require("game.hgss.src.field.FieldPresentationResources")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local function fontWith(advance, selected, shadow, background)
    return {
      glyphs = { [65] = { advance = advance }, [0] = { advance = advance } },
      letterSpacing = 0,
      charmap = { A = 65, W = 65, M = 65, I = 65 },
      palette = {
        [1] = background,
        [2] = selected,
        [3] = shadow,
        [16] = { r = 0, g = 0, b = 1 },
      },
    }
  end
  local menuDraws = {}
  local menuText = { fontDef = fontWith(6, { r = 1, g = 0, b = 0 }, { r = 0, g = 1, b = 0 }, { r = 0, g = 0, b = 0 }) }
  function menuText:drawLineWithPalette(tokens, x, y, palette)
    menuDraws[#menuDraws + 1] = { tokens = tokens, x = x, y = y, palette = palette }
  end
  function menuText:drawTextWithPalette(line, x, y, palette)
    menuDraws[#menuDraws + 1] = { line = line, x = x, y = y, palette = palette }
  end
  function menuText:windowBackgroundColor()
    return { 0.1, 0.2, 0.3, 1 }
  end
  local previewDraws = {}
  local previewText =
    { fontDef = fontWith(10, { r = 1, g = 1, b = 0 }, { r = 0, g = 1, b = 1 }, { r = 0, g = 0, b = 0 }) }
  function previewText:drawLineWithPalette(tokens, x, y, palette)
    previewDraws[#previewDraws + 1] = { tokens = tokens, x = x, y = y, palette = palette }
  end
  function previewText:drawTextWithPalette(line, x, y, palette)
    previewDraws[#previewDraws + 1] = { line = line, x = x, y = y, palette = palette }
  end
  function previewText:windowBackgroundColor()
    return { 0.1, 0.2, 0.3, 1 }
  end
  local stubWindow = {}
  function stubWindow:drawWindow(_, _, _) end
  local resources = setmetatable({
    cacheFs = cache,
    uiManifest = manifest,
    _imagePool = pool,
    textRenderer = menuText,
    battleTextRenderers = { narration = previewText },
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
  Assert.isTrue(ready == true, "the painter prepares")
  local adapter = assert(resources._optionsRenderer._text, "open presentation retains its text adapter")
  local tokens = {
    { kind = "glyph", code = 65, text = "M" },
    { kind = "glyph", code = 65, text = "I" },
    { kind = "glyph", code = 65, text = "D" },
    { kind = "eos" },
  }
  Assert.equal(adapter:measureTokens(tokens, "choice textSpeed stop 1"), 18, "measuring follows the menu advances")
  adapter:drawTokens(tokens, 4, 6, "selected", "choice textSpeed stop 1")
  Assert.equal(#menuDraws, 1, "menu tokens reach the menu font")
  Assert.equal(#previewDraws, 0, "menu tokens never reach the preview font")
  Assert.deepEqual(menuDraws[1].palette, {
    foreground = { r = 255, g = 0, b = 0 },
    shadow = { r = 0, g = 255, b = 0 },
    background = { r = 0, g = 0, b = 0, a = 0 },
  }, "the selected role resolves its source slots")
  adapter:drawTokens(tokens, 4, 6, "normal", "choice textSpeed stop 2")
  Assert.deepEqual(menuDraws[2].palette, {
    foreground = { r = 0, g = 0, b = 255 },
    shadow = { r = 0, g = 255, b = 0 },
    background = { r = 0, g = 0, b = 0, a = 0 },
  }, "the unselected role resolves its source slots")
  Assert.equal(adapter:measurePlain("AB"), 12, "authored strings measure in the menu advances")
  local previewTokens = {
    { kind = "glyph", code = 65, text = "W" },
    { kind = "eos" },
  }
  adapter:drawPreviewTokens(previewTokens, 30, 40)
  Assert.equal(#previewDraws, 1, "one preview line reaches the preview font")
  Assert.equal(#menuDraws, 2, "no preview glyph leaks into the menu font")
  Assert.deepEqual(previewDraws[1].palette, {
    foreground = { r = 255, g = 255, b = 0 },
    shadow = { r = 0, g = 255, b = 255 },
    background = { r = 0, g = 0, b = 255 },
  }, "preview lines resolve the preview source triple")
end

-- This suite stages its own complete synthetic image set under its own
-- disposable namespace: the namespace starts clean without the other suite
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
  Assert.equal(manifest.options.version, 6, "the staged section carries its indicator contract")
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
  }) do
    Assert.notNil(workerVisible:read(path), "the worker-readable namespace stages " .. path)
  end
  local overlay =
    assert(manifest.assets[FieldUiFixture.optionsSelectionOverlayKey()], "the selected-row strip asset is indexed")
  Assert.equal(overlay.width, 256, "the selected-row strip width")
  Assert.equal(overlay.height, 30, "the selected-row strip height")
end

-- Slider values measure in their own font advances and never silently
-- overlap the rail: every supported label fits the reserved window from
-- real glyph advances (none match a byte-count estimate), while an
-- over-wide label fails the draw naming its row and value instead of
-- painting clipped text.
function T.tests.slider_values_measure_in_font_advances_and_overflow_fails_loudly(scope)
  local Resources = require("game.hgss.src.field.FieldPresentationResources")
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  ownPool(scope, pool)
  local advanceByChar = { ["0"] = 5, ["%"] = 9, ["1"] = 4, ["x"] = 7, ["2"] = 6, ["4"] = 6, ["8"] = 6 }
  local glyphs = { [0] = { advance = 8 } }
  local charmap = {}
  local code = 1
  for char, advance in pairs(advanceByChar) do
    glyphs[code] = { advance = advance }
    charmap[char] = code
    code = code + 1
  end
  local menuText = {
    fontDef = {
      glyphs = glyphs,
      letterSpacing = 1,
      charmap = charmap,
      palette = {
        [1] = { r = 0, g = 0, b = 0 },
        [2] = { r = 1, g = 0, b = 0 },
        [3] = { r = 0, g = 1, b = 0 },
        [16] = { r = 0, g = 0, b = 1 },
      },
    },
  }
  function menuText:drawLineWithPalette(_, _, _, _) end
  function menuText:drawTextWithPalette(_, _, _, _) end
  function menuText:windowBackgroundColor()
    return { 0.1, 0.2, 0.3, 1 }
  end
  local stubWindow = {}
  function stubWindow:drawWindow(_, _, _) end
  local resources = setmetatable({
    cacheFs = cache,
    uiManifest = manifest,
    _imagePool = pool,
    textRenderer = menuText,
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
  Assert.isTrue(ready == true, "the painter prepares")
  local adapter = assert(resources._optionsRenderer._text, "open presentation retains its text adapter")
  local expectedWidths = {
    ["0%"] = 16,
    ["80%"] = 23,
    ["100%"] = 27,
    ["1x"] = 13,
    ["2x"] = 15,
    ["4x"] = 15,
  }
  for _, line in ipairs({ "0%", "80%", "100%", "1x", "2x", "4x" }) do
    local width = adapter:measurePlain(line)
    Assert.equal(width, expectedWidths[line], line .. " measures in font advances")
    Assert.isTrue(width <= 44, line .. " fits the numeric window")
  end
  local renderer = assert(resources._optionsRenderer, "open presentation retains its renderer")
  local view = headlessSourceView()
  for _, row in ipairs(view.rows) do
    if row.id == "volume" then
      row.valueLabel = "88888888%"
    end
  end
  -- A failed draw leaves its scopes pushed by shared contract: unwind to
  -- the pre-draw depth plus the canvas so this intentional failure
  -- cannot clip later suites in the same process.
  local stackDepth = love.graphics.getStackDepth()
  local scissorX, scissorY, scissorWidth, scissorHeight = love.graphics.getScissor()
  local drawn, drawErr = pcall(drawSourceView, scope, renderer, view)
  while love.graphics.getStackDepth() > stackDepth do
    love.graphics.pop()
  end
  if scissorX ~= nil then
    love.graphics.setScissor(scissorX, scissorY, scissorWidth, scissorHeight)
  else
    love.graphics.setScissor()
  end
  love.graphics.setCanvas()
  Assert.isFalse(drawn, "an over-wide slider value must fail the draw")
  Assert.isTrue(tostring(drawErr):find("volume", 1, true) ~= nil, "the layout failure names its row")
  Assert.isTrue(
    tostring(drawErr):find("88888888%", 1, true) ~= nil,
    "the layout failure names its value"
  )
end

return GraphicsSmoke.suite(T.tests)
