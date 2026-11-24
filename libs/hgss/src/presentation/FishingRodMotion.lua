-- The player's fishing rod animation (PlayerDraw_UpdateFishing in
-- src/field/map_object_billboard_motion.c): the fishing sprite holds one
-- 16-frame sequence per facing, and each rod motion steps that sequence's
-- frame once per field update. The cast plays it forward and holds the
-- line out; idle and reel draw it back to the first frame; a bite dips the
-- rod from the last frame to the tenth and back, then pauses 30 updates
-- before dipping again. Turning or changing motion restarts the motion.
-- The drawn rod also shifts the billboard per facing as the line goes out
-- (PlayerDraw_SetFishingOffset). Pure module: no love dependency.

---@alias FishingRodMotion.Motion "idle"|"cast"|"bite"|"reel"

---@class FishingRodMotion
---@field private _motion FishingRodMotion.Motion?
---@field private _facing string?
---@field private _frame integer the sequence frame, 0..15
---@field private _phase "dip"|"rise"|"pause"
---@field private _step integer the bite pause counter
local FishingRodMotion = {}
FishingRodMotion.__index = FishingRodMotion

local LAST_FRAME = 15
local BITE_LOW_FRAME = 10
local BITE_PAUSE = 30
local SOURCE_UNITS_PER_TILE = 16

local MOTIONS = { idle = true, cast = true, bite = true, reel = true }

-- The billboard sequence each facing plays (sPlayerFishingSequences); the
-- offset rule reads the frame across all four sequences.
local SEQUENCE_BY_FACING = { north = 0, south = 1, west = 2, east = 3 }

---@return FishingRodMotion
function FishingRodMotion.new()
  return setmetatable({ _motion = nil, _facing = nil, _frame = 0, _phase = "dip", _step = 0 }, FishingRodMotion)
end

-- Advances one field update under the current motion and facing.
---@param motion FishingRodMotion.Motion
---@param facing string
function FishingRodMotion:advance(motion, facing)
  assert(MOTIONS[motion] == true, "unknown rod motion " .. tostring(motion))
  assert(SEQUENCE_BY_FACING[facing] ~= nil, "the rod faces a cardinal direction")
  local restarted = motion ~= self._motion or facing ~= self._facing
  self._motion, self._facing = motion, facing
  if motion == "cast" then
    -- BillboardMotion_Loop: from the first frame, one frame per update,
    -- holding the line out at the sequence's end.
    if restarted then
      self._frame = 0
    end
    self._frame = math.min(LAST_FRAME, self._frame + 1)
    return
  end
  if motion == "bite" then
    if restarted then
      self._frame = LAST_FRAME
      self._phase = "dip"
    end
    if self._phase == "dip" then
      self._frame = self._frame - 1
      if self._frame <= BITE_LOW_FRAME then
        self._phase = "rise"
      end
    elseif self._phase == "rise" then
      self._frame = self._frame + 1
      if self._frame >= LAST_FRAME then
        self._phase = "pause"
        self._step = 0
      end
    else
      self._step = self._step + 1
      if self._step >= BITE_PAUSE then
        self._step = 0
        self._phase = "dip"
      end
    end
    return
  end
  -- BillboardMotion_Fall (idle and reel): from the last frame back to the
  -- first, then held.
  if restarted then
    self._frame = LAST_FRAME
  end
  self._frame = math.max(0, self._frame - 1)
end

---@return integer the sequence frame the rod shows, 0..15
function FishingRodMotion:frame()
  return self._frame
end

-- PlayerDraw_SetFishingOffset in tiles: facing south the rod pushes the
-- billboard toward the camera once the line is half out; facing west or
-- east it leans a unit back, then swings five units toward the water.
---@return number x, number z
function FishingRodMotion:offset()
  local facing = assert(self._facing, "the rod offset follows an advanced motion")
  local absolute = SEQUENCE_BY_FACING[facing] * (LAST_FRAME + 1) + self._frame
  local x, z = 0, 0
  if facing == "south" then
    if absolute >= 24 then
      z = 6
    end
  elseif facing == "west" then
    x = absolute < 40 and 1 or -5
  elseif facing == "east" then
    x = absolute < 56 and -1 or 5
  end
  return x / SOURCE_UNITS_PER_TILE, z / SOURCE_UNITS_PER_TILE
end

return FishingRodMotion
