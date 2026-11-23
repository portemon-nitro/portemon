-- Normal field-runtime coordinator. It joins generated maps through
-- FieldMapLoader, drives the deterministic elevation-aware player, and
-- exposes the field warp transition lifecycle.

local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local PixelScale = require("libs.ui.src.PixelScale")
local FieldActorDefinitionProvider = require("libs.hgss.src.actors.FieldActorDefinitionProvider")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local PartyAssetPrefetch = require("game.hgss.src.field.PartyAssetPrefetch")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldEntryAssetCache = require("libs.assets.src.field.FieldEntryAssetCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldInteractionResolver = require("libs.hgss.src.interaction.FieldInteractionResolver")
local FieldEventResolver = require("libs.hgss.src.interaction.FieldEventResolver")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldPlayerAvatarState = require("libs.hgss.src.actors.FieldPlayerAvatarState")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local FieldPlayerVisual = require("libs.hgss.src.actors.FieldPlayerVisual")
local FieldZoneIdentity = require("libs.hgss.src.world.FieldZoneIdentity")
local FollowingMonController = require("libs.hgss.src.field.FollowingMonController")
local FollowingMonState = require("libs.hgss.src.save.FollowingMonState")
local GymMechanism = require("libs.hgss.src.field.GymMechanism")
local GymMechanismGeometry = require("libs.hgss.src.field.GymMechanismGeometry")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")
local RocketHideoutEffects = require("libs.hgss.src.field.RocketHideoutEffects")
local GameSave = require("libs.hgss.src.save.GameSave")
local FieldPoison = require("libs.hgss.src.field.FieldPoison")
local FieldPoisonEffect = require("libs.hgss.src.field.FieldPoisonEffect")
local FieldPoisonSave = require("libs.hgss.src.save.FieldPoisonSave")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local SysInfoState = require("libs.hgss.src.save.SysInfoState")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local FieldScriptScreenFade = require("libs.hgss.src.transition.FieldScriptScreenFade")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Personality = require("libs.mons.src.gen4.Personality")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local MartCache = require("libs.assets.src.MartCache")
local MartService = require("libs.hgss.src.items.MartService")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local VanillaMartStock = require("game.hgss.src.mart.VanillaMartStock")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local FieldOverworldLifecycle = require("libs.hgss.src.field.FieldOverworldLifecycle")
local FieldScriptPropAnimations = require("libs.hgss.src.field.FieldScriptPropAnimations")
local AssetNeedsRegistry = require("libs.hgss.src.field.AssetNeedsRegistry")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowStyles = require("libs.hgss.src.field.FieldWindowStyles")
local FieldMapNameBanner = require("libs.hgss.src.ui.FieldMapNameBanner")
local FieldShortcutSlide = require("game.hgss.src.field.FieldShortcutSlide")
local StartMenuRenderer = require("libs.hgss.src.ui.StartMenuRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local NeighborRing = require("libs.hgss.src.presentation.NeighborRing")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
local FollowerInteractionCache = require("libs.assets.src.field.FollowerInteractionCache")
local FieldWeatherResolver = require("libs.hgss.src.world.FieldWeatherResolver")
local DisplayContext = require("libs.ui.src.DisplayContext")
local FieldEntranceIndicatorRuntime = require("game.hgss.src.field.FieldEntranceIndicatorRuntime")
local FieldActorEmoteRuntime = require("game.hgss.src.field.FieldActorEmoteRuntime")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldPixelScale = require("libs.hgss.src.presentation.FieldPixelScale")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")
local FieldSaveCoordinator = require("game.hgss.src.field.FieldSaveCoordinator")
local FieldBattleCoordinator = require("game.hgss.src.field.FieldBattleCoordinator")
local CAMERA_PROFILES_PATH = FieldCameraCache.profilesPath()
local LocalClock = require("game.src.LocalClock")
local RepoFs = require("libs.storage.src.RepoFs")
local WindowConfig = require("game.src.WindowConfig")

local function composeStarterBalls(runtime)
  local StarterLabBallController = require("game.hgss.src.field.StarterLabBallController")
  local function currentScene()
    local current = runtime.session and runtime.session.currentMap or runtime.runtimeMap
    return assert(current and (current.sceneRuntime or current))
  end
  return StarterLabBallController.new({
    eventState = runtime.eventState,
    party = runtime.monService,
    flags = {
      gotTm51 = FieldScriptSymbols.flagsByName.FLAG_GOT_TM51_FROM_FALKNER,
      metPasserbyBoy = FieldScriptSymbols.flagsByName.FLAG_MET_PASSERBY_BOY,
    },
    sceneOf = currentScene,
  })
end

-- Predicted working-set driver (private to this runtime): one soft-demand
-- epoch over the already computed current/near map membership from the
-- residency coordinator and the map loader. It joins published field music,
-- soundplate, and script-audio sequences to audio bank demand through the
-- audio controller; scene and menu images already flow through the existing
-- prefetch, so the driver only leans on it and prunes at epoch commit.
-- Prediction is soft interest: live voices, staged scenes, and borrowed
-- chrome keep hard ownership and may exceed the idle budgets, with the
-- admitted-but-uncovered gap reported by the provider census. The epoch
-- recomputes only when its fingerprint changes (map, coverage, audio
-- override, modal hold, or day/night band) and the script index memo holds
-- a single entry; steady-state updates only adopt ready payloads.
local PredictionDriver = {}
PredictionDriver.__index = PredictionDriver

-- CPU seconds one host update may spend preparing enrolled assets; a single
-- unit of work may overshoot it.
local ASSET_NEEDS_STEP_SECONDS = 0.006

---@class PredictionDriver
---@field epoch integer
---@field tier1 string?
---@field fingerprint string?
---@field scriptIndex table<string, unknown>?|false single-entry published script index memo (false until first load)
---@field new fun(): PredictionDriver
---@field _tier1 fun(self: PredictionDriver, runtime: FieldRuntime): string?
---@field _scriptSymbols fun(self: PredictionDriver, runtime: FieldRuntime, fieldData: table<string, unknown>?): string[]?
---@field _commit fun(self: PredictionDriver, runtime: FieldRuntime, currentId: integer, orderedIds: integer[])
---@field refresh fun(self: PredictionDriver, runtime: FieldRuntime)

---@return PredictionDriver
function PredictionDriver.new()
  return setmetatable({ epoch = 0, tier1 = nil, fingerprint = nil, scriptIndex = false }, PredictionDriver)
end

-- Scalar change signal with no table allocation: current map, effective
-- music, controller round, modal hold, day/night band, and coverage anchor.
---@param runtime FieldRuntime
---@return string?
function PredictionDriver:_tier1(runtime)
  local audio = runtime.audio
  if audio == nil or type(audio.effectiveMusic) ~= "function" then
    return nil
  end
  local currentId = runtime.runtimeMap ~= nil and runtime.runtimeMap.mapId or nil
  if runtime.session ~= nil and runtime.session.currentMap ~= nil then
    currentId = runtime.session.currentMap.mapId
  end
  local effectiveOk, effective = pcall(function()
    return audio:effectiveMusic()
  end)
  local audioEpoch = 0
  if type(audio.predictionEpoch) == "function" then
    local epochOk, epoch = pcall(function()
      return audio:predictionEpoch()
    end)
    if epochOk and type(epoch) == "number" then
      audioEpoch = epoch
    end
  end
  local held = 0
  if runtime.session ~= nil and type(runtime.session.isForegroundHoldActive) == "function" then
    local active = runtime.session:isForegroundHoldActive()
    assert(type(active) == "boolean", "field foreground hold reports a boolean")
    held = active and 1 or 0
  end
  local band = ""
  if type(runtime.mapMusicDayNight) == "function" then
    local bandOk, value = pcall(runtime.mapMusicDayNight)
    if bandOk and type(value) == "string" then
      band = value
    end
  end
  local anchor = ""
  local residency = runtime.residency
  if residency ~= nil and residency.coverage ~= nil then
    anchor = tostring(residency.coverage.anchorX) .. "," .. tostring(residency.coverage.anchorZ)
  end
  if currentId == nil or not effectiveOk then
    return nil
  end
  return table.concat({
    "m" .. tostring(currentId),
    "u" .. tostring(effective),
    "e" .. tostring(audioEpoch),
    "h" .. tostring(held),
    "b" .. band,
    "a" .. anchor,
  }, "|")
end

-- Best-effort transitive script-audio symbols for one field record's script
-- member, through the published script index. The index memo holds a single
-- entry for the runtime lifetime; an unavailable index simply contributes
-- no script banks.
---@param runtime FieldRuntime
---@return table<string, unknown>? index the published script index, nil when unavailable
function PredictionDriver:_scriptIndex(runtime)
  local cacheFs = runtime.cacheFs
  if cacheFs == nil or type(cacheFs.loadLua) ~= "function" then
    return nil
  end
  if self.scriptIndex == false then
    -- The per-member closures live in the active generation's index; the
    -- active selector next to it only names that generation.
    local ok, active = pcall(function()
      local ScriptCache = require("libs.assets.src.ScriptCache")
      return ScriptCache.loadActive(cacheFs)
    end)
    if not ok or type(active) ~= "table" then
      self.scriptIndex = nil
    else
      self.scriptIndex = active.index
    end
  end
  return self.scriptIndex or nil
end

---@param runtime FieldRuntime
---@param fieldData table<string, unknown>?
---@return string[]?
function PredictionDriver:_scriptSymbols(runtime, fieldData)
  local memberId = type(fieldData) == "table" and fieldData.scriptBankId or nil
  if type(memberId) ~= "number" then
    return nil
  end
  if self:_scriptIndex(runtime) == nil then
    return nil
  end
  local ok, closure = pcall(function()
    local ScriptCache = require("libs.assets.src.ScriptCache")
    return ScriptCache.audioSequencesForMember(self.scriptIndex, memberId)
  end)
  if not ok then
    return nil
  end
  return closure --[[@as string[]?]]
end

-- Commits one epoch: current-first/near-second bank admission with all
-- independent banks enrolled before polling, then a predicted-shielded
-- trim and stale-interest cancellation, and one image-pool prune. Near-map
-- failures are isolated per map so they never corrupt the current state.
---@param runtime FieldRuntime
---@param currentId integer
---@param orderedIds integer[] current-first map order
function PredictionDriver:_commit(runtime, currentId, orderedIds)
  local audio = assert(runtime.audio, "prediction commit requires its audio service")
  local residency = runtime.residency
  local currentFieldData
  if residency ~= nil and type(residency.mapForId) == "function" then
    local ok, currentMap = pcall(function()
      return residency:mapForId(currentId)
    end)
    if ok and type(currentMap) == "table" then
      currentFieldData = currentMap.fieldData
    end
  end
  if currentFieldData == nil and runtime.runtimeMap ~= nil then
    currentFieldData = runtime.runtimeMap.fieldData
  end
  local currentBanks = {} ---@type integer[]
  if currentFieldData ~= nil then
    local ok, banks = pcall(function()
      return audio:predictedBanksFor(currentFieldData, self:_scriptSymbols(runtime, currentFieldData))
    end)
    if ok and type(banks) == "table" then
      currentBanks = banks
    end
  end
  local nearBanks = {} ---@type integer[]
  local seenBank = {} ---@type table<integer, boolean>
  for _, bankId in ipairs(currentBanks) do
    seenBank[bankId] = true
  end
  for _, mapId in ipairs(orderedIds) do
    if mapId ~= currentId and residency ~= nil and type(residency.mapForId) == "function" then
      local ok, runtimeMap = pcall(function()
        return residency:mapForId(mapId)
      end)
      local fieldData = ok and type(runtimeMap) == "table" and runtimeMap.fieldData or nil
      if fieldData ~= nil then
        local banksOk, banks = pcall(function()
          return audio:predictedBanksFor(fieldData, nil)
        end)
        if banksOk and type(banks) == "table" then
          for _, bankId in ipairs(banks) do
            if not seenBank[bankId] then
              seenBank[bankId] = true
              nearBanks[#nearBanks + 1] = bankId
            end
          end
        end
      end
    end
  end
  -- Enroll every independent bank before polling: background enrollment
  -- never blocks the update, and the single drain below adopts whatever
  -- completed meanwhile.
  pcall(function()
    audio:prewarmAudioBanks(currentBanks)
  end)
  for _, bankId in ipairs(nearBanks) do
    pcall(function()
      audio:prewarmAudioBanks({ bankId })
    end)
  end
  pcall(function()
    audio:drainBackgroundSamples()
  end)
  -- Current-first keep order for the admission-aware trim, then stale
  -- background interest outside the predicted set is dropped.
  local keep = {} ---@type string[]
  local seenKey = {} ---@type table<string, boolean>
  local function noteKeys(bankId)
    local keysOk, keys = pcall(function()
      return audio:bankSampleKeys(bankId)
    end)
    if keysOk and type(keys) == "table" then
      for _, key in ipairs(keys) do
        if not seenKey[key] then
          seenKey[key] = true
          keep[#keep + 1] = key
        end
      end
    end
  end
  for _, bankId in ipairs(currentBanks) do
    noteKeys(bankId)
  end
  for _, bankId in ipairs(nearBanks) do
    noteKeys(bankId)
  end
  local keepSet = {} ---@type table<string, boolean>
  for _, key in ipairs(keep) do
    keepSet[key] = true
  end
  pcall(function()
    audio:cancelUnpredictedSamples(keepSet)
  end)
  -- Image idle trim lands here at epoch commit, never on draw.
  if runtime.imageAssets ~= nil and type(runtime.imageAssets.prune) == "function" then
    pcall(function()
      runtime.imageAssets:prune()
    end)
  end
  self:_commitAssetNeeds(runtime, currentFieldData)
end

-- The needs of one script member: the published index closure plus the needs
-- of any override-layer resource of that member. A malformed index
-- contributes nothing; the synchronous path raises if it ever needs the asset.
---@param index table<string, unknown> the published script index
---@param memberId integer
---@param overrideNeeds fun(id: string): string[]? needs of an id's override resource, nil when it has none
---@return table<string, true> needs set of `kind:id` keys
local function needsForMember(index, memberId, overrideNeeds)
  local ScriptCache = require("libs.assets.src.ScriptCache")
  local needs = {}
  for _, key in ipairs(ScriptCache.assetNeedsForMember(index, memberId) or {}) do
    needs[key] = true
  end
  if type(index.resources) == "table" then
    for _, entry in ipairs(index.resources) do
      if entry.member == memberId then
        for _, key in ipairs(overrideNeeds(entry.id) or {}) do
          needs[key] = true
        end
      end
    end
  end
  return needs
end

-- Enrolls the assets the current map's scripts need (the published index
-- closure plus any override-layer resource of that script member) with the
-- registry, which prepares them in the background, and drops every other
-- need. Maps without a script member need nothing.
---@param runtime FieldRuntime
---@param fieldData table<string, unknown>?
function PredictionDriver:_commitAssetNeeds(runtime, fieldData)
  local memberId = type(fieldData) == "table" and fieldData.scriptBankId or nil
  local needs = {} ---@type table<string, true>
  if type(memberId) == "number" then
    local index = self:_scriptIndex(runtime)
    if index ~= nil then
      local scriptRegistry = runtime.scripts ~= nil and runtime.scripts.registry or nil
      needs = needsForMember(index, memberId, function(id)
        return scriptRegistry ~= nil and scriptRegistry:overrideAssetNeeds(id) or nil
      end)
    end
  end
  for key in pairs(needs) do
    runtime.assetNeeds:enroll(key)
  end
  runtime.assetNeeds:retain(needs)
end

-- Advances the soft epoch when its fingerprint changed; steady-state
-- updates only adopt ready background payloads. Headless runtimes without
-- a shared preparation worker stay on the synchronous path and skip.
---@param runtime FieldRuntime
function PredictionDriver:refresh(runtime)
  if runtime.assetPreparation == nil then
    return
  end
  local audio = runtime.audio
  local residency = runtime.residency
  if audio == nil or residency == nil then
    return
  end
  if type(audio.predictedBanksFor) ~= "function" then
    return
  end
  local tier1 = self:_tier1(runtime)
  if tier1 == nil then
    return
  end
  if tier1 == self.tier1 then
    if type(audio.drainBackgroundSamples) == "function" then
      audio:drainBackgroundSamples()
    end
    return
  end
  local committed, near, loaderIds = {}, {}, {}
  if type(residency.predictionMembership) == "function" then
    local ok, committedIds, nearIds = pcall(function()
      return residency:predictionMembership()
    end)
    if not ok then
      return
    end
    committed, near = committedIds or {}, nearIds or {}
  end
  local loader = runtime.mapLoader
  if loader ~= nil and type(loader.nearDemandIds) == "function" then
    local ok, ids = pcall(function()
      return loader:nearDemandIds()
    end)
    if ok and type(ids) == "table" then
      loaderIds = ids
    end
  end
  local currentId = runtime.runtimeMap ~= nil and runtime.runtimeMap.mapId or nil
  if runtime.session ~= nil and runtime.session.currentMap ~= nil then
    currentId = runtime.session.currentMap.mapId
  end
  if currentId == nil then
    return
  end
  local ordered, seen = {}, {} ---@type integer[], table<integer, boolean>
  local function note(id)
    if type(id) == "number" and not seen[id] then
      seen[id] = true
      ordered[#ordered + 1] = id
    end
  end
  note(currentId)
  for _, group in ipairs({ near, committed, loaderIds }) do
    for _, id in ipairs(group) do
      if id ~= currentId then
        note(id)
      end
    end
  end
  local union = {} ---@type string[]
  for _, id in ipairs(ordered) do
    union[#union + 1] = tostring(id)
  end
  local fingerprint = tier1 .. "#" .. table.concat(union, ",")
  if fingerprint == self.fingerprint then
    self.tier1 = tier1
    if type(audio.drainBackgroundSamples) == "function" then
      audio:drainBackgroundSamples()
    end
    return
  end
  self.tier1 = tier1
  self.fingerprint = fingerprint
  self.epoch = self.epoch + 1
  self:_commit(runtime, currentId --[[@as integer]], ordered)
end

-- The script party composition: the modal selection surface over the
-- live party. The blocking selection task receives it through scheduler
-- services; no script code requires the concrete host module after this
-- composition step. A missing manifest fails the boot loudly with no
-- half-built host.
---@param runtime FieldRuntime
---@param cacheFs table<string, unknown> CacheFs-shaped
---@return table<string, unknown> the script-owned party selection host
local function buildPartySelectionHost(runtime, cacheFs)
  local PartySelectionHost = require("game.hgss.src.field.PartySelectionHost")
  local PartyCache = require("libs.assets.src.PartyCache")
  local partyOverrides = runtime.presentationOverrides ~= nil and runtime.presentationOverrides.party or nil
  local function measureDisplay()
    return runtime.presentationDisplay
  end
  -- The icon preparation binding belongs to the presentation lifetime
  -- and may postdate this host: resolve it per open, when a screen is
  -- actually constructed, mirroring the application factories.
  local function prepareIcons(iconKeys)
    local binding =
      assert(runtime._partyIconPreparation, "script party selection requires its icon preparation binding")
    return binding.prepare(iconKeys)
  end
  local function cancelIconPreparation()
    local binding =
      assert(runtime._partyIconPreparation, "script party selection requires its icon preparation binding")
    binding.cancel()
  end
  return PartySelectionHost.new({
    service = assert(runtime.monService, "the script party host requires the live mon service"),
    manifest = PartyCache.loadManifest(cacheFs),
    uiManifest = runtime.uiManifest,
    measureDisplay = measureDisplay,
    overrides = partyOverrides,
    prepareIcons = prepareIcons,
    cancelIconPreparation = cancelIconPreparation,
  })
end

---@class FieldRuntimeOptions
---@field fieldScaleConfig table<string, unknown>?
---@field viewportWidth integer?
---@field viewportHeight integer?
---@field screenTopology ScreenTopology?
---@field displayContext DisplayContext? shared actual-display measurement owner (defaults to a runtime-owned context)
---@field displayGraphics table<string, unknown>? graphics namespace for the default display context
---@field presentationOverrides table<string, table<string, unknown>>? product-root per-case function overrides by application
---@field martStockResolver (fun(descriptor: table<string, unknown>, context: table<string, unknown>, catalog: table<string, unknown>): table<string, unknown>)? game-root mart stock policy
---@field overrideFs table<string, unknown>? read-shaped repository filesystem override
---@field presentation boolean?
---@field preparedEntry table<string, unknown>? one-shot staged New Game transfer; the runtime claims its loader and queue
---@field scriptHosts table<string, unknown>? deterministic host boundaries for script effects
---@field dayNight (fun(): string)? deterministic day/night source for the field-music policy
---@field audioOutput table<string, unknown>? { audio: table<string, unknown>, sound: table<string, unknown> } audio-output host namespaces for the LÖVE sink (defaults to love.audio + love.sound)
---@field audioPreferences table<string, function>? borrowed app-wide volume port (never serialized)
---@field derivedAssets table<string, function>? semantic derived-asset host
---@field cacheFs table<string, unknown> selected epoch's installed generated view
---@field assetRuntime { cacheFs: table<string, unknown>, decoded: table<string, unknown>, preparationQueue: table<string, unknown> } borrowed selected CPU runtime
---@field localClock LocalClock? injectable host-local civil-time boundary
---@field weatherClock table<string, unknown>? injectable host boundary { today()->{month,day}, hasPenalty()->boolean }
---@field saveStore FieldRuntimeSaveStore? global publication owner

---@class FieldRuntimeScriptHosts
---@field fieldAudio table<string, unknown>? field map audio policy test adapter
---@field audio table<string, unknown>?
---@field camera table<string, unknown>?
---@field screen table<string, unknown>?
---@field events table<string, unknown>?

---@class FieldRuntimeSaveStore
---@field save fun(self: FieldRuntimeSaveStore, record: table<string, unknown>)
---@field publishFirst fun(self: FieldRuntimeSaveStore, record: table<string, unknown>)

---@class FieldRuntime
---@field versionId string
---@field overrideFs table<string, unknown> read-shaped repository filesystem
---@field saveId string
---@field game table<string, unknown> finalized unpublished game or normalized loaded GameSave
---@field viewportWidth integer
---@field viewportHeight integer
---@field screenTopology ScreenTopology?
---@field fieldPixelScale FieldPixelScale
---@field saveStatus string?
---@field saveStore FieldRuntimeSaveStore? global publication owner
---@field savePublished boolean whether the reserved record has been published
---@field saveCoordinator FieldSaveCoordinator required save capture/publication owner
---@field worldSwapCoordinator FieldWorldSwapCoordinator required staged transition/world owner
---@field menuComposer FieldMenuCompositionCoordinator required menu/presentation composition owner
---@field playerData table<string, unknown> the validated profile/options authority (PlayerData shape)
---@field avatar table<string, unknown> the gender-selected compiled avatar capability
---@field playerAvatar FieldPlayerAvatarState? the one avatar transition owner
---@field monCatalog MonCatalog the immutable domain mon catalog behind the live party
---@field itemCatalog ItemCatalog the shared item catalog behind mon and later Bag composition
---@field monLanguage string the semantic language key the mon catalog was built for
---@field monService HgssMonService the live party/creation/script mon service
---@field _partyPrefetchRevision integer? last warmed party revision, nil before the first warmup
---@field _partyPrefetchCooldown number? seconds until a deferred party warmup retries, failing closed at zero
---@field fashionCase FashionCaseState live accessory inventory restored from the save
---@field sysInfo SysInfoState live system-info state (mystery-gift flag) restored from the save
---@field followerInteractionCatalog table<string, unknown> generated follower interaction rules
---@field followerReactionTicks table<string, integer> follower reaction emote kind -> emote action duration
---@field bagService HgssBagService the live bag/inventory service
---@field martService MartService the live mart inventory/session service
---@field martHost table<string, unknown> the one script-owned mart child host
---@field kurtBoxHost table<string, unknown> the one script-owned Kurt selector host
---@field moneyBox FieldMoneyBox? the transient source money window the field draw renders
---@field apricornTreePresentation table<string, function>? presentation assets invalidation owner
---@field martStockResolver function the selected mart stock provider
---@field battleCoordinator FieldBattleCoordinator concrete owner of the battle lifetime
---@field pendingEncounterId integer|nil prepared unconsumed encounter identity
---@field pendingEncounter table<string, unknown>? prepared unconsumed encounter
---@field _trainerCatalog table<string, unknown>? composed immutable trainer template catalog (nil before composition)
---@field _trainerFactory table<string, unknown>? composed native trainer party materializer (nil before composition)
---@field trainerEncounter TrainerEncounterCoordinator? the source trainer engagement owner (nil before composition)
---@field _encounterCatalog table<string, unknown>? composed immutable encounter table catalog (nil before composition)
---@field _battleHost table<string, unknown>? narrow battle host for script battle tasks
---@field roamerState table<string, unknown>? the owned roamer and encounter persistence
---@field pendingWarpForm string? the source form of the warp currently starting (nil for an ordinary warp)
---@field pokedexCatalog table<string, unknown>? the borrowed generated dex catalog behind knowledge (nil after teardown)
---@field dexKnowledge table<string, unknown>? the owned dex knowledge
---@field gameStats table<string, unknown>? the owned game-stats owner
---@field pokegearState table<string, unknown> the owned companion state, calendar checkpoint, and persisted draw seeds
---@field pokegearRandom table<string, unknown>? the live companion draw pair (nil after teardown)
---@field pokegearCalendar table<string, unknown>? the companion-local civil calendar adapter (nil after teardown)
---@field pokegearManifest table<string, unknown>? the compiled companion family (nil after teardown)
---@field pokegearCatalog table<string, unknown>? the borrowed compiled contact catalog (nil after teardown)
---@field pokegear table<string, unknown>? the composed companion feature bundle (nil after teardown)
---@field pokegearApplications table<string, unknown>? the companion script host the feature composes (nil after teardown)
---@field incomingCalls table<string, unknown>? the owned ambient incoming-call coordinator (nil after teardown)
---@field playerDataContext table<string, unknown>? the generated charmap and frame-index context behind player validation
---@field bagCursor BagCursor the runtime-only field bag cursor
---@field partyMenu table<string, unknown>? the owned menu composition (nil before composition / after teardown)
---@field menuLaneWarps table<string, unknown>? the long-lived menu-origin warp service (nil before composition / after teardown)
---@field followingMon FollowingMonController|nil the one derived follower controller (nil after teardown)
---@field celebiTimeTravelScene table<string, unknown>|nil runtime-owned headless Celebi cutscene state
---@field hoOhAppearanceScene table<string, unknown>? runtime-owned Bell Tower cutscene state
---@field followingMonTransition FollowingMonTransitionController|nil the one transient follower-transition owner (nil after teardown)
---@field followerTransitionDefinition table<string, unknown>? the compiled follower-transition definition behind the transient owner
---@field starterBalls table<string, unknown>? the Elm starter-ball runtime-prop controller (nil after teardown)
---@field session FieldSession
---@field overworld FieldOverworldLifecycle
---@field propAnimations FieldScriptPropAnimations
---@field actors FieldActorManager
---@field actorAssets FieldActorAssets
---@field dialogue FieldDialogueController?
---@field signpost FieldSignpostController the fixed-tick signpost controller (script-owned via ScriptSignpostHost)
---@field auxiliaryFieldUi AuxiliaryFieldUi?
---@field contextChoiceProvider ContextChoiceProvider?
---@field starterProvider table<string, unknown> the hand-editable default starter roster, injected into the starter task
---@field starterChoice StarterChoiceState? the modal starter-choice surface the blocking task opens and closes
---@field partySelection table<string, unknown>? the modal script-party surface the blocking selection task opens and closes
---@field monNaming MonNamingState the script-owned Pokemon Naming Screen host
---@field menuHost FieldMenuHost?
---@field yesNoHost FieldYesNoHost? the live choice presentation host shared by the session, the script dialogue host, and field draw
---@field actionKeys table<string, boolean>?
---@field cancelKeys table<string, boolean>?
---@field menuKeys table<string, boolean>?
---@field presentation boolean
---@field windowStyles FieldWindowStyles the immutable per-runtime window style catalogue
---@field fontDef table<string, unknown> the generated field font and charmap
---@field fieldEntryManifest FieldEntryAssetCache.Manifest the compiled map-name banner skins, palettes, and eligibility
---@field mapNameBanner FieldMapNameBanner? the transient area-name banner controller (nil after teardown)
---@field shortcutSlide FieldShortcutSlide? the closed-menu shortcut cluster's slide (nil after teardown)
---@field scriptHosts FieldRuntimeScriptHosts?
---@field transitionPanel "exit"|"enter"|nil
---@field applications FieldApplicationRegistry the immutable per-runtime destination application catalogue
---@field applicationHost FieldApplicationHost the one application modal owner the session steps
---@field pcApplicationHost PcApplicationHost the one script-owned PC child host
---@field pcTerminal table<string, unknown> source PC query and prop-effect owner
---@field displayContext DisplayContext the actual-display measurement owner (shared or runtime-owned)
---@field presentationDisplay DisplayMeasurement? the complete measured display rendering and menu input share
---@field _displayTopology ScreenTopology? the latest resize topology tracked by the default display context
---@field presentationOverrides table<string, table<string, unknown>>? product-root per-case function overrides by application
---@field dayNight fun(): string?
---@field audioOutput table<string, unknown>?
---@field audioPreferences table<string, function>? borrowed app-wide volume port for the Options factory
---@field optionsPresentationFactory (fun(): FieldPresentationResources.OptionsPresentationPort)? field-lifetime per-open options presentation factory, installed by the presented state and absent in headless runtimes
---@field derivedAssets table<string, function>?
---@field audio FieldAudioController? production-composed audio service (absent when only a recording script adapter is injected, without an audio-output host)
---@field mapMusicDayNight (fun(): string)? production-composed day/night band source for the map-music lookup (present whenever the production composition exists)
---@field assetNeeds AssetNeedsRegistry the script-declared asset preparation registry
---@field audioSink LoveAudioSink? production-composed LÖVE output sink (absent without an audio-output host)
---@field audioComposition table<string, unknown>? field-owned audio composition (sink plus voices plus provider)
---@field acquireSource fun(reference: ResidentCache.BlobRef): table<string, unknown>? resident source acquirer of the borrowed selected runtime
---@field screenFade FieldScriptScreenFade the production semantic script screen-fade controller (fade_screen/wait_fade); always composed, advanced once after each field tick
---@field scentTint FieldScentTint the Honey/Sweet Scent screen tint; always composed, advanced once after each field tick
---@field fishingHost FieldFishingHost the fishing rod host seam and its pose and "!" mark; always composed
---@field localClock LocalClock the shared host-local civil-time boundary
---@field weatherClock table<string, unknown> injectable host boundary { today()->{month,day}, hasPenalty()->boolean }
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field fieldEntranceIndicatorAsset table<string, unknown>
---@field fieldEffectAssets table<string, unknown>
---@field pokemonCenterHeal PokemonCenterHealFlow? source-owned Pokémon Center choreography
---@field blackoutFlow FieldBlackoutFlow? runtime-owned whiteout presentation and recovery flow
---@field fieldPoison FieldPoison? the overworld poison step counter behind field damage ticks
---@field poisonEffect FieldPoisonEffect? the retail HBlank wobble behind damage ticks; always composed, advanced once per source frame
---@field poisonCure { slots: integer[], index: integer }? pending cure-message chain behind a survive tick
---@field pokemonCenterHealDefinition table<string, unknown>? generated healing-ball asset definition
---@field physicalCoverage FieldCoverage?
---@field residency FieldResidencyCoordinator?
---@field assetPreparation AssetPreparationQueue borrowed selected preparation queue
---@field decoded table<string, unknown> borrowed selected decoded CPU owner
---@field _predictionDriver table<string, unknown>? soft current/near working-set epoch owner
---@field imageAssets ImageAssetPool? presentation-only session image owner borrowed by every field scene (nil when headless)
local FieldRuntime = {}
FieldRuntime.__index = FieldRuntime

-- The world catalog's matrix member of one outdoor logical map: structural
-- membership, available before (and without) visual realization. Shared by boot
-- composition and the covered transition's destination staging.
---@param runtime FieldRuntime
---@param logicalMap table<string, unknown>
---@return integer
local function mapMatrixMemberId(runtime, logicalMap)
  local world = runtime.mapLoader.world
  local mapIndex = assert(world.byId[logicalMap.mapId], "outdoor map catalog record is required")
  local mapRecord = assert(world.maps[mapIndex], "outdoor map catalog record is missing")
  return assert(mapRecord.matrix.memberId, "outdoor map matrix member is required")
end

---@class FieldRuntimePhysicalSwap
---@field coverage FieldCoverage? the finished window: nil while a covered transition is still staging it
---@field replacement boolean
---@field previous FieldCoverage?
---@field state "staging"|"prepared"|"committed"|"released"
---@field task table<string, unknown>? staged construction task, present only while `state` is `staging`
---@field matrixMemberId integer? destination matrix identity of a staged window
---@field anchorX integer? destination anchor cell of a staged window
---@field anchorZ integer? destination anchor cell of a staged window

---@param avatars table[]
local function validateAvatarConfig(avatars)
  assert(type(avatars) == "table" and #avatars > 0, "field actor index must contain avatars")
  local genders = {}
  for _, avatar in ipairs(avatars) do
    assert(type(avatar) == "table", "field actor avatar metadata must be a table")
    assert(type(avatar.id) == "string" and avatar.id ~= "", "field actor avatar id must be a non-empty string")
    assert(type(avatar.states) == "table", "field actor avatar states must be a visual-state map")
    assert(
      type(avatar.states.walking) == "number" and avatar.states.walking >= 0 and avatar.states.walking % 1 == 0,
      "field actor avatar walking state must be a compiled spriteId"
    )
    for state, spriteId in pairs(avatar.states) do
      assert(
        type(state) == "string" and type(spriteId) == "number" and spriteId >= 0 and spriteId % 1 == 0,
        "field actor avatar states must map visual states to compiled spriteIds"
      )
    end
    assert(PlayerData.GENDERS[avatar.gender] == true, "field actor avatar gender is unsupported")
    assert(genders[avatar.gender] == nil, "field actor index contains duplicate playable avatar genders")
    genders[avatar.gender] = true
  end
  for gender in pairs(PlayerData.GENDERS) do
    assert(genders[gender] == true, "field actor index has no avatar for player gender " .. gender)
  end
end

---@param avatars table[]
---@param gender integer
---@return table<string, unknown>
local function avatarForGender(avatars, gender)
  assert(PlayerData.GENDERS[gender] == true, "field player gender is unsupported")
  local match
  for _, avatar in ipairs(avatars) do
    if avatar.gender == gender then
      assert(match == nil, "compiled avatars contain duplicate playable gender")
      match = avatar
    end
  end
  return assert(match, "compiled avatars have no entry for player gender " .. gender)
end

-- The one actor lookup shared by movement collision and interaction
-- discovery: live occupancy for any map the actor manager holds (active or
-- frozen neighbor), and a read-only source event probe for any other logical
-- map, resident or preflight. The probe never publishes an actor map or
-- acquires an actor visual.
---@param mapId integer
---@param candidate FieldOccupancyCandidate
---@return FieldActorManager.Actor|FieldActorManager.ProbeResult|nil
function FieldRuntime:_actorAt(mapId, candidate)
  if self.actors:holdsMap(mapId) then
    return self.actors:getAt(mapId, candidate)
  end
  local residency = assert(self.residency, "inactive actor lookup requires logical residency")
  local runtimeMap = residency:mapForId(mapId) or residency:mapForPreflight(mapId)
  return self.actors:probeAt(runtimeMap, self.eventState, candidate)
end

---@param candidate FieldOccupancyCandidate
---@return string?
function FieldRuntime:_playerOccupantAt(candidate)
  local currentMap = self.runtimeMap
  local coverage = currentMap.coverage
  local targetMapId = currentMap.mapId
  if coverage then
    targetMapId = FieldZoneIdentity.logicalZoneAt(coverage, candidate.fieldX, candidate.fieldZ, currentMap.mapId)
      or currentMap.mapId
  end
  local occupant
  if self.actors:holdsMap(targetMapId) then
    occupant = self.actors:getCollisionAt(targetMapId, candidate)
  else
    occupant = self:_actorAt(targetMapId, candidate)
  end
  return occupant and occupant.actorId or nil
end

local function playerOccupancy(self)
  local function occupancy(candidate)
    return self:_playerOccupantAt(candidate)
  end
  return occupancy
end

-- The spawn surface at a declared spawn tile: the topmost walkable terrain
-- surface at the point, exactly the no-hint arrival rule of scripted warp
-- resolution (WarpSystem.directSurface). The historic nearest-world-Y-zero
-- choice served only the deleted (0,0) synthesis and selected the wrong floor
-- on vertically stacked maps.
local function spawnSurface(runtimeMap, localX, localZ)
  local x = localX + FieldCoordinates.TILE_CENTER_OFFSET
  local z = localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local best
  for _, plate in ipairs(runtimeMap.terrain:candidatesAt(x, z)) do
    local sample = runtimeMap.terrain:sample(plate.id, x, z)
    if best == nil or sample.worldY > best.worldY then
      best = sample
    end
  end
  assert(best, string.format("spawn tile (%d,%d) has no walkable terrain surface", localX, localZ))
  return best
end

-- Compose the current logical context with the session-owned physical world.
-- Cached loader entries remain logical-only; this view is disposable and never
-- releases either collaborator.
local function composePhysicalMap(logicalMap, coverage)
  if not coverage then
    return logicalMap
  end
  local runtimeMap = {}
  for key, value in pairs(logicalMap) do
    runtimeMap[key] = value
  end
  runtimeMap.logicalMap = logicalMap
  runtimeMap.coverage = coverage
  function runtimeMap.release() end
  function runtimeMap.probePhysicalCell(_, fieldX, fieldZ, context)
    return coverage:probe(fieldX, fieldZ, context)
  end
  function runtimeMap.projectPhysicalPoint(_, fieldX, fieldZ, cellKey, sourceSurfaceId)
    return coverage:project(fieldX, fieldZ, cellKey, sourceSurfaceId)
  end
  function runtimeMap.updateAnimated()
    coverage:updateAnimated()
  end
  function runtimeMap.syncPhysicalFields()
    runtimeMap.fieldRegion = coverage.region
    runtimeMap.collision = coverage.region.collision
    runtimeMap.terrain = coverage.region.terrain
    runtimeMap.terrainDependencyHash = coverage.terrainDependencyHash
    runtimeMap.coordinateOrigin = { x = coverage.origin.x, z = coverage.origin.z }
    runtimeMap.physicalOrigin = coverage.origin
    -- The composed terrain and permission owners were just replaced: a runtime
    -- projection the field installed over them re-installs over these.
    if runtimeMap.reprojectFieldGeometry ~= nil then
      runtimeMap.reprojectFieldGeometry()
    end
  end
  runtimeMap:syncPhysicalFields()
  return runtimeMap
end

---@param localClock LocalClock
---@return table<string, unknown>
local function defaultWeatherClock(localClock)
  local function today()
    local now = localClock:nowLocal()
    return { month = now.month, day = now.day }
  end
  local function hasPenalty()
    return false
  end
  return {
    today = today,
    hasPenalty = hasPenalty,
  }
end

local function closestSurface(runtimeMap, localX, localZ, savedY)
  local best
  local bestDistance
  for _, plate in
    ipairs(
      runtimeMap.terrain:candidatesAt(
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    )
  do
    local sample = runtimeMap.terrain:sample(
      plate.id,
      localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ + FieldCoordinates.TILE_CENTER_OFFSET
    )
    local distance = math.abs(sample.worldY - savedY)
    if best == nil or distance < bestDistance then
      best, bestDistance = sample, distance
    end
  end
  return assert(best, "saved coordinate has no walkable terrain surface")
end

-- An outdoor destination map loads with no collision/terrain at all until
-- physical coverage composes over it (FieldMapLoader splits outdoor scenes
-- this way so a bare load never pays for a physical window the caller might
-- discard). `composeMap` is a no-op for non-outdoor scenes, so this runs
-- unconditionally; every FieldCoordinates/terrain lookup below runs only
-- after the composed map is in hand.
---@param game table<string, unknown>
---@param mapLoader FieldMapLoader
---@param composeMap fun(logicalMap: RuntimeFieldMap, position: { fieldX: integer, fieldZ: integer }): RuntimeFieldMap
---@return RuntimeFieldMap, { fieldX: integer, fieldZ: integer, surfaceId: integer, facing: FieldDirection, worldY: number }
local function loadGameLocation(game, mapLoader, composeMap)
  if game.schema == GameSave.SCHEMA then
    local runtimeMap = mapLoader:load(game.mapId)
    runtimeMap = composeMap(runtimeMap, { fieldX = game.fieldX, fieldZ = game.fieldZ })
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, game.fieldX, game.fieldZ)
    local surface
    if
      game.terrainDependencyHash == runtimeMap.terrainDependencyHash
      and runtimeMap.terrain:contains(
        game.surfaceId,
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    then
      surface = runtimeMap.terrain:sample(
        game.surfaceId,
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    else
      surface = closestSurface(runtimeMap, localX, localZ, game.worldY)
    end
    return runtimeMap,
      {
        fieldX = game.fieldX,
        fieldZ = game.fieldZ,
        surfaceId = surface.surfaceId,
        facing = game.facing,
        worldY = surface.worldY,
      }
  end

  assert(type(game.location) == "table", "finalized game location is required")
  local runtimeMap = mapLoader:load(game.location.mapSymbol)
  -- The global position is plain origin arithmetic (no collision lookup),
  -- so it is always safe to compute before composing physical coverage.
  local fieldX = runtimeMap.coordinateOrigin.x + game.location.fieldX
  local fieldZ = runtimeMap.coordinateOrigin.z + game.location.fieldZ
  runtimeMap = composeMap(runtimeMap, { fieldX = fieldX, fieldZ = fieldZ })
  -- Composing may have replaced coordinateOrigin with the physical window's
  -- own origin; re-derive local coordinates against it rather than reusing
  -- game.location's pre-compose local coordinates.
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  local surface = spawnSurface(runtimeMap, localX, localZ)
  return runtimeMap,
    {
      fieldX = fieldX,
      fieldZ = fieldZ,
      surfaceId = surface.surfaceId,
      facing = game.location.facing,
      worldY = surface.worldY,
    }
end

-- Acquires the runtime map loader, its preparation worker, and the session
-- image owner. A prepared New Game entry moves its already-staged loader,
-- queue, and image owner in before the initial map acquisition, so the
-- first load hits the resident bedroom instead of rebuilding it. Without
-- one, presentation mode owns one asset-preparation worker and one image
-- pool for the runtime lifetime (a headless runtime leaves both nil and
-- starts no thread); both are built before the map loader so scene loading
-- can route mesh CPU work and texture ownership through them. Kept outside
-- the asset-loading phase to keep that closure under the upvalue limit.
---@param runtime FieldRuntime
---@param cacheFs table<string, unknown>
---@param world table<string, unknown>
---@param loadOptions FieldRuntimeOptions?
---@return FieldMapLoader mapLoader
---@return table<string, unknown> assetPreparation
---@return ImageAssetPool? imageAssets
---@return table<string, unknown> decoded
local function acquireMapLoader(runtime, cacheFs, world, loadOptions)
  assert(loadOptions and loadOptions.assetRuntime, "the field runtime requires the selected CPU runtime")
  local assetRuntime = loadOptions.assetRuntime
  assert(assetRuntime.cacheFs == cacheFs, "the field runtime requires the selected runtime over its generated view")
  local preparedTransfer = loadOptions.preparedEntry
  if preparedTransfer ~= nil then
    local opening = assert(runtime.game.location, "a prepared field entry requires a finalized new-game location")
    local claimed = preparedTransfer:claim({ versionId = runtime.versionId, mapSymbol = opening.mapSymbol })
    return assert(claimed.mapLoader, "a prepared field entry carries its loader"),
      assert(claimed.assetPreparation, "a prepared field entry carries its queue"),
      claimed.imageAssets,
      assert(claimed.decoded, "a prepared field entry carries its decoded owner")
  end
  local queue = assetRuntime.preparationQueue
  local decoded = assetRuntime.decoded
  local imageAssets
  if runtime.presentation then
    -- The session image owner borrows the selected queue and decoded owner:
    -- one presented session realizes GPU images, never a second CPU owner.
    imageAssets = ImageAssetPool.new(cacheFs, { queue = queue, decoded = decoded })
  end
  local function acquireResidentSource(reference)
    return queue:acquireSource(reference)
  end
  local loader = FieldMapLoader.new(cacheFs, world, {
    sceneLoader = runtime.presentation and MapSceneLoader or nil,
    neighborLoader = runtime.presentation and NeighborRing or nil,
    assetPreparation = queue,
    decoded = decoded,
    acquireSource = acquireResidentSource,
    imageAssets = imageAssets,
    derivedAssets = runtime.derivedAssets,
  })
  return loader, queue, imageAssets, decoded
end

-- The six `_load` boot phases below are ordinary FieldRuntime methods rather
-- than nested closures inside one function: nesting them once pushed the
-- shared boot-scoped locals (cacheFs, fontDef, composeCurrentMap, ...) close
-- to LuaJIT's 60-upvalue-per-function limit. Each phase instead takes a
-- `boot` table holding those boot-scoped values explicitly.

-- Trusted published cache inputs are loaded before any field owner is published.
-- Whole-payload validation stays with the producer pipeline and explicit audit.
---@param boot table<string, unknown>
---@param loadOptions FieldRuntimeOptions?
function FieldRuntime:_loadRuntimeAssets(boot, loadOptions)
  boot.cacheFs = assert(
    loadOptions ~= nil and loadOptions.cacheFs,
    "the field runtime requires the selected epoch's installed generated view"
  )
  self.cacheFs = boot.cacheFs
  -- The compiled actor index carries the runtime-facing actor configuration
  -- (avatars + variable-sprite policy); a missing runtime block is a stale
  -- or foreign cache and fails the boot loudly.
  local actorIndex = assert(
    boot.cacheFs:loadLua(FieldActorCache.indexPath()),
    "field actor index missing -- run `scripts/buildcache.sh` first"
  )
  assert(
    actorIndex.runtime and actorIndex.runtime.avatars and actorIndex.runtime.variableSprites,
    "field actor index has no runtime configuration"
  )
  self.actorConfig = actorIndex.runtime
  validateAvatarConfig(self.actorConfig.avatars)
  -- The player-data validation context: the generated field font charmap
  -- and the imported dialogue frame-index set, loaded once and injected
  -- into fresh-session construction and the save store (the same pattern
  -- as the compiled avatar set). The field-UI class is a required runtime
  -- asset: its manifest is the authority for which frame indexes resolve.
  boot.fontDef = FieldFontLoader.load(boot.cacheFs)
  self.fontDef = boot.fontDef
  boot.uiManifest = assert(
    boot.cacheFs:loadLua(FieldUiAssetCache.manifestPath()),
    "field UI cache is cold -- run `scripts/buildcache.sh` first"
  )
  assert(
    type(boot.uiManifest) == "table" and boot.uiManifest.schema == FieldUiAssetCache.SCHEMA,
    "field UI manifest is invalid"
  )
  -- The window-style catalogue is composed per runtime from the generated
  -- manifest: the production-owned built-in styles, immutable from then on.
  self.windowStyles = FieldWindowStyles.new(boot.uiManifest)
  self.uiManifest = boot.uiManifest
  -- The compiled field-entry class carries the map-name banner skins, their
  -- text palettes, and the strict map-to-style eligibility projection the
  -- transient area-name banner consumes.
  self.fieldEntryManifest = FieldEntryAssetCache.loadManifest(boot.cacheFs)
  local frameIndexes = {}
  for frame = 0, boot.uiManifest.dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  boot.playerDataContext = {
    charmap = boot.fontDef.charmap,
    frameIndexes = frameIndexes,
  }
  self.playerDataContext = boot.playerDataContext
  boot.world =
    assert(boot.cacheFs:loadLua(MapAssetCache.worldPath()), "world.lua missing -- run `scripts/buildcache.sh` first")
  local profiles = assert(
    boot.cacheFs:loadLua(CAMERA_PROFILES_PATH),
    "field camera cache is cold -- run `scripts/buildcache.sh` first"
  )
  assert(profiles.schema == FieldCameraCache.SCHEMA, "unsupported field camera cache")
  self.cameraProfiles = profiles.profiles

  -- The weather catalog (fog presets and ordered override rules) and the
  -- follower interaction catalog are trusted published artifacts: presence
  -- through the ready cache path is sufficient, and the producer pipeline
  -- plus explicit audit own whole-catalog validation.
  local weatherCatalog = assert(
    boot.cacheFs:loadLua(FieldWeatherCache.catalogPath()),
    "field weather cache is cold -- run `scripts/buildcache.sh` first"
  ) --[[@as FieldWeatherCache.Catalog]]
  self.weatherCatalog = weatherCatalog
  local followerInteractionCatalog = assert(
    boot.cacheFs:loadLua(FollowerInteractionCache.catalogPath()),
    "follower interaction catalog is missing -- run `scripts/buildcache.sh` first"
  )
  self.followerInteractionCatalog = followerInteractionCatalog
  -- The mon catalog behind the live party: loaded once per runtime
  -- through the ready cache path, before service construction.
  -- The shared item catalog loads beside it and is retained
  -- for later Bag composition. Screens and scripts borrow the service,
  -- never the catalogs directly.
  local monRoot = MonCache.loadCatalog(boot.cacheFs)
  self.itemCatalog = ItemCatalog.new(ItemCache.loadCatalog(boot.cacheFs))
  self.martCatalog = MartCache.loadCatalog(boot.cacheFs)
  self.monCatalog = MonCatalog.new(monRoot, self.itemCatalog)
  self.monLanguage = monRoot.version.language
  boot.monRoot = monRoot
  self.fieldEntranceIndicatorAsset, self.fieldEntranceIndicator = FieldEntranceIndicatorRuntime.load(boot.cacheFs)
  self.fieldEmoteModels, self.followerReactionTicks =
    FieldActorEmoteRuntime.load(boot.cacheFs, self.fieldEntranceIndicatorAsset.effects)
  self.fieldEffectAssets = self.fieldEntranceIndicatorAsset
  local terrainEffects = {
    tall_grass = self.fieldEntranceIndicatorAsset.effects.tall_grass,
    very_tall_grass = self.fieldEntranceIndicatorAsset.effects.very_tall_grass,
    trainer_reveal = self.fieldEntranceIndicatorAsset.effects.trainer_reveal,
  }
  self.fieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController").new({
    effects = terrainEffects,
    modelFactory = require("libs.hgss.src.presentation.FieldTerrainEffectModelFactory").new(),
  })

  -- A prepared New Game entry moves its already-staged loader, queue, and
  -- image owner in before the initial map acquisition, so the first load
  -- hits the resident bedroom instead of rebuilding it. Without one,
  -- presentation mode owns one asset-preparation worker and one session
  -- image owner for the runtime lifetime (a headless runtime leaves both
  -- nil and starts no thread); they are constructed before the map loader
  -- so scene loading can route mesh CPU work and texture ownership
  -- through them.
  self.mapLoader, self.assetPreparation, self.imageAssets, self.decoded =
    acquireMapLoader(self, boot.cacheFs, boot.world, loadOptions)
  -- The borrowable form of the selected runtime's source boundary: every
  -- compact runtime reader of this field (audio, messages, collision) borrows
  -- resident bytes through it.
  local preparation = assert(self.assetPreparation, "the field runtime requires the selected preparation queue")
  local function acquireSource(reference)
    return preparation:acquireSource(reference)
  end
  self.acquireSource = acquireSource

  -- Structural outdoor check: matrix membership comes from the world
  -- catalog and holds before (and without) visual realization.
  local function hasMatrixMembership(mapId)
    local byId = self.mapLoader.world.byId
    local maps = self.mapLoader.world.maps
    if type(byId) ~= "table" or type(maps) ~= "table" then
      return false
    end
    local mapIndex = byId[mapId]
    local mapRecord = type(mapIndex) == "number" and maps[mapIndex] or nil
    return type(mapRecord) == "table" and type(mapRecord.matrix) == "table"
  end

  -- Initial boot has no live source owner to protect. It is the only path
  -- allowed to publish a newly created initial coverage.
  local function initialMap(logicalMap, position)
    if logicalMap.scene.type ~= "outdoor" then
      return logicalMap
    end
    assert(not self.physicalCoverage, "initial physical coverage already exists")
    self.physicalCoverage = self.mapLoader:createPhysicalCoverage(logicalMap, position)
    return composePhysicalMap(logicalMap, self.physicalCoverage)
  end
  boot.composeInitialMap = initialMap

  -- Logical zone changes reuse the committed owner. A matrix mismatch here
  -- indicates that a logical seam was routed through the wrong boundary.
  -- Outdoor-ness is structural matrix membership, not visual readiness:
  -- a scene-less outdoor halo still gets the shared physical window so
  -- permission, projection, and camera math keep working.
  local function currentMap(logicalMap, coverage)
    if not hasMatrixMembership(logicalMap.mapId) then
      return logicalMap
    end
    coverage = coverage or assert(self.physicalCoverage, "current outdoor coverage is required")
    assert(
      mapMatrixMemberId(self, logicalMap) == coverage.matrixMemberId,
      "logical outdoor map does not belong to the current physical matrix"
    )
    return composePhysicalMap(logicalMap, coverage)
  end
  boot.composeCurrentMap = currentMap

  -- A live warp receives an explicit ownership record. The replacement is
  -- transition-owned until commit and never mutates physicalCoverage here.
  local function preparedMap(logicalMap, position)
    if logicalMap.scene.type ~= "outdoor" then
      return logicalMap, nil
    end
    local matrixMemberId = mapMatrixMemberId(self, logicalMap)
    local physical = self:_stagePhysicalCoverage(logicalMap, position, matrixMemberId)
    local ok, runtimeMap = pcall(composePhysicalMap, logicalMap, physical.coverage)
    if not ok then
      if physical.replacement then
        physical.coverage:release()
        physical.state = "released"
      end
      error(runtimeMap, 0)
    end
    return runtimeMap, physical
  end
  boot.composePreparedMap = preparedMap
end

-- Restore the entry record and establish the initial map, player, and actor owners.
---@param boot table<string, unknown>
function FieldRuntime:_loadInitialWorld(boot)
  -- A loaded game arrives normalized through the save store, so the runtime
  -- trusts its envelope and restores each nested domain directly. Only a
  -- finalized new game still validates, through the player-data owner.
  local entryGame
  if self.game.schema == GameSave.SCHEMA then
    entryGame = self.game
    assert(entryGame.versionId == self.versionId, "loaded game belongs to another version")
  else
    assert(self.game.playerData, "finalized game player data is required")
    local validPlayerData, playerDataErr = PlayerData.validate(self.game.playerData, boot.playerDataContext)
    assert(validPlayerData, "finalized game player data is invalid: " .. tostring(playerDataErr))
    self.game.playerData = validPlayerData
  end
  boot.loadedGame = entryGame
  boot.activeGame = entryGame or self.game
  self.savePublished = entryGame ~= nil
  -- The gym mechanism union and the follower inhibit bit are saved owners: a
  -- Continue restores the settled union here, and the dynamic terrain plate it
  -- implies is projected over the loaded map before the entry position is
  -- sampled, so a settled lift's height is the first height the player holds.
  -- A saved record always carries both buckets (v14 is strict); a finalized
  -- new-game candidate that carries neither starts from the same initial
  -- owners NewGame composes.
  local function entryBucket(name)
    if entryGame ~= nil then
      return assert(boot.activeGame[name], "a saved game carries its " .. name .. " bucket")
    end
    return boot.activeGame[name]
  end
  self.gymMechanismState = GymMechanismState.restore(entryBucket("gymmick"))
  self.followingMonState = FollowingMonState.restore(entryBucket("followingMon"))
  self.gymMechanismGeometry = GymMechanismGeometry.new()
  local composeInitialMap = boot.composeInitialMap
  local function composeAndDecorateInitialMap(logicalMap, position)
    local runtimeMap = composeInitialMap(logicalMap, position)
    local mechanismState = self.gymMechanismState
    self.gymMechanismGeometry:restoreViolet(
      mechanismState:kind() == GymMechanismState.VIOLET and mechanismState:violetRaised() or false
    )
    self.gymMechanismGeometry:setBlackthornPlatforms(
      mechanismState:kind() == GymMechanismState.BLACKTHORN and mechanismState:blackthornPlatforms() or nil
    )
    self.gymMechanismGeometry:bindMap(runtimeMap)
    return runtimeMap
  end
  self.runtimeMap, self.entryLocation = loadGameLocation(boot.activeGame, self.mapLoader, composeAndDecorateInitialMap)
  self.mapLoader:protectMap(self.runtimeMap.mapId, true)

  self.playerData = boot.activeGame.playerData
  self.fieldTravel =
    FieldTravelState.new(assert(boot.activeGame.fieldTravel, "field travel state is required to enter the field"))
  self.fashionCase =
    FashionCaseState.new(assert(boot.activeGame.fashionCase, "Fashion Case state is required to enter the field"))
  local fieldX, fieldZ = self.entryLocation.fieldX, self.entryLocation.fieldZ
  local surfaceId, facing = self.entryLocation.surfaceId, self.entryLocation.facing
  self.player = FieldPlayer.new({
    currentMap = self.runtimeMap,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    facing = facing,
    occupancy = playerOccupancy(self),
  })
  self.input = FieldInput.new()
  local worldPoint = self.player:renderPosition()

  local profile = assert(
    self.cameraProfiles[self.runtimeMap.cameraType],
    "field camera cache has no camera type " .. self.runtimeMap.cameraType
  )
  self.camera = FieldCamera.new(profile, { initialTarget = worldPoint })
  local width, height = self.viewportWidth, self.viewportHeight
  self.viewport = FieldViewport.new(width, height, { mode = "expanded" })
  self:_updateCameraProjection()
  local restoredWorld = entryGame and entryGame.world
  boot.restoredAudio = entryGame and entryGame.audio
  self.restoredAudio = boot.restoredAudio
  self.eventState = entryGame and FieldEventState.new({ flags = restoredWorld.flags, vars = restoredWorld.variables })
    or self.game.worldState
  assert(self.eventState and self.eventState.serialize, "finalized game event state is required")
  boot.initialActorRestore = entryGame and restoredWorld.objects or nil
  boot.initialActorRestoreMapId = entryGame and entryGame.mapId or nil
  self.actorAssets = FieldActorDefinitionProvider.new(boot.cacheFs)
  self.actors = FieldActorManager.new({
    assets = self.actorAssets,
    policy = { variableSprites = self.actorConfig.variableSprites },
  })

  -- The player's graphic is one more compiled actor visual: FieldPlayer
  -- keeps every bit of movement authority while the avatar transition owner
  -- selects which compiled visual presents it. Dynamic residency stays with
  -- FieldState; the simulation side holds no fixed avatar asset.
  self.avatar = avatarForGender(self.actorConfig.avatars, self.playerData.profile.gender)
  local initialAvatarState = "walking"
  if entryGame and entryGame.avatar then
    initialAvatarState = entryGame.avatar.state
  end
  self.playerAvatar = FieldPlayerAvatarState.new({
    capability = self.avatar,
    surfPresentation = self.fieldEffectAssets.effects.surf_attachment.presentation,
    initialState = initialAvatarState,
  })
  self.playerVisual = FieldPlayerVisual.new({
    player = self.player,
    spriteId = self.playerAvatar:currentSpriteId(),
    playerAvatar = self.playerAvatar,
  })

  -- Warp resolution is owned by WarpSystem through FieldTransition's
  -- default resolver: ordinary records follow the indexed path; scripted
  -- `direct` records carry global destination coordinates and resolve
  -- through their own branch. Fallible destination preparation runs before
  -- the commit, so a failed warp never touches current-map ownership.
  -- Door identity is semantic: the owning physical cell (outdoor) or the
  -- map's canonical resolver (indoor) answers with generated sound and
  -- role state whether or not presentation instances are attached.
  -- Headless and presentation production resolve semantic doors through
  -- that same owner; a live instance never falls back to semantic-only
  -- timing when generated roles exist.
end

-- Install the transition boundary while the runtime still owns boot rollback.
---@param boot table<string, unknown>
function FieldRuntime:_composeTransitions(boot)
  local doorAt
  local escalatorAt
  if self.presentation or self.runtimeMap.sceneRuntime or self.runtimeMap.scene then
    local function resolveDoorAt(runtimeMap, doorFieldX, doorFieldZ)
      -- A scene-less logical map carries no placements or collision:
      -- door identity is unknowable, so the warp resolves no door and
      -- the transition raises its unresolved-door failure rather than
      -- degrading to a plain fade or a synthetic open sound. Door-kind
      -- warps gate on source visual readiness before choreography, so
      -- this backstop only fires for hostless loaders.
      if runtimeMap.scene == nil and runtimeMap.sceneRuntime == nil then
        return nil
      end
      -- Outdoor maps resolve through the committed physical cell that
      -- owns the trigger coordinate; the cell's semantic resolver
      -- carries the generated sound and role state with or without
      -- live presentation instances.
      if runtimeMap.coverage then
        return runtimeMap.coverage:doorAt(runtimeMap, doorFieldX, doorFieldZ)
      end
      -- A bare outdoor load (the realized source visual a scene-less
      -- resident is replaced with before choreography) carries its
      -- scene but no composed coverage. It still resolves through the
      -- runtime-owned committed coverage, which owns the same canonical
      -- cells the composed path would have used; no semantic census is
      -- built here, the owning cell answers. Indoor maps never take
      -- this branch: without coverage they keep their map/scene owner.
      local scene = runtimeMap.scene
      if scene and scene.type == "outdoor" and self.physicalCoverage then
        return self.physicalCoverage:doorAt(runtimeMap, doorFieldX, doorFieldZ)
      end
      if runtimeMap.mapProps then
        return runtimeMap.mapProps:doorAt(runtimeMap, doorFieldX, doorFieldZ)
      end
      local sceneRuntime = runtimeMap.sceneRuntime
      if sceneRuntime and sceneRuntime.mapProps then
        return sceneRuntime.mapProps:doorAt(runtimeMap, doorFieldX, doorFieldZ)
      end
      return nil
    end
    local function resolveEscalatorAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
      if runtimeMap.scene == nil and runtimeMap.sceneRuntime == nil then
        return nil
      end
      if runtimeMap.coverage then
        return runtimeMap.coverage:propAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
      end
      -- Same bare-outdoor-load ownership as door lookup: the
      -- runtime-owned committed coverage answers through the owning
      -- cell's semantic resolver.
      local scene = runtimeMap.scene
      if scene and scene.type == "outdoor" and self.physicalCoverage then
        return self.physicalCoverage:propAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
      end
      if runtimeMap.mapProps then
        return runtimeMap.mapProps:propAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
      end
      local sceneRuntime = runtimeMap.sceneRuntime
      if sceneRuntime and sceneRuntime.mapProps then
        return sceneRuntime.mapProps:propAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
      end
      return nil
    end
    doorAt = resolveDoorAt
    escalatorAt = resolveEscalatorAt
  end
  self.transition = self.worldSwapCoordinator:createTransition(
    self,
    doorAt,
    escalatorAt,
    function(_, sourceMap, warp, dynamicWarp, plan)
      local physical
      local ok, result = pcall(function()
        -- The plan is this destination's one arrival decision: resolution reads
        -- the runtime through the identity the warp record named and composes
        -- the destination window from those same coordinates, so no second
        -- walk of the destination warp can disagree with it.
        local function loadDestination(_, selector)
          return self.mapLoader:load(selector)
        end
        local function composeDestination(_, logicalMap, position)
          local composed, ownership = boot.composePreparedMap(logicalMap, position)
          physical = ownership
          return composed
        end
        return WarpSystem.resolveDestination({
          load = loadDestination,
          compose = composeDestination,
        }, sourceMap, warp, dynamicWarp, plan)
      end)
      if not ok then
        if physical and physical.replacement and physical.state == "prepared" then
          physical.coverage:release()
          physical.state = "released"
        end
        error(result, 0)
      end
      result.physical = physical
      return result
    end
  )
  self.transition.player = self.player
  self.transition.suppression = nil

  -- The production script screen-fade controller (fade_screen/wait_fade):
  -- composed unconditionally so every supported field script has it,
  -- regardless of presentation mode or scriptHosts injection. Rendering
  -- only reads its status().
  self.screenFade = FieldScriptScreenFade.new()
  self.scentTint = require("libs.hgss.src.transition.FieldScentTint").new()
  self.fishingHost = require("game.hgss.src.field.FieldFishingHost").new(self)
  -- The poison wobble composes unconditionally beside the other
  -- presentation-only source-frame effects; ticks start it, the
  -- source-frame pump advances it, and the field draw consumes it.
  self.poisonEffect = FieldPoisonEffect.new()

  -- Modal dialogue is pure and fixed-tick. Runtime layout needs only the
  -- compiled font definition; presentation later owns the atlas and drawing.
  -- The text-speed cadence is captured from the player options at
  -- construction, so an open request never queries options afterwards.
end

-- Compose the fixed-tick presentation and application hosts.
---@param boot table<string, unknown>
function FieldRuntime:_composeFieldUi(boot)
  -- Modal hosts compose beside the menu composition they serve; the
  -- callbacks below keep root-owned audio/menu/field-action policy behind
  -- the root while the coordinator owns the construction algorithm.
  local function buildAudio(cacheFs, restoredAudio)
    return self:_composeAudio(cacheFs, restoredAudio)
  end
  local function menuFactory(rememberedActionId)
    return self:_composeStartMenu(rememberedActionId)
  end
  local function fieldAction(actionId, request)
    return self:_admitFieldAction(actionId, request)
  end
  self.menuComposer:composeModalHosts(boot, {
    buildAudio = buildAudio,
    menuFactory = menuFactory,
    fieldAction = fieldAction,
  })
  -- Interaction discovery: the resolver is pure and consults the same
  -- live-or-probe actor lookup movement collision uses, so both agree about
  -- objects on a logical map that is not the active actor map; bound
  -- interactions run through the script client and the binding audit
  -- guarantees every interactable event is bound.
  self.messageProvider = FieldMessageProvider.new(boot.cacheFs, { acquireSource = self.acquireSource })
  -- Pin the Start Menu label bank for the field-runtime lifetime so menu
  -- composition stays deterministic and I/O-free after a successful boot.
  -- A missing bank fails the boot with the provider's typed error.
  local startMenuBank = require("libs.assets.src.MenuProtocol").START_MENU_MESSAGE_BANK
  local _, startMenuBankErr = self.messageProvider:acquireBank(startMenuBank)
  if startMenuBankErr ~= nil then
    error(startMenuBankErr, 0)
  end
  -- Pin the native section-name bank beside the Start Menu label bank: the
  -- transient area-name banner resolves one section label per request through
  -- this single held lease for the field lifetime, and the compiled manifest
  -- supplies style eligibility. A missing bank fails the boot with the
  -- provider's typed error.
  local SECTION_NAME_MESSAGE_BANK = 279
  local _, sectionNameBankErr = self.messageProvider:acquireBank(SECTION_NAME_MESSAGE_BANK)
  if sectionNameBankErr ~= nil then
    error(sectionNameBankErr, 0)
  end
  local function resolveSectionTitle(mapSectionNativeId)
    local template, titleErr = self.messageProvider:get(SECTION_NAME_MESSAGE_BANK, mapSectionNativeId)
    if template == nil then
      error(titleErr, 0)
    end
    return template.text
  end
  self.mapNameBanner = FieldMapNameBanner.new({
    styleByMapId = self.fieldEntryManifest.bannerStyleByMapId,
    resolveTitle = resolveSectionTitle,
  })
  -- The closed-menu shortcut cluster rests against the screen's right edge,
  -- so sliding it its own width hides it.
  self.shortcutSlide =
    FieldShortcutSlide.new(StartMenuRenderer.shortcutBounds(self.uiManifest.startMenu).width --[[@as integer]])
  local function actorAt(mapId, candidate)
    return self:_actorAt(mapId, candidate)
  end
  local function targetMapAt(x, z, currentMap)
    local coverage = currentMap.coverage
    if not coverage then
      return currentMap
    end
    local targetMapId = FieldZoneIdentity.logicalZoneAt(coverage, x, z, currentMap.mapId) or currentMap.mapId
    if targetMapId == currentMap.mapId then
      return currentMap
    end
    local targetMap = assert(self.residency):mapForId(targetMapId)
    return assert(targetMap, "reachable interaction target is not resident")
  end
  self.interactionResolver = FieldInteractionResolver.new({
    actorAt = actorAt,
    targetMapAt = targetMapAt,
    eventState = self.eventState,
  })

  -- The production audio composition lives in _composeAudio, keeping its
  -- module collaborators out of this already large UI-composition phase
  -- near LuaJIT's 60-upvalue-per-function limit.
  -- The field-script platform (the script override system): registry over
  -- the compiled cache + data/scripts/overrides, composition, mechanical
  -- bindings, scheduler, and interaction client. A resumed save reattaches
  -- its script bucket.
  -- The override files live in the repo tree outside the LÖVE source dir,
  -- so the loader reads them through the io-backed repo filesystem.
  -- The live mon service: constructed once per runtime from the
  -- canonical bucket (the normalized continue record, or the unpublished
  -- new-game bucket) and the HGSS player/version policy. A failed
  -- restore propagates before any field state publishes. The met
  -- location resolves from the active map and the met date from the
  -- host clock at creation time.
end

-- Bind the live mon, Bag, follower, and script services.
---@param boot table<string, unknown>
function FieldRuntime:_composeFieldServices(boot)
  local monBucket = boot.loadedGame and boot.loadedGame.mons
    or assert(self.game.mons, "finalized game mons bucket is required")
  local function monMetMapSection()
    local currentMap = self.session and self.session.currentMap or self.runtimeMap
    local nativeId = currentMap and currentMap.mapSectionNativeId or nil
    assert(
      type(nativeId) == "number" and nativeId % 1 == 0 and nativeId >= 0,
      "mon met location requires the active native map section"
    )
    return nativeId
  end
  local function monMetDate()
    local now = self.localClock:nowLocal()
    return { year = now.year, month = now.month, day = now.day }
  end
  self:_composePokedex(
    boot.loadedGame,
    assert(boot.monRoot, "mon catalog root is required for dex knowledge"),
    boot.cacheFs
  )
  self:_composeGameStats(boot.loadedGame, assert(boot.monRoot, "mon catalog root is required for game stats"))
  self:_composeEasyChat(boot.loadedGame, boot.cacheFs)
  self.monService = HgssMonService.new({
    catalog = self.monCatalog,
    bucket = monBucket,
    profile = self.playerData.profile,
    game = self.versionId,
    language = self.monLanguage,
    charmap = boot.fontDef.charmap,
    mapSection = monMetMapSection,
    date = monMetDate,
    dex = assert(self.dexKnowledge, "field runtime composes dex knowledge before the mon service"),
    stats = assert(self.gameStats, "field runtime composes game stats before the mon service"),
  })
  -- The field Pokémon picture window (452/453) borrows the generated portrait
  -- family and publishes its sighting through the one dex owner.
  self:_composeMonPictureWindow(boot.cacheFs)
  self.sysInfo = SysInfoState.new(
    boot.loadedGame and boot.loadedGame.sysInfo
      or assert(boot.activeGame.sysInfo, "finalized game sysInfo bucket is required")
  )
  self.mailbox = Mailbox.new(
    boot.loadedGame and boot.loadedGame.mailbox
      or assert(boot.activeGame.mailbox, "finalized game mailbox bucket is required"),
    { catalog = self.monCatalog, charmap = boot.fontDef.charmap }
  )
  self.photoAlbum = PhotoAlbum.new(
    boot.loadedGame and boot.loadedGame.photoAlbum
      or assert(boot.activeGame.photoAlbum, "finalized game photo album bucket is required")
  )
  -- The overworld poison step phase restores from the loaded bucket and
  -- falls back to the finalized game (pre-poison saves resume on phase
  -- zero through the same default the finalized record carries).
  self.fieldPoison = FieldPoison.restore(
    FieldPoisonSave.restore(
      boot.loadedGame and boot.loadedGame.fieldPoison
        or assert(boot.activeGame.fieldPoison, "finalized game field poison bucket is required")
    )
  )
  self:_composePokegear(boot.loadedGame, boot.cacheFs)
  self:_composePokegearFeature(boot)
  self:_composeBag(boot.activeGame, boot.loadedGame)
  -- Encounter and trainer data load once during boot from the same cache:
  -- a missing or invalid payload fails the boot instead of leaving
  -- the battle owners absent. The roamer owner reads the source roamer graph
  -- from the same compiled catalog the encounter service consumes.
  local compiledEncounters = BattleDataCache.loadEncounters(boot.cacheFs)
  self:_composeBattleState(
    boot.loadedGame,
    assert(boot.monRoot, "mon catalog root is required for battle state"),
    boot.world,
    compiledEncounters
  )
  self:composeEncounters(compiledEncounters)
  self:composeTrainers(BattleDataCache.loadTrainers(boot.cacheFs))
  local martBucket = boot.loadedGame and boot.loadedGame.mart
    or assert(self.game.mart, "finalized game mart bucket is required")
  self.martService = MartService.new({
    profile = self.playerData.profile,
    bag = self.bagService,
    itemCatalog = self.itemCatalog,
    catalog = self.martCatalog,
    bucket = martBucket,
  })
  self:_composeMart(boot)
  self:_processApricornDate()
  -- The one following-mon controller: derived follower presentation over
  -- the live party, driven once per fixed tick after the session update.
  -- The player accessor tracks warp rebinds, so the controller never holds
  -- a stale player across map swaps. The map accessor reads the live
  -- session map first (the exact metadata behind the actor/player map)
  -- and falls back to the loader's resident logical maps; it never
  -- reaches producer data.
  local function currentPlayer()
    return self.player
  end
  local function currentMap(mapId)
    local current = self.session and self.session.currentMap or self.runtimeMap
    if current and current.mapId == mapId then
      return current
    end
    return self.mapLoader:get(mapId)
  end
  -- The mechanism reads the session player once it resumes and the boot
  -- player before the first map binds, so its own lookup stays separate
  -- from the follower's map-only player view.
  local function currentMechanismPlayer()
    return self.session ~= nil and self.session.player or self.player
  end
  local function currentForegroundScriptId()
    return self.scripts ~= nil and self.scripts.scheduler:foregroundScriptId() or nil
  end
  -- The candle commands read the source script environment's
  -- engaged-trainer attribute. The trainer engagement owner is composed
  -- after this mechanism, so the attribute reads the live owner on demand.
  local function engagedTrainerActor()
    local engagement = self.trainerEncounter
    return engagement ~= nil and engagement:engagedActor() or nil
  end
  -- The one follower-transition owner: composed before the following-mon
  -- controller so the controller can hold it as its required
  -- recall-transition collaborator.
  self:_composeFollowerTransition(boot.cacheFs)
  self.followingMon = FollowingMonController.new({
    service = self.monService,
    catalog = self.monCatalog,
    actors = self.actors,
    playerOf = currentPlayer,
    mapOf = currentMap,
    transition = self.followingMonTransition,
    inhibitState = self.followingMonState,
  })
  self.gymMechanism = GymMechanism.new({
    state = self.gymMechanismState,
    geometry = self.gymMechanismGeometry,
    playerOf = currentMechanismPlayer,
    actors = self.actors,
    followingMon = self.followingMon,
    audio = self.audio or (self.scriptHosts and self.scriptHosts.audio),
    camera = self.camera,
    foregroundScript = currentForegroundScriptId,
    trainerEngagement = { engagedActor = engagedTrainerActor },
  })
  -- The initial map's own union decides which runtime-loaded source props the
  -- mechanism presents, exactly like the source map init loading them.
  self.gymMechanism:bindMap(self.runtimeMap)
  -- The Rocket hideout's own effects: the trap and alarm animations those
  -- scripts block on, and the powered-prop projection its map init asks for.
  -- The owner reads the live map, player and world store, so a warp never leaves
  -- it with a stale anchor and its map event key writes land in the executing
  -- script's own variable store. The script platform is composed after this
  -- owner, so the world facade resolves it on each call instead of capturing it.
  local function scriptsWorldState()
    assert(self.scripts ~= nil, "the Rocket hideout effects need the script platform")
    return assert(self.scripts.worldState, "the Rocket hideout effects need the world store")
  end
  -- The hideout owner calls its world facade with method syntax, so these
  -- take the facade as their own discarded receiver.
  local function isWorldFlagSet(_, id)
    return scriptsWorldState():isFlagSet(id)
  end
  local function setWorldVariable(_, id, value)
    return scriptsWorldState():setVar(id, value)
  end
  local rocketWorld = {
    isFlagSet = isWorldFlagSet,
    setVar = setWorldVariable,
  }
  local function currentRuntimeMap()
    return self.session ~= nil and self.session.currentMap or self.runtimeMap
  end
  self.rocketHideoutEffects = RocketHideoutEffects.new({
    playerOf = currentMechanismPlayer,
    runtimeMapOf = currentRuntimeMap,
    -- The effect owner plays every trap and alarm sound itself, so it needs the
    -- source audio host the field composes or its recording script adapter.
    audio = assert(
      self.audio or (self.scriptHosts and self.scriptHosts.audio),
      "the Rocket hideout effects need the source audio host"
    ),
    world = rocketWorld,
    mapEventKeyVariableBase = assert(
      FieldScriptSymbols.variablesByName.VAR_UNK_4036,
      "the map event key variable identity is required"
    ),
    electrodeFlagBase = assert(
      FieldScriptSymbols.flagsByName.FLAG_UNK_96B,
      "the powered prop flag identity is required"
    ),
    foregroundScript = currentForegroundScriptId,
  })
  self.rocketHideoutEffects:bindMap()
  -- The source legendary-story scenes: the wing effect with its own looping
  -- clips and map child, Lance's departure, the Sinjoh Unown circle and egg
  -- cutscenes, and the Arceus montage. One owner per live field; a scene only
  -- presents the generated definitions the field-effect bundle published, and
  -- a missing one faults before the scene claims anything.
  local LegendEventScene = require("libs.hgss.src.field.LegendEventScene")
  local function currentScriptBankId()
    local runtimeMap = self.session ~= nil and self.session.currentMap or self.runtimeMap
    local fieldData = runtimeMap ~= nil and runtimeMap.fieldData or nil
    local bankId = type(fieldData) == "table" and fieldData.scriptBankId or nil
    return type(bankId) == "number" and bankId or nil
  end
  local effectDefinitions = assert(
    self.fieldEffectAssets and self.fieldEffectAssets.effects,
    "the legendary-story scenes require the generated field-effect bundle"
  )
  self.legendEventScene = LegendEventScene.new({
    definitions = effectDefinitions,
    audio = assert(self.audio or (self.scriptHosts and self.scriptHosts.audio), "the legend scenes need the source audio host"),
    screen = self.screenFade,
    actors = self.actors,
    playerOf = currentMechanismPlayer,
    foregroundScript = currentForegroundScriptId,
    currentScriptBankId = currentScriptBankId,
  })
  self.starterBalls = composeStarterBalls(self)
  self.partySelection = buildPartySelectionHost(self, boot.cacheFs)
  self:_composePartyMenu(boot.cacheFs)
  local ApricornBoxHost = require("game.hgss.src.apricorn.ApricornBoxHost")
  self.kurtBoxHost = ApricornBoxHost.new({
    makeApricornBox = assert(
      self.partyMenu.makeApricornBox,
      "Kurt selector uses the composed source Apricorn Box factory"
    ),
    service = self.martService,
    bag = self.bagService,
  })
  local PcApplicationHost = require("game.hgss.src.pc.PcApplicationHost")
  local function createStorage(request)
    return self.partyMenu.makeStorageChild(assert(request.mode, "Storage mode required"))
  end
  local function createMailbox()
    return self.partyMenu.makeMailboxChild()
  end
  local function createPhotoAlbum()
    return self.partyMenu.makePhotoAlbumChild()
  end
  self.pcApplicationHost = PcApplicationHost.new({
    createStorage = createStorage,
    createMailbox = createMailbox,
    createPhotoAlbum = createPhotoAlbum,
  })
  local PcTerminal = require("game.hgss.src.pc.PcTerminal")
  local function resolveTerminalProp(propRef)
    return self:_resolvePcTerminalProp(propRef)
  end
  self.pcTerminal = PcTerminal.new({
    mailbox = self.mailbox,
    photoAlbum = self.photoAlbum,
    sourcePolicy = self.partyMenu.pcManifest.terminal,
    resolveTerminalProp = resolveTerminalProp,
  })
  self:_composePokemonCenterHeal(boot.audioService)
  -- The one script-owned word editor child host, composed beside the PC
  -- host: the task owns the source lifecycle, this host owns only the
  -- single child, its readiness, and its result lease.
  local EasyChatScriptHost = require("game.hgss.src.easychat.EasyChatScriptHost")
  self.easyChatScriptHost = EasyChatScriptHost.new({ runtime = self })
  -- The one trainer engagement owner: source sight, the two engagement slots,
  -- their approaches, and the trainer-script queries. Composed before the
  -- script platform so the standard trainer scene resolves it as its service.
  local TrainerEncounterCoordinator = require("game.hgss.src.field.TrainerEncounterCoordinator")
  local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
  local function currentPlayerFacing()
    return self.player
  end
  local function currentTrainerMap()
    return self.session ~= nil and self.session.currentMap or self.runtimeMap
  end
  local function sessionTick()
    return self.session ~= nil and self.session.tick or 0
  end
  local function currentTrainerCatalog()
    return self._trainerCatalog
  end
  local function trainerWorldState()
    local scripts = self.scripts
    assert(scripts ~= nil, "trainer engagement needs the script platform")
    return scripts.worldState
  end
  local function startTrainerScene(scriptId)
    if self.scripts == nil then
      return false
    end
    return self.scripts.client:startSceneScript(scriptId, sessionTick()) ~= nil
  end
  local function trainerScriptActive()
    return self.scripts ~= nil and self.scripts.scheduler:foregroundEnvironmentId() ~= nil
  end
  local function trainerBattleActive()
    return self.battleCoordinator ~= nil
      and (self.battleCoordinator:activeBattle() ~= nil or self.battleCoordinator:hasLaunch())
  end
  local function trainerDoublesEligible()
    return self.monService:countAliveMons() >= 2
  end
  -- The source checks trainer sight from the field's own input frame: map
  -- entry, transitions, a held field, and any script ownership all precede
  -- the check, so none of them may start an engagement.
  local function trainerFieldReady()
    if self.session == nil then
      return false
    end
    if self.transition == nil or self.transition.phase ~= FieldTransition.PHASES.idle then
      return false
    end
    local entry = self.session.mapEntryController
    if entry ~= nil and entry:isActive() then
      return false
    end
    if self.scripts ~= nil and self.scripts.scheduler:playerInputOwned() then
      return false
    end
    return true
  end
  local function currentTrainerRegion()
    local map = currentTrainerMap()
    local region = map ~= nil and map.fieldData ~= nil and map.fieldData.region or nil
    assert(type(region) == "string", "the live map carries its native region")
    return region == "KANTO" and "kanto" or "johto"
  end
  local function currentTerrainEffects()
    return self.fieldTerrainEffectController
  end
  self.trainerEncounter = TrainerEncounterCoordinator.new({
    actors = self.actors,
    catalog = currentTrainerCatalog,
    playerOf = currentPlayerFacing,
    currentMap = currentTrainerMap,
    world = trainerWorldState,
    startScene = startTrainerScene,
    scriptActive = trainerScriptActive,
    battleActive = trainerBattleActive,
    doublesEligible = trainerDoublesEligible,
    fieldReady = trainerFieldReady,
    region = currentTrainerRegion,
    effects = currentTerrainEffects,
  })
  local scriptComposition = require("game.hgss.src.field.FieldScriptComposition").compose(self, {
    cacheFs = boot.cacheFs,
    layoutMessage = boot.layoutMessage,
    fontDef = boot.fontDef,
    audioService = boot.audioService,
    loadedGame = boot.loadedGame,
    mons = self.monService,
    items = self.bagService,
    itemCatalog = self.itemCatalog,
    starterProvider = self.starterProvider,
    starterChoice = self.starterChoice,
    partySelection = self.partySelection,
    mart = self.martHost,
    travel = self.fieldTravel,
    fieldMoves = self.partyMenu.fieldMoves,
    monNaming = self.monNaming,
    followingMon = self.followingMon,
    followerInteractionCatalog = self.followerInteractionCatalog,
    followerReactionTicks = self.followerReactionTicks,
    clock = self.localClock,
    followerTransition = self.followingMonTransition,
    starterBalls = self.starterBalls,
    battle = self._battleHost,
    pcApplications = self.pcApplicationHost,
    kurtBoxHost = self.kurtBoxHost,
    pcTerminal = self.pcTerminal,
  })
  self.scripts = scriptComposition.scripts
  scriptComposition.restore()
end

function FieldRuntime:_processApricornDate()
  local now = self.localClock:nowLocal()
  local result = self.martService:processApricornDate({ year = now.year, month = now.month, day = now.day })
  if result.advanced then
    self.eventState:clearFlag(FieldScriptSymbols.flagsByName.FLAG_DAILY_KURT_MAKING_BALLS)
    local treePresentation = self.apricornTreePresentation
    if treePresentation ~= nil then
      treePresentation:invalidateAssets()
    end
  end
end

-- Resolve the retail tag's placed model through its generated semantic role.
-- The returned adapter keeps each model's
-- compiled clip duration alongside its live instance handle.
---@param propRef string
---@return table<string, unknown>
function FieldRuntime:_resolvePcTerminalProp(propRef)
  assert(propRef == "pc_terminal", "PC terminal prop reference is closed")
  local pcManifest = assert(self.partyMenu, "PC terminal needs the menu composition").pcManifest
  local terminal = assert(pcManifest.terminal, "PC terminal source policy is compiled")
  local mapProps = assert(self.runtimeMap.mapProps, "the active map owns canonical scene props")
  local selected
  for _, placement in ipairs(mapProps.placements) do
    if placement.semanticRole == "pc_terminal" then
      local descriptor =
        assert(self.cacheFs:loadLua(MapAssetCache.modelPath(placement.modelKey)), "placed model descriptor is compiled")
      selected = { prop = assert(mapProps:prop(placement.placementIndex)), descriptor = descriptor }
      break
    end
  end
  local selectedProp = assert(selected, "source PC terminal model is present on the active map")
  local clips = assert(selectedProp.descriptor.animations, "terminal model carries compiled animations")
  local instance = selectedProp.prop.instance
  local activeHandle = nil
  local activeFrameCount = nil
  local headlessFrame = nil
  local function slotForRole(role)
    for slot = 0, 1 do
      if terminal.slots[slot].role == role then
        return slot
      end
    end
    error("unknown terminal role: " .. tostring(role), 0)
  end
  local function clipForRole(role)
    local slot = slotForRole(role)
    local clip = assert(clips[slot + 1], "terminal role slot has a compiled model clip")
    assert(type(clip.frameCount) == "number" and clip.frameCount > 0, "terminal clip has its source frame count")
    activeFrameCount = clip.frameCount
    return clip
  end
  local function play(_, role, mode)
    assert(mode == "once", "terminal roles play once")
    assert(activeHandle == nil, "terminal model has one active one-shot clip")
    local clip = clipForRole(role)
    if instance ~= nil then
      local liveClip = assert(instance.definition.animations[slotForRole(role) + 1])
      assert(liveClip.name == clip.name, "live terminal clip order matches its compiled descriptor")
      activeHandle = instance:play(liveClip.name, { loopMode = "once" })
    else
      headlessFrame = 0
      activeHandle = clip
    end
  end
  local function isFinished(_, role)
    assert(activeHandle ~= nil and activeFrameCount ~= nil, "terminal role is playing")
    assert(terminal.slots[slotForRole(role)].role == role, "terminal wait names its active source role")
    if instance ~= nil then
      return activeHandle.player:isComplete()
    end
    headlessFrame = math.min(headlessFrame + 1, activeFrameCount)
    return headlessFrame == activeFrameCount
  end
  local function stop(_, role)
    if activeHandle == nil then
      return
    end
    assert(terminal.slots[slotForRole(role)].role == role, "terminal release names its active source role")
    if instance ~= nil then
      instance:stop(activeHandle)
    end
    activeHandle = nil
    activeFrameCount = nil
    headlessFrame = nil
  end
  return { play = play, isFinished = isFinished, stop = stop }
end

-- Composes the one script-owned mart child host over the real inventory and
-- presentation owners. Children borrow the shared field display and complete
-- Bag contracts; the scheduler remains their only fixed-tick driver.
---@param boot table<string, unknown>
function FieldRuntime:_composeMart(boot)
  local MartHost = require("game.hgss.src.mart.MartHost")
  local MartScreenState = require("game.hgss.src.mart.MartScreenState")
  local BagScreenState = require("game.hgss.src.field.BagScreenState")
  local BagCache = require("libs.assets.src.BagCache")
  local BagOverrides = self.presentationOverrides ~= nil and self.presentationOverrides.bag or nil
  local MartOverrides = self.presentationOverrides ~= nil and self.presentationOverrides.mart or nil
  local function measureDisplay()
    return assert(self.presentationDisplay, "mart children require measured field display")
  end
  local function playSequence(sequence)
    local audio = self.audio or boot.audioService
    if audio ~= nil then
      audio:play(sequence)
    end
  end
  -- Mart children resolve their text cadence per open from the live
  -- player options, so a confirmed option lands on the next buy/sell
  -- without recomposing inventory, scripts, or audio.
  local function createBuy(session)
    return MartScreenState.new({
      session = session,
      manifest = MartCache.loadManifest(boot.cacheFs),
      uiManifest = self.uiManifest,
      fontDef = boot.fontDef,
      textPolicy = TextSpeedPolicy.forSpeed(self.playerData.options.textSpeed),
      effect = playSequence,
      measureDisplay = measureDisplay,
      frameIndex = self.playerData.options.textFrame,
      overrides = MartOverrides,
    })
  end
  local function createSell(session)
    return BagScreenState.new({
      effect = playSequence,
      textPolicy = TextSpeedPolicy.forSpeed(self.playerData.options.textSpeed),
      service = self.bagService,
      cursor = self.bagCursor,
      manifest = BagCache.loadManifest(boot.cacheFs),
      uiManifest = self.uiManifest,
      monCatalog = self.monCatalog,
      heroGender = self.playerData.profile.gender == 0 and "male" or "female",
      context = "sell",
      saleSession = session,
      partyEmpty = self.monService:partyCount() == 0,
      measureDisplay = measureDisplay,
      overrides = BagOverrides,
    })
  end
  local function readFlag(flagId)
    return self.eventState:isFlagSet(flagId)
  end
  local function readVariable(varId)
    return self.eventState:getVar(varId)
  end
  local function currentMartDate()
    return self.localClock:nowLocal()
  end
  local function clearMartUi()
    self.input:clearUi()
  end
  local resolver = self.martStockResolver
  if resolver == nil then
    resolver = VanillaMartStock.resolve
  end
  self.martHost = MartHost.new({
    service = self.martService,
    catalog = { mart = self.martCatalog, items = self.itemCatalog },
    profile = self.playerData.profile,
    localDate = currentMartDate,
    stockResolver = resolver,
    getFlag = readFlag,
    getVar = readVariable,
    createBuy = createBuy,
    createSell = createSell,
    clearUi = clearMartUi,
  })
end

-- Publish residency and the live session only after its collaborators are ready.
---@param boot table<string, unknown>
function FieldRuntime:_startFieldSession(boot)
  local FieldZoneController = require("libs.hgss.src.world.FieldZoneController")
  local function mapForId(mapId)
    return assert(self.residency):mapForId(mapId)
  end
  local function rebindScripts(runtimeMap, player)
    self.runtimeMap = runtimeMap
    player.currentMap = runtimeMap
    self.scripts:onZoneChange(runtimeMap)
  end
  local function applyWeather(runtimeMap)
    -- The runtime render environment is always available, even on a
    -- scene-less logical halo, so destination weather resolves against
    -- the destination map itself instead of carrying the source weather.
    self.weatherRuntime = { mapId = runtimeMap.mapId }
    self:_applyEffectiveWeather(runtimeMap)
  end
  local function enterAudio(runtimeMap)
    if self.audio and self.audio.enterZone then
      self.audio:enterZone(runtimeMap)
    end
  end
  local function onZoneChange(change)
    self.lastZoneChange = change
    if self.incomingCalls ~= nil then
      self.incomingCalls:resetTransient("transition")
    end
    -- A seamless crossing is the only place the section fact is announced, and
    -- the section fact ignores source/destination map identity. The zone
    -- rebind has already published the destination logical map.
    if change.mapSectionChanged and self.mapNameBanner ~= nil then
      assert(
        self.runtimeMap.mapId == change.newMapId,
        "a seamless zone change must publish its destination map before the callback"
      )
      self.mapNameBanner:request(change.newMapId, self.runtimeMap.mapSectionNativeId)
    end
  end
  self.zoneController = FieldZoneController.new({
    currentMap = self.runtimeMap,
    mapForId = mapForId,
    rebindScripts = rebindScripts,
    applyWeather = applyWeather,
    enterAudio = enterAudio,
    onChange = onZoneChange,
  })

  local FieldResidencyCoordinator = require("libs.hgss.src.world.FieldResidencyCoordinator")
  local function coverageProvider()
    return self.physicalCoverage
  end
  local function resolveInteraction(_, snapshot)
    return self.interactionResolver:resolve(snapshot)
  end
  local function enterMapActors()
    local restore = boot.initialActorRestore
    if restore ~= nil then
      assert(self.runtimeMap.mapId == boot.initialActorRestoreMapId, "loaded actor snapshot map mismatch")
    end
    self.actors:enterMap(self.runtimeMap, self.eventState, restore)
    if restore ~= nil then
      boot.initialActorRestore = nil
      boot.initialActorRestoreMapId = nil
    end
  end
  local onPreparedMap
  if self.audio then
    local function prewarmMapMusic(runtimeMap)
      self.audio:prewarmMapMusic(runtimeMap)
    end
    onPreparedMap = prewarmMapMusic
  end
  self.residency = FieldResidencyCoordinator.new({
    coverage = self.physicalCoverage,
    mapLoader = self.mapLoader,
    actors = self.actors,
    zoneController = self.zoneController,
    composeMap = boot.composeCurrentMap,
    onPreparedMap = onPreparedMap,
  })
  self.residency:initialize()
  -- The boot position drives halo ordering from the first frame: a player who
  -- starts near a boundary must not walk corner-to-corner before the imminent
  -- frontier is predicted.
  if self.player ~= nil then
    self.residency:setPrefetchFocus(self.player.fieldX, self.player.fieldZ, self.player.facing)
  end

  local function sessionContextChoicePresentation()
    return self:contextChoicePresentation()
  end
  local function partyKnowsMove(move)
    return self.monService:partySlotWithMove(move) ~= nil
  end
  local function useRegisteredItem(slot)
    local itemKey = self.bagService:registeredItems()[slot]
    return itemKey ~= nil and self:useKeyItem(itemKey, true)
  end
  self.session = FieldSession.new({
    versionId = self.versionId,
    currentMap = self.runtimeMap,
    player = self.player,
    camera = self.camera,
    transition = self.transition,
    actors = self.actors,
    playerVisual = self.playerVisual,
    dialogue = self.dialogue,
    input = self.input,
    scriptScheduler = self.scripts.scheduler,
    scriptClient = self.scripts.client,
    initController = self.scripts.initController,
    menuHost = self.menuHost,
    yesNoHost = self.yesNoHost,
    contextChoice = self.contextChoiceProvider,
    contextChoicePresentation = sessionContextChoicePresentation,
    starterChoice = self.starterChoice,
    partySelection = self.partySelection,
    martHost = self.martHost,
    kurtBoxHost = self.kurtBoxHost,
    registeredItemUse = useRegisteredItem,
    fieldMoves = self.partyMenu.fieldMoves,
    overworld = self.overworld,
    monNaming = self.monNaming,
    signpost = self.signpost,
    applicationHost = self.applicationHost,
    pcApplications = self.pcApplicationHost,
    -- The session's fixed-tick audio collaborator is the production
    -- GameSound only; a recording script adapter is a script service, not
    -- a session collaborator.
    audio = self.audio,
    navigationBoundary = require("libs.hgss.src.world.FieldNavigationBoundary").new({
      zoneController = self.zoneController,
      residencyCoordinator = self.residency,
      coverageProvider = coverageProvider,
    }),
    interactions = {
      resolve = resolveInteraction,
    },
    eventResolver = FieldEventResolver,
    eventState = self.eventState,
    fieldEntranceIndicator = self.fieldEntranceIndicator,
    incomingCalls = assert(self.incomingCalls, "the field session routes the ambient phone opportunity"),
    pokegearApplications = self.pokegear and self.pokegear.scriptHost or nil,
    easyChatScriptHost = self.easyChatScriptHost,
    enterMapActors = enterMapActors,
    autoAcknowledgePresentation = not self.presentation,
    terrainEffects = self.fieldTerrainEffectController,
    playerAvatar = self.playerAvatar,
    progression = PlayerProgression.new(self.playerData.profile),
    partyKnowsMove = partyKnowsMove,
    gymMechanism = self.gymMechanism,
    roamerTransitions = {
      connection = function(sourceMapId, destinationMapId)
        self:publishRoamerTransition("connection", sourceMapId, destinationMapId)
      end,
    },
  })

  if boot.loadedGame and boot.loadedGame.weatherId ~= nil then
    self:_setLiveWeather(self.runtimeMap, boot.loadedGame.weatherId)
  else
    self:_applyEffectiveWeather(self.runtimeMap)
  end
  -- A restored game opens the field on its saved map: the source loads that map
  -- with INIT_SCRIPT_ON_LOAD and INIT_SCRIPT_ON_RESUME and reaches
  -- INIT_SCRIPT_ON_TRANSITION only through a warp, so a Continue never re-runs
  -- the map's transition scripts.
  self.session:beginMapEntry(boot.loadedGame ~= nil and "load" or "full")
  self.playTime = boot.loadedGame and PlayTime.new(boot.loadedGame.playTimeSeconds) or self.game.playTime
  assert(self.playTime and self.playTime.start and self.playTime.advance, "game play time is required")
  self.playTime:start()

  self.weatherRuntime = { mapId = self.runtimeMap.mapId }
end

function FieldRuntime.new(game, options)
  assert(type(game) == "table", "field runtime requires a finalized or loaded game")
  assert(type(game.versionId) == "string" and game.versionId ~= "", "field runtime game version is required")
  options = options or {}
  assert(
    options.martStockResolver == nil or type(options.martStockResolver) == "function",
    "martStockResolver must be a function"
  )
  local effectiveOverrideFs = options.overrideFs or RepoFs.new(love.filesystem.getSourceBaseDirectory())
  local self = setmetatable({
    game = game,
    versionId = game.versionId,
    saveId = game.saveId,
    viewportWidth = options.viewportWidth or WindowConfig.REFERENCE_WIDTH,
    viewportHeight = options.viewportHeight or WindowConfig.REFERENCE_HEIGHT,
    screenTopology = options.screenTopology,
    overrideFs = effectiveOverrideFs,
    presentation = options.presentation == true,
    scriptHosts = options.scriptHosts,
    dayNight = options.dayNight,
    audioOutput = options.audioOutput,
    audioPreferences = options.audioPreferences,
    derivedAssets = options.derivedAssets,
    cacheFs = options.cacheFs,
    saveStore = options.saveStore,
    savePublished = false,
    localClock = options.localClock or LocalClock.system(),
    weatherClock = options.weatherClock,
    presentationOverrides = options.presentationOverrides,
    martStockResolver = options.martStockResolver,
    fieldPixelScale = FieldPixelScale.new(options.fieldScaleConfig or FieldPresentation.fieldScale),
    overworld = FieldOverworldLifecycle.new(),
    propAnimations = FieldScriptPropAnimations.new(),
    assetNeeds = AssetNeedsRegistry.new(),
  }, FieldRuntime)
  -- The actual-display measurement owner: shared when the product root
  -- supplies one, otherwise a runtime-owned context whose provider tracks
  -- the latest resize topology (or the context default without one). The
  -- runtime never acquires graphics itself.
  self._displayTopology = options.screenTopology
  if options.displayContext ~= nil then
    self.displayContext = options.displayContext
  else
    local function displayTopologyProvider()
      return self._displayTopology
    end
    local provider
    if options.screenTopology ~= nil then
      provider = displayTopologyProvider
    end
    self.displayContext = DisplayContext.new({ graphics = options.displayGraphics, topologyProvider = provider })
  end
  self.saveCoordinator = FieldSaveCoordinator.new(self)
  self.worldSwapCoordinator = FieldWorldSwapCoordinator.new(self)
  self.menuComposer = FieldMenuCompositionCoordinator.new(self)
  self.weatherClock = self.weatherClock or defaultWeatherClock(self.localClock)
  self:_load(options)
  return self
end

function FieldRuntime:_load(loadOptions)
  local boot = {}
  local ok, err = pcall(function()
    self:_loadRuntimeAssets(boot, loadOptions)
    self:_loadInitialWorld(boot)
    self:_composeTransitions(boot)
    self:_composeFieldUi(boot)
    self:_composeFieldServices(boot)
    self:_startFieldSession(boot)
  end)
  -- Construction is binary: a failed boot releases everything acquired so
  -- far exactly once, then the original failure propagates to the caller.
  -- There is no half-constructed runtime; boot failures always propagate.
  if not ok then
    self:_releaseAll()
    error(err, 0)
  end
end

-- Seconds between deferred party-warmup retries while selector manifests
-- are still staging.
local PARTY_PREFETCH_RETRY_SECONDS = 1.0

-- Indivisible background cell-preparation steps the field staging pass may spend
-- in one frame. Two steps keep the halo ahead of the player without letting a
-- long-lost prefetch backlog own the frame; each step is itself bounded (one
-- descriptor read, one collision decode, one presentation realization).
local FIELD_STAGE_UNITS_PER_FRAME = 2

-- Warms the live party's compiled assets once per party revision, plus a
-- bounded retry while selector manifests are still staging. Best effort
-- only: a deferral rearms the cooldown instead of failing the update,
-- and the required display demands stay the correctness path.
function FieldRuntime:_pollPartyAssetWarmup(dt)
  local service = assert(self.monService, "party warmup requires the live mon service")
  local revision = service:partyRevision()
  local cooldown = self._partyPrefetchCooldown or 0
  if revision == self._partyPrefetchRevision then
    if cooldown <= 0 then
      return
    end
    cooldown = cooldown - dt
    self._partyPrefetchCooldown = cooldown
    if cooldown > 0 then
      return
    end
  end
  local warmed = PartyAssetPrefetch.prefetch({
    monService = service,
    cacheFs = assert(self.cacheFs, "party warmup requires the version cache filesystem"),
    derivedAssets = assert(self.derivedAssets, "party warmup requires the semantic derived-asset host"),
  })
  self._partyPrefetchRevision = revision
  if warmed then
    self._partyPrefetchCooldown = 0
  else
    self._partyPrefetchCooldown = PARTY_PREFETCH_RETRY_SECONDS
  end
end

-- Re-runs the live party near warmup on the next update: battle admission
-- refreshes the bench portrait, cry, and effect demands even when the
-- party revision has not changed since map entry. Marker-only; the next
-- update still skips without its mon service, cache, or asset host.
function FieldRuntime:refreshPartyWarmup()
  self._partyPrefetchRevision = nil
  self._partyPrefetchCooldown = 0
end

function FieldRuntime:update(dt)
  local maxSemanticDt = FieldSession.FIXED_DT * FieldSession.MAX_CATCH_UP_TICKS
  local acceptedDt = math.min(dt, maxSemanticDt)
  if self.playTime then
    self.playTime:advance(acceptedDt)
  end

  if self.residency then
    -- Background cell staging owns a small, explicitly bounded share of each
    -- frame: two indivisible preparation steps (a descriptor read, one
    -- presentation realization, ...), never an unbounded catch-up pass. The
    -- halo ahead of the player is what keeps a seamless boundary from waiting.
    -- The predicted window's region and draw-list assembly rides the same call
    -- but bounds itself by measured time, so a whole-window build fills in
    -- across frames instead of owning the one that crosses the boundary.
    self.residency:updatePrefetch(FIELD_STAGE_UNITS_PER_FRAME)
  end

  -- Consumers observe party changes by polling partyRevision, so the
  -- near-urgency asset warmup rides the same poll: save-load boot warms
  -- the loaded party on its first update and every later party mutation
  -- rewarms through its revision bump. Cache and host absence (a
  -- headless seam without derived assets) skips warmup without touching
  -- the required display demands.
  if self.monService ~= nil and self.cacheFs ~= nil and self.derivedAssets ~= nil then
    self:_pollPartyAssetWarmup(dt)
  end

  self.session.accumulator = self.session.accumulator + acceptedDt
  -- Reconcile the battle input gate before any fixed tick can initiate
  -- player movement, interactions, or menu actions.
  self:_reconcileBattleGate()
  local FIXED_DT = FieldSession.FIXED_DT
  local MAX_CATCH_UP = FieldSession.MAX_CATCH_UP_TICKS
  local EPSILON = 1e-12
  local fieldExecuted = 0
  while self.session.accumulator + EPSILON >= FIXED_DT and fieldExecuted < MAX_CATCH_UP do
    self.session.accumulator = self.session.accumulator - FIXED_DT
    if self.pokemonCenterHeal then
      self.pokemonCenterHeal:updateFixed()
    end
    -- The mechanism's presented source props advance their own clip clocks on
    -- the same fixed tick, and the one gameplay mechanism the field drives
    -- without a script - the Blackthorn platform action - advances here too;
    -- gameplay state is untouched by the presentation half.
    if self.gymMechanism then
      self.gymMechanism:updatePresentation()
      self.gymMechanism:updateFixed()
    end
    if self.rocketHideoutEffects then
      self.rocketHideoutEffects:updatePresentation()
    end
    if self.legendEventScene then
      self.legendEventScene:updatePresentation()
    end
    self:_processApricornDate()
    -- The transient banner advances one fixed tick before the session so a
    -- request created during this tick keeps its initial source displacement
    -- until the next tick, even while a transition holds input.
    if self.mapNameBanner then
      self.mapNameBanner:updateFixed()
    end
    -- The source checks trainer sight at the head of every field input
    -- frame, before a step could start, and advances the running approaches
    -- on the same fixed tick.
    if self.trainerEncounter then
      self.trainerEncounter:updateFixed()
      self.trainerEncounter:tryEngage()
    end
    -- The shortcut cluster slides out while the start menu is open and
    -- whenever a cutscene, dialogue, or other modal holds the field.
    if self.shortcutSlide then
      self.shortcutSlide:updateFixed(self.applicationHost:isActive() or not self.session:isRoamingFree())
    end
    self.session:updateFixed()
    self.fishingHost:updateFixed()
    if self.hoOhAppearanceScene then
      self.hoOhAppearanceScene:updateFixed()
    end
    fieldExecuted = fieldExecuted + 1
    -- One committed step is considered per fixed tick, before another
    -- catch-up tick can start a step: an accepted encounter claims the
    -- launch (and its input/foreground hold) synchronously, so the next
    -- tick in this same update already sees the held field.
    self:_consumeCommittedStep()
    -- The follower reconciles once per fixed tick, after player and
    -- transition commits inside the session update and before the next
    -- tick's actor finalization and draw reads. The follower transition
    -- advances once per fixed tick right after, so a same-tick start
    -- observes the committed placement. A presented battle holds both
    -- clocks alongside player movement; otherwise the field can jump
    -- when revealed.
    local sessionHold = self.session.isForegroundHoldActive
    local gameplayHeld = sessionHold ~= nil and sessionHold(self.session) or false
    if self.followingMon and not gameplayHeld then
      local currentMap = assert(self.session.currentMap, "field logical map is required")
      local actors = assert(self.actors, "field actor manager is required")
      local entry = assert(self.session.mapEntryController, "field map-entry controller is required")
      local logicalMapId = assert(currentMap.mapId, "field logical map identity is required")
      local actorMapId = actors.currentMapId
      if actorMapId == logicalMapId then
        local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
        if self.transition.phase ~= FieldTransition.PHASES.preview then
          -- Retail keeps the follower hidden for the whole bike ride.
          self.followingMon:setStowed(self.playerAvatar:durableState() == "cycling")
          self.followingMon:update()
          -- The follower commits its own step after the session tick; publish
          -- it in this same tick so its grass lands with its feet.
          self.session:emitCommittedActorSteps()
        end
      elseif entry:isActive() then
        -- Map entry owns publication of the destination actor set. Until it
        -- publishes an identity, the follower has no coherent map to
        -- reconcile against.
      elseif actorMapId == nil then
        assert(false, "field actor map identity is required")
      else
        assert(false, "field actor map ownership drifted outside map entry")
      end
    end
    if self.followingMonTransition and not gameplayHeld then
      self.followingMonTransition:updateFixed()
    end
    -- The script-owned starter modal advances its retail transition clocks
    -- once per fixed tick while open, after the scheduler poll above has
    -- applied this tick's UI events: the next poll observes settled
    -- rotations, confirmations, and lock exits deterministically.
    if self.starterChoice and self.starterChoice:isActive() then
      self.starterChoice:update()
    end
    local applicationError = self.applicationHost:error()
    if applicationError ~= nil then
      error(applicationError, 0)
    end
    -- The scheduler-owned word editor child reports its preparation
    -- failure through its inspected status: the runtime never prepares
    -- or steps the child here, only cancels the owning foreground and
    -- rethrows the original error.
    local easyChatHost = self.easyChatScriptHost
    if easyChatHost ~= nil and easyChatHost:isActive() then
      local childStatus = easyChatHost:status()
      if type(childStatus) == "table" and childStatus.preparationError ~= nil then
        self:failEasyChatPresentation("word editor preparation failed: " .. tostring(childStatus.preparationError))
      end
    end
    local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
    local preview = self.transition.preview
    local pausePreviewHold = self.transition.phase == FieldTransition.PHASES.preview
      and preview ~= nil
      and preview:status().stage == "hold"
      and not self.session:destinationWorldPresentable()
    if not pausePreviewHold then
      self.transition:updateSourceFrame()
    end
    self.screenFade:updateSourceFrame()
    self.scentTint:updateSourceFrame()
    if self.poisonEffect ~= nil then
      self.poisonEffect:updateSourceFrame()
    end
    if self.blackoutFlow then
      self.blackoutFlow:updateSourceFrame()
    end
    if self.audio then
      self.audio:updateSoundFrame()
    end
  end
  if self.session.accumulator + EPSILON >= FIXED_DT then
    local discarded = math.floor((self.session.accumulator + EPSILON) / FIXED_DT)
    self.session.accumulator = self.session.accumulator - discarded * FIXED_DT
  end

  -- After the fixed ticks: a tick may activate a new map, whose render
  -- environment must carry the current time in the frame that draws it.
  self:_pumpIncomingClock()
  self:_refreshFieldTimeOfDay()

  -- The owned battle lifetime pumps once per runtime update, after the
  -- field settles: simulation and presentation acknowledgements advance
  -- together while entry/return readiness still gates phase transitions.
  -- Step encounters were already considered once per fixed tick above. A
  -- presented launch advances only through its envelope's fixed driver,
  -- never through this host-update pump as well.
  if self.battleCoordinator:shouldPumpFromHost() then
    self.battleCoordinator:updateBattle()
  end
  self.battleCoordinator:prefetchEncounterScene()
  -- Lifetimes may have settled or released during pumping, so reconcile
  -- the gate again before the next update observes it.
  self:_reconcileBattleGate()
  -- Soft prediction round for the current/near working set at end of
  -- update: enrolls background audio demand and trims idle caches at epoch
  -- commit. Steady-state updates only adopt ready payloads; drawing never
  -- prunes.
  self:_refreshPrediction()
  -- Background asset preparation: one bounded slice of the jobs the
  -- prediction round enrolled, once per host update.
  self.assetNeeds:step(ASSET_NEEDS_STEP_SECONDS)
  -- The audio output clock: pump PCM from the engine into the host sink once
  -- per runtime update, separate from the field fixed tick (the sink never
  -- advances game-semantic audio state).
  if self.audioSink then
    self.audioSink:update()
  end
  if self.transition.error then
    local context = self.transition.warpContext
    if context then
      error(
        string.format(
          "%s\nsource map %s warp %s -> map %s warp %s",
          tostring(self.transition.error),
          tostring(context.sourceMapId),
          tostring(context.sourceWarpId),
          tostring(context.destinationMapId),
          tostring(context.destinationWarpId)
        ),
        0
      )
    else
      error(self.transition.error, 0)
    end
  end
  local completed = self.transition:consumeCompleted()
  if completed and self.incomingCalls ~= nil then
    self.incomingCalls:resetTransient("transition")
  end
  if completed and self.camera then
    -- The transition may finish on the same fixed tick that applies the
    -- destination stair/door arrival. Publish a settled camera pair with the
    -- completion event so the first post-transition presentation frame cannot
    -- interpolate from the pre-arrival Y history.
    self.camera:collapseRenderInterpolation()
  end
end

-- Advances the soft predicted working-set epoch at end of update, never on
-- draw. The driver owns change detection; steady-state updates only adopt
-- ready background payloads.
function FieldRuntime:_refreshPrediction()
  if self._predictionDriver == nil then
    self._predictionDriver = PredictionDriver.new()
  end
  local driver = self._predictionDriver --[[@as PredictionDriver]]
  driver:refresh(self)
end

-- Samples the host-local civil clock into the incoming-call owner once
-- per field update, never from rendering or the displayed clock. The
-- sample pauses while a higher-priority owner holds the field, matching
-- the source advancement that only runs without a field task.
function FieldRuntime:_pumpIncomingClock()
  local calls = self.incomingCalls
  local session = self.session
  if calls == nil or session == nil then
    return
  end
  if session:isBattleActive() then
    return
  end
  local transition = session.transition
  if transition ~= nil and transition.phase ~= nil then
    local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
    if transition.phase ~= FieldTransition.PHASES.idle then
      return
    end
  end
  if session.mapEntryController:isActive() then
    return
  end
  if session.dialogue:isModal() then
    return
  end
  if session.applicationHost:isActive() then
    return
  end
  local scripts = self.scripts
  local scheduler = scripts ~= nil and scripts.scheduler or nil
  if scheduler ~= nil then
    if type(scheduler.playerInputOwned) == "function" and scheduler:playerInputOwned() then
      return
    end
    if type(scheduler.foregroundEnvironmentId) == "function" and scheduler:foregroundEnvironmentId() ~= nil then
      return
    end
  end
  local report = calls:onFieldClock(self.localClock:nowLocal())
  if type(report) ~= "table" then
    return
  end
  -- The Route16 daily word gate clears on a positive civil-day advance
  -- only: same-day reloads preserve the use, and backward adjustments
  -- never reopen the gate. Learned words are never cleared.
  if report.backward ~= true and type(report.dayAdvance) == "number" and report.dayAdvance > 0 then
    local world = self.scripts ~= nil and self.scripts.worldState or nil
    if world ~= nil then
      world:clearFlag(FieldScriptSymbols.flagsByName.FLAG_UNK_ABA)
    end
  end
end

-- Every semantic-input entry point below needs the same live-input guard;
-- factored so the assertion text stays in one place. Returns the input
-- component so a call site can chain straight into it.
local function requireLiveInput(self)
  return assert(self.input, "field runtime is disposed")
end

-- Semantic input keeps the non-rendering runtime independent of keyboard and
-- gamepad event translation. Hosts drive these edges directly.
---@param direction string
function FieldRuntime:press(direction)
  requireLiveInput(self):press(direction)
end

---@param direction string
function FieldRuntime:release(direction)
  requireLiveInput(self):release(direction)
end

function FieldRuntime:pressAction()
  requireLiveInput(self):pressAction("runtime")
end

function FieldRuntime:releaseAction()
  requireLiveInput(self):releaseAction("runtime")
end

function FieldRuntime:pressCancel()
  requireLiveInput(self):pressCancel("runtime")
end

function FieldRuntime:releaseCancel()
  requireLiveInput(self):releaseCancel("runtime")
end

function FieldRuntime:pressMenu()
  requireLiveInput(self):pressMenu("runtime")
end

function FieldRuntime:releaseMenu()
  requireLiveInput(self):releaseMenu("runtime")
end

---@param prepare fun(iconKeys: string[]): boolean, string? presented icon preparation
---@param cancel fun() presented preparation release
---@return integer binding identity for the presented lifetime
function FieldRuntime:bindPartyIconPreparation(prepare, cancel)
  assert(type(prepare) == "function", "icon preparation binding requires its prepare function")
  assert(type(cancel) == "function", "icon preparation binding requires its cancel function")
  assert(self._partyIconPreparation == nil, "one party preparation binding owns the presented lifetime")
  self._partyIconBindingId = (self._partyIconBindingId or 0) + 1
  self._partyIconPreparation = { id = self._partyIconBindingId, prepare = prepare, cancel = cancel }
  return self._partyIconBindingId
end

-- Removes only the matching binding: a stale unbind never drops a
-- replacement presentation, and party factories created after disposal
-- fail at launch instead of drawing without icons.
---@param binding integer binding identity from bindPartyIconPreparation
function FieldRuntime:unbindPartyIconPreparation(binding)
  local current = self._partyIconPreparation
  if current ~= nil and current.id == binding then
    self._partyIconPreparation = nil
  end
end

-- Binds the per-launch presented-battle factory.
---@param factory fun(descriptor: table<string, unknown>): table<string, unknown>
---@return integer binding identity
function FieldRuntime:bindBattlePresentation(factory)
  return self.battleCoordinator:bindBattlePresentation(factory)
end

---@param binding integer binding identity
function FieldRuntime:unbindBattlePresentation(binding)
  local coordinator = self.battleCoordinator
  if coordinator ~= nil then
    coordinator:unbindBattlePresentation(binding)
  end
end

-- Installs the field summary preparation factory for the presented
-- lifetime: the logical composition resolves it per summary open because
-- presentation resources postdate the menu factories. The runtime owns
-- no graphics here, only the acquire callback plus its binding identity.
---@param acquire fun(): table<string, unknown> per-open summary lease factory
---@return integer binding identity for the presented lifetime
function FieldRuntime:bindSummaryPreparation(acquire)
  assert(type(acquire) == "function", "summary preparation binding requires its acquire function")
  assert(self._summaryPreparation == nil, "one summary preparation binding owns the presented lifetime")
  self._summaryBindingId = (self._summaryBindingId or 0) + 1
  self._summaryPreparation = { id = self._summaryBindingId, acquire = acquire }
  return self._summaryBindingId
end

-- Removes only the matching binding: a stale unbind never drops a
-- replacement owner, and summary factories created after disposal fail
-- at launch instead of presenting without preparation.
---@param binding integer binding identity from bindSummaryPreparation
function FieldRuntime:unbindSummaryPreparation(binding)
  local current = self._summaryPreparation
  if current ~= nil and current.id == binding then
    self._summaryPreparation = nil
  end
end

-- Installs the field word editor preparation factory for the presented
-- lifetime: the logical composition resolves it per editor open because
-- presentation resources postdate the menu factories. The runtime owns no
-- graphics here, only the acquire callback plus its binding identity.
---@param acquire fun(): table<string, unknown> per-open editor lease factory
---@return integer binding identity for the presented lifetime
function FieldRuntime:bindEasyChatPreparation(acquire)
  assert(type(acquire) == "function", "word editor preparation binding requires its acquire function")
  assert(self._easyChatPreparation == nil, "one word editor preparation binding owns the presented lifetime")
  self._easyChatBindingId = (self._easyChatBindingId or 0) + 1
  self._easyChatPreparation = { id = self._easyChatBindingId, acquire = acquire }
  return self._easyChatBindingId
end

-- Removes only the matching binding: a stale unbind never drops a
-- replacement owner, and editor factories created after disposal fail
-- at launch instead of presenting without preparation.
---@param binding integer binding identity from bindEasyChatPreparation
function FieldRuntime:unbindEasyChatPreparation(binding)
  local current = self._easyChatPreparation
  if current ~= nil and current.id == binding then
    self._easyChatPreparation = nil
  end
end

-- Installs the Mail stationery preparation factory for the presented
-- lifetime: the logical composition resolves it per Mail open because
-- presentation resources postdate the menu factories. The runtime owns no
-- graphics here, only the acquire callback plus its binding identity.
---@param prepare fun(status: table<string, unknown>): boolean, string? per-open Mail preparation
---@return integer binding identity for the presented lifetime
function FieldRuntime:bindMailPreparation(prepare)
  assert(type(prepare) == "function", "mail preparation binding requires its prepare function")
  assert(self._mailPreparation == nil, "one mail preparation binding owns the presented lifetime")
  self._mailBindingId = (self._mailBindingId or 0) + 1
  self._mailPreparation = { id = self._mailBindingId, prepare = prepare }
  return self._mailBindingId
end

-- Removes only the matching binding: a stale unbind never drops a
-- replacement owner, and Mail factories created after disposal fail at
-- launch instead of presenting without preparation.
---@param binding integer binding identity from bindMailPreparation
function FieldRuntime:unbindMailPreparation(binding)
  local current = self._mailPreparation
  if current ~= nil and current.id == binding then
    self._mailPreparation = nil
  end
end

-- Installs the evolution presentation factory for the presented lifetime:
-- the menu composition resolves it per evolution scene because the battle
-- presentation owner postdates the menu factories. The runtime owns no
-- graphics here, only the acquire callback plus its binding identity.
---@param acquire fun(sceneId: string): { assets: FieldEvolutionAssets, splRandomState: table<string, integer> } per-scene lease factory
---@return integer binding identity for the presented lifetime
function FieldRuntime:bindEvolutionPresentation(acquire)
  assert(type(acquire) == "function", "evolution presentation binding requires its acquire function")
  assert(self._evolutionPresentation == nil, "one evolution presentation binding owns the presented lifetime")
  self._evolutionBindingId = (self._evolutionBindingId or 0) + 1
  self._evolutionPresentation = { id = self._evolutionBindingId, acquire = acquire }
  return self._evolutionBindingId
end

-- Removes only the matching binding: a stale unbind never drops a
-- replacement owner.
---@param binding integer binding identity from bindEvolutionPresentation
function FieldRuntime:unbindEvolutionPresentation(binding)
  local current = self._evolutionPresentation
  if current ~= nil and current.id == binding then
    self._evolutionPresentation = nil
  end
end

-- Installs the field pokedex preparation factory for the presented
-- lifetime: the logical composition resolves it per pokedex open because
-- presentation resources postdate the menu factories. The runtime owns no
-- graphics here, only the acquire callback plus its binding identity.
---@param acquire fun(options: table<string, unknown>): table<string, unknown> per-open pokedex lease factory
---@return integer binding identity for the presented lifetime
function FieldRuntime:bindPokedexPreparation(acquire)
  assert(type(acquire) == "function", "pokedex preparation binding requires its acquire function")
  assert(self._pokedexPreparation == nil, "one pokedex preparation binding owns the presented lifetime")
  self._pokedexBindingId = (self._pokedexBindingId or 0) + 1
  self._pokedexPreparation = { id = self._pokedexBindingId, acquire = acquire }
  return self._pokedexBindingId
end

-- Removes only the matching binding: a stale unbind never drops a
-- replacement owner, and pokedex factories created after disposal fail
-- at launch instead of presenting without preparation.
---@param binding integer binding identity from bindPokedexPreparation
function FieldRuntime:unbindPokedexPreparation(binding)
  local current = self._pokedexPreparation
  if current ~= nil and current.id == binding then
    self._pokedexPreparation = nil
  end
end

---@class FieldShortcuts
---@field runningShoes { locked: boolean }? the toggle, while the shoes are owned and usable
---@field registeredItems string[] the registered items' icon keys in slot order

-- The live shortcut state the start menu and the closed-menu cluster draw:
-- the Running Shoes toggle while the shoes are owned and the avatar is not
-- cycling, and the registered items' icon keys in slot order.
---@return FieldShortcuts
function FieldRuntime:fieldShortcuts()
  local progression = PlayerProgression.new(self.playerData.profile)
  local runningShoes = nil
  if progression:hasRunningShoes() and self.playerAvatar:durableState() ~= "cycling" then
    runningShoes = { locked = progression:runningShoesLock() }
  end
  local catalog = self.bagService:catalog()
  local registeredItems = {}
  for slot, itemKey in ipairs(self.bagService:registeredItems()) do
    registeredItems[slot] = catalog:item(itemKey).icon
  end
  return { runningShoes = runningShoes, registeredItems = registeredItems }
end

-- Flips the Running Shoes auto-run lock, as the shoes shortcut does.
function FieldRuntime:toggleRunningShoesLock()
  PlayerProgression.new(self.playerData.profile):toggleRunningShoesLock()
end

---@param rememberedActionId string?
---@return StartMenuState? nil when the source has no present actions
function FieldRuntime:_composeStartMenu(rememberedActionId)
  return self.menuComposer:composeStartMenu(rememberedActionId)
end

---@param activeGame table<string, unknown>
---@param loadedGame table<string, unknown>?
function FieldRuntime:_composeBag(activeGame, loadedGame)
  self.menuComposer:composeBag(activeGame, loadedGame)
end

---@param cacheFs table<string, unknown> version cache reader for cited spawn landings
function FieldRuntime:_composePartyMenu(cacheFs)
  self.menuComposer:composePartyMenu(cacheFs)
end

---@return table<string, unknown>
function FieldRuntime:_menuPlayerPort()
  return self.menuComposer:menuPlayerPort()
end

---@return fun(): table<string, unknown>
function FieldRuntime:_menuFieldSources()
  return self.menuComposer:menuFieldSources()
end

---@param cacheFs table<string, unknown>
function FieldRuntime:_composeFollowerTransition(cacheFs)
  self.menuComposer:composeFollowerTransition(cacheFs)
end

---@param audio table<string, unknown>
function FieldRuntime:_composePokemonCenterHeal(audio)
  local definition = assert(
    self.fieldEntranceIndicatorAsset.effects.pokemon_center_heal,
    "field-effect cache is missing pokemon_center_heal"
  )
  local ballModel = assert(definition.models[1], "healing ball model is missing")
  local ballFrameCount
  for _, clip in ipairs(ballModel.animations) do
    if clip.name == definition.ballAnimation or clip.id == definition.ballAnimation then
      ballFrameCount = clip.frameCount
      break
    end
  end
  assert(type(ballFrameCount) == "number" and ballFrameCount > 0, "healing ball animation is missing")
  local function currentMap()
    return self.session and self.session.currentMap or self.runtimeMap
  end
  local function exactPlacement(mapProps, modelKey)
    local match
    for _, placement in ipairs(mapProps.placements) do
      if placement.modelKey == modelKey then
        assert(match == nil, "healing model key resolves to multiple map placements")
        match = placement
      end
    end
    return assert(match, "healing model key has no placement on the active map")
  end
  local function timer(frameCount)
    local remaining = frameCount
    local function updateFixed()
      remaining = math.max(0, remaining - 1)
    end
    local function isFinished()
      return remaining == 0
    end
    local function release() end
    return {
      updateFixed = updateFixed,
      isFinished = isFinished,
      release = release,
    }
  end
  local function headlessBallFactory(_, _, _)
    local remaining = ballFrameCount
    local started = false
    local function startAnimation()
      started = true
    end
    local function updateFixed()
      if started then
        remaining = math.max(0, remaining - 1)
      end
    end
    local function isFinished()
      return started and remaining == 0
    end
    local function dispose() end
    return {
      startAnimation = startAnimation,
      updateFixed = updateFixed,
      isFinished = isFinished,
      dispose = dispose,
    }
  end
  local Flow = require("libs.hgss.src.field.PokemonCenterHealFlow")
  self.pokemonCenterHealDefinition = definition
  local function mapId()
    local map = currentMap()
    return map and map.mapId
  end
  local function resolveAnchor()
    local map = assert(currentMap(), "healing requires an active map")
    local mapProps = assert(map.mapProps, "healing requires map props")
    local anchorPlacement = exactPlacement(mapProps, definition.anchorModelKey)
    local machinePlacement = exactPlacement(mapProps, definition.machineModelKey)
    local machine = assert(mapProps:prop(machinePlacement.placementIndex), "healing machine prop is missing")
    local transform = assert(anchorPlacement.transform, "healing anchor transform is missing")
    local function startAnimation(_, animation)
      local playback = machine:play(animation, { loopMode = "once" })
      if playback == nil then
        return timer(definition.machineAnimationFrameCount)
      end
      local function updateFixed() end
      local function isFinished()
        return machine:isFinished(animation) == true
      end
      local function release()
        machine:stop(animation)
      end
      return {
        updateFixed = updateFixed,
        isFinished = isFinished,
        release = release,
      }
    end
    return {
      position = { x = transform[13], y = transform[14], z = transform[15] },
      startAnimation = startAnimation,
    }
  end
  self.pokemonCenterHeal = Flow.new({
    definition = definition,
    mapId = mapId,
    resolveAnchor = resolveAnchor,
    spawnBall = headlessBallFactory,
    audio = audio,
  })
end

---@param cacheFs unknown
---@param restoredAudio table<string, unknown>? the restored save's audio bucket, when resuming
---@return table<string, unknown> audioService the GameSound instance, or the injected recording adapter
function FieldRuntime:_composeAudio(cacheFs, restoredAudio)
  return self.menuComposer:composeAudio(cacheFs, restoredAudio)
end

-- Materialize pending avatar transitions: apply them in source order through
-- the transition owner, swap the player visual when the graphic changed, and
-- play the ordered sound intents through the field audio service. The owner
-- holds all durable/visual/pending state; the runtime keeps no copy.
---@return { spriteId: integer, spriteChanged: boolean, sounds: string[] }
function FieldRuntime:applyAvatarTransitions()
  local avatar = assert(self.playerAvatar, "field runtime has no avatar transition owner")
  local before = avatar:durableState()
  local result = avatar:applyTransitions()
  if result.spriteChanged then
    assert(self.playerVisual, "field runtime has no player visual"):setAvatar(result.spriteId)
  end
  if self.audio ~= nil and avatar:durableState() ~= before then
    self.audio:syncTraversalMusic()
  end
  if #result.sounds > 0 then
    local audio = self.audio or (self.scriptHosts and self.scriptHosts.audio)
    assert(audio and type(audio.play) == "function", "field avatar transition audio host required")
    for _, symbol in ipairs(result.sounds) do
      audio:play(symbol)
    end
  end
  return result
end

-- Capture the current field session for the explicit-save owner. This boundary
-- only builds and validates a snapshot; publication belongs to storage.
---@return table<string, unknown>? snapshot
---@return string|table<string, unknown>? reason validation or stability failure
---@param allowMenu boolean?
function FieldRuntime:_captureGameSave(allowMenu)
  return assert(self.saveCoordinator, "field runtime has no save coordinator"):capture(allowMenu == true)
end

function FieldRuntime:captureGameSave()
  return self:_captureGameSave(false)
end

-- A PC presentation failure freezes the field, so release the foreground
-- script environment that owns its task before publishing the terminal error.
---@param reason string
function FieldRuntime:failPcApplicationPresentation(reason)
  assert(type(reason) == "string" and reason ~= "", "PC presentation failure needs a diagnostic")
  local scheduler = assert(self.session.scriptScheduler, "field session owns its script scheduler")
  local environmentId = scheduler:foregroundEnvironmentId()
  if environmentId ~= nil then
    scheduler:cancelEnvironment(environmentId, reason)
  elseif self.pcApplicationHost ~= nil then
    local host = self.pcApplicationHost
    host:cancel(reason)
  end
  error(reason, 0)
end

-- A word editor presentation failure freezes the field, so release the
-- foreground script environment that owns its task before publishing the
-- terminal error.
---@param reason string
function FieldRuntime:failEasyChatPresentation(reason)
  assert(type(reason) == "string" and reason ~= "", "word editor presentation failure needs a diagnostic")
  local scheduler = assert(self.session.scriptScheduler, "field session owns its script scheduler")
  local environmentId = scheduler:foregroundEnvironmentId()
  if environmentId ~= nil then
    scheduler:cancelEnvironment(environmentId, reason)
  elseif self.easyChatScriptHost ~= nil then
    local host = self.easyChatScriptHost
    host:cancel(reason)
  end
  error(reason, 0)
end

function FieldRuntime:_captureManualSaveFromMenu()
  return assert(self.saveCoordinator, "field runtime has no save coordinator"):captureManual()
end

-- Composes the one authoritative dex owner before the mon service: the
-- generated catalog loads from the already-ready data scope, then Continue
-- restores the nested bucket (even when absent) with story flag 107 and
-- profile seeds while a new game starts empty. The profile National
-- compatibility value reconciles from the owner before dependent services
-- compose; valid v2 flags stay authoritative and never rewrite the story
-- flag. A failed construction or migration fails the boot instead of
-- leaving a partially composed field.
---@param loadedGame table<string, unknown>?
---@param monRoot table<string, unknown>
---@param cacheFs table<string, unknown> CacheFs-shaped
function FieldRuntime:_composePokedex(loadedGame, monRoot, cacheFs)
  local PokedexCache = require("libs.assets.src.PokedexCache")
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  local catalog = PokedexCache.loadCatalog(cacheFs)
  self.pokedexCatalog = catalog
  local speciesRefs = {}
  for key in pairs(assert(monRoot.species, "mon catalog root carries its species")) do
    speciesRefs[key] = true
  end
  local refs = {
    species = speciesRefs,
    monCatalog = self.monCatalog,
    pokedexCatalog = catalog,
    nativeLanguage = self.monLanguage,
  }
  if loadedGame ~= nil then
    refs.legacyFlags = {
      dexEnabled = self.eventState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_GOT_POKEDEX),
      nationalDex = self.playerData.profile.nationalDex == true,
      enabledInternational = false,
      canDetectForms = false,
    }
    self.dexKnowledge = PokedexKnowledge.restore(loadedGame.pokedex, refs)
  else
    self.dexKnowledge = PokedexKnowledge.new(refs)
  end
  self.playerData.profile.nationalDex = self.dexKnowledge:hasNationalDex()
end

-- Composes the one authoritative shared word owner beside dex knowledge:
-- the immutable generated catalog loads from the already-ready data
-- scope once monLanguage exists, then Continue restores the nested
-- bucket (even when absent) while a new game starts from source
-- defaults. A failed construction or restore fails the boot instead of
-- leaving the field without its live word owner.
---@param loadedGame table<string, unknown>?
---@param cacheFs table<string, unknown> CacheFs-shaped
function FieldRuntime:_composeEasyChat(loadedGame, cacheFs)
  local EasyChatCache = require("libs.assets.src.EasyChatCache")
  local EasyChatState = require("libs.hgss.src.save.EasyChatState")
  local EasyChatCatalog = require("libs.hgss.src.ui.EasyChatCatalog")
  local catalog = EasyChatCatalog.new(EasyChatCache.loadCatalog(cacheFs))
  self.easyChatCatalog = catalog
  local language = assert(self.monLanguage, "field runtime composes word state after the mon language is known")
  if loadedGame ~= nil then
    self.easyChatState = EasyChatState.restore(loadedGame.easyChat, language, catalog)
  else
    self.easyChatState = EasyChatState.new(language, catalog)
  end
end

-- Composes the one authoritative game-stats owner beside dex knowledge:
-- Continue restores the nested bucket (even when absent, through the
-- bucket's nil->initial migration) while a new game starts empty. A
-- failed construction or migration fails the boot instead of leaving
-- the runtime without its live stats owner.
---@param loadedGame table<string, unknown>?
---@param monRoot table<string, unknown>
function FieldRuntime:_composeGameStats(loadedGame, monRoot)
  local GameStats = require("libs.hgss.src.mons.GameStats")
  local speciesRefs = {}
  for key in pairs(assert(monRoot.species, "mon catalog root carries its species")) do
    speciesRefs[key] = true
  end
  local refs = { species = speciesRefs }
  if loadedGame ~= nil then
    self.gameStats = GameStats.restore(loadedGame.gameStats, refs)
  else
    self.gameStats = GameStats.new(refs)
  end
end

-- Composes the battle-era persistent owners: roamer and encounter state,
-- restored from the loaded battle-era buckets or started fresh. Reference
-- sets come from the same mon root and world catalog the runtime boots
-- from, so selected custom content resolves exactly as validation sees it.
---@param loadedGame table<string, unknown>?
---@param monRoot table<string, unknown>
---@param world table<string, unknown>
---@param compiledEncounters table<string, unknown> the compiled encounter catalog
function FieldRuntime:_composeBattleState(loadedGame, monRoot, world, compiledEncounters)
  local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
  local speciesRefs = {}
  for key in pairs(assert(monRoot.species, "mon catalog root carries its species")) do
    speciesRefs[key] = true
  end
  local mapRefs = {}
  for mapId in pairs(assert(world.byId, "world catalog carries its map index")) do
    mapRefs[mapId] = true
  end
  local mapIdBySymbol = assert(world.bySymbol, "world catalog carries its symbol index")
  local roamerData = assert(
    type(compiledEncounters) == "table" and compiledEncounters.roamers,
    "the compiled encounter catalog carries its roamer graph"
  )
  local refs = { species = speciesRefs, maps = mapRefs, mapIdBySymbol = mapIdBySymbol }
  if loadedGame ~= nil and loadedGame.encounters ~= nil then
    self.roamerState = HgssRoamerState.restore(loadedGame.encounters, refs, roamerData)
  else
    self.roamerState = HgssRoamerState.new({
      records = {},
      species = speciesRefs,
      maps = mapRefs,
      native = roamerData,
      mapIdBySymbol = mapIdBySymbol,
    })
  end
  self.battleCoordinator = FieldBattleCoordinator.new(self)
  self.pendingEncounterId = nil
  self.pendingEncounter = nil
  self.pendingWarpForm = nil
  -- The narrow battle host for script battle tasks: launch, status, and
  -- result reads delegate to the runtime's battle face. The adapter (not
  -- the whole runtime) is what scheduler services carry.
  local owner = self
  local function hostLaunch(_, spec)
    local launchId = owner:launchBattle(spec)
    -- A launch issued through the script battle host belongs to its
    -- launching task: its defeat routes to the authored continuation,
    -- never to automatic recovery. Direct and step launches keep the
    -- automatic route. The mark lands synchronously before any poll.
    owner.battleCoordinator:markScriptedLaunch(launchId)
    return launchId
  end
  local function hostStatus(_, launchId)
    return owner:battleStatus(launchId)
  end
  local function hostResult(_)
    return owner:lastBattleResult()
  end
  self._battleHost = { launchBattle = hostLaunch, battleStatus = hostStatus, lastBattleResult = hostResult }
end

-- Composes the one companion owner: durable state restored with generated
-- catalog references (or started fresh with the session seed when the
-- record predates the bucket), the live draw pair continuing the persisted
-- seeds, and the civil calendar adapter over the state checkpoint. The
-- runtime holds the state as a required owner; the draw pair and calendar
-- are transient adapters released at field shutdown. Field samples reach
-- the calendar through explicit observations, never through polling here.
---@param loadedGame table<string, unknown>?
---@param cacheFs table<string, unknown> CacheFs-shaped
function FieldRuntime:_composePokegear(loadedGame, cacheFs)
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local manifest = PokegearCache.loadManifest(cacheFs)
  assert(
    type(manifest) == "table" and type(manifest.catalog) == "table",
    "companion composition needs its contact catalog"
  )
  local refs = { catalog = manifest.catalog }
  local bucket = loadedGame ~= nil and loadedGame.pokegear or nil
  if bucket ~= nil then
    assert(type(bucket) == "table" and type(bucket.random) == "table", "saved companion state carries its draw seeds")
    self.pokegearState = PokegearState.restore(bucket, refs)
    self.pokegearRandom = PokegearRandom.restore(bucket.random)
  else
    local seed = self:_pokegearSeed()
    self.pokegearState = PokegearState.new({ seed = seed }, refs)
    self.pokegearRandom = PokegearRandom.new(seed)
  end
  local contacts = assert(manifest.catalog.contacts, "companion composition reads its compiled contacts")
  local momKey = nil
  for _, entry in
    ipairs(contacts --[[@as table[] ]])
  do
    local contact = entry --[[@as table<string, unknown>]]
    if contact.id == 0 then
      assert(contact.family == "mother", "native contact zero is Mom")
      assert(momKey == nil, "the compiled phonebook has one native Mom contact")
      assert(type(contact.key) == "string" and contact.key ~= "", "native Mom carries its semantic key")
      momKey = contact.key --[[@as string]]
    end
  end
  local nativeMom = assert(momKey, "the compiled phonebook has native contact zero")
  local phone = self.pokegearState:readPhone()
  assert(type(phone) == "table" and type(phone.contacts) == "table", "field composition reads phonebook state")
  if phone.contacts[nativeMom] == nil then
    self.pokegearState:registerContact(nativeMom)
  end

  local sourceSkins = assert(manifest.skins, "companion composition reads its six compiled skins")
  local unlockedSkins = {}
  for skin = 0, 5 do
    assert(sourceSkins[skin] ~= nil, "the compiled Configure palette includes every source skin")
    unlockedSkins[#unlockedSkins + 1] = skin
  end
  local preferences = self.pokegearState:readPreferences()
  assert(type(preferences) == "table", "field composition reads companion preferences")
  local savedSkins = assert(preferences.unlockedSkins, "field composition reads saved Configure skins")
  local sameSkins = #savedSkins == #unlockedSkins
  if sameSkins then
    for index, skin in ipairs(unlockedSkins) do
      if savedSkins[index] ~= skin then
        sameSkins = false
        break
      end
    end
  end
  if not sameSkins then
    self.pokegearState:setPreference("unlockedSkins", unlockedSkins)
  end
  self.pokegearCalendar = PokegearCalendar.new(self.pokegearState)
  self.pokegearManifest = manifest
  self.pokegearCatalog = manifest.catalog
end

-- Composes the one concrete companion feature over the durable owners:
-- the screen factory, script host, incoming-call owner, and radio
-- effect reader. Runs once after state, calendar, streams, clock, and
-- audio exist; script composition consumes the bundle below. A failed
-- composition releases nothing else: boot stays binary through the
-- runtime's release path.
-- Builds the shared phone greeting references from the compiled contact
-- catalog: one msg.hgss identity per native contact from that contact's
-- message bank and greeting number, plus the shared lease token. The
-- token carries the first catalogued caller's real reference: call
-- sessions freeze the identity but never display it, and per-contact text
-- resolves at call time through the message provider behind the same
-- identity language the script dialogue host already speaks. The trailing
-- number is the source greeting (phone-script) number: it resolves as a
-- direct bank entry only where the phone script table maps the selector
-- onto itself, and call-time resolution otherwise fails loudly with its
-- bank/entry evidence instead of inventing text. A contact without
-- compiled bank or greeting facts fails the boot instead of installing a
-- fabricated greeting.
---@param catalog table<string, unknown> the borrowed compiled contact catalog
---@param provider table<string, unknown> the borrowed field message provider
---@param profile table<string, unknown> the native player profile
---@param fontDef table<string, unknown> the generated field font
---@param runtime table<string, unknown> the live field runtime
---@return table<string, string> contact key to greeting reference, with .greeting as the lease token
local function phoneGreetingRefs(catalog, provider, profile, fontDef, runtime)
  local Errors = require("libs.errors.src.Errors")
  local ScriptErrors = require("libs.script.src.errors")
  local contacts = assert(catalog.contacts, "companion feature needs its compiled contacts")
  assert(type(contacts) == "table", "companion greeting references read the compiled contacts")
  assert(type(provider) == "table", "phone text resolves through the field message provider")
  assert(type(profile) == "table" and type(profile.name) == "string", "phone text reads the live player profile")
  assert(type(fontDef) == "table", "phone text uses the generated field font")
  assert(type(runtime) == "table", "phone substitutions read the live field runtime")
  local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
  local phoneLabels = assert(catalog.landmarkLabels, "phone catalog carries landmark message references")
  local messages = {}
  local contactsByKey = {}
  local firstRef = nil
  -- Maps a map header identity onto its native map section for caller
  -- landmarks, mirroring MapHeader_GetMapSec behind slot 3.
  ---@param headerId integer map header identity
  ---@return integer map section
  local function headerMapSection(headerId)
    assert(type(headerId) == "number" and headerId % 1 == 0, "caller landmarks read header identities")
    local okMaps, maps = pcall(require, "romdump.src.catalog.hgss.maps")
    assert(okMaps and type(maps) == "table", "caller landmarks read the static map-header catalog")
    local byId = (maps --[[@as table<string, unknown>]]).byId
    assert(type(byId) == "table", "caller landmarks read indexed map headers")
    local header = (byId --[[@as table<integer, unknown>]])[headerId]
    assert(type(header) == "table", "caller landmarks need a header for the caller map")
    local section = (header --[[@as table<string, unknown>]]).mapSectionNativeId
    assert(type(section) == "number" and section % 1 == 0, "caller landmarks read native map sections")
    return section
  end
  for _, record in
    ipairs(contacts --[[@as table<integer, unknown>]])
  do
    local contact = record --[[@as table<string, unknown>]]
    local key = contact.key
    local bank = contact.messageBank
    local entry = contact.phoneScriptIfLocal
    assert(type(key) == "string" and key ~= "", "companion greeting references name their contact")
    assert(
      type(bank) == "number" and bank % 1 == 0 and bank >= 0,
      "companion greeting references read the compiled message bank for " .. key
    )
    assert(
      type(entry) == "number" and entry % 1 == 0 and entry >= 0,
      "companion greeting references read the compiled greeting number for " .. key
    )
    contactsByKey[
      key --[[@as string]]
    ] = contact
    local ref = string.format("msg.hgss.%d.%d", bank, entry)
    messages[
      key --[[@as string]]
    ] = ref
    if firstRef == nil then
      firstRef = ref
    end
  end
  assert(firstRef ~= nil, "companion greeting references need at least one compiled contact")
  messages.greeting = firstRef
  -- Per-call substitution staging behind generic and word scripts:
  -- the conversation engine draws the chatter species pair and the
  -- word pick before the text prints, and the resolvers below read
  -- them back by caller. One foreground call owns the lease, so one
  -- staged entry at a time is exact.
  messages.speciesStaging = {}
  messages.wordStaging = {}
  ---@param contactKey string
  ---@param resolveMessage fun(bankId: integer, messageId: integer, contactKey: string): table<string, unknown>
  ---@return string word display text
  local function wordTextFor(contactKey, resolveMessage)
    local staging = assert(messages.wordStaging, "word scripts stage their pick before the text prints")
    local stored = (staging --[[@as table<string, unknown>]])[contactKey]
    assert(type(stored) == "table", "word scripts stage their pick for the caller")
    local record = stored --[[@as table<string, unknown>]]
    local base, pick = record.base, record.pick
    assert(type(base) == "string" and type(pick) == "number", "word picks carry their bank reference and draw")
    local PhoneGreetingSets = require("game.hgss.src.pokegear.PhoneGreetingSets")
    local bank, entry = PhoneGreetingSets.wordEntry(base --[[@as string]], pick --[[@as integer]])
    return resolveMessage(bank, entry, contactKey).text
  end
  ---@param contactKey string
  ---@param which string "a" for the party mon, "b" for the encounter mon
  ---@return string species display name
  local function speciesNameFor(contactKey, which)
    local staging = assert(messages.speciesStaging, "generic chatter stages its species pair before the text prints")
    local pair = (staging --[[@as table<string, unknown>]])[contactKey]
    assert(type(pair) == "table", "generic chatter stages species for its caller")
    local key = (pair --[[@as table<string, unknown>]])[which]
    assert(type(key) == "string" and key ~= "", "generic chatter stages species keys")
    local monCatalog = assert(runtime.monCatalog, "species names resolve through the domain mon catalog")
    local species = monCatalog:species(key --[[@as string]])
    assert(type(species) == "table" and type(species.name) == "string", "species keys resolve names")
    return species.name --[[@as string]]
  end
  local function resolve(bankId, messageId, contactKey)
    local acquire = provider.acquireBank --[[@as fun(self: table<string, unknown>, bankId: integer): table<string, unknown>? , Errors.Error?]]
    local release = provider.releaseBank --[[@as fun(self: table<string, unknown>, bankId: integer)]]
    local get = provider.get --[[@as fun(self: table<string, unknown>, bankId: integer, messageId: integer): table<string, unknown>? , Errors.Error?]]
    local format = provider.format --[[@as fun(self: table<string, unknown>, template: table<string, unknown>, context: table<string, unknown>, resolvers: table<integer, function>): table<string, unknown>]]
    assert(
      type(acquire) == "function"
        and type(release) == "function"
        and type(get) == "function"
        and type(format) == "function"
    )
    local bank, acquireError = acquire(provider, bankId)
    assert(type(bank) == "table", "phone text bank " .. bankId .. " is acquired: " .. tostring(acquireError))
    local function formatMessage()
      local template, getError = get(provider, bankId, messageId)
      assert(
        type(template) == "table",
        "phone message " .. bankId .. "." .. messageId .. " exists: " .. tostring(getError)
      )
      local resolvers = {}
      local templateTokens = (template --[[@as table<string, unknown>]]).tokens
      assert(type(templateTokens) == "table", "phone templates carry tokens")
      for _, token in ipairs(templateTokens) do
        if token.kind == "substitution" and token.control == FieldMessageText.TRNAME then
          local function resolveTrainerName()
            return assert(FieldMessageProvider.asciiGlyphTokens(profile.name, fontDef))
          end
          resolvers[token.control] = resolveTrainerName
        elseif
          token.kind == "substitution"
          and token.control >= FieldMessageText.STRVAR_1
          and token.control < FieldMessageText.STRVAR_1 + 0x100
        then
          assert(type(contactKey) == "string", "phone substitutions identify their caller")
          -- The buffer slot is the marker's first argument, never the
          -- control low byte: the retail encoder folds that argument's
          -- predecessor into the command (msgenc MessagesEncoder), while
          -- expansion indexes the buffered fields by the first argument
          -- (message_format StringExpandPlaceholders via
          -- MsgArray_ControlCodeGetField(cstr, 0)). PhoneCall buffers the
          -- player name at 0, the caller name at 1, and the player and
          -- caller landmarks at 2 and 3
          -- (PhoneCall_InitMsgDataAndBufferNames), so {STRVAR_1 3, 0, 0}
          -- names the player behind slot zero. One resolver per control
          -- dispatches on its call-time arguments, so markers sharing a
          -- control but naming different slots each resolve.
          local function resolveSourceSubstitution(_, args, _)
            local slot = type(args) == "table" and args[1] or nil
            local text = nil
            if slot == 0 then
              text = profile.name
            elseif slot == 1 then
              local contact = assert(contactsByKey[contactKey], "caller-name substitution resolves a catalog contact")
              text = resolve(contact.messageBank, 0).text
            elseif slot == 4 then
              -- Word-kind scripts buffer the drawn bank entry at slot 4
              -- (BufferString slot 4 behind WORD side effects).
              text = wordTextFor(contactKey, resolve)
            elseif slot == 10 then
              -- Slot 10 is the Mom balance behind dynamic Mother entries
              -- and the caller-party species behind generic chatter.
              -- Static lines never address it for Mother, so the static
              -- path carries no balance and keeps the historical zero.
              local contact = assert(contactsByKey[contactKey], "slot-ten substitution resolves a catalog contact")
              if contact.family == "mother" then
                text = "0"
              else
                text = speciesNameFor(contactKey, "a")
              end
            elseif slot == 11 then
              -- Slot 11 is the map encounter species behind generic
              -- chatter (BufferSpeciesName slot 11).
              text = speciesNameFor(contactKey, "b")
            elseif slot == 2 or slot == 3 then
              local mapSection = nil
              if slot == 2 then
                local session = runtime.session
                local currentMap = type(session) == "table" and session.currentMap or runtime.runtimeMap
                assert(type(currentMap) == "table", "player landmark substitution reads the current map")
                mapSection = currentMap.mapSectionNativeId
              else
                local contact =
                  assert(contactsByKey[contactKey], "caller landmark substitution resolves a catalog contact")
                mapSection = headerMapSection(contact.mapId)
              end
              assert(
                type(mapSection) == "number" and mapSection % 1 == 0,
                "landmark substitutions use native map sections"
              )
              local landmarkBankId, landmarkEntryId = phoneLabels.bank, mapSection
              local acquireLandmark = provider.acquireBank --[[@as fun(self: table<string, unknown>, bankId: integer): table<string, unknown>? , Errors.Error?]]
              local releaseLandmark = provider.releaseBank --[[@as fun(self: table<string, unknown>, bankId: integer)]]
              local landmarkBank =
                assert(acquireLandmark(provider, landmarkBankId), "the native landmark bank is available")
              local landmarkCount = landmarkBank.messageCount --[[@as integer]]
              releaseLandmark(provider, landmarkBankId)
              if landmarkEntryId == 0 or landmarkEntryId >= landmarkCount then
                landmarkBankId, landmarkEntryId = phoneLabels.fallbackBank, phoneLabels.fallbackEntry
              end
              text = resolve(landmarkBankId, landmarkEntryId, contactKey).text
            end
            if text == nil then
              return nil
            end
            return assert(FieldMessageProvider.asciiGlyphTokens(text, fontDef))
          end
          resolvers[token.control] = resolveSourceSubstitution
        end
      end
      return format(provider, template, {}, resolvers)
    end
    local ok, result = pcall(formatMessage)
    release(provider, bankId)
    if not ok then
      error(result, 0)
    end
    assert(
      not result.hadUnresolvedSubstitutions,
      "phone message substitutions resolve through the field profile: " .. result.text
    )
    return result
  end
  ---@param _ table<string, unknown>
  ---@param contactKey string
  ---@return string resolved caller name
  local function resolveName(_, contactKey)
    local contact = assert(contactsByKey[contactKey], "phone name resolves a catalog contact")
    local name = assert(contact.name, "phone contact carries its source name reference")
    local formatted = resolve(name.bank, name.entry, contactKey)
    return formatted.text
  end
  messages.resolveName = resolveName
  ---@param _ table<string, unknown>
  ---@param contactKey string
  ---@return string resolved class name
  local function resolveClass(_, contactKey)
    local contact = assert(contactsByKey[contactKey], "phone class resolves a catalog contact")
    local class = assert(contact.class, "phone contact carries its source class rule")
    if class.kind == "blank" then
      return ""
    end
    return resolve(class.bank, class.entry, contactKey).text
  end
  messages.resolveClass = resolveClass
  ---@param _ table<string, unknown>
  ---@param contactKey string
  ---@param scriptId integer native script index
  ---@return table<string, unknown> formatted message text
  local function resolveLine(_, contactKey, scriptId)
    local contact = assert(contactsByKey[contactKey], "phone dialogue resolves a catalog contact")
    local definitions = catalog.callDefinitions
    assert(type(definitions) == "table", "phone dialogue reads the compiled native script table")
    local definition = assert(definitions[scriptId], "phone dialogue uses a compiled native script")
    local gender = profile.gender == 0 and "male" or profile.gender == 1 and "female" or nil
    assert(gender ~= nil, "phone dialogue has a native player gender")
    local message = definition[gender]
    if type(message) ~= "table" or message.bank ~= contact.messageBank then
      local failure = Errors.new(
        ScriptErrors.FEATURE_UNAVAILABLE,
        "native phone script belongs to a different caller bank",
        { contact = contactKey, script = scriptId, bank = contact.messageBank }
      )
      error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
    end
    return resolve(message.bank, message.entry, contactKey)
  end
  messages.resolveLine = resolveLine
  -- The source time-of-day greeting behind static calls: bank 640
  -- indexed by the contact greeting set, the call time band, the
  -- direction, and the player gender, exactly like
  -- PhoneCall_PrintGreeting over sGreetingMsgIDs. A 0xFF set or an
  -- unknown contact skips the greeting with nil instead of text.
  ---@param _ table<string, unknown>
  ---@param contactKey string
  ---@param timeOfDay integer 0 morning, 1 day, 2 night
  ---@param isIncoming boolean
  ---@return table<string, unknown>? formatted greeting text, nil when the caller skips it
  local function resolveCallGreeting(_, contactKey, timeOfDay, isIncoming)
    local contact = contactsByKey[contactKey]
    if type(contact) ~= "table" then
      return nil
    end
    local set = (contact --[[@as table<string, unknown>]]).greetingMsgSet
    if type(set) ~= "number" or set == 255 then
      return nil
    end
    assert(timeOfDay == 0 or timeOfDay == 1 or timeOfDay == 2, "call greetings read the call time band")
    local gender = profile.gender == 0 and 0 or profile.gender == 1 and 1 or nil
    assert(gender ~= nil, "call greetings have a native player gender")
    local GreetingSets = require("game.hgss.src.pokegear.PhoneGreetingSets")
    local entry = GreetingSets.entry(set, timeOfDay, isIncoming == true, gender)
    assert(type(entry) == "number", "call greetings resolve a bank 640 entry")
    return resolve(640, entry, contactKey)
  end
  messages.resolveCallGreeting = resolveCallGreeting
  -- Direct bank-entry reader behind the dynamic Mother flow: intro
  -- 664.(7+param), prompt 22/23/24/27/28, gift-full 21, result 25/26.
  -- Entries resolve through the caller's own bank with the same player
  -- and landmark substitutions as static lines, plus the Mom balance
  -- integer slot (BufferIntegerAsString slot 10) when the caller passes
  -- it. Retail fallback identical: caller-landmark id 0 → bank 280
  -- entry 2 ("Faraway place").
  ---@param _ table<string, unknown>
  ---@param contactKey string
  ---@param entry integer bank entry number
  ---@param opts table<string, unknown>? { balance: integer? }
  ---@return table<string, unknown> formatted message text
  local function resolveContactEntry(_, contactKey, entry, opts)
    local contact = assert(contactsByKey[contactKey], "phone entry resolves a catalog contact")
    assert(type(entry) == "number" and entry % 1 == 0, "phone entries name their bank entry")
    local balance = type(opts) == "table" and opts.balance or nil
    if balance ~= nil then
      assert(type(balance) == "number" and balance % 1 == 0, "phone balance formats its integer slot")
    end
    -- Dynamic Bill stages the active box name and free count for the
    -- slot-10/11 substitutions behind GearPhoneCall_Bill case 2
    -- (BufferString slot 10, BufferIntegerAsString slot 11).
    local boxName = type(opts) == "table" and opts.boxName or nil
    if boxName ~= nil then
      assert(type(boxName) == "string" and boxName ~= "", "phone box names format their string slot")
    end
    local freeCount = type(opts) == "table" and opts.freeCount or nil
    if freeCount ~= nil then
      assert(type(freeCount) == "number" and freeCount % 1 == 0, "phone box counts format their integer slot")
    end
    -- Dynamic Kurt stages the ball item and handed quantity for the
    -- slot-10/11 substitutions behind GearPhoneCall_Kurt case 1
    -- (BufferItemName slot 10, BufferIntegerAsString slot 11).
    local ballItem = type(opts) == "table" and opts.ballItem or nil
    if ballItem ~= nil then
      assert(type(ballItem) == "string" and ballItem ~= "", "phone ball items format their string slot")
    end
    local kurtCount = type(opts) == "table" and opts.kurtCount or nil
    if kurtCount ~= nil then
      assert(type(kurtCount) == "number" and kurtCount % 1 == 0, "phone kurt counts format their integer slot")
    end
    -- Dynamic Day Care Man stages both stabled nicknames for slots
    -- 10/11 behind the whole call, exactly like the selection-time
    -- buffers; the Lady re-buffers one nickname and growth per
    -- growth report instead.
    local nickA = type(opts) == "table" and opts.nickA or nil
    if nickA ~= nil then
      assert(type(nickA) == "string" and nickA ~= "", "phone nicknames format their string slot")
    end
    local nickB = type(opts) == "table" and opts.nickB or nil
    if nickB ~= nil then
      assert(type(nickB) == "string" and nickB ~= "", "phone nicknames format their string slot")
    end
    local nickname = type(opts) == "table" and opts.nickname or nil
    if nickname ~= nil then
      assert(type(nickname) == "string" and nickname ~= "", "phone nicknames format their string slot")
    end
    local growth = type(opts) == "table" and opts.growth or nil
    if growth ~= nil then
      assert(type(growth) == "number" and growth % 1 == 0, "phone growth formats its integer slot")
    end
    -- Dynamic Oak stages the seen and owned counts for slots 5/6
    -- behind the evaluation message, like BufferIntegerAsString in
    -- GearPhoneCall_ProfOak case 3.
    local seenCount = type(opts) == "table" and opts.seenCount or nil
    if seenCount ~= nil then
      assert(type(seenCount) == "number" and seenCount % 1 == 0, "phone dex counts format their integer slot")
    end
    local ownedCount = type(opts) == "table" and opts.ownedCount or nil
    if ownedCount ~= nil then
      assert(type(ownedCount) == "number" and ownedCount % 1 == 0, "phone dex counts format their integer slot")
    end
    local areaNames = type(opts) == "table" and opts.areaNames or nil
    if areaNames ~= nil then
      assert(type(areaNames) == "table", "phone area names stage their string slots")
    end
    local bankId, messageId = contact.messageBank, entry
    local acquire = provider.acquireBank
    local release = provider.releaseBank
    local get = provider.get
    local format = provider.format
    assert(acquire(provider, bankId), "phone entry bank is available")
    local function formatEntry()
      local template = assert(get(provider, bankId, messageId), "phone entry exists")
      local resolvers = {}
      local templateTokens = (template --[[@as table<string, unknown>]]).tokens
      assert(type(templateTokens) == "table", "phone templates carry tokens")
      for _, token in ipairs(templateTokens) do
        if token.kind == "substitution" and token.control == FieldMessageText.TRNAME then
          local function resolveTrainerName()
            return assert(FieldMessageProvider.asciiGlyphTokens(profile.name, fontDef))
          end
          resolvers[token.control] = resolveTrainerName
        elseif
          token.kind == "substitution"
          and token.control >= FieldMessageText.STRVAR_1
          and token.control < FieldMessageText.STRVAR_1 + 0x100
        then
          -- The buffer slot is the marker's first argument, never the
          -- control low byte (see the static path above for the source
          -- rule). Mother buffers her savings balance at field 10
          -- (BufferIntegerAsString in phone_scripts_mother), so
          -- {STRVAR_1 55, 10, 0} reads the balance behind slot ten.
          local function resolveSourceSubstitution(_, args, _)
            local slot = type(args) == "table" and args[1] or nil
            local text = nil
            if slot == 0 then
              text = profile.name
            elseif slot == 1 then
              local contactRecord = assert(contactsByKey[contactKey])
              text = resolve(contactRecord.messageBank, 0, contactKey).text
            elseif slot == 5 then
              -- Slot 5 is the seen count behind dynamic Oak
              -- evaluations; other families leave it unresolved so
              -- the provider reports the missing substitution.
              if contact.family == "oak" and seenCount ~= nil then
                text = tostring(seenCount)
              end
            elseif slot == 6 then
              -- Slot 6 is the owned count behind dynamic Oak
              -- evaluations.
              if contact.family == "oak" and ownedCount ~= nil then
                text = tostring(ownedCount)
              end
            elseif slot == 2 or slot == 3 then
              local mapSection = nil
              if slot == 2 then
                local session = runtime.session
                local currentMap = type(session) == "table" and session.currentMap or runtime.runtimeMap
                assert(type(currentMap) == "table", "player landmark substitution reads the current map")
                mapSection = currentMap.mapSectionNativeId
              else
                local contactRecord = assert(contactsByKey[contactKey])
                mapSection = headerMapSection(contactRecord.mapId)
              end
              local landmarkBankId, landmarkEntryId = phoneLabels.bank, mapSection
              local landmarkBank = assert(provider.acquireBank(phoneLabels.bank))
              local landmarkCount = landmarkBank.messageCount
              provider.releaseBank(phoneLabels.bank)
              if landmarkEntryId == 0 or landmarkEntryId >= landmarkCount then
                landmarkBankId, landmarkEntryId = phoneLabels.fallbackBank, phoneLabels.fallbackEntry
              end
              text = resolve(landmarkBankId, landmarkEntryId, contactKey).text
            elseif slot == 10 or slot == 12 or slot == 13 or slot == 14 then
              if contact.family == "bill" and boxName ~= nil then
                text = boxName
              elseif contact.family == "kurt" and ballItem ~= nil then
                local item = assert(runtime.itemCatalog, "phone ball names resolve through the item catalog")
                local definition = item:item(ballItem --[[@as string]])
                assert(
                  type(definition) == "table" and type((definition --[[@as table<string, unknown>]]).name) == "string",
                  "phone ball items resolve display names"
                )
                text = (definition --[[@as table<string, unknown>]]).name --[[@as string]]
              elseif contact.family == "daycare" and nickA ~= nil then
                text = nickA
              elseif contact.family == "daycare" and nickname ~= nil then
                text = nickname
              elseif contact.family == "baoba" and areaNames ~= nil then
                text = areaNames[slot - 9]
              else
                text = tostring(balance or 0)
              end
            elseif slot == 11 then
              -- Slot 11 is the free box count behind dynamic Bill
              -- status lines, the handed quantity behind Kurt, the
              -- second nickname behind the Day Care Man pair report,
              -- the growth behind Lady reports, and the second area
              -- name behind Baoba; other families leave it unresolved
              -- so the provider reports the missing substitution.
              if contact.family == "bill" and freeCount ~= nil then
                text = tostring(freeCount)
              elseif contact.family == "kurt" and kurtCount ~= nil then
                text = tostring(kurtCount)
              elseif contact.family == "daycare" and nickB ~= nil then
                text = nickB
              elseif contact.family == "daycare" and growth ~= nil then
                text = tostring(growth)
              elseif contact.family == "baoba" and areaNames ~= nil then
                text = areaNames[2]
              end
            end
            if text == nil then
              return nil
            end
            return assert(FieldMessageProvider.asciiGlyphTokens(text, fontDef))
          end
          resolvers[token.control] = resolveSourceSubstitution
        end
      end
      return format(provider, template, {}, resolvers)
    end
    local ok, result = pcall(formatEntry)
    release(provider, bankId)
    if not ok then
      error(result, 0)
    end
    assert(not result.hadUnresolvedSubstitutions, "phone entry substitutions resolve through the field profile")
    return result
  end
  messages.resolveContactEntry = resolveContactEntry
  -- The narrow bank271 UI text reader behind live calls: choice labels,
  -- the choice tooltip, and the three hangup messages. Both the menu
  -- card and direct scripted calls share this facade, so both resolve
  -- through the same provider acquire/format/release round trip. Only
  -- the entries the call UI actually reads are admitted; anything else
  -- is a programming error, never a default label.
  ---@param _ table<string, unknown>
  ---@param entryId integer bank271 entry number
  ---@return table<string, unknown> formatted message text
  local function resolvePhoneUiMessage(_, entryId)
    local known = type(entryId) == "number"
      and entryId % 1 == 0
      and ((entryId >= 8 and entryId <= 19) or entryId == 22 or (entryId >= 30 and entryId <= 35) or entryId == 37)
    if not known then
      local failure = Errors.new(
        ScriptErrors.FEATURE_UNAVAILABLE,
        "phone UI text names a known bank271 entry, got " .. tostring(entryId),
        { entry = entryId }
      )
      error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
    end
    return resolve(271, entryId)
  end
  messages.resolvePhoneUiMessage = resolvePhoneUiMessage
  return messages
end

---@param boot table<string, unknown>
function FieldRuntime:_composePokegearFeature(boot)
  local PokegearComposition = require("game.hgss.src.pokegear.PokegearComposition")
  local manifest = assert(self.pokegearManifest, "companion feature needs its compiled manifest")
  local catalog = assert(self.pokegearCatalog, "companion feature needs its contact catalog")
  local bundle = PokegearComposition.compose(self, {
    state = assert(self.pokegearState, "companion feature needs its durable state"),
    catalog = catalog,
    assets = manifest,
    clock = assert(self.localClock, "companion feature needs its civil clock"),
    audio = self.audio or boot.audioService,
    messages = phoneGreetingRefs(catalog, self.messageProvider, self.playerData.profile, self.fontDef, self),
  })
  self.pokegear = bundle
  self.pokegearApplications = assert(bundle.scriptHost, "companion feature carries its script host")
  self.incomingCalls = assert(bundle.incoming, "companion feature carries its incoming owner")
end

-- The companion seed boundary: the validated trainer identity when the
-- profile carries one, otherwise a deterministic hash of the save id.
-- Never host time, so the same game always resumes the same streams.
---@return integer
function FieldRuntime:_pokegearSeed()
  local profile = self.playerData ~= nil and self.playerData.profile or nil
  local trainerId = type(profile) == "table" and profile.trainerId or nil
  if type(trainerId) == "number" and trainerId % 1 == 0 and trainerId >= 0 then
    return math.floor(trainerId % 4294967296)
  end
  local saveId = type(self.saveId) == "string" and self.saveId or ""
  local hash = 0
  for index = 1, #saveId do
    hash = (hash * 31 + saveId:byte(index)) % 4294967296
  end
  return hash
end

-- Attaches the presentation port used by field-owned battles.
---@param port table<string, unknown>
function FieldRuntime:attachBattlePresentation(port)
  self.battleCoordinator:attachBattlePresentation(port)
end

-- Builds the detached scenario for one launch request from the prepared
-- encounter (consuming a matching pending preparation exactly once), the
-- resolved trainer party, or an explicit staged scenario. Native trainer
-- identities resolve through the composed trainer catalog and materializer
-- before shaping; explicit caller-authored parties still ride through
-- untouched, and unknown trainer identities fail loudly.
--
-- The follower's party slot rides the scenario when one walks behind the
-- player (BattleSystem_GetFollowMonSlot): send-outs onto that slot skip
-- their ball throw, matching Task_FollowMonSlideIn/SendOut. No follower
-- out leaves the field absent, matching the native 0xFF default.
---@param request table<string, unknown>
---@return table<string, unknown> detached scenario fragment
function FieldRuntime:buildBattleScenario(request)
  assert(type(request) == "table" and type(request.kind) == "string", "scenario builds need their request")
  local scenario = self:_buildBattleScenarioFragment(request)
  local followMonSlot = self:_launchFollowMonSlot()
  local payload = request.payload
  local selector = type(payload) == "table" and (payload --[[@as table<string, unknown>]]).followSlot or nil
  if
    type(selector) == "number"
    and selector ~= 0
    and (payload --[[@as table<string, unknown>]]).partner == nil
  then
    -- src/encounter.c::SetupAndStartTrainerBattle: a deliberate send-out
    -- selector names the follower's own party slot for the position the
    -- battle type selects (the single player position). A multi battle names
    -- the ally position instead, which never shares the player's roster here,
    -- so only the single-opponent branch rewrites the player's own send-out.
    followMonSlot = 0
  end
  if type(followMonSlot) == "number" then
    scenario.followMonSlot = followMonSlot
  end
  return scenario
end

---@param request table<string, unknown> admitted source battle request
---@return table<string, unknown> detached scenario fragment without field send-out facts
function FieldRuntime:_buildBattleScenarioFragment(request)
  local HgssBattleScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local live = { party = self.monService, bag = self.bagService, world = self.scripts.worldState }
  -- The current player reward identity rides the scenario context for
  -- traded and foreign award classification: the validated profile owns
  -- the trainer facts and the composed mon language owns the language key.
  if self.playerData ~= nil and self.playerData.profile ~= nil and self.monLanguage ~= nil then
    local profile = self.playerData.profile --[[@as table<string, unknown>]]
    if type(profile.trainerId) == "number" and type(profile.name) == "string" then
      local playerClassKey = ({ [0] = "PKMN_TRAINER_ETHAN", [1] = "PKMN_TRAINER_LYRA" })[profile.gender]
      assert(type(playerClassKey) == "string", "the validated player profile selects Ethan or Lyra")
      live.player = {
        trainerId = profile.trainerId,
        trainerName = profile.name,
        language = self.monLanguage,
        trainerClassKey = playerClassKey,
        metBill = self.eventState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_SYS_MET_BILL),
      }
    end
  end
  if request.kind == "wild" then
    local payload = request.payload
    assert(type(payload) == "table", "wild launches carry their payload")
    if self.pendingEncounter ~= nil then
      local pending = self.pendingEncounter --[[@as table<string, unknown>]]
      if payload.attemptId == nil or payload.attemptId == pending.id then
        local encounter = self:consumePendingEncounter()
        local mons = encounter.mons --[[@as table<integer, unknown>]]
        assert(type(mons) == "table" and type(mons[1]) == "table", "prepared encounters carry their mon")
        local first = mons[1] --[[@as table<string, unknown>]]
        assert(type(first.mon) == "table", "prepared encounters carry their mon record")
        local environment = {}
        for key, value in pairs(encounter.environment) do
          environment[key] = value
        end
        -- The Repeat Ball reads the wild species' Pokedex caught flag.
        local species = first.mon.species --[[@as string]]
        local dex = assert(self.dexKnowledge, "wild launches read the Pokedex caught flags")
        environment.caughtSpecies = dex:isCaught(species) and { [species] = true } or {}
        return HgssBattleScenarioFactory.fromEncounter({
          attemptId = encounter.id,
          mon = first.mon,
          format = encounter.format,
          environment = environment,
        }, live)
      end
    end
    -- A bare species/level foe never passed preparation, so the kernel
    -- would read unwritten combat facts for it: materialize it once here
    -- through the existing wild factory on the world stream (the trainer
    -- materialization precedent), exactly like a scripted static
    -- encounter. Prepared encounters already carry full records and skip
    -- this; without the composed catalogs the descriptor rides through
    -- untouched and fails loudly only if it ever settles, as before.
    if type(payload.species) == "string" or type(payload.species) == "number" then
      local grown = self:_materializeDescriptorFoe(payload --[[@as table<string, unknown>]])
      if grown ~= nil then
        local staged = {}
        for key, value in pairs(payload) do
          staged[key] = value
        end
        staged.mon = grown
        payload = staged
      end
    end
    return HgssBattleScenarioFactory.fromEncounter(payload --[[@as table<string, unknown>]], live)
  end
  if request.kind == "trainer" then
    return HgssBattleScenarioFactory.fromTrainer(
      self:_trainerPayload(request.payload --[[@as table<string, unknown>]]),
      live
    )
  end
  -- Retail catching-tutorial (scrcmd_c.c ScrCmd_CatchingTutorial opcode
  -- 251 via BattleSetup_New_Tutorial): the lesson runs its fixed Marill
  -- and Rattata content with 20× balls behind the tutorial marker,
  -- never live party or bag state. Map-script content owns the trigger;
  -- a test-only launch without the script still builds the same lesson
  -- through this seam.
  if request.kind == "tutorial" then
    local payload = request.payload
    assert(type(payload) == "table", "tutorial launches carry their payload")
    local lesson = HgssBattleScenarioFactory.TUTORIAL_LESSON
    return HgssBattleScenarioFactory.fromTutorial({
      attemptId = payload.attemptId,
      mons = { player = self:_materializeLessonMon(lesson.player), foe = self:_materializeLessonMon(lesson.foe) },
    }, live)
  end
  return HgssBattleScenarioFactory.fromScript(request.payload --[[@as table<string, unknown>]], live)
end

---@return table<string, unknown> the consumed prepared encounter
function FieldRuntime:consumePendingEncounter()
  local pending = assert(self.pendingEncounter, "no prepared encounter to consume")
  local id = self.pendingEncounterId
  self.pendingEncounter = nil
  self.pendingEncounterId = nil
  if self._encounters ~= nil and id ~= nil then
    return self._encounters:consume(id)
  end
  return pending
end

-- The field-owned origin facts behind a wild creation: the active map's
-- native section identity and the host clock's civil date, copied once at
-- admission. Terrain stays neutral until a sourced numeric mapping exists.
-- Missing section or clock facts fail loudly instead of guessing.
---@return { location: integer, date: { year: integer, month: integer, day: integer }, terrain: integer }
function FieldRuntime:_wildMetContext()
  local session = self.session
  local currentMap = session ~= nil and session.currentMap or self.runtimeMap
  local nativeId = currentMap ~= nil and currentMap.mapSectionNativeId or nil
  assert(
    type(nativeId) == "number" and nativeId % 1 == 0 and nativeId >= 0 and nativeId <= 0xFFFF,
    "wild encounters require the active native map section"
  )
  local clock = assert(self.localClock, "wild encounters require their host clock")
  local now = clock:nowLocal()
  assert(type(now) == "table", "wild encounters read their host clock date")
  assert(
    type(now.year) == "number"
      and now.year % 1 == 0
      and now.year >= 2000
      and now.year <= 2255
      and type(now.month) == "number"
      and now.month % 1 == 0
      and now.month >= 1
      and now.month <= 12
      and type(now.day) == "number"
      and now.day % 1 == 0
      and now.day >= 1
      and now.day <= 31,
    "wild encounters require a valid host clock date"
  )
  return {
    location = nativeId,
    date = { year = now.year, month = now.month, day = now.day },
    terrain = 0,
  }
end

-- The field Pokémon picture window behind Screen 452/453: one borrowed
-- generated portrait family, the mon catalog that resolves a source species
-- number, and the one dex owner that records the shown species as seen.
---@param cacheFs CacheFs
function FieldRuntime:_composeMonPictureWindow(cacheFs)
  local MonCache = require("libs.assets.src.MonCache")
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local FieldMonPictureWindow = require("game.hgss.src.field.FieldMonPictureWindow")
  local portraits = assert(
    cacheFs:loadLua(MonCache.portraitManifestPath()),
    "the field picture window requires the generated portrait manifest"
  )
  assert(MonAssetSchema.isValidPortraitManifest(portraits), "the portrait manifest satisfies its current schema")
  local catalog = assert(self.monCatalog, "the picture window resolves source species through the mon catalog")
  local dex = assert(self.dexKnowledge, "the picture window publishes sightings through the dex owner")
  local function markSeen(species)
    local receipt = dex:prepareChanges({ seen = { species } })
    if receipt.isCurrent() ~= true then
      return false
    end
    receipt.publish()
    return true
  end
  self.monPicture = FieldMonPictureWindow.new({
    portraits = portraits,
    speciesKeyByNativeId = function(nativeId)
      return catalog:speciesKeyByNativeId(nativeId)
    end,
    markSeen = markSeen,
  })
end

-- Materializes one bare species/level foe into a full mon record through
-- the existing wild factory, drawing identity on the world stream exactly
-- like a scripted static encounter. The authored species rides either as its
-- catalog key or as the source's own native species number (ScriptGetVar reads
-- a literal species id), which the mon catalog maps to that key. Nil unless
-- every composed catalog and the world generator are present; production always
-- carries them.
---@return table<string, unknown>? factory, table<string, unknown>? stream, table<string, unknown>? profile
function FieldRuntime:_staticWildKit()
  local catalog = self.monCatalog
  local items = self.itemCatalog
  local cacheFs = self.cacheFs
  if catalog == nil or items == nil or cacheFs == nil or self.monLanguage == nil then
    return nil
  end
  local scripts = self.scripts
  if scripts == nil or scripts.worldState == nil or scripts.worldState.rng == nil then
    return nil
  end
  local profile = self.playerData ~= nil and self.playerData.profile or nil
  local session = self.session
  local sessionMap = session ~= nil and session.currentMap or nil
  if sessionMap == nil or type(profile) ~= "table" then
    return nil
  end
  local WildMonFactory = require("libs.hgss.src.encounters.WildMonFactory")
  local fontDef = FieldFontLoader.load(cacheFs)
  local factory = WildMonFactory.new({
    catalog = catalog,
    items = items,
    charmap = fontDef.charmap,
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
    game = self.versionId,
    language = self.monLanguage,
  })
  local worldRng = scripts.worldState.rng
  local function drawWorldU16(_, _, _)
    return worldRng:nextRaw() % 65536
  end
  return factory, { nextU16 = drawWorldU16 }, profile
end

---@param payload table<string, unknown> wild launch payload naming its species and level
---@return table<string, unknown>? full foe record, nil when uncomposable
function FieldRuntime:_materializeDescriptorFoe(payload)
  if type(payload.level) ~= "number" then
    return nil
  end
  local catalog = assert(self.monCatalog, "the wild factory requires the composed mon catalog")
  local species = payload.species
  if type(species) == "number" then
    species = catalog:speciesKeyByNativeId(species)
    if type(species) ~= "string" then
      return nil
    end
  end
  if type(species) ~= "string" then
    return nil
  end
  local factory, stream, profile = self:_staticWildKit()
  if factory == nil then
    return nil
  end
  local met = self:_wildMetContext()
  -- The source wild-battle operand selects the forced shiny identity, and the
  -- fateful launch marks the created foe. Both are authored launch facts, not
  -- presentation choices.
  local args = payload.args
  local forcedShiny = type(args) == "table" and args[1] == 1
  return factory:createStatic(species, payload.level --[[@as integer]], stream, {
    profile = profile,
    ball = "POKE_BALL",
    location = met.location,
    terrain = met.terrain,
    date = met.date,
    forcedShiny = forcedShiny,
    fateful = payload.fateful == true,
  })
end

-- Materializes one catching-tutorial lesson mon like a scripted static
-- foe, then gives it the source OT_ID_RANDOM_NO_SHINY original trainer: a
-- random identity drawn on the world stream that never makes it shiny.
---@param descriptor { species: string, level: integer } fixed lesson content
---@return table<string, unknown> full lesson record
function FieldRuntime:_materializeLessonMon(descriptor)
  local mon =
    assert(self:_materializeDescriptorFoe(descriptor), "tutorial lessons materialize through the composed wild factory")
  local worldRng = self.scripts.worldState.rng
  local origin = mon.origin --[[@as table<string, unknown>]]
  repeat
    origin.trainerId = worldRng:nextRaw() % 65536 + (worldRng:nextRaw() % 65536) * 65536
  until not Personality.shiny(origin.trainerId --[[@as integer]], mon.personality --[[@as integer]])
  return mon
end

-- Resolves one trainer launch payload into the detached trainer entries the
-- scenario shaper consumes. Entries already carrying their full party
-- records (explicit staged/scripted authoring) ride through untouched;
-- bare native identities resolve through the composed catalog and
-- materializer into detached bundles retaining the native identity, class,
-- ordered party, and controller metadata. Unknown identities fail before
-- any battle publishes; nothing here invents a party.
--
-- The payload's two opponent identities follow
-- src/encounter.c::SetupAndStartTrainerBattle: a second identity naming a
-- different trainer fields two opponents, the same identity fields the native
-- one-trainer double, and no second identity keeps the single-opponent battle.
---@param payload table<string, unknown>
---@return table<string, unknown> scenario-ready trainer payload
function FieldRuntime:_trainerPayload(payload)
  assert(type(payload) == "table", "trainer launches carry their payload")
  local source = payload.trainers
  if source == nil then
    local second = payload.trainer2
    local doubles = type(second) == "number" and second ~= 0
    if doubles and second == payload.trainer then
      -- One native trainer on both opponent slots: a marked single entry,
      -- never two generated copies of the same party.
      source = { { id = payload.trainer, party = payload.party, doubleBattle = true } }
    elseif doubles then
      source = { { id = payload.trainer, party = payload.party }, { id = second } }
    else
      source = { { id = payload.trainer, party = payload.party } }
    end
  end
  assert(type(source) == "table" and #source > 0, "trainer battles field at least one trainer")
  local factory = assert(self._trainerFactory, "trainer launches require their composed trainer materializer")
  local Errors = require("libs.errors.src.Errors")
  local world = self.scripts ~= nil and self.scripts.worldState or nil
  local stream = world ~= nil and world.rng or nil
  assert(type(stream) == "table", "trainer materialization threads the world stream untouched")
  -- The rival display name is the saved profile's rival name; an explicit
  -- staged-launch override wins.
  local rivalName = nil
  local payloadRival = payload["rivalName"]
  if type(payloadRival) == "string" and payloadRival ~= "" then
    rivalName = payloadRival
  else
    rivalName = self.playerData ~= nil and self.playerData.profile.rivalName or nil
  end
  local resolved = {}
  for _, entry in ipairs(source) do
    assert(type(entry) == "table", "trainer entries stay records")
    local item = entry --[[@as table<string, unknown>]]
    if type(item.party) == "table" and #item.party > 0 then
      local staged = { id = item.id, party = item.party }
      if item.doubleBattle ~= nil then
        staged.doubleBattle = item.doubleBattle
      end
      resolved[#resolved + 1] = staged
    else
      local id = item.id
      if id == nil then
        id = payload.trainer
      end
      if type(id) ~= "string" and type(id) ~= "number" then
        Errors.raise("TRAINER_UNKNOWN", "trainer launches name their trainer identity", {
          trainer = tostring(id),
        })
      end
      local bundle = factory:build({
        trainerKey = id,
        rivalName = rivalName,
        storyVariant = item.storyVariant or payload.storyVariant,
        rng = stream,
      })
      resolved[#resolved + 1] = {
        id = id,
        class = bundle.trainerClass,
        name = bundle.name,
        loseSpeechSelector = bundle.loseSpeechSelector,
        party = bundle.mons,
        partyLevels = bundle.partyLevels,
        prizeMoney = bundle.prizeMoney,
        aiPasses = bundle.aiPasses,
        items = bundle.items,
        -- The launch's own double mark (one trainer on both opponent slots)
        -- survives beside the trainer record's own mark.
        doubleBattle = item.doubleBattle == true or bundle.doubleBattle,
      }
    end
  end
  local partner = nil
  local partnerId = payload.partner
  if type(partnerId) == "number" and partnerId ~= 0 then
    local bundle = factory:build({
      trainerKey = partnerId,
      rivalName = rivalName,
      storyVariant = payload.storyVariant,
      rng = stream,
    })
    partner = {
      id = partnerId,
      class = bundle.trainerClass,
      name = bundle.name,
      party = bundle.mons,
      partyLevels = bundle.partyLevels,
      aiPasses = bundle.aiPasses,
      items = bundle.items,
    }
  end
  return {
    attemptId = payload.attemptId,
    id = payload.id,
    format = payload.format,
    trainers = resolved,
    partner = partner,
    inventories = payload.inventories,
    environment = payload.environment,
    formatState = payload.formatState,
  }
end

---@param args table<string, unknown>
---@return table<string, unknown> the owned application battle lifetime
function FieldRuntime:startBattle(args)
  local battle = self.battleCoordinator:startBattle(args)
  if self.incomingCalls ~= nil then
    self.incomingCalls:resetTransient("battle")
  end
  return battle
end

function FieldRuntime:_reconcileBattleGate()
  self.battleCoordinator:reconcileBattleGate()
end

-- Accepts one complete battle only after its native consequences are
-- committed. The returned decision is consumed by the path-specific field
-- envelope; this boundary owns only launch result and wallet adoption.
---@param launch table<string, unknown>? the active field launch, when present
---@param battle table<string, unknown> the matching live battle
---@param status table<string, unknown> terminal battle status
---@return { result: string, sourceResult: integer, nativeOutcome: integer, receipt: table<string, unknown>, successful: boolean }
function FieldRuntime:acceptCommittedBattleStatus(launch, battle, status)
  assert(self.battleCoordinator:activeBattle() == battle, "only the owned battle can settle its field launch")
  assert(status.phase == "complete", "only a complete battle can be accepted")
  local receipt = status.outcomeReceipt
  assert(type(receipt) == "table" and receipt.committed == true, "battle completed without a committed outcome receipt")
  local result = assert(status.result, "committed battle status requires its result")
  local sourceResult = assert(status.sourceResult, "committed battle status requires its source result")
  local nativeOutcome = assert(status.nativeOutcome, "committed battle status requires its native outcome code")
  if launch ~= nil then
    launch.result = result
    launch.sourceResult = sourceResult
    launch.nativeOutcome = nativeOutcome
    -- The committed consequence plan rides the launch record so the
    -- settled battle publishes one observable receipt.
    launch.rewards = receipt.rewards
    self.battleCoordinator:adoptCommittedPlayerMoney(launch, receipt)
  end
  -- A committed roaming battle publishes its lifecycle word in this same
  -- publication step: 0 roaming, 1 caught, 2 defeated. A rejected or stale
  -- outcome never returns a receipt, so it reaches no variable and leaves the
  -- stored record on its last known-good state.
  local settledRoamer = receipt.roamer
  if type(settledRoamer) == "table" then
    self:_publishRoamerStatus(settledRoamer --[[@as table<string, unknown>]])
  end
  return {
    result = result,
    sourceResult = sourceResult,
    nativeOutcome = nativeOutcome,
    receipt = receipt,
    successful = result ~= "loss" and result ~= "draw",
  }
end

function FieldRuntime:updateBattle()
  return self.battleCoordinator:updateBattle()
end

function FieldRuntime:lastBattleResult()
  local coordinator = self.battleCoordinator
  return coordinator ~= nil and coordinator:lastBattleResult() or nil
end

---@param launchId string
---@return table<string, unknown>? status record
function FieldRuntime:battleStatus(launchId)
  local coordinator = self.battleCoordinator
  return coordinator ~= nil and coordinator:battleStatus(launchId) or nil
end

---@param spec table<string, unknown>
---@return string launch identity
function FieldRuntime:launchBattle(spec)
  return self.battleCoordinator:launchBattle(spec)
end

function FieldRuntime:cancelPendingEncounter()
  return self.battleCoordinator:cancelPendingEncounter()
end

-- The one roamer transition publication: the source records the arrival
-- and the map the player left, then connects a connection entry's roamer
-- movement, randomizes every active roamer on the explicit fly warp, and
-- moves nothing on an ordinary warp. The world random stream is the one
-- shared generator. Called only from a committed transition, so a failed
-- or abandoned transition mutates nothing.
---@param form string connection, ordinary or fly
---@param sourceMapId integer the map the player left
---@param destinationMapId integer the map the player entered
function FieldRuntime:publishRoamerTransition(form, sourceMapId, destinationMapId)
  local roamers = self.roamerState
  if type(roamers) ~= "table" then
    return
  end
  local scripts = self.scripts
  local rng = scripts ~= nil and scripts.worldState ~= nil and scripts.worldState.rng or nil
  assert(type(rng) == "table", "roamer transitions draw from the world random stream")
  roamers:notePlayerLocation(form, destinationMapId, sourceMapId)
  if form == "connection" then
    roamers:updateOnConnectionEntry(rng)
  elseif form == "fly" then
    roamers:randomizeLocations(rng)
  end
end

-- The source status word per roamer lifecycle
-- (field_roamer.c::VAR_ROAMER_*_STATUS): a roaming slot reads 0, a captured
-- one 1 and a defeated one 2. The same publication that records the slot
-- writes its word, so a script reading the word sees its own committed state.
local ROAMER_STATUS_BY_LIFECYCLE = { roaming = 0, caught = 1, defeated = 2 }

-- The source variable identity of one roamer lifecycle word, resolved through
-- the compiled field symbols by the slot's own species. Only the four source
-- slots own a word: a custom roamer species answers nil.
---@param species string the roamer's species key
---@return integer? the source lifecycle variable, nil without one
local function roamerStatusVariable(species)
  local id = FieldScriptSymbols.variablesByName["VAR_ROAMER_" .. species .. "_STATUS"]
  if type(id) ~= "number" then
    return nil
  end
  return id
end

-- Publishes one roamer's lifecycle word through the script world. Called from
-- the same step that commits the record, so no second publication exists.
---@param record table<string, unknown> the committed roamer record
function FieldRuntime:_publishRoamerStatus(record)
  local species = assert(record.mon.species, "roamer records carry their species")
  assert(type(species) == "string", "roamer species are catalog keys")
  local status = assert(ROAMER_STATUS_BY_LIFECYCLE[assert(record.lifecycle)], "roamer records carry a known lifecycle")
  local variable = roamerStatusVariable(species)
  if variable == nil then
    return
  end
  local world = assert(self.scripts and self.scripts.worldState, "roamer status publishes through the script world")
  world:setVar(variable, status)
end

-- Materializes one native roamer's identity through the ordinary static
-- creation owner: the source generates a fresh identity, individual values and
-- held item on the one world stream, exactly like a scripted static encounter.
---@param fact { species: string, level: integer }
---@return table<string, unknown>? the created mon, nil when uncomposable
function FieldRuntime:_materializeNativeRoamer(fact)
  local factory, stream, profile = self:_staticWildKit()
  if factory == nil then
    return nil
  end
  local met = self:_wildMetContext()
  return factory:createStatic(fact.species, fact.level, stream, {
    profile = profile,
    ball = "POKE_BALL",
    location = met.location,
    terrain = met.terrain,
    date = met.date,
  })
end

-- Source ScrCmd_CreateRoamer: creates one native roamer slot from the compiled
-- source slot facts. The roaming mon materializes once, the roamer owner
-- records it with its route and full battle health, and the slot's status word
-- publishes in the same step. A slot that already exists is the owner's own
-- programming error, never a silent second creation.
---@param slot integer source slot index
---@return table<string, unknown> the created record
function FieldRuntime:createNativeRoamer(slot)
  local roamers = assert(self.roamerState, "roamer creation requires the field roamer owner")
  local fact = roamers:nativeSlot(slot)
  local scripts = assert(self.scripts, "roamer creation requires the field scripts")
  local rng = assert(scripts.worldState and scripts.worldState.rng, "roamer creation draws from the world stream")
  local mon = assert(self:_materializeNativeRoamer(fact), "roamer creation requires the composed mon catalogs")
  local record = roamers:createNativeSlot(slot, mon, rng)
  self:_publishRoamerStatus(record)
  return record
end

-- Marks the warp that is about to start as the source's Fly warp. The
-- world-swap commit consumes the mark: a Fly warp records the raw arrival
-- and departure identities and randomizes every active roamer, while an
-- ordinary warp only records the history.
function FieldRuntime:beginFlyWarp()
  assert(self.pendingWarpForm == nil, "a field warp already names its source form")
  self.pendingWarpForm = "fly"
end

-- Composes the concrete encounter service over a compiled encounter
-- catalog, sharing the live party, catalogs, and roamer state. Field
-- boot composes it from generated data; a missing or invalid payload
-- fails the boot instead of leaving the service absent.
---@param compiled table<string, unknown> compiled encounter catalog record
function FieldRuntime:composeEncounters(compiled)
  local HgssEncounterCatalog = require("libs.hgss.src.encounters.HgssEncounterCatalog")
  local WildMonFactory = require("libs.hgss.src.encounters.WildMonFactory")
  local HgssEncounterService = require("libs.hgss.src.encounters.HgssEncounterService")
  local catalog = HgssEncounterCatalog.new(compiled)
  local encounterCacheFs = assert(self.cacheFs, "encounter composition requires its cache")
  local fontDef = FieldFontLoader.load(encounterCacheFs)
  local monCatalog = assert(self.monCatalog, "encounter composition requires the mon catalog")
  local factory = WildMonFactory.new({
    catalog = monCatalog,
    items = assert(self.itemCatalog, "encounter composition requires the item catalog"),
    charmap = fontDef.charmap,
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
    game = self.versionId,
    language = self.monLanguage,
  })
  -- Magnet-pull/static coercion reads live slot types from the mon
  -- catalog, mirroring the native base-stat scan at selection time:
  -- the encounter tables carry no duplicated type data.
  local function slotTypes(species, form)
    return monCatalog:form(species, form).types
  end
  self._encounters = HgssEncounterService.new({
    catalog = catalog,
    wildFactory = factory,
    roamers = assert(self.roamerState, "encounter composition requires its roamer state"),
    game = self.versionId,
    speciesTypes = slotTypes,
  })
  self._encounterCatalog = catalog
end

-- Composes the concrete trainer materializer over a compiled trainer
-- catalog, sharing the domain mon catalog and creation policy. Field
-- boot composes it from generated data; a missing or invalid payload
-- fails the boot instead of leaving trainer launches uncomposed.
---@param compiled table<string, unknown> compiled trainer catalog record
function FieldRuntime:composeTrainers(compiled)
  local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
  local HgssTrainerFactory = require("libs.hgss.src.battle.HgssTrainerFactory")
  local catalog = HgssTrainerCatalog.new(compiled)
  local trainerCacheFs = assert(self.cacheFs, "trainer composition requires its cache")
  local fontDef = FieldFontLoader.load(trainerCacheFs)
  self._trainerCatalog = catalog
  self._trainerFactory = HgssTrainerFactory.new({
    catalog = catalog,
    monCatalog = assert(self.monCatalog, "trainer composition requires the mon catalog"),
    charmap = fontDef.charmap,
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
    game = self.versionId,
    language = assert(self.monLanguage, "trainer composition requires the mon language"),
  })
end

-- Names one trainer template's class without materializing its party:
-- battle-music selection reads the class while the factory keeps owning
-- party builds and their randomness. Unknown trainers answer nil so the
-- caller keeps the ordinary default instead of guessing.
---@param key string|integer trainer identity behind the lookup
---@return string? trainer class key, nil for unknown trainers or before composition
function FieldRuntime:trainerClassFor(key)
  local catalog = self._trainerCatalog
  if catalog == nil then
    return nil
  end
  local ok, template = pcall(function()
    local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
    return HgssTrainerCatalog.trainer(catalog, key)
  end)
  if not ok or type(template) ~= "table" then
    return nil
  end
  if type(template.trainerClass) == "string" and template.trainerClass ~= "" then
    return template.trainerClass --[[@as string]]
  end
  return nil
end

-- Runs one encounter attempt over the composed service. Without a service
-- (or while a battle or preparation owns the field) there is nothing to
-- attempt. A prepared encounter is held exactly once under its attempt
-- identity; later steps skip until it is consumed or released. Maps
-- without tables miss instead of faulting: no table means no encounter.
---@param context table<string, unknown> encounter attempt context
---@return table<string, unknown>? attempt result
function FieldRuntime:attemptEncounter(context)
  local service = self._encounters
  if service == nil then
    return nil
  end
  if self.battleCoordinator:hasBattleWork() or self.pendingEncounterId ~= nil then
    return nil
  end
  local worldState = assert(self.scripts, "encounter attempts require their script platform").worldState
  local worldRng = assert(worldState.rng, "encounter attempts draw from the world generator")
  local function drawU16(_, _, _)
    return worldRng:nextRaw() % 65536
  end
  local stream = { nextU16 = drawU16 }
  -- The lookup identity stays the encounter table member; the origin
  -- record rides beside it so selection never moves. The caller's record
  -- is staged, never mutated, and an explicitly supplied record wins.
  local admitted = context
  if type(context) == "table" then
    admitted = {}
    for key, value in pairs(context) do
      admitted[key] = value
    end
    if admitted.met == nil then
      admitted.met = self:_wildMetContext()
    end
    assert(admitted.mapId == context.mapId)
    -- The launch environment carries the encounter facts the conditional
    -- balls read: the time of day (the Dusk Ball) and a hooked encounter
    -- (the Lure Ball).
    if type(context.environment) == "table" then
      local environment = {}
      for key, value in pairs(context.environment) do
        environment[key] = value
      end
      environment.timeOfDay = context.timeOfDay
      environment.fished = context.method == "fish"
      admitted.environment = environment
    end
  end
  local Errors = require("libs.errors.src.Errors")
  local ok, result = pcall(service.attempt, service, admitted, stream)
  if not ok then
    if Errors.is(result) and result.code == "ENCOUNTER_MISSING_TABLE" then
      return { kind = "miss", reason = "no_table" }
    end
    error(result, 0)
  end
  assert(type(result) == "table", "attempts answer with a result record")
  if result.kind == "prepared" then
    self.pendingEncounterId = result.attemptId
    self.pendingEncounter = result.encounter
  end
  return result
end

-- The current semantic radio music effect behind live encounters and the
-- script music query: the audio latch through the one shared
-- sequence-to-effect mapping. Frame-read-only; never restarts, resumes,
-- or polls audio. Without audio there is no effect.
---@return string the semantic music effect
function FieldRuntime:_currentRadioEffect()
  local audio = self.audio
  local latch = nil
  if type(audio) == "table" and type(audio.currentRadioSequence) == "function" then
    latch = audio:currentRadioSequence()
  end
  local PokegearRadioEffects = require("game.hgss.src.pokegear.PokegearRadioEffects")
  return PokegearRadioEffects.fromSequence(latch)
end

-- Answers the source radio script query for one semantic effect: exact
-- comparison against the retained audio latch on the calling tick. The
-- query mutates no world or actor state. This is the script-service
-- boundary the opcode adapter consumes; encounters read the same mapping
-- through preparation.
---@param effect string the semantic music effect under test
---@return boolean
function FieldRuntime:radioMusicIs(effect)
  assert(type(effect) == "string", "radio music queries compare a semantic effect")
  return self:_currentRadioEffect() == effect
end

-- Whether the committed step swarms: the outbreak-active flag stays with
-- the encounter owner while the outbreak identity is the shared companion
-- seed resolved through the same lookup the broadcast announces, so field
-- encounters can never swarm a different outbreak. Per-map applicability
-- stays with the catalog's active-replacement gate. Without owners there
-- is no swarm.
---@return boolean
function FieldRuntime:_stepSwarmActive()
  local roamers = self.roamerState
  if type(roamers) ~= "table" or type(roamers.isSwarmActive) ~= "function" then
    return false
  end
  if roamers:isSwarmActive() ~= true then
    return false
  end
  local gear = self.pokegearState
  if type(gear) ~= "table" or type(gear.readDailyIdentity) ~= "function" then
    return false
  end
  local identity = gear:readDailyIdentity()
  if type(identity) ~= "table" or type(identity.outbreakSeed) ~= "number" then
    return false
  end
  local RadioWorldContext = require("game.hgss.src.pokegear.RadioWorldContext")
  return RadioWorldContext.swarmInfoFromSeed(identity.outbreakSeed) ~= nil
end

-- The retail field-poison cue message behind one cured mon, resolved
-- through the live message pipeline (never copied text): the nickname
-- rides buffer slot 0 exactly like the BufferPartyMonNick binding the
-- native script leaves behind (STRVAR_1 names the first string buffer).
local POISON_CURE_MESSAGE = "msg.hgss.0040.00053"

local function copyPoisonRecord(record)
  if type(record) ~= "table" then
    return record
  end
  local out = {}
  for key, value in pairs(record) do
    out[key] = copyPoisonRecord(value)
  end
  return out
end

-- Notes one processed committed step on the poison counter and runs the
-- damage tick every fourth step: HP drains through the staged mon
-- service, the poison jingle and HBlank wobble fire, and a cure outcome
-- opens its nickname message chain. Returns the tick outcome ("survive"
-- claims the step), or nil when no tick ran. Inert without a poison
-- counter or a mon service; the headless seams that omit either keep
-- their old boundary.
---@return string? the tick outcome kind, nil without a tick
function FieldRuntime:_tickFieldPoison()
  local poison = self.fieldPoison
  local mons = self.monService
  if poison == nil or mons == nil then
    return nil
  end
  if not poison:noteStep() then
    return nil
  end
  local count = mons:partyCount()
  if type(count) ~= "number" or count < 1 then
    return nil
  end
  local records = {}
  for slot = 0, count - 1 do
    records[#records + 1] = mons:partyMon(slot)
  end
  local outcome = FieldPoison.tickParty(records)
  if outcome.kind == "none" then
    return nil
  end
  local updates = {}
  for slot, update in pairs(outcome.updates) do
    local staged = copyPoisonRecord(records[slot + 1])
    assert(type(staged) == "table", "poison staging requires the live mon record")
    local condition = assert(staged.condition, "poison staging requires the live condition")
    condition.currentHp = update.currentHp
    if update.cured then
      condition.effects = update.effects
      staged.friendship = update.friendship
      staged.mood = update.mood
    end
    updates[#updates + 1] = { slot = slot, mon = staged }
  end
  local preparation, reason = mons:preparePartyChanges(mons:partyRevision(), updates)
  if preparation == nil then
    error("field poison party staging went stale: " .. tostring(reason), 0)
  end
  preparation.publish()
  if self.audio ~= nil then
    self.audio:play("SEQ_SE_DP_DOKU2")
  end
  -- The HBlank wobble fires for both damage and survive ticks, matching
  -- the native DoPoisonEffect call on either ApplyPoisonStep outcome. The
  -- effect owner is optional in headless seams that never composed it.
  local effect = self.poisonEffect
  if effect ~= nil then
    effect:start()
  end
  if outcome.kind == "survive" then
    self:_beginPoisonCureMessages(outcome)
  end
  return outcome.kind
end

-- Opens the cure message chain behind a survive tick: one nickname
-- message per cured mon, in slot order, through the session dialogue.
-- The modal gate pauses steps and encounters until every message
-- dismisses, matching the native script claim on the step.
---@param outcome { kind: string, updates: table<integer, table<string, unknown>> }
function FieldRuntime:_beginPoisonCureMessages(outcome)
  local slots = {}
  for slot, update in pairs(outcome.updates) do
    if update.cured then
      slots[#slots + 1] = slot
    end
  end
  table.sort(slots)
  if #slots == 0 then
    return
  end
  self.poisonCure = { slots = slots, index = 1 }
  self:_openPoisonCureMessage()
end

-- Opens the pending cure message at the chain head. The completion
-- callback advances the chain, so sequential cures never overlap.
function FieldRuntime:_openPoisonCureMessage()
  local pending = assert(self.poisonCure, "poison cure chain requires its pending slots")
  local slot = assert(pending.slots[pending.index], "poison cure chain requires its head slot")
  local host = assert(self.scripts and self.scripts.dialogueHost, "poison cure messages require the dialogue host")
  local message = host:resolveMessage(POISON_CURE_MESSAGE, {}, { [0] = { text = "party_nickname", position = slot } })
  local dialogue = assert(self.session and self.session.dialogue, "poison cure messages require the field dialogue")
  -- The cure box is the ordinary NPCMsg field box: it carries the
  -- player-selected window frame like every script-owned message. Without
  -- it the renderer draws only the content-background fill with no frame
  -- tiles (the unstyled box). The host mirrors the same live option, but
  -- the runtime-owned chain reads the authoritative player options.
  local frameIndex = self.playerData and self.playerData.options and self.playerData.options.textFrame or nil
  local handle = dialogue:open({
    id = "field-poison-cure",
    message = message,
    allowCancel = false,
    frameIndex = frameIndex,
  })
  handle:onComplete(function()
    self:_advancePoisonCureMessages()
  end)
end

-- Advances the cure chain past one dismissed message: the next cured mon
-- announces itself, and after the last one the chain clears. A wipe needs
-- no recovery here on top of the cure: damage floors every drained mon at
-- 1 HP, so a survive tick always leaves the party conscious.
function FieldRuntime:_advancePoisonCureMessages()
  local pending = self.poisonCure
  if pending == nil then
    return
  end
  pending.index = pending.index + 1
  if pending.index <= #pending.slots then
    self:_openPoisonCureMessage()
    return
  end
  self.poisonCure = nil
end

-- The committed-step encounter boundary, once per fixed tick: at most one
-- fresh unclaimed completed step is considered, after that step's warp,
-- coordinate-script, and map-boundary arbitration already ran inside the
-- session tick. Guarded steps are marked handled by consumption and never
-- become delayed encounters. A prepared encounter is held for an explicit
-- launch in headless composition; a presented field admits it to the
-- launch path on the same tick. Inert without a composed encounter service.
function FieldRuntime:_consumeCommittedStep()
  local session = self.session
  if self._encounters == nil or session == nil or self.player == nil then
    return
  end
  if session.takeCommittedStep == nil then
    return
  end
  -- Biked steps count as they start, whichever owner later claims them.
  self:_countBikedSteps()
  local step = session:takeCommittedStep()
  if step == nil then
    return
  end
  if self.battleCoordinator:hasBattleWork() or self.pendingEncounterId ~= nil then
    return
  end
  if session.mapEntryController:isActive() or session.dialogue:isModal() then
    return
  end
  local overworld = self.overworld
  if overworld ~= nil then
    local presentPhase = overworld:phase()
    if presentPhase ~= "present" then
      return
    end
  end
  -- Field poison ticks on every processed committed step before the
  -- encounter boundary, matching the native per-step update order. A cure
  -- flow claims the step: like a claimed warp or script, it never becomes
  -- a delayed encounter.
  if self:_tickFieldPoison() == "survive" then
    return
  end
  local map = session.currentMap --[[@as table<string, unknown>]]
  local method = self:_stepEncounterMethod(map, self.player)
  -- One repel tick per committed step that reaches method resolution,
  -- matching the native per-step update: the encounter check below reads
  -- the post-decrement counter.
  local repelSteps = self:_consumeRepelStep()
  self:_raiseBikeShopCall()
  if method == nil then
    -- Steps outside encounter tiles never attempt, but they still count
    -- toward the entry grace.
    self._encounters:noteStep()
    return
  end
  -- The service resolves encounter tables by table member, never by map
  -- identity: the compiled map carries its source table member for
  -- exactly this lookup. The attempt also names the native movement-roll
  -- facts: the avatar pace behind the committed step and whether the
  -- arrival tile is very tall grass. Deterrence, held-item, gender, and
  -- nature facts ride the live party lead; repel and friendship ride the
  -- first alive mon; the weather names snow for the ability stage.
  local fieldData = map.fieldData --[[@as table<string, unknown>]]
  local memberId = fieldData ~= nil and fieldData.wildEncounterMemberId or nil
  assert(
    type(memberId) == "number" and memberId % 1 == 0,
    "committed steps resolve their map's wild encounter table member"
  )
  -- Maps without an encounter bank never roll: the native step check
  -- sits behind the map-level wild-encounter gate, so the ENCDATA_NA
  -- sentinel counts grace without consulting any table.
  if memberId == 255 then
    self._encounters:noteStep()
    return
  end
  local arrival = self:arrivalBehavior(map, self.player)
  local leadFacts = self:_encounterLeadFacts()
  -- The source roamer gate (field_roamer.c::getRandomActiveRoamerInCurrMap)
  -- meets the roaming slots standing on the player's map once the step
  -- resolved an encounter tile: a met slot replaces the ordinary table
  -- encounter with its own borrowed identity, so the attempt names the roaming
  -- method and the record key while the resolved land or water method still
  -- stages the tile rate. The service owns the tile rolls, so the gate's own
  -- draws precede them here instead of following them natively.
  local roamerKey = self:_stepRoamerKey()
  local attemptMethod = method
  local modifiers = {
    radio = self:_currentRadioEffect(),
    swarm = self:_stepSwarmActive(),
    locomotion = self:_stepLocomotion(),
    veryTallGrass = arrival ~= nil and MetatileBehavior.isVeryTallGrass(arrival) or false,
    facing = self.player.facing,
    repel = repelSteps > 0,
    repelSteps = repelSteps,
    leadAbility = leadFacts.leadAbility,
    leadNature = leadFacts.leadNature,
    leadGender = leadFacts.leadGender,
    followActive = self:_isFollowActive(leadFacts.firstAlive ~= nil),
  }
  if roamerKey ~= nil then
    attemptMethod = "roamer"
    modifiers.roamerKey = roamerKey
    modifiers.tileMethod = method
  end
  local result = self:attemptEncounter({
    eventId = session.tick,
    mapId = memberId,
    method = attemptMethod,
    movement = "step",
    modifiers = modifiers,
    lead = leadFacts.lead,
    firstAlive = leadFacts.firstAlive,
    environment = { weather = self:_encounterWeather(map) },
    timeOfDay = self:_encounterTimeOfDay(),
    playerProfile = self.playerData.profile,
  })
  if result == nil or result.kind ~= "prepared" or result.encounter == nil then
    return
  end
  if not self.battleCoordinator:hasPresentationFactory() then
    return
  end
  self:_admitStepEncounter(result.encounter --[[@as table<string, unknown>]], method, roamerKey)
end

-- The source roamer step gate: a committed step that already resolved an
-- encounter tile asks the roamer owner which roaming slot stands on the
-- player's map. The owner consumes the source's refusal draw and, with
-- several candidates, its uniform pick; a map without a standing roamer
-- draws nothing. Inert without the roamer owner.
---@return string? the roaming record key this step meets
function FieldRuntime:_stepRoamerKey()
  local roamers = self.roamerState
  local session = self.session
  if type(roamers) ~= "table" or type(roamers.stepEncounterKey) ~= "function" or session == nil then
    return nil
  end
  local map = session.currentMap
  if type(map) ~= "table" or type(map.mapId) ~= "number" then
    return nil
  end
  local mapId = map.mapId --[[@as integer]]
  local scripts = self.scripts
  local rng = scripts ~= nil and scripts.worldState ~= nil and scripts.worldState.rng or nil
  assert(type(rng) == "table", "roamer encounters draw from the world random stream")
  return roamers:stepEncounterKey(mapId, rng)
end

-- The launch details that identify one prepared wild encounter to the
-- battle host: the prepared identity rides the details so the single
-- scenario construction consumes it, never rerolls it.
---@param encounter table<string, unknown> prepared encounter carrying its mon
---@return table<string, unknown> wild launch details
function FieldRuntime:wildLaunchDetails(encounter)
  local mons = encounter.mons --[[@as table<integer, unknown>]]
  assert(type(mons) == "table" and type(mons[1]) == "table", "prepared encounters carry their mon")
  local first = mons[1] --[[@as table<string, unknown>]]
  local mon = assert(first.mon, "prepared encounters carry their mon record") --[[@as table<string, unknown>]]
  assert(type(mon.species) == "string" and mon.species ~= "", "prepared encounters name their species")
  -- Full records derive level from experience rather than storing it, so
  -- derive the launch level the same way the kernel does. The request
  -- validation below still pins it to 1..100.
  local level = mon.level
  if type(level) ~= "number" then
    local catalog = assert(self.monCatalog, "step launches resolve their foe level through the mon catalog")
    local Experience = require("libs.mons.src.gen4.Experience")
    local speciesRecord = catalog:species(mon.species --[[@as string]])
    assert(type(speciesRecord.growthCurve) == "string", "species records name their growth curve")
    assert(type(mon.experience) == "number", "prepared encounters without a level carry their experience")
    level = Experience.level(
      catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      mon.experience --[[@as integer]]
    )
  end
  assert(
    type(level) == "number" and level % 1 == 0 and level >= 1 and level <= 100,
    "prepared encounters carry their level in 1..100"
  )
  return {
    species = mon.species,
    level = level,
    attemptId = encounter.id,
    environment = encounter.environment,
  }
end

-- Runs one field-move encounter attempt (Rock Smash, Headbutt, Sweet Scent)
-- over the active map's encounter table member. Field-move attempts are not
-- steps: they consult their tables without advancing any step counter or
-- arming repel. The live party lead still rides along for deterrence,
-- slot-level, held-item, and generation effects.
---@param method string rock_smash, headbutt, grass, or surf
---@param modifiers table<string, unknown> method modifiers (headbutt slots, sweetScent)
---@return table<string, unknown>? attempt result
function FieldRuntime:attemptFieldMoveEncounter(method, modifiers)
  local session = assert(self.session, "field-move encounters require the field session")
  local map = session.currentMap --[[@as table<string, unknown>]]
  local fieldData = map.fieldData --[[@as table<string, unknown>]]
  local memberId = fieldData.wildEncounterMemberId
  assert(type(memberId) == "number" and memberId % 1 == 0, "field-move encounters resolve their map's table member")
  local staged = { radio = "none", repel = false }
  for key, value in pairs(modifiers) do
    staged[key] = value
  end
  local leadFacts = self:_encounterLeadFacts()
  staged.leadAbility = staged.leadAbility or leadFacts.leadAbility
  staged.leadNature = staged.leadNature or leadFacts.leadNature
  staged.leadGender = staged.leadGender or leadFacts.leadGender
  return self:attemptEncounter({
    eventId = session.tick,
    mapId = memberId,
    method = method,
    movement = "field_move",
    modifiers = staged,
    lead = leadFacts.lead,
    environment = { weather = self:_encounterWeather(map) },
    timeOfDay = self:_encounterTimeOfDay(),
    playerProfile = self.playerData.profile,
  })
end

-- The Sweet Scent encounter roll: the standing tile's step-encounter method
-- (land or surf), nothing where the tile carries none. The scent always
-- draws an encounter from a table with a rate. Unlike rock smash and
-- headbutt, the scripted check applies the live swarm and radio-sound
-- replacements, matching the native land/surf generation paths.
---@return table<string, unknown>? attempt result, nil when the tile allows no encounter
function FieldRuntime:attemptSweetScentEncounter()
  local session = assert(self.session, "sweet scent requires the field session")
  local method = self:_stepEncounterMethod(session.currentMap, assert(self.player, "sweet scent requires the player"))
  if method == nil then
    return nil
  end
  return self:attemptFieldMoveEncounter(method, {
    sweetScent = true,
    radio = self:_currentRadioEffect(),
    swarm = self:_stepSwarmActive(),
  })
end

-- The fishing rod's encounter check (FieldSystem_PerformFishEncounterCheck),
-- rolled when the line is cast: the rod's own table and rate, the lead's
-- ability, the follower's friendship bite bonus, and the night and swarm
-- rod replacements. Fishing never consults Repel. A map without an
-- encounter bank never bites.
---@param rodKey "old_rod"|"good_rod"|"super_rod"
---@return table<string, unknown>? attempt result, nil on a map without encounters
function FieldRuntime:attemptFishingEncounter(rodKey)
  local session = assert(self.session, "fishing requires the field session")
  local map = session.currentMap --[[@as table<string, unknown>]]
  local memberId = (map.fieldData --[[@as table<string, unknown>]]).wildEncounterMemberId
  assert(type(memberId) == "number" and memberId % 1 == 0, "fishing resolves its map's table member")
  if memberId == 255 then
    return nil
  end
  local leadFacts = self:_encounterLeadFacts()
  return self:attemptEncounter({
    eventId = session.tick,
    mapId = memberId,
    method = "fish",
    movement = "fish",
    modifiers = {
      rod = rodKey,
      radio = "none",
      repel = false,
      swarm = self:_stepSwarmActive(),
      leadAbility = leadFacts.leadAbility,
      leadNature = leadFacts.leadNature,
      leadGender = leadFacts.leadGender,
      followActive = self:_isFollowActive(leadFacts.firstAlive ~= nil),
    },
    lead = leadFacts.lead,
    firstAlive = leadFacts.firstAlive,
    environment = { weather = self:_encounterWeather(map) },
    timeOfDay = self:_encounterTimeOfDay(),
    playerProfile = self.playerData.profile,
  })
end

-- The facts the fishing bite reads (fishing.c): whether the follower is
-- active (a follower put away for a bike ride still is), whether the
-- player surfs, and the first alive mon's friendship and mood, the mon the
-- follower's mood belongs to.
---@return { followerActive: boolean, surfing: boolean, friendship: integer, mood: integer }
function FieldRuntime:fishingBiteFacts()
  local firstAlive = self:_encounterLeadFacts().firstAlive
  local facts = {
    followerActive = self:_isFollowActive(firstAlive ~= nil),
    surfing = self:_isSurfing(),
    friendship = 0,
    mood = 0,
  }
  if firstAlive ~= nil then
    facts.friendship = assert(firstAlive.friendship, "party mons carry their friendship")
    facts.mood = assert(firstAlive.mood, "party mons carry their mood")
  end
  return facts
end

-- Admits one prepared step encounter to the presented launch path on its
-- own committed tick. An explicit cancellation still discards it under the
-- existing policy.
---@param encounter table<string, unknown> prepared encounter carrying its mon
---@param method string encounter method for the arrival tile
---@param roamerKey string? the standing roaming record a roamer launch borrowed
function FieldRuntime:_admitStepEncounter(encounter, method, roamerKey)
  local details = self:wildLaunchDetails(encounter)
  local launchId = self.battleCoordinator:nextLaunchIdentity("wild")
  local request = { id = launchId, kind = "wild", payload = details }
  if roamerKey ~= nil then
    request.roamer = self:_roamerBattleSpec(roamerKey)
  end
  self.battleCoordinator:clearReceipt()
  self.battleCoordinator:launchPresentedBattle(launchId, request, method)
end

-- The staged roamer settlement identity behind one roaming wild launch: the
-- record the encounter borrowed, its revision at launch, and the route the
-- battle opens on. The battle owns the outcome and the settled battle health;
-- the source relocates the slot in its own post-battle step, so the delta the
-- battle stages keeps the route the player met it on.
---@param roamerKey string the borrowed roaming record
---@return table<string, unknown> roamer settlement spec for the battle commit
function FieldRuntime:_roamerBattleSpec(roamerKey)
  local roamers = assert(self.roamerState, "roaming launches name their owner")
  local borrowed = roamers:prepareEncounter(roamerKey)
  local revision = assert(borrowed.revision, "roamer records carry their revision")
  assert(type(revision) == "number", "roamer revisions are numbers")
  return {
    owner = roamers,
    key = roamerKey,
    expectedRevision = revision,
    details = { location = borrowed.location },
  }
end

-- The encounter time of day behind step attempts and evolution gating:
-- the encounter tables carry morning, day, and night slots, so the
-- source band folds evening into day beside morning and day. Noon
-- acceptance clocks read day. The result is one of the strings morning,
-- day, or night. Battle composition reads this public operation frozen
-- at launch; it never polls the live clock after return.
---@return string
function FieldRuntime:encounterTimeOfDay()
  return self:_encounterTimeOfDay()
end

-- The encounter time of day behind step attempts: the encounter tables
-- carry morning, day, and night slots, so the source band folds evening
-- into day beside morning and day. Noon acceptance clocks read day. The
-- result is one of the strings morning, day, or night.
---@return string
function FieldRuntime:_encounterTimeOfDay()
  local hour = 12
  if self.localClock ~= nil then
    local okClock, now = pcall(function()
      return self.localClock:nowLocal()
    end)
    if okClock and type(now) == "table" and type(now.hour) == "number" then
      hour = now.hour
    end
  end
  local hourInt = math.floor(hour)
  if hourInt >= 4 and hourInt < 10 then
    return "morning"
  end
  if hourInt >= 20 or hourInt < 4 then
    return "night"
  end
  return "day"
end

---@param map table<string, unknown>?
---@param player table<string, unknown>?
---@return integer? standing metatile behavior when readable, nil otherwise
function FieldRuntime:arrivalBehavior(map, player)
  if type(map) ~= "table" or type(player) ~= "table" or map.collision == nil then
    return nil
  end
  local ok, localX, localZ = pcall(FieldCoordinates.fieldToLocal, map, player.fieldX, player.fieldZ)
  if not ok then
    return nil
  end
  local collision = map.collision --[[@as table<string, unknown>]]
  local contains = collision.containsLocal
  if type(contains) ~= "function" then
    return nil
  end
  if not collision:containsLocal(localX, localZ) then
    return nil
  end
  return collision:getLocal(localX, localZ).behavior
end

---@param map table<string, unknown>
---@param player table<string, unknown>
---@return string? encounter method for the arrival tile, when one applies
function FieldRuntime:_stepEncounterMethod(map, player)
  local behavior = self:arrivalBehavior(map, player)
  if behavior == nil then
    return nil
  end
  if self:_isSurfing() then
    if self:_isSurfEncounterWater(behavior) then
      return "surf"
    end
    return nil
  end
  if self:_isSurfEncounterWater(behavior) then
    return nil
  end
  if MetatileBehavior.canGenerateWalkingEncounters(behavior) then
    return "grass"
  end
  return nil
end

-- Whether one arrival behavior carries surf encounters: the river and sea
-- tiles plus the two further source encounter-water behaviors (pokeheartgold
-- FieldSystem_GetTileEncounterTypeAndRate). Surfable water without the
-- encounter type never encounters, and water on foot never reads the grass
-- tables.
---@param behavior integer? arrival metatile behavior under inspection
---@return boolean true for surf-encounter water
function FieldRuntime:_isSurfEncounterWater(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.RIVER_WATER
    or behavior == MetatileBehavior.BEHAVIOR.SEA_WATER
    or behavior == 18
    or behavior == 42
end

-- The avatar pace behind one committed-step encounter attempt: the native
-- movement roll paces surfing, cycling, and running above walking, so the
-- attempt facts name the durable avatar state and the completed step's
-- semantic speed. Without an avatar or a published step the pace reads
-- as walking.
---@return string locomotion fact for the encounter attempt
function FieldRuntime:_stepLocomotion()
  if self:_isSurfing() then
    return "surf"
  end
  local avatar = self.playerAvatar
  if avatar ~= nil and type(avatar.status) == "function" then
    local status = avatar:status()
    if type(status) == "table" and status.durableState == "cycling" then
      return "cycle"
    end
  end
  local player = self.player
  if player ~= nil and type(player.movementTransaction) == "function" then
    local transaction = player:movementTransaction()
    if type(transaction) == "table" and transaction.speed == "run" then
      return "run"
    end
  end
  return "walk"
end

-- The native snow weather identity behind the ability rate stage: the
-- decomp checks WEATHER_SNOW exactly, so only snow names a weather
-- effect while every other arrival reads as none.
local SNOW_WEATHER_ID = 5

-- Decrements the live repel counter for one committed step and answers
-- the remaining steps. Without roamer state the counter reads spent and
-- repel stays inactive instead of faulting.
---@return integer remaining repel steps
function FieldRuntime:_consumeRepelStep()
  local roamers = self.roamerState
  if type(roamers) ~= "table" then
    return 0
  end
  if type(roamers.stepRepel) == "function" then
    roamers:stepRepel()
  end
  if type(roamers.repelSteps) == "function" then
    local steps = roamers:repelSteps()
    if type(steps) == "number" and steps >= 0 then
      return math.floor(steps)
    end
  end
  return 0
end

-- The Bike Shop calls once the player has biked this many steps
-- (FieldSystem_UpdateBikeShop in src/field/field_control.c).
local BIKE_SHOP_CALL_STEPS = 1024
local BIKE_SHOP_TRIGGER = "gear.trigger.2"

-- Counts the steps the player started on the Bicycle this tick into the
-- steps-biked stat (PlayerAvatar_CountStep counts each as it begins).
function FieldRuntime:_countBikedSteps()
  local stats = assert(self.gameStats, "biked steps count on the live game stats")
  for _ = 1, self.player:takeBikedSteps() do
    stats:countBikedStep()
  end
end

-- FieldSystem_UpdateBikeShop: once the biked steps reach the threshold,
-- and until the shop has called, a processed step raises the shop's call
-- trigger and rings soon. The call script sets the got-call flag.
function FieldRuntime:_raiseBikeShopCall()
  local stats = assert(self.gameStats, "the Bike Shop call reads the live game stats")
  if stats:stepsBikedCount() < BIKE_SHOP_CALL_STEPS then
    return
  end
  if self.eventState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_SYS_GOT_BIKE_SHOP_CALL) then
    return
  end
  local gear = assert(self.pokegearState, "the Bike Shop call reads the live phone triggers")
  if gear:readPhone().triggers[BIKE_SHOP_TRIGGER] == true then
    return
  end
  assert(self.incomingCalls, "the Bike Shop call rings through the incoming calls"):setTrigger(BIKE_SHOP_TRIGGER, true)
end

-- Derives the encounter lead facts from the live party: the slot-0 mon
-- behind ability, deterrence, held-item, gender, and nature effects, plus
-- the first alive mon behind repel and friendship. Egg slot-0 leads
-- arrive with no ability, matching the native state init; with no party
-- or no alive mon the facts stay absent and repel reads inactive rather
-- than faulting.
---@return { lead: table<string, unknown>?, leadAbility: string?, leadNature: integer?, leadGender: string?, firstAlive: table<string, unknown>? }
function FieldRuntime:_encounterLeadFacts()
  local facts = {}
  local service = self.monService
  if type(service) ~= "table" or type(service.partyCount) ~= "function" then
    return facts
  end
  if type(service.partyMon) ~= "function" then
    return facts
  end
  local count = service:partyCount()
  if type(count) ~= "number" or count < 1 then
    return facts
  end
  local lead = service:partyMon(0)
  if type(lead) ~= "table" then
    return facts
  end
  facts.lead = lead --[[@as table<string, unknown>]]
  if lead.isEgg ~= true then
    local ability = lead.ability
    if type(ability) == "string" then
      local EncounterService = require("libs.hgss.src.encounters.HgssEncounterService")
      local key = string.lower(ability)
      if EncounterService.LEAD_ABILITIES[key] == true then
        facts.leadAbility = key
      end
    end
    if type(lead.personality) == "number" then
      facts.leadNature = Personality.nature(lead.personality)
      local catalog = self.monCatalog
      if type(catalog) == "table" and type(catalog.species) == "function" then
        local species = catalog:species(lead.species)
        if type(species) == "table" and type(species.genderRatio) == "number" then
          local gender = Personality.gender(species.genderRatio, lead.personality)
          if gender == "male" or gender == "female" then
            facts.leadGender = gender
          end
        end
      end
    end
  end
  if type(service.leadAliveSlot) == "function" then
    local slot = service:leadAliveSlot()
    if type(slot) == "number" then
      local alive = service:partyMon(slot)
      if type(alive) == "table" then
        facts.firstAlive = alive --[[@as table<string, unknown>]]
      end
    end
  end
  return facts
end

-- Names the ability-stage weather for one arrival map: snow exactly,
-- silence everywhere else, matching the native weather check.
---@param map table<string, unknown>? arrival map under inspection
---@return string snow on snow weather, none otherwise
function FieldRuntime:_encounterWeather(map)
  if type(map) == "table" and map.effectiveWeatherId == SNOW_WEATHER_ID then
    return "snow"
  end
  return "none"
end

-- Whether a follower walks behind the player for the fishing bite bonus:
-- an active follower controller with an alive mon behind it, matching
-- the native follow check.
---@param hasAliveMon boolean the party holds an alive mon
---@return boolean
function FieldRuntime:_isFollowActive(hasAliveMon)
  if not hasAliveMon then
    return false
  end
  local following = self.followingMon
  if type(following) ~= "table" or type(following.isActive) ~= "function" then
    return false
  end
  return following:isActive() == true
end

-- The follower's zero-based party slot for battle launches, nil when no
-- follower walks behind the player. The slot matches the battle view's
-- party-slot mapping (BattleSystem_GetFollowMonSlot, 0xFF when absent).
---@return integer? follower party slot, nil without one out
function FieldRuntime:_launchFollowMonSlot()
  local service = self.monService
  if type(service) ~= "table" or type(service.leadAliveSlot) ~= "function" then
    return nil
  end
  local slot = service:leadAliveSlot()
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
    return nil
  end
  if not self:_isFollowActive(true) then
    return nil
  end
  return slot
end

-- Resets the step-driven encounter counters on map entry: the native field
-- system clears both counters whenever a warp completes. Fresh boot needs
-- no call; the composed service starts cleared.
function FieldRuntime:resetEncounterStepCounters()
  local service = self._encounters
  if service ~= nil then
    service:resetStepCounters()
  end
end

---@return boolean true while the avatar surfs
function FieldRuntime:_isSurfing()
  local avatar = self.playerAvatar
  if avatar == nil then
    return false
  end
  local status = avatar:status()
  return type(status) == "table" and status.durableState == "surfing"
end

function FieldRuntime:_saveCheckpoint()
  return assert(self.saveCoordinator, "field runtime has no save coordinator"):save()
end

-- The fishing rods' runtime scripts by item; the Bicycle has its own.
local ROD_BY_ITEM = { OLD_ROD = "old_rod", GOOD_ROD = "good_rod", SUPER_ROD = "super_rod" }

-- Uses a field-use key item (ItemCheckUseFunc_Bicycle/_FishingRod) from
-- the Bag or its registered slot, checked over fresh world facts: an
-- allowed use starts the item's script; a refused registered use prints
-- the item check's refusal in the field (RegisteredItem_GoToPrintErrorTask),
-- while the Bag answers its own refusals before leaving and a refusal here
-- is an admission fault. Answers false for items without a field use.
---@param itemKey string
---@param registered boolean whether the use came from a registered slot
---@return boolean true when the use claimed the field
function FieldRuntime:useKeyItem(itemKey, registered)
  local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
  if not FieldMovePolicy.hasKeyItemCheck(itemKey) then
    return false
  end
  local BuiltinScripts = require("libs.hgss.src.script.BuiltinScripts")
  local FieldMoveContext = require("game.hgss.src.field.FieldMoveContext")
  local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
  local decision = FieldMovePolicy.checkKeyItem(itemKey, FieldMoveContext.capture(self:_menuFieldSources()()))
  local rod = ROD_BY_ITEM[itemKey]
  local scriptId = rod ~= nil and BuiltinScripts.FISHING_SCRIPTS[rod] or BuiltinScripts.BICYCLE_SCRIPT
  if decision.kind ~= "ok" then
    if not registered then
      error("pokemon.key_item admission refused: " .. tostring(decision.kind), 0)
    end
    scriptId = assert(
      BuiltinScripts.ITEM_USE_REFUSAL_SCRIPTS[decision.kind],
      "key item refusal has no message: " .. tostring(decision.kind)
    )
  end
  local session = assert(self.session, "key item use requires the field session")
  local client = assert(self.scripts and self.scripts.client, "key item use requires the script client")
  local started = client:startApplicationScript(scriptId, session.tick + 1)
  if started == nil or started == ScriptInteractionClient.RESULTS.blocked then
    error("key item use scheduling failed without a foreground claim", 0)
  end
  return true
end

-- The synchronous child-to-field admission command behind the host's
-- field_action results. Queues the converged request, then claims the
-- scheduler foreground synchronously: a normal return guarantees the
-- claim already exists. A refused queue or failed schedule discards
-- only the still-unclaimed pending request and raises an attributed
-- admission error into the host failure path; it never returns false
-- or nil, which the host would mistake for a scheduled action. The
-- launching UI batch stays with the disposed child and never reaches
-- the task, which first polls on a later scheduler tick.
---@param actionId string
---@param request table<string, unknown>?
---@return unknown the scheduler claim on success
function FieldRuntime:_admitFieldAction(actionId, request)
  if actionId == "vanilla.save" then
    return self:_saveCheckpoint()
  end
  if actionId == "pokemon.key_item" then
    local itemKey = assert(request and request.item, "key item admission names its item")
    -- The Bag checked the use on selection; a world that changed since
    -- refuses here instead of scheduling.
    local started = self:useKeyItem(itemKey, false)
    assert(started, "key item admission requires a field-use key item")
    return started
  end
  assert(actionId == "pokemon.field_move", "unknown field action " .. tostring(actionId))
  local BuiltinScripts = require("libs.hgss.src.script.BuiltinScripts")
  local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
  local composition = assert(self.partyMenu, "field admission requires the menu composition")
  local fieldMoves = assert(composition.fieldMoves, "field admission requires the field runtime")
  local flowRequest = assert(request, "field admission requires its request")
  assert(type(flowRequest.move) == "string", "field admission requires its move key")
  -- Fresh world facts for the admission recheck: the flow checked
  -- moments ago, but badges, maps, and facing may have changed since
  -- boot ambient was captured, so rechecks run on current facts.
  -- Travel rides along for return planning; other moves ignore it.
  -- A refused recheck raises below instead of scheduling.
  local FieldMoveContext = require("game.hgss.src.field.FieldMoveContext")
  local sources = self:_menuFieldSources()()
  local context = FieldMoveContext.capture(sources)
  local travel = nil
  if composition.fieldTravel ~= nil then
    travel = composition.fieldTravel:capture()
  end
  -- Fly is the one field move that needs the region-map facts: the source
  -- selector needs the live map context and the player's confirmed flypoint
  -- set, both read from the composed companion feature. Other moves ignore
  -- them.
  local mapContext, destinations = nil, nil
  if flowRequest.move == "fly" then
    local gear = assert(self.pokegear, "fly admission requires the composed companion feature")
    mapContext = gear.mapContext()
    destinations = gear.flyDestinations()
  end
  local queued = fieldMoves:queue({
    move = flowRequest.move,
    slot = flowRequest.slot,
    moveSlot = flowRequest.moveSlot,
    partyRevision = flowRequest.partyRevision,
    context = context,
    travel = travel,
    mapContext = mapContext,
    destinations = destinations,
  })
  local session = assert(self.session, "field admission requires the field session")
  local client = assert(self.scripts and self.scripts.client, "field admission requires the script client")
  if type(queued) == "table" and queued.kind == "already_active" then
    -- Retail menu Strength with the permission already set runs the menu
    -- script, which reads FLAG_STRENGTH_ACTIVE and says Strength is in use.
    self.scripts.worldState:setVar(0x8000, flowRequest.slot)
    local reply = client:startApplicationScript("common.menu_strength", session.tick + 1)
    if reply == ScriptInteractionClient.RESULTS.blocked then
      error("pokemon.field_move admission scheduling failed without a foreground claim", 0)
    end
    return reply
  end
  if type(queued) ~= "table" or queued.kind ~= "accepted" then
    error("pokemon.field_move admission refused: " .. tostring(queued and queued.kind), 0)
  end
  -- Moves whose party-menu use runs a script that owns the whole move: the
  -- retail menu scripts (cues, effect, aftermath) and the runtime Sweet
  -- Scent script.
  local menuScript = ({
    rock_smash = "common.menu_rock_smash",
    headbutt = "common.menu_headbutt",
    sweet_scent = BuiltinScripts.SWEET_SCENT_SCRIPT,
  })[flowRequest.move]
  if menuScript ~= nil then
    -- Menu scripts read the party slot from the first special variable and
    -- the struck object as their last-talked actor. The admission queue only
    -- vetted eligibility.
    fieldMoves:discardPending()
    self.scripts.worldState:setVar(0x8000, flowRequest.slot)
    if flowRequest.move == "sweet_scent" then
      -- Task_SweetScentEffect: the visible lead follower performs the scent
      -- with a jump, cheered when it is a Grass type.
      local mons = assert(self.monService, "sweet scent requires the mon service")
      local follower = self.followingMon
      if flowRequest.slot == mons:leadAliveSlot() and follower ~= nil and follower:isVisible() then
        mons:cheerFollowerOfType("grass")
      end
    end
    local target = context.facingActor
    local reply = client:startApplicationScript(
      menuScript,
      session.tick + 1,
      target ~= nil and { selfActor = target.identity } or nil
    )
    if reply == ScriptInteractionClient.RESULTS.blocked then
      error("pokemon.field_move admission scheduling failed without a foreground claim", 0)
    end
    return reply
  end
  if flowRequest.move == "escape_rope" then
    -- The Rope is spent as the bag closes, before the return animation.
    assert(self.bagService:take("ESCAPE_ROPE", 1), "the Escape Rope use requires the item in the bag")
  end
  local started = client:startApplicationScript(BuiltinScripts.FIELD_MOVE_ENTRY_SCRIPT, session.tick + 1)
  if started == nil or started == ScriptInteractionClient.RESULTS.blocked then
    fieldMoves:discardPending()
    error("pokemon.field_move admission scheduling failed without a foreground claim", 0)
  end
  return started
end

-- Apply effective weather to a runtime map: resolve the catalog rules
-- against the injected date/penalty and event state, store
-- effectiveWeatherId for headless inspection, and select the fog preset
-- (the generated base fog when unchanged, catalog preset otherwise).
function FieldRuntime:_applyEffectiveWeather(runtimeMap)
  local base = runtimeMap.renderEnvironment.baseWeatherId
  local date = self.weatherClock:today()
  local hasPenalty = self.weatherClock:hasPenalty()
  local effective = FieldWeatherResolver.resolve(self.weatherCatalog, {
    mapId = runtimeMap.mapId,
    baseWeatherId = base,
    eventState = self.eventState,
    date = date,
    hasPenalty = hasPenalty,
  })
  self:_setLiveWeather(runtimeMap, effective)
end

function FieldRuntime:_setLiveWeather(runtimeMap, weatherId)
  assert(type(runtimeMap) == "table", "live weather requires a runtime map")
  assert(type(weatherId) == "number" and weatherId % 1 == 0, "live weather id must be an integer")
  local environment = assert(runtimeMap.renderEnvironment, "live weather requires the runtime render environment")
  local catalogPreset = assert(self.weatherCatalog.presets[weatherId], "live weather id has no catalog preset")
  local preset = weatherId == environment.baseWeatherId and environment.baseFog or catalogPreset
  runtimeMap.effectiveWeatherId = weatherId
  self.lastEffectiveWeatherId = weatherId
  environment.fog = preset
end

-- Advance the active map's field lighting from the injected local clock,
-- every runtime update (unlike weather, which only samples its clock on map
-- activation). A render environment without a `fieldTimeSeconds` field
-- carries no live time-of-day state to advance. The banded animated-prop
-- clip swap is a separate, presentation-only concern that lives on the
-- scene runtime rather than the render environment.
function FieldRuntime:_refreshFieldTimeOfDay()
  local runtimeMap = self.runtimeMap
  local environment = runtimeMap and runtimeMap.renderEnvironment
  if environment == nil or environment.fieldTimeSeconds == nil then
    return
  end
  local now = self.localClock:nowLocal()
  local seconds = now.hour * 3600 + now.minute * 60 + now.second
  environment.fieldTimeSeconds = seconds
  local sceneRuntime = runtimeMap.sceneRuntime
  if sceneRuntime and sceneRuntime.setTimeBand then
    sceneRuntime:setTimeBand(TimeOfDayProps.bandForSeconds(seconds))
  end
end

-- Take the staged destination for this resolution once it is finished. A
-- completed window is transferred to the swap owner when this returns; until
-- then the transition still owns it, so a failure here leaves a releasable
-- stage behind instead of an orphaned cell task.
---@param matrixMemberId integer
---@param anchorX integer
---@param anchorZ integer
---@return FieldRuntimePhysicalSwap?
function FieldRuntime:_takeDestinationStage(matrixMemberId, anchorX, anchorZ)
  local transition = self.transition
  if transition == nil then
    return nil
  end
  local stage = transition:destinationStageFor(matrixMemberId, anchorX, anchorZ)
  if stage == nil then
    return nil
  end
  local swap = stage:finish()
  transition:takeDestinationStage()
  return swap
end

-- Select the physical owner for a discontinuous outdoor destination. A
-- matching matrix is reusable only when its resident window is centered on
-- the destination cell; otherwise the new owner remains transition-owned
-- until the prepared swap commits.
---@param logicalMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@param matrixMemberId integer
---@return FieldRuntimePhysicalSwap
function FieldRuntime:_stagePhysicalCoverage(logicalMap, position, matrixMemberId)
  local coordinator = assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator")
  -- A covered transition may already have staged this exact destination while the
  -- cover was up; the resolution then adopts that finished window instead of
  -- rebuilding it on the frame that finishes loading.
  local staged =
    self:_takeDestinationStage(matrixMemberId, math.floor(position.fieldX / 32), math.floor(position.fieldZ / 32))
  if staged ~= nil then
    return staged
  end
  return coordinator:stagePhysicalCoverage(logicalMap, position, matrixMemberId)
end

-- Begin staging the destination under the held cover, before it is resolved.
-- Destination planning is a scene-free coordinate decision over generated field
-- data: arrival coordinates and outdoor membership come from the map record and
-- catalog, so the plan is the one authoritative arrival decision for every kind
-- of destination. What the stage then stages is the destination runtime load
-- itself, for every destination, plus a new physical window only where the
-- live one cannot serve the arrival. The resolution reads the published runtime
-- instead of loading it again, so no destination pays its whole map load in the
-- frame that finishes loading.
---@param sourceMap table<string, unknown>
---@param warp table<string, unknown>
---@param dynamicWarp table<string, unknown>?
---@return { advance: fun(units: integer): integer, isReady: fun(): boolean, release: fun(), plan: WarpSystem.DestinationPlan }
function FieldRuntime:beginDestinationStage(sourceMap, warp, dynamicWarp)
  local coordinator = assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator")
  local loader = self.mapLoader
  local function loadMetadata(_, idOrSymbol)
    return loader:loadLogical(idOrSymbol)
  end
  local plan = WarpSystem.destinationPlan({ load = loadMetadata }, sourceMap, warp, dynamicWarp)
  -- The plan located its map through scene-free metadata; the runtime
  -- resolution still reads the loaded map, under this one plan's arrivals and
  -- through the identity the record named.
  plan.metadataOnly = true
  local logicalMap = plan.destinationMap
  local mapId = logicalMap.mapId
  local position = { fieldX = plan.coordinates.fieldX, fieldZ = plan.coordinates.fieldZ }
  -- The compiled scene record is the area-type authority: a matrix entry alone
  -- does not make a map outdoor (indoor maps carry a single matching cell).
  local scene = loader:sceneRecord(mapId)
  local matrixMemberId = nil
  local anchorX, anchorZ = nil, nil
  local needsWindow = false
  if type(scene) == "table" and scene.type == "outdoor" then
    matrixMemberId = mapMatrixMemberId(self, logicalMap)
    anchorX = math.floor(position.fieldX / FieldGrid.CELL_TILES)
    anchorZ = math.floor(position.fieldZ / FieldGrid.CELL_TILES)
    local current = self.physicalCoverage
    -- The live window already serving this destination keeps it: the ordinary
    -- swap path reuses it instead of rebuilding the same cells into a second
    -- owner. Same-window destinations therefore stage the runtime alone.
    needsWindow = not (
      current ~= nil
      and current.matrixMemberId == matrixMemberId
      and current.anchorX == anchorX
      and current.anchorZ == anchorZ
    )
  end
  ---@type FieldMapLoader.StagedTask?
  local loadTask = loader:beginLoad(plan.selector)
  ---@type FieldRuntimePhysicalSwap?
  local swap = nil
  local stage = { plan = plan }
  function stage:advance(units)
    assert(type(units) == "number" and units >= 0 and units % 1 == 0, "destination staging consumes integral work")
    local consumed = 0
    if loadTask ~= nil then
      consumed = consumed + loadTask:advance(units)
      if not loadTask:isReady() then
        return consumed
      end
      -- The destination runtime publishes through the loader's own entry cache
      -- exactly once; its window then builds on that runtime.
      loadTask:takeResult()
      loadTask = nil
      if needsWindow then
        swap = coordinator:beginPhysicalCoverage(assert(loader:get(mapId)), position, assert(matrixMemberId))
      end
    end
    if not needsWindow then
      return consumed
    end
    local window = assert(swap, "a finished destination load owns its physical window")
    return consumed + assert(window.task, "a staging window owns its task"):advance(units - consumed)
  end
  function stage:isReady()
    if loadTask ~= nil then
      return false
    end
    if not needsWindow then
      return true
    end
    return swap ~= nil and swap.task ~= nil and swap.task:isReady()
  end
  -- Whether this finished stage describes the physical window a resolution is
  -- about to need.
  function stage:matches(candidateMatrixMemberId, candidateAnchorX, candidateAnchorZ)
    if not needsWindow then
      return false
    end
    return matrixMemberId == candidateMatrixMemberId and anchorX == candidateAnchorX and anchorZ == candidateAnchorZ
  end
  -- Transfer the finished window into the swap record exactly once.
  function stage:finish()
    assert(swap ~= nil, "destination stage has no finished window")
    return coordinator:finishPhysicalCoverage(swap)
  end
  function stage:release()
    if loadTask ~= nil then
      loadTask:release()
      loadTask = nil
    end
    if swap ~= nil and swap.task ~= nil then
      coordinator:releasePhysicalCoverage(swap)
    end
  end
  return stage
end

-- Fallible warp preparation, run by FieldTransition while the source map is
-- still authoritative: construct the destination player, camera, and player
-- visual, then stage logical residency as the final ownership-bearing step.
-- The coordinator keeps the source logical world live until the hidden commit.
---@param resolution table<string, unknown>
---@param facing FieldDirection
---@return table<string, unknown> prepared destination player, camera, and player visual
function FieldRuntime:_prepareSwap(resolution, facing)
  return assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator"):prepare(resolution, facing)
end

-- Dispose only transition-owned physical state. A reused coverage remains
-- owned by the runtime, while a staged replacement is released once on abort.
---@param resolution table<string, unknown>?
---@param prepared table<string, unknown>?
---@return nil
function FieldRuntime:_disposePreparedSwap(resolution, prepared)
  return assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator"):abort(resolution, prepared)
end

-- The irreversible current-map ownership transfer, run by FieldTransition
-- only after every fallible preparation step succeeded. Logical residency is
-- published first; runtime/session pointers and physical ownership follow.
---@param resolution table<string, unknown>
---@param prepared table<string, unknown>
---@return nil
function FieldRuntime:_commitSwap(resolution, _, prepared)
  return assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator"):commit(
    resolution,
    _,
    prepared
  )
end

function FieldRuntime:destinationWorldPresentable()
  return self.session:destinationWorldPresentable()
end

function FieldRuntime:acknowledgeDestinationPresentation()
  self.session:acknowledgeDestinationPresentation()
end

---@param camera FieldCamera
function FieldRuntime:configureCameraProjection(camera)
  local grid = assert(self.viewport.pixelGrid, "field projection requires a published pixel grid")
  camera:setProjectionAspect(grid.allocationWidth / grid.allocationHeight)
  camera:setZoom(192 / grid.allocationHeight)
end

function FieldRuntime:_updateCameraProjection()
  self.fieldPixelScale:resize(self.viewport.referenceFrame.height)
  local measurement = self.presentationDisplay
  if measurement == nil then
    measurement = self.displayContext:measure(self.viewport.width, self.viewport.height)
  end
  local nominal = self.fieldPixelScale:resolvedScale()
  local ratio = assert(measurement.pixelRatio)
  local worldHeight = self.viewport.worldViewport.height
  local referenceHeight = self.viewport.referenceFrame.height
  local physicalScale = math.max(1, math.floor(nominal * ratio * worldHeight / referenceHeight + 0.5))
  local candidateGrid = PixelScale.cover(self.viewport.worldViewport, physicalScale, ratio)
  self.viewport.pixelGrid = candidateGrid
  self:configureCameraProjection(self.camera)
end

-- Re-apply the user's field-scale change to the camera projection.
function FieldRuntime:applyFieldPixelScaleChange()
  self:_updateCameraProjection()
end

-- The contextual two-choice presentation record shared by field draw and
-- fixed-tick pointer translation. Nil while no contextual prompt is open;
-- otherwise the provider selection plus the generated Yes/No labels. Draw
-- and input consume this one record so labels and geometry cannot drift.
---Returns nil while no contextual prompt is open or while presentation
---geometry is unavailable (no screen topology): pointer translation and
---draw share this one record, so an unpresentable choice disables both
---and the tick falls back to the pre-existing raw lane.
---@return { active: boolean, selectedIndex: integer, yesText: string, noText: string, frameIndex: integer? }|nil
function FieldRuntime:contextChoicePresentation()
  local provider = self.contextChoiceProvider
  if provider == nil then
    return nil
  end
  if self.screenTopology == nil then
    return nil
  end
  local status = provider:status()
  if status == nil then
    return nil
  end
  assert(status.selected == 0 or status.selected == 1, "contextual choice selection is outside the two choices")
  local dialogueHost = assert(
    self.scripts and self.scripts.dialogueHost,
    "contextual choice presentation requires the script dialogue host"
  )
  local options = dialogueHost:yesNoOptions()
  return {
    active = true,
    selectedIndex = status.selected,
    yesText = options.yesText,
    noText = options.noText,
    frameIndex = options.frameIndex,
  }
end

-- The central 4:3 reference region and field scale that list menus anchor in.
---@return { bounds: { x: number, y: number, width: number, height: number }, preferredScale: integer }
function FieldRuntime:menuPresentationContext()
  local viewport = assert(self.viewport, "menu presentation requires the field viewport")
  return {
    bounds = assert(viewport.referenceFrame, "menu presentation requires the 4:3 reference frame"),
    preferredScale = assert(self.fieldPixelScale, "menu presentation requires the field scale"):resolvedScale(),
  }
end

-- Presentation facts for the live choice host: the same bounds, dialogue
-- anchor, and preferred scale the field draw uses for its attached UI.
---@return { topology: ScreenTopology, bounds: { x: number, y: number, width: number, height: number }, dialogueBox: { x: number, y: number, width: number, height: number }?, preferredScale: integer }
function FieldRuntime:yesNoPresentationContext()
  local viewport = assert(self.viewport, "choice presentation requires the field viewport")
  local bounds = viewport.worldViewport
  if type(bounds) ~= "table" or type(bounds.width) ~= "number" or type(bounds.height) ~= "number" then
    bounds = viewport.referenceFrame
  end
  if type(bounds) ~= "table" or type(bounds.width) ~= "number" or type(bounds.height) ~= "number" then
    bounds = {
      x = 0,
      y = 0,
      width = assert(self.viewportWidth, "choice presentation requires viewport dimensions"),
      height = assert(self.viewportHeight, "choice presentation requires viewport dimensions"),
    }
  end
  local fieldScale = assert(self.fieldPixelScale, "choice presentation requires the field scale"):resolvedScale()
  local dialogueBox
  local preferredScale = fieldScale
  if assert(self.dialogue, "choice presentation requires the dialogue controller"):isModal() then
    local manifestPlacement = assert(self.uiManifest).dialogueFrames.continueCursor.placement
    local dialogueScale = PixelScale.fitPreferred(bounds, 256, 48, assert(fieldScale))
    dialogueBox = DialoguePresentationLayout.compute(bounds, {
      scale = dialogueScale,
      allowClipping = true,
      cursorPlacement = manifestPlacement,
    }).outerRect
    preferredScale = dialogueScale
  end
  return {
    topology = assert(self.screenTopology, "choice presentation requires the screen topology"),
    bounds = bounds,
    dialogueBox = dialogueBox,
    preferredScale = preferredScale,
  }
end

-- Presentation geometry sync owned by the runtime: the viewport and menu
-- host geometry, the new screen topology, the complete measured display,
-- and the camera projection update together. FieldState calls this exactly
-- once per structural presentation-geometry change.
---@param width integer
---@param height integer
---@param screenTopology ScreenTopology
function FieldRuntime:resizePresentation(width, height, screenTopology)
  self.screenTopology = screenTopology
  self.viewport:resize(width, height)
  self.menuHost:resize(width, height)
  self.menuHost:setScreenTopology(screenTopology)
  self.yesNoHost:resize(width, height)
  self.yesNoHost:setScreenTopology(screenTopology)
  self._displayTopology = screenTopology
  self.presentationDisplay = self.displayContext:measure(width, height)
  self:_updateCameraProjection()
  if self.martHost then
    self.martHost:refreshPresentation()
  end
end

-- The one teardown path shared by reset and dispose: release every owned
-- collaborator exactly once and clear every owned field, so a later release
-- call is a no-op. Disposing the dialogue first is deliberate -- a half-open
-- dialogue must never be persisted, so dispose() saves against a cancelled
-- dialogue -- and the field clearing means reset never leaves a hand-picked
-- subset behind for its re-boot.
function FieldRuntime:_releaseAll()
  if self.assetNeeds then
    self.assetNeeds:dispose()
  end
  if self.celebiTimeTravelScene then
    self.celebiTimeTravelScene:abort()
    self.celebiTimeTravelScene = nil
  end
  if self.session then
    self.session:dispose()
  end
  if self.battleCoordinator then
    self.battleCoordinator:dispose()
    self.battleCoordinator = nil
  end
  if self.propAnimations then
    self.propAnimations:clear()
  end
  -- A source floor box outlives the script that showed it, so field teardown
  -- releases whatever is still open exactly once.
  if self.scripts ~= nil and self.scripts.floorWindow ~= nil then
    self.scripts.floorWindow:dispose()
  end
  if self.overworld then
    self.overworld:dispose()
  end
  if self.blackoutFlow then
    self.blackoutFlow:dispose()
  end
  if self.transition then
    -- A covered transition still staging its destination window owns cell tasks
    -- and decoded leases: teardown releases them through the same owner that
    -- would release a resolved-but-uncommitted swap.
    if type(self.transition.releaseDestinationStage) == "function" then
      self.transition:releaseDestinationStage()
    end
    self:_disposePreparedSwap(self.transition.resolution, self.transition.prepared)
  end
  self.menuComposer:releaseModalHosts()
  if self.martHost then
    self.martHost:dispose()
  end
  if self.pcApplicationHost then
    self.pcApplicationHost:dispose()
  end
  if self.easyChatScriptHost ~= nil then
    self.easyChatScriptHost:dispose()
  end
  if self.kurtBoxHost then
    self.kurtBoxHost:dispose()
  end
  if self.moneyBox then
    -- The transient source money window is field presentation state: close
    -- it so no window outlives the field that opened it.
    self.moneyBox:dispose()
  end
  if self.pcTerminal then
    self.pcTerminal:releaseEffect()
  end
  self.pcApplicationHost, self.pcTerminal = nil, nil
  self.easyChatScriptHost = nil
  self.martHost = nil
  self.kurtBoxHost = nil
  self.moneyBox = nil
  self.applications = nil
  self.displayContext, self.presentationDisplay, self.presentationOverrides = nil, nil, nil
  self._displayTopology = nil
  self.mapNameBanner = nil
  self.shortcutSlide = nil
  if self.messageProvider then
    self.messageProvider:dispose()
  end
  self.messageProvider = nil
  if self.residency then
    self.residency:dispose()
  end
  self.residency = nil
  if self.rocketHideoutEffects then
    self.rocketHideoutEffects:unbind()
  end
  self.rocketHideoutEffects = nil
  if self.trainerEncounter then
    self.trainerEncounter:dispose()
  end
  self.trainerEncounter = nil
  if self.gymMechanism then
    self.gymMechanism:unbind()
  end
  self.gymMechanism = nil
  self.gymMechanismGeometry = nil
  self.gymMechanismState = nil
  self.followingMonState = nil
  if self.followingMon then
    self.followingMon:dispose()
  end
  self.followingMon = nil
  if self.followingMonTransition then
    self.followingMonTransition:dispose()
  end
  self.followingMonTransition = nil
  if self.pokemonCenterHeal then
    self.pokemonCenterHeal:dispose()
  end
  self.pokemonCenterHeal, self.pokemonCenterHealDefinition = nil, nil
  self.starterBalls = nil
  self.followerTransitionDefinition = nil
  if self.actors then
    self.actors:dispose()
  end
  self.playerVisual = nil
  if self.actorAssets then
    local dispose = assert(self.actorAssets.dispose, "field actor assets dispose operation is required")
    dispose(self.actorAssets)
  end
  if self.physicalCoverage then
    self.physicalCoverage:release()
  end
  -- The field-owned audio composition is disposed as a whole: the sink stops,
  -- the mixer returns every physical voice's sample acquisition, then the
  -- provider's active records are released -- all before the map, GPU and
  -- message borrowers below. The shared preparation queue and its resident
  -- bytes belong to the selected runtime and stay alive.
  if self.audioComposition then
    self.audioComposition:dispose()
    self.audioComposition = nil
  end
  if self.mapLoader then
    self.mapLoader:release()
  end
  -- The session image owner is disposed after every scene and actor lease
  -- has been returned through the releases above, but before the
  -- preparation worker is joined below.
  if self.imageAssets then
    self.imageAssets:dispose()
  end
  self.imageAssets = nil
  -- The preparation worker is released after every presentation scene
  -- consumer and pending task above, so no outstanding prepared token can
  -- outlive its queue.
  -- The selected preparation queue and its decoded owner belong to the
  -- selected runtime; field teardown releases only this runtime's own image
  -- owner above and drops the borrowed references here.
  self.assetPreparation = nil
  self.decoded = nil
  self.acquireSource = nil
  self.actors, self.actorAssets, self.mapLoader = nil, nil, nil
  self.audio, self.audioSink, self.audioComposition, self.mapMusicDayNight = nil, nil, nil, nil
  self._predictionDriver = nil
  self.session, self.saveStore, self.scripts = nil, nil, nil
  self.transition, self.camera, self.player, self.runtimeMap, self.physicalCoverage = nil, nil, nil, nil, nil
  self.fieldTerrainEffectController = nil
  self.fieldEffectAssets = nil
  self.fieldEntranceIndicator, self.fieldEntranceIndicatorAsset = nil, nil
  self.fieldEmoteModels = nil
  self.followerReactionTicks = nil
  self.viewport, self.input, self.menuHost = nil, nil, nil
  self.yesNoHost = nil
  self.auxiliaryFieldUi, self.contextChoiceProvider, self.interactionResolver = nil, nil, nil
  self.eventState, self.avatar, self.actorConfig, self.playerData = nil, nil, nil, nil
  self.playerAvatar = nil
  self.windowStyles, self.uiManifest, self.fontDef, self.weatherCatalog = nil, nil, nil, nil
  self.monCatalog, self.monLanguage, self.monService = nil, nil, nil
  self.monPicture = nil
  if self.legendEventScene ~= nil then
    self.legendEventScene:cancel("the field retired")
  end
  self.legendEventScene = nil
  self.easyChatCatalog, self.easyChatState = nil, nil
  self._easyChatPreparation, self._easyChatBindingId = nil, nil
  self.pokedexCatalog, self.dexKnowledge, self.gameStats = nil, nil, nil
  self.bagService, self.bagCursor = nil, nil
  self.martService = nil
  self.mailbox, self.photoAlbum, self.sysInfo = nil, nil, nil
  self.fieldPoison, self.poisonEffect, self.poisonCure = nil, nil, nil
  if self.pokegear ~= nil then
    self.pokegear:dispose()
  end
  self.pokegear = nil
  self.pokegearApplications = nil
  self.incomingCalls = nil
  self.pokegearManifest, self.pokegearCatalog = nil, nil
  self.pokegearState, self.pokegearRandom, self.pokegearCalendar = nil, nil, nil
  self.martStockResolver = nil
  self.itemCatalog = nil
  self.followerInteractionCatalog = nil
  self.starterProvider, self.starterChoice, self.monNaming = nil, nil, nil
  self.partySelection = nil
  self.partyMenu, self.menuLaneWarps = nil, nil
end

-- End the state's lifetime: persist the field session if one is live, then
-- release every owned resource exactly once through the shared teardown. This
-- is the single general disposal hook invoked by App on both state
-- replacement and application shutdown; clearing the capture-bearing fields
-- in the teardown makes a repeat call a no-op rather than a second save.
function FieldRuntime:dispose()
  -- A half-open dialogue must never be persisted; disposal cancels it cleanly
  -- before the capture (and releases it once, before the shared teardown).
  if self.dialogue then
    self.dialogue:dispose()
    self.dialogue = nil
  end
  -- The same transient gate applies to the signpost: a presented window is
  -- cancelled before the save attempt, never persisted.
  if self.signpost then
    self.signpost:dispose()
    self.signpost = nil
  end
  -- The application host owns the other transient modal (the Start Menu, an
  -- application fade, or a child application).
  if self.applicationHost then
    self.applicationHost:dispose()
  end
  if self.pcApplicationHost then
    self.pcApplicationHost:dispose()
  end
  if self.easyChatScriptHost ~= nil then
    self.easyChatScriptHost:dispose()
    self.easyChatScriptHost = nil
  end
  if self.pcTerminal then
    self.pcTerminal:releaseEffect()
  end
  -- The starter choice is the script-owned transient modal: an open choice
  -- releases its controller and portrait resources, never the candidates
  -- the task owns.
  -- The script party host is the script-owned transient modal: an open
  -- selection releases its screen, never the live party it observed.
  if self.partySelection then
    self.partySelection:dispose()
  end
  -- The menu composition owns the field-move runtime: cancel owned
  -- pending/active work exactly once; borrowed services stay live for
  -- the remaining teardown below.
  if self.partyMenu then
    self.partyMenu.dispose()
  end
  if self.starterChoice then
    self.starterChoice:dispose()
  end
  if self.monNaming then
    self.monNaming:dispose()
  end
  self:_releaseAll()
end

return FieldRuntime
