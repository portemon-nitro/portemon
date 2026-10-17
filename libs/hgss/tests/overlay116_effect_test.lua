local Assert = require("tests.support.Assert")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local Sources = require("romdump.src.config.BattlePresentationSources")
local TransitionFamilyFactory = require("libs.hgss.src.transition.TransitionFamilyFactory")

local T = {}

local function camera()
  return FieldCamera.new({
    projectionType = "perspective",
    distanceTiles = 50,
    angleXRaw = -8192,
    angleYRaw = 0,
    halfFovRadians = math.rad(20),
    fullVerticalFovRadians = math.rad(40),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }, { initialTarget = { x = 0, y = 0, z = 0 } })
end

function T.overlay116_factory_executes_camera_task_and_owns_motion_blur_until_disposal()
  local fieldCamera = camera()
  local initialCamera = fieldCamera:captureTransitionState()
  local seeded = 0
  local stepped = 0
  local blurDisposed = 0
  local function disposeBlur()
    blurDisposed = blurDisposed + 1
  end
  local function beginMotionBlur(_, layers)
    seeded = seeded + 1
    Assert.equal(layers.sourceTick, 0, "the source motion history starts from the launch frame")
    return { composite = {}, _disposed = false, dispose = disposeBlur }
  end
  local function stepMotionBlur(_, _, layers)
    stepped = stepped + 1
    Assert.equal(layers.sourceTick, stepped, "each camera update consumes its matching source frame")
  end
  local renderer = {
    beginEncounterMotionBlur = beginMotionBlur,
    stepEncounterMotionBlur = stepMotionBlur,
  }
  local route = assert(Sources.TRANSITION_SELECTOR_ROUTES[34])
  local effect = TransitionFamilyFactory.new(route, {}, love.graphics, {
    camera = fieldCamera,
    fieldRenderer = renderer,
  }, { playerGender = "male" })
  effect:start()
  effect:acceptFieldLayers({ sourceTick = 0 })
  local completed = false
  local sourceTick = 0
  local flashAlpha = {}
  while not completed and sourceTick < 200 do
    completed = effect:stepSourceTick()
    sourceTick = sourceTick + 1
    local frame = effect:frame()
    if frame.sourcePhase == "flash" then
      flashAlpha[#flashAlpha + 1] = frame.whiteFadeAlpha
    end
    if frame.requiresCurrentFieldLayers then
      effect:acceptFieldLayers({ sourceTick = sourceTick })
    end
  end

  Assert.isTrue(completed, "callback 34 waits for its camera and native fade task")
  local expectedFlashAlpha = { 0, 0, 0, 1 / 3, 2 / 3, 1, 1, 1, 2 / 3, 1 / 3, 0 }
  Assert.equal(#flashAlpha, #expectedFlashAlpha, "the source flash helper exposes every update")
  for index, expected in ipairs(expectedFlashAlpha) do
    Assert.near(flashAlpha[index], expected, 1e-12, "source flash interpolation frame " .. index)
  end
  Assert.isTrue(sourceTick > 57, "callback task waits and fade outlive its camera subtask")
  Assert.equal(seeded, 1, "the motion blur owns one launch seed")
  Assert.equal(stepped + 1, sourceTick, "the launch seed plus each active source tick updates the feedback pair")
  Assert.isTrue(effect:frame().motionBlur ~= nil, "the current frame carries the transition-owned feedback image")
  effect:dispose()
  Assert.equal(blurDisposed, 1, "task disposal releases its feedback canvases once")
  Assert.deepEqual(fieldCamera:captureTransitionState(), initialCamera, "task disposal restores the launch camera")
end

function T.overlay116_distance_routes_use_distinct_source_parameters()
  local finalDistances = {}
  for _, callbackIndex in ipairs({ 35, 36 }) do
    local fieldCamera = camera()
    local disposed = 0
    local function disposeBlur()
      disposed = disposed + 1
    end
    local function beginMotionBlur()
      return { composite = {}, _disposed = false, dispose = disposeBlur }
    end
    local function stepMotionBlur() end
    local renderer = {
      beginEncounterMotionBlur = beginMotionBlur,
      stepEncounterMotionBlur = stepMotionBlur,
    }
    local route = assert(Sources.TRANSITION_SELECTOR_ROUTES[callbackIndex])
    local initialDistance = fieldCamera:captureTransitionState().distanceTiles
    local effect = TransitionFamilyFactory.new(route, {}, love.graphics, {
      camera = fieldCamera,
      fieldRenderer = renderer,
    }, { playerGender = "male" })
    effect:start()
    effect:acceptFieldLayers({})
    local complete = false
    local sourceTick = 0
    while not complete and sourceTick < 200 do
      complete = effect:stepSourceTick()
      sourceTick = sourceTick + 1
      if effect:frame().requiresCurrentFieldLayers then
        effect:acceptFieldLayers({})
      end
    end
    Assert.isTrue(complete, "each source camera route reaches its palette-fade terminal")
    Assert.isTrue(sourceTick > 30, "the effect waits for source camera and fade work")
    finalDistances[#finalDistances + 1] = fieldCamera:captureTransitionState().distanceTiles
    effect:dispose()
    Assert.equal(disposed, 1, "each route releases its owned feedback exactly once")
  end
  Assert.near(finalDistances[1], 8.75, 0.02, "the first route uses its source distance delta")
  Assert.near(finalDistances[2], 15.625, 0.02, "the second route uses its distinct source distance delta")
  Assert.isTrue(finalDistances[1] ~= finalDistances[2], "the two source task records stay distinct")
end

return { tests = T }
