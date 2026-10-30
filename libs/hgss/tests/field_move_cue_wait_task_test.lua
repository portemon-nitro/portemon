-- Field-move cue wait task: polls the cue service's blocking-cue completion
-- and keeps no state, so a save made mid-wait resumes against the live cue.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMoveCueWaitTask = require("libs.hgss.src.script.tasks.FieldMoveCueWaitTask")

local T = {}

local function ctxWith(finished)
  return {
    services = {
      fieldMoveCue = {
        isBlockingCueFinished = function()
          return finished
        end,
      },
    },
  }
end

function T.wait_completes_on_the_first_poll_after_the_cue_finishes()
  local state = FieldMoveCueWaitTask.create({}, ctxWith(false))
  Assert.isFalse(FieldMoveCueWaitTask.poll(state, ctxWith(false)).complete, "an unfinished cue keeps waiting")
  local done = FieldMoveCueWaitTask.poll(state, ctxWith(true))
  Assert.isTrue(done.complete, "the first finished poll completes")
  Assert.isNil(done.result)
end

function T.wait_state_validates_as_a_table_only()
  Assert.isNil(FieldMoveCueWaitTask.validate({}))
  local err = FieldMoveCueWaitTask.validate(
    ---@diagnostic disable-next-line: param-type-mismatch -- the failure branch requires a non-table state
    "not-a-table"
  )
  Assert.isTrue(Errors.is(err))
end

return { tests = T }
