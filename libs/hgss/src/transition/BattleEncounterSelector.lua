-- Resolves encounter selectors from the generated source-normalized catalog.

local Errors = require("libs.errors.src.Errors")

---@class BattleEncounterSelector
local BattleEncounterSelector = {}

---@class BattleEncounterSelector.Context
---@field kind "trainer"|"wild"
---@field trainerClass string? semantic trainer class for trainer encounters
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
    if type(trainerClass) ~= "string" or trainerClass == "" then
      Errors.raise("BATTLE_TRANSITION_CONTEXT_INVALID", "trainer encounters name their source class", {
        kind = kind,
      })
    end
    local classRoutes = assert(selection.trainerClassRoutes, "selector carries trainer routes")
    local classMusicRoles = assert(selection.trainerClassMusicRoles, "selector carries trainer music roles")
    local trainerRules = assert(selection.trainerRules, "selector carries trainer precedence")
    local specialRules = assert(trainerRules.specialBattle, "selector carries special-trainer precedence")
    routeKey = classRoutes[trainerClass] or trainerRules.unknownRoute
    musicRole = classMusicRoles[trainerClass] or trainerRules.unknownMusicRole
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
