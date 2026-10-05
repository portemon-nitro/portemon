-- Blocks the source script through blackout recovery and its common child.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local WhiteoutTask = {}
WhiteoutTask.type = "whiteout"
WhiteoutTask.version = 1

function WhiteoutTask.create(_, ctx)
  local flow = assert(ctx.services.blackout, "blackout flow is unavailable")
  local travel = assert(ctx.services.travel, "field travel state is unavailable")
  return { phase = "flow", runId = flow:start(travel.lastHealSpawn) }
end

function WhiteoutTask.poll(state, ctx)
  local flow = assert(ctx.services.blackout, "blackout flow is unavailable")
  if state.phase == "flow" then
    flow:updateFixed(ctx.input)
    local status = flow:status()
    if status.error ~= nil then
      return { complete = true, state = state, result = { termination = "faulted", error = status.error } }
    end
    if not status.complete then
      return { complete = false, state = state }
    end
    local followup = flow:consumeResult(state.runId)
    assert(type(followup) == "string", "completed blackout supplies its canonical follow-up")
    local composed = ctx.scheduler:resolveComposition(followup)
    if composed == nil then
      Errors.raise(ScriptErrors.SCRIPT_CALL_TARGET_MISSING, "blackout common script is unavailable", {
        target = followup,
      })
    end
    local child = ctx.scheduler:createCommonChild(composed, {}, ctx)
    state.phase = "child"
    state.childInstanceId = child.instanceId
    return { complete = false, state = state }
  end

  local child = ctx.scheduler:instance(state.childInstanceId)
  if child == nil or child.status == "cancelled" then
    return { complete = true, state = state, result = { termination = "cancelled" } }
  end
  if child.status == "faulted" then
    return {
      complete = true,
      state = state,
      result = {
        termination = "faulted",
        error = Errors.new(ScriptErrors.SCRIPT_CALLER_SIGNAL_INVALID, "blackout follow-up common script faulted", {
          scriptId = child.scriptId,
          instanceId = child.instanceId,
          reason = child.endReason,
        }),
      },
    }
  end
  if child.status == "completed" then
    return { complete = true, state = state, result = { termination = "completed" } }
  end
  return { complete = false, state = state }
end

function WhiteoutTask.cancel(state, reason, ctx)
  state.cancelled = reason
  local flow = ctx and ctx.services and ctx.services.blackout
  if flow ~= nil then
    flow:cancel(state.runId)
  end
end

function WhiteoutTask.validate(state)
  if type(state) ~= "table" or type(state.runId) ~= "string" or state.runId == "" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "whiteout task state is invalid", context)
  end
  if state.phase ~= "flow" and state.phase ~= "child" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "whiteout task phase is invalid", context)
  end
  if state.phase == "child" and type(state.childInstanceId) ~= "string" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "whiteout child state is invalid", context)
  end
  return nil
end

return WhiteoutTask
