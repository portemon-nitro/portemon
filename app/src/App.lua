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

---@class App
---@field opts AppOptions
---@field state table<string, unknown>|nil
---@field importer RomImporter|nil
---@field provisioner DerivedAssetProvisioner|nil
---@field service CacheService|nil process-owned cache controller service shared by every selection
---@field epoch integer latest borrowed controller epoch, monotonically increasing
---@field pendingQuiesce table<string, integer>|nil unacknowledged source-close barrier for import
---@field selectedVersionId string? currently selected game version
---@field _rebindVersionId string? version a pending raw drop is expected to supply back
---@field _bootBlockedVersionId string? version a blocked boot refuses to switch away from
---@field importPickerError string? latest recoverable picker or preference detail
---@field preferenceError string? last-played preference write diagnostic
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

-- Retires the selected source interest without joining controller work.
-- The process service is reused; stale results cannot publish afterwards.
function App._retireSelection()
  local provisioner = App.provisioner
  App.provisioner = nil
  if provisioner then
    provisioner:dispose()
  end
end

---@param versionId string
local function installMenu(versionId)
  local ok, menuOrError = pcall(MainMenuComposition.new, {
    versionId = versionId,
    width = App.drawableWidth,
    height = App.drawableHeight,
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
    App._showVersionSelector()
    error(menuOrError, 0)
  end
  App.setState(assert(menuOrError))
end

-- Installs the selected-version product menu and starts the one-time
-- speculative work that is useful while it remains open.
---@param versionId string
function App._launchMenuWithProvisioner(versionId)
  local provisioner = assert(App.provisioner, "selection has no provisioner")
  installMenu(versionId)
  local host = provisioner:gameHost()
  host.requestMilestone("new-game-intro", "near")
  host.requestMilestone("field-planning", "near")
  host.requestMilestone("field-runtime", "near")
  host.requestBattlePresentation("near")
  provisioner:startBackgroundWarmup()
end

-- Cancellation restores only the menu state; the current selection and its
-- warmup authorization remain owned by the App.
---@param versionId string
function App._restoreMenuWithProvisioner(versionId)
  assert(App.provisioner, "selection has no provisioner")
  installMenu(versionId)
end

---@param versionId string
---@param entry table<string, unknown>
function App._launchGameWithProvisioner(versionId, entry)
  local provisioner = assert(App.provisioner, "selection has no provisioner")
  local ok, gameOrError = pcall(HgssGame.new, {
    versionId = versionId,
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
---@param options { freshImport: boolean?, importContinuation: table<string, unknown>?, sourceOffer: userdata?, bootMismatch: string? }? private selection mode
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

-- Selects a game version: borrows a controller epoch through its
-- provisioner, hands any verified offered source to the controller, queues
-- the boot readiness gate behind it on the same control stream, and waits
-- through a visible boot-source state. Nothing downstream (menu, retail,
-- first-play preparation, background sweep) runs before the gate answers
-- ready for this exact epoch.
---@param versionId string newly selected game version
---@param options { freshImport: boolean?, importContinuation: table<string, unknown>?, sourceOffer: userdata?, bootMismatch: string? }? private selection mode, default ordinary
function App._selectVersion(versionId, options)
  if App._waitForQuiescence(versionId, options) then
    return
  end
  App.selectedVersionId = versionId
  App._retireSelection()
  local provisioner = DerivedAssetProvisioner.new(provisionerOptions(versionId))
  App.provisioner = provisioner
  App.epoch = assert(provisioner.epoch, "selection borrowed no epoch")
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
  App.setState(CachePreparationState.new({
    kind = "boot-source",
    epoch = epoch,
    service = service,
    versionId = versionId,
    mismatch = mismatch,
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
-- exact selected epoch. Runs the original downstream choice unchanged:
-- the menu immediately when bootstrap is already ready, otherwise a
-- visible bootstrap wait; a registered source with first-play attestation
-- missing or stale routes through the same bounded first-play preparation
-- a fresh import uses. Never reselects and never mints another epoch.
---@param versionId string newly selected game version
---@param options { freshImport: boolean?, importContinuation: table<string, unknown>?, sourceOffer: userdata?, bootMismatch: string? }? private selection mode, default ordinary
function App._continueSelectedVersion(versionId, options)
  local epoch = App.epoch
  local provisioner = assert(App.provisioner, "boot continuation needs the selected provisioner")
  local host = provisioner:gameHost()
  local freshImport = options ~= nil and options.freshImport == true
  if not freshImport and FirstPlayCompletion.isCurrent(versionId, App._firstPlayGeneration(versionId)) then
    local checkOk, ready = pcall(host.requestMilestone, "bootstrap", "required")
    if checkOk and ready then
      App._launchMenuWithProvisioner(versionId)
      return
    end
    -- A pending bootstrap waits visibly; a thrown readiness check is latched
    -- as the preparation state's visible error on its first update.
    App.setState(CachePreparationState.new({
      kind = "bootstrap",
      epoch = epoch,
      provisioner = host,
      isCurrent = function(selected)
        return App.epoch == selected
      end,
      onReady = function()
        App._launchMenuWithProvisioner(versionId)
      end,
      onCancel = function()
        App._showVersionSelector()
      end,
    }))
    return
  end
  -- One provisioner epoch owns the mandatory preparation and the
  -- launched game: no retirement or reselection happens between them.
  -- The fresh-import path always compiles the closure (a new version has
  -- no attestation yet) and carries no gateway; the ordinary path carries
  -- the durable gateway so
  -- preparation fast-transfers once the controller-derived generation
  -- validates a stored attestation instead of recompiling the closure.
  local gateway = nil
  if not freshImport then
    gateway = App._firstPlayGateway(versionId)
  end
  local preparation = HgssGame.newFirstPlayCachePreparation({
    versionId = versionId,
    derivedAssets = host,
    completion = gateway,
  })
  ---@type CachePreparationOptions
  local waitOptions = {
    kind = "first-play",
    epoch = epoch,
    preparation = preparation,
    provisioner = host,
    isCurrent = function(selected)
      return App.epoch == selected
    end,
    onReady = function()
      App._publishFirstPlay(versionId)
      App._launchMenuWithProvisioner(versionId)
    end,
    onCancel = function()
      App._showVersionSelector()
    end,
  }
  -- Only a fresh import carries the captured import display facts: the
  -- ordinary stale-cache wait keeps the generic preparation surface.
  if freshImport and options ~= nil and options.importContinuation ~= nil then
    waitOptions.importContinuation = options.importContinuation
  end
  App.setState(CachePreparationState.new(waitOptions))
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
  App.selectedVersionId = nil
  App._rebindVersionId = nil
  App._bootBlockedVersionId = nil
  App.importPickerError = nil
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
  App.setState(ImportState.new(App.importer, App.saveDir, {
    targetVersion = expectedVersionId,
    pickerError = App.importPickerError,
    onPick = function()
      local result = NativeRomPicker.openSingle()
      if result.kind == "path" then
        App._beginImportPath(result.path, expectedVersionId)
      elseif result.kind == "error" then
        App.importPickerError = result.message
        if App.state and getmetatable(App.state) == ImportState then
          App.state.pickerError = result.message
        end
      end
    end,
    onSwitchEdition = function()
      local target = expectedVersionId == "soulsilver" and "heartgold" or "soulsilver"
      App._switchEdition(target)
    end,
  }))
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
    App.importPickerError = "Choose a file ending in .nds or .zip, or drag and drop a ROM."
    if App.state and getmetatable(App.state) == ImportState then
      App.state.pickerError = App.importPickerError
    end
    return
  end
  App._beginImportAttempt("path", path, expectedVersionId)
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
  local begin = function()
    App._startImport(expectedVersionId)
    if App.importer then
      if kind == "path" then
        App.importer:startPath(value)
      else
        App.importer:filedropped(value)
      end
    end
  end
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
            begin()
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
  begin()
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
  -- Capture the final importer display facts before releasing the
  -- importer: the fresh-import first-play wait renders them as an import
  -- continuation while readiness still owns the transfer. Only immutable
  -- scalar display fields cross the handoff; no live importer is kept.
  local importer = App.importer
  local continuation = nil
  if importer ~= nil then
    local statusOk, status = pcall(importer.status, importer)
    if statusOk and type(status) == "table" then
      local snapshot = {}
      for _, field in ipairs({
        "state",
        "versionId",
        "displayName",
        "sourceName",
        "progress",
        "stage",
        "stageLabel",
        "detail",
      }) do
        snapshot[field] = status[field]
      end
      continuation = { status = snapshot, saveDir = App.saveDir }
    end
  end
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
  -- restarting as a fresh import. Only a genuinely new version takes the
  -- fresh-import first-play path with the import continuation.
  local rebindId = App._rebindVersionId
  App._rebindVersionId = nil
  if rebindId ~= nil and versionId == rebindId then
    if offeredBytes ~= nil then
      App._selectVersion(versionId, { sourceOffer = offeredBytes })
    else
      App._selectVersion(versionId)
    end
  else
    local selectOptions = { freshImport = true, importContinuation = continuation }
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
  end
  if App.service then
    App.service:update()
  end
  if App.state and App.state.update then
    App.state:update(dt)
  end
end

function App.resize(width, height)
  App.drawableWidth = width
  App.drawableHeight = height
  App.pixelRatio = love.graphics.getDPIScale()
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
    return
  end
  if App.opts.dev then
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("portemon", 24, 24)
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
  if App.state and App.state.mousepressed then
    App.state:mousepressed(x, y, button, istouch, presses)
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
  if App.state and App.state.touchpressed then
    App.state:touchpressed(id, x, y, dx, dy, pressure)
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
