-- Neutral pre-movie loading adapter borrowing the process launcher renderer.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LauncherLayout = require("app.src.launcher.LauncherLayout")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

local LauncherLoadingPresentation = {}
LauncherLoadingPresentation.__index = LauncherLoadingPresentation

local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

local function colorBackground(graphics, viewport)
  graphics.setColor(0.984, 0.984, 0.984, 1)
  graphics.rectangle("fill", viewport.x, viewport.y, viewport.width, viewport.height)
end

local function paintLoading(renderer, view, layout)
  local graphics = love.graphics
  colorBackground(graphics, layout.viewport)
  LogicalSurface.clip(graphics, layout.content, function()
    local content = layout.content
    local titleY = content.y + math.max(0, math.floor((content.height - 96) / 2))
    local font = renderer.fonts.bold
    graphics.setFont(font)
    graphics.setColor(0.157, 0.157, 0.157, 1)
    graphics.print(view.gameLabel, content.x + (content.width - font:getWidth(view.gameLabel)) / 2, titleY)
    graphics.setFont(renderer.fonts.body)
    font = graphics.getFont()
    graphics.print(view.label, content.x + (content.width - font:getWidth(view.label)) / 2, titleY + 24)
    renderer:drawLoadingSquares(content.x + (content.width - 50) / 2, titleY + 54, view.elapsed)
    if view.receipt ~= nil then
      graphics.print(view.receipt, content.x + (content.width - font:getWidth(view.receipt)) / 2, titleY + 78)
    end
    if view.error ~= nil then
      graphics.printf(tostring(view.error), content.x + 8, titleY + 96, math.max(1, content.width - 16), "center")
    end
  end)
  renderer:drawButton(layout.cancelRect, "Cancel", "back", { focused = true })
end

local function renderLoading(resources, view, plan)
  local renderer = assert(resources.renderer, "neutral loading borrows its renderer")
  LogicalSurface.draw(love.graphics, assert(plan.panes[1].placement), function()
    paintLoading(renderer, view, assert(plan.content.layout))
  end)
end

local function resolveLoading(context, view)
  local usable = assert(context.primary and context.primary.usableBounds, "neutral loading needs its safe surface")
  return {
    panes = {
      {
        id = "content",
        placement = {
          frame = usable,
          origin = { x = usable.x, y = usable.y },
          scale = 1,
          logicalWidth = usable.width,
          logicalHeight = usable.height,
          clipRect = usable,
        },
        interactive = true,
      },
    },
    frames = {},
    content = { layout = LauncherLayout.loading(usable.width, usable.height) },
    inputKey = "launcher-loading",
    render = renderLoading,
    mapInput = view.mapInput,
  }
end

local function defaults()
  return {
    dualDisplay = resolveLoading,
    nativeLike = resolveLoading,
    wide = resolveLoading,
    tall = resolveLoading,
  }
end

local function displayContext(width, height, safeRect)
  return DisplayContext.new({
    graphics = {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return 1
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
  })
end

function LauncherLoadingPresentation.new(options)
  assert(type(options) == "table" and options.renderer, "neutral loading requires its borrowed renderer")
  assert(type(options.label) == "string" and options.label ~= "", "neutral loading requires a game label")
  assert(type(options.onCancel) == "function", "neutral loading requires its cancellation route")
  assert(type(options.width) == "number" and options.width > 0, "neutral loading requires its host width")
  assert(type(options.height) == "number" and options.height > 0, "neutral loading requires its host height")
  assert(
    type(options.renderer.drawButton) == "function" and type(options.renderer.drawLoadingSquares) == "function",
    "neutral loading requires the shared launcher painter"
  )
  local safeRect = copyRect(options.safeRect or { x = 0, y = 0, width = options.width, height = options.height })
  local self = setmetatable({
    renderer = options.renderer,
    onCancel = options.onCancel,
    versionId = options.versionId,
    label = options.label,
    width = options.width,
    height = options.height,
    safeRect = safeRect,
    elapsed = 0,
    disposed = false,
    cancelled = false,
    _gestures = {},
    _displayContext = displayContext(options.width, options.height, safeRect),
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
    gameLabel = self.label,
    label = status and status.label or "Starting game",
    receipt = status and status.receipt or nil,
    error = status and status.error or nil,
    elapsed = self.elapsed,
    action = "cancel",
    renderer = self.renderer,
    mapInput = self._mapInput,
  }
  local plan = self._session:resolve(self._displayContext:measure(self.width, self.height), view)
  return view, plan
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
end

function LauncherLoadingPresentation:_cancel()
  if self.disposed or self.cancelled then
    return
  end
  self.cancelled = true
  self.onCancel()
end

function LauncherLoadingPresentation:_mapEvent(event, _, plan)
  local hit = LauncherLayout.hitTestLoading(plan.content.layout, event.x, event.y)
  local pointerId = event.pointerId
  if event.type == "pointer_down" then
    self._gestures[pointerId] = { kind = hit.kind }
  elseif event.type == "pointer_up" then
    local gesture = self._gestures[pointerId]
    self._gestures[pointerId] = nil
    if gesture ~= nil and gesture.kind == "cancel" and hit.kind == "cancel" then
      event.activate = hit
    end
  elseif event.type == "pointer_cancel" then
    self._gestures[pointerId] = nil
  end
  return event
end

function LauncherLoadingPresentation:_dispatch(events)
  if self.disposed then
    return
  end
  local view, _ = self:_resolve()
  for _, event in ipairs(self._session:mapInput(events, view)) do
    if event.activate ~= nil and event.activate.kind == "cancel" then
      self:_cancel()
    end
  end
end

function LauncherLoadingPresentation:keypressed(key, _, isrepeat)
  if self.disposed or isrepeat then
    return
  end
  if key == "escape" or key == "backspace" or key == "return" or key == "kpenter" or key == "space" then
    self:_cancel()
  end
end

function LauncherLoadingPresentation:gamepadpressed(_, button)
  if not self.disposed and (button == "a" or button == "b") then
    self:_cancel()
  end
end

function LauncherLoadingPresentation:mousepressed(x, y, button, istouch)
  if not self.disposed and button == 1 and not istouch then
    self:_dispatch({ { type = "pointer_down", pointerId = "mouse:1", x = x, y = y } })
  end
end

function LauncherLoadingPresentation:mousemoved(x, y, _, _, istouch)
  if not self.disposed and not istouch then
    self:_dispatch({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  end
end

function LauncherLoadingPresentation:mousereleased(x, y, button, istouch)
  if not self.disposed and button == 1 and not istouch then
    self:_dispatch({ { type = "pointer_up", pointerId = "mouse:1", x = x, y = y } })
  end
end

function LauncherLoadingPresentation:touchpressed(id, x, y)
  if not self.disposed then
    self:_dispatch({ { type = "pointer_down", pointerId = "touch:" .. tostring(id), x = x, y = y } })
  end
end

function LauncherLoadingPresentation:touchmoved(id, x, y)
  if not self.disposed then
    self:_dispatch({ { type = "pointer_move", pointerId = "touch:" .. tostring(id), x = x, y = y } })
  end
end

function LauncherLoadingPresentation:touchreleased(id, x, y)
  if not self.disposed then
    self:_dispatch({ { type = "pointer_up", pointerId = "touch:" .. tostring(id), x = x, y = y } })
  end
end

function LauncherLoadingPresentation:focus(focused)
  if not focused and not self.disposed then
    self._gestures = {}
    self._session:cancelPointers()
  end
end

function LauncherLoadingPresentation:resize(width, height, safeRect)
  assert(width > 0 and height > 0, "neutral loading dimensions must be positive")
  self.width, self.height = width, height
  self.safeRect = copyRect(safeRect or { x = 0, y = 0, width = width, height = height })
  self._gestures = {}
  self._session:cancelPointers()
  self._displayContext = displayContext(width, height, self.safeRect)
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
  self.renderer = nil
  self.onCancel = nil
end

return LauncherLoadingPresentation
