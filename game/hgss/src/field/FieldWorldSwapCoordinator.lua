-- Owns staged field-world replacement and its transition callback surface.

local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldPlayerVisual = require("libs.hgss.src.actors.FieldPlayerVisual")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")

---@class FieldWorldSwapCoordinator
---@field runtime FieldRuntime
---@field pokegearLastExterior { x: integer, y: integer }? the last committed source-confirmed exterior cell
local FieldWorldSwapCoordinator = {}
FieldWorldSwapCoordinator.__index = FieldWorldSwapCoordinator

---@param runtime FieldRuntime
---@return FieldWorldSwapCoordinator
function FieldWorldSwapCoordinator.new(runtime)
  return setmetatable({ runtime = runtime }, FieldWorldSwapCoordinator)
end

---@param self FieldWorldSwapCoordinator
---@param logicalMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@param matrixMemberId integer
---@return FieldRuntimePhysicalSwap
function FieldWorldSwapCoordinator:stagePhysicalCoverage(logicalMap, position, matrixMemberId)
  local runtime = self.runtime
  local destinationAnchorX = math.floor(position.fieldX / FieldGrid.CELL_TILES)
  local destinationAnchorZ = math.floor(position.fieldZ / FieldGrid.CELL_TILES)
  local current = runtime.physicalCoverage
  if
    current
    and current.matrixMemberId == matrixMemberId
    and current.anchorX == destinationAnchorX
    and current.anchorZ == destinationAnchorZ
  then
    return { coverage = current, replacement = false, previous = nil, state = "prepared" }
  end

  local replacement = runtime.mapLoader:createPhysicalCoverage(logicalMap, position)
  return { coverage = replacement, replacement = true, previous = current, state = "prepared" }
end

-- Begin the destination window as the same staged task the entry path uses, so a
-- covered transition can advance its cell loads, collision decodes and GPU
-- realizations while the cover is up instead of building all of it in one frame.
-- The source world is untouched: the stage only holds its own task.
---@param self FieldWorldSwapCoordinator
---@param logicalMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@param matrixMemberId integer
---@return FieldRuntimePhysicalSwap
function FieldWorldSwapCoordinator:beginPhysicalCoverage(logicalMap, position, matrixMemberId)
  local runtime = self.runtime
  local current = runtime.physicalCoverage
  return {
    task = runtime.mapLoader:beginPhysicalCoverage(logicalMap, position),
    matrixMemberId = matrixMemberId,
    anchorX = math.floor(position.fieldX / FieldGrid.CELL_TILES),
    anchorZ = math.floor(position.fieldZ / FieldGrid.CELL_TILES),
    coverage = nil,
    replacement = true,
    previous = current,
    state = "staging",
  }
end

-- Take the finished staged window into the swap record, which then reads exactly
-- like a synchronously prepared one.
---@param self FieldWorldSwapCoordinator
---@param swap FieldRuntimePhysicalSwap
---@return FieldRuntimePhysicalSwap
function FieldWorldSwapCoordinator:finishPhysicalCoverage(swap)
  assert(swap.state == "staging", "physical swap is not staging")
  local task = assert(swap.task, "staged physical swap carries no task")
  swap.coverage = task:takeResult()
  swap.task = nil
  swap.state = "prepared"
  return swap
end

-- Drop a staged destination that will never be committed.
---@param self FieldWorldSwapCoordinator
---@param swap FieldRuntimePhysicalSwap
function FieldWorldSwapCoordinator:releasePhysicalCoverage(swap)
  local task = swap.task
  swap.task = nil
  if task ~= nil then
    task:release()
  end
  swap.state = "released"
end

---@param self FieldWorldSwapCoordinator
---@param resolution table<string, unknown>
---@param facing FieldDirection
---@return table<string, unknown>
function FieldWorldSwapCoordinator:prepare(resolution, facing)
  local runtime = self.runtime
  local lifecyclePhase = runtime.overworld:phase()
  local externallyCovered = runtime.transition.coveredSwap and lifecyclePhase == "absent"
  assert(
    runtime.transition.fadeAlpha == 1 or runtime.screenFade:isOpaque() or externallyCovered,
    "field map swap must be hidden by fade"
  )
  local runtimeMap = resolution.destinationMap
  runtime:_applyEffectiveWeather(runtimeMap)
  local fieldX, fieldZ = resolution.fieldX, resolution.fieldZ
  local surfaceId, worldY = resolution.surfaceId, resolution.worldY
  if runtime.transition.sourceKind == "door" then
    -- Retail warp placement lands on the destination warp tile itself
    -- (FieldSystem_EnterLocation copies the warp coordinates); the
    -- destination door choreography steps south out of it from there.
    assert(resolution.destinationWarp, "door destination warp required")
    fieldX = resolution.destinationWarp.x
    fieldZ = resolution.destinationWarp.z
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
    local sample = SurfaceResolver.new(runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = worldY,
    })
    surfaceId, worldY = sample.surfaceId, sample.worldY
  elseif runtimeMap.terrain then
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
    local surface = SurfaceResolver.new(runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    })
    surfaceId, worldY = surface.surfaceId, surface.worldY
  end
  local function occupancy(candidate)
    return runtime:_playerOccupantAt(candidate)
  end
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    initialWorldY = worldY,
    facing = facing,
    occupancy = occupancy,
  })
  local profile = assert(
    runtime.cameraProfiles[runtimeMap.cameraType],
    "field camera cache has no camera type " .. runtimeMap.cameraType
  )
  local camera = FieldCamera.new(profile, { initialTarget = player:renderPosition() })
  runtime:configureCameraProjection(camera)
  local playerVisual = FieldPlayerVisual.new({
    player = player,
    spriteId = assert(runtime.playerAvatar, "field runtime has no avatar transition owner"):currentSpriteId(),
    playerAvatar = runtime.playerAvatar,
  })
  local physical = (resolution.physical and resolution.physical.coverage) and resolution.physical or nil
  local destinationCoverage = physical and physical.coverage or nil
  local residency = assert(runtime.residency):prepareTransition(runtimeMap, destinationCoverage)
  return { player = player, camera = camera, playerVisual = playerVisual, physical = physical, residency = residency }
end

---@param self FieldWorldSwapCoordinator
---@param resolution table<string, unknown>?
---@param prepared table<string, unknown>?
function FieldWorldSwapCoordinator:abort(resolution, prepared)
  local runtime = self.runtime
  local residency = prepared and prepared.residency
  if residency then
    assert(runtime.residency):discardTransition(residency)
  end
  local physical = (prepared and prepared.physical) or (resolution and resolution.physical)
  if not physical or not physical.replacement then
    return
  end
  if physical.state == "released" or physical.state == "committed" then
    return
  end
  assert(physical.state == "prepared", "physical swap is not disposable")
  assert(physical.coverage ~= runtime.physicalCoverage, "staged physical coverage is already committed")
  physical.coverage:release()
  physical.state = "released"
end

-- Special-spawn publication owns the durable relocation point the source
-- field control writes when the player leaves the main outdoor matrix
-- (FieldSystem_SetMapConnection): a successful swap from an outdoor map to
-- a building or cave records the outdoor warp tile and the facing used to
-- enter it (a northward entrance records the tile south of the warp).
-- Dig and Escape Rope arrive there; Teleport, Fly and blackout overwrite it
-- elsewhere, and nothing here ever clears it. Failed builds never reach
-- this owner, so the old record survives them unchanged.
---@param self FieldWorldSwapCoordinator
---@param runtime table<string, unknown> the live runtime surface (travel, map, player)
---@param resolution table<string, unknown>
function FieldWorldSwapCoordinator:publishSpecialSpawn(runtime, resolution)
  local travel = runtime.fieldTravel
  if travel == nil or type(travel.setSpecialSpawn) ~= "function" then
    return
  end
  local sourceMap = runtime.runtimeMap
  local destinationMap = resolution.destinationMap
  if type(sourceMap) ~= "table" or type(destinationMap) ~= "table" then
    return
  end
  local sourceFieldData = sourceMap.fieldData
  local destinationFieldData = destinationMap.fieldData
  if type(sourceFieldData) ~= "table" or type(destinationFieldData) ~= "table" then
    return
  end
  if
    sourceFieldData.transitionEnvironment ~= "outdoors" or destinationFieldData.transitionEnvironment == "outdoors"
  then
    return
  end
  local player = runtime.player
  assert(type(player) == "table", "special spawn recording needs the source player")
  assert(type(sourceMap.mapSymbol) == "string", "special spawn recording needs the source map symbol")
  local facing = assert(player.facing, "special spawn recording needs the source facing")
  local fieldZ = assert(player.fieldZ, "special spawn recording needs the source tile")
  if facing == "north" then
    fieldZ = fieldZ + 1
  end
  travel:setSpecialSpawn({
    map = sourceMap.mapSymbol,
    fieldX = assert(player.fieldX, "special spawn recording needs the source tile"),
    fieldZ = fieldZ,
    warpId = -1,
    direction = facing,
  })
end

-- Blackout-spawn publication owns the durable heal point the source
-- field control refreshes on every non-connection map entry
-- (FieldSystem_InitMapOnEnter via MapHeader_GetSpawnIdForDeathWarp):
-- entering a compiled death destination (a Pokemon Center interior, the
-- mother house, and the other listed death maps) records its spawn key
-- on the travel owner. Any other destination leaves the record
-- untouched, and a missing cache or travel owner never fails the swap.
---@param self FieldWorldSwapCoordinator
---@param runtime table<string, unknown> the live runtime surface (travel, cacheFs)
---@param resolution table<string, unknown>
function FieldWorldSwapCoordinator:publishBlackoutSpawn(runtime, resolution)
  local travel = runtime.fieldTravel
  if travel == nil or type(travel.setLastHealSpawn) ~= "function" then
    return
  end
  local destinationMap = resolution.destinationMap
  if type(destinationMap) ~= "table" or type(destinationMap.mapSymbol) ~= "string" then
    return
  end
  local cacheFs = runtime.cacheFs
  if cacheFs == nil or type(cacheFs.loadLua) ~= "function" then
    return
  end
  local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
  local spawnKey = FieldMapDataCache.spawnKeyForDeathMap(cacheFs, destinationMap.mapSymbol)
  if spawnKey ~= nil then
    travel:setLastHealSpawn(spawnKey)
  end
end

-- Dynamic-warp entrance publication owns the saved dynamic destination the
-- source refreshes on an arrival whose own anchor warp event is 0x100
-- (FieldSystem_EnterLocation): the arriving map's anchor tile records the
-- entrance position, so the next warp through that anchor leaves for the map
-- the player entered from. The record is the source's map-local tile and the
-- trigger-time entrance facing (FieldSystem_MapConnection stores
-- PlayerAvatar_GetFacingDirection when the warp triggers), which the
-- transition carries on its resolution; the live player has already been
-- turned by the departure choreography and is never re-read here. Every other
-- arrival leaves the record untouched, while a qualifying arrival requires the
-- travel owner and the source entrance state the retail operation always has.
---@param self FieldWorldSwapCoordinator
---@param runtime table<string, unknown>
---@param resolution table<string, unknown>
function FieldWorldSwapCoordinator:publishDynamicWarpEntrance(runtime, resolution)
  local destinationWarp = resolution.destinationWarp
  if type(destinationWarp) ~= "table" or destinationWarp.destinationWarpId ~= WarpSystem.DYNAMIC_WARP_SENTINEL then
    return
  end
  local travel = assert(runtime.fieldTravel, "dynamic warp entrance recording needs the travel owner")
  assert(
    type(travel.setDynamicWarp) == "function",
    "dynamic warp entrance recording needs FieldTravelState.setDynamicWarp"
  )
  local sourceMap = assert(resolution.sourceMap, "dynamic warp entrance recording needs the source map")
  assert(type(sourceMap.mapSymbol) == "string", "dynamic warp entrance recording needs the source map symbol")
  local sourceWarp = assert(resolution.sourceWarp, "dynamic warp entrance recording needs the source warp record")
  assert(type(sourceWarp.index) == "number", "dynamic warp entrance recording needs the source warp index")
  assert(type(sourceWarp.x) == "number", "dynamic warp entrance recording needs the source warp tile")
  assert(type(sourceWarp.z) == "number", "dynamic warp entrance recording needs the source warp tile")
  local direction =
    assert(resolution.sourceFacing, "dynamic warp entrance recording needs the trigger-time source facing")
  local localX, localZ = FieldCoordinates.fieldToLocal(sourceMap, sourceWarp.x, sourceWarp.z)
  travel:setDynamicWarp({
    map = sourceMap.mapSymbol,
    fieldX = localX,
    fieldZ = localZ,
    warpId = sourceWarp.index,
    direction = direction,
  })
end

---@param self FieldWorldSwapCoordinator
---@param resolution table<string, unknown>
---@param _ FieldDirection
---@param prepared table<string, unknown>
function FieldWorldSwapCoordinator:commit(resolution, _, prepared)
  local runtime = self.runtime
  local sourceMap, sourcePlayer = runtime.runtimeMap, runtime.player
  self:publishSpecialSpawn(runtime, resolution)
  self:publishBlackoutSpawn(runtime, resolution)
  self:publishDynamicWarpEntrance(runtime, resolution)
  local runtimeMap = resolution.destinationMap
  local physical = (prepared and prepared.physical) or resolution.physical
  local residency = assert(prepared and prepared.residency, "prepared residency transaction required")
  -- The follower clears before the old map leaves residency; the manager
  -- retires the old entry afterwards and the controller reinstalls once the
  -- new actor map publishes.
  if runtime.followingMon then
    runtime.followingMon:handleMapExit()
  end
  if runtime.followingMonTransition then
    runtime.followingMonTransition:clear()
  end
  assert(runtime.residency):commitTransition(residency, {
    fieldX = prepared.player.fieldX,
    fieldZ = prepared.player.fieldZ,
    facing = prepared.player.facing,
  })
  local previousCoverage
  if physical then
    assert(physical.state == "prepared", "physical swap is not committable")
    assert(physical.coverage, "physical swap coverage is required")
    if physical.replacement then
      assert(physical.previous == runtime.physicalCoverage, "physical swap source owner changed")
      previousCoverage = runtime.physicalCoverage
      runtime.physicalCoverage = physical.coverage
    else
      assert(physical.coverage == runtime.physicalCoverage, "reused physical coverage is not current")
    end
    assert(runtimeMap.coverage == runtime.physicalCoverage, "destination map coverage is not the committed owner")
    physical.state = "committed"
  end
  runtime.fieldTerrainEffectController:clear()
  runtime.runtimeMap = runtimeMap
  runtime.player = prepared.player
  runtime.transition.player = prepared.player
  runtime.playerVisual = prepared.playerVisual
  runtime.session.playerVisual = prepared.playerVisual
  runtime.camera = prepared.camera
  runtime.session.currentMap = runtimeMap
  runtime.zoneController.currentMap = runtimeMap
  runtime.session.player = prepared.player
  runtime.session.camera = prepared.camera
  if runtime.audio then
    runtime.audio:enterMap(runtimeMap, { clearMusicOverride = true, play = true })
  end
  -- FieldSystem_ResetStateOnWarp: a rider warping into a map that forbids
  -- bikes arrives on foot.
  local avatar = assert(runtime.playerAvatar, "field runtime has no avatar transition owner")
  if avatar:durableState() == "cycling" and not runtimeMap.fieldData.fieldUse.bikeAllowed then
    avatar:queueTransition("walking")
    runtime:applyAvatarTransitions()
  end
  runtime.scripts:onMapSwap(prepared.player, runtimeMap)
  runtime.session:beginMapEntry()
  runtime:resetEncounterStepCounters()
  -- The durable destination is published: one ordinary arrival may announce
  -- the new area, regardless of the source section. Ineligible destinations
  -- are the controller's own compiled-eligibility decision.
  if runtime.mapNameBanner then
    runtime.mapNameBanner:request(runtimeMap.mapId, runtimeMap.mapSectionNativeId)
  end
  if runtimeMap.fieldData.transitionEnvironment ~= "outdoors" then
    local exterior = self:_sourceExteriorCell(sourceMap, sourcePlayer)
    if exterior ~= nil then
      self.pokegearLastExterior = exterior
    end
  end
  if previousCoverage then
    previousCoverage:release()
  end
end

---@param sourceMap RuntimeFieldMap?
---@param player table<string, unknown>?
---@return { x: integer, y: integer }? the source-confirmed exterior cell
function FieldWorldSwapCoordinator:_sourceExteriorCell(sourceMap, player)
  if
    type(sourceMap) ~= "table"
    or sourceMap.fieldData.transitionEnvironment ~= "outdoors"
    or type(sourceMap.mapSymbol) ~= "string"
    or type(player) ~= "table"
  then
    return nil
  end
  local catalog = self.runtime.pokegearCatalog
  local locations = type(catalog) == "table" and catalog.locations or nil
  if type(locations) ~= "table" then
    return nil
  end
  local sourceLocation
  for _, entry in ipairs(locations) do
    if type(entry) == "table" and entry.fieldMap == sourceMap.mapSymbol then
      sourceLocation = entry
      break
    end
  end
  if
    type(sourceLocation) ~= "table"
    or type(sourceLocation.matrix) ~= "table"
    or type(sourceLocation.matrix.x) ~= "number"
    or type(sourceLocation.matrix.y) ~= "number"
    or sourceLocation.explicitX ~= nil
    or sourceLocation.explicitY ~= nil
    or type(player.fieldX) ~= "number"
    or type(player.fieldZ) ~= "number"
  then
    return nil
  end
  return { x = math.floor(player.fieldX / 32), y = math.floor(player.fieldZ / 32) }
end

---@param runtime FieldRuntime
---@param doorAt fun(runtimeMap: table<string, unknown>, fieldX: integer, fieldZ: integer): table<string, unknown>?
---@param escalatorAt fun(runtimeMap: table<string, unknown>, fieldX: integer, fieldZ: integer): table<string, unknown>?
---@param resolveDestination function
---@return FieldTransition
function FieldWorldSwapCoordinator:createTransition(runtime, doorAt, escalatorAt, resolveDestination)
  -- The saved dynamic destination: read late through the travel owner so a
  -- script's SetDynamicWarp between two transitions is always visible.
  local function savedDynamicWarp()
    local travel = runtime.fieldTravel
    if travel == nil or type(travel.dynamicWarp) ~= "function" then
      return nil
    end
    return travel:dynamicWarp()
  end
  local transition ---@type FieldTransition
  local function onStart(sourceMap, trigger)
    -- Start destination compilation under the emerging cover. Readiness stays
    -- gated at load_destination, so this early demand never blocks or commits.
    -- The transition resolved the saved destination once at start; the same
    -- record names a dynamic anchor's destination map.
    local dynamicWarp = transition.dynamicWarp
    runtime.mapLoader:requestWarp(sourceMap, trigger.warp, dynamicWarp)
    if runtime.audio then
      local destination = trigger.warp.destinationMapId
      if trigger.warp.destinationWarpId == WarpSystem.DYNAMIC_WARP_SENTINEL and dynamicWarp ~= nil then
        -- The sentinel header names no map: the saved record does.
        destination = dynamicWarp.map
      end
      runtime.audio:beginWarp(destination)
    end
  end
  local function playSound(soundRef)
    local audio = runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.audio)
    assert(audio and type(audio.play) == "function", "field transition audio host required")
    audio:play(soundRef)
  end
  local function stopSound(soundRef)
    local audio = runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.audio)
    assert(audio and type(audio.stop) == "function", "field transition audio host required")
    audio:stop(soundRef)
  end
  local function prepare(resolution, facing)
    return self:prepare(resolution, facing)
  end
  local function disposePrepared(resolution, prepared)
    return self:abort(resolution, prepared)
  end
  -- The covered destination stage: started once the warp artifacts are ready and
  -- advanced by the transition while the cover is up.
  local function produceDestination(sourceMap, warp, dynamicWarp)
    if type(runtime.beginDestinationStage) ~= "function" then
      return nil
    end
    return runtime:beginDestinationStage(sourceMap, warp, dynamicWarp)
  end
  local function commit(resolution, facing, prepared)
    return self:commit(resolution, facing, prepared)
  end
  local function onProfile(profile, phase)
    assert(type(profile) == "number", "field transition profile required")
    runtime.player.facing = phase == "enter" and runtime.transition.destinationFacing or runtime.transition.facing
  end
  local function cameraAdjust(profile, adjustment, player)
    assert(runtime.camera and type(runtime.camera.adjustTransition) == "function", "field transition camera required")
    if player and type(runtime.camera.setTransitionPlayer) == "function" then
      runtime.camera:setTransitionPlayer(player)
    end
    runtime.camera:adjustTransition(profile, adjustment)
    -- Hand the live camera back so the transition can drive timed angle
    -- choreography on its own source-frame clock. This stays an adapter:
    -- no counters, timing, or angle policy live here.
    return runtime.camera
  end
  local function onPanel(phase)
    runtime.transitionPanel = phase
    local screen = runtime.scriptHosts and runtime.scriptHosts.screen
    if screen and type(screen.setPanelTransition) == "function" then
      screen:setPanelTransition(phase)
    end
  end
  -- The post-commit area-preview selector: side-effect-free, reading only the
  -- compiled field-entry manifest and the host-local clock. The cave guard is
  -- the ORIGINAL source map's environment (never the destination's); the
  -- destination must be a listed preview destination; the sampled hour selects
  -- one of the four immutable time slots. The selected hour is snapshotted
  -- once and the semantic image key resolves from the already-generated
  -- manifest, so a clock rollover during the preview never swaps the art.
  local function selectPreview(sourceMap, destinationMap, profileId)
    local manifest = runtime.fieldEntryManifest
    local slots = manifest.previewByMapId[destinationMap.mapId]
    if slots == nil then
      return nil
    end
    local sourceEnvironment = sourceMap.fieldData and sourceMap.fieldData.transitionEnvironment
    if sourceEnvironment == "cave" then
      return nil
    end
    local clock = assert(runtime.localClock, "the area preview requires the host-local clock")
    local hour = assert(clock:nowLocal().hour, "the local clock must report a civil hour")
    assert(hour % 1 == 0 and hour >= 0 and hour < 24, "malformed local clock hour: " .. tostring(hour))
    local slot = (hour < 4 or hour >= 20) and 3 or (hour < 10 and 0 or (hour < 17 and 1 or 2))
    local imageKey = slots[slot]
    assert(imageKey, "the listed destination has no preview image for time slot " .. tostring(slot))
    return { imageKey = imageKey, timeSlot = slot, profileId = profileId }
  end
  -- The follower collaborator closes over the live following-mon controller
  -- with a late read: the transition composes before the field services own
  -- the controller, so presence/recall/rejoin resolve it at hook-fire time.
  -- Presence reads the live party (the reconciled lead lags by a tick after
  -- party changes), departure recalls through the instant recall hide, and
  -- each arrival rejoins hidden on the player tile until the first trail
  -- step reveals (retail MoveToPlayer + HideUntilStep with the trail-step
  -- observation as the reveal owner).
  local function followerPresent()
    local followingMon = runtime.followingMon
    return followingMon ~= nil and followingMon:isSourceActive()
  end
  local function followerRecall()
    local followingMon = assert(runtime.followingMon, "follower recall implies the controller")
    followingMon:hideForRecall()
  end
  local function followerRejoin(reason)
    local followingMon = assert(runtime.followingMon, "follower rejoin implies the controller")
    followingMon:rejoin(reason)
  end
  local follower = { isPresent = followerPresent, recall = followerRecall, rejoin = followerRejoin }
  transition = FieldTransition.new({
    loader = runtime.mapLoader,
    prepare = prepare,
    disposePrepared = disposePrepared,
    produceDestination = produceDestination,
    commit = commit,
    doorAt = doorAt,
    escalatorAt = escalatorAt,
    resolveDestination = resolveDestination,
    dynamicWarp = savedDynamicWarp,
    onStart = onStart,
    playSound = playSound,
    stopSound = stopSound,
    onProfile = onProfile,
    cameraAdjust = cameraAdjust,
    onPanel = onPanel,
    selectPreview = selectPreview,
    follower = follower,
  })
  return transition
end

return FieldWorldSwapCoordinator
