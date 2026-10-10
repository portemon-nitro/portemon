-- The companion-local civil calendar adapter: Gregorian serial arithmetic
-- over validated local-civil samples, with source elapsed-minute and
-- elapsed-day semantics. The field checkpoint and the shared daily seeds
-- persist through the companion state owner; ring cooldowns and backlog
-- policy stay with the runtime caller, which supplies one sample per
-- evaluation. Pure domain module: no love dependency.

local U32 = require("libs.codec.src.U32")

---@class PokegearCalendar
---@field private _state table<string, unknown>
local PokegearCalendar = {}
PokegearCalendar.__index = PokegearCalendar

local SECONDS_PER_DAY = 86400
local PRANDOM_MULTIPLIER = 1812433253

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

---@param year integer
---@param month integer
---@return integer
local function daysInMonth(year, month)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
    return 29
  end
  return days[month]
end

-- Independent Gregorian day serial: days since 1970-01-01 under the DS
-- local civil calendar model, with no host timezone reinterpretation.
---@param moment table<string, integer>
---@return integer
local function daysFromCivil(moment)
  local year = moment.year
  assert(type(year) == "number" and type(moment.month) == "number", "calendar serials read civil dates")
  if moment.month <= 2 then
    year = year - 1
  end
  local era = math.floor((year >= 0 and year or year - 399) / 400)
  local yearOfEra = year - era * 400
  local monthPrime = (moment.month + 9) % 12
  local dayOfYear = math.floor((153 * monthPrime + 2) / 5) + moment.day - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
  return era * 146097 + dayOfEra - 719468
end

-- Inverse of the day serial above, for advancing the checkpoint while
-- preserving a discarded sub-minute remainder.
---@param serial integer
---@return table<string, integer> { year: integer, month: integer, day: integer }
local function civilFromSerial(serial)
  local shifted = serial + 719468
  local era = math.floor((shifted >= 0 and shifted or shifted - 146096) / 146097)
  local dayOfEra = shifted - era * 146097
  local yearOfEra = math.floor(
    (dayOfEra - math.floor(dayOfEra / 1460) + math.floor(dayOfEra / 36524) - math.floor(dayOfEra / 146096)) / 365
  )
  local year = yearOfEra + era * 400
  local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100))
  local monthPrime = math.floor((5 * dayOfYear + 2) / 153)
  local day = dayOfYear - math.floor((153 * monthPrime + 2) / 5) + 1
  local month = monthPrime + 3
  if monthPrime >= 10 then
    month = monthPrime - 9
    year = year + 1
  end
  if month <= 2 then
    year = year + 1
  end
  return { year = year, month = month, day = day }
end

---@param sample table<string, integer>
local function checkSample(sample)
  assert(type(sample) == "table", "calendar observations need a validated civil sample")
  assert(
    isInteger(sample.year)
      and sample.year >= 1
      and isInteger(sample.month)
      and sample.month >= 1
      and sample.month <= 12
      and isInteger(sample.day)
      and sample.day >= 1
      and sample.day <= daysInMonth(sample.year, sample.month)
      and isInteger(sample.hour)
      and sample.hour >= 0
      and sample.hour <= 23
      and isInteger(sample.minute)
      and sample.minute >= 0
      and sample.minute <= 59
      and isInteger(sample.second)
      and sample.second >= 0
      and sample.second <= 59,
    "calendar observations need a validated civil sample"
  )
end

---@param moment table<string, integer>
---@return integer seconds since the serial epoch
local function epochSeconds(moment)
  return daysFromCivil(moment) * SECONDS_PER_DAY + moment.hour * 3600 + moment.minute * 60 + moment.second
end

---@param total integer
---@return table<string, integer> civil moment
local function momentFromEpoch(total)
  local days = math.floor(total / SECONDS_PER_DAY)
  local clock = total - days * SECONDS_PER_DAY
  local date = civilFromSerial(days)
  return {
    year = date.year,
    month = date.month,
    day = date.day,
    hour = math.floor(clock / 3600),
    minute = math.floor((clock % 3600) / 60),
    second = clock % 60,
  }
end

-- Binds the adapter to its companion state owner, which persists the
-- checkpoint and daily identity. Render-free: holds no graphics.
---@param state table<string, unknown>
---@return PokegearCalendar
function PokegearCalendar.new(state)
  assert(type(state) == "table", "calendar observations persist through the companion state")
  assert(type(state.readCalendar) == "function", "calendar observations read the persisted checkpoint")
  assert(type(state.commitCalendar) == "function", "calendar observations commit checkpoint advances")
  return setmetatable({ _state = state }, PokegearCalendar)
end

-- Pure serial helper: seconds since the serial epoch for one validated
-- civil sample. Shared by expiry math so serial arithmetic stays in one
-- owner instead of drifting into parallel copies.
---@param sample table<string, integer>
---@return integer
function PokegearCalendar.epochSeconds(sample)
  checkSample(sample)
  return epochSeconds(sample)
end

-- Pure display helper: the local-civil weekday of one sample, Monday 0
-- through Sunday 6, independent of host timezone handling.
---@param sample table<string, integer>
---@return integer
function PokegearCalendar.weekday(sample)
  checkSample(sample)
  local serial = daysFromCivil(sample)
  return ((serial + 3) % 7 + 7) % 7
end

-- Observes one field sample and reports whole elapsed minutes, whole
-- elapsed days, and backward movement. The checkpoint advances only by
-- completed whole minutes so a discarded remainder carries into the next
-- observation; backward samples rebase the checkpoint and add nothing.
-- Each elapsed day steps the shared daily seed once through the source
-- recurrence and the outbreak seed follows the selected group. The caller
-- owns cooldown and backlog policy from the reported counts.
---@param sample table<string, integer>
---@return { dayAdvance: integer, minuteAdvance: integer, backward: boolean }
function PokegearCalendar:observeField(sample)
  checkSample(sample)
  local state = self._state
  assert(type(state.readCalendar) == "function", "calendar observations read the persisted checkpoint")
  local persisted = state:readCalendar()
  assert(type(persisted) == "table", "calendar observations read a calendar record")
  local serial = daysFromCivil(sample)
  local checkpoint = persisted.checkpoint
  if checkpoint == nil then
    assert(type(state.commitCalendar) == "function", "calendar observations commit checkpoint advances")
    state:commitCalendar({
      checkpoint = {
        year = sample.year,
        month = sample.month,
        day = sample.day,
        hour = sample.hour,
        minute = sample.minute,
        second = sample.second,
      },
      daySerial = serial,
      dailyGroupSeed = persisted.dailyGroupSeed,
      outbreakSeed = persisted.outbreakSeed,
    })
    return { dayAdvance = 0, minuteAdvance = 0, backward = false }
  end
  assert(type(checkpoint) == "table", "calendar observations measure from the checkpoint")
  assert(type(persisted.daySerial) == "number", "calendar observations measure from the last processed day")
  local elapsed = epochSeconds(sample) - epochSeconds(checkpoint)
  -- A sample behind the checkpoint, or behind the last processed day while
  -- the checkpoint kept its remainder, both mean host time moved backwards:
  -- rebase the checkpoint and add no negative minutes.
  if elapsed < 0 or serial - persisted.daySerial < 0 then
    assert(type(state.commitCalendar) == "function", "calendar observations commit checkpoint advances")
    state:commitCalendar({
      checkpoint = {
        year = sample.year,
        month = sample.month,
        day = sample.day,
        hour = sample.hour,
        minute = sample.minute,
        second = sample.second,
      },
      daySerial = serial,
      dailyGroupSeed = persisted.dailyGroupSeed,
      outbreakSeed = persisted.outbreakSeed,
    })
    return { dayAdvance = 0, minuteAdvance = 0, backward = true }
  end
  local wholeMinutes = math.floor(elapsed / 60)
  local dayAdvance = serial - persisted.daySerial
  if wholeMinutes == 0 and dayAdvance == 0 then
    return { dayAdvance = 0, minuteAdvance = 0, backward = false }
  end
  local group = persisted.dailyGroupSeed
  assert(
    type(group) == "number" and group % 1 == 0 and group >= 0 and group <= U32.MAX,
    "calendar observations step an unsigned daily seed"
  )
  for _ = 1, dayAdvance do
    group = U32.add(U32.mul(group, PRANDOM_MULTIPLIER), 1)
  end
  local outbreak = persisted.outbreakSeed
  if dayAdvance > 0 then
    outbreak = group
  end
  local nextCheckpoint = checkpoint
  if wholeMinutes > 0 then
    nextCheckpoint = momentFromEpoch(epochSeconds(checkpoint) + wholeMinutes * 60)
  end
  assert(type(nextCheckpoint) == "table", "calendar observations carry the checkpoint forward")
  assert(type(state.commitCalendar) == "function", "calendar observations commit checkpoint advances")
  state:commitCalendar({
    checkpoint = nextCheckpoint,
    daySerial = serial,
    dailyGroupSeed = group,
    outbreakSeed = outbreak,
  })
  return { dayAdvance = dayAdvance, minuteAdvance = wholeMinutes, backward = false }
end

return PokegearCalendar
