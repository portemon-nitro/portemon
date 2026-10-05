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
  }
end

local function stubOptions(partySelection)
  return {
    cacheFs = {},
    layoutMessage = function(message)
      return message
    end,
    fontDef = {},
    audioService = nil,
    loadedGame = nil,
    mons = {},
    partySelection = partySelection,
  }
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
    local result = compose(stubRuntime(), stubOptions(host))
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
