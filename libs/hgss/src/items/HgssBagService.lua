-- Runtime-facing HGSS Bag facade: the one writable inventory dependency
-- exposed to script and Bag controller composition. It joins the immutable
-- shared item catalog with the mutable pocket mechanics and owns the
-- monotonically increasing runtime revision: every successful semantic
-- mutation increments it exactly once, while failed or no-op mutations and
-- all queries leave it untouched. Item identity is the semantic key;
-- native numeric ids cross the boundary only through the explicit
-- native-facing adapters. Pure domain code: no love dependency.

local BagInventory = require("libs.hgss.src.items.BagInventory")

---@class HgssBagService
---@field private _catalog ItemCatalog
---@field private _inventory BagInventory
---@field private _revision integer
local HgssBagService = {}
HgssBagService.__index = HgssBagService

---@class HgssBagServiceOptions
---@field catalog ItemCatalog
---@field bag table<string, unknown>?
---@param opts HgssBagServiceOptions
---@return HgssBagService
function HgssBagService.new(opts)
  assert(type(opts) == "table", "bag service requires an options record")
  assert(opts.catalog ~= nil, "bag service requires an item catalog")
  return setmetatable({
    _catalog = opts.catalog,
    _inventory = BagInventory.new(opts.catalog, opts.bag),
    _revision = 0,
  }, HgssBagService)
end

---@param ok boolean
---@return boolean
function HgssBagService:_bump(ok)
  if ok then
    self._revision = self._revision + 1
  end
  return ok
end

---@return integer
function HgssBagService:revision()
  return self._revision
end

---@return ItemCatalog
function HgssBagService:catalog()
  return self._catalog
end

---@param itemKey string
---@param quantity integer
---@return boolean
function HgssBagService:add(itemKey, quantity)
  return self:_bump(self._inventory:add(itemKey, quantity))
end

---@param itemKey string
---@param quantity integer
---@return boolean
function HgssBagService:take(itemKey, quantity)
  return self:_bump(self._inventory:take(itemKey, quantity))
end

---@param itemKey string
---@param quantity integer
---@return boolean
function HgssBagService:has(itemKey, quantity)
  return self._inventory:has(itemKey, quantity)
end

---@param itemKey string
---@param quantity integer
---@return boolean
function HgssBagService:hasSpace(itemKey, quantity)
  return self._inventory:hasSpace(itemKey, quantity)
end

---@param itemKey string
---@return integer
function HgssBagService:quantity(itemKey)
  return self._inventory:quantity(itemKey)
end

---@param itemKey string
---@return string
function HgssBagService:pocketOf(itemKey)
  return self._catalog:item(itemKey).pocket
end

---@param itemKey string
---@return integer
function HgssBagService:pocketNativeId(itemKey)
  return self._catalog:pocket(self:pocketOf(itemKey)).nativeId
end

---@param itemKey string
---@return boolean
function HgssBagService:isTMHM(itemKey)
  return self:pocketOf(itemKey) == "tmhm"
end

---@param nativeId integer
---@return boolean
function HgssBagService:isTMHMNative(nativeId)
  return self:isTMHM(self:_keyByNativeId(nativeId))
end

---@param nativeId integer
---@return integer
function HgssBagService:pocketNativeIdNative(nativeId)
  return self:pocketNativeId(self:_keyByNativeId(nativeId))
end

---@param itemKey string
---@return boolean
function HgssBagService:isRegisterable(itemKey)
  return self._catalog:isRegisterable(itemKey)
end

---@param pocketKey string
---@return { item: string, quantity: integer }[]
function HgssBagService:pocketItems(pocketKey)
  return self._inventory:pocketItems(pocketKey)
end

---@param pocketKey string
---@param fromIndex integer
---@param toIndex integer
---@return boolean
function HgssBagService:move(pocketKey, fromIndex, toIndex)
  return self:_bump(self._inventory:move(pocketKey, fromIndex, toIndex))
end

---@return string[]
function HgssBagService:registeredItems()
  return self._inventory:registeredItems()
end

---@param itemKey string
---@return "slot1"|"slot2"|nil
function HgssBagService:tryRegister(itemKey)
  local slot = self._inventory:tryRegister(itemKey)
  if slot ~= nil then
    self._revision = self._revision + 1
  end
  return slot
end

---@param itemKey string
---@return boolean
function HgssBagService:unregister(itemKey)
  return self:_bump(self._inventory:unregister(itemKey))
end

---@return table<string, unknown>
function HgssBagService:capture()
  return self._inventory:capture()
end

-- Stages validated inventory deltas without touching the live inventory.
-- Deltas apply in order to a private candidate built from the current
-- capture, preserving exact stack order and capacity semantics. Returns
-- nil and "stale" when the expected revision drifted; otherwise returns
-- a one-use opaque preparation whose publish swaps the candidate and
-- bumps the revision exactly once when the batch changed anything. A
-- repeated publish is a programming error. Callers enforce domain
-- preconditions (capacity, ownership) before preparing; a candidate
-- application failure after those checks is a programming error raised
-- loudly, never a silent partial publication.
---@class BagPreparation
---@field changed boolean
---@field isCurrent fun(): boolean
---@field publish fun()
---@param expectedRevision integer
---@param deltas { op: string, item: string, quantity: integer }[]
---@return BagPreparation|nil, string|nil
function HgssBagService:prepareInventoryChanges(expectedRevision, deltas)
  assert(type(expectedRevision) == "number", "bag preparation requires the expected revision")
  assert(type(deltas) == "table", "bag preparation requires a delta array")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  local candidate = BagInventory.new(self._catalog, self._inventory:capture())
  for _, delta in ipairs(deltas) do
    assert(type(delta) == "table", "bag preparation deltas must be records")
    local applied = false
    if delta.op == "add" then
      applied = candidate:add(delta.item, delta.quantity)
    elseif delta.op == "take" then
      applied = candidate:take(delta.item, delta.quantity)
    else
      error("bag preparation delta carries an unknown operation: " .. tostring(delta.op), 0)
    end
    assert(applied, "bag preparation delta must apply after caller preconditions")
  end
  local capturedRevision = self._revision
  local live = self._inventory
  local changed = #deltas > 0
  local consumed = false
  local function isCurrent()
    return self._inventory == live and self._revision == capturedRevision
  end
  local function publish()
    assert(not consumed, "bag preparation publishes exactly once")
    consumed = true
    if changed then
      self._inventory = candidate
      self._revision = self._revision + 1
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

---@param nativeId integer
---@return string
function HgssBagService:_keyByNativeId(nativeId)
  return self._catalog:itemKeyByNativeId(nativeId)
end

---@param nativeId integer
---@param quantity integer
---@return boolean
function HgssBagService:addNative(nativeId, quantity)
  return self:add(self:_keyByNativeId(nativeId), quantity)
end

---@param nativeId integer
---@param quantity integer
---@return boolean
function HgssBagService:takeNative(nativeId, quantity)
  return self:take(self:_keyByNativeId(nativeId), quantity)
end

---@param nativeId integer
---@param quantity integer
---@return boolean
function HgssBagService:hasNative(nativeId, quantity)
  return self:has(self:_keyByNativeId(nativeId), quantity)
end

---@param nativeId integer
---@param quantity integer
---@return boolean
function HgssBagService:hasSpaceNative(nativeId, quantity)
  return self:hasSpace(self:_keyByNativeId(nativeId), quantity)
end

---@param nativeId integer
---@return integer
function HgssBagService:quantityNative(nativeId)
  return self:quantity(self:_keyByNativeId(nativeId))
end

---@param nativeId integer
---@return "slot1"|"slot2"|nil
function HgssBagService:tryRegisterNative(nativeId)
  return self:tryRegister(self:_keyByNativeId(nativeId))
end

---@param nativeId integer
---@return boolean
function HgssBagService:unregisterNative(nativeId)
  return self:unregister(self:_keyByNativeId(nativeId))
end

---@param nativeId integer
---@return boolean
function HgssBagService:isRegisterableNative(nativeId)
  return self:isRegisterable(self:_keyByNativeId(nativeId))
end

return HgssBagService
