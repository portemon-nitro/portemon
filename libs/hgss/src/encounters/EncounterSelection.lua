-- Native encounter opportunity, table, slot, and level selection. The order is
-- normative: the opportunity roll is compared against the method rate, the
-- slot roll walks the ordered per-method interval ladder without merging
-- equal species, and the level roll resolves inside the selected slot's
-- window (land slots carry a single fixed level, read with no roll).
-- Before the slot roll, a magnet-pull or static lead may coerce the slot:
-- on a passed 50% gate the pick is a uniform index into the ordered
-- matching-type slots, and an empty or total match falls through to the
-- normal roll. Rolls arrive already normalized; validation rejects
-- out-of-range rates and rolls at this boundary before any draw is
-- consumed. Pure domain module: no love dependency and no random source
-- of its own.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

---@class EncounterSelection
local EncounterSelection = {}

EncounterSelection.MAX_RATE = 255
EncounterSelection.MAX_ROLL = 99
EncounterSelection.MAX_DRAW = 65535

-- Methods without provider slot data fail with the missing-table contract;
-- anything else unrecognized is invalid caller input.
local METHODS_WITHOUT_TABLES = {
  headbutt = true,
  safari = true,
  bug_contest = true,
  unown = true,
  roaming = true,
}

local ROD_KEYS = {
  old_rod = "oldRod",
  good_rod = "goodRod",
  super_rod = "superRod",
}

---@param value unknown
---@param lower integer
---@param upper integer
---@param what string
---@return integer
local function checkRangedInteger(value, lower, upper, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < lower or value > upper then
    Errors.raise("ENCOUNTER_INVALID_INPUT", what .. " must be an integer in " .. lower .. ".." .. upper, {})
  end
  return value
end

-- Compares a normalized roll against the method rate: rolls strictly below
-- the rate trigger, a zero rate never triggers, and a full rate always does.
---@param rate integer
---@param roll integer
---@return boolean
function EncounterSelection.trigger(rate, roll)
  checkRangedInteger(rate, 0, EncounterSelection.MAX_RATE, "encounter rate")
  checkRangedInteger(roll, 0, EncounterSelection.MAX_ROLL, "encounter roll")
  return roll < rate
end

---@param slots table<string, unknown>[]
---@param roll integer
---@return integer 1-based slot index into the ordered ladder
function EncounterSelection.selectSlot(slots, roll)
  if not Validate.isArray(slots) or #slots == 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slots must be a non-empty array", {})
  end
  assert(type(slots) == "table", "slot selection walks its ordered ladder")
  checkRangedInteger(roll, 0, EncounterSelection.MAX_ROLL, "encounter roll")
  local running = 0
  for index, slot in ipairs(slots) do
    if type(slot) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. index .. " must be a record", {})
    end
    local weight = slot.weight
    if type(weight) ~= "number" or weight % 1 ~= 0 or weight < 0 then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. index .. " carries an invalid weight", {})
    end
    running = running + weight
    if roll < running then
      return index
    end
  end
  -- Native interval ladders end in a final else: a roll past every stated
  -- width still selects the last slot.
  return #slots
end

-- Resolves the level inside the slot's source window, wrapping rolls larger
-- than the span. Fixed single-level slots ignore the roll.
---@param slot table<string, unknown>
---@param roll integer
---@return integer
function EncounterSelection.selectLevel(slot, roll)
  if type(slot) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter level selection requires a slot record", {})
  end
  assert(type(slot) == "table", "level selection reads the slot window")
  local minLevel = slot.minLevel
  local maxLevel = slot.maxLevel
  if
    type(minLevel) ~= "number"
    or minLevel % 1 ~= 0
    or minLevel < 0
    or minLevel > 255
    or type(maxLevel) ~= "number"
    or maxLevel % 1 ~= 0
    or maxLevel < 0
    or maxLevel > 255
    or minLevel > maxLevel
  then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot carries an invalid level window", {})
  end
  assert(type(minLevel) == "number" and type(maxLevel) == "number", "the slot window carries its bounds")
  checkRangedInteger(roll, 0, EncounterSelection.MAX_DRAW, "encounter roll")
  local span = maxLevel - minLevel + 1
  return minLevel + (roll % span)
end

-- Reselects the highest-level same-species slot for the slot-level
-- ability: walks every slot in order, keeping the last strictly higher
-- same-species maximum, matching the native reseat loop.
---@param slots table<string, unknown>[] ordered slots
---@param chosen integer 1-based selected slot index
---@return integer 1-based reselected slot index
function EncounterSelection.highestSameSpeciesSlot(slots, chosen)
  if not Validate.isArray(slots) or #slots == 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slots must be a non-empty array", {})
  end
  assert(type(slots) == "table", "slot reselection walks its ordered ladder")
  if type(chosen) ~= "number" or chosen % 1 ~= 0 or chosen < 1 or chosen > #slots then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot selection is outside the ordered ladder", {})
  end
  assert(type(chosen) == "number", "slot reselection reads the selected index")
  local selected = slots[chosen]
  if type(selected) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. chosen .. " must be a record", {})
  end
  assert(type(selected) == "table", "slot reselection reads the selected slot")
  if type(selected.species) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. chosen .. " carries an invalid species", {})
  end
  if type(selected.maxLevel) ~= "number" or selected.maxLevel % 1 ~= 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. chosen .. " carries an invalid level", {})
  end
  local reseated = chosen
  local best = selected.maxLevel
  local species = selected.species
  for index, slot in ipairs(slots) do
    if type(slot) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. index .. " must be a record", {})
    end
    assert(type(slot) == "table", "slot reselection reads every slot")
    if slot.species == species then
      local maxLevel = slot.maxLevel
      if type(maxLevel) ~= "number" or maxLevel % 1 ~= 0 then
        Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. index .. " carries an invalid level", {})
      end
      assert(type(maxLevel) == "number", "slot reselection reads every maximum")
      if maxLevel > best then
        best = maxLevel
        reseated = index
      end
    end
  end
  return reseated
end

-- Resolves the ordered 1-based slot indices whose species carries the
-- target type, for the magnet-pull/static coercion. Either base type
-- matches, mirroring the native scan over both type slots. An empty or
-- total match yields nil: with no narrowing the attempt falls through to
-- the normal slot roll without a pick draw. Unreadable slots (inert
-- entries with no catalog record) read as no match instead of faulting,
-- matching the native scan; every other malformed slot fails. The
-- provider answers the lower-case type keys per species and form.
---@param slots table<string, unknown>[] ordered slots
---@param targetType string lower-case type key behind the coercion
---@param typeOf fun(species: string, form: integer): string[]?
---@return integer[]? ordered matching indices, or nil without a narrowing match
function EncounterSelection.matchingTypeSlots(slots, targetType, typeOf)
  if not Validate.isArray(slots) or #slots == 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slots must be a non-empty array", {})
  end
  assert(type(slots) == "table", "type coercion walks its ordered ladder")
  if type(targetType) ~= "string" or targetType == "" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter type coercion requires a known type", {
      targetType = targetType,
    })
  end
  if type(typeOf) ~= "function" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter type coercion requires a type provider", {})
  end
  local matches = {}
  for index, slot in ipairs(slots) do
    if type(slot) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. index .. " must be a record", {})
    end
    if type(slot.species) ~= "string" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. index .. " carries an invalid species", {})
    end
    local form = slot.form or 0
    if type(form) ~= "number" or form % 1 ~= 0 then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot " .. index .. " carries an invalid form", {})
    end
    local ok, types = pcall(typeOf, slot.species, form)
    if ok and type(types) == "table" and Validate.isArray(types) then
      assert(type(types) == "table", "the provider answers its type keys")
      for _, typeKey in ipairs(types) do
        if typeKey == targetType then
          matches[#matches + 1] = index
          break
        end
      end
    end
  end
  if #matches == 0 or #matches == #slots then
    return nil
  end
  return matches
end

-- Resolves the level inside one land slot: land tables carry a single
-- level per slot, so generation reads the slot maximum with no level
-- roll. Only the maximum is read, matching the native land branch; the
-- window relationship stays a compiled-schema concern.
---@param slot table<string, unknown>
---@return integer
function EncounterSelection.selectLandLevel(slot)
  if type(slot) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter level selection requires a slot record", {})
  end
  assert(type(slot) == "table", "land level selection reads the slot record")
  local maxLevel = slot.maxLevel
  if type(maxLevel) ~= "number" or maxLevel % 1 ~= 0 or maxLevel < 0 or maxLevel > 255 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter slot carries an invalid level window", {})
  end
  assert(type(maxLevel) == "number", "the slot maximum carries the land level")
  return maxLevel
end

---@param member table<string, unknown>
---@param field string
---@param method string
---@return table<string, unknown>
local function checkArrayField(member, field, method)
  local slots = member[field]
  if not Validate.isArray(slots) then
    Errors.raise("ENCOUNTER_MISSING_TABLE", "encounter method " .. method .. " has no provider slots", {
      method = method,
    })
  end
  assert(type(slots) == "table", "the resolved method carries its ordered slots")
  return slots
end

---@param member table<string, unknown>
---@param method string
---@param rateKey string
---@return integer
local function rateFor(member, method, rateKey)
  local rates = member.rates
  if type(rates) ~= "table" then
    Errors.raise("ENCOUNTER_MISSING_TABLE", "encounter method " .. method .. " has no provider rate", {
      method = method,
    })
  end
  assert(type(rates) == "table", "the member carries its method rates")
  local rate = rates[rateKey]
  if type(rate) ~= "number" or rate % 1 ~= 0 or rate < 0 or rate > EncounterSelection.MAX_RATE then
    Errors.raise("ENCOUNTER_MISSING_TABLE", "encounter method " .. method .. " has no provider rate", {
      method = method,
    })
  end
  assert(type(rate) == "number", "the provider rate carries its value")
  return checkRangedInteger(rate, 0, EncounterSelection.MAX_RATE, "encounter rate")
end

-- Resolves the ordered slots and the opportunity rate for one encounter
-- method. Grass selects the time-of-day land array, fishing selects the
-- requested rod array and rate. The returned slots are borrowed from the
-- member and must not be retained or mutated by the caller.
---@param member table<string, unknown>
---@param method string
---@param opts table<string, unknown>?
---@return { rate: integer, slots: table<string, unknown>[] }
function EncounterSelection.selectTable(member, method, opts)
  if type(member) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table selection requires a member record", {})
  end
  assert(type(member) == "table", "table selection reads the member record")
  if opts ~= nil and type(opts) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table options must be a record", { method = method })
  end
  local options = opts or {}
  if method == "grass" then
    local timeOfDay = options.timeOfDay
    if timeOfDay ~= "morning" and timeOfDay ~= "day" and timeOfDay ~= "night" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "grass encounters require a known time of day", {
        method = method,
        timeOfDay = timeOfDay,
      })
    end
    assert(timeOfDay == "morning" or timeOfDay == "day" or timeOfDay == "night", "grass reads its time array")
    local land = member.land
    if type(land) ~= "table" then
      Errors.raise("ENCOUNTER_MISSING_TABLE", "encounter method grass has no provider slots", { method = method })
    end
    assert(type(land) == "table", "the member carries its land arrays")
    return { rate = rateFor(member, method, "walking"), slots = checkArrayField(land, timeOfDay, method) }
  elseif method == "surf" then
    return { rate = rateFor(member, method, "surfing"), slots = checkArrayField(member, "surf", method) }
  elseif method == "fish" then
    local rod = options.rod
    local rodKey = type(rod) == "string" and ROD_KEYS[rod] or nil
    if rodKey == nil then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "fishing encounters require a known rod", {
        method = method,
        rod = options.rod,
      })
    end
    assert(type(rodKey) == "string", "fishing reads its rod array")
    return { rate = rateFor(member, method, rodKey), slots = checkArrayField(member, rodKey, method) }
  elseif method == "rock_smash" then
    return { rate = rateFor(member, method, "rockSmash"), slots = checkArrayField(member, "rockSmash", method) }
  elseif type(method) == "string" and METHODS_WITHOUT_TABLES[method] == true then
    Errors.raise("ENCOUNTER_MISSING_TABLE", "encounter method " .. method .. " has no provider slots", {
      method = method,
    })
  end
  Errors.raise("ENCOUNTER_INVALID_INPUT", "unknown encounter method " .. tostring(method), { method = method })
  error("unreachable encounter method", 0)
end

return EncounterSelection
