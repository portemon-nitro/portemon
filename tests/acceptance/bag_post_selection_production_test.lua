-- Production-composed post-selection Bag journey: browse a stocked stack
-- through the action menu, the quantity picker, typed toss confirmation and
-- result messaging, the modal prompt, and a single acknowledged mutation,
-- with the browse selection intact throughout. Only host boundaries (save
-- root, render trap) stand in for production; the runtime, services, flow,
-- and generated assets stay production. No renderer or GPU call may occur.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:7", "map-data:45", "map-data:88", "map:7", "map:88" },
    tags = { "field", "bag" },
  },
  tests = {},
}

local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG
local BAG_ACTION = "vanilla.bag"
local BAG_APPLICATION = FieldApplicationIds.BAG
local GRANT_MAP = "MAP_LAKE_OF_RAGE"
local STACK_KEY = "POTION"

local function lakeHarness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = GRANT_MAP, fieldX = 30, fieldZ = 15, facing = "west" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = BagSave.empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
      }
    end,
  })
end

local function hostCallbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function hostPhase(game)
  return game.runtime.applicationHost:status().phase
end

local function openStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  return game:advanceUntil("start menu becomes modal", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 120)
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the start menu must own the tick")
  return assert(status.menu, "the menu phase must expose the controller status")
end

local function actionById(status, id)
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.id == id then
      return action
    end
  end
  return nil
end

local function cursorActionId(status)
  local position = assert(status.selectedPosition, "menu status must expose the selected position")
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.position == position then
      return action.id
    end
  end
  error("start menu cursor does not resolve to a visible action", 0)
end

local function navigateTo(game, state, id)
  for _ = 1, #menuStatus(game).actions + 1 do
    if cursorActionId(menuStatus(game)) == id then
      return
    end
    state:keypressed("s")
    game:step()
    state:keyreleased("s")
  end
  error("start menu never focuses the bag action", 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function tapDirection(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

local function bagView(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(
    status.phase,
    FieldApplicationHost.PHASES.application,
    "the bag application must own the tick while open"
  )
  Assert.equal(status.applicationId, BAG_APPLICATION, "the launched application must be the bag")
  local flow = assert(status.application, "the bag application must expose its flow status")
  local view = assert(flow.child, "the bag flow must expose its live leaf status")
  assert(type(view) == "table", "the bag status must be a record")
  return view
end

local function openBag(game, state)
  openStartMenu(game)
  local action = actionById(menuStatus(game), BAG_ACTION)
  Assert.isTrue(
    action ~= nil and action.enabled == true,
    "the unlocked bag must enable its start menu action through policy/capability composition"
  )
  navigateTo(game, state, BAG_ACTION)
  confirm(game)
  game:advanceUntil("bag application opens over the retained menu", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.application
  end, 120)
  return bagView(game)
end

local function bagFocus(view)
  local focus = view.focus
  Assert.isTrue(
    focus == "items" or focus == "tabs" or focus == "cancel",
    "the bag status must expose its focus region"
  )
  return focus
end

local function viewPocket(view)
  local pocket = view.pocket
  Assert.isTrue(type(pocket) == "string" and pocket ~= "", "the bag status must name its current pocket")
  return pocket
end

local function gotoPocket(game, state, pocket)
  for _ = 1, 160 do
    local view = bagView(game)
    if viewPocket(view) == pocket then
      return view
    end
    local focus = bagFocus(view)
    if focus == "tabs" then
      local candidate = view.tabFocusPocket
      Assert.isTrue(type(candidate) == "string" and candidate ~= "", "the bag status must name its focused tab")
      if candidate ~= viewPocket(view) then
        confirm(game)
      else
        tapDirection(game, state, "d")
      end
    elseif focus == "cancel" then
      tapDirection(game, state, "w")
    else
      tapDirection(game, state, "w")
    end
  end
  error("bag browse never reaches pocket " .. pocket .. " through directional input", 0)
end

local function openActionMenu(game, state)
  if bagFocus(bagView(game)) == "tabs" then
    tapDirection(game, state, "w")
  end
  confirm(game)
  local view = nil
  for _ = 1, 30 do
    game:step()
    view = bagView(game)
    if view.state == "action_menu" then
      break
    end
  end
  view = bagView(game)
  Assert.equal(view.state, "action_menu", "confirming an item must open the action menu")
  return view
end

local ACTION_NEIGHBORS = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

local function actionSlot(view, id)
  for _, action in ipairs(assert(view.actions, "the action menu must list its actions")) do
    if action.id == id then
      return assert(action.slot, "dynamic actions must carry their physical slot")
    end
  end
  return nil
end

local function chooseAction(game, state, id)
  local view = bagView(game)
  Assert.equal(view.state, "action_menu", "choosing an action requires the open action menu")
  local target = actionSlot(view, id)
  Assert.notNil(target, "the requested dynamic action must be present")
  local directions = { "up", "down", "left", "right" }
  for _ = 1, 8 do
    view = bagView(game)
    if view.actionNode == target then
      confirm(game)
      game:step()
      game:step()
      return bagView(game)
    end
    local node = assert(view.actionNode, "the action menu must expose its physical node")
    local queue = { { node = node, path = {} } }
    local seen = { [node] = true }
    local path
    local head = 1
    while head <= #queue and path == nil do
      local current = queue[head]
      head = head + 1
      for _, direction in ipairs(directions) do
        local nextNode = ACTION_NEIGHBORS[current.node][direction]
        if not seen[nextNode] then
          local nextPath = {}
          for index, step in ipairs(current.path) do
            nextPath[index] = step
          end
          nextPath[#nextPath + 1] = direction
          if nextNode == target then
            path = nextPath
            break
          end
          seen[nextNode] = true
          queue[#queue + 1] = { node = nextNode, path = nextPath }
        end
      end
    end
    local direction = assert(path and path[1], "the action node must be reachable")
    tapDirection(game, state, ({ up = "w", down = "s", left = "a", right = "d" })[direction])
  end
  error("the action menu never selects " .. id, 0)
end

function T.tests.stacked_toss_keeps_selection_types_messages_and_mutates_once()
  local game = lakeHarness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = GRANT_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:advanceUntil("field ready for ordinary input", function(snapshot)
      return not snapshot.fieldLocked and not snapshot.dialogue.modal
    end, 480)
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_BAG })
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add(STACK_KEY, 5), "setup stocks a tossable stack")
    local revision = bag:revision()

    openBag(game, state)
    gotoPocket(game, state, bag:pocketOf(STACK_KEY))
    local browsing = bagView(game)
    Assert.equal(browsing.state, "browsing", "setup reaches bag browsing")
    local selected = assert(browsing.selected, "browsing exposes its selected item")
    Assert.equal(selected.item, STACK_KEY, "browsing selects the stocked stack")

    local menu = openActionMenu(game, state)
    local message = assert(menu.lowerMessage, "the action menu publishes its lower message")
    Assert.equal(#message.visibleText, #message.fullText, "the action message reveals instantly")
    Assert.equal(
      (menu.selected or {}).item,
      STACK_KEY,
      "the action menu keeps the selected item context"
    )

    local latched = chooseAction(game, state, "toss")
    Assert.equal(
      latched.state,
      "action_menu",
      "activating toss latches feedback instead of dispatching immediately"
    )
    game:advanceUntil("quantity picker owns the tick", function()
      return bagView(game).state == "toss_quantity"
    end, 240)
    local picking = bagView(game)
    Assert.equal(picking.state, "toss_quantity", "feedback completion enters the quantity picker")

    confirm(game)
    game:advanceUntil("toss confirmation owns the tick", function()
      return bagView(game).state == "toss_confirm"
    end, 240)
    local confirming = bagView(game)
    Assert.equal(confirming.tossBase, "quantity", "a stacked toss retains the quantity base")
    local confirmMessage = assert(confirming.lowerMessage, "the confirmation publishes its lower message")
    Assert.isTrue(
      #confirmMessage.visibleText < #confirmMessage.fullText,
      "the confirmation message types out instead of appearing instantly"
    )
    Assert.isNil(confirming.yesNoPrompt, "the prompt stays closed while the confirmation prints")
    game:advanceUntil("confirmation message completes", function()
      local view = bagView(game)
      return view.yesNoPrompt ~= nil
    end, 600)
    local completed = bagView(game)
    Assert.notNil(completed.yesNoPrompt, "the prompt opens only after the confirmation finishes")

    confirm(game)
    for _ = 1, 9 do
      game:step()
    end
    local resulting = bagView(game)
    Assert.equal(resulting.state, "toss_confirm", "the yes choice starts the result message, not the mutation")
    Assert.equal(bag:revision(), revision, "the yes choice mutates nothing while the result prints")
    local resultMessage = assert(resulting.lowerMessage, "the result publishes its lower message")
    Assert.isTrue(
      #resultMessage.visibleText < #resultMessage.fullText,
      "the result message types out instead of mutating instantly"
    )
    game:advanceUntil("result message completes", function()
      local view = bagView(game)
      local current = view.lowerMessage
      return current ~= nil and #current.visibleText >= #current.fullText
    end, 600)
    confirm(game)
    game:step()
    game:step()
    Assert.equal(bag:quantity(STACK_KEY), 4, "acknowledgement after the result commits the picked copies once")
    Assert.equal(bag:revision(), revision + 1, "the stacked toss mutates exactly once")
    Assert.equal(bagView(game).state, "browsing", "the flow returns to browsing")
    Assert.equal(game:renderAttempts(), 0, "the production journey must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.field_runtime_closure_covers_the_bag_sound_bank()
  local set = {}
  for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
    set[job.kind .. ":" .. tostring(job.key)] = true
  end
  Assert.isTrue(set["audio-bank:750"] == true, "the fixed field-runtime roster includes the toss amount effect bank")
  Assert.isTrue(set["audio-bank:700"] == true, "the fixed field-runtime roster includes the select/cancel effect bank")
end

return T
