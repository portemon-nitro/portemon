-- Return-warp phase ownership: Dig plans from the recorded special spawn and
-- Teleport plans from cited spawn destinations, both advancing departure,
-- the warp, then arrival through the world adapter exactly once; Fly
-- stages bounded destination choice before its validated travel;
-- cancellation before the start leaves the service untouched and
-- repeated polls never re-warp.

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

local function travelWith(special)
  return {
    lastHealSpawn = "SPAWN_NEW_BARK",
    specialSpawn = special,
  }
end

local function worldDouble(warps)
  local world = {
    warpCalls = { plan = 0, begin = 0 },
    order = {},
    departureTicks = 3,
    arrivalTicks = 2,
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
      local special = travel.specialSpawn
      if special == nil then
        return { kind = "not_now" }
      end
      return { map = special.map, warp = 0, fieldX = 1, fieldZ = 2, facing = special.direction }
    end
    if move == "teleport" then
      return { map = "MAP_NEW_BARK", warp = 0, fieldX = 695, fieldZ = 397, facing = "south" }
    end
    error("world double plans only dig and teleport returns", 0)
  end
  function world:stepWarpDeparture(plan)
    self.order[#self.order + 1] = "depart"
    self.departureTicks = self.departureTicks - 1
    return self.departureTicks > 0 and "running" or "warp"
  end
  function world:settleWarp(_)
    self.order[#self.order + 1] = "settle"
  end
  function world:stepWarpArrival(plan)
    self.order[#self.order + 1] = "arrive"
    self.arrivalTicks = self.arrivalTicks - 1
    return self.arrivalTicks > 0 and "running" or "done"
  end
  function world:beginReturnWarp(plan)
    self.order[#self.order + 1] = "begin"
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
  function world:isFollowerPerforming(slot)
    self.followerSlot = slot
    return self.followerPerforming == true
  end
  function world:isStrengthActive()
    return false
  end
  function world:clearStrength() end
  function world:cancelMotion(_)
    self.order[#self.order + 1] = "cancel"
  end
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
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, world = world })
  return runtime --[[@as ReturnRuntimePort]]
end

local function digRequest(travel)
  return { move = "dig", slot = 0, partyRevision = 4, context = contextWith(), travel = travel }
end

function T.dig_plans_and_runs_to_done_through_one_warp()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local special = { map = "M", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" }
  local request = digRequest(travelWith(special))
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

-- The Escape Rope bag item returns to the recorded special spawn like Dig,
-- through its own animation, and needs no party slot or move user.
-- Dig and Teleport resolve the follower performance at plan time from live
-- world state: an adjacent follower using the lead takes the cry path, and
-- the plan carries the answer on itself and its warp sequence.
function T.dig_plan_marks_the_follower_performance_on_the_plan_and_sequence()
  local world = worldDouble()
  world.followerPerforming = true
  local runtime = runtimeWith(world)
  local special = { map = "M", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" }
  runtime:queue(digRequest(travelWith(special)))
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.kind, "dig")
  Assert.equal(world.followerSlot, 0, "the follower check names the used slot")
  Assert.isTrue(plan.withFollowMon, "the plan carries the live performance answer")
  Assert.isTrue(plan.sequence.withFollowMon, "the warp sequence cries for the follower")
end

function T.solo_dig_plans_take_the_cutin_path()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local special = { map = "M", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" }
  runtime:queue(digRequest(travelWith(special)))
  local plan = runtime:plan(runtime:takePending())
  Assert.isFalse(plan.withFollowMon, "a solo departure leaves the flag clear")
  Assert.isFalse(plan.sequence.withFollowMon, "the warp sequence shows the cut-in")
end

function T.escape_rope_plans_the_dig_destination_with_its_own_sequence_and_no_slot()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local special = { map = "M", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" }
  local request = { move = "escape_rope", context = contextWith(), travel = travelWith(special) }
  Assert.equal(runtime:queue(request).kind, "accepted", "escape rope admission must accept without a slot")
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.kind, "escape_rope")
  Assert.equal(plan.slot, nil)
  Assert.equal(world.planned.move, "dig", "the destination is the Dig special spawn")
  Assert.equal(plan.sequence.kind, "escape_rope")
  world.done = true
  local outcome = nil
  for _ = 1, 60 do
    outcome = runtime:advance(plan)
    if outcome.kind ~= "running" then
      break
    end
  end
  Assert.equal(outcome.kind, "done")
  Assert.equal(world.warpCalls.begin, 1)
end

function T.escape_rope_refuses_per_the_item_check_before_any_plan()
  local runtime = runtimeWith(worldDouble())
  local noCave = contextWith()
  noCave.fieldUse = { cave = false, escapeAllowed = false }
  Assert.equal(runtime:queue({ move = "escape_rope", context = noCave, travel = travelWith(nil) }).kind, "not_here")
  Assert.isFalse(runtime:isBusy())
  local escorted = contextWith()
  escorted.humanFollower = true
  Assert.equal(runtime:queue({ move = "escape_rope", context = escorted, travel = travelWith(nil) }).kind, "have_follower")
end

function T.warping_runs_departure_then_one_warp_then_arrival_before_done()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local special = { map = "M", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" }
  runtime:queue(digRequest(travelWith(special)))
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.phase, "depart", "a warping move opens with its departure animation")
  local outcome
  for _ = 1, 40 do
    world.done = world.warpCalls.begin > 0
    outcome = runtime:advance(plan)
    if outcome.kind ~= "running" then
      break
    end
  end
  Assert.equal(outcome.kind, "done")
  Assert.deepEqual(
    world.order,
    { "depart", "depart", "depart", "begin", "settle", "arrive", "arrive" },
    "departure completes, the warp starts once, then arrival runs"
  )
  Assert.isFalse(runtime:isBusy(), "the runtime releases once arrival settles")
end

function T.cancelling_a_started_departure_releases_the_animation_once()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local special = { map = "M", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" }
  runtime:queue(digRequest(travelWith(special)))
  local plan = runtime:plan(runtime:takePending())
  runtime:advance(plan)
  runtime:cancel(plan)
  runtime:cancel(plan)
  local cancels = 0
  for _, entry in ipairs(world.order) do
    if entry == "cancel" then
      cancels = cancels + 1
    end
  end
  Assert.equal(cancels, 1, "the animation releases exactly once")
  Assert.isFalse(runtime:isBusy())
end

function T.dig_without_a_special_spawn_refuses_without_planning()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local request = digRequest(travelWith(nil))
  Assert.equal(runtime:queue(request).kind, "accepted", "dig admission precedes planning")
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.kind, "not_now", "dig with no special spawn refuses instead of planning")
end

function T.failed_warp_reports_failure_and_releases()
  local world = worldDouble()
  world.done = true
  world.errorValue = { kind = "stale" }
  local runtime = runtimeWith(world)
  local special = { map = "M", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" }
  local request = digRequest(travelWith(special))
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
  local special = { map = "M", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" }
  local request = digRequest(travelWith(special))
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
  local outcome = nil
  for _ = 1, 40 do
    world.done = world.warpCalls.begin > 0
    outcome = runtime:advance(plan)
    if outcome.kind ~= "running" then
      break
    end
  end
  Assert.notNil(outcome, "teleport must settle")
  Assert.equal(outcome.kind, "done", "teleport must run to done")
  Assert.equal(world.warpCalls.begin, 1, "the warp must start exactly once across polls")
end

function T.fly_stages_destination_choice()
  local world = worldDouble()
  local runtime = runtimeWith(world)
  local travel = travelWith(nil)
  local fly = {
    move = "fly",
    slot = 1,
    partyRevision = 4,
    context = flyContextWith(),
    travel = travel,
    mapContext = {
      fieldMap = "test.field.new-bark",
      location = "test.place.new-bark",
      matrixX = 96,
      matrixY = 64,
      region = "johto",
      unlockLevel = 1,
      specialMode = nil,
      playerGender = "boy",
    },
    destinations = { "test.fly.violet", "test.fly.new-bark" },
  }
  local admitted = runtime:queue(fly)
  Assert.equal(admitted.kind, "accepted", "fly admission precedes planning")
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.kind, "fly", "fly stages a destination-choice plan")
  Assert.equal(plan.phase, "choose_destination", "fly waits in its choice phase")
  Assert.isTrue(runtime:isBusy(), "the staged choice holds the runtime gate")
  local outcome = runtime:advance(plan)
  Assert.equal(outcome.kind, "running", "the choice waits without travel")
  Assert.equal(world.warpCalls.begin, 0, "waiting on selection starts no warp")
  Assert.isTrue(runtime:isBusy(), "the waiting choice keeps the runtime gate")
  runtime:dispose()
  Assert.isFalse(runtime:isBusy(), "disposing the waiting choice releases the gate")
end

return { tests = T }
