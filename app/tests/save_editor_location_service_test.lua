-- Pending location reads lose authority on map switches and never publish save edits.

local Assert = require("tests.support.Assert")
local CollisionFixture = require("tests.support.CollisionFixture")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("app.tests.support.SaveEditorFixture")
local Session = require("app.src.saveeditor.SaveEditorSession")

local T = { tests = {} }

local function structuralWorld()
  local maps = {}
  local byId, bySymbol = {}, {}
  for index, mapId in ipairs({ 12, 13 }) do
    local symbol = "MAP_TEST_" .. tostring(mapId)
    maps[index] = {
      id = mapId,
      symbol = symbol,
      mapSection = "TEST_SECTION",
      mapSectionNativeId = 1,
      followMode = "ALLOW",
      worldOriginX = (index - 1) * 32,
      worldOriginZ = 0,
      matrix = { memberId = 0 },
    }
    byId[mapId] = index
    bySymbol[symbol] = mapId
  end
  return {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = maps,
    byId = byId,
    bySymbol = bySymbol,
    analysis = { mapHeaderCount = #maps, excluded = {} },
  }
end

local function cacheFs()
  return {
    loadLua = function(_, path)
      if path == FieldCellCache.indexPath() then
        return {
          schema = FieldCellCache.INDEX_SCHEMA,
          matrices = { { matrixMemberId = 0, width = 1, height = 1, cells = {} } },
        }
      end
      return nil, "fixture has no generated map payload"
    end,
  }
end

local function readyIndoorCacheFs()
  local files = {
    [FieldCellCache.indexPath()] = {
      schema = FieldCellCache.INDEX_SCHEMA,
      matrices = { { matrixMemberId = 0, width = 1, height = 1, cells = {} } },
    },
  }
  for index, mapId in ipairs({ 12, 13 }) do
    local symbol = "MAP_TEST_" .. tostring(mapId)
    local originX = (index - 1) * 32
    local events = { background = {}, objects = {}, warps = {}, coordinates = {} }
    if mapId == 12 then
      events.objects[1] = {
        objectEventId = 7,
        movementType = "walk_back_and_forth",
        x = 0,
        z = 0,
        xRange = -1,
        yRange = -1,
      }
    else
      events.objects[1] = {
        objectEventId = 8,
        movementType = "stationary",
        x = 32,
        z = 0,
        xRange = 0,
        yRange = 0,
      }
    end
    files[MapAssetCache.mapDir(mapId) .. "/scene.lua"] = {
      schema = MapAssetCache.SCENE_SCHEMA,
      mapId = mapId,
      mapSymbol = symbol,
      cameraType = 0,
      neighbors = {},
      buildingInstances = {},
      terrainAnimations = { textureSrt = false },
      collision = { file = MapAssetCache.collisionPath(mapId) },
      matrix = {
        width = 1,
        height = 1,
        x = 0,
        z = 0,
        worldOriginX = originX,
        worldOriginZ = 0,
      },
    }
    files[MapAssetCache.terrainPath(mapId)] = {
      schema = "g4-terrain-surfaces-v1",
      source = { bdhcSha1 = "indoor-test-" .. tostring(mapId) },
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
          walkable = true,
        },
      },
    }
    files[FieldMapDataCache.fieldPath(mapId)] = {
      schema = "g4-field-map-v10",
      initScripts = {},
      mapId = mapId,
      mapSymbol = symbol,
      cameraType = 0,
      transitionEnvironment = "building",
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
      events = events,
      music = { day = "SEQ_X", night = "SEQ_X", flagOverrides = {}, traversalOverrides = {} },
      soundplates = {},
    }
    files[MapAssetCache.collisionPath(mapId)] = CollisionFixture.asset(32, 32)
  end
  return {
    loadLua = function(_, path)
      return files[path]
    end,
    read = function(_, path)
      return files[path]
    end,
  }
end

function T.tests.pending_and_stale_map_requests_never_activate_or_change_the_session()
  local loaded, LocationService = pcall(require, "app.src.saveeditor.SaveEditorLocationService")
  Assert.isTrue(loaded, "the Location section must own a headless location reader")
  local fixture = Fixture.new()
  local session, sessionError = Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })
  Assert.isNil(sessionError)
  local before = fixture.copy(session:captureCandidate())
  local revision = session:revision()
  local readiness = { [12] = false, [13] = false }
  local requests = {}
  local retired = 0
  local host = {
    requestField = function(_, mapId, urgency)
      requests[#requests + 1] = { "field", mapId, urgency }
      return readiness[mapId]
    end,
    requestLogicalField = function(_, mapId, urgency)
      requests[#requests + 1] = { "logical", mapId, urgency }
      return readiness[mapId]
    end,
    requestCell = function(_, descriptor, urgency)
      requests[#requests + 1] = { "cell", descriptor.index, urgency }
      return false
    end,
    dispose = function()
      retired = retired + 1
    end,
    retire = function()
      retired = retired + 1
    end,
  }
  local service = LocationService.new({
    cacheFs = cacheFs(),
    world = structuralWorld(),
    derivedAssets = host,
    savedObjects = fixture.initial.world.objects,
  })
  local maps = service:listMaps()
  Assert.equal(#maps, 2, "the browser lists structural map records")
  Assert.equal(maps[1].mapId, 12)
  Assert.equal(maps[2].mapId, 13)

  service:openMap(12)
  service:setViewport(4, 4, 8, 6)
  service:update()
  local firstView = service:snapshot()
  Assert.equal(firstView.status.state, "pending", "cold map preparation remains visibly pending")
  local absent, pending = service:resolve(12, 4, 4, firstView.generation)
  Assert.isNil(absent, "a pending tile has no resolved placement")
  Assert.equal(pending.state, "pending", "resolving a cold tile does not invent empty collision data")
  Assert.equal(session:revision(), revision, "a pending destination cannot revise the Session")
  Assert.deepEqual(session:captureCandidate(), before, "browsing and a pending activation do not change the save")

  service:setViewport(40, 40, 8, 6)
  service:update()
  local pannedView = service:snapshot()
  Assert.equal(pannedView.status.state, "pending", "panning to an unprepared extent keeps the view pending")
  Assert.equal(pannedView.tiles[1].state, "pending", "unclassified cells do not become selectable while pending")

  service:openMap(13)
  service:setViewport(36, 4, 8, 6)
  readiness[12] = true
  service:update()
  local secondView = service:snapshot()
  Assert.equal(secondView.mapId, 13, "late map A readiness cannot replace the current map B view")
  Assert.equal(secondView.status.state, "pending", "map B still reports its own preparation state")
  local stalePlacement, staleStatus = service:resolve(12, 40, 40, pannedView.generation)
  Assert.isNil(stalePlacement, "a resolve started for map A has no authority after switching to map B")
  Assert.equal(staleStatus.reason, "stale_generation", "map switches revoke the prior generation")
  Assert.equal(session:revision(), revision, "late readiness cannot auto-select a destination")
  Assert.deepEqual(session:captureCandidate(), before, "late readiness cannot mutate the staged save")
  Assert.isTrue(#requests > 0, "the service requests data through the borrowed derived host")

  service:dispose()
  service:dispose()
  Assert.equal(retired, 0, "closing the location reader never retires the borrowed cache host")
  Assert.equal(session:revision(), revision, "disposing an unselected view leaves the Session untouched")
end

function T.tests.global_source_actor_coordinates_are_not_offset_twice()
  local LocationService = require("app.src.saveeditor.SaveEditorLocationService")
  local cache = readyIndoorCacheFs()
  local eventPath = FieldMapDataCache.fieldPath(13)
  local sourceMap = assert(cache:loadLua(eventPath))
  local sourceEvent = sourceMap.events.objects[1]
  local savedObjects = { actors = {} }
  local beforeActors = {
    actors = {},
  }
  local service = LocationService.new({
    cacheFs = cache,
    world = structuralWorld(),
    derivedAssets = {
      requestField = function() return true end,
      requestLogicalField = function() return true end,
      requestCell = function() return true end,
      ensureField = function() return true end,
      ensureLogicalField = function() return true end,
      ensureCell = function() return true end,
    },
    savedObjects = savedObjects,
  })

  service:openMap(13)
  service:setViewport(32, 0, 1, 1)
  service:update()
  local view = service:snapshot()
  Assert.equal(view.status.state, "ready", "the synthetic nonzero-origin map is prepared")
  local placement, resolution = service:resolve(13, 32, 0, view.generation)
  Assert.isNil(placement, "the global source actor coordinate cannot be selected")
  Assert.equal(resolution.state, "unavailable")
  Assert.equal(resolution.reason, "possible_actor", "the event is applied at its global coordinate")
  Assert.equal(sourceEvent.x, 32, "the source event x remains immutable")
  Assert.equal(sourceEvent.z, 0, "the source event z remains immutable")
  Assert.deepEqual(savedObjects, beforeActors, "analysis never mutates the saved actor snapshot")
  service:dispose()
end

function T.tests.indoor_unbounded_actor_extent_uses_central_collision_dimensions()
  local loaded, LocationService = pcall(require, "app.src.saveeditor.SaveEditorLocationService")
  Assert.isTrue(loaded, "the Location service reads indoor central collision dimensions")
  local host = {
    requestField = function()
      return true
    end,
    requestLogicalField = function()
      return true
    end,
    ensureField = function()
      return true
    end,
    ensureLogicalField = function()
      return true
    end,
  }
  local service = LocationService.new({
    cacheFs = readyIndoorCacheFs(),
    world = structuralWorld(),
    derivedAssets = host,
    savedObjects = { actors = {} },
  })
  service:openMap(12)
  service:setViewport(31, 31, 1, 1)
  service:update()
  local view = service:snapshot()
  Assert.equal(
    view.status.state,
    "ready",
    "indoor dimensions come from the central collision grid (" .. tostring(view.status.reason) .. ")"
  )
  Assert.equal(
    service:tileStatus(31, 31).reason,
    "possible_actor",
    "an unbounded source actor covers the last inclusive tile on both indoor axes"
  )
  service:dispose()
end

function T.tests.failed_retry_keeps_map_owner_and_active_action_is_destination_scoped()
  local loaded, LocationService = pcall(require, "app.src.saveeditor.SaveEditorLocationService")
  Assert.isTrue(loaded, "the Location service retries preparation without discarding its active map")
  local demand = { failure = nil }
  local host = {
    requestField = function()
      if demand.failure then
        return false, demand.failure
      end
      return true
    end,
    requestLogicalField = function()
      if demand.failure then
        return false, demand.failure
      end
      return true
    end,
    ensureField = function()
      return true
    end,
    ensureLogicalField = function()
      return true
    end,
  }
  local savedActor = {
    actorId = "object:7",
    mapId = 12,
    objectEventId = 7,
    sourceMovementType = "walk_back_and_forth",
    movementType = "walk_back_and_forth",
    fieldX = 0,
    fieldZ = 0,
    action = { kind = "walk" },
  }
  local service = LocationService.new({
    cacheFs = readyIndoorCacheFs(),
    world = structuralWorld(),
    derivedAssets = host,
    savedObjects = { actors = { ["object:7"] = savedActor } },
  })
  service:openMap(12)
  service:setViewport(31, 31, 1, 1)
  service:update()
  Assert.equal(service:snapshot().status.state, "ready", "the first indoor map owner becomes usable")
  Assert.equal(service:tileStatus(31, 31).reason, "actor_motion_active", "saved motion blocks its destination map")
  local retainedMap = assert(service.loader:get(12))
  local releaseCount = 0
  local loader = service.loader
  local releaseLoader = loader.release
  loader.release = function(owner)
    releaseCount = releaseCount + 1
    releaseLoader(owner)
  end

  demand.failure = "temporary field demand failure"
  service:setViewport(30, 30, 1, 1)
  service:update()
  Assert.equal(service:snapshot().status.state, "failed", "a failed request reports its error")
  Assert.equal(service.loader:get(12), retainedMap, "the failed request leaves the prior usable map owner resident")

  demand.failure = nil
  service:update()
  Assert.equal(service:snapshot().status.state, "ready", "retry restores the prior map view")
  service:openMap(13)
  service:setViewport(63, 31, 1, 1)
  service:update()
  local destinationView = service:snapshot()
  Assert.equal(destinationView.status.state, "ready", "a separate destination map remains browseable")
  local placement, status = service:resolve(13, 63, 31, destinationView.generation)
  Assert.notNil(placement, "motion on map 12 does not disable placement on map 13")
  Assert.equal(status.state, "ready")

  service:dispose()
  service:dispose()
  Assert.equal(releaseCount, 1, "the retained map owner is released once after repeated disposal")
end

function T.tests.failed_coverage_recenter_reports_an_error_and_keeps_the_previous_owner()
  local loaded, LocationService = pcall(require, "app.src.saveeditor.SaveEditorLocationService")
  Assert.isTrue(loaded, "the Location service reports failed physical coverage preparation")
  local service = LocationService.new({
    cacheFs = readyIndoorCacheFs(),
    world = structuralWorld(),
    derivedAssets = {
      requestField = function()
        return true
      end,
      requestLogicalField = function()
        return true
      end,
      ensureField = function()
        return true
      end,
      ensureLogicalField = function()
        return true
      end,
    },
    savedObjects = { actors = {} },
  })
  service:openMap(12)
  service:setViewport(31, 31, 1, 1)
  service:update()
  Assert.equal(service:snapshot().status.state, "ready")

  service.runtimeMap.scene.type = "outdoor"
  local recenterAttempts = 0
  local retainedCoverage
  retainedCoverage = {
    anchorX = 0,
    anchorZ = 0,
    index = { matrices = { { matrixMemberId = 0, cells = { { x = 1, z = 0 } } } } },
    containsGlobal = function()
      return false
    end,
    mapHeaderAt = function()
      return 12
    end,
    committedDescriptors = function()
      return { { mapHeaderId = 12, x = 1, z = 0 } }
    end,
    recenter = function()
      recenterAttempts = recenterAttempts + 1
      if recenterAttempts == 1 then
        error(Errors.new("TEST_COVERAGE_RETRY", "coverage could not be staged", {}))
      end
      retainedCoverage.anchorX = 1
    end,
    release = function() end,
  }
  service.coverage = retainedCoverage
  service:setViewport(63, 31, 1, 1)
  service.tileStatuses["63:31"] = { state = "selectable", selectable = true }

  local updateOk, updateError = pcall(service.update, service)
  Assert.isTrue(updateOk, "a structured recenter failure is displayed instead of escaping the service")
  Assert.isNil(updateError)
  Assert.equal(service:snapshot().status.state, "failed")
  Assert.isTrue(service:snapshot().status.reason:match("TEST_COVERAGE_RETRY") ~= nil)
  Assert.equal(service.coverage, retainedCoverage, "failed recenter retains the previously published coverage")
  Assert.equal(service:tileStatus(63, 31).state, "pending", "the failed view clears stale selectable tile classifications")

  service:update()
  Assert.equal(service:snapshot().status.state, "ready", "the next update retries the unchanged destination anchor")
  Assert.equal(recenterAttempts, 2)
  service:dispose()
end

return T
