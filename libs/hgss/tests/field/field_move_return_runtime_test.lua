-- Return-warp phase ownership: Dig plans from recorded entrances and
-- Teleport plans from cited spawn destinations, both advancing
-- acknowledge-then-warp through the world adapter exactly once; Fly
-- never plans; cancellation before the start leaves the service
-- untouched and repeated polls never re-warp.

local Assert = require("tests.support.Assert")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")

local T = {}

-- Structural port for the runtime under test: names exactly the exercised
-- boundary so helper-built subjects resolve their methods.
---@class ReturnRuntimePort
---@field queue fun(self: ReturnRuntimePort, request: table<string, unknown>): table<string, unknown>
---@field takePending fun(self: ReturnRuntimePort): table<string, unknown>
---@field plan fun(self: ReturnRuntimePort, request: table<string, unknown>): table<string, unknown>
---@field advance fun(self: ReturnRuntimePort, plan: table<string, unknown>): table<string, unknown>
---@field cancel fun(self: ReturnRuntimePort, plan: table<string, unknown>)
---@field isBusy fun(self: ReturnRuntimePort): boolean

local function travelWith(entrance)
  return {
    lastHealSpawn = "SPAWN_NEW_BARK",
    escapeEntrance = entrance,
  }
end

local function worldDouble(warps)
  local world = {
    warpCalls = { plan = 0, begin = 0 },
    planned = nil,
    began = nil,
    done = false,
    errorValue = nil,
  }
  function world:planReturn(move, context, travel)
    self.warpCalls.plan = self.warpCalls.plan + 1
    self.planned = { move = move, travel = travel }
    assert(type(context) == "table", "return planning requires its context")
    if move == "dig" then
      local entrance = travel.escapeEntrance
      if entrance == nil then
        return { kind = "not_now" }
      end
      return { map = entrance.map, warp = 0, fieldX = 1, fieldZ = 2, facing = "south" }
    end
    if move == "teleport" then
      return { map = "MAP_NEW_BARK", warp = 0, fieldX = 695, fieldZ = 397, facing = "south" }
    end
    error("world double plans only dig and teleport returns", 0)
  end
  function world:beginReturnWarp(plan)
    self.warpCalls.begin = self.warpCalls.begin + 1
    self.began = plan
    assert(plan.warpStarted ~= true, "world double starts once")
    plan.warpStarted = true
  end
  function world:returnWarpDone(_)
    return self.done
  end
  function world:returnWarpError(_)
    return self.errorValue
  end
  function world:validateTarget(_)
    return nil
  end
  function world:cancelMotion(_) end
  if warps ~= nil then
    world.warpsDouble = warps
  end
  return world
end

local function contextWith()
  return {
    mapId = 176,
    badges = 0,
    fieldUse = { cave = true, escapeAllowed = true, teleportAllowed = true },
  }
end

local function flyContextWith()
  return {
    mapId = 33,
    badges = 16,
    fieldUse = { flyAllowed = true },
  }
end

local function runtimeWith(world)
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, context = contextWith(), world = world })
  return runtime --[[@as ReturnRuntimePort]]
end

local function digRequest(travel)
  return { move = "dig", slot = 0, partyRevision = 4, context = contextWith(), travel = travel }
end

function T.dig_plans_and_runs_to_done_through_one_warp()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local entrance = { map = "M", fieldX = 1, fieldZ = 2, facing = "south" }
  local request = digRequest(travelWith(entrance))
  Assert.equal(runtime:queue(request).kind, "accepted", "dig admission must accept")
  local taken = runtime:takePending()
  local plan = runtime:plan(taken)
  Assert.equal(plan.kind, "dig", "dig must produce an executable plan")
  world.done = true
  local outcome = nil
  for _ = 1, 40 do
    outcome = runtime:advance(plan)
    if outcome.kind ~= "running" then
      break
    end
  end
  Assert.notNil(outcome, "dig must settle")
  Assert.equal(outcome.kind, "done", "dig must run to done")
  Assert.equal(world.warpCalls.begin, 1, "the warp must start exactly once across polls")
  local settled = runtime:advance(plan)
  Assert.equal(settled.kind, "done", "a settled plan stays done without re-warping")
  Assert.equal(world.warpCalls.begin, 1, "settled polls never re-warp")
end

function T.dig_without_history_refuses_without_planning()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local request = digRequest(travelWith(nil))
  Assert.equal(runtime:queue(request).kind, "accepted", "dig admission precedes planning")
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.kind, "not_now", "dig with no entrance refuses instead of planning")
end

function T.failed_warp_reports_failure_and_releases()
  local world = worldDouble()
  world.done = true
  world.errorValue = { kind = "stale" }
  local runtime = runtimeWith(world)
  local entrance = { map = "M", fieldX = 1, fieldZ = 2, facing = "south" }
  local request = digRequest(travelWith(entrance))
  runtime:queue(request)
  local plan = runtime:plan(runtime:takePending())
  local outcome = nil
  for _ = 1, 40 do
    outcome = runtime:advance(plan)
    if outcome.kind ~= "running" then
      break
    end
  end
  Assert.notNil(outcome, "the failed warp must settle")
  Assert.equal(outcome.kind, "failed", "service failure must fault the plan, not succeed")
  Assert.deepEqual(outcome.error, { kind = "stale" }, "the service error surfaces verbatim")
  Assert.isFalse(runtime:isBusy(), "a failed return releases the runtime")
end

function T.cancel_before_start_leaves_the_service_untouched()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local entrance = { map = "M", fieldX = 1, fieldZ = 2, facing = "south" }
  local request = digRequest(travelWith(entrance))
  runtime:queue(request)
  local plan = runtime:plan(runtime:takePending())
  runtime:cancel(plan)
  Assert.equal(world.warpCalls.begin, 0, "cancelling before the start warps nothing")
  Assert.isFalse(runtime:isBusy(), "cancelling releases the runtime")
end

function T.teleport_plans_and_runs_to_done_through_one_warp()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local travel = travelWith(nil)
  local request = { move = "teleport", slot = 1, partyRevision = 4, context = contextWith(), travel = travel }
  Assert.equal(runtime:queue(request).kind, "accepted", "teleport admission must accept")
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.kind, "teleport", "teleport must produce an executable plan")
  world.done = true
  local outcome = nil
  for _ = 1, 40 do
    outcome = runtime:advance(plan)
    if outcome.kind ~= "running" then
      break
    end
  end
  Assert.notNil(outcome, "teleport must settle")
  Assert.equal(outcome.kind, "done", "teleport must run to done")
  Assert.equal(world.warpCalls.begin, 1, "the warp must start exactly once across polls")
end

function T.fly_never_plans()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local travel = travelWith(nil)
  local fly = { move = "fly", slot = 1, partyRevision = 4, context = flyContextWith(), travel = travel }
  local admitted = runtime:queue(fly)
  Assert.equal(admitted.kind, "accepted", "fly admission precedes planning")
  local ok, err = pcall(function()
    runtime:plan(runtime:takePending())
  end)
  Assert.isFalse(ok, "fly must never produce a field plan")
  Assert.notNil(tostring(err):find("fly never plans", 1, true), "fly rejection names the invariant")
end

return { tests = T }
