-- CacheBuilder contract: buildVersions prepares every listed version with
-- the complete scope through one common generation session per version. A
-- matching attestation with a valid audit is a fast path that compiles
-- nothing; a strict success defers its new attestation until every requested
-- version satisfies the completion policy; accepted map exclusions and any
-- version failure publish no new attestation. The session, pool, cache, and
-- state modules are faked through package.loaded before CacheBuilder is
-- required, so delegation is exercised without a ROM or filesystem.

local Assert = require("tests.support.Assert")

-- Every module CacheBuilder requires at load that touches the host; each is
-- replaced with a fake. Pure vocabulary modules (ArtifactState, GameVersion,
-- contracts) stay real so requirement parsing and identity shape are proved.
local FAKE_PATHS = {
  "libs.storage.src.CacheFs",
  "romdump.src.DerivedCacheState",
  "romdump.src.ProducerFingerprint",
  "romdump.src.DerivedCacheAudit",
  "romdump.src.build.ArtifactJobs",
  "romdump.src.build.InteractiveCacheBuild",
  "romdump.src.build.CompilerPool",
  "romdump.src.build.CacheArchive",
}

local T = {}

local saved = {}
local env
local CacheBuilder

local function newEnv()
  return {
    identity = {
      versionId = "heartgold",
      generationId = "test-generation",
      producerId = "d" .. string.rep("1", 64),
    },
    readyKeys = {},
    failKeys = {},
    failureClasses = {},
    causeKeys = {},
    excludedKeys = {},
    milestones = {
      bootstrap = { "world-catalog:global", "field-camera:global" },
      ["field-runtime"] = { "world-catalog:global", "actors:global", "map:7" },
    },
    sessions = {},
    pools = {},
    cuts = {},
    snapshotComplete = false,
    snapshotSequence = 7,
    failingPersistVersions = {},
    shutdowns = 0,
    shutdownError = nil,
    retires = 0,
    stateStored = nil,
    stateMatches = false,
    auditAvailable = false,
    auditCalls = {},
    plansAvailable = true,
    planCalls = {},
    invalidatedVersions = {},
    publishes = {},
    publishAttempts = 0,
    publishFailCalls = {},
    updateRaise = nil,
    logLines = {},
  }
end

-- The cuts this run actually persisted: the writer records one snapshot
-- packet per accepted version, and nothing is persisted twice.
---@return table<string, unknown>[]
local function snapshots()
  local persisted = {}
  for _, packet in ipairs(env.cuts) do
    if packet.op == "snapshot" then
      persisted[#persisted + 1] = packet
    end
  end
  return persisted
end

-- The cuts whose persistence the writer acknowledged: a refused cut leaves no
-- persisted snapshot behind for its version.
---@return table<string, unknown>[]
local function persistedSnapshots()
  local persisted = {}
  for _, packet in ipairs(snapshots()) do
    if not env.failingPersistVersions[packet.versionId] then
      persisted[#persisted + 1] = packet
    end
  end
  return persisted
end

local function splitJobKey(jobKey)
  local kind, key = jobKey:match("^([^:]+):(.+)$")
  return kind, key
end

local function makeSession(pool, identity)
  local session = {
    pool = pool,
    identity = identity,
    completeRequested = nil,
    requested = {},
    retired = false,
  }
  function session:_answer(jobKey)
    if env.updateRaise ~= nil then
      error(env.updateRaise, 0)
    end
    if env.failKeys[jobKey] ~= nil then
      return false, jobKey .. ": " .. env.failKeys[jobKey]
    end
    if env.excludedKeys[jobKey] then
      return false, jobKey .. ": source-planned exclusion"
    end
    if env.readyKeys[jobKey] or (self.completed ~= nil and self.completed[jobKey]) then
      return true, nil
    end
    return false, nil
  end
  function session:requestJob(kind, key, urgency)
    assert(not self.retired, "generation session is retired")
    assert(type(kind) == "string" and type(key) == "string", "job needs its canonical kind and key")
    assert(urgency == "required" or urgency == "near" or urgency == "sweep", "unknown urgency")
    local jobKey = kind .. ":" .. key
    self.requested[#self.requested + 1] = jobKey
    self.pool.requested[#self.pool.requested + 1] = jobKey
    return self:_answer(jobKey)
  end
  function session:requestMilestone(name, urgency)
    assert(not self.retired, "generation session is retired")
    assert(name == "bootstrap" or name == "field-runtime", "milestones accept only bootstrap or field-runtime")
    local members = env.milestones[name] or {}
    local failures = {}
    local ready = true
    for _, jobKey in ipairs(members) do
      local kind, key = splitJobKey(jobKey)
      local ok, failure = self:requestJob(kind, key, urgency)
      if failure ~= nil and not env.excludedKeys[jobKey] then
        failures[#failures + 1] = failure
      end
      if not ok and env.excludedKeys[jobKey] == nil then
        ready = false
      end
    end
    if #failures > 0 then
      return false, failures[1]
    end
    return ready, nil
  end
  function session:requestComplete(urgency)
    assert(not self.retired, "generation session is retired")
    assert(urgency == "required" or urgency == "near" or urgency == "sweep", "unknown urgency")
    self.completeRequested = urgency
    -- Complete intent enrolls the fixture-known corpus, mirroring the
    -- production enumerator: every key the fixture stages as failed,
    -- excluded, ready, or pending joins once, so per-job outcomes flow
    -- through their own confirmations.
    if not self.corpusEnrolled then
      self.corpusEnrolled = true
      local seen = {}
      for _, jobKey in ipairs(self.requested) do
        seen[jobKey] = true
      end
      local keySets = { env.failKeys, env.excludedKeys, env.readyKeys }
      if env.pendingKeys ~= nil then
        keySets[#keySets + 1] = env.pendingKeys
      end
      for _, keySet in ipairs(keySets) do
        if type(keySet) == "table" then
          for jobKey in pairs(keySet) do
            if not seen[jobKey] then
              seen[jobKey] = true
              local kind, key = splitJobKey(jobKey)
              if kind ~= nil and key ~= nil then
                self:requestJob(kind, key, urgency)
              end
            end
          end
        end
      end
    end
    -- Complete-scope readiness mirrors production: every requested job
    -- terminal (completed, ready, failed, or excluded), with per-job
    -- failures reported through their own confirmations, not this scope.
    self.completed = self.completed or {}
    for _, jobKey in ipairs(self.requested) do
      if
        env.failKeys[jobKey] == nil
        and env.excludedKeys[jobKey] == nil
        and env.pendingKeys ~= nil
        and env.pendingKeys[jobKey]
      then
        return false, nil
      end
      if
        env.failKeys[jobKey] == nil
        and env.excludedKeys[jobKey] == nil
        and not (self.completed[jobKey] or (env.readyKeys ~= nil and env.readyKeys[jobKey]))
      then
        return false, nil
      end
    end
    return true, nil
  end
  -- The milestone facts this session proved: every fixture roster whose whole
  -- membership answered ready, which is what a captured cut carries.
  function session:milestoneFacts()
    local names = {}
    for name in pairs(env.milestones) do
      if self:_snapshotScope(name).state == "ready" then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    return names
  end
  function session:update()
    assert(not self.retired, "generation session is retired")
    if env.updateRaise ~= nil then
      error(env.updateRaise, 0)
    end
    self.completed = self.completed or {}
    for _, jobKey in ipairs(self.requested) do
      if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil then
        self.completed[jobKey] = true
      end
    end
  end
  function session:status()
    local ready, failed = 0, 0
    local failures = {}
    self.completed = self.completed or {}
    for _, jobKey in ipairs(self.requested) do
      if env.failKeys[jobKey] ~= nil then
        failed = failed + 1
        failures[#failures + 1] = jobKey .. ": " .. env.failKeys[jobKey]
      elseif env.excludedKeys[jobKey] then
        failed = failed + 1
        failures[#failures + 1] = jobKey .. ": source-planned exclusion"
      elseif self.completed[jobKey] or env.readyKeys[jobKey] then
        ready = ready + 1
      end
    end
    return {
      ready = ready,
      queued = 0,
      running = 0,
      failed = failed,
      failures = failures,
      enumerated = #self.requested,
      enumerationComplete = true,
      settled = true,
      planningPending = false,
    }
  end
  function session:outcomes()
    local list = {}
    local seen = {}
    self.completed = self.completed or {}
    for _, jobKey in ipairs(self.requested) do
      if seen[jobKey] == nil then
        seen[jobKey] = true
        local kind, key = splitJobKey(jobKey)
        local state, err, cause, failureClass = nil, nil, nil, nil
        if env.failKeys[jobKey] ~= nil then
          state = "failed"
          err = jobKey .. ": " .. env.failKeys[jobKey]
          cause = env.causeKeys ~= nil and env.causeKeys[jobKey] or nil
          failureClass = (env.failureClasses ~= nil and env.failureClasses[jobKey]) or "job"
        elseif env.excludedKeys[jobKey] then
          state = "failed"
          err = jobKey .. ": source-planned exclusion"
          failureClass = "source-exclusion"
        elseif self.completed[jobKey] or env.readyKeys[jobKey] then
          state = "successful"
        else
          state = "pending"
        end
        list[#list + 1] = {
          kind = kind,
          key = key,
          jobKey = jobKey,
          state = state,
          reused = false,
          error = err,
          causeJobKey = cause,
          failureClass = failureClass,
        }
      end
    end
    table.sort(list, function(left, right)
      return left.jobKey < right.jobKey
    end)
    return list
  end
  -- Read-only finalization observation mirroring the production snapshot:
  -- retained answers for parsed refs without registering unrequested
  -- scopes or jobs. Rows are fresh values that survive retire().
  function session:_snapshotScope(name)
    if name == "complete" then
      if self.completeRequested == nil then
        return { label = name, state = "pending", failure = nil }
      end
      self.completed = self.completed or {}
      for _, jobKey in ipairs(self.requested) do
        if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil then
          local pending = env.pendingKeys ~= nil and env.pendingKeys[jobKey]
          if pending or not (self.completed[jobKey] or (env.readyKeys ~= nil and env.readyKeys[jobKey])) then
            return { label = name, state = "pending", failure = nil }
          end
        end
      end
      return { label = name, state = "ready", failure = nil }
    end
    local members = env.milestones[name]
    if members == nil then
      return { label = name, state = "pending", failure = nil }
    end
    local failures = {}
    local ready = true
    for _, jobKey in ipairs(members) do
      local found = false
      for _, requestedKey in ipairs(self.requested) do
        if requestedKey == jobKey then
          found = true
          break
        end
      end
      if not found then
        ready = false
      else
        local ok, failure = self:_answer(jobKey)
        if failure ~= nil and not env.excludedKeys[jobKey] then
          failures[#failures + 1] = failure
        end
        if not ok and env.excludedKeys[jobKey] == nil then
          ready = false
        end
      end
    end
    if #failures > 0 then
      return { label = name, state = "failed", failure = failures[1] }
    end
    if not ready then
      return { label = name, state = "pending", failure = nil }
    end
    return { label = name, state = "ready", failure = nil }
  end
  function session:completionSnapshot(refs)
    assert(not self.retired, "completion facts are captured before session retirement")
    assert(type(refs) == "table", "completion facts observe parsed requirement refs")
    local answers = {}
    for _, ref in ipairs(refs) do
      if ref.scope ~= nil then
        answers[#answers + 1] = self:_snapshotScope(ref.scope)
      else
        local jobKey = ref.kind .. ":" .. ref.key
        local found = false
        for _, requestedKey in ipairs(self.requested) do
          if requestedKey == jobKey then
            found = true
            break
          end
        end
        if not found then
          answers[#answers + 1] = { label = jobKey, state = "pending", failure = nil }
        else
          local ready, failure = self:_answer(jobKey)
          if ready then
            answers[#answers + 1] = { label = jobKey, state = "ready", failure = nil }
          elseif failure ~= nil then
            answers[#answers + 1] = { label = jobKey, state = "failed", failure = failure }
          else
            answers[#answers + 1] = { label = jobKey, state = "pending", failure = nil }
          end
        end
      end
    end
    return {
      generationId = env.identity.generationId,
      epoch = 1,
      retired = false,
      settled = self:status().settled,
      enumerationComplete = true,
      completeExhausted = false,
      answers = answers,
      outcomes = self:outcomes(),
    }
  end
  function session:retire()
    self.retired = true
    env.retires = env.retires + 1
  end
  return session
end

local function makeFakes()
  local fakes = {}
  fakes.CacheFs = {
    forVersion = function(versionId)
      return {
        versionId = versionId,
        read = function(_, _)
          return nil
        end,
        loadLua = function()
          return env.stateStored
        end,
        remove = function()
          return true
        end,
      }
    end,
  }
  fakes.DerivedCacheState = {
    path = "data/generated/build.lua",
    matches = function(stored)
      return env.stateMatches and stored == env.stateStored
    end,
    invalidate = function(cacheFs)
      env.invalidatedVersions[#env.invalidatedVersions + 1] = cacheFs.versionId
    end,
    publish = function(_, identity)
      env.publishAttempts = env.publishAttempts + 1
      if env.publishFailCalls[env.publishAttempts] then
        error("injected attestation publication failure", 0)
      end
      env.publishes[#env.publishes + 1] = identity
    end,
  }
  fakes.ProducerFingerprint = {
    checkoutBackend = function()
      return {}
    end,
    appBackend = function()
      return {}
    end,
    compute = function()
      return "d" .. string.rep("1", 64)
    end,
  }
  fakes.DerivedCacheAudit = {
    isAvailable = function(_, identity, plans)
      env.auditCalls[#env.auditCalls + 1] = identity ~= nil and identity.generationId or nil
      -- The probe reflects the pre-build cache state; once the session has
      -- drained, every requested job was rebuilt, so the strict gate passes.
      -- Later probes therefore always pass: repair fixed the damage.
      if #env.auditCalls > 1 then
        return true
      end
      assert(plans ~= nil, "the generation audit requires the published inventory")
      return env.auditAvailable
    end,
  }
  fakes.ArtifactJobs = {
    publishedPlans = function(_, identity)
      env.planCalls[#env.planCalls + 1] = identity ~= nil and identity.generationId or nil
      if env.plansAvailable == false then
        return nil, "no published source inventory"
      end
      return { stubInventoryFor = identity ~= nil and identity.generationId or nil }
    end,
  }
  -- The base snapshot owner is exercised by its own suites; here the command
  -- observes only that its consistent cut reaches the writer unchanged, so the
  -- fake answers a persisted acknowledgement without touching a data home.
  fakes.CacheArchive = {
    restoreBackup = function()
      return false
    end,
    recoverableFileName = function()
      if env.snapshotComplete then
        return "cache.zip"
      end
      return nil
    end,
    open = function(versionId, identity)
      if env.snapshotComplete then
        return {
          versionId = versionId,
          sequence = env.snapshotSequence,
          identity = identity,
          entries = {},
          artifacts = {},
          milestones = {},
          firstPlay = false,
          complete = true,
        }
      end
      return nil, { code = "CACHE_ARCHIVE_UNREADABLE", message = "no snapshot archive is present" }
    end,
    run = function(control, reply)
      while true do
        local packet = control:pop()
        if packet == nil then
          break
        end
        env.cuts[#env.cuts + 1] = packet
        if packet.op == "snapshot" then
          if env.failingPersistVersions[packet.versionId] then
            reply:push({
              op = "snapshot-failed",
              versionId = packet.versionId,
              sequence = packet.sequence,
              error = { code = "CACHE_ARCHIVE_WRITE_FAILED", message = "injected persistence failure" },
            })
          else
            reply:push({ op = "snapshot-persisted", versionId = packet.versionId, sequence = packet.sequence })
          end
        end
      end
    end,
  }
  fakes.CompilerPool = {
    new = function()
      local pool = { requested = {}, selected = nil }
      function pool:selectGeneration(identity, epoch)
        self.selected = { identity = identity, epoch = epoch }
      end
      function pool:update() end
      function pool:drain() end
      function pool:waitForProgress() end
      function pool:jobOutcome(_)
        return nil
      end
      -- The cut the command captures from a consistent pool: the committed
      -- bytes and facts travel together, so this fixture publishes none.
      function pool:snapshotCut(identity, completion)
        return {
          versionId = identity.versionId,
          identity = identity,
          sequence = completion.sequence,
          entries = {},
          artifacts = {},
          milestones = completion.milestones or {},
          firstPlay = completion.firstPlay == true,
          complete = completion.complete == true,
        }
      end
      function pool:shutdown()
        env.shutdowns = env.shutdowns + 1
        if env.shutdownError ~= nil then
          error(env.shutdownError, 0)
        end
      end
      env.pools[#env.pools + 1] = pool
      return pool
    end,
  }
  fakes.InteractiveCacheBuild = {
    new = function(options)
      assert(type(options) == "table", "generation session options are required")
      assert(type(options.identity) == "table", "generation session identity is required")
      assert(type(options.epoch) == "number", "generation session epoch is required")
      assert(type(options.pool) == "table", "generation session requires the process-owned pool")
      Assert.isNil(options.sweepEnabled, "exhaustive intent travels as an explicit request, never a construction flag")
      local session = makeSession(options.pool, options.identity)
      env.sessions[#env.sessions + 1] = session
      return session
    end,
  }
  return fakes
end

local function testLog()
  return function(line)
    env.logLines[#env.logLines + 1] = line
  end
end

local function requestedSet(session)
  local set = {}
  for _, jobKey in ipairs(session.requested) do
    set[jobKey] = true
  end
  return set
end

local module = {
  beforeAll = function()
    -- Pure identity computation stays real; only the stateful attestation
    -- behavior (match/invalidate/publish) is faked.
    local realCurrent = require("romdump.src.DerivedCacheState").current
    for _, path in ipairs(FAKE_PATHS) do
      saved[path] = package.loaded[path]
      package.loaded[path] = nil
    end
    env = newEnv()
    local fakes = makeFakes()
    fakes.DerivedCacheState.current = realCurrent
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = fakes[path:match("([^%.]+)$")]
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = require("romdump.src.CacheBuilder")
  end,
  afterAll = function()
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = saved[path]
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
  end,
  tests = T,
}

-- An empty version list is part of the function contract: no build runs and
-- the caller-facing error names the empty selection.
function T.empty_version_list_returns_no_ready_version_to_compile()
  env = newEnv()
  local report, err = CacheBuilder.buildVersions({}, { log = testLog() })
  Assert.isNil(report)
  Assert.equal(err, "no ready version to compile")
  Assert.deepEqual(env.logLines, { "build: no ready version to compile" })
  Assert.equal(#env.pools, 0, "no pool is created for an empty selection")
end

-- The complete scope drives one common session per version with the sweep
-- enabled, requests field core plus the mon summary, and publishes the
-- schema-2 attestation only after every version succeeds.
function T.batch_reports_success_and_preserves_partial_publication_failure()
  env = newEnv()
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.equal(#env.sessions, 1, "one common session serves the version")
  Assert.equal(
    env.sessions[1].completeRequested,
    "required",
    "an exhaustive client requests the explicit complete build"
  )
  local requested = requestedSet(env.sessions[1])
  Assert.isTrue(requested["mon-summary:global"], "the mon summary is requested")
  local persisted = snapshots()
  Assert.equal(#persisted, 1, "a strict success persists exactly one snapshot")
  local identity = persisted[1].identity
  local GameVersion = require("romdump.src.source.GameVersion")
  Assert.equal(identity.versionId, "heartgold")
  Assert.equal(identity.mode, "development")
  Assert.equal(identity.producerId, "d" .. string.rep("1", 64))
  Assert.equal(
    identity.romSha1,
    GameVersion.VERSIONS.heartgold.sha1,
    "batch identity carries the canonical catalog hash, never a dump read"
  )
  Assert.equal(persisted[1].complete, true, "a strict complete build persists a complete cut")
  Assert.deepEqual(env.auditCalls, {}, "a strict success persists without a second audit")
  Assert.equal(env.shutdowns, 1, "the command shuts its pool down")
  Assert.equal(env.retires, 1, "the command retires its session")

  env = newEnv()
  env.auditAvailable = true
  env.failingPersistVersions.soulsilver = true
  local failedReport, failedErr = CacheBuilder.buildVersions(
    { "heartgold", "soulsilver", "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(failedReport, "a failed later persistence fails the command")
  Assert.equal(failedErr, "cache preparation failed")
  local cutVersions = {}
  for _, cut in ipairs(snapshots()) do
    cutVersions[#cutVersions + 1] = cut.identity.versionId
  end
  Assert.deepEqual(
    cutVersions,
    { "heartgold", "soulsilver", "heartgold" },
    "every selected version reaches its own persistence attempt"
  )
  local persistedVersions = {}
  for _, cut in ipairs(persistedSnapshots()) do
    persistedVersions[#persistedVersions + 1] = cut.identity.versionId
  end
  Assert.deepEqual(persistedVersions, { "heartgold", "heartgold" }, "persisted versions keep their cuts")
end

-- A complete snapshot of the current generation is a fast path: no session,
-- no pool, nothing repersisted, and the current-style report line.
function T.a_complete_snapshot_of_the_current_generation_compiles_nothing()
  env = newEnv()
  env.snapshotComplete = true
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.deepEqual(env.logLines, { "build-cache: heartgold current" })
  Assert.equal(#env.sessions, 0, "the fast path opens no session")
  Assert.equal(#env.pools, 0, "the fast path creates no pool")
  Assert.equal(#snapshots(), 0, "a current cache is never repersisted")
  Assert.deepEqual(env.auditCalls, {}, "the fast path never consults the exhaustive audit")
end

-- A complete current snapshot is trusted even when the exhaustive audit would
-- refuse and even without planning metadata: ordinary reuse never re-proves
-- published payloads, so no session opens and nothing is repersisted.
function T.a_complete_snapshot_is_trusted_without_audit_or_inventory()
  env = newEnv()
  env.snapshotComplete = true
  env.auditAvailable = false
  env.plansAvailable = false
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.equal(#snapshots(), 0, "a trusted cache is never repersisted")
  Assert.equal(#env.sessions, 0, "the fast path opens no session")
  Assert.deepEqual(env.auditCalls, {}, "the fast path never consults the exhaustive audit")
  Assert.deepEqual(env.planCalls, {}, "the fast path never enumerates the published inventory")
end

-- Map compile failures fail the batch by default; with explicitly accepted
-- exclusions the batch succeeds partially but publishes no attestation.
function T.compile_exclusions_fail_the_batch_unless_allowed()
  env = newEnv()
  env.failKeys["map:7"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(#env.publishes, 0, "a failed batch publishes no attestation")

  env = newEnv()
  env.failKeys["map:7"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  env.auditAvailable = true
  local accepted, acceptedErr = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", allowCompileExclusions = true, log = testLog() }
  )
  Assert.isNil(acceptedErr)
  Assert.deepEqual(accepted, { published = true, complete = false, exclusionCount = 1 })
  Assert.equal(#env.publishes, 0, "an exclusion-accepting batch never attests completeness")
end

-- A non-map failure is never hidden by the map-exclusion option.
function T.non_map_family_failure_is_never_hidden_by_map_exclusions()
  env = newEnv()
  env.failKeys["actors:global"] = "ACTOR_SOURCE_INVALID: injected actor rejection"
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", allowCompileExclusions = true, log = testLog() }
  )
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(#env.publishes, 0, "a hidden family failure must never pass as partial success")
end

-- One version whose identity cannot resolve is reported while the remaining
-- versions still run; the batch fails and no new attestation is published
-- for any version, while previously valid attestations are untouched.
function T.a_failed_version_continues_without_publishing_new_attestations()
  env = newEnv()
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "bogus-version", "soulsilver" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(#env.sessions, 1, "the remaining version still prepares through its session")
  Assert.equal(#env.publishes, 0, "a failed batch defers every new attestation")
end

-- A complete snapshot of an unaffected version survives another version's
-- failure: the fast path neither recompiles nor repersists it.
function T.a_complete_snapshot_of_an_unaffected_version_survives_another_failure()
  env = newEnv()
  env.snapshotComplete = true
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "heartgold", "bogus-version" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(#snapshots(), 0, "the unaffected version keeps its persisted snapshot")
  Assert.equal(env.logLines[1], "build-cache: heartgold current")
end

-- A programming fault inside a version's preparation rethrows after session
-- retirement and pool shutdown instead of becoming a failed-version report.
function T.a_programming_fault_rethrows_after_cleanup()
  env = newEnv()
  env.updateRaise = "boom"
  local raised = Assert.throws(function()
    CacheBuilder.buildVersions(
      { "heartgold" },
      { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
    )
  end)
  Assert.equal(raised, "boom", "the original fault must propagate unchanged")
  Assert.equal(env.retires, 1, "the faulting session is retired")
  Assert.equal(env.shutdowns, 1, "the owned pool is shut down")
  Assert.equal(#env.publishes, 0, "a faulting batch publishes no attestation")
end

-- Progress stays quiet per job: one dot per ten ready jobs, never a
-- per-change status line.
function T.progress_reports_one_dot_per_ten_ready_jobs()
  env = newEnv()
  local identity = {
    versionId = "heartgold",
    generationId = "test-generation",
    producerId = "d" .. string.rep("1", 64),
  }
  local requirements = {}
  for i = 1, 25 do
    requirements[#requirements + 1] = "map:" .. i
  end
  local report, err = CacheBuilder.prepareVersion("heartgold", {
    identity = identity,
    requirements = requirements,
    log = testLog(),
  })
  Assert.isNil(err)
  Assert.isFalse(report.complete, "a targeted scope never attests completeness")
  local dots = 0
  local dotLines = 0
  for _, line in ipairs(env.logLines) do
    if line:match("^%.+$") ~= nil then
      dots = dots + #line
      dotLines = dotLines + 1
    end
    Assert.isFalse(line:find("jobs ready", 1, true) ~= nil, "no per-change status lines: " .. line)
  end
  Assert.equal(dots, 2, "one dot per ten ready jobs")
  Assert.equal(dotLines, 1, "all dots share one line")
end

-- The log option defaults to print, the plain-Lua output of the CLI: dots
-- reach print one per ten ready jobs.
function T.log_defaults_to_print()
  env = newEnv()
  for i = 1, 12 do
    env.readyKeys["map:" .. i] = true
  end
  local lines = {}
  local realPrint = print
  _G.print = function(line)
    lines[#lines + 1] = tostring(line)
  end
  local ok, report, err = pcall(
    CacheBuilder.buildVersions,
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout" }
  )
  _G.print = realPrint
  Assert.isTrue(ok, tostring(report))
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.deepEqual(lines, { "." }, "one dot per ten ready jobs through the default log")
end

-- A targeted scope never attests completeness, while a strict complete
-- preparation publishes exactly one attestation and deletes nothing.
function T.targeted_prepare_never_attests_while_complete_prepare_does()
  env = newEnv()
  local identity = {
    versionId = "heartgold",
    generationId = "test-generation",
    producerId = "d" .. string.rep("1", 64),
  }
  local targeted, targetedErr = CacheBuilder.prepareVersion("heartgold", {
    identity = identity,
    requirements = { "bootstrap" },
    log = testLog(),
  })
  Assert.isNil(targetedErr)
  Assert.isFalse(targeted.complete, "a targeted scope never attests completeness")
  Assert.equal(#snapshots(), 1, "a targeted scope persists its own partial cut")
  Assert.equal(snapshots()[1].complete, false, "a targeted scope never persists a complete cut")

  local complete, completeErr = CacheBuilder.prepareVersion("heartgold", {
    identity = identity,
    requirements = { "complete" },
    log = testLog(),
  })
  Assert.isNil(completeErr)
  Assert.isTrue(complete.complete, "a strict complete build attests completeness")
  Assert.equal(#snapshots(), 2, "a strict complete build persists its complete cut")
  Assert.equal(snapshots()[2].complete, true, "the complete cut carries its completeness fact")
end

-- An unproved pool closure fails the build before attestation: no new
-- full marker is published.
function T.unproved_pool_closure_blocks_attestation()
  env = newEnv()
  env.shutdownError = "injected worker join failure"
  local identity = {
    versionId = "heartgold",
    generationId = "test-generation",
    producerId = "d" .. string.rep("1", 64),
  }
  local complete, completeErr = CacheBuilder.prepareVersion("heartgold", {
    identity = identity,
    requirements = { "complete" },
    log = testLog(),
  })
  Assert.isNil(complete, "an unproved join never reports a successful build")
  Assert.notNil(completeErr, "an unproved join carries its failure")
  Assert.equal(#env.publishes, 0, "an unproved join publishes no attestation")
end

-- An exclusion-accepting partial batch publishes no completeness attestation.
function T.accepted_partial_batch_publishes_no_attestation()
  env = newEnv()
  env.failKeys["map:7"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  env.auditAvailable = true
  local accepted, acceptedErr = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", allowCompileExclusions = true, log = testLog() }
  )
  Assert.isNil(acceptedErr)
  Assert.deepEqual(accepted, { published = true, complete = false, exclusionCount = 1 })
  Assert.equal(#env.publishes, 0, "an exclusion-accepting partial batch attests nothing")
end

return module
