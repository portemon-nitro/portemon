-- Owns headless map and physical coverage reads for the save editor.
--
-- An unfamiliar map first publishes a map-owned browsing seed taken from its
-- indexed physical descriptors (or its indoor collision bounds) and then
-- cooperatively looks for one nearby safe tile inside the already published
-- coverage. The seed is for browsing only; only explicit tile activation
-- stages a destination. Placement facts come from the selected map's own
-- events plus exact known actor positions.

local Errors = require("libs.errors.src.Errors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local FieldZoneIdentity = require("libs.hgss.src.world.FieldZoneIdentity")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local SaveEditorLocationPolicy = require("app.src.saveeditor.SaveEditorLocationPolicy")

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

---@class SaveEditorHintCell
---@field x integer
---@field z integer
---@field owned boolean

---@class SaveEditorLocationHint
---@field seedX integer
---@field seedZ integer
---@field cells SaveEditorHintCell[]
---@field done table<integer, boolean>
---@field waiting table<integer, boolean>
---@field skipped table<integer, boolean>
---@field pos table<integer, integer>
---@field inspected integer
---@field coverageSeen FieldCoverage|false?

---@class SaveEditorLocationService
---@field world SaveEditorStructuralWorld
---@field derivedAssets SaveEditorDerivedAssetHost
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
---@field actorOccupiedByMap table<integer, table<string, boolean>>
---@field occupiedSet table<string, boolean>?
---@field warpSet table<string, boolean>?
---@field resolver SurfaceResolver?
---@field resolverTerrain table<string, unknown>?
---@field requestPurpose string
---@field initialCursor table<string, unknown>?
---@field rememberedCursor { fieldX: integer, fieldZ: integer }?
---@field seedDomain FieldMapLoader.MapCellDomain?
---@field ownedCells { x: integer, z: integer, owned: boolean }[]?
---@field fillerCells { x: integer, z: integer, owned: boolean }[]?
---@field hint SaveEditorLocationHint?
---@field seedFresh boolean
---@field dirty boolean
---@field requestGeneration integer
---@field factsRevision integer
local SaveEditorLocationService = {}
SaveEditorLocationService.__index = SaveEditorLocationService

local TILE_SIZE = 32
local MAX_VIEW_TILES = 64
local UPDATE_WORK_UNITS = 8
local METADATA_ITEMS_PER_UNIT = 128
local MAX_HINT_CELLS = 8
local MAX_HINT_POSITIONS = 4096

-- Center-out tile offsets shared by every candidate cell: increasing squared
-- distance to the cell center with a deterministic (fieldZ, fieldX) tie-break.
local hintTileOrder = nil

local function centerOutTileOrder()
  if hintTileOrder ~= nil then
    return hintTileOrder
  end
  local decorated = {}
  for localZ = 0, TILE_SIZE - 1 do
    for localX = 0, TILE_SIZE - 1 do
      decorated[#decorated + 1] = {
        dx = localX,
        dz = localZ,
        distance = (localX - (TILE_SIZE - 1) / 2) ^ 2 + (localZ - (TILE_SIZE - 1) / 2) ^ 2,
      }
    end
  end
  table.sort(decorated, function(left, right)
    if left.distance == right.distance then
      if left.dz == right.dz then
        return left.dx < right.dx
      end
      return left.dz < right.dz
    end
    return left.distance < right.distance
  end)
  local order = {}
  for _, entry in ipairs(decorated) do
    order[#order + 1] = { dx = entry.dx, dz = entry.dz }
  end
  hintTileOrder = order
  return order
end

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

-- Indexes exact known actor positions by selected map. Saved-object content
-- stays defensive here: malformed points are skipped because save validation
-- belongs to the session owner, while browsing must never crash on them.
local function indexSavedActorPoints(savedObjects)
  local byMap = {}
  local actors = savedObjects.actors
  if type(actors) ~= "table" then
    return byMap
  end
  for _, actor in pairs(actors) do
    if
      type(actor) == "table"
      and finiteInteger(actor.mapId)
      and finiteInteger(actor.fieldX)
      and finiteInteger(actor.fieldZ)
    then
      local occupied = byMap[actor.mapId]
      if occupied == nil then
        occupied = {}
        byMap[actor.mapId] = occupied
      end
      occupied[tileKey(actor.fieldX, actor.fieldZ)] = true
      local action = actor.action
      if type(action) == "table" then
        for _, point in ipairs({ action.start, action.destination }) do
          if type(point) == "table" and finiteInteger(point.fieldX) and finiteInteger(point.fieldZ) then
            occupied[tileKey(point.fieldX, point.fieldZ)] = true
          end
        end
      end
    end
  end
  return byMap
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
    actorOccupiedByMap = indexSavedActorPoints(options.savedObjects),
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
    centerX = nil,
    centerZ = nil,
    widthTiles = 1,
    heightTiles = 1,
    generation = 0,
    tileStatuses = {},
    status = status("idle"),
    disposed = false,
    preparedMapId = nil,
    objectEvents = nil,
    warpEvents = nil,
    coordinateEvents = nil,
    occupiedSet = nil,
    warpSet = nil,
    resolver = nil,
    resolverTerrain = nil,
    requestPurpose = "browse",
    initialCursor = nil,
    rememberedCursor = nil,
    seedDomain = nil,
    ownedCells = nil,
    fillerCells = nil,
    hint = nil,
    seedFresh = false,
    dirty = false,
    requestGeneration = 0,
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
  self:_setStatus("idle")
end

-- Disarms only the automatic cursor suggestion. The current viewport and any
-- selected save destination remain owned by their existing controllers.
function SaveEditorLocationService:cancelInitialSuggestion()
  assert(not self.disposed, "location service is disposed")
  local active = self.initialCursor
  self:_discardHint()
  if
    self.requestPurpose == "browse"
    and active ~= nil
    and (active.state == "pending" or active.state == "seeded" or active.state == "ready")
  then
    self.initialCursor = {
      state = "canceled",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
    }
    self.dirty = true
  end
end

function SaveEditorLocationService:_setStatus(state, reason)
  local current = self.status
  if current.state == state and current.reason == reason then
    return
  end
  self.status = status(state, reason)
  self.dirty = true
end

function SaveEditorLocationService:_publishInitialCursor(cursor)
  self.initialCursor = cursor
  self.dirty = true
end

function SaveEditorLocationService:_invalidate()
  self.generation = self.generation + 1
  self.tileStatuses = {}
  self.dirty = true
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

function SaveEditorLocationService:_discardCandidateCoverage()
  local candidate = self.candidateCoverage
  self.candidateCoverage = nil
  if candidate ~= nil then
    candidate:release()
  end
end

function SaveEditorLocationService:_discardHint()
  self.seedDomain = nil
  self.ownedCells = nil
  self.fillerCells = nil
  self.hint = nil
  self.seedFresh = false
end

function SaveEditorLocationService:_releaseMap()
  self:_releaseLoadTask()
  self:_releaseCoverageTask()
  self:_discardCandidateCoverage()
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
  self.objectEvents = nil
  self.warpEvents = nil
  self.coordinateEvents = nil
  self.occupiedSet = nil
  self.warpSet = nil
  self.resolver = nil
  self.resolverTerrain = nil
  self:_discardHint()
  self.initialCursor = nil
  self.rememberedCursor = nil
end

function SaveEditorLocationService:_failRequest(err, allowReturnedText)
  if self.status.state == "failed" then
    return
  end
  local expected = Errors.is(err) or (allowReturnedText and type(err) == "string")

  self:_releaseLoadTask()
  self:_releaseCoverageTask()
  self:_discardCandidateCoverage()
  -- The published map window and its selected-map indexes stay owned: a
  -- failed replacement never takes the last known-good presentation down.
  self:_discardHint()
  self.rememberedCursor = nil
  self.tileStatuses = {}
  self.resolver = nil
  self.resolverTerrain = nil
  if not expected then
    error(err, 0)
  end
  local reason = Errors.is(err) and Errors.format(err) or err
  self:_setStatus("failed", reason)
  if self.requestPurpose == "browse" then
    self:_publishInitialCursor({
      state = "failed",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      reason = reason,
    })
  else
    self.initialCursor = nil
    self.dirty = true
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
  assert(recordById(self.world, mapId) ~= nil, "location browser map is not in the structural world")
  self.requestGeneration = self.requestGeneration + 1
  if self.mapId ~= mapId then
    self:_releaseMap()
    self.mapId = mapId
  else
    self:_discardCandidateCoverage()
  end
  -- An unfamiliar map starts without coordinates: the map-owned seed below
  -- replaces the old structural-origin guess instead of preparing against it.
  self.centerX = nil
  self.centerZ = nil
  self:_setStatus("pending")
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
  self:_discardHint()
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
    self:_setStatus("pending")
    return consumed, false
  end
  if self.loadTaskMapId ~= self.mapId then
    self:_releaseLoadTask()
    self:_setStatus("pending")
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

-- Builds the selected map's placement indexes once its staged map publishes.
-- Only this map's own source events participate; saved actors contribute
-- their exact known positions on this map. The borrowed event records stay
-- read-only: no deep copy, no neighboring map reads.
function SaveEditorLocationService:_initSelectedMap()
  if self.objectEvents ~= nil then
    return
  end
  local runtimeMap = assert(self.runtimeMap, "selected-map indexes require a published runtime map")
  local fieldData = assert(runtimeMap.fieldData, "field map data is required")
  local events = assert(fieldData.events, "field map event collections are required")
  local objects = events.objects or {}
  local warps = events.warps or {}
  local coordinates = events.coordinates or {}
  for _, event in ipairs(objects) do
    assertInteger("source object event x", event.x)
    assertInteger("source object event z", event.z)
  end
  for _, event in ipairs(warps) do
    assertInteger("source warp x", event.x)
    assertInteger("source warp z", event.z)
  end
  for _, event in ipairs(coordinates) do
    assertInteger("source coordinate trigger x", event.x)
    assertInteger("source coordinate trigger z", event.z)
    assertInteger("source coordinate trigger width", event.width)
    assertInteger("source coordinate trigger height", event.height)
  end
  self.objectEvents = objects
  self.warpEvents = warps
  self.coordinateEvents = coordinates
  local occupied = {}
  for _, event in ipairs(objects) do
    occupied[tileKey(event.x, event.z)] = true
  end
  for key in pairs(self.actorOccupiedByMap[self.mapId] or {}) do
    occupied[key] = true
  end
  self.occupiedSet = occupied
  local warpSet = {}
  for _, event in ipairs(warps) do
    warpSet[tileKey(event.x, event.z)] = true
  end
  self.warpSet = warpSet
  if runtimeMap.scene.type ~= "outdoor" then
    self.mapBounds = indoorBounds(runtimeMap)
  end
  self.dirty = true
end

function SaveEditorLocationService:_failCoverageTask(err)
  self:_failRequest(err)
end

function SaveEditorLocationService:_publishCandidateCoverage()
  local candidate = assert(self.candidateCoverage, "candidate coverage is required")
  self.candidateCoverage = nil
  local previous = self.coverage
  self.coverage = candidate
  self.resolver = nil
  self.resolverTerrain = nil
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
      self:_setStatus("pending")
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
    self:_setStatus("pending")
    return consumed, false
  end
  if
    self.coverageTaskMapId ~= self.mapId
    or self.coverageTaskAnchorX ~= anchorX
    or self.coverageTaskAnchorZ ~= anchorZ
  then
    self:_releaseCoverageTask()
    self:_setStatus("pending")
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

-- Prepares the requested viewport coordinate through the staged map and
-- coverage boundary and publishes the selected-map indexes. Returns whether
-- the viewport itself is prepared; the optional safe-tile hint settles
-- separately through _advanceHint and gates only the ready status.
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
    self:_setStatus("pending")
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
  if self.objectEvents == nil then
    local ready, readyError = pcall(self._initSelectedMap, self)
    if not ready then
      self:_failRequest(readyError)
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
    self:_setStatus("pending")
    return pending()
  end

  if self.runtimeMap.scene.type == "outdoor" then
    -- Do not begin/advance coverage after the budget is exhausted.
    if remaining == 0 and self:_needsCoverageFor(fieldX, fieldZ) then
      self:_setStatus("pending")
      return pending()
    end
    local consumed, isReady = self:_advanceStagedCoverage(fieldX, fieldZ, remaining)
    remaining = remaining - consumed
    if self.status.state == "failed" then
      return pending()
    end
    if not isReady then
      return pending()
    end
    if self.candidateCoverage ~= nil then
      self:_publishCandidateCoverage()
    end
  end
  if
    self.requestPurpose == "browse"
    and self.initialCursor
    and self.initialCursor.state == "pending"
    and self.rememberedCursor ~= nil
  then
    if remaining == 0 then
      self:_setStatus("pending")
      return pending()
    end
    local cursor = assert(self.rememberedCursor, "pending remembered cursor is retained for point preparation")
    local task = self:_beginTileClassification(cursor.fieldX, cursor.fieldZ)
    local _, result = self:_advanceTileClassification(task, METADATA_ITEMS_PER_UNIT)
    remaining = remaining - 1
    result = assert(result, "remembered-point classification is synchronous")
    self:_publishInitialCursor({
      state = result.selectable and "ready" or "unavailable",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      fieldX = result.selectable and cursor.fieldX or nil,
      fieldZ = result.selectable and cursor.fieldZ or nil,
      reason = result.selectable and nil or result.reason,
    })
    self.rememberedCursor = nil
    if self.runtimeMap.scene.type == "outdoor" and self:_needsCoverageFor(self.centerX, self.centerZ) then
      self:_setStatus("pending")
      return pending()
    end
  end
  if self.requestPurpose == "browse" and self.rememberedCursor == nil then
    local consumed = self:_advanceSeedDiscovery(remaining)
    remaining = remaining - consumed
    if self.status.state == "failed" then
      return pending()
    end
  end
  return true, UPDATE_WORK_UNITS - remaining
end

-- Discovers the map-owned browsing seed without demanding destination
-- coverage: indoor maps use their collision midpoint, outdoor maps walk the
-- indexed physical descriptors owned by the selected logical map. Publishes
-- a seeded cursor that needs no tile to pass placement policy.
function SaveEditorLocationService:_advanceSeedDiscovery(maxWorkUnits)
  local cursor = self.initialCursor
  if cursor == nil or cursor.state ~= "pending" or self.rememberedCursor ~= nil then
    return 0
  end
  local runtimeMap = assert(self.runtimeMap, "seed discovery requires a published runtime map")
  if runtimeMap.scene.type ~= "outdoor" then
    local bounds = assert(self.mapBounds, "indoor seed discovery requires indoor map bounds")
    local seedX = math.floor((bounds.minX + bounds.maxX) / 2)
    local seedZ = math.floor((bounds.minZ + bounds.maxZ) / 2)
    seedX = math.max(bounds.minX, math.min(bounds.maxX, seedX))
    seedZ = math.max(bounds.minZ, math.min(bounds.maxZ, seedZ))
    self:_publishInitialCursor({
      state = "seeded",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      fieldX = seedX,
      fieldZ = seedZ,
    })
    self.seedFresh = true
    return 0
  end
  if self.seedDomain == nil then
    local created, domainOrError = pcall(self.loader.mapCellDomain, self.loader, self.mapId)
    if not created then
      self:_failRequest(domainOrError)
      return 0
    end
    self.seedDomain = domainOrError
    self.ownedCells = {}
    self.fillerCells = {}
  end
  local domain = assert(self.seedDomain, "outdoor seed discovery requires its finite cell domain")
  local visited, discovered, done = domain:advance(math.max(0, maxWorkUnits) * METADATA_ITEMS_PER_UNIT)
  local consumed = visited > 0 and math.ceil(visited / METADATA_ITEMS_PER_UNIT) or 0
  for _, descriptor in ipairs(discovered) do
    local header = assert(descriptor.mapHeaderId, "indexed physical cells carry their map header")
    if header == self.mapId then
      local owned = assert(self.ownedCells, "owned seed cells are retained while the domain walks")
      owned[#owned + 1] = { x = descriptor.x, z = descriptor.z, owned = true }
    elseif FieldZoneIdentity.isPhysicalOnlyCell(header) then
      local filler = assert(self.fillerCells, "filler seed cells are retained while the domain walks")
      filler[#filler + 1] = { x = descriptor.x, z = descriptor.z, owned = false }
    end
  end
  if not done then
    return consumed
  end
  self.seedDomain = nil
  local owned = assert(self.ownedCells, "owned seed cells are retained while the domain walks")
  if #owned == 0 then
    self:_publishInitialCursor({
      state = "unavailable",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      reason = "no_owned_cells",
    })
    return consumed
  end
  local sumX, sumZ = 0, 0
  for _, cell in ipairs(owned) do
    sumX, sumZ = sumX + cell.x, sumZ + cell.z
  end
  local meanX, meanZ = sumX / #owned, sumZ / #owned
  table.sort(owned, function(left, right)
    local leftDistance = (left.x - meanX) ^ 2 + (left.z - meanZ) ^ 2
    local rightDistance = (right.x - meanX) ^ 2 + (right.z - meanZ) ^ 2
    if leftDistance == rightDistance then
      if left.z == right.z then
        return left.x < right.x
      end
      return left.z < right.z
    end
    return leftDistance < rightDistance
  end)
  local seed = assert(owned[1], "a map with owned cells has a nearest owned cell")
  self:_publishInitialCursor({
    state = "seeded",
    mapId = self.mapId,
    generation = self.requestGeneration,
    factsRevision = self.factsRevision,
    fieldX = seed.x * TILE_SIZE + math.floor(TILE_SIZE / 2),
    fieldZ = seed.z * TILE_SIZE + math.floor(TILE_SIZE / 2),
  })
  self.seedFresh = true
  return consumed
end

-- Advances the bounded first-nearby-safe suggestion under spare budget. Only
-- tiles already inspectable in the published window are considered: indoor
-- tiles inside the collision bounds, outdoor tiles inside the published
-- coverage (filler cells only where logical ownership agrees). Positions
-- that cannot be inspected yet wait for coverage instead of consuming the
-- finite miss budget; the hint settles once a safe tile wins, the inspected
-- domain is exhausted, or the position budget runs out.
function SaveEditorLocationService:_advanceHint(maxWorkUnits)
  if self.requestPurpose ~= "browse" or self.rememberedCursor ~= nil then
    return 0
  end
  local cursor = self.initialCursor
  if cursor == nil or cursor.state ~= "seeded" or cursor.fieldX == nil or cursor.fieldZ == nil then
    return 0
  end
  -- A freshly published seed stays observable for one update before the
  -- suggestion can replace it, so browsing never skips the map-owned seed.
  if self.seedFresh then
    self.seedFresh = false
    return 0
  end
  if maxWorkUnits <= 0 then
    return 0
  end
  if self.hint == nil then
    self.hint = self:_beginHint(cursor.fieldX, cursor.fieldZ)
    if self.hint == nil then
      self:_publishInitialCursor({
        state = "unavailable",
        mapId = self.mapId,
        generation = self.requestGeneration,
        factsRevision = self.factsRevision,
        fieldX = cursor.fieldX,
        fieldZ = cursor.fieldZ,
        reason = "no_nearby_safe_tile",
      })
      return 0
    end
  end
  local hint = assert(self.hint, "the bounded safe-tile hint is retained while pending")
  if self.coverage ~= hint.coverageSeen then
    -- A new published window reopens cells that were waiting on coverage.
    hint.coverageSeen = self.coverage
    for index in ipairs(hint.cells) do
      if not hint.done[index] then
        hint.waiting[index] = false
        hint.skipped[index] = false
        hint.pos[index] = 0
      end
    end
  end
  local budget = maxWorkUnits * METADATA_ITEMS_PER_UNIT
  local inspected = 0
  local order = centerOutTileOrder()
  while inspected < budget do
    if hint.inspected >= MAX_HINT_POSITIONS then
      break
    end
    local cellIndex, cell = nil, nil ---@type integer?, SaveEditorHintCell?
    for index, candidate in ipairs(hint.cells) do
      if not hint.done[index] and not hint.waiting[index] then
        cellIndex, cell = index, candidate
        break
      end
    end
    if cellIndex == nil then
      break
    end
    cell = assert(cell, "an actionable hint cell is retained while its cell walks")
    local pos = hint.pos[cellIndex] or 0
    local offset = order[pos + 1]
    if offset == nil then
      -- The cell walked fully: cells with skipped positions wait for a new
      -- window instead of reporting a miss for coverage they never saw.
      if hint.skipped[cellIndex] then
        hint.waiting[cellIndex] = true
      else
        hint.done[cellIndex] = true
      end
    else
      hint.pos[cellIndex] = pos + 1
      local fieldX, fieldZ = cell.x * TILE_SIZE + offset.dx, cell.z * TILE_SIZE + offset.dz
      local key = tileKey(fieldX, fieldZ)
      local known = self.tileStatuses[key]
      if known ~= nil then
        if known.selectable then
          self.hint = nil
          self:_publishInitialCursor({
            state = "ready",
            mapId = self.mapId,
            generation = self.requestGeneration,
            factsRevision = self.factsRevision,
            fieldX = fieldX,
            fieldZ = fieldZ,
          })
          return inspected > 0 and math.ceil(inspected / METADATA_ITEMS_PER_UNIT) or 0
        end
      elseif self:_hintTileInspectable(cell, fieldX, fieldZ) then
        inspected = inspected + 1
        hint.inspected = hint.inspected + 1
        local facts = self:_tileFacts(fieldX, fieldZ)
        local result = SaveEditorLocationPolicy.classify(facts)
        if result.selectable then
          self.tileStatuses[key] = { state = "selectable", selectable = true }
        else
          self.tileStatuses[key] = { state = "unavailable", selectable = false, reason = result.reason }
        end
        self.dirty = true
        if result.selectable then
          self.hint = nil
          self:_publishInitialCursor({
            state = "ready",
            mapId = self.mapId,
            generation = self.requestGeneration,
            factsRevision = self.factsRevision,
            fieldX = fieldX,
            fieldZ = fieldZ,
          })
          return inspected > 0 and math.ceil(inspected / METADATA_ITEMS_PER_UNIT) or 0
        end
      else
        hint.skipped[cellIndex] = true
      end
    end
  end
  if hint.inspected >= MAX_HINT_POSITIONS then
    self.hint = nil
    self:_publishInitialCursor({
      state = "unavailable",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      fieldX = cursor.fieldX,
      fieldZ = cursor.fieldZ,
      reason = "no_nearby_safe_tile",
    })
    return inspected > 0 and math.ceil(inspected / METADATA_ITEMS_PER_UNIT) or 0
  end
  local settled = true
  for index in ipairs(hint.cells) do
    if not hint.done[index] then
      settled = false
      break
    end
  end
  if settled then
    self.hint = nil
    self:_publishInitialCursor({
      state = "unavailable",
      mapId = self.mapId,
      generation = self.requestGeneration,
      factsRevision = self.factsRevision,
      fieldX = cursor.fieldX,
      fieldZ = cursor.fieldZ,
      reason = "no_nearby_safe_tile",
    })
  end
  return inspected > 0 and math.ceil(inspected / METADATA_ITEMS_PER_UNIT) or 0
end

---@param seedX integer
---@param seedZ integer
---@return SaveEditorLocationHint?
function SaveEditorLocationService:_beginHint(seedX, seedZ)
  local runtimeMap = assert(self.runtimeMap, "the safe-tile hint requires a published runtime map")
  local cells = {}
  if runtimeMap.scene.type ~= "outdoor" then
    local bounds = assert(self.mapBounds, "the indoor safe-tile hint requires indoor map bounds")
    for cellZ = math.floor(bounds.minZ / TILE_SIZE), math.floor(bounds.maxZ / TILE_SIZE) do
      for cellX = math.floor(bounds.minX / TILE_SIZE), math.floor(bounds.maxX / TILE_SIZE) do
        cells[#cells + 1] = { x = cellX, z = cellZ, owned = true }
      end
    end
  else
    for _, cell in ipairs(self.ownedCells or {}) do
      cells[#cells + 1] = cell
    end
    for _, cell in ipairs(self.fillerCells or {}) do
      cells[#cells + 1] = cell
    end
  end
  if #cells == 0 then
    return nil
  end
  table.sort(cells, function(left, right)
    local leftDistance = (left.x * TILE_SIZE + TILE_SIZE / 2 - seedX) ^ 2
      + (left.z * TILE_SIZE + TILE_SIZE / 2 - seedZ) ^ 2
    local rightDistance = (right.x * TILE_SIZE + TILE_SIZE / 2 - seedX) ^ 2
      + (right.z * TILE_SIZE + TILE_SIZE / 2 - seedZ) ^ 2
    if leftDistance == rightDistance then
      if left.z == right.z then
        return left.x < right.x
      end
      return left.z < right.z
    end
    return leftDistance < rightDistance
  end)
  local ranked = {}
  for index = 1, math.min(MAX_HINT_CELLS, #cells) do
    ranked[#ranked + 1] = cells[index]
  end
  local done, waiting, skipped, pos = {}, {}, {}, {}
  for index in ipairs(ranked) do
    done[index], waiting[index], skipped[index], pos[index] = false, false, false, 0
  end
  return {
    seedX = seedX,
    seedZ = seedZ,
    cells = ranked,
    done = done,
    waiting = waiting,
    skipped = skipped,
    pos = pos,
    inspected = 0,
    coverageSeen = self.coverage,
  }
end

---@param cell SaveEditorHintCell
---@param fieldX integer
---@param fieldZ integer
---@return boolean
function SaveEditorLocationService:_hintTileInspectable(cell, fieldX, fieldZ)
  local runtimeMap = assert(self.runtimeMap, "the safe-tile hint requires a published runtime map")
  if runtimeMap.scene.type ~= "outdoor" then
    local bounds = assert(self.mapBounds, "the indoor safe-tile hint requires indoor map bounds")
    return fieldX >= bounds.minX and fieldX <= bounds.maxX and fieldZ >= bounds.minZ and fieldZ <= bounds.maxZ
  end
  local coverage = self.coverage
  if coverage == nil or not coverage:containsGlobal(fieldX, fieldZ) then
    return false
  end
  if cell.owned then
    return true
  end
  return FieldZoneIdentity.logicalZoneAt(coverage, fieldX, fieldZ, self.mapId) == self.mapId
end

function SaveEditorLocationService:_releaseCoverage()
  self:_releaseCoverageTask()
  self:_discardCandidateCoverage()
  if self.coverage then
    self.coverage:release()
    self.coverage = nil
  end
  self.resolver = nil
  self.resolverTerrain = nil
end

---@param fieldX integer
---@param fieldZ integer
---@return false|string
function SaveEditorLocationService:_lookupTrigger(fieldX, fieldZ)
  if self.warpSet ~= nil and self.warpSet[tileKey(fieldX, fieldZ)] then
    return "warp"
  end
  for _, event in ipairs(self.coordinateEvents or {}) do
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

---@param fieldX integer
---@param fieldZ integer
---@return boolean
function SaveEditorLocationService:_lookupOccupied(fieldX, fieldZ)
  return self.occupiedSet ~= nil and self.occupiedSet[tileKey(fieldX, fieldZ)] == true
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
    occupied = false,
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
  if not facts.logicalMapMatch then
    return facts
  end

  facts.trigger = self:_lookupTrigger(fieldX, fieldZ)
  facts.occupied = self:_lookupOccupied(fieldX, fieldZ)
  -- Cheap gates first: the terrain surface is sampled only for tiles that
  -- survived every earlier refusal, matching the placement policy order.
  -- The behavior allowlist here must stay identical to the policy's own.
  local collision = assert(facts.collision, "collision facts precede surface sampling")
  if
    facts.trigger == false
    and not collision.blocked
    and (collision.behavior == 0 or collision.behavior == MetatileBehavior.BEHAVIOR.TALL_GRASS)
    and not facts.occupied
  then
    if self.resolver == nil or self.resolverTerrain ~= terrain then
      self.resolver = SurfaceResolver.new(assert(terrain, "terrain is required for surface sampling"))
      self.resolverTerrain = terrain
    end
    local resolver = assert(self.resolver, "a region-cached surface resolver is required")
    local ok, sampleOrError = pcall(function()
      return resolver:resolve({
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
  end
  return facts
end

function SaveEditorLocationService:_classify(fieldX, fieldZ)
  local task = self:_beginTileClassification(fieldX, fieldZ)
  local _, result = self:_advanceTileClassification(task, 4096)
  return assert(result, "tile classification is synchronous"), task.facts
end

function SaveEditorLocationService:_beginTileClassification(fieldX, fieldZ)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    facts = self:_tileFacts(fieldX, fieldZ),
    phase = "policy",
    result = nil,
  }
end

function SaveEditorLocationService:_advanceTileClassification(task, maxVisits)
  assert(finiteInteger(maxVisits) and maxVisits >= 0, "tile classification budget must be non-negative")
  if task.result ~= nil then
    return 0, task.result
  end
  if maxVisits <= 0 then
    return 0, nil
  end
  task.result = SaveEditorLocationPolicy.classify(task.facts)
  task.phase = "done"
  return 1, task.result
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
        local task = self:_beginTileClassification(tile.fieldX, tile.fieldZ)
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
        self.dirty = true
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

-- Advances browse preparation that needs no viewport: staged map assets,
-- selected-map indexes and the map-owned seed. Destination closure and
-- coverage are never demanded for a guessed coordinate here.
function SaveEditorLocationService:_updateUnlocated()
  local assetsReady, assetsError = self.loader:requestMapAssets(self.mapId, "required")
  if assetsError ~= nil then
    self:_failRequest(assetsError, true)
    return
  end
  if not assetsReady then
    self:_setStatus("pending")
    return
  end
  local remaining = UPDATE_WORK_UNITS
  if self.runtimeMap == nil then
    local consumed, mapReady = self:_advanceStagedMap(remaining)
    remaining = remaining - consumed
    if not mapReady then
      return
    end
  end
  if self.objectEvents == nil then
    local ready, readyError = pcall(self._initSelectedMap, self)
    if not ready then
      self:_failRequest(readyError)
      return
    end
  end
  local consumed = self:_advanceSeedDiscovery(remaining)
  remaining = remaining - consumed
  if self.status.state == "failed" then
    return
  end
  if remaining > 0 then
    self:_advanceHint(remaining)
  end
end

-- Reports whether this update changed externally visible snapshot state:
-- map, status, initial cursor or visible tile statuses. Pure work progress
-- without such a change reports false, so idle updates stay quiet.
function SaveEditorLocationService:update()
  assert(not self.disposed, "location service is disposed")
  if self.status.state == "failed" then
    local changed = self.dirty
    self.dirty = false
    return changed
  end
  if self.mapId == nil or self.centerX == nil or self.centerZ == nil then
    if self.mapId == nil then
      self.status = status("idle")
      return false
    end
    self:_updateUnlocated()
    local changed = self.dirty
    self.dirty = false
    return changed
  end
  local fieldX, fieldZ = self.centerX, self.centerZ
  if self.initialCursor ~= nil and self.initialCursor.state == "pending" and self.rememberedCursor ~= nil then
    fieldX, fieldZ = self.rememberedCursor.fieldX, self.rememberedCursor.fieldZ
  end
  local ok, prepared, consumed = pcall(self._prepareAt, self, fieldX, fieldZ)
  if not ok then
    self:_failRequest(prepared)
    local changed = self.dirty
    self.dirty = false
    return changed
  end
  if not prepared then
    if next(self.tileStatuses) ~= nil then
      self.tileStatuses = {}
      self.dirty = true
    end
    local changed = self.dirty
    self.dirty = false
    return changed
  end
  assert(finiteInteger(consumed) and consumed >= 0 and consumed <= UPDATE_WORK_UNITS)
  local visibleUsed = self:_classifyVisible(UPDATE_WORK_UNITS - consumed)
  self:_advanceHint(UPDATE_WORK_UNITS - consumed - visibleUsed)
  if self.requestPurpose == "verify" then
    self:_setStatus("ready")
  elseif self.rememberedCursor ~= nil then
    self:_setStatus("pending")
  elseif self.initialCursor == nil then
    self:_setStatus("ready")
  elseif self.initialCursor.state == "ready" or self.initialCursor.state == "unavailable" then
    self:_setStatus("ready")
  else
    self:_setStatus("pending")
  end
  local changed = self.dirty
  self.dirty = false
  return changed
end

function SaveEditorLocationService:snapshot()
  assert(not self.disposed, "location service is disposed")
  local record = self.mapId and recordById(self.world, self.mapId) or nil
  if self.mapId == nil or self.centerX == nil or self.centerZ == nil then
    if self.mapId == nil then
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
    -- An active map without a viewport still publishes its selected map,
    -- preparation status and request-owned cursor; there are no tiles yet.
    return {
      mapId = self.mapId,
      map = record and { mapId = record.id, symbol = record.symbol, section = record.mapSection } or nil,
      symbol = record and record.symbol or nil,
      generation = self.generation,
      status = copy(self.status),
      tiles = {},
      initialCursor = copy(self.initialCursor),
    }
  end
  local tiles = {}
  for _, tile in ipairs(self:_visibleTiles()) do
    local current = self.tileStatuses[tileKey(tile.fieldX, tile.fieldZ)]
    local copied = current and copy(current) or status("pending")
    copied.fieldX, copied.fieldZ = tile.fieldX, tile.fieldZ
    tiles[#tiles + 1] = copied
  end
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
  local outdoor = self.runtimeMap.scene.type == "outdoor"
  if outdoor and (self.coverageTask ~= nil or self.candidateCoverage ~= nil or self.coverage == nil) then
    return nil, status("pending")
  end
  if self.objectEvents == nil then
    return nil, status("pending")
  end
  if not outdoor and self.mapBounds == nil then
    return nil, status("pending")
  end

  if outdoor and not self.coverage:containsGlobal(fieldX, fieldZ) then
    -- Exact selected-map refusals hold regardless of the published window:
    -- a known warp, trigger or occupied tile is never a destination even
    -- when the current coverage anchors elsewhere.
    local trigger = self:_lookupTrigger(fieldX, fieldZ)
    if trigger ~= false then
      return nil, status("unavailable", trigger == "warp" and "warp" or "coordinate_trigger")
    end
    if self:_lookupOccupied(fieldX, fieldZ) then
      return nil, status("unavailable", "possible_actor")
    end
    return nil, status("unavailable", "outside_map")
  end

  -- Explicit activation classifies through the same single-facts path as the
  -- grid so direct selection agrees with visible statuses.
  local result, facts = self:_classify(fieldX, fieldZ)
  if not result.selectable then
    return nil, status("unavailable", result.reason)
  end
  -- The placement reuses the exact sampled facts the policy accepted: one
  -- terrain sample per activation, never a second resolution read.
  local surface = assert(facts.surface, "an accepted placement carries its sampled surface")
  local placement = {
    mapId = self.mapId,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surface.surfaceId,
    worldY = surface.worldY,
    terrainDependencyHash = surface.terrainDependencyHash,
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
