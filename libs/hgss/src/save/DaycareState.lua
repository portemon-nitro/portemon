-- Strict persisted Day Care custody: the two source parent slots with their
-- walked-step counters, the pending egg identity and the egg cycle progress.
-- Every stored parent is a detached canonical g4-mon-v2 record, so a
-- deposited mon can never be seen in the party and the Day Care at once; the
-- step counters are the source's own u32 accumulation and never a second
-- clock. Mutations stage as one-use revision-based candidates exactly like
-- the party, Bag, and dex owners: a candidate is built completely, a stale or
-- repeated publication fails before touching state, and only the current
-- publication installs the new slots.
--
-- Retail sources (tmp/refs/pokeheartgold): the saved struct is
-- `Daycare { DaycareMon mons[2]; u32 egg_pid; u8 egg_cycles; }` with
-- `DaycareMon { BoxPokemon mon; DaycareMail mail; u32 steps; }`
-- (include/daycare.h); `Save_Daycare_GetState` answers egg-waiting 1, mons+1,
-- or none 0 (src/get_egg.c), `Save_Daycare_HasEgg` is `egg_pid != 0`
-- (src/daycare.c), and `Save_Daycare_Compaction` moves slot 1 into an empty
-- slot 0 (src/get_egg.c). The stored Mail and nickname live on the mon record
-- in this port, so the source's DaycareMail extras record has no counterpart.
-- Pure domain code: no love dependency, no catalog.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

---@class DaycareState
---@field private _slots { mon: table<string, unknown>, steps: integer }[]
---@field private _pendingEggPid integer
---@field private _eggCycleCounter integer
---@field private _validateMon fun(mon: unknown): table<string, unknown>
---@field private _revision integer
local DaycareState = {}
DaycareState.__index = DaycareState

DaycareState.SCHEMA = "hgss-daycare-v1"
-- NUM_DAYCARE_MONS (include/constants/daycare.h).
DaycareState.MAX_SLOTS = 2
DaycareState.MAX_STEPS = 0xFFFFFFFF
DaycareState.MAX_EGG_PID = 0xFFFFFFFF
DaycareState.MAX_EGG_CYCLE = 255

-- DAYCARE_NO_MONS / DAYCARE_EGG_WAITING / DAYCARE_ONE_MON / DAYCARE_TWO_MONS.
DaycareState.STATE_EMPTY = 0
DaycareState.STATE_EGG_READY = 1
DaycareState.STATE_ONE_MON = 2
DaycareState.STATE_TWO_MONS = 3

local TOP_FIELDS = { schema = true, slots = true, pendingEggPid = true, eggCycleCounter = true }
local SLOT_FIELDS = { mon = true, steps = true }

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, context)
end

---@param value unknown
---@param what string
---@param max integer
---@return integer
local function checkUnsigned(value, what, max)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > max then
    fail("day care " .. what .. " must be an integer in 0.." .. tostring(max), { field = what, value = value })
  end
  return value --[[@as integer]]
end

---@param record table<string, unknown>
---@param allowed table<string, boolean>
---@param what string
local function checkFields(record, allowed, what)
  for key in pairs(record) do
    if allowed[key] ~= true then
      fail("day care " .. what .. " has an unknown field", { field = key })
    end
  end
end

---@param value unknown
---@return boolean
local function isDenseArray(value)
  if type(value) ~= "table" then
    return false
  end
  assert(type(value) == "table")
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      return false
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

---@param validateMon fun(mon: unknown): table<string, unknown>
---@param value unknown
---@param where string
---@return { mon: table<string, unknown>, steps: integer }
local function checkSlot(validateMon, value, where)
  if type(value) ~= "table" then
    fail("day care " .. where .. " must be a record", {})
  end
  assert(type(value) == "table")
  checkFields(value, SLOT_FIELDS, where)
  if value.mon == nil then
    fail("day care " .. where .. " names its stored parent", {})
  end
  return {
    mon = validateMon(value.mon),
    steps = checkUnsigned(value.steps, where .. " steps", DaycareState.MAX_STEPS),
  }
end

---@param validateMon fun(mon: unknown): table<string, unknown>
---@param value unknown
---@return { mon: table<string, unknown>, steps: integer }[]
local function checkSlots(validateMon, value)
  if not isDenseArray(value) then
    fail("day care slots must be a dense array", {})
  end
  assert(type(value) == "table")
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  if count > DaycareState.MAX_SLOTS then
    fail("day care holds at most " .. DaycareState.MAX_SLOTS .. " parents", { count = count })
  end
  local slots = {}
  for index = 1, count do
    slots[index] = checkSlot(validateMon, value[index], "slot " .. (index - 1))
  end
  return slots
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkValidator(value, what)
  if type(value) ~= "function" then
    fail("day care " .. what .. " requires the canonical mon validator", {})
  end
  return value --[[@as fun(mon: unknown): table<string, unknown>]]
end

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

-- One staged mutation over the slots: the candidate slots and egg fields are
-- built completely before this record exists, and the one-use publication
-- installs them only while the captured revision still holds.
---@class DaycarePreparation
---@field changed boolean
---@field isCurrent fun(): boolean
---@field publish fun()

---@param state DaycareState
---@param slots { mon: table<string, unknown>, steps: integer }[]
---@param pendingEggPid integer
---@param eggCycleCounter integer
---@return DaycarePreparation
local function prepareState(state, slots, pendingEggPid, eggCycleCounter)
  local capturedRevision = state._revision
  local changed = #slots ~= #state._slots
    or pendingEggPid ~= state._pendingEggPid
    or eggCycleCounter ~= state._eggCycleCounter
  if not changed then
    for index, slot in ipairs(slots) do
      local live = state._slots[index]
      if slot.steps ~= live.steps or slot.mon ~= live.mon then
        changed = true
      end
    end
  end
  local consumed = false
  local function isCurrent()
    return (not consumed) and state._revision == capturedRevision
  end
  local function publish()
    if consumed then
      fail("day care preparation already published", {})
    end
    if state._revision ~= capturedRevision then
      fail("day care preparation is stale", {})
    end
    consumed = true
    state._slots = slots
    state._pendingEggPid = pendingEggPid
    state._eggCycleCounter = eggCycleCounter
    if changed then
      state._revision = state._revision + 1
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

-- Copies the live slots for a candidate: a caller may stage any number of
-- derived edits without ever aliasing live state.
---@param state DaycareState
---@return { mon: table<string, unknown>, steps: integer }[]
local function copySlots(state)
  local slots = {}
  for index, slot in ipairs(state._slots) do
    slots[index] = { mon = slot.mon, steps = slot.steps }
  end
  return slots
end

-- The defined empty bucket: no parent, no pending egg, no cycle progress.
---@return table<string, unknown>
function DaycareState.initial()
  return {
    schema = DaycareState.SCHEMA,
    slots = {},
    pendingEggPid = 0,
    eggCycleCounter = 0,
  }
end

---@param validateMon fun(mon: unknown): table<string, unknown>
---@return DaycareState
function DaycareState.empty(validateMon)
  return setmetatable({
    _slots = {},
    _pendingEggPid = 0,
    _eggCycleCounter = 0,
    _validateMon = checkValidator(validateMon, "state"),
    _revision = 0,
  }, DaycareState)
end

-- Restores one stored bucket. The current schema is strict: an unknown field,
-- more than two parents, an out-of-range step counter or egg identity, or a
-- stored parent that fails canonical mon validation refuses the record
-- instead of normalizing it. The bucket's own presence is required: the save
-- migration initializes it for every earlier envelope, and a current record
-- without it is malformed rather than an empty Day Care.
---@param bucket unknown
---@param validateMon fun(mon: unknown): table<string, unknown>
---@return DaycareState
function DaycareState.restore(bucket, validateMon)
  local checkMon = checkValidator(validateMon, "restore")
  if type(bucket) ~= "table" then
    fail("day care bucket must be a record", {})
  end
  assert(type(bucket) == "table")
  if bucket.schema ~= DaycareState.SCHEMA then
    fail("day care schema is invalid", { schema = bucket.schema })
  end
  checkFields(bucket, TOP_FIELDS, "bucket")
  return setmetatable({
    _slots = checkSlots(checkMon, bucket.slots),
    _pendingEggPid = checkUnsigned(bucket.pendingEggPid, "pending egg pid", DaycareState.MAX_EGG_PID),
    _eggCycleCounter = checkUnsigned(bucket.eggCycleCounter, "egg cycle counter", DaycareState.MAX_EGG_CYCLE),
    _validateMon = checkMon,
    _revision = 0,
  }, DaycareState)
end

-- The detached canonical bucket: stored parents are copied out, so a caller
-- cannot mutate live custody through the capture.
---@return table<string, unknown>
function DaycareState:capture()
  local slots = {}
  for index, slot in ipairs(self._slots) do
    slots[index] = { mon = copyValue(slot.mon), steps = slot.steps }
  end
  return {
    schema = DaycareState.SCHEMA,
    slots = slots,
    pendingEggPid = self._pendingEggPid,
    eggCycleCounter = self._eggCycleCounter,
  }
end

---@return integer
function DaycareState:revision()
  return self._revision
end

-- The occupied slot count, which is also the source's one/two-parent state.
---@return integer
function DaycareState:count()
  return #self._slots
end

-- The source's Save_Daycare_GetState answer: an egg waiting outranks the
-- parent count, and every occupied count maps to its own state.
---@return integer
function DaycareState:state()
  if self._pendingEggPid ~= 0 then
    return DaycareState.STATE_EGG_READY
  end
  local count = #self._slots
  if count == 0 then
    return DaycareState.STATE_EMPTY
  end
  return DaycareState.STATE_ONE_MON + (count - 1)
end

---@return integer
function DaycareState:pendingEggPid()
  return self._pendingEggPid
end

---@return integer
function DaycareState:eggCycleCounter()
  return self._eggCycleCounter
end

---@param slot0 integer
---@return table<string, unknown>? detached parent or nil outside the occupied slots
function DaycareState:mon(slot0)
  assert(type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0, "day care slot index is zero-based")
  local slot = self._slots[slot0 + 1]
  if slot == nil then
    return nil
  end
  return copyValue(slot.mon)
end

---@param slot0 integer
---@return integer? the stored walked steps, or nil outside the occupied slots
function DaycareState:steps(slot0)
  assert(type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0, "day care slot index is zero-based")
  local slot = self._slots[slot0 + 1]
  return slot ~= nil and slot.steps or nil
end

-- Last occupied parent, the source's Day-care "tail" mon.
---@return integer? index
function DaycareState:tailSlot()
  if #self._slots == 0 then
    return nil
  end
  return #self._slots - 1
end

-- Stages one deposit at the first free source slot with a zero step counter.
-- The parent record is validated canonically and copied, so the caller keeps
-- its own live record.
---@param expectedRevision integer
---@param mon table<string, unknown>
---@return DaycarePreparation|nil, string|nil
function DaycareState:prepareDeposit(expectedRevision, mon)
  assert(type(expectedRevision) == "number", "day care deposit requires the expected revision")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  if #self._slots >= DaycareState.MAX_SLOTS then
    return nil, "full"
  end
  local slots = copySlots(self)
  slots[#slots + 1] = { mon = self._validateMon(mon), steps = 0 }
  return prepareState(self, slots, self._pendingEggPid, self._eggCycleCounter)
end

-- Stages one withdrawal: the candidate hands the detached parent and its
-- stored steps to the caller during the deposit-safe build, and publication
-- removes the slot and compacts slot 1 into an empty slot 0 exactly like
-- Save_Daycare_Compaction.
---@param expectedRevision integer
---@param slot0 integer zero-based source slot
---@return { prepared: DaycarePreparation, mon: table<string, unknown>, steps: integer }|nil, string|nil
function DaycareState:prepareWithdraw(expectedRevision, slot0)
  assert(type(expectedRevision) == "number", "day care withdrawal requires the expected revision")
  assert(type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0, "day care slot index is zero-based")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  local slot = self._slots[slot0 + 1]
  if slot == nil then
    return nil, "empty"
  end
  local slots = copySlots(self)
  table.remove(slots, slot0 + 1)
  return {
    prepared = prepareState(self, slots, self._pendingEggPid, self._eggCycleCounter),
    mon = copyValue(slot.mon),
    steps = slot.steps,
  }
end

-- Stages one committed walking step: every occupied parent advances its
-- counter (saturating at its unsigned 32-bit ceiling), and the caller's own
-- egg-field outcome replaces the stored pending identity and cycle progress.
-- The source increments the cycle counter on every processed step, so an empty
-- Day Care still stages that field.
---@param expectedRevision integer
---@param advance { pendingEggPid: integer?, eggCycleCounter: integer? }?
---@return DaycarePreparation|nil, string|nil
function DaycareState:prepareStepAdvance(expectedRevision, advance)
  assert(type(expectedRevision) == "number", "day care step advance requires the expected revision")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  local slots = copySlots(self)
  for _, slot in ipairs(slots) do
    if slot.steps < DaycareState.MAX_STEPS then
      slot.steps = slot.steps + 1
    end
  end
  local pendingEggPid = self._pendingEggPid
  local eggCycleCounter = self._eggCycleCounter
  if advance ~= nil then
    if advance.pendingEggPid ~= nil then
      pendingEggPid = checkUnsigned(advance.pendingEggPid, "pending egg pid", DaycareState.MAX_EGG_PID)
    end
    if advance.eggCycleCounter ~= nil then
      eggCycleCounter =
        checkUnsigned(advance.eggCycleCounter, "egg cycle counter", DaycareState.MAX_EGG_CYCLE)
    end
  end
  return prepareState(self, slots, pendingEggPid, eggCycleCounter)
end

-- Stages one produced egg identity: only the pending PID changes, exactly like
-- GenerateEggPID's Save_Daycare_SetEggPID.
---@param expectedRevision integer
---@param pendingEggPid integer
---@return DaycarePreparation|nil, string|nil
function DaycareState:prepareEggPending(expectedRevision, pendingEggPid)
  assert(type(expectedRevision) == "number", "day care egg production requires the expected revision")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  return prepareState(
    self,
    copySlots(self),
    checkUnsigned(pendingEggPid, "pending egg pid", DaycareState.MAX_EGG_PID),
    self._eggCycleCounter
  )
end

-- Stages Save_Daycare_ResetEggStats: the pending identity and the cycle
-- progress clear together, with custody untouched.
---@param expectedRevision integer
---@return DaycarePreparation|nil, string|nil
function DaycareState:prepareEggReset(expectedRevision)
  assert(type(expectedRevision) == "number", "day care egg reset requires the expected revision")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  return prepareState(self, copySlots(self), 0, 0)
end

return DaycareState
