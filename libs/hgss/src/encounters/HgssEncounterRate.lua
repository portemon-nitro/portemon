-- The transcribed wild-opportunity rate stage behind the radio music
-- effects. Order follows the native encounter-rate roll: the table rate
-- enters capped at one hundred, the reverse-turn step boost applies at its
-- native thresholds, March and Lullaby shift land-or-surf rates by
-- twenty-five percentage points at their native position, and the result
-- clamps to zero through one hundred. Fishing, rock smash, and any other
-- bypassing path take neither the boost nor the music. This is the
-- single-roll opportunity the encounter service owns: the movement terms
-- of the native first-roll machinery stay out (vectors pin silence equal
-- to the table rate), and the comparison roll stays with the service.
-- Consumes explicit immutable attempt facts and returns a rate; no RNG,
-- no retained state. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")

---@class HgssEncounterRate
local HgssEncounterRate = {}

HgssEncounterRate.MAX_RATE = 100

local MUSIC_RATES = {
  none = 0,
  march = 25,
  lullaby = -25,
}

local MUSIC_METHODS = {
  grass = true,
  surf = true,
}

local TABLE_METHODS = {
  grass = true,
  surf = true,
  fish = true,
  rock_smash = true,
}

---@param steps unknown
---@return integer the transcribed reverse-turn boost
local function stepBoost(steps)
  assert(type(steps) == "number" and steps % 1 == 0 and steps >= 0, "the step boost reads whole reverse-turn steps")
  if steps >= 4 then
    return 60
  elseif steps >= 3 then
    return 40
  elseif steps >= 2 then
    return 30
  end
  return 0
end

-- Stages one opportunity rate from explicit immutable facts. The facts
-- record stays untouched; only the returned rate carries the result.
---@param facts { baseRate: integer, radio: string, method: string, reverseTurnSteps?: integer }
---@return integer the staged opportunity rate in 0..100
function HgssEncounterRate.compute(facts)
  if type(facts) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter rate staging requires a facts record", {})
  end
  assert(type(facts) == "table", "rate staging reads its attempt facts")
  local baseRate = facts.baseRate
  if type(baseRate) ~= "number" or baseRate % 1 ~= 0 or baseRate < 0 or baseRate > 255 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter rate staging requires a base rate in 0..255", {
      baseRate = baseRate,
    })
  end
  assert(type(baseRate) == "number", "rate staging reads its base rate")
  local radio = facts.radio
  if MUSIC_RATES[radio] == nil then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter rate staging requires a known music effect", {
      radio = radio,
    })
  end
  assert(type(radio) == "string", "rate staging reads its music effect")
  local method = facts.method
  if TABLE_METHODS[method] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter rate staging requires a known table method", {
      method = method,
    })
  end
  assert(type(method) == "string", "rate staging reads its encounter method")
  -- The attempt pipeline carries no reverse-turn counter yet; the
  -- transcribed thresholds engage only when a producer supplies one.
  local reverseTurnSteps = facts.reverseTurnSteps or 0
  if type(reverseTurnSteps) ~= "number" or reverseTurnSteps % 1 ~= 0 or reverseTurnSteps < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter rate staging requires whole reverse-turn steps", {
      reverseTurnSteps = facts.reverseTurnSteps,
    })
  end
  local staged = math.min(baseRate, HgssEncounterRate.MAX_RATE)
  if MUSIC_METHODS[method] == true then
    staged = staged + stepBoost(reverseTurnSteps) + assert(MUSIC_RATES[radio], "the music effect carries its shift")
  end
  if staged < 0 then
    staged = 0
  elseif staged > HgssEncounterRate.MAX_RATE then
    staged = HgssEncounterRate.MAX_RATE
  end
  return staged
end

return HgssEncounterRate
