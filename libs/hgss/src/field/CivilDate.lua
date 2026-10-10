-- Proleptic Gregorian day ordinal and Sunday-based weekday for a host civil
-- date, matching the weekday the retail RTC date reports. Pure domain
-- module: no love dependency.

local CivilDate = {}

local function integer(value, minimum, maximum)
  return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

-- Returns the 1-based day ordinal (0001-01-01 is 1) and the weekday with
-- Sunday as zero.
---@param date { year: integer, month: integer, day: integer }
---@return integer ordinal
---@return integer weekday
function CivilDate.parts(date)
  assert(
    type(date) == "table" and integer(date.year, 1, 9999) and integer(date.month, 1, 12) and integer(date.day, 1, 31),
    "LocalClock date must be Gregorian"
  )
  local year, month, day = date.year, date.month, date.day
  local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
  local monthDays = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  assert(day <= monthDays[month], "LocalClock date has an invalid day of month")
  local prior = year - 1
  local ordinal = prior * 365 + math.floor(prior / 4) - math.floor(prior / 100) + math.floor(prior / 400) + day
  for index = 1, month - 1 do
    ordinal = ordinal + monthDays[index]
  end
  -- 0001-01-01 is Monday in the proleptic Gregorian calendar.
  return ordinal, ordinal % 7
end

return CivilDate
