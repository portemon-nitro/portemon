-- Route 30 tree interactions through the generated map, authored common
-- script, field scheduler, and live Apricorn ledger. Rendering stays trapped.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
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
    derivedAssets = { "field-runtime", "map-data:34", "map:34", "map-data:73", "map:73", "message-bank:150" },
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
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = worldState,
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = BagSave.empty(),
        mart = mart,
      }
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_ROUTE_30",
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, localClock = clock },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
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

local function interact(game)
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
  return snapshot
end

local function waitForDialogue(game, label)
  return game:advanceUntil(label, function(snapshot)
    return snapshot.dialogue.modal
  end, 180)
end

local function waitForTreeOutcome(game, expectedCount)
  return game:advanceUntil("source animation depletes the tree and resolves its grant", function()
    local mart = game.runtime.martService
    return not mart:treeAvailable(6) and mart:apricornQuantity(GREEN_APRICORN) == expectedCount
  end, 240)
end

function T.tests.tree_requires_the_box_then_grants_once_and_stays_interactive()
  withGame({ ownsBox = false, greenCount = 0 }, function(game)
    local actorId = standAtTree(game, route30Tree(game))
    local mart = assert(game.runtime.martService, "field runtime owns the Apricorn ledger")

    interact(game)
    waitForDialogue(game, "the tree explains that the Box is required")
    Assert.equal(mart:apricornQuantity(GREEN_APRICORN), 0, "a missing Box grants nothing")
    Assert.isTrue(mart:treeAvailable(6), "a missing Box does not deplete the tree")
    game:advanceDialogue()

    game:setWorldState({ flag = APRICORN_BOX })
    interact(game)
    game:advanceDialogue()
    waitForTreeOutcome(game, 1)
    Assert.equal(mart:apricornQuantity(GREEN_APRICORN), 1, "a fresh tree grants one matching Apricorn")
    Assert.isFalse(mart:treeAvailable(6), "the successful tree is depleted for this date")
    Assert.notNil(game:actor(actorId), "depletion keeps the source tree actor present")
    game:advanceDialogue()

    interact(game)
    waitForDialogue(game, "the depleted tree reports no fruit")
    Assert.equal(mart:apricornQuantity(GREEN_APRICORN), 1, "same-day repeat does not duplicate the reward")
    Assert.isFalse(mart:treeAvailable(6), "same-day repeat leaves the tree depleted")
    Assert.notNil(game:actor(actorId), "the depleted tree remains available for interaction")
    game:advanceDialogue()

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

    interact(game)
    game:advanceDialogue()
    waitForTreeOutcome(game, 99)
    Assert.equal(mart:apricornQuantity(GREEN_APRICORN), 99, "full stock refuses the additional Apricorn")
    Assert.isFalse(mart:treeAvailable(6), "the source animation depletes fruit before the capacity check")
    Assert.notNil(game:actor(actorId), "full stock does not remove the tree actor")
    waitForDialogue(game, "full Box message opens")
    game:advanceDialogue()
  end)
end

return T
