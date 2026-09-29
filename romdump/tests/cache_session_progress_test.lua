-- Convergent generation-session progress: local runnable work versus named
-- external waits, FIFO fairness within urgency, exact-once submission,
-- and truthful settlement. The real session runs against the
-- real dependency, milestone and canonical inventory functions over
-- synthetic membership; the pool is a test-local epoch-conformant boundary
-- that holds and completes chosen physical jobs on demand.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local SourcePlan = require("romdump.src.build.SourcePlan")

local T = {}

local PRODUCER_ID = "d" .. string.rep("3", 64)
local SYNTHETIC_SHA1 = string.rep("a", 40)
local FIXTURE_MARKER = "fixture-ready-marker"

-- Production-conformant pool boundary: current-epoch lookup only, queued
-- promotion, no live inheritance across selections. History is an
-- append-only epoch-labeled trace and never answers lookups.
local function epochPool(workerCount)
  local pool = {
    records = {},
    order = {},
    created = {},
    calls = {},
    history = {},
    physical = {},
    selected = nil,
    retired = false,
    waitCalls = 0,
    workerCount = workerCount or 2,
    onWait = nil,
  }
  function pool:selectGeneration(identity, epoch)
    assert(type(identity) == "table", "pool generation identity is required")
    assert(type(epoch) == "number" and epoch % 1 == 0, "pool epoch must be an integer")
    local current = self.selected
    if
      current ~= nil
      and current.epoch == epoch
      and current.versionId == identity.versionId
      and current.generationId == identity.generationId
    then
      return
    end
    local archivedEpoch = current ~= nil and current.epoch or 0
    for _, jobKey in ipairs(self.order) do
      local record = self.records[jobKey]
      self.history[#self.history + 1] = {
        epoch = archivedEpoch,
        jobKey = jobKey,
        event = "archived:" .. record.state,
      }
      if record.state == "running" or record.state == "prepared" then
        self.physical[jobKey] = record.state
      end
    end
    self.records = {}
    self.order = {}
    self.selected = {
      versionId = identity.versionId,
      generationId = identity.generationId,
      epoch = epoch,
    }
    self.retired = false
  end
  function pool:retireSelection(epoch)
    local selected = self.selected
    if selected == nil or self.retired or epoch ~= selected.epoch then
      return false
    end
    self.retired = true
    for _, jobKey in ipairs(self.order) do
      local record = self.records[jobKey]
      if record.state == "queued" then
        record.state = "cancelled"
        self.history[#self.history + 1] = { epoch = selected.epoch, jobKey = jobKey, event = "retired" }
      elseif record.state == "running" or record.state == "prepared" then
        self.physical[jobKey] = record.state
      end
    end
    return true
  end
  function pool:request(job)
    assert(not self.retired, "pool selection is retired")
    local selected = assert(self.selected, "pool has no selected generation")
    assert(job.epoch == selected.epoch, "pool job epoch does not match the selected generation")
    self.calls[job.jobKey] = (self.calls[job.jobKey] or 0) + 1
    local record = self.records[job.jobKey]
    if record ~= nil then
      if record.state == "failed" then
        error(record.details and record.details.error or "compiler job failed", 0)
      end
      if record.state == "cancelled" then
        self.records[job.jobKey] = nil
      else
        if record.state == "queued" and job.priority < record.priority then
          record.priority = job.priority
        end
        return record.state, record.details
      end
    end
    record = {
      kind = job.kind,
      key = job.key,
      jobKey = job.jobKey,
      priority = job.priority,
      epoch = job.epoch,
      job = job,
      state = "queued",
      details = nil,
    }
    self.records[job.jobKey] = record
    self.order[#self.order + 1] = job.jobKey
    self.created[#self.created + 1] = { epoch = job.epoch, jobKey = job.jobKey }
    return record.state, nil
  end
  function pool:status(jobKey)
    local record = self.records[jobKey]
    if record == nil then
      return "unknown"
    end
    return record.state, record.details
  end
  function pool:retry(jobKey, priority)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    assert(record.state == "failed", "only failed compiler jobs can be retried")
    record.state = "queued"
    record.priority = priority
    record.details = nil
    return record.state
  end
  function pool:update()
    return true
  end
  function pool:waitForProgress()
    self.waitCalls = self.waitCalls + 1
    if self.onWait ~= nil then
      self.onWait(self)
    end
  end
  function pool:diagnostics()
    local counts = { queued = 0, running = 0, prepared = 0, ready = 0, failed = 0, cancelled = 0 }
    for _, record in pairs(self.records) do
      if counts[record.state] ~= nil then
        counts[record.state] = counts[record.state] + 1
      end
    end
    return { workerCount = self.workerCount, counts = counts, error = nil }
  end
  function pool:shutdown()
    return true
  end
  -- Test driver operations below: hold and complete chosen physical jobs.
  function pool:startRunning(jobKey)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    assert(record.state == "queued", "only queued jobs start running")
    record.state = "running"
  end
  function pool:complete(jobKey)
    local record = self.records[jobKey]
    assert(
      record ~= nil and (record.state == "queued" or record.state == "running"),
      "only a current job completes: " .. tostring(jobKey)
    )
    if self.physical[jobKey] ~= nil then
      error("a retired physical slot never completes as current work: " .. tostring(jobKey), 0)
    end
    record.state = "ready"
    record.details = nil
    self.physical[jobKey] = nil
  end
  function pool:fail(jobKey, message)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    record.state = "failed"
    record.details = { error = message }
  end
  function pool:releasePhysical(jobKey)
    assert(self.physical[jobKey] ~= nil, "no such physical slot: " .. tostring(jobKey))
    self.physical[jobKey] = nil
  end
  function pool:createdCount(epoch, jobKey)
    local count = 0
    for _, entry in ipairs(self.created) do
      if entry.epoch == epoch and (jobKey == nil or entry.jobKey == jobKey) then
        count = count + 1
      end
    end
    return count
  end
  return pool
end

local function withPatched(patches, fn)
  local originals = {}
  for index, patch in ipairs(patches) do
    originals[index] = patch.target[patch.name]
    patch.target[patch.name] = patch.replacement
  end
  local ok, first, second = pcall(fn)
  for index, patch in ipairs(patches) do
    patch.target[patch.name] = originals[index]
  end
  if not ok then
    error(first, 0)
  end
  return first, second
end

local function newEnv(generation, workerCount)
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local pool = epochPool(workerCount)
  return {
    generation = generation,
    identity = { versionId = "heartgold", generationId = generation, producerId = PRODUCER_ID },
    epoch = 1,
    backend = backend,
    cacheFs = cacheFs,
    pool = pool,
  }
end

local function openSession(env)
  local realForVersion = CacheFs.forVersion
  return withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", env.backend)
      end,
    },
  }, function()
    return InteractiveCacheBuild.new({
      identity = env.identity,
      epoch = env.epoch,
      pool = env.pool,
    })
  end)
end

local function pump(session, rounds)
  for _ = 1, rounds do
    session:update()
  end
end

-- Pumps until no runnable local work remains; false when the cap runs out.
-- The first update always runs: retained status lags one pump behind intent.
local function drainLocal(session, cap)
  for _ = 1, cap or 500 do
    session:update()
    if not session:status().planningPending then
      return true
    end
  end
  return not session:status().planningPending
end

local function acceptedCount(pool)
  local count = 0
  for _ in pairs(pool.calls) do
    count = count + 1
  end
  return count
end

-- Synthetic source membership through the real inventory compiler: the
-- aggregate planners answer fixed synthetic data while the real
-- SourcePlan assembly, staging and publication stay in the path.
local function cellDescriptor(matrixMemberId, index)
  return {
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

local function syntheticIndexBundle()
  return {
    index = {
      matrices = {
        { matrixMemberId = 11, cells = { cellDescriptor(11, 0), cellDescriptor(11, 1) } },
      },
    },
    indexMarker = "synthetic-index-marker",
  }
end

local function syntheticRomFs()
  return {
    metadata = function()
      return { sha1 = SYNTHETIC_SHA1 }
    end,
    version = function()
      return "heartgold"
    end,
    openNarc = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
    read = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
    resolvedNarc = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
  }
end

local function syntheticWorld()
  return {
    maps = { { id = 7 }, { id = 9 } },
    bySymbol = { MAP_SEVEN = 7, MAP_NINE = 9 },
    byId = { [7] = 1, [9] = 2 },
    analysis = {
      mapHeaderCount = 3,
      renderableCount = 2,
      excluded = { { id = 3, symbol = "MAP_NOTHING", reason = "placeholder header" } },
    },
  }
end

local function compileSynthetic(env, scriptIds)
  local calls = { world = 0, index = 0, script = 0, audio = 0, mapKeys = 0 }
  local members = {}
  for _, memberId in ipairs(scriptIds or { 4, 6 }) do
    members[#members + 1] = { memberId = memberId }
  end
  local WorldManifest = require("romdump.src.digest.map.WorldManifest")
  local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
  local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
  local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
  return withPatched({
    {
      target = WorldManifest,
      name = "compileCatalog",
      replacement = function()
        calls.world = calls.world + 1
        return syntheticWorld()
      end,
    },
    {
      target = FieldCellCompiler,
      name = "compileIndex",
      replacement = function()
        calls.index = calls.index + 1
        return syntheticIndexBundle()
      end,
    },
    {
      target = ScriptCompiler,
      name = "plan",
      replacement = function()
        calls.script = calls.script + 1
        return { members = members, generationKey = "synthetic-generation" }
      end,
    },
    {
      target = AudioCompiler,
      name = "planSource",
      replacement = function()
        calls.audio = calls.audio + 1
        return {
          plan = { index = { version = "heartgold" }, bankPlans = { { bankId = 2 }, { bankId = 5 } } },
          identity = { romSha1 = SYNTHETIC_SHA1, sdatSha1 = string.rep("d", 40), sdatFileId = 9 },
        }
      end,
    },
    -- Roster enumeration is topology only: the inventory consults the
    -- cell-key projection per loadable map and never runs full per-map
    -- content planning.
    {
      target = MapCompilePlan,
      name = "cellKeys",
      replacement = function(_, _, mapId)
        calls.mapKeys = calls.mapKeys + 1
        if mapId == 7 then
          return { "11:1", "11:0" }
        end
        return {}
      end,
    },
    {
      target = MapCompilePlan,
      name = "plan",
      replacement = function()
        error("roster enumeration must not run full per-map content planning", 0)
      end,
    },
  }, function()
    return SourcePlan.compile(syntheticRomFs(), env.identity), calls
  end)
end

local function stageSynthetic(env, scriptIds)
  local plan = compileSynthetic(env, scriptIds)
  local artifact = PreparedArtifact.new({
    cacheFs = env.cacheFs,
    generationId = env.generation,
    epoch = env.epoch,
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    stageName = "inventory-stage",
  })
  local marker = SourcePlan.stage(artifact, plan)
  Assert.equal(marker, SourcePlan.marker(env.generation), "staging returns the generation marker")
  artifact:finishSuccess({ marker = marker })
  artifact:publish({
    generationId = env.generation,
    epoch = env.epoch,
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
  })
  return plan
end

local function writeReceipt(env, kind, key)
  env.cacheFs:writeLua(ArtifactState.path(kind, key), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = env.generation,
    kind = kind,
    key = key,
    marker = FIXTURE_MARKER,
  })
end

-- Fixture-owned publication facts at the family validation boundary: jobs
-- with a staged fixture receipt validate ready without their payload
-- compilers running. Families without fixture facts use the real
-- validator. The session pump, status and outcomes are never stubbed.
local function withFixtureFacts(env, fn)
  local realValidate = ArtifactJobs.validate
  return withPatched({
    {
      target = ArtifactJobs,
      name = "validate",
      replacement = function(cacheFs, generationId, kind, key, plans, identity)
        if generationId == env.generation then
          local receipt = ArtifactState.read(cacheFs, generationId, kind, key)
          if receipt ~= nil and receipt.marker == FIXTURE_MARKER then
            return true
          end
        end
        return realValidate(cacheFs, generationId, kind, key, plans, identity)
      end,
    },
  }, fn)
end

local function publishBank(env, bankId, marker)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  env.cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = env.generation,
    kind = "message-bank",
    key = tostring(bankId),
    marker = marker,
  })
  env.cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
  env.cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
  })
end

-- Missing knowledge backed by a held worker is blocked, not runnable: the
-- scope stays pending, idle polling performs no cache IO, source planning
-- or validation, and publishing the source resumes progress.
function T.held_source_work_leaves_local_planning_idle()
  local env = newEnv("held-source-generation", 2)
  local session = openSession(env)
  local ready, failure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(ready, "the intro stays pending while its inventory is cold")
  Assert.isNil(failure, "the intro must not fail while cold")
  Assert.isTrue(drainLocal(session, 500), "locally eligible work must drain")
  local status = session:status()
  Assert.isFalse(status.planningPending, "a held worker leaves no runnable local work")
  Assert.isFalse(status.settled, "a held scope never settles")
  local reads, validations = 0, 0
  local realRead, realValidate = SourcePlan.read, ArtifactJobs.validate
  SourcePlan.read = function(...)
    reads = reads + 1
    return realRead(...)
  end
  ArtifactJobs.validate = function(...)
    validations = validations + 1
    return realValidate(...)
  end
  local callsBefore = acceptedCount(env.pool)
  local ok, err = pcall(function()
    for _ = 1, 100 do
      session:update()
    end
  end)
  SourcePlan.read, ArtifactJobs.validate = realRead, realValidate
  Assert.isTrue(ok, tostring(err))
  status = session:status()
  Assert.isFalse(status.planningPending, "repeated idle updates stay idle")
  Assert.isFalse(status.settled, "repeated idle updates never settle a held scope")
  Assert.equal(reads, 0, "idle polling performs no source reads")
  Assert.equal(validations, 0, "idle polling performs no validation")
  Assert.equal(acceptedCount(env.pool), callsBefore, "idle polling submits no duplicate work")
  local again, againFailure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(again, "an unchanged poll stays pending")
  Assert.isNil(againFailure, "an unchanged poll reports no failure")
  Assert.equal(acceptedCount(env.pool), callsBefore, "an unchanged poll registers nothing")
  stageSynthetic(env)
  env.pool:complete("source-plan:global")
  session:update()
  Assert.isTrue(session.sourceLoaded, "publishing the source adopts membership")
  local sourceReady, sourceFailure = session:requestJob("source-plan", "global", "required")
  Assert.isTrue(sourceReady, "the published source validates ready: " .. tostring(sourceFailure))
  local mapReady, mapFailure = session:requestJob("map", "7", "required")
  Assert.isFalse(mapReady, "adopted map demand stays pending while cold")
  Assert.isNil(mapFailure, "adopted map demand reports no failure")
  pump(session, 10)
  withFixtureFacts(env, function()
    writeReceipt(env, "world-catalog", "global")
    writeReceipt(env, "field-cell-index", "global")
    env.pool:complete("world-catalog:global")
    env.pool:complete("field-cell-index:global")
    pump(session, 10)
    Assert.isTrue(env.pool.calls["field-cell:11-0"] ~= nil, "adopted membership dispatches new demand")
  end)
end

-- A wide pending family cannot monopolize the pump: resumable expansion
-- gives a trailing runnable leaf its turn, held children are planned once,
-- and the pump goes idle without busy-spinning.
function T.wide_pending_family_leaves_room_for_ready_leaves()
  local env = newEnv("wide-family-generation", 2)
  local session = openSession(env)
  session:requestJob("message-summary", "global", "required")
  session:requestJob("audio-summary", "global", "required")
  pump(session, 5)
  stageSynthetic(env)
  env.pool:complete("source-plan:global")
  pump(session, 5)
  local validations = 0
  local realValidate = ArtifactJobs.validate
  ArtifactJobs.validate = function(...)
    validations = validations + 1
    return realValidate(...)
  end
  local ok, err = pcall(function()
    local ready, failure = session:requestJob("message-summary", "global", "required")
    Assert.isFalse(ready, "the wide summary stays pending while its banks are held")
    Assert.isNil(failure, "the wide summary must not fail while cold")
    -- Hundreds of required banks dwarf two 32-unit slices; the trailing
    -- leaf below still earns its submission while the parent expands.
    local leafReady, leafFailure = session:requestJob("mon-catalog", "global", "required")
    Assert.isFalse(leafReady, "the trailing leaf stays pending while held")
    Assert.isNil(leafFailure, "the trailing leaf must not fail while held")
    -- Hundreds of required banks need dozens of slices to expand; the
    -- trailing leaf still earns its submission once finite work drains.
    pump(session, 150)
    local submitted = 0
    for _ in pairs(env.pool.calls) do
      submitted = submitted + 1
    end
    Assert.isTrue(env.pool.calls["mon-catalog:global"] ~= nil, "the trailing leaf gets its turn")
    Assert.isTrue(submitted > 64, "the wide family actually spans several slices")
    Assert.isTrue(drainLocal(session, 2000), "finite held work drains to idle")
    local settled = session:status()
    Assert.isFalse(settled.planningPending, "held children do not keep the pump runnable")
    Assert.isFalse(settled.settled, "held work never settles")
    local validationsAfterDrain = validations
    pump(session, 50)
    Assert.equal(validations, validationsAfterDrain, "drained children are never revalidated")
    for jobKey, calls in pairs(env.pool.calls) do
      Assert.equal(calls, 1, "no held child is resubmitted: " .. jobKey)
    end
  end)
  ArtifactJobs.validate = realValidate
  Assert.isTrue(ok, tostring(err))
end

function T.running_promotion_forwards_urgency_without_resubmission()
  local env = newEnv("running-promotion-generation", 1)
  local session = openSession(env)
  withFixtureFacts(env, function()
    for _, kind in ipairs({ "mon-catalog", "items", "bag" }) do
      session:requestJob(kind, "global", "sweep")
    end
    pump(session, 20)
    for _, kind in ipairs({ "mon-catalog", "items", "bag" }) do
      Assert.isTrue(env.pool.calls[kind .. ":global"] ~= nil, "every leaf submits without parking: " .. kind)
    end
    for _, kind in ipairs({ "mon-catalog", "items", "bag" }) do
      writeReceipt(env, kind, "global")
    end
    env.pool:startRunning("mon-catalog:global")
    local ready, failure = session:requestJob("mon-catalog", "global", "required")
    Assert.isFalse(ready, "a running job stays pending")
    Assert.isNil(failure, "promotion reports no failure")
    pump(session, 20)
    Assert.equal(env.pool.calls["mon-catalog:global"], 1, "a running job is never resubmitted")
    env.pool:complete("mon-catalog:global")
    env.pool:complete("items:global")
    env.pool:complete("bag:global")
    pump(session, 20)
    for _, kind in ipairs({ "mon-catalog", "items", "bag" }) do
      local done, _ = session:requestJob(kind, "global", "sweep")
      Assert.isTrue(done, "every leaf settles: " .. kind)
    end
  end)
end

local function zeroCurve()
  local curve = {}
  for level = 1, 100 do
    curve[level] = 0
  end
  return curve
end
local function minimalCatalog()
  return {
    schema = "g4-mon-catalog-v3",
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
local function layoutManifest(schema, imagePath, width, height, cell)
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
local function iconPagePlan(pageId)
  return {
    pageId = pageId,
    width = 256,
    height = 128,
    cell = 32,
    combos = { { naix = 0, palette = 0, key = "icons-" .. tostring(pageId), selectors = { "K/f0" } } },
    representative = { { selector = "K/f0", x = 0, y = 0, width = 32, height = 32 } },
  }
end
local function portraitPagePlan(pageId)
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
local function stageLayout(env, catalogMarker, layoutMarker)
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  MonCacheWriter.writeCatalog(env.cacheFs, minimalCatalog(), catalogMarker)
  env.cacheFs:writeLua(ArtifactState.path("mon-catalog", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = env.generation,
    kind = "mon-catalog",
    key = "global",
    marker = catalogMarker,
  })
  MonCacheWriter.writeLayout(
    env.cacheFs,
    layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
    layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    layoutMarker,
    { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
    env.generation
  )
  env.cacheFs:writeLua(ArtifactState.path("mon-layout", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = env.generation,
    kind = "mon-layout",
    key = "global",
    marker = layoutMarker,
  })
end
local function completeQueued(env)
  local completed = 0
  local queued = {}
  for _, jobKey in ipairs(env.pool.order) do
    local record = env.pool.records[jobKey]
    if record ~= nil and record.state == "queued" then
      queued[#queued + 1] = jobKey
    end
  end
  for _, jobKey in ipairs(queued) do
    local kind, key = jobKey:match("^([^:]+):(.+)$")
    writeReceipt(env, kind, key)
    env.pool:complete(jobKey)
    completed = completed + 1
  end
  return completed
end
local function finishCorpus(env, session, cap)
  for _ = 1, cap or 5000 do
    local status = session:status()
    if status.settled then
      return true
    end
    completeQueued(env)
    session:update()
  end
  return session:status().settled
end
local function outcomeKeySet(session)
  local set = {}
  for _, outcome in ipairs(session:outcomes()) do
    set[outcome.jobKey] = true
  end
  return set
end
function T.command_takes_physical_wait_for_delayed_completion()
  local env = newEnv("command-wait-generation", 2)
  local savedPool = package.loaded["romdump.src.build.CompilerPool"]
  local savedBuilder = package.loaded["romdump.src.CacheBuilder"]
  local realForVersion = CacheFs.forVersion
  local CacheBuilder
  local ok, err = pcall(function()
    package.loaded["romdump.src.build.CompilerPool"] = {
      new = function()
        return env.pool
      end,
    }
    CacheFs.forVersion = function()
      return realForVersion("heartgold", env.backend)
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = require("romdump.src.CacheBuilder")
    env.pool.onWait = function(pool)
      if pool:status("message-bank:219") == "queued" then
        publishBank(env, 219, "command-marker")
        pool:complete("message-bank:219")
      end
    end
    local report, reportErr = CacheBuilder.prepareVersion("heartgold", {
      identity = env.identity,
      requirements = { "message-bank:219" },
      log = function() end,
    })
    Assert.isNil(reportErr, "the delayed scope must succeed")
    assert(report ~= nil, "the command returns its report")
    Assert.isTrue(report.requestedReady, "the waited scope proves ready")
    Assert.isTrue(env.pool.waitCalls >= 1, "completion arrives through a physical wait")
    Assert.equal(report.counts.successful, 1, "exactly the requested job succeeds")
    Assert.equal(report.counts.failed, 0, "nothing fails")
    local seen = {}
    for _, outcome in ipairs(report.outcomes) do
      seen[outcome.jobKey] = outcome
    end
    local bank = assert(seen["message-bank:219"], "the exact outcome carries its identity")
    Assert.equal(bank.state, "successful", "the bank outcome is successful")
    Assert.isFalse(bank.reused, "a compiled job is not reuse")
  end)
  package.loaded["romdump.src.build.CompilerPool"] = savedPool
  package.loaded["romdump.src.CacheBuilder"] = savedBuilder
  CacheFs.forVersion = realForVersion
  env.pool.onWait = nil
  Assert.isTrue(ok, tostring(err))
end

function T.retirement_drops_logical_work_without_erasing_physical_ownership()
  local env = newEnv("retirement-generation", 2)
  local session = openSession(env)
  session:requestJob("message-bank", "219", "required")
  session:requestJob("message-bank", "3", "required")
  pump(session, 10)
  Assert.isTrue(env.pool.calls["message-bank:219"] ~= nil, "the queued job submits")
  Assert.isTrue(env.pool.calls["message-bank:3"] ~= nil, "the running job submits")
  env.pool:startRunning("message-bank:3")
  session:retire()
  Assert.equal(env.pool:status("message-bank:219"), "cancelled", "queued logical work cancels")
  Assert.equal(env.pool.physical["message-bank:3"], "running", "the physical slot stays charged")
  Assert.throws(function()
    session:requestJob("message-bank", "219", "required")
  end, "generation session is retired")
  local ok = pcall(env.pool.complete, env.pool, "message-bank:219")
  Assert.isFalse(ok, "a cancelled record never completes as current work")
  env.epoch = 2
  local resumed = openSession(env)
  Assert.equal(env.pool.physical["message-bank:3"], "running", "selection keeps old physical occupancy separate")
  resumed:requestJob("message-bank", "219", "required")
  resumed:requestJob("message-bank", "3", "required")
  pump(resumed, 10)
  Assert.equal(env.pool:createdCount(2, "message-bank:219"), 1, "identical keys restart as new interest")
  Assert.equal(env.pool:createdCount(2, "message-bank:3"), 1, "identical keys restart as new interest")
  env.pool:releasePhysical("message-bank:3")
  pump(resumed, 10)
  local reready, refailure = resumed:requestJob("message-bank", "3", "required")
  Assert.isFalse(reready, "stale output never satisfies the new epoch")
  Assert.isNil(refailure, "the new epoch stays pending on its own record")
end

-- A failed required metadata owner fails its scopes with the canonical
-- cause while unrelated independent work still succeeds.
function T.metadata_failure_reaches_scopes_without_success_wait()
  local env = newEnv("metadata-failure-generation", 2)
  local session = openSession(env)
  session:requestMilestone("new-game-intro", "required")
  pump(session, 5)
  env.pool:fail("source-plan:global", "WORKER_FAILED: synthetic source failure")
  pump(session, 20)
  local ready, failure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(ready, "the scope never succeeds behind its failed owner")
  Assert.isTrue(failure ~= nil, "the scope carries its failure")
  Assert.isTrue(
    tostring(failure):find("source-plan:global", 1, true) ~= nil,
    "the failure names its canonical cause: " .. tostring(failure)
  )
  withFixtureFacts(env, function()
    writeReceipt(env, "field-font", "global")
    env.pool:complete("field-font:global")
    pump(session, 10)
    local fontReady, fontFailure = session:requestJob("field-font", "global", "required")
    Assert.isTrue(fontReady, "unrelated work still succeeds: " .. tostring(fontFailure))
  end)
  local status = session:status()
  Assert.isTrue(#status.failures >= 1, "the failure stays visible")
  Assert.isFalse(status.complete, "failure never reports successful completion")
end

function T.finite_work_stays_fair_under_varied_completion_orders()
  local leaves = { "bag", "field-camera", "field-effects", "field-emotes", "field-ui", "field-font" }
  local function reversed(list)
    local out = {}
    for index = #list, 1, -1 do
      out[#out + 1] = list[index]
    end
    return out
  end
  local runs = 0
  for _, registerOrder in ipairs({ leaves, reversed(leaves) }) do
    for _, completionOrder in ipairs({ leaves, reversed(leaves) }) do
      runs = runs + 1
      local env = newEnv("fairness-generation-" .. tostring(runs), 2)
      local session = openSession(env)
      withFixtureFacts(env, function()
        for _, kind in ipairs(registerOrder) do
          session:requestJob(kind, "global", "required")
        end
        pump(session, 30)
        for _, kind in ipairs(completionOrder) do
          local jobKey = kind .. ":global"
          if env.pool.records[jobKey] ~= nil and env.pool.records[jobKey].state == "queued" then
            writeReceipt(env, kind, "global")
            env.pool:complete(jobKey)
            pump(session, 5)
          end
        end
        Assert.isTrue(drainLocal(session, 2000), "every order drains to idle")
        local outcomes = session:outcomes()
        local readySet = {}
        for _, outcome in ipairs(outcomes) do
          if outcome.state == "successful" then
            readySet[outcome.jobKey] = true
          end
          Assert.isTrue(outcome.state ~= "failed", "no order fails finite work: " .. outcome.jobKey)
        end
        for _, kind in ipairs(leaves) do
          Assert.isTrue(readySet[kind .. ":global"], "every order covers " .. kind)
        end
        for jobKey, calls in pairs(env.pool.calls) do
          Assert.equal(calls, 1, "no order duplicates an admission: " .. jobKey)
        end
      end)
    end
  end
  Assert.equal(runs, 4, "the matrix covers both orders twice")
end

function T.exhaustive_intent_progresses_without_later_rescue()
  local env = newEnv("exhaustive-intent-generation", 4)
  local session = openSession(env)
  session:requestComplete("required")
  withFixtureFacts(env, function()
    pump(session, 10)
    Assert.isTrue(env.pool.calls["source-plan:global"] ~= nil, "discovery starts from complete intent alone")
    Assert.isFalse(session:status().settled, "an undiscovered corpus never settles")
    stageSynthetic(env)
    env.pool:complete("source-plan:global")
    pump(session, 10)
    local spins = 0
    while env.pool.calls["mon-catalog:global"] == nil and spins < 200 do
      pump(session, 5)
      spins = spins + 1
    end
    stageLayout(env, "catalog-marker", "layout-marker")
    env.pool:complete("mon-catalog:global")
    pump(session, 30)
    -- No controller reuse phase remains: the staged layout is worker
    -- proof input, so the layout admits to the pool and succeeds once
    -- the pool completion stands in for that worker decision.
    local layoutReady, layoutFailure = session:requestJob("mon-layout", "global", "required")
    Assert.isFalse(layoutReady, "the layout starts pending for worker proof")
    Assert.isNil(layoutFailure, "the layout reports no failure")
    pump(session, 10)
    Assert.isTrue(env.pool.calls["mon-layout:global"] ~= nil, "the layout submits")
    env.pool:complete("mon-layout:global")
    pump(session, 10)
    layoutReady, layoutFailure = session:requestJob("mon-layout", "global", "required")
    Assert.isTrue(layoutReady, "worker-proved layout succeeds: " .. tostring(layoutFailure))
    Assert.isTrue(finishCorpus(env, session, 8000), "enumeration finishes without a later caller rescue")
    local final = session:status()
    Assert.isTrue(final.settled, "the exhausted complete build settles")
    Assert.isFalse(final.complete, "complete success without milestones claims no completion")
  end)
end

function T.command_proof_and_recorded_fatal_behavior()
  local realForVersion = CacheFs.forVersion
  local savedPool = package.loaded["romdump.src.build.CompilerPool"]
  local savedBuilder = package.loaded["romdump.src.CacheBuilder"]
  local function withCommand(env, fn)
    package.loaded["romdump.src.build.CompilerPool"] = {
      new = function()
        return env.pool
      end,
    }
    CacheFs.forVersion = function()
      return realForVersion("heartgold", env.backend)
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    local CacheBuilder = require("romdump.src.CacheBuilder")
    local ok, first, second = pcall(fn, CacheBuilder)
    package.loaded["romdump.src.build.CompilerPool"] = savedPool
    package.loaded["romdump.src.CacheBuilder"] = savedBuilder
    CacheFs.forVersion = realForVersion
    env.pool.onWait = nil
    if not ok then
      error(first, 0)
    end
    return first, second
  end
  -- A scope held in the pool fails after the wait reports its worker error.
  do
    local env = newEnv("pending-generation", 2)
    withCommand(env, function(CacheBuilder)
      env.pool.onWait = function(pool)
        if pool.waitCalls >= 3 and pool:status("message-bank:219") == "queued" then
          pool:fail("message-bank:219", "WORKER_FAILED: synthetic held failure")
        end
      end
      local report, err = CacheBuilder.prepareVersion("heartgold", {
        identity = env.identity,
        requirements = { "message-bank:219" },
        log = function() end,
      })
      Assert.isNil(report, "a pending scope issues no success report")
      Assert.isTrue(err ~= nil, "a pending scope reports its failure")
      local Errors = require("libs.errors.src.Errors")
      Assert.isTrue(Errors.is(err), "command failures stay structured")
      Assert.isTrue(env.pool.waitCalls >= 1, "the held scope waits physically")
    end)
  end
  -- A recorded fatal keeps its exact failure evidence.
  do
    local env = newEnv("fatal-generation", 2)
    local fatal = "synthetic pool fatal"
    env.pool.diagnostics = function(self)
      return { workerCount = self.workerCount, counts = {}, error = fatal }
    end
    local realRequest = env.pool.request
    env.pool.request = function(self, job)
      if job.jobKey == "message-bank:219" then
        error(fatal, 0)
      end
      return realRequest(self, job)
    end
    withCommand(env, function(CacheBuilder)
      local report, err = CacheBuilder.prepareVersion("heartgold", {
        identity = env.identity,
        requirements = { "message-bank:219" },
        log = function() end,
      })
      Assert.isNil(report, "a fatal pool failure proves nothing")
      Assert.isTrue(err ~= nil, "the fatal failure is reported")
      Assert.isTrue(
        tostring(err):find("synthetic pool fatal", 1, true) ~= nil,
        "the recorded fatal keeps its evidence: " .. tostring(err)
      )
    end)
  end
  -- An unrelated programming fault is not a handled drain failure.
  do
    local env = newEnv("raw-generation", 2)
    local realUpdate = env.pool.update
    env.pool.update = function()
      error("unexpected boom", 0)
    end
    local ok = pcall(withCommand, env, function(CacheBuilder)
      return CacheBuilder.prepareVersion("heartgold", {
        identity = env.identity,
        requirements = { "message-bank:219" },
        log = function() end,
      })
    end)
    env.pool.update = realUpdate
    Assert.isFalse(ok, "an unrelated fault still propagates")
  end
end

-- An indirect promotion keeps a queued result validation: the child is
-- submitted at sweep urgency, its published result is observed, and the
-- requiring summary promotes it before the validation ticket is
-- consumed. The validation survives at the stronger urgency exactly
-- once with no duplicate compilation.
function T.indirect_promotion_succeeds_on_worker_proof()
  local env = newEnv("indirect-promotion-generation", 2)
  local session = openSession(env)
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local bankIds = FieldMessageCompiler.requiredBankIds()
  Assert.isTrue(#bankIds > 0, "the real inventory names message banks")
  local leafBank = tostring(bankIds[1])
  local leafKey = "message-bank:" .. leafBank
  local ready, failure = session:requestJob("source-plan", "global", "sweep")
  Assert.isFalse(ready, "the inventory starts pending")
  Assert.isNil(failure, "the inventory reports no failure")
  pump(session, 10)
  stageSynthetic(env)
  env.pool:complete("source-plan:global")
  pump(session, 10)
  Assert.isTrue(session.sourceLoaded, "the staged inventory adopts membership")
  ready, failure = session:requestJob("message-bank", leafBank, "sweep")
  Assert.isFalse(ready, "the leaf starts pending")
  Assert.isNil(failure, "the leaf reports no failure")
  pump(session, 10)
  Assert.isTrue(env.pool.calls[leafKey] ~= nil, "the leaf submits at sweep urgency")
  publishBank(env, tonumber(leafBank), "promotion-marker")
  env.pool:complete(leafKey)
  -- No update here: the requiring summary promotes the submitted child
  -- through dependency expansion instead of another child request.
  ready, failure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(ready, "the wide summary stays pending while its banks are held")
  Assert.isNil(failure, "the wide summary reports no failure")
  local validations = 0
  local realValidate = ArtifactJobs.validate
  ArtifactJobs.validate = function(cacheFs, generationId, kind, key, plans, identity)
    if kind == "message-bank" and key == leafBank then
      validations = validations + 1
    end
    return realValidate(cacheFs, generationId, kind, key, plans, identity)
  end
  local ok, err = pcall(function()
    -- No further child request here: the indirect promotion through the
    -- requiring summary must preserve the success on its own. A
    -- direct wrapper request would rescue the ticket and hide the loss.
    for _ = 1, 100 do
      session:update()
      for _, outcome in ipairs(session:outcomes()) do
        if outcome.jobKey == leafKey and outcome.state == "successful" then
          return
        end
      end
    end
    error("the promoted child never succeeded", 0)
  end)
  ArtifactJobs.validate = realValidate
  Assert.isTrue(ok, "an indirect promotion succeeds on worker proof: " .. tostring(err))
  Assert.equal(validations, 0, "ready replies carry worker proof; the controller runs no family validation")
  Assert.equal(env.pool:createdCount(1, leafKey), 1, "promotion compiles the child exactly once")
  ready, failure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(ready, "held banks keep the wide summary pending")
  Assert.isNil(failure, "the wide summary reports no failure")
end

function T.pool_retry_faults_propagate_without_replanning()
  -- A faulting retry surfaces with its identity instead of replanning.
  local env = newEnv("retry-fault-generation", 2)
  local session = openSession(env)
  session:requestJob("field-camera", "global", "required")
  pump(session, 10)
  env.pool:fail("field-camera:global", "WORKER_FAILED: synthetic camera failure")
  pump(session, 10)
  local realRetry = env.pool.retry
  env.pool.retry = function()
    error("unexpected boom: synthetic programming fault", 0)
  end
  local ok, err = pcall(function()
    withFixtureFacts(env, function()
      local repaired = session:retry("field-camera", "global", "required")
      Assert.isFalse(repaired, "the retry starts pending")
      for _ = 1, 50 do
        session:update()
      end
    end)
  end)
  env.pool.retry = realRetry
  Assert.isFalse(ok, "an unmatched retry fault propagates instead of replanning")
  Assert.isTrue(
    tostring(err):find("unexpected boom", 1, true) ~= nil,
    "the fault keeps its identity: " .. tostring(err)
  )
end

function T.standalone_mon_scopes_need_no_source_inventory()
  local env = newEnv("mon-isolation-generation", 2)
  local session = openSession(env)
  local reads, compilations = 0, 0
  local realRead, realCompile = SourcePlan.read, SourcePlan.compile
  SourcePlan.read = function()
    reads = reads + 1
    error("mon preparation must not read the source inventory", 0)
  end
  SourcePlan.compile = function()
    compilations = compilations + 1
    error("mon preparation must not compile the source inventory", 0)
  end
  local ok, err = pcall(function()
    withFixtureFacts(env, function()
      writeReceipt(env, "mon-catalog", "global")
      local ready, failure = session:requestJob("mon-catalog", "global", "required")
      Assert.isFalse(ready, "the catalog starts pending")
      Assert.isNil(failure, "the catalog reports no failure")
      pump(session, 10)
      Assert.isTrue(env.pool.calls["mon-catalog:global"] ~= nil, "the catalog submits")
      -- The staged receipt is what the worker validates: the pool
      -- completion below stands in for that worker reuse decision.
      env.pool:complete("mon-catalog:global")
      pump(session, 10)
      ready, failure = session:requestJob("mon-catalog", "global", "required")
      Assert.isTrue(ready, "worker-proved catalog succeeds: " .. tostring(failure))
      ready, failure = session:requestJob("mon-layout", "global", "required")
      Assert.isFalse(ready, "the layout starts pending")
      Assert.isNil(failure, "the layout reports no failure")
      pump(session, 10)
      Assert.isTrue(env.pool.calls["mon-layout:global"] ~= nil, "the layout submits")
      -- The staged receipt is what the worker validates: the pool
      -- completion below stands in for that worker reuse decision.
      writeReceipt(env, "mon-layout", "global")
      env.pool:complete("mon-layout:global")
      pump(session, 10)
      ready, failure = session:requestJob("mon-layout", "global", "required")
      Assert.isTrue(ready, "worker-proved layout succeeds: " .. tostring(failure))
      Assert.isNil(env.pool.calls["source-plan:global"], "the source inventory is never admitted for mon scopes")
      for jobKey in pairs(env.pool.calls) do
        Assert.isTrue(
          jobKey == "mon-layout:global" or jobKey == "mon-catalog:global",
          "only the requested closure submits: " .. jobKey
        )
      end
    end)
  end)
  SourcePlan.read, SourcePlan.compile = realRead, realCompile
  Assert.isTrue(ok, tostring(err))
  Assert.equal(reads, 0, "no source read backs mon preparation")
  Assert.equal(compilations, 0, "no source compilation backs mon preparation")
  Assert.isNil(env.pool.calls["source-plan:global"], "the source inventory is never admitted")
end

-- Isolation never weakens the real graph: a page still opens its actual
-- source dependency and the failure propagates with its cause.
function T.page_demand_still_opens_its_source_dependency()
  local env = newEnv("page-counterexample-generation", 2)
  local session = openSession(env)
  local realRead = SourcePlan.read
  SourcePlan.read = function()
    error("synthetic source inventory is unavailable", 0)
  end
  local ok, err = pcall(function()
    local ready, failure = session:requestJob("map", "7", "required")
    Assert.isFalse(ready, "map demand stays pending")
    Assert.isNil(failure, "map demand reports no failure")
    pump(session, 5)
    Assert.isTrue(env.pool.calls["source-plan:global"] ~= nil, "a map still demands its actual source")
    env.pool:fail("source-plan:global", "WORKER_FAILED: synthetic source failure")
    pump(session, 20)
    local outcomes = session:outcomes()
    local mapOutcome = nil
    for _, outcome in ipairs(outcomes) do
      if outcome.jobKey == "map:7" then
        mapOutcome = outcome
      end
    end
    assert(mapOutcome ~= nil, "map demand stays in the outcomes")
    Assert.equal(mapOutcome.state, "failed", "the map fails behind its source")
    Assert.isTrue(
      tostring(mapOutcome.error):find("source-plan:global", 1, true) ~= nil,
      "the failure names its source cause: " .. tostring(mapOutcome.error)
    )
  end)
  SourcePlan.read = realRead
  Assert.isTrue(ok, tostring(err))
end

function T.both_milestone_rosters_enroll_their_scopes()
  local env = newEnv("dual-roster-generation", 4)
  local session = openSession(env)
  local ready, failure = session:requestJob("source-plan", "global", "required")
  Assert.isFalse(ready, "the inventory starts pending")
  Assert.isNil(failure, "the inventory reports no failure")
  pump(session, 10)
  stageSynthetic(env)
  env.pool:complete("source-plan:global")
  pump(session, 10)
  Assert.isTrue(session.sourceLoaded, "the staged inventory adopts membership")
  ready, failure = session:requestJob("mon-catalog", "global", "required")
  Assert.isFalse(ready, "the catalog starts pending")
  Assert.isNil(failure, "the catalog reports no failure")
  pump(session, 10)
  Assert.isTrue(env.pool.calls["mon-catalog:global"] ~= nil, "the catalog submits")
  stageLayout(env, "dual-catalog-marker", "dual-layout-marker")
  env.pool:complete("mon-catalog:global")
  pump(session, 30)
  withFixtureFacts(env, function()
    local milestoneReady, milestoneFailure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(milestoneReady, "bootstrap starts pending")
    Assert.isNil(milestoneFailure, "bootstrap reports no failure")
    milestoneReady, milestoneFailure = session:requestMilestone("field-runtime", "required")
    Assert.isFalse(milestoneReady, "field-runtime starts pending")
    Assert.isNil(milestoneFailure, "field-runtime reports no failure")
    -- The expected union comes from the authoritative milestone
    -- membership functions over the session's adopted selections, never
    -- from a frozen member list: inventory growth must not break this.
    -- Recomputed every turn so roster refreshes observe the same
    -- selections the session enrolls.
    local function expectedUnion()
      local union = {}
      for _, job in ipairs(ArtifactJobs.bootstrapJobs()) do
        union[#union + 1] = job.kind .. ":" .. job.key
      end
      for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
        union[#union + 1] = job.kind .. ":" .. job.key
      end
      return union
    end
    for _ = 1, 8000 do
      completeQueued(env)
      session:update()
      local observed = outcomeKeySet(session)
      local covered = true
      for _, key in ipairs(expectedUnion()) do
        if observed[key] == nil then
          covered = false
          break
        end
      end
      if covered then
        break
      end
    end
    local expected = expectedUnion()
    Assert.isTrue(#expected > 0, "both scopes name a nonempty enrolled union")
    local observed = outcomeKeySet(session)
    for _, key in ipairs(expected) do
      Assert.isTrue(observed[key] ~= nil, "both scopes enroll " .. key)
    end
    for jobKey, calls in pairs(env.pool.calls) do
      Assert.equal(calls, 1, "no admission duplicates: " .. jobKey)
    end
  end)
end

-- Readiness and progress keep their distinct answers without doing new
-- work: an unenrolled scope reports pending readiness and denominatorless
-- progress, an enrolled-but-cold roster counts zero of its full denominator,
-- one proven member advances the count without certifying the scope, and
-- failures of different classes keep roster-order precedence in both views.
function T.readiness_and_progress_keep_distinct_answers_without_new_work()
  local env = newEnv("readiness-progress-generation", 4)
  local session = openSession(env)
  local ready, failure = session:requestJob("source-plan", "global", "required")
  Assert.isFalse(ready, "the inventory starts pending")
  Assert.isNil(failure, "the inventory reports no failure")
  pump(session, 10)
  stageSynthetic(env)
  env.pool:complete("source-plan:global")
  pump(session, 10)
  Assert.isTrue(session.sourceLoaded, "the staged inventory adopts membership")
  withFixtureFacts(env, function()
    -- The planning closure resolves entirely inside the adopted synthetic
    -- inventory, so its roster/count view and its enrollment/readiness
    -- facts can be told apart without inventing membership.
    local requested, requestFailure = session:requestMilestone("field-planning", "required")
    Assert.isFalse(requested, "the scope stays pending until the pump runs")
    Assert.isNil(requestFailure, "registration reports no failure")
    local early = session:milestoneStatus("field-planning")
    Assert.equal(early.state, "pending", "progress stays pending before the roster builds")
    Assert.equal(early.ready, 0, "progress counts no ready members before the roster builds")
    Assert.isNil(early.total, "progress reports no denominator before the roster builds")
    Assert.isFalse(session:status().settled, "the unenrolled scope never settles")
    Assert.isTrue(drainLocal(session), "local planning enrolls the roster")
    local members = assert(session.roster["field-planning"], "the planning roster is retained")
    Assert.equal(#members, #ArtifactJobs.fieldPlanningJobs(), "the retained roster covers the static membership")
    Assert.isTrue(#members > 1, "the planning roster names more than one member")
    local enrolled = session:milestoneStatus("field-planning")
    Assert.equal(enrolled.state, "pending", "the enrolled-but-cold scope reports pending progress")
    Assert.equal(enrolled.ready, 1, "only the adopted inventory member counts as ready")
    Assert.equal(enrolled.total, #members, "the built roster carries its denominator")
    local createdBefore = #env.pool.created
    for _ = 1, 3 do
      local polled, pollFailure = session:requestMilestone("field-planning", "required")
      Assert.isFalse(polled, "repeated polls stay pending")
      Assert.isNil(pollFailure, "repeated polls report no failure")
      session:status()
      session:milestoneStatus("field-planning")
    end
    Assert.equal(#env.pool.created, createdBefore, "observations admit no new work")
    -- One proven member advances the count without certifying the scope:
    -- the world catalog has no prerequisites, so its proof settles alone.
    writeReceipt(env, "world-catalog", "global")
    env.pool:complete("world-catalog:global")
    pump(session, 10)
    local partial = session:milestoneStatus("field-planning")
    Assert.equal(partial.state, "pending", "one proven member leaves progress pending")
    Assert.equal(partial.ready, 2, "progress counts the proven member")
    Assert.equal(partial.total, #members, "the denominator survives partial progress")
    local stillPending, stillFailure = session:requestMilestone("field-planning", "required")
    Assert.isFalse(stillPending, "one proven member never certifies the scope")
    Assert.isNil(stillFailure, "partial progress reports no failure")
  end)
  -- Two failure classes in roster order on the runtime scope: the adopted
  -- synthetic inventory carries no 750 closure, so enrollment excludes
  -- that member while a directly failed lead keeps its own class. Both
  -- views keep roster-order precedence while each entry keeps its class.
  -- A fresh session keeps terminal settlement readable: the planning scope
  -- above stays pending on purpose.
  local runtimeEnv = newEnv("readiness-progress-runtime", 4)
  local runtimeSession = openSession(runtimeEnv)
  local inventoryReady, inventoryFailure = runtimeSession:requestJob("source-plan", "global", "required")
  Assert.isFalse(inventoryReady, "the runtime inventory starts pending")
  Assert.isNil(inventoryFailure, "the runtime inventory reports no failure")
  pump(runtimeSession, 10)
  stageSynthetic(runtimeEnv)
  runtimeEnv.pool:complete("source-plan:global")
  pump(runtimeSession, 10)
  Assert.isTrue(runtimeSession.sourceLoaded, "the staged runtime inventory adopts membership")
  withFixtureFacts(runtimeEnv, function()
    local runtimeRequested, runtimeFailure = runtimeSession:requestMilestone("field-runtime", "required")
    Assert.isFalse(runtimeRequested, "the runtime scope stays pending until the pump runs")
    Assert.isNil(runtimeFailure, "registration reports no failure")
    Assert.isTrue(drainLocal(runtimeSession), "local planning enrolls the runtime roster")
    local runtimeMembers = assert(runtimeSession.roster["field-runtime"], "the runtime roster is retained")
    local firstKey = runtimeMembers[1].kind .. ":" .. runtimeMembers[1].key
    local closureEntry = assert(runtimeSession.byKey["audio-bank:750"], "the unknown closure stays retained")
    Assert.equal(closureEntry.failureClass, "source-exclusion", "the unknown closure keeps its class")
    Assert.isTrue(
      tostring(closureEntry.failure):find("no such closure", 1, true) ~= nil,
      "the unknown closure carries its cause: " .. tostring(closureEntry.failure)
    )
    runtimeEnv.pool:fail(firstKey, "synthetic lead failure")
    pump(runtimeSession, 10)
    local failedReady, failedFailure = runtimeSession:requestMilestone("field-runtime", "required")
    Assert.isFalse(failedReady, "a failed scope never answers ready")
    Assert.isTrue(
      tostring(failedFailure):find("synthetic lead failure", 1, true) ~= nil,
      "readiness carries the roster-first cause: " .. tostring(failedFailure)
    )
    local failedProgress = runtimeSession:milestoneStatus("field-runtime")
    Assert.equal(failedProgress.state, "failed", "progress reports the failure")
    Assert.isTrue(
      tostring(failedProgress.failure):find("synthetic lead failure", 1, true) ~= nil,
      "progress carries the roster-first cause: " .. tostring(failedProgress.failure)
    )
    local leadEntry = assert(runtimeSession.byKey[firstKey], "the failed lead stays retained")
    Assert.equal(leadEntry.failureClass, "job", "the direct leaf failure keeps its class")
    local failedStatus = runtimeSession:status()
    Assert.isTrue(failedStatus.settled, "the terminally failed scope settles")
    Assert.isFalse(failedStatus.complete, "a failure never attests completion")
    Assert.isTrue(failedStatus.failed >= 2, "both failure classes stay visible")
  end)
end

return { tests = T }
