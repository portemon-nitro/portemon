-- Location map preparation advances through staged loader tasks the update loop owns.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
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

local function indoorRuntime()
  local collision = {}
  function collision:containsLocal()
    return true
  end
  function collision:getLocal()
    return { blocked = false, behavior = 0 }
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
        { matrixMemberId = 0, width = 2, height = 1, cells = { { x = 0, z = 0 }, { x = 1, z = 0 } } },
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
      error(script.taskFailOnAdvance, 0)
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
    runtime = indoorRuntime(),
  }
  if script.outdoor then
    local outdoor = indoorRuntime()
    outdoor.scene = { type = "outdoor" }
    loader.runtime = outdoor
  end
  function loader:requestLocation(mapId, fieldX, fieldZ, urgency)
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
  function loader:load(mapId)
    self.loads[#self.loads + 1] = mapId
    return self.runtime
  end
  function loader:definesMap(mapId)
    return mapId == 11 or mapId == 22
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
local function realOutdoorService()
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
            startHalfSeconds = 0,
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
  return Service.new({
    cacheFs = cacheFs,
    world = world,
    derivedAssets = {
      requestField = alwaysReady,
      requestLogicalField = alwaysReady,
      requestCell = alwaysReady,
      ensureField = alwaysReady,
      ensureLogicalField = alwaysReady,
      ensureCell = alwaysReady,
    },
    savedObjects = { actors = {} },
  })
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
  Assert.isTrue(
    service:snapshot().generation ~= generationBeforePan,
    "panning and resizing invalidate tile freshness"
  )

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
  service:update()

  local mapTask = loader.tasks[1]
  Assert.equal(#loader.coverageBegins, 1, "outdoor preparation stages its coverage work through a task")
  Assert.equal(
    #loader.blockingCoverages,
    0,
    "staged preparation never builds coverage through the blocking call"
  )
  local coverageTask = loader.coverageTasks[1]
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
  Assert.equal(
    service:snapshot().status.state,
    "pending",
    "a pending replacement coverage keeps the viewport pending"
  )
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
  Assert.equal(
    first.status.state,
    "pending",
    "one bounded update cannot finish real map and coverage work"
  )
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

return T
