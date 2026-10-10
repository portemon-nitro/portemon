-- CivilDate contract tests: the proleptic Gregorian day ordinal and the
-- Sunday-based weekday the retail RTC date reports.

local Assert = require("tests.support.Assert")
local CivilDate = require("libs.hgss.src.field.CivilDate")

local T = {}

function T.weekday_is_sunday_based_across_a_leap_day()
  local _, thursday = CivilDate.parts({ year = 2024, month = 2, day = 29 })
  Assert.equal(thursday, 4)
  local _, sunday = CivilDate.parts({ year = 2024, month = 3, day = 3 })
  Assert.equal(sunday, 0)
  local _, monday = CivilDate.parts({ year = 1, month = 1, day = 1 })
  Assert.equal(monday, 1)
end

function T.ordinal_advances_one_per_day_and_rejects_impossible_dates()
  local first = CivilDate.parts({ year = 2023, month = 12, day = 31 })
  local second = CivilDate.parts({ year = 2024, month = 1, day = 1 })
  Assert.equal(second, first + 1)
  Assert.throws(function()
    CivilDate.parts({ year = 2023, month = 2, day = 29 })
  end)
end

return { tests = T }
