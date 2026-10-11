-- Owns the one script-opened Kurt selector and commits its selected order.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class ApricornBoxHost
---@field _makeApricornBox fun(mode: string): table<string, unknown>
---@field _service { submitKurt: fun(self: table<string, unknown>, apricornKey: string, quantity: integer): boolean }
---@field _bag { registeredItems: fun(self: table<string, unknown>): string[] }
---@field _nextId integer
---@field _active table<string, unknown>?
---@field _disposed boolean
local ApricornBoxHost = {}
ApricornBoxHost.__index = ApricornBoxHost

local function disposeChild(child)
  if type(child.cancelPointerCapture) == "function" then
    child:cancelPointerCapture()
  end
  child:dispose()
end

local function validateChild(child)
  assert(type(child) == "table", "Apricorn Box factory returns a screen state")
  assert(type(child.updateFixed) == "function", "Kurt selector consumes fixed-tick events")
  assert(type(child.status) == "function", "Kurt selector publishes read-only status")
  assert(type(child.takeResult) == "function", "Kurt selector publishes its close result")
  assert(type(child.dispose) == "function", "Kurt selector releases its session")
end

---@param opts table<string, unknown>
---@return ApricornBoxHost
function ApricornBoxHost.new(opts)
  assert(type(opts) == "table", "Kurt Box host requires dependencies")
  assert(type(opts.makeApricornBox) == "function", "Kurt Box host reuses the composed screen factory")
  assert(type(opts.service) == "table", "Kurt Box host requires the live MartService")
  assert(type(opts.service.submitKurt) == "function", "Kurt Box host submits through MartService")
  assert(type(opts.bag) == "table" and type(opts.bag.registeredItems) == "function", "Box shortcut reads the live Bag")
  return setmetatable({
    _makeApricornBox = opts.makeApricornBox,
    _service = opts.service,
    _bag = opts.bag,
    _nextId = 0,
    _active = nil,
    _disposed = false,
  }, ApricornBoxHost)
end

function ApricornBoxHost:isActive()
  return self._active ~= nil
end

function ApricornBoxHost:activeHandle()
  return self._active and self._active.handle or nil
end

---@return table<string, unknown>
function ApricornBoxHost:open()
  assert(not self._disposed, "disposed Kurt Box host cannot open a selector")
  assert(self._active == nil, "Kurt already owns an open Apricorn selector")
  local ok, child = pcall(self._makeApricornBox, "kurt_select")
  if not ok then
    error(child, 0)
  end
  local valid, err = pcall(validateChild, child)
  if not valid then
    if type(child) == "table" and type(child.dispose) == "function" then
      disposeChild(child)
    end
    error(err, 0)
  end
  self._nextId = self._nextId + 1
  local handle = { id = self._nextId }
  self._active = {
    handle = handle,
    child = child,
    mode = "kurt_select",
    result = nil,
    resultTaken = false,
    presentationReady = false,
  }
  return handle
end

---@return boolean true when the registered Apricorn Box opened
function ApricornBoxHost:openRegisteredBrowse()
  assert(not self._disposed, "disposed Kurt Box host cannot open a selector")
  assert(self._active == nil, "Apricorn Box host already owns an open selector")
  if self._bag:registeredItems()[1] ~= "APRICORN_BOX" then
    return false
  end
  local ok, child = pcall(self._makeApricornBox, "browse")
  if not ok then
    error(child, 0)
  end
  local valid, err = pcall(validateChild, child)
  if not valid then
    if type(child) == "table" and type(child.dispose) == "function" then
      disposeChild(child)
    end
    error(err, 0)
  end
  self._nextId = self._nextId + 1
  self._active = {
    handle = { id = self._nextId },
    child = child,
    mode = "browse",
    result = nil,
    resultTaken = false,
    presentationReady = false,
  }
  return true
end

function ApricornBoxHost:isBrowseActive()
  return self._active ~= nil and self._active.mode == "browse"
end

---@param handle table<string, unknown>
---@param events table[] ordered semantic UI events
function ApricornBoxHost:stepBrowse(handle, events)
  local active = assert(self._active, "Apricorn Box has no open browse session")
  assert(handle == active.handle, "Apricorn Box browse handle is stale or foreign")
  assert(active.mode == "browse", "only registered browse sessions use the field lane")
  assert(type(events) == "table", "Apricorn Box browse steps semantic UI events")
  local ok, result = pcall(function()
    active.child:updateFixed(active.presentationReady and events or {})
    return active.child:takeResult()
  end)
  if not ok then
    self:close(handle)
    error(result, 0)
  end
  if result ~= nil then
    assert(result.kind == "closed", "Apricorn Box browse returns after closing")
    self:close(handle)
  end
end

local function activeFor(self, handle)
  local active = assert(self._active, "Kurt has no open Apricorn selector")
  assert(handle == active.handle, "Kurt selector handle is stale or foreign")
  return active
end

---@param handle table<string, unknown>
---@param events table[] ordered semantic UI events
function ApricornBoxHost:step(handle, events)
  local active = activeFor(self, handle)
  assert(type(events) == "table", "Kurt selector steps the scheduler event batch")
  if active.result ~= nil then
    return
  end
  local ok, result = pcall(function()
    active.child:updateFixed(active.presentationReady and events or {})
    return active.child:takeResult()
  end)
  if not ok then
    self:close(handle)
    error(result, 0)
  end
  if result == nil then
    return
  end
  assert(result.kind == "closed", "Kurt selector returns after closing")
  if result.selected ~= nil then
    local selected = result.selected
    assert(
      type(selected) == "table"
        and type(selected.apricornKey) == "string"
        and type(selected.quantity) == "number"
        and selected.quantity % 1 == 0
        and selected.quantity >= 1
        and selected.quantity <= 99,
      "Kurt selection carries one Apricorn key and a valid quantity"
    )
    if not self._service:submitKurt(selected.apricornKey, selected.quantity) then
      self:close(handle)
      Errors.raise(ScriptErrors.SCRIPT_TASK_CALLBACK_FAULT, "Kurt selection is stale", {
        apricornKey = selected.apricornKey,
        quantity = selected.quantity,
      })
    end
  end
  active.result = result.selected == nil and { kind = "closed" }
    or {
      kind = "closed",
      selected = { apricornKey = result.selected.apricornKey, quantity = result.selected.quantity },
    }
end

---@param handle table<string, unknown>
---@return table<string, unknown>?
function ApricornBoxHost:result(handle)
  local active = activeFor(self, handle)
  if active.result == nil or active.resultTaken then
    return nil
  end
  active.resultTaken = true
  return active.result
end

---@param handle table<string, unknown>
---@param ready boolean
function ApricornBoxHost:setPresentationReady(handle, ready)
  local active = activeFor(self, handle)
  assert(type(ready) == "boolean", "Kurt selector presentation readiness is boolean")
  active.presentationReady = ready
end

function ApricornBoxHost:close(handle)
  local active = self._active
  if active == nil then
    return
  end
  assert(handle == active.handle, "Kurt selector handle is stale or foreign")
  disposeChild(active.child)
  self._active = nil
end

---@return table<string, unknown>?
function ApricornBoxHost:status()
  local active = self._active
  if active == nil then
    return nil
  end
  local status = {}
  for key, value in pairs(active.child:status()) do
    status[key] = value
  end
  status.hostMode = active.mode
  status.presentationReady = active.presentationReady
  return status
end

function ApricornBoxHost:cancelPointerCapture()
  local active = self._active
  if active ~= nil and type(active.child.cancelPointerCapture) == "function" then
    active.child:cancelPointerCapture()
  end
end

function ApricornBoxHost:cancel(_)
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

function ApricornBoxHost:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:cancel("field teardown")
end

return ApricornBoxHost
