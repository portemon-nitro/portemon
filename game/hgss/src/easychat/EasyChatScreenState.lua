-- The per-open Easy Chat screen: one controller, one resource lease,
-- and only presentation-local state. It owns the readiness key, the
-- committed bundle, the application presentation session, and the
-- entry/exit fades; it never duplicates editor policy or resource
-- acquisition. Each fixed update resolves fresh display facts, maps input
-- through the current plan, advances the controller once with matching
-- readiness, and prepares at most one finite lease. Preparation or
-- controller failure cleans ownership and propagates the original cause.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local EasyChatInterface = require("game.hgss.src.easychat.EasyChatInterface")

---@class EasyChatScreenState
---@field _controller table<string, unknown> borrowed editor policy owner
---@field _lease table<string, unknown> acquired per-open preparation lease
---@field _measureDisplay fun(): table<string, unknown> fresh host display facts
---@field _effect fun(sequence: unknown)? borrowed audio effect sink
---@field _session ApplicationPresentation owned presentation session
---@field _catalog table<string, unknown>? borrowed word catalog behind sentence drawing
---@field _cacheFs CacheFs? borrowed cache filesystem for stub-lease text
---@field _menu table<string, unknown>? detached per-open menu snapshot
---@field _assets table<string, unknown>? last committed whole ready bundle
---@field _phase string preparing, editor, exit, done, failed
---@field _entryTick integer entry fade updates since commit
---@field _exitTick integer exit fade updates since terminal latch
---@field _preparationError string? nonempty cause behind the failed phase
---@field _published table<string, unknown>? latched terminal result, read once
---@field _consumed boolean true once the terminal result is taken
---@field _view table<string, unknown> latest detached projection
---@field _disposed boolean
---@field uiInput table<string, unknown> finite modal input profile for the host session
local EasyChatScreenState = {}
EasyChatScreenState.__index = EasyChatScreenState

-- The finite modal input profile the screen advertises: shoulder and
-- menu buttons with the source 8-tick initial delay and 4-tick repeat,
-- plus held-direction facts. Only this opt-in profile receives extra or
-- held events; default siblings keep their exact previous behavior.
local UI_INPUT_PROFILE = {
  buttons = { l = true, r = true, start = true, select = true },
  repeatDelay = 8,
  repeatInterval = 4,
  heldDirections = true,
}

-- Signed 1/128 fixed-point fade recurrence (screen_fade_effects.c):
-- truncate the step toward zero, add per update, force the exact target
-- on the final step. Displayed brightness truncates toward zero.
---@param from integer
---@param to integer
---@param steps integer
---@param elapsed integer updates since the initial level
---@return integer brightness
local function fadeBrightness(from, to, steps, elapsed)
  if elapsed <= 0 then
    return from
  end
  if elapsed >= steps then
    return to
  end
  local delta = to - from
  local step = delta * 128 / steps
  if step >= 0 then
    step = math.floor(step)
  else
    step = math.ceil(step)
  end
  return math.floor((from * 128 + step * elapsed) / 128)
end

---@class EasyChatScreenState.Options
---@field controller table<string, unknown> borrowed editor policy owner
---@field lease table<string, unknown> acquired per-open preparation lease
---@field measureDisplay fun(): table<string, unknown> the current display facts
---@field overrides table<string, unknown>? existing presentation overrides
---@field effect (fun(sequence: unknown))? borrowed audio effect sink
---@field catalog table<string, unknown>? borrowed word catalog behind sentence drawing
---@field cacheFs CacheFs? borrowed cache filesystem for stub-lease text
---@field menu table<string, unknown>? detached per-open menu snapshot

---@param opts EasyChatScreenState.Options
---@return EasyChatScreenState
function EasyChatScreenState.new(opts)
  assert(type(opts) == "table", "the editor screen requires its options")
  local controller = assert(opts.controller, "the editor screen requires its controller")
  assert(type(controller.updateFixed) == "function", "the editor controller steps per fixed tick")
  assert(type(controller.view) == "function", "the editor controller projects its view")
  assert(type(controller.takeResult) == "function", "the editor controller publishes its result")
  assert(type(controller.dispose) == "function", "the editor controller releases its lifetime")
  local lease = assert(opts.lease, "the editor screen requires its preparation lease")
  assert(type(lease.prepare) == "function", "the preparation lease prepares per fixed tick")
  assert(type(lease.release) == "function", "the preparation lease releases exactly once")
  assert(type(opts.measureDisplay) == "function", "the editor screen requires the display facts")
  assert(opts.overrides == nil or type(opts.overrides) == "table", "the presentation overrides must be a record")
  assert(opts.effect == nil or type(opts.effect) == "function", "the editor sound boundary must be a function")
  if opts.menu ~= nil then
    assert(type(opts.menu) == "table", "the editor screen borrows its per-open menu snapshot")
    assert(type(opts.menu.groups) == "table" and type(opts.menu.initials) == "table", "the menu carries its lists")
  end
  local session = ApplicationPresentation.new(EasyChatInterface.defaults(), opts.overrides)
  local self = setmetatable({
    _controller = controller,
    _lease = lease,
    _measureDisplay = opts.measureDisplay,
    _effect = opts.effect,
    _session = session,
    _catalog = opts.catalog,
    _cacheFs = opts.cacheFs,
    _menu = opts.menu,
    _assets = nil,
    _phase = "preparing",
    _entryTick = 0,
    _exitTick = 0,
    _preparationError = nil,
    _published = nil,
    _consumed = false,
    _released = false,
    _view = { mode = 0, level = "composition", time = 0, inputMode = "buttons" },
    _disposed = false,
    uiInput = UI_INPUT_PROFILE,
  }, EasyChatScreenState)
  return self
end

---@param self EasyChatScreenState
function EasyChatScreenState:_releaseLease()
  if self._released then
    return
  end
  self._released = true
  local lease = self._lease
  self._lease = nil
  if lease ~= nil then
    lease:release()
  end
end

---@param self EasyChatScreenState
---@param assets table<string, unknown> committed whole ready bundle
---@return table<string, unknown> enriched bundle with its renderer
function EasyChatScreenState:_commitBundle(assets)
  assert(type(assets) == "table", "the committed bundle stays a record")
  -- Stub leases behind the documented binding carry no GPU bundle; the
  -- editor still commits its lifecycle over an empty presentation while
  -- production leases always carry the whole bundle.
  local manifest = assets.manifest
  if manifest == nil then
    manifest = { layers = {}, buttons = {}, sequences = {}, palettes = {} }
  end
  local images = assets.images
  if images == nil then
    images = {}
  end
  local bundle = {
    manifest = manifest,
    images = images,
    text0 = assets.text0,
    text1 = assets.text1,
    text4 = assets.text4,
    window = assets.window,
    prompt = assets.prompt,
    menu = assets.menu or self._menu,
    interface = assets.interface,
  }
  local catalog = self._catalog
  if bundle.interface == nil and type(catalog) == "table" and type(catalog.interface) == "table" then
    bundle.interface = catalog.interface
  end
  if assets.renderer ~= nil then
    bundle.renderer = assets.renderer
    return bundle
  end
  -- Stub leases without realized images commit textless: attempting GPU
  -- realization here would trip the headless render trap. Leases carrying
  -- realized images prove a GPU-backed presentation context, so the
  -- screen realizes its standalone text owners then.
  local realizedImages = false
  for _ in pairs(images) do
    realizedImages = true
    break
  end
  if bundle.text0 == nil and realizedImages and self._cacheFs ~= nil then
    local ok, text0 = pcall(function()
      local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
      return FieldTextRenderer.new({ cacheFs = self._cacheFs, fontId = 0 })
    end)
    if ok then
      bundle.text0 = text0
    end
  end
  if bundle.text1 == nil and realizedImages and self._cacheFs ~= nil then
    local ok, text1 = pcall(function()
      local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
      return FieldTextRenderer.new({ cacheFs = self._cacheFs, fontId = 1 })
    end)
    if ok then
      bundle.text1 = text1
    end
  end
  if bundle.text4 == nil and realizedImages and self._cacheFs ~= nil then
    local ok, text4 = pcall(function()
      local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
      return FieldTextRenderer.new({ cacheFs = self._cacheFs, fontId = 4 })
    end)
    if ok then
      bundle.text4 = text4
    end
  end
  local EasyChatRenderer = require("libs.hgss.src.ui.EasyChatRenderer")
  local renderer = EasyChatRenderer.new({
    manifest = manifest,
    images = images,
    text0 = bundle.text0,
    text1 = bundle.text1,
    text4 = bundle.text4,
    window = bundle.window,
    prompt = bundle.prompt,
  })
  bundle.renderer = renderer
  return bundle
end

---@param self EasyChatScreenState
---@param events table[]
function EasyChatScreenState:_stepPreparing(events)
  assert(type(events) == "table", "preparation steps over the event batch")
  local lease = assert(self._lease, "preparation steps resolve their lease")
  local ok, outcome = pcall(lease.prepare, lease)
  if not ok then
    local cause = outcome
    self:_releaseLease()
    self._phase = "failed"
    self._preparationError = tostring(cause)
    error(cause, 0)
  end
  assert(type(outcome) == "table", "the preparation lease reports its state")
  if outcome.kind == "failed" then
    local cause = outcome.error or "editor preparation failed"
    self:_releaseLease()
    self._phase = "failed"
    self._preparationError = tostring(cause)
    error(cause, 0)
  end
  if outcome.kind == "ready" then
    local commitOk, bundle = pcall(function()
      return self:_commitBundle(assert(outcome.assets, "the ready bundle carries its assets"))
    end)
    if not commitOk then
      self:_releaseLease()
      self._phase = "failed"
      self._preparationError = tostring(bundle)
      error(bundle, 0)
    end
    self._assets = bundle
    self._phase = "editor"
    self._entryTick = 0
  end
end

---@param self EasyChatScreenState
---@param events table[]
function EasyChatScreenState:_stepEditor(events)
  local measurement = self:_measureDisplay()
  local status = self:status()
  self._session:resolve(measurement, status)
  local mapped = self._session:mapInput(events, status)
  if self._entryTick < 7 then
    self._entryTick = self._entryTick + 1
  end
  local controller = assert(self._controller, "editor steps resolve their controller")
  local ok, failure = pcall(controller.updateFixed, controller, mapped)
  if not ok then
    self:_releaseLease()
    self._phase = "failed"
    self._preparationError = tostring(failure)
    if self._controller ~= nil then
      self._controller = nil
    end
    error(failure, 0)
  end
  local view = controller:view()
  if type(view) == "table" and view.exiting == true and self._published == nil then
    self._phase = "exit"
    self._exitTick = 0
  end
  self._view = self:_projectView()
end

---@param self EasyChatScreenState
function EasyChatScreenState:_stepExit()
  local controller = self._controller
  if controller ~= nil then
    local ok, failure = pcall(controller.updateFixed, controller, {})
    if not ok then
      self._phase = "failed"
      self._preparationError = tostring(failure)
      self._controller = nil
      error(failure, 0)
    end
  end
  self._exitTick = self._exitTick + 1
  self._view = self:_projectView()
  if self._exitTick >= 7 then
    self._phase = "done"
    if controller ~= nil then
      self._published = controller:takeResult()
    end
  end
end

-- One fixed tick: preparation advances the lease alone; the editor maps
-- input through the current plan and advances the controller once;
-- the exit fade runs after the terminal latch. Status reads never tick.
---@param events table[]
function EasyChatScreenState:updateFixed(events)
  assert(type(events) == "table", "the editor input must be an event list")
  if self._disposed then
    return
  end
  if self._phase == "preparing" then
    self:_stepPreparing(events)
  elseif self._phase == "editor" then
    self:_stepEditor(events)
  elseif self._phase == "exit" then
    self:_stepExit()
  end
  local measurement = self:_measureDisplay()
  self._session:resolve(measurement, {
    preparing = self._phase == "preparing",
    assets = self._assets,
  })
  self._resolved = true
end

---@param self EasyChatScreenState
---@return table<string, unknown> detached controller projection
function EasyChatScreenState:_projectView()
  local controller = self._controller
  if controller == nil then
    return { mode = 0, level = "composition", time = 0, inputMode = "buttons" }
  end
  local view = controller:view()
  assert(type(view) == "table", "the editor controller projects its view")
  return view
end

-- The presentation snapshot: the published plan, the editor view with
-- its brightness cover, the committed assets once whole, readiness, and
-- the direct input key. Fresh tables per call; status never ticks.
---@return table<string, unknown>
function EasyChatScreenState:status()
  if not self._resolved then
    local measurement = self:_measureDisplay()
    self._session:resolve(measurement, {
      preparing = self._phase == "preparing",
      assets = self._assets,
    })
    self._resolved = true
  end
  local preparing = self._phase == "preparing"
  local brightness = nil
  if self._phase == "editor" and self._entryTick < 7 then
    brightness = fadeBrightness(16, 0, 5, self._entryTick)
  elseif self._phase == "exit" then
    brightness = fadeBrightness(0, 16, 6, self._exitTick)
  elseif self._phase == "done" then
    brightness = 16
  end
  local status = {
    presentation = self._session:plan(),
    view = self._view,
    preparing = preparing,
    uiInput = preparing and EasyChatInterface.INACTIVE_INPUT_KEY or EasyChatInterface.INPUT_KEY,
    brightness = brightness,
  }
  if self._assets ~= nil then
    status.assets = self._assets
  end
  if self._preparationError ~= nil then
    status.preparationError = self._preparationError
  end
  if self._catalog ~= nil then
    status.catalog = self._catalog
  end
  return status
end

-- Delivers the terminal result exactly once after the exit fade
-- completes, or nil while the edit is still open. Disposal abandons an
-- untaken result.
---@return table<string, unknown>? detached terminal result
function EasyChatScreenState:takeResult()
  if self._disposed or self._consumed then
    return nil
  end
  local result = self._published
  if result == nil then
    return nil
  end
  self._consumed = true
  self._published = nil
  return result
end

-- Drops the session capture and the editor touch capture so a stale
-- release never activates after focus loss or an input-mode change.
function EasyChatScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  if self._controller ~= nil then
    self._controller:cancelPointerCapture()
  end
end

-- Idempotent release of the per-open lifetime: the session, controller,
-- and lease release exactly once in every phase; a pending result is
-- discarded and no result is reported after disposal.
function EasyChatScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  if self._controller ~= nil then
    self._controller:dispose()
    self._controller = nil
  end
  self:_releaseLease()
  self._published = nil
end

return EasyChatScreenState
