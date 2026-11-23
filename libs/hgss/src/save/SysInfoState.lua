-- Strict persisted state for the retail SysInfo block's product-owned fields.
-- The source SysInfo block carries machine identity (RTC, MAC, profile id) the
-- product never persists; only the mystery-gift active bit scripts touch and
-- the moment the game was first cleared ride here. The bucket carries exactly
-- its schema, the boolean, and the first-clear stamp, rejects malformed records
-- without repairing them, and round-trips through capture/restore. Pure domain
-- code.
--
-- Retail sources: FieldSystem_SetGameClearTime (src/game_clear.c) stores the
-- local RTC date on the first clear only; every later clear keeps the original
-- stamp. A save published before this bucket existed cannot know that moment,
-- so the migration keeps it unknown instead of inventing one.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

---@class SysInfoState
---@field private _active boolean
---@field private _firstClearAt table<string, unknown>|false
local SysInfoState = {}
SysInfoState.__index = SysInfoState

SysInfoState.SCHEMA = "hgss-sys-info-v2"
SysInfoState.STATE_VERSION = 2
SysInfoState.LEGACY_SCHEMA = "hgss-sys-info-v1"

local TOP_FIELDS = { schema = true, stateVersion = true, mysteryGiftActive = true, firstClearAt = true }
local DATE_FIELDS = { year = true, month = true, day = true }

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
---@return table<string, unknown>|false
local function checkFirstClearAt(value)
  if value == false then
    return false
  end
  if type(value) ~= "table" then
    fail("sysInfo first-clear stamp must be false or a date record", {})
  end
  assert(type(value) == "table")
  for key in pairs(value) do
    if DATE_FIELDS[key] ~= true then
      fail("sysInfo first-clear stamp has an unknown field", { field = key })
    end
  end
  local function bounded(field, min, max)
    local number = value[field]
    if not isInteger(number) or number < min or number > max then
      fail("sysInfo first-clear " .. field .. " is invalid", { field = field, value = number })
    end
    return number --[[@as integer]]
  end
  return { year = bounded("year", 0, 9999), month = bounded("month", 1, 12), day = bounded("day", 1, 31) }
end

---@param record table<string, unknown>
---@return table<string, unknown> detached canonical bucket
local function canonicalize(record)
  if type(record.mysteryGiftActive) ~= "boolean" then
    fail("sysInfo mystery-gift flag must be a boolean", {})
  end
  for key in pairs(record) do
    if TOP_FIELDS[key] ~= true then
      fail("sysInfo bucket has an unknown field", { field = key })
    end
  end
  return {
    schema = SysInfoState.SCHEMA,
    stateVersion = SysInfoState.STATE_VERSION,
    mysteryGiftActive = record.mysteryGiftActive,
    firstClearAt = checkFirstClearAt(record.firstClearAt),
  }
end

---@return table<string, unknown>
function SysInfoState.empty()
  return {
    schema = SysInfoState.SCHEMA,
    stateVersion = SysInfoState.STATE_VERSION,
    mysteryGiftActive = false,
    firstClearAt = false,
  }
end

-- Migrates one stored bucket to the current shape. An exact v1 bucket and a
-- current bucket resolve; only exact historical shapes migrate, and malformed
-- current data is reported rather than repaired. An already-cleared save whose
-- v1 bucket has no stamp keeps the moment unknown.
---@param bucket unknown
---@return table<string, unknown> detached canonical bucket
function SysInfoState.migrate(bucket)
  if type(bucket) ~= "table" then
    fail("sysInfo bucket must be a record", {})
  end
  assert(type(bucket) == "table")
  if bucket.schema == SysInfoState.SCHEMA and bucket.stateVersion == SysInfoState.STATE_VERSION then
    return canonicalize(bucket)
  end
  -- The v1 bucket predates the state-version field: its schema and the
  -- boolean are all it carries.
  if bucket.schema == SysInfoState.LEGACY_SCHEMA then
    for key in pairs(bucket) do
      if key ~= "schema" and key ~= "mysteryGiftActive" then
        fail("sysInfo bucket has an unknown field", { field = key })
      end
    end
    return canonicalize({
      schema = SysInfoState.SCHEMA,
      stateVersion = SysInfoState.STATE_VERSION,
      mysteryGiftActive = bucket.mysteryGiftActive,
      firstClearAt = false,
    })
  end
  fail("sysInfo bucket carries an unsupported schema", { schema = bucket.schema })
  error("unreachable", 0)
end

---@param record table<string, unknown> a stored bucket, migrated when historical
---@return SysInfoState
function SysInfoState.new(record)
  local bucket = SysInfoState.migrate(record)
  return setmetatable({
    _active = bucket.mysteryGiftActive == true,
    _firstClearAt = checkFirstClearAt(bucket.firstClearAt),
  }, SysInfoState)
end

---@return boolean
function SysInfoState:isMysteryGiftActive()
  return self._active == true
end

-- Retail ScrCmd_SetMysteryGiftActive has no operand and no clear
-- counterpart: the flag only ever turns on.
function SysInfoState:setMysteryGiftActive()
  self._active = true
end

-- The local date the game was first cleared, or false while it never was or
-- cannot be known.
---@return table<string, unknown>|false
function SysInfoState:firstClearAt()
  local stamp = self._firstClearAt
  if stamp == false then
    return false
  end
  return { year = stamp.year, month = stamp.month, day = stamp.day }
end

-- Stores the first-clear stamp once: a save that already carries a known first
-- clear keeps its original date forever, and an already-cleared save whose v1
-- bucket could not store one never fabricates it.
---@param date { year: integer, month: integer, day: integer }
---@return boolean whether the stamp was stored
function SysInfoState:setFirstClearAt(date)
  if self._firstClearAt ~= false then
    return false
  end
  self._firstClearAt = checkFirstClearAt({ year = date.year, month = date.month, day = date.day })
  return true
end

---@return table<string, unknown> detached canonical bucket
function SysInfoState:capture()
  return canonicalize({
    schema = SysInfoState.SCHEMA,
    stateVersion = SysInfoState.STATE_VERSION,
    mysteryGiftActive = self._active == true,
    firstClearAt = self._firstClearAt,
  })
end

return SysInfoState
