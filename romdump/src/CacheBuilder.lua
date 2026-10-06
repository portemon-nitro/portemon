-- Exhaustive and targeted cache preparation through the common generation
-- session. buildVersions prepares every listed version with the complete
-- scope; prepareVersion prepares one version with a declared closure. Both
-- drive InteractiveCacheBuild jobs and validate the requested scope. A
-- matching complete attestation at data/generated/build.lua is trusted
-- for ordinary reuse without re-proving payloads; the attestation is
-- published after strict exhaustive success, and a targeted scope never
-- attests completeness no matter its exit status. The exhaustive audit
-- remains an explicit manual diagnostic and never runs here.

local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local Errors = require("libs.errors.src.Errors")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local RawDumpContract = require("romdump.src.source.RawDumpContract")
local GameVersion = require("romdump.src.source.GameVersion")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local ArtifactState = require("romdump.src.build.ArtifactState")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local CompilerPool = require("romdump.src.build.CompilerPool")
local Schema = require("libs.script.src.Schema")

local CacheBuilder = {}

-- Closed preparation scopes: the fixed milestones plus the exhaustive scope.
-- Anything else must be a canonical kind:key pair owned by ArtifactState.
local SCOPES = {
  bootstrap = true,
  ["new-game-intro"] = true,
  ["field-planning"] = true,
  ["field-runtime"] = true,
  complete = true,
}

local epochCounter = 0

---@class CacheBuilder.Requirement
---@field scope string|nil closed scope word when the requirement names a milestone scope
---@field kind string|nil canonical job kind when the requirement names a job
---@field key string|nil canonical job key when the requirement names a job
---@field jobKey string|nil canonical kind:key identity when the requirement names a job

---@param text string
---@return CacheBuilder.Requirement|nil entry
---@return Errors.Error|string|nil err
function CacheBuilder.parseRequirement(text)
  if type(text) ~= "string" or text == "" then
    return nil, Errors.new("INVALID_CACHE_REQUIREMENT", "cache requirement must be a non-empty string", {})
  end
  if SCOPES[text] then
    return { scope = text }
  end
  local kind, key = text:match("^([^:]+):(.+)$")
  if kind == nil or not pcall(ArtifactState.path, kind, key) then
    return nil, Errors.new("INVALID_CACHE_REQUIREMENT", "unknown cache requirement: " .. text, { requirement = text })
  end
  return { kind = kind, key = key, jobKey = kind .. ":" .. key }
end

---@param requirements string[]
---@return string[]|nil ordered
---@return CacheBuilder.Requirement[]|nil parsed
---@return Errors.Error|string|nil err
local function parseRequirements(requirements)
  if type(requirements) ~= "table" or #requirements == 0 then
    return nil, nil, Errors.new("INVALID_CACHE_REQUIREMENT", "preparation requires at least one requirement", {})
  end
  local seen, ordered, parsed = {}, {}, {}
  for _, text in ipairs(requirements) do
    local entry, err = CacheBuilder.parseRequirement(text)
    if entry == nil then
      return nil, nil, err
    end
    if not seen[text] then
      seen[text] = true
      ordered[#ordered + 1] = text
      parsed[#parsed + 1] = entry
    end
  end
  return ordered, parsed, nil
end

---@param versionId string
---@return Errors.Error|string|nil err
local function checkVersion(versionId)
  if type(versionId) ~= "string" or GameVersion.VERSIONS[versionId] == nil then
    return Errors.new("UNSUPPORTED_VERSION", "unsupported version: " .. tostring(versionId), { versionId = versionId })
  end
  return nil
end

---@param identity table<string, unknown>|nil
---@param versionId string
---@return Errors.Error|string|nil err
local function checkIdentity(identity, versionId)
  if type(identity) ~= "table" then
    return Errors.new("INVALID_GENERATION_IDENTITY", "preparation requires a generation identity", {})
  end
  if identity.versionId ~= versionId then
    return Errors.new(
      "INVALID_GENERATION_IDENTITY",
      "generation identity version does not match the prepared version",
      { versionId = versionId }
    )
  end
  if type(identity.generationId) ~= "string" or identity.generationId == "" then
    return Errors.new("INVALID_GENERATION_IDENTITY", "generation identity carries no generation", {})
  end
  if type(identity.producerId) ~= "string" or identity.producerId == "" then
    return Errors.new("INVALID_GENERATION_IDENTITY", "generation identity carries no producer", {})
  end
  return nil
end

---@param rebuild string[]|nil
---@param parsed CacheBuilder.Requirement[]
---@param ordered string[]
---@param dev boolean|nil
---@return { kind: string, key: string, jobKey: string }[]|nil jobs
---@return Errors.Error|string|nil err
local function checkRebuild(rebuild, parsed, ordered, dev)
  if rebuild == nil or #rebuild == 0 then
    return {}
  end
  if dev ~= true then
    return nil, Errors.new("INVALID_REBUILD", "explicit rebuild requires development mode", {})
  end
  local exhaustive = false
  local required = {}
  for index, _ in ipairs(ordered) do
    local entry = parsed[index]
    if entry.scope == "complete" then
      exhaustive = true
    elseif entry.jobKey ~= nil then
      required[entry.jobKey] = true
    end
  end
  local jobs = {}
  local seenRebuild = {}
  for _, text in ipairs(rebuild) do
    local entry, err = CacheBuilder.parseRequirement(text)
    if entry == nil then
      return nil, err
    end
    if entry.scope ~= nil or entry.jobKey == nil then
      return nil, Errors.new("INVALID_REBUILD", "rebuild accepts only a canonical job: " .. text, { job = text })
    end
    local kind = assert(entry.kind, "parsed requirements are scopes or canonical jobs")
    local key = assert(entry.key, "parsed requirements are scopes or canonical jobs")
    local jobKey = assert(entry.jobKey, "parsed requirements are scopes or canonical jobs")
    if not exhaustive and not required[jobKey] then
      return nil, Errors.new("INVALID_REBUILD", "rebuild job is not in the requested scope: " .. text, { job = text })
    end
    if not seenRebuild[jobKey] then
      seenRebuild[jobKey] = true
      jobs[#jobs + 1] = { kind = kind, key = key, jobKey = jobKey }
    end
  end
  return jobs
end

---@class CacheBuilder.SessionStatus
---@field ready integer|nil
---@field queued integer|nil
---@field running integer|nil
---@field failed integer|nil
---@field failures string[]|nil
---@field enumerated integer|nil
---@field settled boolean|nil
---@field planningPending boolean|nil

---@param pool CompilerPool
---@param session InteractiveCacheBuild
---@param versionId string
---@param log fun(line: string)
---@return CacheBuilder.SessionStatus status
local function drainSession(pool, session, versionId, log)
  local rounds = 0
  local lastReady, lastFailed = -1, -1
  local function poolSummary()
    if type(pool.diagnostics) ~= "function" then
      return "pool=?"
    end
    local ok, diagnostics = pcall(pool.diagnostics, pool)
    if not ok or type(diagnostics) ~= "table" or type(diagnostics.counts) ~= "table" then
      return "pool=?"
    end
    local counts = diagnostics.counts
    local active = {}
    if type(diagnostics.activeJobKeys) == "table" then
      for index, jobKey in ipairs(diagnostics.activeJobKeys) do
        if index > 3 then
          break
        end
        active[#active + 1] = tostring(jobKey)
      end
    end
    return string.format(
      "pool q=%d run=%d prep=%d workers=%s heap=%s active=%s",
      counts.queued or 0,
      counts.running or 0,
      counts.prepared or 0,
      tostring(diagnostics.workerStates),
      tostring(diagnostics.heapStates),
      table.concat(active, ",")
    )
  end
  while true do
    rounds = rounds + 1
    assert(rounds <= 100000, "preparation did not settle")
    session:update()
    local status = session:status() --[[@as CacheBuilder.SessionStatus]]
    if type(status.settled) ~= "boolean" or type(status.planningPending) ~= "boolean" then
      error("generation session reports no settled/planningPending progress facts", 0)
    end
    local failed = #(status.failures or {})
    if (status.ready or 0) ~= lastReady or failed ~= lastFailed then
      lastReady, lastFailed = status.ready or 0, failed
      log(
        string.format(
          "build-cache: %s %d/%d jobs ready (%d failed) %s",
          versionId,
          lastReady,
          status.enumerated or lastReady,
          failed,
          poolSummary()
        )
      )
    end
    if status.settled then
      return status
    end
    -- Runnable local planning repumps at once: an idle pool never blocks
    -- deferred planning work and never earns a physical wait.
    if not status.planningPending then
      if (status.queued or 0) > 0 or (status.running or 0) > 0 then
        if type(pool.waitForProgress) == "function" then
          pool:waitForProgress()
        else
          pool:drain()
        end
      else
        error("preparation is unfinished with no runnable planning or physical work", 0)
      end
    end
  end
end

---@class CacheBuilder.VersionOptions
---@field identity table<string, unknown> immutable generation identity for the selected version
---@field requirements string[] closed requirement strings
---@field allowCompileExclusions boolean|nil accept resolved map compile failures as partial success
---@field rebuild string[]|nil canonical jobs to force in development mode
---@field dev boolean|nil development mode selector for explicit rebuilds
---@field log fun(line: string)|nil progress sink
---@field developmentRepositoryRoot string|nil worker source root for compiler threads

-- Session outcomes are the only identity and disposition authority; pool facts
-- attach exact physical failures by equality on the canonical key. Error text
-- is display-only.
---@param item table<string, unknown>
---@param allowCompileExclusions boolean|nil
---@return boolean
local function isToleratedMapExclusion(item, allowCompileExclusions)
  return allowCompileExclusions == true and item.kind == "map" and item.failureClass == "job"
end

---@param pool table<string, unknown>|nil
---@param jobKey string
---@return string|nil poolError exact physical failure before session propagation
local function exactPoolFailure(pool, jobKey)
  if type(pool) ~= "table" or type(pool.jobOutcome) ~= "function" then
    return nil
  end
  local ok, snapshot = pcall(pool.jobOutcome, pool, jobKey)
  if ok and type(snapshot) == "table" and snapshot.state == "failed" then
    if type(snapshot.error) == "string" then
      return snapshot.error
    end
    return jobKey .. ": compiler job failed"
  end
  return nil
end

---@param outcomeList table<string, unknown>
---@param pool table<string, unknown>|nil live pool for exact physical failures
---@param allowCompileExclusions boolean|nil
---@return table<string, integer> counts
---@return string[] failures
---@return string[] exclusions
local function classifyExactOutcomes(outcomeList, pool, allowCompileExclusions)
  assert(type(outcomeList) == "table", "the generation session owns an exact outcome inventory")
  local outcomes = {}
  for _, item in ipairs(outcomeList) do
    assert(type(item) == "table", "outcome rows are canonical records")
    assert(type(item.jobKey) == "string" and item.jobKey ~= "", "outcome rows carry their canonical key")
    assert(type(item.kind) == "string" and type(item.key) == "string", "outcome rows carry their canonical identity")
    assert(ArtifactState.KINDS[item.kind], "outcome rows carry a known job kind")
    assert(item.jobKey == item.kind .. ":" .. item.key, "outcome identity must match its canonical key")
    assert(
      item.state == "pending" or item.state == "successful" or item.state == "failed",
      "outcome rows carry a known state"
    )
    local state, message
    if item.state == "successful" then
      assert(item.error == nil, "successful rows carry no error")
      state = "successful"
    elseif item.state == "failed" then
      assert(type(item.error) == "string", "failed outcomes carry an error string")
      assert(type(item.failureClass) == "string", "failed rows carry their exact failure class")
      assert(item.causeJobKey == nil or type(item.causeJobKey) == "string", "causes are exact canonical keys")
      if item.failureClass == "source-exclusion" or isToleratedMapExclusion(item, allowCompileExclusions) then
        state = "excluded"
        message = item.error
      else
        state = "failed"
        message = item.error
      end
    else
      assert(item.error == nil, "pending rows carry no error")
      message = exactPoolFailure(pool, item.jobKey)
      state = message == nil and "cancelled" or "failed"
    end
    outcomes[#outcomes + 1] = { jobKey = item.jobKey, state = state, error = message }
  end
  table.sort(outcomes, function(left, right)
    return left.jobKey < right.jobKey
  end)
  local counts = { planned = 0, successful = 0, failed = 0, cancelled = 0, excluded = 0 }
  local failures, exclusions = {}, {}
  for _, outcome in ipairs(outcomes) do
    counts.planned = counts.planned + 1
    if outcome.state == "successful" then
      counts.successful = counts.successful + 1
    elseif outcome.state == "failed" then
      counts.failed = counts.failed + 1
      failures[#failures + 1] = assert(outcome.error, "failed outcomes carry their error")
    elseif outcome.state == "cancelled" then
      counts.cancelled = counts.cancelled + 1
    else
      assert(outcome.state == "excluded", "outcomes carry a classified state")
      counts.excluded = counts.excluded + 1
      exclusions[#exclusions + 1] = assert(outcome.error, "excluded outcomes carry their error")
    end
  end
  return counts, failures, exclusions
end

---@class CacheBuilder.VersionRecord
---@field versionId string
---@field identity table<string, unknown>
---@field requestedReady boolean
---@field counts table<string, integer>
---@field failures string[]
---@field exclusions string[]
---@field needsAttestation boolean
---@field isCurrent boolean
---@field cacheFs table<string, unknown>|nil pending publication access
---@field primaryError Errors.Error|string|nil handled drain failure preserved for the caller

---@param answers table<string, unknown>[] snapshot root answers in requested order
---@param versionId string
---@return Errors.Error|nil scopeError a pending requirement names itself when settlement claims otherwise
local function verifyOriginalRequirements(answers, versionId)
  -- Final requested-scope proof from the read-only snapshot: every
  -- originally requested root must answer ready. This observes retained
  -- intent without driving new work; a count-balanced census never
  -- overrides a pending requirement, and failed answers are never ready.
  -- Failed roots surface through the disposition counts downstream, so
  -- only a still-pending root fails proof here, exactly as before.
  assert(type(answers) == "table", "original-root proof consumes snapshot answers")
  for _, answer in ipairs(answers) do
    assert(type(answer) == "table" and type(answer.label) == "string", "snapshot answers name their root")
    if answer.state == "pending" then
      return Errors.new(
        "CACHE_PREPARATION_FAILED",
        "cache preparation settled while " .. answer.label .. " was still pending; no successful report is issued",
        { versionId = versionId, scope = answer.label }
      )
    end
  end
  return nil
end

-- A drain failure is a handled command interruption when it is an already
-- supported structured error or when it is exactly the fatal value the
-- borrowed pool recorded through its public diagnostics. Exact equality
-- keeps unrelated raw faults on the cleanup-and-rethrow path.
---@param pool table<string, unknown>|nil
---@param caught unknown
---@return boolean
local function recognizedDrainFailure(pool, caught)
  if Errors.is(caught) then
    return true
  end
  if pool == nil then
    return false
  end
  local ok, diagnostics = pcall(pool.diagnostics, pool)
  return ok and type(diagnostics) == "table" and diagnostics.error ~= nil and diagnostics.error == caught
end

---@param versionId string
---@param allowCompileExclusions boolean|nil
---@param developmentRepositoryRoot string|nil
---@param cacheFs table<string, unknown>
---@param identity table<string, unknown>
---@param parsed CacheBuilder.Requirement[]
---@param exhaustive boolean
---@param rebuildJobs { kind: string, key: string, jobKey: string }[]
---@param log fun(line: string)
---@return CacheBuilder.VersionRecord record
local function collectVersionFacts(
  versionId,
  allowCompileExclusions,
  developmentRepositoryRoot,
  cacheFs,
  identity,
  parsed,
  exhaustive,
  rebuildJobs,
  log
)
  local stored = cacheFs:loadLua(DerivedCacheState.path)
  local matched = exhaustive and #rebuildJobs == 0 and DerivedCacheState.matches(stored, identity)
  if matched then
    -- The trusted corpus covers only its canonical inventory, so an
    -- explicitly requested identity reuses it only as a member. A pure
    -- complete scope trusts attestation identity directly and never
    -- enumerates the published inventory.
    local uncovered = {}
    for _, requirement in ipairs(parsed) do
      if requirement.jobKey ~= nil then
        uncovered[requirement.jobKey] = true
      end
    end
    if next(uncovered) ~= nil then
      local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
      local plans = ArtifactJobs.publishedPlans(cacheFs, identity)
      if plans ~= nil then
        for _, job in ipairs(ArtifactJobs.completeJobs(plans)) do
          uncovered[job.jobKey] = nil
        end
      end
    end
    if next(uncovered) == nil then
      return {
        versionId = versionId,
        identity = identity,
        requestedReady = true,
        counts = { planned = 0, successful = 0, failed = 0, cancelled = 0, excluded = 0 },
        failures = {},
        exclusions = {},
        needsAttestation = false,
        isCurrent = true,
        cacheFs = nil,
        primaryError = nil,
      }
    end
    -- A trusted attestation survives an uncovered explicit request:
    -- the extra identity falls through to the normal session below
    -- without invalidating the attestation first.
  else
    -- Only stale or explicitly rebuilt state is removed before
    -- replacement work.
    if exhaustive or #rebuildJobs > 0 then
      DerivedCacheState.invalidate(cacheFs)
    end
  end
  for _, job in ipairs(rebuildJobs) do
    cacheFs:remove(ArtifactState.path(job.kind, job.key))
  end
  epochCounter = epochCounter + 1
  local epoch = epochCounter
  local pool = nil ---@type table<string, unknown>|nil
  local session = nil ---@type table<string, unknown>|nil
  -- Snapshot refs mirror the registered parsed refs; an exhaustive build
  -- additionally proves the mon summary its complete scope implies.
  local snapshotRefs = {}
  for _, entry in ipairs(parsed) do
    snapshotRefs[#snapshotRefs + 1] = entry
  end
  if exhaustive then
    snapshotRefs[#snapshotRefs + 1] = { kind = "mon-summary", key = "global" }
  end
  -- One owned teardown for this acquisition lifecycle: every path
  -- captures its facts first, then closes session and pool exactly once.
  local function teardown()
    if session ~= nil then
      pcall(session.retire, session)
    end
    if pool ~= nil then
      pcall(pool.shutdown, pool)
    end
  end
  local drainOk, drainResult = pcall(function()
    pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = developmentRepositoryRoot })
    session = InteractiveCacheBuild.new({
      identity = identity,
      epoch = epoch,
      pool = pool,
    })
    if exhaustive then
      session:requestComplete("required")
    end
    for _, entry in ipairs(parsed) do
      if entry.scope ~= nil and entry.scope ~= "complete" then
        local scope = assert(entry.scope, "parsed requirements are scopes or canonical jobs")
        session:requestMilestone(scope, "required")
      elseif entry.scope == "complete" then
        session:requestComplete("required")
        session:requestJob("mon-summary", "global", "required")
      else
        local kind = assert(entry.kind, "parsed requirements are scopes or canonical jobs")
        local key = assert(entry.key, "parsed requirements are scopes or canonical jobs")
        session:requestJob(kind, key, "required")
      end
    end
    return drainSession(pool, session, versionId, log)
  end)
  if not drainOk then
    local drainErr = drainResult
    if recognizedDrainFailure(pool, drainErr) then
      -- The interrupted session still owns its retained facts: capture
      -- the read-only snapshot before teardown so pending outcomes stay
      -- pending raw facts for the single policy pass below.
      local outcomeList = {}
      if session ~= nil and type(session.completionSnapshot) == "function" then
        local okSnap, snapshot = pcall(session.completionSnapshot, session, snapshotRefs)
        if okSnap and type(snapshot) == "table" and type(snapshot.outcomes) == "table" then
          outcomeList = snapshot.outcomes
        end
      end
      if #outcomeList == 0 and session ~= nil and type(session.outcomes) == "function" then
        local okOut, list = pcall(session.outcomes, session)
        if okOut and type(list) == "table" then
          outcomeList = list
        end
      end
      local counts, failures, exclusions = classifyExactOutcomes(outcomeList, pool, allowCompileExclusions)
      teardown()
      return {
        versionId = versionId,
        identity = identity,
        requestedReady = false,
        counts = counts,
        failures = failures,
        exclusions = exclusions,
        needsAttestation = false,
        isCurrent = false,
        cacheFs = nil,
        primaryError = drainErr,
      }
    end
    teardown()
    error(drainErr, 0)
  end
  assert(drainResult ~= nil, "a settled session reports its status")
  assert(session ~= nil and pool ~= nil, "a settled scope owns its pool and session")
  -- The command proves only its originally requested scope: the snapshot
  -- observes the retained answers and raw outcomes before teardown, and a
  -- pending requirement behind a settled census fails proof without
  -- inventing a job. Unknown capture faults clean up, then rethrow.
  local okSnap, snapshot = pcall(session.completionSnapshot, session, snapshotRefs)
  if not okSnap then
    teardown()
    error(snapshot, 0)
  end
  assert(
    type(snapshot) == "table" and type(snapshot.answers) == "table" and type(snapshot.outcomes) == "table",
    "the generation session owns its completion facts"
  )
  local counts, failures, exclusions = classifyExactOutcomes(snapshot.outcomes, pool, allowCompileExclusions)
  teardown()
  local scopeError = verifyOriginalRequirements(snapshot.answers, versionId)
  local requestedReady = counts.failed == 0 and counts.cancelled == 0 and counts.excluded == 0
  if scopeError ~= nil then
    requestedReady = false
  end
  local needsAttestation = exhaustive and counts.failed == 0 and counts.cancelled == 0 and counts.excluded == 0
  -- A strictly successful exhaustive session publishes its attestation
  -- directly: successful publication is the proof, so no second
  -- exhaustive audit runs on the ordinary path.
  local pendingFs = needsAttestation and cacheFs or nil
  return {
    versionId = versionId,
    identity = identity,
    requestedReady = requestedReady,
    counts = counts,
    failures = failures,
    exclusions = exclusions,
    needsAttestation = needsAttestation,
    isCurrent = false,
    cacheFs = pendingFs,
    primaryError = scopeError,
  }
end

---@param record CacheBuilder.VersionRecord
---@param complete boolean
---@return table<string, unknown> report
local function makeRecordReport(record, complete)
  return {
    requestedReady = record.requestedReady,
    complete = complete,
    exclusions = record.exclusions,
    failures = record.failures,
    counts = {
      planned = record.counts.planned,
      successful = record.counts.successful,
      failed = record.counts.failed,
      cancelled = record.counts.cancelled,
      excluded = record.counts.excluded,
    },
  }
end

local function logRecordOutcomes(record, log)
  for _, message in ipairs(record.exclusions) do
    log(string.format("build-cache: %s excluded %s", record.versionId, message))
  end
  for _, message in ipairs(record.failures) do
    log(string.format("build-cache: %s failed: %s", record.versionId, message))
  end
end

local function interpretTargetedOutcome(record, attestationPublished, publishError)
  if record.isCurrent then
    return { complete = true }
  end
  if record.primaryError ~= nil then
    return { complete = false, error = record.primaryError }
  end
  if record.counts.failed > 0 or record.counts.cancelled > 0 then
    return {
      complete = false,
      error = Errors.new(
        "CACHE_PREPARATION_FAILED",
        "cache preparation failed",
        { versionId = record.versionId, failures = record.failures }
      ),
    }
  end
  if record.needsAttestation then
    if attestationPublished then
      return { complete = true }
    end
    local failure = publishError
    if not Errors.is(failure) then
      failure = Errors.new(
        "CACHE_PREPARATION_FAILED",
        "cache preparation failed: " .. tostring(failure),
        { versionId = record.versionId }
      )
    end
    return { complete = false, error = failure }
  end
  return { complete = false }
end

---@param versionId string
---@param options CacheBuilder.VersionOptions
---@return table<string, unknown>|nil report
---@return Errors.Error|string|nil err
function CacheBuilder.prepareVersion(versionId, options)
  options = options or {}
  local log = options.log or print
  local versionErr = checkVersion(versionId)
  if versionErr ~= nil then
    return nil, versionErr
  end
  local identityErr = checkIdentity(options.identity, versionId)
  if identityErr ~= nil then
    return nil, identityErr
  end
  local ordered, parsed, requirementsErr = parseRequirements(options.requirements)
  if ordered == nil or parsed == nil then
    return nil, requirementsErr
  end
  local rebuildJobs, rebuildErr = checkRebuild(options.rebuild, parsed, ordered, options.dev)
  if rebuildJobs == nil then
    return nil, rebuildErr
  end
  local identity = options.identity
  local exhaustive = false
  for _, entry in ipairs(parsed) do
    if entry.scope == "complete" then
      exhaustive = true
    end
  end
  local cacheFs = CacheFs.forVersion(versionId)
  local collectOk, record = pcall(
    collectVersionFacts,
    versionId,
    options.allowCompileExclusions,
    options.developmentRepositoryRoot,
    cacheFs,
    identity,
    parsed,
    exhaustive,
    rebuildJobs,
    log
  )
  if not collectOk then
    error(record, 0)
  end
  assert(record ~= nil, "scoped collection returns its scalar record")
  if not record.isCurrent then
    logRecordOutcomes(record, log)
  end
  local attestationPublished = false
  local publishError = nil
  if not record.isCurrent and record.primaryError == nil and record.needsAttestation then
    local publishOk, publishErr = pcall(DerivedCacheState.publish, cacheFs, identity)
    if publishOk then
      attestationPublished = true
    else
      publishError = publishErr
    end
  end
  local outcome = interpretTargetedOutcome(record, attestationPublished, publishError)
  if outcome.error ~= nil then
    return nil, outcome.error
  end
  local report = makeRecordReport(record, outcome.complete)
  if record.isCurrent then
    log(string.format("build-cache: %s current", versionId))
  elseif attestationPublished then
    log(string.format("build-cache: %s complete (%d jobs)", versionId, record.counts.successful))
  elseif exhaustive then
    log(
      string.format(
        "build-cache: %s partial (%d jobs, %d excluded)",
        versionId,
        record.counts.successful,
        record.counts.excluded
      )
    )
  else
    log(string.format("build-cache: %s prepared (%d jobs)", versionId, record.counts.successful))
  end
  return report
end

local function versionIdentity(versionId, dev, producerFingerprint)
  local romFs, openErr = RomFs.open(versionId)
  if romFs == nil then
    assert(Errors.is(openErr), "source-data stage failure must be a structured error")
    return nil, openErr --[[@as Errors.Error]]
  end
  local metadata = romFs:metadata()
  romFs:close()
  local sha1 = metadata ~= nil and metadata.sha1 or nil
  if type(sha1) ~= "string" or #sha1 ~= 40 or sha1:find("[^0-9a-f]") ~= nil then
    return nil,
      Errors.new("INVALID_ROM_IDENTITY", "the published dump carries no validated ROM hash", { versionId = versionId })
  end
  local mode = dev == true and "development" or "release"
  local producerId
  if dev == true then
    producerId = assert(producerFingerprint, "development identity requires the working-tree digest")
  else
    producerId = "r" .. tostring(assert(DerivedCacheVersions[versionId], "release counter is required"))
  end
  local ok, identity = pcall(DerivedCacheState.current, {
    versionId = versionId,
    romSha1 = sha1,
    mode = mode,
    producerId = producerId,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  if not ok then
    if Errors.is(identity) then
      return nil, identity
    end
    error(identity, 0)
  end
  return identity
end

---@param versionIds string[]
---@param options { allowCompileExclusions?: boolean, dev?: boolean, log?: fun(line: string), developmentRepositoryRoot?: string }|nil
---@return table<string, unknown>|nil report, string|nil err
function CacheBuilder.buildVersions(versionIds, options)
  options = options or {}
  local log = options.log or print
  if #versionIds == 0 then
    log("build: no ready version to compile")
    return nil, "no ready version to compile"
  end
  local producerFingerprint
  if options.dev == true then
    local repositoryRoot =
      assert(options.developmentRepositoryRoot, "development builds require the repository root the process runs from")
    producerFingerprint = ProducerFingerprint.compute(ProducerFingerprint.checkoutBackend(repositoryRoot))
  end
  ---@type CacheBuilder.VersionRecord[]
  local records = {}
  local allOk = true
  for _, version in ipairs(versionIds) do
    local ok, result, failureErr = pcall(function()
      local cacheFs = CacheFs.forVersion(version)
      local dumpMarker = cacheFs:read(RawDumpContract.MARKER_PATH)
      assert(type(dumpMarker) == "string", "a ready version must have a published dump marker")
      local identity, identityErr = versionIdentity(version, options.dev, producerFingerprint)
      if identity == nil then
        assert(Errors.is(identityErr), "source-data stage failure must be a structured error")
        return nil, identityErr
      end
      local parsed = {
        { scope = "complete" },
      }
      local record = collectVersionFacts(
        version,
        options.allowCompileExclusions,
        options.developmentRepositoryRoot,
        cacheFs,
        identity,
        parsed,
        true,
        {},
        log
      )
      return record
    end)
    if not ok then
      if Errors.is(result) then
        allOk = false
        log("build-cache: " .. version .. " failed: " .. Errors.format(result))
      else
        error(result, 0)
      end
    elseif result == nil then
      allOk = false
      if failureErr ~= nil then
        log("build-cache: " .. version .. " failed: " .. Errors.format(failureErr))
      else
        log("build-cache: " .. version .. " failed")
      end
    else
      ---@cast result CacheBuilder.VersionRecord
      records[#records + 1] = result
      if result.isCurrent then
        log(string.format("build-cache: %s current", version))
      else
        logRecordOutcomes(result, log)
      end
      if result.primaryError ~= nil then
        allOk = false
        log("build-cache: " .. version .. " failed: " .. Errors.format(result.primaryError))
      elseif result.counts.failed > 0 or result.counts.cancelled > 0 then
        allOk = false
      elseif result.counts.excluded > 0 and not options.allowCompileExclusions then
        allOk = false
      end
    end
  end
  local exclusionCount = 0
  for _, record in ipairs(records) do
    exclusionCount = exclusionCount + record.counts.excluded
  end
  -- Collection gates pass before publication begins. A publication failure
  -- preserves earlier effects and stops later publication attempts.
  local tailFailed = not allOk
  if allOk then
    local publishFailed = false
    for _, record in ipairs(records) do
      if record.needsAttestation and not record.isCurrent then
        if not publishFailed then
          local ok, err = pcall(DerivedCacheState.publish, assert(record.cacheFs), record.identity)
          if not ok then
            publishFailed = true
            log("build-cache: " .. record.versionId .. " failed: " .. Errors.format(err))
          end
        end
      end
    end
    if publishFailed then
      tailFailed = true
    end
  end
  if tailFailed then
    if not allOk and exclusionCount > 0 and not options.allowCompileExclusions then
      log("build-cache: compile exclusions remain; rerun with --allow-compile-exclusions to accept them")
    end
    return nil, "cache preparation failed"
  end
  local complete = exclusionCount == 0
  return { published = true, complete = complete, exclusionCount = exclusionCount }
end

return CacheBuilder
