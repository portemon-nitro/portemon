-- Resolves the Box's native panes through the shared application layout cases.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

local ApricornBoxInterface = {}
local UPPER = { id = "upper", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local LOWER = { id = "lower", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

local function render(resources, view, plan)
  local graphics = assert(resources.graphics, "Box drawing borrows the host graphics")
  local renderer = assert(resources.apricornBoxRenderer, "Box drawing borrows its owned renderer")
  for _, pane in ipairs(plan.panes) do
    LogicalSurface.draw(graphics, pane.placement, function()
      renderer:drawPane(view, pane)
    end)
  end
end

local function mapInput(event, view)
  if event.type == "pointer_down" and event.outside == true then
    return { type = "cancel", source = "touch" }
  end
  if event.type == "pointer_down" then
    local mode = assert(view.mode, "Box input retains its application mode")
    if mode == "kurt_select" and view.phase == "confirm" then
      return event
    end
    if view.phase == "actions" then
      local menu = assert(view.controls.actions[mode == "browse" and "browse" or "kurtSelect"])
      for index = 1, menu.windowCount do
        local left = (menu.x + 1) * 8
        local top = (menu.y + 1) * 8 + 24 * (index - 1)
        if event.x >= left and event.x < left + menu.width * 8 and event.y >= top and event.y < top + 16 then
          return { type = "action_control", index = index }
        end
      end
      return nil
    end
    if mode == "kurt_select" and view.phase == "quantity" then
      for index, bounds in ipairs(assert(view.controls.quantityHitboxes, "Kurt controls use source touch geometry")) do
        if
          event.x >= bounds.x
          and event.x < bounds.x + bounds.width
          and event.y >= bounds.y
          and event.y < bounds.y + bounds.height
        then
          return { type = "quantity_control", index = index }
        end
      end
      return nil
    end
    if view.phase ~= "browse" and view.phase ~= "rows" then
      return nil
    end
    for index, hitbox in ipairs(assert(view.rowHitboxes, "Box input shares source row hitboxes")) do
      local dx = event.x - hitbox.x
      local dy = event.y - hitbox.y
      if dx * dx + dy * dy < hitbox.radius * hitbox.radius then
        return { type = "touch_row", index = index }
      end
    end
    return nil
  end
  if event.type == "pointer_up" or event.type == "pointer_move" or event.type == "pointer_scroll" then
    return nil
  end
  return event
end

local function plan(geometry, placements)
  if geometry == nil then
    return {
      panes = {},
      frames = {},
      content = {},
      inputKey = "apricorn-box-inactive",
      render = render,
      mapInput = mapInput,
    }
  end
  local panes = {}
  for _, pane in ipairs(placements) do
    local placement = geometry.placements[pane]
    if placement ~= nil then
      panes[#panes + 1] = { id = pane, placement = placement, interactive = pane == "lower" }
    end
  end
  return {
    panes = panes,
    frames = geometry.frames or {},
    content = { panes = panes },
    inputKey = "apricorn-box",
    render = render,
    mapInput = mapInput,
  }
end

---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function ApricornBoxInterface.defaults()
  local function nativeLike(context, _)
    return plan(ApplicationLayout.coverOrFrame(context, LOWER, { maxOverdraw = ZERO_CROP }), { "lower" })
  end
  local function dualDisplay(context, _)
    local geometry = ApplicationLayout.nativeDual(context, UPPER, LOWER, { lower = { maxOverdraw = ZERO_CROP } })
    return plan(geometry, { "upper", "lower" })
  end
  local function wide(context, view)
    local geometry = ApplicationLayout.sideBySide(context, UPPER, LOWER)
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    return plan(geometry, { "upper", "lower" })
  end
  local function tall(context, view)
    local geometry = ApplicationLayout.stacked(context, UPPER, LOWER)
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    return plan(geometry, { "upper", "lower" })
  end
  return {
    dualDisplay = dualDisplay,
    nativeLike = nativeLike,
    wide = wide,
    tall = tall,
  }
end

return ApricornBoxInterface
