-- SysInfoState tests: the strict persisted home of the retail SysInfo
-- mystery-gift flag and the moment the game was first cleared. The bucket
-- carries only its schema, the boolean and the first-clear stamp, rejects
-- malformed records without repairing them, and round-trips through
-- capture/restore byte-identically.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local SysInfoState = require("libs.hgss.src.save.SysInfoState")

local T = {}

-- The SysInfo lifecycle: the empty bucket starts inactive, live state
-- reports inactive until latched, the latch is idempotent with no clear
-- counterpart, and the capture round-trips byte-identically through
-- restore. One sequential test owns the happy path; malformed records
-- stay a separate failure contract below.
function T.mystery_gift_lifecycle_starts_inactive_latches_once_and_round_trips()
  local bucket = SysInfoState.empty()
  Assert.equal(bucket.schema, SysInfoState.SCHEMA)
  Assert.isFalse(bucket.mysteryGiftActive)

  local state = SysInfoState.new(bucket)
  Assert.isFalse(state:isMysteryGiftActive(), "fresh state reports inactive")
  state:setMysteryGiftActive()
  Assert.isTrue(state:isMysteryGiftActive(), "the latch activates the flag")
  state:setMysteryGiftActive()
  Assert.isTrue(state:isMysteryGiftActive(), "re-latching never deactivates")
  Assert.deepEqual(state:capture(), {
    schema = SysInfoState.SCHEMA,
    stateVersion = SysInfoState.STATE_VERSION,
    mysteryGiftActive = true,
    firstClearAt = false,
  })

  local restored = SysInfoState.new(state:capture())
  Assert.isTrue(restored:isMysteryGiftActive())
  Assert.deepEqual(restored:capture(), state:capture(), "the capture round-trips through restore")
end

function T.malformed_records_are_reported_never_repaired()
  local cases = {
    nil,
    {},
    { schema = SysInfoState.SCHEMA },
    { schema = SysInfoState.SCHEMA, mysteryGiftActive = nil },
    { schema = SysInfoState.SCHEMA, stateVersion = SysInfoState.STATE_VERSION, mysteryGiftActive = false },
    { schema = SysInfoState.SCHEMA, stateVersion = 1, mysteryGiftActive = false, firstClearAt = false },
    { schema = SysInfoState.SCHEMA, stateVersion = SysInfoState.STATE_VERSION, mysteryGiftActive = false,
      firstClearAt = { year = 2000, month = 0, day = 1 } },
    { schema = SysInfoState.SCHEMA, stateVersion = SysInfoState.STATE_VERSION, mysteryGiftActive = false,
      firstClearAt = { year = 2000, month = 1 } },
    { schema = SysInfoState.SCHEMA, stateVersion = SysInfoState.STATE_VERSION, mysteryGiftActive = false,
      firstClearAt = "2000-01-01" },
    { schema = SysInfoState.SCHEMA, mysteryGiftActive = 0 },
    { schema = SysInfoState.SCHEMA, mysteryGiftActive = 1 },
    { schema = SysInfoState.SCHEMA, mysteryGiftActive = "true" },
    { schema = "hgss-sys-info-v0", mysteryGiftActive = false },
    { schema = SysInfoState.SCHEMA, mysteryGiftActive = false, extra = true },
  }
  for _, record in ipairs(cases) do
    local ok, err = pcall(SysInfoState.new, record)
    Assert.isFalse(ok, "malformed sysInfo record must not construct")
    Assert.isTrue(Errors.is(err), "malformed sysInfo record reports a structured error")
  end
end

-- The first-clear stamp is written once: the first legitimate clear stores the
-- local date, every later clear keeps it, and an inherited v1 bucket keeps the
-- moment unknown instead of inventing one.
function T.first_clear_stamp_is_stored_once_and_v1_migrates_unknown()
  local state = SysInfoState.new(SysInfoState.empty())
  Assert.equal(state:firstClearAt(), false, "a fresh save knows no first clear")
  Assert.isTrue(state:setFirstClearAt({ year = 2000, month = 1, day = 1 }), "the first clear stores its date")
  Assert.deepEqual(state:firstClearAt(), { year = 2000, month = 1, day = 1 }, "the stored date reads back")
  Assert.isFalse(
    state:setFirstClearAt({ year = 2001, month = 2, day = 2 }),
    "a later clear never rewrites the original first-clear moment"
  )
  Assert.deepEqual(state:firstClearAt(), { year = 2000, month = 1, day = 1 }, "the original date survives")

  local migrated = SysInfoState.migrate({ schema = "hgss-sys-info-v1", mysteryGiftActive = true })
  Assert.equal(migrated.schema, SysInfoState.SCHEMA, "a v1 bucket migrates to the current schema")
  Assert.equal(migrated.stateVersion, SysInfoState.STATE_VERSION, "a v1 bucket migrates to the current state version")
  Assert.equal(migrated.mysteryGiftActive, true, "a v1 bucket keeps its mystery-gift flag")
  Assert.equal(migrated.firstClearAt, false, "a v1 bucket cannot know its first-clear moment")
  local restored = SysInfoState.new({ schema = "hgss-sys-info-v1", mysteryGiftActive = false })
  Assert.equal(restored:firstClearAt(), false, "a migrated v1 bucket reports no first clear")
  Assert.isTrue(
    restored:setFirstClearAt({ year = 2000, month = 3, day = 4 }),
    "a migrated v1 bucket still stores its next legitimate clear"
  )
  local roundTrip = SysInfoState.new(restored:capture())
  Assert.deepEqual(roundTrip:firstClearAt(), { year = 2000, month = 3, day = 4 }, "the stamp round-trips")
  Assert.isFalse(roundTrip:setFirstClearAt({ year = 2002, month = 5, day = 6 }), "the stamp never moves again")
end

return { tests = T }
