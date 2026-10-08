-- Session stock projection behavior over the real Bag service and catalogs.

local Assert = require("tests.support.Assert")
local BagSave = require("libs.hgss.src.save.BagSave")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local ItemFixture = require("libs.items.tests.item_fixture")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartService = require("libs.hgss.src.items.MartService")

local T = {}

local function bagEntry(entryKey, price, itemKey)
  itemKey = itemKey or "POTION"
  return {
    key = entryKey,
    displayItemKey = itemKey,
    description = { kind = "item" },
    unitPrice = price,
    destination = { kind = "bag", key = itemKey },
    restriction = { kind = "none" },
  }
end

local function buildStock(count, price)
  local entries = {}
  for index = 1, count do
    entries[index] = bagEntry("offer-" .. index, price or 100)
  end
  return {
    key = "projection-stock",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = entries,
  }
end

local function openSession(options)
  options = options or {}
  local root = ItemFixture.buildAssetRoot()
  local items = ItemCatalog.new(root)
  local reads = { catalog = 0, bag = 0 }
  local rawItem = items.item
  items.item = function(self, key)
    reads.catalog = reads.catalog + 1
    return rawItem(self, key)
  end
  local bag = HgssBagService.new({ catalog = items, bag = options.bag or BagSave.empty() })
  local rawQuantity = bag.quantity
  bag.quantity = function(self, key)
    reads.bag = reads.bag + 1
    return rawQuantity(self, key)
  end
  local profile = { money = options.money or 1000, badges = 0, nationalDex = false }
  local service = MartService.new({
    profile = profile,
    bag = bag,
    itemCatalog = items,
    catalog = { cards = {}, apricorns = {}, seals = {}, decorations = {} },
    bucket = options.bucket or MartSave.empty(),
  })
  if options.date ~= nil then
    service:processDate(options.date)
  end
  local session = service:openBuy(options.stock or buildStock(4))
  reads.catalog, reads.bag = 0, 0
  return { service = service, bag = bag, profile = profile, session = session, reads = reads }
end

function T.repeated_views_share_one_projection_while_inputs_hold()
  local state = openSession({ money = 1000, stock = buildStock(4, 100) })
  local first = state.session:view()
  Assert.equal(#first.entries, 4)
  Assert.equal(first.balance, 1000)
  local builtCatalog, builtBag = state.reads.catalog, state.reads.bag
  Assert.isTrue(builtCatalog > 0, "the first view resolves catalog facts")

  local second = state.session:view()
  local third = state.session:view()
  Assert.deepEqual(second, first)
  Assert.deepEqual(third, first)
  Assert.equal(state.reads.catalog, builtCatalog, "idle views do not reread the catalog")
  Assert.equal(state.reads.bag, builtBag, "idle views do not reread Bag quantities")

  local selected = state.session:entryView(2)
  Assert.equal(selected.entryKey, "offer-2")
  Assert.equal(selected.unitPrice, 100)
  Assert.equal(state.reads.catalog, builtCatalog, "a selected-entry read does not traverse the catalog")
  Assert.equal(state.session:entryView(2).ownedQuantity, selected.ownedQuantity)
  state.session:close()
end

function T.each_live_input_advances_the_projection_generation()
  local state = openSession({ money = 1000, stock = buildStock(2, 100) })
  local key = state.session:projectionKey()
  Assert.equal(state.session:projectionKey(), key, "idle observations keep the generation")
  state.session:view()
  Assert.equal(state.session:projectionKey(), key, "repeated views keep the generation")

  state.profile.money = 950
  local afterMoney = state.session:projectionKey()
  Assert.isTrue(afterMoney ~= key, "a balance change alone advances the generation")
  local view = state.session:view()
  Assert.equal(view.balance, 950)
  Assert.equal(view.entries[1].maxQuantity, 9, "the maximum follows the live balance")
  key = afterMoney

  Assert.isTrue(state.bag:add("POTION", 3))
  Assert.isTrue(state.session:projectionKey() ~= key, "a Bag change advances the generation")
  Assert.equal(state.session:view().entries[1].ownedQuantity, 3)
  key = state.session:projectionKey()

  local token = assert(state.session:quoteBuy("offer-1", 1))
  Assert.notNil(state.session:commit(token))
  Assert.isTrue(state.session:projectionKey() ~= key, "a committed purchase advances the generation")
  Assert.equal(state.session:view().entries[1].ownedQuantity, 4)
  Assert.equal(state.profile.money, 850)
  state.session:close()
end

function T.day_rollover_clears_daily_slots_on_the_next_session()
  local state = openSession({ money = 1000, date = { year = 2024, month = 3, day = 1 } })
  state.session:close()
  local daily = {
    key = "daily-stock",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = {
      {
        key = "daily-potion",
        displayItemKey = "POTION",
        description = { kind = "item" },
        unitPrice = 10,
        destination = { kind = "bag", key = "POTION" },
        restriction = { kind = "daily_slot", slot = 3 },
      },
    },
  }
  local first = state.service:openBuy(daily)
  Assert.isNil(first:view().entries[1].selectionFailure)
  local token = assert(first:quoteBuy("daily-potion", 1))
  Assert.notNil(first:commit(token))
  Assert.equal(first:view().entries[1].selectionFailure, "bought_today")
  first:close()

  state.service:processDate({ year = 2024, month = 3, day = 2 })
  local second = state.service:openBuy(daily)
  Assert.isNil(second:view().entries[1].selectionFailure, "the new day clears the daily slot")
  second:close()
end

function T.stale_balances_fail_at_quote_and_commit_with_fresh_state()
  local state = openSession({ money = 250, stock = buildStock(1, 100) })
  local token = assert(state.session:quoteBuy("offer-1", 2))
  state.profile.money = 50
  local receipt, reason = state.session:commit(token)
  Assert.isNil(receipt)
  Assert.equal(reason, "stale", "the commit sees the live balance, not the quoted one")
  Assert.equal(state.session:view().balance, 50, "the display follows the live balance")
  local retry, retryReason = state.session:quoteBuy("offer-1", 2)
  Assert.isNil(retry)
  Assert.equal(retryReason, "insufficient_money")
  state.session:close()
end

function T.selected_entry_reads_are_narrow_detached_and_checked()
  local state = openSession({ money = 1000, stock = buildStock(4, 100) })
  state.session:view()
  local builtCatalog, builtBag = state.reads.catalog, state.reads.bag

  local entry = state.session:entryView(3)
  Assert.equal(entry.entryKey, "offer-3")
  Assert.equal(entry.bindings.itemName, "Potion")
  Assert.equal(state.reads.catalog, builtCatalog, "the selected read reuses the projection")
  Assert.equal(state.reads.bag, builtBag, "the selected read reuses the projection")

  entry.ownedQuantity = 99
  entry.bindings.itemName = "changed"
  entry.descriptionText = "changed"
  local reread = state.session:entryView(3)
  Assert.equal(reread.ownedQuantity, 0, "mutated entries cannot reach the retained projection")
  Assert.equal(reread.bindings.itemName, "Potion")
  Assert.equal(reread.descriptionText, "Potion description")
  Assert.equal(state.session:view().entries[3].ownedQuantity, 0)

  Assert.throws(function()
    state.session:entryView(0)
  end)
  Assert.throws(function()
    state.session:entryView(5)
  end)
  Assert.deepEqual(state.session:view().entries[3], reread, "rejected reads leave the projection intact")
  state.session:close()
end

function T.returned_views_are_detached_from_the_retained_projection()
  local state = openSession({ money = 1000, stock = buildStock(2, 100) })
  local view = state.session:view()
  view.balance = 1
  view.entries[1].ownedQuantity = 42
  view.entries[1].bindings.itemName = "changed"
  view.entries[1].descriptionText = "changed"
  view.entries[1].description.kind = "literal"
  local fresh = state.session:view()
  Assert.equal(fresh.balance, 1000)
  Assert.equal(fresh.entries[1].ownedQuantity, 0)
  Assert.equal(fresh.entries[1].bindings.itemName, "Potion")
  Assert.equal(fresh.entries[1].descriptionText, "Potion description")
  Assert.deepEqual(fresh.entries[1].description, { kind = "item" })
  state.session:close()
end

function T.sell_sessions_keep_a_live_balance_without_stock()
  local state = openSession({ money = 700 })
  state.session:close()
  local selling = state.service:openSell()
  local view = selling:view()
  Assert.equal(view.balance, 700)
  Assert.equal(#view.entries, 0)
  state.profile.money = 650
  Assert.equal(selling:view().balance, 650, "sell views track the live wallet")
  Assert.throws(function()
    selling:entryView(1)
  end)
  selling:close()
end

function T.close_releases_the_session_projection()
  local state = openSession({ money = 1000, stock = buildStock(2, 100) })
  state.session:view()
  state.session:close()
  state.session:close()
  Assert.throws(function()
    state.session:view()
  end)
  Assert.throws(function()
    state.session:entryView(1)
  end)
  Assert.throws(function()
    state.session:projectionKey()
  end)
end

return { tests = T }
