-- SysInfoState tests: the strict persisted home of the retail SysInfo
-- mystery-gift flag. The bucket carries only its schema and the boolean,
-- rejects malformed records without repairing them, and round-trips
-- through capture/restore byte-identically.

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
  Assert.deepEqual(state:capture(), { schema = SysInfoState.SCHEMA, mysteryGiftActive = true })

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

return { tests = T }
