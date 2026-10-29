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
-- prediction never enqueues another derived-asset request.
local function predictionRuntime(requests)
  return {
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
end

return { tests = T }
