-- Fly destination selection owns nothing but its terminal choice: a
-- cancelled selection reports one cancelled result, a repeated
-- confirmation reads back the same single destination, an unknown
-- destination publishes nothing, and a late result from an older
-- operation can never satisfy a newer one because every terminal carries
-- its own operation identity. The field-move runtime underneath stays
-- the sole travel owner: it holds its busy gate while the selector is
-- open and releases it exactly once on unwind, and no warp is ever
-- observed on cancel, repeat, invalid, or stale input. Companion cases
-- cover malformed selector options, the view-only Town selector, the
-- real map-gate refusal, the empty permitted set, mutated-party and
-- unknown-key rejections, stale confirmations, cross-tier travel through
-- the world handoff, and the scheduler task routing its choice through
-- the real companion host with exactly-once cancellation. Runs without
-- a ROM on synthetic catalogs; only host audio/time boundaries are stubbed.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokegearMapFixture")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads the fly selector that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

-- Synthetic companion catalog with two semantic fly destinations over the
-- synthetic region map: location A (flypoint 3) and a second map (flypoint
-- 15), validated through the real asset schema so the scenarios borrow only
-- genuine semantic references. Keys stay symbolic; no coordinates enter any
-- record the selector publishes.
---@return table
local function fixtureManifest()
  local manifest = Fixture.manifest()
  manifest.catalog.locations[1].flypoint = "test.fly.violet"
  manifest.catalog.locations[2] = {
    key = "test.place.nb",
    fieldMap = "MAP_NB",
    mapRef = 75,
    matrix = { x = 5 * 32 + 8, y = 8 * 32 + 8 },
    location = "test.location.nb",
    section = "test.section.nb",
    region = "johto",
    flypoint = "test.fly.new-bark",
  }
  manifest.catalog.flypoints = { { key = "test.fly.violet" }, { key = "test.fly.new-bark" } }
  return manifest
end

-- Source-normalized map context standing on the first flypoint's cell.
---@return table
local function outdoorContext()
  return Fixture.context()
end

-- Source-normalized map context standing on the second flypoint's cell.
---@return table
local function secondContext()
  local context = Fixture.context()
  context.matrixX, context.matrixY = 5 * 32 + 8, 8 * 32 + 8
  context.fieldMap = "MAP_NB"
  return context
end

-- Confirms the destination under the cursor: A opens the Fly/Quit menu and
-- A on "Fly" settles it.
---@param selector table
local function confirmFly(selector)
  selector:updateFixed({ { type = "confirm" } })
  selector:updateFixed({ { type = "confirm" } })
end

-- The real field-move runtime with a permissive eligibility stub and a
-- recording world adapter: the runtime owns queue, busy, and unwind, so
-- the test observes that travel ownership never leaks into the selector.
-- The stub world records every physical call it receives; the scenarios
-- assert that record stays empty.
---@return table runtime, table world
local function ownedRuntime()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local world = { calls = {} }
  function world:cancelMotion(_)
    self.calls[#self.calls + 1] = "cancelMotion"
  end
  local policy = {
    check = function(_, _)
      return { kind = "ok" }
    end,
  }
  return FieldMoveRuntime.new({ policy = policy, world = world }), world
end

---@param controllerClass table
---@param record table
---@param operationId string
---@param context table?
---@param destinations string[]?
---@param effect fun(sequence: string)?
---@return table
local function openSelector(controllerClass, record, operationId, context, destinations, effect)
  return controllerClass.new({
    mode = "fly",
    operationId = operationId,
    context = context or outdoorContext(),
    destinations = destinations or { "test.fly.violet", "test.fly.new-bark" },
    assets = record,
    facts = Fixture.facts(),
    messages = Fixture.messages(),
    effect = effect,
  })
end

-- The operation-identity match the travel handoff applies: only a
-- terminal carrying the live operation identity is consumable, so a late
-- result from an older operation is undeliverable to a newer one.
---@param operationId string
---@param terminal table?
---@return table?
local function acceptResult(operationId, terminal)
  if type(terminal) ~= "table" then
    return nil
  end
  if terminal.operationId ~= operationId then
    return nil
  end
  return terminal
end

-- Cancel reports one cancelled terminal and never warps; a repeated
-- confirmation publishes the same single destination once; an unknown
-- destination publishes nothing; and a late result from the cancelled
-- operation cannot satisfy a newer operation. The runtime busy gate
-- balances exactly once across the whole sequence.
function T.tests.cancelled_and_stale_fly_selections_never_warp()
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no fly destination selector yet: cancel, repeat, invalid, and stale selections cannot resolve without warping"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")

  local runtime, world = ownedRuntime()
  local queued = runtime:queue({ move = "fly", slot = 0, partyRevision = 7 })
  Assert.equal(queued.kind, "accepted", "an eligible fly request is admitted")
  Assert.isTrue(runtime:isBusy(), "the runtime holds its busy gate while the selector is open")

  -- Cancel publishes one cancelled terminal carrying its own operation
  -- identity, and nothing else.
  local first = openSelector(FlyMapController, record, "fly-op-1")
  first:updateFixed({ { type = "cancel" } })
  local cancelled = first:takeResult()
  Assert.notNil(cancelled, "a cancelled selection still reports its terminal result")
  assert(type(cancelled) == "table", "cancel terminal validated above")
  Assert.keySet(cancelled, "kind,operationId", "the cancelled terminal carries only its kind and operation identity")
  Assert.equal(cancelled.kind, "cancelled", "cancel reports cancellation, never a destination")
  Assert.equal(cancelled.operationId, "fly-op-1", "the cancelled terminal names its own operation")
  local reread = first:takeResult()
  Assert.deepEqual(reread, cancelled, "the cancelled terminal reads back identically until closed")
  confirmFly(first)
  Assert.deepEqual(
    first:takeResult(),
    cancelled,
    "confirming after cancel never replaces the cancelled terminal with a destination"
  )
  first:dispose()

  -- A repeated confirmation publishes the same single destination once.
  local second = openSelector(FlyMapController, record, "fly-op-2")
  confirmFly(second)
  local destination = second:takeResult()
  Assert.notNil(destination, "a confirmed selection reports its destination")
  assert(type(destination) == "table", "destination terminal validated above")
  Assert.keySet(
    destination,
    "flypointKey,kind,operationId",
    "the destination terminal carries a semantic flypoint key, never raw coordinates"
  )
  Assert.equal(destination.kind, "destination", "confirmation reports a destination")
  Assert.equal(destination.flypointKey, "test.fly.violet", "the destination names its semantic flypoint")
  Assert.equal(destination.operationId, "fly-op-2", "the destination names its own operation")
  confirmFly(second)
  Assert.deepEqual(second:takeResult(), destination, "repeating confirmation never publishes a second operation")
  second:dispose()

  -- An unknown destination publishes nothing and leaves the pending
  -- selection usable for a genuine choice afterwards.
  local third = openSelector(FlyMapController, record, "fly-op-3", nil, { "test.fly.nowhere" })
  confirmFly(third)
  Assert.isNil(third:takeResult(), "an unpermitted destination publishes no terminal result")
  third:dispose()
  third = openSelector(FlyMapController, record, "fly-op-3", secondContext())
  confirmFly(third)
  local recovered = third:takeResult()
  Assert.notNil(recovered, "a genuine choice still settles after a rejected one")
  assert(type(recovered) == "table", "recovered terminal validated above")
  Assert.equal(recovered.flypointKey, "test.fly.new-bark", "the recovered choice names its semantic flypoint")
  third:dispose()

  -- The cancelled first operation's late terminal can never satisfy the
  -- newer second operation: operation identity rejects it before any map
  -- change, so no stale warp is possible.
  Assert.isNil(
    acceptResult("fly-op-2", cancelled),
    "a late result from the cancelled operation is undeliverable to the newer operation"
  )
  Assert.deepEqual(
    acceptResult("fly-op-2", destination),
    destination,
    "the live operation still consumes its own terminal"
  )

  -- Balanced ownership: unwinding releases the runtime gate exactly once,
  -- disposal is idempotent, and the world adapter observed no travel.
  Assert.isTrue(runtime:isBusy(), "the runtime still owns the operation past the selector terminals")
  runtime:dispose()
  Assert.isFalse(runtime:isBusy(), "unwinding releases the runtime busy gate")
  runtime:dispose()
  Assert.isFalse(runtime:isBusy(), "repeated disposal stays idle without a second release")
  Assert.deepEqual(world.calls, {}, "cancel, repeat, invalid, and stale inputs warped nothing")
end

-- Malformed selector options fail before any effect: an unknown mode, a
-- missing operation identity, and a non-key destination each raise
-- without publishing anything.
function T.tests.malformed_fly_selector_options_fail_before_any_effect()
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no fly destination selector yet: malformed options cannot be rejected"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local function validOptions()
    return {
      mode = "fly",
      operationId = "fly-shape-1",
      context = outdoorContext(),
      destinations = { "test.fly.violet", "test.fly.new-bark" },
      assets = record,
      facts = Fixture.facts(),
    }
  end
  local unknown = validOptions()
  unknown.mode = "map"
  Assert.throws(function()
    FlyMapController.new(unknown)
  end, "an unknown selector mode never opens")
  local anonymous = validOptions()
  anonymous.operationId = ""
  Assert.throws(function()
    FlyMapController.new(anonymous)
  end, "a selector without its operation identity never opens")
  local keyless = validOptions()
  keyless.destinations = { "" }
  Assert.throws(function()
    FlyMapController.new(keyless)
  end, "a non-key destination never opens a selector")
end

-- The view-only Town selector never reports a destination: bare and
-- keyed confirmations settle nothing, and cancellation reports one
-- cancelled terminal carrying only its kind and operation identity.
function T.tests.view_only_town_selector_never_reports_a_destination()
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no view-only town selector yet: confirmations cannot stay destination-free"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local town = FlyMapController.new({
    mode = "townMap",
    operationId = "town-view-1",
    assets = record,
    facts = Fixture.facts(),
    context = outdoorContext(),
  })
  town:updateFixed({ { type = "confirm" } })
  Assert.isNil(town:takeResult(), "a view-only confirmation settles nothing")
  town:updateFixed({ { type = "confirm" }, { type = "confirm" } })
  Assert.isNil(town:takeResult(), "a keyed confirmation never emits a destination from a view-only map")
  town:updateFixed({ { type = "cancel" } })
  local closed = town:takeResult()
  Assert.notNil(closed, "cancelling the view-only map reports its terminal")
  assert(type(closed) == "table", "close terminal validated above")
  Assert.keySet(closed, "kind,operationId", "the view-only close carries only its kind and operation identity")
  Assert.equal(closed.kind, "cancelled", "the view-only close reports cancellation")
  town:updateFixed({ { type = "confirm" }, { type = "confirm" } })
  Assert.deepEqual(town:takeResult(), closed, "confirming after close never replaces the terminal")
  town:dispose()
end

-- A recording world adapter behind the real eligibility policy: queue
-- and plan observably refuse or stage without touching travel.
---@return table runtime, table world
local function policyRuntime()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
  local world = { calls = {} }
  function world:cancelMotion(_)
    self.calls[#self.calls + 1] = "cancelMotion"
  end
  return FieldMoveRuntime.new({ policy = FieldMovePolicy, world = world }), world
end

---@param flyAllowed boolean
---@return table
local function mapGateContext(flyAllowed)
  return {
    mapId = 33,
    badges = 16,
    fieldUse = { flyAllowed = flyAllowed },
    humanFollower = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
  }
end

-- The map gate refuses Fly before admission on maps that forbid it,
-- while an eligible request is admitted through the real badge, map,
-- and escort checks.
function T.tests.indoor_fly_requests_fail_the_map_gate()
  local runtime, world = policyRuntime()
  local refused = runtime:queue({ move = "fly", slot = 0, partyRevision = 7, context = mapGateContext(false) })
  Assert.equal(refused.kind, "not_here", "a map forbidding fly refuses before admission")
  Assert.isFalse(runtime:isBusy(), "a refused request holds no operation")
  local admitted = runtime:queue({ move = "fly", slot = 0, partyRevision = 7, context = mapGateContext(true) })
  Assert.equal(admitted.kind, "accepted", "an eligible fly request is admitted through the real checks")
  Assert.isTrue(runtime:isBusy(), "an admitted request holds the operation")
  runtime:dispose()
  Assert.deepEqual(world.calls, {}, "eligibility checks warp nothing")
end

-- An admitted Fly request with no eligible destinations refuses before
-- selection instead of opening an empty selector, releasing the gate.
function T.tests.fly_choice_without_eligible_destinations_refuses_before_selection()
  local runtime, world = ownedRuntime()
  local admitted = runtime:queue({
    move = "fly",
    slot = 0,
    partyRevision = 7,
    context = { mapId = 33 },
    mapContext = outdoorContext(),
    destinations = {},
  })
  Assert.equal(admitted.kind, "accepted", "admission precedes destination staging")
  local decision = runtime:plan(runtime:takePending())
  Assert.equal(decision.kind, "not_now", "an empty permitted set refuses before selection")
  Assert.isFalse(runtime:isBusy(), "a refused plan releases the runtime gate")
  runtime:dispose()
  Assert.deepEqual(world.calls, {}, "a refused plan warps nothing")
end

-- A world double behind the travel handoff: semantic resolution,
-- source-map revalidation, and the existing return-warp owner.
---@return table world
local function travelWorld()
  local world = { calls = {}, done = false, errorValue = nil }
  function world:cancelMotion(_)
    self.calls[#self.calls + 1] = "cancelMotion"
  end
  function world:validateTarget(_)
    return nil
  end
  function world:planFly(flypointKey, _)
    self.calls[#self.calls + 1] = { op = "planFly", flypointKey = flypointKey }
    return { map = "test.field.kanto-route", warp = 0, fieldX = 3, fieldZ = 9, facing = "south" }
  end
  function world:beginReturnWarp(plan)
    self.calls[#self.calls + 1] = { op = "beginReturnWarp" }
    assert(plan.destination ~= nil, "fly warps start from a resolved destination")
    plan.warpStarted = true
  end
  function world:returnWarpDone(_)
    return self.done
  end
  function world:returnWarpError(_)
    return self.errorValue
  end
  return world
end

---@param runtime table
---@return table plan the staged fly plan
local function stageFlyChoice(runtime)
  local admitted = runtime:queue({
    move = "fly",
    slot = 0,
    partyRevision = 7,
    context = { mapId = 33 },
    mapContext = outdoorContext(),
    destinations = { "test.fly.violet", "test.fly.new-bark" },
  })
  Assert.equal(admitted.kind, "accepted", "an eligible fly request is admitted")
  local plan = runtime:plan(runtime:takePending())
  Assert.equal(plan.kind, "fly", "fly stages a destination-choice plan")
  Assert.equal(plan.phase, "choose_destination", "fly waits in its choice phase")
  return plan
end

-- A party change after opening rejects the confirmed choice: the
-- operation abandons without travel and the gate releases.
function T.tests.party_changes_after_opening_reject_the_confirmed_choice()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local world = travelWorld()
  local policy = {
    check = function(_, _)
      return { kind = "ok" }
    end,
  }
  local runtime = FieldMoveRuntime.new({ policy = policy, world = world })
  local plan = stageFlyChoice(runtime)
  local stale = runtime:confirmFlyDestination(
    plan,
    { kind = "destination", operationId = "fly-party-1", flypointKey = "test.fly.violet" },
    8
  )
  Assert.equal(stale.kind, "stale", "a mutated party rejects the choice")
  Assert.equal(stale.reason, "party_changed", "the rejection names its party drift")
  Assert.isFalse(runtime:isBusy(), "a rejected choice releases the runtime gate")
  for _, call in ipairs(world.calls) do
    Assert.isTrue(call ~= "beginReturnWarp", "a rejected choice starts no warp")
    if type(call) == "table" then
      Assert.isTrue(call.op ~= "planFly", "a rejected choice resolves no destination")
    end
  end
  runtime:dispose()
end

-- A confirmed key outside the permitted set rejects the choice without
-- travel and releases the gate.
function T.tests.unknown_destinations_reject_the_confirmed_choice()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local world = travelWorld()
  local policy = {
    check = function(_, _)
      return { kind = "ok" }
    end,
  }
  local runtime = FieldMoveRuntime.new({ policy = policy, world = world })
  local plan = stageFlyChoice(runtime)
  local stale = runtime:confirmFlyDestination(
    plan,
    { kind = "destination", operationId = "fly-unknown-1", flypointKey = "test.fly.nowhere" },
    7
  )
  Assert.equal(stale.kind, "stale", "an unknown destination rejects the choice")
  Assert.equal(stale.reason, "unknown_destination", "the rejection names its unknown key")
  Assert.isFalse(runtime:isBusy(), "a rejected choice releases the runtime gate")
  Assert.deepEqual(world.calls, {}, "a rejected choice warps nothing")
  runtime:dispose()
end

-- A confirmation against a settled operation touches nothing: the late
-- result never warps a newer state.
function T.tests.stale_confirmations_against_settled_operations_touch_nothing()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local world = travelWorld()
  local policy = {
    check = function(_, _)
      return { kind = "ok" }
    end,
  }
  local runtime = FieldMoveRuntime.new({ policy = policy, world = world })
  local plan = stageFlyChoice(runtime)
  runtime:dispose()
  world.calls = {}
  local stale = runtime:confirmFlyDestination(
    plan,
    { kind = "destination", operationId = "fly-late-1", flypointKey = "test.fly.violet" },
    7
  )
  Assert.equal(stale.kind, "stale", "a late confirmation against a settled operation is stale")
  Assert.deepEqual(world.calls, {}, "a stale confirmation warps nothing")
  runtime:dispose()
end

-- A confirmed choice travels across tiers through the world handoff:
-- the semantic key resolves once, the warp starts once through the
-- existing return-warp owner, and arrival settles the operation.
function T.tests.confirmed_fly_choice_travels_across_tiers_through_the_world_handoff()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local world = travelWorld()
  local policy = {
    check = function(_, _)
      return { kind = "ok" }
    end,
  }
  local runtime = FieldMoveRuntime.new({ policy = policy, world = world })
  local plan = stageFlyChoice(runtime)
  local confirmed = runtime:confirmFlyDestination(
    plan,
    { kind = "destination", operationId = "fly-travel-1", flypointKey = "test.fly.violet" },
    7
  )
  Assert.equal(confirmed.kind, "confirmed", "a live choice confirms")
  Assert.equal(plan.phase, "acknowledge", "a confirmed choice enters acknowledgement")
  world.done = true
  local outcome = nil
  for _ = 1, 40 do
    outcome = runtime:advance(plan)
    if outcome.kind ~= "running" then
      break
    end
  end
  Assert.notNil(outcome, "the travel must settle")
  assert(outcome ~= nil, "travel outcome validated above")
  Assert.equal(outcome.kind, "done", "validated travel runs to done")
  Assert.equal(plan.phase, "complete", "arrival completes the choice stages")
  local plans, starts = 0, 0
  for _, call in ipairs(world.calls) do
    if type(call) == "table" and call.op == "planFly" then
      plans = plans + 1
      Assert.equal(call.flypointKey, "test.fly.violet", "resolution carries the confirmed key")
    end
    if type(call) == "table" and call.op == "beginReturnWarp" then
      starts = starts + 1
    end
  end
  Assert.equal(plans, 1, "travel resolves its destination exactly once")
  Assert.equal(starts, 1, "travel starts its warp exactly once")
  Assert.equal(plan.destination.map, "test.field.kanto-route", "the other-tier destination arrives")
  Assert.isFalse(runtime:isBusy(), "arrival releases the runtime gate")
  runtime:dispose()
end

-- A real companion host behind task-driven choice: durable gear state
-- and the validated catalog, with no audio or random owners since
-- selection draws no tones or streams.
---@return table host
local function choiceHost()
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearScriptHost = require("game.hgss.src.pokegear.PokegearScriptHost")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local state = PokegearState.new({ seed = 4242 }, { catalog = record.catalog })
  return PokegearScriptHost.new({
    state = state,
    catalog = record.catalog,
    messages = {},
    world = { player = { x = 1, y = 2 } },
    assets = record,
    regionMapOwners = function()
      return Fixture.messages(), Fixture.facts()
    end,
  })
end

---@param runtime table
---@param host table
---@param uiEvents table
---@param revision integer
---@return table ctx
local function choiceTaskContext(runtime, host, uiEvents, revision)
  return {
    services = {
      fieldMoves = runtime,
      pokegearApplications = host,
      mons = {
        partyRevision = function(_)
          return revision
        end,
      },
    },
    input = { uiEvents = uiEvents },
    taskId = "task-fly-1",
  }
end

-- A staged fly request behind the scheduler task, ready for the first
-- choice poll.
---@param runtime table
---@param host table
---@return table state
local function stageFlyTask(runtime, host)
  local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
  local admitted = runtime:queue({
    move = "fly",
    slot = 0,
    partyRevision = 7,
    context = { mapId = 33 },
    mapContext = outdoorContext(),
    destinations = { "test.fly.violet", "test.fly.new-bark" },
  })
  Assert.equal(admitted.kind, "accepted", "an eligible fly request is admitted")
  local ctx = choiceTaskContext(runtime, host, {}, 7)
  local state = FieldMoveTask.create({ source = "pending" }, ctx)
  Assert.isNil(state.refused, "fly stages an executable choice")
  Assert.isNil(FieldMoveTask.validate(state), "fly choice state stays serializable")
  return state
end

-- The scheduler task routes only its active choice through the
-- companion host: the first poll opens the selector, scheduler events
-- confirm through it, and the one terminal feeds back into validated
-- travel with exactly one destination resolution and one warp start.
function T.tests.fly_task_routes_its_choice_through_the_companion_host()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
  local world = travelWorld()
  local policy = {
    check = function(_, _)
      return { kind = "ok" }
    end,
  }
  local runtime = FieldMoveRuntime.new({ policy = policy, world = world })
  local host = choiceHost()
  local state = stageFlyTask(runtime, host)
  local opened = FieldMoveTask.poll(state, choiceTaskContext(runtime, host, {}, 7))
  Assert.isFalse(opened.complete, "opening the selector waits for its choice")
  Assert.isTrue(host:isActive(), "the choice opens the companion selector")
  Assert.isTrue(runtime:isBusy(), "the runtime holds its gate across the choice")
  local confirmed =
    FieldMoveTask.poll(state, choiceTaskContext(runtime, host, { { type = "confirm" }, { type = "confirm" } }, 7))
  Assert.isFalse(confirmed.complete, "a confirmed choice continues into travel")
  Assert.isFalse(host:isActive(), "the consumed choice closes its selector exactly once")
  world.done = true
  local outcome = nil
  for _ = 1, 40 do
    local step = FieldMoveTask.poll(state, choiceTaskContext(runtime, host, {}, 7))
    if step.complete then
      outcome = step.result
      break
    end
  end
  Assert.notNil(outcome, "the choice must settle through travel")
  assert(type(outcome) == "table", "travel outcome validated above")
  Assert.equal(outcome.kind, "field_move_done", "validated travel reports done")
  Assert.equal(outcome.move, "fly", "completion names the executed choice")
  local plans, starts = 0, 0
  for _, call in ipairs(world.calls) do
    if type(call) == "table" and call.op == "planFly" then
      plans = plans + 1
      Assert.equal(call.flypointKey, "test.fly.violet", "resolution carries the confirmed key")
    end
    if type(call) == "table" and call.op == "beginReturnWarp" then
      starts = starts + 1
    end
  end
  Assert.equal(plans, 1, "the choice resolves its destination exactly once")
  Assert.equal(starts, 1, "the choice starts its warp exactly once")
  Assert.isFalse(runtime:isBusy(), "arrival releases the runtime gate")
  Assert.isTrue(host:isStableForSave(), "the settled choice captures saves again")
  host:dispose()
  runtime:dispose()
end

-- Cancelling the task mid-choice closes the selector and releases the
-- operation once each: no destination resolves, no warp starts, and the
-- cancelled task never polls again.
function T.tests.fly_task_cancellation_closes_the_selector_and_releases()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
  local world = travelWorld()
  local policy = {
    check = function(_, _)
      return { kind = "ok" }
    end,
  }
  local runtime = FieldMoveRuntime.new({ policy = policy, world = world })
  local host = choiceHost()
  local state = stageFlyTask(runtime, host)
  local ctx = choiceTaskContext(runtime, host, {}, 7)
  local opened = FieldMoveTask.poll(state, ctx)
  Assert.isFalse(opened.complete, "opening the selector waits for its choice")
  Assert.isTrue(host:isActive(), "the choice opens the companion selector")
  FieldMoveTask.cancel(state, "test cancel", ctx)
  Assert.equal(state.cancelled, "test cancel", "cancel marks serializable state")
  Assert.isFalse(host:isActive(), "cancellation closes the selector")
  Assert.isFalse(runtime:isBusy(), "cancellation releases the operation")
  Assert.deepEqual(world.calls, { "cancelMotion" }, "cancellation releases motion once and starts nothing")
  local ok = pcall(function()
    FieldMoveTask.poll(state, ctx)
  end)
  Assert.isFalse(ok, "a cancelled choice task never polls again")
  host:dispose()
  runtime:dispose()
end

-- Cancelling the staged choice releases motion and the gate exactly
-- once; repeated cancellation stays idle without a second release.
function T.tests.cancelled_fly_choice_releases_without_travel()
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local world = travelWorld()
  local policy = {
    check = function(_, _)
      return { kind = "ok" }
    end,
  }
  local runtime = FieldMoveRuntime.new({ policy = policy, world = world })
  local plan = stageFlyChoice(runtime)
  runtime:cancel(plan)
  Assert.isFalse(runtime:isBusy(), "cancelling the choice releases the gate")
  runtime:cancel(plan)
  Assert.isFalse(runtime:isBusy(), "repeated cancellation stays idle")
  Assert.deepEqual(world.calls, { "cancelMotion" }, "cancellation releases motion once and warps nothing")
  runtime:dispose()
end

-- The source map application ignores keys and new touches while the
-- cursor tween runs (two ticks per cell): A never opens the Fly/Quit
-- menu mid-tween, B never cancels mid-tween, and a fresh touch never
-- reselects mid-tween. Input applies again once the tween settles.
function T.tests.input_waits_for_the_cursor_tween()
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no fly destination selector yet: gated input cannot resolve without it"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")

  local selector = openSelector(FlyMapController, record, "fly-op-tween-confirm")
  selector:updateFixed({ { type = "navigate", direction = "right" } })
  selector:updateFixed({ { type = "confirm" } })
  Assert.isNil(selector:status().view.menu, "A during the cursor tween opens no menu")
  selector:updateFixed({})
  selector:updateFixed({ { type = "confirm" } })
  Assert.notNil(selector:status().view.menu, "A once idle opens the Fly/Quit menu")
  selector:dispose()

  local cancelling = openSelector(FlyMapController, record, "fly-op-tween-cancel")
  cancelling:updateFixed({ { type = "navigate", direction = "right" } })
  cancelling:updateFixed({ { type = "cancel" } })
  Assert.isNil(cancelling:takeResult(), "B during the cursor tween cancels nothing")
  cancelling:updateFixed({})
  cancelling:updateFixed({ { type = "cancel" } })
  local terminal = cancelling:takeResult()
  Assert.notNil(terminal, "B once idle still cancels the selector")
  assert(type(terminal) == "table", "cancel terminal validated above")
  Assert.equal(terminal.kind, "cancelled", "the idle cancel reports cancellation")
  cancelling:dispose()

  local touching = openSelector(FlyMapController, record, "fly-op-tween-touch")
  touching:updateFixed({ { type = "navigate", direction = "right" } })
  touching:updateFixed({ { type = "pointer_down", pointerId = "t", x = 40, y = 16 } })
  Assert.isNil(touching:status().view.menu, "a touch during the cursor tween opens no menu")
  Assert.equal(
    touching:status().view.panel.landmark,
    "Landmark 41",
    "a touch during the cursor tween reselects nothing"
  )
  touching:dispose()
end

-- The source list menu reports no input for taps outside its frame, so
-- the Fly/Quit menu stays open until Fly or Quit settles it: an outside
-- tap keeps the prompt naming the destination, and Quit returns to the
-- map with the neutral prompt and no terminal.
function T.tests.taps_outside_the_fly_menu_keep_it_open()
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no fly destination selector yet: menu taps cannot resolve without it"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local selector = openSelector(FlyMapController, record, "fly-op-menu-tap")
  selector:updateFixed({ { type = "confirm" } })
  Assert.notNil(selector:status().view.menu, "A on a flypoint opens the Fly/Quit menu")
  selector:updateFixed({ { type = "pointer_down", pointerId = "t", x = 8, y = 8 } })
  selector:updateFixed({ { type = "pointer_up", pointerId = "t", x = 8, y = 8 } })
  Assert.notNil(selector:status().view.menu, "a tap outside the menu frame keeps it open")
  Assert.isNil(selector:takeResult(), "the outside tap settles no terminal")
  Assert.equal(
    selector:status().view.prompt,
    "Fly to Landmark 41?",
    "the open menu keeps naming the destination"
  )
  selector:updateFixed({ { type = "navigate", direction = "down" } })
  selector:updateFixed({ { type = "confirm" } })
  Assert.isNil(selector:status().view.menu, "Quit closes the menu")
  Assert.isNil(selector:takeResult(), "Quit settles no destination")
  Assert.equal(
    selector:status().view.prompt,
    "Choose your destination.",
    "quitting restores the neutral prompt"
  )
  selector:dispose()
end

function T.tests.fly_card_plays_its_source_tones()
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no fly destination selector yet: card tones cannot resolve without it"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local effects = {}
  local function play(sequence)
    effects[#effects + 1] = sequence
  end
  local selector = openSelector(FlyMapController, record, "fly-op-sound", nil, nil, play)
  selector:updateFixed({ { type = "confirm" } })
  Assert.notNil(selector:status().view.menu, "A on a destination opens the menu")
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARDECIDE", "opening the menu plays the decide tone")
  selector:dispose()
  -- Each gate check runs on the tick right after the move starts: any
  -- further tick settles the two-tick tween, so each uses its own selector.
  local effectsBefore = #effects
  local gatedConfirm = openSelector(FlyMapController, record, "fly-op-sound-gated-a", nil, nil, play)
  gatedConfirm:updateFixed({ { type = "navigate", direction = "right" } })
  gatedConfirm:updateFixed({ { type = "confirm" } })
  Assert.isNil(gatedConfirm:status().view.menu, "A during the cursor tween opens no menu")
  Assert.equal(#effects, effectsBefore, "a gated confirm plays nothing")
  gatedConfirm:dispose()
  local gatedCancel = openSelector(FlyMapController, record, "fly-op-sound-gated-b", nil, nil, play)
  gatedCancel:updateFixed({ { type = "navigate", direction = "right" } })
  gatedCancel:updateFixed({ { type = "cancel" } })
  Assert.isNil(gatedCancel:takeResult(), "B during the cursor tween cancels nothing")
  Assert.equal(#effects, effectsBefore, "a gated cancel plays nothing")
  gatedCancel:dispose()
  local cancelling = openSelector(FlyMapController, record, "fly-op-sound-cancel", nil, nil, play)
  cancelling:updateFixed({ { type = "cancel" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCANCEL", "B plays the cancel tone")
  Assert.equal(cancelling:takeResult().kind, "cancelled", "B still cancels the selector")
  cancelling:dispose()
  local closer = openSelector(FlyMapController, record, "fly-op-sound-touch-close", nil, nil, play)
  closer:updateFixed({ { type = "pointer_down", pointerId = "t", x = 220, y = 168 } })
  Assert.equal(closer:takeResult().kind, "cancelled", "touching Close cancels the selector")
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCANCEL", "touching Close plays the cancel tone")
  closer:dispose()
  local touching = openSelector(FlyMapController, record, "fly-op-sound-touch-map", nil, nil, play)
  local mapBefore = #effects
  touching:updateFixed({ { type = "pointer_down", pointerId = "t", x = 100, y = 100 } })
  local found = false
  for index = mapBefore + 1, #effects do
    if effects[index] == "SEQ_SE_GS_GEARMAPTOUCH" then
      found = true
    end
  end
  Assert.isTrue(found, "touching the map plays the touch tone")
  touching:dispose()
end

-- The fly information panel mirrors the gear card: the rematch/gift icon
-- resolves through the shared phone projection and the saved marking
-- through the durable companion owner, both optional readers the
-- view-only and synthetic entries omit. Town mode keeps only the name.
function T.tests.fly_panel_shows_markings_and_battle_icon()
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no fly destination selector yet: the panel cannot show markings without it"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local facts = Fixture.facts()
  facts.markingFor = function(symbol)
    if symbol == "MAP_A" then
      return { icons = { 2, false, false, false }, words = { "7", false, false, false } }
    end
    return nil
  end
  facts.rematchOnMap = function(mapId)
    return mapId == 10
  end
  local selector = FlyMapController.new({
    mode = "fly",
    operationId = "fly-op-panel",
    context = outdoorContext(),
    destinations = { "test.fly.violet", "test.fly.new-bark" },
    assets = record,
    facts = facts,
    messages = Fixture.messages(),
  })
  local panel = selector:status().view.panel
  Assert.equal(panel.markers[1], 2, "the fly panel shows the saved marking icon")
  Assert.equal(panel.words[1], "Word 7", "the fly panel resolves the saved marking word")
  Assert.isTrue(panel.battleIcon, "the fly panel shows the rematch icon on a ready map")
  selector:dispose()
  local town = FlyMapController.new({
    mode = "townMap",
    operationId = "town-op-panel",
    context = outdoorContext(),
    destinations = {},
    assets = record,
    facts = facts,
    messages = Fixture.messages(),
  })
  local townPanel = town:status().view.panel
  Assert.isNil(townPanel.markers[1], "the town map prints no marking icons")
  Assert.isNil(townPanel.words[1], "the town map prints no marking words")
  Assert.isNil(townPanel.battleIcon, "the town map shows no battle icon")
  town:dispose()
end

-- Host-opened maps borrow the shared information-pane readers: the fly
-- entry shows saved markings and the rematch icon through them, while
-- the town entry without panel owners keeps the previous bare facts.
function T.tests.host_map_entries_carry_the_shared_panel_readers()
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no fly destination selector yet: host panel readers cannot resolve without it"
  )
  assert(FlyMapController ~= nil, "fly selector checked above")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearScriptHost = require("game.hgss.src.pokegear.PokegearScriptHost")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local state = PokegearState.new({ seed = 4242 }, { catalog = record.catalog })
  local host = PokegearScriptHost.new({
    state = state,
    catalog = record.catalog,
    messages = {},
    world = { player = { x = 1, y = 2 } },
    assets = record,
    regionMapOwners = function()
      return Fixture.messages(), Fixture.facts()
    end,
    mapPanel = {
      markingFor = function(symbol)
        if symbol == "MAP_A" then
          return { icons = { 2, false, false, false }, words = { "7", false, false, false } }
        end
        return nil
      end,
      rematchOnMap = function(mapId)
        return mapId == 10
      end,
    },
  })
  local townHandle = host:open({ mode = "townMap", parentOwner = "script:test" })
  local townPanel = host._active.controller:status().view.panel
  Assert.isNil(townPanel.markers[1], "the town map prints no marking icons")
  host:close(townHandle)
  local context = outdoorContext()
  local flyHandle = host:open({
    mode = "fly",
    parentOwner = "script:test",
    selection = { slot = 0, mapContext = context, destinations = { "test.fly.violet" } },
  })
  local flyPanel = host._active.controller:status().view.panel
  Assert.equal(flyPanel.markers[1], 2, "the hosted fly entry shows the saved marking icon")
  Assert.equal(flyPanel.words[1], "Word 7", "the hosted fly entry resolves the saved marking word")
  Assert.isTrue(flyPanel.battleIcon, "the hosted fly entry shows the rematch icon")
  host:close(flyHandle)
  host:dispose()
end

return T
