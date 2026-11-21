-- Runs fixed producer jobs inside one persistent worker VM.
-- Each job carries its explicit source version, generation, epoch, and
-- dispatch identity. The worker builds one closed dependency view per job
-- from the committed entries the controller sends, compiles that job into a
-- private in-memory artifact, and returns its immutable output entries; it
-- never opens a generated filesystem and never decides readiness. Transient
-- geometry scratch is released at map job boundaries. The VM persists across
-- jobs: large compilations never retire it.

local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local ResidentCache = require("libs.storage.src.ResidentCache")
local RomFs = require("romdump.src.source.RomFs")
local RomSource = require("romdump.src.source.RomSource")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local PngEncoder = require("romdump.src.digest.PngEncoder")

local CompilerWorker = {}

local function wallSeconds()
  local host = rawget(_G, "love")
  if host ~= nil and host.timer == nil then
    -- Worker Lua states start without love.timer preloaded; require it on
    -- demand so job timings stay wall time rather than CPU time.
    pcall(require, "love.timer")
  end
  assert(host and host.timer and type(host.timer.getTime) == "function", "worker wall clock is required")
  return host.timer.getTime()
end

---@param context table<string, unknown>
local function closeContext(context)
  ArtifactJobs.closeSessions(context)
  if context.dependencyView ~= nil then
    context.dependencyView:close()
    context.dependencyView = nil
    context.cacheFs = nil
    context.artifactFacts = nil
  end
  if context.romFs ~= nil then
    local romFs = context.romFs
    context.romFs = nil
    context.cacheFs = nil
    context.artifactFacts = nil
    context.versionId = nil
    context.generationId = nil
    -- A failed close propagates with its original failure and emits no
    -- closure acknowledgement: the controller must never mistake it for
    -- source closure authorizing an import.
    romFs:close()
  else
    context.cacheFs = nil
    context.artifactFacts = nil
    context.versionId = nil
    context.generationId = nil
  end
  context.sourcePlanMemo = nil
  context.terrainScratch = {}
  if context.fieldCellScratch ~= nil then
    context.fieldCellScratch.terrainScratch = context.terrainScratch
  end
end

-- Build the one closed dependency view this job may read: the committed
-- entries the controller declared for the job's dependency closure, committed
-- into a job-local byte store that is dropped at every terminal path. A read
-- outside that view is a graph error, never a filesystem fallback.
---@param job table<string, unknown>
---@param context table<string, unknown>
local function openDependencyView(job, context)
  assert(type(job.versionId) == "string" and job.versionId ~= "", "worker job version is required")
  assert(type(job.generationId) == "string" and job.generationId ~= "", "worker job generation is required")
  assert(type(job.epoch) == "number" and job.epoch % 1 == 0, "worker job epoch must be an integer")
  local dependencies = job.dependencies
  assert(type(dependencies) == "table", "worker job requires its declared dependencies")
  assert(type(dependencies.artifacts) == "table", "worker job requires its committed dependency facts")
  assert(type(dependencies.entries) == "table", "worker job requires its dependency entries")
  if context.dependencyView ~= nil then
    local sameGeneration = context.generationId == job.generationId
    local sameView = context.dependencyViewGeneration == job.generationId
    if sameGeneration and sameView then
      return
    end
    context.dependencyView:close()
    context.dependencyView = nil
    context.cacheFs = nil
    context.artifactFacts = nil
  end
  local owner = ResidentCache.new(job.versionId, assert(dependencies.sourceId, "dependency entries carry a source"))
  owner:commit(owner:prepare(dependencies.entries))
  context.dependencyView = owner
  context.dependencyViewGeneration = job.generationId
  context.cacheFs = CacheFs.fromStore(owner)
  context.artifactFacts = dependencies.artifacts
  context.versionId = job.versionId
  context.generationId = job.generationId
  assert(context.cacheFs, "worker context is incomplete")
end

-- Drop one job's dependency view; the shared payload Data stays alive through
-- every other owner and no consumer may mutate it.
---@param context table<string, unknown>
local function releaseDependencyView(context)
  if context.dependencyView == nil then
    return
  end
  context.dependencyView:close()
  context.dependencyView = nil
  context.dependencyViewGeneration = nil
  context.cacheFs = nil
  context.artifactFacts = nil
end

-- Ask the pool for the shared source buffer after a genuine receipt miss
-- and suspend only this job until the matching reply arrives. The request
-- names the exact worker and job waiting; a supply carries the one
-- immutable buffer by reference and an unavailable reply carries the typed
-- failure. Stale, duplicate, or mismatched replies are rejected without
-- effect and the wait continues; a close barrier is honored mid-wait and a
-- stop ends the worker loop. A borrowed view established for the selected
-- generation is reused by later jobs without asking again; it closes on the
-- exact close barrier, so the pool can prove every borrower released.
---@param job table<string, unknown> dispatched job carrying the controller identity
---@param context table<string, unknown>
---@param workerId integer
---@param inputChannel table<string, function>
---@param resultChannel table<string, function>
---@return string "supplied", "unavailable", or "stop"
---@return table<string, unknown>|nil borrowed buffer on supplied, plain typed error on unavailable
local function awaitPooledSource(job, context, workerId, inputChannel, resultChannel)
  local jobKey = assert(job.jobKey or job.key, "worker job identity is required")
  resultChannel:push({
    status = "source-needed",
    workerId = workerId,
    jobKey = jobKey,
    versionId = job.versionId,
    generationId = job.generationId,
    epoch = job.epoch,
  })
  while true do
    local message = inputChannel:demand()
    assert(type(message) == "table", "worker received an invalid control message")
    local matches = message.workerId == workerId
      and message.jobKey == jobKey
      and message.versionId == job.versionId
      and message.generationId == job.generationId
      and message.epoch == job.epoch
    if message.kind == "source-supplied" and matches then
      if type(message.romByteData) ~= "userdata" then
        error("compiler protocol failure: pooled source must travel by reference", 0)
      end
      return "supplied", message.romByteData
    elseif message.kind == "source-unavailable" and matches then
      local failure = message.error
      if type(failure) == "table" and type(failure.code) == "string" then
        return "unavailable", { code = failure.code, message = failure.message, context = failure.context }
      end
      return "unavailable", { code = "SOURCE_UNAVAILABLE", message = tostring(failure) }
    elseif message.kind == "close-context" then
      closeContext(context)
      resultChannel:push({ workerId = workerId, status = "context-closed", closeToken = message.closeToken })
    elseif message.kind == "stop" then
      return "stop"
    end
    -- Anything else (a mismatched supply, a duplicate, a stray control) is
    -- rejected without effect; only the matching reply settles this job.
  end
end

---@param context table<string, unknown>
local function releaseGeometryScratch(context)
  -- Geometry jobs retain only immutable source sessions across jobs: the
  -- transient terrain references and the geometry/GX scratch arenas reset
  -- here at the safe job boundary through the existing constructors,
  -- every alias updated, the old arenas released by worker-local
  -- collection. This initial policy favors a measurable plateau over
  -- retaining unbounded high-water arenas.
  context.terrainScratch = {}
  context.geometryArena = GxGeometryBuffer.new()
  context.gxScratch = GxDisplayList.newScratch()
  local scratch = context.fieldCellScratch
  if type(scratch) == "table" then
    scratch.geometryArena = context.geometryArena
    scratch.gxScratch = context.gxScratch
    scratch.terrainScratch = context.terrainScratch
    scratch.lastBundle = nil
    scratch.lastDescriptor = nil
    -- Animation compilers accumulate per-member hashes into every cell
    -- record they touch, so the memo must not outlive its job: the next
    -- geometry job rebuilds compilers for the cells it actually compiles.
    scratch.terrainAnimationCompilers = nil
  end
  collectgarbage("collect")
end

---@param job table<string, unknown>
---@return boolean
local function isGeometryJob(job)
  return job.kind == "map" or job.kind == "field-cell"
end

---@param job table<string, unknown>
---@param context table<string, unknown>
---@return table<string, unknown>
function CompilerWorker.execute(job, context)
  assert(type(job) == "table", "worker job must be a table")
  return ArtifactJobs.execute(job, context)
end

---@param resultChannel table<string, function>
---@param workerId integer
---@param job table<string, unknown> channel job carrying the controller identity
---@param executeJob table<string, unknown> worker job with the resolved key
---@param status string prepared, images-pending, or failed
---@param timingReason string interleaved
---@param workSeconds number wall time spent on validation and compilation
---@param failure string|table<string, unknown>|nil channel-safe cause: the pool-reported typed error,
--- a worker-caught compile or backend failure with its throw-site trace, or nothing on success paths
---@param artifactResult table<string, unknown>|nil sealed output or its pending image packet
local function pushCompletion(
  resultChannel,
  workerId,
  job,
  executeJob,
  status,
  timingReason,
  workSeconds,
  failure,
  artifactResult
)
  local packet = {
    workerId = workerId,
    dispatchId = job.dispatchId,
    epoch = job.epoch,
    generationId = job.generationId,
    versionId = job.versionId,
    kind = job.kind,
    key = executeJob.key,
    jobKey = assert(job.jobKey or job.key),
    status = status,
    compileSeconds = nil,
    stageSeconds = nil,
    workSeconds = workSeconds,
    stagedBytes = nil,
    timingReason = timingReason,
    error = failure,
  }
  if artifactResult ~= nil then
    local sealed = artifactResult.sealed
    if sealed ~= nil then
      packet.marker = sealed.marker
      packet.ownedRoots = sealed.ownedRoots
      packet.sharedPaths = sealed.sharedPaths
      packet.entries = sealed.entries
    else
      packet.marker = artifactResult.marker
      packet.ownedRoots = artifactResult.ownedRoots
      packet.sharedPaths = artifactResult.sharedPaths
      packet.entries = artifactResult.entries
      packet.images = artifactResult.images
    end
  end
  resultChannel:push(packet)
end

-- Captures the throw-site traceback for a failure caught by xpcall. Called
-- from the error handler, which runs where the failure was raised; the same
-- call anywhere else would describe the wrong frame.
-- Level 3 skips this helper and its pcall, so the trace starts at the
-- handler frame exactly like the direct debug.traceback("", 2) calls the
-- digest compilers make in their own xpcall handlers.
---@return string? traceback when the debug library can provide one
local function throwSiteTraceback()
  if type(debug) ~= "table" or type(debug.traceback) ~= "function" then
    return nil
  end
  local ok, trace = pcall(debug.traceback, "", 3)
  if ok and type(trace) == "string" and trace ~= "" then
    return trace
  end
  return nil
end

-- Failure causes cross the love thread boundary to the pool, which carries
-- plain data only: a metatabled Errors value would not survive the trip, so
-- typed failures travel as plain code/message tables and untyped throws as
-- strings. A captured throw-site traceback rides along when present. The
-- pool prefers staged manifest detail first and falls back to this cause
-- before the generic fault.
---@param failure unknown caught xpcall failure
---@param traceback string? throw-site trace captured by the handler
---@return string|table<string, unknown> channel-safe completion cause
local function completionCause(failure, traceback)
  if Errors.is(failure) then
    ---@cast failure Errors.Error
    local cause = { code = failure.code, message = failure.message, context = failure.context }
    if traceback ~= nil then
      cause.traceback = traceback
    end
    return cause
  end
  local message = tostring(failure)
  if traceback ~= nil then
    message = message .. "\n" .. traceback
  end
  return message
end

---@param workerId integer
---@param inputChannel table<string, function>
---@param resultChannel table<string, function>
function CompilerWorker.run(workerId, inputChannel, resultChannel)
  assert(type(workerId) == "number" and workerId % 1 == 0, "worker id must be an integer")
  local context = {
    workerId = workerId,
    terrainScratch = {},
    fieldCellScratch = {
      geometryArena = GxGeometryBuffer.new(),
      gxScratch = GxDisplayList.newScratch(),
    },
  }
  context.fieldCellScratch.terrainScratch = context.terrainScratch
  context.geometryArena = context.fieldCellScratch.geometryArena
  context.gxScratch = context.fieldCellScratch.gxScratch
  while true do
    local job = inputChannel:demand()
    assert(type(job) == "table", "worker received an invalid control message")
    if job.kind == "stop" then
      break
    end
    if job.kind == "close-context" then
      -- The barrier token is echoed only after the owned source context is
      -- closed. A failed close propagates with its original text and emits
      -- no acknowledgement, so the controller never mistakes it for closure.
      closeContext(context)
      resultChannel:push({ workerId = workerId, status = "context-closed", closeToken = job.closeToken })
    elseif job.kind == "encode-png" then
      -- The parent's authored output waits in its packet; this is the
      -- deferred low-priority image encode into that same private map. The
      -- owning parent seals only after every image is written, and a failure
      -- settles it as failed instead.
      openDependencyView(job, context)
      local pending = assert(job.pending, "the png continuation has no pending parent")
      local artifact = PreparedArtifact.fromPending(pending, {
        cacheFs = assert(context.cacheFs, "worker context is incomplete"),
        facts = assert(context.artifactFacts, "worker job requires its committed dependency facts"),
      })
      local sealed
      local ok, failure = xpcall(function()
        sealed = ArtifactJobs.completeDeferredImages(artifact, pending.marker, function(image)
          local rgba = assert(image.rgba, "a pending image carries its RGBA pixels")
          artifact:write(image.relativePath, PngEncoder.encode(image.width, image.height, rgba:getString()))
        end)
      end, function(err)
        return completionCause(err, throwSiteTraceback())
      end)
      if not ok then
        local abandoned, abandonError = pcall(ArtifactJobs.abandonDeferredImages, artifact, failure, nil)
        if not abandoned then
          failure = completionCause(abandonError, nil)
        end
      end
      releaseDependencyView(context)
      -- The continuation answers the parent attempt it belongs to: the
      -- completion identity is the parent's job identity, never the private
      -- encode task the pool handed over.
      local parentIdentity = {
        dispatchId = job.dispatchId,
        epoch = job.epoch,
        generationId = job.generationId,
        versionId = job.versionId,
        kind = assert(job.parentKind, "the png continuation names its parent job kind"),
        key = job.key,
        jobKey = job.jobKey,
      }
      pushCompletion(
        resultChannel,
        workerId,
        parentIdentity,
        { key = job.key },
        ok and "prepared" or "failed",
        "interleaved",
        job.workSeconds or 0,
        ok and nil or failure,
        ok and { sealed = sealed } or nil
      )
    else
      local startedAt = wallSeconds()
      openDependencyView(job, context)
      local executeJob = {
        kind = job.kind,
        key = job.key or job.jobKey,
        versionId = job.versionId,
        generationId = job.generationId,
        epoch = job.epoch,
        producerFingerprint = job.producerFingerprint,
        artifactFacts = context.artifactFacts,
        payload = job.payload,
      }
      -- The controller dispatches only uncompiled jobs: there is no local
      -- reuse decision left, so a job either compiles from the pool-owned
      -- shared source or settles with the typed source failure.
      local sourceOutcome, sourceDetail = "supplied", nil
      if context.romFs == nil then
        sourceOutcome, sourceDetail = awaitPooledSource(job, context, workerId, inputChannel, resultChannel)
        if sourceOutcome == "stop" then
          break
        end
        if sourceOutcome == "supplied" then
          local versionId = assert(job.versionId, "worker job version is required")
          local romFs, openError = RomFs.open(versionId, RomSource.fromByteData(assert(sourceDetail)))
          if not romFs then
            error(openError, 0)
          end
          context.romFs = romFs
        end
      end
      if sourceOutcome == "unavailable" then
        if isGeometryJob(executeJob) then
          releaseGeometryScratch(context)
        end
        releaseDependencyView(context)
        pushCompletion(
          resultChannel,
          workerId,
          job,
          executeJob,
          "failed",
          "interleaved",
          wallSeconds() - startedAt,
          sourceDetail
        )
        -- Fall through to the next control message without compiling.
      else
        assert(context.romFs and context.cacheFs, "worker context is incomplete")
        local compileTraceback = nil
        local ok, result = xpcall(function()
          return CompilerWorker.execute(executeJob, context)
        end, function(failure)
          compileTraceback = throwSiteTraceback()
          return failure
        end)
        local workSeconds = wallSeconds() - startedAt
        if isGeometryJob(executeJob) then
          releaseGeometryScratch(context)
        end
        if ok then
          if result.status == "images-pending" then
            pushCompletion(
              resultChannel,
              workerId,
              job,
              executeJob,
              "images-pending",
              "interleaved",
              workSeconds,
              nil,
              result
            )
          else
            releaseDependencyView(context)
            pushCompletion(
              resultChannel,
              workerId,
              job,
              executeJob,
              "prepared",
              "interleaved",
              workSeconds,
              nil,
              result
            )
          end
        else
          releaseDependencyView(context)
          pushCompletion(
            resultChannel,
            workerId,
            job,
            executeJob,
            "failed",
            "interleaved",
            workSeconds,
            completionCause(result, compileTraceback)
          )
        end
      end
    end
  end
  ArtifactJobs.closeSessions(context)
  if context.romFs ~= nil then
    local romFs = context.romFs
    context.romFs = nil
    romFs:close()
  end
end

return CompilerWorker
