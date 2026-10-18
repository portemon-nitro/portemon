-- Coordinator class-capture precision: string and numeric trainer classes
-- ride the captured transition context untouched for the precise
-- downstream selector, while a missing trainer still fails loudly.
-- Synthetic catalogs only: no ROM, no presentation.

local Assert = require("tests.support.Assert")
local FieldBattleCoordinator = require("game.hgss.src.field.FieldBattleCoordinator")
local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")

local T = {}

local function template(trainerClass)
  return {
    trainerClass = trainerClass,
    nameReference = { trainerIndex = 7 },
    party = { { species = "CHIKORITA", level = 5 } },
    aiPasses = {},
    doubleBattle = false,
    items = {},
    prizeMoney = { trainerClass = 2, classRate = 4 },
    messageSelectors = { intro = 0, lose = 1, after = 2 },
  }
end

local function capture(trainerClass, trainerId)
  local catalog = HgssTrainerCatalog.new({ trainers = { [7] = template(trainerClass) } })
  local owner = FieldBattleCoordinator.new({
    playerData = { profile = { gender = 0 } },
    _trainerCatalog = catalog,
  })
  return owner:_captureTransitionContext(
    { kind = "trainer", payload = { trainer = trainerId or 7 } },
    { time = "day", terrain = "plain" }
  )
end

function T.numeric_trainer_classes_ride_the_context_for_precise_selection()
  local context = capture(66)
  Assert.equal(context.trainerClass, 66, "the numeric leader keeps its native identity for selection")
  local ordinary = capture(2)
  Assert.equal(ordinary.trainerClass, 2, "ordinary numeric classes ride the context untouched")
end

function T.string_trainer_classes_keep_their_names()
  local context = capture("LEADER_FALKNER")
  Assert.equal(context.trainerClass, "LEADER_FALKNER", "named classes keep their semantic key")
end

function T.missing_trainers_still_fail_loudly()
  Assert.throws(function()
    capture(66, 404)
  end, "a transition context without its trainer template never launches")
end

return { tests = T }
