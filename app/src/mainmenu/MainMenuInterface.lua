-- The startup Main Menu's function-selected interface over the shared
-- responsive placement. Every display case resolves the same fullscreen
-- interface on the primary/world usable surface: the density rule picks one
-- integer physical-pixel scale, the logical viewport feeds the canonical
-- Main Menu geometry, and tiny hosts reflow at native 1x. Dual auxiliaries
-- receive only the neutral background, never a duplicate save menu. A
-- per-case override replaces the whole render/input pair, never a mode
-- token. Resolvers require the complete context the owning session supplies.

local MainMenuLayout = require("app.src.mainmenu.MainMenuLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local PixelScale = require("libs.ui.src.PixelScale")

---@class MainMenuInterface
local MainMenuInterface = {}

local PANE_ID = "content"
local INPUT_KEY = "main-menu"
local DENSITY_WIDTH = 320
local DENSITY_HEIGHT = 240
local MAX_DENSITY_SCALE = 3
local function clampScale(value)
  return math.max(1, math.min(MAX_DENSITY_SCALE, value))
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderMenu(resources, view, plan)
  local renderer = assert(resources.renderer, "the menu render borrows its renderer")
  renderer:draw(view, plan)
end

-- The default mapper emits one semantic hit per content press: the shared
-- layout hit test with modal precedence over the resolved logical
-- geometry. Scroll, move and release carry no menu action; the
-- session owns capture and cancellation around this mapper.
---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan the resolved interface plan
---@return table<string, string|nil>? the semantic hit, or nil when the press targets nothing actionable
local function mapMenuInput(event, view, plan)
  if event.type ~= "pointer_down" then
    return nil
  end
  if event.outside == true then
    return nil
  end
  local content = assert(plan.content, "the menu plan carries its logical content")
  local layout = assert(content.layout, "the menu content carries its computed geometry")
  local hit = MainMenuLayout.hitTest(layout, view, event.x, event.y)
  if hit.region == nil then
    return nil
  end
  return hit
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
    inputKey = "main-menu-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

---@param rect table<string, number>
---@return table<string, number>
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

-- Responsive fullscreen menu for every display case: one primary content
-- pane over the owned target region. Dual auxiliaries join coverage with
-- the neutral background; the save interface never duplicates there.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function MainMenuInterface.resolve(context, view)
  assert(type(view) == "table", "menu resolution needs the current semantic snapshot")
  local primary = assert(context.primary, "menu resolution needs its primary surface")
  local usable = primary.usableBounds
  if usable == nil then
    return inactivePlan()
  end
  local measurement = context.measurement
  local ratio = measurement.pixelRatio or 1
  assert(type(ratio) == "number" and ratio > 0, "menu resolution needs a positive pixel ratio")
  local physicalWidth = usable.width * ratio
  local physicalHeight = usable.height * ratio
  local placement
  local viewportWidth
  local viewportHeight
  local density = (physicalWidth < NativeDisplay.WIDTH or physicalHeight < NativeDisplay.HEIGHT) and 1
    or clampScale(math.floor(math.min(physicalWidth / DENSITY_WIDTH, physicalHeight / DENSITY_HEIGHT)))
  local covered = PixelScale.cover(usable, density, ratio)
  placement = covered.placement
  viewportWidth = covered.logicalViewport.width
  viewportHeight = covered.logicalViewport.height
  local layout = MainMenuLayout.compute(
    assert(view.globalActions, "menu resolution needs its global actions"),
    assert(view.saves, "menu resolution needs its saves"),
    assert(view.focus, "menu resolution needs its focus"),
    viewportWidth,
    viewportHeight,
    view.scrollOffset,
    view.popup,
    view.confirmation,
    type(view.catalogError) == "string" and view.catalogError ~= ""
  )
  -- The startup surface owns no paused field beneath it, so the menu keeps
  -- painting its own host background regions leaf-locally through content.
  local hostBackgrounds = { copyRect(usable) }
  local secondary = context.secondary
  if secondary ~= nil and secondary.usableBounds ~= nil then
    hostBackgrounds[#hostBackgrounds + 1] = copyRect(secondary.usableBounds)
  end
  return {
    panes = { { id = PANE_ID, placement = placement, interactive = true } },
    frames = {},
    content = { layout = layout, width = viewportWidth, height = viewportHeight, hostBackgrounds = hostBackgrounds },
    inputKey = INPUT_KEY,
    render = renderMenu,
    mapInput = mapMenuInput,
  }
end

-- One responsive function behind every display case: the startup menu is
-- fullscreen on the primary surface, never a field window.
MainMenuInterface.dualDisplay = MainMenuInterface.resolve
MainMenuInterface.nativeLike = MainMenuInterface.resolve
MainMenuInterface.wide = MainMenuInterface.resolve
MainMenuInterface.tall = MainMenuInterface.resolve

-- The bound default resolver set: the same stable function behind every
-- case. A per-case override replaces entries centrally at session
-- composition; the gameplay controller instance never changes.
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function MainMenuInterface.defaults()
  return {
    dualDisplay = MainMenuInterface.resolve,
    nativeLike = MainMenuInterface.resolve,
    wide = MainMenuInterface.resolve,
    tall = MainMenuInterface.resolve,
  }
end

return MainMenuInterface
