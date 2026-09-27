-- Script-owned party selection host: one visible PartyScreenState in
-- pick context per open, driven by scheduler UI events only. The host
-- owns the screen, its controller, and its presentation session; the
-- task owns an opaque handle plus value-only focus. Scheduler input is
-- the only driver; rendering observes status without advancing it.
-- An empty party with cancel permission opens an empty shell focused
-- on cancel; without cancel permission the open is a typed invalid
-- request. One open at a time; a second open is a composition error.

local Errors = require("libs.errors.src.Errors")
local PartyScreenState = require("game.hgss.src.field.PartyScreenState")
local ScriptErrors = require("libs.script.src.errors")

---@class PartySelectionHost
---@field private _service table<string, unknown> the live mon service
---@field private _manifest table<string, unknown> the validated party manifest
---@field private _measureDisplay fun(): table<string, unknown> the current display facts
---@field private _prepareIcons fun(iconKeys: string[]): boolean, string? presented icon preparation (borrowed binding)
---@field private _cancelIconPreparation fun() presented preparation release (borrowed binding)
---@field private _uiManifest table<string, unknown>? the field-UI manifest
---@field private _overrides table<string, unknown>? per-case screen overrides
---@field private _nextId integer the next open handle identity
---@field private _active table<string, unknown>? the open selection record
local PartySelectionHost = {}
PartySelectionHost.__index = PartySelectionHost

---@param opts table<string, unknown> host dependencies
---@return table<string, unknown> the script party host
function PartySelectionHost.new(opts)
  assert(type(opts) == "table", "the script party host requires its dependencies")
  local service = assert(opts.service, "the script party host requires the live mon service")
  local manifest = assert(opts.manifest, "the script party host requires the validated party manifest")
  assert(type(manifest) == "table", "the script party host requires the validated party manifest")
  local measureDisplay = assert(opts.measureDisplay, "the script party host requires the display facts")
  assert(type(measureDisplay) == "function", "the script party host requires the display facts")
  local prepareIcons = assert(opts.prepareIcons, "the script party host requires its icon preparation")
  assert(type(prepareIcons) == "function", "the script party host requires its icon preparation")
  local cancelIconPreparation =
    assert(opts.cancelIconPreparation, "the script party host requires its preparation release")
  assert(type(cancelIconPreparation) == "function", "the script party host requires its preparation release")
  return setmetatable({
    _service = service,
    _manifest = manifest,
    _measureDisplay = measureDisplay,
    _prepareIcons = prepareIcons,
    _cancelIconPreparation = cancelIconPreparation,
    _uiManifest = opts.uiManifest,
    _overrides = opts.overrides,
    _nextId = 0,
    _active = nil,
  }, PartySelectionHost)
end

---@param focus integer|"cancel" the value-only opening focus
---@return integer|"cancel" the focus the screen can honor
local function checkFocus(focus)
  if focus == "cancel" then
    return "cancel"
  end
  assert(
    type(focus) == "number" and focus % 1 == 0 and focus >= 0 and focus < 6,
    "the script selection opens on a party slot in 0..5 or cancel"
  )
  return focus
end

-- Opens one pick-context party screen (or the empty shell) for a
-- value-only request. A second open while one is active is a composition
-- error. An empty party without cancel permission is a typed invalid
-- request, never a silent wait.
---@param request table<string, unknown> { focus: integer|"cancel", allowCancel: boolean, policy: string }
---@return table<string, unknown> the opaque open handle
function PartySelectionHost:open(request)
  assert(type(request) == "table", "the script selection opens from a value-only request")
  assert(type(request.allowCancel) == "boolean", "the script selection open carries cancel permission")
  assert(type(request.policy) == "string", "the script selection open carries the named policy")
  assert(self._active == nil, "a script party selection is already open")
  local service = assert(self._service, "the script party host requires the live mon service")
  assert(type(service.partyCount) == "function", "the script party host requires the live mon service")
  local focus = checkFocus(request.focus)
  if service:partyCount() == 0 then
    if not request.allowCancel then
      Errors.raise(
        ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
        "party selection has no selectable slot and cancel is refused",
        {}
      )
    end
    self._nextId = self._nextId + 1
    local handle = { id = self._nextId }
    self._active = { handle = handle, screen = nil, empty = true }
    return handle
  end
  local screen = PartyScreenState.new({
    service = service,
    manifest = self._manifest,
    uiManifest = self._uiManifest,
    context = "pick",
    initialFocus = focus,
    measureDisplay = self._measureDisplay,
    overrides = self._overrides,
    prepareIcons = self._prepareIcons,
    cancelIconPreparation = self._cancelIconPreparation,
  })
  self._nextId = self._nextId + 1
  local handle = { id = self._nextId }
  self._active = { handle = handle, screen = screen, empty = false }
  return handle
end

-- Whether a selection is open. The session input lane reads this
-- every tick to route the normalized UI batch while script selection
-- owns it, mirroring the starter lane.
---@return boolean
function PartySelectionHost:isActive()
  return self._active ~= nil
end

-- The live handle owned by this host, or nil when no selection is open.
-- The task recovers its handle through this accessor every poll so the
-- opaque handle never enters serializable task state.
---@return table<string, unknown>? the active open handle
function PartySelectionHost:activeHandle()
  if self._active == nil then
    return nil
  end
  return self._active.handle
end

---@param handle table<string, unknown>
---@return table<string, unknown> the open selection record
local function checkHandle(self, handle)
  assert(type(handle) == "table", "the script selection handle is required")
  local active = assert(self._active, "no script party selection is open")
  assert(handle == active.handle, "the handle names a stale script selection")
  return active
end

-- One fixed tick of scheduler UI events through the open screen. An
-- empty shell holds cancel focus without a screen to step.
---@param handle table<string, unknown>
---@param uiEvents table[] the scheduler event list
---@return table<string, unknown>? the read-only screen status
function PartySelectionHost:step(handle, uiEvents)
  local active = checkHandle(self, handle)
  assert(type(uiEvents) == "table", "the script selection steps on the scheduler event list")
  if active.empty then
    -- The empty shell holds cancel focus without a screen to step: a
    -- confirm answers cancelled exactly once, anything else holds.
    for _, event in ipairs(uiEvents) do
      if type(event) == "table" and event.type == "confirm" and active.pending == nil then
        active.pending = { kind = "cancelled" }
      end
    end
    return self:status()
  end
  local screen = assert(active.screen, "the open selection owns its screen")
  screen:updateFixed(uiEvents)
  return self:status()
end

-- The one-shot semantic answer: selected with its slot, or cancelled.
-- Nil until the screen answers; nil again once consumed.
---@param handle table<string, unknown>
---@return table<string, unknown>? { kind: "selected", slot: integer } or { kind: "cancelled" }
function PartySelectionHost:result(handle)
  local active = checkHandle(self, handle)
  if active.empty then
    local pending = active.pending
    active.pending = nil
    return pending
  end
  local screen = assert(active.screen, "the open selection owns its screen")
  local record = screen:takeResult()
  if record == nil then
    return nil
  end
  if record.kind == "selected" then
    assert(type(record.slot) == "number", "selection answers on a party slot")
    return { kind = "selected", slot = record.slot }
  end
  if record.kind == "cancelled" then
    return { kind = "cancelled" }
  end
  Errors.raise(
    ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
    "the picking screen closed without a selection",
    { kind = record.kind }
  )
  error("unreachable script selection result", 0)
end

-- The live semantic focus: a party slot in 0..5, or cancel.
---@param handle table<string, unknown>
---@return integer|"cancel"
function PartySelectionHost:focus(handle)
  local active = checkHandle(self, handle)
  if active.empty then
    return "cancel"
  end
  local screen = assert(active.screen, "the open selection owns its screen")
  local status = screen:status()
  local node = status.cursorNode
  if node == "cancel" then
    return node
  end
  assert(type(node) == "number", "the script selection focuses a slot or cancel")
  assert(node % 1 == 0 and node >= 0 and node < 6, "the script selection focuses a slot in 0..5")
  return node
end

-- Releases the open screen exactly once. Closing an idle or foreign
-- handle is a composition fault, never a silent success.
---@param handle table<string, unknown>
function PartySelectionHost:close(handle)
  local active = checkHandle(self, handle)
  if active.screen ~= nil then
    active.screen:dispose()
  end
  self._active = nil
end

-- The read-only presentation snapshot for renderers: nil when idle, the
-- live screen status while open, or the empty shell record. Never
-- advances the screen.
---@return table<string, unknown>?
function PartySelectionHost:status()
  local active = self._active
  if active == nil then
    return nil
  end
  if active.empty then
    return { open = true, empty = true, focus = "cancel", context = "pick" }
  end
  local screen = assert(active.screen, "the open selection owns its screen")
  return screen:status()
end

-- Releases any open selection without writing a result: the teardown
-- backstop when a script dies with its selector open. Idempotent.
function PartySelectionHost:dispose()
  local active = self._active
  if active == nil then
    return
  end
  if active.screen ~= nil then
    active.screen:dispose()
  end
  self._active = nil
end

return PartySelectionHost
