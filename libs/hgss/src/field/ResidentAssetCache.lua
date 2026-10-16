-- Shared byte-counted idle lease kernel for resident game resources: one keyed
-- table with an intrusive oldest-first idle queue, single-use borrowing
-- leases, an owner-supplied busy check for natively held resources, and
-- exact-once physical release. Only unborrowed entries the busy check does
-- not claim are ever evicted; borrowed entries stay findable but leave the
-- idle queue until their last lease returns. The small fixed-capacity
-- message and actor owners keep their own domain lifetimes; this kernel
-- serves the byte-budgeted audio and image pools.

---@class ResidentAssetCacheEntry
---@field key string
---@field value table<string, unknown>
---@field weight integer
---@field leases integer
---@field prev ResidentAssetCacheEntry?
---@field next ResidentAssetCacheEntry?

---@class ResidentAssetCacheLease
---@field _owner ResidentAssetCache
---@field _key string
---@field _returned boolean

---@class ResidentAssetCacheOptions
---@field idleByteLimit number
---@field release fun(value: table<string, unknown>)
---@field busy (fun(value: table<string, unknown>): boolean)?

---@class ResidentAssetCache
---@field private _limit number
---@field private _release fun(value: table<string, unknown>)
---@field private _busy (fun(value: table<string, unknown>): boolean)?
---@field private _byKey table<string, ResidentAssetCacheEntry>
---@field private _head ResidentAssetCacheEntry?
---@field private _tail ResidentAssetCacheEntry?
---@field private _idleBytes integer
---@field private _pinnedBytes integer
---@field new fun(opts: ResidentAssetCacheOptions): ResidentAssetCache
---@field find fun(self: ResidentAssetCache, key: string): table<string, unknown>?
---@field publish fun(self: ResidentAssetCache, key: string, value: table<string, unknown>, weight: integer)
---@field borrow fun(self: ResidentAssetCache, key: string): ResidentAssetCacheLease
---@field returnLease fun(self: ResidentAssetCache, lease: ResidentAssetCacheLease): boolean
---@field touch fun(self: ResidentAssetCache, key: string)
---@field trim fun(self: ResidentAssetCache): integer, integer
---@field clear fun(self: ResidentAssetCache)
---@field stats fun(self: ResidentAssetCache): { idleBytes: integer, pinnedBytes: integer }

local ResidentAssetCache = {}
ResidentAssetCache.__index = ResidentAssetCache

---@param opts ResidentAssetCacheOptions
---@return ResidentAssetCache
function ResidentAssetCache.new(opts)
  assert(type(opts) == "table", "resident cache requires an options table")
  assert(
    type(opts.idleByteLimit) == "number" and opts.idleByteLimit >= 0,
    "resident cache requires a non-negative idle byte limit"
  )
  assert(type(opts.release) == "function", "resident cache requires a release callback")
  assert(opts.busy == nil or type(opts.busy) == "function", "resident cache busy check must be a function")
  return setmetatable({
    _limit = opts.idleByteLimit,
    _release = opts.release,
    _busy = opts.busy,
    _byKey = {},
    _head = nil,
    _tail = nil,
    _idleBytes = 0,
    _pinnedBytes = 0,
  }, ResidentAssetCache) --[[@as ResidentAssetCache]]
end

-- Links an idle entry as the most-recently-used end of the queue.
---@param entry ResidentAssetCacheEntry
function ResidentAssetCache:_append(entry)
  entry.prev = self._tail
  entry.next = nil
  if self._tail ~= nil then
    self._tail.next = entry
  else
    self._head = entry
  end
  self._tail = entry
end

-- Unlinks an idle entry from the queue without touching the key table or
-- the byte totals. Callers hold only queued entries: a borrowed entry is
-- already outside the queue.
---@param entry ResidentAssetCacheEntry
function ResidentAssetCache:_unlink(entry)
  assert(entry.prev ~= nil or self._head == entry, "resident cache unlink of a non-queued entry")
  if entry.prev ~= nil then
    entry.prev.next = entry.next
  else
    self._head = entry.next
  end
  if entry.next ~= nil then
    entry.next.prev = entry.prev
  else
    self._tail = entry.prev
  end
  entry.prev = nil
  entry.next = nil
end

-- Drops a fully unborrowed entry from the key table, the queue, and the
-- idle bytes. The physical release itself stays with the caller so a
-- throwing release still leaves coherent bookkeeping behind.
---@param entry ResidentAssetCacheEntry
function ResidentAssetCache:_remove(entry)
  assert(entry.leases == 0, "resident cache never drops a borrowed entry")
  self:_unlink(entry)
  self._byKey[entry.key] = nil
  self._idleBytes = self._idleBytes - entry.weight
end

---@param entry ResidentAssetCacheEntry
---@return boolean
function ResidentAssetCache:_isBusy(entry)
  local busy = self._busy
  if busy == nil then
    return false
  end
  return busy(entry.value) == true
end

-- Finds an entry by key and marks it most-recently-used. Borrowed entries
-- report their value without moving: they rejoin the idle queue only when
-- their last lease returns. Unknown keys report nil.
---@param key string
---@return table<string, unknown>?
function ResidentAssetCache:find(key)
  local entry = self._byKey[key]
  if entry == nil then
    return nil
  end
  self:touch(key)
  return entry.value
end

-- Admits a fully staged value under a fresh key at its real byte weight,
-- most-recently-used. Rejects duplicate keys and non-positive weights; a
-- rejected publication creates no entry and releases nothing.
---@param key string
---@param value table<string, unknown>
---@param weight integer
function ResidentAssetCache:publish(key, value, weight)
  assert(type(key) == "string", "resident cache keys are strings")
  assert(type(value) == "table", "resident cache values are tables")
  assert(type(weight) == "number" and weight > 0, "resident cache weights are positive byte counts")
  if self._byKey[key] ~= nil then
    error("resident cache already holds key " .. key, 0)
  end
  local entry = { key = key, value = value, weight = weight, leases = 0, prev = nil, next = nil }
  self._byKey[key] = entry
  self:_append(entry)
  self._idleBytes = self._idleBytes + weight
end

-- Borrows an entry through one opaque single-use lease per acquisition:
-- competing borrows of one key hold distinct leases over the shared value.
-- The first borrow of an entry moves its bytes from idle to borrowed.
---@param key string
---@return ResidentAssetCacheLease
function ResidentAssetCache:borrow(key)
  local entry = self._byKey[key]
  if entry == nil then
    error("resident cache has no entry for key " .. tostring(key), 0)
  end
  if entry.leases == 0 then
    self:_unlink(entry)
    self._idleBytes = self._idleBytes - entry.weight
    self._pinnedBytes = self._pinnedBytes + entry.weight
  end
  entry.leases = entry.leases + 1
  return { _owner = self, _key = key, _returned = false }
end

-- Returns a lease to its owning cache. The first return drops one borrow
-- reference and reports true; repeating it reports false without side
-- effects. A lease from another cache, or any non-lease, fails loudly.
---@param lease ResidentAssetCacheLease
---@return boolean
function ResidentAssetCache:returnLease(lease)
  if type(lease) ~= "table" or lease._owner ~= self then
    error("resident cache lease belongs to another cache", 0)
  end
  if lease._returned then
    return false
  end
  lease._returned = true
  local entry = self._byKey[lease._key]
  assert(entry ~= nil, "resident cache entry vanished under its borrower")
  assert(entry.leases > 0, "resident cache lease count went negative")
  entry.leases = entry.leases - 1
  if entry.leases == 0 then
    self:_append(entry)
    self._pinnedBytes = self._pinnedBytes - entry.weight
    self._idleBytes = self._idleBytes + entry.weight
  end
  return true
end

-- Marks an entry most-recently-used without borrowing it: the revisit and
-- prewarm signal. Borrowed entries need no move; unknown keys fail loudly.
---@param key string
function ResidentAssetCache:touch(key)
  local entry = self._byKey[key]
  if entry == nil then
    error("resident cache has no entry for key " .. tostring(key), 0)
  end
  if entry.leases == 0 then
    self:_unlink(entry)
    self:_append(entry)
  end
end

-- Evicts oldest-idle entries until the idle bytes fit the budget, skipping
-- entries the busy check still claims. Reports the evicted count and the
-- busy-claimed bytes still resident, so owners surface overflow instead of
-- churning live resources. A throwing release detaches its entry and
-- aborts loudly; bookkeeping stays coherent either way.
---@return integer, integer
function ResidentAssetCache:trim()
  local evicted = 0
  local busyBytes = 0
  local over = self._idleBytes - self._limit
  local node = self._head
  while node ~= nil do
    local following = node.next
    if self:_isBusy(node) then
      busyBytes = busyBytes + node.weight
    elseif over > 0 then
      over = over - node.weight
      self:_remove(node)
      evicted = evicted + 1
      local ok, err = pcall(self._release, node.value)
      if not ok then
        error(err, 0)
      end
    end
    node = following
  end
  return evicted, busyBytes
end

-- Releases every idle entry exactly once, oldest first, and empties the
-- kernel. Refuses loudly while any lease is outstanding: live borrowers
-- are never invalidated. Idempotent once empty.
function ResidentAssetCache:clear()
  for key, entry in pairs(self._byKey) do
    if entry.leases > 0 then
      error("resident cache still lends key " .. tostring(key), 0)
    end
  end
  local node = self._head
  while node ~= nil do
    local following = node.next
    self:_remove(node)
    local ok, err = pcall(self._release, node.value)
    if not ok then
      error(err, 0)
    end
    node = following
  end
end

-- Current byte census: unborrowed bytes still resident, and bytes held by
-- outstanding leases.
---@return { idleBytes: integer, pinnedBytes: integer }
function ResidentAssetCache:stats()
  return { idleBytes = self._idleBytes, pinnedBytes = self._pinnedBytes }
end

return ResidentAssetCache
