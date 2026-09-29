-- Command outcomes and opt-in execution evidence: every planned canonical job
-- appears exactly once with its terminal disposition, failure and cancellation
-- evidence is preserved through cleanup, a complete footer follows only the
-- final audit and attestation, explicit rebuilds run once per selected job, a
-- missing readiness proof fails the command, worker metrics never fabricate
-- unmeasured values, and observation failures fail the command. The session,
-- pool, cache, and state modules are faked through package.loaded before the
-- command owner is required, so the ledger is exercised without a ROM or
-- filesystem; the worker reply is exercised through the real worker with
-- controlled channels and source.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ArtifactState = require("romdump.src.build.ArtifactState")

-- The genuine IO opener, captured before any fault-injection test replaces
-- it, so suite teardown can restore real IO ahead of owned cleanup.
local realIoOpen = io.open

local FAKE_PATHS = {
  "libs.storage.src.CacheFs",
  "romdump.src.source.RomFs",
  "romdump.src.DerivedCacheState",
  "romdump.src.ProducerFingerprint",
  "romdump.src.DerivedCacheAudit",
  "romdump.src.build.ArtifactJobs",
  "romdump.src.build.InteractiveCacheBuild",
  "romdump.src.build.CompilerPool",
}

local WORKER_PATH = "romdump.src.build.CompilerWorker"
local BUILDER_PATH = "romdump.src.CacheBuilder"

-- The bounded diagnostic view the real pool keeps; the profile must not
-- depend on it.
local RING_LIMIT = 32

local saved = {}
local env
local CacheBuilder
local CompilerWorker

local function newEnv()
  return {
    identity = {
      versionId = "heartgold",
      generationId = "test-generation",
      producerId = "d" .. string.rep("1", 64),
    },
    failKeys = {},
    failureClasses = {},
    pendingKeys = {},
    excludedKeys = {},
    reusedKeys = {},
    causeKeys = {},
    poolFailures = {},
    failByVersion = {},
    infraError = nil,
    infraErrorByVersion = nil,
    -- A recorded pool fatal is candidate recovery evidence only when the
    -- drain exception is exactly this value; nil means no fatal recorded.
    poolFatal = nil,
    waitInfraError = nil,
    drainViaWait = false,
    diagnosticsRaise = nil,
    publishFails = false,
    publishFailCalls = {},
    publishAttempts = 0,
    publishedVersions = {},
    milestones = {
      bootstrap = { "field-camera:global" },
      ["field-runtime"] = { "map:7" },
    },
    sessions = {},
    pools = {},
    completedOrder = {},
    removals = {},
    invalidations = 0,
    publishes = 0,
    shutdowns = 0,
    retires = 0,
    stateStored = nil,
    stateMatches = false,
    auditAvailable = false,
    plansAvailable = true,
    closedSources = 0,
    executedJobs = {},
    executeResult = { stageName = "test-stage" },
  }
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
    requestedSet = {},
    completed = {},
    retired = false,
  }
  function session:_failFor(jobKey)
    local perVersion = env.failByVersion
    if perVersion ~= nil then
      local versionId = self.identity ~= nil and self.identity.versionId or nil
      if versionId ~= nil and perVersion[versionId] ~= nil and perVersion[versionId][jobKey] ~= nil then
        return perVersion[versionId][jobKey]
      end
    end
    return env.failKeys[jobKey]
  end
  function session:_answer(jobKey)
    if self:_failFor(jobKey) ~= nil then
      return false, jobKey .. ": " .. (self:_failFor(jobKey) or "")
    end
    if env.excludedKeys[jobKey] then
      return false, jobKey .. ": source-planned exclusion"
    end
    if env.pendingKeys[jobKey] then
      return false, nil
    end
    if self.completed[jobKey] then
      return true, nil
    end
    return false, nil
  end
  function session:requestJob(kind, key, urgency)
    assert(not self.retired, "generation session is retired")
    assert(type(kind) == "string" and type(key) == "string", "job needs its canonical kind and key")
    assert(urgency == "required" or urgency == "near" or urgency == "sweep", "unknown urgency")
    local jobKey = kind .. ":" .. key
    if not self.requestedSet[jobKey] then
      self.requestedSet[jobKey] = true
      self.requested[#self.requested + 1] = jobKey
      if not pool.requestedSet[jobKey] then
        pool.requestedSet[jobKey] = true
        pool.requested[#pool.requested + 1] = jobKey
      end
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
      if failure ~= nil then
        failures[#failures + 1] = failure
      end
      if not ok then
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
      -- Per-version failures belong to this session's corpus too: without
      -- them a failing version would never request its failing job.
      if env.failByVersion ~= nil and self.identity ~= nil and self.identity.versionId ~= nil then
        local versioned = env.failByVersion[self.identity.versionId]
        if type(versioned) == "table" then
          keySets[#keySets + 1] = versioned
        end
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
    local function versionFailed(jobKey)
      if env.failByVersion == nil or self.identity == nil or self.identity.versionId == nil then
        return nil
      end
      local versioned = env.failByVersion[self.identity.versionId]
      if type(versioned) == "table" then
        return versioned[jobKey]
      end
      return nil
    end
    for _, jobKey in ipairs(self.requested) do
      if versionFailed(jobKey) ~= nil then
        -- A per-version failure is terminal for this session; its cause
        -- surfaces through the job confirmation, not this scope.
      elseif
        env.failKeys[jobKey] == nil
        and env.excludedKeys[jobKey] == nil
        and env.pendingKeys ~= nil
        and env.pendingKeys[jobKey]
      then
        return false, nil
      elseif
        env.failKeys[jobKey] == nil
        and env.excludedKeys[jobKey] == nil
        and not (self.completed[jobKey] or (env.readyKeys ~= nil and env.readyKeys[jobKey]))
      then
        return false, nil
      end
    end
    return true, nil
  end
  function session:update()
    assert(not self.retired, "generation session is retired")
    for _, jobKey in ipairs(self.requested) do
      if
        self:_failFor(jobKey) == nil
        and env.pendingKeys[jobKey] == nil
        and env.excludedKeys[jobKey] == nil
        and not self.completed[jobKey]
      then
        self.completed[jobKey] = true
        if env.reusedKeys[jobKey] == nil then
          env.completedOrder[#env.completedOrder + 1] = jobKey
        end
      end
    end
    -- The production session delegates bounded waits to the pool; when the
    -- test arms that path the wait boundary is the failure origin.
    if env.drainViaWait then
      pool:waitForProgress()
    end
    local versioned = env.infraErrorByVersion
    if versioned ~= nil and self.identity ~= nil then
      local versionId = self.identity.versionId
      if versionId ~= nil and versioned[versionId] ~= nil then
        local injected = versioned[versionId]
        versioned[versionId] = nil
        error(injected, 0)
      end
    end
    if env.infraError ~= nil then
      local injected = env.infraError
      env.infraError = nil
      error(injected, 0)
    end
  end
  function session:status()
    local ready = 0
    local failures = {}
    for _, jobKey in ipairs(self.requested) do
      if self:_failFor(jobKey) ~= nil then
        failures[#failures + 1] = jobKey .. ": " .. (self:_failFor(jobKey) or "")
      elseif env.excludedKeys[jobKey] then
        failures[#failures + 1] = jobKey .. ": source-planned exclusion"
      elseif self.completed[jobKey] then
        ready = ready + 1
      end
    end
    return {
      ready = ready,
      queued = 0,
      running = 0,
      failed = #failures,
      failures = failures,
      enumerated = #self.requested,
      enumerationComplete = true,
      settled = true,
      planningPending = false,
    }
  end
  function session:outcomes()
    local list = {}
    for _, jobKey in ipairs(self.requested) do
      local kind, key = splitJobKey(jobKey)
      local state, err, cause, failureClass = nil, nil, nil, nil
      if self:_failFor(jobKey) ~= nil then
        state = "failed"
        err = jobKey .. ": " .. (self:_failFor(jobKey) or "")
        cause = env.causeKeys ~= nil and env.causeKeys[jobKey] or nil
        failureClass = (env.failureClasses ~= nil and env.failureClasses[jobKey]) or "job"
      elseif env.excludedKeys[jobKey] then
        state = "failed"
        err = jobKey .. ": source-planned exclusion"
        failureClass = "source-exclusion"
      elseif env.pendingKeys[jobKey] then
        state = "pending"
      elseif self.completed[jobKey] then
        state = "successful"
      else
        state = "pending"
      end
      list[#list + 1] = {
        kind = kind,
        key = key,
        jobKey = jobKey,
        state = state,
        reused = state == "successful" and env.reusedKeys[jobKey] ~= nil,
        error = err,
        causeJobKey = cause,
        failureClass = failureClass,
      }
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
      for _, jobKey in ipairs(self.requested) do
        if self:_failFor(jobKey) == nil and not env.excludedKeys[jobKey] then
          local pending = env.pendingKeys ~= nil and env.pendingKeys[jobKey]
          if pending or not self.completed[jobKey] then
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
        if failure ~= nil then
          failures[#failures + 1] = failure
        end
        if not ok then
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
        loadLua = function()
          return env.stateStored
        end,
        read = function(_, _)
          return "test-dump-marker"
        end,
        remove = function(_, path)
          env.removals[#env.removals + 1] = path
          return true
        end,
      }
    end,
  }
  fakes.RomFs = {
    open = function(versionId)
      return {
        versionId = versionId,
        metadata = function()
          return { sha1 = string.rep("a", 40) }
        end,
        close = function()
          env.closedSources = env.closedSources + 1
        end,
      }
    end,
  }
  fakes.DerivedCacheState = {
    path = "data/generated/build.lua",
    current = function(inputs)
      assert(type(inputs) == "table", "generation identity inputs are required")
      return {
        schema = 2,
        versionId = inputs.versionId,
        generationId = "test-generation",
        producerId = inputs.producerId,
        romSha1 = inputs.romSha1,
        mode = inputs.mode,
      }
    end,
    matches = function(stored)
      return env.stateMatches and stored == env.stateStored
    end,
    invalidate = function()
      env.invalidations = env.invalidations + 1
    end,
    publish = function(_, identity)
      env.publishAttempts = env.publishAttempts + 1
      if env.publishFails or (env.publishFailCalls ~= nil and env.publishFailCalls[env.publishAttempts]) then
        error("injected attestation failure", 0)
      end
      env.publishes = env.publishes + 1
      env.publishedIdentity = identity
      env.publishedVersions[#env.publishedVersions + 1] = identity.versionId
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
      assert(identity ~= nil and plans ~= nil, "the generation audit requires identity and inventory")
      return env.auditAvailable
    end,
  }
  fakes.ArtifactJobs = {
    publishedPlans = function()
      if env.plansAvailable == false then
        return nil, "no published source inventory"
      end
      return { stubInventory = true }
    end,
    closeSessions = function() end,
    -- The real worker validates before compiling: a cold test family is
    -- never reusable, so validation declines and execution proceeds.
    validateCurrent = function()
      return false
    end,
    execute = function(job)
      env.executedJobs[#env.executedJobs + 1] = job.kind .. ":" .. job.key
      return env.executeResult
    end,
  }
  fakes.CompilerPool = {
    new = function()
      local pool = { requested = {}, requestedSet = {} }
      function pool:drain() end
      function pool:waitForProgress()
        if env.waitInfraError ~= nil then
          local injected = env.waitInfraError
          env.waitInfraError = nil
          error(injected, 0)
        end
      end
      function pool:jobOutcome(jobKey)
        if env.poolFailures ~= nil and env.poolFailures[jobKey] ~= nil then
          return env.poolFailures[jobKey]
        end
        for _, completed in ipairs(env.completedOrder) do
          if completed == jobKey then
            return {
              jobKey = jobKey,
              generationId = env.identity.generationId,
              epoch = 1,
              state = "ready",
              workerId = 1,
              workSeconds = 0.01,
              timingReason = "test",
            }
          end
        end
        return nil
      end
      function pool:shutdown()
        env.shutdowns = env.shutdowns + 1
      end
      function pool:diagnostics()
        if env.diagnosticsRaise ~= nil then
          error(env.diagnosticsRaise, 0)
        end
        local entries = {}
        for _, jobKey in ipairs(env.completedOrder) do
          entries[#entries + 1] = { jobKey = jobKey, workerId = 1, workSeconds = 0.01, stagedBytes = 0 }
        end
        local recent = {}
        for index = math.max(1, #entries - RING_LIMIT + 1), #entries do
          recent[#recent + 1] = entries[index]
        end
        return {
          counts = { queued = 0, running = 0, prepared = 0 },
          recentTimings = recent,
          error = env.poolFatal,
        }
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
      assert(options.sweepEnabled == nil, "exhaustive intent travels as an explicit request, never a construction flag")
      local session = makeSession(options.pool, options.identity)
      env.sessions[#env.sessions + 1] = session
      return session
    end,
  }
  return fakes
end

local function scopedOptions(overrides)
  local options = {
    identity = env.identity,
    requirements = { "map:7" },
    log = function() end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return options
end

---@param path string
---@return string[] lines
local function readProfile(path)
  local handle = assert(io.open(path, "r"))
  local body = handle:read("*a")
  handle:close()
  os.remove(path)
  local lines = {}
  for line in (body or ""):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

---@param lines string[]
---@return string|nil header
---@return string|nil footer
---@return string[] rows
local function splitProfile(lines)
  local header, footer
  local rows = {}
  for _, line in ipairs(lines) do
    if line:find('"type":"header"', 1, true) ~= nil then
      header = line
    elseif line:find('"type":"footer"', 1, true) ~= nil then
      footer = line
    elseif line:find('"type":"job"', 1, true) ~= nil then
      rows[#rows + 1] = line
    end
  end
  return header, footer, rows
end

---@param line string
---@param name string
---@return number|nil
local function profileCount(line, name)
  local raw = line:match('"' .. name .. '":(%d+)')
  if raw == nil then
    return nil
  end
  return tonumber(raw)
end

---@param rows string[]
---@param key string
---@return string|nil row
local function rowForKey(rows, key)
  for _, row in ipairs(rows) do
    if row:find('"key":"' .. key .. '"', 1, true) ~= nil then
      return row
    end
  end
  return nil
end

---@param lines string[]
---@return string[] headers
---@return string[] footers
local function splitProfileAll(lines)
  local headers, footers = {}, {}
  for _, line in ipairs(lines) do
    if line:find('"type":"header"', 1, true) ~= nil then
      headers[#headers + 1] = line
    elseif line:find('"type":"footer"', 1, true) ~= nil then
      footers[#footers + 1] = line
    end
  end
  return headers, footers
end

-- Invocation-owned evidence paths: one atomically acquired directory per
-- suite invocation holds every profile this run writes. A process-local
-- counter is unique only inside that exclusive root, never across processes,
-- and no shared deterministic directory is used.
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
    for _, path in ipairs(FAKE_PATHS) do
      saved[path] = package.loaded[path]
      package.loaded[path] = nil
    end
    saved[WORKER_PATH] = package.loaded[WORKER_PATH]
    package.loaded[WORKER_PATH] = nil
    saved[BUILDER_PATH] = package.loaded[BUILDER_PATH]
    package.loaded[BUILDER_PATH] = nil
    env = newEnv()
    local fakes = makeFakes()
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = fakes[path:match("([^%.]+)$")]
    end
    fakesInstalled = true
    CacheBuilder = require("romdump.src.CacheBuilder")
    CompilerWorker = require("romdump.src.build.CompilerWorker")
  end,
  afterAll = function()
    if fakesInstalled then
      for _, path in ipairs(FAKE_PATHS) do
        package.loaded[path] = saved[path]
      end
      package.loaded[WORKER_PATH] = saved[WORKER_PATH]
      package.loaded[BUILDER_PATH] = saved[BUILDER_PATH]
      fakesInstalled = false
    end
    releaseOutputRoot()
  end,
  tests = T,
}

-- A scope larger than the bounded diagnostic view keeps every planned job in
-- the execution evidence: one header, one row per canonical job, and a
-- reconciling footer whose rows never depend on the retained sample.
function T.profile_records_every_planned_job_beyond_the_bounded_diagnostic_ring()
  env = newEnv()
  local requirements = {}
  for id = 1, 100 do
    requirements[#requirements + 1] = "map:" .. tostring(id)
  end
  local profilePath = newOutputPath("bounded-ring", ".jsonl")
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = requirements,
      profile = profilePath,
    })
  )
  Assert.isNil(err)
  assert(report ~= nil, "a fully compiled scope must return a report")
  Assert.isTrue(report.requestedReady, "a fully compiled scope must be ready")
  local header, footer, rows = splitProfile(readProfile(profilePath))
  assert(header ~= nil, "the evidence opens with a header")
  Assert.isTrue(
    header:find("g4-cache-execution-v2", 1, true) ~= nil,
    "the evidence carries the lossless execution schema, got: " .. tostring(header)
  )
  assert(footer ~= nil, "the evidence closes with a footer")
  Assert.equal(#rows, 100, "one row per planned canonical job")
  local seen = {}
  for _, row in ipairs(rows) do
    local kind = row:match('"kind":"([^"]+)"')
    local key = row:match('"key":"([^"]+)"')
    Assert.equal(kind, "map")
    assert(key ~= nil, "evidence rows carry their canonical key")
    Assert.isTrue(seen[key] == nil, "duplicate evidence row for map:" .. tostring(key))
    seen[key] = true
    Assert.isTrue(
      row:find('"workerId":null', 1, true) == nil,
      "map:" .. tostring(key) .. " lost its worker evidence to the diagnostic ring"
    )
  end
  for id = 1, 100 do
    Assert.isTrue(seen[tostring(id)] ~= nil, "missing evidence row for map:" .. tostring(id))
  end
  Assert.equal(profileCount(footer, "planned"), 100)
  Assert.equal(profileCount(footer, "successful"), 100)
  Assert.equal(profileCount(footer, "failed"), 0)
  Assert.equal(profileCount(footer, "cancelled"), 0)
  Assert.equal(profileCount(footer, "excluded"), 0)
  Assert.isTrue(footer:find('"complete":false', 1, true) ~= nil, "a targeted scope never claims completeness")
end

-- A mid-batch failure preserves what finished, keeps the blocked parent with
-- its own identity and the leaf cause, marks work that never ran as
-- cancelled rather than successful, and fails the command with a failure
-- footer whose partition reconciles.
function T.failure_keeps_completed_outcomes_and_marks_unrun_work_cancelled()
  env = newEnv()
  env.failKeys["map:1"] = "WORKER_FAILED: injected leaf failure"
  env.failKeys["map:2"] = "blocked by map:1: WORKER_FAILED: injected leaf failure"
  env.causeKeys["map:2"] = "map:1"
  env.pendingKeys["map:3"] = true
  local profilePath = newOutputPath("failure-outcomes", ".jsonl")
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:1", "map:2", "map:3" },
      profile = profilePath,
    })
  )
  Assert.isNil(report, "a failed scope must not return a success report")
  assert(err ~= nil, "a failed scope reports its cause")
  Assert.isTrue(Errors.is(err), "failures are structured")
  local _, footer, rows = splitProfile(readProfile(profilePath))
  assert(footer ~= nil, "a handled failure still closes with a footer")
  Assert.equal(#rows, 3, "every planned job keeps exactly one row")
  local leaf = rowForKey(rows, "1")
  assert(leaf ~= nil, "the failed leaf keeps its row")
  Assert.isTrue(leaf:find('"failed"', 1, true) ~= nil, "the leaf row carries its failed disposition")
  Assert.isTrue(leaf:find("map:1", 1, true) ~= nil, "the leaf row names its own identity")
  local parent = rowForKey(rows, "2")
  assert(parent ~= nil, "the blocked parent keeps its own row")
  Assert.isTrue(parent:find('"failed"', 1, true) ~= nil, "the parent row carries its own failed disposition")
  Assert.isTrue(parent:find("map:2", 1, true) ~= nil, "the parent row names its own identity")
  Assert.isTrue(parent:find("map:1", 1, true) ~= nil, "the parent row keeps the leaf cause")
  local unrun = rowForKey(rows, "3")
  assert(unrun ~= nil, "work that never ran keeps an explicit row")
  Assert.isTrue(
    unrun:find('"cancelled"', 1, true) ~= nil,
    "work that never ran is cancelled, never successful by default, got: " .. tostring(unrun)
  )
  local planned = assert(profileCount(footer, "planned"), "the footer carries its partition")
  local reconciled = assert(profileCount(footer, "successful"), "the footer carries its partition")
    + assert(profileCount(footer, "failed"), "the footer carries its partition")
    + assert(profileCount(footer, "cancelled"), "the footer carries its partition")
    + assert(profileCount(footer, "excluded"), "the footer carries its partition")
  Assert.equal(planned, reconciled, "the footer partition reconciles")
  Assert.equal(profileCount(footer, "failed"), 2)
  Assert.isTrue(
    footer:find('"auditPassed":false', 1, true) ~= nil,
    "a failed scope records no audit proof, got: " .. tostring(footer)
  )
  Assert.isTrue(
    footer:find('"attestationPublished":false', 1, true) ~= nil,
    "a failed scope records no attestation, got: " .. tostring(footer)
  )
end

function T.explicit_rebuild_deduplicates_keys_and_reruns_only_the_selected_job()
  env = newEnv()
  env.stateStored = { schema = 2, generationId = "test-generation" }
  env.stateMatches = true
  env.auditAvailable = true
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "complete", "map:7" },
      rebuild = { "map:7", "map:7" },
      dev = true,
    })
  )
  Assert.isNil(err)
  assert(report ~= nil, "the repaired scope must return a report")
  Assert.isTrue(report.requestedReady, "the rebuilt scope must be ready")
  Assert.isTrue(report.complete, "the repaired scope attests completeness")
  local expectedPath = ArtifactState.path("map", "7")
  Assert.equal(#env.removals, 1, "a duplicated rebuild key reruns exactly once")
  Assert.equal(env.removals[1], expectedPath, "only the selected job is forced past its receipt")
  Assert.isTrue(env.invalidations >= 1, "a forced repair invalidates the stale completion proof first")
  local requested = {}
  for _, jobKey in ipairs(env.sessions[1].requested) do
    requested[jobKey] = true
  end
  Assert.isTrue(requested["map:7"], "the selected job reruns")
  Assert.equal(env.publishes, 1, "the new complete proof follows the audit")
end

-- The worker reply keeps measured work time but never fabricates an
-- unmeasured staged-byte count: unavailable metrics stay absent with their
-- reason instead of zero.
function T.worker_reports_unmeasured_staged_bytes_as_absent_not_zero()
  env = newEnv()
  local pushed = {}
  local input = {
    queue = {
      {
        kind = "map",
        key = "7",
        jobKey = "map:7",
        versionId = "heartgold",
        generationId = "test-generation",
        epoch = 1,
        sizeClass = "normal",
        payload = {},
      },
      { kind = "stop" },
    },
  }
  function input:demand()
    return table.remove(self.queue, 1)
  end
  local resultChannel = {}
  function resultChannel:push(message)
    pushed[#pushed + 1] = message
  end
  CompilerWorker.run(1, input, resultChannel)
  Assert.equal(#env.executedJobs, 1, "the worker executes the dispatched job")
  Assert.equal(#pushed, 1, "the worker answers with one terminal reply")
  local reply = pushed[1]
  Assert.equal(reply.status, "prepared")
  Assert.equal(reply.jobKey, "map:7")
  Assert.isTrue(type(reply.workSeconds) == "number", "executed work carries its measured duration")
  Assert.isNil(reply.stagedBytes, "unmeasured staged bytes stay absent, got: " .. tostring(reply.stagedBytes))
  Assert.notNil(reply.timingReason, "the reply carries its timing reason")
  Assert.equal(env.closedSources, 1, "the worker releases its source context on exit")
end

function T.warm_reused_jobs_report_reuse_without_fabricated_timing()
  env = newEnv()
  env.reusedKeys["map:7"] = true
  local profilePath = newOutputPath("warm-reuse", ".jsonl")
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:7" },
      profile = profilePath,
    })
  )
  Assert.isNil(err)
  assert(report ~= nil, "a fully reused scope must return a report")
  Assert.isTrue(report.requestedReady, "a fully reused scope must be ready")
  Assert.isFalse(report.complete, "a targeted scope never claims completeness")
  Assert.equal(report.counts.successful, 1)
  Assert.equal(#report.outcomes, 1)
  Assert.isTrue(report.outcomes[1].reused, "a validated job without pool execution is reused")
  local _, footer, rows = splitProfile(readProfile(profilePath))
  assert(footer ~= nil, "the profile carries a footer")
  Assert.equal(#rows, 1)
  local row = rows[1]
  Assert.isTrue(row:find('"reused":true', 1, true) ~= nil, "the row marks its reuse, got: " .. tostring(row))
  Assert.isTrue(row:find('"workerId":null', 1, true) ~= nil, "a reused job has no worker evidence")
  Assert.isTrue(row:find('"stagedBytes":0', 1, true) == nil, "unmeasured metrics are never zero-filled")
  Assert.equal(profileCount(footer, "successful"), 1)
end

-- An explicit source exclusion is reported separately from failures: the
-- command returns its report without readiness, the exclusion names its
-- cause, and no attestation is published.
function T.explicit_source_exclusion_reports_separately_without_readiness()
  env = newEnv()
  env.excludedKeys["map:5"] = true
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:5", "map:7" },
    })
  )
  Assert.isNil(err)
  assert(report ~= nil, "an excluded scope returns its report instead of a hard failure")
  Assert.isFalse(report.requestedReady, "an excluded scope is never ready")
  Assert.isFalse(report.complete, "an excluded scope never claims completeness")
  Assert.equal(#report.sourceExclusions, 1)
  Assert.isTrue(report.sourceExclusions[1]:find("map:5", 1, true) ~= nil, "the exclusion names its key")
  Assert.equal(report.counts.excluded, 1)
  Assert.equal(report.counts.successful, 1)
  Assert.equal(env.publishes, 0, "an excluded scope publishes no attestation")
end

function T.targeted_finalization_reports_exact_footer_combinations()
  env = newEnv()
  env.stateStored = { schema = 2, generationId = "test-generation" }
  env.stateMatches = true
  env.auditAvailable = true
  local currentPath = newOutputPath("matrix-current", ".jsonl")
  local current, currentErr =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" }, profile = currentPath }))
  Assert.isNil(currentErr)
  assert(current ~= nil, "the already-current scope must return a report")
  Assert.isTrue(current.complete, "the already-current scope stays complete")
  Assert.equal(env.publishes, 0, "the already-current scope publishes no new attestation")
  local _, currentFooter, _ = splitProfile(readProfile(currentPath))
  assert(currentFooter ~= nil, "the current run still closes with a footer")
  Assert.isTrue(currentFooter:find('"auditPassed":true', 1, true) ~= nil, "got: " .. tostring(currentFooter))
  Assert.isTrue(currentFooter:find('"attestationPublished":false', 1, true) ~= nil, "got: " .. tostring(currentFooter))
  Assert.isTrue(currentFooter:find('"complete":true', 1, true) ~= nil, "got: " .. tostring(currentFooter))

  env = newEnv()
  local targetedPath = newOutputPath("matrix-targeted", ".jsonl")
  local targeted, targetedErr =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:7" }, profile = targetedPath }))
  Assert.isNil(targetedErr)
  assert(targeted ~= nil, "a targeted success must return a report")
  Assert.isTrue(targeted.requestedReady, "a targeted success must be ready")
  Assert.isFalse(targeted.complete, "a targeted scope never claims completeness")
  local _, targetedFooter, _ = splitProfile(readProfile(targetedPath))
  assert(targetedFooter ~= nil, "the targeted run still closes with a footer")
  Assert.isTrue(targetedFooter:find('"auditPassed":false', 1, true) ~= nil, "got: " .. tostring(targetedFooter))
  Assert.isTrue(
    targetedFooter:find('"attestationPublished":false', 1, true) ~= nil,
    "got: " .. tostring(targetedFooter)
  )
  Assert.isTrue(targetedFooter:find('"complete":false', 1, true) ~= nil, "got: " .. tostring(targetedFooter))

  env = newEnv()
  local auditPath = newOutputPath("matrix-audit", ".jsonl")
  local auditReport, auditErr =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" }, profile = auditPath }))
  Assert.isNil(auditReport, "an unaudited scope must not return a success report")
  Assert.notNil(auditErr)
  local _, auditFooter, _ = splitProfile(readProfile(auditPath))
  assert(auditFooter ~= nil, "the unaudited run still closes with a footer")
  Assert.isTrue(auditFooter:find('"auditPassed":false', 1, true) ~= nil, "got: " .. tostring(auditFooter))
  Assert.isTrue(auditFooter:find('"attestationPublished":false', 1, true) ~= nil, "got: " .. tostring(auditFooter))
  Assert.isTrue(auditFooter:find('"complete":false', 1, true) ~= nil, "got: " .. tostring(auditFooter))

  env = newEnv()
  env.auditAvailable = true
  env.publishFails = true
  local attestPath = newOutputPath("matrix-attestation", ".jsonl")
  local attestReport, attestErr =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" }, profile = attestPath }))
  Assert.isNil(attestReport, "a scope without attestation must not return success")
  Assert.notNil(attestErr)
  Assert.isTrue(Errors.is(attestErr), "attestation failures are structured")
  Assert.equal(env.publishes, 0, "a failed attestation publishes nothing")
  local _, attestFooter, _ = splitProfile(readProfile(attestPath))
  assert(attestFooter ~= nil, "the unattested run still closes with a footer")
  Assert.isTrue(attestFooter:find('"auditPassed":true', 1, true) ~= nil, "got: " .. tostring(attestFooter))
  Assert.isTrue(attestFooter:find('"attestationPublished":false', 1, true) ~= nil, "got: " .. tostring(attestFooter))
  Assert.isTrue(attestFooter:find('"complete":false', 1, true) ~= nil, "got: " .. tostring(attestFooter))

  env = newEnv()
  env.auditAvailable = true
  local successPath = newOutputPath("matrix-success", ".jsonl")
  local success, successErr =
    CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" }, profile = successPath }))
  Assert.isNil(successErr)
  assert(success ~= nil, "an attested scope must return a report")
  Assert.isTrue(success.requestedReady, "an attested scope must be ready")
  Assert.isTrue(success.complete, "an attested scope attests completeness")
  Assert.equal(env.publishes, 1, "an attested scope publishes its new proof")
  local _, successFooter, _ = splitProfile(readProfile(successPath))
  assert(successFooter ~= nil, "the attested run still closes with a footer")
  Assert.isTrue(successFooter:find('"auditPassed":true', 1, true) ~= nil, "got: " .. tostring(successFooter))
  Assert.isTrue(successFooter:find('"attestationPublished":true', 1, true) ~= nil, "got: " .. tostring(successFooter))
  Assert.isTrue(successFooter:find('"complete":true', 1, true) ~= nil, "got: " .. tostring(successFooter))
end

function T.dependency_blocked_map_with_non_map_cause_is_never_a_compile_exclusion()
  env = newEnv()
  env.failKeys["map:9"] = "blocked by ui:font: prerequisite ui:font failed"
  env.failureClasses["map:9"] = "dependency"
  env.causeKeys["map:9"] = "ui:font"
  local profilePath = newOutputPath("dependency-blocked", ".jsonl")
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:7", "map:9" },
      allowCompileExclusions = true,
      profile = profilePath,
    })
  )
  Assert.isNil(report, "a prerequisite failure is never laundered into an accepted exclusion")
  assert(err ~= nil, "a prerequisite failure reports its cause")
  Assert.isTrue(Errors.is(err), "failures are structured")
  local _, footer, rows = splitProfile(readProfile(profilePath))
  assert(footer ~= nil, "a handled failure still closes with a footer")
  Assert.equal(#rows, 2, "every planned job keeps exactly one row")
  local blocked = rowForKey(rows, "9")
  assert(blocked ~= nil, "the blocked job keeps its row")
  Assert.isTrue(
    blocked:find('"failed"', 1, true) ~= nil,
    "the dependency-blocked row stays failed, got: " .. tostring(blocked)
  )
  Assert.isTrue(
    blocked:find("ui:font", 1, true) ~= nil,
    "the row keeps its exact non-map cause, got: " .. tostring(blocked)
  )
  Assert.equal(profileCount(footer, "failed"), 1)
  Assert.equal(profileCount(footer, "excluded"), 0)
end

-- A handled infrastructure failure preserves known work: the validated
-- success stays successful, the exact failed job fails, unfinished work is
-- cancelled, the failure footer is emitted, and every owner is released
-- exactly once.
function T.handled_infrastructure_failure_keeps_known_rows_and_failure_footer()
  env = newEnv()
  env.failKeys["map:2"] = "WORKER_FAILED: injected pool failure"
  env.failureClasses["map:2"] = "job"
  env.poolFailures["map:2"] = {
    jobKey = "map:2",
    generationId = "test-generation",
    epoch = 1,
    state = "failed",
    error = "map:2: injected pool failure",
    workerId = 2,
    workSeconds = 0.02,
    timingReason = "test",
  }
  env.pendingKeys["map:3"] = true
  env.infraError =
    Errors.new("CACHE_PREPARATION_FAILED", "injected infrastructure failure", { versionId = "heartgold" })
  local profilePath = newOutputPath("infra-failure", ".jsonl")
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:1", "map:2", "map:3" },
      profile = profilePath,
    })
  )
  Assert.isNil(report, "an interrupted scope must not return a success report")
  assert(err ~= nil, "an interrupted scope reports its cause")
  Assert.isTrue(Errors.is(err), "failures are structured")
  local _, footer, rows = splitProfile(readProfile(profilePath))
  assert(footer ~= nil, "a handled infrastructure failure still closes with a footer")
  Assert.equal(#rows, 3, "every planned job keeps exactly one row")
  local succeeded = rowForKey(rows, "1")
  assert(succeeded ~= nil, "validated work keeps its row")
  Assert.isTrue(
    succeeded:find('"successful"', 1, true) ~= nil,
    "validated work stays successful, got: " .. tostring(succeeded)
  )
  local failed = rowForKey(rows, "2")
  assert(failed ~= nil, "the failed job keeps its row")
  Assert.isTrue(failed:find('"failed"', 1, true) ~= nil, "the exact failed job fails, got: " .. tostring(failed))
  local unfinished = rowForKey(rows, "3")
  assert(unfinished ~= nil, "unfinished work keeps an explicit row")
  Assert.isTrue(
    unfinished:find('"cancelled"', 1, true) ~= nil,
    "unfinished work is cancelled, got: " .. tostring(unfinished)
  )
  Assert.equal(profileCount(footer, "planned"), 3)
  Assert.equal(profileCount(footer, "successful"), 1)
  Assert.equal(profileCount(footer, "failed"), 1)
  Assert.equal(profileCount(footer, "cancelled"), 1)
  Assert.equal(profileCount(footer, "excluded"), 0)
  Assert.equal(env.shutdowns, 1, "the pool shuts down exactly once")
  Assert.equal(env.retires, 1, "the session retires exactly once")
end

-- A later version failure publishes no new attestation: the first version
-- keeps its audited successful rows without a new publication or complete
-- proof, the second version fails, the command fails, and both started
-- versions retain evidence.
function T.later_version_failure_publishes_no_new_attestation()
  env = newEnv()
  env.auditAvailable = true
  -- Heartgold's map stays warm while soulsilver's fails: the complete
  -- scope enrolls the fixture-known corpus in every version.
  env.readyKeys = { ["map:7"] = true }
  env.failByVersion = { soulsilver = { ["map:7"] = "WORKER_FAILED: injected later-version failure" } }
  env.failureClasses["map:7"] = "job"
  local profilePath = newOutputPath("later-version", ".jsonl")
  local report, err = CacheBuilder.buildVersions(
    { "heartgold", "soulsilver" },
    { log = function() end, profile = profilePath }
  )
  Assert.isNil(report, "a batch with a failed version must not succeed")
  assert(err ~= nil, "the batch reports its failure")
  Assert.equal(env.publishes, 0, "no new attestation is published when a later version fails")
  Assert.equal(env.publishAttempts, 0, "the collection gate runs before any new attestation")
  local lines = readProfile(profilePath)
  local headers, footers = splitProfileAll(lines)
  Assert.equal(#headers, 2, "both started versions retain evidence")
  Assert.equal(#footers, 2, "both started versions retain evidence")
  local _, _, rows = splitProfile(lines)
  Assert.equal(#rows, 4, "every planned job of both versions keeps exactly one row")
  Assert.isTrue(
    footers[1]:find('"versionId":"heartgold"', 1, true) ~= nil,
    "the first footer belongs to the first version, got: " .. tostring(footers[1])
  )
  Assert.equal(profileCount(footers[1], "successful"), 2, "the first version reports its audited successful jobs")
  Assert.isTrue(
    footers[1]:find('"attestationPublished":false', 1, true) ~= nil,
    "the first version claims no new publication, got: " .. tostring(footers[1])
  )
  Assert.isTrue(
    footers[1]:find('"complete":false', 1, true) ~= nil,
    "an uncommitted proof is never complete, got: " .. tostring(footers[1])
  )
  Assert.isTrue(
    footers[2]:find('"versionId":"soulsilver"', 1, true) ~= nil,
    "the second footer belongs to the failed version, got: " .. tostring(footers[2])
  )
  Assert.isTrue(
    (profileCount(footers[2], "failed") or 0) >= 1,
    "the failed version records its failure, got: " .. tostring(footers[2])
  )
end

-- A partial publication failure reports actual effects: only the real
-- publication is flagged, failed and unattempted versions stay false, the
-- command fails, and valid earlier outputs are not rolled back.
function T.partial_publication_failure_reports_actual_effects()
  env = newEnv()
  env.auditAvailable = true
  env.publishFailCalls = { [2] = true }
  local profilePath = newOutputPath("partial-publication", ".jsonl")
  local ok, report, err = pcall(
    CacheBuilder.buildVersions,
    { "heartgold", "soulsilver" },
    { log = function() end, profile = profilePath }
  )
  Assert.isTrue(not ok or report == nil, "a batch with a failed publication must not succeed")
  Assert.equal(env.publishes, 1, "only the actual publication is recorded")
  Assert.equal(env.publishAttempts, 2, "a failed publication stops every later publication attempt")
  Assert.equal(#env.publishedVersions, 1, "only the actual publication is recorded")
  Assert.equal(env.publishedVersions[1], "heartgold", "the first publication is preserved")
  for _, path in ipairs(env.removals) do
    Assert.isTrue(
      path ~= ArtifactState.path("map", "7"),
      "valid published artifacts are not rolled back, got: " .. tostring(path)
    )
  end
  local lines = readProfile(profilePath)
  local _, footers = splitProfileAll(lines)
  Assert.equal(#footers, 2, "both started versions retain evidence")
  Assert.isTrue(
    footers[1]:find('"attestationPublished":true', 1, true) ~= nil,
    "the actual publication is flagged, got: " .. tostring(footers[1])
  )
  Assert.isTrue(
    footers[2]:find('"attestationPublished":false', 1, true) ~= nil,
    "the failed publication stays unflagged, got: " .. tostring(footers[2])
  )
  if ok then
    assert(err ~= nil, "the batch reports its publication failure")
  end
end

-- A shared profile close failure fails the command: throwing and explicit
-- unsuccessful closes report no success, the sink closes exactly once, and
-- already published artifact facts stay factual.
function T.shared_profile_close_failure_fails_the_command()
  for _, mode in ipairs({ "throwing", "unsuccessful" }) do
    env = newEnv()
    env.auditAvailable = true
    local profilePath = newOutputPath("close-failure", ".jsonl")
    local closes = 0
    local realOpen = io.open
    io.open = function(path, openMode)
      if path == profilePath then
        return {
          write = function()
            return true
          end,
          close = function()
            closes = closes + 1
            if mode == "throwing" then
              error("injected close failure", 0)
            end
            return nil, "injected close failure"
          end,
        }
      end
      return realOpen(path, openMode)
    end
    local ok, report, err = pcall(
      CacheBuilder.buildVersions,
      { "heartgold" },
      { log = function() end, profile = profilePath }
    )
    io.open = realOpen
    os.remove(profilePath)
    Assert.isTrue(ok, "a close failure is a handled command failure, not a crash (" .. mode .. ")")
    Assert.isNil(report, "a command that cannot close its evidence must not claim success (" .. mode .. ")")
    assert(err ~= nil, "the sink failure is reported (" .. mode .. ")")
    Assert.equal(closes, 1, "the shared sink closes exactly once (" .. mode .. ")")
    Assert.equal(env.publishes, 1, "already published artifact facts stay factual (" .. mode .. ")")
  end
end

function T.sink_failure_keeps_recorded_interruption_failed()
  for _, mode in ipairs({ "write", "close" }) do
    env = newEnv()
    local fatal = "recorded stop with a failing sink"
    env.poolFatal = fatal
    env.infraError = fatal
    local profilePath = newOutputPath("sink-failure-" .. mode, ".jsonl")
    local realOpen = io.open
    io.open = function(path, openMode)
      if path == profilePath then
        if mode == "write" then
          return {
            write = function()
              return nil, "injected write failure"
            end,
            close = function()
              return true
            end,
          }
        end
        return {
          write = function()
            return true
          end,
          close = function()
            error("injected close failure", 0)
          end,
        }
      end
      return realOpen(path, openMode)
    end
    local ok, report, err = pcall(
      CacheBuilder.prepareVersion,
      "heartgold",
      scopedOptions({ requirements = { "map:7" }, profile = profilePath })
    )
    io.open = realOpen
    os.remove(profilePath)
    Assert.isTrue(ok, "a sink failure is a handled command failure, not a crash (" .. mode .. ")")
    Assert.isNil(report, "a command that cannot record its evidence must not claim success (" .. mode .. ")")
    assert(err ~= nil, "the sink failure is reported (" .. mode .. ")")
  end
end

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

function T.output_path_rejects_unsafe_labels()
  for _, label in ipairs({ "../escape", "a/b", "", "has space", "semi;colon", "quote'quote", "$HOME" }) do
    local raised = Assert.throws(function()
      newOutputPath(label, ".jsonl")
    end)
    Assert.isTrue(tostring(raised):find("unsafe output label", 1, true) ~= nil, "label must be rejected: " .. label)
  end
  local root = assert(outputRoot, "the suite output root is not acquired")
  local path = newOutputPath("probe-9_Z", ".jsonl")
  Assert.equal(path:sub(1, #root + 1), root .. "/")
  Assert.isTrue(path:sub(-6) == ".jsonl", "the suffix is preserved")
end

return module
