-- Exhaustive and targeted cache preparation through the common generation
-- session. buildVersions prepares every listed version with the complete
-- scope; prepareVersion prepares one version with a declared closure. Both
-- hydrate the version's recoverable snapshot into the generation, drive
-- InteractiveCacheBuild for the requested closure, and report success only
-- after the captured cut is persisted: this explicit flush is the one place
-- that waits for a snapshot, and a failed write is a nonzero preparation. A
-- targeted scope never marks a snapshot complete no matter its exit status.
-- The exhaustive audit remains an explicit manual diagnostic and never runs
-- here.

local Errors = require("libs.errors.src.Errors")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local GameVersion = require("romdump.src.source.GameVersion")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheArchive = require("romdump.src.build.CacheArchive")
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
  if kind == nil or not pcall(ArtifactState.validateKey, kind, key) then
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
---@param log fun(line: string)
---@return CacheBuilder.SessionStatus status
local function drainSession(pool, session, log)
  local rounds = 0
  local nextDotAt = 10
  local dots = 0
  while true do
    rounds = rounds + 1
    assert(rounds <= 100000, "preparation did not settle")
    session:update()
    local status = session:status() --[[@as CacheBuilder.SessionStatus]]
    if type(status.settled) ~= "boolean" or type(status.planningPending) ~= "boolean" then
      error("generation session reports no settled/planningPending progress facts", 0)
    end
    -- One dot per ten settled jobs, like the test progress dots: per-job
    -- status lines stay out of the build output. Dots accumulate and emit
    -- as one line so multi-dot preparations stay on a single line.
    while (status.ready or 0) >= nextDotAt do
      dots = dots + 1
      nextDotAt = nextDotAt + 10
    end
    if status.settled then
      if dots > 0 then
        log(string.rep(".", dots))
      end
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
---@field complete boolean the capture covers the whole generation
---@field sequence integer|nil sequence persisted by this run, nil when none was written
---@field isCurrent boolean the hydrated snapshot already answered the scope
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

-- The recoverable snapshot of one version, hydrated against the exact
-- generation it must belong to. A foreign, damaged, or absent candidate yields
-- nothing: preparation then compiles the requested scope from its source.
---@param versionId string
---@param identity table<string, unknown>
---@return CacheArchive.Hydration|nil
local function hydrateVersion(versionId, identity)
  CacheArchive.restoreBackup(versionId)
  local fileName = CacheArchive.recoverableFileName(versionId)
  if fileName == nil then
    return nil
  end
  local hydration = CacheArchive.open(versionId, identity, fileName)
  return hydration
end

---@return table<string, function> a bounded FIFO channel for the in-process writer
local function newQueue()
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
end

-- Persist one captured cut before the caller reports success. The writer runs
-- in this process with its explicit flush, so no debounce, pacing, or rate
-- limit applies and the answer is the writer's own typed outcome.
---@param cut table<string, unknown>
---@return Errors.Error|nil failure
local function persistCut(cut)
  local control = newQueue()
  local reply = newQueue()
  control:push({
    op = "snapshot",
    versionId = cut.versionId,
    generationId = cut.identity.generationId,
    epoch = 1,
    identity = cut.identity,
    sequence = cut.sequence,
    entries = cut.entries,
    artifacts = cut.artifacts,
    milestones = cut.milestones,
    firstPlay = cut.firstPlay,
    complete = cut.complete,
    flush = true,
  })
  control:push({ op = "stop" })
  local written, writeFailure = pcall(CacheArchive.run, control, reply)
  if not written then
    return Errors.new("CACHE_PREPARATION_FAILED", "the snapshot writer failed: " .. tostring(writeFailure), {
      versionId = cut.versionId,
    })
  end
  local packet = reply:pop()
  if type(packet) ~= "table" then
    return Errors.new("CACHE_PREPARATION_FAILED", "the snapshot writer answered nothing", {
      versionId = cut.versionId,
    })
  end
  if packet.op ~= "snapshot-persisted" then
    local error = packet.error
    if Errors.is(error) then
      return error
    end
    local message = type(error) == "table" and tostring(error.message) or tostring(error)
    return Errors.new("CACHE_PREPARATION_FAILED", "the snapshot was not persisted: " .. message, {
      versionId = cut.versionId,
    })
  end
  return nil
end

---@param versionId string
---@param allowCompileExclusions boolean|nil
---@param developmentRepositoryRoot string|nil
---@param hydration CacheArchive.Hydration|nil
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
  hydration,
  identity,
  parsed,
  exhaustive,
  rebuildJobs,
  log
)
  -- A complete snapshot of this exact generation answers a pure complete
  -- scope without re-proving anything. An explicitly requested job always
  -- falls through to the session, which reuses the same hydrated cut and
  -- settles the request from its committed facts.
  local current = hydration ~= nil and hydration.complete == true and exhaustive and #rebuildJobs == 0
  if current then
    local explicit = nil
    for _, requirement in ipairs(parsed) do
      if requirement.jobKey ~= nil then
        explicit = requirement
      end
    end
    if explicit == nil then
      return {
        versionId = versionId,
        identity = identity,
        requestedReady = true,
        counts = { planned = 0, successful = 0, failed = 0, cancelled = 0, excluded = 0 },
        failures = {},
        exclusions = {},
        complete = true,
        isCurrent = true,
        primaryError = nil,
      }
    end
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
  -- The pool join is observed: a failed shutdown surfaces so the caller
  -- cannot attest or clean from an unproved worker closure.
  local function teardown()
    if session ~= nil then
      pcall(session.retire, session)
    end
    if pool ~= nil then
      local shutOk, shutErr = pcall(pool.shutdown, pool)
      if not shutOk then
        return shutErr
      end
    end
    return nil
  end
  local drainOk, drainResult = pcall(function()
    pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = developmentRepositoryRoot })
    -- The hydrated cut becomes the generation's starting content: covered
    -- artifacts are reused and only genuine misses reach a worker.
    pool:selectGeneration(identity, epoch)
    if hydration ~= nil then
      pool:seedCommittedGeneration(hydration.entries, hydration.artifacts)
    end
    session = InteractiveCacheBuild.new({
      identity = identity,
      epoch = epoch,
      pool = pool,
      milestones = hydration ~= nil and hydration.milestones or nil,
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
    return drainSession(pool, session, log)
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
        complete = false,
        isCurrent = false,
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
  -- Capture the cut while the pool still owns it: the sequence advances once
  -- per preparation over whatever the hydrated snapshot already persisted,
  -- and the completion facts it carries are the ones this session can prove.
  local nextSequence = (hydration ~= nil and hydration.sequence or 0) + 1
  local complete = (hydration ~= nil and hydration.complete == true)
    or (exhaustive and counts.failed == 0 and counts.cancelled == 0 and counts.excluded == 0)
  local cut = pool:snapshotCut(identity, {
    sequence = nextSequence,
    milestones = session:milestoneFacts(),
    firstPlay = hydration ~= nil and hydration.firstPlay == true,
    complete = complete,
  })
  local shutdownError = teardown()
  local scopeError = verifyOriginalRequirements(snapshot.answers, versionId)
  local requestedReady = counts.failed == 0 and counts.cancelled == 0 and counts.excluded == 0
  if scopeError ~= nil then
    requestedReady = false
  end
  -- An unproved pool closure fails the build before it persists anything.
  if shutdownError ~= nil then
    requestedReady = false
    complete = false
    if scopeError == nil then
      scopeError = shutdownError
    end
  end
  -- The explicit flush: success means this exact sequence is on disk for the
  -- next process. A write failure keeps the resident result and fails the run.
  -- A run with tolerated exclusions still produced committed work worth
  -- reusing, so it persists an honest partial cut; a run with a real failure
  -- or a cancelled key changes nothing.
  local persistedSequence = nil
  local persistable = scopeError == nil
    and counts.failed == 0
    and counts.cancelled == 0
    and (counts.excluded == 0 or allowCompileExclusions == true)
  if persistable then
    local persistError = persistCut(cut)
    if persistError ~= nil then
      requestedReady = false
      complete = false
      if scopeError == nil then
        scopeError = persistError
      end
    else
      persistedSequence = cut.sequence
    end
  end
  return {
    versionId = versionId,
    identity = identity,
    requestedReady = requestedReady,
    counts = counts,
    failures = failures,
    exclusions = exclusions,
    complete = requestedReady and complete,
    sequence = persistedSequence,
    isCurrent = false,
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
    sequence = record.sequence,
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

local function interpretTargetedOutcome(record)
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
  return { complete = record.complete == true }
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
  local hydration = hydrateVersion(versionId, identity)
  local collectOk, record = pcall(
    collectVersionFacts,
    versionId,
    options.allowCompileExclusions,
    options.developmentRepositoryRoot,
    hydration,
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
  local outcome = interpretTargetedOutcome(record)
  if outcome.error ~= nil then
    return nil, outcome.error
  end
  local report = makeRecordReport(record, outcome.complete)
  if record.isCurrent then
    log(string.format("build-cache: %s current", versionId))
  elseif record.complete then
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

-- Batch generation identity without touching the source: the canonical
-- per-version SHA-1 from the version catalog selects the generation, and
-- the actual ROM bytes load lazily through the pool only on a genuine
-- compilation miss. A complete current cache therefore builds nothing and
-- opens nothing.
local function versionIdentity(versionId, dev, producerFingerprint)
  local info = GameVersion.VERSIONS[versionId]
  local sha1 = type(info) == "table" and info.sha1 or nil
  if type(sha1) ~= "string" or #sha1 ~= 40 or sha1:find("[^0-9a-f]") ~= nil then
    return nil,
      Errors.new("INVALID_ROM_IDENTITY", "no validated ROM identity for version " .. tostring(versionId), {
        versionId = versionId,
      })
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
        hydrateVersion(version, identity),
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
  -- Each record already persisted its own cut before it was accepted here, so
  -- a later failure never leaves this run's success unpersisted.
  if not allOk then
    if not allOk and exclusionCount > 0 and not options.allowCompileExclusions then
      log("build-cache: compile exclusions remain; rerun with --allow-compile-exclusions to accept them")
    end
    return nil, "cache preparation failed"
  end
  local complete = exclusionCount == 0
  return { published = true, complete = complete, exclusionCount = exclusionCount }
end

return CacheBuilder
