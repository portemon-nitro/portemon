-- Tests for the runtime half of FieldLightProfile: time-of-day
-- selection over normalized records. Parsing of the HGSS source text lives
-- with HgssFieldLightProfile under romdump.

local Assert = require("tests.support.Assert")
local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")

local T = {}

-- One record with the given half-second threshold.
local function record(threshold)
  return {
    endHalfSeconds = threshold,
    enabledLightMask = 1,
    lights = {},
    diffuseRgb555 = 0,
    ambientRgb555 = 0,
    specularRgb555 = 0,
    emissionRgb555 = 0,
  }
end

function T.threshold_ends_the_record_interval()
  -- area00light.txt thresholds: a record is active until its own threshold,
  -- so 11:00 (19800 hs) shows the record ending at 11:30 (20700 hs).
  local p = { records = { record(0), record(14400), record(20700), record(21600), record(43200) } }
  Assert.equal(FieldLightProfile.select(p, 39600).endHalfSeconds, 20700) -- 11:00
  Assert.equal(FieldLightProfile.select(p, 41398).endHalfSeconds, 20700) -- 11:29:58
  Assert.equal(FieldLightProfile.select(p, 41400).endHalfSeconds, 21600) -- 11:30
  Assert.equal(FieldLightProfile.select(p, 43200).endHalfSeconds, 43200) -- noon
  -- A zero threshold ends at midnight, so it never stays selected.
  Assert.equal(FieldLightProfile.select(p, 0).endHalfSeconds, 14400)
end

function T.selection_wraps_to_first_record_after_last_threshold()
  -- area01light.txt opens at 900; times past the final threshold carry into
  -- the first record, as does the time before it.
  local p = { records = { record(900), record(21600) } }
  Assert.equal(FieldLightProfile.select(p, 0).endHalfSeconds, 900)
  Assert.equal(FieldLightProfile.select(p, 2000).endHalfSeconds, 21600)
  Assert.equal(FieldLightProfile.select(p, 43200).endHalfSeconds, 900)
end

function T.default_time_is_noon()
  Assert.equal(FieldLightProfile.DEFAULT_TIME_SECONDS, 43200)
end

function T.empty_profile_is_fatal()
  Assert.throws(function()
    FieldLightProfile.select({ records = {} }, 0)
  end)
end

return { tests = T }
