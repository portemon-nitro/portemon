-- Publishes the compiled hatch presentation through the existing care family:
-- the manifest and every staged image land under the hatch root and the
-- family's completion marker is written last, so a staging failure before
-- publication preserves the live family. Validation runs on both the bundle
-- and the readback, exactly like the other UI families.

local Errors = require("libs.errors.src.Errors")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")

---@class PokemonCareCacheWriter
local PokemonCareCacheWriter = {}

PokemonCareCacheWriter.ERROR = {
  BUNDLE_INVALID = "POKEMON_CARE_HATCH_BUNDLE_INVALID",
  READBACK_FAILED = "POKEMON_CARE_HATCH_READBACK_FAILED",
}

---@param bundle table<string, unknown>
local function validateBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.manifest) ~= "table" or type(bundle.assets) ~= "table" then
    Errors.raise(PokemonCareCacheWriter.ERROR.BUNDLE_INVALID, "hatch bundle carries its manifest and assets", {})
  end
  local ok, err = pcall(PokemonCareAssetSchema.assertHatchManifest, bundle.manifest)
  if not ok then
    Errors.raise(PokemonCareCacheWriter.ERROR.BUNDLE_INVALID, "hatch manifest is invalid: " .. Errors.format(err), {})
  end
  for _, path in ipairs(PokemonCareCache.referencedHatchPaths(bundle.manifest)) do
    if bundle.assets[path] == nil then
      Errors.raise(PokemonCareCacheWriter.ERROR.BUNDLE_INVALID, "hatch bundle is missing " .. path, { path = path })
    end
  end
end

-- Stages the catalogue the same family already carries plus this bundle. The
-- caller owns the artifact roots and the marker value.
---@param stage table<string, unknown>
---@param cacheFs CacheFs
---@param catalog table<string, unknown>
---@param bundle table<string, unknown>
local function stageBundle(stage, cacheFs, catalog, bundle)
  stage:writeLua(PokemonCareCache.catalogPath(), catalog)
  for _, path in ipairs(PokemonCareCache.referencedHatchPaths(bundle.manifest)) do
    assert(type(path) == "string" and path ~= "", "hatch asset paths are named")
    stage:write(path, assert(bundle.assets[path], "hatch asset staged"))
  end
  stage:writeLua(PokemonCareCache.hatchManifestPath(), bundle.manifest)
  local readback = stage:loadLua(PokemonCareCache.hatchManifestPath())
  local ok, err = pcall(PokemonCareAssetSchema.assertHatchManifest, readback)
  if not ok then
    Errors.raise(
      PokemonCareCacheWriter.ERROR.READBACK_FAILED,
      "hatch manifest readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  for _, path in ipairs(PokemonCareCache.referencedHatchPaths(readback)) do
    if not stage:exists(path, "file") and not cacheFs:exists(path, "file") then
      Errors.raise(PokemonCareCacheWriter.ERROR.READBACK_FAILED, "hatch asset missing after stage: " .. path, {
        path = path,
      })
    end
  end
end

-- Stages the care family's payloads into one prepared artifact and answers the
-- marker the caller publishes.
---@param artifact table<string, unknown>
---@param catalog table<string, unknown>
---@param bundle table<string, unknown>
---@param marker string
---@return string
function PokemonCareCacheWriter.stage(artifact, catalog, bundle, marker)
  assert(artifact and artifact.stageFs, "care staging requires a PreparedArtifact")
  assert(type(marker) == "string" and marker ~= "", "care staging requires its completion marker")
  validateBundle(bundle)
  artifact:addOwnedRoot(PokemonCareCache.dir())
  local stage = artifact:stageFs()
  stageBundle(stage, artifact:cacheFs(), catalog, bundle)
  stage:write(PokemonCareCache.markerPath(), marker)
  return marker
end

return PokemonCareCacheWriter
