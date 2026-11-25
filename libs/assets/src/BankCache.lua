-- Paths and readiness for the independently generated bank keypad family.
-- Readiness verifies the persisted schemas, their provenance marker and every
-- manifest image before exposing the presentation.

---@class BankCache
local BankCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local Validate = require("libs.assets.src.Validate")

BankCache.FORMAT = Contract.bank.cacheFormat
BankCache.SCHEMA = Contract.bank.schema

local DATA_DIR = "data/generated/bank"
local ASSET_DIR = "assets/generated/bank"

---@return string
function BankCache.dir()
  return DATA_DIR
end

---@return string
function BankCache.assetDir()
  return ASSET_DIR
end

---@return string
function BankCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

---@return string
function BankCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

---@return string
function BankCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param versionRomSha1 string
---@param dependencyHash string
---@return string
function BankCache.marker(versionRomSha1, dependencyHash)
  return string.format("%s:%s:%s", BankCache.FORMAT, versionRomSha1, dependencyHash)
end

---@param manifest table<string, unknown>
---@return string[]
function BankCache.referencedPaths(manifest)
  local BankAssetSchema = require("libs.assets.src.BankAssetSchema")
  local paths = BankAssetSchema.referencedPaths(manifest)
  local prefix = ASSET_DIR .. "/"
  for _, path in ipairs(paths) do
    assert(path:sub(1, #prefix) == prefix, "bank image path must be family-relative")
    assert(not path:find("..", 1, true), "bank image path must not traverse its family")
  end
  return paths
end

local function provenanceMatches(provenance, expectedMarker)
  if type(provenance) ~= "table" then
    return false
  end
  for key in pairs(provenance) do
    if
      key ~= "cacheFormat"
      and key ~= "schema"
      and key ~= "versionRomSha1"
      and key ~= "source"
      and key ~= "dependencies"
      and key ~= "dependencyHash"
    then
      return false
    end
  end
  if
    provenance.cacheFormat ~= BankCache.FORMAT
    or provenance.schema ~= BankCache.SCHEMA
    or not Validate.isSha1Key(provenance.versionRomSha1)
    or not Validate.isSha1Key(provenance.dependencyHash)
    or type(provenance.source) ~= "table"
    or type(provenance.dependencies) ~= "table"
  then
    return false
  end
  return BankCache.marker(provenance.versionRomSha1, provenance.dependencyHash) == expectedMarker
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function BankCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or cacheFs:read(BankCache.markerPath()) ~= expectedMarker then
    return false
  end
  local BankAssetSchema = require("libs.assets.src.BankAssetSchema")
  local manifest = cacheFs:loadLua(BankCache.manifestPath())
  if type(manifest) ~= "table" or manifest.schema ~= BankCache.SCHEMA then
    return false
  end
  local valid, _ = BankAssetSchema.check(manifest)
  if not valid then
    return false
  end
  local provenance = cacheFs:loadLua(BankCache.provenancePath())
  local matches, result = pcall(provenanceMatches, provenance, expectedMarker)
  if not matches or not result then
    return false
  end
  local ok, paths = pcall(BankCache.referencedPaths, manifest)
  if not ok then
    return false
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path, "file") then
      return false
    end
  end
  return true
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-manifest validation stays with the producer writer, the
-- schema tests and explicit audit (see isReady).
---@param cacheFs CacheFs
---@return table<string, unknown>
function BankCache.loadManifest(cacheFs)
  local BankAssetSchema = require("libs.assets.src.BankAssetSchema")
  local manifest = cacheFs:loadLua(BankCache.manifestPath())
  assert(type(manifest) == "table" and manifest.schema == BankCache.SCHEMA, "bank presentation is unavailable")
  return assert(BankAssetSchema.validate(manifest))
end

return BankCache
