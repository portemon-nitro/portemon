-- The pure two-pane Easy Chat presentation: native pair placements and
-- the inverse pointer mapping. Information (the sentence strip) is never
-- interactive; controls own every touch. True dual surfaces use
-- fullscreen information on world and controls on auxiliary; wide single
-- displays place information left and controls right; tall and nativeLike
-- stack the pair. Every pane keeps both full native surfaces visible; only
-- the below-1x leaf uses fractional scale. Draw and pointer inverse share
-- the identical plan. Pure geometry: no love, no input capture.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

---@class EasyChatInterface
local EasyChatInterface = {}

EasyChatInterface.INFORMATION_NATIVE = { id = "information", width = 256, height = 192 }
EasyChatInterface.CONTROLS_NATIVE = { id = "controls", width = 256, height = 192 }

-- The finite modal input key behind the per-open session: active only
-- while the committed bundle admits input.
EasyChatInterface.INPUT_KEY = "easy-chat"
EasyChatInterface.INACTIVE_INPUT_KEY = "easy-chat-inactive"

---@param inputKey string
---@return table<string, unknown> a valid inactive plan: no panes, dismissal still deliverable
local function inactivePlan(inputKey)
  return {
    panes = {},
    frames = {},
    content = {},
    inputKey = inputKey,
    render = EasyChatInterface.render,
    mapInput = EasyChatInterface.mapInput,
  }
end

---@param geometry table<string, unknown>
---@param inputKey string
---@return table<string, unknown>
local function pairPlan(geometry, inputKey)
  local information = assert(geometry.placements[EasyChatInterface.INFORMATION_NATIVE.id], "a pair places information")
  local controls = assert(geometry.placements[EasyChatInterface.CONTROLS_NATIVE.id], "a pair places controls")
  return {
    panes = {
      { id = EasyChatInterface.INFORMATION_NATIVE.id, placement = information, interactive = false },
      { id = EasyChatInterface.CONTROLS_NATIVE.id, placement = controls, interactive = true },
    },
    frames = geometry.frames or {},
    content = {},
    inputKey = inputKey,
    render = EasyChatInterface.render,
    mapInput = EasyChatInterface.mapInput,
  }
end

---@param context table<string, unknown>
---@param horizontal boolean
---@param inputKey string
---@return table<string, unknown>
local function fractionalPair(context, horizontal, inputKey)
  local primary = assert(context.primary, "fractional pair resolution requires its primary surface")
  local usable = ApplicationLayout.usableBounds(primary.surface)
  if usable == nil then
    return inactivePlan(inputKey)
  end
  local envelopeWidth = horizontal and 512 or 256
  local envelopeHeight = horizontal and 192 or 384
  local scale = math.min(usable.width / envelopeWidth, usable.height / envelopeHeight)
  assert(scale > 0, "fractional pair resolution requires drawable space")
  local originX = usable.x + (usable.width - envelopeWidth * scale) / 2
  local originY = usable.y + (usable.height - envelopeHeight * scale) / 2
  local function placement(rect)
    return {
      frame = {
        x = originX + rect.x * scale,
        y = originY + rect.y * scale,
        width = rect.width * scale,
        height = rect.height * scale,
      },
      origin = { x = originX + rect.x * scale, y = originY + rect.y * scale },
      scale = scale,
      logicalWidth = rect.width,
      logicalHeight = rect.height,
    }
  end
  local infoRect = { x = 0, y = 0, width = 256, height = 192 }
  local controlsRect
  if horizontal then
    controlsRect = { x = 256, y = 0, width = 256, height = 192 }
  else
    controlsRect = { x = 0, y = 192, width = 256, height = 192 }
  end
  return {
    panes = {
      { id = EasyChatInterface.INFORMATION_NATIVE.id, placement = placement(infoRect), interactive = false },
      { id = EasyChatInterface.CONTROLS_NATIVE.id, placement = placement(controlsRect), interactive = true },
    },
    frames = {},
    content = {},
    inputKey = inputKey,
    render = EasyChatInterface.render,
    mapInput = EasyChatInterface.mapInput,
  }
end

---@param view table<string, unknown> committed screen status
---@return string input key
local function inputKeyFor(view)
  if view.preparing == true then
    return EasyChatInterface.INACTIVE_INPUT_KEY
  end
  return EasyChatInterface.INPUT_KEY
end

---@param context table<string, unknown>
---@param view table<string, unknown>
---@return table<string, unknown>
function EasyChatInterface.dualDisplay(context, view)
  local inputKey = inputKeyFor(view)
  local geometry =
    ApplicationLayout.nativeDual(context, EasyChatInterface.INFORMATION_NATIVE, EasyChatInterface.CONTROLS_NATIVE, {})
  if
    geometry == nil
    or geometry.placements == nil
    or geometry.placements[EasyChatInterface.INFORMATION_NATIVE.id] == nil
  then
    return inactivePlan(inputKey)
  end
  return pairPlan(geometry, inputKey)
end

---@param context table<string, unknown>
---@param view table<string, unknown>
---@return table<string, unknown>
function EasyChatInterface.wide(context, view)
  local inputKey = inputKeyFor(view)
  local geometry =
    ApplicationLayout.sideBySide(context, EasyChatInterface.INFORMATION_NATIVE, EasyChatInterface.CONTROLS_NATIVE, {})
  if
    geometry == nil
    or geometry.placements == nil
    or geometry.placements[EasyChatInterface.INFORMATION_NATIVE.id] == nil
  then
    return fractionalPair(context, true, inputKey)
  end
  return pairPlan(geometry, inputKey)
end

---@param context table<string, unknown>
---@param view table<string, unknown>
---@return table<string, unknown>
function EasyChatInterface.tall(context, view)
  local inputKey = inputKeyFor(view)
  local geometry =
    ApplicationLayout.stacked(context, EasyChatInterface.INFORMATION_NATIVE, EasyChatInterface.CONTROLS_NATIVE, {})
  if
    geometry == nil
    or geometry.placements == nil
    or geometry.placements[EasyChatInterface.INFORMATION_NATIVE.id] == nil
  then
    return fractionalPair(context, false, inputKey)
  end
  return pairPlan(geometry, inputKey)
end

---@param context table<string, unknown>
---@param view table<string, unknown>
---@return table<string, unknown>
function EasyChatInterface.nativeLike(context, view)
  return EasyChatInterface.tall(context, view)
end

---@return table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>>
function EasyChatInterface.defaults()
  return {
    dualDisplay = EasyChatInterface.dualDisplay,
    nativeLike = EasyChatInterface.nativeLike,
    wide = EasyChatInterface.wide,
    tall = EasyChatInterface.tall,
  }
end

-- Draws the committed whole bundle through the identical placements the
-- pointer inverse uses. Pending statuses draw black over their native
-- panes; nothing is acquired or updated here.
---@param resources table<string, unknown> host graphics plus prepared images
---@param view table<string, unknown> committed screen status
---@param plan table<string, unknown> published application plan
function EasyChatInterface.render(resources, view, plan)
  local graphics = assert(resources.graphics, "editor rendering requires its host graphics namespace")
  local assets = view.assets
  if assets == nil or assets.renderer == nil then
    for _, pane in ipairs(plan.panes or {}) do
      local LogicalSurface = require("libs.ui.src.LogicalSurface")
      LogicalSurface.draw(graphics, pane.placement, function()
        graphics.setColor(0, 0, 0, 1)
        graphics.rectangle("fill", 0, 0, 256, 192)
        graphics.setColor(1, 1, 1, 1)
      end)
    end
    return
  end
  assets.renderer:drawPair(graphics, view, plan)
end

-- Inverts one pointer event into native editor coordinates. Only the
-- controls pane is interactive; information-pane touches observe without
-- activating. Pointer geometry follows the drawn target exactly.
---@param event table<string, unknown>
---@param _ table<string, unknown> unused committed status
---@param plan table<string, unknown>
---@return table<string, unknown>? logical touch event, or nil when consumed
function EasyChatInterface.mapInput(event, _, plan)
  if event.type == "pointer_down" and event.outside == true then
    return nil
  end
  if type(event.x) ~= "number" or type(event.y) ~= "number" then
    return event
  end
  local panes = plan.panes or {}
  local controls, information = nil, nil
  for _, pane in ipairs(panes) do
    if pane.id == EasyChatInterface.CONTROLS_NATIVE.id then
      controls = pane
    elseif pane.id == EasyChatInterface.INFORMATION_NATIVE.id then
      information = pane
    end
  end
  if controls ~= nil then
    local x, y = LayoutGeometry.hostToLogical(controls.placement, event.x, event.y)
    if x ~= nil and y ~= nil then
      if event.type == "pointer_down" then
        return { type = "touch", phase = "down", x = x, y = y, pane = "controls", pointerId = event.pointerId }
      elseif event.type == "pointer_move" then
        return { type = "touch", phase = "move", x = x, y = y, pane = "controls", pointerId = event.pointerId }
      elseif event.type == "pointer_up" then
        return { type = "touch", phase = "up", x = x, y = y, pane = "controls", pointerId = event.pointerId }
      end
      return event
    end
  end
  if information ~= nil then
    local x, y = LayoutGeometry.hostToLogical(information.placement, event.x, event.y)
    if x ~= nil and y ~= nil then
      if event.type == "pointer_down" then
        return { type = "touch", phase = "down", x = x, y = y, pane = "information", pointerId = event.pointerId }
      elseif event.type == "pointer_move" then
        return { type = "touch", phase = "move", x = x, y = y, pane = "information", pointerId = event.pointerId }
      elseif event.type == "pointer_up" then
        return { type = "touch", phase = "up", x = x, y = y, pane = "information", pointerId = event.pointerId }
      end
      return event
    end
  end
  return nil
end

return EasyChatInterface
