-- Field camera zoom: the source FieldCameraZoom_Set command pair (zoom by a
-- fixed fx32 delta over N ticks, zoom back to the distance captured at
-- start) driving one camera's eye distance. Arithmetic stays in integer
-- fx32 so the per-tick steps and the exact landing match the source. The
-- owner steps it once per source tick and releases it exactly once; a
-- released zoom restores the captured distance and never moves the camera
-- again. Pure domain module: no love dependency.

---@class FieldCameraZoom
---@field private _camera FieldCamera
---@field private _initialFx integer
---@field private _distanceFx integer
---@field private _mode "idle"|"by"|"back"
---@field private _amountFx integer
---@field private _duration integer
---@field private _elapsed integer
---@field private _stepFx integer
---@field private _targetFx integer
---@field private _started boolean
---@field private _done boolean
---@field private _released boolean
local FieldCameraZoom = {}
FieldCameraZoom.__index = FieldCameraZoom

local FX32 = 65536

local function trunc(value)
  if value >= 0 then
    return math.floor(value)
  end
  return math.ceil(value)
end

---@param camera FieldCamera
---@return FieldCameraZoom
function FieldCameraZoom.new(camera)
  assert(type(camera) == "table", "camera zoom requires its camera")
  local initialFx = math.floor(camera:distanceTiles() * FX32 + 0.5)
  return setmetatable({
    _camera = camera,
    _initialFx = initialFx,
    _distanceFx = initialFx,
    _mode = "idle",
    _amountFx = 0,
    _duration = 1,
    _elapsed = 0,
    _stepFx = 0,
    _targetFx = initialFx,
    _started = false,
    _done = true,
    _released = false,
  }, FieldCameraZoom)
end

-- Start a zoom command, replacing any running one.
---@param mode "idle"|"by"|"back"
---@param amountFx32 integer signed delta for "by"; ignored otherwise
---@param duration integer ticks, positive
function FieldCameraZoom:set(mode, amountFx32, duration)
  assert(not self._released, "a released camera zoom accepts no command")
  assert(mode == "idle" or mode == "by" or mode == "back", "unknown camera zoom mode " .. tostring(mode))
  assert(type(duration) == "number" and duration % 1 == 0 and duration > 0, "zoom duration must be positive")
  assert(type(amountFx32) == "number" and amountFx32 % 1 == 0, "zoom amount must be integer fx32")
  self._mode = mode
  self._amountFx = amountFx32
  self._duration = duration
  self._elapsed = 0
  self._started = false
  self._done = false
end

---@return boolean
function FieldCameraZoom:isDone()
  return self._done
end

-- Advance one source tick.
function FieldCameraZoom:step()
  assert(not self._released, "a released camera zoom never steps")
  if self._mode == "idle" then
    self._done = true
    return
  end
  if self._done then
    return
  end
  if not self._started then
    self._started = true
    if self._mode == "by" then
      self._stepFx = trunc(self._amountFx / self._duration)
      self._targetFx = self._distanceFx + self._amountFx
    else
      self._stepFx = trunc((self._initialFx - self._distanceFx) / self._duration)
      self._targetFx = self._initialFx
    end
  end
  self._distanceFx = self._distanceFx + self._stepFx
  self._elapsed = self._elapsed + 1
  if self._elapsed >= self._duration then
    self._distanceFx = self._targetFx
    self._done = true
  end
  self._camera:setDistanceTiles(self._distanceFx / FX32)
end

-- Put the camera back at the captured distance and end the zoom. Idempotent.
function FieldCameraZoom:release()
  if self._released then
    return
  end
  self._released = true
  if self._distanceFx ~= self._initialFx then
    self._camera:setDistanceTiles(self._initialFx / FX32)
  end
end

return FieldCameraZoom
