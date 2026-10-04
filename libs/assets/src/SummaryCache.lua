-- Readiness and paths for the derived summary presentation cache. The
-- summary class is one independently rebuildable derived class (manifest,
-- background/stamp/picture images, geometry/text/picture/ribbon/
-- performance/dex/memo records, registration markers): changing the
-- summary compilers must not disturb the raw ROM dump or any other
-- compiled class. A class is ready only when the completion marker matches
-- exactly and the manifest plus every referenced artifact is present with
-- the expected schema, so a partial build never reads as complete.
-- Species portraits stay in the mon class; the summary manifest references
-- no portrait pixels.
-- Paths are cache-relative; all IO goes through a CacheFs.

---@class SummaryCache
local SummaryCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local SummaryAssetSchema = require("libs.assets.src.SummaryAssetSchema")

SummaryCache.FORMAT = Contract.summary.cacheFormat
SummaryCache.SCHEMA = Contract.summary.schema

local DATA_DIR = "data/generated/summary"
local ASSET_DIR = "assets/generated/summary"

function SummaryCache.dir()
  return DATA_DIR
end
function SummaryCache.assetDir()
  return ASSET_DIR
end
function SummaryCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end
function SummaryCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function SummaryCache.markerPath()
  return DATA_DIR .. "/complete"
end

function SummaryCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", SummaryCache.FORMAT, romSha1, depHash)
end

-- Every cache-relative path the manifest references: each image leaf the
-- manifest names, enumerated once and sorted. Manifest pictures resolve
-- either through a mon portrait selector (owned by the mon class) or
-- through a family-owned visual below; only the family-owned images
-- participate in readiness.
---@param manifest table<string, unknown>
---@return string[]
function SummaryCache.referencedPaths(manifest)
  SummaryAssetSchema.assertManifest(manifest)
  local seen = {}
  local function add(path)
    if seen[path] == nil then
      seen[path] = true
    end
  end
  local function scan(value)
    if type(value) == "string" then
      if value:sub(-4) == ".png" then
        add(value)
      end
    elseif type(value) == "table" then
      for _, child in pairs(value) do
        scan(child)
      end
    end
  end
  scan(manifest)
  local paths = {}
  for path in pairs(seen) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  return paths
end

-- True only when the marker is exact, the manifest loads with the expected
-- schema, and every referenced artifact is present.
function SummaryCache.isReady(cacheFs, expectedMarker)
  local marker = cacheFs:read(SummaryCache.markerPath())
  if
    type(marker) ~= "string"
    or type(expectedMarker) ~= "string"
    or marker ~= expectedMarker
    or marker:sub(1, #SummaryCache.FORMAT + 1) ~= SummaryCache.FORMAT .. ":"
  then
    return false
  end
  local manifest = cacheFs:loadLua(SummaryCache.manifestPath())
  if not SummaryAssetSchema.isValidManifest(manifest) then
    return false
  end
  local provenance = cacheFs:loadLua(SummaryCache.provenancePath())
  if
    type(provenance) ~= "table"
    or provenance.cacheFormat ~= SummaryCache.FORMAT
    or provenance.schema ~= SummaryCache.SCHEMA
  then
    return false
  end
  local ok, paths = pcall(SummaryCache.referencedPaths, manifest)
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

function SummaryCache.validateManifest(manifest)
  return SummaryAssetSchema.assertManifest(manifest)
end

function SummaryCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(SummaryCache.manifestPath())
  SummaryAssetSchema.assertManifest(manifest)
  return manifest
end

return SummaryCache
