-- Compiler-pool component scenarios cover queue ownership, in-memory map
-- publication, and unsupported host capability handling.

local Assert = require("tests.support.Assert")
local BundleFixture = require("tests.support.BundleFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = {}

---@return CompilerPool
local function requirePool()
  local ok, pool = pcall(require, "romdump.src.build.CompilerPool")
  Assert.isTrue(ok, "the production compiler-pool boundary is missing")
  return assert(pool) --[[@as CompilerPool]]
end

local function requirePreparedArtifact()
  local ok, prepared = pcall(require, "romdump.src.build.PreparedArtifact")
  Assert.isTrue(ok, "the production prepared-artifact boundary is missing")
  return prepared --[[@as PreparedArtifact]]
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

local function newThreadHost(processorCount)
  local dispatched = {}
  local threads = {}
  local channels = {}
  -- Test-local liveness control: healthy threads by default. A test may arm
  -- stopOnDispatch so the first worker that receives real work reports itself
  -- stopped with no error text, exercising the production fatal path.
  local control = { stopOnDispatch = false, stopDone = false }
  local filesystemBackend = FakeCache.new()
  local filesystem = {
    write = function(path, data)
      return filesystemBackend:write(path, data)
    end,
    read = function(path)
      return filesystemBackend:read(path)
    end,
    getInfo = function(path)
      return filesystemBackend:getInfo(path)
    end,
    createDirectory = function(path)
      return filesystemBackend:createDirectory(path)
    end,
    remove = function(path)
      return filesystemBackend:remove(path)
    end,
    getDirectoryItems = function(path)
      return filesystemBackend:getDirectoryItems(path)
    end,
  }

  local function newChannel()
    local values = {}
    local channel = {}
    function channel:push(value)
      values[#values + 1] = value
      if type(value) == "table" and value.jobKey ~= nil then
        dispatched[#dispatched + 1] = value.jobKey
        if control.stopOnDispatch and not control.stopDone and threads[1] ~= nil then
          control.stopDone = true
          threads[1].stopped = true
        end
      end
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      local value = table.remove(values, 1)
      return value
    end
    function channel:demand()
      return self:pop()
    end
    function channel:getCount()
      return #values
    end
    channels[#channels + 1] = channel
    return channel
  end

  local function newThread()
    local thread = { starts = 0, waits = 0, stopped = false }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return nil
    end
    function thread:isRunning()
      if self.stopped then
        return false
      end
      return self.starts > 0 and self.waits == 0
    end
    threads[#threads + 1] = thread
    return thread
  end

  return {
    love = {
      filesystem = filesystem,
      system = {
        getProcessorCount = function()
          return processorCount
        end,
      },
      timer = {
        getTime = function()
          return 0
        end,
      },
      thread = {
        newChannel = newChannel,
        newThread = newThread,
      },
    },
    dispatched = dispatched,
    threads = threads,
    channels = channels,
    control = control,
  }
end

function T.failed_preparation_preserves_the_previous_map()
  local prepared = requirePreparedArtifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local generation = "failed-preparation-generation"
  local first = BundleFixture.minimal()
  local baseline = prepared.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "map",
    key = tostring(first.mapId),
    jobKey = "map:" .. first.mapId,
  })
  MapCacheWriter.stage(baseline, first)
  baseline:finishSuccess({ mapId = first.mapId, marker = first.marker })
  ResidentArtifactFixture.materialize(baseline)
  local oldMarker = cache:read(MapAssetCache.mapDir(first.mapId) .. "/complete")
  local oldScene = cache:read(MapAssetCache.mapDir(first.mapId) .. "/scene.lua")

  local artifact = prepared.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "map",
    key = tostring(first.mapId),
    jobKey = "map:" .. first.mapId,
  })
  Assert.throws(function()
    MapCacheWriter.stage(artifact, { mapId = first.mapId })
  end)
  artifact:abort()

  Assert.equal(cache:read(MapAssetCache.mapDir(first.mapId) .. "/complete"), oldMarker)
  Assert.equal(cache:read(MapAssetCache.mapDir(first.mapId) .. "/scene.lua"), oldScene)
  Assert.equal(artifact:status(), "aborted", "a failed preparation seals no output")
end

-- Epoch ownership pins the census contract: a new selection inherits no
-- live lookup, the same selection is idempotent, and identical keys
-- restart as new-epoch interest while old physical slots stay busy.
function T.selected_epoch_resets_current_lookup()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local function mapJob(key, mapId, priority, epoch)
    return {
      generationId = "epoch-generation",
      epoch = epoch,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      dependencies = {},
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "epoch-generation" }, 1)
    pool:request(mapJob("60", 60, 100, 1))
    pool:request(mapJob("60", 60, 100, 1))
    pool:selectGeneration({ versionId = "heartgold", generationId = "epoch-generation" }, 1)
    pool:request(mapJob("60", 60, 100, 1))
    pool:update()
  end)
  Assert.deepEqual(host.dispatched, { "map:60" }, "one job exists per identity within its epoch")
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "epoch-generation" }, 2)
  end)
  Assert.equal(pool:status("map:60"), "unknown", "the new epoch inherits no live lookup")
  withLove(host.love, function()
    pool:request(mapJob("60", 60, 100, 2))
    pool:update()
  end)
  Assert.equal(pool:status("map:60"), "queued", "identical keys restart as new-epoch interest")
  Assert.deepEqual(host.dispatched, { "map:60" }, "the new record waits on the still-busy old slot")
  local diagnostics = pool:diagnostics()
  Assert.isTrue(
    tostring(diagnostics.workerStates):find("busy", 1, true) ~= nil,
    "old physical slots stay busy across selections: " .. tostring(diagnostics.workerStates)
  )
  pool:shutdown()
end

-- Queued promotion reorders dispatch while running work holds its slot:
-- strengthening a queued record promotes it, strengthening a running
-- record neither preempts nor resubmits it.
function T.queued_promotion_reorders_dispatch_while_running_holds()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local function mapJob(key, mapId, priority)
    return {
      generationId = "promotion-generation",
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      dependencies = {},
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "promotion-generation" }, 1)
    pool:request(mapJob("60", 60, 100))
    pool:request(mapJob("61", 61, 100))
    pool:request(mapJob("60", 60, 0))
    pool:update()
  end)
  Assert.deepEqual(host.dispatched, { "map:60" }, "the promoted queued job dispatches first")
  Assert.equal(pool:status("map:60"), "running", "the promoted job executes")
  Assert.equal(pool:status("map:61"), "queued", "unpromoted work waits")
  withLove(host.love, function()
    pool:request(mapJob("60", 60, 0))
    pool:update()
  end)
  Assert.deepEqual(host.dispatched, { "map:60" }, "strengthening a running job resubmits nothing")
  Assert.equal(pool:status("map:60"), "running", "running work is never preempted")
  Assert.equal(pool:status("map:61"), "queued", "the waiter still waits on the busy slot")
  pool:shutdown()
end

-- Retirement cancels logical queued work: the record reads cancelled, no
-- new work is accepted into the retired selection, and the next epoch
-- starts clean.
function T.retired_selection_cancels_queued_work()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local function mapJob(key, mapId, priority, epoch)
    return {
      generationId = "retirement-generation",
      epoch = epoch,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      dependencies = {},
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "retirement-generation" }, 1)
    pool:request(mapJob("60", 60, 100, 1))
    Assert.isTrue(pool:retireSelection(1), "retirement accepts its epoch")
    Assert.isFalse(pool:retireSelection(1), "retirement does not repeat")
  end)
  Assert.equal(pool:status("map:60"), "cancelled", "retired queued work reads cancelled")
  local ok = pcall(function()
    withLove(host.love, function()
      pool:request(mapJob("61", 61, 100, 1))
    end)
  end)
  Assert.isFalse(ok, "the retired selection accepts no later work")
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "retirement-generation" }, 2)
    pool:request(mapJob("60", 60, 100, 2))
  end)
  Assert.equal(pool:status("map:60"), "queued", "the next epoch accepts the key as new work")
  pool:shutdown()
end

function T.queued_jobs_are_deduplicated_and_priority_fifo()
  local CompilerPool = requirePool()
  local host = newThreadHost(4)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "deduplication-generation" }, 1)
  end)

  local function mapJob(key, mapId, priority)
    return {
      generationId = "deduplication-generation",
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      dependencies = {},
      payload = { mapId = mapId },
    }
  end

  withLove(host.love, function()
    pool:request(mapJob("60", 60, 100))
    pool:request(mapJob("61", 61, 10))
    pool:request(mapJob("60", 60, 0))
    pool:request(mapJob("62", 62, 10))
    pool:update()
  end)

  -- The bounded batch pool runs two workers: the promoted map:60 keeps its
  -- original sequence ahead of map:61, and map:62 waits for a free worker.
  Assert.deepEqual(host.dispatched, { "map:60", "map:61" })
  Assert.equal(pool:status("map:60"), "running")
  Assert.equal(pool:status("map:61"), "running")
  Assert.equal(pool:status("map:62"), "queued")
  pool:shutdown()
end

function T.missing_thread_support_fails_before_cache_mutation()
  local CompilerPool = requirePool()
  for _, mode in ipairs({ "batch", "interactive" }) do
    local createdWorkers = 0
    local fakeLove = {
      system = {
        getProcessorCount = function()
          return 4
        end,
      },
      thread = {
        newThread = function()
          createdWorkers = createdWorkers + 1
          return {}
        end,
        newChannel = function()
          return {}
        end,
      },
    }
    withLove(fakeLove, function()
      local err = Assert.throws(function()
        CompilerPool.new({ versionId = "heartgold", mode = mode })
      end)
      Assert.isTrue(tostring(err):lower():find("thread", 1, true) ~= nil, "error names missing thread support")
    end)
    Assert.equal(createdWorkers, 0, "capability preflight starts no workers")
  end
end

function T.constructor_failure_joins_started_workers()
  local CompilerPool = requirePool()
  local started = {}
  local threads = {}
  local function channel()
    local values = {}
    return {
      push = function(_, value)
        values[#values + 1] = value
        return true
      end,
      pop = function()
        if #values == 0 then
          return nil
        end
        return table.remove(values, 1)
      end,
      demand = function(self)
        return self:pop()
      end,
      getCount = function()
        return #values
      end,
    }
  end
  local fakeLove = {
    system = {
      getProcessorCount = function()
        return 4
      end,
    },
    thread = {
      newChannel = channel,
      newThread = function()
        if #threads == 1 then
          error("injected worker construction failure")
        end
        local thread = { waits = 0 }
        function thread:start()
          started[#started + 1] = self
        end
        function thread:wait()
          self.waits = self.waits + 1
        end
        function thread:getError()
          return nil
        end
        threads[#threads + 1] = thread
        return thread
      end,
    },
  }

  withLove(fakeLove, function()
    Assert.throws(function()
      CompilerPool.new({ versionId = "heartgold", mode = "batch" })
    end)
  end)
  Assert.equal(#started, 1, "workers before the failed construction were started")
  for _, thread in ipairs(threads) do
    Assert.equal(thread.waits, 1, "each acquired worker is joined exactly once")
  end
end

-- Two artifacts may declare one shared payload: the controller reconciles it
-- at commit, reuses the committed bytes for an identical declaration, and
-- refuses the whole artifact when its bytes contradict them.
function T.staged_shared_files_promote_once_and_conflicts_fail()
  local CompilerPool = requirePool()
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newThreadHost(2)
  host.love.data = hostLove.data
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "shared-promotion-generation"
  local sharedPath = "data/generated/geometry/shared"
  local function bytes(text)
    return assert(hostLove.data.newByteData(text))
  end
  local function dispatchMap(key)
    withLove(host.love, function()
      pool:request({
        generationId = generation,
        epoch = 1,
        versionId = "heartgold",
        kind = "map",
        key = key,
        jobKey = "map:" .. key,
        priority = 0,
        sizeClass = "normal",
        dependencies = {},
        payload = { mapId = tonumber(key) },
      })
      pool:update()
    end)
    return assert(host.channels[2]:pop(), "the worker received the job")
  end
  local function reportShared(dispatched, key, sharedText)
    local shared = bytes(sharedText)
    local marker = bytes("ready")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      dispatchId = dispatched.dispatchId,
      status = "prepared",
      marker = "complete",
      ownedRoots = { "data/generated/maps/" .. key },
      sharedPaths = { sharedPath },
      entries = {
        { path = sharedPath, data = shared, size = shared:getSize() },
        { path = "data/generated/maps/" .. key .. "/complete", data = marker, size = marker:getSize() },
      },
    })
    withLove(host.love, function()
      pool:update()
    end)
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
  end)

  reportShared(dispatchMap("61"), "61", "first")
  Assert.equal(pool:status("map:61"), "ready", "the first artifact commits its shared payload")
  local sharedEntry = assert(pool:cacheFs():resolveAsset(sharedPath), "the shared payload is resident")
  Assert.equal(sharedEntry.data:getString(), "first")

  reportShared(dispatchMap("62"), "62", "first")
  Assert.equal(pool:status("map:62"), "ready", "identical shared bytes commit once")
  Assert.isTrue(
    pool:cacheFs():resolveAsset(sharedPath) == sharedEntry,
    "identical shared bytes reuse the committed buffer"
  )
  Assert.equal(pool:cacheFs():readData("data/generated/maps/62/complete"):getString(), "ready")

  reportShared(dispatchMap("63"), "63", "different")
  local state, details = pool:status("map:63")
  Assert.equal(state, "failed", "a shared contradiction refuses the whole artifact")
  Assert.isTrue(
    tostring(details and details.error or ""):find("PREPARED_SHARED_CONFLICT", 1, true) ~= nil,
    "the contradiction names its cause: " .. tostring(details and details.error)
  )
  Assert.equal(
    pool:cacheFs():readData(sharedPath):getString(),
    "first",
    "a shared conflict never overwrites committed bytes"
  )
  Assert.isNil(
    pool:cacheFs():resolveAsset("data/generated/maps/63/complete"),
    "a shared conflict exposes no family output"
  )
  pool:shutdown()
end

-- Two artifacts may publish one logical path without declaring it shared: an
-- owned output of both resolves to the payload the first artifact installed,
-- each fact keeps its own declarations, one captured cut lists the payload
-- once, and a contradiction still refuses the whole artifact.
function T.overlapping_owned_outputs_commit_once_and_conflicts_fail()
  local CompilerPool = requirePool()
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newThreadHost(2)
  host.love.data = hostLove.data
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "owned-overlap-generation"
  local ownedPath = "data/generated/geometry/overlapped"
  local function bytes(text)
    return assert(hostLove.data.newByteData(text))
  end
  local function dispatchMap(key)
    withLove(host.love, function()
      pool:request({
        generationId = generation,
        epoch = 1,
        versionId = "heartgold",
        kind = "map",
        key = key,
        jobKey = "map:" .. key,
        priority = 0,
        sizeClass = "normal",
        dependencies = {},
        payload = { mapId = tonumber(key) },
      })
      pool:update()
    end)
    return assert(host.channels[2]:pop(), "the worker received the job")
  end
  local function reportOwned(dispatched, key, ownedText)
    local owned = bytes(ownedText)
    local marker = bytes("ready")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      dispatchId = dispatched.dispatchId,
      status = "prepared",
      marker = "complete",
      ownedRoots = { ownedPath, "data/generated/maps/" .. key },
      sharedPaths = {},
      entries = {
        { path = ownedPath, data = owned, size = owned:getSize() },
        { path = "data/generated/maps/" .. key .. "/complete", data = marker, size = marker:getSize() },
      },
    })
    withLove(host.love, function()
      pool:update()
    end)
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
  end)

  reportOwned(dispatchMap("71"), "71", "overlapped")
  Assert.equal(pool:status("map:71"), "ready", "the first artifact commits its owned output")
  local committed = assert(pool:cacheFs():resolveAsset(ownedPath), "the owned output is resident")
  Assert.equal(committed.data:getString(), "overlapped")

  reportOwned(dispatchMap("72"), "72", "overlapped")
  Assert.equal(pool:status("map:72"), "ready", "an artifact producing an identical owned output commits")
  Assert.isTrue(
    pool:cacheFs():resolveAsset(ownedPath) == committed,
    "identical owned bytes reuse the committed buffer instead of replacing it"
  )
  local facts = assert(pool:artifactFacts())
  for _, key in ipairs({ "71", "72" }) do
    local fact = assert(ArtifactState.read(facts, "map", key), "each artifact keeps its own fact: " .. key)
    Assert.deepEqual(fact.files, {
      ownedPath,
      "data/generated/maps/" .. key .. "/complete",
    }, "each fact names the payload it published: " .. key)
    Assert.deepEqual(fact.ownedRoots, {
      ownedPath,
      "data/generated/maps/" .. key,
    }, "each fact keeps its owned roots: " .. key)
    Assert.deepEqual(fact.sharedPaths, {}, "neither artifact declares the payload shared: " .. key)
  end

  local cut = pool:snapshotCut({ versionId = "heartgold", generationId = generation }, { sequence = 1 })
  local rows, carried = 0, nil
  for _, entry in ipairs(cut.entries) do
    if entry.path == ownedPath then
      rows = rows + 1
      carried = entry.data
    end
  end
  Assert.equal(rows, 1, "one cut lists the overlapping payload once")
  Assert.isTrue(carried == committed.data, "the cut carries the committed buffer")
  Assert.equal(#cut.artifacts, 2, "both artifacts are captured")
  for _, artifact in ipairs(cut.artifacts) do
    local namesPayload = false
    for _, path in ipairs(artifact.files) do
      if path == ownedPath then
        namesPayload = true
      end
    end
    Assert.isTrue(namesPayload, "each captured artifact names the payload it published")
  end

  reportOwned(dispatchMap("73"), "73", "contradiction")
  local state, details = pool:status("map:73")
  Assert.equal(state, "failed", "a contradictory owned output refuses the whole artifact")
  Assert.isTrue(
    tostring(details and details.error or ""):find("PREPARED_SHARED_CONFLICT", 1, true) ~= nil,
    "the contradiction names its cause: " .. tostring(details and details.error)
  )
  Assert.isTrue(
    pool:cacheFs():resolveAsset(ownedPath) == committed,
    "a contradiction never overwrites the committed payload"
  )
  Assert.isNil(
    pool:cacheFs():resolveAsset("data/generated/maps/73/complete"),
    "a contradictory artifact exposes no family output"
  )

  -- The boot side of a hydrate: the captured cut seeds a fresh committed
  -- generation as one payload and both artifact facts.
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 2)
    pool:seedCommittedGeneration(cut.entries, cut.artifacts)
  end)
  local seeded = assert(pool:cacheFs():resolveAsset(ownedPath), "a hydrated cut carries the payload")
  Assert.equal(seeded.data:getString(), "overlapped")
  local seededFacts = assert(pool:artifactFacts())
  for _, key in ipairs({ "71", "72" }) do
    Assert.notNil(ArtifactState.read(seededFacts, "map", key), "a hydrated cut keeps its fact: " .. key)
  end
  pool:shutdown()
end

function T.shutdown_is_idempotent_and_joins_workers()
  local CompilerPool = requirePool()
  local host = newThreadHost(4)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ versionId = "heartgold", mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  pool:shutdown()
  pool:shutdown()
  for _, thread in ipairs(host.threads) do
    Assert.equal(thread.waits, 1, "shutdown joins every worker once")
  end
end

-- A worker whose thread never provably joins forbids a successful
-- shutdown: the failure surfaces, the failed worker stays unjoined,
-- every other worker is still joined, and no later call can claim
-- success until the join genuinely completes.
function T.failed_worker_join_forbids_successful_shutdown()
  local CompilerPool = requirePool()
  local host = newThreadHost(4)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ versionId = "heartgold", mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  Assert.isTrue(#host.threads >= 2, "the pool starts at least two workers to join")
  local failing = assert(host.threads[1], "a first worker owns the injected failure")
  local realWait = failing.wait
  failing.wait = function(_)
    error("injected worker join failure", 0)
  end
  local firstOk, firstResult = pcall(function()
    return pool:shutdown()
  end)
  Assert.isFalse(firstOk and firstResult == true, "an unproved join never reports successful shutdown")
  Assert.isFalse(pool.workers[1].joined, "a failed wait never marks its worker joined")
  Assert.equal(host.threads[2].waits, 1, "shutdown still joins every other worker")
  failing.wait = realWait
  Assert.isTrue(pool:shutdown(), "a genuinely completed join reports success")
  Assert.isTrue(pool:shutdown(), "a proved shutdown stays idempotent")
  for _, thread in ipairs(host.threads) do
    Assert.equal(thread.waits, 1, "a proved shutdown joins every worker exactly once")
  end
end

function T.worker_dispatcher_rejects_unknown_job_kinds()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  Assert.throws(function()
    CompilerWorker.execute({ kind = "unknown", key = "unknown:1" }, {})
  end)
end

function T.plain_worker_failures_keep_their_message()
  local CompilerPool = requirePool()
  local prepared = requirePreparedArtifact()
  local ScopedFs = require("libs.storage.src.ScopedFs")
  local backendStore = FakeCache.new()
  local filesystem = {
    write = function(path, data)
      return backendStore:write(path, data)
    end,
    read = function(path)
      return backendStore:read(path)
    end,
    getInfo = function(path)
      return backendStore:getInfo(path)
    end,
    createDirectory = function(path)
      return backendStore:createDirectory(path)
    end,
    remove = function(path)
      return backendStore:remove(path)
    end,
    getDirectoryItems = function(path)
      return backendStore:getDirectoryItems(path)
    end,
  }
  local resultChannel = nil
  local inputChannels = {}
  local channels = {}
  local function newChannel()
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
      return self:pop()
    end
    function channel:getCount()
      return #values
    end
    channels[#channels + 1] = channel
    return channel
  end
  local function newThread()
    local thread = { starts = 0, waits = 0 }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return nil
    end
    function thread:isRunning()
      return self.starts > 0 and self.waits == 0
    end
    return thread
  end
  local fakeLove = {
    filesystem = filesystem,
    system = {
      getProcessorCount = function()
        return 2
      end,
    },
    timer = {
      getTime = function()
        return 0
      end,
    },
    thread = {
      newChannel = newChannel,
      newThread = newThread,
    },
  }
  local generationId = "plain-failure-generation"
  local pool = assert(withLove(fakeLove, function()
    local instance = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
    instance:selectGeneration({ versionId = "heartgold", generationId = generationId }, 1)
    instance:request({
      versionId = "heartgold",
      generationId = generationId,
      epoch = 1,
      kind = "map",
      key = "60",
      jobKey = "map:60",
      priority = 0,
      sizeClass = "normal",
      dependencies = {},
      payload = { mapId = 60 },
    })
    instance:update()
    return instance
  end))
  resultChannel = channels[1]
  for index = 2, #channels do
    inputChannels[#inputChannels + 1] = channels[index]
  end
  local dispatchId, workerId = nil, nil
  for offset, channel in ipairs(inputChannels) do
    local dispatched = channel:pop()
    if type(dispatched) == "table" and dispatched.jobKey == "map:60" then
      dispatchId = dispatched.dispatchId
      workerId = offset
    end
  end
  Assert.notNil(dispatchId, "the pool dispatched the job with its dispatch identity")
  Assert.notNil(workerId, "the pool dispatched the job to a known worker")
  local backend = withLove(fakeLove, function()
    return ScopedFs.loveBackend()
  end)
  local cache = CacheFs.forVersion("heartgold", backend)
  local artifact = prepared.new({
    cacheFs = cache,
    generationId = generationId,
    epoch = 1,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    dispatchId = dispatchId,
  })
  local cause = artifact:finishFailure("plain worker boom")
  resultChannel:push({
    workerId = workerId,
    epoch = 1,
    generationId = generationId,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    dispatchId = dispatchId,
    status = "failed",
    error = cause.message,
  })
  withLove(fakeLove, function()
    pool:update()
  end)
  local state, details = pool:status("map:60")
  Assert.equal(state, "failed", "the worker failure settles the job")
  local message = tostring(details and details.error or "")
  Assert.isTrue(
    message:find("plain worker boom", 1, true) ~= nil,
    "the surfaced failure keeps the worker message: " .. message
  )
  Assert.isTrue(
    message:find("table: 0x", 1, true) == nil,
    "the surfaced failure is never an opaque table address: " .. message
  )
  pool:shutdown()
end

-- An unstaged worker failure keeps the cause its completion carries: with
-- no prepared stage to open, the pool falls back to the worker-sent detail
-- before the generic fault. The second job proves a typed cause keeps its
-- code and throw-site trace, and that consecutive failures on one worker
-- never cross-contaminate.
function T.unstaged_worker_failures_keep_their_worker_cause()
  local CompilerPool = requirePool()
  local backendStore = FakeCache.new()
  local filesystem = {
    write = function(path, data)
      return backendStore:write(path, data)
    end,
    read = function(path)
      return backendStore:read(path)
    end,
    getInfo = function(path)
      return backendStore:getInfo(path)
    end,
    createDirectory = function(path)
      return backendStore:createDirectory(path)
    end,
    remove = function(path)
      return backendStore:remove(path)
    end,
    getDirectoryItems = function(path)
      return backendStore:getDirectoryItems(path)
    end,
  }
  local resultChannel = nil
  local inputChannels = {}
  local channels = {}
  local function newChannel()
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
      return self:pop()
    end
    function channel:getCount()
      return #values
    end
    channels[#channels + 1] = channel
    return channel
  end
  local function newThread()
    local thread = { starts = 0, waits = 0 }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return nil
    end
    function thread:isRunning()
      return self.starts > 0 and self.waits == 0
    end
    return thread
  end
  local fakeLove = {
    filesystem = filesystem,
    system = {
      getProcessorCount = function()
        return 2
      end,
    },
    timer = {
      getTime = function()
        return 0
      end,
    },
    thread = {
      newChannel = newChannel,
      newThread = newThread,
    },
  }
  local generationId = "unstaged-cause-generation"
  local pool = assert(withLove(fakeLove, function()
    local instance = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
    instance:selectGeneration({ versionId = "heartgold", generationId = generationId }, 1)
    instance:request({
      versionId = "heartgold",
      generationId = generationId,
      epoch = 1,
      kind = "map",
      key = "60",
      jobKey = "map:60",
      priority = 0,
      sizeClass = "normal",
      dependencies = {},
      payload = { mapId = 60 },
    })
    instance:request({
      versionId = "heartgold",
      generationId = generationId,
      epoch = 1,
      kind = "map",
      key = "61",
      jobKey = "map:61",
      priority = 0,
      sizeClass = "normal",
      dependencies = {},
      payload = { mapId = 61 },
    })
    instance:update()
    return instance
  end))
  resultChannel = channels[1]
  for index = 2, #channels do
    inputChannels[#inputChannels + 1] = channels[index]
  end
  local function popDispatch(jobKey)
    for offset, channel in ipairs(inputChannels) do
      local dispatched = channel:pop()
      if type(dispatched) == "table" and dispatched.jobKey == jobKey then
        return dispatched, offset
      end
    end
    return nil, nil
  end
  local first, firstWorker = popDispatch("map:60")
  Assert.notNil(first, "the pool dispatches the first job with a stage name")
  resultChannel:push({
    workerId = firstWorker,
    epoch = 1,
    generationId = generationId,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    dispatchId = first.dispatchId,
    status = "failed",
    error = "synthetic compile boom",
  })
  withLove(fakeLove, function()
    pool:update()
  end)
  local state60, details60 = pool:status("map:60")
  Assert.equal(state60, "failed", "the unstaged worker failure settles the job")
  local message60 = tostring(details60 and details60.error or "")
  Assert.isTrue(
    message60:find("synthetic compile boom", 1, true) ~= nil,
    "the surfaced failure keeps the worker message: " .. message60
  )
  Assert.isTrue(
    message60:find("worker failed", 1, true) == nil,
    "the surfaced failure is not the generic fault: " .. message60
  )
  local second, secondWorker = popDispatch("map:61")
  Assert.notNil(second, "the freed worker dispatches the second job")
  resultChannel:push({
    workerId = secondWorker,
    epoch = 1,
    generationId = generationId,
    kind = "map",
    key = "61",
    jobKey = "map:61",
    dispatchId = second.dispatchId,
    status = "failed",
    error = {
      code = "BAG_SOURCE_INVALID",
      message = "bag synthetic boom",
      context = { path = "assets/generated/maps/textures/drifted.png" },
      traceback = "stack traceback:\n\tsynthetic:1",
    },
  })
  withLove(fakeLove, function()
    pool:update()
  end)
  local state61, details61 = pool:status("map:61")
  Assert.equal(state61, "failed", "the typed worker failure settles the job")
  local message61 = tostring(details61 and details61.error or "")
  Assert.isTrue(
    message61:find("BAG_SOURCE_INVALID: bag synthetic boom", 1, true) ~= nil,
    "the surfaced failure keeps the typed cause: " .. message61
  )
  Assert.isTrue(
    message61:find("stack traceback", 1, true) ~= nil,
    "the surfaced failure keeps the throw-site trace: " .. message61
  )
  Assert.isTrue(
    message61:find("assets/generated/maps/textures/drifted.png", 1, true) ~= nil,
    "the surfaced failure keeps the diagnostic context: " .. message61
  )
  Assert.isTrue(
    message61:find("synthetic compile boom", 1, true) == nil,
    "consecutive failures never cross-contaminate: " .. message61
  )
  pool:shutdown()
end
-- A worker thread that stops behind a real command keeps truthful evidence:
-- The command preserves a worker failure recorded by the pool and joins the
-- worker exactly once. Real command, session, dependencies, and pool; only
-- the thread transport is controlled.
function T.stopped_worker_returns_recorded_failure_and_joins_worker()
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function(versionId)
    return realForVersion(versionId, backend)
  end
  local host = newThreadHost(2)
  host.control.stopOnDispatch = true
  local ok, outcome = pcall(function()
    return withLove(host.love, function()
      local report, err = CacheBuilder.prepareVersion("heartgold", {
        identity = {
          versionId = "heartgold",
          generationId = "stopped-worker-generation",
          producerId = "d" .. string.rep("1", 64),
        },
        requirements = { "field-camera:global", "field-weather:global" },
        log = function() end,
      })
      -- Box both returns: the transport helper keeps only the first value.
      return { report = report, failure = err }
    end)
  end)
  local report = ok and outcome.report or nil
  local err = ok and outcome.failure or outcome
  CacheFs.forVersion = realForVersion
  Assert.isTrue(ok, "a recorded pool failure is handled instead of escaping: " .. tostring(report))
  Assert.isNil(report, "an interrupted command returns no success report")
  Assert.equal(err, "compiler worker stopped unexpectedly", "the command preserves the recorded fatal value")
  Assert.equal(#host.dispatched, 1, "only the first job reaches a worker before the stop")
  Assert.equal(#host.threads, 1, "one physical worker serves the command")
  Assert.equal(host.threads[1].waits, 1, "the stopped worker joins exactly once")
end

-- Large-backlog dispatch keeps priority/FIFO/admission order without sorting
-- the queued corpus on the dispatch path: a promoted sweep job keeps its
-- original sequence among required jobs while weaker work waits.
function T.large_backlog_dispatch_preserves_order_without_whole_queue_sort()
  local CompilerPool = requirePool()
  local host = newThreadHost(3)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "backlog-order-generation"
  local function mapJob(key, mapId, priority, sizeClass)
    return {
      generationId = generation,
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = sizeClass or "normal",
      dependencies = {},
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    for index = 1, 1200 do
      pool:request(mapJob(tostring(30000 + index), 30000 + index, 100))
    end
    pool:request(mapJob("31201", 31201, 10))
    pool:request(mapJob("31202", 31202, 10))
    pool:request(mapJob("31203", 31203, 0))
    pool:request(mapJob("30001", 30001, 0))
    local realSort = table.sort
    table.sort = function(list)
      assert(#list <= 16, "hot-path whole-queue sort during dispatch")
      return realSort(list)
    end
    local ok, sortFailure = pcall(function()
      pool:update()
    end)
    table.sort = realSort
    if not ok then
      error(sortFailure, 0)
    end
  end)
  Assert.deepEqual(
    { host.dispatched[1], host.dispatched[2] },
    { "map:30001", "map:31203" },
    "the promoted sweep job keeps its original sequence ahead of the later required job"
  )
  Assert.equal(pool:status("map:30001"), "running", "the promoted job executes")
  Assert.equal(pool:status("map:31203"), "running", "the required job executes")
  Assert.equal(pool:status("map:31201"), "queued", "weaker work waits behind required")
  Assert.equal(pool:status("map:30002"), "queued", "the backlog waits behind required")
  pool:shutdown()
end

-- Stronger priority dispatches first while weaker work waits, all without
-- sorting the queued corpus on the dispatch path. Family labels reserve
-- nothing: a waiting jumbo takes the next free worker like any other job.
function T.stronger_priority_dispatches_first_without_sort()
  local CompilerPool = requirePool()
  local host = newThreadHost(3)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "jumbo-reservation-generation"
  local function mapJob(key, mapId, priority, sizeClass)
    return {
      generationId = generation,
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = sizeClass,
      dependencies = {},
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(mapJob("32001", 32001, 0, "heavy"))
    pool:update()
  end)
  Assert.deepEqual(host.dispatched, { "map:32001" }, "the heavy job takes the first worker")
  withLove(host.love, function()
    pool:request(mapJob("32002", 32002, 100, "jumbo"))
    pool:request(mapJob("32003", 32003, 100, "normal"))
    pool:request(mapJob("32004", 32004, 0, "normal"))
    local realSort = table.sort
    table.sort = function(list)
      assert(#list <= 16, "hot-path whole-queue sort during dispatch")
      return realSort(list)
    end
    local ok, sortFailure = pcall(function()
      pool:update()
    end)
    table.sort = realSort
    if not ok then
      error(sortFailure, 0)
    end
  end)
  Assert.deepEqual(
    host.dispatched,
    { "map:32001", "map:32004" },
    "the stronger arrival dispatches on the free worker while weaker work waits"
  )
  Assert.equal(pool:status("map:32002"), "queued", "the jumbo waits for a free worker")
  Assert.equal(pool:status("map:32003"), "queued", "same-priority work waits behind the queue head")
  local _, sweepDetails = pool:status("map:32003")
  Assert.equal(
    type(sweepDetails) == "table" and sweepDetails.waitingOn,
    "active-job",
    "the wait names physical occupancy"
  )
  pool:shutdown()
end

-- Promotion never leaves a dispatchable stale queue node and retry rejoins
-- behind older same-priority work with a fresh sequence.
function T.promotion_stale_nodes_never_dispatch_and_retry_takes_a_fresh_sequence()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "stale-node-generation"
  local function mapJob(key, mapId, priority)
    return {
      generationId = generation,
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      dependencies = {},
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(mapJob("33001", 33001, 100))
    pool:request(mapJob("33002", 33002, 100))
    pool:request(mapJob("33001", 33001, 0))
    pool:update()
  end)
  local dispatchedOrder = {}
  withLove(host.love, function()
    local dispatched = host.channels[2]:pop()
    assert(type(dispatched) == "table", "the worker received a job record")
    dispatchedOrder[#dispatchedOrder + 1] = assert(dispatched.jobKey, "dispatched work names its job")
    local dispatchId = assert(dispatched.dispatchId, "dispatched work carries its stage identity")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "33001",
      jobKey = "map:33001",
      dispatchId = dispatchId,
      status = "failed",
    })
    pool:update()
    Assert.equal(pool:status("map:33001"), "failed", "the worker failure settles the job")
    Assert.equal(pool:status("map:33002"), "running", "the waiter takes the freed worker")
    pool:request(mapJob("33003", 33003, 100))
    pool:retry("map:33001", 100)
    local runningMessage = host.channels[2]:pop()
    assert(type(runningMessage) == "table", "the waiter reached the worker")
    dispatchedOrder[#dispatchedOrder + 1] = assert(runningMessage.jobKey, "dispatched work names its job")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "33002",
      jobKey = "map:33002",
      dispatchId = assert(runningMessage.dispatchId, "dispatched work carries its stage identity"),
      status = "failed",
    })
    pool:update()
    local thirdMessage = host.channels[2]:pop()
    assert(type(thirdMessage) == "table", "the third job reached the worker")
    dispatchedOrder[#dispatchedOrder + 1] = assert(thirdMessage.jobKey, "dispatched work names its job")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "33003",
      jobKey = "map:33003",
      dispatchId = assert(thirdMessage.dispatchId, "dispatched work carries its stage identity"),
      status = "failed",
    })
    pool:update()
    local retriedMessage = host.channels[2]:pop()
    assert(type(retriedMessage) == "table", "the retried job reached the worker")
    dispatchedOrder[#dispatchedOrder + 1] = assert(retriedMessage.jobKey, "dispatched work names its job")
  end)
  Assert.deepEqual(
    dispatchedOrder,
    { "map:33001", "map:33002", "map:33003", "map:33001" },
    "the stale promotion node never dispatches and the retry rejoins last"
  )
  pool:shutdown()
end

-- Heavy/jumbo admission survives prepared pinning, selection retirement,
-- and late terminal replies: a prepared heavy blocks a second heavy, a
-- jumbo waits for the drain, an old physical heavy keeps blocking across a
-- new epoch, and its late reply releases exactly once.
-- Physical occupancy pins prepared results across retirement and late
-- completion: one prepared unpublished result per worker keeps its slot
-- whatever the family label, retirement never frees a running slot, and a
-- late terminal reply releases it exactly once. Family labels never
-- serialize the bounded workers.
function T.physical_occupancy_pins_prepared_results_across_retirement_and_late_completion()
  local CompilerPool = requirePool()
  local host = newThreadHost(3)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "scheduler-lifecycle-generation"
  local function mapJob(key, mapId, priority, sizeClass, epoch)
    return {
      generationId = generation,
      epoch = epoch or 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = sizeClass,
      dependencies = {},
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(mapJob("61", 61, 0, "heavy"))
    pool:update()
    Assert.equal(pool:status("map:61"), "running", "the heavy job executes")
    pool:request(mapJob("62", 62, 0, "normal"))
    pool:update()
    Assert.equal(pool:status("map:62"), "running", "a normal job overlaps the heavy job")
    local normalMessage = host.channels[3]:pop()
    assert(type(normalMessage) == "table", "the second worker received the normal job")
    local normalStage = assert(normalMessage.dispatchId, "dispatched work carries its stage identity")
    host.channels[1]:push({
      workerId = 2,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "62",
      jobKey = "map:62",
      dispatchId = normalStage,
      status = "failed",
    })
    pool:update()
    Assert.equal(pool:status("map:62"), "failed", "the normal job settles and frees its worker")
    Assert.equal(pool:status("map:61"), "running", "the heavy job still executes")
    -- No family exclusivity: the freed worker takes the next job whatever
    -- its label, and the jumbo queues only while both workers are busy.
    pool:request(mapJob("63", 63, 0, "heavy"))
    pool:request(mapJob("64", 64, 0, "jumbo"))
    pool:update()
    Assert.equal(pool:status("map:63"), "running", "the freed worker takes the next job")
    Assert.equal(pool:status("map:64"), "queued", "the jumbo waits while both workers are busy")
    local busyState, busyDetails = pool:status("map:64")
    Assert.equal(busyState, "queued", "the jumbo stays queued")
    Assert.equal(
      type(busyDetails) == "table" and busyDetails.waitingOn,
      "active-job",
      "the wait names physical occupancy, not a family rule"
    )
    local heavyMessage = host.channels[2]:pop()
    assert(type(heavyMessage) == "table", "the first worker received the heavy job")
    local heavyStage = assert(heavyMessage.dispatchId, "dispatched work carries its stage identity")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "61",
      jobKey = "map:61",
      dispatchId = heavyStage,
      status = "prepared",
      compileSeconds = 1,
      stageSeconds = 1,
      workSeconds = 1,
      stagedBytes = 8,
    })
    pool:update(0)
    Assert.equal(pool:status("map:61"), "prepared", "the prepared result stays pinned to its worker")
    pool:update()
    Assert.equal(
      pool:status("map:61"),
      "failed",
      "the terminal result releases admission even when publication finds no staged bytes"
    )
    Assert.equal(pool:status("map:64"), "running", "the freed worker takes the waiting jumbo")
    Assert.equal(pool:status("map:63"), "running", "the other worker still executes")
    Assert.isTrue(pool:retireSelection(1), "the selection retires while work executes")
    Assert.equal(pool:status("map:63"), "running", "retirement keeps the executing record")
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 2)
    pool:request(mapJob("65", 65, 0, "heavy", 2))
    local nextState, nextDetails = pool:status("map:65")
    Assert.equal(nextState, "queued", "the new epoch job waits")
    Assert.equal(
      type(nextDetails) == "table" and nextDetails.waitingOn,
      "active-job",
      "the retired physical occupancy still counts"
    )
    local retiredMessage = host.channels[3]:pop()
    assert(type(retiredMessage) == "table", "the retired job reached the second worker")
    local retiredStage = assert(retiredMessage.dispatchId, "retired work carries its stage identity")
    host.channels[1]:push({
      workerId = 2,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "63",
      jobKey = "map:63",
      dispatchId = retiredStage,
      status = "failed",
    })
    pool:update()
    Assert.equal(pool:status("map:65"), "running", "the late reply releases the retired slot exactly once")
    pool:request(mapJob("66", 66, 0, "heavy", 2))
    Assert.equal(pool:status("map:66"), "queued", "further work still waits behind the running jobs")
  end)
  pool:shutdown()
end
-- Controller publication is a move, not a copy: the committed bytes are the
-- worker's own immutable buffers, the reader serves those buffers, and no host
-- file is read or written for them.
function T.controller_publication_moves_payload_without_byte_copies()
  local CompilerPool = requirePool()
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newThreadHost(2)
  host.love.data = hostLove.data
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "payload-free-publication-generation"
  local scenePath = "data/generated/maps/60/scene.lua"
  local sharedPath = "data/generated/geometry/shared"
  local function bytes(text)
    return assert(hostLove.data.newByteData(text))
  end
  local scene = bytes(string.rep("scene-payload", 64))
  local shared = bytes(string.rep("shared-payload", 64))
  local writes, reads = {}, {}
  local filesystem = host.love.filesystem
  local realWrite, realRead = filesystem.write, filesystem.read
  filesystem.write = function(path, data)
    writes[#writes + 1] = path
    return realWrite(path, data)
  end
  filesystem.read = function(path)
    reads[#reads + 1] = path
    return realRead(path)
  end
  local ok, failure = pcall(function()
    withLove(host.love, function()
      pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
      pool:request({
        generationId = generation,
        epoch = 1,
        versionId = "heartgold",
        kind = "map",
        key = "60",
        jobKey = "map:60",
        priority = 0,
        sizeClass = "normal",
        dependencies = {},
        payload = { mapId = 60 },
      })
      pool:update()
    end)
    local dispatched = assert(host.channels[2]:pop(), "the worker received the job")
    writes, reads = {}, {}
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "60",
      jobKey = "map:60",
      dispatchId = dispatched.dispatchId,
      status = "prepared",
      marker = "payload-free-marker",
      ownedRoots = { "data/generated/maps/60" },
      sharedPaths = { sharedPath },
      entries = {
        { path = scenePath, data = scene, size = scene:getSize() },
        { path = sharedPath, data = shared, size = shared:getSize() },
      },
    })
    withLove(host.love, function()
      pool:update()
    end)
  end)
  filesystem.write = realWrite
  filesystem.read = realRead
  if not ok then
    error(failure, 0)
  end
  Assert.equal(pool:status("map:60"), "ready", "the sealed result commits")
  local reader = assert(pool:cacheFs(), "the selected generation owns its resident reader")
  Assert.isTrue(reader:readData(scenePath) == scene, "the owned payload is the worker's own buffer")
  Assert.isTrue(reader:readData(sharedPath) == shared, "the shared install is the worker's own buffer")
  for _, path in ipairs(reads) do
    Assert.isFalse(
      path:find("maps/60", 1, true) ~= nil or path:find("geometry/shared", 1, true) ~= nil,
      "controller publication reads no payload bytes: " .. tostring(path)
    )
  end
  for _, path in ipairs(writes) do
    Assert.isFalse(
      path:find("maps/60", 1, true) ~= nil or path:find("geometry/shared", 1, true) ~= nil,
      "controller publication copies no payload bytes: " .. tostring(path)
    )
  end
  Assert.equal(reader:readData(scenePath):getString(), scene:getString(), "the owned payload moves intact")
  Assert.equal(reader:readData(sharedPath):getString(), shared:getString(), "the shared install lands intact")
  pool:shutdown()
end

local function selectedInteractivePool(host, generation)
  local CompilerPool = requirePool()
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "interactive", developmentRepositoryRoot = "/checkout" })
  end))
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
  end)
  return pool
end

local function activityMapJob(generation, key, mapId, priority)
  return {
    generationId = generation,
    epoch = 1,
    versionId = "heartgold",
    kind = "map",
    key = key,
    jobKey = "map:" .. key,
    priority = priority,
    sizeClass = "normal",
    dependencies = {},
    payload = { mapId = mapId },
  }
end

local function observeActivity(host, pool)
  return withLove(host.love, function()
    return pool:activityState()
  end)
end

-- A fresh selected pool holds no local work and waits on no worker, so
-- it reads idle without scanning queued interest.
function T.fresh_selected_pool_reports_idle_with_no_work_outstanding()
  local host = newThreadHost(4)
  local pool = selectedInteractivePool(host, "activity-idle-generation")
  Assert.equal(observeActivity(host, pool), "idle", "a fresh selected pool holds no runnable or waiting work")
  pool:shutdown()
end

-- Queued work that can dispatch immediately reads runnable.
function T.queued_dispatchable_work_reports_runnable()
  local generation = "activity-dispatchable-generation"
  local host = newThreadHost(4)
  local pool = selectedInteractivePool(host, generation)
  withLove(host.love, function()
    pool:request(activityMapJob(generation, "60", 60, 0))
  end)
  Assert.equal(observeActivity(host, pool), "runnable", "dispatchable queued work can advance now")
  pool:shutdown()
end

-- A worker reply already waiting on the result channel reads runnable,
-- and classification consumes nothing.
function T.queued_worker_reply_reports_runnable_without_consuming_it()
  local generation = "activity-reply-generation"
  local host = newThreadHost(4)
  local pool = selectedInteractivePool(host, generation)
  withLove(host.love, function()
    pool:request(activityMapJob(generation, "60", 60, 0))
    pool:update()
  end)
  local dispatched = assert(host.channels[2]:pop(), "the worker received its job record")
  local dispatchId = assert(dispatched.dispatchId, "dispatched work carries its stage identity")
  host.channels[1]:push({
    workerId = 1,
    epoch = 1,
    generationId = generation,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    dispatchId = dispatchId,
    status = "failed",
  })
  Assert.equal(host.channels[1]:getCount(), 1, "the reply waits on the result channel")
  Assert.equal(observeActivity(host, pool), "runnable", "a queued worker reply can advance now")
  Assert.equal(host.channels[1]:getCount(), 1, "classification consumes no worker reply")
  pool:shutdown()
end

-- A prepared but unpublished completion reads runnable: publication can
-- advance without any new worker reply.
function T.prepared_completion_reports_runnable_before_publication()
  local generation = "activity-prepared-generation"
  local host = newThreadHost(4)
  local pool = selectedInteractivePool(host, generation)
  withLove(host.love, function()
    pool:request(activityMapJob(generation, "60", 60, 0))
    pool:update()
  end)
  local dispatched = assert(host.channels[2]:pop(), "the worker received its job record")
  local dispatchId = assert(dispatched.dispatchId, "dispatched work carries its stage identity")
  host.channels[1]:push({
    workerId = 1,
    epoch = 1,
    generationId = generation,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    dispatchId = dispatchId,
    status = "prepared",
  })
  withLove(host.love, function()
    pool:update(0)
  end)
  Assert.equal(pool:status("map:60"), "prepared", "the completion waits for publication")
  Assert.equal(observeActivity(host, pool), "runnable", "an unpublished prepared result can advance now")
  pool:shutdown()
end

-- A busy worker with queued work behind it reads waiting: nothing local
-- can advance, but progress depends on the outstanding worker reply.
function T.occupied_worker_with_blocked_queue_reports_waiting()
  local generation = "activity-blocked-generation"
  local host = newThreadHost(4)
  local pool = selectedInteractivePool(host, generation)
  withLove(host.love, function()
    pool:request(activityMapJob(generation, "60", 60, 100))
    pool:update()
    pool:request(activityMapJob(generation, "61", 61, 100))
  end)
  Assert.equal(pool:status("map:60"), "running", "the first background job holds the single slot")
  Assert.equal(pool:status("map:61"), "queued", "the second background job waits on the held slot")
  Assert.equal(observeActivity(host, pool), "waiting", "blocked background work waits on its worker")
  pool:shutdown()
end

-- A source-close barrier without its acknowledgement reads waiting:
-- the controller must keep polling, never block indefinitely.
function T.close_barrier_without_acknowledgement_reports_waiting()
  local host = newThreadHost(4)
  local pool = selectedInteractivePool(host, "activity-close-generation")
  withLove(host.love, function()
    pool:quiesce()
  end)
  Assert.isFalse(pool:isQuiescent(), "the close acknowledgement is still outstanding")
  Assert.equal(observeActivity(host, pool), "waiting", "an unacknowledged close waits on its worker")
  pool:shutdown()
end

-- A fatal pool condition never reads idle: the next drive must pump
-- and surface it through the failure path.
function T.fatal_pool_condition_never_reports_idle()
  local generation = "activity-fatal-generation"
  local host = newThreadHost(4)
  host.control.stopOnDispatch = true
  local pool = selectedInteractivePool(host, generation)
  withLove(host.love, function()
    pool:request(activityMapJob(generation, "60", 60, 0))
    pool:update()
  end)
  local ok, _ = pcall(function()
    withLove(host.love, function()
      pool:update()
    end)
  end)
  Assert.isFalse(ok, "the stopped worker surfaces its fatal condition")
  Assert.equal(observeActivity(host, pool), "runnable", "a fatal pool condition never reads idle")
  pool:shutdown()
end

-- Required demand beside running background work stays dispatchable: the
-- pool reads runnable while a free worker can take it.
function T.required_work_beside_running_background_reports_runnable()
  local generation = "activity-required-beside-background"
  local host = newThreadHost(6)
  local pool = selectedInteractivePool(host, generation)
  withLove(host.love, function()
    pool:request(activityMapJob(generation, "70", 70, 100))
    pool:update()
  end)
  Assert.equal(pool:status("map:70"), "running", "the background job occupies its worker")
  withLove(host.love, function()
    pool:request(activityMapJob(generation, "71", 71, 0))
  end)
  Assert.equal(observeActivity(host, pool), "runnable", "required demand beside background work can advance now")
  pool:shutdown()
end

-- Synthetic direct-source selection for the source-lifetime scenarios: a
-- valid cartridge under a temporary catalog identity, persisted to a
-- temporary file so the pool can acquire it exactly like a user-owned ROM.
-- The catalog entry and the temporary file are removed even when the body
-- fails; every acquisition runs through the isolated test cache.
local function withDirectSourceSelection(versionId, gameCode, fn)
  local RomSource = require("romdump.src.source.RomSource")
  local NdsBuilder = require("tests.support.NdsBuilder")
  local DumpFixture = require("tests.support.DumpFixture")
  local GameVersion = require("romdump.src.source.GameVersion")
  local NdsRom = require("romdump.src.source.NdsRom")
  local spec = DumpFixture.spec()
  spec.gameCode = gameCode
  local data = NdsBuilder.build(spec)
  local sha1 = RomSource.fromString(data):sha1()
  local unique = tostring(os.time()) .. "-" .. tostring({}):match("0x(%x+)")
  local romPath = (os.getenv("TMPDIR") or "/tmp") .. "/portemon-source-" .. versionId .. "-" .. unique .. ".nds"
  local file = assert(io.open(romPath, "wb"), "the isolated source fixture must be writable")
  file:write(data)
  file:close()
  local saved = GameVersion.VERSIONS[versionId]
  GameVersion.VERSIONS[versionId] = {
    id = versionId,
    label = "Synthetic",
    displayName = "Synthetic Cartridge",
    sha1 = sha1,
    gameCode = gameCode,
    expectedSize = #data,
  }
  local rom, romErr = NdsRom.open(RomSource.fromString(data))
  if rom == nil then
    GameVersion.VERSIONS[versionId] = saved
    os.remove(romPath)
    error("synthetic cartridge failed to open: " .. tostring(romErr), 0)
  end
  -- The pool resolves its version cache through the love backend, so point
  -- that seam at an isolated in-memory backend for the selection: binding
  -- registration and staged publication (both rename-based) then run
  -- hermetically, exactly as they would against the real save root.
  local ScopedFs = require("libs.storage.src.ScopedFs")
  local realLoveBackend = ScopedFs.loveBackend
  local backend = FakeCache.new()
  ScopedFs.loveBackend = function()
    return backend
  end
  local bodyOk, bodyErr = pcall(fn, { data = data, sha1 = sha1, romPath = romPath, rom = rom, backend = backend })
  ScopedFs.loveBackend = realLoveBackend
  GameVersion.VERSIONS[versionId] = saved
  os.remove(romPath)
  if not bodyOk then
    error(bodyErr, 0)
  end
end

local function sourceMapJob(versionId, generation, epoch, key, mapId, priority)
  return {
    generationId = generation,
    epoch = epoch,
    versionId = versionId,
    kind = "map",
    key = key,
    jobKey = "map:" .. key,
    priority = priority,
    sizeClass = "normal",
    dependencies = {},
    payload = { mapId = mapId },
  }
end

local function dispatchedJob(host, workerId)
  local channel = assert(host.channels[1 + workerId], "missing input channel for worker " .. tostring(workerId))
  local message = channel:pop()
  assert(type(message) == "table" and message.jobKey ~= nil, "worker " .. workerId .. " received no job")
  return message
end

local function drainMessages(host, workerId)
  local channel = assert(host.channels[1 + workerId], "missing input channel for worker " .. tostring(workerId))
  local messages = {}
  while true do
    local message = channel:pop()
    if message == nil then
      return messages
    end
    messages[#messages + 1] = message
  end
end

local function reportSourceNeeded(host, workerId, dispatched, epoch, generation)
  host.channels[1]:push({
    status = "source-needed",
    workerId = workerId,
    epoch = epoch,
    generationId = generation,
    kind = dispatched.kind,
    key = dispatched.key,
    jobKey = dispatched.jobKey,
    dispatchId = dispatched.dispatchId,
  })
end

local function findSupply(messages)
  for _, message in ipairs(messages) do
    if type(message) == "table" and message.kind == "source-supplied" then
      return message
    end
  end
  return nil
end

local function closeMessage(messages)
  for _, message in ipairs(messages) do
    if type(message) == "table" and message.kind == "close-context" then
      return message
    end
  end
  return nil
end

-- The shared handle must travel by reference: the reply carries a real
-- buffer userdata, never a whole-buffer string copy of the ROM bytes.
local function assertSharedSupply(supply, data, owner)
  Assert.notNil(supply, "the pool answers " .. owner .. " with a source supply")
  local answered = assert(supply, "the pool answers " .. owner .. " with a source supply")
  Assert.equal(type(answered.romByteData), "userdata", "the supply carries the shared buffer by reference")
  for key, value in pairs(answered) do
    Assert.isFalse(
      type(value) == "string" and #value == #data and value == data,
      "the supply never copies the whole buffer into a string field: " .. tostring(key)
    )
  end
  return answered
end

-- The sealed output one compiled map carries back to the controller: a
-- private entry list plus the completion fact, exactly as the worker reports
-- it. The bytes never touch a host file.
local function sealedMapOutput(cacheFs, generation, epoch, key)
  local prepared = requirePreparedArtifact()
  local artifact = prepared.new({
    cacheFs = cacheFs,
    generationId = generation,
    epoch = epoch,
    kind = "map",
    key = key,
    jobKey = "map:" .. key,
  })
  artifact:write("data/generated/maps/" .. key .. "/complete", "ready")
  artifact:addOwnedRoot("data/generated/maps/" .. key)
  artifact:finishSuccess({ mapId = tonumber(key), marker = "sweep-marker" })
  local sealed = artifact:sealed()
  local entry = assert(sealed.entries[1], "a sealed map carries its output")
  return {
    path = entry.path,
    data = entry.data,
    size = entry.data:getSize(),
    marker = sealed.marker,
    ownedRoots = sealed.ownedRoots,
    sharedPaths = sealed.sharedPaths,
  }
end

local function pushPrepared(host, workerId, epoch, generation, key, dispatchId, cacheFs)
  local output = sealedMapOutput(cacheFs, generation, epoch, key)
  host.channels[1]:push({
    workerId = workerId,
    epoch = epoch,
    generationId = generation,
    kind = "map",
    key = key,
    jobKey = "map:" .. key,
    dispatchId = dispatchId,
    status = "prepared",
    marker = output.marker,
    ownedRoots = output.ownedRoots,
    sharedPaths = output.sharedPaths,
    entries = { { path = output.path, data = output.data, size = output.size } },
  })
end

-- Two concurrent misses open the registered ROM exactly once and lend both
-- workers the identical buffer: no per-worker file open, no second 128 MiB
-- allocation, no whole-buffer string copy through the channels.
function T.concurrent_source_misses_share_one_buffer_by_reference()
  local CompilerPool = requirePool()
  local RomSource = require("romdump.src.source.RomSource")
  local RomBinding = require("romdump.src.source.RomBinding")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  withDirectSourceSelection("synthshared", "IXS2", function(selection)
    local host = newThreadHost(4)
    host.love.data = hostLove.data
    local realFromPath = RomSource.fromPath
    local fromPathCalls = 0
    RomSource.fromPath = function(path)
      fromPathCalls = fromPathCalls + 1
      return realFromPath(path)
    end
    local bodyOk, bodyErr = pcall(function()
      local outcome = withLove(host.love, function()
        local pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
        local cache = CacheFs.forVersion("synthshared")
        local recorded, recordErr = RomBinding.record(cache, selection.rom, {
          kind = "nds",
          path = selection.romPath,
          displayName = "synthetic.nds",
          zipEntry = false,
        })
        Assert.notNil(recorded, "the binding registers the synthetic ROM: " .. tostring(recordErr))
        pool:selectGeneration({ versionId = "synthshared", generationId = "shared-generation" }, 1)
        pool:request(sourceMapJob("synthshared", "shared-generation", 1, "60", 60, 0))
        pool:request(sourceMapJob("synthshared", "shared-generation", 1, "61", 61, 0))
        pool:update()
        Assert.equal(pool:status("map:60"), "running", "the first miss dispatches")
        Assert.equal(pool:status("map:61"), "running", "the concurrent miss dispatches")
        local first = dispatchedJob(host, 1)
        local second = dispatchedJob(host, 2)
        reportSourceNeeded(host, 1, first, 1, "shared-generation")
        reportSourceNeeded(host, 2, second, 1, "shared-generation")
        local driveOk, driveErr = pcall(function()
          pool:update()
        end)
        local replies1 = drainMessages(host, 1)
        local replies2 = drainMessages(host, 2)
        pcall(function()
          pool:shutdown()
        end)
        return { driveOk = driveOk, driveErr = driveErr, replies1 = replies1, replies2 = replies2 }
      end)
      Assert.isTrue(
        outcome.driveOk,
        "the pool acquires one shared buffer for concurrent misses: " .. tostring(outcome.driveErr)
      )
      Assert.equal(fromPathCalls, 1, "two concurrent misses cause exactly one external acquisition")
      local firstSupply = assertSharedSupply(findSupply(outcome.replies1), selection.data, "the first worker")
      local secondSupply = assertSharedSupply(findSupply(outcome.replies2), selection.data, "the second worker")
      Assert.isTrue(
        firstSupply.romByteData == secondSupply.romByteData,
        "both workers borrow the identical buffer object"
      )
    end)
    RomSource.fromPath = realFromPath
    if not bodyOk then
      error(bodyErr, 0)
    end
  end)
end

-- The complete sweep keeps its scheduling from a direct source: the
-- required job overtakes background admission, every planned member
-- settles in memory, and settling ready work evicts nothing. The required
-- miss compiles through the one shared buffer; a background member settles
-- from its own in-memory result without source traffic.
function T.background_sweep_compiles_from_shared_source_without_evicting_ready_work()
  local CompilerPool = requirePool()
  local RomSource = require("romdump.src.source.RomSource")
  local RomBinding = require("romdump.src.source.RomBinding")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  withDirectSourceSelection("synthsweep", "IXS3", function(selection)
    local host = newThreadHost(4)
    host.love.data = hostLove.data
    local realFromPath = RomSource.fromPath
    local fromPathCalls = 0
    RomSource.fromPath = function(path)
      fromPathCalls = fromPathCalls + 1
      return realFromPath(path)
    end
    local bodyOk, bodyErr = pcall(function()
      local outcome = withLove(host.love, function()
        local pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
        local cache = CacheFs.forVersion("synthsweep")
        local recorded, recordErr = RomBinding.record(cache, selection.rom, {
          kind = "nds",
          path = selection.romPath,
          displayName = "synthetic.nds",
          zipEntry = false,
        })
        Assert.notNil(recorded, "the binding registers the synthetic ROM: " .. tostring(recordErr))
        pool:selectGeneration({ versionId = "synthsweep", generationId = "sweep-generation" }, 1)
        pool:request(sourceMapJob("synthsweep", "sweep-generation", 1, "60", 60, 0))
        pool:request(sourceMapJob("synthsweep", "sweep-generation", 1, "61", 61, 100))
        pool:request(sourceMapJob("synthsweep", "sweep-generation", 1, "62", 62, 100))
        pool:update()
        local required = dispatchedJob(host, 1)
        Assert.equal(required.jobKey, "map:60", "the required job overtakes background admission")
        local background = dispatchedJob(host, 2)
        Assert.equal(background.jobKey, "map:61", "background work still admits beside the required job")
        pushPrepared(host, 2, 1, "sweep-generation", "61", background.dispatchId, pool:cacheFs())
        pool:update()
        Assert.equal(pool:status("map:61"), "ready", "the background member settles without source traffic")
        Assert.equal(fromPathCalls, 0, "a settled background member acquires no source")
        reportSourceNeeded(host, 1, required, 1, "sweep-generation")
        local driveOk, driveErr = pcall(function()
          pool:update()
        end)
        if not driveOk then
          pcall(function()
            pool:shutdown()
          end)
          return { driveOk = driveOk, driveErr = driveErr }
        end
        local supply = findSupply(drainMessages(host, 1))
        assertSharedSupply(supply, selection.data, "the required miss")
        pushPrepared(host, 1, 1, "sweep-generation", "60", required.dispatchId, pool:cacheFs())
        pool:update()
        Assert.equal(pool:status("map:60"), "ready", "the required miss compiles and publishes")
        local last = dispatchedJob(host, 2)
        Assert.equal(last.jobKey, "map:62", "the sweep continues through every planned member")
        pushPrepared(host, 2, 1, "sweep-generation", "62", last.dispatchId, pool:cacheFs())
        pool:update()
        local diagnostics = pool:diagnostics()
        pcall(function()
          pool:shutdown()
        end)
        return {
          driveOk = true,
          status60 = pool:status("map:60"),
          status61 = pool:status("map:61"),
          status62 = pool:status("map:62"),
          ready = diagnostics.counts.ready,
          cancelled = diagnostics.counts.cancelled,
        }
      end)
      Assert.isTrue(
        outcome.driveOk,
        "the sweep hands its required miss to the shared source: " .. tostring(outcome.driveErr)
      )
      Assert.equal(fromPathCalls, 1, "the sweep acquires its source exactly once")
      Assert.equal(outcome.status60, "ready", "the required member settles")
      Assert.equal(outcome.status61, "ready", "the first background member settles")
      Assert.equal(outcome.status62, "ready", "the trailing background member settles")
      Assert.equal(outcome.ready, 3, "every planned member is ready")
      Assert.equal(outcome.cancelled, 0, "settling ready work cancels nothing")
    end)
    RomSource.fromPath = realFromPath
    if not bodyOk then
      error(bodyErr, 0)
    end
  end)
end

-- The pool-owned buffer outlives any single job but never a borrower: the
-- pool closes borrowers only after the sweep settles, keeps the buffer
-- while one close is still outstanding, drops it after the last
-- acknowledgement, reacquires exactly once on the next miss, and never
-- lets a stale epoch touch the new selection.
function T.source_release_waits_for_every_borrower_close_then_reacquires_on_demand()
  local CompilerPool = requirePool()
  local RomSource = require("romdump.src.source.RomSource")
  local RomBinding = require("romdump.src.source.RomBinding")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  withDirectSourceSelection("synthrelease", "IXS4", function(selection)
    local host = newThreadHost(4)
    host.love.data = hostLove.data
    local realFromPath = RomSource.fromPath
    local fromPathCalls = 0
    RomSource.fromPath = function(path)
      fromPathCalls = fromPathCalls + 1
      return realFromPath(path)
    end
    local bodyOk, bodyErr = pcall(function()
      local outcome = withLove(host.love, function()
        local pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
        local cache = CacheFs.forVersion("synthrelease")
        local recorded, recordErr = RomBinding.record(cache, selection.rom, {
          kind = "nds",
          path = selection.romPath,
          displayName = "synthetic.nds",
          zipEntry = false,
        })
        Assert.notNil(recorded, "the binding registers the synthetic ROM: " .. tostring(recordErr))
        pool:selectGeneration({ versionId = "synthrelease", generationId = "release-generation" }, 1)
        pool:request(sourceMapJob("synthrelease", "release-generation", 1, "60", 60, 0))
        pool:request(sourceMapJob("synthrelease", "release-generation", 1, "61", 61, 0))
        pool:update()
        local first = dispatchedJob(host, 1)
        local second = dispatchedJob(host, 2)
        reportSourceNeeded(host, 1, first, 1, "release-generation")
        reportSourceNeeded(host, 2, second, 1, "release-generation")
        local driveOk, driveErr = pcall(function()
          pool:update()
        end)
        if not driveOk then
          pcall(function()
            pool:shutdown()
          end)
          return { driveOk = driveOk, driveErr = driveErr }
        end
        local firstSupply = assertSharedSupply(findSupply(drainMessages(host, 1)), selection.data, "the first borrower")
        local secondSupply =
          assertSharedSupply(findSupply(drainMessages(host, 2)), selection.data, "the second borrower")
        Assert.isTrue(firstSupply.romByteData == secondSupply.romByteData, "both borrowers share one backing")
        local sharedBuffer = firstSupply.romByteData
        -- Both jobs settle with the sweep exhausted and no further
        -- interest: the pool must now ask every borrower to close.
        pushPrepared(host, 1, 1, "release-generation", "60", first.dispatchId, pool:cacheFs())
        pushPrepared(host, 2, 1, "release-generation", "61", second.dispatchId, pool:cacheFs())
        pool:update(math.huge)
        Assert.equal(pool:status("map:60"), "ready", "the first job settles")
        Assert.equal(pool:status("map:61"), "ready", "the second job settles")
        local firstClose = closeMessage(drainMessages(host, 1))
        local secondClose = closeMessage(drainMessages(host, 2))
        Assert.notNil(firstClose, "the settled sweep closes the first borrower")
        Assert.notNil(secondClose, "the settled sweep closes the second borrower")
        -- One acknowledgement is not enough: a later miss must still find
        -- the retained buffer instead of acquiring again.
        host.channels[1]:push({ status = "context-closed", workerId = 1, closeToken = firstClose.closeToken })
        pool:update()
        pool:request(sourceMapJob("synthrelease", "release-generation", 1, "62", 62, 0))
        pool:update()
        local third = dispatchedJob(host, 1)
        reportSourceNeeded(host, 1, third, 1, "release-generation")
        local retainOk, retainErr = pcall(function()
          pool:update()
        end)
        local retainedSupply = findSupply(drainMessages(host, 1))
        -- The last acknowledgement releases the buffer: the next miss
        -- acquires exactly once more.
        host.channels[1]:push({ status = "context-closed", workerId = 2, closeToken = secondClose.closeToken })
        pool:update()
        pool:request(sourceMapJob("synthrelease", "release-generation", 1, "63", 63, 0))
        pool:update()
        local fourth = dispatchedJob(host, 2)
        reportSourceNeeded(host, 2, fourth, 1, "release-generation")
        local reacquireOk, reacquireErr = pcall(function()
          pool:update()
        end)
        local reacquiredSupply = findSupply(drainMessages(host, 2))
        -- A stale first-epoch request against the reselected generation
        -- acquires nothing and disturbs nothing.
        pool:selectGeneration({ versionId = "synthrelease", generationId = "release-generation" }, 2)
        pool:request(sourceMapJob("synthrelease", "release-generation", 2, "64", 64, 0))
        host.channels[1]:push({
          status = "source-needed",
          workerId = 1,
          epoch = 1,
          generationId = "release-generation",
          kind = "map",
          key = "60",
          jobKey = "map:60",
          dispatchId = first.dispatchId,
        })
        local staleOk, staleErr = pcall(function()
          pool:update()
        end)
        local staleReplies = drainMessages(host, 1)
        local newStatus = pool:status("map:64")
        pcall(function()
          pool:shutdown()
        end)
        return {
          driveOk = true,
          sharedBuffer = sharedBuffer,
          retainOk = retainOk,
          retainErr = retainErr,
          retainedSupply = retainedSupply,
          reacquireOk = reacquireOk,
          reacquireErr = reacquireErr,
          reacquiredSupply = reacquiredSupply,
          staleOk = staleOk,
          staleErr = staleErr,
          staleReplies = staleReplies,
          newStatus = newStatus,
        }
      end)
      Assert.isTrue(outcome.driveOk, "the pool lends one buffer to both borrowers: " .. tostring(outcome.driveErr))
      Assert.isTrue(
        outcome.retainOk,
        "one outstanding close keeps the buffer without a new acquisition: " .. tostring(outcome.retainErr)
      )
      local retained = assertSharedSupply(outcome.retainedSupply, selection.data, "the retained buffer")
      Assert.isTrue(
        retained.romByteData == outcome.sharedBuffer,
        "the later miss reuses the retained buffer instead of acquiring again"
      )
      Assert.isTrue(outcome.reacquireOk, "the miss after the last close reacquires: " .. tostring(outcome.reacquireErr))
      assertSharedSupply(outcome.reacquiredSupply, selection.data, "the post-release miss")
      Assert.equal(fromPathCalls, 2, "exactly one acquisition before release and one after")
      Assert.isTrue(outcome.staleOk, "a stale epoch request never breaks the pool: " .. tostring(outcome.staleErr))
      Assert.isNil(findSupply(outcome.staleReplies), "a stale request earns no supply")
      Assert.isTrue(
        outcome.newStatus == "queued" or outcome.newStatus == "running",
        "the reselected generation keeps its own interest: " .. tostring(outcome.newStatus)
      )
    end)
    RomSource.fromPath = realFromPath
    if not bodyOk then
      error(bodyErr, 0)
    end
  end)
end

-- A repeated request for the same live slot and a request from an unknown
-- worker fabricate nothing: the duplicate is answered idempotently from
-- the retained buffer, the stranger earns no supply, and neither triggers
-- a second acquisition nor disturbs the live selection.
function T.duplicate_and_unknown_source_requests_acquire_nothing_extra()
  local CompilerPool = requirePool()
  local RomSource = require("romdump.src.source.RomSource")
  local RomBinding = require("romdump.src.source.RomBinding")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  withDirectSourceSelection("synthduplicate", "IXDP", function(selection)
    local host = newThreadHost(4)
    host.love.data = hostLove.data
    local realFromPath = RomSource.fromPath
    local fromPathCalls = 0
    RomSource.fromPath = function(path)
      fromPathCalls = fromPathCalls + 1
      return realFromPath(path)
    end
    local bodyOk, bodyErr = pcall(function()
      local outcome = withLove(host.love, function()
        local pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
        local cache = CacheFs.forVersion("synthduplicate")
        local recorded, recordErr = RomBinding.record(cache, selection.rom, {
          kind = "nds",
          path = selection.romPath,
          displayName = "synthetic.nds",
          zipEntry = false,
        })
        Assert.notNil(recorded, "the binding registers the synthetic ROM: " .. tostring(recordErr))
        pool:selectGeneration({ versionId = "synthduplicate", generationId = "dup-generation" }, 1)
        pool:request(sourceMapJob("synthduplicate", "dup-generation", 1, "60", 60, 0))
        pool:update()
        local first = dispatchedJob(host, 1)
        reportSourceNeeded(host, 1, first, 1, "dup-generation")
        local driveOk, driveErr = pcall(function()
          pool:update()
        end)
        if not driveOk then
          pcall(function()
            pool:shutdown()
          end)
          return { driveOk = driveOk, driveErr = driveErr }
        end
        local firstSupply = assertSharedSupply(findSupply(drainMessages(host, 1)), selection.data, "the first answer")
        -- The same live slot asks again: the retained buffer answers
        -- without a second acquisition.
        reportSourceNeeded(host, 1, first, 1, "dup-generation")
        local duplicateOk, duplicateErr = pcall(function()
          pool:update()
        end)
        local secondSupply = findSupply(drainMessages(host, 1))
        -- A stranger names no live slot: it earns no supply and no
        -- acquisition, and the pool keeps serving its selection.
        host.channels[1]:push({
          status = "source-needed",
          workerId = 99,
          epoch = 1,
          generationId = "dup-generation",
          kind = "map",
          key = "60",
          jobKey = "map:60",
          dispatchId = first.dispatchId,
        })
        local strangerOk, strangerErr = pcall(function()
          pool:update()
        end)
        local strangerSupplies = {}
        for _, workerId in ipairs({ 1, 2 }) do
          for _, message in ipairs(drainMessages(host, workerId)) do
            if type(message) == "table" and message.kind == "source-supplied" then
              strangerSupplies[#strangerSupplies + 1] = message
            end
          end
        end
        pool:request(sourceMapJob("synthduplicate", "dup-generation", 1, "61", 61, 0))
        pool:update()
        local followup = pool:status("map:61")
        pcall(function()
          pool:shutdown()
        end)
        return {
          driveOk = true,
          firstSupply = firstSupply,
          duplicateOk = duplicateOk,
          duplicateErr = duplicateErr,
          secondSupply = secondSupply,
          strangerOk = strangerOk,
          strangerErr = strangerErr,
          strangerSupplies = strangerSupplies,
          followup = followup,
        }
      end)
      Assert.isTrue(outcome.driveOk, "the first miss acquires its buffer: " .. tostring(outcome.driveErr))
      Assert.isTrue(
        outcome.duplicateOk,
        "a duplicate live request never breaks the pool: " .. tostring(outcome.duplicateErr)
      )
      local second = assertSharedSupply(outcome.secondSupply, selection.data, "the duplicate answer")
      Assert.isTrue(
        second.romByteData == outcome.firstSupply.romByteData,
        "the duplicate borrows the identical retained buffer"
      )
      Assert.isTrue(outcome.strangerOk, "an unknown worker never breaks the pool: " .. tostring(outcome.strangerErr))
      Assert.equal(#outcome.strangerSupplies, 0, "an unknown worker earns no supply")
      Assert.equal(fromPathCalls, 1, "duplicates and strangers acquire nothing extra")
      Assert.isTrue(
        outcome.followup == "queued" or outcome.followup == "running",
        "the live selection keeps serving: " .. tostring(outcome.followup)
      )
    end)
    RomSource.fromPath = realFromPath
    if not bodyOk then
      error(bodyErr, 0)
    end
  end)
end

-- Release timing follows the sweep, not pool idleness: while the
-- completion owner still has unsettled source work, an idle pool keeps
-- its buffer instead of opening a release round; once the sweep settles,
-- the same idle pool closes borrowers as usual.
function T.source_release_waits_for_settled_sweep_work_before_closing_borrowers()
  local CompilerPool = requirePool()
  local RomSource = require("romdump.src.source.RomSource")
  local RomBinding = require("romdump.src.source.RomBinding")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  withDirectSourceSelection("synthhold", "IXS5", function(selection)
    local host = newThreadHost(4)
    host.love.data = hostLove.data
    local bodyOk, bodyErr = pcall(function()
      local outcome = withLove(host.love, function()
        local pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
        local cache = CacheFs.forVersion("synthhold")
        local recorded, recordErr = RomBinding.record(cache, selection.rom, {
          kind = "nds",
          path = selection.romPath,
          displayName = "synthetic.nds",
          zipEntry = false,
        })
        Assert.notNil(recorded, "the binding registers the synthetic ROM: " .. tostring(recordErr))
        pool:selectGeneration({ versionId = "synthhold", generationId = "hold-generation" }, 1)
        -- The sweep still owns future source work: the pool must not
        -- open a release round even once its own queues drain.
        local settled = false
        pool.sourceSettledQuery = function()
          return settled
        end
        pool:request(sourceMapJob("synthhold", "hold-generation", 1, "60", 60, 0))
        pool:update()
        local first = dispatchedJob(host, 1)
        reportSourceNeeded(host, 1, first, 1, "hold-generation")
        pool:update()
        assertSharedSupply(findSupply(drainMessages(host, 1)), selection.data, "the borrower")
        pushPrepared(host, 1, 1, "hold-generation", "60", first.dispatchId, pool:cacheFs())
        pool:update(math.huge)
        Assert.equal(pool:status("map:60"), "ready", "the job settles")
        Assert.isNil(
          closeMessage(drainMessages(host, 1)),
          "an unsettled sweep keeps the idle buffer without closing borrowers"
        )
        -- The same idle pool closes borrowers once the sweep settles.
        settled = true
        pool:update()
        local close = closeMessage(drainMessages(host, 1))
        Assert.notNil(close, "a settled sweep closes the borrower")
        host.channels[1]:push({ status = "context-closed", workerId = 1, closeToken = close.closeToken })
        pool:update()
        pcall(function()
          pool:shutdown()
        end)
        return { closeToken = close.closeToken }
      end)
      Assert.notNil(outcome.closeToken, "the settled close carries its barrier token")
    end)
    if not bodyOk then
      error(bodyErr, 0)
    end
  end)
end

-- One boot-held source survives the gap before warming: a composed
-- selection plus boot gate opens the registered synthetic cartridge
-- exactly once, idle pool updates across the pre-sweep gap reopen nothing
-- and keep the identical buffer, and retirement releases it through the
-- exact barrier. No offer is involved; the file binding alone suffices.
function T.boot_held_source_survives_idle_until_retirement()
  local RomSource = require("romdump.src.source.RomSource")
  local RomBinding = require("romdump.src.source.RomBinding")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  withDirectSourceSelection("heartgold", "IPKE", function(selection)
    local host = newThreadHost(4)
    host.love.data = hostLove.data
    local realFromPath = RomSource.fromPath
    local fromPathCalls = 0
    RomSource.fromPath = function(path, options)
      fromPathCalls = fromPathCalls + 1
      return realFromPath(path, options)
    end
    local bodyOk, bodyErr = pcall(function()
      local cache = CacheFs.forVersion("heartgold")
      local recorded, recordErr = RomBinding.record(cache, selection.rom, {
        kind = "nds",
        path = selection.romPath,
        displayName = "synthetic.nds",
        zipEntry = false,
      })
      Assert.notNil(recorded, "the binding registers the synthetic ROM: " .. tostring(recordErr))
      local CacheService = require("app.src.CacheService")
      local Worker = require("romdump.src.build.CacheControllerWorker").Worker
      local service = assert(CacheService.new({ thread = host.love.thread }))
      local worker = Worker.new(service._command, service._reply)
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
      withLove(host.love, function()
        worker:step()
      end)
      service:update()
      local status, _ = service:bootSourceStatus(epoch)
      Assert.equal(status, "ready", "the registered synthetic source satisfies the boot gate")
      Assert.equal(fromPathCalls, 1, "the boot preflight opens the registered source exactly once")
      local pool = assert(worker.pool, "the selection owns its compiler pool")
      local held = pool.sharedSource
      local heldBuffer = type(held) == "table" and held.byteData or held
      Assert.isTrue(heldBuffer ~= nil, "the preflight pins one shared buffer")
      withLove(host.love, function()
        for _ = 1, 5 do
          pool:update()
        end
      end)
      Assert.equal(fromPathCalls, 1, "idle pre-sweep updates reopen nothing")
      local idleHeld = pool.sharedSource
      local idleBuffer = type(idleHeld) == "table" and idleHeld.byteData or idleHeld
      Assert.isTrue(idleBuffer == heldBuffer, "the idle gap keeps the identical buffer")
      local barrier = assert(service:retire(epoch), "retirement returns its barrier identity")
      service:update()
      withLove(host.love, function()
        worker:step()
      end)
      service:update()
      Assert.equal(service:barrierStatus(epoch, barrier), "ready", "the retirement acknowledgement lands")
      Assert.isNil(pool.sharedSource, "retirement releases the boot-held buffer")
      service:shutdown()
      withLove(host.love, function()
        pool:shutdown()
      end)
    end)
    RomSource.fromPath = realFromPath
    if not bodyOk then
      error(bodyErr, 0)
    end
  end)
end

-- A boot-held buffer survives borrower-free idle updates across the
-- pre-sweep gap, while quiescence overrides the hold: the next idle
-- update drops the buffer through the ordinary borrower-free path.
function T.boot_hold_survives_borrower_free_idle_and_quiesce_overrides_it()
  local CompilerPool = requirePool()
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newThreadHost(4)
  host.love.data = hostLove.data
  withLove(host.love, function()
    local pool = CompilerPool.new({ mode = "interactive", developmentRepositoryRoot = "/checkout" })
    pool:selectGeneration({ versionId = "heartgold", generationId = "hold-generation" }, 1)
    local info = GameVersion.info("heartgold")
    local buffer = hostLove.data.newByteData("synthetic-boot-bytes")
    Assert.isTrue(
      pool:offerSource(1, buffer, { versionId = "heartgold", romSha1 = info.sha1 }),
      "the live offer is accepted"
    )
    Assert.isTrue(pool:prepareBootSource(1, true), "the preflight pins the offered buffer")
    Assert.isTrue(pool.sharedSource.byteData == buffer, "the preflight pins the identical buffer")
    for _ = 1, 5 do
      pool:update()
    end
    Assert.isTrue(
      pool.sharedSource ~= nil and pool.sharedSource.byteData == buffer,
      "borrower-free idle updates keep the boot-held buffer"
    )
    pool:quiesce()
    pool:update()
    Assert.isNil(pool.sharedSource, "quiescence overrides the hold and the idle buffer drops")
    pool:shutdown()
  end)
end

-- A no-source preflight discards a queued offer with zero file IO and
-- retains nothing: a later source preflight must open the registration
-- instead of resurrecting the discarded bytes.
function T.boot_preflight_without_source_discards_offer_with_zero_io()
  local CompilerPool = requirePool()
  local RomSource = require("romdump.src.source.RomSource")
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newThreadHost(4)
  host.love.data = hostLove.data
  local realFromPath = RomSource.fromPath
  local fromPathCalls = 0
  RomSource.fromPath = function(path, options)
    fromPathCalls = fromPathCalls + 1
    return realFromPath(path, options)
  end
  local bodyOk, bodyErr = pcall(function()
    withLove(host.love, function()
      local pool = CompilerPool.new({ mode = "interactive", developmentRepositoryRoot = "/checkout" })
      pool:selectGeneration({ versionId = "heartgold", generationId = "complete-generation" }, 1)
      local info = GameVersion.info("heartgold")
      local buffer = hostLove.data.newByteData("synthetic-boot-bytes")
      Assert.isTrue(
        pool:offerSource(1, buffer, { versionId = "heartgold", romSha1 = info.sha1 }),
        "the live offer is accepted"
      )
      Assert.isTrue(pool:prepareBootSource(1, false), "the no-source preflight succeeds")
      Assert.equal(fromPathCalls, 0, "the fast path performs zero source opens")
      Assert.isNil(pool.sharedSource, "the fast path retains no buffer")
      local held, failure = pool:prepareBootSource(1, true)
      Assert.isNil(held, "no discarded offer resurrects a later preflight")
      Assert.equal(failure.code, "ROM_SOURCE_REQUIRED", "the later preflight reads its registration")
      pool:shutdown()
    end)
  end)
  RomSource.fromPath = realFromPath
  if not bodyOk then
    error(bodyErr, 0)
  end
end

-- Hold release and preflight both refuse foreign epochs without effect;
-- releasing the live hold drops the idle buffer at once.
function T.boot_hold_release_refuses_stale_epoch()
  local CompilerPool = requirePool()
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newThreadHost(4)
  host.love.data = hostLove.data
  withLove(host.love, function()
    local pool = CompilerPool.new({ mode = "interactive", developmentRepositoryRoot = "/checkout" })
    pool:selectGeneration({ versionId = "heartgold", generationId = "release-generation" }, 1)
    local info = GameVersion.info("heartgold")
    local buffer = hostLove.data.newByteData("synthetic-boot-bytes")
    Assert.isTrue(
      pool:offerSource(1, buffer, { versionId = "heartgold", romSha1 = info.sha1 }),
      "the live offer is accepted"
    )
    Assert.isTrue(pool:prepareBootSource(1, true), "the preflight pins the offered buffer")
    Assert.isNil(pool:prepareBootSource(99, true), "a foreign preflight pins nothing")
    Assert.isFalse(pool:releaseBootSourceHold(99), "a foreign epoch releases no hold")
    Assert.isTrue(pool.sharedSource.byteData == buffer, "a foreign release keeps the held buffer")
    Assert.isTrue(pool:releaseBootSourceHold(1), "the live epoch releases its hold")
    Assert.isNil(pool.sharedSource, "the released idle buffer drops at once")
    Assert.isFalse(pool:releaseBootSourceHold(1), "a second release is a no-op")
    pool:shutdown()
  end)
end
-- A prepared result whose PNG continuation has not written its image yet is
-- not a committed cache entry: the pool keeps the parent unsettled, hands the
-- unwritten image to a sweep-priority continuation, commits no fact or bytes,
-- and a late reply from an earlier attempt can never settle it.
function T.deferred_png_continuation_gates_parent_publication()
  local CompilerPool = requirePool()
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newThreadHost(2)
  host.love.data = hostLove.data
  local versionId = "heartgold"
  local generation = "deferred-png-publication-generation"
  local scenePath = "data/generated/maps/60/scene.lua"
  local imagePath = "data/generated/maps/60/atlas.png"
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local sceneBytes = assert(hostLove.data.newByteData("return { mapId = 60 }\n"))
  local pendingImage = {
    relativePath = imagePath,
    width = 1,
    height = 1,
    rgba = hostLove.data.newByteData(string.char(9, 8, 7, 255)),
  }
  local ok, err = pcall(function()
    withLove(host.love, function()
      pool:selectGeneration({ versionId = versionId, generationId = generation }, 1)
      pool:request({
        generationId = generation,
        epoch = 1,
        versionId = versionId,
        kind = "map",
        key = "60",
        jobKey = "map:60",
        priority = 0,
        sizeClass = "normal",
        dependencies = {},
        payload = { mapId = 60 },
      })
      pool:update()
      Assert.equal(pool:status("map:60"), "running", "the map job dispatches to a worker")
      local dispatchedWork = assert(host.channels[2]:pop(), "the worker received the job")
      local dispatchId = assert(dispatchedWork.dispatchId, "dispatched work carries its dispatch identity")

      host.channels[1]:push({
        workerId = 1,
        epoch = 1,
        generationId = generation,
        kind = "map",
        key = "60",
        jobKey = "map:60",
        dispatchId = dispatchId,
        status = "images-pending",
        marker = "deferred-png-marker",
        ownedRoots = { "data/generated/maps/60" },
        sharedPaths = {},
        entries = { { path = scenePath, data = sceneBytes, size = sceneBytes:getSize() } },
        images = { pendingImage },
      })
      pool:update()
      pool:update()

      local pendingState = pool:status("map:60")
      Assert.isTrue(
        pendingState ~= "ready" and pendingState ~= "failed",
        "a parent with an unwritten deferred image stays pending: " .. tostring(pendingState)
      )
      Assert.isNil(
        ArtifactState.read(pool:artifactFacts(), "map", "60"),
        "no committed fact exists while the deferred image is unwritten"
      )
      Assert.isNil(pool:cacheFs():resolveAsset(scenePath), "no payload byte is committed before the continuation")

      local continuation = assert(host.channels[2]:pop(), "the pool hands the unwritten image to a continuation")
      Assert.equal(continuation.kind, "encode-png", "the continuation is the pool's private png encode task")
      Assert.equal(continuation.jobKey, "map:60", "the continuation names its owning parent job")
      Assert.equal(continuation.dispatchId, dispatchId, "the continuation resumes the parent's dispatch attempt")
      Assert.equal(
        continuation.priority,
        ArtifactJobs.priorityFor("sweep"),
        "png encoding continues at the existing sweep priority"
      )
      local images =
        assert(continuation.pending and continuation.pending.images, "the continuation carries the unwritten images")
      Assert.equal(#images, 1, "each unwritten image is handed over once")
      Assert.equal(images[1].relativePath, imagePath, "the continuation keeps the pending output path")
      local carried = assert(continuation.pending.entries, "the continuation carries the parent's private output")
      Assert.equal(carried[1].path, scenePath, "the continuation keeps the parent's committed-scene output")

      -- A result for an attempt this worker no longer owns cannot settle the
      -- pinned parent: it is dropped with its own references.
      host.channels[1]:push({
        workerId = 1,
        epoch = 999,
        generationId = generation,
        kind = "map",
        key = "60",
        jobKey = "map:60",
        dispatchId = dispatchId + 1000,
        status = "prepared",
        marker = "stale-marker",
        ownedRoots = { "data/generated/maps/60" },
        sharedPaths = {},
        entries = { { path = scenePath, data = sceneBytes, size = sceneBytes:getSize() } },
      })
      pool:update()
      Assert.isTrue(pool:status("map:60") ~= "ready", "a stale result cannot settle the pending parent")
      Assert.isNil(ArtifactState.read(pool:artifactFacts(), "map", "60"), "a stale result commits no fact")
      Assert.isNil(pool:cacheFs():resolveAsset(scenePath), "a stale result commits no bytes")
      pool.fatalError = nil
      Assert.equal(pool:status("map:60"), "images", "the pinned parent still owns its worker")

      -- The sealed output of the same attempt settles it exactly once.
      host.channels[1]:push({
        workerId = 1,
        epoch = 1,
        generationId = generation,
        kind = "map",
        key = "60",
        jobKey = "map:60",
        dispatchId = dispatchId,
        status = "prepared",
        marker = "deferred-png-marker",
        ownedRoots = { "data/generated/maps/60" },
        sharedPaths = {},
        entries = {
          { path = scenePath, data = sceneBytes, size = sceneBytes:getSize() },
          { path = imagePath, data = assert(hostLove.data.newByteData("png-bytes")), size = 9 },
        },
      })
      pool:update()
      pool:update()
      Assert.equal(pool:status("map:60"), "ready", "the parent settles ready after its continuation completes")
      Assert.notNil(
        ArtifactState.read(pool:artifactFacts(), "map", "60"),
        "exactly one parent fact publishes after the continuation"
      )
      Assert.equal(pool:cacheFs():readData(imagePath):getString(), "png-bytes", "the encoded image reaches the store")
      Assert.equal(pool:diagnostics().counts.ready, 1, "the job holds exactly one ready record")
    end)
  end)
  pcall(function()
    pool:shutdown()
  end)
  if not ok then
    error(err, 0)
  end
end

-- A failed deferred continuation never commits the parent and never damages
-- the previously committed generation: the private output is dropped and the
-- job settles as failed.
function T.deferred_png_continuation_failure_publishes_nothing()
  local CompilerPool = requirePool()
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local host = newThreadHost(2)
  host.love.data = hostLove.data
  local versionId = "heartgold"
  local generation = "deferred-png-failure-generation"
  local scenePath = "data/generated/maps/61/scene.lua"
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local sceneBytes = assert(hostLove.data.newByteData("return { mapId = 61 }\n"))
  local pendingImage = {
    relativePath = "data/generated/maps/61/atlas.png",
    width = 1,
    height = 1,
    rgba = hostLove.data.newByteData(string.char(1, 2, 3, 255)),
  }
  local dispatchId
  local ok, err = pcall(function()
    withLove(host.love, function()
      -- A previously committed map keeps its bytes through the failed rebuild.
      pool:selectGeneration({ versionId = versionId, generationId = generation }, 1)
      pool:request({
        generationId = generation,
        epoch = 1,
        versionId = versionId,
        kind = "map",
        key = "60",
        jobKey = "map:60",
        priority = 0,
        sizeClass = "normal",
        dependencies = {},
        payload = { mapId = 60 },
      })
      pool:update()
      local prior = assert(host.channels[2]:pop(), "the worker received the earlier job")
      host.channels[1]:push({
        workerId = 1,
        epoch = 1,
        generationId = generation,
        kind = "map",
        key = "60",
        jobKey = "map:60",
        dispatchId = assert(prior.dispatchId),
        status = "prepared",
        marker = "previously-published-marker",
        ownedRoots = { "data/generated/maps/60" },
        sharedPaths = {},
        entries = {
          {
            path = "data/generated/maps/60/complete",
            data = assert(hostLove.data.newByteData("previously-published-marker")),
            size = #"previously-published-marker",
          },
        },
      })
      pool:update()
      Assert.equal(pool:status("map:60"), "ready", "the earlier map is committed")

      pool:request({
        generationId = generation,
        epoch = 1,
        versionId = versionId,
        kind = "map",
        key = "61",
        jobKey = "map:61",
        priority = 0,
        sizeClass = "normal",
        dependencies = {},
        payload = { mapId = 61 },
      })
      pool:update()
      local dispatchedWork = assert(host.channels[2]:pop(), "the worker received the failing job")
      dispatchId = assert(dispatchedWork.dispatchId, "dispatched work carries its dispatch identity")
      host.channels[1]:push({
        workerId = 1,
        epoch = 1,
        generationId = generation,
        kind = "map",
        key = "61",
        jobKey = "map:61",
        dispatchId = dispatchId,
        status = "images-pending",
        marker = "deferred-png-failure-marker",
        ownedRoots = { "data/generated/maps/61" },
        sharedPaths = {},
        entries = { { path = scenePath, data = sceneBytes, size = sceneBytes:getSize() } },
        images = { pendingImage },
      })
      pool:update()
      pool:update()
      local continuation = assert(host.channels[2]:pop(), "the pool hands the unwritten image to a continuation")
      Assert.equal(continuation.kind, "encode-png", "the continuation is the private png encode task")
      host.channels[1]:push({
        workerId = 1,
        epoch = 1,
        generationId = generation,
        kind = "map",
        key = "61",
        jobKey = "map:61",
        dispatchId = dispatchId,
        status = "failed",
        error = "injected png encode failure",
      })
      pool:update()
      pool:update()
      Assert.equal(pool:status("map:61"), "failed", "a failed continuation settles the parent as failed")
      Assert.isNil(ArtifactState.read(pool:artifactFacts(), "map", "61"), "a failed continuation commits no fact")
      Assert.isNil(pool:cacheFs():resolveAsset(scenePath), "a failed continuation commits no bytes")
      Assert.equal(
        pool:cacheFs():readData("data/generated/maps/60/complete"):getString(),
        "previously-published-marker",
        "the previously committed generation stays untouched"
      )
    end)
  end)
  pcall(function()
    pool:shutdown()
  end)
  if not ok then
    error(err, 0)
  end
end

-- A selection that is retired while one of its workers is still encoding a
-- deferred image keeps that physical slot until the continuation settles
-- exactly once, the one shared source is released as soon as no compilation
-- needs it (a pending snapshot cut is not compilation), the cut's immutable
-- bytes outlive that release, and a late result from the retired epoch reaches
-- neither the live view nor a later capture.
function T.a_retired_continuation_holds_its_slot_while_a_pending_cut_keeps_its_bytes()
  local CompilerPool = requirePool()
  local RomSource = require("romdump.src.source.RomSource")
  local RomBinding = require("romdump.src.source.RomBinding")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  withDirectSourceSelection("synthretire", "IRL5", function(selection)
    local host = newThreadHost(4)
    host.love.data = hostLove.data
    local realFromPath = RomSource.fromPath
    local fromPathCalls = 0
    RomSource.fromPath = function(path)
      fromPathCalls = fromPathCalls + 1
      return realFromPath(path)
    end
    local generation = "retired-continuation-generation"

    -- One completed artifact as the compiler worker reports it: private output
    -- bytes plus its completion fact, addressed by the dispatch it belongs to.
    ---@param workerId integer
    ---@param epoch integer
    ---@param key string
    ---@param dispatchId integer
    ---@param text string
    ---@return table<string, unknown>
    local function memoryResult(workerId, epoch, key, dispatchId, text)
      local data = assert(hostLove.data.newByteData(text), "a result needs real Data buffers")
      return {
        workerId = workerId,
        epoch = epoch,
        generationId = generation,
        versionId = "synthretire",
        kind = "map",
        key = key,
        jobKey = "map:" .. key,
        dispatchId = dispatchId,
        status = "prepared",
        marker = "map-" .. key .. "-ready",
        ownedRoots = { "data/generated/field/" .. key },
        sharedPaths = {},
        entries = {
          { path = "data/generated/field/" .. key .. "/scene.lua", data = data, size = data:getSize() },
        },
      }
    end

    local bodyOk, bodyErr = pcall(function()
      withLove(host.love, function()
        local pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
        local cache = CacheFs.forVersion("synthretire")
        local recorded, recordErr = RomBinding.record(cache, selection.rom, {
          kind = "nds",
          path = selection.romPath,
          displayName = "synthetic.nds",
          zipEntry = false,
        })
        Assert.notNil(recorded, "the binding registers the synthetic ROM: " .. tostring(recordErr))
        pool:selectGeneration({ versionId = "synthretire", generationId = generation }, 1)
        pool:request(sourceMapJob("synthretire", generation, 1, "60", 60, 0))
        pool:request(sourceMapJob("synthretire", generation, 1, "61", 61, 0))
        pool:update()
        Assert.equal(pool:status("map:60"), "running", "the first source-dependent job dispatches")
        Assert.equal(pool:status("map:61"), "running", "the second source-dependent job dispatches")
        local first = dispatchedJob(host, 1)
        local second = dispatchedJob(host, 2)
        reportSourceNeeded(host, 1, first, 1, generation)
        reportSourceNeeded(host, 2, second, 1, generation)
        pool:update()
        local firstSupply = assertSharedSupply(findSupply(drainMessages(host, 1)), selection.data, "the first job")
        local secondSupply = assertSharedSupply(findSupply(drainMessages(host, 2)), selection.data, "the second job")
        Assert.isTrue(firstSupply.romByteData == secondSupply.romByteData, "both jobs borrow the same buffer")
        Assert.equal(fromPathCalls, 1, "two source-dependent jobs need exactly one source allocation")

        -- Compiled work travels in memory: the dispatch identity a worker
        -- answers is process-local, never a disk stage name.
        Assert.notNil(first.dispatchId, "dispatched work carries its in-memory dispatch identity")

        local sceneData = assert(hostLove.data.newByteData("return { mapId = 60 }\n"))
        local pendingEntry = {
          path = "data/generated/field/60/scene.lua",
          data = sceneData,
          size = sceneData:getSize(),
        }
        host.channels[1]:push({
          workerId = 1,
          status = "images-pending",
          epoch = 1,
          generationId = generation,
          versionId = "synthretire",
          kind = "map",
          key = "60",
          jobKey = "map:60",
          dispatchId = first.dispatchId,
          marker = "map-60-ready",
          ownedRoots = { "data/generated/field/60" },
          sharedPaths = {},
          entries = { pendingEntry },
          images = {
            {
              path = "data/generated/field/60/atlas.png",
              width = 1,
              height = 1,
              rgba = assert(hostLove.data.newByteData(string.char(9, 8, 7, 255))),
            },
          },
        })
        pool:update()
        pool:update()
        local pendingState = pool:status("map:60")
        Assert.isTrue(
          pendingState ~= "ready" and pendingState ~= "failed",
          "a job whose image is not written yet is not a ready artifact: " .. tostring(pendingState)
        )
        pool:request(sourceMapJob("synthretire", generation, 1, "62", 62, 0))
        Assert.equal(pool:status("map:62"), "queued", "the unwritten image keeps its physical worker slot")
        local continuation = assert(host.channels[2]:pop(), "the pool hands the unwritten image to its own worker")
        Assert.equal(continuation.kind, "encode-png", "the continuation is the pool's private encode task")
        Assert.equal(continuation.jobKey, "map:60", "the continuation names its owning parent job")

        -- Retirement cancels interest without freeing a physical slot: the
        -- unwritten image keeps its worker, the next generation waits behind
        -- it, and the one shared source is already gone even though that
        -- continuation is still owed.
        Assert.isTrue(pool:retireSelection(1), "the selection retires while the continuation is pending")
        Assert.isNil(pool.sharedSource, "retirement releases the shared source while a continuation still owes work")
        pool:selectGeneration({ versionId = "synthretire", generationId = generation }, 2)
        pool:request(sourceMapJob("synthretire", generation, 2, "63", 63, 0))
        local waitingState, waitingDetails = pool:status("map:63")
        Assert.equal(waitingState, "queued", "the next generation waits behind the retired occupancy")
        Assert.equal(
          type(waitingDetails) == "table" and waitingDetails.waitingOn,
          "active-job",
          "the wait names physical occupancy, not a policy label"
        )

        -- The finished continuation releases the retired slot exactly once.
        host.channels[1]:push(memoryResult(1, 1, "60", first.dispatchId, "return { mapId = 60 }\n"))
        pool:update()
        pool:update()
        Assert.equal(pool:status("map:63"), "running", "the settled continuation frees its worker for the live epoch")
        Assert.isTrue(pool:status("map:60") ~= "ready", "a retired continuation never becomes ready work")
        host.channels[1]:push(memoryResult(1, 1, "60", first.dispatchId, "late duplicate bytes"))
        pool:update()
        Assert.equal(pool:status("map:63"), "running", "a duplicate late result frees no second worker")
        local live = dispatchedJob(host, 1)
        Assert.notNil(live.dispatchId, "the live epoch's work carries its own dispatch identity")

        -- The second retired job settles too, and the live epoch's work
        -- settles from its own in-memory result.
        host.channels[1]:push(memoryResult(2, 1, "61", second.dispatchId, "return { mapId = 61 }\n"))
        pool:update()
        host.channels[1]:push(memoryResult(1, 2, "63", live.dispatchId, "return { mapId = 63 }\n"))
        pool:update(math.huge)
        Assert.equal(pool:status("map:63"), "ready", "the live epoch's work settles from memory")
        Assert.isNil(pool.sharedSource, "settled work keeps no source the selection no longer needs")

        -- A cut already captured for persistence keeps its own immutable
        -- bytes, and a late result's bytes are released rather than retained.
        collectgarbage("collect")
        Assert.equal(
          pendingEntry.data:getString(),
          "return { mapId = 60 }\n",
          "a pending snapshot cut keeps the immutable bytes it captured"
        )
        local weak = setmetatable({}, { __mode = "v" })
        local late = memoryResult(1, 1, "60", first.dispatchId, "late abandoned bytes")
        weak[1] = late.entries[1].data
        host.channels[1]:push(late)
        late = nil
        pool:update()
        collectgarbage("collect")
        collectgarbage("collect")
        Assert.isNil(weak[1], "a late result's bytes are released, never retained by the live selection")
        Assert.equal(pool:status("map:63"), "ready", "a late retired result cannot change the live view")
        Assert.equal(fromPathCalls, 1, "the whole journey needs its one verified source allocation")
        pcall(function()
          pool:shutdown()
        end)
      end)
    end)
    RomSource.fromPath = realFromPath
    if not bodyOk then
      error(bodyErr, 0)
    end
  end)
end

return { tests = T }
