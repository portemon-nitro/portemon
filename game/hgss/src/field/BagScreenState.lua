-- The concrete field-bag application: the per-open wrapper binding the
-- existing browse controller and hero presenter to one presentation
-- session. Each tick maps one ordered batch through the current plan,
-- advances the controller once, then resolves again only when measured
-- host geometry or layout-relevant wrapper state moved, without
-- advancing semantic clocks. Geometry lives in the session, never in
-- the host. Construction is failure-safe: a failed session or
-- controller releases whatever the open acquired. Missing production
-- capabilities fail at construction, never on first draw.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BagActionPolicy = require("libs.hgss.src.ui.BagActionPolicy")
local BagController = require("libs.hgss.src.ui.BagController")
local BagHeroPresenter = require("libs.hgss.src.presentation.BagHeroPresenter")
local BagInterface = require("game.hgss.src.field.BagInterface")
local BagModel = require("libs.hgss.src.ui.BagModel")

---@class BagScreenState
---@field _service HgssBagService
---@field _cursor BagCursor
---@field _context "inventory"|"field"|"pick_held"|"sell"|"battle" the selection context for intent emission
---@field _manifest table<string, unknown>
---@field _heroGender "male"|"female"
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _controller BagController
---@field _session ApplicationPresentation the per-open presentation session
---@field _hero BagHeroPresenter
---@field _heroPocket string?
---@field _openingPhase "opening"|"interactive"?
---@field _openingSubStep integer
---@field _openingMainStep integer
---@field _openingInitialTick boolean
---@field _settleTicks integer
---@field _resolvedKey string? the layout key behind the published plan
---@field _disposed boolean
local BagScreenState = {}
BagScreenState.__index = BagScreenState

---@param measurement DisplayMeasurement
---@return string the host geometry behind a plan resolution
local function measurementKey(measurement)
  return table.concat({
    tostring(measurement.signature),
    tostring(measurement.width),
    tostring(measurement.height),
    tostring(measurement.pixelRatio),
    tostring(measurement.topology),
  }, "|")
end

---@param self BagScreenState
---@param view table<string, unknown>
---@return string the wrapper and controller state behind a plan resolution
local function semanticKey(self, view)
  return table.concat({
    tostring(self._openingPhase),
    tostring(self._openingSubStep),
    tostring(self._openingMainStep),
    tostring(view.open),
    tostring(view.state),
    tostring(view.pocket),
    tostring(view.tabFocusPocket),
    tostring(view.focus),
    tostring(view.selectedAbsoluteIndex),
    tostring(view.visibleStart),
    tostring(view.focusedAbsoluteIndex),
    tostring(view.actionNode),
  }, "|")
end

---@class BagScreenState.Options
---@field effect (fun(sequence: string))? the production semantic sound boundary, silent when omitted
---@field textPolicy { interGlyphDelay: integer, glyphBudget: integer, abAcceleration: boolean }? the copied player text-speed cadence
---@field service HgssBagService the live bag service
---@field cursor BagCursor the borrowed runtime-only field cursor
---@field manifest table<string, unknown> the validated bag presentation manifest
---@field uiManifest table<string, unknown> the validated field-UI manifest carrying the prompt section
---@field monCatalog table<string, unknown> the borrowed compiled mon catalog
---@field heroGender "male"|"female" the profile-selected hero backdrop
---@field context "inventory"|"field"|"pick_held"|"sell"|"battle"? the selection context (defaults to inventory)
---@field battlePolicy BattleSelectionPolicy? the native selection policy, required for battle
---@field saleSession table<string, unknown>? required for sell context
---@field partyEmpty boolean? true when no party member exists to target (field contexts hide Use/Give)
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field overrides table<string, unknown>? per-case function overrides for this application

---@param opts BagScreenState.Options
---@return BagScreenState
function BagScreenState.new(opts)
  assert(type(opts) == "table", "the bag screen requires options")
  local service = assert(opts.service, "the bag screen requires the live bag service")
  assert(type(service.pocketItems) == "function", "the bag screen requires pocket reads")
  assert(type(service.catalog) == "function", "the bag screen requires the item catalog")
  assert(type(service.registeredItems) == "function", "the bag screen requires registration reads")
  assert(type(service.revision) == "function", "the bag screen requires the service revision")
  local cursor = assert(opts.cursor, "the bag screen requires the runtime bag cursor")
  assert(type(cursor.currentPocket) == "function", "the bag screen requires the cursor pocket")
  assert(type(cursor.setPocket) == "function", "the bag screen requires pocket switching")
  local manifest = assert(opts.manifest, "the bag screen requires the bag presentation manifest")
  -- The modal toss confirmation binds the generated prompt shape with the
  -- bag's semantic placement; either missing definition fails the open
  -- instead of falling back to action slots.
  local uiManifest = assert(opts.uiManifest, "the bag screen requires the field-UI manifest")
  local promptSection = assert(uiManifest.yesNoPrompt, "the field-UI manifest carries the prompt section")
  assert(type(promptSection) == "table", "the field-UI manifest carries the prompt section")
  local promptShapes = assert(promptSection.shapes, "the prompt section carries its shape map")
  local promptShape = assert(promptShapes.compact, "the field-UI manifest carries the compact prompt shape")
  local overlays = assert(manifest.interactive, "the bag manifest carries its interactive pane")
  assert(type(overlays) == "table", "the bag manifest carries its interactive pane")
  local bagOverlays = assert(overlays.overlays, "the bag manifest carries its overlay geometry")
  local tossPrompt = assert(bagOverlays.tossPrompt, "the bag manifest carries its toss prompt placement")
  local context = opts.context or "inventory"
  assert(
    context == "inventory" or context == "field" or context == "pick_held" or context == "sell" or context == "battle",
    "the bag screen needs a named inventory, field, pick_held, sell, or battle context"
  )
  local battlePolicy = opts.battlePolicy
  if context == "battle" then
    assert(battlePolicy ~= nil, "the battle bag needs its native options")
    assert(type(battlePolicy.isEnabled) == "function", "the battle policy answers selection legality")
    assert(type(battlePolicy.reason) == "function", "the battle policy explains its refusals")
  else
    assert(battlePolicy == nil, "only the battle bag takes battle options")
  end
  -- Post-selection timing and text ride the validated manifest: a bundle
  -- missing them fails the open instead of animating with silent fallbacks.
  local text = assert(overlays.text, "the bag manifest carries its semantic text")
  assert(type(text) == "table", "the bag manifest carries its semantic text")
  local controllerMessages = text
  if context == "sell" then
    controllerMessages = {}
    for key, value in pairs(text) do
      controllerMessages[key] = value
    end
    controllerMessages.sale = assert(overlays.sale.messages, "sale messages are complete")
  end
  local feedback = assert(overlays.feedback, "the bag manifest carries its activation feedback")
  assert(type(feedback) == "table", "the bag manifest carries its activation feedback")
  local feedbackTicks = assert(feedback.totalTicks, "activation feedback carries its generated total")
  assert(
    type(feedbackTicks) == "number" and feedbackTicks % 1 == 0 and feedbackTicks >= 1,
    "activation feedback carries a positive generated total"
  )
  ---@cast feedbackTicks integer
  local moveTransition = assert(overlays.moveTransition, "the bag manifest carries its move commit transition")
  assert(type(moveTransition) == "table", "the bag manifest carries its move commit transition")
  for _, key in ipairs({ "unchanged", "changed" }) do
    local clip = assert(moveTransition[key], "the move transition carries its " .. key .. " clip")
    assert(
      type(clip.totalTicks) == "number" and clip.totalTicks % 1 == 0 and clip.totalTicks >= 1,
      "the " .. key .. " clip carries a positive generated total"
    )
  end
  local textPolicy = assert(opts.textPolicy, "the bag screen requires its copied text-speed policy")
  assert(type(textPolicy) == "table", "the bag screen requires its copied text-speed policy")
  local selectionEntry = assert(overlays.selectionEntry, "the bag manifest carries its selection-entry sequence")
  local itemSelectTicks = assert(selectionEntry.totalTicks, "the selection-entry sequence carries its generated total")
  assert(
    type(itemSelectTicks) == "number" and itemSelectTicks % 1 == 0 and itemSelectTicks >= 1,
    "the selection-entry total drives the controller clock"
  )
  ---@cast itemSelectTicks integer
  local monCatalog = assert(opts.monCatalog, "the bag screen requires the mon catalog")
  assert(
    type(monCatalog) == "table" and type(monCatalog.moveByNativeId) == "function",
    "the bag screen requires move lookup"
  )
  local heroGender = assert(opts.heroGender, "the bag screen requires the hero gender")
  assert(heroGender == "male" or heroGender == "female", "the hero gender selects its backdrop")
  local saleSession = opts.saleSession
  if context == "sell" then
    assert(type(saleSession) == "table", "the selling bag requires its sale session")
    assert(type(saleSession.view) == "function", "the selling bag requires sale balance reads")
    assert(type(saleSession.quoteSell) == "function", "the selling bag requires sale quotes")
    assert(type(saleSession.commit) == "function", "the selling bag requires sale commits")
    local sale = assert(overlays.sale, "the bag manifest carries its sale presentation")
    assert(type(sale) == "table" and type(sale.messages) == "table", "sale presentation carries all messages")
  else
    assert(saleSession == nil, "only the selling bag accepts a sale session")
  end
  assert(type(opts.measureDisplay) == "function", "the bag screen requires the display facts")
  local self = setmetatable({
    _service = service,
    _cursor = cursor,
    _context = context,
    _manifest = manifest,
    _heroGender = heroGender,
    _measureDisplay = opts.measureDisplay,
    _heroPocket = nil,
    _openingPhase = "opening",
    _openingSubStep = 0,
    _openingMainStep = 0,
    _openingInitialTick = true,
    _settleTicks = 0,
    _disposed = false,
  }, BagScreenState)
  self._hero = BagHeroPresenter.new({ manifest = manifest, gender = heroGender })
  local function refreshModel()
    return BagModel.build(service, cursor, monCatalog)
  end
  local wrapper = self
  local function resolveLayout()
    return wrapper:resolveLayout()
  end
  -- The controller stays pure: every inventory mutation rides the injected
  -- semantic commands straight into the one live service, and the action
  -- menu rides the pure policy projection bound to that same service.
  -- Persistence stays with the normal save capture; nothing writes here.
  -- The battle context selects only: its commands are tripwires that fail
  -- closed instead of reaching the live service, and its action policy is
  -- empty because battle selections bypass the field action menu.
  local function tossItem(itemKey, quantity)
    return service:take(itemKey, quantity)
  end
  local function moveItem(pocketKey, fromIndex, toIndex)
    return service:move(pocketKey, fromIndex, toIndex)
  end
  local function registerItem(itemKey)
    return service:tryRegister(itemKey)
  end
  local function unregisterItem(itemKey)
    return service:unregister(itemKey)
  end
  local function deniedTake(_, _)
    error("the battle bag never calls take", 2)
  end
  local function deniedMove(_, _, _)
    error("the battle bag never calls move", 2)
  end
  local function deniedRegister(_)
    error("the battle bag never calls register", 2)
  end
  local function deniedUnregister(_)
    error("the battle bag never calls unregister", 2)
  end
  local function noBattleActions(_)
    return {}
  end
  local battleCommands = {
    toss = deniedTake,
    move = deniedMove,
    register = deniedRegister,
    unregister = deniedUnregister,
  }
  local fieldCommands = {
    toss = tossItem,
    move = moveItem,
    register = registerItem,
    unregister = unregisterItem,
  }
  local commands = fieldCommands
  local resolveActions = BagActionPolicy.forService(service)
  if context == "battle" then
    commands = battleCommands
    resolveActions = noBattleActions
  elseif context ~= "inventory" then
    resolveActions = BagActionPolicy.forField(service, opts.partyEmpty)
  end
  local function pickable(itemKey)
    return BagActionPolicy.isPickable(BagActionPolicy.fieldFacts(service, itemKey))
  end
  local isPickable = nil
  if context == "pick_held" then
    isPickable = pickable
  end
  local controller
  local session
  local built, buildErr = pcall(function()
    session = ApplicationPresentation.new(BagInterface.defaults(manifest), opts.overrides)
    controller = BagController.new({
      model = { refresh = refreshModel },
      cursor = cursor,
      context = context,
      resolveLayout = resolveLayout,
      promptShape = promptShape,
      tossPrompt = tossPrompt,
      itemSelectTicks = itemSelectTicks,
      effect = opts.effect,
      textPolicy = textPolicy,
      messages = controllerMessages,
      saleSession = saleSession,
      salePrompt = context == "sell" and assert(overlays.sale.compactPrompt) or nil,
      feedbackTicks = feedbackTicks,
      moveTransition = moveTransition,
      isPickable = isPickable,
      battlePolicy = battlePolicy,
      commands = commands,
      resolveActions = resolveActions,
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
  self._controller = assert(controller, "the bag screen requires its browse controller")
  self._session = assert(session, "the bag screen requires its presentation session")
  local resolveOk, resolveErr = pcall(function()
    local measurement = self:_measured()
    local view = self:_view()
    self._session:resolve(measurement, view)
    self._resolvedKey = measurementKey(measurement) .. "#" .. semanticKey(self, view)
  end)
  if not resolveOk then
    self._controller:dispose()
    self._session:dispose()
    error(resolveErr, 0)
  end
  return self
end

---@return DisplayMeasurement
function BagScreenState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the bag screen requires current display facts")
end

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function BagScreenState:_view()
  local view = {}
  for key, value in pairs(self._controller:status()) do
    view[key] = value
  end
  if self._openingPhase ~= nil then
    view.phase = self._openingPhase
    if self._openingPhase == "opening" then
      view.opening = { subStep = self._openingSubStep, mainStep = self._openingMainStep }
    end
  end
  return view
end

-- The canonical logical content the controller hits against: the current
-- plan's content, never a separately computed host layout.
---@return table<string, unknown>
function BagScreenState:resolveLayout()
  local plan = self._session:plan()
  return assert(plan.content, "the bag plan carries its canonical content")
end

-- Resolves the published plan only when the measured host geometry or
-- the layout-relevant wrapper and controller state moved since the last
-- resolution; unchanged ticks keep mapping through the current plan.
---@param measurement DisplayMeasurement
---@param view table<string, unknown>
function BagScreenState:_resolveWhenChanged(measurement, view)
  local key = measurementKey(measurement) .. "#" .. semanticKey(self, view)
  if key ~= self._resolvedKey then
    self._session:resolve(measurement, view)
    self._resolvedKey = key
  end
end

-- Re-resolves host placement without advancing the Bag or hero clocks.
---@param view table<string, unknown>?
---@return table<string, unknown> current presentation plan
function BagScreenState:refreshPresentation(view)
  assert(not self._disposed, "a disposed bag wrapper refreshes nothing")
  local measurement = self:_measured()
  local resolvedView = view or self:_view()
  local plan = self._session:resolve(measurement, resolvedView)
  self._resolvedKey = measurementKey(measurement) .. "#" .. semanticKey(self, resolvedView)
  return plan
end

-- One fixed tick: map once through the current plan, advance the
-- controller once, sync the hero presenter, then resolve again only when
-- the opening, semantic, or measured state moved since the last
-- resolution. pointer_cancel flows in batch order; the controller
-- absorbs it without changing selection.
---@param uiInput table[]
function BagScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed bag wrapper steps nothing")
  local session = self._session
  local measurement = self:_measured()
  local preView = self:_view()
  self:_resolveWhenChanged(measurement, preView)
  local gated = false
  if self._openingPhase == "opening" then
    if self._openingInitialTick then
      self._openingInitialTick = false
    elseif self._openingSubStep < 6 then
      self._openingSubStep = self._openingSubStep + 1
    elseif self._openingMainStep < 6 then
      self._openingMainStep = self._openingMainStep + 1
    elseif self._settleTicks == 0 then
      self._settleTicks = 2
    else
      self._settleTicks = self._settleTicks - 1
      if self._settleTicks == 0 then
        self._openingPhase = "interactive"
      end
    end
    gated = true
  end
  local input = assert(uiInput, "the bag input must be an event list")
  if gated then
    for _, event in ipairs(input) do
      assert(type(event) == "table" and type(event.type) == "string", "bag events need their type")
    end
    self._controller:updateFixed({})
    local status = self._controller:status()
    if status.open then
      if status.pocket ~= self._heroPocket then
        self._hero:selectPocket(status.pocket)
        self._heroPocket = status.pocket
      end
      self._hero:updateFixed()
    end
    self:_resolveWhenChanged(measurement, self:_view())
    return
  end
  local mapped = session:mapInput(input, preView)
  self._controller:updateFixed(mapped)
  local status = self._controller:status()
  if status.open then
    if status.pocket ~= self._heroPocket then
      self._hero:selectPocket(status.pocket)
      self._heroPocket = status.pocket
    end
    self._hero:updateFixed()
  end
  self:_resolveWhenChanged(measurement, self:_view())
end

-- The presentation snapshot: the controller status (semantic browse state)
-- with the hero presentation facts plus presentation=plan, the single
-- host-facing layout authority. Fresh tables per call.
---@return table<string, unknown>
function BagScreenState:status()
  local status = self:_view()
  if not status.open then
    return status
  end
  status.heroGender = self._heroGender
  status.hero = self._hero:status()
  status.presentation = self._session:plan()
  return status
end

-- Forwards the one-shot selection intent to the flow that routes it.
---@return table<string, unknown>?
function BagScreenState:takeIntent()
  return self._controller:takeIntent()
end

-- The host result contract: the bag only ever closes back to the menu.
---@return { kind: "close" }?
function BagScreenState:takeResult()
  local result = self._controller:takeResult()
  if result == nil then
    return nil
  end
  assert(result.kind == "closed", "the bag application only returns close")
  return { kind = "close" }
end

-- Cancels a held press through both owners: the session drops its capture
-- and the controller releases its own, so a stale release never activates.
function BagScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  self._controller:cancelPointerCapture()
end

-- Idempotent release of the logical lifetime: the session and controller
-- release exactly once, a pending result is discarded and no close is
-- reported after disposal.
function BagScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._controller:dispose()
end

return BagScreenState
