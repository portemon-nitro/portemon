-- Owns headless map and physical coverage reads for the save editor.

local Errors = require("libs.errors.src.Errors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local FieldZoneIdentity = require("libs.hgss.src.world.FieldZoneIdentity")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local SaveEditorLocationPolicy = require("app.src.saveeditor.SaveEditorLocationPolicy")

---@class SaveEditorStructuralMapRecord
---@field id integer
---@field symbol string
---@field mapSection string
---@field worldOriginX integer
---@field worldOriginZ integer
---@field matrix { memberId: integer }

---@class SaveEditorStructuralWorld
---@field maps SaveEditorStructuralMapRecord[]
---@field byId table<integer, integer>
---@field [string] unknown

---@class SaveEditorSavedActor
---@field actorId string
---@field mapId integer
---@field objectEventId integer
---@field sourceMovementType string
---@field movementType string
---@field fieldX integer
---@field fieldZ integer
---@field action unknown?

---@class SaveEditorLocationBounds
---@field minX integer
---@field maxX integer
---@field minZ integer
---@field maxZ integer

---@class SaveEditorLocationStatus
---@field state string
---@field reason string?

---@class SaveEditorTileStatus: SaveEditorLocationStatus
---@field selectable boolean?
---@field fieldX integer?
---@field fieldZ integer?

---@class SaveEditorLocationOptions
---@field cacheFs CacheFs
---@field world SaveEditorStructuralWorld
---@field derivedAssets SaveEditorDerivedAssetHost
---@field savedObjects { actors: table<string, SaveEditorSavedActor> }

---@alias SaveEditorDerivedAssetHost table<string, function>

---@class SaveEditorLocationService
---@field world SaveEditorStructuralWorld
---@field derivedAssets SaveEditorDerivedAssetHost
---@field savedActors table[]
---@field loader FieldMapLoader
---@field loadTask FieldMapLoader.StagedTask?
---@field loadTaskMapId integer?
---@field coverageTask FieldCoverage.InitialTask?
---@field coverageTaskMapId integer?
---@field coverageTaskAnchorX integer?
---@field coverageTaskAnchorZ integer?
---@field maps table[]
---@field mapId integer?
---@field runtimeMap RuntimeFieldMap?
---@field coverage FieldCoverage?
---@field representedMapIds table<integer, boolean>?
---@field mapBounds SaveEditorLocationBounds?
---@field centerX integer?
---@field centerZ integer?
---@field widthTiles integer
---@field heightTiles integer
---@field generation integer
---@field tileStatuses table<string, SaveEditorTileStatus>
---@field status SaveEditorLocationStatus
---@field disposed boolean
---@field preparedMapId integer?
---@field objectEvents table[]?
---@field warpEvents table[]?
---@field coordinateEvents table[]?
local SaveEditorLocationService = {}
SaveEditorLocationService.__index = SaveEditorLocationService

local TILE_SIZE = 32
local MAX_VIEW_TILES = 64
local MAX_CLASSIFICATIONS_PER_UPDATE = 256
local LOAD_WORK_UNITS = 8

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[copy(key)] = copy(child)
  end
  return result
end

local function finiteInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

local function assertInteger(name, value)
  assert(finiteInteger(value), name .. " must be a finite integer")
end

local function tileKey(fieldX, fieldZ)
  return tostring(fieldX) .. ":" .. tostring(fieldZ)
end

local function status(state, reason)
  return { state = state, reason = reason }
end

local function recordById(world, mapId)
  local index = world.byId[mapId]
  return index and world.maps[index] or nil
end

local function mapList(world)
  local result = {}
  for _, record in ipairs(world.maps) do
    result[#result + 1] = {
      mapId = record.id,
      symbol = record.symbol,
      section = record.mapSection,
    }
  end
  table.sort(result, function(left, right)
    if left.section ~= right.section then
      return left.section < right.section
    end
    if left.symbol ~= right.symbol then
      return left.symbol < right.symbol
    end
    return left.mapId < right.mapId
  end)
  return result
end

local function savedActorList(savedObjects)
  local actors = {}
  for _, actor in pairs(savedObjects.actors) do
    actors[#actors + 1] = copy(actor)
  end
  table.sort(actors, function(left, right)
    if left.mapId == right.mapId then
      return left.objectEventId < right.objectEventId
    end
    return left.mapId < right.mapId
  end)
  return actors
end

local function mapBoundsFromCells(coverage, matrixMemberId, selectedMapId, representedMapIds)
  local index = assert(coverage.index, "coverage field-cell index is required")
  local selectedMatrix
  for _, matrix in ipairs(index.matrices) do
    if matrix.matrixMemberId == matrixMemberId then
      selectedMatrix = matrix
      break
    end
  end
  assert(selectedMatrix, "coverage matrix is missing from its validated index")

  local bounds
  for _, descriptor in ipairs(selectedMatrix.cells) do
    local fieldX = descriptor.x * TILE_SIZE
    local fieldZ = descriptor.z * TILE_SIZE
    local logicalMapId = FieldZoneIdentity.logicalZoneAt(coverage, fieldX, fieldZ, selectedMapId)
    if representedMapIds[logicalMapId] then
      local cellBounds = {
        minX = fieldX,
        maxX = fieldX + TILE_SIZE - 1,
        minZ = fieldZ,
        maxZ = fieldZ + TILE_SIZE - 1,
      }
      if bounds == nil then
        bounds = cellBounds
      else
        bounds.minX = math.min(bounds.minX, cellBounds.minX)
        bounds.maxX = math.max(bounds.maxX, cellBounds.maxX)
        bounds.minZ = math.min(bounds.minZ, cellBounds.minZ)
        bounds.maxZ = math.max(bounds.maxZ, cellBounds.maxZ)
      end
    end
  end
  return assert(bounds, "represented logical maps have no indexed physical cells")
end

local function indoorBounds(runtimeMap)
  local cells = assert(runtimeMap.fieldRegion and runtimeMap.fieldRegion.cells, "indoor field region is required")
  local centralCell = assert(cells[1], "indoor field region central cell is required")
  local collision = assert(centralCell.collision, "indoor central collision grid is required")
  local origin = assert(runtimeMap.coordinateOrigin, "indoor map coordinate origin is required")
  return {
    minX = origin.x,
    maxX = origin.x + collision.width - 1,
    minZ = origin.z,
    maxZ = origin.z + collision.height - 1,
  }
end

local function appendEvents(target, source, mapId)
  for _, event in ipairs(source) do
    local copied = copy(event)
    copied.mapId = mapId
    target[#target + 1] = copied
  end
end

local function representedMapIds(coverage, mapId, loader)
  local ids = { [mapId] = true }
  if coverage == nil then
    return { mapId }
  end
  for _, descriptor in ipairs(coverage:committedDescriptors()) do
    local header = assert(descriptor.mapHeaderId, "physical descriptor map header is required")
    if not FieldZoneIdentity.isPhysicalOnlyCell(header) and loader:definesMap(header) then
      ids[header] = true
    end
  end
  local result = {}
  for id in pairs(ids) do
    result[#result + 1] = id
  end
  table.sort(result)
  return result
end

local function coordinateTrigger(warps, coordinates, fieldX, fieldZ)
  for _, event in ipairs(warps) do
    if fieldX == event.x and fieldZ == event.z then
      return "warp"
    end
  end
  for _, event in ipairs(coordinates) do
    if
      fieldX >= event.x
      and fieldX < event.x + event.width
      and fieldZ >= event.z
      and fieldZ < event.z + event.height
    then
      return "coordinate_trigger"
    end
  end
  return false
end

---@param options SaveEditorLocationOptions
---@return SaveEditorLocationService
function SaveEditorLocationService.new(options)
  assert(type(options) == "table", "location service options are required")
  assert(options.cacheFs and options.cacheFs.loadLua, "location service needs a cache filesystem")
  assert(type(options.world) == "table", "location service needs a structural world")
  assert(type(options.derivedAssets) == "table", "location service needs the borrowed derived-asset host")
  assert(
    type(options.savedObjects) == "table" and type(options.savedObjects.actors) == "table",
    "saved actors are required"
  )

  return setmetatable({
    world = options.world,
    derivedAssets = options.derivedAssets,
    savedActors = savedActorList(options.savedObjects),
    loader = FieldMapLoader.new(options.cacheFs, options.world, { derivedAssets = options.derivedAssets }),
    loadTask = nil,
    loadTaskMapId = nil,
    coverageTask = nil,
    coverageTaskMapId = nil,
    coverageTaskAnchorX = nil,
    coverageTaskAnchorZ = nil,
    maps = mapList(options.world),
    mapId = nil,
    runtimeMap = nil,
    coverage = nil,
    mapBounds = nil,
    representedMapIds = nil,
    centerX = nil,
    centerZ = nil,
    widthTiles = 1,
    heightTiles = 1,
    generation = 0,
    tileStatuses = {},
    status = status("idle"),
    disposed = false,
    preparedMapId = nil,
  }, SaveEditorLocationService)
end

function SaveEditorLocationService:listMaps()
  assert(not self.disposed, "location service is disposed")
  return copy(self.maps)
end

function SaveEditorLocationService:_invalidate()
  self.generation = self.generation + 1
  self.tileStatuses = {}
end

function SaveEditorLocationService:_releaseLoadTask()
  local task = self.loadTask
  self.loadTask = nil
  self.loadTaskMapId = nil
  if task ~= nil then
    task:release()
  end
end

function SaveEditorLocationService:_releaseCoverageTask()
  local task = self.coverageTask
  self.coverageTask = nil
  self.coverageTaskMapId = nil
  self.coverageTaskAnchorX = nil
  self.coverageTaskAnchorZ = nil
  if task ~= nil then
    task:release()
  end
end

function SaveEditorLocationService:_releaseMap()
  self:_releaseLoadTask()
  self:_releaseCoverageTask()
  if self.coverage then
    self.coverage:release()
    self.coverage = nil
  end
  if self.preparedMapId then
    self.loader:protectMap(self.preparedMapId, false)
    self.preparedMapId = nil
  end
  self.runtimeMap = nil
  self.mapBounds = nil
  self.representedMapIds = nil
  self.objectEvents = nil
  self.warpEvents = nil
  self.coordinateEvents = nil
end

function SaveEditorLocationService:openMap(mapId)
  assert(not self.disposed, "location service is disposed")
  assertInteger("mapId", mapId)
  local record = assert(recordById(self.world, mapId), "location browser map is not in the structural world")
  if self.mapId ~= mapId then
    self:_releaseMap()
    self.mapId = mapId
  end
  self.centerX = record.worldOriginX + 16
  self.centerZ = record.worldOriginZ + 16
  self.status = status("pending")
  self:_invalidate()
end

function SaveEditorLocationService:setViewport(centerX, centerZ, widthTiles, heightTiles)
  assert(not self.disposed, "location service is disposed")
  assertInteger("viewport centerX", centerX)
  assertInteger("viewport centerZ", centerZ)
  assertInteger("viewport widthTiles", widthTiles)
  assertInteger("viewport heightTiles", heightTiles)
  assert(widthTiles > 0 and heightTiles > 0, "location viewport dimensions must be positive")
  self.centerX = centerX
  self.centerZ = centerZ
  self.widthTiles = math.min(widthTiles, MAX_VIEW_TILES)
  self.heightTiles = math.min(heightTiles, MAX_VIEW_TILES)
  self:_invalidate()
end

function SaveEditorLocationService:_collectRepresented()
  local representedIds = representedMapIds(self.coverage, self.mapId, self.loader)
  local idsSet = {}
  for _, id in ipairs(representedIds) do
    idsSet[id] = true
  end

  local objectEvents = {}
  local warpEvents = {}
  local coordinateEvents = {}
  for _, representedMapId in ipairs(representedIds) do
    local map
    local ownsMap = false
    if representedMapId == self.mapId then
      map = self.runtimeMap
    else
      map = self.loader:loadLogical(representedMapId)
      ownsMap = true
    end
    local currentMap = assert(map, "represented logical map acquisition returned no map")
    local ok, err = pcall(function()
      local events = assert(currentMap.fieldData.events, "field map event collections are required")
      appendEvents(objectEvents, assert(events.objects), representedMapId)
      appendEvents(warpEvents, assert(events.warps), representedMapId)
      appendEvents(coordinateEvents, assert(events.coordinates), representedMapId)
    end)
    if ownsMap then
      currentMap:release()
    end
    if not ok then
      error(err, 0)
    end
  end

  if self.coverage then
    local matrix = assert(recordById(self.world, self.mapId).matrix)
    self.mapBounds = mapBoundsFromCells(self.coverage, matrix.memberId, self.mapId, idsSet)
  else
    self.mapBounds = indoorBounds(self.runtimeMap)
  end
  self.objectEvents = objectEvents
  self.representedMapIds = idsSet
  self.warpEvents = warpEvents
  self.coordinateEvents = coordinateEvents
end

function SaveEditorLocationService:_failStaged(err)
  self:_releaseLoadTask()
  self.objectEvents = nil
  self.warpEvents = nil
  self.coordinateEvents = nil
  self.representedMapIds = nil
  self.mapBounds = nil
  if not Errors.is(err) then
    error(err, 0)
  end
  self.status = status("failed", Errors.format(err))
end

-- Advances the outstanding staged map load under the caller's work budget
-- and publishes the runtime map once the loader task is ready. The pending
-- task is keyed by map identity only: viewport changes never restart it.
-- Returns the consumed work units and whether the runtime map is available.
function SaveEditorLocationService:_advanceStagedMap(maxWorkUnits)
  if self.loadTask ~= nil and self.loadTaskMapId ~= self.mapId then
    self:_releaseLoadTask()
  end
  if self.loadTask == nil then
    local begun, taskOrError = pcall(self.loader.beginLoad, self.loader, self.mapId)
    if not begun then
      self:_failStaged(taskOrError)
      return 0, false
    end
    self.loadTask = taskOrError
    self.loadTaskMapId = self.mapId
  end
  local task = assert(self.loadTask, "staged map task is required")
  local advanced, consumedOrError = pcall(task.advance, task, maxWorkUnits)
  if not advanced then
    self:_failStaged(consumedOrError)
    return 0, false
  end
  local consumed = assert(consumedOrError, "staged map advance returned no work-unit count")
  assert(
    finiteInteger(consumed) and consumed >= 0 and consumed <= maxWorkUnits,
    "staged map task consumed an invalid work-unit count"
  )
  if not task:isReady() then
    self.status = status("pending")
    return consumed, false
  end
  if self.loadTaskMapId ~= self.mapId then
    self:_releaseLoadTask()
    self.status = status("pending")
    return consumed, false
  end
  local taken, runtimeOrError = pcall(function()
    local runtime = task:takeResult()
    self.loader:protectMap(self.mapId, true)
    return runtime
  end)
  if not taken then
    self:_failStaged(runtimeOrError)
    return consumed, false
  end
  self.loadTask = nil
  self.loadTaskMapId = nil
  self.runtimeMap = runtimeOrError
  self.preparedMapId = self.mapId
  return consumed, true
end

function SaveEditorLocationService:_failCoverageTask(err)
  self:_releaseCoverageTask()
  if not Errors.is(err) then
    error(err, 0)
  end
  self.status = status("failed", Errors.format(err))
end

-- Whether the requested outdoor position still needs staged coverage work:
-- a pending replacement task, a missing window, or a window anchored
-- elsewhere. A settled window on the requested anchor needs no work.
function SaveEditorLocationService:_needsCoverageFor(fieldX, fieldZ)
  local runtimeMap = self.runtimeMap
  if runtimeMap == nil or runtimeMap.scene.type ~= "outdoor" then
    return false
  end
  if self.coverageTask ~= nil then
    return true
  end
  if self.coverage == nil then
    return true
  end
  local anchorX, anchorZ = math.floor(fieldX / TILE_SIZE), math.floor(fieldZ / TILE_SIZE)
  return self.coverage.anchorX ~= anchorX or self.coverage.anchorZ ~= anchorZ
end

-- Advances the one staged outdoor coverage replacement under the caller's
-- remaining work budget. The pending task is keyed by map plus physical
-- anchor; a settled window on the requested anchor is reused without new
-- work. Returns the consumed work units and whether the current window
-- matches the requested anchor.
function SaveEditorLocationService:_advanceStagedCoverage(fieldX, fieldZ, maxWorkUnits)
  local anchorX, anchorZ = math.floor(fieldX / TILE_SIZE), math.floor(fieldZ / TILE_SIZE)
  local runtimeMap = assert(self.runtimeMap, "staged coverage requires a prepared runtime map")
  if self.coverage ~= nil and self.coverage.anchorX == anchorX and self.coverage.anchorZ == anchorZ then
    self:_releaseCoverageTask()
    return 0, true
  end
  if
    self.coverageTask ~= nil
    and (
      self.coverageTaskMapId ~= self.mapId
      or self.coverageTaskAnchorX ~= anchorX
      or self.coverageTaskAnchorZ ~= anchorZ
    )
  then
    self:_releaseCoverageTask()
  end
  if self.coverageTask == nil then
    if maxWorkUnits <= 0 then
      self.status = status("pending")
      return 0, false
    end
    local begun, taskOrError =
      pcall(self.loader.beginPhysicalCoverage, self.loader, runtimeMap, { fieldX = fieldX, fieldZ = fieldZ })
    if not begun then
      self:_failCoverageTask(taskOrError)
      return 0, false
    end
    self.coverageTask = taskOrError
    self.coverageTaskMapId = self.mapId
    self.coverageTaskAnchorX = anchorX
    self.coverageTaskAnchorZ = anchorZ
  end
  local task = assert(self.coverageTask, "staged coverage task is required")
  local advanced, consumedOrError = pcall(task.advance, task, maxWorkUnits)
  if not advanced then
    self:_failCoverageTask(consumedOrError)
    return 0, false
  end
  local consumed = assert(consumedOrError, "staged coverage advance returned no work-unit count")
  assert(
    finiteInteger(consumed) and consumed >= 0 and consumed <= maxWorkUnits,
    "staged coverage task consumed an invalid work-unit count"
  )
  if not task:isReady() then
    self.status = status("pending")
    return consumed, false
  end
  if
    self.coverageTaskMapId ~= self.mapId
    or self.coverageTaskAnchorX ~= anchorX
    or self.coverageTaskAnchorZ ~= anchorZ
  then
    self:_releaseCoverageTask()
    self.status = status("pending")
    return consumed, false
  end
  local taken, candidateOrError = pcall(task.takeResult, task)
  if not taken then
    self:_failCoverageTask(candidateOrError)
    return consumed, false
  end
  local candidate = candidateOrError
  local previous = self.coverage
  self.coverage = candidate
  local published, metadataError = pcall(self._collectRepresented, self)
  if not published then
    self.coverage = previous
    self:_releaseCoverageTask()
    candidate:release()
    if not Errors.is(metadataError) then
      error(metadataError, 0)
    end
    self.status = status("failed", Errors.format(metadataError))
    return consumed, false
  end
  self:_releaseCoverageTask()
  if previous ~= nil then
    previous:release()
  end
  self:_invalidate()
  return consumed, true
end

function SaveEditorLocationService:_prepareAt(fieldX, fieldZ)
  -- Destination map assets first: this enrolls only the destination
  -- field/logical demand, so first-use cell-index acquisition stays inside
  -- the staged map driver below instead of running outside the budget.
  local assetsReady, assetsError = self.loader:requestMapAssets(self.mapId, "required")
  if assetsError ~= nil then
    self.status = status("failed", assetsError)
    return false
  end
  if not assetsReady then
    self.status = status("pending")
    return false
  end

  local remaining = LOAD_WORK_UNITS
  if self.runtimeMap == nil then
    local consumed, mapReady = self:_advanceStagedMap(remaining)
    remaining = remaining - consumed
    if not mapReady then
      return false
    end
  end

  -- The full location closure only runs once the staged map published:
  -- outdoor index acquisition already happened under the map budget, and a
  -- pending closure below returns without spending coverage work.
  local ready, err = self.loader:requestLocation(self.mapId, fieldX, fieldZ, "required")
  if err ~= nil then
    self.status = status("failed", err)
    return false
  end
  if not ready then
    self.status = status("pending")
    return false
  end

  if self.runtimeMap.scene.type == "outdoor" then
    -- Do not begin/advance coverage after the budget is exhausted.
    if remaining == 0 and self:_needsCoverageFor(fieldX, fieldZ) then
      self.status = status("pending")
      return false
    end
    local _, coverageReady = self:_advanceStagedCoverage(fieldX, fieldZ, remaining)
    if not coverageReady then
      return false
    end
  elseif self.coverage ~= nil or self.mapBounds == nil then
    local prepared, prepareError = pcall(function()
      self:_releaseCoverage()
      self:_collectRepresented()
    end)
    if not prepared then
      self.objectEvents = nil
      self.warpEvents = nil
      self.coordinateEvents = nil
      self.representedMapIds = nil
      self.mapBounds = nil
      if not Errors.is(prepareError) then
        error(prepareError, 0)
      end
      self.status = status("failed", Errors.format(prepareError))
      return false
    end
  end
  self.status = status("ready")
  return true
end

function SaveEditorLocationService:_releaseCoverage()
  self:_releaseCoverageTask()
  if self.coverage then
    self.coverage:release()
    self.coverage = nil
  end
end

function SaveEditorLocationService:_tileFacts(fieldX, fieldZ)
  local facts = {
    mapId = self.mapId,
    fieldX = fieldX,
    fieldZ = fieldZ,
    coverage = false,
    logicalMapMatch = false,
    collision = nil,
    surface = nil,
    trigger = coordinateTrigger(self.warpEvents or {}, self.coordinateEvents or {}, fieldX, fieldZ),
    mapBounds = self.mapBounds,
    representedMapIds = self.representedMapIds,
    savedActors = self.savedActors,
  }

  if fieldX < 0 or fieldX > 0xFFFF or fieldZ < 0 or fieldZ > 0xFFFF then
    return facts
  end

  local viewMap
  local terrain
  local terrainDependencyHash
  if self.coverage then
    if not self.coverage:containsGlobal(fieldX, fieldZ) then
      return facts
    end
    facts.logicalMapMatch = FieldZoneIdentity.logicalZoneAt(self.coverage, fieldX, fieldZ, self.mapId) == self.mapId
    local origin = self.coverage.origin
    viewMap = {
      collision = self.coverage.region.collision,
      coordinateOrigin = { x = origin.x, z = origin.z },
    }
    terrain = self.coverage.region.terrain
    terrainDependencyHash = self.coverage.terrainDependencyHash
  else
    viewMap = self.runtimeMap
    local bounds = assert(self.mapBounds, "indoor map bounds are required")
    facts.logicalMapMatch = fieldX >= bounds.minX
      and fieldX <= bounds.maxX
      and fieldZ >= bounds.minZ
      and fieldZ <= bounds.maxZ
    terrain = self.runtimeMap.terrain
    terrainDependencyHash = self.runtimeMap.terrainDependencyHash
  end

  local physicalMap = assert(viewMap, "physical map view is required")
  local localX, localZ = FieldCoordinates.fieldToLocal(physicalMap, fieldX, fieldZ)
  if not physicalMap.collision:containsLocal(localX, localZ) then
    return facts
  end
  facts.coverage = true
  facts.collision = physicalMap.collision:getLocal(localX, localZ)
  if not facts.coverage or not facts.logicalMapMatch then
    return facts
  end

  local ok, sampleOrError = pcall(function()
    return SurfaceResolver.new(terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    })
  end)
  if not ok then
    local err = sampleOrError
    if Errors.is(err) and err.code == FieldErrors.TERRAIN_SURFACE_AMBIGUOUS then
      facts.surface = { rejection = "ambiguous_surface" }
    elseif Errors.is(err) and err.code == FieldErrors.TERRAIN_SURFACE_NOT_FOUND then
      facts.surface = { rejection = "no_surface" }
    else
      error(err, 0)
    end
  else
    local sample = assert(sampleOrError)
    facts.surface = {
      surfaceId = sample.surfaceId,
      worldY = sample.worldY,
      terrainDependencyHash = terrainDependencyHash,
    }
  end
  return facts
end

function SaveEditorLocationService:_classify(fieldX, fieldZ)
  local facts = self:_tileFacts(fieldX, fieldZ)
  facts.events = self.objectEvents or {}
  facts.savedActors = self.savedActors
  return SaveEditorLocationPolicy.classify(facts)
end

function SaveEditorLocationService:_visibleTiles()
  local startX = self.centerX - math.floor(self.widthTiles / 2)
  local startZ = self.centerZ - math.floor(self.heightTiles / 2)
  local result = {}
  for row = 0, self.heightTiles - 1 do
    for column = 0, self.widthTiles - 1 do
      local fieldX, fieldZ = startX + column, startZ + row
      result[#result + 1] = { fieldX = fieldX, fieldZ = fieldZ }
    end
  end
  return result
end

function SaveEditorLocationService:_classifyVisible()
  local work = 0
  for _, tile in ipairs(self:_visibleTiles()) do
    local key = tileKey(tile.fieldX, tile.fieldZ)
    if self.tileStatuses[key] == nil then
      if work >= MAX_CLASSIFICATIONS_PER_UPDATE then
        break
      end
      local result = self:_classify(tile.fieldX, tile.fieldZ)
      if result.selectable then
        self.tileStatuses[key] = { state = "selectable", selectable = true }
      else
        self.tileStatuses[key] = {
          state = "unavailable",
          selectable = false,
          reason = result.reason,
        }
      end
      work = work + 1
    end
  end
end

function SaveEditorLocationService:update()
  assert(not self.disposed, "location service is disposed")
  if self.mapId == nil or self.centerX == nil or self.centerZ == nil then
    self.status = status("idle")
    return
  end
  local readyOrError = self:_prepareAt(self.centerX, self.centerZ)
  if not readyOrError then
    self.tileStatuses = {}
    return
  end
  self:_classifyVisible()
end

function SaveEditorLocationService:snapshot()
  assert(not self.disposed, "location service is disposed")
  local tiles = {}
  for _, tile in ipairs(self:_visibleTiles()) do
    local current = self.tileStatuses[tileKey(tile.fieldX, tile.fieldZ)]
    local copied = current and copy(current) or status("pending")
    copied.fieldX, copied.fieldZ = tile.fieldX, tile.fieldZ
    tiles[#tiles + 1] = copied
  end
  local record = self.mapId and recordById(self.world, self.mapId) or nil
  return {
    mapId = self.mapId,
    map = record and { mapId = record.id, symbol = record.symbol, section = record.mapSection } or nil,
    symbol = record and record.symbol or nil,
    maps = copy(self.maps),
    generation = self.generation,
    status = copy(self.status),
    tiles = tiles,
  }
end

function SaveEditorLocationService:tileStatus(fieldX, fieldZ)
  assert(not self.disposed, "location service is disposed")
  assertInteger("tile fieldX", fieldX)
  assertInteger("tile fieldZ", fieldZ)
  local tileStatus = self.tileStatuses[tileKey(fieldX, fieldZ)]
  return tileStatus and copy(tileStatus) or status("pending")
end

function SaveEditorLocationService:resolve(mapId, fieldX, fieldZ, expectedGeneration)
  assert(not self.disposed, "location service is disposed")
  assertInteger("mapId", mapId)
  assertInteger("fieldX", fieldX)
  assertInteger("fieldZ", fieldZ)
  assertInteger("expected generation", expectedGeneration)
  if expectedGeneration ~= self.generation then
    return nil, status("unavailable", "stale_generation")
  end
  if mapId ~= self.mapId then
    return nil, status("unavailable", "wrong_map")
  end

  local requested, requestError = self.loader:requestLocation(mapId, fieldX, fieldZ, "required")
  if requestError ~= nil then
    return nil, status("failed", requestError)
  end
  if not requested then
    return nil, status("pending")
  end

  -- Resolution only observes preparation the update loop already published;
  -- it never starts or advances staged map/coverage work itself.
  if self.status.state == "failed" then
    return nil, copy(self.status)
  end
  if self.runtimeMap == nil or self.loadTask ~= nil then
    return nil, status("pending")
  end
  if self.runtimeMap.scene.type == "outdoor" and (self.coverageTask ~= nil or self.coverage == nil) then
    return nil, status("pending")
  end
  if self.mapBounds == nil or self.objectEvents == nil then
    return nil, status("pending")
  end

  local result = self:_classify(fieldX, fieldZ)
  if not result.selectable then
    return nil, status("unavailable", result.reason)
  end
  local tileFacts = self:_tileFacts(fieldX, fieldZ)
  local placement = {
    mapId = self.mapId,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = tileFacts.surface.surfaceId,
    worldY = tileFacts.surface.worldY,
    terrainDependencyHash = tileFacts.surface.terrainDependencyHash,
  }
  return copy(placement), status("ready")
end

function SaveEditorLocationService:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.generation = self.generation + 1
  self.tileStatuses = {}
  self:_releaseMap()
  self.loader:release()
end

return SaveEditorLocationService
