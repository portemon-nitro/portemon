-- Seeded script-hash lifecycle against the real published corpus: the digest
-- computed from published hashes equals the digest computed by loading every
-- generated body, and lazy construction reads no generated bodies. Saved
-- script state carries no aggregate fingerprint: a current bucket validates
-- without one, and a predecessor bucket carrying stale fingerprints migrates
-- by dropping only those fields.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local HgssScript = require("libs.hgss.src.script.Composition")
local Registry = require("libs.script.src.Registry")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local ScriptSave = require("libs.script.src.ScriptSave")

local T = {}

local function overrideFs()
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return "return {}\n"
      end
      return nil
    end,
  }
end

local function builtins()
  return HgssScript.builtins()
end

-- The pre-change algorithm: every generated body loaded and hashed, no
-- published hash consulted. Mirrors the loader's layer composition exactly
-- except hash seeding, so any divergence names a digest break.
local function oracleDigest(cacheFs, fs, selection)
  local registry = Registry.new()
  for id, script in pairs(builtins().all()) do
    registry:installBuiltin(id, script)
  end
  ScriptLoader.installGenerated(registry, cacheFs, nil, { lazy = false, selection = selection })
  ScriptLoader.installOverrides(registry, fs, nil)
  registry:seal()
  return registry:fingerprint()
end

local function countBodyReads(cacheFs)
  local reads = 0
  local backend = assert(cacheFs.backend, "the cache exposes its backend")
  local originalRead = assert(backend.read, "the backend reads by path")
  backend.read = function(self, path)
    if type(path) == "string" and path:find("/scripts/", 1, true) ~= nil and path:sub(-4) == ".lua" then
      reads = reads + 1
    end
    return originalRead(self, path)
  end
  return function()
    backend.read = originalRead
    return reads
  end
end

local function currentBucket()
  return {
    schema = ScriptSave.SCHEMA_NAME,
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
  }
end

function T.published_hashes_reproduce_the_body_loaded_digest_without_body_reads(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local fs = overrideFs()
  local _, selection = ScriptLoader.buildRegistry(cacheFs, fs, nil, { lazy = true, builtins = builtins() })
  local oracle = oracleDigest(cacheFs, fs, selection)
  local finishBodyReads = countBodyReads(cacheFs)
  local registry = ScriptLoader.buildRegistry(cacheFs, fs, nil, { lazy = true, builtins = builtins() })
  local digest = registry:fingerprint()
  local bodyReads = finishBodyReads()
  Assert.equal(digest, oracle, "seeded hashes reproduce the body-loaded registry digest")
  Assert.equal(bodyReads, 0, "digest acquisition reads no generated bodies")
  Assert.isTrue(#digest > 0, "the reproduced digest is non-empty")
end

function T.current_save_bucket_validates_without_fingerprints(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local fs = overrideFs()
  ScriptLoader.buildRegistry(cacheFs, fs, nil, { lazy = true, builtins = builtins() })
  Assert.isNil(ScriptSave.validate(currentBucket(), {}), "a current bucket validates with no fingerprint context")
  local predecessor = currentBucket()
  predecessor.schema = ScriptSave.LEGACY_SCHEMA_NAME
  predecessor.registryFingerprint = "stale-registry"
  predecessor.taskFingerprint = "stale-tasks"
  local migrated = ScriptSave.migrateV1(predecessor)
  Assert.equal(migrated.schema, ScriptSave.SCHEMA_NAME)
  Assert.isNil(ScriptSave.validate(migrated, {}), "the migrated predecessor validates without rebinding")
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
-- Reads the runner-prepared complete scope (which publishes the complete
-- script corpus with canonical sidecars) read-only; the oracle loads bodies
-- through the same cache without writing.
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "script-summary:global" }
suite.metadata.tags = { "script", "save" }
return suite
