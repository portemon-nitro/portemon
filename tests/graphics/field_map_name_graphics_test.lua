-- Native placement, geometry, and composition order of the transient top-left
-- area-name banner: the source 136x32 skin lands at logical x0 with the scroll
-- displacement as a vertical offset, the centered title is painted through the
-- style's own palette path, the whole overlay anchors to the canonical 256x192
-- MAIN reference frame rather than the host origin, and the field composes it
-- after the world and warp fade and before the script-owned cover.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldState = require("game.hgss.src.field.FieldState")
local PixelScale = require("libs.ui.src.PixelScale")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192
local BANNER_WIDTH = 136
local BANNER_TEXT_Y = 8
local BANNER_TEXT_INSET = 4

local T = {}

-- The banner renderer is the module under test, so its absence must fail as
-- the missing behavior, not as a suite load error.
local function rendererModule(behavior)
  local ok, moduleOrError = pcall(require, "game.hgss.src.field.FieldMapNameRenderer")
  Assert.isTrue(ok, behavior .. " is missing: the banner renderer is unavailable")
  local module = moduleOrError
  Assert.isTrue(type(module.new) == "function", behavior .. " is missing: the renderer exposes no constructor")
  Assert.isTrue(type(module.draw) == "function", behavior .. " is missing: the renderer exposes no draw operation")
  return module
end

-- The generated text roles are the style's own area-window palette, never the
-- dialogue frame's user selection.
local STYLE_PALETTE = {
  foreground = { r = 248, g = 248, b = 248, a = 255 },
  shadow = { r = 88, g = 88, b = 88, a = 255 },
  background = { r = 0, g = 0, b = 0, a = 255 },
}

-- The shared glyph atlas is a borrowed collaborator; this records the exact
-- text placement and palette the renderer asks for without materializing a
-- font.
local function recordingText(titleWidth)
  return {
    width = titleWidth,
    measured = nil,
    calls = {},
    textWidth = function(self, text)
      self.measured = text
      return self.width
    end,
    drawTextWithPalette = function(self, text, x, y, palette)
      self.calls[#self.calls + 1] = { text = text, x = x, y = y, palette = palette }
    end,
  }
end

---@return table renderer, table skin
local function bannerRenderer(behavior, graphics, text)
  local module = rendererModule(behavior)
  local skin = graphics.newImage()
  local renderer = module.new({
    graphics = graphics,
    text = text,
    imageFor = function()
      return { image = skin, palette = STYLE_PALETTE }
    end,
  })
  return renderer, skin
end

local function referenceFrame(x, y)
  return { x = x, y = y, width = CANONICAL_WIDTH, height = CANONICAL_HEIGHT }
end

function T.the_skin_and_centered_title_land_at_the_source_geometry()
  local graphics = FakeGraphics.new()
  local text = recordingText(80)
  local renderer, skin = bannerRenderer("area-name presentation", graphics, text)
  renderer:draw({ title = "ROUTE 29", styleKey = 2, scrollOffset = 38 }, referenceFrame(40, 30))

  -- One logical scope only: a single translate to the canonical origin and one
  -- scale. A second transform would scale the borrowed surface twice.
  local transforms = graphics.transforms
  Assert.equal(#transforms, 2, "the banner composes exactly one logical transform")
  Assert.equal(transforms[1][1], "translate", "the banner anchors with one origin translate")
  Assert.equal(transforms[2][1], "scale", "the banner applies one logical scale")

  local skinDraw = assert(graphics.draws[1], "the banner skin is drawn")
  Assert.isTrue(skinDraw.image == skin, "the selected banner skin is drawn")
  Assert.equal(skinDraw.x, 0, "the skin sits at logical x0")
  Assert.equal(skinDraw.y, -38, "the skin displacement is the negated scroll offset")

  local textCall = assert(text.calls[1], "the resolved title is drawn")
  Assert.equal(text.measured, "ROUTE 29", "the measured title is the resolved section name")
  Assert.equal(textCall.text, "ROUTE 29", "the native section title is drawn")
  Assert.equal(textCall.y, BANNER_TEXT_Y - 38, "the title shares the skin's displacement")
  Assert.equal(
    textCall.x,
    math.floor((BANNER_WIDTH - 4 - text.width) / 2) + BANNER_TEXT_INSET,
    "the title is centered by the source X formula at local y8"
  )
end

function T.the_title_uses_the_style_palette_roles()
  local graphics = FakeGraphics.new()
  local text = recordingText(96)
  local renderer = bannerRenderer("area-name text roles", graphics, text)
  renderer:draw({ title = "NEW BARK TOWN", styleKey = 1, scrollOffset = 0 }, referenceFrame(0, 0))

  local palette = assert(text.calls[1] and text.calls[1].palette, "the title is painted through the style palette")
  Assert.deepEqual(palette.foreground, STYLE_PALETTE.foreground, "the style foreground role is forwarded")
  Assert.deepEqual(palette.shadow, STYLE_PALETTE.shadow, "the style shadow role is forwarded")
  Assert.deepEqual(palette.background, STYLE_PALETTE.background, "the style background role is forwarded")
end

function T.the_overlay_anchors_to_the_reference_frame_not_the_host_origin()
  local graphics = FakeGraphics.new()
  local renderer = bannerRenderer("MAIN-frame anchoring", graphics, recordingText(80))
  local frame = referenceFrame(41, 27)
  local placement = assert(PixelScale.placeFixed(frame, CANONICAL_WIDTH, CANONICAL_HEIGHT))
  renderer:draw({ title = "ROUTE 29", styleKey = 2, scrollOffset = 0 }, frame)

  Assert.deepEqual(
    graphics.transforms[1],
    { "translate", placement.origin.x, placement.origin.y },
    "the banner anchors at the resolved MAIN origin, not the host origin"
  )
  Assert.deepEqual(
    graphics.transforms[2],
    { "scale", placement.scale, placement.scale },
    "the banner applies the resolved MAIN scale exactly once"
  )
end

-- The field draw owner orders the banner above the world and warp fade and
-- below the script-owned cover; the avatar host and battlefield are idle here,
-- so the only draws are the world, the warp fade, the banner, and the cover.
local function drawableState(order, bannerStatus)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    touch = false,
    role = "world",
  })
  local worldViewport = { x = 0, y = 0, width = 512, height = 384 }
  local resources = {
    drawMart = function() end,
    drawMapNameBanner = function(_, banner)
      if banner ~= nil and banner:status() ~= nil then
        order[#order + 1] = "banner"
      end
    end,
    renderer = {
      draw = function()
        order[#order + 1] = "world"
      end,
    },
    dialogueRenderer = { draw = function() end },
    signpostRenderer = { draw = function() end },
    startMenuRenderer = { draw = function() end },
    trainerCardRenderer = { draw = function() end },
    menuRenderer = { draw = function() end },
    fieldEntranceIndicatorRenderer = {
      drawItems = function()
        return {}
      end,
    },
    fieldEmoteRenderer = {
      drawItems = function()
        return {}
      end,
    },
  }
  local runtime = {
    errorText = nil,
    uiManifest = { dialogueFrames = {} },
    runtimeMap = {
      mapId = 33,
      mapSymbol = "MAP_ROUTE_29",
      coverage = {
        worldParts = function()
          return {}
        end,
      },
      renderEnvironment = {},
      sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
    },
    player = { fieldX = 0, fieldZ = 0, worldY = 0, surfaceId = 0, facing = "east", motion = "idle" },
    session = {
      renderAlpha = function()
        return 0.5
      end,
    },
    overworld = {
      isPresent = function()
        return true
      end,
    },
    destinationWorldPresentable = function()
      return true
    end,
    acknowledgeDestinationPresentation = function() end,
    viewport = {
      width = 512,
      height = 384,
      worldViewport = worldViewport,
      referenceFrame = worldViewport,
    },
    camera = { zoom = 1 },
    transition = {
      fadeAlpha = 0.5,
      presentationStatus = function()
        order[#order + 1] = "warpFade"
        return { overlay = { r = 0, g = 0, b = 0, a = 0.5 } }
      end,
    },
    screenFade = {
      presentationOverlay = function()
        order[#order + 1] = "scriptCover"
        return { r = 0, g = 0, b = 0, a = 0.5, screenScope = "both" }
      end,
    },
    screenTopology = topology,
    fieldPixelScale = {
      resolvedScale = function()
        return 3
      end,
    },
    fieldEntranceIndicator = {
      status = function()
        return { visible = false }
      end,
    },
    fieldTerrainEffectController = {
      status = function()
        return { instances = {} }
      end,
    },
    dialogue = {
      isModal = function()
        return false
      end,
    },
    scripts = { dialogueHost = {
      yesNoPresentation = function()
        return nil
      end,
    } },
    signpost = {
      isModal = function()
        return false
      end,
    },
    applicationHost = {
      isActive = function()
        return false
      end,
      status = function()
        return { fadeAlpha = 0 }
      end,
    },
    pcApplicationHost = {
      isActive = function()
        return false
      end,
    },
    menuHost = {
      presentation = function()
        return nil
      end,
    },
    yesNoHost = {
      isModal = function()
        return false
      end,
      layoutFor = function()
        error("no choice is active in this fixture", 0)
      end,
    },
    contextChoiceProvider = {
      status = function()
        return nil
      end,
    },
    contextChoicePresentation = function()
      return nil
    end,
    resizePresentation = function() end,
    mapNameBanner = {
      status = function()
        return bannerStatus
      end,
    },
  }
  return setmetatable({
    _actorDesiredReady = true,
    runtime = runtime,
    topologyProvider = function()
      return topology
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    presentationResources = resources,
    actorPresentation = {
      drawItems = function()
        return {}
      end,
      records = function()
        return {}
      end,
    },
  }, FieldState)
end

local function render(scope, order, bannerStatus)
  local state = drawableState(order, bannerStatus)
  local canvas = scope:own(love.graphics.newCanvas(512, 384))
  love.graphics.setCanvas(canvas)
  local ok, err = pcall(function()
    state:draw()
  end)
  love.graphics.setCanvas()
  Assert.isTrue(ok, "field draw must not throw: " .. tostring(err))
end

function T.the_field_draws_the_banner_above_the_world_and_below_the_script_cover(scope)
  local order = {}
  render(scope, order, { title = "ROUTE 29", styleKey = 2, scrollOffset = 12 })
  Assert.deepEqual(
    order,
    { "world", "warpFade", "banner", "scriptCover" },
    "the banner draws after the world and warp fade and before the script cover"
  )

  local hidden = {}
  render(scope, hidden, nil)
  Assert.deepEqual(hidden, { "world", "warpFade", "scriptCover" }, "a hidden banner paints nothing")
end

-- The banner skin must survive whatever graphics color the preceding warp
-- fade left behind: the renderer neutralizes the inherited tint inside its
-- own logical scope, so the selected art always draws fully opaque white
-- while the caller color is restored on return.
function T.the_skin_draws_at_full_white_tint_under_a_hostile_inherited_color()
  for _, tint in ipairs({ { 0, 0, 0, 0.5 }, { 1, 1, 1, 0.25 } }) do
    local label = string.format("tint (%.2f,%.2f,%.2f,%.2f)", tint[1], tint[2], tint[3], tint[4])
    local graphics = FakeGraphics.new()
    graphics.setColor(tint[1], tint[2], tint[3], tint[4])
    local text = recordingText(80)
    local renderer, skin = bannerRenderer("area-name tint scope", graphics, text)
    renderer:draw({ title = "ROUTE 29", styleKey = 2, scrollOffset = 38 }, referenceFrame(40, 30))

    local skinDraw = assert(graphics.draws[1], "the banner skin is drawn under " .. label)
    Assert.isTrue(skinDraw.image == skin, "the selected banner skin is drawn under " .. label)
    Assert.deepEqual(
      { skinDraw.color[1], skinDraw.color[2], skinDraw.color[3], skinDraw.color[4] },
      { 1, 1, 1, 1 },
      "the banner skin ignores the inherited warp fade color under " .. label
    )
    Assert.equal(skinDraw.x, 0, "the skin keeps logical x0 under " .. label)
    Assert.equal(skinDraw.y, -38, "the skin keeps its scroll displacement under " .. label)
    local r, g, b, a = graphics.getColor()
    Assert.deepEqual({ r, g, b, a }, tint, "the caller graphics color is restored after " .. label)
  end
end

-- A two-style banner lease fixture: source-like RGB-only role palettes with
-- deliberately nonzero background bytes, and one small skin PNG per style.
-- The cache double answers only the banner image paths the lease resolves.
local function bannerLeaseFixture()
  local function solidPng(r, g, b)
    local cells = {}
    for _ = 1, 64 do
      cells[#cells + 1] = string.char(r, g, b, 255)
    end
    return PngWriter.encode(8, 8, table.concat(cells))
  end
  local manifest = {
    bannerStyles = { [4] = "banner-style-4", [7] = "banner-style-7" },
    assets = {
      ["banner-style-4"] = { image = "banner/style-4.png" },
      ["banner-style-7"] = { image = "banner/style-7.png" },
    },
    bannerTextPalettes = {
      [4] = {
        foreground = { r = 16, g = 32, b = 48 },
        shadow = { r = 64, g = 80, b = 96 },
        background = { r = 96, g = 112, b = 128 },
      },
      [7] = {
        foreground = { r = 200, g = 210, b = 220 },
        shadow = { r = 30, g = 40, b = 50 },
        background = { r = 70, g = 80, b = 90 },
      },
    },
  }
  local cacheFs = {
    files = {
      ["banner/style-4.png"] = solidPng(10, 20, 30),
      ["banner/style-7.png"] = solidPng(40, 50, 60),
    },
    read = function(self, path)
      return self.files[path]
    end,
  }
  return manifest, cacheFs
end

-- The shared fixture mask atlas carries only foreground and shadow classes,
-- so this 16x16 replacement splits the first glyph cell into a foreground
-- half and a background (blue mask channel) half while keeping the second
-- glyph an all-shadow cell. A background-class texel over textured art is
-- the only probe that can catch an opaque glyph backing.
local function maskBytesWithBackgroundClass()
  local cells = {}
  for _ = 1, 16 do
    for x = 1, 16 do
      if x <= 4 then
        cells[#cells + 1] = string.char(255, 0, 0, 255)
      elseif x <= 8 then
        cells[#cells + 1] = string.char(0, 0, 255, 255)
      else
        cells[#cells + 1] = string.char(0, 255, 0, 255)
      end
    end
  end
  return PngWriter.encode(16, 16, table.concat(cells))
end

-- Deliberately nonuniform skin stand-in: a two-color checkerboard whose
-- expected color at any pixel is computed from its coordinates, so no
-- uniform fill can conceal an opaque glyph backing.
local function checkerColor(x, y)
  if (x + y) % 2 == 0 then
    return 200 / 255, 10 / 255, 10 / 255
  end
  return 10 / 255, 200 / 255, 10 / 255
end

-- Glyph text recolored through the real palette shader must leave the skin
-- visible wherever the mask names the background class, while foreground
-- and shadow classes paint their exact style roles. The palette under test
-- is the lease-local view resolved by the production banner lease, never a
-- hand-built alpha table, so an RGB-only generated palette that defaults
-- to opaque would paint a solid block over the checkerboard.
function T.glyph_background_class_leaves_textured_skin_visible_through_the_real_shader(scope)
  local lg = love.graphics
  local manifest, cacheFs = bannerLeaseFixture()
  local resources = setmetatable({ cacheFs = cacheFs, fieldEntryManifest = manifest }, FieldPresentationResources)
  local viewPalette = resources:_bannerSkinFor(4).palette

  local fontCache = FieldDialogueFixture.cacheWithFont()
  fontCache:write(FieldFontCache.maskAtlasPath(0), maskBytesWithBackgroundClass())
  local text = scope:own(FieldTextRenderer.new({ cacheFs = fontCache }))

  local canvas = scope:own(lg.newCanvas(32, 32))
  local backdropData = love.image.newImageData(32, 32)
  for y = 0, 31 do
    for x = 0, 31 do
      local r, g, b = checkerColor(x, y)
      backdropData:setPixel(x, y, r, g, b, 1)
    end
  end
  local backdropImage = scope:own(lg.newImage(backdropData))
  backdropImage:setFilter("nearest", "nearest")

  lg.setColor(1, 1, 1, 1)
  lg.setBlendMode("alpha")
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  local drawOk, drawErr = pcall(function()
    lg.draw(backdropImage, 0, 0)
    text:drawTextWithPalette("AB", 4, 4, viewPalette)
  end)
  lg.setCanvas()
  local pixels = drawOk and scope:own(canvas:newImageData()) or nil
  local disposeOk, disposeErr = pcall(function()
    resources:dispose()
  end)
  if not drawOk then
    error(drawErr, 0)
  end
  Assert.isTrue(disposeOk, "the banner lease cleans up after the compositing draw: " .. tostring(disposeErr))
  Assert.notNil(pixels, "the compositing readback is available")
  assert(pixels, "the compositing readback is available")

  local function assertPixel(x, y, er, eg, eb, ea, label)
    local r, g, b, a = pixels:getPixel(x, y)
    local got = {
      math.floor(r * 255 + 0.5),
      math.floor(g * 255 + 0.5),
      math.floor(b * 255 + 0.5),
      math.floor(a * 255 + 0.5),
    }
    local close = math.abs(got[1] - er) <= 1
      and math.abs(got[2] - eg) <= 1
      and math.abs(got[3] - eb) <= 1
      and math.abs(got[4] - ea) <= 1
    Assert.isTrue(
      close,
      label
        .. string.format(": expected (%d,%d,%d,%d) got (%d,%d,%d,%d)", er, eg, eb, ea, got[1], got[2], got[3], got[4])
    )
  end

  assertPixel(5, 6, 16, 32, 48, 255, "a foreground-class texel paints the style foreground")
  assertPixel(11, 6, 64, 80, 96, 255, "a shadow-class texel paints the style shadow")
  assertPixel(30, 30, 200, 10, 10, 255, "an untouched texel keeps the skin color")
  local br, bg, bb = checkerColor(9, 6)
  assertPixel(
    9,
    6,
    math.floor(br * 255 + 0.5),
    math.floor(bg * 255 + 0.5),
    math.floor(bb * 255 + 0.5),
    255,
    "a background-class texel leaves the skin visible"
  )
  Assert.isNil(manifest.bannerTextPalettes[4].background.a, "the generated palette carries no alpha of its own")
  Assert.equal(viewPalette.background.a, 0, "the lease-local background role requests normalized zero alpha")
end

-- The banner lease borrows the immutable generated palette for a
-- presentation-only transparent-background view, retains one image at a
-- time, and keeps the last valid skin when a replacement fails: a missing
-- PNG fails before acquiring anything, and an image that fails filtering
-- after creation is freed exactly once without publishing a half lease.
function T.a_failed_style_replacement_keeps_the_last_valid_skin_and_lease_palette(_scope)
  local manifest, cacheFs = bannerLeaseFixture()
  local style7png = cacheFs.files["banner/style-7.png"]
  local resources = setmetatable({ cacheFs = cacheFs, fieldEntryManifest = manifest }, FieldPresentationResources)

  local created = {}
  local failSetFilter = false
  local realNewImage = love.graphics.newImage
  love.graphics.newImage = function(_fileData)
    local image = { released = false, releaseCount = 0, filters = {} }
    image.setFilter = function(_, min, mag)
      if failSetFilter then
        error("injected banner setFilter failure", 0)
      end
      image.filters[#image.filters + 1] = { min = min, mag = mag }
    end
    image.release = function()
      image.released = true
      image.releaseCount = image.releaseCount + 1
    end
    created[#created + 1] = image
    return image
  end

  local ok, err = pcall(function()
    local skinA = resources:_bannerSkinFor(4)
    Assert.equal(#created, 1, "the first lease acquires exactly one image")
    Assert.deepEqual(
      skinA.palette.foreground,
      manifest.bannerTextPalettes[4].foreground,
      "the lease keeps the source foreground role"
    )
    Assert.deepEqual(
      skinA.palette.shadow,
      manifest.bannerTextPalettes[4].shadow,
      "the lease keeps the source shadow role"
    )
    Assert.equal(skinA.palette.background.r, 96, "the lease keeps the source background red byte")
    Assert.equal(skinA.palette.background.g, 112, "the lease keeps the source background green byte")
    Assert.equal(skinA.palette.background.b, 128, "the lease keeps the source background blue byte")
    Assert.equal(skinA.palette.background.a, 0, "the lease-local background role requests normalized zero alpha")
    Assert.isNil(manifest.bannerTextPalettes[4].background.a, "presentation alpha never persists into the manifest")
    Assert.isTrue(resources:_bannerSkinFor(4) == skinA, "a repeated style draw reuses the retained lease")
    Assert.equal(#created, 1, "a repeated style draw allocates nothing")

    cacheFs.files["banner/style-7.png"] = nil
    Assert.throws(function()
      resources:_bannerSkinFor(7)
    end, "a style with missing art fails loudly")
    Assert.isTrue(resources._bannerSkin == skinA, "a failed lease keeps the last valid skin")
    Assert.equal(resources._bannerSkinKey, 4, "a failed lease keeps the last valid style key")
    Assert.equal(#created, 1, "a failed lease acquires no image")

    cacheFs.files["banner/style-7.png"] = style7png
    failSetFilter = true
    Assert.throws(function()
      resources:_bannerSkinFor(7)
    end, "a filter failure on the replacement fails loudly")
    failSetFilter = false
    Assert.equal(#created, 2, "the failed replacement acquired exactly one image")
    Assert.equal(created[2].releaseCount, 1, "a failed replacement frees its own image exactly once")
    Assert.isTrue(resources._bannerSkin == skinA, "a filter failure keeps the last valid skin")
    Assert.equal(resources._bannerSkinKey, 4, "a filter failure keeps the last valid style key")

    local skinB = resources:_bannerSkinFor(7)
    Assert.equal(#created, 3, "the retry acquires its replacement image")
    Assert.equal(created[1].releaseCount, 1, "a successful replacement releases the outgoing skin exactly once")
    Assert.isTrue(resources._bannerSkin == skinB, "the retry publishes the replacement skin")
    Assert.equal(resources._bannerSkinKey, 7, "the retry publishes the replacement style key")
  end)
  love.graphics.newImage = realNewImage
  local disposeOk, disposeErr = pcall(function()
    resources:dispose()
  end)
  if not ok then
    error(err, 0)
  end
  Assert.isTrue(disposeOk, "dispose cleans up the retained lease: " .. tostring(disposeErr))
  Assert.equal(created[3].releaseCount, 1, "dispose releases the retained skin exactly once")
  Assert.isNil(resources._bannerSkin, "dispose clears the lease")
end

return GraphicsSmoke.suite(T)
