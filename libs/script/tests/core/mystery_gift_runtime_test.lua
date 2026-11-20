-- Script runtime coverage for the Mystery Gift queue query. This product
-- distributes no Mystery Gifts, so the source HAS_GIFT query answers the
-- FALSE convention through its declared destination and nothing else: the
-- executable part of the command never invents queued gift data.

local Assert = require("tests.support.Assert")
local Dsl = require("libs.script.src.Dsl")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local Validator = require("libs.script.src.Validator")

local T = {}

local function runWith()
  local vars = {}
  local world = {
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
    vars = vars,
  }
  return {
    instance = { scriptId = "test.mystery_gift", locals = {}, textArgs = {} },
    services = { world = world },
    semantics = RuntimeValues,
  },
    vars
end

function T.the_waiting_gift_query_validates_as_a_script_operation()
  local ok, err = Validator.validate(Dsl.script({
    api = 1,
    id = "test.mystery_gift_query",
    steps = {
      { op = "mystery_gift_has_gift", result = Dsl.var("VAR_MYSTERY_GIFT_CHECK") },
    },
  }))
  Assert.isTrue(ok, "the waiting-gift query is a valid operation: " .. tostring(err))
end

function T.the_waiting_gift_query_writes_false_before_the_runtime_continues()
  local run, vars = runWith()
  vars.VAR_MYSTERY_GIFT_CHECK = 9
  local outcome = Runtime.executeNode({
    op = "mystery_gift_has_gift",
    result = { value = "var", id = "VAR_MYSTERY_GIFT_CHECK" },
  }, run)
  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE)
  Assert.equal(vars.VAR_MYSTERY_GIFT_CHECK, 0, "no gift can wait without a distribution system")
end

return { tests = T }
