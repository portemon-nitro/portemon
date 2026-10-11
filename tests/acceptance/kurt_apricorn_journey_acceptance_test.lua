-- The generated Kurt house script owns the blocking Apricorn selection,
-- daily order state, and source-native Ball pickup continuation.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local BagSave = require("libs.hgss.src.save.BagSave")
local MartSave = require("libs.hgss.src.save.MartSave")
local LocalClock = require("game.src.LocalClock")
local FieldMovement = require("tests.acceptance.support.FieldMovement")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map:164",
      "map-data:164",
      "script-member:874",
      "message-bank:571",
      "apricorn-box:global",
    },
    tags = { "field", "apricorn", "kurt", "acceptance" },
  },
  tests = {},
}

local MAP = "MAP_AZALEA_KURT_HOUSE"
local KURT_SCRIPT = "vanilla.hgss.scr_seq.0874.script_001"
local STORY_COMPLETE = FieldScriptSymbols.flagsByName.FLAG_UNK_07C
local AZALEA_ROCKETS_DEFEATED = FieldScriptSymbols.flagsByName.FLAG_BEAT_AZALEA_ROCKETS
local MAKING_BALLS = FieldScriptSymbols.flagsByName.FLAG_DAILY_KURT_MAKING_BALLS
local APRICORN_KEYS = {
  "RED_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
}

local function seededMart(withPendingOrder)
  local mart = MartSave.empty()
  for _, key in ipairs(APRICORN_KEYS) do
    mart.apricorns[key] = 3
  end
  if withPendingOrder then
    mart.kurtOrder = { apricornKey = "WHT_APRICORN", quantity = 3 }
  end
  return mart
end

local function withGame(fn, options)
  options = options or {}
  local date = options.date or { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
  local clock = LocalClock.new(function()
    return date
  end)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local worldState = FieldEventState.new()
      worldState:setFlag(STORY_COMPLETE)
      worldState:setFlag(AZALEA_ROCKETS_DEFEATED)
      if options.makingBalls then
        worldState:setFlag(MAKING_BALLS)
      end
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map, fieldX = 5, fieldZ = 6, facing = "north" },
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
        mart = seededMart(options.pendingOrder == true),
      }
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, localClock = clock },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "Kurt's production script acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function tapDirection(game, direction)
  game.runtime:press(direction)
  game:step()
  game.runtime:release(direction)
end

local function fillBallPocketExceptFastBalls(game)
  local bag = assert(game.runtime.bagService, "the production field runtime owns the Bag")
  local catalog = assert(game.runtime.itemCatalog, "the production field runtime owns the item catalog")
  for _, itemKey in ipairs(catalog:itemKeys()) do
    if bag:pocketOf(itemKey) == "balls" and itemKey ~= "FAST_BALL" then
      local preparation = bag:prepareInventoryChanges(bag:revision(), {
        { op = "add", item = itemKey, quantity = 1 },
      })
      if preparation then
        preparation.publish()
      end
    end
  end
  Assert.isFalse(bag:hasSpace("FAST_BALL", 3), "the Ball pocket cannot fit Kurt's three FAST_BALLS")
  Assert.equal(bag:quantity("FAST_BALL"), 0, "the refused reward is not already in the Bag")
end

local function freeBallPocketSlot(game)
  local bag = assert(game.runtime.bagService, "the production field runtime owns the Bag")
  local catalog = assert(game.runtime.itemCatalog, "the production field runtime owns the item catalog")
  for _, itemKey in ipairs(catalog:itemKeys()) do
    if bag:pocketOf(itemKey) == "balls" and itemKey ~= "FAST_BALL" and bag:quantity(itemKey) > 0 then
      local preparation = bag:prepareInventoryChanges(bag:revision(), {
        { op = "take", item = itemKey, quantity = bag:quantity(itemKey) },
      })
      if preparation then
        preparation.publish()
        return
      end
    end
  end
  error("the full Balls pocket has no ordinary stack to remove", 0)
end

local function finishKurtPickup(game)
  for _ = 1, 3600 do
    local errors = game:recordsForScript(KURT_SCRIPT, "script.error")
    if #errors > 0 then
      error(
        "Kurt's generated pickup script faulted: "
          .. tostring(errors[1].payload.code)
          .. " command="
          .. tostring(errors[1].payload.context.command)
          .. " sourceOffset="
          .. tostring(errors[1].payload.context.sourceOffset),
        0
      )
    end
    if
      game.runtime.martService:pendingKurt() == nil
      and game.runtime.scripts.scheduler:foregroundScriptId() == nil
      and not game:snapshot().dialogue.modal
    then
      local errors = game:recordsForScript(KURT_SCRIPT, "script.error")
      Assert.equal(#errors, 0, "Kurt's generated pickup continuation completes without a script fault")
      return
    end
    if game:snapshot().dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error("Kurt's source pickup continuation did not clear its pending order", 0)
end

local function talkToKurt(game)
  local map = game.runtime.runtimeMap
  local mapId = assert(map.mapId, "Kurt's house has a loaded map identity")
  Assert.equal(map.mapSymbol, MAP, "the generated Azalea house map is active")
  local objects = assert(map.fieldData.events.objects, "the house exposes its source object events")
  local event = assert(objects[1], "Kurt is source object event zero")
  Assert.equal(event.objectEventId, 0, "Kurt is object event zero")
  Assert.equal(event.spriteId, 233, "object event zero is the source Kurt actor")
  Assert.equal(event.scriptId, 2, "Kurt's object invokes source script index one")
  local actorId = "map:" .. mapId .. ":object:" .. event.objectEventId
  local actor = assert(game.runtime.actors:getById(actorId), "Kurt is present in the field runtime")
  local position = actor:getFieldPosition()
  local approaches = {
    { x = position.fieldX, z = position.fieldZ + 1, facing = "north" },
    { x = position.fieldX - 1, z = position.fieldZ, facing = "east" },
    { x = position.fieldX + 1, z = position.fieldZ, facing = "west" },
    { x = position.fieldX, z = position.fieldZ - 1, facing = "south" },
  }
  local standing
  for _, approach in ipairs(approaches) do
    if FieldMovement.route(game, { fieldX = approach.x, fieldZ = approach.z }) ~= nil then
      game:moveTo({ fieldX = approach.x, fieldZ = approach.z })
      game:face(approach.facing)
      standing = approach
      break
    end
  end
  Assert.notNil(standing, "the production map has a reachable tile beside Kurt")
  game:pressAction()
  Assert.equal(game:interaction().actorId, actorId, "the field interaction targets Kurt")
  Assert.equal(game:interaction().scriptId, KURT_SCRIPT, "Kurt runs his generated source script")
end

local function advanceToKurtSelector(game)
  for _ = 1, 2400 do
    local errors = game:recordsForScript(KURT_SCRIPT, "script.error")
    if #errors > 0 then
      error(
        "Kurt's source script faulted before its selector: "
          .. tostring(errors[1].payload.code)
          .. " command="
          .. tostring(errors[1].payload.context.command)
          .. " sourceOffset="
          .. tostring(errors[1].payload.context.sourceOffset),
        0
      )
    end
    local host = game.runtime.kurtBoxHost
    if host ~= nil and host:status() ~= nil then
      local errors = game:recordsForScript(KURT_SCRIPT, "script.error")
      Assert.equal(#errors, 0, "Kurt's generated script reaches the selector without a script fault")
      host:setPresentationReady(assert(host:activeHandle()), true)
      return host
    end
    if game:snapshot().dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error("Kurt's source script did not open the Apricorn selector", 0)
end

local finishKurtConversation

local function cancelKurtSelector(game, host)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
  game:advanceUntil("cancel closes Kurt's selector", function()
    return host:status() == nil
  end, 120)
  finishKurtConversation(game)
end

local function selectKurtOrder(game, host, apricornKey, quantity)
  local status = assert(host:status(), "Kurt's source selector publishes its live status")
  Assert.equal(status.mode, "kurt_select", "the source script opens the shared selector in Kurt mode")
  local targetIndex
  for index, row in ipairs(assert(status.rows, "the selector lists all seven Apricorns")) do
    if row.apricornKey == apricornKey then
      targetIndex = index
    end
  end
  Assert.notNil(targetIndex, "the selected Apricorn has a row in the shared selector")
  while status.selectedIndex ~= targetIndex do
    local direction = status.selectedIndex < targetIndex and "south" or "north"
    tapDirection(game, direction)
    status = assert(host:status(), "Kurt's source selector stays open during color selection")
  end
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
  status = assert(host:status(), "confirming the focused row starts native row selection")
  Assert.equal(status.phase, "selection_delay")
  for _ = 1, 8 do
    if status.phase == "actions" then
      break
    end
    game:step()
    status = assert(host:status(), "Kurt's row transition keeps the selector open")
  end
  Assert.equal(status.phase, "actions", "the selected row finishes its native cursor delay")
  Assert.equal(status.rows[targetIndex].quantity, 3, "the selected color has enough source stock")
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
  status = assert(host:status(), "selecting the Apricorn opens quantity selection")
  Assert.equal(status.phase, "quantity")
  for _ = 2, quantity do
    tapDirection(game, "east")
    status = assert(host:status(), "Kurt's source selector stays open during quantity selection")
  end
  Assert.equal(status.quantity, quantity, "the shared selector holds the requested quantity")
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
  status = assert(host:status(), "the selected quantity opens the native confirmation prompt")
  Assert.equal(status.phase, "confirm")
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

finishKurtConversation = function(game)
  for _ = 1, 2400 do
    local errors = game:recordsForScript(KURT_SCRIPT, "script.error")
    if #errors > 0 then
      error(
        "Kurt's generated conversation faulted: "
          .. tostring(errors[1].payload.code)
          .. " command="
          .. tostring(errors[1].payload.context.command)
          .. " sourceOffset="
          .. tostring(errors[1].payload.context.sourceOffset),
        0
      )
    end
    if game.runtime.scripts.scheduler:foregroundScriptId() == nil and not game:snapshot().dialogue.modal then
      return
    end
    if game:snapshot().dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error("Kurt's source conversation did not finish", 0)
end

function T.tests.canceling_kurt_selection_keeps_apricorns_and_does_not_start_the_daily_order()
  withGame(function(game)
    local mart = assert(game.runtime.martService, "the field composition owns the Apricorn ledger")
    Assert.equal(mart:apricornTotal(), 21, "the fixture starts with three of each Apricorn")
    Assert.equal(mart:pendingKurt(), nil, "the fixture starts without a Kurt order")
    talkToKurt(game)

    local host = advanceToKurtSelector(game)
    local captured, reason = game.runtime:captureGameSave()
    Assert.isNil(captured, "the blocking selection cannot publish a half-accepted save")
    Assert.notNil(reason, "save denial explains that the field interaction is active")

    cancelKurtSelector(game, host)

    Assert.equal(mart:apricornTotal(), 21, "cancel does not consume any Apricorns")
    Assert.equal(mart:pendingKurt(), nil, "cancel does not create an order")
    Assert.isFalse(game.runtime.scripts.worldState:isFlagSet(MAKING_BALLS), "cancel does not set the daily making flag")

    talkToKurt(game)
    local reopenedHost = advanceToKurtSelector(game)
    Assert.equal(mart:apricornTotal(), 21, "retrying after cancel still leaves stock available")
    cancelKurtSelector(game, reopenedHost)
    Assert.equal(mart:pendingKurt(), nil, "reopening and canceling does not leave a stale order")
    local errors = game:recordsForScript(KURT_SCRIPT, "script.error")
    Assert.equal(#errors, 0, "cancel and retry return through the source script without a fault")
  end)
end

function T.tests.full_ball_pocket_refuses_kurts_reward_but_the_source_continuation_clears_the_order()
  withGame(function(game)
    local mart = assert(game.runtime.martService, "the field composition owns Kurt's saved order")
    local bag = assert(game.runtime.bagService, "the field composition owns ordinary Bag grants")
    Assert.equal(mart:pendingKurt().apricornKey, "WHT_APRICORN", "the ready order came from White Apricorns")
    Assert.equal(mart:pendingKurt().quantity, 3, "the ready order carries the selected quantity")
    fillBallPocketExceptFastBalls(game)

    talkToKurt(game)
    finishKurtPickup(game)

    Assert.equal(bag:quantity("FAST_BALL"), 0, "the ordinary item grant awards nothing when its pocket is full")
    Assert.equal(mart:pendingKurt(), nil, "native opcode 736 clears the order after the refused grant")
    Assert.isFalse(
      game.runtime.scripts.worldState:isFlagSet(MAKING_BALLS),
      "the source-ready pickup path does not restore the daily making flag"
    )

    freeBallPocketSlot(game)
    Assert.isTrue(bag:hasSpace("FAST_BALL", 3), "removing a Ball stack creates room after Kurt's failed award")
    Assert.equal(bag:quantity("FAST_BALL"), 0, "a later visit cannot recover the refused Balls")
    Assert.equal(mart:pendingKurt(), nil, "the source clear permanently removes the failed order")
  end, { pendingOrder = true })
end

function T.tests.kurt_order_spends_once_and_the_matching_ball_is_ready_after_midnight_reload()
  local date = { year = 2000, month = 1, day = 1, hour = 23, minute = 59, second = 50 }
  withGame(function(game)
    local mart = assert(game.runtime.martService, "the production field runtime owns Apricorn stock and Kurt's order")
    local world = game.runtime.scripts.worldState
    Assert.equal(mart:apricornQuantity("WHT_APRICORN"), 3, "the fixture starts with three White Apricorns")
    Assert.equal(mart:pendingKurt(), nil, "the fixture starts without an order")

    talkToKurt(game)
    local host = advanceToKurtSelector(game)
    selectKurtOrder(game, host, "WHT_APRICORN", 3)
    game:advanceUntil("Kurt accepts the selected Apricorn order", function()
      return mart:pendingKurt() ~= nil and world:isFlagSet(MAKING_BALLS)
    end, 1200)

    Assert.equal(mart:apricornQuantity("WHT_APRICORN"), 0, "confirm spends exactly the selected Apricorn quantity")
    Assert.equal(mart:apricornTotal(), 18, "confirm deducts no other Apricorn color")
    Assert.deepEqual(
      mart:pendingKurt(),
      { apricornKey = "WHT_APRICORN", quantity = 3 },
      "the live ledger records the selected color and quantity once"
    )
    Assert.isTrue(world:isFlagSet(MAKING_BALLS), "Kurt's source script marks the order as making today")

    finishKurtConversation(game)
    talkToKurt(game)
    finishKurtConversation(game)
    Assert.equal(mart:apricornQuantity("WHT_APRICORN"), 0, "talking again cannot spend the same stock twice")
    Assert.deepEqual(
      mart:pendingKurt(),
      { apricornKey = "WHT_APRICORN", quantity = 3 },
      "a pending order remains unique"
    )

    date.day = 2
    date.hour = 0
    date.minute = 0
    date.second = 1
    game:restart()
    game:waitForFieldEntry()
    local reloadedMart = assert(game.runtime.martService, "the reloaded runtime restores the Apricorn service")
    local reloadedBag = assert(game.runtime.bagService, "the reloaded runtime restores ordinary Ball grants")
    Assert.equal(reloadedMart:apricornQuantity("WHT_APRICORN"), 0, "save reload preserves the one-time deduction")
    Assert.deepEqual(
      reloadedMart:pendingKurt(),
      { apricornKey = "WHT_APRICORN", quantity = 3 },
      "save reload preserves the order until Kurt awards it"
    )
    Assert.isFalse(
      game.runtime.scripts.worldState:isFlagSet(MAKING_BALLS),
      "the next civil date clears the source-controlled daily making flag"
    )

    talkToKurt(game)
    finishKurtPickup(game)
    Assert.equal(reloadedBag:quantity("FAST_BALL"), 3, "White Apricorns produce the matching native Fast Balls")
    Assert.equal(reloadedMart:pendingKurt(), nil, "the source pickup continuation clears the completed order")
    Assert.equal(reloadedMart:apricornQuantity("WHT_APRICORN"), 0, "pickup does not deduct Apricorns again")
    Assert.isFalse(
      game.runtime.scripts.worldState:isFlagSet(MAKING_BALLS),
      "pickup leaves the daily making flag clear after rollover"
    )
  end, { date = date })
end

return T
