-- Interactive app-owned game library and import state.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BuildInfo = require("app.src.BuildInfo")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Errors = require("libs.errors.src.Errors")
local FocusGraph = require("libs.ui.src.FocusGraph")
local LauncherLayout = require("app.src.launcher.LauncherLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local PixelScale = require("libs.ui.src.PixelScale")
local RomImporter = require("romdump.src.source.RomImporter")

local GameSelectState = {}
GameSelectState.__index = GameSelectState

---@class GameSelectImportStatus
---@field state string
---@field canCancel boolean?
---@field progress number?
---@field error unknown?
---@field errorCode string?
---@field versionId string?
---@field displayName string?
---@field sourceName string?

local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

local function renderLauncher(_, view, plan)
  view.renderer:draw(view, plan)
end

local function renderDualLauncher(_, view, plan)
  view.renderer:drawDual(view, plan)
end

local function logicalSurface(bounds, ratio)
  local physicalWidth, physicalHeight = bounds.width * ratio, bounds.height * ratio
  local density = (physicalWidth < NativeDisplay.WIDTH or physicalHeight < NativeDisplay.HEIGHT) and 1
    or math.max(1, math.min(3, math.floor(math.min(physicalWidth / 320, physicalHeight / 240))))
  return PixelScale.cover(bounds, density, ratio)
end

local function resolveLauncher(context, view)
  local primary = assert(context.primary)
  local usable = assert(primary.usableBounds)
  local ratio = context.measurement.pixelRatio or 1
  local covered = logicalSurface(usable, ratio)
  local width, height = covered.logicalViewport.width, covered.logicalViewport.height
  local layout = LauncherLayout.compute(view, width, height)
  local backgrounds = { copyRect(usable) }
  if context.secondary and context.secondary.usableBounds then
    backgrounds[#backgrounds + 1] = copyRect(context.secondary.usableBounds)
  end
  return {
    panes = { { id = "content", placement = covered.placement, interactive = true } },
    frames = {},
    content = { layout = layout, width = width, height = height, hostBackgrounds = backgrounds },
    inputKey = "game-select",
    render = renderLauncher,
    mapInput = view.mapInput,
  }
end

local function resolveDualLauncher(context, view)
  local primary = assert(context.primary)
  local secondary = assert(context.secondary)
  local primaryBounds = assert(primary.usableBounds)
  local secondaryBounds = assert(secondary.usableBounds)
  local ratio = context.measurement.pixelRatio or 1
  local primarySurface = logicalSurface(primaryBounds, ratio)
  local secondarySurface = logicalSurface(secondaryBounds, ratio)
  local summaryLayout =
    LauncherLayout.compute(view, primarySurface.logicalViewport.width, primarySurface.logicalViewport.height)
  local layout =
    LauncherLayout.compute(view, secondarySurface.logicalViewport.width, secondarySurface.logicalViewport.height)
  return {
    panes = {
      { id = "summary", placement = primarySurface.placement, interactive = false },
      { id = "content", placement = secondarySurface.placement, interactive = true },
    },
    frames = {},
    content = {
      layout = layout,
      summaryLayout = summaryLayout,
      summaryPaneId = "summary",
      width = secondarySurface.logicalViewport.width,
      height = secondarySurface.logicalViewport.height,
      hostBackgrounds = { copyRect(primaryBounds), copyRect(secondaryBounds) },
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

local function sanitizeName(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local clean = name:gsub("[%c]", "?")
  if #clean > 48 then
    clean = clean:sub(1, 47) .. "…"
  end
  return clean ~= "" and clean or nil
end

local function failureText(failure)
  if Errors.is(failure) then
    return failure.message or failure.code or "Game unavailable"
  end
  return tostring(failure or "Game unavailable")
end

function GameSelectState.new(options)
  assert(type(options) == "table" and type(options.games) == "table", "game selection requires its catalog")
  assert(
    type(options.renderer) == "table" and type(options.audio) == "table",
    "game selection borrows process resources"
  )
  assert(
    type(options.onPlay) == "function" and type(options.onPick) == "function",
    "game selection requires product callbacks"
  )
  assert(
    type(options.onCancelImport) == "function"
      and type(options.onDismissError) == "function"
      and type(options.onQuit) == "function"
  )
  local focusedId = options.initialGameId
  local valid = false
  for _, game in ipairs(options.games) do
    if game.gameId == focusedId then
      valid = true
      break
    end
  end
  if not valid then
    focusedId = options.games[1] and options.games[1].gameId or "add-game"
  end
  local self = setmetatable({
    games = options.games,
    renderer = options.renderer,
    audio = options.audio,
    importer = options.importer,
    failure = options.failure,
    pickerAvailable = options.pickerAvailable == true,
    onPick = options.onPick,
    onPlay = options.onPlay,
    onCancelImport = options.onCancelImport,
    onDismissError = options.onDismissError,
    onQuit = options.onQuit,
    focusedId = focusedId,
    selectedGameId = focusedId ~= "add-game" and focusedId or nil,
    focusNode = focusedId ~= "add-game" and ("game:" .. focusedId) or "add-game",
    scrollOffset = 0,
    _revealFocused = true,
    width = options.width or love.graphics.getDimensions(),
    height = options.height or love.graphics.getHeight(),
    _received = nil,
    _painted = nil,
    _gestures = {},
    _disposed = false,
    _displayContext = options.displayContext or DisplayContext.new({}),
  }, GameSelectState)
  self.height = options.height or select(2, love.graphics.getDimensions())
  self._mapInput = function(event, view, plan)
    return self:_mapEvent(event, view, plan)
  end
  self._session = ApplicationPresentation.new(defaults())
  self:_resolve()
  return self
end

---@return GameSelectImportStatus?
function GameSelectState:_status()
  if self.importer == nil or type(self.importer.status) ~= "function" then
    return nil
  end
  local status = assert(self.importer:status(), "the borrowed importer must expose its status")
  assert(type(status) == "table", "the borrowed importer must return a status record")
  return status --[[@as GameSelectImportStatus]]
end

---@param status GameSelectImportStatus?
---@return boolean
function GameSelectState:_busy(status)
  return status ~= nil
    and (
      status.state == RomImporter.STATES.READING
      or status.state == RomImporter.STATES.VERIFYING
      or status.state == RomImporter.STATES.REGISTERING
      or status.canCancel == true
    )
end

function GameSelectState:_canCancel(status)
  status = status or self:_status()
  return status ~= nil and status.canCancel == true
end

function GameSelectState:_snapshot()
  local status = self:_status()
  local failure = self.failure
  if failure == nil and status ~= nil and status.state == RomImporter.STATES.ERROR then
    failure = status.error
  end
  local statusText = nil
  if self._received ~= nil then
    statusText = "File received " .. self._received
  elseif status ~= nil and self:_busy(status) then
    statusText = status.state == RomImporter.STATES.READING and "Checking ROM" or "Verifying ROM"
  elseif status ~= nil and status.state == RomImporter.STATES.COMPLETE then
    statusText = "Import complete"
  end
  local focusNode = self.focusNode
  if failure ~= nil and focusNode ~= "back" and focusNode ~= "pick" then
    focusNode = "back"
  end
  return {
    kind = "game-select",
    games = self.games,
    focusedId = self.selectedGameId or self.focusedId,
    action = (
      focusNode == "add-game"
      or focusNode == "play"
      or focusNode == "cancel"
      or focusNode == "back"
      or focusNode == "pick"
    )
        and focusNode
      or nil,
    scrollOffset = self.scrollOffset,
    revealFocused = self._revealFocused,
    status = statusText,
    modal = failure ~= nil and { kind = "error" } or nil,
    failure = failure,
    failureText = failure ~= nil and failureText(failure) or nil,
    version = BuildInfo.version,
    renderer = self.renderer,
    mapInput = self._mapInput,
    canCancel = self:_canCancel(status),
    busy = status ~= nil and self:_busy(status) or false,
    progress = status ~= nil and status.progress or nil,
  }
end

function GameSelectState:_resolve()
  local view = self:_snapshot()
  local plan = self._session:resolve(self._displayContext:measure(self.width, self.height), view)
  self.scrollOffset = plan.content.layout.scroll.offset
  self._revealFocused = false
  return view, plan
end

function GameSelectState:view()
  local view, plan = self:_resolve()
  view.layout = plan.content.layout
  view.scroll = { offset = self.scrollOffset }
  view.presentation = plan
  return view
end

function GameSelectState:_nodeForGame(gameId)
  return "game:" .. gameId
end

function GameSelectState:_move(direction)
  self._revealFocused = true
  local view = self:view()
  local graph = view.layout.graph
  self.focusNode = FocusGraph.reconcile(graph.graph, self.focusNode, graph.fallbacks)
  self.focusNode = FocusGraph.move(graph.graph, self.focusNode, direction)
  local target = graph.targets[self.focusNode]
  if target.kind == "game" then
    self.focusedId = target.gameId
    self.selectedGameId = target.gameId
  end
  if target.kind == "game" or view.modal ~= nil or self.focusNode == "cancel" then
    self.audio:play("focus")
  end
end

function GameSelectState:_game(gameId)
  for _, game in ipairs(self.games) do
    if game.gameId == gameId then
      return game
    end
  end
  return nil
end

function GameSelectState:_cancelImport()
  if self:_canCancel() then
    self.audio:play("back")
    self.onCancelImport()
  end
end

function GameSelectState:_activateNode(node, playFocused)
  if self:_snapshot().modal ~= nil then
    if node == "back" then
      self:_dismissError()
    elseif node == "pick" then
      self.audio:play("confirm")
      self.onPick()
    end
    return
  end
  if node == "cancel" then
    self:_cancelImport()
    return
  end
  if node == "add-game" then
    if not self:_busy(self:_status()) and self.pickerAvailable then
      self.audio:play("confirm")
      self.onPick()
    end
  elseif node == "play" then
    local game = self:_game(self.selectedGameId)
    if game ~= nil and game.ready == true then
      self.audio:play("confirm")
      self.onPlay(game.versionId)
    end
  elseif node:sub(1, 5) == "game:" then
    local gameId = node:sub(6)
    local game = self:_game(gameId)
    if game ~= nil then
      self.focusedId, self.selectedGameId, self.focusNode = gameId, gameId, node
      if playFocused and game.ready == true then
        self.audio:play("confirm")
        self.onPlay(game.versionId)
      else
        self.audio:play("focus")
      end
    end
  end
end

function GameSelectState:_dismissError()
  self.audio:play("back")
  self.onDismissError(self.selectedGameId or self.focusedId)
end

function GameSelectState:keypressed(key, _, isrepeat)
  if self._disposed or isrepeat then
    return
  end
  local view = self:view()
  if view.modal ~= nil then
    if key == "escape" or key == "backspace" then
      self:_dismissError()
    elseif key == "return" or key == "kpenter" or key == "space" then
      self.focusNode = assert(view.action, "the modal publishes a focused action")
      self:_activateNode(self.focusNode)
    end
    return
  end
  if key == "up" or key == "down" or key == "left" or key == "right" then
    self:_move(key)
  elseif key == "return" or key == "kpenter" or key == "space" then
    self:_activateNode(self.focusNode, true)
  elseif key == "escape" then
    if self:_canCancel() then
      self:_cancelImport()
    else
      self.audio:play("back")
      self.onQuit()
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
  local hit = LauncherLayout.hitTest(plan.content.layout, view, event.x, event.y)
  local pointerId = event.pointerId
  if event.type == "pointer_down" then
    self._gestures[pointerId] = { hit = hit, x = event.x, y = event.y, dragging = false }
  elseif event.type == "pointer_move" then
    local gesture = self._gestures[pointerId]
    if gesture ~= nil and gesture.hit.kind == "game" and math.abs(event.y - gesture.y) > 6 then
      gesture.dragging = true
      self._revealFocused = false
      self.scrollOffset = math.max(0, self.scrollOffset + (event.y - gesture.y))
      gesture.y = event.y
    end
  elseif event.type == "pointer_up" then
    local gesture = self._gestures[pointerId]
    self._gestures[pointerId] = nil
    if gesture ~= nil and not gesture.dragging then
      local current = LauncherLayout.hitTest(plan.content.layout, view, event.x, event.y)
      if current.kind == gesture.hit.kind and current.gameId == gesture.hit.gameId then
        event.activate = current
      end
    end
  elseif event.type == "pointer_cancel" then
    self._gestures[pointerId] = nil
  end
  event.hit = hit
  return event
end

function GameSelectState:_dispatch(events)
  self:_resolve()
  local view = self:_snapshot()
  local mapped = self._session:mapInput(events, view)
  for _, event in ipairs(mapped) do
    if event.activate ~= nil and not self._disposed then
      local hit = event.activate
      if hit.kind == "game" then
        self:_activateNode(self._nodeForGame(hit.gameId))
      elseif hit.kind == "add-game" or hit.kind == "play" then
        self:_activateNode(hit.kind)
      elseif hit.kind == "cancel" then
        self.focusNode = "cancel"
        self:_activateNode("cancel")
      elseif hit.kind == "back" then
        self.focusNode = "back"
        self:_dismissError()
      elseif hit.kind == "pick" then
        self.focusNode = "pick"
        self:_activateNode("pick")
      end
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

function GameSelectState:wheelmoved(_, y)
  if not self._disposed and (self:view()).modal == nil then
    self._revealFocused = false
    self.scrollOffset = math.max(0, self.scrollOffset + y * 24)
    self.audio:play("focus")
  end
end

function GameSelectState:resize(width, height)
  self.width, self.height = width, height
  self._revealFocused = true
  self._gestures = {}
  self:_resolve()
end

function GameSelectState:focus(focused)
  if not focused then
    self._gestures = {}
    self._session:cancelPointers()
  end
end

function GameSelectState:update() end

function GameSelectState:draw()
  if self._disposed then
    return
  end
  local view, plan = self:_resolve()
  self._painted = nil
  ApplicationPresentation.draw(love.graphics, { renderer = self.renderer }, view, plan)
  if self._received ~= nil and view.status ~= nil then
    self._painted = self._received
  end
end

function GameSelectState:markReceived(displayName)
  local clean = sanitizeName(displayName)
  if clean ~= nil then
    self._received, self._painted = clean, nil
  end
end

function GameSelectState:receivedName()
  return self._received
end

function GameSelectState:paintedReceipt()
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
  self.renderer, self.audio, self.importer = nil, nil, nil
  self.onPick, self.onPlay, self.onCancelImport, self.onDismissError, self.onQuit = nil, nil, nil, nil, nil
end

return GameSelectState
