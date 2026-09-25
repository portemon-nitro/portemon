-- Publishes the compiled party presentation class through the shared
-- stage/validate/publish lifecycle. The party-owned manifest, images, and
-- completion marker stage under the family roots with the marker last, so a
-- staging failure before publication preserves the live family. Once
-- publication begins the shared publisher owns rollback, recovery, and
-- cleanup outcomes.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local PartyAssetSchema = require("libs.assets.src.PartyAssetSchema")
local PartyCache = require("libs.assets.src.PartyCache")

local PartyCacheWriter = {}

PartyCacheWriter.ERROR = {
  BUNDLE_INVALID = "PARTY_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "PARTY_CACHE_READBACK_FAILED",
}

function PartyCacheWriter.isReady(cacheFs, marker)
  return PartyCache.isReady(cacheFs, marker)
end

---@param bundle table<string, unknown>
local function validateBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(PartyCacheWriter.ERROR.BUNDLE_INVALID, "party bundle carries no marker", {})
  end
  if type(bundle.manifest) ~= "table" or type(bundle.assets) ~= "table" then
    Errors.raise(PartyCacheWriter.ERROR.BUNDLE_INVALID, "party bundle carries no manifest payload", {})
  end
  if type(bundle.dependencies) ~= "table" then
    Errors.raise(PartyCacheWriter.ERROR.BUNDLE_INVALID, "party bundle carries no dependency record", {})
  end
  if bundle.dependencies.cacheFormat ~= PartyCache.FORMAT or bundle.dependencies.schema ~= PartyCache.SCHEMA then
    Errors.raise(PartyCacheWriter.ERROR.BUNDLE_INVALID, "party bundle dependencies identify the wrong cache", {})
  end
  local ok, err = pcall(PartyAssetSchema.assertManifest, bundle.manifest)
  if not ok then
    Errors.raise(PartyCacheWriter.ERROR.BUNDLE_INVALID, "party manifest is invalid: " .. Errors.format(err), {})
  end
  for _, path in ipairs(PartyCache.referencedPaths(bundle.manifest)) do
    if bundle.assets[path] == nil then
      Errors.raise(
        PartyCacheWriter.ERROR.BUNDLE_INVALID,
        "party bundle is missing referenced asset " .. path,
        { path = path }
      )
    end
  end
end

---@param tx table<string, unknown>
---@param bundle table<string, unknown>
---@param cacheFs CacheFs
local function stageBundle(tx, bundle, cacheFs)
  local stage = tx.stage
  for _, path in ipairs(PartyCache.referencedPaths(bundle.manifest)) do
    if path:sub(1, #PartyCache.assetDir()) == PartyCache.assetDir() then
      stage:write(path, bundle.assets[path])
    else
      cacheFs:write(path, bundle.assets[path])
    end
  end
  stage:writeLua(PartyCache.provenancePath(), bundle.dependencies)
  stage:writeLua(PartyCache.manifestPath(), bundle.manifest)
  local dependencies = stage:loadLua(PartyCache.provenancePath())
  if
    type(dependencies) ~= "table"
    or dependencies.cacheFormat ~= PartyCache.FORMAT
    or dependencies.schema ~= PartyCache.SCHEMA
  then
    Errors.raise(PartyCacheWriter.ERROR.READBACK_FAILED, "party dependencies readback is invalid", {})
  end
  local manifest = stage:loadLua(PartyCache.manifestPath())
  local ok, err = pcall(PartyAssetSchema.assertManifest, manifest)
  if not ok then
    Errors.raise(
      PartyCacheWriter.ERROR.READBACK_FAILED,
      "party manifest readback is invalid: " .. Errors.format(err),
      {}
    )
  end
  for _, path in ipairs(PartyCache.referencedPaths(manifest)) do
    local present = stage:exists(path, "file") or cacheFs:exists(path, "file")
    if not present then
      Errors.raise(PartyCacheWriter.ERROR.READBACK_FAILED, "party asset missing after stage: " .. path, { path = path })
    end
  end
  stage:write(PartyCache.markerPath(), bundle.marker)
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function PartyCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "party staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(PartyCache.assetDir())
  artifact:addOwnedRoot(PartyCache.dir())
  for _, path in ipairs(PartyCache.referencedPaths(bundle.manifest)) do
    if path:sub(1, #PartyCache.assetDir()) ~= PartyCache.assetDir() then
      artifact:addSharedFile(path)
    end
  end
  stageBundle({ stage = artifact:stageFs() }, bundle, artifact:cacheFs())
  return bundle.marker
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return boolean
function PartyCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and bundle, "party publication requires a cache and a bundle")
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "party", { PartyCache.assetDir(), PartyCache.dir() })
  local ok, err = pcall(stageBundle, tx, bundle, cacheFs)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return PartyCacheWriter
