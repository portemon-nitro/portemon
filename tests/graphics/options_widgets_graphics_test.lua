-- Graphics contract for the concrete option-control painters: selected
-- and unselected choice states sample their own source frames through the
-- shared image-pool leases, pressed arrow and footer states resolve their
-- compiled frames by animation age, and the project-authored slider draws
-- only its rail, fill, and thumb on the logical pixel grid: a focused row is
-- marked by the list selection strip, never by an extra slider outline. Missing
-- art fails explicitly and every draw restores the borrowed graphics
-- state; releasing the borrowed leases returns pool references to
-- baseline.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")

local T = {}

local function widgetsModule()
  local ok, mod = pcall(require, "game.hgss.src.ui.OptionsWidgets")
  Assert.isTrue(ok, "OptionsWidgets missing: " .. tostring(mod))
  return mod
end

local function sliderModule()
  local ok, mod = pcall(require, "libs.ui.src.Slider")
  Assert.isTrue(ok, "Slider missing: " .. tostring(mod))
  return mod
end

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

local function preparedQuadFor(manifest, chrome)
  local image = assert(chrome.image, "the chrome lease carries its resolved image")
  local width, height = image:getWidth(), image:getHeight()
  local map = {}
  local function add(sequence)
    for _, frame in ipairs(assert(sequence.frames, "sequences carry frames")) do
      if map[frame] == nil then
        map[frame] =
          love.graphics.newQuad(frame.atlas.x, frame.atlas.y, frame.atlas.width, frame.atlas.height, width, height)
      end
    end
  end
  for _, size in ipairs({ "small", "wide" }) do
    add(manifest.options.choices[size].unselected)
    add(manifest.options.choices[size].selected)
  end
  for _, side in ipairs({ "left", "right" }) do
    add(manifest.options.arrows[side].idle)
    add(manifest.options.arrows[side].pressed)
  end
  for _, state in ipairs({ "normal", "focused", "pressed", "pressedFocused" }) do
    add(manifest.options.actions[state])
  end
  return function(frame)
    local quad = map[frame]
    Assert.notNil(quad, "the caller prepares every drawn frame")
    return quad
  end
end

local function optionsCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addOptionsContract(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  -- The pool worker reads PNG bytes through the versioned love-backend
  -- cache, never the test FakeCache: publish the fixture chrome at its
  -- fixture-specific path so production bytes are never confused.
  CacheFs.forVersion("heartgold"):write(FieldUiFixture.OPTIONS_CHROME_PATH, FieldUiFixture.optionsChromeBytes())
  return cache, manifest
end

local function acquireChrome(scope, pool, manifest)
  local entry = assert(manifest.assets[FieldUiAssetCache.ASSET.OPTIONS_CHROME])
  local token = pool:request(entry.image, POOLED_SAMPLER, "demand")
  local stalled = 0
  while true do
    local ok, status, failure = pcall(pool.poll, pool, token)
    if ok and status == "ready" then
      local lease = pool:acquire(token)
      return scope:own({
        release = function()
          pool:release(lease)
        end,
        lease = lease,
      }).lease
    end
    Assert.isTrue(
      ok and status == "pending",
      "chrome resolves through the pool worker: " .. tostring(status) .. " / " .. tostring(failure)
    )
    stalled = stalled + 1
    Assert.isTrue(stalled < 10000, "chrome acquisition stalls")
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
  end
end

local function setup(scope)
  local cache, manifest = optionsCache()
  local pool = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  local chrome = acquireChrome(scope, pool, manifest)
  return manifest, chrome
end

local function renderInto(scope, width, height, draw)
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  draw()
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function pixel(image, x, y)
  local r, g, b, a = image:getPixel(x, y)
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  return { quantize(r), quantize(g), quantize(b), quantize(a) }
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

function T.choice_states_sample_their_own_compiled_frames(scope)
  local Widgets = widgetsModule()
  local manifest, chrome = setup(scope)
  local quadFor = preparedQuadFor(manifest, chrome)
  local choice = assert(manifest.options.choices.small)
  local anchor = { x = 40, y = 30 }
  local function draw(selected)
    return renderInto(scope, 128, 64, function()
      Widgets.drawChoice(love.graphics, chrome, quadFor, choice, anchor, selected, 0)
    end)
  end
  local unselected = draw(false)
  local selected = draw(true)
  Assert.deepEqual(pixel(unselected, 40, 30), { 200, 40, 40, 255 }, "unselected samples its own patch frame")
  Assert.deepEqual(pixel(selected, 40, 30), { 40, 200, 40, 255 }, "selected samples its own pill frame")
  Assert.deepEqual(
    pixel(selected, 36, 30),
    { 40, 200, 40, 255 },
    "selected honors the signed source offset left of its anchor"
  )
  Assert.deepEqual(pixel(selected, 35, 30), { 0, 0, 0, 0 }, "pixels outside the frame rect stay untouched")
end

function T.pressed_states_resolve_their_compiled_frames_by_age(scope)
  local Widgets = widgetsModule()
  local manifest, chrome = setup(scope)
  local quadFor = preparedQuadFor(manifest, chrome)
  local arrows = assert(manifest.options.arrows)
  local function draw(side, age)
    return renderInto(scope, 128, 64, function()
      Widgets.drawCycle(love.graphics, chrome, quadFor, arrows, { x = 8, y = 24 }, { x = 104, y = 24 }, side, age)
    end)
  end
  local idle = draw(nil, 0)
  Assert.deepEqual(pixel(idle, 10, 26), { 200, 40, 200, 255 }, "idle samples the idle arrow frame")
  local early = draw("left", 0)
  Assert.deepEqual(pixel(early, 10, 26), { 40, 200, 200, 255 }, "a fresh press samples the first pressed frame")
  local late = draw("left", 4)
  Assert.deepEqual(pixel(late, 10, 26), { 150, 80, 20, 255 }, "an aged press samples the second pressed frame")
  local clamped = draw("left", 100000)
  Assert.deepEqual(
    pixel(clamped, 10, 26),
    { 150, 80, 20, 255 },
    "a one-shot press holds its terminal frame instead of wrapping"
  )
  local right = draw("right", 0)
  Assert.deepEqual(pixel(right, 10, 26), { 200, 40, 200, 255 }, "the unpressed side stays idle")
  Assert.deepEqual(pixel(right, 106, 26), { 20, 150, 80, 255 }, "the pressed side samples its own arrow frames")
  local actions = assert(manifest.options.actions)
  local pressed = renderInto(scope, 128, 64, function()
    Widgets.drawAction(love.graphics, chrome, quadFor, actions, { x = 32, y = 40 }, "pressed", 3)
  end)
  Assert.deepEqual(pixel(pressed, 34, 42), { 200, 200, 90, 255 }, "an aged footer press samples its second frame")
end

function T.slider_thumb_tracks_the_resolved_stop_on_the_pixel_grid(scope)
  local Widgets = widgetsModule()
  local Slider = sliderModule()
  setup(scope)
  local resolved =
    Slider.resolve({ rect = { x = 10, y = 20, width = 210, height = 30 }, count = 5, index = 4, knobExtent = 10 })
  local style = {
    rail = { r = 0, g = 0, b = 1, a = 1 },
    fill = { r = 0, g = 1, b = 0, a = 1 },
    thumb = { r = 1, g = 0, b = 0, a = 1 },
    thumbEdge = { r = 1, g = 1, b = 1, a = 1 },
  }
  local before = graphicsState()
  local unfocused = renderInto(scope, 256, 64, function()
    Widgets.drawSlider(love.graphics, resolved, style)
  end)
  assertSameState(before, graphicsState(), "slider painting")
  local thumb = resolved.thumbRect
  local centerX = math.floor(thumb.x + thumb.width / 2)
  local centerY = math.floor(resolved.centerY)
  Assert.deepEqual(pixel(unfocused, centerX, centerY), { 255, 0, 0, 255 }, "the thumb fills its resolved rect")
  Assert.deepEqual(
    pixel(unfocused, math.floor(resolved.trackStartX) + 2, centerY),
    { 0, 255, 0, 255 },
    "the traveled rail samples the fill treatment"
  )
  Assert.deepEqual(
    pixel(unfocused, math.floor(resolved.trackEndX) - 2, centerY),
    { 0, 0, 255, 255 },
    "the untraveled rail samples the rail treatment"
  )
  Assert.deepEqual(
    pixel(unfocused, resolved.rect.x, resolved.rect.y),
    { 0, 0, 0, 0 },
    "no focus outline leaks outside an unfocused slider"
  )
  local focused = renderInto(scope, 256, 64, function()
    Widgets.drawSlider(love.graphics, resolved, style)
  end)
  local function hasFocusTone(image)
    for y = 0, 63 do
      for x = 0, 255 do
        local sampled = pixel(image, x, y)
        if sampled[1] == 255 and sampled[2] == 255 and sampled[3] == 0 and sampled[4] == 255 then
          return true, x, y
        end
      end
    end
    return false
  end
  local leaked, leakX, leakY = hasFocusTone(focused)
  Assert.isFalse(leaked, "a focused slider paints no extra outline beyond its rail and thumb")
  local thumbCenter = math.floor(thumb.x + thumb.width / 2)
  local railCenter = math.floor(resolved.centerY)
  Assert.deepEqual(
    pixel(focused, thumbCenter, railCenter),
    { 255, 0, 0, 255 },
    "the focused thumb keeps its resolved fill"
  )
  Assert.deepEqual(
    pixel(focused, math.floor(resolved.trackStartX) + 2, railCenter),
    { 0, 255, 0, 255 },
    "the focused traveled rail keeps its fill treatment"
  )
  Assert.deepEqual(
    pixel(focused, math.floor(resolved.trackEndX) - 2, railCenter),
    { 0, 0, 255, 255 },
    "the focused untraveled rail keeps its rail treatment"
  )
  assertSameState(before, graphicsState(), "focused slider painting")
end

function T.missing_art_fails_without_touching_graphics_state(scope)
  local Widgets = widgetsModule()
  local manifest, chrome = setup(scope)
  local quadFor = preparedQuadFor(manifest, chrome)
  local broken = {
    unselected = manifest.options.choices.small.unselected,
    selected = {
      frames = {
        {
          image = manifest.options.choices.small.selected.frames[1].image,
          atlas = { x = 100000, y = 0, width = 24, height = 16 },
          offset = { x = 0, y = 0 },
          ticks = 1,
        },
      },
      loop = true,
      bounds = { x = 0, y = 0, width = 24, height = 16 },
    },
  }
  local before = graphicsState()
  local ok, err = pcall(Widgets.drawChoice, love.graphics, chrome, quadFor, broken, { x = 8, y = 8 }, true, 0)
  Assert.isFalse(ok, "a frame outside its atlas must fail")
  Assert.isTrue(tostring(err):find("atlas", 1, true) ~= nil, "the failure names the atlas rect")
  assertSameState(before, graphicsState(), "failed choice painting")
  local okQuad, errQuad = pcall(Widgets.drawChoice, love.graphics, chrome, function()
    return nil
  end, manifest.options.choices.small, { x = 8, y = 8 }, false, 0)
  Assert.isFalse(okQuad, "a missing prepared quad must fail loudly")
  Assert.isTrue(tostring(errQuad):find("never prepared", 1, true) ~= nil, "the failure names the unmet preparation")
  assertSameState(before, graphicsState(), "failed quad lookup painting")
end

function T.release_returns_pool_references_to_baseline(_scope)
  widgetsModule()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addOptionsContract(manifest)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  CacheFs.forVersion("heartgold"):write(FieldUiFixture.OPTIONS_CHROME_PATH, FieldUiFixture.optionsChromeBytes())
  local settledImages = love.graphics.getStats().images
  local pool = ImageAssetPool.new(cache)
  local entry = assert(manifest.assets[FieldUiAssetCache.ASSET.OPTIONS_CHROME])
  local token = pool:request(entry.image, POOLED_SAMPLER, "demand")
  local chrome = nil
  for _ = 1, 10000 do
    local ok, status = pcall(pool.poll, pool, token)
    if ok and status == "ready" then
      chrome = pool:acquire(token)
      break
    end
    if love.timer ~= nil then
      love.timer.sleep(0.001)
    end
  end
  Assert.notNil(chrome, "chrome resolves through its lease")
  pool:release(chrome)
  pool:dispose()
  Assert.equal(love.graphics.getStats().images, settledImages, "disposing the pool releases its images")
end

return GraphicsSmoke.suite(T)
