-- ROM-free launcher composition at the App boundary. Only host graphics,
-- audio, picker and save-root placement are replaced; routing and the real
-- SaveFs/GameSaveStore metadata path stay production-owned.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local WindowConfig = require("game.src.WindowConfig")
local FakeCache = require("tests.support.FakeCache")
local PublishedSaveFixture = require("tests.support.PublishedSaveFixture")
local ManagedRomIconFixture = require("tests.support.ManagedRomIconFixture")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local DisplayContext = require("libs.ui.src.DisplayContext")
local RomArchive = require("romdump.src.source.RomArchive")
local GameVersion = require("romdump.src.source.GameVersion")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local RomImporter = require("romdump.src.source.RomImporter")
local CacheArchive = require("romdump.src.build.CacheArchive")
local NativeRomPicker = require("app.src.launcher.NativeRomPicker")

local T = {}

local BOOT_LOGO_PATH = "assets/logo.png"
local BOOT_LOGO_WIDTH, BOOT_LOGO_HEIGHT = 451, 115
local BOOT_LOGO_LOGICAL_WIDTH = 151

local function fakeFont()
  local font = { released = 0 }
  function font:getHeight()
    return 12
  end
  function font:getWidth(text)
    return #tostring(text) * 6
  end
  function font:getWrap(text, limit)
    local words = {}
    for word in tostring(text):gmatch("%S+") do
      words[#words + 1] = word
    end
    return #tostring(text) * 6, { tostring(text) }
  end
  function font:setFilter(minimum, maximum)
    self.filter = { minimum, maximum }
  end
  function font:release()
    self.released = self.released + 1
  end
  return font
end

local function fakeImage(path)
  local logo = path == BOOT_LOGO_PATH
  local image = { released = 0, path = path }
  function image:getWidth()
    return logo and BOOT_LOGO_WIDTH or 32
  end
  function image:getHeight()
    return logo and BOOT_LOGO_HEIGHT or 32
  end
  function image:getDimensions()
    return logo and BOOT_LOGO_WIDTH or 32, logo and BOOT_LOGO_HEIGHT or 32
  end
  function image:setFilter() end
  function image:release()
    self.released = self.released + 1
  end
  return image
end

local function fakeSource(onStop)
  local source = { released = 0, volume = 1, playing = false }
  function source:play()
    self.playing = true
  end
  function source:pause()
    self.playing = false
  end
  function source:stop()
    self.playing = false
    if onStop ~= nil then
      onStop(self)
    end
  end
  function source:isPlaying()
    return self.playing
  end
  function source:getDuration()
    return 0.1
  end
  function source:setVolume(volume)
    self.volume = volume
  end
  function source:getVolume()
    return self.volume
  end
  function source:release()
    self.released = self.released + 1
  end
  return source
end

local function withLauncherHost(options, fn)
  options = options or {}
  love.filesystem.remove("app-edition.lua")
  love.filesystem.remove("app-edition.lua.tmp")
  local backend = options.backend or FakeCache.new()
  local copy = {}
  local pickerOpens = 0
  local pickerPolls = 0
  local pickerResult = options.pickerResult or { kind = "cancel" }
  local pickerPollResult = nil
  local audioSources = {}
  local audioEvents = {}
  local fonts = {}
  local images = {}
  local imageDatas = {}
  local fileData = {}
  local fontRequests = {}
  local printPositions = {}
  local backgroundColors = {}
  local rectangles = {}
  local draws = {}
  local currentColor = { 1, 1, 1, 1 }
  local transform = { x = 0, y = 0, scaleX = 1, scaleY = 1 }
  local transforms = {}
  local transformEnters = 0
  local function hostPoint(x, y)
    return transform.x + x * transform.scaleX, transform.y + y * transform.scaleY
  end
  local quitCodes = {}
  local fullscreenEvents = {}
  local safeAreaReads = 0
  local metadataReads = 0
  local saveLoads = 0
  local managedProbes = 0
  local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
  local originalListMetadata = GameSaveStore.listMetadata
  local originalLoad = GameSaveStore.load
  GameSaveStore.listMetadata = function(self, ...)
    metadataReads = metadataReads + 1
    return originalListMetadata(self, ...)
  end
  GameSaveStore.load = function(self, ...)
    saveLoads = saveLoads + 1
    return originalLoad(self, ...)
  end
  local hostWidth, hostHeight = options.width or 360, options.height or 640
  local hostPixelRatio = options.pixelRatio or 1
  local safeRect = options.safeRect or { x = 0, y = 0, width = hostWidth, height = hostHeight }
  local graphics = love.graphics
  local originalAudio = love.audio
  local audio = originalAudio or {}
  love.audio = audio
  local LauncherAssets = require("app.src.launcher.LauncherAssets")
  local original = {
    dimensions = graphics.getDimensions,
    width = graphics.getWidth,
    dpi = graphics.getDPIScale,
    background = graphics.setBackgroundColor,
    newFont = graphics.newFont,
    newImage = graphics.newImage,
    imageData = love.image.newImageData,
    getFont = graphics.getFont,
    setFont = graphics.setFont,
    print = graphics.print,
    printf = graphics.printf,
    rectangle = graphics.rectangle,
    line = graphics.line,
    polygon = graphics.polygon,
    color = graphics.setColor,
    draw = graphics.draw,
    push = graphics.push,
    pop = graphics.pop,
    origin = graphics.origin,
    translate = graphics.translate,
    scale = graphics.scale,
    transformPoint = graphics.transformPoint,
    color = graphics.setColor,
    lineWidth = graphics.setLineWidth,
    getLineWidth = graphics.getLineWidth,
    scissor = graphics.setScissor,
    intersectScissor = graphics.intersectScissor,
    audioVolume = audio.setVolume,
    newSource = audio.newSource,
    safeArea = love.window.getSafeArea,
    fullscreen = love.window.getFullscreen,
    setFullscreen = love.window.setFullscreen,
    localClockSystem = require("game.src.LocalClock").system,
    assetRead = LauncherAssets.read,
    quit = love.event.quit,
    ready = RomImporter.isReady,
    registered = RomImporter.isRegistered,
    recoverable = CacheArchive.recoverableFileName,
    managed = RomArchive.recoverablePath,
    pickerAvailable = NativeRomPicker.available,
    pickerOpen = NativeRomPicker.openSingle,
    appBackend = ProducerFingerprint.appBackend,
    checkoutBackend = ProducerFingerprint.checkoutBackend,
    selectVersion = App._selectVersion,
    showSelection = App._showGameSelection,
  }
  local SaveFs = require("libs.storage.src.SaveFs")
  local originalGlobal = SaveFs.global
  local currentFont = fakeFont()
  fonts[#fonts + 1] = currentFont
  graphics.getDimensions = function()
    return hostWidth, hostHeight
  end
  graphics.getWidth = function()
    return hostWidth
  end
  graphics.getDPIScale = function()
    return hostPixelRatio
  end
  graphics.setBackgroundColor = function(r, g, b, a)
    backgroundColors[#backgroundColors + 1] = { r, g, b, a }
  end
  graphics.newFont = function(data, size, hinting, dpi)
    local font = fakeFont()
    font.path = data ~= nil and data.path or nil
    fonts[#fonts + 1] = font
    fontRequests[#fontRequests + 1] = {
      path = font.path,
      size = size,
      hinting = hinting,
      dpi = dpi,
      font = font,
    }
    return font
  end
  graphics.newImage = function(imageData)
    if options.failImageAt == #images + 1 then
      error("synthetic launcher image acquisition failure", 0)
    end
    local image = fakeImage(imageData.path)
    images[#images + 1] = image
    return image
  end
  love.image.newImageData = function(data, format, bytes)
    if type(data) == "number" then
      return original.imageData(data, format, bytes)
    end
    local path = data:getFilename()
    local logo = path == BOOT_LOGO_PATH
    local imageData = { path = path, releases = 0 }
    function imageData:getWidth()
      return logo and BOOT_LOGO_WIDTH or 32
    end
    function imageData:getHeight()
      return logo and BOOT_LOGO_HEIGHT or 32
    end
    function imageData:getDimensions()
      return logo and BOOT_LOGO_WIDTH or 32, logo and BOOT_LOGO_HEIGHT or 32
    end
    function imageData:release()
      self.releases = self.releases + 1
    end
    imageDatas[#imageDatas + 1] = imageData
    return imageData
  end
  graphics.getFont = function()
    return currentFont
  end
  graphics.setFont = function(font)
    currentFont = font
  end
  graphics.print = function(text, x, y)
    x, y = hostPoint(x, y)
    copy[#copy + 1] = tostring(text)
    printPositions[#printPositions + 1] = { text = tostring(text), x = x, y = y, scaleX = transform.scaleX }
  end
  graphics.printf = function(text, x, y)
    x, y = hostPoint(x, y)
    copy[#copy + 1] = tostring(text)
    printPositions[#printPositions + 1] = { text = tostring(text), x = x, y = y, scaleX = transform.scaleX }
  end
  graphics.rectangle = function(mode, x, y, width, height)
    x, y = hostPoint(x, y)
    rectangles[#rectangles + 1] = {
      mode = mode,
      x = x,
      y = y,
      width = width * transform.scaleX,
      height = height * transform.scaleY,
      color = { currentColor[1], currentColor[2], currentColor[3], currentColor[4] },
    }
  end
  graphics.draw = function(image, x, y, rotation, scaleX, scaleY)
    x, y = hostPoint(x, y)
    draws[#draws + 1] = {
      image = image,
      path = image.path,
      x = x,
      y = y,
      scaleX = scaleX or 1,
      scaleY = scaleY or 1,
      width = image:getWidth(),
      height = image:getHeight(),
    }
  end
  for _, name in ipairs({ "line", "polygon", "setScissor", "intersectScissor" }) do
    graphics[name] = function() end
  end
  graphics.push = function()
    transforms[#transforms + 1] = {
      x = transform.x,
      y = transform.y,
      scaleX = transform.scaleX,
      scaleY = transform.scaleY,
    }
  end
  graphics.pop = function()
    transform = assert(table.remove(transforms), "unbalanced graphics pop")
  end
  graphics.origin = function()
    transformEnters = transformEnters + 1
    transform.x, transform.y = 0, 0
  end
  graphics.translate = function(x, y)
    transform.x = transform.x + x * transform.scaleX
    transform.y = transform.y + y * transform.scaleY
  end
  graphics.scale = function(x, y)
    transform.scaleX = transform.scaleX * x
    transform.scaleY = transform.scaleY * y
  end
  graphics.transformPoint = function(x, y)
    return hostPoint(x, y)
  end
  graphics.setColor = function(r, g, b, a)
    currentColor = { r, g, b, a or 1 }
  end
  graphics.setLineWidth = function() end
  graphics.getLineWidth = function()
    return 1
  end
  audio.setVolume = function() end
  local sourceAttempts = 0
  audio.newSource = function(data)
    sourceAttempts = sourceAttempts + 1
    if options.failAudioAt == sourceAttempts then
      error("synthetic launcher audio acquisition failure", 0)
    end
    local source
    source = fakeSource(function()
      audioEvents[#audioEvents + 1] = "boot-stop:" .. tostring(source.path)
    end)
    source.path = data:getFilename()
    audioSources[#audioSources + 1] = source
    return source
  end
  if options.audioMissing then
    audio.newSource = nil
  end
  love.window.getSafeArea = function()
    safeAreaReads = safeAreaReads + 1
    return safeRect.x, safeRect.y, safeRect.width, safeRect.height
  end
  love.window.getFullscreen = function()
    return false
  end
  love.window.setFullscreen = function()
    fullscreenEvents[#fullscreenEvents + 1] = true
  end
  local LocalClock = require("game.src.LocalClock")
  LocalClock.system = function()
    return LocalClock.new(function()
      return options.now or { year = 2026, month = 12, day = 31, hour = 23, minute = 59, second = 0 }
    end)
  end
  LauncherAssets.read = function(path)
    if path == options.missingAsset then
      return nil
    end
    if options.syntheticFonts ~= nil and options.syntheticFonts[path] then
      local real = original.assetRead(path)
      if real ~= nil then
        real:release()
      else
        local data = { path = path, releases = 0 }
        function data:getFilename()
          return self.path
        end
        function data:getSize()
          return 0
        end
        function data:getString()
          return ""
        end
        function data:release()
          self.releases = self.releases + 1
        end
        fileData[#fileData + 1] = data
        return data
      end
    end
    local raw = assert(original.assetRead(path), "required launcher fixture asset is missing: " .. path)
    local data = { path = path, releases = 0, raw = raw }
    function data:getFilename()
      return self.path
    end
    function data:getSize()
      return self.raw:getSize()
    end
    function data:getString()
      return self.raw:getString()
    end
    function data:release()
      self.releases = self.releases + 1
      self.raw:release()
    end
    fileData[#fileData + 1] = data
    return data
  end
  love.event.quit = function(code)
    quitCodes[#quitCodes + 1] = code
  end
  RomImporter.isReady = function(versionId)
    return options.ready ~= nil and options.ready[versionId] == true
  end
  RomImporter.isRegistered = function()
    return false
  end
  CacheArchive.recoverableFileName = function()
    return nil
  end
  RomArchive.recoverablePath = function(romSha1)
    managedProbes = managedProbes + 1
    if options.managed == true then
      return original.managed(romSha1)
    end
    return nil
  end
  NativeRomPicker.available = function()
    return options.pickerAvailable ~= false
  end
  NativeRomPicker.openSingle = function()
    pickerOpens = pickerOpens + 1
    return pickerResult
  end
  NativeRomPicker.poll = function()
    pickerPolls = pickerPolls + 1
    local result = pickerPollResult
    pickerPollResult = nil
    return result
  end
  ProducerFingerprint.appBackend = function()
    return {
      list = function()
        return {}
      end,
      read = function()
        error("the launcher fixture has no producer files")
      end,
      getInfo = function(path)
        return path == "romdump/src" and { type = "directory" } or nil
      end,
    }
  end
  ProducerFingerprint.checkoutBackend = ProducerFingerprint.appBackend
  SaveFs.global = function()
    return originalGlobal(backend)
  end
  if options.candidate == true then
    local Store = require("libs.hgss.src.save.GameSaveStore")
    local store = Store.new(originalGlobal(backend))
    local saveId = store:reserve()
    store:publishFirst(PublishedSaveFixture.new(saveId, "heartgold"))
  end
  local result = {
    copy = copy,
    pickerOpens = function()
      return pickerOpens
    end,
    pickerPolls = function()
      return pickerPolls
    end,
    setPickerResult = function(result)
      pickerResult = result
    end,
    setPickerPollResult = function(result)
      pickerPollResult = result
    end,
    audioSources = audioSources,
    audioEvents = audioEvents,
    fonts = fonts,
    images = images,
    imageDatas = imageDatas,
    fileData = fileData,
    fontRequests = fontRequests,
    printPositions = printPositions,
    backgroundColors = backgroundColors,
    rectangles = rectangles,
    draws = draws,
    safeAreaReads = function()
      return safeAreaReads
    end,
    transformEnters = function()
      return transformEnters
    end,
    metadataReads = function()
      return metadataReads
    end,
    saveLoads = function()
      return saveLoads
    end,
    managedProbes = function()
      return managedProbes
    end,
    safeRect = function()
      return safeRect
    end,
    setSafeRect = function(rect)
      safeRect = rect
    end,
    setHostSize = function(width, height)
      hostWidth, hostHeight = width, height
    end,
    setPixelRatio = function(ratio)
      hostPixelRatio = ratio
    end,
    quitCodes = quitCodes,
    fullscreenEvents = fullscreenEvents,
  }
  local ok, err = xpcall(function()
    fn(result)
  end, debug.traceback)
  App.quit()
  App.setState(nil)
  App._retireSelection()
  App._releaseLauncherResources()
  App.service = nil
  App.importer = nil
  App.opts = nil
  love.filesystem.remove("app-edition.lua")
  love.filesystem.remove("app-edition.lua.tmp")
  graphics.getDimensions = original.dimensions
  graphics.getWidth = original.width
  graphics.getDPIScale = original.dpi
  graphics.setBackgroundColor = original.background
  graphics.newFont = original.newFont
  graphics.newImage = original.newImage
  love.image.newImageData = original.imageData
  graphics.getFont = original.getFont
  graphics.setFont = original.setFont
  graphics.print = original.print
  graphics.printf = original.printf
  graphics.rectangle = original.rectangle
  graphics.line = original.line
  graphics.polygon = original.polygon
  graphics.draw = original.draw
  graphics.push = original.push
  graphics.pop = original.pop
  graphics.origin = original.origin
  graphics.translate = original.translate
  graphics.scale = original.scale
  graphics.transformPoint = original.transformPoint
  graphics.setColor = original.color
  graphics.setLineWidth = original.lineWidth
  graphics.getLineWidth = original.getLineWidth
  graphics.setScissor = original.scissor
  graphics.intersectScissor = original.intersectScissor
  audio.setVolume = original.audioVolume
  audio.newSource = original.newSource
  love.window.getSafeArea = original.safeArea
  love.window.getFullscreen = original.fullscreen
  love.window.setFullscreen = original.setFullscreen
  LocalClock.system = original.localClockSystem
  GameSaveStore.listMetadata = originalListMetadata
  GameSaveStore.load = originalLoad
  LauncherAssets.read = original.assetRead
  love.audio = originalAudio
  love.event.quit = original.quit
  RomImporter.isReady = original.ready
  RomImporter.isRegistered = original.registered
  CacheArchive.recoverableFileName = original.recoverable
  RomArchive.recoverablePath = original.managed
  NativeRomPicker.available = original.pickerAvailable
  NativeRomPicker.openSingle = original.pickerOpen
  ProducerFingerprint.appBackend = original.appBackend
  ProducerFingerprint.checkoutBackend = original.checkoutBackend
  App._selectVersion = original.selectVersion
  App._showGameSelection = original.showSelection
  SaveFs.global = originalGlobal
  if not ok then
    error(err, 0)
  end
end

local function drawnText(result, first)
  local copy = {}
  for index = first or 1, #result.copy do
    copy[#copy + 1] = result.copy[index]
  end
  return table.concat(copy, "\n")
end

local function logoDraw(result)
  for _, draw in ipairs(result.draws) do
    if draw.path == BOOT_LOGO_PATH then
      return draw
    end
  end
  return nil
end

local function countByPath(list, path)
  local count = 0
  for _, item in ipairs(list) do
    if item.path == path then
      count = count + 1
    end
  end
  return count
end

local function occurrences(text, needle)
  local count, from = 0, 1
  while true do
    local at = text:find(needle, from, true)
    if at == nil then
      return count
    end
    count = count + 1
    from = at + #needle
  end
end

local function drawnTitleCenter(result, first, title)
  local width = #title * 6
  local center
  for index = first or 1, #result.printPositions do
    local position = result.printPositions[index]
    if position.text == title then
      center = position.x + width * position.scaleX / 2
    end
  end
  return center
end

local function candidateBackend()
  local backend = FakeCache.new()
  local originalGetInfo = backend.getInfo
  function backend:getInfo(path)
    local info = originalGetInfo(self, path)
    if info ~= nil and info.type == "file" and path:match("^saves/games/") then
      info.modtime = 1700000000
    end
    return info
  end
  return backend
end

local function installEdition(rom, versionId, withIcon)
  local edition = rom[versionId]
  local bytes = love.data.newByteData(edition.cart.data)
  local prepared = assert(RomArchive.prepare(edition.cart.info, bytes, edition.cart.versions))
  Assert.isTrue(RomArchive.publish(prepared), "managed source publication failed")
  if withIcon then
    local png = assert(RomArchive.encodeIcon(bytes))
    Assert.isTrue(RomArchive.publishIcon(edition.cart.sha1, png))
    png:release()
  end
  bytes:release()
end

local function withManagedLauncher(options, fn)
  options.managed = true
  ManagedRomIconFixture.with(function(rom)
    for editionId, info in pairs(GameVersion.VERSIONS) do
      if editionId ~= "heartgold" and info.sha1 == rom.heartgold.cart.sha1 then
        GameVersion.VERSIONS[editionId] = nil
      end
    end
    for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
      if options.installed and options.installed[versionId] then
        installEdition(rom, versionId, options.icons ~= false)
      end
    end
    withLauncherHost(options, function(host)
      fn(host, rom)
    end)
  end)
end

local function scriptedService(options)
  options = options or {}
  local record = {
    epochs = {},
    requests = {},
    retired = {},
    sourceRequests = 0,
    quiesceCalls = 0,
    importCalls = 0,
    sweeps = 0,
    barrier = options.barrier,
    barrierStatus = "pending",
    authorizeImport = options.authorizeImport ~= false,
  }
  local service = {}
  local view = {}
  function view:resolveAsset(_)
    return nil
  end
  function view:loadLua(_)
    return nil
  end
  function view:withPackages()
    return self
  end
  function service:select(selectOptions)
    local epoch = #record.epochs + 1
    record.epochs[epoch] = selectOptions.versionId
    view.versionId = selectOptions.versionId
    return epoch
  end
  function service:request(epoch, selector)
    record.requests[#record.requests + 1] = { epoch = epoch, selector = selector }
    return true
  end
  function service:observe(_, selector)
    if selector.requestKind == "opening-scene" then
      return options.scenesReady ~= false, nil
    end
    if selector.requestKind == "milestone" then
      if selector.name == "startup-title" then
        return options.titleReady ~= false, nil
      elseif selector.name == "startup-audio" then
        if options.audioFailure ~= nil then
          return false, options.audioFailure
        end
        return options.audioReady ~= false, nil
      elseif selector.name == "bootstrap" then
        return options.bootstrapReady == true, nil
      end
    end
    return false, nil
  end
  function service:requestBootSource(_)
    record.sourceRequests = record.sourceRequests + 1
    return true
  end
  function service:bootSourceStatus(_)
    if options.sourceStatus ~= nil then
      return options.sourceStatus, options.sourceDetail
    end
    record.sourceChecks = (record.sourceChecks or 0) + 1
    return record.sourceChecks == 1 and "pending" or "ready", nil
  end
  function service:update() end
  function service:retire(epoch)
    record.retired[#record.retired + 1] = epoch
  end
  function service:setExecutionPolicy() end
  function service:generationId(_)
    return "launcher-test-generation"
  end
  function service:getCacheFs(epoch)
    for _, retired in ipairs(record.retired) do
      if retired == epoch then
        return nil
      end
    end
    return view
  end
  function service:cacheIdentity(epoch)
    return {
      schema = "derived-cache",
      versionId = record.epochs[epoch],
      romSha1 = string.rep("0", 40),
      mode = "release",
      producerId = "launcher-test",
      assetRevision = 19,
      scriptApi = 1,
      generationId = "launcher-test-generation",
    }
  end
  function service:firstPlayReady(_)
    return true
  end
  function service:recordFirstPlay(_) end
  function service:enableSweep(_)
    record.sweeps = record.sweeps + 1
  end
  function service:quiesce(_)
    record.quiesceCalls = record.quiesceCalls + 1
    return record.barrier
  end
  function service:barrierStatus(_, _)
    return record.barrierStatus
  end
  function service:importSource(_, _)
    record.importCalls = record.importCalls + 1
    return record.authorizeImport
  end
  function service:offerSource()
    return true
  end
  function service:shutdown() end
  return service, record
end

local function withStartupConsumers(options, fn)
  local Movie = require("libs.hgss.src.presentation.HgssOpeningMovie")
  local Title = require("libs.hgss.src.presentation.HgssTitleScene")
  local StartupAssets = require("libs.assets.src.StartupAssetCache")
  local StartupAudio = require("app.src.audio.StartupAudioSession")
  local MainMenu = require("app.src.mainmenu.MainMenuComposition")
  local HgssGame = require("game.hgss.src.HgssGame")
  local saved = {
    movieNew = Movie.new,
    titleBegin = Title.begin,
    loadScene = StartupAssets.loadOpeningScene,
    audioNew = StartupAudio.new,
    menuNew = MainMenu.new,
    firstPlay = HgssGame.newFirstPlayCachePreparation,
    saveLocation = HgssGame.newSaveLocationPreparation,
  }
  local record = { movieTicks = 0, movieDraws = 0, warmups = 0, saveLocationWarmups = 0, audioEvents = {} }
  Movie.new = function()
    local movie = {}
    function movie:updateFixed()
      record.movieTicks = record.movieTicks + 1
    end
    function movie:draw()
      record.movieDraws = record.movieDraws + 1
    end
    function movie:resize() end
    function movie:skipAllowed()
      return false
    end
    function movie:requestSkip()
      return false
    end
    function movie:isFinished()
      return false
    end
    function movie:sceneNumber()
      return 1
    end
    function movie:dispose() end
    return movie
  end
  StartupAssets.loadOpeningScene = function(_, sceneNumber, versionId)
    return { sceneNumber = sceneNumber, versionId = versionId, generationId = "launcher-test-generation" }
  end
  Title.begin = function()
    local title = { bundle = { crySpeciesId = 25 } }
    function title:updateFixed() end
    function title:update() end
    function title:draw() end
    function title:resize() end
    function title:beginProceed() end
    function title:dispose() end
    local build = { ready = false }
    function build:advance()
      self.ready = true
      return 1
    end
    function build:isReady()
      return self.ready
    end
    function build:takeResult()
      return title
    end
    function build:release()
      title:dispose()
    end
    return build
  end
  StartupAudio.new = function()
    local session = {}
    function session:beginOpening()
      record.audioEvents[#record.audioEvents + 1] = "retail-audio"
      if options.recordRetailAudio then
        options.recordRetailAudio()
      end
      if options.openingAck == false then
        return false, "synthetic opening soundtrack rejection"
      end
      return true
    end
    function session:bindTitleRecord() end
    function session:beginTitle() end
    function session:beginMovieCycle() end
    function session:notifySkip() end
    function session:beginFade() end
    function session:playMenuCue() end
    function session:update() end
    function session:dispose() end
    return session
  end
  MainMenu.new = function()
    local menu = {}
    function menu:update() end
    function menu:draw() end
    function menu:resize() end
    function menu:keypressed() end
    function menu:mousereleased() end
    function menu:dispose() end
    return menu
  end
  HgssGame.newFirstPlayCachePreparation = function()
    return {
      poll = function()
        return false
      end,
      dispose = function() end,
    }
  end
  HgssGame.newSaveLocationPreparation = function()
    record.saveLocationWarmups = record.saveLocationWarmups + 1
    return {
      poll = function()
        return false
      end,
      dispose = function() end,
    }
  end
  local originalWarmup = App._beginSaveAgnosticWarmup
  App._beginSaveAgnosticWarmup = function(...)
    record.warmups = record.warmups + 1
    return originalWarmup(...)
  end
  local ok, failure = xpcall(function()
    fn(record)
  end, debug.traceback)
  App._beginSaveAgnosticWarmup = originalWarmup
  Movie.new = saved.movieNew
  Title.begin = saved.titleBegin
  StartupAssets.loadOpeningScene = saved.loadScene
  StartupAudio.new = saved.audioNew
  MainMenu.new = saved.menuNew
  HgssGame.newFirstPlayCachePreparation = saved.firstPlay
  HgssGame.newSaveLocationPreparation = saved.saveLocation
  if not ok then
    error(failure, 0)
  end
end

local function targetPoint(view, targetId)
  local target = assert(view.layout.graph.targets[targetId], "current graph exposes " .. targetId)
  local placement = assert(view.presentation.panes[1].placement)
  return LayoutGeometry.logicalToHost(
    placement,
    target.rect.x + target.rect.width / 2,
    target.rect.y + target.rect.height / 2
  )
end

local function tap(targetId)
  local x, y = targetPoint(assert(App.state:view()), targetId)
  App.touchpressed("finger", x, y)
  App.touchreleased("finger", x, y)
end

local function trackImporter(rom)
  if App.importer ~= nil then
    local found = false
    for _, importer in ipairs(rom.host.importers) do
      if importer == App.importer then
        found = true
      end
    end
    if not found then
      rom.host.importers[#rom.host.importers + 1] = App.importer
    end
  end
end

local function advanceUntil(predicate, label, rom)
  local deadline = love.timer.getTime() + 20
  while love.timer.getTime() < deadline do
    if rom ~= nil then
      trackImporter(rom)
    end
    App.update(1 / 60)
    if predicate() then
      if rom ~= nil then
        trackImporter(rom)
      end
      return
    end
    love.timer.sleep(0.002)
  end
  error("timed out waiting for " .. label .. "; state=" .. tostring(App.state and App.state.phase))
end

function T.native_display_facts_intersect_once_and_suspend_across_invalid_intervals()
  withManagedLauncher({
    installed = { heartgold = true },
    width = 385,
    height = 287,
    pixelRatio = 3,
    safeRect = { x = 0, y = 0, width = 800, height = 600 },
  }, function(host)
    App.load({ dev = false })
    Assert.deepEqual(
      App._safeRect,
      { x = 0, y = 0, width = 385, height = 287 },
      "load intersects the actual safe query with the drawable"
    )
    Assert.equal(App.drawableWidth, 385)
    Assert.equal(App.drawableHeight, 287)
    Assert.equal(App.pixelRatio, 3)
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    local service, record = scriptedService()
    App.service = service
    local selection = assert(App.state)
    local originalResize = selection.resize
    local resizes = 0
    selection.resize = function(self, ...)
      resizes = resizes + 1
      return originalResize(self, ...)
    end
    host.setSafeRect({ x = -20, y = -10, width = 430, height = 320 })
    App.resize(800, 600)
    Assert.deepEqual(
      App._safeRect,
      { x = 0, y = 0, width = 385, height = 287 },
      "resize event dimensions never replace current host facts"
    )
    Assert.equal(resizes, 1)
    local x, y = targetPoint(selection:view(), "heartgold")
    App.touchpressed("held", x, y)
    host.setHostSize(0, 0)
    App.update(1 / 60)
    Assert.equal(App.drawableWidth, 385, "invalid intervals retain the last valid facts for disposal")
    Assert.equal(App.drawableHeight, 287)
    Assert.equal(resizes, 1, "invalid intervals never publish resize(0, 0)")
    local copyBefore, rectanglesBefore = #host.copy, #host.rectangles
    App.draw()
    Assert.equal(#host.copy, copyBefore, "suspended launcher draws no stale actionable text")
    Assert.equal(#host.rectangles, rectanglesBefore, "suspended launcher draws no stale surfaces")
    host.setHostSize(385, 287)
    App.update(1 / 60)
    Assert.equal(resizes, 2, "same-size restoration forces exactly one geometry publication")
    App.touchmoved("held", x, y)
    App.touchreleased("held", x, y)
    Assert.equal(record.sourceRequests, 0, "the suspended touch tail cannot activate a cartridge")
    host.setPixelRatio(2)
    App.update(1 / 60)
    Assert.equal(resizes, 3, "DPI-only changes republish geometry")
    Assert.equal(selection:view().presentation.panes[1].placement.pixelRatio, 2)
    App._selectVersion("heartgold")
    Assert.deepEqual(App.state.loading.safeRect, App._safeRect, "the ordinary loader borrows the same safe facts")
    Assert.equal(
      App.state.loading._displayContext:measure(385, 287).pixelRatio,
      2,
      "loader measurement uses the published DPI"
    )
  end)
end

function T.semantic_pointer_events_activate_only_the_current_cartridge_once()
  withManagedLauncher({ installed = { heartgold = true } }, function()
    App.load({ dev = false })
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    local service, record = scriptedService()
    App.service = service
    local selection = assert(App.state)
    Assert.equal(#selection:view().games, 2)
    selection:_dispatch({
      { type = "pointer_down", pointerId = "outside", outside = true },
      { type = "pointer_up", pointerId = "outside", x = 0, y = 0 },
      { type = "pointer_cancel", pointerId = "cancel" },
      { type = "pointer_up", pointerId = "cancel", x = 0, y = 0 },
    })
    Assert.equal(record.sourceRequests, 0)
    local x, y = targetPoint(selection:view(), "heartgold")
    App.touchpressed("drag", x, y)
    App.touchmoved("drag", x, y + 100)
    App.touchreleased("drag", x, y + 100)
    Assert.equal(record.sourceRequests, 0, "drag-away and re-entry cannot activate")
    tap("heartgold")
    Assert.equal(record.sourceRequests, 1, "one direct cartridge tap starts one selected epoch")
    Assert.equal(App.selectedVersionId, "heartgold")
  end)
end

function T.boot_paints_before_discovery_and_overlaps_real_opening_preparation()
  withManagedLauncher(
    { installed = { heartgold = true }, ready = { heartgold = true }, candidate = true, backend = candidateBackend() },
    function(host)
      withStartupConsumers({
        recordRetailAudio = function()
          host.audioEvents[#host.audioEvents + 1] = "retail-audio"
        end,
      }, function(startup)
        local service, record = scriptedService()
        App.load({ dev = false })
        App.service = service
        Assert.equal(host.metadataReads(), 0, "load performs no save metadata discovery")
        App.draw()
        local first = drawnText(host)
        Assert.equal(host.metadataReads(), 0, "candidate discovery waits for the first painted update")
        Assert.equal(record.sourceRequests, 0, "candidate discovery and source work wait for the first painted update")
        Assert.isNil(first:find("Portémon", 1, true), "boot no longer prints the replaced wordmark")
        Assert.isNil(first:find("Nitro", 1, true), "boot no longer prints the replaced wordmark")
        local logo = assert(logoDraw(host), "boot paints the supplied logo")
        local expectedScale = BOOT_LOGO_LOGICAL_WIDTH / BOOT_LOGO_WIDTH
        Assert.isTrue(
          math.abs(logo.scaleX - expectedScale) < 1e-9 and math.abs(logo.scaleY - expectedScale) < 1e-9,
          "the logo keeps its measured wordmark width"
        )
        local safe = host.safeRect()
        Assert.isTrue(
          math.abs(logo.x + logo.width * logo.scaleX / 2 - (safe.x + safe.width / 2)) <= 1
            and math.abs(logo.y + logo.height * logo.scaleY / 2 - (safe.y + safe.height / 2)) <= 1,
          "the logo is centered in the usable logical bounds"
        )
        Assert.isTrue(first:find("Press a button for game selection", 1, true) ~= nil)
        Assert.notNil(App._bootIntro)
        Assert.isTrue(App._bootIntro.painted)
        App.update(1 / 60)
        Assert.equal(record.sourceRequests, 1, "the first update starts the real selected source gate")
        Assert.equal(host.metadataReads(), 1, "candidate discovery reads one metadata snapshot")
        Assert.equal(host.saveLoads(), 0, "automatic startup never loads or restores a save")
        Assert.notNil(App._bootIntro, "source preparation remains covered by the same jingle")
        Assert.equal(getmetatable(App.state).__index, require("app.src.launcher.CachePreparationState"))
        advanceUntil(function()
          return getmetatable(App.state).__index == require("app.src.launcher.StartupTitleState")
            and App.state.movie ~= nil
        end, "staged opening behind the jingle")
        Assert.equal(getmetatable(App.state).__index, require("app.src.launcher.StartupTitleState"))
        Assert.notNil(App.state.movie, "the real startup owner stages the opening behind the overlay")
        Assert.equal(startup.movieTicks, 0)
        Assert.equal(startup.movieDraws, 0)
        Assert.deepEqual(startup.audioEvents, {})
        advanceUntil(function()
          return App._bootIntro == nil and App.state.phase == "movie"
        end, "early movie admission")
        Assert.isNil(App._bootIntro, "genuine readiness ends the foreground overlay early")
        Assert.equal(App.state.phase, "movie")
        Assert.equal(startup.warmups, 1, "gameplay warmup starts at actual movie entry")
        Assert.equal(startup.saveLocationWarmups, 1)
        local bootStop, retailAudio
        for index, event in ipairs(host.audioEvents) do
          if event == "boot-stop:assets/audio/launcher/boot.ogg" then
            bootStop = index
          elseif event == "retail-audio" then
            retailAudio = index
          end
        end
        Assert.notNil(bootStop)
        Assert.notNil(retailAudio)
        Assert.isTrue(bootStop < retailAudio, "the boot tail stops before retail soundtrack admission")
      end)
    end
  )

  withManagedLauncher({ installed = {} }, function()
    App.load({ dev = false })
    local intro = assert(App._bootIntro)
    Assert.isFalse(intro.painted, "the jingle clock starts before its first paint")
    App.update(1 / 60)
    Assert.equal(intro.elapsed, 0, "time before the first painted frame is not jingle time")
    App.draw()
    Assert.isTrue(intro.painted, "the first painted frame starts jingle time")
    for _ = 1, 120 do
      App.update(1 / 60)
    end
    Assert.notNil(App._bootIntro, "no-candidate boot does not use the superseded short dwell")
    local elapsedAtFocusLoss = intro.elapsed
    App.focus(false)
    for _ = 1, 600 do
      App.update(1 / 60)
    end
    Assert.equal(intro.elapsed, elapsedAtFocusLoss, "background frames do not advance the jingle")
    Assert.notNil(App._bootIntro, "background time is not foreground time")
    App.focus(true)
    for _ = 1, 178 do
      App.update(1 / 60)
    end
    Assert.notNil(App._bootIntro)
    App.update(1 / 60)
    App.update(1 / 60)
    Assert.isNil(App._bootIntro)
    Assert.equal(#App.state:view().games, 2)
  end)

  withManagedLauncher(
    { installed = { heartgold = true }, candidate = true, backend = candidateBackend(), audioMissing = true },
    function()
      withStartupConsumers({}, function()
        local service, record = scriptedService()
        App.load({ dev = false })
        App.service = service
        App.draw()
        App.update(1 / 60)
        advanceUntil(function()
          return App.state and App.state.phase == "movie"
        end, "movie admission without launcher audio")
        Assert.isTrue(App.launcherAudio.unavailable)
        Assert.equal(App.state.phase, "movie", "launcher audio failure adds no readiness delay")
        Assert.equal(record.sourceRequests, 1)
      end)
    end
  )

  withManagedLauncher(
    { installed = { heartgold = true }, candidate = true, backend = candidateBackend() },
    function(host)
      local service = scriptedService({
        sourceStatus = "failed",
        sourceDetail = { code = "ROM_SOURCE_REQUIRED", message = "repair HeartGold" },
      })
      App.load({ dev = false })
      App.service = service
      App.draw()
      App.update(1 / 60)
      Assert.isNil(App._bootIntro, "terminal source failure does not wait out the animation")
      Assert.deepEqual(
        host.backgroundColors[#host.backgroundColors],
        WindowConfig.BACKGROUND_COLOR,
        "terminal boot failure restores the normal clear"
      )
      Assert.equal(App.state:view().mode, "error")
      Assert.equal(App.state:view().focusedId, "heartgold")
    end
  )
end

function T.boot_host_clear_is_owned_by_the_overlay_lifetime()
  withManagedLauncher({ installed = {} }, function(host)
    App.load({ dev = false })
    Assert.deepEqual(
      host.backgroundColors,
      { WindowConfig.BACKGROUND_COLOR, { 1, 1, 1, 1 } },
      "load installs the boot clear after the overlay exists"
    )
    App.draw()
    for _ = 1, 299 do
      App.update(1 / 60)
    end
    Assert.notNil(App._bootIntro, "the five-second dwell still runs unchanged")
    Assert.deepEqual(host.backgroundColors[#host.backgroundColors], { 1, 1, 1, 1 })
    App.update(1 / 60)
    Assert.isNil(App._bootIntro, "the overlay ends after the same dwell")
    Assert.equal(#App.state:view().games, 2, "natural completion still opens the selection")
    Assert.deepEqual(
      host.backgroundColors,
      { WindowConfig.BACKGROUND_COLOR, { 1, 1, 1, 1 }, WindowConfig.BACKGROUND_COLOR },
      "the overlay end restores the normal clear exactly once"
    )
    for _ = 1, 60 do
      App.update(1 / 60)
    end
    Assert.equal(#host.backgroundColors, 3, "post-boot frames keep the normal clear")
  end)

  withManagedLauncher(
    { installed = { heartgold = true }, candidate = true, backend = candidateBackend() },
    function(host)
      local service = scriptedService()
      App.load({ dev = false })
      App.service = service
      App.draw()
      Assert.deepEqual(host.backgroundColors[#host.backgroundColors], { 1, 1, 1, 1 })
      local before = #host.backgroundColors
      App.gamepadpressed({}, "x")
      Assert.isNil(App._bootIntro, "the interrupt still retires the overlay")
      Assert.equal(#App.state:view().games, 2, "the interrupt still reaches the selection")
      Assert.deepEqual(host.backgroundColors[#host.backgroundColors], WindowConfig.BACKGROUND_COLOR)
      Assert.equal(#host.backgroundColors, before + 1, "the interrupt restores the normal clear once")
    end
  )
end

function T.boot_admission_requires_a_foreground_window_and_overlay()
  withManagedLauncher({ installed = {} }, function(host)
    App.load({ dev = false })
    App.draw()
    local epoch, versionId = App.epoch, App.selectedVersionId
    App.focus(false)
    Assert.isFalse(App._admitOpening(epoch, versionId), "a backgrounded window cannot admit the retail movie")
    Assert.notNil(App._bootIntro, "closed admission keeps the boot overlay owned")

    App.focus(true)
    local intro = assert(App._bootIntro)
    Assert.isTrue(intro.foreground)
    intro:focus(false)
    Assert.isFalse(App._admitOpening(epoch, versionId), "a non-foreground overlay cannot admit the retail movie")
    Assert.isTrue(App._bootIntro == intro, "closed admission keeps the overlay in place")

    intro:focus(true)
    Assert.isTrue(App._admitOpening(epoch, versionId), "foreground admission still retires the overlay")
    Assert.isNil(App._bootIntro)
    Assert.deepEqual(
      host.backgroundColors[#host.backgroundColors],
      WindowConfig.BACKGROUND_COLOR,
      "foreground admission restores the normal clear"
    )
    Assert.isTrue(
      App._admitOpening(epoch, versionId),
      "later title and attract reentry is not gated by the boot overlay"
    )
  end)
end

function T.boot_audio_admission_failure_leaves_the_overlay_with_a_recoverable_error()
  for _, scenario in ipairs({
    {
      label = "milestone failure",
      audioFailure = "synthetic startup audio failure",
      cause = "synthetic startup audio failure",
    },
    { label = "soundtrack rejection", openingAck = false, cause = "synthetic opening soundtrack rejection" },
  }) do
    withManagedLauncher(
      { installed = { heartgold = true }, candidate = true, backend = candidateBackend() },
      function(host)
        withStartupConsumers({ openingAck = scenario.openingAck }, function()
          local service, record = scriptedService({ audioFailure = scenario.audioFailure })
          App.load({ dev = false })
          App.service = service
          App.draw()
          local intro = assert(App._bootIntro)
          advanceUntil(function()
            return App._bootIntro == nil
          end, scenario.label .. " overlay teardown")
          Assert.isTrue(intro.elapsed < 5, scenario.label .. " tears down before the five-second deadline")
          Assert.notNil(App.state, scenario.label .. " keeps the recoverable startup owner")
          Assert.equal(App.state.phase, "loading", scenario.label .. " never admits the movie")
          Assert.notNil(App.state.audioError, scenario.label .. " keeps its audio diagnostic")
          local first = #host.copy + 1
          App.draw()
          local text = drawnText(host, first)
          Assert.isTrue(text:find(scenario.cause, 1, true) ~= nil, scenario.label .. " shows its cause")
          Assert.isTrue(text:find("Press Esc to return", 1, true) ~= nil, scenario.label .. " offers recovery")
          Assert.equal(record.sourceRequests, 1, scenario.label .. " still starts one selected source")
        end)
      end
    )
  end
end

function T.manual_selection_wins_and_swallows_the_initiating_gesture_through_release()
  withManagedLauncher(
    { installed = { heartgold = true }, candidate = true, backend = candidateBackend() },
    function(host)
      local service, record = scriptedService()
      App.load({ dev = false })
      App.service = service
      App.keypressed("return", "return", false)
      Assert.equal(#App.state:view().games, 2)
      Assert.equal(App.state:view().focusedId, "heartgold")
      Assert.equal(record.sourceRequests, 0, "pre-paint interruption starts no speculative epoch")
      App.keypressed("return", "return", true)
      App.resize(800, 600)
      App.keyreleased("return", "return")
      Assert.equal(record.sourceRequests, 0, "repeat, resize and release cannot replay the initiating press")
      App.keypressed("return", "return", false)
      App.keyreleased("return", "return")
      Assert.equal(record.sourceRequests, 1, "the next deliberate confirmation launches once")
      Assert.deepEqual(host.quitCodes, {})
    end
  )

  withManagedLauncher({ installed = { heartgold = true }, candidate = true, backend = candidateBackend() }, function()
    withStartupConsumers({}, function(startup)
      local service, record = scriptedService()
      App.load({ dev = false })
      App.service = service
      App.draw()
      App.update(1 / 60)
      Assert.notNil(App._bootIntro)
      App.gamepadpressed({}, "x")
      Assert.isNil(App._bootIntro)
      Assert.equal(#App.state:view().games, 2)
      Assert.equal(#record.retired, 1)
      service.bootSourceStatus = function()
        return "ready"
      end
      for _ = 1, 10 do
        App.update(1 / 60)
      end
      Assert.equal(startup.movieTicks, 0)
      Assert.deepEqual(startup.audioEvents, {})
      Assert.equal(record.sourceRequests, 1, "late readiness cannot mint another selected epoch")
    end)
  end)

  withManagedLauncher(
    { installed = { heartgold = true }, candidate = true, backend = candidateBackend() },
    function(host)
      local service = scriptedService()
      App.load({ dev = false })
      App.service = service
      App.gamepadaxis({}, "leftx", 0.9)
      App.wheelmoved(0, 1)
      App.keypressed("lshift", "lshift", false)
      App.keyreleased("lshift", "lshift")
      App.keypressed("f11", "f11", false)
      Assert.equal(#host.fullscreenEvents, 1, "F11 remains the global fullscreen shortcut")
      Assert.notNil(App._bootIntro)
      Assert.isTrue(App._bootIntro.foreground)
      Assert.isNil(App.state, "non-button input does not choose selection or start speculation")
    end
  )
end

function T.targeted_import_channels_preserve_edition_and_terminal_ownership()
  withManagedLauncher({ installed = { heartgold = true } }, function(host, rom)
    local service = scriptedService()
    App.load({ dev = false })
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    App.service = service
    tap("soulsilver")
    Assert.equal(App.state:view().mode, "choose")
    Assert.equal(App.state:view().import.expectedVersionId, "soulsilver")
    host.setPickerResult({ kind = "path", path = rom.heartgold.originalPath })
    local receiptFrame = #host.copy + 1
    tap("choose-rom")
    App.draw()
    Assert.isTrue(
      drawnText(host, receiptFrame):find("original.nds", 1, true) ~= nil,
      "the sanitized receipt is visible before validation"
    )
    advanceUntil(function()
      return App.state:view().mode == "error"
    end, "targeted mismatch", rom)
    local view = App.state:view()
    Assert.equal(view.import.expectedVersionId, "soulsilver")
    Assert.equal(view.import.error.context.expectedVersionId, "soulsilver")
    Assert.equal(view.import.error.context.actualVersionId, "heartgold")
    Assert.isNil(RomArchive.recoverablePath(rom.soulsilver.cart.sha1), "wrong-edition validation publishes no source")
    Assert.notNil(RomArchive.recoverablePath(rom.heartgold.cart.sha1), "the prior edition remains unchanged")
    tap("back")
    tap("soulsilver")
    host.setPickerResult({ kind = "cancel" })
    tap("choose-rom")
    Assert.equal(App.state:view().mode, "choose", "native picker cancellation restores the targeted choose view")
    local dropPath = "launcher-targeted-drop.nds"
    Assert.isTrue(love.filesystem.write(dropPath, rom.soulsilver.cart.data))
    local dropped = assert(love.filesystem.newFile(dropPath))
    App.filedropped(dropped)
    App.draw()
    advanceUntil(function()
      return App.importer == nil and App.state:view().mode == "selection"
    end, "targeted drop publication", rom)
    Assert.isTrue(love.filesystem.remove(dropPath))
    Assert.equal(App.state:view().focusedId, "soulsilver")
    Assert.equal(App.state:view().games[2].installed, true)
    Assert.notNil(RomArchive.recoverablePath(rom.soulsilver.cart.sha1))
    Assert.notNil(love.filesystem.getInfo(RomArchive.iconPath(rom.soulsilver.cart.sha1), "file"))

    Assert.isTrue(love.filesystem.remove(rom.soulsilver.canonical))
    Assert.isTrue(love.filesystem.remove(rom.soulsilver.icon))
    tap("soulsilver")
    local requestId = "123e4567-e89b-12d3-a456-426614174000"
    host.setPickerResult({ kind = "pending", requestId = requestId })
    tap("choose-rom")
    App.update(1 / 60)
    Assert.isTrue(host.pickerPolls() > 0, "the native bridge is polled by exact request identity")
    local temporary = rom.heartgold:writePickerTemporary(requestId, rom.soulsilver.cart.data)
    host.setPickerPollResult({
      kind = "path",
      requestId = requestId,
      relativePath = temporary,
      displayName = "Android SoulSilver.nds",
    })
    App.update(1 / 60)
    App.draw()
    advanceUntil(function()
      return App.importer == nil and App.state:view().mode == "selection"
    end, "Android temporary publication", rom)
    Assert.equal(App.state:view().focusedId, "soulsilver")
    Assert.isNil(love.filesystem.getInfo(temporary), "the worker owns and removes the accepted private stage")

    Assert.isTrue(love.filesystem.remove(rom.soulsilver.canonical))
    Assert.isTrue(love.filesystem.remove(rom.soulsilver.icon))
    tap("soulsilver")
    local staleRequestId = "123e4567-e89b-12d3-a456-426614174001"
    host.setPickerResult({ kind = "pending", requestId = staleRequestId })
    tap("choose-rom")
    App.update(1 / 60)
    tap("back")
    local staleTemporary = rom.heartgold:writePickerTemporary(staleRequestId, rom.soulsilver.cart.data)
    host.setPickerPollResult({
      kind = "path",
      requestId = staleRequestId,
      relativePath = staleTemporary,
      displayName = "late.nds",
    })
    App.update(1 / 60)
    Assert.equal(App.state:view().mode, "selection", "a late native result cannot navigate a canceled attempt")
    Assert.isNil(love.filesystem.getInfo(staleTemporary), "stale native temporary data is cleaned up")
    Assert.isNil(RomArchive.recoverablePath(rom.soulsilver.cart.sha1), "stale picker data cannot publish a source")
  end)

  withManagedLauncher({ installed = { heartgold = true }, pickerAvailable = false }, function(host)
    App.load({ dev = false })
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    tap("soulsilver")
    Assert.equal(App.state:view().mode, "choose")
    Assert.isNil(App.state:view().layout.graph.targets["choose-rom"], "an unavailable native picker has no dead button")
    App.draw()
    Assert.isTrue(drawnText(host):lower():find("drop", 1, true) ~= nil, "desktop drop guidance remains actionable")
  end)
end

function T.receipt_barrier_and_commit_gates_have_one_import_owner()
  withManagedLauncher({ installed = { heartgold = true } }, function(host, rom)
    rom.host.holdValidation = true
    local service, record = scriptedService({ barrier = 7 })
    App.load({ dev = false })
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    App.service = service
    tap("soulsilver")
    host.setPickerResult({ kind = "path", path = rom.soulsilver.originalPath })
    tap("choose-rom")
    Assert.notNil(App.pendingQuiesce)
    Assert.equal(record.importCalls, 0, "no source worker starts before barrier acknowledgement")
    Assert.isNil(App.importer)
    host.setHostSize(0, 0)
    App.update(1 / 60)
    App.draw()
    Assert.equal(record.importCalls, 0, "suspension cannot acknowledge receipt paint")
    host.setHostSize(360, 640)
    local receiptFrame = #host.copy + 1
    App.draw()
    local operationText = drawnText(host, receiptFrame)
    Assert.isTrue(operationText:find("SoulSilver", 1, true) ~= nil)
    Assert.isNil(operationText:find("Now loading...", 1, true), "an operation never borrows generic loading copy")
    Assert.notNil(App.state:paintedReceipt(), "the real operation draw returns its receipt token")
    local waitingView = App.state:view()
    Assert.equal(waitingView.import.receipt, "soulsilver.nds")
    Assert.notNil(waitingView.import.statusText, "the operation publishes its actual waiting phase")
    Assert.isNil(waitingView.import.progress, "an unstarted worker cannot invent a finite fraction")
    Assert.equal(record.importCalls, 0)
    local epoch = App.epoch
    App._selectVersion("heartgold")
    Assert.equal(App.epoch, epoch, "a competing launch cannot replace the attempt owner")
    App.state:keypressed("escape")
    Assert.notNil(App.pendingQuiesce, "canceling the view never forgets the outstanding source barrier")
    Assert.equal(record.importCalls, 0)
    Assert.equal(record.quiesceCalls, 1, "canceling a view does not create another source barrier")

    tap("soulsilver")
    host.setPickerResult({ kind = "path", path = rom.soulsilver.originalPath })
    tap("choose-rom")
    Assert.equal(record.quiesceCalls, 1, "a new attempt waits behind the existing barrier")
    Assert.equal(record.importCalls, 0)
    record.barrierStatus = "ready"
    App.update(1 / 60)
    Assert.equal(record.importCalls, 1, "barrier acknowledgement authorizes exactly one source import")
    waitingView = App.state:view()
    App.draw()
    App.update(1 / 60)
    trackImporter(rom)
    local importer = assert(App.importer, "the painted and authorized attempt starts its queued worker")
    local session = rom.host:validationGate(importer)
    Assert.equal(
      App.state:view().import.attemptId,
      waitingView.import.attemptId,
      "worker progress keeps the same attempt identity"
    )
    Assert.equal(
      App.state:view().import.receipt,
      waitingView.import.receipt,
      "worker progress keeps the first receipt visible"
    )
    Assert.notNil(App.state:view().import.statusText, "the active worker publishes its real stage")
    Assert.isTrue(importer:status().canCancel, "precommit validation remains cancellable")
    App._cancelImport()
    session.outbox:discardValidation()
    rom.host:finish(importer, RomImporter.STATES.IDLE)
    Assert.isNil(RomArchive.recoverablePath(rom.soulsilver.cart.sha1), "precommit cancellation publishes no source")
    rom.host.holdValidation = false
    rom.host.holdCommit = true
    record.barrier = nil
    tap("soulsilver")
    host.setPickerResult({ kind = "path", path = rom.soulsilver.originalPath })
    tap("choose-rom")
    App.draw()
    App.update(1 / 60)
    trackImporter(rom)
    importer = assert(App.importer)
    rom.host:commitGate(importer)
    Assert.isFalse(importer:status().canCancel, "commit-sent is the noncancellable linearization point")
    App._cancelImport()
    App.keypressed("escape", "escape", false)
    App.gamepadpressed({}, "b")
    local lateDropPath = "launcher-late-drop.nds"
    Assert.isTrue(love.filesystem.write(lateDropPath, rom.heartgold.cart.data))
    local lateDrop = assert(love.filesystem.newFile(lateDropPath))
    App.filedropped(lateDrop)
    lateDrop:close()
    Assert.isTrue(love.filesystem.remove(lateDropPath))
    Assert.isTrue(App.importer == importer, "late cancel/back/drop cannot replace the committed owner")
    Assert.isTrue(importer._commitSent)
    rom.host:releaseCommit()
    advanceUntil(function()
      return App.importer == nil and App.state:view().mode == "selection"
    end, "committed publication", rom)
    Assert.notNil(RomArchive.recoverablePath(rom.soulsilver.cart.sha1), "committed source survives terminal handoff")
    Assert.equal(App.state:view().focusedId, "soulsilver")
  end)
end

function T.root_source_facts_clock_and_optional_icon_recovery_stay_independent()
  for _, installed in ipairs({
    {},
    { heartgold = true },
    { soulsilver = true },
    { heartgold = true, soulsilver = true },
  }) do
    withManagedLauncher({ installed = installed, icons = false }, function(host)
      App.load({ dev = false })
      App.keypressed("return", "return", false)
      App.keyreleased("return", "return")
      Assert.equal(host.managedProbes(), 2, "one installation fact per edition enters the selector")
      local view = App.state:view()
      Assert.equal(#view.games, 2)
      Assert.equal(view.games[1].versionId, "heartgold")
      Assert.equal(view.games[2].versionId, "soulsilver")
      Assert.equal(view.games[1].installed, installed.heartgold == true)
      Assert.equal(view.games[2].installed, installed.soulsilver == true)
      Assert.equal(
        view.games[1].iconSha1,
        installed.heartgold and GameVersion.info("heartgold").sha1 or nil,
        "the snapshot icon identity reuses the installed fact"
      )
      Assert.equal(
        view.focusedId,
        installed.heartgold and "heartgold" or installed.soulsilver and "soulsilver" or "heartgold"
      )
    end)
  end

  withLauncherHost({ ready = { heartgold = true } }, function()
    App.load({ dev = false })
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    local games = App.state:view().games
    Assert.equal(#games, 2)
    Assert.isFalse(games[1].installed, "cache readiness is not managed source installation")
    Assert.isFalse(games[2].installed)
  end)

  withManagedLauncher({ installed = { heartgold = true }, icons = false }, function()
    local Recovery = require("romdump.src.source.RomIconRecovery")
    local originalStart = Recovery.start
    Recovery.start = function()
      return {
        poll = function()
          return "failed", "synthetic optional recovery failure"
        end,
        dispose = function() end,
      }
    end
    local ok, failure = xpcall(function()
      App.load({ dev = false })
      App.keypressed("return", "return", false)
      App.keyreleased("return", "return")
      App.update(1 / 60)
      Assert.isTrue(App.state:view().games[1].installed, "optional recovery failure does not mark the source missing")
      local service, record = scriptedService()
      App.service = service
      tap("heartgold")
      Assert.equal(record.sourceRequests, 1, "installed source remains directly playable without an icon")
    end, debug.traceback)
    Recovery.start = originalStart
    if not ok then
      error(failure, 0)
    end
  end)

  withManagedLauncher({ installed = { heartgold = true }, icons = false }, function(_, rom)
    local Recovery = require("romdump.src.source.RomIconRecovery")
    local originalStart = Recovery.start
    local starts = 0
    Recovery.start = function()
      starts = starts + 1
      return {
        poll = function()
          return "failed", "synthetic invalid PNG recovery"
        end,
        dispose = function() end,
      }
    end
    local renderer, originalRefresh, originalDrop
    local ok, failure = xpcall(function()
      Assert.isTrue(love.filesystem.write(rom.heartgold.icon, "not a png"))
      Assert.notNil(love.filesystem.getInfo(rom.heartgold.icon, "file"), "the invalid PNG is present")
      App.load({ dev = false })
      renderer = assert(App.launcherRenderer)
      originalRefresh, originalDrop = renderer.refreshGameIcon, renderer.dropGameIcon
      local dropped = {}
      renderer.refreshGameIcon = function(_, sha1, path)
        Assert.equal(path, rom.heartgold.icon, "refresh receives the installed sidecar path")
        Assert.equal(sha1, rom.heartgold.cart.sha1, "refresh receives the installed source identity")
        return false
      end
      renderer.dropGameIcon = function(_, sha1)
        dropped[#dropped + 1] = sha1
      end
      App.keypressed("return", "return", false)
      App.keyreleased("return", "return")
      Assert.equal(starts, 1, "a present but unusable PNG schedules one process-local repair")
      local droppedInstalledSha = false
      for _, sha1 in ipairs(dropped) do
        droppedInstalledSha = droppedInstalledSha or sha1 == rom.heartgold.cart.sha1
      end
      Assert.isTrue(droppedInstalledSha, "an unusable PNG drops its stale texture")
      App._refreshRootIcons()
      Assert.equal(starts, 1, "repair is one-shot across icon refreshes")

      local savedAttempt = App._importAttempt
      App._importAttempt = { attemptId = {} }
      App._refreshRootIcons()
      App._importAttempt = savedAttempt
      Assert.equal(starts, 1, "an active import still defers optional icon repair")
    end, debug.traceback)
    if renderer ~= nil then
      renderer.refreshGameIcon = originalRefresh
      renderer.dropGameIcon = originalDrop
    end
    Recovery.start = originalStart
    if not ok then
      error(failure, 0)
    end
  end)

  local now = { year = 2026, month = 12, day = 31, hour = 23, minute = 59, second = 0 }
  withManagedLauncher({ installed = { heartgold = true, soulsilver = true }, now = now }, function(host, rom)
    local Recovery = require("romdump.src.source.RomIconRecovery")
    local originalStart = Recovery.start
    local starts = 0
    Recovery.start = function(versionId)
      starts = starts + 1
      local bytes = love.data.newByteData(rom[versionId].cart.data)
      local png = assert(RomArchive.encodeIcon(bytes))
      bytes:release()
      local delivered, disposed, polls = false, false, 0
      return {
        poll = function()
          polls = polls + 1
          if polls == 1 then
            return "pending"
          end
          if polls == 2 and not disposed then
            delivered = true
            local result = png
            png = nil
            return "ready", rom[versionId].cart.sha1, result
          end
          return nil
        end,
        dispose = function()
          if disposed then
            return
          end
          disposed = true
          if not delivered and png ~= nil then
            png:release()
            png = nil
          end
        end,
      }
    end
    local ok, failure = xpcall(function()
      Assert.isTrue(love.filesystem.remove(rom.heartgold.icon), "missing-icon setup failed")
      App.load({ dev = false })
      App.keypressed("return", "return", false)
      App.keyreleased("return", "return")
      App.draw()
      local text = drawnText(host)
      Assert.isTrue(text:find("31/12/2026", 1, true) ~= nil)
      Assert.isTrue(text:find("23:59", 1, true) ~= nil)
      Assert.isTrue(text:find(require("app.src.BuildInfo").version, 1, true) ~= nil)
      advanceUntil(function()
        return love.filesystem.getInfo(rom.heartgold.icon, "file") ~= nil
      end, "optional icon recovery", rom)
      Assert.equal(starts, 1, "missing sidecar schedules one process-local repair")
      Assert.notNil(
        RomArchive.recoverablePath(rom.heartgold.cart.sha1),
        "optional icon recovery never gates installation"
      )
      for _ = 1, 5 do
        App.update(1 / 60)
      end
      local imagesAfterRecovery = #host.images
      for _ = 1, 10 do
        App.state:view()
        App.draw()
        App.update(1 / 60)
      end
      Assert.equal(starts, 1, "recovery is not retried per view")
      Assert.equal(#host.images, imagesAfterRecovery, "a recovered texture is cached rather than allocated per view")
      now.day, now.month, now.year, now.hour, now.minute = 1, 1, 2027, 0, 0
      App.state:update(0)
      local first = #host.copy + 1
      App.draw()
      text = drawnText(host, first)
      Assert.isTrue(text:find("01/01/2027", 1, true) ~= nil)
      Assert.isTrue(text:find("00:00", 1, true) ~= nil)
    end, debug.traceback)
    Recovery.start = originalStart
    if not ok then
      error(failure, 0)
    end
  end)
end

function T.launcher_resources_release_every_acquired_file_and_host_object()
  withLauncherHost({}, function(host)
    App.load({ dev = false })
    for _, data in ipairs(host.fileData) do
      Assert.equal(data.releases, 1, "constructor FileData releases once: " .. data.path)
    end
    for _, imageData in ipairs(host.imageDatas) do
      Assert.equal(imageData.releases, 1)
    end
    Assert.equal(countByPath(host.fileData, BOOT_LOGO_PATH), 1, "the boot logo FileData is acquired once")
    Assert.equal(countByPath(host.imageDatas, BOOT_LOGO_PATH), 1, "the boot logo image data is decoded once")
    Assert.equal(countByPath(host.images, BOOT_LOGO_PATH), 1, "the boot logo image is created once")
    local cachedLogo
    for _, image in ipairs(host.images) do
      if image.path == BOOT_LOGO_PATH then
        cachedLogo = image
      end
    end
    cachedLogo = assert(cachedLogo, "the boot logo image is cached")
    App.draw()
    App.draw()
    Assert.equal(countByPath(host.draws, BOOT_LOGO_PATH), 2, "each boot frame paints the logo")
    Assert.equal(countByPath(host.fileData, BOOT_LOGO_PATH), 1, "drawing acquires no FileData")
    Assert.equal(countByPath(host.imageDatas, BOOT_LOGO_PATH), 1, "drawing decodes no image data")
    Assert.equal(countByPath(host.images, BOOT_LOGO_PATH), 1, "drawing creates no image")
    for _, draw in ipairs(host.draws) do
      if draw.path == BOOT_LOGO_PATH then
        Assert.equal(draw.image, cachedLogo, "both frames use the cached logo image")
      end
    end
    App.quit()
    for index = 2, #host.fonts do
      Assert.equal(host.fonts[index].released, 1, "renderer fonts release once")
    end
    for _, image in ipairs(host.images) do
      Assert.equal(image.released, 1, "renderer images release once")
    end
    for _, source in ipairs(host.audioSources) do
      Assert.equal(source.released, 1, "launcher Sources release once")
    end
  end)
end

function T.launcher_faces_are_acquired_with_an_explicit_pixel_policy()
  withLauncherHost({
    syntheticFonts = {
      ["assets/fonts/mplus1p/MPLUS1p-Bold.ttf"] = true,
      ["assets/fonts/galmuri/Galmuri9.ttf"] = true,
    },
  }, function(host)
    App.load({ dev = false })
    local byPath = {}
    for _, request in ipairs(host.fontRequests) do
      byPath[request.path] = request
    end
    local wordmark = assert(byPath["assets/fonts/mplus1p/MPLUS1p-Bold.ttf"], "smooth wordmark face is acquired")
    Assert.equal(wordmark.size, 32, "the wordmark is authored at its larger size")
    Assert.equal(wordmark.hinting, "normal", "the wordmark keeps smooth hinting")
    Assert.equal(wordmark.dpi, 3, "the wordmark rasterizes above its logical size")
    Assert.deepEqual(wordmark.font.filter, { "linear", "linear" }, "the smooth face is not nearest filtered")
    local prompt = assert(byPath["assets/fonts/galmuri/Galmuri9.ttf"], "native prompt face is acquired")
    Assert.equal(prompt.size, 10, "the prompt uses its native pixel size")
    Assert.deepEqual(prompt.font.filter, { "nearest", "nearest" }, "the prompt stays a pixel face")
  end)
end

function T.neutral_loading_centers_one_full_title_under_a_single_placement()
  withManagedLauncher({ installed = { heartgold = true, soulsilver = true }, width = 764, height = 575 }, function(host)
    App.load({ dev = false })
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    App.service = scriptedService()
    App._selectVersion("heartgold")
    local first = #host.copy + 1
    local origins = host.transformEnters()
    App.draw()
    Assert.equal(host.transformEnters() - origins, 1, "the loader paints through exactly one logical placement")
    local text = drawnText(host, first)
    Assert.equal(occurrences(text, "Pokémon HeartGold"), 1, "the full edition title appears once")
    Assert.equal(occurrences(text, "Now loading..."), 1, "the neutral status appears once")
    Assert.isNil(text:find("heartgold", 1, true), "the loader does not print a version identifier")
    local center = drawnTitleCenter(host, first, "Pokémon HeartGold")
    Assert.notNil(center, "the full title reaches the painted host boundary")
    Assert.isTrue(math.abs(center - 764 / 2) <= 40, "the title block is centered in the usable surface")
  end)
end

function T.neutral_error_diagnostic_stays_in_its_region_and_stops_loading_motion()
  for _, case in ipairs({ { width = 256, height = 192 }, { width = 390, height = 844 } }) do
    withLauncherHost({ width = case.width, height = case.height }, function(host)
      local renderer = require("app.src.launcher.LauncherRenderer").new()
      local captured
      local drawLoading = renderer.drawLoading
      function renderer:drawLoading(view, layout)
        captured = layout
        drawLoading(self, view, layout)
      end
      local safeRect = { x = 0, y = 0, width = case.width, height = case.height }
      local displayContext = DisplayContext.new({
        graphics = {
          getDimensions = function()
            return case.width, case.height
          end,
          getDPIScale = function()
            return 1
          end,
        },
        topologyProvider = function()
          return { surfaces = { { id = "main", role = "world", rect = safeRect, safeRect = safeRect, touch = true } } }
        end,
      })
      local Loading = require("app.src.launcher.LauncherLoadingPresentation")
      local loading = Loading.new({
        renderer = renderer,
        versionId = "heartgold",
        gameLabel = "Pokémon HeartGold",
        label = "Now loading...",
        width = case.width,
        height = case.height,
        safeRect = safeRect,
        pixelRatio = 1,
        displayContext = displayContext,
        selectionInterrupt = true,
        onCancel = function() end,
      })
      local first = #host.copy + 1
      loading:draw({ label = "Preparation failed", error = "Cache read failed", detail = "Card unreadable" })
      local text = drawnText(host, first)
      Assert.isTrue(text:find("Cache read failed", 1, true) ~= nil, "the neutral diagnostic reaches the host")
      Assert.isNil(text:find("Now loading...", 1, true), "generic status is suppressed while an error is visible")
      local region = assert(captured and captured.errorRect, "the loader resolves a diagnostic region")
      local diagnosticLines = 0
      for _, position in ipairs(host.printPositions) do
        if position.text:find("Cache read failed", 1, true) then
          diagnosticLines = diagnosticLines + 1
          Assert.isTrue(
            position.x >= region.x and position.y >= region.y,
            "diagnostic copy starts inside its measured region"
          )
          Assert.isTrue(
            position.x + renderer.fonts.body:getWidth(position.text) * position.scaleX <= region.x + region.width
              and position.y + renderer.fonts.body:getHeight() <= region.y + region.height,
            "diagnostic copy ends inside its measured region"
          )
        end
      end
      Assert.equal(diagnosticLines, 1, "the diagnostic paints once")
      Assert.isTrue(
        captured.promptRect.y >= region.y + region.height,
        "the bottom-right prompt stays clear of the diagnostic"
      )
      for _, shape in ipairs(host.rectangles) do
        Assert.isFalse(
          shape.width == 8 and shape.height == 8,
          "loading squares stay suppressed while an error is visible"
        )
      end
      loading:dispose()
      renderer:dispose()
    end)
  end
end

function T.transferred_loader_recenters_after_resize_and_preserves_operation_status()
  local StartupTitleState = require("app.src.launcher.StartupTitleState")
  withManagedLauncher({
    installed = { heartgold = true },
    candidate = true,
    backend = candidateBackend(),
    width = 764,
    height = 575,
  }, function(host)
    withStartupConsumers({}, function()
      local service = scriptedService({ scenesReady = false })
      App.load({ dev = false })
      App.service = service
      App.draw()
      App.update(1 / 60)
      advanceUntil(function()
        return getmetatable(App.state).__index == StartupTitleState
      end, "boot loader transfer")
      advanceUntil(function()
        return App._bootIntro == nil
      end, "boot overlay completion")
      local first = #host.copy + 1
      local origins = host.transformEnters()
      App.draw()
      Assert.equal(host.transformEnters() - origins, 1, "the borrowed loader keeps one placement after transfer")
      local text = drawnText(host, first)
      Assert.equal(occurrences(text, "Pokémon HeartGold"), 1, "the transferred loader keeps the full title")
      Assert.equal(occurrences(text, "Now loading..."), 1, "the transferred loader keeps the neutral status")

      local safeRect = { x = 12, y = 18, width = 320, height = 560 }
      host.setPixelRatio(2)
      host.setHostSize(360, 640)
      host.setSafeRect(safeRect)
      App.resize(720, 1280)
      first = #host.copy + 1
      origins = host.transformEnters()
      App.draw()
      Assert.equal(host.transformEnters() - origins, 1, "a resized loader still paints through one placement")
      text = drawnText(host, first)
      Assert.equal(occurrences(text, "Pokémon HeartGold"), 1, "resize does not duplicate the title")
      local center = drawnTitleCenter(host, first, "Pokémon HeartGold")
      Assert.notNil(center, "the resized title reaches the host boundary")
      Assert.isTrue(
        math.abs(center - (safeRect.x + safeRect.width / 2)) <= 24,
        "the resized title is centered in the new safe bounds"
      )
    end)
  end)
end

function T.launcher_font_failure_releases_every_acquired_face_and_file()
  withLauncherHost({ missingAsset = "assets/fonts/galmuri/Galmuri9.ttf" }, function(host)
    local constructed = false
    pcall(function()
      require("app.src.launcher.LauncherRenderer").new()
      constructed = true
    end)
    Assert.isFalse(constructed, "a missing required face fails renderer construction")
    for _, data in ipairs(host.fileData) do
      Assert.equal(data.releases, 1, "constructor FileData releases once: " .. data.path)
    end
    for index = 2, #host.fonts do
      Assert.equal(host.fonts[index].released, 1, "every acquired face releases on rollback")
    end
  end)
end

function T.boot_logo_failure_releases_every_acquired_face_and_file()
  withLauncherHost({ missingAsset = BOOT_LOGO_PATH }, function(host)
    local constructed = false
    pcall(function()
      require("app.src.launcher.LauncherRenderer").new()
      constructed = true
    end)
    Assert.isFalse(constructed, "a missing boot logo fails renderer construction")
    for _, data in ipairs(host.fileData) do
      Assert.equal(data.releases, 1, "constructor FileData releases once: " .. data.path)
    end
    for _, data in ipairs(host.imageDatas) do
      Assert.equal(data.releases, 1, "decoded image data releases once on rollback")
    end
    for _, image in ipairs(host.images) do
      Assert.equal(image.released, 1, "an acquired image releases on rollback")
    end
  end)
end

return { tests = T }
