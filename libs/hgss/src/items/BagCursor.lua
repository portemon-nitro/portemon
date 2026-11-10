-- Runtime-only field Bag cursor: the current pocket plus the per-pocket
-- visible-grid position and scroll offset (include/bag_cursor.h keeps field
-- cursor state separate from saved Bag state). The cursor survives Bag
-- close/reopen inside one field runtime and resets on save/relaunch: no
-- cursor field ever enters the persisted save. Pure mutable runtime helper:
-- no love or save dependency beyond the shared pocket order.

local BagSave = require("libs.hgss.src.save.BagSave")

---@class BagBattleCursor
---@field pocket integer zero-based pocket
---@field pages table<integer, integer> page per zero-based pocket
---@field positions table<integer, integer> cell per zero-based pocket
---@field cursorActive boolean? d-pad cursor visibility behind browser snapshots

---@class BagCursor
---@field pocket string
---@field pockets table<string, { position: integer, scroll: integer }>
---@field _battleLastUsedItem string? backing last-consumed key (read through battleLastUsedItem)
---@field _battle BagBattleCursor? backing battle-bag cursor (read through battleCursor)
local BagCursor = {}
BagCursor.__index = BagCursor

---@return BagCursor
function BagCursor.new()
  local pockets = {}
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    pockets[pocketKey] = { position = 0, scroll = 0 }
  end
  return setmetatable({ pocket = "items", pockets = pockets }, BagCursor)
end

---@return BagBattleCursor cleared battle-bag cursor with zero-based pocket, pages, and cells
local function clearedBattleCursor()
  return {
    pocket = 0,
    pages = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 },
    positions = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 },
  }
end

---@param value unknown validated battle pocket, page, or cell offset under storing
---@param what string offset identity under diagnostics
local function checkBattleOffset(value, what)
  assert(
    type(value) == "number" and value % 1 == 0 and value >= 0,
    "bag battle cursor " .. what .. " must be a non-negative integer"
  )
end

-- Reads the runtime-only battle-bag cursor (retail BagCursor_Battle_*
-- state): the last sealed pocket with each pocket's page and cell, so
-- the bag reopens where selection left it. Fresh cursors open cleared.
-- The returned snapshot is detached; mutating it moves nothing.
---@return BagBattleCursor battle cursor snapshot with zero-based pocket, pages, and cells
function BagCursor:battleCursor()
  local stored = self._battle
  if type(stored) ~= "table" then
    return clearedBattleCursor()
  end
  local pages = {}
  local positions = {}
  for pocket = 0, 3 do
    pages[pocket] = stored.pages[pocket]
    positions[pocket] = stored.positions[pocket]
  end
  return { pocket = stored.pocket, pages = pages, positions = positions }
end

-- Stores the battle-bag cursor behind a sealed item (retail
-- BattleBagMenu_Exit writes positions, pages, and pocket only when an
-- item was chosen): cancelling the browser stores nothing. Malformed
-- snapshots fail instead of recording a shortcut the browser cannot
-- reopen.
---@param snapshot BagBattleCursor battle cursor snapshot with zero-based pocket, pages, and cells
function BagCursor:setBattleCursor(snapshot)
  assert(type(snapshot) == "table", "the battle cursor stores as a record")
  local pocket = snapshot.pocket
  assert(
    type(pocket) == "number" and pocket % 1 == 0 and pocket >= 0 and pocket <= 3,
    "the battle cursor names its pocket"
  )
  assert(type(snapshot.pages) == "table", "the battle cursor carries its pages")
  assert(type(snapshot.positions) == "table", "the battle cursor carries its cells")
  local pages = {}
  local positions = {}
  for index = 0, 3 do
    checkBattleOffset(snapshot.pages[index], "page")
    checkBattleOffset(snapshot.positions[index], "cell")
    pages[index] = snapshot.pages[index]
    positions[index] = snapshot.positions[index]
  end
  self._battle = { pocket = pocket, pages = pages, positions = positions }
end

---@param pocketKey string
local function checkPocket(self, pocketKey)
  if type(self.pockets[pocketKey]) ~= "table" then
    error("unknown bag pocket " .. tostring(pocketKey), 0)
  end
end

---@param offset integer
---@param what string
local function checkOffset(offset, what)
  assert(
    type(offset) == "number" and offset % 1 == 0 and offset >= 0,
    "bag cursor " .. what .. " must be a non-negative integer"
  )
end

---@return string? last battle-consumed item key, nil when none is recorded
function BagCursor:battleLastUsedItem()
  return self._battleLastUsedItem
end

-- Reads the battle pocket behind the last-used shortcut, nil when the
-- recorded consume named no pocket.
---@return integer? zero-based battle pocket behind the last-used item
function BagCursor:battleLastUsedPocket()
  return self._battleLastUsedPocket
end

-- Records the battle-consumed item behind the bag last-used shortcut
-- (retail `BagCursor_Battle_SetLastUsedItem`, written on every battle
-- consume): clearing restores the disabled shortcut. Only non-empty
-- item keys record; without a pocket the mapping resolves at intent
-- build time through the item catalog.
---@param itemKey string? consumed battle item key, nil to clear
---@param pocket integer? zero-based battle pocket behind the consume, nil when unknown
function BagCursor:setBattleLastUsedItem(itemKey, pocket)
  if itemKey == nil then
    self._battleLastUsedItem = nil
    self._battleLastUsedPocket = nil
    return
  end
  assert(type(itemKey) == "string" and itemKey ~= "", "the battle last-used item names its key")
  if pocket ~= nil then
    assert(
      type(pocket) == "number" and pocket % 1 == 0 and pocket >= 0 and pocket <= 3,
      "the battle last-used item names its pocket"
    )
  end
  self._battleLastUsedItem = itemKey
  self._battleLastUsedPocket = pocket
end

---@return string
function BagCursor:currentPocket()
  return self.pocket
end

---@param pocketKey string
function BagCursor:setPocket(pocketKey)
  checkPocket(self, pocketKey)
  self.pocket = pocketKey
end

---@param pocketKey string?
---@return integer
function BagCursor:position(pocketKey)
  pocketKey = pocketKey or self.pocket
  checkPocket(self, pocketKey)
  return self.pockets[pocketKey].position
end

---@param pocketKey string
---@param position integer
function BagCursor:setPosition(pocketKey, position)
  checkPocket(self, pocketKey)
  checkOffset(position, "position")
  self.pockets[pocketKey].position = position
end

---@param pocketKey string?
---@return integer
function BagCursor:scroll(pocketKey)
  pocketKey = pocketKey or self.pocket
  checkPocket(self, pocketKey)
  return self.pockets[pocketKey].scroll
end

---@param pocketKey string
---@param scroll integer
function BagCursor:setScroll(pocketKey, scroll)
  checkPocket(self, pocketKey)
  checkOffset(scroll, "scroll")
  self.pockets[pocketKey].scroll = scroll
end

return BagCursor
