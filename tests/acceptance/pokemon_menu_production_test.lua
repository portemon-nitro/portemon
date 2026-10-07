-- Production-composed menu journeys: Start Menu Pokemon and Bag open
-- the composed flows (never leaves directly), flow behaviors persist
-- through the live services, the field handoff executes once on the live
-- scheduler after the foreground claim, and save/reload preserves domain,
-- badges, travel, and leaf state with busy denial. Stops before GPU
-- rendering like every acceptance path. No planning vocabulary here.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local GameSave = require("libs.hgss.src.save.GameSave")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local GameSave = require("libs.hgss.src.save.GameSave")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local GameSave = require("libs.hgss.src.save.GameSave")
local RomFs = require("romdump.src.source.RomFs")

local T = {
  metadata = { capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "audio-bank:700", "audio-bank:702", "audio-bank:709", "audio-bank:758", "audio-bank:759", "map-data:31", "map-data:33", "map-data:47", "map-data:48", "map-data:60", "map:33", "map:60", "summary:global" }, tags = { "menu", "production" } },
  tests = {},
}

local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG
local FLAG_GOT_STARTER = FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER
local FLAG_GOT_TRAINER_CARD = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD

local function requireVersions(context)
  local versions = { AcceptanceHarness.defaultVersion() }
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("production journeys need a ready ROM cache", 0)
  end
  return versions
end

local function withGame(fn, map)
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local romFs, err = RomFs.open(versionId)
  assert(romFs, tostring(err))
  local facts = NavigationFacts.discover(CacheFs.forVersion(versionId), romFs)
  romFs:close()
  local game = harness:boot({ versionId = versionId, map = map or "MAP_NEW_BARK", save = "fresh" })
  game:waitForFieldEntry()
  -- Headless composition binds the explicit no-image preparation fake:
  -- the party reports ready without realizing GPU icons it never draws.
  game.runtime:bindPartyIconPreparation(function(_)
    return true
  end, function() end)
  -- Headless summary leases resolve instantly with the validated
  -- family: nothing draws (render attempts stay zero), so no portrait
  -- realizes.
  local SummaryCache = require("libs.assets.src.SummaryCache")
  local summaryManifest = SummaryCache.loadManifest(assert(game.runtime.cacheFs, "the runtime owns its cache"))
  game.runtime:bindSummaryPreparation(function()
    local lease = {}
    function lease:prepare(demand)
      return { kind = "ready", key = demand.key, assets = { manifest = summaryManifest } }
    end
    function lease:release()
    end
    return lease
  end)
  OpeningLifecycle.seedNewBarkWestExitScene(game)
  OpeningLifecycle.settleNewBarkFriendScene(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
  local ok, failure = xpcall(function()
    fn(game, facts)
    Assert.equal(game:renderAttempts(), 0, "production journeys must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
end

local function giftMon(game, species, heldItem)
  local mons = assert(game.runtime.monService, "live mon service required")
  Assert.isTrue(
    mons:giveMon({ species = species, level = 5, heldItem = heldItem or "NONE", form = 0, location = 7 }),
    "setup gift must enter the party: " .. species
  )
  return mons:partyCount() - 1
end

local function teachMove(game, slot, itemKey)
  local runtime = game.runtime
  local mons = assert(runtime.monService, "live mon service required")
  local bag = assert(runtime.bagService, "live bag service required")
  Assert.isTrue(bag:add(itemKey, 1), "setup must stock " .. itemKey)
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local outcome = actions:commit({
    kind = "teach_move",
    slot = slot,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = itemKey,
  })
  Assert.equal(outcome.kind, "changed", itemKey .. " must teach, got " .. tostring(outcome.kind))
end

local function awardBadge(game, key)
  local profile = assert(game.runtime.playerData and game.runtime.playerData.profile, "live profile required")
  PlayerProgression.new(profile):awardBadge(key)
  Assert.isTrue(PlayerProgression.new(profile):hasBadge(key), "badge award must persist on the live profile")
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

local function applicationStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.application, "a destination must own the tick")
  return assert(status.application, "the application phase must expose the child status")
end

local function childView(flow)
  local status = flow:status()
  Assert.isTrue(status.open, "the party flow stays open")
  return assert(status.child, "the party flow holds a live child")
end

local function settleTransition(flow)
  -- Summary-involved exits publish one extra full-black frame past the
  -- six-update shutter cadence; the loop still breaks early for shorter
  -- sibling transitions.
  for _ = 1, 10 do
    if flow:status().transition == nil then
      break
    end
    flow:updateFixed({})
  end
  if not flow:status().open then
    -- The host consumes a terminal result after presenting the opaque frame.
    flow:updateFixed({})
  end
end

-- A fresh party page clears its open before input: wait for the leaf
-- to turn interactive, then run out the handover ticks that still drop
-- input so the first navigation acts.
local function drainOpen(flow)
  for _ = 1, 30 do
    local status = flow:status()
    local child = status.child
    if child ~= nil and child.phase == "interactive" then
      break
    end
    flow:updateFixed({})
  end
  flow:updateFixed({})
  flow:updateFixed({})
end

local function focusSlot(flow, slot, direction)
  -- Party slots run left to right; down from a slot reaches cancel.
  -- A fresh screen reports no cursor while icon preparation pends:
  -- wait for the visible cursor before navigating.
  for _ = 1, 30 do
    if childView(flow).cursorNode ~= nil then
      break
    end
    flow:updateFixed({})
  end
  for _ = 1, 12 do
    local child = childView(flow)
    if child.cursorNode == slot then
      return
    end
    flow:updateFixed({ { type = "navigate", direction = direction or "right" } })
  end
  error("slot focus never settled on " .. tostring(slot), 0)
end

-- Seeks the action-menu row satisfying match and confirms it; the focused
-- row is read live so confirmation lands on the intended entry.
local function activateMenuRow(flow, match, what)
  flow:updateFixed({ { type = "confirm" } })
  -- Source menus place later entries laterally: a down-only walk cycles
  -- the first column forever, so explored rows rotate an escape direction
  -- whenever focus revisits a row.
  local seen = {}
  local escapes = { "right", "left", "up" }
  local escapeNext = 1
  for _ = 1, 40 do
    local child = childView(flow)
    local menu = assert(child.menu, "slot confirm must open the action menu")
    local index = assert(child.menuIndex, "the open menu carries focus")
    local current = menu[index]
    if current ~= nil and match(current) then
      flow:updateFixed({ { type = "confirm" } })
      -- Menu activation rides the visual press cadence before its single
      -- dispatch: settle the gate so callers read the dispatched state.
      -- A terminal handoff closes the flow instead of settling a child.
      for _ = 1, 10 do
        local status = flow:status()
        if not status.open then
          settleTransition(flow)
          return
        end
        local settled = assert(status.child, "the party flow holds a live child")
        if settled.menuPress == nil then
          settleTransition(flow)
          return
        end
        flow:updateFixed({})
      end
      error("the gated menu entry never dispatched " .. what, 0)
    end
    local direction = "down"
    if seen[index] then
      direction = escapes[escapeNext]
      escapeNext = escapeNext % #escapes + 1
    end
    seen[index] = true
    flow:updateFixed({ { type = "navigate", direction = direction } })
  end
  error("the action menu never offered " .. what, 0)
end

function T.tests.production_pokemon_destination_opens_the_native_flow(context)
  requireVersions(context)
  withGame(function(game)
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_STARTER })
    giftMon(game, "CHIKORITA")
    giftMon(game, "TOTODILE")
    openStartMenu(game)
    navigateTo(game, state, "vanilla.pokemon")
    confirm(game)
    game:advanceUntil("the pokemon destination owns the tick", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)
    game:advanceUntil("the party reveal completes before the close", function()
      local hostStatus = game.runtime.applicationHost:status()
      if hostStatus.phase ~= FieldApplicationHost.PHASES.application then
        return false
      end
      local flow = hostStatus.application
      local leaf = flow ~= nil and flow.child or nil
      return leaf ~= nil and leaf.phase == "interactive"
    end, 120)
    -- The handover and its settling tick still drop input; the close
    -- presses only once the screen forwards.
    game:step()
    game:step()
    local child = applicationStatus(game)
    Assert.equal(child.page, "party_browse", "the pokemon destination opens the native party flow")
    Assert.equal(child.root, "party", "the pokemon destination roots the flow at party")
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

function T.tests.production_bag_destination_opens_the_native_flow(context)
  requireVersions(context)
  withGame(function(game)
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_BAG })
    openStartMenu(game)
    navigateTo(game, state, "vanilla.bag")
    confirm(game)
    game:advanceUntil("the bag destination owns the tick", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)
    local child = applicationStatus(game)
    Assert.equal(child.page, "bag_browse", "the bag destination opens the native bag flow")
    Assert.equal(child.root, "bag", "the bag destination roots the flow at bag")

    -- Opening batches are consumed while the Bag performs its source
    -- sub-then-main reveal. The first cancel must not close the new app.
    cancel(game)
    game:advanceUntil("the Bag resolves its opening batch", function()
      if hostPhase(game) ~= FieldApplicationHost.PHASES.application then
        return true
      end
      local flow = game.runtime.applicationHost:status().application
      local leaf = flow ~= nil and flow.child or nil
      return leaf ~= nil and leaf.phase == "interactive"
    end, 120)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.application, "opening cancel input is discarded")
    child = applicationStatus(game)
    Assert.equal(child.page, "bag_browse", "the Bag stays active after opening input is discarded")
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

function T.tests.production_bag_return_reveals_the_retained_menu(context)
  requireVersions(context)
  withGame(function(game)
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_BAG })
    openStartMenu(game)
    navigateTo(game, state, "vanilla.bag")
    confirm(game)
    game:advanceUntil("the bag destination owns the tick", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)

    -- Let Bag's source opening finish before testing the root close.
    game:advanceUntil("the Bag is ready for root close", function()
      if hostPhase(game) ~= FieldApplicationHost.PHASES.application then
        return false
      end
      local flow = game.runtime.applicationHost:status().application
      local leaf = flow ~= nil and flow.child or nil
      return leaf ~= nil and (leaf.phase == nil or leaf.phase == "interactive")
    end, 120)
    game:step()
    game:step()
    cancel(game)

    -- Six app-exit steps finish the outgoing Bag. The next tick starts
    -- brightness-in over the retained menu, before close is published.
    for _ = 1, 7 do
      game:step()
    end
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "the Bag flow stays published while the retained Start Menu is revealed"
    )
    game:advanceUntil("the completed reveal returns to the retained menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    cancel(game)
    game:advanceUntil("cancelling the menu returns to the field", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.closed
    end, 120)
  end)
end

function T.tests.flow_behaviors_persist_through_production_composition(context)
  requireVersions(context)
  withGame(function(game)
    local runtime = game.runtime
    giftMon(game, "CHIKORITA")
    local aron = giftMon(game, "TOTODILE")
    local composition = assert(runtime.pokemonMenu, "the production runtime owns the menu composition")
    local flow = composition.makePartyFlow()
    Assert.isTrue(flow:status().open, "the composed party flow opens")
    drainOpen(flow)
    -- Summary returns to the displayed member.
    focusSlot(flow, aron)
    activateMenuRow(flow, function(row)
      return row.kind == "summary"
    end, "summary")
    Assert.equal(flow:status().page, "summary", "summary opens for the focused member")
    flow:updateFixed({ { type = "cancel" } })
    local returned = nil
    for _ = 1, 30 do
      returned = childView(flow).cursorNode
      if returned ~= nil then
        break
      end
      flow:updateFixed({})
    end
    Assert.equal(returned, aron, "summary returns to the displayed member")
    -- The summary return reopens the party page on a fresh leaf, so its
    -- open clears again before the switch leg drives.
    drainOpen(flow)
    -- Switch persists through the live service after its animation.
    local mons = assert(runtime.monService, "live mon service required")
    local before = mons:partyRevision()
    focusSlot(flow, aron)
    activateMenuRow(flow, function(row)
      return row.kind == "switch"
    end, "switch")
    focusSlot(flow, 0, "left")
    flow:updateFixed({ { type = "confirm" } })
    for _ = 1, 40 do
      flow:updateFixed({})
    end
    Assert.isTrue(mons:partyRevision() > before, "the switch publishes once")
    Assert.equal(mons:partyMon(0).species, "TOTODILE", "the switch reorders the live party")
    flow:dispose()
  end)
end

function T.tests.unrelated_destinations_keep_their_routes(context)
  requireVersions(context)
  withGame(function(game)
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_TRAINER_CARD })
    openStartMenu(game)
    navigateTo(game, state, "vanilla.trainer_card")
    confirm(game)
    game:advanceUntil("the trainer card owns the tick", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)
    cancel(game)
    game:advanceUntil("cancelling the card returns to the menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    cancel(game)
    game:advanceUntil("cancelling the menu returns to the field", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.closed
    end, 120)
  end)
end

function T.tests.field_handoff_executes_once_on_the_live_scheduler(context)
  requireVersions(context)
  withGame(function(game, facts)
    awardBadge(game, "fog")
    local swimmer = giftMon(game, "TOTODILE")
    teachMove(game, swimmer, "HM03")
    game:moveTo({ fieldX = facts.water.approach.fieldX, fieldZ = facts.water.approach.fieldZ })
    game:face(facts.water.direction)
    local runtime = game.runtime
    local composition = assert(runtime.pokemonMenu, "the production runtime owns the menu composition")
    local flow = composition.makePartyFlow()
    drainOpen(flow)
    focusSlot(flow, swimmer)
    activateMenuRow(flow, function(row)
      return row.move == "SURF"
    end, "SURF")
    local terminal = flow:takeResult()
    Assert.isTrue(
      type(terminal) == "table" and terminal.kind == "field_action",
      "an executable surf emits the typed terminal handoff"
    )
    Assert.equal(terminal.actionId, "pokemon.field_move", "the handoff carries the field action identity")
    runtime:_admitFieldAction(terminal.actionId, terminal.request)
    Assert.isTrue(
      runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil,
      "admission establishes the foreground claim before UI release"
    )
    -- A stray confirm after admission opens no menu: the batch was consumed.
    confirm(game)
    game:step()
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.closed, "stray input after admission opens nothing")
    local settled = game:advanceUntil("surf entry settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 1200)
    Assert.equal(settled.player.fieldX, facts.water.fieldX, "surf entry commits the water tile exactly once")
    Assert.equal(settled.player.fieldZ, facts.water.fieldZ, "surf entry commits the water tile exactly once")
    game:advanceUntil("the completed task releases the foreground claim", function()
      return runtime.scripts.scheduler:foregroundEnvironmentId() == nil
    end, 120)
    local ashore = game:snapshot()
    Assert.equal(ashore.player.fieldX, facts.water.fieldX, "completion holds the committed tile")
    flow:dispose()
  end)
end

function T.tests.save_round_trip_preserves_domain_badges_travel_and_leaves(context)
  requireVersions(context)
  withGame(function(game)
    local runtime = game.runtime
    local mons = assert(runtime.monService, "live mon service required")
    giftMon(game, "CHIKORITA")
    local rocky = giftMon(game, "GEODUDE")
    teachMove(game, rocky, "TM28")
    awardBadge(game, "zephyr")
    awardBadge(game, "fog")
    mons:swapPartyMons(0, rocky)
    local monRevision = mons:partyRevision()
    local bag = assert(runtime.bagService, "live bag service required")
    Assert.isTrue(bag:add("POTION", 3), "setup must stock potions")
    local potionBefore = bag:quantity("POTION")
    local record = assert(runtime:captureGameSave(), "a settled field captures")
    Assert.equal(record.schema, GameSave.SCHEMA, "production capture writes the current save schema")

    Assert.equal(type(record.mart), "table", "production capture carries the canonical mart bucket")
    Assert.equal(record.mart.schema, "g4-mart-save-v1", "production capture uses the supported mart schema")
    Assert.equal(record.playerData.profile.nationalDex, false, "new-game profiles start without the National Dex")
    Assert.isNil(record.battleFrontier, "the current save schema carries no Frontier bucket")

    Assert.isTrue(record.playerData.profile.badges > 0, "awarded badges persist in the record")
    Assert.isTrue(type(record.fieldTravel) == "table", "the record carries travel facts")
    Assert.equal(record.fieldTravel.lastHealSpawn, "SPAWN_NEW_BARK", "the mother spawn survives capture")
    Assert.equal(mons:partyRevision(), monRevision, "capture publishes no mon state")
    -- Reload through the production capture boundary and prove persistence.
    -- Revisions are runtime counters, not durable facts: persistence
    -- means the same ordered content, badges, and travel records.
    local function partyContent(service)
      local entries = {}
      for slot = 0, service:partyCount() - 1 do
        local mon = service:partyMon(slot)
        entries[#entries + 1] = mon.species .. ":" .. tostring(mon.heldItem)
      end
      return entries
    end
    local orderBefore = partyContent(mons)
    game:restart()
    local fresh = game.runtime
    Assert.deepEqual(partyContent(fresh.monService), orderBefore, "reload preserves the ordered party content")
    Assert.equal(fresh.bagService:quantity("POTION"), potionBefore, "reload preserves inventory quantities")
    Assert.equal(
      fresh.playerData.profile.badges,
      record.playerData.profile.badges,
      "reload preserves the awarded badges"
    )
    Assert.equal(fresh.fieldTravel:capture().lastHealSpawn, "SPAWN_NEW_BARK", "reload preserves the travel facts")
    Assert.equal(fresh.monService:partyMon(0).species, "GEODUDE", "reload preserves the switched order")
    Assert.deepEqual(fresh.martService:capture(), record.mart, "reload preserves the canonical mart state")
  end)
end

function T.tests.busy_save_is_denied_then_recovers_without_data_loss(context)
  requireVersions(context)
  withGame(function(game, facts)
    awardBadge(game, "fog")
    game:moveTo({ fieldX = facts.water.approach.fieldX, fieldZ = facts.water.approach.fieldZ })
    game:face(facts.water.direction)
    local runtime = game.runtime
    local composition = assert(runtime.pokemonMenu, "the production runtime owns the menu composition")
    local avatar = assert(runtime.playerAvatar, "live avatar required")
    local lived = avatar:status()
    local contextRecord = {
      badges = 0xFFFF,
      mapSymbol = runtime.runtimeMap.mapSymbol,
      mapId = runtime.runtimeMap.mapId,
      fieldUse = runtime.runtimeMap.fieldData.fieldUse,
      avatarMode = lived.durableState,
      humanFollower = false,
      followingMon = false,
      rocketCostume = false,
      safari = false,
      palPark = false,
      surfEdge = true,
      facingWaterfall = false,
      facingWhirlpool = false,
      climbTile = false,
      headbuttTree = false,
      foggy = false,
      chatterOpen = false,
    }
    local queued = composition.fieldMoves:queue({ move = "surf", slot = 0, context = contextRecord })
    Assert.equal(queued.kind, "accepted", "setup must queue at a valid shore, got " .. tostring(queued.kind))
    local denied, reason = runtime:captureGameSave()
    Assert.isNil(denied, "a pending field operation denies capture")
    Assert.isTrue(type(reason) == "string" and reason ~= "", "the denial explains itself")
    composition.fieldMoves:discardPending()
    local record = assert(runtime:captureGameSave(), "capture recovers after the queue clears")
    Assert.equal(record.schema, GameSave.SCHEMA, "recovered capture writes the current schema")
  end)
end

return { tests = T.tests, metadata = T.metadata }
