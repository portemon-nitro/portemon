-- Bounded Pokemon menu flow: real Bag Use/Give and Party Item/Summary
-- round trips through the composed flow with real services, real cursor,
-- real generated manifests, and real child applications. Stops before GPU
-- rendering like every acceptance path; production Start Menu wiring of
-- the flow arrives separately, so these scenarios compose the flow
-- directly at its public boundary with a contract-double field port.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BagCache = require("libs.assets.src.BagCache")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PartyCache = require("libs.assets.src.PartyCache")

local FLOW_MODULE = "game.hgss.src.field.PokemonMenuFlow"

local T = {
  metadata = { capabilities = { "rom_dump" }, derivedAssets = { "field-runtime", "map:7" }, tags = { "party", "bag", "flow" } },
  tests = {},
}

local BAG_NEIGHBORS = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "menu flow acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function requireFlow()
  local ok, flowModule = pcall(require, FLOW_MODULE)
  Assert.isTrue(ok, "the menu flow owns Bag/Party/Summary round trips: " .. tostring(flowModule))
  return assert(flowModule)
end

local function heroGender(game)
  local avatar = assert(game.runtime.avatar, "field runtime owns the player avatar")
  assert(avatar.gender == 0 or avatar.gender == 1, "the hero gender is binary")
  return avatar.gender == 0 and "male" or "female"
end

local function recordingIcons()
  local calls = { prepared = {}, cancels = 0 }
  local function prepare(iconKeys)
    local snapshot = {}
    for index, key in ipairs(iconKeys) do
      snapshot[index] = key
    end
    calls.prepared[#calls.prepared + 1] = snapshot
    return true, nil
  end
  local function cancel()
    calls.cancels = calls.cancels + 1
  end
  return { prepare = prepare, cancel = cancel, calls = calls }
end

local function openFlow(game, root)
  local Flow = requireFlow()
  local runtime = game.runtime
  local icons = recordingIcons()
  local mons = assert(runtime.monService, "field runtime owns the live mon service")
  local bag = assert(runtime.bagService, "field runtime owns the live bag service")
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local cacheFs = assert(runtime.cacheFs, "field runtime owns its asset filesystem")
  return Flow.new({
    root = root,
    mons = mons,
    bag = bag,
    bagCursor = assert(runtime.bagCursor, "field runtime owns the live bag cursor"),
    partyActions = actions,
    fieldMoves = {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = BagCache.loadManifest(cacheFs),
      partyManifest = PartyCache.loadManifest(cacheFs),
      uiManifest = assert(runtime.uiManifest, "field runtime owns the field-UI manifest"),
      monCatalog = assert(runtime.monCatalog, "field runtime owns the mon catalog"),
      itemCatalog = assert(runtime.itemCatalog, "field runtime owns the item catalog"),
      heroGender = heroGender(game),
    },
    measureDisplay = function()
      return runtime.presentationDisplay
    end,
    prepareIcons = icons.prepare,
    cancelIconPreparation = icons.cancel,
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
  })
end

local function givePair(game)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  Assert.isTrue(service:giveMon({ species = "CHIKORITA", level = 5 }), "setup gift must enter the party")
  Assert.isTrue(service:giveMon({ species = "TOTODILE", level = 5 }), "setup gift must enter the party")
end

local function injureLead(game, amount)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  local mon = service:partyMon(0)
  local maxHp = service:derive(mon).maxHp
  Assert.isTrue(maxHp > amount, "the injured fixture needs headroom above the wound")
  mon.condition.currentHp = maxHp - amount
  local revision = service:partyRevision()
  local preparation, reason = service:preparePartyChanges(revision, { { slot = 0, mon = mon } })
  Assert.isNil(reason, "injury staging must prepare cleanly")
  assert(preparation).publish()
  Assert.equal(service:partyMon(0).condition.currentHp, maxHp - amount, "injury staging must stick")
  return maxHp
end

local function flowStatus(flow)
  local status = flow:status()
  Assert.isTrue(status.open, "the flow stays open through the round trip")
  return status
end

local function drive(flow, events)
  flow:updateFixed(events)
  return flowStatus(flow)
end

local function driveUntil(flow, label, maxSteps, predicate)
  for _ = 1, maxSteps do
    local status = flowStatus(flow)
    if predicate(status) then
      return status
    end
    flow:updateFixed({})
  end
  error("the flow never reaches " .. label, 0)
end

local function bagChild(status)
  return assert(status.child, "the active page carries its child status")
end

-- Confirming a browsed item parks in the source selection entry before
-- the stable action menu opens: settle the generated transition clock
-- before callers read the action state or its actions.
local function chooseBagAction(flow, id)
  local status = drive(flow, { { type = "confirm" } })
  status = driveUntil(flow, "the stable action menu", 30, function(current)
    return current.child ~= nil and current.child.state == "action_menu"
  end)
  local child = bagChild(status)
  Assert.equal(child.state, "action_menu", "confirming an item must open the action menu")
  local target = nil
  for _, action in ipairs(assert(child.actions, "the action menu lists its actions")) do
    if action.id == id then
      target = assert(action.slot, "menu actions carry their physical slot")
    end
  end
  Assert.notNil(target, "the action menu must offer " .. id)
  for _ = 1, 8 do
    status = flowStatus(flow)
    child = bagChild(status)
    if child.actionNode == target then
      drive(flow, { { type = "confirm" } })
      -- Activation latches behind feedback before the semantic transition
      -- runs, so settle until the menu leaves or the flow changes pages.
      return driveUntil(flow, "the chosen action", 30, function(current)
        return current.page ~= "bag_browse"
          or current.child == nil
          or current.child.state ~= "action_menu"
      end)
    end
    local node = assert(child.actionNode, "the action menu exposes its node")
    local queue = { { node = node, path = {} } }
    local seen = { [node] = true }
    local path = nil
    local head = 1
    while head <= #queue and path == nil do
      local current = queue[head]
      head = head + 1
      for _, direction in ipairs({ "up", "down", "left", "right" }) do
        local nextNode = BAG_NEIGHBORS[current.node][direction]
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
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the action menu never selects " .. id, 0)
end

local function gotoPocket(flow, pocket)
  for _ = 1, 30 do
    local status = flowStatus(flow)
    local child = bagChild(status)
    if child.pocket == pocket and child.focus == "items" then
      return status
    end
    if child.focus == "tabs" then
      if child.tabFocusPocket == pocket then
        status = drive(flow, { { type = "confirm" } })
        status = drive(flow, { { type = "navigate", direction = "down" } })
      else
        status = drive(flow, { { type = "navigate", direction = "right" } })
      end
    else
      status = drive(flow, { { type = "navigate", direction = "up" } })
    end
  end
  error("the bag never reaches pocket " .. pocket, 0)
end

local PARTY_DIRECTIONS = { "right", "down", "left", "up" }

local function choosePartySlot(flow, slot)
  local probe = 1
  for _ = 1, 40 do
    local status = flowStatus(flow)
    local child = bagChild(status)
    if child.cursorNode == slot then
      return drive(flow, { { type = "confirm" } })
    end
    local direction = PARTY_DIRECTIONS[probe]
    probe = probe % #PARTY_DIRECTIONS + 1
    drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the party cursor never reaches slot " .. tostring(slot), 0)
end

local function choosePartyMenu(flow, kind)
  for _ = 1, 40 do
    local status = flowStatus(flow)
    local child = bagChild(status)
    local menu = assert(child.menu, "the party context menu must be open")
    local index = nil
    for position, entry in ipairs(menu) do
      if entry.kind == kind then
        index = position
      end
    end
    Assert.notNil(index, "the party menu must offer " .. kind)
    if child.menuIndex == index then
      -- Menu activation rides the visual press cadence before its single
      -- dispatch: settle the gate so callers read the dispatched submenu
      -- or intent state instead of the armed menu.
      drive(flow, { { type = "confirm" } })
      return driveUntil(flow, "the gated menu dispatch", 10, function(current)
        local dispatched = bagChild(current)
        return dispatched.menuPress == nil and (dispatched.menu ~= menu or dispatched.state ~= "context")
      end)
    end
    local direction = child.menuIndex < index and "down" or "up"
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the party menu never selects " .. kind, 0)
end

function T.tests.bag_medicine_round_trip_preserves_navigation()
  withGame(function(game)
    givePair(game)
    local maxHp = injureLead(game, 10)
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("POTION", 3), "the medicine fixture must stock potions")
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    cursor:setPocket("medicine")
    cursor:setPosition("medicine", 0)
    cursor:setScroll("medicine", 0)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local partyRevision = mons:partyRevision()

    local flow = openFlow(game, "bag")
    local status = driveUntil(flow, "the bag browse page", 30, function(current)
      return current.page == "bag_browse"
    end)
    local child = bagChild(status)
    Assert.equal(child.pocket, "medicine", "the flow opens on the borrowed cursor pocket")
    Assert.equal(
      child.selected and child.selected.item,
      "POTION",
      "the borrowed cursor position selects the stocked potion"
    )
    Assert.isNil(flow:takeResult(), "no terminal result fires on open")

    status = chooseBagAction(flow, "use")
    Assert.equal(status.page, "party_item_target", "choosing Use must open the party target page")
    status = drive(flow, { { type = "confirm" } })
    Assert.equal(
      mons:partyMon(0).condition.currentHp,
      maxHp,
      "confirming the injured lead must restore it through one publication"
    )
    Assert.equal(bag:quantity("POTION"), 2, "exactly one potion is consumed")
    Assert.isTrue(mons:partyRevision() == partyRevision + 1, "one party revision publishes the healing")

    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the originating bag page", 30, function(current)
      return current.page == "bag_browse"
    end)
    child = bagChild(status)
    Assert.equal(child.pocket, "medicine", "the return preserves the borrowed pocket")
    Assert.equal(child.selected and child.selected.item, "POTION", "the return reconciles onto the used key")
    Assert.equal(cursor:currentPocket(), "medicine", "the borrowed cursor survives the round trip")
    Assert.isNil(flow:takeResult(), "returning to the root reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.party_give_round_trip_preserves_target_identity()
  withGame(function(game)
    givePair(game)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("POTION", 2), "the give fixture must stock potions")
    Assert.isTrue(bag:add("SOOTHE_BELL", 1), "the picker boots on an occupied pocket")
    Assert.isTrue(bag:add("GREAT_BALL", 1), "the setup item must enter the bag")
    local setupActions = PartyActions.new({ mons = mons, bag = bag })
    local staged = setupActions:commit({
      kind = "give",
      slot = 1,
      partyRevision = mons:partyRevision(),
      bagRevision = bag:revision(),
      item = "GREAT_BALL",
      confirmed = true,
    })
    Assert.equal(staged.kind, "changed", "slot one must own its setup item")
    Assert.isTrue(bag:add("POTION", 1), "the replacement stock must survive setup")
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    local heldBefore = mons:partyMon(1).heldItem
    local revisionBefore = mons:partyRevision()

    local flow = openFlow(game, "party")
    local status = driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    status = choosePartySlot(flow, 1)
    status = choosePartyMenu(flow, "item")
    status = choosePartyMenu(flow, "give")
    Assert.equal(status.page, "bag_pick_held", "party Give must open the held-item picker")

    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the originating party page", 30, function(current)
      return current.page == "party_browse"
    end)
    Assert.equal(mons:partyMon(1).heldItem, heldBefore, "declining the picker must change nothing on the captured slot")
    Assert.equal(mons:partyRevision(), revisionBefore, "declining the picker publishes no revision")

    status = choosePartySlot(flow, 1)
    status = choosePartyMenu(flow, "item")
    status = choosePartyMenu(flow, "give")
    Assert.equal(status.page, "bag_pick_held", "reopening Give must return to the picker")
    status = gotoPocket(flow, "medicine")
    status = drive(flow, { { type = "confirm" } })
    Assert.equal(status.page, "party_give_confirm", "picking for an occupied holder must ask before publishing")
    status = drive(flow, {})
    status = drive(flow, { { type = "navigate", direction = "down" } })
    status = drive(flow, { { type = "confirm" } })
    status = driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    Assert.equal(cursor:currentPocket(), "medicine", "the pick writes picker navigation back")
    Assert.equal(mons:partyMon(1).heldItem, "POTION", "accepting must exchange onto slot one")
    Assert.isTrue(mons:partyRevision() == revisionBefore + 1, "exactly one revision publishes the exchange")
    Assert.equal(bag:quantity("POTION"), 2, "the picked stock decreases once")
    Assert.equal(bag:quantity("GREAT_BALL"), 1, "the displaced item returns to the bag once")
    Assert.isNil(flow:takeResult(), "returning to the root reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.summary_return_follows_displayed_mon()
  withGame(function(game)
    givePair(game)
    local flow = openFlow(game, "party")
    local status = driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    status = drive(flow, { { type = "confirm" } })
    status = choosePartyMenu(flow, "summary")
    Assert.equal(status.page, "summary", "choosing Summary must open the summary page")
    status = drive(flow, { { type = "navigate", direction = "right" } })
    local child = bagChild(status)
    Assert.equal(child.slot, 1, "moving right must display the second mon")
    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    status = drive(flow, {})
    child = bagChild(status)
    Assert.equal(child.cursorNode, 1, "the party must resume on the displayed mon with live data")
    Assert.isNil(flow:takeResult(), "returning to the root reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.bag_edge_cases_keep_prior_contracts_with_use_give()
  withGame(function(game)
    givePair(game)
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("POTION", 3), "the edge fixture must stock potions")
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    cursor:setPocket("medicine")

    local flow = openFlow(game, "bag")
    local status = driveUntil(flow, "the bag browse page", 30, function(current)
      return current.page == "bag_browse"
    end)
    status = drive(flow, { { type = "confirm" } })
    status = driveUntil(flow, "the stable action menu", 30, function(current)
      return current.child ~= nil and current.child.state == "action_menu"
    end)
    local child = bagChild(status)
    local ids = {}
    for _, action in ipairs(assert(child.actions, "the action menu lists its actions")) do
      ids[action.id] = action.slot
    end
    Assert.equal(ids.use, 0, "Use rides the source slot zero")
    Assert.equal(ids.give, 2, "Give rides the source slot two")
    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the cancelled menu", 30, function(current)
      return current.child == nil or current.child.state == "browsing"
    end)
    child = bagChild(status)
    Assert.isNil(child.actions, "cancelling the menu must leave browse state")

    status = chooseBagAction(flow, "toss")
    child = bagChild(status)
    Assert.equal(child.state, "toss_quantity", "the toss path must survive alongside Use/Give")
    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the cancelled picker", 30, function(current)
      return current.child == nil or current.child.state == "browsing"
    end)
    Assert.equal(bag:quantity("POTION"), 3, "backing out of toss must consume nothing")
    flow:dispose()
  end)
end

return T
