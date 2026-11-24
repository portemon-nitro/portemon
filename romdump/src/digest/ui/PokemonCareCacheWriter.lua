-- Publishes the compiled care presentations through the existing care family:
-- the hatch and trade manifests with every staged image land under their own
-- roots and the family's completion marker is written last, so a staging
-- failure before publication preserves the live family. Validation runs on both
-- bundles and the readback, exactly like the other UI families.

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
---@param namespace string
---@param validate fun(manifest: table<string, unknown>)
---@param referenced fun(manifest: table<string, unknown>): string[]
local function validateBundle(bundle, namespace, validate, referenced)
  if type(bundle) ~= "table" or type(bundle.manifest) ~= "table" or type(bundle.assets) ~= "table" then
    Errors.raise(PokemonCareCacheWriter.ERROR.BUNDLE_INVALID, namespace .. " bundle carries its manifest and assets", {})
  end
  local ok, err = pcall(validate, bundle.manifest)
  if not ok then
    Errors.raise(
      PokemonCareCacheWriter.ERROR.BUNDLE_INVALID,
      namespace .. " manifest is invalid: " .. Errors.format(err),
      {}
    )
  end
  for _, path in ipairs(referenced(bundle.manifest)) do
    if bundle.assets[path] == nil then
      Errors.raise(PokemonCareCacheWriter.ERROR.BUNDLE_INVALID, namespace .. " bundle is missing " .. path, {
        path = path,
      })
    end
  end
end

-- Stages one care presentation: its own staged images, its manifest, and the
-- readback the caller publishes under.
---@param stage table<string, unknown>
---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@param manifestPath string
---@param validate fun(manifest: table<string, unknown>)
---@param referenced fun(manifest: table<string, unknown>): string[]
---@param namespace string
local function stageManifest(stage, cacheFs, bundle, manifestPath, validate, referenced, namespace)
  for _, path in ipairs(referenced(bundle.manifest)) do
    assert(type(path) == "string" and path ~= "", namespace .. " asset paths are named")
    stage:write(path, assert(bundle.assets[path], namespace .. " asset staged"))
  end
  stage:writeLua(manifestPath, bundle.manifest)
  local readback = stage:loadLua(manifestPath)
  local ok, err = pcall(validate, readback)
  if not ok then
    Errors.raise(
      PokemonCareCacheWriter.ERROR.READBACK_FAILED,
      namespace .. " manifest readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  for _, path in ipairs(referenced(readback)) do
    if not stage:exists(path, "file") and not cacheFs:exists(path, "file") then
      Errors.raise(PokemonCareCacheWriter.ERROR.READBACK_FAILED, namespace .. " asset missing after stage: " .. path, {
        path = path,
      })
    end
  end
end

-- Stages the catalogue the same family already carries plus every generated
-- presentation. The caller owns the artifact roots and the marker value.
---@param stage table<string, unknown>
---@param cacheFs CacheFs
---@param catalog table<string, unknown>
---@param hatch table<string, unknown>
---@param trade table<string, unknown>
---@param reminder table<string, unknown>
local function stageBundle(stage, cacheFs, catalog, hatch, trade, reminder)
  stage:writeLua(PokemonCareCache.catalogPath(), catalog)
  stageManifest(
    stage,
    cacheFs,
    hatch,
    PokemonCareCache.hatchManifestPath(),
    PokemonCareAssetSchema.assertHatchManifest,
    PokemonCareCache.referencedHatchPaths,
    "hatch"
  )
  stageManifest(
    stage,
    cacheFs,
    trade,
    PokemonCareCache.tradeManifestPath(),
    PokemonCareAssetSchema.assertTradeManifest,
    PokemonCareCache.tradeStagedPaths,
    "trade"
  )
  stageManifest(
    stage,
    cacheFs,
    reminder,
    PokemonCareCache.reminderManifestPath(),
    PokemonCareAssetSchema.assertReminderManifest,
    PokemonCareCache.referencedReminderPaths,
    "reminder"
  )
end

-- Stages the care family's payloads into one prepared artifact and answers the
-- marker the caller publishes.
---@param artifact table<string, unknown>
---@param catalog table<string, unknown>
---@param hatch table<string, unknown>
---@param trade table<string, unknown>
---@param reminder table<string, unknown>
---@param marker string
---@return string
function PokemonCareCacheWriter.stage(artifact, catalog, hatch, trade, reminder, marker)
  assert(artifact and artifact.stageFs, "care staging requires a PreparedArtifact")
  assert(type(marker) == "string" and marker ~= "", "care staging requires its completion marker")
  validateBundle(
    hatch,
    "hatch",
    PokemonCareAssetSchema.assertHatchManifest,
    PokemonCareCache.referencedHatchPaths
  )
  validateBundle(
    trade,
    "trade",
    PokemonCareAssetSchema.assertTradeManifest,
    PokemonCareCache.tradeStagedPaths
  )
  validateBundle(
    reminder,
    "reminder",
    PokemonCareAssetSchema.assertReminderManifest,
    PokemonCareCache.referencedReminderPaths
  )
  artifact:addOwnedRoot(PokemonCareCache.dir())
  local stage = artifact:stageFs()
  stageBundle(stage, artifact:cacheFs(), catalog, hatch, trade, reminder)
  stage:write(PokemonCareCache.markerPath(), marker)
  return marker
end

return PokemonCareCacheWriter
