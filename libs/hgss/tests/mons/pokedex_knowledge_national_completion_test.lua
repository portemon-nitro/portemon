-- National dex completion follows the retail non-mythical caught predicate.
local Assert = require("tests.support.Assert")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local T = {}

function T.national_completion_excludes_all_nine_mythicals_at_the_484_species_boundary()
  local mythicals = {
    "MEW", "CELEBI", "JIRACHI", "DEOXYS", "PHIONE", "MANAPHY", "DARKRAI", "SHAYMIN", "ARCEUS",
  }
  local required = {}
  local species = {}
  for index = 1, 484 do
    local key = string.format("REQUIRED_%03d", index)
    required[index] = key
    species[key] = true
  end
  for _, key in ipairs(mythicals) do
    species[key] = true
  end

  local knowledge = PokedexKnowledge.new({ species = species })
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

return { tests = T }
