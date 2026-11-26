-- Neutral pre-movie loading or one real import/quiescence operation.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local LauncherLayout = require("app.src.launcher.LauncherLayout")

local LauncherLoadingPresentation = {}
LauncherLoadingPresentation.__index = LauncherLoadingPresentation

local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

local function renderLoading(_, view, plan)
  LogicalSurface.draw(love.graphics, assert(plan.panes[1].placement), function()
    view.paintedReceiptToken = view.renderer:drawLoading(view, assert(plan.content.layout))
  end)
end

local function resolveLoading(context, view)
  local usable = assert(context.primary and context.primary.usableBounds, "loading needs its safe surface")
  local surface = LauncherLayout.surface(usable, context.measurement.pixelRatio)
  local options = {
    selectionInterrupt = view.selectionInterrupt,
    gameLabel = view.gameLabel,
    receipt = view.receipt,
    canCancel = view.canCancel,
    error = view.error,
    fonts = view.renderer.fonts,
  }
  return {
    panes = { { id = "content", placement = surface.placement, interactive = true } },
    frames = {},
    content = {
      layout = LauncherLayout.loading(surface.logicalViewport.width, surface.logicalViewport.height, options),
    },
    inputKey = view.selectionInterrupt and "launcher-opening" or "launcher-operation",
    render = renderLoading,
    mapInput = view.mapInput,
  }
end

local function defaults()
  return { dualDisplay = resolveLoading, nativeLike = resolveLoading, wide = resolveLoading, tall = resolveLoading }
end

function LauncherLoadingPresentation.new(options)
  assert(type(options) == "table" and options.renderer, "loading requires its borrowed renderer")
  assert(type(options.label) == "string" and options.label ~= "", "loading requires a game label")
  assert(type(options.onCancel) == "function", "loading requires its cancellation route")
  assert(
    type(options.width) == "number" and options.width > 0 and type(options.height) == "number" and options.height > 0
  )
  local width, height = options.width, options.height
  local safeRect = copyRect(options.safeRect or { x = 0, y = 0, width = width, height = height })
  local ratio = options.pixelRatio or 1
  local self = setmetatable({
    renderer = options.renderer,
    onCancel = options.onCancel,
    versionId = options.versionId,
    label = options.label,
    gameLabel = options.gameLabel or options.versionId or "Game",
    selectionInterrupt = options.selectionInterrupt == true,
    receipt = options.receipt,
    attemptId = options.attemptId,
    canCancel = options.canCancel == true,
    width = width,
    height = height,
    safeRect = safeRect,
    pixelRatio = ratio,
    elapsed = 0,
    disposed = false,
    cancelled = false,
    _gestures = {},
    _geometry = 0,
    _displayContext = options.displayContext or DisplayContext.new({
      graphics = {
        getDimensions = function()
          return width, height
        end,
        getDPIScale = function()
          return ratio
        end,
      },
      topologyProvider = function()
        return {
          surfaces = {
            {
              id = "main",
              role = "world",
              rect = { x = 0, y = 0, width = width, height = height },
              safeRect = safeRect,
              touch = true,
            },
          },
        }
      end,
    }),
    _session = ApplicationPresentation.new(defaults()),
  }, LauncherLoadingPresentation)
  self._mapInput = function(event, view, plan)
    return self:_mapEvent(event, view, plan)
  end
  self:_resolve()
  return self
end

function LauncherLoadingPresentation:_resolve(status)
  local view = {
    gameLabel = self.gameLabel,
    label = status and status.label or self.label,
    receipt = status and status.receipt or self.receipt,
    attemptId = self.attemptId,
    error = status and status.error or nil,
    detail = status and status.detail or nil,
    selectionInterrupt = self.selectionInterrupt,
    canCancel = self.canCancel,
    elapsed = self.elapsed,
    renderer = self.renderer,
    mapInput = self._mapInput,
  }
  return view, self._session:resolve(self._displayContext:measure(self.width, self.height), view)
end

function LauncherLoadingPresentation:update(dt)
  if not self.disposed then
    self.elapsed = self.elapsed + dt
  end
end

function LauncherLoadingPresentation:draw(status)
  if self.disposed then
    return
  end
  local view, plan = self:_resolve(status)
  ApplicationPresentation.draw(love.graphics, { renderer = self.renderer }, view, plan)
  self.paintedReceiptToken = view.paintedReceiptToken
end

function LauncherLoadingPresentation:paintedReceipt()
  return self.paintedReceiptToken
end

function LauncherLoadingPresentation:_cancel()
  if self.disposed or self.cancelled or self.selectionInterrupt or not self.canCancel then
    return
  end
  self.cancelled = true
  self.onCancel()
end

function LauncherLoadingPresentation:_mapEvent(event, _, plan)
  local pointerId = assert(type(event.pointerId) == "string")
  if event.type == "pointer_cancel" or event.outside or self.selectionInterrupt then
    self._gestures[pointerId] = nil
    return event
  end
  if event.type == "pointer_down" then
    local targetId = LauncherLayout.hitTestLoading(plan.content.layout, event.x, event.y)
    self._gestures[pointerId] = targetId ~= nil and { targetId = targetId, geometry = self._geometry } or nil
  elseif event.type == "pointer_move" then
    local gesture = self._gestures[pointerId]
    if gesture ~= nil and LauncherLayout.hitTestLoading(plan.content.layout, event.x, event.y) ~= gesture.targetId then
      gesture.armed = false
    end
  elseif event.type == "pointer_up" then
    local gesture = self._gestures[pointerId]
    self._gestures[pointerId] = nil
    if
      gesture ~= nil
      and gesture.armed ~= false
      and gesture.geometry == self._geometry
      and LauncherLayout.hitTestLoading(plan.content.layout, event.x, event.y) == gesture.targetId
    then
      event.activate = gesture.targetId
    end
  end
  return event
end

function LauncherLoadingPresentation:_dispatch(events)
  if self.disposed or self.selectionInterrupt then
    return
  end
  local view, _ = self:_resolve()
  for _, event in ipairs(self._session:mapInput(events, view)) do
    if event.activate == "cancel" then
      self:_cancel()
    end
  end
end

function LauncherLoadingPresentation:keypressed(key, _, isrepeat)
  if not isrepeat and (key == "escape" or key == "backspace") then
    self:_cancel()
  end
end

function LauncherLoadingPresentation:gamepadpressed(_, button)
  if button == "b" then
    self:_cancel()
  end
end

function LauncherLoadingPresentation:mousepressed(x, y, button, istouch)
  if button == 1 and not istouch then
    self:_dispatch({ { type = "pointer_down", pointerId = "mouse:1", x = x, y = y } })
  end
end

function LauncherLoadingPresentation:mousemoved(x, y, _, _, istouch)
  if not istouch then
    self:_dispatch({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  end
end

function LauncherLoadingPresentation:mousereleased(x, y, button, istouch)
  if button == 1 and not istouch then
    self:_dispatch({ { type = "pointer_up", pointerId = "mouse:1", x = x, y = y } })
  end
end

function LauncherLoadingPresentation:touchpressed(id, x, y)
  self:_dispatch({ { type = "pointer_down", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end

function LauncherLoadingPresentation:touchmoved(id, x, y)
  self:_dispatch({ { type = "pointer_move", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end

function LauncherLoadingPresentation:touchreleased(id, x, y)
  self:_dispatch({ { type = "pointer_up", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end

function LauncherLoadingPresentation:focus(focused)
  if not focused then
    self._gestures = {}
    self._session:cancelPointers()
  end
end

function LauncherLoadingPresentation:resize(width, height, safeRect, pixelRatio)
  assert(width > 0 and height > 0, "loading dimensions must be positive")
  self.width, self.height = width, height
  self.safeRect = copyRect(safeRect or { x = 0, y = 0, width = width, height = height })
  self.pixelRatio = pixelRatio or self.pixelRatio
  self._geometry = self._geometry + 1
  self._gestures = {}
  self._session:cancelPointers()
  local ratio = self.pixelRatio
  self._displayContext = DisplayContext.new({
    graphics = {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return ratio
      end,
    },
    topologyProvider = function()
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = width, height = height },
            safeRect = self.safeRect,
            touch = true,
          },
        },
      }
    end,
  })
  self:_resolve()
end

function LauncherLoadingPresentation:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self._gestures = {}
  self._session:dispose()
  self._session = nil
  self.renderer, self.onCancel = nil, nil
end

return LauncherLoadingPresentation
