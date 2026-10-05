-- Tests sorted copied key views of the mon catalog.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function assertKeysEqual(expected, actual)
  Assert.equal(#expected, #actual)
  for index, key in ipairs(expected) do
    Assert.equal(key, actual[index])
  end
end

local function assertOrderedByNativeId(keys, lookup)
  local previousId = -1
  for _, key in ipairs(keys) do
    local nativeId = lookup(key).nativeId
    Assert.isTrue(nativeId > previousId, "keys must follow sparse native identity order")
    previousId = nativeId
  end
end

function T.species_and_move_key_views_are_sorted_copies()
  local catalog = CatalogFixture.makeCatalog()
  local species = catalog:speciesKeys()
  local moves = catalog:moveKeys()
  local expectedSpecies = { "EEVEE", "CHIKORITA", "TOTODILE", "SHEDINJA" }
  local expectedMoves = {
    "SCRATCH", "CUT", "SAND_ATTACK", "TACKLE", "TAIL_WHIP", "LEER", "GROWL", "WATER_GUN",
    "RAZOR_LEAF", "POISONPOWDER", "TOXIC", "QUICK_ATTACK", "HARDEN", "REFLECT", "SYNTHESIS",
    "BULLET_SEED",
  }
  assertKeysEqual(expectedSpecies, species)
  assertKeysEqual(expectedMoves, moves)
  assertOrderedByNativeId(species, function(key)
    return catalog:species(key)
  end)
  assertOrderedByNativeId(moves, function(key)
    return catalog:move(key)
  end)

  species[1] = "changed"
  moves[1] = "changed"
  assertKeysEqual(expectedSpecies, catalog:speciesKeys())
  assertKeysEqual(expectedMoves, catalog:moveKeys())
end

return { tests = T }
