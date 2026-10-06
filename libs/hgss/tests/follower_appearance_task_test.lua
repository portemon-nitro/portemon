-- Follower-appearance task: the blocking opcode-599 choreography owns the
-- native hidden-follower state machine. An active hidden follower walks the
-- source geometry branch, applies eight cumulative presentation-vector
-- updates, starts the generic visual transition once, holds a twenty-count
-- tail, then settles onto the player anchor before completing. Inactive or
-- already-visible followers complete with no work, and cancellation cleans
-- only task-owned movement/presentation state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FollowerAppearanceTask = require("libs.hgss.src.script.tasks.FollowerAppearanceTask")

local T = {}

local VECTOR_Y = { 1, 2, 2, 3, 3, 2, 2, 0 }
local VECTOR_Z = { 4, 4, 4, 2, 2, 2, 0, 0 }

---@param mirror boolean
---@return table<integer, { x: number, y: number, z: number }>
local function cumulativeOffsets(mirror)
  local offsets = {}
  local x, y, z = 0, 0, 0
  for index = 1, 8 do
    x = x + (mirror and 2 or -2)
    y = y + VECTOR_Y[index]
    z = z - VECTOR_Z[index]
    offsets[index] = { x = x, y = y, z = z }
  end
  return offsets
end

local function harness(options)
  local log = {}
  local settled = { value = options.settled }
  if settled.value == nil then
    settled.value = true
  end
  local harnessState = {
    log = log,
    settled = settled,
    active = options.active,
    visible = options.visible,
    mirror = options.mirror,
    nextState = options.nextState,
  }
  local followingMon = {}
  function followingMon:isSourceActive()
    log[#log + 1] = "isSourceActive"
    return harnessState.active
  end
  function followingMon:isPartnerVisible()
    log[#log + 1] = "isPartnerVisible"
    return harnessState.visible
  end
  function followingMon:setMovementPaused(paused)
    log[#log + 1] = { "setMovementPaused", paused }
  end
  function followingMon:isMovementSettled()
    log[#log + 1] = "isMovementSettled"
    return harnessState.settled.value
  end
  function followingMon:settleMovement()
    log[#log + 1] = "settleMovement"
  end
  function followingMon:classifyAppearanceGeometry()
    log[#log + 1] = "classifyAppearanceGeometry"
    return { mirror = harnessState.mirror, nextState = harnessState.nextState }
  end
  function followingMon:startAppearanceMovement(kind)
    log[#log + 1] = { "startAppearanceMovement", kind }
  end
  function followingMon:setAppearancePresentationOffset(offset)
    log[#log + 1] = { "setAppearancePresentationOffset", { x = offset.x, y = offset.y, z = offset.z } }
  end
  function followingMon:clearAppearancePresentationOffset()
    log[#log + 1] = "clearAppearancePresentationOffset"
  end
  function followingMon:repositionRelativeToPlayer(offset, direction)
    log[#log + 1] = { "repositionRelativeToPlayer", offset, direction }
  end
  local transition = {}
  function transition:start()
    log[#log + 1] = "transition:start"
    return true
  end
  function transition:clear()
    log[#log + 1] = "transition:clear"
  end
  local ctx = { services = { followingMon = followingMon, followerTransition = transition } }
  return harnessState, ctx, log
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
    if type(entry) == "table" and entry[1] == "setAppearancePresentationOffset" then
      offsets[#offsets + 1] = entry[2]
    end
  end
  return offsets
end

-- Drives one full native trace for a classified geometry: unpause with
-- state-0 fallthrough, the geometry branch, optional west/north walks with
-- settlement waits, face north, eight cumulative vector updates, one generic
-- transition start, a twenty-count tail, the zero-offset player snap, and
-- completion on its own poll.
---@param mirror boolean
---@param nextState integer
---@param walks table<integer, string>
local function driveNativeTrace(mirror, nextState, walks)
  local harnessState, ctx, log =
    harness({ active = true, visible = false, settled = false, mirror = mirror, nextState = nextState })
  local state = FollowerAppearanceTask.create({}, ctx)
  Assert.isNil(FollowerAppearanceTask.validate(state), "fresh appearance state is serializable")

  local first = FollowerAppearanceTask.poll(state, ctx)
  Assert.isFalse(first.complete, "state 0 unpauses and falls through to the unsettled wait")
  Assert.equal(countCall(log, "classifyAppearanceGeometry"), 0, "state 1 waits before classifying")

  harnessState.settled.value = true
  local branched = FollowerAppearanceTask.poll(state, ctx)
  Assert.isFalse(branched.complete, "classification keeps blocking")
  Assert.equal(countCall(log, "classifyAppearanceGeometry"), 1, "geometry classifies exactly once")
  Assert.equal(state.state, nextState, "the classified geometry selects the branch")

  for _, walk in ipairs(walks) do
    local issued = FollowerAppearanceTask.poll(state, ctx)
    Assert.isFalse(issued.complete, "walk issue keeps blocking")
    Assert.equal(countMovement(log, "startAppearanceMovement", walk), 1, walk .. " issues exactly once")
    harnessState.settled.value = false
    local inFlight = FollowerAppearanceTask.poll(state, ctx)
    Assert.isFalse(inFlight.complete, "in-flight movement waits")
    harnessState.settled.value = true
  end
  Assert.equal(countMovement(log, "startAppearanceMovement", "walk_west"), #walks > 0 and 1 or 0, "west walk count")
  if nextState == 2 then
    Assert.equal(state.state, 3, "the walk pair hands off to facing without running it early")
  end

  local faced = FollowerAppearanceTask.poll(state, ctx)
  Assert.isFalse(faced.complete, "facing keeps blocking")
  Assert.equal(countMovement(log, "startAppearanceMovement", "face_north"), 1, "face north applies exactly once")
  Assert.equal(state.state, 4, "facing hands off to the vector sequence")

  for _ = 1, 8 do
    local stepped = FollowerAppearanceTask.poll(state, ctx)
    Assert.isFalse(stepped.complete, "vector updates keep blocking")
  end
  Assert.equal(state.state, 5, "eight vector updates hand off to the visual effect")
  Assert.deepEqual(appliedOffsets(log), cumulativeOffsets(mirror), "vector offsets accumulate absolutely")

  local effected = FollowerAppearanceTask.poll(state, ctx)
  Assert.isFalse(effected.complete, "the visual effect keeps blocking without waiting on its clip")
  Assert.equal(countCall(log, "transition:start"), 1, "the generic transition starts exactly once")
  Assert.equal(state.state, 6, "the effect hands off to the tail")

  for _ = 1, 19 do
    local held = FollowerAppearanceTask.poll(state, ctx)
    Assert.isFalse(held.complete, "the tail holds before its twentieth count")
  end
  Assert.equal(countMovement(log, "repositionRelativeToPlayer", nil), 0, "no snap before the twentieth count")
  local snapped = FollowerAppearanceTask.poll(state, ctx)
  Assert.isFalse(snapped.complete, "the final snap still completes on its own poll")
  Assert.equal(state.state, 7, "the twentieth count hands off to completion")
  Assert.equal(countCall(log, "clearAppearancePresentationOffset"), 1, "the snap clears the vector offset")
  local snap = log[#log]
  Assert.equal(snap[1], "repositionRelativeToPlayer", "the tail ends in the player snap")
  Assert.equal(snap[2], 4, "the snap uses the zero-offset selector")
  Assert.equal(snap[3], 0, "the snap faces north")

  local done = FollowerAppearanceTask.poll(state, ctx)
  Assert.isTrue(done.complete, "state 7 completes on its own poll")
  Assert.equal(countCall(log, "transition:start"), 1, "completion never restarts the transition")
  return log
end

function T.hidden_follower_reproduces_the_native_appearance_trace()
  local southLog = driveNativeTrace(true, 2, { "walk_west", "walk_north" })
  Assert.equal(countMovement(southLog, "startAppearanceMovement", "walk_west"), 1, "south branch walks west")
  Assert.equal(countMovement(southLog, "startAppearanceMovement", "walk_north"), 1, "south branch walks north")

  local eastLog = driveNativeTrace(false, 3, {})
  Assert.equal(countMovement(eastLog, "startAppearanceMovement", "walk_west"), 0, "east branch skips the walks")
  Assert.equal(countMovement(eastLog, "startAppearanceMovement", "walk_north"), 0, "east branch skips the walks")

  local westLog = driveNativeTrace(true, 3, {})
  Assert.equal(countMovement(westLog, "startAppearanceMovement", "walk_west"), 0, "west branch skips the walks")
  Assert.deepEqual(appliedOffsets(westLog), cumulativeOffsets(true), "west branch mirrors the vectors")

  for _, log in ipairs({ southLog, eastLog, westLog }) do
    local unpauses = 0
    for _, entry in ipairs(log) do
      if type(entry) == "table" and entry[1] == "setMovementPaused" and entry[2] == false then
        unpauses = unpauses + 1
      end
    end
    Assert.equal(unpauses, 1, "state 0 unpauses exactly once")
  end
end

function T.inactive_or_visible_follower_completes_without_work()
  local _, inactiveCtx, inactiveLog = harness({ active = false, visible = false })
  local inactiveState = FollowerAppearanceTask.create({}, inactiveCtx)
  Assert.isNil(FollowerAppearanceTask.validate(inactiveState), "inactive state is serializable")
  Assert.isTrue(FollowerAppearanceTask.poll(inactiveState, inactiveCtx).complete, "inactive completes immediately")
  Assert.equal(#inactiveLog, 1, "inactive performs no movement, vector, transition, or snap work")

  local _, visibleCtx, visibleLog = harness({ active = true, visible = true })
  local visibleState = FollowerAppearanceTask.create({}, visibleCtx)
  Assert.isNil(FollowerAppearanceTask.validate(visibleState), "visible-exit state is serializable")
  Assert.isTrue(FollowerAppearanceTask.poll(visibleState, visibleCtx).complete, "visible completes immediately")
  Assert.equal(countCall(visibleLog, "transition:start"), 0, "visible starts no transition")
  Assert.equal(countMovement(visibleLog, "startAppearanceMovement", "walk_west"), 0, "visible walks nothing")
  Assert.equal(#appliedOffsets(visibleLog), 0, "visible writes no vector offset")
end

function T.cancellation_cleans_task_owned_movement_and_offset_only()
  local _, vectorCtx, vectorLog =
    harness({ active = true, visible = false, settled = true, mirror = true, nextState = 2 })
  local vectorState = FollowerAppearanceTask.create({}, vectorCtx)
  for _ = 1, 10 do
    Assert.isFalse(FollowerAppearanceTask.poll(vectorState, vectorCtx).complete, "setup reaches the vector phase")
  end
  Assert.equal(vectorState.state, 4, "setup holds in the vector sequence")
  Assert.isTrue(#appliedOffsets(vectorLog) > 0, "setup wrote task-owned vector state")

  FollowerAppearanceTask.cancel(vectorState, "environment", vectorCtx)
  Assert.equal(countCall(vectorLog, "settleMovement"), 1, "cancel settles task-owned movement")
  Assert.equal(countCall(vectorLog, "clearAppearancePresentationOffset"), 1, "cancel clears the task-owned offset")
  Assert.equal(countCall(vectorLog, "transition:start"), 0, "cancel before the effect starts nothing generic")
  Assert.equal(countCall(vectorLog, "transition:clear"), 0, "cancel never clears generic transition work")
  Assert.equal(vectorState.cancelled, "environment", "the cancellation reason remains recorded")
  Assert.isNil(FollowerAppearanceTask.validate(vectorState), "cancelled state remains serializable")
  local settledAfterCancel = FollowerAppearanceTask.poll(vectorState, vectorCtx)
  Assert.isTrue(settledAfterCancel.complete, "cancel releases the block without a deferred snap")
  Assert.equal(countMovement(vectorLog, "repositionRelativeToPlayer", nil), 0, "cancel runs no deferred snap")

  local _, tailCtx, tailLog = harness({ active = true, visible = false, settled = true, mirror = false, nextState = 3 })
  local tailState = FollowerAppearanceTask.create({}, tailCtx)
  local guard = 0
  while tailState.state ~= 6 and guard < 40 do
    Assert.isFalse(FollowerAppearanceTask.poll(tailState, tailCtx).complete, "setup reaches the tail")
    guard = guard + 1
  end
  Assert.equal(tailState.state, 6, "setup holds in the tail after the generic start")
  Assert.equal(countCall(tailLog, "transition:start"), 1, "setup started the generic effect once")

  FollowerAppearanceTask.cancel(tailState, "environment", tailCtx)
  Assert.equal(countCall(tailLog, "settleMovement"), 1, "late cancel still settles task-owned movement")
  Assert.equal(countCall(tailLog, "clearAppearancePresentationOffset"), 1, "late cancel still clears the offset")
  Assert.equal(countCall(tailLog, "transition:clear"), 0, "late cancel leaves generic transition work alone")
  Assert.isTrue(FollowerAppearanceTask.poll(tailState, tailCtx).complete, "late cancel completes without snapping")
  Assert.equal(countMovement(tailLog, "repositionRelativeToPlayer", nil), 0, "late cancel runs no deferred snap")
end

function T.state_validates_every_serializable_field_and_rejects_the_previous_shape()
  local _, ctx, _ = harness({ active = true, visible = false })
  Assert.isNil(FollowerAppearanceTask.validate(FollowerAppearanceTask.create({}, ctx)), "fresh state validates")
  Assert.isNil(
    FollowerAppearanceTask.validate({
      state = 4,
      moveStep = 1,
      vectorIndex = 3,
      mirror = true,
      tailCount = 0,
      offset = { x = 6, y = 6, z = -12 },
    }),
    "mid-trace state validates"
  )
  Assert.isNil(
    FollowerAppearanceTask.validate({
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
    Assert.isTrue(Errors.is(FollowerAppearanceTask.validate(state)), "malformed state " .. index .. " is invalid")
  end
end

function T.cancelling_before_the_choreography_starts_touches_no_follower_work()
  local _, ctx, log = harness({ active = true, visible = false, settled = true, mirror = true, nextState = 2 })
  local state = FollowerAppearanceTask.create({}, ctx)
  FollowerAppearanceTask.cancel(state, "environment", ctx)
  Assert.equal(countCall(log, "settleMovement"), 0, "pre-start cancel settles nothing")
  Assert.equal(countCall(log, "clearAppearancePresentationOffset"), 0, "pre-start cancel clears no offset")
  Assert.equal(state.cancelled, "environment", "the cancellation reason remains recorded")
  Assert.isNil(FollowerAppearanceTask.validate(state), "pre-start cancelled state remains serializable")
  Assert.isTrue(FollowerAppearanceTask.poll(state, ctx).complete, "pre-start cancel completes immediately")
end

return { tests = T }
