-- Dig and Teleport return plans through the shared scheduler task over the
-- real world adapter: the closed plan union admits both kinds, the source
-- animation (sound, zoom, spin, colored cover) completes before the warp
-- starts under an opaque screen, completion and failure report through the
-- task protocol, cancellation never re-polls, and serialized state validates
-- without live references.

local Assert = require("tests.support.Assert")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local FieldScriptScreenFade = require("libs.hgss.src.transition.FieldScriptScreenFade")

local T = {}

-- Structural port for the runtime under test: names exactly the exercised
-- boundary so helper-built subjects resolve their methods.
---@class ReturnTaskRuntimePort
---@field queue fun(self: ReturnTaskRuntimePort, request: table<string, unknown>): table<string, unknown>

local function stub()
  return function() end
end

local function newCamera()
  return FieldCamera.new({
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = -8192,
    angleYRaw = 0,
    halfFovRadians = math.rad(15),
    fullVerticalFovRadians = math.rad(30),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }, { initialTarget = { x = 0, y = 0, z = 0 } })
end

-- Observable run state shared by one test's doubles.
local function newRig()
  return {
    effects = {},
    clearedFlags = {},
    faces = {},
    transitions = {},
    specialSpawn = nil,
    screen = FieldScriptScreenFade.new(),
    camera = newCamera(),
  }
end

local function worldWith(warps, spawns, rig)
  rig = rig or newRig()
  return FieldMoveWorld.new({
    actors = {
      getActor = stub(),
      actorsOf = stub(),
      getPosition = stub(),
      getCollisionAt = stub(),
      beginScriptedAction = stub(),
      advanceScriptedAction = stub(),
      commitScriptedAction = stub(),
      cancelScriptedMovement = stub(),
      isScriptedMoving = stub(),
      removePresence = stub(),
      syncEventStateChanges = stub(),
    },
    events = {
      setFlag = stub(),
      isFlagSet = stub(),
      clearFlag = function(_, flagId)
        rig.clearedFlags[#rig.clearedFlags + 1] = flagId
      end,
    },
    maps = {
      current = function()
        return {}
      end,
      runtimeMap = function()
        return {}
      end,
    },
    player = {
      position = stub(),
      facing = stub(),
      beginScriptedAction = function(_, action)
        rig.faces[#rig.faces + 1] = action.direction
      end,
      advanceScriptedAction = stub(),
      commitScriptedAction = stub(),
      cancelScriptedMovement = stub(),
      isScriptedMoving = stub(),
      queueAvatarTransition = function(_, name)
        rig.transitions[#rig.transitions + 1] = name
      end,
      applyAvatarTransitions = stub(),
    },
    profile = { badges = 0 },
    weather = { change = stub() },
    reactions = { dispatch = stub() },
    warps = warps,
    spawns = spawns,
    audio = {
      play = function(_, sequence)
        rig.effects[#rig.effects + 1] = sequence
      end,
    },
    camera = function()
      return rig.camera
    end,
    screen = rig.screen,
    travel = {
      setSpecialSpawn = function(_, spawn)
        rig.specialSpawn = spawn
      end,
    },
  })
end

-- Cited landing destinations for the task boundary: the mother spawn
-- resolves to New Bark; anything else is uncited and refused loudly.
local function spawnsDouble()
  return {
    destinationFor = function(_, spawnKey)
      if spawnKey == "SPAWN_NEW_BARK" then
        return { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 }
      end
      return nil
    end,
    specialFor = function(_, spawnKey)
      assert(spawnKey == "SPAWN_NEW_BARK", "unexpected special spawn " .. tostring(spawnKey))
      return { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397, warpId = -1, direction = "south" }
    end,
  }
end

local function warpsDouble(rig)
  local service = {
    starts = 0,
    done = false,
    errorValue = nil,
    origin = { x = 600, z = 300 },
  }
  function service:placement(ref)
    assert(ref == "MAP_ROUTE_46" or ref == "MAP_NEW_BARK", "unexpected map " .. tostring(ref))
    return { id = 48, originX = self.origin.x, originZ = self.origin.z }
  end
  function service:startWarp(target)
    assert(rig == nil or rig.screen:isOpaque(), "the map swap waits for the move's opaque cover")
    self.starts = self.starts + 1
    self.lastTarget = target
  end
  function service:warpDone()
    return self.done
  end
  function service:pendingError()
    return self.errorValue
  end
  return service
end

local function contextWith()
  return {
    mapId = 176,
    badges = 0,
    fieldUse = { cave = true, escapeAllowed = true, teleportAllowed = true },
  }
end

local function travelWith()
  return {
    lastHealSpawn = "SPAWN_NEW_BARK",
    specialSpawn = { map = "MAP_ROUTE_46", fieldX = 628, fieldZ = 329, warpId = -1, direction = "south" },
  }
end

local function taskContext(runtime)
  return {
    services = { fieldMoves = runtime },
    instance = { scriptId = "test-return-move", instanceId = "inst-1", locals = {} },
    tick = 100,
    taskId = "task-1",
  }
end

local function driveToResult(runtime, state, rig)
  local guard = 0
  while true do
    guard = guard + 1
    Assert.isTrue(guard < 600, "return task must settle within a bounded poll count")
    local outcome = FieldMoveTask.poll(state, taskContext(runtime))
    if rig ~= nil then
      rig.screen:updateSourceFrame()
    end
    if outcome.complete then
      return outcome.result
    end
  end
end

local function queueDig(runtime)
  local queued =
    runtime:queue({ move = "dig", slot = 0, partyRevision = 4, context = contextWith(), travel = travelWith() })
  Assert.equal(queued.kind, "accepted", "dig admission must accept")
end

function T.dig_completes_through_the_shared_task()
  local rig = newRig()
  local warps = warpsDouble(rig)
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, world = worldWith(warps, nil, rig) }) --[[@as ReturnTaskRuntimePort]]
  queueDig(runtime)
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  Assert.isNil(state.refused, "dig must plan an executable task")
  Assert.isNil(FieldMoveTask.validate(state), "dig task state must be serializable")
  warps.done = true
  local result = driveToResult(runtime, state, rig)
  Assert.equal(result.kind, "field_move_done", "dig must report done")
  Assert.equal(result.move, "dig", "completion names the executed plan")
  Assert.equal(warps.starts, 1, "the shared task starts the warp exactly once")
  Assert.deepEqual(rig.effects, { "SEQ_SE_DP_KAIDAN2" }, "dig plays its source effect once")
  Assert.equal(#rig.clearedFlags, 1, "the landed warp ends any Safari session once")
  Assert.deepEqual(rig.transitions, { "walking" }, "the avatar returns to walking for the warp")
  Assert.equal(warps.lastTarget.facing, "south", "dig arrives facing its recorded special spawn direction")
  Assert.equal(warps.lastTarget.fieldX, 628 - 600, "the special spawn tile converts to the destination map")
  Assert.equal(rig.faces[#rig.faces], "south", "the arrival spin ends facing south")
  Assert.equal(rig.camera:distanceTiles(), 10, "the camera is back at its normal distance")
  Assert.isTrue(rig.screen:fadeDone() and not rig.screen:isOpaque(), "the cover is gone when the move ends")
end

function T.failed_warp_reports_failure_and_uncovers_the_screen()
  local rig = newRig()
  local warps = warpsDouble(rig)
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, world = worldWith(warps, nil, rig) }) --[[@as ReturnTaskRuntimePort]]
  queueDig(runtime)
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  warps.done = true
  warps.errorValue = { kind = "stale" }
  local result = driveToResult(runtime, state, rig)
  Assert.equal(result.kind, "field_move_failed", "service failure must fault the task result")
  Assert.deepEqual(result.error, { kind = "stale" }, "the service error surfaces verbatim")
  Assert.isFalse(rig.screen:isOpaque(), "a failed warp never strands the covered screen")
  Assert.equal(rig.camera:distanceTiles(), 10, "a failed warp restores the camera")
end

function T.cancelled_return_never_polls_again()
  local warps = warpsDouble()
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, world = worldWith(warps) }) --[[@as ReturnTaskRuntimePort]]
  queueDig(runtime)
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  local ctx = taskContext(runtime)
  FieldMoveTask.cancel(state, "test cancel", ctx)
  Assert.equal(state.cancelled, "test cancel", "cancel marks serializable state")
  local ok = pcall(function()
    FieldMoveTask.poll(state, ctx)
  end)
  Assert.isFalse(ok, "a cancelled return task never polls again")
  Assert.equal(warps.starts, 0, "cancelling before the start warps nothing")
end

function T.teleport_plans_through_cited_destinations()
  local rig = newRig()
  local warps = warpsDouble(rig)
  local runtime = FieldMoveRuntime.new({
    policy = FieldMovePolicy,
    world = worldWith(warps, spawnsDouble(), rig),
  }) --[[@as ReturnTaskRuntimePort]]
  local queued = runtime:queue({
    move = "teleport",
    slot = 1,
    partyRevision = 4,
    context = contextWith(),
    travel = travelWith(),
  })
  Assert.equal(queued.kind, "accepted", "teleport admission precedes planning")
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  Assert.isNil(state.refused, "cited destinations produce an executable plan")
  Assert.isNil(FieldMoveTask.validate(state), "executable teleport state validates")
  warps.done = true
  local result = driveToResult(runtime, state, rig)
  Assert.equal(result.kind, "field_move_done")
  Assert.deepEqual(rig.effects, { "SEQ_SE_DP_TELE" }, "teleport plays its source effect once")
  Assert.deepEqual(
    rig.specialSpawn,
    { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397, warpId = -1, direction = "south" },
    "teleport rewrites the special spawn with the spawn it leaves for"
  )
end

return { tests = T }
