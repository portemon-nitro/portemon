-- The concrete summary application: the per-open wrapper binding the
-- bounded summary controller to one presentation session. Each tick
-- resolves a complete plan against fresh model facts, maps one ordered
-- batch, advances the controller once, then resolves again for the
-- resulting snapshot without advancing semantic clocks. Geometry lives
-- in the session, never in the host; the four display resolvers are
-- private to this composition (fullscreen for dual and native-like
-- cases, a static framed box for wide and tall). Construction is
-- failure-safe: a failed session or controller releases whatever the
-- open acquired. The child never consumes an item or teaches a move:
-- normal reorders publish one complete mon update through the owned
-- preparation path, and move_pick mode is strictly read-only.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local SummaryController = require("libs.hgss.src.ui.SummaryController")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")

---@class SummaryScreenState
---@field _service HgssMonService the live mon service
---@field _manifest table<string, unknown> the borrowed party manifest for badges
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _controller SummaryController
---@field _session ApplicationPresentation the per-open presentation session
---@field _disposed boolean
local SummaryScreenState = {}
SummaryScreenState.__index = SummaryScreenState

local NATIVE = { id = "content", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local INPUT_KEY = "summary"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

-- Forward declarations: the context completion below falls back to the
-- native-like resolver, which is defined after it. Locals keep the
-- resolvers out of the module surface.
local fullscreen, framed

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderSummary(resources, view, plan)
  local renderer = assert(resources.summaryRenderer, "the summary render borrows its renderer")
  local portraits = assert(resources.portraits, "the summary render borrows its portrait provider")
  local graphics = assert(resources.graphics, "the summary render borrows its host graphics")
  local pane = assert(plan.panes[1], "the summary plan carries its content pane")
  local LogicalSurface = require("libs.ui.src.LogicalSurface")
  LogicalSurface.draw(graphics, assert(pane.placement, "the summary pane carries its placement"), function()
    renderer.draw(renderer, view, assert(plan.content.layout, "the summary plan carries its canonical layout"), {
      manifest = resources.manifest,
      portraits = portraits,
      icons = resources.icons,
      badgeImage = resources.badgeImage,
    })
  end)
end

---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? the app event, or nil when the summary ignores it
local function mapSummaryInput(event, _, _)
  if event.type == "pointer_down" and event.outside == true then
    return { type = "dismiss" }
  end
  return event
end

---@return nil
local function noopMap(_, _, _)
  return nil
end

---@return nil
local function noopRender(_, _, _) end

---@return ApplicationPlan a valid inactive plan: no panes, no targets, cancellation still deliverable
local function inactivePlan()
  return {
    panes = {},
    frames = {},
    content = {},
    inputKey = "summary-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

-- Completes a measured production context with helper-derived surface
-- selections. The effective nativeLike entry backs the below-1x framed
-- fallback.
---@param context ApplicationLayout.Context
---@return ApplicationLayout.Context the production context with helper-derived selections
local function completeContext(context)
  assert(type(context) == "table", "a resolver needs its context")
  local measurement = assert(context.measurement, "a resolver needs its display measurement")
  local selection = ApplicationLayout.selectSurfaces(measurement)
  return {
    measurement = measurement,
    configuration = context.configuration,
    primary = context.primary or selection.primary,
    secondary = context.secondary or selection.secondary,
    nativeLikeInterface = context.nativeLikeInterface or fullscreen,
  }
end

-- The canonical logical content the controller hits against: the closed
-- summary geometry sized by the current move-row count.
---@param view table<string, unknown> the wrapper semantic snapshot
---@return table<string, unknown>
local function summaryContent(view)
  local facts = view.facts
  local moveCount = 0
  if type(facts) == "table" and type(facts.moves) == "table" then
    moveCount = #facts.moves
  end
  return SummaryRenderer.layout(moveCount)
end

-- Fullscreen summary for the dualDisplay and nativeLike cases: one
-- canonical interactive pane over the owned target region, never
-- cropped. A target the pane genuinely covers stays unframed; an
-- underfilled target refits as a complete decorated box with zero crop.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function fullscreen(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.coverOrFrame(complete, NATIVE, { maxOverdraw = ZERO_CROP })
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    frames = geometry.frames or {},
    content = { layout = summaryContent(view) },
    inputKey = INPUT_KEY,
    render = renderSummary,
    mapInput = mapSummaryInput,
  }
end

-- Static framed summary for the wide and tall cases: the canonical pane
-- centered with its complete outer frame. A frame that cannot fit 1x
-- falls back to the effective nativeLike case with the same context and
-- view; the configuration keeps describing the actual measured display.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function framed(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.framed(complete, NATIVE, {})
  if geometry == nil then
    return complete.nativeLikeInterface(complete, view)
  end
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    frames = geometry.frames or {},
    content = { layout = summaryContent(view) },
    inputKey = INPUT_KEY,
    render = renderSummary,
    mapInput = mapSummaryInput,
  }
end

local function resolvers()
  return {
    dualDisplay = fullscreen,
    nativeLike = fullscreen,
    wide = framed,
    tall = framed,
  }
end

---@class SummaryScreenState.Options
---@field mons HgssMonService the live mon service
---@field manifest table<string, unknown> the borrowed party manifest for badges
---@field initialSlot integer? the zero-based opening member
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field mode "summary"|"move_pick"
---@field request table<string, unknown>? the picker request for move_pick mode

-- Validates request shapes per mode: summary carries no request and
-- reorders through the owned command; move_pick carries an explicit
-- picker request and stays read-only.
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
end

---@param opts SummaryScreenState.Options
---@return SummaryScreenState
function SummaryScreenState.new(opts)
  assert(type(opts) == "table", "the summary requires options")
  local service = assert(opts.mons, "the summary requires the live mon service")
  assert(type(service.partyCount) == "function" and service:partyCount() > 0, "the summary requires a non-empty party")
  local manifest = assert(opts.manifest, "the summary requires the party manifest")
  assert(type(manifest) == "table", "the party manifest arrives as a record")
  assert(type(opts.measureDisplay) == "function", "the summary requires the display facts")
  assert(opts.mode == "summary" or opts.mode == "move_pick", "the summary requires its mode")
  checkRequest(opts.mode, opts.request)
  local initialSlot = opts.initialSlot or 0
  assert(
    type(initialSlot) == "number" and initialSlot % 1 == 0 and initialSlot >= 0 and initialSlot < service:partyCount(),
    "the initial slot must be an occupied party position"
  )
  local self = setmetatable({
    _service = service,
    _manifest = manifest,
    _measureDisplay = opts.measureDisplay,
    _disposed = false,
  }, SummaryScreenState)
  local function refreshModel(slot)
    return SummaryModel.build(service, slot)
  end
  local wrapper = self
  local function resolveLayout()
    return wrapper:resolveLayout()
  end
  local controllerOpts = {
    mode = opts.mode,
    model = { refresh = refreshModel },
    request = opts.request,
    resolveLayout = resolveLayout,
    initialSlot = initialSlot,
  }
  local function reorderMoves(slot, a, b, revision)
    return wrapper:reorderMoves(slot, a, b, revision)
  end
  if opts.mode == "summary" then
    controllerOpts.reorderMoves = reorderMoves
  end
  local controller
  local session
  local built, buildErr = pcall(function()
    session = ApplicationPresentation.new(resolvers())
    controller = SummaryController.new(controllerOpts)
    controller:updateFixed({})
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
  self._controller = assert(controller, "the summary requires its controller")
  self._session = assert(session, "the summary requires its presentation session")
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

-- Swaps two whole move entries through one owned preparation: the
-- complete replacement records (move, PP, PP ups) exchange once after
-- revision validation, and every non-move field travels untouched.
-- Same-slot gestures never reach this command.
---@param slot integer zero-based party slot
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
  if revision ~= self._service:partyRevision() then
    return { kind = "stale" }
  end
  local mon = self._service:partyMon(slot)
  local moves = assert(mon.moves, "stored mons carry their moves")
  assert(a >= 0 and a < #moves and b >= 0 and b < #moves, "reorder rows stay inside the learned set")
  local swapped = {}
  for index, entry in ipairs(moves) do
    swapped[index] = { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
  end
  swapped[a + 1], swapped[b + 1] = swapped[b + 1], swapped[a + 1]
  mon.moves = swapped
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

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function SummaryScreenState:_view()
  local view = self._controller:status()
  view.manifest = self._manifest
  return view
end

-- The canonical logical content the controller hits against: the current
-- plan's layout, never a separately computed host geometry.
---@return table<string, unknown>
function SummaryScreenState:resolveLayout()
  local plan = self._session:plan()
  local content = assert(plan.content, "the summary plan carries its canonical content")
  return assert(content.layout, "the summary content carries its layout")
end

-- One fixed tick: resolve, map once, advance the controller once, then
-- resolve again for the resulting snapshot. pointer_cancel flows in
-- batch order; the controller absorbs it without changing selection.
---@param uiInput table[]
function SummaryScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed summary wrapper steps nothing")
  local session = self._session
  local measurement = self:_measured()
  session:resolve(measurement, self:_view())
  local mapped = session:mapInput(assert(uiInput, "the summary input must be an event list"), self:_view())
  self._controller:updateFixed(mapped)
  session:resolve(measurement, self:_view())
end

-- The presentation snapshot: the controller status (semantic view state
-- plus borrowed manifest) with presentation=plan, the single host-facing
-- layout authority. Fresh tables per call.
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

-- Idempotent release of the logical lifetime: the session and controller
-- release exactly once, a pending result is discarded and no result is
-- reported after disposal.
function SummaryScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._controller:dispose()
end

return SummaryScreenState
