-- Blocks source scripts until the field lifecycle reaches its stable phase.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local OverworldLifecycleTask = {}
OverworldLifecycleTask.type = "overworld_lifecycle"
OverworldLifecycleTask.version = 1

function OverworldLifecycleTask.create(spec, ctx)
  assert(spec.action == "leave" or spec.action == "restore", "overworld lifecycle action is invalid")
  local lifecycle = assert(ctx.services.overworld, "overworld service is unavailable")
  if spec.action == "leave" then
    lifecycle:requestLeave()
  else
    lifecycle:requestRestore()
  end
  return { action = spec.action }
end

function OverworldLifecycleTask.poll(state, ctx)
  local lifecycle = assert(ctx.services.overworld, "overworld service is unavailable")
  local phase, failure = lifecycle:phase()
  if failure ~= nil or phase == "failed" then
    local err = failure
      or Errors.new(ScriptErrors.SCRIPT_TASK_CALLBACK_FAULT, "overworld lifecycle failed", { phase = phase })
    return { complete = true, state = state, result = { termination = "faulted", error = err } }
  end
  local target = state.action == "leave" and "absent" or "present"
  if phase == target then
    return { complete = true, state = state, result = nil }
  end
  local expected = state.action == "leave" and "leaving" or "restoring"
  assert(phase == expected, "overworld lifecycle reached an unexpected phase: " .. tostring(phase))
  return { complete = false, state = state }
end

function OverworldLifecycleTask.cancel(state, reason)
  state.cancelled = reason
end

function OverworldLifecycleTask.validate(state)
  if type(state) ~= "table" or (state.action ~= "leave" and state.action ~= "restore") then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "overworld lifecycle task state is invalid", context)
  end
  return nil
end

return OverworldLifecycleTask
