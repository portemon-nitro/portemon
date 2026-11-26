-- Source/quiescence gates with one neutral, transferable loading surface.

local LauncherLoadingPresentation = require("app.src.launcher.LauncherLoadingPresentation")

local CachePreparationState = {}
CachePreparationState.__index = CachePreparationState

local function copyDetail(detail)
  if type(detail) ~= "table" then
    return detail
  end
  local copy = {}
  for key, value in pairs(detail) do
    copy[key] = value
  end
  if type(detail.context) == "table" then
    local context = {}
    for key, value in pairs(detail.context) do
      context[key] = value
    end
    copy.context = context
  end
  return copy
end

local function failureText(detail)
  if type(detail) == "table" then
    return detail.message or detail.code or "Game preparation failed"
  end
  return detail ~= nil and tostring(detail) or "Game preparation failed"
end

function CachePreparationState.new(options)
  assert(type(options) == "table", "cache preparation requires its composition")
  assert(options.kind == "quiescence" or options.kind == "boot-source", "cache preparation kind is required")
  assert(type(options.epoch) == "number" and options.epoch % 1 == 0 and options.epoch >= 0)
  assert(
    type(options.service) == "table" and type(options.isCurrent) == "function" and type(options.onReady) == "function"
  )
  assert(type(options.onCancel) == "function", "cache preparation requires its cancellation route")
  if options.kind == "quiescence" then
    assert(type(options.barrier) == "number" and options.barrier % 1 == 0 and options.barrier >= 1)
    assert(options.loading == nil, "quiescence owns no transferable boot presentation")
  else
    assert(type(options.versionId) == "string" and options.versionId ~= "")
    assert(type(options.onFailure) == "function", "boot-source preparation requires its failure route")
  end
  local width = options.width or love.graphics.getDimensions()
  local height = options.height or love.graphics.getHeight()
  local loading = options.loading
  if loading == nil then
    assert(options.renderer ~= nil, "neutral cache preparation requires its borrowed renderer")
    loading = LauncherLoadingPresentation.new({
      renderer = options.renderer,
      versionId = options.versionId,
      gameLabel = options.pendingImportLabel or options.versionId or "Game",
      label = options.kind == "quiescence" and "Preparing import" or options.label or options.versionId or "Game",
      width = width,
      height = height,
      safeRect = options.safeRect,
      pixelRatio = options.pixelRatio,
      displayContext = options.displayContext,
      selectionInterrupt = options.kind == "boot-source",
      receipt = options.pendingImportName,
      attemptId = options.importAttemptId,
      canCancel = options.kind == "quiescence",
      onCancel = options.onCancel,
    })
  end
  return setmetatable({
    kind = options.kind,
    epoch = options.epoch,
    service = options.service,
    barrier = options.barrier,
    pendingImportName = options.pendingImportName,
    pendingImportLabel = options.pendingImportLabel,
    versionId = options.versionId,
    isCurrent = options.isCurrent,
    onReady = options.onReady,
    onCancel = options.onCancel,
    onFailure = options.onFailure,
    loading = loading,
    importViewProvider = options.importViewProvider,
    sourceStatus = nil,
    sourceDetail = nil,
    error = nil,
    fired = false,
    terminal = false,
    transferred = false,
    released = false,
    dead = false,
    _receiptPainted = nil,
    safeRect = options.safeRect,
    pixelRatio = options.pixelRatio,
  }, CachePreparationState)
end

function CachePreparationState:_fire()
  if self.fired or self.dead or self.terminal then
    return
  end
  self.fired = true
  self.onReady()
end

function CachePreparationState:_fail(detail)
  if self.terminal or self.dead then
    return
  end
  self.terminal = true
  self.sourceDetail = copyDetail(detail)
  if type(self.onFailure) == "function" then
    self.onFailure(self.sourceDetail)
  else
    self.error = failureText(detail)
  end
end

-- The boot wait, import preparation and cache clearing are genuinely blocking
-- preparations: while this state is still polling, the selected epoch may
-- compile at loader throughput.
---@return boolean
function CachePreparationState:isPreparingAssets()
  return not self.dead and not self.fired and self.error == nil
end

function CachePreparationState:isAwaitingOpening()
  return not self.dead
    and not self.terminal
    and not self.fired
    and self.kind == "boot-source"
    and self.isCurrent(self.epoch)
end

function CachePreparationState:update(dt)
  if self.fired or self.dead or self.terminal then
    return
  end
  local live = self.isCurrent(self.epoch)
  if not live then
    self.dead = true
    return
  end
  if self.loading ~= nil then
    self.loading:update(dt)
  end
  if self.kind == "boot-source" then
    local status, detail = self.service:bootSourceStatus(self.epoch)
    if status == "ready" then
      self.sourceStatus = "ready"
      self:_fire()
    elseif status == "source-required" or status == "failed" then
      self.sourceStatus = status
      self:_fail(detail)
    elseif status ~= "pending" and status ~= nil then
      error("unknown source readiness state: " .. tostring(status), 0)
    end
  else
    local ok, status = pcall(self.service.barrierStatus, self.service, self.epoch, assert(self.barrier))
    if not ok then
      error(status, 0)
    elseif status == "ready" then
      self:_fire()
    elseif status == "failed" or status == nil then
      self:_fail("cache source closure failed")
    end
  end
end

function CachePreparationState:draw()
  if self.dead then
    return
  end
  self._receiptPainted = nil
  if self.kind == "boot-source" then
    self.loading:draw(self.error ~= nil and { label = "Preparation failed", error = self.error } or nil)
  else
    self.loading:draw({
      label = "Waiting for source readers to drain…",
      receipt = self.pendingImportName,
      error = self.error,
    })
    local receipt = self.loading.paintedReceipt
    self._receiptPainted = receipt ~= nil and receipt(self.loading) or nil
  end
end

function CachePreparationState:view()
  if self.kind ~= "quiescence" or self.importViewProvider == nil then
    error("cache preparation publishes a view only for its borrowed import attempt", 2)
  end
  local import = assert(self.importViewProvider(), "quiescence borrows the current import view")
  return { mode = import.mode, import = import }
end

function CachePreparationState:paintedReceipt()
  return self._receiptPainted
end

function CachePreparationState:takeLoading()
  assert(self.kind == "boot-source" and self.fired and not self.transferred and not self.terminal)
  self.transferred = true
  local loading = assert(self.loading)
  self.loading = nil
  return loading
end

function CachePreparationState:resize(width, height, safeRect, pixelRatio)
  if self.loading ~= nil then
    self.loading:resize(width, height, safeRect, pixelRatio)
  end
end

function CachePreparationState:_observeLoadingCancel()
  if self.loading ~= nil and self.loading.cancelled == true then
    self.dead = true
  end
end

function CachePreparationState:keypressed(key)
  if self.dead or self.kind == "boot-source" then
    return
  end
  if self.loading ~= nil and type(self.loading.keypressed) == "function" then
    self.loading:keypressed(key)
    self:_observeLoadingCancel()
  elseif key == "escape" then
    self:dispose()
    self.onCancel()
  end
end

function CachePreparationState:gamepadpressed(_, button)
  if
    not self.dead
    and self.kind == "quiescence"
    and self.loading ~= nil
    and type(self.loading.gamepadpressed) == "function"
  then
    self.loading:gamepadpressed(nil, button)
    self:_observeLoadingCancel()
  elseif not self.dead and button == "b" then
    self:dispose()
    self.onCancel()
  end
end

function CachePreparationState:mousepressed(x, y, button, istouch)
  if not self.dead and self.loading ~= nil and type(self.loading.mousepressed) == "function" then
    self.loading:mousepressed(x, y, button, istouch)
    self:_observeLoadingCancel()
  end
end

function CachePreparationState:mousemoved(x, y, dx, dy, istouch)
  if not self.dead and self.loading ~= nil and type(self.loading.mousemoved) == "function" then
    self.loading:mousemoved(x, y, dx, dy, istouch)
  end
end

function CachePreparationState:mousereleased(x, y, button, istouch)
  if not self.dead and self.loading ~= nil and type(self.loading.mousereleased) == "function" then
    self.loading:mousereleased(x, y, button, istouch)
    self:_observeLoadingCancel()
  end
end

function CachePreparationState:touchpressed(id, x, y)
  if not self.dead and self.loading ~= nil and type(self.loading.touchpressed) == "function" then
    self.loading:touchpressed(id, x, y)
    self:_observeLoadingCancel()
  end
end

function CachePreparationState:touchmoved(id, x, y)
  if not self.dead and self.loading ~= nil and type(self.loading.touchmoved) == "function" then
    self.loading:touchmoved(id, x, y)
  end
end

function CachePreparationState:touchreleased(id, x, y)
  if not self.dead and self.loading ~= nil and type(self.loading.touchreleased) == "function" then
    self.loading:touchreleased(id, x, y)
    self:_observeLoadingCancel()
  end
end

function CachePreparationState:focus(focused)
  if not focused and not self.dead and self.loading ~= nil and type(self.loading.focus) == "function" then
    self.loading:focus(false)
  end
end

function CachePreparationState:filedropped(_) end

function CachePreparationState:dispose()
  self.dead = true
  self._receiptPainted = nil
  if not self.transferred and not self.released then
    self.released = true
    local loading = self.loading
    self.loading = nil
    if loading ~= nil then
      loading:dispose()
    end
  end
end

return CachePreparationState
