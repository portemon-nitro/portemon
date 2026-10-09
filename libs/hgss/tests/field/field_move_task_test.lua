-- Field-move execution acceptance: Cut/Strength/Smash/Flash run against live
-- actors and terrain through one scheduler task. The premise section pins the
-- current behavior this deliverable builds on (script hide stays solid, so
-- removal must change presence). The execution sections drive the
-- FieldMoveTask boundary with real collaborators and stay red until the
-- execution owner exists: no current owner can produce removal, pushes,
-- illumination, or single-owner admission at this boundary.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local FieldObjectSave = require("libs.hgss.src.save.FieldObjectSave")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

-- Structural port for the runtime under test: names exactly the exercised
-- boundary so helper-built subjects resolve their methods.
---@class FieldMoveRuntimePort
---@field queue fun(self: FieldMoveRuntimePort, request: table<string, unknown>): table<string, unknown>
---@field takePending fun(self: FieldMoveRuntimePort): table<string, unknown>
---@field discardPending fun(self: FieldMoveRuntimePort)
---@field plan fun(self: FieldMoveRuntimePort, request: table<string, unknown>): table<string, unknown>
---@field advance fun(self: FieldMoveRuntimePort, plan: table<string, unknown>): table<string, unknown>
---@field cancel fun(self: FieldMoveRuntimePort, plan: table<string, unknown>)
---@field clearTransient fun(self: FieldMoveRuntimePort)
---@field isBusy fun(self: FieldMoveRuntimePort): boolean
---@field tryStrengthPush fun(self: FieldMoveRuntimePort, snapshot: table<string, unknown>): table<string, unknown>

local CUT_FLAG = 100
local SMASH_FLAG = 101

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
    },
  })
end

local function objectEvent(overrides)
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
  return {
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

-- Map under test: a cut tree (sprite 86) east of the player start, a smash
-- rock (sprite 85) further east, a boulder (sprite 84) south of the player,
-- and an unrelated NPC. Coordinates are asymmetric so a swapped axis fails.
local function fieldObjects()
  return {
    objectEvent({ objectEventId = 0, spriteId = 86, eventFlag = CUT_FLAG, x = 6, z = 3, obstacleKind = "cut_tree" }),
    objectEvent({ objectEventId = 1, spriteId = 85, eventFlag = SMASH_FLAG, x = 9, z = 3, obstacleKind = "smash_rock" }),
    objectEvent({ objectEventId = 2, spriteId = 84, eventFlag = 0, x = 4, z = 6, obstacleKind = "strength_boulder" }),
    objectEvent({ objectEventId = 3, spriteId = 99, eventFlag = 0, x = 12, z = 10 }),
  }
end

local function openManager(map, eventState)
  local mgr = FieldActorManager.new({
    assets = fakeAssets({ [86] = true, [85] = true, [84] = true, [99] = true }),
    policy = POLICY,
  })
  mgr:enterMap(map, eventState, nil)
  return mgr
end

local function treeId()
  return "map:61:object:0"
end

local function rockId()
  return "map:61:object:1"
end

local function boulderId()
  return "map:61:object:2"
end

local function npcId()
  return "map:61:object:3"
end

local function context(overrides)
  local base = {
    badges = 0xFFFF,
    unionOrColosseum = false,
    mapSymbol = "test-map",
    mapId = 61,
    avatarMode = "walking",
    humanFollower = false,
    followingMon = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
    weatherId = 11,
    facingObstacle = nil,
    facingActor = nil,
    surfEdge = false,
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
    foggy = false,
    chatterOpen = false,
    fieldUse = {
      flyAllowed = false,
      teleportAllowed = false,
      escapeAllowed = false,
      flashUsable = true,
      alphChamber = false,
      icePathB2F = false,
      cave = true,
      unionOrColosseum = false,
    },
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

local function treeContext()
  return context({
    facingObstacle = "cut_tree",
    facingActor = { identity = treeId(), obstacleKind = "cut_tree", mapSymbol = "test-map", fieldX = 6, fieldZ = 3 },
  })
end

local function ports(manager, eventState, map, overrides)
  local weatherChanged = {}
  local reactions = {}
  local base = {
    actors = manager,
    events = eventState,
    maps = {
      current = function()
        return { symbol = "test-map", id = 61, fieldUse = { flashUsable = true, alphChamber = false } }
      end,
      runtimeMap = function()
        return map
      end,
    },
    player = {
      positionValue = { fieldX = 5, fieldZ = 3, worldY = 0 },
      facingValue = "east",
      position = function(self)
        return {
          fieldX = self.positionValue.fieldX,
          fieldZ = self.positionValue.fieldZ,
          worldY = self.positionValue.worldY,
        }
      end,
      facing = function(self)
        return self.facingValue
      end,
      beginScriptedAction = function(self, action)
        self.began = self.began or {}
        self.began[#self.began + 1] = action
        self.moving = true
      end,
      advanceScriptedAction = function(self)
        self.advanced = (self.advanced or 0) + 1
      end,
      commitScriptedAction = function(self)
        self.commits = (self.commits or 0) + 1
        self.moving = false
      end,
      cancelScriptedMovement = function(self)
        self.cancelled = (self.cancelled or 0) + 1
        self.moving = false
      end,
      isScriptedMoving = function(self)
        return self.moving == true
      end,
      avatarTransitions = {},
      avatarApplies = 0,
      queueAvatarTransition = function(self, name)
        self.avatarTransitions[#self.avatarTransitions + 1] = name
      end,
      applyAvatarTransitions = function(self)
        self.avatarApplies = self.avatarApplies + 1
        return nil
      end,
    },
    profile = { badges = 0xFFFF },
    weather = {
      change = function(_, weatherId)
        weatherChanged[#weatherChanged + 1] = weatherId
      end,
    },
    reactions = {
      dispatch = function(_, kind)
        reactions[#reactions + 1] = kind
        return true
      end,
    },
    weatherChanged = weatherChanged,
    reactionsFired = reactions,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

local function openRuntime(manager, eventState, map, worldPorts)
  local world = FieldMoveWorld.new(worldPorts or ports(manager, eventState, map))
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, world = world }) --[[@as FieldMoveRuntimePort]]
  return runtime, world
end

local function taskContext(runtime, tick)
  return {
    services = { fieldMoves = runtime },
    instance = { scriptId = "test-field-move", instanceId = "inst-1", locals = {} },
    tick = tick or 100,
    taskId = "task-1",
  }
end

local function runTask(runtime, request)
  local queued = runtime:queue(request)
  Assert.equal(queued.kind, "accepted", "setup queue must accept, got " .. tostring(queued.kind))
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  Assert.isNil(FieldMoveTask.validate(state), "created task state must be serializable")
  local guard = 0
  while true do
    guard = guard + 1
    Assert.isTrue(guard < 200, "task must settle within a bounded poll count")
    local outcome = FieldMoveTask.poll(state, taskContext(runtime, 100 + guard))
    if outcome.complete then
      return outcome.result
    end
  end
end

-- Premise: script hide is transient visibility only. Hidden actors stay
-- solid, so Cut and Rock Smash must change presence, never call hide alone.
function T.hide_leaves_the_collider_behind()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local actors = ScriptActorWorld.new(manager --[[@as ScriptActorManager]], {
    position = function()
      return { fieldX = 5, fieldZ = 3 }
    end,
    facing = function()
      return "east"
    end,
  })
  Assert.isTrue(actors:isVisible(treeId()), "tree starts visible")
  actors:hide(treeId())
  Assert.isFalse(actors:isVisible(treeId()), "hide flips visibility")
  Assert.notNil(
    manager:getCollisionAt(61, { fieldX = 6, fieldZ = 3, surfaceId = 0 }),
    "a hidden tree still collides: hide alone is never removal"
  )
  actors:show(treeId())
  Assert.isTrue(actors:isVisible(treeId()), "show restores visibility")
  manager:dispose()
end

-- Cut removes the tree's presence and collision together, persists through
-- a same-map save round trip, and leaves unrelated NPC hide behavior solid.
function T.cut_removes_presence_and_collision_together()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local runtime = openRuntime(manager, eventState, map)
  local result = runTask(runtime, { move = "cut", slot = 0, partyRevision = 4, context = treeContext() })
  Assert.equal(result.kind, "field_move_done", "cut must run to done")
  Assert.equal(result.move, "cut")
  Assert.isNil(manager:getById(treeId()), "cut tree presence is gone")
  Assert.isNil(
    manager:getCollisionAt(61, { fieldX = 6, fieldZ = 3, surfaceId = 0 }),
    "cut tree collision is gone with its presence"
  )
  Assert.isTrue(eventState:isFlagSet(CUT_FLAG), "cut persists through the source presence flag")
  Assert.notNil(manager:getById(npcId()), "unrelated NPC survives the cut")
  -- Same-map save round trip keeps the tree cut and validates cleanly.
  local captured = manager:captureObjects()
  local validated, validationErr = FieldObjectSave.validate(captured)
  Assert.notNil(validated, "capture must validate: " .. tostring(validationErr))
  local fresh = openManager(map, eventState)
  Assert.isNil(fresh:getById(treeId()), "re-entry follows the persisted removal")
  Assert.notNil(fresh:getById(rockId()), "other obstacles are unaffected by the re-entry")
  manager:dispose()
  fresh:dispose()
end

-- Strength arming then a walked-into push moves boulder and player exactly
-- once; a boulder blocked by a wall moves neither.
function T.strength_push_moves_boulder_and_player_once()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local worldPorts = ports(manager, eventState, map)
  worldPorts.player.positionValue = { fieldX = 4, fieldZ = 5 }
  worldPorts.player.facingValue = "south"
  local runtime = openRuntime(manager, eventState, map, worldPorts)
  local enabled = runTask(runtime, {
    move = "strength",
    slot = 1,
    partyRevision = 4,
    context = context({
      facingObstacle = "strength_boulder",
      facingActor = {
        identity = boulderId(),
        obstacleKind = "strength_boulder",
        mapSymbol = "test-map",
        fieldX = 4,
        fieldZ = 6,
      },
    }),
  })
  Assert.equal(enabled.kind, "field_move_done", "strength enablement must run to done")
  Assert.isTrue(runtime:isBusy() == false, "settled enablement releases the runtime")
  -- Walk south into the boulder: the port queues one push and claims a task.
  local pushAttempt = runtime:tryStrengthPush({ boulderActorId = boulderId(), direction = "south", mapId = 61 })
  Assert.equal(pushAttempt.kind, "accepted", "an armed boulder step must queue, got " .. tostring(pushAttempt.kind))
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  local guard = 0
  local result = nil
  while result == nil and guard < 200 do
    guard = guard + 1
    local outcome = FieldMoveTask.poll(state, taskContext(runtime, 200 + guard))
    if outcome.complete then
      result = outcome.result
    end
  end
  result = assert(result, "push must settle")
  Assert.equal(result.kind, "field_move_done", "push must run to done")
  local boulder = manager:getById(boulderId())
  Assert.notNil(boulder, "pushed boulder stays present")
  local position = assert(manager:getPosition(boulderId()), "pushed boulder reports its tile")
  Assert.equal(position.fieldX, 4, "boulder moves one tile south")
  Assert.equal(position.fieldZ, 7, "boulder moves one tile south")
  manager:dispose()
end

-- Rock Smash removes terrain only: no encounter, item, or RNG draw exists
-- anywhere on the world contract.
function T.rock_smash_is_terrain_only()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local dannoPorts = ports(manager, eventState, map)
  dannoPorts.player.positionValue = { fieldX = 8, fieldZ = 3, worldY = 0 }
  dannoPorts.player.facingValue = "east"
  local runtime, world = openRuntime(manager, eventState, map, dannoPorts)
  local exposed = world --[[@as table<string, unknown>]]
  Assert.isNil(exposed.beginEncounter, "the world exposes no encounter entry")
  Assert.isNil(exposed.rollReward, "the world exposes no reward entry")
  Assert.isNil(exposed.drawRng, "the world exposes no RNG entry")
  local result = runTask(runtime, {
    move = "rock_smash",
    slot = 2,
    partyRevision = 4,
    context = context({
      facingObstacle = "smash_rock",
      facingActor = {
        identity = rockId(),
        obstacleKind = "smash_rock",
        mapSymbol = "test-map",
        fieldX = 9,
        fieldZ = 3,
      },
    }),
  })
  Assert.equal(result.kind, "field_move_done", "smash must run to done")
  Assert.equal(result.move, "smash")
  Assert.isNil(manager:getById(rockId()), "smashed rock presence is gone")
  Assert.isNil(
    manager:getCollisionAt(61, { fieldX = 9, fieldZ = 3, surfaceId = 0 }),
    "smashed rock collision is gone so traversal works"
  )
  Assert.isFalse(eventState:isFlagSet(SMASH_FLAG), "smash sets no flag: the rock respawns on re-entry")
  local fresh = openManager(map, eventState)
  Assert.notNil(fresh:getById(rockId()), "re-entry rebuilds the transient rock from source")
  manager:dispose()
  fresh:dispose()
end

-- Flash in a dark cave illuminates through the weather owner and persists
-- through the save flag; the Alph chamber dispatches its reaction instead.
function T.flash_illuminates_through_weather_and_persists()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local worldPorts = ports(manager, eventState, map)
  local runtime = openRuntime(manager, eventState, map, worldPorts)
  local result = runTask(runtime, { move = "flash", slot = 3, partyRevision = 4, context = context() })
  Assert.equal(result.kind, "field_move_done", "flash must run to done")
  Assert.isTrue(eventState:isFlagSet(2419), "flash persists through the source illumination flag")
  Assert.deepEqual(worldPorts.weatherChanged, { 12 }, "illumination runs through the weather owner")
  Assert.equal(#worldPorts.reactionsFired, 0, "a normal cave fires no special reaction")
  local serialized = eventState:serialize()
  local reloaded = FieldEventState.new(serialized)
  Assert.isTrue(reloaded:isFlagSet(2419), "reload keeps the lit state")
  manager:dispose()
end

function T.flash_in_the_alph_chamber_dispatches_its_reaction()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local worldPorts = ports(manager, eventState, map)
  local runtime = openRuntime(manager, eventState, map, worldPorts)
  local chamber = context()
  chamber.fieldUse.alphChamber = true
  local result = runTask(runtime, { move = "flash", slot = 3, partyRevision = 4, context = chamber })
  Assert.equal(result.kind, "field_move_done", "chamber flash must run to done")
  Assert.deepEqual(worldPorts.reactionsFired, { "alph_flash" }, "the chamber dispatches its source reaction")
  Assert.equal(#worldPorts.weatherChanged, 0, "the chamber reaction replaces brightening, not both")
  manager:dispose()
end

-- Scheduling faults and teardown never double-commit: a fault before commit
-- publishes nothing, and a second admission while busy changes nothing.
function T.scheduling_and_teardown_never_double_commit()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local runtime = openRuntime(manager, eventState, map)
  local first = runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = treeContext() })
  Assert.equal(first.kind, "accepted")
  Assert.isTrue(runtime:isBusy(), "a queued request holds the runtime")
  local second = runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = treeContext() })
  Assert.equal(second.kind, "busy", "a second request is rejected without mutation")
  Assert.isTrue(runtime:isBusy(), "the rejected request leaves the first pending")
  runtime:discardPending()
  Assert.isFalse(runtime:isBusy(), "discarding the unclaimed queue releases the runtime")
  Assert.notNil(manager:getById(treeId()), "no effect was committed by the discarded queue")
  -- A fault before commit publishes nothing: the target vanishes mid-flight.
  local queued = runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = treeContext() })
  Assert.equal(queued.kind, "accepted")
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  manager:removePresence(treeId(), false)
  eventState:setFlag(CUT_FLAG)
  manager:syncEventStateChanges()
  local outcome = nil
  local guard = 0
  while outcome == nil and guard < 200 do
    guard = guard + 1
    local polled = FieldMoveTask.poll(state, taskContext(runtime, 100 + guard))
    if polled.complete then
      outcome = polled
    end
  end
  outcome = assert(outcome, "a stale target settles the task")
  Assert.equal(outcome.result.kind, "field_move_failed", "stale target reports failure, never success")
  Assert.isFalse(runtime:isBusy(), "the failed task releases the runtime")
  manager:dispose()
end

-- Cancellation through the scheduler context releases motion and plan state
-- at once; the cancelled task never executes again.
function T.cancellation_cleans_up_without_another_poll()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local worldPorts = ports(manager, eventState, map)
  worldPorts.player.positionValue = { fieldX = 4, fieldZ = 5 }
  worldPorts.player.facingValue = "south"
  local runtime = openRuntime(manager, eventState, map, worldPorts)
  local enabled = runTask(runtime, {
    move = "strength",
    slot = 1,
    partyRevision = 4,
    context = context({
      facingObstacle = "strength_boulder",
      facingActor = {
        identity = boulderId(),
        obstacleKind = "strength_boulder",
        mapSymbol = "test-map",
        fieldX = 4,
        fieldZ = 6,
      },
    }),
  })
  Assert.equal(enabled.kind, "field_move_done")
  local pushAttempt = runtime:tryStrengthPush({ boulderActorId = boulderId(), direction = "south", mapId = 61 })
  Assert.equal(pushAttempt.kind, "accepted")
  local ctx = taskContext(runtime)
  local state = FieldMoveTask.create({ source = "pending" }, ctx)
  local first = FieldMoveTask.poll(state, taskContext(runtime, 101))
  Assert.isFalse(first.complete, "the push stays live across polls")
  FieldMoveTask.cancel(state, "test cancel", { services = { fieldMoves = runtime }, taskId = "task-1" })
  Assert.isFalse(runtime:isBusy(), "cancel releases the runtime at once")
  Assert.isFalse(manager:isScriptedMoving(boulderId()), "cancel releases the boulder motion without another poll")
  local position = assert(manager:getPosition(boulderId()), "cancelled boulder keeps its tile")
  Assert.equal(position.fieldX, 4, "cancel restores the committed boulder tile")
  Assert.equal(position.fieldZ, 6, "cancel restores the committed boulder tile")
  worldPorts.player.positionValue = { fieldX = 5, fieldZ = 3, worldY = 0 }
  worldPorts.player.facingValue = "east"
  local punch = runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = treeContext() })
  Assert.equal(punch.kind, "accepted", "the runtime serves the next operation after cancel")
  runtime:discardPending()
  manager:dispose()
end

-- Explicit script-origin requests plan without re-gating: the runtime is
-- built with a policy double that faults loudly on consultation, so
-- reaching a live plan or a live refusal proves admission never gates on
-- eligibility. Executable water traversal reaches the world and refuses
-- honestly on geometry, still deferred moves complete refused, malformed
-- slots fault loudly, and admission contention faults instead of queuing
-- twice.
function T.explicit_requests_use_the_shared_task_entry()
  local objects = fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = openManager(map, eventState)
  local policyCalls = { count = 0 }
  local policy = {
    check = function(_, _)
      policyCalls.count = policyCalls.count + 1
      error("explicit script-origin requests never consult eligibility", 0)
    end,
  }
  local world = FieldMoveWorld.new(ports(manager, eventState, map))
  local runtime = FieldMoveRuntime.new({ policy = policy, world = world }) --[[@as FieldMoveRuntimePort]]
  local function explicitCtx()
    local ctx = taskContext(runtime)
    ctx.semantics = RuntimeValues
    return ctx
  end
  local geometric = FieldMoveTask.create({ source = "explicit", node = { move = "surf", slot = 2 } }, explicitCtx())
  Assert.isNil(FieldMoveTask.validate(geometric), "planned state stays serializable")
  local refused = FieldMoveTask.poll(geometric, explicitCtx())
  Assert.isTrue(refused.complete)
  Assert.equal(refused.result.kind, "field_move_refused")
  Assert.equal(refused.result.decision.kind, "not_here", "explicit surf refuses on geometry, never defers")
  local deferred = FieldMoveTask.create({ source = "explicit", node = { move = "dig", slot = 2 } }, explicitCtx())
  Assert.isNil(FieldMoveTask.validate(deferred), "refused state stays serializable")
  local digRefused = FieldMoveTask.poll(deferred, explicitCtx())
  Assert.isTrue(digRefused.complete)
  Assert.equal(digRefused.result.kind, "field_move_refused")
  Assert.equal(digRefused.result.decision.kind, "not_now", "explicit dig without travel refuses, never guesses")
  Assert.isFalse(runtime:isBusy(), "refused explicit work holds nothing")
  local badSlot = Assert.throws(function()
    FieldMoveTask.create({ source = "explicit", node = { move = "surf", slot = 9 } }, explicitCtx())
  end)
  Assert.notNil(badSlot, "a non-party slot faults loudly")
  Assert.isFalse(runtime:isBusy(), "refused explicit work holds nothing")
  Assert.equal(policyCalls.count, 0, "no eligibility check ran for the explicit requests")
  manager:dispose()
end

function T.composition_registers_the_field_task()
  local Composition = require("libs.hgss.src.script.Composition")
  local TaskRegistry = require("libs.script.src.TaskRegistry")
  local registry = Composition.registerTasks(TaskRegistry.new())
  local impl = assert(registry:resolve("field_move", 1), "field task must be registered")
  Assert.equal(impl.type, "field_move")
  Assert.equal(impl.version, 1)
  local followerInteraction = assert(
    registry:resolve("follower_interaction", 3),
    "follower interaction task must be registered before save restoration"
  )
  Assert.equal(followerInteraction.type, "follower_interaction")
  Assert.equal(followerInteraction.version, 3)
end

return { tests = T }
