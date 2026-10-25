-- Native placement and composition of the time-aware area preview: the selected
-- 256x192 cache image lands at the canonical MAIN reference frame through the
-- shared PixelScale/LogicalSurface primitives, the black brightness cover is
-- painted above it, and the field composes world -> preview -> banner -> script
-- cover. A committed but not-yet-presentable destination still shows the
-- preview (or its black fade) instead of exposing the world.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldState = require("game.hgss.src.field.FieldState")
local PixelScale = require("libs.ui.src.PixelScale")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

local T = {}

-- The area-preview renderer is the module under test, so its absence must fail
-- as the missing behavior, not as a suite load error.
local function rendererModule(behavior)
  local ok, moduleOrError = pcall(require, "game.hgss.src.field.FieldAreaPreviewRenderer")
  Assert.isTrue(ok, behavior .. " is missing: the area-preview renderer is unavailable")
  local module = moduleOrError
  Assert.isTrue(type(module.new) == "function", behavior .. " is missing: the renderer exposes no constructor")
  Assert.isTrue(type(module.draw) == "function", behavior .. " is missing: the renderer exposes no draw operation")
  return module
end

local function referenceFrame(x, y)
  return { x = x, y = y, width = CANONICAL_WIDTH, height = CANONICAL_HEIGHT }
end

-- Merged draw order over the fake graphics namespace so the suite can prove the
-- black cover sits above the selected image.
local function orderedGraphics()
  local graphics = FakeGraphics.new()
  local order = {}
  local draw = graphics.draw
  local rectangle = graphics.rectangle
  graphics.draw = function(image, ...)
    order[#order + 1] = "image"
    return draw(image, ...)
  end
  graphics.rectangle = function(mode, ...)
    order[#order + 1] = "cover"
    return rectangle(mode, ...)
  end
  return graphics, order
end

---@return table instance, table calls
local function previewRenderer(behavior, graphics, images)
  local module = rendererModule(behavior)
  local calls = { keys = {} }
  local instance = module.new({
    graphics = graphics,
    imageFor = function(imageKey)
      calls.keys[#calls.keys + 1] = imageKey
      return images[imageKey]
    end,
  })
  return instance, calls
end

function T.the_selected_image_and_black_cover_land_at_the_canonical_geometry()
  local graphics, order = orderedGraphics()
  local image = graphics.newImage()
  local instance, calls = previewRenderer("area-preview presentation", graphics, { ["preview.ilex.evening"] = image })
  instance:draw(
    { imageKey = "preview.ilex.evening", imageAlpha = 1, blackAlpha = 1, timeSlot = 2, stage = "fade_in" },
    referenceFrame(40, 30)
  )

  -- One logical scope only: a single translate to the canonical origin and one
  -- scale. A second transform would scale the borrowed surface twice.
  Assert.equal(#graphics.transforms, 2, "the preview composes exactly one logical transform")
  Assert.equal(graphics.transforms[1][1], "translate", "the preview anchors with one origin translate")
  Assert.equal(graphics.transforms[2][1], "scale", "the preview applies one logical scale")

  local imageDraw = assert(graphics.draws[1], "the selected preview image is drawn")
  Assert.equal(imageDraw.image, image, "the published image key is drawn")
  Assert.equal(imageDraw.x, 0, "the preview image sits at logical x0")
  Assert.equal(imageDraw.y, 0, "the preview image sits at logical y0")
  Assert.deepEqual(imageDraw.color, { 1, 1, 1, 1 }, "the image draws at the status image alpha")

  local cover = assert(graphics.rectangles[1], "the black brightness cover is drawn")
  Assert.equal(cover.mode, "fill", "the cover is a filled rectangle")
  Assert.equal(cover.x, 0, "the cover spans the full logical surface")
  Assert.equal(cover.y, 0, "the cover spans the full logical surface")
  Assert.equal(cover.w, CANONICAL_WIDTH, "the cover spans the full reference width")
  Assert.equal(cover.h, CANONICAL_HEIGHT, "the cover spans the full reference height")
  Assert.deepEqual(cover.color, { 0, 0, 0, 1 }, "the cover draws at the status black alpha")
  Assert.deepEqual(order, { "image", "cover" }, "the black cover paints above the selected image")
  Assert.deepEqual(calls.keys, { "preview.ilex.evening" }, "the renderer requests exactly the published image key")
  -- The renderer is a pure draw leaf: it materializes no GPU image of its own,
  -- so the one selected bitmap is leased exactly once by the resource owner.
  Assert.equal(#graphics.images, 1, "the preview renderer uploads no second GPU image")
end

function T.the_status_alphas_drive_the_cover_and_the_image_reveal()
  local graphics, order = orderedGraphics()
  local image = graphics.newImage()
  local instance = (previewRenderer("area-preview alpha", graphics, { ["preview.union.day"] = image }))
  instance:draw(
    { imageKey = "preview.union.day", imageAlpha = 0.5, blackAlpha = 0.25, timeSlot = 1, stage = "blend_out" },
    referenceFrame(0, 0)
  )
  Assert.deepEqual(assert(graphics.draws[1]).color, { 1, 1, 1, 0.5 }, "the image fades toward the committed world")
  Assert.deepEqual(assert(graphics.rectangles[1]).color, { 0, 0, 0, 0.25 }, "the cover thins as the image shows")
  Assert.deepEqual(order, { "image", "cover" }, "the cover stays above the image while both are visible")

  local hidden, hiddenOrder = orderedGraphics()
  local hiddenInstance = (previewRenderer("area-preview hold", hidden, { ["preview.union.day"] = hidden.newImage() }))
  hiddenInstance:draw(
    { imageKey = "preview.union.day", imageAlpha = 1, blackAlpha = 0, timeSlot = 1, stage = "hold" },
    referenceFrame(0, 0)
  )
  Assert.deepEqual(hidden.rectangles, {}, "a fully cleared cover paints no black rectangle")
  Assert.deepEqual(hiddenOrder, { "image" }, "a cleared cover leaves only the opaque image")
end

-- The renderer borrows the lease owner's already-validated selected image. It
-- must never swallow a cache-integrity failure and paint a substitute: a
-- missing generated current PNG reaches the field as a terminal error with no
-- substitute art, and the already committed world stays authoritative.
function T.a_missing_selected_image_is_a_terminal_error_not_a_silent_omission()
  local graphics, order = orderedGraphics()
  local instance = rendererModule("area-preview missing image").new({
    graphics = graphics,
    imageFor = function(imageKey)
      error("missing generated preview image " .. imageKey, 0)
    end,
  })
  local ok, err = pcall(function()
    instance:draw(
      { imageKey = "preview.ilex.night", imageAlpha = 1, blackAlpha = 1, timeSlot = 3, stage = "fade_in" },
      referenceFrame(41, 27)
    )
  end)
  Assert.isFalse(ok, "a missing generated preview image must not be silently omitted")
  Assert.isTrue(
    tostring(err):find("preview.ilex.night", 1, true) ~= nil,
    "the terminal cache-integrity error names the missing generated image"
  )
  Assert.deepEqual(graphics.draws, {}, "no substitute image is painted for a missing generated preview")
  Assert.deepEqual(order, {}, "no substitute art is composed for a missing generated preview")
end

function T.the_preview_anchors_to_the_reference_frame_not_the_host_origin()
  local graphics = orderedGraphics()
  local instance = (previewRenderer("area-preview anchoring", graphics, { ["preview.x"] = graphics.newImage() }))
  local frame = referenceFrame(41, 27)
  local placement = assert(PixelScale.placeFixed(frame, CANONICAL_WIDTH, CANONICAL_HEIGHT))
  instance:draw({ imageKey = "preview.x", imageAlpha = 1, blackAlpha = 0.5, timeSlot = 0, stage = "fade_in" }, frame)
  Assert.deepEqual(
    graphics.transforms[1],
    { "translate", placement.origin.x, placement.origin.y },
    "the preview anchors at the resolved MAIN origin, not the host origin"
  )
  Assert.deepEqual(
    graphics.transforms[2],
    { "scale", placement.scale, placement.scale },
    "the preview applies the resolved MAIN scale exactly once"
  )
end

-- The field draw owner orders the preview above the world and below the banner
-- and script cover; the fade is settled (fadeAlpha 0) so the ordinary warp fade
-- paints nothing and the only draws are the world, preview, banner, and cover.
-- The `ui` override selects covered script-owned surfaces (`dialogue`,
-- `choice`) and whether the banner is eligible (`banner = false` idles it).
local function drawableState(order, previewStatus, presentable, ui)
  ui = ui or {}
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    touch = false,
    role = "world",
  })
  local worldViewport = { x = 0, y = 0, width = 512, height = 384 }
  local resources = {
    drawMart = function() end,
    drawAreaPreview = function(_, preview)
      if preview ~= nil then
        order[#order + 1] = "preview"
      end
    end,
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
    dialogueRenderer = {
      draw = function()
        order[#order + 1] = "dialogue"
      end,
    },
    yesNoRenderer = {
      draw = function()
        order[#order + 1] = "choice"
      end,
    },
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
    uiManifest = {
      dialogueFrames = {
        continueCursor = { placement = { x = 240, y = 168, width = 16, height = 16 } },
      },
    },
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
      return presentable
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
      fadeAlpha = 0,
      -- The field gates the status read on cheap owner state, so an active
      -- preview is declared exactly like the real transition: non-nil only
      -- while a preview owns the presentation.
      preview = previewStatus,
      presentationStatus = function()
        return { preview = previewStatus }
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
        return ui.dialogue == true
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
        return ui.choice == true
      end,
      presentation = function()
        return { status = { prompt = "covered choice" }, layout = { rows = 2 } }
      end,
      layoutFor = function()
        error("no choice is active in this fixture", 0)
      end,
    },
    contextChoiceProvider = {
      status = function()
        return nil
      end,
      isActive = function()
        return false
      end,
    },
    contextChoicePresentation = function()
      return nil
    end,
    resizePresentation = function() end,
    mapNameBanner = {
      status = function()
        if ui.banner == false then
          return nil
        end
        return { title = "ROUTE 29", styleKey = 2, scrollOffset = 12 }
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

local function render(scope, order, previewStatus, presentable, ui)
  local state = drawableState(order, previewStatus, presentable, ui)
  local canvas = scope:own(love.graphics.newCanvas(512, 384))
  love.graphics.setCanvas(canvas)
  local ok, err = pcall(function()
    state:draw()
  end)
  love.graphics.setCanvas()
  Assert.isTrue(ok, "field draw must not throw: " .. tostring(err))
end

local function visiblePreview()
  return { imageKey = "preview.x", imageAlpha = 1, blackAlpha = 0, timeSlot = 1, stage = "hold" }
end

function T.the_field_draws_the_preview_above_the_world_below_the_banner_and_cover(scope)
  local order = {}
  render(scope, order, visiblePreview(), true)
  Assert.deepEqual(
    order,
    { "world", "preview", "banner", "scriptCover" },
    "the preview draws above the world, below the banner, and below the script cover"
  )

  local hidden = {}
  render(scope, hidden, nil, true)
  Assert.deepEqual(hidden, { "world", "banner", "scriptCover" }, "a hidden preview paints nothing")
end

function T.a_hidden_preview_keeps_the_banner_and_covered_script_ui_above_it(scope)
  local order = {}
  render(
    scope,
    order,
    { imageKey = "preview.x", imageAlpha = 1, blackAlpha = 1, timeSlot = 1, stage = "fade_in" },
    false,
    { dialogue = true, choice = true }
  )
  Assert.deepEqual(
    order,
    { "preview", "banner", "dialogue", "choice", "scriptCover" },
    "the banner and covered script-owned surfaces paint above the preview while the world stays hidden"
  )
end

function T.a_hidden_destination_without_a_preview_still_shows_the_banner(scope)
  local order = {}
  render(scope, order, nil, false)
  Assert.deepEqual(
    order,
    { "banner", "scriptCover" },
    "the banner is never swallowed by the world gate, even with no preview active"
  )

  local idle = {}
  render(scope, idle, { imageKey = "preview.x", imageAlpha = 1, blackAlpha = 0, timeSlot = 1, stage = "hold" }, false, {
    banner = false,
  })
  Assert.deepEqual(idle, { "preview", "scriptCover" }, "an ineligible banner paints nothing over the covered preview")
end

function T.a_presentable_blend_composites_the_preview_over_the_drawn_world(scope)
  local order = {}
  render(
    scope,
    order,
    { imageKey = "preview.x", imageAlpha = 0.5, blackAlpha = 0, timeSlot = 1, stage = "blend_out" },
    true,
    { dialogue = true }
  )
  Assert.deepEqual(
    order,
    { "world", "preview", "banner", "dialogue", "scriptCover" },
    "the translucent reveal composites over the drawn destination, below the banner and script surfaces"
  )
end

-- The reveal half of the entry contract at the pixel level: the production
-- preview renderer paints its selected image with the status alpha, so a
-- half-transparent image over a painted world leaves a blended readback
-- pixel that is neither the world nor the image color alone.
function T.a_translucent_preview_reveals_the_drawn_world_beneath_it(scope)
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(CANONICAL_WIDTH, CANONICAL_HEIGHT))
  local data = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  data:mapPixel(function()
    return 1, 0, 0, 1
  end)
  local image = scope:own(lg.newImage(data))
  local module = rendererModule("area-preview presentation")
  local instance = module.new({
    graphics = lg,
    imageFor = function()
      return image
    end,
  })
  lg.setCanvas(canvas)
  local beforeRed, beforeGreen, beforeBlue, beforeAlpha = lg.getColor()
  lg.setColor(0, 0, 1, 1)
  lg.rectangle("fill", 0, 0, CANONICAL_WIDTH, CANONICAL_HEIGHT)
  lg.setColor(beforeRed, beforeGreen, beforeBlue, beforeAlpha)
  instance:draw(
    { imageKey = "preview.x", imageAlpha = 0.5, blackAlpha = 0, timeSlot = 1, stage = "blend_out" },
    referenceFrame(0, 0)
  )
  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local red, green, blue, alpha = pixels:getPixel(128, 96)
  Assert.near(red, 0.5, 0.02, "the blended pixel carries the half-transparent image red")
  Assert.near(green, 0, 0.02, "the blended pixel carries no image green")
  Assert.near(blue, 0.5, 0.02, "the blended pixel still carries the drawn world blue")
  Assert.near(alpha, 1, 0.02, "the blended pixel stays opaque")
end

return GraphicsSmoke.suite(T)
