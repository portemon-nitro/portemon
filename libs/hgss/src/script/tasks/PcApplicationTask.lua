-- Runs one script-owned PC application or waits for a terminal effect.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local PcApplicationTask = {}

PcApplicationTask.type = "pc_application"
PcApplicationTask.version = 1

local APPS = { storage = true, mailbox = true, photoAlbum = true }

local function applicationHost(ctx)
  local services = ctx.services
  local host = services ~= nil and services.pcApplications or nil
  if host == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "PC application task requires its host", {})
  end
  assert(host ~= nil, "PC application task requires its host")
  return host
end

local function terminal(ctx)
  local services = ctx.services
  local host = services ~= nil and services.pcTerminal or nil
  if host == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "PC terminal task requires its service", {})
  end
  assert(host ~= nil, "PC terminal task requires its service")
  return host
end

local function validMode(mode)
  return type(mode) == "number" and mode % 1 == 0 and mode >= 0 and mode <= 3
end

local function validShape(state)
  if type(state) ~= "table" or type(state.kind) ~= "string" or type(state.completed) ~= "boolean" then
    return false
  end
  if state.kind == "application" then
    if not APPS[state.app] then
      return false
    end
    if state.app == "storage" then
      if not validMode(state.mode) then
        return false
      end
    elseif state.mode ~= nil then
      return false
    end
    for key in pairs(state) do
      if key ~= "kind" and key ~= "app" and key ~= "mode" and key ~= "completed" then
        return false
      end
    end
    return true
  end
  if state.kind == "terminal_wait" then
    for key in pairs(state) do
      if key ~= "kind" and key ~= "completed" then
        return false
      end
    end
    return true
  end
  return false
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function PcApplicationTask.create(spec, ctx)
  assert(type(spec) == "table", "PC application task requires a request")
  if spec.kind == "application" then
    if spec.app == "storage" and spec.mode == 4 then
      Errors.raise(
        ScriptErrors.FEATURE_UNAVAILABLE,
        "the source PC Storage mode is not implemented",
        { app = spec.app, mode = spec.mode }
      )
    end
    local state = { kind = "application", app = spec.app, mode = spec.mode, completed = false }
    assert(validShape(state), "PC application task request must name a supported app and mode")
    applicationHost(ctx):open({ app = state.app, mode = state.mode })
    return state
  end
  assert(spec.kind == "terminal_wait", "PC application task request has an unknown kind")
  terminal(ctx)
  return { kind = "terminal_wait", completed = false }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function PcApplicationTask.poll(state, ctx)
  assert(validShape(state), "PC application task polls a valid state")
  if state.completed then
    return { complete = true, state = state }
  end
  if state.kind == "terminal_wait" then
    if not terminal(ctx):effectFinished() then
      return { complete = false, state = state }
    end
  else
    local host = applicationHost(ctx)
    local handle = host:activeHandle()
    if handle == nil then
      handle = host:open({ app = state.app, mode = state.mode })
    end
    local input = ctx.input or {}
    local events = input.uiEvents or {}
    assert(type(events) == "table", "PC application consumes scheduler UI events")
    host:step(handle, events)
    local result = host:result(handle)
    if result == nil then
      return { complete = false, state = state }
    end
    assert(result.kind == "closed", "PC application returns to the field after closing")
    host:close(handle)
  end
  state.completed = true
  return { complete = true, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function PcApplicationTask.cancel(state, reason, ctx)
  assert(validShape(state), "PC application cancellation requires a valid state")
  assert(type(reason) == "string" and reason ~= "", "PC application cancellation requires a reason")
  if state.completed or ctx == nil then
    return
  end
  if state.kind == "terminal_wait" then
    terminal(ctx):releaseEffect()
  else
    applicationHost(ctx):cancel(reason)
  end
end

---@param state unknown
---@return Errors.Error|nil
function PcApplicationTask.validate(state)
  if not validShape(state) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "PC application task state is invalid", {})
  end
  return nil
end

return PcApplicationTask
