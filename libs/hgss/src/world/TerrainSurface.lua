-- Runtime index over normalized BDHC plates. It answers horizontal containment
-- and evaluates the authoritative gameplay plane; permission/collision policy
-- deliberately remains outside this pure domain module.
--
-- A composite region (FieldRegion) joins several cells' plate sets, translating
-- every neighbor plate into the central frame and tagging it with its cell
-- offset. Retail resolves one BDHC's plates in source record order, and a BDHC
-- may legitimately declare the same floor twice (the Rocket Hideout's own
-- neighbor chunk carries a wide strip plus one-tile splits of it, and its second
-- floor's central chunk declares its whole partition twice). A coordinate in a
-- composite region therefore resolves against the first containing cell's plates
-- (the central cell first, then neighbors in load order) and, inside that cell,
-- against one record per plane: a later record covering the same point on the
-- same plane is the same physical surface, not a second candidate. Distinct
-- planes that merely share a height still tie, so resolution keeps refusing to
-- choose between them. A single plate set (one cell, no offsets) keeps the
-- strict single-surface policy: every covering record is a candidate.

---@class TerrainSurface
---@field artifact table<string, unknown>
---@field plates table[]
---@field plateById table<integer, table<string, unknown>>
---@field cells { plates: table[] }[]? ordered cell plate groups; nil for a single plate set
local TerrainSurface = {}
TerrainSurface.__index = TerrainSurface

local CONTAINMENT_EPSILON = 1e-9
local PLANE_EPSILON = 1e-9

-- The cell offset triple a composite region's plates carry; nil for a plain
-- single-cell artifact.
---@param plate table<string, unknown>
---@return string?
local function cellOf(plate)
  if plate.cellOffsetX == nil then
    return nil
  end
  return plate.cellOffsetX .. ":" .. plate.cellOffsetY .. ":" .. plate.cellOffsetZ
end

---@param plates table[]
---@param localX number
---@param localZ number
---@param terrain TerrainSurface
---@return table[]
local function platesAt(terrain, plates, localX, localZ)
  local candidates = {}
  -- Full scans are intentional until strip boundary semantics are verified.
  for _, plate in ipairs(plates) do
    if plate.walkable ~= false and terrain:contains(plate.id, localX, localZ) then
      candidates[#candidates + 1] = plate
    end
  end
  return candidates
end

---@param left table<string, unknown>
---@param right table<string, unknown>
---@return boolean
local function samePlane(left, right)
  local leftNormal, rightNormal = left.normal, right.normal
  return math.abs(leftNormal.x - rightNormal.x) <= PLANE_EPSILON
    and math.abs(leftNormal.y - rightNormal.y) <= PLANE_EPSILON
    and math.abs(leftNormal.z - rightNormal.z) <= PLANE_EPSILON
    and math.abs(left.distance - right.distance) <= PLANE_EPSILON
end

-- One cell's covering records in source order, with duplicate records of an
-- already covered plane dropped.
---@param terrain TerrainSurface
---@param plates table[]
---@param localX number
---@param localZ number
---@return table[]
local function distinctPlatesAt(terrain, plates, localX, localZ)
  local candidates = {}
  for _, plate in ipairs(platesAt(terrain, plates, localX, localZ)) do
    local duplicate = false
    for _, accepted in ipairs(candidates) do
      if samePlane(accepted, plate) then
        duplicate = true
        break
      end
    end
    if not duplicate then
      candidates[#candidates + 1] = plate
    end
  end
  return candidates
end

-- The ordered cell groups behind one plate set: nil for a plain single-cell
-- artifact (or a lone cell group, which keeps the plain single plate set
-- behavior), otherwise the central cell first in load order.
---@param plates table[]
---@return { plates: table[] }[]?
local function buildCells(plates)
  local cells, cellByKey = {}, {}
  for _, plate in ipairs(plates) do
    local key = cellOf(plate)
    if key == nil then
      return nil
    end
    local cell = cellByKey[key]
    if cell == nil then
      cell = { plates = {} }
      cellByKey[key] = cell
      cells[#cells + 1] = cell
    end
    cell.plates[#cell.plates + 1] = plate
  end
  -- A lone cell group has no cross-cell composition to resolve: it keeps the
  -- plain single plate set behavior.
  if #cells < 2 then
    return nil
  end
  return cells
end

---@param artifact table<string, unknown>
---@param plateById table<integer, table<string, unknown>>
---@return TerrainSurface
local function indexedSurface(artifact, plateById)
  return setmetatable({
    artifact = artifact,
    plates = artifact.plates,
    plateById = plateById,
    cells = buildCells(artifact.plates),
  }, TerrainSurface)
end

function TerrainSurface.new(artifact)
  assert(
    type(artifact) == "table" and type(artifact.plates) == "table",
    "TerrainSurface.new requires a terrain artifact"
  )
  local plateById = {}
  for _, plate in ipairs(artifact.plates) do
    assert(plateById[plate.id] == nil, "duplicate terrain surface id")
    plateById[plate.id] = plate
  end
  return indexedSurface(artifact, plateById)
end

-- Adopt an index built alongside the plates by their producer. Field region
-- composition assigns each composite id while copying, so publication need not
-- scan the whole window again. Cell grouping is still derived from the
-- plates themselves, preserving the composite duplicate-plane policy.
---@param artifact table<string, unknown>
---@param plateById table<integer, table<string, unknown>>
---@return TerrainSurface
function TerrainSurface.fromIndexedPlates(artifact, plateById)
  assert(
    type(artifact) == "table" and type(artifact.plates) == "table" and type(plateById) == "table",
    "TerrainSurface.fromIndexedPlates requires plates and their index"
  )
  return indexedSurface(artifact, plateById)
end

function TerrainSurface:plate(surfaceId)
  return self.plateById[surfaceId]
end

function TerrainSurface:contains(surfaceId, localX, localZ)
  local plate = self.plateById[surfaceId]
  if not plate then
    return false
  end
  return localX >= plate.minX - CONTAINMENT_EPSILON
    and localX <= plate.maxX + CONTAINMENT_EPSILON
    and localZ >= plate.minZ - CONTAINMENT_EPSILON
    and localZ <= plate.maxZ + CONTAINMENT_EPSILON
end

function TerrainSurface:candidatesAt(localX, localZ)
  assert(type(localX) == "number" and type(localZ) == "number", "candidate coordinates must be numbers")
  local cells = self.cells
  if cells == nil then
    return platesAt(self, self.plates, localX, localZ)
  end
  for _, cell in ipairs(cells) do
    if #platesAt(self, cell.plates, localX, localZ) > 0 then
      return distinctPlatesAt(self, cell.plates, localX, localZ)
    end
  end
  return {}
end

function TerrainSurface:sampleHeight(surfaceId, localX, localZ)
  local plate = assert(self.plateById[surfaceId], "unknown terrain surface id")
  local normal = plate.normal
  assert(plate.walkable ~= false and normal.y ~= 0, "terrain surface must be walkable")
  return (plate.distance - normal.x * localX - normal.z * localZ) / normal.y
end

function TerrainSurface:sample(surfaceId, localX, localZ)
  local plate = assert(self.plateById[surfaceId], "unknown terrain surface id")
  return {
    surfaceId = surfaceId,
    worldY = self:sampleHeight(surfaceId, localX, localZ),
    normal = { x = plate.normal.x, y = plate.normal.y, z = plate.normal.z },
    slopeClass = plate.slopeClass,
  }
end

-- A plate's cross-cell identity, when it has one: physically-partitioned
-- (outdoor coverage) terrain carries both fields together; a plain local
-- plate (most indoor terrain) carries neither, which callers treat as "this
-- surface's identity is the local surfaceId alone".
---@param plate table<string, unknown>
---@return string?, integer?
function TerrainSurface.sourceIdentity(plate)
  if plate.cellKey == nil and plate.sourceSurfaceId == nil then
    return nil, nil
  end
  assert(plate.cellKey ~= nil and plate.sourceSurfaceId ~= nil, "terrain source surface identity is incomplete")
  return plate.cellKey, plate.sourceSurfaceId
end

return TerrainSurface
