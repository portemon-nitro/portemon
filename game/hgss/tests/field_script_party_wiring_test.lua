-- Script composition forwards the script-owned party selection host
-- into scheduler services explicitly: the blocking selection task
-- receives the same host instance the runtime constructed, never a
-- second host and never a Start Menu round trip.

local Assert = require("tests.support.Assert")

local T = {}

local TARGET_MODULE = "game.hgss.src.field.FieldScripts"
local COMPOSE_MODULE = "game.hgss.src.field.FieldScriptComposition"

local function stubRuntime()
  return {
    applicationHost = {
      requestReopen = function() end,
    },
    applyAvatarTransitions = function()
      return {}
    end,
    _setLiveWeather = function() end,
    overrideFs = {},
    eventState = {},
    actors = {},
    player = {},
    playerAvatar = nil,
    playerData = { profile = {}, options = { textFrame = 0 } },
    versionId = "heartgold",
    runtimeMap = { mapId = 61 },
    overworld = {
      phase = function()
        return "present"
      end,
    },
    fieldTerrainEffectController = {},
    scriptHosts = nil,
    screenFade = nil,
    auxiliaryFieldUi = {},
    contextChoiceProvider = {},
    menuHost = {},
    dialogue = {},
    messageProvider = {},
    signpost = {},
    windowStyles = {},
    transition = {},
    mapLoader = {},
    fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
  }
end

local function stubOptions(partySelection, mart)
  local InteractionCache = require("libs.assets.src.field.FollowerInteractionCache")
  local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
  local reactions = {}
  local speciesClassBySpeciesId = {}
  local fashionNames = {}
  for selector = 1, 14 do
    local definition = "follower_reaction_" .. selector
    reactions[selector] = {
      definition = definition,
      resourceKey = FieldEffectAssetCache.definitionPath(definition),
    }
  end
  for speciesId = 1, 493 do
    speciesClassBySpeciesId[speciesId] = 0
  end
  for accessoryId = 0, 99 do
    fashionNames[accessoryId] = { name = "Accessory", nameWithArticle = "an Accessory" }
  end
  local rulesByMapSection = {}
  for sectionId = 0, 234 do
    rulesByMapSection[sectionId] = {}
  end
  local followerInteractionCatalog = {
    schema = InteractionCache.SCHEMA,
    version = "heartgold",
    rulesByMapSection = rulesByMapSection,
    programs = {},
    motions = {},
    reactions = reactions,
    speciesClassBySpeciesId = speciesClassBySpeciesId,
    locationNames = {},
    fashionNames = fashionNames,
  }
  assert(InteractionCache.validateCatalog(followerInteractionCatalog))
  return {
    cacheFs = {},
    layoutMessage = function(message)
      return message
    end,
    fontDef = {},
    audioService = nil,
    loadedGame = nil,
    mons = {},
    itemCatalog = {},
    followingMon = {},
    clock = {},
    followerInteractionCatalog = followerInteractionCatalog,
    followerReactionTicks = {},
    partySelection = partySelection,
    mart = mart,
  }
end

function T.compose_threads_the_script_mart_host()
  local seen = {}
  local double = {
    new = function(opts)
      seen.opts = opts
      return { scheduler = {}, worldState = {}, blackoutFlow = {} }
    end,
  }
  local savedTarget = package.loaded[TARGET_MODULE]
  local savedCompose = package.loaded[COMPOSE_MODULE]
  package.loaded[TARGET_MODULE] = double
  package.loaded[COMPOSE_MODULE] = nil
  local ok, err = pcall(function()
    local compose = require(COMPOSE_MODULE).compose
    local host = { scriptMartHost = true }
    compose(stubRuntime(), stubOptions(nil, host))
    Assert.equal(seen.opts and seen.opts.mart, host, "the scheduler receives the composed mart host")
  end)
  package.loaded[TARGET_MODULE] = savedTarget
  package.loaded[COMPOSE_MODULE] = savedCompose
  if not ok then
    error(err, 0)
  end
end

function T.compose_threads_the_party_selection_host()
  local seen = {}
  local double = {
    new = function(opts)
      seen.opts = opts
      return { scheduler = {}, worldState = {}, blackoutFlow = {} }
    end,
  }
  local savedTarget = package.loaded[TARGET_MODULE]
  local savedCompose = package.loaded[COMPOSE_MODULE]
  package.loaded[TARGET_MODULE] = double
  package.loaded[COMPOSE_MODULE] = nil
  local ok, err = pcall(function()
    local compose = require(COMPOSE_MODULE).compose
    local host = { scriptPartyHost = true }
    local runtime = stubRuntime()
    runtime.fashionCase = require("libs.hgss.src.save.FashionCaseState").empty()
    local result = compose(runtime, stubOptions(host))
    Assert.notNil(result.scripts, "composition still yields its scripts")
    Assert.equal(seen.opts and seen.opts.partySelection, host, "the host reaches scheduler services intact")
  end)
  package.loaded[TARGET_MODULE] = savedTarget
  package.loaded[COMPOSE_MODULE] = savedCompose
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
