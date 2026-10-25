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
  }, { terrain = "water", time = "day", hour = 22 })

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

-- Source EncounterEffect_GetDefaultEffect folds every battle terrain other
-- than water and cave into the plain fallback, and only the NITE and LATE
-- RTC times select the late fallback, whatever band the scene shows.
function T.wild_context_folds_battle_terrain_and_clock_into_fallback_axes()
  local coordinator = setmetatable({
    runtime = { playerData = { profile = { gender = 0 } } },
  }, FieldBattleCoordinator)
  local function capture(environment)
    return coordinator:_captureTransitionContext({
      kind = "wild",
      payload = { species = "PIDGEY", format = "wild-single" },
    }, environment)
  end

  local grass = capture({ terrain = "grass", time = "evening", hour = 18 })
  Assert.equal(grass.terrain, "plain", "grass battles use the plain fallback")
  Assert.equal(grass.timeOfDay, "day", "evening is not a late transition time")
  local building = capture({ terrain = "building", time = "day", hour = 2 })
  Assert.equal(building.terrain, "plain", "building battles use the plain fallback")
  Assert.equal(building.timeOfDay, "late", "late night reads late even when the scene pins day")
  local cave = capture({ terrain = "cave", time = "day", hour = 20 })
  Assert.equal(cave.terrain, "cave", "caves keep their own fallback")
  Assert.equal(cave.timeOfDay, "late", "night reads late")
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
  }, { terrain = "plain", time = "day", hour = 12 })

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
