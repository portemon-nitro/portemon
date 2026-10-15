-- Paths, completion marker, and readiness of the generated move-icons
-- artifact: the type and damage-category icon sprites shared by every move
-- presentation. The images live under assets/generated/move-icons, the one
-- place a mod replaces them.

local Contract = require("libs.assets.src.DerivedAssetContract")
local Validate = require("libs.assets.src.Validate")

---@class MoveIconCache
local MoveIconCache = {}

MoveIconCache.FORMAT = Contract.moveIcons.cacheFormat
MoveIconCache.SCHEMA = Contract.moveIcons.schema

MoveIconCache.TYPE_KEYS = {
  "normal",
  "fighting",
  "flying",
  "poison",
  "ground",
  "rock",
  "bug",
  "ghost",
  "steel",
  "mystery",
  "fire",
  "water",
  "grass",
  "electric",
  "psychic",
  "ice",
  "dragon",
  "dark",
}
MoveIconCache.CATEGORY_KEYS = { "physical", "special", "status" }

local DATA_DIR = "data/generated/move-icons"
local ASSET_DIR = "assets/generated/move-icons"

function MoveIconCache.dir()
  return DATA_DIR
end

function MoveIconCache.assetDir()
  return ASSET_DIR
end

function MoveIconCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

function MoveIconCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function MoveIconCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param romSha1 string
---@param dependencyHash string
---@return string
function MoveIconCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", MoveIconCache.FORMAT, romSha1, dependencyHash)
end

---@param manifest table<string, unknown>
---@return string[] every image path the manifest references, sorted
function MoveIconCache.referencedPaths(manifest)
  local paths = {}
  for _, set in ipairs({ manifest.types, manifest.categories }) do
    for _, visual in pairs(set) do
      paths[#paths + 1] = visual.image
    end
  end
  table.sort(paths)
  return paths
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function MoveIconCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or cacheFs:read(MoveIconCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(MoveIconCache.manifestPath())
  if type(manifest) ~= "table" or manifest.schema ~= MoveIconCache.SCHEMA then
    return false
  end
  local provenance = cacheFs:loadLua(MoveIconCache.provenancePath())
  if
    type(provenance) ~= "table"
    or provenance.cacheFormat ~= MoveIconCache.FORMAT
    or provenance.schema ~= MoveIconCache.SCHEMA
    or not Validate.isSha1Key(provenance.versionRomSha1)
    or not Validate.isSha1Key(provenance.dependencyHash)
    or MoveIconCache.marker(provenance.versionRomSha1, provenance.dependencyHash) ~= expectedMarker
    or type(provenance.dependencies) ~= "table"
    or #provenance.dependencies == 0
  then
    return false
  end
  local ok, paths = pcall(MoveIconCache.referencedPaths, manifest)
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

---@param cacheFs CacheFs
---@return table<string, unknown>
function MoveIconCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(MoveIconCache.manifestPath())
  assert(type(manifest) == "table" and manifest.schema == MoveIconCache.SCHEMA, "the move icon manifest is unavailable")
  ---@cast manifest table<string, unknown>
  return manifest
end

return MoveIconCache
