-- Publishes a complete source-backed Apricorn Box pane bundle.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local Validate = require("libs.assets.src.Validate")

local ApricornBoxCacheWriter = {}

ApricornBoxCacheWriter.ERROR = {
  BUNDLE_INVALID = "APRICORN_BOX_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "APRICORN_BOX_CACHE_READBACK_FAILED",
}

local function validateBundle(bundle)
  if
    type(bundle) ~= "table"
    or type(bundle.marker) ~= "string"
    or type(bundle.manifest) ~= "table"
    or type(bundle.assets) ~= "table"
    or type(bundle.provenance) ~= "table"
  then
    Errors.raise(ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID, "bundle is incomplete", {})
  end
  local provenance = bundle.provenance
  if
    not Validate.isSha1Key(provenance.versionRomSha1)
    or not Validate.isSha1Key(provenance.dependencyHash)
    or type(provenance.dependencies) ~= "table"
    or type(provenance.source) ~= "table"
    or type(provenance.source.backgrounds) ~= "table"
    or provenance.source.backgrounds.alias ~= "apricorn_box_ui"
    or provenance.source.backgrounds.narcId ~= 220
    or provenance.source.backgrounds.path ~= "a/2/1/8"
    or type(provenance.source.resources) ~= "table"
    or provenance.source.resources.alias ~= "apricorn_box_resdat"
    or provenance.source.resources.narcId ~= 175
    or provenance.source.resources.path ~= "a/1/7/5"
  then
    Errors.raise(ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID, "bundle provenance is invalid", {})
  end
  if
    provenance.cacheFormat ~= ApricornBoxAssetCache.FORMAT
    or provenance.schema ~= ApricornBoxAssetCache.SCHEMA
    or ApricornBoxAssetCache.marker(provenance.versionRomSha1, provenance.dependencyHash) ~= bundle.marker
  then
    Errors.raise(ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID, "bundle provenance does not identify its marker", {})
  end
  if not ApricornBoxAssetCache.isManifestValid(bundle.manifest) then
    Errors.raise(ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID, "manifest is invalid", {})
  end
  local references = {}
  local referenceCount = 0
  for _, path in ipairs(ApricornBoxAssetCache.referencedPaths(bundle.manifest)) do
    references[path] = true
    referenceCount = referenceCount + 1
  end
  for path, bytes in pairs(bundle.assets) do
    if
      type(path) ~= "string"
      or not references[path]
      or type(bytes) ~= "string"
      or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n"
    then
      Errors.raise(
        ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID,
        "bundle carries an invalid or unused asset",
        { path = path }
      )
    end
  end
  local assetCount = 0
  for _ in pairs(bundle.assets) do
    assetCount = assetCount + 1
  end
  if assetCount ~= referenceCount then
    Errors.raise(ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID, "bundle asset set is incomplete or duplicated", {})
  end
  for path in pairs(references) do
    if bundle.assets[path] == nil then
      Errors.raise(ApricornBoxCacheWriter.ERROR.BUNDLE_INVALID, "bundle is missing a pane image", { path = path })
    end
  end
end

local function stageBundle(stage, bundle)
  for path, bytes in pairs(bundle.assets) do
    stage:write(path, bytes)
  end
  stage:writeLua(ApricornBoxAssetCache.manifestPath(), bundle.manifest)
  stage:writeLua(ApricornBoxAssetCache.provenancePath(), bundle.provenance)
  local manifest = stage:loadLua(ApricornBoxAssetCache.manifestPath())
  if not ApricornBoxAssetCache.isManifestValid(manifest) then
    Errors.raise(ApricornBoxCacheWriter.ERROR.READBACK_FAILED, "manifest readback is invalid", {})
  end
  for _, path in ipairs(ApricornBoxAssetCache.referencedPaths(manifest)) do
    if not stage:exists(path, "file") then
      Errors.raise(ApricornBoxCacheWriter.ERROR.READBACK_FAILED, "pane image is missing after stage", { path = path })
    end
  end
  stage:write(ApricornBoxAssetCache.markerPath(), bundle.marker)
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function ApricornBoxCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "Apricorn Box staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(ApricornBoxAssetCache.assetDir())
  artifact:addOwnedRoot(ApricornBoxAssetCache.dir())
  stageBundle(artifact:stageFs(), bundle)
  return bundle.marker
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return string
function ApricornBoxCacheWriter.write(cacheFs, bundle)
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "apricorn-box", {
    ApricornBoxAssetCache.assetDir(),
    ApricornBoxAssetCache.dir(),
  })
  local ok, err = pcall(stageBundle, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return bundle.marker
end

return ApricornBoxCacheWriter
