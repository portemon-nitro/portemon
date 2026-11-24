-- Fishing task: the retail fishing rod state machine (field/fishing.c) over a
-- host seam. The cast lasts 34 ticks with its sound on tick 10; an empty
-- line waits 120 ticks for a nibble; a hooked line bites after one to four
-- seconds and leaves the rod's reel window to press A; pressing early reels
-- in too soon. The follower's friendship decides who notices the bite and
-- its mood widens the reel window.

local Assert = require("tests.support.Assert")
local FishingTask = require("libs.hgss.src.script.tasks.FishingTask")

local T = {}

-- A scripted host: `rolls` are consumed in order by random draws.
local function rig(opts)
  local log = {}
  local rolls = opts.rolls or {}
  local host = {
    cast = function(_, rod)
      log[#log + 1] = "cast:" .. rod
      return opts.hooked == true
    end,
    setPose = function(_, mode)
      log[#log + 1] = "pose:" .. mode
    end,
    biteFacts = function()
      return {
        followerActive = opts.followerActive == true,
        surfing = opts.surfing == true,
        friendship = opts.friendship or 70,
        mood = opts.mood or 0,
      }
    end,
    random = function(_, bound)
      local roll = assert(table.remove(rolls, 1), "the rig ran out of random draws")
      assert(roll < bound, "a scripted roll stays below its bound")
      return roll
    end,
    showNotice = function(_, onFollower)
      log[#log + 1] = onFollower and "notice:follower" or "notice:player"
    end,
    clearNotice = function()
      log[#log + 1] = "clear"
    end,
    discardEncounter = function()
      log[#log + 1] = "discard"
    end,
    putAway = function()
      log[#log + 1] = "put_away"
    end,
  }
  local audio = {
    play = function(_, sound)
      log[#log + 1] = "sound:" .. sound
    end,
  }
  return { services = { fishing = host, audio = audio }, input = {} }, log
end

-- Polls the cast stage, pressing A on the listed ticks, until it completes.
local function cast(ctx, rod, pressTicks)
  local presses = {}
  for _, tick in ipairs(pressTicks or {}) do
    presses[tick] = true
  end
  local state = FishingTask.create({ stage = "cast", rod = rod }, ctx)
  for tick = 1, 400 do
    ctx.input = { pressedAction = presses[tick] == true }
    local outcome = FishingTask.poll(state, ctx)
    if outcome.complete then
      return outcome.result, tick
    end
    state = outcome.state
  end
  error("the fishing cast never completed", 0)
end

local function indexOf(log, entry)
  for index, value in ipairs(log) do
    if value == entry then
      return index
    end
  end
  return nil
end

function T.an_empty_line_waits_for_a_nibble_that_never_comes()
  local ctx, log = rig({ hooked = false })
  local outcome, ticks = cast(ctx, "old_rod")
  Assert.equal(outcome, FishingTask.OUTCOME_NO_BITE)
  -- One start tick, 34 cast ticks, then 120 ticks of waiting counted down
  -- from the cast's last tick.
  Assert.equal(ticks, 1 + 34 + 119)
  Assert.deepEqual(log, {
    "cast:old_rod",
    "pose:cast",
    "sound:SEQ_SE_DP_FW104",
    "pose:idle",
    "clear",
    "discard",
  })
end

function T.pressing_before_the_bite_reels_in_too_soon()
  local ctx, log = rig({ hooked = true, rolls = { 3 } })
  local outcome = cast(ctx, "good_rod", { 40 })
  Assert.equal(outcome, FishingTask.OUTCOME_TOO_SOON)
  Assert.isNil(indexOf(log, "pose:bite"), "the early press never sees a bite")
  Assert.notNil(indexOf(log, "discard"), "the unused encounter is dropped")
end

-- The bite comes (roll + 1) * 30 ticks after the cast; A inside the reel
-- window hooks the Pokemon and lands it sixteen ticks later.
function T.a_timely_press_after_the_bite_lands_the_pokemon()
  local ctx, log = rig({ hooked = true, rolls = { 0 } })
  -- The cast ends on tick 35 and counts the first bite tick there, so the
  -- 30-tick delay bites on tick 64.
  local outcome, ticks = cast(ctx, "super_rod", { 70 })
  Assert.equal(outcome, FishingTask.OUTCOME_LANDED)
  Assert.equal(ticks, 70 + 16)
  Assert.notNil(indexOf(log, "notice:player"), "a player without a follower notices the bite")
  Assert.isNil(indexOf(log, "discard"), "a landed Pokemon keeps its encounter")
  Assert.isTrue(indexOf(log, "pose:reel") > indexOf(log, "pose:bite"))
end

-- The Super Rod leaves 15 ticks to react; the miss is reported on the tick
-- after the window closes.
function T.a_missed_reel_window_lets_the_pokemon_get_away()
  local ctx = rig({ hooked = true, rolls = { 0 } })
  local outcome, ticks = cast(ctx, "super_rod")
  Assert.equal(outcome, FishingTask.OUTCOME_GOT_AWAY)
  Assert.equal(ticks, 64 + 15)
end

-- The follower's mood widens the Super Rod's 15-tick window by its bucket:
-- the bite lands on tick 64, so a press on tick 80 misses without a
-- follower but lands with a neutral one (+3), and a press on tick 84 lands
-- only for a cheerful one (50..99, +12) while a sour one (<= -10) adds
-- nothing.
function T.the_followers_mood_widens_the_reel_window()
  local alone = rig({ hooked = true, rolls = { 0 } })
  Assert.equal(cast(alone, "super_rod", { 80 }), FishingTask.OUTCOME_GOT_AWAY)
  local calm = rig({ hooked = true, rolls = { 0 }, followerActive = true, mood = 0 })
  Assert.equal(cast(calm, "super_rod", { 80 }), FishingTask.OUTCOME_LANDED, "a neutral mood adds 3 ticks")
  local happy = rig({ hooked = true, rolls = { 0 }, followerActive = true, mood = 60 })
  Assert.equal(cast(happy, "super_rod", { 84 }), FishingTask.OUTCOME_LANDED)
  local sullen = rig({ hooked = true, rolls = { 0 }, followerActive = true, mood = -20 })
  Assert.equal(cast(sullen, "super_rod", { 80 }), FishingTask.OUTCOME_GOT_AWAY, "a sour mood adds nothing")
end

-- A follower with at least 100 friendship may notice the bite itself; the
-- chance rises with friendship, and a surfing player always notices.
function T.a_friendly_follower_notices_the_bite()
  local friendly, friendlyLog = rig({ hooked = true, rolls = { 0, 49 }, followerActive = true, friendship = 255 })
  cast(friendly, "old_rod", { 70 })
  Assert.notNil(indexOf(friendlyLog, "notice:follower"), "a 49 roll is inside the 50% band")
  local shy, shyLog = rig({ hooked = true, rolls = { 0, 20 }, followerActive = true, friendship = 120 })
  cast(shy, "old_rod", { 70 })
  Assert.notNil(indexOf(shyLog, "notice:player"), "a 20 roll misses the 20% band")
  local cold, coldLog = rig({ hooked = true, rolls = { 0 }, followerActive = true, friendship = 99 })
  cast(cold, "old_rod", { 70 })
  Assert.notNil(indexOf(coldLog, "notice:player"), "below 100 friendship never rolls")
  local surf, surfLog = rig({ hooked = true, rolls = { 0 }, followerActive = true, friendship = 255, surfing = true })
  cast(surf, "old_rod", { 70 })
  Assert.notNil(indexOf(surfLog, "notice:player"), "a surfing player notices the bite")
end

function T.putting_away_stows_the_rod_over_three_ticks()
  local ctx, log = rig({})
  local state = FishingTask.create({ stage = "put_away" }, ctx)
  local ticks = 0
  repeat
    ticks = ticks + 1
    local outcome = FishingTask.poll(state, ctx)
    state = outcome.state
  until outcome.complete
  Assert.equal(ticks, 4)
  Assert.deepEqual(log, { "put_away" })
end

-- A cancelled cast drops its prepared encounter and stows the rod through
-- the live host, and never polls again.
function T.cancelling_a_cast_stows_the_rod_and_drops_the_encounter()
  local ctx, log = rig({ hooked = true, rolls = { 0 } })
  local state = FishingTask.create({ stage = "cast", rod = "old_rod" }, ctx)
  state = FishingTask.poll(state, ctx).state
  Assert.isNil(FishingTask.validate(state))
  FishingTask.cancel(state, "teardown", ctx)
  Assert.equal(log[#log - 1], "discard")
  Assert.equal(log[#log], "put_away")
  Assert.throws(function()
    FishingTask.poll(state, ctx)
  end)
end

return { tests = T }
