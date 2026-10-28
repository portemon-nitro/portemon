-- App shell state replacement tests. App.setState is the single transition point
-- between top-level states: it must dispose the previous state exactly once,
-- tolerate states without a disposal hook (the one centralized optional
-- check), and guarantee application quit can never dispose a state twice.
-- Import sessions are single-use: a file drop must always enter a fresh
-- import session through the import state and never invoke an importer left
-- over from a previous session.

local Assert = require("tests.support.Assert")
local RomImporter = require("romdump.src.source.RomImporter")
local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")
local HgssGame = require("game.hgss.src.HgssGame")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local defaultAppBackend = ProducerFingerprint.appBackend
local defaultCheckoutBackend = ProducerFingerprint.checkoutBackend

local App
local ImportState
local VersionSelectState

-- Scope the harness attestation answers to one installed version. The
-- harness flags answer for every version, which would mark the sibling
-- version current too and boot into the version selector; tests that boot
-- a single installed menu gate currency to that version instead. The
-- harness teardown restores the pre-harness module functions, so no test
-- leaks this scoping into the next.
---@param versionId string the single installed version
local function currentOnlyFor(versionId)
  local harnessIsCurrent = FirstPlayCompletion.isCurrent
  local harnessHasStored = FirstPlayCompletion.hasStored
  FirstPlayCompletion.isCurrent = function(candidateId, generationId)
    if candidateId ~= versionId then
      return false
    end
    return harnessIsCurrent(candidateId, generationId)
  end
  FirstPlayCompletion.hasStored = function(candidateId, cacheFs)
    if candidateId ~= versionId then
      return false
    end
    return harnessHasStored(candidateId, cacheFs)
  end
end

local function loadShellModules()
  local ok, appOrError = pcall(require, "app.src.App")
  Assert.isTrue(ok, "the app shell must provide app.src.App: " .. tostring(appOrError))
  App = appOrError
  local okImport, importOrError = pcall(require, "app.src.launcher.ImportState")
  Assert.isTrue(okImport, "the app shell must own its import state: " .. tostring(importOrError))
  ImportState = importOrError
  local okVersion, versionOrError = pcall(require, "app.src.launcher.VersionSelectState")
  Assert.isTrue(okVersion, "the app shell must own its version selector: " .. tostring(versionOrError))
  VersionSelectState = versionOrError
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
  App.pendingQuiesce = nil
  App.epoch = 0
  App.selectedVersionId = nil
  App._rebindVersionId = nil
  App._bootBlockedVersionId = nil
  App.drawableWidth = nil
  App.drawableHeight = nil
  App.pixelRatio = nil
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
---@field firstPlayCurrent boolean scripted durable attestation currency
---@field firstPlayStored boolean scripted durable attestation presence
---@field firstPlayPublished table[] recorded attestation publications
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
  local originalNew = HgssGame.new
  local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
  local originalMenuNew = MainMenuComposition.new
  local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")
  local originalTitleNew = HgssTitleScene.new
  local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
  local originalLoadingNew = HgssLoadingPresentation.new
  local graphics = love.graphics
  local originalPrint = graphics.print
  local originalGetDimensions = graphics.getDimensions
  local originalGetDPIScale = graphics.getDPIScale
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
    firstPlayCurrent = true,
    firstPlayStored = true,
    alreadyRegistered = false,
    firstPlayPublished = {},
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
    if selector.requestKind == "milestone" and selector.name == "startup-loader" then
      return true, nil
    end
    if selector.requestKind == "milestone" and selector.name == "startup-title" then
      return result.startupTitleReady == true, nil
    end
    -- The locked cinematic journey runs the five opening scenes before the
    -- legendary title: the harness models a healthy worker by answering the
    -- numbered scene demands beside title readiness, so the instant movie
    -- below completes and the title adopts without GPU fixtures.
    if selector.requestKind == "opening-scene" then
      return result.startupTitleReady == true, nil
    end
    -- A cold first import gates on its selected walking pair: the harness
    -- models a healthy worker by default, while tests set walkerReady to
    -- false to hold the card on a still-pending pair.
    if selector.requestKind == "startup-walker" and selector.pairIndex == App.pairIndex then
      if result.walkerReady == false then
        return nil, nil
      end
      return true, nil
    end
    return nil, nil
  end
  function service:enableSweep(_)
    result.warmups = result.warmups + 1
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
  function service:retire(_)
    result.provisionerDisposals = result.provisionerDisposals + 1
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
  RomImporter.isRegistered = function(_, _)
    return result.alreadyRegistered
  end
  local originalIsCurrent = FirstPlayCompletion.isCurrent
  local originalHasStored = FirstPlayCompletion.hasStored
  local originalPublish = FirstPlayCompletion.publish
  FirstPlayCompletion.isCurrent = function(_, _)
    return result.firstPlayCurrent
  end
  FirstPlayCompletion.hasStored = function()
    return result.firstPlayStored
  end
  FirstPlayCompletion.publish = function(versionId, generationId)
    result.firstPlayPublished[#result.firstPlayPublished + 1] = { versionId = versionId, generationId = generationId }
  end
  HgssGame.new = function(options)
    result.launches[#result.launches + 1] = options
    return result.state
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
  HgssTitleScene.new = function()
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
    return title
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
    return 800, 600
  end
  graphics.getDPIScale = function()
    return 1
  end
  love.event.quit = function(code)
    result.quitCodes[#result.quitCodes + 1] = code
  end
  local ok, err = pcall(fn, result)
  App.opts = originalOpts
  RomImporter.isReady = originalIsReady
  RomImporter.isRegistered = originalIsRegistered
  FirstPlayCompletion.isCurrent = originalIsCurrent
  FirstPlayCompletion.hasStored = originalHasStored
  FirstPlayCompletion.publish = originalPublish
  HgssGame.new = originalNew
  HgssOpeningMovie.new = originalMovieNew
  StartupAssetCache.loadOpeningScene = originalLoadOpeningScene
  App.pairIndex = originalPairIndex
  MainMenuComposition.new = originalMenuNew
  HgssTitleScene.new = originalTitleNew
  HgssLoadingPresentation.new = originalLoadingNew
  graphics.print = originalPrint
  graphics.getDimensions = originalGetDimensions
  graphics.getDPIScale = originalGetDPIScale
  love.event.quit = originalQuit
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
    App.update(1 / 30)
  end
  Assert.equal(getmetatable(App.state).__index, StartupTitleState, "selection remains under startup title ownership")
  Assert.equal(App.state.stagedMenu, result.menus[#result.menus], "title stages the exact product menu")
end

local function finishStartupTitle(result)
  result.startupTitleReady = true
  assertStagedStartupMenu(result)
  for _ = 1, 3 do
    if App.state.title ~= nil then
      break
    end
    App.update(1 / 30)
  end
  Assert.notNil(App.state.title, "title readiness adopts the renderer before skip")
  App.keypressed("return")
  for _ = 1, 80 do
    local metatable = getmetatable(App.state)
    if metatable == nil or metatable.__index ~= require("app.src.launcher.StartupTitleState") then
      break
    end
    App.update(1 / 30)
  end
  Assert.equal(
    App.state,
    result.menus[#result.menus],
    "skip transfers the same staged menu (phase " .. tostring(App.state.phase) .. ", frame " .. tostring(App.state.fadeFrame) .. ")"
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

function T.starting_an_import_disposes_the_active_field_state()
  fresh()
  local field = countingState()
  App.setState(field)
  App.saveDir = nil
  App._startImport()
  Assert.equal(field.disposed, 1)
  Assert.equal(getmetatable(App.state).__index, ImportState)
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
    Assert.equal(getmetatable(App.state).__index, ImportState)
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
    local originalImportStateNew = ImportState.new
    local importer = importerStub("idle")
    local importState = countingState()
    RomImporter.new = function()
      return importer
    end
    ImportState.new = function(received)
      Assert.equal(received, importer, "the existing importer is passed to ImportState")
      return importState
    end
    local ok, err = pcall(function()
      App.filedropped({
        getFilename = function()
          return "ordinary.lua"
        end,
      })
      Assert.equal(importer.filedroppedCalls, 1, "a non-editor Lua drop follows ROM import routing")
      Assert.equal(App.state, importState, "the normal import state owns the non-editor drop")
    end)
    RomImporter.new = originalImporterNew
    ImportState.new = originalImportStateNew
    if not ok then
      error(err, 0)
    end
  end)
end

-- A failed import leaves no importer behind: the next update clears it, so a
-- stale reference can never survive the session. The import screen holds its
-- own reference and is unaffected.
function T.failed_import_is_cleared_on_the_next_update()
  fresh()
  App.importer = importerStub("error")
  local state = { update = function() end }
  App.setState(state)
  App.update(0.016)
  Assert.isNil(App.importer, "a failed import session must not linger")
  Assert.equal(App.state, state, "clearing the importer must not disturb the import screen")
end

-- The boot decision when no ROM was supplied: zero ready versions enter the
-- import state, one launches HGSS, and several offer the version selector.

function T.boot_existing_with_no_ready_version_starts_an_import()
  withAppHarness({}, function()
    return false
  end, function(result)
    -- Nothing is installed or bound: no current attestation anywhere.
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    App._bootExisting()
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
  end)
end

function T.boot_existing_selects_the_persisted_last_played_edition()
  local preferencePath = "app-edition.lua"
  withAppHarness({ dev = false }, function()
    return true
  end, function()
    local wrote, err = love.filesystem.write(preferencePath, 'return { schema = 1, versionId = "soulsilver" }\n')
    Assert.isTrue(wrote, tostring(err))
    App._bootExisting()
    Assert.equal(App.selectedVersionId, "soulsilver", "last-played edition boots without a preview screen")
  end)
end

function T.boot_falls_back_when_the_persisted_edition_is_not_ready()
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold"
  end, function()
    local wrote = love.filesystem.write("app-edition.lua", 'return { schema = 1, versionId = "soulsilver" }\n')
    Assert.isTrue(wrote)
    currentOnlyFor("heartgold")
    App._bootExisting()
    Assert.equal(App.selectedVersionId, "heartgold", "an unavailable preference falls back to the first ready edition")
  end)
end

function T.native_picker_path_waits_for_quiescence_before_importing()
  local NativeRomPicker = require("app.src.launcher.NativeRomPicker")
  local originalAvailable = NativeRomPicker.available
  local originalOpen = NativeRomPicker.openSingle
  local originalNew = RomImporter.new
  local starts = { path = 0, drop = 0 }
  NativeRomPicker.available = function()
    return true
  end
  NativeRomPicker.openSingle = function()
    return { kind = "path", path = "/user/heartgold.nds" }
  end
  RomImporter.new = function()
    local importer = { state = "idle" }
    function importer:isBusy()
      return false
    end
    function importer:startPath(path)
      Assert.equal(path, "/user/heartgold.nds")
      starts.path = starts.path + 1
    end
    function importer:filedropped(_)
      starts.drop = starts.drop + 1
    end
    function importer:update() end
    function importer:status()
      return { state = self.state }
    end
    return importer
  end
  local ok, failure = pcall(function()
    withAppHarness({}, function()
      return false
    end, function(result)
      result.firstPlayCurrent = false
      result.firstPlayStored = false
      App._bootExisting()
      result.service.barrierStatus = function()
        return "ready"
      end
      result.service.importSource = function()
        result.importAuthorized = (result.importAuthorized or 0) + 1
        return true
      end
      App.state:mousepressed(400, 300, 1)
      Assert.equal(result.importAuthorized, nil, "path import waits for barrier polling")
      App.update(0.016)
      Assert.equal(result.importAuthorized, 1, "source ownership is authorized after quiescence")
      Assert.equal(starts.path, 1, "picker path enters the importer exactly once")
      Assert.equal(starts.drop, 0, "native selection does not masquerade as a dropped file")
    end)
  end)
  NativeRomPicker.available = originalAvailable
  NativeRomPicker.openSingle = originalOpen
  RomImporter.new = originalNew
  if not ok then
    error(failure, 0)
  end
end

function T.picker_cancel_does_not_start_a_barrier_or_import()
  local NativeRomPicker = require("app.src.launcher.NativeRomPicker")
  local originalAvailable = NativeRomPicker.available
  local originalOpen = NativeRomPicker.openSingle
  NativeRomPicker.available = function()
    return true
  end
  NativeRomPicker.openSingle = function()
    return { kind = "cancel" }
  end
  local ok, failure = pcall(function()
    withAppHarness({}, function()
      return false
    end, function(result)
      result.firstPlayCurrent = false
      result.firstPlayStored = false
      App._bootExisting()
      App.state:mousepressed(400, 300, 1)
      Assert.equal(App.state.onImportAttempt, nil)
      Assert.equal(App.pendingQuiesce, nil, "cancel does not authorize source replacement")
      Assert.equal(App.importer.state, "idle", "cancel leaves the importer idle")
    end)
  end)
  NativeRomPicker.available = originalAvailable
  NativeRomPicker.openSingle = originalOpen
  if not ok then
    error(failure, 0)
  end
end

function T.switching_to_a_missing_edition_waits_for_quiescence_and_targets_its_import()
  local originalNew = RomImporter.new
  local importerOptions
  RomImporter.new = function(options)
    importerOptions = options
    local importer = { state = "idle" }
    function importer:isBusy()
      return false
    end
    function importer:update() end
    function importer:status()
      return { state = self.state }
    end
    function importer:filedropped(_) end
    function importer:startPath(_) end
    return importer
  end
  local ok, failure = pcall(function()
    withAppHarness({ dev = false }, function(versionId)
      return versionId == "heartgold"
    end, function(result)
      currentOnlyFor("heartgold")
      App._bootExisting()
      Assert.equal(App.selectedVersionId, "heartgold")
      result.service.barrierStatus = function()
        return "ready"
      end
      result.service.importSource = function()
        result.importAuthorized = (result.importAuthorized or 0) + 1
        return true
      end
      App._switchEdition("soulsilver")
      Assert.isNil(importerOptions, "no importer starts while source readers are quiescing")
      App.update(0.016)
      Assert.equal(result.importAuthorized, 1)
      Assert.equal(importerOptions.expectedVersionId, "soulsilver")
      Assert.equal(App.state.targetVersion, "soulsilver")
      Assert.equal(App.selectedVersionId, "heartgold", "a missing edition is only an import target until verified")
    end)
  end)
  RomImporter.new = originalNew
  if not ok then
    error(failure, 0)
  end
end

function T.last_played_preference_changes_only_after_successful_game_install()
  local EditionPreference = require("app.src.launcher.EditionPreference")
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold"
  end, function()
    currentOnlyFor("heartgold")
    App._bootExisting()
    App.update(0.016)
    Assert.isNil(EditionPreference.read(), "selecting the installed edition is only a preview")
    App._launchGameWithProvisioner("heartgold", { kind = "new_game" })
    Assert.equal(EditionPreference.read(), "heartgold", "successful game-state installation records play")
  end)
end

function T.failed_game_composition_does_not_change_last_played_preference()
  local EditionPreference = require("app.src.launcher.EditionPreference")
  withAppHarness({ dev = false }, function(versionId)
    return versionId == "heartgold"
  end, function()
    currentOnlyFor("heartgold")
    App._bootExisting()
    App.update(0.016)
    local originalNew = HgssGame.new
    HgssGame.new = function()
      error("injected game composition failure")
    end
    local ok = pcall(App._launchGameWithProvisioner, "heartgold", { kind = "new_game" })
    HgssGame.new = originalNew
    Assert.isFalse(ok, "composition failure remains visible to the caller")
    Assert.isNil(EditionPreference.read(), "failed game construction does not record play")
  end)
end

function T.boot_existing_with_one_ready_version_stages_the_menu_under_startup_title()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- Only heartgold is installed and current; the sibling stays out.
    currentOnlyFor("heartgold")
    App._bootExisting()
    -- The boot gate answers first; startup then stages the menu behind its title.
    App.update(0.016)
    App.update(0.016)
    Assert.equal(#result.launches, 0, "selecting a version installs the product menu without starting retail")
    Assert.equal(App.state.phase, "loading", "missing title assets keep the loading presentation visible")
    Assert.equal(App.state.stagedMenu, result.menus[1], "bootstrap constructs the product menu under title ownership")
    Assert.equal(result.provisionerDisposals, 0, "staging does not dispose its selected provisioner")
    Assert.equal(result.warmups, 0, "near-priority prewarm waits until title readiness")
  end)
end

function T.cancelled_retail_entries_restore_the_product_menu_on_the_same_selection()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- Only heartgold is installed and current; the sibling stays out.
    currentOnlyFor("heartgold")
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
      App._bootExisting()
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

function T.boot_existing_with_two_ready_versions_uses_the_deterministic_first_edition()
  withAppHarness({ dev = true }, function(id)
    return id == "heartgold" or id == "soulsilver"
  end, function(result)
    App._bootExisting()
    Assert.equal(App.selectedVersionId, "heartgold")
    -- The boot gate answers first: readiness continues into the menu.
    App.update(0.016)
      finishStartupTitle(result)
    Assert.equal(#result.launches, 0, "selecting a version installs the product menu")
    Assert.equal(result.menus[1].options.versionId, "heartgold")
    Assert.equal(App.state, result.menus[1])
  end)
end

function T.completed_import_launches_the_imported_version_through_the_hgss_entry()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- A fresh import completes first-play preparation before installing the app menu.
    local original = HgssGame.newFirstPlayCachePreparation
    HgssGame.newFirstPlayCachePreparation = function(_)
      local preparation = {}
      function preparation:poll()
        return true, nil
      end
      function preparation:dispose() end
      return preparation
    end
    local ok, err = pcall(function()
      App._onImported("heartgold")
      -- The boot gate answers first, then the ready closure installs the menu.
      App.update(0.016)
      App.update(0.016)
      Assert.equal(#result.launches, 0, "import completion installs the product menu only")
      Assert.equal(result.menus[1].options.versionId, "heartgold")
      finishStartupTitle(result)
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
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
      currentOnlyFor("heartgold")
      App._bootExisting()
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
      currentOnlyFor("soulsilver")
      App._bootExisting()
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
        currentOnlyFor("heartgold")
        App._bootExisting()
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
function T.fresh_import_stages_menu_before_near_warmup()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._onImported("heartgold")
    App.update(0.016)
    assertStagedStartupMenu(result)
    Assert.isTrue(App.state.initialImport, "the title knows this selection came from import")
    Assert.equal(result.warmups, 0, "background sweep waits until menu handoff")
    result.startupTitleReady = true
    App.update(0.016)
    Assert.equal(getmetatable(App.state).__index, require("app.src.launcher.StartupTitleState"))
    Assert.equal(#result.launches, 0, "title readiness does not launch retail")
  end)
end

-- A cold first import holds its boot card while the selected pair is still
-- pending, then transfers the exact owned presentation and the same pair
-- index to the startup owner without reselecting.
function T.cold_import_startup_hold_transfers_the_adopted_presenter()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    result.walkerReady = false
    App._onImported("heartgold")
    local wait = assert(App.state, "the cold import waits visibly")
    Assert.equal(
      getmetatable(wait).__index,
      CachePreparationState,
      "the pending pair keeps the boot wait installed"
    )
    Assert.isTrue(wait.freshImport, "the fresh import holds its card")
    local chosen = assert(App.pairIndex, "the selection chooses one walking pair")
    Assert.isTrue(chosen >= 1 and chosen <= 32, "the chosen pair index names one of 32 pairs")
    App.update(0.016)
    Assert.equal(App.state, wait, "the admitted gate alone never leaves the cold card")
    Assert.isNil(wait.artFailure, "a pending pair is not a failure")
    result.walkerReady = true
    local StartupTitleState = require("app.src.launcher.StartupTitleState")
    local originalNew = StartupTitleState.new
    local seen = {}
    StartupTitleState.new = function(options)
      seen.loading = options.loading
      seen.pairIndex = options.pairIndex
      return originalNew(options)
    end
    local ok, err = pcall(App.update, 0.016)
    StartupTitleState.new = originalNew
    if not ok then
      error(err, 0)
    end
    Assert.equal(
      getmetatable(App.state).__index,
      StartupTitleState,
      "the adopted pair continues into the startup owner"
    )
    Assert.isTrue(App.state.initialImport, "the title knows this selection came from import")
    Assert.notNil(seen.loading, "the transfer hands over the owned presentation")
    Assert.isTrue(seen.loading == wait.loading, "the transfer hands over the exact owned presentation")
    Assert.equal(seen.pairIndex, chosen, "the transfer forwards the same selected pair")
    for _ = 1, 3 do
      App.update(0.016)
    end
    Assert.equal(App.pairIndex, chosen, "later updates never reselect the pair")
  end)
end

-- Existing selection opens the title before its optional near coordinator.
function T.existing_selection_with_no_completion_stages_the_menu_under_title()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._bootExisting()
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

-- A stale receipt has no effect on menu admission; readiness still starts
-- only after the title has loaded.
function T.existing_selection_with_a_stale_completion_stages_before_warmup()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = true
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._bootExisting()
      -- The boot gate answers first while title assets remain pending.
      App.update(0.016)
      assertStagedStartupMenu(result)
      Assert.equal(script.constructions, nil, "stale receipt does not bypass title readiness")
      result.startupTitleReady = true
      App.update(0.016)
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
    Assert.equal(#result.launches, 0, "title startup does not launch retail")
    Assert.equal(script.constructions, 1, "stale completion enters optional near preparation")
  end)
end

-- Existing completion state does not bypass the title and needs no duplicate
-- near coordinator after title assets are ready.
function T.current_completion_waits_for_title_without_duplicate_warmup()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- Only heartgold carries the current completion; the sibling stays out.
    currentOnlyFor("heartgold")
    local factoryCalls = 0
    local original = HgssGame.newFirstPlayCachePreparation
    if original ~= nil then
      HgssGame.newFirstPlayCachePreparation = function(options)
        factoryCalls = factoryCalls + 1
        return original(options)
      end
    end
    local ok, err = pcall(function()
      App._bootExisting()
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
    App._bootExisting()
    App.update(0.016)
    App.update(0.016)
    assertStagedStartupMenu(result)
    App.keypressed("escape")
    Assert.equal(#result.firstPlayPublished, 0, "cancellation never publishes the completion")
    local selector = App.state
    Assert.equal(getmetatable(selector).__index, VersionSelectState, "cancellation returns to the version selector")
    selector.onPick("heartgold")
    App.update(0.016)
    assertStagedStartupMenu(result)
    Assert.equal(#result.firstPlayPublished, 0, "reselection alone publishes nothing")
  end)
end

-- The optional near coordinator publishes only after its complete result;
-- the title remains usable while the coordinator is pending.
function T.first_play_near_completion_publishes_only_on_success()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._bootExisting()
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
        { { versionId = "heartgold", generationId = "test-generation" } },
        "success publishes the current generation exactly once"
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

-- Unknown generation leaves the title usable and waits without closure
-- requests; a later validated generation lets the near coordinator publish.
function T.unknown_generation_waits_without_demands_during_title()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.cannedGeneration = nil
    result.firstPlayCurrent = false
    result.firstPlayStored = true
    local requests = {}
    result.service.request = function(_, _, selector)
      if selector.name == "new-game-intro" or selector.name == "field-planning" or selector.name == "field-runtime" or selector.requestKind == "battle-presentation" then
        requests[#requests + 1] = selector
      end
    end
    App._bootExisting()
    App.update(0.016)
    assertStagedStartupMenu(result)
    Assert.equal(#result.launches, 0, "title startup does not launch retail")
    Assert.equal(#requests, 0, "no closure demand issues while the generation is unknown")
    result.startupTitleReady = true
    App.update(0.016)
    Assert.equal(getmetatable(App.state).__index, require("app.src.launcher.StartupTitleState"))
    result.cannedGeneration = "test-generation"
    result.firstPlayCurrent = true
    App.update(0.016)
    Assert.equal(#result.menus, 1, "the title keeps its staged product menu")
    Assert.deepEqual(
      result.firstPlayPublished,
      { { versionId = "heartgold", generationId = "test-generation" } },
      "the near coordinator publishes the validated generation"
    )
    finishStartupTitle(result)
    local names, urgencies = requestedMilestones(requests)
    Assert.deepEqual(
      names,
      { "field-planning", "field-runtime", "new-game-intro" },
      "transfer demands the intro prefetch and both field closures"
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
end

-- A failed optional coordinator stays off the menu admission path.
function T.failed_first_play_warmup_does_not_block_title()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local script = { ready = false, failure = "intro milestone failed in the fixture" }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._bootExisting()
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

-- The staged menu and near coordinator share the selected provisioner
-- epoch, which the menu passes to the game launch.
function T.fresh_import_menu_reuses_the_near_warmup_epoch()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._onImported("heartgold")
      App.update(0.016)
      assertStagedStartupMenu(result)
      local epoch = assert(App.epoch, "fresh import borrows a controller epoch")
      local selections = #result.selectOptions
      Assert.equal(script.constructions, nil, "near preparation waits for title readiness")
      result.startupTitleReady = true
      App.update(0.016)
      Assert.equal(script.constructions, 1, "title readiness starts the coordinator")
      finishStartupTitle(result)
      Assert.equal(#result.menus, 1)
      result.menus[1].options.onResult({ kind = "new_game" })
      local launch = assert(result.launches[1], "the menu routes New Game to an explicit retail entry")
      Assert.equal(launch.entry.kind, "new_game")
      Assert.equal(#result.selectOptions, selections, "the launch reuses the preparation epoch without reselection")
      Assert.equal(result.provisionerDisposals, 0, "nothing disposes between preparation and launch")
      Assert.equal(App.epoch, epoch, "the epoch is stable across the handoff")
      Assert.equal(
        launch.derivedAssets,
        script.captured.derivedAssets,
        "the game inherits the same selected derived host"
      )
      Assert.equal(script.captured.versionId, "heartgold", "near preparation serves the imported version")
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- The title starts near work only after readiness; the menu handoff starts
-- the one-time corpus sweep.
function T.fresh_import_defers_near_work_until_title_and_sweep_until_menu()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local requests = recordServiceRequests(result)
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._onImported("heartgold")
      App.update(0.016)
      assertStagedStartupMenu(result)
      Assert.equal(script.constructions, nil, "near coordinator waits for title readiness")
      Assert.equal(result.warmups, 0, "background sweep waits until menu handoff")
      for _, selector in ipairs(requests) do
        Assert.isFalse(
          selector.requestKind == "complete",
          "mandatory import preparation never requests whole-corpus scope"
        )
      end
      result.startupTitleReady = true
      App.update(0.016)
      Assert.equal(script.constructions, 1, "title readiness starts near preparation")
      Assert.equal(#result.launches, 0, "title readiness does not launch retail")
      Assert.equal(result.warmups, 0, "near preparation does not authorize corpus sweep")
      finishStartupTitle(result)
      Assert.equal(#result.menus, 1)
      Assert.equal(result.warmups, 1, "menu handoff authorizes background completion exactly once")
      App.update(0.016)
      Assert.equal(result.warmups, 1, "sweep authorization never repeats")
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- A fresh import uses the title loading surface until its title assets are
-- available, with the product menu already staged underneath.
function T.fresh_import_title_loading_keeps_the_staged_menu()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App.saveDir = "test-save-root"
    App.importer = {
      status = function()
        return { state = "complete", sourceName = "dropped.nds", displayName = "HeartGold" }
      end,
    }
    App._onImported("heartgold")
    Assert.isTrue(App.importer == nil, "the completed importer is released at handoff")
    App.update(0.016)
    assertStagedStartupMenu(result)
    Assert.isTrue(App.state.initialImport, "the startup title retains the import context")
    Assert.equal(App.state.phase, "loading", "title readiness keeps the loading surface visible")
    Assert.equal(#result.launches, 0, "the title never launches retail")
    finishStartupTitle(result)
  end)
end

function T.menu_installation_requests_intro_and_field_closures_at_near_urgency()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- Only heartgold is installed and current; the sibling stays out.
    currentOnlyFor("heartgold")
    local requests = recordServiceRequests(result)
    App._bootExisting()
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
      "startup-loader",
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

-- A version whose derived cache is current boots without its ROM: a moved
-- or missing source file never blocks an installed game, prompts no
-- import, and causes zero ROM file activity on the startup path.
function T.boot_existing_with_a_current_cache_and_no_source_skips_the_import()
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
      result.firstPlayCurrent = true
      result.firstPlayStored = true
      -- The scenario covers one installed version: scope the harness
      -- attestation answers to heartgold so the sibling stays uninstalled
      -- and boot selects exactly one version without source work.
      currentOnlyFor("heartgold")
      App._bootExisting()
      -- The boot gate answers first: readiness continues into the menu.
      App.update(0.016)
      Assert.isNil(App.importer, "a current derived cache never prompts for its ROM")
      assertStagedStartupMenu(result)
      Assert.equal(result.warmups, 0, "near-priority preparation waits until title readiness")
      Assert.equal(#result.launches, 0, "selecting a version installs the menu without starting retail")
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

-- Stubs the native bridge for one import-screen construction: `available`
-- answers the capability probe and `openSingle` answers the dialog.
-- Restores both entrypoints on every path so no test leaks stubs.
---@param available boolean scripted capability answer
---@param openResult table|fun(): table scripted dialog answer
---@param fn fun(opens: fun(): integer)
local function withNativeBridge(available, openResult, fn)
  local NativeRomPicker = require("app.src.launcher.NativeRomPicker")
  local originalAvailable = NativeRomPicker.available
  local originalOpen = NativeRomPicker.openSingle
  NativeRomPicker.available = function()
    return available
  end
  local opens = 0
  NativeRomPicker.openSingle = function()
    opens = opens + 1
    if type(openResult) == "function" then
      return openResult()
    end
    return openResult
  end
  local ok, err = pcall(fn, function()
    return opens
  end)
  NativeRomPicker.available = originalAvailable
  NativeRomPicker.openSingle = originalOpen
  if not ok then
    error(err, 0)
  end
end

-- Boots the pristine first-import card: no ready version, no current
-- attestation anywhere.
---@param fn fun(result: table)
local function withPristineImport(fn)
  withAppHarness({}, function()
    return false
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    App._bootExisting()
    Assert.equal(getmetatable(App.state).__index, ImportState, "an empty shelf boots into the import card")
    fn(result)
  end)
end

-- The first import preselects no edition: the importer session carries no
-- targeted expectation, so any supported ROM is acceptable.
function T.pristine_import_accepts_any_supported_edition()
  local captured = {}
  local originalNew = RomImporter.new
  RomImporter.new = function(options)
    captured = options or {}
    return originalNew(options)
  end
  local ok, err = pcall(function()
    withPristineImport(function(_) end)
  end)
  RomImporter.new = originalNew
  if not ok then
    error(err, 0)
  end
  Assert.isNil(captured.expectedVersionId, "the first import preselects no edition")
end

-- A targeted rebind still carries its expected edition into the importer
-- session, so a wrong ROM cannot satisfy it.
function T.targeted_rebind_carries_its_expected_edition()
  local captured = {}
  local originalNew = RomImporter.new
  RomImporter.new = function(options)
    captured = options or {}
    return originalNew(options)
  end
  local ok, err = pcall(function()
    withAppHarness({}, function()
      return false
    end, function(_)
      App._startImport("soulsilver")
    end)
  end)
  RomImporter.new = originalNew
  if not ok then
    error(err, 0)
  end
  Assert.equal(captured.expectedVersionId, "soulsilver", "a targeted import keeps its expected edition")
end

-- Without a usable native bridge the first card offers no edition switch
-- and no picker banner, and gestures never invoke the bridge.
function T.pristine_import_without_a_bridge_has_no_switch_or_dead_action()
  withNativeBridge(false, { kind = "cancel" }, function(opens)
    withPristineImport(function(_)
      Assert.isNil(App.state.onSwitchEdition, "the first card offers no edition switch")
      Assert.isNil(App.importPickerError, "booting the first card sets no picker banner")
      App.state:mousepressed(400, 300, 1)
      App.state:touchpressed("touch", 400, 300, 0, 0, 1)
      App.state:keypressed("return")
      App.state:keypressed("space")
      Assert.equal(opens(), 0, "an unavailable bridge is never invoked")
      Assert.isNil(App.importPickerError, "inert gestures leave no banner behind")
      Assert.isNil(App.state.pickerError, "inert gestures leave no card banner behind")
    end)
  end)
end

-- With a usable bridge each card gesture opens exactly one dialog, a
-- corner outside the card opens nothing, and cancel leaves the session
-- idle without any banner.
function T.available_picker_opens_once_per_card_gesture_until_cancel()
  withNativeBridge(true, { kind = "cancel" }, function(opens)
    withPristineImport(function(_)
      App.state:mousepressed(400, 300, 1)
      Assert.equal(opens(), 1, "one pointer gesture opens one dialog")
      App.state:touchpressed("touch", 400, 300, 0, 0, 1)
      Assert.equal(opens(), 2, "one touch gesture opens one dialog")
      App.state:mousepressed(16, 16, 1)
      Assert.equal(opens(), 2, "a gesture outside the card opens nothing")
      Assert.isNil(App.importPickerError, "cancel leaves no banner behind")
      Assert.equal(App.importer:status().state, "idle", "cancel leaves the importer idle")
    end)
  end)
end

-- A dialog failure after an available preflight is recoverable: no
-- persistent banner is written and the import card stays usable.
function T.picker_dialog_failure_leaves_no_banner_and_keeps_the_card()
  withNativeBridge(true, { kind = "error", message = "native bridge exploded" }, function(opens)
    withPristineImport(function(_)
      App.state:mousepressed(400, 300, 1)
      Assert.equal(opens(), 1, "the available bridge is tried once")
      Assert.isNil(App.importPickerError, "a dialog failure leaves no shell banner")
      Assert.isNil(App.state.pickerError, "a dialog failure leaves no card banner")
      Assert.equal(getmetatable(App.state).__index, ImportState, "the import card stays usable")
      Assert.equal(App.importer:status().state, "idle", "a dialog failure starts no import")
    end)
  end)
end

-- A picker path with an unsupported extension is rejected without
-- starting an import, and the card stays behind for a retry.
function T.unsupported_picker_extension_rejects_without_starting_import()
  withNativeBridge(true, { kind = "path", path = "/tmp/not-a-rom.exe" }, function(opens)
    withPristineImport(function(_)
      App.state:mousepressed(400, 300, 1)
      Assert.equal(opens(), 1, "the available bridge is tried once")
      Assert.equal(getmetatable(App.state).__index, ImportState, "the import card stays behind for a retry")
      Assert.isNil(App.selectedVersionId, "an unsupported extension admits no verified source")
    end)
  end)
end

-- A fresh import hands its verified bytes to the controller ahead of the
-- boot gate and continues directly into the startup title: no intermediate
-- preparation wait, no display snapshot on the selection handoff. A wrong
-- ROM against a blocked boot keeps the expected version waiting with its
-- mismatch instead of switching the selection.
function T.fresh_import_reaches_title_through_the_boot_gate_without_an_intermediate_wait()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local GameVersion = require("romdump.src.source.GameVersion")
    local StartupTitleState = require("app.src.launcher.StartupTitleState")
    local controlOps = {}
    local offeredBytes, offeredSha1 = nil, nil
    local baseOffer = result.service.offerSource
    result.service.offerSource = function(self, epoch, bytes, identity)
      controlOps[#controlOps + 1] = "offer-source"
      offeredBytes = bytes
      offeredSha1 = identity and identity.romSha1 or nil
      return baseOffer(self, epoch, bytes, identity)
    end
    local baseGate = result.service.requestBootSource
    result.service.requestBootSource = function(self, epoch)
      controlOps[#controlOps + 1] = "check-boot-source"
      return baseGate(self, epoch)
    end
    local originalSelect = App._selectVersion
    local selections = {}
    App._selectVersion = function(versionId, options)
      selections[#selections + 1] = { versionId = versionId, options = options }
      return originalSelect(versionId, options)
    end
    local ok, err = pcall(function()
      local buffer = love.data.newByteData("synthetic-fresh-import-bytes")
      local released = 0
      App.importer = {
        status = function()
          return {
            state = "complete",
            versionId = "heartgold",
            displayName = "HeartGold",
            sourceName = "fresh.nds",
            progress = 1,
          }
        end,
        takeVerifiedSource = function()
          return {
            byteData = function()
              return buffer
            end,
            release = function()
              released = released + 1
            end,
          }
        end,
      }
      App._onImported("heartgold")
      Assert.isNil(App.importer, "the completed importer is released at the handoff")
      Assert.equal(released, 1, "the handoff releases the verified-source wrapper exactly once")
      Assert.deepEqual(
        controlOps,
        { "offer-source", "check-boot-source" },
        "the fresh offer waits behind selection and ahead of the boot gate"
      )
      Assert.isTrue(offeredBytes == buffer, "the offer hands the identical buffer by reference")
      Assert.equal(offeredSha1, GameVersion.info("heartgold").sha1, "the offer carries the canonical ROM identity")
      local fresh = assert(selections[1])
      Assert.equal(fresh.versionId, "heartgold")
      Assert.isTrue(fresh.options.freshImport, "the fresh import marks its selection")
      Assert.isTrue(fresh.options.sourceOffer == buffer, "the selection carries the offered bytes")
      Assert.isNil(fresh.options.importContinuation, "the selection handoff carries no display-only snapshot")
      local waiting = assert(App.state)
      Assert.equal(getmetatable(waiting).__index, CachePreparationState, "a fresh import waits visibly")
      Assert.equal(waiting.kind, "boot-source", "a fresh import waits on its source gate, never an intermediate wait")
      App.update(0.016)
      Assert.equal(
        getmetatable(App.state).__index,
        StartupTitleState,
        "the authorized boot gate continues directly into the title"
      )
      assertStagedStartupMenu(result)
      result.bootStatus = "source-required"
      result.bootDetail = { code = "ROM_SOURCE_REQUIRED", message = "synthetic heartgold missing" }
      App._selectVersion("heartgold")
      App.update(0.016)
      Assert.equal(App.state.kind, "boot-source", "the missing source keeps the boot wait alive")
      App.importer = {
        status = function()
          return {
            state = "complete",
            versionId = "soulsilver",
            displayName = "SoulSilver",
            sourceName = "wrong.nds",
            progress = 1,
          }
        end,
        takeVerifiedSource = function()
          return {
            byteData = function()
              return love.data.newByteData("synthetic-wrong-version-bytes")
            end,
            release = function() end,
          }
        end,
      }
      App._onImported("soulsilver")
      Assert.equal(App.selectedVersionId, "heartgold", "a wrong ROM never switches the blocked selection")
      Assert.equal(App.state.kind, "boot-source", "the wrong ROM keeps the original boot blocked")
      Assert.notNil(App.state.mismatch, "the blocked boot surfaces its version mismatch")
      Assert.equal(#result.menus, 1, "the wrong ROM installs no menu")
      Assert.equal(#result.launches, 0, "the wrong ROM starts no retail")
    end)
    App._selectVersion = originalSelect
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
        Assert.isTrue(
          copy:find(".nds", 1, true) ~= nil,
          "the painted receipt keeps the file kind, got: " .. copy
        )
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
      Assert.isTrue(
        copy:find("File received", 1, true) ~= nil,
        "the first painted frame names the drop, got: " .. copy
      )
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

function T.superseded_import_completion_never_replaces_the_current_selection()
  fresh()
  local originalSelect = App._selectVersion
  local selections = {}
  App._selectVersion = function(versionId, options)
    selections[#selections + 1] = { versionId = versionId, options = options }
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
  local ok, err = xpcall(function()
    App._importReceipt = nil
    App._startImport("soulsilver")
    local currentImporter = assert(App.importer, "the current session owns its importer")
    Assert.equal(App.state.targetVersion, "soulsilver", "the current card targets its edition")
    App._onImported("heartgold")
    Assert.equal(#selections, 0, "a superseded completion never selects its stale version")
    Assert.isTrue(
      App.importer == currentImporter,
      "a superseded completion never releases the current importer"
    )
    currentImporter:filedropped({
      getFilename = function()
        return "photo.png"
      end,
    })
    Assert.equal(
      currentImporter.state,
      RomImporter.STATES.ERROR,
      "the bad file fails the current session"
    )
    Assert.equal(#selections, 0, "a failed current import still selects nothing")
    local shown = captureCopy(function()
      App.draw()
    end)
    Assert.isTrue(
      shown:find("photo.png", 1, true) ~= nil,
      "the current failure names its file, got: " .. shown
    )
    Assert.isTrue(
      shown:find("File received", 1, true) == nil,
      "a rejected file is never acknowledged as received"
    )
  end, debug.traceback)
  App._selectVersion = originalSelect
  fresh()
  if not ok then
    error(err, 0)
  end
end

-- A repeated completion for an already registered ROM stays on the themed
-- warm loader even without the launch-path rebind flag, while a genuinely
-- new ROM keeps its cold artwork card. Classification follows the verified
-- prior binding, never the filename or the entry route alone.
function T.registered_reimport_stays_warm_while_true_first_import_stays_cold()
  local RomBinding = require("romdump.src.source.RomBinding")
  local originalRead = RomBinding.read
  local function completeImporter(versionId)
    return {
      state = "complete",
      status = function()
        return {
          state = "complete",
          progress = 1,
          versionId = versionId,
          displayName = versionId,
          sourceName = versionId .. ".nds",
        }
      end,
      takeVerifiedSource = function()
        return {
          byteData = function()
            return nil
          end,
          release = function()
          end,
        }
      end,
    }
  end
  local function captureCopy(draw)
    local graphics = love.graphics
    local saved = {
      getDimensions = graphics.getDimensions,
      getWidth = graphics.getWidth,
      setColor = graphics.setColor,
      rectangle = graphics.rectangle,
      print = graphics.print,
      printf = graphics.printf,
    }
    local copy = {}
    graphics.getDimensions = function()
      return 800, 600
    end
    graphics.getWidth = function()
      return 800
    end
    graphics.setColor = function()
    end
    graphics.rectangle = function()
    end
    graphics.print = function(value)
      copy[#copy + 1] = tostring(value)
    end
    graphics.printf = function(value)
      copy[#copy + 1] = tostring(value)
    end
    local ok, err = xpcall(draw, debug.traceback)
    graphics.getDimensions = saved.getDimensions
    graphics.getWidth = saved.getWidth
    graphics.setColor = saved.setColor
    graphics.rectangle = saved.rectangle
    graphics.print = saved.print
    graphics.printf = saved.printf
    if not ok then
      error(err, 0)
    end
    return table.concat(copy, "\n")
  end
  RomBinding.read = function(_, versionId)
    if versionId == "soulsilver" then
      return { versionId = "soulsilver", romSha1 = "synthetic-same-sha1" }
    end
    return nil, "synthetic missing registration"
  end
  local ok, err = xpcall(function()
    withAppHarness({ dev = false }, function(id)
      return id == "soulsilver"
    end, function(result)
      result.alreadyRegistered = true
      result.firstPlayCurrent = true
      result.firstPlayStored = true
      App._rebindVersionId = nil
      App.importer = completeImporter("soulsilver")
      App._onImported("soulsilver")
      Assert.equal(
        getmetatable(App.state).__index,
        CachePreparationState,
        "the repeated registered completion waits visibly instead of launching retail"
      )
      Assert.isFalse(App.state.freshImport, "a registered reimport is never a first import")
      local copy = captureCopy(function()
        App.state:draw()
      end)
      Assert.isTrue(
        copy:find("Preparing", 1, true) == nil,
        "the warm loader never shows the cold artwork card, got: " .. copy
      )
      App.update(0.016)
      Assert.equal(
        getmetatable(App.state).__index,
        require("app.src.launcher.StartupTitleState"),
        "the ready pair completes the warm handoff"
      )
      Assert.isFalse(App.state.initialImport, "the warm title knows this selection was not imported fresh")
    end)
    withAppHarness({ dev = false }, function()
      return false
    end, function(result)
      result.firstPlayCurrent = false
      result.firstPlayStored = false
      App.importer = completeImporter("heartgold")
      App._onImported("heartgold")
      Assert.equal(
        getmetatable(App.state).__index,
        CachePreparationState,
        "the first import holds its card"
      )
      Assert.isTrue(App.state.freshImport, "a genuinely new ROM takes the first-import path")
      local copy = captureCopy(function()
        App.state:draw()
      end)
      Assert.isTrue(
        copy:find("Preparing walking sprites", 1, true) ~= nil,
        "the true first import keeps its truthful artwork progress, got: " .. copy
      )
      App.update(0.016)
      Assert.equal(
        getmetatable(App.state).__index,
        require("app.src.launcher.StartupTitleState"),
        "the drawable pair completes the cold handoff"
      )
      Assert.isTrue(App.state.initialImport, "the cold title keeps its bounded beat")
    end)
  end, debug.traceback)
  RomBinding.read = originalRead
  if not ok then
    error(err, 0)
  end
end

-- A warm selection keeps its one published pair across the title handoff,
-- retail entry, and the save editor: every owner forwards the same index
-- without reselecting.
function T.warm_selection_keeps_one_pair_across_title_game_and_editor()
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
  local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
  local savedLoadWalker = StartupAssetCache.loadWalker
  local savedEditorNew = SaveEditorState.new
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
      App._selectVersion("soulsilver")
      App.update(0.016)
      App.update(0.016)
      local StartupTitleState = require("app.src.launcher.StartupTitleState")
      Assert.equal(
        getmetatable(App.state).__index,
        StartupTitleState,
        "the warm pair transfers into startup title ownership"
      )
      Assert.equal(App.pairIndex, 7, "the warm epoch settles on the published pair")
      Assert.isFalse(App.state.initialImport, "the ordinary warm selection takes no import beat")
      finishStartupTitle(result)
      local menu = assert(App.state, "skip installs the staged menu")
      Assert.equal(menu, result.menus[#result.menus], "the exact staged menu installs")
      menu.options.onResult({ kind = "new_game" })
      local launch = assert(result.launches[#result.launches], "retail entry is captured")
      Assert.equal(launch.startupPairIndex, 7, "retail entry forwards the selected pair")
      Assert.equal(App.pairIndex, 7, "entering retail never reselects the pair")
      launch.onExit({ kind = "main_menu" })
      local returned = assert(App.state, "returning installs a menu")
      Assert.equal(App.pairIndex, 7, "returning to the menu never reselects the pair")
      returned.options.onResult({ kind = "edit", saveId = "synthetic-save" })
      Assert.notNil(editorOptions, "the save editor receives the selection")
      Assert.equal(editorOptions.startupPairIndex, 7, "the editor forwards the selected pair")
      Assert.equal(App.pairIndex, 7, "opening the editor never reselects the pair")
    end)
  end, debug.traceback)
  StartupAssetCache.loadWalker = savedLoadWalker
  SaveEditorState.new = savedEditorNew
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
