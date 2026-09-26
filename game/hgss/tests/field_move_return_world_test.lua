-- Return-warp adaptation over the borrowed maps service: Dig resolves
-- the recorded outside entrance through the loader, Teleport resolves
-- the recorded heal spawn through the injected cited landing
-- destinations (unknown keys fail loudly, never a guess), warps start
-- exactly once with destination-local coordinates, completion and
-- failures surface through the service protocol, and nothing is owned.

local Assert = require("tests.support.Assert")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")

local T = {}

-- Structural service double for return warps: records starts with plain
-- data so assertions read recorded values, never live references.
---@class ReturnWarpsDouble
---@field origin table<string, integer>
---@field done boolean
---@field errorValue unknown
---@field started table<string, unknown>?
---@field resolve fun(self: ReturnWarpsDouble, ref: unknown): table<string, unknown>?
---@field startWarp fun(self: ReturnWarpsDouble, target: table<string, unknown>)
---@field warpDone fun(self: ReturnWarpsDouble): boolean
---@field pendingError fun(self: ReturnWarpsDouble): unknown

local function warpsDouble()
  local calls = { start = 0 }
  local service = {
    started = nil,
    done = false,
    errorValue = nil,
    origin = { x = 600, z = 300 },
    resolve = function(self, ref)
      if ref == "MAP_ROUTE_46" then
        return { mapSymbol = ref, mapId = 48, coordinateOrigin = self.origin }
      end
      return nil
    end,
    startWarp = function(self, target)
      calls.start = calls.start + 1
      self.started = target
    end,
    warpDone = function(self)
      return self.done
    end,
    pendingError = function(self)
      return self.errorValue
    end,
  } ---@type ReturnWarpsDouble
  return service, calls
end

local function worldWith(warps, spawns)
  local function stub()
    return function() end
  end
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

local function travelWith(entrance)
  return {
    lastHealSpawn = "SPAWN_NEW_BARK",
    escapeEntrance = entrance,
  }
end

local function contextWith()
  return { mapId = 176 }
end

function T.plan_return_dig_resolves_the_recorded_entrance()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local entrance = { map = "MAP_ROUTE_46", fieldX = 628, fieldZ = 329, facing = "south" }
  local destination = world:planReturn("dig", contextWith(), travelWith(entrance))
  Assert.equal(destination.map, "MAP_ROUTE_46", "dig exits through the recorded map")
  Assert.equal(destination.fieldX, 628, "dig keeps destination-global record tiles")
  Assert.equal(destination.fieldZ, 329, "dig keeps destination-global record tiles")
  Assert.equal(destination.facing, "south", "dig keeps the recorded facing")
end

function T.plan_return_dig_without_history_reports_not_now()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local decision = world:planReturn("dig", contextWith(), travelWith(nil))
  Assert.equal(decision.kind, "not_now", "dig with no recorded entrance is not now, never a guess")
end

function T.plan_return_teleport_resolves_the_recorded_heal_spawn()
  local warps = warpsDouble()
  local spawns = {
    destinationFor = function(_, key)
      assert(key == "SPAWN_NEW_BARK", "resolution requests the recorded spawn")
      return { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 }
    end,
  }
  local world = worldWith(warps, spawns)
  local destination = world:planReturn("teleport", contextWith(), travelWith(nil))
  Assert.equal(destination.map, "MAP_NEW_BARK", "teleport exits through the recorded spawn map")
  Assert.equal(destination.fieldX, 695, "teleport keeps destination-global record tiles")
  Assert.equal(destination.fieldZ, 397, "teleport keeps destination-global record tiles")
  Assert.equal(destination.facing, "south", "teleport stamps the standard arrival facing")
end

function T.plan_return_teleport_with_an_uncited_spawn_fails_loudly()
  local warps = warpsDouble()
  local spawns = {
    destinationFor = function(_, _)
      return nil
    end,
  }
  local world = worldWith(warps, spawns)
  local ok, err = pcall(function()
    world:planReturn("teleport", contextWith(), travelWith(nil))
  end)
  Assert.isFalse(ok, "an uncited spawn must never warp somewhere convenient")
  Assert.notNil(tostring(err):find("SPAWN_NEW_BARK", 1, true), "the refusal names the spawn")
end

function T.plan_return_teleport_without_destinations_is_a_programming_error()
  local warps = warpsDouble()
  local world = worldWith(warps, nil)
  local ok = pcall(function()
    world:planReturn("teleport", contextWith(), travelWith(nil))
  end)
  Assert.isFalse(ok, "teleport without destinations must fail loudly, never guess")
end

function T.begin_starts_the_warp_exactly_once_with_local_coordinates()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local entrance = { map = "MAP_ROUTE_46", fieldX = 628, fieldZ = 329, facing = "south" }
  local destination = world:planReturn("dig", contextWith(), travelWith(entrance))
  local plan = { kind = "dig", destination = destination }
  world:beginReturnWarp(plan)
  local started = assert(warps.started, "the warp must start")
  Assert.equal(started.map, "MAP_ROUTE_46", "the warp targets the recorded map")
  Assert.equal(started.fieldX, 28, "the warp carries destination-local tiles")
  Assert.isTrue(plan.warpStarted, "the plan records its single start")
  local ok = pcall(function()
    world:beginReturnWarp(plan)
  end)
  Assert.isFalse(ok, "a second start must not silently re-warp")
  local restated = assert(warps.started, "the single start persists")
  Assert.isTrue(restated.map == "MAP_ROUTE_46", "no duplicate start reaches the service")
end

function T.done_and_error_read_the_service_protocol()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local plan = { kind = "dig", destination = { map = "M", warp = 0, fieldX = 1, fieldZ = 2, facing = "south" } }
  Assert.isFalse(world:returnWarpDone(plan), "an unfinished warp is not done")
  Assert.isNil(world:returnWarpError(plan), "no error surfaces before completion")
  warps.done = true
  Assert.isTrue(world:returnWarpDone(plan), "a finished warp reports done")
  warps.errorValue = { kind = "stale" }
  Assert.deepEqual(world:returnWarpError(plan), { kind = "stale" }, "service failures surface verbatim")
end

function T.unresolvable_destination_refuses_with_the_service_code()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local plan = {
    kind = "dig",
    destination = { map = "MAP_NOWHERE", warp = 0, fieldX = 1, fieldZ = 2, facing = "south" },
  }
  local Errors = require("libs.errors.src.Errors")
  local ok, err = pcall(function()
    world:beginReturnWarp(plan)
  end)
  Assert.isFalse(ok, "an unresolvable destination must not start")
  Assert.isTrue(Errors.is(err), "resolution failure stays a structured error")
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_INVALID_REFERENCE", "unknown maps refuse with the service code")
  Assert.isFalse(plan.warpStarted == true, "a refused start marks nothing")
end

function T.unknown_moves_and_malformed_travel_fail_loudly()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local ok = pcall(function()
    world:planReturn("cut", contextWith(), travelWith(nil))
  end)
  Assert.isFalse(ok, "return planning accepts only dig and teleport")
  local bad = pcall(function()
    world:planReturn("dig", contextWith(), {})
  end)
  Assert.isFalse(bad, "return planning requires a travel record")
end

return { tests = T }
