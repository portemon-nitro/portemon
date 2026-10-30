-- Sweet Scent task: the source Honey/Sweet Scent state machine over a host
-- seam. Unsuitable weather waits 20 ticks and reports the faded outcome;
-- otherwise the tint fades in with the scent sound, 22 ticks pass, and the
-- encounter roll either reports a started battle or fades the tint out and
-- reports nothing.
-- Source basis: the retail ROM's Honey and Sweet Scent task.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local SweetScentTask = require("libs.hgss.src.script.tasks.SweetScentTask")

local T = {}

local function rig(opts)
  local log = {}
  local host = {
    weatherSuitable = function()
      log[#log + 1] = "weather"
      return opts.suitable ~= false
    end,
    startTint = function(_, direction)
      log[#log + 1] = "tint:" .. direction
    end,
    tintDone = function()
      return opts.tintReady ~= false
    end,
    clearTint = function()
      log[#log + 1] = "clear"
    end,
    hasWildEncounters = function()
      return opts.hasWild ~= false
    end,
    encounter = function()
      log[#log + 1] = "encounter"
      return opts.battle == true
    end,
  }
  local audio = {
    play = function(_, sound)
      log[#log + 1] = "sound:" .. sound
    end,
  }
  return { services = { sweetScent = host, audio = audio } }, log
end

-- Polls until the task completes, returning its result and the tick count.
local function run(ctx, limit)
  local state = SweetScentTask.create({}, ctx)
  for tick = 1, limit or 200 do
    local outcome = SweetScentTask.poll(state, ctx)
    if outcome.complete then
      return outcome.result, tick, state
    end
    state = outcome.state
  end
  error("the sweet scent task never completed", 0)
end

function T.unsuitable_weather_waits_twenty_ticks_then_reports_the_faded_outcome()
  local ctx, log = rig({ suitable = false })
  local result, ticks = run(ctx)
  Assert.equal(result, SweetScentTask.OUTCOME_WEATHER)
  Assert.deepEqual(log, { "weather" }, "no tint or sound plays in unsuitable weather")
  Assert.equal(ticks, 22, "one check tick, a 20-tick wait that expires below zero, then the report")
end

function T.a_started_encounter_reports_battle_after_the_tint_and_the_wait()
  local ctx, log = rig({ battle = true })
  local result, ticks = run(ctx)
  Assert.equal(result, SweetScentTask.OUTCOME_BATTLE)
  Assert.deepEqual(log, { "weather", "tint:in", "sound:SEQ_SE_DP_FW230", "encounter" })
  Assert.isTrue(ticks >= 22, "the encounter waits out the tint and 22 ticks")
end

function T.no_encounter_fades_the_tint_out_and_reports_nothing()
  local ctx, log = rig({ battle = false })
  local result = run(ctx)
  Assert.equal(result, SweetScentTask.OUTCOME_NOTHING)
  Assert.deepEqual(log, { "weather", "tint:in", "sound:SEQ_SE_DP_FW230", "encounter", "tint:out", "clear" })
end

function T.a_map_without_wild_encounters_fades_out_without_waiting_or_rolling()
  local ctx, log = rig({ hasWild = false })
  local result, ticks = run(ctx)
  Assert.equal(result, SweetScentTask.OUTCOME_NOTHING)
  Assert.deepEqual(log, { "weather", "tint:in", "sound:SEQ_SE_DP_FW230", "tint:out", "clear" })
  local wildCtx = rig({ hasWild = true })
  local _, waited = run(wildCtx)
  Assert.isTrue(ticks < waited, "the 22-tick wait applies only to maps with wild encounters")
end

function T.the_wait_holds_until_the_tint_reports_done()
  local ctx = rig({ tintReady = false })
  local state = SweetScentTask.create({}, ctx)
  for _ = 1, 30 do
    local outcome = SweetScentTask.poll(state, ctx)
    Assert.isFalse(outcome.complete, "a running tint never lets the task finish")
    state = outcome.state
  end
end

function T.cancel_releases_the_tint_and_state_validates_as_a_table()
  local ctx, log = rig({})
  local state = SweetScentTask.create({}, ctx)
  SweetScentTask.poll(state, ctx)
  SweetScentTask.poll(state, ctx)
  SweetScentTask.cancel(state, "test", ctx)
  Assert.equal(log[#log], "clear")
  Assert.isNil(SweetScentTask.validate({}))
  Assert.isTrue(Errors.is(SweetScentTask.validate(
    ---@diagnostic disable-next-line: param-type-mismatch -- the failure branch requires a non-table state
    "x"
  )))
end

return { tests = T }
