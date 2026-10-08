-- Owns headless map and physical coverage reads for the save editor.

local Errors = require("libs.errors.src.Errors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local FieldZoneIdentity = require("libs.hgss.src.world.FieldZoneIdentity")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local SaveEditorLocationPolicy = require("app.src.saveeditor.SaveEditorLocationPolicy")
local SaveEditorMapSurvey = require("app.src.saveeditor.SaveEditorMapSurvey")

---@class SaveEditorStructuralMapRecord
---@field id integer
---@field symbol string
---@field mapSection string
---@field mapSectionNativeId integer
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

---@class SaveEditorFieldEvents
---@field objects table[]
---@field warps table[]
---@field coordinates table[]

---@class SaveEditorLocationMetadata
---@field currentMap RuntimeFieldMap|LogicalFieldMap?
---@field ownsCurrentMap boolean
---@field events SaveEditorFieldEvents?
---@field [string] unknown

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
---@field mapId integer?
---@field runtimeMap RuntimeFieldMap?
---@field coverage FieldCoverage?
---@field candidateCoverage FieldCoverage?
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
---@field ambiguousObjectIds table<integer, table<integer, boolean>>?
---@field warpEvents table[]?
---@field coordinateEvents table[]?
---@field metadata SaveEditorLocationMetadata?
---@field metadataReady boolean
---@field metadataTask FieldMapLoader.LogicalMetadataTask?
---@field requestPurpose string
---@field initialCursor table<string, unknown>?
---@field rememberedCursor { fieldX: integer, fieldZ: integer }?
---@field survey SaveEditorMapSurvey?
---@field surveyCells { x: integer, z: integer }[]?
---@field surveyIndex integer
---@field surveyDomain FieldMapLoader.MapCellDomain?
---@field surveyDomainComplete boolean
---@field surveyResult { fieldX: integer, fieldZ: integer, validTileCount: integer }?
---@field factsRevision integer
---@field requestGeneration integer
local SaveEditorLocationService = {}
SaveEditorLocationService.__index = SaveEditorLocationService

local TILE_SIZE = 32
local MAX_VIEW_TILES = 64
local UPDATE_WORK_UNITS = 8
local METADATA_ITEMS_PER_UNIT = 128

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

---@class SaveEditorMapSummaryTask
---@field world SaveEditorStructuralWorld
---@field cursor integer
---@field summaries SaveEditorMapSummary[]
---@field complete boolean
---@field advance fun(self: SaveEditorMapSummaryTask, budget: integer): integer, boolean
---@field take fun(self: SaveEditorMapSummaryTask): SaveEditorMapSummary[]
---@param world SaveEditorStructuralWorld
---@return SaveEditorMapSummaryTask
local function newMapSummaryTask(world)
  local task = {
    world = world,
    cursor = 1,
    summaries = {},
    complete = false,
    advance = function(self, budget)
      assert(
        type(budget) == "number" and budget % 1 == 0 and budget >= 0,
        "map summary budget must be a non-negative integer"
      )
      local used = 0
      while used < budget and self.cursor <= #self.world.maps do
        local record = self.world.maps[self.cursor]
        self.summaries[#self.summaries + 1] = {
          mapId = record.id,
          symbol = record.symbol,
          section = record.mapSection,
          mapSectionNativeId = record.mapSectionNativeId,
          displayName = record.symbol:gsub("^MAP_", "", 1),
        }
        self.cursor = self.cursor + 1
        used = used + 1
      end
      self.complete = self.cursor > #self.world.maps
      return used, self.complete
    end,
    take = function(self)
      assert(self.complete, "map summaries are complete before publication")
      local summaries = self.summaries
      self.summaries = {}
      return summaries
    end,
  }
  return task
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

local function surveyRectangleDomain(bounds)
  local minX, maxX = math.floor(bounds.minX / TILE_SIZE), math.floor(bounds.maxX / TILE_SIZE)
  local minZ, maxZ = math.floor(bounds.minZ / TILE_SIZE), math.floor(bounds.maxZ / TILE_SIZE)
  local width = maxX - minX + 1
  local total = width * (maxZ - minZ + 1)
  local domain = { _minX = minX, _minZ = minZ, _width = width, _total = total, _index = 0 }
  function domain:advance(maxVisits)
    assert(finiteInteger(maxVisits) and maxVisits >= 0, "survey domain budget must be a non-negative integer")
    local visited, cells = 0, {}
    while visited < maxVisits and self._index < self._total do
      local index = self._index
      cells[#cells + 1] = {
        x = self._minX + index % self._width,
        z = self._minZ + math.floor(index / self._width),
      }
      self._index = index + 1
      visited = visited + 1
    end
    return visited, cells, self._index == self._total
  end
  return domain
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
    mapId = nil,
    runtimeMap = nil,
    coverage = nil,
    candidateCoverage = nil,
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
    metadata = nil,
    metadataReady = false,
    metadataTask = nil,
    requestPurpose = "browse",
    initialCursor = nil,
    rememberedCursor = nil,
    survey = nil,
    surveyCells = nil,
    surveyIndex = 1,
    surveyDomain = nil,
    surveyDomainComplete = false,
    surveyResult = nil,
    requestGeneration = 0,
    visibleClassificationTask = nil,
    rememberedClassificationTask = nil,
    surveyClassificationTask = nil,
    surveyValidationTask = nil,
    factsRevision = 0,
  }, SaveEditorLocationService)
end

-- Creates source summaries incrementally so callers can bound inventory reads.
function SaveEditorLocationService:newMapSummaryTask()
  assert(not self.disposed, "location service is disposed")
  return newMapSummaryTask(self.world)
end

-- Releases staged tasks and published grid resources after leaving
-- coordinate selection. Map selection memory stays in the controller, so
-- the next grid entry re-prepares through the staged boundary.
function SaveEditorLocationService:releaseGrid()
  assert(not self.disposed, "location service is disposed")
  self:_releaseMap()
  self:_invalidate()
  self.status = status("idle")
end

-- Disarms only the automatic cursor suggestion. The current viewport and any
-- selected save destination remain owned by their existing controllers.
function SaveEditorLocationService:cancelInitialSurvey()
  assert(not self.disposed, "location service is disposed")
  if self.survey then
    self.survey:release()
    self.survey = nil
  end
  self.surveyDomain = nil
  self.surveyDomainComplete = false
  self.surveyResult = nil
  self.rememberedClassificationTask = nil
  self.surveyClassificationTask = nil
  self.surveyValidationTask = nil
  self.surveyCells = nil
  if self.requestPurpose == "browse" and self.initialCursor and self.initialCursor.state == "pending" then
    self.initialCursor = {
      state = "canceled",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
    }
  end
end

function SaveEditorLocationService:_invalidate()
  self.generation = self.generation + 1
  self.tileStatuses = {}
  self.visibleClassificationTask = nil
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

function SaveEditorLocationService:_releaseMetadata(preservePublished)
  if self.metadataTask then
    self.metadataTask:release()
    self.metadataTask = nil
  end
  local metadata = self.metadata
  if metadata and metadata.currentMap and metadata.ownsCurrentMap then
    local currentMap = metadata.currentMap --[[@as LogicalFieldMap]]
    currentMap:release()
  end
  self.metadata = nil
  self.metadataReady = preservePublished == true
end

function SaveEditorLocationService:_discardCandidateCoverage()
  if self.metadata ~= nil and self.metadata.candidate then
    self:_releaseMetadata(self.coverage ~= nil and self.metadataReady)
  end
  local candidate = self.candidateCoverage
  self.candidateCoverage = nil
  if candidate ~= nil then
    candidate:release()
  end
end

function SaveEditorLocationService:_releaseMap()
  self:_releaseLoadTask()
  self:_releaseCoverageTask()
  self:_discardCandidateCoverage()
  self:_releaseMetadata()
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
  self.ambiguousObjectIds = nil
  self.warpEvents = nil
  self.coordinateEvents = nil
  if self.survey then
    self.survey:release()
    self.survey = nil
  end
  self.surveyCells = nil
  self.surveyDomain = nil
  self.surveyDomainComplete = false
  self.surveyResult = nil
  self.initialCursor = nil
  self.rememberedCursor = nil
  self.rememberedClassificationTask = nil
  self.surveyClassificationTask = nil
  self.surveyValidationTask = nil
  self.visibleClassificationTask = nil
end

function SaveEditorLocationService:_failRequest(err, allowReturnedText)
  if self.status.state == "failed" then
    return
  end
  local expected = Errors.is(err) or (allowReturnedText and type(err) == "string")

  local preservePublished = self.coverage ~= nil
    and self.mapBounds ~= nil
    and self.objectEvents ~= nil
    and self.warpEvents ~= nil
    and self.coordinateEvents ~= nil
    and self.representedMapIds ~= nil
  self:_releaseLoadTask()
  self:_releaseCoverageTask()
  if self.candidateCoverage ~= nil then
    self.metadataReady = preservePublished
    self:_discardCandidateCoverage()
  elseif self.metadata ~= nil then
    self:_releaseMetadata(preservePublished)
  end
  self:_discardInitialSurvey()
  self.rememberedCursor = nil
  self.rememberedClassificationTask = nil
  self.visibleClassificationTask = nil
  self.tileStatuses = {}
  if not expected then
    error(err, 0)
  end
  local reason = Errors.is(err) and Errors.format(err) or err
  self.status = status("failed", reason)
  if self.requestPurpose == "browse" then
    self.initialCursor = {
      state = "failed",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      reason = reason,
    }
  else
    self.initialCursor = nil
  end
end

---@param mapId integer
---@param request { purpose: "browse"|"verify", rememberedCursor: { fieldX: integer, fieldZ: integer }? }?
function SaveEditorLocationService:openMap(mapId, request)
  assert(not self.disposed, "location service is disposed")
  assertInteger("mapId", mapId)
  request = request or { purpose = "verify" }
  assert(request.purpose == "browse" or request.purpose == "verify", "location request purpose is invalid")
  if request.rememberedCursor ~= nil then
    assert(request.purpose == "browse", "remembered cursors are only valid for browse requests")
    assert(type(request.rememberedCursor) == "table", "remembered cursor is required")
    assertInteger("remembered cursor fieldX", request.rememberedCursor.fieldX)
    assertInteger("remembered cursor fieldZ", request.rememberedCursor.fieldZ)
  end
  local record = assert(recordById(self.world, mapId), "location browser map is not in the structural world")
  self.requestGeneration = self.requestGeneration + 1
  if self.mapId ~= mapId then
    self:_releaseMap()
    self.mapId = mapId
  else
    self:_discardCandidateCoverage()
  end
  self.centerX = record.worldOriginX + 16
  self.centerZ = record.worldOriginZ + 16
  self.status = status("pending")
  self.requestPurpose = request.purpose
  self.rememberedCursor = request.rememberedCursor and copy(request.rememberedCursor) or nil
  self.initialCursor = request.purpose == "browse"
      and {
        state = "pending",
        mapId = mapId,
        generation = self.requestGeneration,
        factsRevision = self.factsRevision + 1,
        fieldX = request.rememberedCursor and request.rememberedCursor.fieldX or nil,
        fieldZ = request.rememberedCursor and request.rememberedCursor.fieldZ or nil,
      }
    or nil
  self:_releaseMetadata()
  if self.survey then
    self.survey:release()
    self.survey = nil
  end
  self.surveyDomain = nil
  self.surveyDomainComplete = false
  self.surveyResult = nil
  self.rememberedClassificationTask = nil
  self.surveyClassificationTask = nil
  self.surveyValidationTask = nil
  self.factsRevision = self.factsRevision + 1
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

function SaveEditorLocationService:_collectRepresented(coverage, candidate)
  if self.metadata ~= nil or (self.metadataReady and not candidate) then
    return
  end
  coverage = coverage or self.coverage
  local idsSet = { [self.mapId] = true }
  local matrixMemberId = coverage ~= nil and assert(recordById(self.world, self.mapId).matrix.memberId) or nil
  self.metadata = {
    candidate = candidate == true,
    complete = false,
    ids = coverage == nil and { self.mapId } or nil,
    idsSet = idsSet,
    representedCount = 1,
    catalogIndex = 1,
    descriptorCursor = nil,
    descriptorCells = coverage ~= nil and assert(coverage.cells) or nil,
    mapIndex = 1,
    kindIndex = 1,
    eventIndex = 1,
    currentMap = nil,
    ownsCurrentMap = false,
    events = nil,
    objectEvents = {},
    objectEventIdentities = {},
    ambiguousObjectIds = {},
    warpEvents = {},
    coordinateEvents = {},
    matrixMemberId = matrixMemberId,
    matrixIndex = 1,
    matrices = coverage ~= nil and assert(coverage.index).matrices or nil,
    boundsDescriptors = nil,
    boundsIndex = 1,
    boundsPass = "owners",
    selectedExtent = nil,
    bounds = nil,
    phase = coverage ~= nil and "representedDescriptors" or "events",
  }
end

function SaveEditorLocationService:_advanceRepresented(maxWorkUnits)
  local metadata = assert(self.metadata)
  local consumed = 0
  while consumed < maxWorkUnits do
    if metadata.phase == "representedDescriptors" or metadata.phase == "representedCatalog" then
      local visited = 0
      while visited < METADATA_ITEMS_PER_UNIT do
        if metadata.phase == "representedDescriptors" then
          local cellKey, cell = next(assert(metadata.descriptorCells), metadata.descriptorCursor)
          if cellKey == nil then
            metadata.ids = {}
            metadata.phase = "representedCatalog"
          else
            metadata.descriptorCursor = cellKey
            visited = visited + 1
            local descriptor = assert(cell.descriptor, "committed coverage cells retain their descriptors")
            local header = assert(descriptor.mapHeaderId, "physical descriptor map header is required")
            if not FieldZoneIdentity.isPhysicalOnlyCell(header) and self.loader:definesMap(header) then
              if not metadata.idsSet[header] then
                metadata.idsSet[header] = true
                metadata.representedCount = metadata.representedCount + 1
              end
            end
          end
        elseif metadata.phase == "representedCatalog" then
          local maps = self.world.maps
          if metadata.catalogIndex > #maps then
            assert(
              #assert(metadata.ids) == metadata.representedCount,
              "structural catalog contains every represented map"
            )
            metadata.phase = "matrixSearch"
          else
            local mapId = maps[metadata.catalogIndex].id
            if metadata.idsSet[mapId] then
              local ids = assert(metadata.ids)
              ids[#ids + 1] = mapId
            end
            metadata.catalogIndex = metadata.catalogIndex + 1
            visited = visited + 1
          end
        else
          break
        end
      end
      consumed = consumed + 1
    elseif metadata.phase == "matrixSearch" then
      local matrices = assert(metadata.matrices)
      local stop = math.min(#matrices, metadata.matrixIndex + METADATA_ITEMS_PER_UNIT - 1)
      for index = metadata.matrixIndex, stop do
        local matrix = matrices[index]
        if matrix.matrixMemberId == metadata.matrixMemberId then
          metadata.boundsDescriptors = matrix.cells
          metadata.phase = "events"
          break
        end
      end
      metadata.matrixIndex = stop + 1
      consumed = consumed + 1
      if metadata.phase == "matrixSearch" and metadata.matrixIndex > #matrices then
        error("coverage matrix is missing from its validated index", 2)
      end
    elseif metadata.phase == "events" then
      if metadata.currentMap == nil then
        local representedMapId = metadata.ids[metadata.mapIndex]
        if representedMapId == nil then
          metadata.phase = "bounds"
        else
          if representedMapId == self.mapId then
            metadata.currentMap = self.runtimeMap
            metadata.ownsCurrentMap = false
            consumed = consumed + 1
          else
            if self.metadataTask == nil then
              self.metadataTask = self.loader:beginLogicalMetadata(representedMapId)
            end
            local task = assert(self.metadataTask, "logical metadata task is required")
            consumed = consumed + task:advance(1)
            if task:isReady() then
              metadata.currentMap = task:takeResult()
              self.metadataTask = nil
              metadata.ownsCurrentMap = true
            end
          end
          if metadata.currentMap ~= nil then
            ---@type SaveEditorFieldEvents
            local events = assert(metadata.currentMap.fieldData.events, "field map event collections are required")
            metadata.events = events
          end
          metadata.kindIndex = 1
          metadata.eventIndex = 1
        end
      else
        local sources = { metadata.events.objects, metadata.events.warps, metadata.events.coordinates }
        local targets = { metadata.objectEvents, metadata.warpEvents, metadata.coordinateEvents }
        local source = assert(sources[metadata.kindIndex], "field event collection is required")
        local target = targets[metadata.kindIndex]
        if metadata.eventIndex > #source then
          metadata.kindIndex = metadata.kindIndex + 1
          metadata.eventIndex = 1
          if metadata.kindIndex > 3 then
            if metadata.ownsCurrentMap then
              metadata.currentMap:release()
            end
            metadata.currentMap = nil
            metadata.ownsCurrentMap = false
            metadata.mapIndex = metadata.mapIndex + 1
          end
        else
          local copied = 0
          while metadata.eventIndex <= #source and copied < METADATA_ITEMS_PER_UNIT do
            local event = copy(source[metadata.eventIndex])
            local representedMapId = metadata.ids[metadata.mapIndex]
            event.mapId = representedMapId
            if metadata.kindIndex == 1 then
              local identities = metadata.objectEventIdentities[representedMapId]
              if identities == nil then
                identities = {}
                metadata.objectEventIdentities[representedMapId] = identities
              end
              local previous = identities[event.objectEventId]
              if previous == nil then
                identities[event.objectEventId] = event
                target[#target + 1] = event
              elseif
                previous.movementType ~= event.movementType
                or previous.x ~= event.x
                or previous.z ~= event.z
                or previous.xRange ~= event.xRange
                or previous.yRange ~= event.yRange
              then
                local ambiguous = metadata.ambiguousObjectIds[representedMapId]
                if ambiguous == nil then
                  ambiguous = {}
                  metadata.ambiguousObjectIds[representedMapId] = ambiguous
                end
                ambiguous[event.objectEventId] = true
              end
            else
              target[#target + 1] = event
            end
            metadata.eventIndex = metadata.eventIndex + 1
            copied = copied + 1
          end
          consumed = consumed + 1
          if metadata.eventIndex > #source then
            metadata.kindIndex = metadata.kindIndex + 1
            metadata.eventIndex = 1
            if metadata.kindIndex > 3 then
              if metadata.ownsCurrentMap then
                metadata.currentMap:release()
              end
              metadata.currentMap = nil
              metadata.ownsCurrentMap = false
              metadata.mapIndex = metadata.mapIndex + 1
            end
          end
        end
      end
    elseif metadata.phase == "bounds" then
      if metadata.boundsDescriptors == nil then
        metadata.bounds = indoorBounds(self.runtimeMap)
        metadata.phase = "publish"
        consumed = consumed + 1
      elseif metadata.boundsIndex > #metadata.boundsDescriptors and metadata.boundsPass == "owners" then
        assert(metadata.selectedExtent, "selected logical map has no indexed physical cells")
        metadata.boundsPass = "filler"
        metadata.boundsIndex = 1
        consumed = consumed + 1
      elseif metadata.boundsIndex <= #metadata.boundsDescriptors then
        local stop = math.min(#metadata.boundsDescriptors, metadata.boundsIndex + METADATA_ITEMS_PER_UNIT - 1)
        for index = metadata.boundsIndex, stop do
          local descriptor = metadata.boundsDescriptors[index]
          local header = assert(descriptor.mapHeaderId, "indexed physical cells carry their map header")
          local isFiller = FieldZoneIdentity.isPhysicalOnlyCell(header)
          local inSelectedExtent = false
          if metadata.boundsPass == "filler" and isFiller then
            local extent = assert(metadata.selectedExtent)
            inSelectedExtent = descriptor.x >= extent.minX
              and descriptor.x <= extent.maxX
              and descriptor.z >= extent.minZ
              and descriptor.z <= extent.maxZ
          end
          local includeNamedMap = metadata.boundsPass == "owners"
            and metadata.idsSet[header]
            and (header == self.mapId or not isFiller)
          if includeNamedMap or inSelectedExtent then
            if metadata.boundsPass == "owners" and header == self.mapId then
              local extent = metadata.selectedExtent
              if extent == nil then
                metadata.selectedExtent =
                  { minX = descriptor.x, maxX = descriptor.x, minZ = descriptor.z, maxZ = descriptor.z }
              else
                extent.minX, extent.maxX = math.min(extent.minX, descriptor.x), math.max(extent.maxX, descriptor.x)
                extent.minZ, extent.maxZ = math.min(extent.minZ, descriptor.z), math.max(extent.maxZ, descriptor.z)
              end
            end
            local x, z = descriptor.x * TILE_SIZE, descriptor.z * TILE_SIZE
            local bounds = metadata.bounds
            if bounds == nil then
              metadata.bounds = { minX = x, maxX = x + 31, minZ = z, maxZ = z + 31 }
            else
              bounds.minX, bounds.maxX = math.min(bounds.minX, x), math.max(bounds.maxX, x + 31)
              bounds.minZ, bounds.maxZ = math.min(bounds.minZ, z), math.max(bounds.maxZ, z + 31)
            end
          end
        end
        metadata.boundsIndex = stop + 1
        consumed = consumed + 1
      else
        assert(metadata.bounds, "represented logical maps have no indexed physical cells")
        metadata.phase = "publish"
      end
    elseif metadata.phase == "publish" then
      if metadata.candidate then
        metadata.phase = "complete"
        metadata.complete = true
        return consumed + 1, true
      end
      self.objectEvents = metadata.objectEvents
      self.ambiguousObjectIds = metadata.ambiguousObjectIds
      self.warpEvents = metadata.warpEvents
      self.coordinateEvents = metadata.coordinateEvents
      self.representedMapIds = metadata.idsSet
      self.mapBounds = metadata.bounds
      self.metadata = nil
      self.metadataReady = true
      return consumed + 1, true
    elseif metadata.phase == "complete" then
      return consumed, true
    end
  end
  return consumed, false
end

function SaveEditorLocationService:_failStaged(err)
  self:_failRequest(err)
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
  self:_failRequest(err)
end

function SaveEditorLocationService:_publishCandidateCoverage()
  local candidate = assert(self.candidateCoverage, "candidate coverage is required")
  local metadata = assert(self.metadata, "candidate metadata is required")
  assert(metadata.candidate and metadata.complete, "candidate coverage publishes with complete metadata")
  local previous = self.coverage
  self.coverage = candidate
  self.candidateCoverage = nil
  self.objectEvents = metadata.objectEvents
  self.ambiguousObjectIds = metadata.ambiguousObjectIds
  self.warpEvents = metadata.warpEvents
  self.coordinateEvents = metadata.coordinateEvents
  self.representedMapIds = metadata.idsSet
  self.mapBounds = metadata.bounds
  self.metadata = nil
  self.metadataReady = true
  self:_invalidate()
  if previous ~= nil then
    previous:release()
  end
end

-- Whether the requested outdoor position still needs staged coverage work:
-- a pending replacement task, a missing window, or a window anchored
-- elsewhere. A settled window on the requested anchor needs no work.
function SaveEditorLocationService:_needsCoverageFor(fieldX, fieldZ)
  local runtimeMap = self.runtimeMap
  if runtimeMap == nil or runtimeMap.scene.type ~= "outdoor" then
    return false
  end
  if self.coverageTask ~= nil or self.candidateCoverage ~= nil then
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
  if self.candidateCoverage ~= nil then
    if self.candidateCoverage.anchorX == anchorX and self.candidateCoverage.anchorZ == anchorZ then
      return 0, true
    end
    self:_discardCandidateCoverage()
  end
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
  self.candidateCoverage = candidateOrError
  self:_releaseCoverageTask()
  return consumed, true
end

function SaveEditorLocationService:_prepareAt(fieldX, fieldZ)
  -- Destination map assets first: this enrolls only the destination
  -- field/logical demand, so first-use cell-index acquisition stays inside
  -- the staged map driver below instead of running outside the budget.
  local assetsReady, assetsError = self.loader:requestMapAssets(self.mapId, "required")
  if assetsError ~= nil then
    self:_failRequest(assetsError, true)
    return false, 0
  end
  if not assetsReady then
    self.status = status("pending")
    return false, 0
  end

  local remaining = UPDATE_WORK_UNITS
  local function pending()
    return false, UPDATE_WORK_UNITS - remaining
  end

  if self.runtimeMap == nil then
    local consumed, mapReady = self:_advanceStagedMap(remaining)
    remaining = remaining - consumed
    if not mapReady then
      return pending()
    end
  end

  -- The full location closure only runs once the staged map published:
  -- outdoor index acquisition already happened under the map budget, and a
  -- pending closure below returns without spending coverage work.
  local ready, err = self.loader:requestLocation(self.mapId, fieldX, fieldZ, "required")
  if err ~= nil then
    self:_failRequest(err, true)
    return pending()
  end
  if not ready then
    self.status = status("pending")
    return pending()
  end

  local coverageReady = true
  if self.runtimeMap.scene.type == "outdoor" and self.survey == nil then
    -- Do not begin/advance coverage after the budget is exhausted.
    if remaining == 0 and self:_needsCoverageFor(fieldX, fieldZ) then
      self.status = status("pending")
      return pending()
    end
    local consumed, isReady = self:_advanceStagedCoverage(fieldX, fieldZ, remaining)
    remaining = remaining - consumed
    coverageReady = isReady
    if self.status.state == "failed" then
      return pending()
    end
  elseif self.runtimeMap.scene.type ~= "outdoor" and self.coverage ~= nil then
    self:_releaseCoverage()
    self.metadata = nil
    self.mapBounds = nil
  end
  local prepared, metadataCompleteOrError = pcall(function()
    local candidate = self.candidateCoverage ~= nil
    local mayPrepareCurrentMetadata = self.runtimeMap.scene.type ~= "outdoor"
      or (
        self.coverage ~= nil
        and self.coverage.anchorX == math.floor(fieldX / TILE_SIZE)
        and self.coverage.anchorZ == math.floor(fieldZ / TILE_SIZE)
      )
    if candidate then
      self:_collectRepresented(self.candidateCoverage, true)
    elseif mayPrepareCurrentMetadata then
      self:_collectRepresented(self.coverage)
    end
    if self.metadata ~= nil and remaining > 0 then
      local consumed, complete = self:_advanceRepresented(remaining)
      remaining = remaining - consumed
      if not complete then
        self.status = status("pending")
        return false
      end
    end
    if candidate then
      return self.metadata ~= nil and self.metadata.complete
    end
    return self.metadata == nil and self.metadataReady
  end)
  if not prepared then
    if self.candidateCoverage ~= nil then
      self:_discardCandidateCoverage()
    else
      self:_releaseMetadata()
    end
    if not Errors.is(metadataCompleteOrError) then
      error(metadataCompleteOrError, 0)
    end
    self:_failRequest(metadataCompleteOrError)
    return pending()
  end
  if not metadataCompleteOrError then
    self.status = status("pending")
    return pending()
  end
  if not coverageReady then
    self.status = status("pending")
    return pending()
  end
  if self.candidateCoverage ~= nil then
    self:_publishCandidateCoverage()
  end
  if
    self.requestPurpose == "browse"
    and self.initialCursor
    and self.initialCursor.state == "pending"
    and self.rememberedCursor ~= nil
  then
    if remaining == 0 then
      self.status = status("pending")
      return pending()
    end
    local cursor = assert(self.rememberedCursor, "pending remembered cursor is retained for point preparation")
    local task = self.rememberedClassificationTask
    if task == nil then
      task = self:_beginTileClassification(cursor.fieldX, cursor.fieldZ)
      self.rememberedClassificationTask = task
    end
    local _, result = self:_advanceTileClassification(task, METADATA_ITEMS_PER_UNIT)
    remaining = remaining - 1
    if result == nil then
      self.status = status("pending")
      return pending()
    end
    self.rememberedClassificationTask = nil
    self.initialCursor = {
      state = result.selectable and "ready" or "unavailable",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      fieldX = result.selectable and cursor.fieldX or nil,
      fieldZ = result.selectable and cursor.fieldZ or nil,
      reason = result.selectable and nil or result.reason,
    }
    self.rememberedCursor = nil
    if self.runtimeMap.scene.type == "outdoor" and self:_needsCoverageFor(self.centerX, self.centerZ) then
      self.status = status("pending")
      return pending()
    end
  end
  if self.requestPurpose == "browse" and self.initialCursor and self.initialCursor.state == "pending" then
    if self.survey == nil then
      self:_beginInitialSurvey()
    end
    if remaining > 0 then
      local consumed, complete = self:_advanceInitialSurvey(remaining)
      remaining = remaining - consumed
      if self.status.state == "failed" then
        return pending()
      end
      if not complete then
        self.status = status("pending")
        return pending()
      end
    else
      self.status = status("pending")
      return pending()
    end
  end
  self.status = status("ready")
  return true, UPDATE_WORK_UNITS - remaining
end

function SaveEditorLocationService:_releaseCoverage()
  self:_releaseCoverageTask()
  self:_discardCandidateCoverage()
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
    trigger = false,
    mapBounds = self.mapBounds,
    representedMapIds = self.representedMapIds,
    savedActors = self.savedActors,
    ambiguousSourceActor = self.ambiguousObjectIds ~= nil and self.ambiguousObjectIds[self.mapId] ~= nil,
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
  if not self.coverage then
    local origin = assert(physicalMap.coordinateOrigin, "indoor map coordinate origin is required")
    if not physicalMap.collision:containsLocal(fieldX - origin.x, fieldZ - origin.z) then
      return facts
    end
  end
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
  local task = self:_beginTileClassification(fieldX, fieldZ)
  while true do
    local _, result = self:_advanceTileClassification(task, 4096)
    if result ~= nil then
      return result
    end
  end
end

function SaveEditorLocationService:_beginTileClassification(fieldX, fieldZ)
  local facts = self:_tileFacts(fieldX, fieldZ)
  facts.events = self.objectEvents or {}
  facts.savedActors = self.savedActors
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    facts = facts,
    phase = "warps",
    eventIndex = 1,
    policyTask = nil,
  }
end

function SaveEditorLocationService:_advanceTileClassification(task, maxVisits)
  assert(finiteInteger(maxVisits) and maxVisits >= 0, "tile classification budget must be non-negative")
  local visits = 0
  while true do
    if task.phase == "warps" then
      local event = (self.warpEvents or {})[task.eventIndex]
      if event == nil then
        task.phase = "coordinates"
        task.eventIndex = 1
      else
        if visits >= maxVisits then
          return visits, nil
        end
        if task.fieldX == event.x and task.fieldZ == event.z then
          task.facts.trigger = "warp"
          task.phase = "policy"
        else
          task.eventIndex = task.eventIndex + 1
        end
        visits = visits + 1
      end
    elseif task.phase == "coordinates" then
      local event = (self.coordinateEvents or {})[task.eventIndex]
      if event == nil then
        task.phase = "policy"
      else
        if visits >= maxVisits then
          return visits, nil
        end
        if
          task.fieldX >= event.x
          and task.fieldX < event.x + event.width
          and task.fieldZ >= event.z
          and task.fieldZ < event.z + event.height
        then
          task.facts.trigger = "coordinate_trigger"
          task.phase = "policy"
        else
          task.eventIndex = task.eventIndex + 1
        end
        visits = visits + 1
      end
    elseif task.phase == "policy" then
      task.policyTask = task.policyTask or SaveEditorLocationPolicy.beginClassification(task.facts)
      local used, result = SaveEditorLocationPolicy.advanceClassification(task.policyTask, maxVisits - visits)
      visits = visits + used
      if result ~= nil then
        task.phase = "done"
        task.result = result
        return visits, result
      end
      if used == 0 and result == nil then
        return visits, nil
      end
    else
      return visits, assert(task.result)
    end
  end
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

function SaveEditorLocationService:_classifyVisible(maxWorkUnits)
  assert(finiteInteger(maxWorkUnits) and maxWorkUnits >= 0, "visible classification budget must be non-negative")
  local work = 0
  local tiles = self:_visibleTiles()
  local index = 1
  while work < maxWorkUnits do
    local unitVisits, unitTiles = 0, 0
    local incomplete = false
    while unitTiles < METADATA_ITEMS_PER_UNIT and index <= #tiles do
      local tile = tiles[index]
      index = index + 1
      local key = tileKey(tile.fieldX, tile.fieldZ)
      if self.tileStatuses[key] == nil then
        local task = self.visibleClassificationTask
        if task == nil or task.fieldX ~= tile.fieldX or task.fieldZ ~= tile.fieldZ then
          task = self:_beginTileClassification(tile.fieldX, tile.fieldZ)
          self.visibleClassificationTask = task
        end
        local visits, result = self:_advanceTileClassification(task, METADATA_ITEMS_PER_UNIT - unitVisits)
        unitVisits = unitVisits + visits
        unitTiles = unitTiles + 1
        if result == nil then
          incomplete = true
          break
        end
        if result.selectable then
          self.tileStatuses[key] = { state = "selectable", selectable = true }
        else
          self.tileStatuses[key] = { state = "unavailable", selectable = false, reason = result.reason }
        end
        self.visibleClassificationTask = nil
      end
    end
    if unitTiles == 0 then
      break
    end
    work = work + 1
    if incomplete then
      break
    end
  end
  return work
end

function SaveEditorLocationService:_beginInitialSurvey()
  self.survey = SaveEditorMapSurvey.new()
  self.surveyCells = {}
  self.surveyIndex = 0
  local bounds = assert(self.mapBounds)
  if self.coverage ~= nil then
    self.surveyDomain = self.loader:mapCellDomain(self.mapId)
  else
    self.surveyDomain = surveyRectangleDomain(bounds)
  end
  self.surveyDomainComplete = false
  self.initialCursor = {
    state = "pending",
    mapId = self.mapId,
    generation = self.requestGeneration,
    factsRevision = self.factsRevision,
  }
end

function SaveEditorLocationService:_discardInitialSurvey()
  if self.survey ~= nil then
    self.survey:release()
    self.survey = nil
  end
  self.surveyCells = nil
  self.surveyIndex = 0
  self.surveyDomain = nil
  self.surveyDomainComplete = false
  self.surveyResult = nil
  self.surveyClassificationTask = nil
  self.surveyValidationTask = nil
end

function SaveEditorLocationService:_advanceInitialSurvey(maxWorkUnits)
  local survey = assert(self.survey)
  local cells = assert(self.surveyCells)
  local consumed = 0
  if not self.surveyDomainComplete then
    local domain = assert(self.surveyDomain, "browse survey requires its finite cell domain")
    local visited, discovered, done = domain:advance(maxWorkUnits * METADATA_ITEMS_PER_UNIT)
    for _, descriptor in ipairs(discovered) do
      cells[#cells + 1] = { x = descriptor.x, z = descriptor.z }
    end
    if visited > 0 then
      consumed = math.ceil(visited / METADATA_ITEMS_PER_UNIT)
    end
    if done then
      self.surveyDomain = nil
      self.surveyDomainComplete = true
    else
      return consumed, false
    end
  end
  while consumed < maxWorkUnits and self.surveyIndex < #cells * TILE_SIZE * TILE_SIZE do
    local currentCell = cells[math.floor(self.surveyIndex / (TILE_SIZE * TILE_SIZE)) + 1]
    if self.coverage ~= nil and self:_needsCoverageFor(currentCell.x * TILE_SIZE, currentCell.z * TILE_SIZE) then
      local closureReady, closureError =
        self.loader:requestLocation(self.mapId, currentCell.x * TILE_SIZE, currentCell.z * TILE_SIZE, "required")
      if closureError ~= nil then
        self:_failRequest(closureError, true)
        return consumed, false
      end
      if not closureReady then
        self.status = status("pending")
        return consumed, false
      end
      local coverageConsumed, coverageReady =
        self:_advanceStagedCoverage(currentCell.x * TILE_SIZE, currentCell.z * TILE_SIZE, maxWorkUnits - consumed)
      consumed = consumed + coverageConsumed
      if self.status.state == "failed" then
        return consumed, false
      end
      if not coverageReady or consumed >= maxWorkUnits then
        return consumed, false
      end
    end
    if self.candidateCoverage ~= nil then
      self:_collectRepresented(self.candidateCoverage, true)
      if consumed >= maxWorkUnits then
        return consumed, false
      end
      local metadataConsumed, metadataComplete = self:_advanceRepresented(maxWorkUnits - consumed)
      consumed = consumed + metadataConsumed
      if not metadataComplete then
        return consumed, false
      end
      self:_publishCandidateCoverage()
    end
    if self:_needsCoverageFor(currentCell.x * TILE_SIZE, currentCell.z * TILE_SIZE) then
      return consumed, false
    end
    local currentCellEnd = math.min(
      #cells * TILE_SIZE * TILE_SIZE,
      (math.floor(self.surveyIndex / (TILE_SIZE * TILE_SIZE)) + 1) * TILE_SIZE * TILE_SIZE
    )
    local unitVisits, unitTiles = 0, 0
    while unitTiles < METADATA_ITEMS_PER_UNIT and self.surveyIndex < currentCellEnd do
      local index = self.surveyIndex
      local cell = cells[math.floor(index / (TILE_SIZE * TILE_SIZE)) + 1]
      local localIndex = index % (TILE_SIZE * TILE_SIZE)
      local fieldX = cell.x * TILE_SIZE + localIndex % TILE_SIZE
      local fieldZ = cell.z * TILE_SIZE + math.floor(localIndex / TILE_SIZE)
      local bounds = assert(self.mapBounds)
      local classification = self.surveyClassificationTask
      if classification == nil then
        classification = self:_beginTileClassification(fieldX, fieldZ)
        self.surveyClassificationTask = classification
      end
      local visits, result = self:_advanceTileClassification(classification, METADATA_ITEMS_PER_UNIT - unitVisits)
      unitVisits = unitVisits + visits
      unitTiles = unitTiles + 1
      if result == nil then
        return consumed + 1, false
      end
      if fieldX >= bounds.minX and fieldX <= bounds.maxX and fieldZ >= bounds.minZ and fieldZ <= bounds.maxZ then
        survey:record(fieldX, fieldZ, result.selectable)
      end
      self.surveyClassificationTask = nil
      self.surveyIndex = index + 1
    end
    if unitTiles > 0 then
      consumed = consumed + 1
    end
  end
  if self.surveyIndex < #cells * TILE_SIZE * TILE_SIZE then
    return consumed, false
  end
  if not survey.classified then
    if consumed >= maxWorkUnits then
      return consumed, false
    end
    survey:finishClassification()
    consumed = consumed + 1
  end
  if not survey.complete then
    if consumed >= maxWorkUnits then
      return consumed, false
    end
    local visited, complete = survey:advanceSelection(cells, METADATA_ITEMS_PER_UNIT)
    if visited > 0 then
      consumed = consumed + 1
    end
    if not complete then
      return consumed, false
    end
  end
  if consumed >= maxWorkUnits then
    return consumed, false
  end
  if self.surveyResult == nil then
    self.surveyResult = survey:takeResult()
  end
  local result = self.surveyResult
  if result == nil then
    self.initialCursor = {
      state = "unavailable",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      validTileCount = 0,
      reason = "no_valid_tiles",
    }
  else
    if self:_needsCoverageFor(result.fieldX, result.fieldZ) then
      if consumed >= maxWorkUnits then
        return consumed, false
      end
      local coverageConsumed, coverageReady =
        self:_advanceStagedCoverage(result.fieldX, result.fieldZ, maxWorkUnits - consumed)
      consumed = consumed + coverageConsumed
      if self.status.state == "failed" then
        return consumed, false
      end
      if not coverageReady then
        return consumed, false
      end
    end
    if self.candidateCoverage ~= nil then
      local candidate = self.candidateCoverage
      local prepared, metadataCompleteOrError = pcall(function()
        self:_collectRepresented(candidate, true)
        if not self.metadata.complete and consumed < maxWorkUnits then
          local metadataConsumed, complete = self:_advanceRepresented(maxWorkUnits - consumed)
          consumed = consumed + metadataConsumed
          return complete
        end
        return self.metadata.complete
      end)
      if not prepared then
        self:_discardCandidateCoverage()
        if not Errors.is(metadataCompleteOrError) then
          error(metadataCompleteOrError, 0)
        end
        self:_failRequest(metadataCompleteOrError)
        return consumed, false
      end
      if not metadataCompleteOrError then
        self.status = status("pending")
        return consumed, false
      end
      self:_publishCandidateCoverage()
    end
    if self.runtimeMap.scene.type == "outdoor" then
      local anchorX, anchorZ = math.floor(result.fieldX / TILE_SIZE), math.floor(result.fieldZ / TILE_SIZE)
      assert(
        self.coverage ~= nil and self.coverage.anchorX == anchorX and self.coverage.anchorZ == anchorZ,
        "selected survey tile has published physical coverage"
      )
    end
    if consumed >= maxWorkUnits then
      return consumed, false
    end
    local task = self.surveyValidationTask
    if task == nil then
      task = self:_beginTileClassification(result.fieldX, result.fieldZ)
      self.surveyValidationTask = task
    end
    local _, confirmed = self:_advanceTileClassification(task, METADATA_ITEMS_PER_UNIT)
    consumed = consumed + 1
    if confirmed == nil then
      return consumed, false
    end
    self.surveyValidationTask = nil
    if not confirmed.selectable then
      self.initialCursor = {
        state = "unavailable",
        mapId = self.mapId,
        generation = self.requestGeneration,
        factsRevision = self.factsRevision,
        validTileCount = result.validTileCount,
        reason = confirmed.reason or "cursor_revalidation_failed",
      }
      survey:release()
      self.survey = nil
      return consumed, true
    end
    self.initialCursor = {
      state = "ready",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      fieldX = result.fieldX,
      fieldZ = result.fieldZ,
      validTileCount = result.validTileCount,
    }
    self.tileStatuses[tileKey(result.fieldX, result.fieldZ)] = {
      state = "selectable",
      selectable = true,
      fieldX = result.fieldX,
      fieldZ = result.fieldZ,
    }
  end
  survey:release()
  self.survey = nil
  self.surveyResult = nil
  return consumed + 1, true
end

function SaveEditorLocationService:update()
  assert(not self.disposed, "location service is disposed")
  if self.status.state == "failed" then
    return
  end
  if self.mapId == nil or self.centerX == nil or self.centerZ == nil then
    self.status = status("idle")
    return
  end
  local fieldX, fieldZ = self.centerX, self.centerZ
  if self.initialCursor ~= nil and self.initialCursor.state == "pending" and self.rememberedCursor ~= nil then
    fieldX, fieldZ = self.rememberedCursor.fieldX, self.rememberedCursor.fieldZ
  end
  local ok, readyOrError, consumed = pcall(self._prepareAt, self, fieldX, fieldZ)
  if not ok then
    self:_failRequest(readyOrError)
    return
  end
  if not readyOrError then
    self.tileStatuses = {}
    return
  end
  assert(finiteInteger(consumed) and consumed >= 0 and consumed <= UPDATE_WORK_UNITS)
  self:_classifyVisible(UPDATE_WORK_UNITS - consumed)
end

function SaveEditorLocationService:snapshot()
  assert(not self.disposed, "location service is disposed")
  if self.mapId == nil or self.centerX == nil or self.centerZ == nil then
    return {
      mapId = nil,
      map = nil,
      symbol = nil,
      generation = self.generation,
      status = status("idle"),
      tiles = {},
      initialCursor = nil,
    }
  end
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
    generation = self.generation,
    status = copy(self.status),
    tiles = tiles,
    initialCursor = copy(self.initialCursor),
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

  if self.status.state == "failed" then
    return nil, copy(self.status)
  end

  local requested, requestError = self.loader:requestLocation(mapId, fieldX, fieldZ, "required")
  if requestError ~= nil then
    self:_failRequest(requestError, true)
    return nil, copy(self.status)
  end
  if not requested then
    return nil, status("pending")
  end

  -- Resolution only observes preparation the update loop already published;
  -- it never starts or advances staged map/coverage work itself.
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
