-- Owns one script-opened mart child and its return to the paused field.

local MartHost = {}
MartHost.__index = MartHost

---@class MartHostActive
---@field handle table<string, unknown>
---@field owner string
---@field descriptor table<string, unknown>
---@field context table<string, unknown>
---@field stock table<string, unknown>?
---@field session table<string, unknown>?
---@field child table<string, unknown>?
---@field result { kind: string }?
---@field resultTaken boolean

---@class MartHost
---@field _service MartService
---@field _catalog table<string, unknown>
---@field _profile table<string, unknown>
---@field _localDate fun(): table<string, unknown>
---@field _stockResolver fun(descriptor: table<string, unknown>, context: table<string, unknown>, catalog: table<string, unknown>): table<string, unknown>
---@field _getFlag fun(flag: integer): boolean
---@field _getVar fun(variable: integer): integer
---@field _createBuy fun(session: table<string, unknown>): table<string, unknown>
---@field _createSell fun(session: table<string, unknown>): table<string, unknown>
---@field _clearUi fun()
---@field _nextId integer
---@field _active MartHostActive?
---@field _disposed boolean
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

---@param opts table<string, unknown>
---@return MartHost
function MartHost.new(opts)
  assert(type(opts) == "table", "mart host options are required")
  local service = assert(opts.service, "mart host requires the live mart service")
  local catalog = assert(opts.catalog, "mart host requires the mart catalog pair")
  local profile = assert(opts.profile, "mart host requires the canonical profile")
  local localDate = assert(opts.localDate, "mart host requires the local date provider")
  local stockResolver = assert(opts.stockResolver, "mart host requires the stock resolver")
  local createBuy = assert(opts.createBuy, "mart host requires the purchase child factory")
  local createSell = assert(opts.createSell, "mart host requires the sale child factory")
  assert(type(service.processDate) == "function", "mart host requires date processing")
  assert(type(service.openBuy) == "function" and type(service.openSell) == "function", "mart host requires sessions")
  assert(type(localDate) == "function" and type(stockResolver) == "function", "mart host providers must be functions")
  assert(type(createBuy) == "function" and type(createSell) == "function", "mart child factories must be functions")
  assert(type(profile.badges) == "number" and type(profile.nationalDex) == "boolean", "mart profile facts are required")
  return setmetatable({
    _service = service,
    _catalog = catalog,
    _profile = profile,
    _localDate = localDate,
    _stockResolver = stockResolver,
    _getFlag = assert(opts.getFlag, "mart host requires flag lookup"),
    _getVar = assert(opts.getVar, "mart host requires variable lookup"),
    _createBuy = createBuy,
    _createSell = createSell,
    _clearUi = assert(opts.clearUi, "mart host requires field UI edge release"),
    _nextId = 0,
    _active = nil,
    _disposed = false,
  }, MartHost)
end

---@param self MartHost
---@param date table<string, unknown>
---@return table<string, unknown>
local function resolverContext(self, date)
  return {
    badges = self._profile.badges,
    nationalDex = self._profile.nationalDex,
    weekday = date.weekday,
    dayOrdinal = date.dayOrdinal,
    cardPrefix = self._service:cardPrefix(),
    readFlag = self._getFlag,
    readVariable = self._getVar,
  }
end

---@param self MartHost
---@param handle table<string, unknown>
---@return table<string, unknown>
local function activeFor(self, handle)
  local active = assert(self._active, "no script mart is open")
  assert(handle == active.handle, "mart handle is stale or belongs to another task")
  return active
end

---@param ownerKey string
---@param descriptor table<string, unknown>
---@return table<string, unknown> opaque task-owned handle
function MartHost:open(ownerKey, descriptor)
  assert(not self._disposed, "disposed mart host cannot open a child")
  assert(type(ownerKey) == "string" and ownerKey ~= "", "mart owner identity is required")
  assert(type(descriptor) == "table" and type(descriptor.kind) == "string", "mart launch descriptor is required")
  assert(self._active == nil, "a script mart is already open")

  local processedDate = self._service:processDate(self._localDate())
  local context = resolverContext(self, processedDate)
  local session
  local child
  local stock
  local ok, err = pcall(function()
    if descriptor.kind == "sell" then
      session = self._service:openSell()
      child = self._createSell(session)
    else
      if descriptor.kind == "custom" then
        stock = copy(assert(descriptor.stock, "custom mart requires validated stock"))
      else
        stock = self._stockResolver(copy(descriptor), copy(context), self._catalog)
      end
      assert(type(stock) == "table", "mart stock resolver must return a stock record")
      session = self._service:openBuy(stock)
      child = self._createBuy(session)
    end
    assert(type(child) == "table", "mart child factory must return a child")
    assert(type(child.status) == "function", "mart child must expose presentation status")
    assert(type(child.takeResult) == "function", "mart child must expose a terminal result")
    self._clearUi()
  end)
  if not ok then
    if child ~= nil and type(child.dispose) == "function" then
      child:dispose()
    end
    if session ~= nil and type(session.close) == "function" and not session.closed then
      session:close()
    end
    error(err, 0)
  end

  self._nextId = self._nextId + 1
  local handle = { id = self._nextId, owner = ownerKey }
  self._active = {
    handle = handle,
    owner = ownerKey,
    descriptor = copy(descriptor),
    context = context,
    stock = stock,
    session = assert(session),
    child = assert(child),
    result = nil,
    resultTaken = false,
  }
  return handle
end

---@return boolean
function MartHost:isActive()
  return self._active ~= nil
end

---@return table<string, unknown>?
function MartHost:activeHandle()
  return self._active and self._active.handle or nil
end

---@param handle table<string, unknown>
---@param uiEvents table[]
function MartHost:step(handle, uiEvents)
  local active = activeFor(self, handle)
  assert(type(uiEvents) == "table", "mart host consumes scheduler UI events")
  if active.result ~= nil then
    return
  end
  if active.descriptor.kind == "sell" then
    active.child:updateFixed(uiEvents)
  else
    active.child:step(uiEvents)
  end
  local result = active.child:takeResult()
  if result == nil then
    return
  end
  assert(result.kind == "close", "mart child must complete by returning to the field")
  active.child:cancelPointerCapture()
  active.child:dispose()
  active.child = nil
  active.session:close()
  active.session = nil
  active.result = { kind = "close" }
end

---@param handle table<string, unknown>
---@return table<string, unknown>? one terminal field-return result
function MartHost:result(handle)
  local active = activeFor(self, handle)
  if active.result == nil or active.resultTaken then
    return nil
  end
  active.resultTaken = true
  return copy(active.result)
end

---@param kind "athlete_available"|"card_prefix"
---@return integer
function MartHost:query(kind)
  assert(not self._disposed, "disposed mart host cannot answer queries")
  assert(kind == "athlete_available" or kind == "card_prefix", "unknown mart query")
  local context
  local active = self._active
  if active ~= nil then
    context = active.context
  else
    local date = self._service:processDate(self._localDate())
    context = resolverContext(self, date)
  end
  if kind == "card_prefix" then
    return self._service:cardPrefix()
  end
  local stock = self._stockResolver({ kind = "athlete" }, copy(context), self._catalog)
  return self._service:athleteAvailable(stock) and 1 or 0
end

function MartHost:refreshPresentation()
  local active = self._active
  if active ~= nil and active.child ~= nil then
    active.child:refreshPresentation()
  end
end

function MartHost:cancelPointerCapture()
  local active = self._active
  if active ~= nil and active.child ~= nil then
    active.child:cancelPointerCapture()
  end
end

---@return table<string, unknown>? read-only active child presentation snapshot
function MartHost:status()
  local active = self._active
  if active == nil or active.child == nil then
    return nil
  end
  local status = active.child:status()
  status.martKind = active.descriptor.kind == "sell" and "sell" or "buy"
  return status
end

---@param handle table<string, unknown>
function MartHost:close(handle)
  local active = activeFor(self, handle)
  if active.child ~= nil then
    active.child:cancelPointerCapture()
    active.child:dispose()
    active.child = nil
  end
  if active.session ~= nil and not active.session.closed then
    active.session:close()
    active.session = nil
  end
  self._clearUi()
  self._active = nil
end

function MartHost:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

return MartHost
