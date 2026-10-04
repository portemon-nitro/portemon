-- The foreground task keeps one source mart launch blocked until its child
-- has closed and the field host has restored the running field.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local MartTask = {}
MartTask.type = "mart"
MartTask.version = 1

local KINDS = {
  standard = true,
  special = true,
  seal = true,
  decoration = true,
  athlete = true,
  data_cards = true,
  custom = true,
  sell = true,
}

local SELECTOR_KINDS = { special = true, seal = true, decoration = true }

---@class MartTaskHost
---@field open fun(self: MartTaskHost, ownerKey: string, descriptor: table<string, unknown>): table<string, unknown>
---@field step fun(self: MartTaskHost, handle: table<string, unknown>, events: table[])
---@field result fun(self: MartTaskHost, handle: table<string, unknown>): { kind: string }?
---@field close fun(self: MartTaskHost, handle: table<string, unknown>)

---@class MartTaskContext
---@field services { mart: MartTaskHost? }?
---@field instance { instanceId: string }
---@field taskId string?
---@field input { uiEvents: table[] }?

local function serializable(value, seen)
  local valueType = type(value)
  if valueType == "table" then
    if getmetatable(value) ~= nil or seen[value] then
      return false
    end
    seen[value] = true
    for key, child in pairs(value) do
      local keyType = type(key)
      if (keyType ~= "string" and keyType ~= "number") or not serializable(child, seen) then
        return false
      end
    end
    seen[value] = nil
    return true
  end
  if valueType == "string" or valueType == "boolean" then
    return true
  end
  if valueType == "number" then
    return value == value and value ~= math.huge and value ~= -math.huge
  end
  return false
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function descriptorError(descriptor)
  if type(descriptor) ~= "table" or not KINDS[descriptor.kind] then
    return "mart task requires a known launch kind"
  end
  for key in pairs(descriptor) do
    if key ~= "kind" and key ~= "selector" and key ~= "stock" then
      return "mart launch descriptor has an unknown field " .. tostring(key)
    end
  end
  if SELECTOR_KINDS[descriptor.kind] then
    local selector = descriptor.selector
    if
      type(selector) ~= "number"
      or selector ~= selector
      or selector == math.huge
      or selector == -math.huge
      or selector % 1 ~= 0
      or selector < 0
      or selector > 0xFFFF
    then
      return "mart launch selector must be an unsigned 16-bit integer"
    end
  elseif descriptor.selector ~= nil then
    return "mart launch kind does not accept a selector"
  end
  if descriptor.kind == "custom" then
    if type(descriptor.stock) ~= "table" or not serializable(descriptor.stock, {}) then
      return "custom mart stock must be a serializable record"
    end
  elseif descriptor.stock ~= nil then
    return "mart launch kind does not accept custom stock"
  end
  return nil
end

---@param code string
---@param message string
local function fail(code, message)
  Errors.raise(code, message, {})
end

---@param ctx MartTaskContext
---@return MartTaskHost
local function service(ctx)
  local host = ctx.services ~= nil and ctx.services.mart or nil
  if host == nil then
    fail(ScriptErrors.SCRIPT_SERVICE_MISSING, "mart task requires the script mart host")
  end
  assert(host ~= nil, "mart task requires a script mart host")
  assert(type(host.open) == "function", "mart host must expose open")
  assert(type(host.step) == "function", "mart host must expose step")
  assert(type(host.result) == "function", "mart host must expose result")
  assert(type(host.close) == "function", "mart host must expose close")
  return host
end

---@param ctx MartTaskContext
---@return string
local function instanceId(ctx)
  local instance = ctx.instance
  assert(type(instance) == "table" and type(instance.instanceId) == "string", "mart task requires an instance id")
  return instance.instanceId
end

---@param spec table<string, unknown> flat mart launch descriptor
---@param ctx MartTaskContext
---@return table<string, unknown>
function MartTask.create(spec, ctx)
  local problem = descriptorError(spec)
  if problem ~= nil then
    fail(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, problem)
  end
  service(ctx)
  return {
    descriptor = copy(spec),
    ownerInstanceId = instanceId(ctx),
    completed = false,
  }
end

---@param state table<string, unknown>
---@param ctx MartTaskContext
---@return table<string, unknown>
function MartTask.poll(state, ctx)
  assert(state.completed == false, "completed mart task cannot be polled")
  local ownerInstanceId = instanceId(ctx)
  assert(ownerInstanceId == state.ownerInstanceId, "mart task cannot move between script instances")
  local taskId = ctx.taskId
  assert(type(taskId) == "string" and taskId ~= "", "mart task requires its scheduler task id")
  if state.taskId ~= nil then
    assert(taskId == state.taskId, "mart task cannot move between scheduler tasks")
  else
    state.taskId = taskId
    state.ownerKey = ownerInstanceId .. ":" .. taskId
  end

  local host = service(ctx)
  if state.handle == nil then
    state.handle = host:open(state.ownerKey, state.descriptor)
  end
  assert(state.handle ~= nil, "mart host must return an owned handle")
  local input = ctx.input or {}
  local events = input.uiEvents or {}
  assert(type(events) == "table", "mart task consumes the scheduler UI event list")
  host:step(state.handle, events)
  local result = host:result(state.handle)
  if result == nil then
    return { complete = false, state = state }
  end
  assert(result.kind == "close", "mart host returned an unsupported terminal result")
  host:close(state.handle)
  state.handle = nil
  state.descriptor = nil
  state.completed = true
  return { complete = true, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx MartTaskContext?
function MartTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx == nil or state.handle == nil then
    return
  end
  local ownerInstanceId = instanceId(ctx)
  assert(ownerInstanceId == state.ownerInstanceId, "mart task cancellation belongs to another script instance")
  assert(ctx.taskId == state.taskId, "mart task cancellation belongs to another scheduler task")
  service(ctx):close(state.handle)
  state.handle = nil
  state.descriptor = nil
  state.completed = true
end

---@param state unknown
---@return Errors.Error|nil
function MartTask.validate(state)
  local function invalid(message)
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, message, {})
  end
  if type(state) ~= "table" or getmetatable(state) ~= nil then
    return invalid("mart task state must be a record")
  end
  local stateFields = {
    descriptor = true,
    ownerInstanceId = true,
    completed = true,
    taskId = true,
    ownerKey = true,
    handle = true,
    cancelled = true,
  }
  for key in pairs(state) do
    if not stateFields[key] then
      return invalid("mart task state has an unknown field " .. tostring(key))
    end
  end
  if not serializable(state, {}) then
    return invalid("mart task state must be serializable")
  end
  if type(state.ownerInstanceId) ~= "string" or state.ownerInstanceId == "" then
    return invalid("mart task needs an owner instance")
  end
  if type(state.completed) ~= "boolean" then
    return invalid("mart task state needs completion status")
  end
  if state.completed then
    if state.handle ~= nil or state.descriptor ~= nil then
      return invalid("completed mart task must release its launch and handle")
    end
    return nil
  end
  local problem = descriptorError(state.descriptor)
  if problem ~= nil then
    return invalid(problem)
  end
  if state.taskId ~= nil and (type(state.taskId) ~= "string" or state.taskId == "") then
    return invalid("mart task id must be a non-empty string")
  end
  if state.ownerKey ~= nil then
    if type(state.taskId) ~= "string" or state.ownerKey ~= state.ownerInstanceId .. ":" .. state.taskId then
      return invalid("mart task owner key does not match its identities")
    end
  end
  if state.handle ~= nil and (state.taskId == nil or state.ownerKey == nil) then
    return invalid("mart host handle needs its task owner identity")
  end
  return nil
end

return MartTask
