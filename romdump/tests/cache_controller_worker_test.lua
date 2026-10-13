-- Selected-session drive behavior without worker threads or a ROM: fake
-- channels, session, pool, and timer prove the controller waits on its
-- control channel when settled, polls on the live cadence while worker
-- results are outstanding, and pumps immediately runnable planning.

local Assert = require("tests.support.Assert")
local CacheControllerWorker = require("romdump.src.build.CacheControllerWorker")
local CacheEnvelope = require("tests.support.CacheEnvelope")
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
    Assert.isTrue(
      tostring(settled[index].errorMessage) ~= "",
      "a malformed key carries its cause"
    )
  end
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
  CacheEnvelope.attachHostCodecs(backend)
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:recoverPublication()
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
  Assert.isFalse(
    cache:exists("data/generated/storage-migrated.lua"),
    "quiescence writes no marker of its own"
  )
  Assert.equal(cache:read("mods/mymod/info.lua"), modLogical, "user mods stay byte-identical")
  Assert.equal(
    cache:read("staging/leftover/scratch.lua"),
    stageLogical,
    "staging debris is never entered"
  )
  Assert.equal(sibling:read("data/generated/maps/61.lua"), siblingLogical, "a sibling version is never entered")
  Assert.equal(cache:read("data/generated/maps/61.lua"), generated)
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

-- One composed boot drive through the real service and the real
-- controller: selection plus boot gate flush FIFO, the controller answers
-- exactly once, and the service absorbs the answer. Reports the observed
-- status, its detail, the number of external source opens, and whether a
-- source buffer stayed retained.
---@param backend table<string, unknown> isolated version-cache backend
---@return string? status
---@return table<string, unknown>? detail
---@return integer opens
---@return boolean held
local function driveBootGate(backend)
  local CacheService = require("app.src.CacheService")
  local RomSource = require("romdump.src.source.RomSource")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
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
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function(selected)
    assert(selected == "heartgold", "the boot drive stays on its version")
    return cacheFs
  end
  local opens = 0
  local realFromPath = RomSource.fromPath
  RomSource.fromPath = function(path, options)
    opens = opens + 1
    return realFromPath(path, options)
  end
  local realThread = hostLove.thread
  hostLove.thread = bootPoolThreadApi()
  local stepOk, stepErr = pcall(function()
    worker:step()
  end)
  hostLove.thread = realThread
  CacheFs.forVersion = realForVersion
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
  return status, detail, opens, held
end

-- A strictly current full-generation attestation boots with no source
-- work at all: no offer, no registered path, zero opens, zero retained
-- buffers. A stale-producer or malformed record instead reports that its
-- source is required without destroying anything.
function T.current_full_marker_boots_without_source_io()
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local GameVersion = require("romdump.src.source.GameVersion")
  local info = GameVersion.info("heartgold")
  local identity =
    DerivedCacheState.currentForSelection({ versionId = "heartgold", romSha1 = info.sha1, producerId = "r5" })
  local backend = FakeCache.new()
  DerivedCacheState.publish(CacheFs.forVersion("heartgold", backend), identity)
  local status, detail, opens, held = driveBootGate(backend)
  Assert.equal(status, "ready", "a strictly current full marker boots with no source")
  Assert.isNil(detail, "a fast boot carries no failure detail")
  Assert.equal(opens, 0, "a current full marker performs zero source opens")
  Assert.isFalse(held, "a fast boot retains no source buffer")
  local staleBackend = FakeCache.new()
  local stale = DerivedCacheState.currentForSelection(
    { versionId = "heartgold", romSha1 = info.sha1, producerId = "r6" }
  )
  DerivedCacheState.publish(CacheFs.forVersion("heartgold", staleBackend), stale)
  local staleStatus, staleDetail, staleOpens, _ = driveBootGate(staleBackend)
  Assert.equal(staleStatus, "source-required", "a stale full marker cannot skip the source")
  Assert.isTrue(type(staleDetail) == "table", "the missing source carries a typed cause")
  Assert.equal(staleDetail.code, "ROM_SOURCE_REQUIRED", "an unregistered source names its cause")
  Assert.equal(staleOpens, 0, "an unavailable source opens nothing")
  local damagedBackend = FakeCache.new()
  CacheFs.forVersion("heartgold", damagedBackend):write(DerivedCacheState.path, "this is not lua{{{")
  local damagedStatus, _, damagedOpens, __ = driveBootGate(damagedBackend)
  Assert.equal(damagedStatus, "source-required", "a malformed full marker cannot skip the source")
  Assert.equal(damagedOpens, 0, "a malformed marker opens nothing")
end

-- One composed boot drive with a mismatched source offer: selection
-- plus a wrong-identity offer flush FIFO, the controller visibly refuses
-- the offer, and the boot gate fails with its typed cause instead of
-- admitting gameplay on other grounds.
function T.rejected_offer_fails_the_boot_gate()
  local CacheService = require("app.src.CacheService")
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local backend = FakeCache.new()
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  local buffer = hostLove.data.newByteData("synthetic-offer-bytes")
  service:offerSource(epoch, buffer, { versionId = "heartgold", romSha1 = string.rep("1", 40) })
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
    worker:step()
  end)
  hostLove.thread = realThread
  CacheFs.forVersion = realForVersion
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
    worker:step()
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

-- A storage backend that explodes while the gate reads its attestation is
-- an infrastructure failure, never a source request.
function T.storage_backend_failure_reports_failed()
  local CacheService = require("app.src.CacheService")
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local realLoadLua = CacheFs.loadLua
  cacheFs.loadLua = function(self, path)
    if path == DerivedCacheState.path then
      error("synthetic backend explosion", 0)
    end
    return realLoadLua(self, path)
  end
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  service:update()
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function(selected)
    assert(selected == "heartgold", "the boot drive stays on its version")
    return cacheFs
  end
  local realThread = hostLove.thread
  hostLove.thread = bootPoolThreadApi()
  local stepOk, stepErr = pcall(function()
    worker:step()
  end)
  hostLove.thread = realThread
  CacheFs.forVersion = realForVersion
  assert(stepOk, stepErr)
  service:update()
  local status, _ = service:bootSourceStatus(epoch)
  Assert.equal(status, "failed", "a backend failure is infrastructure failure, not source-required")
  service:shutdown()
  pcall(function()
    if worker.pool ~= nil then
      worker.pool:shutdown()
    end
  end)
end

-- A boot check for a foreign epoch earns no reply and affects no state:
-- the gate answers its exact epoch only.
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

-- A failed full-marker write is non-destructive: the marker stays
-- absent, current assets survive, the boot hold stays pinned, and the
-- controller records its diagnostic instead of failing.
function T.failed_marker_write_keeps_hold_and_assets()
  local CacheService = require("app.src.CacheService")
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local backend = FakeCache.new()
  local service = assert(CacheService.new({ thread = bootServiceHost() }))
  local worker = CacheControllerWorker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  local buffer = hostLove.data.newByteData("synthetic-offer-bytes")
  local info = GameVersion.info("heartgold")
  service:offerSource(epoch, buffer, { versionId = "heartgold", romSha1 = info.sha1 })
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
    worker:step()
  end)
  hostLove.thread = realThread
  CacheFs.forVersion = realForVersion
  assert(stepOk, stepErr)
  service:update()
  local status, _ = service:bootSourceStatus(epoch)
  Assert.equal(status, "ready", "the offered buffer satisfies the boot gate")
  local pool = assert(worker.pool, "the selection owns its compiler pool")
  local held = pool.sharedSource
  Assert.isTrue(
    (type(held) == "table" and held.byteData or held) == buffer,
    "the preflight pins the identical offered buffer"
  )
  -- Swap in a terminally successful sweep observation over a cache whose
  -- marker writes explode, keeping one pre-existing asset beside it.
  local faultBackend = FakeCache.new()
  local faultFs = CacheFs.forVersion("heartgold", faultBackend)
  faultFs:write("data/generated/maps/61.lua", "current bytes")
  faultFs.writeLua = function()
    error("synthetic marker fault", 0)
  end
  local releases = 0
  local realRelease = pool.releaseBootSourceHold
  pool.releaseBootSourceHold = function(self, releaseEpoch)
    releases = releases + 1
    return realRelease(self, releaseEpoch)
  end
  local generationId = assert(worker.selectedIdentity, "the selection owns its identity").generationId
  worker.session = {
    generationId = generationId,
    cacheFs = faultFs,
  }
  function worker.session:update() end
  function worker.session:status()
    return {
      sweepState = "exhausted",
      sweepFailure = nil,
      bootstrap = "ready",
      failed = 0,
      queued = 0,
      running = 0,
      complete = false,
    }
  end
  local attestOk, attestErr = pcall(function()
    worker:step()
  end)
  assert(attestOk, attestErr)
  Assert.isNil(
    CacheFs.forVersion("heartgold", faultBackend):loadLua(DerivedCacheState.path),
    "a failed write leaves no full-generation marker"
  )
  Assert.equal(
    faultBackend:read("heartgold/data/generated/maps/61.lua"),
    "current bytes",
    "a failed write never deletes current assets"
  )
  Assert.equal(releases, 0, "a failed write never releases the boot hold")
  local stillHeld = pool.sharedSource
  Assert.isTrue(
    (type(stillHeld) == "table" and stillHeld.byteData or stillHeld) == buffer,
    "the buffer stays pinned across the failed write"
  )
  Assert.notNil(worker.attestationNote, "the failed write records its diagnostic")
  service:shutdown()
  pcall(function()
    pool:shutdown()
  end)
end

-- Composed boot-cleanup coverage: the two scenarios below drive the real
-- boot-source gate against a real versioned filesystem backed by FakeCache,
-- with synthetic roster plans standing in for the inventoried source
-- membership. They pin the ordinary-lifecycle cleanup contract: a clean
-- complete boot reclaims only proven orphans and memoizes the pass, while
-- uncertain proof deletes nothing and leaves no memo.

local CLEANUP_MEMO_PATH = "data/generated/retention.lua"
local CLEANUP_PRODUCER = "r5"
local ACTIVE_SCRIPT_GENERATION = string.rep("a", 40)
local OBSOLETE_SCRIPT_GENERATION = string.rep("b", 40)
local ACTIVE_SCRIPT_MARKER = "script-format:marker-current"

local function cleanupIdentity()
  local GameVersion = require("romdump.src.source.GameVersion")
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local info = GameVersion.info("heartgold")
  return DerivedCacheState.currentForSelection({
    versionId = "heartgold",
    romSha1 = info.sha1,
    producerId = CLEANUP_PRODUCER,
  })
end

local function syntheticRosterPlans()
  return {
    messageBankIds = { 7 },
    audioBankIds = { 3 },
    scriptMemberIds = { 11 },
    iconPageIds = { 1 },
    portraitPageIds = { 1 },
    mapDataIds = { 9 },
    mapIds = { 3 },
    indexBundle = { index = { matrices = { { cells = { { matrixMemberId = 5, index = 2 } } } } } },
  }
end

local function publishSharedReceipt(cache, generation, kind, key)
  local ArtifactState = require("romdump.src.build.ArtifactState")
  cache:writeLua(ArtifactState.path(kind, key), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = kind,
    key = key,
    marker = "complete",
  })
end

local function sharedSidecarPath(kind, key)
  return "data/generated/jobs-shared/" .. kind .. "/" .. key .. ".lua"
end

local function publishSharedSidecar(cache, generation, kind, key, paths)
  local sorted = {}
  for _, path in ipairs(paths or {}) do
    sorted[#sorted + 1] = path
  end
  table.sort(sorted)
  cache:writeLua(sharedSidecarPath(kind, key), {
    schema = 1,
    generationId = generation,
    kind = kind,
    key = key,
    paths = sorted,
  })
end

local function setupProvenSharedFiles(cache, generation, plans)
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  local roster = {}
  local iterate = ArtifactJobs.completeIterator(plans)
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    roster[#roster + 1] = job
  end
  Assert.isTrue(#roster > 10, "the synthetic roster must span several job families")
  local meshRef = MapAssetCache.geometryPath(string.rep("a", 40))
  local sampleRef = AudioCache.samplePath("bank003_kick")
  local meshOrphan = MapAssetCache.geometryPath(string.rep("b", 40))
  local metaOrphan = AudioCache.sampleMetadataPath("bank009_stale")
  for _, job in ipairs(roster) do
    publishSharedReceipt(cache, generation, job.kind, job.key)
    publishSharedSidecar(cache, generation, job.kind, job.key, {})
  end
  publishSharedSidecar(cache, generation, "map", "3", { meshRef })
  publishSharedSidecar(cache, generation, "map-data", "9", { meshRef })
  publishSharedSidecar(cache, generation, "audio-bank", "3", { sampleRef })
  cache:write(meshRef, string.rep("mesh-block;", 200))
  cache:write(sampleRef, string.rep("pcm-frame;", 200))
  cache:write(meshOrphan, string.rep("orphan-mesh;", 200))
  cache:write(metaOrphan, "return { stale = true }\n")
  return {
    meshRef = meshRef,
    sampleRef = sampleRef,
    meshOrphan = meshOrphan,
    metaOrphan = metaOrphan,
  }
end

local function setupScriptGenerations(cache, generation)
  local ScriptCache = require("libs.assets.src.ScriptCache")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  cache:write(ScriptCache.markerPath(), ACTIVE_SCRIPT_MARKER)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = ACTIVE_SCRIPT_GENERATION,
    marker = ACTIVE_SCRIPT_MARKER,
  })
  cache:writeLua(ScriptCache.generationIndexPath(ACTIVE_SCRIPT_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = ACTIVE_SCRIPT_GENERATION,
    marker = ACTIVE_SCRIPT_MARKER,
  })
  cache:write(ScriptCache.generationMarkerPath(ACTIVE_SCRIPT_GENERATION), ACTIVE_SCRIPT_MARKER)
  cache:write(ScriptCache.generationDir(ACTIVE_SCRIPT_GENERATION) .. "/sentinel", "active payload")
  cache:write(ScriptCache.generationDir(OBSOLETE_SCRIPT_GENERATION) .. "/stale", "superseded payload")
  cache:write(ScriptCache.generationsDir() .. "/README.txt", "operator note")
  cache:createDirectory(ScriptCache.generationsDir() .. "/Stray-Notes")
  cache:write(ScriptCache.generationsDir() .. "/Stray-Notes/keep.txt", "operator note")
  cache:write("mods/mymod/info.lua", "return { name = 'kept' }\n")
  cache:writeLua(ArtifactState.path("script-summary", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "script-summary",
    key = "global",
    marker = "complete",
  })
end

local function setupCompleteBootCache()
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:recoverPublication()
  local identity = cleanupIdentity()
  DerivedCacheState.publish(cache, identity)
  local plans = syntheticRosterPlans()
  local shared = setupProvenSharedFiles(cache, identity.generationId, plans)
  setupScriptGenerations(cache, identity.generationId)
  return { backend = backend, cache = cache, identity = identity, plans = plans, shared = shared }
end

-- One composed boot drive: a fresh controller with a stub source pool
-- answers exactly one boot-source check against the given version cache.
local function driveBootCheck(cache, identity, pool)
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
  local session = { cacheFs = cache }
  function session:update() end
  worker.session = session
  worker.pool = pool
  worker.selectedIdentity = identity
  worker.liveEpoch = 7
  worker.lifecycle = "active"
  queued[#queued + 1] = { op = "check-boot-source", epoch = 7 }
  worker:step()
  for _, packet in ipairs(replies) do
    if type(packet) == "table" and packet.op == "boot-source-result" then
      return packet
    end
  end
  error("the boot gate answered nothing", 0)
end

-- A source pool with no registered source: anything but the complete
-- fast path reports its typed cause instead of admitting the boot.
local function sourcelessPool()
  local pool = { calls = {} }
  function pool:prepareBootSource(epoch, needsSource)
    pool.calls[#pool.calls + 1] = needsSource
    if needsSource then
      return false,
        { code = "ROM_SOURCE_REQUIRED", message = "the original source is unavailable", context = {} }
    end
    return true
  end
  return pool
end

-- The inventoried source membership is synthetic here: the roster owner
-- answers the fixed synthetic plans while the receipts, sidecars, and
-- every deleted byte stay on the real versioned filesystem.
local function withSyntheticRoster(plans, fn)
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local real = ArtifactJobs.publishedPlans
  ArtifactJobs.publishedPlans = function()
    return plans
  end
  local ok, err = pcall(fn)
  ArtifactJobs.publishedPlans = real
  if not ok then
    error(err, 0)
  end
end

-- A clean complete boot needs no second import and no source access to
-- reclaim proven orphans: the first boot deletes only the unreferenced
-- shared files, keeps every referenced output and user path, and leaves
-- a per-generation memo so the next clean boot answers without any
-- roster or directory scan. A first-play-only generation instead holds
-- its source gate and deletes nothing.
function T.clean_complete_boot_reclaims_only_proven_shared_orphans_and_memoizes_the_pass()
  local setup = setupCompleteBootCache()
  local pool = sourcelessPool()
  local answer
  withSyntheticRoster(setup.plans, function()
    answer = driveBootCheck(setup.cache, setup.identity, pool)
  end)
  Assert.equal(answer.state, "ready", "a complete cache boots without its source")
  Assert.isFalse(
    setup.cache:exists(setup.shared.meshOrphan),
    "a clean complete boot must reclaim proven orphans, but the boot fast path performs no cleanup"
  )
  Assert.isFalse(setup.cache:exists(setup.shared.metaOrphan), "a clean complete boot reclaims every proven orphan")
  Assert.equal(setup.cache:read(setup.shared.meshRef), string.rep("mesh-block;", 200))
  Assert.equal(setup.cache:read(setup.shared.sampleRef), string.rep("pcm-frame;", 200))
  Assert.deepEqual(
    setup.cache:loadLua(CLEANUP_MEMO_PATH),
    { schema = 1, generationId = setup.identity.generationId }
  )

  local listings = 0
  local realItems = setup.backend.getDirectoryItems
  setup.backend.getDirectoryItems = function(self, path)
    listings = listings + 1
    return realItems(self, path)
  end
  local second
  withSyntheticRoster(setup.plans, function()
    second = driveBootCheck(setup.cache, setup.identity, sourcelessPool())
  end)
  setup.backend.getDirectoryItems = realItems
  Assert.equal(second.state, "ready", "the memoized generation still boots without its source")
  Assert.equal(listings, 0, "a memoized pass performs no roster or directory scans")

  local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")
  local incomplete = CacheFs.forVersion("heartgold", FakeCache.new())
  incomplete:recoverPublication()
  local identity = cleanupIdentity()
  FirstPlayCompletion.publish("heartgold", identity.generationId, incomplete)
  local plans = syntheticRosterPlans()
  local shared = setupProvenSharedFiles(incomplete, identity.generationId, plans)
  local scarce = sourcelessPool()
  local blocked
  withSyntheticRoster(plans, function()
    blocked = driveBootCheck(incomplete, identity, scarce)
  end)
  Assert.equal(blocked.state, "source-required", "a first-play-only cache still requires its source")
  Assert.equal(#scarce.calls, 1, "the incomplete boot consults the source exactly once")
  Assert.isTrue(scarce.calls[1], "the incomplete boot asks the pool to pin its source")
  Assert.isTrue(incomplete:exists(shared.meshOrphan), "an incomplete boot deletes no shared file")
  Assert.isTrue(incomplete:exists(shared.metaOrphan), "an incomplete boot deletes no shared file")
  Assert.isNil(incomplete:loadLua(CLEANUP_MEMO_PATH), "an incomplete boot leaves no cleanup memo")
end

-- Old script generations retire only under independent current proof:
-- the active tree stays valid while the obsolete proven tree goes, and
-- unknown or user paths survive. Missing script proof retires nothing
-- and leaves no memo; missing shared proof still deletes no shared file
-- and leaves no memo even while the proven script tree retires; and an
-- interrupted pass converges on retry without touching live data.
function T.obsolete_script_generations_retire_only_with_independent_current_proof()
  local ScriptCache = require("libs.assets.src.ScriptCache")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local obsoleteSentinel = ScriptCache.generationDir(OBSOLETE_SCRIPT_GENERATION) .. "/stale"
  local activeSentinel = ScriptCache.generationDir(ACTIVE_SCRIPT_GENERATION) .. "/sentinel"

  local setup = setupCompleteBootCache()
  local answer
  withSyntheticRoster(setup.plans, function()
    answer = driveBootCheck(setup.cache, setup.identity, sourcelessPool())
  end)
  Assert.equal(answer.state, "ready", "a complete cache boots without its source")
  Assert.isFalse(
    setup.cache:exists(obsoleteSentinel),
    "a complete boot must retire the obsolete script generation, but no script retirement runs"
  )
  Assert.equal(setup.cache:read(activeSentinel), "active payload", "the active script tree stays readable")
  local active, activeErr = ScriptCache.loadActive(setup.cache)
  Assert.notNil(active, "the active script selection stays valid: " .. tostring(activeErr))
  Assert.equal(active.generation, ACTIVE_SCRIPT_GENERATION, "the active script selection still names its generation")
  Assert.equal(
    setup.cache:read(ScriptCache.generationsDir() .. "/README.txt"),
    "operator note",
    "unknown names are preserved, not scavenged"
  )
  Assert.isTrue(
    setup.cache:exists(ScriptCache.generationsDir() .. "/Stray-Notes/keep.txt"),
    "unknown directories survive"
  )
  Assert.equal(setup.cache:read("mods/mymod/info.lua"), "return { name = 'kept' }\n", "user mods stay byte-identical")
  Assert.deepEqual(
    setup.cache:loadLua(CLEANUP_MEMO_PATH),
    { schema = 1, generationId = setup.identity.generationId }
  )

  local unstamped = setupCompleteBootCache()
  unstamped.cache:remove(ArtifactState.path("script-summary", "global"))
  local refused
  withSyntheticRoster(unstamped.plans, function()
    refused = driveBootCheck(unstamped.cache, unstamped.identity, sourcelessPool())
  end)
  Assert.equal(refused.state, "ready", "uncertain script proof never blocks a playable cache")
  Assert.isTrue(
    unstamped.cache:exists(ScriptCache.generationDir(OBSOLETE_SCRIPT_GENERATION) .. "/stale"),
    "missing script proof retires no script tree"
  )
  Assert.isNil(unstamped.cache:loadLua(CLEANUP_MEMO_PATH), "missing script proof leaves no cleanup memo")

  local unproven = setupCompleteBootCache()
  unproven.cache:remove(sharedSidecarPath("map", "3"))
  local partial
  withSyntheticRoster(unproven.plans, function()
    partial = driveBootCheck(unproven.cache, unproven.identity, sourcelessPool())
  end)
  Assert.equal(partial.state, "ready", "uncertain shared proof never blocks a playable cache")
  Assert.isTrue(unproven.cache:exists(unproven.shared.meshOrphan), "missing shared proof deletes no shared file")
  Assert.isTrue(unproven.cache:exists(unproven.shared.metaOrphan), "missing shared proof deletes no shared file")
  Assert.isFalse(
    unproven.cache:exists(ScriptCache.generationDir(OBSOLETE_SCRIPT_GENERATION) .. "/stale"),
    "independent script proof still retires the obsolete generation"
  )
  Assert.isNil(unproven.cache:loadLua(CLEANUP_MEMO_PATH), "a partial pass leaves no cleanup memo")

  local flaky = setupCompleteBootCache()
  local fullOrphan = "heartgold/" .. flaky.shared.meshOrphan
  local realRemove = flaky.backend.remove
  flaky.backend.remove = function(self, path)
    if path == fullOrphan then
      return false, "injected cleanup delete failure"
    end
    return realRemove(self, path)
  end
  local survived
  withSyntheticRoster(flaky.plans, function()
    survived = driveBootCheck(flaky.cache, flaky.identity, sourcelessPool())
  end)
  flaky.backend.remove = realRemove
  Assert.equal(survived.state, "ready", "a cleanup fault never blocks a playable cache")
  Assert.isNil(flaky.cache:loadLua(CLEANUP_MEMO_PATH), "an interrupted pass leaves no cleanup memo")
  Assert.equal(flaky.cache:read(flaky.shared.meshRef), string.rep("mesh-block;", 200))
  Assert.equal(flaky.cache:read(activeSentinel), "active payload")
  local retry
  withSyntheticRoster(flaky.plans, function()
    retry = driveBootCheck(flaky.cache, flaky.identity, sourcelessPool())
  end)
  Assert.equal(retry.state, "ready", "the retry still boots without its source")
  Assert.isFalse(flaky.cache:exists(flaky.shared.meshOrphan), "the retry converges once the fault clears")
  Assert.isFalse(flaky.cache:exists(flaky.shared.metaOrphan), "the retry converges once the fault clears")
  Assert.isFalse(
    flaky.cache:exists(ScriptCache.generationDir(OBSOLETE_SCRIPT_GENERATION) .. "/stale"),
    "the retry converges on script retirement"
  )
  Assert.deepEqual(
    flaky.cache:loadLua(CLEANUP_MEMO_PATH),
    { schema = 1, generationId = flaky.identity.generationId }
  )
end

return { metadata = { capabilities = {} }, tests = T }
