-- The concrete party-screen application: the per-open wrapper binding
-- the native fixed-tick controller to one presentation session. Each tick
-- resolves a complete plan against fresh display facts, maps one ordered
-- batch, advances the controller once, then resolves again for the
-- resulting snapshot without advancing semantic clocks. Geometry lives in
-- the session, never in the host; a measurement change cancels held
-- presses through both owners. Construction is failure-safe: a failed
-- session or controller releases whatever the open acquired. Missing
-- production capabilities fail at construction, never on first draw.
-- Intents and completions forward to the controller; only the final close
-- record translates for the host.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")
local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")

---@class PartyScreenState
---@field _service HgssMonService the live mon service
---@field _manifest table<string, unknown> the validated party presentation manifest
---@field _policy table<string, unknown> the injected action policy
---@field _promptShape table<string, unknown> the yes/no prompt shape for confirmations
---@field _context string the named party context for this open
---@field _targetPromptKey ("giveTarget"|"useTarget"|"teachTarget")? the lower prompt for item target contexts
---@field _item { key: string, bagRevision: integer }? the pending item for give continuation and target contexts
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _prepareIcons fun(iconKeys: string[]): boolean, string?
---@field _cancelIconPreparation fun()
---@field _preparationState "pending"|"ready"|"failed"
---@field _preparationError string?
---@field _preparedKeys string?
---@field _preparationReleased boolean
---@field _revealPhase "opening"|"interactive"? the post-preparation lifecycle; nil while icons are not ready
---@field _revealFirst integer the completed steps of the first-pane leg (0..6)
---@field _revealSecond integer the completed steps of the second-pane leg (0..6)
---@field _settleTicks integer gated interactive ticks remaining before input forwards
---@field _detailOverlay boolean the wrapper-owned host toggle for the one-display detail overlay; never persisted, never native state
---@field _controller PartyScreenController
---@field _session ApplicationPresentation the per-open presentation session
---@field _signature string? the last resolved measurement signature
---@field _disposed boolean
local PartyScreenState = {}
PartyScreenState.__index = PartyScreenState

-- The fallback browse policy when a screen injects no action policy: only locally completable branches stay reachable. Switch reorders through the delayed swap; Quit closes. Summary, held-item, mail, and field-move branches arrive with their owning flows, never as silent no-ops.
---@param service HgssMonService
---@param labels table<string, unknown>?
---@return table<string, unknown> the browse action policy
local function productionPolicy(service, labels)
  local function text(key, fallback)
    if type(labels) == "table" and type(labels[key]) == "string" then
      return labels[key]
    end
    return fallback
  end
  local function menuFor(_, _)
    local entries = {}
    if service:partyCount() >= 2 then
      entries[#entries + 1] = { kind = "switch", label = text("switch", "SWITCH") }
    end
    entries[#entries + 1] = { kind = "quit", label = text("quit", "QUIT") }
    return entries
  end
  local function unreachable(submenuKind)
    error("party composition offers no " .. tostring(submenuKind) .. " submenus", 2)
  end
  local function submenuFor(_, menuKind)
    unreachable(menuKind)
    return {}
  end
  local function evaluateTarget(_, _)
    return { compatible = true }
  end
  return { menuFor = menuFor, submenuFor = submenuFor, evaluateTarget = evaluateTarget }
end

---@param manifest table<string, unknown>?
---@return table<string, unknown>? display labels or nil without a manifest
local function manifestLabels(manifest)
  if type(manifest) ~= "table" then
    return nil
  end
  local text = manifest.text
  if type(text) ~= "table" then
    return nil
  end
  local labels = text.labels
  if type(labels) ~= "table" then
    return nil
  end
  return labels
end

---@class PartyScreenState.Options
---@field service HgssMonService the live mon service
---@field manifest table<string, unknown> the validated party presentation manifest
---@field actionPolicy table<string, unknown>? the action policy (defaults to the production browse policy)
---@field uiManifest table<string, unknown>? the field-UI manifest carrying the yes/no prompt shape
---@field context string? the named party context (defaults to browse)
---@field targetPromptKey ("giveTarget"|"useTarget"|"teachTarget")? the lower prompt for item target contexts
---@field item { key: string, bagRevision: integer }? the pending item for give continuation and target contexts
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field initialFocus integer|"cancel"? the opening cursor (defaults to the nearest selectable node)
---@field initialMessage { templateKey: "giveHeldItem", displayName: string, itemNames: string[] }? Party-owned held-item result on entry
---@field overrides table<string, unknown>? per-case function overrides for this application
---@field prepareIcons fun(iconKeys: string[]): boolean, string? required icon preparation collaborator
---@field cancelIconPreparation fun() required preparation release collaborator
---@field effect fun(sequence: string)? the borrowed swap sound boundary forwarded to the native controller

---@param opts PartyScreenState.Options
---@return PartyScreenState
function PartyScreenState.new(opts)
  assert(type(opts) == "table", "the party screen requires options")
  local service = assert(opts.service, "the party screen requires the live mon service")
  assert(type(opts.measureDisplay) == "function", "the party screen requires the display facts")
  assert(type(opts.prepareIcons) == "function", "the party screen requires its icon preparation")
  assert(type(opts.cancelIconPreparation) == "function", "the party screen requires its preparation release")
  if opts.effect ~= nil then
    assert(type(opts.effect) == "function", "the party sound boundary is a function")
  end
  assert(
    type(service.partyCount) == "function" and service:partyCount() > 0,
    "the party screen requires a non-empty party"
  )
  local manifest = assert(opts.manifest, "the party screen requires the validated party manifest")
  assert(type(manifest) == "table", "the party screen requires the validated party manifest")
  -- The modal take confirmation binds the generated prompt shape; a
  -- missing definition fails the open instead of falling back.
  local promptShape
  if opts.uiManifest ~= nil then
    local promptSection = assert(opts.uiManifest.yesNoPrompt, "the field-UI manifest carries the prompt section")
    assert(type(promptSection) == "table", "the field-UI manifest carries the prompt section")
    local promptShapes = assert(promptSection.shapes, "the prompt section carries its shape map")
    promptShape = assert(promptShapes.compact, "the field-UI manifest carries the compact prompt shape")
  end
  local context = opts.context or "browse"
  assert(
    context == "browse"
      or context == "pick"
      or context == "item_target"
      or context == "give_target"
      or context == "give_resume",
    "the party screen requires a named context"
  )
  local targetPromptKey = opts.targetPromptKey
  if context == "give_target" then
    assert(targetPromptKey == "giveTarget", "give targets require the Give prompt")
  elseif context == "item_target" then
    assert(
      targetPromptKey == "useTarget" or targetPromptKey == "teachTarget",
      "item targets require the Use or Teach prompt"
    )
  else
    assert(targetPromptKey == nil, "only target contexts carry a target prompt")
  end
  local self = setmetatable({
    _service = service,
    _manifest = manifest,
    _policy = opts.actionPolicy or productionPolicy(service, manifestLabels(manifest)),
    _promptShape = promptShape,
    _context = context,
    _targetPromptKey = targetPromptKey,
    _item = opts.item,
    _measureDisplay = opts.measureDisplay,
    _prepareIcons = opts.prepareIcons,
    _cancelIconPreparation = opts.cancelIconPreparation,
    _preparationState = "pending",
    _preparationError = nil,
    _preparedKeys = nil,
    _preparationReleased = false,
    _revealPhase = nil,
    _revealFirst = 0,
    _revealSecond = 0,
    _settleTicks = 0,
    _detailOverlay = false,
    _disposed = false,
  }, PartyScreenState)
  local function refreshModel()
    return PartyScreenModel.build(service)
  end
  local function partyRevision()
    return service:partyRevision()
  end
  local function swapPartyMons(a, b)
    service:swapPartyMons(a, b)
  end
  local wrapper = self
  local function resolveLayout()
    return wrapper:resolveLayout()
  end
  local controller
  local session
  local built, buildErr = pcall(function()
    session = ApplicationPresentation.new(PartyScreenInterface.defaults(manifest), opts.overrides)
    controller = PartyScreenController.new({
      context = context,
      initialFocus = opts.initialFocus,
      initialMessage = opts.initialMessage,
      model = {
        refresh = refreshModel,
      },
      layout = resolveLayout,
      swap = {
        partyRevision = partyRevision,
        swapPartyMons = swapPartyMons,
      },
      actionPolicy = self._policy,
      promptShape = self._promptShape,
      item = self._item,
      effect = opts.effect,
    })
  end)
  if not built then
    if session ~= nil then
      session:dispose()
    end
    if controller ~= nil then
      controller:dispose()
    end
    error(buildErr, 0)
  end
  self._controller = assert(controller, "the party screen requires its native controller")
  self._session = assert(session, "the party screen requires its presentation session")
  local resolveOk, resolveErr = pcall(function()
    self._session:resolve(self:_measured(), self:_view())
  end)
  if not resolveOk then
    self._controller:dispose()
    self._session:dispose()
    error(resolveErr, 0)
  end
  return self
end

---@return DisplayMeasurement
function PartyScreenState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the party screen requires current display facts")
end

-- The icon keys behind the current view: occupied slots only, in slot
-- order. Read-only: preparation advances on update, never on status/draw.
---@return string[] keys
---@return string joined
function PartyScreenState:_currentIconKeys()
  local service = assert(self._service, "the party screen keeps its mon service")
  local model = PartyScreenModel.build(service)
  local keys = {}
  for _, slot in ipairs(model.slots) do
    if slot.occupied and type(slot.iconKey) == "string" then
      keys[#keys + 1] = slot.iconKey
    end
  end
  return keys, table.concat(keys, "\0")
end

-- The resolved layout for the preparation wait screen, measured against
-- the current display facts. Ready draws resolve through the session
-- plan instead; this layout only places the wait/failure copy.
---@return PartyScreenLayoutResolved
function PartyScreenState:_layout()
  local measurement = self:_measured()
  return PartyScreenLayout.resolve({
    manifest = self._manifest,
    width = measurement.width,
    height = measurement.height,
    cancellable = self._controller:cancellable(),
  })
end

---@return table<string, unknown> the controller snapshot plus the wrapper-owned host overlay flag and reveal progress for resolvers and renderers
function PartyScreenState:_view()
  ---@type table<string, unknown>
  local view = {}
  for key, value in pairs(self._controller:status()) do
    view[key] = value
  end
  view.detailOverlay = self._detailOverlay == true
  if self._targetPromptKey ~= nil then
    view.targetPromptKey = self._targetPromptKey
  end
  if self._revealPhase ~= nil then
    view.phase = self._revealPhase
    if self._revealPhase == "opening" then
      view.opening = { subStep = self._revealFirst, mainStep = self._revealSecond }
    end
  end
  return view
end

-- The canonical logical content the controller hits against: the current
-- plan's content, never a separately computed host layout.
---@return table<string, unknown>
function PartyScreenState:resolveLayout()
  local plan = self._session:plan()
  return assert(plan.content, "the party plan carries its canonical content")
end

-- Re-resolves host placement without advancing icon preparation or the Party clock.
-- A pending/failed wait record is not a semantic view: re-resolve from the
-- canonical controller snapshot so placement never inherits wait metadata.
---@param view table<string, unknown>?
---@return table<string, unknown> current presentation plan
function PartyScreenState:refreshPresentation(view)
  assert(not self._disposed, "a disposed party wrapper refreshes nothing")
  if type(view) == "table" and view.preparationState ~= nil and view.preparationState ~= "ready" then
    return self._session:resolve(self:_measured(), self:_view())
  end
  return self._session:resolve(self:_measured(), view or self:_view())
end

-- The published plan is the native-like one-display shape exactly when
-- it carries only the interaction pane, optionally followed by the
-- noninteractive host overlay: content-only, or content plus overlay.
-- Any detail pane marks a paired composition, and any other pane
-- identity marks a custom override; neither is a toggle target.
---@param plan table<string, unknown>
---@return boolean
local function isNativeLikePlan(plan)
  local panes = plan.panes
  if type(panes) ~= "table" then
    return false
  end
  if #panes == 1 then
    local only = panes[1]
    return only.id == "content" and only.interactive == true
  end
  if #panes == 2 then
    local first = panes[1]
    local second = panes[2]
    return first.id == "content"
      and first.interactive == true
      and second.id == "overlay"
      and second.interactive == false
  end
  return false
end

-- One fixed tick: resolve, cancel stale presses across measurement
-- changes, map once, advance the controller once, then resolve again for
-- the resulting snapshot. pointer_cancel flows in batch order; the
-- controller absorbs it without changing selection.
---@param uiInput table[]
function PartyScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed party wrapper steps nothing")
  local keys, joined = self:_currentIconKeys()
  if self._preparedKeys ~= joined then
    self._preparedKeys = joined
    self._preparationState = "pending"
    self._preparationError = nil
  end
  if self._preparationState == "pending" then
    local ready, failure = self._prepareIcons(keys)
    if failure ~= nil then
      self._preparationState = "failed"
      self._preparationError = tostring(failure)
    elseif ready then
      self._preparationState = "ready"
      self._preparationError = nil
    end
  end
  if self._preparationState ~= "ready" then
    -- While waiting the screen stays cancellable but discards every other
    -- activation: held input must never replay once readiness arrives.
    local cancellations = {}
    for _, event in ipairs(assert(uiInput, "the party input must be an event list")) do
      assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
      if event.type == "cancel" then
        cancellations[#cancellations + 1] = event
      end
    end
    if #cancellations > 0 then
      self._controller:updateFixed(cancellations)
    end
    return
  end
  -- The opening reveal runs before any controller input: the ready tick
  -- publishes fully covered panes, the next twelve fixed ticks clear the
  -- first pane then the second one step per tick, the following tick
  -- hands over to the interactive phase, and one settling tick after the
  -- handover still drops its batch so the batch completing the reveal and
  -- the batch arriving on the first interactive tick can never act or
  -- replay. Every gated batch is validated and discarded, never queued.
  if self._revealPhase == nil then
    self._revealPhase = "opening"
    self._revealFirst = 0
    self._revealSecond = 0
    self._settleTicks = 0
  elseif self._revealPhase == "opening" then
    if self._revealFirst < 6 then
      self._revealFirst = self._revealFirst + 1
    elseif self._revealSecond < 6 then
      self._revealSecond = self._revealSecond + 1
    else
      self._revealPhase = "interactive"
      self._settleTicks = 2
    end
  end
  if self._revealPhase == "opening" or self._settleTicks > 0 then
    for _, event in ipairs(assert(uiInput, "the party input must be an event list")) do
      assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
    end
    if self._settleTicks > 0 then
      self._settleTicks = self._settleTicks - 1
    end
    local session = self._session
    local measurement = self:_measured()
    local signature = measurement.signature
    if signature ~= nil and signature ~= self._signature then
      if self._signature ~= nil then
        self:cancelPointerCapture()
      end
      self._signature = signature
    end
    session:resolve(measurement, self:_view())
    return
  end
  local session = self._session
  local measurement = self:_measured()
  local signature = measurement.signature
  if signature ~= nil and signature ~= self._signature then
    if self._signature ~= nil then
      self:cancelPointerCapture()
    end
    self._signature = signature
  end
  session:resolve(measurement, self:_view())
  local raw = assert(uiInput, "the party input must be an event list")
  local remaining = raw
  if isNativeLikePlan(session:plan()) then
    -- The host toggle consumes its own events in order: each menu press
    -- flips host visibility only and never reaches the native controller,
    -- while every other event keeps its order in the forwarded batch.
    local kept = {}
    local toggled = false
    for _, event in ipairs(raw) do
      assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
      if event.type == "menu" then
        self._detailOverlay = not self._detailOverlay
        toggled = true
      else
        kept[#kept + 1] = event
      end
    end
    if toggled then
      remaining = kept
      session:resolve(measurement, self:_view())
    end
  end
  local mapped = session:mapInput(remaining, self:_view())
  self._controller:updateFixed(mapped)
  session:resolve(measurement, self:_view())
end

-- The presentation snapshot: the preparation wait plus its resolved plan
-- while icons are not ready, the controller status plus presentation=plan
-- and readiness once they are, presentation=plan remaining the single
-- host-facing layout authority. Read-only: status never advances
-- preparation. Fresh tables per call.
---@return table<string, unknown>
function PartyScreenState:status()
  if self._preparationState ~= "ready" then
    return {
      open = true,
      preparationState = self._preparationState,
      preparationError = self._preparationError,
      layout = self:_layout(),
      presentation = self._session:plan(),
    }
  end
  local status = self:_view()
  if not status.open then
    return status
  end
  status.manifest = self._manifest
  status.presentation = self._session:plan()
  status.preparationState = "ready"
  return status
end

-- Forwards the one-shot intent to the flow that completes it.
---@return table<string, unknown>?
function PartyScreenState:takeIntent()
  return self._controller:takeIntent()
end

-- Forwards the flow's outcome into the waiting controller.
---@param outcome table<string, unknown>
function PartyScreenState:completeAction(outcome)
  self._controller:completeAction(outcome)
end

-- The host result contract: the final close record translates to the
-- host close and releases the preparation interest exactly once;
-- selection records pass through for target-context owners.
---@return table<string, unknown>?
function PartyScreenState:takeResult()
  local result = self._controller:takeResult()
  if result == nil then
    return nil
  end
  if result.kind == "closed" then
    self:_releasePreparation()
    return { kind = "close" }
  end
  return result
end

-- Cancels a held press through both owners: the session drops its capture
-- and the controller releases its own, so a stale release never activates.
function PartyScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  self._controller:cancelPointerCapture()
end

-- Releases the preparation interest exactly once across close and
-- disposal: a late readiness arrival cannot reopen or draw the screen.
function PartyScreenState:_releasePreparation()
  if not self._preparationReleased then
    self._preparationReleased = true
    self._cancelIconPreparation()
  end
end

-- Idempotent release of the logical lifetime: the session and controller
-- release exactly once, a pending result is discarded and no close is
-- reported after disposal.
function PartyScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:_releasePreparation()
  self._session:dispose()
  self._controller:dispose()
end

return PartyScreenState
