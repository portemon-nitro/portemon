-- The semantic Pokedex readiness request travels the existing request
-- lifecycle with no new protocol: one coalesced pokedex:global demand
-- reaches the controller, stale completions never satisfy a new
-- generation, failures stay attributed, the worker dispatches the exact
-- registered global job, and the two families register with bounded
-- statically known dependencies behind the field-runtime prerequisite.

local Assert = require("tests.support.Assert")

local T = {}

local function newChannelHost()
  local channels = {}
  local function newChannel()
    local queue = {}
    local channel = { pushed = {} }
    function channel:push(value)
      queue[#queue + 1] = value
      self.pushed[#self.pushed + 1] = value
      return true
    end
    function channel:pop()
      if #queue == 0 then
        return nil
      end
      return table.remove(queue, 1)
    end
    function channel:demand()
      return table.remove(queue, 1)
    end
    channels[#channels + 1] = channel
    return channel
  end
  local function newThread(_)
    local thread = { starts = 0 }
    function thread:start(...)
      self.starts = self.starts + 1
      return true
    end
    function thread:wait()
      return true
    end
    function thread:isRunning()
      return true
    end
    return thread
  end
  return { newChannel = newChannel, newThread = newThread, channels = channels }
end

local function requireProduction()
  local loadedProvisioner = pcall(require, "app.src.DerivedAssetProvisioner")
  Assert.isTrue(
    loadedProvisioner,
    "the derived-asset provisioner must be published before the semantic request can be proven"
  )
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local CacheService = require("app.src.CacheService")
  local host =
    DerivedAssetProvisioner.new({ service = CacheService.new({ thread = newChannelHost() }), versionId = "heartgold" })
  local gameHost = host:gameHost()
  Assert.isTrue(
    type(gameHost.requestPokedex) == "function",
    "the game host must expose the single bounded pokedex request before readiness can be proven"
  )
  host:dispose()
  return DerivedAssetProvisioner, CacheService
end

local function selectedHarness()
  local DerivedAssetProvisioner, CacheService = requireProduction()
  local thread = newChannelHost()
  local service = CacheService.new({ thread = thread })
  -- The epoch belongs to the provisioner selection: the provisioner
  -- borrows it when it is created, and every request in this harness
  -- travels through that selection.
  local provisioner = DerivedAssetProvisioner.new({ service = service, versionId = "heartgold" })
  local epoch = assert(provisioner.epoch, "selection must yield an epoch")
  return {
    service = service,
    epoch = epoch,
    provisioner = provisioner,
    host = provisioner:gameHost(),
    thread = thread,
  }
end

local function emittedRequests(thread)
  local requests = {}
  for _, channel in ipairs(thread.channels) do
    for _, message in ipairs(channel.pushed) do
      if type(message) == "table" and message.op == "request" then
        requests[#requests + 1] = message
      end
    end
  end
  return requests
end

local function pushReply(harness, packet)
  -- The service creates its command channel first and its reply channel
  -- second; worker facts arrive on the reply channel only.
  local reply = harness.thread.channels[2]
  assert(reply ~= nil, "the harness must expose the service reply channel")
  reply:push(packet)
end

function T.semantic_pokedex_request_coalesces_to_one_global_job()
  local harness = selectedHarness()
  local ready, failure = harness.host.requestPokedex("required")
  Assert.isNil(ready, "the missing presentation artifact reads pending, not ready")
  Assert.isNil(failure, "the missing presentation artifact carries no failure yet")
  local secondReady, secondFailure = harness.host.requestPokedex("required")
  Assert.isNil(secondReady, "the repeated request reads pending, not ready")
  Assert.isNil(secondFailure, "the repeated request carries no failure yet")

  harness.service:update()
  local requests = emittedRequests(harness.thread)
  Assert.equal(#requests, 1, "the two semantic requests coalesce into one controller demand")
  local command = requests[1]
  Assert.equal(command.requestKind, "pokedex", "the demand carries the pokedex kind")
  Assert.equal(command.urgency, "required", "the demand carries the requested urgency")
  Assert.isNil(command.pageId, "the demand carries no page selector")
  Assert.isNil(command.name, "the demand carries no milestone selector")
  Assert.isNil(command.mapId, "the demand carries no map selector")

  harness.service:update()
  Assert.equal(#emittedRequests(harness.thread), 1, "a settled demand emits no duplicate request")

  pushReply(harness, { op = "request-result", epoch = harness.epoch, requestId = command.requestId, state = "ready" })
  harness.service:update()
  Assert.isTrue(harness.host.requestPokedex("required"), "a ready worker result satisfies the semantic request")
  harness.provisioner:dispose()
end

function T.stale_completion_is_ignored_and_failure_is_retained()
  local harness = selectedHarness()
  harness.host.requestPokedex("required")
  harness.service:update()
  local first = emittedRequests(harness.thread)
  Assert.equal(#first, 1, "the first generation emits its demand")
  local staleId = first[1].requestId

  -- A completion for the retired generation must not satisfy the fresh
  -- live epoch even though both describe the same selector.
  local provisioner = require("app.src.DerivedAssetProvisioner").new({
    service = harness.service,
    versionId = "heartgold",
  })
  local nextEpoch = assert(provisioner.epoch, "reselection must yield a fresh epoch")
  Assert.isTrue(nextEpoch ~= harness.epoch, "reselection retires the previous generation")
  local freshHost = provisioner:gameHost()
  Assert.isNil(freshHost.requestPokedex("required"), "the fresh generation starts pending")
  -- A completion for the retired generation must not satisfy the fresh
  -- live epoch even though both describe the same selector.
  pushReply(harness, { op = "request-result", epoch = harness.epoch, requestId = staleId, state = "ready" })
  harness.service:update()
  local freshReady, freshFailure = harness.service:observe(nextEpoch, { requestKind = "pokedex", urgency = "required" })
  Assert.isNil(freshReady, "a stale completion must not satisfy the new generation")
  Assert.isNil(freshFailure, "a stale completion must not fail the new generation")
  harness.service:update()
  local second = emittedRequests(harness.thread)
  local current = second[#second]
  Assert.notNil(current, "the fresh generation emits its own demand")
  Assert.isTrue(current.requestId ~= staleId, "the fresh demand carries a fresh identity")
  pushReply(harness, {
    op = "request-result",
    epoch = nextEpoch,
    requestId = current.requestId,
    state = "failed",
    errorMessage = "fixture pokedex job failure",
  })
  harness.service:update()
  local failedReady, failedFailure = freshHost.requestPokedex("required")
  Assert.isNil(failedReady, "a failed job never reads ready")
  Assert.notNil(failedFailure, "a failed job retains its attribution")
  Assert.notNil(
    tostring(failedFailure):find("fixture pokedex job failure", 1, true),
    "the retained failure names the worker cause"
  )
  provisioner:dispose()
  harness.provisioner:dispose()
end

function T.pokedex_request_rejects_unknown_urgency_and_selectors()
  local harness = selectedHarness()
  local urgencyOk = pcall(harness.host.requestPokedex, "soon")
  Assert.isFalse(urgencyOk, "an unknown urgency must not enter the request lifecycle")
  local selectorOk = pcall(function()
    harness.service:request(harness.epoch, { requestKind = "pokedex", urgency = "required", pageId = 0 })
  end)
  Assert.isFalse(selectorOk, "a page selector must not ride the selector-free pokedex request")
  harness.provisioner:dispose()
end

function T.controller_dispatches_pokedex_through_the_registered_global_job()
  requireProduction()
  local loadedWorker, CacheControllerWorker = pcall(require, "romdump.src.build.CacheControllerWorker")
  Assert.isTrue(loadedWorker, "the cache controller worker must be published before dispatch can be proven")
  local control = {}
  function control.pop()
    return nil
  end
  local reply = { pushed = {} }
  function reply:push(message)
    reply.pushed[#reply.pushed + 1] = message
  end
  local worker = CacheControllerWorker.Worker.new(control, reply)
  local calls = {}
  worker.session = {
    requestJob = function(_, kind, key, urgency)
      calls[#calls + 1] = { kind = kind, key = key, urgency = urgency }
      return false, nil
    end,
  }
  worker:_invoke({ requestKind = "pokedex", urgency = "required" })
  Assert.equal(#calls, 1, "the pokedex request dispatches exactly one job")
  Assert.equal(calls[1].kind, "pokedex", "the dispatch targets the pokedex family")
  Assert.equal(calls[1].key, "global", "the dispatch targets the single global key")
  Assert.equal(calls[1].urgency, "required", "the dispatch preserves the requested urgency")
end

function T.pokedex_families_register_with_bounded_dependencies()
  requireProduction()
  local loadedState, ArtifactState = pcall(require, "romdump.src.build.ArtifactState")
  Assert.isTrue(loadedState, "the artifact state must be published before family registration can be proven")
  local loadedJobs, ArtifactJobs = pcall(require, "romdump.src.build.ArtifactJobs")
  Assert.isTrue(loadedJobs, "the artifact jobs must be published before family registration can be proven")
  local dataOk = pcall(ArtifactState.path, "pokedex-data", "global")
  Assert.isTrue(dataOk, "the pokedex-data family must admit its global receipt")
  local presentationOk = pcall(ArtifactState.path, "pokedex", "global")
  Assert.isTrue(presentationOk, "the pokedex family must admit its global receipt")
  local nonGlobalOk = pcall(ArtifactState.path, "pokedex", "0")
  Assert.isFalse(nonGlobalOk, "the pokedex family must reject non-global keys")

  local dataDependencies, dataComplete = ArtifactJobs.dependencies("pokedex-data", "global", {})
  Assert.isTrue(dataComplete, "the data family dependencies are statically known")
  local presentationDependencies, presentationComplete = ArtifactJobs.dependencies("pokedex", "global", {})
  Assert.isTrue(presentationComplete, "the presentation family dependencies are statically known")
  local waitsForData = false
  for _, edge in ipairs(presentationDependencies) do
    Assert.isNil(edge.pageId, "presentation dependencies carry no page selectors")
    if edge.kind == "pokedex-data" and edge.key == "global" then
      waitsForData = true
    end
  end
  Assert.isTrue(waitsForData, "the presentation family waits for the data family")

  local fieldRuntime = false
  for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
    if job.kind == "pokedex-data" and job.key == "global" then
      fieldRuntime = true
    end
    Assert.isTrue(
      not (job.kind == "pokedex" and job.key == "global"),
      "field boot waits for data alone, never for presentation pixels"
    )
  end
  Assert.isTrue(fieldRuntime, "field runtime prepares the pokedex data family")
  local intro, complete = ArtifactJobs.newGameIntroJobs(nil)
  Assert.isFalse(complete, "the intro closure remains unresolved without its audio plan")
  for _, job in ipairs(intro) do
    Assert.isTrue(job.kind ~= "pokedex", "Oak-only preparation never pulls pokedex presentation")
    Assert.isTrue(job.kind ~= "pokedex-data", "Oak-only preparation never pulls pokedex data")
  end
  Assert.notNil(dataDependencies, "the data dependency list exists for the audit")
end

return { tests = T }
