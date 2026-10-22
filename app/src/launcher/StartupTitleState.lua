-- Holds the selected edition's loader/title while the existing Main Menu is staged.

local CacheFs = require("libs.storage.src.CacheFs")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")

---@class StartupTitleLoading
---@field artFailure unknown?
---@field adoptGeneratedAssets fun(self: StartupTitleLoading, cacheFs: table<string, unknown>): boolean, unknown?
---@field update fun(self: StartupTitleLoading, dt: number)
---@field draw fun(self: StartupTitleLoading, status: table<string, unknown>?)
---@field resize fun(self: StartupTitleLoading, width: number, height: number)
---@field dispose fun(self: StartupTitleLoading)

---@class StartupTitleState
---@field versionId string
---@field epoch integer
---@field derivedAssets table<string, function>?
---@field stageMenu fun(): table<string, unknown>
---@field onFinished fun(menu: table<string, unknown>)
---@field onSwitchEdition fun(versionId: string)
---@field onCancel fun()?
---@field isCurrent fun(epoch: integer): boolean
---@field onTitleReady fun()?
---@field audio table<string, function>?
---@field initialImport boolean
---@field phase string
---@field loading StartupTitleLoading?
---@field title HgssTitleScene?
---@field stagedMenu table<string, unknown>?
---@field skipRequested boolean
---@field menuError unknown?
---@field titleError unknown?
---@field bootstrapError unknown?
---@field requested boolean
---@field loaderObserved boolean
---@field titleObserved boolean
---@field titleReadyNotified boolean
---@field bootstrapObserved boolean
---@field audioObserved boolean
---@field audioReady boolean
---@field audioError unknown?
---@field audioStarted boolean
---@field menuAttempted boolean
---@field accumulator number
---@field fadeFrame integer
---@field pointerCapture string?
---@field canceledPointers table<string, boolean>
---@field transferred boolean
---@field disposed boolean
---@field width number
---@field height number
local StartupTitleState = {}
StartupTitleState.__index = StartupTitleState

local FRAME_SECONDS = 1 / 30
local FADE_OUT_FRAMES = 60
local FADE_IN_FRAMES = 18
local EDITIONS = { heartgold = "soulsilver", soulsilver = "heartgold" }

---@class StartupTitleState.Options
---@field versionId string
---@field epoch integer
---@field derivedAssets table<string, function> selected epoch host
---@field stageMenu fun(): table<string, unknown> constructs the actual product menu
---@field onFinished fun(menu: table<string, unknown>) transfers the staged menu
---@field onSwitchEdition fun(versionId: string) routes through App's selection owner
---@field onCancel fun()? returns to the edition selector
---@field isCurrent fun(epoch: integer): boolean
---@field onTitleReady (fun())?
---@field audio table<string, function>? borrowed App-owned callbacks
---@field initialImport boolean?
---@field width number
---@field height number

---@param options StartupTitleState.Options
---@return StartupTitleState
function StartupTitleState.new(options)
  assert(type(options) == "table", "startup title requires composition options")
  assert(EDITIONS[options.versionId] ~= nil, "startup title requires a supported edition")
  assert(type(options.epoch) == "number" and options.epoch % 1 == 0, "startup title requires its selected epoch")
  assert(type(options.derivedAssets) == "table", "startup title requires the selected derived host")
  assert(type(options.stageMenu) == "function", "startup title requires menu staging")
  assert(type(options.onFinished) == "function", "startup title requires the menu transfer")
  assert(type(options.onSwitchEdition) == "function", "startup title requires edition routing")
  assert(type(options.isCurrent) == "function", "startup title requires an epoch guard")
  assert(type(options.width) == "number" and type(options.height) == "number")
  local self = setmetatable({
    versionId = options.versionId,
    epoch = options.epoch,
    derivedAssets = options.derivedAssets,
    stageMenu = options.stageMenu,
    onFinished = options.onFinished,
    onSwitchEdition = options.onSwitchEdition,
    onCancel = options.onCancel,
    isCurrent = options.isCurrent,
    onTitleReady = options.onTitleReady,
    audio = options.audio,
    initialImport = options.initialImport == true,
    phase = "loading",
    loading = HgssLoadingPresentation.new({
      versionId = options.versionId,
      width = options.width,
      height = options.height,
    }),
    title = nil,
    stagedMenu = nil,
    skipRequested = false,
    menuError = nil,
    titleError = nil,
    bootstrapError = nil,
    requested = false,
    loaderObserved = false,
    titleObserved = false,
    titleReadyNotified = false,
    bootstrapObserved = false,
    audioObserved = false,
    audioReady = false,
    audioError = nil,
    audioStarted = false,
    menuAttempted = false,
    accumulator = 0,
    fadeFrame = 0,
    pointerCapture = nil,
    canceledPointers = {},
    transferred = false,
    disposed = false,
    width = options.width,
    height = options.height,
  }, StartupTitleState)
  return self
end

function StartupTitleState:_live()
  return not self.disposed and self.isCurrent(self.epoch)
end

function StartupTitleState:_request(name, urgency)
  local ok, ready, failure = pcall(self.derivedAssets.requestMilestone, name, urgency or "required")
  if not ok then
    return false, ready
  end
  if failure ~= nil then
    return false, failure
  end
  return ready == true, nil
end

function StartupTitleState:_startRequests()
  if self.requested then
    return
  end
  self.requested = true
  -- Request order preserves title priority ahead of broad menu/gameplay work.
  -- Optional audio is an independent near demand: it never gates the visuals.
  for _, name in ipairs({ "startup-loader", "startup-title", "bootstrap" }) do
    local ready, failure = self:_request(name)
    if name == "startup-loader" and ready then
      self:_adoptLoader()
    elseif name == "startup-title" and ready then
      self:_adoptTitle()
    elseif name == "bootstrap" and ready then
      self.bootstrapObserved = true
    elseif failure ~= nil then
      if name == "startup-title" then
        self.titleError = failure
        self.phase = "error"
      elseif name == "bootstrap" then
        self.bootstrapError = failure
      end
    end
  end
  local audioReady, audioFailure = self:_request("startup-audio", "near")
  if audioReady then
    self.audioObserved = true
    self.audioReady = true
  elseif audioFailure ~= nil then
    self.audioObserved = true
    self.audioError = audioFailure
  end
  self:_notifyTitleReady()
  self:_maybeStartAudio()
end

function StartupTitleState:_adoptLoader()
  if self.loaderObserved or not self:_live() then
    return
  end
  self.loaderObserved = true
  local ok, cacheFs = pcall(CacheFs.forVersion, self.versionId)
  if not ok then
    self.loading.artFailure = cacheFs
    return
  end
  local adopted, failure = self.loading:adoptGeneratedAssets(cacheFs)
  if not adopted then
    self.loading.artFailure = failure
  end
end

function StartupTitleState:_adoptTitle()
  if self.titleObserved or not self:_live() then
    return
  end
  self.titleObserved = true
  local ok, result = pcall(function()
    return HgssTitleScene.new({
      versionId = self.versionId,
      cacheFs = CacheFs.forVersion(self.versionId),
      width = self.width,
      height = self.height,
    })
  end)
  if not ok then
    self.titleError = result
    self.phase = "error"
    return
  end
  self.title = assert(result)
  self.phase = "title"
  self:_maybeStartAudio()
end

function StartupTitleState:_notifyTitleReady()
  if self.title == nil or self.titleReadyNotified or not self:_live() then
    return
  end
  self.titleReadyNotified = true
  if self.onTitleReady ~= nil then
    self.onTitleReady()
  end
end

-- Starts the optional title theme exactly once, and only while the title
-- is still visible and unskipped. Audio that arrives after the skip or
-- during the fade stays silent; the menu stages cues lazily instead.
function StartupTitleState:_maybeStartAudio()
  if self.audioStarted or not self.audioReady or not self:_live() then
    return
  end
  if self.phase ~= "title" or self.skipRequested or self.title == nil then
    return
  end
  if self.audio == nil or type(self.audio.titleReady) ~= "function" then
    return
  end
  self.audioStarted = true
  self.audio.titleReady({ crySpeciesId = self.title.bundle.crySpeciesId })
end

function StartupTitleState:_stageMenu()
  if self.menuAttempted or self.stagedMenu ~= nil or not self.bootstrapObserved or not self:_live() then
    return
  end
  self.menuAttempted = true
  local ok, menu = pcall(self.stageMenu)
  if not ok then
    self.menuError = menu
    return
  end
  assert(type(menu) == "table" and type(menu.draw) == "function" and type(menu.dispose) == "function")
  self.stagedMenu = menu
  self.menuError = nil
end

function StartupTitleState:_pollAssets()
  if not self.requested or not self:_live() then
    return
  end
  if not self.loaderObserved then
    local ready, failure = self:_request("startup-loader")
    if failure ~= nil then
      self.loading.artFailure = failure
      self.loaderObserved = true
    elseif ready then
      self:_adoptLoader()
    end
  end
  if not self.titleObserved then
    local ready, failure = self:_request("startup-title")
    if failure ~= nil then
      self.titleError = failure
      self.phase = "error"
      self.titleObserved = true
    elseif ready then
      self:_adoptTitle()
    end
  end
  if not self.bootstrapObserved then
    local ready, failure = self:_request("bootstrap")
    if failure ~= nil then
      self.bootstrapError = failure
    elseif ready then
      self.bootstrapObserved = true
    end
  end
  if not self.audioObserved then
    local ready, failure = self:_request("startup-audio", "near")
    if failure ~= nil then
      self.audioObserved = true
      self.audioError = failure
    elseif ready then
      self.audioObserved = true
      self.audioReady = true
    end
  end
  if self.bootstrapObserved then
    self:_stageMenu()
  end
  self:_notifyTitleReady()
  self:_maybeStartAudio()
end

function StartupTitleState:_beginFade()
  if self.phase == "title" and self.skipRequested and self.stagedMenu ~= nil then
    self.phase = "fadeOut"
    self.fadeFrame = 0
    if self.audio and type(self.audio.skip) == "function" then
      self.audio.skip()
    end
  end
end

-- Ownership order only: detach before callback, never restore once the
-- callback starts. The App transfer installs the menu exactly once; a
-- post-install optional failure is recorded there and never rolls back
-- into this disposed owner.
function StartupTitleState:_finish()
  if self.transferred or not self:_live() then
    return
  end
  local menu = self:takeStagedMenu()
  self.transferred = true
  self.phase = "transferred"
  self.onFinished(menu)
end

function StartupTitleState:_tick()
  if self.title ~= nil then
    self.title:updateFixed()
  end
  if self.phase == "title" then
    self:_beginFade()
  elseif self.phase == "fadeOut" then
    self.fadeFrame = self.fadeFrame + 1
    if self.fadeFrame >= FADE_OUT_FRAMES then
      self.phase = "fadeIn"
      self.fadeFrame = 0
    end
  elseif self.phase == "fadeIn" then
    self.fadeFrame = self.fadeFrame + 1
    if self.fadeFrame >= FADE_IN_FRAMES then
      self:_finish()
    end
  end
end

function StartupTitleState:update(dt)
  if not self:_live() then
    self:dispose()
    return
  end
  assert(type(dt) == "number" and dt >= 0, "startup title delta must be non-negative")
  self:_startRequests()
  self:_pollAssets()
  if self.phase == "loading" or self.phase == "error" then
    self.loading:update(dt)
  end
  self.accumulator = self.accumulator + dt
  while self.accumulator >= FRAME_SECONDS and not self.disposed do
    self.accumulator = self.accumulator - FRAME_SECONDS
    self:_tick()
  end
end

function StartupTitleState:_status()
  if self.titleError ~= nil or self.phase == "error" then
    local detail = self.titleError or self.menuError or self.bootstrapError
    return {
      label = "Title unavailable",
      error = tostring(detail),
      detail = "Press Esc to return",
    }
  end
  local detail = self.menuError or self.bootstrapError
  if detail ~= nil then
    return {
      label = "Menu unavailable",
      error = tostring(detail),
      detail = "Press R to retry",
    }
  end
  return nil
end

function StartupTitleState:draw()
  if self.disposed then
    return
  end
  if self.title ~= nil and self.phase ~= "loading" and self.phase ~= "error" then
    local graphics = love.graphics
    graphics.push("all")
    local ok, failure = pcall(self.title.draw, self.title, {
      preparingMenu = self.skipRequested and self.stagedMenu == nil,
      menuError = self.menuError or self.bootstrapError,
    })
    graphics.pop()
    if not ok then
      self.titleError = tostring(failure)
      self.phase = "error"
      self.loading:draw({ label = "Title unavailable", error = self.titleError })
    end
  else
    self.loading:draw(self:_status())
  end
  local graphics = love.graphics
  if self.phase == "fadeOut" then
    graphics.setColor(1, 1, 1, self.fadeFrame / FADE_OUT_FRAMES)
    graphics.rectangle("fill", 0, 0, self.width, self.height)
  elseif self.phase == "fadeIn" then
    if self.stagedMenu ~= nil then
      self.stagedMenu:draw()
    end
    graphics.setColor(1, 1, 1, 1 - self.fadeFrame / FADE_IN_FRAMES)
    graphics.rectangle("fill", 0, 0, self.width, self.height)
  end
  graphics.setColor(1, 1, 1, 1)
end

function StartupTitleState:resize(width, height)
  assert(width > 0 and height > 0, "startup title dimensions must be positive")
  self.width, self.height = width, height
  self.loading:resize(width, height)
  if self.title ~= nil then
    self.title:resize(width, height)
  end
  if self.stagedMenu ~= nil and type(self.stagedMenu.resize) == "function" then
    self.stagedMenu:resize(width, height)
  end
  self.pointerCapture = nil
  self.canceledPointers = {}
end

function StartupTitleState:_switchBounds()
  if self.title ~= nil and type(self.title.editionButtonBounds) == "function" then
    return self.title:editionButtonBounds()
  end
  local size, margin = 56, 2
  return {
    x = self.versionId == "heartgold" and self.width - size - margin or margin,
    y = self.height - size - margin,
    width = size,
    height = size,
  }
end

local function contains(rect, x, y)
  return rect ~= nil and x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

function StartupTitleState:_pressPointer(pointerId, x, y)
  if not self:_live() then
    return
  end
  if (self.phase == "title" or self.phase == "error") and self.title ~= nil then
    if contains(self:_switchBounds(), x, y) then
      self.pointerCapture = pointerId
      self.canceledPointers[pointerId] = true
      self.onSwitchEdition(EDITIONS[self.versionId])
      return
    end
    if self.phase == "title" then
      self.pointerCapture = pointerId
      self.canceledPointers[pointerId] = true
      self:_requestSkip()
    end
  end
end

function StartupTitleState:_requestSkip()
  if self.phase ~= "title" or self.title == nil then
    return
  end
  if not self.skipRequested then
    self.skipRequested = true
    if self.audio and type(self.audio.prompt) == "function" then
      self.audio.prompt()
    end
  end
  self:_beginFade()
end

function StartupTitleState:_retryMenu()
  if self.phase ~= "title" then
    return
  end
  if self.bootstrapError ~= nil and not self.bootstrapObserved then
    self.bootstrapError = nil
    local ready, failure = self:_request("bootstrap")
    if failure ~= nil then
      self.bootstrapError = failure
      return
    end
    if ready then
      self.bootstrapObserved = true
    end
  end
  if self.menuError == nil or not self.bootstrapObserved then
    return
  end
  self.menuError = nil
  self.menuAttempted = false
  self:_stageMenu()
  self:_beginFade()
end

-- Modifier-only keys never act: they carry no discrete press intent.
local MODIFIER_KEYS = {
  lshift = true,
  rshift = true,
  lctrl = true,
  rctrl = true,
  lalt = true,
  ralt = true,
  lgui = true,
  rgui = true,
}

-- Releases one normalized pointer identity. Touch and mouse releases use
-- the exact identity their press captured, never a doubly prefixed one.
function StartupTitleState:_releasePointer(pointerId)
  if self.canceledPointers[pointerId] then
    self.canceledPointers[pointerId] = nil
    if self.pointerCapture == pointerId then
      self.pointerCapture = nil
    end
  end
end

function StartupTitleState:keypressed(key, _, isrepeat)
  if isrepeat then
    return
  end
  if key == "escape" then
    self.phase = "cancelled"
    if self.onCancel ~= nil then
      self.onCancel()
    end
  elseif key == "r" then
    if self.menuError ~= nil or self.bootstrapError ~= nil then
      self:_retryMenu()
    else
      self:_requestSkip()
    end
  elseif not MODIFIER_KEYS[key] then
    self:_requestSkip()
  end
end

function StartupTitleState:gamepadpressed(_, _)
  self:_requestSkip()
end

function StartupTitleState:mousepressed(x, y, button)
  if button ~= 1 then
    return
  end
  self:_pressPointer("mouse:" .. tostring(button), x, y)
end

function StartupTitleState:mousereleased(_, _, button)
  self:_releasePointer("mouse:" .. tostring(button))
end

function StartupTitleState:touchpressed(id, x, y)
  self:_pressPointer("touch:" .. tostring(id), x, y)
end

function StartupTitleState:touchreleased(id)
  self:_releasePointer("touch:" .. tostring(id))
end

function StartupTitleState:focus(focused)
  if not focused then
    self.pointerCapture = nil
    self.canceledPointers = {}
  end
end

function StartupTitleState:takeStagedMenu()
  assert(
    self.phase == "fadeIn" and self.fadeFrame >= FADE_IN_FRAMES and not self.transferred,
    "menu can transfer only once after the reveal"
  )
  local menu = assert(self.stagedMenu, "the staged menu was already taken")
  self.stagedMenu = nil
  return menu
end

function StartupTitleState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local menu, title, loading = self.stagedMenu, self.title, self.loading
  self.stagedMenu, self.title, self.loading = nil, nil, nil
  self.derivedAssets = nil
  self.audio = nil
  if menu ~= nil then
    menu:dispose()
  end
  if title ~= nil then
    title:dispose()
  end
  if loading ~= nil then
    loading:dispose()
  end
end

return StartupTitleState
