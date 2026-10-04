-- Paths and readiness for the independently published PC asset family.

local Contract = require("libs.assets.src.DerivedAssetContract")
local PcAssetSchema = require("libs.assets.src.PcAssetSchema")

local PcCache = {}

PcCache.FORMAT = Contract.pc.cacheFormat
PcCache.SCHEMA = Contract.pc.schema

local DATA_DIR = "data/generated/pc"
local ASSET_DIR = "assets/generated/pc"

function PcCache.dir()
  return DATA_DIR
end

function PcCache.assetDir()
  return ASSET_DIR
end

function PcCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

function PcCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function PcCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param romSha1 string
---@param dependencyHash string
---@return string
function PcCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", PcCache.FORMAT, romSha1, dependencyHash)
end

---@param manifest table<string, unknown>
---@return string[]
function PcCache.referencedPaths(manifest)
  PcAssetSchema.assertManifest(manifest)
  local paths, seen = {}, {}
  local function collect(value)
    if type(value) ~= "table" then
      return
    end
    if value.image ~= nil then
      local image = value.image
      assert(type(image) == "string", "validated PC visual has an image path")
      if not seen[image] then
        seen[image] = true
        paths[#paths + 1] = image
      end
      return
    end
    for _, child in pairs(value) do
      collect(child)
    end
  end
  collect(manifest)
  return paths
end

---@param provenance table<string, unknown>?
---@param expectedMarker string
---@return boolean
local function validProvenance(provenance, expectedMarker)
  if
    type(provenance) ~= "table"
    or provenance.schema ~= PcCache.SCHEMA
    or provenance.cacheFormat ~= PcCache.FORMAT
    or type(provenance.versionRomSha1) ~= "string"
    or type(provenance.dependencyHash) ~= "string"
    or type(provenance.archives) ~= "table"
    or type(provenance.selections) ~= "table"
  then
    return false
  end
  local expected = {
    storage = { physical = 87, selected = 87 },
    mailbox = { physical = 11, selected = 11 },
    stationery = { physical = 37, selected = 36 },
    photoAlbum = { physical = 13, selected = 13 },
  }
  for key, counts in pairs(expected) do
    local archive = provenance.archives[key]
    if
      type(archive) ~= "table"
      or type(archive.path) ~= "string"
      or type(archive.fileId) ~= "number"
      or archive.fileId % 1 ~= 0
      or archive.memberCount ~= counts.physical
      or archive.selectedMemberCount ~= counts.selected
    then
      return false
    end
  end
  return expectedMarker == PcCache.marker(provenance.versionRomSha1, provenance.dependencyHash)
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function PcCache.isReady(cacheFs, expectedMarker)
  local marker = cacheFs:read(PcCache.markerPath())
  if
    type(marker) ~= "string"
    or type(expectedMarker) ~= "string"
    or marker ~= expectedMarker
    or marker:sub(1, #PcCache.FORMAT + 1) ~= PcCache.FORMAT .. ":"
  then
    return false
  end
  local manifest = cacheFs:loadLua(PcCache.manifestPath())
  if not PcAssetSchema.isValidManifest(manifest) then
    return false
  end
  local provenance = cacheFs:loadLua(PcCache.provenancePath())
  if not validProvenance(provenance, marker) then
    return false
  end
  local ok, paths = pcall(PcCache.referencedPaths, manifest)
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

function PcCache.validateManifest(manifest)
  return PcAssetSchema.assertManifest(manifest)
end

---@param cacheFs CacheFs
---@return table<string, unknown>
function PcCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(PcCache.manifestPath())
  PcAssetSchema.assertManifest(manifest)
  return manifest --[[@as table<string, unknown>]]
end

return PcCache
