-- Runs the camera-owned choreography shared by the pinned overlay 116 routes.

local Overlay116CameraProgram = {}
Overlay116CameraProgram.__index = Overlay116CameraProgram

---@param value integer fx32 value rounded as in EncounterEffectQuadInterp_Init/Update
---@return integer
local function roundFx(value)
  return math.floor((value + 2048) / 4096)
end

---@param task {start: integer, finish: integer, duration: integer, frame: integer}
---@return integer value
---@return boolean done
local function stepLinear(task)
  local value = task.start + math.modf((task.finish - task.start) * task.frame / task.duration)
  task.frame = task.frame + 1
  if task.frame > task.duration then
    task.frame = task.duration
    return value, true
  end
  return value, false
end

---@param start integer
---@param finish integer
---@param velocity integer fx32 per frame
---@param duration integer
---@return { start: integer, finish: integer, velocity: integer, acceleration: integer, duration: integer, frame: integer }
local function newQuadratic(start, finish, velocity, duration)
  local linearTotal = roundFx(velocity * duration * 4096)
  local remaining = finish - start - linearTotal
  local numerator = roundFx(remaining * 8192)
  local denominator = duration * duration * 4096
  local acceleration = math.modf(numerator * 4096 / denominator)
  return {
    start = start,
    finish = finish,
    velocity = velocity,
    acceleration = acceleration,
    duration = duration,
    frame = 0,
  }
end

---@param task { start: integer, finish: integer, velocity: integer, acceleration: integer, duration: integer, frame: integer }
---@return integer value
---@return boolean done
local function stepQuadratic(task)
  local frame = task.frame
  local linear = roundFx(task.velocity * frame * 4096)
  local square = frame * frame * 4096
  local quadratic = roundFx(task.acceleration * square)
  local value = task.start + linear + math.modf(quadratic / 2)
  task.frame = frame + 1
  if task.frame > task.duration then
    task.frame = task.duration
    return value, true
  end
  return value, false
end

---@param task { kind: string, parameters: { poses: { distanceFx32: integer, angleXRaw: integer, angleYRaw: integer, perspectiveRaw: integer, waitTicks: integer }[], perspectiveDeltaRaw: integer, perspectiveTicks: integer, waitTicks: integer, distanceDeltaFx32: integer, distanceVelocityFx32: integer, distanceTicks: integer } } source-normalized overlay 116 camera task
---@param camera table<string, function> live field camera owner
---@return table<string, unknown>
function Overlay116CameraProgram.new(task, camera)
  assert(type(task) == "table" and type(task.parameters) == "table", "overlay 116 camera task is required")
  assert(
    task.kind == "field-camera-pose-sequence" or task.kind == "field-camera-perspective-distance-fade",
    "overlay 116 camera program accepts its two normalized task kinds"
  )
  assert(camera and camera.captureTransitionState and camera.setTransitionPose and camera.restoreTransitionState)
  return setmetatable({
    _task = task,
    _camera = camera,
    _state = "new",
    _cameraState = nil,
    _poseIndex = 1,
    _delay = 0,
    _interpolation = nil,
    _distance = nil,
    _lastPose = nil,
  }, Overlay116CameraProgram)
end

function Overlay116CameraProgram:start()
  assert(self._state == "new", "overlay 116 camera program starts once")
  self._cameraState = self._camera:captureTransitionState()
  local parameters = self._task.parameters
  if self._task.kind == "field-camera-pose-sequence" then
    self._state = "pose-delay"
    self._delay = parameters.poses[1].waitTicks
  else
    self._state = "perspective"
    local start = self._camera:rawPerspective()
    self._interpolation = {
      start = start,
      finish = start + parameters.perspectiveDeltaRaw,
      duration = parameters.perspectiveTicks,
      frame = 0,
    }
  end
end

---@return boolean complete when the source camera subtask has reached its terminal condition
function Overlay116CameraProgram:stepSourceTick()
  assert(self._state ~= "new", "overlay 116 camera program starts before stepping")
  assert(self._state ~= "disposed", "disposed overlay 116 camera program cannot advance")
  if self._state == "complete" then
    return true
  end

  local parameters = self._task.parameters
  if self._state == "pose-delay" then
    self._delay = self._delay - 1
    if self._delay < 0 then
      local pose = parameters.poses[self._poseIndex]
      self._camera:setTransitionPose(pose)
      self._lastPose = pose
      self._poseIndex = self._poseIndex + 1
      if self._poseIndex > #parameters.poses then
        self._state = "complete"
        return true
      end
      self._delay = parameters.poses[self._poseIndex].waitTicks
    end
    return false
  end

  if self._state == "perspective" then
    local perspective, done = stepLinear(assert(self._interpolation, "perspective phase owns its interpolation"))
    local cameraState = assert(self._cameraState)
    self._camera:setTransitionPose({
      distanceFx32 = math.floor(cameraState.distanceTiles * 65536 + 0.5),
      angleXRaw = cameraState.angleXRaw,
      angleYRaw = cameraState.angleYRaw,
      perspectiveRaw = perspective % 65536,
    })
    if done then
      self._state = "distance-delay"
      self._delay = parameters.waitTicks
    end
    return false
  end

  if self._state == "distance-delay" then
    self._delay = self._delay - 1
    if self._delay < 0 then
      local cameraState = assert(self._cameraState)
      local start = math.floor(cameraState.distanceTiles * 65536 + 0.5)
      self._distance = newQuadratic(
        start,
        start + parameters.distanceDeltaFx32,
        parameters.distanceVelocityFx32,
        parameters.distanceTicks
      )
      self._state = "distance"
    end
    return false
  end

  assert(self._state == "distance", "overlay 116 camera program has a pinned source phase")
  local distance, done = stepQuadratic(assert(self._distance))
  local cameraState = assert(self._cameraState)
  self._camera:setTransitionPose({
    distanceFx32 = distance,
    angleXRaw = cameraState.angleXRaw,
    angleYRaw = cameraState.angleYRaw,
    perspectiveRaw = self._camera:rawPerspective(),
  })
  if done then
    self._state = "complete"
    return true
  end
  return false
end

---@return { state: string, poseIndex: integer, delay: integer, requiresCurrentFieldLayers: boolean, cameraPose: { distanceFx32: integer, angleXRaw: integer, angleYRaw: integer, perspectiveRaw: integer, waitTicks: integer }|nil, camera: table<string, unknown> } current camera program phase and source index
function Overlay116CameraProgram:frame()
  local pose = self._lastPose
  return {
    state = self._state,
    poseIndex = self._poseIndex,
    delay = self._delay,
    requiresCurrentFieldLayers = true,
    cameraPose = pose and {
      distanceFx32 = pose.distanceFx32,
      angleXRaw = pose.angleXRaw,
      angleYRaw = pose.angleYRaw,
      perspectiveRaw = pose.perspectiveRaw,
      waitTicks = pose.waitTicks,
    } or nil,
    camera = self._camera:captureTransitionState(),
  }
end

function Overlay116CameraProgram:dispose()
  if self._state == "disposed" then
    return
  end
  if self._cameraState ~= nil then
    self._camera:restoreTransitionState(self._cameraState)
  end
  self._state = "disposed"
end

return Overlay116CameraProgram
