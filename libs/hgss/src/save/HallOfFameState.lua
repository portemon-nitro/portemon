-- Strict persisted Hall of Fame history: the source's ring of recorded clears
-- with its own independent sequence number. The newest clear answers first, the
-- retained window keeps the source capacity, and every record is a detached
-- by-value snapshot a later party can never rewrite. An entry that lost its
-- records is unavailable rather than plausible: its sequence restarts with the
-- next recorded clear, exactly like the source reinitializing an unreadable
-- history chunk. Pure domain code: no live party, no love dependency.
--
-- Retail sources: src/hall_of_fame.c Save_HOF_RecordParty snapshots every
-- non-Egg party member by value (species, level, form, personality, OT id, four
-- moves, nickname, OT name) with the local date and increments `num_total`
-- while it stays below 9999; Save_HOF_GetNumRecords clamps the retained window
-- to NUM_HOF_RECORDS 30 and Save_HOF_TranslateRecordIdx(hof, 0) is num_total.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

---@class HallOfFameState
---@field private _records table<string, unknown>[] newest first
---@field private _total integer recorded clears, capped at the source ceiling
local HallOfFameState = {}
HallOfFameState.__index = HallOfFameState

HallOfFameState.SCHEMA = "hgss-hall-of-fame-v1"
HallOfFameState.STATE_VERSION = 1
-- src/hall_of_fame.c NUM_HOF_RECORDS.
HallOfFameState.CAPACITY = 30
-- Save_HOF_RecordParty records nothing once num_total reached 9999.
HallOfFameState.TOTAL_CAP = 9999

local MOVE_SLOTS = 4
local TOP_FIELDS = { schema = true, stateVersion = true, total = true, records = true }
local DATE_FIELDS = { year = true, month = true, day = true }
local MON_FIELDS = {
  species = true,
  level = true,
  form = true,
  personality = true,
  otId = true,
  otName = true,
  nickname = true,
  moves = true,
}
local RECORD_FIELDS = { date = true, party = true }

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, context)
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

---@param value unknown
---@param what string
---@return integer
local function checkBoundedInteger(value, what, min, max)
  if not isInteger(value) or value < min or value > max then
    fail("hall of fame " .. what .. " must be an integer in " .. min .. ".." .. max, { field = what, value = value })
  end
  return value --[[@as integer]]
end

---@param value unknown
---@param what string
---@return string
local function checkText(value, what)
  if type(value) ~= "string" then
    fail("hall of fame " .. what .. " must be text", { field = what })
  end
  return value --[[@as string]]
end

---@param record table<string, unknown>
---@param allowed table<string, boolean>
---@param what string
local function checkFields(record, allowed, what)
  for key in pairs(record) do
    if allowed[key] ~= true then
      fail("hall of fame " .. what .. " has an unknown field", { field = key })
    end
  end
end

---@param value unknown
---@return table<string, unknown>
local function checkDate(value)
  if type(value) ~= "table" then
    fail("hall of fame record date must be a record", {})
  end
  assert(type(value) == "table")
  checkFields(value, DATE_FIELDS, "record date")
  return {
    year = checkBoundedInteger(value.year, "record year", 0, 9999),
    month = checkBoundedInteger(value.month, "record month", 1, 12),
    day = checkBoundedInteger(value.day, "record day", 1, 31),
  }
end

-- One recorded party member by value. The source pads unused move slots with
-- MOVE_NONE, so an empty slot stays an empty name rather than a catalog
-- reference this bucket cannot resolve.
---@param value unknown
---@param where string
---@return table<string, unknown>
local function checkMon(value, where)
  if type(value) ~= "table" then
    fail("hall of fame " .. where .. " must be a record", {})
  end
  assert(type(value) == "table")
  checkFields(value, MON_FIELDS, where)
  local species = checkText(value.species, where .. " species")
  if species == "" then
    fail("hall of fame " .. where .. " names no species", {})
  end
  checkBoundedInteger(value.level, where .. " level", 1, 100)
  checkBoundedInteger(value.form, where .. " form", 0, 0xFFFF)
  checkBoundedInteger(value.personality, where .. " personality", 0, 0xFFFFFFFF)
  checkBoundedInteger(value.otId, where .. " OT id", 0, 0xFFFFFFFF)
  local moves = value.moves
  if type(moves) ~= "table" then
    fail("hall of fame " .. where .. " moves must be an array", {})
  end
  assert(type(moves) == "table")
  local checked = {}
  for index = 1, MOVE_SLOTS do
    local move = moves[index]
    if type(move) ~= "string" then
      fail("hall of fame " .. where .. " must keep its four move slots", { slot = index })
    end
    checked[index] = move
  end
  for key in pairs(moves) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > MOVE_SLOTS then
      fail("hall of fame " .. where .. " must keep exactly four move slots", { slot = tostring(key) })
    end
  end
  return {
    species = species,
    level = value.level,
    form = value.form,
    personality = value.personality,
    otId = value.otId,
    otName = checkText(value.otName, where .. " OT name"),
    nickname = checkText(value.nickname, where .. " nickname"),
    moves = checked,
  }
end

---@param value unknown
---@param where string
---@return table<string, unknown>
local function checkRecord(value, where)
  if type(value) ~= "table" then
    fail("hall of fame " .. where .. " must be a record", {})
  end
  assert(type(value) == "table")
  checkFields(value, RECORD_FIELDS, where)
  local party = value.party
  if type(party) ~= "table" then
    fail("hall of fame " .. where .. " party must be an array", {})
  end
  assert(type(party) == "table")
  local checked = {}
  local count = 0
  for key in pairs(party) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      fail("hall of fame " .. where .. " party must be a dense array", {})
    end
    count = count + 1
  end
  if count == 0 then
    fail("hall of fame " .. where .. " records no party member", {})
  end
  for index = 1, count do
    if party[index] == nil then
      fail("hall of fame " .. where .. " party must be a dense array", {})
    end
    checked[index] = checkMon(party[index], where .. " party slot " .. index)
  end
  return { date = checkDate(value.date), party = checked }
end

---@param value unknown
---@param what string
---@return table<string, unknown>[]
local function checkRecords(value, what)
  if type(value) ~= "table" then
    fail("hall of fame " .. what .. " must be an array", {})
  end
  assert(type(value) == "table")
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      fail("hall of fame " .. what .. " must be a dense array", {})
    end
    count = count + 1
  end
  if count > HallOfFameState.CAPACITY then
    fail("hall of fame " .. what .. " exceeds the source capacity", { count = count })
  end
  local checked = {}
  for index = 1, count do
    if value[index] == nil then
      fail("hall of fame " .. what .. " must be a dense array", {})
    end
    checked[index] = checkRecord(value[index], "record " .. index)
  end
  return checked
end

---@param record table<string, unknown>
---@return table<string, unknown>
local function checkBucket(record)
  if type(record) ~= "table" then
    fail("hall of fame bucket must be a record", {})
  end
  assert(type(record) == "table")
  if record.schema ~= HallOfFameState.SCHEMA then
    fail("hall of fame schema is invalid", { schema = record.schema })
  end
  if record.stateVersion ~= HallOfFameState.STATE_VERSION then
    fail("hall of fame state version is incompatible", { stateVersion = record.stateVersion })
  end
  checkFields(record, TOP_FIELDS, "bucket")
  local total = checkBoundedInteger(record.total, "total", 0, HallOfFameState.TOTAL_CAP)
  local records = checkRecords(record.records, "records")
  return { total = total, records = records }
end

---@return HallOfFameState
function HallOfFameState.empty()
  return setmetatable({ _records = {}, _total = 0 }, HallOfFameState)
end

-- Restores one stored bucket. A missing bucket is the source's missing history
-- chunk: unavailable, never a fabricated sequence. A bucket that kept its
-- sequence but lost its records is unavailable the same way, so a later clear
-- reinitializes it instead of continuing a sequence nothing backs.
---@param bucket unknown
---@return HallOfFameState
function HallOfFameState.restore(bucket)
  if bucket == nil then
    return HallOfFameState.empty()
  end
  local checked = checkBucket(bucket --[[@as table<string, unknown>]])
  local state = setmetatable({ _records = checked.records, _total = checked.total }, HallOfFameState)
  if #state._records == 0 then
    state._total = 0
  end
  return state
end

---@return boolean
function HallOfFameState:isAvailable()
  return #self._records > 0
end

---@return integer retained record count
function HallOfFameState:count()
  return #self._records
end

-- The source's recorded-clear sequence: Save_HOF_TranslateRecordIdx(hof, 0).
---@return integer
function HallOfFameState:total()
  return self._total
end

-- Reads one retained record by zero-based recency (zero is the newest clear) as
-- a detached copy, or nil outside the retained window.
---@param index0 integer
---@return table<string, unknown>|nil
local function readRecord(self, index0)
  assert(
    type(index0) == "number" and index0 % 1 == 0 and index0 >= 0,
    "hall of fame record index is a zero-based integer"
  )
  local record = self._records[index0 + 1]
  if record == nil then
    return nil
  end
  return checkRecord(record, "record " .. (index0 + 1))
end

-- Records one completed clear: the entry lands newest-first, the retained
-- window drops past the source capacity, and the sequence stops at its ceiling
-- (the source records nothing more once num_total reached 9999). Returns
-- whether the clear was recorded.
---@param entry table<string, unknown>
---@return boolean
function HallOfFameState:recordClear(entry)
  if self._total >= HallOfFameState.TOTAL_CAP then
    return false
  end
  local checked = checkRecord(entry, "new record")
  local records = { checked }
  for index = 1, math.min(#self._records, HallOfFameState.CAPACITY - 1) do
    records[#records + 1] = self._records[index]
  end
  self._records = records
  self._total = self._total + 1
  return true
end

-- The owner API the source capture path calls: a table argument records one
-- clear, a zero-based number reads one retained record.
---@param argument integer|table<string, unknown>
---@return boolean|table<string, unknown>|nil
function HallOfFameState:record(argument)
  if type(argument) == "table" then
    return self:recordClear(argument)
  end
  return readRecord(self, argument --[[@as integer]])
end

-- Drops the whole history, the source's Save_HOF_Init before the first record
-- of a save that was never cleared.
function HallOfFameState:reset()
  self._records = {}
  self._total = 0
end

---@return table<string, unknown> detached canonical bucket
function HallOfFameState:capture()
  local records = {}
  for index, record in ipairs(self._records) do
    records[index] = checkRecord(record, "record " .. index)
  end
  return {
    schema = HallOfFameState.SCHEMA,
    stateVersion = HallOfFameState.STATE_VERSION,
    total = self._total,
    records = records,
  }
end

return HallOfFameState
