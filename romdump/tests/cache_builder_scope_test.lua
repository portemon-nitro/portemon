-- Scoped cache preparation drives one common generation session per version:
-- a targeted closure runs only its declared dependencies and never publishes
-- full-build attestation, an exhaustive scope attests only strict success,
-- and opt-in profiling observes without changing job identity. The session,
-- pool, cache, and state modules are faked through package.loaded before
-- CacheBuilder is required, so scope policy is exercised without a ROM.

local Assert = require("tests.support.Assert")

-- The genuine IO opener, captured before any fault-injection test replaces
-- it, so suite teardown can restore real IO ahead of owned cleanup.
local realIoOpen = io.open

local FAKE_PATHS = {
  "libs.storage.src.CacheFs",
  "romdump.src.DerivedCacheState",
  "romdump.src.DerivedCacheAudit",
  "romdump.src.build.ArtifactJobs",
  "romdump.src.ProducerFingerprint",
  "romdump.src.build.InteractiveCacheBuild",
  "romdump.src.build.CompilerPool",
  "romdump.src.source.RomSource",
}

local saved = {}
local env
local CacheBuilder

-- The genuine canonical-inventory enumerator, captured before the suite
-- installs its package fakes so membership checks stay real.
local realCompleteJobs

local function newEnv()
  return {
    identity = {
      versionId = "heartgold",
      romSha1 = string.rep("b", 40),
      generationId = "test-generation",
      producerId = "d" .. string.rep("1", 64),
    },
    readyKeys = {},
    failKeys = {},
    pendingKeys = {},
    stuckMilestones = {},
    failureClasses = {},
    causeKeys = {},
    excludedKeys = {},
    milestones = {
      bootstrap = { "field-camera:global", "message-bank:219" },
      ["field-runtime"] = { "field-camera:global", "map-data:7", "script-member:0" },
    },
    sessions = {},
    pools = {},
    cacheWrites = {},
    stateMatches = false,
    auditAvailable = false,
    plansAvailable = true,
    invalidations = 0,
    publishes = 0,
    publishedIdentity = nil,
    waitCalls = 0,
    localRounds = nil,
  }
end

local function splitJobKey(jobKey)
  local kind, key = jobKey:match("^([^:]+):(.+)$")
  return kind, key
end

-- Smallest well-shaped generation inventory for canonical-membership
-- checks: the controlled corpus knows map 7 and no other map, with empty
-- banks, members, pages, and cell matrices around it.
local function canonicalPlans()
  return {
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = { 7 },
    indexBundle = { index = { matrices = {} } },
    mapIds = { 7 },
  }
end

local function makeSession(pool, identity)
  local session = {
    pool = pool,
    identity = identity,
    completeRequested = nil,
    requested = {},
    requestedSet = {},
    retired = false,
  }
  function session:_answer(jobKey)
    if env.failKeys[jobKey] ~= nil then
      return false, jobKey .. ": " .. env.failKeys[jobKey]
    end
    if env.excludedKeys[jobKey] then
      return false, jobKey .. ": source-planned exclusion"
    end
    if env.readyKeys[jobKey] or self.completed ~= nil and self.completed[jobKey] then
      return true, nil
    end
    return false, nil
  end
  function session:requestJob(kind, key, urgency)
    assert(not self.retired, "generation session is retired")
    assert(type(kind) == "string" and type(key) == "string", "job needs its canonical kind and key")
    assert(urgency == "required" or urgency == "near" or urgency == "sweep", "unknown urgency")
    local jobKey = kind .. ":" .. key
    -- Retained answers are idempotent like the production session: a
    -- repeated identical request observes without registering new work.
    if not self.requestedSet[jobKey] then
      self.requestedSet[jobKey] = true
      self.requested[#self.requested + 1] = jobKey
      self.pool.requested[#self.pool.requested + 1] = jobKey
    end
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
    if env.stuckMilestones ~= nil and env.stuckMilestones[name] then
      return false, nil
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
    -- Complete-scope readiness mirrors production: every requested job
    -- terminal (completed, ready, failed, or excluded) with exclusions
    -- reported through their own job confirmations, not this scope.
    self.completed = self.completed or {}
    for _, jobKey in ipairs(self.requested) do
      if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil then
        if not (self.completed[jobKey] or env.readyKeys[jobKey]) then
          return false, nil
        end
      end
    end
    return true, nil
  end
  function session:update()
    assert(not self.retired, "generation session is retired")
    self.completed = self.completed or {}
    local function completeAll()
      for _, jobKey in ipairs(self.requested) do
        if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil and env.pendingKeys[jobKey] == nil then
          self.completed[jobKey] = true
        end
      end
    end
    if env.localRounds ~= nil then
      if env.localRounds > 0 then
        env.localRounds = env.localRounds - 1
      end
      if env.localRounds == 0 then
        completeAll()
      end
    else
      completeAll()
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
    local localPending = env.localRounds ~= nil and env.localRounds > 0
    local settled = true
    for _, jobKey in ipairs(self.requested) do
      if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil then
        if not (self.completed[jobKey] or env.readyKeys[jobKey]) then
          settled = false
          break
        end
      end
    end
    if localPending then
      settled = false
    end
    return {
      ready = ready,
      failed = failed,
      failures = failures,
      enumerated = #self.requested,
      enumerationComplete = true,
      queued = 0,
      running = 0,
      settled = settled,
      planningPending = localPending,
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
        local state, err, cause = nil, nil, nil
        if env.failKeys[jobKey] ~= nil then
          state = "failed"
          err = jobKey .. ": " .. env.failKeys[jobKey]
          cause = env.causeKeys ~= nil and env.causeKeys[jobKey] or nil
        elseif env.excludedKeys[jobKey] then
          state = "failed"
          err = jobKey .. ": source-planned exclusion"
        elseif self.completed[jobKey] or env.readyKeys[jobKey] then
          state = "successful"
        else
          state = "pending"
        end
        local failureClass = nil
        if state == "failed" then
          if env.excludedKeys[jobKey] then
            failureClass = "source-exclusion"
          else
            failureClass = (env.failureClasses ~= nil and env.failureClasses[jobKey]) or "job"
          end
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
  -- scopes or jobs. Unregistered refs stay pending; failed roots report
  -- their failure; rows are fresh values that survive retire().
  function session:_snapshotScope(name)
    if name == "complete" then
      if self.completeRequested == nil then
        return { label = name, state = "pending", failure = nil }
      end
      self.completed = self.completed or {}
      for _, jobKey in ipairs(self.requested) do
        if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil then
          if not (self.completed[jobKey] or env.readyKeys[jobKey]) then
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
      if not self.requestedSet[jobKey] then
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
    if env.stuckMilestones ~= nil and env.stuckMilestones[name] then
      return { label = name, state = "pending", failure = nil }
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
        if not self.requestedSet[jobKey] then
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
  end
  return session
end

local function makeFakes()
  local fakes = {}
  fakes.CacheFs = {
    forVersion = function(versionId)
      return {
        versionId = versionId,
        write = function(_, path)
          env.cacheWrites[#env.cacheWrites + 1] = versionId .. ":" .. path
        end,
        read = function()
          return nil
        end,
        loadLua = function()
          return nil
        end,
        remove = function()
          return true
        end,
      }
    end,
  }
  fakes.DerivedCacheState = {
    path = "data/generated/build.lua",
    current = function(inputs)
      return { versionId = inputs.versionId, generationId = env.identity.generationId }
    end,
    matches = function()
      return env.stateMatches
    end,
    invalidate = function()
      env.invalidations = env.invalidations + 1
    end,
    publish = function(_, identity)
      env.publishes = env.publishes + 1
      env.publishedIdentity = identity
    end,
  }
  fakes.DerivedCacheAudit = {
    isAvailable = function(_, identity, plans)
      assert(identity ~= nil and plans ~= nil, "the generation audit requires identity and inventory")
      return env.auditAvailable
    end,
  }
  fakes.ArtifactJobs = {
    publishedPlans = function()
      if env.plansAvailable == false then
        return nil, "no published source inventory"
      end
      return canonicalPlans()
    end,
    completeJobs = function(plans)
      local enumerate = assert(realCompleteJobs, "canonical membership needs its genuine enumerator")
      return enumerate(plans)
    end,
  }
  fakes.ProducerFingerprint = {
    appBackend = function()
      return {}
    end,
    compute = function()
      return "producer-fingerprint"
    end,
  }
  fakes.CompilerPool = {
    new = function()
      local pool = { requested = {}, selected = nil }
      function pool:selectGeneration(identity, epoch)
        self.selected = { identity = identity, epoch = epoch }
      end
      function pool:update() end
      function pool:waitForProgress()
        env.waitCalls = (env.waitCalls or 0) + 1
      end
      function pool:drain()
        env.waitCalls = (env.waitCalls or 0) + 1
      end
      function pool:jobOutcome(_)
        return nil
      end
      function pool:shutdown() end
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
  fakes.RomSource = {
    fromPath = function()
      return nil, "rom source is faked out of the scope contract"
    end,
  }
  return fakes
end

local function scopedOptions(overrides)
  local options = {
    identity = env.identity,
    requirements = { "map:7" },
    allowCompileExclusions = false,
    log = function() end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return options
end

local function requireScopedPreparation()
  Assert.equal(
    type(CacheBuilder.prepareVersion),
    "function",
    "scoped preparation must drive one common session per version"
  )
end

-- Invocation-owned output paths: one atomically acquired directory per
-- suite invocation holds every profile and staging sibling this
-- run writes. A process-local counter is unique only inside that exclusive
-- root, never across processes, and no shared deterministic directory
-- is used.
---@type string|nil
local outputRoot = nil
local outputCounter = 0
local fakesInstalled = false

---@param value string
---@return string
local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param status any
---@return boolean
local function commandSucceeded(status)
  return status == 0 or status == true
end

---@return string
local function acquireOutputRoot()
  local handle = assert(io.popen("mktemp -d"), "mktemp -d could not start")
  local path = (handle:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local closed = handle:close()
  assert(commandSucceeded(closed), "mktemp -d did not exit successfully")
  assert(path ~= "", "mktemp -d produced no path")
  return path
end

---@param label string
---@return boolean
local function isSafeLabel(label)
  return label:match("^[A-Za-z0-9_-]+$") ~= nil
end

---@param label string
---@param suffix string
---@return string
local function newOutputPath(label, suffix)
  local root = assert(outputRoot, "the suite output root is not acquired")
  assert(isSafeLabel(label), "unsafe output label: " .. tostring(label))
  outputCounter = outputCounter + 1
  return root .. "/" .. label .. "-" .. tostring(outputCounter) .. suffix
end

---@param root string
local function removeOwnedRoot(root)
  assert(root ~= "" and root ~= "/", "refusing to remove an unowned path")
  local status = os.execute("rm -rf -- " .. shellQuote(root))
  assert(commandSucceeded(status), "owned output cleanup failed: " .. root)
end

local function releaseOutputRoot()
  local root = outputRoot
  outputRoot = nil
  outputCounter = 0
  io.open = realIoOpen
  if root ~= nil then
    removeOwnedRoot(root)
  end
end

local T = {}

local module = {
  beforeAll = function()
    outputRoot = acquireOutputRoot()
    realCompleteJobs = require("romdump.src.build.ArtifactJobs").completeJobs
    for _, path in ipairs(FAKE_PATHS) do
      saved[path] = package.loaded[path]
      package.loaded[path] = nil
    end
    env = newEnv()
    local fakes = makeFakes()
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = fakes[path:match("([^%.]+)$")]
    end
    fakesInstalled = true
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = require("romdump.src.CacheBuilder")
  end,
  afterAll = function()
    if fakesInstalled then
      for _, path in ipairs(FAKE_PATHS) do
        package.loaded[path] = saved[path]
      end
      package.loaded["romdump.src.CacheBuilder"] = nil
      fakesInstalled = false
    end
    releaseOutputRoot()
  end,
  tests = T,
}

-- A single map request runs only its declared closure: unrelated families
-- never reach the pool, and no full-build attestation is published even
-- though the requested scope succeeds.
function T.targeted_map_request_runs_only_its_closure_without_full_attestation()
  env = newEnv()
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:7" } }))
  Assert.isNil(err)
  Assert.isTrue(report.requestedReady, "the requested closure must be ready")
  Assert.isFalse(report.complete, "a targeted scope must never report a complete cache")
  Assert.equal(#env.sessions, 1, "one common session serves the targeted scope")
  Assert.isNil(env.sessions[1].completeRequested, "a targeted client must not request an unrelated complete build")
  local requested = {}
  for _, jobKey in ipairs(env.sessions[1].requested) do
    requested[jobKey] = true
  end
  Assert.isTrue(requested["map:7"], "the requested map must run")
  Assert.isNil(requested["map:5"], "an unrelated map must never be requested")
  Assert.isNil(requested["audio-bank:3"], "an unrelated audio bank must never be requested")
  Assert.equal(env.publishes, 0, "a targeted scope must never publish full attestation")
  local planned = report.counts.successful + report.counts.failed + report.counts.cancelled + report.counts.excluded
  Assert.equal(planned, report.counts.planned, "every planned key lands in exactly one outcome category")
end

-- A source-resolved map whose compiler fails aborts the command by default:
-- the failure names its canonical key, nothing is attested, and the staged
-- replacement never becomes authoritative.
function T.unaccepted_map_failure_fails_without_full_attestation()
  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:5" } }))
  Assert.isNil(report)
  Assert.notNil(err)
  Assert.equal(#env.sessions, 1, "the failure is observed through the common session")
  local status = env.sessions[1]:status()
  Assert.equal(status.failed, 1, "the failed job stays visible")
  Assert.isTrue(status.failures[1]:find("map:5", 1, true) ~= nil, "the failure names its canonical key")
  Assert.equal(env.publishes, 0, "a failed command publishes no full attestation")
end

-- With explicitly accepted exclusions the exploratory run succeeds partially:
-- the report carries complete=false with the excluded key listed, and no
-- complete attestation is published.
function T.accepted_map_exclusions_report_partial_success_without_full_attestation()
  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:5", "map:7" },
      allowCompileExclusions = true,
    })
  )
  Assert.isNil(err)
  Assert.isFalse(report.complete, "an exclusion-accepting run must never claim completeness")
  Assert.equal(#report.exclusions, 1, "the excluded map is reported")
  Assert.isTrue(report.exclusions[1]:find("map:5", 1, true) ~= nil, "the exclusion names its canonical key")
  Assert.equal(env.publishes, 0, "an exclusion-accepting run must not publish full attestation")
  local planned = report.counts.successful + report.counts.failed + report.counts.cancelled + report.counts.excluded
  Assert.equal(planned, report.counts.planned, "every planned key lands in exactly one outcome category")
end

-- The map-exclusion option accepts only map compile failures: an audio
-- failure still fails the command even when exclusions are allowed.
function T.non_map_family_failure_is_never_hidden_by_map_exclusions()
  env = newEnv()
  env.failKeys["audio-bank:3"] = "AUDIO_SOURCE_INVALID: injected audio rejection"
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "audio-bank:3" },
      allowCompileExclusions = true,
    })
  )
  Assert.isNil(report)
  Assert.notNil(err)
  Assert.equal(env.publishes, 0, "a hidden audio failure must never pass as partial success")
end

-- A matching full attestation with valid receipts is a fast path: no source
-- compilation runs and the existing current state is reused.
function T.warm_matching_attestation_compiles_nothing()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" } }))
  Assert.isNil(err)
  Assert.isTrue(report.complete, "the warm cache stays complete")
  Assert.equal(#env.pools, 0, "the fast path must not create a compiler pool")
  Assert.equal(#env.sessions, 0, "the fast path must not open a generation session")
  Assert.equal(env.invalidations, 0, "a current cache must not be invalidated")
  Assert.equal(env.publishes, 0, "a current cache must not be republished")
end

-- Missing planning metadata bypasses the warm shortcut: the command drains
-- its session instead of reporting current, and the strict gate still
-- refuses attestation without an inventory.
function T.missing_planning_metadata_bypasses_the_warm_shortcut()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  env.plansAvailable = false
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" } }))
  Assert.isNil(report)
  Assert.notNil(err)
  Assert.equal(#env.sessions, 1, "missing plans run the normal session")
  Assert.equal(env.publishes, 0, "no inventory means no attestation")
end

-- Opt-in profiling records every failed job with its cause and closes with a
-- partial census: observation never changes job identity or scope.
function T.profile_log_captures_failed_jobs_with_a_partial_census()
  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local profilePath = newOutputPath("partial-census", ".jsonl")
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:5", "map:7" },
      allowCompileExclusions = true,
      profile = profilePath,
    })
  )
  Assert.isNil(err)
  Assert.isFalse(report.complete, "the profiled run stays partial")
  local handle = assert(io.open(profilePath, "r"))
  local body = handle:read("*a")
  handle:close()
  os.remove(profilePath)
  Assert.isTrue(body:find("g4-cache-execution-v2", 1, true) ~= nil, "the log carries its execution schema")
  Assert.isTrue(body:find("map:5", 1, true) ~= nil, "the failed job remains in the log")
  Assert.isTrue(body:find("failed", 1, true) ~= nil, "the failed outcome remains in the log")
  Assert.isTrue(body:find("complete", 1, true) ~= nil, "the footer records completion scope")
  Assert.isNil(body:find("payload", 1, true), "profile output must not retain asset payloads")
end

-- An explicit development rebuild reruns only the selected ready job: its
-- dependencies are reused, the stale completion proof is invalidated first,
-- and staged publication invariants still hold.
function T.explicit_rebuild_reruns_only_the_selected_job()
  env = newEnv()
  env.readyKeys["map:7"] = true
  env.readyKeys["map-data:7"] = true
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:7" },
      rebuild = { "map:7" },
      dev = true,
    })
  )
  Assert.isNil(err)
  Assert.isTrue(report.requestedReady, "the rebuilt job must be ready")
  local requested = {}
  for _, jobKey in ipairs(env.sessions[1].requested) do
    requested[jobKey] = true
  end
  Assert.isTrue(requested["map:7"], "the selected job reruns")
  Assert.isNil(requested["map:5"], "unrelated jobs must not rerun")
  Assert.isTrue(env.invalidations >= 1, "a forced repair invalidates the stale completion proof first")
end

-- Malformed requirement strings fail before any cache mutation: unknown
-- kinds, signed keys, padded keys, paths, plan files, empty requirement
-- lists, and a missing version never open a session or write cache state.
function T.malformed_requests_fail_before_any_cache_mutation()
  env = newEnv()
  requireScopedPreparation()
  local badRequirementSets = {
    { "fused:7" },
    { "map:-7" },
    { "map: 7" },
    { "map:7 " },
    { "maps/7/complete" },
    { "plan.lua" },
    { "map:" },
    { ":7" },
  }
  for _, requirements in ipairs(badRequirementSets) do
    local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = requirements }))
    Assert.isNil(report, "malformed requirement must fail: " .. requirements[1])
    Assert.notNil(err)
  end
  local emptyReport, emptyErr = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = {} }))
  Assert.isNil(emptyReport)
  Assert.notNil(emptyErr)
  local missingReport, missingErr = CacheBuilder.prepareVersion(nil, scopedOptions({}))
  Assert.isNil(missingReport)
  Assert.notNil(missingErr)
  Assert.equal(#env.sessions, 0, "no malformed request may open a generation session")
  Assert.deepEqual(env.cacheWrites, {}, "no malformed request may mutate cache state")
  Assert.equal(env.publishes, 0, "no malformed request may publish attestation")
end

function T.drain_distinguishes_local_planning_from_physical_waiting()
  env = newEnv()
  env.localRounds = 3
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:7" } }))
  Assert.isNil(err)
  assert(report, "local planning must drain to a report")
  Assert.isTrue(report.requestedReady, "deferred planning repumps until the session settles")
  Assert.equal(env.waitCalls, 0, "the drain never waits on nonexistent physical work")
  Assert.isTrue(env.sessions[1].retired, "the drained session retires")
  local requestOk = pcall(function()
    env.sessions[1]:requestJob("map", "7", "required")
  end)
  Assert.isFalse(requestOk, "a retired session accepts no further work")

  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local badReport, badErr = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:5" } }))
  Assert.isNil(badReport)
  Assert.isTrue(
    tostring(badErr):find("map:5", 1, true) ~= nil,
    "an ordinary producer failure terminates with its actual cause"
  )
end

-- An independent leaf keeps a small closure through the command: a
-- camera-only preparation requests only the camera job and succeeds with
-- no source inventory work and no full attestation.
function T.camera_only_scope_requests_no_inventory_work()
  env = newEnv()
  requireScopedPreparation()
  local report, err =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "field-camera:global" } }))
  Assert.isNil(err)
  assert(report, "a camera-only preparation returns its report")
  Assert.isTrue(report.requestedReady, "the independent leaf succeeds")
  Assert.isFalse(report.complete, "a targeted scope never reports a complete cache")
  local requested = {}
  for _, jobKey in ipairs(env.sessions[1].requested) do
    requested[jobKey] = true
  end
  Assert.isTrue(requested["field-camera:global"], "the camera job runs")
  Assert.isNil(requested["source-plan:global"], "no inventory work is requested")
  Assert.equal(env.publishes, 0, "a targeted scope publishes no full attestation")
end

-- The command never proves a scope the session still calls pending: a
-- scope with one page that never becomes ready fails.
function T.settled_counts_never_override_a_pending_scope()
  env = newEnv()
  env.milestones["bootstrap"] = { "field-camera:global", "map-data:7" }
  env.stuckMilestones["bootstrap"] = true
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "bootstrap" },
    })
  )
  Assert.isNil(report, "a pending scope issues no report")
  Assert.notNil(err, "a pending scope fails instead of proving readiness")
  local Errors = require("libs.errors.src.Errors")
  Assert.isTrue(Errors.is(err), "the scope failure is structured")
  Assert.isTrue(
    tostring(err):find("bootstrap", 1, true) ~= nil,
    "the failure names its pending scope: " .. tostring(err)
  )
  Assert.equal(env.publishes, 0, "a pending scope publishes no attestation")
end

function T.warm_complete_with_absent_extra_map_refuses()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  env.excludedKeys["map:999999"] = true
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "complete", "map:999999" },
    })
  )
  Assert.isNil(err)
  assert(report, "an excluded mixed request returns its refusal report")
  Assert.isFalse(report.requestedReady, "an absent extra identity is never ready")
  Assert.isFalse(report.complete, "an excluded mixed request never reports a complete cache")
  Assert.equal(#report.exclusions, 1, "the absent identity is reported exactly once")
  Assert.isTrue(report.exclusions[1]:find("map:999999", 1, true) ~= nil, "the exclusion names its canonical key")
  Assert.equal(#env.sessions, 1, "the uncovered key falls through to the normal session")
  Assert.equal(env.publishes, 0, "a refused request publishes no attestation")
end

-- A refused uncovered mixed request preserves the audited attestation: the
-- first call refuses without invalidating, and a later plain complete
-- request reuses the current cache with no additional pool or session.
function T.refused_uncovered_request_preserves_attestation_for_later_reuse()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  env.excludedKeys["map:999999"] = true
  requireScopedPreparation()
  local first, firstErr =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete", "map:999999" } }))
  Assert.isNil(firstErr)
  assert(first, "a refused mixed request returns its refusal report")
  Assert.isFalse(first.requestedReady, "an uncovered extra identity is never ready")
  Assert.isFalse(first.complete, "a refused mixed request never reports a complete cache")
  Assert.equal(#first.exclusions, 1, "the uncovered identity is reported exactly once")
  Assert.isTrue(first.exclusions[1]:find("map:999999", 1, true) ~= nil, "the exclusion names its canonical key")
  Assert.equal(env.invalidations, 0, "a refused request preserves the audited attestation")
  Assert.equal(env.publishes, 0, "a refused request publishes no attestation")
  Assert.equal(#env.sessions, 1, "the uncovered key falls through to the normal session")
  local pools, sessions = #env.pools, #env.sessions
  local second, secondErr = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" } }))
  Assert.isNil(secondErr)
  assert(second, "the later complete request returns its report")
  Assert.isTrue(second.requestedReady, "the preserved attestation stays ready")
  Assert.isTrue(second.complete, "the preserved attestation stays complete")
  Assert.equal(env.invalidations, 0, "later reuse invalidates nothing")
  Assert.equal(#env.pools, pools, "later reuse creates no additional pool")
  Assert.equal(#env.sessions, sessions, "later reuse opens no additional session")
end

-- Cache history never changes satisfiability: the same absent mixed
-- request refuses identically whether or not a matching attestation
-- happens to remain on disk.
function T.profiled_absent_extra_map_excludes_without_success_evidence()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  env.excludedKeys["map:999999"] = true
  requireScopedPreparation()
  local profilePath = newOutputPath("absent-extra-profile", ".jsonl")
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "complete", "map:999999" },
      profile = profilePath,
    })
  )
  Assert.isNil(err)
  assert(report, "a profiled refusal returns its report")
  Assert.isFalse(report.requestedReady, "profiling never makes an absent identity ready")
  Assert.isFalse(report.complete, "a profiled refusal never reports a complete cache")
  Assert.isTrue(report.exclusions[1]:find("map:999999", 1, true) ~= nil, "the exclusion names its canonical key")
  local handle = assert(io.open(profilePath, "r"), "a refusal still closes its evidence log")
  local body = handle:read("*a")
  handle:close()
  os.remove(profilePath)
  Assert.isTrue(body:find("map:999999", 1, true) ~= nil, "the evidence names the excluded identity")
  Assert.isTrue(body:find('"requestedReady":false', 1, true) ~= nil, "the footer records the refusal")
  Assert.isTrue(body:find('"complete":false', 1, true) ~= nil, "the footer never claims completeness")
  Assert.equal(env.publishes, 0, "a profiled refusal publishes no attestation")
end

-- Freshness always outranks coverage: missing inventory, a failed audit,
-- and an explicit development rebuild each run the normal session instead
-- of any shortcut.
function T.stale_or_explicitly_rebuilt_complete_runs_the_normal_session()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  env.plansAvailable = false
  requireScopedPreparation()
  local missingReport, missingErr =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" } }))
  Assert.isNil(missingReport)
  Assert.notNil(missingErr)
  Assert.equal(#env.sessions, 1, "missing inventory runs the normal session")
  Assert.isTrue(env.invalidations >= 1, "missing inventory invalidates before replacement work")
  Assert.equal(env.publishes, 0, "missing inventory publishes no attestation")

  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = false
  requireScopedPreparation()
  local refusedReport, refusedErr =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" } }))
  Assert.isNil(refusedReport)
  Assert.notNil(refusedErr)
  Assert.equal(#env.sessions, 1, "a failed audit runs the normal session")
  Assert.isTrue(env.invalidations >= 1, "a failed audit invalidates before replacement work")
  Assert.equal(env.publishes, 0, "a failed audit publishes no attestation")

  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  requireScopedPreparation()
  local rebuiltReport, rebuiltErr = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "complete" },
      rebuild = { "map:7" },
      dev = true,
    })
  )
  Assert.isNil(rebuiltErr)
  assert(rebuiltReport, "an explicit rebuild returns its report")
  Assert.isTrue(rebuiltReport.requestedReady, "the rebuilt scope is ready")
  Assert.equal(#env.sessions, 1, "an explicit rebuild runs the normal session")
  Assert.isTrue(env.invalidations >= 1, "an explicit rebuild invalidates first")
end

-- Invocation-isolation probe: reports the output root this suite invocation
-- acquired, so two concurrent invocations can prove from their logs whether
-- they own disjoint output paths.
function T.invocation_reports_its_owned_evidence_path()
  local root = assert(outputRoot, "the suite output root is not acquired")
  print("owned-evidence-path: " .. root)
end

-- Owned cleanup removes exactly one invocation root: a released root and its
-- sentinel disappear while a sibling root, its sentinel, and their shared
-- parent remain intact.
function T.owned_cleanup_removes_only_the_released_root()
  local first = acquireOutputRoot()
  local second = acquireOutputRoot()
  Assert.isTrue(first ~= second, "independent acquisitions never share a root")
  local firstSentinel = first .. "/sentinel.txt"
  local secondSentinel = second .. "/sentinel.txt"
  local writer = assert(io.open(firstSentinel, "w"))
  writer:write("first")
  writer:close()
  writer = assert(io.open(secondSentinel, "w"))
  writer:write("second")
  writer:close()
  removeOwnedRoot(first)
  local leaked = io.open(firstSentinel, "r")
  if leaked ~= nil then
    leaked:close()
  end
  Assert.isNil(leaked, "the released root is gone")
  local reader = assert(io.open(secondSentinel, "r"), "the sibling root survives teardown")
  Assert.equal(reader:read("*a"), "second")
  reader:close()
  removeOwnedRoot(second)
  leaked = io.open(secondSentinel, "r")
  if leaked ~= nil then
    leaked:close()
  end
  Assert.isNil(leaked, "the second release removes its own root")
end

-- A test that fails before readback still restores genuine IO and releases
-- only its owned root: the original failure surfaces and the suite root
-- remains usable.
function T.injected_failure_still_restores_io_and_releases_ownership()
  local savedRoot, savedCounter = outputRoot, outputCounter
  outputRoot = acquireOutputRoot()
  local root = assert(outputRoot, "the scratch root is not acquired")
  local sentinel = root .. "/sentinel.txt"
  local writer = assert(io.open(sentinel, "w"))
  writer:write("owned")
  writer:close()
  io.open = function()
    return nil, "injected write failure"
  end
  local ok, _ = pcall(function()
    local handle = assert(io.open(root .. "/unwritten.txt", "w"))
    handle:write("never")
    handle:close()
  end)
  releaseOutputRoot()
  outputRoot, outputCounter = savedRoot, savedCounter
  Assert.isFalse(ok, "the injected IO failure must surface")
  local leaked = io.open(sentinel, "r")
  if leaked ~= nil then
    leaked:close()
  end
  Assert.isNil(leaked, "the owned root is released after failure")
  local probePath = newOutputPath("failure-teardown-probe", ".txt")
  local probe = assert(io.open(probePath, "w"), "genuine IO is restored after failure")
  probe:write("restored")
  probe:close()
  os.remove(probePath)
end

-- The common preparation scope admits the existing production milestones
-- beside bootstrap: each name parses to its own scope instead of failing
-- as an unknown requirement.
function T.field_milestone_scopes_parse_to_their_session_names()
  for _, name in ipairs({ "new-game-intro", "field-planning", "field-runtime" }) do
    local entry, err = CacheBuilder.parseRequirement(name)
    Assert.isNil(err, "milestone " .. name .. " must parse")
    assert(entry, "milestone " .. name .. " must produce an entry")
    Assert.equal(entry.scope, name, "milestone " .. name .. " keeps its own scope")
  end
  local bootstrap, bootstrapErr = CacheBuilder.parseRequirement("bootstrap")
  Assert.isNil(bootstrapErr, "bootstrap keeps parsing")
  assert(bootstrap, "bootstrap must produce an entry")
  Assert.equal(bootstrap.scope, "bootstrap")
end

-- A field milestone prepares through its session roster without invoking
-- the exhaustive scope: the requested closure is ready, the report stays
-- nonexhaustive, and no full attestation is published.
function T.field_runtime_scope_prepares_without_complete_attestation()
  env = newEnv()
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "field-runtime" } }))
  Assert.isNil(err)
  Assert.isTrue(report.requestedReady, "the requested milestone closure must be ready")
  Assert.isFalse(report.complete, "a milestone scope must never report a complete cache")
  Assert.equal(#env.sessions, 1, "one common session serves the milestone scope")
  Assert.isNil(env.sessions[1].completeRequested, "a milestone client must not request an unrelated complete build")
  Assert.equal(env.publishes, 0, "a milestone scope must never publish full attestation")
end

-- Output labels are confined to a safe alphabet so generated names can never
-- escape the owned root through path fragments.
function T.output_path_rejects_unsafe_labels()
  for _, label in ipairs({ "../escape", "a/b", "", "has space", "semi;colon", "quote'quote", "$HOME" }) do
    local raised = Assert.throws(function()
      newOutputPath(label, ".lua")
    end)
    Assert.isTrue(tostring(raised):find("unsafe output label", 1, true) ~= nil, "label must be rejected: " .. label)
  end
  local root = assert(outputRoot, "the suite output root is not acquired")
  local path = newOutputPath("probe-9_Z", ".lua")
  Assert.equal(path:sub(1, #root + 1), root .. "/")
  Assert.isTrue(path:sub(-4) == ".lua", "the suffix is preserved")
end

return module
