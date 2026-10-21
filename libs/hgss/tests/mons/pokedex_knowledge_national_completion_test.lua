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

  local knowledge = PokedexKnowledge.new(
    PokedexDexFixture.refsWithExtraSpecies(extra, { johto = {}, national = required })
  )
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

return { tests = T }
