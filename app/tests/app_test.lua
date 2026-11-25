-- App shell state replacement tests. App.setState is the single transition point
-- between top-level states: it must dispose the previous state exactly once,
-- tolerate states without a disposal hook (the one centralized optional
-- check), and guarantee application quit can never dispose a state twice.
-- Import sessions are single-use: a file drop must always enter a fresh
-- import session through the import state and never invoke an importer left
-- over from a previous session.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")
local RomImporter = require("romdump.src.source.RomImporter")
local HgssGame = require("game.hgss.src.HgssGame")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local SourceTick = require("libs.hgss.src.field.SourceTick")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local StartupAudioSession = require("app.src.audio.StartupAudioSession")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local defaultAppBackend = ProducerFingerprint.appBackend
local defaultCheckoutBackend = ProducerFingerprint.checkoutBackend

local App
local GameSelectState

local function loadShellModules()
  local ok, appOrError = pcall(require, "app.src.App")
  Assert.isTrue(ok, "the app shell must provide app.src.App: " .. tostring(appOrError))
  App = appOrError
  local okSelect, selectOrError = pcall(require, "app.src.launcher.GameSelectState")
  Assert.isTrue(okSelect, "the app shell must own its game selection state: " .. tostring(selectOrError))
  GameSelectState = selectOrError
end

local T = {}

-- A contract state that counts disposal invocations.
local function countingState()
  local state = { disposed = 0 }
  function state:dispose()
    self.disposed = self.disposed + 1
  end
  return state
end

local function minimalSourceBackend()
  return {
    list = function()
      return {}
    end,
    read = function()
      error("the empty source fixture has no files")
    end,
    getInfo = function(path)
      if path == "romdump/src" then
        return { type = "directory" }
      end
      return nil
    end,
  }
end

-- Clear module state so tests are independent of each other and of the boot
-- flow tests.
local function fresh()
  loadShellModules()
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  if App.service ~= nil then
    pcall(function()
      App.service:shutdown()
    end)
  end
  App.service = nil
  if App._assetRuntime ~= nil then
    pcall(App._releaseAssetRuntime, App)
  end
  App._assetRuntime = nil
  App.pendingQuiesce = nil
  App.epoch = 0
  App.selectedVersionId = nil
  App._rebindVersionId = nil
  App._bootBlockedVersionId = nil
  App._startupWarmup = nil
  App._saveLocationWarmup = nil
  App._selectedEntryLocation = nil
  App._libraryMetadata = nil
  App._bootPending = false
  App._bootSwallowedInputs = {}
  App.drawableWidth = nil
  App.drawableHeight = nil
  App.pixelRatio = nil
  App._safeRect = nil
  App._touchGamepadSuspended = false
  App._suspendedTouchIds = {}
  if App._touchGamepad ~= nil then
    pcall(App._touchGamepad.setTarget, App._touchGamepad, nil)
    App._touchGamepad = nil
  end
end

-- One harness for every App-level seam a test can touch: fresh module state,
-- the App opts the boot/draw paths read, the RomImporter.isReady seam, a
-- captured HgssGame.new launch, and a graphics.print/quit spy. Every stub is
-- restored on every path, so no test leaks options or stubs into the next.
---@class AppStateHarness
---@field prints integer
---@field state table
---@field launches table[]
---@field selectOptions table[]
---@field quitCodes integer[]
---@field provisionerDisposals integer
---@field warmups integer
---@field cannedGeneration string? controller-derived generation token answered for the selection
---@field service table scripted process cache service behind the selection
---@field firstPlayReady boolean scripted installed first-play fact for the selected epoch
---@field firstPlayPublished table[] recorded first-play facts, one entry per recorded epoch
---@param opts table|nil
---@param ready fun(id: string): boolean
---@param fn fun(result: AppStateHarness)
---@return AppStateHarness
local function withAppHarness(opts, ready, fn)
  love.filesystem.remove("app-edition.lua")
  love.filesystem.remove("app-edition.lua.tmp")
  fresh()
  local originalOpts = App.opts
  local originalIsReady = RomImporter.isReady
  local originalIsRegistered = RomImporter.isRegistered
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local originalRecoverable = CacheArchive.recoverableFileName
  local originalNew = HgssGame.new
  local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
  local originalMenuNew = MainMenuComposition.new
  local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")
  local LauncherLoadingPresentation = require("app.src.launcher.LauncherLoadingPresentation")
  local StartupAudioSession = require("app.src.audio.StartupAudioSession")
  local originalTitleNew = HgssTitleScene.new
  local originalTitleBegin = HgssTitleScene.begin
  local originalLoadingNew = HgssLoadingPresentation.new
  local originalLauncherLoadingNew = LauncherLoadingPresentation.new
  local originalStartupAudioNew = StartupAudioSession.new
  local graphics = love.graphics
  local originalPrint = graphics.print
  local originalGetDimensions = graphics.getDimensions
  local originalGetDPIScale = graphics.getDPIScale
  local originalGetOS = love.system.getOS
  local originalGetSafeArea = love.window.getSafeArea
  local originalQuit = love.event.quit
  -- The harness stands in for the selection flow's chosen walking pair (the
  -- selection flow owns the production assignment): game/editor entry forwards
  -- this immutable choice without reselection.
  local originalPairIndex = App.pairIndex
  App.pairIndex = 1
  local harnessAppBackend = ProducerFingerprint.appBackend
  local harnessCheckoutBackend = ProducerFingerprint.checkoutBackend
  if harnessAppBackend == defaultAppBackend then
    ProducerFingerprint.appBackend = minimalSourceBackend
  end
  if harnessCheckoutBackend == defaultCheckoutBackend then
    ProducerFingerprint.checkoutBackend = function()
      return minimalSourceBackend()
    end
  end
  local result = {
    prints = 0,
    state = countingState(),
    launches = {},
    menus = {},
    selectOptions = {},
    quitCodes = {},
    provisionerDisposals = 0,
    warmups = 0,
    cannedGeneration = "test-generation",
    firstPlayReady = true,
    alreadyRegistered = false,
    firstPlayPublished = {},
    retiredEpochs = {},
    loaders = {},
  }
  local epoch = 0
  local service = {}
  function service:select(options)
    epoch = epoch + 1
    result.selectOptions[#result.selectOptions + 1] = options
    return epoch
  end
  function service:request(_, _) end
  function service:observe(_, selector)
    if selector.requestKind == "milestone" and selector.name == "bootstrap" then
      return true, nil
    end
    if selector.requestKind == "milestone" and selector.name == "startup-title" then
      return result.startupTitleReady == true, nil
    end
    -- Movie admission acknowledges the soundtrack; the harness models that
    -- milestone as ready beside the title so the handoff journey runs without
    -- audio fixtures.
    if selector.requestKind == "milestone" and selector.name == "startup-audio" then
      return true, nil
    end
    -- The locked cinematic journey runs the five opening scenes before the
    -- legendary title: the harness models a healthy worker by answering the
    -- numbered scene demands beside title readiness, so the instant movie
    -- below completes and the title adopts without GPU fixtures.
    if selector.requestKind == "opening-scene" then
      return result.startupTitleReady == true, nil
    end
    return nil, nil
  end
  function service:enableSweep(_)
    result.warmups = result.warmups + 1
  end
  function service:setExecutionPolicy(epoch, loading)
    result.executionPolicies = result.executionPolicies or {}
    result.executionPolicies[#result.executionPolicies + 1] = { epoch = epoch, loading = loading }
  end
  function service:offerSource(_, _, _)
    result.offers = (result.offers or 0) + 1
    return true
  end
  function service:requestBootSource(_)
    result.bootGates = (result.bootGates or 0) + 1
    return true
  end
  function service:bootSourceStatus(_)
    return result.bootStatus or "ready", result.bootDetail
  end
  function service:update() end
  function service:retire(retiredEpoch)
    result.provisionerDisposals = result.provisionerDisposals + 1
    -- Retiring an epoch revokes its installed view and identity, exactly as the
    -- process service does: a stale epoch never hands out a reader again.
    result.retiredEpochs[retiredEpoch] = true
  end
  function service:quiesce(_)
    return 1
  end
  function service:barrierStatus(_, _)
    return "pending"
  end
  function service:generationId(_)
    return result.cannedGeneration
  end
  function service:importSource(_, _)
    return false, "unacknowledged"
  end
  function service:shutdown() end
  -- The selected epoch's installed generated view: the harness models an
  -- epoch that installed its bytes, so compositions receive one shared
  -- reader object instead of opening a physical generated root. Every
  -- generated consumer is stubbed at this boundary, so the view holds no
  -- payloads. The selection's overlay is a second reader over that same base,
  -- exactly as the App composes one per selected epoch.
  result.generatedView = { versionId = "heartgold" }
  function result.generatedView:resolveAsset(_)
    return nil
  end
  function result.generatedView:loadLua(_)
    return nil, "the harness view carries no generated payloads"
  end
  result.selectedView = { versionId = "heartgold", base = result.generatedView }
  function result.selectedView:resolveAsset(path)
    return result.generatedView:resolveAsset(path)
  end
  function result.selectedView:loadLua(path)
    return result.generatedView:loadLua(path)
  end
  function result.generatedView:withPackages(packageSet)
    result.overlayPackages = packageSet
    return result.selectedView
  end
  function service:getCacheFs(epoch)
    if result.retiredEpochs[epoch] then
      return nil
    end
    return result.generatedView
  end
  -- The installed cache identity every generated byte was produced under: the
  -- selection validates its package manifests against exactly these fields.
  result.cacheIdentity = {
    schema = "derived-cache",
    versionId = "heartgold",
    romSha1 = string.rep("0", 40),
    mode = "release",
    producerId = "harness",
    assetRevision = 19,
    scriptApi = 1,
    generationId = result.cannedGeneration,
  }
  function service:cacheIdentity(epoch)
    if result.retiredEpochs[epoch] then
      return nil
    end
    return result.cacheIdentity
  end
  function service:firstPlayReady(_)
    return result.firstPlayReady == true
  end
  function service:recordFirstPlay(epoch)
    result.firstPlayPublished[#result.firstPlayPublished + 1] = { epoch = epoch }
  end
  result.service = service
  local unownedOption = {}
  App.opts = setmetatable(opts or { dev = false }, {
    __index = function(_, key)
      if key == "dev" then
        return false
      end
      return unownedOption
    end,
  })
  App.service = service
  RomImporter.isReady = ready
  -- Candidate registration is scripted per test: the shared save root may
  -- carry a real snapshot, which must not widen the harness's shelf.
  CacheArchive.recoverableFileName = function(versionId)
    local present = result.snapshotVersions
    return present ~= nil and present[versionId] == true and "cache.zip" or nil
  end
  RomImporter.isRegistered = function(_, _)
    return result.alreadyRegistered
  end
  HgssGame.new = function(options)
    result.launches[#result.launches + 1] = options
    if result.launchFailure ~= nil then
      error(result.launchFailure, 0)
    end
    return result.game or result.state
  end
  MainMenuComposition.new = function(options)
    local menu = countingState()
    menu.options = options
    function menu:draw() end
    result.menus[#result.menus + 1] = menu
    return menu
  end
  -- The boot wait owns a themed presentation whose adoption needs
  -- generated fixtures this harness never builds: model an instantly
  -- drawable pair so cold flows exercise the real request/adopt/transfer
  -- path instead of stalling on missing GPU art.
  HgssLoadingPresentation.new = function(options)
    local presentation = {
      versionId = options and options.versionId,
      pairIndex = options and options.pairIndex,
      adopted = false,
      adoptions = 0,
      draws = 0,
      disposals = 0,
    }
    function presentation:update() end
    function presentation:resize() end
    function presentation:draw()
      self.draws = self.draws + 1
    end
    function presentation:dispose()
      self.disposals = self.disposals + 1
    end
    function presentation:adoptGeneratedAssets()
      self.adoptions = self.adoptions + 1
      self.adopted = true
      return true
    end
    return presentation
  end
  LauncherLoadingPresentation.new = function(options)
    local presentation = {
      versionId = options and options.versionId,
      draws = 0,
      disposals = 0,
    }
    function presentation:update() end
    function presentation:resize() end
    function presentation:draw()
      self.draws = self.draws + 1
    end
    function presentation:dispose()
      self.disposals = self.disposals + 1
    end
    result.loaders[#result.loaders + 1] = presentation
    return presentation
  end
  StartupAudioSession.new = function()
    local session = { disposals = 0 }
    function session:bindTitleRecord(record)
      self.titleRecord = record
    end
    function session:beginOpening()
      return true
    end
    function session:beginTitle() end
    function session:notifySkip() end
    function session:beginFade() end
    function session:beginMovieCycle() end
    function session:playMenuCue() end
    function session:update() end
    function session:dispose()
      self.disposals = self.disposals + 1
    end
    return session
  end
  -- The launcher stages the title through its build task, so the harness
  -- stands in there: the title is realized on the first advance and transfers
  -- like the real build.
  HgssTitleScene.begin = function()
    local title = { updates = 0, draws = 0, disposals = 0, bundle = { crySpeciesId = 25 } }
    function title:updateFixed()
      self.updates = self.updates + 1
    end
    function title:draw()
      self.draws = self.draws + 1
    end
    function title:dispose()
      self.disposals = self.disposals + 1
    end
    function title:resize() end
    function title:beginProceed() end
    local build = { _ready = false, _taken = false }
    function build:advance(_)
      self._ready = true
      return 1
    end
    function build:isReady()
      return self._ready
    end
    function build:takeResult()
      self._taken = true
      return title
    end
    function build:release()
      title:dispose()
    end
    return build
  end
  -- The harness models the locked movie-first journey with an instantly
  -- finished movie and canned validated scene manifests: the flow under
  -- test is the title/menu handoff, not scene playback (covered by the
  -- dedicated movie suites), so no GPU scene fixtures are built here.
  local HgssOpeningMovie = require("libs.hgss.src.presentation.HgssOpeningMovie")
  local originalMovieNew = HgssOpeningMovie.new
  HgssOpeningMovie.new = function(_)
    local movie = { disposals = 0 }
    function movie:updateFixed() end
    function movie:draw() end
    function movie:resize() end
    function movie:isFinished()
      return true
    end
    function movie:skipAllowed()
      return false
    end
    function movie:requestSkip()
      return false
    end
    function movie:sceneNumber()
      return 5
    end
    function movie:dispose()
      self.disposals = self.disposals + 1
    end
    return movie
  end
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
  local originalLoadOpeningScene = StartupAssetCache.loadOpeningScene
  StartupAssetCache.loadOpeningScene = function(_, sceneNumber, versionId)
    return {
      sceneNumber = sceneNumber,
      versionId = versionId,
      generationId = "test-generation",
      schema = "g4-startup-opening-scene-v1",
    }
  end
  graphics.print = function()
    result.prints = result.prints + 1
  end
  graphics.getDimensions = function()
    return result.hostWidth or 800, result.hostHeight or 600
  end
  graphics.getDPIScale = function()
    return result.pixelRatio or 1
  end
  love.system.getOS = function()
    return result.osName or originalGetOS()
  end
  love.window.getSafeArea = function()
    result.safeAreaReads = (result.safeAreaReads or 0) + 1
    local safe = result.safeRect or { 0, 0, result.hostWidth or 800, result.hostHeight or 600 }
    return safe[1], safe[2], safe[3], safe[4]
  end
  -- The startup journey admits the movie only behind an acknowledged
  -- soundtrack: one silent session stands in for the selected edition's audio
  -- so the title/menu handoff never depends on audio fixtures.
  local originalStartupAudioNew = StartupAudioSession.new
  StartupAudioSession.new = function()
    local session = { disposed = false }
    function session:beginOpening()
      return true
    end
    function session:beginTitle() end
    function session:notifySkip() end
    function session:beginFade() end
    function session:beginMovieCycle() end
    function session:playMenuCue() end
    function session:update() end
    function session:dispose()
      self.disposed = true
    end
    return session
  end
  love.event.quit = function(code)
    result.quitCodes[#result.quitCodes + 1] = code
  end
  local ok, err = pcall(fn, result)
  if App.state ~= nil then
    App.setState(nil)
  end
  if App.provisioner ~= nil then
    App._retireSelection()
  end
  App.opts = originalOpts
  RomImporter.isReady = originalIsReady
  RomImporter.isRegistered = originalIsRegistered
  CacheArchive.recoverableFileName = originalRecoverable
  HgssGame.new = originalNew
  HgssOpeningMovie.new = originalMovieNew
  StartupAssetCache.loadOpeningScene = originalLoadOpeningScene
  App.pairIndex = originalPairIndex
  MainMenuComposition.new = originalMenuNew
  HgssTitleScene.new = originalTitleNew
  HgssTitleScene.begin = originalTitleBegin
  HgssLoadingPresentation.new = originalLoadingNew
  LauncherLoadingPresentation.new = originalLauncherLoadingNew
  StartupAudioSession.new = originalStartupAudioNew
  graphics.print = originalPrint
  graphics.getDimensions = originalGetDimensions
  graphics.getDPIScale = originalGetDPIScale
  love.system.getOS = originalGetOS
  love.window.getSafeArea = originalGetSafeArea
  love.event.quit = originalQuit
  StartupAudioSession.new = originalStartupAudioNew
  App.startupAudioError = nil
  ProducerFingerprint.appBackend = harnessAppBackend
  ProducerFingerprint.checkoutBackend = harnessCheckoutBackend
  love.filesystem.remove("app-edition.lua")
  love.filesystem.remove("app-edition.lua.tmp")
  if not ok then
    error(err, 0)
  end
  return result
end

local function assertStagedStartupMenu(result)
  local StartupTitleState = require("app.src.launcher.StartupTitleState")
  for _ = 1, 3 do
    if getmetatable(App.state).__index == StartupTitleState and App.state.stagedMenu ~= nil then
      break
    end
    App.update(SourceTick.DT)
  end
  Assert.equal(getmetatable(App.state).__index, StartupTitleState, "selection remains under startup title ownership")
  Assert.equal(App.state.stagedMenu, result.menus[#result.menus], "title stages the exact product menu")
end

local function finishStartupTitle(result)
  result.startupTitleReady = true
  assertStagedStartupMenu(result)
  -- The realized title follows the admitted opening: a true first import spends
  -- its bounded loader beat before the movie is admitted at all.
  for _ = 1, 200 do
    if App.state.phase == "title" and App.state.title ~= nil then
      break
    end
    App.update(SourceTick.DT)
  end
  Assert.notNil(App.state.title, "title readiness adopts the renderer before skip")
  Assert.equal(App.state.phase, "title", "the realized title presents after the opening")
  -- The adopted title spends the retail start-up calls behind white before
  -- its first animation call reads input.
  for _ = 1, 10 do
    if App.state.titleAnimating then
      break
    end
    App.update(SourceTick.DT)
  end
  Assert.isTrue(App.state.titleAnimating, "the adopted title reaches its first animation call")
  App.keypressed("return")
  for _ = 1, 80 do
    local metatable = getmetatable(App.state)
    if metatable == nil or metatable.__index ~= require("app.src.launcher.StartupTitleState") then
      break
    end
    App.update(SourceTick.DT)
  end
  Assert.equal(
    App.state,
    result.menus[#result.menus],
    "skip transfers the same staged menu (phase "
      .. tostring(App.state.phase)
      .. ", frame "
      .. tostring(App.state.fadeFrame)
      .. ")"
  )
end

---@param appBackend fun(): ProducerSourceTree
---@param checkoutBackend fun(repositoryRoot: string): ProducerSourceTree
---@param fn fun()
local function withProducerBackends(appBackend, checkoutBackend, fn)
  local originalAppBackend = ProducerFingerprint.appBackend
  local originalCheckoutBackend = ProducerFingerprint.checkoutBackend
  ProducerFingerprint.appBackend = appBackend
  ProducerFingerprint.checkoutBackend = checkoutBackend
  local ok, err = pcall(fn)
  ProducerFingerprint.appBackend = originalAppBackend
  ProducerFingerprint.checkoutBackend = originalCheckoutBackend
  if not ok then
    error(err, 0)
  end
end

---@param root string
---@param fn fun()
local function withSourceBaseDirectory(root, fn)
  local fs = love.filesystem
  local original = fs.getSourceBaseDirectory
  fs.getSourceBaseDirectory = function()
    return root
  end
  local ok, err = pcall(fn)
  fs.getSourceBaseDirectory = original
  if not ok then
    error(err, 0)
  end
end

---@param files table<string, string>
---@return ProducerSourceTree
local function fakeSourceBackend(files)
  return {
    list = function()
      local paths = {}
      for path in pairs(files) do
        paths[#paths + 1] = path
      end
      table.sort(paths, function(left, right)
        return left > right
      end)
      return paths
    end,
    read = function(path)
      return assert(files[path])
    end,
    getInfo = function(path)
      if path == "romdump/src" then
        return { type = "directory" }
      end
      return nil
    end,
  }
end

-- An importer stand-in in a given state. App reads isBusy()/state and forwards
-- drops; a terminal (complete/error) stand-in models an importer left over
-- from a finished session.
local function importerStub(state, busy)
  local importer = {
    state = state,
    busy = busy or false,
    filedroppedCalls = 0,
  }
  function importer:isBusy()
    return self.busy
  end
  function importer:filedropped()
    self.filedroppedCalls = self.filedroppedCalls + 1
  end
  return importer
end

-- A minimal dropped-file stand-in satisfying RomSource.fromDroppedFile's
-- protocol. The bytes are not a ROM, so a real importer routes the drop into
-- its reading state without touching the filesystem or caches.
local function droppedFile()
  return {
    getFilename = function()
      return "dropped.nds"
    end,
    open = function()
      return true
    end,
    read = function()
      return "not a real rom"
    end,
    close = function() end,
  }
end

local function publishedSave(saveId, versionId)
  return require("tests.support.PublishedSaveFixture").new(saveId, versionId)
end

local function recordingGameChild(events)
  local child = { disposed = 0 }
  local function record(kind, ...)
    events[#events + 1] = { kind, ... }
  end
  function child:gamepadpressed(joystick, button)
    record("gamepadpressed", joystick:getID(), button)
  end
  function child:gamepadreleased(joystick, button)
    record("gamepadreleased", joystick:getID(), button)
  end
  function child:touchpressed(id, x, y)
    record("touchpressed", id, x, y)
  end
  function child:touchmoved(id, x, y)
    record("touchmoved", id, x, y)
  end
  function child:touchreleased(id, x, y)
    record("touchreleased", id, x, y)
  end
  function child:mousepressed(x, y, button, istouch)
    record("mousepressed", x, y, button, istouch)
  end
  function child:mousemoved(x, y, dx, dy, istouch)
    record("mousemoved", x, y, dx, dy, istouch)
  end
  function child:mousereleased(x, y, button, istouch)
    record("mousereleased", x, y, button, istouch)
  end
  function child:resize(width, height)
    record("resize", width, height)
  end
  function child:focus(focused)
    record("focus", focused)
  end
  function child:dispose()
    self.disposed = self.disposed + 1
    record("dispose")
  end
  return child
end

local function installRecordingGame(result)
  local Game = require("game.src.Game")
  local events = {}
  local game = Game.new({ onExit = function() end })
  game:setState(recordingGameChild(events))
  result.game = game
  App._ensureLauncherResources()
  App._syncDrawableSize()
  App.selectedVersionId = "heartgold"
  App.epoch = assert(result.service:select({ versionId = "heartgold" }))
  App.provisioner = {
    gameHost = function()
      return {}
    end,
    dispose = function()
      result.service:retire(App.epoch)
    end,
  }
  local menu = assert(App._stageMenu("heartgold"))
  App.setState(menu)
  menu.options.onResult({ kind = "new_game" })
  Assert.isTrue(App.state == game, "the menu installs the real generic Game returned by the factory")
  return game, events, assert(result.launches[#result.launches])
end

local function clearEvents(events)
  for index = #events, 1, -1 do
    events[index] = nil
  end
end

function T.android_menu_entry_routes_controls_to_the_real_game_and_preserves_native_touch()
  withAppHarness({ dev = false }, function()
    return false
  end, function(result)
    result.osName = "Android"
    result.hostWidth, result.hostHeight = 360, 800
    result.pixelRatio = 2
    App._ensureLauncherResources()
    App._syncDrawableSize()
    App.selectedVersionId = "heartgold"
    App.epoch = assert(result.service:select({ versionId = "heartgold" }))
    App.provisioner = {
      gameHost = function()
        return {}
      end,
      dispose = function()
        result.service:retire(App.epoch)
      end,
    }
    local menu = assert(App._stageMenu("heartgold"))
    local launcherEvents = {}
    function menu:touchpressed(id, x, y)
      launcherEvents[#launcherEvents + 1] = { "pressed", id, x, y }
    end
    function menu:touchmoved(id, x, y)
      launcherEvents[#launcherEvents + 1] = { "moved", id, x, y }
    end
    function menu:touchreleased(id, x, y)
      launcherEvents[#launcherEvents + 1] = { "released", id, x, y }
    end
    App.setState(menu)
    App.touchpressed(90, 100, 100)
    App.touchpressed(91, 56, 672)
    Assert.deepEqual(launcherEvents, {
      { "pressed", 90, 100, 100 },
      { "pressed", 91, 56, 672 },
    }, "launcher touch never acquires gamepad chrome, even at a control position")

    local Game = require("game.src.Game")
    local events = {}
    local game = Game.new({ onExit = function() end })
    game:setState(recordingGameChild(events))
    result.game = game
    menu.options.onResult({ kind = "new_game" })
    Assert.isTrue(App.state == game, "the App binds the successful real Game from its existing factory seam")
    local launch = assert(result.launches[1])

    App.touchpressed(1, 56, 672)
    App.touchreleased(1, 56, 672)
    App.touchpressed(2, 328, 720)
    App.touchreleased(2, 328, 720)
    App.touchpressed(3, 280, 672)
    App.touchreleased(3, 280, 672)
    App.touchpressed(4, 224, 616)
    App.touchreleased(4, 224, 616)
    App.touchpressed(9, 180, 500)
    App.touchmoved(9, 280, 720)
    App.touchreleased(9, 280, 720)
    Assert.deepEqual(events, {
      { "gamepadpressed", -1, "dpup" },
      { "gamepadreleased", -1, "dpup" },
      { "gamepadpressed", -1, "a" },
      { "gamepadreleased", -1, "a" },
      { "gamepadpressed", -1, "x" },
      { "gamepadreleased", -1, "x" },
      { "gamepadpressed", -1, "start" },
      { "gamepadreleased", -1, "start" },
      { "touchpressed", 9, 180, 500 },
      { "touchmoved", 9, 280, 720 },
      { "touchreleased", 9, 280, 720 },
    }, "controls use normal gamepad edges while an outside gesture remains native for its lifetime")
    Assert.equal(type(launch.topologyProvider), "function", "Android publishes reservations before retail presentation")
    local topology = launch.topologyProvider(360, 800)
    Assert.deepEqual(topology.surfaces[1].safeRect, { x = 0, y = 0, width = 360, height = 800 })
    Assert.deepEqual(topology.surfaces[1].occupiedRegions, { { x = 0, y = 584, width = 360, height = 216 } })

    App.touchpressed(5, 224, 616)
    game:exit({ kind = "main_menu" })
    clearEvents(events)
    local selection = assert(App.state)
    function selection:touchmoved(id, x, y)
      launcherEvents[#launcherEvents + 1] = { "selection moved", id, x, y }
    end
    function selection:touchreleased(id, x, y)
      launcherEvents[#launcherEvents + 1] = { "selection released", id, x, y }
    end
    App.touchmoved(5, 280, 720)
    App.touchreleased(5, 280, 720)
    Assert.deepEqual(events, {}, "a former control tail cannot release into game selection or its replacement")
    Assert.equal(#launcherEvents, 2, "the launcher receives no duplicate control gesture")
  end)
end

function T.desktop_menu_entry_has_no_virtual_controls_or_reservations()
  withAppHarness({ dev = false }, function()
    return false
  end, function(result)
    result.osName = "Linux"
    result.hostWidth, result.hostHeight = 360, 800
    local _, events, launch = installRecordingGame(result)
    Assert.isNil(launch.topologyProvider, "desktop composition retains its existing topology path")
    App.touchpressed(1, 56, 672)
    App.touchreleased(1, 56, 672)
    Assert.deepEqual(events, {
      { "touchpressed", 1, 56, 672 },
      { "touchreleased", 1, 56, 672 },
    }, "desktop receives only the original native pointer callbacks")
  end)
end

function T.android_safe_area_only_change_cancels_once_before_one_resize()
  withAppHarness({ dev = false }, function()
    return false
  end, function(result)
    result.osName = "Android"
    result.hostWidth, result.hostHeight = 360, 800
    result.safeRect = { 0, 0, 360, 800 }
    local _, events = installRecordingGame(result)
    App.touchpressed(1, 56, 672)
    clearEvents(events)
    result.safeRect = { 12, 20, 336, 780 }
    result.safeAreaReads = 0
    App.update(1 / 60)
    App.update(1 / 60)
    Assert.equal(
      result.safeAreaReads,
      2,
      "safe-area-only invalidation is observed through the ordinary App update path"
    )
    Assert.deepEqual(events, {
      { "gamepadreleased", -1, "dpup" },
      { "resize", 360, 800 },
    }, "same-size inset changes cancel before exactly one structural resize")
    clearEvents(events)
    App.touchpressed(2, 68, 672)
    App.touchreleased(2, 68, 672)
    Assert.deepEqual(events, {
      { "gamepadpressed", -1, "dpup" },
      { "gamepadreleased", -1, "dpup" },
    }, "fresh input uses the newly published safe-area plan")
  end)
end

function T.android_focus_loss_cancels_before_the_live_child_and_swallows_touch_mouse_companions()
  withAppHarness({ dev = false }, function()
    return false
  end, function(result)
    result.osName = "Android"
    result.hostWidth, result.hostHeight = 360, 800
    local _, events = installRecordingGame(result)
    App.touchpressed(1, 328, 720)
    clearEvents(events)
    App.focus(false)
    Assert.deepEqual(events, {
      { "gamepadreleased", -1, "a" },
      { "focus", false },
    }, "virtual cancellation precedes live child focus loss")
    App.focus(true)
    clearEvents(events)
    App.touchmoved(1, 328, 720)
    App.touchreleased(1, 328, 720)
    App.mousepressed(280, 720, 1, true)
    App.mousemoved(281, 720, 1, 0, true)
    App.mousereleased(281, 720, 1, true)
    Assert.deepEqual(events, {}, "stale control tails and touch-generated mouse companions are inert")
    App.mousepressed(20, 100, 1, false)
    Assert.deepEqual(
      events,
      { { "mousepressed", 20, 100, 1, false } },
      "genuine mouse input retains its existing route"
    )
  end)
end

function T.android_nonpresentable_interval_releases_without_a_zero_resize_and_recovers()
  withAppHarness({ dev = false }, function()
    return false
  end, function(result)
    result.osName = "Android"
    result.hostWidth, result.hostHeight = 360, 800
    local _, events = installRecordingGame(result)
    App.touchpressed(1, 56, 672)
    clearEvents(events)
    result.hostWidth, result.hostHeight = 0, 0
    App.update(1 / 60)
    Assert.deepEqual(
      events,
      { { "gamepadreleased", -1, "dpup" } },
      "a nonpresentable host releases holds without resizing to zero"
    )
    clearEvents(events)
    App.touchpressed(2, 180, 500)
    App.touchmoved(2, 280, 720)
    Assert.deepEqual(events, {}, "touches first seen while nonpresentable establish no live input")
    clearEvents(events)
    result.hostWidth, result.hostHeight = 360, 800
    App.update(1 / 60)
    Assert.deepEqual(events, { { "resize", 360, 800 } }, "positive dimensions resume geometry publication once")
    App.touchmoved(2, 280, 720)
    App.touchreleased(2, 280, 720)
    Assert.deepEqual(
      events,
      { { "resize", 360, 800 } },
      "the suspended touch tail stays consumed after geometry resumes"
    )
    clearEvents(events)
    App.touchpressed(2, 56, 672)
    App.touchreleased(2, 56, 672)
    Assert.deepEqual(events, {
      { "gamepadpressed", -1, "dpup" },
      { "gamepadreleased", -1, "dpup" },
    }, "a fresh down after resume starts a new lifetime even when the host reuses the ID")
  end)
end

function T.android_detach_releases_the_live_game_before_disposal()
  withAppHarness({ dev = false }, function()
    return false
  end, function(result)
    result.osName = "Android"
    result.hostWidth, result.hostHeight = 360, 800
    local game, events = installRecordingGame(result)
    App.touchpressed(1, 328, 720)
    clearEvents(events)
    App.setState(nil)
    Assert.deepEqual(events, {
      { "gamepadreleased", -1, "a" },
      { "dispose" },
    }, "ordinary App detach cancels through the live child before Game disposal")
    Assert.isTrue(game.terminal)
    clearEvents(events)
    App.touchreleased(1, 328, 720)
    Assert.deepEqual(events, {}, "the detached gesture tail cannot reach a later App state")
  end)
end

function T.android_quit_cancels_before_game_and_renderer_teardown()
  withAppHarness({ dev = false }, function()
    return false
  end, function(result)
    result.osName = "Android"
    result.hostWidth, result.hostHeight = 360, 800
    local _, events = installRecordingGame(result)
    App.touchpressed(1, 328, 720)
    clearEvents(events)
    App.quit()
    Assert.deepEqual(events, {
      { "gamepadreleased", -1, "a" },
      { "dispose" },
    }, "quit releases virtual holds before disposing the live Game")
    Assert.isNil(App.launcherRenderer, "renderer disposal remains owned by App")
    Assert.isNil(App.state)
  end)
end

function T.android_failed_game_construction_leaves_no_control_target()
  withAppHarness({ dev = false }, function()
    return false
  end, function(result)
    result.osName = "Android"
    result.hostWidth, result.hostHeight = 360, 800
    App._ensureLauncherResources()
    App._syncDrawableSize()
    App.selectedVersionId = "heartgold"
    App.epoch = assert(result.service:select({ versionId = "heartgold" }))
    App.provisioner = {
      gameHost = function()
        return {}
      end,
      dispose = function() end,
    }
    local menu = assert(App._stageMenu("heartgold"))
    App.setState(menu)
    result.launchFailure = "synthetic construction failure"
    local ok = pcall(function()
      menu.options.onResult({ kind = "new_game" })
    end)
    Assert.isFalse(ok, "the existing construction error remains authoritative")
    local selection = assert(App.state)
    local touches = 0
    local originalTouch = selection.touchpressed
    function selection:touchpressed(...)
      touches = touches + 1
      return originalTouch(self, ...)
    end
    App.touchpressed(1, 56, 672)
    Assert.equal(touches, 1, "a failed construction leaves the selection as the native touch owner")
  end)
end

local function completedSyntheticImporter(versionId)
  local NdsBuilder = require("tests.support.NdsBuilder")
  local DumpFixture = require("tests.support.DumpFixture")
  local RomSource = require("romdump.src.source.RomSource")
  local CacheFs = require("libs.storage.src.CacheFs")
  local data = NdsBuilder.build(DumpFixture.spec())
  local sha1 = RomSource.fromString(data):sha1()
  local info = {
    id = versionId,
    label = versionId == "heartgold" and "HeartGold" or "SoulSilver",
    displayName = versionId == "heartgold" and "Pokemon HeartGold" or "Pokemon SoulSilver",
    sha1 = sha1,
    gameCode = "IPKE",
    expectedSize = #data,
    cachePrefix = versionId .. "/",
  }
  local versions = {
    info = function(id)
      return id == info.id and info or nil
    end,
    forSha1 = function(value)
      return value == sha1 and info or nil
    end,
    forGameCode = function(value)
      return value == info.gameCode and info or nil
    end,
  }
  local backend = FakeCache.new()
  local importer = RomImporter.new({
    versions = versions,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, backend)
    end,
  })
  importer:startSource(RomSource.fromString(data, versionId .. ".nds"))
  for _ = 1, 10000 do
    importer:update()
    if importer.state == RomImporter.STATES.COMPLETE or importer.state == RomImporter.STATES.ERROR then
      break
    end
  end
  Assert.equal(importer.state, RomImporter.STATES.COMPLETE, "the real importer validates the synthetic source")
  return importer
end

local function withPublishedSaves(backend, fn)
  local SaveFs = require("libs.storage.src.SaveFs")
  local originalGlobal = SaveFs.global
  SaveFs.global = function()
    return originalGlobal(backend)
  end
  local ok, err = xpcall(fn, debug.traceback)
  SaveFs.global = originalGlobal
  if not ok then
    error(err, 0)
  end
end

function T.starting_an_import_disposes_the_active_field_state()
  fresh()
  local field = countingState()
  App.setState(field)
  App.saveDir = nil
  App._startImport()
  Assert.equal(field.disposed, 1)
  Assert.equal(getmetatable(App.state).__index, GameSelectState)
  Assert.notNil(App.importer)
end

-- LÖVE keeps the draw color across frames: a state that last drew with a
-- tint must not tint the next state's frame.
function T.app_draw_starts_every_frame_from_white()
  withAppHarness({ dev = false }, function()
    return false
  end, function()
    local graphics = love.graphics
    local original = graphics.setColor
    local color
    graphics.setColor = function(red, green, blue, alpha)
      color = { red, green, blue, alpha }
    end
    local seen
    App.state = {
      draw = function()
        seen = color
      end,
    }
    local ok, err = pcall(App.draw)
    graphics.setColor = original
    assert(ok, err)
    Assert.deepEqual(seen, { 1, 1, 1, 1 }, "the state draws on a white color")
  end)
end

-- The bare "portemon" draw is developer branding on an empty frame: product
-- mode draws nothing, dev mode keeps the emergency text.
function T.app_draw_keeps_the_emergency_brand_text_only_in_dev_mode()
  for _, dev in ipairs({ false, true }) do
    local result = withAppHarness({ dev = dev }, function()
      return false
    end, function()
      App.draw()
    end)
    local expected = 0
    if dev then
      expected = 1
    end
    Assert.equal(result.prints, expected, "brand text on an empty frame tracks dev mode")
  end
end

function T.ratio_only_display_change_invalidates_once_before_update()
  withAppHarness({ dev = false }, function()
    return false
  end, function()
    local graphics = love.graphics
    local originalGetDimensions = graphics.getDimensions
    local originalGetDPIScale = graphics.getDPIScale
    local dimensions = { 800, 600 }
    local pixelRatio = 1
    local reads, dpiReads, events = 0, 0, {}
    graphics.getDimensions = function()
      reads = reads + 1
      return dimensions[1], dimensions[2]
    end
    graphics.getDPIScale = function()
      dpiReads = dpiReads + 1
      return pixelRatio
    end
    App.drawableWidth, App.drawableHeight = 800, 600
    App.pixelRatio = 1
    App.state = {
      resize = function(_, width, height)
        events[#events + 1] = { "resize", width, height }
      end,
      update = function()
        events[#events + 1] = { "update" }
      end,
      draw = function()
        events[#events + 1] = { "draw" }
      end,
    }
    pixelRatio = 2
    App.update(1 / 60)
    App.update(1 / 60)
    graphics.getDimensions = originalGetDimensions
    graphics.getDPIScale = originalGetDPIScale
    Assert.equal(reads, 2, "each update samples dimensions once")
    Assert.equal(dpiReads, 2, "each update samples DPI once")
    Assert.deepEqual(events, {
      { "resize", 800, 600 },
      { "update" },
      { "update" },
    })
  end)
end

function T.display_sync_reads_once_and_draw_and_explicit_resize_do_not_duplicate_invalidation()
  withAppHarness({ dev = false }, function()
    return false
  end, function()
    local graphics = love.graphics
    local originalGetDimensions = graphics.getDimensions
    local originalGetDPIScale = graphics.getDPIScale
    local width, height, pixelRatio = 800, 600, 1
    local dimensionReads, dpiReads, events = 0, 0, {}
    graphics.getDimensions = function()
      dimensionReads = dimensionReads + 1
      return width, height
    end
    graphics.getDPIScale = function()
      dpiReads = dpiReads + 1
      return pixelRatio
    end
    App.drawableWidth, App.drawableHeight, App.pixelRatio = 640, 480, 1
    App.state = {
      resize = function(_, resizeWidth, resizeHeight)
        events[#events + 1] = { "resize", resizeWidth, resizeHeight }
      end,
      update = function()
        events[#events + 1] = { "update" }
      end,
      draw = function()
        events[#events + 1] = { "draw" }
      end,
    }

    App.update(1 / 60)
    Assert.equal(dimensionReads, 1)
    Assert.equal(dpiReads, 1)
    App.draw()
    Assert.equal(dimensionReads, 1, "draw does not sample dimensions")
    Assert.equal(dpiReads, 1, "draw does not sample DPI")

    pixelRatio = 2
    App.resize(width, height)
    local dpiReadsAfterResize = dpiReads
    App.update(1 / 60)
    graphics.getDimensions = originalGetDimensions
    graphics.getDPIScale = originalGetDPIScale

    Assert.equal(dpiReadsAfterResize, 2, "explicit resize refreshes the retained DPI")
    Assert.equal(dimensionReads, 2, "each sync samples dimensions once")
    Assert.equal(dpiReads, 3, "each sync samples DPI once")
    Assert.deepEqual(events, {
      { "resize", width, height },
      { "update" },
      { "draw" },
      { "resize", width, height },
      { "update" },
    })
  end)
end

-- An import session is single-use. A file drop during gameplay after a
-- finished import (complete or failed) must enter a fresh import session
-- through the import state; the stale importer's completion callback would
-- otherwise replace the active field state unexpectedly, and re-running a
-- failed importer is just as wrong.
function T.drop_after_a_finished_import_starts_a_fresh_session()
  for _, terminalState in ipairs({ "complete", "error" }) do
    fresh()
    local stale = importerStub(terminalState)
    App.importer = stale
    App.setState({})
    App.filedropped(droppedFile())
    Assert.equal(stale.filedroppedCalls, 0, "the stale importer must not be invoked")
    Assert.isFalse(App.importer == stale, "a finished import session must not be reused")
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, GameSelectState)
    Assert.equal(App.state.importer, App.importer)
  end
end

-- Drops while an import is running are ignored: no new session, no forward to
-- the busy importer.
function T.drop_while_busy_is_ignored()
  fresh()
  local busy = importerStub("reading", true)
  App.importer = busy
  local state = {}
  App.setState(state)
  App.filedropped(droppedFile())
  Assert.equal(busy.filedroppedCalls, 0)
  Assert.equal(App.importer, busy)
  Assert.equal(App.state, state)
end

function T.save_editor_routes_only_lua_drops_to_its_preset_entrypoint()
  fresh()
  local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
  local imported, notices = 0, 0
  local editor = setmetatable({
    importPresetFile = function(self, file)
      imported = imported + 1
      self.receivedFile = file
    end,
    onImportAttempt = function()
      notices = notices + 1
    end,
  }, SaveEditorState)
  App.setState(editor)
  local luaFile = {
    getFilename = function()
      return "/tmp/fixture.LUA"
    end,
  }
  App.filedropped(luaFile)
  Assert.equal(imported, 1, "the active Save Editor receives one case-insensitive preset drop")
  Assert.equal(editor.receivedFile, luaFile, "the shell passes the original unopened File object")
  Assert.equal(notices, 0, "a preset drop does not show the ROM-import notice")

  App.filedropped({
    getFilename = function()
      return "fixture.nds"
    end,
  })
  Assert.equal(imported, 1, "other editor file types do not enter preset handling")
  Assert.equal(notices, 1, "other editor file types retain the ROM-import notice")
end

function T.non_editor_lua_drop_keeps_the_existing_rom_import_route()
  withAppHarness({}, function()
    return true
  end, function()
    App.service = nil
    local originalImporterNew = RomImporter.new
    local importer = importerStub("idle")
    RomImporter.new = function()
      return importer
    end
    local ok, err = pcall(function()
      App.filedropped({
        getFilename = function()
          return "ordinary.lua"
        end,
      })
      Assert.equal(importer.filedroppedCalls, 1, "a non-editor Lua drop follows ROM import routing")
      Assert.equal(getmetatable(App.state).__index, GameSelectState, "game selection owns the import variant")
      Assert.equal(App.state.importer, importer)
    end)
    RomImporter.new = originalImporterNew
    if not ok then
      error(err, 0)
    end
  end)
end

-- A terminal importer error remains owned while its borrowed modal is visible.
-- Dropping it in App.update would erase the actionable cause before the player
-- can dismiss it; replacement or dismissal remains the cleanup boundary.
function T.pending_import_worker_lease_is_pumped_and_blocks_a_second_import()
  fresh()
  local importer = {
    state = RomImporter.STATES.IDLE,
    updates = 0,
    isBusy = function()
      return false
    end,
    status = function()
      return { state = RomImporter.STATES.IDLE, canCancel = true }
    end,
    update = function(self)
      self.updates = self.updates + 1
    end,
  }
  App.importer = importer
  App.state = {}
  App.update(1 / 60)
  Assert.equal(importer.updates, 1, "a pending worker lease still advances on the App frame")
  App.filedropped({
    getFilename = function()
      return "second.nds"
    end,
  })
  Assert.isTrue(App.importer == importer, "a pending lease cannot be replaced by a second import")
end

function T.failed_import_is_retained_until_its_error_view_is_dismissed()
  fresh()
  local failure = completedSyntheticImporter("heartgold")
  failure:filedropped({
    getFilename = function()
      return "notes.txt"
    end,
  })
  Assert.equal(failure.state, RomImporter.STATES.ERROR, "the real importer rejects the unsupported file")
  local state = { update = function() end }
  App.importer = failure
  App.setState(state)
  App.update(0.016)
  Assert.isTrue(App.importer == failure, "the terminal error stays available to its visible modal")
  Assert.equal(App.state, state, "polling does not replace the borrowed error view")
end

-- The boot decision with no ROM or save candidate shows the empty library.

function T.boot_existing_with_no_ready_version_shows_empty_selection()
  withAppHarness({}, function()
    return false
  end, function()
    withPublishedSaves(FakeCache.new(), function()
      App._bootExisting()
      Assert.isNil(App.importer, "an empty library starts no importer until the player asks")
      Assert.equal(getmetatable(App.state).__index, GameSelectState)
      Assert.deepEqual(App.state:view().games, {}, "first boot is the empty game library")
    end)
  end)
end
function T.boot_uses_the_newest_published_payload_time_without_loading_a_save()
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold" or versionId == "soulsilver"
  end, function(result)
    local backend = FakeCache.new()
    local modtimes = {}
    local originalGetInfo = backend.getInfo
    function backend:getInfo(path)
      local info = originalGetInfo(self, path)
      if info ~= nil and info.type == "file" then
        info.modtime = modtimes[path]
      end
      return info
    end
    withPublishedSaves(backend, function()
      local Store = require("libs.hgss.src.save.GameSaveStore")
      local store = Store.new(require("libs.storage.src.SaveFs").global())
      local heartgoldId = store:reserve()
      local soulsilverId = store:reserve()
      store:publishFirst(publishedSave(heartgoldId, "heartgold"))
      store:publishFirst(publishedSave(soulsilverId, "soulsilver"))
      modtimes["saves/games/" .. heartgoldId .. ".lua"] = 1700000000
      modtimes["saves/games/" .. soulsilverId .. ".lua"] = 1700000100
      modtimes["saves/catalog.lua"] = 1900000000

      local originalList, originalLoad = Store.listMetadata, Store.load
      local listings, loads = 0, 0
      Store.listMetadata = function(...)
        listings = listings + 1
        return originalList(...)
      end
      Store.load = function(...)
        loads = loads + 1
        return originalLoad(...)
      end
      local ok, err = xpcall(function()
        App._bootExisting()
        Assert.equal(App.selectedVersionId, "soulsilver", "the newest published save chooses only its game")
        Assert.equal(listings, 1, "one boot decision reads one metadata snapshot")
        App.update(0.016)
        App.update(0.016)
        Assert.equal(loads, 0, "automatic boot never loads or restores the save")
        Assert.equal(#result.launches, 0, "automatic boot never constructs gameplay")
        Assert.equal(
          getmetatable(App.state).__index,
          require("app.src.launcher.StartupTitleState"),
          "the normal startup still owns the route"
        )
        Assert.isTrue(App.state ~= result.menus[1], "a staged menu is not installed before the movie and title")
      end, debug.traceback)
      Store.listMetadata, Store.load = originalList, originalLoad
      if not ok then
        error(err, 0)
      end
    end)
  end)
end

function T.boot_without_a_known_candidate_or_with_a_missing_winner_stays_in_selection()
  local function runCase(modtimes, ready)
    withAppHarness({ dev = false }, ready, function()
      local backend = FakeCache.new()
      local originalGetInfo = backend.getInfo
      function backend:getInfo(path)
        local info = originalGetInfo(self, path)
        if info ~= nil and info.type == "file" then
          info.modtime = modtimes[path]
        end
        return info
      end
      withPublishedSaves(backend, function()
        local Store = require("libs.hgss.src.save.GameSaveStore")
        local store = Store.new(require("libs.storage.src.SaveFs").global())
        local heartgoldId = store:reserve()
        local soulsilverId = store:reserve()
        store:publishFirst(publishedSave(heartgoldId, "heartgold"))
        store:publishFirst(publishedSave(soulsilverId, "soulsilver"))
        App._bootExisting()
        Assert.isNil(App.selectedVersionId, "an unavailable automatic candidate selects no game")
        Assert.isNil(App.provisioner, "selection owns no retired source epoch")
        Assert.notNil(App.state, "the library remains the visible product state")
        Assert.equal(type(App.state.view), "function", "the library publishes its resolved semantic view")
        if modtimes["saves/games/" .. soulsilverId .. ".lua"] ~= nil then
          Assert.equal(
            App.state:view().focusedId,
            "soulsilver",
            "the missing winning game stays focused instead of launching an older game"
          )
        end
      end)
    end)
  end

  runCase({}, function(versionId)
    return versionId == "heartgold" or versionId == "soulsilver"
  end)
  runCase({ ["saves/games/save-00000002.lua"] = 1700000100 }, function(versionId)
    return versionId == "heartgold"
  end)
end

function T.boot_catalog_failure_stays_in_selection_instead_of_guessing_a_game()
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold" or versionId == "soulsilver"
  end, function()
    local backend = FakeCache.new()
    backend.files["saves/catalog.lua"] = "return { schema = 'broken-catalog' }"
    withPublishedSaves(backend, function()
      App._bootExisting()
      Assert.isNil(App.selectedVersionId, "a catalog failure never guesses an automatic game")
      Assert.isNil(App.provisioner, "the library owns no selected source epoch")
      Assert.equal(type(App.state.view), "function", "catalog failure leaves a usable selection surface")
    end)
  end)
end

function T.boot_time_tie_chooses_either_supported_game_without_loading()
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold" or versionId == "soulsilver"
  end, function(result)
    local backend = FakeCache.new()
    local originalGetInfo = backend.getInfo
    function backend:getInfo(path)
      local info = originalGetInfo(self, path)
      if info ~= nil and info.type == "file" and path:match("^saves/games/") then
        info.modtime = 1700000000
      end
      return info
    end
    withPublishedSaves(backend, function()
      local Store = require("libs.hgss.src.save.GameSaveStore")
      local store = Store.new(require("libs.storage.src.SaveFs").global())
      local heartgoldId = store:reserve()
      local soulsilverId = store:reserve()
      store:publishFirst(publishedSave(heartgoldId, "heartgold"))
      store:publishFirst(publishedSave(soulsilverId, "soulsilver"))
      App._bootExisting()
      Assert.isTrue(
        App.selectedVersionId == "heartgold" or App.selectedVersionId == "soulsilver",
        "a timestamp tie may choose either supported game"
      )
      App.update(0.016)
      Assert.equal(#result.launches, 0, "a tie never starts gameplay automatically")
    end)
  end)
end

function T.boot_existing_with_one_ready_version_stages_the_menu_under_startup_title()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- Only heartgold is installed and current; the sibling stays out.
    App._selectVersion("heartgold")
    -- The boot gate answers first; startup then stages the menu behind its title.
    App.update(0.016)
    App.update(0.016)
    Assert.equal(#result.launches, 0, "selecting a version installs the product menu without starting retail")
    Assert.equal(App.state.phase, "loading", "missing title assets keep the loading presentation visible")
    Assert.equal(App.state.stagedMenu, result.menus[1], "bootstrap constructs the product menu under title ownership")
    Assert.equal(result.provisionerDisposals, 0, "staging does not dispose its selected provisioner")
    Assert.equal(result.warmups, 0, "optional warmup waits for actual movie entry")
  end)
end

function T.cancelled_retail_entries_restore_the_product_menu_on_the_same_selection()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- Only heartgold is installed and current; the sibling stays out.
    local compositionPath = "app.src.mainmenu.MainMenuComposition"
    local previousComposition = package.loaded[compositionPath]
    local MainMenuComposition = previousComposition or {}
    local originalNew = MainMenuComposition.new
    local menus = {}
    MainMenuComposition.new = function(options)
      local menu = countingState()
      menu.options = options
      function menu:draw() end
      menus[#menus + 1] = menu
      result.menus[#result.menus + 1] = menu
      return menu
    end
    package.loaded[compositionPath] = MainMenuComposition
    local requests = {}
    result.service.request = function(_, _, selector)
      requests[#requests + 1] = selector
    end

    local ok, err = pcall(function()
      App._selectVersion("heartgold")
      -- The boot gate answers first: readiness continues into the menu.
      App.update(0.016)
      finishStartupTitle(result)
      local provisioner = App.provisioner
      local epoch = App.epoch
      local activeState = App.state
      local gameOptions
      Assert.equal(#menus, 1, "selection installs one app-owned menu")
      Assert.equal(activeState, menus[1], "the app installs its product menu")
      menus[1].options.onResult({ kind = "new_game" })
      Assert.equal(App.state, result.state, "New Game enters the retail application")
      gameOptions = assert(result.launches[1])
      Assert.equal(gameOptions.entry.kind, "new_game")
      Assert.equal(
        gameOptions.startupPairIndex,
        App.pairIndex,
        "New Game entry forwards the session-selected walking pair"
      )

      gameOptions.onExit({ kind = "main_menu" })
      Assert.isTrue(App.state ~= activeState, "main_menu exit must publish an app-owned menu state")
      Assert.equal(#menus, 2, "retail cancellation installs a fresh product menu")
      Assert.equal(App.provisioner, provisioner, "the selected provisioner stays live across return")
      Assert.equal(App.epoch, epoch, "the selected epoch stays live across return")

      menus[2].options.onResult({ kind = "continue", saveId = "save-00000042" })
      Assert.equal(result.launches[2].entry.kind, "continue")
      Assert.equal(result.launches[2].entry.saveId, "save-00000042")
      Assert.equal(
        result.launches[2].startupPairIndex,
        gameOptions.startupPairIndex,
        "Continue reuses the same selected pair across the menu return, without reselection"
      )
      result.launches[2].onExit({ kind = "main_menu" })
      Assert.equal(#menus, 3, "a second cancellation restores the product menu again")
      Assert.equal(App.provisioner, provisioner)
      Assert.equal(App.epoch, epoch)
      Assert.equal(#result.selectOptions, 1, "return does not select the version again")
      Assert.equal(result.provisionerDisposals, 0, "return does not retire the provisioner")
      Assert.equal(result.warmups, 1, "only the initial menu authorizes background warmup")

      local introNearRequests = 0
      for _, selector in ipairs(requests) do
        if selector.requestKind == "milestone" and selector.name == "new-game-intro" and selector.urgency == "near" then
          introNearRequests = introNearRequests + 1
        end
      end
      Assert.equal(introNearRequests, 1, "menu restoration does not repeat the initial intro prefetch")
    end)
    MainMenuComposition.new = originalNew
    package.loaded[compositionPath] = previousComposition
    if not ok then
      error(err, 0)
    end
  end)
end

function T.start_menu_return_retires_the_selected_epoch_without_replaying_boot()
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold"
  end, function(result)
    App.selectedVersionId = "heartgold"
    App.epoch = assert(result.service:select({ versionId = "heartgold" }))
    local disposals = 0
    App.provisioner = {
      gameHost = function()
        return {}
      end,
      dispose = function()
        disposals = disposals + 1
        result.service:retire(App.epoch)
      end,
    }
    local menu = assert(App._stageMenu("heartgold"), "the real menu composition exposes its result handler")
    App.setState(menu)
    local epoch = App.epoch
    menu.options.onResult({ kind = "game_selection" })
    Assert.isTrue(App.state ~= menu, "the return action replaces the selected start menu")
    Assert.isNil(App.selectedVersionId, "return leaves no selected game")
    Assert.isNil(App.provisioner, "return retires the selected source owner")
    Assert.equal(disposals, 1, "the selected epoch retires exactly once")
    Assert.isTrue(result.retiredEpochs[epoch], "the exact selected epoch is revoked")
    Assert.equal(#result.selectOptions, 1, "return does not mint a replacement game epoch")
    Assert.equal(#result.launches, 0, "return never constructs gameplay")
    Assert.equal(type(App.state.view), "function", "return installs the library, not another boot intro")
  end)
end

function T.shell_exit_mapping_quits_only_for_a_hgss_quit_result()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._bootMainMenu({ "heartgold" })
    -- The boot gate answers first: readiness continues into the menu.
    App.update(0.016)
    finishStartupTitle(result)
    result.menus[1].options.onResult({ kind = "new_game" })
    local launch = assert(result.launches[1])
    launch.onExit({ kind = "continue" })
    launch.onExit(nil)
    Assert.deepEqual(result.quitCodes, {})
    launch.onExit({ kind = "quit" })
    Assert.deepEqual(result.quitCodes, { 0 })
  end)
end

-- Release startup selects the explicit per-game counter without reading any
-- producer source: both source backends fail the boot if touched.
function T.release_startup_passes_the_release_counter_without_reading_producer_sources()
  local touches = 0
  local function touch()
    touches = touches + 1
    error("release startup must not touch producer sources")
  end
  local hostileBackend = { list = touch, read = touch, getInfo = touch }
  withProducerBackends(function()
    touches = touches + 1
    return hostileBackend
  end, function()
    touches = touches + 1
    error("release startup must not select the checkout source")
  end, function()
    withAppHarness({ dev = false }, function(id)
      return id == "heartgold"
    end, function(result)
      -- Only heartgold is installed and current; the sibling stays out.
      App._selectVersion("heartgold")
      -- The boot gate answers first: readiness continues into the menu.
      App.update(0.016)
      finishStartupTitle(result)
      local options = assert(result.selectOptions[1])
      Assert.keySet(options, "development,versionId")
      Assert.equal(options.versionId, "heartgold")
      Assert.isFalse(options.development)
      Assert.isNil(
        options.developmentRepositoryRoot,
        "release selection passes no checkout root; identity is derived below the controller"
      )
      Assert.isNil(options.sweepEnabled, "exhaustive intent travels as an explicit request, never a construction flag")
      Assert.equal(touches, 0)
      Assert.equal(#result.launches, 0)
      Assert.equal(#result.menus, 1)
      Assert.equal(App.state, result.menus[1])
    end)
  end)
end

-- The release counter is selected per game from the explicit release table.
function T.release_startup_selects_the_per_game_release_counter()
  withProducerBackends(function()
    error("release startup must not use the product source")
  end, function()
    error("release startup must not select the checkout source")
  end, function()
    withAppHarness({ dev = false }, function(id)
      return id == "soulsilver"
    end, function(result)
      -- Only soulsilver is installed and current; the sibling stays out.
      App._selectVersion("soulsilver")
      -- The boot gate answers first: readiness continues into the menu.
      App.update(0.016)
      finishStartupTitle(result)
      local options = assert(result.selectOptions[1])
      Assert.keySet(options, "development,versionId")
      Assert.equal(options.versionId, "soulsilver")
      Assert.isFalse(options.development)
      Assert.isNil(
        options.developmentRepositoryRoot,
        "release selection passes no checkout root; the release counter is derived below the controller"
      )
      Assert.equal(#result.launches, 0)
      Assert.equal(#result.menus, 1)
    end)
  end)
end

-- Explicit development mode passes the checkout root through frozen
-- selectors: the game thread never scans the checkout itself, identity is
-- derived below the controller, and a second boot resends the selectors
-- unchanged even after checkout bytes change.
function T.development_startup_passes_frozen_checkout_selectors_without_scanning()
  local files = {
    ["build/Compiler.lua"] = "checkout compiler",
    ["build/Readers.lua"] = "checkout readers",
  }
  local checkoutRoot = "/deterministic/checkout"
  local checkoutCalls = 0
  local appBackendCalls = 0
  local checkoutBackend = function(repositoryRoot)
    checkoutCalls = checkoutCalls + 1
    Assert.equal(repositoryRoot, checkoutRoot)
    return fakeSourceBackend(files)
  end
  local appBackend = function()
    appBackendCalls = appBackendCalls + 1
    error("development startup must not use the product source")
  end
  withProducerBackends(appBackend, checkoutBackend, function()
    withSourceBaseDirectory(checkoutRoot, function()
      withAppHarness({ dev = true }, function(id)
        return id == "heartgold"
      end, function(result)
        -- Only heartgold is installed and current; the sibling stays out.
        App._selectVersion("heartgold")
        -- The boot gate answers first: readiness continues into the menu.
        App.update(0.016)
        local first = assert(result.selectOptions[1])
        Assert.equal(first.versionId, "heartgold")
        Assert.isTrue(first.development)
        Assert.equal(
          first.repositoryRoot,
          checkoutRoot,
          "development selection passes the checkout root instead of a digest"
        )
        finishStartupTitle(result)
        App._bootMainMenu({ "heartgold" })
        -- The boot gate answers first: readiness continues into the menu.
        App.update(0.016)
        finishStartupTitle(result)
        local second = assert(result.selectOptions[2])
        Assert.equal(checkoutCalls, 0, "no checkout scan happens on the game thread")
        Assert.equal(appBackendCalls, 0)
        Assert.deepEqual(
          { second.versionId, second.development, second.repositoryRoot },
          { first.versionId, first.development, first.repositoryRoot },
          "reselection passes the same frozen selectors without rescanning"
        )
        Assert.equal(#result.launches, 0)
        Assert.equal(#result.menus, 2)
      end)
    end)
  end)
end

-- A scripted first-play preparation stand-in behind the app-facing
-- factory seam. It reports pending until its script releases it, so App
-- wiring tests prove epoch ownership and sweep ordering without
-- rebuilding the real bedroom closure (owned by the preparation tests).
local function installFirstPlayFactory(script)
  local original = HgssGame.newFirstPlayCachePreparation
  HgssGame.newFirstPlayCachePreparation = function(options)
    script.captured = options
    script.constructions = (script.constructions or 0) + 1
    local preparation = {}
    function preparation:poll()
      script.polls = (script.polls or 0) + 1
      if script.failure ~= nil then
        return nil, script.failure
      end
      if script.ready then
        return true, nil
      end
      return nil, nil
    end
    function preparation:dispose()
      script.disposals = (script.disposals or 0) + 1
    end
    return preparation
  end
  return original
end

-- Records every controller request selector so tests prove the mandatory
-- import interval requests exactly the bounded first-play set and never a
-- whole-corpus scope.
local function recordServiceRequests(result)
  local requests = {}
  local baseRequest = result.service.request
  result.service.request = function(_, epoch, selector)
    requests[#requests + 1] = selector
    return baseRequest(_, epoch, selector)
  end
  return requests
end

local function requestedMilestones(requests)
  local names = {}
  local urgencies = {}
  local seen = {}
  for _, selector in ipairs(requests) do
    if selector.requestKind == "milestone" then
      -- Interest is re-affirmed on every poll until terminal readiness,
      -- so the same milestone is requested repeatedly: the contract is
      -- the exact SET of names, never a total call count.
      if not seen[selector.name] then
        seen[selector.name] = true
        names[#names + 1] = selector.name
      end
      urgencies[selector.name] = selector.urgency
    end
  end
  table.sort(names)
  return names, urgencies
end

-- A fresh import stages the menu under the startup title; optional near
-- work is deferred until the title assets become ready.
function T.existing_selection_with_no_completion_stages_the_menu_under_title()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayReady = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._selectVersion("heartgold")
      -- The boot gate answers first; title readiness has not arrived yet.
      App.update(0.016)
      assertStagedStartupMenu(result)
      Assert.equal(script.constructions, nil, "near preparation waits for title readiness")
      result.startupTitleReady = true
      App.update(0.016)
      Assert.equal(script.constructions, 1, "title readiness starts the near coordinator")
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
    Assert.equal(#result.launches, 0, "title startup does not launch retail")
    Assert.equal(getmetatable(App.state).__index, require("app.src.launcher.StartupTitleState"))
    Assert.notNil(script.captured.completion, "ordinary preparation carries the durable gateway")
  end)
end

-- A missing installed first-play fact has no effect on menu admission;
-- readiness still starts only after the title has loaded.
function T.existing_selection_without_an_installed_completion_stages_before_warmup()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayReady = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._selectVersion("heartgold")
      -- The boot gate answers first while title assets remain pending.
      App.update(0.016)
      assertStagedStartupMenu(result)
      Assert.equal(script.constructions, nil, "a missing fact does not bypass title readiness")
      result.startupTitleReady = true
      App.update(0.016)
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
    Assert.equal(#result.launches, 0, "title startup does not launch retail")
    Assert.equal(script.constructions, 1, "a missing completion enters optional near preparation")
  end)
end

-- Existing completion state does not bypass the title and needs no duplicate
-- near coordinator after title assets are ready.
function T.current_completion_waits_for_title_without_duplicate_warmup()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- Only heartgold carries the current completion; the sibling stays out.
    local factoryCalls = 0
    local original = HgssGame.newFirstPlayCachePreparation
    if original ~= nil then
      HgssGame.newFirstPlayCachePreparation = function(options)
        factoryCalls = factoryCalls + 1
        return original(options)
      end
    end
    local ok, err = pcall(function()
      App._selectVersion("heartgold")
      -- The boot gate answers first while title assets remain pending.
      App.update(0.016)
      assertStagedStartupMenu(result)
      Assert.equal(factoryCalls, 0, "near preparation waits for title readiness")
      result.startupTitleReady = true
      App.update(0.016)
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
    Assert.equal(#result.launches, 0, "title startup does not launch retail")
    Assert.equal(#result.menus, 1)
    Assert.equal(factoryCalls, 0, "a current completion skips duplicate near preparation")
  end)
end

-- Cancelling the title retires its selection; reselecting starts a fresh
-- title handoff without publishing a warmup receipt.
function T.cancelled_title_retires_selection_without_publishing()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._selectVersion("heartgold")
    App.update(0.016)
    App.update(0.016)
    assertStagedStartupMenu(result)
    App.keypressed("escape")
    Assert.equal(#result.firstPlayPublished, 0, "cancellation never publishes the completion")
    local selector = App.state
    Assert.equal(getmetatable(selector).__index, GameSelectState, "cancellation returns to game selection")
    App._selectVersion("heartgold")
    App.update(0.016)
    assertStagedStartupMenu(result)
    Assert.equal(#result.firstPlayPublished, 0, "reselection alone publishes nothing")
  end)
end

-- One selected-epoch CPU aggregate: an installed epoch owns exactly one decoded
-- kernel and one lazy preparation queue, every composition of that epoch
-- borrows that same aggregate, a stale epoch sees none, and retirement drains
-- the aggregate before the installed read view is retired.
local function suppliesAggregate(options, record)
  local queueFound, decodedFound = false, false
  local function scan(value, depth)
    if value == record then
      queueFound, decodedFound = true, true
      return
    end
    if value == record.preparationQueue then
      queueFound = true
      return
    end
    if value == record.decoded then
      decodedFound = true
      return
    end
    if depth == 0 or type(value) ~= "table" or value == record.cacheFs then
      return
    end
    for key, nested in pairs(value) do
      if key ~= "isCurrent" and key ~= "onResult" and key ~= "stageMenu" and key ~= "onExit" then
        scan(nested, depth - 1)
      end
    end
  end
  scan(options, 2)
  return queueFound and decodedFound
end

function T.selected_epoch_owns_one_shared_asset_runtime_that_drains_before_retirement()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._selectVersion("heartgold")
    App.update(0.016)
    finishStartupTitle(result)
    local epoch = assert(App.epoch, "the selection installed an epoch")
    Assert.equal(type(App._ensureAssetRuntime), "function", "the App must own one selected-epoch CPU asset runtime")
    local record = App._ensureAssetRuntime(epoch)
    Assert.notNil(record, "an installed epoch owns one shared CPU asset runtime")
    Assert.isTrue(
      record.cacheFs == result.selectedView,
      "the runtime's reader is the selection's overlay on the installed view"
    )
    Assert.isTrue(record.packages == result.overlayPackages, "the runtime owns the selection it reads through")
    Assert.equal(record.packages.epoch, epoch, "the ordered selection belongs to this epoch alone")
    Assert.notNil(record.preparationQueue, "the runtime owns one preparation queue")
    Assert.notNil(record.decoded, "the runtime owns one decoded CPU owner")
    Assert.isTrue(App._ensureAssetRuntime(epoch) == record, "the aggregate is stable for its live epoch")
    Assert.isNil(App._ensureAssetRuntime(epoch - 1), "a stale epoch has no live aggregate")
    local queue = record.preparationQueue
    local decoded = record.decoded

    Assert.equal(#result.menus, 1, "the selection installed one product menu")
    Assert.isTrue(
      suppliesAggregate(result.menus[1].options, record),
      "the menu composition borrows the selected CPU owners"
    )

    result.menus[1].options.onResult({ kind = "new_game" })
    local gameOptions = assert(result.launches[1], "New Game enters the retail application")
    Assert.isTrue(suppliesAggregate(gameOptions, record), "the game composition borrows the selected CPU owners")
    Assert.isTrue(gameOptions.cacheFs == record.cacheFs, "the game reads the same selection the early boot art adopted")
    gameOptions.onExit({ kind = "main_menu" })
    Assert.equal(#result.menus, 2, "the cancelled game installs a fresh product menu")
    Assert.isTrue(
      suppliesAggregate(result.menus[2].options, record),
      "the screen replacing the game still borrows the same selected CPU owners"
    )
    Assert.isTrue(App._ensureAssetRuntime(epoch) == record, "an ordinary screen transition keeps one aggregate")

    local atRetire
    local service = result.service
    local retire = service.retire
    service.retire = function(self, retiredEpoch)
      local accepted = pcall(function()
        queue:request("mesh", "data/generated/geometry/retirement-probe.g4mesh", "prefetch")
      end)
      atRetire = {
        epoch = retiredEpoch,
        idle = decoded:stats().idleBytes,
        pinned = decoded:stats().pinnedBytes,
        queueClosed = not accepted,
        packagesClosed = record.packages.closed == true,
      }
      return retire(self, retiredEpoch)
    end
    local ok, err = pcall(App._retireSelection)
    service.retire = retire
    if not ok then
      error(err, 0)
    end
    Assert.notNil(atRetire, "retiring the selection retires its installed read view")
    Assert.equal(atRetire.epoch, epoch, "the retired read view is the selected one")
    Assert.equal(atRetire.idle, 0, "retirement clears idle decoded entries before the read view retires")
    Assert.equal(atRetire.pinned, 0, "retirement leaves no decoded interest pinned before the read view retires")
    Assert.isTrue(atRetire.queueClosed, "the shared preparation queue is released before the read view retires")
    Assert.isTrue(atRetire.packagesClosed, "every selected package is unmounted before the installed view retires")
    Assert.isNil(App._ensureAssetRuntime(epoch), "a retired epoch exposes no live aggregate")
  end)
end

-- A selection that cannot compose its ordered package set is a visible failure,
-- not a base-only boot: the early wait reports the typed cause, the App publishes
-- no partial runtime, and a later selection with a working package set composes
-- normally on its own epoch.
function T.a_broken_package_selection_publishes_no_runtime()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    local Errors = require("libs.errors.src.Errors")
    local ModPackages = require("app.src.ModPackages")
    local originalOpen = ModPackages.open
    ModPackages.open = function()
      Errors.raise("MOD_PACKAGE_INCOMPATIBLE", "one.zip was built for another game", { package = "one.zip" })
    end
    local ok, err = pcall(function()
      App._selectVersion("heartgold")
      App.update(0.016)
      Assert.isNil(App.provisioner, "a broken composition retires its selected epoch")
      Assert.equal(type(App.state.view), "function", "recovery returns to game selection")
      Assert.isTrue(
        tostring(App.state:view().failure):find("another game", 1, true) ~= nil,
        "the selection modal preserves the typed package cause"
      )
      Assert.equal(#result.menus, 0, "a broken selection never reaches the menu")
      Assert.isNil(result.overlayPackages, "the broken attempt never composed an overlay")
      Assert.equal(#result.loaders, 1, "the failed wait owned one neutral loader")
      Assert.equal(result.loaders[1].disposals, 1, "recovery releases that loader exactly once")

      ModPackages.open = originalOpen
      App._selectVersion("heartgold")
      App.update(0.016)
      finishStartupTitle(result)
      local epoch = assert(App.epoch, "the repaired selection installed its epoch")
      local record = App._ensureAssetRuntime(epoch)
      Assert.notNil(record, "a selection that opens composes its runtime")
      Assert.isTrue(record.cacheFs == result.selectedView, "the composed runtime reads the selection's overlay")
    end)
    ModPackages.open = originalOpen
    if not ok then
      error(err, 0)
    end
  end)
end
function T.first_play_near_completion_publishes_only_on_success()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayReady = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._selectVersion("heartgold")
      App.update(0.016)
      assertStagedStartupMenu(result)
      Assert.equal(script.constructions, nil, "near preparation waits until title readiness")
      result.startupTitleReady = true
      App.update(0.016)
      Assert.equal(script.constructions, 1, "title readiness starts near preparation")
      Assert.equal(#result.firstPlayPublished, 0, "pending preparation publishes nothing")
      script.ready = true
      App.update(0.016)
      Assert.equal(#result.launches, 0, "near preparation never launches retail")
      Assert.equal(#result.menus, 1)
      Assert.deepEqual(
        result.firstPlayPublished,
        { { epoch = App.epoch } },
        "success records first play once for the selected epoch"
      )
      Assert.equal(getmetatable(App.state).__index, require("app.src.launcher.StartupTitleState"))
      finishStartupTitle(result)
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- An unknown controller generation never becomes first play by itself: only
-- the selected epoch's installed fact can prove it, so the near coordinator
-- starts demanding while the title stays usable and the speculative entry
-- demands issue unchanged.
function T.unknown_generation_never_fabricates_first_play()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.cannedGeneration = nil
    result.firstPlayReady = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local requests = {}
    local baseRequest = result.service.request
    result.service.request = function(_, epoch, selector)
      if
        selector.name == "new-game-intro"
        or selector.name == "field-planning"
        or selector.name == "field-runtime"
        or selector.requestKind == "battle-presentation"
      then
        requests[#requests + 1] = selector
      end
      return baseRequest(_, epoch, selector)
    end
    local ok, err = pcall(function()
      App._selectVersion("heartgold")
      App.update(0.016)
      assertStagedStartupMenu(result)
      Assert.equal(#result.launches, 0, "title startup does not launch retail")
      local entryNames, entryUrgencies = requestedMilestones(requests)
      Assert.deepEqual(entryNames, {}, "optional entry preparation waits for actual movie entry")
      result.startupTitleReady = true
      App.update(0.016)
      local movieEntryNames, movieEntryUrgencies = requestedMilestones(requests)
      Assert.deepEqual(
        movieEntryNames,
        { "field-planning", "field-runtime", "new-game-intro" },
        "movie entry issues the speculative intro and field closures without waiting on the generation"
      )
      for _, name in ipairs(movieEntryNames) do
        Assert.equal(movieEntryUrgencies[name], "near", "movie entry demand stays speculative for " .. name)
      end
      Assert.equal(getmetatable(App.state).__index, require("app.src.launcher.StartupTitleState"))
      Assert.equal(script.constructions, 1, "the near coordinator runs while the generation is unknown")
      Assert.equal(#result.firstPlayPublished, 0, "an unknown generation proves no first play")
      result.cannedGeneration = "test-generation"
      App.update(0.016)
      Assert.equal(#result.menus, 1, "the title keeps its staged product menu")
      Assert.equal(#result.firstPlayPublished, 0, "a known generation alone proves no first play")
      script.ready = true
      App.update(0.016)
      Assert.deepEqual(
        result.firstPlayPublished,
        { { epoch = App.epoch } },
        "the completed closure records first play for the selected epoch"
      )
      finishStartupTitle(result)
      local names, urgencies = requestedMilestones(requests)
      Assert.deepEqual(
        names,
        { "field-planning", "field-runtime", "new-game-intro" },
        "transfer adds no closure demand beyond the title entry set"
      )
      for _, name in ipairs(names) do
        Assert.equal(urgencies[name], "near", "transfer demand stays speculative for " .. name)
      end
      local battleDemands = {}
      for _, selector in ipairs(requests) do
        if selector.requestKind == "battle-presentation" then
          battleDemands[#battleDemands + 1] = selector
        end
      end
      Assert.deepEqual(
        battleDemands,
        { { requestKind = "battle-presentation", urgency = "near" } },
        "transfer demands the shared battle catalog once at near urgency"
      )
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- A failed optional coordinator stays off the menu admission path.
function T.failed_first_play_warmup_does_not_block_title()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayReady = false
    local script = { ready = false, failure = "intro milestone failed in the fixture" }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._selectVersion("heartgold")
      App.update(0.016)
      assertStagedStartupMenu(result)
      result.startupTitleReady = true
      App.update(0.016)
      App.update(0.016)
      Assert.equal(#result.launches, 0, "a failed warmup never launches retail")
      Assert.equal(#result.firstPlayPublished, 0, "a failed warmup never publishes")
      Assert.notNil(App.startupWarmupError, "the warmup failure is retained for diagnostics")
      finishStartupTitle(result)
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- The execution policy follows the actual presentation: the boot wait and the
-- startup loader report loader throughput for the selected epoch, and the
-- title/menu journey reports ordinary interactive use again. A retired epoch is
-- never reported for a replacement selection.
function T.loader_presentations_report_loader_throughput_and_the_menu_does_not()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._bootExisting()
    App.update(0.016)
    local first = assert(result.executionPolicies and result.executionPolicies[1], "the boot wait reports its policy")
    Assert.equal(first.epoch, App.epoch, "the policy belongs to the selected epoch")
    Assert.isTrue(first.loading, "the boot wait reports loader throughput")
    local runtime = assert(App._assetRuntime, "the selection owns its CPU runtime")
    Assert.equal(
      runtime.preparationQueue:workerSlotBudget(),
      2,
      "the loader presentation raises the runtime preparation executor to two slots"
    )
    finishStartupTitle(result)
    local last = assert(result.executionPolicies[#result.executionPolicies], "the journey reports a final policy")
    Assert.isFalse(last.loading, "the title and menu never report loader throughput")
    Assert.equal(
      runtime.preparationQueue:workerSlotBudget(),
      1,
      "the menu returns the preparation executor to its single interactive slot"
    )
    Assert.equal(App.state, result.menus[1], "the ordinary interactive policy follows the installed menu")
  end)
end

-- New Game and Continue are the entries whose loaders should widen cache
-- throughput: the App asks the running game host, which forwards to its
-- current child, so the retail entry's own preparation screen raises policy
-- and its transfer restores ordinary admission.
function T.retail_entry_loaders_report_loader_throughput_through_the_game_host()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    local Game = require("game.src.Game")
    local function hostingChild(preparing)
      local child = { preparing = preparing }
      function child:isPreparingAssets()
        return self.preparing
      end
      function child:update() end
      local game = Game.new({ onExit = function() end })
      game:setState(child)
      return game, child
    end

    App._bootExisting()
    App.update(0.016)
    finishStartupTitle(result)
    local runtime = assert(App._assetRuntime, "the selection owns its CPU runtime")

    local game, child = hostingChild(true)
    result.state = game
    result.menus[1].options.onResult({ kind = "new_game" })
    Assert.isTrue(App.state == game, "New Game enters the retail application host")
    App.update(0.016)
    local policy = assert(result.executionPolicies[#result.executionPolicies], "the New Game loader reports its policy")
    Assert.isTrue(policy.loading, "the New Game loader reports loader throughput through the game host")
    Assert.equal(
      runtime.preparationQueue:workerSlotBudget(),
      2,
      "the New Game entry widens the runtime preparation executor"
    )

    child.preparing = false
    App.update(0.016)
    policy = assert(result.executionPolicies[#result.executionPolicies], "the entry transfer reports a new policy")
    Assert.isFalse(policy.loading, "the entry transfer restores ordinary admission")
    Assert.equal(runtime.preparationQueue:workerSlotBudget(), 1, "ordinary gameplay keeps one preparation slot")

    -- Return to the menu through the same retail exit the host publishes, then
    -- enter the other loader-bearing entry on a fresh host lifetime.
    result.launches[1].onExit({ kind = "main_menu" })
    game, child = hostingChild(true)
    result.state = game
    result.menus[2].options.onResult({ kind = "continue", saveId = "save-00000042" })
    App.update(0.016)
    policy = assert(result.executionPolicies[#result.executionPolicies], "the Continue loader reports its policy")
    Assert.isTrue(policy.loading, "the Continue loader reports loader throughput through the game host")
    Assert.equal(
      runtime.preparationQueue:workerSlotBudget(),
      2,
      "the Continue entry widens the runtime preparation executor"
    )
    child.preparing = false
    App.update(0.016)
    Assert.isFalse(
      assert(result.executionPolicies[#result.executionPolicies]).loading,
      "Continue's handoff restores ordinary admission"
    )
  end)
end

-- A cold boot installs the selected reader after the loader policy is already
-- in force. The runtime created then owns the live budget from construction
-- instead of the ordinary one-slot default it would never be lifted from.
function T.a_late_installed_runtime_is_created_under_the_live_loader_budget()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    local installedView = assert(result.service.getCacheFs)
    local withheld = true
    result.bootStatus = "pending"
    result.service.getCacheFs = function(_, epoch)
      if withheld then
        return nil
      end
      return installedView(_, epoch)
    end

    App._bootExisting()
    App.update(0.016)
    Assert.isNil(App._assetRuntime, "the boot wait reports policy before the reader exists")
    Assert.isTrue(
      assert(result.executionPolicies[#result.executionPolicies]).loading,
      "the boot wait already reports loader throughput"
    )

    withheld = false
    result.bootStatus = "ready"
    for _ = 1, 20 do
      if App._assetRuntime ~= nil then
        break
      end
      App.update(0.016)
    end
    local runtime = assert(App._assetRuntime, "the installed reader publishes the selected runtime")
    Assert.equal(
      runtime.preparationQueue:workerSlotBudget(),
      2,
      "the late runtime is created under the live loader budget"
    )
  end)
end

function T.menu_installation_requests_intro_and_field_closures_at_near_urgency()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- Only heartgold is installed and current; the sibling stays out.
    local requests = recordServiceRequests(result)
    App._selectVersion("heartgold")
    -- The boot gate answers first: readiness continues into the menu.
    App.update(0.016)
    finishStartupTitle(result)
    Assert.equal(#result.menus, 1, "selection installs the product menu")
    local names, urgencies = requestedMilestones(requests)
    Assert.deepEqual(names, {
      "bootstrap",
      "field-planning",
      "field-runtime",
      "new-game-intro",
      "startup-audio",
      "startup-title",
    }, "menu installation demands the intro and both field closures alongside the bootstrap check")
    for _, name in ipairs({ "new-game-intro", "field-planning", "field-runtime" }) do
      Assert.equal(urgencies[name], "near", "idle menu demand stays speculative for " .. name)
    end
    -- The locked startup order rides bootstrap near until the title pipeline
    -- shows progress: with an instantly ready cache the single recorded
    -- demand stays near, while the check itself remains mandatory for the
    -- staged menu above.
    Assert.equal(urgencies.bootstrap, "near", "the bootstrap check rides near until title progress")
    Assert.equal(urgencies["startup-title"], "required", "the title asset request stays mandatory")
    Assert.equal(urgencies["startup-audio"], "near", "the optional audio request stays speculative")
    Assert.equal(result.warmups, 1, "menu installation still authorizes background completion once")
  end)
end

-- A version whose derived-cache snapshot is present boots without its ROM:
-- the archive makes it a boot candidate, the controller decides the route, a
-- moved or missing source file never blocks an installed game, and the
-- startup path performs zero ROM file activity.
function T.current_cache_without_source_selects_without_rom_activity()
  local RomFs = require("romdump.src.source.RomFs")
  local RomSource = require("romdump.src.source.RomSource")
  local realOpen = RomFs.open
  local realFromPath = RomSource.fromPath
  local romOpens, pathOpens = 0, 0
  RomFs.open = function(...)
    romOpens = romOpens + 1
    return realOpen(...)
  end
  RomSource.fromPath = function(...)
    pathOpens = pathOpens + 1
    return realFromPath(...)
  end
  local ok, err = pcall(function()
    withAppHarness({ dev = false }, function(_)
      return false
    end, function(result)
      withPublishedSaves(FakeCache.new(), function()
        result.snapshotVersions = { heartgold = true }
        App._bootExisting()
        Assert.isNil(App.importer, "a library candidate starts no import")
        Assert.equal(App.state:view().focusedId, "heartgold", "the recoverable cache remains selectable")
        Assert.isNil(App.provisioner, "selection owns no source epoch until Play")
        App._selectVersion("heartgold")
        App.update(0.016)
        assertStagedStartupMenu(result)
        Assert.equal(result.warmups, 0, "optional warmup waits for movie entry")
        Assert.equal(#result.launches, 0, "selection installs the menu without starting retail")
      end)
    end)
  end)
  RomFs.open = realOpen
  RomSource.fromPath = realFromPath
  if not ok then
    error(err, 0)
  end
  Assert.equal(romOpens, 0, "booting a current cache opens no ROM source")
  Assert.equal(pathOpens, 0, "booting a current cache reads no ROM file")
end
function T.queued_import_failure_returns_to_an_actionable_error_modal()
  withAppHarness({}, function()
    return false
  end, function()
    App.service = nil
    local Errors = require("libs.errors.src.Errors")
    local originalNew = RomImporter.new
    local importer = {
      state = RomImporter.STATES.IDLE,
      isBusy = function()
        return false
      end,
      status = function()
        return { state = RomImporter.STATES.IDLE, canCancel = false }
      end,
      queuePath = function()
        error(Errors.new("IMPORT_WORKER_UNAVAILABLE", "background import could not start", {}), 0)
      end,
      queueDroppedFile = function() end,
      update = function() end,
    }
    RomImporter.new = function()
      return importer
    end
    local ok, err = pcall(function()
      App._beginImportPath("/user/heartgold.nds")
      App.draw()
      App.update(1 / 60)
      Assert.equal(type(App.state.view), "function", "a rejected queue keeps the library usable")
      Assert.equal(
        App.state:view().failure.message,
        "background import could not start",
        "the typed queue failure reaches the shared error modal"
      )
      Assert.isNil(App._pendingImport, "a rejected queue is not retried silently")
    end)
    RomImporter.new = originalNew
    if not ok then
      error(err, 0)
    end
  end)
end

function T.receipt_draw_precedes_any_source_open_for_both_entry_kinds()
  local RomSource = require("romdump.src.source.RomSource")
  local NdsRom = require("romdump.src.source.NdsRom")
  local RomBinding = require("romdump.src.source.RomBinding")
  local originalFromPath = RomSource.fromPath
  local originalFromDroppedFile = RomSource.fromDroppedFile
  local originalOpen = NdsRom.open
  local originalRecord = RomBinding.record
  local calls = {}
  RomSource.fromPath = function(...)
    calls[#calls + 1] = "path"
    return originalFromPath(...)
  end
  RomSource.fromDroppedFile = function(...)
    calls[#calls + 1] = "drop"
    return originalFromDroppedFile(...)
  end
  NdsRom.open = function(...)
    calls[#calls + 1] = "verify"
    return originalOpen(...)
  end
  RomBinding.record = function(...)
    calls[#calls + 1] = "record"
    return originalRecord(...)
  end
  local function restoreSources()
    RomSource.fromPath = originalFromPath
    RomSource.fromDroppedFile = originalFromDroppedFile
    NdsRom.open = originalOpen
    RomBinding.record = originalRecord
  end
  local function captureCopy(draw)
    local lg = love.graphics
    local saved = {
      getDimensions = lg.getDimensions,
      setColor = lg.setColor,
      rectangle = lg.rectangle,
      print = lg.print,
      printf = lg.printf,
    }
    local copy = {}
    lg.getDimensions = function()
      return 800, 600
    end
    lg.setColor = function() end
    lg.rectangle = function() end
    lg.print = function(value)
      copy[#copy + 1] = tostring(value)
    end
    lg.printf = function(value)
      copy[#copy + 1] = tostring(value)
    end
    local ok, err = xpcall(draw, debug.traceback)
    lg.getDimensions = saved.getDimensions
    lg.setColor = saved.setColor
    lg.rectangle = saved.rectangle
    lg.print = saved.print
    lg.printf = saved.printf
    if not ok then
      error(err, 0)
    end
    return table.concat(copy, "\n")
  end
  local dropImporter = nil
  local dropThread = nil
  local ok, err = xpcall(function()
    do
      fresh()
      App.service = nil
      App.pendingQuiesce = nil
      App._importReceipt = nil
      local shellRoot = assert(io.popen("mktemp -d"))
      local tmpDir = ((shellRoot:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", ""))
      assert(shellRoot:close(), "mktemp -d did not exit successfully")
      assert(tmpDir ~= "", "mktemp -d produced no path")
      local tmpPath = tmpDir .. "/picked.nds"
      local writer = assert(io.open(tmpPath, "wb"))
      writer:write("not a real rom")
      assert(writer:close())
      local receiptImporter = nil
      local receiptThread = nil
      local runOk, runErr = xpcall(function()
        calls = {}
        App._beginImportPath(tmpPath)
        Assert.equal(#calls, 0, "a picked path opens no source before its receipt is drawn")
        local busy = App.importer ~= nil and App.importer:isBusy()
        Assert.isFalse(busy, "no import work runs before the receipt is painted")
        local copy = captureCopy(function()
          App.draw()
        end)
        Assert.isTrue(
          copy:find("File received", 1, true) ~= nil,
          "the first painted frame names the receipt, got: " .. copy
        )
        Assert.isTrue(copy:find(".nds", 1, true) ~= nil, "the painted receipt keeps the file kind, got: " .. copy)
        for _, premature in ipairs({ "verified", "complete" }) do
          Assert.isTrue(
            copy:lower():find(premature, 1, true) == nil,
            "an unvalidated receipt never claims success, found: " .. premature
          )
        end
        App.update(0.016)
        Assert.equal(#calls, 0, "the render thread never reads the picked ROM")
        Assert.isTrue(
          App.importer ~= nil and App.importer.state ~= RomImporter.STATES.IDLE,
          "the painted pick starts its import only after the first draw"
        )
        receiptImporter = App.importer
        local session = receiptImporter ~= nil and receiptImporter._queued or nil
        receiptThread = session ~= nil and session.thread or nil
      end, debug.traceback)
      local drainImporter = receiptImporter or App.importer
      if drainImporter ~= nil and type(drainImporter.cancelQueued) == "function" then
        drainImporter:cancelQueued()
      end
      if receiptThread == nil and drainImporter ~= nil and drainImporter._queued ~= nil then
        receiptThread = drainImporter._queued.thread
      end
      if receiptThread ~= nil and drainImporter ~= nil then
        for _ = 1, 200 do
          drainImporter:update()
          local threadOk, running = pcall(receiptThread.isRunning, receiptThread)
          if not threadOk or running ~= true then
            break
          end
          love.timer.sleep(0.01)
        end
      end
      os.remove(tmpPath)
      os.execute("rm -rf -- '" .. tmpDir:gsub("'", "'\\''") .. "'")
      if not runOk then
        error(runErr, 0)
      end
    end
    do
      fresh()
      App.service = nil
      App.pendingQuiesce = nil
      App._importReceipt = nil
      calls = {}
      App.filedropped({
        getFilename = function()
          return "soulsilver.nds"
        end,
        open = function()
          return true
        end,
        read = function()
          return "not a real rom"
        end,
        close = function() end,
      })
      Assert.equal(#calls, 0, "a dropped file opens no source before its receipt is drawn")
      local busy = App.importer ~= nil and App.importer:isBusy()
      Assert.isFalse(busy, "no drop work runs before the receipt is painted")
      local copy = captureCopy(function()
        App.draw()
      end)
      Assert.isTrue(copy:find("File received", 1, true) ~= nil, "the first painted frame names the drop, got: " .. copy)
      Assert.isTrue(
        copy:find("soulsilver.nds", 1, true) ~= nil,
        "the painted receipt names the dropped file, got: " .. copy
      )
      App.update(0.016)
      Assert.equal(#calls, 0, "the render thread never reads the dropped file")
      Assert.isTrue(
        App.importer ~= nil and App.importer.state ~= RomImporter.STATES.IDLE,
        "the painted drop starts its import only after the first draw"
      )
      dropImporter = App.importer
      local dropSession = dropImporter ~= nil and dropImporter._queued or nil
      dropThread = dropSession ~= nil and dropSession.thread or nil
    end
  end, debug.traceback)
  if dropImporter == nil and App.importer ~= nil then
    dropImporter = App.importer
  end
  if dropThread == nil and dropImporter ~= nil and dropImporter._queued ~= nil then
    dropThread = dropImporter._queued.thread
  end
  if dropImporter ~= nil and type(dropImporter.cancelQueued) == "function" then
    dropImporter:cancelQueued()
  end
  if dropThread ~= nil and dropImporter ~= nil then
    for _ = 1, 200 do
      dropImporter:update()
      local dropThreadOk, dropRunning = pcall(dropThread.isRunning, dropThread)
      if not dropThreadOk or dropRunning ~= true then
        break
      end
      love.timer.sleep(0.01)
    end
  end
  restoreSources()
  fresh()
  if not ok then
    error(err, 0)
  end
end

function T.selected_pair_survives_title_menu_game_editor_and_rerolls_on_reselect()
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
  local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
  local savedLoadWalker = StartupAssetCache.loadWalker
  local savedEditorNew = SaveEditorState.new
  local savedRandom = love.math.random
  local ok, err = xpcall(function()
    StartupAssetCache.loadWalker = function(_, pairIndex)
      if pairIndex == 7 then
        return { pairIndex = 7 }
      end
      return nil, "synthetic missing pair"
    end
    local editorOptions = nil
    SaveEditorState.new = function(options)
      editorOptions = options
      return {
        dispose = function() end,
      }
    end
    withAppHarness({ dev = false }, function(id)
      return id == "soulsilver"
    end, function(result)
      local loaderMilestones = 0
      local service = assert(App.service, "selection borrows a service")
      local originalRequest = service.request
      local originalObserve = service.observe
      service.request = function(self, epoch, selector)
        if type(selector) == "table" and selector.requestKind == "milestone" and selector.name == "startup-loader" then
          loaderMilestones = loaderMilestones + 1
        end
        return originalRequest(self, epoch, selector)
      end
      service.observe = function(self, epoch, selector)
        if type(selector) == "table" and selector.requestKind == "milestone" and selector.name == "startup-loader" then
          loaderMilestones = loaderMilestones + 1
        end
        return originalObserve(self, epoch, selector)
      end
      local draws = { 5, 9 }
      local drawCalls = 0
      love.math.random = function(_, _)
        drawCalls = drawCalls + 1
        return assert(draws[drawCalls], "one draw per selection")
      end
      App._selectVersion("soulsilver")
      Assert.equal(App.pairIndex, 5, "the epoch keeps its drawn pair despite the warm catalog")
      App.update(0.016)
      App.update(0.016)
      local StartupTitleState = require("app.src.launcher.StartupTitleState")
      Assert.equal(
        getmetatable(App.state).__index,
        StartupTitleState,
        "the drawn pair transfers into startup title ownership"
      )
      finishStartupTitle(result)
      local menu = assert(App.state, "skip installs the staged menu")
      menu.options.onResult({ kind = "new_game" })
      local launch = assert(result.launches[#result.launches], "retail entry is captured")
      Assert.equal(launch.startupPairIndex, 5, "retail entry forwards the drawn pair")
      Assert.equal(App.pairIndex, 5, "entering retail never reselects the pair")
      launch.onExit({ kind = "main_menu" })
      local returned = assert(App.state, "returning installs a menu")
      Assert.equal(App.pairIndex, 5, "returning to the menu never reselects the pair")
      returned.options.onResult({ kind = "edit", saveId = "synthetic-save" })
      Assert.notNil(editorOptions, "the save editor receives the selection")
      Assert.equal(editorOptions.startupPairIndex, 5, "the editor forwards the drawn pair")
      Assert.equal(loaderMilestones, 0, "the title never demands its own loader milestone")
      App._selectVersion("soulsilver")
      Assert.equal(App.pairIndex, 9, "a new selection draws again")
      Assert.equal(drawCalls, 2, "each selection draws exactly once")
    end)
  end, debug.traceback)
  StartupAssetCache.loadWalker = savedLoadWalker
  SaveEditorState.new = savedEditorNew
  love.math.random = savedRandom
  if not ok then
    error(err, 0)
  end
end

function T.failed_asset_runtime_teardown_keeps_the_owner_for_retry()
  loadShellModules()
  local previous = App._assetRuntime
  local queueAttempts = 0
  local clearAttempts = 0
  local closeAttempts = 0
  local record = {
    preparationQueue = {
      release = function()
        queueAttempts = queueAttempts + 1
        if queueAttempts == 1 then
          error("injected worker join failure")
        end
      end,
    },
    decoded = {
      clear = function()
        clearAttempts = clearAttempts + 1
      end,
    },
    packages = {
      close = function()
        closeAttempts = closeAttempts + 1
        if closeAttempts == 1 then
          error("injected unmount failure")
        end
      end,
    },
  }
  App._assetRuntime = record
  local ok, err = xpcall(function()
    local firstClosed = pcall(App._releaseAssetRuntime)
    Assert.isFalse(firstClosed, "a worker join failure aborts dependent teardown")
    Assert.isTrue(App._assetRuntime == record, "the App retains its runtime owner after the join failure")
    Assert.equal(clearAttempts, 0, "decoded backing stays live while worker shutdown failed")
    Assert.equal(closeAttempts, 0, "mounted packages stay live while the queue still owns readers")

    local secondClosed = pcall(App._releaseAssetRuntime)
    Assert.isFalse(secondClosed, "an unmount failure keeps teardown incomplete")
    Assert.isTrue(App._assetRuntime == record, "the App retains its runtime owner after the unmount failure")
    Assert.equal(clearAttempts, 1, "decoded state clears after the worker has joined")

    App._releaseAssetRuntime()
    Assert.isNil(App._assetRuntime, "the App drops the owner after all cleanup succeeds")
    Assert.equal(queueAttempts, 3, "queue release remains safely retryable")
    Assert.equal(clearAttempts, 2, "decoded clear may be retried idempotently")
    Assert.equal(closeAttempts, 2, "the package owner receives its cleanup retry")
  end, debug.traceback)
  App._assetRuntime = previous
  if not ok then
    error(err, 0)
  end
end

function T.successful_import_returns_to_focused_selection_without_starting_a_game()
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold"
  end, function(result)
    local importer = completedSyntheticImporter("heartgold")
    App.importer = importer
    App._onImported("heartgold", importer)
    Assert.isNil(importer:takeVerifiedSource(), "the library route consumes the real one-shot verified source")
    Assert.isNil(App.importer, "the completed importer is disposed after its handoff is released")
    Assert.isNil(App.selectedVersionId, "import completion does not select a provisioner")
    Assert.isNil(App.provisioner, "idle selection retains no source controller")
    Assert.equal(#result.selectOptions, 0, "import completion never requests boot-source admission")
    Assert.equal(#result.menus, 0, "import completion constructs no start menu")
    Assert.equal(#result.launches, 0, "import completion never constructs gameplay")
    Assert.equal(type(App.state.view), "function", "completion returns to the interactive library")
    Assert.equal(App.state:view().focusedId, "heartgold", "the detected game is focused")
  end)
end

function T.stale_import_callback_cannot_consume_a_newer_complete_importer()
  fresh()
  App.opts = { dev = false }
  local current = completedSyntheticImporter("soulsilver")
  local originalNew = RomImporter.new
  local staleCallback
  RomImporter.new = function(options)
    staleCallback = options.onComplete
    return originalNew(options)
  end
  App._startImport()
  App.importer = current
  local state = countingState()
  App.setState(state)
  local ok, err = pcall(function()
    staleCallback("heartgold")
    local untouched = current:takeVerifiedSource()
    Assert.notNil(untouched, "a stale completion never takes the newer importer's verified source")
    untouched:release()
    Assert.isTrue(App.importer == current, "the newer importer remains current")
    Assert.equal(App.state, state, "a stale completion never navigates")
  end)
  RomImporter.new = originalNew
  fresh()
  if not ok then
    error(err, 0)
  end
end

function T.typed_runtime_failure_keeps_the_loader_owned_until_selection_recovery()
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold"
  end, function(result)
    local Errors = require("libs.errors.src.Errors")
    local Loading = require("app.src.launcher.LauncherLoadingPresentation")
    local harnessNew = Loading.new
    local loader = { disposals = 0 }
    function loader:update() end
    function loader:resize() end
    function loader:draw() end
    function loader:adoptGeneratedAssets()
      return true
    end
    function loader:dispose()
      self.disposals = self.disposals + 1
    end
    Loading.new = function()
      return loader
    end
    result.generatedView.withPackages = function()
      error(Errors.new("MOD_PACKAGE_INCOMPATIBLE", "selected package belongs to another game"), 0)
    end
    local ok, err = xpcall(function()
      App._selectVersion("heartgold")
      App.update(0.016)
      Assert.isNil(App.selectedVersionId, "a typed composition failure returns to game selection")
      Assert.isNil(App.provisioner, "the failed selected epoch is retired")
      Assert.equal(type(App.state.view), "function", "selection owns the recovery surface")
      Assert.equal(loader.disposals, 1, "the wait releases its loader exactly once on recovery")
      Assert.isTrue(
        tostring(App.state:view().failure):find("another game", 1, true) ~= nil,
        "the original typed cause reaches the actionable modal"
      )
    end, debug.traceback)
    result.generatedView.withPackages = nil
    Loading.new = harnessNew
    if not ok then
      error(err, 0)
    end
  end)
end

function T.receiving_startup_constructor_failure_disposes_the_detached_loader_once()
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold"
  end, function()
    local Loading = require("app.src.launcher.LauncherLoadingPresentation")
    local StartupTitleState = require("app.src.launcher.StartupTitleState")
    local harnessLoadingNew = Loading.new
    local originalStartupNew = StartupTitleState.new
    local loader = { disposals = 0 }
    function loader:update() end
    function loader:resize() end
    function loader:draw() end
    function loader:adoptGeneratedAssets()
      return true
    end
    function loader:dispose()
      self.disposals = self.disposals + 1
    end
    Loading.new = function()
      return loader
    end
    StartupTitleState.new = function()
      error("synthetic receiving constructor failure", 0)
    end
    local ok, failure = xpcall(function()
      App._selectVersion("heartgold")
      App.update(0.016)
    end, debug.traceback)
    Loading.new = harnessLoadingNew
    StartupTitleState.new = originalStartupNew
    Assert.isFalse(ok, "a receiving constructor failure remains visible to its caller")
    Assert.isTrue(tostring(failure):find("receiving constructor failure", 1, true) ~= nil)
    Assert.equal(loader.disposals, 1, "the caller releases the detached loader exactly once")
  end)
end

local function withNativePickerImportHost(fixture, fn)
  loadShellModules()
  fresh()
  App.opts = { dev = false }
  local NativeRomPicker = require("app.src.launcher.NativeRomPicker")
  local original = {
    available = NativeRomPicker.available,
    openSingle = NativeRomPicker.openSingle,
    poll = NativeRomPicker.poll,
    newImporter = RomImporter.new,
    renderer = App.launcherRenderer,
    audio = App.launcherAudio,
  }
  local host = { opens = 0, polls = 0, results = {}, openBusy = false, lastView = nil }
  function host:complete(result)
    self.results[#self.results + 1] = result
  end
  NativeRomPicker.available = function()
    return true
  end
  NativeRomPicker.openSingle = function()
    host.opens = host.opens + 1
    if host.openBusy then
      return { kind = "error", message = "the previous picker operation is still finishing" }
    end
    return { kind = "pending", requestId = host.requestId }
  end
  NativeRomPicker.poll = function(_)
    host.polls = host.polls + 1
    return table.remove(host.results, 1)
  end
  RomImporter.new = function(options)
    return fixture.host:importer(fixture.cart, options and options.onComplete)
  end
  App.launcherRenderer = {
    draw = function(_, view)
      host.lastView = view
    end,
    drawDual = function(_, view)
      host.lastView = view
    end,
    drawButton = function() end,
    dispose = function() end,
  }
  App.launcherAudio = {
    play = function() end,
    fadeBoot = function() end,
    update = function() end,
    dispose = function() end,
  }
  App.service = nil
  App.pendingQuiesce = nil
  App._pendingImport = nil
  App._importReceipt = nil
  App._showGameSelection(nil, nil, {})
  local ok, err = xpcall(function()
    fn(host)
  end, debug.traceback)
  App._cancelImport()
  App.setState(nil)
  NativeRomPicker.available = original.available
  NativeRomPicker.openSingle = original.openSingle
  NativeRomPicker.poll = original.poll
  RomImporter.new = original.newImporter
  App.launcherRenderer = original.renderer
  App.launcherAudio = original.audio
  fresh()
  if not ok then
    error(err, 0)
  end
end

local function touchCancel(state)
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local view = assert(state:view(), "touch Cancel needs the published selection view")
  local cancel = assert(view.layout.cancelRect, "touch Cancel needs resolved geometry")
  local placement = assert(view.presentation.panes[1].placement, "touch Cancel needs the input placement")
  local x, y = LayoutGeometry.logicalToHost(placement, cancel.x + cancel.width / 2, cancel.y + cancel.height / 2)
  App.touchpressed("cancel-finger", x, y)
  App.touchreleased("cancel-finger", x, y)
end

function T.native_picker_receipt_precedes_real_queued_temporary_import_and_cancel_closes_first()
  local Fixture = require("tests.support.ManagedRomFixture")
  Fixture.with(function(fixture)
    local requestId = "123e4567-e89b-12d3-a456-426614174000"
    local stage = fixture:writePickerTemporary(requestId)
    fixture.host.holdValidation = true
    withNativePickerImportHost(fixture, function(host)
      host.requestId = requestId
      App._requestGameImport()
      Assert.equal(host.opens, 1, "Add game opens one asynchronous picker")
      Assert.isNil(App.importer, "pending native copy creates no importer reader")
      Assert.equal(App.state:view().status, "Adding game…", "the library shows the borrowed native-operation strip")
      App.update(1 / 60)
      Assert.isNil(App.importer, "native copy still pending performs no queued source work")

      host:complete({
        requestId = requestId,
        kind = "path",
        relativePath = stage,
        displayName = "My game.NDS",
      })
      App.update(1 / 60)
      Assert.notNil(App.importer, "a matching completed copy enters the ordinary import card")
      Assert.isNil(App.importer._queued, "the receipt is latched before any worker starts")
      Assert.notNil(love.filesystem.getInfo(stage), "the unopened stage remains App-owned before queue acceptance")
      Assert.isNil(
        App.state:view().status:find("Adding game", 1, true),
        "native pending clears before importer receipt"
      )

      App.draw()
      Assert.equal(host.lastView.status, "File received My game.NDS", "the first frame names the received file")
      Assert.isNil(App.importer._queued, "drawing the receipt alone starts no source work")
      Assert.notNil(love.filesystem.getInfo(stage), "the receipt frame does not consume the stage")
      App.update(1 / 60)
      Assert.notNil(App.importer._queued, "the painted receipt hands the stage to the real queued importer")
      Assert.equal(App._pendingImport.kind, "temporary", "temporary input uses the importer ownership-transfer queue")
      Assert.equal(App._pendingImport.requestId, requestId, "the queued request keeps its native correlation token")
      Assert.notNil(love.filesystem.getInfo(stage), "accepted input persists while the importer worker owns it")

      local session = fixture.host:validationGate(App.importer)
      Assert.notNil(love.filesystem.getInfo(stage), "App never deletes an accepted stage at the validation gate")
      touchCancel(App.state)
      session.outbox:discardValidation()
      local thread = session.thread
      fixture.host:waitFor(function()
        return not thread:isRunning() and love.filesystem.getInfo(stage) == nil
      end, "accepted stage cleanup after physical worker exit")
      Assert.isNil(love.filesystem.getInfo(fixture.canonical), "precommit cancellation publishes no managed ROM")
      Assert.isTrue(fixture:originalExists(), "temporary import cleanup never deletes the user original")
      Assert.isNil(App.provisioner, "import work never creates a selected game epoch")
      Assert.isNil(App.selectedVersionId, "import completion never selects gameplay")
    end)
  end)
end

function T.native_picker_cancel_busy_retry_and_stale_completion_never_navigate()
  local Fixture = require("tests.support.ManagedRomFixture")
  Fixture.with(function(fixture)
    local requestId = "223e4567-e89b-12d3-a456-426614174000"
    local stage = fixture:writePickerTemporary(requestId)
    withNativePickerImportHost(fixture, function(host)
      host.requestId = requestId
      App._requestGameImport()
      Assert.equal(App.state:view().status, "Adding game…", "the pending native request owns the library strip")
      local pending = App.state
      touchCancel(pending)
      Assert.equal(host.opens, 1, "cancelling the App request does not reopen the chooser")
      Assert.isTrue(pending._disposed, "cancellation retires the pending library state")
      Assert.isNil(App.state:view().status, "cancellation restores ordinary selection")

      host.openBusy = true
      App._requestGameImport()
      Assert.equal(host.opens, 2, "an immediate retry reaches the native busy boundary once")
      local failure = App.state:view().failure
      Assert.notNil(failure, "a busy reattempt uses the recoverable picker error modal")
      Assert.isTrue(tostring(failure.message):find("still finishing", 1, true) ~= nil)
      Assert.isNil(App.importer, "a busy reattempt creates no second importer")
      App.state:keypressed("escape")

      local running = countingState()
      App.setState(running)
      host:complete({
        requestId = requestId,
        kind = "path",
        relativePath = stage,
        displayName = "late copy.nds",
      })
      App.update(1 / 60)
      Assert.isNil(love.filesystem.getInfo(stage), "a stale completed copy is drained after screen retirement")
      Assert.isNil(App.importer, "a stale result starts no import")
      Assert.equal(App.state, running, "a stale result never navigates or replaces the running state")
      Assert.isNil(love.filesystem.getInfo(fixture.canonical), "a stale result publishes no managed ROM")
    end)
  end)
end

function T.native_picker_enqueue_rejection_keeps_unaccepted_stage_with_app()
  local Fixture = require("tests.support.ManagedRomFixture")
  Fixture.with(function(fixture)
    local requestId = "323e4567-e89b-12d3-a456-426614174000"
    local stage = fixture:writePickerTemporary(requestId)
    withNativePickerImportHost(fixture, function(host)
      host.requestId = requestId
      App._requestGameImport()
      Assert.equal(App.state:view().status, "Adding game…", "the pending native request owns the library strip")
      host:complete({
        requestId = requestId,
        kind = "path",
        relativePath = stage,
        displayName = "lost copy.nds",
      })
      App.update(1 / 60)
      App.draw()
      Assert.isTrue(love.filesystem.remove(stage), "simulate loss of the completed native stage before admission")
      App.update(1 / 60)
      Assert.equal(#fixture.host.threads, 0, "typed pre-admission rejection starts no worker")
      Assert.isNil(App._pendingImport, "a rejected temporary enqueue is not retried")
      Assert.equal(
        App.state:view().failure.code,
        "ROM_OPEN_FAILED",
        "the typed queue rejection reaches the shared modal"
      )
      Assert.isNil(love.filesystem.getInfo(fixture.canonical), "rejection publishes no managed ROM")
      Assert.isTrue(fixture:originalExists(), "rejection never reaches the user original")
    end)
  end)
end

function T.native_picker_worker_start_failure_leaves_accepted_stage_with_importer()
  local Fixture = require("tests.support.ManagedRomFixture")
  Fixture.with(function(fixture)
    local requestId = "423e4567-e89b-12d3-a456-426614174000"
    local stage = fixture:writePickerTemporary(requestId)
    withNativePickerImportHost(fixture, function(host)
      host.requestId = requestId
      App._requestGameImport()
      Assert.equal(App.state:view().status, "Adding game…", "the pending native request owns the library strip")
      host:complete({
        requestId = requestId,
        kind = "path",
        relativePath = stage,
        displayName = "startup failure.nds",
      })
      App.update(1 / 60)
      App.draw()
      fixture.host.failNextStart = true
      local removals = 0
      local originalRemove = love.filesystem.remove
      love.filesystem.remove = function(path)
        if path == stage then
          removals = removals + 1
        end
        return originalRemove(path)
      end
      local ok, err = pcall(function()
        App.update(1 / 60)
      end)
      love.filesystem.remove = originalRemove
      if not ok then
        error(err, 0)
      end
      Assert.equal(App.importer.state, RomImporter.STATES.ERROR, "accepted startup failure belongs to importer status")
      Assert.equal(removals, 1, "only the importer removes its accepted stage after true ownership transfer")
      Assert.isNil(love.filesystem.getInfo(stage), "the importer completes accepted-stage cleanup")
      Assert.isNil(App._pendingImport, "an immediate importer failure does not re-arm App admission")
      Assert.isNil(love.filesystem.getInfo(fixture.canonical), "startup failure publishes no managed ROM")
    end)
  end)
end

function T.native_picker_copy_error_uses_the_recoverable_modal_without_import()
  local Fixture = require("tests.support.ManagedRomFixture")
  Fixture.with(function(fixture)
    local requestId = "523e4567-e89b-12d3-a456-426614174000"
    withNativePickerImportHost(fixture, function(host)
      host.requestId = requestId
      App._requestGameImport()
      Assert.equal(App.state:view().status, "Adding game…", "the pending native request owns the library strip")
      local focusedId = App.state:view().focusedId
      host:complete({ requestId = requestId, kind = "error", message = "the document could not be copied" })
      App.update(1 / 60)
      local view = App.state:view()
      Assert.isNil(App.importer, "a native copy failure creates no importer")
      Assert.equal(view.failure.code, "ROM_PICKER_FAILED", "copy errors use the typed picker failure path")
      Assert.isTrue(tostring(view.failure.message):find("could not be copied", 1, true) ~= nil)
      Assert.equal(view.focusedId, focusedId, "a recoverable copy error preserves library focus")
      Assert.isNil(view.status, "native pending clears when the error modal takes over")
      Assert.isNil(love.filesystem.getInfo(fixture.canonical), "copy failure publishes no managed ROM")
    end)
  end)
end

return { tests = T }
