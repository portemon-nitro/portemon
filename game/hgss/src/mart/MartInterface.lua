-- The mart's four pure pane resolvers pair the source upper and lower
-- displays without changing their logical geometry. The upper source
-- background is transparent above its opaque strip, so the wide/tall
-- pairs clip the upper pane to the manifest visible rect: the envelope,
-- its centering, and its single outer frame all derive from the opaque
-- content while the renderer keeps drawing full-pane coordinates into the
-- clipped surface. NativeLike keeps only the interactive lower pane;
-- input arrives lower-local from the application presentation session.

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
  -- The source mart is modal: touches outside the lower hitboxes do
  -- nothing, and only Cancel returns to the field. Dropping outside
  -- presses keeps upper-pane taps from closing the shop.
  if event.type == "pointer_down" and event.outside == true then
    return nil
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

---@param value unknown
---@param what string
---@return table<string, number>
local function checkVisibleRect(value, what)
  assert(type(value) == "table", what .. " must be a record")
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    assert(
      type(value[axis]) == "number" and value[axis] == math.floor(value[axis]),
      what .. "." .. axis .. " must be an integer"
    )
  end
  assert(value.width > 0 and value.height > 0, what .. " must cover opaque pixels")
  assert(
    value.x >= 0
      and value.y >= 0
      and value.x + value.width <= NativeDisplay.WIDTH
      and value.y + value.height <= NativeDisplay.HEIGHT,
    what .. " must stay inside the upper pane"
  )
  return value
end

-- Windows the composed upper placement onto the padded slot: the opaque
-- visible rect sits top-aligned while the renderer paints the padding
-- rows below it with the strip background blue, so the 8px-padded frame
-- content shows no transparent air. The origin shifts back by the visible
-- offset, so full-pane renderer coordinates land on the opaque rows and
-- host hits outside the slot stay outside the application.
---@param placement LayoutGeometry.Placement the composed padded-slot upper placement
---@param visible table<string, number> the manifest opaque rect
---@return table<string, unknown> the clipped placement
local function clipUpperPane(placement, visible)
  assert(type(placement) == "table", "the clipped upper needs its composed placement")
  local scale = assert(placement.scale, "the composed upper placement carries its scale")
  local frame = assert(placement.frame, "the composed upper placement carries its frame")
  local origin = placement.origin or frame
  local clip = placement.clipRect or frame
  assert(frame.height + 1e-9 >= visible.height * scale, "the padded slot fits the opaque visible rect")
  local x1 = math.max(frame.x, clip.x)
  local y1 = math.max(frame.y, clip.y)
  local x2 = math.min(frame.x + frame.width, clip.x + clip.width)
  local y2 = math.min(frame.y + frame.height, clip.y + clip.height)
  assert(x2 > x1 and y2 > y1, "the clipped upper keeps drawable space")
  return {
    frame = { x = x1, y = y1, width = x2 - x1, height = y2 - y1 },
    origin = { x = origin.x - visible.x * scale, y = origin.y - visible.y * scale },
    scale = scale,
    logicalWidth = UPPER_NATIVE.width,
    logicalHeight = UPPER_NATIVE.height,
    clipRect = { x = x1, y = y1, width = x2 - x1, height = y2 - y1 },
    pixelScale = placement.pixelScale,
    pixelRatio = placement.pixelRatio,
    visibleLogicalRect = { x = visible.x, y = visible.y, width = visible.width, height = visible.height },
    crop = { left = 0, right = 0, top = 0, bottom = 0 },
  }
end

---@param manifest table<string, unknown> the validated mart presentation manifest
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function MartInterface.defaults(manifest)
  assert(type(manifest) == "table", "the mart interface requires its validated manifest")
  assert(type(manifest.upper) == "table", "the mart manifest carries upper-pane content")
  assert(type(manifest.lower) == "table", "the mart manifest carries lower-pane content")
  local visible = checkVisibleRect(
    assert(manifest.upper.visibleRect, "the mart manifest carries the upper opaque visible rect"),
    "upper.visibleRect"
  )
  -- The outer application frame tiles on an 8px grid, so the clipped
  -- slot pads up to the next multiple of 8. The opaque band stays
  -- bottom-aligned in the slot (gapless against the lower pane); the
  -- padding is transparent air at the envelope top.
  assert(visible.width % 8 == 0, "upper.visibleRect width must stay 8px-compatible")
  local slotHeight = visible.height + ((8 - visible.height % 8) % 8)
  assert(slotHeight % 1 == 0, "the padded slot stays integral")
  ---@cast slotHeight integer
  local clippedUpper = { id = UPPER_NATIVE.id, width = visible.width, height = slotHeight }

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

  -- Both single-display pair configurations stack the clipped opaque
  -- strip above the lower pane, like the source hardware arrangement.
  -- The side-by-side pairing left the strip floating beside the list.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function stackedPair(context, view)
    local geometry = ApplicationLayout.stacked(context, clippedUpper, LOWER_NATIVE, {
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
      { id = UPPER_NATIVE.id, placement = clipUpperPane(upper, visible), interactive = false },
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
  set.wide = stackedPair
  set.tall = stackedPair
  return set
end

return MartInterface
