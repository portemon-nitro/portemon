-- Paths and readiness for the independently generated Day Care care family:
-- the source PMS egg-species table, the personal egg-move list, and the source
-- incense pairs, plus the hatch application's own generated presentation with
-- its staged images. Each payload is one strict record; readiness proves both
-- persisted payloads still satisfy their schemas. Runtime never reads the ROM.

---@class PokemonCareCache
local PokemonCareCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")

PokemonCareCache.FORMAT = Contract.pokemonCare.cacheFormat
PokemonCareCache.CATALOG_SCHEMA = Contract.pokemonCare.catalogSchema
PokemonCareCache.HATCH_SCHEMA = Contract.pokemonCare.hatchSchema

local DATA_DIR = "data/generated/pokemon-care"
local HATCH_DIR = DATA_DIR .. "/hatch"

function PokemonCareCache.dir()
  return DATA_DIR
end

function PokemonCareCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end

-- The hatch presentation's own directory: its manifest and every staged image
-- it references live under this one owned root.
function PokemonCareCache.hatchDir()
  return HATCH_DIR
end

function PokemonCareCache.hatchManifestPath()
  return HATCH_DIR .. "/manifest.lua"
end

-- Every staged image the hatch manifest references, in a stable order so the
-- presentation lease requests the same set on every open.
---@param manifest table<string, unknown>
---@return string[] paths
function PokemonCareCache.referencedHatchPaths(manifest)
  assert(type(manifest) == "table", "hatch paths require the manifest")
  local paths = {}
  local seen = {}
  local function add(path)
    assert(type(path) == "string" and path ~= "", "hatch images carry their staged path")
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  local background = assert(manifest.background) --[[@as table]]
  add(assert(background.image) --[[@as string]])
  for _, groupKey in ipairs({ "egg", "bars" }) do
    local group = assert(manifest[groupKey]) --[[@as table]]
    local frames = assert(group.frames) --[[@as table]]
    for _, frame in ipairs(frames) do
      add(assert(frame.image) --[[@as string]])
    end
  end
  local particles = assert(manifest.particles) --[[@as table]]
  for _, variant in ipairs({ "egg", "manaphy" }) do
    local set = assert(particles[variant]) --[[@as table]]
    local textures = assert(set.textures) --[[@as table]]
    for _, texture in ipairs(textures) do
      add(assert(texture.image) --[[@as string]])
    end
  end
  table.sort(paths)
  return paths
end

function PokemonCareCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param versionRomSha1 string
---@param dependencyHash string
---@return string
function PokemonCareCache.marker(versionRomSha1, dependencyHash)
  return string.format("%s:%s:%s", PokemonCareCache.FORMAT, versionRomSha1, dependencyHash)
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function PokemonCareCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or cacheFs:read(PokemonCareCache.markerPath()) ~= expectedMarker then
    return false
  end
  local ok, catalog = pcall(cacheFs.loadLua, cacheFs, PokemonCareCache.catalogPath())
  if not ok then
    return false
  end
  if not PokemonCareAssetSchema.isValidCatalog(catalog) then
    return false
  end
  local manifestOk, manifest = pcall(cacheFs.loadLua, cacheFs, PokemonCareCache.hatchManifestPath())
  if not manifestOk then
    return false
  end
  return PokemonCareAssetSchema.isValidHatchManifest(manifest)
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-catalog validation stays with the producer writer, schema
-- tests, and explicit audit (see isReady).
-- Trusted runtime load of the hatch presentation manifest. Presence plus the
-- current schema identity is sufficient; whole-manifest validation stays with
-- the producer writer and schema tests.
---@param cacheFs CacheFs
---@return table<string, unknown>
function PokemonCareCache.loadHatchManifest(cacheFs)
  local manifest = cacheFs:loadLua(PokemonCareCache.hatchManifestPath())
  assert(
    type(manifest) == "table" and manifest.schema == PokemonCareCache.HATCH_SCHEMA,
    "the hatch presentation manifest is unavailable"
  )
  return manifest
end

---@param cacheFs CacheFs
---@return table<string, unknown>
function PokemonCareCache.loadCatalog(cacheFs)
  local catalog = cacheFs:loadLua(PokemonCareCache.catalogPath())
  assert(
    type(catalog) == "table" and catalog.schema == PokemonCareCache.CATALOG_SCHEMA,
    "the Day Care care catalog is unavailable"
  )
  return catalog
end

return PokemonCareCache
