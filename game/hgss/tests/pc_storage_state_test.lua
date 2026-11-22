-- Storage child opens in each retail mode across the supported measured
-- topologies and returns cleanly without taking custody from the domain.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FakeGraphics = require("tests.support.FakeGraphics")
local Mon = require("libs.mons.src.Mon")
local PngWriter = require("tests.support.PngEncoder")
local PcStorageRenderer = require("libs.hgss.src.ui.PcStorageRenderer")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PcStorageState = require("game.hgss.src.pc.StorageScreenState")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PcStorageGeometry = require("libs.hgss.src.ui.PcStorageGeometry")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function monService(configuredCount)
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(
      Party.new():capture(),
      Lcrng.new(0x12345678):capture(),
      nil,
      configuredCount and { configuredCount = configuredCount } or nil
    ),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x87654321, catalog)
  Assert.isTrue(service:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  return service
end

local function hostPointForRect(state, rect)
  local plan = state._session:plan()
  local x, y
  for _, pane in ipairs(plan.panes) do
    local placement = pane.placement
    if
      pane.interactive
      and placement ~= nil
      and rect.x + rect.width <= placement.logicalWidth
      and rect.y + rect.height <= placement.logicalHeight
    then
      x, y = LayoutGeometry.logicalToHost(placement, rect.x + rect.width / 2, rect.y + rect.height / 2)
      break
    end
  end
  assert(x ~= nil and y ~= nil, "Storage hit target has a placed pane")
  return x, y
end

local function rawPointerAt(state, rect, pointerId)
  local x, y = hostPointForRect(state, rect)
  state:updateFixed({
    { type = "pointer_down", pointerId = pointerId, x = x, y = y },
    { type = "pointer_up", pointerId = pointerId, x = x, y = y },
  })
end

local function setActiveBox(mons, box)
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { activeBox = box }))
  change.publish()
end

-- `coverage` picks the alternative holder's release-check set: "both" covers
-- Surf and Fly (so the selected mon may leave), "surf" leaves Fly uncovered
-- (so the mon comes back).
local function releaseService(coverage)
  local root = CatalogFixture.buildAssetRoot()
  for _, entry in ipairs({ { "SURF", 57 }, { "FLY", 19 } }) do
    local move = {}
    for key, value in pairs(root.moves.TACKLE) do
      move[key] = value
    end
    move.nativeId = entry[2]
    move.name = entry[1]
    root.moves[entry[1]] = move
  end
  Assert.isTrue(MonAssetSchema.assertCatalog(root))
  local catalog = MonCatalog.new(root, CatalogFixture.makeItemCatalog())
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x10203040):capture(), nil, { configuredCount = 37 }),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x23456789, catalog)
  for _ = 1, 2 do
    Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  end
  mons:setMove(0, 0, "SURF")
  mons:setMove(0, 1, "FLY")
  local alternative = mons:partyMon(1)
  alternative.moves[1] = { move = "SURF", pp = catalog:move("SURF").basePp, ppUps = 0 }
  if coverage ~= "surf" then
    alternative.moves[2] = { move = "FLY", pp = catalog:move("FLY").basePp, ppUps = 0 }
  end
  local boxed = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 36, slot = 29, mon = alternative } } }))
  boxed.publish()
  return mons
end

local function setPartyHeldItem(mons, item)
  local mon = mons:partyMon(0)
  mon.heldItem = item
  local change = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = mon } }))
  change.publish()
end

local function heldItemPicker(item)
  return function()
    local pending = true
    return {
      updateFixed = function() end,
      takeIntent = function()
        if pending then
          pending = false
          return { kind = "pick", item = item }
        end
      end,
      takeResult = function()
        return nil
      end,
      status = function()
        return {}
      end,
      dispose = function() end,
    }
  end
end

-- The source release prompt opens on NO; the player moves the highlight to
-- YES and confirms it to start the release scan.
local function confirmReleaseYes(state)
  state:updateFixed({ { type = "navigate", direction = "up" } })
  state:updateFixed({ { type = "confirm" } })
end

-- Acknowledges the release's two message lines (released/bye-bye, or
-- came-back/worried) with the input the source waits for. The first input
-- only advances the pair; the second (for a removal) finally deletes the mon.
local function acknowledgeReleaseMessages(state)
  local check = state:status().releaseCheck
  while
    check ~= nil
    and (check.outcome == "released" or (check.outcome == "returned" and not check.acknowledged))
  do
    state:updateFixed({ { type = "navigate", direction = "up" } })
    check = state:status().releaseCheck
  end
  return check
end

-- Confirms the armed release and ticks the concurrent shrink/scan to its
-- terminal phase, without acknowledging the messages that follow.
local function settleReleaseScan(state)
  confirmReleaseYes(state)
  local check = state:status().releaseCheck
  local ticks = 1
  local scanTicks = math.ceil(check.total / 15)
  local limit = scanTicks + PcStorageGeometry.RELEASE_GROW_TICKS
  while check.outcome == "pending" do
    Assert.isTrue(ticks <= limit, "the concurrent shrink/scan finishes within its budget")
    state:updateFixed({})
    ticks = ticks + 1
    check = state:status().releaseCheck
  end
  Assert.equal(check.scanned, check.total, "the fixed-tick scan covers every candidate address")
  if check.outcome == "returned" then
    Assert.equal(ticks, scanTicks + PcStorageGeometry.RELEASE_GROW_TICKS, "a came-back mon grows back after the scan")
  else
    Assert.equal(ticks, scanTicks, "the source scan visits fifteen addresses on each fixed tick")
  end
  return check, ticks, scanTicks
end

local function finishReleaseScan(state)
  state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  Assert.equal(state:status().releaseCheck.outcome, "confirm")
  local check = settleReleaseScan(state)
  return acknowledgeReleaseMessages(state) or check
end

local function measurement(configuration)
  if configuration == "dualDisplay" then
    return {
      width = 512,
      height = 384,
      topology = ScreenTopology.dualDisplay(
        { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, role = "world", touch = false },
        { id = "sub", rect = { x = 256, y = 0, width = 256, height = 192 }, role = "auxiliary", touch = true }
      ),
      pixelRatio = 1,
      signature = "pc-storage-test:dual",
    }
  end
  local dimensions = {
    nativeLike = { width = 256, height = 192 },
    wide = { width = 512, height = 192 },
    tall = { width = 384, height = 512 },
  }
  local size = dimensions[configuration]
  return {
    width = size.width,
    height = size.height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = size.width, height = size.height },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "pc-storage-test:" .. configuration,
  }
end

local function openOptions(mons, mode, configuration)
  return {
    mode = mode,
    mons = mons,
    bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() }),
    manifest = PcPresentationFixture.manifest(),
    measureDisplay = function()
      return measurement(configuration)
    end,
    audio = { play = function() end },
    dexNumber = function() end,
    charmap = CatalogFixture.CHARMAP,
    icons = {},
    portraits = {},
    childFactories = {},
  }
end

function T.each_mode_closes_without_moving_or_erasing_domain_custody()
  for mode = 0, 3 do
    for _, configuration in ipairs({ "dualDisplay", "nativeLike", "wide", "tall" }) do
      local mons = monService()
      local beforeParty = mons:partyMon(0)
      local beforePartyRevision = mons:partyRevision()
      local beforeBoxRevision = mons:boxRevision()
      local state = PcStorageState.new(openOptions(mons, mode, configuration))
      local status = state:status()
      Assert.equal(status.mode, mode, "mode remains a retail mode across layouts")
      Assert.equal(status.activeBox, 0)
      Assert.isNil(status.carry, "opening never removes a mon from domain custody")
      Assert.isTrue(state:isActive())
      state:cancel("test-close")
      local result = state:result()
      Assert.equal(result.kind, "closed")
      Assert.isNil(state:result(), "close result is consumed once")
      Assert.isFalse(state:isActive())
      Assert.deepEqual(mons:partyMon(0), beforeParty)
      Assert.equal(mons:partyRevision(), beforePartyRevision)
      Assert.equal(mons:boxRevision(), beforeBoxRevision)
      state:dispose()
    end
  end
end

function T.deposit_and_withdraw_run_through_the_mode_menus()
  local mons = monService()
  local extra = CatalogFixture.makeFactory(0x11223344, mons:catalog())
  Assert.isTrue(mons:addMon(extra:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local deposit = PcStorageState.new(openOptions(mons, 0, "wide"))
  deposit:updateFixed({ { type = "confirm" } })
  Assert.equal(deposit:status().phase, "menu")
  Assert.equal(deposit:status().menu.actions[1], "deposit")
  deposit:updateFixed({ { type = "confirm" } })
  Assert.notNil(deposit:status().carry, "deposit keeps source custody while choosing the destination")
  deposit:updateFixed({ { type = "confirm" } })
  Assert.isNil(deposit:status().carry)
  Assert.equal(mons:partyCount(), 1)
  Assert.notNil(mons:boxMon(0, 0), "deposit publishes into the focused box slot")
  deposit:dispose()

  local withdraw = PcStorageState.new(openOptions(mons, 1, "wide"))
  withdraw:updateFixed({ { type = "storage_target", target = { kind = "box", slot = 0 } } })
  withdraw:updateFixed({ { type = "confirm" } })
  Assert.equal(withdraw:status().menu.actions[1], "withdraw")
  withdraw:updateFixed({ { type = "confirm" } })
  Assert.notNil(withdraw:status().carry)
  Assert.equal(withdraw:_view().tray, "right", "Withdraw slides the party panel in on the right")
  withdraw:updateFixed({ { type = "confirm" } })
  Assert.equal(withdraw:_view().tray, "closed", "the party panel closes once the mon lands")
  Assert.isNil(mons:boxMon(0, 0))
  Assert.equal(mons:partyCount(), 2)
  withdraw:dispose()
end

function T.retail_lists_follow_each_mode_and_context()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x55667788, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local boxed = mons:partyMon(1)
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 4, mon = boxed } } }))
  stored.publish()
  local function boxTap(slot)
    return { type = "storage_target", target = { kind = "box", box = 0, slot = slot } }
  end

  -- Deposit mode hit-tests only the party tray until a deposit asks where.
  local deposit = PcStorageState.new(openOptions(mons, 0, "wide"))
  Assert.equal(#deposit._session:plan().content.hitRegions.boxSlots, 0, "deposit mode has no box touch targets")
  deposit:updateFixed({ boxTap(4) })
  Assert.deepEqual(deposit:status().focus, { domain = "party", slot = 0 }, "a box tap in deposit mode is ignored")
  deposit:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(deposit:status().menu.actions, { "deposit", "summary", "markings", "release" })
  deposit:updateFixed({ { type = "confirm" } })
  Assert.equal(#deposit._session:plan().content.hitRegions.boxSlots, 0, "the deposit selector replaces the box grid")
  Assert.equal(assert(deposit:_view().boxTray).mode, "deposit", "a deposit opens the source box selector")
  deposit:dispose()

  -- Withdraw mode lists a box mon, and leaves empty slots without a list.
  local withdraw = PcStorageState.new(openOptions(mons, 1, "wide"))
  withdraw:updateFixed({ boxTap(4), { type = "confirm" } })
  Assert.deepEqual(withdraw:status().menu.actions, { "withdraw", "summary", "markings", "release" })
  withdraw:updateFixed({ { type = "cancel" }, boxTap(9), { type = "confirm" } })
  Assert.equal(withdraw:status().phase, "browse", "an empty box slot opens no list")
  withdraw:dispose()

  -- Move mode selects the mon and lists its actions; the MOVE row is what puts
  -- it on the hand and slides the box tray open (PCBox_SelectMoveModeBoxMon
  -- only selects).
  local move = PcStorageState.new(openOptions(mons, 2, "wide"))
  move:updateFixed({ boxTap(4), { type = "confirm" } })
  Assert.equal(move:status().phase, "menu", "selecting a mon opens its list without picking it up")
  Assert.deepEqual(move:status().menu.actions, { "move", "summary", "heldItems", "markings", "release" })
  Assert.equal(move:status().menu.selected, 1, "MOVE is the highlighted entry")
  move:updateFixed({ { type = "action", action = "markings" } })
  Assert.equal(move:status().phase, "editor", "another entry runs from the list")
  Assert.isNil(move:status().carry)
  move:dispose()

  -- The MOVE row picks the mon up and opens the box tray with it on the hand.
  local holdMove = PcStorageState.new(openOptions(mons, 2, "wide"))
  holdMove:updateFixed({ boxTap(4), { type = "confirm" }, { type = "confirm" } })
  Assert.equal(holdMove:status().phase, "carry", "the MOVE row puts the mon on the hand")
  Assert.equal(assert(holdMove:_view().boxTray).mode, "box", "the MOVE row slides the box tray open")
  Assert.equal(holdMove._grid:layoutName(), "tray", "the held mon moves through the tray layout")
  holdMove:dispose()

  -- Item mode lists one BAG/GIVE row and lifts a held item for a pointer swap.
  local held = mons:partyMon(0)
  held.heldItem = "POTION"
  assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = held } })).publish()
  local items = PcStorageState.new(openOptions(mons, 3, "wide"))
  items:updateFixed({ { type = "party" } })
  items:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 0 } } })
  items:updateFixed({ { type = "confirm" } })
  Assert.equal(items:status().phase, "carry", "a tapped held item rides the hand")
  Assert.deepEqual(items:status().menu.actions, { "bagItem" }, "the item list carries the BAG row")
  items:dispose()

  -- An item-less mon offers GIVE instead.
  local give = PcStorageState.new(openOptions(mons, 3, "wide"))
  give:updateFixed({ { type = "party" } })
  give:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 1 } } })
  give:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(give:status().menu.actions, { "giveItem" }, "an empty hand offers GIVE")
  Assert.isNil(give:status().carry, "GIVE does not lift an item")
  give:dispose()

  -- HELD ITEMS is one entry that branches on the held item: take it back here,
  -- or open the Bag to give one when the mon holds nothing.
  local holdOptions = openOptions(mons, 2, "wide")
  local pickerOpened = 0
  local pickPending = true
  holdOptions.childFactories = {
    heldItemPicker = function()
      pickerOpened = pickerOpened + 1
      return {
        updateFixed = function() end,
        takeIntent = function()
          if pickPending then
            pickPending = false
            return { kind = "pick", item = "POTION" }
          end
        end,
        status = function()
          return {}
        end,
        dispose = function() end,
      }
    end,
  }
  local hold = PcStorageState.new(holdOptions)
  hold:updateFixed({ { type = "party" } })
  hold:updateFixed({ { type = "action", action = "heldItems" } })
  Assert.equal(hold:_view().message.id, 23, "taking asks the source confirmation")
  hold:updateFixed({ { type = "confirm" } })
  Assert.equal(mons:partyMon(0).heldItem, "NONE", "a held item is taken back to the Bag")
  Assert.equal(holdOptions.bag:quantity("POTION"), 1)
  hold:updateFixed({ { type = "action", action = "heldItems" } })
  Assert.equal(pickerOpened, 1, "an empty hand opens the Bag picker to give an item")
  Assert.equal(hold:status().childKind, "heldItemPicker")
  hold:updateFixed({})
  Assert.equal(mons:partyMon(0).heldItem, "POTION", "the picker's item lands on the mon")
  local given = hold:_view().message
  Assert.notNil(given, "giving an item prints its result line")
  Assert.equal(given.id, 16, "giving prints ... is now being held.")
  Assert.equal(given.subject, "Potion", "the line names the given item")
  hold:dispose()

  -- The title plate opens the Wallpaper / Name pair.
  local title = PcStorageState.new(openOptions(mons, 1, "wide"))
  local plan = title._session:plan()
  local event = plan.mapInput({ type = "pointer_down", x = 84, y = 28 }, title:_view(), plan)
  Assert.deepEqual(event, { type = "box_title" })
  title:updateFixed({ event })
  Assert.deepEqual(title:status().menu.actions, { "wallpaper", "boxName" })
  title:dispose()
end

function T.exit_prompts_leave_only_on_the_retail_answers()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  local plan = state._session:plan()
  local function tap(x, y)
    return plan.mapInput({ type = "pointer_down", x = x, y = y }, state:_view(), plan)
  end
  -- RETURN asks "Exit the Box?"; Yes leaves, No stays.
  local event = tap(224, 180)
  Assert.deepEqual(event, { type = "return" }, "the RETURN button raises its own event")
  state:updateFixed({ event })
  Assert.equal(state:_view().message.id, 11, "RETURN asks to exit")
  Assert.isTrue(state:_view().message.yesNo)
  state:updateFixed({ { type = "cancel" } })
  Assert.isTrue(state:isActive(), "No keeps the Box open")
  Assert.equal(state:_view().message.id, 18, "the browse prompt returns")
  state:updateFixed({ { type = "return" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.isFalse(state:isActive(), "Yes leaves")
  state:dispose()

  -- B asks "Continue Box operations?"; Yes continues, No leaves.
  local back = PcStorageState.new(openOptions(mons, 1, "wide"))
  back:updateFixed({ { type = "cancel" } })
  Assert.equal(back:_view().message.id, 12, "B asks whether to continue")
  back:updateFixed({ { type = "confirm" } })
  Assert.isTrue(back:isActive(), "Yes continues")
  back:updateFixed({ { type = "cancel" } })
  back:updateFixed({ { type = "cancel" } })
  Assert.isFalse(back:isActive(), "No leaves")
  back:dispose()
end

function T.party_tray_follows_each_mode()
  local mons = monService()
  local deposit = PcStorageState.new(openOptions(mons, 0, "wide"))
  Assert.equal(deposit:_view().tray, "left", "Deposit starts with the tray open at the left")
  deposit:updateFixed({ { type = "party" } })
  Assert.equal(deposit:_view().tray, "left", "Deposit has no PARTY button")
  deposit:dispose()

  local withdraw = PcStorageState.new(openOptions(mons, 1, "wide"))
  Assert.equal(withdraw:_view().tray, "closed", "Withdraw never shows the tray")
  withdraw:updateFixed({ { type = "party" } })
  Assert.equal(withdraw:_view().tray, "closed")
  withdraw:dispose()

  local move = PcStorageState.new(openOptions(mons, 2, "wide"))
  Assert.equal(move:_view().tray, "closed", "Move starts with the tray closed")
  local plan = move._session:plan()
  Assert.equal(#plan.content.hitRegions.partySlots, 0, "a closed tray has no party touch targets")
  move:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 0 } } })
  Assert.equal(move:status().focus.domain, "box", "the default box focus is untouched by an ignored tap")
  move:updateFixed({ { type = "party" } })
  Assert.equal(move:_view().tray, "left", "the PARTY button opens the tray at the left")
  Assert.equal(#move._session:plan().content.hitRegions.partySlots, 6)
  move:updateFixed({ { type = "tray_close" } })
  Assert.equal(move:_view().tray, "closed", "EXIT closes the tray")
  move:updateFixed({ { type = "party" }, { type = "cancel" } })
  Assert.equal(move:_view().tray, "closed", "B closes the tray before asking to leave")
  Assert.isNil(move._prompt)
  move:dispose()
end

function T.messages_follow_the_screen_state_and_refusals()
  local mons = monService()
  local boxed = mons:partyMon(0)
  assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 2, mon = boxed } } })).publish()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  Assert.equal(state:_view().message.id, 18, "Withdraw browses with its prompt")
  state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 2 } }, { type = "confirm" } })
  local selected = state:_view().message
  Assert.equal(selected.id, 0, 'a tapped mon reads "is selected"')
  Assert.equal(selected.subject, Mon.displayName(boxed, mons:catalog()))
  Assert.equal(selected.window, "W39")
  state:dispose()

  -- Depositing the last usable mon is refused, with that mon's message.
  -- The TryDeposit custody checks run when DEPOSIT is chosen, before any
  -- target-box selector opens.
  local deposit = PcStorageState.new(openOptions(mons, 0, "wide"))
  deposit:updateFixed({ { type = "confirm" } })
  deposit:updateFixed({ { type = "confirm" } })
  Assert.equal(deposit:_view().message.id, 6, "the last Pokémon cannot be deposited")
  Assert.equal(deposit:_view().message.window, "W37")
  deposit:updateFixed({ { type = "navigate", direction = "up" } })
  local after = deposit:_view().message
  Assert.isTrue(after == nil or after.id ~= 6, "the message ends with the next input")
  deposit:dispose()
end

function T.move_swap_cancel_and_held_item_routes_keep_domain_owners_authoritative()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x22113344, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local selected = mons:partyMon(0)
  local boxed = mons:partyMon(1)
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 4, mon = boxed } } }))
  stored.publish()

  local move = PcStorageState.new(openOptions(mons, 2, "wide"))
  move:updateFixed({ { type = "party" } })
  Assert.equal(move:status().focus.domain, "party", "the PARTY button opens the tray on the party")
  move:updateFixed({ { type = "action", action = "move" } })
  Assert.equal(move:status().phase, "carry")
  move:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 4 } }, { type = "confirm" } })
  Assert.equal(
    mons:partyMon(0).personality,
    boxed.personality,
    "swap sends the selected box mon into the exact Party slot"
  )
  Assert.equal(mons:boxMon(0, 4).personality, selected.personality)
  local secondParty = mons:partyMon(1)
  move:updateFixed({
    { type = "storage_target", target = { kind = "box", box = 0, slot = 4 } },
    { type = "action", action = "move" },
  })
  move:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 1 } }, { type = "confirm" } })
  Assert.equal(mons:partyMon(1).personality, selected.personality, "box to Party swap replaces the exact Party address")
  Assert.equal(mons:boxMon(0, 4).personality, secondParty.personality, "box to Party swap returns the displaced mon")
  local beforeParty, beforeBox = mons:partyMon(1), mons:boxMon(0, 4)
  move:updateFixed({
    { type = "storage_target", target = { kind = "party", slot = 1 } },
    { type = "action", action = "move" },
  })
  move:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(mons:partyMon(1), beforeParty, "cancel returns the carry to Party custody")
  Assert.deepEqual(mons:boxMon(0, 4), beforeBox, "cancel preserves the selected box record")
  move:dispose()

  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POTION", 1))
  local pickerSelected = true
  local options = openOptions(mons, 3, "wide")
  options.bag = bag
  options.childFactories.heldItemPicker = function()
    return {
      updateFixed = function() end,
      takeIntent = function()
        if pickerSelected then
          pickerSelected = false
          return { kind = "pick", item = "POTION" }
        end
      end,
      takeResult = function()
        return nil
      end,
      status = function()
        return {}
      end,
      dispose = function() end,
    }
  end
  local items = PcStorageState.new(options)
  items:updateFixed({ { type = "party" } })
  items:updateFixed({ { type = "action", action = "giveItem" } })
  Assert.equal(items:status().childKind, "heldItemPicker", "Give Item opens a child picker")
  Assert.equal(mons:partyMon(0).heldItem, "NONE", "opening the picker leaves the Pokemon unchanged")
  items:updateFixed({})
  Assert.equal(mons:partyMon(0).heldItem, "POTION")
  Assert.equal(bag:quantity("POTION"), 0)
  items:dispose()
end

function T.active_box_projection_keeps_all_thirty_slots_after_holes()
  local mons = monService()
  local boxed = mons:partyMon(0)
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 29, mon = boxed } } }))
  change.publish()

  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  local slots = state:status().boxSlots
  Assert.equal(#slots, 30, "the active box projection retains all thirty positions")
  Assert.equal(slots[1], false, "an empty first position uses the explicit sentinel")
  Assert.equal(slots[16], false, "an empty middle position uses the explicit sentinel")
  Assert.equal(slots[30].personality, boxed.personality, "an occupied final position survives earlier holes")
  state:dispose()
end

function T.give_item_existing_item_confirmation_can_cancel_or_commit_through_storage()
  local mons = monService()
  local options = openOptions(mons, 3, "wide")
  local bag = options.bag
  Assert.isTrue(bag:add("POTION", 1))
  Assert.isTrue(bag:add("SITRUS_BERRY", 1))
  setPartyHeldItem(mons, "POTION")

  options.childFactories.heldItemPicker = heldItemPicker("SITRUS_BERRY")
  local cancelled = PcStorageState.new(options)
  cancelled:updateFixed({ { type = "party" } })
  cancelled:updateFixed({ { type = "action", action = "giveItem" } })
  cancelled:updateFixed({})
  Assert.equal(cancelled:status().lastAction.kind, "confirm", "replacing a held item requests confirmation")
  local beforeCancelMon = mons:partyMon(0)
  local beforeCancelRevision = bag:revision()
  cancelled:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(mons:partyMon(0), beforeCancelMon, "cancelling replacement preserves the held item")
  Assert.equal(bag:quantity("POTION"), 1, "cancelling replacement does not return the old item")
  Assert.equal(bag:quantity("SITRUS_BERRY"), 1, "cancelling replacement does not take the new item")
  Assert.equal(bag:revision(), beforeCancelRevision, "cancelling replacement does not publish Bag state")
  cancelled:dispose()

  options.childFactories.heldItemPicker = heldItemPicker("SITRUS_BERRY")
  local confirmed = PcStorageState.new(options)
  confirmed:updateFixed({ { type = "party" } })
  confirmed:updateFixed({ { type = "action", action = "giveItem" } })
  confirmed:updateFixed({})
  local beforeConfirmRevision = bag:revision()
  confirmed:updateFixed({ { type = "confirm" } })
  Assert.equal(mons:partyMon(0).heldItem, "SITRUS_BERRY", "confirmation installs the picked item")
  Assert.equal(bag:quantity("POTION"), 2, "confirmation returns the old held item")
  Assert.equal(bag:quantity("SITRUS_BERRY"), 0, "confirmation consumes the selected item")
  Assert.equal(bag:revision(), beforeConfirmRevision + 1, "confirmation publishes the Bag change once")
  confirmed:dispose()
end

function T.give_item_refusal_from_picker_preserves_mon_and_bag()
  local mons = monService()
  local options = openOptions(mons, 3, "wide")
  local bag = options.bag
  Assert.isTrue(bag:add("ITEM_112", 1))
  options.childFactories.heldItemPicker = heldItemPicker("ITEM_112")
  local state = PcStorageState.new(options)
  local beforeMon, beforeBagRevision = mons:partyMon(0), bag:revision()
  state:updateFixed({ { type = "party" } })
  state:updateFixed({ { type = "action", action = "giveItem" } })
  state:updateFixed({})
  Assert.equal(state:status().lastAction.reason, "griseous_orb", "the domain owner refuses an ineligible mon/item pair")
  Assert.deepEqual(mons:partyMon(0), beforeMon, "a refused picker result does not change the Pokemon")
  Assert.equal(bag:quantity("ITEM_112"), 1, "a refused picker result leaves inventory untouched")
  Assert.equal(bag:revision(), beforeBagRevision, "a refused picker result publishes no Bag revision")
  state:dispose()
end

function T.deposit_commits_to_the_currently_focused_box_target()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x55667788, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local occupied = mons:partyMon(1)
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = occupied } } }))
  change.publish()

  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  local deposited = mons:partyMon(0)
  state:updateFixed({ { type = "action", action = "deposit" } })
  Assert.equal(state:status().phase, "carry", "Deposit waits for the user's destination")
  state:updateFixed({ { type = "storage_target", target = { kind = "box", slot = 1 } } })
  local confirmed, failure = pcall(function()
    state:updateFixed({ { type = "confirm" } })
  end)
  Assert.isTrue(
    confirmed,
    "Deposit confirmation uses the focused empty slot instead of the occupied initial slot: " .. tostring(failure)
  )
  Assert.equal(mons:boxMon(0, 0).personality, occupied.personality, "the occupied source slot remains unchanged")
  local destination = mons:boxMon(0, 1)
  Assert.isTrue(destination ~= nil, "the focused empty destination receives the Party Pokemon")
  Assert.equal(destination.personality, deposited.personality, "the selected Party Pokemon reaches the focused slot")
  Assert.equal(mons:partyCount(), 1, "the deposited Pokemon leaves Party custody")
  state:dispose()
end

function T.deposit_tracks_controller_navigation_after_box_focus_changes()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x66778899, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local occupied = mons:partyMon(1)
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = occupied } } }))
  change.publish()

  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  local deposited = mons:partyMon(0)
  state:updateFixed({ { type = "action", action = "deposit" } })
  Assert.equal(state:status().visualView.cursor.node, 0, "the selector starts on the active box thumbnail")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().visualView.cursor.node, 8, "down reaches the selector's OK plate")
  local confirmed, failure = pcall(function()
    state:updateFixed({ { type = "confirm" } })
  end)
  Assert.isTrue(confirmed, "Deposit confirmation commits the chosen box: " .. tostring(failure))
  Assert.equal(mons:boxMon(0, 1).personality, deposited.personality)
  Assert.equal(mons:boxMon(0, 0).personality, occupied.personality)
  state:dispose()
end

function T.fresh_box_name_uses_the_manifest_default_without_overwriting_custom_names()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  Assert.equal(state:status().boxName, "BOX 1", "a fresh box displays its compiled default label")
  state:dispose()

  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { metadata = { { box = 0, name = "MY BOX" } } }))
  change.publish()
  local renamed = PcStorageState.new(openOptions(mons, 0, "wide"))
  Assert.equal(renamed:status().boxName, "MY BOX", "a persisted custom name takes precedence over the default")
  Assert.equal(mons:boxMetadata(0).name, "MY BOX", "presentation does not rewrite box metadata")
  renamed:dispose()
end

function T.expanded_box_name_uses_the_production_expansion_ordinal()
  local mons = monService(19)
  setActiveBox(mons, 18)
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  Assert.equal(state:status().boxName, "BOX 19")
  state:dispose()
end

function T.raw_pointer_selects_a_storage_target_through_the_state_owner()
  local mons = monService()
  local boxed = mons:partyMon(0)
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 4, mon = boxed } } }))
  change.publish()
  local state = PcStorageState.new(openOptions(mons, 1, "nativeLike"))
  local target = assert(state._session:plan().content.hitRegions.boxSlots[5])
  local x, y = hostPointForRect(state, target.rect)
  local ok, failure = pcall(function()
    state:updateFixed({
      { type = "pointer_down", pointerId = "storage-target", x = x, y = y },
      { type = "pointer_up", pointerId = "storage-target", x = x, y = y },
    })
  end)
  Assert.isTrue(ok, "the Storage owner maps raw pointer events before semantic dispatch: " .. tostring(failure))
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 4 })
  state:dispose()
end
function T.missing_compiled_box_name_fails_instead_of_using_expansion_copy()
  local options = openOptions(monService(), 0, "wide")
  options.manifest.storage.boxNames[1] = nil
  local ok = pcall(function()
    PcStorageState.new(options)
  end)
  Assert.isFalse(ok, "missing source box labels are generated-asset invariant failures")
end

function T.child_cancel_returns_to_the_same_mode_box_and_focus()
  local mons = monService()
  local disposed = 0
  local childFactories = {
    summary = function(request)
      Assert.deepEqual(request.source, { kind = "box", box = 0, slot = 0 })
      local result
      return {
        updateFixed = function(_, events)
          for _, event in ipairs(events) do
            if event.type == "cancel" then
              result = { kind = "cancel" }
            end
          end
        end,
        result = function()
          local nextResult = result
          result = nil
          return nextResult
        end,
        dispose = function()
          disposed = disposed + 1
        end,
      }
    end,
  }
  local options = openOptions(mons, 2, "wide")
  options.childFactories = childFactories
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "action", action = "summary" } })
  Assert.equal(state:status().childKind, "summary")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(state:status().phase, "browse")
  Assert.equal(state:status().mode, 2)
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 0 })
  Assert.equal(disposed, 1, "returned child is disposed exactly once")
  state:dispose()
end

function T.nested_child_receives_the_original_raw_pointer_batch()
  local mons = monService()
  local received
  local options = openOptions(mons, 2, "nativeLike")
  options.childFactories.summary = function()
    return {
      updateFixed = function(_, events)
        received = events
      end,
      result = function()
        return nil
      end,
      dispose = function() end,
    }
  end
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "action", action = "summary" } })
  local hit = assert(state._session:plan().content.hitRegions.boxSlots[1])
  local x, y = hostPointForRect(state, hit.rect)
  local raw = { type = "pointer_down", pointerId = "summary-touch", x = x, y = y }
  state:updateFixed({ raw })
  Assert.deepEqual(received, { raw }, "the child owns the raw host event and its coordinates")
  Assert.deepEqual(
    state:status().focus,
    { domain = "box", slot = 0 },
    "parent focus is untouched while the child owns input"
  )
  state:dispose()
end

function T.direct_disposal_releases_a_live_child_once()
  local mons = monService()
  local disposed = 0
  local options = openOptions(mons, 2, "wide")
  options.childFactories.summary = function()
    return {
      updateFixed = function() end,
      result = function()
        return nil
      end,
      dispose = function()
        disposed = disposed + 1
      end,
    }
  end
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "action", action = "summary" } })
  state:dispose()
  state:dispose()
  Assert.equal(disposed, 1, "direct and repeated parent disposal release the child exactly once")
  Assert.isFalse(state:isActive())
end

function T.storage_pointer_capture_cancellation_drops_release_and_reaches_child()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 1, "nativeLike"))
  local target = assert(state._session:plan().content.hitRegions.boxSlots[3])
  local x, y = hostPointForRect(state, target.rect)
  state:updateFixed({ { type = "pointer_down", pointerId = "storage-touch", x = x, y = y } })
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 2 })
  state:cancelPointerCapture()
  local ok, failure = pcall(function()
    state:updateFixed({ { type = "pointer_up", pointerId = "storage-touch", x = x, y = y } })
  end)
  Assert.isTrue(ok, "cancelled capture consumes its stale release: " .. tostring(failure))
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 2 }, "stale release does not activate another target")
  state:dispose()

  local childCancelled = 0
  local childOptions = openOptions(monService(), 2, "wide")
  childOptions.childFactories.summary = function()
    return {
      updateFixed = function() end,
      result = function()
        return nil
      end,
      cancelPointerCapture = function()
        childCancelled = childCancelled + 1
      end,
      dispose = function() end,
    }
  end
  local childState = PcStorageState.new(childOptions)
  childState:updateFixed({ { type = "action", action = "summary" } })
  childState:cancelPointerCapture()
  Assert.equal(childCancelled, 1, "Storage forwards capture cancellation to its active child")
  childState:dispose()
end

function T.refused_carry_keeps_storage_live_and_preserves_domain_custody()
  local mons = monService()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local state = PcStorageState.new({
    mode = 2,
    mons = mons,
    bag = bag,
    manifest = PcPresentationFixture.manifest(),
    dexNumber = function() end,
    measureDisplay = function()
      return measurement("wide")
    end,
    audio = { play = function() end },
    charmap = CatalogFixture.CHARMAP,
    icons = {},
    portraits = {},
    childFactories = {},
  })
  local beforeMon = mons:partyMon(0)
  local beforePartyRevision = mons:partyRevision()
  local beforeBoxRevision = mons:boxRevision()
  local beforeBagRevision = bag:revision()
  state:updateFixed({ { type = "party" } })
  state:updateFixed({ { type = "action", action = "move" } })
  Assert.notNil(state:status().carry)
  local ok, failure = pcall(function()
    state:updateFixed({
      { type = "storage_target", target = { kind = "box", box = 0, slot = 0 } },
      { type = "confirm" },
    })
  end)
  Assert.isTrue(ok, "the Storage consumer commits the domain refusal as data: " .. tostring(failure))
  Assert.equal(state:status().lastAction.kind, "refused")
  Assert.equal(state:status().lastAction.reason, "last_usable")
  Assert.notNil(state:status().carry, "the user can select another destination or cancel")
  Assert.isTrue(state:isActive())
  Assert.deepEqual(mons:partyMon(0), beforeMon)
  Assert.equal(mons:partyRevision(), beforePartyRevision)
  Assert.equal(mons:boxRevision(), beforeBoxRevision)
  Assert.equal(bag:revision(), beforeBagRevision)
  Assert.isNil(mons:boxMon(0, 0))
  state:dispose()
end

function T.take_held_item_and_edit_box_records_return_through_child_results()
  local mons = monService()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local held = mons:partyMon(0)
  held.heldItem = "POTION"
  local partyChange = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = held } }))
  partyChange.publish()
  local items = PcStorageState.new({
    mode = 3,
    mons = mons,
    bag = bag,
    manifest = PcPresentationFixture.manifest(),
    measureDisplay = function()
      return measurement("wide")
    end,
    audio = { play = function() end },
    dexNumber = function() end,
    icons = {},
    portraits = {},
    childFactories = {},
  })
  items:updateFixed({ { type = "party" } })
  items:updateFixed({ { type = "action", action = "takeItem" } })
  items:updateFixed({ { type = "confirm" } })
  Assert.equal(mons:partyMon(0).heldItem, "NONE")
  Assert.equal(bag:quantity("POTION"), 1)
  items:dispose()

  local factory = CatalogFixture.makeFactory(0x33445566, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local first = mons:partyMon(0)
  first.heldItem = "POTION"
  local second = mons:partyMon(1)
  second.heldItem = "SITRUS_BERRY"
  local heldChange = assert(mons:preparePartyChanges(mons:partyRevision(), {
    { slot = 0, mon = first },
    { slot = 1, mon = second },
  }))
  heldChange.publish()
  local itemSwap = PcStorageState.new({
    mode = 3,
    mons = mons,
    bag = bag,
    manifest = PcPresentationFixture.manifest(),
    measureDisplay = function()
      return measurement("wide")
    end,
    audio = { play = function() end },
    dexNumber = function() end,
    icons = {},
    portraits = {},
    childFactories = {},
  })
  itemSwap:updateFixed({ { type = "party" } })
  itemSwap:updateFixed({ { type = "action", action = "swapItems" } })
  Assert.equal(itemSwap:status().phase, "carry")
  itemSwap:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 1 } }, { type = "confirm" } })
  Assert.equal(mons:partyMon(0).heldItem, "SITRUS_BERRY")
  Assert.equal(mons:partyMon(1).heldItem, "POTION")
  Assert.equal(bag:quantity("POTION"), 1, "a held-item swap leaves the Bag unchanged")
  itemSwap:dispose()

  local original = mons:partyMon(0)
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 7, mon = original } } }))
  stored.publish()
  local childFactories = {}
  for _, kind in ipairs({ "boxName" }) do
    local childKind = kind
    childFactories[childKind] = function(request)
      return {
        updateFixed = function(_, events)
          for _, event in ipairs(events) do
            if event.type == "submit" then
              request.result = childKind == "markings" and { kind = "submit", mask = 37 }
                or childKind == "boxName" and { kind = "submit", text = "TEST BOX" }
                or { kind = "submit", wallpaperId = 2 }
            elseif event.type == "cancel" then
              request.result = { kind = "cancel" }
            end
          end
        end,
        result = function()
          local nextResult = request.result
          request.result = nil
          return nextResult
        end,
        dispose = function() end,
      }
    end
  end
  local editingOptions = openOptions(mons, 1, "wide")
  editingOptions.childFactories = childFactories
  local editing = PcStorageState.new(editingOptions)
  editing:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 7 } } })
  editing:updateFixed({ { type = "action", action = "markings" } })
  editing:updateFixed({ { type = "confirm" } })
  editing:updateFixed({ { type = "submit" } })
  Assert.equal(assert(mons:boxMon(0, 7)).markings, 1)
  Assert.isFalse(editing:acceptsText(), "typed text is not routed to Storage itself")
  editing:updateFixed({ { type = "action", action = "boxName" } })
  Assert.isTrue(editing:acceptsText(), "the box-name editor takes typed text")
  editing:updateFixed({ { type = "submit" } })
  Assert.isFalse(editing:acceptsText())
  Assert.equal(mons:boxMetadata(0).name, "TEST BOX")
  editing:updateFixed({ { type = "action", action = "wallpaper" } })
  editing:updateFixed({ { type = "wallpaper_choice", id = 2 } })
  editing:updateFixed({ { type = "submit" } })
  Assert.equal(mons:boxMetadata(0).wallpaperId, 2)
  editing:dispose()
end

function T.cancelled_summary_and_name_children_return_to_parent()
  local mons = monService()
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 7, mon = mons:partyMon(0) } } }))
  stored.publish()
  local beforeMon = assert(mons:boxMon(0, 7))
  local beforeMetadata = mons:boxMetadata(0)
  local disposed = 0
  local childFactories = {}
  for _, childKind in ipairs({ "summary", "boxName" }) do
    childFactories[childKind] = function()
      return {
        updateFixed = function() end,
        result = function()
          return { kind = "cancel" }
        end,
        dispose = function()
          disposed = disposed + 1
        end,
      }
    end
  end
  local options = openOptions(mons, 1, "wide")
  options.childFactories = childFactories
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 7 } } })
  for _, childKind in ipairs({ "summary", "boxName" }) do
    state:updateFixed({ { type = "action", action = childKind } })
    Assert.equal(state:status().phase, "child")
    state:updateFixed({ { type = "cancel" } })
    Assert.equal(state:status().phase, "browse")
    Assert.equal(state:status().mode, 1)
    Assert.equal(state:status().activeBox, 0)
    Assert.deepEqual(state:status().focus, { domain = "box", slot = 7 })
  end
  Assert.deepEqual(mons:boxMon(0, 7), beforeMon)
  Assert.deepEqual(mons:boxMetadata(0), beforeMetadata)
  Assert.equal(disposed, 2, "each cancelled child is disposed once")
  state:dispose()
end

function T.active_markings_editor_masks_box_slot_pointer_input()
  local mons = monService()
  local boxed = mons:partyMon(0)
  boxed.markings = 5
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 7, mon = boxed } } }))
  change.publish()

  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 7 } } })
  local browsePlan = state._session:plan()
  local boxSlot = assert(browsePlan.content.hitRegions.boxSlots[8])
  local x, y = hostPointForRect(state, boxSlot.rect)
  state:updateFixed({ { type = "action", action = "markings" } })

  local before = state:status()
  local partyRevision = mons:partyRevision()
  local boxRevision = mons:boxRevision()
  local beforeMon = mons:boxMon(0, 7)
  local ok, failure = pcall(function()
    state:updateFixed({
      { type = "pointer_down", pointerId = "editor-box-slot", x = x, y = y },
      { type = "pointer_up", pointerId = "editor-box-slot", x = x, y = y },
    })
  end)

  Assert.isTrue(ok, "an editor masks the underlying box target: " .. tostring(failure))
  local after = state:status()
  Assert.equal(after.phase, "editor")
  Assert.equal(after.editor.kind, "markings")
  Assert.equal(after.editor.mask, before.editor.mask)
  Assert.deepEqual(after.focus, before.focus)
  Assert.isNil(after.carry)
  Assert.deepEqual(mons:boxMon(0, 7), beforeMon)
  Assert.equal(mons:partyRevision(), partyRevision)
  Assert.equal(mons:boxRevision(), boxRevision)
  state:dispose()
end

function T.active_editor_ignores_queued_pointer_cancellation()
  local mons = monService()
  local boxed = mons:partyMon(0)
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 7, mon = boxed } } }))
  change.publish()

  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 7 } } })
  state:updateFixed({ { type = "action", action = "markings" } })
  local before = state:status()
  local partyRevision = mons:partyRevision()
  local boxRevision = mons:boxRevision()
  local beforeMon = mons:boxMon(0, 7)
  local x, y = hostPointForRect(state, { x = 10, y = 10, width = 1, height = 1 })
  state:updateFixed({ { type = "pointer_down", pointerId = "editor-neutral", x = x, y = y } })
  state:cancelPointerCapture()

  local ok, failure = pcall(function()
    state:updateFixed({})
  end)

  Assert.isTrue(ok, "a queued pointer cancellation is inert in editor mode: " .. tostring(failure))
  local after = state:status()
  Assert.equal(after.phase, "editor")
  Assert.equal(after.editor.kind, "markings")
  Assert.equal(after.editor.mask, before.editor.mask)
  Assert.deepEqual(after.focus, before.focus)
  Assert.isNil(after.carry)
  Assert.deepEqual(mons:boxMon(0, 7), beforeMon)
  Assert.equal(mons:partyRevision(), partyRevision)
  Assert.equal(mons:boxRevision(), boxRevision)
  state:dispose()
end

function T.markings_and_wallpaper_edit_as_local_source_phases()
  local mons = monService()
  local boxed = mons:partyMon(0)
  boxed.markings = 5
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 7, mon = boxed } } }))
  stored.publish()
  local openedChildren = 0
  local options = openOptions(mons, 1, "wide")
  options.childFactories = {
    markings = function()
      openedChildren = openedChildren + 1
      error("markings are a local Storage phase")
    end,
    wallpaper = function()
      openedChildren = openedChildren + 1
      error("wallpaper is a local Storage phase")
    end,
  }
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 7 } } })
  local info = assert(state:_view().info, "the highlighted mon publishes its top-screen facts")
  local highlighted = assert(mons:boxMon(0, 7))
  Assert.equal(info.nickname, Mon.displayName(highlighted, mons:catalog()), "the info panel names the highlighted mon")
  Assert.notNil(info.level, "a non-egg mon publishes its level")
  Assert.notNil(info.natureName, "a non-egg mon publishes its nature")
  state:updateFixed({ { type = "action", action = "markings" } })
  Assert.equal(state:status().phase, "editor")
  Assert.equal(state:status().editor.kind, "markings")
  local markingPlan = state._session:plan()
  Assert.equal(#markingPlan.content.hitRegions.editorChoices, 6)
  Assert.deepEqual(markingPlan.content.hitRegions.editorChoices[1].rect, { x = 188, y = 60, width = 16, height = 16 })
  Assert.deepEqual(
    markingPlan.mapInput({ type = "pointer_down", x = 189, y = 61 }, state:_view(), markingPlan),
    { type = "marking_choice", id = 0 },
    "the source marking tile and its pointer target share one plan"
  )
  rawPointerAt(state, markingPlan.content.hitRegions.editorChoices[2].rect, "marking-choice")
  Assert.equal(state:status().editor.mask, 7, "raw pointer input toggles a local marking choice")
  state:updateFixed({ { type = "submit" } })
  Assert.equal(assert(mons:boxMon(0, 7)).markings, 7)
  Assert.equal(openedChildren, 0)

  state:updateFixed({ { type = "action", action = "wallpaper" } })
  Assert.equal(state:status().phase, "editor")
  Assert.equal(state:status().editor.kind, "wallpaper")
  local plan = state._session:plan()
  Assert.equal(#plan.content.hitRegions.editorChoices, 8, "four swatches, two page arrows, confirm and Cancel")
  local tap = plan.mapInput({ type = "pointer_down", x = 105, y = 35 }, state:_view(), plan)
  Assert.deepEqual(tap, { type = "wallpaper_choice", id = 1 }, "pointer and draw plans share wallpaper geometry")
  Assert.deepEqual(
    plan.mapInput({ type = "pointer_down", x = 240, y = 35 }, state:_view(), plan),
    { type = "wallpaper_page", delta = 1 },
    "the right arrow pages forward"
  )
  Assert.deepEqual(
    plan.mapInput({ type = "pointer_down", x = 200, y = 130 }, state:_view(), plan),
    { type = "submit" },
    "the confirm button submits"
  )
  Assert.deepEqual(
    plan.mapInput({ type = "pointer_down", x = 200, y = 180 }, state:_view(), plan),
    { type = "cancel" },
    "the Cancel button cancels"
  )
  rawPointerAt(state, plan.content.hitRegions.editorChoices[2].rect, "wallpaper-choice")
  Assert.equal(state:status().editor.selected, 1, "raw pointer input selects a local wallpaper choice")
  state:updateFixed({ { type = "wallpaper_choice", id = 16 } })
  Assert.equal(state:status().editor.selected, 16, "a locked bonus entry can be highlighted")
  state:updateFixed({ { type = "submit" } })
  Assert.equal(state:status().phase, "editor", "confirming a locked entry keeps the chooser open")
  Assert.equal(mons:boxMetadata(0).wallpaperId, 0, "a locked entry never reaches the box")
  state:updateFixed({ { type = "wallpaper_choice", id = 2 } })
  state:updateFixed({ { type = "submit" } })
  Assert.equal(mons:boxMetadata(0).wallpaperId, 2)
  Assert.equal(openedChildren, 0)

  state:updateFixed({ { type = "action", action = "wallpaper" } })
  Assert.equal(state:status().editor.selected, 2, "the chooser opens on the box's current wallpaper")
  state:updateFixed({ { type = "submit" } })
  Assert.equal(state:status().phase, "editor", "confirming the current wallpaper keeps the chooser open")
  Assert.equal(mons:boxMetadata(0).wallpaperId, 2, "confirming the current wallpaper does not mutate the box")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(state:status().phase, "browse")

  local unlocked = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { bonusUnlocks = { true, true, true, true, true, true, true, true } }))
  unlocked.publish()
  state:updateFixed({ { type = "action", action = "wallpaper" } })
  state:updateFixed({ { type = "navigate", direction = "right" }, { type = "navigate", direction = "right" } })
  Assert.equal(state:status().editor.selected, 0, "horizontal movement wraps within the page's four swatches")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().editor.focus, "confirm", "down walks to the confirm button")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().editor.focus, "cancel", "then to Cancel")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().editor.focus, "slots", "up returns to the swatches")
  state:updateFixed({ { type = "wallpaper_page", delta = -1 } })
  Assert.equal(state:status().editor.selected, 20, "paging wraps across the six pages of four")
  state:updateFixed({ { type = "submit" } })
  Assert.equal(mons:boxMetadata(0).wallpaperId, 36, "logical bonus wallpaper maps to its stored identity")

  state:updateFixed({ { type = "action", action = "markings" } })
  local cancelledPlan = state._session:plan()
  local markingTap = cancelledPlan.mapInput({ type = "pointer_down", x = 189, y = 61 }, state:_view(), cancelledPlan)
  state:updateFixed({ markingTap })
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(assert(mons:boxMon(0, 7)).markings, 7, "cancel discards the local marking draft")
  state:dispose()
end

function T.release_scan_processes_fifteen_addresses_per_tick_and_detects_stale_custody()
  for _, configuration in ipairs({ "dualDisplay", "nativeLike", "wide", "tall" }) do
    local mons = releaseService()
    local state = PcStorageState.new(openOptions(mons, 2, configuration))
    state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
    local confirmation = state:status().releaseCheck
    Assert.equal(confirmation.outcome, "confirm")
    Assert.equal(confirmation.total, 37 * 30 + 6)
    Assert.deepEqual(confirmation.address, { kind = "party", slot = 0 })

    confirmReleaseYes(state)
    local pending = state:status().releaseCheck
    Assert.equal(pending.outcome, "pending")
    Assert.equal(pending.scanned, 15, "each fixed tick advances fifteen candidate addresses")
    Assert.equal(mons:partyCount(), 2, "confirmation does not remove custody before the scan completes")

    local external = mons:partyMon(1)
    external.heldItem = "SITRUS_BERRY"
    local preparation = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = external } }))
    preparation.publish()
    state:updateFixed({})
    Assert.equal(state:status().releaseCheck.outcome, "stale", "revision drift cancels the scan")
    Assert.equal(mons:partyCount(), 2, "stale scan retains the selected mon")
    Assert.notNil(mons:boxMon(36, 29), "stale scan leaves the expanded-box mon untouched")
    state:dispose()
  end
end

function T.completed_release_scan_includes_the_last_box_and_clears_every_check_move()
  -- The last box (36) holds an alternative that knows the released mon's whole
  -- release-check set (Surf and Fly), so every flag bit clears and the mon may
  -- leave the save.
  local mons = releaseService()
  local alternative = mons:partyMon(1)
  alternative.moves[2] = { move = "FLY", pp = mons:catalog():move("FLY").basePp, ppUps = 0 }
  assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = alternative } })).publish()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  local released = finishReleaseScan(state)
  Assert.equal(released.total, 37 * 30 + 6)
  Assert.equal(released.outcome, "removed", "a fully covered check-move set permits removal")
  Assert.equal(mons:partyCount(), 1)
  Assert.notNil(mons:boxMon(36, 29), "release never moves the alternative holder")
  state:dispose()

  local reversed = releaseService("surf")
  reversed:setMove(0, 1, "TACKLE")
  reversed:setMove(0, 0, "FLY")
  reversed:setMove(0, 1, "SURF")
  local reverseState = PcStorageState.new(openOptions(reversed, 2, "wide"))
  local returned = finishReleaseScan(reverseState)
  Assert.equal(returned.outcome, "returned", "an uncovered release-check move brings the mon back")
  Assert.equal(reversed:partyCount(), 2, "returned Pokemon retains party custody")
  reverseState:dispose()

  -- Every release-check move must stay known: Surf is duplicated but Fly is
  -- not, so the mon returns even though the first matching move is covered
  -- (PCBox_RunReleaseMoveCheck keeps one flag bit per uncovered move).
  local mixed = releaseService("surf")
  mixed:setMove(0, 0, "SURF")
  mixed:setMove(0, 1, "FLY")
  local mixedState = PcStorageState.new(openOptions(mixed, 2, "wide"))
  local mixedResult = finishReleaseScan(mixedState)
  Assert.equal(mixedResult.outcome, "returned", "a partially covered move set still returns the mon")
  Assert.equal(mixed:partyCount(), 2, "the mon stays in the party")
  mixedState:dispose()
end

function T.populated_boxes_keep_idle_projection_off_full_capture()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0xA11CE01, mons:catalog())
  local activeMon = mons:partyMon(0)
  local offscreen = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
  local seeded = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, {
    boxUpdates = {
      { box = 0, slot = 0, mon = activeMon },
      { box = 1, slot = 0, mon = offscreen },
      { box = 1, slot = 1, mon = offscreen },
      { box = 2, slot = 5, mon = offscreen },
    },
    bonusUnlocks = { true, false, true, false, false, false, false, false },
  }))
  seeded.publish()
  local fullCaptures = 0
  local originalSnapshot = mons.boxSnapshot
  mons.boxSnapshot = function(self)
    fullCaptures = fullCaptures + 1
    return originalSnapshot(self)
  end
  local boxMonReads = 0
  local originalBoxMon = mons.boxMon
  mons.boxMon = function(self, box, slot)
    boxMonReads = boxMonReads + 1
    return originalBoxMon(self, box, slot)
  end
  local ok, failure = pcall(function()
    local state = PcStorageState.new(openOptions(mons, 0, "wide"))
    local view = state:_view()
    Assert.notNil(view.boxSlots[1], "the active box projection keeps its visible mon")
    Assert.deepEqual(
      view.wallpaperUnlocks,
      { true, false, true, false, false, false, false, false },
      "visible flags match the domain unlocks"
    )
    Assert.equal(fullCaptures, 0, "opening projection never copies whole storage for flags")
    Assert.isTrue(boxMonReads <= 30, "opening reads at most the thirty visible slots")
    local settledReads = boxMonReads
    state:updateFixed({})
    local idleStatus = state:status()
    Assert.notNil(idleStatus.boxSlots[1], "idle update keeps the visible mon")
    state:_view()
    Assert.equal(fullCaptures, 0, "idle update and status never copy whole storage")
    Assert.equal(boxMonReads, settledReads, "unchanged identity reuses bounded visible contents")
    state:updateFixed({ { type = "storage_target", target = { kind = "box", slot = 0 } } })
    state:updateFixed({ { type = "action", action = "wallpaper" } })
    Assert.equal(state:status().phase, "editor", "wallpaper editing opens over the bounded projection")
    state:updateFixed({ { type = "navigate", direction = "right" } })
    state:updateFixed({ { type = "wallpaper_choice", id = 2 } })
    Assert.equal(fullCaptures, 0, "wallpaper editing never copies whole storage")
    state:dispose()
  end)
  mons.boxSnapshot = originalSnapshot
  mons.boxMon = originalBoxMon
  Assert.isTrue(ok, "bounded projection gate: " .. tostring(failure))
  Assert.equal(fullCaptures, 0, "no full storage capture on any display path")
end

function T.visible_contents_follow_revisions_and_box_identity_while_overlays_advance()
  local mons = monService()
  Assert.notNil(mons.boxBonusUnlocks, "the service exposes the narrow unlock read")
  local factory = CatalogFixture.makeFactory(0xB0111111, mons:catalog())
  local firstBoxMon = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
  local secondBoxMon = mons:partyMon(0)
  local seeded = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, {
    boxUpdates = {
      { box = 0, slot = 0, mon = firstBoxMon },
      { box = 1, slot = 0, mon = secondBoxMon },
    },
  }))
  seeded.publish()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  state:updateFixed({ { type = "storage_target", target = { kind = "box", slot = 5 } } })
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 5 }, "focus starts on a known slot")
  local added = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
  local mutated = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, {
    boxUpdates = { { box = 0, slot = 1, mon = added } },
    bonusUnlocks = { true, true, false, false, false, false, false, false },
  }))
  mutated.publish()
  state:updateFixed({})
  local refreshed = state:status()
  Assert.notNil(refreshed.boxSlots[2], "a box revision refreshes the visible second slot")
  Assert.deepEqual(
    state:_view().wallpaperUnlocks,
    { true, true, false, false, false, false, false, false },
    "an unlock revision is visible on the next update"
  )
  Assert.deepEqual(refreshed.focus, { domain = "box", slot = 5 }, "content refresh leaves cursor focus alone")
  state:updateFixed({ { type = "action", action = "move" } })
  Assert.equal(state:status().phase, "carry", "carry starts from the refreshed projection")
  state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 1, slot = 0 } } })
  state:updateFixed({ { type = "cancel" } })
  local moved = state:status()
  Assert.equal(moved.activeBox, 1, "changing the active box follows the requested identity")
  Assert.notNil(moved.boxSlots[1], "the new active box shows its own visible mon")
  Assert.equal(moved.phase, "browse", "cancelling carry returns to browsing the new box")
  state:dispose()
end

function T.published_status_stays_detached_and_survives_failed_refresh()
  local mons = monService()
  local first = mons:boxBonusUnlocks()
  Assert.equal(#first, 8, "the narrow unlock read returns eight flags")
  for index = 1, 8 do
    Assert.equal(type(first[index]), "boolean", "each unlock flag is an isolated boolean")
  end
  first[1] = not first[1]
  local second = mons:boxBonusUnlocks()
  Assert.equal(second[1], not first[1], "mutating a returned vector never touches the domain flags")
  local factory = CatalogFixture.makeFactory(0xCAFE011, mons:catalog())
  local boxed = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
  local seeded = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = boxed } } }))
  seeded.publish()
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  local before = state:status()
  local beforeSlot = assert(before.boxSlots[1], "the seeded slot is visible before mutation")
  local beforePersonality = beforeSlot.personality
  before.boxSlots[1] = false
  before.party[1].nickname = "TAMPERED"
  Assert.equal(
    assert(mons:boxMon(0, 0)).personality,
    beforePersonality,
    "mutating published slots never reaches stored mons"
  )
  local afterTamper = state:status()
  Assert.equal(
    assert(afterTamper.boxSlots[1]).personality,
    beforePersonality,
    "mutating published slots never alters cached render facts"
  )
  local originalBoxMon = mons.boxMon
  local extra = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
  local drifted = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 2, mon = extra } } }))
  drifted.publish()
  mons.boxMon = function()
    error("injected narrow read failure", 0)
  end
  local failed = pcall(function()
    state:updateFixed({})
  end)
  mons.boxMon = originalBoxMon
  Assert.isFalse(failed, "a narrow read failure propagates instead of fabricating contents")
  local retained = state:status()
  Assert.equal(
    assert(retained.boxSlots[1]).personality,
    beforePersonality,
    "a failed refresh never publishes a mixed or empty view"
  )
  Assert.equal(before.boxSlots[1], false, "successful replacement leaves the previously held status stable")
  state:dispose()
end

function T.menu_and_mapped_release_share_protected_move_return()
  local function protectedService()
    local mons = releaseService("surf")
    mons:setMove(0, 1, "TACKLE")
    mons:setMove(0, 0, "FLY")
    mons:setMove(0, 1, "SURF")
    return mons
  end
  local function settle(state)
    return settleReleaseScan(state)
  end

  local menuMons = protectedService()
  local menuState = PcStorageState.new(openOptions(menuMons, 2, "wide"))
  menuState:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  local menuArmed = menuState:status().releaseCheck
  Assert.notNil(menuArmed, "menu protected-move request opens confirmation")
  Assert.equal(menuArmed.outcome, "confirm")
  Assert.deepEqual(menuArmed.address, { kind = "party", slot = 0 })
  local menuSettled, menuTicks, menuMaximum = settle(menuState)
  Assert.equal(menuSettled.outcome, "returned", "menu protected-move request returns instead of removing")
  Assert.equal(menuMons:partyCount(), 2, "menu return keeps party custody")
  Assert.notNil(menuMons:boxMon(36, 29), "menu return leaves the alternative holder untouched")
  menuState:dispose()

  local eventMons = protectedService()
  local eventState = PcStorageState.new(openOptions(eventMons, 2, "wide"))
  eventState:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  local eventArmed = eventState:status().releaseCheck
  Assert.notNil(eventArmed, "mapped protected-move request opens confirmation")
  Assert.equal(eventArmed.outcome, "confirm")
  local eventSettled, eventTicks, eventMaximum = settle(eventState)
  Assert.equal(eventSettled.outcome, "returned")
  Assert.equal(eventMons:partyCount(), 2)
  Assert.equal(menuArmed.total, eventArmed.total, "both origins scan the same candidate set")
  Assert.equal(menuSettled.scanned, eventSettled.scanned, "both origins advance the same progress")
  Assert.equal(menuTicks, eventTicks, "both origins settle on the same timing")
  Assert.equal(menuMaximum, eventMaximum)
  eventState:dispose()
end

function T.menu_and_mapped_release_agree_on_removal_cancel_and_stale()
  local function settle(state)
    confirmReleaseYes(state)
    local check = state:status().releaseCheck
    local maximumTicks = math.ceil(check.total / 15)
    local ticks = 1
    while check.outcome == "pending" do
      Assert.isTrue(ticks < maximumTicks, "removal scan completes within the candidate count")
      state:updateFixed({})
      ticks = ticks + 1
      check = state:status().releaseCheck
    end
    return acknowledgeReleaseMessages(state) or check
  end

  local menuMons = releaseService()
  local menuState = PcStorageState.new(openOptions(menuMons, 2, "wide"))
  menuState:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  Assert.equal(menuState:status().releaseCheck.outcome, "confirm")
  local menuRemoved = settle(menuState)
  Assert.equal(menuRemoved.outcome, "removed")
  Assert.equal(menuMons:partyCount(), 1, "menu removal publishes once")
  local menuCount = menuMons:partyCount()
  menuState:updateFixed({})
  menuState:updateFixed({})
  Assert.equal(menuState:status().releaseCheck.outcome, "removed", "settled menu removal never commits again")
  Assert.equal(menuMons:partyCount(), menuCount)
  menuState:dispose()

  local eventMons = releaseService()
  local eventState = PcStorageState.new(openOptions(eventMons, 2, "wide"))
  eventState:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  Assert.equal(eventState:status().releaseCheck.outcome, "confirm")
  local eventRemoved = settle(eventState)
  Assert.equal(eventRemoved.outcome, "removed")
  Assert.equal(eventMons:partyCount(), 1, "mapped removal publishes once")
  local eventCount = eventMons:partyCount()
  eventState:updateFixed({})
  Assert.equal(eventMons:partyCount(), eventCount, "settled mapped removal never commits again")
  eventState:dispose()

  local menuCancelMons = releaseService()
  local menuCancel = PcStorageState.new(openOptions(menuCancelMons, 2, "wide"))
  menuCancel:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  confirmReleaseYes(menuCancel)
  Assert.equal(menuCancel:status().releaseCheck.outcome, "pending")
  menuCancel:updateFixed({ { type = "cancel" } })
  Assert.equal(menuCancel:status().releaseCheck.outcome, "cancelled", "menu cancel stops the scan")
  Assert.equal(menuCancelMons:partyCount(), 2, "menu cancel never removes")
  menuCancel:dispose()

  local eventCancelMons = releaseService()
  local eventCancel = PcStorageState.new(openOptions(eventCancelMons, 2, "wide"))
  eventCancel:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  confirmReleaseYes(eventCancel)
  eventCancel:updateFixed({ { type = "cancel" } })
  Assert.equal(eventCancel:status().releaseCheck.outcome, "cancelled")
  Assert.equal(eventCancelMons:partyCount(), 2, "mapped cancel never removes")
  eventCancel:dispose()

  local menuStaleMons = releaseService()
  local menuStale = PcStorageState.new(openOptions(menuStaleMons, 2, "wide"))
  menuStale:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  confirmReleaseYes(menuStale)
  local drifting = menuStaleMons:partyMon(1)
  drifting.heldItem = "SITRUS_BERRY"
  local preparation =
    assert(menuStaleMons:preparePartyChanges(menuStaleMons:partyRevision(), { { slot = 1, mon = drifting } }))
  preparation.publish()
  menuStale:updateFixed({})
  Assert.equal(menuStale:status().releaseCheck.outcome, "stale", "menu revision drift cancels the scan")
  Assert.equal(menuStaleMons:partyCount(), 2, "menu stale scan retains the selected mon")
  menuStale:dispose()

  local armed = PcStorageState.new(openOptions(releaseService(), 2, "wide"))
  armed:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  Assert.equal(armed:status().releaseCheck.outcome, "confirm")
  local secondMenu = pcall(function()
    armed:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  end)
  Assert.isFalse(secondMenu, "a second menu request never overwrites the armed decision")
  local secondEvent = pcall(function()
    armed:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  end)
  Assert.isFalse(secondEvent, "a second mapped request never overwrites the armed decision")
  Assert.deepEqual(armed:status().releaseCheck.address, { kind = "party", slot = 0 })
  armed:dispose()
end

-- Settles an armed confirmation through the bounded fixed-tick scan and
-- returns the terminal check with its tick count and tick budget.
local function settleArmedRelease(state)
  local check, ticks, maximumTicks = settleReleaseScan(state)
  return acknowledgeReleaseMessages(state) or check, ticks, maximumTicks
end

function T.sequential_confirmed_removals_share_one_storage_lifetime()
  local mons = releaseService()
  local factory = CatalogFixture.makeFactory(0x5EED01, mons:catalog())
  for _ = 1, 2 do
    Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  end
  Assert.equal(mons:partyCount(), 4, "both added members join the party before the first release")
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({ { type = "party" } })

  state:updateFixed({ { type = "release", address = { kind = "party", slot = 2 } } })
  local firstArmed = state:status().releaseCheck
  Assert.equal(firstArmed.outcome, "confirm")
  Assert.equal(firstArmed.scanned, 0)
  Assert.equal(firstArmed.total, 37 * 30 + 6)
  Assert.deepEqual(firstArmed.address, { kind = "party", slot = 2 })
  local beforeFirst = mons:partyRevision()
  local firstSettled, firstTicks, firstMaximum = settleArmedRelease(state)
  Assert.equal(firstSettled.outcome, "removed")
  Assert.equal(firstSettled.scanned, firstSettled.total)
  Assert.equal(mons:partyCount(), 3)
  Assert.isTrue(mons:partyRevision() ~= beforeFirst, "the first removal publishes once")
  local afterFirst = mons:partyRevision()

  state:updateFixed({})
  state:updateFixed({})
  Assert.equal(state:status().releaseCheck.outcome, "removed", "idle ticks keep the settled result visible")
  Assert.equal(mons:partyCount(), 3)
  Assert.equal(mons:partyRevision(), afterFirst, "idle ticks never commit again")

  local rearmed, failure = pcall(function()
    state:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 2 } } })
    state:updateFixed({ { type = "action", action = "release" } })
  end)
  if not rearmed then
    state:dispose()
  end
  Assert.isTrue(rearmed, "a settled removal admits a later release: " .. tostring(failure))
  local secondArmed = state:status().releaseCheck
  Assert.equal(secondArmed.outcome, "confirm", "the later request waits for its own confirmation")
  Assert.equal(secondArmed.scanned, 0, "the later request starts a fresh scan")
  Assert.equal(secondArmed.total, 37 * 30 + 6)
  Assert.deepEqual(secondArmed.address, { kind = "party", slot = 2 })
  Assert.equal(mons:partyCount(), 3, "rearming never removes before confirmation")
  Assert.equal(mons:partyRevision(), afterFirst)
  local secondSettled, secondTicks, secondMaximum = settleArmedRelease(state)
  Assert.equal(secondSettled.outcome, "removed")
  Assert.equal(secondSettled.scanned, secondSettled.total)
  Assert.equal(mons:partyCount(), 2)
  Assert.isTrue(mons:partyRevision() ~= afterFirst, "the second removal publishes once")
  Assert.equal(secondTicks, firstTicks, "both scans cover the same candidate set in the same ticks")
  Assert.equal(secondMaximum, firstMaximum)
  local afterSecond = mons:partyRevision()
  state:updateFixed({})
  Assert.equal(state:status().releaseCheck.outcome, "removed")
  Assert.equal(mons:partyCount(), 2)
  Assert.equal(mons:partyRevision(), afterSecond, "idle ticks after the second removal never commit again")
  state:dispose()
end

function T.protected_return_leaves_later_releases_independent()
  local mons = releaseService("surf")
  mons:setMove(0, 1, "TACKLE")
  mons:setMove(0, 0, "FLY")
  mons:setMove(0, 1, "SURF")
  local factory = CatalogFixture.makeFactory(0x5EED02, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  Assert.equal(mons:partyCount(), 3)
  local protectedBefore = mons:partyMon(0)
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))

  state:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  Assert.equal(state:status().releaseCheck.outcome, "confirm")
  local returned = settleArmedRelease(state)
  Assert.equal(returned.outcome, "returned", "the protected first move returns instead of removing")
  Assert.equal(mons:partyCount(), 3, "return keeps party custody")
  Assert.deepEqual(mons:partyMon(0), protectedBefore, "return leaves the protected record untouched")
  Assert.notNil(mons:boxMon(36, 29), "return leaves the alternative holder untouched")
  local afterReturn = mons:partyRevision()

  local rearmed, failure = pcall(function()
    state:updateFixed({ { type = "release", address = { kind = "party", slot = 2 } } })
  end)
  if not rearmed then
    state:dispose()
  end
  Assert.isTrue(rearmed, "a returned request admits a later release: " .. tostring(failure))
  local fresh = state:status().releaseCheck
  Assert.equal(fresh.outcome, "confirm", "the later request waits for its own confirmation")
  Assert.equal(fresh.scanned, 0, "the later request starts a fresh scan")
  Assert.deepEqual(fresh.address, { kind = "party", slot = 2 })
  Assert.equal(mons:partyCount(), 3, "rearming never removes before confirmation")
  Assert.equal(mons:partyRevision(), afterReturn)
  local removed = settleArmedRelease(state)
  Assert.equal(removed.outcome, "removed", "the later ordinary release commits under current law")
  Assert.equal(mons:partyCount(), 2)
  Assert.deepEqual(mons:partyMon(0), protectedBefore, "the later release leaves the protected record intact")
  state:updateFixed({})
  Assert.equal(state:status().releaseCheck.outcome, "removed")
  Assert.equal(mons:partyCount(), 2, "idle ticks never replay the later release")
  state:dispose()
end

function T.concurrent_release_requests_stay_rejected_while_armed_or_scanning()
  local mons = releaseService()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  Assert.equal(state:status().releaseCheck.outcome, "confirm")
  local armedAddress = state:status().releaseCheck.address
  local armedPartyRevision = mons:partyRevision()
  local armedBoxRevision = mons:boxRevision()

  local secondMenu, secondMenuError = pcall(function()
    state:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  end)
  Assert.isFalse(secondMenu, "a second menu request never overwrites the armed decision")
  Assert.notNil(
    string.find(tostring(secondMenuError), "only one release decision may be armed", 1, true),
    "the armed overlap reports the single-decision guard"
  )
  local secondEvent, secondEventError = pcall(function()
    state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  end)
  Assert.isFalse(secondEvent, "a second mapped request never overwrites the armed decision")
  Assert.notNil(
    string.find(tostring(secondEventError), "only one release decision may be armed", 1, true),
    "both origins report the same guard while armed"
  )
  Assert.equal(state:status().releaseCheck.outcome, "confirm", "rejected overlaps keep the armed decision")
  Assert.equal(state:status().releaseCheck.scanned, 0)
  Assert.deepEqual(state:status().releaseCheck.address, armedAddress)
  Assert.equal(mons:partyCount(), 2, "rejected overlaps never remove")
  Assert.equal(mons:partyRevision(), armedPartyRevision)
  Assert.equal(mons:boxRevision(), armedBoxRevision)

  confirmReleaseYes(state)
  local pending = state:status().releaseCheck
  Assert.equal(pending.outcome, "pending")
  Assert.equal(pending.scanned, 15, "confirmation starts the scan before the overlap retry")
  local scanningPartyRevision = mons:partyRevision()
  local scanningBoxRevision = mons:boxRevision()
  local scanningMenu, scanningMenuError = pcall(function()
    state:updateFixed({ { type = "party" }, { type = "action", action = "release" } })
  end)
  Assert.isFalse(scanningMenu, "a menu request never interrupts the scanning decision")
  Assert.notNil(
    string.find(tostring(scanningMenuError), "only one release decision may be armed", 1, true),
    "the scanning overlap reports the single-decision guard"
  )
  local scanningEvent, scanningEventError = pcall(function()
    state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  end)
  Assert.isFalse(scanningEvent, "a mapped request never interrupts the scanning decision")
  Assert.notNil(
    string.find(tostring(scanningEventError), "only one release decision may be armed", 1, true),
    "both origins report the same guard while scanning"
  )
  Assert.equal(state:status().releaseCheck.outcome, "pending", "rejected overlaps keep the scan")
  Assert.equal(state:status().releaseCheck.scanned, 15, "rejected overlaps never advance the scan")
  Assert.deepEqual(state:status().releaseCheck.address, armedAddress)
  Assert.equal(mons:partyCount(), 2)
  Assert.equal(mons:partyRevision(), scanningPartyRevision)
  Assert.equal(mons:boxRevision(), scanningBoxRevision)

  local check = state:status().releaseCheck
  local maximumTicks = math.ceil(check.total / 15)
  local ticks = 1
  while check.outcome == "pending" do
    Assert.isTrue(ticks < maximumTicks, "the first scan still completes after rejected overlaps")
    state:updateFixed({})
    ticks = ticks + 1
    check = state:status().releaseCheck
  end
  acknowledgeReleaseMessages(state)
  Assert.equal(state:status().releaseCheck.outcome, "removed", "the first scan completes normally after rejection")
  Assert.equal(mons:partyCount(), 1)
  state:dispose()
end

function T.cancelled_and_stale_scans_admit_fresh_releases_without_replay()
  do
    local mons = releaseService()
    local state = PcStorageState.new(openOptions(mons, 2, "wide"))
    state:updateFixed({ { type = "party" } })
    state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
    Assert.equal(state:status().releaseCheck.outcome, "confirm")
    confirmReleaseYes(state)
    Assert.equal(state:status().releaseCheck.outcome, "pending")
    state:updateFixed({ { type = "cancel" } })
    Assert.equal(state:status().releaseCheck.outcome, "cancelled", "cancel stops the scan")
    Assert.equal(mons:partyCount(), 2, "cancel never removes")
    local afterCancel = mons:partyRevision()
    local rearmed, failure = pcall(function()
      state:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 1 } } })
      state:updateFixed({ { type = "action", action = "release" } })
    end)
    if not rearmed then
      state:dispose()
    end
    Assert.isTrue(rearmed, "a cancelled scan admits a later release: " .. tostring(failure))
    local fresh = state:status().releaseCheck
    Assert.equal(fresh.outcome, "confirm", "the retry waits for its own confirmation")
    Assert.equal(fresh.scanned, 0, "the retry starts a fresh scan")
    Assert.deepEqual(fresh.address, { kind = "party", slot = 1 })
    Assert.equal(mons:partyCount(), 2, "rearming never commits")
    Assert.equal(mons:partyRevision(), afterCancel)
    local settled = settleArmedRelease(state)
    Assert.equal(settled.outcome, "removed", "the retry commits under current law")
    Assert.equal(mons:partyCount(), 1)
    state:updateFixed({})
    Assert.equal(state:status().releaseCheck.outcome, "removed")
    Assert.equal(mons:partyCount(), 1, "idle ticks never replay the retry")
    state:dispose()
  end
  do
    local mons = releaseService()
    local state = PcStorageState.new(openOptions(mons, 2, "wide"))
    state:updateFixed({ { type = "party" } })
    state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
    Assert.equal(state:status().releaseCheck.outcome, "confirm")
    confirmReleaseYes(state)
    Assert.equal(state:status().releaseCheck.outcome, "pending")
    local drifting = mons:partyMon(1)
    drifting.heldItem = "SITRUS_BERRY"
    local preparation = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = drifting } }))
    preparation.publish()
    state:updateFixed({})
    Assert.equal(state:status().releaseCheck.outcome, "stale", "revision drift cancels the scan")
    Assert.equal(mons:partyCount(), 2, "stale scan retains the selected mon")
    Assert.notNil(mons:boxMon(36, 29), "stale scan leaves the expanded-box mon untouched")
    local rearmed, failure = pcall(function()
      state:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 1 } } })
      state:updateFixed({ { type = "action", action = "release" } })
    end)
    if not rearmed then
      state:dispose()
    end
    Assert.isTrue(rearmed, "a stale scan admits a later release: " .. tostring(failure))
    local fresh = state:status().releaseCheck
    Assert.equal(fresh.outcome, "confirm", "the retry waits for its own confirmation")
    Assert.equal(fresh.scanned, 0, "the retry starts a fresh scan")
    Assert.deepEqual(fresh.address, { kind = "party", slot = 1 })
    Assert.equal(mons:partyCount(), 2, "rearming never commits")
    local settled = settleArmedRelease(state)
    Assert.equal(settled.outcome, "removed", "the retry commits under the current revisions")
    Assert.equal(mons:partyCount(), 1)
    state:updateFixed({})
    Assert.equal(state:status().releaseCheck.outcome, "removed")
    Assert.equal(mons:partyCount(), 1, "idle ticks never replay the retry")
    state:dispose()
  end
end

function T.idle_ticks_reuse_the_published_view_and_plan()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  local builds, resolves = 0, 0
  local buildView = PcStorageState._buildView
  state._buildView = function(self)
    builds = builds + 1
    return buildView(self)
  end
  local resolve = state._session.resolve
  state._session.resolve = function(self, measurement, view)
    resolves = resolves + 1
    return resolve(self, measurement, view)
  end
  state:updateFixed({})
  Assert.equal(builds, 0, "a stable idle tick reuses the published contents instead of projecting icons again")
  Assert.equal(resolves, 0, "a stable idle tick reuses the published layout instead of resolving again")
  state:updateFixed({})
  Assert.equal(builds, 0, "a second idle tick still projects nothing new")
  Assert.equal(resolves, 0, "a second idle tick still resolves nothing new")
  local status = state:status()
  Assert.equal(status.activeBox, 0)
  Assert.equal(status.phase, "browse")
  Assert.deepEqual(status.focus, { domain = "party", slot = 0 })
  Assert.equal(status.boxName, "BOX 1")
  Assert.equal(#status.boxSlots, 30, "the reused projection still covers all thirty box positions")
  Assert.equal(status.transitionTick, 2, "the transition clock still advances while the layout is reused")
  status.boxSlots[1] = false
  local afterTamper = state:status()
  Assert.equal(#afterTamper.boxSlots, 30, "tampering with a published status never shrinks the next view")
  state:dispose()
end

function T.state_changes_publish_once_while_idle_ticks_reuse_the_layout()
  for _, configuration in ipairs({ "nativeLike", "wide", "dualDisplay" }) do
    local mons = monService()
    local seeded = assert(mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 3, mon = mons:partyMon(0) } } }))
    seeded.publish()
    local state = PcStorageState.new(openOptions(mons, 1, configuration))
    local builds, resolves = 0, 0
    local buildView = PcStorageState._buildView
    state._buildView = function(self)
      builds = builds + 1
      return buildView(self)
    end
    local resolve = state._session.resolve
    state._session.resolve = function(self, measurement, view)
      resolves = resolves + 1
      return resolve(self, measurement, view)
    end
    state:updateFixed({ { type = "storage_target", target = { kind = "box", slot = 3 } } })
    Assert.equal(builds, 1, configuration .. ": a focus tick maps against the pre-input layout and publishes once")
    Assert.equal(resolves, 1, configuration .. ": a focus tick resolves once instead of twice")
    Assert.deepEqual(state:status().focus, { domain = "box", slot = 3 })
    local settledBuilds, settledResolves = builds, resolves
    state:updateFixed({})
    Assert.equal(builds, settledBuilds, configuration .. ": an idle tick projects nothing new")
    Assert.equal(resolves, settledResolves, configuration .. ": an idle tick resolves nothing new")
    local menuBuilds, menuResolves = builds, resolves
    state:updateFixed({ { type = "confirm" } })
    Assert.equal(builds, menuBuilds + 1, configuration .. ": opening the menu publishes once")
    Assert.equal(resolves, menuResolves + 1, configuration .. ": opening the menu resolves once")
    Assert.equal(state:status().phase, "menu")
    local unmenuBuilds = builds
    state:updateFixed({ { type = "cancel" } })
    Assert.equal(builds, unmenuBuilds + 1, configuration .. ": cancelling the menu publishes once")
    Assert.equal(state:status().phase, "browse")
    local partyCount = mons:partyCount()
    state:updateFixed({ { type = "action", action = "move" } })
    Assert.equal(state:status().phase, "carry")
    local carriedBuilds, carriedResolves = builds, resolves
    state:updateFixed({})
    Assert.equal(builds, carriedBuilds, configuration .. ": a carry idle tick projects nothing")
    Assert.equal(resolves, carriedResolves, configuration .. ": a carry idle tick resolves nothing")
    Assert.equal(state:status().phase, "carry", "an idle tick never drops or commits the carry")
    Assert.equal(mons:partyCount(), partyCount, "an idle tick never moves domain custody")
    state:updateFixed({ { type = "cancel" } })
    Assert.equal(state:status().phase, "browse")
    local factory = CatalogFixture.makeFactory(0xD03F01, mons:catalog())
    local newcomer = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
    local drifted = assert(mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 6, mon = newcomer } } }))
    drifted.publish()
    local driftBuilds, driftResolves = builds, resolves
    state:updateFixed({})
    Assert.equal(builds, driftBuilds + 1, configuration .. ": external drift rebuilds once before mapping")
    Assert.equal(resolves, driftResolves + 1, configuration .. ": external drift resolves once before mapping")
    Assert.equal(
      assert(state:status().boxSlots[7]).personality,
      newcomer.personality,
      "drifted contents reach the published view"
    )
    Assert.deepEqual(state:status().focus, { domain = "box", slot = 3 }, "content refresh leaves focus alone")
    local switchedBuilds, switchedResolves = builds, resolves
    state:updateFixed({ { type = "navigate", direction = "up" } })
    state:updateFixed({ { type = "navigate", direction = "right" } })
    Assert.equal(builds, switchedBuilds + 2, configuration .. ": reaching the title and switching publishes each step")
    Assert.equal(resolves, switchedResolves + 2, configuration .. ": the title step and switch each resolve once")
    Assert.equal(state:status().activeBox, 1)
    Assert.equal(state:status().boxSlots[7], false, "the new box shows its own empty slot, not stale contents")
    Assert.deepEqual(state:status().focus, { domain = "box", slot = 0 })
    state:updateFixed({ { type = "navigate", direction = "left" } })
    state:updateFixed({ { type = "storage_target", target = { kind = "box", slot = 3 } } })
    state:updateFixed({ { type = "confirm" } })
    Assert.equal(state:status().phase, "menu")
    local beforeMarkings = mons:boxMon(0, 3).markings
    state:updateFixed({ { type = "action", action = "markings" } })
    Assert.equal(state:status().phase, "editor")
    local draftMask = state:status().editor.mask
    local editorBuilds, editorResolves = builds, resolves
    state:updateFixed({})
    Assert.equal(builds, editorBuilds, configuration .. ": an idle editor tick projects nothing")
    Assert.equal(resolves, editorResolves, configuration .. ": an idle editor tick resolves nothing")
    Assert.equal(state:status().phase, "editor", "an idle editor tick keeps the draft")
    Assert.equal(state:status().editor.mask, draftMask)
    state:updateFixed({ { type = "cancel" } })
    Assert.equal(state:status().phase, "browse")
    Assert.equal(mons:boxMon(0, 3).markings, beforeMarkings, "cancel discards the editor draft")
    local hit = assert(state._session:plan().content.hitRegions.boxSlots[1])
    local x, y = hostPointForRect(state, hit.rect)
    state:updateFixed({ { type = "pointer_down", pointerId = "republish-touch", x = x, y = y } })
    Assert.deepEqual(state:status().focus, { domain = "box", slot = 0 })
    state:cancelPointerCapture()
    state:updateFixed({ { type = "pointer_up", pointerId = "republish-touch", x = x, y = y } })
    Assert.deepEqual(state:status().focus, { domain = "box", slot = 0 }, "the stale release activates nothing")
    state:dispose()
  end
end

function T.mixed_batch_opening_a_child_defers_trailing_input_to_the_child()
  local mons = monService()
  local disposed = 0
  local batches = {}
  local cancelled = false
  local options = openOptions(mons, 2, "wide")
  options.childFactories = {
    summary = function()
      return {
        updateFixed = function(_, events)
          batches[#batches + 1] = events
          for _, event in ipairs(events) do
            if event.type == "cancel" then
              cancelled = true
            end
          end
        end,
        result = function()
          if cancelled then
            cancelled = false
            return { kind = "cancel" }
          end
          return nil
        end,
        dispose = function()
          disposed = disposed + 1
        end,
      }
    end,
  }
  local state = PcStorageState.new(options)
  -- One ordered batch opens the nested summary and carries a trailing
  -- cancel. A single owner consumes the batch: the opener wins and the
  -- trailing input waits for the child's own tick.
  state:updateFixed({ { type = "action", action = "summary" }, { type = "cancel" } })
  Assert.equal(state:status().phase, "child")
  Assert.equal(state:status().childKind, "summary")
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 0 })
  Assert.equal(#batches, 0, "the newly opened child sees nothing from the opening batch")
  Assert.isNil(state:_view().message, "the trailing cancel never becomes a parent exit prompt")
  -- The next tick belongs to the child alone: it observes the deferred
  -- cancel while parent focus, box and mode stay untouched.
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(#batches, 1, "the deferred input reaches the child exactly once")
  Assert.deepEqual(batches[1], { { type = "cancel" } })
  Assert.equal(state:status().phase, "browse", "the child's cancel returns to browsing")
  Assert.equal(state:status().mode, 2)
  Assert.equal(state:status().activeBox, 0)
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 0 })
  Assert.equal(disposed, 1, "the returned child is disposed exactly once")
  state:dispose()
end

function T.confirmed_release_advances_fifteen_addresses_once_per_tick_and_holds_the_transition_clock_on_confirmation()
  local mons = releaseService()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  local armed = state:status().releaseCheck
  Assert.equal(armed.outcome, "confirm")
  Assert.equal(armed.scanned, 0)
  Assert.equal(armed.total, 37 * 30 + 6)
  state:updateFixed({ { type = "navigate", direction = "up" } })
  local armedTick = state:status().transitionTick
  state:updateFixed({ { type = "confirm" } })
  local pending = state:status().releaseCheck
  Assert.equal(pending.outcome, "pending")
  Assert.equal(pending.scanned, 15, "confirmation advances exactly one fifteen-address slice")
  Assert.equal(
    state:status().transitionTick,
    armedTick,
    "the confirmation tick advances the scan instead of the transition clock"
  )
  state:updateFixed({})
  local advanced = state:status().releaseCheck
  Assert.equal(advanced.outcome, "pending")
  Assert.equal(advanced.scanned, 30, "each following tick advances exactly one more slice")
  Assert.equal(state:status().transitionTick, armedTick + 1)
  local check = advanced
  local maximumTicks = math.ceil(check.total / 15)
  local ticks = 2
  while check.outcome == "pending" do
    Assert.isTrue(ticks < maximumTicks, "the scan completes within the candidate count")
    state:updateFixed({})
    ticks = ticks + 1
    check = state:status().releaseCheck
  end
  Assert.equal(check.outcome, "released", "the shrink and scan end before the mon is removed")
  Assert.equal(check.scanned, check.total, "the scan covers every candidate address")
  Assert.equal(mons:partyCount(), 2, "the mon waits in custody behind the release messages")
  acknowledgeReleaseMessages(state)
  Assert.equal(state:status().releaseCheck.outcome, "removed")
  Assert.equal(mons:partyCount(), 1, "the confirmed release commits exactly once")
  local afterRevision = mons:partyRevision()
  state:updateFixed({})
  Assert.equal(state:status().releaseCheck.outcome, "removed", "idle ticks keep the settled result visible")
  Assert.equal(mons:partyCount(), 1)
  Assert.equal(mons:partyRevision(), afterRevision, "idle ticks never commit again")
  state:dispose()
end

function T.editor_opening_mid_batch_keeps_trailing_cancel_from_the_parent_prompt()
  local mons = monService()
  local seeded = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = mons:partyMon(0) } } }))
  seeded.publish()
  local beforeMarkings = assert(mons:boxMon(0, 0)).markings
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  -- One ordered batch opens the markings editor and carries a trailing
  -- cancel. The editor owns the next tick, so the trailing cancel never
  -- becomes a parent continue prompt underneath it.
  state:updateFixed({ { type = "action", action = "markings" }, { type = "cancel" } })
  Assert.equal(state:status().phase, "editor")
  Assert.equal(state:status().editor.kind, "markings")
  Assert.equal(state:_view().message.id, 35, "the trailing cancel never prompts under the open editor")
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 0 })
  -- The next tick belongs to the editor alone: it discards its draft while
  -- the box record stays untouched and no prompt appears.
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(state:status().phase, "browse")
  Assert.equal(assert(mons:boxMon(0, 0)).markings, beforeMarkings)
  Assert.equal(state:_view().message.id, 18, "the browse prompt returns with no continue prompt queued")
  state:dispose()
end

-- The published visual snapshot rides the transient status for the
-- admission boundary: status carries the exact same view object the next
-- draw consumes, with the live wallpaper, tray, and mode selectors.
function T.status_publishes_the_exact_drawn_visual_snapshot()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  local status = state:status()
  local published = state:_ensurePublished()
  Assert.isTrue(status.visualView == published, "status carries the exact published view drawn later")
  Assert.equal(status.visualView.wallpaperId, published.wallpaperId, "the snapshot carries the active wallpaper")
  Assert.equal(status.visualView.tray, published.tray, "the snapshot carries the tray pose")
  Assert.equal(status.visualView.mode, published.mode, "the snapshot carries the retail mode")
  Assert.isNil(status.bagChildStatus, "browsing publishes no picker leaf")
  state:updateFixed({})
  Assert.isTrue(state:status().visualView == published, "an idle tick reuses its published snapshot")
  state:dispose()
end

-- The held-item picker leaf rides alongside the status for the shared Bag
-- preparation path: the live child leaf is the exact object the picker
-- reports, while the parent snapshot stays published underneath it.
function T.held_item_picker_status_rides_alongside_for_bag_preparation()
  local mons = monService()
  local held = mons:partyMon(0)
  held.heldItem = "POTION"
  assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = held } })).publish()
  local bagLeaf = { presentation = { inputKey = "bag" } }
  local options = openOptions(mons, 2, "wide")
  options.childFactories = {
    heldItemPicker = function()
      return {
        updateFixed = function() end,
        takeIntent = function() end,
        status = function()
          return bagLeaf
        end,
        dispose = function() end,
      }
    end,
  }
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "party" } })
  state:updateFixed({ { type = "action", action = "heldItems" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(mons:partyMon(0).heldItem, "NONE", "a held item is taken back to the Bag")
  state:updateFixed({ { type = "action", action = "heldItems" } })
  Assert.equal(state:status().childKind, "heldItemPicker", "an empty hand opens the Bag picker")
  local status = state:status()
  Assert.isTrue(status.bagChildStatus == bagLeaf, "status carries the live picker leaf for preparation")
  Assert.isTrue(status.visualView == state:_ensurePublished(), "the picker still rides its published snapshot")
  state:dispose()
end

-- Draw-gate coverage below: the Storage child keeps painting its last
-- admitted parent view while a replacement waits, and only an admitted
-- parent may draw while the host readiness stays false. The helpers stage
-- visuals through the real renderer behind a delayable image owner; the
-- readiness flag travels the way the host passes it to child draw/plan.
local function stateImageOwner()
  local inner = require("tests.support.SharedImagePoolFake").new()
  local pendingPaths = {}
  local tokenPaths = {}
  local pool = {}
  function pool:request(path, sampler, priority)
    local token = inner:request(path, sampler, priority)
    tokenPaths[token] = path
    return token
  end
  function pool:poll(token)
    if pendingPaths[tokenPaths[token]] then
      return "pending"
    end
    return inner:poll(token)
  end
  function pool:acquire(token)
    return inner:acquire(token)
  end
  function pool:release(lease)
    return inner:release(lease)
  end
  function pool:cancel(token)
    tokenPaths[token] = nil
    return inner:cancel(token)
  end
  function pool:prune()
    return inner:prune()
  end
  function pool:stats()
    return inner:stats()
  end
  return pool, inner, pendingPaths
end

local function stateVisualPaths(manifest)
  local storage = manifest.storage
  local all = {
    storage.backgrounds.default,
    storage.ui.boxPane,
    storage.ui.infoPane,
    storage.ui.partyTray,
    storage.ui.partyTrayMove,
    storage.ui.markingPanel,
    storage.ui.wallpaperBar,
    storage.ui.arrows.left,
    storage.ui.arrows.right,
  }
  for _, pose in pairs(storage.ui.cursors) do
    for _, frame in ipairs(pose.frames) do
      all[#all + 1] = frame
    end
  end
  all[#all + 1] = storage.ui.infoGlyphs.lv
  all[#all + 1] = storage.ui.infoGlyphs.no
  for _, key in ipairs({ "yesNormal", "yesSelected", "noNormal", "noSelected" }) do
    all[#all + 1] = storage.ui.yesNo[key]
  end
  for _, visual in pairs(storage.wallpapers) do
    all[#all + 1] = visual
  end
  for _, set in ipairs({ storage.ui.markings, storage.ui.panelMarkings }) do
    for _, pair in pairs(set) do
      all[#all + 1] = pair.clear
      all[#all + 1] = pair.set
    end
  end
  for _, plate in pairs(storage.ui.plates) do
    all[#all + 1] = plate.left
    all[#all + 1] = plate.middle
    all[#all + 1] = plate.right
  end
  for _, style in pairs(storage.ui.windowFrames) do
    if type(style) == "table" and style.image == nil then
      for _, visual in pairs(style) do
        if type(visual) == "table" and type(visual.image) == "string" then
          all[#all + 1] = visual
        end
      end
    end
  end
  return all
end

local function stateRenderer(pool)
  local manifest = PcPresentationFixture.manifest()
  manifest.text = { banks = { [24] = {}, [25] = {} } }
  for bankId, bank in pairs(manifest.text.banks) do
    for messageId = 0, 100 do
      bank[messageId] = { { kind = "glyph", text = "b" .. bankId .. ":" .. messageId } }
    end
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local image = PngWriter.encode(1, 1, string.char(255, 255, 255, 255))
  for _, visual in ipairs(stateVisualPaths(manifest)) do
    cache:write(visual.image, image)
  end
  local graphics = FakeGraphics.new({})
  local text = {
    drawText = function() end,
    drawTextWithColorVariant = function() end,
    textWidth = function()
      return 0
    end,
    windowBackgroundColor = function()
      return { 1, 1, 1, 1 }
    end,
  }
  local renderer = PcStorageRenderer.new({
    graphics = graphics,
    cacheFs = cache,
    manifest = manifest,
    text = text,
    imagePool = pool,
  })
  return renderer, graphics, manifest
end

local function stateResources(renderer)
  -- The ready-picker draw route requires its production collaborators;
  -- this fake picker surface ignores them, so plain stubs stand in.
  return {
    storageRenderer = renderer,
    bagRenderer = {},
    heroRenderer = {},
    itemIcons = {},
    textRenderer = {},
    windowRenderer = {
      drawWindow = function() end,
      drawStandardWindow = function() end,
    },
    applicationFrameIndex = 3,
  }
end

-- Finishes a staged visual group once every other prerequisite for the
-- same view is ready; absent until the renderer stages separately from
-- publishing, when this becomes the explicit commit.
local function settleStateView(renderer, view)
  if type(renderer.commitPrepared) == "function" then
    renderer:commitPrepared(view)
  end
end

local function admitStateView(renderer, view)
  local ready, failure = false, nil
  for _ = 1, 200 do
    ready, failure = renderer:prepare(view)
    if ready then
      break
    end
    Assert.isNil(failure, "admission reports no failure while pending")
  end
  Assert.isTrue(ready, "the view admits before drawing")
  Assert.isNil(failure, "admission reports no failure")
  settleStateView(renderer, view)
end

-- Records the admitted parent once the host turns ready; absent until the
-- child owns its last admitted snapshot, when this becomes the narrow
-- admission recording reconciled with the host cutover.
local function recordAdmittedParent(state)
  if type(state.admitParentPresentation) == "function" then
    state:admitParentPresentation()
  end
end

local function scopeStateLove(graphics)
  local savedLove = rawget(_G, "love")
  local scopedLove = {}
  for key, value in pairs(savedLove) do
    scopedLove[key] = value
  end
  scopedLove.graphics = graphics
  rawset(_G, "love", scopedLove)
  return savedLove
end

local function drawsStateImageSince(graphics, mark, image)
  for index = mark + 1, #graphics.draws do
    if graphics.draws[index].image == image then
      return true
    end
  end
  return false
end

local function switchWallpaper(state, wallpaperId)
  state:updateFixed({ { type = "action", action = "wallpaper" } })
  state:updateFixed({ { type = "wallpaper_choice", id = wallpaperId } })
  state:updateFixed({ { type = "submit" } })
end

function T.unready_first_open_draws_nothing_and_reports_no_plan()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  local pool, _, _ = stateImageOwner()
  local renderer, graphics, _ = stateRenderer(pool)
  admitStateView(renderer, state:status().visualView)
  local resources = stateResources(renderer)
  local savedLove = scopeStateLove(graphics)
  local ok, err = pcall(function()
    local drew, drawFailure = pcall(function()
      state:draw(resources, false)
    end)
    Assert.isTrue(drew, "an unadmitted open never fails its draw: " .. tostring(drawFailure))
    Assert.equal(#graphics.draws, 0, "an unadmitted open paints no surface")
    Assert.isNil(state:presentationPlan(false), "an unadmitted open publishes no plan")
    state:dispose()
    renderer:dispose()
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.pending_replacement_draws_the_admitted_parent_instead_of_the_current_view()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  local pool, inner, pendingPaths = stateImageOwner()
  local renderer, graphics, manifest = stateRenderer(pool)
  admitStateView(renderer, state:status().visualView)
  recordAdmittedParent(state)
  local admittedPlan = state:presentationPlan()
  Assert.notNil(admittedPlan, "admission publishes its plan")
  local oldWallpaper = manifest.storage.wallpapers[0].image
  local newWallpaper = manifest.storage.wallpapers[2].image
  local oldImage = assert(renderer._images[oldWallpaper], "admission installs its wallpaper")
  local resources = stateResources(renderer)
  local savedLove = scopeStateLove(graphics)
  local ok, err = pcall(function()
    pendingPaths[newWallpaper] = true
    switchWallpaper(state, 2)
    Assert.equal(state:status().visualView.wallpaperId, 2, "the desired view advances past admission")
    for _ = 1, 3 do
      local ready, failure = renderer:prepare(state:status().visualView)
      Assert.isFalse(ready, "the replacement stays pending")
      Assert.isNil(failure, "the replacement reports no failure")
    end
    local drew, drawFailure = pcall(function()
      state:draw(resources, false)
    end)
    Assert.isTrue(drew, "a pending draw keeps the admitted parent drawable: " .. tostring(drawFailure))
    local drawsBefore = #graphics.draws
    state:draw(resources, false)
    Assert.isTrue(
      drawsStateImageSince(graphics, drawsBefore, oldImage),
      "a pending draw paints the admitted wallpaper, not the desired one"
    )
    Assert.isTrue(state:presentationPlan(false) == admittedPlan, "a pending plan stays the admitted one")
    pendingPaths[newWallpaper] = nil
    admitStateView(renderer, state:status().visualView)
    drawsBefore = #graphics.draws
    state:draw(resources, true)
    local newImage = assert(renderer._images[newWallpaper], "admission installs the new wallpaper")
    Assert.isTrue(drawsStateImageSince(graphics, drawsBefore, newImage), "an admitted draw paints the new wallpaper")
    Assert.isTrue(inner:stats().outstandingLeases > 0, "admission holds its leases")
    state:dispose()
    renderer:dispose()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.pending_picker_draws_the_admitted_parent()
  local mons = monService()
  local options = openOptions(mons, 3, "wide")
  Assert.isTrue(options.bag:add("POTION", 1))
  local pickerStatus = {}
  options.childFactories.heldItemPicker = function()
    return {
      updateFixed = function() end,
      takeIntent = function()
        return nil
      end,
      takeResult = function()
        return nil
      end,
      status = function()
        return pickerStatus
      end,
      dispose = function() end,
    }
  end
  local state = PcStorageState.new(options)
  local pool, inner, _ = stateImageOwner()
  local renderer, graphics, manifest = stateRenderer(pool)
  admitStateView(renderer, state:status().visualView)
  recordAdmittedParent(state)
  local admittedPlan = state:presentationPlan()
  Assert.notNil(admittedPlan, "admission publishes its plan")
  local oldImage = assert(renderer._images[manifest.storage.wallpapers[0].image], "admission installs its wallpaper")
  local resources = stateResources(renderer)
  local savedLove = scopeStateLove(graphics)
  local ok, err = pcall(function()
    state:updateFixed({ { type = "action", action = "giveItem" } })
    Assert.equal(state:status().childKind, "heldItemPicker", "Give Item opens the picker")
    local drew, drawFailure = pcall(function()
      state:draw(resources, false)
    end)
    Assert.isTrue(drew, "a pending picker keeps its draw safe: " .. tostring(drawFailure))
    local drawsBefore = #graphics.draws
    state:draw(resources, false)
    Assert.isTrue(
      drawsStateImageSince(graphics, drawsBefore, oldImage),
      "a pending picker falls back to the admitted parent"
    )
    Assert.isTrue(state:presentationPlan(false) == admittedPlan, "a pending picker keeps the admitted plan")
    local pickerDraws = 0
    pickerStatus = {
      presentation = {
        render = function()
          pickerDraws = pickerDraws + 1
        end,
      },
    }
    state:draw(resources, true)
    Assert.equal(pickerDraws, 1, "a ready picker draws its own surface")
    state:dispose()
    renderer:dispose()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.failed_replacement_surfaces_its_cause_and_keeps_the_admitted_parent()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  local pool, inner, _ = stateImageOwner()
  local renderer, graphics, manifest = stateRenderer(pool)
  admitStateView(renderer, state:status().visualView)
  recordAdmittedParent(state)
  local oldImage = assert(renderer._images[manifest.storage.wallpapers[0].image], "admission installs its wallpaper")
  local missing = manifest.storage.wallpapers[2].image
  inner:failAfterUploads(inner.uploads, "injected wallpaper failure")
  local resources = stateResources(renderer)
  local savedLove = scopeStateLove(graphics)
  local ok, err = pcall(function()
    switchWallpaper(state, 2)
    local ready, failure = renderer:prepare(state:status().visualView)
    Assert.isFalse(ready, "a failed wallpaper never reports ready")
    Assert.isTrue(
      type(failure) == "string" and failure:find(missing, 1, true) ~= nil,
      "the failure names its missing visual"
    )
    inner:clearFailure()
    local drew, drawFailure = pcall(function()
      state:draw(resources, false)
    end)
    Assert.isTrue(drew, "a failed replacement keeps its draw safe: " .. tostring(drawFailure))
    local drawsBefore = #graphics.draws
    state:draw(resources, false)
    Assert.isTrue(
      drawsStateImageSince(graphics, drawsBefore, oldImage),
      "a failed replacement keeps painting the admitted wallpaper"
    )
    admitStateView(renderer, state:status().visualView)
    drawsBefore = #graphics.draws
    state:draw(resources, true)
    local newImage = assert(renderer._images[missing], "recovery installs the new wallpaper")
    Assert.isTrue(drawsStateImageSince(graphics, drawsBefore, newImage), "recovery paints the new wallpaper")
    state:dispose()
    renderer:dispose()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.superseded_replacement_keeps_the_admitted_parent_until_the_last_view_admits()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  local pool, inner, pendingPaths = stateImageOwner()
  local renderer, graphics, manifest = stateRenderer(pool)
  admitStateView(renderer, state:status().visualView)
  recordAdmittedParent(state)
  local admittedPlan = state:presentationPlan()
  local oldImage = assert(renderer._images[manifest.storage.wallpapers[0].image], "admission installs its wallpaper")
  local uploadsAfterFirst = inner.uploads
  local resources = stateResources(renderer)
  local savedLove = scopeStateLove(graphics)
  local ok, err = pcall(function()
    pendingPaths[manifest.storage.wallpapers[1].image] = true
    pendingPaths[manifest.storage.wallpapers[2].image] = true
    switchWallpaper(state, 1)
    local ready, failure = renderer:prepare(state:status().visualView)
    Assert.isFalse(ready, "the first replacement stays pending")
    Assert.isNil(failure, "the first replacement reports no failure")
    switchWallpaper(state, 2)
    for _ = 1, 3 do
      ready, failure = renderer:prepare(state:status().visualView)
      Assert.isFalse(ready, "the superseding replacement stays pending")
      Assert.isNil(failure, "the superseding replacement reports no failure")
    end
    Assert.equal(inner.uploads, uploadsAfterFirst, "superseded staging uploads no pixels")
    local drew, drawFailure = pcall(function()
      state:draw(resources, false)
    end)
    Assert.isTrue(drew, "a superseded draw keeps the admitted parent drawable: " .. tostring(drawFailure))
    local drawsBefore = #graphics.draws
    state:draw(resources, false)
    Assert.isTrue(
      drawsStateImageSince(graphics, drawsBefore, oldImage),
      "a superseded draw paints the admitted wallpaper"
    )
    Assert.isTrue(state:presentationPlan(false) == admittedPlan, "a superseded plan stays the admitted one")
    pendingPaths[manifest.storage.wallpapers[2].image] = nil
    admitStateView(renderer, state:status().visualView)
    Assert.equal(inner.uploads, uploadsAfterFirst + 1, "only the last wallpaper uploads")
    drawsBefore = #graphics.draws
    state:draw(resources, true)
    local newImage =
      assert(renderer._images[manifest.storage.wallpapers[2].image], "admission installs the last wallpaper")
    Assert.isTrue(drawsStateImageSince(graphics, drawsBefore, newImage), "an admitted draw paints the last wallpaper")
    state:dispose()
    renderer:dispose()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.admitted_view_in_status_is_transient_and_read_only()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  Assert.isNil(state:status().admittedParentView, "no view is admitted before first presentation")
  local pool, inner, _ = stateImageOwner()
  local renderer, _, _ = stateRenderer(pool)
  admitStateView(renderer, state:status().visualView)
  recordAdmittedParent(state)
  local admitted = state:status().admittedParentView
  Assert.notNil(admitted, "admission exposes its parent view")
  Assert.isTrue(admitted == state:status().visualView, "the first admission matches the presented view")
  switchWallpaper(state, 2)
  local advanced = state:status()
  Assert.equal(advanced.visualView.wallpaperId, 2, "the desired view advances past admission")
  Assert.notNil(advanced.admittedParentView, "the admitted parent survives desired advances")
  Assert.equal(advanced.admittedParentView.wallpaperId, 0, "the admitted parent stays behind the desired view")
  advanced.admittedParentView = nil
  Assert.notNil(state:status().admittedParentView, "the admitted reference survives caller mutation")
  state:dispose()
  renderer:dispose()
  Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
end

function T.retained_parent_plan_reflows_to_the_current_display_without_moving_input()
  local mons = monService()
  local options = openOptions(mons, 1, "wide")
  local current = measurement("wide")
  options.measureDisplay = function()
    return current
  end
  local state = PcStorageState.new(options)
  local StorageInterface = require("game.hgss.src.pc.StorageInterface")
  local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
  local function referencePlan(view, measurement)
    local session = ApplicationPresentation.new(StorageInterface.defaults(options.manifest))
    local plan = session:resolve(measurement, view)
    session:dispose()
    return plan
  end
  local function assertFollowsCurrentTopology(plan, view, measurement, what)
    local expected = referencePlan(view, measurement)
    Assert.equal(#plan.panes, #expected.panes, what .. " keeps the current pane count")
    Assert.equal(#plan.frames, #expected.frames, what .. " keeps the current frame count")
    Assert.equal(plan.inputKey, expected.inputKey, what .. " keeps the current input key")
    for index, pane in ipairs(plan.panes) do
      local other = expected.panes[index]
      Assert.equal(pane.id, other.id, what .. " keeps the current pane order")
      Assert.equal(pane.interactive, other.interactive, what .. " keeps pane interaction")
      local frame, otherFrame = pane.placement.frame, other.placement.frame
      Assert.deepEqual(
        { frame.x, frame.y, frame.width, frame.height },
        { otherFrame.x, otherFrame.y, otherFrame.width, otherFrame.height },
        what .. " follows the current pane placement"
      )
    end
  end

  state:status()
  recordAdmittedParent(state)
  local admittedView = assert(state:status().admittedParentView, "the first admission records its parent view")
  local widePlan = assert(state:presentationPlan(false), "admission publishes its parent plan")

  -- Desired state advances while the parent lags: the live snapshot moves
  -- on, the admitted pair stays behind.
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 6 }, "down moves one grid row")
  Assert.isTrue(state:status().admittedParentView == admittedView, "desired advances keep the admitted view")

  -- A tall display reflows the retained parent geometry without touching
  -- the live input session or its content.
  current = measurement("tall")
  local advanced = state:status()
  Assert.isTrue(advanced.admittedParentView == admittedView, "the resize keeps the admitted semantic view by identity")
  Assert.deepEqual(advanced.focus, { domain = "box", slot = 6 }, "the resize keeps live focus")
  local tallPlan = assert(state:presentationPlan(false), "the resize keeps a parent plan")
  Assert.isTrue(tallPlan ~= widePlan, "the resize replaces the stale parent plan")
  assertFollowsCurrentTopology(tallPlan, admittedView, current, "the reflowed parent")
  Assert.isTrue(tallPlan ~= state._session:plan(), "the parent plan stays separate from the live input plan")
  local steady = state:status()
  Assert.isTrue(state:presentationPlan(false) == tallPlan, "a steady tall signature keeps the identical parent plan")
  Assert.isTrue(steady.visualView ~= admittedView, "the live snapshot stays ahead of admission")

  -- A held press keeps its existing cancellation rule: the stale release
  -- is dropped and never activates another target.
  local held = assert(state._session:plan().content.hitRegions.boxSlots[3])
  local x, y = hostPointForRect(state, held.rect)
  state:updateFixed({ { type = "pointer_down", pointerId = "held-press", x = x, y = y } })
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 2 })
  current = measurement("wide")
  state:status()
  local wideAgain = assert(state:presentationPlan(false), "the return keeps a parent plan")
  assertFollowsCurrentTopology(wideAgain, admittedView, current, "the returned parent")
  state:updateFixed({ { type = "pointer_up", pointerId = "held-press", x = x, y = y } })
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 2 }, "the stale release activates nothing")

  -- Fresh presses in the current topology still map through the live
  -- session to the correct target.
  local fresh = assert(state._session:plan().content.hitRegions.boxSlots[6])
  local fx, fy = hostPointForRect(state, fresh.rect)
  state:updateFixed({
    { type = "pointer_down", pointerId = "fresh-press", x = fx, y = fy },
    { type = "pointer_up", pointerId = "fresh-press", x = fx, y = fy },
  })
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 5 })

  -- Admitting the current view cuts over, and the next pending
  -- replacement falls back to the newly admitted pair, not the older one.
  recordAdmittedParent(state)
  local cutoverView = assert(state:status().admittedParentView, "the cutover records its view")
  Assert.isTrue(cutoverView ~= admittedView, "the cutover advances past the older parent")
  Assert.isTrue(state:presentationPlan(false) == state._session:plan(), "the cutover serves the current live plan")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  current = measurement("tall")
  state:status()
  Assert.isTrue(state:status().admittedParentView == cutoverView, "the next stall keeps the newly admitted view")
  assertFollowsCurrentTopology(
    assert(state:presentationPlan(false), "the next stall keeps a parent plan"),
    cutoverView,
    current,
    "the next fallback"
  )
  state:dispose()
  state:dispose()
  Assert.isFalse(state:isActive(), "disposal closes the screen exactly once")
end

function T.unavailable_display_hides_the_retained_parent_without_changing_content()
  local mons = monService()
  local options = openOptions(mons, 3, "wide")
  Assert.isTrue(options.bag:add("POTION", 1))
  options.childFactories.heldItemPicker = function()
    return {
      updateFixed = function() end,
      takeIntent = function()
        return nil
      end,
      takeResult = function()
        return nil
      end,
      status = function()
        return {}
      end,
      dispose = function() end,
    }
  end
  local current = measurement("wide")
  options.measureDisplay = function()
    return current
  end
  local state = PcStorageState.new(options)
  local pool, inner, _ = stateImageOwner()
  local renderer, graphics, manifest = stateRenderer(pool)
  admitStateView(renderer, state:status().visualView)
  recordAdmittedParent(state)
  local admittedView = assert(state:status().admittedParentView, "the first admission records its parent view")
  local oldImage = assert(renderer._images[manifest.storage.wallpapers[0].image], "admission installs its wallpaper")
  local resources = stateResources(renderer)
  local savedLove = scopeStateLove(graphics)
  local ok, err = pcall(function()
    state:updateFixed({ { type = "action", action = "giveItem" } })
    Assert.equal(state:status().childKind, "heldItemPicker", "Give Item opens the picker")
    recordAdmittedParent(state)
    Assert.isTrue(
      state:status().admittedParentView == admittedView,
      "a pending picker never overwrites the admitted parent"
    )

    -- A display with no drawable Storage placement publishes the inactive
    -- plan instead of reusing the old wide rectangles.
    current = {
      width = 256,
      height = 192,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = true,
        occupiedRegions = { { x = 0, y = 0, width = 256, height = 192 } },
      }),
      pixelRatio = 1,
      signature = "pc-storage-test:blocked",
    }
    local blocked = state:status()
    Assert.equal(blocked.childKind, "heldItemPicker", "the blocked display keeps the pending picker")
    Assert.isTrue(blocked.admittedParentView == admittedView, "the blocked display keeps the admitted semantic view")
    local inactive = assert(state:presentationPlan(false), "the blocked display keeps a parent plan")
    Assert.equal(#inactive.panes, 0, "an unavailable display publishes no panes")
    Assert.equal(#inactive.frames, 0, "an unavailable display publishes no outer frames")
    Assert.equal(inactive.inputKey, "pc-storage-inactive", "an unavailable display publishes the inactive plan")
    local drawsBefore = #graphics.draws
    state:draw(resources, false)
    Assert.equal(#graphics.draws, drawsBefore, "blocked frames paint no out-of-host panes")

    -- A supported topology brings the same admitted view back under new
    -- placements; the transient picker never draws as the parent.
    current = measurement("tall")
    local restored = state:status()
    Assert.isTrue(restored.admittedParentView == admittedView, "the restore keeps the admitted semantic view")
    local tallPlan = assert(state:presentationPlan(false), "the restore publishes a parent plan")
    Assert.isTrue(#tallPlan.panes > 0, "the restored display places the admitted panes again")
    drawsBefore = #graphics.draws
    state:draw(resources, false)
    Assert.isTrue(
      drawsStateImageSince(graphics, drawsBefore, oldImage),
      "restored frames paint the admitted wallpaper again"
    )
    state:dispose()
    renderer:dispose()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.rejected_parent_reflow_keeps_the_last_valid_plan_and_recovers()
  local mons = monService()
  local manifest = PcPresentationFixture.manifest()
  local options = openOptions(mons, 1, "wide")
  options.manifest = manifest
  local StorageInterface = require("game.hgss.src.pc.StorageInterface")
  local base = StorageInterface.defaults(manifest)
  local gate = { throwFor = nil }
  options.overrides = {}
  for _, case in ipairs({ "dualDisplay", "nativeLike", "wide", "tall" }) do
    local baseline = base[case]
    options.overrides[case] = function(context, view)
      if gate.throwFor ~= nil and view == gate.throwFor then
        error("admitted reflow rejected", 0)
      end
      return baseline(context, view)
    end
  end
  local current = measurement("wide")
  options.measureDisplay = function()
    return current
  end
  local state = PcStorageState.new(options)
  state:status()
  recordAdmittedParent(state)
  local admittedView = assert(state:status().admittedParentView, "the first admission records its parent view")
  local widePlan = assert(state:presentationPlan(false), "admission publishes its parent plan")

  -- Desired state advances so only the retained parent hits the rejected
  -- override; the live session keeps resolving normally.
  state:updateFixed({ { type = "navigate", direction = "down" } })
  gate.throwFor = admittedView
  current = measurement("tall")
  local published, failure = pcall(function()
    return state:status()
  end)
  Assert.isFalse(published, "a rejected parent reflow propagates instead of publishing")
  Assert.isTrue(
    tostring(failure):find("admitted reflow rejected", 1, true) ~= nil,
    "the failure carries the reflow cause"
  )
  Assert.isTrue(state:presentationPlan(false) == widePlan, "the failed reflow keeps the last valid plan")
  gate.throwFor = nil
  local recovered = state:status()
  Assert.isTrue(recovered.admittedParentView == admittedView, "the failed reflow never replaces the admitted view")
  Assert.isTrue(state:presentationPlan(false) ~= widePlan, "recovery replaces the stale parent plan")
  local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
  local session = ApplicationPresentation.new(StorageInterface.defaults(manifest))
  local expected = session:resolve(current, admittedView)
  session:dispose()
  local plan = assert(state:presentationPlan(false), "recovery publishes a parent plan")
  Assert.equal(#plan.panes, #expected.panes, "recovery keeps the current pane count")
  Assert.equal(plan.inputKey, expected.inputKey, "recovery keeps the current input key")
  state:dispose()
  state:dispose()
end

function T.deposit_selector_reports_where_and_commits_to_the_first_empty_slot()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x99aabbcc, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
  local blocker = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE" }))
  assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = blocker } } })).publish()
  local deposited = mons:partyMon(1)
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  state:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 1 } } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "carry", "choosing DEPOSIT opens the target-box selector")
  local asking = state:_view().message
  Assert.equal(asking.id, 19, "the selector asks where to deposit")
  Assert.equal(asking.window, "W39")
  -- Focusing the occupied slot is harmless: the commit lands in the first
  -- empty slot instead of the focused occupied slot.
  state:updateFixed({ { type = "storage_target", target = { kind = "box", slot = 0 } } })
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(state:status().carry, "the selector closes once the deposit commits")
  Assert.equal(mons:boxMon(0, 0).personality, blocker.personality, "the occupied slot keeps its mon")
  local firstEmpty = assert(mons:boxMon(0, 1), "the deposit lands in the first empty slot")
  Assert.equal(firstEmpty.personality, deposited.personality)
  Assert.equal(mons:partyCount(), 1)
  state:dispose()
end

function T.full_deposit_target_reports_full_and_keeps_the_selector_open()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0xddeeff11, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
  local updates = {}
  for slot = 0, 29 do
    updates[#updates + 1] =
      { box = 0, slot = slot, mon = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" })) }
  end
  assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = updates })).publish()
  local deposited = mons:partyMon(1)
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  state:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 1 } } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:_view().message.id, 19, "the selector opens even when the active box is full")
  state:updateFixed({ { type = "confirm" } })
  local full = state:_view().message
  Assert.equal(full.id, 13, "confirming a full box reports that the box is full")
  Assert.notNil(state:status().carry, "a full box keeps the selector open")
  Assert.equal(mons:partyCount(), 2, "a full box never takes party custody")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:_view().message.id, 19, "leaving the full box returns to the deposit prompt")
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(state:status().carry, "the next box accepts the deposit")
  Assert.equal(assert(mons:boxMon(1, 0)).personality, deposited.personality)
  Assert.equal(mons:partyCount(), 1)
  state:dispose()
end

function T.release_followups_show_bye_bye_and_worried_once_each()
  local mons = releaseService()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  local nickname = Mon.displayName(mons:partyMon(0), mons:catalog())
  state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  settleReleaseScan(state)
  local released = state:_view().message
  Assert.equal(released.id, 3, "the shrink ends with the released line while the mon is still held")
  Assert.equal(mons:partyCount(), 2, "the released line precedes removal")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  local bye = state:_view().message
  Assert.equal(bye.id, 4, "acknowledging the released line shows the bye-bye line once")
  Assert.equal(bye.subject, nickname, "the bye-bye line retains the released nickname")
  Assert.equal(bye.window, "W37")
  Assert.equal(mons:partyCount(), 2, "the mon leaves only after the bye-bye acknowledgement")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().releaseCheck.outcome, "removed")
  Assert.equal(mons:partyCount(), 1, "the bye-bye acknowledgement removes the mon")
  Assert.isNil(state:_view().message, "the removal closes the message line")
  state:dispose()

  local protected = releaseService("surf")
  protected:setMove(0, 1, "TACKLE")
  protected:setMove(0, 0, "FLY")
  protected:setMove(0, 1, "SURF")
  local returned = PcStorageState.new(openOptions(protected, 2, "wide"))
  returned:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  settleReleaseScan(returned)
  local cameBack = returned:_view().message
  Assert.equal(cameBack.id, 32, "a protected move grows the mon back before the came-back line")
  returned:updateFixed({ { type = "navigate", direction = "up" } })
  local worried = returned:_view().message
  Assert.equal(worried.id, 33, "acknowledging a return shows the worried line once")
  Assert.equal(worried.window, "W37")
  Assert.equal(protected:partyCount(), 2, "a return never removes the mon")
  returned:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.isNil(returned:_view().message, "a second input dismisses the worried line")
  Assert.equal(returned:status().releaseCheck.outcome, "returned")
  returned:dispose()
end

function T.give_item_replacement_confirms_with_the_incoming_item()
  local mons = monService()
  local options = openOptions(mons, 3, "wide")
  local bag = options.bag
  Assert.isTrue(bag:add("POTION", 1))
  Assert.isTrue(bag:add("SITRUS_BERRY", 1))
  setPartyHeldItem(mons, "POTION")
  options.childFactories.heldItemPicker = heldItemPicker("SITRUS_BERRY")
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "party" } })
  state:updateFixed({ { type = "action", action = "giveItem" } })
  state:updateFixed({})
  local pending = state:_view().message
  Assert.equal(pending.id, 26, "replacing a held item asks to put the incoming item away")
  Assert.equal(pending.window, "W37")
  Assert.isTrue(pending.yesNo)
  Assert.equal(pending.subject, bag:catalog():item("SITRUS_BERRY").name)
  state:dispose()
end

function T.storage_cues_follow_the_retail_situations()
  local function recordingOptions(mons, mode)
    local cues = {}
    local options = openOptions(mons, mode, "wide")
    options.audio = {
      play = function(name)
        cues[#cues + 1] = name
      end,
    }
    return options, cues
  end
  local function played(cues, name)
    for _, cue in ipairs(cues) do
      if cue == name then
        return true
      end
    end
    return false
  end

  do
    local mons = monService()
    local options, cues = recordingOptions(mons, 0)
    local booted = PcStorageState.new(options)
    booted:updateFixed({})
    booted:updateFixed({})
    Assert.equal(#cues, 1, "the login cue plays once on boot, not per tick")
    Assert.equal(cues[1], "SEQ_SE_DP_PC_LOGIN")
    booted:dispose()
  end

  do
    local mons = monService()
    local boxed = mons:partyMon(0)
    assert(mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 3, mon = boxed } } })).publish()
    local options, cues = recordingOptions(mons, 1)
    local state = PcStorageState.new(options)
    state:updateFixed({})
    local booted = #cues
    state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 3 } } })
    state:updateFixed({ { type = "confirm" } })
    Assert.isTrue(played(cues, "SEQ_SE_DP_BOX02"), "touching an occupied mon plays the pickup cue")
    state:updateFixed({ { type = "confirm" } })
    Assert.isTrue(played(cues, "SEQ_SE_DP_DECIDE"), "choosing a menu action plays the decide cue")
    state:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.isTrue(played(cues, "SEQ_SE_DP_SELECT"), "cursor movement plays the select cue")
    state:updateFixed({ { type = "cancel" } })
    Assert.isTrue(state:status().carry == nil, "cancel puts the picked-up mon back")
    state:dispose()
    Assert.isTrue(booted >= 1, "the boot cue played before the interaction cues")
  end

  do
    -- Depositing the last usable mon refuses with the error cue.
    local mons = monService()
    local options, cues = recordingOptions(mons, 0)
    local state = PcStorageState.new(options)
    state:updateFixed({})
    state:updateFixed({ { type = "confirm" } })
    state:updateFixed({ { type = "confirm" } })
    Assert.equal(state:_view().message.id, 6)
    Assert.isTrue(played(cues, "SEQ_SE_DP_BOX03"), "a refused deposit plays the error cue")
    state:dispose()
  end

  do
    -- A successful drop applies with the drop cue.
    local mons = monService()
    local factory = CatalogFixture.makeFactory(0x44556677, mons:catalog())
    Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
    local boxed = mons:partyMon(1)
    assert(mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 1, mon = boxed } } })).publish()
    local options, cues = recordingOptions(mons, 2)
    local state = PcStorageState.new(options)
    state:updateFixed({})
    state:updateFixed({ { type = "party" } })
    state:updateFixed({ { type = "action", action = "move" } })
    state:updateFixed({
      { type = "storage_target", target = { kind = "box", box = 0, slot = 2 } },
      { type = "confirm" },
    })
    Assert.isTrue(played(cues, "SEQ_SE_DP_BOX01"), "applying a move plays the drop cue")
    Assert.isNil(state:status().carry)
    state:dispose()
  end
end

function T.controller_focus_follows_the_source_grid_through_title_and_bottom_controls()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  local function node()
    return state:status().visualView.cursor.node
  end
  Assert.equal(node(), 0, "Move starts on the first box slot")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(node(), 30, "the first box row rises to the box title")
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(state:status().menu.address, "the title plate opens the Wallpaper / Name pair")
  Assert.equal(node(), 0, "the title menu starts on the active box thumbnail")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(node(), 8, "the thumbnail drops to the Change Box plate")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(node(), 9, "the plate drops to Wallpaper")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(node(), 8, "Wallpaper rises to the Change Box plate")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(node(), 0, "the plate rises to the thumbnail row")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(node(), 10, "the list walks to Name")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(node(), 30, "closing the title menu returns to the title plate")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(node(), 0, "the title drops back to the column the player left")
  for _ = 1, 3 do
    state:updateFixed({ { type = "navigate", direction = "right" } })
  end
  for _ = 1, 4 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(node(), 27, "the grid walks to the last row's fourth column")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(node(), 33, "the last box row drops to PARTY")
  Assert.equal(state:status().visualView.cursor.pose, "browse", "bottom buttons use the open hand")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(node(), 34, "PARTY steps to the Move tab")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(node(), 35, "the tab steps to RETURN")
  state:updateFixed({ { type = "confirm" } })
  Assert.notNil(state:status().visualView.message, "RETURN asks to leave")
  state:updateFixed({ { type = "cancel" } })
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(node(), 24, "up from RETURN uses the source link to the last box row")
  state:dispose()
end

function T.box_tray_pages_selects_and_switches_the_active_box()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({ { type = "box_tab" } })
  local tray = assert(state:_view().boxTray, "the MOVE tab opens the box tray")
  Assert.equal(tray.mode, "box", "the tray runs in its Move/Item mode")
  Assert.equal(tray.trayBox, 0, "the tray starts on the active box")
  state:updateFixed({ { type = "box_tray_select", column = 3 } })
  tray = assert(state:_view().boxTray)
  Assert.equal(tray.trayBox, 3, "a thumbnail selects its box")
  Assert.isTrue(tray.changeBox, "a different box offers the Change Box plate")
  state:updateFixed({ { type = "box_tray_change" } })
  Assert.equal(state:status().activeBox, 3, "the Change Box plate switches the active box")
  tray = assert(state:_view().boxTray)
  Assert.isFalse(tray.changeBox, "the plate retires once the box matches")
  state:updateFixed({ { type = "box_tray_page", delta = 1 } })
  tray = assert(state:_view().boxTray)
  Assert.equal(tray.page, 6, "the next arrow pages by six boxes")
  Assert.equal(tray.trayBox, 9, "paging keeps the selected column")
  state:updateFixed({ { type = "box_tray_cancel" } })
  Assert.isNil(state:_view().boxTray, "EXIT closes the tray")
  state:dispose()
end

function T.deposit_selector_switches_to_the_chosen_box_before_the_drop()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x0fedcba9, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  state:updateFixed({ { type = "action", action = "deposit" } })
  local tray = assert(state:_view().boxTray, "Deposit opens the box selector")
  Assert.equal(tray.mode, "deposit", "the selector runs in its Deposit mode")
  Assert.equal(state:status().visualView.cursor.node, 0, "the selector starts on the active box")
  state:updateFixed({ { type = "box_tray_select", column = 2 } })
  Assert.equal(assert(state:_view().boxTray).trayBox, 2, "a selector thumbnail stages its box")
  Assert.equal(state:status().visualView.cursor.node, 8, "touch selection moves to the OK plate")
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(state:_view().boxTray, "OK closes the selector")
  Assert.equal(state:status().activeBox, 2, "the chosen box becomes active")
  Assert.notNil(mons:boxMon(2, 0), "the deposit lands in the chosen box")
  Assert.equal(mons:partyCount(), 1, "the deposited mon leaves the party")
  state:dispose()
end

-- PCBox_State_ChooseMoveFromBox slides the tray open with the mon on the hand;
-- a drop on another box's thumbnail lands in that box's first empty slot, and a
-- summary opened from the mode list returns to the same row without custody.
function T.move_hold_drops_into_another_box_and_list_summary_restores_the_row()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x99887766, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local boxed = mons:partyMon(1)
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 4, mon = boxed } } }))
  stored.publish()

  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({
    { type = "storage_target", target = { kind = "box", box = 0, slot = 4 } },
    { type = "confirm" },
    { type = "confirm" },
  })
  Assert.equal(state:status().phase, "carry", "the MOVE row holds the mon")
  Assert.isTrue(state:status().carry.holding, "the held mon is in the tray holding state")
  state:updateFixed({ { type = "box_tray_select", column = 1 }, { type = "confirm" } })
  Assert.isNil(state:status().carry, "a thumbnail drop releases the hand")
  Assert.equal(state:status().activeBox, 0, "a cross-box drop does not change the active box")
  Assert.isNil(mons:boxMon(0, 4), "the dropped box slot empties")
  Assert.equal(mons:boxMon(1, 0).personality, boxed.personality, "the mon lands in the target box's first empty slot")
  state:dispose()

  -- Cancelling the hold puts the mon back and closes the tray.
  local cancelled = PcStorageState.new(openOptions(mons, 2, "wide"))
  local before = mons:boxMon(0, 4)
  cancelled:updateFixed({
    { type = "storage_target", target = { kind = "box", box = 0, slot = 4 } },
    { type = "confirm" },
    { type = "confirm" },
  })
  cancelled:updateFixed({ { type = "cancel" } })
  Assert.isNil(cancelled:status().carry, "cancel releases the hand")
  Assert.isNil(cancelled:_view().boxTray, "cancel closes the tray the MOVE row opened")
  Assert.deepEqual(mons:boxMon(0, 4), before, "cancel keeps the mon in its slot")
  cancelled:dispose()

  -- SUMMARY from the open list runs the action; returning restores the row.
  local summaryOptions = openOptions(mons, 1, "wide")
  local disposed = 0
  summaryOptions.childFactories = {
    summary = function()
      return {
        updateFixed = function() end,
        result = function()
          return { kind = "closed" }
        end,
        status = function()
          return {}
        end,
        dispose = function()
          disposed = disposed + 1
        end,
      }
    end,
  }
  local summary = PcStorageState.new(summaryOptions)
  summary:updateFixed({
    { type = "storage_target", target = { kind = "box", box = 1, slot = 0 } },
    { type = "confirm" },
  })
  summary:updateFixed({ { type = "navigate", direction = "down" }, { type = "action", action = "summary" } })
  Assert.equal(summary:status().phase, "child", "SUMMARY from the list opens the summary")
  Assert.equal(summary:status().childKind, "summary")
  summary:updateFixed({})
  Assert.equal(disposed, 1, "the summary child is disposed exactly once")
  Assert.equal(summary:status().phase, "menu", "returning from the summary restores the mode list")
  Assert.deepEqual(summary:status().menu.actions, { "withdraw", "summary", "markings", "release" })
  Assert.equal(summary:status().menu.selected, 2, "the cursor returns to the SUMMARY row")
  Assert.equal(summary._grid:index(), 35, "the returned cursor sits on the source SUMMARY row node")
  summary:dispose()
end

-- PCBox_TryWithdraw refuses a full party before the panel slides in or the mon
-- leaves its slot.
function T.withdraw_refuses_a_full_party_before_arming_the_hand()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x11223344, mons:catalog())
  for _ = 1, 5 do
    Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  end
  local boxed = mons:partyMon(0)
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = boxed } } }))
  stored.publish()
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  state:updateFixed({
    { type = "storage_target", target = { kind = "box", box = 0, slot = 0 } },
    { type = "confirm" },
    { type = "confirm" },
  })
  Assert.isNil(state:status().carry, "a full party refuses the withdrawal without arming the hand")
  Assert.equal(state:status().phase, "menu", "the refusal returns to the action list")
  Assert.notNil(mons:boxMon(0, 0), "the refused mon stays in its slot")
  Assert.notNil(state:_view().message, "the refusal prints its message")
  state:dispose()
end

-- The box tray's SUMMARY plate opens the held mon's summary and returns to the
-- holding state with the mon still on the hand (summaryFromHolding).
function T.box_tray_summary_keeps_the_held_mon_on_return()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x13572468, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local boxed = mons:partyMon(1)
  assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 3, mon = boxed } } })).publish()
  local options = openOptions(mons, 2, "wide")
  options.childFactories = {
    summary = function()
      return {
        updateFixed = function() end,
        result = function()
          return { kind = "closed" }
        end,
        status = function()
          return {}
        end,
        dispose = function() end,
      }
    end,
  }
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 3 } } })
  state:updateFixed({ { type = "confirm" }, { type = "confirm" } })
  Assert.isTrue(state:status().carry.holding, "the MOVE row holds the mon")
  Assert.equal(assert(state:_view().boxTray).mode, "box", "the tray is open while holding")
  state:updateFixed({ { type = "action", action = "summary" } })
  Assert.equal(state:status().phase, "child", "the tray plate opens the held mon's summary")
  state:updateFixed({})
  Assert.equal(state:status().phase, "carry", "returning restores the holding state")
  Assert.isTrue(state:status().carry.holding, "the mon is still on the hand")
  Assert.equal(assert(state:_view().boxTray).mode, "box", "the tray is still open after the summary")
  state:dispose()
end

-- One custody cell's logical centre, and the party drop-rect centre a stylus
-- drag resolves against.
local function boxCenter(slot)
  local rect = PcStorageGeometry.boxSlotRect(slot)
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function partyDropCenter(slot, side)
  local rect = PcStorageGeometry.partyDropRect(slot, side)
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function addPartyMon(mons, seed)
  local factory = CatalogFixture.makeFactory(seed, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
end

local function storePartyMon(mons, partySlot, box, slot, heldItem)
  local mon = mons:partyMon(partySlot)
  if heldItem ~= nil then
    mon.heldItem = heldItem
  end
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = box, slot = slot, mon = mon } } }))
  change.publish()
end

local function dragFrom(slot, pointerId)
  local x, y = boxCenter(slot)
  return { type = "storage_touch", target = { kind = "box", box = 0, slot = slot }, x = x, y = y, pointerId = pointerId }
end

function T.stylus_drag_moves_a_box_mon_and_releasing_on_its_cell_opens_the_list()
  local mons = monService()
  storePartyMon(mons, 0, 0, 4)
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({ dragFrom(4, "pen") })
  Assert.equal(state:status().phase, "carry", "touching an occupied box cell picks the mon up immediately")
  Assert.notNil(state:status().visualView.drag, "the drag publishes its stylus position")
  Assert.equal(state:status().visualView.drag.kind, "mon")

  local toX, toY = boxCenter(7)
  state:updateFixed({ { type = "storage_drag_move", x = toX, y = toY, pointerId = "pen" } })
  Assert.deepEqual(
    { state:status().visualView.drag.x, state:status().visualView.drag.y },
    { toX, toY },
    "the drag follows the stylus"
  )
  state:updateFixed({ { type = "storage_drag_release", x = toX, y = toY, pointerId = "pen" } })
  Assert.isNil(mons:boxMon(0, 4), "the source cell empties")
  Assert.notNil(mons:boxMon(0, 7), "the drop cell holds the mon")
  Assert.isNil(state:status().carry, "the drop ends the carry")

  state:updateFixed({ dragFrom(7, "pen-2") })
  local x, y = boxCenter(7)
  state:updateFixed({ { type = "storage_drag_release", x = x, y = y, pointerId = "pen-2" } })
  Assert.equal(state:status().phase, "menu", "releasing on the source cell opens the action list")
  Assert.deepEqual(state:status().menu.actions, { "move", "summary", "heldItems", "markings", "release" })
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 7 })
  state:dispose()
end

function T.stylus_touch_on_an_empty_cell_never_picks_anything_up()
  local mons = monService()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({ dragFrom(9, "pen") })
  Assert.isNil(state:status().carry)
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 9 })
  state:dispose()
end

function T.stylus_deposit_drag_lowers_the_party_panel_and_drops_into_the_box()
  local mons = monService()
  addPartyMon(mons, 0x1234)
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  local rect = PcStorageGeometry.partySlotRect(0, "left")
  local x, y = rect.x + rect.width / 2, rect.y + rect.height / 2
  state:updateFixed({ { type = "storage_touch", target = { kind = "party", slot = 0 }, x = x, y = y, pointerId = "pen" } })
  Assert.equal(state:_view().tray, "left", "the deposit drag keeps the party panel up on its cell")
  Assert.equal(state:_view().message.window, "W40", "a party drag prints the source hint strip")
  Assert.equal(state:_view().message.id, 36, "a deposit with room in the box prints Place it in the Box!")

  local toX, toY = boxCenter(5)
  state:updateFixed({ { type = "storage_drag_move", x = toX, y = toY, pointerId = "pen" } })
  Assert.equal(state:_view().tray, "closed", "leaving the party panel lowers it")
  state:updateFixed({ { type = "storage_drag_release", x = toX, y = toY, pointerId = "pen" } })
  Assert.notNil(mons:boxMon(0, 5), "the party mon lands in the dropped-on box cell")
  Assert.equal(mons:partyCount(), 1, "the deposit removes one party member")
  Assert.isTrue(
    state:_view().message == nil or state:_view().message.window ~= "W40",
    "the drag hint clears when the drag ends"
  )
  state:dispose()
end

function T.stylus_withdraw_drag_raises_the_right_panel_and_withdraws()
  local mons = monService()
  storePartyMon(mons, 0, 0, 6)
  local state = PcStorageState.new(openOptions(mons, 1, "wide"))
  state:updateFixed({ dragFrom(6, "pen") })
  Assert.equal(state:_view().message.id, 37, "a withdraw with room in the party prints its hint")
  local x, y = partyDropCenter(2, "right")
  state:updateFixed({ { type = "storage_drag_move", x = x, y = y, pointerId = "pen" } })
  Assert.equal(state:_view().tray, "right", "leaving the cell raises the right party panel")
  state:updateFixed({ { type = "storage_drag_release", x = x, y = y, pointerId = "pen" } })
  Assert.isNil(mons:boxMon(0, 6), "the withdrawn mon leaves the box")
  Assert.equal(mons:partyCount(), 2, "the withdrawn mon joins the party")
  state:dispose()
end

function T.stylus_item_drag_swaps_held_items_and_releases_back_on_the_source()
  local mons = monService()
  storePartyMon(mons, 0, 0, 4, "POTION")
  local other = mons:partyMon(0)
  other.heldItem = "NONE"
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 7, mon = other } } }))
  change.publish()
  local state = PcStorageState.new(openOptions(mons, 3, "wide"))
  state:updateFixed({ dragFrom(4, "pen") })
  Assert.equal(state:status().phase, "carry")
  Assert.equal(state:status().visualView.drag.kind, "items", "item mode lifts the held item")
  Assert.equal(state:_view().message.id, 60, "a non-Mail item prints the give hint")
  local toX, toY = boxCenter(7)
  state:updateFixed({ { type = "storage_drag_move", x = toX, y = toY, pointerId = "pen" } })
  state:updateFixed({ { type = "storage_drag_release", x = toX, y = toY, pointerId = "pen" } })
  Assert.equal(mons:boxMon(0, 4).heldItem, "NONE", "the source mon gives its item up")
  Assert.equal(mons:boxMon(0, 7).heldItem, "POTION", "the destination mon takes the item")
  Assert.isNil(state:status().menu, "an item drop never opens the action list")

  -- Releasing a lifted item back on its own mon returns it without a message.
  local back = PcStorageState.new(openOptions(mons, 3, "wide"))
  back:updateFixed({ dragFrom(7, "pen-2") })
  Assert.equal(back:status().phase, "carry", "the mon now holding the item lifts it")
  local x, y = boxCenter(7)
  back:updateFixed({ { type = "storage_drag_release", x = x, y = y, pointerId = "pen-2" } })
  Assert.isNil(back:status().carry)
  Assert.isNil(back:status().menu)
  Assert.equal(mons:boxMon(0, 7).heldItem, "POTION", "dropping the item back changes nothing")
  back:dispose()
  state:dispose()
end

function T.stylus_drag_cancel_restores_the_source_without_committing()
  local mons = monService()
  storePartyMon(mons, 0, 0, 4)
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({ dragFrom(4, "pen") })
  local toX, toY = boxCenter(9)
  state:updateFixed({ { type = "storage_drag_move", x = toX, y = toY, pointerId = "pen" } })
  state:updateFixed({ { type = "pointer_cancel", pointerId = "pen" } })
  Assert.isNil(state:status().carry)
  Assert.isNil(state:status().visualView.drag)
  Assert.notNil(mons:boxMon(0, 4), "a cancelled drag leaves the mon in its cell")
  Assert.isNil(mons:boxMon(0, 9))
  state:dispose()
end

function T.stylus_tap_on_a_mon_without_an_item_opens_the_give_list()
  local mons = monService()
  storePartyMon(mons, 0, 0, 4)
  local state = PcStorageState.new(openOptions(mons, 3, "wide"))
  state:updateFixed({ dragFrom(4, "pen") })
  Assert.equal(state:status().phase, "menu", "an item-less mon opens the GIVE/BAG list on touch")
  Assert.deepEqual(state:status().menu.actions, { "giveItem" })
  Assert.isNil(state:status().carry)
  state:dispose()
end

function T.real_stylus_drag_moves_a_box_mon_through_the_session_pointer_capture()
  local mons = monService()
  storePartyMon(mons, 0, 0, 4)
  local state = PcStorageState.new(openOptions(mons, 2, "nativeLike"))
  local source = assert(state._session:plan().content.hitRegions.boxSlots[5])
  local fromX, fromY = hostPointForRect(state, source.rect)
  state:updateFixed({ { type = "pointer_down", pointerId = "stylus", x = fromX, y = fromY } })
  Assert.equal(state:status().phase, "carry", "the captured pointer press starts the drag")
  local destination = assert(state._session:plan().content.hitRegions.boxSlots[8])
  local toX, toY = hostPointForRect(state, destination.rect)
  state:updateFixed({ { type = "pointer_move", pointerId = "stylus", x = toX, y = toY } })
  state:updateFixed({ { type = "pointer_up", pointerId = "stylus", x = toX, y = toY } })
  Assert.isNil(mons:boxMon(0, 4), "the pointer release commits the drop")
  Assert.notNil(mons:boxMon(0, 7), "the stylus carried the mon to the released cell")
  Assert.isNil(state:status().carry)
  state:dispose()
end

function T.deposit_selector_remembers_the_touched_column_and_cycles_boxes()
  local mons = monService()
  addPartyMon(mons, 0x77AA)
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
  -- Open the deposit list and stage the selector on the active box.
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(assert(state:_view().boxTray).mode, "deposit", "the deposit selector is open")
  Assert.equal(state._grid:index(), 0, "the selector opens on the active box's column")

  -- Touch the fourth thumbnail: the source records that column before moving
  -- to the OK plate.
  state:updateFixed({ { type = "box_tray_select", column = 3 } })
  Assert.equal(state._grid:index(), 8, "a touched thumbnail moves the cursor to the OK plate")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state._grid:index(), 3, "returning from OK restores the touched column")
  state:updateFixed({ { type = "confirm" } })
  Assert.notNil(mons:boxMon(3, 0), "the deposit lands in the remembered box")
  Assert.equal(state._activeBox, 3, "a committed deposit switches the active box")
  state:dispose()

  -- Crossing the row edge steps one box across the whole set, so a held
  -- selector pages without returning to the page arrows first.
  local cyclingMons = monService()
  addPartyMon(cyclingMons, 0x66CC)
  local cycling = PcStorageState.new(openOptions(cyclingMons, 0, "wide"))
  cycling:updateFixed({ { type = "confirm" } })
  cycling:updateFixed({ { type = "confirm" } })
  cycling:updateFixed({ { type = "box_tray_select", column = 5 } })
  cycling:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(cycling._grid:index(), 5, "the last column is remembered")
  cycling:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(assert(cycling:_view().boxTray).trayBox, 6, "leaving the last column steps to the next box")
  Assert.equal(cycling._grid:index(), 0, "the cursor lands on the first column of the next box")
  cycling:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(assert(cycling:_view().boxTray).trayBox, 5, "leaving the first column steps back a box")
  Assert.equal(cycling._grid:index(), 5, "the cursor lands on the last column of the previous box")
  cycling:dispose()
end

function T.item_results_print_the_source_took_and_held_lines()
  local mons = monService()
  local factory = CatalogFixture.makeFactory(0x99BB, mons:catalog())
  local boxed = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
  boxed.heldItem = "POTION"
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = boxed } } }))
  stored.publish()

  -- Item mode BAG: "Put away Potion?" then "Placed Potion in the Bag.".
  local take = PcStorageState.new(openOptions(mons, 3, "wide"))
  take:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 0 } } })
  take:updateFixed({ { type = "confirm" } })
  Assert.equal(take:status().menu.actions[1], "bagItem", "a mon holding an item offers BAG")
  take:updateFixed({ { type = "confirm" } })
  local message = take:_view().message
  Assert.notNil(message, "putting an item away asks first")
  Assert.equal(message.id, 26, "the BAG half asks Put away ...?")
  Assert.equal(message.subject, "Potion")
  take:updateFixed({ { type = "confirm" } })
  message = take:_view().message
  Assert.notNil(message, "a successful put-away prints a result line")
  Assert.equal(message.id, 27, "putting away prints Placed ... in the Bag.")
  Assert.equal(message.subject, "Potion", "the line names the placed item")
  take:dispose()

  -- HELD ITEMS: "Take this Potion?" then "Took the Potion.".
  local held = monService()
  local heldMon = held:partyMon(0)
  heldMon.heldItem = "POTION"
  local prepared = assert(held:preparePartyChanges(held:partyRevision(), { { slot = 0, mon = heldMon } }))
  prepared.publish()
  local taking = PcStorageState.new(openOptions(held, 2, "wide"))
  taking:updateFixed({ { type = "party" } })
  taking:updateFixed({ { type = "action", action = "heldItems" } })
  message = taking:_view().message
  Assert.equal(message.id, 23, "taking asks Take this ...?")
  taking:updateFixed({ { type = "confirm" } })
  message = taking:_view().message
  Assert.equal(message.id, 15, "taking prints Took the ...")
  taking:dispose()
end

function T.drag_hints_follow_the_source_guards()
  local mons = monService()
  -- Every other party member is unusable, so a deposit drag warns instead.
  local rect = PcStorageGeometry.partySlotRect(0, "left")
  local x, y = rect.x + rect.width / 2, rect.y + rect.height / 2
  local guarded = PcStorageState.new(openOptions(mons, 0, "wide"))
  guarded:updateFixed({ { type = "storage_touch", target = { kind = "party", slot = 0 }, x = x, y = y, pointerId = "p" } })
  Assert.equal(guarded:_view().message.id, 58, "a last usable party mon prints its warning hint")
  guarded:dispose()

  local full = monService()
  for index = 2, 6 do
    addPartyMon(full, 0xA0 + index)
  end
  local withdraw = PcStorageState.new(openOptions(full, 1, "wide"))
  storePartyMon(full, 0, 0, 4)
  withdraw:updateFixed({ { type = "storage_touch", target = { kind = "box", box = 0, slot = 4 }, x = 0, y = 0, pointerId = "p" } })
  Assert.equal(withdraw:_view().message.id, 39, "a full party prints the party-full hint")
  withdraw:dispose()
end

function T.stylus_tray_drag_drops_a_box_mon_onto_a_thumbnail_and_returns_to_the_tray()
  local mons = monService()
  storePartyMon(mons, 0, 0, 4)
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  state:updateFixed({ { type = "box_tab" } })
  Assert.equal(assert(state:_view().boxTray).mode, "box", "the Move tray opens")
  local fromX, fromY = boxCenter(4)
  state:updateFixed({ {
    type = "storage_touch",
    target = { kind = "box", box = 0, slot = 4 },
    x = fromX,
    y = fromY,
    pointerId = "pen",
  } })
  Assert.equal(state:status().phase, "carry", "the tray keeps the box grid draggable")
  local rect = PcStorageGeometry.trayDropRect(2, false)
  local toX, toY = rect.x + rect.width / 2, rect.y + rect.height / 2
  state:updateFixed({ { type = "storage_drag_move", x = toX, y = toY, pointerId = "pen" } })
  state:updateFixed({ { type = "storage_drag_release", x = toX, y = toY, pointerId = "pen" } })
  Assert.notNil(mons:boxMon(2, 0), "the drop lands in the thumbnail's box")
  Assert.isNil(mons:boxMon(0, 4), "the source cell empties")
  Assert.isNil(state:_view().boxTray, "a committed tray drop closes the tray")

  state:dispose()

  -- Dropping back on the source resumes the tray instead of closing it.
  local held = monService()
  storePartyMon(held, 0, 0, 4)
  local back = PcStorageState.new(openOptions(held, 2, "wide"))
  back:updateFixed({ { type = "box_tab" } })
  local bx, by = boxCenter(4)
  back:updateFixed({ {
    type = "storage_touch",
    target = { kind = "box", box = 0, slot = 4 },
    x = bx,
    y = by,
    pointerId = "pen",
  } })
  back:updateFixed({ { type = "storage_drag_release", x = bx, y = by, pointerId = "pen" } })
  Assert.equal(assert(back:_view().boxTray).mode, "box", "a drop-back keeps the tray open")
  Assert.notNil(held:boxMon(0, 4), "the mon stays in its cell")
  Assert.isNil(back:status().carry)
  back:dispose()
end

return { tests = T }
