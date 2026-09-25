-- Field-move scheduler task: advances one concrete field operation
-- through the existing foreground scheduler. Creation takes the queued
-- runtime-owned request or plans an explicit script-origin request, then
-- validates foreground ownership; each poll advances once through the
-- runtime; completion reports done/refused/failed through the task
-- protocol while program errors fault visibly. Cancel releases motion and
-- plan state through the scheduler context exactly once and never polls
-- again; without a context it only marks serializable state for the
-- composition disposal backstop. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local FieldMoveTask = {}

FieldMoveTask.type = "field_move"
FieldMoveTask.version = 1

-- The closed executable plan union shared with the runtime. Refused
-- decisions complete as results; only these kinds execute.
local PLAN_KINDS = {
  cut = true,
  smash = true,
  enable_strength = true,
  push_strength = true,
  flash = true,
}

local function fieldMoves(ctx)
  local services = assert(ctx.services, "field task requires its services")
  local runtime = services.fieldMoves
  assert(runtime ~= nil, "field task requires the field runtime service")
  return runtime
end

local function hasFunction(value)
  if type(value) == "function" then
    return true
  end
  if type(value) == "table" then
    for _, child in pairs(value) do
      if hasFunction(child) then
        return true
      end
    end
  end
  return false
end

local function checkPlan(plan)
  if type(plan) ~= "table" or not PLAN_KINDS[plan.kind] then
    return false
  end
  if type(plan.mapId) ~= "number" then
    return false
  end
  if plan.committed ~= true and plan.committed ~= false then
    return false
  end
  if plan.target ~= nil then
    if type(plan.target) ~= "table" or type(plan.target.actorId) ~= "string" then
      return false
    end
  end
  return not hasFunction(plan)
end

---@param spec table<string, unknown> { source = "pending" } or { source = "explicit", node }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function FieldMoveTask.create(spec, ctx)
  assert(type(spec) == "table", "field task requires its spec")
  local runtime = fieldMoves(ctx)
  local request
  if spec.source == "pending" then
    request = runtime:takePending()
  elseif spec.source == "explicit" then
    local node = assert(spec.node, "explicit field task requires its graph node")
    assert(type(node.move) == "string" and node.move ~= "", "explicit field task needs its move key")
    local run = { services = ctx.services, instance = ctx.instance, semantics = ctx.semantics }
    local slot = ctx.semantics.evaluateValue(node.slot, run)
    assert(type(slot) == "number" and slot % 1 == 0 and slot >= 0 and slot <= 5, "explicit field slot must be 0-5")
    request = { move = node.move, slot = slot, partyRevision = nil, context = nil }
    local admitted = runtime:queue(request)
    if admitted.kind ~= "accepted" then
      local context = { move = node.move, decision = admitted.kind }
      ---@cast context Errors.Context
      Errors.raise(
        ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
        "explicit field admission refused: " .. tostring(admitted.kind),
        context
      )
    end
    request = runtime:takePending()
  else
    error("unknown field task source " .. tostring(spec.source), 0)
  end
  local plan = runtime:plan(request)
  if not checkPlan(plan) then
    return { refused = plan }
  end
  return { plan = plan }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function FieldMoveTask.poll(state, ctx)
  assert(type(state) == "table", "field task polls its state")
  if state.cancelled ~= nil then
    error("cancelled field tasks never poll again", 0)
  end
  if state.refused ~= nil then
    return { complete = true, state = state, result = { kind = "field_move_refused", decision = state.refused } }
  end
  local plan = assert(state.plan, "active field task requires its plan")
  local outcome = fieldMoves(ctx):advance(plan)
  assert(type(outcome.kind) == "string", "runtime advance returns a tagged outcome")
  if outcome.kind == "running" then
    return { complete = false, state = state }
  end
  if outcome.kind == "done" then
    return { complete = true, state = state, result = { kind = "field_move_done", move = plan.kind } }
  end
  assert(outcome.kind == "failed", "unknown runtime outcome " .. tostring(outcome.kind))
  return { complete = true, state = state, result = { kind = "field_move_failed", error = outcome.error } }
end

-- Cancel through the live scheduler context when present; otherwise mark
-- serializable state only. Cancelled tasks are never polled again, so
-- cleanup never depends on a later poll.
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>?
function FieldMoveTask.cancel(state, reason, ctx)
  assert(type(state) == "table", "field cancel requires its state")
  assert(type(reason) == "string" and reason ~= "", "field cancel requires a reason")
  if state.plan ~= nil and ctx ~= nil and ctx.services ~= nil and ctx.services.fieldMoves ~= nil then
    ctx.services.fieldMoves:cancel(state.plan)
  end
  state.cancelled = reason
end

-- The implementation owns serializable state validation; nonserializable
-- or unknown plan shapes fail loudly instead of entering the scheduler.
---@param state table<string, unknown>
---@return Errors.Error|nil
function FieldMoveTask.validate(state)
  if type(state) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "field task state must be a table", context)
  end
  if state.refused ~= nil then
    if type(state.refused) ~= "table" or type(state.refused.kind) ~= "string" or hasFunction(state.refused) then
      local context = {}
      ---@cast context Errors.Context
      return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "refused field state is invalid", context)
    end
    return nil
  end
  if not checkPlan(state.plan) then
    local context = {}
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "field task state holds no executable plan", context)
  end
  return nil
end

return FieldMoveTask
