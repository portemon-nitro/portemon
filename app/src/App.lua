-- Launcher/process shell for the interactive app root.

local WindowConfig = require("game.src.WindowConfig")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomArchive = require("romdump.src.source.RomArchive")
local RomIconRecovery = require("romdump.src.source.RomIconRecovery")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
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
local TouchGamepad = require("app.src.input.TouchGamepad")
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

-- App owns the outer host clear only while the boot overlay covers it.
local BOOT_BACKGROUND_COLOR = { 1, 1, 1, 1 }

---@class App
---@field opts AppOptions
---@field state table<string, unknown>|nil
---@field importer RomImporter|nil
---@field provisioner DerivedAssetProvisioner|nil
---@field service CacheService|nil process-owned cache controller service shared by every selection
---@field epoch integer latest borrowed controller epoch, monotonically increasing
---@field pendingQuiesce table<string, integer>|nil unacknowledged source-close barrier for import
---@field pairIndex integer? selected-epoch walking pair, chosen once per selection
---@field _importAttempt table<string, unknown>? one finite native/source import owner
---@field _iconRecovery table<string, unknown>? one optional read-only banner recovery job
---@field _iconRepairAttempted table<string, boolean>
---@field _pendingIconData { romSha1: string, png: love.FileData }?
---@field _bootIntro BootIntroState? foreground-only presentation over the selected epoch
---@field _bootCandidate AppBootCandidate?
---@field selectedVersionId string? currently selected game version
---@field _libraryMetadata AppSaveMetadata[]? detached published-save metadata for the current library decision
---@field _selectedEntryLocation { mapId: integer, fieldX: integer, fieldZ: integer }? transient copied save hint
---@field _saveLocationWarmup { epoch: integer, versionId: string, preparation: table<string, function> }?|nil
---@field _startupWarmup { epoch: integer, versionId: string, preparation: table<string, function> }?|nil
---@field startupWarmupError string? background preparation diagnostic, never a menu gate
---@field launcherRenderer LauncherRenderer?|nil process-owned launcher painter
---@field _touchGamepad TouchGamepad?|nil Android-only borrowed virtual input source
---@field _safeRect { x: number, y: number, width: number, height: number }? latest published native safe rectangle
---@field _touchGamepadSuspended boolean host is temporarily nonpresentable
---@field _suspendedTouchIds table<unknown, boolean> touch lifetimes first seen while nonpresentable
---@field launcherAudio LauncherAudio?|nil process-owned launcher cue owner
---@field _bootPending boolean? metadata decision deferred until the first boot paint
---@field _displayContext DisplayContext? borrows App's published native facts
---@field _foreground boolean
---@field _realTouches table<unknown, boolean>
---@field startupAudioSession StartupAudioSession?|nil optional selected-version title/menu audio owner
---@field startupAudioError string?|nil non-gating audio diagnostic
---@field _assetRuntime AppAssetRuntime?|nil one selected-epoch CPU runtime shared by every composition
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

-- Managed source presence is the product installation fact. It never opens or
-- hashes an archive and never consults caches or legacy external bindings.
local function managedInstalled(versionId)
  local info = GameVersion.info(versionId)
  return type(info) == "table" and type(info.sha1) == "string" and RomArchive.recoverablePath(info.sha1) ~= nil
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

local EDITION_DISPLAY_NAMES = {
  heartgold = "Pokémon HeartGold",
  soulsilver = "Pokémon SoulSilver",
}

local function gameLabel(versionId)
  local displayName = EDITION_DISPLAY_NAMES[versionId]
  if displayName ~= nil then
    return displayName
  end
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

function App._finishBootIntro(stopImmediately)
  local intro = App._bootIntro
  if intro == nil then
    return
  end
  App._bootIntro = nil
  love.graphics.setBackgroundColor(unpack(WindowConfig.BACKGROUND_COLOR))
  if App.launcherAudio ~= nil then
    App.launcherAudio:fadeBoot(stopImmediately == true and 0 or 0.08)
  end
  intro:dispose()
end

function App._releaseIconRecovery()
  local job = App._iconRecovery
  App._iconRecovery = nil
  if job ~= nil then
    job:dispose()
  end
  local pending = App._pendingIconData
  App._pendingIconData = nil
  if pending ~= nil then
    pending.png:release()
  end
end

-- Cancellation is an App effect, never a leaf status guess. A committed
-- worker remains owned until its terminal result; an outstanding source
-- barrier likewise survives the canceled view.
function App._cancelImport()
  local attempt = App._importAttempt
  if attempt == nil then
    return
  end
  local importer = App.importer
  local status = importer ~= nil and importer.status and importer:status() or nil
  local cancellable = attempt.mode == "choose"
    or attempt.mode == "picker"
    or attempt.mode == "receipt"
    or attempt.mode == "draining"
    or attempt.mode == "error"
    or (status ~= nil and status.canCancel == true)
  if not cancellable then
    return
  end
  if attempt.descriptor ~= nil and attempt.descriptor.kind == "temporary" and not attempt.started then
    love.filesystem.remove(attempt.descriptor.value)
  end
  if importer ~= nil and status ~= nil and status.canCancel == true then
    importer:cancelQueued()
  end
  App.importer = nil
  App._importAttempt = nil
  App._showGameSelection(attempt.expectedVersionId)
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
  if App._touchGamepad ~= nil then
    App._touchGamepad:setTarget(nil)
  end
  local touchGamepad = App._touchGamepad
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
    topologyProvider = touchGamepad ~= nil and function()
      return assert(touchGamepad:topology(), "Android game entry requires published controller topology")
    end or nil,
  })
  if not ok then
    App._showGameSelection(versionId)
    error(gameOrError, 0)
  end
  App.setState(assert(gameOrError))
  if App._touchGamepad ~= nil then
    App._touchGamepad:setTarget(assert(gameOrError))
  end
end

function App._ensureLauncherResources()
  if App.launcherRenderer == nil then
    App.launcherRenderer = LauncherRenderer.new()
  end
  if App.launcherAudio == nil then
    App.launcherAudio = LauncherAudio.new()
  end
  if App._touchGamepad == nil and love.system.getOS() == "Android" then
    local renderer = assert(App.launcherRenderer, "Android controls require the launcher renderer")
    ---@cast renderer TouchGamepadRenderer
    App._touchGamepad = TouchGamepad.new(renderer)
    App._suspendedTouchIds = {}
    App._syncDrawableSize()
  elseif App._touchGamepad ~= nil and love.system.getOS() ~= "Android" then
    App._touchGamepad:setTarget(nil)
    App._touchGamepad = nil
    App._suspendedTouchIds = {}
  end
end

function App._releaseLauncherResources()
  if App._touchGamepad ~= nil then
    App._touchGamepad:setTarget(nil)
    App._touchGamepad = nil
    App._safeRect = nil
    App._touchGamepadSuspended = false
    App._suspendedTouchIds = {}
  end
  if App.launcherAudio ~= nil then
    App.launcherAudio:dispose()
    App.launcherAudio = nil
  end
  if App.launcherRenderer ~= nil then
    App.launcherRenderer:dispose()
    App.launcherRenderer = nil
  end
  App._safeRect = nil
  App._displayContext = nil
end

---@return table<string, boolean>
local function managedInstalledFacts()
  local installed = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    installed[versionId] = managedInstalled(versionId)
  end
  return installed
end

---@param installedFacts table<string, boolean>
---@return table<integer, table<string, string|boolean>>
local function gameSnapshot(installedFacts)
  local games = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    local info = GameVersion.info(versionId)
    local installed = installedFacts[versionId] == true
    local sha1 = type(info) == "table" and info.sha1 or nil
    games[#games + 1] = {
      versionId = versionId,
      label = gameLabel(versionId),
      installed = installed,
      iconSha1 = installed and sha1 or nil,
    }
  end
  return games
end

function App._launcherDisplayContext()
  return DisplayContext.new({
    graphics = {
      getDimensions = function()
        return App.drawableWidth, App.drawableHeight
      end,
      getDPIScale = function()
        return App.pixelRatio
      end,
    },
    topologyProvider = function(width, height)
      local safe = App._safeRect or { x = 0, y = 0, width = width, height = height }
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = width, height = height },
            safeRect = { x = safe.x, y = safe.y, width = safe.width, height = safe.height },
            touch = love.system.getOS() == "Android" or love.system.getOS() == "iOS",
          },
        },
      }
    end,
  })
end

function App._importSnapshot(attempt)
  if attempt == nil then
    return nil
  end
  local status = App.importer ~= nil and App.importer.status and App.importer:status() or nil
  local mode = attempt.mode
  local statusText
  if mode == "picker" then
    statusText = "Waiting for file picker"
  elseif mode == "draining" then
    statusText = "Waiting for source readers to drain…"
  elseif mode == "receipt" then
    statusText = "File received; preparing import"
  elseif mode == "importing" and status ~= nil then
    statusText = status.stageLabel or (status.state == RomImporter.STATES.READING and "Checking ROM" or "Verifying ROM")
  elseif mode == "error" then
    statusText = nil
  end
  local progress = nil
  if mode == "importing" and status ~= nil and status.state ~= RomImporter.STATES.IDLE then
    local value = status.progress
    if type(value) == "number" and value == value and value > 0 and value < 1 then
      progress = value
    end
  end
  return {
    attemptId = attempt.attemptId,
    mode = mode,
    expectedVersionId = attempt.expectedVersionId,
    receipt = attempt.receipt,
    statusText = statusText,
    progress = progress,
    canCancel = attempt.canCancel == true,
    pickerAvailable = attempt.pickerAvailable == true,
    error = attempt.error,
    elapsed = attempt.elapsed or 0,
  }
end

---@param installedFacts table<string, boolean>
local function refreshRootIcons(installedFacts)
  local renderer = App.launcherRenderer
  if renderer == nil then
    return
  end
  for _, versionId in ipairs(GameVersion.ORDER) do
    local info = GameVersion.info(versionId)
    if installedFacts[versionId] == true then
      local sha1 = assert(info.sha1)
      local path = RomArchive.iconPath(sha1)
      if love.filesystem.getInfo(path, "file") ~= nil then
        if not renderer:refreshGameIcon(sha1, path) then
          renderer:dropGameIcon(sha1)
          if App._importAttempt == nil and App.importer == nil then
            App._scheduleIconRecovery(versionId, sha1)
          end
        end
      elseif App._importAttempt == nil and App.importer == nil then
        App._scheduleIconRecovery(versionId, sha1)
      end
    elseif info ~= nil and type(info.sha1) == "string" then
      renderer:dropGameIcon(info.sha1)
    end
  end
end

function App._refreshRootIcons()
  refreshRootIcons(managedInstalledFacts())
end

function App._scheduleIconRecovery(versionId, sha1)
  if App._iconRepairAttempted[sha1] or App._iconRecovery ~= nil or App._pendingIconData ~= nil then
    return
  end
  App._iconRepairAttempted[sha1] = true
  local ok, job = pcall(RomIconRecovery.start, versionId)
  if ok then
    App._iconRecovery = job
  else
    print("Optional cartridge icon recovery unavailable: " .. tostring(job))
  end
end

function App._publishRecoveredIcon(romSha1, png)
  local info = GameVersion.forSha1(romSha1)
  if info == nil or RomArchive.recoverablePath(romSha1) == nil then
    png:release()
    return
  end
  local published, failure = RomArchive.publishIcon(romSha1, png)
  png:release()
  if published then
    if App.launcherRenderer ~= nil then
      App.launcherRenderer:refreshGameIcon(romSha1, RomArchive.iconPath(romSha1))
    end
  else
    print("Optional cartridge icon publication failed: " .. tostring(failure and failure.message or failure))
  end
end

function App._pollIconRecovery()
  local job = App._iconRecovery
  if job == nil then
    local pending = App._pendingIconData
    if pending == nil or App._importAttempt ~= nil or App.importer ~= nil then
      return
    end
    App._pendingIconData = nil
    App._publishRecoveredIcon(pending.romSha1, pending.png)
    return
  end
  local state, value, png = job:poll()
  if state == "pending" then
    return
  end
  App._iconRecovery = nil
  job:dispose()
  if state == "failed" then
    print("Optional cartridge icon recovery failed: " .. tostring(value))
    return
  end
  if state ~= "ready" or type(value) ~= "string" or png == nil then
    if png ~= nil then
      png:release()
    end
    return
  end
  if App._importAttempt ~= nil or App.importer ~= nil then
    App._pendingIconData = { romSha1 = value, png = png }
    return
  end
  App._publishRecoveredIcon(value, png)
end

function App._newGameSelectState(focusGameId)
  App._ensureLauncherResources()
  local installedFacts = managedInstalledFacts()
  refreshRootIcons(installedFacts)
  return GameSelectState.new({
    games = gameSnapshot(installedFacts),
    initialGameId = focusGameId,
    renderer = App.launcherRenderer,
    audio = App.launcherAudio,
    width = App.drawableWidth,
    height = App.drawableHeight,
    safeRect = App._safeRect,
    pixelRatio = App.pixelRatio,
    displayContext = App._launcherDisplayContext(),
    getImportView = function()
      return App._importSnapshot(App._importAttempt)
    end,
    onAction = function(targetId)
      if targetId == "quit" then
        love.event.quit(0)
      elseif targetId == "heartgold" or targetId == "soulsilver" then
        if managedInstalled(targetId) then
          local candidate = newestSave(App._libraryMetadata, targetId)
          App._selectVersion(targetId, { entryLocation = candidate and candidate.entryLocation or nil })
        else
          App._openImportChoose(targetId)
        end
      elseif targetId == "choose-rom" then
        App._requestNativePicker()
      elseif targetId == "retry" then
        local attempt = App._importAttempt
        if attempt ~= nil then
          local expectedVersionId = attempt.expectedVersionId
          -- A terminal importer belongs to the retired attempt; keeping it
          -- would re-fail the fresh choose attempt on the next update.
          if
            App.importer ~= nil
            and (App.importer.state == RomImporter.STATES.ERROR or App.importer.state == RomImporter.STATES.COMPLETE)
          then
            App.importer = nil
          end
          App._importAttempt = App._newImportAttempt(expectedVersionId)
          App.setState(App._newGameSelectState(expectedVersionId))
        end
      elseif targetId == "back" or targetId == "cancel" then
        App._cancelImport()
      end
    end,
  })
end

function App._showGameSelection(focusGameId, failure)
  if failure ~= nil and App._importAttempt == nil then
    App._importAttempt = {
      attemptId = {},
      expectedVersionId = focusGameId,
      mode = "error",
      error = failure,
      canCancel = false,
      pickerAvailable = NativeRomPicker.available() == true,
    }
  end
  if failure ~= nil then
    App._finishBootIntro(false)
  end
  App._retireSelection()
  App.selectedVersionId = nil
  App.setState(App._newGameSelectState(focusGameId))
end

function App._showQuiescence(attempt, versionId, options)
  local pending = assert(App.pendingQuiesce)
  local service = assert(App.service)
  App.setState(CachePreparationState.new({
    kind = "quiescence",
    epoch = pending.epoch,
    barrier = pending.barrier,
    service = service,
    renderer = App.launcherRenderer,
    width = App.drawableWidth,
    height = App.drawableHeight,
    safeRect = App._safeRect,
    pixelRatio = App.pixelRatio,
    displayContext = App._launcherDisplayContext(),
    pendingImportName = attempt and attempt.receipt or nil,
    pendingImportLabel = attempt and attempt.expectedVersionId and gameLabel(attempt.expectedVersionId) or nil,
    importAttemptId = attempt and attempt.attemptId or nil,
    importViewProvider = attempt ~= nil and function()
      return App._importSnapshot(attempt)
    end or nil,
    isCurrent = function(_)
      return App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier == pending.barrier
    end,
    onReady = function()
      if App.pendingQuiesce == nil or App.pendingQuiesce.barrier ~= pending.barrier then
        return
      end
      App.pendingQuiesce = nil
      if attempt ~= nil then
        App._authorizeImport(attempt, pending.epoch, pending.barrier)
      else
        App._selectVersion(versionId, options)
      end
    end,
    onCancel = function()
      if attempt ~= nil then
        App._cancelImport()
      else
        App._showGameSelection()
      end
    end,
  }))
end

function App._waitForQuiescence(versionId, options)
  local pending = App.pendingQuiesce
  local service = App.service
  if pending == nil or service == nil then
    return false
  end
  local ok, status = pcall(service.barrierStatus, service, pending.epoch, pending.barrier)
  if not ok then
    App.pendingQuiesce = nil
    App._showGameSelection(nil, Errors.new("ROM_SOURCE_BARRIER_FAILED", tostring(status), {}))
    return true
  end
  if status == "ready" then
    App.pendingQuiesce = nil
    return false
  end
  if status == "failed" or status == nil then
    App.pendingQuiesce = nil
    App._showGameSelection(nil, Errors.new("ROM_SOURCE_BARRIER_FAILED", "source readers could not close", {}))
    return true
  end
  App._showQuiescence(nil, versionId, options)
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
  assert(supported(versionId), "unknown selected edition")
  if App._importAttempt ~= nil then
    return
  end
  if not managedInstalled(versionId) then
    App._openImportChoose(
      versionId,
      Errors.new(
        "ROM_SOURCE_REQUIRED",
        "a managed " .. gameLabel(versionId) .. " ROM is required",
        { versionId = versionId }
      )
    )
    return
  end
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
    width = App.drawableWidth,
    height = App.drawableHeight,
    safeRect = App._safeRect,
    pixelRatio = App.pixelRatio,
    displayContext = App._launcherDisplayContext(),
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
  local width, height = App.drawableWidth, App.drawableHeight
  local pixelRatio = App.pixelRatio
  assert(
    type(width) == "number" and width > 0 and type(height) == "number" and height > 0,
    "selected startup requires published drawable dimensions"
  )
  assert(type(pixelRatio) == "number" and pixelRatio > 0, "selected startup requires a published pixel ratio")
  local constructed, stateOrError = pcall(StartupTitleState.new, {
    versionId = versionId,
    epoch = epoch,
    cacheFs = runtime.cacheFs,
    assetRuntime = runtime,
    derivedAssets = provisioner:gameHost(),
    splRandomState = App.splRandomState,
    width = width,
    height = height,
    safeRect = App._safeRect,
    pixelRatio = pixelRatio,
    loading = loading,
    pairIndex = App.pairIndex,
    admitOpening = function()
      return App._admitOpening(epoch, versionId)
    end,
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

function App._prepareBootCandidate()
  if not App._bootPending then
    return App._bootCandidate
  end
  App._bootPending = false
  local metadata = readSaveMetadata()
  App._libraryMetadata = metadata
  local candidate = newestSave(metadata)
  if candidate ~= nil then
    candidate.ready = managedInstalled(candidate.versionId)
    App._bootCandidate = candidate
    if candidate.ready then
      App._selectVersion(candidate.versionId, { entryLocation = candidate.entryLocation })
    end
  end
  return App._bootCandidate
end

function App._routeBoot(candidate)
  App._bootPending = false
  if candidate ~= nil and managedInstalled(candidate.versionId) then
    App._selectVersion(candidate.versionId, { entryLocation = candidate.entryLocation })
  else
    App._showGameSelection(candidate and candidate.versionId or nil)
  end
end

function App._admitOpening(epoch, versionId)
  if App._foreground ~= true then
    return false
  end
  if App._touchGamepadSuspended or App.epoch ~= epoch or App.selectedVersionId ~= versionId then
    return false
  end
  if App._bootIntro == nil then
    return true
  end
  if App._bootIntro.foreground ~= true then
    return false
  end
  App._finishBootIntro(true)
  return true
end

function App._isPreOpening()
  if App._touchGamepadSuspended or App._importAttempt ~= nil or App.importer ~= nil then
    return false
  end
  if App._bootIntro ~= nil then
    return true
  end
  local state = App.state
  return state ~= nil and type(state.isAwaitingOpening) == "function" and state:isAwaitingOpening() == true
end

function App._interruptOpening(identity)
  if not App._isPreOpening() then
    return false
  end
  App._bootSwallowedInputs[identity] = true
  local candidate = App._bootCandidate
  App._bootPending = false
  App._finishBootIntro(false)
  App._showGameSelection(candidate and candidate.versionId or nil)
  return true
end

function App.load(opts)
  App.opts = opts or {}
  App._cleanupAbandonedImports()
  App.drawableWidth, App.drawableHeight = nil, nil
  App.pixelRatio = nil
  App._safeRect = nil
  App._displayContext = nil
  App._touchGamepadSuspended = false
  App._suspendedTouchIds = {}
  App._foreground = true
  App._realTouches = {}
  App.importer = nil
  App.provisioner = nil
  App.splRandomState = nil
  App.service = nil
  App.epoch = 0
  App.pendingQuiesce = nil
  App.pairIndex = nil
  App._importAttempt = nil
  App._releaseIconRecovery()
  App._iconRepairAttempted = {}
  App.selectedVersionId = nil
  App._swallowedPointers = {}
  App._bootSwallowedInputs = {}
  App._startupWarmup = nil
  App._saveLocationWarmup = nil
  App._selectedEntryLocation = nil
  App._libraryMetadata = nil
  App._bootCandidate = nil
  App._bootPending = true
  App._bootIntro = nil
  App.startupWarmupError = nil
  App.startupAudioSession = nil
  App.startupAudioError = nil
  App._assetRuntime = nil
  App._cacheLoading = false
  App.setState(nil)
  love.graphics.setBackgroundColor(unpack(WindowConfig.BACKGROUND_COLOR))
  App.saveDir = love.filesystem.getSaveDirectory()

  local setGain = function(_) end
  if love ~= nil and love.audio ~= nil and type(love.audio.setVolume) == "function" then
    local host = love.audio
    setGain = function(gain)
      host.setVolume(gain)
    end
  end
  App.audioPreferences = AudioPreferences.new({ storage = SaveFs.global(), setGain = setGain })
  App._ensureLauncherResources()
  App._syncDrawableSize()
  App._displayContext = App._launcherDisplayContext()
  App._bootIntro = BootIntroState.new({
    renderer = App.launcherRenderer,
    audio = App.launcherAudio,
    displayContext = App._displayContext,
    width = App.drawableWidth,
    height = App.drawableHeight,
    safeRect = App._safeRect,
    pixelRatio = App.pixelRatio,
  })
  love.graphics.setBackgroundColor(unpack(BOOT_BACKGROUND_COLOR))
end

-- Replaces only the UI state. Source ownership is explicit: selection,
-- re-import, selector return and quit retire the session; the
-- bootstrap-state to game handoff must not retire it.
function App.setState(nextState)
  local previous = App.state
  if previous ~= nextState and App._touchGamepad ~= nil then
    App._touchGamepad:setTarget(nil)
  end
  App.state = nextState
  if previous and previous.dispose then
    previous:dispose()
  end
end

function App._newImportAttempt(expectedVersionId)
  local attempt = {
    attemptId = {},
    expectedVersionId = expectedVersionId,
    mode = "choose",
    canCancel = true,
    pickerAvailable = NativeRomPicker.available() == true,
    elapsed = 0,
  }
  return attempt
end

function App._openImportChoose(expectedVersionId, failure)
  local attempt = App._importAttempt
  if attempt == nil then
    attempt = App._newImportAttempt(expectedVersionId)
    App._importAttempt = attempt
  end
  attempt.mode = failure ~= nil and "error" or "choose"
  attempt.error = failure
  attempt.canCancel = attempt.mode == "choose"
  App._finishBootIntro(false)
  App._bootPending = false
  App.setState(App._newGameSelectState(expectedVersionId))
end

function App._requestNativePicker()
  local attempt = App._importAttempt
  if attempt == nil or attempt.mode ~= "choose" or not attempt.pickerAvailable then
    return
  end
  local result = NativeRomPicker.openSingle()
  if result.kind == "path" then
    App._beginImportPath(result.path)
  elseif result.kind == "pending" then
    attempt.mode, attempt.requestId = "picker", result.requestId
    App.setState(App._newGameSelectState(attempt.expectedVersionId))
  elseif result.kind == "cancel" then
    attempt.mode = "choose"
    App.setState(App._newGameSelectState(attempt.expectedVersionId))
  elseif result.kind == "error" then
    App._failImport(Errors.new("ROM_PICKER_FAILED", tostring(result.message or "file picker failed"), {}))
  end
end

function App._pollNativePicker()
  local attempt = App._importAttempt
  local requestId = attempt ~= nil and attempt.mode == "picker" and attempt.requestId or nil
  local result = NativeRomPicker.poll(requestId)
  if result == nil then
    return
  end
  if attempt == nil or attempt.mode ~= "picker" or result.requestId ~= attempt.requestId then
    if result.kind == "path" then
      love.filesystem.remove(result.relativePath)
    end
    return
  end
  attempt.requestId = nil
  if result.kind == "path" then
    App._beginImportTemporary(result.relativePath, result.displayName, result.requestId)
  elseif result.kind == "cancel" then
    attempt.mode = "choose"
    App.setState(App._newGameSelectState(attempt.expectedVersionId))
  elseif result.kind == "error" then
    App._failImport(Errors.new("ROM_PICKER_FAILED", tostring(result.message), {}))
  end
end

function App._beginImportTemporary(relativePath, displayName, requestId)
  App._beginImportAttempt("temporary", relativePath, displayName, requestId)
end

function App._beginImportPath(path)
  if type(path) ~= "string" or (not path:lower():match("%.nds$") and not path:lower():match("%.zip$")) then
    App._failImport(Errors.new("ROM_FILE_UNSUPPORTED", "Choose a supported .nds or .zip file.", {}))
    return
  end
  App._beginImportAttempt("path", path)
end

function App._ensureAttemptImporter(attempt)
  if App.importer ~= nil then
    return App.importer
  end
  assert(App._importAttempt == attempt, "only the current attempt owns an importer")
  local importer
  importer = RomImporter.new({
    expectedVersionId = attempt.expectedVersionId,
    onComplete = function(versionId)
      App._onImported(versionId, importer)
    end,
  })
  App.importer = importer
  return importer
end

function App._showImportReceipt(attempt)
  assert(App._importAttempt == attempt, "a stale attempt cannot publish a receipt view")
  App.setState(App._newGameSelectState(attempt.expectedVersionId))
end

function App._authorizeImport(attempt, epoch, barrier)
  if App._importAttempt ~= attempt then
    return
  end
  if barrier ~= nil then
    local service = assert(App.service)
    local ok, authorized = pcall(service.importSource, service, epoch, barrier)
    if not ok or authorized ~= true then
      App._failImport(
        Errors.new(
          "ROM_SOURCE_IMPORT_DENIED",
          ok and "source publication was not authorized" or tostring(authorized),
          {}
        )
      )
      return
    end
  end
  attempt.authorized = true
  attempt.mode = "receipt"
  attempt.canCancel = true
  App._ensureAttemptImporter(attempt)
  App._showImportReceipt(attempt)
end

function App._beginImportTransaction(attempt)
  App._finishBootIntro(false)
  App._bootPending = false
  App._retireSelection()
  local service = App.service
  if service == nil then
    App._authorizeImport(attempt, nil, nil)
    return
  end
  local epoch = App.epoch or 0
  local barrier = App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier or service:quiesce(epoch)
  if barrier == nil then
    App._authorizeImport(attempt, epoch, nil)
    return
  end
  App.pendingQuiesce = { epoch = epoch, barrier = barrier }
  attempt.mode, attempt.canCancel = "draining", true
  App._showQuiescence(attempt)
end

function App._beginImportAttempt(kind, value, receiptName, requestId)
  local currentState = App.state
  if kind == "drop" and currentState ~= nil and type(currentState.onImportAttempt) == "function" then
    currentState:onImportAttempt()
    return
  end
  local attempt = App._importAttempt
  if attempt ~= nil and attempt.mode ~= "choose" and attempt.mode ~= "picker" and attempt.mode ~= "error" then
    return
  end
  if App._touchGamepadSuspended then
    return
  end
  if App.importer ~= nil then
    local state = App.importer.state
    local status = type(App.importer.status) == "function" and App.importer:status() or nil
    if
      state == RomImporter.STATES.READING
      or state == RomImporter.STATES.VERIFYING
      or state == RomImporter.STATES.REGISTERING
      or (status ~= nil and status.canCancel == true)
    then
      return
    end
    App.importer = nil
  end
  if attempt ~= nil and attempt.mode == "error" then
    attempt = App._newImportAttempt(attempt.expectedVersionId)
  end
  attempt = attempt or App._newImportAttempt(nil)
  App._importAttempt = attempt
  attempt.descriptor = { kind = kind, value = value, requestId = requestId }
  attempt.receipt = receiptName or App._receiptName(kind, value)
  attempt.mode, attempt.canCancel = "receipt", true
  App._beginImportTransaction(attempt)
end

function App._noteReceiptPaint()
  local attempt = App._importAttempt
  if attempt == nil or attempt.painted or attempt.started or attempt.receipt == nil or App._touchGamepadSuspended then
    return
  end
  local state = App.state
  if state == nil or type(state.paintedReceipt) ~= "function" then
    return
  end
  local ok, token = pcall(state.paintedReceipt, state)
  if ok and token == attempt.attemptId then
    attempt.painted = true
  end
end

function App._startPendingImport()
  local attempt = App._importAttempt
  if
    attempt == nil
    or attempt.descriptor == nil
    or attempt.started
    or not attempt.painted
    or not attempt.authorized
    or App.pendingQuiesce ~= nil
    or App._touchGamepadSuspended
  then
    return
  end
  local importer = assert(App.importer, "an authorized attempt owns its importer")
  local descriptor = attempt.descriptor
  local ok, accepted, failure = pcall(function()
    if descriptor.kind == "temporary" then
      return importer:queueTemporaryPath(descriptor.value, descriptor.requestId)
    elseif descriptor.kind == "path" then
      return importer:queuePath(descriptor.value)
    else
      return importer:queueDroppedFile(descriptor.value)
    end
  end)
  if ok and (descriptor.kind ~= "temporary" or accepted == true) then
    attempt.started, attempt.mode = true, "importing"
    if importer.state == RomImporter.STATES.ERROR then
      App._failImport(assert(importer:status()).error or "ROM import failed")
    end
    return
  end
  if descriptor.kind == "temporary" then
    love.filesystem.remove(descriptor.value)
  end
  if not ok then
    if not Errors.is(accepted) then
      error(accepted, 0)
    end
    failure = accepted
  elseif descriptor.kind == "temporary" and not Errors.is(failure) then
    failure = Errors.new("ROM_IMPORT_REQUEST_INVALID", "temporary import was not accepted", {})
  end
  if not Errors.is(failure) then
    error(failure, 0)
  end
  App._failImport(failure)
end

function App._failImport(failure)
  local attempt = App._importAttempt
  if attempt == nil then
    attempt = App._newImportAttempt(nil)
    App._importAttempt = attempt
  end
  if not Errors.is(failure) then
    failure = Errors.new("ROM_IMPORT_FAILED", tostring(failure or "ROM import failed"), {})
  end
  if attempt.descriptor ~= nil and attempt.descriptor.kind == "temporary" and not attempt.started then
    love.filesystem.remove(attempt.descriptor.value)
  end
  attempt.descriptor = nil
  if not attempt.started then
    App.importer = nil
  end
  attempt.mode, attempt.error, attempt.canCancel = "error", failure, false
  App.setState(App._newGameSelectState(attempt.expectedVersionId))
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
  local pendingIcon = App._pendingIconData
  if pendingIcon ~= nil then
    local info = GameVersion.forSha1(pendingIcon.romSha1)
    if info ~= nil and info.id == versionId then
      App._pendingIconData = nil
      pendingIcon.png:release()
    end
  end
  App.importer = nil
  App._importAttempt = nil
  App._showGameSelection(versionId)
end

function App._bootMainMenu(versions)
  assert(type(versions) == "table" and #versions == 1, "Main Menu needs exactly one selected version")
  App._selectVersion(versions[1])
end

function App._bootExisting()
  App._bootPending = false
  local metadata = readSaveMetadata()
  App._libraryMetadata = metadata
  App._bootCandidate = newestSave(metadata)
  App._finishBootIntro(false)
  App._routeBoot(App._bootCandidate)
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
  if App._touchGamepadSuspended then
    return
  end
  if App._touchGamepad ~= nil then
    App._touchGamepad:sync()
  end
  App._pollNativePicker()
  App._pollIconRecovery()
  if App._importAttempt ~= nil then
    App._importAttempt.elapsed = (App._importAttempt.elapsed or 0) + dt
  end
  if
    App.importer ~= nil
    and App.importer.state ~= RomImporter.STATES.COMPLETE
    and App.importer.state ~= RomImporter.STATES.ERROR
  then
    App.importer:update()
  end
  if
    App.importer ~= nil
    and App.importer.state == RomImporter.STATES.ERROR
    and App._importAttempt ~= nil
    and App._importAttempt.mode ~= "error"
  then
    App._failImport(assert(App.importer:status()).error or "ROM import failed")
  end
  if App.service then
    App.service:update()
  end
  App._updateStartupWarmup()
  App._updateSaveLocationWarmup()
  if App.launcherAudio ~= nil then
    App.launcherAudio:update(dt)
  end
  if App._bootIntro ~= nil then
    App._bootIntro:update(dt)
  end
  if App.state and App.state.update then
    App.state:update(dt)
  end
  if App._bootIntro ~= nil and App._bootPending and App._bootIntro.painted then
    App._prepareBootCandidate()
    if App.state ~= nil and getmetatable(App.state) == CachePreparationState and App.state.kind == "boot-source" then
      App.state:update(0)
    end
  end
  if
    App._bootIntro ~= nil
    and App.state ~= nil
    and getmetatable(App.state) == StartupTitleState
    and (App.state.phase == "error" or App.state:hasInitialAudioFailure())
  then
    App._finishBootIntro(false)
  end
  if App._bootIntro ~= nil and App._bootIntro.elapsed + 1e-9 >= 5 then
    App._finishBootIntro(false)
    if App.state == nil then
      App._showGameSelection(App._bootCandidate and App._bootCandidate.versionId or nil)
    end
  end
  App._syncCacheExecutionPolicy()
  if App._touchGamepad ~= nil then
    App._touchGamepad:sync()
  end
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

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function copySafe(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

local function sameRectangle(a, b)
  return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

local function sampleNativeFacts()
  local graphics = love.graphics
  local function sample()
    local width, height = graphics.getDimensions()
    local ratio = graphics.getDPIScale()
    local safe
    if type(love.window.getSafeArea) == "function" then
      local x, y, safeWidth, safeHeight = love.window.getSafeArea()
      safe = { x = x, y = y, width = safeWidth, height = safeHeight }
    elseif love.system.getOS() ~= "Android" and love.system.getOS() ~= "iOS" then
      safe = { x = 0, y = 0, width = width, height = height }
    end
    local widthAfter, heightAfter = graphics.getDimensions()
    local ratioAfter = graphics.getDPIScale()
    return width, height, ratio, safe, widthAfter, heightAfter, ratioAfter
  end
  local width, height, ratio, safe, widthAfter, heightAfter, ratioAfter = sample()
  if width ~= widthAfter or height ~= heightAfter or ratio ~= ratioAfter then
    width, height, ratio, safe = sample()
  end
  return width, height, ratio, safe
end

function App._cancelLeafCaptures()
  if App._touchGamepad ~= nil then
    App._touchGamepad:cancel()
  end
  if App.state ~= nil and type(App.state.focus) == "function" then
    App.state:focus(false)
  end
  if App._bootIntro ~= nil then
    App._bootIntro:focus(false)
  end
  App._swallowedPointers = {}
end

function App._publishDrawableSize(width, height, pixelRatio, safeRect)
  local valid = finite(width)
    and width > 0
    and finite(height)
    and height > 0
    and finite(pixelRatio)
    and pixelRatio > 0
    and type(safeRect) == "table"
    and finite(safeRect.x)
    and finite(safeRect.y)
    and finite(safeRect.width)
    and safeRect.width > 0
    and finite(safeRect.height)
    and safeRect.height > 0
  local usable
  if valid then
    local x = math.max(0, safeRect.x)
    local y = math.max(0, safeRect.y)
    local farX = math.min(width, safeRect.x + safeRect.width)
    local farY = math.min(height, safeRect.y + safeRect.height)
    if farX > x and farY > y then
      usable = { x = x, y = y, width = farX - x, height = farY - y }
    end
  end
  if usable == nil then
    if not App._touchGamepadSuspended then
      App._cancelLeafCaptures()
      for id in pairs(App._realTouches) do
        App._suspendedTouchIds[id] = true
      end
    end
    App._touchGamepadSuspended = true
    return
  end
  local changed = App._forceDisplayPublication
    or App._touchGamepadSuspended
    or width ~= App.drawableWidth
    or height ~= App.drawableHeight
    or pixelRatio ~= App.pixelRatio
    or not sameRectangle(usable, App._safeRect)
  if not changed then
    return
  end
  App._cancelLeafCaptures()
  App.drawableWidth, App.drawableHeight, App.pixelRatio = width, height, pixelRatio
  App._safeRect = copySafe(usable)
  App._displayContext = App._launcherDisplayContext()
  App._touchGamepadSuspended = false
  App._forceDisplayPublication = false
  if App._touchGamepad ~= nil then
    App._touchGamepad:setGeometry(width, height, App._safeRect, pixelRatio)
  end
  if App._importAttempt ~= nil and not App._importAttempt.started then
    App._importAttempt.painted = false
  end
  if App._bootIntro ~= nil then
    App._bootIntro:resize(width, height, App._safeRect, pixelRatio)
  end
  if App.state ~= nil and type(App.state.resize) == "function" then
    App.state:resize(width, height, App._safeRect, pixelRatio)
  end
  if App.state ~= nil and type(App.state.focus) == "function" then
    App.state:focus(true)
  end
  if App._bootIntro ~= nil then
    App._bootIntro:focus(App._foreground)
  end
end

function App.resize(_, _)
  App._forceDisplayPublication = true
  App._syncDrawableSize()
  if not App._touchGamepadSuspended then
    if App.state ~= nil and type(App.state.focus) == "function" then
      App.state:focus(true)
    end
    if App._bootIntro ~= nil then
      App._bootIntro:focus(App._foreground)
    end
  end
end

function App._syncDrawableSize()
  local width, height, ratio, safe = sampleNativeFacts()
  App._publishDrawableSize(width, height, ratio, safe)
end

function App.draw()
  if App._touchGamepadSuspended then
    App._syncDrawableSize()
  end
  if App._touchGamepadSuspended then
    return
  end
  love.graphics.setColor(1, 1, 1, 1)
  if App._bootIntro ~= nil then
    App._bootIntro:draw()
  elseif App.state and App.state.draw then
    App.state:draw()
  elseif App.opts.dev then
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("portemon", 24, 24)
  end
  App._noteReceiptPaint()
  if App._touchGamepad ~= nil then
    App._touchGamepad:draw()
  end
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

local BOOT_MODIFIERS =
  { lshift = true, rshift = true, lctrl = true, rctrl = true, lalt = true, ralt = true, lgui = true, rgui = true }

local function releaseBootInput(identity)
  if App._bootSwallowedInputs ~= nil then
    App._bootSwallowedInputs[identity] = nil
  end
end

local function pointerInSafe(x, y)
  local safe = App._safeRect
  return type(x) == "number"
    and type(y) == "number"
    and safe ~= nil
    and x >= safe.x
    and x < safe.x + safe.width
    and y >= safe.y
    and y < safe.y + safe.height
end

function App.keypressed(key, scancode, isrepeat)
  if key == "f11" then
    if not isrepeat then
      love.window.setFullscreen(not love.window.getFullscreen())
    end
    return
  end
  App._syncDrawableSize()
  if App._touchGamepadSuspended then
    return
  end
  local identity = "key:" .. key
  if App._bootSwallowedInputs[identity] then
    return
  end
  if not isrepeat and not BOOT_MODIFIERS[key] and App._interruptOpening(identity) then
    return
  end
  if App.state and App.state.keypressed then
    App.state:keypressed(key, scancode, isrepeat)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
    return
  end
  if key == "escape" then
    love.event.quit(0)
  end
end

function App.keyreleased(key, scancode)
  local identity = "key:" .. key
  if App._bootSwallowedInputs[identity] then
    releaseBootInput(identity)
    return
  end
  if App.state and App.state.keyreleased then
    App.state:keyreleased(key, scancode)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.gamepadpressed(joystick, button)
  App._syncDrawableSize()
  if App._touchGamepadSuspended then
    return
  end
  local identity = "gamepad:" .. tostring(joystick) .. ":" .. button
  if App._bootSwallowedInputs[identity] then
    return
  end
  if App._interruptOpening(identity) then
    return
  end
  if App.state and App.state.gamepadpressed then
    App.state:gamepadpressed(joystick, button)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.gamepadreleased(joystick, button)
  local identity = "gamepad:" .. tostring(joystick) .. ":" .. button
  if App._bootSwallowedInputs[identity] then
    releaseBootInput(identity)
    return
  end
  if App.state and App.state.gamepadreleased then
    App.state:gamepadreleased(joystick, button)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.gamepadaxis(joystick, axis, value)
  if App.state and App.state.gamepadaxis then
    App.state:gamepadaxis(joystick, axis, value)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.mousepressed(x, y, button, istouch, presses)
  if istouch then
    return
  end
  App._syncDrawableSize()
  if App._touchGamepadSuspended then
    return
  end
  local pointerId = "mouse:" .. tostring(button)
  if App._bootSwallowedInputs[pointerId] then
    return
  end
  if button == 1 and pointerInSafe(x, y) and App._interruptOpening(pointerId) then
    return
  end
  if App._bootIntro ~= nil and not pointerInSafe(x, y) then
    return
  end
  local state = App.state
  if state and state.mousepressed then
    state:mousepressed(x, y, button, istouch, presses)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
    if getmetatable(state) == StartupTitleState and state.canceledPointers[pointerId] then
      App._swallowedPointers[pointerId] = true
    end
  end
end

function App.mousemoved(x, y, dx, dy, istouch)
  if istouch then
    return
  end
  App._syncDrawableSize()
  if App._touchGamepadSuspended then
    return
  end
  local pointerId = "mouse:1"
  if App._bootSwallowedInputs[pointerId] then
    return
  end
  if App.state and App.state.mousemoved then
    App.state:mousemoved(x, y, dx, dy, istouch)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.mousereleased(x, y, button, istouch, presses)
  if istouch then
    return
  end
  App._syncDrawableSize()
  if App._touchGamepadSuspended then
    return
  end
  local pointerId = "mouse:" .. tostring(button)
  if App._bootSwallowedInputs[pointerId] then
    releaseBootInput(pointerId)
    return
  end
  if App._swallowedPointers[pointerId] then
    local state = App.state
    if state ~= nil and getmetatable(state) == StartupTitleState then
      state:mousereleased(x, y, button, istouch, presses)
    end
    App._swallowedPointers[pointerId] = nil
    return
  end
  if App.state and App.state.mousereleased then
    App.state:mousereleased(x, y, button, istouch, presses)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.wheelmoved(x, y)
  if App.state and App.state.wheelmoved then
    App.state:wheelmoved(x, y)
  end
end

function App.touchpressed(id, x, y, dx, dy, pressure)
  App._realTouches[id] = true
  App._syncDrawableSize()
  local pointerId = "touch:" .. tostring(id)
  if App._touchGamepadSuspended then
    App._suspendedTouchIds[id] = true
    return
  end
  App._suspendedTouchIds[id] = nil
  if App._bootSwallowedInputs[pointerId] then
    return
  end
  if App._touchGamepad ~= nil and App._touchGamepad:touchpressed(id, x, y) then
    return
  end
  if pointerInSafe(x, y) and App._interruptOpening(pointerId) then
    return
  end
  if App._bootIntro ~= nil and not pointerInSafe(x, y) then
    return
  end
  local state = App.state
  if state and state.touchpressed then
    state:touchpressed(id, x, y, dx, dy, pressure)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
    if getmetatable(state) == StartupTitleState and state.canceledPointers[pointerId] then
      App._swallowedPointers[pointerId] = true
    end
  end
end

function App.touchmoved(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  if App._touchGamepadSuspended or App._suspendedTouchIds[id] then
    return
  end
  local pointerId = "touch:" .. tostring(id)
  if App._bootSwallowedInputs[pointerId] then
    return
  end
  if App._touchGamepad ~= nil and App._touchGamepad:touchmoved(id, x, y) then
    return
  end
  if App.state and App.state.touchmoved then
    App.state:touchmoved(id, x, y, dx, dy, pressure)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.touchreleased(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  local pointerId = "touch:" .. tostring(id)
  App._realTouches[id] = nil
  if App._touchGamepadSuspended or App._suspendedTouchIds[id] then
    App._suspendedTouchIds[id] = nil
    releaseBootInput(pointerId)
    return
  end
  if App._bootSwallowedInputs[pointerId] then
    releaseBootInput(pointerId)
    return
  end
  if App._touchGamepad ~= nil and App._touchGamepad:touchreleased(id, x, y) then
    return
  end
  if App._swallowedPointers[pointerId] then
    local state = App.state
    if state ~= nil and getmetatable(state) == StartupTitleState then
      state:touchreleased(id, x, y, dx, dy, pressure)
    end
    App._swallowedPointers[pointerId] = nil
    return
  end
  if App.state and App.state.touchreleased then
    App.state:touchreleased(id, x, y, dx, dy, pressure)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.textinput(text)
  if App.state and App.state.textinput then
    App.state:textinput(text)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.focus(focused)
  App._foreground = focused == true
  if not focused then
    if App._touchGamepad ~= nil then
      App._touchGamepad:cancel()
    end
    App._swallowedPointers = {}
    App._bootSwallowedInputs = {}
    App._realTouches = {}
    App._suspendedTouchIds = {}
  end
  if App._bootIntro ~= nil then
    App._bootIntro:focus(App._foreground)
  end
  if App.state and App.state.focus then
    App.state:focus(focused)
    if App._touchGamepad ~= nil then
      App._touchGamepad:sync()
    end
  end
end

function App.quit()
  local currentState = App.state
  if currentState ~= nil and type(currentState.requestClose) == "function" then
    if currentState:requestClose("quit") then
      return true
    end
  end
  local attempt = App._importAttempt
  if attempt ~= nil and attempt.mode == "importing" then
    local importer = App.importer
    local status = importer ~= nil and importer:status() or nil
    if status == nil or status.canCancel ~= true then
      return true
    end
  end
  if attempt ~= nil then
    App._cancelImport()
  end
  App._finishBootIntro(false)
  App._releaseIconRecovery()
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
  App._safeRect = nil
  App._displayContext = nil
  App._importAttempt = nil
  App.importer = nil
end

return App
