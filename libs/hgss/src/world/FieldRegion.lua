-- Composes one runtime map cell and its cached neighboring cells into a single
-- collision and terrain view. Coordinates remain local to the central cell;
-- neighboring BDHC planes are translated in all three axes.

local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local FieldRegion = {}

local function copyPlate(plate, id, offsetX, offsetY, offsetZ, cellKey)
  local copy = {}
  for key, value in pairs(plate) do
    copy[key] = value
  end
  copy.id = id
  copy.cellKey = cellKey
  copy.sourceSurfaceId = cellKey ~= nil and plate.id or nil
  copy.cellOffsetX = offsetX
  copy.cellOffsetY = offsetY
  copy.cellOffsetZ = offsetZ
  copy.minX = plate.minX + offsetX
  copy.maxX = plate.maxX + offsetX
  copy.minZ = plate.minZ + offsetZ
  copy.maxZ = plate.maxZ + offsetZ
  copy.normal = { x = plate.normal.x, y = plate.normal.y, z = plate.normal.z }
  copy.distance = plate.distance + plate.normal.x * offsetX + plate.normal.y * offsetY + plate.normal.z * offsetZ
  return copy
end

---@param cells table[]
---@param localX number
---@param localZ number
---@return table<string, unknown>?, number?, number?
local function cellAt(cells, localX, localZ)
  for _, cell in ipairs(cells) do
    local x, z = localX - cell.offsetTilesX, localZ - cell.offsetTilesZ
    if cell.collision:containsLocal(x, z) then
      return cell, x, z
    end
  end
  return nil
end

---@class FieldRegion.Collision
---@field cells table[]
---@field containsLocal fun(self: FieldRegion.Collision, localX: number, localZ: number): boolean
---@field getLocal fun(self: FieldRegion.Collision, localX: number, localZ: number): table<string, unknown>
---@field isBlockedLocal fun(self: FieldRegion.Collision, localX: number, localZ: number): boolean
local Collision = {}
Collision.__index = Collision

---@param self FieldRegion.Collision
---@param localX number
---@param localZ number
---@return boolean
function Collision:containsLocal(localX, localZ)
  return cellAt(self.cells, localX, localZ) ~= nil
end

---@param self FieldRegion.Collision
---@param localX number
---@param localZ number
---@return table<string, unknown>
function Collision:getLocal(localX, localZ)
  local cell, x, z = cellAt(self.cells, localX, localZ)
  assert(cell, "field coordinate outside composed region")
  local result = cell.collision:getLocal(x, z)
  result.cellKey = cell.key
  return result
end

---@param self FieldRegion.Collision
---@param localX number
---@param localZ number
---@return boolean
function Collision:isBlockedLocal(localX, localZ)
  local cell, x, z = cellAt(self.cells, localX, localZ)
  assert(cell, "field coordinate outside composed region")
  return cell.collision:isBlockedLocal(x, z)
end

---@param cells table[]
---@return FieldRegion.Collision
local function collisionRegion(cells)
  return setmetatable({ cells = cells }, Collision)
end

---@param self table<string, unknown>
---@param cellKey string
---@param sourceSurfaceId integer
---@return integer?
local function sourceSurface(self, cellKey, sourceSurfaceId)
  local byCell = self._sourceSurfaceIndex[cellKey]
  if byCell == nil then
    return nil
  end
  return byCell[sourceSurfaceId]
end

function FieldRegion.new(centralCollision, centralTerrain, neighbors, centralKey, surfaceIdBase)
  assert(centralCollision and centralCollision.containsLocal, "central collision grid required")
  assert(centralTerrain and centralTerrain.plates, "central terrain surfaces required")

  local cells = {
    {
      offsetTilesX = 0,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      collision = centralCollision,
      terrain = centralTerrain,
      key = centralKey,
    },
  }
  for _, neighbor in ipairs(neighbors or {}) do
    assert(neighbor.collision and neighbor.terrain, "neighbor collision and terrain required")
    assert(type(neighbor.offsetTilesX) == "number", "neighbor X offset required")
    assert(type(neighbor.offsetTilesY) == "number", "neighbor Y offset required")
    assert(type(neighbor.offsetTilesZ) == "number", "neighbor Z offset required")
    cells[#cells + 1] = neighbor
  end

  -- One compact index from a stable (cell, source surface) identity to the
  -- composite plate id, built while the plates are copied: the probe and commit
  -- paths resolve a source surface per step instead of scanning every plate.
  local plates, nextSurfaceId, sourceSurfaceIndex = {}, surfaceIdBase or 0, {}
  local function appendPlate(plate, offsetX, offsetY, offsetZ, cell)
    plates[#plates + 1] = copyPlate(plate, nextSurfaceId, offsetX, offsetY, offsetZ, cell.key)
    -- A plate without its own source identity (or a cell without a key) has
    -- none to index: central surfaces stay local and are never looked up by
    -- source id.
    if plate.id ~= nil and cell.key ~= nil then
      local byCell = sourceSurfaceIndex[cell.key]
      if byCell == nil then
        byCell = {}
        sourceSurfaceIndex[cell.key] = byCell
      end
      byCell[plate.id] = nextSurfaceId
    end
    nextSurfaceId = nextSurfaceId + 1
  end
  for _, plate in ipairs(centralTerrain.plates) do
    appendPlate(plate, 0, 0, 0, cells[1])
  end
  for index = 2, #cells do
    local cell = cells[index]
    for _, plate in ipairs(cell.terrain.plates) do
      appendPlate(plate, cell.offsetTilesX, cell.offsetTilesY, cell.offsetTilesZ, cell)
    end
  end

  return {
    collision = collisionRegion(cells),
    terrain = TerrainSurface.new({ schema = "g4-composite-terrain-v1", plates = plates }),
    cells = cells,
    _sourceSurfaceIndex = sourceSurfaceIndex,
    sourceSurface = sourceSurface,
  }
end

return FieldRegion
