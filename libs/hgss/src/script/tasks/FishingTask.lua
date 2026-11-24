-- fishing task implementation: the retail fishing rod (field/fishing.c), one
-- state per poll at the source tick. The cast stage rolls the encounter as
-- the line goes out, casts for 34 ticks (the cast sound on tick 10), then
-- either waits 120 ticks for a nibble that never comes or waits one to four
-- seconds for the bite and gives the player the rod's reel window to press
-- A; pressing early reels in too soon. The outcome code is written for the
-- script, which prints the result before the put_away stage stows the rod.
--
-- Friendship with the party lead shapes the bite: while the follower walks
-- beside a player who is not surfing, a lead with at least 100 friendship
-- may notice the bite itself (20/30/40/50% by friendship band) and shows
-- the "!" instead of the player, and the follower's mood widens the reel
-- window. The encounter roll's friendship bite bonus lives with the
-- encounter rate. The host seam (services.fishing) owns the encounter, the
-- rod pose, the emote, and random draws. Pure domain module: no love
-- dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local FishingTask = {}

FishingTask.type = "fishing"
FishingTask.version = 1

-- Script-visible outcome codes.
FishingTask.OUTCOME_NO_BITE = 0
FishingTask.OUTCOME_TOO_SOON = 1
FishingTask.OUTCOME_GOT_AWAY = 2
FishingTask.OUTCOME_LANDED = 3

local CAST_SOUND = "SEQ_SE_DP_FW104"
local CAST_SOUND_TICK = 10
local CAST_TICKS = 34
local NO_BITE_TICKS = 120
local LANDED_TICKS = 15
local PUT_AWAY_TICKS = 2

-- sReelWindow: ticks to press A after the bite, per rod.
local REEL_WINDOW = { old_rod = 45, good_rod = 30, super_rod = 15 }

-- sMoodReelBonus: extra reel ticks per follower mood bucket, per rod.
local MOOD_REEL_BONUS = {
  { old_rod = 0, good_rod = 0, super_rod = 0 },
  { old_rod = 9, good_rod = 6, super_rod = 3 },
  { old_rod = 15, good_rod = 12, super_rod = 6 },
  { old_rod = 21, good_rod = 18, super_rod = 9 },
  { old_rod = 30, good_rod = 24, super_rod = 12 },
}

local function host(ctx)
  local services = assert(ctx.services, "fishing requires its services")
  local fishing = services.fishing
  if fishing == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "fishing requires its host service", {})
  end
  return fishing --[[@as table<string, unknown>]]
end

-- FishingRod_GetMoodReelBonus: the follower's mood bucket.
---@param mood integer
---@return integer bucket one-based
local function moodBucket(mood)
  if mood <= -10 then
    return 1
  elseif mood <= 9 then
    return 2
  elseif mood < 50 then
    return 3
  elseif mood < 100 then
    return 4
  end
  return 5
end

-- FishingRod_RollFriendshipNotice: the percent chance the lead notices the
-- bite, nil below 100 friendship.
---@param friendship integer
---@return integer?
local function noticeChance(friendship)
  if friendship <= 99 then
    return nil
  elseif friendship <= 149 then
    return 20
  elseif friendship <= 199 then
    return 30
  elseif friendship <= 249 then
    return 40
  end
  return 50
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function FishingTask.create(spec, ctx)
  host(ctx)
  assert(type(spec) == "table", "fishing requires a task spec")
  if spec.stage == "put_away" then
    return { stage = "put_away", phase = "put_away", timer = 0 }
  end
  assert(spec.stage == "cast", "fishing stages are cast and put_away")
  assert(REEL_WINDOW[spec.rod] ~= nil, "fishing names a known rod")
  return { stage = "cast", rod = spec.rod, phase = "start", timer = 0 }
end

local function running(state)
  return { complete = false, state = state }
end

local function finish(state, outcome)
  return { complete = true, state = state, result = outcome }
end

-- The early press and the missed bite drop the rod to its idle pose; a
-- line that hooked nothing leaves no prepared encounter behind.
local function fail(state, fishing, outcome)
  fishing:setPose("idle")
  fishing:clearNotice()
  fishing:discardEncounter()
  return finish(state, outcome)
end

-- The cast-stage states (sFishingRodStates). Each answers a finished
-- result, or nil plus whether the next state runs in the same tick, as the
-- source state functions return nonzero to do.
local CAST_STATES = {}

function CAST_STATES.start(state, fishing)
  state.hooked = fishing:cast(state.rod) == true
  fishing:setPose("cast")
  state.phase = "cast"
  return nil, false
end

function CAST_STATES.cast(state, _, ctx)
  state.timer = state.timer + 1
  if state.timer == CAST_SOUND_TICK then
    assert(ctx.services.audio, "fishing plays its cast through the audio service"):play(CAST_SOUND)
  end
  if state.timer < CAST_TICKS then
    return nil, false
  end
  state.timer = 0
  state.phase = state.hooked and "setup_bite" or "setup_no_bite"
  return nil, true
end

function CAST_STATES.setup_bite(state, fishing)
  local facts = fishing:biteFacts()
  state.biteDelay = (fishing:random(4) + 1) * 30
  state.reelWindow = REEL_WINDOW[state.rod]
  if facts.followerActive then
    state.reelWindow = state.reelWindow + MOOD_REEL_BONUS[moodBucket(facts.mood)][state.rod]
  end
  state.phase = "wait_bite"
  return nil, true
end

function CAST_STATES.wait_bite(state, fishing, _, aPressed)
  state.biteDelay = state.biteDelay - 1
  if aPressed then
    return fail(state, fishing, FishingTask.OUTCOME_TOO_SOON), false
  end
  if state.biteDelay > 0 then
    return nil, false
  end
  fishing:setPose("bite")
  local facts = fishing:biteFacts()
  local onFollower = false
  if facts.followerActive and not facts.surfing then
    local chance = noticeChance(facts.friendship)
    onFollower = chance ~= nil and fishing:random(100) < chance
  end
  fishing:showNotice(onFollower)
  state.phase = "wait_reel"
  return nil, true
end

function CAST_STATES.wait_reel(state, fishing, _, aPressed)
  state.reelWindow = state.reelWindow - 1
  if aPressed then
    fishing:clearNotice()
    fishing:setPose("reel")
    state.timer = 0
    state.phase = "hooked"
    return nil, false
  end
  if state.reelWindow > 0 then
    return nil, false
  end
  state.phase = "got_away"
  return nil, false
end

function CAST_STATES.got_away(state, fishing)
  return fail(state, fishing, FishingTask.OUTCOME_GOT_AWAY), false
end

function CAST_STATES.hooked(state)
  state.timer = state.timer + 1
  if state.timer > LANDED_TICKS then
    return finish(state, FishingTask.OUTCOME_LANDED), false
  end
  return nil, false
end

function CAST_STATES.setup_no_bite(state)
  state.timer = NO_BITE_TICKS
  state.phase = "wait_no_bite"
  return nil, true
end

function CAST_STATES.wait_no_bite(state, fishing, _, aPressed)
  state.timer = state.timer - 1
  if aPressed then
    return fail(state, fishing, FishingTask.OUTCOME_TOO_SOON), false
  end
  if state.timer ~= 0 then
    return nil, false
  end
  return fail(state, fishing, FishingTask.OUTCOME_NO_BITE), false
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
local function pollCast(state, ctx)
  local fishing = host(ctx)
  local input = ctx.input or {}
  local aPressed = input.pressedAction == true
  while true do
    local step = assert(CAST_STATES[state.phase], "unknown fishing phase " .. tostring(state.phase))
    local result, again = step(state, fishing, ctx, aPressed)
    if result ~= nil then
      return result
    end
    if not again then
      return running(state)
    end
  end
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function FishingTask.poll(state, ctx)
  assert(type(state) == "table", "fishing polls its state")
  if state.cancelled ~= nil then
    error("cancelled fishing tasks never poll again", 0)
  end
  if state.stage == "cast" then
    return pollCast(state, ctx)
  end
  local fishing = host(ctx)
  if state.phase == "put_away" then
    fishing:putAway()
    state.phase = "wait_put_away"
    return running(state)
  end
  state.timer = state.timer + 1
  if state.timer > PUT_AWAY_TICKS then
    return finish(state, nil)
  end
  return running(state)
end

-- A cancelled cast stows the rod at once and drops any prepared encounter
-- through the live host; without a context it only marks serializable state.
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>?
function FishingTask.cancel(state, reason, ctx)
  assert(type(state) == "table", "fishing cancel requires its state")
  if ctx ~= nil and ctx.services ~= nil and ctx.services.fishing ~= nil then
    local fishing = ctx.services.fishing
    fishing:discardEncounter()
    fishing:putAway()
  end
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function FishingTask.validate(state)
  if type(state) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "fishing state must be a table", context)
  end
  return nil
end

return FishingTask
