-- Script camera focus integration: the composed script path for the camera
-- target object index resolves through the real manager-backed adapter and
-- drives the standard movement task. While the focus is live it answers
-- script liveness and snapshots without entering the actor store; clearing
-- it releases the object index back to the existing missing-actor fault.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local MovementTask = require("libs.hgss.src.script.tasks.MovementTask")
---@cast MovementTask TaskImplementation
local MovementBarrierTask = require("libs.hgss.src.script.tasks.MovementBarrierTask")
---@cast MovementBarrierTask TaskImplementation
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

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
    },
  })
end

local function testMap(mapId)
  return {
    mapId = mapId or 61,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = terrain(),
    mapSymbol = "test-map",
    sceneRuntime = nil,
    scene = {},
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 4,
    fieldData = {
      events = {
        objects = {
          {
            index = 0,
            objectEventId = 0,
            spriteId = 99,
            movementType = "look_north",
            type = 0,
            eventFlag = 0,
            scriptId = 0,
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
          },
        },
        background = {},
        warps = {},
        coordinates = {},
      },
    },
    release = function() end,
    updateAnimated = function() end,
  }
end

local function manager()
  local mgr = FieldActorManager.new({
    assets = {
      knows = function(_, spriteId)
        return spriteId == 99
      end,
      acquire = function(_, spriteId)
        return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId), references = 1 }
      end,
      release = function() end,
    },
    policy = POLICY,
  })
  mgr:enterMap(testMap(61), FieldEventState.new())
  return mgr
end

local function playerFacade()
  return {
    position = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
  }
end

local function harness(actorWorld)
  local services = FakeServices.new()
  services.actors = actorWorld
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("movement", 1, MovementTask)
  taskRegistry:register("movement_barrier", 1, MovementBarrierTask)
  local scheduler = Scheduler.new({
    semantics = RuntimeValues,
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    scheduler = scheduler,
  }
end

local function script(id)
  return S.script({
    api = 1,
    id = id,
    steps = {
      { op = "camera_focus_set", fieldX = 10, fieldZ = 5 },
      S.applyMovement({
        actor = S.actorIndex(241),
        movement = { S.m.walk({ direction = "east", speed = "normal", tiles = 1 }) },
      }),
      S.waitMovement(),
      { op = "camera_focus_clear" },
      S.stop(),
    },
  })
end

function T.camera_focus_set_then_object_index_241_walk_completes_and_clears()
  local mgr = manager()
  local world = ScriptActorWorld.new(mgr, playerFacade())
  local h = harness(world)
  local resource = script("test.camera_focus_241")
  h.registry:installBase(resource.id, resource, "generated")
  local composed = assert(h.composition:effective(resource.id), "the focus script must compose")
  local instanceId = h.scheduler:createForeground(composed, nil, 100)

  h.scheduler:step(100, nil)
  Assert.isNil(
    h.services.events:eventFor("script.error", instanceId),
    "apply_movement on object index 241 must not fault while the camera focus is live"
  )

  local focusId = assert(mgr:cameraTargetId(), "the focus answers the camera-target path once set")
  Assert.equal(mgr:actorIdForMapIndex(241), focusId, "the focus answers the pinned object index")
  Assert.isTrue(world:exists(focusId), "the live focus passes the script liveness check")
  Assert.isNil(mgr:getById(focusId), "the focus never enters the actor store")

  local run = { instance = { scriptId = resource.id }, services = h.services }
  Assert.equal(
    RuntimeValues.requireActor(S.actorIndex(241), run),
    focusId,
    "the composed liveness guard resolves the pinned object index to the focus"
  )

  local snapshot = assert(world:snapshot(focusId), "the live focus has a script snapshot")
  Assert.equal(snapshot.actorId, focusId)
  Assert.equal(snapshot.position.fieldX, 10)
  Assert.equal(snapshot.position.fieldZ, 5)
  Assert.equal(snapshot.facing, "south")
  Assert.isFalse(snapshot.visible, "the script focus stays invisible")

  local npcId = assert(mgr:actorIdForMapIndex(0), "the map keeps its ordinary object")
  Assert.isTrue(world:exists(npcId), "store-backed actors keep their liveness")
  local npcPosition = assert(mgr:getPosition(npcId), "ordinary actors keep their position")
  Assert.isNil(npcPosition.worldX, "ordinary actors gain no fractional world pair")
  Assert.isNil(npcPosition.worldZ, "ordinary actors gain no fractional world pair")

  local committed = false
  local ended = false
  local tick = 100
  while tick < 220 and not ended do
    tick = tick + 1
    h.scheduler:step(tick, nil)
    local position = mgr:getPosition(focusId)
    if position ~= nil and position.fieldX == 11 then
      committed = true
    end
    local done = h.services.events:eventFor("script.ended", instanceId)
    if done ~= nil and done.completed then
      ended = true
    end
  end
  Assert.isTrue(committed, "the focus walk must commit its destination tile")
  Assert.isTrue(ended, "the script must run to its stop after the movement barrier")
  Assert.isNil(
    h.services.events:eventFor("script.error", instanceId),
    "the composed focus walk must complete without a script fault"
  )

  Assert.isNil(mgr:cameraTargetId(), "clearing releases the camera target")
  Assert.isNil(mgr:actorIdForMapIndex(241), "clearing releases the object index")
  Assert.isFalse(world:exists(focusId), "clearing releases script liveness")
  Assert.isNil(world:snapshot(focusId), "clearing releases the script snapshot")
  local err = Assert.throws(function()
    RuntimeValues.requireActor(S.actorIndex(241), run)
  end)
  Assert.isTrue(Errors.is(err), "a cleared focus reports the existing missing-actor fault")
  Assert.equal(err.code, "SCRIPT_ACTOR_NOT_FOUND")
  Assert.isTrue(world:exists(npcId), "clearing the focus keeps ordinary actors live")
  mgr:dispose()
end

return { tests = T }
