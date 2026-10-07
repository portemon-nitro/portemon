-- Publishes the compiled summary presentation class through the shared
-- stage/validate/publish lifecycle. The summary-owned manifest, images,
-- and completion marker stage under the family roots with the marker
-- last, so a staging failure before publication preserves the live
-- family. Once publication begins the shared publisher owns rollback,
-- recovery, and cleanup outcomes.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local SummaryAssetSchema = require("libs.assets.src.SummaryAssetSchema")
local SummaryCache = require("libs.assets.src.SummaryCache")

local SummaryCacheWriter = {}

SummaryCacheWriter.ERROR = {
  BUNDLE_INVALID = "SUMMARY_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "SUMMARY_CACHE_READBACK_FAILED",
}

function SummaryCacheWriter.isReady(cacheFs, marker)
  return SummaryCache.isReady(cacheFs, marker)
end

---@param bundle table<string, unknown>
local function validateBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(SummaryCacheWriter.ERROR.BUNDLE_INVALID, "summary bundle carries no marker", {})
  end
  if type(bundle.manifest) ~= "table" or type(bundle.assets) ~= "table" then
    Errors.raise(SummaryCacheWriter.ERROR.BUNDLE_INVALID, "summary bundle carries no manifest payload", {})
  end
  if type(bundle.dependencies) ~= "table" then
    Errors.raise(SummaryCacheWriter.ERROR.BUNDLE_INVALID, "summary bundle carries no dependency record", {})
  end
  if bundle.dependencies.cacheFormat ~= SummaryCache.FORMAT or bundle.dependencies.schema ~= SummaryCache.SCHEMA then
    Errors.raise(SummaryCacheWriter.ERROR.BUNDLE_INVALID, "summary bundle dependencies identify the wrong cache", {})
  end
  local ok, err = pcall(SummaryAssetSchema.assertManifest, bundle.manifest)
  if not ok then
    Errors.raise(SummaryCacheWriter.ERROR.BUNDLE_INVALID, "summary manifest is invalid: " .. Errors.format(err), {})
  end
  for _, path in ipairs(SummaryCache.referencedPaths(bundle.manifest)) do
    if path:sub(1, 2) == ".." or path:find("/%.%./") ~= nil then
      Errors.raise(
        SummaryCacheWriter.ERROR.BUNDLE_INVALID,
        "summary bundle escapes its roots: " .. path,
        { path = path }
      )
    end
    if bundle.assets[path] == nil then
      Errors.raise(
        SummaryCacheWriter.ERROR.BUNDLE_INVALID,
        "summary bundle is missing referenced asset " .. path,
        { path = path }
      )
    end
  end
end

---@param tx table<string, unknown>
---@param bundle table<string, unknown>
---@param cacheFs CacheFs
local function stageBundle(tx, bundle, cacheFs)
  local stage = tx.stage
  stage:createDirectory(SummaryCache.assetDir())
  stage:createDirectory(SummaryCache.dir())
  for _, path in ipairs(SummaryCache.referencedPaths(bundle.manifest)) do
    if path:sub(1, #SummaryCache.assetDir()) == SummaryCache.assetDir() then
      stage:write(path, bundle.assets[path])
    else
      cacheFs:write(path, bundle.assets[path])
    end
  end
  stage:writeLua(SummaryCache.provenancePath(), bundle.dependencies)
  stage:writeLua(SummaryCache.manifestPath(), bundle.manifest)
  local dependencies = stage:loadLua(SummaryCache.provenancePath())
  if
    type(dependencies) ~= "table"
    or dependencies.cacheFormat ~= SummaryCache.FORMAT
    or dependencies.schema ~= SummaryCache.SCHEMA
  then
    Errors.raise(SummaryCacheWriter.ERROR.READBACK_FAILED, "summary dependencies readback is invalid", {})
  end
  local manifest = stage:loadLua(SummaryCache.manifestPath())
  local ok, err = pcall(SummaryAssetSchema.assertManifest, manifest)
  if not ok then
    Errors.raise(
      SummaryCacheWriter.ERROR.READBACK_FAILED,
      "summary manifest readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  for _, path in ipairs(SummaryCache.referencedPaths(manifest)) do
    local present = stage:exists(path, "file") or cacheFs:exists(path, "file")
    if not present then
      Errors.raise(
        SummaryCacheWriter.ERROR.READBACK_FAILED,
        "summary asset missing after stage: " .. path,
        { path = path }
      )
    end
  end
  stage:write(SummaryCache.markerPath(), bundle.marker)
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function SummaryCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "summary staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(SummaryCache.assetDir())
  artifact:addOwnedRoot(SummaryCache.dir())
  for _, path in ipairs(SummaryCache.referencedPaths(bundle.manifest)) do
    if path:sub(1, #SummaryCache.assetDir()) ~= SummaryCache.assetDir() then
      artifact:addSharedFile(path)
    end
  end
  stageBundle({ stage = artifact:stageFs() }, bundle, artifact:cacheFs())
  return bundle.marker
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return boolean
function SummaryCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and bundle, "summary publication requires a cache and a bundle")
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "summary", { SummaryCache.assetDir(), SummaryCache.dir() })
  local ok, err = pcall(stageBundle, tx, bundle, cacheFs)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return SummaryCacheWriter
