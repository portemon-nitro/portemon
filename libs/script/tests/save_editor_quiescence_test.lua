-- Tests the shape-only empty continuation predicate used by save migration.

local Assert = require("tests.support.Assert")
local ScriptSave = require("libs.script.src.ScriptSave")

local T = {}

function T.quiescence_requires_three_present_empty_tables()
  local empty = { environments = {}, instances = {}, tasks = {} }
  Assert.isTrue(ScriptSave.isQuiescent(empty))
  Assert.isFalse(ScriptSave.isQuiescent(nil))
  Assert.isFalse(ScriptSave.isQuiescent({}))
  Assert.isFalse(ScriptSave.isQuiescent({ environments = false, instances = {}, tasks = {} }))

  for _, name in ipairs({ "environments", "instances", "tasks" }) do
    local live = { environments = {}, instances = {}, tasks = {} }
    live[name][1] = true
    Assert.isFalse(ScriptSave.isQuiescent(live), name .. " must be empty")
  end
end

return { tests = T }
