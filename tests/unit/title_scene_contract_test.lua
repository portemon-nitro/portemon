-- Lower-level title scene contracts behind the frozen acceptance scenarios:
-- source projection conversion and clip normalization, multi-waypoint
-- axis stepping with wrap-around, and the built-in lighting fallback plus
-- bundle passthrough. Synthetic scenes only; no ROM or GPU.

local Assert = require("tests.support.Assert")
local Matrix4 = require("libs.math.src.Matrix4")
local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")

local HALF_ANGLE_INDEX = 0xB60
local SOURCE_FULL_FOV = 2 * (HALF_ANGLE_INDEX / 65536) * (2 * math.pi)

local function stubActor()
  local actor = { updates = 0 }
  function actor:updateFixed()
    self.updates = self.updates + 1
  end
  function actor:evaluatePose() end
  function actor:drawItems()
    return {}
  end
  return actor
end

local function stubTextRenderer(drawn)
  return {
    fontDef = { lineHeight = 16 },
    textWidth = function()
      return 120
    end,
    drawLineWithPalette = function(_, _, _, _, palette)
      drawn[#drawn + 1] = { palette = palette }
    end,
  }
end

local function stubScene(bundle, drawn)
  local legend, sparkle = stubActor(), stubActor()
  return setmetatable({
    versionId = "soulsilver",
    bundle = bundle,
    tick = 0,
    promptFrame = 0,
    graphics = {},
    legend = legend,
    sparkle = sparkle,
    textRenderer = stubTextRenderer(drawn or {}),
    layout = { prompt = { x = 100, y = 300, width = 300, height = 30 } },
    disposed = false,
  }, HgssTitleScene)
end

local function twoWaypointBundle()
  return {
    timeline = {
      camera = {
        start = { position = { 0, 0, 0 }, target = { 0, 0, -10 } },
        target = { 0, 0, -10 },
        endPosition = { 0, 0, 0 },
        points = {
          { position = { 10, 0, 0 }, durationSeconds = 1 },
          { position = { 10, 20, 0 }, durationSeconds = 1 },
        },
        movement = { unitsPerFrame = 5, tolerance = 1, waitFramesPerSecond = 30 },
      },
    },
    prompt = {
      text = "TOUCH TO START",
      alignment = "center",
      tokens = {},
      color = {
        foreground = 2,
        shadow = 2,
        background = 0,
        foregroundRgb = { 0, 28 / 31, 1 },
        shadowRgb = { 0, 28 / 31, 1 },
      },
      flash = {
        initialDelayFrames = 30,
        initialPhaseFrame = 30,
        cycleFrames = 45,
        visibleFrames = 30,
        hiddenFrames = 15,
      },
    },
  }
end

local function fovOf(projection)
  return 2 * math.atan(1 / projection[6])
end

local function worldView(eye, target)
  local unit = 1 / 16
  return Matrix4.lookAt(
    { eye[1] * unit, eye[2] * unit, eye[3] * unit },
    { target[1] * unit, target[2] * unit, target[3] * unit },
    { 0, 1, 0 }
  )
end

local function eyeOf(scene)
  return { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] }
end

local T = {}

function T.title_projection_converts_the_source_half_angle_with_stable_clipping()
  local scene = stubScene(twoWaypointBundle())
  local camera = scene:_camera()
  Assert.near(fovOf(camera.projection()), SOURCE_FULL_FOV, 0.02, "projection keeps the sourced vertical field")
  Assert.near(SOURCE_FULL_FOV, 32 * math.pi / 180, 0.5, "the sourced field is about 32 degrees")
  Assert.equal(camera.far, 5000, "the far plane keeps the camera script visible")
  local projection = camera.projection()
  Assert.near(projection[11], (5000 + 1) / (1 - 5000), 1e-9, "projection normalizes to a positive near plane")
  Assert.near(projection[15], (2 * 5000 * 1) / (1 - 5000), 1e-6, "projection keeps the near/far depth pair")
  local wide = scene:_camera().projection()
  Assert.near(fovOf(wide), SOURCE_FULL_FOV, 1e-9, "host shape never changes the vertical field")
  Assert.near(wide[1], wide[6] / (4 / 3), 1e-9, "the projection keeps the fixed sourced 4:3 frame")
  local target = scene.bundle.timeline.camera.target
  local function distance(eye)
    local dx, dy, dz = eye[1] - target[1], eye[2] - target[2], eye[3] - target[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  Assert.isTrue(distance(eyeOf(scene)) < camera.far, "the opening pose sits inside the clip range")
  for _, point in ipairs(scene.bundle.timeline.camera.points) do
    Assert.isTrue(distance(point.position) < camera.far, "every waypoint sits inside the clip range")
  end
end

function T.title_camera_steps_each_waypoint_then_wraps_its_script()
  local scene = stubScene(twoWaypointBundle())
  local target = scene.bundle.timeline.camera.target
  local function viewNow()
    return scene:_camera().view()
  end
  Assert.deepEqual(viewNow(), worldView({ 0, 0, 0 }, target))
  for _ = 1, 30 do
    scene:updateFixed()
  end
  Assert.deepEqual(viewNow(), worldView({ 0, 0, 0 }, target), "first waypoint wait holds")
  scene:updateFixed()
  Assert.deepEqual(viewNow(), worldView({ 5, 0, 0 }, target), "one axis steps per tick")
  scene:updateFixed()
  Assert.deepEqual(viewNow(), worldView({ 10, 0, 0 }, target), "the waypoint snaps on arrival")
  for _ = 1, 30 do
    scene:updateFixed()
  end
  Assert.deepEqual(
    viewNow(),
    worldView({ 10, 0, 0 }, target),
    "the second waypoint wait holds its pose"
  )
  for _ = 1, 4 do
    scene:updateFixed()
  end
  Assert.deepEqual(
    viewNow(),
    worldView({ 10, 20, 0 }, target),
    "the second waypoint completes after four steps"
  )
  for _ = 1, 30 do
    scene:updateFixed()
  end
  scene:updateFixed()
  Assert.deepEqual(
    viewNow(),
    worldView({ 10, 15, 0 }, target),
    "the script wraps back to its first waypoint"
  )
end

function T.title_camera_scales_source_units_once_and_keeps_authored_pose()
  local scene = stubScene(twoWaypointBundle())
  scene.cameraPos = { 16, 32, 48 }
  local target = scene.bundle.timeline.camera.target
  local before = { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] }
  Assert.deepEqual(
    scene:_camera().view(),
    worldView({ 16, 32, 48 }, target),
    "the view converts both eye and target into model world units"
  )
  Assert.deepEqual(
    { scene.cameraPos[1], scene.cameraPos[2], scene.cameraPos[3] },
    before,
    "view composition leaves the authored camera position untouched"
  )
  local scaledTwice = Matrix4.lookAt(
    { 16 / 256, 32 / 256, 48 / 256 },
    { target[1] / 256, target[2] / 256, target[3] / 256 },
    { 0, 1, 0 }
  )
  Assert.isFalse(
    pcall(Assert.deepEqual, scene:_camera().view(), scaledTwice),
    "the view scales source units exactly once"
  )
end

function T.title_lighting_falls_back_lit_and_passes_bundles_through()
  local scene = stubScene(twoWaypointBundle())
  local seen = {}
  scene.renderer = {
    draw = function(_, environment)
      seen.environment = environment
    end,
  }
  scene.graphics = {
    push = function() end,
    pop = function() end,
    setCanvas = function() end,
    setScissor = function() end,
    clear = function() end,
  }
  scene:_drawModel()
  local fallback = assert(seen.environment and seen.environment.lighting, "a synthetic scene still renders lit")
  Assert.equal(fallback.records[1].endHalfSeconds, 43200, "the fallback profile is the constant title record")
  Assert.isTrue(
    fallback.records[1].diffuseRgb555 > 0 and fallback.records[1].ambientRgb555 > 0,
    "the fallback carries material registers"
  )
  local passed = {
    records = {
      {
        endHalfSeconds = 7,
        lights = {
          { enabled = true, colorRgb555 = 1, color = { 1, 1, 1 }, vectorFx12 = { 0, 1, 0 }, direction = { 0, 1, 0 } },
          { enabled = false, colorRgb555 = 0, color = { 0, 0, 0 }, vectorFx12 = { 0, 0, 0 }, direction = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, color = { 0, 0, 0 }, vectorFx12 = { 0, 0, 0 }, direction = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, color = { 0, 0, 0 }, vectorFx12 = { 0, 0, 0 }, direction = { 0, 0, 0 } },
        },
        diffuseRgb555 = 1,
        ambientRgb555 = 2,
        specularRgb555 = 3,
        emissionRgb555 = 4,
      },
    },
  }
  local bundled = stubScene(twoWaypointBundle())
  bundled.bundle.lighting = passed
  bundled.renderer = {
    draw = function(_, environment)
      seen.environment = environment
    end,
  }
  bundled.graphics = scene.graphics
  bundled:_drawModel()
  Assert.equal(
    seen.environment and seen.environment.lighting,
    passed,
    "a compiled lighting record passes through untouched"
  )
end

function T.title_prompt_tint_uses_the_compiled_retail_palette_per_edition()
  local expected = {
    heartgold = { 27 / 31, 8 / 31, 0 },
    soulsilver = { 0, 28 / 31, 1 },
  }
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local bundle = twoWaypointBundle()
    local ink = expected[versionId]
    bundle.prompt.color = {
      foreground = versionId == "heartgold" and 1 or 2,
      shadow = versionId == "heartgold" and 1 or 2,
      background = 0,
      foregroundRgb = { ink[1], ink[2], ink[3] },
      shadowRgb = { ink[1], ink[2], ink[3] },
    }
    bundle.prompt.flash = {
      initialDelayFrames = 30,
      initialPhaseFrame = 30,
      cycleFrames = 45,
      visibleFrames = 30,
      hiddenFrames = 15,
    }
    local drawn = {}
    local scene = stubScene(bundle, drawn)
    scene.versionId = versionId
    scene.tick = 30
    scene.graphics = {
      push = function() end,
      pop = function() end,
      translate = function() end,
      scale = function() end,
      setColor = function() end,
      setLineWidth = function() end,
      circle = function() end,
      printf = function() end,
    }
    scene:_drawUi(nil)
    Assert.equal(#drawn, 1, versionId .. " prompt prints one ROM-font line")
    local palette = assert(drawn[1].palette, versionId .. " prompt carries its palette triple")
    local function byte(channel)
      return math.floor(channel * 255 + 0.5)
    end
    Assert.deepEqual(
      palette.foreground,
      { r = byte(ink[1]), g = byte(ink[2]), b = byte(ink[3]) },
      versionId .. " prompt foreground uses the retail text palette"
    )
    Assert.deepEqual(
      palette.shadow,
      { r = byte(ink[1]), g = byte(ink[2]), b = byte(ink[3]) },
      versionId .. " prompt shadow reuses the foreground ink"
    )
    Assert.equal(palette.background.a, 0, versionId .. " prompt background stays transparent")
  end
end

return { tests = T }
