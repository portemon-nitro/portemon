-- Selected-session drive behavior without worker threads or a ROM: fake
-- channels, session, pool, and timer prove the controller waits on its
-- control channel when settled, polls on the live cadence while worker
-- results are outstanding, and pumps immediately runnable planning.

local Assert = require("tests.support.Assert")
local CacheControllerWorker = require("romdump.src.build.CacheControllerWorker")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local LIVE_CADENCE_SECONDS = 0.005

local function recordingTimer()
  local timer = { sleeps = {} }
  function timer.sleep(first, second)
    local seconds = second == nil and first or second
    timer.sleeps[#timer.sleeps + 1] = seconds
  end
  return timer
end

---@param options { runnable: boolean, poolState: string, wakeDelay: number?, queued: table[]?, demandCommand: table? }
---@return table worker fake-channel controller under test
---@return table session fake selected session
---@return table pool fake compiler pool
---@return table timer recording sleep timer
---@return table log channel/session call log
local function driveSetup(options)
  local log = {
    pops = 0,
    demands = 0,
    replies = {},
    pumpsBeforeDemand = nil,
    queued = options.queued or {},
    demandCommand = options.demandCommand,
  }
  local session = { pumps = 0, runnable = options.runnable, wakeDelay = options.wakeDelay }
  function session.hasRunnablePlanning()
    return session.runnable
  end
  function session.nextPlanningWakeDelay()
    return session.wakeDelay
  end
  function session.update()
    session.pumps = session.pumps + 1
  end
  local pool = { state = options.poolState, updates = 0 }
  function pool.activityState()
    return pool.state
  end
  function pool.update()
    pool.updates = pool.updates + 1
  end
  local control = {}
  function control.pop()
    log.pops = log.pops + 1
    if #log.queued > 0 then
      return table.remove(log.queued, 1)
    end
    return nil
  end
  function control.demand()
    log.demands = log.demands + 1
    log.pumpsBeforeDemand = session.pumps
    return assert(log.demandCommand, "the blocking wait must answer a command")
  end
  local reply = {}
  function reply:push(message)
    log.replies[#log.replies + 1] = message
  end
  local worker = CacheControllerWorker.Worker.new(control, reply)
  worker.session = session
  worker.pool = pool
  return worker, session, pool, recordingTimer(), log
end

-- A settled selected session performs no timed polling and no session
-- update while waiting: one drive blocks on the control channel, handles
-- the command, and only then pumps once.
function T.settled_selected_session_blocks_for_the_next_command()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(log.demands, 1, "the settled controller blocks on its control channel")
  Assert.equal(#timer.sleeps, 0, "the settled controller performs no timed sleep")
  Assert.equal(log.pumpsBeforeDemand, 0, "no session pump precedes the blocking wait")
  Assert.equal(session.pumps, 1, "the post-command step pumps the session exactly once")
end

-- A worker-dependent wait keeps the bounded live cadence: exactly one
-- short sleep followed by exactly one pump, with no control block.
function T.worker_dependent_wait_polls_once_with_the_live_cadence()
  local worker, session, _, timer, log = driveSetup({ runnable = false, poolState = "waiting" })
  worker:driveOnce(timer)
  Assert.equal(#timer.sleeps, 1, "a worker wait sleeps exactly once before polling")
  Assert.equal(timer.sleeps[1], LIVE_CADENCE_SECONDS, "the wait keeps the live poll cadence")
  Assert.equal(session.pumps, 1, "the wait polls the session exactly once")
  Assert.equal(log.demands, 0, "a worker wait never blocks on the control channel")
end

-- Immediately runnable local planning pumps without sleeping or
-- blocking, even though no command is available.
function T.runnable_local_planning_pumps_without_sleeping()
  local worker, session, _, timer, log = driveSetup({ runnable = true, poolState = "idle" })
  worker:driveOnce(timer)
  Assert.equal(session.pumps, 1, "runnable planning steps immediately")
  Assert.equal(#timer.sleeps, 0, "runnable planning waits for no sleep")
  Assert.equal(log.demands, 0, "runnable planning waits for no command")
end

-- An already-queued command outranks any wait decision: it is handled
-- first and the session pumps immediately with no sleep or demand.
function T.queued_command_handles_before_any_wait_decision()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "waiting",
    queued = { { op = "unknown-drive-probe" } },
  })
  worker:driveOnce(timer)
  Assert.isTrue(log.pops >= 1, "the drive consults queued commands first")
  Assert.equal(session.pumps, 1, "the command path pumps the session immediately")
  Assert.equal(#timer.sleeps, 0, "a queued command waits for no sleep")
  Assert.equal(log.demands, 0, "a queued command waits for no demand")
end

-- A session clock wait sleeps on the live cadence instead of spinning:
-- exactly one bounded sleep and one pump, with no control-channel block.
function T.timed_planning_wait_sleeps_once_then_pumps()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    wakeDelay = 0.5,
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(#timer.sleeps, 1, "a timed wait sleeps exactly once before pumping")
  Assert.isTrue(timer.sleeps[1] <= LIVE_CADENCE_SECONDS, "a timed wait never exceeds the live cadence")
  Assert.equal(session.pumps, 1, "a timed wait pumps the session exactly once")
  Assert.equal(log.demands, 0, "a timed wait never blocks on the control channel")
end

-- An expired clock wait pumps immediately: no sleep is owed when the
-- deadline is already due.
function T.expired_timed_wait_pumps_without_sleeping()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    wakeDelay = 0,
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(session.pumps, 1, "an expired wait pumps the session exactly once")
  Assert.equal(#timer.sleeps, 0, "an expired wait sleeps for no cadence")
  Assert.equal(log.demands, 0, "an expired wait never blocks on the control channel")
end

-- Pool worker waiting outranks a session clock wait: the drive keeps the
-- live poll cadence instead of the shorter clock remainder.
function T.pool_waiting_outranks_a_shorter_session_clock_wait()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "waiting",
    wakeDelay = 0.002,
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(#timer.sleeps, 1, "the pool wait sleeps exactly once before polling")
  Assert.equal(timer.sleeps[1], LIVE_CADENCE_SECONDS, "the pool wait keeps the live poll cadence")
  Assert.equal(session.pumps, 1, "the wait polls the session exactly once")
  Assert.equal(log.demands, 0, "the wait never blocks on the control channel")
end

-- An already-queued command outranks a session clock wait: no sleep is
-- owed when a command is ready.
function T.queued_command_outranks_a_session_clock_wait()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    wakeDelay = 0.5,
    queued = { { op = "unknown-drive-probe" } },
  })
  worker:driveOnce(timer)
  Assert.isTrue(log.pops >= 1, "the drive consults queued commands first")
  Assert.equal(session.pumps, 1, "the command path pumps the session immediately")
  Assert.equal(#timer.sleeps, 0, "a queued command waits for no sleep")
  Assert.equal(log.demands, 0, "a queued command waits for no demand")
end

-- Terminal request/barrier/failure facts are pushed over the existing reply
-- channel: fake control/reply channels plus a fake selected session prove the
-- controller emits each terminal event without any status probe round-trip.
local function pushChannels()
  local queued = {}
  local control = {}
  function control.pop()
    if #queued == 0 then
      return nil
    end
    return table.remove(queued, 1)
  end
  function control.demand()
    return table.remove(queued, 1)
  end
  local replies = {}
  local reply = {}
  function reply:push(message)
    replies[#replies + 1] = message
  end
  return control, reply, replies, queued
end

local function terminalSession(outcomes)
  local session = { pumps = 0, milestoneCalls = 0, ready = true }
  if outcomes ~= nil and outcomes.ready ~= nil then
    session.ready = outcomes.ready
  end
  function session.update()
    session.pumps = session.pumps + 1
  end
  function session.requestMilestone(_, _)
    session.milestoneCalls = session.milestoneCalls + 1
    if session.ready then
      return true, nil
    end
    return false, nil
  end
  function session.milestoneStatus(_)
    error("terminal observation must not query progress", 0)
  end
  function session.requestField(_, _)
    return true, nil
  end
  function session.requestLogicalField(_, _)
    return true, nil
  end
  function session.requestCell(_, _)
    return true, nil
  end
  function session.requestMonPortraitPage(_, _)
    return true, nil
  end
  function session.requestIconPage(_, _)
    return true, nil
  end
  function session.hasRunnablePlanning()
    return false
  end
  function session.nextPlanningWakeDelay()
    return nil
  end
  return session
end

local function pushWorker(session, epoch)
  local control, reply, replies, queued = pushChannels()
  local worker = CacheControllerWorker.Worker.new(control, reply)
  worker.session = session
  worker.pool = nil
  worker.liveEpoch = epoch
  worker.lifecycle = "active"
  return worker, replies, queued
end

-- Drain one FIFO channel without absorbing it through an owner: a test asserts
-- exactly what the controller pushed.
---@param channel table<string, function>
---@return table<string, unknown>[]
local function drainChannel(channel)
  local packets = {}
  while true do
    local packet = channel:pop()
    if packet == nil then
      return packets
    end
    packets[#packets + 1] = packet
  end
end

local function packetsOf(replies, op)
  local found = {}
  for _, packet in ipairs(replies) do
    if type(packet) == "table" and packet.op == op then
      found[#found + 1] = packet
    end
  end
  return found
end

-- An immediately settled external request emits one terminal event during
-- request handling: no status probe is required for progress.
function T.request_outcome_is_pushed_without_a_status_probe()
  local worker, replies, queued = pushWorker(terminalSession(), 7)
  queued[#queued + 1] =
    { op = "request", epoch = 7, requestId = 11, requestKind = "milestone", name = "bootstrap", urgency = "required" }
  worker:step()
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 1, "an immediately ready request emits one terminal event without a status probe")
  Assert.equal(results[1].requestId, 11, "the terminal event carries the request identity")
  Assert.equal(results[1].state, "ready", "the terminal event carries the ready state")
  Assert.equal(results[1].epoch, 7, "the terminal event carries the epoch identity")
end

-- A request that settles after session progress emits exactly one terminal
-- event on the settling pump and never duplicates it on later pumps.
function T.delayed_readiness_emits_exactly_one_terminal_event()
  local session = terminalSession({ ready = false })
  local worker, replies, queued = pushWorker(session, 7)
  queued[#queued + 1] =
    { op = "request", epoch = 7, requestId = 12, requestKind = "milestone", name = "bootstrap", urgency = "required" }
  worker:step()
  Assert.equal(#packetsOf(replies, "request-result"), 0, "a pending request emits no terminal event yet")
  session.ready = true
  worker:step()
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 1, "settling progress emits one terminal event")
  Assert.equal(results[1].requestId, 12, "the terminal event carries the request identity")
  Assert.equal(results[1].state, "ready", "the terminal event carries the ready state")
  worker:step()
  Assert.equal(#packetsOf(replies, "request-result"), 1, "later pumps never duplicate the terminal event")
end

-- A fake selected session that counts every semantic cell observation and
-- keys readiness by cell selector, so tests can register many unique
-- pending requests and flip one late entry to ready on demand. Per-member
-- counts prove a single flush never observes the same record twice.
---@param readyMemberId integer? matrix member whose cells read ready; nil keeps everything pending
---@return table fake selected session counting semantic cell observations
local function countingSession(readyMemberId)
  local session = { pumps = 0, observations = 0, readyMemberId = readyMemberId, observationsByMember = {} }
  function session.update()
    session.pumps = session.pumps + 1
  end
  function session:requestCell(selector, _)
    session.observations = session.observations + 1
    if type(selector) == "table" then
      local memberId = selector.matrixMemberId
      session.observationsByMember[memberId] = (session.observationsByMember[memberId] or 0) + 1
    end
    if
      session.readyMemberId ~= nil
      and type(selector) == "table"
      and selector.matrixMemberId == session.readyMemberId
    then
      return true, nil
    end
    return false, nil
  end
  function session.hasRunnablePlanning()
    return false
  end
  function session.nextPlanningWakeDelay()
    return nil
  end
  return session
end

---@param queued table command queue receiving one unique cell request per entry
---@param epoch integer live controller epoch
---@param firstRequestId integer request identity for matrix member zero
---@param total integer number of unique requests to register
local function queueUniqueCellRequests(queued, epoch, firstRequestId, total)
  for offset = 0, total - 1 do
    queued[#queued + 1] = {
      op = "request",
      epoch = epoch,
      requestId = firstRequestId + offset,
      requestKind = "cell",
      matrixMemberId = offset,
      index = 0,
      urgency = "near",
    }
  end
end

-- One terminal flush re-observes at most sixteen pending records no matter
-- how many unique requests are retained: forty distinct pending cells are
-- registered first, then a single pump with no new commands is measured.
function T.one_flush_reobserves_at_most_sixteen_pending_requests()
  local total = 40
  local session = countingSession(nil)
  local worker, replies, queued = pushWorker(session, 21)
  queueUniqueCellRequests(queued, 21, 101, total)
  while #queued > 0 do
    worker:step()
  end
  Assert.equal(#packetsOf(replies, "request-result"), 0, "pending requests emit no terminal event during registration")
  local retained = 0
  for _ in pairs(worker.requests) do
    retained = retained + 1
  end
  Assert.equal(retained, total, "every unique pending request is retained after registration")
  session.observations = 0
  worker:step()
  Assert.isTrue(
    session.observations <= 16,
    "one flush re-observes at most sixteen pending requests, observed " .. tostring(session.observations)
  )
  Assert.equal(#packetsOf(replies, "request-result"), 0, "an all-pending flush emits no terminal event")
end

-- Bounding never strands requests past the first observation window: with
-- forty unique pending cells and a late entry outside the first post-drain
-- window ready, successive pumps each stay within sixteen observations
-- until the late entry settles once. Draining forty requests in 16/16/8
-- command steps leaves the retained cursor at slot 33, so the first flush
-- covers slots 33..40 and 1..8; member 31 (slot 32) needs a third flush.
function T.repeated_flushes_eventually_reach_a_late_pending_request()
  local total = 40
  local lateMemberId = total - 9
  local session = countingSession(nil)
  local worker, replies, queued = pushWorker(session, 23)
  queueUniqueCellRequests(queued, 23, 201, total)
  while #queued > 0 do
    worker:step()
  end
  Assert.equal(#packetsOf(replies, "request-result"), 0, "pending requests emit no terminal event during registration")
  session.readyMemberId = lateMemberId
  session.observations = 0
  local steps = 0
  while #packetsOf(replies, "request-result") == 0 do
    Assert.isTrue(steps < 10, "the late ready request settles after finitely many bounded flushes")
    local before = session.observations
    worker:step()
    steps = steps + 1
    local delta = session.observations - before
    Assert.isTrue(delta <= 16, "every flush stays within sixteen observations, observed " .. tostring(delta))
  end
  Assert.isTrue(steps >= 2, "the late request waits for a later flush window")
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 1, "the late ready request emits one terminal event")
  Assert.equal(results[1].requestId, 201 + lateMemberId, "the terminal event carries the late request identity")
  Assert.equal(results[1].state, "ready", "the terminal event carries the ready state")
  Assert.equal(results[1].epoch, 23, "the terminal event carries the epoch identity")
  worker:step()
  worker:step()
  Assert.equal(#packetsOf(replies, "request-result"), 1, "the late terminal event is never duplicated")
end

-- A flush that wraps past the end of the pending sequence never
-- re-observes a record swapped under the cursor: with twenty pending
-- cells the retained cursor starts mid-sequence, so settling the earliest
-- entry removes it while its tail replacement was already observed in the
-- same flush and must be skipped.
function T.one_flush_never_reobserves_the_same_pending_request()
  local total = 20
  local session = countingSession(nil)
  local worker, replies, queued = pushWorker(session, 25)
  queueUniqueCellRequests(queued, 25, 301, total)
  while #queued > 0 do
    worker:step()
  end
  Assert.equal(#packetsOf(replies, "request-result"), 0, "pending requests emit no terminal event during registration")
  session.readyMemberId = 0
  session.observations = 0
  session.observationsByMember = {}
  worker:step()
  Assert.isTrue(
    session.observations <= 16,
    "the wrapping flush stays within sixteen observations, observed " .. tostring(session.observations)
  )
  for memberId, count in pairs(session.observationsByMember) do
    Assert.equal(count, 1, "matrix member " .. tostring(memberId) .. " is observed once per flush")
  end
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 1, "the settled early request emits one terminal event")
  Assert.equal(results[1].requestId, 301, "the terminal event carries the early request identity")
  Assert.equal(results[1].state, "ready", "the terminal event carries the ready state")
  Assert.equal(results[1].epoch, 25, "the terminal event carries the epoch identity")
  worker:step()
  worker:step()
  Assert.equal(#packetsOf(replies, "request-result"), 1, "the early terminal event is never duplicated")
end

-- Retirement and quiescence each push their own exact barrier event at the
-- existing completion point instead of waiting for a status round-trip.
function T.retirement_and_quiescence_push_exact_barrier_events()
  local worker, replies, queued = pushWorker(terminalSession(), 9)
  queued[#queued + 1] = { op = "retire", epoch = 9, barrierId = 4 }
  worker:step()
  local retired = packetsOf(replies, "barrier-result")
  Assert.equal(#retired, 1, "retirement pushes one barrier event")
  Assert.equal(retired[1].epoch, 9, "the retirement event carries the epoch identity")
  Assert.equal(retired[1].barrierId, 4, "the retirement event carries the barrier identity")
  Assert.equal(retired[1].kind, "retire", "the retirement event carries its kind")
  queued[#queued + 1] = { op = "quiesce", epoch = 9, barrierId = 5 }
  worker:step()
  local settled = packetsOf(replies, "barrier-result")
  Assert.equal(#settled, 2, "quiescence pushes its own barrier event")
  Assert.equal(settled[2].epoch, 9, "the quiescence event carries the epoch identity")
  Assert.equal(settled[2].barrierId, 5, "the quiescence event carries the barrier identity")
  Assert.equal(settled[2].kind, "quiesce", "the quiescence event carries its kind")
end

-- A lifecycle failure pushes one terminal fact with the first cause; later
-- failures never spam the channel or replace the primary cause.
function T.lifecycle_failure_pushes_one_terminal_event()
  local worker, replies, queued = pushWorker(terminalSession(), 11)
  queued[#queued + 1] = { op = "select", epoch = 11 }
  worker:step()
  local failures = packetsOf(replies, "controller-failure")
  Assert.equal(#failures, 1, "the first lifecycle failure pushes one terminal event")
  Assert.isTrue(tostring(failures[1].errorMessage) ~= "", "the terminal failure carries its cause")
  queued[#queued + 1] = { op = "select", epoch = 12 }
  worker:step()
  Assert.equal(#packetsOf(replies, "controller-failure"), 1, "later failures never spam the channel")
end

-- A fully idle session with no clock wait still blocks for the next
-- command instead of polling.
function T.idle_session_without_a_timed_wait_blocks_for_the_next_command()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    wakeDelay = nil,
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(log.demands, 1, "an idle controller blocks on its control channel")
  Assert.equal(#timer.sleeps, 0, "an idle controller performs no timed sleep")
  Assert.equal(session.pumps, 1, "the post-command step pumps the session exactly once")
end

-- One semantic scene demand dispatches the registered scene job with its
-- exact key: a pending job emits nothing yet, readiness completes through
-- the existing terminal event, and a malformed key fails its own request
-- without killing the controller.
function T.scene_selector_dispatches_the_registered_scene_job()
  local calls = {}
  local answer = { ready = false, failure = nil }
  local session = { pumps = 0 }
  function session.update()
    session.pumps = session.pumps + 1
  end
  function session.requestJob(_, kind, key, urgency)
    calls[#calls + 1] = { kind = kind, key = key, urgency = urgency }
    return answer.ready, answer.failure
  end
  function session.hasRunnablePlanning()
    return false
  end
  function session.nextPlanningWakeDelay()
    return nil
  end
  local worker, replies, queued = pushWorker(session, 7)
  queued[#queued + 1] = {
    op = "request",
    epoch = 7,
    requestId = 31,
    requestKind = "battle-scene",
    sceneKey = "general/grass/day",
    urgency = "required",
  }
  worker:step()
  Assert.isTrue(#calls >= 1, "the scene demand dispatches its registered job")
  Assert.equal(calls[1].kind, "battle-scene", "the dispatched job keeps its kind")
  Assert.equal(calls[1].key, "general/grass/day", "the dispatched job keeps its exact scene key")
  Assert.equal(calls[1].urgency, "required", "the dispatched job keeps its urgency")
  Assert.equal(#packetsOf(replies, "request-result"), 0, "a pending scene job emits no terminal event yet")
  answer.ready = true
  worker:step()
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 1, "scene readiness completes through one terminal event")
  Assert.equal(results[1].requestId, 31, "the terminal event carries the request identity")
  Assert.equal(results[1].state, "ready", "the terminal event carries the ready state")
  Assert.equal(results[1].epoch, 7, "the terminal event carries the epoch identity")
  local badKeys = { "bogus", "general/grass/nonsense", "" }
  for offset, badKey in ipairs(badKeys) do
    queued[#queued + 1] = {
      op = "request",
      epoch = 7,
      requestId = 40 + offset,
      requestKind = "battle-scene",
      sceneKey = badKey,
      urgency = "required",
    }
  end
  worker:step()
  local settled = packetsOf(replies, "request-result")
  Assert.equal(#settled, 4, "each malformed scene key fails its own request")
  for index = 2, 4 do
    Assert.equal(settled[index].state, "failed", "a malformed key reports failure")
    Assert.isTrue(tostring(settled[index].errorMessage) ~= "", "a malformed key carries its cause")
  end
  Assert.isTrue(worker.lifecycle ~= "failed", "a malformed selector never kills the controller")
end

-- One trainer picture, one ball, and the selector-free evolution demand
-- each dispatch the safe keyed worker job for the requested selector: a
-- well-formed but unsourced selector still dispatches for the producer to
-- validate, while malformed selectors fail their own requests without
-- killing the controller.
function T.battle_leaf_selectors_dispatch_safe_keyed_jobs()
  local calls = {}
  local answer = { ready = false, failure = nil }
  local session = { pumps = 0 }
  function session.update()
    session.pumps = session.pumps + 1
  end
  function session.requestJob(_, kind, key, urgency)
    calls[#calls + 1] = { kind = kind, key = key, urgency = urgency }
    return answer.ready, answer.failure
  end
  function session.hasRunnablePlanning()
    return false
  end
  function session.nextPlanningWakeDelay()
    return nil
  end
  local worker, replies, queued = pushWorker(session, 7)
  queued[#queued + 1] = {
    op = "request",
    epoch = 7,
    requestId = 61,
    requestKind = "battle-trainer-picture",
    trainerSelector = "front:YOUNGSTER",
    urgency = "required",
  }
  queued[#queued + 1] = {
    op = "request",
    epoch = 7,
    requestId = 62,
    requestKind = "battle-trainer-picture",
    trainerSelector = "front:NOT_A_CLASS",
    urgency = "near",
  }
  queued[#queued + 1] = {
    op = "request",
    epoch = 7,
    requestId = 63,
    requestKind = "battle-ball",
    ballSelector = "ball:POKE_BALL",
    urgency = "required",
  }
  queued[#queued + 1] =
    { op = "request", epoch = 7, requestId = 64, requestKind = "battle-evolution", urgency = "required" }
  worker:step()
  -- The controller re-observes still-pending requests in the same step
  -- through its documented flush, so the session sees each dispatch at
  -- least once; the first four calls are the drain-phase dispatches in
  -- queue order, matching the scene-test precedent.
  Assert.isTrue(#calls >= 4, "each leaf demand dispatches its registered job")
  Assert.equal(calls[1].kind, "battle-trainer-picture", "the trainer demand keeps its kind")
  Assert.equal(calls[1].key, "front-YOUNGSTER", "the trainer demand carries its safe class key")
  Assert.equal(calls[1].urgency, "required", "the trainer demand keeps its urgency")
  Assert.equal(calls[2].key, "front-NOT_A_CLASS", "an unsourced selector keeps its exact safe spelling")
  Assert.equal(calls[3].kind, "battle-ball", "the ball demand keeps its kind")
  Assert.equal(calls[3].key, "POKE_BALL", "the ball demand carries its safe item key")
  Assert.equal(calls[4].kind, "battle-evolution", "the evolution demand keeps its kind")
  Assert.equal(calls[4].key, "global", "evolution stays one global-keyed job")
  Assert.equal(#packetsOf(replies, "request-result"), 0, "pending leaf jobs emit no terminal event yet")
  answer.ready = true
  worker:step()
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 4, "leaf readiness completes through one terminal event each")
  for _, result in ipairs(results) do
    Assert.equal(result.state, "ready", "the terminal event carries the ready state")
    Assert.equal(result.epoch, 7, "the terminal event carries the epoch identity")
  end
  local badPackets = {
    { requestKind = "battle-trainer-picture", urgency = "required" },
    { requestKind = "battle-trainer-picture", trainerSelector = "", urgency = "required" },
    { requestKind = "battle-trainer-picture", trainerSelector = "front:YOUNGSTER/x", urgency = "required" },
    { requestKind = "battle-trainer-picture", trainerSelector = 7, urgency = "required" },
    {
      requestKind = "battle-trainer-picture",
      trainerSelector = "front:YOUNGSTER",
      urgency = "required",
      sceneKey = "general/grass/day",
    },
    { requestKind = "battle-ball", urgency = "required" },
    { requestKind = "battle-ball", ballSelector = "POKE_BALL", urgency = "required" },
    { requestKind = "battle-ball", ballSelector = "ball:a/b", urgency = "required" },
    {
      requestKind = "battle-evolution",
      urgency = "required",
      trainerSelector = "front:YOUNGSTER",
    },
    { requestKind = "battle-trainer-picture", trainerSelector = "front:YOUNGSTER", urgency = "eventual" },
  }
  for offset, packet in ipairs(badPackets) do
    packet.op = "request"
    packet.epoch = 7
    packet.requestId = 70 + offset
    queued[#queued + 1] = packet
  end
  local dispatched = #calls
  worker:step()
  -- Malformed selectors fail closed without dispatching: the flush may
  -- re-observe the still-pending valid jobs, but no call may carry a new
  -- job identity beyond the four already dispatched.
  for index = dispatched + 1, #calls do
    local call = calls[index]
    local redispatched = false
    for prior = 1, dispatched do
      if calls[prior].kind == call.kind and calls[prior].key == call.key then
        redispatched = true
        break
      end
    end
    Assert.isTrue(
      redispatched,
      "malformed leaf selectors dispatch no further jobs: " .. tostring(call.kind) .. ":" .. tostring(call.key)
    )
  end
  local settled = packetsOf(replies, "request-result")
  local failures = 0
  for index = 5, #settled do
    Assert.equal(settled[index].state, "failed", "a malformed leaf selector reports failure")
    Assert.isTrue(tostring(settled[index].errorMessage) ~= "", "a malformed leaf selector carries its cause")
    failures = failures + 1
  end
  Assert.equal(failures, #badPackets, "each malformed leaf selector fails its own request")
  Assert.isTrue(worker.lifecycle ~= "failed", "a malformed leaf selector never kills the controller")
end

-- A leaf demand for a retired epoch never reaches the worker: the stale
-- packet is dropped without dispatching a job or emitting a terminal
-- event, so it cannot make a new selection ready.
function T.battle_leaf_requests_ignore_retired_epochs()
  local calls = {}
  local answer = { ready = false, failure = nil }
  local session = { pumps = 0 }
  function session.update()
    session.pumps = session.pumps + 1
  end
  function session.requestJob(_, kind, key, urgency)
    calls[#calls + 1] = { kind = kind, key = key, urgency = urgency }
    return answer.ready, answer.failure
  end
  function session.hasRunnablePlanning()
    return false
  end
  function session.nextPlanningWakeDelay()
    return nil
  end
  local worker, replies, queued = pushWorker(session, 7)
  queued[#queued + 1] = {
    op = "request",
    epoch = 6,
    requestId = 61,
    requestKind = "battle-trainer-picture",
    trainerSelector = "front:YOUNGSTER",
    urgency = "required",
  }
  queued[#queued + 1] = {
    op = "request",
    epoch = 6,
    requestId = 62,
    requestKind = "battle-ball",
    ballSelector = "ball:POKE_BALL",
    urgency = "required",
  }
  queued[#queued + 1] =
    { op = "request", epoch = 6, requestId = 63, requestKind = "battle-evolution", urgency = "required" }
  worker:step()
  Assert.equal(#calls, 0, "a retired epoch dispatches no leaf jobs")
  Assert.equal(#packetsOf(replies, "request-result"), 0, "a retired epoch emits no terminal events")
  Assert.isTrue(worker.lifecycle ~= "failed", "a retired epoch never kills the controller")
end

-- One cry bank demand dispatches the generic audio-bank job keyed by its
-- numeric bank; a malformed bank fails its own request.
-- The selector-free editor demand dispatches its registered global job
-- with urgency alone; extras fail their own request without killing the
-- controller.
function T.easy_chat_selector_dispatches_the_global_job()
  local calls = {}
  local session = { pumps = 0 }
  function session.update()
    session.pumps = session.pumps + 1
  end
  function session.requestJob(_, kind, key, urgency)
    calls[#calls + 1] = { kind = kind, key = key, urgency = urgency }
    return true, nil
  end
  function session.hasRunnablePlanning()
    return false
  end
  function session.nextPlanningWakeDelay()
    return nil
  end
  local worker, replies, queued = pushWorker(session, 7)
  queued[#queued + 1] = { op = "request", epoch = 7, requestId = 51, requestKind = "easy-chat", urgency = "required" }
  queued[#queued + 1] =
    { op = "request", epoch = 7, requestId = 52, requestKind = "easy-chat", urgency = "required", pageId = 3 }
  worker:step()
  worker:step()
  Assert.equal(calls[1].kind, "easy-chat", "the dispatched job keeps its kind")
  Assert.equal(calls[1].key, "global", "the dispatched job keys the global job")
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 2, "both requests settle")
  Assert.equal(results[1].state, "ready", "a ready editor completes through its terminal event")
  Assert.equal(results[2].state, "failed", "a selector-carrying demand fails its own request")
  Assert.isTrue(worker.lifecycle ~= "failed", "a malformed selector never kills the controller")
end

function T.audio_bank_selector_dispatches_the_bank_job()
  local calls = {}
  local session = { pumps = 0 }
  function session.update()
    session.pumps = session.pumps + 1
  end
  function session.requestJob(_, kind, key, urgency)
    calls[#calls + 1] = { kind = kind, key = key, urgency = urgency }
    return true, nil
  end
  function session.hasRunnablePlanning()
    return false
  end
  function session.nextPlanningWakeDelay()
    return nil
  end
  local worker, replies, queued = pushWorker(session, 7)
  queued[#queued + 1] =
    { op = "request", epoch = 7, requestId = 51, requestKind = "audio-bank", bankId = 158, urgency = "required" }
  queued[#queued + 1] =
    { op = "request", epoch = 7, requestId = 52, requestKind = "audio-bank", bankId = -1, urgency = "required" }
  worker:step()
  worker:step()
  Assert.equal(calls[1].kind, "audio-bank", "the dispatched job keeps its kind")
  Assert.equal(calls[1].key, "158", "the dispatched job keys the bank id")
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 2, "both requests settle")
  Assert.equal(results[1].state, "ready", "a ready bank completes through its terminal event")
  Assert.equal(results[2].state, "failed", "a malformed bank fails its own request")
  Assert.isTrue(worker.lifecycle ~= "failed", "a malformed selector never kills the controller")
end

-- A source offer for the live epoch is never silently dropped: the
-- controller acknowledges it, forwards it to its pool, or rejects it
-- visibly. The exact acknowledgement shape stays the implementation's
-- choice; this scenario only proves the offer reaches an owner.
function T.live_epoch_source_offer_is_never_silently_dropped()
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local worker, replies, queued = pushWorker(terminalSession(), 7)
  local forwarded = {}
  local pool = { state = "idle", updates = 0 }
  function pool.activityState()
    return pool.state
  end
  function pool.update()
    pool.updates = pool.updates + 1
  end
  setmetatable(pool, {
    __index = function(_, key)
      return function(_, ...)
        forwarded[#forwarded + 1] = { method = key }
      end
    end,
  })
  worker.pool = pool
  local buffer = hostLove.data.newByteData("synthetic-offer-bytes")
  queued[#queued + 1] = {
    op = "offer-source",
    epoch = 7,
    byteData = buffer,
    versionId = "heartgold",
    romSha1 = string.rep("0", 40),
  }
  worker:step()
  Assert.isTrue(
    #replies >= 1 or #forwarded >= 1,
    "a live-epoch source offer must be acknowledged or forwarded, never silently dropped"
  )
  Assert.isTrue(worker.lifecycle ~= "failed", "handling the offer never fails the controller")
end

-- A stale epoch or a non-buffer offer is refused visibly: the controller
-- answers ok=false on its reply channel and forwards nothing to its pool.
-- Rejection is explicit, never a silent drop and never a lifecycle failure.
function T.stale_epoch_source_offer_is_refused_visibly()
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local worker, replies, queued = pushWorker(terminalSession(), 7)
  local forwarded = {}
  local pool = { state = "idle", updates = 0 }
  function pool.activityState()
    return pool.state
  end
  function pool.update()
    pool.updates = pool.updates + 1
  end
  setmetatable(pool, {
    __index = function(_, key)
      return function(_, ...)
        forwarded[#forwarded + 1] = { method = key }
      end
    end,
  })
  worker.pool = pool
  local buffer = hostLove.data.newByteData("synthetic-offer-bytes")
  queued[#queued + 1] = {
    op = "offer-source",
    epoch = 8,
    byteData = buffer,
    versionId = "heartgold",
    romSha1 = string.rep("0", 40),
  }
  queued[#queued + 1] = {
    op = "offer-source",
    epoch = 7,
    byteData = "not-a-shared-buffer",
    versionId = "heartgold",
    romSha1 = string.rep("0", 40),
  }
  worker:step()
  local refusals = {}
  for _, packet in ipairs(replies) do
    if type(packet) == "table" and packet.op == "offer-source-result" then
      refusals[#refusals + 1] = packet
    end
  end
  Assert.equal(#refusals, 2, "every foreign offer earns a visible refusal")
  for _, refusal in ipairs(refusals) do
    Assert.isFalse(refusal.ok == true, "a foreign offer is never accepted")
  end
  Assert.equal(#forwarded, 0, "a refused offer never reaches the pool")
  Assert.isTrue(worker.lifecycle ~= "failed", "refusing an offer never fails the controller")
end

-- Post-quiesce maintenance never owns the raw source trees or user data: a
-- settled sweep leaves them byte-identical and writes no marker of its own.
-- The proven-shared collector keeps its own proof-gated contract, covered
-- by its dedicated suite; this seam pins only that quiescence preserves
-- what the cache does not own.
function T.quiesce_preserves_source_trees_and_user_data()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local sibling = CacheFs.forVersion("soulsilver", backend)
  local generated = "return { map = 61 }\n"
  cache:write("data/generated/maps/61.lua", generated)
  cache:write("romfs/old", "raw extracted bytes")
  cache:write("system/old", "raw system bytes")
  cache:write("data/generated/rom_metadata.lua", "return { raw = true }\n")
  cache:write("rom-dump.complete", "raw")
  local modLogical = "return { name = 'kept' }\n"
  cache:write("mods/mymod/info.lua", modLogical)
  local stageLogical = string.rep("staged-block;", 120)
  cache:write("staging/leftover/scratch.lua", stageLogical)
  local siblingLogical = string.rep("sibling-block;", 120)
  sibling:write("data/generated/maps/61.lua", siblingLogical)

  local session = terminalSession()
  session.completion = { sweepExhausted = true }
  session.cacheFs = cache
  session.generationId = "test-generation"
  session.producerId = "test-producer"
  local worker, replies, queued = pushWorker(session, 9)
  worker.selectedVersionId = "heartgold"
  queued[#queued + 1] = { op = "quiesce", epoch = 9, barrierId = 5 }
  worker:step()

  local settled = packetsOf(replies, "barrier-result")
  Assert.equal(#settled, 1, "quiescence still pushes its barrier event")
  Assert.equal(cache:read("romfs/old"), "raw extracted bytes", "the raw source tree survives quiescence")
  Assert.equal(cache:read("system/old"), "raw system bytes", "the raw system tree survives quiescence")
  Assert.equal(
    cache:read("data/generated/rom_metadata.lua"),
    "return { raw = true }\n",
    "superseded source metadata survives quiescence"
  )
  Assert.equal(cache:read("rom-dump.complete"), "raw", "the source marker survives quiescence")
  Assert.isFalse(cache:exists("data/generated/storage-migrated.lua"), "quiescence writes no marker of its own")
  Assert.equal(cache:read("mods/mymod/info.lua"), modLogical, "user mods stay byte-identical")
  Assert.equal(cache:read("staging/leftover/scratch.lua"), stageLogical, "staging debris is never entered")
  Assert.equal(sibling:read("data/generated/maps/61.lua"), siblingLogical, "a sibling version is never entered")
  Assert.equal(cache:read("data/generated/maps/61.lua"), generated)
end

-- The release selection identity the boot gate compares against.
local function bootIdentity()
  local GameVersion = require("romdump.src.source.GameVersion")
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
  return DerivedCacheState.currentForSelection({
    versionId = "heartgold",
    romSha1 = GameVersion.info("heartgold").sha1,
    producerId = "r" .. tostring(DerivedCacheVersions.heartgold),
  })
end

-- A captured snapshot as the next boot would hydrate it: the generated bytes
-- one fact owns plus the completion facts of that same cut.
local function capturedCut(options)
  options = options or {}
  local identity = options.identity or bootIdentity()
  local entries = {}
  local artifacts = {}
  for index, source in ipairs(options.sources or {}) do
    local path = source.path
    entries[index] = { path = path, data = assert(love.data.newByteData(source.text)), size = #source.text }
  end
  local files = {}
  for _, entry in ipairs(entries) do
    files[#files + 1] = entry.path
  end
  if #files > 0 then
    artifacts[1] = {
      kind = options.kind or "map",
      key = options.key or "61",
      marker = "snapshot-marker",
      dependencies = {},
      ownedRoots = { "data/generated/maps" },
      sharedPaths = {},
      files = files,
    }
  end
  return {
    versionId = identity.versionId,
    identity = identity,
    sequence = options.sequence or 4,
    entries = entries,
    artifacts = artifacts,
    milestones = options.milestones or {},
    firstPlay = options.firstPlay == true,
    complete = options.complete == true,
  }
end

-- The one snapshot candidate this drive may open. The controller hydrates the
-- recoverable archive at selection, so the fixture replaces that single owner
-- entry point with a cut the test already built: no file is written and no
-- other suite can observe it.
local function withSnapshotCandidate(hydration, fn)
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local realRecoverable = CacheArchive.recoverableFileName
  local realOpen = CacheArchive.open
  local realRestore = CacheArchive.restoreBackup
  CacheArchive.restoreBackup = function()
    return false
  end
  CacheArchive.recoverableFileName = function()
    return hydration ~= nil and "cache.zip" or nil
  end
  CacheArchive.open = function(_, expectedIdentity)
    if hydration == nil then
      return nil, { code = "CACHE_ARCHIVE_UNREADABLE", message = "no snapshot archive is present" }
    end
    if hydration.identity.generationId ~= expectedIdentity.generationId then
      return nil, { code = "CACHE_ARCHIVE_SCHEMA_INVALID", message = "the snapshot belongs to another generation" }
    end
    return hydration
  end
  local ok, err = pcall(fn)
  CacheArchive.recoverableFileName = realRecoverable
  CacheArchive.open = realOpen
  CacheArchive.restoreBackup = realRestore
  if not ok then
    error(err, 0)
  end
end

-- A boot-source drive: a fresh controller with a live session and the given
-- pool answers exactly one boot-source check against the given completion fact.
local function driveBootCheck(identity, pool, complete)
  local queued = {}
  local control = {}
  function control.pop()
    if #queued == 0 then
      return nil
    end
    return table.remove(queued, 1)
  end
  local replies = {}
  local reply = {}
  function reply:push(message)
    replies[#replies + 1] = message
  end
  local worker = CacheControllerWorker.Worker.new(control, reply)
  local session = {}
  function session:update() end
  worker.session = session
  worker.pool = pool
  worker.selectedIdentity = identity
  worker.liveEpoch = 7
  worker.lifecycle = "active"
  worker.complete = complete == true
  queued[#queued + 1] = { op = "check-boot-source", epoch = 7 }
  worker:step()
  for _, packet in ipairs(replies) do
    if type(packet) == "table" and packet.op == "boot-source-result" then
      return packet
    end
  end
  error("the boot gate answered nothing", 0)
end

-- A source pool with no registered source: anything but the captured complete
-- fact reports its typed cause instead of admitting the boot.
local function sourcelessPool()
  local pool = { calls = {} }
  function pool:prepareBootSource(epoch, needsSource)
    pool.calls[#pool.calls + 1] = needsSource
    if needsSource then
      return false, { code = "ROM_SOURCE_REQUIRED", message = "the original source is unavailable", context = {} }
    end
    return true
  end
  return pool
end

-- A complete captured cut admits the boot with no source at all, while a cut
-- that only proves first play still asks for one: completeness is a fact of the
-- cut, never a marker beside the payloads.
function T.complete_snapshot_boots_without_source_and_a_partial_one_does_not()
  local identity = bootIdentity()
  local complete = driveBootCheck(identity, sourcelessPool(), true)
  Assert.equal(complete.state, "ready", "a complete cut boots without its source")
  Assert.isNil(complete.detail, "a complete boot carries no failure detail")

  local pool = sourcelessPool()
  local partial = driveBootCheck(identity, pool, false)
  Assert.equal(partial.state, "source-required", "a first-play-only cut still requires its source")
  Assert.equal(#pool.calls, 1, "the partial boot consults the source exactly once")
  Assert.isTrue(pool.calls[1], "the partial boot asks the pool to pin its source")
  Assert.equal(partial.detail.code, "ROM_SOURCE_REQUIRED", "the missing source names its cause")
end

-- Deterministic process-local thread host for the boot-gate drive: FIFO
-- channels plus a killable worker, mirroring the service suite shape. No
-- real OS thread starts here.
local function bootServiceHost()
  local host = {}
  function host.newChannel()
    local values = {}
    local channel = {}
    function channel:push(value)
      values[#values + 1] = value
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:demand()
      return channel:pop()
    end
    function channel:getCount()
      return #values
    end
    function channel:count()
      return #values
    end
    return channel
  end
  function host.newThread()
    local thread = { starts = 0, waits = 0 }
    function thread:start()
      self.starts = self.starts + 1
      return true
    end
    function thread:wait()
      self.waits = self.waits + 1
      return true
    end
    function thread:getError()
      return nil
    end
    function thread:isRunning()
      return self.starts > 0
    end
    return thread
  end
  return host
end

local function bootPoolThreadApi()
  return {
    newChannel = function()
      local values = {}
      local channel = {}
      function channel:push(value)
        values[#values + 1] = value
        return true
      end
      function channel:pop()
        if #values == 0 then
          return nil
        end
        return table.remove(values, 1)
      end
      function channel:demand()
        return channel:pop()
      end
      function channel:getCount()
        return #values
      end
      return channel
    end,
    newThread = function()
      local thread = {}
      function thread:start()
        return true
      end
      function thread:wait()
        return true
      end
      function thread:getError()
        return nil
      end
      function thread:isRunning()
        return true
      end
      return thread
    end,
  }
end

-- One composed boot drive through the real service and the real controller:
-- selection plus boot gate flush FIFO, the controller answers exactly once, and
-- the service absorbs the answer. Reports the observed status, its detail, the
-- number of external source opens, whether a source buffer stayed retained, and
-- the physical cache the drive ran against.
---@param candidate table<string, unknown>|nil captured snapshot the drive may hydrate
---@return string? status
---@return table<string, unknown>? detail
---@return integer opens
---@return boolean held
---@return table<string, unknown> backend
local function driveBootGate(candidate)
  local CacheService = require("app.src.CacheService")
  local RomSource = require("romdump.src.source.RomSource")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local backend = FakeCache.new()
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  Assert.isTrue(
    type(service.requestBootSource) == "function",
    "the boot gate queues behind selection on the same control stream"
  )
  Assert.isTrue(
    type(service.bootSourceStatus) == "function",
    "the boot gate reports its epoch-scoped readiness without filesystem work"
  )
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  service:update()
  local opens = 0
  local realFromPath = RomSource.fromPath
  RomSource.fromPath = function(path, options)
    opens = opens + 1
    return realFromPath(path, options)
  end
  local realThread = hostLove.thread
  hostLove.thread = bootPoolThreadApi()
  local stepOk, stepErr = pcall(function()
    withSnapshotCandidate(candidate, function()
      worker:step()
    end)
  end)
  hostLove.thread = realThread
  RomSource.fromPath = realFromPath
  assert(stepOk, stepErr)
  service:update()
  local status, detail = service:bootSourceStatus(epoch)
  local held = worker.pool ~= nil and worker.pool.sharedSource ~= nil
  service:shutdown()
  pcall(function()
    if worker.pool ~= nil then
      worker.pool:shutdown()
    end
  end)
  return status, detail, opens, held, backend
end

-- A strictly current complete cut boots with no source work at all: no offer,
-- no registered path, zero opens, zero retained buffers. A foreign or damaged
-- candidate is discarded whole and takes the ordinary source route instead.
function T.current_complete_snapshot_boots_without_source_io()
  local status, detail, opens, held, backend = driveBootGate(
    capturedCut({ complete = true, sources = { { path = "data/generated/maps/61.lua", text = "return { map = 61 }\n" } } })
  )
  Assert.equal(status, "ready", "a strictly current complete cut boots with no source")
  Assert.isNil(detail, "a fast boot carries no failure detail")
  Assert.equal(opens, 0, "a complete cut performs zero source opens")
  Assert.isFalse(held, "a fast boot retains no source buffer")
  Assert.notNil(backend, "the drive owns its physical cache")
end

-- A candidate the archive owner refuses is dropped whole: selection still
-- succeeds, main installs an empty store, and the boot takes the rebuild route
-- instead of failing the controller.
function T.refused_snapshot_candidate_never_blocks_selection()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local CacheService = require("app.src.CacheService")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local realRecoverable = CacheArchive.recoverableFileName
  local realOpen = CacheArchive.open
  local realRestore = CacheArchive.restoreBackup
  local backend = FakeCache.new()
  CacheArchive.restoreBackup = function()
    return false
  end
  CacheArchive.recoverableFileName = function()
    return "cache.zip"
  end
  CacheArchive.open = function()
    return nil, { code = "CACHE_ARCHIVE_UNREADABLE", message = "synthetic damage" }
  end
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  service:update()
  local realThread = hostLove.thread
  hostLove.thread = bootPoolThreadApi()
  local stepOk, stepErr = pcall(function()
    worker:step()
  end)
  hostLove.thread = realThread
  CacheArchive.recoverableFileName = realRecoverable
  CacheArchive.open = realOpen
  CacheArchive.restoreBackup = realRestore
  assert(stepOk, stepErr)
  service:update()
  Assert.equal(worker.lifecycle, "active", "a refused candidate never fails the controller")
  Assert.notNil(worker.session, "selection still owns its generation session")
  Assert.notNil(worker.snapshot.lastError, "the discarded candidate leaves its typed diagnostic")
  Assert.equal(worker.complete, false, "a refused candidate proves no completeness")
  local status = service:bootSourceStatus(epoch)
  Assert.isTrue(status == "ready" or status == "source-required", "the boot takes its ordinary route: " .. tostring(status))
  local reader = assert(service:getCacheFs(epoch), "the empty initial installation still produced a reader")
  Assert.isNil(reader:read("data/generated/maps/61.lua"), "no bytes were installed from the refused candidate")
  service:shutdown()
  pcall(function()
    if worker.pool ~= nil then
      worker.pool:shutdown()
    end
  end)
end

-- One composed boot drive with a mismatched source offer: selection
-- plus a wrong-identity offer flush FIFO, the controller visibly refuses
-- the offer, and the boot gate fails with its typed cause instead of
-- admitting gameplay on other grounds.
function T.rejected_offer_fails_the_boot_gate()
  local CacheService = require("app.src.CacheService")
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  local buffer = hostLove.data.newByteData("synthetic-offer-bytes")
  service:offerSource(epoch, buffer, { versionId = "heartgold", romSha1 = string.rep("1", 40) })
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  service:update()
  local realThread = hostLove.thread
  hostLove.thread = bootPoolThreadApi()
  local stepOk, stepErr = pcall(function()
    withSnapshotCandidate(nil, function()
      worker:step()
    end)
  end)
  hostLove.thread = realThread
  assert(stepOk, stepErr)
  service:update()
  local status, detail = service:bootSourceStatus(epoch)
  Assert.equal(status, "failed", "a refused offer fails the boot gate")
  Assert.equal(detail.code, "SOURCE_OFFER_REJECTED", "the refusal carries its typed cause")
  service:shutdown()
  pcall(function()
    if worker.pool ~= nil then
      worker.pool:shutdown()
    end
  end)
end

-- Seed one fabricated source registration and drive the boot gate against
-- it, reporting the observed status and typed detail code.
---@param binding table<string, unknown> fabricated seven-field registration
---@return string? status
---@return table<string, unknown>? detail
local function driveBootGateWithBinding(binding)
  local CacheService = require("app.src.CacheService")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local backend = FakeCache.new()
  CacheFs.forVersion("heartgold", backend):writeLua(require("romdump.src.source.RomBinding").PATH, binding)
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  service:update()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function(selected)
    assert(selected == "heartgold", "the boot drive stays on its version")
    return cacheFs
  end
  local realThread = hostLove.thread
  hostLove.thread = bootPoolThreadApi()
  local stepOk, stepErr = pcall(function()
    withSnapshotCandidate(nil, function()
      worker:step()
    end)
  end)
  hostLove.thread = realThread
  CacheFs.forVersion = realForVersion
  assert(stepOk, stepErr)
  service:update()
  local status, detail = service:bootSourceStatus(epoch)
  service:shutdown()
  pcall(function()
    if worker.pool ~= nil then
      worker.pool:shutdown()
    end
  end)
  return status, detail
end

-- Unusable registered sources are source problems, not infrastructure
-- failures: a missing file, a wrong-identity registration, and a missing
-- exact archive member each report source-required with their typed code.
function T.unusable_registered_sources_report_source_required()
  local GameVersion = require("romdump.src.source.GameVersion")
  local info = GameVersion.info("heartgold")
  local missingStatus, missingDetail = driveBootGateWithBinding({
    schema = 1,
    versionId = "heartgold",
    romSha1 = info.sha1,
    kind = "nds",
    path = (os.getenv("TMPDIR") or "/tmp") .. "/portemon-never-present.nds",
    displayName = "missing.nds",
    zipEntry = false,
  })
  Assert.equal(missingStatus, "source-required", "a missing source file requires its source")
  Assert.equal(missingDetail.code, "ROM_OPEN_FAILED", "a missing file names its cause")
  local wrongStatus, wrongDetail = driveBootGateWithBinding({
    schema = 1,
    versionId = "heartgold",
    romSha1 = string.rep("2", 40),
    kind = "nds",
    path = (os.getenv("TMPDIR") or "/tmp") .. "/portemon-wrong-identity.nds",
    displayName = "wrong.nds",
    zipEntry = false,
  })
  Assert.equal(wrongStatus, "source-required", "a wrong-identity registration requires its source")
  Assert.equal(wrongDetail.code, "ROM_BINDING_MISMATCH", "a wrong identity names its cause")
  local ZipBuilder = require("tests.support.ZipBuilder")
  local zipBytes = ZipBuilder.build({ { name = "other.txt", data = "not a rom" } })
  local zipPath = (os.getenv("TMPDIR") or "/tmp") .. "/portemon-missing-member.zip"
  local zipFile = assert(io.open(zipPath, "wb"), "the zip fixture must be writable")
  zipFile:write(zipBytes)
  zipFile:close()
  local zipStatus, zipDetail = driveBootGateWithBinding({
    schema = 1,
    versionId = "heartgold",
    romSha1 = info.sha1,
    kind = "zip",
    path = zipPath,
    displayName = "archive.zip",
    zipEntry = "absent/game.nds",
  })
  os.remove(zipPath)
  Assert.equal(zipStatus, "source-required", "a missing exact member requires its source")
  Assert.equal(zipDetail.code, "ZIP_ENTRY_MISSING", "a missing member names its cause")
end

-- A stale boot check for a retired epoch earns no reply and touches no state.
function T.stale_boot_check_earns_no_reply()
  local values = {}
  local control = {}
  function control.pop()
    if #values == 0 then
      return nil
    end
    return table.remove(values, 1)
  end
  local replies = {}
  local reply = {}
  function reply:push(message)
    replies[#replies + 1] = message
  end
  local worker = CacheControllerWorker.Worker.new(control, reply)
  values[#values + 1] = { op = "check-boot-source", epoch = 99 }
  worker:step()
  Assert.equal(#replies, 0, "a foreign boot check earns no reply")
end

-- Deterministic clock for the snapshot deadlines: the controller reads it
-- instead of the host wall clock, so a debounce or retry elapses without
-- waiting.
local function fakeClock()
  local clock = { now = 100 }
  clock.read = function()
    return clock.now
  end
  return clock
end

-- A controller over the real pool with a fake archive writer: the test owns
-- the whole writer channel pair, so it can inspect the captured cut and answer
-- it deliberately. Returns the worker, the service, the epoch, and the clocks.
local function snapshotRig(candidate)
  local CacheService = require("app.src.CacheService")
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local clock = fakeClock()
  worker.clock = clock.read
  local epoch = assert(service:select({ versionId = "heartgold" }))
  local buffer = hostLove.data.newByteData("synthetic-offer-bytes")
  service:offerSource(epoch, buffer, { versionId = "heartgold", romSha1 = GameVersion.info("heartgold").sha1 })
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  service:update()
  local realThread = hostLove.thread
  hostLove.thread = bootPoolThreadApi()
  local stepOk, stepErr = pcall(function()
    withSnapshotCandidate(candidate, function()
      worker:step()
    end)
  end)
  assert(stepOk, stepErr)
  service:update()
  -- The fake thread host stays installed: the controller creates its archive
  -- writer lazily on the first capture, and no test may start a real one.
  return {
    hostLove = hostLove,
    service = service,
    worker = worker,
    epoch = epoch,
    clock = clock,
    buffer = buffer,
    realThread = realThread,
  }
end

local function closeSnapshotRig(rig)
  rig.hostLove.thread = rig.realThread
  rig.service:shutdown()
  pcall(function()
    if rig.worker ~= nil then
      assert(rig.worker):_closeArchiveWriter()
    end
  end)
  pcall(function()
    local pool = rig.worker ~= nil and rig.worker.pool or nil
    if pool ~= nil then
      pool:shutdown()
    end
  end)
end

-- One completed-session pump: the fake session reports an exhaustive settled
-- sweep over the generation the selection owns.
local function completedSession(worker, generationId)
  local session = { generationId = generationId }
  function session:update() end
  function session:status()
    return {
      generationId = generationId,
      sweepState = "exhausted",
      sweepFailure = nil,
      bootstrap = "ready",
      failed = 0,
      queued = 0,
      running = 0,
      complete = false,
    }
  end
  function session:milestoneFacts()
    return { "bootstrap", "new-game-intro", "field-planning", "field-runtime" }
  end
  function session:hasRunnablePlanning()
    return false
  end
  function session:nextPlanningWakeDelay()
    return nil
  end
  worker.session = session
  return session
end

-- Completion is a memory fact and is installed with its own sequence: the boot
-- hold releases at once, a borrowed source view survives its close handshake,
-- and the persisted sequence stays behind until a writer actually answers.
function T.completion_fact_installs_and_releases_the_boot_hold_without_persistence()
  local rig = snapshotRig(nil)
  local worker = rig.worker
  local pool = assert(worker.pool, "the selection owns its compiler pool")
  Assert.equal(rig.service:bootSourceStatus(rig.epoch), "ready", "the offered buffer satisfies the boot gate")
  local generationId = assert(worker.selectedIdentity, "the selection owns its identity").generationId
  completedSession(worker, generationId)
  local stepOk, stepErr = pcall(function()
    worker:step()
  end)
  assert(stepOk, stepErr)
  Assert.isNil(pool.bootSourceHold, "a proven generation releases its boot hold")
  Assert.isNil(pool.sharedSource, "the borrower-free buffer unpins at once")
  Assert.isTrue(worker.complete, "the exhaustively settled generation is complete")
  Assert.equal(worker.snapshot.persistedSequence, 0, "completion alone persists nothing")
  Assert.isTrue(worker.snapshot.dirty, "the completion fact marks the cut dirty")
  Assert.isNil(worker.snapshot.active, "no capture starts before the debounce elapses")
  rig.service:update()
  Assert.isTrue(rig.service:bootSourceStatus(rig.epoch) == "ready", "persistence never gates the boot")
  closeSnapshotRig(rig)
end

-- A failed snapshot write keeps the ready generation and reports once: the
-- retry deadline is armed, persistedSequence stays behind the captured
-- sequence, and a later capture uses the newest cut.
function T.failed_snapshot_write_keeps_play_ready_and_reports_once()
  local rig = snapshotRig(nil)
  local worker = rig.worker
  local generationId = assert(worker.selectedIdentity, "the selection owns its identity").generationId
  completedSession(worker, generationId)
  local stepOk, stepErr = pcall(function()
    worker:step()
  end)
  assert(stepOk, stepErr)
  rig.clock.now = rig.clock.now + 6
  worker:step()
  local control = assert(worker.snapshot.control, "the capture reached the archive writer")
  local cut = control:pop()
  Assert.equal(type(cut), "table", "the writer received its capture")
  Assert.equal(cut.op, "snapshot", "the writer received a snapshot command")
  Assert.equal(cut.sequence, worker.sequence, "the cut names the installed sequence")
  Assert.isTrue(cut.complete, "the cut carries the completion fact it captured")
  local captured = cut.sequence
  worker.snapshot.reply:push({
    op = "snapshot-failed",
    versionId = cut.versionId,
    generationId = cut.generationId,
    epoch = cut.epoch,
    sequence = cut.sequence,
    error = { code = "CACHE_ARCHIVE_WRITE_FAILED", message = "synthetic write failure" },
  })
  worker:step()
  Assert.isNil(worker.snapshot.active, "the failure settles the one active capture")
  Assert.equal(worker.snapshot.persistedSequence, 0, "a failure never advances the persisted sequence")
  Assert.notNil(worker.snapshot.lastError, "the failure keeps its typed cause")
  Assert.equal(worker.snapshot.lastError.code, "CACHE_ARCHIVE_WRITE_FAILED")
  Assert.isTrue(worker.complete, "a failed write never revokes the ready generation")
  local reports = {}
  for _, packet in ipairs(drainChannel(rig.service._reply)) do
    if packet.op == "cache-persistence-failed" then
      reports[#reports + 1] = packet
    end
  end
  Assert.equal(#reports, 1, "one failed attempt is reported exactly once")
  Assert.equal(reports[1].op, "cache-persistence-failed", "the report names its own op")
  Assert.equal(reports[1].sequence, captured, "the report names the captured sequence")

  local retry = worker.snapshot.retryAt
  Assert.notNil(retry, "a failure arms the retry deadline")
  rig.clock.now = retry - 1
  worker:step()
  Assert.isNil(worker.snapshot.active, "no capture is attempted before the retry deadline")
  rig.clock.now = retry
  worker:step()
  local again = assert(worker.snapshot.control):pop()
  Assert.equal(type(again), "table", "the retry captures the latest cut")
  Assert.equal(again.sequence, worker.sequence, "the retry names the current sequence")
  closeSnapshotRig(rig)
end

-- One captured snapshot and one pending dirty indication: an acknowledgement
-- of N advances only N, a newer commit keeps the cut dirty, and retirement
-- cancels a pending capture without waiting for the writer.
function T.snapshot_coalescing_advances_only_the_captured_sequence()
  local rig = snapshotRig(nil)
  local worker = rig.worker
  local generationId = assert(worker.selectedIdentity, "the selection owns its identity").generationId
  completedSession(worker, generationId)
  local stepOk, stepErr = pcall(function()
    worker:step()
  end)
  assert(stepOk, stepErr)
  rig.clock.now = rig.clock.now + 6
  worker:step()
  local first = assert(worker.snapshot.control):pop()
  Assert.equal(first.sequence, worker.sequence, "the first capture names the installed sequence")

  -- A later completion fact moves the cut while the writer owns the first one.
  worker.firstPlay = true
  worker:_publishInstallation(true)
  local newer = worker.sequence
  Assert.isTrue(newer > first.sequence, "a completion fact advances the installed sequence")
  worker:step()
  Assert.isNil(worker.snapshot.control:pop(), "no second capture starts while one is active")
  Assert.isTrue(worker.snapshot.dirty, "the newer cut stays dirty while the writer is busy")

  worker.snapshot.reply:push({
    op = "snapshot-persisted",
    versionId = first.versionId,
    generationId = first.generationId,
    epoch = first.epoch,
    sequence = first.sequence,
  })
  worker:step()
  Assert.equal(worker.snapshot.persistedSequence, first.sequence, "the acknowledgement advances its own sequence")
  Assert.isTrue(worker.snapshot.dirty, "acknowledging N never clears dirty N+1")
  rig.clock.now = rig.clock.now + 6
  worker:step()
  local second = assert(worker.snapshot.control):pop()
  Assert.equal(second.sequence, newer, "the next capture takes the latest cut")

  worker.snapshot.reply:push({
    op = "snapshot-failed",
    versionId = second.versionId,
    generationId = second.generationId,
    epoch = second.epoch,
    sequence = second.sequence,
    error = { code = "CACHE_ARCHIVE_REPLACE_FAILED", message = "synthetic promotion failure" },
  })
  worker:step()
  Assert.equal(worker.snapshot.persistedSequence, first.sequence, "a failed later capture keeps the earlier persistence")

  -- An active capture is what retirement must cancel; a capture that was only
  -- pending is simply dropped.
  worker.firstPlay = true
  worker:_publishInstallation(true)
  rig.clock.now = rig.clock.now + 6
  worker:step()
  rig.clock.now = worker.snapshot.retryAt
  worker:step()
  local third = worker.snapshot.control:pop()
  Assert.equal(third.sequence, worker.sequence, "a third capture owns the writer")
  local queue = { { op = "retire", epoch = rig.epoch, barrierId = 3 } }
  worker.control = {
    pop = function()
      if #queue == 0 then
        return nil
      end
      return table.remove(queue, 1)
    end,
    demand = function()
      return nil
    end,
  }
  worker:step()
  local cancel = assert(worker.snapshot.control):pop()
  Assert.equal(cancel.op, "cancel", "retirement cancels the active capture")
  Assert.equal(cancel.sequence, third.sequence, "the cancellation names the captured sequence")
  Assert.isFalse(worker.snapshot.dirty, "retirement drops the pending dirty indication")
  Assert.equal(worker.snapshot.persistedSequence, first.sequence, "retirement keeps the last persisted sequence")
  closeSnapshotRig(rig)
end

-- A completed generation settles back to its idle wait without a new timer and
-- never invalidates a borrowed source view early: the borrower-free path
-- releases at once, while a borrowed view stays valid through its close
-- handshake and only then unpins.
function T.completed_generation_idles_without_polling_and_honors_borrowed_views()
  local rig = snapshotRig(nil)
  local worker = rig.worker
  local pool = assert(worker.pool, "the selection owns its compiler pool")
  local generationId = assert(worker.selectedIdentity, "the selection owns its identity").generationId
  local borrowerId = assert(pool.workers[1], "the pool owns its worker").id
  pool.sourceBorrowers[borrowerId] = true
  completedSession(worker, generationId)
  local stepOk, stepErr = pcall(function()
    worker:step()
  end)
  assert(stepOk, stepErr)
  Assert.isNil(pool.bootSourceHold, "the hold clears even with a borrowed view")
  local retained = pool.sharedSource
  Assert.notNil(retained, "the borrowed buffer stays valid through its close handshake")
  local retainedBuffer = type(retained) == "table" and retained.byteData or retained
  Assert.isTrue(retainedBuffer == rig.buffer, "the borrowed view still pins the identical buffer")
  local closeMessage = pool.workers[1].input:pop()
  Assert.notNil(closeMessage, "the release asks its borrower to close")
  Assert.equal(closeMessage.kind, "close-context", "the borrower closes through its exact protocol")
  local closeToken = assert(closeMessage.closeToken, "the close carries its token")
  Assert.equal(pool:activityState(), "waiting", "an outstanding close keeps the pool waiting")
  local log = { demands = 0 }
  local fakeControl = {}
  function fakeControl.pop()
    return nil
  end
  function fakeControl.demand()
    log.demands = log.demands + 1
    return { op = "unknown-drive-probe" }
  end
  worker.control = fakeControl
  local timer = recordingTimer()
  worker:driveOnce(timer)
  Assert.equal(#timer.sleeps, 1, "a close wait sleeps exactly once before polling")
  Assert.equal(timer.sleeps[1], LIVE_CADENCE_SECONDS, "the close wait keeps the live poll cadence")
  Assert.equal(log.demands, 0, "a close wait never blocks on the control channel")
  Assert.notNil(pool.sharedSource, "the buffer stays valid across the poll")
  pool.resultChannel:push({ status = "context-closed", workerId = borrowerId, closeToken = closeToken })
  local updateOk, updateErr = pcall(function()
    pool:update()
  end)
  assert(updateOk, updateErr)
  Assert.isNil(pool.sharedSource, "the last acknowledgement unpins the buffer")
  closeSnapshotRig(rig)
end

-- A boot that finds a saved snapshot must decide where play stands from what
-- that snapshot honestly covers: a complete matching one admits the boot with
-- no source work at all, a partial one keeps the coverage it proves installed
-- while it verifies one source for the work it is missing, and a rejected one
-- installs nothing and asks for the source instead of retrying or admitting a
-- partial view.
--
-- The snapshots come from the production archive writer and are hydrated
-- through the archive owner's boot reader; this drive then composes the real
-- service, controller, and pool exactly like the existing boot-gate drives, with
-- the resolved initial view installed through the contracted installation
-- transport before the gate is asked.
local SnapshotBootFixture = require("tests.support.SnapshotBootFixture")

local BOOT_SCENE_PATH = "data/generated/field/30/scene.lua"
local BOOT_ATLAS_PATH = "assets/generated/field/30/atlas.png"
local BOOT_ATLAS_BYTES = "PNG-BOOT-COMPOSITION-ATLAS"

---@param identity table<string, unknown>
---@param options { complete: boolean, sequence: integer }
---@return table<string, unknown> one small closed cut
local function bootCut(identity, options)
  local entries = {
    SnapshotBootFixture.blob(identity, BOOT_SCENE_PATH, "return { mapId = 30 }\n"),
  }
  local files = { BOOT_SCENE_PATH }
  local sharedPaths = {}
  if options.complete then
    entries[2] = SnapshotBootFixture.blob(identity, BOOT_ATLAS_PATH, BOOT_ATLAS_BYTES)
    files[2] = BOOT_ATLAS_PATH
    sharedPaths = { BOOT_ATLAS_PATH }
  end
  return {
    generationId = identity.generationId,
    identity = identity,
    epoch = 1,
    sequence = options.sequence,
    entries = entries,
    artifacts = {
      {
        kind = "map",
        key = "30",
        marker = "map-ready",
        dependencies = {},
        ownedRoots = { "data/generated/field/30" },
        sharedPaths = sharedPaths,
        files = files,
      },
    },
    milestones = options.complete and { "bootstrap" } or {},
    firstPlay = options.complete,
    complete = options.complete,
  }
end

-- One boot of a selected version whose only generated input is the resolved
-- initial view: the hydrated snapshot when the boot kept one, otherwise the
-- empty store. The physical generated backend stays empty, so nothing this
-- drive observes can come from a loose file.
---@param options { identity: table<string, unknown>, candidate: table<string, unknown>? }
---@return table<string, unknown> the observed boot
local function bootFromSaved(options)
  local CacheService = require("app.src.CacheService")
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomSource = require("romdump.src.source.RomSource")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  local candidate = options.candidate
  if candidate ~= nil then
    SnapshotBootFixture.install(service, {
      epoch = epoch,
      identity = options.identity,
      sequence = candidate.sequence,
      initial = true,
      entries = SnapshotBootFixture.entries(candidate),
      milestones = candidate.milestones,
      firstPlay = candidate.firstPlay,
      complete = candidate.complete,
    })
  else
    SnapshotBootFixture.install(service, {
      epoch = epoch,
      identity = options.identity,
      sequence = 1,
      initial = true,
      entries = {},
      milestones = {},
      firstPlay = false,
      complete = false,
    })
  end
  service:update()

  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function(selected)
    assert(selected == "heartgold", "the boot drive stays on its version")
    return cacheFs
  end
  local opens = 0
  local realFromPath = RomSource.fromPath
  RomSource.fromPath = function(...)
    opens = opens + 1
    return realFromPath(...)
  end
  if options.offerSource then
    local info = GameVersion.info("heartgold")
    Assert.isTrue(
      service:offerSource(epoch, assert(hostLove.data.newByteData("synthetic-boot-source")), {
        versionId = "heartgold",
        romSha1 = info.sha1,
      }),
      "the boot drive offers its verified source to the live epoch"
    )
  end
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  service:update()
  local realThread = hostLove.thread
  hostLove.thread = bootPoolThreadApi()
  local stepOk, stepErr = pcall(function()
    -- The controller hydrates the candidate this boot resolved, so the boot
    -- gate decides from the same coverage the service already installed.
    withSnapshotCandidate(candidate, function()
      worker:step()
    end)
  end)
  hostLove.thread = realThread
  CacheFs.forVersion = realForVersion
  RomSource.fromPath = realFromPath
  assert(stepOk, stepErr)
  service:update()
  local status, detail = service:bootSourceStatus(epoch)
  local pool = worker.pool
  return {
    service = service,
    worker = worker,
    pool = pool,
    epoch = epoch,
    opens = opens,
    status = status,
    detail = detail,
    close = function()
      service:shutdown()
      if pool ~= nil then
        pcall(function()
          pool:shutdown()
        end)
      end
    end,
  }
end

---@param service table<string, unknown> installed cache service
---@param epoch integer live epoch
---@return table<string, unknown> the installed generated reader
local function installedReader(service, epoch)
  Assert.isTrue(
    type(service.getCacheFs) == "function",
    "the service hands out no installed generated reader, so an admitted boot reads physical generated files"
  )
  local reader = service:getCacheFs(epoch)
  Assert.notNil(reader, "an admitted boot exposes the installed generated reader")
  return reader
end

function T.a_saved_snapshot_decides_the_boot_route_from_its_coverage()
  local identity = SnapshotBootFixture.identity()
  local completeRoot = "boot-probe-admitted"
  local partialRoot = "boot-probe-partial"
  local damagedRoot = "boot-probe-rejected"
  local boots = {}
  local function remember(boot)
    boots[#boots + 1] = boot
    return boot
  end
  local ok, err = pcall(function()
    SnapshotBootFixture.save(completeRoot, bootCut(identity, { complete = true, sequence = 9 }))
    SnapshotBootFixture.save(partialRoot, bootCut(identity, { complete = false, sequence = 4 }))
    SnapshotBootFixture.save(damagedRoot, bootCut(identity, { complete = true, sequence = 6 }))

    -- A complete matching snapshot is all the boot needs.
    local complete = assert(SnapshotBootFixture.open(completeRoot, identity), "the complete snapshot hydrates")
    local admitted = remember(bootFromSaved({ identity = identity, candidate = complete }))
    Assert.equal(
      admitted.status,
      "ready",
      "a complete matching snapshot admits the boot with no source work at all"
    )
    Assert.equal(admitted.opens, 0, "an admitted snapshot boot opens no source file")
    Assert.notNil(admitted.pool, "the admitted boot owns its compiler pool")
    Assert.isNil(
      admitted.pool and admitted.pool.sharedSource or nil,
      "an admitted snapshot boot retains no source buffer"
    )
    local reader = installedReader(admitted.service, admitted.epoch)
    Assert.equal(
      reader:readData(BOOT_ATLAS_PATH):getString(),
      BOOT_ATLAS_BYTES,
      "the admitted boot serves the saved member bytes immediately"
    )
    Assert.deepEqual(
      admitted.service:cacheIdentity(admitted.epoch),
      identity,
      "the admitted boot keeps the identity its snapshot proved"
    )

    -- A partial snapshot never admits the offline boot, but it keeps what it
    -- proved and asks for exactly the source the rest needs.
    local partial, partialFailure = SnapshotBootFixture.open(partialRoot, identity)
    Assert.isTrue(
      partial ~= nil,
      "the partial snapshot hydrates: " .. tostring(partialFailure and partialFailure.message)
    )
    partial = assert(partial)
    local denied = remember(bootFromSaved({ identity = identity, candidate = partial }))
    Assert.equal(
      denied.status,
      "source-required",
      "a partial snapshot alone never admits the offline boot"
    )
    Assert.equal(denied.detail.code, "ROM_SOURCE_REQUIRED", "the partial boot names the source it needs")
    local supplied = remember(bootFromSaved({ identity = identity, candidate = partial, offerSource = true }))
    Assert.equal(supplied.status, "ready", "a verified source completes the partial boot")
    Assert.equal(supplied.opens, 0, "the offered source is used without opening a file")
    Assert.notNil(
      supplied.pool and supplied.pool.sharedSource or nil,
      "the partial boot pins one source buffer for the work it does not cover"
    )
    local partialReader = installedReader(supplied.service, supplied.epoch)
    Assert.equal(
      partialReader:readData(BOOT_SCENE_PATH):getString(),
      "return { mapId = 30 }\n",
      "the partial boot keeps the coverage its snapshot proved"
    )
    Assert.isNil(
      partialReader:resolveAsset(BOOT_ATLAS_PATH),
      "the partial boot must still produce what its snapshot never captured"
    )

    -- A rejected snapshot installs nothing, and the boot stops asking instead
    -- of looping or admitting a partial view.
    local savedBytes = assert(SnapshotBootFixture.canonical(damagedRoot))
    SnapshotBootFixture.writeCanonical(damagedRoot, savedBytes:sub(1, #savedBytes - 40))
    local rejected = SnapshotBootFixture.open(damagedRoot, identity)
    Assert.isNil(rejected, "the damaged snapshot yields no candidate for this boot")
    local rebuilt = remember(bootFromSaved({ identity = identity, candidate = nil }))
    Assert.equal(
      rebuilt.status,
      "source-required",
      "a rejected snapshot takes the rebuild route and asks for the source"
    )
    local emptyReader = installedReader(rebuilt.service, rebuilt.epoch)
    Assert.isNil(
      emptyReader:resolveAsset(BOOT_ATLAS_PATH),
      "a rejected snapshot installs none of its bytes"
    )
    Assert.isNil(emptyReader:resolveAsset(BOOT_SCENE_PATH), "a rejected snapshot installs no partial coverage")
    Assert.isTrue(rebuilt.service:requestBootSource(rebuilt.epoch), "the boot may ask its gate again")
    rebuilt.service:update()
    local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
    local realThread = hostLove.thread
    hostLove.thread = bootPoolThreadApi()
    local stepOk, stepErr = pcall(function()
      rebuilt.worker:step()
    end)
    hostLove.thread = realThread
    assert(stepOk, stepErr)
    rebuilt.service:update()
    local again = rebuilt.service:bootSourceStatus(rebuilt.epoch)
    Assert.equal(again, "source-required", "the rejected boot answers the same way without retrying the snapshot")
    Assert.isNil(
      installedReader(rebuilt.service, rebuilt.epoch):resolveAsset(BOOT_ATLAS_PATH),
      "a repeated gate leaves the rejected snapshot uninstalled"
    )
  end)
  for _, boot in ipairs(boots) do
    boot.close()
  end
  SnapshotBootFixture.releaseWriters()
  SnapshotBootFixture.removeRoot(completeRoot)
  SnapshotBootFixture.removeRoot(partialRoot)
  SnapshotBootFixture.removeRoot(damagedRoot)
  if not ok then
    error(err, 0)
  end
end

-- One background writer must save one honest cut at a time: the controller
-- hands it the latest committed sequence with that sequence's own immutable
-- bytes, keeps later committed work pending while a cut is in flight, never
-- runs two cuts at once, and lets no retired generation's pending or active
-- writer work mark a later same-version one.
--
-- The drive composes the real service, controller and compiler pool over a
-- deterministic channel host that records what every worker thread was
-- started with, so the snapshot writer's own channels are observed without a
-- private accessor. Committed work comes from synthetic worker results (the
-- suites that own the producer protocol prove the bytes); pacing runs on a
-- fake clock the controller's own drive loop advances.
local SNAPSHOT_PROBE_ROOT = "data/generated/snapshot-probe"

---@return table<string, unknown> recording channel/thread host
local function writerChannelHost()
  local host = { channels = {}, threads = {} }
  local function newChannel()
    local values = {}
    local channel = { log = {} }
    function channel:push(value)
      values[#values + 1] = value
      channel.log[#channel.log + 1] = value
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:demand()
      return channel:pop()
    end
    function channel:getCount()
      return #values
    end
    function channel:count()
      return #values
    end
    host.channels[#host.channels + 1] = channel
    return channel
  end
  local function newThread(code)
    local thread = { code = code, starts = 0, waits = 0, running = false, startArgs = nil }
    function thread:start(...)
      thread.startArgs = { ... }
      thread.starts = thread.starts + 1
      thread.running = true
      return true
    end
    function thread:wait()
      thread.waits = thread.waits + 1
      thread.running = false
      return true
    end
    function thread:isRunning()
      return thread.running
    end
    function thread:getError()
      return nil
    end
    function thread:kill()
      thread.running = false
      return true
    end
    host.threads[#host.threads + 1] = thread
    return thread
  end
  host.newChannel = newChannel
  host.newThread = newThread
  return host
end

---@param channel table recording channel
---@param predicate fun(packet: table): boolean
---@return table[] matching packets in send order
local function packetsMatching(channel, predicate)
  local matched = {}
  for _, packet in ipairs(channel.log) do
    if type(packet) == "table" and predicate(packet) then
      matched[#matched + 1] = packet
    end
  end
  return matched
end

-- Composes one live selection over the recording host: a hydrated snapshot
-- admits the boot, one verified source keeps the pool able to produce the
-- uncovered work, and every later commit comes from a synthetic worker result.
---@param options { sequence: integer, coverage: { path: string, text: string }|nil }
---@return table<string, unknown> the running drive
local function snapshotDrive(options)
  local CacheService = require("app.src.CacheService")
  local GameVersion = require("romdump.src.source.GameVersion")
  local identity = SnapshotBootFixture.identity()
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = writerChannelHost()
  local clock = { now = 0 }
  local timer = { sleeps = 0 }
  function timer.sleep(seconds)
    timer.sleeps = timer.sleeps + 1
    local value = tonumber(seconds) or 0
    if value > 0 then
      clock.now = clock.now + value
    end
  end
  local service = assert(CacheService.new({ thread = host }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local drive = {
    host = host,
    service = service,
    worker = worker,
    clock = clock,
    timer = timer,
    identity = identity,
    answered = {},
    authoredPaths = {},
  }
  drive.epoch = assert(service:select({ versionId = "heartgold", development = false }))
  local entries = {}
  local hydration = nil
  if options.coverage ~= nil then
    local blob = SnapshotBootFixture.blob(identity, options.coverage.path, options.coverage.text)
    entries[1] = blob
    -- The same coverage the service installs is the candidate the controller
    -- hydrates: the committed store then holds the captured bytes, so a cut
    -- that carries them can be checked byte for byte.
    hydration = {
      versionId = "heartgold",
      identity = identity,
      sequence = options.sequence,
      entries = { blob },
      artifacts = {
        {
          kind = "map",
          key = "30",
          marker = "coverage-ready",
          dependencies = {},
          ownedRoots = { assert(options.coverage.path:match("^(.*)/[^/]+$"), "coverage needs its owned root") },
          sharedPaths = {},
          files = { options.coverage.path },
        },
      },
      milestones = {},
      firstPlay = false,
      complete = false,
    }
  end
  SnapshotBootFixture.install(service, {
    epoch = drive.epoch,
    identity = identity,
    sequence = options.sequence,
    initial = true,
    entries = entries,
    milestones = {},
    firstPlay = false,
    complete = false,
  })
  service:update()

  local originalThread = hostLove.thread
  local originalGetTime = hostLove.timer.getTime
  hostLove.thread = host
  hostLove.timer.getTime = function()
    return clock.now
  end
  drive.restore = function()
    hostLove.thread = originalThread
    hostLove.timer.getTime = originalGetTime
  end

  -- One verified source keeps the pool able to produce the work the hydrated
  -- snapshot never captured.
  local info = GameVersion.info("heartgold")
  Assert.isTrue(
    service:offerSource(drive.epoch, assert(hostLove.data.newByteData("synthetic-snapshot-source")), {
      versionId = "heartgold",
      romSha1 = info.sha1,
    }),
    "the drive offers one verified source to the live epoch"
  )
  Assert.isTrue(service:requestBootSource(drive.epoch), "the live epoch queues its boot gate")
  service:update()
  withSnapshotCandidate(hydration, function()
    worker:step()
  end)
  service:update()
  Assert.equal(
    service:bootSourceStatus(drive.epoch),
    "ready",
    "the partial snapshot plus one verified source admits the boot"
  )

  ---@param delta number|nil seconds of drive time to pass
  function drive.wake(delta)
    if delta ~= nil then
      clock.now = clock.now + delta
    end
    worker:driveOnce(timer)
    service:update()
  end

  -- The installation sequence is per selection: a reselected epoch starts its
  -- own stream, so the drive measures the live epoch's commits only.
  ---@return integer highest committed installation sequence the game thread absorbed
  function drive.installedSequence()
    local committed = 0
    local epoch = drive.epoch
    local packets = packetsMatching(service._reply, function(candidate)
      return candidate.op == "cache-install-commit" and candidate.epoch == epoch
    end)
    for _, packet in ipairs(packets) do
      if type(packet.sequence) == "number" and packet.sequence > committed then
        committed = packet.sequence
      end
    end
    return committed
  end

  -- Answers the oldest unanswered dispatch on each pool worker with a
  -- successful in-memory artifact: one owned root and one payload per job, so
  -- a committed cut is checkable byte for byte.
  ---@return integer number of jobs answered
  function drive.answerDispatched()
    local answered = 0
    for workerId = 1, 64 do
      local channel = host.channels[3 + workerId]
      if channel == nil then
        break
      end
      local dispatches = packetsMatching(channel, function(candidate)
        return candidate.jobKey ~= nil and candidate.status == nil
      end)
      local previous = drive.answered[workerId] or 0
      if #dispatches > previous then
        local job = dispatches[previous + 1]
        drive.answered[workerId] = previous + 1
        local root = SNAPSHOT_PROBE_ROOT .. "/" .. tostring(job.jobKey):gsub("[^%w%-]", "-")
        local path = root .. "/output.bin"
        local bytes = "payload:" .. tostring(job.jobKey)
        drive.authoredPaths[path] = bytes
        host.channels[3]:push({
          status = "prepared",
          workerId = workerId,
          epoch = job.epoch,
          generationId = job.generationId,
          kind = job.kind,
          key = job.key,
          jobKey = job.jobKey,
          dispatchId = job.dispatchId,
          marker = root .. "-ready",
          ownedRoots = { root },
          sharedPaths = {},
          entries = {
            { path = path, data = assert(hostLove.data.newByteData(bytes)), size = #bytes },
          },
        })
        answered = answered + 1
      end
    end
    return answered
  end

  ---@param selector table<string, unknown> request selector
  function drive.request(selector)
    service:request(drive.epoch, selector)
  end

  -- Advances the drive until the installed sequence grows by the requested
  -- amount, answering every dispatch it meets.
  ---@param growth integer committed sequences to produce
  ---@param budget integer? drive rounds
  function drive.commit(growth, budget)
    local start = drive.installedSequence()
    for _ = 1, budget or 200 do
      if drive.installedSequence() >= start + growth then
        return
      end
      drive.wake(0.05)
      drive.answerDispatched()
    end
    Assert.isTrue(drive.installedSequence() >= start + growth, "the drive committed the work it was asked to produce")
  end

  ---@return table<string, unknown>? the background snapshot writer
  function drive.writer()
    for _, thread in ipairs(host.threads) do
      if type(thread.code) == "string" and thread.code:find("CacheArchive", 1, true) ~= nil then
        local args = thread.startArgs or {}
        return { thread = thread, control = args[1], reply = args[2] }
      end
    end
    return nil
  end

  ---@param writer table<string, unknown> observed writer
  ---@return table[] cuts handed to the writer
  function drive.cuts(writer)
    return packetsMatching(writer.control, function(packet)
      return type(packet.sequence) == "number" and type(packet.entries) == "table"
    end)
  end

  ---@return integer cuts handed to the writer that it has not answered yet
  function drive.outstanding()
    local writer = drive.writer()
    if writer == nil then
      return 0
    end
    local sent = #drive.cuts(writer)
    local acknowledged = 0
    for _, packet in ipairs(writer.reply.log) do
      if type(packet) == "table" and type(packet.sequence) == "number" then
        acknowledged = acknowledged + 1
      end
    end
    return sent - acknowledged
  end

  ---@param cut table<string, unknown> cut to acknowledge
  ---@param status string? acknowledgement status
  function drive.acknowledge(cut, status)
    local writer = assert(drive.writer(), "the drive has a background writer to answer")
    writer.reply:push({
      op = status or "snapshot-persisted",
      versionId = cut.versionId,
      generationId = cut.generationId,
      epoch = cut.epoch,
      sequence = cut.sequence,
    })
  end

  drive.close = function()
    drive.restore()
    service:shutdown()
    if worker.pool ~= nil then
      pcall(function()
        worker.pool:shutdown()
      end)
    end
  end
  return drive
end

function T.one_captured_snapshot_and_one_pending_indication_keep_persistence_honest()
  local archiveOk, archive = pcall(require, "romdump.src.build.CacheArchive")
  Assert.isTrue(
    archiveOk and archive ~= nil,
    "no background snapshot writer exists to capture one coalesced cut of the resident generated cache: "
      .. tostring(archive)
  )
  local coverage = { path = "data/generated/field/60/scene.lua", text = "return { mapId = 60 }\n" }
  local drive = snapshotDrive({ sequence = 4, coverage = coverage })
  local ok, err = pcall(function()
    drive.request({ requestKind = "milestone", name = "new-game-intro", urgency = "required" })
    drive.commit(3, 600)
    Assert.isTrue(
      drive.installedSequence() >= 7,
      "the drive committed work beyond the sequence it hydrated"
    )
    -- Settle every outstanding dispatch and completion fact before the capture
    -- is forced: what the cut must name is the state that exists then.
    local settled = -1
    for _ = 1, 200 do
      if drive.installedSequence() == settled and drive.outstanding() == 0 then
        break
      end
      settled = drive.installedSequence()
      drive.wake(0.05)
      drive.answerDispatched()
    end
    local committed = drive.installedSequence()
    for _ = 1, 8 do
      drive.wake(60)
    end
    local writer = drive.writer()
    Assert.notNil(
      writer,
      "the controller owns no background snapshot writer, so keeping playable bytes costs no persistence work"
    )
    local cuts = drive.cuts(writer)
    Assert.equal(#cuts, 1, "one dirty state yields exactly one captured snapshot")
    local cut = cuts[1]
    Assert.equal(cut.sequence, committed, "the captured cut names the latest committed sequence")
    Assert.equal(cut.epoch, drive.epoch, "the captured cut belongs to the live epoch")
    Assert.equal(cut.generationId, drive.identity.generationId, "the captured cut carries the selected generation")
    local captured = {}
    for _, entry in ipairs(cut.entries) do
      captured[entry.path] = entry
    end
    local authored = 0
    for path, expected in pairs(drive.authoredPaths) do
      authored = authored + 1
      local entry = assert(captured[path], "the cut carries every committed payload it covers: " .. path)
      Assert.equal(entry.data:getString(), expected, "the cut carries the committed bytes unchanged: " .. path)
    end
    Assert.isTrue(authored >= 3, "the cut covers the committed artifacts of its own sequence")
    Assert.equal(
      captured[coverage.path] and captured[coverage.path].data:getString(),
      coverage.text,
      "the cut keeps the bytes it hydrated unchanged"
    )
    Assert.equal(drive.outstanding(), 1, "exactly one captured snapshot is active")

    -- Work keeps committing while that cut is in flight: it becomes the one
    -- pending dirty indication, never a second captured snapshot.
    drive.request({ requestKind = "milestone", name = "field-planning", urgency = "required" })
    drive.commit(2, 600)
    local duringFlight = drive.installedSequence()
    Assert.isTrue(duringFlight > committed, "later work commits while the first cut is still active")
    for _ = 1, 8 do
      drive.wake(60)
    end
    Assert.equal(#drive.cuts(writer), 1, "an active captured snapshot is never joined by a second one")
    Assert.equal(drive.outstanding(), 1, "at most one captured snapshot exists at a time")

    drive.acknowledge(cut)
    drive.wake(0.05)
    for _ = 1, 8 do
      drive.wake(60)
    end
    cuts = drive.cuts(writer)
    Assert.equal(#cuts, 2, "the acknowledgment releases exactly one pending capture")
    local nextCut = cuts[2]
    Assert.isTrue(
      nextCut.sequence > cut.sequence,
      "acknowledging an earlier sequence never clears the work committed after it"
    )
    Assert.equal(nextCut.sequence, drive.installedSequence(), "the next cut carries the latest committed sequence")

    -- A retired generation's pending cut must settle before a later generation
    -- of the same version may capture, and its late acknowledgment must never
    -- stand in for that later generation's own sequence.
    drive.request({ requestKind = "milestone", name = "field-runtime", urgency = "required" })
    drive.commit(2, 600)
    for _ = 1, 8 do
      drive.wake(60)
    end
    cuts = drive.cuts(writer)
    local retiredCut = cuts[#cuts]
    Assert.equal(drive.outstanding(), 1, "the retired generation's cut is still active")
    local retiredEpoch = drive.epoch
    drive.service:retire(retiredEpoch)
    drive.wake(0.05)
    local nextEpoch = assert(drive.service:select({ versionId = "heartgold", development = false }))
    Assert.isTrue(nextEpoch > retiredEpoch, "the reselection mints a fresh epoch for the same version")
    drive.epoch = nextEpoch
    SnapshotBootFixture.install(drive.service, {
      epoch = nextEpoch,
      identity = drive.identity,
      sequence = 1,
      initial = true,
      entries = {},
      milestones = {},
      firstPlay = false,
      complete = false,
    })
    drive.wake(0.05)
    local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
    local GameVersion = require("romdump.src.source.GameVersion")
    local info = GameVersion.info("heartgold")
    Assert.isTrue(
      drive.service:offerSource(nextEpoch, assert(hostLove.data.newByteData("synthetic-snapshot-source-2")), {
        versionId = "heartgold",
        romSha1 = info.sha1,
      }),
      "the reselected epoch receives its own verified source"
    )
    Assert.isTrue(drive.service:requestBootSource(nextEpoch), "the reselected epoch queues its boot gate")
    drive.wake(0.05)
    drive.request({ requestKind = "milestone", name = "new-game-intro", urgency = "required" })
    local settledCuts = #drive.cuts(writer)
    drive.commit(2, 600)
    for _ = 1, 6 do
      drive.wake(60)
    end
    Assert.equal(
      #drive.cuts(writer),
      settledCuts,
      "a later same-version generation never captures while the earlier writer operation is unsettled"
    )
    drive.acknowledge(retiredCut)
    drive.wake(0.05)
    for _ = 1, 8 do
      drive.wake(60)
    end
    local released = drive.cuts(writer)
    Assert.isTrue(#released > settledCuts, "the settled earlier operation releases the later generation's capture")
    local freshCut = released[#released]
    Assert.equal(freshCut.epoch, nextEpoch, "the later generation's cut carries its own epoch")
    Assert.equal(
      freshCut.sequence,
      drive.installedSequence(),
      "the retired acknowledgment never stands in for the later generation's own sequence"
    )
  end)
  drive.close()
  if not ok then
    error(err, 0)
  end
end

return { metadata = { capabilities = {} }, tests = T }
