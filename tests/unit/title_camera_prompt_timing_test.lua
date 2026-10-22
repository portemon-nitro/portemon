-- The legendary title camera, start prompt and shader delivery follow the
-- sourced scene setup: a narrow half-angle projection, an end-pose first
-- frame, axis-stepped motion after waits, a lit model and a prompt that
-- stays hidden through its opening delay.

local Assert = require("tests.support.Assert")
local Matrix4 = require("libs.math.src.Matrix4")
local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")

local HALF_ANGLE_INDEX = 0xB60
local SOURCE_FULL_FOV = 2 * (HALF_ANGLE_INDEX / 65536) * (2 * math.pi)
local FLASH_CYCLE = 45
local FLASH_VISIBLE = 30

local function syntheticBundle()
  return {
    timeline = {
      camera = {
        start = { position = { 0, 0, 0 }, target = { 0, 0, -10 } },
        target = { 0, 0, -10 },
        endPosition = { 0, 10, 0 },
        points = { { position = { 30, 10, 0 }, durationSeconds = 1 } },
        movement = { unitsPerFrame = 5, tolerance = 1, waitFramesPerSecond = 30 },
      },
    },
    prompt = {
      text = "TOUCH TO START",
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
        cycleFrames = FLASH_CYCLE,
        visibleFrames = FLASH_VISIBLE,
        hiddenFrames = 15,
      },
    },
  }
end

local function stubActor()
  local actor = { updates = 0, poses = 0 }
  function actor:updateFixed()
    self.updates = self.updates + 1
  end
  function actor:evaluatePose()
    self.poses = self.poses + 1
  end
  function actor:drawItems()
    return {}
  end
  return actor
end

local function stubUiGraphics(printed)
  return {
    push = function() end,
    pop = function() end,
    setColor = function() end,
    setLineWidth = function() end,
    circle = function() end,
    printf = function(text)
      printed[#printed + 1] = text
    end,
  }
end

local function stubScene(graphics, bundle)
  local legend, sparkle = stubActor(), stubActor()
  local scene = setmetatable({
    versionId = "soulsilver",
    bundle = bundle or syntheticBundle(),
    tick = 0,
    promptFrame = 0,
    graphics = graphics or {},
    legend = legend,
    sparkle = sparkle,
    layout = { prompt = { x = 100, y = 300, width = 300, height = 30 } },
    buttonBounds = { x = 400, y = 320, width = 48, height = 48 },
    disposed = false,
  }, HgssTitleScene)
  return scene, legend, sparkle
end

local function fovOf(projection)
  return 2 * math.atan(1 / projection[6])
end

local function expectedView(eye, target)
  return Matrix4.lookAt(eye, target, { 0, 1, 0 })
end

local function promptShown(printed, text)
  for _, entry in ipairs(printed) do
    if entry == text then
      return true
    end
  end
  return false
end

local T = {}

function T.title_camera_uses_source_projection_start_pose_stepping_and_lit_delivery()
  local scene = stubScene({})
  local camera = scene:_camera()
  Assert.near(fovOf(camera.projection()), SOURCE_FULL_FOV, 0.02, "title projection matches the source half-angle")
  Assert.deepEqual(camera.view(), expectedView({ 0, 10, 0 }, { 0, 0, -10 }))

  for _ = 1, 15 do
    scene:updateFixed()
  end
  Assert.equal(scene.tick, 15, "title ticks advance once per fixed update")
  Assert.deepEqual(
    scene:_camera().view(),
    expectedView({ 0, 10, 0 }, { 0, 0, -10 }),
    "title camera holds its pose through the waypoint wait"
  )

  for _ = 1, 16 do
    scene:updateFixed()
  end
  Assert.equal(scene.tick, 31, "title ticks advance once per fixed update")
  Assert.deepEqual(
    scene:_camera().view(),
    expectedView({ 5, 10, 0 }, { 0, 0, -10 }),
    "title camera steps one axis by the sourced increment after its wait"
  )

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
  local lighting = seen.environment and seen.environment.lighting
  Assert.notNil(lighting, "title hands the renderer a lighting record")
  Assert.isTrue(type(lighting.records) == "table" and #lighting.records > 0, "title lighting carries records")
  local lights = assert(lighting.records[1].lights, "title lighting record carries lights")
  local enabled = {}
  for _, light in ipairs(lights) do
    if light.enabled ~= false then
      enabled[#enabled + 1] = light
    end
  end
  Assert.equal(#enabled, 2, "title enables exactly two scene lights")
  for _, light in ipairs(enabled) do
    local color = assert(light.color or light.colour, "title light carries a color")
    Assert.equal(color[1], color[2], "title light is neutral white")
    Assert.equal(color[2], color[3], "title light is neutral white")
    Assert.isTrue(color[1] > 0, "title light is on")
    local direction = light.direction or light.vector or light.position
    Assert.isTrue(type(direction) == "table", "title light carries a direction")
    local length = math.sqrt(direction[1] * direction[1] + direction[2] * direction[2] + direction[3] * direction[3])
    Assert.isTrue(length > 0, "title light direction is nonzero")
  end
end

function T.title_prompt_hides_through_its_opening_delay_then_flashes()
  local printed = {}
  local scene, legend, sparkle = stubScene(stubUiGraphics(printed))
  local promptText = scene.bundle.prompt.text
  local shownAt = {}
  local function drawUi() 
    for index = #printed, 1, -1 do
      printed[index] = nil
    end
    scene:_drawUi(nil)
    return promptShown(printed, promptText)
  end
  shownAt[0] = drawUi()
  for frame = 1, 80 do
    scene:updateFixed()
    shownAt[frame] = drawUi()
  end
  Assert.equal(legend.updates, 80, "legend animation advances once per fixed update")
  Assert.equal(sparkle.updates, 80, "sparkle animation advances once per fixed update")
  for tick = 0, 29 do
    Assert.isFalse(shownAt[tick], "start prompt stays hidden during its opening delay")
  end
  for tick = 30, 59 do
    Assert.isTrue(shownAt[tick], "start prompt shows after its opening delay")
  end
  for tick = 60, 74 do
    Assert.isFalse(shownAt[tick], "start prompt hides again after its visible window")
  end
  for tick = 75, 80 do
    Assert.isTrue(shownAt[tick], "start prompt repeats after its hidden window")
  end
end

return { tests = T }
