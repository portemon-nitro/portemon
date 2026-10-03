-- Sale sessions use the real Bag and canonical profile; staging and refusing
-- a sale leave both owners unchanged, while commit removes the quoted stack.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local BagSave = require("libs.hgss.src.save.BagSave")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local MartSave = require("libs.hgss.src.save.MartSave")
local MartService = require("libs.hgss.src.items.MartService")
local PlayerData = require("libs.hgss.src.save.PlayerData")

local T = {}

local function resources(money)
  local root = ItemFixture.buildAssetRoot()
  root.items.POTION.price = 301
  root.items.BICYCLE.price = 1000
  root.items.ITEM_1.price = 1
  local itemCatalog = ItemCatalog.new(root)
  local bag = HgssBagService.new({ catalog = itemCatalog, bag = BagSave.empty() })
  local profile = { money = money, badges = 0, nationalDex = false }
  local service = MartService.new({
    profile = profile,
    bag = bag,
    itemCatalog = itemCatalog,
    catalog = { cards = {}, apricorns = {}, seals = {}, decorations = {} },
    bucket = MartSave.empty(),
  })
  return { bag = bag, itemCatalog = itemCatalog, profile = profile, service = service }
end

local function snapshot(state)
  return {
    bag = state.bag:capture(),
    money = state.profile.money,
    mart = state.service:capture(),
  }
end

function T.protected_and_free_items_refuse_without_changing_the_real_state()
  local state = resources(1000)
  Assert.isTrue(state.bag:add("BICYCLE", 1))
  Assert.isTrue(state.bag:add("ITEM_1", 1))
  local session = state.service:openSell()
  local before = snapshot(state)

  local protected, protectedReason = session:quoteSell("BICYCLE", 1)
  Assert.isNil(protected)
  Assert.equal(protectedReason, "not_sellable", "preventToss blocks sale even with a positive price")
  local free, freeReason = session:quoteSell("ITEM_1", 1)
  Assert.isNil(free)
  Assert.equal(freeReason, "not_sellable", "price 1 has no resale value after per-unit flooring")
  Assert.deepEqual(snapshot(state), before, "both refusal paths preserve inventory and profile data")
  session:close()
end

function T.a_bag_revision_change_stales_a_sale_quote_without_partial_publication()
  local state = resources(1000)
  Assert.isTrue(state.bag:add("POTION", 2))
  local session = state.service:openSell()
  local token, terms = session:quoteSell("POTION", 1)
  Assert.notNil(token)
  Assert.equal(terms.total, 150)

  Assert.isTrue(state.bag:add("GREAT_BALL", 1), "an unrelated Bag update advances its revision")
  local beforeCommit = snapshot(state)
  local receipt, reason = session:commit(token)
  Assert.isNil(receipt)
  Assert.equal(reason, "stale")
  Assert.deepEqual(snapshot(state), beforeCommit, "a stale sale changes neither money nor any Bag slot")
  Assert.equal(state.bag:quantity("POTION"), 2)
  session:close()
end

function T.wallet_cap_keeps_the_full_confirmed_quantity_sale()
  local state = resources(PlayerData.MAX_MONEY - 100)
  Assert.isTrue(state.bag:add("POTION", 3))
  local session = state.service:openSell()
  local token, terms = session:quoteSell("POTION", 3)
  Assert.notNil(token)
  Assert.equal(terms.total, 450, "three units receive 150 each")

  Assert.notNil(session:commit(token))
  Assert.equal(state.profile.money, PlayerData.MAX_MONEY, "credited money clamps at the profile maximum")
  Assert.equal(state.bag:quantity("POTION"), 0, "wallet clamping does not reduce the sold quantity")
  Assert.equal(state.service:capture().statistics.currencySpent, 0, "selling does not count as currency spent")
  session:close()
end

function T.closing_with_a_staged_sale_quote_cancels_without_committing()
  local state = resources(1000)
  Assert.isTrue(state.bag:add("POTION", 2))
  local session = state.service:openSell()
  local beforeQuote = snapshot(state)
  local token, terms = session:quoteSell("POTION", 1)
  Assert.notNil(token)
  Assert.equal(terms.total, 150)
  Assert.deepEqual(snapshot(state), beforeQuote, "quote staging is not a sale commit")

  session:close()
  Assert.deepEqual(snapshot(state), beforeQuote, "closing the owner discards its uncommitted sale")
  Assert.isTrue(state.bag:has("POTION", 2))
end

return { tests = T }
