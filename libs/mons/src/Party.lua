-- Ordered at-most-six party. Public positions are zero-based dense slots
-- from 0 to count-1, matching script and UI positions. The aggregate owns
-- copies of validated mon records: reads hand out copies so callers cannot
-- bypass validation or revision, and every successful structural change
-- increments the revision once. Adding to a full party returns false without
-- mutation; there is no PC fallback.

local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")

---@class Party
---@field private _mons table[]
---@field private _revision integer
local Party = {}
Party.__index = Party

Party.MAX = 6

---@param mons table[]?
---@param revision integer?
---@return Party
local function build(mons, revision)
  return setmetatable({ _mons = mons or {}, _revision = revision or 0 }, Party)
end

---@return Party
function Party.new()
  return build()
end

---@generic T
---@param value T
---@return T
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

local function sameValue(left, right)
  if left == right then
    return true
  end
  if type(left) ~= "table" or type(right) ~= "table" then
    return false
  end
  for key, value in pairs(left) do
    if not sameValue(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function sameRoster(left, right)
  if #left ~= #right then
    return false
  end
  for index, mon in ipairs(left) do
    if not sameValue(mon, right[index]) then
      return false
    end
  end
  return true
end

---@param slot integer
---@param count integer
---@param what string
local function checkSlot(slot, count, what)
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot >= count then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, what .. " slot is out of range", { slot = slot })
  end
end

---@return integer
function Party:count()
  return #self._mons
end

---@param slot0 integer
---@return table<string, unknown>
function Party:get(slot0)
  checkSlot(slot0, #self._mons, "party slot")
  return copyValue(self._mons[slot0 + 1])
end

-- Adds a copy of the mon; false when full, without mutation.
---@param mon table<string, unknown>
---@return boolean
function Party:add(mon)
  assert(type(mon) == "table", "party add requires a mon record")
  if #self._mons >= Party.MAX then
    return false
  end
  self._mons[#self._mons + 1] = copyValue(mon)
  self._revision = self._revision + 1
  return true
end

---@param slot0 integer
---@return table<string, unknown>
function Party:remove(slot0)
  checkSlot(slot0, #self._mons, "party removal")
  local removed = table.remove(self._mons, slot0 + 1)
  self._revision = self._revision + 1
  return copyValue(removed)
end

---@param left0 integer
---@param right0 integer
function Party:swap(left0, right0)
  checkSlot(left0, #self._mons, "party swap")
  checkSlot(right0, #self._mons, "party swap")
  if left0 ~= right0 then
    local left = left0 + 1
    local right = right0 + 1
    self._mons[left], self._mons[right] = self._mons[right], self._mons[left]
    self._revision = self._revision + 1
  end
end

---@param slot0 integer
---@param mon table<string, unknown>
function Party:set(slot0, mon)
  checkSlot(slot0, #self._mons, "party slot")
  assert(type(mon) == "table", "party set requires a mon record")
  self._mons[slot0 + 1] = copyValue(mon)
  self._revision = self._revision + 1
end

-- Stages a same-size replacement without mutating the party: each update
-- names a unique existing zero-based slot and its replacement record. The
-- candidate carries copies, so later caller edits never leak into it. An
-- empty update set preserves the revision; any non-empty set advances it
-- exactly once. Rejected stagings raise before allocating a candidate.
---@param updates { slot: integer, mon: table<string, unknown> }[]
---@return Party
function Party:withUpdates(updates)
  assert(type(updates) == "table", "party staging requires an update array")
  local seen = {}
  for _, update in ipairs(updates) do
    assert(type(update) == "table", "party staging updates must be records")
    local slot = update.slot
    if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot >= #self._mons then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party staging slot is out of range", { slot = slot })
    end
    assert(type(slot) == "number", "staging slot validated above")
    if seen[slot] then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party staging slot is duplicated", { slot = slot })
    end
    seen[slot] = true
    if type(update.mon) ~= "table" then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party staging requires a mon record", { slot = slot })
    end
  end
  local mons = copyValue(self._mons)
  for _, update in ipairs(updates) do
    mons[update.slot + 1] = copyValue(update.mon)
  end
  local revision = self._revision
  if #updates > 0 then
    revision = revision + 1
  end
  return build(mons, revision)
end

-- Stages a complete compact roster while preserving this Party's ownership
-- and revision rules for deposit and withdrawal operations.
---@param mons table[]
---@return Party
function Party:withRoster(mons)
  assert(type(mons) == "table", "party roster staging requires an array")
  local count = 0
  for key in pairs(mons) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party roster keys must be dense from one", {})
    end
    count = math.max(count, key)
  end
  if count > Party.MAX then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party roster exceeds six mons", {})
  end
  local candidate = {}
  for index = 1, count do
    if mons[index] == nil or type(mons[index]) ~= "table" then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party roster must be dense", {})
    end
    candidate[index] = copyValue(mons[index])
  end
  local changed = not sameRoster(self._mons, candidate)
  return build(candidate, self._revision + (changed and 1 or 0))
end

---@param predicate fun(mon: table<string, unknown>): boolean
---@return integer?
function Party:findFirst(predicate)
  assert(type(predicate) == "function", "party search requires a predicate")
  for index, mon in ipairs(self._mons) do
    if predicate(copyValue(mon)) then
      return index - 1
    end
  end
  return nil
end

---@return integer?
function Party:leadSlot()
  if #self._mons == 0 then
    return nil
  end
  return 0
end

---@return integer?
function Party:leadAliveSlot()
  for index, mon in ipairs(self._mons) do
    if not mon.isEgg and mon.condition.currentHp > 0 then
      return index - 1
    end
  end
  return nil
end

---@return integer
function Party:revision()
  return self._revision
end

---@return { max: integer, mons: table[] }
function Party:capture()
  return { max = Party.MAX, mons = copyValue(self._mons) }
end

---@param snapshot table<string, unknown>
---@param context table<string, unknown>
---@return boolean
function Party.validate(snapshot, context)
  assert(type(context) == "table", "party validation requires a context")
  if type(snapshot) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot must be a record", {})
  end
  if snapshot.max ~= Party.MAX then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot must carry max six", {})
  end
  if type(snapshot.mons) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot must carry a mon array", {})
  end
  local count = 0
  for key in pairs(snapshot.mons) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot keys must be dense from one", {})
    end
    if key > count then
      count = key
    end
  end
  if count > Party.MAX then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot exceeds six mons", {})
  end
  for index = 1, count do
    if snapshot.mons[index] == nil then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot must stay dense", {})
    end
  end
  for _, mon in ipairs(snapshot.mons) do
    Mon.validate(mon, context)
  end
  return true
end

---@param snapshot table<string, unknown>
---@param context table<string, unknown>
---@return Party
function Party.restore(snapshot, context)
  assert(type(context) == "table", "party restore requires a context")
  local mons = {}
  for _, mon in ipairs(snapshot.mons) do
    mons[#mons + 1] = copyValue(mon)
  end
  return build(mons, #mons)
end

return Party
