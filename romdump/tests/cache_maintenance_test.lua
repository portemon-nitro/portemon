-- Complete-proof shared collection.
--
-- A version-scoped maintenance owner
-- reclaims unreachable content-addressed shared files only after every
-- canonical job proves its current receipt plus its matching shared
-- reference sidecar while no reader or worker is active. Saves, mods,
-- and unknown files are never traversed.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("romdump.src.source.GameVersion")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Schema = require("libs.script.src.Schema")
local ScriptCache = require("libs.assets.src.ScriptCache")
local Sha256 = require("libs.script.src.Sha256")

local T = {}

local HEARTGOLD_SHA1 = GameVersion.VERSIONS.heartgold.sha1
local RECEIPT_SCHEMA = "g4-derived-receipt-v1"
local function requireMaintenance()
  local ok, maintenance = pcall(require, "romdump.src.build.CacheMaintenance")
  Assert.isTrue(ok, "shared-collection owner is missing: " .. "no version-scoped maintenance collects proven orphans")
  return assert(maintenance)
end

local function requireJobs()
  local ok, jobs = pcall(require, "romdump.src.build.ArtifactJobs")
  Assert.isTrue(ok, "the canonical complete job roster is missing")
  return assert(jobs)
end

local function requireReceipts()
  local ok, receipts = pcall(require, "romdump.src.build.ArtifactState")
  Assert.isTrue(ok, "the generation-scoped receipt boundary is missing")
  return assert(receipts)
end

local function generationIdFor(producerBody)
  local identity = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "development",
    producerId = "d" .. producerBody,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  return assert(identity.generationId)
end

local function minimalPlans()
  return {
    messageBankIds = { 7 },
    audioBankIds = { 3 },
    scriptMemberIds = { 11 },
    iconPageIds = { 1 },
    portraitPageIds = { 1 },
    mapDataIds = { 9 },
    mapIds = { 3 },
    indexBundle = { index = { matrices = { { cells = { { matrixMemberId = 5, index = 2 } } } } } },
  }
end

local function drainRoster(jobs, plans)
  local roster = {}
  local iterate = jobs.completeIterator(plans)
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    roster[#roster + 1] = job
  end
  Assert.isTrue(#roster > 10, "the synthetic roster must span several job families")
  return roster
end

local function publishReceipt(cache, generation, kind, key, marker)
  cache:writeLua(requireReceipts().path(kind, key), {
    schema = RECEIPT_SCHEMA,
    generationId = generation,
    kind = kind,
    key = key,
    marker = marker or "complete",
  })
end

local function sidecarPath(kind, key)
  return "data/generated/jobs-shared/" .. kind .. "/" .. key .. ".lua"
end

local function publishSidecar(cache, generation, kind, key, paths)
  local sorted = {}
  for _, path in ipairs(paths or {}) do
    sorted[#sorted + 1] = path
  end
  table.sort(sorted)
  cache:writeLua(sidecarPath(kind, key), {
    schema = 1,
    generationId = generation,
    kind = kind,
    key = key,
    paths = sorted,
  })
end

local function setupCompleteSharedCache(generation)
  local jobs = requireJobs()
  local plans = minimalPlans()
  local roster = drainRoster(jobs, plans)
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:recoverPublication()
  local meshRef = MapAssetCache.geometryPath(string.rep("a", 40))
  local sampleRef = AudioCache.samplePath("bank003_kick")
  local meshOrphan = MapAssetCache.geometryPath(string.rep("b", 40))
  local metaOrphan = AudioCache.sampleMetadataPath("bank009_stale")
  local unknownPath = "data/generated/audio/custom-note.txt"
  local byKey = {}
  for _, job in ipairs(roster) do
    byKey[job.kind .. ":" .. job.key] = job
    publishReceipt(cache, generation, job.kind, job.key, "complete")
    publishSidecar(cache, generation, job.kind, job.key, {})
  end
  Assert.notNil(byKey["map:3"], "the synthetic roster must contain a map job")
  Assert.notNil(byKey["audio-bank:3"], "the synthetic roster must contain an audio job")
  Assert.notNil(byKey["map-data:9"], "the synthetic roster must contain a map-data job")
  publishSidecar(cache, generation, "map", "3", { meshRef })
  publishSidecar(cache, generation, "map-data", "9", { meshRef })
  publishSidecar(cache, generation, "audio-bank", "3", { sampleRef })
  cache:write(meshRef, string.rep("mesh-block;", 200))
  cache:write(sampleRef, string.rep("pcm-frame;", 200))
  cache:write(meshOrphan, string.rep("orphan-mesh;", 200))
  cache:write(metaOrphan, "return { stale = true }\n")
  cache:write(unknownPath, "operator note")
  return {
    backend = backend,
    cache = cache,
    plans = plans,
    meshRef = meshRef,
    sampleRef = sampleRef,
    meshOrphan = meshOrphan,
    metaOrphan = metaOrphan,
    unknownPath = unknownPath,
  }
end

function T.complete_quiet_generation_collects_only_proven_orphans()
  local maintenance = requireMaintenance()
  local generation = generationIdFor(Sha256.hex("shared collection producer"))
  local setup = setupCompleteSharedCache(generation)

  local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)

  Assert.equal(result.status, "collected", "a proven complete quiet generation reclaims: " .. tostring(result.reason))
  Assert.equal(result.removedCount, 2, "exactly the unreferenced shared files are removed")
  Assert.isFalse(setup.cache:exists(setup.meshOrphan), "the orphan mesh is reclaimed")
  Assert.isFalse(setup.cache:exists(setup.metaOrphan), "the orphan sample metadata is reclaimed")
  Assert.equal(setup.cache:read(setup.meshRef), string.rep("mesh-block;", 200))
  Assert.equal(setup.cache:read(setup.sampleRef), string.rep("pcm-frame;", 200))
  Assert.equal(setup.cache:read(setup.unknownPath), "operator note", "unknown files are preserved, not scavenged")
end

function T.collection_skips_entirely_without_complete_sidecar_proof()
  local maintenance = requireMaintenance()
  local generation = generationIdFor(Sha256.hex("missing proof producer"))
  local setup = setupCompleteSharedCache(generation)
  setup.cache:remove(sidecarPath("map", "3"))

  local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)

  Assert.equal(result.status, "skipped", "a missing shared proof forbids every delete")
  Assert.notNil(result.reason, "the skip must name the failed proof")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "no partial collection runs on uncertain proof")
  Assert.isTrue(setup.cache:exists(setup.metaOrphan), "no partial collection runs on uncertain proof")
  Assert.equal(setup.cache:read(setup.meshRef), string.rep("mesh-block;", 200))
end

function T.collection_skips_entirely_while_readers_or_workers_are_active()
  local maintenance = requireMaintenance()
  local generation = generationIdFor(Sha256.hex("busy collection producer"))
  local setup = setupCompleteSharedCache(generation)

  local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, false)

  Assert.equal(result.status, "skipped", "an active generation never loses shared files under its readers")
  Assert.notNil(result.reason, "the skip must name the busy condition")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "a busy pass deletes nothing")
  Assert.isTrue(setup.cache:exists(setup.metaOrphan), "a busy pass deletes nothing")
end

function T.collection_skips_entirely_when_a_sidecar_generation_is_stale()
  local maintenance = requireMaintenance()
  local generation = generationIdFor(Sha256.hex("stale proof producer"))
  local setup = setupCompleteSharedCache(generation)
  local staleGeneration = generationIdFor(Sha256.hex("previous producer tree"))
  publishSidecar(setup.cache, staleGeneration, "map", "3", { setup.meshRef })

  local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)

  Assert.equal(result.status, "skipped", "a stale shared proof forbids every delete")
  Assert.notNil(result.reason, "the skip must name the failed proof")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "no partial collection runs on a stale proof")
  Assert.isTrue(setup.cache:exists(setup.metaOrphan), "no partial collection runs on a stale proof")
  Assert.equal(setup.cache:read(setup.meshRef), string.rep("mesh-block;", 200))
end

function T.collection_skips_entirely_when_a_sidecar_names_an_unknown_root()
  local maintenance = requireMaintenance()
  local generation = generationIdFor(Sha256.hex("unknown root producer"))
  local setup = setupCompleteSharedCache(generation)
  publishSidecar(setup.cache, generation, "map", "3", { "data/generated/elsewhere/mystery.g4mesh" })

  local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)

  Assert.equal(result.status, "skipped", "a reference outside the known shared roots forbids every delete")
  Assert.notNil(result.reason, "the skip must name the failed proof")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "no partial collection runs on an unexpected root")
  Assert.isTrue(setup.cache:exists(setup.metaOrphan), "no partial collection runs on an unexpected root")
end

function T.collection_skips_entirely_when_a_sidecar_table_is_malformed()
  local maintenance = requireMaintenance()
  for _, scenario in ipairs({ "padded", "unshaped" }) do
    local generation = generationIdFor(Sha256.hex("malformed proof producer " .. scenario))
    local setup = setupCompleteSharedCache(generation)
    if scenario == "padded" then
      setup.cache:writeLua(sidecarPath("map", "3"), {
        schema = 1,
        generationId = generation,
        kind = "map",
        key = "3",
        paths = { setup.meshRef },
        extra = "unowned",
      })
    else
      setup.cache:writeLua(sidecarPath("map", "3"), {
        schema = 1,
        generationId = generation,
        kind = "map",
        key = "3",
        paths = setup.meshRef,
      })
    end

    local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)

    Assert.equal(result.status, "skipped", "a malformed shared proof forbids every delete: " .. scenario)
    Assert.notNil(result.reason, "the skip must name the failed proof")
    Assert.isTrue(setup.cache:exists(setup.meshOrphan), "no partial collection runs on a malformed proof")
    Assert.isTrue(setup.cache:exists(setup.metaOrphan), "no partial collection runs on a malformed proof")
  end
end

function T.collection_skips_entirely_when_one_sidecar_repeats_a_path()
  local maintenance = requireMaintenance()
  local generation = generationIdFor(Sha256.hex("repeated path producer"))
  local setup = setupCompleteSharedCache(generation)
  publishSidecar(setup.cache, generation, "map", "3", { setup.meshRef, setup.meshRef })

  local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)

  Assert.equal(result.status, "skipped", "a duplicated shared reference forbids every delete")
  Assert.notNil(result.reason, "the skip must name the failed proof")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "no partial collection runs on a duplicated proof")
  Assert.isTrue(setup.cache:exists(setup.metaOrphan), "no partial collection runs on a duplicated proof")
end

function T.collection_skips_entirely_when_one_roster_receipt_is_missing()
  local maintenance = requireMaintenance()
  local generation = generationIdFor(Sha256.hex("partial sweep producer"))
  local setup = setupCompleteSharedCache(generation)
  setup.cache:remove(requireReceipts().path("audio-bank", "3"))

  local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)

  Assert.equal(result.status, "skipped", "a partial sweep forbids every delete")
  Assert.notNil(result.reason, "the skip must name the failed proof")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "no partial collection runs on a partial sweep")
  Assert.isTrue(setup.cache:exists(setup.metaOrphan), "no partial collection runs on a partial sweep")
  Assert.equal(setup.cache:read(setup.sampleRef), string.rep("pcm-frame;", 200))
end

function T.collection_delete_fault_fails_without_harming_referenced_files()
  local maintenance = requireMaintenance()
  local generation = generationIdFor(Sha256.hex("delete fault producer"))
  local setup = setupCompleteSharedCache(generation)
  local fullOrphan = "heartgold/" .. setup.meshOrphan
  local originalRemove = setup.backend.remove
  setup.backend.remove = function(self, path)
    if path == fullOrphan then
      return false, "injected collection delete failure"
    end
    return originalRemove(self, path)
  end
  local fault = Assert.throws(function()
    maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)
  end)
  Assert.notNil(fault, "a backend delete fault must surface instead of reporting a done collection")
  setup.backend.remove = originalRemove
  Assert.equal(setup.cache:read(setup.meshRef), string.rep("mesh-block;", 200))
  Assert.equal(setup.cache:read(setup.sampleRef), string.rep("pcm-frame;", 200))
  Assert.equal(setup.cache:read(setup.unknownPath), "operator note")

  local result = maintenance.collectShared(setup.cache, { generationId = generation }, setup.plans, true)
  Assert.equal(result.status, "collected", "the retry converges after the fault clears")
  Assert.equal(result.removedCount, 2, "the retry still reclaims exactly the proven orphans")
end

-- Current-generation orchestration: one proven shared-plus-script pass with
-- a disposable per-generation memo. The memo never proves completeness and
-- never authorizes deletion by itself; every destructive step stays gated on
-- its own full proof, and faults surface without a memo for a later retry.

local SCRIPT_GENERATION = string.rep("a", 40)
local SCRIPT_OBSOLETE = string.rep("b", 40)
local SCRIPT_MARKER = "script-format:marker-current"

local function requireCollector()
  local maintenance = requireMaintenance()
  Assert.isTrue(
    type(maintenance.collectCurrentGeneration) == "function",
    "the current-generation cleanup orchestration is missing: "
      .. "no single helper proves and memoizes the shared-plus-script pass"
  )
  Assert.equal(
    maintenance.RETENTION_MARKER,
    "data/generated/retention.lua",
    "the cleanup memo lives at its disposable generated path"
  )
  Assert.equal(maintenance.RETENTION_SCHEMA, 1, "the cleanup memo carries its exact schema")
  return maintenance
end

local function selectionIdentity(producerId)
  return DerivedCacheState.currentForSelection({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    producerId = producerId,
  })
end

local function publishScriptSelection(cache)
  cache:write(ScriptCache.markerPath(), SCRIPT_MARKER)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
  })
  cache:writeLua(ScriptCache.generationIndexPath(SCRIPT_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
  })
  cache:write(ScriptCache.generationMarkerPath(SCRIPT_GENERATION), SCRIPT_MARKER)
  cache:write(ScriptCache.generationDir(SCRIPT_GENERATION) .. "/sentinel", "active payload")
  cache:write(ScriptCache.generationDir(SCRIPT_OBSOLETE) .. "/stale", "superseded payload")
end

local function setupProvenGeneration(producerId)
  local identity = selectionIdentity(producerId)
  local generation = assert(identity.generationId, "selection carries its generation token")
  local setup = setupCompleteSharedCache(generation)
  DerivedCacheState.publish(setup.cache, identity)
  publishScriptSelection(setup.cache)
  setup.identity = identity
  setup.generation = generation
  return setup
end

-- The inventoried source membership is synthetic here, mirroring the
-- controller acceptance coverage: the roster owner answers the fixed
-- synthetic plans while every receipt, sidecar, and deleted byte stays on
-- the real versioned filesystem.
local function withRoster(plans, fn)
  local jobs = requireJobs()
  local real = jobs.publishedPlans
  jobs.publishedPlans = function()
    return plans
  end
  local ok, result = pcall(fn)
  jobs.publishedPlans = real
  if not ok then
    error(result, 0)
  end
  return result
end

local function collectProven(maintenance, setup, quiescent)
  return withRoster(setup.plans, function()
    return maintenance.collectCurrentGeneration(setup.cache, setup.identity, quiescent)
  end)
end

function T.current_generation_cleanup_collects_both_passes_and_memoizes()
  local maintenance = requireCollector()
  local setup = setupProvenGeneration("r5")

  local result = collectProven(maintenance, setup, true)

  Assert.equal(result.status, "collected", "a proven quiet generation cleans: " .. tostring(result.reason))
  Assert.equal(result.removedCount, 2, "exactly the unreferenced shared files are removed")
  Assert.isFalse(setup.cache:exists(setup.meshOrphan), "the orphan mesh is reclaimed")
  Assert.isFalse(setup.cache:exists(setup.metaOrphan), "the orphan sample metadata is reclaimed")
  Assert.equal(setup.cache:read(setup.meshRef), string.rep("mesh-block;", 200))
  Assert.isFalse(
    setup.cache:exists(ScriptCache.generationDir(SCRIPT_OBSOLETE) .. "/stale"),
    "the obsolete script tree retires"
  )
  Assert.equal(
    setup.cache:read(ScriptCache.generationDir(SCRIPT_GENERATION) .. "/sentinel"),
    "active payload",
    "the active script tree stays readable"
  )
  Assert.deepEqual(
    setup.cache:loadLua(maintenance.RETENTION_MARKER),
    { schema = 1, generationId = setup.generation },
    "success persists the exact memo shape"
  )

  local listings = 0
  local realItems = setup.backend.getDirectoryItems
  setup.backend.getDirectoryItems = function(self, path)
    listings = listings + 1
    return realItems(self, path)
  end
  local second = collectProven(maintenance, setup, true)
  setup.backend.getDirectoryItems = realItems
  Assert.equal(second.status, "already-collected", "the memo suppresses repeat proof work")
  Assert.equal(listings, 0, "a memoized pass performs no directory scans")
end

function T.current_generation_cleanup_memo_never_proves_an_incomplete_cache()
  local maintenance = requireCollector()
  local setup = setupProvenGeneration("r5")
  setup.cache:remove(DerivedCacheState.path)
  setup.cache:writeLua(maintenance.RETENTION_MARKER, { schema = 1, generationId = setup.generation })

  local missing = collectProven(maintenance, setup, true)

  Assert.equal(missing.status, "skipped", "the exact memo alone authorizes no deletion")
  Assert.notNil(missing.reason, "the skip must name the missing attestation")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "no deletion runs on memo alone")
  Assert.isTrue(
    setup.cache:exists(ScriptCache.generationDir(SCRIPT_OBSOLETE) .. "/stale"),
    "no script retirement runs on memo alone"
  )

  local foreign = setupProvenGeneration("r5")
  DerivedCacheState.publish(foreign.cache, selectionIdentity("r7"))
  foreign.cache:writeLua(maintenance.RETENTION_MARKER, { schema = 1, generationId = foreign.generation })

  local stale = withRoster(foreign.plans, function()
    return maintenance.collectCurrentGeneration(foreign.cache, foreign.identity, true)
  end)

  Assert.equal(stale.status, "skipped", "a foreign attestation with a matching memo still proves nothing")
  Assert.isTrue(foreign.cache:exists(foreign.meshOrphan), "no deletion runs under a foreign attestation")
  Assert.isTrue(
    foreign.cache:exists(ScriptCache.generationDir(SCRIPT_OBSOLETE) .. "/stale"),
    "no script retirement runs under a foreign attestation"
  )
end

function T.current_generation_cleanup_malformed_memo_authorizes_a_new_attempt()
  local maintenance = requireCollector()
  for _, shape in ipairs({ "missing-field", "wrong-schema", "padded", "wrong-type", "foreign" }) do
    local setup = setupProvenGeneration("r5")
    if shape == "missing-field" then
      setup.cache:writeLua(maintenance.RETENTION_MARKER, { schema = 1 })
    elseif shape == "wrong-schema" then
      setup.cache:writeLua(maintenance.RETENTION_MARKER, { schema = 2, generationId = setup.generation })
    elseif shape == "padded" then
      setup.cache:writeLua(
        maintenance.RETENTION_MARKER,
        { schema = 1, generationId = setup.generation, extra = "unowned" }
      )
    elseif shape == "wrong-type" then
      setup.cache:writeLua(maintenance.RETENTION_MARKER, { schema = 1, generationId = 7 })
    else
      setup.cache:writeLua(
        maintenance.RETENTION_MARKER,
        { schema = 1, generationId = "g4:heartgold:previous-producer" }
      )
    end

    local result = collectProven(maintenance, setup, true)

    Assert.equal(
      result.status,
      "collected",
      "a malformed memo authorizes a new attempt, never deletion by itself: " .. shape
    )
    Assert.isFalse(setup.cache:exists(setup.meshOrphan), "the fresh attempt still proves its deletions: " .. shape)
    Assert.deepEqual(
      setup.cache:loadLua(maintenance.RETENTION_MARKER),
      { schema = 1, generationId = setup.generation },
      "the retry persists the exact memo shape: " .. shape
    )
  end
end

function T.current_generation_cleanup_write_fault_leaves_no_memo()
  local maintenance = requireCollector()
  local setup = setupProvenGeneration("r5")
  local realWriteLua = setup.cache.writeLua
  setup.cache.writeLua = function()
    error("injected memo write failure", 0)
  end
  local fault = Assert.throws(function()
    collectProven(maintenance, setup, true)
  end, "a memo write fault must surface instead of reporting a done pass")
  Assert.notNil(fault, "the fault must be observable")
  setup.cache.writeLua = realWriteLua
  Assert.isNil(setup.cache:loadLua(maintenance.RETENTION_MARKER), "a failed memo write leaves no memo")

  local result = collectProven(maintenance, setup, true)
  Assert.equal(result.status, "collected", "the retry converges once the fault clears")
  Assert.deepEqual(setup.cache:loadLua(maintenance.RETENTION_MARKER), { schema = 1, generationId = setup.generation })
end

function T.current_generation_cleanup_requires_quiescence_identity_and_capability()
  local maintenance = requireCollector()
  local setup = setupProvenGeneration("r5")

  local busy = collectProven(maintenance, setup, false)
  Assert.equal(busy.status, "skipped", "an active generation never loses files under its readers")
  Assert.notNil(busy.reason, "the skip must name the busy condition")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "a busy pass deletes nothing")
  Assert.isNil(setup.cache:loadLua(maintenance.RETENTION_MARKER), "a busy pass leaves no memo")

  local foreign = selectionIdentity("r5")
  foreign.versionId = "soulsilver"
  local mismatch = maintenance.collectCurrentGeneration(setup.cache, foreign, true)
  Assert.equal(mismatch.status, "skipped", "another version's identity proves nothing here")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "a version mismatch deletes nothing")

  local bare = maintenance.collectCurrentGeneration(setup.cache, {}, true)
  Assert.equal(bare.status, "skipped", "an incomplete identity proves nothing")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "an incomplete identity deletes nothing")

  local narrow = maintenance.collectCurrentGeneration({ versionId = "heartgold" }, setup.identity, true)
  Assert.equal(narrow.status, "skipped", "a backend without the maintenance capability skips")
end

function T.current_generation_cleanup_stale_script_proof_skips_scripts_without_memo()
  local maintenance = requireCollector()
  local setup = setupProvenGeneration("r5")
  setup.cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = "script-format:stale-marker",
  })

  local result = collectProven(maintenance, setup, true)

  Assert.equal(result.status, "skipped", "a stale active selector forbids overall success")
  Assert.notNil(result.reason, "the skip must name the failed script proof")
  Assert.isFalse(setup.cache:exists(setup.meshOrphan), "the proved shared pass still collects")
  Assert.isTrue(
    setup.cache:exists(ScriptCache.generationDir(SCRIPT_OBSOLETE) .. "/stale"),
    "a stale active selector retires no tree"
  )
  Assert.isNil(setup.cache:loadLua(maintenance.RETENTION_MARKER), "uncertain script proof leaves no memo")

  local unstamped = setupProvenGeneration("r5")
  publishReceipt(unstamped.cache, "g4:heartgold:previous-producer", "script-summary", "global")

  local stale = collectProven(maintenance, unstamped, true)

  Assert.equal(stale.status, "skipped", "a stale script-summary receipt forbids overall success")
  Assert.notNil(stale.reason, "the skip must name the failed proof")
  Assert.isTrue(unstamped.cache:exists(unstamped.meshOrphan), "a stale summary receipt deletes no shared file")
  Assert.isTrue(
    unstamped.cache:exists(ScriptCache.generationDir(SCRIPT_OBSOLETE) .. "/stale"),
    "a stale summary receipt retires no tree"
  )
  Assert.isNil(unstamped.cache:loadLua(maintenance.RETENTION_MARKER), "a stale summary leaves no memo")
end

function T.current_generation_cleanup_partial_roster_skips_shared_but_retires_scripts()
  local maintenance = requireCollector()
  local setup = setupProvenGeneration("r5")
  setup.cache:remove(requireReceipts().path("audio-bank", "3"))

  local result = collectProven(maintenance, setup, true)

  Assert.equal(result.status, "skipped", "a partial roster forbids overall success")
  Assert.notNil(result.reason, "the skip must name the failed shared proof")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "missing shared proof deletes no shared file")
  Assert.isTrue(setup.cache:exists(setup.metaOrphan), "missing shared proof deletes no shared file")
  Assert.isFalse(
    setup.cache:exists(ScriptCache.generationDir(SCRIPT_OBSOLETE) .. "/stale"),
    "independent script proof still retires the obsolete tree"
  )
  Assert.isNil(setup.cache:loadLua(maintenance.RETENTION_MARKER), "a partial pass leaves no memo")
end

function T.current_generation_cleanup_unknown_sidecar_root_skips_shared_pass()
  local maintenance = requireCollector()
  local setup = setupProvenGeneration("r5")
  publishSidecar(setup.cache, setup.generation, "map", "3", { "data/generated/elsewhere/mystery.g4mesh" })

  local result = collectProven(maintenance, setup, true)

  Assert.equal(result.status, "skipped", "an unexpected shared root forbids overall success")
  Assert.notNil(result.reason, "the skip must name the failed shared proof")
  Assert.isTrue(setup.cache:exists(setup.meshOrphan), "no partial collection runs on an unexpected root")
  Assert.isTrue(setup.cache:exists(setup.metaOrphan), "no partial collection runs on an unexpected root")
  Assert.isNil(setup.cache:loadLua(maintenance.RETENTION_MARKER), "an unproved pass leaves no memo")
end

return { tests = T }
