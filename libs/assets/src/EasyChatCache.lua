-- Paths and readiness for the independently published Easy Chat family.
-- The semantic data scope (catalog plus its provenance and completion
-- marker) and the presentation scope (manifest plus its images,
-- provenance, and completion marker) stage through non-overlapping owned
-- files, so one scope never erases the other. Trusted runtime loads check
-- presence plus the current schema identity; whole-record validation
-- stays with the producer writers, schema tests, and explicit audit.

local Contract = require("libs.assets.src.DerivedAssetContract")

local EasyChatCache = {}

EasyChatCache.FORMAT = Contract.easyChat.cacheFormat
EasyChatCache.CATALOG_SCHEMA = Contract.easyChat.catalogSchema
EasyChatCache.SCHEMA = Contract.easyChat.schema

local DATA_DIR = "data/generated/easy-chat"
local ASSET_DIR = "assets/generated/easy-chat"

function EasyChatCache.dir()
  return DATA_DIR
end

function EasyChatCache.assetDir()
  return ASSET_DIR
end

function EasyChatCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end

function EasyChatCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

function EasyChatCache.dataMarkerPath()
  return DATA_DIR .. "/data.complete"
end

function EasyChatCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param scope string "data" or "presentation"
---@return string
function EasyChatCache.provenancePath(scope)
  assert(scope == "data" or scope == "presentation", "easy chat provenance scope must be data or presentation")
  if scope == "data" then
    return DATA_DIR .. "/data.provenance.lua"
  end
  return DATA_DIR .. "/presentation.provenance.lua"
end

---@param romSha1 string
---@param dependencyHash string
---@return string
function EasyChatCache.dataMarker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", EasyChatCache.FORMAT, romSha1, dependencyHash)
end

---@param romSha1 string
---@param dependencyHash string
---@return string
function EasyChatCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", EasyChatCache.FORMAT, romSha1, dependencyHash)
end

---@param node unknown
---@param out table<string, table<string, unknown>>
local function collectImagePaths(node, out)
  if type(node) ~= "table" then
    return
  end
  if type(node.image) == "string" then
    out[node.image] = node
    return
  end
  for key, value in pairs(node) do
    if key ~= "image" and type(value) == "table" then
      collectImagePaths(value, out)
    end
  end
end

---@param manifest table<string, unknown>
---@return string[]
function EasyChatCache.referencedPaths(manifest)
  assert(type(manifest) == "table", "easy chat referenced paths require a manifest")
  local paths, seen = {}, {}
  local found = {}
  collectImagePaths(manifest, found)
  for path in pairs(found) do
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

---@param cacheFs CacheFs
---@param path string
---@return boolean
local function hasPayload(cacheFs, path)
  return cacheFs:exists(path, "file")
end

-- Producer/audit readiness for the data scope: the expected marker is
-- current and the catalog plus data provenance payloads are present. The
-- catalog's schema identity is trusted here; full validation stays with
-- the producer writer and schema tests.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function EasyChatCache.isDataReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or expectedMarker == "" then
    return false
  end
  if cacheFs:read(EasyChatCache.dataMarkerPath()) ~= expectedMarker then
    return false
  end
  local catalog = cacheFs:loadLua(EasyChatCache.catalogPath())
  if type(catalog) ~= "table" or catalog.schema ~= EasyChatCache.CATALOG_SCHEMA then
    return false
  end
  return type(cacheFs:loadLua(EasyChatCache.provenancePath("data"))) == "table"
end

-- Producer/audit readiness for the presentation scope: the expected
-- marker is current, the manifest carries the current schema, its
-- provenance is present, and every referenced asset file exists.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function EasyChatCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or expectedMarker == "" then
    return false
  end
  if cacheFs:read(EasyChatCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(EasyChatCache.manifestPath())
  if type(manifest) ~= "table" or manifest.schema ~= EasyChatCache.SCHEMA then
    return false
  end
  if type(cacheFs:loadLua(EasyChatCache.provenancePath("presentation"))) ~= "table" then
    return false
  end
  local ok, paths = pcall(EasyChatCache.referencedPaths, manifest)
  if not ok then
    return false
  end
  for _, path in ipairs(paths) do
    if not hasPayload(cacheFs, path) then
      return false
    end
  end
  return true
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-catalog validation stays with the producer writer,
-- schema tests, and explicit audit (see isDataReady).
---@param cacheFs CacheFs
---@return table<string, unknown>
function EasyChatCache.loadCatalog(cacheFs)
  local catalog = cacheFs:loadLua(EasyChatCache.catalogPath())
  assert(
    type(catalog) == "table" and catalog.schema == EasyChatCache.CATALOG_SCHEMA,
    "easy chat catalog is unavailable"
  )
  return catalog --[[@as table<string, unknown>]]
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-manifest validation stays with the producer writer,
-- schema tests, and explicit audit (see isReady/referencedPaths).
---@param cacheFs CacheFs
---@return table<string, unknown>
function EasyChatCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(EasyChatCache.manifestPath())
  assert(type(manifest) == "table" and manifest.schema == EasyChatCache.SCHEMA, "easy chat manifest is unavailable")
  return manifest --[[@as table<string, unknown>]]
end

return EasyChatCache
