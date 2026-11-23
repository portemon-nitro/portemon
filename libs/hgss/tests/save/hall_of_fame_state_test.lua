-- The saved Hall of Fame history: newest-first bounded records, an independent
-- total sequence, and detached by-value snapshots a later party can never
-- rewrite. The owner is a closed save schema: it restores only what it
-- understands, rejects malformed records without repairing them, drops Eggs and
-- empty slots, and resets an unavailable or invalid history when a new record
-- arrives.

local Assert = require("tests.support.Assert")
local HallOfFameState = require("libs.hgss.src.save.HallOfFameState")

local T = { tests = {} }

local SCHEMA = "hgss-hall-of-fame-v1"
local CAPACITY = 30
local TOTAL_CAP = 9999

---@param species string
---@param level integer
---@return table
local function mon(species, level)
  return {
    species = species,
    level = level,
    form = 0,
    personality = 123456789,
    otId = 4242,
    otName = "GOLD",
    nickname = species,
    moves = { "FLAMETHROWER", "EMBER", "TACKLE", "GROWL" },
  }
end

---@param year integer
---@param month integer
---@param day integer
---@return table
local function date(year, month, day)
  return { year = year, month = month, day = day }
end

---@return table
local function team()
  return { date = date(2000, 1, 1), party = { mon("TYPHLOSION", 60), mon("PIDGEOT", 55) } }
end

---@param count integer
---@param firstTotal integer?
---@return table
local function bucket(count, firstTotal)
  local records = {}
  for index = 1, count do
    records[index] = team()
  end
  return {
    schema = SCHEMA,
    stateVersion = 1,
    total = firstTotal or count,
    records = records,
  }
end

function T.tests.empty_history_reports_an_unavailable_owner()
  local state = HallOfFameState.restore(nil)
  Assert.equal(state:count(), 0, "a save with no history retains no record")
  Assert.equal(state:total(), 0, "a save with no history owns no recorded clear")
  Assert.isNil(state:record(0), "an unavailable history answers no record")
end

function T.tests.roundtrip_keeps_the_stored_records_and_sequence()
  local restored = HallOfFameState.restore(bucket(3))
  Assert.equal(restored:count(), 3, "the restored history keeps its records")
  Assert.equal(restored:total(), 3, "the restored history keeps its sequence")
  local captured = restored:capture()
  Assert.equal(captured.schema, SCHEMA, "the captured history carries its schema")
  Assert.equal(#captured.records, 3, "the captured history keeps every retained record")
  Assert.equal(captured.records[1].party[1].species, "TYPHLOSION", "a record keeps its party by value")
end

function T.tests.newest_record_lands_first_and_older_records_drop_at_the_capacity()
  local state = HallOfFameState.restore(nil)
  for index = 1, CAPACITY + 5 do
    local entry = team()
    entry.party[1].level = index
    state:record(entry)
  end
  Assert.equal(state:count(), CAPACITY, "the history retains only its source capacity")
  Assert.equal(state:total(), CAPACITY + 5, "the sequence counts every recorded clear")
  Assert.equal(state:record(0).party[1].level, CAPACITY + 5, "the newest record answers first")
  Assert.equal(state:record(CAPACITY - 1).party[1].level, 6, "the oldest retained record is the source window's end")
  Assert.isNil(state:record(CAPACITY), "no record survives past the source capacity")
end

function T.tests.sequence_cap_stops_recording()
  local state = HallOfFameState.restore(bucket(1, TOTAL_CAP))
  local entry = team()
  entry.party[1].level = 99
  Assert.isFalse(state:record(entry), "a full sequence records nothing")
  Assert.equal(state:total(), TOTAL_CAP, "the sequence stays at its source ceiling")
  Assert.equal(state:count(), 1, "a full sequence retains what it already stored")
  Assert.equal(state:record(0).party[1].level, 60, "a full sequence leaves its newest record untouched")
end

function T.tests.recording_snapshots_the_party_by_value()
  local state = HallOfFameState.restore(nil)
  local entry = team()
  Assert.isTrue(state:record(entry), "the first record is accepted")
  -- The caller keeps owning its tables: later edits never reach the history.
  entry.party[1].species = "AMPHAROS"
  entry.party[1].level = 1
  entry.party[2] = nil
  entry.date.year = 1999
  local stored = state:record(0)
  Assert.equal(stored.party[1].species, "TYPHLOSION", "a recorded clear keeps the party it captured")
  Assert.equal(stored.party[1].level, 60, "a recorded clear keeps the levels it captured")
  Assert.equal(#stored.party, 2, "a recorded clear keeps its party size")
  Assert.equal(stored.date.year, 2000, "a recorded clear keeps the date it captured")
  -- The detached view the caller reads is a copy, not the saved record.
  stored.party[1].species = "AMPHAROS"
  Assert.equal(state:record(0).party[1].species, "TYPHLOSION", "a read record is a detached snapshot")
end

function T.tests.new_record_resets_an_unavailable_history_but_keeps_a_readable_one()
  local unreadable = HallOfFameState.restore({ schema = SCHEMA, stateVersion = 1, total = 4, records = {} })
  Assert.equal(unreadable:total(), 0, "a history that lost its records is unavailable, not plausible")
  Assert.isTrue(unreadable:record(team()), "a new clear still records")
  Assert.equal(unreadable:total(), 1, "the unavailable sequence restarts at the first new clear")

  local readable = HallOfFameState.restore(bucket(2))
  Assert.isTrue(readable:record(team()), "a new clear on a readable history records")
  Assert.equal(readable:total(), 3, "a readable sequence continues from where it was")
  Assert.equal(readable:count(), 3, "a readable history keeps its records")
end

function T.tests.malformed_buckets_fail_instead_of_repairing()
  local cases = {
    { schema = "hgss-hall-of-fame-v0", stateVersion = 1, total = 0, records = {} },
    { schema = SCHEMA, stateVersion = 1, total = -1, records = {} },
    { schema = SCHEMA, stateVersion = 1, total = TOTAL_CAP + 1, records = {} },
    { schema = SCHEMA, stateVersion = 1, total = 1, records = "none" },
  }
  for index, record in ipairs(cases) do
    local ok = pcall(HallOfFameState.restore, record)
    Assert.isFalse(ok, "malformed history bucket " .. index .. " is rejected instead of repaired")
  end
end

return T
