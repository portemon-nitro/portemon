local Assert = require("tests.support.Assert")
local Sources = require("romdump.src.config.BattlePresentationSources")
local BattleEncounterSelector = require("libs.hgss.src.transition.BattleEncounterSelector")

local T = {}

local function semanticRoute(category)
  local route = Sources.TRANSITION_PRESELECTION.categoryRoutes[category]
  if type(route) == "table" and route.fallback == true then
    return "setup-fallback"
  end
  return route
end

local function sourceCatalog()
  local preselection = Sources.TRANSITION_PRESELECTION
  local categories = preselection.categoryRoutes
  local routes = {}
  for _, route in pairs(categories) do
    local key = type(route) == "table" and "setup-fallback" or route
    routes[key] = { role = key }
  end
  for _, route in pairs(Sources.TRANSITION_SELECTOR_ROUTES) do
    routes[route.key] = { role = route.role }
  end

  local trainerClassRoutes = {}
  for class, routeKey in pairs(preselection.trainerClasses) do
    trainerClassRoutes[class] = semanticRoute(preselection.trainerCategoryByKey[routeKey])
  end
  local wildSpeciesRoutes = {}
  for species, routeKey in pairs(preselection.wildSpecies) do
    wildSpeciesRoutes[species] = semanticRoute(preselection.wildCategoryByKey[routeKey])
  end
  local function musicRole(category)
    local sequenceSymbol = Sources.INTRO_MUSIC.rows[category + 1]
    return assert(Sources.INTRO_MUSIC.roles[sequenceSymbol])
  end
  local trainerClassMusicRoles = {}
  for class, sourceKey in pairs(preselection.trainerClasses) do
    trainerClassMusicRoles[class] = musicRole(preselection.trainerCategoryByKey[sourceKey])
  end
  local wildSpeciesMusicRoles = {}
  for species, sourceKey in pairs(preselection.wildSpecies) do
    wildSpeciesMusicRoles[species] = musicRole(preselection.wildCategoryByKey[sourceKey])
  end
  local function routesForCategories(categoriesList)
    local result = {}
    for _, category in ipairs(categoriesList) do
      result[#result + 1] = semanticRoute(category)
    end
    return result
  end
  local sourceRules = preselection.selectionRules
  local fallbackRoutes = {}
  for selector = 0, 11 do
    local context = assert(Sources.TRANSITION_SELECTOR_ROUTES[selector].context)
    fallbackRoutes[#fallbackRoutes + 1] = {
      route = Sources.TRANSITION_SELECTOR_ROUTES[selector].key,
      terrain = context.terrain,
      timeOfDay = context.timeOfDay,
      battleKind = context.isTrainer and "trainer" or "wild",
    }
  end
  return {
    routes = routes,
    selection = {
      trainerClassRoutes = trainerClassRoutes,
      wildSpeciesRoutes = wildSpeciesRoutes,
      trainerClassMusicRoles = trainerClassMusicRoles,
      wildSpeciesMusicRoles = wildSpeciesMusicRoles,
      trainerRules = {
        specialBattle = {
          preserveRoute = semanticRoute(sourceRules.trainer.specialBattle.preserveCategory),
          preserveMusicRole = musicRole(sourceRules.trainer.specialBattle.preserveCategory),
          defaultRoute = semanticRoute(sourceRules.trainer.specialBattle.defaultCategory),
          defaultMusicRole = musicRole(sourceRules.trainer.specialBattle.defaultCategory),
          doublesRoute = semanticRoute(sourceRules.trainer.specialBattle.doublesCategory),
          doublesMusicRole = musicRole(sourceRules.trainer.specialBattle.doublesCategory),
        },
        preserveRoutes = routesForCategories(sourceRules.trainer.preserveCategories),
        unknownRoute = semanticRoute(41),
        unknownMusicRole = musicRole(41),
        doublesRoute = semanticRoute(sourceRules.trainer.doublesCategory),
        doublesMusicRole = musicRole(sourceRules.trainer.doublesCategory),
        alternateTransitionRoute = semanticRoute(sourceRules.trainer.alternateCategory),
        alternateMusicRole = musicRole(sourceRules.trainer.alternateCategory),
      },
      wildRules = {
        fallbackRoute = semanticRoute(sourceRules.wild.fallbackCategory),
        fallbackMusicRole = musicRole(sourceRules.wild.fallbackCategory),
        doublesRoute = semanticRoute(sourceRules.wild.doublesCategoryWhenCategoryAtLeast.category),
        doublesMusicRole = musicRole(sourceRules.wild.doublesCategoryWhenCategoryAtLeast.category),
      },
      fallbackRoutes = fallbackRoutes,
    },
  }
end

local function select(catalog, kind, values)
  values.kind = kind
  values.terrain = values.terrain or "plain"
  values.timeOfDay = values.timeOfDay or "day"
  values.doubleBattle = values.doubleBattle or false
  values.specialBattle = values.specialBattle or false
  values.alternateTransition = values.alternateTransition or false
  values.wildSetupFallback = values.wildSetupFallback or false
  return BattleEncounterSelector.resolve(catalog, values)
end

function T.native_trainer_and_wild_rows_resolve_to_source_routes()
  local catalog = sourceCatalog()
  local preselection = Sources.TRANSITION_PRESELECTION

  for trainerClass, sourceRoute in pairs(preselection.trainerClasses) do
    local category = assert(preselection.trainerCategoryByKey[sourceRoute])
    local expected = semanticRoute(category)
    local selected = select(catalog, "trainer", { trainerClass = trainerClass })
    Assert.equal(selected.routeKey, expected, "native trainer class " .. trainerClass .. " keeps its source route")
  end

  for species, sourceRoute in pairs(preselection.wildSpecies) do
    local category = assert(preselection.wildCategoryByKey[sourceRoute])
    local expected = semanticRoute(category)
    if expected == "setup-fallback" then
      expected = "fallback/plain/day/wild"
    end
    local selected = select(catalog, "wild", { wildSpecies = species })
    Assert.equal(selected.routeKey, expected, "native wild species " .. species .. " keeps its source route")
  end

  for _, fallbackRoute in ipairs(catalog.selection.fallbackRoutes) do
    local selected
    if fallbackRoute.battleKind == "trainer" then
      selected = select(catalog, "trainer", {
        trainerClass = "UNMAPPED_SOURCE_CLASS",
        terrain = fallbackRoute.terrain,
        timeOfDay = fallbackRoute.timeOfDay,
      })
    else
      selected = select(catalog, "wild", {
        wildSpecies = "RATTATA",
        wildSetupFallback = true,
        terrain = fallbackRoute.terrain,
        timeOfDay = fallbackRoute.timeOfDay,
      })
    end
    Assert.equal(selected.routeKey, fallbackRoute.route, "source sentinel resolves " .. fallbackRoute.route)
  end
end

function T.native_precedence_uses_class_bits_and_region_routes()
  local catalog = sourceCatalog()
  local preselection = Sources.TRANSITION_PRESELECTION
  local johto = select(catalog, "trainer", { trainerClass = "LEADER_FALKNER" })
  local kanto = select(catalog, "trainer", { trainerClass = "LEADER_BROCK" })
  local special = select(catalog, "trainer", {
    trainerClass = "RIVAL",
    specialBattle = true,
    alternateTransition = true,
  })
  local specialDoubles = select(catalog, "trainer", {
    trainerClass = "RIVAL",
    specialBattle = true,
    doubleBattle = true,
  })
  local ordinaryDoubles = select(catalog, "trainer", {
    trainerClass = "UNMAPPED_SOURCE_CLASS",
    doubleBattle = true,
  })
  local alternate = select(catalog, "trainer", {
    trainerClass = "UNMAPPED_SOURCE_CLASS",
    alternateTransition = true,
  })
  local wildDoublesFallback = select(catalog, "wild", {
    wildSpecies = "RATTATA",
    wildSetupFallback = true,
    doubleBattle = true,
  })

  Assert.equal(johto.routeKey, semanticRoute(preselection.trainerCategoryByKey["trainer/falkner"]), "Johto leader row")
  Assert.equal(kanto.routeKey, semanticRoute(preselection.trainerCategoryByKey["trainer/brock"]), "Kanto leader row")
  Assert.equal(
    special.routeKey,
    semanticRoute(preselection.selectionRules.trainer.specialBattle.defaultCategory),
    "special-battle flag precedes class and alternate flag"
  )
  Assert.equal(
    specialDoubles.routeKey,
    semanticRoute(preselection.selectionRules.trainer.specialBattle.doublesCategory),
    "special doubles takes its source row"
  )
  Assert.equal(
    ordinaryDoubles.routeKey,
    semanticRoute(preselection.selectionRules.trainer.doublesCategory),
    "trainer doubles takes its source row"
  )
  Assert.equal(
    alternate.routeKey,
    semanticRoute(preselection.selectionRules.trainer.alternateCategory),
    "alternate transition takes its source row"
  )
  Assert.equal(
    wildDoublesFallback.routeKey,
    semanticRoute(preselection.selectionRules.wild.doublesCategoryWhenCategoryAtLeast.category),
    "wild fallback doubles takes its source row"
  )

  Assert.equal(#Sources.INTRO_MUSIC.rows, 45, "pinned transition/music table contains categories 0 through 44")
  for category, sequence in ipairs(Sources.INTRO_MUSIC.rows) do
    Assert.notNil(Sources.INTRO_MUSIC.roles[sequence], "music row " .. (category - 1) .. " has a semantic role")
  end
end

function T.native_intro_music_rows_keep_frontier_and_linked_format_roles()
  local introMusic = Sources.INTRO_MUSIC
  local preselection = Sources.TRANSITION_PRESELECTION
  Assert.equal(preselection.callInputs.genericFrontierTrainerCategory, 39, "frontier category remains source-defined")
  Assert.deepEqual(introMusic.selectionRules.trainer.modifiers, { "frontierBattle", "doubleBattle", "tagBattle" })
  Assert.equal(introMusic.rows[40], "SEQ_GS_BA_BRAIN", "category 39 selects the Frontier Brain music sequence")
  Assert.equal(
    introMusic.roles[introMusic.rows[40]],
    "battle-arcade-brain",
    "Frontier Brain sequence has a semantic role"
  )
  Assert.equal(introMusic.rows[42], "SEQ_GS_VS_TRAINER", "category 41 keeps the general trainer sequence")
  Assert.equal(introMusic.rows[43], "SEQ_GS_VS_NORAPOKE", "category 42 keeps the ordinary wild sequence")
  Assert.equal(introMusic.rows[44], "SEQ_GS_VS_TRAINER", "category 43 keeps the semantic trainer sequence")
  Assert.equal(introMusic.rows[45], "SEQ_GS_VS_CHAMP", "category 44 keeps the Champion sequence")
end

return { tests = T }
