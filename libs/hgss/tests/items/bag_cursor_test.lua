-- Runtime-only field Bag cursor: current pocket plus per-pocket grid
-- position and scroll offset. The cursor never enters the persisted save;
-- reloading a runtime restarts it at its default while reopening the Bag in
-- one runtime keeps it.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {}

function T.cursor_starts_at_the_default_pocket_with_zero_offsets()
  local cursor = BagCursor.new()
  Assert.equal(cursor:currentPocket(), "items")
  for _, pocket in ipairs(BagSave.POCKET_ORDER) do
    Assert.equal(cursor:position(pocket), 0, "pocket " .. pocket .. " starts at position zero")
    Assert.equal(cursor:scroll(pocket), 0, "pocket " .. pocket .. " starts with no scroll")
  end
end

function T.cursor_remembers_per_pocket_offsets_across_pocket_switches()
  local cursor = BagCursor.new()
  cursor:setPosition("balls", 3)
  cursor:setScroll("balls", 1)
  cursor:setPocket("balls")
  Assert.equal(cursor:currentPocket(), "balls")
  cursor:setPocket("medicine")
  cursor:setPosition("medicine", 2)
  cursor:setPocket("balls")
  Assert.equal(cursor:position("balls"), 3, "returning to a pocket restores its cursor")
  Assert.equal(cursor:scroll("balls"), 1, "returning to a pocket restores its scroll")
  Assert.equal(cursor:position("medicine"), 2)
end

function T.cursor_rejects_unknown_pockets_and_negative_offsets()
  local cursor = BagCursor.new()
  Assert.throws(function()
    cursor:setPocket("BOGUS_POCKET")
  end)
  Assert.throws(function()
    cursor:setPosition("balls", -1)
  end)
  Assert.throws(function()
    cursor:setScroll("balls", -1)
  end)
  Assert.throws(function()
    cursor:position("BOGUS_POCKET")
  end)
  Assert.equal(cursor:currentPocket(), "items", "a rejected switch leaves the pocket untouched")
end

-- Battle last-used tracking rides the same runtime-only cursor: fresh
-- cursors name nothing, setting records the consumed item and its pocket,
-- clearing disables the shortcut again, and empty or foreign records
-- are rejected without touching the stored value.
function T.battle_last_used_item_round_trips_with_its_pocket_and_rejects_junk()
  local cursor = BagCursor.new()
  Assert.isNil(cursor:battleLastUsedItem(), "fresh cursors name no last-used item")
  Assert.isNil(cursor:battleLastUsedPocket(), "fresh cursors name no last-used pocket")
  cursor:setBattleLastUsedItem("POKE_BALL", 2)
  Assert.equal(cursor:battleLastUsedItem(), "POKE_BALL", "setting records the consumed item")
  Assert.equal(cursor:battleLastUsedPocket(), 2, "the consumed pocket records beside the item")
  cursor:setBattleLastUsedItem(nil)
  Assert.isNil(cursor:battleLastUsedItem(), "clearing disables the shortcut again")
  Assert.isNil(cursor:battleLastUsedPocket(), "clearing the item clears the pocket with it")
  cursor:setBattleLastUsedItem("POTION")
  Assert.equal(cursor:battleLastUsedItem(), "POTION", "a pocketless record still names its item")
  Assert.isNil(cursor:battleLastUsedPocket(), "a pocketless record names no pocket")
  Assert.throws(function()
    cursor:setBattleLastUsedItem("")
  end)
  Assert.throws(function()
    cursor:setBattleLastUsedItem(42)
  end)
  Assert.throws(function()
    cursor:setBattleLastUsedItem("POTION", 4)
  end)
  Assert.equal(cursor:battleLastUsedItem(), "POTION", "rejected records keep the stored item")
end

-- Retail battle cursor memory (battle_bag_menu.c Create/Exit over
-- BagCursor_Battle_*): fresh cursors open cleared without aliasing, stored
-- cursors reopen on their pocket with pages and cells, and malformed
-- snapshots are rejected without touching the live cursor.
function T.battle_cursor_round_trips_through_snapshots_and_rejects_malformed()
  local cursor = BagCursor.new()
  local fresh = cursor:battleCursor()
  Assert.equal(fresh.pocket, 0, "fresh cursors open on the first battle pocket")
  Assert.deepEqual(fresh.pages, { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }, "fresh pages start at zero")
  Assert.deepEqual(fresh.positions, { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }, "fresh cells start at zero")
  fresh.pocket = 3
  Assert.equal(cursor:battleCursor().pocket, 0, "snapshots never alias the live cursor")
  cursor:setBattleCursor({
    pocket = 2,
    pages = { [0] = 0, [1] = 1, [2] = 0, [3] = 0 },
    positions = { [0] = 0, [1] = 4, [2] = 0, [3] = 0 },
  })
  Assert.deepEqual(cursor:battleCursor(), {
    pocket = 2,
    pages = { [0] = 0, [1] = 1, [2] = 0, [3] = 0 },
    positions = { [0] = 0, [1] = 4, [2] = 0, [3] = 0 },
  }, "stored cursors reopen on their pocket with pages and cells")
  Assert.throws(function()
    cursor:setBattleCursor({ pocket = 4, pages = {}, positions = {} })
  end)
  Assert.throws(function()
    cursor:setBattleCursor({ pocket = 0, pages = { [0] = -1 }, positions = {} })
  end)
  Assert.throws(function()
    cursor:setBattleCursor(nil)
  end)
  Assert.equal(cursor:battleCursor().pocket, 2, "rejected stores keep the live cursor")
end

return { tests = T }
