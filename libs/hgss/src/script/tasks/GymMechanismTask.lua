-- The blocking native field action task: one script-frame owner for the
-- source's native gym and Rocket-hideout operations. ScrCmd_VioletGymElevator,
-- ScrCmd_AzaleaGymSpinarak, ScrCmd_AzaleaGymSwitch,
-- ScrCmd_EcruteakGymExtinguishCandle, ScrCmd_CianwoodGymTurnWinch,
-- ScrCmd_PlayTrapEffect and ScrCmd_PlayHideoutAlarm all return TRUE in the
-- source, so the task holds the script until the transport, the switch sound,
-- the candle task, the winch cutscene, the trap clips or the alarm finished and
-- only then lets it resume; the init commands and the candle binding commands
-- return FALSE and never reach this task.
--
-- Each action names the one owner that drives it: the gym mechanism owns the
-- five gym operations, and the Rocket hideout effect owner owns the trap and the
-- alarm. Both publish the same closed protocol (begin/step/takeResult/
-- cancelRide), so this task stays the single scheduler adapter for either.
--
-- The winch answers its own output variable, so a completed mechanism hands the
-- source boolean back with its completion and the scheduler writes it before
-- the next command runs.
--
-- The task is serializable only once COMPLETE. An active ride owns a player
-- transport lease, the follower's carried presentation, a source sound sequence
-- or a presented model, and the scheduler's restore hook carries no services: a
-- restored ride could neither drive nor release them. Saving or capturing an
-- active ride is therefore refused with SCRIPT_TASK_UNSERIALIZABLE instead of
-- faking a restorable lease.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local GymMechanismTask = {}
GymMechanismTask.type = "gym_mechanism"
GymMechanismTask.version = 1

local PHASES = { wait = true, complete = true }

-- The Rocket hideout's two blocking native effects, driven by the field's own
-- Rocket effect owner instead of the gym mechanism union.
local ROCKET_ACTIONS = { rocket_trap = true, rocket_alarm = true }

---@param ctx table<string, unknown>|nil
---@param action string? closed source action name
---@return table<string, unknown>
local function requireMechanism(ctx, action)
  assert(ctx ~= nil, "the gym mechanism task requires the task context")
  local services = assert(ctx.services, "the gym mechanism task requires its services")
  if action ~= nil and ROCKET_ACTIONS[action] == true then
    return assert(services.rocketHideout, "rocketHideout service is unavailable")
  end
  return assert(services.gymMechanism, "gymMechanism service is unavailable")
end

---@param spec { action: string, selector: integer?, switchNumber: integer?, useLastInteracted: boolean?, lastInteractedActor: string?, kind: integer? }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function GymMechanismTask.create(spec, ctx)
  assert(type(spec) == "table" and type(spec.action) == "string", "a gym mechanism task needs its source action")
  requireMechanism(ctx, spec.action):begin(spec.action, {
    selector = spec.selector,
    switchNumber = spec.switchNumber,
    useLastInteracted = spec.useLastInteracted,
    lastInteractedActor = spec.lastInteractedActor,
    kind = spec.kind,
    choice = spec.choice,
  })
  return {
    phase = "wait",
    action = spec.action,
    selector = spec.selector,
    switchNumber = spec.switchNumber,
    kind = spec.kind,
    choice = spec.choice,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
function GymMechanismTask.poll(state, ctx)
  if state.phase == "complete" then
    return { complete = true, state = state, result = nil }
  end
  local mechanism = requireMechanism(ctx, state.action)
  local status = mechanism:step()
  if status ~= "complete" then
    return { complete = false, state = state }
  end
  state.phase = "complete"
  return { complete = true, state = state, result = mechanism:takeResult() }
end

-- Cancel the owned activation. The owning mechanism restores its own settled
-- state, so a cancelled ride leaves no in-flight claim behind and a repeated
-- cancellation is a clean no-op.
---@param state table<string, unknown>
---@param reason string?
---@param ctx table<string, unknown>|nil
function GymMechanismTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if state.phase == "complete" then
    return
  end
  state.phase = "complete"
  local services = ctx ~= nil and ctx.services or nil
  if services == nil then
    return
  end
  local action = state.action
  if type(action) == "string" and ROCKET_ACTIONS[action] == true then
    if services.rocketHideout ~= nil then
      services.rocketHideout:cancelRide(reason)
    end
    return
  end
  if services.gymMechanism ~= nil then
    services.gymMechanism:cancelRide(reason)
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
      "an active native field action owns a transport, presentation and sound lease and cannot be restored",
      context
    )
  end
  return nil
end

return GymMechanismTask
