-- The concrete summary application: the per-open wrapper binding the
-- native controller to one presentation session with bounded preparation
-- and single-owner entry. Each wrapper acquires one opaque preparation
-- lease, reconciles roster and context into bounded demand, gates
-- interaction and picture playback behind readiness and the entry fade,
-- maps one ordered batch per tick, drains one-shot effects once, then
-- publishes a stable native plan. The wrapper owns preparation, the
-- controller, the session, and entry; the parent flow owns exit,
-- replacement, and item transactions. The child never consumes an item
-- or teaches a move: normal reorders publish one complete mon update
-- through the owned preparation path, and move_pick mode is strictly
-- read-only. Construction is failure-safe: a failed session, controller,
-- or resolve releases the lease and whatever the open acquired.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local StandardFade = require("libs.hgss.src.presentation.StandardFade")
local SummaryController = require("libs.hgss.src.ui.SummaryController")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryScreenInterface = require("game.hgss.src.field.SummaryScreenInterface")

---@class SummaryScreenState
---@field _service HgssMonService the live mon service
---@field _subjectPort SummarySubjectPort?
---@field _manifest table<string, unknown> the validated summary family
---@field _contextSource fun(): table<string, unknown> explicit read-only display context per refresh
---@field _readNavigation fun(): table<string, unknown>? read-only navigation sample
---@field _acquirePreparation fun(): table<string, unknown> per-open lease factory
---@field _effect (fun(sequence: string))? the production semantic sound boundary
---@field _playCry (fun(species: integer, pattern: integer))? the production cry boundary
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _lease table<string, unknown>? the per-open preparation lease
---@field _demandKey string? the qualified demand behind the ready bundle
---@field _bundle table<string, unknown>? the ready resource bundle
---@field _preparationError string?
---@field _phase "preparing"|"entering"|"active"|"failed" the wrapper-owned lifetime
---@field _entryFade StandardFade? the single-owner entry fade
---@field _entryCoefficient integer? the published entry coefficient while entering
---@field _entryHeld boolean? whether the full-black entry frame published
---@field _mainInspection boolean the host-only main inspection overlay
---@field _signature string? the last measured display signature
---@field _result table<string, unknown>? terminal wrapper result before controller delivery
---@field _controller SummaryController
---@field _session ApplicationPresentation the per-open presentation session
---@field _disposed boolean
local SummaryScreenState = {}
SummaryScreenState.__index = SummaryScreenState

---@class SummarySubjectPort
---@field count fun(): integer
---@field revision fun(): integer
---@field read fun(index: integer): table<string, unknown>
---@field publish fun(index: integer, mon: table<string, unknown>, expectedRevision: integer): { kind: "changed"|"stale" }

---@class SummaryScreenState.Options
---@field mons HgssMonService the live mon service
---@field manifest table<string, unknown> the validated summary family (not the party manifest)
---@field initialSlot integer? the zero-based opening member
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field mode "summary"|"move_pick"
---@field request table<string, unknown>? the picker request for move_pick mode
---@field subjectPort SummarySubjectPort? optional concrete ordered subject adapter
---@field context fun(): table<string, unknown> the explicit display context per refresh
---@field readNavigation fun(): table<string, unknown>? the read-only navigation sample
---@field acquirePreparation fun(): table<string, unknown> the per-open lease factory
---@field effect (fun(sequence: string))? the production semantic sound boundary
---@field playCry (fun(species: integer, pattern: integer))? the production cry boundary
---@field textPolicy table<string, unknown>? the copied player text-speed cadence
---@field overrides table<string, unknown>? per-case layout overrides
---@field allowCancel boolean? cancel permission, default true

-- Validates request shapes per mode: summary carries no request and
-- reorders through the owned command; move_pick carries an explicit
-- picker request and stays read-only. Machine replacement may preview
-- one parent-supplied prospective move without owning it.
---@param mode string
---@param request table<string, unknown>?
local function checkRequest(mode, request)
  if mode == "summary" then
    assert(request == nil, "summary mode carries no picker request")
    return
  end
  assert(type(request) == "table", "move_pick mode carries its picker request")
  local context = assert(request.context, "picker requests carry their context")
  assert(
    context == "pp_restore" or context == "pp_up" or context == "replace_machine" or context == "inspect_reorder",
    "picker contexts stay in the closed set"
  )
  if request.protected ~= nil then
    assert(type(request.protected) == "table", "picker protection arrives as a record")
    for slot, reason in pairs(request.protected) do
      assert(type(slot) == "number" and slot % 1 == 0 and slot >= 1, "protected move rows use one-based slots")
      assert(type(reason) == "string" and reason ~= "", "protected rows name their reason")
    end
  end
  if request.prospectiveMove ~= nil then
    assert(
      type(request.prospectiveMove) == "string" and request.prospectiveMove ~= "",
      "preview moves arrive as named moves"
    )
    assert(context == "replace_machine", "preview rows belong to machine replacement")
  end
end

-- The read source behind one open: the live party service, or a
-- party-shaped adapter over a detached subject port. Boxed subjects
-- read through the port while catalog text and stat derivation stay on
-- the service, so both shapes build identical native snapshots.
---@param self SummaryScreenState
---@return HgssMonService party-shaped read source for the summary projection
local function modelService(self)
  local port = self._subjectPort
  if port == nil then
    return self._service
  end
  local service = self._service
  return {
    partyCount = function()
      return port.count()
    end,
    partyRevision = function()
      return port.revision()
    end,
    partyMon = function(_, index)
      return assert(port.read(index), "summary subject indexes stay occupied")
    end,
    catalog = function()
      return service:catalog()
    end,
    derive = function(_, mon)
      return service:derive(mon)
    end,
  }
end

---@param opts SummaryScreenState.Options
---@return SummaryScreenState
function SummaryScreenState.new(opts)
  assert(type(opts) == "table", "the summary requires options")
  local service = assert(opts.mons, "the summary requires the live mon service")
  local subjectPort = opts.subjectPort
  if subjectPort ~= nil then
    assert(type(subjectPort.count) == "function", "summary subjects expose a count")
    assert(type(subjectPort.revision) == "function", "summary subjects expose a revision")
    assert(type(subjectPort.read) == "function", "summary subjects expose copied reads")
    assert(type(subjectPort.publish) == "function", "summary subjects expose guarded publication")
    assert(subjectPort.count() > 0, "the summary requires a non-empty subject list")
  else
    assert(
      type(service.partyCount) == "function" and service:partyCount() > 0,
      "the summary requires a non-empty party"
    )
  end
  local manifest = assert(opts.manifest, "the summary requires the summary family")
  assert(type(manifest) == "table", "the summary family arrives as a record")
  assert(type(opts.measureDisplay) == "function", "the summary requires the display facts")
  assert(opts.mode == "summary" or opts.mode == "move_pick", "the summary requires its mode")
  checkRequest(opts.mode, opts.request)
  local initialSlot = opts.initialSlot or 0
  local subjectCount = service:partyCount()
  if subjectPort ~= nil then
    subjectCount = subjectPort.count()
  end
  assert(
    type(initialSlot) == "number" and initialSlot % 1 == 0 and initialSlot >= 0 and initialSlot < subjectCount,
    "the initial slot must be an occupied subject position"
  )
  local contextSource = assert(opts.context, "presented summaries require their display context")
  assert(type(contextSource) == "function", "the display context arrives as a callback")
  local readNavigation = assert(opts.readNavigation, "presented summaries require their navigation sample")
  assert(type(readNavigation) == "function", "the navigation sample arrives as a callback")
  local acquirePreparation = assert(opts.acquirePreparation, "presented summaries require preparation")
  assert(type(acquirePreparation) == "function", "preparation arrives as a lease factory")
  assert(opts.effect == nil or type(opts.effect) == "function", "the summary sound boundary is a function")
  assert(opts.playCry == nil or type(opts.playCry) == "function", "the summary cry boundary is a function")
  assert(opts.textPolicy == nil or type(opts.textPolicy) == "table", "the summary text policy is a record")
  local self = setmetatable({
    _service = service,
    _subjectPort = subjectPort,
    _manifest = manifest,
    _contextSource = contextSource,
    _readNavigation = readNavigation,
    _acquirePreparation = acquirePreparation,
    _effect = opts.effect,
    _playCry = opts.playCry,
    _textPolicy = opts.textPolicy,
    _measureDisplay = opts.measureDisplay,
    _lease = nil,
    _demandKey = nil,
    _bundle = nil,
    _preparationError = nil,
    _phase = "preparing",
    _entryFade = nil,
    _entryCoefficient = nil,
    _mainInspection = false,
    _signature = nil,
    _result = nil,
    _disposed = false,
  }, SummaryScreenState)
  local lease = acquirePreparation()
  assert(
    type(lease) == "table" and type(lease.prepare) == "function" and type(lease.release) == "function",
    "preparation leases prepare bounded demand and release idempotently"
  )
  self._lease = lease
  local wrapper = self
  local function refreshModel(slot)
    return SummaryModel.build(modelService(wrapper), slot, wrapper._contextSource(), manifest)
  end
  local function resolveLayout()
    return wrapper:resolveLayout()
  end
  local controllerOpts = {
    mode = opts.mode,
    model = { refresh = refreshModel },
    request = opts.request,
    resolveLayout = resolveLayout,
    manifest = manifest,
    readNavigation = readNavigation,
    initialSlot = initialSlot,
  }
  if opts.mode == "summary" then
    local function reorderThroughCommand(slot, a, b, revision)
      return wrapper:reorderMoves(slot, a, b, revision)
    end
    controllerOpts.reorderMoves = reorderThroughCommand
  end
  local controller
  local session
  local built, buildErr = pcall(function()
    session = ApplicationPresentation.new(SummaryScreenInterface.defaults(manifest), opts.overrides)
    controller = SummaryController.new(controllerOpts)
  end)
  if not built then
    if controller ~= nil then
      controller:dispose()
    end
    if session ~= nil then
      session:dispose()
    end
    lease:release()
    self._lease = nil
    error(buildErr, 0)
  end
  self._controller = assert(controller, "the summary requires its controller")
  self._session = assert(session, "the summary requires its presentation session")
  local resolveOk, resolveErr = pcall(function()
    self._session:resolve(self:_measured(), self:_view())
  end)
  if not resolveOk then
    self._controller:dispose()
    self._session:dispose()
    lease:release()
    self._lease = nil
    error(resolveErr, 0)
  end
  return self
end

-- Swaps two whole move entries through one owned preparation: the
-- complete replacement records (move, PP, PP ups) exchange once after
-- revision validation, and every non-move field travels untouched.
-- Same-slot gestures never reach this command.
---@param slot integer zero-based subject slot
---@param a integer zero-based source move row
---@param b integer zero-based target move row
---@param revision integer the controller-observed party revision
---@return { kind: "changed"|"stale" }
function SummaryScreenState:reorderMoves(slot, a, b, revision)
  assert(not self._disposed, "a disposed summary reorders nothing")
  assert(type(slot) == "number" and slot % 1 == 0, "reorder needs its party slot")
  assert(type(a) == "number" and a % 1 == 0, "reorder needs its source row")
  assert(type(b) == "number" and b % 1 == 0, "reorder needs its target row")
  assert(a ~= b, "same-slot gestures never reach publication")
  local port = self._subjectPort
  local currentRevision = self._service:partyRevision()
  if port ~= nil then
    currentRevision = port.revision()
  end
  if revision ~= currentRevision then
    return { kind = "stale" }
  end
  local mon = self._service:partyMon(slot)
  if port ~= nil then
    mon = assert(port.read(slot), "summary subject indexes stay occupied")
  end
  local moves = assert(mon.moves, "stored mons carry their moves")
  assert(a >= 0 and a < #moves and b >= 0 and b < #moves, "reorder rows stay inside the learned set")
  local swapped = {}
  for index, entry in ipairs(moves) do
    swapped[index] = { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
  end
  swapped[a + 1], swapped[b + 1] = swapped[b + 1], swapped[a + 1]
  mon.moves = swapped
  if port ~= nil then
    return port.publish(slot, mon, revision)
  end
  local preparation, reason = self._service:preparePartyChanges(revision, { { slot = slot, mon = mon } })
  if preparation == nil then
    assert(reason == "stale", "preparation refuses stale revisions loudly")
    return { kind = "stale" }
  end
  preparation.publish()
  return { kind = "changed" }
end

---@return DisplayMeasurement
function SummaryScreenState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the summary requires current display facts")
end

-- The production hit test over sub-pane coordinates: the compiled
-- touch inventory maps to controller targets. Host affordance and
-- inspection handling live
-- one layer up in the interface mapper; keyboard and menu edges drive
-- native state.

-- Classifies one compiled touch box into the controller target the box
-- drives plus the native group the box belongs to: move rows answer on
-- the skills group and ribbon cells on the performance group because both
-- states share the same pane region, while tabs, members, and exits stay
-- live everywhere. Boxes without a native target kind (page arrows,
-- panel rows, restricted selector pairs) stay inert: those gestures
-- travel through directional input instead. Blank rows and cells stay
-- separate boxes so the controller qualifies them against its facts;
-- edges are half-open with a zero right edge reading 256.
---@param key string compiled hitbox name
---@return table<string, unknown>? the controller target, or nil when the box drives no native target
---@return string? the owning native group, or nil when the box answers everywhere
local function classifyTouchBox(key)
  assert(type(key) == "string" and key ~= "", "touch boxes carry names")
  local lower = key:lower()
  local group = lower:match("tab([a-z]+)$")
  if group == "info" or group == "skills" or group == "performance" then
    return { kind = "group", group = group }
  end
  if lower:find("exit", 1, true) ~= nil then
    return { kind = "return" }
  end
  local member = lower:match("member(%d+)$")
  if member ~= nil then
    return { kind = "member", slot = tonumber(member) }
  end
  local move = lower:match("moverow(%d+)$")
  if move ~= nil then
    return { kind = "move", index = tonumber(move) }, "skills"
  end
  local cell = lower:match("ribboncell(%d+)$")
  if cell ~= nil then
    return { kind = "ribbon", index = tonumber(cell) }, "performance"
  end
  return nil
end

---@return table<string, unknown>
function SummaryScreenState:resolveLayout()
  local hitboxes = assert(self._manifest.hitboxes, "the summary family carries its hitboxes")
  assert(type(hitboxes) == "table", "summary hitboxes arrive as a record")
  local touch = assert(hitboxes.touch, "the summary family carries its touch targets")
  assert(type(touch) == "table", "summary touch targets arrive as a record")
  local names = {}
  for key, _ in pairs(touch) do
    assert(type(key) == "string", "touch targets carry names")
    names[#names + 1] = key
  end
  table.sort(names)
  local boxes = {}
  for _, key in ipairs(names) do
    local box = assert(touch[key], "touch targets carry rects")
    assert(type(box) == "table", "touch target rects arrive as records")
    local top = assert(box.top, "touch targets carry their top edge")
    local bottom = assert(box.bottom, "touch targets carry their bottom edge")
    local left = assert(box.left, "touch targets carry their left edge")
    local right = assert(box.right, "touch targets carry their right edge")
    assert(
      type(top) == "number" and type(bottom) == "number" and type(left) == "number" and type(right) == "number",
      "touch target edges stay numeric"
    )
    if right == 0 then
      right = 256
    end
    local target, affinity = classifyTouchBox(key)
    if target ~= nil then
      boxes[#boxes + 1] =
        { top = top, bottom = bottom, left = left, right = right, target = target, affinity = affinity }
    end
  end
  local function hitTest(x, y)
    local group = nil
    local controller = self._controller
    if controller ~= nil then
      local status = controller:status()
      if type(status) == "table" and type(status.group) == "string" then
        group = status.group
      end
    end
    for _, entry in ipairs(boxes) do
      if entry.affinity ~= nil and entry.affinity ~= group then
        -- A state-bound box stays inert outside its native group so the
        -- overlapping skills and performance regions resolve to the live
        -- state instead of the first compiled box.
      elseif x >= entry.left and x < entry.right and y >= entry.top and y < entry.bottom then
        return entry.target
      end
    end
    return nil
  end
  return {
    hitTest = hitTest,
  }
end

---@return table<string, unknown> the controller snapshot plus wrapper-owned phase, fade, and inspection state
function SummaryScreenState:_view()
  local view = {}
  for key, value in pairs(self._controller:status()) do
    view[key] = value
  end
  view.wrapperPhase = self._phase
  view.entryFade = self._entryCoefficient
  view.mainInspection = self._mainInspection
  view.resources = self._bundle
  if self._phase == "failed" then
    view.preparationState = "failed"
    view.preparationError = self._preparationError
  elseif self._phase == "active" then
    view.preparationState = "ready"
  else
    view.preparationState = "pending"
  end
  return view
end

-- Re-resolves host placement without advancing preparation or the native
-- clock. A pending/failed wait record is not a semantic view: re-resolve
-- from the canonical snapshot so placement never inherits wait metadata.
---@param view table<string, unknown>?
---@return table<string, unknown> current presentation plan
function SummaryScreenState:refreshPresentation(view)
  assert(not self._disposed, "a disposed summary wrapper refreshes nothing")
  if type(view) == "table" and view.preparationState ~= nil and view.preparationState ~= "ready" then
    return self._session:resolve(self:_measured(), self:_view())
  end
  return self._session:resolve(self:_measured(), view or self:_view())
end

-- Builds the bounded demand behind the current roster: one full portrait
-- identity per non-egg member in slot order with the roster icon keys,
-- qualified by revision and picture epoch so a stale worker result can
-- never satisfy a newer selection.
---@return table<string, unknown>? demand when facts build
---@return string? build failure when facts do not build
local function currentDemand(self)
  local ok, context = pcall(self._contextSource)
  if not ok then
    return nil, tostring(context)
  end
  local source = modelService(self)
  local manifest = self._manifest
  local buildOk, facts = pcall(SummaryModel.build, source, 0, context, manifest)
  if not buildOk then
    return nil, tostring(facts)
  end
  local selectors = {}
  local iconKeys = {}
  for _, row in ipairs(assert(facts.roster, "facts carry the party roster")) do
    iconKeys[#iconKeys + 1] = assert(row.iconKey, "roster rows carry their icon key")
    if row.isEgg ~= true then
      selectors[#selectors + 1] = assert(row.portraitSelector, "non-egg roster rows carry their portrait identity")
    end
  end
  local status = self._controller:status()
  local key = string.format("%d:%d", source:partyRevision(), status.pictureEpoch or 0)
  return {
    key = key,
    revision = source:partyRevision(),
    pictureEpoch = status.pictureEpoch or 0,
    portraitSelectors = selectors,
    iconKeys = iconKeys,
  }
end

-- A layout change discards the host overlay and any held press without
-- touching native group/member/picture state.
---@param measurement DisplayMeasurement
local function watchLayout(self, measurement)
  local signature = measurement.signature
  if signature == nil then
    signature = string.format("%dx%d", measurement.width or 0, measurement.height or 0)
  end
  if self._signature ~= nil and self._signature ~= signature then
    self._mainInspection = false
    self._session:cancelPointers()
    self._controller:cancelPointerCapture()
  end
  self._signature = signature
end

-- Advances preparation one step and files the outcome: pending stays
-- under the host cover, ready adopts the key-qualified bundle, failure
-- enters the visible failed state. Only a first open starts the
-- single-owner entry fade; later demand adopts instantly-ready bundles
-- without replaying entry, while genuinely new demand gates under the
-- cover until it is ready.
---@param demand table<string, unknown>
---@param fresh boolean whether this demand opens the screen
---@return "pending"|"ready"|"failed"
local function advancePreparation(self, demand, fresh)
  local lease = assert(self._lease, "preparation owns its lease")
  local outcome = lease:prepare(demand)
  assert(type(outcome) == "table" and type(outcome.kind) == "string", "prepare outcomes name their kind")
  if outcome.kind == "pending" then
    self._phase = "preparing"
    return "pending"
  end
  if outcome.kind == "failed" then
    self._phase = "failed"
    self._preparationError = tostring(assert(outcome.error, "preparation failures name their cause"))
    return "failed"
  end
  assert(outcome.kind == "ready", "prepare outcomes stay in the closed set")
  assert(outcome.key == demand.key, "readiness qualifies its demand key")
  self._bundle = assert(outcome.assets, "ready preparation carries its bundle")
  self._demandKey = demand.key
  if fresh then
    self._phase = "entering"
    self._entryFade = StandardFade.new({ direction = "in", color = 0 })
    self._entryCoefficient = self._entryFade.coefficient
  else
    self._phase = "active"
    self._preparationError = nil
  end
  return "ready"
end

---@param uiInput table[]
---@return table<string, unknown>[] validated events
local function checkInput(uiInput)
  assert(type(uiInput) == "table", "the summary input must be an event list")
  for _, event in ipairs(uiInput) do
    assert(type(event) == "table" and type(event.type) == "string", "summary events need a type")
  end
  return uiInput
end

-- Handles one mapped host event: inspection edges toggle or close the
-- host overlay and cancel any held native press; dismissal respects
-- cancel permission. Returns true when the event is consumed here.
---@param event table<string, unknown>
---@return boolean consumed
local function handleHostEvent(self, event)
  local kind = event.type
  -- Toggling never drops the session capture: the opening press stays
  -- held so a second press cannot slip through while inspecting, while
  -- the controller press (which never saw the host edge) releases.
  if kind == "inspect_open" then
    self._mainInspection = true
    self._controller:cancelPointerCapture()
    return true
  end
  if kind == "inspect_close" then
    self._mainInspection = false
    self._controller:cancelPointerCapture()
    return true
  end
  if kind == "inspect_toggle" then
    self._mainInspection = not self._mainInspection
    self._controller:cancelPointerCapture()
    return true
  end
  if kind == "dismiss" then
    if self._controller:status().allowCancel ~= false then
      return false
    end
    return true
  end
  return false
end

-- Routes one drained controller effect to its audio boundary. Cries play
-- through the cry boundary resolved to the displayed member's national
-- species with the default pattern, qualified by the effect's slot and
-- picture epoch so a stale delayed cry never sounds for a new selection;
-- semantic sound roles travel through the borrowed effect boundary.
-- Screens without a boundary stay silent and eggs never cry. Disposal
-- clears the controller queue, so pending effects never outlive the open.
---@param effect table<string, unknown> one drained one-shot effect
---@param status table<string, unknown> the current controller snapshot
local function dispatchEffect(self, effect, status)
  assert(type(effect) == "table", "controller effects arrive as records")
  if effect.kind == "cry" then
    if self._playCry == nil then
      return
    end
    if effect.slot ~= status.slot or effect.pictureEpoch ~= status.pictureEpoch then
      return
    end
    local facts = status.facts
    if type(facts) ~= "table" or facts.isEgg == true then
      return
    end
    local identity = assert(facts.identity, "facts carry their identity")
    local speciesKey = assert(identity.species, "identities carry their species")
    local dexNumbers = assert(self._manifest.dexNumbers, "the summary family carries dex numbers")
    assert(type(dexNumbers) == "table", "dex numbers arrive as a record")
    local numbers = assert(dexNumbers[speciesKey], "dex numbers cover the displayed species")
    assert(type(numbers) == "table", "dex numbers carry per-species entries")
    local national = assert(numbers.national, "dex numbers carry the national entry")
    assert(type(national) == "number" and national % 1 == 0, "cry species stay numeric")
    self._playCry(national, 0)
    return
  end
  if effect.kind == "sound" then
    if self._effect == nil then
      return
    end
    self._effect(assert(effect.role, "sound effects name their role"))
    return
  end
  error("unknown summary effect kind " .. tostring(effect.kind), 0)
end

-- One fixed tick: resolve, map once, advance the controller once while
-- interactive, then resolve again for the resulting snapshot. Preparation
-- and entry gate both controller input and picture playback: gated edges
-- are validated and discarded, never queued or replayed. While the host
-- inspection overlay is open, Confirm and navigation suspend and Cancel
-- closes the overlay first.
---@param uiInput table[]
function SummaryScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed summary wrapper steps nothing")
  checkInput(uiInput)
  local session = self._session
  local measurement = self:_measured()
  watchLayout(self, measurement)
  if self._phase ~= "active" then
    if self._phase ~= "failed" then
      local demand, failure = currentDemand(self)
      if demand == nil then
        self._phase = "failed"
        self._preparationError = tostring(failure)
      elseif self._phase == "preparing" then
        advancePreparation(self, demand, self._demandKey == nil)
      else
        local fade = assert(self._entryFade, "entry owns its fade")
        fade:updateSourceFrame()
        self._entryCoefficient = fade.coefficient
        if fade.completed then
          -- The full-black frame publishes once before handover so the
          -- source recurrence reads complete; interaction and playback
          -- still start past it.
          if self._entryHeld ~= true then
            self._entryHeld = true
          else
            self._phase = "active"
            self._entryFade = nil
            self._entryCoefficient = nil
            self._entryHeld = nil
          end
        end
      end
    end
    session:resolve(measurement, self:_view())
    -- The failed state honors the current batch's cancellation even on
    -- the tick it fails: preparation input stays discarded, but an
    -- explicit cancel still recovers instead of hanging on black.
    if self._phase == "failed" then
      for _, event in ipairs(uiInput) do
        if event.type == "cancel" and self._controller:status().allowCancel ~= false then
          self._result = { kind = "cancelled" }
        end
      end
      session:resolve(measurement, self:_view())
    end
    return
  end
  session:resolve(measurement, self:_view())
  local mapped = session:mapInput(uiInput, self:_view())
  -- The semantic menu edge bypasses leaf mappers and arrives raw: on
  -- the single-display entry it toggles the host inspection overlay,
  -- everywhere else native policy ignores it.
  local untypedPlan = session:plan() --[[@as table<string, unknown>]]
  local nativeLike = untypedPlan.nativeLike == true
  local native = {}
  for _, event in ipairs(mapped) do
    if event.type == "menu" and nativeLike then
      self._mainInspection = not self._mainInspection
      self._session:cancelPointers()
      self._controller:cancelPointerCapture()
    elseif not handleHostEvent(self, event) then
      if self._mainInspection == true then
        if event.type ~= "cancel" and event.type ~= "dismiss" then
          -- Hidden sub rows stay inert while inspecting: Confirm and
          -- navigation suspend until the overlay closes.
        else
          self._mainInspection = false
          self._controller:cancelPointerCapture()
        end
      else
        native[#native + 1] = event
      end
    end
  end
  self._controller:updateFixed(native)
  local status = self._controller:status()
  for _, effect in ipairs(self._controller:takeEffects()) do
    dispatchEffect(self, effect, status)
  end
  session:resolve(measurement, self:_view())
  local demand, failure = currentDemand(self)
  if demand == nil then
    if not self._controller:status().open then
      return
    end
    self._phase = "failed"
    self._preparationError = tostring(failure)
    session:resolve(measurement, self:_view())
    return
  end
  if demand.key ~= self._demandKey then
    self._preparationError = nil
    advancePreparation(self, demand, false)
    session:resolve(measurement, self:_view())
  end
end

-- The presentation snapshot: the controller status (semantic view state
-- plus wrapper-owned phase, fade, inspection, resources, and preparation
-- state) with presentation=plan, the single host-facing layout
-- authority. Fresh tables per call; the terminal frame stays frozen for
-- the parent exit fade.
---@return table<string, unknown>
function SummaryScreenState:status()
  local status = self:_view()
  if not status.open then
    return status
  end
  status.presentation = self._session:plan()
  return status
end

-- The host result contract: closing returns the displayed member, picks
-- return revision-qualified selections, and cancellation stays explicit.
---@return table<string, unknown>?
function SummaryScreenState:takeResult()
  if self._result ~= nil then
    local result = self._result
    self._result = nil
    return result
  end
  local result = self._controller:takeResult()
  if result == nil then
    return nil
  end
  assert(
    result.kind == "return" or result.kind == "move_selected" or result.kind == "cancelled",
    "the summary reports return, selection, or cancellation"
  )
  return result
end

-- Cancels a held press through both owners: the session drops its
-- capture and the controller releases its own, so a stale release never
-- activates.
function SummaryScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  self._controller:cancelPointerCapture()
end

-- Idempotent release of the per-open lifetime: the preparation lease,
-- the session, and the controller release exactly once, a pending result
-- is discarded and no result is reported after disposal.
function SummaryScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._result = nil
  self._session:dispose()
  self._controller:dispose()
  local lease = self._lease
  self._lease = nil
  if lease ~= nil then
    lease:release()
  end
end

return SummaryScreenState
