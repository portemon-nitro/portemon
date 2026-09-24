-- Script runtime coverage for the durable badge progression operations:
-- semantic nodes evaluate their badge operand, call exactly one named
-- operation on the required injected progression service, and write the
-- source result convention (1 or 0 for the check, the exact owned count
-- for the counter). Awards are idempotent. A missing service is an
-- attributed fault, never a read of zero badges.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local S = require("gen4.script")

local T = {}

local function progression()
  return PlayerProgression.new({ name = "GOLD", gender = 0, trainerId = 0, money = 3000, badges = 0 })
end

local function runWith(service)
  local world = {
    vars = {},
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  local services = { world = world }
  if service ~= nil then
    services.progression = service
  end
  return {
    instance = { scriptId = "test.progression", locals = {}, textArgs = {} },
    services = services,
    semantics = RuntimeValues,
  }
end

local function var(id)
  return { value = "var", id = id }
end

function T.check_award_and_count_round_trip_through_real_progression()
  local service = progression()
  local run = runWith(service)
  Assert.equal(
    Runtime.executeNode({ op = "check_badge", badge = "hive", result = var("V_CHECK") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.V_CHECK, 0)
  Assert.equal(Runtime.executeNode({ op = "award_badge", badge = "hive" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(
    Runtime.executeNode({ op = "check_badge", badge = "hive", result = var("V_CHECK") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.V_CHECK, 1)
  Assert.equal(Runtime.executeNode({ op = "count_badges", result = var("V_COUNT") }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(run.services.world.vars.V_COUNT, 1)
  Assert.equal(Runtime.executeNode({ op = "award_badge", badge = "hive" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "count_badges", result = var("V_COUNT") }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(run.services.world.vars.V_COUNT, 1, "a repeated award counts once")
end

function T.missing_progression_service_raises()
  local run = runWith(nil)
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "check_badge", badge = "hive", result = var("V_CHECK") }, run)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

function T.constructors_emit_valid_nodes()
  local check = S.checkBadge({ badge = "fog", result = S.var("V") })
  Assert.equal(check.op, "check_badge")
  local award = S.awardBadge({ badge = "storm" })
  Assert.equal(award.op, "award_badge")
  local count = S.countBadges({ result = S.var("V") })
  Assert.equal(count.op, "count_badges")
  local script = S.script({ api = 1, id = "test.badges", steps = { check, award, count } })
  Assert.isTrue(S.validate(script))
  local bad = S.script({
    api = 1,
    id = "test.badges-bad",
    steps = { { op = "check_badge", badge = "fog" } },
  })
  Assert.isNil(S.validate(bad))
end

return { tests = T }
