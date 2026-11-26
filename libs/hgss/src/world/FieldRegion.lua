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
  return FieldRegion.begin(centralCollision, centralTerrain, neighbors, centralKey, surfaceIdBase):finish()
end

---@class FieldRegion.Task
---@field advance fun(self: FieldRegion.Task, maxPlates: number): integer copies up to maxPlates plates
---@field isReady fun(self: FieldRegion.Task): boolean
---@field finish fun(self: FieldRegion.Task): table<string, unknown> the composed region
---@field private _cells table[]
---@field private _nextCellIndex integer
---@field private _nextPlateIndex integer
---@field private _plates table[]
---@field private _nextSurfaceId integer
---@field private _sourceSurfaceIndex table<string, table<integer, integer>>
---@field private _terrain TerrainSurface?
---@field private _region table<string, unknown>?

local FieldRegionTask = {}
FieldRegionTask.__index = FieldRegionTask

-- Starts a resumable composition of the central cell and its neighbors. One
-- advance unit copies one terrain plate into the composite surface, so a caller
-- with a frame budget can spread a whole window over several frames without
-- changing the published result.
---@param centralCollision table<string, unknown>
---@param centralTerrain table<string, unknown>
---@param neighbors table[]?
---@param centralKey string?
---@param surfaceIdBase integer?
---@return FieldRegion.Task
function FieldRegion.begin(centralCollision, centralTerrain, neighbors, centralKey, surfaceIdBase)
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

  return setmetatable({
    _cells = cells,
    _nextCellIndex = 1,
    _nextPlateIndex = 1,
    _plates = {},
    _nextSurfaceId = surfaceIdBase or 0,
    _sourceSurfaceIndex = {},
    _terrain = nil,
    _region = nil,
  }, FieldRegionTask)
end

-- One compact index from a stable (cell, source surface) identity to the
-- composite plate id, built while the plates are copied: the probe and commit
-- paths resolve a source surface per step instead of scanning every plate.
---@param plate table<string, unknown>
---@param cell table<string, unknown>
function FieldRegionTask:_appendPlate(plate, cell)
  local id = self._nextSurfaceId
  self._plates[#self._plates + 1] =
    copyPlate(plate, id, cell.offsetTilesX, cell.offsetTilesY, cell.offsetTilesZ, cell.key)
  -- A plate without its own source identity (or a cell without a key) has
  -- none to index: central surfaces stay local and are never looked up by
  -- source id.
  if plate.id ~= nil and cell.key ~= nil then
    local byCell = self._sourceSurfaceIndex[cell.key]
    if byCell == nil then
      byCell = {}
      self._sourceSurfaceIndex[cell.key] = byCell
    end
    byCell[plate.id] = id
  end
  self._nextSurfaceId = id + 1
end

-- Copy up to `maxPlates` terrain plates into the composite surface and return
-- how many were copied. One plate is the indivisible unit: it is a table copy
-- plus one index entry.
---@param maxPlates number
---@return integer consumed
function FieldRegionTask:advance(maxPlates)
  assert(type(maxPlates) == "number" and maxPlates >= 0 and maxPlates % 1 == 0)
  local consumed = 0
  while consumed < maxPlates and self._terrain == nil do
    local cell = self._cells[self._nextCellIndex]
    if cell == nil then
      self._terrain = TerrainSurface.new({ schema = "g4-composite-terrain-v1", plates = self._plates })
      consumed = consumed + 1
      break
    end
    local plate = cell.terrain.plates[self._nextPlateIndex]
    if plate == nil then
      self._nextCellIndex = self._nextCellIndex + 1
      self._nextPlateIndex = 1
    else
      self:_appendPlate(plate, cell)
      self._nextPlateIndex = self._nextPlateIndex + 1
      consumed = consumed + 1
    end
  end
  return consumed
end

---@return boolean
function FieldRegionTask:isReady()
  return self._terrain ~= nil
end

---@return table<string, unknown> the composed region
function FieldRegionTask:finish()
  while self._terrain == nil do
    self:advance(256)
  end
  if self._region == nil then
    self._region = {
      collision = collisionRegion(self._cells),
      terrain = self._terrain,
      cells = self._cells,
      _sourceSurfaceIndex = self._sourceSurfaceIndex,
      sourceSurface = sourceSurface,
    }
  end
  return self._region
end

return FieldRegion
