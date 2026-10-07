-- Trainer Card stars are the five source-defined save predicates.
local Assert = require("tests.support.Assert")
local TrainerCardStars = require("libs.hgss.src.save.TrainerCardStars")

local T = {}

function T.counts_existing_flags_and_semantic_save_predicates_independently()
  local flags = { FLAG_GAME_CLEAR = true, FLAG_UNK_0F1 = true, FLAG_UNK_184 = false }
  local world = { isFlagSet = function(_, name) return flags[name] == true end }
  for _, dexComplete in ipairs({ false, true }) do
    for _, frontierQualifies in ipairs({ false, true }) do
      local dex = { isNationalDexComplete = function() return dexComplete end }
      local frontier = { qualifiesForTrainerCardStar = function() return frontierQualifies end }
      Assert.equal(TrainerCardStars.count(world, dex, frontier), 2 + (dexComplete and 1 or 0) + (frontierQualifies and 1 or 0))
    end
  end

  local noFlags = { isFlagSet = function() return false end }
  local completeDex = { isNationalDexComplete = function() return true end }
  local qualifyingFrontier = { qualifiesForTrainerCardStar = function() return true end }
  Assert.equal(TrainerCardStars.count(noFlags, completeDex, qualifyingFrontier), 2)
end

return { tests = T }
