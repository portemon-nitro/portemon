-- Resolves one measured editor pane and its canonical logical input mapping.

local Layout = require("app.src.saveeditor.SaveEditorLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PixelScale = require("libs.ui.src.PixelScale")

local Interface = {}
local WIDTH, HEIGHT = 256, 192

local function chooseSurface(context)
  local primary = context.primary
  local secondary = context.secondary
  if secondary and secondary.surface.touch and secondary.usableBounds then
    return secondary
  end
  if primary.usableBounds then
    return primary
  end
  if secondary and secondary.usableBounds then
    return secondary
  end
  return nil
end

local function render(resources, view, plan)
  assert(resources.renderer):draw(view, plan)
end

local function mapInput(event, view, plan)
  if event.outside then
    return { type = event.type, pointerId = event.pointerId }
  end
  if event.type ~= "pointer_down" and event.type ~= "pointer_up" then
    return nil
  end
  local content = assert(plan.content)
  local targetId = Layout.hitTest(content.layout, view, event.x, event.y)
  if targetId == nil then
    return { type = event.type, pointerId = event.pointerId }
  end
  return { type = event.type, pointerId = event.pointerId, targetId = targetId }
end

function Interface.resolve(context, view)
  local surface = chooseSurface(context)
  if surface == nil then
    return {
      panes = {},
      frames = {},
      content = {},
      inputKey = "save-editor-inactive",
      render = function() end,
      mapInput = function()
        return nil
      end,
    }
  end
  local bounds = surface.usableBounds
  local pixelRatio = context.measurement.pixelRatio or 1
  local authoredWidth, authoredHeight = WIDTH, HEIGHT
  if context.configuration == "wide" then
    authoredWidth, authoredHeight = 400, 300
  end
  local scale = PixelScale.fitPreferred(bounds, authoredWidth, authoredHeight, 3)
  local covered = PixelScale.cover(bounds, scale, pixelRatio)
  local logicalWidth = math.max(authoredWidth, covered.logicalViewport.width)
  local logicalHeight = math.max(authoredHeight, covered.logicalViewport.height)
  local placement = LayoutGeometry.centeredFit(bounds, logicalWidth, logicalHeight)
  local layout = Layout.compute(view, logicalWidth, logicalHeight)
  local pane = { id = "editor", placement = placement, interactive = true }
  local panes = { pane }
  local primary = context.primary
  if context.secondary ~= nil and surface == context.secondary and primary.usableBounds ~= nil then
    local previewPlacement = LayoutGeometry.centeredFit(primary.usableBounds, WIDTH, HEIGHT)
    panes[#panes + 1] = { id = "context", placement = previewPlacement, interactive = false }
  end
  local identity = table.concat(
    { surface.surface.id, tostring(logicalWidth), tostring(logicalHeight), view.section or "", view.modal or "" },
    ":"
  )
  return {
    panes = panes,
    frames = {},
    content = { layout = layout, width = logicalWidth, height = logicalHeight, interactiveSurface = surface.surface.id },
    inputKey = identity,
    render = render,
    mapInput = mapInput,
  }
end

Interface.dualDisplay = Interface.resolve
Interface.nativeLike = Interface.resolve
Interface.wide = Interface.resolve
Interface.tall = Interface.resolve

function Interface.defaults()
  return {
    dualDisplay = Interface.resolve,
    nativeLike = Interface.resolve,
    wide = Interface.resolve,
    tall = Interface.resolve,
  }
end

return Interface
