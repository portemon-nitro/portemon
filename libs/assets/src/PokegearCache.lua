-- Paths and readiness for the independently published Pokegear asset family.

local Contract = require("libs.assets.src.DerivedAssetContract")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")

local PokegearCache = {}

PokegearCache.FORMAT = Contract.pokegear.cacheFormat
PokegearCache.SCHEMA = Contract.pokegear.schema

local DATA_DIR = "data/generated/pokegear"
local ASSET_DIR = "assets/generated/pokegear"

function PokegearCache.dir()
  return DATA_DIR
end

function PokegearCache.assetDir()
  return ASSET_DIR
end

function PokegearCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

function PokegearCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function PokegearCache.markerPath()
  return DATA_DIR .. "/complete"
end

-- The separately published single-word entry section stages beside the
-- core family without joining its manifest: its own section, provenance,
-- and completion marker keep core readiness independent.
function PokegearCache.wordEntryManifestPath()
  return DATA_DIR .. "/word-entry.lua"
end

function PokegearCache.wordEntryProvenancePath()
  return DATA_DIR .. "/word-entry-provenance.lua"
end

function PokegearCache.wordEntryMarkerPath()
  return DATA_DIR .. "/word-entry-complete"
end

---@param romSha1 string
---@param dependencyHash string
---@return string
function PokegearCache.wordEntryMarker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", PokegearCache.FORMAT, romSha1, dependencyHash)
end

---@param section table<string, unknown>
---@return string[]
function PokegearCache.wordEntryReferencedPaths(section)
  local validated, err = PokegearAssetSchema.validateWordEntry(section)
  if validated == nil then
    error(err, 0)
  end
  local paths, seen = {}, {}
  local cursor = validated.cursor --[[@as table<string, unknown>]]
  local sequences = cursor.sequences --[[@as table]]
  for _, sequence in ipairs(sequences) do
    local frames = sequence.frames --[[@as table]]
    for _, frame in ipairs(frames) do
      local image = frame.image
      assert(type(image) == "string", "validated word-entry frames have image paths")
      if not seen[image] then
        seen[image] = true
        paths[#paths + 1] = image
      end
    end
  end
  return paths
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function PokegearCache.isWordEntryReady(cacheFs, expectedMarker)
  local marker = cacheFs:read(PokegearCache.wordEntryMarkerPath())
  if
    type(marker) ~= "string"
    or type(expectedMarker) ~= "string"
    or marker ~= expectedMarker
    or marker:sub(1, #PokegearCache.FORMAT + 1) ~= PokegearCache.FORMAT .. ":"
  then
    return false
  end
  local section = cacheFs:loadLua(PokegearCache.wordEntryManifestPath())
  if PokegearAssetSchema.validateWordEntry(section) == nil then
    return false
  end
  local provenance = cacheFs:loadLua(PokegearCache.wordEntryProvenancePath())
  if type(provenance) ~= "table" then
    return false
  end
  local ok, paths = pcall(PokegearCache.wordEntryReferencedPaths, section)
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

---@param romSha1 string
---@param dependencyHash string
---@return string
function PokegearCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", PokegearCache.FORMAT, romSha1, dependencyHash)
end

---@param manifest table<string, unknown>
---@return string[]
function PokegearCache.referencedPaths(manifest)
  PokegearAssetSchema.assertManifest(manifest)
  local paths, seen = {}, {}
  local function collect(value)
    if type(value) ~= "table" then
      return
    end
    if value.image ~= nil then
      local image = value.image
      assert(type(image) == "string", "validated pokegear visual has an image path")
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

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function PokegearCache.isReady(cacheFs, expectedMarker)
  local marker = cacheFs:read(PokegearCache.markerPath())
  if
    type(marker) ~= "string"
    or type(expectedMarker) ~= "string"
    or marker ~= expectedMarker
    or marker:sub(1, #PokegearCache.FORMAT + 1) ~= PokegearCache.FORMAT .. ":"
  then
    return false
  end
  local manifest = cacheFs:loadLua(PokegearCache.manifestPath())
  if not PokegearAssetSchema.isValidManifest(manifest) then
    return false
  end
  local provenance = cacheFs:loadLua(PokegearCache.provenancePath())
  if type(provenance) ~= "table" then
    return false
  end
  local ok, paths = pcall(PokegearCache.referencedPaths, manifest)
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

function PokegearCache.validateManifest(manifest)
  return PokegearAssetSchema.assertManifest(manifest)
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-manifest validation stays with the producer writers,
-- schema tests, and explicit audit (see isReady/referencedPaths).
---@param cacheFs CacheFs
---@return table<string, unknown>
function PokegearCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(PokegearCache.manifestPath())
  assert(type(manifest) == "table" and manifest.schema == PokegearCache.SCHEMA, "pokegear manifest is unavailable")
  return manifest --[[@as table<string, unknown>]]
end

return PokegearCache
