-- The mart's four pure pane resolvers pair the source upper and lower
-- displays without changing their logical geometry. NativeLike keeps only
-- the interactive lower pane; input arrives lower-local from the application
-- presentation session.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

---@class MartInterface
local MartInterface = {}

local UPPER_NATIVE = { id = "upper", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local LOWER_NATIVE = { id = "lower", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local INPUT_KEY = "mart"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the screen's semantic snapshot
---@param plan ApplicationPlan the adopted geometry and manifest-backed content
local function renderMart(resources, view, plan)
  local renderer = assert(resources.martRenderer, "the mart render borrows its renderer")
  local icons = assert(resources.icons, "the mart render borrows its icon provider")
  renderer --[[@as { draw: fun(self: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan, collaborators: table<string, unknown>) }]].draw(
    renderer,
    view,
    plan,
    { icons = icons }
  )
end

---@param event table<string, unknown> session-inverted lower-local input
---@return table<string, unknown>? the app event, or nil when the mart ignores it
local function mapMartInput(event, _, _)
  if event.type == "pointer_down" and event.outside == true then
    return { type = "dismiss" }
  end
  return event
end

---@param manifest table<string, unknown> the validated mart presentation manifest
---@param panes table<integer, table<string, unknown>> the resolved ordered panes
---@param frames ApplicationFrameGeometry[] the static outer-frame geometry
---@return ApplicationPlan
local function martPlan(manifest, panes, frames)
  return {
    panes = panes,
    frames = frames,
    content = {
      upper = assert(manifest.upper, "the mart manifest carries upper-pane content"),
      lower = assert(manifest.lower, "the mart manifest carries lower-pane content"),
    },
    inputKey = INPUT_KEY,
    render = renderMart,
    mapInput = mapMartInput,
  }
end

---@param manifest table<string, unknown> the validated mart presentation manifest
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function MartInterface.defaults(manifest)
  assert(type(manifest) == "table", "the mart interface requires its validated manifest")
  assert(type(manifest.upper) == "table", "the mart manifest carries upper-pane content")
  assert(type(manifest.lower) == "table", "the mart manifest carries lower-pane content")

  local set = {}

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function nativeLike(context, view)
    local _ = view
    local geometry = ApplicationLayout.coverOrFrame(context, LOWER_NATIVE, { maxOverdraw = ZERO_CROP })
    local lower = geometry.placements[LOWER_NATIVE.id]
    if lower == nil then
      return martPlan(manifest, {}, geometry.frames or {})
    end
    return martPlan(manifest, {
      { id = LOWER_NATIVE.id, placement = lower, interactive = true },
    }, geometry.frames or {})
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function wide(context, view)
    local geometry = ApplicationLayout.sideBySide(context, UPPER_NATIVE, LOWER_NATIVE, {
      lower = { maxOverdraw = ZERO_CROP },
    })
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    local upper = geometry.placements[UPPER_NATIVE.id]
    local lower = geometry.placements[LOWER_NATIVE.id]
    if upper == nil or lower == nil then
      return martPlan(manifest, {}, geometry.frames or {})
    end
    return martPlan(manifest, {
      { id = UPPER_NATIVE.id, placement = upper, interactive = false },
      { id = LOWER_NATIVE.id, placement = lower, interactive = true },
    }, geometry.frames or {})
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function tall(context, view)
    local geometry = ApplicationLayout.stacked(context, UPPER_NATIVE, LOWER_NATIVE, {
      lower = { maxOverdraw = ZERO_CROP },
    })
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    local upper = geometry.placements[UPPER_NATIVE.id]
    local lower = geometry.placements[LOWER_NATIVE.id]
    if upper == nil or lower == nil then
      return martPlan(manifest, {}, geometry.frames or {})
    end
    return martPlan(manifest, {
      { id = UPPER_NATIVE.id, placement = upper, interactive = false },
      { id = LOWER_NATIVE.id, placement = lower, interactive = true },
    }, geometry.frames or {})
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function dualDisplay(context, view)
    local _ = view
    local geometry = ApplicationLayout.nativeDual(context, UPPER_NATIVE, LOWER_NATIVE, {
      lower = { maxOverdraw = ZERO_CROP },
    })
    local upper = geometry.placements[UPPER_NATIVE.id]
    local lower = geometry.placements[LOWER_NATIVE.id]
    if upper == nil or lower == nil then
      return martPlan(manifest, {}, geometry.frames or {})
    end
    return martPlan(manifest, {
      { id = UPPER_NATIVE.id, placement = upper, interactive = false },
      { id = LOWER_NATIVE.id, placement = lower, interactive = true },
    }, geometry.frames or {})
  end

  set.dualDisplay = dualDisplay
  set.nativeLike = nativeLike
  set.wide = wide
  set.tall = tall
  return set
end

return MartInterface
