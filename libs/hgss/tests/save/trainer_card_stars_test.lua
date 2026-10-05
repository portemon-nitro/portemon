-- Trainer Card stars are the five source-defined save predicates.
local Assert = require("tests.support.Assert")
local TrainerCardStars = require("libs.hgss.src.save.TrainerCardStars")

local T = {}

function T.counts_independent_source_criteria()
  local flags = { FLAG_GAME_CLEAR = true, FLAG_UNK_0F1 = true, FLAG_UNK_184 = false }
  local world = { isFlagSet = function(_, name) return flags[name] == true end }
  local dex = { nationalCaughtCount = function() return 484 end }
  local frontier = { allAtLeast = function(_, value) return value == 100 end }
  Assert.equal(TrainerCardStars.count(world, dex, frontier), 4)
end

function T.criteria_are_inclusive_at_their_thresholds()
  local world = { isFlagSet = function() return false end }
  local dex = { nationalCaughtCount = function() return 483 end }
  local frontier = { allAtLeast = function() return false end }
  Assert.equal(TrainerCardStars.count(world, dex, frontier), 0)
end

return { tests = T }
