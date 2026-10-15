-- Owns the one script-opened companion application behind a shared
-- feature lease. Normal menu entry stays with the field application host;
-- script entry opens here and blocks on its scheduler task, but both build
-- the same card controller and conversation engine underneath. At most one
-- handle is active: a second open while the lease is held is an attributed
-- refusal naming the lease, never a steal and never a deadlock. Staged
-- setup requests wait outside the lease keyed by their script session and
-- are consumed once; a terminal result reads back until the owner closes
-- the handle, and closing releases exactly once without rolling back
-- committed effects. This host never owns input routing: the field
-- application host owns normal input and the script modal lane owns script
-- input. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local PhoneController = require("game.hgss.src.pokegear.PhoneController")

---@class PokegearScriptHost
---@field _state table<string, unknown> the borrowed durable companion owner
---@field _catalog table<string, unknown> the borrowed contact catalog
---@field _messages table<string, unknown> the borrowed message references
---@field _world table<string, unknown> the borrowed world fixture
---@field _assets table<string, unknown>? the borrowed compiled family behind the map entries
---@field _regionMapOwners (fun(): table<string, unknown>, table<string, unknown>)? the region map text and flag owners
---@field _audio table<string, unknown>? the borrowed audio boundary
---@field _random table<string, unknown>? the borrowed companion streams
---@field _active table<string, unknown>? the live application record
---@field _lastResult table<string, unknown>? the retained terminal result of the last cancelled call
---@field _staged table<string, table<string, string>> staged setup requests by session key
---@field _nextId integer
---@field _disposed boolean
local PokegearScriptHost = {}
PokegearScriptHost.__index = PokegearScriptHost

local MODES = { call = true, townMap = true, fly = true }

---@param value unknown
---@return boolean
local function isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

---@param opts table<string, unknown>
---@return PokegearScriptHost
function PokegearScriptHost.new(opts)
  assert(type(opts) == "table", "the companion host borrows its owners through a record")
  assert(type(opts.state) == "table", "the companion host borrows the companion state")
  assert(type(opts.catalog) == "table", "the companion host borrows the contact catalog")
  assert(type(opts.messages) == "table", "the companion host borrows its message references")
  assert(type(opts.world) == "table", "the companion host borrows its world")
  assert(opts.audio == nil or type(opts.audio) == "table", "the companion host uses the audio boundary as a record")
  assert(opts.random == nil or type(opts.random) == "table", "the companion host draws through the companion streams")
  assert(
    opts.assets == nil or type(opts.assets) == "table",
    "the companion host borrows the compiled family as a record"
  )
  assert(
    opts.regionMapOwners == nil or type(opts.regionMapOwners) == "function",
    "the companion host reads the region map owners through a function"
  )
  return setmetatable({
    _assets = opts.assets,
    _regionMapOwners = opts.regionMapOwners,
    _state = opts.state,
    _catalog = opts.catalog,
    _messages = opts.messages,
    _world = opts.world,
    _audio = opts.audio,
    _random = opts.random,
    _active = nil,
    _lastResult = nil,
    _staged = {},
    _nextId = 0,
    _disposed = false,
  }, PokegearScriptHost)
end

---@param request unknown
local function checkCallRequest(request)
  if type(request) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion calls open through a request record", {})
  end
  assert(type(request) == "table", "companion call requests stay records")
  local record = request --[[@as table<string, unknown>]]
  for _, name in ipairs({ "id", "contact", "direction", "kind" }) do
    if not isNonEmptyString(record[name]) then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "companion call requests name their " .. name,
        { field = name }
      )
    end
  end
end

---@param self PokegearScriptHost
---@param handle unknown
---@return table<string, unknown> the live application record
local function activeFor(self, handle)
  local active = self._active
  if active == nil then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "no companion application is open", {})
  end
  assert(active ~= nil, "companion handle checks read the live application")
  local record = active --[[@as table<string, unknown>]]
  if handle ~= record.handle then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion application handle is stale or foreign", {})
  end
  return record
end

-- Validates one Fly field-move selection into a detached record: the
-- initiating party slot and revision, the current map context, and the
-- source-permitted destination set. Malformed combinations fail with
-- attribution before any lease or map effect.
---@param selection unknown
---@return table<string, unknown> the detached validated selection
local function checkFlySelection(selection)
  if type(selection) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion fly selection carries its field-move choice", {})
  end
  assert(type(selection) == "table", "fly selections stay records")
  local record = selection --[[@as table<string, unknown>]]
  local slot = record.slot
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 5 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion fly selection names its party slot", {})
  end
  local partyRevision = record.partyRevision
  if partyRevision ~= nil and (type(partyRevision) ~= "number" or partyRevision % 1 ~= 0) then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion fly selection carries its party revision", {})
  end
  local mapContext = record.mapContext
  if type(mapContext) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion fly selection carries its map context", {})
  end
  assert(type(mapContext) == "table", "fly map contexts stay records")
  local context = mapContext --[[@as table<string, unknown>]]
  if
    type(context.fieldMap) ~= "string"
    or type(context.location) ~= "string"
    or type(context.matrixX) ~= "number"
    or type(context.matrixY) ~= "number"
    or type(context.region) ~= "string"
    or type(context.unlockLevel) ~= "number"
    or (context.specialMode ~= nil and type(context.specialMode) ~= "string")
    or type(context.playerGender) ~= "string"
  then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion fly selection carries its map context", {})
  end
  local destinations = record.destinations
  if type(destinations) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion fly selection carries its destinations", {})
  end
  assert(type(destinations) == "table", "fly destinations stay lists")
  local keys = {}
  for index, key in
    ipairs(destinations --[[@as table]])
  do
    if type(key) ~= "string" or key == "" then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion fly destinations name semantic flypoints", {})
    end
    keys[index] = key
  end
  return {
    slot = slot,
    partyRevision = partyRevision,
    mapContext = {
      fieldMap = context.fieldMap,
      location = context.location,
      matrixX = context.matrixX,
      matrixY = context.matrixY,
      region = context.region,
      unlockLevel = context.unlockLevel,
      specialMode = context.specialMode,
      playerGender = context.playerGender,
    },
    destinations = keys,
  }
end

-- Opens one companion application under the shared lease. Call, Town
-- map, and Fly entries each build their concrete child; unknown modes
-- and malformed mode/request combinations fail before any effect. A
-- failing construction takes no lease and keeps the original error.
---@param args { mode: string, request: table<string, unknown>?, selection: table<string, unknown>?, parentOwner: string }
---@return table<string, unknown> the active handle
function PokegearScriptHost:open(args)
  if self._disposed then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "a disposed companion host opens nothing", {})
  end
  assert(type(args) == "table", "companion applications open through a request record")
  if self._active ~= nil then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "a companion application already holds the feature lease",
      { mode = args.mode }
    )
  end
  if MODES[args.mode] ~= true then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "companion applications open in a known mode",
      { mode = args.mode }
    )
  end
  if not isNonEmptyString(args.parentOwner) then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion applications carry their parent identity", {})
  end
  if args.mode == "townMap" or args.mode == "fly" then
    return self:_openMap(args --[[@as table<string, unknown>]])
  end
  checkCallRequest(args.request)
  local request = args.request --[[@as table<string, string>]]
  local ok, controller = pcall(PhoneController.new, {
    state = self._state,
    catalog = self._catalog,
    messages = self._messages,
    world = self._world,
    audio = self._audio,
    random = self._random,
    request = { id = request.id, contact = request.contact, direction = request.direction, kind = request.kind },
  })
  if not ok then
    if Errors.is(controller) then
      error(controller, 0)
    end
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "companion call construction failed: " .. tostring(controller),
      { mode = args.mode }
    )
  end
  assert(type(controller) == "table", "companion construction returns its controller")
  self._nextId = self._nextId + 1
  self._lastResult = nil
  local handle = { id = self._nextId }
  self._active = {
    handle = handle,
    mode = args.mode,
    controller = controller,
    request = { id = request.id, contact = request.contact, direction = request.direction, kind = request.kind },
    parentOwner = args.parentOwner,
  }
  return handle
end

-- Opens the view-only Town map or the Fly destination selector under
-- the shared lease. Town maps open with parent identity only and never
-- receive a request or selection; Fly opens only with the authorized
-- parent field-move selection. The host lends its borrowed catalog to
-- the selector; full visuals arrive with the final composition, and the
-- selector paints procedurally until then. A failing construction takes
-- no lease and keeps the original error.
---@param args table<string, unknown>
---@return table<string, unknown> the active handle
function PokegearScriptHost:_openMap(args)
  local record = args --[[@as table<string, unknown>]]
  local mode = record.mode --[[@as string]]
  local selection = nil
  if mode == "fly" then
    if record.request ~= nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "companion fly opens through its field-move selection, never a call request",
        { mode = mode }
      )
    end
    selection = checkFlySelection(record.selection)
  elseif record.request ~= nil or record.selection ~= nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "companion town maps open view-only without a request or selection",
      { mode = mode }
    )
  end
  local FlyMapController = require("game.hgss.src.pokegear.FlyMapController")
  local regionMapOwners = self._regionMapOwners --[[@as (fun(): table<string, unknown>, table<string, unknown>)?]]
  if regionMapOwners == nil or self._assets == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "companion maps need the compiled family and the region map owners",
      { mode = mode }
    )
  end
  local messages, facts = (regionMapOwners --[[@as fun(): table<string, unknown>, table<string, unknown>]])()
  local identity = mode .. "-" .. tostring(self._nextId + 1)
  local ok, controller = pcall(FlyMapController.new, {
    mode = mode,
    operationId = identity,
    context = selection ~= nil and (selection --[[@as table<string, unknown>]]).mapContext or nil,
    destinations = selection ~= nil and (selection --[[@as table<string, unknown>]]).destinations or nil,
    assets = self._assets,
    messages = messages,
    facts = facts,
  })
  if not ok then
    if Errors.is(controller) then
      error(controller, 0)
    end
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "companion map construction failed: " .. tostring(controller),
      { mode = mode }
    )
  end
  assert(type(controller) == "table", "companion construction returns its controller")
  self._nextId = self._nextId + 1
  self._lastResult = nil
  local handle = { id = self._nextId }
  self._active = {
    handle = handle,
    mode = mode,
    controller = controller,
    parentOwner = record.parentOwner,
  }
  return handle
end

---@return boolean
function PokegearScriptHost:isActive()
  return self._active ~= nil
end

---@return table<string, unknown>?
function PokegearScriptHost:activeHandle()
  local active = self._active
  if active == nil then
    return nil
  end
  return (active --[[@as table<string, unknown>]]).handle --[[@as table<string, unknown>]]
end

-- Advances the live application one fixed step. Input that arrives after
-- the terminal result is retained without re-stepping, so repeated views
-- never duplicate an effect.
---@param handle table<string, unknown>
---@param events table[]
function PokegearScriptHost:step(handle, events)
  local active = activeFor(self, handle)
  assert(type(events) == "table", "companion applications step the event batch")
  local controller = active.controller --[[@as table<string, unknown>]]
  local takeResult = controller.takeResult --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
  if takeResult(controller) ~= nil then
    return
  end
  local updateFixed = controller.updateFixed --[[@as fun(self: table<string, unknown>, events: table)]]
  updateFixed(controller, events)
end

-- Reads back the one terminal result, or nil while the call is live. The
-- result stays readable until the owner closes the handle, including
-- after cancellation releases the lease: the cancelled terminal result is
-- retained once and reads back identically.
---@param handle table<string, unknown>
---@return table<string, unknown>?
function PokegearScriptHost:result(handle)
  local active = self._active
  if active ~= nil then
    local record = active --[[@as table<string, unknown>]]
    if handle ~= record.handle then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion application handle is stale or foreign", {})
    end
    local controller = record.controller --[[@as table<string, unknown>]]
    local takeResult = controller.takeResult --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
    return takeResult(controller)
  end
  local retained = self._lastResult
  if retained ~= nil then
    local entry = retained --[[@as table<string, unknown>]]
    if handle == entry.handle then
      local result = entry.result --[[@as table<string, unknown>]]
      local detached = {}
      for key, value in pairs(result) do
        detached[key] = value
      end
      return detached
    end
  end
  Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion application handle is stale or foreign", {})
  return nil
end

-- Releases the live application exactly once. Closing an idle host is a
-- no-op so cancellation-then-close unwinds once; closing a foreign handle
-- while another application is live fails without touching it.
---@param handle table<string, unknown>
function PokegearScriptHost:close(handle)
  local active = self._active
  if active == nil then
    local retained = self._lastResult
    if
      retained ~= nil and handle == (retained --[[@as table<string, unknown>]]).handle
    then
      self._lastResult = nil
    end
    return
  end
  local record = active --[[@as table<string, unknown>]]
  if handle ~= record.handle then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "companion application handle is stale or foreign", {})
  end
  local controller = record.controller --[[@as table<string, unknown>]]
  local dispose = controller.dispose --[[@as fun(self: table<string, unknown>)]]
  dispose(controller)
  self._active = nil
end

-- Cancels the live application: hangs its call up through the ordinary
-- input path so the terminal result stays available, retains that one
-- result, then releases the lease. Cancelling an idle host is a no-op,
-- so repeated cancellation unwinds once and stays terminal.
---@param reason string
function PokegearScriptHost:cancel(reason)
  assert(type(reason) == "string" and reason ~= "", "companion cancellation names its reason")
  local active = self._active
  if active == nil then
    return
  end
  local record = active --[[@as table<string, unknown>]]
  local controller = record.controller --[[@as table<string, unknown>]]
  local updateFixed = controller.updateFixed --[[@as fun(self: table<string, unknown>, events: table)]]
  updateFixed(controller, { { type = "cancel" } })
  local takeResult = controller.takeResult --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
  local terminal = takeResult(controller)
  if terminal ~= nil then
    self._lastResult = { handle = record.handle, result = terminal }
  end
  self:close(record.handle --[[@as table<string, unknown>]])
end

-- Save capture stays denied while a child owns the lease, including after
-- its terminal result until the return transition settles through close.
---@return boolean
function PokegearScriptHost:isStableForSave()
  return self._active == nil
end

-- Stages one evaluated setup request outside the lease under its script
-- session key. Staging never blocks and never touches the lease; a later
-- setup from the same session replaces its own pending request.
---@param ownerKey string
---@param request { contact: string, direction: string, kind: string }
function PokegearScriptHost:stageCall(ownerKey, request)
  if self._disposed then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "a disposed companion host stages nothing", {})
  end
  assert(isNonEmptyString(ownerKey), "staged phone requests carry their session key")
  assert(type(request) == "table", "staged phone requests stay records")
  local record = request --[[@as table<string, unknown>]]
  assert(
    isNonEmptyString(record.contact) and isNonEmptyString(record.direction) and isNonEmptyString(record.kind),
    "staged phone requests carry their evaluated call identity"
  )
  self._staged[ownerKey] = {
    contact = record.contact --[[@as string]],
    direction = record.direction --[[@as string]],
    kind = record.kind --[[@as string]],
  }
end

-- Consumes the staged setup request for one session key, or nil when the
-- session staged nothing. Consumption is exactly-once: a second take
-- finds nothing.
---@param ownerKey string
---@return table<string, string>?
function PokegearScriptHost:takeStagedCall(ownerKey)
  assert(isNonEmptyString(ownerKey), "staged phone requests carry their session key")
  local pending = self._staged[ownerKey]
  self._staged[ownerKey] = nil
  return pending
end

-- Answers the field rematch readiness query through a transient
-- conversation engine over the borrowed owners. Pure read: no lease, no
-- mutation.
---@param contact string
---@return { ready: boolean, tier: integer? }
function PokegearScriptHost:queryRematch(contact)
  assert(isNonEmptyString(contact), "rematch queries name their contact")
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local engine = PhoneCall.new({
    state = self._state,
    catalog = self._catalog,
    messages = self._messages,
    world = self._world,
    audio = self._audio,
    random = self._random,
  })
  return engine:queryRematch(contact)
end

-- Whether the named contact is acquired. Pure read through the durable
-- owner.
---@param contact string
---@return boolean
function PokegearScriptHost:isContactRegistered(contact)
  assert(isNonEmptyString(contact), "registration queries name their contact")
  local phone = (self._state --[[@as table<string, unknown>]]).readPhone
  assert(type(phone) == "function", "the companion host reads registration through the companion state")
  local projection = phone(self._state)
  assert(type(projection) == "table", "the companion state carries its phone projection")
  local contacts = (projection --[[@as table<string, unknown>]]).contacts
  assert(type(contacts) == "table", "the phone projection carries its registered contacts")
  return (contacts --[[@as table<string, unknown>]])[contact] ~= nil
end

-- Registers one catalogued contact through the durable owner. Unknown
-- contacts fail with attribution instead of staging a plausible entry.
---@param contact string
function PokegearScriptHost:registerContact(contact)
  assert(isNonEmptyString(contact), "contact registration names its contact")
  local register = (self._state --[[@as table<string, unknown>]]).registerContact
  assert(type(register) == "function", "the companion host registers through the companion state")
  register(self._state, contact)
end

-- Drops held pointer capture on the live child, if any.
function PokegearScriptHost:cancelPointerCapture()
  local active = self._active
  if active ~= nil then
    local controller = (active --[[@as table<string, unknown>]]).controller --[[@as table<string, unknown>]]
    local cancelCapture = (controller --[[@as table<string, unknown>]]).cancelPointerCapture
    if type(cancelCapture) == "function" then
      (cancelCapture --[[@as fun(self: table<string, unknown>)]])(controller)
    end
  end
end

-- Idempotent release of the logical lifetime: the live child unwinds
-- once, staged requests clear, and no later open succeeds.
function PokegearScriptHost:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:cancel("companion host teardown")
  self._staged = {}
end

return PokegearScriptHost
