-- Strict source-record owner for the five Battle Frontier Trainer Card counters.
local Errors = require("libs.errors.src.Errors")

---@class BattleFrontierRecords
---@field private _streaks integer[]
local BattleFrontierRecords = {}
BattleFrontierRecords.__index = BattleFrontierRecords

BattleFrontierRecords.SCHEMA = "hgss-battle-frontier-records-v1"
BattleFrontierRecords.STATE_VERSION = 1
BattleFrontierRecords.COUNTER_COUNT = 5

-- Retail Trainer Card reads record IDs 0, 2, 4, 6, and 8; array slots
-- preserve that source order without exposing raw IDs to the runtime API.
local SOURCE_RECORD_IDS = { 0, 2, 4, 6, 8 }

---@param streaks unknown
---@return integer[]
local function validateStreaks(streaks)
  if type(streaks) ~= "table" or #streaks ~= BattleFrontierRecords.COUNTER_COUNT then
    Errors.raise("BATTLE_FRONTIER_RECORDS_INVALID", "five battle frontier streaks are required", {})
  end
  local copy = {}
  for index = 1, BattleFrontierRecords.COUNTER_COUNT do
    local value = streaks[index]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 0xFFFF then
      Errors.raise("BATTLE_FRONTIER_RECORDS_INVALID", "battle frontier streak is outside u16", { index = index })
    end
    copy[index] = value
  end
  for key in pairs(streaks) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > BattleFrontierRecords.COUNTER_COUNT then
      Errors.raise("BATTLE_FRONTIER_RECORDS_INVALID", "battle frontier streaks contain an unknown entry", { key = key })
    end
  end
  return copy
end

---@param streaks integer[]
---@return BattleFrontierRecords
local function withStreaks(streaks)
  return setmetatable({ _streaks = streaks }, BattleFrontierRecords)
end

---@return BattleFrontierRecords
function BattleFrontierRecords.new()
  return withStreaks({ 0, 0, 0, 0, 0 })
end

---@param bucket unknown
---@return BattleFrontierRecords
function BattleFrontierRecords.restore(bucket)
  if type(bucket) ~= "table" then
    Errors.raise("BATTLE_FRONTIER_RECORDS_INVALID", "battle frontier record bucket is required", {})
  end
  local fields = 0
  for key in pairs(bucket) do
    if key ~= "schema" and key ~= "stateVersion" and key ~= "streaks" then
      Errors.raise("BATTLE_FRONTIER_RECORDS_INVALID", "battle frontier record bucket has an unknown field", {
        field = key,
      })
    end
    fields = fields + 1
  end
  if fields ~= 3 or bucket.schema ~= BattleFrontierRecords.SCHEMA then
    Errors.raise("BATTLE_FRONTIER_RECORDS_INVALID", "battle frontier record schema is invalid", {})
  end
  if bucket.stateVersion ~= BattleFrontierRecords.STATE_VERSION then
    Errors.raise("BATTLE_FRONTIER_RECORDS_INVALID", "battle frontier record version is invalid", {})
  end
  return withStreaks(validateStreaks(bucket.streaks))
end

---@param index integer one of the five records read by the source helper
---@param streak integer
function BattleFrontierRecords:record(index, streak)
  assert(index >= 1 and index <= BattleFrontierRecords.COUNTER_COUNT and index % 1 == 0, "record index must be 1..5")
  assert(streak >= 0 and streak <= 0xFFFF and streak % 1 == 0, "streak must be a u16")
  self._streaks[index] = math.max(self._streaks[index], streak)
end

---@param sourceRecordId integer retail record identifier
---@param streak integer
function BattleFrontierRecords:recordSourceId(sourceRecordId, streak)
  for slot, recordId in ipairs(SOURCE_RECORD_IDS) do
    if recordId == sourceRecordId then
      self:record(slot, streak)
      return
    end
  end
  Errors.raise("BATTLE_FRONTIER_RECORDS_INVALID", "unknown source battle frontier record", {
    sourceRecordId = sourceRecordId,
  })
end

---@param threshold integer
---@return boolean
function BattleFrontierRecords:allAtLeast(threshold)
  for _, streak in ipairs(self._streaks) do
    if streak < threshold then
      return false
    end
  end
  return true
end

---@return table<string, unknown>
function BattleFrontierRecords:bucket()
  local streaks = {}
  for index, streak in ipairs(self._streaks) do
    streaks[index] = streak
  end
  return { schema = BattleFrontierRecords.SCHEMA, stateVersion = BattleFrontierRecords.STATE_VERSION, streaks = streaks }
end

return BattleFrontierRecords
