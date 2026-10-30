-- The Honey and Sweet Scent screen tint: a solid colour blended over the
-- world, faded in to ten sixteenths of alpha over 19 frames and back out
-- over 15. Each fade completes one update after its frame counter reaches
-- the frame count. Source basis: the retail ROM's Honey and Sweet Scent fade
-- (tint 0x5D5F, step formula start + delta * counter / frames). It advances
-- only from explicit updateSourceFrame() calls. Pure domain module: no love
-- dependency.

---@class FieldScentTint
---@field private _active boolean
---@field private _done boolean
---@field private _cur integer
---@field private _start integer
---@field private _delta integer
---@field private _counter integer
---@field private _frames integer
---@field private _overlay { r: number, g: number, b: number, a: number, screenScope: "main" }
local FieldScentTint = {}
FieldScentTint.__index = FieldScentTint

FieldScentTint.FADE_IN_FRAMES = 19
FieldScentTint.FADE_OUT_FRAMES = 15
FieldScentTint.MAX_ALPHA = 10

-- The tint colour 0x5D5F as 5-bit channels over 31.
local COLOR = { r = 31 / 31, g = 10 / 31, b = 23 / 31 }

-- C integer division truncates toward zero.
local function truncate(value)
  if value >= 0 then
    return math.floor(value)
  end
  return math.ceil(value)
end

---@return FieldScentTint
function FieldScentTint.new()
  return setmetatable({
    _active = false,
    _done = true,
    _cur = 0,
    _start = 0,
    _delta = 0,
    _counter = 0,
    _frames = 1,
    _overlay = { r = COLOR.r, g = COLOR.g, b = COLOR.b, a = 0, screenScope = "main" },
  }, FieldScentTint)
end

local function begin(self, start, target, frames)
  self._active = true
  self._done = false
  self._cur = start
  self._start = start
  self._delta = target - start
  self._counter = 0
  self._frames = frames
end

function FieldScentTint:startIn()
  begin(self, 0, FieldScentTint.MAX_ALPHA, FieldScentTint.FADE_IN_FRAMES)
end

function FieldScentTint:startOut()
  begin(self, FieldScentTint.MAX_ALPHA, 0, FieldScentTint.FADE_OUT_FRAMES)
end

-- Release the tint at once, whatever its state.
function FieldScentTint:clear()
  self._active = false
  self._done = true
  self._cur = 0
end

---@return boolean true while idle or once the started fade finished
function FieldScentTint:isDone()
  return self._done
end

-- Advance one source frame; a no-op while idle or finished.
function FieldScentTint:updateSourceFrame()
  if self._done then
    return
  end
  self._cur = self._start + truncate(self._delta * self._counter / self._frames)
  if self._counter + 1 <= self._frames then
    self._counter = self._counter + 1
  else
    self._counter = self._frames
    self._done = true
  end
end

-- The borrowed overlay for the renderer, nil while no tint shows.
---@return { r: number, g: number, b: number, a: number, screenScope: "main" }?
function FieldScentTint:presentationOverlay()
  if not self._active or self._cur <= 0 then
    return nil
  end
  self._overlay.a = self._cur / 16
  return self._overlay
end

return FieldScentTint
