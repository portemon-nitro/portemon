-- The per-open field Pokedex screen: one browser controller, one resource lease,
-- and only presentation-local state. It owns the readiness key, the
-- committed bundle, the application presentation session, and the private
-- compact record; it never duplicates search, form, or resource policy.
-- Each fixed update resolves fresh display facts, maps input through the
-- current plan, consumes private compact actions, advances the model once
-- with matching readiness, and prepares at most one finite demand.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local PokedexInterface = require("game.hgss.src.pokedex.PokedexInterface")

---@class PokedexScreenState
---@field _controller table<string, unknown> borrowed browser policy owner
---@field _lease table<string, unknown> acquired per-open preparation lease
---@field _measureDisplay fun(): table<string, unknown> fresh host display facts
---@field _effect fun(sequence: unknown) borrowed audio effect sink
---@field _playCry fun(species: string, pattern: integer, form: integer) borrowed cry sink
---@field _commitResume fun(resume: table<string, unknown>): boolean composed one-use resume publication
---@field _music fun(action: string)? borrowed optional field-music duck/restore sink
---@field _musicDucked boolean true after an actually applied duck until its balancing restore
---@field _session table<string, unknown> owned presentation session
---@field _readyKey integer? last matching resource generation behind admitted motion
---@field _view table<string, unknown> latest detached projection from the model
---@field _presentedView table<string, unknown>? last committed printable projection paired with the bundle
---@field _assets table<string, unknown>? last committed whole ready bundle
---@field _phase string active, failed
---@field _preparationError string? nonempty cause behind the failed phase
---@field _compact { inspect: boolean, size: string } private compact presentation record (host adaptation: single-display reflow, non-retail arrangement; model ids and art stay native)
---@field _compactMode boolean true while the measured display uses the compact arrangement
---@field _pointerHeld boolean true while an in-flight drag holds touch across ticks
---@field _activeDragTarget string? in-flight drag target behind transactional cancel
---@field _lastInputKey string? last published plan input geometry
---@field _terminal table<string, unknown>? observed one-use close result
---@field _disposed boolean
---@field page string current top-level page mirrored for host readers
---@field view table<string, unknown> current detached projection mirrored for host readers
---@field uiInput table<string, unknown> finite modal input profile mirrored for the host session
local PokedexScreenState = {}
PokedexScreenState.__index = PokedexScreenState

-- The finite modal input profile the screen advertises: seven extra buttons
-- with the source 8-tick initial delay, 4-tick continuous repeat, and
-- held-direction facts. Only this opt-in profile receives extra or held
-- events; default siblings keep their exact previous behavior.
local UI_INPUT_PROFILE = {
  buttons = { y = true, l = true, r = true, start = true, select = true, inspect = true, x = true },
  repeatDelay = 8,
  repeatInterval = 4,
  heldDirections = true,
}

-- Maps the live browser projection to its exact generated page role:
-- each open search editor names its own criteria page and an active
-- forms comparison names the compare page, never the generic parents.
---@param view table<string, unknown> detached browser projection
---@return string page role key for the demand
local function pageRoleFor(view)
  local page = view.page
  if page == "grid" or page == "cover" or page == "results" then
    return page
  end
  if page == "search" then
    local search = view.search
    if type(search) == "table" and type(search.editor) == "table" then
      local kind = search.editor.kind or search.editor.criterion
      if kind == "letter" then
        return "search.name"
      elseif kind == "order" then
        return "search.order"
      elseif kind == "type" then
        return "search.type"
      elseif kind == "height" then
        return "search.height"
      elseif kind == "weight" then
        return "search.weight"
      elseif kind == "area" then
        return "search.area"
      elseif kind == "shape" then
        return "search.shape"
      end
    end
    return "search.criteria"
  end
  if page == "area" or page == "size" then
    return "entry." .. page
  end
  if page == "forms" then
    local forms = view.forms
    if type(forms) == "table" and forms.comparison ~= nil then
      return "entry.compare"
    end
    return "entry.forms"
  end
  if page == "return" then
    return "entry.return"
  end
  return "grid"
end

---@param view table<string, unknown> detached browser projection
---@return table<string, unknown> immutable semantic demand for the lease
local function buildDemand(view)
  local grid = view.grid
  local iconKeys, seenIcons = {}, {}
  if type(grid) == "table" and type(grid.buffers) == "table" then
    for _, buffer in ipairs(grid.buffers) do
      if type(buffer) == "table" and type(buffer.entries) == "table" then
        for _, entry in ipairs(buffer.entries) do
          if type(entry) == "table" and entry.seen == true and type(entry.species) == "string" then
            local key = entry.species .. "/f0"
            if not seenIcons[key] and #iconKeys < 30 then
              seenIcons[key] = true
              iconKeys[#iconKeys + 1] = key
            end
          end
        end
      end
      if #iconKeys >= 30 then
        break
      end
    end
  end
  -- The compact portrait falls back to the selected species icon when the
  -- bundle carries no entry picture, so the selection icon stays wanted
  -- even when the selection stages off the visible buffer or the page
  -- stages no grid at all.
  if type(view.selection) == "table" and type(view.selection.species) == "string" then
    local key = view.selection.species .. "/f0"
    if not seenIcons[key] and #iconKeys < 30 then
      seenIcons[key] = true
      iconKeys[#iconKeys + 1] = key
    end
  end
  -- Forms and compare pages stage their per-variant mon icons beside
  -- the rows: the six list rows around the cursor (the same
  -- cursor - 1 .. cursor + 4 window the plan lists) and the compared
  -- pair on the compare page. Icon art resolves outside the native
  -- sprite archive, so the variant keys ride the icon demand directly
  -- instead of a native subject binding. The grid keeps its own
  -- thirty-key scroll closure above; variants stage on top up to eight
  -- further keys (six rows plus the compared pair) so a full grid
  -- never crowds them out, matching the source staging list icons and
  -- form icons through separate sprite sets.
  if view.page == "forms" and type(view.forms) == "table" then
    local forms = view.forms
    local variants = forms.variants
    if type(variants) == "table" and type(view.selection) == "table" and type(view.selection.species) == "string" then
      local species = view.selection.species
      local row = forms.row
      if type(row) ~= "number" then
        row = 0
      end
      row = math.floor(row)
      local function wantVariantIcon(form)
        if type(form) ~= "number" then
          return
        end
        local key = species .. "/f" .. math.floor(form)
        if not seenIcons[key] and #iconKeys < 38 then
          seenIcons[key] = true
          iconKeys[#iconKeys + 1] = key
        end
      end
      for position = 1, 6 do
        local variant = variants[row + position - 1]
        if type(variant) == "table" then
          wantVariantIcon(variant.form)
        end
      end
      local comparison = forms.comparison
      if type(comparison) == "table" and type(comparison.indices) == "table" then
        local indices = comparison.indices
        for _, side in ipairs({ 1, 2 }) do
          local compared = indices[side]
          if type(compared) == "number" then
            local variant = variants[math.floor(compared) + 1]
            if type(variant) == "table" then
              wantVariantIcon(variant.form)
            end
          end
        end
      end
    end
  end
  local pictures = {}
  if type(view.pictures) == "table" then
    for _, picture in ipairs(view.pictures) do
      if #pictures < 4 and type(picture) == "table" then
        pictures[#pictures + 1] = {
          slot = picture.slot,
          specimen = picture.specimen,
          facing = picture.facing,
          mode = picture.mode,
        }
      end
    end
  end
  local objects = {}
  if type(view.objects) == "table" then
    for _, intent in ipairs(view.objects) do
      if type(intent) == "table" then
        objects[#objects + 1] = intent
      end
    end
  end
  local text = {}
  if type(view.text) == "table" then
    text = view.text
  end
  local dexMode = view.mode
  if dexMode ~= "national" then
    dexMode = "johto"
  end
  local language = "native"
  if
    type(view.selection) == "table"
    and type(view.selection.language) == "string"
    and view.selection.language ~= ""
  then
    language = view.selection.language
  end
  return {
    key = "pokedex-" .. tostring(view.key),
    purpose = "browser",
    pageRole = pageRoleFor(view),
    dexMode = dexMode,
    language = language,
    profile = "base",
    iconKeys = iconKeys,
    pictures = pictures,
    text = text,
    objects = objects,
  }
end

---@param self PokedexScreenState
---@return table<string, unknown> presented projection paired with the committed bundle
local function presentedView(self)
  return self._presentedView or self._view
end

---@param view table<string, unknown> detached browser projection
---@param compact table<string, unknown> private compact presentation record
---@param capturedTarget string? in-flight captured slider target
---@return table<string, unknown> merged plan view with the private compact record
local function planViewFor(view, compact, capturedTarget)
  local merged = {}
  for key, value in pairs(view) do
    merged[key] = value
  end
  merged.compact = compact
  merged.capturedSliderTarget = capturedTarget
  return merged
end

---@param self PokedexScreenState
---@param specificView table<string, unknown>? explicit projection, defaulting to the published one
---@return table<string, unknown> merged plan view with the private compact record
local function planView(self, specificView)
  return planViewFor(specificView or presentedView(self), self._compact, self._activeDragTarget)
end

---@param self PokedexScreenState
---@param specificView table<string, unknown>? projection to resolve, defaulting to the published one
---@param measurement table<string, unknown>? fresh host display facts; without them the plan is retained
---@return boolean ok true when the session plan matches the projection
---@return string? cause resolution failure attribution when ok is false
local function resolvePlan(self, specificView, measurement)
  if measurement == nil then
    return true
  end
  self._compactMode = measurement.layout == "compact"
  if self._compactMode ~= true and type(measurement.width) == "number" then
    local classify = require("libs.ui.src.ApplicationLayout").classify
    local okClassify, configuration = pcall(classify, measurement)
    if okClassify and configuration == "nativeLike" then
      self._compactMode = true
    end
  end
  -- The session validates its candidate before publishing, so a failed
  -- resolve keeps the previous plan: the caller decides whether the
  -- retained plan stays coherent (published reflow) or the failed
  -- candidate must surface (pending replacement).
  local ok, cause = pcall(self._session.resolve, self._session, measurement, planView(self, specificView))
  if not ok then
    return false, tostring(cause)
  end
  local planOk, currentPlan = pcall(self._session.plan, self._session)
  if planOk and type(currentPlan) == "table" and type(currentPlan.inputKey) == "string" then
    -- A geometry change drops the held host capture, and the session
    -- already queued its pointer_cancel: the queued event carries the
    -- exactly-once transactional drag cancellation through consumeBatch,
    -- so the in-flight target is retained here until that event clears
    -- it. Eagerly clearing it would swallow the rollback.
    self._lastInputKey = currentPlan.inputKey
  end
  return true
end

---@param self PokedexScreenState
---@param events table<integer, table<string, unknown>> raw fixed-tick batch
---@return table<integer, table<string, unknown>> mapped batch with host actions consumed
local function mapBatch(self, events)
  local planOk, hasPlan = pcall(self._session.plan, self._session)
  if not planOk or hasPlan == nil then
    return events
  end
  local ok, mapped = pcall(self._session.mapInput, self._session, events, planView(self))
  if not ok or type(mapped) ~= "table" then
    return events
  end
  return mapped
end

---@param self PokedexScreenState
---@param mapped table<integer, table<string, unknown>> session-mapped batch
---@return table<integer, table<string, unknown>> model batch with exactly one held record
local function consumeBatch(self, mapped)
  local model = {}
  local held = { left = false, right = false, touch = false }
  local touchNow = false
  for _, event in ipairs(mapped) do
    if type(event) == "table" and event.type == "held" and type(event.directions) == "table" then
      local directions = event.directions
      if directions.left == true then
        held.left = true
      end
      if directions.right == true then
        held.right = true
      end
    elseif type(event) == "table" and event.type == "inspect" then
      if self._compactMode then
        self._compact.inspect = not self._compact.inspect
      end
    elseif type(event) == "table" and event.type == "toggleSize" then
      if self._compact.size == "weight" then
        self._compact.size = "height"
      else
        self._compact.size = "weight"
      end
    elseif type(event) == "table" and event.type == "cancel" and self._compact.inspect then
      self._compact.inspect = false
    elseif type(event) == "table" and event.type == "pointer_cancel" then
      -- A lost capture ends the in-flight gesture transactionally: the
      -- controller restores the pre-drag bound instead of keeping a
      -- stale drag, then observes the cancellation itself.
      if self._activeDragTarget ~= nil then
        model[#model + 1] = { type = "drag", target = self._activeDragTarget, phase = "cancel" }
        self._activeDragTarget = nil
      end
      self._pointerHeld = false
      model[#model + 1] = event
    elseif type(event) == "table" and event.type == "drag" then
      if event.phase == "begin" or event.phase == "move" then
        self._pointerHeld = true
        if type(event.target) == "string" then
          self._activeDragTarget = event.target
        end
        touchNow = true
      else
        if self._activeDragTarget == nil or self._activeDragTarget == event.target then
          self._activeDragTarget = nil
        end
        self._pointerHeld = false
      end
      model[#model + 1] = event
    elseif type(event) == "table" and event.type == "activate" then
      -- A tap reports its momentary touch for this tick only: only an
      -- in-flight drag latches the held press across frame boundaries.
      touchNow = true
      model[#model + 1] = event
    else
      model[#model + 1] = event
    end
  end
  if self._compact.inspect then
    -- The expanded information panel owns all input while open: every
    -- background command stays inert and only the toggle, the close,
    -- the capture lifecycle, and the held record flow through.
    local shielded = {}
    for _, event in ipairs(model) do
      if type(event) ~= "table" then
        shielded[#shielded + 1] = event
      elseif
        event.type == "inspect"
        or event.type == "cancel"
        or event.type == "pointer_cancel"
        or event.type == "held"
      then
        shielded[#shielded + 1] = event
      end
    end
    model = shielded
  end
  held.touch = touchNow or self._pointerHeld
  model[#model + 1] = { type = "held", left = held.left, right = held.right, touch = held.touch }
  return model
end

---@param self PokedexScreenState
---@param demand table<string, unknown> finite demand for the current projection
---@param measurement table<string, unknown>? fresh host display facts; without them the plan is retained
local function advanceLease(self, demand, measurement)
  local outcome = self._lease:prepare(demand)
  assert(type(outcome) == "table" and type(outcome.kind) == "string", "leases answer pending, ready, or failed")
  if outcome.kind == "ready" then
    if outcome.key == demand.key then
      -- A matching generation commits view, key, and bundle together
      -- only after its own plan validates against the same display
      -- facts: the commit and the plan swap share one synchronous
      -- update, so no reader observes a mixed triplet. The same key
      -- with refreshed presentation values simply refreshes the
      -- presented projection without new acquisitions.
      if measurement == nil then
        return
      end
      local planOk, cause = resolvePlan(self, self._view, measurement)
      if not planOk then
        if self._phase ~= "failed" then
          self._phase = "failed"
          self._preparationError = tostring(cause)
        end
        return
      end
      self._assets = assert(outcome.assets, "ready outcomes carry their whole bundle")
      self._readyKey = self._view.key
      self._presentedView = self._view
    end
  elseif outcome.kind == "failed" then
    if self._phase ~= "failed" then
      self._phase = "failed"
      self._preparationError = tostring(outcome.error)
    end
  else
    assert(outcome.kind == "pending", "leases answer pending, ready, or failed")
  end
end

---@param self PokedexScreenState
---@param action string dispatched music request behind the controller effect
local function applyMusic(self, action)
  if action == "duck" then
    if self._music == nil then
      return
    end
    local applied = self._music("duck")
    if applied == true then
      self._musicDucked = true
    end
  elseif action == "restore" then
    if not self._musicDucked then
      return
    end
    if self._music == nil then
      self._musicDucked = false
      return
    end
    self._music("restore")
    self._musicDucked = false
  end
end

-- Balances one acknowledged duck outside the effect stream: clears the
-- claim before the sink runs so a throwing restore still releases
-- exactly once.
---@param self PokedexScreenState
local function restoreIfDucked(self)
  if not self._musicDucked then
    return
  end
  self._musicDucked = false
  if self._music == nil then
    return
  end
  self._music("restore")
end

---@param self PokedexScreenState
local function dispatchEffects(self)
  local drain = self._controller.drainEffects
  if type(drain) ~= "function" then
    return
  end
  local effects = drain(self._controller)
  if type(effects) ~= "table" then
    return
  end
  for _, effect in ipairs(effects) do
    if type(effect) == "table" and effect.kind == "sound" then
      self._effect(effect.role)
    elseif type(effect) == "table" and effect.kind == "music" then
      applyMusic(self, effect.action)
    elseif type(effect) == "table" and effect.kind == "cry" then
      self._playCry(effect.species, effect.mode or 0, effect.form or 0)
    elseif type(effect) == "table" and effect.kind == "resume" then
      self._commitResume({ mode = effect.mode, species = effect.species })
    end
  end
end

---@class PokedexScreenStateOptions
---@field controller table<string, unknown> borrowed browser policy owner
---@field lease table<string, unknown> acquired per-open preparation lease
---@field measureDisplay fun(): table<string, unknown> fresh host display facts
---@field effect fun(sequence: unknown) borrowed audio effect sink
---@field playCry fun(species: string, pattern: integer, form: integer) borrowed cry sink
---@field commitResume fun(resume: table<string, unknown>): boolean composed one-use resume publication
---@field music fun(action: string)? optional field-music duck/restore sink
---@field overrides table<string, unknown>? product per-case interface replacements

---@param args PokedexScreenStateOptions the per-open construction record
---@return PokedexScreenState
function PokedexScreenState.new(args)
  assert(type(args) == "table", "the presented screen needs its construction record")
  local controller = assert(args.controller, "the presented screen borrows its browser controller")
  assert(type(controller.updateFixed) == "function", "the browser controller advances per fixed tick")
  assert(type(controller.view) == "function", "the browser controller projects its detached view")
  local lease = assert(args.lease, "the presented screen acquires its resource lease")
  assert(type(lease.prepare) == "function" and type(lease.release) == "function", "leases prepare and release")
  assert(type(args.measureDisplay) == "function", "the presented screen measures its display")
  assert(type(args.effect) == "function", "the presented screen sinks its sound effects")
  assert(type(args.playCry) == "function", "the presented screen sinks its cry effects")
  assert(type(args.commitResume) == "function", "the presented screen publishes its resume through the owner")
  local music = args.music
  if music ~= nil then
    assert(type(music) == "function", "the presented screen sinks its music requests")
  end
  -- A fresh screen holds no matching readiness: the first whole bundle
  -- commits view, key, and assets together before any motion is
  -- admitted.
  local self = setmetatable({
    _controller = controller,
    _lease = lease,
    _measureDisplay = args.measureDisplay,
    _effect = args.effect,
    _playCry = args.playCry,
    _commitResume = args.commitResume,
    _music = music,
    _session = ApplicationPresentation.new(PokedexInterface.browser(args.overrides)),
    _readyKey = nil,
    _view = controller:view(),
    _presentedView = nil,
    _assets = nil,
    _phase = "active",
    _preparationError = nil,
    _compact = { inspect = false, size = "weight" },
    _compactMode = false,
    _pointerHeld = false,
    _activeDragTarget = nil,
    _lastInputKey = nil,
    _terminal = nil,
    _disposed = false,
    _musicDucked = false,
  }, PokedexScreenState)
  self.page = self._view.page
  self.view = self._view
  self.uiInput = UI_INPUT_PROFILE
  local demand = buildDemand(self._view)
  local okDisplay, measured = pcall(self._measureDisplay)
  ---@type table<string, unknown>?
  local displayFacts
  if okDisplay and type(measured) == "table" then
    displayFacts = measured
  end
  advanceLease(self, demand, displayFacts)
  resolvePlan(self, presentedView(self), displayFacts)
  return self
end

-- Advances the per-open screen once per host fixed tick: resolve the
-- published plan against fresh display facts, map events through that
-- published plan, consume private compact actions, advance the model
-- once with matching readiness, and prepare at most one finite demand
-- for the new projection. A pending candidate never feeds the session:
-- only a ready candidate whose own plan validates replaces the
-- published view, bundle, and plan in the same update. Effects drain
-- exactly once; sound and cry use the borrowed audio while normal-close
-- resume publishes once through the composed owner.
---@param events table<integer, table<string, unknown>> fixed-tick batch for the screen
function PokedexScreenState:updateFixed(events)
  assert(not self._disposed, "a disposed presented screen steps nothing")
  assert(type(events) == "table", "screen updates consume an event batch")
  if self._terminal ~= nil then
    return
  end
  -- A failed preparation never returns to successful browsing: the
  -- retained cause raises through the existing host error ownership.
  if self._phase == "failed" then
    error(self._preparationError, 0)
  end
  local okDisplay, measured = pcall(self._measureDisplay)
  ---@type table<string, unknown>?
  local displayFacts
  if okDisplay and type(measured) == "table" then
    displayFacts = measured
  end
  -- The published projection owns the plan and the input map for the
  -- whole tick; the live candidate staged below cannot move them.
  resolvePlan(self, presentedView(self), displayFacts)
  local mapped = mapBatch(self, events)
  local model = consumeBatch(self, mapped)
  -- Before the first whole bundle commits the ready key stays nil, so
  -- the model withholds every non-cancel transition; afterwards the
  -- committed key admits motion while a newer pending generation holds
  -- the last presented pair.
  local preparation
  if self._assets ~= nil then
    preparation = { readyKey = self._readyKey, animations = self._assets.animations }
  else
    preparation = { readyKey = self._readyKey }
  end
  self._controller:updateFixed(model, preparation)
  self._view = self._controller:view()
  if self._phase ~= "failed" then
    advanceLease(self, buildDemand(self._view), displayFacts)
  end
  local presented = presentedView(self)
  self.page = presented.page
  self.view = presented
  dispatchEffects(self)
  local terminal = self._controller:takeResult()
  if terminal ~= nil then
    self._terminal = terminal
  end
end

-- The host-facing presentation snapshot: open lifetime, the detached
-- browser projection paired with the committed bundle, the private
-- compact record, the resolved plan, the terminal failure cause, and
-- the finite modal input profile. The exposed view and assets always
-- belong to one matching generation; while the first bundle is pending
-- the view stays live with no assets attached. Fresh tables per call.
---@return table<string, unknown>
function PokedexScreenState:status()
  local status = {
    open = self._terminal == nil,
    view = presentedView(self),
    phase = self._phase,
    compact = self._compact,
    uiInput = UI_INPUT_PROFILE,
  }
  if self._assets ~= nil then
    status.assets = self._assets
  end
  if self._preparationError ~= nil then
    status.preparationError = self._preparationError
  end
  local ok, plan = pcall(self._session.plan, self._session)
  if ok and plan ~= nil then
    status.presentation = plan
  end
  return status
end

-- The host result contract: the controller's one-use close result,
-- observed once during the update that produced it.
---@return table<string, unknown>?
function PokedexScreenState:takeResult()
  local terminal = self._terminal
  self._terminal = nil
  return terminal
end

-- Cancels a held press through both owners: the session drops its capture
-- and the controller releases its own, so a stale release never
-- activates.
function PokedexScreenState:cancelPointerCapture()
  local ok, _ = pcall(self._session.cancelPointers, self._session)
  self._pointerHeld = false
  self._activeDragTarget = nil
  if not ok then
    return
  end
  self._controller:cancelPointerCapture()
end

-- Idempotent release of the per-open lifetime: balances one actually
-- applied duck, then the session, the controller, and the acquired
-- lease release exactly once. A throwing restore still releases every
-- owned resource; the first observed failure propagates.
function PokedexScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._terminal = nil
  self._pointerHeld = false
  self._activeDragTarget = nil
  local firstFailure = nil
  if self._musicDucked then
    local okRestore, restoreFailure = pcall(restoreIfDucked, self)
    if not okRestore and firstFailure == nil then
      firstFailure = restoreFailure
    end
  end
  local okSession, sessionFailure = pcall(self._session.dispose, self._session)
  if not okSession and firstFailure == nil then
    firstFailure = sessionFailure
  end
  local okController, controllerFailure = pcall(self._controller.dispose, self._controller)
  if not okController and firstFailure == nil then
    firstFailure = controllerFailure
  end
  local okLease, leaseFailure = pcall(self._lease.release, self._lease)
  if not okLease and firstFailure == nil then
    firstFailure = leaseFailure
  end
  if firstFailure ~= nil then
    error(firstFailure, 0)
  end
end

return PokedexScreenState
