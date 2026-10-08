-- Resolves one measured editor pane and its canonical logical input mapping.

local Layout = require("app.src.saveeditor.SaveEditorLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PixelScale = require("libs.ui.src.PixelScale")

local Interface = {}
local WIDTH, HEIGHT = 256, 192
local MAX_DENSITY = 3

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

local function copyBounds(bounds)
  return { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height }
end

local function containsPoint(bounds, x, y)
  return x >= bounds.x and x < bounds.x + bounds.width and y >= bounds.y and y < bounds.y + bounds.height
end

local function mapInput(event, view, plan)
  if event.outside then
    return { type = event.type, pointerId = event.pointerId }
  end
  if event.type ~= "pointer_down" and event.type ~= "pointer_up" and event.type ~= "pointer_move" then
    return nil
  end
  local content = assert(plan.content)
  local targetId = Layout.hitTest(content.layout, view, event.x, event.y)
  local scrollViewportId = content.layout.scrollOwner
  local scrollViewport
  if scrollViewportId ~= nil then
    scrollViewport = assert(content.layout.viewports[scrollViewportId], "active scroll owner needs a viewport")
    if not containsPoint(scrollViewport.clip, event.x, event.y) then
      scrollViewport = nil
    end
  end
  local locationGrid
  if view.scope.kind == "section" and view.section == "Location" and view.locationNavigation.page == "grid" then
    local grid = content.layout.locationGrid
    if grid ~= nil and containsPoint(grid.clip, event.x, event.y) then
      locationGrid = grid
    end
  end
  if targetId == nil and scrollViewport == nil and locationGrid == nil and event.type ~= "pointer_move" then
    return { type = event.type, pointerId = event.pointerId }
  end
  local mapped = {
    type = event.type,
    pointerId = event.pointerId,
    targetId = targetId,
    x = event.x,
    y = event.y,
    grid = locationGrid,
    scopeId = view.scope.id,
    scopeEpoch = view.scope.epoch,
  }
  if scrollViewport ~= nil then
    mapped.scrollViewportId = scrollViewportId
    mapped.scrollOffset = scrollViewport.offset
    mapped.scrollContentExtent = scrollViewport.contentExtent
    mapped.scrollViewportExtent = scrollViewport.clip.height
  end
  return mapped
end

function Interface.resolve(context, view)
  local surface = chooseSurface(context)
  if surface == nil then
    return {
      panes = {},
      frames = {},
      hostBackgrounds = {},
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
  local physicalWidth, physicalHeight = bounds.width * pixelRatio, bounds.height * pixelRatio
  local metrics = assert(view.textMetrics, "save editor layout requires borrowed font metrics")
  local authoredWidth, authoredHeight = WIDTH, HEIGHT
  if context.configuration == "wide" or (physicalWidth >= 800 and physicalHeight >= 600) then
    authoredWidth, authoredHeight = 400, 300
  end
  if context.secondary == nil and (physicalWidth < authoredWidth or physicalHeight < authoredHeight) then
    authoredWidth = Layout.minimumListCanvasWidth(view, metrics, authoredHeight) or authoredWidth
  end
  local logicalWidth, logicalHeight, placement
  if physicalWidth < authoredWidth or physicalHeight < authoredHeight then
    logicalWidth, logicalHeight = authoredWidth, authoredHeight
    placement = LayoutGeometry.centeredFit(bounds, authoredWidth, authoredHeight)
    placement.pixelScale = placement.scale * pixelRatio
    placement.pixelRatio = pixelRatio
    placement.visibleLogicalRect = { x = 0, y = 0, width = authoredWidth, height = authoredHeight }
  else
    local density = math.max(
      1,
      math.min(MAX_DENSITY, math.floor(math.min(physicalWidth / authoredWidth, physicalHeight / authoredHeight)))
    )
    local covered = PixelScale.cover(bounds, density, pixelRatio)
    logicalWidth, logicalHeight = covered.logicalViewport.width, covered.logicalViewport.height
    placement = covered.placement
  end
  local layout = Layout.compute(view, logicalWidth, logicalHeight, metrics)
  local pane = { id = "editor", placement = placement, interactive = true }
  local panes = { pane }
  local hostBackgrounds = { copyBounds(bounds) }
  local primary = context.primary
  if context.secondary ~= nil and surface == context.secondary and primary.usableBounds ~= nil then
    local previewPlacement = LayoutGeometry.centeredFit(primary.usableBounds, WIDTH, HEIGHT)
    panes[#panes + 1] = { id = "context", placement = previewPlacement, interactive = false }
    hostBackgrounds[#hostBackgrounds + 1] = copyBounds(primary.usableBounds)
  end
  local identity = table.concat(
    { surface.surface.id, tostring(logicalWidth), tostring(logicalHeight), view.scope.id, tostring(view.scope.epoch) },
    ":"
  )
  return {
    panes = panes,
    frames = {},
    hostBackgrounds = hostBackgrounds,
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
