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
    { time = "day", terrain = "plain", hour = 12 }
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

-- The coordinator publishes its already-computed scene prediction for
-- idle warmup without reselecting: the memo survives while the tile
-- matches, expires on tile/surface/map moves and during launches, and
-- never synthesizes a scene when nothing was prefetched. Reading the
-- prediction never enqueues another derived-asset request. Mutable clock
-- and avatar state ride an explicit box so stationary time-of-day and
-- movement changes are observable without wall clocks or sleeps; an
-- absent box keeps the historical clockless/movementless defaults.
local function predictionRuntime(requests, state)
  state = state or {}
  local runtime = {
    session = { currentMap = { mapId = 33, fieldData = { battleBackground = "general" } } },
    player = { fieldX = 5, fieldZ = 6, surfaceId = 0 },
    derivedAssets = {
      requestBattleScene = function(sceneKey, urgency)
        requests[#requests + 1] = sceneKey .. "@" .. urgency
        return false
      end,
    },
    arrivalBehavior = function()
      return nil
    end,
  }
  if state.clockHour ~= nil then
    runtime.localClock = {
      nowLocal = function()
        return { hour = state.clockHour }
      end,
    }
  end
  if state.movementMode ~= nil then
    runtime.playerAvatar = {
      status = function()
        return { durableState = state.movementMode }
      end,
    }
  end
  return runtime
end

function T.predicted_scene_key_tracks_memo_expiry_without_reselecting()
  Assert.isTrue(
    type(FieldBattleCoordinator.predictedSceneKey) == "function",
    "the coordinator publishes its memoized scene prediction for idle battle warmup"
  )
  local requests = {}
  local runtime = predictionRuntime(requests)
  local coordinator = FieldBattleCoordinator.new(runtime)
  coordinator:bindBattlePresentation(function(_)
    error("no launch is admitted by a prediction read", 0)
  end)
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "no prediction reads before the first prefetch"
  )
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "repeated reads still synthesize nothing before the first prefetch"
  )
  Assert.deepEqual(
    requests,
    {},
    "reads before the first prefetch enqueue no derived work"
  )
  coordinator:prefetchEncounterScene()
  Assert.deepEqual(
    requests,
    { "general/plain/day@near" },
    "the committed tile queues its scene once at near urgency"
  )
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/day",
    "the committed tile publishes its memoized scene"
  )
  Assert.deepEqual(
    requests,
    { "general/plain/day@near" },
    "reading the prediction enqueues no further derived work"
  )
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/day",
    "an unchanged tile keeps its memoized scene"
  )
  runtime.player.fieldX = 6
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "a moved tile expires the memo until the next prefetch"
  )
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/day",
    "the next prefetch at the new tile republishes the same scene"
  )
  Assert.deepEqual(
    requests,
    { "general/plain/day@near" },
    "an unchanged scene queues no second derived request"
  )
  runtime.player.surfaceId = 1
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "a surface change expires the memo until the next prefetch"
  )
  runtime.player.surfaceId = 0
  runtime.session.currentMap = { mapId = 99, fieldData = { battleBackground = "general" } }
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "a map change expires the memo until the next prefetch"
  )
  runtime.session.currentMap = { mapId = 33, fieldData = { battleBackground = "general" } }
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/day",
    "returning to the memoized tile republishes the scene"
  )
  coordinator._battleLaunch = { id = "launch-prediction-guard" }
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "an accepted launch hides the prediction while the battle owns the field"
  )
  coordinator._battleLaunch = nil
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/day",
    "clearing the launch restores the memoized scene"
  )
  local indoorRequests = {}
  local indoorState = { clockHour = 12 }
  local indoorRuntime = predictionRuntime(indoorRequests, indoorState)
  indoorRuntime.session.currentMap = { mapId = 61, fieldData = { battleBackground = "building_1" } }
  local indoor = FieldBattleCoordinator.new(indoorRuntime)
  indoor:bindBattlePresentation(function(_)
    error("no launch is admitted by a prediction read", 0)
  end)
  Assert.isNil(indoor:predictedSceneKey(), "no interior prediction reads before the first prefetch")
  Assert.deepEqual(indoorRequests, {}, "interior reads before the first prefetch enqueue no derived work")
  indoor:prefetchEncounterScene()
  Assert.equal(
    indoor:predictedSceneKey(),
    "building_1/building/day",
    "the interior publishes its day scene"
  )
  Assert.deepEqual(
    indoorRequests,
    { "building_1/building/day@near" },
    "the interior queues its scene once at near urgency"
  )
  indoorState.clockHour = 23
  Assert.isNil(
    indoor:predictedSceneKey(),
    "a night clock expires the interior memo until the next prefetch"
  )
  indoor:prefetchEncounterScene()
  Assert.equal(
    indoor:predictedSceneKey(),
    "building_1/building/day",
    "interiors keep day lighting after dark"
  )
  Assert.deepEqual(
    indoorRequests,
    { "building_1/building/day@near" },
    "an unchanged interior scene queues nothing new"
  )
  local indoorEnvironment = indoor:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "grass")
  Assert.equal(
    indoorEnvironment.sceneKey,
    "building_1/building/day",
    "the live interior launch agrees with the refreshed prediction"
  )
  Assert.equal(indoorEnvironment.time, "day", "interiors pin day lighting after dark")
  indoorState.clockHour = 12
  indoor:prefetchEncounterScene()
  Assert.deepEqual(
    indoorRequests,
    { "building_1/building/day@near" },
    "returning to the same band queues nothing new"
  )
end

-- A stationary outdoor prediction follows the civil clock: the memo
-- expires when the time band changes and the next prefetch publishes the
-- scene the live launch would select. Settled repeats queue nothing new.
function T.stationary_time_of_day_changes_refresh_the_predicted_scene()
  local requests = {}
  local state = { clockHour = 12 }
  local runtime = predictionRuntime(requests, state)
  local coordinator = FieldBattleCoordinator.new(runtime)
  coordinator:bindBattlePresentation(function(_)
    error("no launch is admitted by a prediction read", 0)
  end)
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/day",
    "midday publishes the day scene"
  )
  Assert.deepEqual(
    requests,
    { "general/plain/day@near" },
    "the midday tile queues its scene once at near urgency"
  )
  state.clockHour = 18
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "an evening clock expires the stationary memo until the next prefetch"
  )
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/evening",
    "the next prefetch publishes the evening scene"
  )
  Assert.deepEqual(
    requests,
    { "general/plain/day@near", "general/plain/evening@near" },
    "the evening scene queues exactly once"
  )
  local evening = coordinator:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "grass")
  Assert.equal(
    evening.sceneKey,
    "general/plain/evening",
    "the live evening launch agrees with the refreshed prediction"
  )
  state.clockHour = 23
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "a night clock expires the stationary memo until the next prefetch"
  )
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/night",
    "the next prefetch publishes the night scene"
  )
  Assert.deepEqual(
    requests,
    { "general/plain/day@near", "general/plain/evening@near", "general/plain/night@near" },
    "the night scene queues exactly once"
  )
  local night = coordinator:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "grass")
  Assert.equal(
    night.sceneKey,
    "general/plain/night",
    "the live night launch agrees with the refreshed prediction"
  )
  Assert.equal(night.time, "night", "the night launch carries its band")
  coordinator:prefetchEncounterScene()
  Assert.deepEqual(
    requests,
    { "general/plain/day@near", "general/plain/evening@near", "general/plain/night@near" },
    "a settled night prediction queues nothing new"
  )
end

-- A stationary prediction follows avatar movement and the authored map
-- background: surfing selects ocean water, walking restores the compiled
-- background, and each changed scene queues once while repeats stay quiet.
function T.stationary_movement_and_background_changes_refresh_the_predicted_scene()
  local requests = {}
  local state = { clockHour = 12, movementMode = "walking" }
  local runtime = predictionRuntime(requests, state)
  local coordinator = FieldBattleCoordinator.new(runtime)
  coordinator:bindBattlePresentation(function(_)
    error("no launch is admitted by a prediction read", 0)
  end)
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/day",
    "walking publishes the compiled background scene"
  )
  state.movementMode = "surfing"
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "surfing expires the stationary memo until the next prefetch"
  )
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "ocean/water/day",
    "the next prefetch publishes the surfing scene"
  )
  Assert.deepEqual(
    requests,
    { "general/plain/day@near", "ocean/water/day@near" },
    "the surfing scene queues exactly once"
  )
  local surf = coordinator:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "surf")
  Assert.equal(
    surf.sceneKey,
    "ocean/water/day",
    "the live surfing launch agrees with the refreshed prediction"
  )
  Assert.equal(surf.movementMode, "surfing", "the surfing launch carries its movement")
  state.movementMode = "walking"
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "walking again expires the stationary memo until the next prefetch"
  )
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "general/plain/day",
    "returning to walking restores the compiled background scene"
  )
  Assert.deepEqual(
    requests,
    { "general/plain/day@near", "ocean/water/day@near", "general/plain/day@near" },
    "the restored scene queues again only because its key changed"
  )
  runtime.session.currentMap.fieldData.battleBackground = "forest"
  Assert.isNil(
    coordinator:predictedSceneKey(),
    "an authored background swap expires the memo on the same map object"
  )
  coordinator:prefetchEncounterScene()
  Assert.equal(
    coordinator:predictedSceneKey(),
    "forest/grass/day",
    "the next prefetch publishes the authored background scene"
  )
  local forest = coordinator:_captureLaunchEnvironment({ kind = "wild", payload = {} }, "grass")
  Assert.equal(
    forest.sceneKey,
    "forest/grass/day",
    "the live forest launch agrees with the refreshed prediction"
  )
  coordinator:prefetchEncounterScene()
  Assert.deepEqual(
    requests,
    {
      "general/plain/day@near",
      "ocean/water/day@near",
      "general/plain/day@near",
      "forest/grass/day@near",
    },
    "a settled background prediction queues nothing new"
  )
end

-- Presented admission pre-seeds the launch without touching field audio:
-- the descriptor carries the lead and foe records for required-urgency
-- staging, the party warmup refreshes its bench near demands, and the
-- field policy stays active until the battle music voices with the
-- transition effect.
function T.presented_admission_preseeds_without_suspending_field_audio()
  local refreshed = 0
  local admitted = nil
  local runtime = {
    session = {
      currentMap = { mapId = 33, fieldData = { battleBackground = "general" } },
      setBattleActive = function() end,
      setForegroundHold = function() end,
    },
    player = { fieldX = 5, fieldZ = 6, surfaceId = 0 },
    playerData = { profile = { gender = 0 }, options = { textSpeed = "fastest" } },
    arrivalBehavior = function()
      return nil
    end,
    localClock = {
      nowLocal = function()
        return { hour = 12 }
      end,
    },
    audio = {
      suspendFieldPolicy = function()
        error("admission never suspends the field policy", 0)
      end,
    },
    monService = {
      partyMon = function(_, slot)
        assert(slot == 0, "admission pre-seeds the opening lead")
        return { species = "CHIKORITA", form = 0 }
      end,
    },
    refreshPartyWarmup = function()
      refreshed = refreshed + 1
    end,
  }
  local coordinator = FieldBattleCoordinator.new(runtime)
  coordinator:bindBattlePresentation(function(descriptor)
    admitted = descriptor
    return {}
  end)
  local foe = { species = "PIDGEY", form = 0 }
  local launchId =
    coordinator:launchPresentedBattle("wild#9", { id = "wild#9", kind = "wild", payload = {
      species = "PIDGEY",
      mon = foe,
    } }, nil)
  Assert.equal(launchId, "wild#9", "admission keeps its issued launch identity")
  Assert.notNil(admitted, "admission builds its presentation port")
  Assert.equal(admitted.leadMon.species, "CHIKORITA", "the descriptor pre-seeds the party lead")
  Assert.isTrue(admitted.foeMon == foe, "the descriptor pre-seeds the wild foe record")
  Assert.equal(refreshed, 1, "admission refreshes the bench near warmup once")
end

return { tests = T }
