-- Publishes a complete move-icons bundle through the shared staged-artifact
-- transaction. The family marker is written after payload readback succeeds.

local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Errors = require("libs.errors.src.Errors")
local MoveIconAssetSchema = require("libs.assets.src.MoveIconAssetSchema")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local Validate = require("libs.assets.src.Validate")

local MoveIconCacheWriter = {}

MoveIconCacheWriter.ERROR = {
  BUNDLE_INVALID = "MOVE_ICON_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "MOVE_ICON_CACHE_READBACK_FAILED",
}

function MoveIconCacheWriter.isReady(cacheFs, marker)
  return MoveIconCache.isReady(cacheFs, marker)
end

local function invalid(message, context)
  Errors.raise(MoveIconCacheWriter.ERROR.BUNDLE_INVALID, "move icon bundle " .. message, context or {})
end

local function validateBundle(bundle)
  if
    type(bundle) ~= "table"
    or type(bundle.marker) ~= "string"
    or type(bundle.manifest) ~= "table"
    or type(bundle.assets) ~= "table"
    or type(bundle.provenance) ~= "table"
  then
    invalid("is incomplete")
  end
  local provenance = bundle.provenance
  if
    provenance.cacheFormat ~= MoveIconCache.FORMAT
    or provenance.schema ~= MoveIconCache.SCHEMA
    or not Validate.isSha1Key(provenance.versionRomSha1)
    or not Validate.isSha1Key(provenance.dependencyHash)
    or type(provenance.dependencies) ~= "table"
    or type(provenance.source) ~= "table"
    or MoveIconCache.marker(provenance.versionRomSha1, provenance.dependencyHash) ~= bundle.marker
  then
    invalid("provenance does not identify its marker")
  end
  local ok, err = pcall(MoveIconAssetSchema.assertManifest, bundle.manifest)
  if not ok then
    invalid("manifest is invalid: " .. Errors.format(err))
  end
  local references = {}
  for _, path in ipairs(MoveIconCache.referencedPaths(bundle.manifest)) do
    references[path] = true
    if bundle.assets[path] == nil then
      invalid("is missing image " .. path, { path = path })
    end
  end
  for path, bytes in pairs(bundle.assets) do
    if not references[path] or type(bytes) ~= "string" or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
      invalid("carries an invalid or unreferenced image", { path = path })
    end
  end
end

local function stageBundle(stage, bundle)
  for path, bytes in pairs(bundle.assets) do
    stage:write(path, bytes)
  end
  stage:writeLua(MoveIconCache.manifestPath(), bundle.manifest)
  stage:writeLua(MoveIconCache.provenancePath(), bundle.provenance)
  local manifest = stage:loadLua(MoveIconCache.manifestPath())
  for _, path in ipairs(MoveIconCache.referencedPaths(manifest)) do
    if not stage:exists(path, "file") then
      Errors.raise(MoveIconCacheWriter.ERROR.READBACK_FAILED, "icon image is missing after stage", { path = path })
    end
  end
  stage:write(MoveIconCache.markerPath(), bundle.marker)
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function MoveIconCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "move icon staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(MoveIconCache.assetDir())
  artifact:addOwnedRoot(MoveIconCache.dir())
  stageBundle(artifact:stageFs(), bundle)
  return bundle.marker
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return string
function MoveIconCacheWriter.write(cacheFs, bundle)
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "move-icons", { MoveIconCache.assetDir(), MoveIconCache.dir() })
  local ok, err = pcall(stageBundle, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return bundle.marker
end

return MoveIconCacheWriter
