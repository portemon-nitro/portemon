-- Production-composed Route 30 Apricorn Box journey: collect it from the
-- Apricorn Man's authored house script, then use it from the live Bag while
-- the party is empty. The field runtime, generated scripts, assets, Bag and
-- modal flow stay production; only host callbacks and save storage are
-- supplied by the acceptance harness. This journey stops before rendering.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "field-runtime", "map:127", "map-data:127", "apricorn-box:global" },
    tags = { "field", "bag", "apricorn" },
  },
  tests = {},
}

local MAP = "MAP_ROUTE_30_APRICORN_HOUSE"
local BAG_ACTION = "vanilla.bag"
local BAG_APPLICATION = FieldApplicationIds.BAG
local BOX_KEY = "APRICORN_BOX"
local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG
local FLAG_GOT_APRICORN_BOX = FieldScriptSymbols.flagsByName.FLAG_GOT_APRICORN_BOX

local function callbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function hostStatus(game)
  return game.runtime.applicationHost:status()
end

local function bagView(game)
  local status = hostStatus(game)
  Assert.equal(status.phase, FieldApplicationHost.PHASES.application, "the Bag flow must own the tick")
  Assert.equal(status.applicationId, BAG_APPLICATION, "the live application remains the Bag")
  local flow = assert(status.application, "the application host exposes the active menu flow")
  Assert.equal(flow.root, "bag", "the flow remains rooted in the Bag")
  return assert(flow.child, "the Bag flow exposes its current screen status")
end

local function pressConfirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function tapDirection(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

local function openStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("the Start Menu opens", function()
    return hostStatus(game).phase == FieldApplicationHost.PHASES.menu
  end, 120)
end

local function startMenuStatus(game)
  local status = hostStatus(game)
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the Start Menu owns navigation")
  return assert(status.menu, "the Start Menu exposes its actions")
end

local function selectedMenuAction(status)
  for _, action in ipairs(assert(status.actions, "the Start Menu lists actions")) do
    if action.position == status.selectedPosition then
      return action.id
    end
  end
  error("Start Menu focus has no matching action", 0)
end

local function openBag(game, state)
  openStartMenu(game)
  for _ = 1, #startMenuStatus(game).actions + 1 do
    local status = startMenuStatus(game)
    if selectedMenuAction(status) == BAG_ACTION then
      break
    end
    tapDirection(game, state, "s")
  end
  Assert.equal(selectedMenuAction(startMenuStatus(game)), BAG_ACTION, "the Bag action is reachable")
  pressConfirm(game)
  game:advanceUntil("the Bag application opens", function()
    return hostStatus(game).phase == FieldApplicationHost.PHASES.application
  end, 120)
  game:advanceUntil("the Bag finishes its opening transition", function()
    local view = bagView(game)
    return view.state == nil or view.state == "browsing"
  end, 120)
  return bagView(game)
end

local function focusKeyItems(game, state)
  for _ = 1, 32 do
    local view = bagView(game)
    if view.pocket == "key_items" then
      return view
    end
    if view.focus == "tabs" then
      local target = assert(view.tabFocusPocket, "the Bag exposes its focused pocket tab")
      if target ~= view.pocket then
        pressConfirm(game)
      else
        tapDirection(game, state, "d")
      end
    else
      tapDirection(game, state, "w")
    end
  end
  error("the Bag never reaches the Key Items pocket", 0)
end

local function slotKey(slot)
  return assert(slot.item, "a non-empty Bag slot has an item key")
end

local function focusApricornBox(game, state)
  for _ = 1, 64 do
    local view = bagView(game)
    if view.selected ~= nil and slotKey(view.selected) == BOX_KEY and view.focus == "items" then
      return view
    end
    if view.focus == "tabs" then
      tapDirection(game, state, "s")
    elseif view.focus == "cancel" then
      tapDirection(game, state, "w")
    else
      tapDirection(game, state, "s")
    end
  end
  error("the Key Items pocket never focuses the Apricorn Box", 0)
end

local function openItemActions(game)
  pressConfirm(game)
  for _ = 1, 30 do
    local view = bagView(game)
    if view.state == "action_menu" then
      return view
    end
    game:step()
  end
  local status = bagView(game)
  local selected = status.selected
  local actions = status.actions or {}
  local actionIds = {}
  for _, action in ipairs(actions) do
    actionIds[#actionIds + 1] = tostring(action.id) .. "@" .. tostring(action.slot)
  end
  error(
    "selecting the Apricorn Box never opens its action menu; state="
      .. tostring(status.state)
      .. " selected="
      .. tostring(type(selected) == "table" and selected.item)
      .. " focus="
      .. tostring(status.focus)
      .. " actionNode="
      .. tostring(status.actionNode)
      .. " itemSelect="
      .. tostring(status.itemSelectElapsed)
      .. "/"
      .. tostring(status.itemSelectTotal)
      .. " actions=["
      .. table.concat(actionIds, ",")
      .. "]",
    0
  )
end

local function selectAction(game, state, targetSlot)
  local neighbors = {
    [0] = { up = 2, down = 2, left = 1, right = 1 },
    [1] = { up = 3, down = 3, left = 0, right = 0 },
    [2] = { up = 0, down = 0, left = 4, right = 3 },
    [3] = { up = 1, down = 1, left = 2, right = 4 },
    [4] = { up = 4, down = 4, left = 3, right = 2 },
  }
  local keys = { up = "w", down = "s", left = "a", right = "d" }
  for _ = 1, 8 do
    local view = bagView(game)
    Assert.equal(view.state, "action_menu", "selecting Use requires the Box action menu")
    if view.actionNode == targetSlot then
      pressConfirm(game)
      return
    end
    local queue = { { node = assert(view.actionNode), path = {} } }
    local seen = { [queue[1].node] = true }
    local path
    local head = 1
    while head <= #queue and path == nil do
      local current = queue[head]
      head = head + 1
      for direction, nextNode in pairs(neighbors[current.node]) do
        if not seen[nextNode] then
          local nextPath = {}
          for index, step in ipairs(current.path) do
            nextPath[index] = step
          end
          nextPath[#nextPath + 1] = direction
          if nextNode == targetSlot then
            path = nextPath
            break
          end
          seen[nextNode] = true
          queue[#queue + 1] = { node = nextNode, path = nextPath }
        end
      end
    end
    local direction = assert(path and path[1], "the Use action is reachable")
    tapDirection(game, state, keys[direction])
  end
  error("the Bag action cursor never selects Use", 0)
end

local function findApricornMan(game)
  local map = game.runtime.runtimeMap
  local mapId = assert(map.mapId, "the Route 30 house has a loaded map identity")
  local objects = assert(map.fieldData.events.objects, "the house exposes its source object events")
  Assert.equal(#objects, 1, "the source house contains its single NPC object")
  local event = assert(objects[1], "the source house NPC occupies object event zero")
  Assert.equal(event.objectEventId, 0, "the source house NPC is object event zero")
  Assert.equal(event.spriteId, 328, "the source house NPC uses the source Man 1 sprite")
  Assert.equal(event.scriptId, 1, "the source house NPC invokes the Box-giving script")
  local actorId = "map:" .. mapId .. ":object:" .. event.objectEventId
  local actor = game.runtime.actors:getById(actorId)
  Assert.notNil(actor, "the source house NPC is present in the fresh field runtime")
  return actorId, assert(actor)
end

local function talkToApricornMan(game)
  local actorId, actor = findApricornMan(game)
  local position = actor:getFieldPosition()
  local approaches = {
    { x = position.fieldX, z = position.fieldZ + 1, facing = "north" },
    { x = position.fieldX - 1, z = position.fieldZ, facing = "east" },
    { x = position.fieldX + 1, z = position.fieldZ, facing = "west" },
    { x = position.fieldX, z = position.fieldZ - 1, facing = "south" },
  }
  local standing = nil
  for _, approach in ipairs(approaches) do
    local route = FieldMovement.route(game, { fieldX = approach.x, fieldZ = approach.z })
    if route ~= nil then
      game:moveTo({ fieldX = approach.x, fieldZ = approach.z })
      game:face(approach.facing)
      standing = approach
      break
    end
  end
  Assert.notNil(standing, "the production map has a reachable interaction tile beside the Apricorn Man")
  game:pressAction()
  local interaction = game:interaction()
  Assert.equal(interaction.actorId, actorId, "the source interaction targets the Apricorn Man")
  Assert.isTrue(type(interaction.scriptId) == "string", "the house interaction starts its generated script")
  return interaction.scriptId
end

local function finishApricornManScript(game, scriptId)
  for _ = 1, 2400 do
    local snapshot = game:snapshot()
    if
      game.runtime.scripts.worldState:isFlagSet(FLAG_GOT_APRICORN_BOX)
      and game.runtime.bagService:quantity(BOX_KEY) == 1
      and not snapshot.fieldLocked
      and not snapshot.dialogue.modal
    then
      local errors = game:recordsForScript(scriptId, "script.error")
      Assert.equal(#errors, 0, "the Box-giving source script completes without a script fault")
      return
    end
    if snapshot.dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error("the source Apricorn Box script did not finish its dialogue and grant", 0)
end

function T.tests.route_30_apricorn_box_is_obtained_and_used_without_a_party_target()
  local harness = AcceptanceHarness.new()
  local defaultGameFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local gameState = defaultGameFactory(versionId, map)
    gameState.location = { mapSymbol = map, fieldX = 5, fieldZ = 6, facing = "north" }
    return gameState
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local state = callbacks(game)
    local bag = assert(game.runtime.bagService, "the production field runtime owns the Bag")
    local mart = assert(game.runtime.martService, "the production field runtime owns Apricorn stock")
    Assert.equal(bag:quantity(BOX_KEY), 0, "the fresh profile has not collected the Box")
    Assert.equal(game.runtime.monService:partyCount(), 0, "the acquisition path has no party members")
    game:setWorldState({ flag = FLAG_GOT_BAG })

    local scriptId = talkToApricornMan(game)
    finishApricornManScript(game, scriptId)
    Assert.equal(bag:quantity(BOX_KEY), 1, "the authored house script grants one Box")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(FLAG_GOT_APRICORN_BOX),
      "the acquisition records the vanilla Box flag"
    )

    local martBefore = mart:capture()
    local apricornBefore = mart:apricornTotal()
    openBag(game, state)
    focusKeyItems(game, state)
    focusApricornBox(game, state)
    local bagBeforeUse = bag:revision()
    local actions = openItemActions(game)
    local useSlot = nil
    for _, action in ipairs(assert(actions.actions, "the selected item action menu lists actions")) do
      if action.id == "use" then
        useSlot = action.slot
      end
    end
    Assert.notNil(useSlot, "the Apricorn Box offers Use even with an empty party")
    selectAction(game, state, useSlot)

    game:advanceUntil("the Box screen owns the active Bag flow", function()
      local status = hostStatus(game)
      local flow = status.phase == FieldApplicationHost.PHASES.application and status.application or nil
      return flow ~= nil and flow.page == "apricorn_box"
    end, 120)
    local flow = assert(hostStatus(game).application, "the Bag flow stays active while the Box is open")
    Assert.equal(flow.page, "apricorn_box", "Bag Use opens the Box directly without a party target")
    Assert.equal(bag:revision(), bagBeforeUse, "opening the Box does not change Bag inventory")
    Assert.equal(bag:quantity(BOX_KEY), 1, "the Box remains in the Bag while open")
    Assert.equal(mart:apricornTotal(), apricornBefore, "viewing the Box does not change Apricorn stock")
    Assert.deepEqual(mart:capture(), martBefore, "the read-only Box does not publish mart state")

    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    game:advanceUntil("closing the Box returns to the selected Bag item", function()
      local status = hostStatus(game)
      local flowStatus = status.phase == FieldApplicationHost.PHASES.application and status.application or nil
      local child = flowStatus and flowStatus.child or nil
      return flowStatus ~= nil
        and flowStatus.page == "bag_browse"
        and child ~= nil
        and child.selected ~= nil
        and child.selected.item == BOX_KEY
    end, 120)
    local returned = bagView(game)
    Assert.equal(returned.pocket, "key_items", "closing the Box returns to the prior Bag pocket")
    Assert.equal(slotKey(returned.selected), BOX_KEY, "closing the Box restores the previous Bag cursor")
    Assert.equal(bag:revision(), bagBeforeUse, "opening and closing the Box leave Bag revision unchanged")
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.registered_apricorn_box_opens_the_browse_page_from_field_input()
  local harness = AcceptanceHarness.new()
  local defaultGameFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local gameState = defaultGameFactory(versionId, map)
    gameState.location = { mapSymbol = map, fieldX = 5, fieldZ = 6, facing = "north" }
    gameState.bag = BagSave.empty()
    gameState.bag.pockets.key_items = { { item = "BICYCLE", quantity = 1 } }
    return gameState
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local state = callbacks(game)
    local bag = assert(game.runtime.bagService, "the production field runtime owns the Bag")
    game:setWorldState({ flag = FLAG_GOT_BAG })
    local scriptId = talkToApricornMan(game)
    finishApricornManScript(game, scriptId)

    Assert.deepEqual(bag:registeredItems(), {}, "the new profile has no registered item")
    local joystick = {
      getID = function()
        return 1
      end,
    }
    state:gamepadpressed(joystick, "y")
    game:step()
    state:gamepadreleased(joystick, "y")
    Assert.equal(hostStatus(game).phase, FieldApplicationHost.PHASES.closed, "Y does not open an unregistered Box")
    Assert.isNil(game.runtime.kurtBoxHost:status(), "unregistered Y leaves the Box closed")

    Assert.equal(bag:tryRegister("BICYCLE"), "slot1", "the different Key Item occupies the registered slot")
    state:gamepadpressed(joystick, "y")
    game:step()
    state:gamepadreleased(joystick, "y")
    Assert.equal(
      hostStatus(game).phase,
      FieldApplicationHost.PHASES.closed,
      "Y does not open the Apricorn Box when another Key Item is registered"
    )
    Assert.isNil(game.runtime.kurtBoxHost:status(), "another registered item leaves the Box closed")

    Assert.isTrue(bag:unregister("BICYCLE"), "the live Bag service clears the other registered Key Item")
    Assert.equal(bag:tryRegister(BOX_KEY), "slot1", "the live Bag service registers the Apricorn Box")
    state:gamepadpressed(joystick, "y")
    game:step()
    state:gamepadreleased(joystick, "y")
    game:advanceUntil("Y opens the Apricorn Box browse screen", function()
      local status = game.runtime.kurtBoxHost:status()
      return status ~= nil and status.hostMode == "browse" and status.phase == "browse"
    end, 120)
    local boxStatus = assert(game.runtime.kurtBoxHost:status(), "the registered shortcut opens the Apricorn Box")
    Assert.equal(boxStatus.hostMode, "browse", "the registered shortcut opens the browse screen")
    Assert.equal(boxStatus.phase, "browse", "the registered shortcut uses the native browse mode")
    Assert.equal(hostStatus(game).phase, FieldApplicationHost.PHASES.closed, "the shortcut does not open Start Menu")
    Assert.equal(game:renderAttempts(), 0, "the journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
