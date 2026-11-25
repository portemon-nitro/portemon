-- Launcher/process shell for the interactive app root.

local WindowConfig = require("game.src.WindowConfig")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local CacheArchive = require("romdump.src.build.CacheArchive")
local CacheService = require("app.src.CacheService")
local AudioPreferences = require("app.src.AudioPreferences")
local HgssGame = require("game.hgss.src.HgssGame")
local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
local ModPackages = require("app.src.ModPackages")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local BootIntroState = require("app.src.launcher.BootIntroState")
local GameSelectState = require("app.src.launcher.GameSelectState")
local LauncherAudio = require("app.src.launcher.LauncherAudio")
local LauncherRenderer = require("app.src.launcher.LauncherRenderer")
local NativeRomPicker = require("app.src.launcher.NativeRomPicker")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local Errors = require("libs.errors.src.Errors")
local StartupTitleState = require("app.src.launcher.StartupTitleState")
local StartupAudioSession = require("app.src.audio.StartupAudioSession")
local SaveFs = require("libs.storage.src.SaveFs")
local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local DisplayContext = require("libs.ui.src.DisplayContext")

-- Idle retention for the selected epoch's decoded CPU owner: charged, shared
-- decoded results, never the resident base bytes themselves.
local ASSET_RUNTIME_IDLE_BYTES = 64 * 1024 * 1024

---@class App
---@field opts AppOptions
---@field state table<string, unknown>|nil
---@field importer RomImporter|nil
---@field provisioner DerivedAssetProvisioner|nil
---@field service CacheService|nil process-owned cache controller service shared by every selection
---@field epoch integer latest borrowed controller epoch, monotonically increasing
---@field pendingQuiesce table<string, integer>|nil unacknowledged source-close barrier for import
---@field pairIndex integer? selected-epoch walking pair, chosen once per selection
---@field _importReceipt string? received filename latched synchronously on drop/picker input
---@field _pendingImport table<string, unknown>? deferred import descriptor awaiting its receipt paint
---@field _pendingPicker { requestId: string }? active asynchronous native picker/copy
---@field selectedVersionId string? currently selected game version
---@field _libraryMetadata AppSaveMetadata[]? detached published-save metadata for the current library decision
---@field _selectedEntryLocation { mapId: integer, fieldX: integer, fieldZ: integer }? transient copied save hint
---@field _saveLocationWarmup { epoch: integer, versionId: string, preparation: table<string, function> }?|nil
---@field _startupWarmup { epoch: integer, versionId: string, preparation: table<string, function> }?|nil
---@field startupWarmupError string? background preparation diagnostic, never a menu gate
---@field launcherRenderer LauncherRenderer?|nil process-owned launcher painter
---@field launcherAudio LauncherAudio?|nil process-owned launcher cue owner
---@field _bootPending boolean? metadata decision deferred until the first boot paint
---@field startupAudioSession StartupAudioSession?|nil optional selected-version title/menu audio owner
---@field _assetRuntime AppAssetRuntime?|nil one selected-epoch CPU runtime shared by every composition
---@field startupAudioError string?|nil non-gating audio diagnostic
---@field audioPreferences table<string, function>?|nil process-owned app-wide volume port, retained across saves and versions
---@field _swallowedPointers table<string, boolean> pointer releases owned by startup during a transfer
---@field _bootSwallowedInputs table<string, boolean> held initiating boot inputs consumed before a route
---@field drawableWidth number?
---@field drawableHeight number?
---@field pixelRatio number?
local App = {}

---@class AppOptions
---@field test boolean?
---@field dev boolean?

---@class AppSaveMetadata
---@field versionId string?
---@field modifiedAt number?
---@field entryLocation { mapId: integer, fieldX: integer, fieldZ: integer }?
---@field hasError boolean

---@class AppBootCandidate
---@field versionId string
---@field entryLocation { mapId: integer, fieldX: integer, fieldZ: integer }?
---@field ready boolean

---@class AppAssetRuntime
---@field epoch integer selected controller epoch the runtime was installed for
---@field cacheFs table<string, unknown> selected epoch's generated reader: the installed view overlaid by the ordered packages
---@field packages ModPackages ordered selected mod packages this runtime owns
---@field decoded ResidentAssetCache shared decoded CPU owner
---@field preparationQueue AssetPreparationQueue shared preparation queue

-- Version registration only lists candidates for the boot gate: every
-- selection waits for source readiness before the menu, first play, or
-- retail. A registered source, or a derived-cache snapshot on disk, makes a
-- version a candidate; neither fact proves the cache usable, so the
-- controller still decides the boot route. Neither check opens or hashes
-- the ROM.
local function readyVersions()
  local out = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) or CacheArchive.recoverableFileName(versionId) ~= nil then
      out[#out + 1] = versionId
    end
  end
  return out
end

---@param location unknown
---@return { mapId: integer, fieldX: integer, fieldZ: integer }?
local function copyLocation(location)
  if type(location) ~= "table" then
    return nil
  end
  return { mapId = location.mapId, fieldX = location.fieldX, fieldZ = location.fieldZ }
end

---@param versionId string
---@return boolean
local function supported(versionId)
  for _, candidate in ipairs(GameVersion.ORDER) do
    if candidate == versionId then
      return true
    end
  end
  return false
end

local function gameLabel(versionId)
  local ok, info = pcall(GameVersion.info, versionId)
  if ok and type(info) == "table" then
    return info.label or info.displayName or versionId
  end
  return versionId
end

---@return AppSaveMetadata[]?
---@return unknown?
local function readSaveMetadata()
  local store = GameSaveStore.new(SaveFs.global())
  local ok, entries = pcall(store.listMetadata, store)
  if not ok then
    return nil, entries
  end
  assert(type(entries) == "table", "save metadata listing must return an array")
  ---@type AppSaveMetadata[]
  local detached = {}
  for index, entry in ipairs(entries) do
    detached[index] = {
      versionId = entry.versionId,
      modifiedAt = entry.modifiedAt,
      entryLocation = copyLocation(entry.entryLocation),
      hasError = entry.error ~= nil,
    }
  end
  return detached, nil
end

---@param entries AppSaveMetadata[]?
---@param versionId string?
---@return AppBootCandidate?
local function newestSave(entries, versionId)
  if type(entries) ~= "table" then
    return nil
  end
  local newest, newestTime = nil, nil
  for _, entry in ipairs(entries) do
    local modifiedAt = entry.modifiedAt
    if
      not entry.hasError
      and type(entry.versionId) == "string"
      and supported(entry.versionId)
      and (versionId == nil or entry.versionId == versionId)
      and type(modifiedAt) == "number"
      and modifiedAt == modifiedAt
      and math.abs(modifiedAt) < math.huge
      and (newestTime == nil or modifiedAt > newestTime)
    then
      newest, newestTime = entry, modifiedAt
    end
  end
  if newest == nil then
    return nil
  end
  local newestVersionId = assert(newest.versionId, "supported save metadata names its game")
  return { versionId = newestVersionId, entryLocation = copyLocation(newest.entryLocation) }
end

local function provisionerOptions(versionId)
  -- Every selection borrows a fresh controller epoch, even when the
  -- logical generation is unchanged. Only selectors cross the channel:
  -- the development producer digest and the generation identity are
  -- derived below the controller thread, never on the game thread.
  App._ensureService()
  local options = {
    versionId = versionId,
    service = assert(App.service, "process cache service is unavailable"),
    development = App.opts.dev == true,
  }
  if App.opts.dev == true then
    options.developmentRepositoryRoot = love.filesystem.getSourceBaseDirectory()
  end
  return options
end

-- Physical preparation slots the selected runtime's executor may fill. A
-- loader presentation keeps one more decode overlapping the compiler (its jobs
-- are per-scene one-shots, so a second slot keeps the frontier moving while the
-- compiler holds the rest of the host); ordinary gameplay keeps exactly the one
-- slot it has always used. This is deliberately not a processor-count budget:
-- the compiler pool already owns that, and a loader must not staff two
-- independent host-sized pools.
local PREPARATION_LOADER_SLOTS = 2

---@param loading boolean
---@return integer
local function preparationWorkerSlots(loading)
  if not loading then
    return 1
  end
  return PREPARATION_LOADER_SLOTS
end

function App._ensureService()
  if App.service ~= nil then
    return
  end
  App.service = CacheService.new()
end

local function importInProgress(importer)
  if importer == nil then
    return false
  end
  if type(importer.isBusy) == "function" and importer:isBusy() then
    return true
  end
  if type(importer.status) == "function" then
    local status = importer:status()
    return type(status) == "table" and status.canCancel == true
  end
  return false
end

local IMPORT_UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

-- Called once at process startup, before an importer can own a stage. Only
-- bridge-shaped temporary names are eligible; canonical sources and saves are
-- never scanned.
function App._cleanupAbandonedImports()
  local info = love.filesystem.getInfo("imports")
  if info == nil or info.type ~= "directory" then
    return
  end
  for _, name in ipairs(love.filesystem.getDirectoryItems("imports")) do
    local path = "imports/" .. name
    local entry = love.filesystem.getInfo(path)
    if
      entry ~= nil
      and entry.type == "file"
      and (
        name:match("^(" .. IMPORT_UUID .. ")%.nds$")
        or name:match("^(" .. IMPORT_UUID .. ")%.zip$")
        or name:match("^(" .. IMPORT_UUID .. ")%.part$")
      )
    then
      love.filesystem.remove(path)
    end
  end
end

-- Retire the interactive import session without blocking: a queued worker is
-- told to abandon its registration gate, late results are invalidated, and
-- the pending first-paint descriptor is dropped so no worker starts later.
function App._cancelImport()
  local pending = App._pendingImport
  if pending ~= nil and pending.kind == "temporary" and not pending.started then
    love.filesystem.remove(pending.value)
  end
  App._pendingPicker = nil
  if App.state ~= nil and type(App.state.setPickerPending) == "function" then
    App.state:setPickerPending(false)
  end
  local importer = App.importer
  App.importer = nil
  App._pendingImport = nil
  if importer ~= nil and type(importer.cancelQueued) == "function" then
    importer:cancelQueued()
  end
end

-- Retires the selected source interest without joining controller work.
-- Consumers stop before their reader is revoked: the installed view is
-- retired only after the presented state, the startup audio, the warmup and
-- the shared decoded owner have released what they borrowed from it. The
-- process service is reused; stale results cannot publish afterwards.
function App._retireSelection()
  App.setState(nil)
  -- A retired selection owns no execution policy: the replacement epoch starts
  -- under the ordinary interactive policy until its own presentation reports.
  App._cacheLoading = false
  App._swallowedPointers = {}
  App.pairIndex = nil
  App.splRandomState = nil
  App._importReceipt = nil
  App._cancelImport()
  App._releaseStartupAudio()
  local locationWarmup = App._saveLocationWarmup
  App._saveLocationWarmup = nil
  if locationWarmup ~= nil then
    locationWarmup.preparation:dispose()
  end
  local warmup = App._startupWarmup
  App._startupWarmup = nil
  if warmup ~= nil then
    warmup.preparation:dispose()
  end
  App._releaseAssetRuntime()
  local provisioner = App.provisioner
  App.provisioner = nil
  if provisioner then
    provisioner:dispose()
  end
  App._selectedEntryLocation = nil
  App._libraryMetadata = nil
end

-- The selected epoch's one decoded CPU runtime. It exists only while the
-- controller has installed a reader for the live epoch: the shared queue is
-- released (draining and joining any started worker) before the decoded kernel
-- clears, because running work still roots decoded backing, and the mounted
-- packages go away only after both. Every consumer composes over this record;
-- none owns or releases it.
function App._releaseAssetRuntime()
  local record = App._assetRuntime
  if record == nil then
    return
  end
  -- Later owners borrow resources released by earlier owners, so do not
  -- advance teardown when one owner fails. Keep the record available for the
  -- next close attempt and prohibit a replacement selection from orphaning it.
  record.preparationQueue:release()
  record.decoded:clear()
  record.packages:close()
  App._assetRuntime = nil
end

-- One tenancy per live selected epoch: the same record answers every
-- composition until the selection retires. It exists only once the controller
-- has installed the epoch's generated bytes and their identity, because the
-- ordered package selection is validated against that identity. Construction
-- publishes only after every owner exists, so a failed construction leaves no
-- half-installed runtime and nothing to hand a consumer.
---@param epoch integer
---@return AppAssetRuntime?
function App._ensureAssetRuntime(epoch)
  if epoch == nil or App.epoch ~= epoch then
    return nil
  end
  local existing = App._assetRuntime
  if existing ~= nil and existing.epoch == epoch then
    return existing
  end
  assert(existing == nil, "the previous asset runtime must close before a replacement selection")
  local service = App.service
  if service == nil then
    return nil
  end
  local baseFs = service:getCacheFs(epoch)
  if baseFs == nil then
    return nil
  end
  local installed = service:cacheIdentity(epoch)
  if installed == nil then
    return nil
  end
  -- Packages live under the installed identity's version directory and must
  -- match that identity, so the installed record supplies both: the game thread
  -- never derives a cache identity of its own.
  ---@cast installed ModArchive.Identity
  local packages = assert(ModPackages.open(installed.versionId, installed, epoch))
  local overlayOk, cacheFsOrError = pcall(baseFs.withPackages, baseFs, packages)
  if not overlayOk then
    pcall(packages.close, packages)
    error(cacheFsOrError, 0)
  end
  local cacheFs = cacheFsOrError
  local decoded = ResidentAssetCache.new({
    idleByteLimit = ASSET_RUNTIME_IDLE_BYTES,
    release = function(value)
      value:release()
    end,
  })
  local ok, queueOrError = pcall(AssetPreparationQueue.new, cacheFs, {
    decoded = decoded,
    -- The runtime is created under the presentation policy already in force: a
    -- cold boot installs its reader while a loader owns the screen, so a queue
    -- built with the ordinary budget would never be widened afterwards.
    workerSlots = preparationWorkerSlots(App._cacheLoading == true),
  })
  if not ok then
    pcall(decoded.clear, decoded)
    pcall(packages.close, packages)
    error(queueOrError, 0)
  end
  local record = {
    epoch = epoch,
    cacheFs = cacheFs,
    packages = packages,
    decoded = decoded,
    preparationQueue = queueOrError,
  }
  App._assetRuntime = record
  return record
end

function App._releaseStartupAudio()
  local session = App.startupAudioSession
  App.startupAudioSession = nil
  if session ~= nil then
    session:dispose()
  end
end

function App._recordStartupAudioError(failure)
  local diagnostic = tostring(failure)
  if App.startupAudioError == diagnostic then
    return
  end
  App.startupAudioError = diagnostic
  print("Startup audio disabled: " .. diagnostic)
end

-- Optional audio readiness for the selected epoch. The session must never
-- be constructed while its banks are still pending or have failed: absence
-- of audio stays silent and retryable instead of blocking the visuals.
---@return boolean
local function startupAudioReady()
  local provisioner = App.provisioner
  if provisioner == nil or type(provisioner.gameHost) ~= "function" then
    return false
  end
  local okHost, host = pcall(provisioner.gameHost, provisioner)
  if not okHost or type(host) ~= "table" or type(host.requestMilestone) ~= "function" then
    return false
  end
  local ok, ready, failure = pcall(host.requestMilestone, "startup-audio", "near")
  if not ok then
    return false
  end
  if failure ~= nil then
    App._recordStartupAudioError(failure)
    return false
  end
  return ready == true
end

---@param versionId string
---@param epoch integer
---@return StartupAudioSession|nil
---@param titleRecord { crySpeciesId: integer }?
function App._ensureStartupAudio(versionId, epoch, titleRecord)
  if App.epoch ~= epoch or App.selectedVersionId ~= versionId then
    return nil
  end
  if App.startupAudioSession ~= nil then
    if titleRecord ~= nil then
      local ok, failure = pcall(App.startupAudioSession.bindTitleRecord, App.startupAudioSession, titleRecord)
      if not ok then
        App._recordStartupAudioError(failure)
        App._releaseStartupAudio()
        return nil
      end
    end
    return App.startupAudioSession
  end
  if not startupAudioReady() then
    return nil
  end
  local ok, sessionOrError = pcall(function()
    local runtime = assert(App._ensureAssetRuntime(epoch), "startup audio needs the selected CPU runtime")
    return StartupAudioSession.new({
      versionId = versionId,
      cacheFs = runtime.cacheFs,
      assetRuntime = runtime,
      titleRecord = titleRecord,
    })
  end)
  if not ok then
    App._recordStartupAudioError(sessionOrError)
    return nil
  end
  local session = assert(sessionOrError)
  App.startupAudioSession = session
  return session
end

---@param versionId string
---@param epoch integer
---@return table<string, function> borrowed semantic callbacks
local function startupAudioBorrow(versionId, epoch)
  local function invoke(method, create, titleRecord, ...)
    if App.epoch ~= epoch or App.selectedVersionId ~= versionId then
      return
    end
    local session = create and App._ensureStartupAudio(versionId, epoch, titleRecord) or App.startupAudioSession
    if session == nil or type(session[method]) ~= "function" then
      return
    end
    local ok, failure
    if titleRecord ~= nil then
      ok, failure = pcall(session[method], session, titleRecord, ...)
    else
      ok, failure = pcall(session[method], session, ...)
    end
    if not ok then
      App._recordStartupAudioError(failure)
      App._releaseStartupAudio()
    end
  end
  return {
    -- Reports the current-epoch opening start result: true only after the
    -- selected session accepts SEQ_GS_TITLE. A stale epoch, missing
    -- session or callback, rejected play, or composition failure admits
    -- no movie and returns its reason instead of succeeding silently.
    ---@return boolean acknowledged
    ---@return string? reason
    openingReady = function()
      if App.epoch ~= epoch or App.selectedVersionId ~= versionId then
        return false, "stale selection epoch"
      end
      local session = App.startupAudioSession
      if session == nil then
        session = App._ensureStartupAudio(versionId, epoch, nil)
        if session == nil then
          return false, App.startupAudioError or "startup audio unavailable"
        end
      end
      if type(session.beginOpening) ~= "function" then
        App._recordStartupAudioError("startup audio cannot start the opening track")
        return false, "startup audio cannot start the opening track"
      end
      local ok, acknowledged, reason = pcall(session.beginOpening, session)
      if not ok then
        App._recordStartupAudioError(acknowledged)
        App._releaseStartupAudio()
        return false, tostring(acknowledged)
      end
      if acknowledged ~= true then
        local detail = reason or App.startupAudioError or "startup audio unavailable"
        App._recordStartupAudioError(detail)
        if session.disposed then
          App._releaseStartupAudio()
        end
        return false, detail
      end
      return true, nil
    end,
    titleReady = function(titleRecord)
      invoke("beginTitle", true, titleRecord)
    end,
    prompt = function(titleRecord)
      invoke("notifySkip", true, titleRecord)
    end,
    skip = function()
      invoke("beginFade", false)
    end,
    beginMovieCycle = function()
      invoke("beginMovieCycle", false)
    end,
    playMenuCue = function(kind)
      invoke("playMenuCue", true, nil, kind)
    end,
  }
end

-- The session's selected walking pair, chosen once per selected epoch by the
-- import/selection flow. Game and editor loading journeys only forward it;
-- they never reselect or randomize a pair locally.
---@return integer selected walking pair within the loading stage's pool
local function selectedPairIndex()
  local pairIndex = App.pairIndex
  assert(
    type(pairIndex) == "number"
      and pairIndex % 1 == 0
      and pairIndex >= 1
      and pairIndex <= HgssLoadingPresentation.walkerPairCount(),
    "selection has no walking pair"
  )
  return pairIndex --[[@as integer]]
end

---@param versionId string
---@return table<string, unknown> staged MainMenuState
local function stageMenu(versionId)
  local audio = App.epoch ~= nil and startupAudioBorrow(versionId, App.epoch) or nil
  local runtime = assert(App._ensureAssetRuntime(App.epoch), "the Main Menu needs the selected CPU runtime")
  local ok, menuOrError = pcall(MainMenuComposition.new, {
    versionId = versionId,
    cacheFs = runtime.cacheFs,
    assetRuntime = runtime,
    width = App.drawableWidth,
    height = App.drawableHeight,
    audio = audio,
    onResult = function(result)
      if result.kind == "new_game" then
        App._launchGameWithProvisioner(versionId, { kind = "new_game" })
      elseif result.kind == "continue" then
        App._launchGameWithProvisioner(versionId, { kind = "continue", saveId = result.saveId })
      elseif result.kind == "edit" then
        App._disposeSaveLocationWarmup()
        local provisioner = assert(App.provisioner, "save editing needs the selected provisioner")
        local ok, stateOrError = pcall(function()
          local editorRuntime =
            assert(App._ensureAssetRuntime(App.epoch), "save editing needs the selected CPU runtime")
          return SaveEditorState.new({
            versionId = versionId,
            cacheFs = editorRuntime.cacheFs,
            assetRuntime = editorRuntime,
            saveId = assert(result.saveId),
            startupPairIndex = selectedPairIndex(),
            width = App.drawableWidth,
            height = App.drawableHeight,
            derivedAssets = provisioner:gameHost(),
            repositoryRoot = love.filesystem.getSourceBaseDirectory(),
            onResult = function(editorResult)
              if editorResult.kind == "main_menu" then
                App._restoreMenuWithProvisioner(versionId)
              end
            end,
          })
        end)
        if not ok then
          App._restoreMenuWithProvisioner(versionId)
          error(stateOrError, 0)
        end
        App.setState(assert(stateOrError))
      elseif result.kind == "game_selection" then
        App._showGameSelection(versionId)
      elseif result.kind == "quit" then
        love.event.quit(0)
      end
    end,
  })
  if not ok then
    error(menuOrError, 0)
  end
  return assert(menuOrError)
end

---@param versionId string
---@return table<string, unknown> fully constructed menu, still owned by caller
function App._stageMenu(versionId)
  return stageMenu(versionId)
end

local function installMenu(versionId)
  local ok, menu = pcall(stageMenu, versionId)
  if not ok then
    App._showGameSelection(versionId)
    error(menu, 0)
  end
  App.setState(assert(menu))
end

-- Save-agnostic gameplay warmup fired once at opening title entry:
-- near-priority milestones, the shared battle presentation, and
-- background corpus authorization all enroll while the cinematic still
-- plays, so the menu opens onto already-warming work. The optional
-- first-play closure keeps its own title-readiness gate and starts
-- separately. Every step is contained so warmup only records
-- diagnostics, never throws back into the title journey. A stale entry
-- enrolls nothing.
---@param versionId string
---@param epoch integer
function App._beginSaveAgnosticWarmup(versionId, epoch)
  if App.epoch ~= epoch or App.selectedVersionId ~= versionId then
    return
  end
  local provisioner = App.provisioner
  if provisioner == nil then
    return
  end
  local hostOk, host = pcall(provisioner.gameHost, provisioner)
  if hostOk and type(host) == "table" then
    for _, name in ipairs({ "new-game-intro", "field-planning", "field-runtime" }) do
      local ok, failure = pcall(host.requestMilestone, name, "near")
      if not ok then
        App.startupWarmupError = tostring(failure)
      end
    end
    -- The Pokedex presentation scope compiles every browser page's chrome
    -- and its manifest, so a first open must never be the request that
    -- starts that work: enroll it beside the field milestones while the
    -- cinematic still plays.
    local dexOk, dexFailure = pcall(host.requestPokedex, "near")
    if not dexOk then
      App.startupWarmupError = tostring(dexFailure)
    end
    local battleOk, battleFailure = pcall(host.requestBattlePresentation, "near")
    if not battleOk then
      App.startupWarmupError = tostring(battleFailure)
    end
  end
  local warmupOk, warmupFailure = pcall(provisioner.startBackgroundWarmup, provisioner)
  if not warmupOk then
    App.startupWarmupError = tostring(warmupFailure)
  end
end

-- Installs the selected-version product menu. Save-agnostic warmup no
-- longer starts here: the opening title entry fires it while the
-- cinematic still plays, so the installed menu never re-enrolls it.
---@param versionId string
---@param stagedMenu table<string, unknown>?
function App._launchMenuWithProvisioner(versionId, stagedMenu)
  if stagedMenu == nil then
    installMenu(versionId)
  else
    assert(type(stagedMenu) == "table" and type(stagedMenu.dispose) == "function")
    App.setState(stagedMenu)
  end
end

-- Optional near-priority preparation runs beside the startup presentation;
-- first play becomes the installed epoch's fact once the closure settled.
---@param versionId string
---@param epoch integer
function App._maybeStartFirstPlayWarmup(versionId, epoch)
  if App._startupWarmup ~= nil or App.epoch ~= epoch or App.selectedVersionId ~= versionId then
    return
  end
  if App.service ~= nil and App.service:firstPlayReady(epoch) then
    return
  end
  local provisioner = App.provisioner
  if provisioner == nil then
    return
  end
  local ok, preparation = pcall(HgssGame.newFirstPlayCachePreparation, {
    versionId = versionId,
    derivedAssets = provisioner:gameHost(),
    completion = App._firstPlayGateway(epoch),
    urgency = "near",
  })
  if not ok then
    App.startupWarmupError = tostring(preparation)
    return
  end
  App._startupWarmup = { epoch = epoch, versionId = versionId, preparation = preparation }
end

function App._updateStartupWarmup()
  local warmup = App._startupWarmup
  if warmup == nil then
    return
  end
  if warmup.epoch ~= App.epoch or warmup.versionId ~= App.selectedVersionId then
    warmup.preparation:dispose()
    App._startupWarmup = nil
    return
  end
  local ok, ready, failure = pcall(warmup.preparation.poll, warmup.preparation)
  if not ok or failure ~= nil then
    App.startupWarmupError = tostring(ok and failure or ready)
    warmup.preparation:dispose()
    App._startupWarmup = nil
  elseif ready then
    App._publishFirstPlay(warmup.versionId, warmup.epoch)
    warmup.preparation:dispose()
    App._startupWarmup = nil
  end
end

function App._disposeSaveLocationWarmup()
  local warmup = App._saveLocationWarmup
  App._saveLocationWarmup = nil
  if warmup ~= nil then
    warmup.preparation:dispose()
  end
end

function App._maybeStartSaveLocationWarmup(versionId, epoch)
  local location = App._selectedEntryLocation
  if location == nil or App._saveLocationWarmup ~= nil or App.epoch ~= epoch or App.selectedVersionId ~= versionId then
    return
  end
  local provisioner = App.provisioner
  if provisioner == nil then
    return
  end
  local entryLocation = assert(copyLocation(location), "a selected save location is copyable")
  local ok, preparation = pcall(HgssGame.newSaveLocationPreparation, {
    versionId = versionId,
    entryLocation = entryLocation,
    derivedAssets = provisioner:gameHost(),
  })
  if not ok then
    App.startupWarmupError = tostring(preparation)
    return
  end
  App._saveLocationWarmup = { epoch = epoch, versionId = versionId, preparation = preparation }
end

function App._updateSaveLocationWarmup()
  local warmup = App._saveLocationWarmup
  if warmup == nil then
    return
  end
  if warmup.epoch ~= App.epoch or warmup.versionId ~= App.selectedVersionId then
    App._disposeSaveLocationWarmup()
    return
  end
  local ok, ready, failure = pcall(warmup.preparation.poll, warmup.preparation)
  if not ok or failure ~= nil or ready == true then
    if not ok or failure ~= nil then
      App.startupWarmupError = tostring(ok and failure or ready)
    end
    App._disposeSaveLocationWarmup()
  end
end

-- Cancellation restores only the menu state; the current selection and its
-- warmup authorization remain owned by the App.
---@param versionId string
function App._restoreMenuWithProvisioner(versionId)
  assert(App.provisioner, "selection has no provisioner")
  App._ensureStartupAudio(versionId, App.epoch)
  installMenu(versionId)
end

---@param versionId string
---@param entry table<string, unknown>
function App._launchGameWithProvisioner(versionId, entry)
  local provisioner = assert(App.provisioner, "selection has no provisioner")
  App._disposeSaveLocationWarmup()
  App._releaseStartupAudio()
  local runtime = assert(App._ensureAssetRuntime(App.epoch), "the retail entry needs the selected CPU runtime")
  local ok, gameOrError = pcall(HgssGame.new, {
    versionId = versionId,
    cacheFs = runtime.cacheFs,
    assetRuntime = runtime,
    startupPairIndex = selectedPairIndex(),
    entry = entry,
    audioPreferences = App.audioPreferences,
    onExit = function(result)
      if result and result.kind == "main_menu" then
        App._restoreMenuWithProvisioner(versionId)
      elseif result and result.kind == "quit" then
        love.event.quit(0)
      end
    end,
    development = App.opts.dev,
    derivedAssets = provisioner:gameHost(),
    splRandomState = App.splRandomState,
  })
  if not ok then
    App._showGameSelection(versionId)
    error(gameOrError, 0)
  end
  App.setState(assert(gameOrError))
end

function App._ensureLauncherResources()
  if App.launcherRenderer == nil then
    App.launcherRenderer = LauncherRenderer.new()
  end
  if App.launcherAudio == nil then
    App.launcherAudio = LauncherAudio.new()
  end

end

function App._releaseLauncherResources()
  if App.launcherAudio ~= nil then
    App.launcherAudio:dispose()
    App.launcherAudio = nil
  end
  if App.launcherRenderer ~= nil then
    App.launcherRenderer:dispose()
    App.launcherRenderer = nil
  end
end

local function gameSnapshot(entries)
  if entries == nil then
    entries = readSaveMetadata()
  end
  local ready = {}
  for _, versionId in ipairs(readyVersions()) do
    ready[versionId] = true
  end
  local hasSave, named = {}, {}
  for _, entry in ipairs(entries or {}) do
    if not entry.hasError and supported(entry.versionId) then
      hasSave[entry.versionId] = true
      named[entry.versionId] = true
    end
  end
  local games = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if ready[versionId] or named[versionId] then
      games[#games + 1] = {
        gameId = versionId,
        versionId = versionId,
        label = gameLabel(versionId),
        ready = ready[versionId] == true,
        hasSave = hasSave[versionId] == true,
      }
    end
  end
  return games, entries
end

local function launcherDisplayContext()
  return DisplayContext.new({
    topologyProvider = function(width, height)
      local rect = { x = 0, y = 0, width = width, height = height }
      local os = love.system.getOS()
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = rect,
            safeRect = App._safeRect or rect,
            touch = os == "Android" or os == "iOS",
          },
        },
      }
    end,
  })
end

function App._newGameSelectState(focusGameId, failure, entries)
  App._ensureLauncherResources()
  local games, metadata = gameSnapshot(entries)
  App._libraryMetadata = metadata
  return GameSelectState.new({
    games = games,
    initialGameId = focusGameId,
    importer = App.importer,
    failure = failure,
    pickerAvailable = NativeRomPicker.available(),
    renderer = App.launcherRenderer,
    audio = App.launcherAudio,
    width = App.drawableWidth,
    height = App.drawableHeight,
    displayContext = launcherDisplayContext(),
    onPick = App._requestGameImport,
    onPlay = function(versionId)
      local candidate = newestSave(App._libraryMetadata, versionId)
      App._selectVersion(versionId, { entryLocation = candidate and candidate.entryLocation or nil })
    end,
    onCancelImport = function()
      local current = App.state
      local focus = current and current.view and current:view().focusedId or nil
      App._cancelImport()
      App._showGameSelection(focus)
    end,
    onDismissError = function(focusedId)
      App._showGameSelection(focusedId)
    end,
    onQuit = function()
      love.event.quit(0)
    end,
  })
end

function App._showGameSelection(focusGameId, failure, entries)
  App._retireSelection()
  App.selectedVersionId = nil
  App.setState(App._newGameSelectState(focusGameId, failure, entries))
end

-- A pending source-close barrier blocks new selections behind a visible
-- wait: no new session writes shared version roots before the controller
-- acknowledges that every source reader closed successfully.
---@param versionId string newly selected game version
---@param options { entryLocation: { mapId: integer, fieldX: integer, fieldZ: integer }? }?
---@return boolean
function App._waitForQuiescence(versionId, options)
  local pending = App.pendingQuiesce
  local service = App.service
  if pending == nil or service == nil then
    return false
  end
  if service:barrierStatus(pending.epoch, pending.barrier) == "ready" then
    App.pendingQuiesce = nil
    return false
  end
  App.setState(CachePreparationState.new({
    kind = "quiescence",
    epoch = pending.epoch,
    service = service,
    barrier = pending.barrier,
    renderer = App.launcherRenderer,
    safeRect = App._safeRect,
    isCurrent = function(_)
      return App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier == pending.barrier
    end,
    onReady = function()
      App.pendingQuiesce = nil
      App._selectVersion(versionId, options)
    end,
    onCancel = function()
      App.pendingQuiesce = nil
      App._showGameSelection()
    end,
  }))
  return true
end

-- First-play generation for one selection: the controller-derived token
-- when known, else the synchronous release identity (pure constants, no
-- producer scan). Development selections without a controller answer yet
-- report unknown; the caller prepares again. Never reads or writes cache
-- files: first play is a captured fact of the installed epoch.
---@param versionId string newly selected game version
---@return string?
function App._firstPlayGeneration(versionId)
  local provisioner = App.provisioner
  if provisioner ~= nil and type(provisioner.generationId) == "function" then
    local known = provisioner:generationId()
    if known ~= nil then
      return known
    end
  end
  if App.opts.dev == true then
    return nil
  end
  local ok, generation = pcall(DerivedCacheState.releaseGenerationId, versionId)
  if ok then
    return generation
  end
  return nil
end

-- Gateway handed to first-play preparation: the answers come from the
-- selected epoch's installed facts, so a boot that already captured first
-- play transfers without demanding the closure again. It captures the
-- epoch, so a stale gateway never reports another selection's progress.
---@param epoch integer selected controller epoch
---@return table<string, function>
function App._firstPlayGateway(epoch)
  local provisioner = App.provisioner
  local function installed()
    local service = App.service
    return service ~= nil and App.epoch == epoch and service:firstPlayReady(epoch) == true
  end
  return {
    hasStored = installed,
    isCurrent = function(_)
      return installed()
    end,
    currentGeneration = function()
      if provisioner == nil or type(provisioner.generationId) ~= "function" then
        return nil
      end
      return provisioner:generationId()
    end,
  }
end

-- Record first play as a fact of the selection that proved the closure. The
-- controller captures it with that closure's own sequence, so a failed or
-- partial persistence never turns into a false completion. Failure and
-- cancellation paths never reach this function, so they never record it.
---@param versionId string newly selected game version
---@param epoch integer selected controller epoch
function App._publishFirstPlay(versionId, epoch)
  if App.epoch ~= epoch or App.selectedVersionId ~= versionId then
    return
  end
  local service = App.service
  if service == nil then
    return
  end
  pcall(service.recordFirstPlay, service, epoch)
end

-- Selects one game through the existing source/epoch gate.
---@param versionId string
---@param options { entryLocation: { mapId: integer, fieldX: integer, fieldZ: integer }? }?
function App._selectVersion(versionId, options)
  if App._waitForQuiescence(versionId, options) then
    return
  end
  App.selectedVersionId = versionId
  App._retireSelection()
  App._ensureLauncherResources()
  if options ~= nil and options.entryLocation ~= nil then
    local location = assert(options.entryLocation, "selected entry location is present")
    App._selectedEntryLocation = { mapId = location.mapId, fieldX = location.fieldX, fieldZ = location.fieldZ }
  end
  local provisioner = DerivedAssetProvisioner.new(provisionerOptions(versionId))
  App.provisioner = provisioner
  App.epoch = assert(provisioner.epoch, "selection borrowed no epoch")
  App.pairIndex = math.floor(love.math.random(1, HgssLoadingPresentation.walkerPairCount()))
  App.splRandomState = { state = 0 }
  local epoch = App.epoch
  local service = assert(App.service, "process cache service is unavailable")
  service:requestBootSource(epoch)
  App.setState(CachePreparationState.new({
    kind = "boot-source",
    epoch = epoch,
    service = service,
    versionId = versionId,
    label = gameLabel(versionId),
    renderer = App.launcherRenderer,
    safeRect = App._safeRect,
    isCurrent = function(selected)
      return App.epoch == selected and App.selectedVersionId == versionId
    end,
    onReady = function()
      App._continueSelectedVersion(versionId)
    end,
    onFailure = function(detail)
      if App.epoch == epoch and App.selectedVersionId == versionId then
        App._showGameSelection(versionId, detail)
      end
    end,
    onCancel = function()
      App._showGameSelection(versionId)
    end,
  }))
end

-- Resolve the selected runtime before detaching the neutral presentation.
-- Expected composition failures leave it owned by the wait until recovery.
function App._continueSelectedVersion(versionId)
  local epoch = App.epoch
  local provisioner = assert(App.provisioner, "boot continuation needs the selected provisioner")
  local previous = App.state
  assert(previous ~= nil and type(previous.takeLoading) == "function", "boot continuation needs its loading owner")
  local runtimeOk, runtimeOrError = pcall(App._ensureAssetRuntime, epoch)
  if not runtimeOk or runtimeOrError == nil then
    local failure = runtimeOk and "selected runtime is unavailable" or runtimeOrError
    if not runtimeOk and not Errors.is(failure) then
      App._showGameSelection(versionId)
      error(failure, 0)
    end
    App._showGameSelection(versionId, failure)
    return
  end
  local runtime = runtimeOrError
  local loading = previous:takeLoading()
  local width, height = love.graphics.getDimensions()
  local constructed, stateOrError = pcall(StartupTitleState.new, {
    versionId = versionId,
    epoch = epoch,
    cacheFs = runtime.cacheFs,
    assetRuntime = runtime,
    derivedAssets = provisioner:gameHost(),
    splRandomState = App.splRandomState,
    width = width,
    height = height,
    loading = loading,
    pairIndex = App.pairIndex,
    audio = startupAudioBorrow(versionId, epoch),
    isCurrent = function(selected)
      return App.epoch == selected and App.selectedVersionId == versionId
    end,
    stageMenu = function()
      return App._stageMenu(versionId)
    end,
    onFinished = function(menu)
      if App.epoch == epoch and App.selectedVersionId == versionId then
        App._launchMenuWithProvisioner(versionId, menu)
      else
        menu:dispose()
      end
    end,
    onCancel = function()
      if App.epoch == epoch and App.selectedVersionId == versionId then
        App._showGameSelection(versionId)
      end
    end,
    onTitleReady = function()
      App._maybeStartFirstPlayWarmup(versionId, epoch)
    end,
    beginWarmup = function()
      App._beginSaveAgnosticWarmup(versionId, epoch)
      App._maybeStartSaveLocationWarmup(versionId, epoch)
    end,
  })
  if not constructed then
    loading:dispose()
    error(stateOrError, 0)
  end
  App.setState(assert(stateOrError))
end

local function versionReady(versionId)
  for _, candidate in ipairs(readyVersions()) do
    if candidate == versionId then
      return true
    end
  end
  return false
end

function App._prepareBootCandidate()
  if not App._bootPending then
    return
  end
  App._bootPending = false
  local metadata = readSaveMetadata()
  App._libraryMetadata = metadata
  local candidate = newestSave(metadata)
  if candidate ~= nil then
    candidate.ready = versionReady(candidate.versionId)
  end
  if App.state ~= nil and type(App.state.setCandidate) == "function" then
    App.state:setCandidate(candidate)
  end
  return candidate
end

function App._routeBoot(candidate)
  if candidate ~= nil and candidate.ready then
    App._selectVersion(candidate.versionId, { entryLocation = candidate.entryLocation })
  else
    App._showGameSelection(candidate and candidate.versionId or nil, nil, App._libraryMetadata or {})
  end
end

function App.load(opts)
  App.opts = opts or {}
  App._cleanupAbandonedImports()
  App.drawableWidth, App.drawableHeight = love.graphics.getDimensions()
  App.pixelRatio = love.graphics.getDPIScale()
  App.importer = nil
  App.provisioner = nil
  App.splRandomState = nil
  App.service = nil
  App.epoch = 0
  App.pendingQuiesce = nil
  App.pairIndex = nil
  App._importReceipt = nil
  App._pendingImport = nil
  App._pendingPicker = nil
  App.selectedVersionId = nil
  App._swallowedPointers = {}
  App._bootSwallowedInputs = {}
  App._startupWarmup = nil
  App._saveLocationWarmup = nil
  App._selectedEntryLocation = nil
  App._libraryMetadata = nil
  App.startupWarmupError = nil
  App.startupAudioSession = nil
  App.startupAudioError = nil
  App._assetRuntime = nil
  App._cacheLoading = false
  App.setState(nil)
  love.graphics.setBackgroundColor(unpack(WindowConfig.BACKGROUND_COLOR))
  App.saveDir = love.filesystem.getSaveDirectory()

  -- The process-wide master gain applies before any route can play audio
  -- and is retained across save and version switches. A deliberately
  -- headless host without an audio module keeps persistence with a silent
  -- gain adapter.
  local setGain = function(_) end
  if love ~= nil and love.audio ~= nil and type(love.audio.setVolume) == "function" then
    local host = love.audio
    setGain = function(gain)
      host.setVolume(gain)
    end
  end
  App.audioPreferences = AudioPreferences.new({ storage = SaveFs.global(), setGain = setGain })
  App._ensureLauncherResources()
  App._bootPending = true
  App.setState(BootIntroState.new({
    renderer = App.launcherRenderer,
    audio = App.launcherAudio,
    safeRect = App._safeRect,
    onRoute = function(automatic, candidate)
      if automatic and App._bootPending then
        candidate = App._prepareBootCandidate()
      end
      local swallowed = {}
      if not automatic and App.state ~= nil and type(App.state.consumedInputs) == "function" then
        swallowed = App.state:consumedInputs()
      end
      App._bootPending = false
      App._bootSwallowedInputs = swallowed
      App._routeBoot(candidate)
    end,
  }))
end

-- Replaces only the UI state. Source ownership is explicit: selection,
-- re-import, selector return and quit retire the session; the
-- bootstrap-state to game handoff must not retire it.
function App.setState(nextState)
  local previous = App.state
  if App._pendingPicker ~= nil and previous ~= nextState then
    App._pendingPicker = nil
  end
  App.state = nextState
  if previous and previous.dispose then
    previous:dispose()
  end
end

function App._consumeBootInput(identity)
  if App._bootSwallowedInputs == nil or not App._bootSwallowedInputs[identity] then
    return false
  end
  App._bootSwallowedInputs[identity] = nil
  return true
end

function App._startImport()
  ---@type RomImporter
  local importer
  importer = RomImporter.new({
    onComplete = function(versionId)
      App._onImported(versionId, importer)
    end,
  })
  App.importer = importer
  App.setState(App._newGameSelectState(nil, nil))
end

function App._requestGameImport()
  if App._pendingPicker ~= nil or importInProgress(App.importer) then
    return
  end
  local result = NativeRomPicker.openSingle()
  if result.kind == "path" then
    App._beginImportPath(result.path)
  elseif result.kind == "pending" then
    App._pendingPicker = { requestId = result.requestId }
    if App.state ~= nil and type(App.state.setPickerPending) == "function" then
      App.state:setPickerPending(true)
    end
  elseif result.kind == "error" then
    local current = App.state
    local focus = current and current.view and current:view().focusedId or nil
    App._showGameSelection(focus, Errors.new("ROM_PICKER_FAILED", tostring(result.message or "file picker failed"), {}))
  end
end

function App._pollNativePicker()
  local pendingPicker = App._pendingPicker
  local result = NativeRomPicker.poll(pendingPicker and pendingPicker.requestId or nil)
  if result == nil then
    return
  end
  local matches = pendingPicker ~= nil and result.requestId == pendingPicker.requestId
  if matches then
    App._pendingPicker = nil
    if App.state ~= nil and type(App.state.setPickerPending) == "function" then
      App.state:setPickerPending(false)
    end
  end
  if not matches then
    if result.kind == "path" then
      love.filesystem.remove(result.relativePath)
    end
    return
  end
  if result.kind == "path" then
    App._beginImportTemporary(result.relativePath, result.displayName, result.requestId)
  elseif result.kind == "error" then
    local current = App.state
    local focus = current and current.view and current:view().focusedId or nil
    App._showGameSelection(focus, Errors.new("ROM_PICKER_FAILED", tostring(result.message), {}))
  end
end

function App._beginImportTemporary(relativePath, displayName, requestId)
  App._beginImportAttempt("temporary", relativePath, displayName, requestId)
end

function App._beginImportPath(path)
  if type(path) ~= "string" or (not path:lower():match("%.nds$") and not path:lower():match("%.zip$")) then
    local current = App.state
    local focus = current and current.view and current:view().focusedId or nil
    App._showGameSelection(focus, Errors.new("ROM_FILE_UNSUPPORTED", "Choose a supported .nds or .zip file.", {}))
    return
  end
  App._beginImportAttempt("path", path)
end

-- Open the import card for one picked or dropped file without touching the
-- source: the receipt is latched for its first paint, and validation starts
-- only after that paint (see App.update). Importers offering the queued
-- handoff start in the background then; direct-only importers keep their
-- immediate start contract on this same tick.
---@param kind "drop"|"path"|"temporary"
---@param value unknown dropped File, picked path, or completed private stage
---@param receipt string? sanitized basename latched for the first paint
---@param requestId string? native temporary-source correlation
function App._openImportCard(kind, value, receipt, requestId)
  local previous = App.importer
  App.importer = nil
  if previous ~= nil and type(previous.cancelQueued) == "function" then
    previous:cancelQueued()
  end
  App._startImport()
  -- Acknowledge the file on the same input tick: the first draw already
  -- names the received file, while no source read has run yet.
  App._importReceipt = receipt
  local importer = App.importer
  if importer ~= nil and type(importer.queuePath) == "function" and type(importer.queueDroppedFile) == "function" then
    App._pendingImport = {
      kind = kind,
      value = value,
      receipt = receipt,
      requestId = requestId,
      painted = receipt == nil,
      started = false,
    }
  else
    App._pendingImport = nil
    if importer then
      if kind == "path" then
        importer:startPath(value)
      else
        importer:filedropped(value)
      end
    end
  end
  local fresh = App.state
  if receipt ~= nil and fresh ~= nil and type(fresh.markReceived) == "function" then
    fresh:markReceived(receipt)
  end
end

function App._beginImportAttempt(kind, value, receiptName, requestId)
  local currentState = App.state
  if kind == "drop" and currentState ~= nil and type(currentState.onImportAttempt) == "function" then
    currentState:onImportAttempt()
    return
  end
  if importInProgress(App.importer) then
    return
  end
  local waiting = App.state
  if waiting ~= nil and getmetatable(waiting) == CachePreparationState and waiting.kind == "quiescence" then
    return
  end
  local receipt = receiptName or App._receiptName(kind, value)
  if App.service ~= nil then
    App._retireSelection()
    local epoch = App.epoch or 0
    local barrier = App.service:quiesce(epoch)
    if barrier ~= nil then
      -- The barrier wait carries the same receipt: its card names the file
      -- while readers drain, and the import card created on admission
      -- paints it again before any worker starts.
      App._importReceipt = receipt
      App._pendingImport = {
        kind = kind,
        value = value,
        receipt = receipt,
        requestId = requestId,
        painted = receipt == nil,
        started = false,
      }
      App.pendingQuiesce = { epoch = epoch, barrier = barrier }
      App.setState(CachePreparationState.new({
        kind = "quiescence",
        epoch = epoch,
        service = App.service,
        barrier = barrier,
        pendingImportName = receipt,
        renderer = App.launcherRenderer,
        safeRect = App._safeRect,
        isCurrent = function(_)
          return App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier == barrier
        end,
        onReady = function()
          App.pendingQuiesce = nil
          if App.service:importSource(epoch, barrier) then
            App._openImportCard(kind, value, receipt, requestId)
          end
        end,
        onCancel = function()
          App.pendingQuiesce = nil
          App._showGameSelection()
        end,
      }))
      return
    end
  end
  App._openImportCard(kind, value, receipt, requestId)
end

-- Record one actually painted receipt for the deferred import start. Only a
-- draw that rendered the pending receipt for the current attempt counts;
-- latching the name is not painting.
function App._noteReceiptPaint()
  local pending = App._pendingImport
  if pending == nil or pending.painted or pending.started or pending.receipt == nil then
    return
  end
  local state = App.state
  if state == nil or type(state.paintedReceipt) ~= "function" then
    return
  end
  local ok, name = pcall(state.paintedReceipt, state)
  if ok and name == pending.receipt then
    pending.painted = true
  end
end

-- Start the deferred import once its receipt was painted and no source-reader
-- barrier holds the selection. The queued handoff validates in the
-- background; the render thread performs no source read here.
function App._startPendingImport()
  local pending = App._pendingImport
  if pending == nil or pending.started or not pending.painted or App.pendingQuiesce ~= nil then
    return
  end
  local importer = App.importer
  if importer == nil then
    App._pendingImport = nil
    if pending.kind == "temporary" and not pending.started then
      love.filesystem.remove(pending.value)
    end
    return
  end
  local ok, accepted, failure = pcall(function()
    if pending.kind == "temporary" then
      return importer:queueTemporaryPath(pending.value, pending.requestId)
    elseif pending.kind == "path" then
      importer:queuePath(pending.value)
    else
      importer:queueDroppedFile(pending.value)
    end
  end)
  if ok and (pending.kind ~= "temporary" or accepted == true) then
    pending.started = true
    if importer.state == RomImporter.STATES.ERROR then
      App._pendingImport = nil
    end
  else
    App._pendingImport = nil
    if pending.kind == "temporary" then
      love.filesystem.remove(pending.value)
    end
    if not ok then
      if not Errors.is(accepted) then
        error(accepted, 0)
      end
      failure = accepted
    elseif pending.kind == "temporary" and not Errors.is(failure) then
      failure = Errors.new("ROM_IMPORT_REQUEST_INVALID", "temporary import was not accepted", {})
    end
    if not Errors.is(failure) then
      error(failure, 0)
    end
    local current = App.state
    local focus = current and current.view and current:view().focusedId or nil
    App._showGameSelection(focus, failure)
  end
end

-- Sanitized basename for the synchronous file-received receipt: the card
-- names the file without leaking paths and truncates to one card row.
---@param kind string "drop" or "path"
---@param value unknown dropped File or picked path
---@return string? receipt basename, if one can be named
function App._receiptName(kind, value)
  local raw = nil
  if kind == "path" and type(value) == "string" then
    raw = value:match("([^/\\]+)$") or value
  elseif kind == "drop" and value ~= nil and type(value.getFilename) == "function" then
    local ok, name = pcall(value.getFilename, value)
    if ok and type(name) == "string" then
      raw = name:match("([^/\\]+)$") or name
    end
  end
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local clean = raw:gsub("[%c]", "?")
  if #clean > 48 then
    clean = clean:sub(1, 47) .. "…"
  end
  if clean == "" then
    return nil
  end
  return clean
end

---@param versionId string
---@param originatingImporter RomImporter
function App._onImported(versionId, originatingImporter)
  local importer = App.importer
  if importer == nil or importer ~= originatingImporter then
    return
  end
  local snapshot = assert(importer:status(), "the current importer must expose its status")
  if type(snapshot) ~= "table" or snapshot.state ~= RomImporter.STATES.COMPLETE then
    return
  end
  assert(type(importer.takeVerifiedSource) == "function", "a complete import owns its verified source handoff")
  local verifiedSource = assert(importer:takeVerifiedSource(), "a complete import has one verified source handoff")
  assert(type(verifiedSource.release) == "function", "the verified source wrapper owns its release")
  verifiedSource:release()
  App.importer = nil
  App._pendingImport = nil
  App._importReceipt = nil
  App._showGameSelection(versionId)
end

function App._bootMainMenu(versions)
  assert(type(versions) == "table" and #versions == 1, "Main Menu needs exactly one selected version")
  App._selectVersion(versions[1])
end

function App._bootExisting()
  App._bootPending = true
  local candidate = App._prepareBootCandidate()
  App._routeBoot(candidate)
end

-- One authoritative execution-policy fact for the selected epoch. A state
-- owns whether it is genuinely blocking on asset preparation: the boot wait,
-- import preparation, a product loader or a game entry loader. Ordinary
-- gameplay frames never raise cache throughput merely because input is locked
-- or a cinematic is covering the scene.
---@return boolean
local function stateIsPreparingAssets()
  local state = App.state
  if state == nil then
    return false
  end
  local query = state.isPreparingAssets
  if type(query) ~= "function" then
    return false
  end
  local ok, loading = pcall(query, state)
  return ok and loading == true
end

-- Transport the current presentation policy to the cache controller and size
-- the selected runtime's preparation executor to match. The executor budget is
-- reconciled against its actual value every frame, so a runtime created after
-- the policy changed still receives it; the service report is deduplicated by
-- the last reported policy. A stale epoch, a retired selection or a failed
-- controller simply ignores the report.
function App._syncCacheExecutionPolicy()
  local loading = stateIsPreparingAssets()
  local runtime = App._assetRuntime
  if runtime ~= nil then
    local slots = preparationWorkerSlots(loading)
    if runtime.preparationQueue:workerSlotBudget() ~= slots then
      runtime.preparationQueue:setWorkerSlots(slots)
    end
  end
  if loading == App._cacheLoading then
    return
  end
  App._cacheLoading = loading
  local service, epoch = App.service, App.epoch
  if service == nil or type(epoch) ~= "number" then
    return
  end
  service:setExecutionPolicy(epoch, loading)
end

function App.update(dt)
  App._syncDrawableSize()
  App._pollNativePicker()
  if
    App.importer
    and App.importer.state ~= RomImporter.STATES.COMPLETE
    and App.importer.state ~= RomImporter.STATES.ERROR
  then
    App.importer:update()
  end
  if App.importer and not App.importer:isBusy() and App.importer.state == RomImporter.STATES.ERROR then
    App._pendingImport = nil
  end
  if App.service then
    App.service:update()
  end
  App._updateStartupWarmup()
  App._updateSaveLocationWarmup()
  if App.launcherAudio ~= nil then
    App.launcherAudio:update(dt)
  end
  if App.state and App.state.update then
    App.state:update(dt)
  end
  App._syncCacheExecutionPolicy()
  App._startPendingImport()
  local audio = App.startupAudioSession
  if audio ~= nil then
    local ok, failure = pcall(audio.update, audio, dt)
    if not ok then
      App._recordStartupAudioError(failure)
      local state = App.state
      if
        state ~= nil
        and getmetatable(state) == StartupTitleState
        and state.phase == "movie"
        and state.epoch == App.epoch
        and App.selectedVersionId == state.versionId
      then
        pcall(state.openingAudioFailed, state, tostring(failure))
      end
      App._releaseStartupAudio()
    elseif audio.diagnostic ~= nil then
      App._recordStartupAudioError(audio.diagnostic)
      local state = App.state
      if
        state ~= nil
        and getmetatable(state) == StartupTitleState
        and state.phase == "movie"
        and state.epoch == App.epoch
        and App.selectedVersionId == state.versionId
      then
        pcall(state.openingAudioFailed, state, tostring(audio.diagnostic))
        App._releaseStartupAudio()
      end
    end
  end
end

local function sameRectangle(a, b)
  return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

local function readSafeRect()
  local x, y, width, height = love.window.getSafeArea()
  return { x = x, y = y, width = width, height = height }
end

function App._publishDrawableSize(width, height, pixelRatio, safeRect)
  local changed = width ~= App.drawableWidth
    or height ~= App.drawableHeight
    or pixelRatio ~= App.pixelRatio
    or not sameRectangle(safeRect, App._safeRect)
  if not changed then
    return
  end
  App.drawableWidth = width
  App.drawableHeight = height
  App.pixelRatio = pixelRatio
  App._safeRect = safeRect
  App._swallowedPointers = {}
  App._bootSwallowedInputs = {}
  if App.state and App.state.resize then
    App.state:resize(width, height, safeRect)
  end
end

function App.resize(width, height)
  App._swallowedPointers = {}
  App._bootSwallowedInputs = {}
  App._publishDrawableSize(width, height, love.graphics.getDPIScale(), readSafeRect())
end

function App._syncDrawableSize()
  local width, height = love.graphics.getDimensions()
  App._publishDrawableSize(width, height, love.graphics.getDPIScale(), readSafeRect())
end

function App.draw()
  -- LÖVE keeps the color across frames, so every frame starts from white
  -- instead of whatever the previous state last drew with.
  love.graphics.setColor(1, 1, 1, 1)
  if App.state and App.state.draw then
    App.state:draw()
  elseif App.opts.dev then
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("portemon", 24, 24)
  end
  if App._bootPending then
    App._prepareBootCandidate()
  end
  App._noteReceiptPaint()
end

function App.filedropped(file)
  local currentState = App.state
  if currentState ~= nil and getmetatable(currentState) == SaveEditorState then
    local filename = file:getFilename()
    if filename:lower():match("%.lua$") then
      currentState:importPresetFile(file)
      return
    end
  end
  App._beginImportAttempt("drop", file)
end

function App.keypressed(key, scancode, isrepeat)
  if key == "f11" then
    if not isrepeat then
      love.window.setFullscreen(not love.window.getFullscreen())
    end
    return
  end
  if App._consumeBootInput("key:" .. key) then
    return
  end
  if App.state and App.state.keypressed then
    App.state:keypressed(key, scancode, isrepeat)
    return
  end
  if key == "escape" then
    love.event.quit(0)
  end
end

function App.keyreleased(key, scancode)
  if App._consumeBootInput("key:" .. key) then
    return
  end
  if App.state and App.state.keyreleased then
    App.state:keyreleased(key, scancode)
  end
end

function App.gamepadpressed(joystick, button)
  if App._consumeBootInput("gamepad:" .. tostring(joystick) .. ":" .. button) then
    return
  end
  if App.state and App.state.gamepadpressed then
    App.state:gamepadpressed(joystick, button)
  end
end

function App.gamepadreleased(joystick, button)
  if App._consumeBootInput("gamepad:" .. tostring(joystick) .. ":" .. button) then
    return
  end
  if App.state and App.state.gamepadreleased then
    App.state:gamepadreleased(joystick, button)
  end
end

function App.gamepadaxis(joystick, axis, value)
  if App.state and App.state.gamepadaxis then
    App.state:gamepadaxis(joystick, axis, value)
  end
end

function App.mousepressed(x, y, button, istouch, presses)
  App._syncDrawableSize()
  if not istouch and App._consumeBootInput("mouse:" .. tostring(button)) then
    return
  end
  local state = App.state
  if state and state.mousepressed then
    state:mousepressed(x, y, button, istouch, presses)
    if getmetatable(state) == StartupTitleState and state.canceledPointers["mouse:" .. tostring(button)] then
      App._swallowedPointers = App._swallowedPointers or {}
      App._swallowedPointers["mouse:" .. tostring(button)] = true
    end
  end
end

function App.mousemoved(x, y, dx, dy, istouch)
  App._syncDrawableSize()
  if not istouch and App._bootSwallowedInputs ~= nil and App._bootSwallowedInputs["mouse:1"] then
    return
  end
  if App.state and App.state.mousemoved then
    App.state:mousemoved(x, y, dx, dy, istouch)
  end
end

function App.mousereleased(x, y, button, istouch, presses)
  App._syncDrawableSize()
  local pointerId = "mouse:" .. tostring(button)
  if not istouch and App._consumeBootInput(pointerId) then
    return
  end
  if App._swallowedPointers ~= nil and App._swallowedPointers[pointerId] then
    local state = App.state
    if state ~= nil and getmetatable(state) == StartupTitleState then
      state:mousereleased(x, y, button, istouch, presses)
    end
    App._swallowedPointers[pointerId] = nil
    return
  end
  if App.state and App.state.mousereleased then
    App.state:mousereleased(x, y, button, istouch, presses)
  end
end

function App.wheelmoved(x, y)
  if App.state and App.state.wheelmoved then
    App.state:wheelmoved(x, y)
  end
end

function App.touchpressed(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  if App._consumeBootInput("touch:" .. tostring(id)) then
    return
  end
  local state = App.state
  if state and state.touchpressed then
    state:touchpressed(id, x, y, dx, dy, pressure)
    if getmetatable(state) == StartupTitleState and state.canceledPointers["touch:" .. tostring(id)] then
      App._swallowedPointers = App._swallowedPointers or {}
      App._swallowedPointers["touch:" .. tostring(id)] = true
    end
  end
end

function App.touchmoved(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  if App._bootSwallowedInputs ~= nil and App._bootSwallowedInputs["touch:" .. tostring(id)] then
    return
  end
  if App.state and App.state.touchmoved then
    App.state:touchmoved(id, x, y, dx, dy, pressure)
  end
end

function App.touchreleased(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  local pointerId = "touch:" .. tostring(id)
  if App._consumeBootInput(pointerId) then
    return
  end
  if App._swallowedPointers ~= nil and App._swallowedPointers[pointerId] then
    local state = App.state
    if state ~= nil and getmetatable(state) == StartupTitleState then
      state:touchreleased(id, x, y, dx, dy, pressure)
    end
    App._swallowedPointers[pointerId] = nil
    return
  end
  if App.state and App.state.touchreleased then
    App.state:touchreleased(id, x, y, dx, dy, pressure)
  end
end

function App.textinput(text)
  if App.state and App.state.textinput then
    App.state:textinput(text)
  end
end

function App.focus(focused)
  if not focused then
    App._swallowedPointers = {}
    App._bootSwallowedInputs = {}
  end
  if App.state and App.state.focus then
    App.state:focus(focused)
  end
end

function App.quit()
  local currentState = App.state
  if currentState ~= nil and type(currentState.requestClose) == "function" then
    if currentState:requestClose("quit") then
      return true
    end
  end
  App.setState(nil)
  App._retireSelection()
  -- Process shutdown alone joins the controller thread; selection
  -- switching only retires epochs while actual old work stays counted
  -- below the controller.
  local service = App.service
  App.service = nil
  App.pendingQuiesce = nil
  App.selectedVersionId = nil
  if service then
    service:shutdown()
  end
  App._releaseLauncherResources()
end

return App
