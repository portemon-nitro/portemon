-- Paths and readiness for the independently published Pokedex family. The
-- semantic data scope (catalog plus its provenance and completion marker)
-- and the presentation scope (manifest plus its images, provenance, and
-- completion marker) stage through non-overlapping owned files, so one
-- scope never erases the other. Trusted runtime loads check presence plus
-- the current schema identity; whole-manifest validation stays with the
-- producer writers, schema tests, and explicit audit.

local Contract = require("libs.assets.src.DerivedAssetContract")

local PokedexCache = {}

PokedexCache.FORMAT = Contract.pokedex.cacheFormat
PokedexCache.CATALOG_SCHEMA = Contract.pokedex.catalogSchema
PokedexCache.SCHEMA = Contract.pokedex.schema

local DATA_DIR = "data/generated/pokedex"
local ASSET_DIR = "assets/generated/pokedex"

function PokedexCache.dir()
  return DATA_DIR
end

function PokedexCache.assetDir()
  return ASSET_DIR
end

function PokedexCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end

function PokedexCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end

function PokedexCache.dataMarkerPath()
  return DATA_DIR .. "/data.complete"
end

function PokedexCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param scope string "data" or "presentation"
---@return string
function PokedexCache.provenancePath(scope)
  assert(scope == "data" or scope == "presentation", "pokedex provenance scope must be data or presentation")
  if scope == "data" then
    return DATA_DIR .. "/data.provenance.lua"
  end
  return DATA_DIR .. "/presentation.provenance.lua"
end

---@param romSha1 string
---@param dependencyHash string
---@return string
function PokedexCache.dataMarker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", PokedexCache.FORMAT, romSha1, dependencyHash)
end

---@param romSha1 string
---@param dependencyHash string
---@return string
function PokedexCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", PokedexCache.FORMAT, romSha1, dependencyHash)
end

---@param manifest table<string, unknown>
---@return string[]
function PokedexCache.referencedPaths(manifest)
  assert(type(manifest) == "table", "pokedex referenced paths require a manifest")
  local chrome = manifest.chrome
  assert(type(chrome) == "table", "pokedex referenced paths require the chrome inventory")
  local paths, seen = {}, {}
  for role, record in pairs(chrome) do
    assert(type(record) == "table", "pokedex chrome record is not a table: " .. tostring(role))
    local path = record.path
    assert(type(path) == "string" and path ~= "", "pokedex chrome record carries no path: " .. tostring(role))
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

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
function PokedexCache.isDataReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or expectedMarker == "" then
    return false
  end
  if cacheFs:read(PokedexCache.dataMarkerPath()) ~= expectedMarker then
    return false
  end
  local catalog = cacheFs:loadLua(PokedexCache.catalogPath())
  if type(catalog) ~= "table" or catalog.schema ~= PokedexCache.CATALOG_SCHEMA then
    return false
  end
  return type(cacheFs:loadLua(PokedexCache.provenancePath("data"))) == "table"
end

-- Producer/audit readiness for the presentation scope: the expected
-- marker is current, the manifest carries the current schema, its
-- provenance is present, and every referenced asset file exists.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function PokedexCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or expectedMarker == "" then
    return false
  end
  if cacheFs:read(PokedexCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(PokedexCache.manifestPath())
  if type(manifest) ~= "table" or manifest.schema ~= PokedexCache.SCHEMA then
    return false
  end
  if type(cacheFs:loadLua(PokedexCache.provenancePath("presentation"))) ~= "table" then
    return false
  end
  local ok, paths = pcall(PokedexCache.referencedPaths, manifest)
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
function PokedexCache.loadCatalog(cacheFs)
  local catalog = cacheFs:loadLua(PokedexCache.catalogPath())
  assert(type(catalog) == "table" and catalog.schema == PokedexCache.CATALOG_SCHEMA, "pokedex catalog is unavailable")
  return catalog --[[@as table<string, unknown>]]
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-manifest validation stays with the producer writer,
-- schema tests, and explicit audit (see isReady).
---@param cacheFs CacheFs
---@return table<string, unknown>
function PokedexCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(PokedexCache.manifestPath())
  assert(type(manifest) == "table" and manifest.schema == PokedexCache.SCHEMA, "pokedex manifest is unavailable")
  return manifest --[[@as table<string, unknown>]]
end

return PokedexCache
