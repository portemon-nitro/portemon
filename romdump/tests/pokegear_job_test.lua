-- The Pokegear presentation is one closed cache family with a single global
-- key, prepared with the ordinary field runtime and never with Oak-only
-- bootstrap. Its worker closure stays bounded: the family compiles from the
-- dump alone and never requests the complete corpus.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")

local T = {}

function T.pokegear_family_receipt_uses_only_the_global_key()
  local accepted, path = pcall(ArtifactState.path, "pokegear", "global")
  Assert.isTrue(accepted, "the pokegear cache family must admit its global receipt")
  Assert.equal(path, "data/generated/jobs/pokegear/global.lua")

  local acceptedNonGlobalKey = pcall(ArtifactState.path, "pokegear", "0")
  Assert.isFalse(acceptedNonGlobalKey, "the pokegear cache family must reject non-global keys")
end

function T.pokegear_is_required_by_field_runtime_and_not_new_game_intro()
  local fieldRuntime = false
  for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
    fieldRuntime = fieldRuntime or (job.kind == "pokegear" and job.key == "global")
  end
  Assert.isTrue(fieldRuntime, "field runtime prepares the pokegear presentation family")

  local intro, complete = ArtifactJobs.newGameIntroJobs(nil)
  Assert.isFalse(complete, "the intro closure remains unresolved without its audio plan")
  for _, job in ipairs(intro) do
    Assert.isFalse(job.kind == "pokegear", "Oak-only preparation does not pull the pokegear presentation family")
  end
end

function T.pokegear_worker_closure_is_bounded_and_statically_known()
  local dependencies, complete = ArtifactJobs.dependencies("pokegear", "global", {})
  Assert.isTrue(complete, "pokegear family dependencies are statically known")
  Assert.equal(#dependencies, 0, "the pokegear family compiles from the dump alone")
end

function T.common_session_compiles_pokegear_through_the_single_dispatcher()
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local compilerPath = "romdump.src.digest.ui.PokegearAssetCompiler"
  local writerPath = "romdump.src.digest.ui.PokegearCacheWriter"
  local compiled = { marker = "pokegear-marker" }
  local stagedBundle = nil
  local savedCompiler, savedWriter = package.loaded[compilerPath], package.loaded[writerPath]
  package.loaded[compilerPath] = {
    compile = function()
      return compiled
    end,
  }
  package.loaded[writerPath] = {
    stage = function(artifact, bundle)
      stagedBundle = bundle
      artifact:addOwnedRoot("data/generated/pokegear")
      return bundle.marker
    end,
  }
  local ok, outcome = pcall(ArtifactJobs.execute, {
    kind = "pokegear",
    key = "global",
    generationId = "test-generation",
    epoch = 1,
    stageName = "pokegear-dispatch-test",
  }, {
    romFs = {},
    versionId = "heartgold",
    cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()),
  })
  package.loaded[compilerPath] = savedCompiler
  package.loaded[writerPath] = savedWriter
  Assert.isTrue(ok, "the single dispatcher runs the pokegear family: " .. tostring(outcome))
  Assert.equal(outcome.result.marker, compiled.marker)
  Assert.equal(stagedBundle, compiled, "the dispatcher stages the family compiler bundle")
  Assert.equal(ArtifactJobs.sizeClass("pokegear"), "normal")
  Assert.deepEqual(ArtifactJobs.dependencies("pokegear", "global", {}), {})
end

return { tests = T }
