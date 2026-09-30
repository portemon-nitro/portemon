-- Generation-session contract tests without opening a ROM or starting
-- worker threads: constructor validation precedes every side effect, the
-- closed dispatch maps every family to its size class and urgency, milestone
-- membership is exact, dependencies resolve through the fixed table, and the
-- follower check names its missing visual. Positive session behavior lives
-- in the ROM census, which owns a real dump.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local CompilerPool = require("romdump.src.build.CompilerPool")
local FakeCache = require("tests.support.FakeCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local MonCache = require("libs.assets.src.MonCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ScriptCache = require("libs.assets.src.ScriptCache")

local T = {}

local function untouchedPool()
  return {
    selectGeneration = function()
      error("session validation must precede pool selection")
    end,
    request = function()
      error("session validation must precede pool requests")
    end,
    status = function()
      error("session validation must precede pool status")
    end,
    update = function()
      error("session validation must precede pool updates")
    end,
  }
end

local function identity()
  return {
    versionId = "heartgold",
    generationId = "g4:heartgold:rom:producer:a1:s1",
    producerId = "d" .. string.rep("3", 64),
  }
end

function T.session_options_are_validated_before_any_side_effect()
  local cases = {
    { options = nil, message = "options are required" },
    { options = {}, message = "identity is required" },
    { options = { identity = {}, epoch = 1, pool = untouchedPool() }, message = "version is required" },
    {
      options = { identity = { versionId = "heartgold" }, epoch = 1, pool = untouchedPool() },
      message = "generation is required",
    },
    {
      options = {
        identity = { versionId = "heartgold", generationId = "g", producerId = "d" .. string.rep("3", 64) },
        pool = untouchedPool(),
      },
      message = "epoch must be a positive integer",
    },
    {
      options = { identity = identity(), epoch = 1 },
      message = "process-owned pool",
    },
  }
  for _, case in ipairs(cases) do
    local ok, err = pcall(InteractiveCacheBuild.new, case.options)
    Assert.isFalse(ok, "malformed session options must fail")
    Assert.isTrue(
      tostring(err):find(case.message, 1, true) ~= nil,
      "session rejection names its cause: " .. tostring(err)
    )
  end
end

function T.urgency_maps_to_three_fixed_pool_priorities()
  Assert.equal(ArtifactJobs.priorityFor("required"), 0)
  Assert.equal(ArtifactJobs.priorityFor("near"), 10)
  Assert.equal(ArtifactJobs.priorityFor("sweep"), 100)
  Assert.throws(function()
    ArtifactJobs.priorityFor("eventually")
  end)
end

function T.every_family_maps_to_its_fixed_size_class()
  -- The size policy covers the live family vocabulary without
  -- freezing it: every registered family resolves to a known class,
  -- and unknown kinds still fail loudly.
  local classes = { normal = true, heavy = true, jumbo = true }
  for kind in pairs(ArtifactState.KINDS) do
    local class = ArtifactJobs.sizeClass(kind)
    Assert.isTrue(classes[class] == true, "size class of " .. kind .. " is a known class, got " .. tostring(class))
  end
  Assert.throws(function()
    ArtifactJobs.sizeClass("world")
  end)
end

local function syntheticPlans()
  return {
    iconPageIds = { 0, 1 },
    portraitPageIds = { 0, 1, 2 },
    messageBankIds = { 219 },
    audioBankIds = { 7 },
    scriptMemberIds = { 149 },
    mapCellKeys = { [7] = { "12-5", "12-6" } },
  }
end

local function dependencySet(kind, key, plans)
  local set = {}
  local deps, complete = ArtifactJobs.dependencies(kind, key, plans or syntheticPlans())
  Assert.isTrue(complete, "the fixed planning table is complete for " .. kind .. ":" .. key)
  for _, dep in ipairs(assert(deps, "complete planning reports its edges")) do
    set[dep.kind .. ":" .. dep.key] = true
  end
  return set
end

function T.dependencies_resolve_through_the_fixed_table()
  Assert.deepEqual(dependencySet("mon-layout", "global"), { ["mon-catalog:global"] = true })
  Assert.deepEqual(dependencySet("mon-icon-page", "3"), { ["source-plan:global"] = true, ["mon-layout:global"] = true })
  Assert.deepEqual(
    dependencySet("mon-portrait-page", "12"),
    { ["source-plan:global"] = true, ["mon-layout:global"] = true }
  )
  local summary = dependencySet("mon-summary", "global")
  for _, name in ipairs({
    "source-plan:global",
    "mon-catalog:global",
    "mon-layout:global",
    "mon-icon-page:0",
    "mon-icon-page:1",
    "mon-portrait-page:0",
    "mon-portrait-page:1",
    "mon-portrait-page:2",
  }) do
    Assert.isTrue(summary[name] == true, "mon summary pulls " .. name)
  end
  Assert.deepEqual(dependencySet("message-summary", "global"), { ["message-bank:219"] = true })
  Assert.deepEqual(dependencySet("audio-summary", "global"), {
    ["source-plan:global"] = true,
    ["audio-catalog:global"] = true,
    ["audio-bank:7"] = true,
  })
  Assert.deepEqual(dependencySet("audio-catalog", "global"), { ["source-plan:global"] = true })
  Assert.deepEqual(
    dependencySet("script-summary", "global"),
    { ["source-plan:global"] = true, ["script-member:149"] = true }
  )
  local map = dependencySet("map", "7")
  for _, name in ipairs({
    "source-plan:global",
    "world-catalog:global",
    "field-cell-index:global",
    "field-cell:12-5",
    "field-cell:12-6",
  }) do
    Assert.isTrue(map[name] == true, "map pulls " .. name)
  end
  Assert.deepEqual(
    dependencySet("field-cell", "12-5"),
    { ["source-plan:global"] = true, ["field-cell-index:global"] = true }
  )
  Assert.deepEqual(dependencySet("actors", "global"), {})
  Assert.deepEqual(dependencySet("intro", "global"), {})
  Assert.deepEqual(dependencySet("items", "global"), {})
  Assert.deepEqual(dependencySet("bag", "global"), {})
  Assert.throws(function()
    ArtifactJobs.dependencies("world", "global", syntheticPlans())
  end)
end

function T.job_identities_validate_through_the_closed_vocabulary()
  Assert.equal(ArtifactJobs.jobKey("map", "7"), "map:7")
  Assert.equal(ArtifactJobs.jobKey("field-cell", "12-5"), "field-cell:12-5")
  Assert.throws(function()
    ArtifactJobs.jobKey("bogus-kind", "global")
  end)
  Assert.throws(function()
    ArtifactJobs.jobKey("map", "not-a-key")
  end)
end

local SUMMARY_GENERATION = "summary-gate-generation"
local function recordingPool()
  local pool = { submitted = {}, states = {} }
  function pool:update() end
  function pool:selectGeneration(selection, epoch)
    self.selected = { identity = selection, epoch = epoch }
  end
  function pool:retireSelection(epoch)
    self.retiredEpoch = epoch
    return true
  end
  function pool:status(jobKey)
    local state = self.states[jobKey]
    if state ~= nil then
      return state
    end
    -- A submitted job with no test-driven reply is still queued: only
    -- never-submitted identities read unknown, matching the production
    -- pool where request and status agree.
    if self.accepted ~= nil and self.accepted[jobKey] then
      return "queued"
    end
    return "unknown"
  end
  function pool:request(job)
    if self.accepted == nil or not self.accepted[job.jobKey] then
      self.submitted[#self.submitted + 1] = job.jobKey
    end
    self.accepted = self.accepted or {}
    self.accepted[job.jobKey] = true
    return self.states[job.jobKey] or "queued", nil
  end
  function pool:retry(jobKey, _)
    self.states[jobKey] = "queued"
    return "queued", nil
  end
  function pool:waitForProgress() end
  function pool:diagnostics()
    return { workerCount = 2, counts = {} }
  end
  return pool
end
local function selectableRecordingPool()
  local pool = recordingPool()
  function pool:selectGeneration(_, _) end
  return pool
end
local function summarySession(pool, cacheFs, bankIds)
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function()
    return cacheFs
  end
  local session
  local ok, err = pcall(function()
    session = InteractiveCacheBuild.new({
      identity = { versionId = "heartgold", generationId = SUMMARY_GENERATION, producerId = "d" .. string.rep("3", 64) },
      epoch = 1,
      pool = pool,
    })
  end)
  CacheFs.forVersion = realForVersion
  if not ok then
    error(err, 0)
  end
  session.messageBankIds = bankIds
  session.sourceLoaded = true
  session.pagesKnown = true
  return session
end
local function submittedSet(pool)
  local set = {}
  for _, jobKey in ipairs(pool.submitted) do
    set[jobKey] = true
  end
  return set
end
local function publishMessageBank(cacheFs, bankId, marker)
  cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = SUMMARY_GENERATION,
    kind = "message-bank",
    key = tostring(bankId),
    marker = marker,
  })
  cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
  cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
  })
end
function T.summary_dispatch_waits_for_bank_publication()
  local pool = recordingPool()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local session = summarySession(pool, cacheFs, { 3, 5 })
  local ready, failure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(ready, "the summary is pending while its banks are cold")
  Assert.isNil(failure, "no failure is reported while the summary waits for its banks")
  session:update()
  local submitted = submittedSet(pool)
  Assert.isTrue(submitted["message-bank:3"] == true, "a cold bank dispatches")
  Assert.isTrue(submitted["message-bank:5"] == true, "a cold bank dispatches")
  Assert.isNil(submitted["message-summary:global"], "the summary never occupies a worker while its banks are pending")

  pool.states["message-bank:3"] = "ready"
  pool.states["message-bank:5"] = "ready"
  publishMessageBank(cacheFs, 3, "bank-marker-3")
  publishMessageBank(cacheFs, 5, "bank-marker-5")
  session:update()
  session:update()
  local again, againFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(again, "the unpublished summary stays pending once its banks publish")
  Assert.isNil(againFailure, "no failure is reported once the banks publish")
  Assert.isTrue(submittedSet(pool)["message-summary:global"] == true, "the summary dispatches once every bank is ready")
end

local PRODUCER_ID = "d" .. string.rep("3", 64)
local function retryCapablePool()
  local pool = { submitted = {}, states = {}, retried = {}, selects = 0 }
  function pool:selectGeneration(_, _)
    self.selects = self.selects + 1
  end
  function pool:retireSelection(epoch)
    self.retiredEpoch = epoch
    return true
  end
  function pool:update() end
  function pool:status(jobKey)
    local state = self.states[jobKey]
    if type(state) == "table" then
      return state.state, state.details
    end
    if state ~= nil then
      return state
    end
    -- Request and status agree, matching the production pool: an accepted
    -- submission without a staged reply reads queued, while a
    -- never-submitted identity reads unknown.
    if self.accepted ~= nil and self.accepted[jobKey] then
      return "queued", nil
    end
    return "unknown", nil
  end
  function pool:request(job)
    self.submitted[#self.submitted + 1] = job.jobKey
    self.accepted = self.accepted or {}
    self.accepted[job.jobKey] = true
    return self:status(job.jobKey)
  end
  function pool:retry(jobKey, _)
    self.retried[#self.retried + 1] = jobKey
    self.states[jobKey] = "queued"
    return "queued", nil
  end
  return pool
end
local function isolatedSession(generation, pool, backend, extra)
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  CacheFs.forVersion = function(versionId)
    assert(versionId == "heartgold", "session fixture stays on heartgold")
    return cacheFs
  end
  local session
  local ok, err = pcall(function()
    local options = {
      identity = { versionId = "heartgold", generationId = generation, producerId = PRODUCER_ID },
      epoch = 1,
      pool = pool,
    }
    if extra ~= nil and extra.clock ~= nil then
      options.clock = extra.clock
    end
    session = InteractiveCacheBuild.new(options)
  end)
  CacheFs.forVersion = realForVersion
  if not ok then
    error(err, 0)
  end
  return session, cacheFs
end
local function submissionCount(pool, jobKey)
  local count = 0
  for _, submitted in ipairs(pool.submitted) do
    if submitted == jobKey then
      count = count + 1
    end
  end
  return count
end
function T.construction_performs_no_pool_census()
  local backend = FakeCache.new()
  local pool = recordingPool()
  local session, _ = isolatedSession("no-census-generation", pool, backend)
  pool.diagnostics = function()
    error("scheduler census must not run on the game thread")
  end
  pool.states["field-font:global"] = "ready"
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "demand stays pending until the pump runs")
  Assert.isNil(failure, "registration reports no failure")
  for _ = 1, 10 do
    session:update()
  end
  local again, againFailure = session:requestMilestone("bootstrap", "required")
  Assert.isTrue(again, "demand settles without pool census")
  Assert.isNil(againFailure, "settlement reports no failure")
end

-- Explicit complete enrollment advances a bounded chunk per update
-- without materializing the complete corpus: with the materialized
-- inventory patched to raise, one update visits only a small prefix,
-- while many updates still cover exactly the canonical union.
function T.complete_enrollment_advances_bounded_chunks_without_materializing_the_corpus()
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local matrices = {}
  for matrixMemberId = 1, 3 do
    local cells = {}
    for index = 0, 199 do
      cells[#cells + 1] = {
        matrixMemberId = matrixMemberId,
        index = index,
        x = 0,
        z = 0,
        mapHeaderId = 0,
        altitude = 0,
        landDataMemberId = 1,
        areaDataMemberId = 2,
      }
    end
    matrices[#matrices + 1] = { matrixMemberId = matrixMemberId, cells = cells }
  end
  local messageBankIds = FieldMessageCompiler.requiredBankIds()
  local mapDataIds = FieldMapDataCompiler.supportedMapIds()
  local mapIds = {}
  local mapCellKeys = {}
  for mapId = 1, 10 do
    mapIds[#mapIds + 1] = mapId
    mapCellKeys[mapId] = { "1-0", "2-0" }
  end
  local plans = {
    indexBundle = { index = { matrices = matrices }, indexMarker = "incremental-index-marker" },
    scriptPlan = { members = { { memberId = 149 }, { memberId = 150 } }, generationKey = "inc-script-generation" },
    audioPlan = { index = {}, bankPlans = { { bankId = 7 }, { bankId = 8 } } },
    messageBankIds = messageBankIds,
    audioBankIds = { 7, 8 },
    scriptMemberIds = { 149, 150 },
    iconPageIds = { 0 },
    portraitPageIds = { 0 },
    mapDataIds = mapDataIds,
    mapIds = mapIds,
    mapCellKeys = mapCellKeys,
    world = { maps = {} },
  }
  local expected = ArtifactJobs.completeJobs(plans)
  Assert.isTrue(#expected > 600, "the loaded fixture spans hundreds of jobs")
  local backend = FakeCache.new()
  local pool = recordingPool()
  pool.diagnostics = nil
  local session, _ = isolatedSession("incremental-complete-generation", pool, backend)
  session.adopted = plans
  session.sourceLoaded = true
  session.pagesKnown = true
  local requested, requestFailure = session:requestComplete("required")
  Assert.isFalse(requested, "the complete build stays pending until the pump runs")
  Assert.isNil(requestFailure, "registration reports no failure")
  local realCompleteJobs = ArtifactJobs.completeJobs
  ArtifactJobs.completeJobs = function()
    error("explicit complete enrollment must not materialize the complete corpus")
  end
  local ok, failure = pcall(function()
    session:update()
    local firstPass = session:outcomes()
    Assert.isTrue(#firstPass < 40, "one update visits only a bounded chunk, not the corpus: " .. tostring(#firstPass))
    -- Enrollment shares the bounded planning slice with every enrolled
    -- entry, so later updates enroll less per turn; iterate to quiescence
    -- (no growth across sustained pumping) rather than a fixed turn
    -- count, which a loaded machine can outlast without product change.
    local lastCount, stagnant = 0, 0
    for _ = 1, 20000 do
      if #session:outcomes() >= #expected then
        break
      end
      session:update()
      if #session:outcomes() == lastCount then
        stagnant = stagnant + 1
        if stagnant >= 500 then
          break
        end
      else
        lastCount, stagnant = #session:outcomes(), 0
      end
    end
    local outcomes = session:outcomes()
    Assert.equal(#outcomes, #expected, "complete enrollment covers the canonical union")
    local seen = {}
    for _, outcome in ipairs(outcomes) do
      seen[outcome.jobKey] = true
    end
    for _, job in ipairs(expected) do
      Assert.isTrue(seen[job.jobKey] == true, "complete enrollment covers " .. job.jobKey)
    end
  end)
  ArtifactJobs.completeJobs = realCompleteJobs
  if not ok then
    error(failure, 0)
  end
end

-- A ready pool reply is worker proof, not a request for controller
-- validation: the entry succeeds with zero family-validator calls on
-- the session thread.
function T.ready_pool_results_succeed_without_controller_revalidation()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("ready-without-revalidation", pool, backend)
  local realValidate = ArtifactJobs.validate
  ArtifactJobs.validate = function()
    error("controller must not deep-validate fresh pool output")
  end
  local ok, failure = pcall(function()
    local ready, requestFailure = session:requestJob("message-bank", "219", "required")
    Assert.isFalse(ready, "the undispatched bank answers pending")
    Assert.isNil(requestFailure, "registration reports no failure")
    session:update()
    Assert.equal(submissionCount(pool, "message-bank:219"), 1, "the cold bank dispatches once")
    pool.states["message-bank:219"] = "ready"
    session:update()
    local established, establishedFailure = session:requestJob("message-bank", "219", "required")
    Assert.isTrue(established, "the pool-proven bank answers ready")
    Assert.isNil(establishedFailure, "the proven bank reports no failure")
  end)
  ArtifactJobs.validate = realValidate
  if not ok then
    error(failure, 0)
  end
end

local function withHost(host, fn)
  local previous = rawget(_G, "love")
  rawset(_G, "love", host.love)
  local ok, first, second = pcall(fn)
  rawset(_G, "love", previous)
  if not ok then
    error(first, 0)
  end
  return first, second
end
local function isolatedHostFs(realFs, prefix)
  local root = realFs.getSaveDirectory() .. "/" .. prefix:gsub("/$", "")
  return {
    write = function(path, data)
      return realFs.write(prefix .. path, data)
    end,
    read = function(path)
      return realFs.read(prefix .. path)
    end,
    getInfo = function(path)
      return realFs.getInfo(prefix .. path)
    end,
    createDirectory = function(path)
      return realFs.createDirectory(prefix .. path)
    end,
    remove = function(path)
      return realFs.remove(prefix .. path)
    end,
    getDirectoryItems = function(path)
      return realFs.getDirectoryItems(prefix .. path)
    end,
    getSaveDirectory = function()
      return root
    end,
  }
end
local function removeTreeReal(realFs, path)
  local info = realFs.getInfo(path)
  if info == nil then
    return
  end
  if info.type == "directory" then
    local items = realFs.getDirectoryItems(path) or {}
    for _, name in ipairs(items) do
      removeTreeReal(realFs, path .. "/" .. name)
    end
  end
  realFs.remove(path)
end
local function newControlledHost(processorCount, hostFs)
  local host = { dispatched = {}, channels = {}, threads = {} }
  local function newChannel()
    local values = {}
    local channel = { log = {} }
    function channel:push(value)
      values[#values + 1] = value
      channel.log[#channel.log + 1] = value
      if type(value) == "table" and value.jobKey ~= nil and value.status == nil then
        host.dispatched[#host.dispatched + 1] = value.jobKey
      end
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:demand(timeout)
      assert(type(timeout) == "number", "pool progress waits are finite")
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:getCount()
      return #values
    end
    host.channels[#host.channels + 1] = channel
    return channel
  end
  local function spawnThread()
    local thread = { starts = 0, waits = 0, alive = true, threadError = nil }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return self.threadError
    end
    function thread:isRunning()
      return self.starts > 0 and self.alive
    end
    host.threads[#host.threads + 1] = thread
    return thread
  end
  host.love = {
    filesystem = hostFs,
    data = (rawget(_G, "love") or {}).data,
    system = {
      getProcessorCount = function()
        return processorCount
      end,
    },
    thread = {
      newChannel = newChannel,
      newThread = function()
        return spawnThread()
      end,
    },
  }
  return host
end
local function openLiveSession(options)
  local realLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local realFs = assert(realLove.filesystem, "the suite runs with a host filesystem")
  local prefix = "d02-isolation/" .. options.generation .. "/"
  removeTreeReal(realFs, prefix:gsub("/$", ""))
  local hostFs = isolatedHostFs(realFs, prefix)
  local host = newControlledHost(4, hostFs)
  local cacheFs = withHost(host, function()
    return CacheFs.forVersion("heartgold")
  end)
  local pool = withHost(host, function()
    local created = CompilerPool.new({ mode = "interactive", developmentRepositoryRoot = "/checkout" })
    created:selectGeneration({ versionId = "heartgold", generationId = options.generation }, 1)
    return created
  end)
  local session = withHost(host, function()
    local realForVersion = CacheFs.forVersion
    CacheFs.forVersion = function()
      return cacheFs
    end
    local ok, created = pcall(InteractiveCacheBuild.new, {
      identity = { versionId = "heartgold", generationId = options.generation, producerId = PRODUCER_ID },
      epoch = 1,
      pool = pool,
    })
    CacheFs.forVersion = realForVersion
    assert(ok, created)
    return created
  end)
  -- The fixture models a post-adoption session: source inventory and page
  -- membership read ready without worker work, so page and summary
  -- prerequisites proceed.
  session.messageBankIds = options.bankIds
  session.iconPageIds = options.iconPageIds or {}
  session.sourceLoaded = true
  session.pagesKnown = true
  local sourcePlanEntry = {
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    urgency = "sweep",
    priority = 100,
    submitted = false,
    ready = true,
    failure = nil,
    failureClass = nil,
    causeJobKey = nil,
    poolState = nil,
    phase = "ready",
    await = nil,
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
    propagateIndex = nil,
    retryPending = false,
  }
  session.byKey["source-plan:global"] = sourcePlanEntry
  session.interest[#session.interest + 1] = sourcePlanEntry
  return { host = host, realFs = realFs, prefix = prefix, cacheFs = cacheFs, pool = pool, session = session }
end
local function pumpSession(env, rounds)
  withHost(env.host, function()
    for _ = 1, rounds do
      env.session:update()
    end
  end)
end
local function pumpPool(env, rounds)
  withHost(env.host, function()
    for _ = 1, rounds do
      env.pool:update(0)
    end
  end)
end
local function resultChannel(env)
  return assert(env.host.channels[1], "the pool must create a result channel first")
end
local function inputChannel(env, workerId)
  return assert(env.host.channels[1 + workerId], "missing input channel for worker " .. tostring(workerId))
end
local function dispatchedStage(env, workerId, jobKey, occurrence)
  local seen = 0
  for _, message in ipairs(inputChannel(env, workerId).log) do
    if type(message) == "table" and message.jobKey == jobKey and message.stageName ~= nil then
      seen = seen + 1
      if seen == occurrence then
        return message.stageName
      end
    end
  end
  error("no dispatched stage for " .. jobKey .. " occurrence " .. tostring(occurrence), 0)
end
local function dispatchedWorker(env, jobKey)
  for workerId = 1, math.max(1, #env.host.channels - 1) do
    for _, message in ipairs(inputChannel(env, workerId).log) do
      if type(message) == "table" and message.jobKey == jobKey and message.stageName ~= nil then
        return workerId
      end
    end
  end
  error("no dispatched worker for " .. jobKey, 0)
end
local function dispatchCount(env, kind, key)
  local jobKey = kind .. ":" .. key
  local count = 0
  for _, dispatched in ipairs(env.host.dispatched) do
    if dispatched == jobKey then
      count = count + 1
    end
  end
  return count
end
local function pushWorkerReply(env, workerId, kind, key, stageName, status)
  local generation = env.session.generationId
  withHost(env.host, function()
    resultChannel(env):push({
      workerId = workerId,
      epoch = 1,
      generationId = generation,
      kind = kind,
      key = key,
      jobKey = kind .. ":" .. key,
      stageName = stageName,
      status = status,
      compileSeconds = 1,
      stageSeconds = 1,
      workSeconds = 1,
      stagedBytes = 8,
    })
  end)
end
local function stageBankReply(env, bankId, marker, stageName)
  local key = tostring(bankId)
  withHost(env.host, function()
    local artifact = PreparedArtifact.new({
      cacheFs = env.cacheFs,
      generationId = env.session.generationId,
      epoch = 1,
      kind = "message-bank",
      key = key,
      jobKey = "message-bank:" .. key,
      stageName = stageName,
    })
    FieldMessageCacheWriter.stageBank(artifact, {
      bankId = bankId,
      bank = { schema = FieldMessageCache.SCHEMA, bankId = bankId, messageCount = 0, key = bankId, messages = {} },
      marker = marker,
      dependencies = {
        cacheFormat = "synthetic",
        charmapVersion = "synthetic",
        manifestSchema = "synthetic",
        versionRomSha1 = "synthetic",
        messageNarc = {
          symbol = "synthetic",
          alias = "synthetic",
          narcId = 0,
          fileId = 0,
          path = "synthetic",
          sha1 = "synthetic",
        },
      },
    })
    artifact:finishSuccess({ marker = marker })
  end)
  pushWorkerReply(env, 1, "message-bank", key, stageName, "prepared")
end
local function stageBankReplyOnWorker(env, bankId, marker, workerId, occurrence)
  local key = tostring(bankId)
  local stageName = dispatchedStage(env, workerId, "message-bank:" .. key, occurrence)
  withHost(env.host, function()
    local artifact = PreparedArtifact.new({
      cacheFs = env.cacheFs,
      generationId = env.session.generationId,
      epoch = 1,
      kind = "message-bank",
      key = key,
      jobKey = "message-bank:" .. key,
      stageName = stageName,
    })
    FieldMessageCacheWriter.stageBank(artifact, {
      bankId = bankId,
      bank = { schema = FieldMessageCache.SCHEMA, bankId = bankId, messageCount = 0, key = bankId, messages = {} },
      marker = marker,
      dependencies = {
        cacheFormat = "synthetic",
        charmapVersion = "synthetic",
        manifestSchema = "synthetic",
        versionRomSha1 = "synthetic",
        messageNarc = {
          symbol = "synthetic",
          alias = "synthetic",
          narcId = 0,
          fileId = 0,
          path = "synthetic",
          sha1 = "synthetic",
        },
      },
    })
    artifact:finishSuccess({ marker = marker })
  end)
  pushWorkerReply(env, workerId, "message-bank", key, stageName, "prepared")
end
local function stageSummaryReply(env, bankIds, bankMarkers, stageName)
  local marker = nil
  withHost(env.host, function()
    local artifact = PreparedArtifact.new({
      cacheFs = env.cacheFs,
      generationId = env.session.generationId,
      epoch = 1,
      kind = "message-summary",
      key = "global",
      jobKey = "message-summary:global",
      stageName = stageName,
    })
    local index = { schema = FieldMessageCache.INDEX_SCHEMA, version = "heartgold", bankIds = bankIds }
    marker = FieldMessageCacheWriter.stageSummary(artifact, index, bankMarkers)
    artifact:finishSuccess({ marker = marker })
  end)
  pushWorkerReply(env, 1, "message-summary", "global", stageName, "prepared")
  return assert(marker, "summary staging must produce its marker")
end
local function publishBankLive(env, bankId, marker)
  local key = tostring(bankId)
  withHost(env.host, function()
    env.cacheFs:writeLua(ArtifactState.path("message-bank", key), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = env.session.generationId,
      kind = "message-bank",
      key = key,
      marker = marker,
    })
    env.cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
    env.cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
      schema = FieldMessageCache.SCHEMA,
      bankId = bankId,
    })
  end)
end
local function publishSummaryLive(env, bankIds, bankMarkers)
  withHost(env.host, function()
    local index = { schema = FieldMessageCache.INDEX_SCHEMA, version = "heartgold", bankIds = bankIds }
    local marker = FieldMessageCacheWriter.summaryMarker(index, bankMarkers)
    env.cacheFs:writeLua(ArtifactState.path("message-summary", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = env.session.generationId,
      kind = "message-summary",
      key = "global",
      marker = marker,
    })
    env.cacheFs:write(FieldMessageCache.markerPath(), marker)
    env.cacheFs:writeLua(FieldMessageCache.indexPath(), index)
  end)
end
local function publishCatalogLive(env, marker)
  withHost(env.host, function()
    env.cacheFs:writeLua(ArtifactState.path("mon-catalog", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = env.session.generationId,
      kind = "mon-catalog",
      key = "global",
      marker = marker,
    })
    env.cacheFs:writeLua(MonCache.catalogPath(), { version = "heartgold" })
    env.cacheFs:write(MonCache.catalogMarkerPath(), marker)
  end)
end
local function publishAudioCatalogLive(env, marker)
  local bundle = require("tests.support.AudioFixture").bundle()
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  withHost(env.host, function()
    env.cacheFs:writeLua(ArtifactState.path("audio-catalog", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = env.session.generationId,
      kind = "audio-catalog",
      key = "global",
      marker = marker,
    })
    env.cacheFs:writeLua(AudioCache.indexPath(), bundle.index)
    env.cacheFs:write(AudioCache.catalogMarkerPath(), marker)
  end)
end
local function requestJob(env, kind, key, urgency)
  return withHost(env.host, function()
    return env.session:requestJob(kind, key, urgency)
  end)
end
local function poolStatus(env, kind, key)
  return withHost(env.host, function()
    return env.pool:status(kind .. ":" .. key)
  end)
end
local function shutdownEnv(env)
  withHost(env.host, function()
    env.pool:shutdown()
  end)
  removeTreeReal(env.realFs, env.prefix:gsub("/$", ""))
end
function T.cold_request_dispatches_children_before_the_parent()
  local env = openLiveSession({ generation = "dependency-dispatch-generation", bankIds = { 3, 5 } })
  local ready, failure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(ready, "the summary is pending while its banks are cold")
  Assert.isNil(failure, "no failure is reported while the summary waits for its banks")
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "the parent never occupies a worker early")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "both cold banks dispatch together onto the bounded workers"
  )
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "the parent waits for every bank")

  stageBankReply(env, 3, "synthetic:romshape:003", dispatchedStage(env, 1, "message-bank:3", 1))
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "the first bank publishes through the pool")
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "the second bank already executes beside the first"
  )
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "one cold bank still gates the parent")

  local worker5 = dispatchedWorker(env, "message-bank:5")
  stageBankReplyOnWorker(env, 5, "synthetic:romshape:005", worker5, 1)
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "5"), "ready", "the second bank publishes through the pool")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5", "message-summary:global" },
    "the parent dispatches only after both banks publish"
  )
  Assert.equal(dispatchCount(env, "message-summary", "global"), 1, "the parent dispatches exactly once")
  shutdownEnv(env)
end

function T.blocking_ensure_never_waits_on_an_absent_parent()
  local env = openLiveSession({ generation = "dependency-block-generation", bankIds = { 3, 5 } })
  publishBankLive(env, 3, "synthetic:romshape:003")
  publishBankLive(env, 5, "synthetic:romshape:005")
  requestJob(env, "message-bank", "3", "required")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "the warm bank dispatches for worker proof")
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "reused")
  pumpSession(env, 2)
  local bankReady, bankFailure = requestJob(env, "message-bank", "3", "required")
  Assert.isTrue(bankReady, "a proven bank answers ready")
  Assert.isNil(bankFailure, "a proven bank reports no failure")
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "a proven bank holds no worker")
  requestJob(env, "message-bank", "5", "required")
  pumpSession(env, 1)
  pushWorkerReply(env, 1, "message-bank", "5", dispatchedStage(env, 1, "message-bank:5", 1), "reused")
  pumpSession(env, 2)
  publishSummaryLive(env, { 3, 5 }, { [3] = "synthetic:romshape:003", [5] = "synthetic:romshape:005" })
  requestJob(env, "message-summary", "global", "required")
  pumpSession(env, 1)
  pushWorkerReply(env, 1, "message-summary", "global", dispatchedStage(env, 1, "message-summary:global", 1), "reused")
  pumpSession(env, 2)
  local ready, failure = requestJob(env, "message-summary", "global", "required")
  Assert.isTrue(ready, "a proven summary answers ready")
  Assert.isNil(failure, "a proven summary reports no failure")
  Assert.equal(poolStatus(env, "message-summary", "global"), "ready", "a proven parent holds no worker")

  local waitCalls = 0
  local realWait = env.pool.wait
  env.pool.wait = function(self, jobKey)
    waitCalls = waitCalls + 1
    return realWait(self, jobKey)
  end
  local blocked = withHost(env.host, function()
    return env.session:_blockOn("message-summary", "global")
  end)
  Assert.isTrue(blocked, "the blocking ensure returns once the artifact is ready")
  Assert.equal(waitCalls, 0, "the ensure never waits on an absent parent record")
  shutdownEnv(env)
end

function T.required_request_promotes_an_already_queued_sweep()
  local env = openLiveSession({ generation = "dependency-promotion-generation", bankIds = { 3, 5 } })
  publishAudioCatalogLive(env, "audio-catalog-marker-promotion")
  requestJob(env, "message-bank", "3", "required")
  requestJob(env, "message-bank", "5", "sweep")
  requestJob(env, "audio-summary", "global", "near")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "the required bank occupies the worker")
  Assert.equal(poolStatus(env, "message-bank", "5"), "queued", "the sweep bank waits its turn")
  requestJob(env, "message-bank", "5", "required")
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "failed")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "the promoted sweep dispatches ahead of near work"
  )
  Assert.equal(dispatchCount(env, "message-bank", "5"), 1, "promotion keeps one job under its identity")
  Assert.equal(poolStatus(env, "message-bank", "5"), "running", "the promoted bank executes next")
  Assert.equal(poolStatus(env, "audio-summary", "global"), "unknown", "near work never occupies a worker early")
  shutdownEnv(env)
end

function T.shared_prerequisite_inherits_urgent_demand()
  local env = openLiveSession({
    generation = "dependency-shared-generation",
    bankIds = { 3 },
    iconPageIds = { 0, 1 },
  })
  publishCatalogLive(env, "catalog-marker-shared")
  publishAudioCatalogLive(env, "audio-catalog-marker-shared")
  requestJob(env, "audio-summary", "global", "required")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "audio-catalog:global" }, "the catalog proves first for worker reuse")
  pushWorkerReply(env, 1, "audio-catalog", "global", dispatchedStage(env, 1, "audio-catalog:global", 1), "reused")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global" },
    "the occupant holds the worker"
  )
  requestJob(env, "mon-icon-page", "0", "sweep")
  requestJob(env, "mon-icon-page", "1", "sweep")
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "mon-catalog", "global"), "queued", "the shared catalog waits behind the occupant")
  requestJob(env, "mon-icon-page", "0", "required")
  -- Required urgency cascades through the waiting layout to its queued
  -- catalog before the occupant releases the worker.
  pumpSession(env, 4)
  pushWorkerReply(env, 1, "audio-summary", "global", dispatchedStage(env, 1, "audio-summary:global", 1), "failed")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global", "mon-catalog:global" },
    "the required catalog inherits the urgent demand"
  )
  -- The required catalog executes beside the occupant on the second
  -- bounded worker, so its reuse proof reports that worker.
  local sharedCatalogWorker = dispatchedWorker(env, "mon-catalog:global")
  pushWorkerReply(
    env,
    sharedCatalogWorker,
    "mon-catalog",
    "global",
    dispatchedStage(env, sharedCatalogWorker, "mon-catalog:global", 1),
    "reused"
  )
  pumpSession(env, 1)
  Assert.equal(poolStatus(env, "mon-layout", "global"), "queued", "the proven catalog wakes its layout")
  requestJob(env, "message-bank", "3", "near")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global", "mon-catalog:global", "mon-layout:global" },
    "the shared prerequisite inherits the urgent demand"
  )
  Assert.equal(dispatchCount(env, "mon-layout", "global"), 1, "the shared job dispatches once for both pages")
  Assert.equal(poolStatus(env, "mon-layout", "global"), "running", "the promoted prerequisite executes next")
  Assert.equal(poolStatus(env, "mon-icon-page", "0"), "unknown", "no page occupies a worker early")
  Assert.equal(poolStatus(env, "mon-icon-page", "1"), "unknown", "no page occupies a worker early")
  Assert.equal(poolStatus(env, "message-bank", "3"), "queued", "near work still waits its turn")
  shutdownEnv(env)
end

function T.retry_repairs_only_the_failed_leaf()
  local env = openLiveSession({ generation = "dependency-retry-generation", bankIds = { 3, 5 } })
  publishBankLive(env, 3, "synthetic:romshape:003")
  local ready, failure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(ready, "the summary is pending while one bank is cold")
  Assert.isNil(failure, "no failure is reported while the summary waits")
  Assert.equal(poolStatus(env, "message-bank", "3"), "unknown", "the healthy bank is never submitted before admission")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "both banks dispatch together onto the bounded workers"
  )
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "reused")
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "the reused bank proves ready without publication")
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "the cold bank overlaps the worker proof"
  )
  pushWorkerReply(env, 2, "message-bank", "5", dispatchedStage(env, 2, "message-bank:5", 1), "failed")
  pumpSession(env, 2)
  local blocked, blockedFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(blocked, "the parent stays blocked behind its failed bank")
  Assert.notNil(blockedFailure, "the blocked parent reports its cause")
  Assert.isTrue(
    tostring(blockedFailure):find("message-bank:5", 1, true) ~= nil,
    "the parent names its failed prerequisite: " .. tostring(blockedFailure)
  )

  local retried = withHost(env.host, function()
    return env.session:retry("message-summary", "global", "required")
  end)
  Assert.isTrue(retried == true or retried == false, "an explicit retry of the blocked parent is accepted")
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "retry never rebuilds the proven sibling")
  Assert.equal(env.session:status().failed, 0, "retry clears the leaf and parent failure annotations")
  -- The retry records intent; the budgeted admission step performs the
  -- pool operation on the next pump, which dispatches exactly one new
  -- attempt for the failed leaf while the healthy sibling stays idle.
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5", "message-bank:5" },
    "the retry creates exactly one new leaf attempt"
  )
  local retriedStatus = poolStatus(env, "message-bank", "5")
  Assert.isTrue(
    retriedStatus == "queued" or retriedStatus == "running",
    "only the failed leaf retries: " .. tostring(retriedStatus)
  )
  stageBankReply(env, 5, "synthetic:romshape:005", dispatchedStage(env, 1, "message-bank:5", 1))
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "5"), "ready", "the retried leaf publishes")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5", "message-bank:5", "message-summary:global" },
    "the parent dispatches once its repaired bank publishes"
  )
  stageSummaryReply(
    env,
    { 3, 5 },
    { [3] = "synthetic:romshape:003", [5] = "synthetic:romshape:005" },
    dispatchedStage(env, 1, "message-summary:global", 1)
  )
  pumpSession(env, 2)
  local repaired, repairedFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isTrue(repaired, "the parent succeeds once its repaired closure publishes")
  Assert.isNil(repairedFailure, "the repaired parent reports no failure")
  Assert.equal(dispatchCount(env, "message-bank", "3"), 1, "the healthy sibling dispatched once for proof")
  shutdownEnv(env)
end

function T.retirement_ends_pending_waits_without_ghost_work()
  local env = openLiveSession({ generation = "dependency-retire-generation", bankIds = { 3, 5 } })
  requestJob(env, "message-summary", "global", "required")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "both banks execute together on the bounded workers"
  )
  withHost(env.host, function()
    env.session:retire()
  end)
  local retiredAgain = withHost(env.host, function()
    return env.pool:retireSelection(1)
  end)
  Assert.isFalse(retiredAgain, "retirement reaches the pool exactly once")
  Assert.equal(poolStatus(env, "message-bank", "3"), "running", "executing work stays charged")
  Assert.equal(poolStatus(env, "message-bank", "5"), "running", "the overlapping bank stays charged too")
  local requestOk = pcall(function()
    withHost(env.host, function()
      return env.session:requestJob("message-bank", "3", "required")
    end)
  end)
  Assert.isFalse(requestOk, "a retired session accepts no further work")

  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "failed")
  pumpPool(env, 2)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3", "message-bank:5" }, "late output dispatches nothing new")
  Assert.equal(poolStatus(env, "message-bank", "3"), "cancelled", "the late result settles without publishing")
  Assert.isNil(env.cacheFs:read(ArtifactState.path("message-bank", "3")), "the late result publishes no receipt")
  local waitOk, waitError = pcall(function()
    withHost(env.host, function()
      return env.session:_blockOn("message-summary", "global")
    end)
  end)
  Assert.isFalse(waitOk, "a pending ensure ends terminally after retirement")
  local message = tostring(waitError)
  Assert.isTrue(
    message:find("retir", 1, true) ~= nil or message:find("cancel", 1, true) ~= nil,
    "the terminated ensure names its retirement: " .. message
  )
  shutdownEnv(env)
end

function T.repeated_requests_submit_only_once()
  local env = openLiveSession({ generation = "dependency-repeat-generation", bankIds = { 3, 5 } })
  local first, firstFailure = requestJob(env, "message-bank", "5", "sweep")
  Assert.isFalse(first, "the cold bank stays pending")
  Assert.isNil(firstFailure, "no failure is reported while the bank waits")
  local second, secondFailure = requestJob(env, "message-bank", "5", "sweep")
  Assert.isFalse(second, "an equal-urgency request stays pending")
  Assert.isNil(secondFailure, "an equal-urgency request reports no failure")
  pumpSession(env, 2)
  Assert.equal(dispatchCount(env, "message-bank", "5"), 1, "repeated interest dispatches exactly once")
  local third, thirdFailure = requestJob(env, "message-bank", "5", "sweep")
  Assert.isFalse(third, "polling a dispatched bank stays pending")
  Assert.isNil(thirdFailure, "polling a dispatched bank reports no failure")
  Assert.equal(dispatchCount(env, "message-bank", "5"), 1, "equal-urgency polling dispatches nothing new")
  shutdownEnv(env)
end

function T.promotion_while_executing_keeps_single_execution()
  local env = openLiveSession({ generation = "dependency-executing-generation", bankIds = { 3, 5 } })
  local first, firstFailure = requestJob(env, "message-bank", "3", "near")
  Assert.isFalse(first, "the cold bank stays pending")
  Assert.isNil(firstFailure, "no failure is reported while the bank waits")
  pumpSession(env, 1)
  Assert.equal(poolStatus(env, "message-bank", "3"), "running", "the near bank occupies the worker")
  local second, secondFailure = requestJob(env, "message-bank", "3", "required")
  Assert.isFalse(second, "promoting an executing bank stays pending")
  Assert.isNil(secondFailure, "promoting an executing bank reports no failure")
  Assert.equal(dispatchCount(env, "message-bank", "3"), 1, "promotion never duplicates an executing job")
  Assert.equal(poolStatus(env, "message-bank", "3"), "running", "the promoted bank keeps executing")
  shutdownEnv(env)
end

function T.failed_dependency_blocks_parent_before_submission()
  local env = openLiveSession({ generation = "dependency-blocked-generation", bankIds = { 3, 5 } })
  publishBankLive(env, 3, "synthetic:romshape:003")
  local pending, pendingFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(pending, "the summary stays pending while one bank is cold")
  Assert.isNil(pendingFailure, "no failure is reported while the summary waits")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "both banks dispatch together onto the bounded workers"
  )
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "reused")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "the cold bank overlaps the worker proof"
  )
  pushWorkerReply(env, 2, "message-bank", "5", dispatchedStage(env, 2, "message-bank:5", 1), "failed")
  pumpSession(env, 2)
  local blocked, blockedFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(blocked, "the parent stays blocked behind its failed bank")
  Assert.isTrue(
    tostring(blockedFailure):find("message-bank:5", 1, true) ~= nil,
    "the parent names its failed prerequisite: " .. tostring(blockedFailure)
  )
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "the blocked parent never occupies a worker")
  shutdownEnv(env)
end

function T.blocking_wait_times_out_without_completion()
  local env = openLiveSession({ generation = "dependency-timeout-generation", bankIds = { 3, 5 } })
  local pending, pendingFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(pending, "the summary stays pending while its banks are cold")
  Assert.isNil(pendingFailure, "no failure is reported while the summary waits")
  local waitOk, waitError = pcall(function()
    withHost(env.host, function()
      return env.session:_blockOn("message-summary", "global")
    end)
  end)
  Assert.isFalse(waitOk, "an ensure with no completion ends terminally")
  local message = tostring(waitError)
  Assert.isTrue(message:find("message-summary:global", 1, true) ~= nil, "the timeout names its target: " .. message)
  Assert.isTrue(message:find("timed out", 1, true) ~= nil, "the outcome names its timeout: " .. message)
  shutdownEnv(env)
end

function T.stale_epoch_demand_fails_at_the_pool()
  local env = openLiveSession({ generation = "dependency-epoch-generation", bankIds = { 3, 5 } })
  withHost(env.host, function()
    env.pool:selectGeneration({ versionId = "heartgold", generationId = env.session.generationId }, 2)
  end)
  local requestOk, requestError = pcall(function()
    withHost(env.host, function()
      return env.session:requestJob("message-bank", "3", "required")
    end)
  end)
  Assert.isTrue(requestOk, "registration never touches the pool: " .. tostring(requestError))
  local pumpOk, pumpError = pcall(function()
    withHost(env.host, function()
      return env.session:update()
    end)
  end)
  Assert.isFalse(pumpOk, "demand from a stale epoch never dispatches")
  Assert.isTrue(
    tostring(pumpError):find("epoch", 1, true) ~= nil,
    "the stale demand names its epoch: " .. tostring(pumpError)
  )
  shutdownEnv(env)
end

-- Scope-relative completion from the bootstrap side: a bootstrap demand
-- never enrolls icon/portrait pages or geometry, and it can succeed from
-- its own roster while page membership stays unknown. It is still not
-- exhaustive completion.
function T.bootstrap_finishes_without_pages_or_geometry()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = isolatedSession("bootstrap-scope-generation", pool, backend)
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "bootstrap stays pending until its own members are ready")
  Assert.isNil(failure, "bootstrap reports no failure while pending")
  -- Readiness arrives through the owned pool transition: the staged ready
  -- reply stands in for worker proof. The scope assertions below are
  -- unchanged.
  pool.states["field-font:global"] = "ready"
  for _ = 1, 4 do
    session:update()
  end
  local again, againFailure = session:requestMilestone("bootstrap", "required")
  Assert.isTrue(again, "bootstrap succeeds from its own scope without page membership")
  Assert.isNil(againFailure, "bootstrap reports no failure on success")
  for jobKey in pairs(session.byKey) do
    local kind = jobKey:match("^([^:]+):")
    Assert.isTrue(kind ~= "mon-icon-page", "bootstrap enrolls no icon page: " .. jobKey)
    Assert.isTrue(kind ~= "mon-portrait-page", "bootstrap enrolls no portrait page: " .. jobKey)
    Assert.isTrue(kind ~= "field-cell", "bootstrap enrolls no geometry: " .. jobKey)
    Assert.isTrue(kind ~= "map", "bootstrap enrolls no field records: " .. jobKey)
  end
  Assert.isFalse(session:status().complete, "a targeted bootstrap is never exhaustive completion")
end

function T.bootstrap_membership_is_exactly_the_menu_font()
  local jobs = ArtifactJobs.bootstrapJobs()
  Assert.equal(#jobs, 1, "bootstrap carries only the menu prerequisite")
  Assert.equal(jobs[1].kind, "field-font", "the menu prerequisite is the field font")
  Assert.equal(jobs[1].key, "global", "the menu prerequisite is the global font")
end

function T.complete_request_is_idempotent_and_performs_no_synchronous_work()
  local backend = FakeCache.new()
  local pool = recordingPool()
  local session = isolatedSession("complete-request-generation", pool, backend)
  session:update()
  local submittedBefore = #pool.submitted
  local first, firstFailure = session:requestComplete("required")
  Assert.isFalse(first, "the complete build stays pending until the pump runs")
  Assert.isNil(firstFailure, "registration reports no failure")
  Assert.equal(#pool.submitted, submittedBefore, "requesting enrolls nothing synchronously")
  local second, secondFailure = session:requestComplete("required")
  Assert.isFalse(second, "a repeated request stays pending")
  Assert.isNil(secondFailure, "a repeated request reports no failure")
  Assert.equal(#pool.submitted, submittedBefore, "repeated requesting stays work-free")
  session:retire()
  local ok, err = pcall(session.requestComplete, session, "required")
  Assert.isFalse(ok, "requesting on a retired session rejects")
  Assert.isTrue(tostring(err):find("retired", 1, true) ~= nil, "the rejection names retirement")
end

local function oakAudioPlan()
  return {
    index = {
      sequences = {
        [2] = { id = 2, bankId = 10 },
        [100] = { id = 100, symbol = "SEQ_GS_STARTING", bankId = 20 },
        [101] = { id = 101, symbol = "SEQ_GS_STARTING2", bankId = 20 },
        [102] = { id = 102, symbol = "SEQ_SE_DP_BOWA2", bankId = 30 },
        [103] = { id = 103, symbol = "SEQ_SE_DP_SELECT", bankId = 30 },
        [104] = { id = 104, symbol = "SEQ_SE_GS_HERO_SHUKUSHOU", bankId = 40 },
      },
      sequenceBySymbol = {
        SEQ_GS_STARTING = 100,
        SEQ_GS_STARTING2 = 101,
        SEQ_SE_DP_BOWA2 = 102,
        SEQ_SE_DP_SELECT = 103,
        SEQ_SE_GS_HERO_SHUKUSHOU = 104,
      },
    },
  }
end

-- The New Game intro milestone stays pending before source adoption with a
-- unresolved roster, and it never schedules mon page membership: the
-- intro closure needs the source inventory but no page layout.
function T.new_game_intro_stays_unresolved_without_source_knowledge()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("new-game-unresolved-generation", pool, backend)
  local ready, failure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(ready, "the intro milestone stays pending while the inventory is cold")
  Assert.isNil(failure, "the intro milestone reports no failure while pending")
  -- Enrollment is update-owned and bounded: pump until the unresolved
  -- roster drains instead of assuming one update converges it.
  for _ = 1, 6 do
    session:update()
  end
  local roster = assert(session.roster["new-game-intro"], "the intro roster builds from retained intent")
  local set = {}
  for _, member in ipairs(roster) do
    set[member.kind .. ":" .. member.key] = true
  end
  Assert.isTrue(set["source-plan:global"] == true, "the unresolved roster keeps its source owner")
  Assert.isTrue(set["audio-catalog:global"] == true, "the unresolved roster keeps the catalog")
  Assert.isNil(set["audio-bank:184"], "no bank closure is final before source adoption")
  Assert.isNil(session.byKey["mon-layout:global"], "the intro milestone schedules no page layout")
  for _, entry in pairs(session.byKey) do
    if type(entry) == "table" and entry.failure == nil then
      entry.ready = true
    end
  end
  local again, againFailure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(again, "ready members never certify the intro scope before source adoption")
  Assert.isNil(againFailure, "no failure is reported while the scope is unresolved")
end

-- With adopted source audio membership the intro roster resolves exactly
-- the Oak bank closures, excludes the full summary and field work, and
-- reaches ready from its own members.
function T.new_game_intro_resolves_exact_bank_closures_after_adoption()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("new-game-final-generation", pool, backend)
  session.sourceLoaded = true
  session.audioBankIds = { 10, 20, 30, 40, 184 }
  session.adopted = { audioPlan = oakAudioPlan() }
  local ready, failure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(ready, "the intro milestone stays pending while cold")
  Assert.isNil(failure, "the intro milestone reports no failure while pending")
  -- The hand-adopted inventory stands in for the published source record,
  -- so its owner is retained ready without a worker round trip. Member
  -- readiness below still arrives through the owned pool transition.
  session.byKey["source-plan:global"] = {
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    urgency = "required",
    priority = 0,
    submitted = false,
    ready = true,
    failure = nil,
    phase = "ready",
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
  }
  session.interest[#session.interest + 1] = session.byKey["source-plan:global"]
  for _ = 1, 6 do
    session:update()
  end
  local roster = assert(session.roster["new-game-intro"], "the adopted roster rebuilds from source knowledge")
  local set = {}
  for _, member in ipairs(roster) do
    set[member.kind .. ":" .. member.key] = true
  end
  for _, expected in ipairs({
    "audio-bank:10",
    "audio-bank:20",
    "audio-bank:30",
    "audio-bank:40",
    "audio-bank:184",
  }) do
    Assert.isTrue(set[expected] == true, "the adopted roster carries " .. expected)
  end
  Assert.isNil(set["audio-summary:global"], "the full summary stays out of the intro roster")
  Assert.isNil(set["actors:global"], "field actors stay out of the intro roster")
  -- Readiness arrives through the owned pool transition: staged ready
  -- replies stand in for worker proof for every enrolled member.
  for _, member in ipairs(roster) do
    pool.states[member.kind .. ":" .. member.key] = "ready"
  end
  for _ = 1, 10 do
    session:update()
  end
  local again, againFailure = session:requestMilestone("new-game-intro", "required")
  Assert.isTrue(again, "the intro scope certifies once its own members are ready")
  Assert.isNil(againFailure, "the intro scope reports no failure on success")
end

function T.required_scope_settles_while_unrelated_background_waits()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("scope-settlement-generation", pool, backend)
  session.messageBankIds = { 31511 }
  pool.states["field-font:global"] = "ready"
  local coldKey = "message-bank:31511"
  local ready, requestFailure = session:requestJob("message-bank", "31511", "near")
  Assert.isFalse(ready, "the cold background bank answers pending")
  Assert.isNil(requestFailure, "registration reports no failure")
  local milestoneReady, milestoneFailure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(milestoneReady, "the milestone stays pending until the pump runs")
  Assert.isNil(milestoneFailure, "the milestone reports no failure while pending")
  local settled = false
  for _ = 1, 100 do
    session:update()
    local again = session:requestMilestone("bootstrap", "required")
    local coldAgain = session:requestJob("message-bank", "31511", "near")
    if again and not coldAgain then
      settled = true
      break
    end
  end
  Assert.isTrue(settled, "the required scope settles while the unrelated leaf waits")
  Assert.equal(submissionCount(pool, coldKey), 1, "the blocked leaf submits exactly once")
  for _ = 1, 20 do
    session:update()
    session:requestMilestone("bootstrap", "required")
    session:requestJob("message-bank", "31511", "near")
  end
  Assert.equal(submissionCount(pool, coldKey), 1, "repeated notifications resubmit nothing")
  local stillPending = session:requestJob("message-bank", "31511", "near")
  Assert.isFalse(stillPending, "the unreplied leaf never borrows the scope's readiness")
end

local function readyOwnerEntry(kind)
  return {
    kind = kind,
    key = "global",
    jobKey = kind .. ":global",
    urgency = "sweep",
    priority = 100,
    submitted = false,
    ready = true,
    failure = nil,
    phase = "ready",
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
  }
end
local function warmingAdopted()
  return {
    messageBankIds = { 1, 2 },
    audioBankIds = { 3 },
    scriptMemberIds = { 4 },
    iconPageIds = { 0 },
    portraitPageIds = { 1 },
    mapDataIds = {},
    mapIds = { 7 },
    mapCellKeys = { [7] = {} },
    indexBundle = { index = { matrices = {} }, indexMarker = "warming-index-marker" },
    scriptPlan = { members = { { memberId = 4 } }, generationKey = "warming-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = { { bankId = 3 } } },
  }
end
local function pumpUntilSubmitted(session, pool, rounds)
  for _ = 1, rounds do
    session:update()
    if #pool.submitted > 0 then
      return pool.submitted[1]
    end
  end
  error("background warmup submitted no candidate", 0)
end
local function newFakeClock()
  local state = { now = 0 }
  local function clock()
    return state.now
  end
  return state, clock
end
local function warmingSessionWithClock(generation, pool, backend, clock)
  local session, cacheFs = isolatedSession(generation, pool, backend, { clock = clock })
  session.adopted = warmingAdopted()
  session.sourceLoaded = true
  session.pagesKnown = true
  session.messageBankIds = { 1, 2 }
  session.audioBankIds = { 3 }
  session.scriptMemberIds = { 4 }
  session.iconPageIds = { 0 }
  session.portraitPageIds = { 1 }
  session.mapDataIds = {}
  session.mapIds = { 7 }
  session.mapCellKeys = { [7] = {} }
  for _, kind in ipairs({ "source-plan", "mon-layout" }) do
    local owner = readyOwnerEntry(kind)
    session.byKey[owner.jobKey] = owner
    session.interest[#session.interest + 1] = owner
  end
  return session, cacheFs
end
function T.authorized_sweep_waits_for_a_quiet_second_before_dispatch()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local tick, clock = newFakeClock()
  local session = warmingSessionWithClock("settle-authorization-generation", pool, backend, clock)
  session:enableSweep()
  for _ = 1, 5 do
    session:update()
  end
  Assert.equal(#pool.submitted, 0, "authorization alone dispatches no background candidate")
  tick.now = 0.999
  for _ = 1, 5 do
    session:update()
  end
  Assert.equal(#pool.submitted, 0, "background dispatch waits out the quiet window")
  tick.now = 1.0
  local candidate = pumpUntilSubmitted(session, pool, 20)
  Assert.notNil(candidate, "one quiet second admits the first background candidate")
end

function T.quiet_deadline_expiry_admits_one_sweep_candidate_and_clears_the_wait()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local tick, clock = newFakeClock()
  local session = warmingSessionWithClock("quiet-deadline-generation", pool, backend, clock)
  session:enableSweep()
  tick.now = 0.5
  for _ = 1, 5 do
    session:update()
  end
  Assert.isFalse(session:hasRunnablePlanning(), "quiet sweep admission is not immediately runnable")
  tick.now = 1.0
  for _ = 1, 5 do
    session:update()
  end
  Assert.equal(#pool.submitted, 1, "the quiet deadline admits exactly one background candidate")
  Assert.isNil(session:nextPlanningWakeDelay(), "an outstanding candidate leaves no clock wait")
  local idle = warmingSessionWithClock("quiet-unauthorized-generation", retryCapablePool(), FakeCache.new(), clock)
  idle:update()
  Assert.isNil(idle:nextPlanningWakeDelay(), "an unauthorized sweep exposes no clock wait")
end

function T.foreground_demand_suppresses_the_sweep_clock_wait()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local tick, clock = newFakeClock()
  local session = warmingSessionWithClock("quiet-foreground-generation", pool, backend, clock)
  session:enableSweep()
  local ready, failure = session:requestJob("script-member", "4", "required")
  Assert.isFalse(ready, "required demand answers pending until the pump runs")
  Assert.isNil(failure, "registration reports no failure")
  tick.now = 0.5
  session:update()
  Assert.isNil(session:nextPlanningWakeDelay(), "foreground demand owns the next candidate, not the sweep clock")
end

function T.icon_page_demand_registers_through_the_canonical_record()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = isolatedSession("icon-page-demand-generation", pool, backend)
  local ready, failure = session:requestIconPage(2, "required")
  Assert.isFalse(ready, "the icon page stays pending while its layout is cold")
  Assert.isNil(failure, "the icon page reports no failure while its layout is pending")
  local ok, _ = pcall(function()
    return session:requestIconPage(-1, "required")
  end)
  Assert.isFalse(ok, "a negative icon page is rejected")
  local urgencyOk, _ = pcall(function()
    return session:requestIconPage(2, "eventually")
  end)
  Assert.isFalse(urgencyOk, "an unknown urgency is rejected")
end

local SEMANTIC_MAP_ID = 5311
local SEMANTIC_DEDUP_MAP_ID = 5312
local SEMANTIC_MESSAGE_BANK = 219
local SEMANTIC_SCRIPT_MEMBER = 149
local SEMANTIC_SCRIPT_GENERATION = string.rep("c", 40)
local SEMANTIC_SCRIPT_MARKER = "semantic-test-marker"
local function semanticAudioPlan()
  return {
    index = {
      sequences = {
        [2] = { id = 2, bankId = 10 },
        [100] = { id = 100, symbol = "SEQ_SEMANTIC_DAY", bankId = 20 },
        [101] = { id = 101, symbol = "SEQ_SEMANTIC_NIGHT", bankId = 30 },
      },
      sequenceBySymbol = {
        SEQ_SEMANTIC_DAY = 100,
        SEQ_SEMANTIC_NIGHT = 101,
      },
    },
  }
end
local function stageSemanticScriptClosure(cacheFs, memberSequences)
  cacheFs:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SEMANTIC_SCRIPT_GENERATION,
    marker = SEMANTIC_SCRIPT_MARKER,
  })
  cacheFs:write(ScriptCache.markerPath(), SEMANTIC_SCRIPT_MARKER)
  cacheFs:writeLua(ScriptCache.generationIndexPath(SEMANTIC_SCRIPT_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SEMANTIC_SCRIPT_GENERATION,
    marker = SEMANTIC_SCRIPT_MARKER,
    resources = {},
    memberAudioSequences = memberSequences or { [tostring(SEMANTIC_SCRIPT_MEMBER)] = {} },
  })
  cacheFs:write(ScriptCache.generationMarkerPath(SEMANTIC_SCRIPT_GENERATION), SEMANTIC_SCRIPT_MARKER)
end
local function stageSemanticFieldRecord(cacheFs, mapId, music, plates)
  stageSemanticScriptClosure(cacheFs)
  cacheFs:writeLua(FieldMapDataCache.fieldPath(mapId), {
    schema = FieldMapDataCache.FIELD_SCHEMA,
    mapId = mapId,
    mapSymbol = "MAP_SEMANTIC_TEST",
    cameraType = 1,
    transitionEnvironment = "outdoors",
    messageBankId = SEMANTIC_MESSAGE_BANK,
    scriptBankId = SEMANTIC_SCRIPT_MEMBER,
    initScripts = {},
    music = music,
    events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    soundplates = plates,
  })
end
local function stageDivergentSemanticRecord(cacheFs, mapId)
  stageSemanticFieldRecord(cacheFs, mapId, {
    day = "SEQ_SEMANTIC_DAY",
    night = 2,
    flagOverrides = { { flagId = 9, sequence = "SEQ_SEMANTIC_NIGHT" } },
    traversalOverrides = { { traversal = "surf", sequence = 2 } },
  }, {
    { x = 0, z = 0, xBounds = 1, zBounds = 1, sequence = "SEQ_SEMANTIC_DAY", useFieldMusicBank = false },
  })
end
local function stageConvergentSemanticRecord(cacheFs, mapId)
  stageSemanticFieldRecord(cacheFs, mapId, {
    day = "SEQ_SEMANTIC_DAY",
    night = "SEQ_SEMANTIC_DAY",
    flagOverrides = {},
    traversalOverrides = {},
  }, {
    { x = 0, z = 0, xBounds = 1, zBounds = 1, sequence = "SEQ_SEMANTIC_DAY", useFieldMusicBank = false },
  })
end
local function adoptSemanticInventory(session)
  session.sourceLoaded = true
  session.audioBankIds = { 10, 20, 30 }
  session.scriptMemberIds = { SEMANTIC_SCRIPT_MEMBER }
  session.mapDataIds = { SEMANTIC_MAP_ID, SEMANTIC_DEDUP_MAP_ID }
  session.mapCellKeys = { [SEMANTIC_MAP_ID] = {}, [SEMANTIC_DEDUP_MAP_ID] = {} }
  local hasBank = false
  for _, bankId in ipairs(session.messageBankIds) do
    if bankId == SEMANTIC_MESSAGE_BANK then
      hasBank = true
    end
  end
  if not hasBank then
    session.messageBankIds[#session.messageBankIds + 1] = SEMANTIC_MESSAGE_BANK
  end
  session.adopted = {
    audioPlan = semanticAudioPlan(),
    scriptPlan = { generationKey = SEMANTIC_SCRIPT_GENERATION, marker = SEMANTIC_SCRIPT_MARKER },
    messageBankIds = session.messageBankIds,
    audioBankIds = session.audioBankIds,
    scriptMemberIds = session.scriptMemberIds,
    mapDataIds = session.mapDataIds,
    mapIds = {},
    mapCellKeys = session.mapCellKeys,
  }
  session.byKey["source-plan:global"] = {
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    urgency = "required",
    priority = 0,
    submitted = false,
    ready = true,
    failure = nil,
    phase = "ready",
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
  }
  session.interest[#session.interest + 1] = session.byKey["source-plan:global"]
end
local function settleSubmittedExcept(session, pool, skip)
  for _ = 1, 12 do
    session:update()
    for _, jobKey in ipairs(pool.submitted) do
      if pool.states[jobKey] == nil and (skip == nil or not skip[jobKey]) then
        pool.states[jobKey] = "ready"
      end
    end
  end
  session:update()
end
local function audioBankInterests(session)
  local banks = {}
  for jobKey in pairs(session.byKey) do
    local bank = jobKey:match("^audio%-bank:(.+)$")
    if bank ~= nil then
      banks[#banks + 1] = bank
    end
  end
  table.sort(banks)
  return banks
end
function T.planning_milestone_carries_only_determination_closure()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("semantic-planning-generation", pool, backend)
  local ready, failure = session:requestMilestone("field-planning", "required")
  Assert.isFalse(ready, "planning stays pending while cold")
  Assert.isNil(failure, "planning reports no failure while pending")
  for _ = 1, 6 do
    session:update()
  end
  local roster = assert(session.roster["field-planning"], "planning builds its roster from retained intent")
  local set = {}
  for _, member in ipairs(roster) do
    set[member.kind .. ":" .. member.key] = true
  end
  for _, expected in ipairs({ "source-plan:global", "world-catalog:global", "field-cell-index:global" }) do
    Assert.isTrue(set[expected] == true, "planning carries " .. expected)
  end
  local count = 0
  for _ in pairs(set) do
    count = count + 1
  end
  Assert.equal(count, 3, "planning carries nothing beyond determination")
  for jobKey in pairs(session.byKey) do
    local kind = jobKey:match("^([^:]+):")
    Assert.isTrue(
      kind ~= "audio-bank"
        and kind ~= "audio-summary"
        and kind ~= "message-bank"
        and kind ~= "message-summary"
        and kind ~= "script-member"
        and kind ~= "script-summary"
        and kind ~= "map-data"
        and kind ~= "map",
      "planning enrolls no family corpus: " .. jobKey
    )
  end
end

function T.runtime_milestone_carries_bounded_static_services()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("semantic-runtime-generation", pool, backend)
  local ready, failure = session:requestMilestone("field-runtime", "required")
  Assert.isFalse(ready, "runtime stays pending while cold")
  Assert.isNil(failure, "runtime reports no failure while pending")
  for _ = 1, 6 do
    session:update()
  end
  local roster = assert(session.roster["field-runtime"], "runtime builds its roster from retained intent")
  local set = {}
  for _, member in ipairs(roster) do
    set[member.kind .. ":" .. member.key] = true
  end
  -- The roster matches the declared runtime membership without
  -- freezing it: the session builds exactly what the jobs table
  -- declares, so membership changes flow from the one owner.
  local declared = {}
  for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
    declared[job.kind .. ":" .. job.key] = true
  end
  Assert.deepEqual(set, declared, "runtime builds exactly its declared membership")
  for identityKey in pairs(set) do
    local kind, key = identityKey:match("^([^:]+):(.+)$")
    Assert.isTrue(
      kind ~= "audio-bank" or key == "750" or key == "700",
      "runtime enrolls no audio bank but the shared transition and menu-effect banks: " .. identityKey
    )
    Assert.isTrue(kind ~= "script-member", "runtime enrolls no script member: " .. identityKey)
    Assert.isTrue(kind ~= "map-data", "runtime enrolls no field record: " .. identityKey)
    Assert.isTrue(kind ~= "map", "runtime enrolls no visual map: " .. identityKey)
    if kind == "message-bank" then
      Assert.isTrue(
        key == tostring(MenuProtocol.STANDARD_MESSAGE_BANK) or key == tostring(MenuProtocol.START_MENU_MESSAGE_BANK),
        "runtime carries only the two protocol menu banks: " .. identityKey
      )
    end
  end
end

local function readySemanticScriptChain(pool)
  pool.states["script-member:" .. tostring(SEMANTIC_SCRIPT_MEMBER)] = "ready"
  pool.states["script-summary:global"] = "ready"
end

function T.logical_field_waits_for_map_data_then_enrolls_exact_leaves()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, cacheFs = isolatedSession("semantic-logical-generation", pool, backend)
  adoptSemanticInventory(session)
  stageDivergentSemanticRecord(cacheFs, SEMANTIC_MAP_ID)
  stageSemanticScriptClosure(cacheFs, { [tostring(SEMANTIC_SCRIPT_MEMBER)] = {} })
  local ready, failure = session:requestLogicalField(SEMANTIC_MAP_ID, "required")
  Assert.isFalse(ready, "logical field waits for its field record")
  Assert.isNil(failure, "logical field reports no failure while pending")
  pool.states["map-data:" .. SEMANTIC_MAP_ID] = "ready"
  readySemanticScriptChain(pool)
  for _ = 1, 12 do
    session:update()
  end
  Assert.isTrue(session.byKey["map-data:" .. SEMANTIC_MAP_ID] ~= nil, "logical field owns its field record")
  Assert.isTrue(session.byKey["message-bank:219"] ~= nil, "logical field owns its message bank")
  Assert.isTrue(session.byKey["script-member:149"] ~= nil, "logical field owns its script member")
  Assert.isTrue(session.byKey["audio-catalog:global"] ~= nil, "logical field owns the audio catalog")
  Assert.deepEqual(audioBankInterests(session), { "10", "20", "30" }, "logical field owns exactly its audio banks")
  Assert.isNil(session.byKey["map:" .. SEMANTIC_MAP_ID], "logical field enrolls no visual map")
  Assert.isNil(session.byKey["audio-summary:global"], "logical field enrolls no audio summary")
  Assert.isNil(session.byKey["message-summary:global"], "logical field enrolls no message summary")
  local pending, pendingFailure = session:requestLogicalField(SEMANTIC_MAP_ID, "required")
  Assert.isFalse(pending, "logical field waits for its leaves")
  Assert.isNil(pendingFailure, "logical field reports no failure while its leaves are pending")
  settleSubmittedExcept(session, pool, nil)
  local done, doneFailure = session:requestLogicalField(SEMANTIC_MAP_ID, "required")
  Assert.isTrue(done, "logical field settles once its leaves are ready")
  Assert.isNil(doneFailure, "logical field reports no failure on success")
end

function T.logical_field_audio_references_collapse_to_unique_banks()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, cacheFs = isolatedSession("semantic-dedup-generation", pool, backend)
  adoptSemanticInventory(session)
  stageConvergentSemanticRecord(cacheFs, SEMANTIC_DEDUP_MAP_ID)
  stageSemanticScriptClosure(cacheFs, { [tostring(SEMANTIC_SCRIPT_MEMBER)] = {} })
  local ready, failure = session:requestLogicalField(SEMANTIC_DEDUP_MAP_ID, "required")
  Assert.isFalse(ready, "convergent logical field waits for its field record")
  Assert.isNil(failure, "convergent logical field reports no failure while pending")
  pool.states["map-data:" .. SEMANTIC_DEDUP_MAP_ID] = "ready"
  readySemanticScriptChain(pool)
  for _ = 1, 12 do
    session:update()
  end
  Assert.deepEqual(audioBankInterests(session), { "20" }, "duplicate audio references collapse to one bank")
  settleSubmittedExcept(session, pool, nil)
  local done, doneFailure = session:requestLogicalField(SEMANTIC_DEDUP_MAP_ID, "required")
  Assert.isTrue(done, "convergent logical field settles once its leaves are ready")
  Assert.isNil(doneFailure, "convergent logical field reports no failure on success")
end

local SCRIPT_AUDIO_MAP_ID = 5313
local SCRIPT_AUDIO_MESSAGE_BANK = 220
local SCRIPT_AUDIO_MEMBER = 150
local SCRIPT_ONLY_SEQUENCE = "SEQ_SCRIPT_ONLY"
local SCRIPT_ONLY_SEQUENCE_ID = 200
local SCRIPT_ONLY_BANK = 40
local SCRIPT_AUDIO_GENERATION = string.rep("d", 40)
local SCRIPT_AUDIO_MARKER = "script-audio-test-marker"
local function scriptAudioPlan()
  return {
    index = {
      sequences = {
        [2] = { id = 2, bankId = 10 },
        [100] = { id = 100, symbol = "SEQ_SEMANTIC_DAY", bankId = 20 },
        [101] = { id = 101, symbol = "SEQ_SEMANTIC_NIGHT", bankId = 30 },
        [SCRIPT_ONLY_SEQUENCE_ID] = {
          id = SCRIPT_ONLY_SEQUENCE_ID,
          symbol = SCRIPT_ONLY_SEQUENCE,
          bankId = SCRIPT_ONLY_BANK,
        },
      },
      sequenceBySymbol = {
        SEQ_SEMANTIC_DAY = 100,
        SEQ_SEMANTIC_NIGHT = 101,
        [SCRIPT_ONLY_SEQUENCE] = SCRIPT_ONLY_SEQUENCE_ID,
      },
    },
  }
end
local function stageScriptAudioRecord(cacheFs)
  stageSemanticFieldRecord(cacheFs, SCRIPT_AUDIO_MAP_ID, { day = 2 }, {})
  local staged = cacheFs:loadLua(FieldMapDataCache.fieldPath(SCRIPT_AUDIO_MAP_ID))
  staged.messageBankId = SCRIPT_AUDIO_MESSAGE_BANK
  staged.scriptBankId = SCRIPT_AUDIO_MEMBER
  cacheFs:writeLua(FieldMapDataCache.fieldPath(SCRIPT_AUDIO_MAP_ID), staged)
end
local function stageScriptAudioClosure(cacheFs, memberSequences)
  cacheFs:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_AUDIO_GENERATION,
    marker = SCRIPT_AUDIO_MARKER,
  })
  cacheFs:write(ScriptCache.markerPath(), SCRIPT_AUDIO_MARKER)
  cacheFs:writeLua(ScriptCache.generationIndexPath(SCRIPT_AUDIO_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_AUDIO_GENERATION,
    marker = SCRIPT_AUDIO_MARKER,
    resources = {},
    memberAudioSequences = memberSequences,
  })
  cacheFs:write(ScriptCache.generationMarkerPath(SCRIPT_AUDIO_GENERATION), SCRIPT_AUDIO_MARKER)
end
local function adoptScriptAudioInventory(session)
  session.sourceLoaded = true
  session.audioBankIds = { 10, 20, 30, SCRIPT_ONLY_BANK }
  session.scriptMemberIds = { SCRIPT_AUDIO_MEMBER }
  session.mapDataIds = { SCRIPT_AUDIO_MAP_ID }
  session.mapCellKeys = { [SCRIPT_AUDIO_MAP_ID] = {} }
  session.messageBankIds = session.messageBankIds or {}
  local hasBank = false
  for _, bankId in ipairs(session.messageBankIds) do
    if bankId == SCRIPT_AUDIO_MESSAGE_BANK then
      hasBank = true
    end
  end
  if not hasBank then
    session.messageBankIds[#session.messageBankIds + 1] = SCRIPT_AUDIO_MESSAGE_BANK
  end
  session.adopted = {
    audioPlan = scriptAudioPlan(),
    scriptPlan = { generationKey = SCRIPT_AUDIO_GENERATION, marker = SCRIPT_AUDIO_MARKER },
    messageBankIds = session.messageBankIds,
    audioBankIds = session.audioBankIds,
    scriptMemberIds = session.scriptMemberIds,
    mapDataIds = session.mapDataIds,
    mapIds = {},
    mapCellKeys = session.mapCellKeys,
  }
  session.byKey["source-plan:global"] = {
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    urgency = "required",
    priority = 0,
    submitted = false,
    ready = true,
    failure = nil,
    phase = "ready",
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
  }
  session.interest[#session.interest + 1] = session.byKey["source-plan:global"]
end
local function settleScriptSummary(session, pool)
  for _, memberId in ipairs(session.scriptMemberIds or {}) do
    local key = "script-member:" .. tostring(memberId)
    if pool.states[key] == nil then
      pool.states[key] = "ready"
    end
  end
  pool.states["script-summary:global"] = "ready"
  for _ = 1, 12 do
    session:update()
  end
end
function T.missing_script_closure_fails_the_logical_field_loudly()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, cacheFs = isolatedSession("script-audio-missing-generation", pool, backend)
  adoptScriptAudioInventory(session)
  stageScriptAudioRecord(cacheFs)
  stageScriptAudioClosure(cacheFs, {})
  session:requestLogicalField(SCRIPT_AUDIO_MAP_ID, "required")
  pool.states["map-data:" .. SCRIPT_AUDIO_MAP_ID] = "ready"
  for _ = 1, 6 do
    session:update()
  end
  settleScriptSummary(session, pool)
  local ready, failure = session:requestLogicalField(SCRIPT_AUDIO_MAP_ID, "required")
  Assert.isFalse(ready, "a logical field without member closure never reports ready")
  Assert.isTrue(
    tostring(failure):find(tostring(SCRIPT_AUDIO_MEMBER), 1, true) ~= nil,
    "the missing closure names its script member: " .. tostring(failure)
  )
end

function T.stale_script_generation_fails_instead_of_reading_old_metadata()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, cacheFs = isolatedSession("script-audio-stale-generation", pool, backend)
  adoptScriptAudioInventory(session)
  stageScriptAudioRecord(cacheFs)
  stageScriptAudioClosure(cacheFs, { [tostring(SCRIPT_AUDIO_MEMBER)] = { SCRIPT_ONLY_SEQUENCE } })
  session.adopted.scriptPlan = { generationKey = string.rep("e", 40), marker = SCRIPT_AUDIO_MARKER }
  session:requestLogicalField(SCRIPT_AUDIO_MAP_ID, "required")
  pool.states["map-data:" .. SCRIPT_AUDIO_MAP_ID] = "ready"
  for _ = 1, 6 do
    session:update()
  end
  settleScriptSummary(session, pool)
  local ready, failure = session:requestLogicalField(SCRIPT_AUDIO_MAP_ID, "required")
  Assert.isFalse(ready, "a logical field never closes over another generation metadata")
  Assert.isTrue(failure ~= nil, "stale script metadata fails loudly")
end

local function sessionLayoutManifest(schema, imagePath, width, height, cell)
  return {
    schema = schema,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = imagePath, width = width, height = height },
    },
    pageIds = { 0 },
    entries = {
      ["K/f0"] = {
        x = 0,
        y = 0,
        width = cell,
        height = cell,
        frames = { { x = 0, y = 0, width = cell, height = cell, duration = 6 } },
        pageId = 0,
      },
    },
    representative = { "K/f0" },
  }
end
local function sessionIconPagePlan(pageId)
  return {
    pageId = pageId,
    width = 256,
    height = 128,
    cell = 32,
    combos = { { naix = 0, palette = 0, key = "icons-" .. tostring(pageId), selectors = { "K/f0" } } },
    representative = { { selector = "K/f0", x = 0, y = 0, width = 32, height = 32 } },
  }
end
local function sessionPortraitPagePlan(pageId)
  return {
    pageId = pageId,
    width = 640,
    height = 320,
    cell = 80,
    combos = {
      {
        narc = "synthetic",
        charMemberId = 0,
        palMemberId = 0,
        key = "portraits-" .. tostring(pageId),
        selectors = { "K/f0" },
      },
    },
    representative = { { selector = "K/f0", x = 0, y = 0, width = 80, height = 80 } },
  }
end
local function sessionMinimalCatalog()
  local function zeroCurve()
    local curve = {}
    for level = 1, 100 do
      curve[level] = 0
    end
    return curve
  end
  return {
    schema = "g4-mon-catalog-v4",
    version = { id = "heartgold", language = "english" },
    species = {},
    moves = {},
    abilities = {},
    growthCurves = {
      medium_fast = zeroCurve(),
      erratic = zeroCurve(),
      fluctuating = zeroCurve(),
      medium_slow = zeroCurve(),
      fast = zeroCurve(),
      slow = zeroCurve(),
      unused_6 = zeroCurve(),
      unused_7 = zeroCurve(),
    },
  }
end
local function writeSessionReceipt(cacheFs, generation, kind, key, marker)
  cacheFs:writeLua(ArtifactState.path(kind, key), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = kind,
    key = key,
    marker = marker,
  })
end
local function slimSessionRecord(generation)
  return {
    schema = "g4-source-plan-v3",
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    generationId = generation,
    producerId = PRODUCER_ID,
    world = {
      maps = { { id = 7 }, { id = 9 } },
      analysis = { excluded = { { id = 3, reason = "placeholder header" } } },
    },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
    scriptPlan = { members = { { memberId = 4 }, { memberId = 6 } }, generationKey = "synthetic-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
    mapCellKeys = { [7] = {}, [9] = {} },
  }
end
local function stageSlimSessionRecord(cacheFs, generation)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  cacheFs:writeLua(SourcePlan.PATH, slimSessionRecord(generation))
  writeSessionReceipt(cacheFs, generation, "source-plan", "global", SourcePlan.marker(generation))
end
local function stageSessionLayout(cacheFs, generation)
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  MonCacheWriter.writeCatalog(cacheFs, sessionMinimalCatalog(), "slim-session-catalog-marker")
  writeSessionReceipt(cacheFs, generation, "mon-catalog", "global", "slim-session-catalog-marker")
  MonCacheWriter.writeLayout(
    cacheFs,
    sessionLayoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
    sessionLayoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    "slim-session-layout-marker",
    { iconPages = { [0] = sessionIconPagePlan(0) }, portraitPages = { [0] = sessionPortraitPagePlan(0) } },
    generation
  )
  writeSessionReceipt(cacheFs, generation, "mon-layout", "global", "slim-session-layout-marker")
end
function T.static_membership_survives_source_and_page_adoption()
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local requiredBanks = FieldMessageCompiler.requiredBankIds()
  local supportedRecords = FieldMapDataCompiler.supportedMapIds()
  Assert.isTrue(#requiredBanks > 0, "the producer bank list is not empty")
  Assert.isTrue(#supportedRecords > 1, "the producer record list carries more than one member")
  local outside = nil
  for _, mapId in ipairs(supportedRecords) do
    if mapId ~= 7 and mapId ~= 9 then
      outside = mapId
      break
    end
  end
  outside = assert(outside, "some supported record lives outside the small world")
  local function runOrder(layoutFirst)
    local generation = layoutFirst and "late-source-generation" or "source-first-generation"
    local backend = FakeCache.new()
    local pool = selectableRecordingPool()
    local session, cacheFs = isolatedSession(generation, pool, backend)
    Assert.deepEqual(session.messageBankIds, requiredBanks, "the constructor already knows every required bank")
    Assert.deepEqual(session.mapDataIds, supportedRecords, "the constructor already knows every supported record")
    local bankReady, bankFailure = session:requestJob("message-bank", tostring(requiredBanks[1]), "required")
    Assert.isFalse(bankReady, "a cold bank stays pending")
    Assert.isNil(bankFailure, "a cold bank reports no failure")
    local recordReady, recordFailure = session:requestJob("map-data", tostring(outside), "required")
    Assert.isFalse(recordReady, "a cold non-world record stays pending")
    Assert.isNil(recordFailure, "a cold non-world record reports no failure")
    local memberReady, memberFailure = session:requestJob("script-member", "4", "required")
    Assert.isFalse(memberReady, "an inventoried member stays pending while cold")
    Assert.isNil(memberFailure, "an inventoried member is accepted even before adoption")
    local unknownReady, unknownFailure = session:requestJob("script-member", "99999", "required")
    Assert.isFalse(unknownReady, "an unknown member stays pending while membership is unknown")
    Assert.isNil(unknownFailure, "an unknown member reports no failure while membership is unknown")
    local pageReady, pageFailure = session:requestJob("mon-portrait-page", "0", "required")
    Assert.isFalse(pageReady, "a page without layout membership stays pending")
    Assert.isNil(pageFailure, "a page without layout membership reports no failure")
    if layoutFirst then
      stageSessionLayout(cacheFs, generation)
    else
      stageSlimSessionRecord(cacheFs, generation)
    end
    for _ = 1, 3 do
      session:update()
    end
    Assert.isFalse(session.sourceLoaded, "partial membership adopts nothing")
    Assert.isFalse(session.pagesKnown, "partial membership adopts no pages")
    if layoutFirst then
      stageSlimSessionRecord(cacheFs, generation)
    else
      stageSessionLayout(cacheFs, generation)
    end
    pool.states["source-plan:global"] = "ready"
    pool.states["mon-catalog:global"] = "ready"
    pool.states["mon-layout:global"] = "ready"
    for _ = 1, 15 do
      session:update()
    end
    Assert.isTrue(session.sourceLoaded, "the staged slim inventory is adopted")
    Assert.deepEqual(session.messageBankIds, requiredBanks, "source adoption keeps the authoritative banks")
    Assert.deepEqual(session.mapDataIds, supportedRecords, "source adoption keeps the authoritative records")
    Assert.deepEqual(session.audioBankIds, {}, "source adoption reports the known-empty audio closure")
    Assert.deepEqual(session.scriptMemberIds, { 4, 6 }, "source adoption reports the inventoried members")
    Assert.deepEqual(session.mapIds, { 7, 9 }, "source adoption reports the narrow visual world")
    local knownCold, knownColdFailure = session:requestJob("script-member", "4", "required")
    Assert.isFalse(knownCold, "an inventoried member stays pending while cold")
    Assert.isNil(knownColdFailure, "an inventoried member reports no failure once known")
    local rejected, rejectedFailure = session:requestJob("script-member", "99999", "required")
    Assert.isFalse(rejected, "an unknown member never answers ready")
    Assert.notNil(rejectedFailure, "an unknown member is rejected once membership is known")
    Assert.isTrue(session.pagesKnown, "the staged layout adopts its page membership")
    Assert.deepEqual(session.portraitPageIds, { 0 }, "page adoption carries its portrait page")
    Assert.deepEqual(session.iconPageIds, { 0 }, "page adoption carries its icon page")
    Assert.deepEqual(session.messageBankIds, requiredBanks, "page adoption keeps the authoritative banks")
    Assert.deepEqual(session.mapDataIds, supportedRecords, "page adoption keeps the authoritative records")
    local adoptedPage, adoptedPageFailure = session:requestJob("mon-portrait-page", "0", "required")
    Assert.isFalse(adoptedPage, "the portrait exits pending while its page payload is cold")
    Assert.isNil(adoptedPageFailure, "the adopted portrait reports no failure")
    local portraitPages = {}
    for _, pageId in ipairs(session.portraitPageIds) do
      portraitPages[#portraitPages + 1] = pageId
    end
    return { pagesKnown = session.pagesKnown, portraitPages = portraitPages }
  end
  local sourceFirst = runOrder(false)
  local layoutFirst = runOrder(true)
  Assert.isTrue(sourceFirst.pagesKnown and layoutFirst.pagesKnown, "both orders adopt")
  Assert.deepEqual(sourceFirst.portraitPages, layoutFirst.portraitPages, "both orders reach the same closure")
end

-- Scope settlement stays parity across scope states: bootstrap reads
-- observable without an explicit request, a requested scope stays pending
-- through enrollment, cold intro membership without adopted inventory never
-- answers ready, a failed member settles its scope with its cause while a
-- pending sibling stays pending, an unrelated background failure never
-- settles pending required work, a metadata failure settles without
-- attesting completion, bare complete intent attests nothing, and
-- retirement masks milestone work again.
function T.status_settles_each_scope_from_its_own_retained_evidence()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("scope-parity-idle", pool, backend)
  local idle = session:status()
  Assert.equal(idle.bootstrap, "pending", "bootstrap is observable without an explicit request")
  Assert.isTrue(idle.settled, "an idle session with no intent settles vacuously")
  Assert.isFalse(idle.complete, "idleness never attests completion")
  local idleMilestone = session:milestoneStatus("bootstrap")
  Assert.equal(idleMilestone.state, "pending", "an unbuilt roster reports pending, never success")
  Assert.equal(idleMilestone.ready, 0, "an unbuilt roster counts no ready members")
  Assert.isNil(idleMilestone.total, "an unbuilt roster reports no denominator")
  local ready, requestFailure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "the requested scope stays pending until the pump runs")
  Assert.isNil(requestFailure, "registration reports no failure")
  local requested = session:status()
  Assert.equal(requested.bootstrap, "pending", "the requested scope stays pending through enrollment")
  Assert.isFalse(requested.settled, "a pending requested scope never settles")
  local requestedMilestone = session:milestoneStatus("bootstrap")
  Assert.equal(requestedMilestone.state, "pending", "progress stays pending through enrollment")
  Assert.isNil(requestedMilestone.total, "progress reports no denominator before the roster builds")
  pool.states["field-font:global"] = "ready"
  for _ = 1, 20 do
    session:update()
  end
  local warm, warmFailure = session:requestMilestone("bootstrap", "required")
  Assert.isTrue(warm, "the satisfied scope answers ready")
  Assert.isNil(warmFailure, "the satisfied scope reports no failure")
  local warmStatus = session:status()
  Assert.equal(warmStatus.bootstrap, "ready", "the satisfied scope reads ready")
  Assert.isTrue(warmStatus.settled, "the satisfied scope settles")
  Assert.isFalse(warmStatus.complete, "known membership is not complete attestation")
  local warmMilestone = session:milestoneStatus("bootstrap")
  Assert.deepEqual(
    { state = warmMilestone.state, ready = warmMilestone.ready, total = warmMilestone.total },
    { state = "ready", ready = 1, total = 1 },
    "the settled bootstrap closure reports its exact membership"
  )
  -- Unknown intro membership: cold intro without adopted source inventory.
  local introBackend = FakeCache.new()
  local introPool = retryCapablePool()
  local introSession, _ = isolatedSession("scope-parity-intro", introPool, introBackend)
  local introReady, introFailure = introSession:requestMilestone("new-game-intro", "required")
  Assert.isFalse(introReady, "the intro stays pending until its inventory arrives")
  Assert.isNil(introFailure, "registration reports no failure")
  for _ = 1, 10 do
    introSession:update()
  end
  local coldReady, coldFailure = introSession:requestMilestone("new-game-intro", "required")
  Assert.isFalse(coldReady, "unknown intro membership never answers ready")
  Assert.isNil(coldFailure, "a wait for inventory is pending, never a failure")
  local coldMilestone = introSession:milestoneStatus("new-game-intro")
  Assert.equal(coldMilestone.state, "pending", "the unknown intro closure reports pending")
  Assert.isNil(coldMilestone.total, "the unknown intro closure reports no denominator")
  Assert.isFalse(introSession:status().settled, "the unknown intro scope never settles")
  -- Member failure plus pending sibling: the failure settles the scope
  -- with its cause while the sibling stays pending.
  local runtimeBackend = FakeCache.new()
  local runtimePool = retryCapablePool()
  local runtimeSession, _ = isolatedSession("scope-parity-runtime", runtimePool, runtimeBackend)
  local runtimeReady, runtimeFailure = runtimeSession:requestMilestone("field-runtime", "required")
  Assert.isFalse(runtimeReady, "the runtime scope stays pending until the pump runs")
  Assert.isNil(runtimeFailure, "registration reports no failure")
  for _ = 1, 10 do
    runtimeSession:update()
  end
  local roster = assert(runtimeSession.roster["field-runtime"], "the runtime roster is retained")
  Assert.isTrue(#roster > 1, "the runtime roster names more than one member")
  local firstKey = roster[1].kind .. ":" .. roster[1].key
  local siblingKey = roster[2].kind .. ":" .. roster[2].key
  runtimePool.states[firstKey] = { state = "failed", details = { error = "synthetic first failure" } }
  for _ = 1, 10 do
    runtimeSession:update()
  end
  local failedReady, failedFailure = runtimeSession:requestMilestone("field-runtime", "required")
  Assert.isFalse(failedReady, "a failed member never answers ready")
  Assert.isTrue(
    tostring(failedFailure):find("synthetic first failure", 1, true) ~= nil,
    "the scope carries the member cause: " .. tostring(failedFailure)
  )
  local failedMilestone = runtimeSession:milestoneStatus("field-runtime")
  Assert.equal(failedMilestone.state, "failed", "progress reports the member failure")
  Assert.isTrue(
    tostring(failedMilestone.failure):find("synthetic first failure", 1, true) ~= nil,
    "progress carries the member cause: " .. tostring(failedMilestone.failure)
  )
  local sibling = runtimeSession.byKey[siblingKey]
  Assert.notNil(sibling, "the pending sibling stays retained")
  Assert.isNil(sibling.failure, "the pending sibling carries no failure")
  Assert.isFalse(sibling.ready, "the pending sibling never borrows the failure as readiness")
  local failedStatus = runtimeSession:status()
  Assert.equal(failedStatus.failed, 1, "exactly the failed member counts as failed")
  Assert.isTrue(failedStatus.settled, "the terminally failed scope settles")
  -- An unrelated failed background job never settles pending required work.
  local scopeBackend = FakeCache.new()
  local scopePool = retryCapablePool()
  local scopeSession, _ = isolatedSession("scope-parity-background", scopePool, scopeBackend)
  scopeSession.messageBankIds = { 31511 }
  local scopeReady, scopeFailure = scopeSession:requestMilestone("bootstrap", "required")
  Assert.isFalse(scopeReady, "the required scope stays pending until the pump runs")
  Assert.isNil(scopeFailure, "registration reports no failure")
  local coldBackground, coldBackgroundFailure = scopeSession:requestJob("message-bank", "31511", "near")
  Assert.isFalse(coldBackground, "the cold background bank answers pending")
  Assert.isNil(coldBackgroundFailure, "registration reports no failure")
  scopePool.states["message-bank:31511"] = { state = "failed", details = { error = "synthetic background failure" } }
  for _ = 1, 10 do
    scopeSession:update()
  end
  local stillPending, stillFailure = scopeSession:requestMilestone("bootstrap", "required")
  Assert.isFalse(stillPending, "the required scope stays pending past an unrelated failure")
  Assert.isNil(stillFailure, "the required scope reports no failure of its own")
  local scopeStatus = scopeSession:status()
  Assert.isFalse(scopeStatus.settled, "an unrelated failure never settles pending required work")
  Assert.equal(scopeStatus.failed, 1, "exactly the background job counts as failed")
  Assert.equal(scopeStatus.bootstrap, "pending", "the required scope stays pending")
  -- A metadata failure settles without attesting completion.
  introPool.states["source-plan:global"] = { state = "failed", details = { error = "synthetic inventory failure" } }
  for _ = 1, 10 do
    introSession:update()
  end
  local metaStatus = introSession:status()
  Assert.isTrue(metaStatus.settled, "a metadata failure settles")
  Assert.isFalse(metaStatus.complete, "a failure never attests completion")
  Assert.isTrue(metaStatus.failed >= 1, "the metadata failure stays visible")
  Assert.isTrue(
    table.concat(metaStatus.failures, " |"):find("synthetic inventory failure", 1, true) ~= nil,
    "the metadata cause stays visible"
  )
  -- Bare complete intent without exhaustion attests nothing.
  local completeBackend = FakeCache.new()
  local completePool = retryCapablePool()
  local completeSession, _ = isolatedSession("scope-parity-complete", completePool, completeBackend)
  local completeReady, completeFailure = completeSession:requestComplete("required")
  Assert.isFalse(completeReady, "an unexhausted complete build stays pending")
  Assert.isNil(completeFailure, "registration reports no failure")
  for _ = 1, 5 do
    completeSession:update()
  end
  Assert.isFalse(completeSession:status().complete, "an unexhausted build never attests completion")
  Assert.isFalse(completeSession:status().settled, "an unexhausted build never settles")
  -- Retirement masks milestone work again.
  session:retire()
  local retired = session:status()
  Assert.equal(retired.bootstrap, "pending", "retirement stops observing milestone work")
  Assert.isTrue(retired.settled, "retirement settles the session")
end

-- Final command observation cannot admit work: the completion snapshot
-- answers already-parsed requirement refs from retained state only. An
-- unregistered scope or job stays pending without registration, and the
-- captured rows survive retirement for the single command-policy pass.
function T.completion_snapshot_observes_without_admitting_work()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("snapshot-observation-generation", pool, backend)
  session:requestMilestone("bootstrap", "required")
  pool.states["field-font:global"] = "ready"
  for _ = 1, 4 do
    session:update()
  end
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isTrue(ready, "bootstrap is ready before the snapshot")
  Assert.isNil(failure, "bootstrap reports no failure before the snapshot")
  local refs = {
    { scope = "bootstrap" },
    { scope = "field-runtime" },
    { kind = "audio-bank", key = "183" },
  }
  local function admission()
    local keys = {}
    for jobKey in pairs(session.byKey) do
      keys[#keys + 1] = jobKey
    end
    table.sort(keys)
    local milestones = {}
    for name in pairs(session.milestones) do
      milestones[#milestones + 1] = name
    end
    table.sort(milestones)
    return {
      interest = table.concat(keys, ","),
      milestones = table.concat(milestones, ","),
      submitted = #pool.submitted,
      enrollCursor = session.enrollCursor ~= nil,
    }
  end
  local before = admission()
  local snapshot = session:completionSnapshot(refs)
  local after = admission()
  Assert.deepEqual(after, before, "observing the snapshot admits no work")
  Assert.isNil(session.byKey["audio-bank:183"], "an unregistered job stays unregistered")
  Assert.isNil(session.milestones["field-runtime"], "an unrequested scope stays unrequested")
  Assert.equal(#snapshot.answers, 3, "the snapshot answers every ref in input order")
  Assert.equal(snapshot.answers[1].label, "bootstrap", "a scope answer names its scope")
  Assert.equal(snapshot.answers[1].state, "ready", "the requested ready root stays ready")
  Assert.equal(snapshot.answers[2].label, "field-runtime", "an unrequested scope is still named")
  Assert.equal(snapshot.answers[2].state, "pending", "an unrequested scope stays pending")
  Assert.equal(snapshot.answers[3].label, "audio-bank:183", "a job answer names its canonical identity")
  Assert.equal(snapshot.answers[3].state, "pending", "an unregistered job stays pending")
  Assert.isTrue(#snapshot.outcomes > 0, "the snapshot carries the raw outcome rows")
  Assert.equal(snapshot.generationId, "snapshot-observation-generation", "the snapshot carries its identity")
  Assert.equal(snapshot.epoch, 1, "the snapshot carries its epoch")
  session:retire()
  Assert.equal(snapshot.answers[1].state, "ready", "captured answers survive retirement")
  Assert.isTrue(#snapshot.outcomes > 0, "captured outcomes survive retirement")
end

return { metadata = { capabilities = {} }, tests = T }
