local Assert = require("tests.support.Assert")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local Sources = require("romdump.src.config.BattlePresentationSources")
local Overlay116CameraProgram = require("libs.hgss.src.transition.battle.Overlay116CameraProgram")

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

function T.pose_sequence_applies_each_record_after_its_source_delay_and_restores()
  local fieldCamera = camera()
  local initial = fieldCamera:captureTransitionState()
  local task = assert(Sources.TRANSITION_SELECTOR_ROUTES[34]).task
  local program = Overlay116CameraProgram.new(task, fieldCamera)
  program:start()
  Assert.isTrue(program:frame().requiresCurrentFieldLayers)

  for _ = 1, task.parameters.poses[1].waitTicks do
    Assert.isFalse(program:stepSourceTick(), "pose delay has not crossed below zero")
  end
  Assert.equal(fieldCamera:rawPerspective(), initial.rawPerspective, "camera key waits before application")
  Assert.isFalse(program:stepSourceTick(), "the negative delay applies the first camera key")
  Assert.equal(fieldCamera:rawPerspective(), task.parameters.poses[1].perspectiveRaw)
  Assert.deepEqual(program:frame().cameraPose, task.parameters.poses[1])
  program:dispose()
  Assert.deepEqual(fieldCamera:captureTransitionState(), initial, "disposal restores the launch camera")
end

function T.pose_sequence_consumes_all_source_waits_before_completion()
  local fieldCamera = camera()
  local task = assert(Sources.TRANSITION_SELECTOR_ROUTES[34]).task
  local program = Overlay116CameraProgram.new(task, fieldCamera)
  program:start()
  local elapsed = 0
  for index, pose in ipairs(task.parameters.poses) do
    for _ = 1, pose.waitTicks do
      elapsed = elapsed + 1
      Assert.isFalse(program:stepSourceTick(), "native wait remains active before its counter is negative")
    end
    elapsed = elapsed + 1
    local done = program:stepSourceTick()
    Assert.deepEqual(program:frame().cameraPose, pose, "source row is applied after its own delay")
    Assert.equal(done, index == #task.parameters.poses, "only the final source pose ends the camera subtask")
  end
  Assert.equal(elapsed, 57, "all source delay crossings consume their source-tick count")
  program:dispose()
end

function T.distance_sequences_use_native_linear_and_quadratic_completion()
  for _, selector in ipairs({ 35, 36 }) do
    local fieldCamera = camera()
    local initialDistance = math.floor(fieldCamera.distance * 65536 + 0.5)
    local initialPerspective = fieldCamera:rawPerspective()
    local task = assert(Sources.TRANSITION_SELECTOR_ROUTES[selector]).task
    local program = Overlay116CameraProgram.new(task, fieldCamera)
    program:start()

    for _ = 1, task.parameters.perspectiveTicks + 1 do
      Assert.isFalse(program:stepSourceTick(), "perspective task completes after the source helper's final update")
    end
    Assert.equal(fieldCamera:rawPerspective(), initialPerspective + task.parameters.perspectiveDeltaRaw)
    for _ = 1, task.parameters.waitTicks + 1 do
      Assert.isFalse(program:stepSourceTick(), "distance task starts after the source wait crosses below zero")
    end
    for _ = 1, task.parameters.distanceTicks do
      Assert.isFalse(program:stepSourceTick(), "quadratic distance task is still active")
    end
    Assert.isTrue(program:stepSourceTick(), "quadratic helper completes on its source terminal update")
    Assert.equal(fieldCamera.distance, (initialDistance + task.parameters.distanceDeltaFx32) / 65536)
    program:dispose()
    Assert.equal(fieldCamera:rawPerspective(), initialPerspective, "disposal restores the original perspective")
  end
end

return { tests = T }
