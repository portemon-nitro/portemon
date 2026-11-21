-- Stages one complete Pokegear family through the generation-owned
-- PreparedArtifact and publishes it through the shared staged-publication
-- lifecycle. The manifest, provenance, images, and completion marker stage
-- together with the marker last, so a staging failure before publication
-- preserves the live family.

local Errors = require("libs.errors.src.Errors")
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

---@param stage PreparedArtifact the artifact's private output owner
---@param bundle table<string, unknown>
---@param cacheFs table<string, unknown> read-only dependency reader
local function stageBundle(stage, bundle, cacheFs)
  local assets = bundle.assets ~= nil and bundle.assets or bundle.files
  assert(type(assets) == "table", "pokegear bundle assets are validated before staging")
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
  -- Errors.raise always throws but carries no noreturn annotation, so the
  -- invalid-readback guard alone does not narrow; reaching here proves a table.
  assert(manifest ~= nil, "pokegear manifest readback is present after the invalid guard")
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
  assert(artifact and artifact.write, "pokegear staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(PokegearCache.assetDir())
  artifact:addOwnedRoot(PokegearCache.dir())
  stageBundle(artifact, bundle, artifact:cacheFs())
  return bundle.marker
end

return PokegearCacheWriter
