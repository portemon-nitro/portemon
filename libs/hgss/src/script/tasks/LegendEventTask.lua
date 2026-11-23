-- The blocking native legend-scene task: ScrCmd_ShowLegendaryWing,
-- ScrCmd_LanceFlyAway, ScrCmd_UnownCircle, ScrCmd_SinjohGetEggCutscene and
-- ScrCmd_Cinematic all return TRUE in the source, so one script-frame owner
-- holds the script until the scene returned. The task polls the field's one
-- legend scene owner and hands the wing effect's map child script to the
-- scheduler's existing common-child mechanism while the scene's loop clip
-- stays active; it never holds the child behind its own block, which is the
-- source's own deadlock.
--
-- The task is serializable only once COMPLETE: an active scene owns presented
-- models, a screen cover, an actor offset and a child context, and the
-- scheduler's restore hook carries no services, so a restored scene could not
-- drive or release them.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local LegendEventTask = {}
LegendEventTask.type = "legend_event"
LegendEventTask.version = 1

local PHASES = { wait = true, child = true, complete = true }
local CHILD_PHASES = { wait = true, child = true }

---@param ctx table<string, unknown>|nil
---@return table<string, unknown>
local function requireScene(ctx)
  assert(ctx ~= nil, "the legend scene task requires the task context")
  local services = assert(ctx.services, "the legend scene task requires its services")
  return assert(services.legendEvents, "legendEvents service is unavailable")
end

---@param spec { action: string, kind: integer?, choice: integer?, count: integer?, first: unknown?, second: unknown? }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function LegendEventTask.create(spec, ctx)
  assert(type(spec) == "table" and type(spec.action) == "string", "a legend scene task needs its source action")
  requireScene(ctx):begin(spec.action, {
    kind = spec.kind,
    choice = spec.choice,
    count = spec.count,
    first = spec.first,
    second = spec.second,
  })
  return {
    phase = "wait",
    action = spec.action,
    kind = spec.kind,
    choice = spec.choice,
    count = spec.count,
    first = spec.first,
    second = spec.second,
  }
end

-- Start the wing effect's map child through the existing common-child
-- mechanism and wait for it like any other common call: the wing scene resumes
-- only after the child cleared its caller signal or terminated.
---@private
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
local function startChild(state, ctx)
  local scene = requireScene(ctx)
  local scriptId = scene:childScriptId()
  if scriptId == nil then
    -- A map without a resolved script bank cannot name the child; the scene
    -- then finishes its own loop instead of blocking forever.
    state.phase = "wait"
    return { complete = false, state = state }
  end
  local composed = ctx.scheduler:resolveComposition(scriptId)
  if composed == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_CALL_TARGET_MISSING,
      "no composed script for " .. scriptId,
      { scriptId = ctx.instance.scriptId, target = scriptId }
    )
  end
  local child, slot, parentSlot = ctx.scheduler:createCommonChild(composed, {}, ctx)
  state.phase = "child"
  state.childInstanceId = child.instanceId
  state.childSlot = slot
  state.parentSlot = parentSlot
  return { complete = false, state = state }
end

-- The child handoff polls its own termination: the same protocol as the
-- translated `call_common` child_script task, driven by this scene's task so
-- the wing effect keeps its single script-frame owner.
---@private
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
local function pollChild(state, ctx)
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
        error = Errors.new(
          child.endReason or ScriptErrors.SCRIPT_CALLER_SIGNAL_INVALID,
          "legend scene child faulted: " .. tostring(child.endReason or "unknown"),
          { scriptId = child.scriptId, instanceId = child.instanceId, reason = child.endReason }
        ),
      },
    }
  end
  local signaled = ctx.environment:callerSignal(state.parentSlot) == false
  if signaled or child.status == "completed" then
    requireScene(ctx):childComplete()
    state.phase = "wait"
    state.childInstanceId = nil
    state.childSlot = nil
    state.parentSlot = nil
    return { complete = false, state = state }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
function LegendEventTask.poll(state, ctx)
  if state.phase == "complete" then
    return { complete = true, state = state, result = nil }
  end
  local scene = requireScene(ctx)
  if state.phase == "child" then
    return pollChild(state, ctx)
  end
  local status = scene:step()
  if status == "complete" then
    state.phase = "complete"
    return { complete = true, state = state, result = scene:takeResult() }
  end
  if status == "child" then
    return startChild(state, ctx)
  end
  return { complete = false, state = state }
end

-- Cancel the owned scene. The scene releases its presented models, its screen
-- cover and its actor offsets exactly once, so a cancelled scene leaves no
-- in-flight claim behind and a repeated cancellation is a clean no-op.
---@param state table<string, unknown>
---@param _ string?
---@param ctx table<string, unknown>|nil
function LegendEventTask.cancel(state, _, ctx)
  if state.phase == "complete" then
    return
  end
  state.phase = "complete"
  local services = ctx ~= nil and ctx.services or nil
  if services == nil or services.legendEvents == nil then
    return
  end
  services.legendEvents:cancel("the legend scene task was cancelled")
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function LegendEventTask.validate(state)
  if type(state) ~= "table" or PHASES[state.phase] ~= true or type(state.action) ~= "string" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "legend scene state is invalid", context)
  end
  if state.phase ~= "complete" then
    local context = { phase = state.phase, action = state.action }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "an active legend scene owns a presentation, a screen cover and a child context and cannot be restored",
      context
    )
  end
  if CHILD_PHASES[state.phase] ~= nil and state.childInstanceId ~= nil then
    local context = { phase = state.phase }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "a completed legend scene keeps no child", context)
  end
  return nil
end

return LegendEventTask
