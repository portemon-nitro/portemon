-- The current Starter Choice's four function references with matching
-- render and input callbacks. DualDisplay maps info to the world surface
-- and the machine interaction to auxiliary irrespective of either
-- region's touch flag; wide pairs info left of the machine and tall
-- stacks info above it, sharing one integer scale with no synthetic gap;
-- nativeLike resolves one complete machine-derived chooser in a single
-- 256x192 pane. A pair that cannot fit 1x falls back to the effective
-- nativeLike case. Underfilled panes carry fitted chrome: one complete
-- outer frame around the pair envelope, or one per underfilled pane.
-- Resolvers require the complete context the owning session supplies.
-- The native
-- mapper reads the state-owned scene presentation from the session view
-- for source-space hit mapping; resolution alone never touches it. A
-- per-case override replaces the whole render/input pair, never a mode
-- token.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

---@class StarterChoiceInterface
local StarterChoiceInterface = {}

local INFO_NATIVE = { id = "info", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local MACHINE_NATIVE = { id = "machine", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local INPUT_KEY = "starter"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderNative(resources, view, plan)
  local presentation = assert(resources.presentation, "the starter render borrows its presentation")
  local text = assert(resources.text, "the starter render borrows its text provider")
  local windowRenderer = assert(resources.windowRenderer, "the starter render borrows the field window renderer")
  local renderAlpha = assert(resources.renderAlpha, "the starter render borrows the field interpolation alpha")
  assert(type(view.selectionState) == "string", "the starter render reads the controller snapshot")
  local snapshot = view
  presentation --[[@as { drawNative: fun(self: table<string, unknown>, snapshot: table<string, unknown>, view: table<string, unknown>, text: table<string, unknown>, plan: table<string, unknown>, windowRenderer: table<string, unknown>, renderAlpha: number) }]].drawNative(
    presentation,
    snapshot,
    view,
    text,
    plan,
    windowRenderer,
    renderAlpha
  )
end

-- NativeLike render: the machine entrypoint through the single-pane plan.
-- The field interpolation alpha defaults to full when the caller carries
-- none; the borrowed window renderer is always required first.
---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderNativeLike(resources, view, plan)
  local presentation = assert(resources.presentation, "the starter render borrows its presentation")
  local text = assert(resources.text, "the starter render borrows its text provider")
  local windowRenderer = assert(resources.windowRenderer, "the starter render borrows the field window renderer")
  assert(type(view.selectionState) == "string", "the starter render reads the controller snapshot")
  local snapshot = view
  local renderAlpha = resources.renderAlpha
  if renderAlpha == nil then
    renderAlpha = 1
  end
  presentation --[[@as { drawNative: fun(self: table<string, unknown>, snapshot: table<string, unknown>, view: table<string, unknown>, text: table<string, unknown>, plan: table<string, unknown>, windowRenderer: table<string, unknown>, renderAlpha: number) }]].drawNative(
    presentation,
    snapshot,
    view,
    text,
    plan,
    windowRenderer,
    renderAlpha
  )
end

local function noopRender(_, _, _) end

---@return nil
local function noopMap(_, _, _)
  return nil
end

---@return ApplicationPlan a valid inactive plan: no panes, no targets, cancellation still deliverable
local function inactivePlan()
  return {
    panes = {},
    frames = {},
    content = {},
    inputKey = "starter-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

---@param panes table<integer, table<string, unknown>> the resolved ordered panes
---@param frames table<integer, table<string, unknown>> the static outer-frame geometry
---@param render fun(resources: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan)
---@param mapInput fun(event: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan): table<string, unknown>?
---@param inputKey string the stable input-geometry identity
---@return ApplicationPlan
local function starterPlan(panes, frames, render, mapInput, inputKey)
  return {
    panes = panes,
    frames = frames,
    -- The blocking choice never dismisses: outside presses stay blocking
    -- under the existing mapper.
    content = {},
    inputKey = inputKey,
    render = render,
    mapInput = mapInput,
  }
end

-- The state-owned scene presentation plus the controller snapshot behind
-- one mapping view. Resolution never needs them; only native hit mapping
-- does.
---@param view table<string, unknown> the session view
---@return table<string, unknown> presentation, table<string, unknown> snapshot
local function mappingInputs(view)
  assert(type(view) == "table", "native hit mapping reads the session view")
  local presentation = assert(view.presentation, "native hit mapping needs the scene presentation")
  assert(type(presentation.ballAt) == "function", "native hit mapping needs source-space projection")
  assert(type(view.selectionState) == "string", "native hit mapping needs the controller snapshot")
  return presentation, view
end

-- Native machine mapper: source-space hits become controller taps
-- through the unchanged canonical projection; taps outside the machine
-- keep the current tap(nil) reversal contract. Only the press edge
-- dispatches; moves, releases, and scrolls carry no starter semantics.
---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> the session view carrying the scene presentation
---@return table<string, unknown>? the app event, or nil when the machine ignores it
local function mapNativeInput(event, view, _)
  if event.type ~= "pointer_down" then
    return nil
  end
  if event.outside == true then
    return { type = "tap", index = nil }
  end
  local x, y = event.x, event.y
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  local presentation, snapshot = mappingInputs(view)
  local ball = presentation:ballAt(x, y, snapshot)
  if ball == nil then
    return { type = "tap", index = nil }
  end
  return { type = "tap", index = ball - 1 }
end

-- DualDisplay: info on the world surface, machine interaction on
-- auxiliary irrespective of touch flags. The machine never crops; the
-- info pane may use the default four-edge budget only to cover its own
-- display (its message and portrait content stays at least eight logical
-- pixels inside every edge, so bounded overdraw cannot hide it). Each
-- underfilled physical pane carries its own complete outer frame.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StarterChoiceInterface.dualDisplay(context, view)
  local _ = view
  local geometry = ApplicationLayout.nativeDual(context, INFO_NATIVE, MACHINE_NATIVE, {
    lower = { maxOverdraw = ZERO_CROP },
  })
  local info = geometry.placements[INFO_NATIVE.id]
  local machine = geometry.placements[MACHINE_NATIVE.id]
  if info == nil or machine == nil then
    return inactivePlan()
  end
  return starterPlan({
    { id = INFO_NATIVE.id, placement = info, interactive = false },
    { id = MACHINE_NATIVE.id, placement = machine, interactive = true },
  }, geometry.frames or {}, renderNative, mapNativeInput, INPUT_KEY)
end

-- NativeLike: one complete machine-derived chooser, fullscreen with no
-- crop, using the native machine ball mapping for pointer input. A
-- covered target stays unframed; an underfilled one refits as a complete
-- decorated box with zero crop.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StarterChoiceInterface.nativeLike(context, view)
  local _ = view
  local geometry = ApplicationLayout.coverOrFrame(context, MACHINE_NATIVE, { maxOverdraw = ZERO_CROP })
  local pane = geometry.placements[MACHINE_NATIVE.id]
  if pane == nil then
    return inactivePlan()
  end
  return starterPlan({
    { id = MACHINE_NATIVE.id, placement = pane, interactive = true },
  }, geometry.frames or {}, renderNativeLike, mapNativeInput, INPUT_KEY)
end

-- Wide: info left, machine right, one shared integer scale with no gap and
-- one fitted frame around the common envelope. A pair that cannot fit 1x
-- falls back to the effective nativeLike entry without changing the
-- measured configuration.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StarterChoiceInterface.wide(context, view)
  local geometry = ApplicationLayout.sideBySide(context, INFO_NATIVE, MACHINE_NATIVE)
  if geometry == nil then
    return context.nativeLikeInterface(context, view)
  end
  local info = geometry.placements[INFO_NATIVE.id]
  local machine = geometry.placements[MACHINE_NATIVE.id]
  if info == nil or machine == nil then
    return inactivePlan()
  end
  return starterPlan({
    { id = INFO_NATIVE.id, placement = info, interactive = false },
    { id = MACHINE_NATIVE.id, placement = machine, interactive = true },
  }, geometry.frames or {}, renderNative, mapNativeInput, INPUT_KEY)
end

-- Tall: info above, machine below, one shared integer scale with no gap
-- and one fitted frame around the common envelope, with the same 1x
-- fallback as wide.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StarterChoiceInterface.tall(context, view)
  local geometry = ApplicationLayout.stacked(context, INFO_NATIVE, MACHINE_NATIVE)
  if geometry == nil then
    return context.nativeLikeInterface(context, view)
  end
  local info = geometry.placements[INFO_NATIVE.id]
  local machine = geometry.placements[MACHINE_NATIVE.id]
  if info == nil or machine == nil then
    return inactivePlan()
  end
  return starterPlan({
    { id = INFO_NATIVE.id, placement = info, interactive = false },
    { id = MACHINE_NATIVE.id, placement = machine, interactive = true },
  }, geometry.frames or {}, renderNative, mapNativeInput, INPUT_KEY)
end

-- The bound default resolver set: the same four stable functions above.
-- A per-case override replaces entries centrally at session composition;
-- the gameplay controller instance never changes.
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function StarterChoiceInterface.defaults()
  return {
    dualDisplay = StarterChoiceInterface.dualDisplay,
    nativeLike = StarterChoiceInterface.nativeLike,
    wide = StarterChoiceInterface.wide,
    tall = StarterChoiceInterface.tall,
  }
end

return StarterChoiceInterface
