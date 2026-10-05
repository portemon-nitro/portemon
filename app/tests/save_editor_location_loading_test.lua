-- Location map preparation advances through staged loader tasks the update loop owns.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
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
    terrain = {},
    terrainDependencyHash = "loading-fixture",
    fieldRegion = { cells = { { collision = { width = 64, height = 64 } } } },
    fieldData = { events = { objects = {}, warps = {}, coordinates = {} } },
  }
end

local function stagedTask(loader, mapId, script)
  local task = {
    mapId = mapId,
    advances = 0,
    advanceBudget = 0,
    releases = 0,
    finishes = 0,
    takes = 0,
  }
  function task:advance(workUnits)
    self.advances = self.advances + 1
    self.advanceBudget = self.advanceBudget + (workUnits or 0)
    if script.taskFailOnAdvance ~= nil then
      error(script.taskFailOnAdvance, 0)
    end
    return 0
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
    released = false,
    runtime = indoorRuntime(),
  }
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

return T
