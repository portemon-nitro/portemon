-- Publishes a complete bank keypad bundle through the shared staged-artifact
-- transaction. The family marker is written after payload readback succeeds.

local Errors = require("libs.errors.src.Errors")
local BankAssetSchema = require("libs.assets.src.BankAssetSchema")
local BankCache = require("libs.assets.src.BankCache")

local BankCacheWriter = {}

BankCacheWriter.ERROR = {
  BUNDLE_INVALID = "BANK_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "BANK_CACHE_READBACK_FAILED",
}

---@param cacheFs CacheFs
---@param marker string
---@return boolean
function BankCacheWriter.isReady(cacheFs, marker)
  return BankCache.isReady(cacheFs, marker)
end

local function validateBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(BankCacheWriter.ERROR.BUNDLE_INVALID, "bank bundle carries no marker", {})
  end
  if type(bundle.manifest) ~= "table" or type(bundle.assets) ~= "table" then
    Errors.raise(BankCacheWriter.ERROR.BUNDLE_INVALID, "bank bundle is incomplete", {})
  end
  if type(bundle.provenance) ~= "table" then
    Errors.raise(BankCacheWriter.ERROR.BUNDLE_INVALID, "bank bundle carries no provenance", {})
  end
  if
    bundle.provenance.cacheFormat ~= BankCache.FORMAT
    or bundle.provenance.schema ~= BankCache.SCHEMA
    or type(bundle.provenance.versionRomSha1) ~= "string"
    or type(bundle.provenance.dependencyHash) ~= "string"
    or BankCache.marker(bundle.provenance.versionRomSha1, bundle.provenance.dependencyHash) ~= bundle.marker
  then
    Errors.raise(BankCacheWriter.ERROR.BUNDLE_INVALID, "bank provenance does not identify its marker", {})
  end
  local ok, err = pcall(BankAssetSchema.validate, bundle.manifest)
  if not ok then
    Errors.raise(BankCacheWriter.ERROR.BUNDLE_INVALID, "bank manifest is invalid: " .. Errors.format(err), {})
  end
  local references = BankCache.referencedPaths(bundle.manifest)
  local referenced = {}
  for _, path in ipairs(references) do
    referenced[path] = true
  end
  for path, bytes in pairs(bundle.assets) do
    if
      type(path) ~= "string"
      or path:sub(1, #BankCache.assetDir() + 1) ~= BankCache.assetDir() .. "/"
      or path:find("..", 1, true)
      or type(bytes) ~= "string"
      or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n"
      or not referenced[path]
    then
      Errors.raise(BankCacheWriter.ERROR.BUNDLE_INVALID, "bank bundle carries an invalid or unreferenced image", {
        path = path,
      })
    end
  end
  for _, path in ipairs(references) do
    if bundle.assets[path] == nil then
      Errors.raise(BankCacheWriter.ERROR.BUNDLE_INVALID, "bank bundle is missing image " .. path, { path = path })
    end
  end
end

local function stageBundle(stage, bundle)
  for _, path in ipairs(BankCache.referencedPaths(bundle.manifest)) do
    stage:write(path, bundle.assets[path])
  end
  stage:writeLua(BankCache.manifestPath(), bundle.manifest)
  stage:writeLua(BankCache.provenancePath(), bundle.provenance)

  local manifest = stage:loadLua(BankCache.manifestPath())
  local ok, err = pcall(BankAssetSchema.validate, manifest)
  if not ok then
    Errors.raise(BankCacheWriter.ERROR.READBACK_FAILED, "bank manifest readback is invalid: " .. Errors.format(err), {})
  end
  local provenance = stage:loadLua(BankCache.provenancePath())
  if type(provenance) ~= "table" or provenance.cacheFormat ~= BankCache.FORMAT then
    Errors.raise(BankCacheWriter.ERROR.READBACK_FAILED, "bank provenance readback is invalid", {})
  end
  for _, path in ipairs(BankCache.referencedPaths(manifest)) do
    if not stage:exists(path, "file") then
      Errors.raise(BankCacheWriter.ERROR.READBACK_FAILED, "bank image missing after stage: " .. path, { path = path })
    end
  end
  stage:write(BankCache.markerPath(), bundle.marker)
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function BankCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.write, "bank staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(BankCache.assetDir())
  artifact:addOwnedRoot(BankCache.dir())
  stageBundle(artifact, bundle)
  return bundle.marker
end

return BankCacheWriter
