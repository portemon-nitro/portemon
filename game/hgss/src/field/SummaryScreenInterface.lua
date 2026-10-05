-- The native Summary screen's host placement with matching render and
-- input callbacks. Dual pairs main above sub; wide pairs main left of sub
-- and tall stacks main above sub at one shared integer scale with no
-- synthetic gap; nativeLike shows the interactive sub pane and toggles a
-- full main-pane inspection overlay through the semantic menu edge or a
-- small host-only gutter affordance. Pairs that cannot fit 1x fall back
-- to the effective nativeLike entry without changing the measured
-- configuration. Only the sub pane is interactive: native touch targets
-- live on the touch screen, so the main pane never takes pointer input.
-- While the host inspection overlay is open, pointer input closes or
-- toggles the overlay only and never reaches hidden sub controls; Cancel
-- closes the overlay before native cancellation. A layout change discards
-- the overlay without touching native group/member/picture state. The
-- affordance sits in unused sub-pane gutter outside native controls and
-- never enters the native raster: drawPane output stays identical with or
-- without it.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")

---@class SummaryScreenInterface
local SummaryScreenInterface = {}

local MAIN_NATIVE = { id = "main", width = 256, height = 192 }
local SUB_NATIVE = { id = "sub", width = 256, height = 192 }

SummaryScreenInterface.PANE_WIDTH = 256
SummaryScreenInterface.PANE_HEIGHT = 192
local INPUT_KEY = "summary"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

SummaryScreenInterface.AFFORDANCE = { x = 144, y = 168, width = 42, height = 21 }
SummaryScreenInterface.AFFORDANCE_LABEL = "MAIN"

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderSummary(resources, view, plan)
  local renderer = assert(resources.summaryRenderer, "the summary render borrows its renderer")
  local bundle = resources.summaryBundle or assert(view.resources, "the summary render needs its ready bundle")
  local graphics = assert(resources.graphics, "the summary render borrows its host graphics")
  local LogicalSurface = require("libs.ui.src.LogicalSurface")
  local panes = assert(plan.panes, "the summary plan carries its panes")
  local inspecting = view.mainInspection == true
  local ordered = {}
  for _, pane in ipairs(panes) do
    ordered[#ordered + 1] = pane
  end
  if inspecting and #ordered == 2 and ordered[1].id == "main" and ordered[2].id == "sub" then
    ordered = { ordered[2], ordered[1] }
  end
  for _, pane in ipairs(ordered) do
    local placement = assert(pane.placement, "summary panes carry placements")
    LogicalSurface.draw(graphics, placement, function()
      renderer.drawPane(renderer, view, assert(pane.id, "summary panes carry identities"), bundle)
    end)
  end
  -- The single-owner entry fade draws here, over the retained native
  -- frame: full black at coefficient 16 clearing to nothing at 0. The
  -- native raster underneath stays identical across host layouts.
  if view.entryFade ~= nil then
    local coefficient = assert(view.entryFade, "entry fades carry their coefficient")
    assert(type(coefficient) == "number", "entry fades carry their coefficient")
    for _, pane in ipairs(ordered) do
      local placement = assert(pane.placement, "summary panes carry placements")
      LogicalSurface.draw(graphics, placement, function()
        graphics.setColor(0, 0, 0, coefficient / 16)
        graphics.rectangle("fill", 0, 0, SummaryScreenInterface.PANE_WIDTH, SummaryScreenInterface.PANE_HEIGHT)
      end)
    end
  end
  local untyped = plan --[[@as table<string, unknown>]]
  if untyped.nativeLike == true and inspecting ~= true then
    local placement = assert(ordered[#ordered].placement, "the affordance rides the sub placement")
    LogicalSurface.draw(graphics, placement, function()
      local box = SummaryScreenInterface.AFFORDANCE
      graphics.setColor(1, 1, 1, 1)
      graphics.rectangle("line", box.x, box.y, box.width, box.height)
      local text = bundle.text
      if type(text) == "table" and type(text.drawText) == "function" then
        text:drawText(SummaryScreenInterface.AFFORDANCE_LABEL, box.x + 4, box.y + 4)
      end
    end)
  end
end

---@param box table<string, integer>
---@param x number
---@param y number
---@return boolean inside
local function inAffordance(box, x, y)
  return x >= box.x and x < box.x + box.width and y >= box.y and y < box.y + box.height
end

---@param event table<string, unknown> session-inverted logical input in sub-pane coordinates
---@param view table<string, unknown> the wrapper semantic snapshot
---@return table<string, unknown>? the app event, or nil when consumed without a native edge
local function mapNativeLikeInput(event, view, _)
  if view.mainInspection == true then
    if event.type == "pointer_down" then
      return { type = "inspect_close" }
    end
    return nil
  end
  if event.type == "pointer_down" and event.outside ~= true then
    if inAffordance(SummaryScreenInterface.AFFORDANCE, event.x, event.y) then
      return { type = "inspect_open" }
    end
  end
  if event.type == "pointer_down" and event.outside == true then
    return { type = "dismiss" }
  end
  return event
end

---@param event table<string, unknown> session-inverted logical input in sub-pane coordinates
---@return table<string, unknown>? the app event, or nil when the summary ignores it
local function mapPairedInput(event, _, _)
  if event.type == "pointer_down" and event.outside == true then
    return { type = "dismiss" }
  end
  return event
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
    inputKey = "summary-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

-- Binds the validated manifest and returns the default resolver set: the
-- manifest rides the resolver closures; the effective nativeLike entry
-- backs the below-1x framed fallback.
---@param manifest table<string, unknown> the validated summary presentation manifest
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function SummaryScreenInterface.defaults(manifest)
  assert(type(manifest) == "table", "the summary interface requires its validated manifest")

  -- Annotates a geometry placement copy with its frame origin: the
  -- shared placement record carries no top-level coordinates, while
  -- host ordering reads pane origins directly. Copies only; the
  -- borrowed geometry record is never mutated.
  ---@param placement table<string, unknown>
  ---@return table<string, unknown> annotated copy
  local function withOrigin(placement)
    local frame = assert(placement.frame, "summary panes carry their frame")
    local copy = {}
    for key, value in pairs(placement) do
      copy[key] = value
    end
    copy.x = frame.x
    copy.y = frame.y
    return copy
  end

  ---@param panes table[] the resolved panes
  ---@param frames table[] the resolved outer frames
  ---@param mapInput fun(event: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan): table<string, unknown>?
  ---@param nativeLike boolean whether the plan is the single-display entry
  ---@param view table<string, unknown> the wrapper semantic snapshot
  ---@return ApplicationPlan
  local function summaryPlan(panes, frames, mapInput, nativeLike, view)
    -- Only the interactive lifetime publishes native panes: preparing
    -- and failed wrappers show the host cover through the inactive plan,
    -- while entering already retains the stable native frame under its
    -- fade. A foreign view without a wrapper phase never opens panes.
    local phase = view.wrapperPhase
    if phase ~= "active" and phase ~= "entering" then
      return inactivePlan()
    end
    local annotated = {}
    for _, pane in ipairs(panes) do
      annotated[#annotated + 1] = {
        id = pane.id,
        placement = withOrigin(pane.placement),
        interactive = pane.interactive,
      }
    end
    return {
      panes = annotated,
      frames = frames,
      content = {},
      inputKey = INPUT_KEY,
      nativeLike = nativeLike,
      render = renderSummary,
      mapInput = mapInput,
    }
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function nativeLikeImpl(context, view)
    local geometry = ApplicationLayout.coverOrFrame(context, SUB_NATIVE, { maxOverdraw = ZERO_CROP })
    local placement = geometry.placements[SUB_NATIVE.id]
    if placement == nil then
      return inactivePlan()
    end
    return summaryPlan({
      { id = MAIN_NATIVE.id, placement = placement, interactive = false },
      { id = SUB_NATIVE.id, placement = placement, interactive = true },
    }, geometry.frames or {}, mapNativeLikeInput, true, view)
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@param horizontal boolean
  ---@return ApplicationPlan
  local function paired(context, view, horizontal)
    local geometry
    if horizontal then
      geometry = ApplicationLayout.sideBySide(context, MAIN_NATIVE, SUB_NATIVE)
    else
      geometry = ApplicationLayout.stacked(context, MAIN_NATIVE, SUB_NATIVE)
    end
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    local main = geometry.placements[MAIN_NATIVE.id]
    local sub = geometry.placements[SUB_NATIVE.id]
    if main == nil or sub == nil then
      return inactivePlan()
    end
    return summaryPlan({
      { id = MAIN_NATIVE.id, placement = main, interactive = false },
      { id = SUB_NATIVE.id, placement = sub, interactive = true },
    }, geometry.frames or {}, mapPairedInput, false, view)
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function dualDisplay(context, view)
    local geometry = ApplicationLayout.nativeDual(context, MAIN_NATIVE, SUB_NATIVE, {
      lower = { maxOverdraw = ZERO_CROP },
    })
    local main = geometry.placements[MAIN_NATIVE.id]
    local sub = geometry.placements[SUB_NATIVE.id]
    if main == nil or sub == nil then
      return inactivePlan()
    end
    return summaryPlan({
      { id = MAIN_NATIVE.id, placement = main, interactive = false },
      { id = SUB_NATIVE.id, placement = sub, interactive = true },
    }, geometry.frames or {}, mapPairedInput, false, view)
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function wideCase(context, view)
    return paired(context, view, true)
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function tallCase(context, view)
    return paired(context, view, false)
  end

  return {
    dualDisplay = dualDisplay,
    nativeLike = nativeLikeImpl,
    wide = wideCase,
    tall = tallCase,
  }
end

return SummaryScreenInterface
