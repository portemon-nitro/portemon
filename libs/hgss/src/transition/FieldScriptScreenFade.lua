-- The pure semantic controller behind source `FadeScreen`/`WaitFade`. It
-- advances only from an explicit `updateSourceFrame()` call driven by the
-- ordinary source-frame cadence; nothing here reads a renderer or an audio
-- service, so the same timeline holds headless and in presentation.
-- Pure domain module: no love dependency.

---@class FieldScriptScreenFade
---@field private _overlay { r: number, g: number, b: number, a: number, screenScope: "main"|"both" }? retained borrowed overlay (read-only/ephemeral)
---@field private _overlayRecord { r: number, g: number, b: number, a: number, screenScope: "main"|"both" } reusable overlay storage
---@field private _active boolean
---@field private _cleanupPending boolean the final step ran; completion lands on the next update
---@field private _completed boolean
---@field private _direction string|nil
---@field private _color string|nil
---@field private _coefficient integer
---@field private _brightnessFx integer
---@field private _deltaFx integer
---@field private _stepsRemaining integer
---@field private _framesIntoStep integer
---@field private _target integer
---@field private _speed integer
---@field private _generation integer
---@field private _screenScope ("main"|"both")?
local FieldScriptScreenFade = {}
FieldScriptScreenFade.__index = FieldScriptScreenFade

local function truncTowardZero(value)
  if value >= 0 then
    return math.floor(value)
  end
  return math.ceil(value)
end

---@return FieldScriptScreenFade
function FieldScriptScreenFade.new()
  return setmetatable({
    _overlay = nil,
    _overlayRecord = { r = 0, g = 0, b = 0, a = 0 },
    _active = false,
    _cleanupPending = false,
    _completed = true,
    _direction = nil,
    _color = nil,
    _coefficient = 0,
    _brightnessFx = 0,
    _deltaFx = 0,
    _stepsRemaining = 0,
    _framesIntoStep = 0,
    _target = 0,
    _speed = 1,
    _generation = 0,
    _screenScope = nil,
  }, FieldScriptScreenFade)
end

-- Begin a screen fade. Starting a second fade while one is still active is a
-- programming/source-sequencing error: two concurrent script screen fades
-- must never blend.
---@param spec { direction: "out"|"in", color: string, duration: integer, speed: integer, screenScope?: "main"|"both" }
---@return integer lease
function FieldScriptScreenFade:startFade(spec)
  assert(self:fadeDone(), "a script screen fade is already active")
  assert(
    type(spec.duration) == "number" and spec.duration % 1 == 0 and spec.duration > 0,
    "fade duration must be a positive integer"
  )
  assert(
    type(spec.speed) == "number" and spec.speed % 1 == 0 and spec.speed > 0,
    "fade speed must be a positive integer"
  )
  assert(spec.direction == "out" or spec.direction == "in", "unsupported fade direction " .. tostring(spec.direction))
  assert(spec.color == "black" or spec.color == "white", "unsupported fade color " .. tostring(spec.color))
  local screenScope = spec.screenScope
  if screenScope == nil then
    screenScope = "both"
  end
  assert(screenScope == "main" or screenScope == "both", "unsupported fade screen scope " .. tostring(screenScope))
  local start, target
  if spec.direction == "out" then
    if spec.color == "black" then
      start, target = 0, -16
    else
      start, target = 0, 16
    end
  else
    if spec.color == "black" then
      start, target = -16, 0
    else
      start, target = 16, 0
    end
  end
  self._active = true
  self._generation = self._generation + 1
  self._screenScope = screenScope
  self._completed = false
  self._cleanupPending = false
  self._direction = spec.direction
  self._color = spec.color
  self._brightnessFx = start * 128
  self._deltaFx = truncTowardZero(((target - start) * 128) / spec.duration)
  self._stepsRemaining = spec.duration
  self._framesIntoStep = 0
  self._target = target
  self._speed = spec.speed
  self._coefficient = math.abs(truncTowardZero(self._brightnessFx / 128))
  self:_refreshOverlay()
  return self._generation
end

-- Clear the active or retained fade only while its generation is still owned
-- by the caller. A stale owner cannot remove a later script's cover.
---@param lease integer
---@return boolean cleared
function FieldScriptScreenFade:clearIfCurrent(lease)
  assert(type(lease) == "number" and lease % 1 == 0 and lease > 0, "fade lease must be a positive integer")
  if lease ~= self._generation or self._screenScope == nil then
    return false
  end
  self._generation = self._generation + 1
  self._active = false
  self._cleanupPending = false
  self._completed = true
  self._direction = nil
  self._color = nil
  self._screenScope = nil
  self._coefficient = 0
  self._brightnessFx, self._deltaFx, self._stepsRemaining = 0, 0, 0
  self._framesIntoStep, self._target, self._speed = 0, 0, 1
  self._overlay = nil
  return true
end

-- True while idle: nothing has started, or the started fade fully completed.
-- `WaitFade` normally follows a `FadeScreen`, so the idle state before any
-- fade must not itself block a script.
---@return boolean
function FieldScriptScreenFade:fadeDone()
  if not self._active then
    return true
  end
  return self._completed
end

-- True only once a fade-out has driven the coefficient fully opaque. Idle
-- and a completed fade-in are both not opaque.
---@return boolean
function FieldScriptScreenFade:isOpaque()
  return self._active and self._coefficient == 16
end

-- Advance exactly one source-frame tick. A no-op before any fade started or
-- once it has completed; rendering must never call this. Source: the retail
-- ROM: after its final step a fade spends one clean-up update before it
-- reports finished.
function FieldScriptScreenFade:updateSourceFrame()
  if not self._active or self._completed then
    return
  end
  if self._cleanupPending then
    self._cleanupPending = false
    self._completed = true
    self:_refreshOverlay()
    return
  end
  self._framesIntoStep = self._framesIntoStep + 1
  if self._framesIntoStep < self._speed then
    return
  end
  self._framesIntoStep = 0
  self._stepsRemaining = self._stepsRemaining - 1
  if self._stepsRemaining > 0 then
    self._brightnessFx = self._brightnessFx + self._deltaFx
    self._coefficient = math.abs(truncTowardZero(self._brightnessFx / 128))
  else
    self._brightnessFx = self._target * 128
    self._coefficient = math.abs(self._target)
    self._cleanupPending = true
  end
  self:_refreshOverlay()
end

-- Refreshes the retained overlay from the current coefficient. The record
-- is reused in place so unchanged frames borrow the identical table; idle
-- (no fade, or a fully clear coefficient) borrows nil with no allocation.
function FieldScriptScreenFade:_refreshOverlay()
  if not self._active or (self._coefficient <= 0 and self._completed) then
    self._overlay = nil
    return
  end
  local channel = self._color == "white" and 1 or 0
  local record = self._overlayRecord
  record.r = channel
  record.g = channel
  record.b = channel
  record.a = math.min(1, math.max(0, self._coefficient / 16))
  record.screenScope = self._screenScope
  self._overlay = record
end

-- The borrowed presentation overlay for the renderer: the retained overlay
-- record, or nil while idle/clear. Controller-owned, read-only, and
-- ephemeral (valid only until the next updateSourceFrame/startFade).
-- Unlike status(), this never allocates an idle record for the renderer.
---@return { r: number, g: number, b: number, a: number, screenScope: "main"|"both" }?
function FieldScriptScreenFade:presentationOverlay()
  return self._overlay
end

-- Read-only status for the scheduler poll and for presentation/acceptance
-- observation. Never mutates the controller.
---@return table<string, unknown>
function FieldScriptScreenFade:status()
  if not self._active then
    return {
      active = false,
      direction = nil,
      color = nil,
      coefficient = 0,
      completed = true,
      screenScope = nil,
      overlay = nil,
    }
  end
  local overlay
  if self._coefficient > 0 then
    local channel = self._color == "white" and 1 or 0
    overlay = {
      r = channel,
      g = channel,
      b = channel,
      a = math.min(1, math.max(0, self._coefficient / 16)),
      screenScope = self._screenScope,
    }
  end
  return {
    active = not self._completed,
    direction = self._direction,
    color = self._color,
    coefficient = self._coefficient,
    completed = self._completed,
    screenScope = self._screenScope,
    overlay = overlay,
  }
end

return FieldScriptScreenFade
