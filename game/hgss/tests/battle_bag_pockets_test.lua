-- Battle-pocket grouping: field stock sorts into retail battle pockets by
-- the 5-bit battlePocket mask via sBattleBagPocketOrder [2,3,0,1,0]
-- (battle_bag_menu.c AddItemToBattlePockets, battle_menu_data.s:2181).
-- bit0->BALLS(2), bit1->BATTLE ITEMS(3), bit2->HP/PP(0), bit3->STATUS(1),
-- bit4->HP/PP(0). Mask 0 stays hidden in battle. Within-pocket order
-- follows the carried saved-bag slot order (SortItemsIntoPockets
-- appends in bag-slot order); stock without a carried order keeps the
-- deterministic native-id stand-in.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")

local BattleBagPockets = require("game.hgss.src.battle.BattleBagPockets")

local T = {}

function T.field_stock_sorts_into_battle_pockets_with_hidden_excluded()
  local catalog = ItemFixture.makeCatalog()
  local groups = BattleBagPockets.group({ POTION = 5, POKE_BALL = 3, SMOKE_BALL = 1, CHERI_BERRY = 2, SOOTHE_BELL = 1 }, catalog)
  local function keys(list)
    local out = {}
    for _, entry in ipairs(list) do
      out[#out + 1] = entry.item
    end
    return out
  end
  Assert.deepEqual(keys(groups.hp_pp), { "POTION" })
  Assert.deepEqual(keys(groups.status), { "CHERI_BERRY" })
  Assert.deepEqual(keys(groups.balls), { "POKE_BALL" })
  Assert.deepEqual(keys(groups.battle_items), { "SMOKE_BALL" })
end

function T.multi_bit_items_appear_in_each_mapped_pocket_without_invented_quantities()
  local catalog = ItemFixture.makeCatalog()
  local groups = BattleBagPockets.group({ POTION = 5 }, catalog)
  -- POTION mask 4 (bit2) maps to HP/PP only; a synthetic multi-bit mask
  -- is exercised through the direct mask entry point.
  local pockets = BattleBagPockets.pocketsForMask(3, catalog)
  Assert.deepEqual(pockets, { 2, 3 })
  Assert.equal(#groups.hp_pp, 1)
  Assert.equal(groups.hp_pp[1].quantity, 5)
end

function T.hit_testing_matches_the_retail_hitbox_order()
  local pockets = BattleBagPockets.HITBOXES
  Assert.equal(#pockets.pocketMenu, 6, "the pocket menu keeps six hitboxes")
  Assert.equal(#pockets.itemList, 9, "the item list keeps nine hitboxes")
  Assert.equal(#pockets.useItem, 2, "the use-item page keeps two hitboxes")
  Assert.equal(BattleBagPockets.hitIndex(pockets.pocketMenu, 191, 43), 2, "upper-right taps the balls pocket")
  Assert.equal(BattleBagPockets.hitIndex(pockets.itemList, 63, 31), 0, "upper-left taps the first cell")
  Assert.equal(BattleBagPockets.hitIndex(pockets.useItem, 103, 171), 0, "the wide button taps USE")
  Assert.isNil(BattleBagPockets.hitIndex(pockets.pocketMenu, 300, 300), "outside taps hit nothing")
  -- Retail hit testing is an unsigned range check (touchscreen.c
  -- FindRectAtPoint): taps above or left of a box never hit it, even
  -- when they fall inside its width/height span.
  Assert.isNil(
    BattleBagPockets.hitIndex(pockets.pocketMenu, 200, 0),
    "taps above the balls button hit nothing"
  )
  Assert.isNil(
    BattleBagPockets.hitIndex(pockets.itemList, 127, 31),
    "taps left of the second cell hit nothing"
  )
  Assert.equal(
    BattleBagPockets.hitIndex(pockets.pocketMenu, 200, 43),
    2,
    "taps inside the balls button still hit"
  )
  local regions = BattleBagPockets.hitRegions("pocket_menu")
  Assert.equal(#regions, 6, "the pocket menu exposes six regions")
  Assert.equal(regions[3].id, "bagpocket:2", "regions name pockets in hitbox order")
  Assert.equal(regions[3].x, 128, "regions carry the transcribed geometry")
  local listed = BattleBagPockets.hitRegions("item_list")
  Assert.equal(#listed, 9, "the item list exposes cells plus cancel and page steppers")
  Assert.equal(listed[8].id, "page_prev", "the page steppers resolve in order")
  local use = BattleBagPockets.hitRegions("use_item")
  Assert.deepEqual({ use[1].id, use[2].id }, { "use", "back" }, "the use-item page exposes USE and cancel")
end

function T.within_pocket_order_follows_native_id()
  local catalog = ItemFixture.makeCatalog()
  local groups = BattleBagPockets.group({ SITRUS_BERRY = 1, POTION = 1, ETHER = 1 }, catalog)
  -- POTION(17) < ETHER(49) < SITRUS(158): all bit2 HP/PP, native-id order.
  Assert.deepEqual({ groups.hp_pp[1].item, groups.hp_pp[2].item, groups.hp_pp[3].item }, {
    "POTION",
    "ETHER",
    "SITRUS_BERRY",
  })
end

function T.within_pocket_order_follows_the_carried_slot_order()
  local catalog = ItemFixture.makeCatalog()
  local stock = { SITRUS_BERRY = 1, POTION = 1, ETHER = 1 }
  local groups = BattleBagPockets.group(stock, catalog, { "SITRUS_BERRY", "ETHER", "POTION" })
  Assert.deepEqual({ groups.hp_pp[1].item, groups.hp_pp[2].item, groups.hp_pp[3].item }, {
    "SITRUS_BERRY",
    "ETHER",
    "POTION",
  }, "the carried bag order wins over native ids")
end

function T.icon_draws_follow_the_visible_browser_page()
  local listed = BattleBagPockets.iconDraws({
    open = true,
    bagPage = "item_list",
    visibleSlots = {
      { item = "POTION" },
      { empty = true },
      { item = "POKE_BALL" },
    },
  })
  Assert.equal(#listed, 2, "empty cells draw no icon")
  Assert.deepEqual(listed[1], { key = "POTION", x = 44, y = 45 })
  Assert.deepEqual(listed[2], { key = "POKE_BALL", x = 44, y = 93 })
  local lastUsed = BattleBagPockets.iconDraws({
    open = true,
    bagPage = "pocket_menu",
    lastUsed = { item = "POTION", pocket = 0 },
  })
  Assert.deepEqual(lastUsed, { { key = "POTION", x = 24, y = 178 } })
  local useItem = BattleBagPockets.iconDraws({
    open = true,
    bagPage = "use_item",
    useItem = { item = "POTION" },
  })
  Assert.deepEqual(useItem, { { key = "POTION", x = 40, y = 44 } })
  local message = BattleBagPockets.iconDraws({
    open = true,
    bagPage = "message",
    useItem = { item = "POTION" },
  })
  Assert.deepEqual(message, { { key = "POTION", x = 40, y = 44 } })
  Assert.deepEqual(BattleBagPockets.iconDraws({ open = false }), {}, "closed browsers draw no icon")
  Assert.deepEqual(
    BattleBagPockets.iconDraws({ open = true, bagPage = "pocket_menu" }),
    {},
    "no last-used item draws no icon"
  )
end

function T.finger_draws_follow_the_tutorial_browser_page()
  Assert.deepEqual(
    BattleBagPockets.fingerDraw({ open = true, tutorial = true, bagPage = "pocket_menu" }),
    { key = "battle:finger", x = 192, y = 24 }
  )
  Assert.deepEqual(
    BattleBagPockets.fingerDraw({ open = true, tutorial = true, bagPage = "item_list" }),
    { key = "battle:finger", x = 64, y = 16 }
  )
  Assert.deepEqual(
    BattleBagPockets.fingerDraw({ open = true, tutorial = true, bagPage = "use_item" }),
    { key = "battle:finger", x = 104, y = 152 }
  )
  Assert.isNil(
    BattleBagPockets.fingerDraw({ open = true, bagPage = "item_list" }),
    "interactive browsers draw no finger"
  )
  Assert.isNil(
    BattleBagPockets.fingerDraw({ open = false, tutorial = true, bagPage = "item_list" }),
    "closed browsers draw no finger"
  )
end

return { tests = T }
