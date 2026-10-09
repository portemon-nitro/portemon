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
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
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
      x, y = LayoutGeometry.logicalToHost(
        placement,
        rect.x + rect.width / 2,
        rect.y + rect.height / 2
      )
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
      dispose = function() end,
    }
  end
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
      dispose = function() end,
    }
  end
  local items = PcStorageState.new(options)
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
  Assert.isTrue(confirmed, "Deposit confirmation uses the focused empty slot instead of the occupied initial slot: "
    .. tostring(failure))
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
  state:updateFixed({ { type = "storage_target", target = { kind = "box", slot = 0 } } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.deepEqual(state:status().focus, { domain = "box", slot = 1 }, "controller input advances the Box focus")
  local confirmed, failure = pcall(function()
    state:updateFixed({ { type = "confirm" } })
  end)
  Assert.isTrue(confirmed, "Deposit confirmation follows controller focus to the empty Box slot: " .. tostring(failure))
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
  local state = PcStorageState.new(openOptions(mons, 0, "nativeLike"))
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
  Assert.deepEqual(state:status().focus, { domain = "party", slot = 0 }, "parent focus is untouched while the child owns input")
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
  local state = PcStorageState.new(openOptions(mons, 0, "nativeLike"))
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

function T.active_markings_editor_masks_box_slot_pointer_input()
  local mons = monService()
  local boxed = mons:partyMon(0)
  boxed.markings = 5
  local change = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 7, mon = boxed } } }))
  change.publish()

  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
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
  rawPointerAt(state, markingPlan.content.hitRegions.editorChoices[2].rect, "marking-choice")
  Assert.equal(state:status().editor.mask, 7, "raw pointer input toggles a local marking choice")
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
  Assert.isNil(lockedTap, "locked bonus wallpaper has no pointer selection")
  rawPointerAt(state, plan.content.hitRegions.editorChoices[1].rect, "wallpaper-choice")
  Assert.equal(state:status().editor.selected, 1, "raw pointer input selects a local wallpaper choice")
  state:updateFixed({ { type = "wallpaper_choice", id = 16 } })
  Assert.equal(state:status().editor.selected, 1, "locked bonus wallpaper preserves the current selection")
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
  local state = PcStorageState.new(openOptions(mons, 0, "wide"))
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
    local mons = releaseService()
    mons:setMove(0, 1, "TACKLE")
    mons:setMove(0, 0, "FLY")
    mons:setMove(0, 1, "SURF")
    return mons
  end
  local function settle(state)
    state:updateFixed({ { type = "confirm" } })
    local check = state:status().releaseCheck
    local ticks = 1
    local maximumTicks = math.ceil(check.total / 15)
    while check.outcome == "pending" do
      Assert.isTrue(ticks < maximumTicks, "protected scan completes within the candidate count")
      state:updateFixed({})
      ticks = ticks + 1
      check = state:status().releaseCheck
    end
    return check, ticks, maximumTicks
  end

  local menuMons = protectedService()
  local menuState = PcStorageState.new(openOptions(menuMons, 2, "wide"))
  menuState:updateFixed({ { type = "action", action = "release" } })
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
    state:updateFixed({ { type = "confirm" } })
    local check = state:status().releaseCheck
    local maximumTicks = math.ceil(check.total / 15)
    local ticks = 1
    while check.outcome == "pending" do
      Assert.isTrue(ticks < maximumTicks, "removal scan completes within the candidate count")
      state:updateFixed({})
      ticks = ticks + 1
      check = state:status().releaseCheck
    end
    return check
  end

  local menuMons = releaseService()
  local menuState = PcStorageState.new(openOptions(menuMons, 2, "wide"))
  menuState:updateFixed({ { type = "action", action = "release" } })
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
  menuCancel:updateFixed({ { type = "action", action = "release" } })
  menuCancel:updateFixed({ { type = "confirm" } })
  Assert.equal(menuCancel:status().releaseCheck.outcome, "pending")
  menuCancel:updateFixed({ { type = "cancel" } })
  Assert.equal(menuCancel:status().releaseCheck.outcome, "cancelled", "menu cancel stops the scan")
  Assert.equal(menuCancelMons:partyCount(), 2, "menu cancel never removes")
  menuCancel:dispose()

  local eventCancelMons = releaseService()
  local eventCancel = PcStorageState.new(openOptions(eventCancelMons, 2, "wide"))
  eventCancel:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
  eventCancel:updateFixed({ { type = "confirm" } })
  eventCancel:updateFixed({ { type = "cancel" } })
  Assert.equal(eventCancel:status().releaseCheck.outcome, "cancelled")
  Assert.equal(eventCancelMons:partyCount(), 2, "mapped cancel never removes")
  eventCancel:dispose()

  local menuStaleMons = releaseService()
  local menuStale = PcStorageState.new(openOptions(menuStaleMons, 2, "wide"))
  menuStale:updateFixed({ { type = "action", action = "release" } })
  menuStale:updateFixed({ { type = "confirm" } })
  local drifting = menuStaleMons:partyMon(1)
  drifting.heldItem = "SITRUS_BERRY"
  local preparation = assert(menuStaleMons:preparePartyChanges(menuStaleMons:partyRevision(), { { slot = 1, mon = drifting } }))
  preparation.publish()
  menuStale:updateFixed({})
  Assert.equal(menuStale:status().releaseCheck.outcome, "stale", "menu revision drift cancels the scan")
  Assert.equal(menuStaleMons:partyCount(), 2, "menu stale scan retains the selected mon")
  menuStale:dispose()

  local armed = PcStorageState.new(openOptions(releaseService(), 2, "wide"))
  armed:updateFixed({ { type = "action", action = "release" } })
  Assert.equal(armed:status().releaseCheck.outcome, "confirm")
  local secondMenu = pcall(function()
    armed:updateFixed({ { type = "action", action = "release" } })
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
  state:updateFixed({ { type = "confirm" } })
  local check = state:status().releaseCheck
  local maximumTicks = math.ceil(check.total / 15)
  local ticks = 1
  while check.outcome == "pending" do
    Assert.isTrue(ticks < maximumTicks, "release scan completes within the candidate count")
    state:updateFixed({})
    ticks = ticks + 1
    check = state:status().releaseCheck
  end
  Assert.equal(ticks, maximumTicks, "the scan visits fifteen addresses on each fixed tick")
  return check, ticks, maximumTicks
end

function T.sequential_confirmed_removals_share_one_storage_lifetime()
  local mons = releaseService()
  local factory = CatalogFixture.makeFactory(0x5EED01, mons:catalog())
  for _ = 1, 2 do
    Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  end
  Assert.equal(mons:partyCount(), 4, "both added members join the party before the first release")
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))

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
  local mons = releaseService()
  mons:setMove(0, 1, "TACKLE")
  mons:setMove(0, 0, "FLY")
  mons:setMove(0, 1, "SURF")
  local factory = CatalogFixture.makeFactory(0x5EED02, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  Assert.equal(mons:partyCount(), 3)
  local protectedBefore = mons:partyMon(0)
  local state = PcStorageState.new(openOptions(mons, 2, "wide"))

  state:updateFixed({ { type = "action", action = "release" } })
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
    state:updateFixed({ { type = "action", action = "release" } })
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

  state:updateFixed({ { type = "confirm" } })
  local pending = state:status().releaseCheck
  Assert.equal(pending.outcome, "pending")
  Assert.equal(pending.scanned, 15, "confirmation starts the scan before the overlap retry")
  local scanningPartyRevision = mons:partyRevision()
  local scanningBoxRevision = mons:boxRevision()
  local scanningMenu, scanningMenuError = pcall(function()
    state:updateFixed({ { type = "action", action = "release" } })
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
  Assert.equal(check.outcome, "removed", "the first scan completes normally after rejection")
  Assert.equal(mons:partyCount(), 1)
  state:dispose()
end

function T.cancelled_and_stale_scans_admit_fresh_releases_without_replay()
  do
    local mons = releaseService()
    local state = PcStorageState.new(openOptions(mons, 2, "wide"))
    state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
    Assert.equal(state:status().releaseCheck.outcome, "confirm")
    state:updateFixed({ { type = "confirm" } })
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
    state:updateFixed({ { type = "release", address = { kind = "party", slot = 0 } } })
    Assert.equal(state:status().releaseCheck.outcome, "confirm")
    state:updateFixed({ { type = "confirm" } })
    Assert.equal(state:status().releaseCheck.outcome, "pending")
    local drifting = mons:partyMon(1)
    drifting.heldItem = "SITRUS_BERRY"
    local preparation =
      assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = drifting } }))
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
    local state = PcStorageState.new(openOptions(mons, 0, configuration))
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
    state:updateFixed({ { type = "navigate", direction = "right" } })
    Assert.equal(builds, switchedBuilds + 1, configuration .. ": a box switch publishes once")
    Assert.equal(resolves, switchedResolves + 1, configuration .. ": a box switch resolves once")
    Assert.equal(state:status().activeBox, 1)
    Assert.equal(state:status().boxSlots[7], false, "the new box shows its own empty slot, not stale contents")
    Assert.deepEqual(state:status().focus, { domain = "box", slot = 0 })
    state:updateFixed({ { type = "storage_target", target = { kind = "party", slot = 0 } } })
    state:updateFixed({ { type = "confirm" } })
    Assert.equal(state:status().phase, "menu")
    local beforeMarkings = mons:partyMon(0).markings
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
    Assert.equal(mons:partyMon(0).markings, beforeMarkings, "cancel discards the editor draft")
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

return { tests = T }
