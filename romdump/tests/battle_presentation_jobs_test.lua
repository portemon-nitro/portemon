-- Battle presentation worker registration over the real dump: the two
-- kinds live in the closed job table, scene keys validate, scene demands
-- resolve to the staged global, and global/scene execution publishes
-- validatable receipts. Assertions are readiness relationships and key
-- rules, never catalog snapshots.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local GENERATION = "battle-presentation-jobs-test"

function T.kinds_sizes_and_keys_follow_the_closed_dispatch()
  Assert.isTrue(ArtifactState.KINDS["battle-presentation"] == true, "the global kind is registered")
  Assert.isTrue(ArtifactState.KINDS["battle-scene"] == true, "the scene kind is registered")
  Assert.equal(ArtifactJobs.sizeClass("battle-presentation"), "normal", "the global job has its lane")
  Assert.equal(ArtifactJobs.sizeClass("battle-scene"), "normal", "scene jobs have their lane")
  Assert.equal(
    ArtifactJobs.jobKey("battle-scene", "general/grass/day"),
    "battle-scene:general/grass/day",
    "scene job keys carry the semantic key"
  )
  Assert.equal(
    ArtifactState.path("battle-scene", "general/grass/day"),
    "data/generated/jobs/battle-scene/general/grass/day.lua",
    "scene receipts nest under their kind"
  )
end

function T.scene_keys_validate_while_effect_backgrounds_do_not()
  local ok = pcall(ArtifactState.path, "battle-scene", "general/grass/day")
  Assert.isTrue(ok, "an ordinary scene key resolves to a receipt path")
  local effectOk = pcall(ArtifactState.path, "battle-scene", "effect/flash/day")
  Assert.isFalse(effectOk, "an effect background never resolves to a receipt path")
  local globalOk = pcall(ArtifactState.path, "battle-presentation", "other")
  Assert.isFalse(globalOk, "the global family carries no other key")
end

function T.scene_demands_resolve_to_the_staged_global()
  local dependencies, complete = ArtifactJobs.dependencies("battle-scene", "general/grass/day", {})
  Assert.isTrue(complete, "scene dependencies resolve without adopted plans")
  Assert.deepEqual(dependencies, { { kind = "battle-presentation", key = "global" } }, "scenes build on the global")
end

---@param cacheFs CacheFs
---@param job table
---@param context table
local function runAndPublish(cacheFs, job, context)
  local outcome = assert(ArtifactJobs.execute(job, context))
  local artifact = PreparedArtifact.open({
    cacheFs = context.cacheFs,
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.kind .. ":" .. job.key,
    stageName = job.stageName,
  })
  artifact:publish({
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.kind .. ":" .. job.key,
  })
  return outcome
end

function T.global_and_scene_execution_publishes_validatable_receipts(romFs, versionId)
  local cache = CacheFs.forVersion(versionId, FakeCache.new())
  local context = { romFs = romFs, cacheFs = cache, versionId = versionId }
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "battle-presentation", "global", {}),
    "an unstaged global never validates"
  )
  local global = runAndPublish(cache, {
    kind = "battle-presentation",
    key = "global",
    generationId = GENERATION,
    epoch = 1,
    stageName = "battle-jobs-global",
  }, context)
  Assert.isTrue(type(global.result.marker) == "string", "global execution carries its marker")
  Assert.isTrue(
    ArtifactJobs.validate(cache, GENERATION, "battle-presentation", "global", {}),
    "the staged global validates"
  )
  local manifest = BattlePresentationCache.load(cache)
  Assert.equal(manifest.verified, true, "the staged manifest proves its dump verification")
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "battle-scene", "general/grass/day", {}),
    "an unstaged scene never validates"
  )
  local scene = runAndPublish(cache, {
    kind = "battle-scene",
    key = "general/grass/day",
    generationId = GENERATION,
    epoch = 1,
    stageName = "battle-jobs-scene",
  }, context)
  Assert.isTrue(type(scene.result.marker) == "string", "scene execution carries its marker")
  Assert.isTrue(
    ArtifactJobs.validate(cache, GENERATION, "battle-scene", "general/grass/day", {}),
    "the staged scene validates"
  )
  local record = assert(BattlePresentationCache.loadScene(cache, "general/grass/day"))
  Assert.equal(record.key, "general/grass/day", "the staged scene names exactly its key")
end

return RomSuite.fromFacts(T)
