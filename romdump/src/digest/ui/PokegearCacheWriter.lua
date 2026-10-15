-- Stages one complete Pokegear family through the generation-owned
-- PreparedArtifact and publishes it through the shared staged-publication
-- lifecycle. The manifest, provenance, images, and completion marker stage
-- together with the marker last, so a staging failure before publication
-- preserves the live family.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCache = require("libs.assets.src.PokegearCache")

local PokegearCacheWriter = {}

PokegearCacheWriter.ERROR = {
  BUNDLE_INVALID = "POKEGEAR_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "POKEGEAR_CACHE_READBACK_FAILED",
}

function PokegearCacheWriter.isReady(cacheFs, marker)
  return PokegearCache.isReady(cacheFs, marker)
end

---@param bundle table<string, unknown>
local function validateBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(PokegearCacheWriter.ERROR.BUNDLE_INVALID, "pokegear bundle carries no marker", {})
  end
  if type(bundle.manifest) ~= "table" then
    Errors.raise(PokegearCacheWriter.ERROR.BUNDLE_INVALID, "pokegear bundle carries no manifest", {})
  end
  local assets = bundle.assets ~= nil and bundle.assets or bundle.files
  if type(assets) ~= "table" then
    Errors.raise(PokegearCacheWriter.ERROR.BUNDLE_INVALID, "pokegear bundle carries no assets", {})
  end
  local ok, schemaErr = pcall(PokegearAssetSchema.assertManifest, bundle.manifest)
  if not ok then
    Errors.raise(
      PokegearCacheWriter.ERROR.BUNDLE_INVALID,
      "pokegear manifest is invalid: " .. Errors.format(schemaErr),
      {}
    )
  end
  for _, path in ipairs(PokegearCache.referencedPaths(bundle.manifest)) do
    if assets[path] == nil then
      Errors.raise(
        PokegearCacheWriter.ERROR.BUNDLE_INVALID,
        "pokegear bundle is missing referenced asset " .. path,
        { path = path }
      )
    end
  end
end

---@param tx table<string, unknown>
---@param bundle table<string, unknown>
---@param cacheFs CacheFs
local function stageBundle(tx, bundle, cacheFs)
  local assets = bundle.assets ~= nil and bundle.assets or bundle.files
  assert(type(assets) == "table", "pokegear bundle assets are validated before staging")
  local stage = tx.stage
  for _, path in ipairs(PokegearCache.referencedPaths(bundle.manifest)) do
    stage:write(path, assets[path])
  end
  stage:writeLua(PokegearCache.manifestPath(), bundle.manifest)
  stage:writeLua(PokegearCache.provenancePath(), bundle.provenance or bundle.dependencies or {})
  local manifest = stage:loadLua(PokegearCache.manifestPath())
  local ok, err = pcall(PokegearAssetSchema.assertManifest, manifest)
  if not ok then
    Errors.raise(
      PokegearCacheWriter.ERROR.READBACK_FAILED,
      "pokegear manifest readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  for _, path in ipairs(PokegearCache.referencedPaths(manifest)) do
    local present = stage:exists(path, "file") or cacheFs:exists(path, "file")
    if not present then
      Errors.raise(
        PokegearCacheWriter.ERROR.READBACK_FAILED,
        "pokegear asset missing after stage: " .. path,
        { path = path }
      )
    end
  end
  stage:write(PokegearCache.markerPath(), bundle.marker)
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function PokegearCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "pokegear staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(PokegearCache.assetDir())
  artifact:addOwnedRoot(PokegearCache.dir())
  stageBundle({ stage = artifact:stageFs() }, bundle, artifact:cacheFs())
  return bundle.marker
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return boolean
function PokegearCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and bundle, "pokegear publication requires a cache and a bundle")
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "pokegear", { PokegearCache.assetDir(), PokegearCache.dir() })
  local ok, err = pcall(stageBundle, tx, bundle, cacheFs, cacheFs)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return PokegearCacheWriter
