-- ROM-backed worker evidence: two supported maps must cross the production
-- compiler boundary and become independently ready published map roots.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function requirePool()
  local ok, pool = pcall(require, "romdump.src.build.CompilerPool")
  Assert.isTrue(ok, "the production compiler-pool boundary is missing")
  return pool
end

-- Maps are ordinary jobs on the bounded batch pool: the two independent
-- maps overlap on the two workers, each publishes a semantically ready
-- root, and no per-job VM recycling intervenes.
function T.independent_map_jobs_overlap_on_bounded_batch_workers(romFs, versionId)
  local CompilerPool = requirePool()
  -- Jobs cross the pool boundary under an explicit generation: select it
  -- first and tag every job, exactly as the production session does.
  local sha1 = assert(romFs:metadata().sha1, "dump has no SHA-1 identity")
  -- The runner prepares the declared map scope under the current
  -- development generation, so the jobs below use that same generation to
  -- consume the prepared cells.
  local sourceBase = love.filesystem.getSourceBaseDirectory()
  local producerId = ProducerFingerprint.compute(ProducerFingerprint.checkoutBackend(sourceBase))
  local identity = DerivedCacheState.currentForSelection({
    versionId = versionId,
    romSha1 = sha1,
    producerId = producerId,
    developmentRepositoryRoot = sourceBase,
  })
  local generationId = assert(identity.generationId, "generation identity is required")
  local pool = CompilerPool.new({
    versionId = versionId,
    mode = "batch",
  })
  pool:selectGeneration(identity, 1)

  -- The prepared scope is this test's starting cut: hydrate the one snapshot
  -- exactly as a selection does, so every dependency a job declares is already
  -- committed when the pool builds its closed dependency view.
  local CacheArchive = require("romdump.src.build.CacheArchive")
  CacheArchive.restoreBackup(versionId)
  local fileName = assert(CacheArchive.recoverableFileName(versionId), "the prepared scope carries one snapshot")
  local hydration = assert(CacheArchive.open(versionId, identity, fileName))
  -- The prepared scope already covers both maps; that cut is the prerequisite
  -- set this test compiles against, so the maps themselves are left out and
  -- recompiled from the ROM exactly like a partial-cache miss.
  local seededArtifacts, seededPaths = {}, {}
  local function isCompiledMap(artifact)
    return artifact.kind == "map" and (artifact.key == "60" or artifact.key == "61")
  end
  for _, artifact in ipairs(hydration.artifacts) do
    if not isCompiledMap(artifact) then
      seededArtifacts[#seededArtifacts + 1] = artifact
      for _, path in ipairs(artifact.files) do
        seededPaths[path] = true
      end
    end
  end
  local seededEntries = {}
  for _, entry in ipairs(hydration.entries) do
    if seededPaths[entry.path] then
      seededEntries[#seededEntries + 1] = entry
    end
  end
  pool:seedCommittedGeneration(seededEntries, seededArtifacts)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local record = assert(SourcePlan.read(pool:cacheFs(), identity), "the snapshot carries its plan")
  local plans = SourcePlan.project(record)
  plans.mapCellKeys = record.mapCellKeys

  local jobs = {
    { key = "60", mapId = 60 },
    { key = "61", mapId = 61 },
  }
  for _, job in ipairs(jobs) do
    local dependencies = assert(ArtifactJobs.dependencies("map", job.key, plans), "map membership is adopted")
    pool:request({
      versionId = versionId,
      generationId = generationId,
      epoch = 1,
      kind = "map",
      key = job.key,
      jobKey = "map:" .. job.key,
      priority = 0,
      sizeClass = ArtifactJobs.sizeClass("map"),
      payload = { mapId = job.mapId, producerFingerprint = producerId },
      dependencies = dependencies,
    })
  end
  pool:drain()

  local workerIds = {}
  local cache = pool:cacheFs()
  for _, job in ipairs(jobs) do
    local state, details = pool:status("map:" .. job.key)
    Assert.equal(state, "ready", "map " .. job.key .. " completes: " .. tostring(details and details.error))
    local workerId = assert(details and details.workerId, "ready result reports its worker")
    workerIds[#workerIds + 1] = workerId

    local marker =
      assert(cache:read(MapAssetCache.mapDir(job.mapId) .. "/complete"), "published map has a completion marker")
    Assert.isTrue(MapAssetCache.isReady(cache, job.mapId, marker), "published map is semantically ready")
    local scene = assert(cache:loadLua(MapAssetCache.mapDir(job.mapId) .. "/scene.lua"))
    Assert.equal(scene.mapId, job.mapId, "published scene retains its requested map identity")
  end
  -- Both maps dispatch together onto the two bounded batch workers:
  -- independence here means separate jobs, separate published roots, and
  -- parallel placement with identical output.
  Assert.equal(#workerIds, 2, "both maps report their worker")
  Assert.isTrue(workerIds[1] ~= workerIds[2], "the independent maps overlap on distinct workers")
  pool:shutdown()
  Assert.isTrue(romFs ~= nil, "the ROM suite keeps the source handle alive")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "map:60", "map:61" }
suite.metadata.tags = { "producer", "cache", "parallel" }
return suite
