-- Owns the camera choreography and field feedback used by overlay 116.

local Overlay116CameraProgram = require("libs.hgss.src.transition.battle.Overlay116CameraProgram")

local Overlay116Effect = {}
Overlay116Effect.__index = Overlay116Effect

---@param route table<string, unknown> source-normalized route
---@param services {camera: table<string, function>, fieldRenderer: table<string, function>}
---@return table<string, unknown>
function Overlay116Effect.new(route, services)
  assert(route.role == "camera-and-fade-transition", "overlay 116 owns camera-and-fade routes")
  assert(type(route.task) == "table", "overlay 116 route carries its normalized camera program")
  assert(services and services.camera and services.fieldRenderer, "overlay 116 requires field camera and compositor")
  local task = route.task
  assert(type(task.parameters) == "table", "overlay 116 task has normalized source parameters")
  return setmetatable({
    _task = task,
    _cameraProgram = Overlay116CameraProgram.new(task, services.camera),
    _fieldRenderer = services.fieldRenderer,
    _phase = "new",
    _flashState = 0,
    _flashFrame = 0,
    _flashStart = 0,
    _flashFinish = 0,
    _flashBrightness = 0,
    _flashDone = false,
    _otherFadeFrame = 0,
    _fadeTick = 0,
    _motionBlur = nil,
    _disposed = false,
  }, Overlay116Effect)
end

function Overlay116Effect:start()
  assert(not self._disposed and self._phase == "new", "overlay 116 starts once")
  self._phase = "flash"
end

---@param layers table<string, unknown> freshly captured native field planes
function Overlay116Effect:acceptFieldLayers(layers)
  assert(not self._disposed and self._phase ~= "new", "overlay 116 consumes active source field layers")
  if self._motionBlur == nil then
    self._motionBlur = self._fieldRenderer:beginEncounterMotionBlur(layers)
  else
    self._fieldRenderer:stepEncounterMotionBlur(self._motionBlur, layers)
  end
end

---@return boolean complete after the native camera and fade work has ended
function Overlay116Effect:stepSourceTick()
  assert(not self._disposed and self._phase ~= "new", "overlay 116 advances after start")
  if self._phase == "flash" then
    self:_stepFlashTask()
    if self._flashDone then
      self._cameraProgram:start()
      self._phase = "camera"
    end
    return false
  end
  if self._phase == "camera" then
    if self._cameraProgram:stepSourceTick() then
      self._phase = "white-fade"
      self._fadeTick = 0
    end
    return false
  end
  if self._phase == "white-fade" then
    self._fadeTick = self._fadeTick + 1
    if self._fadeTick >= self._task.parameters.fadeTicks then
      self._phase = "complete"
      return true
    end
    return false
  end
  assert(self._phase == "complete", "overlay 116 cannot step an unknown source phase")
  return true
end

---@return table<string, unknown> current source camera, feedback image and palette-fade frame
function Overlay116Effect:frame()
  assert(not self._disposed, "disposed overlay 116 has no frame")
  local fadeAlpha = 0
  if self._phase == "flash" then
    fadeAlpha = self._flashBrightness / 16
  elseif self._phase == "white-fade" then
    fadeAlpha = math.min(1, self._fadeTick / self._task.parameters.fadeTicks)
  elseif self._phase == "complete" then
    fadeAlpha = 1
  end
  return {
    sourcePhase = self._phase,
    camera = self._cameraProgram:frame(),
    motionBlur = self._motionBlur,
    whiteFadeAlpha = fadeAlpha,
    requiresCurrentFieldLayers = self._phase ~= "complete",
  }
end

function Overlay116Effect:_stepFlashTask()
  if self._flashState == 0 then
    self._flashState = 1
  elseif self._flashState == 1 then
    self._flashStart = 0
    self._flashFinish = 16
    self._flashFrame = 0
    self._flashState = 2
  elseif self._flashState == 2 then
    self:_updateFlashInterpolation()
    if self._flashFrame > 3 then
      self._flashState = 3
    end
  elseif self._flashState == 3 then
    self._flashStart = 16
    self._flashFinish = 0
    self._flashFrame = 0
    self._flashState = 4
  elseif self._flashState == 4 then
    self:_updateFlashInterpolation()
    if self._flashFrame > 3 then
      self._flashState = 5
    end
  elseif self._flashState == 5 then
    self._flashDone = true
  else
    assert(false, "overlay 116 flash task follows the pinned helper states")
  end
  self._otherFadeFrame = math.min(self._otherFadeFrame + 1, 8)
end

function Overlay116Effect:_updateFlashInterpolation()
  self._flashBrightness = self._flashStart + (self._flashFinish - self._flashStart) * self._flashFrame / 3
  self._flashFrame = self._flashFrame + 1
end

function Overlay116Effect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._cameraProgram:dispose()
  local motionBlur = self._motionBlur
  self._motionBlur = nil
  if motionBlur ~= nil then
    motionBlur:dispose()
  end
  self._phase = "disposed"
end

return Overlay116Effect
