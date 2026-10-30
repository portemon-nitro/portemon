-- field_move_cue_wait task implementation: blocks the script until the
-- field-move cue service reports its started blocking cue (cut-in or
-- follower gesture) finished. State is empty and therefore trivially
-- serializable: a save made while waiting resumes polling the live cue.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local FieldMoveCueWaitTask = {}

FieldMoveCueWaitTask.type = "field_move_cue_wait"
FieldMoveCueWaitTask.version = 1

---@param _ table<string, unknown>
---@return table<string, unknown> state
function FieldMoveCueWaitTask.create(_, _)
  return {}
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function FieldMoveCueWaitTask.poll(state, ctx)
  local cue = ctx.services and ctx.services.fieldMoveCue --[[@as RuntimeFieldMoveCue]]
  assert(cue and cue.isBlockingCueFinished, "field-move cue wait requires the cue service")
  if cue:isBlockingCueFinished() then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
function FieldMoveCueWaitTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function FieldMoveCueWaitTask.validate(state)
  if type(state) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "field-move cue wait state must be a table", context)
  end
  return nil
end

return FieldMoveCueWaitTask
