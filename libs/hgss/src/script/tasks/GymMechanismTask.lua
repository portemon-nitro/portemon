-- The blocking gym mechanism task: one script-frame owner for the source's
-- native gym actions. ScrCmd_VioletGymElevator, ScrCmd_AzaleaGymSpinarak and
-- ScrCmd_AzaleaGymSwitch all return TRUE in the source, so the task holds the
-- script until the transport or the switch sound finished and only then lets
-- it resume; ScrCmd_*GymInit returns FALSE and never reaches this task.
--
-- The task is serializable only once COMPLETE. An active ride owns a player
-- transport lease, the follower's carried presentation and a source sound
-- sequence, and the scheduler's restore hook carries no services: a restored
-- ride could neither drive nor release them. Saving or capturing an active
-- ride is therefore refused with SCRIPT_TASK_UNSERIALIZABLE instead of faking
-- a restorable lease.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local GymMechanismTask = {}
GymMechanismTask.type = "gym_mechanism"
GymMechanismTask.version = 1

local PHASES = { wait = true, complete = true }

local function requireMechanism(ctx)
  assert(ctx ~= nil, "the gym mechanism task requires the task context")
  return assert(ctx.services.gymMechanism, "gymMechanism service is unavailable")
end

---@param spec { action: string, selector: integer?, switchNumber: integer? }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function GymMechanismTask.create(spec, ctx)
  assert(type(spec) == "table" and type(spec.action) == "string", "a gym mechanism task needs its source action")
  requireMechanism(ctx):begin(spec.action, { selector = spec.selector, switchNumber = spec.switchNumber })
  return { phase = "wait", action = spec.action, selector = spec.selector, switchNumber = spec.switchNumber }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
function GymMechanismTask.poll(state, ctx)
  if state.phase == "complete" then
    return { complete = true, state = state, result = nil }
  end
  local status = requireMechanism(ctx):step()
  if status ~= "complete" then
    return { complete = false, state = state }
  end
  state.phase = "complete"
  return { complete = true, state = state, result = nil }
end

-- Cancel the owned activation. The mechanism restores its own settled state,
-- so a cancelled ride leaves no in-flight claim behind and a repeated
-- cancellation is a clean no-op.
---@param state table<string, unknown>
---@param reason string?
---@param ctx table<string, unknown>?
function GymMechanismTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if state.phase == "complete" then
    return
  end
  state.phase = "complete"
  if ctx ~= nil and ctx.services ~= nil and ctx.services.gymMechanism ~= nil then
    ctx.services.gymMechanism:cancelRide(reason)
  end
end

---@param state table<string, unknown>
---@return unknown|nil
function GymMechanismTask.validate(state)
  if type(state) ~= "table" or PHASES[state.phase] ~= true or type(state.action) ~= "string" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "gym mechanism state is invalid", context)
  end
  if state.phase ~= "complete" then
    local context = { phase = state.phase, action = state.action }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "an active gym mechanism owns a transport, presentation and sound lease and cannot be restored",
      context
    )
  end
  return nil
end

return GymMechanismTask
