-- Paths and readiness for the independently generated Day Care care catalog:
-- the source PMS egg-species table, the personal egg-move list, and the source
-- incense pairs. The payload is one strict semantic record; readiness proves
-- the persisted payload still satisfies its schema. Runtime never reads the
-- ROM.

---@class PokemonCareCache
local PokemonCareCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")

PokemonCareCache.FORMAT = Contract.pokemonCare.cacheFormat
PokemonCareCache.CATALOG_SCHEMA = Contract.pokemonCare.catalogSchema

local DATA_DIR = "data/generated/pokemon-care"

function PokemonCareCache.dir()
  return DATA_DIR
end

function PokemonCareCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
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
  return PokemonCareAssetSchema.isValidCatalog(catalog)
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-catalog validation stays with the producer writer, schema
-- tests, and explicit audit (see isReady).
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
