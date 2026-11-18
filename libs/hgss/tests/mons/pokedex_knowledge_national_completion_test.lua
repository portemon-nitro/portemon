-- National dex completion follows the explicit required caught set:
-- mythical-named keys can never substitute for a missing required member.
local Assert = require("tests.support.Assert")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local T = {}

function T.national_completion_excludes_all_nine_mythicals_at_the_484_species_boundary()
  local mythicals = {
    "MEW",
    "CELEBI",
    "JIRACHI",
    "DEOXYS",
    "PHIONE",
    "MANAPHY",
    "DARKRAI",
    "SHAYMIN",
    "ARCEUS",
  }
  local required = {}
  local extra = {}
  for index = 1, 484 do
    local key = string.format("REQUIRED_%03d", index)
    required[index] = key
    extra[#extra + 1] = key
  end
  for _, key in ipairs(mythicals) do
    extra[#extra + 1] = key
  end

  local knowledge =
    PokedexKnowledge.new(PokedexDexFixture.refsWithExtraSpecies(extra, { johto = {}, national = required }))
  local caught = {}
  for _, key in ipairs(mythicals) do
    caught[#caught + 1] = key
  end
  for index = 1, 483 do
    caught[#caught + 1] = required[index]
  end
  knowledge:prepareChanges({ caught = caught }):publish()
  Assert.isFalse(knowledge:isNationalDexComplete(), "mythicals cannot replace the 484th required species")

  knowledge:capture(required[484]):publish()
  Assert.isTrue(knowledge:isNationalDexComplete())
end

function T.explicit_completion_sets_decide_over_raw_caught_cardinality()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local knowledge = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, PokedexDexFixture.buildPokedexCatalog()))
  knowledge
    :prepareChanges({
      caught = { "CHIKORITA", "EEVEE", "CUSTOM_IN", "CUSTOM_OUT_A", "CUSTOM_OUT_B" },
    })
    :publish()
  Assert.isFalse(
    knowledge:isNationalDexComplete(),
    "outside custom keys cannot stand in for the missing required member"
  )
  Assert.equal(knowledge:countCaught("national"), 3, "outside keys never enter the display count")
  Assert.equal(knowledge:countSeen("national"), 3, "outside keys never enter the seen count")
  knowledge:capture("TOTODILE"):publish()
  Assert.isTrue(
    knowledge:isNationalDexComplete(),
    "completion holds only when every explicit required member is caught"
  )
  Assert.equal(knowledge:countCaught("national"), 4, "explicit members count once complete")
  knowledge:prepareChanges({ caught = { "CHIKORITA", "CUSTOM_IN" } }):publish()
  Assert.isTrue(knowledge:isJohtoDexComplete(), "the johto set completes independently from its own explicit members")
end

function T.mythical_exclusion_reads_the_source_sets_per_mode()
  local ordinary = { "ORD_A", "ORD_B", "ORD_C" }
  local mythicals = {
    "MEW",
    "CELEBI",
    "JIRACHI",
  }
  local extra = {}
  for _, key in ipairs(ordinary) do
    extra[#extra + 1] = key
  end
  for _, key in ipairs(mythicals) do
    extra[#extra + 1] = key
  end
  local refs = PokedexDexFixture.refsWithExtraSpecies(extra, {
    johto = { "ORD_A", "MEW" },
    national = extra,
  })
  -- The rating counts walk the display orders, so the test orders
  -- name their rows explicitly behind the registered species.
  refs.pokedexCatalog.dexOrders.johto = { "ORD_A", "ORD_B", "MEW", "CELEBI" }
  refs.pokedexCatalog.dexOrders.national = { "ORD_A", "ORD_B", "ORD_C", "MEW", "CELEBI", "JIRACHI" }
  local knowledge = PokedexKnowledge.new(refs)
  local caught = {}
  for _, key in ipairs(extra) do
    caught[#caught + 1] = key
  end
  knowledge:prepareChanges({ caught = caught }):publish()
  Assert.equal(knowledge:countCaught("national"), 6, "the national count names every ordered key")
  Assert.equal(
    knowledge:countOwnedExcludeMythical("national"),
    3,
    "the national rating excludes Mew, Celebi, and Jirachi"
  )
  Assert.equal(knowledge:countCaught("johto"), 4, "the johto count names every ordered key")
  Assert.equal(knowledge:countOwnedExcludeMythical("johto"), 2, "the johto rating excludes Mew and Celebi")
  Assert.throws(function()
    knowledge:countOwnedExcludeMythical("kanto")
  end, "an unknown mode must fail")
end

return { tests = T }
