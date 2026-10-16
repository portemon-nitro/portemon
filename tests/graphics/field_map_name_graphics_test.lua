-- Native placement, geometry, and composition order of the transient top-left
-- area-name banner: the source 136x32 skin lands at logical x0 with the scroll
-- displacement as a vertical offset, the centered title is painted through the
-- style's own palette path, the whole overlay anchors to the canonical 256x192
-- MAIN reference frame rather than the host origin, and the field composes it
-- after the world and warp fade and before the script-owned cover.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
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
    fieldEntranceIndicatorRenderer = { drawItems = function() return {} end },
    fieldEmoteRenderer = { drawItems = function() return {} end },
  }
  local runtime = {
    errorText = nil,
    uiManifest = { dialogueFrames = {} },
    runtimeMap = {
      mapId = 33,
      mapSymbol = "MAP_ROUTE_29",
      coverage = { worldParts = function() return {} end },
      renderEnvironment = {},
      sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
    },
    player = { fieldX = 0, fieldZ = 0, worldY = 0, surfaceId = 0, facing = "east", motion = "idle" },
    session = { renderAlpha = function() return 0.5 end },
    overworld = { isPresent = function() return true end },
    destinationWorldPresentable = function() return true end,
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
        return { r = 0, g = 0, b = 0, a = 0.5 }
      end,
    },
    screenTopology = topology,
    fieldPixelScale = {
      resolvedScale = function() return 3 end,
    },
    fieldEntranceIndicator = { status = function() return { visible = false } end },
    fieldTerrainEffectController = { status = function() return { instances = {} } end },
    dialogue = { isModal = function() return false end },
    scripts = { dialogueHost = { yesNoPresentation = function() return nil end } },
    signpost = { isModal = function() return false end },
    applicationHost = { isActive = function() return false end, status = function() return { fadeAlpha = 0 } end },
    pcApplicationHost = { isActive = function() return false end },
    menuHost = { presentation = function() return nil end },
    yesNoHost = {
      isModal = function() return false end,
      layoutFor = function() error("no choice is active in this fixture", 0) end,
    },
    contextChoiceProvider = { status = function() return nil end },
    contextChoicePresentation = function() return nil end,
    resizePresentation = function() end,
    mapNameBanner = { status = function() return bannerStatus end },
  }
  return setmetatable({
    runtime = runtime,
    topologyProvider = function() return topology end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    presentationResources = resources,
    actorPresentation = {
      drawItems = function() return {} end,
      records = function() return {} end,
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

return GraphicsSmoke.suite(T)
