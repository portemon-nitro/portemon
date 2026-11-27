-- The game thread must observe cache readiness without producing it: version
-- selection performs no producer digest computation on the calling thread,
-- frame updates emit only bounded deduplicated request/status traffic, and
-- retirement, source replacement, failure, and shutdown all linearize on
-- explicit controller acknowledgements. Until the off-main controller lands,
-- the service surface below is absent and the current selection path still
-- computes digests inline; those are the intended reds.

local Assert = require("tests.support.Assert")
local SnapshotBootFixture = require("tests.support.SnapshotBootFixture")

local T = {}

-- Release-mode producer identity: the selection contract requires the r<int>
-- release shape (development digests are computed by the selection path the
-- first scenario observes, so the fixture carries a release identity).

-- Deterministic process-local thread host mirroring the love.thread shape:
-- FIFO channels, demand without auto-reply so the test scripts every
-- controller answer, and a killable worker to model unexpected thread death.
-- No real OS thread starts here; one focused test below uses a real thread.
local function newChannelHost()
  local channels = {}
  local function newChannel()
    local queue = {}
    local channel = {}
    function channel:push(value)
      queue[#queue + 1] = value
      return true
    end
    function channel:pop()
      if #queue == 0 then
        return nil
      end
      return table.remove(queue, 1)
    end
    function channel:demand(_)
      return table.remove(queue, 1)
    end
    function channel:count()
      return #queue
    end
    channels[#channels + 1] = { channel = channel, queue = queue }
    return channel
  end
  local threads = {}
  local function newThread(source)
    local thread = { source = source, starts = 0, waits = 0, alive = true, startArgs = {}, errorText = nil }
    function thread:start(...)
      self.starts = self.starts + 1
      self.startArgs = { ... }
      return true
    end
    function thread:wait()
      self.waits = self.waits + 1
      self.alive = false
      return true
    end
    function thread:isRunning()
      return self.alive
    end
    function thread:getError()
      return self.errorText
    end
    function thread:kill(message)
      self.alive = false
      self.errorText = message
    end
    threads[#threads + 1] = thread
    return thread
  end
  return { newChannel = newChannel, newThread = newThread, threads = threads }
end

-- The frozen behavioral surface: one process service owning a single
-- controller thread behind flat scalar request/status messages. Names the
-- missing behavior when the controller has not moved off the game thread.
local function requireService()
  local ok, service = pcall(require, "app.src.CacheService")
  Assert.isTrue(
    ok and service ~= nil and type(service.new) == "function",
    "no off-main cache service with bounded request/status protocol exists: " .. tostring(service)
  )
  return service
end

-- Test-local patch helper matching the producer suites: targets stay
-- unannotated parameters so spying on module functions needs no
-- class injection, and every replacement is restored after the run.
local function withPatched(patches, fn)
  local originals = {}
  for index, patch in ipairs(patches) do
    originals[index] = patch.target[patch.name]
    patch.target[patch.name] = patch.wrap(originals[index])
  end
  local ok, first = pcall(fn)
  for index, patch in ipairs(patches) do
    patch.target[patch.name] = originals[index]
  end
  if not ok then
    error(first, 0)
  end
  return true, first
end

-- Plumbing (may adapt to the relocated controller): select one game through
-- the current production selection path and return its provisioner. Frozen:
-- setup (a selected game), action (semantic request plus frame updates),
-- observable boundary (spy counters), expected result (zero synchronous
-- production work on the calling thread).
local function selectGameWithMilestone(spies)
  local CacheFs = require("libs.storage.src.CacheFs")
  local CompilerPool = require("romdump.src.build.CompilerPool")
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local FakeCache = require("tests.support.FakeCache")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function()
    return cacheFs
  end
  local poolUpdates = 0
  local ok, err = pcall(function()
    local pool = CompilerPool.new({ mode = "interactive" })
    local realUpdate = pool.update
    pool.update = function(self, ...)
      poolUpdates = poolUpdates + 1
      return realUpdate(self, ...)
    end
    -- Plumbing adapted to the relocated controller: selection and demand
    -- go through the service; no session or pool is pumped on this thread.
    local Service = require("app.src.CacheService")
    local service = assert(Service.new({ thread = newChannelHost() }))
    local selected = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
    local host = selected:gameHost()
    host.requestMilestone("bootstrap", "required")
    for _ = 1, 20 do
      service:update()
    end
    selected:dispose()
  end)
  CacheFs.forVersion = realForVersion
  assert(ok, err)
  spies.poolUpdates = poolUpdates
  return spies
end

function T.selection_and_frame_updates_do_no_producer_or_filesystem_work_on_the_calling_thread()
  local calls = { digest = 0, moveTree = 0, publish = 0 }
  local ok, err = withPatched({
    {
      target = require("romdump.src.ProducerFingerprint"),
      name = "compute",
      wrap = function(real)
        return function(...)
          calls.digest = calls.digest + 1
          return real(...)
        end
      end,
    },
    {
      target = require("libs.storage.src.CacheFs"),
      name = "moveTree",
      wrap = function(real)
        return function(...)
          calls.moveTree = calls.moveTree + 1
          return real(...)
        end
      end,
    },
    {
      target = require("romdump.src.build.PreparedArtifact"),
      name = "publish",
      wrap = function(real)
        return function(self, ...)
          calls.publish = calls.publish + 1
          return real(self, ...)
        end
      end,
    },
  }, function()
    return selectGameWithMilestone(calls)
  end)
  assert(ok, err)
  Assert.equal(calls.digest, 0, "selecting a version computes no producer digest on the calling thread")
  Assert.equal(calls.moveTree, 0, "frame updates publish no cache trees on the calling thread")
  Assert.equal(calls.publish, 0, "frame updates publish no prepared artifacts on the calling thread")
  Assert.equal(calls.poolUpdates, 0, "frame updates pump no pool control synchronously on the calling thread")
end

function T.repeated_host_requests_send_one_command_and_frame_updates_send_no_status_probe()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  for _ = 1, 50 do
    service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  end
  for index = 1, 3000 do
    service:request(epoch, { requestKind = "cell", matrixMemberId = 11, index = index % 7, urgency = "near" })
  end
  local emitted = service:update()
  Assert.isTrue(emitted.ordinary <= 8, "one frame emits at most eight ordinary records")
  local probes, requests = 0, 0
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "poll" then
      probes = probes + 1
    end
    if command.op == "request" then
      requests = requests + 1
    end
    command = service._command:pop()
  end
  Assert.equal(probes, 0, "thousands of deduplicated requests emit no status probe")
  Assert.isTrue(requests >= 2, "milestone and cell families still leave the game thread")
  Assert.equal(requests, emitted.ordinary, "every emitted command is a deduplicated request")
  local again = service:update()
  Assert.equal(again.ordinary, 0, "repeated pending requests send no further ensure commands")
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "an unanswered request observes no readiness")
  Assert.isNil(failure, "an unanswered request observes no failure")
  service:shutdown()
end

function T.retirement_and_import_wait_for_exact_controller_barriers()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(first, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  local barrier = assert(service:retire(first), "retirement returns its barrier identity")
  Assert.equal(service:barrierStatus(first, barrier), "pending", "retirement is not inferred from empty queues")
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  Assert.isTrue(second ~= first, "a new selection mints a fresh epoch")
  local ready = service:observe(first, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "a retired epoch grants no observation rights")
  local quiesce = assert(service:quiesce(second), "source replacement waits for quiescence")
  Assert.equal(service:barrierStatus(second, quiesce), "pending", "quiescence needs controller acknowledgement")
  local ok, _ = service:importSource(second, quiesce)
  Assert.isFalse(ok, "no import crosses an unacknowledged quiescence barrier")
end

function T.retire_then_quiesce_barriers_resolve_without_further_requests()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  local retireBarrier = assert(service:retire(epoch), "retirement returns its barrier identity")
  local quiesceBarrier = assert(service:quiesce(epoch), "quiescence follows retirement on the same epoch")
  Assert.isTrue(quiesceBarrier > retireBarrier, "barrier identities stay process-ordered")
  service:update()
  local probes = 0
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "poll" then
      probes = probes + 1
    end
    command = service._command:pop()
  end
  Assert.equal(probes, 0, "barrier waiters never earn a status probe while retiring")
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "retire" })
  service:update()
  Assert.equal(service:barrierStatus(epoch, retireBarrier), "ready", "the retirement acknowledgement lands")
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "the retirement answer never settles quiescence"
  )
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = quiesceBarrier, kind = "quiesce" })
  service:update()
  Assert.equal(service:barrierStatus(epoch, quiesceBarrier), "ready", "the quiescence acknowledgement lands")
  local ok, _ = service:importSource(epoch, quiesceBarrier)
  Assert.isTrue(ok, "an acknowledged quiescence barrier authorizes import")
end

function T.stale_barrier_answers_never_satisfy_a_newer_waiter()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  local retireBarrier = assert(service:retire(epoch), "retirement returns its barrier identity")
  local quiesceBarrier = assert(service:quiesce(epoch), "quiescence follows retirement on the same epoch")
  service:update()
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "retire" })
  service:update()
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "quiesce" })
  service:update()
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "an older barrier identity never satisfies a newer waiter"
  )
  service:update()
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = quiesceBarrier, kind = "quiesce" })
  service:update()
  Assert.equal(service:barrierStatus(epoch, quiesceBarrier), "ready", "the exact acknowledgement still lands")
end

function T.late_replies_from_a_retired_epoch_never_enter_the_new_selection()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(first, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  service:retire(first)
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  service:injectReply({ epoch = first, requestKind = "milestone", name = "bootstrap", state = "ready" })
  service:update()
  local ready, failure = service:observe(second, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "an obsolete-epoch reply authorizes no new-epoch transition")
  Assert.isNil(failure, "an obsolete-epoch reply reports no new-epoch failure")
end

function T.controller_death_fails_requests_and_shutdown_joins_exactly_once()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  assert(host.threads[1], "the service owns exactly one controller thread")
  host.threads[1]:kill("controller stopped unexpectedly")
  service:update()
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "a dead controller reports no readiness")
  Assert.isTrue(
    tostring(failure):find("controller", 1, true) ~= nil,
    "pending requests fail with the controller cause: " .. tostring(failure)
  )
  Assert.equal(host.threads[1].starts, 1, "a failed controller is never silently restarted")
  service:shutdown()
  Assert.equal(host.threads[1].waits, 1, "process shutdown joins the controller exactly once")
  service:shutdown()
  Assert.equal(host.threads[1].waits, 1, "repeated shutdown joins nothing again")
end

function T.shutdown_joins_the_controller_exactly_once()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  assert(host.threads[1], "the service owns exactly one controller thread")
  service:shutdown()
  Assert.equal(host.threads[1].waits, 1, "quit joins the controller before releasing owners")
  service:shutdown()
  Assert.equal(host.threads[1].waits, 1, "repeated shutdown joins nothing again")
end

function T.selection_answer_caches_the_controller_generation_token()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  Assert.isNil(service:generationId(epoch), "the generation is unknown before the selection answer lands")
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:injectReply({ op = "select-result", epoch = epoch, ok = true, generationId = "g4:test:token" })
  service:update()
  Assert.equal(service:generationId(epoch), "g4:test:token", "the selection answer publishes its generation token")
  service:shutdown()
end

function T.generation_token_grants_no_rights_to_stale_or_retired_epochs()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  service:injectReply({ op = "select-result", epoch = first, ok = true, generationId = "g4:test:first" })
  service:update()
  Assert.equal(service:generationId(first), "g4:test:first")
  service:retire(first)
  Assert.isNil(service:generationId(first), "a retiring epoch grants no generation rights")
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  Assert.isNil(service:generationId(second), "a fresh epoch starts with an unknown generation")
  service:injectReply({ op = "select-result", epoch = first, ok = true, generationId = "g4:test:late" })
  service:update()
  Assert.isNil(service:generationId(second), "a late answer for a retired epoch never enters the new selection")
  service:shutdown()
end

-- A semantic acquisition prefetch missed blocks the caller on the transport
-- until the controller answers instead of raising for an unrequested field.
function T.logical_field_emergency_ensure_blocks_until_the_controller_answers()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local requests, updates, answerAt = {}, 0, 3
  local service = {
    select = function()
      return 1
    end,
    request = function(_, epoch, selector)
      requests[#requests + 1] = selector.urgency
      return epoch
    end,
    observe = function()
      if updates >= answerAt then
        return true, nil
      end
      return nil, nil
    end,
    update = function()
      updates = updates + 1
      return { ordinary = 0 }
    end,
  }
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local host = provisioner:gameHost()
  Assert.isTrue(host.ensureLogicalField(48), "the emergency ensure returns once the controller answers")
  Assert.equal(updates, answerAt, "the transport is pumped until the answer arrives")
  Assert.equal(requests[1], "required", "the emergency demand is required")

  answerAt = math.huge
  service.observe = function()
    return nil, "producer failed"
  end
  local ok, err = pcall(host.ensureLogicalField, 48)
  Assert.isFalse(ok, "a controller failure still raises")
  Assert.equal(err, "producer failed", "the failure carries its cause")
end

-- A controller that holds the request without ever answering must surface as
-- a diagnosable failure, never as an endless wait on the game thread.
function T.logical_field_emergency_ensure_raises_when_the_controller_never_answers()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local updates = 0
  local service = {
    select = function()
      return 1
    end,
    request = function(_, epoch)
      return epoch
    end,
    observe = function()
      return nil, nil
    end,
    update = function()
      updates = updates + 1
      if updates > 10000000 then
        error("the emergency ensure never gave up", 0)
      end
      return { ordinary = 0 }
    end,
  }
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local host = provisioner:gameHost()
  local realSleep = love.timer.sleep
  love.timer.sleep = function() end
  local ok, err = pcall(host.ensureLogicalField, 48)
  love.timer.sleep = realSleep
  Assert.isFalse(ok, "an unanswered emergency ensure raises")
  Assert.isTrue(
    tostring(err):find("logical field 48", 1, true) ~= nil,
    "the failure names the stalled field: " .. tostring(err)
  )
end

function T.provisioner_exposes_the_selection_generation_without_scanning()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local epoch = assert(provisioner.epoch, "selection borrows an epoch")
  Assert.isNil(provisioner:generationId(), "the generation is unknown before the controller answers")
  service:injectReply({ op = "select-result", epoch = epoch, ok = true, generationId = "g4:test:token" })
  service:update()
  Assert.equal(provisioner:generationId(), "g4:test:token", "the provisioner exposes the derived token")
  provisioner:dispose()
  Assert.isNil(provisioner:generationId(), "a retired provisioner reports no generation")
  service:shutdown()
end

function T.icon_page_requests_validate_selectors_and_never_alias_portraits()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "icon-page", pageId = 3, urgency = "required" })
  service:request(epoch, { requestKind = "portrait", pageId = 3, urgency = "required" })
  service:request(epoch, { requestKind = "icon-page", pageId = 3, urgency = "near" })
  local emitted = service:update()
  Assert.equal(emitted.ordinary, 2, "icon and portrait pages keep distinct request identities")
  local iconReady, _ = service:observe(epoch, { requestKind = "icon-page", pageId = 3 })
  local portraitReady, _ = service:observe(epoch, { requestKind = "portrait", pageId = 3 })
  Assert.isNil(iconReady, "an unanswered icon request observes no readiness")
  Assert.isNil(portraitReady, "an unanswered portrait request observes no readiness")
  local badOk, _ = pcall(function()
    service:request(epoch, { requestKind = "icon-page", pageId = -1, urgency = "required" })
  end)
  Assert.isFalse(badOk, "a negative icon page is rejected")
  local kindOk, _ = pcall(function()
    service:request(epoch, { requestKind = "icon", pageId = 3, urgency = "required" })
  end)
  Assert.isFalse(kindOk, "an unlisted request kind is rejected")
  service:shutdown()
end

function T.pushed_request_completion_lands_in_the_matching_cached_observation()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  SnapshotBootFixture.installBoot(service, epoch)
  local first = assert(service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" }))
  local second =
    assert(service:request(epoch, { requestKind = "milestone", name = "field-planning", urgency = "required" }))
  service:update()
  local pending, _ = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(pending, "an unanswered request observes no readiness")
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = first,
    state = "ready",
    requiredSequence = 1,
  })
  service:update()
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isTrue(ready, "the pushed ready event lands in the matching cached observation")
  Assert.isNil(failure, "a ready observation carries no failure")
  local stillPending, _ = service:observe(epoch, { requestKind = "milestone", name = "field-planning" })
  Assert.isNil(stillPending, "an unrelated request stays pending after another request completes")
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = second,
    state = "failed",
    requiredSequence = 1,
    errorMessage = "background production failed",
  })
  service:update()
  local failedReady, failedCause = service:observe(epoch, { requestKind = "milestone", name = "field-planning" })
  Assert.isFalse(failedReady, "a failed request reports no readiness")
  Assert.isTrue(
    tostring(failedCause):find("background production failed", 1, true) ~= nil,
    "the pushed failure carries its cause: " .. tostring(failedCause)
  )
  service:shutdown()
end

function T.pushed_barrier_answers_settle_only_the_exact_waiter()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  local retireBarrier = assert(service:retire(epoch), "retirement returns its barrier identity")
  local quiesceBarrier = assert(service:quiesce(epoch), "quiescence follows retirement on the same epoch")
  Assert.equal(service:barrierStatus(epoch, retireBarrier), "pending", "retirement waits for its pushed answer")
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "retire" })
  service:update()
  Assert.equal(service:barrierStatus(epoch, retireBarrier), "ready", "the exact retirement answer lands")
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "the retirement answer never settles quiescence"
  )
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "quiesce" })
  service:update()
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "an older barrier identity never satisfies a newer waiter"
  )
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = quiesceBarrier, kind = "quiesce" })
  service:update()
  Assert.equal(service:barrierStatus(epoch, quiesceBarrier), "ready", "the exact quiescence answer lands")
  local ok, _ = service:importSource(epoch, quiesceBarrier)
  Assert.isTrue(ok, "an acknowledged quiescence barrier authorizes import")
  local again, _ = service:importSource(epoch, quiesceBarrier)
  Assert.isFalse(again, "the quiescence barrier authorizes exactly one import")
  service:shutdown()
end

function T.pushed_controller_failure_fails_pending_observations_terminally()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  service:injectReply({ op = "controller-failure", errorMessage = "cache worker exploded" })
  service:update()
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "a failed controller reports no readiness")
  Assert.isTrue(
    tostring(failure):find("cache worker exploded", 1, true) ~= nil,
    "pending observations carry the pushed failure cause: " .. tostring(failure)
  )
  Assert.isNil(
    service:request(epoch, { requestKind = "milestone", name = "field-planning", urgency = "required" }),
    "a failed controller takes no new requests"
  )
  Assert.equal(host.threads[1].starts, 1, "a failed controller is never silently restarted")
  service:shutdown()
  Assert.equal(host.threads[1].waits, 1, "process shutdown joins the controller exactly once")
end

function T.selection_generation_comes_only_from_the_selection_answer()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  SnapshotBootFixture.installBoot(service, epoch)
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  service:injectReply({ op = "select-result", epoch = epoch, ok = true, generationId = "g4:test:token" })
  service:update()
  Assert.equal(service:generationId(epoch), "g4:test:token", "the selection answer publishes its generation token")
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = 1,
    state = "ready",
    requiredSequence = 1,
    generationId = "g4:test:rotated",
  })
  service:update()
  Assert.equal(service:generationId(epoch), "g4:test:token", "request completion never rotates the token")
  service:shutdown()
end

function T.stale_pushed_results_never_enter_a_new_selection()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  local firstRequest =
    assert(service:request(first, { requestKind = "milestone", name = "bootstrap", urgency = "required" }))
  service:update()
  local firstBarrier = assert(service:retire(first), "retirement returns its barrier identity")
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  service:injectReply({ op = "select-result", epoch = second, ok = true, generationId = "g4:test:second" })
  service:update()
  service:injectReply({
    op = "request-result",
    epoch = first,
    requestId = firstRequest,
    state = "ready",
    requiredSequence = 1,
  })
  service:injectReply({ op = "barrier-result", epoch = first, barrierId = firstBarrier, kind = "retire" })
  service:injectReply({ op = "select-result", epoch = first, ok = true, generationId = "g4:test:late" })
  service:update()
  local ready, failure = service:observe(second, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "an obsolete-epoch reply authorizes no new-epoch transition")
  Assert.isNil(failure, "an obsolete-epoch reply reports no new-epoch failure")
  Assert.equal(
    service:generationId(second),
    "g4:test:second",
    "a late answer for a retired epoch never enters the new selection"
  )
  service:shutdown()
end

function T.real_controller_thread_boots_and_answers_a_selection_round()
  local realLove = rawget(_G, "love")
  assert(realLove ~= nil and realLove.thread ~= nil, "the real-thread proof requires the host runtime")
  local ok, entry = pcall(require, "romdump.src.build.CacheControllerWorker")
  Assert.isTrue(
    ok and entry ~= nil and type(entry.run) == "function",
    "no real controller thread entry exists to boot: " .. tostring(entry)
  )
  local request = realLove.thread.newChannel()
  local reply = realLove.thread.newChannel()
  local worker = realLove.thread.newThread(entry.bootstrap())
  worker:start(request, reply, package.path)
  -- Mirror production selection: development identity is derived below
  -- the worker from the repository root, never supplied as a hash.
  local sourceBase = realLove.filesystem.getSourceBaseDirectory()
  request:push({
    op = "select",
    epoch = 1,
    versionId = "heartgold",
    development = true,
    repositoryRoot = sourceBase,
  })
  -- Channel:demand takes no timeout argument, so an unbounded demand
  -- would wedge the suite forever if the worker stalls; poll boundedly
  -- and attribute a timeout with the worker's own error instead.
  local timer = realLove.timer
  local deadline = timer.getTime() + 60
  local answer = nil
  while answer == nil and timer.getTime() < deadline and worker:isRunning() do
    answer = reply:pop()
    if answer == nil then
      timer.sleep(0.05)
    end
  end
  Assert.notNil(answer, "the booted controller answers its selection round: " .. tostring(worker:getError()))
  assert(type(answer) == "table", "the booted controller answers its selection round")
  Assert.isTrue(answer.epoch == 1, "the booted controller answers its selection round")
  Assert.isTrue(answer.ok == true, "development selection succeeds: " .. tostring(answer.errorMessage))
  request:push({ op = "shutdown", epoch = 1 })
  worker:wait()
  Assert.isFalse(worker:isRunning(), "the controller exits on shutdown")
end

-- A cry bank demand travels the selected-game host into one epoch-qualified
-- worker request that carries its bank id; malformed ids never leave the
-- game thread.
-- The single bounded editor presentation demand travels the selected-game
-- host into one selector-free worker request: urgency alone rides the
-- registered global job, and extras or malformed urgencies never leave
-- the game thread.
function T.easy_chat_demands_reach_the_worker_without_selectors()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local gameHost = provisioner:gameHost()
  local ready, failure = gameHost.requestEasyChat("required")
  Assert.isNil(ready, "an unbuilt editor observes no readiness")
  Assert.isNil(failure, "an unbuilt editor observes no failure")
  Assert.isFalse(pcall(gameHost.requestEasyChat, "soon", "required"), "malformed urgencies stay on the game thread")
  service:update()
  local found = nil
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" and command.requestKind == "easy-chat" then
      found = command
    end
    command = service._command:pop()
  end
  Assert.notNil(found, "the editor demand reaches the worker channel")
  Assert.equal(found.urgency, "required", "the request carries its urgency")
  Assert.isNil(found.pageId, "the selector-free demand carries no page selector")
  service:shutdown()
end

function T.audio_bank_demands_reach_the_worker_with_their_bank()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local gameHost = provisioner:gameHost()
  local ready, failure = gameHost.requestAudioBank(158, "required")
  Assert.isNil(ready, "an unbuilt bank observes no readiness")
  Assert.isNil(failure, "an unbuilt bank observes no failure")
  Assert.isFalse(pcall(gameHost.requestAudioBank, -1, "required"), "malformed bank ids stay on the game thread")
  service:update()
  local found = nil
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" and command.requestKind == "audio-bank" then
      found = command
    end
    command = service._command:pop()
  end
  Assert.notNil(found, "the bank demand reaches the worker channel")
  Assert.equal(found.bankId, 158, "the request carries its bank id")
  service:shutdown()
end

-- One battle scene demand travels the selected-game host into a single
-- epoch-qualified worker request: repeated visits share its identity, a
-- stronger urgency promotes it instead of duplicating it, a different
-- time/terrain key stays a distinct job, and malformed keys never leave
-- the game thread. Portrait pages keep their own identities throughout.
function T.scene_demands_dedupe_by_key_and_epoch_with_urgency_promotion()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local epoch = assert(provisioner.epoch, "selection borrows an epoch")
  SnapshotBootFixture.installBoot(service, epoch)
  local gameHost = provisioner:gameHost()
  Assert.isTrue(type(gameHost.requestBattleScene) == "function", "the selected-game host demands its battle scene")
  local day = "general/grass/day"
  local night = "general/grass/night"
  local pending, pendingErr = gameHost.requestBattleScene(day, "near")
  Assert.isNil(pending, "an unbuilt scene observes no readiness")
  Assert.isNil(pendingErr, "an unbuilt scene observes no failure")
  local promoted, promotedErr = gameHost.requestBattleScene(day, "required")
  Assert.isNil(promoted, "a promoted scene still observes no readiness")
  Assert.isNil(promotedErr, "a promoted scene still observes no failure")
  local otherPending, otherErr = gameHost.requestBattleScene(night, "required")
  Assert.isNil(otherPending, "a different time stays its own pending demand")
  Assert.isNil(otherErr, "a different time stays its own pending demand")
  service:request(epoch, { requestKind = "portrait", pageId = 3, urgency = "required" })
  service:update()
  local sceneCommands, portraitCommands = 0, 0
  local dayUrgency = nil
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" then
      if command.requestKind == "battle-scene" then
        sceneCommands = sceneCommands + 1
        if command.sceneKey == day then
          dayUrgency = command.urgency
        end
        Assert.isTrue(command.pageId == nil, "a scene command carries no portrait page: " .. tostring(command.sceneKey))
      elseif command.requestKind == "portrait" then
        portraitCommands = portraitCommands + 1
      end
    end
    command = service._command:pop()
  end
  Assert.equal(sceneCommands, 2, "day and night leave exactly one worker request each")
  Assert.equal(dayUrgency, "required", "the stronger urgency promotes the shared day request")
  Assert.equal(portraitCommands, 1, "the portrait page keeps its own request identity")
  local dayId =
    assert(service._byKey[tostring(epoch) .. ":battle-scene:" .. day], "the day demand registers its selector identity")
  local nightId = assert(
    service._byKey[tostring(epoch) .. ":battle-scene:" .. night],
    "the night demand registers its selector identity"
  )
  Assert.isTrue(dayId ~= nightId, "different scene keys never share a request identity")
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = dayId,
    state = "ready",
    requiredSequence = 1,
  })
  service:update()
  local ready, failure = gameHost.requestBattleScene(day, "required")
  Assert.isTrue(ready, "the pushed ready event lands in the matching scene observation")
  Assert.isNil(failure, "a ready scene carries no failure")
  local stillPending, _ = gameHost.requestBattleScene(night, "required")
  Assert.isNil(stillPending, "the night demand stays pending after the day completes")
  for _, badKey in ipairs({ "", "general", "general/grass", "general/grass/day/extra", "//", 7 }) do
    local ok, _ = pcall(function()
      gameHost.requestBattleScene(badKey, "required")
    end)
    Assert.isFalse(ok, "a malformed scene key never leaves the game thread: " .. tostring(badKey))
  end
  provisioner:dispose()
  service:shutdown()
end

-- A genuine scene build failure reports its producer cause through the
-- same observation, and a retired epoch can never satisfy a new
-- selection: a late ready for the old request leaves the reselected scene
-- pending instead of painting stale pixels.
function T.scene_failure_and_stale_epoch_never_read_ready()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local firstEpoch = assert(provisioner.epoch, "selection borrows an epoch")
  SnapshotBootFixture.installBoot(service, firstEpoch)
  local gameHost = provisioner:gameHost()
  Assert.isTrue(type(gameHost.requestBattleScene) == "function", "the selected-game host demands its battle scene")
  local key = "city/sand/night"
  local pending, pendingErr = gameHost.requestBattleScene(key, "required")
  Assert.isNil(pending, "an unbuilt scene observes no readiness")
  Assert.isNil(pendingErr, "an unbuilt scene observes no failure")
  local id = assert(service._byKey[tostring(firstEpoch) .. ":battle-scene:" .. key], "the scene demand registers")
  service:update()
  service:injectReply({
    op = "request-result",
    epoch = firstEpoch,
    requestId = id,
    state = "failed",
    requiredSequence = 1,
    errorMessage = "probe source read failed",
  })
  service:update()
  local failedReady, failure = gameHost.requestBattleScene(key, "required")
  Assert.isFalse(failedReady, "a failed scene reports no readiness")
  Assert.isTrue(
    tostring(failure):find("probe source read failed", 1, true) ~= nil,
    "the failed scene carries its producer cause: " .. tostring(failure)
  )
  provisioner:dispose()
  local reselected = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local secondEpoch = assert(reselected.epoch, "reselection borrows a fresh epoch")
  Assert.isTrue(secondEpoch ~= firstEpoch, "reselection mints a fresh epoch")
  local freshHost = reselected:gameHost()
  local freshPending, freshErr = freshHost.requestBattleScene(key, "required")
  Assert.isNil(freshPending, "the reselected scene starts pending")
  Assert.isNil(freshErr, "the reselected scene starts without failure")
  service:injectReply({
    op = "request-result",
    epoch = firstEpoch,
    requestId = id,
    state = "ready",
    requiredSequence = 1,
  })
  service:update()
  local staleReady, staleErr = freshHost.requestBattleScene(key, "required")
  Assert.isNil(staleReady, "a retired-epoch ready never satisfies the new selection")
  Assert.isNil(staleErr, "a retired-epoch ready reports no new-epoch failure")
  reselected:dispose()
  service:shutdown()
end

-- One trainer picture, one ball, and the evolution bundle travel the
-- selected-game host as exact semantic demands: repeated visits share one
-- worker identity, promotion strengthens it, a different selector stays
-- distinct, and malformed selectors never leave the game thread. The
-- selector-free evolution demand carries urgency alone, and no leaf
-- selector ever rides the shared battle demand.
function T.selective_battle_leaf_demands_route_by_exact_selector()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  SnapshotBootFixture.installBoot(service, epoch)
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestBattleTrainerPicture) == "function",
    "the selected-game host demands one trainer picture per encounter"
  )
  Assert.isTrue(type(gameHost.requestBattleBall) == "function", "the selected-game host demands one ball per encounter")
  Assert.isTrue(
    type(gameHost.requestBattleEvolution) == "function",
    "the selected-game host demands evolution only when scheduled"
  )
  local pending, pendingErr = gameHost.requestBattleTrainerPicture("front:YOUNGSTER", "near")
  Assert.isNil(pending, "an unbuilt trainer picture observes no readiness")
  Assert.isNil(pendingErr, "an unbuilt trainer picture observes no failure")
  local promoted, promotedErr = gameHost.requestBattleTrainerPicture("front:YOUNGSTER", "required")
  Assert.isNil(promoted, "a promoted trainer picture still observes no readiness")
  Assert.isNil(promotedErr, "a promoted trainer picture still observes no failure")
  local firstOk, firstId = pcall(service.request, service, epoch, {
    requestKind = "battle-trainer-picture",
    trainerSelector = "front:YOUNGSTER",
    urgency = "near",
  })
  Assert.isTrue(firstOk and type(firstId) == "number", "one trainer demand registers its worker identity")
  local secondOk, secondId = pcall(service.request, service, epoch, {
    requestKind = "battle-trainer-picture",
    trainerSelector = "front:YOUNGSTER",
    urgency = "required",
  })
  Assert.isTrue(secondOk, "urgency promotion keeps the shared trainer demand")
  Assert.equal(secondId, firstId, "promotion strengthens the shared demand instead of duplicating it")
  local ballOk, ballId = pcall(service.request, service, epoch, {
    requestKind = "battle-ball",
    ballSelector = "ball:POKE_BALL",
    urgency = "required",
  })
  Assert.isTrue(ballOk and ballId ~= firstId, "a ball demand keeps its own worker identity")
  local evolutionOk, evolutionId = pcall(service.request, service, epoch, {
    requestKind = "battle-evolution",
    urgency = "required",
  })
  Assert.isTrue(evolutionOk and evolutionId ~= firstId, "evolution keeps its own worker identity")
  local unsourcedOk, unsourcedId = pcall(service.request, service, epoch, {
    requestKind = "battle-trainer-picture",
    trainerSelector = "front:NOT_A_CLASS",
    urgency = "required",
  })
  Assert.isTrue(
    unsourcedOk and unsourcedId ~= firstId,
    "a well-formed but unsourced selector still dispatches for the producer to validate"
  )
  for _, badSelector in ipairs({ "", "YOUNGSTER", "front:lower!", "front:a/b", 7 }) do
    local ok, _ = pcall(function()
      gameHost.requestBattleTrainerPicture(badSelector, "required")
    end)
    Assert.isFalse(ok, "a malformed trainer selector never leaves the game thread: " .. tostring(badSelector))
  end
  for _, badSelector in ipairs({ "", "POKE_BALL", "ball:lower!", "ball:a/b", 7 }) do
    local ok, _ = pcall(function()
      gameHost.requestBattleBall(badSelector, "required")
    end)
    Assert.isFalse(ok, "a malformed ball selector never leaves the game thread: " .. tostring(badSelector))
  end
  local missingOk = pcall(service.request, service, epoch, {
    requestKind = "battle-trainer-picture",
    urgency = "required",
  })
  Assert.isFalse(missingOk, "a trainer demand without its selector never leaves the game thread")
  local foreignOk = pcall(service.request, service, epoch, {
    requestKind = "battle-trainer-picture",
    trainerSelector = "front:YOUNGSTER",
    urgency = "near",
    sceneKey = "general/grass/day",
  })
  Assert.isFalse(foreignOk, "a scene selector never rides a trainer demand")
  local evolutionForeignOk = pcall(service.request, service, epoch, {
    requestKind = "battle-evolution",
    urgency = "near",
    trainerSelector = "front:YOUNGSTER",
  })
  Assert.isFalse(evolutionForeignOk, "evolution carries no trainer selector")
  local sharedStrayOk = pcall(service.request, service, epoch, {
    requestKind = "battle-presentation",
    urgency = "near",
    trainerSelector = "front:YOUNGSTER",
  })
  Assert.isFalse(sharedStrayOk, "a trainer selector never rides the shared battle demand")
  service:update()
  local trainerCommands, ballCommands, evolutionCommands = 0, 0, 0
  local trainerSeen = {}
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "request" then
      if command.requestKind == "battle-trainer-picture" then
        trainerCommands = trainerCommands + 1
        trainerSeen[command.trainerSelector] = command.urgency
        Assert.isTrue(command.sceneKey == nil, "a trainer command carries no scene selector")
        Assert.isTrue(command.ballSelector == nil, "a trainer command carries no ball selector")
      elseif command.requestKind == "battle-ball" then
        ballCommands = ballCommands + 1
        Assert.equal(command.ballSelector, "ball:POKE_BALL", "the ball command carries its ball selector")
      elseif command.requestKind == "battle-evolution" then
        evolutionCommands = evolutionCommands + 1
        Assert.isTrue(command.trainerSelector == nil, "an evolution command carries no trainer selector")
        Assert.isTrue(command.ballSelector == nil, "an evolution command carries no ball selector")
      end
    end
    command = service._command:pop()
  end
  Assert.equal(trainerCommands, 2, "two trainer selectors leave exactly two worker requests")
  Assert.equal(trainerSeen["front:YOUNGSTER"], "required", "the stronger urgency promotes the shared trainer demand")
  Assert.equal(
    trainerSeen["front:NOT_A_CLASS"],
    "required",
    "the unsourced selector dispatches with its exact spelling"
  )
  Assert.equal(ballCommands, 1, "one ball selector leaves exactly one worker request")
  Assert.equal(evolutionCommands, 1, "evolution leaves exactly one worker request")
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = firstId,
    state = "ready",
    requiredSequence = 1,
  })
  service:update()
  local ready, failure = gameHost.requestBattleTrainerPicture("front:YOUNGSTER", "required")
  Assert.isTrue(ready, "the pushed ready event lands in the matching trainer observation")
  Assert.isNil(failure, "a ready trainer picture carries no failure")
  local stillPending, _ = gameHost.requestBattleBall("ball:POKE_BALL", "required")
  Assert.isNil(stillPending, "the ball demand stays pending after the trainer completes")
  provisioner:dispose()
  service:shutdown()
end

-- A missing selected audio bank reports its producer failure instead of
-- reading silently ready: pending stays pending until the worker answers.
function T.missing_selected_audio_bank_fails_instead_of_staying_silent()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  SnapshotBootFixture.installBoot(service, epoch)
  local gameHost = provisioner:gameHost()
  local pending, pendingErr = gameHost.requestAudioBank(999, "required")
  Assert.isNil(pending, "an unbuilt bank observes no readiness")
  Assert.isNil(pendingErr, "an unbuilt bank observes no failure")
  local ok, id = pcall(service.request, service, epoch, {
    requestKind = "audio-bank",
    bankId = 999,
    urgency = "required",
  })
  Assert.isTrue(ok and type(id) == "number", "the selected bank registers its worker identity")
  service:update()
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = id,
    state = "failed",
    requiredSequence = 1,
    errorMessage = "probe bank read failed",
  })
  service:update()
  local failedReady, bankFailure = gameHost.requestAudioBank(999, "required")
  Assert.isFalse(failedReady, "a failed bank never reads ready")
  Assert.isTrue(
    tostring(bankFailure):find("probe bank read failed", 1, true) ~= nil,
    "the failed bank carries its producer cause: " .. tostring(bankFailure)
  )
  provisioner:dispose()
  service:shutdown()
end

-- A retired selection grants leaf demands no rights: trainer, ball, and
-- evolution requests for the retired epoch register nothing, observe
-- nothing, and queue no worker traffic, so stale interest can never
-- complete a newer selection.
function T.retired_epochs_grant_battle_leaf_demands_no_rights()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  provisioner:dispose()
  Assert.isNil(
    service:request(epoch, {
      requestKind = "battle-trainer-picture",
      trainerSelector = "front:YOUNGSTER",
      urgency = "required",
    }),
    "a retired trainer demand registers no worker identity"
  )
  Assert.isNil(
    service:request(epoch, { requestKind = "battle-ball", ballSelector = "ball:POKE_BALL", urgency = "required" }),
    "a retired ball demand registers no worker identity"
  )
  Assert.isNil(
    service:request(epoch, { requestKind = "battle-evolution", urgency = "required" }),
    "a retired evolution demand registers no worker identity"
  )
  local retiredOk, retiredErr = pcall(gameHost.requestBattleTrainerPicture, "front:YOUNGSTER", "required")
  Assert.isFalse(retiredOk, "a retired trainer demand rejects instead of observing")
  Assert.isTrue(
    type(retiredErr) == "table" and retiredErr.code == "DERIVED_ASSETS_RETIRED",
    "the rejection carries the retirement identity"
  )
  local retiredBallOk = pcall(gameHost.requestBattleBall, "ball:POKE_BALL", "required")
  Assert.isFalse(retiredBallOk, "a retired ball demand rejects instead of observing")
  local retiredEvolutionOk = pcall(gameHost.requestBattleEvolution, "required")
  Assert.isFalse(retiredEvolutionOk, "a retired evolution demand rejects instead of observing")
  service:update()
  local command = service._command:pop()
  while command ~= nil do
    Assert.isTrue(command.op ~= "request", "a retired leaf demand queues no worker traffic")
    command = service._command:pop()
  end
  service:shutdown()
end

-- A validated import hands its one immutable source buffer to the
-- controller exactly once for the live epoch: the game thread never
-- opens the ROM itself, the same userdata crosses the channel by
-- reference, and stale or retired epochs queue nothing.
function T.validated_source_offer_reaches_the_controller_once_for_the_live_epoch()
  local Service = requireService()
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  Assert.equal(
    type(service.offerSource),
    "function",
    "the process service accepts a validated source handoff for the live epoch"
  )
  local buffer = hostLove.data.newByteData("synthetic-offer-bytes")
  local descriptor = { versionId = "heartgold", romSha1 = string.rep("0", 40) }
  service:offerSource(epoch, buffer, descriptor)
  -- Lifecycle controls flush FIFO on update: the offer waits behind
  -- selection instead of overtaking it, then crosses exactly once.
  service:update()
  local offers = {}
  local command = service._command:pop()
  while command ~= nil do
    if type(command) == "table" and command.byteData == buffer then
      offers[#offers + 1] = command
    end
    command = service._command:pop()
  end
  Assert.equal(#offers, 1, "the live-epoch offer crosses to the controller exactly once")
  Assert.equal(offers[1].epoch, epoch, "the offer carries its selecting epoch")
  Assert.isTrue(offers[1].byteData == buffer, "the offer hands off the identical buffer by reference")
  pcall(function()
    service:offerSource(epoch + 100, buffer, descriptor)
  end)
  service:update()
  local stale = service._command:pop()
  while stale ~= nil do
    Assert.isFalse(
      type(stale) == "table" and stale.byteData == buffer,
      "an offer for an unknown epoch never reaches the controller"
    )
    stale = service._command:pop()
  end
  service:retire(epoch)
  pcall(function()
    service:offerSource(epoch, buffer, descriptor)
  end)
  service:update()
  local retired = service._command:pop()
  while retired ~= nil do
    Assert.isFalse(type(retired) == "table" and retired.byteData == buffer, "no source offer queues after retirement")
    retired = service._command:pop()
  end
  service:shutdown()
end

-- An imported source and its boot gate travel the same ordered control
-- stream as selection: one service update flushes select, the validated
-- offer, and the boot check FIFO before ordinary demand, the live
-- controller observes them in that order, the identical offered buffer is
-- pinned, and a retired epoch can never satisfy a newer selection.
function T.ordered_import_offer_and_boot_gate_share_one_control_stream()
  local Service = requireService()
  local Worker = require("romdump.src.build.CacheControllerWorker")
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local worker = Worker.Worker.new(service._command, service._reply)
  local epoch = assert(service:select({ versionId = "heartgold" }))
  local buffer = hostLove.data.newByteData("synthetic-offer-bytes")
  local info = GameVersion.info("heartgold")
  service:offerSource(epoch, buffer, { versionId = "heartgold", romSha1 = info.sha1 })
  Assert.equal(
    service._command:count(),
    0,
    "selection and its source offer wait for one ordered flush instead of overtaking it"
  )
  Assert.isTrue(
    type(service.requestBootSource) == "function",
    "the boot gate queues behind selection and any source offer on the same control stream"
  )
  Assert.isTrue(
    type(service.bootSourceStatus) == "function",
    "the boot gate reports its epoch-scoped readiness without filesystem work"
  )
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  Assert.isTrue(service:requestBootSource(epoch), "a duplicate gate for the live epoch stays idempotent")
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  local emitted = service:update()
  Assert.isTrue(emitted.ordinary >= 1, "the milestone demand leaves on the same update")
  local seen = {}
  local realHandle = worker._handle
  worker._handle = function(self, command)
    if type(command) == "table" and type(command.op) == "string" then
      seen[#seen + 1] = command.op
    end
    return realHandle(self, command)
  end
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function(_)
    return realForVersion("heartgold", backend)
  end
  local realThread = hostLove.thread
  hostLove.thread = {
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
  local stepOk, stepErr = pcall(function()
    worker:step()
  end)
  hostLove.thread = realThread
  CacheFs.forVersion = realForVersion
  assert(stepOk, stepErr)
  service:update()
  Assert.equal(#seen, 4, "the controller observes select, offer, gate, then demand")
  Assert.equal(seen[1], "select", "selection reaches the controller first")
  Assert.equal(seen[2], "offer-source", "the validated offer never overtakes its selection")
  Assert.equal(seen[3], "check-boot-source", "the boot gate never overtakes its offer")
  Assert.equal(seen[4], "request", "ordinary demand follows the lifecycle controls")
  local pool = assert(worker.pool, "the selection owns its compiler pool")
  local held = pool.sharedSource
  local heldBuffer = type(held) == "table" and held.byteData or held
  Assert.isTrue(heldBuffer == buffer, "the gate pins the identical offered buffer by reference")
  local status, _ = service:bootSourceStatus(epoch)
  Assert.equal(status, "ready", "the offered buffer satisfies the boot gate")
  service:retire(epoch)
  Assert.isNil(service:bootSourceStatus(epoch), "a retiring epoch reports no boot observation")
  local nextEpoch = assert(service:select({ versionId = "heartgold" }))
  service:injectReply({ op = "boot-source-result", epoch = epoch, state = "ready" })
  service:update()
  Assert.equal(service:bootSourceStatus(nextEpoch), "pending", "a late retired answer never satisfies a new selection")
  service:shutdown()
  pcall(function()
    if worker.pool ~= nil then
      worker.pool:shutdown()
    end
  end)
end

-- A duplicate boot gate for the live epoch queues nothing twice, while
-- stale and retired epochs queue nothing at all: one update carries
-- exactly one boot check behind selection.
function T.duplicate_boot_gate_queues_once_and_stale_epochs_queue_nothing()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold" }))
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  Assert.isTrue(service:requestBootSource(epoch), "a duplicate gate stays idempotent")
  Assert.isNil(service:requestBootSource(epoch + 100), "an unknown epoch queues no gate")
  service:update()
  local gates = 0
  local command = service._command:pop()
  while command ~= nil do
    if type(command) == "table" and command.op == "check-boot-source" then
      gates = gates + 1
      Assert.equal(command.epoch, epoch, "the gate carries its selecting epoch")
    end
    command = service._command:pop()
  end
  Assert.equal(gates, 1, "one update carries exactly one boot check")
  service:retire(epoch)
  Assert.isNil(service:requestBootSource(epoch), "a retiring epoch queues no gate")
  service:shutdown()
end

-- A refused source offer fails the epoch boot observation with its cause,
-- and no later gate answer can clear it: a failure never masquerades as
-- ready, while a foreign-epoch answer touches no live state.
function T.rejected_offer_fails_the_boot_gate_permanently()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold" }))
  Assert.isTrue(service:requestBootSource(epoch), "the live epoch queues its boot gate")
  service:injectReply({ op = "offer-source-result", epoch = epoch, ok = false, errorMessage = "stale bytes" })
  service:update()
  local status, detail = service:bootSourceStatus(epoch)
  Assert.equal(status, "failed", "a refused offer fails the boot gate")
  Assert.equal(detail.code, "SOURCE_OFFER_REJECTED", "the refusal carries its typed cause")
  service:injectReply({ op = "boot-source-result", epoch = epoch, state = "ready" })
  service:update()
  local later, _ = service:bootSourceStatus(epoch)
  Assert.equal(later, "failed", "a later success never clears a refused offer")
  service:injectReply({ op = "boot-source-result", epoch = epoch + 100, state = "ready" })
  service:update()
  local foreign, __ = service:bootSourceStatus(epoch)
  Assert.equal(foreign, "failed", "a foreign-epoch answer touches no live state")
  service:shutdown()
end

-- The generated corpus a selected epoch compiles lives in memory: the
-- controller installs bytes (and the small completion facts) through ordered
-- packets, and the game thread exposes one stable reader only once the
-- installation commit has landed. These records name only the locked
-- transport, so a service that still mirrors scalar readiness has no reader to
-- hand out.

local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")

local function probeIdentity()
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  return assert(DerivedCacheState.currentForSelection({
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    producerId = "r7",
  }))
end

local function residentEntry(identity, path, text)
  return {
    path = path,
    data = assert(hostLove.data.newByteData(text), "the probe needs a real Data buffer"),
    size = #text,
    sourceId = "base:" .. identity.generationId,
    contentId = identity.generationId .. "\0" .. path,
  }
end

-- One installation sequence as the controller publishes it: private begin,
-- bounded entry parts, then the commit carrying only the small semantic facts.
local function pushInstallation(service, spec)
  service:injectReply({
    op = "cache-install-begin",
    epoch = spec.epoch,
    generationId = spec.identity.generationId,
    sequence = spec.sequence,
    initial = spec.initial == true,
    identity = spec.identity,
    entryCount = #spec.entries,
  })
  local part, index = 1, 1
  while index <= #spec.entries do
    local slice = {}
    for position = index, math.min(index + 127, #spec.entries) do
      slice[#slice + 1] = spec.entries[position]
    end
    service:injectReply({
      op = "cache-install-entries",
      epoch = spec.epoch,
      generationId = spec.identity.generationId,
      sequence = spec.sequence,
      part = part,
      entries = slice,
    })
    index = index + #slice
    part = part + 1
  end
  service:injectReply({
    op = "cache-install-commit",
    epoch = spec.epoch,
    generationId = spec.identity.generationId,
    sequence = spec.sequence,
    milestones = spec.milestones or {},
    firstPlay = spec.firstPlay == true,
    complete = spec.complete == true,
  })
end

local function requireInstalledReader(service, epoch)
  Assert.isTrue(
    type(service.getCacheFs) == "function",
    "the service hands out no installed generated reader, so gameplay reads physical generated files"
  )
  local reader = service:getCacheFs(epoch)
  Assert.notNil(reader, "an installed epoch exposes one stable generated reader")
  Assert.isTrue(service:getCacheFs(epoch) == reader, "the epoch's reader is one stable view across frames")
  return reader
end

-- A bounded wait on a real channel: a missing packet must fail the record
-- instead of parking the whole run.
local function awaitValue(channel, seconds)
  local deadline = hostLove.timer.getTime() + (seconds or 10)
  while hostLove.timer.getTime() < deadline do
    local value = channel:pop()
    if value ~= nil then
      return value
    end
    hostLove.timer.sleep(0.002)
  end
  return nil
end

-- Stop a test-owned Lua state without ever joining it unconditionally: a
-- publisher parked on its gate would otherwise park the run with it.
local function stopThread(thread)
  for _ = 1, 400 do
    if not thread:isRunning() then
      return
    end
    hostLove.timer.sleep(0.005)
  end
  thread:kill("the recording publisher did not stop")
  thread:wait()
end

-- A terminal observation carries the sequence whose bytes it vouches for.
-- Until that sequence is installed the game thread observes nothing, and once
-- it is installed the reader lends the very buffers the controller published.
function T.an_observation_waits_for_installed_bytes_and_the_reader_shares_them()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  local identity = probeIdentity()
  local scene = residentEntry(identity, "data/generated/field/30/scene.lua", "return { mapId = 30 }\n")
  local atlas = residentEntry(identity, "assets/generated/field/30/atlas.png", "PNGDATA")
  local requestId =
    assert(service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" }))
  service:update()

  -- The controller's terminal answer for the second publication arrives before
  -- the bytes it refers to have been installed on this thread.
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = requestId,
    state = "ready",
    requiredSequence = 2,
  })
  pushInstallation(service, {
    epoch = epoch,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = { scene },
    milestones = { "bootstrap" },
  })
  service:update()
  local early = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(early, "a terminal observation never outruns the bytes it requires")

  -- The installation the observation waited for: one more entry, and the fact
  -- that first play is now recorded for that same captured sequence.
  pushInstallation(service, {
    epoch = epoch,
    identity = identity,
    sequence = 2,
    entries = { atlas },
    milestones = { "bootstrap" },
    firstPlay = true,
  })
  service:update()
  local ready = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isTrue(ready, "the buffered observation lands once its sequence is installed")

  local reader = requireInstalledReader(service, epoch)
  local borrowed = assert(reader:readData(atlas.path), "the installed reader lends the freshly installed bytes")
  Assert.isTrue(borrowed == atlas.data, "the reader lends the published buffer rather than a serialized copy")
  Assert.equal(borrowed:getString(), "PNGDATA", "the lent buffer carries the committed payload")
  local resolved = assert(reader:resolveAsset(scene.path), "the installed reader resolves the earlier entry")
  Assert.equal(resolved.size, scene.size, "the resolved reference reports the payload size")
  Assert.isTrue(reader:readData(scene.path) == scene.data, "earlier entries keep lending their own buffers")

  local identitySeen = service:cacheIdentity(epoch)
  Assert.notNil(identitySeen, "the installed epoch exposes its full cache identity")
  Assert.deepEqual(identitySeen, identity, "the installed identity is the controller's generation identity")
  Assert.isTrue(service:firstPlayReady(epoch), "first play is only reported after its captured closure installed")
  local duplicated = service:recordFirstPlay(epoch)
  Assert.isTrue(duplicated ~= false, "recording an already recorded first play stays a no-op")
  service:retire(epoch)
  Assert.isNil(service:getCacheFs(epoch), "a retired epoch hands out no reader")
  Assert.isNil(service:cacheIdentity(epoch), "a retired epoch exposes no identity")
  Assert.equal(borrowed:getString(), "PNGDATA", "blocks a consumer already borrowed stay readable after retirement")
  service:shutdown()
end

-- A terminal observation is a protocol fact: it names the installation
-- sequence whose bytes and facts it attests. One that omits the sequence can
-- never stand in for an installed stream, so it is a protocol violation
-- instead of an instantly exposed readiness.
function T.a_terminal_observation_without_its_sequence_is_a_protocol_violation()
  local Service = requireService()
  local service = assert(Service.new({ thread = newChannelHost() }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  SnapshotBootFixture.installBoot(service, epoch)
  local requestId = assert(service:request(epoch, {
    requestKind = "milestone",
    name = "bootstrap",
    urgency = "required",
  }))
  service:update()
  service:injectReply({ op = "request-result", epoch = epoch, requestId = requestId, state = "ready" })
  Assert.throws(function()
    service:update()
  end, "a terminal observation without its installation sequence is a protocol violation")
  service:shutdown()
end

-- A sequence is a stream position, not a count of entries: a fresh empty
-- installation establishes sequence 1 with no payload at all, and a hydrated
-- snapshot may open the stream at any later sequence and continue from there.
-- A zero-file job settles through its completion fact alone, and a gap is a
-- protocol violation rather than a miss.
function T.installation_sequences_open_empty_or_from_a_hydrated_snapshot()
  local Service = requireService()
  local identity = probeIdentity()
  local empty = assert(Service.new({ thread = newChannelHost() }))
  local emptyEpoch = assert(empty:select({ versionId = "heartgold", development = true }))
  local emptyRequest = assert(empty:request(emptyEpoch, {
    requestKind = "milestone",
    name = "bootstrap",
    urgency = "required",
  }))
  empty:update()
  empty:injectReply({
    op = "request-result",
    epoch = emptyEpoch,
    requestId = emptyRequest,
    state = "ready",
    requiredSequence = 1,
  })
  pushInstallation(empty, {
    epoch = emptyEpoch,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = {},
    milestones = { "bootstrap" },
  })
  empty:update()
  Assert.isTrue(
    empty:observe(emptyEpoch, { requestKind = "milestone", name = "bootstrap" }),
    "a job with no payload settles through its completion fact"
  )
  local emptyReader = requireInstalledReader(empty, emptyEpoch)
  Assert.isNil(
    emptyReader:resolveAsset("data/generated/field/30/scene.lua"),
    "an empty installation exposes an empty store, not a missing reader"
  )
  empty:shutdown()

  -- A second selection starts from a snapshot this process did not write.
  local reloaded = assert(Service.new({ thread = newChannelHost() }))
  local epoch = assert(reloaded:select({ versionId = "heartgold", development = true }))
  local scene = residentEntry(identity, "data/generated/field/40/scene.lua", "hydrated")
  local requestId = assert(reloaded:request(epoch, {
    requestKind = "milestone",
    name = "bootstrap",
    urgency = "required",
  }))
  reloaded:update()
  pushInstallation(reloaded, {
    epoch = epoch,
    identity = identity,
    sequence = 42,
    initial = true,
    entries = { scene },
    milestones = { "bootstrap" },
  })
  reloaded:update()
  Assert.isTrue(
    reloaded:observe(epoch, { requestKind = "milestone", name = "bootstrap" }),
    "a hydrated snapshot's own sequence satisfies the observations it captured"
  )
  local reader = requireInstalledReader(reloaded, epoch)
  Assert.equal(reader:readData(scene.path):getString(), "hydrated", "the hydrated payload is readable in place")
  local resumed = residentEntry(identity, "data/generated/field/40/actors.lua", "compiled")
  reloaded:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = requestId,
    state = "ready",
    requiredSequence = 43,
  })
  pushInstallation(reloaded, {
    epoch = epoch,
    identity = identity,
    sequence = 43,
    entries = { resumed },
    milestones = { "bootstrap" },
  })
  reloaded:update()
  Assert.equal(
    reader:readData(resumed.path):getString(),
    "compiled",
    "the stream continues at the hydrated sequence instead of restarting"
  )

  pushInstallation(reloaded, {
    epoch = epoch,
    identity = identity,
    sequence = 45,
    entries = {},
  })
  Assert.throws(function()
    reloaded:update()
  end, "an out-of-order installation sequence is a protocol violation, not an ordinary miss")
  reloaded:shutdown()
end

-- The installation stream is a protocol, not a hint: an identical replay of an
-- already installed part changes nothing, while a differently addressed part
-- with the same identity is a programming error instead of a silent overwrite.
function T.a_duplicate_part_must_match_the_installed_bytes()
  local Service = requireService()
  local service = assert(Service.new({ thread = newChannelHost() }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  local identity = probeIdentity()
  local scene = residentEntry(identity, "data/generated/field/30/scene.lua", "stable")
  pushInstallation(service, {
    epoch = epoch,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = { scene },
  })
  service:update()
  local reader = requireInstalledReader(service, epoch)
  local stable = assert(reader:resolveAsset(scene.path), "the installed entry resolves")

  service:injectReply({
    op = "cache-install-entries",
    epoch = epoch,
    generationId = identity.generationId,
    sequence = 1,
    part = 1,
    entries = { scene },
  })
  service:update()
  Assert.isTrue(reader:resolveAsset(scene.path) == stable, "an identical part replay leaves the reader alone")

  local shadow = residentEntry(identity, scene.path, "shadow")
  service:injectReply({
    op = "cache-install-entries",
    epoch = epoch,
    generationId = identity.generationId,
    sequence = 1,
    part = 1,
    entries = { shadow },
  })
  Assert.throws(function()
    service:update()
  end, "a duplicate part with different bytes under one content identity is a protocol violation")
  service:shutdown()
end

-- A whole installation stream replayed for a sequence that is already
-- committed is a no-op when it names the same identity, and a protocol error
-- when it tries to name another one under that sequence.
function T.a_replayed_committed_installation_is_a_no_op()
  local Service = requireService()
  local identity = probeIdentity()
  local service = assert(Service.new({ thread = newChannelHost() }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  local scene = residentEntry(identity, "data/generated/field/30/scene.lua", "stable")
  pushInstallation(service, {
    epoch = epoch,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = { scene },
    milestones = { "bootstrap" },
  })
  service:update()
  local reader = requireInstalledReader(service, epoch)
  local committed = assert(reader:resolveAsset(scene.path), "the installed entry resolves")

  pushInstallation(service, {
    epoch = epoch,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = { scene },
    milestones = { "bootstrap" },
  })
  service:update()
  Assert.isTrue(reader:resolveAsset(scene.path) == committed, "a replayed committed stream changes nothing")

  local other = {}
  for field, value in pairs(identity) do
    other[field] = value
  end
  other.generationId = identity.generationId .. "-other"
  pushInstallation(service, {
    epoch = epoch,
    identity = other,
    sequence = 1,
    initial = true,
    entries = {},
  })
  Assert.throws(function()
    service:update()
  end, "a duplicate committed sequence with another identity is a protocol violation")
  service:shutdown()
end

-- Retiring the live epoch and selecting another must strand everything the old
-- selection still had in flight: late bytes, late terminal facts, and late
-- first-play facts land nowhere.
function T.a_retired_epochs_traffic_never_reaches_the_live_view()
  local Service = requireService()
  local service = assert(Service.new({ thread = newChannelHost() }))
  local identity = probeIdentity()
  local staleEpoch = assert(service:select({ versionId = "heartgold", development = true }))
  local scene = residentEntry(identity, "data/generated/field/30/scene.lua", "stale")
  pushInstallation(service, {
    epoch = staleEpoch,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = { scene },
  })
  service:update()
  requireInstalledReader(service, staleEpoch)

  service:retire(staleEpoch)
  local liveEpoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:update()
  pushInstallation(service, {
    epoch = staleEpoch,
    identity = identity,
    sequence = 2,
    entries = { residentEntry(identity, "data/generated/field/30/late.lua", "late") },
    firstPlay = true,
  })
  service:injectReply({
    op = "request-result",
    epoch = staleEpoch,
    requestId = 1,
    state = "ready",
    requiredSequence = 2,
  })
  service:update()
  Assert.isNil(service:getCacheFs(liveEpoch), "a retired epoch's installation publishes no live reader")
  Assert.isNil(service:cacheIdentity(liveEpoch), "a retired epoch's installation publishes no live identity")
  Assert.isFalse(service:firstPlayReady(liveEpoch), "a stale first-play fact cannot become the live epoch's fact")

  local current = residentEntry(identity, "data/generated/field/31/scene.lua", "current")
  pushInstallation(service, {
    epoch = liveEpoch,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = { current },
  })
  service:update()
  local live = requireInstalledReader(service, liveEpoch)
  Assert.equal(live:readData(current.path):getString(), "current", "the live epoch installs its own bytes")
  Assert.isNil(
    live:readData("data/generated/field/30/late.lua"),
    "the retired epoch's payload never enters the live epoch's store"
  )
  service:shutdown()
end

-- A publisher in another Lua state hands its packets over through real thread
-- channels while this thread is already trying to observe readiness: a partial
-- installation stays invisible until the part it was waiting for arrives, and
-- the bytes cross by reference rather than as a serialized copy.
local PUBLISHER_THREAD = [[
local data = (rawget(_G, "love") and love.data) or require("love.data")
local reply, arrived, gate, hold, spec = ...
local function entry(row)
  return {
    path = row.path,
    data = assert(data.newByteData(row.text)),
    size = #row.text,
    sourceId = spec.sourceId,
    contentId = spec.contentIdPrefix .. row.path,
  }
end
for _, row in ipairs(spec.head) do
  reply:push(row)
end
for _, row in ipairs(spec.headEntries) do
  reply:push({ op = "cache-install-entries", epoch = spec.epoch, generationId = spec.generationId,
    sequence = spec.sequence, part = row.part, entries = { entry(row) } })
end
arrived:push("head")
gate:demand()
for _, row in ipairs(spec.tailEntries) do
  reply:push({ op = "cache-install-entries", epoch = spec.epoch, generationId = spec.generationId,
    sequence = spec.sequence, part = row.part, entries = { entry(row) } })
end
reply:push({ op = "cache-install-commit", epoch = spec.epoch, generationId = spec.generationId,
  sequence = spec.sequence, milestones = spec.milestones, firstPlay = false, complete = false })
arrived:push("tail")
hold:demand()
]]

function T.a_real_thread_installs_every_part_before_readiness_is_observed()
  local Service = requireService()
  local host = assert(hostLove.thread, "the scenario needs real thread channels")
  local command = assert(host.newChannel())
  local reply = assert(host.newChannel())
  -- The controller itself is not the subject here; its channel endpoints are
  -- real so a second Lua state can install the packets it would send.
  local idleController = { alive = true }
  function idleController:start()
    return true
  end
  function idleController:wait()
    return true
  end
  function idleController:isRunning()
    return self.alive
  end
  function idleController:getError()
    return nil
  end
  local minted = 0
  local service = assert(Service.new({
    thread = {
      newChannel = function()
        minted = minted + 1
        if minted == 1 then
          return command
        end
        return reply
      end,
      newThread = function()
        return idleController
      end,
    },
  }))
  local arrived = assert(host.newChannel())
  local gate = assert(host.newChannel())
  local hold = assert(host.newChannel())
  local identity = probeIdentity()
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  local requestId =
    assert(service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" }))
  service:update()

  local thread = assert(host.newThread(PUBLISHER_THREAD))
  local started, startError = pcall(function()
    thread:start(reply, arrived, gate, hold, {
      epoch = epoch,
      generationId = identity.generationId,
      sequence = 2,
      sourceId = "base:" .. identity.generationId,
      contentIdPrefix = identity.generationId .. "\0",
      milestones = { "bootstrap" },
      head = {
        { op = "request-result", epoch = epoch, requestId = requestId, state = "ready", requiredSequence = 2 },
        {
          op = "cache-install-begin",
          epoch = epoch,
          generationId = identity.generationId,
          sequence = 2,
          initial = true,
          identity = identity,
          entryCount = 2,
        },
      },
      headEntries = {
        { part = 1, path = "data/generated/field/30/scene.lua", text = "return { mapId = 30 }\n" },
      },
      tailEntries = {
        { part = 2, path = "assets/generated/field/30/atlas.png", text = "PNGDATA" },
      },
    })
  end)
  Assert.isTrue(started, "the publisher Lua state starts: " .. tostring(startError))

  local ok, err = pcall(function()
    Assert.equal(awaitValue(arrived, 20), "head", "the publisher sends the terminal fact and a first part")
    service:update()
    Assert.isNil(
      service:observe(epoch, { requestKind = "milestone", name = "bootstrap" }),
      "no readiness is exposed before the installation commit"
    )
    Assert.isNil(
      type(service.getCacheFs) == "function" and service:getCacheFs(epoch) or nil,
      "no reader is exposed before the installation commit"
    )

    gate:push(true)
    Assert.equal(awaitValue(arrived, 20), "tail", "the publisher sends the remaining part and the commit")
    service:update()
    Assert.isTrue(
      service:observe(epoch, { requestKind = "milestone", name = "bootstrap" }),
      "the closure is playable once every part is installed"
    )
    local reader = requireInstalledReader(service, epoch)
    local borrowed = assert(reader:readData("assets/generated/field/30/atlas.png"), "the installed bytes are readable")
    Assert.equal(borrowed:getString(), "PNGDATA", "bytes published from another Lua state arrive intact")
    Assert.isTrue(
      reader:readData("data/generated/field/30/scene.lua") ~= nil,
      "the earlier part's bytes are still installed"
    )
  end)
  pcall(function()
    gate:push(true)
    hold:push(true)
  end)
  stopThread(thread)
  service:shutdown()
  if not ok then
    error(err, 0)
  end
end

function T.persistence_observations_are_live_epoch_scoped_and_do_not_fail_play()
  local service = requireService().new({ thread = newChannelHost() })
  local first = assert(service:select({ versionId = "heartgold" }))
  service:update()
  local identity = probeIdentity()
  pushInstallation(service, {
    epoch = first,
    identity = identity,
    sequence = 1,
    initial = true,
    entries = {},
    milestones = { "bootstrap" },
  })
  service:update()
  local reader = assert(service:getCacheFs(first), "the installed reader is available before any archive error")
  service:request(first, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  Assert.isTrue(
    service:observe(first, { requestKind = "milestone", name = "bootstrap" }),
    "the installed request is ready"
  )
  Assert.deepEqual(
    service:persistenceStatus(first),
    { sequence = 0, observedSequence = 0 },
    "a selected epoch starts with no persisted snapshot"
  )

  service:injectReply({
    op = "cache-persistence-failed",
    epoch = first,
    sequence = 4,
    error = { code = "CACHE_ARCHIVE_WRITE_FAILED", message = "disk full" },
  })
  service:update()
  local failed = assert(service:persistenceStatus(first))
  Assert.equal(failed.sequence, 0, "a failed snapshot advances no durable sequence")
  Assert.equal(failed.error.code, "CACHE_ARCHIVE_WRITE_FAILED", "the writer failure stays observable")
  Assert.isNil(service._failure, "an archive failure never becomes a controller failure")
  Assert.notNil(service:getCacheFs(first), "the failed persistence report leaves the installed reader available")
  Assert.isTrue(service:getCacheFs(first) == reader, "the persistence report preserves the reader identity")
  Assert.isTrue(
    service:observe(first, { requestKind = "milestone", name = "bootstrap" }),
    "the persistence report leaves request readiness intact"
  )

  service:injectReply({ op = "cache-persistence-succeeded", epoch = first - 1, sequence = 5 })
  service:injectReply({ op = "cache-persistence-succeeded", epoch = first, sequence = 3 })
  service:update()
  Assert.notNil(service:persistenceStatus(first).error, "an older success cannot clear a newer failure")

  service:injectReply({ op = "cache-persistence-succeeded", epoch = first, sequence = 4 })
  service:update()
  local recovered = assert(service:persistenceStatus(first))
  Assert.equal(recovered.sequence, 4, "a successful acknowledgement advances durability")
  Assert.isNil(recovered.error, "a later successful write clears the failure")

  local second = assert(service:select({ versionId = "soulsilver" }))
  service:update()
  service:injectReply({
    op = "cache-persistence-failed",
    epoch = first,
    sequence = 6,
    error = { message = "stale" },
  })
  service:update()
  Assert.isNil(service:persistenceStatus(first), "a retired selection exposes no status")
  Assert.equal(assert(service:persistenceStatus(second)).sequence, 0, "old reports cannot alter the new selection")
  service:shutdown()
end

return { tests = T }
