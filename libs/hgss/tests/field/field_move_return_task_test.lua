-- Dig and Teleport return plans through the shared scheduler task: the
-- closed plan union admits both kinds, completion and failure report
-- through the task protocol, cancellation never re-polls, and serialized
-- state validates without live references.

local Assert = require("tests.support.Assert")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")

local T = {}

-- Structural port for the runtime under test: names exactly the exercised
-- boundary so helper-built subjects resolve their methods.
---@class ReturnTaskRuntimePort
---@field queue fun(self: ReturnTaskRuntimePort, request: table<string, unknown>): table<string, unknown>

local function stub()
  return function() end
end

local function worldWith(warps, spawns)
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
    events = { setFlag = stub(), isFlagSet = stub() },
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
      beginScriptedAction = stub(),
      advanceScriptedAction = stub(),
      commitScriptedAction = stub(),
      cancelScriptedMovement = stub(),
      isScriptedMoving = stub(),
      queueAvatarTransition = stub(),
      applyAvatarTransitions = stub(),
    },
    profile = { badges = 0 },
    weather = { change = stub() },
    reactions = { dispatch = stub() },
    warps = warps,
    spawns = spawns,
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
  }
end

local function warpsDouble()
  local service = {
    starts = 0,
    done = false,
    errorValue = nil,
    origin = { x = 600, z = 300 },
  }
  function service:resolve(ref)
    if ref == "MAP_ROUTE_46" then
      return { mapSymbol = ref, mapId = 48, coordinateOrigin = self.origin }
    end
    return nil
  end
  function service:startWarp(target)
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
    escapeEntrance = { map = "MAP_ROUTE_46", fieldX = 628, fieldZ = 329, facing = "south" },
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

local function driveToResult(runtime, state)
  local guard = 0
  while true do
    guard = guard + 1
    Assert.isTrue(guard < 200, "return task must settle within a bounded poll count")
    local outcome = FieldMoveTask.poll(state, taskContext(runtime))
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
  local warps = warpsDouble()
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, world = worldWith(warps) }) --[[@as ReturnTaskRuntimePort]]
  queueDig(runtime)
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  Assert.isNil(state.refused, "dig must plan an executable task")
  Assert.isNil(FieldMoveTask.validate(state), "dig task state must be serializable")
  warps.done = true
  local result = driveToResult(runtime, state)
  Assert.equal(result.kind, "field_move_done", "dig must report done")
  Assert.equal(result.move, "dig", "completion names the executed plan")
  Assert.equal(warps.starts, 1, "the shared task starts the warp exactly once")
end

function T.failed_warp_reports_failure_through_the_shared_task()
  local warps = warpsDouble()
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, world = worldWith(warps) }) --[[@as ReturnTaskRuntimePort]]
  queueDig(runtime)
  local state = FieldMoveTask.create({ source = "pending" }, taskContext(runtime))
  warps.done = true
  warps.errorValue = { kind = "stale" }
  local result = driveToResult(runtime, state)
  Assert.equal(result.kind, "field_move_failed", "service failure must fault the task result")
  Assert.deepEqual(result.error, { kind = "stale" }, "the service error surfaces verbatim")
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
  local warps = warpsDouble()
  local runtime = FieldMoveRuntime.new({
    policy = FieldMovePolicy,
    world = worldWith(warps, spawnsDouble()),
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
end

return { tests = T }
