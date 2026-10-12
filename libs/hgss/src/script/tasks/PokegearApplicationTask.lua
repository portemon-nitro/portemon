-- Runs one script-owned companion phone call and waits for its terminal
-- result. Creation only validates and stores the immutable request
-- identity; the first poll opens the shared feature host, later polls
-- step it through the scheduler UI events, and the terminal poll consumes
-- the single result and releases the lease. A missing handle after an
-- acquired call is an attributed lifecycle fault: the conversation is
-- never recreated and committed effects are never replayed. Cancellation
-- unwinds the host call once and stays terminal. Library task only: it
-- borrows the injected host and names no caller program, source number,
-- or renderer.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local PokegearApplicationTask = {}

PokegearApplicationTask.type = "pokegear_application"
PokegearApplicationTask.version = 1

local KINDS = { call = true, townMap = true, fly = true }

local function applicationHost(ctx)
  local services = ctx.services
  local host = services ~= nil and services.pokegearApplications or nil
  if host == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "phone application task requires its host", {})
  end
  assert(host ~= nil, "phone application task requires its host")
  return host
end

---@param value unknown
---@return boolean
local function isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

---@param request unknown
---@return boolean
local function validCallRequest(request)
  if type(request) ~= "table" then
    return false
  end
  assert(type(request) == "table", "phone task requests stay records")
  local record = request --[[@as table<string, unknown>]]
  if
    not isNonEmptyString(record.id)
    or not isNonEmptyString(record.contact)
    or not isNonEmptyString(record.direction)
    or not isNonEmptyString(record.kind)
  then
    return false
  end
  for key in pairs(record) do
    if key ~= "id" and key ~= "contact" and key ~= "direction" and key ~= "kind" then
      return false
    end
  end
  return true
end

---@param state unknown
---@return boolean
local function validShape(state)
  if type(state) ~= "table" then
    return false
  end
  assert(type(state) == "table", "phone task states stay records")
  local record = state --[[@as table<string, unknown>]]
  if KINDS[record.kind] ~= true or not isNonEmptyString(record.parentOwner) or type(record.completed) ~= "boolean" then
    return false
  end
  if record.kind == "call" then
    if not validCallRequest(record.request) then
      return false
    end
  elseif record.request ~= nil then
    return false
  end
  for key, value in pairs(record) do
    if key == "opened" or key == "cancelled" then
      if type(value) ~= "boolean" then
        return false
      end
    elseif key ~= "kind" and key ~= "request" and key ~= "parentOwner" and key ~= "completed" then
      return false
    end
  end
  return true
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function PokegearApplicationTask.create(spec, ctx)
  assert(type(spec) == "table", "phone application task requires a request")
  assert(KINDS[spec.kind] == true, "phone application task names a known companion mode")
  assert(isNonEmptyString(spec.parentOwner), "phone application task carries its parent identity")
  local host = applicationHost(ctx)
  assert(host ~= nil, "phone application task requires its host before any effect")
  if spec.kind ~= "call" then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "the companion " .. tostring(spec.kind) .. " entry has no concrete child yet",
      { kind = spec.kind }
    )
  end
  assert(validCallRequest(spec.request), "phone application task request carries its call identity")
  local source = spec.request --[[@as table<string, string>]]
  return {
    kind = "call",
    request = { id = source.id, contact = source.contact, direction = source.direction, kind = source.kind },
    parentOwner = spec.parentOwner,
    completed = false,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function PokegearApplicationTask.poll(state, ctx)
  assert(validShape(state), "phone application task polls a valid state")
  if state.completed then
    if state.cancelled == true then
      return { complete = true, state = state }
    end
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "phone call handle is missing after its terminal result; the conversation is never recreated",
      { kind = state.kind }
    )
  end
  local host = applicationHost(ctx)
  if state.opened ~= true then
    host:open({ mode = state.kind, request = state.request, parentOwner = state.parentOwner })
    state.opened = true
  end
  local handle = host:activeHandle()
  if handle == nil then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "phone call handle is missing after acquisition; the conversation is never recreated",
      { kind = state.kind }
    )
  end
  assert(handle ~= nil, "phone application task steps its acquired handle")
  local input = ctx.input or {}
  assert(type(input) == "table", "phone application task reads its scheduler input")
  local events = (input --[[@as table<string, unknown>]]).uiEvents or {}
  assert(type(events) == "table", "phone application consumes scheduler UI events")
  host:step(handle, events)
  if host:result(handle) == nil then
    return { complete = false, state = state }
  end
  host:close(handle)
  state.completed = true
  return { complete = true, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function PokegearApplicationTask.cancel(state, reason, ctx)
  assert(validShape(state), "phone application cancellation requires a valid state")
  assert(type(reason) == "string" and reason ~= "", "phone application cancellation requires a reason")
  if state.completed or ctx == nil then
    return
  end
  applicationHost(ctx):cancel(reason)
  state.cancelled = true
  state.completed = true
end

---@param state unknown
---@return Errors.Error|nil
function PokegearApplicationTask.validate(state)
  if not validShape(state) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "phone application task state is invalid", {})
  end
  return nil
end

return PokegearApplicationTask
