-- Paths, completion marker, and readiness of the generated Apricorn Box artifact.

local Contract = require("libs.assets.src.DerivedAssetContract")
local Validate = require("libs.assets.src.Validate")

local ApricornBoxAssetCache = {}

ApricornBoxAssetCache.FORMAT = Contract.apricornBox.cacheFormat
ApricornBoxAssetCache.SCHEMA = Contract.apricornBox.schema

local DATA_DIR = "data/generated/apricorn-box"
local ASSET_DIR = "assets/generated/apricorn-box"

function ApricornBoxAssetCache.dir()
  return DATA_DIR
end

function ApricornBoxAssetCache.assetDir()
  return ASSET_DIR
end

function ApricornBoxAssetCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

function ApricornBoxAssetCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function ApricornBoxAssetCache.markerPath()
  return DATA_DIR .. "/complete"
end

function ApricornBoxAssetCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", ApricornBoxAssetCache.FORMAT, romSha1, dependencyHash)
end

---@param manifest table<string, unknown>
---@return string[]
function ApricornBoxAssetCache.referencedPaths(manifest)
  local paths = {
    manifest.upper.image,
    manifest.lower.image,
    manifest.actionMenu.image,
    manifest.selectionCursor.image,
  }
  for _, sequence in pairs(manifest.selectionCursor.states) do
    for _, frame in ipairs(sequence.frames) do
      paths[#paths + 1] = frame.image
    end
  end
  for _, row in ipairs(manifest.rows) do
    for _, frame in ipairs(row.icon.frames) do
      paths[#paths + 1] = frame.image
    end
  end
  table.sort(paths)
  return paths
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function ApricornBoxAssetCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or cacheFs:read(ApricornBoxAssetCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(ApricornBoxAssetCache.manifestPath())
  if type(manifest) ~= "table" or manifest.schema ~= ApricornBoxAssetCache.SCHEMA then
    return false
  end
  local provenance = cacheFs:loadLua(ApricornBoxAssetCache.provenancePath())
  if
    type(provenance) ~= "table"
    or provenance.cacheFormat ~= ApricornBoxAssetCache.FORMAT
    or provenance.schema ~= ApricornBoxAssetCache.SCHEMA
    or not Validate.isSha1Key(provenance.versionRomSha1)
    or not Validate.isSha1Key(provenance.dependencyHash)
    or ApricornBoxAssetCache.marker(provenance.versionRomSha1, provenance.dependencyHash) ~= expectedMarker
    or type(provenance.dependencies) ~= "table"
    or #provenance.dependencies == 0
  then
    return false
  end
  ---@cast manifest table<string, unknown>
  for _, path in ipairs(ApricornBoxAssetCache.referencedPaths(manifest)) do
    if not cacheFs:exists(path, "file") then
      return false
    end
  end
  return true
end

---@param cacheFs CacheFs
---@return table<string, unknown>
function ApricornBoxAssetCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(ApricornBoxAssetCache.manifestPath())
  assert(type(manifest) == "table", "Apricorn Box presentation manifest is unavailable")
  ---@cast manifest table<string, unknown>
  return manifest
end

return ApricornBoxAssetCache
