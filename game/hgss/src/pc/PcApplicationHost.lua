-- Owns the one script-opened Storage, Mailbox, or Photo Album child.

---@class PcApplicationHost
---@field _factories table<string, function>
---@field _nextId integer
---@field _active table<string, unknown>?
---@field _disposed boolean
local PcApplicationHost = {}
PcApplicationHost.__index = PcApplicationHost

local CHILD_FACTORIES = {
  storage = "createStorage",
  mailbox = "createMailbox",
  photoAlbum = "createPhotoAlbum",
}

function PcApplicationHost.new(opts)
  assert(type(opts) == "table", "PC application host needs its child factories")
  for _, factoryName in pairs(CHILD_FACTORIES) do
    assert(type(opts[factoryName]) == "function", "PC application host requires " .. factoryName)
  end
  return setmetatable({
    _factories = {
      storage = opts.createStorage,
      mailbox = opts.createMailbox,
      photoAlbum = opts.createPhotoAlbum,
    },
    _nextId = 0,
    _active = nil,
    _disposed = false,
  }, PcApplicationHost)
end

local function validateRequest(request)
  assert(type(request) == "table", "PC application request is a record")
  local factory = assert(CHILD_FACTORIES[request.app], "PC application kind is closed")
  if request.app == "storage" then
    assert(
      type(request.mode) == "number" and request.mode % 1 == 0 and request.mode >= 0 and request.mode <= 3,
      "Storage mode must be one of the retained source modes"
    )
  else
    assert(request.mode == nil, "only Storage carries a mode")
  end
  return factory
end

local function disposeChild(child)
  if type(child.cancelPointerCapture) == "function" then
    child:cancelPointerCapture()
  end
  if type(child.dispose) == "function" then
    child:dispose()
  end
end

function PcApplicationHost:open(request)
  assert(not self._disposed, "disposed PC application host cannot open a child")
  assert(self._active == nil, "a PC application already owns the script modal")
  validateRequest(request)
  local ok, child = pcall(self._factories[request.app], request)
  if not ok then
    error(child, 0)
  end
  assert(type(child) == "table", "PC child factory must return a child")
  local valid, err = pcall(function()
    assert(type(child.updateFixed) == "function", "PC child consumes fixed-tick events")
    assert(type(child.status) == "function", "PC child publishes read-only status")
    assert(type(child.dispose) == "function", "PC child releases its owned state")
    assert(type(child.takeResult) == "function" or type(child.result) == "function", "PC child publishes a result")
  end)
  if not valid then
    disposeChild(child)
    error(err, 0)
  end
  self._nextId = self._nextId + 1
  local handle = { id = self._nextId }
  self._active = {
    handle = handle,
    app = request.app,
    child = child,
    result = nil,
    resultTaken = false,
    presentationReady = false,
  }
  return handle
end

function PcApplicationHost:isActive()
  return self._active ~= nil
end

-- Whether the open PC application is in a text-entry editor.
---@return boolean
function PcApplicationHost:acceptsText()
  local active = self._active
  return active ~= nil and active.child.acceptsText ~= nil and active.child:acceptsText()
end

function PcApplicationHost:activeHandle()
  return self._active and self._active.handle or nil
end

local function activeFor(self, handle)
  local active = assert(self._active, "no PC application is open")
  assert(handle == active.handle, "PC application handle is stale or foreign")
  return active
end

function PcApplicationHost:step(handle, events)
  local active = activeFor(self, handle)
  assert(type(events) == "table", "PC application steps the scheduler event batch")
  if active.result ~= nil then
    return
  end
  active.child:updateFixed(active.presentationReady and events or {})
  local takeResult = active.child.takeResult or active.child.result
  local result = takeResult(active.child)
  if result ~= nil then
    assert(result.kind == "closed", "PC child returns to the source shell")
    active.result = { kind = "closed" }
  end
end

function PcApplicationHost:setPresentationReady(handle, ready)
  local active = activeFor(self, handle)
  assert(type(ready) == "boolean", "PC presentation readiness is boolean")
  local changed = active.presentationReady ~= ready
  active.presentationReady = ready
  return changed
end

function PcApplicationHost:result(handle)
  local active = activeFor(self, handle)
  if active.result == nil or active.resultTaken then
    return nil
  end
  active.resultTaken = true
  return { kind = active.result.kind }
end

function PcApplicationHost:close(handle)
  local active = self._active
  if active == nil then
    return
  end
  assert(handle == active.handle, "PC application handle is stale or foreign")
  disposeChild(active.child)
  self._active = nil
end

function PcApplicationHost:status()
  local active = self._active
  if active == nil then
    return nil
  end
  local status = {}
  for key, value in pairs(active.child:status()) do
    status[key] = value
  end
  status.app = active.app
  status.presentationReady = active.presentationReady
  return status
end

function PcApplicationHost:draw(resources)
  local active = assert(self._active, "no PC application is open")
  if not active.presentationReady then
    return
  end
  assert(type(active.child.draw) == "function", "PC child owns its draw route")
  active.child:draw(resources, active.child:status())
end

function PcApplicationHost:cancelPointerCapture()
  local active = self._active
  if active ~= nil and type(active.child.cancelPointerCapture) == "function" then
    active.child:cancelPointerCapture()
  end
end

function PcApplicationHost:cancel(_)
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

function PcApplicationHost:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:cancel("field teardown")
end

return PcApplicationHost
