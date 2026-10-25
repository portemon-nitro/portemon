local Assert = require("tests.support.Assert")
local BattleEncounterSelector = require("libs.hgss.src.transition.BattleEncounterSelector")

local T = {}

local function transitions()
  local routes = {}
  local fallbackRoutes = {}
  for _, terrain in ipairs({ "plain", "water", "cave" }) do
    for _, timeOfDay in ipairs({ "day", "late" }) do
      for _, battleKind in ipairs({ "wild", "trainer" }) do
        local route = "fallback/" .. terrain .. "/" .. timeOfDay .. "/" .. battleKind
        fallbackRoutes[#fallbackRoutes + 1] =
          { terrain = terrain, timeOfDay = timeOfDay, battleKind = battleKind, route = route }
        routes[route] = { role = route, resources = {} }
      end
    end
  end
  for _, route in ipairs({
    "trainer/falkner",
    "trainer/rival-or-passerby",
    "trainer/special-default",
    "trainer/special-double",
    "trainer/alternate",
    "trainer/generic",
    "trainer/team-rocket",
    "wild/ho-oh",
    "wild/raikou",
    "wild/generic",
  }) do
    routes[route] = { role = route, resources = {} }
  end
  return {
    routes = routes,
    selection = {
      trainerClassRoutes = {
        LEADER_FALKNER = "trainer/falkner",
        RIVAL = "trainer/rival-or-passerby",
        FRONTIER_GENERIC = "trainer/generic",
        TEAM_ROCKET = "trainer/team-rocket",
      },
      wildSpeciesRoutes = { RAIKOU = "setup-fallback", HO_OH = "wild/ho-oh" },
      trainerClassMusicRoles = {
        LEADER_FALKNER = "gym-leader",
        RIVAL = "rival",
        FRONTIER_GENERIC = "battle-arcade-brain",
        TEAM_ROCKET = "rocket",
      },
      wildSpeciesMusicRoles = { RAIKOU = "raikou", HO_OH = "ho-oh" },
      trainerRules = {
        specialBattle = {
          preserveRoute = "trainer/generic",
          preserveMusicRole = "battle-arcade-brain",
          defaultRoute = "trainer/special-default",
          defaultMusicRole = "trainer",
          doublesRoute = "trainer/special-double",
          doublesMusicRole = "trainer",
        },
        preserveRoutes = { "trainer/team-rocket" },
        unknownRoute = "setup-fallback",
        unknownMusicRole = "trainer",
        doublesRoute = "wild/generic",
        doublesMusicRole = "trainer",
        alternateTransitionRoute = "trainer/alternate",
        alternateMusicRole = "trainer",
      },
      wildRules = {
        fallbackRoute = "setup-fallback",
        fallbackMusicRole = "wild",
        doublesRoute = "wild/generic",
        doublesMusicRole = "wild",
      },
      fallbackRoutes = fallbackRoutes,
    },
  }
end

function T.trainer_selector_keeps_source_precedence_without_a_rival_name()
  local selected = BattleEncounterSelector.resolve(transitions(), {
    kind = "trainer",
    trainerClass = "RIVAL",
    terrain = "plain",
    timeOfDay = "day",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
  })
  Assert.equal(selected.routeKey, "trainer/rival-or-passerby", "Rival selection does not depend on a display name")
  Assert.equal(selected.musicRole, "rival", "Rival class selects its source music role without a display name")
end

function T.trainer_selector_applies_special_double_and_alternate_precedence()
  local catalog = transitions()
  local regularSpecial = BattleEncounterSelector.resolve(catalog, {
    kind = "trainer",
    trainerClass = "LEADER_FALKNER",
    terrain = "plain",
    timeOfDay = "day",
    specialBattle = true,
    doubleBattle = false,
    alternateTransition = false,
  })
  local doubleSpecial = BattleEncounterSelector.resolve(catalog, {
    kind = "trainer",
    trainerClass = "LEADER_FALKNER",
    terrain = "plain",
    timeOfDay = "day",
    specialBattle = true,
    doubleBattle = true,
    alternateTransition = false,
  })
  local alternate = BattleEncounterSelector.resolve(catalog, {
    kind = "trainer",
    trainerClass = "LEADER_FALKNER",
    terrain = "plain",
    timeOfDay = "day",
    specialBattle = false,
    doubleBattle = false,
    alternateTransition = true,
  })
  local specialFrontier = BattleEncounterSelector.resolve(catalog, {
    kind = "trainer",
    trainerClass = "FRONTIER_GENERIC",
    terrain = "plain",
    timeOfDay = "day",
    specialBattle = true,
    doubleBattle = true,
    alternateTransition = false,
  })
  local doublesBeforeAlternate = BattleEncounterSelector.resolve(catalog, {
    kind = "trainer",
    trainerClass = "LEADER_FALKNER",
    terrain = "plain",
    timeOfDay = "day",
    specialBattle = false,
    doubleBattle = true,
    alternateTransition = true,
  })
  Assert.equal(regularSpecial.routeKey, "trainer/special-default", "special trainer default route")
  Assert.equal(doubleSpecial.routeKey, "trainer/special-double", "special trainer doubles route")
  Assert.equal(alternate.routeKey, "trainer/alternate", "alternate trainer route")
  Assert.equal(specialFrontier.routeKey, "trainer/generic", "special generic trainer route is preserved before doubles")
  Assert.equal(specialFrontier.musicRole, "battle-arcade-brain", "category 39 preserves its Frontier Brain music role")
  Assert.equal(doublesBeforeAlternate.routeKey, "wild/generic", "doubles precedence comes before alternate transition")
end

function T.wild_roamer_and_special_setup_use_environment_fallbacks()
  local catalog = transitions()
  local roaming = BattleEncounterSelector.resolve(catalog, {
    kind = "wild",
    wildSpecies = "RAIKOU",
    wildSetupFallback = false,
    terrain = "cave",
    timeOfDay = "late",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
  })
  local setupFallback = BattleEncounterSelector.resolve(catalog, {
    kind = "wild",
    wildSpecies = "HO_OH",
    wildSetupFallback = true,
    terrain = "water",
    timeOfDay = "day",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
  })
  Assert.equal(roaming.routeKey, "fallback/cave/late/wild", "roaming transition invokes native environment selection")
  Assert.equal(roaming.musicRole, "raikou", "roaming fallback keeps its species-selected music role")
  Assert.equal(setupFallback.routeKey, "fallback/water/day/wild", "wild setup sentinel invokes environment selection")
  Assert.equal(setupFallback.musicRole, "wild", "wild setup sentinel selects the source fallback music role")
end

function T.numeric_trainer_class_mirror_matches_the_pinned_producer_table()
  local Sources = require("romdump.src.config.BattleSources")
  for id = 0, 128 do
    Assert.equal(
      BattleEncounterSelector.trainerClassName(id),
      Sources.trainerClassKeys[id],
      "numeric class " .. id .. " keeps its pinned semantic identity"
    )
  end
  Assert.isNil(BattleEncounterSelector.trainerClassName(129), "identities outside the table stay unmapped")
  Assert.isNil(BattleEncounterSelector.trainerClassName(200), "phone aliases stay unmapped")
end

function T.numeric_trainer_classes_resolve_to_their_precise_source_routes()
  local catalog = transitions()
  local function selectTrainer(trainerClass)
    return BattleEncounterSelector.resolve(catalog, {
      kind = "trainer",
      trainerClass = trainerClass,
      terrain = "plain",
      timeOfDay = "day",
      doubleBattle = false,
      specialBattle = false,
      alternateTransition = false,
    })
  end
  local falkner = selectTrainer(66)
  Assert.equal(falkner.routeKey, "trainer/falkner", "the numeric leader keeps its precise route")
  Assert.equal(falkner.musicRole, "gym-leader", "the numeric leader keeps its precise music role")
  local rival = selectTrainer(23)
  Assert.equal(rival.routeKey, "trainer/rival-or-passerby", "the numeric rival keeps its precise route")
  Assert.equal(rival.musicRole, "rival", "the numeric rival keeps its precise music role")
  local rocket = selectTrainer(55)
  Assert.equal(rocket.routeKey, "trainer/team-rocket", "the numeric grunt keeps its precise route")
  Assert.equal(rocket.musicRole, "rocket", "the numeric grunt keeps its precise music role")
  local youngster = selectTrainer(2)
  Assert.equal(youngster.routeKey, "fallback/plain/day/trainer", "ordinary numeric classes keep the unknown path")
  Assert.equal(youngster.musicRole, "trainer", "ordinary numeric classes keep the unknown music role")
  local absent = selectTrainer(129)
  Assert.equal(absent.routeKey, "fallback/plain/day/trainer", "absent numeric classes keep the unknown path")
  Assert.equal(absent.musicRole, "trainer", "absent numeric classes keep the unknown music role")
  Assert.throws(function()
    selectTrainer(nil)
  end, "a missing class still fails loudly")
  Assert.throws(function()
    selectTrainer("")
  end, "an empty class still fails loudly")
end

function T.elite_route_requires_and_preserves_semantic_profile_gender()
  local catalog = transitions()
  catalog.routes["trainer/falkner"].requiredContext = { "playerGender" }
  local context = {
    kind = "trainer",
    trainerClass = "LEADER_FALKNER",
    terrain = "plain",
    timeOfDay = "day",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
    playerGender = "female",
  }
  local selected = BattleEncounterSelector.resolve(catalog, context)
  Assert.equal(selected.context.playerGender, "female", "family receives the captured semantic gender value")
  context.playerGender = nil
  Assert.equal(
    selected.context.playerGender,
    "female",
    "later caller mutation cannot change the selected launch snapshot"
  )
  Assert.throws(function()
    BattleEncounterSelector.resolve(catalog, context)
  end, "an elite route cannot guess a missing player profile gender")
end

return { tests = T }
