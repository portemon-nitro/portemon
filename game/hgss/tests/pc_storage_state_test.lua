-- Storage child opens in each retail mode across the supported measured
-- topologies and returns cleanly without taking custody from the domain.

local Assert = require("tests.support.Assert")
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
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function monService()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x12345678):capture(), catalog:fingerprint()),
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

local function releaseService()
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
    bucket = MonsSave.capture(
      Party.new():capture(),
      Lcrng.new(0x10203040):capture(),
      catalog:fingerprint(),
      nil,
      { configuredCount = 37 }
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
  local factory = CatalogFixture.makeFactory(0x23456789, catalog)
  for _ = 1, 2 do
    Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  end
  mons:setMove(0, 0, "SURF")
  mons:setMove(0, 1, "FLY")
  local alternative = mons:partyMon(1)
  alternative.moves[1] = { move = "SURF", pp = catalog:move("SURF").basePp, ppUps = 0 }
  local boxed = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 36, slot = 29, mon = alternative } } }))
  boxed.publish()
  return mons
end

local function finishReleaseScan(state)
  state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  Assert.equal(state:status().releaseCheck.outcome, "confirm")
  state:updateFixed({ { type = "confirm" } })
  local check = state:status().releaseCheck
  local ticks = 1
  local maximumTicks = math.ceil(check.total / 15)
  while check.outcome == "pending" do
    Assert.isTrue(ticks < maximumTicks, "scan completes within the source candidate count")
    state:updateFixed({})
    ticks = ticks + 1
    check = state:status().releaseCheck
  end
  Assert.equal(ticks, maximumTicks, "the source scan visits fifteen addresses on each fixed tick")
  Assert.equal(check.scanned, check.total, "the fixed-tick scan covers every candidate address")
  return check
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
    tall = { width = 192, height = 512 },
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
  withdraw:updateFixed({ { type = "confirm" } })
  Assert.isNil(mons:boxMon(0, 0))
  Assert.equal(mons:partyCount(), 2)
  withdraw:dispose()
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
  local items = PcStorageState.new({
    mode = 3,
    mons = mons,
    bag = bag,
    manifest = PcPresentationFixture.manifest(),
    measureDisplay = function()
      return measurement("wide")
    end,
    audio = { play = function() end },
    icons = {},
    portraits = {},
    childFactories = {},
  })
  items:updateFixed({ { type = "action", action = "giveItem", item = "POTION" } })
  Assert.equal(mons:partyMon(0).heldItem, "POTION")
  Assert.equal(bag:quantity("POTION"), 0)
  items:dispose()
end

function T.child_cancel_returns_to_the_same_mode_box_and_focus()
  local mons = monService()
  local disposed = 0
  local childFactories = {
    summary = function(request)
      Assert.deepEqual(request.source, { kind = "party", slot = 0 })
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
  Assert.deepEqual(state:status().focus, { domain = "party", slot = 0 })
  Assert.equal(disposed, 1, "returned child is disposed exactly once")
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
    icons = {},
    portraits = {},
    childFactories = {},
  })
  items:updateFixed({ { type = "action", action = "takeItem" } })
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
    icons = {},
    portraits = {},
    childFactories = {},
  })
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
  local editingOptions = openOptions(mons, 0, "wide")
  editingOptions.childFactories = childFactories
  local editing = PcStorageState.new(editingOptions)
  editing:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 7 } } })
  editing:updateFixed({ { type = "action", action = "markings" } })
  editing:updateFixed({ { type = "confirm" } })
  editing:updateFixed({ { type = "submit" } })
  Assert.equal(assert(mons:boxMon(0, 7)).markings, 1)
  editing:updateFixed({ { type = "action", action = "boxName" } })
  editing:updateFixed({ { type = "submit" } })
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
  local options = openOptions(mons, 0, "wide")
  options.childFactories = childFactories
  local state = PcStorageState.new(options)
  state:updateFixed({ { type = "storage_target", target = { kind = "box", box = 0, slot = 7 } } })
  for _, childKind in ipairs({ "summary", "boxName" }) do
    state:updateFixed({ { type = "action", action = childKind } })
    Assert.equal(state:status().phase, "child")
    state:updateFixed({ { type = "cancel" } })
    Assert.equal(state:status().phase, "browse")
    Assert.equal(state:status().mode, 0)
    Assert.equal(state:status().activeBox, 0)
    Assert.deepEqual(state:status().focus, { domain = "box", slot = 7 })
  end
  Assert.deepEqual(mons:boxMon(0, 7), beforeMon)
  Assert.deepEqual(mons:boxMetadata(0), beforeMetadata)
  Assert.equal(disposed, 2, "each cancelled child is disposed once")
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
  local options = openOptions(mons, 0, "wide")
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
  state:updateFixed({ { type = "action", action = "markings" } })
  Assert.equal(state:status().phase, "editor")
  Assert.equal(state:status().editor.kind, "markings")
  local markingPlan = state._session:plan()
  Assert.equal(#markingPlan.content.hitRegions.editorChoices, 6)
  Assert.deepEqual(markingPlan.content.hitRegions.editorChoices[1].rect, { x = 120, y = 8, width = 8, height = 8 })
  Assert.deepEqual(
    markingPlan.mapInput({ type = "pointer_down", x = 121, y = 9 }, state:_view(), markingPlan),
    { type = "marking_choice", id = 0 },
    "the source marking tile and its pointer target share one plan"
  )
  state:updateFixed({ { type = "navigate", direction = "right" }, { type = "confirm" } })
  state:updateFixed({ { type = "submit" } })
  Assert.equal(assert(mons:boxMon(0, 7)).markings, 7)
  Assert.equal(openedChildren, 0)

  state:updateFixed({ { type = "action", action = "wallpaper" } })
  Assert.equal(state:status().phase, "editor")
  Assert.equal(state:status().editor.kind, "wallpaper")
  local plan = state._session:plan()
  Assert.equal(#plan.content.hitRegions.editorChoices, 15, "locked and current wallpapers have no pointer hit")
  local tap = plan.mapInput({ type = "pointer_down", x = 84, y = 21 }, state:_view(), plan)
  Assert.deepEqual(tap, { type = "wallpaper_choice", id = 1 }, "pointer and draw plans share wallpaper geometry")
  local lockedTap = plan.mapInput({ type = "pointer_down", x = 40, y = 117 }, state:_view(), plan)
  Assert.equal(lockedTap.type, "pointer_down", "locked bonus wallpaper has no pointer selection")
  state:updateFixed({ { type = "wallpaper_choice", id = 16 } })
  Assert.equal(state:status().editor.selected, 0, "locked bonus wallpaper cannot be selected")
  state:updateFixed({ { type = "wallpaper_choice", id = 2 } })
  state:updateFixed({ { type = "submit" } })
  Assert.equal(mons:boxMetadata(0).wallpaperId, 2)
  Assert.equal(openedChildren, 0)

  state:updateFixed({ { type = "action", action = "wallpaper" } })
  state:updateFixed({ { type = "wallpaper_choice", id = 2 } })
  state:updateFixed({ { type = "submit" } })
  Assert.equal(state:status().phase, "browse", "confirming the current wallpaper closes the editor")
  Assert.equal(mons:boxMetadata(0).wallpaperId, 2, "confirming the current wallpaper does not mutate the box")

  local unlocked = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { bonusUnlocks = { true, true, true, true, true, true, true, true } }))
  unlocked.publish()
  state:updateFixed({ { type = "action", action = "wallpaper" } })
  state:updateFixed({ { type = "navigate", direction = "right" }, { type = "navigate", direction = "right" } })
  Assert.equal(state:status().editor.selected, 0, "horizontal movement wraps within four source columns")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().editor.selected, 20, "vertical movement wraps six source rows by four")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().editor.selected, 0)
  state:updateFixed({ { type = "wallpaper_choice", id = 20 } })
  state:updateFixed({ { type = "submit" } })
  Assert.equal(mons:boxMetadata(0).wallpaperId, 36, "logical bonus wallpaper maps to its stored identity")

  state:updateFixed({ { type = "action", action = "markings" } })
  local cancelledPlan = state._session:plan()
  local markingTap = cancelledPlan.mapInput({ type = "pointer_down", x = 121, y = 9 }, state:_view(), cancelledPlan)
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

    state:updateFixed({ { type = "confirm" } })
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

function T.completed_release_scan_includes_the_last_box_and_respects_first_move_order()
  local mons = releaseService()
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))
  local released = finishReleaseScan(state)
  Assert.equal(released.total, 37 * 30 + 6)
  Assert.equal(released.outcome, "removed", "the duplicate Surf in box 36 permits removal")
  Assert.equal(mons:partyCount(), 1)
  Assert.notNil(mons:boxMon(36, 29), "release never moves the alternative holder")
  state:dispose()

  local reversed = releaseService()
  reversed:setMove(0, 1, "TACKLE")
  reversed:setMove(0, 0, "FLY")
  reversed:setMove(0, 1, "SURF")
  local reverseState = PcStorageState.new(openOptions(reversed, 2, "wide"))
  local returned = finishReleaseScan(reverseState)
  Assert.equal(returned.outcome, "returned", "first matching Fly controls the source guard")
  Assert.equal(reversed:partyCount(), 2, "returned Pokemon retains party custody")
  reverseState:dispose()
end

return { tests = T }
