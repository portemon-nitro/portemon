-- Stateless physical placement proposals for field actors: stable surface
-- identity, surface resolution, coordinate projection and adjacent-step
-- endpoints over the world primitives. Every function borrows the runtime
-- map and read-only actor/point facts and returns fresh plain proposals; no
-- function publishes actor, occupancy or save state.

local Errors = require("libs.errors.src.Errors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local FieldActorPlacement = {}

-- MapObject_SetPositionVectorFromObjectEvent uses FX32 source coordinates;
-- object-event Y is expressed in 16 model units per runtime world tile.
local FX32_ONE = 4096
local SOURCE_MODEL_UNITS_PER_TILE = 16
local OBJECT_EVENT_Y_UNITS = SOURCE_MODEL_UNITS_PER_TILE * FX32_ONE

-- The terrain-surface failure codes an actor construction can recover from,
-- mapped to the actor-scoped codes the script world observes. A structured
-- error of any other kind propagates unchanged rather than being re-labelled.
local SURFACE_ERROR_CODES = {
  [FieldErrors.TERRAIN_SURFACE_NOT_FOUND] = FieldErrors.ACTOR_SURFACE_MISSING,
  [FieldErrors.TERRAIN_SURFACE_AMBIGUOUS] = FieldErrors.ACTOR_SURFACE_AMBIGUOUS,
  [FieldErrors.TERRAIN_SURFACE_DISCONNECTED] = FieldErrors.ACTOR_SURFACE_AMBIGUOUS,
}

local sourceIdentityFromPlate = TerrainSurface.sourceIdentity

local STEP_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

---@param runtimeMap RuntimeFieldMap
---@param fieldX integer
---@param fieldZ integer
---@return boolean
function FieldActorPlacement.isResident(runtimeMap, fieldX, fieldZ)
  return not runtimeMap.coverage or runtimeMap.coverage:containsGlobal(fieldX, fieldZ)
end

---@param fieldX integer
---@param fieldZ integer
---@return string
function FieldActorPlacement.cellKeyFor(fieldX, fieldZ)
  return string.format("%d:%d", math.floor(fieldX / 32), math.floor(fieldZ / 32))
end

---@param runtimeMap RuntimeFieldMap
---@param cellKey string
---@param sourceSurfaceId integer?
---@return integer?
function FieldActorPlacement.currentSurfaceFor(runtimeMap, cellKey, sourceSurfaceId)
  if runtimeMap.fieldRegion and runtimeMap.fieldRegion.sourceSurface then
    return runtimeMap.fieldRegion:sourceSurface(cellKey, sourceSurfaceId)
  end
  return nil
end

---@param runtimeMap RuntimeFieldMap
---@param candidate FieldOccupancyCandidate
---@return string kind
---@return string|integer first
---@return integer? second
function FieldActorPlacement.stableSurfaceIdentity(runtimeMap, candidate)
  assert(type(candidate) == "table", "occupancy candidate is required")
  if candidate.sourceSurfaceId ~= nil then
    assert(candidate.cellKey ~= nil, "stable source surface id requires a cell key")
    return "source", candidate.cellKey, candidate.sourceSurfaceId
  end
  local surfaceId = assert(candidate.surfaceId, "occupancy candidate requires a surface identity")
  local plate = assert(runtimeMap.terrain:plate(surfaceId), "occupancy candidate surface id is unknown")
  local cellKey, sourceSurfaceId = sourceIdentityFromPlate(plate)
  if cellKey ~= nil then
    return "source", cellKey, sourceSurfaceId
  end
  return "local", surfaceId, nil
end

---@param leftKind string
---@param leftFirst string|integer
---@param leftSecond integer?
---@param rightKind string
---@param rightFirst string|integer
---@param rightSecond integer?
---@return boolean
function FieldActorPlacement.sameSurfaceIdentity(leftKind, leftFirst, leftSecond, rightKind, rightFirst, rightSecond)
  return leftKind == rightKind and leftFirst == rightFirst and leftSecond == rightSecond
end

---@param runtimeMap RuntimeFieldMap
---@param left FieldOccupancyCandidate
---@param right FieldOccupancyCandidate
---@return boolean
function FieldActorPlacement.samePhysicalCandidate(runtimeMap, left, right)
  if left.fieldX ~= right.fieldX or left.fieldZ ~= right.fieldZ then
    return false
  end
  local leftKind, leftFirst, leftSecond = FieldActorPlacement.stableSurfaceIdentity(runtimeMap, left)
  local rightKind, rightFirst, rightSecond = FieldActorPlacement.stableSurfaceIdentity(runtimeMap, right)
  return FieldActorPlacement.sameSurfaceIdentity(leftKind, leftFirst, leftSecond, rightKind, rightFirst, rightSecond)
end

---@param runtimeMap RuntimeFieldMap
---@param fieldX integer
---@param fieldZ integer
---@param sourceY number
---@param actorId string
---@return FieldActorSurfaceSample
function FieldActorPlacement.resolveSurfaceAt(runtimeMap, fieldX, fieldZ, sourceY, actorId)
  local ok, result = pcall(function()
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
    -- Terrain is sampled at the tile centre, as the player and camera do.
    local surfaceOptions = {
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = sourceY / OBJECT_EVENT_Y_UNITS,
    } ---@type FieldActorSurfaceOptions
    return SurfaceResolver.new(runtimeMap.terrain):resolve(surfaceOptions) --[[@as FieldActorSurfaceSample]]
  end)
  if ok then
    return result --[[@as FieldActorSurfaceSample]]
  end
  if not Errors.is(result) then
    error(result)
  end
  -- Only expected surface-resolution conditions are actor-surface failures; a
  -- structured error of any other kind (e.g. out-of-coverage coordinates)
  -- propagates unchanged rather than being re-labelled as a missing surface.
  local structuredError = result --[[@as Errors.Error]]
  local code = SURFACE_ERROR_CODES[structuredError.code]
  if not code then
    error(structuredError)
  end
  Errors.raise(
    code,
    "actor " .. actorId .. " has no single terrain surface: " .. structuredError.message,
    { actorId = actorId, fieldX = fieldX, fieldZ = fieldZ, sourceY = sourceY, cause = structuredError.code }
  )
  error("unreachable after actor surface error")
end

---@param runtimeMap RuntimeFieldMap
---@param event FieldActorEvent
---@param actorId string
---@return FieldActorSurfaceSample?
function FieldActorPlacement.resolveSurface(runtimeMap, event, actorId)
  -- A scene-less logical map carries no collision or terrain: actors
  -- instantiate without surface positioning (the existing nil-surface
  -- path) and resolve it on visual realization.
  if runtimeMap.collision == nil or runtimeMap.terrain == nil then
    return nil
  end
  return FieldActorPlacement.resolveSurfaceAt(runtimeMap, event.x, event.z, event.y, actorId)
end

-- Projects one action endpoint into the current physical frame. Resident
-- points reuse the committed terrain/source-surface path; points outside
-- coverage rebase X/Z from the new origin and keep their known height and
-- source identity with resident=false.
---@param runtimeMap RuntimeFieldMap
---@param point FieldActorManager.Actor|FieldActorManager.EndpointPoint
---@return FieldObjectActor.ActionEndpoint
function FieldActorPlacement.projectEndpoint(runtimeMap, point)
  local fieldX, fieldZ = point.fieldX, point.fieldZ
  if not FieldActorPlacement.isResident(runtimeMap, fieldX, fieldZ) then
    local origin = assert(runtimeMap.coordinateOrigin, "runtime map coordinate origin required")
    local worldX, worldZ = FieldGrid.tileCenterToWorld(fieldX - origin.x, fieldZ - origin.z)
    return {
      fieldX = fieldX,
      fieldZ = fieldZ,
      surfaceId = point.surfaceId,
      cellKey = point.cellKey,
      sourceSurfaceId = point.sourceSurfaceId,
      worldX = worldX,
      worldY = point.worldY,
      worldZ = worldZ,
      resident = false,
    }
  end
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  local centerX, centerZ = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local surfaceId = point.surfaceId
  if point.cellKey and point.sourceSurfaceId and runtimeMap.fieldRegion and runtimeMap.fieldRegion.sourceSurface then
    surfaceId = assert(
      FieldActorPlacement.currentSurfaceFor(runtimeMap, point.cellKey, point.sourceSurfaceId),
      "actor source surface is absent from coverage"
    )
  end
  if surfaceId == nil or not runtimeMap.terrain:contains(surfaceId, centerX, centerZ) then
    local sample = FieldActorPlacement.resolveSurfaceAt(runtimeMap, fieldX, fieldZ, point.sourceEvent.y, point.actorId)
    surfaceId = sample.surfaceId
  end
  local plate = assert(runtimeMap.terrain:plate(surfaceId), "actor projected surface is missing")
  local cellKey
  local sourceSurfaceId
  if point.sourceSurfaceId ~= nil then
    assert(point.cellKey ~= nil, "actor source surface id requires a cell key")
    cellKey = point.cellKey
    sourceSurfaceId = point.sourceSurfaceId
  else
    local plateCellKey, plateSourceSurfaceId = sourceIdentityFromPlate(plate)
    cellKey = point.cellKey or plateCellKey
    sourceSurfaceId = plateSourceSurfaceId
  end
  local worldY = runtimeMap.terrain:sampleHeight(surfaceId, centerX, centerZ)
  local world = FieldCoordinates.fieldToWorld(runtimeMap, fieldX, fieldZ, worldY)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    cellKey = cellKey or FieldActorPlacement.cellKeyFor(fieldX, fieldZ),
    sourceSurfaceId = sourceSurfaceId,
    worldX = world.x,
    worldY = world.y,
    worldZ = world.z,
    resident = true,
  }
end

---@param runtimeMap RuntimeFieldMap
---@param actor FieldActorManager.Actor
---@return FieldObjectActor.ActionEndpoint
function FieldActorPlacement.projectionFor(runtimeMap, actor)
  local state = actor:numericState()
  return FieldActorPlacement.projectEndpoint(runtimeMap, {
    fieldX = state.fieldX,
    fieldZ = state.fieldZ,
    surfaceId = state.hasSurfaceId == 1 and state.surfaceId or nil,
    cellKey = actor.cellKey,
    sourceSurfaceId = state.hasSourceSurfaceId == 1 and state.sourceSurfaceId or nil,
    worldY = state.hasWorldPosition == 1 and state.worldY or nil,
    sourceEvent = actor.sourceEvent,
    actorId = actor.actorId,
  })
end

---@param err unknown
---@return boolean
local function movementErrorIsBlocked(err)
  if not Errors.is(err) then
    return false
  end
  ---@cast err Errors.Error
  return err.code == FieldErrors.FIELD_COORDINATES_OUT_OF_COVERAGE or SurfaceResolver.isStepRejection(err)
end

-- The one shared physical placement/step rejection classification: a tile
-- outside coverage or a destination surface beyond the reachable step is a
-- placement the caller waits out or steps around. Every other structured
-- failure (ambiguous or missing surfaces, occupancy conflicts, programmer
-- faults, data corruption) propagates unchanged through this predicate's
-- callers.
---@param err unknown
---@return boolean
function FieldActorPlacement.isPlacementRejection(err)
  return movementErrorIsBlocked(err)
end

---@param runtimeMap RuntimeFieldMap
---@param actor FieldActorManager.Actor
---@param direction FieldDirection
---@param checkStepReachability boolean
---@param probeWithoutStableSourceIdentity boolean
---@return table<string, unknown>? endpoint
---@return boolean blocked
function FieldActorPlacement.resolveAdjacentDestination(
  runtimeMap,
  actor,
  direction,
  checkStepReachability,
  probeWithoutStableSourceIdentity
)
  local delta = assert(STEP_DELTAS[direction], "unknown actor direction " .. tostring(direction))
  local state = actor:numericState()
  local fieldX, fieldZ = state.fieldX + delta.x, state.fieldZ + delta.z
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  local centerX, centerZ = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local sample
  local blocked = false
  if
    runtimeMap.probePhysicalCell
    and (probeWithoutStableSourceIdentity or (actor.cellKey ~= nil and state.hasSourceSurfaceId == 1))
  then
    local currentSourceSurfaceId = (state.hasSourceSurfaceId == 1 and state.sourceSurfaceId or nil) --[[@as integer]]
    local currentY = (state.hasWorldPosition == 1 and state.worldY or nil) --[[@as number]]
    local probe = runtimeMap:probePhysicalCell(fieldX, fieldZ, {
      currentCellKey = actor.cellKey,
      currentSourceSurfaceId = currentSourceSurfaceId,
      currentY = currentY,
      fromFieldX = state.fieldX,
      fromFieldZ = state.fieldZ,
    })
    if probe == nil then
      return nil, true
    end
    assert(type(probe.collision) == "table", "physical probe collision facts are missing")
    if checkStepReachability and probe.collision.blocked then
      return nil, true
    end
    assert(
      (probe.cellKey == nil and probe.sourceSurfaceId == nil) or (probe.cellKey ~= nil and probe.sourceSurfaceId ~= nil),
      "physical probe stable surface identity is incomplete"
    )
    assert(type(probe.worldY) == "number", "physical probe world height is missing")
    sample = {
      surfaceId = probe.surfaceId,
      cellKey = probe.cellKey,
      sourceSurfaceId = probe.sourceSurfaceId,
      worldY = probe.worldY,
    }
  else
    blocked = runtimeMap.collision.isBlockedLocal ~= nil and runtimeMap.collision:isBlockedLocal(localX, localZ)
    local surfaceOptions = {
      localX = centerX,
      localZ = centerZ,
      currentY = state.hasWorldPosition == 1 and state.worldY or nil,
      currentSurfaceId = state.hasSurfaceId == 1 and state.surfaceId or nil,
    }
    if checkStepReachability then
      surfaceOptions.crossing = {
        fromX = (state.fieldX - runtimeMap.coordinateOrigin.x) + FieldCoordinates.TILE_CENTER_OFFSET,
        fromZ = (state.fieldZ - runtimeMap.coordinateOrigin.z) + FieldCoordinates.TILE_CENTER_OFFSET,
        toX = centerX,
        toZ = centerZ,
      }
    end
    sample = SurfaceResolver.new(runtimeMap.terrain):resolve(surfaceOptions)
    local plate = assert(runtimeMap.terrain:plate(sample.surfaceId), "actor destination surface is missing")
    sample.cellKey, sample.sourceSurfaceId = sourceIdentityFromPlate(plate)
  end

  local world = FieldCoordinates.fieldToWorld(runtimeMap, fieldX, fieldZ, sample.worldY)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = sample.surfaceId,
    cellKey = sample.cellKey or FieldActorPlacement.cellKeyFor(fieldX, fieldZ),
    sourceSurfaceId = sample.sourceSurfaceId,
    worldX = world.x,
    worldY = world.y,
    worldZ = world.z,
    resident = FieldActorPlacement.isResident(runtimeMap, fieldX, fieldZ),
  },
    blocked
end

return FieldActorPlacement
