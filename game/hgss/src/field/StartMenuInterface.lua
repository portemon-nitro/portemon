-- The current Start Menu's four function references with matching render and
-- input callbacks. DualDisplay and nativeLike resolve cover-or-frame over
-- the owned target region; wide and tall center the canonical
-- 256x192 body in a static framed box with zero crop (the source
-- header/cancel target reaches the edge). The renderer is the existing
-- generated surface invoked through the resolved placement; input passes canonical body
-- coordinates to the existing controller and ignores matte and scroll. A
-- per-case override replaces the whole render/input pair, never a mode
-- token. Resolvers require the complete context the owning session
-- supplies.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")

---@class StartMenuInterface
local StartMenuInterface = {}

local NATIVE = { id = "content", width = 256, height = 192 }
local INPUT_KEY = "start-menu"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderStartMenu(resources, view, plan)
  local renderer = assert(resources.startMenuRenderer, "the start menu needs its renderer")
  local pane = assert(plan.panes[1], "the start menu plan needs its content pane")
  renderer --[[@as { draw: fun(self: table<string, unknown>, presentation: table<string, unknown>, placement: table<string, unknown>) }]].draw(
    renderer,
    view,
    pane.placement
  )
end

---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? the app event, or nil when the menu ignores it
local function mapStartInput(event, _, _)
  if event.type == "pointer_scroll" then
    return nil
  end
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
    inputKey = "start-menu-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

-- Fullscreen Start Menu for the dualDisplay and nativeLike cases: one
-- canonical interactive body pane over the owned target region. A target
-- the pane genuinely covers stays unframed; an underfilled target refits
-- as a complete decorated box with zero crop.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StartMenuInterface.fullscreen(context, view)
  local geometry = ApplicationLayout.coverOrFrame(context, NATIVE, { maxOverdraw = ZERO_CROP })
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local _ = view
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    frames = geometry.frames or {},
    content = { body = { x = 0, y = 0, width = NATIVE.width, height = NATIVE.height } },
    inputKey = INPUT_KEY,
    render = renderStartMenu,
    mapInput = mapStartInput,
  }
end

-- Static framed Start Menu for the wide and tall cases: the canonical body
-- centered with its complete outer frame. A frame that cannot fit 1x falls
-- back to the effective nativeLike case with the same context and view; the
-- configuration keeps describing the actual measured display.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StartMenuInterface.framed(context, view)
  local geometry = ApplicationLayout.framed(context, NATIVE, {})
  if geometry == nil then
    return context.nativeLikeInterface(context, view)
  end
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local _ = view
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    frames = geometry.frames or {},
    content = { body = { x = 0, y = 0, width = NATIVE.width, height = NATIVE.height } },
    inputKey = INPUT_KEY,
    render = renderStartMenu,
    mapInput = mapStartInput,
  }
end

-- The four resolver functions behind one case per display configuration:
-- dual and native-like own their fullscreen region, wide and tall center
-- the canonical body in a static frame.
StartMenuInterface.dualDisplay = StartMenuInterface.fullscreen
StartMenuInterface.nativeLike = StartMenuInterface.fullscreen
StartMenuInterface.wide = StartMenuInterface.framed
StartMenuInterface.tall = StartMenuInterface.framed

-- The bound default resolver set: the same four stable functions above.
-- A per-case override replaces entries centrally at session composition;
-- the gameplay controller instance never changes.
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function StartMenuInterface.defaults()
  return {
    dualDisplay = StartMenuInterface.fullscreen,
    nativeLike = StartMenuInterface.fullscreen,
    wide = StartMenuInterface.framed,
    tall = StartMenuInterface.framed,
  }
end

return StartMenuInterface
