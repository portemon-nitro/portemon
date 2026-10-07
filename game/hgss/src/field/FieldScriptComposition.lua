-- Builds the concrete field script hosts and scheduler-facing adapters.

local FieldScripts = require("game.hgss.src.field.FieldScripts")
local ScriptSave = require("libs.script.src.ScriptSave")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")
local TrainerCardStars = require("libs.hgss.src.save.TrainerCardStars")

---@class FieldScriptCompositionResult
---@field scripts FieldScripts
---@field restore fun()
---@class FieldScriptCompositionOptions
---@field cacheFs CacheFs
---@field layoutMessage fun(formatted: table<string, unknown>): table<string, unknown>
---@field fontDef table<string, unknown>
---@field audioService table<string, unknown>
---@field loadedGame table<string, unknown>?
---@field mons table<string, unknown> live HGSS mon service for mon/party script operations and text
---@field items table<string, unknown>? live HGSS Bag service for generic Bag/item script operations
---@field itemCatalog table<string, unknown> shared item catalog for item/pocket/TM/berry text
---@field followingMon table<string, unknown> the live following-mon controller for follower script operations
---@field starterProvider table<string, unknown>? the default starter roster for the blocking starter task
---@field starterChoice table<string, unknown>? the modal starter-choice surface the blocking task opens and closes
---@field partySelection table<string, unknown>? the modal script-party surface the blocking selection task opens and closes
---@field mart table<string, unknown>? the script-owned mart child host
---@field travel table<string, unknown>? the durable travel owner for spawn updates
---@field fieldMoves table<string, unknown>? the field-move runtime for task execution
---@field pokemonNaming table<string, unknown> the script-owned Pokemon Naming Screen host
---@field followerTransition table<string, unknown>? the transient follower-transition owner the nonblocking transition command starts
---@field starterBalls table<string, unknown>? the Elm starter-ball runtime-prop controller
---@field followerInteractionCatalog table<string, unknown> validated generated interaction catalog
---@field clock table<string, unknown> live local clock
---@field pcApplications table<string, unknown> script-owned PC application host
---@field pcTerminal table<string, unknown> PC terminal effect service
---@field battle table<string, unknown>? the battle host for script battle tasks (absent until the application wires it)
---@field pokemonCenterHeal table<string, unknown>? the runtime-owned blocking Pokémon Center choreography
local FieldScriptComposition = {}

local function currentTimeOfDayCode(runtime)
  return TimeOfDayProps.rtcCodeForHour(runtime.localClock:nowLocal().hour)
end

local function timeOfDayService(runtime)
  local function currentCode()
    return currentTimeOfDayCode(runtime)
  end
  return { currentCode = currentCode }
end

-- No Frontier gameplay owns a writer yet, so the current production
-- composition supplies a stateless non-qualifying Frontier capability. The
-- source predicate inside TrainerCardStars.count stays untouched for the
-- day a real Frontier subsystem injects a qualifying record.
local function frontierNeverQualifiesForTrainerCardStar()
  return false
end

local function trainerCardStarsService(runtime)
  local function count()
    local scripts = assert(runtime.scripts, "field script runtime is assigned before script execution")
    return TrainerCardStars.count(
      scripts.worldState,
      assert(runtime.dexKnowledge, "field runtime has no dex knowledge"),
      {
        qualifiesForTrainerCardStar = frontierNeverQualifiesForTrainerCardStar,
      }
    )
  end
  return { count = count }
end

---@param runtime FieldRuntime
---@param options FieldScriptCompositionOptions
---@return FieldScriptCompositionResult
function FieldScriptComposition.compose(runtime, options)
  assert(type(options) == "table", "field script composition options are required")
  assert(options.followerInteractionCatalog ~= nil, "the validated follower interaction catalog is required")
  assert(
    options.mons and options.itemCatalog and options.followingMon and options.clock,
    "follower interaction services are required"
  )
  assert(runtime.fashionCase ~= nil, "Fashion Case state is required for follower interactions")
  local function requestStartMenuReopen()
    runtime.applicationHost:requestReopen()
  end
  local function applyAvatarTransitionsForScripts()
    return runtime:applyAvatarTransitions()
  end
  local function changeWeather(_, weatherId)
    runtime:_setLiveWeather(assert(runtime.runtimeMap), weatherId)
  end
  local function blackoutSourceMap()
    return assert(runtime.runtimeMap, "blackout swaps require the live source map")
  end
  local scripts = FieldScripts.new({
    cacheFs = options.cacheFs,
    overrideFs = runtime.overrideFs,
    eventState = runtime.eventState,
    actors = runtime.actors,
    player = runtime.player,
    playerAvatar = runtime.playerAvatar,
    avatarApplier = applyAvatarTransitionsForScripts,
    profile = runtime.playerData.profile,
    dialogue = runtime.dialogue,
    messageProvider = runtime.messageProvider,
    layout = options.layoutMessage,
    fontDef = options.fontDef,
    frameIndex = runtime.playerData.options.textFrame,
    signpost = runtime.signpost,
    windowStyles = runtime.windowStyles,
    transition = runtime.transition,
    mapLoader = runtime.mapLoader,
    sourceMap = runtime.runtimeMap,
    seedText = runtime.versionId .. ":" .. runtime.runtimeMap.mapId,
    effects = runtime.fieldTerrainEffectController,
    audio = options.audioService,
    weather = { change = changeWeather },
    camera = runtime.scriptHosts and runtime.scriptHosts.camera,
    screen = runtime.screenFade,
    events = runtime.scriptHosts and runtime.scriptHosts.events,
    auxiliaryUi = runtime.auxiliaryFieldUi,
    contextChoice = runtime.contextChoiceProvider,
    menu = runtime.menuHost,
    yesNoHost = runtime.yesNoHost,
    startMenuReopen = { request = requestStartMenuReopen },
    mons = options.mons,
    items = options.items,
    itemCatalog = options.itemCatalog,
    followingMon = options.followingMon,
    followerInteractionCatalog = options.followerInteractionCatalog,
    clock = options.clock,
    fashionCase = runtime.fashionCase,
    starterProvider = options.starterProvider,
    starterChoice = options.starterChoice,
    partySelection = options.partySelection,
    mart = options.mart,
    travel = options.travel,
    fieldMoves = options.fieldMoves,
    pokemonNaming = options.pokemonNaming,
    followerTransition = options.followerTransition,
    starterBalls = options.starterBalls,
    pcApplications = runtime.pcApplicationHost,
    pcTerminal = runtime.pcTerminal,
    battle = options.battle,
    overworld = runtime.overworld,
    propAnimations = runtime.propAnimations,
    pokemonCenterHeal = runtime.pokemonCenterHeal,
    blackout = {
      loader = runtime.mapLoader,
      sourceMap = blackoutSourceMap,
    },
    timeOfDay = timeOfDayService(runtime),
    trainerCardStars = trainerCardStarsService(runtime),
  })
  runtime.blackoutFlow = assert(scripts.blackoutFlow)
  local function restore()
    if options.loadedGame then
      ScriptSave.restore(options.loadedGame.scripts, scripts.scheduler, 0)
      scripts.worldState:restoreRng(options.loadedGame.world)
    end
  end
  return {
    scripts = scripts,
    restore = restore,
  }
end

return FieldScriptComposition
