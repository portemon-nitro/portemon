-- FieldMoveRuntime: single pending/active admission, closed plan dispatch,
-- revision-qualified requests, and map-lifetime strength arming. Pure
-- coordination over injected policy/world; the world owns every physical
-- write. Queue admission decides eligibility before the application closes;
-- planning revalidates; commit happens exactly once through advance.

local Assert = require("tests.support.Assert")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")

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
    facingObstacle = "cut_tree",
    facingActor = {
      identity = "map:61:object:0",
      obstacleKind = "cut_tree",
      mapSymbol = "test-map",
      fieldX = 6,
      fieldZ = 3,
    },
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

local function worldDouble(overrides)
  local world = {
    plans = 0,
    advances = 0,
    cancels = 0,
    activatedStrength = 0,
    facingTarget = nil,
    planResult = nil,
    advanceResult = nil,
    captureContext = function(_)
      error("unexpected captureContext", 0)
    end,
    resolveFacingTarget = function(self)
      return self.facingTarget
    end,
    validateTarget = function(_)
      return nil
    end,
    validatePush = function(_)
      return nil
    end,
    removeObstacle = function(_) end,
    beginPush = function(_) end,
    advancePush = function(_)
      return true
    end,
    commitPush = function(_) end,
    cancelMotion = function(self)
      self.cancels = self.cancels + 1
    end,
    activateStrength = function(self)
      self.activatedStrength = self.activatedStrength + 1
      return true
    end,
    applyFlash = function(_) end,
  }
  for key, value in pairs(overrides or {}) do
    world[key] = value
  end
  return world
end

local function open(world)
  return FieldMoveRuntime.new({ policy = FieldMovePolicy, context = context(), world = world or worldDouble() }) --[[@as FieldMoveRuntimePort]]
end

function T.queue_accepts_an_eligible_cut_request()
  local runtime = open()
  local outcome = runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = context() })
  Assert.equal(outcome.kind, "accepted")
  Assert.isTrue(runtime:isBusy(), "an accepted queue holds the runtime")
end

function T.queue_refuses_without_badge_before_the_application_closes()
  local runtime = open()
  local poor = context({ badges = 0 })
  local outcome = runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = poor })
  Assert.equal(outcome.kind, "need_badge", "admission decides eligibility, got " .. tostring(outcome.kind))
  Assert.isFalse(runtime:isBusy(), "a refused queue holds nothing")
end

function T.queue_rejects_a_second_request_without_mutation()
  local runtime = open()
  Assert.equal(runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = context() }).kind, "accepted")
  local pendingBefore = runtime:takePending()
  Assert.equal(pendingBefore.move, "cut")
  local outcome = runtime:queue({ move = "flash", slot = 1, partyRevision = 4, context = context() })
  Assert.equal(outcome.kind, "busy", "an active operation rejects newcomers")
end

function T.take_pending_asserts_when_nothing_is_queued()
  local runtime = open()
  local err = Assert.throws(function()
    runtime:takePending()
  end)
  Assert.notNil(tostring(err):find("pending"), "takePending names the missing queue")
end

function T.discard_pending_releases_an_unclaimed_queue()
  local runtime = open()
  runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = context() })
  runtime:discardPending()
  Assert.isFalse(runtime:isBusy(), "discard releases the runtime")
  local err = Assert.throws(function()
    runtime:takePending()
  end)
  Assert.notNil(err, "discarded queue cannot be taken")
end

function T.stale_facing_actor_fails_at_queue_time()
  local world = worldDouble()
  local resync = FieldMoveRuntime.new({ policy = FieldMovePolicy, context = context(), world = world }) --[[@as FieldMoveRuntimePort]]
  world.facingTarget = { actorId = "map:61:object:9", obstacleKind = "cut_tree", mapId = 61 }
  local outcome = resync:queue({ move = "cut", slot = 0, partyRevision = 4, context = context() })
  Assert.equal(outcome.kind, "stale", "a moved actor fails before the application closes")
  Assert.isFalse(resync:isBusy(), "stale queue holds nothing")
end

function T.plan_builds_a_serializable_cut_plan()
  local runtime = open()
  local plan = runtime:plan({ move = "cut", slot = 0, partyRevision = 4, context = context() })
  Assert.equal(plan.kind, "cut")
  Assert.equal(plan.target.actorId, "map:61:object:0")
  Assert.isFalse(plan.committed, "fresh plans are uncommitted")
  Assert.isNil(plan.committedAt, "no function or pointer state crosses the plan")
end

function T.plan_returns_feature_unavailable_for_deferred_traversal()
  local runtime = open()
  local outcome = runtime:plan({ move = "surf", slot = 0, partyRevision = 4, context = context({ surfEdge = true }) })
  Assert.equal(outcome.kind, "feature_unavailable", "water traversal is honestly deferred")
end

function T.advance_commits_exactly_once_then_settles()
  local world = worldDouble()
  local runtime = open(world)
  runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = context() })
  local request = runtime:takePending()
  local plan = runtime:plan(request)
  local guard = 0
  local last = nil
  while guard < 50 do
    guard = guard + 1
    last = runtime:advance(plan)
    if last.kind ~= "running" then
      break
    end
  end
  last = assert(last, "the advance loop must settle")
  Assert.equal(last.kind, "done", "acknowledge then commit settles")
  Assert.isTrue(plan.committed, "commit ran once")
  Assert.isFalse(runtime:isBusy(), "done clears the active marker")
  local again = runtime:advance(plan)
  Assert.equal(again.kind, "done", "a settled plan never recommits")
end

function T.cancel_clears_active_and_releases_motion_once()
  local world = worldDouble()
  local runtime = open(world)
  runtime:queue({ move = "cut", slot = 0, partyRevision = 4, context = context() })
  local request = runtime:takePending()
  local plan = runtime:plan(request)
  runtime:cancel(plan)
  Assert.equal(world.cancels, 1, "cancel releases motion exactly once")
  Assert.isFalse(runtime:isBusy(), "cancel clears the active marker")
  runtime:cancel(plan)
  Assert.equal(world.cancels, 1, "cancel is idempotent")
end

function T.strength_arming_is_map_lifetime_and_explicitly_cleared()
  local world = worldDouble()
  local runtime = open(world)
  runtime:queue({
    move = "strength",
    slot = 1,
    partyRevision = 4,
    context = context({
      facingObstacle = "strength_boulder",
      facingActor = {
        identity = "map:61:object:2",
        obstacleKind = "strength_boulder",
        mapSymbol = "test-map",
        fieldX = 4,
        fieldZ = 6,
      },
    }),
  })
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.kind, "enable_strength")
  local guard = 0
  while guard < 50 do
    guard = guard + 1
    if runtime:advance(plan).kind ~= "running" then
      break
    end
  end
  Assert.isTrue(plan.committed, "enablement commits")
  Assert.equal(world.activatedStrength, 1, "enablement commits through the world once")
  local pushAttempt = runtime:tryStrengthPush({ boulderActorId = "map:61:object:2", direction = "south", mapId = 61 })
  Assert.equal(pushAttempt.kind, "accepted", "an armed map accepts pushes")
  runtime:discardPending()
  runtime:clearTransient()
  local cold = runtime:tryStrengthPush({ boulderActorId = "map:61:object:2", direction = "south", mapId = 61 })
  Assert.equal(cold.kind, "not_here", "only an explicit reset disarms strength")
end

function T.unarmed_push_declines_without_queueing()
  local runtime = open()
  local outcome = runtime:tryStrengthPush({ boulderActorId = "map:61:object:2", direction = "south", mapId = 61 })
  Assert.equal(outcome.kind, "not_here", "disarmed pushes decline")
  Assert.isFalse(runtime:isBusy(), "declined pushes queue nothing")
end

return { tests = T }
