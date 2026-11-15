-- The retail field-poison screen wobble shown when a poisoned party loses
-- HP while walking. Pure presentation state: no love dependency.
--
-- Transcribes tmp/refs/pokeheartgold src/field/field_poison_effect.c:
-- every HBlank shifts the 3D layer horizontally by an offset that
-- alternates sign every 10 scanlines, and the amplitude ramps up and down
-- over the effect lifetime. The native task sequence is START (one frame,
-- offsets cleared), RAMP_UP (three frames filling 1, 2, 3), RAMP_DOWN
-- (three frames filling 2, 1, 0), then STOP (offsets released and the
-- hardware offset reset to zero). Audio (SEQ_SE_DP_DOKU2) is owned by the
-- runtime tick, not this effect, matching FieldSystem_UpdatePoison which
-- drains the party before FieldSystem_DoPoisonEffect plays the jingle and
-- starts the wobble for both damage and survive outcomes.
--
-- The published frame mirrors the source transition shape the field
-- compositor already understands: `{ scanlineOffsets = <192 integers> }`,
-- one horizontal offset per native scanline, or nil while idle so the
-- field draws normally. Offsets wrap in native units at draw time, exactly
-- like the HBlank transition path.

---@class FieldPoisonEffect
---@field private _active boolean
---@field private _seq string
---@field private _counter integer
---@field private _offsets integer[]? live 192-entry offsets while active, nil while idle (borrowed: draws must not mutate)
local FieldPoisonEffect = {}
FieldPoisonEffect.__index = FieldPoisonEffect

local LINE_COUNT = 192
local GROUP_LINES = 10
local RAMP_DENOM = 3
local RAMP_PEAK = 3

local SEQ_IDLE = "idle"
local SEQ_START = "start"
local SEQ_RAMP_UP = "ramp_up"
local SEQ_RAMP_DOWN = "ramp_down"
local SEQ_STOP = "stop"

---@return FieldPoisonEffect
function FieldPoisonEffect.new()
  return setmetatable({
    _active = false,
    _seq = SEQ_IDLE,
    _counter = 0,
    _offsets = nil,
  }, FieldPoisonEffect)
end

---@return boolean true while the wobble owns frames
function FieldPoisonEffect:isActive()
  return self._active
end

-- Fills the live offsets with the alternating-sign pattern behind one
-- ramp step: `value = num * 3 / denom` pixels (native integer division),
-- negated on every other 10-line band. Line 1 starts negative, matching
-- the source toggle which flips before writing line 0.
---@param offsets integer[] live 192-entry offsets mutated in place
---@param num integer 0..3 ramp position
---@param denom integer ramp denominator (3)
local function fillOffsets(offsets, num, denom)
  local value = math.floor(num * RAMP_PEAK / denom)
  local toggle = 1
  for line = 0, LINE_COUNT - 1 do
    if line % GROUP_LINES == 0 then
      toggle = 1 - toggle
    end
    if toggle ~= 0 then
      offsets[line + 1] = value
    else
      offsets[line + 1] = -value
    end
  end
end

---@return integer[] fresh zeroed 192-entry offsets
local function zeroOffsets()
  local offsets = {}
  for line = 1, LINE_COUNT do
    offsets[line] = 0
  end
  return offsets
end

-- Starts the wobble. Asserts idle like the native DoPoisonEffect guard:
-- ticks are spaced four steps apart while the wobble lasts eight frames,
-- so overlapping starts are a programming fault, never a restart.
function FieldPoisonEffect:start()
  assert(not self._active, "poison wobble is already running")
  self._active = true
  self._seq = SEQ_START
  self._counter = 0
  self._offsets = zeroOffsets()
end

-- Advances one source frame. A no-op while idle.
function FieldPoisonEffect:updateSourceFrame()
  if not self._active then
    return
  end
  local offsets = assert(self._offsets, "active poison wobble owns its offsets")
  if self._seq == SEQ_START then
    self._counter = 3
    self._seq = SEQ_RAMP_UP
  elseif self._seq == SEQ_RAMP_UP then
    self._counter = self._counter - 1
    fillOffsets(offsets, 3 - self._counter, RAMP_DENOM)
    if self._counter <= 0 then
      self._counter = 3
      self._seq = SEQ_RAMP_DOWN
    end
  elseif self._seq == SEQ_RAMP_DOWN then
    self._counter = self._counter - 1
    fillOffsets(offsets, self._counter, RAMP_DENOM)
    if self._counter <= 0 then
      self._seq = SEQ_STOP
    end
  elseif self._seq == SEQ_STOP then
    self._active = false
    self._seq = SEQ_IDLE
    self._counter = 0
    self._offsets = nil
  else
    error("poison wobble entered an unknown sequence: " .. tostring(self._seq), 0)
  end
end

-- The current compositor frame, or nil while idle. The offsets storage is
-- borrowed and valid only until the next update; draws must not mutate it.
---@return { scanlineOffsets: integer[] }? nil while idle
function FieldPoisonEffect:frame()
  if not self._active then
    return nil
  end
  return { scanlineOffsets = assert(self._offsets, "active poison wobble owns its offsets") }
end

return FieldPoisonEffect
