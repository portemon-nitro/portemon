-- Script runtime coverage for the source game-score event: the node names one
-- score event from the game-stats owner's authoritative table, delegates the
-- award to that owner in the same tick, and never carries a score amount of
-- its own. A missing owner is an attributed fault, and a step that supplies
-- points is not a valid script.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local S = require("gen4.script")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

local function runWith(services)
  return {
    instance = { scriptId = "test.score", locals = {}, textArgs = {} },
    services = services,
    semantics = RuntimeValues,
  }
end

local function recordingOwner()
  local owner = { awards = {} }
  function owner:awardScriptScoreEvent(eventId)
    self.awards[#self.awards + 1] = eventId
  end
  return owner
end

function T.game_score_event_awards_its_source_event_in_the_same_tick()
  local stats = recordingOwner()
  local run = runWith({ gameStats = stats })
  for _, event in ipairs({ 0, 1, 21, 26, 31, 39 }) do
    Assert.equal(
      Runtime.executeNode({ op = "game_score_event", event = event }, run),
      Runtime.OUTCOME_CONTINUE,
      "the source command returns in the same tick"
    )
  end
  Assert.deepEqual(stats.awards, { 0, 1, 21, 26, 31, 39 }, "each node awards its own source event exactly once")
end

function T.game_score_event_without_a_stats_owner_faults()
  local run = runWith({})
  local ok, err = pcall(function()
    Runtime.executeNode({ op = "game_score_event", event = 1 }, run)
  end)
  Assert.isFalse(ok, "a scripted score never succeeds without the stats owner")
  Assert.isTrue(Errors.is(err), "the missing owner is an attributed fault: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, ScriptErrors.SCRIPT_SERVICE_MISSING, "the fault names the missing service")
end

function T.game_score_event_carries_a_source_event_index_only()
  local function validate(eventFields)
    local step = { op = "game_score_event" }
    for key, value in pairs(eventFields) do
      step[key] = value
    end
    return S.validate({ api = 1, id = "test.score_schema", steps = { step } })
  end
  Assert.equal(validate({ event = 21 }), true, "a source event index is a valid step")
  local ok, err = validate({ event = 21, points = 20 })
  Assert.isNil(ok, "no script supplies its own score amount, got: " .. tostring(err))
  ok, err = validate({})
  Assert.isNil(ok, "the source event index is required, got: " .. tostring(err))
  ok, err = validate({ event = "21" })
  Assert.isNil(ok, "the source event index is an integer, got: " .. tostring(err))
end

return { tests = T }
