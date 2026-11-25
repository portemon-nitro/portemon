-- ROM-free launcher composition at the App boundary. Only host graphics,
-- audio, picker and save-root placement are replaced; routing and the real
-- SaveFs/GameSaveStore metadata path stay production-owned.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local FakeCache = require("tests.support.FakeCache")
local PublishedSaveFixture = require("tests.support.PublishedSaveFixture")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local RomImporter = require("romdump.src.source.RomImporter")
local CacheArchive = require("romdump.src.build.CacheArchive")
local NativeRomPicker = require("app.src.launcher.NativeRomPicker")

local T = {}

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
    return words
  end
  function font:release()
    self.released = self.released + 1
  end
  return font
end

local function fakeImage()
  local image = { released = 0 }
  function image:getWidth()
    return 16
  end
  function image:getHeight()
    return 16
  end
  function image:getDimensions()
    return 16, 16
  end
  function image:setFilter() end
  function image:release()
    self.released = self.released + 1
  end
  return image
end

local function fakeSource()
  local source = { released = 0, volume = 1 }
  function source:play() end
  function source:pause() end
  function source:stop() end
  function source:isPlaying()
    return false
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
  local audioSources = {}
  local fonts = {}
  local images = {}
  local imageDatas = {}
  local fileData = {}
  local printPositions = {}
  local rectangles = {}
  local draws = {}
  local currentColor = { 1, 1, 1, 1 }
  local transform = { x = 0, y = 0, scaleX = 1, scaleY = 1 }
  local transforms = {}
  local function hostPoint(x, y)
    return transform.x + x * transform.scaleX, transform.y + y * transform.scaleY
  end
  local quitCodes = {}
  local safeAreaReads = 0
  local hostWidth, hostHeight = options.width or 360, options.height or 640
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
    assetRead = LauncherAssets.read,
    quit = love.event.quit,
    ready = RomImporter.isReady,
    registered = RomImporter.isRegistered,
    recoverable = CacheArchive.recoverableFileName,
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
    return 1
  end
  graphics.setBackgroundColor = function() end
  graphics.newFont = function()
    local font = fakeFont()
    fonts[#fonts + 1] = font
    return font
  end
  graphics.newImage = function(imageData)
    if options.failImageAt == #images + 1 then
      error("synthetic launcher image acquisition failure", 0)
    end
    local image = fakeImage()
    image.path = imageData.path
    images[#images + 1] = image
    return image
  end
  love.image.newImageData = function(data)
    local imageData = { path = data:getFilename(), releases = 0 }
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
    printPositions[#printPositions + 1] = { text = tostring(text), x = x, y = y }
  end
  graphics.printf = function(text, x, y)
    x, y = hostPoint(x, y)
    copy[#copy + 1] = tostring(text)
    printPositions[#printPositions + 1] = { text = tostring(text), x = x, y = y }
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
  graphics.draw = function(image, x, y)
    x, y = hostPoint(x, y)
    draws[#draws + 1] = { image = image, x = x, y = y }
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
    local source = fakeSource()
    source.path = data:getFilename()
    audioSources[#audioSources + 1] = source
    return source
  end
  love.window.getSafeArea = function()
    safeAreaReads = safeAreaReads + 1
    return safeRect.x, safeRect.y, safeRect.width, safeRect.height
  end
  LauncherAssets.read = function(path)
    if path == options.missingAsset then
      return nil
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
  NativeRomPicker.available = function()
    return true
  end
  NativeRomPicker.openSingle = function()
    pickerOpens = pickerOpens + 1
    return { kind = "cancel" }
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
    audioSources = audioSources,
    fonts = fonts,
    images = images,
    imageDatas = imageDatas,
    fileData = fileData,
    printPositions = printPositions,
    rectangles = rectangles,
    draws = draws,
    safeAreaReads = function()
      return safeAreaReads
    end,
    safeRect = function()
      return safeRect
    end,
    setSafeRect = function(rect)
      safeRect = rect
    end,
    quitCodes = quitCodes,
  }
  local ok, err = xpcall(function()
    fn(result)
  end, debug.traceback)
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
  LauncherAssets.read = original.assetRead
  love.audio = originalAudio
  love.event.quit = original.quit
  RomImporter.isReady = original.ready
  RomImporter.isRegistered = original.registered
  CacheArchive.recoverableFileName = original.recoverable
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

local function drawnText(result)
  return table.concat(result.copy, "\n")
end

local function colorMatches(actual, expected)
  for index = 1, 4 do
    if math.abs((actual[index] or 1) - expected[index]) > 0.002 then
      return false
    end
  end
  return true
end

function T.rom_free_boot_times_out_to_empty_selection_and_picker_cancel_leaves_it_unchanged()
  withLauncherHost({}, function(result)
    App.load({ dev = false })
    Assert.isNil(App.importer, "the first boot frame starts no ROM import")
    Assert.isNil(App.selectedVersionId, "the first boot frame selects no game")
    App.draw()
    local firstFrame = drawnText(result)
    Assert.isTrue(
      firstFrame:find("Press any button to select game", 1, true) ~= nil,
      "the exact muted prompt is visible immediately"
    )
    Assert.isTrue(firstFrame:find("Portémon Nitro", 1, true) ~= nil, "the accented wordmark uses the bundled font")

    for _ = 1, 120 do
      App.update(1 / 60)
    end
    Assert.equal(type(App.state.view), "function", "the foreground timer commits to the game library")
    App.draw()
    local empty = drawnText(result)
    Assert.isTrue(empty:find("No games yet", 1, true) ~= nil, "first boot is the empty library state")
    Assert.isTrue(empty:find("Add game", 1, true) ~= nil, "the empty library exposes Add game")
    Assert.isTrue(empty:find("dev", 1, true) ~= nil, "the installed source version is visible")
    Assert.isTrue(empty:lower():find("settings", 1, true) == nil, "the first build has no settings dead end")
    Assert.isTrue(empty:lower():find("update", 1, true) == nil, "the first build has no update dead end")

    local before = App.state
    App.state:keypressed("return")
    Assert.equal(result.pickerOpens(), 1, "Add game opens the native picker")
    Assert.isTrue(App.state == before, "picker cancellation keeps the same library state")
    Assert.deepEqual(result.quitCodes, {}, "cancelling the picker does not quit")
  end)
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

function T.boot_gesture_selects_once_and_is_not_replayed_as_play_or_movie_skip()
  withLauncherHost({ ready = { heartgold = true }, candidate = true, backend = candidateBackend() }, function(result)
    local routes = {}
    App._selectVersion = function(versionId)
      routes[#routes + 1] = "play:" .. versionId
      App.selectedVersionId = versionId
    end
    App._showGameSelection = function()
      routes[#routes + 1] = "selection"
      App.selectedVersionId = nil
      App.state = {
        view = function()
          return { focusedId = "heartgold" }
        end,
      }
    end
    App.load({ dev = false })
    Assert.deepEqual(routes, {}, "loading a candidate does not commit the timed route early")
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    App.update(1 / 60)
    Assert.deepEqual(routes, { "selection" }, "the initiating gesture chooses selection exactly once")
    App.keypressed("return", "return", false)
    App.keyreleased("return", "return")
    for _ = 1, 120 do
      App.update(1 / 60)
    end
    Assert.deepEqual(routes, { "selection" }, "the timed route and release never activate Play or skip a movie")
  end)
end

function T.analog_drift_wheel_and_background_time_do_not_veto_automatic_choice()
  withLauncherHost({ ready = { heartgold = true }, candidate = true, backend = candidateBackend() }, function()
    local routes = {}
    App._selectVersion = function(versionId)
      routes[#routes + 1] = "play:" .. versionId
      App.selectedVersionId = versionId
    end
    App._showGameSelection = function()
      routes[#routes + 1] = "selection"
      App.selectedVersionId = nil
    end
    App.load({ dev = false })
    App.gamepadaxis({}, "leftx", 0.8)
    App.wheelmoved(0, 1)
    App.focus(false)
    for _ = 1, 120 do
      App.update(1 / 60)
    end
    Assert.deepEqual(routes, {}, "background time and non-button input do not commit a route")
    App.focus(true)
    for _ = 1, 120 do
      App.update(1 / 60)
    end
    Assert.equal(routes[1], "play:heartgold", "foreground timeout uses the ordinary automatic game choice")
    Assert.equal(#routes, 1, "the automatic route commits once")
  end)
end

local function assertDrawInside(result, safe, firstPrint, firstRectangle)
  for index = firstPrint or 1, #result.printPositions do
    local printed = result.printPositions[index]
    Assert.isTrue(printed.x >= safe.x and printed.y >= safe.y, "text starts inside the native safe rectangle")
    Assert.isTrue(
      printed.x + #printed.text * 6 <= safe.x + safe.width and printed.y + 12 <= safe.y + safe.height,
      "text ends inside the native safe rectangle: " .. printed.text
    )
  end
  for index = firstRectangle or 1, #result.rectangles do
    local rectangle = result.rectangles[index]
    Assert.isTrue(
      rectangle.x >= safe.x
        and rectangle.y >= safe.y
        and rectangle.x + rectangle.width <= safe.x + safe.width
        and rectangle.y + rectangle.height <= safe.y + safe.height,
      "launcher painting stays inside the native safe rectangle"
    )
  end
end

function T.app_composes_native_safe_area_into_boot_selection_and_loading()
  local hostOptions = {
    width = 640,
    height = 360,
    safeRect = { x = 40, y = 20, width = 560, height = 300 },
    ready = { heartgold = true },
  }
  withLauncherHost(hostOptions, function(result)
    App.load({ dev = false })
    local safe = result.safeRect()
    Assert.isTrue(result.safeAreaReads() > 0, "App observes the native safe area during production boot composition")
    Assert.deepEqual(App.state.safeRect, safe, "boot receives App's measured safe rectangle")
    local firstPrint, firstRectangle = #result.printPositions + 1, #result.rectangles + 1
    App.draw()
    assertDrawInside(result, safe, firstPrint, firstRectangle)

    for _ = 1, 120 do
      App.update(1 / 60)
    end
    local view = App.state:view()
    local measured = App.state._displayContext:measure(640, 360)
    Assert.deepEqual(
      measured.topology.surfaces[1].safeRect,
      safe,
      "selection resolves against App's measured safe topology"
    )
    local frame = assert(view.presentation.panes[1].placement.frame)
    Assert.isTrue(
      frame.x >= safe.x
        and frame.y >= safe.y
        and frame.x + frame.width <= safe.x + safe.width
        and frame.y + frame.height <= safe.y + safe.height,
      "the composed selection frame stays inside the native safe rectangle"
    )
    local readsBeforeView = result.safeAreaReads()
    App.state:view()
    App.draw()
    Assert.equal(result.safeAreaReads(), readsBeforeView, "launcher states never observe the native window themselves")

    local epoch = 0
    App.service = {
      select = function()
        epoch = epoch + 1
        return epoch
      end,
      request = function() end,
      observe = function()
        return false
      end,
      update = function() end,
      setExecutionPolicy = function() end,
      requestBootSource = function() end,
      bootSourceStatus = function()
        return "pending"
      end,
      retire = function() end,
      shutdown = function() end,
    }
    App._selectVersion("heartgold")
    Assert.deepEqual(App.state.loading.safeRect, safe, "neutral loading receives the same measured safe rectangle")
    firstPrint, firstRectangle = #result.printPositions + 1, #result.rectangles + 1
    App.draw()
    assertDrawInside(result, safe, firstPrint, firstRectangle)

    local changed = { x = 60, y = 30, width = 520, height = 280 }
    result.setSafeRect(changed)
    local readsBeforeResize = result.safeAreaReads()
    App.update(1 / 60)
    Assert.equal(result.safeAreaReads(), readsBeforeResize + 1, "App alone refreshes a same-size safe-area change")
    Assert.deepEqual(App.state.loading.safeRect, changed, "safe-area-only changes reach the live loading presentation")
    firstPrint, firstRectangle = #result.printPositions + 1, #result.rectangles + 1
    App.draw()
    assertDrawInside(result, changed, firstPrint, firstRectangle)
  end)
end

function T.launcher_construction_releases_every_file_data_after_use()
  withLauncherHost({}, function(result)
    App.load({ dev = false })
    Assert.equal(#result.fileData, 14, "the renderer and audio owner acquire their nine visual and five audio files")
    for _, data in ipairs(result.fileData) do
      Assert.equal(
        data.releases,
        1,
        "each FileData releases immediately after its consuming constructor: " .. data.path
      )
    end
    Assert.equal(#result.imageDatas, 6, "each launcher icon acquires one intermediate ImageData")
    for _, imageData in ipairs(result.imageDatas) do
      Assert.equal(imageData.releases, 1, "each ImageData releases immediately after its Image is constructed")
    end
  end)
end

function T.partial_visual_construction_releases_prior_resources_and_file_data()
  withLauncherHost({ failImageAt = 2 }, function(result)
    local ok, failure = pcall(App.load, { dev = false })
    Assert.isFalse(ok, "a partial visual constructor fails instead of publishing a half-usable renderer")
    Assert.isTrue(tostring(failure):find("image acquisition failure", 1, true) ~= nil)
    Assert.equal(#result.fileData, 5, "three fonts and two icon files were acquired before the failure")
    for _, data in ipairs(result.fileData) do
      Assert.equal(data.releases, 1, "partial visual construction releases each FileData exactly once")
    end
    for index = 2, #result.fonts do
      Assert.equal(result.fonts[index].released, 1, "partial visual construction releases each prior Font exactly once")
    end
    for _, image in ipairs(result.images) do
      Assert.equal(image.released, 1, "partial visual construction releases each prior Image exactly once")
    end
    Assert.equal(#result.imageDatas, 2, "both icon ImageData objects exist before the second Image fails")
    for _, imageData in ipairs(result.imageDatas) do
      Assert.equal(imageData.releases, 1, "partial visual construction releases each ImageData exactly once")
    end
  end)
end

function T.partial_audio_construction_releases_prior_sources_and_file_data()
  withLauncherHost({ failAudioAt = 3 }, function(result)
    App.load({ dev = false })
    Assert.isTrue(
      App.launcherAudio.unavailable,
      "App retains the explicit silent audio owner after partial device failure"
    )
    Assert.equal(#result.audioSources, 2, "only the two Sources completed before the failure were acquired")
    for _, source in ipairs(result.audioSources) do
      Assert.equal(source.released, 1, "partial audio construction releases each prior Source exactly once")
    end
    Assert.equal(#result.fileData, 12, "visual construction and three attempted audio acquisitions use FileData")
    for _, data in ipairs(result.fileData) do
      Assert.equal(data.releases, 1, "silent-audio fallback releases every acquired FileData exactly once")
    end
  end)
end

function T.import_status_renders_real_progress_and_the_back_cancel_action()
  withLauncherHost({}, function(result)
    App.load({ dev = false })
    local GameSelectState = require("app.src.launcher.GameSelectState")
    local library = GameSelectState.new({
      games = {
        { gameId = "heartgold", versionId = "heartgold", label = "HeartGold", ready = true, hasSave = false },
      },
      initialGameId = "heartgold",
      importer = {
        status = function()
          return { state = "verifying", progress = 0.6, canCancel = true }
        end,
      },
      renderer = App.launcherRenderer,
      audio = App.launcherAudio,
      width = 360,
      height = 640,
      onPick = function() end,
      onPlay = function() end,
      onCancelImport = function() end,
      onDismissError = function() end,
      onQuit = function() end,
    })
    library:markReceived("heartgold.nds")
    local view = library:view()
    local status = assert(view.layout.statusRect)
    local cancel = assert(view.layout.cancelRect)
    library:draw()
    Assert.isTrue(drawnText(result):find("Cancel", 1, true) ~= nil, "the status action has a visible label")
    local backDrawn = false
    local drawnIcons = {}
    for _, draw in ipairs(result.draws) do
      drawnIcons[#drawnIcons + 1] = string.format("%s@%g,%g", tostring(draw.image.path), draw.x, draw.y)
      if draw.image.path == "assets/ui/launcher/icons/back.png" then
        backDrawn = draw.x >= cancel.x
          and draw.x + 32 <= cancel.x + cancel.width
          and draw.y >= cancel.y
          and draw.y + 32 <= cancel.y + cancel.height
      end
    end
    Assert.isTrue(
      backDrawn,
      "Cancel renders with the existing Back icon inside its target: " .. table.concat(drawnIcons, ", ")
    )

    local track, fill
    for _, rectangle in ipairs(result.rectangles) do
      if rectangle.mode == "fill" and rectangle.y == status.y + 30 and rectangle.height == 4 then
        if colorMatches(rectangle.color, { 0.984, 0, 0.573, 1 }) then
          fill = rectangle
        else
          track = rectangle
        end
      end
    end
    Assert.notNil(track, "determinate importer progress renders a track")
    Assert.notNil(fill, "determinate importer progress renders its real fraction")
    Assert.isTrue(math.abs(fill.width / track.width - 0.6) <= 0.02, "the rendered fraction follows importer progress")
    Assert.isTrue(track.x + track.width <= cancel.x, "progress reserves space before Cancel")
    library:dispose()
  end)
end

function T.panel_faces_paint_clipped_alternating_one_pixel_rows()
  withLauncherHost({}, function(result)
    App.load({ dev = false })
    local GameSelectState = require("app.src.launcher.GameSelectState")
    local library = GameSelectState.new({
      games = {
        { gameId = "heartgold", versionId = "heartgold", label = "HeartGold", ready = true, hasSave = false },
      },
      initialGameId = "heartgold",
      renderer = App.launcherRenderer,
      audio = App.launcherAudio,
      width = 360,
      height = 640,
      onPick = function() end,
      onPlay = function() end,
      onCancelImport = function() end,
      onDismissError = function() end,
      onQuit = function() end,
    })
    local row = assert(library:view().layout.list.rows.heartgold)
    library:draw()
    local face = { x = row.x + 1, y = row.y + 1, width = row.width - 3, height = row.height - 3 }
    local rows = {}
    for _, rectangle in ipairs(result.rectangles) do
      if
        rectangle.mode == "fill"
        and rectangle.height == 1
        and rectangle.x == face.x
        and rectangle.width == face.width
        and rectangle.y >= face.y - 2
        and rectangle.y <= face.y + face.height + 2
      then
        Assert.isTrue(
          rectangle.y >= face.y and rectangle.y < face.y + face.height,
          "face rows stay inside the panel rim"
        )
        rows[#rows + 1] = rectangle
      end
    end
    Assert.isTrue(#rows >= 20, "the panel face is painted as fine horizontal rows")
    for index = 2, #rows do
      Assert.equal(rows[index].y, rows[index - 1].y + 1, "face rows are contiguous")
      Assert.isFalse(colorMatches(rows[index].color, rows[index - 1].color), "face rows alternate color")
    end
    Assert.isTrue(
      colorMatches(rows[1].color, { 0.922, 0.922, 0.922, 1 }) or colorMatches(rows[1].color, { 0.984, 0.984, 0.984, 1 }),
      "face rows use only the locked panel colors"
    )
    library:dispose()
  end)
end

function T.neutral_loading_uses_the_locked_primitive_and_touch_cancel()
  local hostOptions = { width = 640, height = 360, safeRect = { x = 40, y = 20, width = 560, height = 300 } }
  withLauncherHost(hostOptions, function(result)
    App.load({ dev = false })
    local epoch = 0
    App.service = {
      select = function()
        epoch = epoch + 1
        return epoch
      end,
      request = function() end,
      observe = function()
        return false
      end,
      update = function() end,
      setExecutionPolicy = function() end,
      requestBootSource = function() end,
      bootSourceStatus = function()
        return "pending"
      end,
      retire = function() end,
      shutdown = function() end,
    }
    App._selectVersion("heartgold")
    App.draw()
    Assert.isTrue(drawnText(result):find("Cancel", 1, true) ~= nil, "neutral loading has a visible Cancel action")
    local squares = {}
    for _, rectangle in ipairs(result.rectangles) do
      if rectangle.mode == "fill" and rectangle.width == 8 and rectangle.height == 8 then
        squares[#squares + 1] = rectangle
      end
    end
    Assert.equal(#squares, 4, "loading uses exactly four square primitives")
    table.sort(squares, function(left, right)
      return left.x < right.x
    end)
    for index = 2, 4 do
      Assert.equal(squares[index].x - squares[index - 1].x, 14, "the 8px squares keep 6px gaps")
    end
    local accentCount = 0
    local activeIndex
    for index, square in ipairs(squares) do
      if colorMatches(square.color, { 0.984, 0, 0.573, 1 }) then
        accentCount = accentCount + 1
        activeIndex = index - 1
      end
    end
    Assert.equal(accentCount, 1, "one accent square advances through the primitive")
    App.state.loading:update(0.12)
    local firstAdvancedRectangle = #result.rectangles + 1
    App.draw()
    local advanced = {}
    for index = firstAdvancedRectangle, #result.rectangles do
      local rectangle = result.rectangles[index]
      if rectangle.mode == "fill" and rectangle.width == 8 and rectangle.height == 8 then
        advanced[#advanced + 1] = rectangle
      end
    end
    table.sort(advanced, function(left, right)
      return left.x < right.x
    end)
    Assert.equal(#advanced, 4, "the same four-square primitive advances without changing geometry")
    local advancedIndex
    for index, square in ipairs(advanced) do
      if colorMatches(square.color, { 0.984, 0, 0.573, 1 }) then
        advancedIndex = index - 1
      end
    end
    Assert.equal(advancedIndex, (activeIndex + 1) % 4, "the accent square advances every 120ms")

    local safe = result.safeRect()
    local x = safe.x + safe.width - 10 - 56
    local y = safe.y + safe.height - 10 - 22
    App.touchpressed("drag", x, y)
    App.touchmoved("drag", safe.x + 20, safe.y + 20)
    App.touchreleased("drag", safe.x + 20, safe.y + 20)
    Assert.equal(App.selectedVersionId, "heartgold", "press-drag-away cannot cancel neutral loading")
    App.touchpressed("finger", x, y)
    App.touchreleased("finger", x, y)
    Assert.isNil(App.selectedVersionId, "touch Cancel retires the selected loading epoch")
    Assert.equal(
      getmetatable(App.state).__index,
      require("app.src.launcher.GameSelectState"),
      "Cancel returns to game selection"
    )
    Assert.deepEqual(result.quitCodes, {}, "loading Cancel never quits the process")

    App._selectVersion("heartgold")
    App.gamepadpressed({}, "a")
    Assert.isNil(App.selectedVersionId, "gamepad activation can cancel neutral loading")
    Assert.equal(getmetatable(App.state).__index, require("app.src.launcher.GameSelectState"))
  end)
end

return { tests = T }
