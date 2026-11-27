-- Lifecycle/state-machine coverage for the presentation preparation queue:
-- one-worker dispatch, demand-before-prefetch priority, cancellation of
-- queued and running work, failure recovery, and idempotent release. Every
-- test injects a deterministic fake love.thread (Thread/Channel mechanics)
-- so no real OS thread is started here; one focused real-worker test lives
-- in the graphics layer.

local Assert = require("tests.support.Assert")

local T = {}

local function requireQueue()
  local ok, AssetPreparationQueue = pcall(require, "libs.hgss.src.presentation.AssetPreparationQueue")
  Assert.isTrue(ok, "the production asset preparation queue boundary is missing: " .. tostring(AssetPreparationQueue))
  return AssetPreparationQueue --[[@as table]]
end

-- The selected decoded CPU owner every queue requires: one shared kernel with a
-- generous idle budget, so a repeated request inside one test resolves as a
-- resident identity. A test that asserts charges builds and inspects its own.
local function newQueue(cacheFs, options)
  local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
  options = options or {}
  options.decoded = ResidentAssetCache.new({
    idleByteLimit = 32 * 1024 * 1024,
    release = function(value)
      if type(value.release) == "function" then
        value:release()
      end
    end,
  })
  return requireQueue().new(cacheFs, options)
end

local function fakeCacheFs()
  local references = {}
  return {
    -- The selected epoch's resident reader: the version identity travels with
    -- the dispatched job, and one immutable payload reference is what the
    -- worker receives.
    versionId = "heartgold",
    resolveAsset = function(_, relativePath)
      local reference = references[relativePath]
      if reference == nil then
        reference = {
          path = relativePath,
          sourceId = "base:test-generation",
          contentId = "test-generation\0" .. relativePath,
          size = 0,
          data = {
            path = relativePath,
            getString = function()
              return "resident:" .. relativePath
            end,
          },
        }
        references[relativePath] = reference
      end
      return reference
    end,
  }
end

-- A deterministic fake love.thread: newChannel/newThread record every push,
-- every construction source, and every start/wait call, but never execute
-- worker code. Tests drive "worker completion" explicitly by pushing a
-- response record and then calling a queue method that is documented to
-- drain replies (poll/wait); thread:stop(message) models an unexpected
-- worker exit whose cause is visible through getError.
local function fakeThreadHost()
  local state = { channels = {}, allPushes = {}, threads = {}, threadSources = {} }

  local function newChannel()
    local values = {}
    local channel = { onDemand = nil }
    function channel:push(value)
      values[#values + 1] = value
      state.allPushes[#state.allPushes + 1] = { channel = channel, value = value }
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    -- Mirrors love.thread Channel:demand(timeout): an omitted timeout stays
    -- a nonblocking pop so existing tests run without delay, while a
    -- test-local onDemand hook can observe the timeout and model a blocking
    -- interval deterministically (for example worker death mid-wait).
    function channel:demand(timeout)
      if channel.onDemand ~= nil then
        return channel.onDemand(timeout)
      end
      return self:pop()
    end
    function channel:getCount()
      return #values
    end
    state.channels[#state.channels + 1] = channel
    return channel
  end

  local function newThread(source)
    state.threadSources[#state.threadSources + 1] = source
    local thread = { starts = 0, waits = 0, alive = true, errorText = nil, source = source, startArgs = {} }
    function thread:start(...)
      self.starts = self.starts + 1
      self.startArgs[#self.startArgs + 1] = { ... }
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return self.errorText
    end
    function thread:isRunning()
      return self.alive and self.starts > 0 and self.waits == 0
    end
    function thread:stop(message)
      self.alive = false
      self.errorText = message
    end
    state.threads[#state.threads + 1] = thread
    return thread
  end

  state.love = {
    thread = { newChannel = newChannel, newThread = newThread },
  }
  return state
end

local function withLove(fakeLove, fn)
  local previous = rawget(_G, "love")
  rawset(_G, "love", fakeLove)
  local ok, result = pcall(fn)
  rawset(_G, "love", previous)
  if not ok then
    error(result, 0)
  end
  return result
end

-- Finds the channel that carried the outgoing request record for `token`
-- (identified by the flat request shape: token + kind + path), without
-- assuming channel construction order.
local function requestChannelIndexFor(state, token)
  for _, entry in ipairs(state.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.token == token and value.path ~= nil and value.kind ~= nil then
      for index, channel in ipairs(state.channels) do
        if channel == entry.channel then
          return index
        end
      end
    end
  end
  return nil
end

local function requestWasPushedFor(state, token)
  return requestChannelIndexFor(state, token) ~= nil
end

-- How many physical worker requests carried `token` (identified by the flat
-- request shape). Promotion must change a token's priority without
-- dispatching it a second time.
local function pushCountFor(state, token)
  local count = 0
  for _, entry in ipairs(state.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.token == token and value.path ~= nil and value.kind ~= nil then
      count = count + 1
    end
  end
  return count
end

-- Every worker of one queue reports on the one shared reply channel it was
-- started with, whatever the number of request channels.
local function responseChannelFor(state, _)
  local thread = assert(state.threads[1], "no presentation worker was started")
  local startArgs = assert(thread.startArgs[1], "the presentation worker never started")
  return assert(startArgs[2], "the presentation worker starts with its shared reply channel")
end

-- Owned upload buffers in the shape a completion publishes: a measurable size
-- and one release.
local function ownedBuffer(bytes)
  return {
    released = 0,
    attached = bytes,
    getSize = function(self)
      return #self.attached
    end,
    release = function(self)
      self.released = self.released + 1
    end,
  }
end

local function meshResponse(token, path)
  return {
    token = token,
    ok = true,
    kind = "mesh",
    path = path,
    vertexData = ownedBuffer(string.rep("\0", 120)),
    indexData = ownedBuffer(string.rep("\0", 6)),
    vertexCount = 3,
    indexCount = 3,
    indexType = "uint16",
    centerX = 0,
    centerY = 0,
    centerZ = 0,
  }
end

local function imageDerivativeResponse(token, path)
  return {
    token = token,
    ok = true,
    kind = "image-derivative",
    path = path,
    pixelHash = "test-hash",
    width = 1,
    height = 1,
    representation = "indexed",
    colors = 1,
    indexData = ownedBuffer("\0"),
    paletteData = ownedBuffer("\0"),
  }
end

local function failureResponse(token, kind, path)
  return { token = token, ok = false, kind = kind, path = path, error = "injected worker failure" }
end

function T.one_time_take_and_unknown_token_fail_loudly()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local token = queue:request("mesh", "geometry/a.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "an idle worker dispatches the only queued request")

    local requestIndex = requestChannelIndexFor(host, token)
    responseChannelFor(host, requestIndex):push(meshResponse(token, "geometry/a.g4mesh"))

    Assert.equal(queue:poll(token), "ready")
    local prepared = assert(queue:take(token)).value.payload
    Assert.notNil(prepared, "take transfers the prepared payload")
    Assert.throws(function()
      queue:take(token)
    end, "take is valid only once per ready token")
    Assert.throws(function()
      queue:poll(token)
    end, "an already-transferred token cannot be polled again")

    Assert.throws(function()
      queue:poll("never-requested")
    end, "polling an unknown token fails loudly")
    Assert.throws(function()
      queue:take("never-requested")
    end, "taking an unknown token fails loudly")
    Assert.throws(function()
      queue:cancel("never-requested")
    end, "cancelling an unknown token fails loudly")

    queue:release()
  end)
end

function T.cancelled_ready_payload_never_transfers_but_leaves_unrelated_work_alone()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local first = queue:request("mesh", "geometry/first.g4mesh", "demand")
    local requestIndex = requestChannelIndexFor(host, first)
    responseChannelFor(host, requestIndex):push(meshResponse(first, "geometry/first.g4mesh"))
    Assert.equal(queue:poll(first), "ready")

    -- A ready token cancelled before take releases its references without
    -- affecting unrelated resources: the payload never transfers.
    queue:cancel(first)
    Assert.throws(function()
      queue:take(first)
    end, "a cancelled ready token cannot be taken")

    local second = queue:request("mesh", "geometry/second.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, second), "unrelated work still dispatches after a ready cancellation")
    local secondIndex = requestChannelIndexFor(host, second)
    responseChannelFor(host, secondIndex):push(meshResponse(second, "geometry/second.g4mesh"))
    Assert.equal(queue:poll(second), "ready")
    Assert.notNil(queue:take(second), "the unrelated payload still transfers exactly once")
    queue:release()
  end)
end

function T.demand_dispatches_before_queued_prefetch_without_preempting_running_work()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())

    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")

    local queuedPrefetch = queue:request("mesh", "geometry/prefetch.g4mesh", "prefetch")
    local queuedDemand = queue:request("mesh", "geometry/demand.g4mesh", "demand")
    Assert.isFalse(requestWasPushedFor(host, queuedPrefetch), "queued work waits for the busy worker")
    Assert.isFalse(requestWasPushedFor(host, queuedDemand), "queued work waits for the busy worker")

    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(running), "ready")

    Assert.isTrue(requestWasPushedFor(host, queuedDemand), "demand dispatches as soon as the worker is idle")
    Assert.isFalse(requestWasPushedFor(host, queuedPrefetch), "demand outranks queued prefetch at dispatch time")

    queue:take(running)
    queue:cancel(queuedDemand)
    queue:cancel(queuedPrefetch)
    queue:release()
  end)
end

function T.queued_cancellation_never_reaches_the_worker()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    local queued = queue:request("mesh", "geometry/queued.g4mesh", "prefetch")

    queue:cancel(queued)

    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(running), "ready")
    queue:take(running)

    Assert.isFalse(requestWasPushedFor(host, queued), "a cancelled queued token is dropped, never dispatched")
    Assert.throws(function()
      queue:take(queued)
    end, "a cancelled token cannot be taken")

    queue:release()
  end)
end

function T.running_cancellation_discards_the_late_result()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running))

    queue:cancel(running)

    -- Logical cancellation frees no physical slot: a fresh request queues
    -- behind the still-executing job instead of dispatching immediately.
    local next = queue:request("mesh", "geometry/next.g4mesh", "demand")
    Assert.isFalse(
      requestWasPushedFor(host, next),
      "a fresh request waits while the cancelled job still occupies the worker"
    )

    -- The worker's job was already in flight and is not preempted; its late
    -- result must still be discarded rather than published/taken, and only
    -- then does the queued work dispatch.
    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))

    Assert.throws(function()
      queue:take(running)
    end, "a cancelled running token's late result cannot be taken")
    Assert.equal(queue:poll(next), "pending")
    Assert.isTrue(
      requestWasPushedFor(host, next),
      "the queued request dispatches after the late reply frees the worker"
    )

    local nextIndex = requestChannelIndexFor(host, next)
    responseChannelFor(host, nextIndex):push(meshResponse(next, "geometry/next.g4mesh"))
    Assert.equal(queue:poll(next), "ready")
    queue:take(next)
    queue:release()
  end)
end

function T.worker_failure_does_not_wedge_subsequent_requests()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local failing = queue:request("mesh", "geometry/broken.g4mesh", "demand")
    local requestIndex = requestChannelIndexFor(host, failing)
    responseChannelFor(host, requestIndex):push(failureResponse(failing, "mesh", "geometry/broken.g4mesh"))

    Assert.equal(queue:poll(failing), "failed")
    Assert.throws(function()
      queue:take(failing)
    end, "a failed token never yields a payload")

    local next = queue:request("mesh", "geometry/recovered.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, next), "the next request runs after an observed worker failure")
    local nextRequestIndex = requestChannelIndexFor(host, next)
    responseChannelFor(host, nextRequestIndex):push(meshResponse(next, "geometry/recovered.g4mesh"))
    Assert.equal(queue:poll(next), "ready")
    queue:take(next)
    queue:release()
  end)
end

-- A queue that never dispatched owns no worker: compact source acquisition and
-- an unused selection must not depend on a thread host at all.
function T.release_before_first_dispatch_creates_no_worker()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    queue:release()
    queue:release()
    Assert.equal(#host.threads, 0, "a queue released before its first dispatch creates no worker")
    Assert.equal(#host.channels, 0, "no channel pair exists without a worker")
  end)
end

-- Once dispatched, one persistent worker is owned for the queue lifetime and
-- released exactly once.
function T.release_while_idle_joins_the_worker_and_is_idempotent()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local token = queue:request("mesh", "geometry/idle.g4mesh", "demand")
    local requestIndex = requestChannelIndexFor(host, token)
    responseChannelFor(host, requestIndex):push(meshResponse(token, "geometry/idle.g4mesh"))
    Assert.equal(queue:poll(token), "ready")
    queue:release()
    queue:release()
    Assert.equal(#host.threads, 1, "one persistent worker is owned for the queue lifetime")
    Assert.equal(host.threads[1].waits, 1, "release joins the worker exactly once even if called twice")
  end)
end

function T.release_while_busy_signals_stop_and_joins_the_worker()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running))
    queue:release()
    queue:release()
    Assert.equal(host.threads[1].waits, 1, "quit joins the worker before releasing owners")
    local shutdownSeen = false
    for _, pushed in ipairs(host.allPushes) do
      if type(pushed.value) == "table" and pushed.value.op == "shutdown" then
        shutdownSeen = true
      end
    end
    Assert.isTrue(shutdownSeen, "release still asks the worker to stop")
    Assert.throws(function()
      queue:poll(running)
    end, "a released queue discards outstanding tokens rather than reviving them")
  end)
end

function T.release_while_busy_drains_and_discards_outstanding_work()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running))

    queue:release()

    Assert.equal(host.threads[1].waits, 1, "disposal joins the worker after outstanding work returns")
    Assert.throws(function()
      queue:poll(running)
    end, "a released queue discards outstanding tokens rather than reviving them")
  end)
end

function T.default_construction_starts_the_worker_from_a_literal_require_bootstrap()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs(), { thread = host.love.thread })
    Assert.equal(#host.threads, 0, "constructing the queue starts no worker")
    Assert.equal(#host.channels, 0, "constructing the queue creates no channel pair")
    local token = queue:request("mesh", "geometry/bootstrap.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "the first dispatch starts the worker")
    local source = host.threadSources[1]
    Assert.equal(type(source), "string", "the worker starts from a literal bootstrap string")
    Assert.isTrue(
      source:find("asset_preparation_worker", 1, true) ~= nil,
      "the bootstrap requires the worker module through the packaged path"
    )
    Assert.isTrue(source:find(".run(", 1, true) ~= nil, "the bootstrap enters the worker through its channel entry")
    Assert.isNil(source:find("io.open", 1, true), "the bootstrap never reads checkout files")
    local startArgs = assert(host.threads[1].startArgs[1], "the worker start carries its channel arguments")
    Assert.isTrue(
      startArgs[1] == host.channels[1] and startArgs[2] == host.channels[2],
      "the worker starts with the queue request/reply channel pair"
    )
    Assert.equal(type(startArgs[3]), "string", "the worker start carries the module search path context")
    Assert.isTrue(#startArgs[3] > 0, "the search path context is non-empty")
    queue:release()
  end)
end

function T.cancelled_running_work_keeps_the_physical_slot_until_its_reply()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local runningPrefetch = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, runningPrefetch), "the idle worker takes the first request immediately")
    local queuedPrefetch = queue:request("mesh", "geometry/queued.g4mesh", "prefetch")

    queue:cancel(runningPrefetch)

    local lateDemand = queue:request("mesh", "geometry/late.g4mesh", "demand")
    Assert.isFalse(
      requestWasPushedFor(host, queuedPrefetch),
      "no replacement work starts while the cancelled job still occupies the worker"
    )
    Assert.isFalse(
      requestWasPushedFor(host, lateDemand),
      "no replacement work starts while the cancelled job still occupies the worker"
    )

    local requestIndex = requestChannelIndexFor(host, runningPrefetch)
    responseChannelFor(host, requestIndex):push(meshResponse(runningPrefetch, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(lateDemand), "pending")
    Assert.isTrue(requestWasPushedFor(host, lateDemand), "the late demand wins the next physical dispatch")
    Assert.isFalse(
      requestWasPushedFor(host, queuedPrefetch),
      "the queued prefetch still waits while demand occupies the worker"
    )

    local demandIndex = requestChannelIndexFor(host, lateDemand)
    responseChannelFor(host, demandIndex):push(meshResponse(lateDemand, "geometry/late.g4mesh"))
    Assert.equal(queue:poll(queuedPrefetch), "pending")
    Assert.isTrue(requestWasPushedFor(host, queuedPrefetch), "the queued prefetch dispatches after demand completes")

    queue:take(lateDemand)
    queue:cancel(queuedPrefetch)
    queue:release()
  end)
end

function T.stopped_worker_fails_pending_and_future_requests()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local token = queue:request("mesh", "geometry/stalled.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "the idle worker takes the request immediately")

    local pushesBefore = #host.allPushes
    host.threads[1]:stop("injected worker crash")

    local tokenState, failure = queue:poll(token)
    Assert.equal(tokenState, "failed", "a token cannot stay pending after its only worker stopped")
    Assert.isTrue(
      type(failure) == "string" and failure:find("injected worker crash", 1, true) ~= nil,
      "the pending token reports the worker-stop cause: " .. tostring(failure)
    )

    local requestOk, requestResult = pcall(function()
      return queue:request("mesh", "geometry/after.g4mesh", "demand")
    end)
    if requestOk then
      local nextState, nextFailure = queue:poll(requestResult)
      Assert.equal(nextState, "failed", "requests after worker death fail instead of queueing onto a dead worker")
      Assert.isTrue(
        type(nextFailure) == "string" and nextFailure:find("injected worker crash", 1, true) ~= nil,
        "future requests report the same terminal cause: " .. tostring(nextFailure)
      )
    else
      local message = tostring(requestResult)
      Assert.isTrue(
        message:find("injected worker crash", 1, true) ~= nil or message:find("worker stopped", 1, true) ~= nil,
        "future requests report the terminal worker-stop cause: " .. message
      )
    end
    Assert.equal(#host.allPushes, pushesBefore, "no further request is pushed after the worker stopped")

    queue:release()
  end)
end

function T.ready_payload_survives_worker_death_while_pending_work_fails()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local first = queue:request("mesh", "geometry/first.g4mesh", "demand")
    local second = queue:request("mesh", "geometry/second.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, first), "the idle worker takes the first request immediately")
    Assert.isFalse(requestWasPushedFor(host, second), "the second request waits for the busy worker")

    local requestIndex = requestChannelIndexFor(host, first)
    responseChannelFor(host, requestIndex):push(meshResponse(first, "geometry/first.g4mesh"))
    Assert.equal(queue:poll(first), "ready")
    Assert.isTrue(requestWasPushedFor(host, second), "the second request dispatches once the worker is idle")

    host.threads[1]:stop("late worker crash")

    Assert.equal(queue:poll(first), "ready", "a drained ready payload stays transferable after the worker dies")
    local prepared = assert(queue:wait(first)).value.payload
    Assert.notNil(prepared, "the ready payload transfers exactly once despite the later worker death")

    local pendingState, pendingFailure = queue:poll(second)
    Assert.equal(pendingState, "failed", "still-pending work fails instead of staying pending forever")
    Assert.isTrue(
      type(pendingFailure) == "string" and pendingFailure:find("late worker crash", 1, true) ~= nil,
      "pending work reports the worker-stop cause: " .. tostring(pendingFailure)
    )

    queue:release()
  end)
end

function T.release_after_worker_death_joins_once_without_masking_cleanup()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local token = queue:request("mesh", "geometry/stalled.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "the idle worker takes the request immediately")

    host.threads[1]:stop(nil)

    local tokenState, failure = queue:poll(token)
    Assert.equal(tokenState, "failed", "pending work fails after the worker exits without an error")
    Assert.isTrue(
      type(failure) == "string" and failure:find("worker stopped", 1, true) ~= nil,
      "the terminal cause stays descriptive without a worker error: " .. tostring(failure)
    )

    queue:release()
    queue:release()
    Assert.equal(host.threads[1].waits, 1, "release joins the worker exactly once even after terminal failure")
    Assert.throws(function()
      queue:poll(token)
    end, "a released queue discards outstanding tokens rather than reviving them")
  end)
end

function T.synchronous_wait_reobserves_worker_death_during_channel_block()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local token = queue:request("mesh", "geometry/stalled.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "the idle worker takes the request immediately")

    -- The worker dies after the wait's last health probe without producing
    -- a reply; the wait must bound its channel block so liveness is
    -- re-observed instead of hanging forever. An unbounded demand fails
    -- loudly here rather than hanging the suite.
    local requestIndex = requestChannelIndexFor(host, token)
    local reply = responseChannelFor(host, requestIndex)
    local demands = 0
    reply.onDemand = function(timeout)
      demands = demands + 1
      if type(timeout) ~= "number" or timeout <= 0 or timeout > 0.1 then
        error("synchronous wait performed an unbounded channel demand", 0)
      end
      host.threads[1]:stop("injected wait race")
      return nil
    end

    local err = Assert.throws(function()
      queue:wait(token)
    end, "a wait whose worker dies mid-block must raise instead of hanging")
    Assert.isTrue(demands >= 1, "the wait actually blocked on the reply channel")
    Assert.isTrue(
      tostring(err):find("injected wait race", 1, true) ~= nil,
      "the wait reports the worker-stop cause: " .. tostring(err)
    )

    queue:release()
  end)
end

function T.demand_admission_wins_over_queued_prefetch_when_request_discovers_a_completion()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local queuedPrefetch = queue:request("mesh", "geometry/queued.g4mesh", "prefetch")
    Assert.isFalse(requestWasPushedFor(host, queuedPrefetch), "queued work waits for the busy worker")

    -- The running job's reply arrives but is not processed yet; the demand
    -- below discovers it during admission and must win the replacement
    -- dispatch over the older queued prefetch.
    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    local pushesBefore = #host.allPushes

    local admitted = queue:request("mesh", "geometry/demand.g4mesh", "demand")

    local newPushes = {}
    for index = pushesBefore + 1, #host.allPushes do
      local value = host.allPushes[index].value
      if type(value) == "table" and value.token ~= nil and value.path ~= nil and value.kind ~= nil then
        newPushes[#newPushes + 1] = value.token
      end
    end
    Assert.equal(#newPushes, 1, "admission settles exactly one replacement dispatch")
    Assert.equal(
      newPushes[1],
      admitted,
      "the just-admitted demand wins the replacement dispatch over older queued prefetch"
    )
    Assert.isFalse(
      requestWasPushedFor(host, queuedPrefetch),
      "the older queued prefetch still waits while demand occupies the worker"
    )

    queue:take(running)
    queue:cancel(admitted)
    queue:cancel(queuedPrefetch)
    queue:release()
  end)
end

function T.cancelled_running_prefetch_holds_the_worker_until_queued_demand_dispatches()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local queuedDemand = queue:request("mesh", "geometry/queued-demand.g4mesh", "demand")
    local queuedPrefetch = queue:request("mesh", "geometry/queued-prefetch.g4mesh", "prefetch")
    Assert.isFalse(requestWasPushedFor(host, queuedDemand), "queued work waits for the busy worker")
    Assert.isFalse(requestWasPushedFor(host, queuedPrefetch), "queued work waits for the busy worker")

    queue:cancel(running)

    -- Cancellation frees no physical slot: even a fresh demand queues
    -- behind the still-executing job instead of dispatching immediately.
    local lateDemand = queue:request("mesh", "geometry/late-demand.g4mesh", "demand")
    Assert.equal(pushCountFor(host, queuedDemand), 0, "nothing dispatches while the cancelled job runs")
    Assert.equal(pushCountFor(host, queuedPrefetch), 0, "nothing dispatches while the cancelled job runs")
    Assert.equal(pushCountFor(host, lateDemand), 0, "nothing dispatches while the cancelled job runs")

    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(lateDemand), "pending")
    Assert.equal(pushCountFor(host, queuedDemand), 1, "the earlier demand wins the first dispatch after the late reply")
    Assert.equal(pushCountFor(host, lateDemand), 0, "the later demand still waits its turn")
    Assert.equal(pushCountFor(host, queuedPrefetch), 0, "demand outranks queued prefetch at dispatch time")

    local demandIndex = requestChannelIndexFor(host, queuedDemand)
    responseChannelFor(host, demandIndex):push(meshResponse(queuedDemand, "geometry/queued-demand.g4mesh"))
    Assert.equal(queue:poll(queuedDemand), "ready")
    Assert.equal(pushCountFor(host, lateDemand), 1, "the later demand dispatches once the worker is idle")
    Assert.equal(pushCountFor(host, queuedPrefetch), 0, "prefetch still waits while demand occupies the worker")

    queue:take(queuedDemand)
    queue:cancel(lateDemand)
    local lateIndex = requestChannelIndexFor(host, lateDemand)
    responseChannelFor(host, lateIndex):push(meshResponse(lateDemand, "geometry/late-demand.g4mesh"))
    Assert.equal(queue:poll(queuedPrefetch), "pending")
    Assert.equal(pushCountFor(host, queuedPrefetch), 1, "the queued prefetch dispatches after every demand completes")

    local prefetchIndex = requestChannelIndexFor(host, queuedPrefetch)
    responseChannelFor(host, prefetchIndex):push(meshResponse(queuedPrefetch, "geometry/queued-prefetch.g4mesh"))
    Assert.equal(queue:poll(queuedPrefetch), "ready")
    queue:take(queuedPrefetch)
    queue:release()
  end)
end

function T.late_reply_after_mass_cancellation_dispatches_exactly_one_job()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local firstQueued = queue:request("mesh", "geometry/first-queued.g4mesh", "prefetch")
    local secondQueued = queue:request("mesh", "geometry/second-queued.g4mesh", "prefetch")

    queue:cancel(running)
    queue:cancel(firstQueued)
    queue:cancel(secondQueued)

    local next = queue:request("mesh", "geometry/next.g4mesh", "demand")
    Assert.isFalse(
      requestWasPushedFor(host, next),
      "a fresh request waits while the cancelled job still occupies the worker"
    )

    -- The cancelled job's late reply frees the worker; the cancelled queued
    -- tokens must never reach the worker input channel as stale jobs.
    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(next), "pending")
    Assert.equal(pushCountFor(host, next), 1, "the late reply frees the worker for exactly one next job")
    Assert.equal(pushCountFor(host, firstQueued), 0, "a cancelled queued token never reaches the worker")
    Assert.equal(pushCountFor(host, secondQueued), 0, "a cancelled queued token never reaches the worker")

    local nextIndex = requestChannelIndexFor(host, next)
    responseChannelFor(host, nextIndex):push(meshResponse(next, "geometry/next.g4mesh"))
    Assert.equal(queue:poll(next), "ready", "the next job's own payload still publishes normally")
    queue:take(next)
    queue:release()
  end)
end

function T.queued_wait_reobserves_worker_death_through_bounded_demands()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local queued = queue:request("mesh", "geometry/queued.g4mesh", "demand")
    Assert.isFalse(requestWasPushedFor(host, queued), "the second request waits for the busy worker")

    -- A synchronous wait on work that never dispatched must still bound its
    -- channel block, so a worker dying mid-block is re-observed instead of
    -- hanging the waiter forever.
    local requestIndex = requestChannelIndexFor(host, running)
    local reply = responseChannelFor(host, requestIndex)
    local demands = 0
    reply.onDemand = function(timeout)
      demands = demands + 1
      if type(timeout) ~= "number" or timeout <= 0 or timeout > 0.1 then
        error("synchronous wait performed an unbounded channel demand", 0)
      end
      host.threads[1]:stop("injected queued wait race")
      return nil
    end

    local err = Assert.throws(function()
      queue:wait(queued)
    end, "a queued wait whose worker dies mid-block must raise instead of hanging")
    Assert.isTrue(demands >= 1, "the wait actually blocked on the reply channel")
    Assert.isTrue(
      tostring(err):find("injected queued wait race", 1, true) ~= nil,
      "the queued wait reports the worker-stop cause: " .. tostring(err)
    )

    local runningState, runningFailure = queue:poll(running)
    Assert.equal(runningState, "failed", "the running token fails too instead of staying pending forever")
    Assert.isTrue(
      type(runningFailure) == "string" and runningFailure:find("injected queued wait race", 1, true) ~= nil,
      "the running token reports the same terminal cause: " .. tostring(runningFailure)
    )

    queue:release()
  end)
end

-- A dispatched job carries the resolved resident payload, never a physical
-- generated path: the main thread resolves the immutable reference and the
-- worker decodes those bytes directly.
function T.dispatched_requests_carry_the_resolved_resident_payload()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local cacheFs = fakeCacheFs()
    local queue = newQueue(cacheFs)
    local token = queue:request("mesh", "geometry/a.g4mesh", "demand")

    local record = nil
    for _, entry in ipairs(host.allPushes) do
      local value = entry.value
      if type(value) == "table" and value.token == token then
        record = value
        break
      end
    end
    Assert.notNil(record, "the request must reach the worker input channel")
    assert(record, "the pushed request record must be available")
    local reference = assert(cacheFs:resolveAsset("geometry/a.g4mesh"), "the queue resolves the resident reference")
    Assert.isTrue(record.data == reference.data, "the worker receives the resolved resident bytes themselves")
    Assert.equal(record.path, "geometry/a.g4mesh", "the logical path still names the job for diagnostics")
    Assert.isNil(record.logicalPath, "the job carries one logical path, not a second bank-memo identity")
    Assert.isNil(record.versionId, "the worker builds no second versioned cache")
    Assert.equal(record.data:getString(), "resident:geometry/a.g4mesh", "the payload carries the selected bytes")
    Assert.equal(queue:poll(token), "pending", "no reply was faked, so the token stays pending")
    queue:release()
  end)
end

function T.finish_promotes_the_queued_prefetch_token_to_demand()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local queued = queue:request("mesh", "geometry/queued.g4mesh", "prefetch")
    Assert.isFalse(requestWasPushedFor(host, queued), "the second request waits for the busy worker")

    -- Finishing the scene task upgrades its outstanding prefetch token to
    -- demand in place: the same token keeps its identity and is never
    -- dispatched twice for the promotion itself.
    queue:promote(queued, "demand")
    Assert.equal(pushCountFor(host, queued), 0, "promotion upgrades priority without dispatching by itself")

    local laterPrefetch = queue:request("mesh", "geometry/later.g4mesh", "prefetch")

    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(running), "ready")
    Assert.equal(pushCountFor(host, queued), 1, "the promoted token wins the next physical dispatch")
    Assert.isFalse(requestWasPushedFor(host, laterPrefetch), "the promoted demand outranks later prefetch work")

    Assert.throws(function()
      queue:promote("never-requested", "demand")
    end, "promoting an unknown token fails loudly")

    queue:take(running)
    queue:cancel(queued)
    queue:cancel(laterPrefetch)
    queue:release()
  end)
end

function T.identical_inflight_requests_share_one_worker_dispatch()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local first = queue:request("mesh", "geometry/shared.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, first), "the idle worker takes the first request immediately")
    -- An identical in-flight request keeps its own token but never
    -- dispatches a second worker job for the same bytes.
    local second = queue:request("mesh", "geometry/shared.g4mesh", "demand")
    Assert.isTrue(first ~= second, "duplicate interest keeps its own token")
    Assert.equal(pushCountFor(host, second), 0, "an identical in-flight request never dispatches twice")
    -- A different kind over the same path is a different job.
    local otherKind = queue:request("image", "geometry/shared.g4mesh", "demand")
    Assert.isFalse(requestWasPushedFor(host, otherKind), "the kind-disjoint request waits while the worker is busy")

    local requestIndex = requestChannelIndexFor(host, first)
    responseChannelFor(host, requestIndex):push(meshResponse(first, "geometry/shared.g4mesh"))
    Assert.equal(queue:poll(first), "ready")
    Assert.equal(queue:poll(second), "ready", "the linked token observes the shared result")
    local firstPayload = assert(queue:take(first)).value.payload
    local secondPayload = assert(queue:take(second)).value.payload
    Assert.equal(firstPayload.vertexCount, secondPayload.vertexCount, "both tokens take the shared payload")
    Assert.throws(function()
      queue:take(second)
    end, "each linked token still transfers exactly once")
    queue:cancel(otherKind)
    queue:release()
  end)
end

function T.cancelled_primary_promotes_its_follower_without_redispatch()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    local primary = queue:request("mesh", "geometry/shared.g4mesh", "prefetch")
    local follower = queue:request("mesh", "geometry/shared.g4mesh", "prefetch")
    Assert.equal(pushCountFor(host, follower), 0, "the follower never dispatches its own job")
    queue:cancel(primary)
    Assert.throws(function()
      queue:take(primary)
    end, "a cancelled primary never transfers")
    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(running), "ready")
    Assert.isTrue(requestWasPushedFor(host, follower), "the promoted follower dispatches once the worker is idle")
    Assert.equal(pushCountFor(host, primary), 0, "the cancelled primary never dispatches")
    local followerIndex = requestChannelIndexFor(host, follower)
    responseChannelFor(host, followerIndex):push(meshResponse(follower, "geometry/shared.g4mesh"))
    Assert.equal(queue:poll(follower), "ready")
    Assert.notNil(queue:take(follower), "the promoted follower still transfers")
    queue:take(running)
    queue:release()
  end)
end

function T.shared_worker_failure_fails_every_link()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local first = queue:request("mesh", "geometry/shared.g4mesh", "demand")
    local second = queue:request("mesh", "geometry/shared.g4mesh", "demand")
    local requestIndex = requestChannelIndexFor(host, first)
    responseChannelFor(host, requestIndex):push(failureResponse(first, "mesh", "geometry/shared.g4mesh"))
    Assert.equal(queue:poll(first), "failed", "the primary reports the shared failure")
    Assert.equal(queue:poll(second), "failed", "the linked token reports the same shared failure")
    queue:release()
  end)
end

-- A decoded identity publishes one immutable value and every consumer takes
-- its own kernel lease over it. The hand-off must be a lease rather than raw
-- payload ownership: only then do equal requests share one charge, one
-- consumer's return leave the others valid, and the payload free exactly once
-- after the last return even when it exceeds the idle budget.
local function ownedBytes(size)
  return {
    released = 0,
    getSize = function(self)
      return size
    end,
    release = function(self)
      self.released = self.released + 1
    end,
  }
end

local function leaseableMeshResponse(token, path)
  return {
    token = token,
    ok = true,
    kind = "mesh",
    path = path,
    vertexData = ownedBytes(32),
    indexData = ownedBytes(8),
    vertexCount = 3,
    indexCount = 3,
    indexType = "uint16",
    centerX = 0,
    centerY = 0,
    centerZ = 0,
  }
end

local function sharedKernel()
  local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
  local released = {}
  local decoded = ResidentAssetCache.new({
    idleByteLimit = 64,
    release = function(value)
      released[#released + 1] = value
      if type(value.release) == "function" then
        value:release()
      end
    end,
  })
  return decoded, released
end

function T.coalesced_requests_transfer_independent_leases_over_one_charge()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local decoded, released = sharedKernel()
    local cacheFs = fakeCacheFs()
    local queue = AssetPreparationQueue.new(cacheFs, { decoded = decoded })

    local primary = queue:request("mesh", "geometry/shared.g4mesh", "demand")
    local follower = queue:request("mesh", "geometry/shared.g4mesh", "demand")
    Assert.equal(pushCountFor(host, follower), 0, "an equal request coalesces onto the running job")

    queue:cancel(primary)
    local late = queue:request("mesh", "geometry/other.g4mesh", "demand")
    Assert.equal(pushCountFor(host, late), 0, "cancelling the primary frees no physical worker slot")

    local requestIndex = requestChannelIndexFor(host, primary)
    responseChannelFor(host, requestIndex):push(leaseableMeshResponse(primary, "geometry/shared.g4mesh"))
    Assert.equal(queue:poll(follower), "ready", "the cancelled primary's completion serves the surviving follower")
    Assert.equal(pushCountFor(host, late), 1, "the late reply frees the worker for the next job")

    local followerLease = queue:take(follower)
    Assert.equal(type(followerLease), "table", "a ready token transfers a lease")
    Assert.notNil(
      followerLease.value,
      "take must transfer a lease over the shared decoded value instead of raw payload ownership"
    )
    local value = followerLease.value
    Assert.equal(value.kind, "mesh", "the lease exposes the requested decode kind")
    Assert.notNil(value.payload.vertexData, "the lease exposes the immutable decoded payload")
    Assert.equal(value.nativeBytes, 40, "native bytes count the owned output buffers, never the borrowed source")
    Assert.equal(value.metadataChargeBytes, 128, "one decoded value carries its policy charge")
    local charge = value.nativeBytes + value.metadataChargeBytes
    Assert.equal(decoded:stats().pinnedBytes, charge, "the whole weight is pinned while the lease lives")
    Assert.equal(decoded:stats().idleBytes, 0, "a live lease keeps no idle bytes")
    local ownedVertex = value.payload.vertexData
    local ownedIndex = value.payload.indexData

    local revisit = queue:request("mesh", "geometry/shared.g4mesh", "demand")
    Assert.equal(queue:poll(revisit), "ready", "a resident identity resolves without another worker job")
    Assert.equal(pushCountFor(host, revisit), 0, "a resident identity never dispatches the worker again")
    local revisitLease = queue:take(revisit)
    Assert.isTrue(revisitLease.value == value, "independent consumers share one immutable value")
    Assert.equal(decoded:stats().pinnedBytes, charge, "a repeated consumer charges the shared value once")

    local reference = assert(cacheFs:resolveAsset("geometry/shared.g4mesh"))
    Assert.equal(
      reference.data:getString(),
      "resident:geometry/shared.g4mesh",
      "the borrowed base bytes stay untouched and out of the charge"
    )

    Assert.isTrue(decoded:returnLease(followerLease), "the owner accepts the first lease return")
    Assert.isNil(followerLease.value, "a returned lease clears its exposed value")
    Assert.notNil(revisitLease.value, "another consumer keeps its valid lease after the first return")
    Assert.equal(decoded:stats().pinnedBytes, charge, "the shared value stays pinned for the surviving lease")
    Assert.equal(#released, 0, "no shared payload is freed while a lease remains")
    Assert.isFalse(decoded:returnLease(followerLease), "repeating a return is harmless")

    Assert.isTrue(decoded:returnLease(revisitLease))
    Assert.equal(decoded:stats().pinnedBytes, 0, "the last return unpins the shared value")
    Assert.equal(decoded:stats().idleBytes, charge, "the shared value becomes idle at its single charge")
    Assert.equal(decoded:trim(), 1, "a demand larger than the idle budget is evicted after its final return")
    Assert.equal(#released, 1, "the shared payload is freed exactly once")
    Assert.isTrue(released[1] == value, "the freed value is the one every consumer shared")
    Assert.equal(ownedVertex.released, 1, "the owned vertex buffer is released exactly once")
    Assert.equal(ownedIndex.released, 1, "the owned index buffer is released exactly once")

    queue:cancel(late)
    queue:release()
  end)
end

function T.linked_demand_upgrades_a_queued_prefetch_job()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    local primary = queue:request("mesh", "geometry/shared.g4mesh", "prefetch")
    local follower = queue:request("mesh", "geometry/shared.g4mesh", "demand")
    Assert.equal(pushCountFor(host, follower), 0, "the follower never dispatches its own job")
    local laterPrefetch = queue:request("mesh", "geometry/other.g4mesh", "prefetch")
    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(running), "ready")
    Assert.isTrue(
      requestWasPushedFor(host, primary),
      "the upgraded job wins the next physical dispatch over later prefetch"
    )
    Assert.isFalse(requestWasPushedFor(host, laterPrefetch), "the upgraded demand outranks later prefetch work")
    queue:take(running)
    queue:cancel(primary)
    queue:cancel(follower)
    queue:cancel(laterPrefetch)
    queue:release()
  end)
end

-- A selected reader whose entries are disk-backed package sources: a reference
-- names its confined mounted path and carries no resident bytes. The ordered
-- selection itself is proven by its own suites; this only supplies the read
-- shape the queue's source work is defined over.
local function diskCacheFs()
  local references = {}
  return {
    versionId = "heartgold",
    resolveAsset = function(_, relativePath)
      local reference = references[relativePath]
      if reference == nil then
        reference = {
          path = relativePath,
          size = 24,
          sourceId = "mod:selected-epoch\0package",
          contentId = "mod:selected-epoch\0package\0" .. relativePath,
          physicalPath = "__package/" .. relativePath,
        }
        references[relativePath] = reference
      end
      return reference
    end,
  }
end

-- One selected view that serves both shapes: the generated base stays resident
-- and the packaged mod member is disk-backed, so one queue can hold a
-- speculative ready payload and a selected-source decode at the same time.
local function mixedCacheFs()
  local resident = fakeCacheFs()
  local packaged = diskCacheFs()
  return {
    versionId = "heartgold",
    resolveAsset = function(_, relativePath)
      if relativePath:sub(1, 4) == "pkg/" then
        return packaged:resolveAsset(relativePath)
      end
      return resident.resolveAsset(resident, relativePath)
    end,
  }
end

-- Every physical request the fake worker received for one token (test-pushed
-- replies carry their own token and kind too, so they are not dispatches).
---@param state table
---@param token integer
---@return table[]
local function pushesFor(state, token)
  local pushed = {}
  for _, entry in ipairs(state.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.token == token and value.path ~= nil and value.kind ~= nil and value.ok == nil then
      pushed[#pushed + 1] = value
    end
  end
  return pushed
end

-- A disk-backed selected asset is read first: the physical dispatch for a
-- graphical request is the source read of that confined member, and the decode
-- itself never reaches the worker with an absent payload.
function T.a_disk_backed_request_dispatches_its_source_read_before_any_decode()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(diskCacheFs())
    local path = "assets/generated/field/30/package.png"
    local token = queue:request("image-derivative", path, "demand")
    local dispatched = pushesFor(host, token)
    Assert.equal(#dispatched, 1, "one physical dispatch happens for the pending selected source")
    Assert.equal(dispatched[1].kind, "source", "the worker first reads the selected member, not a decode")
    Assert.equal(dispatched[1].path, path, "the source read names the logical selected path")
    Assert.equal(queue:poll(token), "pending", "the graphical request waits for its source rather than failing")
    queue:cancel(token)
    queue:release()
  end)
end

-- The same selected source is physically read once however many consumers ask
-- for it, and a cancelled consumer returns only its own interest.
function T.consumers_of_one_disk_source_share_a_single_physical_read()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(diskCacheFs())
    local path = "assets/generated/field/30/shared-package.png"
    local primary = queue:request("image-derivative", path, "demand")
    local follower = queue:request("image-derivative", path, "demand")
    local sourcePushes = 0
    for _, entry in ipairs(host.allPushes) do
      if type(entry.value) == "table" and entry.value.kind == "source" then
        sourcePushes = sourcePushes + 1
      end
    end
    Assert.equal(sourcePushes, 1, "both consumers wait on one physical source read")
    Assert.equal(#pushesFor(host, follower), 0, "the follower owns no physical dispatch")
    queue:cancel(follower)
    Assert.equal(queue:poll(primary), "pending", "cancelling one consumer keeps the other's interest alive")
    queue:cancel(primary)
    queue:release()
  end)
end

-- The source request kind belongs to disk-backed references: asking for base
-- resident bytes through it is programming misuse, because base bytes are
-- borrowed directly and never charged to the decoded owner.
function T.the_source_request_kind_refuses_a_resident_base_reference()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    local failure = Assert.throws(function()
      queue:request("source", "geometry/resident.g4mesh", "demand")
    end, "a resident base reference is not a source read")
    Assert.isTrue(
      tostring(failure):find("unknown preparation kind", 1, true) == nil,
      "the source kind is a known preparation kind, so the refusal is the base-reference misuse: " .. tostring(failure)
    )
    queue:release()
  end)
end

-- One worker reply for a selected source read, in the flat shape the worker
-- pushes: identity, logical path, and exactly the bytes it read.
local function sourceResponse(token, path, bytes)
  local payload = ownedBuffer(bytes)
  return {
    token = token,
    ok = true,
    kind = "source",
    path = path,
    sourceId = "mod:selected-epoch\0package",
    contentId = "mod:selected-epoch\0package\0" .. path,
    size = payload:getSize(),
    payload = payload,
  }
end

-- Physical source requests only: test-pushed replies also carry kind "source"
-- and an ok flag, so they are not dispatches.
local function sourcePushCount(state)
  local count = 0
  for _, entry in ipairs(state.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.kind == "source" and value.ok == nil then
      count = count + 1
    end
  end
  return count
end

-- A compact synchronous acquisition joins the one source read already pending
-- for its content key: it neither starts a second read nor duplicates the
-- retained allocation, and the lease it returns is the shared owner's.
function T.a_compact_acquisition_joins_the_pending_selected_source()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local cacheFs = diskCacheFs()
    local queue = newQueue(cacheFs)
    local path = "assets/generated/field/30/pending-compact.png"
    local decode = queue:request("image-derivative", path, "demand")
    local requestIndex = requestChannelIndexFor(host, decode)
    local response = sourceResponse(decode, path, string.rep("s", 24))
    responseChannelFor(host, requestIndex):push(response)

    local reference = assert(cacheFs:resolveAsset(path), "the selected member resolves")
    local lease = queue:acquireSource(reference)
    Assert.isTrue(lease.value == response.payload, "the compact lease borrows the read selected bytes")
    Assert.equal(sourcePushCount(host), 1, "compact acquisition joins the one pending source read")
    local decoded = queue:poll(decode)
    Assert.isTrue(decoded == "pending" or decoded == "ready", "the graphical request continues after the same read")
    lease:release()
    Assert.isNil(lease.value, "a returned compact lease clears its reference")
    queue:release()
  end)
end

-- A dispatched source read keeps its physical slot and still feeds the
-- surviving consumer after its logical owner is cancelled; the read is never
-- duplicated and the replacement dispatch waits for the physical reply.
function T.cancelling_a_dispatched_source_owner_keeps_the_read_for_its_successor()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local cacheFs = diskCacheFs()
    local queue = newQueue(cacheFs)
    local path = "assets/generated/field/30/forwarded-source.png"
    local owner = queue:request("image-derivative", path, "demand")
    local requestIndex = requestChannelIndexFor(host, owner)
    local waiter = queue:request("source", path, "demand")
    Assert.equal(#pushesFor(host, waiter), 0, "the compact waiter dispatches no job of its own")
    Assert.equal(sourcePushCount(host), 1, "both consumers share the one physical read")

    queue:cancel(owner)
    local later = queue:request("mesh", "geometry/later.g4mesh", "demand")
    Assert.isFalse(
      requestWasPushedFor(host, later),
      "a fresh request waits while the cancelled source read still occupies the worker"
    )

    responseChannelFor(host, requestIndex):push(sourceResponse(owner, path, string.rep("f", 24)))
    Assert.equal(queue:poll(waiter), "ready", "the surviving consumer receives the forwarded read")
    local lease = queue:wait(waiter)
    Assert.notNil(assert(lease.value).payload, "the forwarded read hands over its retained bytes")
    Assert.isTrue(
      requestWasPushedFor(host, later),
      "the queued request dispatches only after the physical reply frees the worker"
    )
    queue:cancel(later)
    queue:release()
  end)
end

function T.release_keeps_dispatched_source_lease_until_worker_join()
  local AssetPreparationQueue = requireQueue()
  local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
  local host = fakeThreadHost()
  local released = 0
  local decoded = ResidentAssetCache.new({
    idleByteLimit = 0,
    release = function(value)
      released = released + 1
      value:release()
    end,
  })
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(diskCacheFs(), { decoded = decoded, thread = host.love.thread })
    local path = "assets/generated/field/30/leased-package.png"
    local token = queue:request("image-derivative", path, "demand")
    local sourceRequest = requestChannelIndexFor(host, token)
    responseChannelFor(host, sourceRequest):push(sourceResponse(token, path, string.rep("p", 24)))
    Assert.equal(queue:poll(token), "pending", "the source reply dispatches a decode with its input pinned")
    Assert.isTrue(decoded:stats().pinnedBytes > 0, "the physical decode owns the source lease")

    local thread = assert(host.threads[1], "the worker was started for the source read")
    local wait = thread.wait
    local pinnedDuringWait = 0
    function thread:wait()
      pinnedDuringWait = decoded:stats().pinnedBytes
      return wait(self)
    end
    queue:release()

    Assert.isTrue(pinnedDuringWait > 0, "the dispatched decode stays pinned throughout worker join")
    Assert.equal(decoded:stats().pinnedBytes, 0, "the physical lease returns after join")
    Assert.equal(decoded:stats().idleBytes, 0, "over-budget source bytes trim only after join")
    Assert.equal(released, 1, "the source backing releases once after its final lease returns")
    Assert.equal(next(queue._decodeLeases), nil, "no borrowed decode lease survives disposal")
  end)
end

-- A raised slot budget overlaps independent work: two distinct sources run at
-- once, and lowering the budget leaves the running jobs alone while the one
-- remaining slot keeps taking work.
function T.raised_slot_budget_overlaps_independent_work()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    Assert.equal(queue:workerSlotBudget(), 1, "an ordinary queue owns one slot")
    queue:setWorkerSlots(2)
    Assert.equal(queue:workerSlotCount(), 0, "raising the budget alone starts no worker")

    local first = queue:request("mesh", "geometry/overlap-a.g4mesh", "prefetch")
    local second = queue:request("mesh", "geometry/overlap-b.g4mesh", "prefetch")
    Assert.equal(#host.threads, 2, "two independent sources start two workers")
    Assert.isTrue(requestWasPushedFor(host, first), "the first source dispatched")
    Assert.isTrue(
      requestWasPushedFor(host, second),
      "the second source dispatched in the same pass instead of behind the first"
    )

    queue:setWorkerSlots(1)
    local third = queue:request("mesh", "geometry/overlap-c.g4mesh", "demand")
    Assert.isFalse(requestWasPushedFor(host, third), "the lowered budget admits no work onto the extra slot")

    -- Every slot reports on the one shared reply channel the first worker
    -- started with. The lower-index worker settling first must not admit new
    -- work while the higher-index worker still occupies the host.
    local reply = assert(host.threads[1].startArgs[1][2], "the worker starts with the shared reply channel")
    reply:push(meshResponse(first, "geometry/overlap-a.g4mesh"))
    Assert.equal(queue:poll(third), "pending", "the settled job frees nothing beyond the budget")
    Assert.isFalse(
      requestWasPushedFor(host, third),
      "an idle lower slot never restores the occupancy the downshift removed"
    )

    -- The surviving over-budget job settles before any new work dispatches.
    reply:push(meshResponse(second, "geometry/overlap-b.g4mesh"))
    Assert.equal(queue:poll(third), "pending", "the third request waits for its own reply")
    Assert.isTrue(requestWasPushedFor(host, third), "occupancy below the budget admits the next job")
    queue:release()
  end)
end

-- A stopped worker terminalizes the whole executor instead of silently halving
-- its capacity: every unsettled token fails with the terminal cause and the
-- executor admits no new work.
function T.worker_death_with_several_slots_terminalizes_every_token()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs())
    queue:setWorkerSlots(2)
    local first = queue:request("mesh", "geometry/death-a.g4mesh", "demand")
    local second = queue:request("mesh", "geometry/death-b.g4mesh", "demand")
    Assert.equal(#host.threads, 2, "both slots run")
    host.threads[2]:stop("injected worker exit")
    local status, failure = queue:poll(first)
    Assert.equal(status, "failed", "the surviving slot's token fails with the executor")
    Assert.isTrue(tostring(failure):find("injected worker exit", 1, true) ~= nil, "the terminal cause is preserved")
    Assert.equal(queue:poll(second), "failed", "every unsettled token fails")
    queue:release()
  end)
end

-- The ready-payload ceiling bounds speculative readiness, never the resource a
-- real consumer is blocked on: promoting the awaited token dispatches it even
-- while unrelated ready payloads hold the ceiling, while a bare probe of
-- speculative work never changes scheduling.
function T.an_awaited_prefetch_progresses_past_the_ready_payload_ceiling()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs(), { readyPayloadByteLimit = 1 })
    local filler = queue:request("mesh", "geometry/ceiling-filler.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, filler), "the first speculative source dispatches under the ceiling")
    local fillerIndex = requestChannelIndexFor(host, filler)
    responseChannelFor(host, fillerIndex):push(meshResponse(filler, "geometry/ceiling-filler.g4mesh"))
    Assert.equal(queue:poll(filler), "ready", "the speculative payload occupies the ready ceiling")

    local awaited = queue:request("mesh", "geometry/ceiling-awaited.g4mesh", "prefetch")
    Assert.isFalse(requestWasPushedFor(host, awaited), "the ceiling holds the next speculative dispatch")
    Assert.equal(queue:poll(awaited), "pending", "the awaited resource is still queued")
    Assert.isFalse(
      requestWasPushedFor(host, awaited),
      "a speculative probe alone never changes scheduling"
    )
    Assert.equal(queue:poll(awaited), "pending", "promotion alone dispatches nothing")
    queue:promote(awaited, "demand")
    Assert.equal(queue:poll(awaited), "pending", "the promoted frontier still waits on its reply")
    Assert.isTrue(
      requestWasPushedFor(host, awaited),
      "promoting the awaited resource dispatches past the ceiling"
    )

    local awaitedIndex = requestChannelIndexFor(host, awaited)
    responseChannelFor(host, awaitedIndex):push(meshResponse(awaited, "geometry/ceiling-awaited.g4mesh"))
    Assert.equal(queue:poll(awaited), "ready", "the awaited resource completes despite the ceiling")
    queue:take(awaited)
    queue:take(filler)
    queue:release()
  end)
end

-- A blocking caller is the strongest current need: waiting promotes its own
-- token so a speculative reservation can never keep it queued.
function T.a_blocking_wait_promotes_the_token_it_waits_on()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(fakeCacheFs(), { readyPayloadByteLimit = 1 })
    local filler = queue:request("mesh", "geometry/wait-filler.g4mesh", "prefetch")
    local fillerIndex = requestChannelIndexFor(host, filler)
    responseChannelFor(host, fillerIndex):push(meshResponse(filler, "geometry/wait-filler.g4mesh"))
    Assert.equal(queue:poll(filler), "ready", "the speculative payload occupies the ready ceiling")

    local awaited = queue:request("mesh", "geometry/wait-awaited.g4mesh", "prefetch")
    Assert.isFalse(requestWasPushedFor(host, awaited), "the ceiling holds the awaited speculative job")
    local reply = responseChannelFor(host, requestChannelIndexFor(host, filler))
    local requestIndex
    reply.onDemand = function()
      reply.onDemand = nil
      requestIndex = requestChannelIndexFor(host, awaited)
      assert(requestIndex ~= nil, "the promoted job dispatched before the wait blocked")
      responseChannelFor(host, requestIndex):push(meshResponse(awaited, "geometry/wait-awaited.g4mesh"))
      return reply:pop()
    end
    local lease = queue:wait(awaited)
    Assert.notNil(lease and lease.value, "the blocking wait transfers the promoted job's lease")
    Assert.isTrue(requestIndex ~= nil, "the wait dispatched the promoted job")
    queue:take(filler)
    queue:release()
  end)
end

-- Effective demand survives every stage of a logical acquisition: a consumer
-- that promotes a graphical request while its selected-source read is already
-- running must still get the decode continuation dispatched past an occupied
-- ready-payload ceiling, because the promotion belongs to the logical token and
-- not to the physical op it happens to be waiting on.
function T.promotion_during_a_running_source_read_dispatches_the_decode_continuation()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(mixedCacheFs(), { readyPayloadByteLimit = 1, workerSlots = 2 })
    local path = "pkg/generated/field/30/promoted-package.png"
    local awaited = queue:request("image-derivative", path, "prefetch")
    local sourceIndex = assert(requestChannelIndexFor(host, awaited), "the speculative source read dispatched")
    Assert.equal(pushesFor(host, awaited)[1].kind, "source", "the first physical job is the selected read")

    local filler = queue:request("mesh", "geometry/ceiling-filler.g4mesh", "prefetch")
    responseChannelFor(host, filler):push(meshResponse(filler, "geometry/ceiling-filler.g4mesh"))
    Assert.equal(queue:poll(filler), "ready", "the speculative payload occupies the ready ceiling")

    -- The consumer starts awaiting the packaged texture mid-read.
    queue:promote(awaited, "demand")
    responseChannelFor(host, sourceIndex):push(sourceResponse(awaited, path, string.rep("q", 24)))
    Assert.equal(queue:poll(awaited), "pending", "a source reply alone is not the awaited decode")
    local dispatched = pushesFor(host, awaited)
    Assert.equal(#dispatched, 2, "the decode continuation dispatches past the occupied ceiling")
    Assert.equal(dispatched[2].kind, "image-derivative", "the second physical job is the decode")

    queue:take(filler)
    queue:cancel(awaited)
    queue:release()
  end)
end

-- A demand follower of a shared selected read keeps its own urgency: the
-- coalesced decode it ends up awaiting dispatches at the ceiling even though the
-- read owner and the follower asked with different priorities.
function T.a_demand_follower_of_a_prefetched_read_still_dispatches_its_decode()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(mixedCacheFs(), { readyPayloadByteLimit = 1, workerSlots = 2 })
    local path = "pkg/generated/field/30/shared-package.png"
    local speculative = queue:request("image-derivative", path, "prefetch")
    local sourceIndex = assert(requestChannelIndexFor(host, speculative), "the speculative read dispatched")

    local filler = queue:request("mesh", "geometry/shared-filler.g4mesh", "prefetch")
    responseChannelFor(host, filler):push(meshResponse(filler, "geometry/shared-filler.g4mesh"))
    Assert.equal(queue:poll(filler), "ready", "the speculative payload occupies the ready ceiling")

    local awaited = queue:request("image-derivative", path, "demand")
    Assert.equal(sourcePushCount(host), 1, "the demanded follower coalesces onto the one physical read")
    responseChannelFor(host, sourceIndex):push(sourceResponse(speculative, path, string.rep("r", 24)))
    Assert.equal(queue:poll(awaited), "pending", "the awaited decode has not completed")
    Assert.equal(
      #pushesFor(host, speculative) + #pushesFor(host, awaited),
      2,
      "exactly one decode dispatches past the ceiling for the coalesced requesters"
    )

    queue:take(filler)
    queue:cancel(awaited)
    queue:cancel(speculative)
    queue:release()
  end)
end

-- Demand belongs to the surviving logical consumer, not to whichever token
-- temporarily owns the shared source read. Cancelling that owner must promote
-- the oldest heir without losing a later consumer's urgency.
function T.a_demanded_consumer_survives_source_owner_cancellation_at_the_ceiling()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(mixedCacheFs(), { readyPayloadByteLimit = 1, workerSlots = 2 })
    local path = "pkg/generated/field/30/succession-a.png"
    local owner = queue:request("image-derivative", path, "prefetch")
    local olderFollower = queue:request("image-derivative", path, "prefetch")
    local demanded = queue:request("image-derivative", path, "prefetch")
    local sourceIndex = assert(requestChannelIndexFor(host, owner), "the shared source read dispatched")

    local filler = queue:request("mesh", "geometry/succession-filler.g4mesh", "prefetch")
    responseChannelFor(host, filler):push(meshResponse(filler, "geometry/succession-filler.g4mesh"))
    Assert.equal(queue:poll(filler), "ready", "the ready ceiling is occupied")

    queue:promote(demanded, "demand")
    queue:cancel(owner)
    responseChannelFor(host, sourceIndex):push(sourceResponse(owner, path, string.rep("s", 24)))
    Assert.equal(queue:poll(demanded), "pending", "the source successor still owes its decode")
    Assert.equal(#pushesFor(host, olderFollower), 1, "the oldest heir dispatches one demanded decode")
    Assert.equal(pushesFor(host, olderFollower)[1].kind, "image-derivative", "the successor performs the shared decode")
    Assert.equal(sourcePushCount(host), 1, "succession never duplicates the selected read")

    queue:take(filler)
    queue:cancel(olderFollower)
    queue:cancel(demanded)
    queue:release()
  end)
end

function T.a_demand_follower_survives_an_older_prefetch_heir()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(mixedCacheFs(), { readyPayloadByteLimit = 1, workerSlots = 2 })
    local path = "pkg/generated/field/30/succession-b.png"
    local owner = queue:request("image-derivative", path, "prefetch")
    local olderFollower = queue:request("image-derivative", path, "prefetch")
    local demanded = queue:request("image-derivative", path, "demand")
    local sourceIndex = assert(requestChannelIndexFor(host, owner), "the shared source read dispatched")

    local filler = queue:request("mesh", "geometry/succession-filler-b.g4mesh", "prefetch")
    responseChannelFor(host, filler):push(meshResponse(filler, "geometry/succession-filler-b.g4mesh"))
    Assert.equal(queue:poll(filler), "ready", "the ready ceiling is occupied")

    queue:cancel(owner)
    responseChannelFor(host, sourceIndex):push(sourceResponse(owner, path, string.rep("t", 24)))
    Assert.equal(queue:poll(demanded), "pending", "the surviving demand waits for its shared decode")
    Assert.equal(#pushesFor(host, olderFollower), 1, "the older prefetch heir inherits the surviving demand")

    queue:take(filler)
    queue:cancel(olderFollower)
    queue:cancel(demanded)
    queue:release()
  end)
end

-- A queued source owner can be cancelled while a different decode selector
-- still needs the same bytes. The read transfers to that survivor and keeps its
-- demand without dispatching the cancelled owner's unrelated decode.
function T.a_queued_source_owner_transfers_the_read_to_a_different_selector()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(mixedCacheFs())
    local running = queue:request("mesh", "geometry/source-selector-running.g4mesh", "demand")
    local path = "pkg/generated/field/30/shared-bank.g4gx"
    local owner = queue:request("image-derivative", path, "prefetch")
    local survivor = queue:request("g4tx", {
      file = path,
      textureName = "survivor",
    }, "demand")
    Assert.equal(pushCountFor(host, owner), 0, "the speculative source owner is still queued")
    Assert.equal(pushCountFor(host, survivor), 0, "the demanded selector coalesces on that read")

    queue:cancel(owner)
    responseChannelFor(host, running):push(meshResponse(running, "geometry/source-selector-running.g4mesh"))
    Assert.equal(queue:poll(survivor), "pending", "the surviving selector waits for its transferred read")
    Assert.equal(sourcePushCount(host), 1, "the read dispatches once for the surviving selector")
    Assert.equal(pushesFor(host, survivor)[1].kind, "source", "the survivor first receives the physical read")
    Assert.equal(pushCountFor(host, owner), 0, "the cancelled owner never dispatches")

    local sourceIndex = requestChannelIndexFor(host, survivor)
    responseChannelFor(host, sourceIndex):push(sourceResponse(survivor, path, string.rep("w", 24)))
    Assert.equal(queue:poll(survivor), "pending", "source settlement starts the survivor's decode")
    Assert.equal(pushesFor(host, survivor)[2].kind, "g4tx", "only the required selector decode runs")
    Assert.notNil(pushesFor(host, survivor)[2].data, "the selected decode receives its source bytes")

    queue:take(running)
    queue:cancel(survivor)
    queue:release()
  end)
end

-- A direct source consumer raises the shared read's priority, but must not
-- turn the read owner's unrelated speculative decode into demand work.
function T.source_demand_does_not_promote_an_unrelated_owner_decode()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(mixedCacheFs(), { readyPayloadByteLimit = 1, workerSlots = 2 })
    local path = "pkg/generated/field/30/shared-source.png"
    local owner = queue:request("image-derivative", path, "prefetch")
    local sourceIndex = assert(requestChannelIndexFor(host, owner), "the speculative source read dispatched")
    local sourceConsumer = queue:request("source", path, "demand")

    local filler = queue:request("mesh", "geometry/source-demand-filler.g4mesh", "prefetch")
    responseChannelFor(host, filler):push(meshResponse(filler, "geometry/source-demand-filler.g4mesh"))
    Assert.equal(queue:poll(filler), "ready", "the ready ceiling is occupied")

    responseChannelFor(host, sourceIndex):push(sourceResponse(owner, path, string.rep("u", 24)))
    Assert.equal(queue:poll(sourceConsumer), "ready", "the demanded source completes")
    Assert.equal(queue:poll(owner), "pending", "the unrelated decode remains speculative")
    Assert.equal(#pushesFor(host, owner), 1, "source demand does not bypass the ceiling for an unrelated decode")

    queue:take(filler)
    queue:take(sourceConsumer)
    queue:cancel(owner)
    queue:release()
  end)
end

-- Two independent reasons to raise one queued selected read -- another
-- consumer's prerequisite demand and the owner's own decode demand -- still
-- leave exactly one pending entry: one physical source read dispatches, and
-- the decode that follows dispatches once for the coalesced requesters.
function T.one_queued_source_read_promoted_through_both_urgency_paths_dispatches_once()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(mixedCacheFs(), { workerSlots = 2 })
    local blockerA = queue:request("mesh", "geometry/promotion-blocker-a.g4mesh", "demand")
    local blockerB = queue:request("mesh", "geometry/promotion-blocker-b.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, blockerA), "the first slot takes the first blocker")
    Assert.isTrue(requestWasPushedFor(host, blockerB), "the second slot takes the second blocker")
    local path = "pkg/generated/field/30/double-promotion.png"
    local owner = queue:request("image-derivative", path, "prefetch")
    Assert.equal(#pushesFor(host, owner), 0, "the speculative owner waits for both slots")

    -- A compact consumer raises the shared read's prerequisite urgency.
    local consumer = queue:request("source", path, "demand")
    -- The owner's own blocked consumer raises its decode urgency.
    queue:promote(owner, "demand")
    Assert.equal(#pushesFor(host, owner), 0, "queued promotions never dispatch by themselves")

    responseChannelFor(host, blockerB):push(meshResponse(blockerB, "geometry/promotion-blocker-b.g4mesh"))
    responseChannelFor(host, blockerA):push(meshResponse(blockerA, "geometry/promotion-blocker-a.g4mesh"))
    Assert.equal(queue:poll(blockerA), "ready", "both blockers settle through the shared reply channel")
    Assert.equal(sourcePushCount(host), 1, "the read promoted through both paths dispatches on one slot")
    Assert.equal(#pushesFor(host, owner), 1, "no duplicate entry dispatches the same source token twice")

    responseChannelFor(host, requestChannelIndexFor(host, owner)):push(sourceResponse(owner, path, string.rep("x", 24)))
    Assert.equal(queue:poll(consumer), "ready", "the compact consumer receives the shared read")
    Assert.equal(queue:poll(owner), "pending", "the owner still owes its coalesced decode")
    Assert.equal(#pushesFor(host, owner), 2, "exactly one decode follows the one source read")
    Assert.equal(pushesFor(host, owner)[2].kind, "image-derivative", "the second physical job is the decode")

    responseChannelFor(host, requestChannelIndexFor(host, owner)):push(imageDerivativeResponse(owner, path))
    Assert.equal(queue:poll(owner), "ready", "the coalesced decode publishes once")
    local decoded = queue:take(owner)
    local read = queue:take(consumer)
    Assert.equal(assert(decoded.value).kind, "image-derivative", "the decode result transfers to the owner")
    Assert.notNil(assert(read.value).payload, "the read result transfers to the compact consumer")
    Assert.equal(next(queue._decodeLeases), nil, "the dispatched decode returned exactly its own input lease")
    local decodedOwner = queue._decoded
    decodedOwner:returnLease(decoded)
    decodedOwner:returnLease(read)
    decodedOwner:returnLease(queue:take(blockerA))
    decodedOwner:returnLease(queue:take(blockerB))
    Assert.equal(decodedOwner:stats().pinnedBytes, 0, "every read and decode lease is back with the shared owner")
    queue:release()
    decodedOwner:clear()
  end)
end

-- A queued decode succession transfers the complete input: the borrowed source
-- lease and the exact Data it pins must reach the heir together.
function T.a_queued_decode_heir_receives_the_live_input_and_serves_every_follower()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = newQueue(mixedCacheFs(), { readyPayloadByteLimit = 1, workerSlots = 2 })
    local path = "pkg/generated/field/30/queued-successor.png"
    local primary = queue:request("image-derivative", path, "prefetch")
    local heir = queue:request("image-derivative", path, "prefetch")
    local follower = queue:request("image-derivative", path, "prefetch")
    local sourceIndex = assert(requestChannelIndexFor(host, primary), "the selected read dispatched")

    local filler = queue:request("mesh", "geometry/queued-successor-filler.g4mesh", "prefetch")
    responseChannelFor(host, filler):push(meshResponse(filler, "geometry/queued-successor-filler.g4mesh"))
    local busy = queue:request("mesh", "geometry/queued-successor-busy.g4mesh", "demand")
    Assert.equal(queue:poll(filler), "ready", "the ready ceiling is occupied and the second slot takes new work")
    Assert.isTrue(requestWasPushedFor(host, busy), "the second slot stays occupied")
    local input = sourceResponse(primary, path, string.rep("v", 24))
    responseChannelFor(host, sourceIndex):push(input)
    Assert.equal(queue:poll(primary), "pending", "source settlement leaves the decode queued behind the busy slot")
    local inputData = assert(queue._tokens[primary].data, "the queued primary owns its decoded input")

    queue:cancel(primary)
    Assert.equal(#pushesFor(host, heir), 0, "cancellation does not fabricate an idle worker")
    responseChannelFor(host, busy):push(meshResponse(busy, "geometry/queued-successor-busy.g4mesh"))
    Assert.equal(queue:poll(heir), "pending", "the speculative heir still respects the ready ceiling")
    queue:promote(heir, "demand")
    Assert.equal(queue:poll(heir), "pending", "the heir dispatches when a physical slot becomes free")
    local dispatched = assert(pushesFor(host, heir)[1], "the promoted heir reaches the worker")
    Assert.equal(dispatched.kind, "image-derivative", "the heir performs the shared decode")
    Assert.isTrue(dispatched.data == inputData, "the heir receives the same live Data pinned by the transferred lease")

    responseChannelFor(host, requestChannelIndexFor(host, heir)):push(imageDerivativeResponse(heir, path))
    Assert.equal(queue:poll(heir), "ready", "the heir publishes the shared result")
    Assert.equal(queue:poll(follower), "ready", "the remaining follower observes the same completion")
    Assert.isTrue(queue:take(heir).value == queue:take(follower).value, "both survivors borrow one decoded value")
    queue:take(busy)
    queue:take(filler)
    queue:release()
  end)
end

-- A worker's death never returns input bytes another, healthy worker is still
-- reading: physical decode ownership lasts until that job's own reply (which is
-- discarded without changing the failed token) or the join in release.
function T.worker_death_keeps_a_healthy_decode_input_pinned_until_release()
  local AssetPreparationQueue = requireQueue()
  local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
  local host = fakeThreadHost()
  local decoded = ResidentAssetCache.new({
    idleByteLimit = 0,
    release = function(value)
      value:release()
    end,
  })
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(diskCacheFs(), {
      decoded = decoded,
      thread = host.love.thread,
      workerSlots = 2,
    })
    local pathA = "assets/generated/field/30/pinned-a.png"
    local tokenA = queue:request("image-derivative", pathA, "demand")
    responseChannelFor(host, requestChannelIndexFor(host, tokenA)):push(
      sourceResponse(tokenA, pathA, string.rep("a", 24))
    )
    Assert.equal(queue:poll(tokenA), "pending", "the first source reply dispatches its decode")

    local pathB = "assets/generated/field/30/pinned-b.png"
    local tokenB = queue:request("image-derivative", pathB, "demand")
    local sourceB = requestChannelIndexFor(host, tokenB)
    Assert.notNil(sourceB, "the second source read takes the second slot")
    responseChannelFor(host, sourceB):push(sourceResponse(tokenB, pathB, string.rep("b", 24)))
    Assert.equal(queue:poll(tokenB), "pending", "the second source reply dispatches its decode")
    Assert.equal(#host.threads, 2, "two physical workers own two decodes")
    Assert.isTrue(decoded:stats().pinnedBytes > 0, "both dispatched decodes pin their input")

    host.threads[2]:stop("injected sibling exit")
    Assert.equal(queue:poll(tokenB), "failed", "the executor terminalizes with the stopped worker")
    Assert.isTrue(
      decoded:stats().pinnedBytes > 0,
      "the healthy worker's decode input stays pinned after its sibling died"
    )

    -- The healthy job's late reply is discarded without publishing into the
    -- shared owner, and only then does its physical lease return.
    local pinnedAfterDeath = decoded:stats().pinnedBytes
    responseChannelFor(host, requestChannelIndexFor(host, tokenA)):push(
      meshResponse(tokenA, pathA)
    )
    Assert.equal(queue:poll(tokenA), "failed", "a late result never revives a failed token")
    Assert.isTrue(
      decoded:stats().pinnedBytes < pinnedAfterDeath,
      "the late reply returns exactly its own physical input"
    )
    queue:release()
    Assert.equal(decoded:stats().pinnedBytes, 0, "the release join returns every remaining decode lease")
    Assert.equal(next(queue._decodeLeases), nil, "no borrowed decode lease survives disposal")
  end)
end

return { tests = T }
