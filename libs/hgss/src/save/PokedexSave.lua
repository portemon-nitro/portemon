-- Persisted Pokedex knowledge bucket: sorted seen/caught species arrays
-- over the resolved game content. Validation checks shape plus selected
-- references only: every listed species must resolve in the provided
-- species set, but the bucket never asserts whole-catalog equality, so
-- unrelated content changes keep old knowledge loading. Pure data owner:
-- no live state, no love dependency.

local Errors = require("libs.errors.src.Errors")

---@class PokedexSave
local PokedexSave = {}

PokedexSave.SCHEMA = "hgss-pokedex-v1"
PokedexSave.STATE_VERSION = 1

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise("POKEDEX_INVALID", message, context)
end

---@param bucket unknown
---@return table<string, unknown>
local function checkShape(bucket)
  if type(bucket) ~= "table" then
    fail("dex bucket must be a table", {})
  end
  assert(type(bucket) == "table", "shape validation reads the bucket record")
  for key in pairs(bucket) do
    if key ~= "schema" and key ~= "stateVersion" and key ~= "seen" and key ~= "caught" then
      fail("dex bucket contains an unknown field", { field = key })
    end
  end
  if bucket.schema ~= PokedexSave.SCHEMA then
    fail("dex schema must be " .. PokedexSave.SCHEMA, { schema = bucket.schema })
  end
  if bucket.stateVersion ~= PokedexSave.STATE_VERSION then
    fail("dex bucket carries an incompatible state version", { stateVersion = bucket.stateVersion })
  end
  for _, key in ipairs({ "seen", "caught" }) do
    if type(bucket[key]) ~= "table" then
      fail("dex bucket " .. key .. " must be an array", {})
    end
  end
  return bucket
end

---@param bucket table<string, unknown>
---@param refs { species: table<string, boolean> }
---@return table<string, unknown>
function PokedexSave.validate(bucket, refs)
  local shaped = checkShape(bucket)
  if type(refs) ~= "table" or type(refs.species) ~= "table" then
    fail("dex validation requires a species reference set", {})
  end
  assert(type(refs) == "table" and type(refs.species) == "table", "reference checks read the species set")
  local canonical = { schema = PokedexSave.SCHEMA, stateVersion = PokedexSave.STATE_VERSION, seen = {}, caught = {} }
  for _, key in ipairs({ "seen", "caught" }) do
    local known = {}
    for _, species in ipairs(shaped[key]) do
      if type(species) ~= "string" or refs.species[species] ~= true then
        fail("dex bucket " .. key .. " names an unknown species", { species = species })
      end
      if known[species] == true then
        fail("dex bucket " .. key .. " names a duplicate species", { species = species })
      end
      known[species] = true
      canonical[key][#canonical[key] + 1] = species
    end
  end
  return canonical
end

---@return table<string, unknown> the defined source initial state
function PokedexSave.initial()
  return { schema = PokedexSave.SCHEMA, stateVersion = PokedexSave.STATE_VERSION, seen = {}, caught = {} }
end

return PokedexSave
