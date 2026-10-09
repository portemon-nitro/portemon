-- Normal field-runtime coordinator. It joins generated maps through
-- FieldMapLoader, drives the deterministic elevation-aware player, and
-- exposes the field warp transition lifecycle.

local CacheFs = require("libs.storage.src.CacheFs")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local PixelScale = require("libs.ui.src.PixelScale")
local FieldActorDefinitionProvider = require("libs.hgss.src.actors.FieldActorDefinitionProvider")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldInteractionResolver = require("libs.hgss.src.interaction.FieldInteractionResolver")
local FieldEventResolver = require("libs.hgss.src.interaction.FieldEventResolver")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldPlayerAvatarState = require("libs.hgss.src.actors.FieldPlayerAvatarState")
local FieldPlayerVisual = require("libs.hgss.src.actors.FieldPlayerVisual")
local FieldZoneIdentity = require("libs.hgss.src.world.FieldZoneIdentity")
local FollowingMonController = require("libs.hgss.src.field.FollowingMonController")
local GameSave = require("libs.hgss.src.save.GameSave")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local FieldScriptScreenFade = require("libs.hgss.src.transition.FieldScriptScreenFade")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
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
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowStyles = require("libs.hgss.src.field.FieldWindowStyles")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
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
---@field derivedAssets table<string, function>? semantic derived-asset host
---@field localClock LocalClock? injectable host-local civil-time boundary
---@field weatherClock table<string, unknown>? injectable host boundary { today()->{month,day}, hasPenalty()->boolean }
---@field saveStore FieldRuntimeSaveStore? global publication owner

---@class FieldRuntimeScriptHosts
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
---@field fashionCase FashionCaseState live accessory inventory restored from the save
---@field followerInteractionCatalog table<string, unknown> generated follower interaction rules
---@field followerReactionTicks table<string, integer> follower reaction emote kind -> emote action duration
---@field bagService HgssBagService the live bag/inventory service
---@field martService MartService the live mart inventory/session service
---@field martHost table<string, unknown> the one script-owned mart child host
---@field martStockResolver function the selected mart stock provider
---@field battleRuntime table<string, unknown>? the owned application battle lifetime (nil outside battles)
---@field battlePresentation table<string, unknown>? presentation port for owned battles
---@field pendingEncounterId integer|nil prepared unconsumed encounter identity
---@field pendingEncounter table<string, unknown>? prepared unconsumed encounter
---@field _trainerCatalog table<string, unknown>? composed immutable trainer template catalog (nil before composition)
---@field _trainerFactory table<string, unknown>? composed native trainer party materializer (nil before composition)
---@field _battleHost table<string, unknown>? narrow battle host for script battle tasks
---@field roamerState table<string, unknown>? the owned roamer and encounter persistence
---@field dexKnowledge table<string, unknown>? the owned dex knowledge
---@field playerDataContext table<string, unknown>? the generated charmap and frame-index context behind player validation
---@field _lastBattleResult table<string, unknown>? latest committed battle outcome words
---@field bagCursor BagCursor the runtime-only field bag cursor
---@field pokemonMenu table<string, unknown>? the owned menu composition (nil before composition / after teardown)
---@field menuLaneWarps table<string, unknown>? the long-lived menu-origin warp service (nil before composition / after teardown)
---@field followingMon FollowingMonController|nil the one derived follower controller (nil after teardown)
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
---@field pokemonNaming PokemonNamingState the script-owned Pokemon Naming Screen host
---@field menuHost FieldMenuHost?
---@field yesNoHost FieldYesNoHost? the live choice presentation host shared by the session, the script dialogue host, and field draw
---@field actionKeys table<string, boolean>?
---@field cancelKeys table<string, boolean>?
---@field menuKeys table<string, boolean>?
---@field presentation boolean
---@field windowStyles FieldWindowStyles the immutable per-runtime window style catalogue
---@field fontDef table<string, unknown> the generated field font and charmap
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
---@field derivedAssets table<string, function>?
---@field audio FieldAudioController? production-composed audio service (absent when only a recording script adapter is injected, without an audio-output host)
---@field mapMusicDayNight (fun(): string)? production-composed day/night band source for the map-music lookup (present whenever the production composition exists)
---@field audioSink LoveAudioSink? production-composed LÖVE output sink (absent without an audio-output host)
---@field screenFade FieldScriptScreenFade the production semantic script screen-fade controller (fade_screen/wait_fade); always composed, advanced once after each field tick
---@field localClock LocalClock the shared host-local civil-time boundary
---@field weatherClock table<string, unknown> injectable host boundary { today()->{month,day}, hasPenalty()->boolean }
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field fieldEntranceIndicatorAsset table<string, unknown>
---@field fieldEffectAssets table<string, unknown>
---@field pokemonCenterHeal PokemonCenterHealFlow? source-owned Pokémon Center choreography
---@field blackoutFlow FieldBlackoutFlow? runtime-owned whiteout presentation and recovery flow
---@field pokemonCenterHealDefinition table<string, unknown>? generated healing-ball asset definition
---@field physicalCoverage FieldCoverage?
---@field residency FieldResidencyCoordinator?
---@field assetPreparation AssetPreparationQueue? presentation-only preparation worker owner (nil when headless)
local FieldRuntime = {}
FieldRuntime.__index = FieldRuntime

---@class FieldRuntimePhysicalSwap
---@field coverage FieldCoverage
---@field replacement boolean
---@field previous FieldCoverage?
---@field state "prepared"|"committed"|"released"

local NEXT_BATTLE_LAUNCH_ID = 0
local CAMERA_PROFILES_PATH = FieldCameraCache.profilesPath()

-- Outdoor background identities selecting source-daylight scenes; every
-- other background plays under its interior band. Mirrors the source
-- background identity order behind the presentation scene inventory.
local OUTDOOR_BATTLE_BACKGROUNDS = {
  general = true,
  ocean = true,
  city = true,
  forest = true,
  mountain = true,
  snow = true,
}

-- Battle-private standing-tile water set behind MetatileBehavior_IsSurfableWater
-- (src/metatile_behavior.c). Battle scene selection keeps its own copy so
-- field movement keeps using MetatileBehavior.isSurfableWater unchanged.
local BATTLE_SURFABLE_WATER_BEHAVIORS = {
  [16] = true,
  [17] = true,
  [18] = true,
  [19] = true,
  [20] = true,
  [21] = true,
  [25] = true,
  [42] = true,
  [80] = true,
  [81] = true,
  [82] = true,
  [83] = true,
  [115] = true,
  [120] = true,
  [124] = true,
}

-- Battle terrain class for one standing metatile behavior, in the precedence
-- of FieldSystem_GetTerrainFromStandingTile (src/battle/battle_setup.c):
-- ice, tall/very tall grass, sand, snow, marsh mud, cave floor
-- (include/constants/metatile_behavior.h), then the surfable-water flag set.
-- Returns nil when no special class applies so the background default holds.
---@param behavior integer?
---@return string? battle terrain class, nil when the background default applies
local function battleTerrainForStandingBehavior(behavior)
  if behavior == nil then
    return nil
  end
  if behavior == 32 then
    return "ice"
  end
  if MetatileBehavior.isTallGrass(behavior) or MetatileBehavior.isVeryTallGrass(behavior) then
    return "grass"
  end
  if behavior == 33 then
    return "sand"
  end
  if behavior == 168 then
    return "snow"
  end
  if behavior == 164 then
    return "great_marsh"
  end
  if behavior == 8 then
    return "cave"
  end
  if BATTLE_SURFABLE_WATER_BEHAVIORS[behavior] == true then
    return "water"
  end
  return nil
end

-- Default battle terrain per background family when the standing behavior
-- names none explicitly.
local DEFAULT_BATTLE_TERRAINS = {
  general = "plain",
  ocean = "water",
  city = "building",
  forest = "grass",
  mountain = "mountain",
  snow = "snow",
  building_1 = "building",
  building_2 = "building",
  building_3 = "building",
  cave_1 = "cave",
  cave_2 = "cave",
  cave_3 = "cave",
  will = "will",
  koga = "koga",
  bruno = "bruno",
  karen = "karen",
  lance = "lance",
  distortion_world = "distortion_world",
}

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
-- discovery: live occupancy for the active actor map, and a read-only source
-- event probe for any other logical map, resident or preflight. The probe
-- never publishes an actor map or acquires an actor visual.
---@param mapId integer
---@param candidate FieldOccupancyCandidate
---@return FieldActorManager.Actor|FieldActorManager.ProbeResult|nil
function FieldRuntime:_actorAt(mapId, candidate)
  if self.actors.currentMapId == mapId then
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
  if self.actors.currentMapId == targetMapId then
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

-- Acquires the runtime map loader and its preparation worker. A prepared
-- New Game entry moves its already-staged loader and queue in before the
-- initial map acquisition, so the first load hits the resident bedroom
-- instead of rebuilding it. Without one, presentation mode owns one
-- asset-preparation worker for the runtime lifetime (a headless runtime
-- leaves it nil and starts no thread); it is built before the map loader
-- so scene loading can route mesh/image CPU work through it. Kept outside
-- the asset-loading phase to keep that closure under the upvalue limit.
---@param runtime FieldRuntime
---@param cacheFs table<string, unknown>
---@param world table<string, unknown>
---@param loadOptions FieldRuntimeOptions?
---@return FieldMapLoader mapLoader
---@return table<string, unknown>? assetPreparation
local function acquireMapLoader(runtime, cacheFs, world, loadOptions)
  local preparedTransfer = loadOptions ~= nil and loadOptions.preparedEntry or nil
  if preparedTransfer ~= nil then
    local opening = assert(runtime.game.location, "a prepared field entry requires a finalized new-game location")
    local claimed = preparedTransfer:claim({ versionId = runtime.versionId, mapSymbol = opening.mapSymbol })
    return assert(claimed.mapLoader, "a prepared field entry carries its loader"),
      assert(claimed.assetPreparation, "a prepared field entry carries its queue")
  end
  local queue
  if runtime.presentation then
    queue = AssetPreparationQueue.new(cacheFs)
  end
  local loader = FieldMapLoader.new(cacheFs, world, {
    sceneLoader = runtime.presentation and MapSceneLoader or nil,
    neighborLoader = runtime.presentation and NeighborRing or nil,
    assetPreparation = queue,
    derivedAssets = runtime.derivedAssets,
  })
  return loader, queue
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
  boot.cacheFs = CacheFs.forVersion(self.versionId)
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

  -- A prepared New Game entry moves its already-staged loader and queue
  -- in before the initial map acquisition, so the first load hits the
  -- resident bedroom instead of rebuilding it. Without one, presentation
  -- mode owns one asset-preparation worker for the runtime lifetime (a
  -- headless runtime leaves it nil and starts no thread); it is
  -- constructed before the map loader so scene loading can route
  -- mesh/image CPU work through it.
  self.mapLoader, self.assetPreparation = acquireMapLoader(self, boot.cacheFs, boot.world, loadOptions)
  local function mapMatrixMemberId(logicalMap)
    local mapIndex = assert(self.mapLoader.world.byId[logicalMap.mapId], "outdoor map catalog record is required")
    local mapRecord = assert(self.mapLoader.world.maps[mapIndex], "outdoor map catalog record is missing")
    return assert(mapRecord.matrix.memberId, "outdoor map matrix member is required")
  end

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
      mapMatrixMemberId(logicalMap) == coverage.matrixMemberId,
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
    local matrixMemberId = mapMatrixMemberId(logicalMap)
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
  self.runtimeMap, self.entryLocation = loadGameLocation(boot.activeGame, self.mapLoader, boot.composeInitialMap)
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
  self.transition = self.worldSwapCoordinator:createTransition(self, doorAt, escalatorAt, function(_, sourceMap, warp)
    local physical
    local ok, result = pcall(function()
      local function loadDestination(_, mapId)
        assert(mapId == warp.destinationMapId, "transition destination map mismatch")
        local logicalMap = self.mapLoader:load(mapId)
        local destinationPosition
        if warp.direct then
          destinationPosition = { fieldX = warp.x, fieldZ = warp.z }
        else
          local destinationWarp = logicalMap.fieldData.events.warps[warp.destinationWarpId + 1]
          assert(destinationWarp, "transition destination warp is missing")
          destinationPosition = { fieldX = destinationWarp.x, fieldZ = destinationWarp.z }
        end
        local composed, ownership = boot.composePreparedMap(logicalMap, destinationPosition)
        physical = ownership
        return composed
      end
      return require("libs.hgss.src.transition.WarpSystem").resolveDestination({
        load = loadDestination,
      }, sourceMap, warp)
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
  end)
  self.transition.player = self.player
  self.transition.suppression = nil

  -- The production script screen-fade controller (fade_screen/wait_fade):
  -- composed unconditionally so every supported field script has it,
  -- regardless of presentation mode or scriptHosts injection. Rendering
  -- only reads its status().
  self.screenFade = FieldScriptScreenFade.new()

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
  self.messageProvider = FieldMessageProvider.new(boot.cacheFs)
  -- Pin the Start Menu label bank for the field-runtime lifetime so menu
  -- composition stays deterministic and I/O-free after a successful boot.
  -- A missing bank fails the boot with the provider's typed error.
  local startMenuBank = require("libs.assets.src.MenuProtocol").START_MENU_MESSAGE_BANK
  local _, startMenuBankErr = self.messageProvider:acquireBank(startMenuBank)
  if startMenuBankErr ~= nil then
    error(startMenuBankErr, 0)
  end
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
  self.monService = HgssMonService.new({
    catalog = self.monCatalog,
    bucket = monBucket,
    profile = self.playerData.profile,
    game = self.versionId,
    language = self.monLanguage,
    charmap = boot.fontDef.charmap,
    mapSection = monMetMapSection,
    date = monMetDate,
  })
  self.mailbox = Mailbox.new(boot.loadedGame and boot.loadedGame.mailbox or nil)
  self.photoAlbum = PhotoAlbum.new(boot.loadedGame and boot.loadedGame.photoAlbum or nil)
  self:_composeBag(boot.activeGame, boot.loadedGame)
  self:_composeBattleState(
    boot.loadedGame,
    assert(boot.monRoot, "mon catalog root is required for battle state"),
    boot.world
  )
  -- Encounter and trainer data compose during boot from the same cache:
  -- a missing or invalid payload fails the boot instead of leaving
  -- the battle owners absent.
  self:composeEncounters(BattleDataCache.loadEncounters(boot.cacheFs))
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
  })
  self.starterBalls = composeStarterBalls(self)
  self.partySelection = buildPartySelectionHost(self, boot.cacheFs)
  self:_composePokemonMenu(boot.cacheFs)
  local PcApplicationHost = require("game.hgss.src.pc.PcApplicationHost")
  local function createStorage(request)
    return self.pokemonMenu.makeStorageChild(assert(request.mode, "Storage mode required"))
  end
  local function createMailbox()
    return self.pokemonMenu.makeMailboxChild()
  end
  local function createPhotoAlbum()
    return self.pokemonMenu.makePhotoAlbumChild()
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
    sourcePolicy = self.pokemonMenu.pcManifest.terminal,
    resolveTerminalProp = resolveTerminalProp,
  })
  self:_composePokemonCenterHeal(boot.audioService)
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
    fieldMoves = self.pokemonMenu.fieldMoves,
    pokemonNaming = self.pokemonNaming,
    followingMon = self.followingMon,
    followerInteractionCatalog = self.followerInteractionCatalog,
    followerReactionTicks = self.followerReactionTicks,
    clock = self.localClock,
    followerTransition = self.followingMonTransition,
    starterBalls = self.starterBalls,
    battle = self._battleHost,
    pcApplications = self.pcApplicationHost,
    pcTerminal = self.pcTerminal,
  })
  self.scripts = scriptComposition.scripts
  scriptComposition.restore()
end

-- Resolve the retail tag's placed model through its generated semantic role.
-- The returned adapter keeps each model's
-- compiled clip duration alongside its live instance handle.
---@param propRef string
---@return table<string, unknown>
function FieldRuntime:_resolvePcTerminalProp(propRef)
  assert(propRef == "pc_terminal", "PC terminal prop reference is closed")
  local pcManifest = assert(self.pokemonMenu, "PC terminal needs the menu composition").pcManifest
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
  local textPolicy = TextSpeedPolicy.forSpeed(self.playerData.options.textSpeed)
  local function createBuy(session)
    return MartScreenState.new({
      session = session,
      manifest = MartCache.loadManifest(boot.cacheFs),
      uiManifest = self.uiManifest,
      fontDef = boot.fontDef,
      textPolicy = textPolicy,
      effect = playSequence,
      measureDisplay = measureDisplay,
      frameIndex = self.playerData.options.textFrame,
      overrides = MartOverrides,
    })
  end
  local function createSell(session)
    return BagScreenState.new({
      effect = playSequence,
      textPolicy = textPolicy,
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

  local function sessionContextChoicePresentation()
    return self:contextChoicePresentation()
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
    fieldMoves = self.pokemonMenu.fieldMoves,
    overworld = self.overworld,
    pokemonNaming = self.pokemonNaming,
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
    enterMapActors = enterMapActors,
    autoAcknowledgePresentation = not self.presentation,
    terrainEffects = self.fieldTerrainEffectController,
    playerAvatar = self.playerAvatar,
  })

  if boot.loadedGame and boot.loadedGame.weatherId ~= nil then
    self:_setLiveWeather(self.runtimeMap, boot.loadedGame.weatherId)
  else
    self:_applyEffectiveWeather(self.runtimeMap)
  end
  self.session:beginMapEntry()
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
    derivedAssets = options.derivedAssets,
    saveStore = options.saveStore,
    savePublished = false,
    localClock = options.localClock or LocalClock.system(),
    weatherClock = options.weatherClock,
    presentationOverrides = options.presentationOverrides,
    martStockResolver = options.martStockResolver,
    fieldPixelScale = FieldPixelScale.new(options.fieldScaleConfig or FieldPresentation.fieldScale),
    overworld = FieldOverworldLifecycle.new(),
    propAnimations = FieldScriptPropAnimations.new(),
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

function FieldRuntime:update(dt)
  local maxSemanticDt = FieldSession.FIXED_DT * FieldSession.MAX_CATCH_UP_TICKS
  local acceptedDt = math.min(dt, maxSemanticDt)
  if self.playTime then
    self.playTime:advance(acceptedDt)
  end

  if self.residency then
    self.residency:updatePrefetch()
  end

  self:_refreshFieldTimeOfDay()

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
    self.session:updateFixed()
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
        self.followingMon:update()
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
    self.transition:updateSourceFrame()
    self.screenFade:updateSourceFrame()
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

  -- The owned battle lifetime pumps once per runtime update, after the
  -- field settles: simulation and presentation acknowledgements advance
  -- together while entry/return readiness still gates phase transitions.
  -- Step encounters were already considered once per fixed tick above. A
  -- presented launch advances only through its envelope's fixed driver,
  -- never through this host-update pump as well.
  if self.battleRuntime ~= nil or self._battleLaunch ~= nil then
    local launch = self._battleLaunch
    if launch == nil or launch.presented ~= true then
      self:updateBattle()
    end
  end
  -- Lifetimes may have settled or released during pumping, so reconcile
  -- the gate again before the next update observes it.
  self:_reconcileBattleGate()
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
  if completed and self.camera then
    -- The transition may finish on the same fixed tick that applies the
    -- destination stair/door arrival. Publish a settled camera pair with the
    -- completion event so the first post-transition presentation frame cannot
    -- interpolate from the pre-arrival Y history.
    self.camera:collapseRenderInterpolation()
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

-- Binds the per-launch presented-battle factory: the runtime calls it once
-- with a detached launch descriptor at admission and uses the fresh
-- five-operation port it returns for that launch only. A stored disposable
-- port can never span two launches, so production binds a factory instead.
-- Mirrors the party preparation binding: one owner, monotonically
-- increasing identities, and stale unbinds never detach a replacement.
---@param factory fun(descriptor: table<string, unknown>): table<string, unknown> per-launch presentation factory
---@return integer binding identity for the presented lifetime
function FieldRuntime:bindBattlePresentation(factory)
  assert(type(factory) == "function", "battle presentation binding requires its factory function")
  assert(self._battlePresentationFactory == nil, "one battle presentation binding owns the presented lifetime")
  self._battlePresentationBindingId = (self._battlePresentationBindingId or 0) + 1
  self._battlePresentationFactory = { id = self._battlePresentationBindingId, make = factory }
  self._battlePresentationWithdrawn = false
  return self._battlePresentationBindingId
end

-- Removes only the matching binding: a stale unbind never drops a
-- replacement presentation, and launches admitted after disposal fail at
-- admission instead of presenting without a screen.
---@param binding integer binding identity from bindBattlePresentation
function FieldRuntime:unbindBattlePresentation(binding)
  local current = self._battlePresentationFactory
  if current ~= nil and current.id == binding then
    self._battlePresentationFactory = nil
    self._battlePresentationWithdrawn = true
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
function FieldRuntime:_composePokemonMenu(cacheFs)
  self.menuComposer:composePokemonMenu(cacheFs)
end

---@return table<string, unknown>
function FieldRuntime:_menuPlayerPort()
  return self.menuComposer:menuPlayerPort()
end

---@return fun(): table<string, unknown>
function FieldRuntime:_menuFieldSources()
  return self.menuComposer:menuFieldSources()
end

---@param cacheFs CacheFs
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
  local result = avatar:applyTransitions()
  if result.spriteChanged then
    assert(self.playerVisual, "field runtime has no player visual"):setAvatar(result.spriteId)
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

function FieldRuntime:_captureManualSaveFromMenu()
  return assert(self.saveCoordinator, "field runtime has no save coordinator"):captureManual()
end

-- Composes the battle-era persistent owners: roamer and encounter state
-- plus dex knowledge, restored from the loaded battle-era buckets or
-- started fresh. Reference sets come from the same mon root and world
-- catalog the runtime boots from, so selected custom content resolves
-- exactly as validation sees it.
---@param loadedGame table<string, unknown>?
---@param monRoot table<string, unknown>
---@param world table<string, unknown>
function FieldRuntime:_composeBattleState(loadedGame, monRoot, world)
  local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  local speciesRefs = {}
  for key in pairs(assert(monRoot.species, "mon catalog root carries its species")) do
    speciesRefs[key] = true
  end
  local mapRefs = {}
  for mapId in pairs(assert(world.byId, "world catalog carries its map index")) do
    mapRefs[mapId] = true
  end
  if loadedGame ~= nil and loadedGame.encounters ~= nil then
    self.roamerState = HgssRoamerState.restore(loadedGame.encounters, { species = speciesRefs, maps = mapRefs })
  else
    self.roamerState = HgssRoamerState.new({ records = {}, species = speciesRefs, maps = mapRefs })
  end
  if loadedGame ~= nil and loadedGame.pokedex ~= nil then
    self.dexKnowledge = PokedexKnowledge.restore(loadedGame.pokedex, { species = speciesRefs })
  else
    self.dexKnowledge = PokedexKnowledge.new({ species = speciesRefs })
  end
  self.battleRuntime = nil
  self._battleLaunch = nil
  self._battleReceipt = nil
  self.battlePresentation = nil
  self.pendingEncounterId = nil
  self.pendingEncounter = nil
  self._lastBattleResult = nil
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
    if owner._battleLaunch ~= nil and owner._battleLaunch.launchId == launchId then
      owner._battleLaunch.scripted = true
    end
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

-- Attaches the presentation port owned battles present through. Without
-- an attached port, owned battles acknowledge immediately; an attached
-- later UI may instead remain waiting, which holds the lifecycle without
-- touching simulation.
---@param port table<string, unknown>
function FieldRuntime:attachBattlePresentation(port)
  assert(type(port) == "table", "battle presentation stays a record")
  assert(type(port.enter) == "function", "battle presentation implements enter")
  assert(type(port.present) == "function", "battle presentation implements present")
  assert(type(port.leave) == "function", "battle presentation implements leave")
  assert(type(port.dispose) == "function", "battle presentation implements dispose")
  self.battlePresentation = port
end

-- Builds the detached scenario for one launch request from the prepared
-- encounter (consuming a matching pending preparation exactly once), the
-- resolved trainer party, or an explicit staged scenario. Native trainer
-- identities resolve through the composed trainer catalog and materializer
-- before shaping; explicit caller-authored parties still ride through
-- untouched, and unknown trainer identities fail loudly.
---@param request table<string, unknown>
---@return table<string, unknown> detached scenario fragment
function FieldRuntime:_scenarioForRequest(request)
  local HgssBattleScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  assert(type(request) == "table" and type(request.kind) == "string", "scenario builds need their request")
  local live = { party = self.monService, bag = self.bagService, world = self.scripts.worldState }
  -- The current player reward identity rides the scenario context for
  -- traded and foreign award classification: the validated profile owns
  -- the trainer facts and the composed mon language owns the language key.
  if self.playerData ~= nil and self.playerData.profile ~= nil and self.monLanguage ~= nil then
    local profile = self.playerData.profile --[[@as table<string, unknown>]]
    if type(profile.trainerId) == "number" and type(profile.name) == "string" then
      live.player = { trainerId = profile.trainerId, trainerName = profile.name, language = self.monLanguage }
    end
  end
  if request.kind == "wild" then
    local payload = request.payload
    assert(type(payload) == "table", "wild launches carry their payload")
    if self.pendingEncounter ~= nil then
      local pending = self.pendingEncounter --[[@as table<string, unknown>]]
      if payload.attemptId == nil or payload.attemptId == pending.id then
        local encounter = self:_consumePendingEncounter()
        local mons = encounter.mons --[[@as table<integer, unknown>]]
        assert(type(mons) == "table" and type(mons[1]) == "table", "prepared encounters carry their mon")
        local first = mons[1] --[[@as table<string, unknown>]]
        assert(type(first.mon) == "table", "prepared encounters carry their mon record")
        return HgssBattleScenarioFactory.fromEncounter({
          attemptId = encounter.id,
          mon = first.mon,
          format = encounter.format,
          environment = encounter.environment,
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
    if type(payload.species) == "string" then
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
  return HgssBattleScenarioFactory.fromScript(request.payload --[[@as table<string, unknown>]], live)
end

-- Materializes one bare species/level foe into a full mon record through
-- the existing wild factory, drawing identity on the world stream exactly
-- like a scripted static encounter. Nil unless every composed catalog and
-- the world generator are present; production always carries them.
---@param payload table<string, unknown> wild launch payload naming its species and level
---@return table<string, unknown>? full foe record, nil when uncomposable
function FieldRuntime:_materializeDescriptorFoe(payload)
  local catalog = self.monCatalog
  local items = self.itemCatalog
  local cacheFs = self.cacheFs
  if catalog == nil or items == nil or cacheFs == nil or self.monLanguage == nil then
    return nil
  end
  if type(payload.level) ~= "number" then
    return nil
  end
  local scripts = self.scripts
  if scripts == nil or scripts.worldState == nil or scripts.worldState.rng == nil then
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
  local stream = {
    nextU16 = drawWorldU16,
  }
  local session = self.session
  local sessionMap = session ~= nil and session.currentMap or nil
  local profile = self.playerData ~= nil and self.playerData.profile or nil
  if sessionMap == nil or type(sessionMap.mapId) ~= "number" or type(profile) ~= "table" then
    return nil
  end
  local mapId = sessionMap.mapId --[[@as integer]]
  return factory:createStatic(payload.species --[[@as string]], payload.level --[[@as integer]], stream, {
    profile = profile,
    ball = "POKE_BALL",
    location = mapId,
    terrain = 0,
    date = { year = 2000, month = 1, day = 1 },
  })
end

-- Resolves one trainer launch payload into the detached trainer entries the
-- scenario shaper consumes. Entries already carrying their full party
-- records (explicit staged/scripted authoring) ride through untouched;
-- bare native identities resolve through the composed catalog and
-- materializer into detached bundles retaining the native identity, class,
-- ordered party, and controller metadata. Unknown identities fail before
-- any battle publishes; nothing here invents a party.
---@param payload table<string, unknown>
---@return table<string, unknown> scenario-ready trainer payload
function FieldRuntime:_trainerPayload(payload)
  assert(type(payload) == "table", "trainer launches carry their payload")
  local source = payload.trainers
  if source == nil then
    source = { { id = payload.trainer, party = payload.party } }
  end
  assert(type(source) == "table" and #source > 0, "trainer battles field at least one trainer")
  local factory = assert(self._trainerFactory, "trainer launches require their composed trainer materializer")
  local Errors = require("libs.errors.src.Errors")
  local world = self.scripts ~= nil and self.scripts.worldState or nil
  local stream = world ~= nil and world.rng or nil
  assert(type(stream) == "table", "trainer materialization threads the world stream untouched")
  -- The rival display name stays an indirection: an explicit staged-launch
  -- override wins, otherwise the script world supplies it when it models
  -- one. Bracket reads mark both as optional open-record fields rather
  -- than specified payload shape.
  local rivalName = nil
  local payloadRival = payload["rivalName"]
  if type(payloadRival) == "string" and payloadRival ~= "" then
    rivalName = payloadRival
  elseif type(world) == "table" then
    local worldRival = (world --[[@as table<string, unknown>]])["rivalName"]
    if type(worldRival) == "function" then
      local named = worldRival(world)
      if type(named) == "string" and named ~= "" then
        rivalName = named
      end
    end
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
        party = bundle.mons,
        partyLevels = bundle.partyLevels,
        prizeMoney = bundle.prizeMoney,
        aiPasses = bundle.aiPasses,
        items = bundle.items,
        doubleBattle = bundle.doubleBattle,
      }
    end
  end
  return {
    attemptId = payload.attemptId,
    id = payload.id,
    format = payload.format,
    trainers = resolved,
    inventories = payload.inventories,
    environment = payload.environment,
    formatState = payload.formatState,
  }
end

-- Starts the owned application battle lifetime for one launch request and
-- freezes player input until it returns. Only one battle runs at a time;
-- presentation readiness (attached or default) gates entry and return.
---@param args { request: table<string, unknown>, scenario: table<string, unknown>?, presentation: table<string, unknown>?, seed: integer? }
---@return table<string, unknown> the owned application battle lifetime
function FieldRuntime:startBattle(args)
  assert(type(args) == "table", "battle launches require an argument record")
  assert(self.battleRuntime == nil, "a battle is already active")
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local request = assert(args.request, "battle launches require their request")
  local scenario = args.scenario or self:_scenarioForRequest(request)
  -- Live consequence owners ride along so resolution stages through
  -- them: the bag and dex owners plus the player money facts. Prize
  -- inputs, captures, planned consumption, and roamer deltas arrive from
  -- explicit drivers; without them the runtime stages only what the
  -- executed battle determines.
  local playerFacts = nil
  if self.playerData ~= nil and self.playerDataContext ~= nil then
    playerFacts = { record = self.playerData, context = self.playerDataContext }
  end
  -- The presentation port resolves per launch: an explicit caller port
  -- wins, then the bound per-launch factory's fresh port for its admitted
  -- launch, then the stored port. A presented field without its bound
  -- factory never implicitly succeeds headless at this boundary.
  local presentation = args.presentation
  if presentation == nil then
    local launch = self._battleLaunch
    if launch ~= nil and launch.presented == true and launch.request.id == request.id and launch.port ~= nil then
      presentation = launch.port
    else
      presentation = self.battlePresentation
    end
  end
  local battle = BattleRuntime.new({
    request = request,
    scenario = scenario,
    presentation = presentation,
    party = self.monService,
    bag = self.bagService,
    dex = self.dexKnowledge,
    player = playerFacts,
    seed = args.seed,
  })
  self.battleRuntime = battle
  if self.session ~= nil then
    self.session:setBattleActive(true)
  end
  return battle
end

-- Reconciles the derived input gate from the current battle ownership:
-- a field-owned launch or battle handle plus any directly constructed
-- battle over the same live party. Both edges assign, so the gate never
-- latches true and an owned launch or return interval is never cleared
-- while it still owns the field.
function FieldRuntime:_reconcileBattleGate()
  if self.session == nil then
    return
  end
  local owned = self.battleRuntime ~= nil or self._battleLaunch ~= nil
  local direct = false
  if self.monService ~= nil then
    local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
    direct = BattleRuntime.isActiveFor(self.monService)
  end
  self.session:setBattleActive(owned or direct)
end

-- Drives the owned battle once per runtime update and returns through the
-- stable field when it settles. A committed battle records its outcome
-- words for script result reads; a failed battle faults the runtime
-- loudly instead of resuming the story as a success. Presented launches
-- advance only here: the host-update pump skips them, and the envelope's
-- fixed driver is their sole caller.
function FieldRuntime:updateBattle()
  local launch = self._battleLaunch
  if launch ~= nil and launch.presented == true then
    self:_updatePresentedBattle(launch)
    return
  end
  if launch ~= nil and launch.phase == "leaving" then
    local phase, failure = self.overworld:phase()
    if failure ~= nil or phase == "failed" then
      launch.phase = "failed"
      launch.error = failure
      error(failure or "overworld leave failed", 0)
    end
    if phase ~= "absent" then
      self:_reconcileBattleGate()
      return
    end
    local request = launch.request
    self:startBattle({ request = request, scenario = launch.scenario })
    launch.phase = "active"
  end

  if launch ~= nil and launch.phase == "restoring" then
    local phase, failure = self.overworld:phase()
    if failure ~= nil or phase == "failed" then
      launch.phase = "failed"
      launch.error = failure
      error(failure or "overworld restore failed", 0)
    end
    if phase ~= "present" then
      self:_reconcileBattleGate()
      return
    end
    launch.phase = "complete"
    launch.committed = true
    self._lastBattleResult = { result = launch.result, sourceResult = launch.sourceResult }
    self._battleReceipt = launch
    self._battleLaunch = nil
    self:_reconcileBattleGate()
    return
  end

  local battle = self.battleRuntime
  if battle == nil then
    self:_reconcileBattleGate()
    return
  end
  battle:update()
  local status = battle:status()
  if status.phase ~= "complete" and status.phase ~= "failed" then
    self:_reconcileBattleGate()
    return
  end
  battle:dispose()
  self.battleRuntime = nil
  self:_reconcileBattleGate()
  if status.phase == "failed" then
    local failure = status.error or "the battle reported a failure"
    if launch ~= nil then
      launch.phase = "failed"
      launch.error = failure
      self._battleReceipt = launch
      self._battleLaunch = nil
    end
    error(failure, 0)
  end
  if launch ~= nil and status.outcomeReceipt ~= nil and status.outcomeReceipt.committed == true then
    launch.result = status.result
    launch.sourceResult = status.sourceResult
    self:_adoptBattlePlayerMoney(launch, status.outcomeReceipt)
    if status.result == "loss" or status.result == "draw" then
      launch.phase = "complete"
      launch.committed = true
      self._lastBattleResult = { result = status.result, sourceResult = status.sourceResult }
      self._battleReceipt = launch
      self._battleLaunch = nil
    else
      launch.phase = "restoring"
      self.overworld:requestRestore()
    end
  elseif status.phase == "complete" and status.outcomeReceipt ~= nil and status.outcomeReceipt.committed == true then
    self._lastBattleResult = { result = status.result, sourceResult = status.sourceResult }
  end
  self:_reconcileBattleGate()
end

-- Advances one presented launch through its covered envelope: full field
-- cover before semantic leave, one construction under that cover, ordered
-- playback and exactly-once commit, terminal cover before disposal, and
-- the distinct continuing, scripted-defeat, and automatic-defeat returns.
-- Every wait is level-triggered and idempotent across fixed updates.
---@param launch table<string, unknown> presented launch record
function FieldRuntime:_updatePresentedBattle(launch)
  local phase = launch.phase
  if phase == "covering" then
    if launch.coverComplete == true then
      self.overworld:requestLeave()
      launch.phase = "leaving"
    end
    return
  end
  if phase == "leaving" then
    local overworldPhase, failure = self.overworld:phase()
    if failure ~= nil or overworldPhase == "failed" then
      launch.phase = "failed"
      launch.error = failure
      self.errorText = tostring(failure or "overworld leave failed")
      return
    end
    if overworldPhase ~= "absent" then
      return
    end
    local okConstruct, constructErr = pcall(function()
      self:startBattle({ request = launch.request })
    end)
    if not okConstruct then
      launch.phase = "failed"
      launch.error = constructErr
      self.errorText = tostring(constructErr or "presented battle construction failed")
      return
    end
    launch.phase = "active"
    return
  end
  if phase == "active" then
    local battle = self.battleRuntime
    if battle == nil then
      launch.phase = "failed"
      launch.error = "presented battle vanished before settlement"
      self.errorText = tostring(launch.error)
      return
    end
    battle:update()
    local status = battle:status()
    if status.phase ~= "complete" and status.phase ~= "failed" then
      return
    end
    if status.phase == "failed" then
      battle:dispose()
      self.battleRuntime = nil
      self:_resumeBattleAudio(launch, true)
      if self.session ~= nil then
        self.session:setBattleActive(false)
        self.session:setForegroundHold(false)
      end
      launch.phase = "failed"
      launch.error = status.error or "the battle reported a failure"
      self.errorText = tostring(launch.error)
      self._battleReceipt = launch
      self._battleLaunch = nil
      return
    end
    if status.outcomeReceipt == nil or status.outcomeReceipt.committed ~= true then
      launch.phase = "failed"
      launch.error = "presented battle completed without a committed receipt"
      self.errorText = tostring(launch.error)
      return
    end
    launch.result = status.result
    launch.sourceResult = status.sourceResult
    self:_adoptBattlePlayerMoney(launch, status.outcomeReceipt)
    launch.phase = "terminal"
    return
  end
  if phase == "terminal" then
    if launch.battleCovered ~= true then
      return
    end
    -- Terminal playback and acknowledgement finished under full battle
    -- cover: dispose the battle port once while the envelope retains its
    -- cover. The battle reference stays until the safe field returns so
    -- the transient save gate and settle loops observe the lifetime.
    local battle = self.battleRuntime
    if battle ~= nil then
      battle:dispose()
    end
    local result = launch.result
    if result == "loss" or result == "draw" then
      if launch.scripted == true then
        -- Scripted defeat publishes its receipt while absent for the
        -- authored continuation and transfers hold and cover there. The
        -- battle reference releases now (settle loops observe the owned
        -- lifetime until this handoff); the launch record persists until
        -- the continuation restores or recovers, keeping the transient
        -- save gate closed through the transfer.
        launch.phase = "transfer"
        launch.committed = true
        self._lastBattleResult = { result = result, sourceResult = launch.sourceResult }
        self._battleReceipt = launch
        self.battleRuntime = nil
      else
        self:_beginAutomaticRecovery(launch)
      end
    else
      self.overworld:requestRestore()
      launch.phase = "restoring"
    end
    return
  end
  if phase == "restoring" then
    local overworldPhase, failure = self.overworld:phase()
    if failure ~= nil or overworldPhase == "failed" then
      launch.phase = "failed"
      launch.error = failure
      self.errorText = tostring(failure or "overworld restore failed")
      return
    end
    if overworldPhase ~= "present" then
      return
    end
    -- The continuing return waits for actual destination scene and actor
    -- presentation, never for presence alone; only then does field music
    -- resume once ahead of the reveal.
    if not self:destinationWorldPresentable() then
      return
    end
    self:acknowledgeDestinationPresentation()
    self:_resumeBattleAudio(launch, true)
    launch.phase = "revealing"
    return
  end
  if phase == "revealing" then
    if launch.revealed ~= true then
      return
    end
    self:_publishPresentedReceipt(launch)
    return
  end
  if phase == "recovering" then
    self:_pumpAutomaticRecovery(launch)
    return
  end
  if phase == "transfer" then
    self:_finishScriptedTransfer(launch)
    return
  end
end

-- Starts the existing whiteout recovery exactly once for an automatically
-- launched defeat: relocation, healing, follower reset, message, and the
-- scheduled mom and Pokemon Center follow-up stay with that owner. The
-- launch has no launching script to perform the recovery.
---@param launch table<string, unknown> presented launch record
function FieldRuntime:_beginAutomaticRecovery(launch)
  if launch.recoveryStarted == true then
    return
  end
  launch.recoveryStarted = true
  local flow = self.blackoutFlow
  if flow == nil then
    launch.phase = "failed"
    launch.error = "automatic defeat recovery requires its blackout flow"
    self.errorText = tostring(launch.error)
    return
  end
  local travel = self.fieldTravel
  if travel == nil or travel.lastHealSpawn == nil then
    launch.phase = "failed"
    launch.error = "automatic defeat recovery requires its durable spawn"
    self.errorText = tostring(launch.error)
    return
  end
  local okStart, runId = pcall(function()
    return flow:start(travel.lastHealSpawn)
  end)
  if not okStart then
    launch.phase = "failed"
    launch.error = runId
    self.errorText = tostring(runId or "automatic defeat recovery failed to start")
    return
  end
  launch.recoveryRunId = runId
  launch.pendingRecoveryInput = nil
  launch.phase = "recovering"
end

-- Pumps the automatic recovery through the existing flow until its
-- follow-up is scheduled, then waits for the restored present field and
-- its actual scene readiness before exposing the safe field. The flow is
-- driven directly because no launching script owns its task: the waiting
-- recovery message answers only one queued genuine edge per tick, and
-- every other phase pumps dry. The consumed edge clears whether or not
-- the flow accepted it, so one held press never acknowledges twice. The
-- follow-up runs as a background script since no parent task run exists
-- to parent it to.
---@param launch table<string, unknown> presented launch record
function FieldRuntime:_pumpAutomaticRecovery(launch)
  local flow = self.blackoutFlow
  if flow == nil then
    launch.phase = "failed"
    launch.error = "automatic defeat recovery lost its blackout flow"
    self.errorText = tostring(launch.error)
    return
  end
  if launch.recoveryFollowup ~= true then
    local status = flow:status()
    if status.error ~= nil then
      launch.phase = "failed"
      launch.error = status.error
      self.errorText = tostring(status.error)
      return
    end
    if status.complete ~= true then
      local pending = launch.pendingRecoveryInput
      launch.pendingRecoveryInput = nil
      local admitted = type(pending) == "table" and pending.runId == launch.recoveryRunId
      flow:updateFixed({
        pressedAction = admitted == true and pending.pressedAction == true,
        pressedCancel = admitted == true and pending.pressedCancel == true,
        touchPressed = admitted == true and pending.touchPressed == true,
      })
      -- A tick that completes the flow falls through to the follow-up
      -- below instead of waiting another tick: the restored field and
      -- its committed receipt publish together, never a tick apart.
      status = flow:status()
      if status.error ~= nil then
        launch.phase = "failed"
        launch.error = status.error
        self.errorText = tostring(status.error)
        return
      end
      if status.complete ~= true then
        return
      end
    end
    local followup = flow:consumeResult(launch.recoveryRunId)
    if type(followup) ~= "string" then
      launch.phase = "failed"
      launch.error = "completed blackout supplies no follow-up"
      self.errorText = tostring(launch.error)
      return
    end
    local scheduler = self.scripts ~= nil and self.scripts.scheduler or nil
    if scheduler == nil then
      launch.phase = "failed"
      launch.error = "automatic defeat recovery requires its scheduler"
      self.errorText = tostring(launch.error)
      return
    end
    local composed = scheduler:resolveComposition(followup)
    if composed == nil then
      launch.phase = "failed"
      launch.error = "blackout follow-up script is unavailable: " .. tostring(followup)
      self.errorText = tostring(launch.error)
      return
    end
    local session = self.session
    local okChild, childErr = pcall(function()
      return scheduler:createBackground(composed, nil, session ~= nil and session.tick or 0)
    end)
    if not okChild then
      launch.phase = "failed"
      launch.error = childErr
      self.errorText = tostring(childErr or "blackout follow-up failed to schedule")
      return
    end
    launch.recoveryFollowup = true
  end
  local overworldPhase, failure = self.overworld:phase()
  if failure ~= nil or overworldPhase == "failed" then
    launch.phase = "failed"
    launch.error = failure
    self.errorText = tostring(failure or "recovery restore failed")
    return
  end
  if overworldPhase ~= "present" then
    return
  end
  if not self:destinationWorldPresentable() then
    return
  end
  self:acknowledgeDestinationPresentation()
  -- Defeat transfers music ownership to the recovery path: release the
  -- hold without replaying, respecting its authored music decision.
  self:_resumeBattleAudio(launch, false)
  launch.result = launch.result or "loss"
  launch.sourceResult = launch.sourceResult or 0
  self:_publishPresentedReceipt(launch)
end

-- Finishes a scripted-defeat transfer once its authored continuation takes
-- ownership: an observed blackout run that completes and is consumed, or
-- an authored ordinary restoration. Until then the field stays covered
-- and absent under the source script's authority.
---@param launch table<string, unknown> presented launch record
function FieldRuntime:_finishScriptedTransfer(launch)
  local overworldPhase, failure = self.overworld:phase()
  if failure ~= nil or overworldPhase == "failed" then
    launch.phase = "failed"
    launch.error = failure
    self.errorText = tostring(failure or "transfer restore failed")
    return
  end
  if overworldPhase == "present" then
    self:_resumeBattleAudio(launch, false)
    if self.session ~= nil then
      self.session:setBattleActive(false)
      self.session:setForegroundHold(false)
    end
    if self.input ~= nil then
      self.input:clearAll()
    end
    self.battleRuntime = nil
    self._battleLaunch = nil
    return
  end
  local flow = self.blackoutFlow
  if flow == nil then
    return
  end
  local status = flow:status()
  if status.phase ~= "idle" then
    launch.transferBlackoutSeen = true
    return
  end
  if launch.transferBlackoutSeen ~= true then
    return
  end
  self:_resumeBattleAudio(launch, false)
  if self.session ~= nil then
    self.session:setBattleActive(false)
    self.session:setForegroundHold(false)
  end
  if self.input ~= nil then
    self.input:clearAll()
  end
  self.battleRuntime = nil
  self._battleLaunch = nil
end

-- Battle host observation for script result reads: the latest committed
-- outcome words, or nil when no battle has committed yet.
---@return table<string, unknown>?
function FieldRuntime:lastBattleResult()
  return self._lastBattleResult
end

-- Battle host observation for script battle tasks: the owned battle's
-- committed outcome for one launch, or nil when no owned battle carries
-- that identity.
---@param launchId string
---@return table<string, unknown>?
function FieldRuntime:battleStatus(launchId)
  local receipt = self._battleReceipt
  if receipt ~= nil and receipt.launchId == launchId then
    return {
      phase = receipt.phase,
      committed = receipt.committed == true,
      result = receipt.result,
      sourceResult = receipt.sourceResult,
      error = receipt.error,
    }
  end
  local launch = self._battleLaunch
  if launch ~= nil and launch.launchId == launchId then
    return {
      phase = launch.phase,
      committed = launch.committed == true,
      result = launch.result,
      sourceResult = launch.sourceResult,
      error = launch.error,
    }
  end
  local battle = self.battleRuntime
  if battle == nil then
    return nil
  end
  return battle:battleStatus(launchId)
end

-- Battle host launch for script battle tasks: issues a unique launch
-- identity per call (two runs of one script site never share a commit
-- receipt) and starts the owned battle for the evaluated payload. A bound
-- presented factory takes the covered envelope route (cover first, leave
-- only under full cover); without one the launch keeps its headless
-- leave-first behavior.
---@param spec { launchId: string?, kind: string?, details: table<string, unknown>? }
---@return string the issued launch identity
function FieldRuntime:launchBattle(spec)
  assert(type(spec) == "table", "battle host launches require a spec record")
  assert(self._battleLaunch == nil and self.battleRuntime == nil, "a field-owned battle is already active")
  self._battleReceipt = nil
  NEXT_BATTLE_LAUNCH_ID = NEXT_BATTLE_LAUNCH_ID + 1
  local tag = spec.launchId or spec.kind or "battle"
  local launchId = tostring(tag) .. "#" .. tostring(NEXT_BATTLE_LAUNCH_ID)
  local payload = spec.details or {}
  assert(type(payload) == "table", "battle host launches carry their payload record")
  local request = { id = launchId, kind = spec.kind or "wild", payload = payload }
  if self._battlePresentationFactory ~= nil then
    return self:_launchPresentedBattle(launchId, request, nil)
  end
  assert(self._battlePresentationWithdrawn ~= true, "presented launches require their factory binding")
  self.overworld:requestLeave()
  self._battleLaunch = { launchId = launchId, phase = "leaving", request = request }
  return launchId
end

-- Admits one presented launch: captures the launch environment before the
-- field changes, builds the fresh per-launch port through the bound
-- factory, then claims input/foreground and the battle-music policy for
-- the launch lifetime. Semantic leave waits for full field cover under
-- the envelope's fixed driver. A factory failure fails the admission
-- loudly with no partial claim and never impersonates a battle.
---@param launchId string issued launch identity
---@param request table<string, unknown> launch request carrying its identity and kind
---@param method string? encounter method for step admissions, nil otherwise
---@return string the issued launch identity
function FieldRuntime:_launchPresentedBattle(launchId, request, method)
  assert(self._battleLaunch == nil and self.battleRuntime == nil, "a field-owned battle is already active")
  local binding = assert(self._battlePresentationFactory, "presented launches require their factory binding")
  local environment = self:_captureLaunchEnvironment(request, method)
  local launch = {
    launchId = launchId,
    phase = "covering",
    request = request,
    presented = true,
    scripted = false,
    environment = environment,
    coverComplete = false,
    battleCovered = false,
    revealed = false,
    result = nil,
    sourceResult = nil,
    committed = false,
    error = nil,
    recovery = nil,
    recoveryFollowup = false,
    transferBlackoutSeen = false,
  }
  local function presentedStatus()
    return self:_presentedLaunchStatus(launchId)
  end
  local function presentedAdvance()
    self:updateBattle()
  end
  local function presentedSubmit(reply)
    return self:_presentedSubmit(launchId, reply)
  end
  local function presentedNotify(event)
    self:_presentedNotify(launchId, event)
  end
  local function presentedRecoveryInput(edge)
    return self:_presentedRecoveryInput(launchId, edge)
  end
  local descriptor = {
    launchId = launchId,
    kind = request.kind,
    scripted = false,
    environment = environment,
    audio = self.audio,
    musicRole = self:_battleMusicRole(request),
    host = {
      status = presentedStatus,
      advance = presentedAdvance,
      submit = presentedSubmit,
      notify = presentedNotify,
      recoveryInput = presentedRecoveryInput,
    },
  }
  local ok, port = pcall(binding.make, descriptor)
  if not ok or type(port) ~= "table" then
    self.errorText = tostring(port or "presented battle factory returned no port")
    error("presented battle admission failed for launch " .. launchId .. ": " .. tostring(self.errorText), 0)
  end
  launch.port = port
  self._battleLaunch = launch
  -- Claim input and the foreground hold synchronously, before another
  -- catch-up tick can start a step: held and edge state clears so nothing
  -- sticks across the envelope boundary.
  if self.session ~= nil then
    self.session:setBattleActive(true)
    self.session:setForegroundHold(true)
  end
  if self.input ~= nil then
    self.input:clearAll()
  end
  local audio = self.audio
  if audio ~= nil and type(audio.suspendFieldPolicy) == "function" then
    audio:suspendFieldPolicy(launchId)
  end
  return launchId
end

-- Captures the actual launch environment before the field changes: source
-- map identity, committed tile and surface, standing behavior, avatar
-- movement mode, and time of day. Explicit source-request environment
-- overrides ride the record untouched for the scenario; the semantic
-- battle background resolves from the map's compiled battle background
-- with the surfing override to ocean, and terrain follows the standing
-- behavior ahead of the background default. Neither scene nor audio
-- selection consumes battle or encounter randomness.
---@param request table<string, unknown> launch request carrying its payload
---@param method string? encounter method for step admissions, nil otherwise
---@return table<string, unknown> detached launch environment
function FieldRuntime:_captureLaunchEnvironment(request, method)
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local session = self.session
  local map = nil
  if session ~= nil then
    map = session.currentMap
  end
  if map == nil then
    map = self.runtimeMap
  end
  local background = "general"
  if type(map) == "table" and type(map.fieldData) == "table" then
    local compiled = map.fieldData.battleBackground
    if type(compiled) == "string" and compiled ~= "" then
      background = compiled
    end
  end
  local player = self.player
  local fieldX, fieldZ, surfaceId = nil, nil, nil
  local behavior = nil
  if player ~= nil then
    fieldX, fieldZ, surfaceId = player.fieldX, player.fieldZ, player.surfaceId
    behavior = self:_arrivalBehavior(map, player)
  end
  local movementMode = "walking"
  local avatar = self.playerAvatar
  if avatar ~= nil and type(avatar.status) == "function" then
    local okStatus, status = pcall(function()
      return avatar:status()
    end)
    if okStatus and type(status) == "table" and type(status.durableState) == "string" then
      movementMode = status.durableState
    end
  end
  if movementMode == "surfing" then
    background = "ocean"
  end
  local hour = 12
  if self.localClock ~= nil then
    local okClock, now = pcall(function()
      return self.localClock:nowLocal()
    end)
    if okClock and type(now) == "table" and type(now.hour) == "number" then
      hour = now.hour
    end
  end
  local band = "day"
  local hourInt = math.floor(hour)
  if hourInt >= 0 and hourInt < 24 then
    local okBand, bandName = pcall(TimeOfDayProps.bandForHour, hourInt)
    if okBand and bandName == "eve" then
      band = "evening"
    elseif okBand and bandName == "nite" then
      band = "night"
    end
  end
  if OUTDOOR_BATTLE_BACKGROUNDS[background] ~= true then
    band = "day"
  end
  local terrain = DEFAULT_BATTLE_TERRAINS[background] or "plain"
  local standingTerrain = battleTerrainForStandingBehavior(behavior)
  if standingTerrain ~= nil then
    terrain = standingTerrain
  end
  local sceneKey = background .. "/" .. terrain .. "/" .. band
  if BattlePresentationCache.parseSceneKey(sceneKey) == nil then
    error("presented battle resolved an unknown scene context: " .. sceneKey, 0)
  end
  local explicit = nil
  local payload = request.payload
  if type(payload) == "table" and type(payload.environment) == "table" then
    explicit = payload.environment
  end
  return {
    mapId = (type(map) == "table" and map.mapId) or nil,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    behavior = behavior,
    movementMode = movementMode,
    method = method,
    background = background,
    terrain = terrain,
    time = band,
    sceneKey = sceneKey,
    sourceEnvironment = explicit,
  }
end

-- Chooses the source-defined battle music role for one launch: ordinary
-- wild, trainer, or rival roles from the staged presentation manifest.
-- Banks resolve through the normalized audio catalog at playback; a
-- missing manifest or role selects no music instead of guessing.
---@param request table<string, unknown> launch request carrying its kind and payload
---@return string? symbolic battle music role
function FieldRuntime:_battleMusicRole(request)
  if self.cacheFs == nil then
    return nil
  end
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local okManifest, manifest = pcall(BattlePresentationCache.load, self.cacheFs)
  if not okManifest or type(manifest) ~= "table" then
    return nil
  end
  local roles = manifest.audioRoles
  if type(roles) ~= "table" then
    return nil
  end
  if request.kind ~= "wild" then
    local payload = request.payload
    local rival = type(payload) == "table" and payload.rivalName
    if type(rival) == "string" and rival ~= "" and type(roles.rival) == "string" then
      return roles.rival
    end
    if type(roles.trainer) == "string" then
      return roles.trainer
    end
    return nil
  end
  if type(roles.wild) == "string" then
    return roles.wild
  end
  return nil
end

-- Presented-launch observation for the envelope's fixed driver: the launch
-- phase, the owned battle phase, overworld presence, and recovery
-- ownership. Nil once the launch clears, so stale envelopes drop it.
---@param launchId string
---@return table<string, unknown>? detached launch status snapshot
function FieldRuntime:_presentedLaunchStatus(launchId)
  local launch = self._battleLaunch
  if launch == nil or launch.launchId ~= launchId then
    return nil
  end
  local snapshot = {
    phase = launch.phase,
    result = launch.result,
    sourceResult = launch.sourceResult,
    committed = launch.committed == true,
    scripted = launch.scripted == true,
    battlePhase = nil,
    overworld = nil,
    blackoutPhase = nil,
  }
  local battle = self.battleRuntime
  if battle ~= nil then
    local okBattle, battleStatus = pcall(function()
      return battle:status()
    end)
    if okBattle and type(battleStatus) == "table" then
      snapshot.battlePhase = battleStatus.phase
    end
  end
  if self.overworld ~= nil then
    local okOverworld, phase = pcall(function()
      return self.overworld:phase()
    end)
    if okOverworld then
      snapshot.overworld = phase
    end
  end
  if self.blackoutFlow ~= nil then
    local okFlow, flowStatus = pcall(function()
      return self.blackoutFlow:status()
    end)
    if okFlow and type(flowStatus) == "table" then
      snapshot.blackoutPhase = flowStatus.phase
    end
  end
  return snapshot
end

-- Queues one genuine recovery edge for the waiting defeat message: only
-- the matching launch admits it, only while recovering, and only while
-- the recovery flow itself waits for input. Anything else is dropped and
-- never deferred, so a press under cover or ahead of the wait cannot
-- answer it later. At most one edge waits per recovery run; the pump
-- consumes it exactly once on the next tick.
---@param launchId string owning launch identity
---@param edge table<string, unknown> one-shot semantic recovery edge
---@return boolean admitted
function FieldRuntime:_presentedRecoveryInput(launchId, edge)
  local launch = self._battleLaunch
  if launch == nil or launch.launchId ~= launchId or launch.phase ~= "recovering" then
    return false
  end
  local flow = self.blackoutFlow
  if flow == nil then
    return false
  end
  local okStatus, status = pcall(function()
    return flow:status()
  end)
  if not okStatus or type(status) ~= "table" or status.waitingInput ~= true then
    return false
  end
  if type(edge) ~= "table" then
    return false
  end
  local pending = nil
  if edge.pressedAction == true then
    pending = { pressedAction = true }
  elseif edge.pressedCancel == true then
    pending = { pressedCancel = true }
  elseif edge.touchPressed == true then
    pending = { touchPressed = true }
  end
  if pending == nil then
    return false
  end
  pending.runId = launch.recoveryRunId
  launch.pendingRecoveryInput = pending
  return true
end

-- Presented decision submission behind the battle screen's accepted-choice
-- boundary: only the live launch battle answers, and only while it owns
-- an open request.
---@param launchId string
---@param reply table<string, unknown> sealed controller reply
---@return boolean stored
---@return table<string, unknown>? input error when the reply is rejected
function FieldRuntime:_presentedSubmit(launchId, reply)
  local launch = self._battleLaunch
  if launch == nil or launch.launchId ~= launchId then
    return false, { message = "no presented battle owns this launch" }
  end
  local battle = self.battleRuntime
  if battle == nil then
    return false, { message = "the presented battle is not constructed yet" }
  end
  return battle:submit(reply)
end

-- Presented cover handshake from the envelope: each event fires its phase
-- transition exactly once; stale or out-of-phase events are ignored.
---@param launchId string
---@param event string cover-complete, battle-covered, or revealed
function FieldRuntime:_presentedNotify(launchId, event)
  local launch = self._battleLaunch
  if launch == nil or launch.launchId ~= launchId then
    return
  end
  if event == "cover-complete" then
    if launch.phase == "covering" then
      launch.coverComplete = true
    end
  elseif event == "battle-covered" then
    if launch.phase == "terminal" then
      launch.battleCovered = true
    end
  elseif event == "revealed" then
    if launch.phase == "revealing" then
      launch.revealed = true
    end
  elseif event == "screen-failed" then
    -- A failed screen fails the launch loudly before commitment, without
    -- publishing any result. After commitment (terminal and later)
    -- mechanics are never rolled back or rerun to repair visuals.
    if launch.phase == "covering" or launch.phase == "leaving" or launch.phase == "active" then
      if self.battleRuntime ~= nil then
        local _, _ = pcall(function()
          return self.battleRuntime:dispose()
        end)
        self.battleRuntime = nil
      end
      self:_resumeBattleAudio(launch, true)
      if self.session ~= nil then
        self.session:setBattleActive(false)
        self.session:setForegroundHold(false)
      end
      launch.phase = "failed"
      launch.error = "the presented battle screen failed"
      self.errorText = tostring(launch.error)
      self._battleReceipt = launch
      self._battleLaunch = nil
    end
  end
end

-- Releases the battle-music claim for one launch: a matching continuing
-- return restores the current field policy once, while defeat transfers
-- ownership to the blackout and source recovery path untouched.
---@param launch table<string, unknown> presented launch record
---@param restoreMusic boolean true to restore the current field policy once
function FieldRuntime:_resumeBattleAudio(launch, restoreMusic)
  local audio = self.audio
  if audio == nil or type(audio.resumeFieldPolicy) ~= "function" then
    return
  end
  audio:resumeFieldPolicy(launch.launchId, restoreMusic == true)
end

-- Adopts the committed receipt's validated player candidate into the live
-- profile exactly once: prize money and blackout debits reach the live
-- wallet through this boundary, since the committer stages but never
-- publishes player money itself. Later saves capture the adopted money.
---@param launch table<string, unknown> launch record carrying its result
---@param receipt table<string, unknown> committed outcome receipt
function FieldRuntime:_adoptBattlePlayerMoney(launch, receipt)
  if launch.moneyAdopted == true then
    return
  end
  launch.moneyAdopted = true
  local candidate = receipt.player
  if type(candidate) ~= "table" or type(candidate.profile) ~= "table" then
    return
  end
  local live = self.playerData
  if type(live) ~= "table" or type(live.profile) ~= "table" then
    return
  end
  if candidate.profile.money ~= live.profile.money then
    self.playerData = candidate
  end
end

-- Publishes one committed continuing receipt only after the restored field
-- is revealed: usable field completion reaches scripts and saves solely
-- through this boundary.
---@param launch table<string, unknown> presented launch record
function FieldRuntime:_publishPresentedReceipt(launch)
  self._lastBattleResult = { result = launch.result, sourceResult = launch.sourceResult }
  self._battleReceipt = launch
  launch.phase = "complete"
  launch.committed = true
  self._battleLaunch = nil
  -- The retained battle reference releases here: the save gate stays
  -- closed through settlement, restoration, and reveal, and settle loops
  -- observe the owned lifetime until the safe field returns.
  self.battleRuntime = nil
  if self.session ~= nil then
    self.session:setBattleActive(false)
    self.session:setForegroundHold(false)
  end
  if self.input ~= nil then
    self.input:clearAll()
  end
end

-- Releases a prepared but unconsumed encounter without rerolling: the
-- service protection lifts and later steps may attempt anew. The prepared
-- mon is discarded, never battled and never committed.
---@return boolean released true when a pending encounter was held
function FieldRuntime:cancelPendingEncounter()
  if self.pendingEncounter == nil then
    return false
  end
  self:_consumePendingEncounter()
  return true
end

---@return table<string, unknown> the consumed prepared encounter
function FieldRuntime:_consumePendingEncounter()
  local pending = assert(self.pendingEncounter, "no prepared encounter to consume")
  local id = self.pendingEncounterId
  self.pendingEncounter = nil
  self.pendingEncounterId = nil
  if self._encounters ~= nil and id ~= nil then
    return self._encounters:consume(id)
  end
  return pending
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
  local factory = WildMonFactory.new({
    catalog = assert(self.monCatalog, "encounter composition requires the mon catalog"),
    items = assert(self.itemCatalog, "encounter composition requires the item catalog"),
    charmap = fontDef.charmap,
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
    game = self.versionId,
    language = self.monLanguage,
  })
  self._encounters = HgssEncounterService.new({
    catalog = catalog,
    wildFactory = factory,
    roamers = assert(self.roamerState, "encounter composition requires its roamer state"),
    game = self.versionId,
  })
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
  if self.battleRuntime ~= nil or self._battleLaunch ~= nil or self.pendingEncounterId ~= nil then
    return nil
  end
  local worldState = assert(self.scripts, "encounter attempts require their script platform").worldState
  local worldRng = assert(worldState.rng, "encounter attempts draw from the world generator")
  local function drawU16(_, _, _)
    return worldRng:nextRaw() % 65536
  end
  local stream = { nextU16 = drawU16 }
  local Errors = require("libs.errors.src.Errors")
  local ok, result = pcall(service.attempt, service, context, stream)
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
  local step = session:takeCommittedStep()
  if step == nil then
    return
  end
  if self.battleRuntime ~= nil or self._battleLaunch ~= nil or self.pendingEncounterId ~= nil then
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
  local map = session.currentMap --[[@as table<string, unknown>]]
  local method = self:_stepEncounterMethod(map, self.player)
  if method == nil then
    return
  end
  -- The service resolves encounter tables by table member, never by map
  -- identity: the compiled map carries its source table member for
  -- exactly this lookup.
  local fieldData = map.fieldData --[[@as table<string, unknown>]]
  local memberId = fieldData ~= nil and fieldData.wildEncounterMemberId or nil
  assert(
    type(memberId) == "number" and memberId % 1 == 0,
    "committed steps resolve their map's wild encounter table member"
  )
  local result = self:attemptEncounter({
    eventId = session.tick,
    mapId = memberId,
    method = method,
    movement = "step",
    modifiers = {},
    environment = {},
    timeOfDay = self:_encounterTimeOfDay(),
    playerProfile = self.playerData.profile,
  })
  if result == nil or result.kind ~= "prepared" or result.encounter == nil then
    return
  end
  if self._battlePresentationFactory == nil then
    return
  end
  self:_admitStepEncounter(result.encounter --[[@as table<string, unknown>]], method)
end

-- Admits one prepared step encounter to the presented launch path on its
-- own committed tick: the prepared identity rides the launch details so
-- the single scenario construction consumes it, never rerolls it. An
-- explicit cancellation still discards it under the existing policy.
---@param encounter table<string, unknown> prepared encounter carrying its mon
---@param method string encounter method for the arrival tile
function FieldRuntime:_admitStepEncounter(encounter, method)
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
  local details = {
    species = mon.species,
    level = level,
    attemptId = encounter.id,
    environment = encounter.environment,
  }
  NEXT_BATTLE_LAUNCH_ID = NEXT_BATTLE_LAUNCH_ID + 1
  local launchId = "wild#" .. tostring(NEXT_BATTLE_LAUNCH_ID)
  local request = { id = launchId, kind = "wild", payload = details }
  self._battleReceipt = nil
  self:_launchPresentedBattle(launchId, request, method)
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
function FieldRuntime:_arrivalBehavior(map, player)
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
  local behavior = self:_arrivalBehavior(map, player)
  if behavior == nil then
    return nil
  end
  if MetatileBehavior.isTallGrass(behavior) or MetatileBehavior.isVeryTallGrass(behavior) then
    return "grass"
  end
  if MetatileBehavior.isSurfableWater(behavior) and self:_isSurfing() then
    return "surf"
  end
  return nil
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
  assert(actionId == "pokemon.field_move", "unknown field action " .. tostring(actionId))
  local BuiltinScripts = require("libs.hgss.src.script.BuiltinScripts")
  local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
  local composition = assert(self.pokemonMenu, "field admission requires the menu composition")
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
  local queued = fieldMoves:queue({
    move = flowRequest.move,
    slot = flowRequest.slot,
    moveSlot = flowRequest.moveSlot,
    partyRevision = flowRequest.partyRevision,
    context = context,
    travel = travel,
  })
  if type(queued) ~= "table" or queued.kind ~= "accepted" then
    error("pokemon.field_move admission refused: " .. tostring(queued and queued.kind), 0)
  end
  local session = assert(self.session, "field admission requires the field session")
  local client = assert(self.scripts and self.scripts.client, "field admission requires the script client")
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

-- Select the physical owner for a discontinuous outdoor destination. A
-- matching matrix is reusable only when its resident window is centered on
-- the destination cell; otherwise the new owner remains transition-owned
-- until the prepared swap commits.
---@param logicalMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@param matrixMemberId integer
---@return FieldRuntimePhysicalSwap
function FieldRuntime:_stagePhysicalCoverage(logicalMap, position, matrixMemberId)
  return assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator"):stagePhysicalCoverage(
    logicalMap,
    position,
    matrixMemberId
  )
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

function FieldRuntime:_updateCameraProjection()
  self.fieldPixelScale:resize(self.viewport.referenceFrame.height)
  self.camera:setProjectionAspect(self.viewport:worldAspect())
  self.camera:setZoom(self.fieldPixelScale:cameraZoom())
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
  self:_updateCameraProjection()
  self._displayTopology = screenTopology
  self.presentationDisplay = self.displayContext:measure(width, height)
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
  if self.propAnimations then
    self.propAnimations:clear()
  end
  if self.overworld then
    self.overworld:dispose()
  end
  if self.blackoutFlow then
    self.blackoutFlow:dispose()
  end
  if self.battleRuntime then
    self.battleRuntime:dispose()
  end
  self.battleRuntime = nil
  self._battleLaunch = nil
  self._battleReceipt = nil
  self._lastBattleResult = nil
  self._battlePresentationFactory = nil
  self._battlePresentationBindingId = nil
  if self.transition then
    self:_disposePreparedSwap(self.transition.resolution, self.transition.prepared)
  end
  self.menuComposer:releaseModalHosts()
  if self.martHost then
    self.martHost:dispose()
  end
  if self.pcApplicationHost then
    self.pcApplicationHost:dispose()
  end
  if self.pcTerminal then
    self.pcTerminal:releaseEffect()
  end
  self.pcApplicationHost, self.pcTerminal = nil, nil
  self.martHost = nil
  self.applications = nil
  self.displayContext, self.presentationDisplay, self.presentationOverrides = nil, nil, nil
  self._displayTopology = nil
  if self.messageProvider then
    self.messageProvider:dispose()
  end
  self.messageProvider = nil
  if self.residency then
    self.residency:dispose()
  end
  self.residency = nil
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
  if self.mapLoader then
    self.mapLoader:release()
  end
  -- The preparation worker is released after every presentation scene
  -- consumer and pending task above, so no outstanding prepared token can
  -- outlive its queue.
  if self.assetPreparation then
    self.assetPreparation:release()
  end
  self.assetPreparation = nil
  if self.audioSink then
    self.audioSink:release()
  end
  self.actors, self.actorAssets, self.mapLoader = nil, nil, nil
  self.audio, self.audioSink, self.mapMusicDayNight = nil, nil, nil
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
  self.bagService, self.bagCursor = nil, nil
  self.martService = nil
  self.mailbox, self.photoAlbum = nil, nil
  self.martStockResolver = nil
  self.itemCatalog = nil
  self.followerInteractionCatalog = nil
  self.starterProvider, self.starterChoice, self.pokemonNaming = nil, nil, nil
  self.partySelection = nil
  self.pokemonMenu, self.menuLaneWarps = nil, nil
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
  if self.pokemonMenu then
    self.pokemonMenu.dispose()
  end
  if self.starterChoice then
    self.starterChoice:dispose()
  end
  if self.pokemonNaming then
    self.pokemonNaming:dispose()
  end
  self:_releaseAll()
end

return FieldRuntime
