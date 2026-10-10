-- Location map preparation advances through staged loader tasks the update loop owns.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local CollisionFixture = require("tests.support.CollisionFixture")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Service = require("app.src.saveeditor.SaveEditorLocationService")

local T = { tests = {} }

local OUTSIDE_CENTER = 70000

local function structuralWorld()
  local maps = {
    {
      id = 11,
      symbol = "MAP_FIRST",
      mapSection = "FIRST_SECTION",
      mapSectionNativeId = 1,
      followMode = "ALLOW",
      worldOriginX = 0,
      worldOriginZ = 0,
      matrix = { memberId = 0 },
    },
    {
      id = 22,
      symbol = "MAP_SECOND",
      mapSection = "SECOND_SECTION",
      mapSectionNativeId = 2,
      followMode = "ALLOW",
      worldOriginX = 1024,
      worldOriginZ = 2048,
      matrix = { memberId = 0 },
    },
  }
  return {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = maps,
    byId = { [11] = 1, [22] = 2 },
    bySymbol = { MAP_FIRST = 11, MAP_SECOND = 22 },
    analysis = { mapHeaderCount = 2, excluded = {} },
  }
end

local function flatTerrain()
  return {
    candidatesAt = function()
      return { { id = 1 } }
    end,
    sampleHeight = function()
      return 0
    end,
    sample = function()
      return { surfaceId = 3, worldY = 0 }
    end,
  }
end

local function indoorRuntime(blocked)
  local collision = {}
  function collision:containsLocal()
    return true
  end
  function collision:getLocal()
    return { blocked = blocked == true, behavior = 0 }
  end
  return {
    scene = { type = "indoor" },
    coordinateOrigin = { x = 0, z = 0 },
    collision = collision,
    terrain = flatTerrain(),
    terrainDependencyHash = "loading-fixture",
    fieldRegion = { cells = { { collision = { width = 64, height = 64 } } } },
    fieldData = { events = { objects = {}, warps = {}, coordinates = {} } },
  }
end

local function fakeCoverage(loader, mapId, anchorX, anchorZ)
  local coverage = {
    anchorX = anchorX,
    anchorZ = anchorZ,
    origin = { x = anchorX * 32, z = anchorZ * 32 },
    index = {
      matrices = {
        {
          matrixMemberId = 0,
          width = 2,
          height = 1,
          cells = { { x = 0, z = 0, mapHeaderId = mapId }, { x = 1, z = 0, mapHeaderId = mapId } },
        },
      },
    },
    cells = {
      [tostring(anchorX) .. ":" .. tostring(anchorZ)] = {
        descriptor = { x = anchorX, z = anchorZ, mapHeaderId = mapId },
      },
    },
    terrainDependencyHash = "fake-coverage-hash",
    releases = 0,
    recenters = {},
  }
  local regionCollision = {}
  function regionCollision:containsLocal()
    return true
  end
  function regionCollision:getLocal()
    return { blocked = false, behavior = 0 }
  end
  coverage.region = { collision = regionCollision, terrain = flatTerrain() }
  function coverage:containsGlobal()
    return true
  end
  function coverage:mapHeaderAt()
    return mapId
  end
  function coverage:committedDescriptors()
    return { { mapHeaderId = mapId } }
  end
  function coverage:recenter(newAnchorX, newAnchorZ)
    self.recenters[#self.recenters + 1] = { anchorX = newAnchorX, anchorZ = newAnchorZ }
    self.anchorX = newAnchorX
    self.anchorZ = newAnchorZ
  end
  function coverage:release()
    self.releases = self.releases + 1
  end
  loader.coverages = loader.coverages or {}
  loader.coverages[#loader.coverages + 1] = coverage
  return coverage
end

local function stagedCoverageTask(loader, mapId, anchorX, anchorZ, script)
  local task = {
    mapId = mapId,
    anchorX = anchorX,
    anchorZ = anchorZ,
    advances = 0,
    advanceArgs = {},
    consumedTotal = 0,
    releases = 0,
    takes = 0,
  }
  function task:advance(workUnits)
    self.advances = self.advances + 1
    local requested = workUnits or 0
    self.advanceArgs[#self.advanceArgs + 1] = requested
    local consumed = math.min(script.coverageConsumePerAdvance or 0, requested)
    self.consumedTotal = self.consumedTotal + consumed
    return consumed
  end
  function task:isReady()
    if script.coverageImmediate then
      return true
    end
    if script.coverageReadyAtAdvances ~= nil then
      return self.advances >= script.coverageReadyAtAdvances
    end
    return false
  end
  function task:takeResult()
    self.takes = self.takes + 1
    return fakeCoverage(loader, self.mapId, self.anchorX, self.anchorZ)
  end
  function task:finish()
    error("synchronous finish must not drive staged coverage preparation", 2)
  end
  function task:release()
    self.releases = self.releases + 1
  end
  return task
end

local function stagedTask(loader, mapId, script)
  local task = {
    mapId = mapId,
    advances = 0,
    advanceBudget = 0,
    advanceArgs = {},
    consumedTotal = 0,
    releases = 0,
    finishes = 0,
    takes = 0,
  }
  function task:advance(workUnits)
    self.advances = self.advances + 1
    local requested = workUnits or 0
    self.advanceArgs[#self.advanceArgs + 1] = requested
    self.advanceBudget = self.advanceBudget + requested
    if script.taskFailOnAdvance ~= nil then
      local failure = script.taskFailOnAdvance
      if type(failure) == "function" then
        failure = failure(self)
      end
      if failure ~= nil then
        error(failure, 0)
      end
    end
    local consumed = math.min(script.consumePerAdvance or 0, requested)
    self.consumedTotal = self.consumedTotal + consumed
    return consumed
  end
  function task:isReady()
    if script.taskImmediate then
      return true
    end
    if script.taskReadyAtAdvances ~= nil then
      return self.advances >= script.taskReadyAtAdvances
    end
    return false
  end
  function task:takeResult()
    self.takes = self.takes + 1
    loader.runtime.mapId = self.mapId
    return loader.runtime
  end
  function task:finish()
    self.finishes = self.finishes + 1
    error("synchronous finish must not drive staged map preparation", 2)
  end
  function task:release()
    self.releases = self.releases + 1
  end
  return task
end

local function fakeLoader(script)
  local loader = {
    requestCount = 0,
    locationRequestCount = 0,
    readyAfterRequests = script.readyAfterRequests or 0,
    requestError = script.requestError,
    begins = {},
    loads = {},
    protects = {},
    tasks = {},
    coverageBegins = {},
    coverageTasks = {},
    blockingCoverages = {},
    released = false,
    runtime = indoorRuntime(script.allBlocked),
  }
  if script.outdoor then
    local outdoor = indoorRuntime()
    outdoor.scene = { type = "outdoor" }
    loader.runtime = outdoor
  end
  function loader:requestLocation(mapId, fieldX, fieldZ, urgency)
    self.requestCount = self.requestCount + 1
    self.locationRequestCount = self.locationRequestCount + 1
    if script.surveyClosureError ~= nil and fieldX == 0 and fieldZ == 0 then
      return false, script.surveyClosureError
    end
    if self.requestError ~= nil then
      return false, self.requestError
    end
    if self.requestCount <= self.readyAfterRequests then
      return false
    end
    return true
  end
  function loader:requestMapAssets(mapId, urgency)
    self.requestCount = self.requestCount + 1
    if self.requestError ~= nil then
      return false, self.requestError
    end
    if self.requestCount <= self.readyAfterRequests then
      return false
    end
    return true
  end
  function loader:beginLoad(mapId)
    local task = stagedTask(self, mapId, script)
    self.begins[#self.begins + 1] = mapId
    self.tasks[#self.tasks + 1] = task
    return task
  end
  function loader:beginLogicalMetadata(mapId)
    local task = { ready = false, taken = false, released = false, mapId = mapId }
    function task:advance(workUnits)
      if workUnits > 0 and not self.ready then
        self.ready = true
        return 1
      end
      return 0
    end
    function task:isReady()
      return self.ready
    end
    function task:takeResult()
      assert(self.ready and not self.taken)
      self.taken = true
      return loader.runtime
    end
    function task:release()
      self.released = true
    end
    return task
  end
  function loader:load(mapId)
    self.loads[#self.loads + 1] = mapId
    return self.runtime
  end
  function loader:definesMap(mapId)
    return mapId == 11 or mapId == 22
  end
  function loader:mapCellDomain(mapId)
    local cells = {
      { x = 0, z = 0, mapHeaderId = mapId },
      { x = 1, z = 0, mapHeaderId = mapId },
    }
    local index = 1
    local domain = {}
    function domain:advance(maxVisits)
      local visited, selected = 0, {}
      while visited < maxVisits and index <= #cells do
        selected[#selected + 1] = cells[index]
        index = index + 1
        visited = visited + 1
      end
      return visited, selected, index > #cells
    end
    return domain
  end
  function loader:beginPhysicalCoverage(runtimeMap, position)
    local anchorX, anchorZ = math.floor(position.fieldX / 32), math.floor(position.fieldZ / 32)
    local task = stagedCoverageTask(self, runtimeMap.mapId, anchorX, anchorZ, script)
    self.coverageBegins[#self.coverageBegins + 1] = { mapId = runtimeMap.mapId, anchorX = anchorX, anchorZ = anchorZ }
    self.coverageTasks[#self.coverageTasks + 1] = task
    return task
  end
  function loader:createPhysicalCoverage(runtimeMap, position)
    local anchorX, anchorZ = math.floor(position.fieldX / 32), math.floor(position.fieldZ / 32)
    self.blockingCoverages[#self.blockingCoverages + 1] =
      { mapId = runtimeMap.mapId, anchorX = anchorX, anchorZ = anchorZ }
    return fakeCoverage(self, runtimeMap.mapId, anchorX, anchorZ)
  end
  function loader:protectMap(mapId, protect)
    self.protects[#self.protects + 1] = { mapId = mapId, protect = protect }
  end
  function loader:release()
    self.released = true
  end
  return loader
end

local function loadingService(script)
  local service = Service.new({
    cacheFs = {
      loadLua = function()
        return nil
      end,
    },
    world = structuralWorld(),
    derivedAssets = {},
    savedObjects = { actors = {} },
  })
  local loader = fakeLoader(script or {})
  service.loader = loader
  return service, loader
end

local function openOutside(service, mapId)
  service:openMap(mapId)
  service:setViewport(OUTSIDE_CENTER, OUTSIDE_CENTER, 1, 1)
end

-- A synthetic outdoor world served by the real headless loader and the
-- real staged coverage: one 5x5 physical-cell matrix around the map
-- origin, so a committed radius-1 window always resolves without a ROM.
-- The optional hooks table instruments the composition: index-load
-- counting, a holdable cell closure, and per-update staged work totals.
local function buildRealOutdoorService(hooks)
  hooks = hooks or {}
  local files = {}
  local world = {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = {
      {
        id = 0,
        symbol = "MAP_ZERO",
        mapSection = "TEST_SECTION",
        mapSectionNativeId = 7,
        followMode = "ALLOW",
        worldOriginX = 64,
        worldOriginZ = 64,
        matrix = { memberId = 1 },
      },
    },
    byId = { [0] = 1 },
    bySymbol = { MAP_ZERO = 0 },
    analysis = { mapHeaderCount = 1, excluded = {} },
  }
  files["data/generated/maps/0000/scene.lua"] = {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = 0,
    mapSymbol = "MAP_ZERO",
    cameraType = 3,
    type = "outdoor",
    neighbors = {},
    buildingInstances = {},
    terrainAnimations = { textureSrt = false },
    matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = 64, worldOriginZ = 64 },
  }
  local edgeColors = {}
  for index = 0, 7 do
    edgeColors[index] = 0
  end
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  files["data/generated/field/maps/0000/field.lua"] = {
    schema = FieldMapDataCache.FIELD_SCHEMA,
    mapId = 0,
    mapSymbol = "MAP_ZERO",
    cameraType = 3,
    transitionEnvironment = "outdoors",
    initScripts = {},
    fieldUse = {
      flyAllowed = true,
      teleportAllowed = true,
      escapeAllowed = false,
      flashUsable = false,
      alphChamber = false,
      icePathB2F = false,
      cave = false,
      unionOrColosseum = false,
    },
    events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    music = { day = "SEQ_X", night = "SEQ_X", flagOverrides = {}, traversalOverrides = {} },
    soundplates = {},
    renderEnvironment = {
      lighting = {
        records = {
          {
            endHalfSeconds = 0,
            lights = {},
            diffuseRgb555 = 0,
            ambientRgb555 = 0,
            specularRgb555 = 0,
            emissionRgb555 = 0,
          },
        },
      },
      edgeColors = edgeColors,
      weatherId = 0,
      fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
    },
  }
  local cells = {}
  local cellFiles = {}
  local terrainFiles = {}
  local collisionBytes = CollisionFixture.asset(32, 32)
  for z = 0, 4 do
    for x = 0, 4 do
      local index = z * 5 + x
      local cell = {
        schema = FieldCellCache.CELL_SCHEMA,
        matrixMemberId = 1,
        index = index,
        x = x,
        z = z,
        mapHeaderId = 0,
        altitude = 0,
        origin = { x = x * 32, y = 0, z = z * 32 },
        landDataMemberId = 1,
        areaDataMemberId = 1,
        file = FieldCellCache.cellPath(1, index),
        collision = { file = FieldCellCache.collisionPath(1, index) },
        terrain = { schema = "g4-terrain-surfaces-v1", file = FieldCellCache.terrainPath(1, index) },
        batches = {},
        materials = {},
        buildingInstances = {},
        terrainAnimations = { textureSrt = false },
      }
      cells[#cells + 1] = cell
      cellFiles[cell.file] = cell
      terrainFiles[cell.terrain.file] = {
        schema = "g4-terrain-surfaces-v1",
        source = { bdhcSha1 = "staged-cell-" .. index },
        plates = {},
      }
    end
  end
  files[FieldCellCache.indexPath()] = {
    schema = FieldCellCache.INDEX_SCHEMA,
    matrices = { { matrixMemberId = 1, width = 5, height = 5, cells = cells } },
  }
  local cacheFs = {}
  function cacheFs:loadLua(path)
    if path == FieldCellCache.indexPath() then
      hooks.indexLoads = (hooks.indexLoads or 0) + 1
    end
    if cellFiles[path] then
      return cellFiles[path]
    end
    if terrainFiles[path] then
      return terrainFiles[path]
    end
    return files[path]
  end
  function cacheFs:read(_)
    return collisionBytes
  end
  local function alwaysReady()
    return true
  end
  local function cellReady()
    return not hooks.cellPending
  end
  local service = Service.new({
    cacheFs = cacheFs,
    world = world,
    derivedAssets = {
      requestField = alwaysReady,
      requestLogicalField = alwaysReady,
      requestCell = cellReady,
      ensureField = alwaysReady,
      ensureLogicalField = alwaysReady,
      ensureCell = alwaysReady,
    },
    savedObjects = { actors = {} },
  })
  local trackedLoader = service.loader
  local function trackTask(task)
    local taskAdvance = task.advance
    task.advance = function(taskSelf, workUnits)
      local consumed = taskAdvance(taskSelf, workUnits)
      hooks.updateConsumed = (hooks.updateConsumed or 0) + consumed
      return consumed
    end
    return task
  end
  local loaderBeginLoad = trackedLoader.beginLoad
  trackedLoader.beginLoad = function(loaderSelf, mapId)
    local task = loaderBeginLoad(loaderSelf, mapId)
    hooks.mapTaskBegun = true
    if hooks.indexLoadsAtBegin == nil then
      hooks.indexLoadsAtBegin = hooks.indexLoads or 0
    end
    return trackTask(task)
  end
  local loaderBeginCoverage = trackedLoader.beginPhysicalCoverage
  trackedLoader.beginPhysicalCoverage = function(loaderSelf, runtimeMap, position)
    hooks.coverageBegun = true
    return trackTask(loaderBeginCoverage(loaderSelf, runtimeMap, position))
  end
  return service
end

local function realOutdoorService()
  return buildRealOutdoorService()
end

function T.tests.superseded_map_work_releases_exactly_once_and_never_publishes()
  local service, loader = loadingService({ taskReadyAtAdvances = 4 })
  openOutside(service, 11)
  service:update()
  openOutside(service, 22)
  service:update()
  service:update()
  service:update()
  service:update()

  Assert.equal(#loader.begins, 2, "each opened map stages its own load task")
  local first, second = loader.tasks[1], loader.tasks[2]
  Assert.equal(first.mapId, 11, "the first task belongs to the superseded map")
  Assert.equal(first.releases, 1, "the superseded task releases exactly once")
  Assert.equal(first.takes, 0, "the superseded result is never taken")
  Assert.equal(second.takes, 1, "only the current map takes its result")
  local snapshot = service:snapshot()
  Assert.equal(snapshot.mapId, 22, "only the current map publishes")
  Assert.equal(snapshot.status.state, "ready", "the current map reaches ready")
  service:dispose()
end

function T.tests.dispose_releases_a_pending_task_exactly_once()
  local service, loader = loadingService({})
  openOutside(service, 11)
  service:update()

  Assert.equal(#loader.tasks, 1, "preparation stages its map work through a loader task")
  service:dispose()
  Assert.equal(loader.tasks[1].releases, 1, "disposal releases the pending task exactly once")
  Assert.isTrue(loader.released, "disposal still releases the loader")
end

function T.tests.task_failure_releases_and_publishes_a_failed_status()
  local failure = Errors.new("MAP_PREPARATION_FAILED", "staged scene build failed")
  local service, loader = loadingService({ taskFailOnAdvance = failure })
  openOutside(service, 11)
  service:update()

  Assert.equal(#loader.tasks, 1, "preparation stages its map work through a loader task")
  Assert.equal(loader.tasks[1].releases, 1, "a failed task releases exactly once")
  Assert.equal(loader.tasks[1].takes, 0, "a failed result is never taken")
  Assert.equal(service:snapshot().status.state, "failed", "a task failure becomes a failed status")
  Assert.isNil(service.runtimeMap, "a failed map publishes no runtime map")
  for _, tile in ipairs(service:snapshot().tiles) do
    Assert.equal(tile.state, "pending", "a failed map classifies no tiles")
  end
  service:dispose()
end

function T.tests.programmer_string_from_staged_task_remains_a_hard_failure()
  local service, loader = loadingService({ taskFailOnAdvance = "unexpected task failure" })
  openOutside(service, 11)

  local ok, failure = pcall(service.update, service)

  Assert.isFalse(ok, "an unstructured task exception is not converted into a recoverable map status")
  Assert.equal(failure, "unexpected task failure", "the original programmer failure propagates")
  Assert.equal(assert(loader.tasks[1]).releases, 1, "the failed task still releases exactly once")
  service:dispose()
end

function T.tests.failed_browse_request_stays_terminal_across_updates_viewports_and_resolve()
  local failure = Errors.new("MAP_PREPARATION_FAILED", "staged scene build failed")
  local failedTask
  local service, loader = loadingService({
    taskFailOnAdvance = function(task)
      if failedTask == nil then
        failedTask = task
        return failure
      end
      return nil
    end,
    taskImmediate = true,
  })
  local requestMapAssets = loader.requestMapAssets
  local assetRequests = 0
  function loader:requestMapAssets(mapId, urgency)
    assetRequests = assetRequests + 1
    return requestMapAssets(self, mapId, urgency)
  end
  service:openMap(11, { purpose = "browse" })
  service:setViewport(16, 16, 1, 1)
  service:update()

  local failed = service:snapshot()
  Assert.equal(failed.status.state, "failed", "the typed staged error is visible")
  Assert.notNil(failed.initialCursor, "failed browse requests keep an inspectable cursor")
  Assert.equal(failed.initialCursor.state, "failed", "the browse cursor is terminal with the request")
  Assert.equal(failed.initialCursor.mapId, 11, "the failed cursor identifies its map")
  Assert.equal(failed.initialCursor.generation, service.requestGeneration, "the failed cursor identifies its request")
  Assert.equal(failed.initialCursor.reason, failed.status.reason, "the cursor retains the failure reason")

  local task = assert(loader.tasks[1])
  local initialCounts = {
    assets = assetRequests,
    begins = #loader.begins,
    advances = task.advances,
    requests = loader.locationRequestCount,
    releases = task.releases,
  }
  for index = 1, 20 do
    service:setViewport(16 + index, 16, 1, 1)
    service:update()
    local snapshot = service:snapshot()
    Assert.equal(snapshot.status.state, "failed", "viewport changes do not rearm the failed request")
    Assert.equal(snapshot.status.reason, failed.status.reason, "failure diagnostics remain stable")
    Assert.equal(snapshot.initialCursor.state, "failed", "the failed cursor remains inspectable")
    Assert.equal(
      snapshot.initialCursor.generation,
      failed.initialCursor.generation,
      "the failed cursor remains request-bound"
    )
  end
  local resolved, resolveStatus = service:resolve(11, 16, 16, service.generation)
  Assert.isNil(resolved, "a failed request cannot resolve a tile")
  Assert.equal(resolveStatus.state, "failed", "resolution returns the terminal failure")
  Assert.equal(assetRequests, initialCounts.assets, "failed updates request no map assets")
  Assert.equal(#loader.begins, initialCounts.begins, "failed updates begin no new map tasks")
  Assert.equal(task.advances, initialCounts.advances, "failed updates advance no staged task")
  Assert.equal(
    loader.locationRequestCount,
    initialCounts.requests,
    "failed updates and resolution request no location readiness"
  )
  Assert.equal(task.releases, 1, "the failed map task is released exactly once")
  service:dispose()
end

function T.tests.resolve_location_failure_commits_terminal_browse_request()
  local failure = Errors.new("LOCATION_CLOSURE_FAILED", "selected location is unavailable")
  local service, loader = loadingService({ taskImmediate = true })
  local locationRequests = 0
  function loader:requestLocation()
    locationRequests = locationRequests + 1
    return false, failure
  end

  service:openMap(11, { purpose = "browse" })
  service:setViewport(16, 16, 1, 1)
  local generation = service.generation
  local requestGeneration = service.requestGeneration
  local resolved, resolveStatus = service:resolve(11, 16, 16, generation)

  Assert.isNil(resolved, "a failed location cannot resolve")
  Assert.equal(resolveStatus.state, "failed", "resolution reports the structured failure")
  local failed = service:snapshot()
  Assert.equal(failed.status.state, "failed", "resolution commits failure for its request")
  Assert.equal(failed.status.reason, Errors.format(failure), "the terminal status preserves typed error context")
  Assert.equal(failed.initialCursor.state, "failed", "the browse cursor becomes terminal")
  Assert.equal(failed.initialCursor.mapId, 11, "the failed cursor retains its map")
  Assert.equal(failed.initialCursor.generation, requestGeneration, "the failed cursor retains its generation")
  Assert.equal(failed.initialCursor.reason, failed.status.reason, "cursor and status retain the same cause")

  local acquisitionCounts = {
    assets = loader.requestCount,
    begins = #loader.begins,
    locationRequests = locationRequests,
  }
  for _ = 1, 3 do
    local repeated, repeatedStatus = service:resolve(11, 16, 16, generation)
    Assert.isNil(repeated, "a terminal request still cannot resolve")
    Assert.equal(repeatedStatus.reason, failed.status.reason, "resolution returns the committed failure")
    service:update()
  end
  Assert.equal(locationRequests, acquisitionCounts.locationRequests, "terminal resolution requests no more locations")
  Assert.equal(loader.requestCount, acquisitionCounts.assets, "terminal updates request no map assets")
  Assert.equal(#loader.begins, acquisitionCounts.begins, "terminal updates begin no staged map task")
  service:dispose()
end

function T.tests.asset_and_location_failures_are_terminal_for_browse_requests()
  local assetFailure = Errors.new("MAP_ASSETS_FAILED", "map assets are unavailable")
  local assetService, assetLoader = loadingService({ requestError = assetFailure })
  assetService:openMap(11, { purpose = "browse" })
  assetService:setViewport(16, 16, 1, 1)
  assetService:update()
  local assetFailureView = assetService:snapshot()
  Assert.equal(assetFailureView.status.state, "failed", "asset acquisition failure is published")
  Assert.equal(assetFailureView.initialCursor.state, "failed", "asset failure closes the browse cursor")
  local requestsAtAssetFailure = assetLoader.requestCount
  assetService:update()
  Assert.equal(assetLoader.requestCount, requestsAtAssetFailure, "failed asset acquisition is not retried")
  assetService:dispose()

  local locationFailure = Errors.new("LOCATION_CLOSURE_FAILED", "map location is unavailable")
  local locationService, locationLoader = loadingService({ taskImmediate = true })
  local requests = 0
  function locationLoader:requestLocation()
    requests = requests + 1
    return false, locationFailure
  end
  locationService:openMap(11, { purpose = "browse" })
  locationService:setViewport(16, 16, 1, 1)
  locationService:update()
  local locationFailureView = locationService:snapshot()
  Assert.equal(locationFailureView.status.state, "failed", "location readiness failure is published")
  Assert.equal(locationFailureView.initialCursor.state, "failed", "location failure closes the browse cursor")
  local requestsAtLocationFailure = requests
  locationService:update()
  Assert.equal(requests, requestsAtLocationFailure, "failed location readiness is not retried")
  Assert.equal(
    assert(locationLoader.tasks[1]).releases,
    0,
    "a successfully published map task is not released on closure failure"
  )
  locationService:dispose()
end

function T.tests.same_map_retry_rearms_only_after_explicit_open()
  local failure = Errors.new("MAP_PREPARATION_FAILED", "staged scene build failed")
  local failedTask
  local service, loader = loadingService({
    taskFailOnAdvance = function(task)
      if failedTask == nil then
        failedTask = task
        return failure
      end
      return nil
    end,
    taskImmediate = true,
  })
  service:openMap(11, { purpose = "browse" })
  service:setViewport(16, 16, 1, 1)
  service:update()
  Assert.equal(service:snapshot().status.state, "failed", "the first generation records its staged failure")

  local beginsAtFailure = #loader.begins
  pcall(service.update, service)
  Assert.equal(#loader.begins, beginsAtFailure, "a failed generation does not implicitly begin replacement work")

  local failedGeneration = service.requestGeneration
  service:openMap(11, { purpose = "browse", rememberedCursor = { fieldX = 18, fieldZ = 16 } })
  service:setViewport(18, 16, 1, 1)
  local retry = service:snapshot()
  Assert.equal(retry.status.state, "pending", "reopening the same map starts a new request")
  Assert.isTrue(retry.initialCursor.generation > failedGeneration, "explicit retry receives a fresh generation")
  Assert.equal(retry.initialCursor.fieldX, 18, "explicit retry uses its fresh remembered cursor")
  local guard = 0
  while service:snapshot().status.state ~= "ready" and guard < 20 do
    service:update()
    guard = guard + 1
  end
  Assert.equal(service:snapshot().status.state, "ready", "the explicit same-map retry can become ready")
  Assert.equal(#loader.begins, beginsAtFailure + 1, "one new map task begins only after explicit retry")
  Assert.equal(assert(loader.tasks[1]).releases, 1, "the original failed task stays released exactly once")
  service:dispose()
end

function T.tests.uncovered_door_failure_retains_map_identity_and_typed_diagnostic_context()
  local failure = Errors.new(
    FieldErrors.MAP_PROP_UNCOVERED_DOOR,
    "door tile (9,1) nearest placement is 9.01387818866 tiles away (beyond 5)",
    { x = 9, z = 1, nearestDistance = 9.01387818866 }
  )
  local service = loadingService({ taskFailOnAdvance = failure })
  openOutside(service, 11)
  service:update()

  local snapshot = service:snapshot()
  Assert.equal(snapshot.mapId, 11, "the failed request retains its map identity")
  Assert.equal(snapshot.status.state, "failed", "the typed door error remains a loader failure")
  Assert.equal(
    snapshot.status.reason,
    Errors.format(failure),
    "the status preserves the original typed code and context"
  )
  Assert.isTrue(snapshot.status.reason:find(FieldErrors.MAP_PROP_UNCOVERED_DOOR, 1, true) ~= nil)
  Assert.isTrue(snapshot.status.reason:find("nearestDistance=9.01387818866", 1, true) ~= nil)
  Assert.isNil(service.runtimeMap, "a failed map is not published as loaded")

  service:dispose()
end

function T.tests.an_immediately_ready_task_publishes_in_one_update()
  local service, loader = loadingService({ taskImmediate = true })
  openOutside(service, 11)
  service:update()

  Assert.equal(#loader.begins, 1, "preparation stages its map work through a loader task")
  Assert.equal(#loader.loads, 0, "staged preparation never uses the synchronous load")
  local finishes = 0
  for _, task in ipairs(loader.tasks) do
    finishes = finishes + task.finishes
  end
  Assert.equal(finishes, 0, "staged preparation never finishes a task synchronously")
  local snapshot = service:snapshot()
  Assert.equal(snapshot.mapId, 11, "the ready task publishes its map in one update")
  Assert.equal(snapshot.status.state, "ready", "the ready task reaches ready in one update")
  service:dispose()
end

function T.tests.repeated_updates_progress_a_pending_closure_to_ready()
  local service, _ = loadingService({ readyAfterRequests = 2, taskImmediate = true })
  openOutside(service, 11)

  service:update()
  Assert.equal(service:snapshot().status.state, "pending", "an unready closure stays pending")
  service:update()
  Assert.equal(service:snapshot().status.state, "pending", "polling keeps a pending closure pending")
  service:update()
  local snapshot = service:snapshot()
  Assert.equal(snapshot.status.state, "ready", "a ready closure publishes through repeated updates")
  Assert.equal(snapshot.mapId, 11, "the verified map publishes once its closure is ready")
  service:dispose()
end

function T.tests.same_map_viewport_changes_keep_the_pending_map_task()
  local service, loader = loadingService({ taskReadyAtAdvances = 4, consumePerAdvance = 1 })
  openOutside(service, 11)
  service:update()
  Assert.equal(#loader.begins, 1, "preparation stages its map work through a loader task")
  local first = loader.tasks[1]
  local generationBeforePan = service:snapshot().generation

  service:setViewport(OUTSIDE_CENTER + 1, OUTSIDE_CENTER, 1, 1)
  service:setViewport(OUTSIDE_CENTER + 1, OUTSIDE_CENTER, 2, 2)
  Assert.isTrue(service:snapshot().generation ~= generationBeforePan, "panning and resizing invalidate tile freshness")

  service:update()
  service:update()
  service:update()
  Assert.equal(#loader.begins, 1, "tile freshness changes never restart the pending map task")
  Assert.equal(first.releases, 0, "the same-map task is never released for a viewport change")
  Assert.equal(first.takes, 1, "the same pending task eventually publishes its map")
  local snapshot = service:snapshot()
  Assert.equal(snapshot.mapId, 11, "the same map publishes after viewport changes")
  Assert.equal(snapshot.status.state, "ready", "the same map reaches ready after viewport changes")
  service:dispose()
end

function T.tests.one_update_shares_a_single_work_budget_between_map_and_coverage()
  local service, loader = loadingService({
    taskReadyAtAdvances = 1,
    consumePerAdvance = 5,
    outdoor = true,
    coverageReadyAtAdvances = 99,
    coverageConsumePerAdvance = 3,
  })
  openOutside(service, 11)
  local prepare = service._prepareAt
  local preparationConsumed
  function service:_prepareAt(fieldX, fieldZ)
    local ready, consumed = prepare(self, fieldX, fieldZ)
    preparationConsumed = consumed
    return ready, consumed
  end
  service:update()

  local mapTask = loader.tasks[1]
  Assert.equal(#loader.coverageBegins, 1, "outdoor preparation stages its coverage work through a task")
  Assert.equal(#loader.blockingCoverages, 0, "staged preparation never builds coverage through the blocking call")
  local coverageTask = loader.coverageTasks[1]
  Assert.equal(preparationConsumed, 8, "map and coverage preparation report their combined work")
  Assert.equal(mapTask.consumedTotal, 5, "the map reports the work it consumed")
  Assert.equal(
    coverageTask.advanceArgs[1],
    8 - mapTask.consumedTotal,
    "coverage receives only the budget the map left over"
  )
  Assert.isTrue(
    mapTask.consumedTotal + coverageTask.consumedTotal <= 8,
    "one update spends no more than the single location budget"
  )
  Assert.equal(service:snapshot().status.state, "pending", "a pending replacement coverage keeps the viewport pending")
  service:dispose()
end

function T.tests.one_update_shares_preparation_and_visible_classification_work()
  local service = loadingService({ taskImmediate = true })
  openOutside(service, 11)
  service:setViewport(OUTSIDE_CENTER, OUTSIDE_CENTER, 20, 20)

  local prepare = service._prepareAt
  function service:_prepareAt(fieldX, fieldZ)
    local ready = prepare(self, fieldX, fieldZ)
    Assert.isTrue(ready, "the test preparation is ready")
    return ready, 5
  end
  local classify = service._classifyVisible
  local classificationBudget
  function service:_classifyVisible(maxWorkUnits)
    classificationBudget = maxWorkUnits
    return classify(self, maxWorkUnits)
  end
  local classificationAdvances = 0
  local advanceTile = service._advanceTileClassification
  function service:_advanceTileClassification(task, maxVisits)
    classificationAdvances = classificationAdvances + 1
    return advanceTile(self, task, maxVisits)
  end

  service:update()

  Assert.equal(classificationBudget, 3, "visible classification receives only preparation's remaining work")
  Assert.equal(classificationAdvances, 384, "visible classification spends only the remaining tile-position budget")
  Assert.equal(service:_classifyVisible(2), 1, "visible classification reports one unit for the remaining tiles")
  Assert.equal(classificationAdvances, 400, "remaining visible positions finish inside their bounded work unit")
  service:dispose()
end

function T.tests.stale_coverage_anchor_releases_once_and_never_publishes()
  local service, loader = loadingService({
    taskImmediate = true,
    outdoor = true,
    coverageReadyAtAdvances = 3,
    coverageConsumePerAdvance = 1,
  })
  service:openMap(11)
  service:setViewport(16, 16, 1, 1)
  service:update()
  Assert.equal(#loader.begins, 1, "preparation stages its map work through a loader task")
  Assert.equal(#loader.coverageBegins, 1, "outdoor preparation stages its coverage work through a task")

  service:setViewport(48, 16, 1, 1)
  service:update()
  service:update()
  service:update()

  Assert.equal(#loader.coverageBegins, 2, "the new anchor stages its own coverage task")
  local stale, current = loader.coverageTasks[1], loader.coverageTasks[2]
  Assert.equal(stale.releases, 1, "the superseded anchor task releases exactly once")
  Assert.equal(stale.takes, 0, "the superseded anchor result is never taken")
  Assert.equal(current.takes, 1, "only the current anchor takes its result")
  Assert.equal(service.coverage.anchorX, 1, "only the current anchor publishes")
  Assert.equal(service.coverage.anchorZ, 0, "only the current anchor publishes")
  Assert.equal(#loader.begins, 1, "an anchor change never restarts the settled map task")
  Assert.equal(service:snapshot().status.state, "ready", "the current anchor reaches ready")
  service:dispose()
end

function T.tests.replacement_coverage_publishes_without_waiting_for_tile_work()
  local service, loader = loadingService({
    taskImmediate = true,
    outdoor = true,
    coverageReadyAtAdvances = 3,
    coverageConsumePerAdvance = 1,
  })
  openOutside(service, 11)
  local guard = 0
  while service:snapshot().status.state ~= "ready" and guard < 20 do
    service:update()
    guard = guard + 1
  end
  Assert.equal(service:snapshot().status.state, "ready", "the original coverage and facts are published")
  local oldCoverage = assert(service.coverage)
  local oldEvents = assert(service.objectEvents)

  service:setViewport(48, 16, 1, 1)
  service:update()
  Assert.isTrue(service.coverage == oldCoverage, "a pending replacement keeps the prior coverage published")
  Assert.equal(oldCoverage.releases, 0, "a pending replacement does not release prior coverage")
  Assert.isTrue(service.objectEvents == oldEvents, "a pending replacement keeps prior selected-map facts")
  Assert.isNil(service.candidateCoverage, "an unready replacement stays out of the candidate slot")

  guard = 0
  while service.coverage == oldCoverage and guard < 20 do
    service:update()
    guard = guard + 1
  end
  local candidate = assert(loader.coverages[2], "the replacement coverage is acquired through a staged task")
  Assert.isTrue(service.coverage == candidate, "the replacement coverage publishes once ready")
  Assert.equal(oldCoverage.releases, 1, "the prior coverage releases after replacement")
  Assert.isTrue(service.objectEvents == oldEvents, "selected-map facts survive the coverage replacement")
  Assert.equal(service.coverage.anchorX, 1, "only the current anchor publishes")
  Assert.equal(service.coverage.anchorZ, 0, "only the current anchor publishes")
  Assert.equal(service:snapshot().status.state, "ready", "the current anchor reaches ready")
  service:dispose()
end

function T.tests.failed_replacement_coverage_retains_the_prior_window()
  local service, loader = loadingService({
    taskImmediate = true,
    outdoor = true,
    coverageImmediate = true,
    coverageConsumePerAdvance = 1,
  })
  openOutside(service, 11)
  local guard = 0
  while service:snapshot().status.state ~= "ready" and guard < 20 do
    service:update()
    guard = guard + 1
  end
  local retainedCoverage = assert(service.coverage)
  local retainedEvents = assert(service.objectEvents)

  local failure = Errors.new("CANDIDATE_COVERAGE_FAILED", "replacement coverage failed")
  local beginCoverage = loader.beginPhysicalCoverage
  function loader:beginPhysicalCoverage(runtimeMap, position)
    local task = beginCoverage(self, runtimeMap, position)
    function task:takeResult()
      error(failure, 0)
    end
    return task
  end

  service:setViewport(48, 16, 1, 1)
  service:update()
  Assert.equal(service:snapshot().status.state, "failed", "candidate coverage failure is observable")
  Assert.isTrue(service.coverage == retainedCoverage, "coverage failure preserves prior coverage")
  Assert.equal(retainedCoverage.releases, 0, "coverage failure retains prior coverage ownership")
  Assert.isTrue(service.objectEvents == retainedEvents, "coverage failure preserves prior event facts")
  Assert.isNil(service.candidateCoverage, "failed candidate coverage is discarded")
  local beginsAtFailure = #loader.coverageBegins
  service:update()
  Assert.equal(service:snapshot().status.state, "failed", "candidate failure remains terminal")
  Assert.equal(#loader.coverageBegins, beginsAtFailure, "failed candidate work is not staged again")
  service:dispose()
  Assert.equal(retainedCoverage.releases, 1, "disposal releases retained coverage exactly once")
end

function T.tests.resolve_observes_pending_work_without_advancing_it()
  local service, loader = loadingService({ taskReadyAtAdvances = 3, consumePerAdvance = 1 })
  service:openMap(11)
  service:setViewport(10, 10, 1, 1)
  service:update()
  local generation = service:snapshot().generation
  local advancesBefore = loader.tasks[1].advances
  local beginsBefore = #loader.begins

  local placement, pendingStatus = service:resolve(11, 10, 10, generation)
  Assert.isNil(placement, "resolution against pending preparation returns no placement")
  Assert.equal(pendingStatus.state, "pending", "resolution reports pending without doing staged work")
  Assert.equal(loader.tasks[1].advances, advancesBefore, "resolution advances no map work")
  Assert.equal(#loader.begins, beginsBefore, "resolution begins no new map work")

  service:update()
  service:update()
  Assert.equal(service:snapshot().status.state, "ready", "repeated updates finish preparation")
  local final, readyStatus = service:resolve(11, 10, 10, service:snapshot().generation)
  Assert.notNil(final, "resolution returns the normal placement once preparation is ready")
  Assert.equal(readyStatus.state, "ready", "resolution reports ready once preparation is ready")
  Assert.equal(final.mapId, 11, "the placement keeps the resolved map")
  Assert.equal(final.fieldX, 10, "the placement keeps the resolved field position")
  Assert.equal(final.fieldZ, 10, "the placement keeps the resolved field position")
  service:dispose()
end

function T.tests.real_loader_and_coverage_need_repeated_bounded_updates()
  local service = realOutdoorService()
  service:openMap(0)
  service:setViewport(80, 80, 1, 1)
  service:update()

  local first = service:snapshot()
  Assert.equal(first.status.state, "pending", "one bounded update cannot finish real map and coverage work")
  Assert.isNil(service.coverage, "no synchronously built coverage appears after one update")

  local guard = 0
  while service:snapshot().status.state ~= "ready" and guard < 120 do
    service:update()
    guard = guard + 1
  end
  local final = service:snapshot()
  Assert.equal(final.status.state, "ready", "repeated bounded updates finish real preparation")
  Assert.notNil(service.coverage, "staged coverage publishes a real physical window")
  Assert.notNil(service.loader:get(0), "the real loader published the prepared map")
  Assert.isTrue(#final.tiles > 0, "the ready viewport classifies its tiles")
  for _, tile in ipairs(final.tiles) do
    Assert.isTrue(tile.state ~= "pending", "real preparation classifies every visible tile")
  end
  service:dispose()
end

function T.tests.first_outdoor_preparation_acquires_the_cell_index_inside_staged_map_work()
  local hooks = {
    indexLoads = 0,
    indexLoadsAtBegin = nil,
    mapTaskBegun = false,
    coverageBegun = false,
    cellPending = true,
    updateConsumed = 0,
  }
  local service = buildRealOutdoorService(hooks)
  local loader = service.loader

  local assetsReady, assetsFailure = loader:requestMapAssets(0, "required")
  Assert.isTrue(assetsReady, "destination-only demand reports ready once its assets are ready")
  Assert.isNil(assetsFailure, "destination-only demand reports no failure")
  Assert.equal(hooks.indexLoads, 0, "destination-only demand never reads the cell index")

  service:openMap(0)
  service:setViewport(80, 80, 1, 1)
  hooks.updateConsumed = 0
  service:update()
  Assert.isTrue(hooks.mapTaskBegun, "preparation stages its map work through a loader task")
  Assert.equal(hooks.indexLoadsAtBegin, 0, "no index load precedes staged map work")
  Assert.isTrue(hooks.indexLoads >= 1, "staged map work acquires the cell index")
  Assert.isFalse(hooks.coverageBegun, "no coverage begins before the map publishes")
  Assert.isTrue(hooks.updateConsumed <= 8, "one update spends no more than the single location budget")

  local guard = 0
  while service.runtimeMap == nil and guard < 120 do
    hooks.updateConsumed = 0
    service:update()
    Assert.isTrue(hooks.updateConsumed <= 8, "every map-staging update stays within budget")
    guard = guard + 1
  end
  Assert.notNil(service.runtimeMap, "bounded updates publish the staged runtime map")
  Assert.equal(service:snapshot().status.state, "pending", "a pending cell closure holds preparation pending")
  Assert.isFalse(hooks.coverageBegun, "no coverage begins while the full closure is pending")

  hooks.cellPending = false
  guard = 0
  while service:snapshot().status.state ~= "ready" and guard < 120 do
    hooks.updateConsumed = 0
    service:update()
    Assert.isTrue(hooks.updateConsumed <= 8, "every coverage-staging update stays within budget")
    guard = guard + 1
  end
  local final = service:snapshot()
  Assert.equal(final.status.state, "ready", "repeated bounded updates finish real preparation")
  Assert.notNil(service.coverage, "staged coverage publishes a real physical window")
  Assert.notNil(loader:get(0), "the real loader published the prepared map")
  service:dispose()
end

function T.tests.owned_seed_ignores_foreign_cells_and_names_a_descriptorless_map()
  local service, loader = loadingService({ taskImmediate = true, coverageImmediate = true, outdoor = true })
  local ok, err = xpcall(function()
    local ownedCells = {
      { x = 5, z = 7, mapHeaderId = 11 },
      { x = 6, z = 7, mapHeaderId = 11 },
    }
    function loader:mapCellDomain(mapId)
      local cells = {
        ownedCells[1],
        { x = 90, z = 90, mapHeaderId = 22 },
        ownedCells[2],
        { x = 7, z = 7, mapHeaderId = 0 },
      }
      local index = 0
      local domain = {}
      function domain:advance(maxVisits)
        local visited, selected = 0, {}
        while visited < maxVisits and index < #cells do
          index = index + 1
          selected[#selected + 1] = cells[index]
          visited = visited + 1
        end
        return visited, selected, index >= #cells
      end
      return domain
    end
    service:openMap(11, { purpose = "browse" })
    local seed, updates = nil, 0
    while updates < 30 do
      service:update()
      updates = updates + 1
      local cursor = service:snapshot().initialCursor
      if cursor ~= nil and cursor.state == "seeded" then
        seed = cursor
        break
      end
    end
    Assert.notNil(seed, "a map with owned cells publishes a map-owned seed")
    local seedCellX, seedCellZ = math.floor(seed.fieldX / 32), math.floor(seed.fieldZ / 32)
    local owned = false
    for _, cell in ipairs(ownedCells) do
      if cell.x == seedCellX and cell.z == seedCellZ then
        owned = true
      end
    end
    Assert.isTrue(owned, "foreign and filler headers never supply the browsing seed")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end

  local empty, emptyLoader = loadingService({ taskImmediate = true, coverageImmediate = true, outdoor = true })
  local emptyOk, emptyErr = xpcall(function()
    function emptyLoader:mapCellDomain(mapId)
      local done = false
      local domain = {}
      function domain:advance(maxVisits)
        done = true
        return 0, {}, true
      end
      return domain
    end
    empty:openMap(11, { purpose = "browse" })
    local cursor, updates = nil, 0
    while updates < 30 do
      empty:update()
      updates = updates + 1
      cursor = empty:snapshot().initialCursor
      if cursor ~= nil and cursor.state ~= "pending" then
        break
      end
    end
    Assert.notNil(cursor, "a descriptorless map finishes seed discovery")
    Assert.equal(cursor.state, "unavailable", "no owned cell is an ordinary preview state")
    Assert.equal(cursor.reason, "no_owned_cells", "the miss names its cause instead of guessing coordinates")
    Assert.isNil(cursor.fieldX, "a descriptorless miss publishes no fabricated coordinate")
    Assert.isNil(cursor.fieldZ, "a descriptorless miss publishes no fabricated coordinate")
  end, debug.traceback)
  empty:dispose()
  if not emptyOk then
    error(emptyErr, 0)
  end
end

function T.tests.relocated_save_publishes_through_the_session_without_a_second_map_check()
  local Controller = require("app.src.saveeditor.SaveEditorController")
  local State = require("app.src.saveeditor.SaveEditorState")
  local LocationServiceModule = require("app.src.saveeditor.SaveEditorLocationService")
  local controller = Controller.new()
  local saves = {}
  local placement = {
    mapId = 11,
    fieldX = 10,
    fieldZ = 12,
    surfaceId = 3,
    worldY = 0,
    terrainDependencyHash = "loading-fixture",
  }
  local staged = {
    revision = 7,
    location = placement,
    locationChanged = true,
  }
  local session = {
    snapshot = function()
      return staged
    end,
    save = function(_, hasUnappliedDraft)
      saves[#saves + 1] = hasUnappliedDraft
      return { ok = true }
    end,
  }
  local state = setmetatable({
    status = "ready",
    controller = controller,
    session = session,
    dependencies = {
      cacheFs = {
        loadLua = function()
          return nil
        end,
      },
      world = structuralWorld(),
      savedObjects = { actors = {} },
    },
    derivedAssets = {},
    valueEditor = nil,
    monDraft = nil,
    errorMessage = nil,
    closeRequest = nil,
    onResult = function() end,
  }, State)

  local constructions = 0
  local originalNew = LocationServiceModule.new
  LocationServiceModule.new = function(...)
    constructions = constructions + 1
    return originalNew(...)
  end
  local savedOk
  local ok, saveError = pcall(function()
    savedOk = state:_save(false)
  end)
  LocationServiceModule.new = originalNew

  Assert.isTrue(ok, "the relocated save runs without raising through a verifier")
  if not ok then
    error(saveError, 0)
  end
  Assert.isTrue(savedOk, "a relocated save publishes synchronously through the session transaction")
  Assert.equal(#saves, 1, "the relocated save invokes the session transaction exactly once")
  Assert.equal(constructions, 0, "saving never opens a second destination service")
  Assert.isNil(state.errorMessage, "the direct save reports no destination drift")
  Assert.deepEqual(staged.location, placement, "the saved placement keeps all six accepted fields")
end

function T.tests.owned_cell_walk_shares_the_update_budget()
  local service, loader = loadingService({ taskImmediate = true, coverageImmediate = true, outdoor = true })
  local ok, err = xpcall(function()
    local budgets = {}
    function loader:mapCellDomain(mapId)
      local cells = {}
      for index = 1, 300 do
        cells[index] = { x = index, z = 0, mapHeaderId = mapId }
      end
      local cursor = 0
      local domain = {}
      function domain:advance(maxVisits)
        budgets[#budgets + 1] = maxVisits
        local visited, selected = 0, {}
        while visited < maxVisits and visited < 4 and cursor < #cells do
          cursor = cursor + 1
          selected[#selected + 1] = cells[cursor]
          visited = visited + 1
        end
        return visited, selected, cursor >= #cells
      end
      return domain
    end
    service:openMap(11, { purpose = "browse" })
    local seed, updates = nil, 0
    while updates < 200 do
      service:update()
      updates = updates + 1
      local current = service:snapshot().initialCursor
      if current ~= nil and current.state == "seeded" then
        seed = current
        break
      end
    end
    Assert.notNil(seed, "a large owned domain still publishes a map-owned seed")
    Assert.isTrue(#budgets > 1, "a large domain walks across several bounded updates")
    for _, budget in ipairs(budgets) do
      Assert.isTrue(budget <= 1024, "one domain advance never exceeds the shared per-update visit budget")
    end
    local seedCellX = math.floor(seed.fieldX / 32)
    Assert.isTrue(seedCellX >= 1 and seedCellX <= 300, "the seed stays inside the owned descriptor range")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.viewport_tiles_classify_once_their_window_publishes()
  local service, loader = loadingService({
    outdoor = true,
    taskImmediate = true,
    coverageImmediate = true,
  })
  openOutside(service, 11)
  local ok, err = xpcall(function()
    service:update()
    Assert.equal(
      service:snapshot().status.state,
      "ready",
      "an exact destination request reaches ready without neighboring event reads"
    )
    local window = assert(service.coverage)
    function window:containsGlobal(fieldX, fieldZ)
      return fieldX >= 70000 and fieldX < 70032 and fieldZ >= 70000 and fieldZ < 70032
    end
    local classifications = 0
    local beginClassification = service._beginTileClassification
    function service:_beginTileClassification(fieldX, fieldZ)
      classifications = classifications + 1
      return beginClassification(self, fieldX, fieldZ)
    end
    local placement, resolution = service:resolve(11, 16, 16, service:snapshot().generation)
    Assert.isNil(placement, "a point outside the published window is not a destination")
    Assert.equal(resolution.reason, "outside_map", "uncovered points keep the coverage reason")
    Assert.equal(classifications, 0, "an uncovered point classifies no tiles against a stale window")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.large_selected_map_event_index_publishes_with_its_map()
  local service, loader = loadingService({ outdoor = true, taskImmediate = true, coverageImmediate = true })
  local eventCount = 4096
  for eventIndex = 1, eventCount do
    loader.runtime.fieldData.events.objects[eventIndex] = {
      objectEventId = eventIndex,
      movementType = "stationary",
      x = 10000 + eventIndex,
      z = 10000,
      xRange = 0,
      yRange = 0,
    }
  end
  openOutside(service, 11)
  local ok, err = xpcall(function()
    service:update()
    Assert.equal(#assert(service.objectEvents), eventCount, "the selected-map index publishes with its map")
    Assert.equal(service:snapshot().status.state, "ready", "selected-map facts need no incremental cross-map staging")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.replaced_map_and_manual_pan_cannot_receive_a_late_initial_cursor()
  local service = loadingService({ taskImmediate = true })
  local firstResult
  local ok, err = xpcall(function()
    service:openMap(11, { purpose = "browse" })
    service:setViewport(16, 16, 1, 1)
    service:update()
    firstResult = service:snapshot().initialCursor
    Assert.notNil(firstResult, "the active browse generation publishes or tracks its survey")

    service:openMap(22, { purpose = "browse" })
    service:setViewport(1040, 2064, 1, 1)
    service:update()
    local replacement = service:snapshot().initialCursor
    Assert.notNil(replacement, "the replacement browse request has its own cursor result")
    Assert.equal(replacement.mapId, 22, "a late result from the old map cannot publish into the replacement")
    Assert.isTrue(replacement.generation ~= firstResult.generation, "replacement requests have distinct generations")

    service:setViewport(1050, 2064, 1, 1)
    local manuallyPanned = { fieldX = service.centerX, fieldZ = service.centerZ }
    service:update()
    replacement = service:snapshot().initialCursor
    Assert.notNil(replacement, "manual navigation leaves the active request observable")
    Assert.equal(replacement.mapId, 22, "manual navigation cannot revive the superseded map result")
    Assert.deepEqual(
      { fieldX = service.centerX, fieldZ = service.centerZ },
      manuallyPanned,
      "a completed suggestion cannot overwrite a user's manual pan"
    )
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.closure_failure_releases_hint_state_and_stays_terminal()
  local service, loader = loadingService({
    outdoor = true,
    taskImmediate = true,
    coverageImmediate = true,
  })
  service:openMap(11, { purpose = "browse" })
  local ok, err = xpcall(function()
    local seed, guard = nil, 0
    while guard < 30 do
      service:update()
      guard = guard + 1
      local cursor = service:snapshot().initialCursor
      if cursor ~= nil and cursor.state == "seeded" then
        seed = cursor
        break
      end
    end
    seed = assert(seed, "seed discovery finishes before viewport closure work")
    Assert.isNil(service.seedDomain, "the completed domain walk releases its iterator")
    Assert.notNil(service.ownedCells, "owned cells are retained for the local hint")

    local failure = Errors.new("CELL_CLOSURE_FAILED", "hint closure fixture failure")
    local requestLocation = loader.requestLocation
    function loader:requestLocation(mapId, fieldX, fieldZ, urgency)
      if fieldX == seed.fieldX and fieldZ == seed.fieldZ then
        return false, failure
      end
      return requestLocation(self, mapId, fieldX, fieldZ, urgency)
    end
    service:setViewport(seed.fieldX, seed.fieldZ, 1, 1)
    service:update()

    local view = service:snapshot()
    Assert.equal(view.status.state, "failed", "viewport closure failure is not overwritten with pending")
    Assert.isTrue(
      (view.status.reason or ""):find("hint closure fixture failure", 1, true) ~= nil,
      "failure reason is retained"
    )
    Assert.equal(view.initialCursor.state, "failed", "failed preparation publishes a terminal cursor")
    Assert.isNil(service.seedDomain, "failure releases the domain walk")
    Assert.isNil(service.ownedCells, "failure releases discovered cells")
    Assert.isNil(service.hint, "failure releases the pending hint")

    service:openMap(11, { purpose = "browse" })
    local reseeded, retries = nil, 0
    while retries < 30 do
      service:update()
      retries = retries + 1
      local cursor = service:snapshot().initialCursor
      if cursor ~= nil and cursor.state == "seeded" then
        reseeded = cursor
        break
      end
    end
    Assert.notNil(reseeded, "reopening after a failure rearms seed discovery")
    Assert.notNil(service.ownedCells, "reopening rebuilds the owned cells")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.indoor_seed_publishes_without_a_cell_domain()
  local service, loader = loadingService({ taskImmediate = true })
  loader.mapCellDomain = nil
  local ok, err = xpcall(function()
    service:openMap(11, { purpose = "browse" })
    local seed, updates = nil, 0
    while updates < 10 do
      service:update()
      updates = updates + 1
      local cursor = service:snapshot().initialCursor
      if cursor ~= nil and cursor.state == "seeded" then
        seed = cursor
        break
      end
    end
    Assert.notNil(seed, "a small indoor map seeds from its collision bounds alone")
    Assert.isTrue(
      seed.fieldX >= 0 and seed.fieldX < 64 and seed.fieldZ >= 0 and seed.fieldZ < 64,
      "the indoor seed stays inside the exact collision rectangle"
    )
    Assert.equal(service:snapshot().status.state, "pending", "seeding alone never claims preparation is ready")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.exact_verification_prepares_only_its_requested_point()
  local service, loader = loadingService({ taskImmediate = true })
  local ok, err = xpcall(function()
    service:openMap(11, { purpose = "verify" })
    service:setViewport(16, 16, 1, 1)
    service:update()

    local view = service:snapshot()
    Assert.equal(view.status.state, "ready", "the exact destination reaches normal prepared status")
    Assert.notNil(service:tileStatus(16, 16), "the requested destination has ordinary placement facts")
    Assert.isNil(view.initialCursor, "an exact destination verification does not create a whole-map browse survey")
    Assert.equal(#loader.begins, 1, "point verification prepares only its requested logical map")
    Assert.equal(#loader.coverageBegins, 0, "indoor point verification does not acquire unrelated physical coverage")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.resolving_an_off_cursor_tile_runs_its_own_placement_classification()
  local service = loadingService({ taskImmediate = true })
  local ok, err = xpcall(function()
    service:openMap(11, {
      purpose = "browse",
      rememberedCursor = { fieldX = 16, fieldZ = 16 },
    })
    service:setViewport(16, 16, 1, 1)
    service:update()

    local view = service:snapshot()
    Assert.deepEqual(
      { fieldX = view.initialCursor.fieldX, fieldZ = view.initialCursor.fieldZ },
      { fieldX = 16, fieldZ = 16 },
      "the prepared preview cursor is distinct from the requested tile"
    )
    local classified
    local classify = service._classify
    function service:_classify(fieldX, fieldZ)
      classified = { fieldX = fieldX, fieldZ = fieldZ }
      return classify(self, fieldX, fieldZ)
    end

    local placement, status = service:resolve(11, 17, 16, view.generation)

    Assert.deepEqual(classified, { fieldX = 17, fieldZ = 16 }, "resolution classifies the requested off-cursor tile")
    Assert.equal(status.state, "ready", "the safe neighboring tile is accepted by placement policy")
    Assert.deepEqual(
      { mapId = placement.mapId, fieldX = placement.fieldX, fieldZ = placement.fieldZ },
      { mapId = 11, fieldX = 17, fieldZ = 16 },
      "the accepted placement preserves the tapped coordinates"
    )
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.remembered_cursor_is_revalidated_without_starting_a_browse_survey()
  local service = loadingService({ taskImmediate = true })
  local ok, err = xpcall(function()
    service:openMap(11, {
      purpose = "browse",
      rememberedCursor = { fieldX = 16, fieldZ = 16 },
    })
    local requestGeneration = assert(service:snapshot().initialCursor).generation
    service:setViewport(16, 16, 1, 1)
    service:update()

    local view = service:snapshot()
    Assert.isNil(service.survey, "remembered-point preparation does not start a whole-map survey")
    Assert.isNil(service.surveyDomain, "remembered-point preparation does not enumerate the map domain")
    Assert.equal(view.status.state, "ready", "remembered-point preparation reaches normal ready state")
    Assert.deepEqual(view.initialCursor, {
      state = "ready",
      mapId = 11,
      generation = requestGeneration,
      factsRevision = service.factsRevision,
      fieldX = 16,
      fieldZ = 16,
    }, "the remembered point is revalidated and returned as the active initial cursor")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.unavailable_remembered_cursor_is_classified_without_survey()
  local service = loadingService({ taskImmediate = true })
  local ok, err = xpcall(function()
    service:openMap(11, {
      purpose = "browse",
      rememberedCursor = { fieldX = 100, fieldZ = 16 },
    })
    service:setViewport(16, 16, 1, 1)
    service:update()

    local view = service:snapshot()
    Assert.equal(view.status.state, "ready", "an unavailable preview does not prevent map preparation")
    Assert.equal(view.initialCursor.state, "unavailable", "the remembered point is classified unavailable")
    Assert.equal(view.initialCursor.reason, "wrong_logical_map", "the point keeps its placement reason")
    Assert.isNil(service.survey, "an unavailable remembered point still skips whole-map survey")
    Assert.isNil(service.surveyDomain, "an unavailable remembered point does not enumerate the map domain")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.remembered_point_coverage_does_not_replace_the_requested_viewport()
  local service, loader = loadingService({
    outdoor = true,
    taskImmediate = true,
    coverageImmediate = true,
  })
  local ok, err = xpcall(function()
    service:openMap(11, {
      purpose = "browse",
      rememberedCursor = { fieldX = 16, fieldZ = 16 },
    })
    service:setViewport(48, 16, 1, 1)

    local guard = 0
    while service:snapshot().status.state ~= "ready" and guard < 12 do
      service:update()
      guard = guard + 1
    end

    local view = service:snapshot()
    Assert.equal(view.status.state, "ready", "the remembered point and requested viewport both prepare")
    Assert.equal(view.initialCursor.state, "ready", "the remembered point remains revalidated")
    Assert.equal(view.initialCursor.fieldX, 16, "the initial cursor retains its remembered coordinate")
    Assert.equal(service.coverage.anchorX, 1, "published coverage follows the requested viewport")
    Assert.equal(#loader.coverageBegins, 2, "point and viewport anchors receive separate staged preparation")
    Assert.isNil(service.survey, "remembered navigation does not start a whole-map survey")
    Assert.equal(view.tiles[1].fieldX, 48, "the returned tile window remains centered on the requested viewport")
    Assert.equal(view.tiles[1].state, "selectable", "the requested viewport tile has prepared placement facts")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.browse_suggestion_generation_stays_bound_to_its_request()
  local service = loadingService({ taskImmediate = true })
  local ok, err = xpcall(function()
    service:openMap(11, { purpose = "browse" })
    local requestGeneration = assert(service:snapshot().initialCursor).generation
    service:setViewport(16, 16, 1, 1)

    local updates = 0
    while
      (service:snapshot().initialCursor.state == "pending" or service:snapshot().initialCursor.state == "seeded")
      and updates < 100
    do
      service:update()
      updates = updates + 1
    end

    local result = assert(service:snapshot().initialCursor)
    Assert.isTrue(updates < 100, "the bounded indoor seed and hint complete in the fixture")
    Assert.equal(result.state, "ready", "the fixture has selectable tiles")
    Assert.equal(
      result.generation,
      requestGeneration,
      "the suggestion generation identifies its browse request, not later publication epochs"
    )
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.selected_map_trigger_index_answers_without_per_tile_scans()
  local service, loader = loadingService({
    outdoor = true,
    taskImmediate = true,
    coverageImmediate = true,
  })
  local ok, err = xpcall(function()
    local warps, coordinates = {}, {}
    for index = 1, 140 do
      warps[index] = { x = 3000 + index, z = 3000 }
      coordinates[index] = { x = 4000 + index, z = 4000, width = 1, height = 1 }
    end
    warps[#warps + 1] = { x = 20, z = 20 }
    coordinates[#coordinates + 1] = { x = 24, z = 20, width = 2, height = 2 }
    loader.runtime.fieldData.events.warps = warps
    loader.runtime.fieldData.events.coordinates = coordinates
    local metadataBegins = 0
    function loader:beginLogicalMetadata(mapId)
      metadataBegins = metadataBegins + 1
      error("selected-map checks never load neighboring logical metadata", 2)
    end
    service:openMap(11, { purpose = "browse" })
    service:setViewport(16, 16, 8, 8)
    service:update()

    local generation = service:snapshot().generation
    local _, warpStatus = service:resolve(11, 20, 20, generation)
    Assert.equal(warpStatus.reason, "warp", "a covered selected-map warp refuses placement")
    local _, farWarp = service:resolve(11, 3001, 3000, service:snapshot().generation)
    Assert.equal(farWarp.reason, "warp", "an uncovered warp refuses without demanding its window")
    local _, triggerStatus = service:resolve(11, 25, 21, service:snapshot().generation)
    Assert.equal(triggerStatus.reason, "coordinate_trigger", "a trigger interior refuses placement")
    local _, edge = service:resolve(11, 26, 20, service:snapshot().generation)
    Assert.equal(edge.state, "ready", "coordinate triggers keep half-open rectangle edges")
    local _, free = service:resolve(11, 22, 22, service:snapshot().generation)
    Assert.equal(free.state, "ready", "an ordinary covered tile stays selectable beside many triggers")
    Assert.equal(metadataBegins, 0, "trigger checks never census neighboring maps")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.duplicate_source_rows_block_only_their_exact_tiles()
  local service, loader = loadingService({ taskImmediate = true })
  local sourceEvent = {
    objectEventId = 7,
    movementType = "stationary",
    x = 10,
    z = 10,
    xRange = -1,
    yRange = -1,
    eventFlag = 0,
  }
  local repeatedEvent = {
    objectEventId = 7,
    movementType = "stationary",
    x = 10,
    z = 10,
    xRange = -1,
    yRange = -1,
    eventFlag = 0,
  }
  local secondFootprint = {
    objectEventId = 7,
    movementType = "stationary",
    x = 11,
    z = 10,
    xRange = -1,
    yRange = -1,
    eventFlag = 1,
  }
  loader.runtime.fieldData.events.objects = { sourceEvent, repeatedEvent, secondFootprint }
  service:openMap(11, { purpose = "browse" })
  service:setViewport(10, 10, 1, 1)

  local ok, err = pcall(function()
    for _ = 1, 100 do
      service:update()
      if service:snapshot().status.state == "ready" and service.objectEvents ~= nil then
        break
      end
    end
    Assert.equal(service:snapshot().status.state, "ready", "the selected map reaches ready state")
    Assert.equal(#assert(service.objectEvents), 3, "selected-map events are borrowed without deduplication")
    Assert.equal(service:_classify(10, 10).reason, "possible_actor", "the repeated source tile stays reserved")
    Assert.equal(service:_classify(11, 10).reason, "possible_actor", "the second footprint stays reserved")
    Assert.isTrue(service:_classify(12, 10).selectable, "an unrelated safe tile remains selectable")
  end)
  service:dispose()
  Assert.isTrue(ok, "duplicate source event rows must not throw during map browse: " .. tostring(err))
end

function T.tests.saved_actor_current_and_action_endpoints_block_exact_tiles()
  local actors = {
    {
      actorId = "object:7",
      mapId = 11,
      objectEventId = 7,
      sourceMovementType = "stationary",
      movementType = "stationary",
      fieldX = 30,
      fieldZ = 30,
    },
    {
      actorId = "object:9",
      mapId = 11,
      objectEventId = 9,
      sourceMovementType = "stationary",
      movementType = "wander_around",
      fieldX = 40,
      fieldZ = 40,
      action = {
        owner = "autonomous",
        kind = "walk",
        direction = "north",
        start = { fieldX = 41, fieldZ = 40 },
        destination = { fieldX = 42, fieldZ = 40 },
        progressTicks = 0,
      },
    },
    {
      actorId = "object:3",
      mapId = 22,
      objectEventId = 3,
      sourceMovementType = "stationary",
      movementType = "stationary",
      fieldX = 50,
      fieldZ = 50,
    },
  }
  local service = Service.new({
    cacheFs = {
      loadLua = function()
        return nil
      end,
    },
    world = structuralWorld(),
    derivedAssets = {},
    savedObjects = { actors = actors },
  })
  local loader = fakeLoader({ taskImmediate = true })
  service.loader = loader
  loader.runtime.fieldData.events.objects = {
    { objectEventId = 7, movementType = "stationary", x = 10, z = 10, xRange = 0, yRange = 0 },
  }
  local ok, err = xpcall(function()
    service:openMap(11, { purpose = "browse" })
    service:setViewport(30, 30, 1, 1)
    local guard = 0
    while service:snapshot().status.state ~= "ready" and guard < 40 do
      service:update()
      guard = guard + 1
    end
    Assert.equal(service:snapshot().status.state, "ready", "the selected map prepares with saved actors")
    local function reasonAt(fieldX, fieldZ)
      local _, status = service:resolve(11, fieldX, fieldZ, service:snapshot().generation)
      return status
    end
    Assert.equal(reasonAt(10, 10).reason, "possible_actor", "the exact source tile stays reserved")
    Assert.equal(reasonAt(30, 30).reason, "possible_actor", "a saved current tile stays reserved")
    Assert.equal(reasonAt(41, 40).reason, "possible_actor", "an action start tile stays reserved")
    Assert.equal(reasonAt(42, 40).reason, "possible_actor", "an action destination tile stays reserved")
    local _, free = service:resolve(11, 50, 50, service:snapshot().generation)
    Assert.equal(free.state, "ready", "another map's actor never reserves this map's tiles")
    local _, between = service:resolve(11, 31, 30, service:snapshot().generation)
    Assert.equal(between.state, "ready", "tiles between known points stay selectable")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.location_snapshot_returns_detached_records()
  local service, loader = loadingService({ taskImmediate = true })
  local ok, err = xpcall(function()
    service:openMap(11, { purpose = "verify" })
    service:setViewport(16, 16, 1, 1)
    service:update()
    Assert.equal(service:snapshot().status.state, "ready", "the fixture preparation completes")
    local first = service:snapshot()
    Assert.isTrue(#first.tiles > 0, "the ready viewport publishes its tiles")
    first.tiles[1].state = "corrupted"
    first.tiles[1].fieldX = -1
    first.status.state = "corrupted"
    local second = service:snapshot()
    Assert.isTrue(second.tiles ~= first.tiles, "snapshots never share their tile storage")
    Assert.equal(second.tiles[1].state, "selectable", "mutating a snapshot never leaks into service state")
    Assert.equal(second.tiles[1].fieldX, 16, "mutating a snapshot never moves service coordinates")
    Assert.equal(second.status.state, "ready", "mutating a snapshot never changes service status")
    Assert.equal(service:tileStatus(16, 16).selectable, true, "direct tile reads stay intact")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.indoor_outside_permission_is_rejected_before_field_coordinate_conversion()
  local service, loader = loadingService({ taskImmediate = true })
  loader.runtime.fieldRegion.cells[1].collision.width = 32
  loader.runtime.fieldRegion.cells[1].collision.height = 32
  function loader.runtime.collision:containsLocal(localX, localZ)
    return localX >= 0 and localX < 32 and localZ >= 0 and localZ < 32
  end
  service:openMap(11, { purpose = "browse" })
  service:setViewport(32, 7, 1, 1)

  local ok, err = pcall(function()
    for _ = 1, 100 do
      service:update()
      if service:snapshot().status.state == "ready" and service.objectEvents ~= nil then
        break
      end
    end
    local view = service:snapshot()
    Assert.equal(view.status.state, "ready", "outside visible coordinates do not fail the map request")
    local visible = service:tileStatus(32, 7)
    Assert.equal(visible.state, "unavailable", "visible out-of-permission tiles are classified normally")
    Assert.equal(visible.reason, "outside_map", "visible classification retains the outside-map reason")
    local outside, outsideStatus = service:resolve(11, 32, 7, view.generation)
    Assert.isNil(outside, "an outside permission tile is not a destination")
    Assert.equal(outsideStatus.state, "unavailable", "out-of-coverage is a normal tile outcome")
    Assert.equal(outsideStatus.reason, "outside_map", "out-of-coverage retains the policy reason")
    local inside, insideStatus = service:resolve(11, 31, 7, view.generation)
    Assert.equal(insideStatus.state, "ready", "the neighboring covered point uses ordinary resolution")
    Assert.notNil(inside, "strict conversion remains available for a valid neighbor")
  end)
  service:dispose()
  Assert.isTrue(ok, "out-of-coverage tiles must not escape through FieldCoordinates: " .. tostring(err))
end

function T.tests.unfamiliar_outdoor_browse_starts_from_an_owned_map_cell()
  local service, loader = loadingService({ taskImmediate = true, coverageImmediate = true, outdoor = true })
  local ok, err = xpcall(function()
    service.world.maps[1].worldOriginX = 10000
    service.world.maps[1].worldOriginZ = 10000
    local ownedCells = {
      { x = 5, z = 7, mapHeaderId = 11 },
      { x = 6, z = 7, mapHeaderId = 11 },
      { x = 5, z = 8, mapHeaderId = 11 },
    }
    function loader:mapCellDomain(mapId)
      local cells = {}
      for _, cell in ipairs(ownedCells) do
        cells[#cells + 1] = cell
      end
      cells[#cells + 1] = { x = 90, z = 90, mapHeaderId = 22 }
      local index = 0
      local domain = {}
      function domain:advance(maxVisits)
        local visited, selected = 0, {}
        while visited < maxVisits and index < #cells do
          index = index + 1
          selected[#selected + 1] = cells[index]
          visited = visited + 1
        end
        return visited, selected, index >= #cells
      end
      return domain
    end
    local dummyRequests = 0
    local requestLocation = loader.requestLocation
    function loader:requestLocation(mapId, fieldX, fieldZ, urgency)
      if fieldX == 10016 and fieldZ == 10016 then
        dummyRequests = dummyRequests + 1
      end
      return requestLocation(self, mapId, fieldX, fieldZ, urgency)
    end

    service:openMap(11, { purpose = "browse" })
    local seed, updates = nil, 0
    while updates < 60 do
      service:update()
      updates = updates + 1
      local cursor = service:snapshot().initialCursor
      if cursor ~= nil and cursor.state == "seeded" then
        seed = cursor
        break
      end
    end
    Assert.notNil(seed, "an unfamiliar outdoor map publishes a map-owned seed without a full-tile census")
    Assert.isTrue(updates <= 10, "the owned-cell seed arrives promptly without classifying the map")
    local seedCellX, seedCellZ = math.floor(seed.fieldX / 32), math.floor(seed.fieldZ / 32)
    local owned = false
    for _, cell in ipairs(ownedCells) do
      if cell.x == seedCellX and cell.z == seedCellZ then
        owned = true
      end
    end
    Assert.isTrue(owned, "the seed lies inside a physical cell owned by the selected map")
    Assert.isFalse(
      seed.fieldX == 10016 and seed.fieldZ == 10016,
      "the seed is never the misleading structural origin offset"
    )
    Assert.equal(dummyRequests, 0, "no destination coverage is demanded for the dummy origin coordinate")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.small_indoor_and_hollow_outdoor_previews_start_inside_real_map_bounds()
  local indoor, indoorLoader = loadingService({ taskImmediate = true })
  local indoorOk, indoorErr = xpcall(function()
    indoorLoader.runtime.fieldRegion.cells[1].collision.width = 7
    indoorLoader.runtime.fieldRegion.cells[1].collision.height = 9
    indoorLoader.runtime.coordinateOrigin = { x = 100, z = 200 }
    indoor:openMap(11, { purpose = "browse" })
    local seed, updates = nil, 0
    while updates < 30 do
      indoor:update()
      updates = updates + 1
      local cursor = indoor:snapshot().initialCursor
      if cursor ~= nil and cursor.state == "seeded" then
        seed = cursor
        break
      end
    end
    Assert.notNil(seed, "a small indoor map publishes a map-owned seed without a full-tile census")
    Assert.isTrue(
      seed.fieldX >= 100 and seed.fieldX <= 106 and seed.fieldZ >= 200 and seed.fieldZ <= 208,
      "the indoor seed stays inside the exact collision rectangle"
    )
  end, debug.traceback)
  indoor:dispose()
  Assert.isTrue(indoorOk, "small indoor preview must not escape through map bounds: " .. tostring(indoorErr))

  local outdoor, outdoorLoader = loadingService({ taskImmediate = true, coverageImmediate = true, outdoor = true })
  local outdoorOk, outdoorErr = xpcall(function()
    outdoor.world.maps[1].worldOriginX = 352
    outdoor.world.maps[1].worldOriginZ = 352
    local ring = {
      { x = 10, z = 10, mapHeaderId = 11 },
      { x = 11, z = 10, mapHeaderId = 11 },
      { x = 12, z = 10, mapHeaderId = 11 },
      { x = 10, z = 11, mapHeaderId = 11 },
      { x = 12, z = 11, mapHeaderId = 11 },
      { x = 10, z = 12, mapHeaderId = 11 },
      { x = 11, z = 12, mapHeaderId = 11 },
      { x = 12, z = 12, mapHeaderId = 11 },
    }
    function outdoorLoader:mapCellDomain(mapId)
      local cells = {}
      for _, cell in ipairs(ring) do
        cells[#cells + 1] = cell
      end
      cells[#cells + 1] = { x = 60, z = 60, mapHeaderId = 22 }
      local index = 0
      local domain = {}
      function domain:advance(maxVisits)
        local visited, selected = 0, {}
        while visited < maxVisits and index < #cells do
          index = index + 1
          selected[#selected + 1] = cells[index]
          visited = visited + 1
        end
        return visited, selected, index >= #cells
      end
      return domain
    end
    outdoor:openMap(11, { purpose = "browse" })
    local seed, updates = nil, 0
    while updates < 30 do
      outdoor:update()
      updates = updates + 1
      local cursor = outdoor:snapshot().initialCursor
      if cursor ~= nil and cursor.state == "seeded" then
        seed = cursor
        break
      end
    end
    Assert.notNil(seed, "a hollow outdoor map publishes a map-owned seed without a full-tile census")
    local seedCellX, seedCellZ = math.floor(seed.fieldX / 32), math.floor(seed.fieldZ / 32)
    local onRing = false
    for _, cell in ipairs(ring) do
      if cell.x == seedCellX and cell.z == seedCellZ then
        onRing = true
      end
    end
    Assert.isTrue(onRing, "the outdoor seed uses an owned descriptor instead of the empty centroid hole")
    Assert.isFalse(seedCellX == 11 and seedCellZ == 11, "the outdoor seed never opens in the unowned gap")
  end, debug.traceback)
  outdoor:dispose()
  Assert.isTrue(outdoorOk, "hollow outdoor preview must not escape through map bounds: " .. tostring(outdoorErr))
end

function T.tests.selected_map_checks_use_only_selected_map_events()
  local service, loader = loadingService({ taskImmediate = true, coverageImmediate = true, outdoor = true })
  local ok, err = xpcall(function()
    function loader.runtime:release() end
    local metadataBegins = {}
    local beginLogicalMetadata = loader.beginLogicalMetadata
    function loader:beginLogicalMetadata(mapId)
      metadataBegins[#metadataBegins + 1] = mapId
      return beginLogicalMetadata(self, mapId)
    end
    local beginPhysicalCoverage = loader.beginPhysicalCoverage
    function loader:beginPhysicalCoverage(runtimeMap, position)
      local task = beginPhysicalCoverage(self, runtimeMap, position)
      local takeResult = task.takeResult
      function task:takeResult()
        local coverage = takeResult(self)
        coverage.cells["neighbor"] = { descriptor = { x = 2, z = 0, mapHeaderId = 22 } }
        return coverage
      end
      return task
    end
    loader.runtime.fieldData.events.objects = {
      {
        mapId = 11,
        objectEventId = 7,
        movementType = "wander_around",
        x = 50,
        z = 50,
        xRange = 2,
        yRange = 2,
        eventFlag = 0,
      },
    }
    loader.runtime.fieldData.events.warps = { { x = 32, z = 32 } }
    loader.runtime.fieldData.events.coordinates = { { x = 40, z = 40, width = 2, height = 2 } }
    local terrainSamples = 0
    local function countTerrainSamples(terrain)
      for _, method in ipairs({ "candidatesAt", "sampleHeight", "sample" }) do
        local original = terrain[method]
        terrain[method] = function(terrainSelf, ...)
          terrainSamples = terrainSamples + 1
          return original(terrainSelf, ...)
        end
      end
    end

    service:openMap(11, { purpose = "browse" })
    service:setViewport(32, 32, 8, 8)
    local guard = 0
    while (service.objectEvents == nil or service.coverage == nil) and guard < 40 do
      service:update()
      guard = guard + 1
    end
    Assert.notNil(service.objectEvents, "the selected map publishes its event index without a full-tile census")
    Assert.notNil(service.coverage, "the selected map publishes its viewport coverage")
    countTerrainSamples(service.coverage.region.terrain)
    local view = service:snapshot()
    Assert.equal(#metadataBegins, 0, "opening a map never loads neighboring logical source events for actor preflight")

    local generation = view.generation
    local _, warpStatus = service:resolve(11, 32, 32, generation)
    Assert.equal(warpStatus.reason, "warp", "a selected-map warp still refuses placement")
    local _, triggerStatus = service:resolve(11, 41, 41, generation)
    Assert.equal(triggerStatus.reason, "coordinate_trigger", "a selected-map trigger interior still refuses placement")
    local _, boundaryStatus = service:resolve(11, 42, 40, generation)
    Assert.equal(boundaryStatus.state, "ready", "coordinate triggers keep half-open rectangle edges")
    local _, sourceStatus = service:resolve(11, 50, 50, generation)
    Assert.equal(sourceStatus.reason, "possible_actor", "the exact source tile remains reserved")
    local _, rangedStatus = service:resolve(11, 52, 50, generation)
    Assert.equal(rangedStatus.state, "ready", "a free tile inside a wander range is not reserved by speculation")

    local freeBefore = terrainSamples
    local placed, freeStatus = service:resolve(11, 33, 33, service:snapshot().generation)
    Assert.equal(freeStatus.state, "ready", "an ordinary tile resolves")
    Assert.notNil(placed, "an ordinary tile returns its placement")
    Assert.equal(terrainSamples - freeBefore, 2, "explicit activation samples the destination surface exactly once")
    -- One SurfaceResolver:resolve performs candidatesAt + sample on fixture terrain.
    local warpBefore = terrainSamples
    local _, _ = service:resolve(11, 32, 32, service:snapshot().generation)
    Assert.equal(terrainSamples - warpBefore, 0, "a trigger refusal never samples the terrain surface")

    service:setViewport(70, 20, 8, 8)
    for _ = 1, 15 do
      service:update()
    end
    Assert.equal(#metadataBegins, 0, "panning the viewport never starts a neighboring event census")
    local _, repanned = service:resolve(11, 50, 50, service:snapshot().generation)
    Assert.equal(repanned.reason, "possible_actor", "the exact occupancy index survives viewport movement")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.location_updates_report_only_observable_changes_and_isolate_requests()
  local service, loader = loadingService({ taskImmediate = true })
  local ok, err = xpcall(function()
    service:openMap(11, { purpose = "browse" })
    service:setViewport(16, 16, 1, 1)
    local first = service:update()
    Assert.isTrue(type(first) == "boolean", "location preparation reports whether its visible snapshot changed")
    Assert.isTrue(first, "opening a map is an observable change")
    local guard = 0
    while service:snapshot().status.state == "pending" and guard < 100 do
      service:update()
      guard = guard + 1
    end
    Assert.equal(service:snapshot().status.state, "ready", "the fixture preparation completes")
    Assert.isFalse(service:update(), "a settled browser reports no observable change on idle updates")
    Assert.isFalse(service:update(), "repeated idle updates stay quiet")

    service:openMap(22, { purpose = "browse" })
    service:setViewport(1040, 2064, 1, 1)
    Assert.isTrue(service:update(), "replacing the map is an observable change")
    Assert.equal(service:snapshot().mapId, 22, "the replacement owns the browser")
    local _, stale = service:resolve(11, 16, 16, -1)
    Assert.equal(stale.state, "unavailable", "a stale request generation never resolves")
    Assert.equal(stale.reason, "stale_generation", "stale requests name their cause")
  end, debug.traceback)
  service:dispose()
  if not ok then
    error(err, 0)
  end

  local failing = loadingService({ requestError = Errors.new("MAP_PREPARATION_FAILED", "staged scene build failed") })
  local failingOk, failingErr = xpcall(function()
    failing:openMap(11, { purpose = "browse" })
    failing:setViewport(16, 16, 1, 1)
    Assert.isTrue(failing:update(), "a failed preparation publishes its terminal state exactly once")
    Assert.equal(failing:snapshot().status.state, "failed", "the failure state is terminal")
    Assert.isFalse(failing:update(), "a terminal failure settles instead of churning")
  end, debug.traceback)
  failing:dispose()
  Assert.isTrue(failingOk, "terminal failure reporting must not escape the update loop: " .. tostring(failingErr))
end

return T
