-- The reusable Naming Screen composes generated source visuals instead of
-- hand-drawn rectangles: the opaque base first, the selected page overlay at
-- its canonical placement, then the OAM-composed controls, entry slots,
-- source-placed text, cursor visual, and manifest player subject. Unknown
-- pages are programmer errors, never a silent fallback.

local Assert = require("tests.support.Assert")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {}

local BASE_PATH = "assets/generated/field/ui/naming-screen-base.png"
local UPPER_PATH = "assets/generated/field/ui/naming-screen-page-upper.png"
local LOWER_PATH = "assets/generated/field/ui/naming-screen-page-lower.png"
local SYMBOLS_PATH = "assets/generated/field/ui/naming-screen-page-symbols.png"

local function manifest()
  return FieldUiFixture.namingSemanticsManifest()
end

local function graphicsFake()
  local calls = { draws = {}, rectangles = {}, colors = {} }
  local graphics = {
    push = function() end,
    pop = function() end,
    translate = function() end,
    scale = function() end,
    setColor = function(r, g, b, a)
      calls.colors[#calls.colors + 1] = { r, g, b, a }
    end,
    rectangle = function(mode, x, y, width, height)
      calls.rectangles[#calls.rectangles + 1] = { mode = mode, x = x, y = y, width = width, height = height }
    end,
    newQuad = function(x, y, w, h, imgW, imgH)
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
    draw = function(image, quad, x, y)
      if type(quad) == "number" then
        quad, x, y = nil, quad, x
      end
      calls.draws[#calls.draws + 1] = { image = image, quad = quad, x = x, y = y }
    end,
  }
  return graphics, calls
end

local function textFake()
  local calls = { texts = {} }
  local text = {
    drawText = function(_, value, x, y)
      calls.texts[#calls.texts + 1] = { value = value, x = x, y = y }
    end,
    textWidth = function(_, value)
      return #value * 8
    end,
  }
  return text, calls
end

local function imageLoaderFake(failOn)
  local calls = { loads = {}, images = {} }
  local loader = function(path)
    calls.loads[#calls.loads + 1] = path
    if failOn ~= nil and #calls.loads == failOn then
      error("injected image failure for " .. path, 0)
    end
    local image = { path = path, released = false, releaseCount = 0 }
    function image:setFilter() end
    function image:release()
      self.released = true
      self.releaseCount = self.releaseCount + 1
    end
    calls.images[#calls.images + 1] = image
    return image
  end
  return loader, calls
end

local function snapshot(page, cursor)
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "glyph", glyph = "A" }
    end
  end
  return {
    page = page,
    cursor = cursor,
    text = "AB",
    maxLength = 7,
    grid = grid,
    subject = { kind = "player", gender = 0 },
    presentation = { subjectTick = 0, cursorTick = 0, entrySlotTick = 0, glowAngle = 180 },
  }
end

local function layout()
  return NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 }, manifest().namingScreen)
end

function T.construction_requires_the_naming_chrome_contract()
  local graphics = graphicsFake()
  local text = textFake()
  Assert.throws(function()
    NamingScreenRenderer.new({ graphics = graphics, text = text, drawSubject = function() end })
  end, "a renderer without its naming manifest must fail at construction")
  local _, loads = imageLoaderFake()
  Assert.throws(function()
    NamingScreenRenderer.new({
      graphics = graphics,
      text = text,
      drawSubject = function() end,
      manifest = manifest(),
    })
  end, "a renderer without its generated image loader must fail at construction")
  Assert.equal(#loads.loads, 0, "a rejected construction acquires no images")
end

function T.construction_acquires_the_base_pages_and_every_semantic_visual()
  local graphics = graphicsFake()
  local loader, loads = imageLoaderFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest(),
    imageLoader = loader,
  })
  local naming = manifest().namingScreen
  local expected = { BASE_PATH, UPPER_PATH, LOWER_PATH, SYMBOLS_PATH }
  for _, record in pairs(naming.controls) do
    expected[#expected + 1] = record.image
  end
  local fixtureManifest = manifest()
  local function animationImages(record)
    local seen = {}
    for _, frame in ipairs(record.frames) do
      if not seen[frame.asset] then
        seen[frame.asset] = true
        expected[#expected + 1] = fixtureManifest.assets[frame.asset].image
      end
    end
    if record.pulseAsset ~= nil then
      expected[#expected + 1] = fixtureManifest.assets[record.pulseAsset].image
    end
  end
  animationImages(naming.playerSubjects.male)
  animationImages(naming.playerSubjects.female)
  animationImages(naming.pokemonGenderMarkers.male)
  animationImages(naming.pokemonGenderMarkers.female)
  animationImages(naming.cursor.keyboard)
  for _, record in pairs(naming.cursor.home) do
    animationImages(record)
  end
  expected[#expected + 1] = naming.entrySlots.normal.image
  animationImages(naming.entrySlots.selected)
  Assert.equal(#loads.loads, #expected, "construction loads the chrome plus every semantic visual")
  local seen = {}
  for _, path in ipairs(loads.loads) do
    seen[path] = true
  end
  for _, path in ipairs(expected) do
    Assert.isTrue(seen[path], "construction loads " .. path)
  end
  renderer:dispose()
  for _, image in ipairs(loads.images) do
    Assert.equal(image.releaseCount, 1, "dispose releases " .. image.path .. " exactly once")
  end
end

function T.construction_failure_releases_already_acquired_images()
  local loader, loads = imageLoaderFake(20)
  local err = Assert.throws(function()
    NamingScreenRenderer.new({
      graphics = graphicsFake(),
      text = textFake(),
      drawSubject = function() end,
      manifest = manifest(),
      imageLoader = loader,
    })
  end, "a late acquisition image failure must fail construction")
  Assert.isTrue(tostring(err):find("injected image failure", 1, true) ~= nil)
  Assert.equal(#loads.images, 19, "nineteen images were acquired before the failure")
  for _, image in ipairs(loads.images) do
    Assert.isTrue(image.released, image.path .. " is released after the failed construction")
    Assert.equal(image.releaseCount, 1, image.path .. " is released exactly once")
  end
end

function T.draw_composes_base_page_controls_slots_text_cursor_and_manifest_subject()
  local graphics, calls = graphicsFake()
  local text, textCalls = textFake()
  local loader, _ = imageLoaderFake()
  local seenSubject = {}
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = text,
    drawSubject = function(_, subject, rect)
      seenSubject[#seenSubject + 1] = { subject = subject, rect = rect }
    end,
    manifest = manifest(),
    imageLoader = loader,
  })
  local view = snapshot("lower", { row = 3, column = 5 })
  local layoutResult = layout()
  renderer:draw(view, layoutResult)

  Assert.isTrue(#calls.draws >= 2, "the base and the selected page are drawn as images")
  Assert.equal(calls.draws[1].image.path, BASE_PATH, "the base draws first")
  Assert.deepEqual({ x = calls.draws[1].x, y = calls.draws[1].y }, { x = 0, y = 0 })
  Assert.equal(calls.draws[2].image.path, LOWER_PATH, "the selected lower page draws over the base")
  Assert.deepEqual({ x = calls.draws[2].x, y = calls.draws[2].y }, { x = 11, y = 80 })

  Assert.equal(#calls.rectangles, 0, "source visuals replace every procedural outline")
  Assert.equal(#seenSubject, 0, "the player subject comes from the manifest, not the host callback")

  local naming = manifest().namingScreen
  local paths = {}
  for _, draw in ipairs(calls.draws) do
    paths[draw.image.path] = true
  end
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok", "backing" }) do
    Assert.isTrue(paths[naming.controls[id].image], "the " .. id .. " control draws its generated visual")
  end
  local keyboardFrame = naming.cursor.keyboard.frames[1]
  Assert.isTrue(paths[manifest().assets[keyboardFrame.asset].image], "the keyboard cursor draws its generated visual")
  Assert.isTrue(paths[naming.entrySlots.normal.image], "the entry slots draw their generated visual")
  local maleFrame = naming.playerSubjects.male.frames[1]
  Assert.isTrue(paths[manifest().assets[maleFrame.asset].image], "the male player subject draws its generated visual")

  local entered = {}
  for _, entry in ipairs(textCalls.texts) do
    entered[entry.value] = true
  end
  Assert.isNil(entered["AB"], "the entered name is placed per glyph, never as one string")
  Assert.isTrue(entered["A"] and entered["B"], "each entered glyph renders")
  Assert.isTrue(#textCalls.texts > 2, "keyboard glyphs still render")
  renderer:dispose()
end

local CANONICAL_VIEWPORT = { x = 0, y = 0, width = 256, height = 192 }

local function fullManifest()
  return FieldUiFixture.fieldStateManifest()
end

-- One coherent keyboard variant: the upper control and its home cursor move
-- right together while the keyboard stepping origin and every text-cell
-- position shift by the same column step. Source image content is untouched;
-- only manifest coordinates move.
local function relocatedVariant()
  local manifest = fullManifest()
  local naming = manifest.namingScreen
  naming.controls.upper.anchor = { x = 66, y = 68 }
  naming.cursor.home.upper.anchor = { x = 65, y = 68 }
  naming.cursor.keyboard.origin = { x = 42, y = 91 }
  for row = 1, 5 do
    for column = 1, 13 do
      naming.text.keyboard.cells[row][column].x = naming.text.keyboard.cells[row][column].x + 16
    end
  end
  return manifest
end

function T.relocated_control_anchor_moves_hit_geometry_with_the_manifest()
  local vanilla = NamingScreenLayout.compute(CANONICAL_VIEWPORT, fullManifest().namingScreen)
  Assert.deepEqual(vanilla.controls.upper, { x = 25, y = 60, width = 32, height = 23 })
  Assert.deepEqual(vanilla.cells[2][1], { x = 28, y = 88, width = 17, height = 20 })
  Assert.deepEqual(vanilla.cursorCenters[2][1], { x = 26, y = 91 })

  local moved = NamingScreenLayout.compute(CANONICAL_VIEWPORT, relocatedVariant().namingScreen)
  Assert.deepEqual(moved.controls.upper, { x = 65, y = 60, width = 32, height = 23 })
  Assert.deepEqual(moved.cells[2][1], { x = 44, y = 88, width = 17, height = 20 })
  Assert.deepEqual(moved.cursorCenters[2][1], { x = 42, y = 91 })
  Assert.isFalse(
    NamingScreenLayout.contains(moved.controls.upper, 30, 70),
    "the old control point must not activate the relocated target"
  )
  Assert.isTrue(NamingScreenLayout.contains(moved.controls.upper, 70, 70))
end

function T.relocated_naming_chrome_stays_valid_and_draws_from_the_manifest()
  Assert.isTrue(FieldUiAssetCache.validateManifest(fullManifest()))
  local variant = relocatedVariant()
  Assert.isTrue(FieldUiAssetCache.validateManifest(variant), "a coherently relocated naming section must stay usable")

  local graphics, calls = graphicsFake()
  local loader, _ = imageLoaderFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
    manifest = variant,
    imageLoader = loader,
  })
  renderer:draw(snapshot("upper", { row = 2, column = 1 }), layout())
  local upperDraw = nil
  for _, draw in ipairs(calls.draws) do
    if draw.image.path == variant.namingScreen.controls.upper.image then
      upperDraw = draw
    end
  end
  Assert.deepEqual(
    { x = assert(upperDraw).x, y = upperDraw.y },
    { x = 67, y = 70 },
    "the control visual follows its manifest anchor plus offset"
  )
  renderer:dispose()
end

function T.unknown_page_is_a_programmer_error()
  local loader = imageLoaderFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphicsFake(),
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest(),
    imageLoader = loader,
  })
  Assert.throws(function()
    renderer:draw(snapshot("digits", { row = 2, column = 1 }), layout())
  end, "an unknown page must fail instead of silently choosing a normal overlay")
  renderer:dispose()
end

return { tests = T }
