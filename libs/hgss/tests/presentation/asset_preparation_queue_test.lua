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

-- One request/reply Channel pair per queue: the response channel for a
-- known request channel index is the other member of the pair.
local function responseChannelFor(state, requestIndex)
  Assert.equal(#state.channels, 2, "one presentation worker owns exactly one request/reply Channel pair")
  for index, channel in ipairs(state.channels) do
    if index ~= requestIndex then
      return channel
    end
  end
  error("no response channel found")
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

-- Every physical dispatch the fake worker received for one token.
---@param state table
---@param token integer
---@return table[]
local function pushesFor(state, token)
  local pushed = {}
  for _, entry in ipairs(state.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.token == token and value.path ~= nil and value.kind ~= nil then
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

return { tests = T }
