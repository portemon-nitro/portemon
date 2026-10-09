-- Runtime time-of-day selection over normalized field-light profile records.
-- The records are generated from HGSS source text tables; parsing and
-- validation of that source grammar belongs to romdump's
-- HgssFieldLightProfile, and the runtime consumes only the parsed records.
-- A record is active until its endHalfSeconds: the active record is the
-- first that ends later than now, wrapping to the first record past the
-- final end (AreaLightManager_New and
-- AreaLightManager_UpdateActiveTemplate in pret/pokeheartgold
-- asm/overlay_01_021E90C0.s).
-- Pure domain module: no love, no source text knowledge.

local FieldLightProfile = {}

local SECONDS_PER_DAY = 86400
local DEFAULT_TIME_SECONDS = 43200 -- noon

-- The effective half-second bucket selection changes on: the single
-- bucketing rule shared by `select` and by consumers that cache the
-- selection (such as the field renderer), so a bucketing change in the
-- owner can never silently stale a downstream cache.
---@param secondsSinceMidnight number
---@return integer
function FieldLightProfile.bucket(secondsSinceMidnight)
  return math.floor((secondsSinceMidnight % SECONDS_PER_DAY) / 2)
end

-- Select the active record for a wall-clock second-of-day: the first record
-- that ends later than now, or the first record when none does.
---@param profile { records: table[] }
---@param secondsSinceMidnight number
---@return table<string, unknown> record
function FieldLightProfile.select(profile, secondsSinceMidnight)
  assert(profile and profile.records and #profile.records > 0, "profile has no records")
  local halfSeconds = FieldLightProfile.bucket(secondsSinceMidnight)
  for _, rec in ipairs(profile.records) do
    if rec.endHalfSeconds > halfSeconds then
      return rec
    end
  end
  return profile.records[1]
end

FieldLightProfile.DEFAULT_TIME_SECONDS = DEFAULT_TIME_SECONDS

return FieldLightProfile
