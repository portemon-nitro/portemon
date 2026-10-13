-- One-time legacy migration and complete-proof shared collection.
--
-- A version-scoped maintenance owner converts already-digested generated
-- bytes to their canonical compact physical form without recompiling,
-- removes the superseded extracted source dump only when the remaining
-- cache stays usable or a matching original source is verified, and
-- reclaims unreachable content-addressed shared files only after every
-- canonical job proves its current receipt plus its matching shared
-- reference sidecar while no reader or worker is active. Saves, mods,
-- and unknown files are never traversed.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local CacheEnvelope = require("tests.support.CacheEnvelope")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("romdump.src.source.GameVersion")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Schema = require("libs.script.src.Schema")
local Sha256 = require("libs.script.src.Sha256")

local T = {}

local HEARTGOLD_SHA1 = GameVersion.VERSIONS.heartgold.sha1
local RECEIPT_SCHEMA = "g4-derived-receipt-v1"
local MIGRATION_MARKER = "data/generated/storage-migrated.lua"

local LEGACY_DUMP_PATHS = {
  "romfs/a/0/0/2",
  "system/menu.bin",
  "data/generated/rom_metadata.lua",
  "data/generated/romfs_index.lua",
  "data/generated/overlay_index.lua",
  "rom-dump.complete",
}

local function requireMaintenance()
  local ok, maintenance = pcall(require, "romdump.src.build.CacheMaintenance")
  Assert.isTrue(
    ok,
    "legacy derived-cache migration and shared-collection owner is missing: "
      .. "no version-scoped maintenance converts old bytes, gates dump removal, or collects proven orphans"
  )
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

local function seedLegacyDump(cache)
  for _, path in ipairs(LEGACY_DUMP_PATHS) do
    cache:write(path, "legacy-bytes for " .. path)
  end
end

local function assertLegacyDumpGone(cache)
  for _, path in ipairs(LEGACY_DUMP_PATHS) do
    Assert.isFalse(cache:exists(path), "the legacy source dump must be gone: " .. path)
  end
end

local function assertLegacyDumpKept(cache)
  for _, path in ipairs(LEGACY_DUMP_PATHS) do
    Assert.isTrue(cache:exists(path), "the last usable source must be retained: " .. path)
  end
end

local function compressibleLua()
  return "return { payload = '" .. string.rep("map-block;", 120) .. "' }\n"
end

function T.complete_cache_migrates_without_source_and_drops_the_legacy_dump()
  local maintenance = requireMaintenance()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:recoverPublication()
  local generation = generationIdFor(Sha256.hex("complete migration producer"))
  local luaLogical = compressibleLua()
  local pcmLogical = string.rep("pcm-frame;", 300)
  local meshLogical = string.rep("mesh-block;", 300)
  local pngBytes = "\137PNG\r\n\26\n" .. string.rep("png-block;", 120)
  cache:write("data/generated/maps/61.lua", luaLogical)
  cache:write("data/generated/audio/bank7.pcm16le", pcmLogical)
  cache:write("assets/generated/maps/geometry/scratch.g4mesh", meshLogical)
  cache:write("assets/generated/maps/textures/abc.png", pngBytes)
  cache:write("mods/mymod/info.lua", "return { name = 'mymod' }\n")
  publishReceipt(cache, generation, "map", "61", "complete")
  seedLegacyDump(cache)
  CacheEnvelope.attachHostCodecs(backend)
  local saveBackend = FakeCache.new()
  saveBackend:write("saves/slot1.sav", "save-bytes")

  local result = maintenance.migrateLegacy("heartgold", cache, {
    completeCacheUsable = true,
    verifiedReopenableSource = false,
  })

  Assert.equal(result.rawRemoved, true, "a playable complete cache drops its duplicate source dump without a ROM")
  Assert.isTrue(result.bytesAfter < result.bytesBefore, "migration must shrink measured physical bytes")
  Assert.isTrue((result.changedCount or 0) >= 2, "compressible derived files must convert")
  Assert.equal(cache:read("data/generated/maps/61.lua"), luaLogical)
  Assert.equal(cache:read("data/generated/audio/bank7.pcm16le"), pcmLogical)
  Assert.equal(cache:read("assets/generated/maps/geometry/scratch.g4mesh"), meshLogical)
  Assert.equal(cache:read("assets/generated/maps/textures/abc.png"), pngBytes)
  Assert.isTrue(
    CacheEnvelope.isWrapped(backend.files["heartgold/data/generated/maps/61.lua"]),
    "migrated derived bytes land in the compact physical form"
  )
  Assert.equal(
    backend.files["heartgold/assets/generated/maps/textures/abc.png"],
    pngBytes,
    "native images stay unwrapped so graphics paths keep reading them"
  )
  assertLegacyDumpGone(cache)
  Assert.equal(cache:read("mods/mymod/info.lua"), "return { name = 'mymod' }\n")
  Assert.equal(saveBackend:read("saves/slot1.sav"), "save-bytes", "saves are never inside the migration root")
  Assert.notNil(
    requireReceipts().read(cache, generation, "map", "61"),
    "migration preserves the trusted readiness receipt for a source-free boot"
  )
  local marker = cache:loadLua(MIGRATION_MARKER)
  Assert.deepEqual(marker, { schema = 1, physicalFormat = 1 })
  local repeatResult = maintenance.migrateLegacy("heartgold", cache, {
    completeCacheUsable = true,
    verifiedReopenableSource = false,
  })
  Assert.equal(repeatResult.changedCount, 0, "a marked migration is not reprocessed")
end

function T.partial_cache_keeps_its_dump_until_a_matching_source_is_verified()
  local maintenance = requireMaintenance()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:recoverPublication()
  local generation = generationIdFor(Sha256.hex("partial migration producer"))
  local luaLogical = compressibleLua()
  cache:write("data/generated/maps/61.lua", luaLogical)
  publishReceipt(cache, generation, "map", "61", "complete")
  seedLegacyDump(cache)
  CacheEnvelope.attachHostCodecs(backend)

  local blocked = maintenance.migrateLegacy("heartgold", cache, {
    completeCacheUsable = false,
    verifiedReopenableSource = false,
  })
  Assert.equal(blocked.rawRemoved, false, "an unverified partial cache must not lose its last source")
  Assert.notNil(blocked.blockedReason, "the gate must name why removal is unsafe")
  assertLegacyDumpKept(cache)
  Assert.isFalse(cache:exists(MIGRATION_MARKER), "a blocked migration leaves no completion marker")
  Assert.notNil(
    requireReceipts().read(cache, generation, "map", "61"),
    "ready partial artifacts stay usable while the dump is retained"
  )

  local verified = maintenance.migrateLegacy("heartgold", cache, {
    completeCacheUsable = false,
    verifiedReopenableSource = true,
  })
  Assert.equal(verified.rawRemoved, true, "a verified matching source releases the duplicate dump")
  Assert.equal(cache:read("data/generated/maps/61.lua"), luaLogical)
  assertLegacyDumpGone(cache)
  Assert.deepEqual(cache:loadLua(MIGRATION_MARKER), { schema = 1, physicalFormat = 1 })
end

function T.interrupted_migration_resumes_and_converges_without_recompiling()
  local maintenance = requireMaintenance()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:recoverPublication()
  local luaLogical = compressibleLua()
  local pcmLogical = string.rep("pcm-frame;", 300)
  local pngBytes = "\137PNG\r\n\26\n" .. string.rep("png-block;", 120)
  cache:write("data/generated/maps/61.lua", luaLogical)
  cache:write("data/generated/audio/bank7.pcm16le", pcmLogical)
  cache:write("assets/generated/maps/textures/abc.png", pngBytes)
  seedLegacyDump(cache)
  CacheEnvelope.attachHostCodecs(backend)

  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if destinationPath:find(".__g4next", 1, true) then
      return false, "injected migration publication failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local err = Assert.throws(function()
    maintenance.migrateLegacy("heartgold", cache, {
      completeCacheUsable = true,
      verifiedReopenableSource = false,
    })
  end)
  Assert.notNil(err, "a storage fault during conversion must surface")
  backend.replace = originalReplace
  Assert.equal(cache:read("data/generated/maps/61.lua"), luaLogical)
  Assert.equal(cache:read("data/generated/audio/bank7.pcm16le"), pcmLogical)
  Assert.equal(cache:read("assets/generated/maps/textures/abc.png"), pngBytes)
  Assert.isFalse(cache:exists(MIGRATION_MARKER), "a failed pass leaves no completion marker")
  assertLegacyDumpKept(cache)

  cache:recoverPublication()
  local result = maintenance.migrateLegacy("heartgold", cache, {
    completeCacheUsable = true,
    verifiedReopenableSource = false,
  })
  Assert.equal(result.rawRemoved, true, "the retry converges without recompiling from a ROM")
  Assert.equal(cache:read("data/generated/maps/61.lua"), luaLogical)
  Assert.equal(cache:read("data/generated/audio/bank7.pcm16le"), pcmLogical)
  Assert.equal(
    backend.files["heartgold/assets/generated/maps/textures/abc.png"],
    pngBytes,
    "the retry still leaves native images unwrapped"
  )
  assertLegacyDumpGone(cache)
  Assert.deepEqual(cache:loadLua(MIGRATION_MARKER), { schema = 1, physicalFormat = 1 })
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

function T.malformed_migration_marker_retries_instead_of_erasing_output()
  local maintenance = requireMaintenance()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:recoverPublication()
  local luaLogical = compressibleLua()
  cache:write("data/generated/maps/61.lua", luaLogical)
  seedLegacyDump(cache)
  cache:writeLua(MIGRATION_MARKER, { schema = 2, physicalFormat = 1, extra = true })
  CacheEnvelope.attachHostCodecs(backend)

  local result = maintenance.migrateLegacy("heartgold", cache, {
    completeCacheUsable = true,
    verifiedReopenableSource = false,
  })

  Assert.equal(result.rawRemoved, true, "a malformed marker never blocks a safe migration")
  Assert.equal(cache:read("data/generated/maps/61.lua"), luaLogical)
  Assert.deepEqual(cache:loadLua(MIGRATION_MARKER), { schema = 1, physicalFormat = 1 })
  assertLegacyDumpGone(cache)
end

function T.migration_never_touches_mods_staging_or_sibling_versions()
  local maintenance = requireMaintenance()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local sibling = CacheFs.forVersion("soulsilver", backend)
  cache:recoverPublication()
  local luaLogical = compressibleLua()
  local modLogical = "return { name = 'kept' }\n"
  local stageLogical = string.rep("staged-block;", 120)
  local siblingLogical = string.rep("sibling-block;", 120)
  cache:write("data/generated/maps/61.lua", luaLogical)
  cache:write("mods/mymod/nested/info.lua", modLogical)
  cache:write("staging/leftover/scratch.lua", stageLogical)
  sibling:write("data/generated/maps/61.lua", siblingLogical)
  seedLegacyDump(cache)
  CacheEnvelope.attachHostCodecs(backend)

  local result = maintenance.migrateLegacy("heartgold", cache, {
    completeCacheUsable = true,
    verifiedReopenableSource = false,
  })

  Assert.equal(result.rawRemoved, true)
  Assert.equal(cache:read("data/generated/maps/61.lua"), luaLogical)
  Assert.equal(cache:read("mods/mymod/nested/info.lua"), modLogical, "user mods stay byte-identical")
  Assert.equal(
    backend.files["heartgold/staging/leftover/scratch.lua"],
    stageLogical,
    "staging debris is never transcoded"
  )
  Assert.equal(sibling:read("data/generated/maps/61.lua"), siblingLogical, "a sibling version is never entered")
  Assert.isFalse(sibling:exists(MIGRATION_MARKER), "the marker lands only on the migrated version")
  assertLegacyDumpGone(cache)
end

return { tests = T }
