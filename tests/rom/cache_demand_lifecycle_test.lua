-- Demand lifecycle against the real published corpus: lazy construction
-- reads no generated bodies, and first access reads only its own member
-- bundle.
-- Saved script state carries no aggregate fingerprint: a current bucket
-- validates without one, and a predecessor bucket carrying stale
-- fingerprints migrates by dropping only those fields.

local Assert = require("tests.support.Assert")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
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

-- Counts reads of generated member bundles: one readable bundle per nonempty
-- script archive member is the generated body unit. The counted reader is a
-- thin per-test wrapper over the installed view, so the shared resident reader
-- itself is never mutated.
local READER_METHODS = {
  "read",
  "readData",
  "loadLua",
  "loadModule",
  "exists",
  "getInfo",
  "getDirectoryItems",
  "resolveAsset",
}

---@param cacheFs table<string, unknown> installed generated reader
---@return table<string, unknown> counting reader
---@return fun(): integer finished body read count
local function countBodyReads(cacheFs)
  local reads = 0
  local reader = { versionId = cacheFs.versionId }
  for _, name in ipairs(READER_METHODS) do
    local method = cacheFs[name]
    if type(method) == "function" then
      reader[name] = function(_, path, ...)
        if name == "read" and type(path) == "string" then
          if path:find("/generations/", 1, true) ~= nil and path:sub(-4) == ".lua" then
            reads = reads + 1
          end
        end
        return method(cacheFs, path, ...)
      end
    end
  end
  return reader, function()
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
-- access then reads exactly its own member bundle.
function T.lazy_build_reads_no_bodies_and_first_access_reads_only_its_resource(_, versionId)
  local cacheFs, finishedBodies = countBodyReads(GeneratedCacheFixture.reader(versionId))
  local fs = overrideFs()
  local registry, selection = ScriptLoader.buildRegistry(cacheFs, fs, nil, { lazy = true, builtins = builtins() })
  Assert.equal(finishedBodies(), 0, "lazy construction reads no generated bodies")
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
  local base = assert(registry:base(firstId))
  Assert.equal(base.id, firstId, "first access resolves the pinned resource")
  Assert.equal(finishedBodies(), 1, "first access reads exactly its own member bundle")
end

function T.current_save_bucket_validates_without_fingerprints(_, versionId)
  local cacheFs = GeneratedCacheFixture.reader(versionId)
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
-- Reads the runner-prepared complete scope read-only; member bundle reads
-- go through the same cache without writing.
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "script-summary:global" }
suite.metadata.tags = { "script", "save" }
return suite
