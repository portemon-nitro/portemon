local Assert = require("tests.support.Assert")
local BattleFrontierRecords = require("libs.hgss.src.save.BattleFrontierRecords")

local T = {}

function T.new_record_owner_starts_with_five_source_counters_and_updates_monotonically()
  local records = BattleFrontierRecords.new()
  Assert.deepEqual(records:bucket(), {
    schema = BattleFrontierRecords.SCHEMA,
    stateVersion = BattleFrontierRecords.STATE_VERSION,
    streaks = { 0, 0, 0, 0, 0 },
  })
  records:record(1, 100)
  records:record(2, 120)
  records:record(2, 90)
  Assert.deepEqual(records:bucket().streaks, { 100, 120, 0, 0, 0 })
  records:recordSourceId(8, 100)
  Assert.equal(records:bucket().streaks[5], 100, "source record 8 maps to the fifth stored slot")
  local sourceRecordIds = { 0, 2, 4, 6, 8 }
  for _, sourceRecordId in ipairs(sourceRecordIds) do
    local qualifying = BattleFrontierRecords.new()
    qualifying:recordSourceId(sourceRecordId, 100)
    Assert.isTrue(qualifying:qualifiesForTrainerCardStar(), "record " .. sourceRecordId .. " qualifies alone")
    qualifying:recordSourceId(sourceRecordId, 120)
    Assert.isTrue(qualifying:qualifiesForTrainerCardStar(), "record " .. sourceRecordId .. " remains qualified above 100")
  end

  local belowThreshold = BattleFrontierRecords.new()
  for _, sourceRecordId in ipairs(sourceRecordIds) do
    belowThreshold:recordSourceId(sourceRecordId, 99)
  end
  Assert.isFalse(belowThreshold:qualifiesForTrainerCardStar())
end

function T.restoration_rejects_missing_or_malformed_record_counters()
  local ok, err = pcall(BattleFrontierRecords.restore, {})
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("schema", 1, true) ~= nil)

  ok = pcall(BattleFrontierRecords.restore, {
    schema = BattleFrontierRecords.SCHEMA,
    stateVersion = BattleFrontierRecords.STATE_VERSION,
    streaks = { 100, 100, -1, 100, 100 },
  })
  Assert.isFalse(ok)
end

return { tests = T }
