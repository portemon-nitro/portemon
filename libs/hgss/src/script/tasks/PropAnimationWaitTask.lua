-- Blocks until a retained one-shot prop animation completes.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local PropAnimationWaitTask = {}
PropAnimationWaitTask.type = "prop_animation_wait"
PropAnimationWaitTask.version = 1

function PropAnimationWaitTask.create(spec, ctx)
  assert(type(spec.slot) == "number", "prop animation wait requires a slot")
  local owner = assert(ctx.services.propAnimations, "propAnimations service is unavailable")
  owner:isFinished(spec.slot)
  return { slot = spec.slot }
end

function PropAnimationWaitTask.poll(state, ctx)
  local owner = assert(ctx.services.propAnimations, "propAnimations service is unavailable")
  if owner:isFinished(state.slot) then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

function PropAnimationWaitTask.cancel(state, reason)
  state.cancelled = reason
end

function PropAnimationWaitTask.validate(state)
  if type(state) ~= "table" or type(state.slot) ~= "number" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "prop animation wait state is invalid", context)
  end
  return nil
end

return PropAnimationWaitTask
