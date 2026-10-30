-- The field-move cue service on the script services seam: the one place the
-- field-move scripts hand their presentation cues to (move cut-in, the
-- Cut/Rock Smash/Strength/Headbutt effect, follower gestures, emote marks).
-- Blocking cues (cut-in, follower gestures, emote marks) stay pending until
-- the presentation reports them finished through finishBlockingCue; effects
-- stay pending until the presentation completes them through finishEffects,
-- which fires each startEffect callback exactly once for the script's polled
-- done variable. Headless tests and acceptance harnesses stand in for the
-- presentation by finishing while stepping. addFollowerMood is immediate.
-- Effect kinds 0..5 mirror the source Task_ScriptFieldMoveEffect dispatch:
-- 0 Cut at the player, 1 Rock Smash at the player, 2 Rock Smash at the
-- follower, 3 Cut at the follower, 4 Headbutt at the player, 5 Headbutt at
-- the follower. Gestures mirror the source follower interaction tasks:
-- jump (a = repeats), grow_shrink, flash (a = step, b = period). The emote
-- mark mirrors field_emote_mark.c: the exclamation over a smashed rock.

local FieldMoveCue = {}
FieldMoveCue.__index = FieldMoveCue

local GESTURES = { jump = true, grow_shrink = true, flash = true }
local EFFECT_KIND_COUNT = 6

---@return table
function FieldMoveCue.new()
  return setmetatable({ _blocking = false, _pendingEffects = {} }, FieldMoveCue)
end

-- Play the move user's cut-in for a zero-based party slot. The cue stays
-- blocking until the presentation reports it finished.
---@param partySlot integer
function FieldMoveCue:startCutIn(partySlot)
  assert(
    type(partySlot) == "number" and partySlot % 1 == 0 and partySlot >= 0 and partySlot <= 5,
    "cut-in requires a zero-based party slot"
  )
  self._blocking = true
end

-- Play one follower gesture: jump (a = repeats), grow_shrink, flash (a = step, b = period).
-- The cue stays blocking until the presentation reports it finished.
---@param gesture string
---@param _ integer?
function FieldMoveCue:startFollowerGesture(gesture, _, _)
  assert(GESTURES[gesture] == true, "unknown follower gesture " .. tostring(gesture))
  self._blocking = true
end

-- Start effect kind 0..5. The presentation completes it later through
-- finishEffects, which fires onFinished exactly once.
---@param effect integer
---@param onFinished fun()
function FieldMoveCue:startEffect(effect, onFinished)
  assert(
    type(effect) == "number" and effect % 1 == 0 and effect >= 0 and effect < EFFECT_KIND_COUNT,
    "unknown field-move effect " .. tostring(effect)
  )
  assert(type(onFinished) == "function", "an effect needs its completion callback")
  self._pendingEffects[#self._pendingEffects + 1] = onFinished
end

-- Complete every pending effect exactly once. A presentation stand-in calls
-- this while stepping; without a presentation the done variable stays clear.
function FieldMoveCue:finishEffects()
  local pending = self._pendingEffects
  self._pendingEffects = {}
  for _, onFinished in ipairs(pending) do
    onFinished()
  end
end

---@return integer the number of effects waiting for the presentation
function FieldMoveCue:pendingEffectCount()
  return #self._pendingEffects
end

-- Play the emote mark over the move user: the follower when it used the
-- move, else the player. The cue stays blocking until the presentation
-- reports it finished.
---@param onFollower boolean
function FieldMoveCue:startEmoteMark(onFollower)
  assert(type(onFollower) == "boolean", "the emote mark names its subject")
  self._blocking = true
end

---@param amount integer
function FieldMoveCue:addFollowerMood(amount)
  assert(type(amount) == "number" and amount % 1 == 0, "follower mood amount must be an integer")
end

-- Report a started blocking cue finished. Idempotent: stands in for the
-- presentation, which calls this once its animation reports done.
function FieldMoveCue:finishBlockingCue()
  self._blocking = false
end

---@return boolean
function FieldMoveCue:isBlockingCueFinished()
  return not self._blocking
end

return FieldMoveCue
