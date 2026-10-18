-- Resolves encounter selectors from the generated source-normalized catalog.

local Errors = require("libs.errors.src.Errors")

---@class BattleEncounterSelector
local BattleEncounterSelector = {}

-- Numeric trainer-class identities behind the selector, derived from the
-- pinned producer inventory (romdump/src/config/BattleSources.lua
-- trainerClassKeys): the header byte of the native 20-byte trainer record
-- behind each TRAINERCLASS_* symbol in include/constants/trainer_class.h
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36). Phone
-- contact aliases never enter battles and stay out; Kanto variants keep
-- their own distinct identities. A numeric class resolves to its semantic
-- key before the route tables; an identity outside this table keeps the
-- designed unknown route and music role.
local TRAINER_CLASS_KEYS = {
  [0] = "PKMN_TRAINER_ETHAN",
  [1] = "PKMN_TRAINER_LYRA",
  [2] = "YOUNGSTER",
  [3] = "LASS",
  [4] = "CAMPER",
  [5] = "PICNICKER",
  [6] = "BUG_CATCHER",
  [7] = "AROMA_LADY",
  [8] = "TWINS",
  [9] = "HIKER",
  [10] = "BATTLE_GIRL",
  [11] = "FISHERMAN",
  [12] = "CYCLIST_M",
  [13] = "CYCLIST_F",
  [14] = "BLACK_BELT",
  [15] = "ARTIST",
  [16] = "PKMN_BREEDER_M",
  [17] = "PKMN_BREEDER_F",
  [18] = "COWGIRL",
  [19] = "JOGGER",
  [20] = "POKEFAN_M",
  [21] = "POKEFAN",
  [22] = "POKE_KID",
  [23] = "RIVAL",
  [24] = "ACE_TRAINER_M",
  [25] = "ACE_TRAINER_F",
  [26] = "WAITRESS",
  [27] = "VETERAN",
  [28] = "NINJA_BOY",
  [29] = "DRAGON_TAMER",
  [30] = "BIRD_KEEPER",
  [31] = "JUGGLER",
  [32] = "RICH_BOY",
  [33] = "LADY",
  [34] = "GENTLEMAN",
  [35] = "SOCIALITE",
  [36] = "BEAUTY",
  [37] = "COLLECTOR",
  [38] = "POLICEMAN",
  [39] = "PKMN_RANGER_M",
  [40] = "PKMN_RANGER_F",
  [41] = "SCIENTIST",
  [42] = "SWIMMER_M",
  [43] = "SWIMMER_F",
  [44] = "TUBER_M",
  [45] = "TUBER_F",
  [46] = "SAILOR",
  [47] = "KIMONO_GIRL",
  [48] = "RUIN_MANIAC",
  [49] = "PSYCHIC_M",
  [50] = "PSYCHIC_F",
  [51] = "PI",
  [52] = "GUITARIST",
  [53] = "ACE_TRAINER_M_GS",
  [54] = "ACE_TRAINER_F_GS",
  [55] = "TEAM_ROCKET",
  [56] = "SKIER",
  [57] = "ROUGHNECK",
  [58] = "CLOWN",
  [59] = "WORKER",
  [60] = "SCHOOL_KID_M",
  [61] = "SCHOOL_KID_F",
  [62] = "TEAM_ROCKET_F",
  [63] = "BURGLAR",
  [64] = "FIREBREATHER",
  [65] = "BIKER",
  [66] = "LEADER_FALKNER",
  [67] = "LEADER_BUGSY",
  [68] = "POKE_MANIAC",
  [69] = "BIRD_KEEPER_GS",
  [70] = "LEADER_WHITNEY",
  [71] = "RANCHER",
  [72] = "LEADER_MORTY",
  [73] = "LEADER_PRYCE",
  [74] = "LEADER_JASMINE",
  [75] = "LEADER_CHUCK",
  [76] = "LEADER_CLAIR",
  [77] = "TEACHER",
  [78] = "SUPER_NERD",
  [79] = "SAGE",
  [80] = "PARASOL_LADY",
  [81] = "WAITER",
  [82] = "MEDIUM",
  [83] = "CAMERAMAN",
  [84] = "REPORTER",
  [85] = "IDOL",
  [86] = "CHAMPION",
  [87] = "ELITE_FOUR_WILL",
  [88] = "ELITE_FOUR_KAREN",
  [89] = "ELITE_FOUR_KOGA",
  [90] = "PKMN_TRAINER_CHERYL",
  [91] = "PKMN_TRAINER_RILEY",
  [92] = "PKMN_TRAINER_BUCK",
  [93] = "PKMN_TRAINER_MIRA",
  [94] = "PKMN_TRAINER_MARLEY",
  [95] = "PKMN_TRAINER_FTR_LUCAS",
  [96] = "PKMN_TRAINER_FTR_DAWN",
  [97] = "TOWER_TYCOON",
  [98] = "LEADER_BROCK",
  [99] = "HALL_MATRON",
  [100] = "FACTORY_HEAD",
  [101] = "ARCADE_STAR",
  [102] = "CASTLE_VALET",
  [103] = "LEADER_MISTY",
  [104] = "LEADER_LT_SURGE",
  [105] = "LEADER_ERIKA",
  [106] = "LEADER_JANINE",
  [107] = "LEADER_SABRINA",
  [108] = "LEADER_BLAINE",
  [109] = "PKMN_TRAINER_RED",
  [110] = "LEADER_BLUE",
  [111] = "ELDER",
  [112] = "ELITE_FOUR_BRUNO",
  [113] = "SCIENTIST_GS",
  [114] = "EXECUTIVE_ARIANA",
  [115] = "BOARDER",
  [116] = "EXECUTIVE_ARCHER",
  [117] = "EXECUTIVE_PROTON",
  [118] = "EXECUTIVE_PETREL",
  [119] = "PASSERBY",
  [120] = "MYSTERY_MAN",
  [121] = "DOUBLE_TEAM",
  [122] = "YOUNG_COUPLE",
  [123] = "PKMN_TRAINER_LANCE",
  [124] = "ROCKET_BOSS",
  [125] = "PKMN_TRAINER_LUCAS_DP",
  [126] = "PKMN_TRAINER_DAWN_DP",
  [127] = "PKMN_TRAINER_LUCAS_PT",
  [128] = "PKMN_TRAINER_DAWN_PT",
}

-- Resolves one numeric native trainer class to its semantic key behind the
-- route tables. Identities outside the pinned table answer nil so the
-- caller keeps the designed unknown path instead of guessing a name.
---@param classId number? numeric native trainer class
---@return string? semantic trainer class key, nil when genuinely absent
function BattleEncounterSelector.trainerClassName(classId)
  if type(classId) == "number" and classId % 1 == 0 then
    return TRAINER_CLASS_KEYS[classId]
  end
  return nil
end

---@class BattleEncounterSelector.Context
---@field kind "trainer"|"wild"
---@field trainerClass string|number? semantic trainer class or numeric native class for trainer encounters
---@field wildSpecies string? semantic first living opponent species for wild encounters
---@field doubleBattle boolean source doubles fact
---@field specialBattle boolean source special-battle fact
---@field alternateTransition boolean source alternate-transition fact
---@field playerGender "male"|"female"|nil semantic player profile gender captured at admission
---@field wildSetupFallback boolean source setup selected the wild fallback path
---@field terrain string semantic environment terrain
---@field timeOfDay string normalized source transition time

---@class BattleEncounterSelector.Selection
---@field routeKey string semantic encounter transition route
---@field musicRole string semantic encounter music role
---@field route table<string, unknown> selected generated route
---@field context BattleEncounterSelector.Context immutable launch context

---@param context BattleEncounterSelector.Context
---@param field string
---@param expected string
local function requireBoolean(context, field, expected)
  if type(context[field]) ~= "boolean" then
    Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", field .. " must be explicit", {
      field = field,
      expected = expected,
      value = context[field],
    })
  end
end

---@param transitions table<string, unknown> validated generated transition catalog
---@param context BattleEncounterSelector.Context immutable launch setup facts
---@return BattleEncounterSelector.Selection
function BattleEncounterSelector.resolve(transitions, context)
  assert(type(transitions) == "table", "encounter selection reads its generated transition catalog")
  assert(type(context) == "table", "encounter selection reads immutable launch context")
  local selection = assert(transitions.selection, "transition catalog carries selector rules")
  local routes = assert(transitions.routes, "transition catalog carries semantic routes")
  local kind = context.kind
  if kind ~= "trainer" and kind ~= "wild" then
    Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", "encounter kind must be trainer or wild", {
      kind = kind,
    })
  end
  requireBoolean(context, "doubleBattle", "boolean")
  requireBoolean(context, "specialBattle", "boolean")
  requireBoolean(context, "alternateTransition", "boolean")

  local routeKey
  local musicRole
  if kind == "trainer" then
    local trainerClass = context.trainerClass
    local unknownNumeric = false
    if type(trainerClass) == "number" then
      if trainerClass % 1 ~= 0 then
        Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", "trainer encounters name their source class", {
          kind = kind,
        })
      end
      trainerClass = BattleEncounterSelector.trainerClassName(trainerClass)
      unknownNumeric = trainerClass == nil
    end
    if not unknownNumeric and (type(trainerClass) ~= "string" or trainerClass == "") then
      Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", "trainer encounters name their source class", {
        kind = kind,
      })
    end
    local classRoutes = assert(selection.trainerClassRoutes, "selector carries trainer routes")
    local classMusicRoles = assert(selection.trainerClassMusicRoles, "selector carries trainer music roles")
    local trainerRules = assert(selection.trainerRules, "selector carries trainer precedence")
    local specialRules = assert(trainerRules.specialBattle, "selector carries special-trainer precedence")
    routeKey = (type(trainerClass) == "string" and classRoutes[trainerClass]) or trainerRules.unknownRoute
    musicRole = (type(trainerClass) == "string" and classMusicRoles[trainerClass]) or trainerRules.unknownMusicRole
    if context.specialBattle then
      if routeKey ~= specialRules.preserveRoute then
        if context.doubleBattle then
          routeKey = specialRules.doublesRoute
          musicRole = specialRules.doublesMusicRole
        else
          routeKey = specialRules.defaultRoute
          musicRole = specialRules.defaultMusicRole
        end
      end
    else
      local preserve = false
      for _, preservedRoute in ipairs(trainerRules.preserveRoutes) do
        if routeKey == preservedRoute then
          preserve = true
          break
        end
      end
      if not preserve then
        if context.doubleBattle then
          routeKey = trainerRules.doublesRoute
          musicRole = trainerRules.doublesMusicRole
        elseif context.alternateTransition then
          routeKey = trainerRules.alternateTransitionRoute
          musicRole = trainerRules.alternateMusicRole
        end
      end
    end
  else
    local wildSpecies = context.wildSpecies
    if type(wildSpecies) ~= "string" or wildSpecies == "" then
      Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", "wild encounters name their first living species", {
        kind = kind,
      })
    end
    if type(context.wildSetupFallback) ~= "boolean" then
      Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", "wild setup fallback must be explicit", {
        value = context.wildSetupFallback,
      })
    end
    local wildRules = assert(selection.wildRules, "selector carries wild precedence")
    local speciesRoute = assert(selection.wildSpeciesRoutes, "selector carries wild routes")[wildSpecies]
    musicRole = assert(selection.wildSpeciesMusicRoles, "selector carries wild music roles")[wildSpecies]
      or wildRules.fallbackMusicRole
    if context.wildSetupFallback then
      musicRole = wildRules.fallbackMusicRole
    end
    routeKey = context.wildSetupFallback and wildRules.fallbackRoute or speciesRoute or wildRules.fallbackRoute
    if context.doubleBattle and (context.wildSetupFallback or speciesRoute == nil) then
      routeKey = wildRules.doublesRoute
      musicRole = wildRules.doublesMusicRole
    end
  end

  if routeKey == nil then
    Errors.raise("BATTLE_TRANSITION_ROUTE_UNRESOLVED", "source category has no transition route", {
      kind = kind,
    })
  end
  if routeKey == "setup-fallback" then
    local terrain = context.terrain
    local timeOfDay = context.timeOfDay
    if type(terrain) ~= "string" or type(timeOfDay) ~= "string" then
      Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", "environment transition requires terrain and time", {
        terrain = terrain,
        timeOfDay = timeOfDay,
      })
    end
    local matching = nil
    for _, fallback in ipairs(selection.fallbackRoutes) do
      if fallback.terrain == terrain and fallback.timeOfDay == timeOfDay and fallback.battleKind == kind then
        assert(matching == nil, "environment selector contexts are unique")
        matching = fallback.route
      end
    end
    routeKey = matching
    if routeKey == nil then
      Errors.raise("BATTLE_TRANSITION_ROUTE_UNRESOLVED", "source environment has no transition fallback", {
        terrain = terrain,
        timeOfDay = timeOfDay,
        kind = kind,
      })
    end
  end
  local route = routes[routeKey]
  if type(route) ~= "table" then
    Errors.raise("BATTLE_TRANSITION_ROUTE_UNRESOLVED", "selected transition route is not staged", {
      route = routeKey,
    })
  end
  if type(musicRole) ~= "string" or musicRole == "" then
    Errors.raise("BATTLE_TRANSITION_MUSIC_UNRESOLVED", "selected encounter has no semantic music role", {
      kind = kind,
      route = routeKey,
    })
  end
  for _, input in ipairs(route.requiredContext or {}) do
    if input == "playerGender" and context.playerGender ~= "male" and context.playerGender ~= "female" then
      Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", "elite trainer transition requires player profile gender", {
        playerGender = context.playerGender,
        route = routeKey,
      })
    end
  end
  local launchContext = {}
  for key, value in pairs(context) do
    launchContext[key] = value
  end
  return { routeKey = routeKey, musicRole = musicRole, route = route, context = launchContext }
end

return BattleEncounterSelector
