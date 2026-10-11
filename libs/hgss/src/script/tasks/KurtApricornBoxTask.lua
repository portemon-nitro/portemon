-- Blocks a field script while Kurt's one source Box selector is open.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local KurtApricornBoxTask = {}
KurtApricornBoxTask.type = "kurt_apricorn_box"
KurtApricornBoxTask.version = 1

---@class KurtApricornBoxHost
---@field open fun(self: KurtApricornBoxHost): table<string, unknown>
---@field activeHandle fun(self: KurtApricornBoxHost): table<string, unknown>?
---@field step fun(self: KurtApricornBoxHost, handle: table<string, unknown>, events: table[])
---@field result fun(self: KurtApricornBoxHost, handle: table<string, unknown>): table<string, unknown>?
---@field close fun(self: KurtApricornBoxHost, handle: table<string, unknown>)
---@field cancel fun(self: KurtApricornBoxHost, reason: string)

---@param ctx table<string, unknown>
---@return KurtApricornBoxHost
local function hostFor(ctx)
  local services = ctx.services
  local host = services ~= nil and services.kurtBoxHost or nil
  if host == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "Kurt Box task requires its host", {})
  end
  return host --[[@as KurtApricornBoxHost]]
end

local function validState(state)
  if type(state) ~= "table" or type(state.completed) ~= "boolean" or type(state.orderCommitted) ~= "boolean" then
    return false
  end
  for key in pairs(state) do
    if key ~= "completed" and key ~= "orderCommitted" then
      return false
    end
  end
  return true
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, boolean>
function KurtApricornBoxTask.create(spec, ctx)
  assert(type(spec) == "table", "Kurt Box task receives a request record")
  assert(next(spec) == nil, "Kurt Box task has no authored options")
  hostFor(ctx):open()
  return { completed = false, orderCommitted = false }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function KurtApricornBoxTask.poll(state, ctx)
  assert(validState(state), "Kurt Box task state is serializable and closed")
  local host = hostFor(ctx)
  if state.completed then
    return { complete = true, state = state }
  end
  if state.orderCommitted then
    state.completed = true
    return { complete = true, state = state }
  end
  local handle = host:activeHandle()
  if handle == nil then
    handle = host:open()
  end
  local input = ctx.input or {}
  local events = input.uiEvents or {}
  assert(type(events) == "table", "Kurt Box task receives normalized scheduler UI events")
  host:step(handle, events)
  local result = host:result(handle)
  if result == nil then
    return { complete = false, state = state }
  end
  assert(result.kind == "closed", "Kurt selector resumes the source script after closing")
  state.orderCommitted = result.selected ~= nil
  host:close(handle)
  state.completed = true
  return { complete = true, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>
function KurtApricornBoxTask.cancel(state, reason, ctx)
  assert(validState(state), "Kurt Box cancellation receives valid task state")
  if not state.completed then
    hostFor(ctx):cancel(reason)
  end
  state.completed = true
end

---@param state table<string, unknown>
---@return boolean
function KurtApricornBoxTask.validate(state)
  return validState(state)
end

return KurtApricornBoxTask
