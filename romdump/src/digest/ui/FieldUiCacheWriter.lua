-- Persists a compiled field-UI bundle through the shared staged
-- publication primitive: provenance, the manifest, and every generated image
-- are written into a disposable staging root, readback-validated there, and
-- only then is the completed stage published with the marker last. A compiled
-- image record defers its PNG encode and write to the owning job's
-- low-priority continuation in the same stage; a direct write encodes it here.
-- Staging and validation are one step; publication happens outside that
-- step's error handler, so a publish failure never triggers writer-level stage
-- cleanup that could delete the last remaining copy of the previous class.

local Errors = require("libs.errors.src.Errors")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")

local FieldUiCacheWriter = {}

function FieldUiCacheWriter.isReady(cacheFs, marker)
  return FieldUiAssetCache.isReady(cacheFs, marker)
end

-- The staged copy of an image record is not written yet: its continuation owns
-- that file, so readback accepts the pending registration instead.
local function deferAssets(artifact, bundle)
  local stage = artifact
  for path, asset in pairs(bundle.assets) do
    if type(asset) == "table" then
      artifact:deferImage(path, asset.width, asset.height, asset.pixels)
    else
      stage:write(path, asset)
    end
  end
end

local function finishStage(stage, bundle, present)
  stage:writeLua(FieldUiAssetCache.provenancePath(), {
    schema = "g4-field-ui-provenance-v1",
    dependencies = bundle.dependencies,
  })
  stage:writeLua(FieldUiAssetCache.manifestPath(), bundle.manifest)
  local manifest = stage:loadLua(FieldUiAssetCache.manifestPath())
  if type(manifest) ~= "table" or manifest.schema ~= FieldUiAssetCache.SCHEMA then
    Errors.raise("FIELD_UI_CACHE_READBACK_FAILED", "ui manifest readback failed", {})
  end
  local typedManifest = manifest --[[@as FieldUiAssetCache.Manifest]]
  local ok, err = FieldUiAssetCache.validateManifest(typedManifest)
  if not ok then
    Errors.raise("FIELD_UI_CACHE_READBACK_FAILED", "ui manifest readback is invalid", { cause = err and err.message })
  end
  for _, entry in pairs(typedManifest.assets) do
    if not present(entry.image) then
      Errors.raise("FIELD_UI_CACHE_READBACK_FAILED", "ui asset missing after stage: " .. entry.image, {
        image = entry.image,
      })
    end
  end
  stage:write(FieldUiAssetCache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function FieldUiCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.write, "field-ui staging requires a PreparedArtifact")
  assert(bundle and bundle.marker and bundle.manifest and bundle.assets, "stage requires a UI bundle")
  assert(bundle.manifest.schema == FieldUiAssetCache.SCHEMA, "ui manifest schema mismatch")
  artifact:addOwnedRoot(FieldUiAssetCache.assetDir())
  artifact:addOwnedRoot(FieldUiAssetCache.dir())
  deferAssets(artifact, bundle)
  finishStage(artifact, bundle, function(image)
    return artifact:hasDeferredImage(image) or artifact:exists(image, "file")
  end)
  return bundle.marker
end

return FieldUiCacheWriter
