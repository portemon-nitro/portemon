-- Transaction tests run over the real Bag service and detached resolved stock.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local BagSave = require("libs.hgss.src.save.BagSave")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartService = require("libs.hgss.src.items.MartService")

local T = {}

local function resources(options)
  options = options or {}
  local root = ItemFixture.buildAssetRoot()
  root.items.POTION.price = 301
  root.items.PREMIER_BALL = root.items.ITEM_5
  root.items.ITEM_5 = nil
  local itemCatalog = ItemCatalog.new(root)
  local bag = HgssBagService.new({ catalog = itemCatalog, bag = options.bag or BagSave.empty() })
  local martCatalog = {
    cards = {},
    apricorns = { RED_APRICORN = "red" },
    seals = { SEAL_A = { displayItemKey = "ITEM_0", description = "A" } },
  }
  for index = 0, 26 do
    local key = "CARD_" .. index
    martCatalog.cards[key] = { itemKey = "ITEM_" .. (index + 30), ownershipIndex = index }
  end
  local profile = { money = options.money or 1000, badges = 0, nationalDex = false }
  local service = MartService.new({
    profile = profile,
    bag = bag,
    itemCatalog = itemCatalog,
    catalog = martCatalog,
    bucket = options.bucket or MartSave.empty(),
  })
  return { bag = bag, catalog = martCatalog, itemCatalog = itemCatalog, profile = profile, service = service }
end

local function stock(entries, overrides)
  local result = {
    key = "custom-test-stock",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = entries,
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

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

local function today(year, month, day)
  return { year = year, month = month, day = day }
end

local function prefixMask(prefix)
  local mask = 0
  for index = 0, prefix - 1 do
    mask = mask + 2 ^ index
  end
  return mask
end

function T.open_stock_is_copied_and_free_quotes_do_not_divide_by_zero()
  local state = resources({ money = 1000 })
  local input = stock({ bagEntry("cheap", 7), bagEntry("same-item", 22), bagEntry("free", 0) })
  local session = state.service:openBuy(input)
  input.entries[1].unitPrice = 900
  input.entries[1].key = "mutated"

  local view = session:view()
  Assert.equal(view.entries[1].entryKey, "cheap")
  Assert.equal(view.entries[1].unitPrice, 7)
  Assert.equal(view.entries[2].entryKey, "same-item")
  Assert.equal(view.entries[3].maxQuantity, 99)
  local token, terms = session:quoteBuy("free", 99)
  Assert.notNil(token)
  Assert.equal(terms.total, 0)
  Assert.equal(terms.quantity, 99)
  Assert.equal(state.profile.money, 1000, "quote staging never changes the wallet")
  Assert.equal(state.bag:quantity("POTION"), 0, "quote staging never changes Bag")
end

function T.buy_view_exposes_detached_presentation_and_display_bindings()
  local state = resources({ money = 1000 })
  local session = state.service:openBuy(stock({ bagEntry("potion-offer", 100) }))
  local view = session:view()
  Assert.equal(view.presentationKind, "items")
  Assert.equal(view.quantityMode, "multiple")
  Assert.equal(view.entries[1].entryKey, "potion-offer")
  Assert.deepEqual(view.entries[1].description, { kind = "item" }, "the semantic description remains available")
  Assert.equal(view.entries[1].descriptionText, "Potion description")
  Assert.equal(view.entries[1].bindings.itemName, "Potion")
  Assert.equal(view.entries[1].bindings.pocketName, "Medicine")
  view.presentationKind = "legacy_decorations"
  view.entries[1].bindings.itemName = "changed"
  view.entries[1].descriptionText = "changed"
  local fresh = session:view()
  Assert.equal(fresh.presentationKind, "items", "the returned presentation record is detached")
  Assert.equal(fresh.entries[1].bindings.itemName, "Potion", "display bindings are detached")
  Assert.equal(fresh.entries[1].descriptionText, "Potion description", "description text is detached")
  session:close()
end

function T.commit_is_atomic_idempotent_and_old_or_foreign_tokens_reject()
  local first = resources({ money = 1000 })
  local second = resources({ money = 1000 })
  local session = first.service:openBuy(stock({ bagEntry("offer", 12) }))
  local token = assert(session:quoteBuy("offer", 2))
  local receipt = assert(session:commit(token))
  Assert.equal(first.profile.money, 976)
  Assert.equal(first.bag:quantity("POTION"), 2)
  Assert.equal(first.service:capture().statistics.currencySpent, 24)
  Assert.equal(session:commit(token), receipt, "retrying the current committed token returns the same receipt")
  Assert.equal(first.profile.money, 976, "idempotent retry does not charge twice")
  local foreign = second.service:openBuy(stock({ bagEntry("other", 1) }))
  local foreignToken = assert(foreign:quoteBuy("other", 1))
  local rejected, reason = session:commit(foreignToken)
  Assert.isNil(rejected)
  Assert.equal(reason, "stale")
  local nextToken = assert(session:quoteBuy("offer", 1))
  local oldReceipt
  oldReceipt, reason = session:commit(token)
  Assert.isNil(oldReceipt)
  Assert.equal(reason, "stale")
  Assert.notNil(session:commit(nextToken))
end

function T.mutable_receipt_fields_cannot_suppress_or_repeat_the_acknowledgement_bonus()
  local state = resources({ money = 6000 })
  local session = state.service:openBuy(stock({ bagEntry("balls", 200, "POKE_BALL") }, { bonusPolicy = "premier_ball" }))
  local token = assert(session:quoteBuy("balls", 10))
  local receipt = assert(session:commit(token))
  Assert.equal(state.bag:quantity("POKE_BALL"), 10)
  Assert.equal(state.bag:quantity("PREMIER_BALL"), 0, "the bonus waits for acknowledgement")

  receipt.bonusEligible = false
  receipt.acknowledged = true
  receipt.bonusGranted = false
  receipt.terms.total = -1
  local acknowledged = assert(session:acknowledge(receipt))
  Assert.isTrue(acknowledged.bonusGranted, "public receipt writes cannot change the private bonus decision")
  Assert.equal(state.bag:quantity("PREMIER_BALL"), 1)
  Assert.equal(state.service:capture().statistics.premierBallsEarned, 1)
  local retried = assert(session:acknowledge(receipt))
  Assert.isTrue(retried.bonusGranted)
  Assert.equal(state.bag:quantity("PREMIER_BALL"), 1, "acknowledgement replay cannot grant twice")
end

function T.stale_bag_and_balance_leave_the_post_drift_capture_unchanged()
  local state = resources({ money = 1000 })
  local session = state.service:openBuy(stock({ bagEntry("offer", 12) }))
  local token = assert(session:quoteBuy("offer", 2))
  Assert.isTrue(state.bag:add("GREAT_BALL", 1))
  local before = { bag = state.bag:capture(), profile = { money = state.profile.money }, mart = state.service:capture() }
  local receipt, reason = session:commit(token)
  Assert.isNil(receipt)
  Assert.equal(reason, "stale")
  Assert.deepEqual({ bag = state.bag:capture(), profile = { money = state.profile.money }, mart = state.service:capture() }, before)
  session:close()

  local balanceSession = state.service:openBuy(stock({ bagEntry("offer", 12) }))
  local balanceToken = assert(balanceSession:quoteBuy("offer", 2))
  state.profile.money = state.profile.money - 1
  local balanceBefore = { bag = state.bag:capture(), money = state.profile.money, mart = state.service:capture() }
  local balanceReceipt, balanceReason = balanceSession:commit(balanceToken)
  Assert.isNil(balanceReceipt)
  Assert.equal(balanceReason, "stale")
  Assert.deepEqual({ bag = state.bag:capture(), money = state.profile.money, mart = state.service:capture() }, balanceBefore)
end

function T.calendar_handles_leap_day_forward_reset_and_rollback_without_reset()
  local initial = MartSave.empty()
  initial.dailyPurchasedMask = 0x801
  local state = resources({ bucket = initial })
  local first = state.service:processDate(today(2024, 2, 28))
  Assert.equal(first.weekday, 3, "weekday uses Sunday as zero")
  Assert.equal(state.service:capture().dailyPurchasedMask, 0x801, "first observation preserves seeded purchases")
  local same = state.service:processDate(today(2024, 2, 28))
  Assert.equal(same.dayOrdinal, first.dayOrdinal)
  Assert.equal(state.service:capture().dailyPurchasedMask, 0x801)
  local leap = state.service:processDate(today(2024, 2, 29))
  Assert.equal(leap.dayOrdinal, first.dayOrdinal + 1)
  Assert.equal(leap.weekday, 4)
  Assert.equal(state.service:capture().dailyPurchasedMask, 0, "a forward date clears all daily slots")

  local later = state.service:capture()
  later.dailyPurchasedMask = 0x101
  local rollback = resources({ bucket = later })
  local result = rollback.service:processDate(today(2024, 2, 28))
  Assert.equal(result.weekday, 3)
  Assert.equal(rollback.service:capture().dailyPurchasedMask, 0x101, "rollback changes the baseline without resetting")
end

function T.card_progress_uses_the_first_missing_index_at_every_group_boundary()
  for _, prefix in ipairs({ 0, 5, 6, 11, 12, 23, 24, 26, 27 }) do
    local bucket = MartSave.empty()
    bucket.ownedDataCardsMask = prefixMask(prefix)
    local state = resources({ bucket = bucket })
    Assert.equal(state.service:cardPrefix(), prefix)
  end
end

function T.ap_spend_apricorn_daily_slots_and_data_card_ownership_share_one_bucket()
  local bucket = MartSave.empty()
  bucket.athletePoints = 10
  bucket.apricorns.RED_APRICORN = 98
  local state = resources({ bucket = bucket })
  state.service:processDate(today(2024, 3, 1))
  local athlete = stock({
    {
      key = "daily-red",
      displayItemKey = "POTION",
      description = { kind = "item" },
      unitPrice = 3,
      destination = { kind = "apricorn", key = "RED_APRICORN" },
      restriction = { kind = "daily_slot", slot = 1 },
    },
    {
      key = "points-item",
      displayItemKey = "POTION",
      description = { kind = "item" },
      unitPrice = 2,
      destination = { kind = "bag", key = "POTION" },
      restriction = { kind = "daily_slot", slot = 7 },
    },
  }, { key = "athlete-test", currency = "athlete_points", presentationKind = "athlete_items", quantityMode = "single" })
  Assert.isTrue(state.service:athleteAvailable(athlete))
  local first = state.service:openBuy(athlete)
  local apricornToken = assert(first:quoteBuy("daily-red", 1))
  Assert.notNil(first:commit(apricornToken))
  Assert.equal(state.service:capture().apricorns.RED_APRICORN, 99)
  Assert.equal(state.service:capture().athletePoints, 7)
  first:close()

  local second = state.service:openBuy(athlete)
  local itemToken = assert(second:quoteBuy("points-item", 1))
  Assert.notNil(second:commit(itemToken))
  Assert.equal(state.bag:quantity("POTION"), 1)
  Assert.equal(state.service:capture().athletePoints, 5)
  Assert.equal(state.service:capture().dailyPurchasedMask, 0x82)
  Assert.isFalse(state.service:athleteAvailable(athlete), "availability compares against every one of 12 daily slots")
  second:close()

  local cardStock = stock({ {
    key = "card-zero",
    displayItemKey = "ITEM_30",
    description = { kind = "item" },
    unitPrice = 4,
    destination = { kind = "card", key = "CARD_0" },
    restriction = { kind = "owned_card", key = "CARD_0" },
    capacityProbe = { kind = "bag", key = "CHERI_BERRY" },
  } }, { key = "card-test", currency = "athlete_points", presentationKind = "athlete_cards", quantityMode = "single" })
  local cards = state.service:openBuy(cardStock)
  local cardToken = assert(cards:quoteBuy("card-zero", 1))
  Assert.notNil(cards:commit(cardToken))
  local captured = state.service:capture()
  Assert.equal(captured.athletePoints, 1)
  Assert.equal(captured.ownedDataCardsMask, 1)
  Assert.equal(state.bag:quantity("ITEM_30"), 0, "Data Card ownership does not grant its capacity probe")
  Assert.equal(captured.statistics.currencySpent, 9, "AP transactions contribute to currency-spent statistics")
  Assert.equal(cards:view().entries[1].selectionFailure, "already_owned")
  local repeated, repeatedReason = cards:quoteBuy("card-zero", 1)
  Assert.isNil(repeated)
  Assert.equal(repeatedReason, "already_owned")
  cards:close()

  local full = resources({ bucket = (function()
    local seeded = MartSave.empty()
    seeded.athletePoints = 10
    return seeded
  end)() })
  local itemKeys = {}
  for key, definition in pairs(ItemFixture.buildAssetRoot().items) do
    if definition.pocket == "berries" then itemKeys[#itemKeys + 1] = key end
  end
  table.sort(itemKeys)
  for _, itemKey in ipairs(itemKeys) do
    Assert.isTrue(full.bag:add(itemKey, 1), "fill each distinct Berry pocket slot")
  end
  Assert.equal(#full.bag:pocketItems("berries"), 64)
  Assert.isTrue(full.bag:add("CHERI_BERRY", 998), "fill the probe item's stack so no Bag capacity remains")
  local fullCard = full.service:openBuy(cardStock)
  local fullToken, fullReason = fullCard:quoteBuy("card-zero", 1)
  Assert.isNil(fullToken)
  Assert.equal(fullReason, "bag_full", "the source Bag capacity probe still governs Data Card purchase")
  Assert.equal(full.service:capture().athletePoints, 10)
  Assert.equal(full.service:capture().ownedDataCardsMask, 0)
end

function T.seal_capacity_counts_loose_and_all_equipped_copies()
  local bucket = MartSave.empty()
  bucket.sealCase.loose.SEAL_A = 98
  bucket.sealCase.capsules[12][1] = { key = "SEAL_A", x = 4, y = 5 }
  local state = resources({ bucket = bucket })
  local seals = stock({ {
    key = "seal-a",
    displayItemKey = "ITEM_1",
    description = { kind = "literal", value = "Seal A" },
    unitPrice = 100,
    destination = { kind = "seal", key = "SEAL_A" },
    restriction = { kind = "none" },
  } }, { key = "seal-test", presentationKind = "seals" })
  local session = state.service:openBuy(seals)
  local token, reason = session:quoteBuy("seal-a", 1)
  Assert.isNil(token)
  Assert.equal(reason, "seal_full")
  Assert.equal(state.profile.money, 1000)
  Assert.equal(state.service:capture().sealCase.loose.SEAL_A, 98)
  Assert.equal(state.service:capture().sealCase.capsules[12][1].key, "SEAL_A")
end

function T.capacity_is_checked_after_quantity_selection_and_sales_clamp_wallet()
  local state = resources({ money = 1000 })
  Assert.isTrue(state.bag:add("POTION", 990))
  local session = state.service:openBuy(stock({ bagEntry("offer", 1) }))
  Assert.equal(session:view().entries[1].maxQuantity, 99, "visible maximum is affordability limited, not capacity limited")
  local token, terms = session:quoteBuy("offer", 10)
  Assert.isNil(token)
  Assert.equal(terms, "bag_full")
  Assert.equal(state.profile.money, 1000)
  Assert.equal(state.bag:quantity("POTION"), 990)
  session:close()

  state.profile.money = 999950
  local selling = state.service:openSell()
  local sellToken, sellTerms = selling:quoteSell("POTION", 1)
  Assert.notNil(sellToken)
  Assert.equal(sellTerms.total, 150, "resale is floor(301/2) per sold item")
  Assert.notNil(selling:commit(sellToken))
  Assert.equal(state.profile.money, 999999, "wallet clamps while the full sale is removed")
  Assert.equal(state.bag:quantity("POTION"), 989)
  Assert.equal(state.service:capture().statistics.currencySpent, 0, "selling does not count as currency spent")
end

function T.owner_mutations_reuse_saved_state_without_whole_bucket_validation()
  local state = resources({ money = 1000 })
  state.service:processDate(today(2024, 3, 1))
  local calls = 0
  local original = MartSave.validate
  MartSave.validate = function(...)
    calls = calls + 1
    return original(...)
  end
  local function finish()
    MartSave.validate = original
    return calls
  end

  local baseline = state.service:capture()
  Assert.deepEqual(state.service:capture(), baseline, "captures of untouched owner state are stable")

  local daily = stock({
    {
      key = "daily-potion",
      displayItemKey = "POTION",
      description = { kind = "item" },
      unitPrice = 10,
      destination = { kind = "bag", key = "POTION" },
      restriction = { kind = "daily_slot", slot = 3 },
    },
    bagEntry("offer", 12),
  })
  local session = state.service:openBuy(daily)
  local token = assert(session:quoteBuy("daily-potion", 1))
  Assert.notNil(session:commit(token))
  Assert.equal(state.profile.money, 990, "the committed purchase deducts its exact total")
  Assert.equal(state.bag:quantity("POTION"), 1)
  Assert.equal(state.service:capture().dailyPurchasedMask, 8, "the daily slot records its exact bit")

  local repeated, repeatReason = session:quoteBuy("daily-potion", 1)
  Assert.isNil(repeated)
  Assert.equal(repeatReason, "bought_today", "the daily restriction still binds owner state")
  local afforded, affordReason = session:quoteBuy("offer", 99)
  Assert.isNil(afforded)
  Assert.equal(affordReason, "insufficient_money", "the balance check still binds owner state")
  session:close()

  state.service:processDate(today(2024, 3, 2))
  Assert.equal(
    state.service:capture().dailyPurchasedMask,
    0,
    "a forward date clears the daily slots without touching ownership"
  )
  local nextDay = state.service:openBuy(daily)
  Assert.notNil(nextDay:quoteBuy("daily-potion", 1), "the cleared slot is purchasable again")
  nextDay:close()

  Assert.equal(finish(), 0, "owner capture and controlled mutations must not revalidate the whole bucket")
  Assert.notNil(
    MartSave.validate(state.service:capture(), state.catalog),
    "explicit mart validation still accepts the published capture"
  )
end

function T.gregorian_century_rules_reject_invalid_dates_and_process_forward_days()
  local commonYear = resources()
  local february = commonYear.service:processDate(today(1900, 2, 28))
  local march = commonYear.service:processDate(today(1900, 3, 1))
  Assert.equal(march.dayOrdinal, february.dayOrdinal + 1, "1900 is not a leap year")

  local leapCentury = resources()
  local februaryLeap = leapCentury.service:processDate(today(2000, 2, 28))
  local leapDay = leapCentury.service:processDate(today(2000, 2, 29))
  Assert.equal(leapDay.dayOrdinal, februaryLeap.dayOrdinal + 1, "2000 is a leap year")
  local marchLeap = leapCentury.service:processDate(today(2000, 3, 1))
  Assert.equal(marchLeap.dayOrdinal, leapDay.dayOrdinal + 1)
  Assert.throws(function() leapCentury.service:processDate(today(1900, 2, 29)) end)
end

return { tests = T }
