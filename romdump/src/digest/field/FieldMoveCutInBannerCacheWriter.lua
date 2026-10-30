-- Persists a compiled cut-in banner bundle through the shared staged
-- publication primitive: provenance, the manifest, and the generated PNG
-- are written into a disposable staging root, readback-validated there, and
-- only then is the completed stage published with the marker last. Staging
-- and validation are one step; publication happens outside that step's
-- error handler, so a publish failure never triggers writer-level stage
-- cleanup that could delete the last remaining copy of the previous class.

local Errors = require("libs.errors.src.Errors")
local FieldMoveCutInBannerAssetCache = require("libs.assets.src.field.FieldMoveCutInBannerAssetCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local FieldMoveCutInBannerCacheWriter = {}

function FieldMoveCutInBannerCacheWriter.isReady(cacheFs, marker)
  return FieldMoveCutInBannerAssetCache.isReady(cacheFs, marker)
end

local function stageBundle(stage, bundle)
  stage:writeLua(FieldMoveCutInBannerAssetCache.provenancePath(), {
    schema = "g4-field-move-cut-in-banner-provenance-v1",
    dependencies = bundle.dependencies,
  })
  for path, bytes in pairs(bundle.assets) do
    stage:write(path, bytes)
  end
  stage:writeLua(FieldMoveCutInBannerAssetCache.manifestPath(), bundle.manifest)
  local manifest = stage:loadLua(FieldMoveCutInBannerAssetCache.manifestPath())
  if type(manifest) ~= "table" or manifest.schema ~= FieldMoveCutInBannerAssetCache.SCHEMA then
    Errors.raise("FIELD_MOVE_CUT_IN_BANNER_CACHE_READBACK_FAILED", "banner manifest readback failed", {})
  end
  local typedManifest = manifest --[[@as FieldMoveCutInBannerAssetCache.Manifest]]
  local ok, err = FieldMoveCutInBannerAssetCache.validateManifest(typedManifest)
  if not ok then
    Errors.raise("FIELD_MOVE_CUT_IN_BANNER_CACHE_READBACK_FAILED", "banner manifest readback is invalid", {
      cause = err and err.message,
    })
  end
  for _, entry in pairs(typedManifest.assets) do
    if not stage:exists(entry.image, "file") then
      Errors.raise(
        "FIELD_MOVE_CUT_IN_BANNER_CACHE_READBACK_FAILED",
        "banner asset missing after stage: " .. entry.image,
        {
          image = entry.image,
        }
      )
    end
  end
  stage:write(FieldMoveCutInBannerAssetCache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function FieldMoveCutInBannerCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "banner staging requires a PreparedArtifact")
  assert(bundle and bundle.marker and bundle.manifest and bundle.assets, "stage requires a banner bundle")
  assert(bundle.manifest.schema == FieldMoveCutInBannerAssetCache.SCHEMA, "banner manifest schema mismatch")
  artifact:addOwnedRoot(FieldMoveCutInBannerAssetCache.assetDir())
  artifact:addOwnedRoot(FieldMoveCutInBannerAssetCache.dir())
  stageBundle(artifact:stageFs(), bundle)
  return bundle.marker
end

function FieldMoveCutInBannerCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.manifest and bundle.assets, "write requires a banner bundle")
  assert(bundle.manifest.schema == FieldMoveCutInBannerAssetCache.SCHEMA, "banner manifest schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "field-move-cut-in-banner", {
    FieldMoveCutInBannerAssetCache.assetDir(),
    FieldMoveCutInBannerAssetCache.dir(),
  })
  local ok, err = pcall(stageBundle, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return FieldMoveCutInBannerCacheWriter
