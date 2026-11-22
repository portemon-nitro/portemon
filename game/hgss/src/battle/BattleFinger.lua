-- Catching-tutorial touch finger (battle_finger.c): armed over a control
-- with a 60-update touch delay, it bobs on an 18-update sine wave, presses
-- on the first wave wrap after the delay, and hides after its release.
local BattleFinger = {}

-- Update count from arming to the touch: the delay expires on update 60,
-- the next wave wrap (update 72) starts the press, and the press lands
-- four updates later (BattleFinger_Update touchAnimationState 0 to 1).
BattleFinger.TOUCH_TICKS = 76

local DELAY = 60
local WAVE = 18
local BOB_AMPLITUDE = 14

---@param updates integer bob updates applied since the last wave wrap
---@return integer upward pixel offset (GF_SinDegNoWrap times 14 in fx32)
local function bob(updates)
  local sinFx = math.floor(math.sin(math.rad((updates % WAVE) * 10)) * 4096 + 0.5)
  return math.floor(sinFx * BOB_AMPLITUDE / 4096)
end

-- Vertical offset of the finger after `ticks` updates since arming, or nil
-- once the release hides it (BattleFinger_Disable after touch state 3).
---@param ticks integer finger updates applied since arming
---@return integer? vertical pixel offset from the armed spot, nil when hidden
function BattleFinger.offset(ticks)
  assert(type(ticks) == "number" and ticks % 1 == 0 and ticks >= 0, "finger ticks stay whole and nonnegative")
  local pressStart = (math.floor(DELAY / WAVE) + 1) * WAVE
  if ticks < pressStart then
    return -bob(ticks)
  elseif ticks < BattleFinger.TOUCH_TICKS then
    return -bob(pressStart - 1)
  elseif ticks < BattleFinger.TOUCH_TICKS + 3 then
    return 8
  elseif ticks < BattleFinger.TOUCH_TICKS + 6 then
    return 2
  end
  return nil
end

return BattleFinger
