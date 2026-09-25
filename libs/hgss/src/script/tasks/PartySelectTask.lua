-- The blocking party-selection task behind opcode 349: it opens one
-- visible pick-context party screen through the script-owned host,
-- persists semantic focus (a slot in 0..5 or cancel) across polls,
-- and completes with the zero-based slot or the source cancellation
-- value. Selection mutates no party state. Only the named eligibility
-- policy, the cancel permission, the focus, and completion serialize;
-- the live screen is rebuilt from value-only state on every poll.
--
-- Source sentinel ownership (pret/pokeheartgold@0985e8718d): opcode 349
-- launches PARTY_MENU_CONTEXT_3, where confirming an occupied slot exits
-- with that slot while B exits with partySlot 7
-- (PARTY_MON_SELECTION_CONFIRM, src/party_menu.c PartyMenu_HandleInput);
-- the companion result command writes 255 for slot 7
-- (src/scrcmd_c.c ScrCmd_GetPartySelection). The host only ever emits
-- the semantic selected/cancelled records; this task alone translates
-- them to the script-visible slot-or-255 values.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local PartySelectTask = {}

PartySelectTask.type = "party_select"
PartySelectTask.version = 2

-- The script-visible cancellation value the companion result command
-- expects: the source maps the cancelled args slot to 255.
PartySelectTask.CANCEL_RESULT = 255

PartySelectTask.ELIGIBILITY_OCCUPIED = "occupied"

---@param policy string
local function checkPolicy(policy)
  if policy ~= PartySelectTask.ELIGIBILITY_OCCUPIED then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "unknown party eligibility policy " .. tostring(policy), {
      policy = policy,
    })
  end
end

---@param ctx table<string, unknown>
---@return PartySelectionHost the script-owned party selection host
local function selectionHost(ctx)
  local services = ctx.services
  local host = services ~= nil and services.partySelection or nil
  if host == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "party_select requires the script party host", {})
  end
  assert(host ~= nil, "party_select requires the script party host")
  return host
end

---@param ctx table<string, unknown>
---@return HgssMonService the live mon service
local function monsService(ctx)
  local services = ctx.services
  local mons = services ~= nil and services.mons or nil
  if mons == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "party_select requires the live mon service", {})
  end
  assert(mons ~= nil, "party_select requires the live mon service")
  return mons
end

---@param request table<string, unknown>
---@return table<string, unknown> normalized
local function checkRequest(request)
  assert(type(request) == "table", "party_select requires a selection request")
  assert(request.mode == "select", "party_select only runs the selection context")
  assert(
    type(request.initialSlot) == "number"
      and request.initialSlot % 1 == 0
      and request.initialSlot >= 0
      and request.initialSlot < 6,
    "party selection needs an initial slot in 0..5"
  )
  assert(type(request.eligibility) == "table", "party selection needs an eligibility policy")
  checkPolicy(request.eligibility.policy)
  assert(type(request.allowCancel) == "boolean", "party selection needs cancel permission")
  return request
end

---@param spec table<string, unknown> { request: table<string, unknown> }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function PartySelectTask.create(spec, ctx)
  assert(type(spec) == "table" and type(spec.request) == "table", "party_select requires a selection request")
  monsService(ctx)
  selectionHost(ctx)
  local request = checkRequest(spec.request)
  return {
    policy = request.eligibility.policy,
    allowCancel = request.allowCancel,
    focus = request.initialSlot,
    completed = false,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function PartySelectTask.poll(state, ctx)
  if state.completed == true then
    return { complete = true, state = state }
  end
  local host = selectionHost(ctx)
  local handle = host:activeHandle()
  if handle == nil then
    handle = host:open({ focus = state.focus, allowCancel = state.allowCancel, policy = state.policy })
  end
  local input = ctx.input or {}
  local events = input.uiEvents or {}
  assert(type(events) == "table", "party selection consumes the scheduler event list")
  host:step(handle, events)
  local result = host:result(handle)
  if result == nil then
    state.focus = host:focus(handle)
    return { complete = false, state = state }
  end
  -- Park the completed outcome on the script instance for the companion
  -- result node (the same instance-scoped handoff the menu builder uses);
  -- locals persist across save/restore, so the handoff survives with the
  -- script. The scheduler's own task-result write stays empty: no game
  -- variable is named until the result command runs.
  local instance = assert(ctx.instance, "party_select runs on a script instance")
  assert(type(instance.locals) == "table", "the script instance carries locals")
  if result.kind == "selected" then
    assert(type(result.slot) == "number", "selection completes on a party slot")
    instance.locals.__party_selection = result.slot
  else
    assert(result.kind == "cancelled", "selection ends selected or cancelled")
    instance.locals.__party_selection = PartySelectTask.CANCEL_RESULT
  end
  state.completed = true
  host:close(handle)
  return { complete = true, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>?
function PartySelectTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx == nil then
    return
  end
  local services = ctx.services or {}
  local host = services.partySelection
  if type(host) == "table" and type(host.status) == "function" and type(host.close) == "function" then
    if host:status() ~= nil and type(host.activeHandle) == "function" then
      local handle = host:activeHandle()
      if handle ~= nil then
        host:close(handle)
      end
    end
  end
end

---@param focus unknown
---@return boolean
local function isFocus(focus)
  if focus == "cancel" then
    return true
  end
  return type(focus) == "number" and focus % 1 == 0 and focus >= 0 and focus < 6
end

---@param state unknown
---@return Errors.Error|nil
function PartySelectTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "party_select state must be a record", {})
  end
  if type(state.allowCancel) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "party_select state needs cancel permission", {})
  end
  if not isFocus(state.focus) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "party_select focus must sit in 0..5 or cancel", {})
  end
  if state.focus == "cancel" and state.allowCancel ~= true then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "party_select cancel focus needs cancel permission", {})
  end
  if state.policy ~= PartySelectTask.ELIGIBILITY_OCCUPIED then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "party_select policy must name a known eligibility",
      { policy = state.policy }
    )
  end
  if state.completed ~= nil and type(state.completed) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "party_select completion must be a boolean", {})
  end
  return nil
end

return PartySelectTask
