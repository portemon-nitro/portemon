-- Accumulates a map-local valid-tile mask and selects its nearest centroid tile.

---@class SaveEditorMapSurvey
---@field masks table<string, { x: integer, z: integer, rows: number[], classifiedRows: number[] }>
---@field count integer
---@field sumX number
---@field sumZ number
---@field centroidX number?
---@field centroidZ number?
---@field classified boolean
---@field scanCell integer
---@field scanIndex integer
---@field bestX integer?
---@field bestZ integer?
---@field bestDistance number?
---@field complete boolean
---@field taken boolean
---@field released boolean
local SaveEditorMapSurvey = {}
SaveEditorMapSurvey.__index = SaveEditorMapSurvey

local TILE_SIZE = 32

---@return SaveEditorMapSurvey
function SaveEditorMapSurvey.new()
  return setmetatable({
    masks = {},
    count = 0,
    sumX = 0,
    sumZ = 0,
    centroidX = nil,
    centroidZ = nil,
    classified = false,
    scanCell = 0,
    scanIndex = 0,
    bestX = nil,
    bestZ = nil,
    bestDistance = nil,
    complete = false,
    taken = false,
    released = false,
  }, SaveEditorMapSurvey)
end

---@param fieldX integer
---@param fieldZ integer
---@param selectable boolean
function SaveEditorMapSurvey:record(fieldX, fieldZ, selectable)
  assert(not self.released and not self.classified, "survey classification is closed")
  assert(type(fieldX) == "number" and fieldX % 1 == 0, "survey fieldX must be an integer")
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0, "survey fieldZ must be an integer")
  assert(type(selectable) == "boolean", "survey classification must be boolean")
  local cellX, cellZ = math.floor(fieldX / TILE_SIZE), math.floor(fieldZ / TILE_SIZE)
  local cellKey = tostring(cellX) .. ":" .. tostring(cellZ)
  local mask = self.masks[cellKey]
  if mask == nil then
    mask = { x = cellX, z = cellZ, rows = {}, classifiedRows = {} }
    for row = 1, TILE_SIZE do
      mask.rows[row] = 0
      mask.classifiedRows[row] = 0
    end
    self.masks[cellKey] = mask
  end
  local row = fieldZ - cellZ * TILE_SIZE + 1
  local column = fieldX - cellX * TILE_SIZE
  local bit = (2 ^ column) --[[@as integer]]
  local bits = mask.rows[row]
  local classified = mask.classifiedRows[row]
  assert(math.floor(classified / bit) % 2 == 0, "survey tile was classified twice")
  mask.classifiedRows[row] = classified + bit
  if not selectable then
    return
  end
  mask.rows[row] = bits + bit
  self.count = self.count + 1
  self.sumX = self.sumX + fieldX
  self.sumZ = self.sumZ + fieldZ
end

function SaveEditorMapSurvey:finishClassification()
  assert(not self.released and not self.classified, "survey classification already finished")
  self.classified = true
  if self.count > 0 then
    self.centroidX = self.sumX / self.count
    self.centroidZ = self.sumZ / self.count
  end
end

---@param cells { x: integer, z: integer }[] ordered logical map cells
---@param maxTilePositions integer
---@return integer consumed, boolean complete
function SaveEditorMapSurvey:advanceSelection(cells, maxTilePositions)
  assert(not self.released and self.classified, "survey classification is not complete")
  assert(type(maxTilePositions) == "number" and maxTilePositions >= 0 and maxTilePositions % 1 == 0)
  local consumed = 0
  while consumed < maxTilePositions and self.scanCell < #cells do
    local cell = cells[self.scanCell + 1]
    local tile = self.scanIndex
    local localX, localZ = tile % TILE_SIZE, math.floor(tile / TILE_SIZE)
    local mask = self.masks[tostring(cell.x) .. ":" .. tostring(cell.z)]
    if mask ~= nil then
      local bits = mask.rows[localZ + 1]
      local bit = 2 ^ localX
      if math.floor(bits / bit) % 2 == 1 then
        local fieldX, fieldZ = cell.x * TILE_SIZE + localX, cell.z * TILE_SIZE + localZ
        local dx, dz = fieldX - self.centroidX, fieldZ - self.centroidZ
        local distance = dx * dx + dz * dz
        if
          self.bestDistance == nil
          or distance < self.bestDistance
          or (distance == self.bestDistance and (fieldZ < self.bestZ or (fieldZ == self.bestZ and fieldX < self.bestX)))
        then
          self.bestX, self.bestZ, self.bestDistance = fieldX, fieldZ, distance
        end
      end
    end
    consumed = consumed + 1
    self.scanIndex = self.scanIndex + 1
    if self.scanIndex == TILE_SIZE * TILE_SIZE then
      self.scanIndex = 0
      self.scanCell = self.scanCell + 1
    end
  end
  self.complete = self.scanCell == #cells
  return consumed, self.complete
end

---@return { fieldX: integer, fieldZ: integer, validTileCount: integer }?
function SaveEditorMapSurvey:takeResult()
  assert(not self.released and self.complete, "survey result is not ready")
  assert(not self.taken, "survey result was already transferred")
  self.taken = true
  if self.count == 0 then
    return nil
  end
  return { fieldX = assert(self.bestX), fieldZ = assert(self.bestZ), validTileCount = self.count }
end

function SaveEditorMapSurvey:release()
  if self.released then
    return
  end
  self.released = true
  self.masks = {}
end

return SaveEditorMapSurvey
