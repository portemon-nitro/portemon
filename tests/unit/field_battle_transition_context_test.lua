local Assert = require("tests.support.Assert")
local FieldBattleCoordinator = require("game.hgss.src.field.FieldBattleCoordinator")
local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")

local T = {}

function T.wild_context_keeps_semantic_species_and_normalizes_fallback_time()
  local coordinator = setmetatable({
    runtime = { playerData = { profile = { gender = 0 } } },
  }, FieldBattleCoordinator)
  local context = coordinator:_captureTransitionContext({
    kind = "wild",
    payload = { species = "HO_OH", format = "wild-single" },
  }, { terrain = "water", time = "night" })

  Assert.deepEqual(context, {
    kind = "wild",
    wildSpecies = "HO_OH",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
    wildSetupFallback = false,
    terrain = "water",
    timeOfDay = "late",
    playerGender = "male",
  })
end

function T.trainer_context_reads_class_without_materializing_party()
  local catalog = HgssTrainerCatalog.new({
    trainers = {
      trainer_key = {
        trainerClass = "LEADER_FALKNER",
        nameReference = { kind = "literal", value = "Falkner" },
        party = {},
        doubleBattle = true,
      },
    },
  })
  local coordinator = setmetatable({
    runtime = { _trainerCatalog = catalog, playerData = { profile = { gender = 1 } } },
  }, FieldBattleCoordinator)
  local context = coordinator:_captureTransitionContext({
    kind = "trainer",
    payload = { trainer = "trainer_key" },
  }, { terrain = "plain", time = "day" })

  Assert.deepEqual(context, {
    kind = "trainer",
    trainerClass = "LEADER_FALKNER",
    doubleBattle = true,
    specialBattle = false,
    alternateTransition = false,
    terrain = "plain",
    timeOfDay = "day",
    playerGender = "female",
  })
end

return { tests = T }
