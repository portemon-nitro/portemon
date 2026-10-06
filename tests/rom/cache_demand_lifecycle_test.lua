-- Demand lifecycle against the real published corpus: lazy construction
-- reads no generated bodies, and first access reads only its own resource.
-- Saved script state carries no aggregate fingerprint: a current bucket
-- validates without one, and a predecessor bucket carrying stale
-- fingerprints migrates by dropping only those fields.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local HgssScript = require("libs.hgss.src.script.Composition")
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

-- Lazy construction reads no generated body; the first explicit base
-- access then reads exactly its own resource file.
function T.lazy_build_reads_no_bodies_and_first_access_reads_only_its_resource(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local fs = overrideFs()
  local finishBuildReads = countBodyReads(cacheFs)
  local registry, selection = ScriptLoader.buildRegistry(cacheFs, fs, nil, { lazy = true, builtins = builtins() })
  Assert.equal(finishBuildReads(), 0, "lazy construction reads no generated bodies")
  local builtinIds = {}
  for id in pairs(builtins().all()) do
    builtinIds[id] = true
  end
  local firstId
  for _, entry in ipairs(selection.index.resources) do
    if type(entry.id) == "string" and not builtinIds[entry.id] then
      firstId = entry.id
      break
    end
  end
  assert(firstId ~= nil, "the published corpus carries generated scripts")
  local finishAccessReads = countBodyReads(cacheFs)
  local base = assert(registry:base(firstId))
  Assert.equal(base.id, firstId, "first access resolves the pinned resource")
  Assert.equal(finishAccessReads(), 1, "first access reads exactly its own body")
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
-- script corpus with canonical sidecars) read-only; body reads go through
-- the same cache without writing.
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "script-summary:global" }
suite.metadata.tags = { "script", "save" }
return suite
