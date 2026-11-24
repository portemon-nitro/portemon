-- Authoritative validation for the generated Day Care care catalog: the source
-- PMS egg-species table, the personal egg-move list, and the source incense
-- pairs. The catalog carries normalized semantic meaning only; native ids and
-- archive offsets stay producer-side. Runtime trusts published artifacts and
-- must not duplicate this validation. Unknown fields, dangling shells, and
-- duplicated entries fail loudly.

local Contract = require("libs.assets.src.DerivedAssetContract")
local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

---@class PokemonCareAssetSchema
local PokemonCareAssetSchema = {}

PokemonCareAssetSchema.CATALOG_SCHEMA = Contract.pokemonCare.catalogSchema

local CATALOG_ERROR = "POKEMON_CARE_CATALOG_INVALID"
local fail = SchemaCheck.fail

local CATALOG_FIELDS = { schema = true, eggSpecies = true, eggMoves = true, incense = true }
local INCENSE_FIELDS = { baby = true, item = true, parent = true }

---@param value unknown
---@param what string
---@return table
local function requireRecord(value, what)
  if type(value) ~= "table" then
    fail(CATALOG_ERROR, what .. " must be a record", {})
  end
  assert(type(value) == "table")
  return value
end

---@param value unknown
---@param what string
---@param count integer?
---@return table
local function requireArray(value, what, count)
  if not Validate.isArray(value) or (count ~= nil and #value ~= count) then
    fail(
      CATALOG_ERROR,
      what .. (count and (" must contain exactly " .. count .. " entries") or " must be a contiguous array"),
      {}
    )
  end
  assert(type(value) == "table")
  return value
end

function PokemonCareAssetSchema.assertCatalog(catalog)
  local context = {}
  requireRecord(catalog, "care catalog")
  SchemaCheck.checkKeys(catalog, CATALOG_FIELDS, context, CATALOG_ERROR, "care catalog")
  if catalog.schema ~= PokemonCareAssetSchema.CATALOG_SCHEMA then
    fail(CATALOG_ERROR, "care catalog schema is not current", {})
  end

  local eggSpecies = requireRecord(catalog.eggSpecies, "eggSpecies")
  if next(eggSpecies) == nil then
    fail(CATALOG_ERROR, "eggSpecies must name at least one species", {})
  end
  for motherKey, eggKey in pairs(eggSpecies) do
    SchemaCheck.checkNonEmptyString(motherKey, context, CATALOG_ERROR, "eggSpecies key")
    SchemaCheck.checkNonEmptyString(eggKey, context, CATALOG_ERROR, "eggSpecies." .. tostring(motherKey))
  end

  -- The source breeding list is authoritative and repeats a move inside some
  -- species blocks, so the catalog keeps its exact order and duplicates; the
  -- runtime skips a move the offspring already knows.
  local eggMoves = requireRecord(catalog.eggMoves, "eggMoves")
  for speciesKey, moves in pairs(eggMoves) do
    SchemaCheck.checkNonEmptyString(speciesKey, context, CATALOG_ERROR, "eggMoves key")
    requireArray(moves, "eggMoves." .. speciesKey)
    if #moves == 0 then
      fail(CATALOG_ERROR, "eggMoves." .. speciesKey .. " must name at least one move", {})
    end
    for _, moveKey in ipairs(moves) do
      SchemaCheck.checkNonEmptyString(moveKey, context, CATALOG_ERROR, "eggMoves." .. speciesKey .. " move")
    end
  end

  local incense = requireArray(catalog.incense, "incense")
  if #incense == 0 then
    fail(CATALOG_ERROR, "incense must carry the source pairs", {})
  end
  local seenBabies = {}
  for index, row in ipairs(incense) do
    local what = "incense[" .. index .. "]"
    requireRecord(row, what)
    assert(type(row) == "table")
    SchemaCheck.checkKeys(row, INCENSE_FIELDS, context, CATALOG_ERROR, what)
    for _, field in ipairs({ "baby", "item", "parent" }) do
      SchemaCheck.checkNonEmptyString(row[field], context, CATALOG_ERROR, what .. "." .. field)
    end
    if seenBabies[row.baby] then
      fail(CATALOG_ERROR, what .. " repeats the baby " .. row.baby, {})
    end
    seenBabies[row.baby] = true
  end
  return true
end

---@param catalog unknown
---@return boolean
function PokemonCareAssetSchema.isValidCatalog(catalog)
  return pcall(PokemonCareAssetSchema.assertCatalog, catalog)
end

return PokemonCareAssetSchema
