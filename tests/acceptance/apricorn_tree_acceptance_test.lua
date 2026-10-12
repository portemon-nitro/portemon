-- Route 30 tree interactions through the generated map, authored common
-- script, field scheduler, and live Apricorn ledger. Rendering stays trapped.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MartSave = require("libs.hgss.src.save.MartSave")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local LocalClock = require("game.src.LocalClock")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:33",
      "map:33",
      "map-data:48",
      "map:48",
      "map-data:34",
      "map:34",
      "map-data:35",
      "map:35",
      "map-data:67",
      "map:67",
      "map-data:73",
      "map:73",
      "message-bank:23",
      "message-bank:150",
      "audio-bank:702",
      "audio-bank:703",
      "audio-bank:709",
    },
    tags = { "field", "apricorn", "acceptance" },
  },
  tests = {},
}

local ROUTE_30_ID = MapCatalog.require("MAP_ROUTE_30").id
local GREEN_APRICORN = "GRN_APRICORN"
local APRICORN_BOX = FieldScriptSymbols.flagsByName.FLAG_GOT_APRICORN_BOX

local ADJACENT = {
  { facing = "south", dx = 0, dz = -1 },
  { facing = "north", dx = 0, dz = 1 },
  { facing = "east", dx = -1, dz = 0 },
  { facing = "west", dx = 1, dz = 0 },
}

local function bagFor(ownsBox)
  local bag = BagSave.empty()
  if ownsBox then
    bag.pockets.key_items[1] = { item = "APRICORN_BOX", quantity = 1 }
  end
  return bag
end

local function withGame(options, fn)
  local date = options.date or { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
  local clock = LocalClock.new(function()
    return date
  end)
  local game = AcceptanceHarness.new({
    gameFactory = function(versionId)
      local worldState = FieldEventState.new()
      if options.ownsBox then
        worldState:setFlag(APRICORN_BOX)
      end
      local mart = MartSave.empty()
      if options.greenCount > 0 then
        mart.apricorns[GREEN_APRICORN] = options.greenCount
      end
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = "MAP_ROUTE_30", fieldX = 10, fieldZ = 10, facing = "south" },
        playerData = {
          profile = {
            name = "GOLD",
            gender = 0,
            trainerId = 1,
            money = 3000,
            badges = 0,
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
          },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = worldState,
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = bagFor(options.ownsBox),
        mart = mart,
      }
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_ROUTE_30",
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      audioOutput = FakeAudioOutput.new(),
      recordingScriptHosts = true,
      localClock = clock,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game, date)
    Assert.equal(game:renderAttempts(), 0, "tree acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function route30Tree(game)
  local events = assert(game.runtime.runtimeMap.fieldData.events.objects)
  for _, event in ipairs(events) do
    if event.scriptId == "common.apricorn_tree" and event.param0 == 6 then
      return event
    end
  end
  error("generated Route 30 data has no tree at global index 6", 0)
end

local function treeSpriteId(game, actorId)
  local actor = assert(game.runtime.actors:getActor(actorId), "source tree actor remains present")
  local presentation = assert(game.runtime.apricornTreePresentation, "field runtime owns tree presentation")
  return presentation:spriteIdForTree(actor)
end

local function waitForTreeGesture(game, actorId, gesture)
  local expected = "apricorn_tree_" .. gesture
  for _ = 1, 240 do
    local actor = assert(game.runtime.actors:getActor(actorId), "source tree actor remains present")
    if actor:presentationState().gesturePose == expected then
      return
    end
    if game:snapshot().dialogue.waiting then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  local snapshot = game:snapshot()
  error(
    "tree did not enter its source "
      .. gesture
      .. " gesture within 240 ticks: script="
      .. tostring(snapshot.foregroundScript)
      .. " locked="
      .. tostring(snapshot.fieldLocked)
      .. " dialogue="
      .. tostring(snapshot.dialogue.modal)
      .. " available="
      .. tostring(game.runtime.martService:treeAvailable(6)),
    0
  )
end

local function standAtTree(game, event)
  local actorId = "map:" .. ROUTE_30_ID .. ":object:" .. event.objectEventId
  local actor = assert(game:actor(actorId), "the source tree actor remains present")
  for _, offset in ipairs(ADJACENT) do
    local ok = pcall(game.moveTo, game, {
      fieldX = actor.fieldX + offset.dx,
      fieldZ = actor.fieldZ + offset.dz,
    })
    if ok then
      game:face(offset.facing)
      return actorId
    end
  end
  error("Route 30 tree has no reachable adjacent interaction tile", 0)
end

local function interact(game, actorId)
  local snapshot = game:pressAction()
  local interaction = game:interaction()
  Assert.equal(
    interaction.scriptId,
    "common.apricorn_tree",
    "interaction executes the authored tree script; got "
      .. tostring(interaction.scriptId)
      .. " at "
      .. tostring(snapshot.player.fieldX)
      .. ","
      .. tostring(snapshot.player.fieldZ)
      .. " facing "
      .. tostring(snapshot.player.facing)
  )
  Assert.equal(interaction.actorId, actorId, "interaction targets the expected source tree actor")
  return snapshot
end

local function waitForDialogue(game, label)
  game:advanceUntil(label, function(snapshot)
    return snapshot.dialogue.modal
  end, 180)
end

local function advanceSourceMessage(game)
  game:advanceUntil("source dialogue reaches its input continuation", function(snapshot)
    return snapshot.dialogue.waiting
  end, 180)
  local requestId = game:snapshot().dialogue.requestId
  for _ = 1, 240 do
    local dialogue = game:snapshot().dialogue
    if not dialogue.modal or dialogue.requestId ~= requestId then
      return
    end
    if dialogue.waiting then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error("source dialogue message did not finish after its input edges", 0)
end

local function finishTreeScript(game, label, previousEventCount)
  local function ended()
    local records = game:hostEvents().records
    for index = previousEventCount + 1, #records do
      local event = records[index]
      if event.name == "script.ended" and event.payload.scriptId == "common.apricorn_tree" then
        return true
      end
    end
    return false
  end
  for _ = 1, 240 do
    if ended() then
      return
    end
    if game:snapshot().dialogue.waiting then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error("timed out waiting for " .. label .. " to finish", 0)
end

local function waitForTreeOutcome(game, expectedCount)
  return game:advanceUntil("source animation depletes the tree and resolves its grant", function()
    local mart = game.runtime.martService
    return not mart:treeAvailable(6) and mart:apricornQuantity(GREEN_APRICORN) == expectedCount
  end, 240)
end

function T.tests.tree_requires_the_box_then_grants_once_and_stays_interactive()
  withGame({ ownsBox = false, greenCount = 0 }, function(game, date)
    local actorId = standAtTree(game, route30Tree(game))
    local mart = assert(game.runtime.martService, "field runtime owns the Apricorn ledger")
    Assert.equal(treeSpriteId(game, actorId), 266, "a ripe green tree uses its source color visual")

    local eventCount = #game:hostEvents().records
    interact(game, actorId)
    waitForDialogue(game, "the tree explains that the Box is required")
    Assert.equal(mart:apricornQuantity(GREEN_APRICORN), 0, "a missing Box grants nothing")
    Assert.isTrue(mart:treeAvailable(6), "a missing Box does not deplete the tree")
    advanceSourceMessage(game)
    finishTreeScript(game, "no-Box source script finishes", eventCount)

    game:setWorldState({ flag = APRICORN_BOX })
    Assert.isTrue(game.runtime.bagService:add("APRICORN_BOX", 1), "Box pickup adds the native key item")
    eventCount = #game:hostEvents().records
    interact(game, actorId)
    waitForTreeGesture(game, actorId, "wiggle")
    Assert.equal(treeSpriteId(game, actorId), 262, "tree gestures use the full source animation resource")
    waitForDialogue(game, "the shaken tree message opens")
    advanceSourceMessage(game)
    waitForDialogue(game, "the Apricorn result message opens")
    advanceSourceMessage(game)
    waitForTreeOutcome(game, 1)
    Assert.equal(treeSpriteId(game, actorId), 262, "a depleted tree keeps the source base visual")
    Assert.equal(mart:apricornQuantity(GREEN_APRICORN), 1, "a fresh tree grants one matching Apricorn")
    Assert.isFalse(mart:treeAvailable(6), "the successful tree is depleted for this date")
    Assert.notNil(game:actor(actorId), "depletion keeps the source tree actor present")
    waitForDialogue(game, "the source result message opens")
    advanceSourceMessage(game)
    finishTreeScript(game, "successful harvest source script finishes", eventCount)

    eventCount = #game:hostEvents().records
    interact(game, actorId)
    waitForDialogue(game, "the depleted tree reports no fruit")
    Assert.equal(mart:apricornQuantity(GREEN_APRICORN), 1, "same-day repeat does not duplicate the reward")
    Assert.isFalse(mart:treeAvailable(6), "same-day repeat leaves the tree depleted")
    Assert.notNil(game:actor(actorId), "the depleted tree remains available for interaction")
    advanceSourceMessage(game)
    finishTreeScript(game, "depleted-tree source script finishes", eventCount)

    game.runtime:cancelPendingEncounter()
    local saved, saveError = game.runtime:captureGameSave()
    Assert.notNil(saved, "finished tree scripts restore through a stable save: " .. tostring(saveError))
    game:restart()
    game:waitForFieldEntry()
    local restoredMart = assert(game.runtime.martService)
    Assert.equal(restoredMart:apricornQuantity(GREEN_APRICORN), 1, "save restore keeps the harvested stock")
    Assert.isFalse(restoredMart:treeAvailable(6), "save restore keeps same-day depletion")
    Assert.isTrue(restoredMart:treeAvailable(7), "the neighboring tree retains independent identity")
    Assert.notNil(game:actor(actorId), "restore rebuilds the depleted actor without removing it")

    date.day = 2
    game:step()
    Assert.isTrue(restoredMart:treeAvailable(6), "the next civil date repopulates the tree")
    Assert.equal(restoredMart:apricornQuantity(GREEN_APRICORN), 1, "daily reset preserves harvested stock")
  end)
end

function T.tests.full_box_attempt_still_depletes_the_tree_without_adding_stock()
  withGame({ ownsBox = true, greenCount = 99 }, function(game)
    local actorId = standAtTree(game, route30Tree(game))
    local mart = assert(game.runtime.martService, "field runtime owns the Apricorn ledger")
    local eventCount = #game:hostEvents().records
    interact(game, actorId)
    waitForDialogue(game, "full Box tree explanation opens")
    advanceSourceMessage(game)
    waitForTreeOutcome(game, 99)
    Assert.equal(mart:apricornQuantity(GREEN_APRICORN), 99, "full stock refuses the additional Apricorn")
    Assert.isFalse(mart:treeAvailable(6), "the source animation depletes fruit before the capacity check")
    Assert.notNil(game:actor(actorId), "full stock does not remove the tree actor")
    waitForDialogue(game, "the shaken tree message opens")
    advanceSourceMessage(game)
    waitForDialogue(game, "the Apricorn result message opens")
    advanceSourceMessage(game)
    waitForDialogue(game, "full Box message opens")
    advanceSourceMessage(game)
    finishTreeScript(game, "full-Box source script finishes", eventCount)
  end)
end

return T
