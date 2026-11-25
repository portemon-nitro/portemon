-- The foreground task keeps one source bank transfer blocked until the amount
-- screen has closed and the field host has restored the running field
-- (src/scrcmd_c.c::ScrCmd_BankTransaction/NativeScript_WaitBankTransaction).
-- The task owns the opaque bank handle and writes the source result variable:
-- one for a cancelled or zero entry, zero for an accepted transfer.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local BankTransactionTask = {}
BankTransactionTask.type = "bank_transaction"
BankTransactionTask.version = 1

-- ScrCmd_BankTransaction's two modes: deposit and withdrawal.
local MODES = { [0] = true, [1] = true }

---@class BankTransactionTaskHost
---@field open fun(self: BankTransactionTaskHost, ownerKey: string, descriptor: table<string, unknown>): table<string, unknown>
---@field step fun(self: BankTransactionTaskHost, handle: table<string, unknown>, events: table[])
---@field result fun(self: BankTransactionTaskHost, handle: table<string, unknown>): { kind: string, amount: integer }?
---@field close fun(self: BankTransactionTaskHost, handle: table<string, unknown>)
---@field activeHandle fun(self: BankTransactionTaskHost): table<string, unknown>?

---@class BankTransactionTaskContext
---@field services { bank: BankTransactionTaskHost? }?
---@field instance { instanceId: string }
---@field taskId string?
---@field input { uiEvents: table[] }?

---@param code string
---@param message string
local function fail(code, message)
  Errors.raise(code, message, {})
end

---@param ctx BankTransactionTaskContext
---@return BankTransactionTaskHost
local function service(ctx)
  local host = ctx.services ~= nil and ctx.services.bank or nil
  if host == nil then
    fail(ScriptErrors.SCRIPT_SERVICE_MISSING, "bank task requires the script bank host")
  end
  assert(host ~= nil, "bank task requires a script bank host")
  assert(type(host.open) == "function", "bank host must expose open")
  assert(type(host.step) == "function", "bank host must expose step")
  assert(type(host.result) == "function", "bank host must expose result")
  assert(type(host.close) == "function", "bank host must expose close")
  return host
end

---@param ctx BankTransactionTaskContext
---@return string
local function instanceId(ctx)
  local instance = ctx.instance
  assert(type(instance) == "table" and type(instance.instanceId) == "string", "bank task requires an instance id")
  return instance.instanceId
end

---@param mode unknown
---@return string? problem
local function modeProblem(mode)
  if type(mode) ~= "number" or mode % 1 ~= 0 or MODES[mode] ~= true then
    return "bank task requires the source deposit or withdrawal mode"
  end
  return nil
end

---@param spec { mode: integer }
---@param ctx BankTransactionTaskContext
---@return table<string, unknown>
function BankTransactionTask.create(spec, ctx)
  if type(spec) ~= "table" then
    fail(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "bank task requires a launch descriptor")
  end
  for key in pairs(spec) do
    if key ~= "mode" then
      fail(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "bank launch descriptor has an unknown field " .. tostring(key))
    end
  end
  local problem = modeProblem(spec.mode)
  if problem ~= nil then
    fail(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, problem)
  end
  service(ctx)
  return {
    mode = spec.mode,
    ownerInstanceId = instanceId(ctx),
    completed = false,
  }
end

---@param state table<string, unknown>
---@param ctx BankTransactionTaskContext
---@return table<string, unknown>
function BankTransactionTask.poll(state, ctx)
  assert(state.completed == false, "completed bank task cannot be polled")
  local ownerInstanceId = instanceId(ctx)
  assert(ownerInstanceId == state.ownerInstanceId, "bank task cannot move between script instances")
  local taskId = ctx.taskId
  assert(type(taskId) == "string" and taskId ~= "", "bank task requires its scheduler task id")
  if state.taskId ~= nil then
    assert(taskId == state.taskId, "bank task cannot move between scheduler tasks")
  else
    state.taskId = taskId
    state.ownerKey = ownerInstanceId .. ":" .. taskId
  end

  local host = service(ctx)
  local handle = host:activeHandle()
  if handle == nil then
    handle = host:open(state.ownerKey, { mode = state.mode })
  else
    assert(handle.owner == state.ownerKey, "bank task cannot adopt another task's child")
  end
  assert(handle ~= nil, "bank host must return an owned handle")
  local input = ctx.input or {}
  local events = input.uiEvents or {}
  assert(type(events) == "table", "bank task consumes the scheduler UI event list")
  host:step(handle, events)
  local result = host:result(handle)
  if result == nil then
    return { complete = false, state = state }
  end
  assert(result.kind == "completed", "bank host returned an unsupported terminal result")
  assert(type(result.amount) == "number", "bank host reports the accepted amount")
  host:close(handle)
  state.mode = nil
  state.completed = true
  -- NativeScript_WaitBankTransaction writes one for a cancel or zero entry and
  -- zero for an accepted transfer.
  return { complete = true, state = state, result = result.amount > 0 and 0 or 1 }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx BankTransactionTaskContext?
function BankTransactionTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx == nil then
    return
  end
  local ownerInstanceId = instanceId(ctx)
  assert(ownerInstanceId == state.ownerInstanceId, "bank task cancellation belongs to another script instance")
  assert(ctx.taskId == state.taskId, "bank task cancellation belongs to another scheduler task")
  local host = service(ctx)
  local handle = host:activeHandle()
  if handle == nil then
    return
  end
  assert(handle.owner == state.ownerKey, "bank task cancellation cannot close another task's child")
  host:close(handle)
  state.mode = nil
  state.completed = true
end

---@param state unknown
---@return Errors.Error|nil
function BankTransactionTask.validate(state)
  local function invalid(message)
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, message, {})
  end
  if type(state) ~= "table" or getmetatable(state) ~= nil then
    return invalid("bank task state must be a record")
  end
  local fields = {
    mode = true,
    ownerInstanceId = true,
    completed = true,
    taskId = true,
    ownerKey = true,
    cancelled = true,
  }
  for key in pairs(state) do
    if not fields[key] then
      return invalid("bank task state has an unknown field " .. tostring(key))
    end
  end
  if type(state.ownerInstanceId) ~= "string" or state.ownerInstanceId == "" then
    return invalid("bank task needs an owner instance")
  end
  if type(state.completed) ~= "boolean" then
    return invalid("bank task state needs completion status")
  end
  if state.completed then
    if state.mode ~= nil then
      return invalid("completed bank task must release its launch")
    end
    return nil
  end
  local problem = modeProblem(state.mode)
  if problem ~= nil then
    return invalid(problem)
  end
  if state.taskId ~= nil and (type(state.taskId) ~= "string" or state.taskId == "") then
    return invalid("bank task id must be a non-empty string")
  end
  if state.ownerKey ~= nil then
    if type(state.taskId) ~= "string" or state.ownerKey ~= state.ownerInstanceId .. ":" .. state.taskId then
      return invalid("bank task owner key does not match its identities")
    end
  end
  return nil
end

return BankTransactionTask
