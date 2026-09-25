-- Script runtime coverage for the field task: the pending node blocks on
-- the runtime-owned queue claim, while the explicit node forwards its
-- source move key and evaluated slot through the existing blocking
-- handoff. No HGSS policy executes in the generic runtime.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function runWith()
  local created = {}
  return {
    run = {
      instance = { scriptId = "test.field", locals = {}, textArgs = {} },
      node = { nodeId = "n1" },
      tick = 1,
      input = {},
      services = {},
      semantics = RuntimeValues,
      scheduler = {
        createTask = function(_, taskType, spec, _, _, _)
          created[#created + 1] = { taskType = taskType, spec = spec }
          return #created
        end,
      },
    },
    created = created,
  }
end

function T.pending_blocks_on_the_queued_claim()
  local fixture = runWith()
  local outcome = Runtime.executeNode({ op = "field_move", source = "pending" }, fixture.run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(#fixture.created, 1)
  Assert.equal(fixture.created[1].taskType, "field_move")
  Assert.equal(fixture.created[1].spec.source, "pending")
end

function T.explicit_forwards_move_and_slot_node()
  local fixture = runWith()
  local slot = { value = "var", id = "V_SLOT" }
  local outcome =
    Runtime.executeNode({ op = "field_move", source = "explicit", move = "surf", slot = slot }, fixture.run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(#fixture.created, 1)
  Assert.equal(fixture.created[1].taskType, "field_move")
  Assert.equal(fixture.created[1].spec.source, "explicit")
  Assert.equal(fixture.created[1].spec.node.move, "surf")
  Assert.equal(fixture.created[1].spec.node.slot, slot, "slot evaluation stays in the task")
end

function T.background_scripts_cannot_start_field_tasks()
  local fixture = runWith()
  fixture.run.instance.mode = "background"
  local ok, err = pcall(function()
    Runtime.executeNode({ op = "field_move", source = "pending" }, fixture.run)
  end)
  Assert.isFalse(ok, "background field tasks must fault")
  Assert.isTrue(Errors.is(err))
end

return { tests = T }
