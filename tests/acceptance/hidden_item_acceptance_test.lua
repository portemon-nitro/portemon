-- Production-composed New Bark hidden-item pickup. The real field runtime,
-- generated map and member-145 script own selection, inventory, dialogue,
-- collection, and save state; the harness supplies only host boundaries.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "message-bank:210",
      "map-data:31",
      "map-data:33",
      "map-data:47",
      "map-data:48",
      "map-data:60",
      "map:60",
    },
    tags = { "field", "item", "interaction" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local PICKUP_SCRIPT = "common.hiddenitem_t20_potion"
local OVERLAPPING_ACTOR_ID = "map:60:object:0"
local ITEM_ID = 17
local ITEM_KEY = "POTION"
local ITEM_QUANTITY = 1
local COLLECTION_FLAG = 800
local UNRELATED_FLAG = 32774
local STACK_MAXIMUM = 999
local FAILURE_RESULT = 0
local SUCCESS_RESULT = 1

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      return FinalizedGameFixture.build(versionId, {
        location = { mapSymbol = TOWN, fieldX = 10, fieldZ = 8, facing = "north" },
      })
    end,
  })
end

---@param game AcceptanceGame
local function enterField(game)
  game:waitForFieldEntry()
  game:advanceUntil("New Bark is ready for ordinary input", function(snapshot)
    return not snapshot.fieldLocked and not snapshot.dialogue.modal
  end, 480)
  local map = assert(game.runtime.runtimeMap, "New Bark must be the active production map")
  Assert.equal(map.mapSymbol, TOWN, "the hidden item must run in New Bark Town")
  local event = nil
  for _, candidate in ipairs(map.fieldData.events.background) do
    if candidate.type == 2 and candidate.x == 682 and candidate.z == 391 then
      event = candidate
      break
    end
  end
  Assert.notNil(event, "New Bark's source map must contain the target hidden-item event")
  game.runtime.eventState:clearFlag(COLLECTION_FLAG)
  local player = game:snapshot().player
  Assert.deepEqual({ player.fieldX, player.fieldZ, player.facing }, { 682, 392, "north" })
  local actor = assert(game:actor(OVERLAPPING_ACTOR_ID), "the source object at the target tile must start present")
  Assert.deepEqual(
    { actor.fieldX, actor.fieldZ },
    { event.x, event.z },
    "the source object must be the reason the hidden-item tile starts occupied"
  )
  game:setActorRemovalFlag(OVERLAPPING_ACTOR_ID)
  game:step()
  game:step()
  Assert.isNil(game.runtime.actors:getById(OVERLAPPING_ACTOR_ID), "the source removal flag must clear the item tile")
  Assert.isFalse(
    game.runtime.eventState:isFlagSet(COLLECTION_FLAG),
    "clearing the actor must leave the item uncollected"
  )
end

---@param game AcceptanceGame
---@return integer
local function startedCount(game)
  return #game:recordsForScript(PICKUP_SCRIPT, "script.started")
end

---@param game AcceptanceGame
local function startPickup(game)
  local startsBefore = startedCount(game)
  local effectsBefore = #game:hostEffects()
  game:pressAction()
  local interaction = game:interaction()
  Assert.equal(
    interaction.scriptId,
    PICKUP_SCRIPT,
    "the adjacent retail hidden item must start its generated pickup script; got "
      .. tostring(interaction.scriptId)
      .. " (kind="
      .. tostring(interaction.kind)
      .. ", actor="
      .. tostring(interaction.actorId)
      .. ")"
  )
  Assert.equal(interaction.scriptSource, "vanilla", "pickup must use the generated retail binding")
  Assert.equal(startedCount(game), startsBefore + 1, "one Action edge must start one pickup root")
  return { index = startsBefore + 1, effectsBefore = effectsBefore }
end

---@param game AcceptanceGame
---@param instanceId integer
---@param effectsBefore integer
---@return { ended: boolean, fault: string|nil, completed: boolean, reason: string|nil, sawDialogue: boolean, sawFanfare: boolean }
local function drivePickupToEnd(game, instanceId, effectsBefore)
  local sawDialogue = false
  for _ = 1, 6000 do
    if game.runtime.errorText ~= nil then
      return {
        ended = false,
        fault = tostring(game.runtime.errorText),
        completed = false,
        reason = nil,
        sawDialogue = sawDialogue,
        sawFanfare = false,
      }
    end
    for _, record in ipairs(game:recordsForScript(PICKUP_SCRIPT, "script.ended")) do
      if record.payload.instanceId == instanceId then
        local fanfare = false
        local effects = game:hostEffects()
        for index = effectsBefore + 1, #effects do
          local effect = effects[index]
          if effect:find("fanfare:", 1, true) == 1 then
            fanfare = true
            break
          end
        end
        return {
          ended = true,
          fault = nil,
          completed = record.payload.completed == true,
          reason = record.payload.reason,
          sawDialogue = sawDialogue,
          sawFanfare = fanfare,
        }
      end
    end

    local snapshot = game:snapshot()
    if snapshot.dialogue.modal then
      sawDialogue = true
    end
    if snapshot.dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  return {
    ended = false,
    fault = "the pickup script did not end within the tick bound",
    completed = false,
    reason = nil,
    sawDialogue = sawDialogue,
    sawFanfare = false,
  }
end

---@param game AcceptanceGame
---@param startIndex integer
---@param expectedResult integer
---@return { completed: boolean, sawDialogue: boolean, sawFanfare: boolean }
local function assertPickupEnded(game, start, expectedResult)
  local started = assert(
    game:recordsForScript(PICKUP_SCRIPT, "script.started")[start.index],
    "the pickup root must have a scheduler start record"
  )
  local outcome = drivePickupToEnd(game, started.payload.instanceId, start.effectsBefore)
  Assert.isNil(outcome.fault, "the generated pickup script must not fault")
  Assert.isTrue(outcome.ended, "the generated pickup script must reach its source End")
  Assert.isTrue(outcome.completed, "the source branch must complete: " .. tostring(outcome.reason))
  Assert.isTrue(outcome.sawDialogue, "the source branch must show its ordinary dialogue")
  Assert.equal(
    #game:recordsForScript(PICKUP_SCRIPT, "script.error"),
    0,
    "the actual member-145 graph must not report a script error"
  )
  Assert.equal(
    game.runtime.scripts.worldState:getVar("VAR_SPECIAL_RESULT"),
    expectedResult,
    "the source branch must publish its normal special result"
  )
  for _, record in ipairs(game:recordsForScript(PICKUP_SCRIPT, "script.ended")) do
    if record.payload.instanceId == started.payload.instanceId then
      Assert.isFalse(
        record.payload.reason == "SCRIPT_UNSUPPORTED_REACHABLE",
        "the actual member-145 graph must not halt as unsupported"
      )
    end
  end
  Assert.equal(game:renderAttempts(), 0, "the production pickup flow must stop before GPU rendering")
  return {
    completed = outcome.completed,
    sawDialogue = outcome.sawDialogue,
    sawFanfare = outcome.sawFanfare,
  }
end

local function closeGame(game)
  local namespace = game.saveNamespace
  game:close()
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

function T.tests.new_bark_hidden_item_uses_the_source_script_and_persists_collection()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({
    versionId = versionId,
    map = TOWN,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    enterField(game)
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    local quantityBefore = bag:quantity(ITEM_KEY)
    Assert.isTrue(bag:hasSpaceNative(ITEM_ID, ITEM_QUANTITY), "the fresh Bag must have room for the source item")
    local scriptStart = startPickup(game)
    Assert.equal(game.runtime.scripts.worldState:getVar(0x8000), ITEM_ID, "the source item ID must be seeded")
    Assert.equal(game.runtime.scripts.worldState:getVar(0x8001), ITEM_QUANTITY, "the source quantity must be seeded")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(0x8002),
      COLLECTION_FLAG,
      "the source collection flag must be seeded"
    )
    assertPickupEnded(game, scriptStart, SUCCESS_RESULT)
    Assert.equal(bag:quantity(ITEM_KEY), quantityBefore + ITEM_QUANTITY, "the source script must grant one Potion")
    Assert.isTrue(game.runtime.eventState:isFlagSet(COLLECTION_FLAG), "the source script must collect flag 800")
    Assert.isFalse(game.runtime.eventState:isFlagSet(UNRELATED_FLAG), "pickup must not set variable-backed flag 32774")
    local fanfare = false
    for _, effect in ipairs(game:hostEffects()) do
      if effect:find("fanfare:", 1, true) == 1 then
        fanfare = true
        break
      end
    end
    Assert.isTrue(fanfare, "the actual source success path must play its fanfare")

    local startsAfterGrant = startedCount(game)
    game:pressAction()
    Assert.equal(startedCount(game), startsAfterGrant, "a collected hidden item must not start again")
    Assert.equal(bag:quantity(ITEM_KEY), quantityBefore + ITEM_QUANTITY, "a repeated Action must not grant again")

    game:save()
    game:restart()
    game:waitForFieldEntry()
    game:advanceUntil("the reloaded field is ready", function(snapshot)
      return not snapshot.fieldLocked and not snapshot.dialogue.modal
    end, 480)
    Assert.isTrue(game.runtime.eventState:isFlagSet(COLLECTION_FLAG), "save/reload must retain flag 800")
    Assert.equal(
      game.runtime.bagService:quantity(ITEM_KEY),
      quantityBefore + ITEM_QUANTITY,
      "save/reload must retain the source item"
    )
    local startsAfterReload = startedCount(game)
    game:pressAction()
    Assert.equal(startedCount(game), startsAfterReload, "the reloaded collection must remain ineligible")
    Assert.equal(
      game.runtime.bagService:quantity(ITEM_KEY),
      quantityBefore + ITEM_QUANTITY,
      "the reloaded hidden item must not grant again"
    )
  end, debug.traceback)
  closeGame(game)
  if not ok then
    error(err, 0)
  end

  local fullBagGame = harness():boot({
    versionId = versionId,
    map = TOWN,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local fullBagOk, fullBagErr = xpcall(function()
    enterField(fullBagGame)
    local bag = assert(fullBagGame.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add(ITEM_KEY, STACK_MAXIMUM), "the source stack maximum must fit in the live Bag")
    Assert.isFalse(bag:hasSpaceNative(ITEM_ID, ITEM_QUANTITY), "the hidden item must start with a full stack")
    local revisionBefore = bag:revision()
    local failedStart = startPickup(fullBagGame)
    assertPickupEnded(fullBagGame, failedStart, FAILURE_RESULT)
    Assert.equal(bag:quantity(ITEM_KEY), STACK_MAXIMUM, "a full-Bag failure must not grant")
    Assert.equal(bag:revision(), revisionBefore, "the source failure branch must not mutate Bag state")
    Assert.isFalse(fullBagGame.runtime.eventState:isFlagSet(COLLECTION_FLAG), "a full-Bag failure must not collect")
    Assert.isFalse(fullBagGame.runtime.eventState:isFlagSet(UNRELATED_FLAG), "failure must not set flag 32774")

    Assert.isTrue(bag:take(ITEM_KEY, 1), "removing one Potion through the live Bag must open stack capacity")
    Assert.isTrue(bag:hasSpaceNative(ITEM_ID, ITEM_QUANTITY), "the retry must have one slot of stack capacity")
    local retryStart = startPickup(fullBagGame)
    local success = assertPickupEnded(fullBagGame, retryStart, SUCCESS_RESULT)
    Assert.isTrue(success.sawFanfare, "the retry success branch must play the source fanfare")
    Assert.equal(bag:quantity(ITEM_KEY), STACK_MAXIMUM, "the retry must grant exactly one Potion")
    Assert.isTrue(
      fullBagGame.runtime.eventState:isFlagSet(COLLECTION_FLAG),
      "the successful retry must collect flag 800"
    )
    Assert.isFalse(
      fullBagGame.runtime.eventState:isFlagSet(UNRELATED_FLAG),
      "the successful retry must not set flag 32774"
    )
  end, debug.traceback)
  closeGame(fullBagGame)
  if not fullBagOk then
    error(fullBagErr, 0)
  end
end

return T
