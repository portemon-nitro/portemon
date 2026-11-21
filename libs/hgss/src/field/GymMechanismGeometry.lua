-- The gym mechanisms' runtime geometry: one source dynamic height plate
-- projected over the active runtime map's immutable terrain.
--
-- The source keeps a DynamicTerrainHeightManager plate separate from the BDHC
-- terrain (src/field/dynamic_terrain_height.c): the Violet Gym installs one
-- 3x3 plate at tile (14,19) and sets its height when the lift stops, and map
-- gameplay samples it exactly like any other surface. This owner is the same
-- thing for one map: it answers the source plate to the existing terrain
-- queries by delegating every other surface to the generated plates, and it
-- never mutates a decoded plate array. The plate's settled height is runtime
-- state: the source restores it from the saved union at map load
-- (GymmickInit_Violet) and moves it only when a ride stops, so a later gym
-- init command cannot silently drop a car the player is standing on.
--
-- A plate at the lower stop carries no offset from the floor, so this owner
-- publishes nothing while the car stands down: the generated floor plate
-- answers those samples, and two coincident surfaces never make one point
-- ambiguous.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")

---@class GymMechanismGeometry
---@field _runtimeMap table<string, unknown>|nil
---@field _base table<string, unknown>|nil
---@field private _raised boolean
local GymMechanismGeometry = {}
GymMechanismGeometry.__index = GymMechanismGeometry

-- DynamicTerrainHeightManager_SetPlate(0, 14, 19, 3, 3, ...) in
-- src/field/gymmick/violet.c: the car's footprint in map tiles.
GymMechanismGeometry.ELEVATOR_FIELD_X = 14
GymMechanismGeometry.ELEVATOR_FIELD_Z = 19
GymMechanismGeometry.ELEVATOR_WIDTH = 3
GymMechanismGeometry.ELEVATOR_DEPTH = 3

-- The car's own source transform: MapPropManager_LoadOne places build model
-- 111 at (FX32_CONST(0xF8), 0, FX32_CONST(0x148)) with a null rotation
-- override, i.e. the centre tile of the plate above.
GymMechanismGeometry.ELEVATOR_CAR_FIELD_X = 15
GymMechanismGeometry.ELEVATOR_CAR_FIELD_Z = 20

-- ELEVATOR_Y_UP - ELEVATOR_Y_DOWN = FX32_CONST(496) - FX32_CONST(32), i.e. 464
-- source units of 16 per tile.
GymMechanismGeometry.ELEVATOR_TILES = 29

-- The runtime surface id the dynamic plate answers with. Generated plate ids
-- are small sequential integers, so a high sentinel cannot collide.
GymMechanismGeometry.PLATE_SURFACE_ID = 0x7F000001

---@return GymMechanismGeometry
function GymMechanismGeometry.new()
  return setmetatable({ _runtimeMap = nil, _base = nil, _raised = false }, GymMechanismGeometry)
end

-- The wrapper terrain: every query delegates to the generated surfaces except
-- the active dynamic plate, which answers containment, height and candidates
-- like any other walkable surface of the map.
---@class DynamicPlateTerrain
---@field base table<string, unknown> the generated terrain every other query delegates to
---@field geometry GymMechanismGeometry the geometry that owns the plate this wrapper adds
---@field plates table[] the base's plate list, carried so the map reads one terrain shape
---@field artifact table<string, unknown> the base's own terrain artifact
local DynamicPlateTerrain = {}
DynamicPlateTerrain.__index = DynamicPlateTerrain

---@param base table<string, unknown>
---@param geometry GymMechanismGeometry
---@return DynamicPlateTerrain
function DynamicPlateTerrain.new(base, geometry)
  return setmetatable({ base = base, geometry = geometry }, DynamicPlateTerrain)
end

-- The dynamic plate's geometry in local map coordinates, or nil while the car
-- stands on the lower stop.
---@param self GymMechanismGeometry
---@return { id: integer, minX: number, maxX: number, minZ: number, maxZ: number, height: number }|nil
function GymMechanismGeometry:plate()
  local runtimeMap, base = self._runtimeMap, self._base
  if runtimeMap == nil or base == nil or not self._raised then
    return nil
  end
  local origin = assert(runtimeMap.coordinateOrigin, "active runtime map has no coordinate origin")
  local minX = GymMechanismGeometry.ELEVATOR_FIELD_X - origin.x
  local minZ = GymMechanismGeometry.ELEVATOR_FIELD_Z - origin.z
  local maxX = minX + GymMechanismGeometry.ELEVATOR_WIDTH
  local maxZ = minZ + GymMechanismGeometry.ELEVATOR_DEPTH
  -- The settled car floor is the map's own floor at the pad plus the raised
  -- travel: the source's absolute heights are the retail map's frame, and the
  -- port keeps the same relative lift over whatever floor the plate covers.
  return {
    id = GymMechanismGeometry.PLATE_SURFACE_ID,
    minX = minX,
    maxX = maxX,
    minZ = minZ,
    maxZ = maxZ,
    height = self:violetCarWorldY(),
  }
end

-- The map's own walkable floor height under one field tile. The dynamic plate
-- is excluded by construction: it is the moving surface, so this answers the
-- generated terrain the source prop heights are measured from.
---@param fieldX number
---@param fieldZ number
---@return number
function GymMechanismGeometry:floorWorldY(fieldX, fieldZ)
  local runtimeMap, base = self._runtimeMap, self._base
  if runtimeMap == nil or base == nil then
    Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, "the gym mechanism has no bound map floor", {
      fieldX = fieldX,
      fieldZ = fieldZ,
    })
  end
  ---@cast runtimeMap -nil
  ---@cast base -nil
  local origin = assert(runtimeMap.coordinateOrigin, "active runtime map has no coordinate origin")
  local localX = fieldX - origin.x + FieldCoordinates.TILE_CENTER_OFFSET
  local localZ = fieldZ - origin.z + FieldCoordinates.TILE_CENTER_OFFSET
  local best
  for _, candidate in ipairs(base:candidatesAt(localX, localZ)) do
    local height = base:sampleHeight(candidate.id, localX, localZ)
    if best == nil or height > best then
      best = height
    end
  end
  if best == nil then
    Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, "the source tile covers no walkable floor", {
      mapId = runtimeMap.mapId,
      fieldX = fieldX,
      fieldZ = fieldZ,
    })
  end
  return best
end

-- The car's settled world height: the floor under the pad while it stands on
-- the lower stop, plus the source travel while it is raised
-- (DynamicTerrainHeightManager_SetPlateHeight).
---@return number
function GymMechanismGeometry:violetCarWorldY()
  local floor = self:floorWorldY(GymMechanismGeometry.ELEVATOR_CAR_FIELD_X, GymMechanismGeometry.ELEVATOR_CAR_FIELD_Z)
  if self._raised then
    return floor + GymMechanismGeometry.ELEVATOR_TILES
  end
  return floor
end

-- The car's own horizontal world placement: the centre of its source tile.
---@return { x: number, z: number }|nil
function GymMechanismGeometry:violetCarWorldPoint()
  local runtimeMap = self._runtimeMap
  if runtimeMap == nil then
    return nil
  end
  local origin = assert(runtimeMap.coordinateOrigin, "active runtime map has no coordinate origin")
  local worldX, worldZ = FieldGrid.tileCenterToWorld(
    GymMechanismGeometry.ELEVATOR_CAR_FIELD_X - origin.x,
    GymMechanismGeometry.ELEVATOR_CAR_FIELD_Z - origin.z
  )
  return { x = worldX, z = worldZ }
end

local function plateContains(plate, localX, localZ)
  local epsilon = 1e-9
  return localX >= plate.minX - epsilon
    and localX <= plate.maxX + epsilon
    and localZ >= plate.minZ - epsilon
    and localZ <= plate.maxZ + epsilon
end

local function dynamicPlate(terrain)
  return terrain.geometry:plate()
end

function DynamicPlateTerrain:plate(surfaceId)
  local dynamic = dynamicPlate(self)
  if dynamic ~= nil and dynamic.id == surfaceId then
    return {
      id = dynamic.id,
      normal = { x = 0, y = 1, z = 0 },
      distance = dynamic.height,
      minX = dynamic.minX,
      maxX = dynamic.maxX,
      minZ = dynamic.minZ,
      maxZ = dynamic.maxZ,
      walkable = true,
      slopeClass = 0,
    }
  end
  return self.base:plate(surfaceId)
end

function DynamicPlateTerrain:contains(surfaceId, localX, localZ)
  local dynamic = dynamicPlate(self)
  if dynamic ~= nil and dynamic.id == surfaceId then
    return plateContains(dynamic, localX, localZ)
  end
  return self.base:contains(surfaceId, localX, localZ)
end

function DynamicPlateTerrain:candidatesAt(localX, localZ)
  local candidates = self.base:candidatesAt(localX, localZ)
  local dynamic = dynamicPlate(self)
  if dynamic ~= nil and plateContains(dynamic, localX, localZ) then
    candidates[#candidates + 1] = self:plate(dynamic.id)
  end
  return candidates
end

function DynamicPlateTerrain:sampleHeight(surfaceId, localX, localZ)
  local dynamic = dynamicPlate(self)
  if dynamic ~= nil and dynamic.id == surfaceId then
    return dynamic.height
  end
  return self.base:sampleHeight(surfaceId, localX, localZ)
end

function DynamicPlateTerrain:sample(surfaceId, localX, localZ)
  local dynamic = dynamicPlate(self)
  if dynamic ~= nil and dynamic.id == surfaceId then
    return { surfaceId = surfaceId, worldY = dynamic.height, normal = { x = 0, y = 1, z = 0 }, slopeClass = 0 }
  end
  return self.base:sample(surfaceId, localX, localZ)
end

function DynamicPlateTerrain:sourceIdentity(plate)
  local dynamic = dynamicPlate(self)
  if dynamic ~= nil and type(plate) == "table" and plate.id == dynamic.id then
    return nil, nil
  end
  return self.base:sourceIdentity(plate)
end

-- Install the wrapper over the generated terrain of the map this owner is
-- bound to. Only a raised plate ever needs it: while the car stands on the
-- lower stop the map keeps answering through its own surfaces untouched.
---@param self GymMechanismGeometry
local function installWrapper(self)
  local runtimeMap, base = self._runtimeMap, self._base
  if runtimeMap == nil or base == nil or runtimeMap.terrain ~= base then
    return
  end
  local terrain = DynamicPlateTerrain.new(base, self)
  terrain.plates = base.plates
  terrain.artifact = base.artifact
  runtimeMap.terrain = terrain
end

---@param self GymMechanismGeometry
local function removeWrapper(self)
  local runtimeMap, base = self._runtimeMap, self._base
  if runtimeMap == nil or base == nil then
    return
  end
  if runtimeMap.terrain ~= nil and runtimeMap.terrain.base == base then
    runtimeMap.terrain = base
  end
end

-- Bind to the map whose floor the plate is projected over. Rebinding detaches
-- the previous map (its terrain is the generated surface again) but keeps the
-- runtime plate: the map load, not the rebind, owns the settled floor.
---@param runtimeMap table<string, unknown>
function GymMechanismGeometry:bindMap(runtimeMap)
  assert(type(runtimeMap) == "table" and runtimeMap.terrain ~= nil, "gym mechanism geometry requires a runtime map")
  self:unbind()
  local base = runtimeMap.terrain
  if base.base ~= nil then
    base = base.base
  end
  if base.plates == nil or base.candidatesAt == nil then
    -- A map whose physical coverage has not composed yet cannot answer
    -- surfaces; there is nothing to project a plate over.
    return
  end
  self._runtimeMap, self._base = runtimeMap, base
  if self._raised then
    installWrapper(self)
  end
end

function GymMechanismGeometry:unbind()
  removeWrapper(self)
  self._runtimeMap, self._base = nil, nil
end

-- Map load: the source GymmickInit_Violet reads the settled union and places
-- the car, so the dynamic plate exists before any loaded position is sampled.
---@param raised boolean
function GymMechanismGeometry:restoreViolet(raised)
  assert(type(raised) == "boolean", "the violet plate needs its settled raised flag")
  self._raised = raised
end

---@return boolean
function GymMechanismGeometry:isVioletRaised()
  return self._raised
end

-- The lift's arrival stop: DynamicTerrainHeightManager_SetPlateHeight. Raising
-- the car installs the plate over the bound map's floor; lowering it gives the
-- generated surfaces back.
---@param raised boolean
function GymMechanismGeometry:setVioletRaised(raised)
  assert(type(raised) == "boolean", "the violet plate needs its settled raised flag")
  self._raised = raised
  if raised then
    installWrapper(self)
  else
    removeWrapper(self)
  end
end

return GymMechanismGeometry
