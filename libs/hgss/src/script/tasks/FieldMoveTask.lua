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
-- decisions complete as results; only these kinds execute. Rock Smash,
-- Headbutt, and Sweet Scent are absent on purpose: the retail menu scripts
-- and the runtime Sweet Scent script own those moves through FieldMoveAftermath,
-- FieldMoveCue, and SweetScentTask after the queue vets eligibility. Chatter
-- eligibility matches FieldMove_CheckChatter, while field use stays
-- feature_unavailable chatter_recording_deferred until a voice-recording
-- application owner exists. The traversal tags mirror the runtime's closed
-- plan union exactly, as do the return tags: a tag missing here can never
-- execute through the scheduler task.
local PLAN_KINDS = {
  cut = true,
  enable_strength = true,
  push_strength = true,
  flash = true,
  surf_enter = true,
  disembark = true,
  waterfall = true,
  whirlpool = true,
  rock_climb = true,
  dig = true,
  teleport = true,
  escape_rope = true,
  fly = true,
}

local function fieldMoves(ctx)
  local services = assert(ctx.services, "field task requires its services")
  local runtime = services.fieldMoves
  assert(runtime ~= nil, "field task requires the field runtime service")
  return runtime
end

-- The feature-local companion host behind Fly destination choice.
-- Absent in compositions without the companion, the choice faults
-- loudly instead of succeeding without a selector.
---@param ctx table<string, unknown>
---@return table<string, unknown>
local function companionHost(ctx)
  local services = assert(ctx.services, "field task requires its services")
  local host = (services --[[@as table<string, unknown>]]).pokegearApplications
  if host == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "fly destination choice requires the companion host", {})
  end
  assert(host ~= nil, "fly choice requires the companion host")
  return host --[[@as table<string, unknown>]]
end

---@param ctx table<string, unknown>
---@return table[]
local function choiceEvents(ctx)
  local input = ctx.input or {}
  assert(type(input) == "table", "fly choice reads its scheduler input")
  local events = (input --[[@as table<string, unknown>]]).uiEvents or {}
  assert(type(events) == "table", "fly choice consumes scheduler UI events")
  return events --[[@as table[] ]]
end

-- The current party revision when the composition supplies the party
-- service; nil in rigs without one, where the revision check is skipped
-- but membership and phase checks still apply.
---@param ctx table<string, unknown>
---@return integer?
local function livePartyRevision(ctx)
  local services = ctx.services
  local mons = services ~= nil and (services --[[@as table<string, unknown>]]).mons or nil
  if type(mons) ~= "table" then
    return nil
  end
  local readRevision = (mons --[[@as table<string, unknown>]]).partyRevision
  if type(readRevision) ~= "function" then
    return nil
  end
  local revision = (readRevision --[[@as fun(self: table<string, unknown>): integer]])(
    mons --[[@as table<string, unknown>]]
  )
  assert(type(revision) == "number", "party revisions are numeric")
  return revision
end

-- Advance the active Fly choice through the feature-local companion
-- host: open the selector once under the field-move identity, route
-- scheduler events only while selection is active, then feed the one
-- terminal back to the runtime. Cancellation and stale choices release
-- without travel; the UI closes exactly once with its operation.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@param plan table<string, unknown>
---@return table<string, unknown>
local function pollFlyChoice(state, ctx, plan)
  local runtime = fieldMoves(ctx)
  local host = companionHost(ctx)
  if state.uiOpened ~= true then
    local openChoice = host.open --[[@as fun(self: table<string, unknown>, args: table<string, unknown>)]]
    openChoice(host, {
      mode = "fly",
      parentOwner = "field-move:" .. tostring(ctx.taskId or "unscheduled"),
      selection = {
        slot = assert(plan.slot, "fly choice carries its party slot"),
        partyRevision = plan.partyRevision,
        mapContext = assert(plan.mapContext, "fly choice carries its map context"),
        destinations = assert(plan.destinations, "fly choice carries its destinations"),
      },
    })
    state.uiOpened = true
  end
  local activeHandle = host.activeHandle --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
  local handle = activeHandle(host)
  if handle == nil then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "fly choice lost its companion handle; the selection is never recreated",
      { move = "fly" }
    )
  end
  assert(handle ~= nil, "fly choice steps its acquired handle")
  local stepChoice = host.step --[[@as fun(self: table<string, unknown>, handle: table<string, unknown>, events: table)]]
  stepChoice(host, handle, choiceEvents(ctx))
  local readChoice = host.result --[[@as fun(self: table<string, unknown>, handle: table<string, unknown>): table<string, unknown>?]]
  local terminal = readChoice(host, handle)
  if terminal == nil then
    return { complete = false, state = state }
  end
  local closeChoice = host.close --[[@as fun(self: table<string, unknown>, handle: table<string, unknown>)]]
  closeChoice(host, handle)
  state.uiOpened = false
  if terminal.kind == "cancelled" then
    local cancelPlan = runtime.cancel --[[@as fun(self: table<string, unknown>, plan: table<string, unknown>)]]
    cancelPlan(runtime, plan)
    return {
      complete = true,
      state = state,
      result = { kind = "field_move_refused", decision = { kind = "cancelled" } },
    }
  end
  if terminal.kind ~= "destination" then
    error("unknown fly terminal " .. tostring(terminal.kind), 0)
  end
  local confirmChoice = runtime.confirmFlyDestination --[[@as fun(self: table<string, unknown>, plan: table<string, unknown>, terminal: table<string, unknown>, livePartyRevision: integer?): table<string, unknown>]]
  local confirmed = confirmChoice(runtime, plan, terminal, livePartyRevision(ctx))
  if confirmed.kind ~= "confirmed" then
    return { complete = true, state = state, result = { kind = "field_move_refused", decision = confirmed } }
  end
  return { complete = false, state = state }
end

-- Dispose a live Fly choice through the companion host: the selector
-- closes exactly once while it is ours, and never touches a later
-- lease holder after its choice already settled.
---@param services table<string, unknown>
---@param reason string
local function cancelFlyChoice(services, reason)
  local host = assert(services.pokegearApplications, "an open fly choice cancels through the companion host")
  assert(type(host) == "table", "fly choice cancels through the companion host")
  local companion = host --[[@as table<string, unknown>]]
  local cancelChoice = companion.cancel --[[@as fun(self: table<string, unknown>, reason: string)]]
  cancelChoice(companion, reason)
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
  local rawPlan = assert(state.plan, "active field task requires its plan")
  local plan = rawPlan --[[@as table<string, unknown>]]
  if plan.kind == "fly" and plan.phase == "choose_destination" then
    return pollFlyChoice(state, ctx, plan)
  end
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
  if state.plan ~= nil and ctx ~= nil and ctx.services ~= nil then
    -- A live Fly choice disposes its selector first so cancellation
    -- closes the UI and the original operation once each; an already
    -- consumed choice leaves later lease holders untouched.
    if state.uiOpened == true then
      state.uiOpened = false
      cancelFlyChoice(ctx.services --[[@as table<string, unknown>]], reason)
    end
    if ctx.services.fieldMoves ~= nil then
      ctx.services.fieldMoves:cancel(state.plan)
    end
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
