-- Fixed-tick playback of one compiled picture track: the player exposes the
-- authored initial sample, consumes exactly one duration unit per fixed
-- update, holds finite terminals, cycles proved loops from their entry, and
-- emits a delayed cry cue exactly once. Status reads never advance playback;
-- disposal drops a pending cry. Pure module: no love, no I/O, no RNG.

---@class SummaryPicturePlayer
---@field _epoch integer
---@field _samples table[]
---@field _loopFrom integer?
---@field _cryDelayTicks integer?
---@field _index integer
---@field _remaining integer
---@field _elapsed integer
---@field _cryEmitted boolean
---@field _effects table[]
---@field _disposed boolean
local SummaryPicturePlayer = {}
SummaryPicturePlayer.__index = SummaryPicturePlayer

---@param samples table[]
local function checkSamples(samples)
  assert(type(samples) == "table" and #samples >= 1, "a picture definition carries its samples")
  for position, sample in ipairs(samples) do
    assert(type(sample) == "table", "picture sample " .. position .. " is a record")
    local duration = sample.durationTicks
    assert(
      type(duration) == "number" and duration % 1 == 0 and duration >= 1,
      "picture sample " .. position .. " carries a positive duration"
    )
  end
end

---@param definition table<string, unknown>
---@param epoch integer
---@return SummaryPicturePlayer
function SummaryPicturePlayer.new(definition, epoch)
  assert(type(definition) == "table", "a picture definition is required")
  assert(
    type(epoch) == "number" and epoch % 1 == 0 and epoch >= 0,
    "a picture player carries its non-negative picture epoch"
  )
  local samples = assert(definition.samples, "a picture definition carries its samples")
  checkSamples(samples)
  local loopFrom = definition.loopFrom
  if loopFrom ~= nil then
    assert(
      type(loopFrom) == "number" and loopFrom % 1 == 0 and loopFrom >= 1 and loopFrom <= #samples,
      "a proved loop re-enters inside its samples"
    )
  end
  local cryDelay = definition.cryDelayTicks
  if cryDelay ~= nil then
    assert(type(cryDelay) == "number" and cryDelay % 1 == 0 and cryDelay >= 0, "a cry delay counts native ticks")
  end
  return setmetatable({
    _epoch = epoch,
    _samples = samples,
    _loopFrom = loopFrom,
    _cryDelayTicks = cryDelay,
    _index = 1,
    _remaining = 0,
    _elapsed = 0,
    _cryEmitted = false,
    _effects = {},
    _disposed = false,
  }, SummaryPicturePlayer)
end

-- Beginning playback selects the authored initial sample without consuming
-- it; the first fixed update consumes the first duration unit. Starting
-- schedules a delayed cry but never emits it.
function SummaryPicturePlayer:start()
  assert(not self._disposed, "a disposed picture plays nothing")
  self._index = 1
  local first = assert(self._samples[1], "a picture definition carries its samples")
  self._remaining = assert(first.durationTicks, "picture samples carry a positive duration")
  self._elapsed = 0
  self._cryEmitted = false
  self._effects = {}
end

-- One native tick: exactly one duration unit, then the delayed cry cue when
-- its window elapses. Finite tracks hold their terminal sample; proved loops
-- re-enter at their entry without replaying the prefix.
function SummaryPicturePlayer:updateFixed()
  if self._disposed then
    return
  end
  self._elapsed = self._elapsed + 1
  if self._cryDelayTicks ~= nil and not self._cryEmitted and self._elapsed >= math.max(self._cryDelayTicks, 1) then
    self._cryEmitted = true
    self._effects[#self._effects + 1] = { kind = "cry" }
  end
  self._remaining = self._remaining - 1
  if self._remaining > 0 then
    return
  end
  if self._index < #self._samples then
    self._index = self._index + 1
  elseif self._loopFrom ~= nil then
    self._index = self._loopFrom
  else
    self._remaining = 0
    return
  end
  local sample = assert(self._samples[self._index], "picture samples stay addressable")
  self._remaining = assert(sample.durationTicks, "picture samples carry a positive duration")
end

---@param blend unknown
---@return table<string, unknown>?
local function copyPaletteBlend(blend)
  if blend == nil then
    return nil
  end
  assert(type(blend) == "table", "picture blends are records")
  local coefficient = assert(blend.coefficient, "picture blends carry a coefficient")
  assert(type(coefficient) == "number" and coefficient % 1 == 0, "picture blend coefficients are integers")
  local target = assert(blend.target, "picture blends carry a target")
  assert(type(target) == "table", "picture blend targets are records")
  local channels = {}
  for _, channel in ipairs({ "r", "g", "b" }) do
    local value = assert(target[channel], "picture blend targets carry " .. channel)
    assert(
      type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 31,
      "picture blend targets stay 5-bit"
    )
    channels[channel] = value
  end
  return { coefficient = coefficient, target = { r = channels.r, g = channels.g, b = channels.b } }
end

-- The playback snapshot: one-based sample position, authored transformed
-- picture values with a detached palette-blend copy, and the owning
-- picture epoch.
---@return table<string, unknown>
function SummaryPicturePlayer:status()
  if self._disposed then
    return { epoch = self._epoch, disposed = true }
  end
  local sample = assert(self._samples[self._index], "picture samples stay addressable")
  return {
    sampleIndex = self._index,
    frameIndex = sample.frameIndex,
    offsetX = sample.offsetX,
    offsetY = sample.offsetY,
    scaleX = sample.scaleX,
    scaleY = sample.scaleY,
    rotationTurns = sample.rotationTurns,
    visible = sample.visible,
    paletteBlend = copyPaletteBlend(sample.paletteBlend),
    epoch = self._epoch,
  }
end

-- Transfers the queued one-shot cues once; drained cues never repeat.
---@return table[]
function SummaryPicturePlayer:takeEffects()
  local effects = self._effects
  self._effects = {}
  return effects
end

-- Idempotent release: pending cues are dropped and later updates stay quiet.
function SummaryPicturePlayer:dispose()
  self._effects = {}
  self._disposed = true
end

return SummaryPicturePlayer
