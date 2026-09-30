-- Immutable resolved item definitions. The constructor requires the
-- already-canonical generated asset root, validates it through the owned
-- asset schema, copies it into package-owned state, and indexes semantic and
-- native identities. Lookups never mutate and never reach source formats:
-- native numeric identities stay only because exact native encoding gives
-- them current use. Pocket definitions are the schema-owned source
-- contract, re-exported here for consumers.

local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ResolvedItemSchema = require("libs.items.src.ResolvedItemSchema")
local ItemErrors = require("libs.items.src.errors")

---@class ItemCatalog
---@field private _root table<string, unknown>
---@field private _itemByNative table<integer, string>
---@field private _pocketByNative table<integer, string>
local ItemCatalog = {}
ItemCatalog.__index = ItemCatalog

ItemCatalog.POCKETS = ItemAssetSchema.POCKETS

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

-- One shared index builder for both constructors: entries without a
-- declared numeric identity resolve semantically only and never occupy the
-- native index, while duplicate declared identities fail loudly.
---@param owned table<string, unknown>
---@return table<integer, string> itemByNative
---@return table<integer, string> pocketByNative
local function buildIndexes(owned)
  local itemByNative = {}
  local pocketByNative = {}
  for key, item in pairs(owned.items) do
    local nativeId = item.nativeId
    if nativeId ~= nil then
      if itemByNative[nativeId] ~= nil then
        ItemErrors.raise(
          ItemErrors.RECORD_INVALID,
          "duplicate native item identity " .. tostring(nativeId),
          { item = key }
        )
      end
      itemByNative[nativeId] = key
    end
  end
  for key, pocket in pairs(owned.pockets) do
    pocketByNative[pocket.nativeId] = key
  end
  return itemByNative, pocketByNative
end

---@param root table<string, unknown>
---@return ItemCatalog
function ItemCatalog.new(root)
  assert(type(root) == "table", "ItemCatalog requires the generated asset root")
  ItemAssetSchema.assertCatalog(root)
  local owned = copyValue(root)
  local itemByNative, pocketByNative = buildIndexes(owned)
  return setmetatable({
    _root = owned,
    _itemByNative = itemByNative,
    _pocketByNative = pocketByNative,
  }, ItemCatalog)
end

-- Composed catalog construction: validates through the resolved schema so
-- namespaced custom entries without numeric identities resolve, then shares
-- the single lookup implementation and ownership contract with native
-- construction. The owned root is detached from the caller.
---@param root table<string, unknown>
---@return ItemCatalog
function ItemCatalog.fromResolved(root)
  assert(type(root) == "table", "ItemCatalog requires the composed asset root")
  ResolvedItemSchema.assertCatalog(root)
  local owned = copyValue(root)
  local itemByNative, pocketByNative = buildIndexes(owned)
  return setmetatable({
    _root = owned,
    _itemByNative = itemByNative,
    _pocketByNative = pocketByNative,
  }, ItemCatalog)
end

-- Stable pocket sorting key: native entries keep numeric source order while
-- custom entries sort after every native entry, ordered semantically by
-- pocket and key. Values compare with `<` and stay stable across builds.
---@param key string
---@return string
function ItemCatalog:orderingKey(key)
  local definition = self:item(key)
  if definition.nativeId ~= nil then
    return string.format("0:%06d", definition.nativeId)
  end
  assert(type(definition.pocket) == "string", "composed items carry their pocket")
  return "1:" .. definition.pocket .. ":" .. key
end

---@param key string
---@return table<string, unknown>
function ItemCatalog:item(key)
  assert(type(key) == "string", "item lookup requires a string key")
  local definition = self._root.items[key]
  if definition == nil then
    ItemErrors.raise(ItemErrors.RECORD_INVALID, "unknown item " .. key, { item = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function ItemCatalog:itemKeyByNativeId(nativeId)
  local key = self._itemByNative[nativeId]
  if key == nil then
    ItemErrors.raise(
      ItemErrors.RECORD_INVALID,
      "unknown native item identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table<string, unknown>
function ItemCatalog:itemByNativeId(nativeId)
  return self._root.items[self:itemKeyByNativeId(nativeId)]
end

---@param key string
---@return table<string, unknown>
function ItemCatalog:pocket(key)
  assert(type(key) == "string", "pocket lookup requires a string key")
  local definition = self._root.pockets[key]
  if definition == nil then
    ItemErrors.raise(ItemErrors.RECORD_INVALID, "unknown pocket " .. key, { pocket = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function ItemCatalog:pocketKeyByNativeId(nativeId)
  local key = self._pocketByNative[nativeId]
  if key == nil then
    ItemErrors.raise(
      ItemErrors.RECORD_INVALID,
      "unknown native pocket identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table<string, unknown>
function ItemCatalog:pocketByNativeId(nativeId)
  return self._root.pockets[self:pocketKeyByNativeId(nativeId)]
end

---@param key string
---@return string
function ItemCatalog:pocketName(key)
  assert(type(key) == "string", "pocket name lookup requires a string key")
  local name = self._root.pocketNames[key]
  if name == nil then
    ItemErrors.raise(ItemErrors.RECORD_INVALID, "unknown pocket " .. key, { pocket = key })
  end
  assert(name ~= nil, "catalog index carries the validated entry")
  return name
end

-- Whether the item may occupy a source registered-item slot: a Key Item
-- whose source selectability flag permits field registration. Unknown keys
-- raise the same structured record error as other lookups.
---@param key string
---@return boolean
function ItemCatalog:isRegisterable(key)
  local definition = self:item(key)
  return definition.pocket == "key_items" and definition.selectable == true
end

-- The source move identities taught by HM records: the machine context
-- refuses to overwrite them while the domain delete primitive keeps its
-- general legality.
---@return table<integer, boolean> source move native identities keyed by identity
function ItemCatalog:hmMoveNativeIds()
  local moves = {}
  for _, record in pairs(assert(self._root.items, "the catalog carries its items")) do
    assert(type(record) == "table", "catalog items arrive as records")
    if record.pocket == "tmhm" and record.isHm == true then
      local nativeId = assert(record.tmhmMoveNativeId, "machine records name their move")
      assert(type(nativeId) == "number", "machine records name their move")
      moves[nativeId] = true
    end
  end
  return moves
end

return ItemCatalog
