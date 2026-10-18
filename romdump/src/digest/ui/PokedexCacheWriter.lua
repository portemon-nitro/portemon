-- Stages the two independent Pokedex scopes through the generation-owned
-- PreparedArtifact and publishes them through the shared staged-publication
-- lifecycle. Data (catalog plus provenance and marker) and presentation
-- (manifest plus images, provenance, and marker) claim exact
-- non-overlapping owned files, write outputs and provenance, read back
-- through the normal generated readers, apply closed validation with the
-- completion marker last, so a staging failure before publication preserves
-- the live family.

local Errors = require("libs.errors.src.Errors")
local PokedexAssetSchema = require("libs.assets.src.PokedexAssetSchema")
local PokedexCache = require("libs.assets.src.PokedexCache")

local PokedexCacheWriter = {}

PokedexCacheWriter.ERROR = {
  BUNDLE_INVALID = "POKEDEX_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "POKEDEX_CACHE_READBACK_FAILED",
}

---@param cacheFs table<string, unknown>
---@return table<string, unknown>?
local function loadMonCatalogOrNil(cacheFs)
  if cacheFs == nil or type(cacheFs.loadLua) ~= "function" then
    return nil
  end
  local MonCache = require("libs.assets.src.MonCache")
  local ok, catalog = pcall(MonCache.loadCatalog, cacheFs)
  if not ok or type(catalog) ~= "table" then
    return nil
  end
  return catalog --[[@as table<string, unknown>]]
end

---@param bundle table<string, unknown>
---@param monCatalog table<string, unknown>?
local function validateDataBundle(bundle, monCatalog)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(PokedexCacheWriter.ERROR.BUNDLE_INVALID, "pokedex data bundle carries no marker", {})
  end
  if type(bundle.catalog) ~= "table" then
    Errors.raise(PokedexCacheWriter.ERROR.BUNDLE_INVALID, "pokedex data bundle carries no catalog", {})
  end
  if type(bundle.assets) ~= "table" then
    Errors.raise(PokedexCacheWriter.ERROR.BUNDLE_INVALID, "pokedex data bundle carries no assets", {})
  end
  local validated, schemaErr = PokedexAssetSchema.validateCatalog(bundle.catalog, monCatalog)
  if validated == nil then
    Errors.raise(
      PokedexCacheWriter.ERROR.BUNDLE_INVALID,
      "pokedex catalog is invalid: " .. Errors.format(schemaErr),
      {}
    )
  end
end

---@param bundle table<string, unknown>
---@param catalog table<string, unknown>
local function validatePresentationBundle(bundle, catalog)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(PokedexCacheWriter.ERROR.BUNDLE_INVALID, "pokedex presentation bundle carries no marker", {})
  end
  if type(bundle.manifest) ~= "table" then
    Errors.raise(PokedexCacheWriter.ERROR.BUNDLE_INVALID, "pokedex presentation bundle carries no manifest", {})
  end
  if type(bundle.assets) ~= "table" then
    Errors.raise(PokedexCacheWriter.ERROR.BUNDLE_INVALID, "pokedex presentation bundle carries no assets", {})
  end
  local validated, schemaErr = PokedexAssetSchema.validateManifest(bundle.manifest, catalog)
  if validated == nil then
    Errors.raise(
      PokedexCacheWriter.ERROR.BUNDLE_INVALID,
      "pokedex manifest is invalid: " .. Errors.format(schemaErr),
      {}
    )
  end
  for _, path in ipairs(PokedexCache.referencedPaths(bundle.manifest)) do
    if bundle.assets[path] == nil then
      Errors.raise(
        PokedexCacheWriter.ERROR.BUNDLE_INVALID,
        "pokedex bundle is missing referenced asset " .. path,
        { path = path }
      )
    end
  end
end

---@param stage table<string, unknown>
---@param bundle table<string, unknown>
---@param liveFs table<string, unknown>
local function readbackData(stage, bundle, liveFs)
  local catalog = stage:loadLua(PokedexCache.catalogPath())
  local monCatalog = loadMonCatalogOrNil(liveFs)
  local validated, err = PokedexAssetSchema.validateCatalog(catalog, monCatalog)
  if validated == nil then
    Errors.raise(
      PokedexCacheWriter.ERROR.READBACK_FAILED,
      "pokedex catalog readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  local provenance = stage:loadLua(PokedexCache.provenancePath("data"))
  if type(provenance) ~= "table" then
    Errors.raise(PokedexCacheWriter.ERROR.READBACK_FAILED, "pokedex data provenance is missing after stage", {})
  end
  if bundle.marker == nil or bundle.marker == "" then
    Errors.raise(PokedexCacheWriter.ERROR.READBACK_FAILED, "pokedex data bundle lost its marker", {})
  end
end

---@param stage table<string, unknown>
---@param bundle table<string, unknown>
---@param liveFs table<string, unknown>
local function readbackPresentation(stage, bundle, liveFs)
  local manifest = stage:loadLua(PokedexCache.manifestPath())
  local catalog = PokedexCache.loadCatalog(liveFs)
  local validated, err = PokedexAssetSchema.validateManifest(manifest, catalog)
  if validated == nil then
    Errors.raise(
      PokedexCacheWriter.ERROR.READBACK_FAILED,
      "pokedex manifest readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  for _, path in ipairs(PokedexCache.referencedPaths(manifest)) do
    local present = stage:exists(path, "file") or liveFs:exists(path, "file")
    if not present then
      Errors.raise(
        PokedexCacheWriter.ERROR.READBACK_FAILED,
        "pokedex asset missing after stage: " .. path,
        { path = path }
      )
    end
  end
  local provenance = stage:loadLua(PokedexCache.provenancePath("presentation"))
  if type(provenance) ~= "table" then
    Errors.raise(PokedexCacheWriter.ERROR.READBACK_FAILED, "pokedex presentation provenance is missing after stage", {})
  end
  if bundle.marker == nil or bundle.marker == "" then
    Errors.raise(PokedexCacheWriter.ERROR.READBACK_FAILED, "pokedex presentation bundle lost its marker", {})
  end
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function PokedexCacheWriter.stageData(artifact, bundle)
  assert(artifact and artifact.stageFs, "pokedex staging requires a PreparedArtifact")
  local liveFs = artifact:cacheFs()
  validateDataBundle(bundle, loadMonCatalogOrNil(liveFs))
  artifact:addOwnedRoot(PokedexCache.catalogPath())
  artifact:addOwnedRoot(PokedexCache.provenancePath("data"))
  artifact:addOwnedRoot(PokedexCache.dataMarkerPath())
  local stage = artifact:stageFs()
  stage:writeLua(PokedexCache.catalogPath(), bundle.catalog)
  stage:writeLua(PokedexCache.provenancePath("data"), bundle.provenance or {})
  readbackData(stage, bundle, liveFs)
  stage:write(PokedexCache.dataMarkerPath(), bundle.marker)
  return bundle.marker
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function PokedexCacheWriter.stagePresentation(artifact, bundle)
  assert(artifact and artifact.stageFs, "pokedex staging requires a PreparedArtifact")
  local liveFs = artifact:cacheFs()
  local catalog = PokedexCache.loadCatalog(liveFs)
  validatePresentationBundle(bundle, catalog)
  artifact:addOwnedRoot(PokedexCache.manifestPath())
  artifact:addOwnedRoot(PokedexCache.provenancePath("presentation"))
  artifact:addOwnedRoot(PokedexCache.markerPath())
  artifact:addOwnedRoot(PokedexCache.assetDir())
  local stage = artifact:stageFs()
  for _, path in ipairs(PokedexCache.referencedPaths(bundle.manifest)) do
    stage:write(path, bundle.assets[path])
  end
  stage:writeLua(PokedexCache.manifestPath(), bundle.manifest)
  stage:writeLua(PokedexCache.provenancePath("presentation"), bundle.provenance or {})
  readbackPresentation(stage, bundle, liveFs)
  stage:write(PokedexCache.markerPath(), bundle.marker)
  return bundle.marker
end

return PokedexCacheWriter
