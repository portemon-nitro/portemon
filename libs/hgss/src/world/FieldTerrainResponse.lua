-- Resolves a committed destination metatile into a presentation-only terrain
-- response. The resolver is pure and deliberately knows nothing about audio,
-- encounters, cache assets, or LÖVE.

local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local FieldTerrainResponse = {}

---@param behavior integer
---@return string?
function FieldTerrainResponse.kindFor(behavior)
  if MetatileBehavior.isTallGrass(behavior) then
    return "tall_grass"
  end
  if MetatileBehavior.isVeryTallGrass(behavior) then
    return "very_tall_grass"
  end
  return nil
end

-- The opposite of a cardinal facing: the tile a stepping object leaves behind.
local BEHIND_DELTA = {
  north = { x = 0, z = 1 },
  south = { x = 0, z = -1 },
  west = { x = 1, z = 0 },
  east = { x = -1, z = 0 },
}

---@param map RuntimeFieldMap
---@param fieldX integer
---@param fieldZ integer
---@return integer?
local function behaviorAt(map, fieldX, fieldZ)
  local collision = map.collision
  local origin = assert(map.coordinateOrigin, "terrain response map origin is required")
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  if collision == nil or not collision:containsLocal(localX, localZ) then
    return nil
  end
  return collision:getLocal(localX, localZ).behavior
end

-- Resolve one stepping map object's committed destination into the
-- presentation-only terrain responses the source spawns for that object
-- (MapObject_SpawnTallGrassOnStep): grass responds at the object's own tile and
-- a large follower (source shape nibble above zero) additionally disturbs the
-- tile behind it when it faces east or west.
---@param step { map: RuntimeFieldMap, fieldX: integer, fieldZ: integer, worldY: number, facing: string, cellKey: string?, sourceSurfaceId: integer?, large: boolean? }
---@return table[]
function FieldTerrainResponse.resolveActorStep(step)
  assert(type(step) == "table", "terrain step is required")
  local map = assert(step.map, "terrain step requires its runtime map")
  local responses = {}
  local function respondAt(fieldX, fieldZ)
    local behavior = behaviorAt(map, fieldX, fieldZ)
    local kind = behavior ~= nil and FieldTerrainResponse.kindFor(behavior) or nil
    if kind == nil then
      return
    end
    responses[#responses + 1] = {
      kind = kind,
      fieldX = fieldX,
      fieldZ = fieldZ,
      worldY = step.worldY,
      cellKey = step.cellKey,
      sourceSurfaceId = step.sourceSurfaceId,
    }
  end
  respondAt(step.fieldX, step.fieldZ)
  if step.large == true and (step.facing == "east" or step.facing == "west") then
    local delta = assert(BEHIND_DELTA[step.facing], "unknown terrain step facing " .. tostring(step.facing))
    respondAt(step.fieldX + delta.x, step.fieldZ + delta.z)
  end
  return responses
end

---@param movement { committed: boolean, destination: { behavior: integer, fieldX: integer, fieldZ: integer, worldY: number, cellKey: string?, sourceCellKey: string?, sourceSurfaceId: integer? }, direction: string }
---@return table[]
function FieldTerrainResponse.resolve(movement)
  assert(type(movement) == "table", "terrain movement is required")
  if not movement.committed then
    return {}
  end
  local destination = assert(movement.destination, "committed terrain destination is required")
  local kind = FieldTerrainResponse.kindFor(destination.behavior)
  if not kind then
    return {}
  end
  return {
    {
      kind = kind,
      fieldX = destination.fieldX,
      fieldZ = destination.fieldZ,
      worldY = destination.worldY,
      cellKey = destination.cellKey or destination.sourceCellKey,
      sourceSurfaceId = destination.sourceSurfaceId,
    },
  }
end

return FieldTerrainResponse
