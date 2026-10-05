-- National dex star counting follows the source helper's mythical exclusions.
local Assert = require("tests.support.Assert")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local T = {}

function T.national_caught_count_excludes_event_species_and_includes_celebi()
  local species = {
    MEW = true,
    JIRACHI = true,
    DEOXYS = true,
    PHIONE = true,
    MANAPHY = true,
    DARKRAI = true,
    SHAYMIN = true,
    ARCEUS = true,
    CELEBI = true,
    CHIKORITA = true,
  }
  local knowledge = PokedexKnowledge.new({ species = species })
  knowledge:prepareChanges({ caught = {
    "MEW", "JIRACHI", "DEOXYS", "PHIONE", "MANAPHY", "DARKRAI", "SHAYMIN", "ARCEUS", "CELEBI", "CHIKORITA",
  } }):publish()
  Assert.equal(knowledge:nationalCaughtCount(), 2)
end

return { tests = T }
