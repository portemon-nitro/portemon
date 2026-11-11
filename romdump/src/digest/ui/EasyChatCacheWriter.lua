-- Stages the two independent Easy Chat scopes through the
-- generation-owned PreparedArtifact and publishes them through the shared
-- staged-publication lifecycle. Data (catalog plus provenance and marker)
-- and presentation (manifest plus images, provenance, and marker) claim
-- exact non-overlapping owned files, write outputs and provenance, read
-- back through the normal generated readers, apply closed validation with
-- the completion marker last, so a staging failure before publication
-- preserves the live family.

local Errors = require("libs.errors.src.Errors")
local EasyChatAssetSchema = require("libs.assets.src.EasyChatAssetSchema")
local EasyChatCache = require("libs.assets.src.EasyChatCache")

local EasyChatCacheWriter = {}

EasyChatCacheWriter.ERROR = {
  BUNDLE_INVALID = "EASY_CHAT_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "EASY_CHAT_CACHE_READBACK_FAILED",
}

---@param data table<string, unknown>
local function validateDataBundle(data)
  if type(data) ~= "table" or type(data.marker) ~= "string" or data.marker == "" then
    Errors.raise(EasyChatCacheWriter.ERROR.BUNDLE_INVALID, "easy chat data bundle carries no marker", {})
  end
  local validated, schemaErr = EasyChatAssetSchema.validateCatalog(data)
  if validated == nil then
    Errors.raise(
      EasyChatCacheWriter.ERROR.BUNDLE_INVALID,
      "easy chat catalog is invalid: " .. Errors.format(schemaErr),
      {}
    )
  end
end

---@param bundle table<string, unknown>
local function validatePresentationBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(EasyChatCacheWriter.ERROR.BUNDLE_INVALID, "easy chat presentation bundle carries no marker", {})
  end
  if type(bundle.manifest) ~= "table" then
    Errors.raise(EasyChatCacheWriter.ERROR.BUNDLE_INVALID, "easy chat presentation bundle carries no manifest", {})
  end
  if type(bundle.assets) ~= "table" then
    Errors.raise(EasyChatCacheWriter.ERROR.BUNDLE_INVALID, "easy chat presentation bundle carries no assets", {})
  end
  local validated, schemaErr = EasyChatAssetSchema.validateManifest(bundle.manifest)
  if validated == nil then
    Errors.raise(
      EasyChatCacheWriter.ERROR.BUNDLE_INVALID,
      "easy chat manifest is invalid: " .. Errors.format(schemaErr),
      {}
    )
  end
  for _, path in ipairs(EasyChatCache.referencedPaths(bundle.manifest)) do
    if bundle.assets[path] == nil then
      Errors.raise(
        EasyChatCacheWriter.ERROR.BUNDLE_INVALID,
        "easy chat bundle is missing referenced asset " .. path,
        { path = path }
      )
    end
  end
end

---@param stage table<string, unknown>
---@param data table<string, unknown>
local function readbackData(stage, data)
  local catalog = stage:loadLua(EasyChatCache.catalogPath())
  local validated, err = EasyChatAssetSchema.validateCatalog(catalog)
  if validated == nil then
    Errors.raise(
      EasyChatCacheWriter.ERROR.READBACK_FAILED,
      "easy chat catalog readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  local provenance = stage:loadLua(EasyChatCache.provenancePath("data"))
  if type(provenance) ~= "table" then
    Errors.raise(EasyChatCacheWriter.ERROR.READBACK_FAILED, "easy chat data provenance is missing after stage", {})
  end
  if data.marker == nil or data.marker == "" then
    Errors.raise(EasyChatCacheWriter.ERROR.READBACK_FAILED, "easy chat data bundle lost its marker", {})
  end
end

---@param stage table<string, unknown>
---@param bundle table<string, unknown>
---@param liveFs table<string, unknown>
local function readbackPresentation(stage, bundle, liveFs)
  local manifest = stage:loadLua(EasyChatCache.manifestPath())
  local validated, err = EasyChatAssetSchema.validateManifest(manifest)
  if validated == nil then
    Errors.raise(
      EasyChatCacheWriter.ERROR.READBACK_FAILED,
      "easy chat manifest readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  for _, path in ipairs(EasyChatCache.referencedPaths(manifest)) do
    local present = stage:exists(path, "file") or liveFs:exists(path, "file")
    if not present then
      Errors.raise(
        EasyChatCacheWriter.ERROR.READBACK_FAILED,
        "easy chat asset missing after stage: " .. path,
        { path = path }
      )
    end
  end
  local provenance = stage:loadLua(EasyChatCache.provenancePath("presentation"))
  if type(provenance) ~= "table" then
    Errors.raise(
      EasyChatCacheWriter.ERROR.READBACK_FAILED,
      "easy chat presentation provenance is missing after stage",
      {}
    )
  end
  if bundle.marker == nil or bundle.marker == "" then
    Errors.raise(EasyChatCacheWriter.ERROR.READBACK_FAILED, "easy chat presentation bundle lost its marker", {})
  end
end

---@param artifact table<string, unknown>
---@param data table<string, unknown> compiled catalog with its marker and provenance
---@return string
function EasyChatCacheWriter.stageData(artifact, data)
  assert(artifact and artifact.stageFs, "easy chat staging requires a PreparedArtifact")
  validateDataBundle(data)
  artifact:addOwnedRoot(EasyChatCache.catalogPath())
  artifact:addOwnedRoot(EasyChatCache.provenancePath("data"))
  artifact:addOwnedRoot(EasyChatCache.dataMarkerPath())
  local stage = artifact:stageFs()
  local record = {}
  for key, value in pairs(data) do
    if key ~= "marker" and key ~= "provenance" and key ~= "dependencyHash" then
      record[key] = value
    end
  end
  stage:writeLua(EasyChatCache.catalogPath(), record)
  stage:writeLua(EasyChatCache.provenancePath("data"), data.provenance or {})
  readbackData(stage, data)
  stage:write(EasyChatCache.dataMarkerPath(), data.marker)
  return data.marker
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function EasyChatCacheWriter.stagePresentation(artifact, bundle)
  assert(artifact and artifact.stageFs, "easy chat staging requires a PreparedArtifact")
  local liveFs = artifact:cacheFs()
  validatePresentationBundle(bundle)
  artifact:addOwnedRoot(EasyChatCache.manifestPath())
  artifact:addOwnedRoot(EasyChatCache.provenancePath("presentation"))
  artifact:addOwnedRoot(EasyChatCache.markerPath())
  artifact:addOwnedRoot(EasyChatCache.assetDir())
  local stage = artifact:stageFs()
  for _, path in ipairs(EasyChatCache.referencedPaths(bundle.manifest)) do
    stage:write(path, bundle.assets[path])
  end
  stage:writeLua(EasyChatCache.manifestPath(), bundle.manifest)
  stage:writeLua(EasyChatCache.provenancePath("presentation"), bundle.provenance or {})
  readbackPresentation(stage, bundle, liveFs)
  stage:write(EasyChatCache.markerPath(), bundle.marker)
  return bundle.marker
end

return EasyChatCacheWriter
