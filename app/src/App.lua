-- Launcher/process shell for the interactive app root.

local WindowConfig = require("game.src.WindowConfig")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")
local CacheService = require("app.src.CacheService")
local HgssGame = require("game.hgss.src.HgssGame")
local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local ImportState = require("app.src.launcher.ImportState")
local VersionSelectState = require("app.src.launcher.VersionSelectState")
local NativeRomPicker = require("app.src.launcher.NativeRomPicker")
local EditionPreference = require("app.src.launcher.EditionPreference")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local StartupTitleState = require("app.src.launcher.StartupTitleState")
local StartupAudioSession = require("app.src.audio.StartupAudioSession")
local CacheFs = require("libs.storage.src.CacheFs")

---@class App
---@field opts AppOptions
---@field state table<string, unknown>|nil
---@field importer RomImporter|nil
---@field provisioner DerivedAssetProvisioner|nil
---@field service CacheService|nil process-owned cache controller service shared by every selection
---@field epoch integer latest borrowed controller epoch, monotonically increasing
---@field pendingQuiesce table<string, integer>|nil unacknowledged source-close barrier for import
---@field pairIndex integer? selected-epoch walking pair 1..32, chosen once per selection
---@field _publishedPairHint { versionId: string, pairIndex: integer, receipt: string? }? volatile smallest-pair hint keyed by version and publication receipt, never source authorization
---@field _importReceipt string? received filename latched synchronously on drop/picker input
---@field _pendingImport table<string, unknown>? deferred import descriptor awaiting its receipt paint
---@field selectedVersionId string? currently selected game version
---@field _rebindVersionId string? version a pending raw drop is expected to supply back
---@field _bootBlockedVersionId string? version a blocked boot refuses to switch away from
---@field importPickerError string? latest recoverable picker or preference detail
---@field preferenceError string? last-played preference write diagnostic
---@field _startupWarmup { epoch: integer, versionId: string, preparation: table<string, function> }?|nil
---@field startupWarmupError string? background first-play diagnostic, never a menu gate
---@field startupAudioSession StartupAudioSession?|nil optional selected-version title/menu audio owner
---@field startupAudioError string?|nil non-gating audio diagnostic
---@field _swallowedPointers table<string, boolean> pointer releases owned by startup during a transfer
---@field drawableWidth number?
---@field drawableHeight number?
---@field pixelRatio number?
local App = {}

---@class AppOptions
---@field test boolean?
---@field dev boolean?

-- Version registration only lists candidates for the boot gate: every
-- selection waits for source readiness before the menu, first play, or
-- retail. A current complete derived cache keeps its offline fast path
-- without any source access; an incomplete cache stays blocked until its
-- exact ROM is verified, even when its bounded opening closure is ready.
-- Neither check opens or hashes the ROM on the fast path.
local function readyVersions()
  local out = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      out[#out + 1] = versionId
    else
      local ok, generation = pcall(FirstPlayCompletion.releaseGenerationId, versionId)
      if ok and FirstPlayCompletion.isCurrent(versionId, generation) then
        out[#out + 1] = versionId
      end
    end
  end
  return out
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

function App._ensureService()
  if App.service ~= nil then
    return
  end
  App.service = CacheService.new()
end

-- Retire the interactive import session without blocking: a queued worker is
-- told to abandon its registration gate, late results are invalidated, and
-- the pending first-paint descriptor is dropped so no worker starts later.
function App._cancelImport()
  local importer = App.importer
  App.importer = nil
  App._pendingImport = nil
  if importer ~= nil and type(importer.cancelQueued) == "function" then
    importer:cancelQueued()
  end
end

-- Retires the selected source interest without joining controller work.
-- The process service is reused; stale results cannot publish afterwards.
function App._retireSelection()
  App._swallowedPointers = {}
  App.pairIndex = nil
  App._importReceipt = nil
  App._cancelImport()
  App._releaseStartupAudio()
  local warmup = App._startupWarmup
  App._startupWarmup = nil
  if warmup ~= nil then
    warmup.preparation:dispose()
  end
  local provisioner = App.provisioner
  App.provisioner = nil
  if provisioner then
    provisioner:dispose()
  end
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
    return StartupAudioSession.new({
      versionId = versionId,
      cacheFs = CacheFs.forVersion(versionId),
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
    openingReady = function()
      invoke("beginOpening", true)
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
---@return integer selected 1..32 walking pair
local function selectedPairIndex()
  local pairIndex = App.pairIndex
  assert(
    type(pairIndex) == "number" and pairIndex % 1 == 0 and pairIndex >= 1 and pairIndex <= 32,
    "selection has no walking pair"
  )
  return pairIndex --[[@as integer]]
end

---@param versionId string
---@return table<string, unknown> staged MainMenuState
local function stageMenu(versionId)
  local audio = App.epoch ~= nil and startupAudioBorrow(versionId, App.epoch) or nil
  local ok, menuOrError = pcall(MainMenuComposition.new, {
    versionId = versionId,
    width = App.drawableWidth,
    height = App.drawableHeight,
    audio = audio,
    onResult = function(result)
      if result.kind == "new_game" then
        App._launchGameWithProvisioner(versionId, { kind = "new_game" })
      elseif result.kind == "continue" then
        App._launchGameWithProvisioner(versionId, { kind = "continue", saveId = result.saveId })
      elseif result.kind == "edit" then
        local provisioner = assert(App.provisioner, "save editing needs the selected provisioner")
        local ok, stateOrError = pcall(SaveEditorState.new, {
          versionId = versionId,
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
        if not ok then
          App._restoreMenuWithProvisioner(versionId)
          error(stateOrError, 0)
        end
        App.setState(assert(stateOrError))
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
    App._showVersionSelector()
    error(menu, 0)
  end
  App.setState(assert(menu))
end

-- Installs the selected-version product menu and starts the one-time
-- speculative work that is useful while it remains open.
---@param versionId string
---@param stagedMenu table<string, unknown>?
function App._launchMenuWithProvisioner(versionId, stagedMenu)
  local provisioner = assert(App.provisioner, "selection has no provisioner")
  if stagedMenu == nil then
    installMenu(versionId)
  else
    assert(type(stagedMenu) == "table" and type(stagedMenu.dispose) == "function")
    App.setState(stagedMenu)
  end
  -- The transfer above is committed: every optional step below is
  -- individually contained so it can only record a diagnostic, never throw
  -- back into a rollback of the installed menu.
  local host = provisioner:gameHost()
  for _, name in ipairs({ "new-game-intro", "field-planning", "field-runtime" }) do
    local ok, failure = pcall(host.requestMilestone, name, "near")
    if not ok then
      App.startupWarmupError = tostring(failure)
    end
  end
  local battleOk, battleFailure = pcall(host.requestBattlePresentation, "near")
  if not battleOk then
    App.startupWarmupError = tostring(battleFailure)
  end
  local warmupOk, warmupFailure = pcall(provisioner.startBackgroundWarmup, provisioner)
  if not warmupOk then
    App.startupWarmupError = tostring(warmupFailure)
  end
end

-- Optional near-priority preparation runs beside the startup presentation;
-- only the coordinator's complete answer can publish its durable receipt.
---@param versionId string
---@param epoch integer
function App._maybeStartFirstPlayWarmup(versionId, epoch)
  if App._startupWarmup ~= nil or App.epoch ~= epoch or App.selectedVersionId ~= versionId then
    return
  end
  local generation = App._firstPlayGeneration(versionId)
  if generation ~= nil and FirstPlayCompletion.isCurrent(versionId, generation) then
    return
  end
  local provisioner = App.provisioner
  if provisioner == nil then
    return
  end
  local ok, preparation = pcall(HgssGame.newFirstPlayCachePreparation, {
    versionId = versionId,
    derivedAssets = provisioner:gameHost(),
    completion = App._firstPlayGateway(versionId),
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
    App._publishFirstPlay(warmup.versionId)
    warmup.preparation:dispose()
    App._startupWarmup = nil
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
  App._releaseStartupAudio()
  local ok, gameOrError = pcall(HgssGame.new, {
    versionId = versionId,
    startupPairIndex = selectedPairIndex(),
    entry = entry,
    onExit = function(result)
      if result and result.kind == "main_menu" then
        App._restoreMenuWithProvisioner(versionId)
      elseif result and result.kind == "quit" then
        love.event.quit(0)
      end
    end,
    development = App.opts.dev,
    derivedAssets = provisioner:gameHost(),
  })
  if not ok then
    App._showVersionSelector()
    error(gameOrError, 0)
  end
  App.setState(assert(gameOrError))
  local recorded, recordError = EditionPreference.recordPlayed(versionId)
  if not recorded then
    App.preferenceError = tostring(recordError)
    print("Could not save the last played edition: " .. App.preferenceError)
  end
end

function App._showVersionSelector()
  App._rebindVersionId = nil
  App._bootBlockedVersionId = nil
  App.importPickerError = nil
  App._retireSelection()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  App.setState(VersionSelectState.new(ready, function(versionId)
    App._selectVersion(versionId)
  end))
end

-- A pending source-close barrier blocks new selections behind a visible
-- wait: no new session writes shared version roots before the controller
-- acknowledges that every source reader closed successfully.
---@param versionId string newly selected game version
---@param options { freshImport: boolean?, sourceOffer: userdata?, bootMismatch: string?, importStatus: { state: string?, progress: number?, versionId: string?, displayName: string?, sourceName: string? }?, importReceipt: string? }? private selection mode
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
    isCurrent = function(_)
      return App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier == pending.barrier
    end,
    onReady = function()
      App.pendingQuiesce = nil
      App._selectVersion(versionId, options)
    end,
    onCancel = function()
      App.pendingQuiesce = nil
      App._showVersionSelector()
    end,
  }))
  return true
end

-- Durable first-play generation for one selection: the controller-derived
-- token when known, else the synchronous release identity (pure constants,
-- no producer scan). Development selections without a controller answer yet
-- report unknown; the caller prepares again.
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
  local ok, generation = pcall(FirstPlayCompletion.releaseGenerationId, versionId)
  if ok then
    return generation
  end
  return nil
end

-- Gateway handed to first-play preparation on the ordinary selection path:
-- durable attestation answers owned by the import orchestration boundary.
-- It captures the selecting provisioner, so the generation answer follows
-- the selection epoch without reaching the game-facing host surface.
---@param versionId string newly selected game version
---@return table<string, function>
function App._firstPlayGateway(versionId)
  local provisioner = App.provisioner
  return {
    hasStored = function()
      return FirstPlayCompletion.hasStored(versionId)
    end,
    isCurrent = function(generationId)
      return FirstPlayCompletion.isCurrent(versionId, generationId)
    end,
    currentGeneration = function()
      if provisioner == nil or type(provisioner.generationId) ~= "function" then
        return nil
      end
      return provisioner:generationId()
    end,
  }
end

-- Publish the generation-scoped first-play completion after the closure
-- succeeded, keeping the same provisioner epoch for the menu. A failed
-- publication still launches: the closure is ready and only its
-- attestation is missing, so the next boot prepares again. Failure and
-- cancellation paths never reach this function, so they never publish.
---@param versionId string newly selected game version
function App._publishFirstPlay(versionId)
  local generation = App._firstPlayGeneration(versionId)
  if generation == nil then
    return
  end
  pcall(FirstPlayCompletion.publish, versionId, generation)
end

-- Publication receipt for the volatile pair hint: the controller-derived
-- generation token for the selecting provisioner when known. A nil receipt
-- never trusts the hint; the owning scan settles the pair instead. The
-- receipt only proves the publication set is unchanged, never authorization.
---@return string? current publication receipt, or nil when still unknown
local function currentPublicationReceipt()
  local provisioner = App.provisioner
  if provisioner ~= nil and type(provisioner.generationId) == "function" then
    local ok, known = pcall(provisioner.generationId, provisioner)
    if ok and type(known) == "string" and known ~= "" then
      return known
    end
  end
  return nil
end

-- Warm pair scan: the smallest currently published walking pair (1..32) is
-- reused for the new epoch; when no manifest loads, the epoch falls back
-- to one fresh random pair for normal preparation. A volatile hint keyed by
-- version and publication receipt avoids rescanning all 32 manifests when
-- the same version still publishes under the same receipt: the hint only
-- orders the probe, and every slot is validated through the presentation
-- that owns walker manifests, so a smaller newcomer or stale entry still
-- resolves to the exact smallest full scan. The controller still gates every
-- transfer, so an unverified file can never pose as a pair.
---@param versionId string newly selected game version
---@return integer? currently published pair, or nil when none loads
local function publishedPair(versionId)
  local cacheOk, cacheFs = pcall(CacheFs.forVersion, versionId)
  if not cacheOk or cacheFs == nil then
    return nil
  end
  local receipt = currentPublicationReceipt()
  local hint = App._publishedPairHint
  local hinted = nil
  if
    type(hint) == "table"
    and hint.versionId == versionId
    and hint.receipt ~= nil
    and hint.receipt == receipt
    and type(hint.pairIndex) == "number"
    and hint.pairIndex % 1 == 0
    and hint.pairIndex >= 1
    and hint.pairIndex <= 32
  then
    hinted = hint.pairIndex
  end
  local found
  if hinted ~= nil then
    -- A matching hint only orders the owner-validated probe: slots below
    -- the hint are rechecked first so a smaller newcomer still wins, and
    -- a stale hint falls through to the exact smallest full scan.
    for pairIndex = 1, hinted - 1 do
      if HgssLoadingPresentation.publishedPairSlot(cacheFs, pairIndex) then
        found = pairIndex
        break
      end
    end
    if found == nil and HgssLoadingPresentation.publishedPairSlot(cacheFs, hinted) then
      found = hinted
    end
    if found == nil then
      for pairIndex = hinted + 1, 32 do
        if HgssLoadingPresentation.publishedPairSlot(cacheFs, pairIndex) then
          found = pairIndex
          break
        end
      end
    end
  else
    found = HgssLoadingPresentation.publishedPair(cacheFs)
  end
  if found ~= nil then
    App._publishedPairHint = { versionId = versionId, pairIndex = found, receipt = receipt }
  elseif type(App._publishedPairHint) == "table" and App._publishedPairHint.versionId == versionId then
    App._publishedPairHint = nil
  end
  return found
end

-- Whether the version already carries a persisted source registration.
-- Answered behind the importer seam without opening the ROM: a filename
-- or launch route alone never counts, and a failed read is unregistered.
---@param versionId string newly selected game version
---@return boolean
local function alreadyRegistered(versionId)
  local cacheOk, cacheFs = pcall(CacheFs.forVersion, versionId)
  if not cacheOk or cacheFs == nil then
    return false
  end
  return RomImporter.isRegistered(cacheFs, versionId)
end

-- Selects a game version: borrows a controller epoch through its
-- provisioner, hands any verified offered source to the controller, queues
-- the boot readiness gate behind it on the same control stream, and waits
-- through a visible boot-source state. Nothing downstream (menu, retail,
-- first-play preparation, background sweep) runs before the gate answers
-- ready for this exact epoch.
---@param versionId string newly selected game version
---@param options { freshImport: boolean?, sourceOffer: userdata?, bootMismatch: string?, importStatus: { state: string?, progress: number?, versionId: string?, displayName: string?, sourceName: string? }?, importReceipt: string? }? private selection mode, default ordinary
function App._selectVersion(versionId, options)
  if App._waitForQuiescence(versionId, options) then
    return
  end
  App.selectedVersionId = versionId
  App._retireSelection()
  local provisioner = DerivedAssetProvisioner.new(provisionerOptions(versionId))
  App.provisioner = provisioner
  App.epoch = assert(provisioner.epoch, "selection borrowed no epoch")
  -- One walking pair per newly selected epoch: the App alone chooses it
  -- once per selection, preferring the smallest currently published pair
  -- on a warm cache and rolling one fresh random pair otherwise. Later
  -- journeys (menu returns, New Game, Continue, editor, late GPU adoption)
  -- reuse it, never reroll.
  App.pairIndex = publishedPair(versionId) or math.floor(love.math.random(1, 32))
  local epoch = App.epoch
  local service = assert(App.service, "process cache service is unavailable")
  -- A newly imported verified source crosses on the same control stream
  -- behind selection and ahead of the gate, by reference; the controller
  -- validates and pins it. An ordinary selection carries no offer.
  local offer = options ~= nil and options.sourceOffer or nil
  if type(offer) == "userdata" then
    local info = GameVersion.info(versionId)
    service:offerSource(epoch, offer, { versionId = versionId, romSha1 = info.sha1 })
  end
  service:requestBootSource(epoch)
  local mismatch = options ~= nil and options.bootMismatch or nil
  local freshImport = options ~= nil and options.freshImport == true
  local importStatus = (freshImport and options ~= nil) and options.importStatus or nil
  local importReceipt = (freshImport and options ~= nil) and options.importReceipt or nil
  App.setState(CachePreparationState.new({
    kind = "boot-source",
    epoch = epoch,
    service = service,
    versionId = versionId,
    mismatch = mismatch,
    pairIndex = App.pairIndex,
    freshImport = freshImport,
    importStatus = importStatus,
    importReceipt = importReceipt,
    isCurrent = function(selected)
      return App.epoch == selected
    end,
    onReady = function()
      App._continueSelectedVersion(versionId, options)
    end,
    onCancel = function()
      App._showVersionSelector()
    end,
  }))
end

-- Continues the selected version once its boot gate answered ready for the
-- exact selected epoch: installs the startup title directly, which stages
-- the product menu and owns the transfer. Never reselects and never mints
-- another epoch.
---@param versionId string newly selected game version
---@param options { freshImport: boolean?, sourceOffer: userdata?, bootMismatch: string?, importStatus: { state: string?, progress: number?, versionId: string?, displayName: string?, sourceName: string? }?, importReceipt: string? }? private selection mode, default ordinary
function App._continueSelectedVersion(versionId, options)
  local epoch = App.epoch
  local provisioner = assert(App.provisioner, "boot continuation needs the selected provisioner")
  local freshImport = options ~= nil and options.freshImport == true
  -- Detach the single owned presentation before replacing the boot wait:
  -- the old state's disposal must never free transferred art, and the
  -- same selected pair index travels with it to the startup owner.
  local previous = App.state
  local loading = nil
  if previous ~= nil and type(previous.takeLoading) == "function" then
    loading = previous:takeLoading()
  end
  -- The normal App boot path always detaches the live C02 presentation
  -- above; a missing transfer here would silently fall back to a default
  -- inside the state constructor, so fail loudly instead.
  assert(loading ~= nil, "boot continuation needs the transferred loading presentation")
  local width, height = love.graphics.getDimensions()
  local audio = startupAudioBorrow(versionId, epoch)
  App.setState(StartupTitleState.new({
    versionId = versionId,
    epoch = epoch,
    derivedAssets = provisioner:gameHost(),
    width = width,
    height = height,
    initialImport = freshImport,
    loading = loading,
    pairIndex = App.pairIndex,
    audio = audio,
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
    onSwitchEdition = function(otherVersionId)
      if App.epoch == epoch and App.selectedVersionId == versionId then
        App._switchEdition(otherVersionId)
      end
    end,
    onCancel = function()
      if App.epoch == epoch and App.selectedVersionId == versionId then
        App._showVersionSelector()
      end
    end,
    onTitleReady = function()
      App._maybeStartFirstPlayWarmup(versionId, epoch)
    end,
  }))
end

function App.load(opts)
  App.opts = opts or {}
  App.drawableWidth, App.drawableHeight = love.graphics.getDimensions()
  App.pixelRatio = love.graphics.getDPIScale()
  App.importer = nil
  App.provisioner = nil
  App.service = nil
  App.epoch = 0
  App.pendingQuiesce = nil
  App.pairIndex = nil
  App._publishedPairHint = nil
  App._importReceipt = nil
  App._pendingImport = nil
  App.selectedVersionId = nil
  App._swallowedPointers = {}
  App._rebindVersionId = nil
  App._bootBlockedVersionId = nil
  App.importPickerError = nil
  App._startupWarmup = nil
  App.startupWarmupError = nil
  App.startupAudioSession = nil
  App.startupAudioError = nil
  App.setState(nil)
  love.graphics.setBackgroundColor(unpack(WindowConfig.BACKGROUND_COLOR))
  App.saveDir = love.filesystem.getSaveDirectory()

  App._bootExisting()
end

-- Replaces only the UI state. Source ownership is explicit: selection,
-- re-import, selector return and quit retire the session; the
-- bootstrap-state to game handoff must not retire it.
function App.setState(nextState)
  local previous = App.state
  App.state = nextState
  if previous and previous.dispose then
    previous:dispose()
  end
end

function App._startImport(expectedVersionId)
  local function onComplete(versionId)
    App._onImported(versionId)
  end
  App.importer = RomImporter.new({ onComplete = onComplete, expectedVersionId = expectedVersionId })
  -- Capability is a fact for this screen construction, not a persisted
  -- preference: only an actually loadable bridge gets an activation.
  local pickerAvailable = NativeRomPicker.available()
  local importOptions = {
    targetVersion = expectedVersionId,
    pickerAvailable = pickerAvailable,
  }
  if pickerAvailable then
    importOptions.onPick = function()
      local result = NativeRomPicker.openSingle()
      if result.kind == "path" then
        App._beginImportPath(result.path, expectedVersionId)
      elseif result.kind == "error" then
        print("Native file picker failed: " .. tostring(result.message))
      end
    end
  end
  App.setState(ImportState.new(App.importer, App.saveDir, importOptions))
end

function App._switchEdition(versionId)
  assert(GameVersion.VERSIONS[versionId], "unknown edition")
  local ready = readyVersions()
  for _, readyId in ipairs(ready) do
    if readyId == versionId then
      App._selectVersion(versionId)
      return
    end
  end
  if App.importer and App.importer:isBusy() then
    return
  end
  local function showTargetImport()
    App._startImport(versionId)
  end
  if App.service ~= nil and App.selectedVersionId ~= nil then
    App._retireSelection()
    local epoch = App.epoch or 0
    local barrier = App.service:quiesce(epoch)
    if barrier ~= nil then
      App.pendingQuiesce = { epoch = epoch, barrier = barrier }
      App.setState(CachePreparationState.new({
        kind = "quiescence",
        epoch = epoch,
        service = App.service,
        barrier = barrier,
        isCurrent = function(_)
          return App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier == barrier
        end,
        onReady = function()
          App.pendingQuiesce = nil
          if App.service:importSource(epoch, barrier) then
            showTargetImport()
          end
        end,
        onCancel = function()
          App.pendingQuiesce = nil
          App._showVersionSelector()
        end,
      }))
      return
    end
  end
  showTargetImport()
end

function App._beginImportPath(path, expectedVersionId)
  if type(path) ~= "string" or (not path:lower():match("%.nds$") and not path:lower():match("%.zip$")) then
    -- Unsupported picker selection is a handled rejection, not a diagnostic:
    -- the import card stays put with no console noise under normal operation.
    return
  end
  App._beginImportAttempt("path", path, expectedVersionId)
end

-- Open the import card for one picked or dropped file without touching the
-- source: the receipt is latched for its first paint, and validation starts
-- only after that paint (see App.update). Importers offering the queued
-- handoff start in the background then; direct-only importers keep their
-- immediate start contract on this same tick.
---@param kind "drop"|"path"
---@param value unknown dropped File or picked path
---@param expectedVersionId string?
---@param receipt string? sanitized basename latched for the first paint
function App._openImportCard(kind, value, expectedVersionId, receipt)
  local previous = App.importer
  App.importer = nil
  if previous ~= nil and type(previous.cancelQueued) == "function" then
    previous:cancelQueued()
  end
  App._startImport(expectedVersionId)
  -- Acknowledge the file on the same input tick: the first draw already
  -- names the received file, while no source read has run yet.
  App._importReceipt = receipt
  local importer = App.importer
  if importer ~= nil and type(importer.queuePath) == "function" and type(importer.queueDroppedFile) == "function" then
    App._pendingImport = {
      kind = kind,
      value = value,
      receipt = receipt,
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

function App._beginImportAttempt(kind, value, expectedVersionId)
  local currentState = App.state
  if kind == "drop" and currentState ~= nil and type(currentState.onImportAttempt) == "function" then
    currentState:onImportAttempt()
    return
  end
  if App.importer and App.importer:isBusy() then
    return
  end
  local waiting = App.state
  if waiting ~= nil and getmetatable(waiting) == CachePreparationState and waiting.kind == "quiescence" then
    return
  end
  expectedVersionId = expectedVersionId or (currentState and currentState.targetVersion)
  local receipt = App._receiptName(kind, value)
  if App.service ~= nil then
    local wasBootBlocked = currentState ~= nil
      and getmetatable(currentState) == CachePreparationState
      and currentState.kind == "boot-source"
    App._bootBlockedVersionId = wasBootBlocked and App.selectedVersionId or nil
    App._rebindVersionId = App.selectedVersionId
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
        expectedVersionId = expectedVersionId,
        receipt = receipt,
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
        isCurrent = function(_)
          return App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier == barrier
        end,
        onReady = function()
          App.pendingQuiesce = nil
          if App.service:importSource(epoch, barrier) then
            App._openImportCard(kind, value, expectedVersionId, receipt)
          end
        end,
        onCancel = function()
          App.pendingQuiesce = nil
          App._showVersionSelector()
        end,
      }))
      return
    end
  end
  App._openImportCard(kind, value, expectedVersionId, receipt)
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
    return
  end
  local ok = pcall(function()
    if pending.kind == "path" then
      importer:queuePath(pending.value)
    else
      importer:queueDroppedFile(pending.value)
    end
  end)
  if ok then
    pending.started = true
  else
    App._pendingImport = nil
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
---@return string display label for the selected game version
local function selectedVersionLabel(versionId)
  local infoOk, info = pcall(GameVersion.info, versionId)
  if infoOk and type(info) == "table" and type(info.label) == "string" then
    return info.label
  end
  return tostring(versionId)
end

function App._onImported(versionId)
  local importer = App.importer
  -- A completion counts only for the live session: an import that never
  -- completed never selects, releases, or offers. Attempts the shell never
  -- owned keep their historical handoff.
  if importer ~= nil then
    local statusOk, snapshot = pcall(importer.status, importer)
    if not statusOk or type(snapshot) ~= "table" or snapshot.state ~= RomImporter.STATES.COMPLETE then
      return
    end
  end
  App._pendingImport = nil
  -- Take the one verified source handoff before the importer is released.
  -- A dropped or freshly imported ROM carries no reopenable path yet, so
  -- this buffer is what lets the controller admit the selection; the
  -- buffer crosses by reference as a selection option so the offer is
  -- enqueued before the boot gate, including when quiescence defers the
  -- selection behind a pending barrier. Releasing the wrapper never drops
  -- the buffer: the options own the reference until admitted.
  local verifiedSource = nil
  if importer ~= nil and type(importer.takeVerifiedSource) == "function" then
    local takeOk, taken = pcall(importer.takeVerifiedSource, importer)
    if takeOk and taken ~= nil then
      verifiedSource = taken
    end
  end
  App.importer = nil
  -- Freeze the final verified view for the cold fresh-import card and
  -- prefer the live card receipt the import view latched on input.
  local frozenStatus = nil
  if importer ~= nil and type(importer.status) == "function" then
    local statusOk, snapshot = pcall(importer.status, importer)
    if statusOk and type(snapshot) == "table" then
      frozenStatus = {
        state = snapshot.state,
        progress = snapshot.progress,
        versionId = snapshot.versionId,
        displayName = snapshot.displayName,
        sourceName = snapshot.sourceName,
      }
    end
  end
  local receipt = App._importReceipt
  App._importReceipt = nil
  local currentView = App.state
  if currentView ~= nil and type(currentView.receivedName) == "function" then
    receipt = currentView:receivedName() or receipt
  end
  local offeredBytes = nil
  if verifiedSource ~= nil then
    local bytesOk, byteData = pcall(verifiedSource.byteData, verifiedSource)
    if bytesOk and type(byteData) == "userdata" then
      offeredBytes = byteData
    end
    if type(verifiedSource.release) == "function" then
      pcall(verifiedSource.release, verifiedSource)
    end
  end
  -- A blocked boot rebind stays on its expected version: a wrong ROM never
  -- switches the selection, launches another game, or clears current
  -- files. The expected version reselects with the mismatch diagnostic so
  -- the boot wait stays actionable on a fresh epoch.
  local blockedExpected = App._bootBlockedVersionId
  if blockedExpected == nil then
    local current = App.state
    if
      current ~= nil
      and getmetatable(current) == CachePreparationState
      and current.kind == "boot-source"
      and App.selectedVersionId ~= nil
    then
      blockedExpected = App.selectedVersionId
    end
  end
  if blockedExpected ~= nil and versionId ~= blockedExpected then
    App._bootBlockedVersionId = nil
    App._rebindVersionId = nil
    local expectedLabel = selectedVersionLabel(blockedExpected)
    local wrongLabel = selectedVersionLabel(versionId)
    App._selectVersion(blockedExpected, {
      bootMismatch = string.format(
        "Dropped %s does not match the expected %s version (mismatch). Drop the matching .nds or .zip for %s to finish preparing.",
        wrongLabel,
        expectedLabel,
        expectedLabel
      ),
    })
    return
  end
  App._bootBlockedVersionId = nil
  -- A rebind that supplies the same ROM resumes the waiting version on
  -- the ordinary path: its receipts, assets, and saves survive instead of
  -- restarting as a fresh import. A repeated completion for an already
  -- registered version is warm even without that launch-path flag, while
  -- only a genuinely new version takes the fresh-import path.
  local rebindId = App._rebindVersionId
  App._rebindVersionId = nil
  if rebindId ~= nil and versionId == rebindId then
    if offeredBytes ~= nil then
      App._selectVersion(versionId, { sourceOffer = offeredBytes })
    else
      App._selectVersion(versionId)
    end
  elseif alreadyRegistered(versionId) then
    if offeredBytes ~= nil then
      App._selectVersion(versionId, { sourceOffer = offeredBytes })
    else
      App._selectVersion(versionId)
    end
  else
    local selectOptions = {
      freshImport = true,
      importStatus = frozenStatus,
      importReceipt = receipt,
    }
    if offeredBytes ~= nil then
      selectOptions.sourceOffer = offeredBytes
    end
    App._selectVersion(versionId, selectOptions)
  end
end

function App._bootMainMenu(versions)
  assert(type(versions) == "table" and #versions == 1, "Main Menu needs exactly one selected version")
  App._selectVersion(versions[1])
end

function App._bootExisting()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  local remembered = EditionPreference.read()
  for _, versionId in ipairs(ready) do
    if versionId == remembered then
      App._selectVersion(versionId)
      return
    end
  end
  App._selectVersion(ready[1])
end

function App.update(dt)
  App._syncDrawableSize()
  if App.importer and App.importer:isBusy() then
    App.importer:update()
  end
  if App.importer and not App.importer:isBusy() and App.importer.state == RomImporter.STATES.ERROR then
    App.importer = nil
    App._pendingImport = nil
  end
  if App.service then
    App.service:update()
  end
  App._updateStartupWarmup()
  if App.state and App.state.update then
    App.state:update(dt)
  end
  App._startPendingImport()
  local audio = App.startupAudioSession
  if audio ~= nil then
    local ok, failure = pcall(audio.update, audio, dt)
    if not ok then
      App._recordStartupAudioError(failure)
      App._releaseStartupAudio()
    elseif audio.diagnostic ~= nil then
      App._recordStartupAudioError(audio.diagnostic)
    end
  end
end

function App.resize(width, height)
  App.drawableWidth = width
  App.drawableHeight = height
  App.pixelRatio = love.graphics.getDPIScale()
  App._swallowedPointers = {}
  if App.state and App.state.resize then
    App.state:resize(width, height)
  end
end

function App._syncDrawableSize()
  local width, height = love.graphics.getDimensions()
  local pixelRatio = love.graphics.getDPIScale()
  if width == App.drawableWidth and height == App.drawableHeight and pixelRatio == App.pixelRatio then
    return
  end
  App.drawableWidth = width
  App.drawableHeight = height
  App.pixelRatio = pixelRatio
  if App.state and App.state.resize then
    App.state:resize(width, height)
  end
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
  if App.state and App.state.keypressed then
    App.state:keypressed(key, scancode, isrepeat)
    return
  end
  if key == "escape" then
    love.event.quit(0)
  end
end

function App.keyreleased(key, scancode)
  if App.state and App.state.keyreleased then
    App.state:keyreleased(key, scancode)
  end
end

function App.gamepadpressed(joystick, button)
  if App.state and App.state.gamepadpressed then
    App.state:gamepadpressed(joystick, button)
  end
end

function App.gamepadreleased(joystick, button)
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
  if App.state and App.state.mousemoved then
    App.state:mousemoved(x, y, dx, dy, istouch)
  end
end

function App.mousereleased(x, y, button, istouch, presses)
  App._syncDrawableSize()
  local pointerId = "mouse:" .. tostring(button)
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
  if App.state and App.state.touchmoved then
    App.state:touchmoved(id, x, y, dx, dy, pressure)
  end
end

function App.touchreleased(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  local pointerId = "touch:" .. tostring(id)
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
  App._rebindVersionId = nil
  App._bootBlockedVersionId = nil
  if service then
    service:shutdown()
  end
end

return App
