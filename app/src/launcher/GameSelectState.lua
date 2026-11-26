-- Interactive app-owned cartridge selector and targeted import views.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BuildInfo = require("app.src.BuildInfo")
local DisplayContext = require("libs.ui.src.DisplayContext")
local FocusGraph = require("libs.ui.src.FocusGraph")
local LauncherLayout = require("app.src.launcher.LauncherLayout")
local LocalClock = require("game.src.LocalClock")

local GameSelectState = {}
GameSelectState.__index = GameSelectState

local function detectMonthFirst()
  local probeTime = os.time({ year = 2001, month = 12, day = 31, hour = 12 })
  if type(probeTime) ~= "number" then
    return false
  end
  local probe = os.date("%x", probeTime)
  if type(probe) ~= "string" then
    return false
  end
  local monthPos = probe:find("12", 1, true)
  local dayPos = probe:find("31", 1, true)
  if monthPos == nil or dayPos == nil then
    return false
  end
  return monthPos < dayPos
end

local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

local function renderLauncher(_, view, plan)
  local token = view.renderer:draw(view, plan)
  if token ~= nil then
    view.paintedReceiptToken = token
  end
end

local function renderDualLauncher(_, view, plan)
  local token = view.renderer:drawDual(view, plan)
  if token ~= nil then
    view.paintedReceiptToken = token
  end
end

local function resolveLauncher(context, view)
  local usable = assert(context.primary and context.primary.usableBounds, "selection needs its safe surface")
  local surface = LauncherLayout.surface(usable, context.measurement.pixelRatio)
  local layout = LauncherLayout.compute(view, surface.logicalViewport.width, surface.logicalViewport.height)
  return {
    panes = { { id = "content", placement = surface.placement, interactive = true } },
    frames = {},
    content = { layout = layout, width = surface.logicalViewport.width, height = surface.logicalViewport.height },
    inputKey = "game-select",
    render = renderLauncher,
    mapInput = view.mapInput,
  }
end

local function resolveDualLauncher(context, view)
  local primary = assert(context.primary and context.primary.usableBounds)
  local secondary = assert(context.secondary and context.secondary.usableBounds)
  local ratio = context.measurement.pixelRatio
  local statusSurface = LauncherLayout.surface(primary, ratio)
  local contentSurface = LauncherLayout.surface(secondary, ratio)
  local statusLayout =
    LauncherLayout.compute(view, statusSurface.logicalViewport.width, statusSurface.logicalViewport.height)
  local layout =
    LauncherLayout.compute(view, contentSurface.logicalViewport.width, contentSurface.logicalViewport.height)
  return {
    panes = {
      { id = "status", placement = statusSurface.placement, interactive = false },
      { id = "content", placement = contentSurface.placement, interactive = true },
    },
    frames = {},
    content = {
      layout = layout,
      statusLayout = statusLayout,
      statusPaneId = "status",
      width = contentSurface.logicalViewport.width,
      height = contentSurface.logicalViewport.height,
    },
    inputKey = "game-select",
    render = renderDualLauncher,
    mapInput = view.mapInput,
  }
end

local function defaults()
  return {
    dualDisplay = resolveDualLauncher,
    nativeLike = resolveLauncher,
    wide = resolveLauncher,
    tall = resolveLauncher,
  }
end

local function copyImport(view)
  if view == nil then
    return nil
  end
  local copy = {}
  for key, value in pairs(view) do
    copy[key] = value
  end
  if type(view.error) == "table" and type(view.error.context) == "table" then
    local context = {}
    for key, value in pairs(view.error.context) do
      context[key] = value
    end
    copy.error = { code = view.error.code, message = view.error.message, context = context }
  end
  return copy
end

function GameSelectState.new(options)
  assert(type(options) == "table" and type(options.games) == "table", "game selection requires its edition catalog")
  assert(#options.games == 2, "game selection publishes exactly two editions")
  assert(
    type(options.renderer) == "table" and type(options.audio) == "table",
    "game selection borrows process resources"
  )
  assert(
    type(options.onAction) == "function" and type(options.getImportView) == "function",
    "game selection requires semantic product callbacks"
  )
  local games = {}
  for index, game in ipairs(options.games) do
    assert(type(game.versionId) == "string" and game.versionId ~= "" and type(game.label) == "string")
    assert(type(game.installed) == "boolean", "edition installation is a managed source fact")
    games[index] = {
      versionId = game.versionId,
      label = game.label,
      installed = game.installed,
      iconSha1 = game.installed and game.iconSha1 or nil,
    }
  end
  local focusedId = options.initialGameId
  local valid = games[1].versionId == focusedId or games[2].versionId == focusedId
  if not valid then
    focusedId = games[1].installed and games[1].versionId
      or games[2].installed and games[2].versionId
      or games[1].versionId
  end
  local self = setmetatable({
    games = games,
    renderer = options.renderer,
    audio = options.audio,
    onAction = options.onAction,
    getImportView = options.getImportView,
    clock = options.clock or LocalClock.system(),
    focusedId = focusedId,
    focusId = focusedId,
    width = options.width or love.graphics.getDimensions(),
    height = options.height or select(2, love.graphics.getDimensions()),
    safeRect = copyRect(options.safeRect or {
      x = 0,
      y = 0,
      width = options.width or love.graphics.getWidth(),
      height = options.height or love.graphics.getHeight(),
    }),
    pixelRatio = options.pixelRatio or 1,
    monthFirst = options.monthFirst,
    _displayContext = options.displayContext,
    _gestures = {},
    _geometry = 0,
    _painted = nil,
    _minuteKey = nil,
    _dateText = "",
    _timeText = "",
    _disposed = false,
  }, GameSelectState)
  self.height = options.height or select(2, love.graphics.getDimensions())
  self._mapInput = function(event, view, plan)
    return self:_mapEvent(event, view, plan)
  end
  self._session = ApplicationPresentation.new(defaults())
  self:_updateClock()
  self:_resolve()
  return self
end

function GameSelectState:_updateClock()
  local now = self.clock:nowLocal()
  local key = string.format("%04d-%02d-%02d-%02d-%02d", now.year, now.month, now.day, now.hour, now.minute)
  if key == self._minuteKey then
    return
  end
  self._minuteKey = key
  local monthFirst = self.monthFirst
  if monthFirst == nil then
    monthFirst = detectMonthFirst()
  end
  if monthFirst then
    self._dateText = string.format("%02d/%02d", now.month, now.day)
  else
    self._dateText = string.format("%02d/%02d", now.day, now.month)
  end
  self._timeText = string.format("%02d:%02d", now.hour, now.minute)
end

function GameSelectState:_snapshot()
  local games = {}
  for index, game in ipairs(self.games) do
    games[index] = {
      versionId = game.versionId,
      label = game.label,
      installed = game.installed,
      iconSha1 = game.iconSha1,
    }
  end
  local import = copyImport(self.getImportView())
  local mode = import ~= nil and import.mode or "selection"
  return {
    kind = "game-select",
    games = games,
    focusedId = mode == "selection" and self.focusedId
      or (mode == "error" and import and import.expectedVersionId or nil),
    action = mode ~= "selection" and self.focusId or nil,
    mode = mode,
    import = import,
    receipt = import ~= nil and import.receipt or nil,
    version = BuildInfo.version,
    dateText = self._dateText,
    timeText = self._timeText,
    fonts = self.renderer.fonts,
    renderer = self.renderer,
    mapInput = self._mapInput,
  }
end

function GameSelectState:_context()
  if self._displayContext ~= nil then
    return self._displayContext
  end
  local width, height, safeRect, ratio = self.width, self.height, self.safeRect, self.pixelRatio
  return DisplayContext.new({
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
  })
end

function GameSelectState:_resolve()
  local view = self:_snapshot()
  local plan = self._session:resolve(self:_context():measure(self.width, self.height), view)
  view.layout = plan.content.layout
  view.presentation = plan
  return view, plan
end

function GameSelectState:view()
  local view = self:_resolve()
  return view
end

function GameSelectState:_reconcile(view)
  local graph = view.layout.graph
  if next(graph.targets) == nil then
    self.focusId = nil
    return
  end
  local fallback = view.mode == "selection" and self.focusedId or nil
  self.focusId = FocusGraph.reconcile(graph.graph, self.focusId, graph.fallbacks)
  if view.mode == "selection" and graph.targets[self.focusId] ~= nil then
    self.focusedId = self.focusId
  elseif fallback ~= nil and graph.targets[fallback] ~= nil then
    self.focusId = fallback
  end
end

function GameSelectState:_move(direction)
  local view = self:view()
  self:_reconcile(view)
  if self.focusId == nil then
    return
  end
  local nextId = FocusGraph.move(view.layout.graph.graph, self.focusId, direction)
  if nextId ~= self.focusId then
    self.focusId = nextId
    if view.mode == "selection" then
      self.focusedId = nextId
    end
    self.audio:play("focus")
  end
end

function GameSelectState:_activate(targetId)
  local view = self:view()
  local target = view.layout.graph.targets[targetId]
  if target == nil then
    return
  end
  self.focusId = targetId
  if view.mode == "selection" then
    self.focusedId = targetId
  end
  if targetId == "back" or targetId == "cancel" then
    self.audio:play("back")
  else
    self.audio:play("confirm")
  end
  self.onAction(targetId)
end

function GameSelectState:keypressed(key, _, isrepeat)
  if self._disposed or isrepeat then
    return
  end
  local view = self:view()
  self:_reconcile(view)
  if key == "up" or key == "down" or key == "left" or key == "right" then
    self:_move(key)
  elseif key == "return" or key == "kpenter" or key == "space" then
    if self.focusId ~= nil then
      self:_activate(self.focusId)
    end
  elseif key == "escape" or key == "backspace" then
    if view.mode == "selection" then
      self.audio:play("back")
      self.onAction("quit")
    else
      local targetId = view.layout.graph.targets.cancel ~= nil and "cancel" or "back"
      self:_activate(targetId)
    end
  end
end

function GameSelectState:gamepadpressed(_, button)
  if self._disposed then
    return
  end
  local directions = { dpup = "up", dpdown = "down", dpleft = "left", dpright = "right" }
  if directions[button] then
    self:_move(directions[button])
  elseif button == "a" then
    self:keypressed("return", "", false)
  elseif button == "b" then
    self:keypressed("escape", "", false)
  end
end

function GameSelectState:_mapEvent(event, view, plan)
  local pointerId = assert(type(event.pointerId) == "string", "pointer events have stable identities")
  if event.type == "pointer_cancel" or event.outside then
    self._gestures[pointerId] = nil
    return event
  end
  if event.type == "pointer_down" then
    local targetId = LauncherLayout.hitTest(plan.content.layout, view, event.x, event.y)
    self._gestures[pointerId] = targetId ~= nil
        and {
          targetId = targetId,
          mode = view.mode,
          attemptId = view.import and view.import.attemptId,
          geometry = self._geometry,
        }
      or nil
    if targetId ~= nil then
      self.focusId = targetId
      if view.mode == "selection" then
        self.focusedId = targetId
      end
    end
  elseif event.type == "pointer_move" then
    local gesture = self._gestures[pointerId]
    if gesture ~= nil then
      local targetId = LauncherLayout.hitTest(plan.content.layout, view, event.x, event.y)
      if targetId ~= gesture.targetId then
        gesture.armed = false
      end
    end
  elseif event.type == "pointer_up" then
    local gesture = self._gestures[pointerId]
    self._gestures[pointerId] = nil
    local currentImport = view.import
    if
      gesture ~= nil
      and gesture.armed ~= false
      and gesture.geometry == self._geometry
      and gesture.mode == view.mode
      and gesture.attemptId == (currentImport and currentImport.attemptId or nil)
      and LauncherLayout.hitTest(plan.content.layout, view, event.x, event.y) == gesture.targetId
      and view.layout.graph.targets[gesture.targetId] ~= nil
    then
      event.activate = gesture.targetId
    end
  end
  return event
end

function GameSelectState:_dispatch(events)
  if self._disposed then
    return
  end
  local view = self:_resolve()
  self:_reconcile(view)
  for _, event in ipairs(self._session:mapInput(events, view)) do
    if event.activate ~= nil and not self._disposed then
      self:_activate(event.activate)
      -- A mode-changing callback publishes a new graph for the next gesture.
      return
    end
  end
end

function GameSelectState:mousepressed(x, y, button, istouch)
  if not self._disposed and button == 1 and not istouch then
    self:_dispatch({ { type = "pointer_down", pointerId = "mouse:1", x = x, y = y } })
  end
end

function GameSelectState:mousemoved(x, y, _, _, istouch)
  if not self._disposed and not istouch then
    self:_dispatch({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  end
end

function GameSelectState:mousereleased(x, y, button, istouch)
  if not self._disposed and button == 1 and not istouch then
    self:_dispatch({ { type = "pointer_up", pointerId = "mouse:1", x = x, y = y } })
  end
end

function GameSelectState:touchpressed(id, x, y)
  if not self._disposed then
    self:_dispatch({ { type = "pointer_down", pointerId = "touch:" .. tostring(id), x = x, y = y } })
  end
end

function GameSelectState:touchmoved(id, x, y)
  if not self._disposed then
    self:_dispatch({ { type = "pointer_move", pointerId = "touch:" .. tostring(id), x = x, y = y } })
  end
end

function GameSelectState:touchreleased(id, x, y)
  if not self._disposed then
    self:_dispatch({ { type = "pointer_up", pointerId = "touch:" .. tostring(id), x = x, y = y } })
  end
end

function GameSelectState:resize(width, height, safeRect, pixelRatio)
  assert(width > 0 and height > 0, "selection dimensions must be positive")
  self.width, self.height = width, height
  self.safeRect = copyRect(safeRect or { x = 0, y = 0, width = width, height = height })
  self.pixelRatio = pixelRatio or self.pixelRatio
  self._geometry = self._geometry + 1
  self._gestures = {}
  self._session:cancelPointers()
  self:_resolve()
end

function GameSelectState:focus(focused)
  if not focused then
    self._gestures = {}
    self._session:cancelPointers()
  end
end

function GameSelectState:update(_)
  if not self._disposed then
    self:_updateClock()
  end
end

function GameSelectState:draw()
  if self._disposed then
    return
  end
  local view, plan = self:_resolve()
  self:_reconcile(view)
  self._painted = nil
  ApplicationPresentation.draw(love.graphics, { renderer = self.renderer }, view, plan)
  local token = view.paintedReceiptToken
  if view.import ~= nil and token == view.import.attemptId and view.layout.receiptRect ~= nil then
    self._painted = token
  end
end

function GameSelectState:paintedReceipt()
  if self._disposed or self._painted == nil or self.getImportView == nil then
    return nil
  end
  local import = self.getImportView()
  if import == nil or import.attemptId ~= self._painted then
    return nil
  end
  return self._painted
end

function GameSelectState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._gestures = {}
  self._session:dispose()
  self._session = nil
  self.renderer, self.audio, self.onAction, self.getImportView = nil, nil, nil, nil
end

return GameSelectState
