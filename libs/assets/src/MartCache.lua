-- Paths and readiness for the independently generated mart data and
-- presentation family. Readiness verifies the persisted contracts, their
-- provenance-derived marker, and every manifest image before exposing data.

---@class MartCache
local MartCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local MartAssetSchema = require("libs.assets.src.MartAssetSchema")
local Validate = require("libs.assets.src.Validate")

MartCache.FORMAT = Contract.mart.cacheFormat
MartCache.CATALOG_SCHEMA = Contract.mart.catalogSchema
MartCache.SCHEMA = Contract.mart.schema

local DATA_DIR = "data/generated/mart"
local ASSET_DIR = "assets/generated/mart"

function MartCache.dir()
  return DATA_DIR
end

function MartCache.assetDir()
  return ASSET_DIR
end

function MartCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end

function MartCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

function MartCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function MartCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param versionRomSha1 string
---@param dependencyHash string
---@return string
function MartCache.marker(versionRomSha1, dependencyHash)
  return string.format("%s:%s:%s", MartCache.FORMAT, versionRomSha1, dependencyHash)
end

-- The manifest has already passed its schema before traversal. Every image
-- is family-owned; borrowed item icons remain in the item provider and are
-- not duplicated in this presentation contract.
---@param manifest table<string, unknown>
---@return string[]
function MartCache.referencedPaths(manifest)
  local paths = {}
  local seen = {}
  local function visit(value)
    if type(value) ~= "table" then
      return
    end
    if type(value.image) == "string" then
      local path = value.image
      local prefix = ASSET_DIR .. "/"
      assert(path:sub(1, #prefix) == prefix, "mart image path must be family-relative")
      assert(not path:find("..", 1, true), "mart image path must not traverse its family")
      if not seen[path] then
        paths[#paths + 1] = path
        seen[path] = true
      end
    end
    for _, child in pairs(value) do
      visit(child)
    end
  end
  visit(manifest)
  table.sort(paths)
  return paths
end

local function provenanceMatches(provenance, expectedMarker)
  if type(provenance) ~= "table" then
    return false
  end
  for key in pairs(provenance) do
    if
      key ~= "cacheFormat"
      and key ~= "catalogSchema"
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
    provenance.cacheFormat ~= MartCache.FORMAT
    or provenance.catalogSchema ~= MartCache.CATALOG_SCHEMA
    or provenance.schema ~= MartCache.SCHEMA
    or not Validate.isSha1Key(provenance.versionRomSha1)
    or not Validate.isSha1Key(provenance.dependencyHash)
    or type(provenance.source) ~= "table"
    or type(provenance.dependencies) ~= "table"
  then
    return false
  end
  return MartCache.marker(provenance.versionRomSha1, provenance.dependencyHash) == expectedMarker
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function MartCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or cacheFs:read(MartCache.markerPath()) ~= expectedMarker then
    return false
  end
  local catalog = cacheFs:loadLua(MartCache.catalogPath())
  if not MartAssetSchema.isValidCatalog(catalog) then
    return false
  end
  local manifest = cacheFs:loadLua(MartCache.manifestPath())
  if not MartAssetSchema.isValidManifest(manifest) then
    return false
  end
  local provenance = cacheFs:loadLua(MartCache.provenancePath())
  local matches, result = pcall(provenanceMatches, provenance, expectedMarker)
  if not matches or not result then
    return false
  end
  local ok, paths = pcall(MartCache.referencedPaths, manifest)
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

-- Trusted runtime loads: presence plus the current schema identity is
-- sufficient. Whole-catalog/manifest validation stays with the producer
-- writers, schema tests, and explicit audit (see isReady).
---@param cacheFs CacheFs
---@return table<string, unknown>
function MartCache.loadCatalog(cacheFs)
  local catalog = cacheFs:loadLua(MartCache.catalogPath())
  assert(type(catalog) == "table" and catalog.schema == MartCache.CATALOG_SCHEMA, "mart catalog is unavailable")
  return catalog
end

---@param cacheFs CacheFs
---@return table<string, unknown>
function MartCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(MartCache.manifestPath())
  assert(type(manifest) == "table" and manifest.schema == MartCache.SCHEMA, "mart manifest is unavailable")
  return manifest
end

return MartCache
