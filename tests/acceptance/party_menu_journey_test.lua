-- End-to-end menu journeys on the production composition: the Start
-- Menu opens the real Bag and Pokemon flows, medicine Use and held-item
-- Give/Take round trips conserve through live services, a UI-driven swap
-- plus Summary survives save/reload, deferred items stay safe and
-- non-consuming, and script selection answers through the live runtime
-- host. Stops before GPU rendering like every acceptance path. Deferred
-- capabilities (evolution, level-up items, mail, contests, storage,
-- battles) are out of scope and stay refused; journeys below never
-- convert them into successes.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local GameSave = require("libs.hgss.src.save.GameSave")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")

local T = {
  metadata = { capabilities = { "rom_dump" }, derivedAssets = { "field-runtime", "audio-bank:700", "audio-bank:730", "audio-bank:759", "map-data:7", "map:7", "summary:global" }, tags = { "party", "bag", "journey" } },
  tests = {},
}

local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG
local FLAG_GOT_STARTER = FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER

local function requireVersions(context)
  if context ~= nil and type(context.hasCapability) == "function" then
    if not context:hasCapability("rom_dump") then
      context:skip("requires rom_dump and prepared assets")
    end
  end
  local versions = { AcceptanceHarness.defaultVersion() }
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("menu journeys need a ready ROM cache", 0)
  end
  return versions
end

-- Headless summary leases resolve instantly with the validated family:
-- nothing draws (render attempts stay zero), so no portrait realizes.
---@param game table<string, unknown> booted acceptance game
local function bindSummaryLease(game)
  local SummaryCache = require("libs.assets.src.SummaryCache")
  local manifest = SummaryCache.loadManifest(assert(game.runtime.cacheFs, "the runtime owns its cache"))
  game.runtime:bindSummaryPreparation(function()
    local lease = {}
    function lease:prepare(demand)
      return { kind = "ready", key = demand.key, assets = { manifest = manifest } }
    end
    function lease:release()
    end
    return lease
  end)
end

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    -- Headless composition binds the explicit no-image preparation fake:
    -- the party reports ready without realizing GPU icons it never draws.
    game.runtime:bindPartyIconPreparation(function(_)
      return true
    end, function() end)
    bindSummaryLease(game)
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "menu journeys must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
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
  error("start menu never focuses " .. tostring(id), 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function cancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function giftPair(game)
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
  Assert.isTrue(status.open, "the production flow stays open through the journey")
  return status
end

local function drive(flow, events)
  flow:updateFixed(events)
  -- Summary-involved exits publish one extra full-black frame past the
  -- six-update shutter cadence; the loop still breaks early for shorter
  -- sibling transitions.
  for _ = 1, 10 do
    if flow:status().transition == nil then
      break
    end
    flow:updateFixed({})
  end
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

local function flowChild(status)
  return assert(status.child, "the active page carries its child status")
end

-- A fresh party page clears its open before input: wait for the leaf
-- to turn interactive, then run out the handover ticks that still drop
-- input so the first navigation acts.
local function drainOpen(flow)
  driveUntil(flow, "the open clears before input", 30, function(current)
    local child = current.child
    return child ~= nil and child.phase == "interactive"
  end)
  drive(flow, {})
  drive(flow, {})
end

local BAG_NEIGHBORS = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

-- Confirming a browsed item parks in the source selection entry before
-- the stable action menu opens: settle the generated transition clock
-- before callers read the action state or its actions.
local function chooseBagAction(flow, id)
  driveUntil(flow, "the Bag opening settles", 30, function(current)
    return current.child ~= nil and current.child.phase == "interactive"
  end)
  local status = drive(flow, { { type = "confirm" } })
  status = driveUntil(flow, "the stable action menu", 30, function(current)
    return current.child ~= nil and current.child.state == "action_menu"
  end)
  local child = flowChild(status)
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
    child = flowChild(status)
    if child.actionNode == target then
      status = drive(flow, { { type = "confirm" } })
      -- Confirming latches behind the action feedback before the semantic
      -- transition runs; settle the latch before callers read the next page.
      return driveUntil(flow, "the settled action transition", 30, function(current)
        return current.page ~= "bag_browse" or current.child == nil
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
    local child = flowChild(status)
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

local function choosePartySlot(flow, slot, direction)
  -- A fresh screen reports no cursor while icon preparation pends:
  -- wait for the visible cursor before navigating, or the first
  -- navigation overshoots a cursor that already sits on target.
  for _ = 1, 30 do
    if flowChild(flowStatus(flow)).cursorNode ~= nil then
      break
    end
    drive(flow, {})
  end
  for _ = 1, 12 do
    local status = flowStatus(flow)
    local child = flowChild(status)
    if child.cursorNode == slot then
      return drive(flow, { { type = "confirm" } })
    end
    drive(flow, { { type = "navigate", direction = direction or "right" } })
  end
  error("the party cursor never reaches slot " .. tostring(slot), 0)
end

local function choosePartyMenu(flow, kind)
  for _ = 1, 40 do
    local status = flowStatus(flow)
    local child = flowChild(status)
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
      -- dispatch: settle the gate so callers read the dispatched state.
      drive(flow, { { type = "confirm" } })
      return driveUntil(flow, "the gated menu dispatch", 10, function(current)
        local dispatched = flowChild(current)
        return dispatched.menuPress == nil and (dispatched.menu ~= menu or dispatched.state ~= "context")
      end)
    end
    local direction = child.menuIndex < index and "down" or "up"
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the party menu never selects " .. kind, 0)
end

local function composition(game)
  return assert(game.runtime.pokemonMenu, "the production runtime owns the menu composition")
end

function T.tests.production_medicine_give_take_round_trip(context)
  requireVersions(context)
  withGame(function(game)
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_STARTER })
    game:setWorldState({ flag = FLAG_GOT_BAG })
    giftPair(game)
    local maxHp = injureLead(game, 10)
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("POTION", 3), "the medicine fixture must stock potions")
    Assert.isTrue(bag:add("SOOTHE_BELL", 1), "the held fixture must stock a bell")
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")

    -- The Start Menu opens the production bag destination first.
    openStartMenu(game)
    navigateTo(game, state, "vanilla.bag")
    confirm(game)
    game:advanceUntil("the bag destination owns the tick", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)
    game:advanceUntil("the Bag opening settles before cancellation", function()
      local flow = game.runtime.applicationHost:status().application
      local leaf = flow ~= nil and flow.child or nil
      return leaf ~= nil and leaf.phase == "interactive"
    end, 120)
    cancel(game)
    game:advanceUntil("cancelling the flow returns to the menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    cancel(game)
    game:advanceUntil("cancelling the menu returns to the field", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.closed
    end, 120)

    -- Medicine Use through the production factory flow.
    local flow = composition(game).makeBagFlow()
    Assert.isTrue(flow:status().open, "the production bag flow opens")
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    cursor:setPocket("medicine")
    cursor:setPosition("medicine", 0)
    driveUntil(flow, "the Bag opening settles", 30, function(current)
      return current.child ~= nil and current.child.phase == "interactive"
    end)
    driveUntil(flow, "the bag browse page", 30, function(current)
      return current.page == "bag_browse"
    end)
    local status = chooseBagAction(flow, "use")
    Assert.equal(status.page, "party_item_target", "choosing Use must open the party target page")
    drainOpen(flow)
    status = drive(flow, { { type = "confirm" } })
    Assert.equal(
      mons:partyMon(0).condition.currentHp,
      maxHp,
      "confirming the injured lead must restore it through one publication"
    )
    Assert.equal(bag:quantity("POTION"), 2, "exactly one potion is consumed")
    status = drive(flow, { { type = "cancel" } })
    driveUntil(flow, "the originating bag page", 30, function(current)
      return current.page == "bag_browse"
    end)
    Assert.equal(cursor:currentPocket(), "medicine", "the borrowed cursor survives the healing leg")
    flow:dispose()

    -- Held-item Give through the picker, then Take back.
    local party = composition(game).makePartyFlow()
    drainOpen(party)
    driveUntil(party, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    local partyRevision = mons:partyRevision()
    choosePartySlot(party, 1)
    choosePartyMenu(party, "item")
    choosePartyMenu(party, "give")
    status = driveUntil(party, "the held-item picker", 30, function(current)
      return current.page == "bag_pick_held"
    end)
    Assert.isTrue(status.open, "party Give must open the held-item picker")
    driveUntil(party, "the held-item Bag opening settles", 30, function(current)
      return current.child ~= nil and current.child.phase == "interactive"
    end)
    status = gotoPocket(party, "medicine")
    status = drive(party, { { type = "confirm" } })
    driveUntil(party, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    driveUntil(party, "the Give result message", 30, function(current)
      return current.page == "party_browse" and current.child ~= nil and current.child.state == "message"
    end)
    drainOpen(party)
    drive(party, { { type = "confirm" } })
    driveUntil(party, "the acknowledged give result", 30, function(current)
      return current.page == "party_browse" and current.child ~= nil and current.child.state == "browse"
    end)
    drainOpen(party)
    Assert.equal(mons:partyMon(1).heldItem, "POTION", "accepting the pick must hold the potion on slot one")
    Assert.isTrue(mons:partyRevision() == partyRevision + 1, "exactly one revision publishes the give")
    choosePartySlot(party, 1)
    choosePartyMenu(party, "item")
    choosePartyMenu(party, "take")
    -- Take answers directly with no confirmation: settle the dispatch
    -- before asserting the transfer.
    for _ = 1, 15 do
      party:updateFixed({})
    end
    Assert.equal(mons:partyMon(1).heldItem, "NONE", "taking must clear the held slot")
    Assert.equal(bag:quantity("POTION"), 2, "the taken potion returns to the bag exactly once")
    Assert.isNil(party:takeResult(), "returning to the root reports no terminal result")
    party:dispose()
  end)
end

local function exerciseBagTargetPrompt(game, item, pocket, action, targetPage, prompt)
  giftPair(game)
  local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
  Assert.isTrue(bag:add(item, 1), "the target-prompt fixture must stock " .. item)
  local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
  cursor:setPocket(pocket)
  cursor:setPosition(pocket, 0)
  local flow = composition(game).makeBagFlow()
  driveUntil(flow, "the bag browse page", 30, function(current)
    return current.page == "bag_browse"
  end)

  local status = chooseBagAction(flow, action)
  Assert.equal(status.page, targetPage, "the Bag operation must enter its matching Party target context")
  drainOpen(flow)
  local child = flowChild(flow:status())
  Assert.equal(child.state, "choosing_item_target", "target operations share Party target navigation")
  if prompt == nil then
    Assert.equal(child.context, "give_target", "Bag Give keeps its source Party target context")
  else
    Assert.equal(child.targetPromptKey, prompt, "the Party presentation carries the operation's lower prompt")
  end

  drive(flow, { { type = "navigate", direction = "right" } })
  child = flowChild(flow:status())
  if prompt == nil then
    Assert.equal(child.context, "give_target", "target navigation preserves Bag Give")
  else
    Assert.equal(child.targetPromptKey, prompt, "target navigation keeps the operation prompt visible")
  end
  flow:dispose()
end

function T.tests.production_bag_give_keeps_its_party_target_context(context)
  requireVersions(context)
  withGame(function(game)
    exerciseBagTargetPrompt(game, "GREAT_BALL", "balls", "give", "party_give_target", nil)
  end)
end

function T.tests.production_ordinary_item_use_shows_its_target_prompt(context)
  requireVersions(context)
  withGame(function(game)
    exerciseBagTargetPrompt(game, "POTION", "medicine", "use", "party_item_target", "useTarget")
  end)
end

function T.tests.production_machine_use_shows_its_target_prompt(context)
  requireVersions(context)
  withGame(function(game)
    exerciseBagTargetPrompt(game, "TM28", "tmhm", "use", "party_item_target", "teachTarget")
  end)
end

function T.tests.production_swap_summary_save_reload_persists(context)
  requireVersions(context)
  withGame(function(game)
    giftPair(game)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("POTION", 1), "the journey fixture must stock a potion")
    local party = composition(game).makePartyFlow()
    driveUntil(party, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    drainOpen(party)
    -- A UI-driven switch commits once at the end of its animation.
    choosePartySlot(party, 1)
    choosePartyMenu(party, "switch")
    choosePartySlot(party, 0, "left")
    drive(party, { { type = "confirm" } })
    for _ = 1, 40 do
      party:updateFixed({})
    end
    Assert.equal(mons:partyMon(0).species, "TOTODILE", "the UI switch reorders the live party")
    -- Summary opens on the displayed member and returns to it.
    choosePartySlot(party, 0)
    choosePartyMenu(party, "summary")
    local status = driveUntil(party, "the summary page", 30, function(current)
      return current.page == "summary"
    end)
    Assert.isTrue(status.open, "summary opens for the focused member")
    drive(party, { { type = "cancel" } })
    local returned = nil
    for _ = 1, 30 do
      returned = flowChild(party:status()).cursorNode
      if returned ~= nil then
        break
      end
      drive(party, {})
    end
    Assert.equal(returned, 0, "summary returns to the displayed member")
    party:dispose()
    -- Save, reload, and prove the journey state persists.
    local record = assert(game.runtime:captureGameSave(), "a settled field captures")
    Assert.equal(record.schema, GameSave.SCHEMA, "capture writes the current save schema")
    game:restart()
    game:waitForFieldEntry()
    -- The restart boots a fresh runtime: rebind the headless
    -- preparation fake the previous runtime carried.
    game.runtime:bindPartyIconPreparation(function(_)
      return true
    end, function() end)
    bindSummaryLease(game)
    local fresh = game.runtime
    Assert.equal(fresh.monService:partyMon(0).species, "TOTODILE", "reload preserves the switched order")
    Assert.equal(fresh.monService:partyMon(1).species, "CHIKORITA", "reload preserves the full order")
    Assert.equal(fresh.bagService:quantity("POTION"), 1, "reload preserves inventory quantities")
    -- The Start Menu still opens the native flow after reload: no old UI.
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_STARTER })
    openStartMenu(game)
    navigateTo(game, state, "vanilla.pokemon")
    confirm(game)
    game:advanceUntil("the pokemon destination owns the tick", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)
    game:advanceUntil("the open clears before the close", function()
      local hostStatus = game.runtime.applicationHost:status()
      if hostStatus.phase ~= FieldApplicationHost.PHASES.application then
        return false
      end
      local flow = hostStatus.application
      local leaf = flow ~= nil and flow.child or nil
      return leaf ~= nil and leaf.phase == "interactive"
    end, 120)
    game:step()
    game:step()
    local child = game.runtime.applicationHost:status()
    Assert.equal(child.phase, FieldApplicationHost.PHASES.application, "the pokemon destination owns the tick")
    cancel(game)
    game:advanceUntil("cancelling the flow returns to the menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    cancel(game)
    game:advanceUntil("cancelling the menu returns to the field", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.closed
    end, 120)
  end)
end

function T.tests.production_deferred_use_reports_without_consuming(context)
  requireVersions(context)
  withGame(function(game)
    giftPair(game)
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("RARE_CANDY", 2), "the deferred fixture must stock rare candies")
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local monRevision = mons:partyRevision()
    local bagRevision = bag:revision()
    local flow = composition(game).makeBagFlow()
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    -- Find the stocked pocket and index through the live inventory,
    -- then park the borrowed cursor exactly on the candy.
    local candyPocket, candyIndex = nil, nil
    for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
      for index, entry in ipairs(bag:pocketItems(pocket)) do
        if entry.item == "RARE_CANDY" then
          candyPocket = pocket
          candyIndex = index - 1
        end
      end
    end
    Assert.notNil(candyPocket, "the stocked candy must live in some pocket")
    cursor:setPocket(candyPocket)
    cursor:setPosition(candyPocket, assert(candyIndex, "candy index resolved"))
    driveUntil(flow, "the bag browse page", 30, function(current)
      return current.page == "bag_browse"
    end)
    -- The page opens on the tab strip: enter the stocked pocket first,
    -- then step down to the candy with a tight bound (it is the only
    -- stocked entry, so the walk is short and cannot wander off-page).
    gotoPocket(flow, candyPocket)
    local selected = nil
    for _ = 1, 6 do
      selected = flowChild(flowStatus(flow)).selected
      if selected ~= nil and selected.item == "RARE_CANDY" then
        break
      end
      drive(flow, { { type = "navigate", direction = "down" } })
    end
    Assert.equal(selected ~= nil and selected.item, "RARE_CANDY", "the stocked candy must be reachable")
    local status = chooseBagAction(flow, "use")
    Assert.isTrue(status.open, "a deferred use must not crash the flow")
    Assert.equal(bag:quantity("RARE_CANDY"), 2, "a deferred use consumes nothing")
    Assert.equal(mons:partyRevision(), monRevision, "a deferred use publishes no mon revision")
    Assert.equal(bag:revision(), bagRevision, "a deferred use publishes no bag revision")
    Assert.isNil(flow:takeResult(), "a deferred use reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.production_script_selection_answers_through_the_live_host(context)
  requireVersions(context)
  withGame(function(game)
    giftPair(game)
    local runtime = game.runtime
    local host = assert(runtime.partySelection, "the production runtime owns the script party host")
    Assert.isNil(host:status(), "a fresh boot owns no open selection")
    local mons = assert(runtime.monService, "field runtime owns the live mon service")
    local handle = assert(
      host:open({ focus = 1, allowCancel = true, policy = "occupied" }),
      "opening a script selection on the live party must succeed"
    )
    -- The open clears before input: run out the covered ticks plus
    -- the handover ticks so the first navigation acts.
    for _ = 1, 30 do
      local status = host:status()
      if status ~= nil and status.phase == "interactive" then
        break
      end
      host:step(handle, {})
    end
    host:step(handle, {})
    host:step(handle, {})
    local focused = nil
    for _ = 1, 12 do
      host:step(handle, {})
      focused = host:focus(handle)
      if focused == 1 then
        break
      end
      host:step(handle, { { type = "navigate", direction = "down" } })
    end
    Assert.equal(host:focus(handle), 1, "the live host focuses the requested slot")
    host:step(handle, { { type = "confirm" } })
    local result = host:result(handle)
    Assert.notNil(result, "confirming a live slot answers exactly once")
    Assert.equal(result.kind, "selected", "the live answer selects")
    Assert.equal(result.slot, 1, "the live answer carries the focused slot")
    Assert.equal(mons:partyMon(result.slot).species, "TOTODILE", "the live answer resolves against current party data")
    Assert.isNil(host:result(handle), "the live answer is one-shot")
    host:close(handle)
    Assert.isNil(host:status(), "closing releases the live selection")
  end)
end

function T.tests.production_empty_take_reports_the_generated_template_without_mutation(context)
  requireVersions(context)
  withGame(function(game)
    giftPair(game)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    local partyRevision = mons:partyRevision()
    local bagRevision = bag:revision()
    local flow = composition(game).makePartyFlow()
    driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    drainOpen(flow)
    choosePartySlot(flow, 0)
    choosePartyMenu(flow, "item")
    choosePartyMenu(flow, "take")
    local status = flowStatus(flow)
    local child = flowChild(status)
    Assert.equal(child.state, "message", "an empty Take answers with its message")
    local message = child.message
    Assert.equal(type(message), "table", "an empty Take renders the generated template")
    Assert.equal(message.templateKey, "takeNoItem", "an empty Take shows the empty-take template")
    Assert.equal(
      message.displayName,
      assert(child.view, "the party child carries its view").slots[1].displayName,
      "an empty Take names the acting mon the party screen shows"
    )
    Assert.equal(mons:partyMon(0).heldItem, "NONE", "an empty Take holds nothing new")
    Assert.equal(mons:partyRevision(), partyRevision, "an empty Take publishes no mon revision")
    Assert.equal(bag:revision(), bagRevision, "an empty Take publishes no bag revision")
    Assert.isNil(flow:takeResult(), "an empty Take reports no terminal result")
    drive(flow, { { type = "confirm" } })
    driveUntil(flow, "the dismissed message", 30, function(current)
      return flowChild(current).state == "browse"
    end)
    status = flowStatus(flow)
    Assert.equal(status.page, "party_browse", "dismissal stays on party browse")
    Assert.equal(flowChild(status).cursorNode, 0, "dismissal refocuses the same slot")
    Assert.isNil(flow:takeResult(), "dismissal reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.production_held_take_keeps_its_transfer(context)
  requireVersions(context)
  withGame(function(game)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    Assert.isTrue(
      mons:giveMon({ species = "CHIKORITA", level = 5, heldItem = "POTION" }),
      "setup gift must enter the party holding a potion"
    )
    Assert.isTrue(mons:giveMon({ species = "TOTODILE", level = 5 }), "setup gift must enter the party")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    local bagQuantity = bag:quantity("POTION")
    local partyRevision = mons:partyRevision()
    local bagRevision = bag:revision()
    local flow = composition(game).makePartyFlow()
    driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    drainOpen(flow)
    choosePartySlot(flow, 0)
    choosePartyMenu(flow, "item")
    choosePartyMenu(flow, "take")
    -- Answer the confirmation while the composition asks one: a direct
    -- Take settles without it, so only answer a visibly open prompt.
    for _ = 1, 10 do
      local leaf = flowChild(flowStatus(flow))
      if leaf.prompt == nil and leaf.state ~= "confirm" then
        break
      end
      drive(flow, { { type = "navigate", direction = "up" } })
      drive(flow, { { type = "confirm" } })
    end
    for _ = 1, 15 do
      flow:updateFixed({})
    end
    Assert.equal(mons:partyMon(0).heldItem, "NONE", "taking must clear the held slot")
    Assert.equal(
      bag:quantity("POTION"),
      bagQuantity + 1,
      "the taken potion returns to the bag exactly once"
    )
    Assert.isTrue(mons:partyRevision() == partyRevision + 1, "taking publishes exactly one mon revision")
    Assert.isTrue(bag:revision() == bagRevision + 1, "taking publishes exactly one bag revision")
    local status = flowStatus(flow)
    Assert.equal(status.page, "party_browse", "taking returns to party browse")
    Assert.equal(flowChild(status).cursorNode, 0, "taking refocuses the taken slot")
    Assert.isNil(flow:takeResult(), "taking reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.production_switch_reorders_once_and_restores_browse(context)
  requireVersions(context)
  withGame(function(game)
    giftPair(game)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local partyRevision = mons:partyRevision()
    local party = composition(game).makePartyFlow()
    driveUntil(party, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    drainOpen(party)
    -- A UI-driven switch commits once at the end of its animation and
    -- hands focus to the destination with the browse message restored.
    choosePartySlot(party, 0)
    choosePartyMenu(party, "switch")
    choosePartySlot(party, 1)
    drive(party, { { type = "confirm" } })
    for _ = 1, 40 do
      party:updateFixed({})
    end
    Assert.equal(mons:partyRevision(), partyRevision + 1, "the switch publishes exactly one revision")
    Assert.equal(mons:partyMon(0).species, "TOTODILE", "the switch reorders the live party")
    Assert.equal(mons:partyMon(1).species, "CHIKORITA", "the switch keeps every member")
    local child = flowChild(flowStatus(party))
    Assert.equal(child.state, "browse", "completion returns to browse")
    Assert.equal(child.cursorNode, 1, "focus follows the switch destination")
    Assert.isNil(child.swap, "completion clears the animation")
    Assert.isNil(party:takeResult(), "returning to the root reports no terminal result")
    party:dispose()
  end)
end

return { tests = T.tests, metadata = T.metadata }
