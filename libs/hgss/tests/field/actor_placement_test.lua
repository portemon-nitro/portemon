-- Physical placement proposals stay equivalent while actor lifecycle stays
-- with its owners: spawn/adjacent/saved/trajectory endpoints, rejection
-- classification, save round trips, partner placement and recentering.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldActorPlacement = require("libs.hgss.src.actors.FieldActorPlacement")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRegion = require("libs.hgss.src.world.FieldRegion")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

-- Plate 0 is the ground; plate 1 is stacked four units above it on x >= 8.
-- Plate 2 duplicates plate 0's height over x 20..24 to force an exact tie.
local function terrain()
  return TerrainSurface.new({
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
      },
      {
        id = 1,
        minX = 8,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 4,
        slopeClass = "flat",
      },
      {
        id = 2,
        minX = 20,
        minZ = 0,
        maxX = 24,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
end

local function object(overrides)
  local event = {
    index = 0,
    objectEventId = 0,
    spriteId = 99,
    movementType = "stationary",
    type = 0,
    eventFlag = 0,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = 2,
    z = 3,
    y = 0,
  } --[[@as table<string, unknown>]]
  for key, value in pairs(overrides or {}) do
    rawset(event, key, value)
  end
  return event --[[@as FieldActorEvent]]
end

local function runtimeMap(objects, mapId)
  local map = {
    mapId = mapId or 61,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 40 and z >= 0 and z < 32
      end,
    },
    terrain = terrain(),
    mapSymbol = "test-map",
    sceneRuntime = nil,
    scene = {},
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 4,
    fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
  return map
end

local function fakeAssets(known)
  local assets = {
    references = {},
    knows = function(_, spriteId)
      return known[spriteId] == true
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced release of spriteId " .. spriteId)
      self.references[spriteId] = count - 1
    end,
  }
  return assets
end

local function enter(objects, opts)
  opts = opts or {}
  local assets = opts.assets or fakeAssets({ [99] = true, [34] = true, [20153] = true, [20154] = true })
  local eventState = opts.eventState or FieldEventState.new()
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  local map = opts.map or runtimeMap(objects)
  mgr:enterMap(map, eventState, opts.restoredObjects)
  return mgr, eventState, assets, map
end

local function endpointFields(endpoint)
  return {
    fieldX = endpoint.fieldX,
    fieldZ = endpoint.fieldZ,
    surfaceId = endpoint.surfaceId,
    cellKey = endpoint.cellKey,
    sourceSurfaceId = endpoint.sourceSurfaceId,
    resident = endpoint.resident,
  }
end

function T.spawn_surface_matches_the_live_actor_anchor()
  local events = { object({ x = 2, z = 3 }) }
  local mgr, _, _, map = enter(events)
  local actor = assert(mgr:getById("map:61:object:0"))

  local atSample = FieldActorPlacement.resolveSurfaceAt(map, 2, 3, 0, actor.actorId)
  Assert.equal(atSample.surfaceId, actor:getSurfaceId())
  Assert.equal(atSample.worldY, actor:getWorldPosition().y)

  local eventSample = FieldActorPlacement.resolveSurface(map, events[1], actor.actorId)
  Assert.notNil(eventSample)
  Assert.equal(assert(eventSample).surfaceId, actor:getSurfaceId())

  local projection = FieldActorPlacement.projectionFor(map, actor)
  Assert.equal(projection.fieldX, 2)
  Assert.equal(projection.fieldZ, 3)
  Assert.equal(projection.surfaceId, actor:getSurfaceId())
  Assert.equal(projection.cellKey, actor.cellKey)
  Assert.equal(projection.worldY, actor:getWorldPosition().y)
  Assert.isTrue(projection.resident)
  mgr:dispose()
end

function T.scripted_step_destination_matches_the_placement_endpoint()
  local mgr, _, _, map = enter({ object({ x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))

  local endpoint, blocked = FieldActorPlacement.resolveAdjacentDestination(map, actor, "east", false, false)
  Assert.isFalse(blocked)
  Assert.notNil(endpoint)
  Assert.deepEqual(endpointFields(assert(endpoint)), {
    fieldX = 3,
    fieldZ = 3,
    surfaceId = 0,
    cellKey = "0:0",
    sourceSurfaceId = nil,
    resident = true,
  })

  mgr:beginScriptedAction(actor.actorId, { action = "walk", direction = "east", speed = "normal" })
  local motion = assert(actor:scriptedMotionState())
  Assert.equal(motion.destFieldX, assert(endpoint).fieldX)
  Assert.equal(motion.destFieldZ, assert(endpoint).fieldZ)
  mgr:commitScriptedAction(actor.actorId)
  Assert.equal(actor:getFieldPosition().fieldX, 3)
  Assert.equal(assert(mgr:getAt(61, {
    fieldX = 3,
    fieldZ = 3,
    surfaceId = actor:getSurfaceId(),
  })), actor)
  mgr:dispose()
end

function T.distant_point_projects_without_residency()
  local map = runtimeMap({ object({ x = 2, z = 3 }) })
  map.coverage = {
    containsGlobal = function(_, x, z)
      return x >= 0 and x < 40 and z >= 0 and z < 32
    end,
  }
  local mgr, _, _, liveMap = enter(map.fieldData.events.objects, { map = map })
  local actor = assert(mgr:getById("map:61:object:0"))

  mgr:setPosition(actor.actorId, { fieldX = 100, fieldZ = 100 })
  Assert.equal(actor:getFieldPosition().fieldX, 100)
  local projection = FieldActorPlacement.projectionFor(liveMap, actor)
  Assert.isFalse(projection.resident)
  Assert.equal(projection.fieldX, 100)
  Assert.equal(projection.fieldZ, 100)

  local direct = FieldActorPlacement.projectEndpoint(liveMap, {
    fieldX = 100,
    fieldZ = 100,
    sourceEvent = { y = 0 },
    actorId = "probe:actor",
  })
  Assert.isFalse(direct.resident)
  Assert.equal(direct.fieldX, 100)
  Assert.equal(direct.fieldZ, 100)
  Assert.notNil(direct.worldX)
  Assert.notNil(direct.worldZ)
  mgr:dispose()
end

function T.waitable_step_outcome_leaves_occupancy_untouched()
  local probing = runtimeMap({ object({ x = 2, z = 3 }) })
  probing.probePhysicalCell = function()
    return nil
  end
  local mgr, _, _, map = enter(probing.fieldData.events.objects, { map = probing })
  local actor = assert(mgr:getById("map:61:object:0"))

  local endpoint, blocked = FieldActorPlacement.resolveAdjacentDestination(map, actor, "east", true, true)
  Assert.isNil(endpoint)
  Assert.isTrue(blocked)
  Assert.equal(actor:getFieldPosition().fieldX, 2)
  Assert.equal(
    assert(mgr:getAt(61, { fieldX = 2, fieldZ = 3, surfaceId = actor:getSurfaceId() })),
    actor
  )

  mgr:dispose()

  local edgeObjects = { object({ x = 31, z = 3 }) }
  local edgeMap = runtimeMap(edgeObjects)
  edgeMap.collision = {
    containsLocal = function(_, x, z)
      return x >= 0 and x < 32 and z >= 0 and z < 32
    end,
  }
  local edgeMgr = enter(edgeObjects, { map = edgeMap })
  local edgeActor = assert(edgeMgr:getById("map:61:object:0"))
  local outOfCoverage = Assert.throws(function()
    FieldActorPlacement.resolveAdjacentDestination(edgeMap, edgeActor, "east", false, false)
  end)
  Assert.isTrue(Errors.is(outOfCoverage), "expected a structured error")
  Assert.equal(outOfCoverage.code, "FIELD_COORDINATES_OUT_OF_COVERAGE")
  Assert.isTrue(FieldActorPlacement.isPlacementRejection(outOfCoverage))
  Assert.isTrue(FieldActorManager.isPlacementRejection(outOfCoverage))
  Assert.equal(edgeActor:getFieldPosition().fieldX, 31, "a rejected step moves nothing")
  edgeMgr:dispose()
end

function T.surface_identity_selects_stable_source_keys()
  local mgr, _, _, map = enter({ object({ x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))
  local state = actor:numericState()

  local kind, first, second = FieldActorPlacement.stableSurfaceIdentity(map, {
    fieldX = 2,
    fieldZ = 3,
    surfaceId = state.surfaceId,
  })
  Assert.equal(kind, "local")
  Assert.equal(first, state.surfaceId)

  local stableKind, stableFirst, stableSecond = FieldActorPlacement.stableSurfaceIdentity(map, {
    fieldX = 2,
    fieldZ = 3,
    surfaceId = state.surfaceId,
    cellKey = "0:0",
    sourceSurfaceId = 7,
  })
  Assert.equal(stableKind, "source")
  Assert.equal(stableFirst, "0:0")
  Assert.equal(stableSecond, 7)
  Assert.isTrue(
    FieldActorPlacement.samePhysicalCandidate(map, { fieldX = 2, fieldZ = 3, surfaceId = state.surfaceId }, {
      fieldX = 2,
      fieldZ = 3,
      surfaceId = state.surfaceId,
    })
  )
  Assert.isFalse(
    FieldActorPlacement.samePhysicalCandidate(map, { fieldX = 2, fieldZ = 3, surfaceId = state.surfaceId }, {
      fieldX = 3,
      fieldZ = 3,
      surfaceId = state.surfaceId,
    })
  )
  mgr:dispose()
end

function T.unclassifiable_surface_failures_are_not_waitable()
  local ambiguous = throwsCode("ACTOR_SURFACE_AMBIGUOUS", function()
    enter({ object({ x = 21, z = 3 }) })
  end)
  Assert.isFalse(FieldActorPlacement.isPlacementRejection(ambiguous))

  local missing = throwsCode("ACTOR_SURFACE_MISSING", function()
    enter({ object({ x = 35, z = 3 }) })
  end)
  Assert.isFalse(FieldActorPlacement.isPlacementRejection(missing))
  Assert.isFalse(FieldActorPlacement.isPlacementRejection("a plain string is never a placement outcome"))
  Assert.isFalse(FieldActorPlacement.isPlacementRejection(nil))
end

function T.proposals_are_fresh_and_leave_inputs_untouched()
  local mgr, _, _, map = enter({ object({ x = 2, z = 3 }) })
  local actor = assert(mgr:getById("map:61:object:0"))

  local first = FieldActorPlacement.projectionFor(map, actor)
  local second = FieldActorPlacement.projectionFor(map, actor)
  Assert.deepEqual(first, second)
  Assert.isTrue(first ~= second, "each proposal is a fresh table")
  first.fieldX = -999
  Assert.equal(second.fieldX, 2, "mutating one proposal must not touch another")

  local endpoint, _ = FieldActorPlacement.resolveAdjacentDestination(map, actor, "east", false, false)
  Assert.notNil(endpoint)
  Assert.equal(actor:getFieldPosition().fieldX, 2, "resolving a proposal must not move the actor")
  Assert.equal(
    assert(mgr:getAt(61, { fieldX = 2, fieldZ = 3, surfaceId = actor:getSurfaceId() })),
    actor
  )
  mgr:dispose()
end

function T.physical_proposal_does_not_commit_occupancy()
  local mgr = enter({
    object({ objectEventId = 0, x = 7, z = 3 }),
    object({ objectEventId = 1, x = 8, z = 3, spriteId = 34 }),
  })
  local mover = assert(mgr:getById("map:61:object:0"))
  local occupant = assert(mgr:getById("map:61:object:1"))
  local map = assert(mgr.maps[61]).runtimeMap

  local endpoint, blocked = FieldActorPlacement.resolveAdjacentDestination(map, mover, "east", false, false)
  Assert.isFalse(blocked)
  Assert.notNil(endpoint, "the physical tile is resolvable even though it is occupied")

  throwsCode("ACTOR_OCCUPANCY_CONFLICT", function()
    mgr:setPosition(mover.actorId, { fieldX = 8, fieldZ = 3 })
  end)
  Assert.equal(mover:getFieldPosition().fieldX, 7, "a rejected commit moves nothing")
  Assert.equal(
    assert(mgr:getAt(61, { fieldX = 8, fieldZ = 3, surfaceId = occupant:getSurfaceId() })),
    occupant
  )
  mgr:dispose()
end

function T.save_capture_round_trip_keeps_order_and_records()
  local events = {
    object({ objectEventId = 0, x = 2, z = 3 }),
    object({ objectEventId = 1, x = 5, z = 3, spriteId = 34 }),
  }
  local mgr = enter(events)
  mgr:setPosition("map:61:object:0", { fieldX = 4, fieldZ = 3 })
  local captured = mgr:captureObjects()
  local order = {}
  for _, actor in ipairs(mgr:actorsOf(61)) do
    order[#order + 1] = actor.actorId
  end

  local restoredMgr, _, _, restoredMap = enter(events, { restoredObjects = captured })
  local restored = restoredMgr:captureObjects()
  Assert.deepEqual(restored.actors, captured.actors)
  local restoredOrder = {}
  for _, actor in ipairs(restoredMgr:actorsOf(61)) do
    restoredOrder[#restoredOrder + 1] = actor.actorId
  end
  Assert.deepEqual(restoredOrder, order)
  local moved = assert(restoredMgr:getById("map:61:object:0"))
  Assert.equal(moved:getFieldPosition().fieldX, 4)
  Assert.equal(
    assert(restoredMgr:getAt(61, { fieldX = 4, fieldZ = 3, surfaceId = moved:getSurfaceId() })),
    moved
  )
  Assert.notNil(restoredMap)
  mgr:dispose()
  restoredMgr:dispose()
end

function T.partner_placement_and_recenter_stay_stable()
  local emptyMap = runtimeMap({})
  local mgr = enter({}, { map = emptyMap })
  Assert.isNil(mgr:partnerId())

  local installed = mgr:installPartner({
    numericId = 253,
    visualId = 20153,
    mapId = 61,
    fieldX = 2,
    fieldZ = 3,
    facing = "south",
  })
  Assert.equal(installed, "field:partner")
  Assert.equal(mgr:partnerId(), "field:partner")

  local updated = mgr:updatePartner({
    numericId = 253,
    visualId = 20154,
    mapId = 61,
    fieldX = 4,
    fieldZ = 3,
    facing = "south",
  })
  Assert.equal(updated, "field:partner")
  local partner = assert(mgr:getById("field:partner"))
  Assert.equal(partner:getFieldPosition().fieldX, 4)

  mgr:reconcilePhysicalWorld()
  Assert.equal(partner:getFieldPosition().fieldX, 4)
  Assert.equal(mgr:partnerId(), "field:partner")

  Assert.equal(mgr:clearPartner(), "field:partner")
  Assert.isNil(mgr:getById("field:partner"))
  Assert.isNil(mgr:partnerId())
  mgr:dispose()
end

function T.source_region_restore_uses_the_captured_surface()
  local events = { object({ x = 9, z = 3 }) }
  local sourceMap = runtimeMap(events)
  local region = FieldRegion.new(sourceMap.collision, terrain(), {}, "0:0", 0)
  sourceMap.collision = region.collision
  sourceMap.terrain = region.terrain
  sourceMap.fieldRegion = region
  local mgr = enter(events, { map = sourceMap })
  local actor = assert(mgr:getById("map:61:object:0"))
  Assert.equal(actor:getSurfaceId(), 0)

  mgr:setPosition(actor.actorId, { fieldX = 9, fieldZ = 3, worldY = 4 })
  Assert.equal(actor:getSourceSurfaceId(), 1)
  local captured = mgr:captureObjects()

  local restoredMgr = enter(events, { map = sourceMap, restoredObjects = captured })
  local restored = assert(restoredMgr:getById("map:61:object:0"))
  Assert.equal(restored:getSourceSurfaceId(), 1)
  Assert.equal(restored:getWorldPosition().y, 4)
  mgr:dispose()
  restoredMgr:dispose()
end

function T.placement_module_works_from_plain_facts()
  for key, value in pairs(FieldActorPlacement) do
    Assert.isTrue(type(value) == "function", "placement export " .. key .. " must be a pure operation")
  end
  Assert.isNil(FieldActorPlacement.new, "placement owns no lifetime")

  local map = runtimeMap({})
  local facts = {
    fieldX = 2,
    fieldZ = 3,
    hasWorldPosition = 0,
    hasSurfaceId = 0,
    hasSourceSurfaceId = 0,
  }
  local factActor = {
    numericState = function()
      return facts
    end,
    sourceEvent = { y = 0 },
    actorId = "probe:actor",
  }
  local endpoint, blocked =
    FieldActorPlacement.resolveAdjacentDestination(map, factActor, "east", false, false)
  Assert.isFalse(blocked)
  Assert.notNil(endpoint)
  Assert.equal(assert(endpoint).fieldX, 3)
  Assert.equal(assert(endpoint).fieldZ, 3)
  Assert.deepEqual(facts, {
    fieldX = 2,
    fieldZ = 3,
    hasWorldPosition = 0,
    hasSurfaceId = 0,
    hasSourceSurfaceId = 0,
  }, "placement must not mutate the actor facts it borrows")
end

return { tests = T }
