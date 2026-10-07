-- Opcode-599 recall task: a visible follower runs the native movement and
-- vector choreography, then shrinks through quartered billboard scales,
-- hides on the final scale step, holds hidden through the effect tail, and
-- snaps onto the player anchor with identity scale and one armed transition
-- for the next real walk. Inactive or already-hidden followers complete with
-- no work, and cancellation cleans only task-owned transient state without
-- touching the shared transition effect.
--
-- This contract runs against the opcode-599 recall task module directly.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local RecallTask = require("libs.hgss.src.script.tasks.FollowerRecallTask")

local T = {}

-- Native HGSS model-space increments behind state 4, kept here as the
-- source reference. Runtime presentation offsets are in world units (one
-- unit per tile) with 16 model units per tile, so every expectation below
-- is normalized by 1/16 at this source/runtime seam.
local NATIVE_Y = { 1, 2, 2, 3, 3, 2, 2, 0 }
local NATIVE_Z = { 4, 4, 4, 2, 2, 2, 0, 0 }
local MODEL_UNITS_PER_TILE = 16

-- Independent source-to-runtime expectations: cumulative native sums divided
-- by the tile size, written as literal fractions so the test never
-- re-blesses the unnormalized algorithm. Final end points are x = +/-1,
-- y = 15/16, z = -18/16 tiles.
---@param mirror boolean
---@return table<integer, { x: number, y: number, z: number }>
local function expectedOffsets(mirror)
  local sign = mirror and 1 or -1
  return {
    { x = sign * 2 / MODEL_UNITS_PER_TILE, y = 1 / MODEL_UNITS_PER_TILE, z = -4 / MODEL_UNITS_PER_TILE },
    { x = sign * 4 / MODEL_UNITS_PER_TILE, y = 3 / MODEL_UNITS_PER_TILE, z = -8 / MODEL_UNITS_PER_TILE },
    { x = sign * 6 / MODEL_UNITS_PER_TILE, y = 5 / MODEL_UNITS_PER_TILE, z = -12 / MODEL_UNITS_PER_TILE },
    { x = sign * 8 / MODEL_UNITS_PER_TILE, y = 8 / MODEL_UNITS_PER_TILE, z = -14 / MODEL_UNITS_PER_TILE },
    { x = sign * 10 / MODEL_UNITS_PER_TILE, y = 11 / MODEL_UNITS_PER_TILE, z = -16 / MODEL_UNITS_PER_TILE },
    { x = sign * 12 / MODEL_UNITS_PER_TILE, y = 13 / MODEL_UNITS_PER_TILE, z = -18 / MODEL_UNITS_PER_TILE },
    { x = sign * 14 / MODEL_UNITS_PER_TILE, y = 15 / MODEL_UNITS_PER_TILE, z = -18 / MODEL_UNITS_PER_TILE },
    { x = sign * 16 / MODEL_UNITS_PER_TILE, y = 15 / MODEL_UNITS_PER_TILE, z = -18 / MODEL_UNITS_PER_TILE },
  }
end

-- Cross-checks the literal table above against the native source sums so a
-- transcription slip fails loudly instead of freezing a wrong constant.
for _, mirror in ipairs({ false, true }) do
  local sign = mirror and 1 or -1
  local literal = expectedOffsets(mirror)
  local x, y, z = 0, 0, 0
  for index = 1, 8 do
    x = x + sign * 2
    y = y + NATIVE_Y[index]
    z = z - NATIVE_Z[index]
    assert(
      literal[index].x == x / MODEL_UNITS_PER_TILE
        and literal[index].y == y / MODEL_UNITS_PER_TILE
        and literal[index].z == z / MODEL_UNITS_PER_TILE,
      "recall test expectations drift from native source sums"
    )
  end
end

local function harness(options)
  local log = {}
  local settled = { value = options.settled }
  if settled.value == nil then
    settled.value = true
  end
  ---@class RecallHarnessState
  local fake = {
    log = log,
    settled = settled,
    active = options.active,
    visible = options.visible,
    mirror = options.mirror,
    nextState = options.nextState,
    scaleValue = 1,
    scales = {},
    hides = 0,
    shows = 0,
    latchArms = 0,
  }
  local followingMon = {}
  function followingMon:isSourceActive()
    log[#log + 1] = "isSourceActive"
    return fake.active
  end
  function followingMon:isPartnerVisible()
    log[#log + 1] = "isPartnerVisible"
    return fake.visible
  end
  function followingMon:setMovementPaused(paused)
    log[#log + 1] = { "setMovementPaused", paused }
  end
  function followingMon:isMovementSettled()
    log[#log + 1] = "isMovementSettled"
    return fake.settled.value
  end
  function followingMon:settleMovement()
    log[#log + 1] = "settleMovement"
  end
  function followingMon:classifyRecallGeometry()
    log[#log + 1] = "classifyRecallGeometry"
    return { mirror = fake.mirror, nextState = fake.nextState }
  end
  function followingMon:startRecallMovement(kind)
    log[#log + 1] = { "startRecallMovement", kind }
  end
  function followingMon:setRecallPresentationOffset(offset)
    log[#log + 1] = { "setRecallPresentationOffset", { x = offset.x, y = offset.y, z = offset.z } }
  end
  function followingMon:clearRecallPresentationOffset()
    log[#log + 1] = "clearRecallPresentationOffset"
  end
  function followingMon:repositionRelativeToPlayer(offset, direction)
    log[#log + 1] = { "repositionRelativeToPlayer", offset, direction }
  end
  function followingMon:setRecallPresentationScale(scale)
    fake.scales[#fake.scales + 1] = scale
    fake.scaleValue = scale
    log[#log + 1] = { "setRecallPresentationScale", scale }
  end
  function followingMon:clearRecallPresentationScale()
    fake.scaleValue = 1
    log[#log + 1] = "clearRecallPresentationScale"
  end
  function followingMon:hideForRecall()
    fake.visible = false
    fake.hides = fake.hides + 1
    log[#log + 1] = "hideForRecall"
  end
  function followingMon:showForRecall()
    fake.visible = true
    fake.shows = fake.shows + 1
    log[#log + 1] = "showForRecall"
  end
  function followingMon:armRecallTransition()
    fake.latchArms = fake.latchArms + 1
    log[#log + 1] = "armRecallTransition"
  end
  local transition = { starts = 0, clears = 0 }
  function transition:start()
    transition.starts = transition.starts + 1
    log[#log + 1] = "transition:start"
    return true
  end
  function transition:clear()
    transition.clears = transition.clears + 1
    log[#log + 1] = "transition:clear"
  end
  local ctx = { services = { followingMon = followingMon, followerTransition = transition } }
  return fake, ctx, log, transition
end

---@param log table
---@param name string
---@return integer
local function countCall(log, name)
  local count = 0
  for _, entry in ipairs(log) do
    if entry == name then
      count = count + 1
    end
  end
  return count
end

---@param log table
---@param name string
---@param arg string
---@return integer
local function countMovement(log, name, arg)
  local count = 0
  for _, entry in ipairs(log) do
    if type(entry) == "table" and entry[1] == name and entry[2] == arg then
      count = count + 1
    end
  end
  return count
end

---@param log table
---@return table<integer, { x: number, y: number, z: number }>
local function appliedOffsets(log)
  local offsets = {}
  for _, entry in ipairs(log) do
    if type(entry) == "table" and entry[1] == "setRecallPresentationOffset" then
      offsets[#offsets + 1] = entry[2]
    end
  end
  return offsets
end

-- Drives one full visible-follower trace for a classified geometry: unpause
-- with state-0 fallthrough, the geometry branch, optional west/north walks
-- with settlement waits, face north, eight cumulative vector updates, and
-- the handoff into the recall shrink window. Returns the harness positioned
-- at the first shrink poll.
---@param mirror boolean
---@param nextState integer
---@param walks table<integer, string>
---@return table fake, table ctx, table log, table transition, table state
local function driveToShrinkWindow(mirror, nextState, walks)
  local fake, ctx, log, transition =
    harness({ active = true, visible = true, settled = false, mirror = mirror, nextState = nextState })
  local state = RecallTask.create({}, ctx)
  Assert.isNil(RecallTask.validate(state), "fresh recall state is serializable")

  local first = RecallTask.poll(state, ctx)
  Assert.isFalse(first.complete, "state 0 unpauses a visible follower and falls through to the unsettled wait")
  Assert.equal(countCall(log, "classifyRecallGeometry"), 0, "state 1 waits before classifying")

  fake.settled.value = true
  local branched = RecallTask.poll(state, ctx)
  Assert.isFalse(branched.complete, "classification keeps blocking")
  Assert.equal(countCall(log, "classifyRecallGeometry"), 1, "geometry classifies exactly once")
  Assert.equal(state.state, nextState, "the classified geometry selects the branch")

  for _, walk in ipairs(walks) do
    local issued = RecallTask.poll(state, ctx)
    Assert.isFalse(issued.complete, "walk issue keeps blocking")
    Assert.equal(countMovement(log, "startRecallMovement", walk), 1, walk .. " issues exactly once")
    fake.settled.value = false
    local inFlight = RecallTask.poll(state, ctx)
    Assert.isFalse(inFlight.complete, "in-flight movement waits")
    fake.settled.value = true
  end
  if nextState == 2 then
    Assert.equal(state.state, 3, "the walk pair hands off to facing without running it early")
  end

  local faced = RecallTask.poll(state, ctx)
  Assert.isFalse(faced.complete, "facing keeps blocking")
  Assert.equal(countMovement(log, "startRecallMovement", "face_north"), 1, "face north applies exactly once")
  Assert.equal(state.state, 4, "facing hands off to the vector sequence")

  for _ = 1, 8 do
    local stepped = RecallTask.poll(state, ctx)
    Assert.isFalse(stepped.complete, "vector updates keep blocking")
  end
  Assert.equal(state.state, 5, "eight vector updates hand off to the recall effect")
  local traced = appliedOffsets(log)
  Assert.deepEqual(traced, expectedOffsets(mirror), "vector offsets accumulate in runtime tiles")
  Assert.deepEqual(traced[1], expectedOffsets(mirror)[1], "the first vector step normalizes native units to tiles")
  local sign = mirror and 1 or -1
  Assert.deepEqual(
    traced[8],
    { x = sign * 1, y = 15 / 16, z = -18 / 16 },
    "the final vector lands on the normalized tile-scale end point"
  )

  local entered = RecallTask.poll(state, ctx)
  Assert.isFalse(entered.complete, "entering the shrink window keeps blocking")
  Assert.equal(transition.starts, 0, "the recall effect never starts the shared transition")
  Assert.equal(state.state, 6, "the effect hands off to the shrink window")
  Assert.equal(state.tailCount, 0, "the shrink window opens with a fresh count")
  return fake, ctx, log, transition, state
end

function T.task_identifies_the_recall_operation()
  Assert.equal(RecallTask.type, "follower_recall", "the opcode-599 task carries recall semantics")
  Assert.equal(RecallTask.version, 1, "the corrected recall type starts its own version")
end

function T.visible_follower_runs_choreography_then_enters_the_shrink_window()
  local _, _, southLog = driveToShrinkWindow(true, 2, { "walk_west", "walk_north" })
  Assert.equal(countMovement(southLog, "startRecallMovement", "walk_west"), 1, "south branch walks west")
  Assert.equal(countMovement(southLog, "startRecallMovement", "walk_north"), 1, "south branch walks north")

  local _, _, eastLog = driveToShrinkWindow(false, 3, {})
  Assert.equal(countMovement(eastLog, "startRecallMovement", "walk_west"), 0, "east branch skips the walks")
  Assert.equal(countMovement(eastLog, "startRecallMovement", "walk_north"), 0, "east branch skips the walks")

  local _, _, westLog = driveToShrinkWindow(true, 3, {})
  Assert.equal(countMovement(westLog, "startRecallMovement", "walk_west"), 0, "west branch skips the walks")
  Assert.deepEqual(appliedOffsets(westLog), expectedOffsets(true), "west branch mirrors the vectors")

  for _, log in ipairs({ southLog, eastLog, westLog }) do
    local unpauses = 0
    for _, entry in ipairs(log) do
      if type(entry) == "table" and entry[1] == "setMovementPaused" and entry[2] == false then
        unpauses = unpauses + 1
      end
    end
    Assert.equal(unpauses, 1, "state 0 unpauses exactly once")
    Assert.equal(countCall(log, "transition:start"), 0, "the choreography starts no shared transition")
  end
end

function T.shrink_window_applies_quartered_scale_then_hides()
  local fake, ctx, _, transition, state = driveToShrinkWindow(true, 2, { "walk_west", "walk_north" })

  local expected = { 1, 1 / 2, 1 / 3, 1 / 4 }
  for index = 1, 4 do
    local stepped = RecallTask.poll(state, ctx)
    Assert.isFalse(stepped.complete, "shrink update " .. index .. " keeps blocking")
    Assert.equal(#fake.scales, index, "shrink update " .. index .. " writes exactly one scale")
    Assert.equal(fake.scales[index], expected[index], "shrink update " .. index .. " quarters the billboard")
    if index < 4 then
      Assert.isTrue(fake.visible, "the follower stays visible through shrink update " .. index)
    end
  end
  Assert.isFalse(fake.visible, "the follower hides after the quarter-scale update")
  Assert.equal(fake.hides, 1, "the hide happens exactly once")
  Assert.equal(fake.scaleValue, 1 / 4, "the hide keeps the quarter scale applied")
  Assert.equal(transition.starts, 0, "the shrink window starts no shared transition")
  Assert.equal(state.tailCount, 4, "four updates advance the tail count to four")
end

function T.tail_holds_then_snaps_resets_and_arms_without_revealing()
  local fake, ctx, log, transition, state = driveToShrinkWindow(false, 3, {})

  for _ = 1, 4 do
    Assert.isFalse(RecallTask.poll(state, ctx).complete, "setup reaches the hidden hold")
  end
  Assert.isFalse(fake.visible, "setup hides the follower on the fourth update")

  for count = 5, 19 do
    local held = RecallTask.poll(state, ctx)
    Assert.isFalse(held.complete, "the tail holds at count " .. count)
    Assert.equal(#fake.scales, 4, "the hold writes no further scales")
    Assert.isFalse(fake.visible, "the hold keeps the follower hidden")
  end
  Assert.equal(countMovement(log, "repositionRelativeToPlayer", nil), 0, "no snap before the twentieth count")
  Assert.equal(transition.starts, 0, "the hold starts no shared transition")

  local snapped = RecallTask.poll(state, ctx)
  Assert.isFalse(snapped.complete, "the final snap still completes on its own poll")
  Assert.equal(state.state, 7, "the twentieth count hands off to completion")
  local snaps = {}
  for _, entry in ipairs(log) do
    if type(entry) == "table" and entry[1] == "repositionRelativeToPlayer" then
      snaps[#snaps + 1] = entry
    end
  end
  Assert.equal(#snaps, 1, "the tail ends in exactly one player snap")
  Assert.equal(snaps[1][2], 4, "the snap uses the zero-offset selector")
  Assert.equal(snaps[1][3], 0, "the snap faces north")
  Assert.equal(fake.scaleValue, 1, "the snap restores identity scale")
  Assert.isFalse(fake.visible, "the snap leaves the follower hidden")
  Assert.equal(fake.latchArms, 1, "completion arms exactly one transition for the next real walk")
  Assert.equal(transition.starts, 0, "arming never starts the shared transition eagerly")

  local done = RecallTask.poll(state, ctx)
  Assert.isTrue(done.complete, "state 7 completes on its own poll")
  Assert.equal(transition.starts, 0, "completion never starts the transition")
  Assert.equal(fake.latchArms, 1, "completion never rearms")
end

function T.hidden_or_inactive_follower_completes_without_work()
  local hiddenFake, hiddenCtx, hiddenLog, hiddenTransition = harness({ active = true, visible = false })
  local hiddenState = RecallTask.create({}, hiddenCtx)
  Assert.isNil(RecallTask.validate(hiddenState), "hidden-exit state is serializable")
  Assert.isTrue(RecallTask.poll(hiddenState, hiddenCtx).complete, "an already-hidden follower completes immediately")
  Assert.equal(countMovement(hiddenLog, "startRecallMovement", "walk_west"), 0, "hidden walks nothing")
  Assert.equal(#appliedOffsets(hiddenLog), 0, "hidden writes no vector offset")
  Assert.equal(#hiddenFake.scales, 0, "hidden writes no recall scale")
  Assert.equal(hiddenTransition.starts, 0, "hidden starts no transition")

  local _, inactiveCtx, inactiveLog, inactiveTransition = harness({ active = false, visible = true })
  local inactiveState = RecallTask.create({}, inactiveCtx)
  Assert.isNil(RecallTask.validate(inactiveState), "inactive state is serializable")
  Assert.isTrue(RecallTask.poll(inactiveState, inactiveCtx).complete, "inactive completes immediately")
  Assert.equal(#inactiveLog, 1, "inactive performs no movement, vector, scale, transition, or snap work")
  Assert.equal(inactiveTransition.starts, 0, "inactive starts no transition")
end

function T.cancellation_before_the_hide_clears_transient_state_and_keeps_visibility()
  local fake, ctx, log, transition, state = driveToShrinkWindow(true, 2, { "walk_west", "walk_north" })
  Assert.isFalse(RecallTask.poll(state, ctx).complete, "setup applies the first shrink scale")
  Assert.equal(state.tailCount, 1, "setup holds early in the shrink window")
  Assert.isTrue(fake.visible, "setup is still visible before the hide point")
  Assert.equal(#fake.scales, 1, "setup wrote task-owned scale state")

  RecallTask.cancel(state, "environment", ctx)
  Assert.equal(countCall(log, "settleMovement"), 1, "cancel settles task-owned movement")
  Assert.equal(countCall(log, "clearRecallPresentationOffset"), 1, "cancel clears the task-owned offset")
  Assert.equal(fake.scaleValue, 1, "cancel resets the task-owned scale")
  Assert.isTrue(fake.visible, "cancel before the hide never alters visibility")
  Assert.equal(fake.shows, 0, "cancel before the hide restores nothing")
  Assert.equal(transition.starts, 0, "cancel starts no shared transition")
  Assert.equal(transition.clears, 0, "cancel clears no shared transition")
  Assert.equal(fake.latchArms, 0, "cancel arms no transition")
  Assert.equal(state.cancelled, "environment", "the cancellation reason remains recorded")
  Assert.isNil(RecallTask.validate(state), "cancelled state remains serializable")
  local settledAfterCancel = RecallTask.poll(state, ctx)
  Assert.isTrue(settledAfterCancel.complete, "cancel releases the block without a deferred snap")
  Assert.equal(countMovement(log, "repositionRelativeToPlayer", nil), 0, "cancel runs no deferred snap")
end

function T.cancellation_after_the_hide_restores_visibility_without_arming()
  local fake, ctx, log, transition, state = driveToShrinkWindow(false, 3, {})
  for _ = 1, 6 do
    Assert.isFalse(RecallTask.poll(state, ctx).complete, "setup passes the hide point")
  end
  Assert.isFalse(fake.visible, "setup hid the follower")
  Assert.equal(state.tailCount, 6, "setup holds mid-tail")

  RecallTask.cancel(state, "environment", ctx)
  Assert.equal(countCall(log, "settleMovement"), 1, "late cancel still settles task-owned movement")
  Assert.equal(countCall(log, "clearRecallPresentationOffset"), 1, "late cancel still clears the offset")
  Assert.equal(fake.scaleValue, 1, "late cancel still resets the task-owned scale")
  Assert.isTrue(fake.visible, "late cancel restores the task-owned hide")
  Assert.equal(fake.shows, 1, "late cancel restores visibility exactly once")
  Assert.equal(transition.starts, 0, "late cancel starts no shared transition")
  Assert.equal(transition.clears, 0, "late cancel leaves shared transition work alone")
  Assert.equal(fake.latchArms, 0, "late cancel arms no transition")
  Assert.isTrue(RecallTask.poll(state, ctx).complete, "late cancel completes without snapping")
  Assert.equal(countMovement(log, "repositionRelativeToPlayer", nil), 0, "late cancel runs no deferred snap")
end

function T.state_validates_every_serializable_field()
  local _, ctx, _ = harness({ active = true, visible = true })
  Assert.isNil(RecallTask.validate(RecallTask.create({}, ctx)), "fresh state validates")
  Assert.isNil(
    RecallTask.validate({
      state = 4,
      moveStep = 1,
      vectorIndex = 3,
      mirror = true,
      tailCount = 0,
      offset = { x = 6 / 16, y = 5 / 16, z = -12 / 16 },
    }),
    "mid-trace state validates"
  )
  Assert.isNil(
    RecallTask.validate({
      state = 7,
      moveStep = 1,
      vectorIndex = 8,
      mirror = false,
      tailCount = 20,
      offset = { x = 0, y = 0, z = 0 },
      cancelled = "environment",
    }),
    "cancelled terminal state validates"
  )
  local bad = {
    { started = true },
    { started = false },
    {},
    "not-a-table",
    { state = 8, moveStep = 0, vectorIndex = 0, mirror = false, tailCount = 0, offset = { x = 0, y = 0, z = 0 } },
    { state = 2, moveStep = 2, vectorIndex = 0, mirror = false, tailCount = 0, offset = { x = 0, y = 0, z = 0 } },
    { state = 4, moveStep = 0, vectorIndex = 9, mirror = false, tailCount = 0, offset = { x = 0, y = 0, z = 0 } },
    { state = 4, moveStep = 0, vectorIndex = 0, mirror = "yes", tailCount = 0, offset = { x = 0, y = 0, z = 0 } },
    { state = 6, moveStep = 0, vectorIndex = 0, mirror = false, tailCount = 21, offset = { x = 0, y = 0, z = 0 } },
    { state = 4, moveStep = 0, vectorIndex = 0, mirror = false, tailCount = 0, offset = { x = 0, y = 0 } },
    {
      state = 4,
      moveStep = 0,
      vectorIndex = 0,
      mirror = false,
      tailCount = 0,
      offset = { x = 0, y = 0, z = 0, w = 0 },
    },
    {
      state = 4,
      moveStep = 0,
      vectorIndex = 0,
      mirror = false,
      tailCount = 0,
      offset = { x = 0, y = 0, z = 0 },
      extra = true,
    },
    {
      state = 0,
      moveStep = 0,
      vectorIndex = 0,
      mirror = false,
      tailCount = 0,
      offset = { x = 0, y = 0, z = 0 },
      cancelled = 7,
    },
  }
  for index, state in ipairs(bad) do
    Assert.isTrue(Errors.is(RecallTask.validate(state)), "malformed state " .. index .. " is invalid")
  end
end

function T.cancelling_before_the_choreography_starts_touches_no_follower_work()
  local fake, ctx, log, transition =
    harness({ active = true, visible = true, settled = true, mirror = true, nextState = 2 })
  local state = RecallTask.create({}, ctx)
  RecallTask.cancel(state, "environment", ctx)
  Assert.equal(countCall(log, "settleMovement"), 0, "pre-start cancel settles nothing")
  Assert.equal(countCall(log, "clearRecallPresentationOffset"), 0, "pre-start cancel clears no offset")
  Assert.equal(#fake.scales, 0, "pre-start cancel writes no scale")
  Assert.isTrue(fake.visible, "pre-start cancel alters no visibility")
  Assert.equal(transition.starts, 0, "pre-start cancel starts no transition")
  Assert.equal(fake.latchArms, 0, "pre-start cancel arms nothing")
  Assert.equal(state.cancelled, "environment", "the cancellation reason remains recorded")
  Assert.isNil(RecallTask.validate(state), "pre-start cancelled state remains serializable")
  Assert.isTrue(RecallTask.poll(state, ctx).complete, "pre-start cancel completes immediately")
end

return { tests = T }
