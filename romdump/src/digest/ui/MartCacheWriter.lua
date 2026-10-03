-- Publishes a complete mart bundle through the shared staged-artifact
-- transaction. The family marker is written after payload readback succeeds.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local MartAssetSchema = require("libs.assets.src.MartAssetSchema")
local MartCache = require("libs.assets.src.MartCache")

local MartCacheWriter = {}

MartCacheWriter.ERROR = {
  BUNDLE_INVALID = "MART_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "MART_CACHE_READBACK_FAILED",
}

function MartCacheWriter.isReady(cacheFs, marker)
  return MartCache.isReady(cacheFs, marker)
end

local function validateBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(MartCacheWriter.ERROR.BUNDLE_INVALID, "mart bundle carries no marker", {})
  end
  if type(bundle.catalog) ~= "table" or type(bundle.manifest) ~= "table" or type(bundle.assets) ~= "table" then
    Errors.raise(MartCacheWriter.ERROR.BUNDLE_INVALID, "mart bundle is incomplete", {})
  end
  if type(bundle.provenance) ~= "table" then
    Errors.raise(MartCacheWriter.ERROR.BUNDLE_INVALID, "mart bundle carries no provenance", {})
  end
  if
    bundle.provenance.cacheFormat ~= MartCache.FORMAT
    or bundle.provenance.catalogSchema ~= MartCache.CATALOG_SCHEMA
    or bundle.provenance.schema ~= MartCache.SCHEMA
    or type(bundle.provenance.versionRomSha1) ~= "string"
    or type(bundle.provenance.dependencyHash) ~= "string"
    or MartCache.marker(bundle.provenance.versionRomSha1, bundle.provenance.dependencyHash) ~= bundle.marker
  then
    Errors.raise(MartCacheWriter.ERROR.BUNDLE_INVALID, "mart provenance does not identify its marker", {})
  end
  local ok, err = pcall(MartAssetSchema.assertCatalog, bundle.catalog)
  if not ok then
    Errors.raise(MartCacheWriter.ERROR.BUNDLE_INVALID, "mart catalog is invalid: " .. Errors.format(err), {})
  end
  ok, err = pcall(MartAssetSchema.assertManifest, bundle.manifest)
  if not ok then
    Errors.raise(MartCacheWriter.ERROR.BUNDLE_INVALID, "mart manifest is invalid: " .. Errors.format(err), {})
  end
  local references = MartCache.referencedPaths(bundle.manifest)
  local referenced = {}
  for _, path in ipairs(references) do
    referenced[path] = true
  end
  for path, bytes in pairs(bundle.assets) do
    if
      type(path) ~= "string"
      or path:sub(1, #MartCache.assetDir() + 1) ~= MartCache.assetDir() .. "/"
      or path:find("..", 1, true)
      or type(bytes) ~= "string"
      or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n"
      or not referenced[path]
    then
      Errors.raise(MartCacheWriter.ERROR.BUNDLE_INVALID, "mart bundle carries an invalid or unreferenced image", {
        path = path,
      })
    end
  end
  for _, path in ipairs(references) do
    if bundle.assets[path] == nil then
      Errors.raise(MartCacheWriter.ERROR.BUNDLE_INVALID, "mart bundle is missing image " .. path, { path = path })
    end
  end
end

local function stageBundle(stage, bundle)
  for _, path in ipairs(MartCache.referencedPaths(bundle.manifest)) do
    stage:write(path, bundle.assets[path])
  end
  stage:writeLua(MartCache.catalogPath(), bundle.catalog)
  stage:writeLua(MartCache.manifestPath(), bundle.manifest)
  stage:writeLua(MartCache.provenancePath(), bundle.provenance)

  local catalog = stage:loadLua(MartCache.catalogPath())
  local ok, err = pcall(MartAssetSchema.assertCatalog, catalog)
  if not ok then
    Errors.raise(MartCacheWriter.ERROR.READBACK_FAILED, "mart catalog readback is invalid: " .. Errors.format(err), {})
  end
  local manifest = stage:loadLua(MartCache.manifestPath())
  ok, err = pcall(MartAssetSchema.assertManifest, manifest)
  if not ok then
    Errors.raise(MartCacheWriter.ERROR.READBACK_FAILED, "mart manifest readback is invalid: " .. Errors.format(err), {})
  end
  local provenance = stage:loadLua(MartCache.provenancePath())
  if type(provenance) ~= "table" or provenance.cacheFormat ~= MartCache.FORMAT then
    Errors.raise(MartCacheWriter.ERROR.READBACK_FAILED, "mart provenance readback is invalid", {})
  end
  for _, path in ipairs(MartCache.referencedPaths(manifest)) do
    if not stage:exists(path, "file") then
      Errors.raise(MartCacheWriter.ERROR.READBACK_FAILED, "mart image missing after stage: " .. path, { path = path })
    end
  end
  stage:write(MartCache.markerPath(), bundle.marker)
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function MartCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "mart staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(MartCache.assetDir())
  artifact:addOwnedRoot(MartCache.dir())
  stageBundle(artifact:stageFs(), bundle)
  return bundle.marker
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return string
function MartCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and bundle, "mart publication requires a cache and a bundle")
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "mart", { MartCache.assetDir(), MartCache.dir() })
  local ok, err = pcall(stageBundle, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return bundle.marker
end

return MartCacheWriter
