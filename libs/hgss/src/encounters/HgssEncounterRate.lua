-- The transcribed wild-opportunity movement stage behind step encounters
-- (the native EncounterRateRoll modified rate), plus the transcribed
-- table-rate stage (the native ability, flute, held-item, and
-- fishing-friendship adjustments applied after the empty-table refusal).
-- Movement order follows the native movement roll: the base forty paces every step, walking sheds twenty,
-- very tall grass adds forty (replacing the cycling thirty), the
-- reverse-turn step boost applies at its native thresholds, March and
-- Lullaby shift by twenty-five percentage points, and the result caps at
-- one hundred. The table rate enters the second roll
-- capped at one hundred; fishing, rock smash, and any other bypassing
-- path never take this stage, so this module carries no method gate. This
-- is the first of the two opportunity rolls the encounter service owns;
-- the comparison roll stays with the service. Consumes explicit immutable
-- attempt facts and returns a rate; no RNG, no retained state. Pure
-- domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")

---@class HgssEncounterRate
local HgssEncounterRate = {}

HgssEncounterRate.MAX_RATE = 100

HgssEncounterRate.BASE_RATE = 40
HgssEncounterRate.WALK_REDUCTION = 20
HgssEncounterRate.VERY_TALL_GRASS_BONUS = 40
HgssEncounterRate.CYCLING_BONUS = 30

local LOCOMOTION = {
  walk = true,
  run = true,
  cycle = true,
  surf = true,
}

local MUSIC_RATES = {
  none = 0,
  march = 25,
  lullaby = -25,
}

-- Every lead ability that shifts an encounter: the closed vocabulary the
-- attempt modifiers and the adapter mapping share. Only the rate subset
-- below moves the table rate; slot, level, deterrence, nature, gender,
-- and held-odd effects read the same keys at their own stages.
HgssEncounterRate.LEAD_ABILITIES = {
  synchronize = true,
  intimidate = true,
  keen_eye = true,
  arena_trap = true,
  no_guard = true,
  illuminate = true,
  snow_cloak = true,
  white_smoke = true,
  quick_feet = true,
  stench = true,
  sticky_hold = true,
  suction_cups = true,
  hustle = true,
  vital_spirit = true,
  pressure = true,
  magnet_pull = true,
  static = true,
  cute_charm = true,
  compoundeyes = true,
}

-- The rate subset: abilities that double or halve the table rate.
local RATE_ABILITIES = {
  arena_trap = true,
  no_guard = true,
  illuminate = true,
  snow_cloak = true,
  white_smoke = true,
  quick_feet = true,
  stench = true,
  sticky_hold = true,
  suction_cups = true,
}

-- The fishing bite tiers behind an active follower, by first-alive
-- friendship: nothing below one hundred, then twenty, thirty, forty,
-- and fifty points.
---@param friendship integer
---@return integer the native bite bonus
local function friendshipBoost(friendship)
  assert(
    type(friendship) == "number" and friendship % 1 == 0 and friendship >= 0,
    "the bite bonus reads whole friendship"
  )
  if friendship <= 99 then
    return 0
  end
  if friendship <= 149 then
    return 20
  end
  if friendship <= 199 then
    return 30
  end
  if friendship <= 249 then
    return 40
  end
  return 50
end

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

-- Stages one movement rate from explicit immutable facts. The facts
-- record stays untouched; only the returned rate carries the result.
---@param facts { locomotion: string, veryTallGrass: boolean, radio: string, reverseTurnSteps?: integer }
---@return integer the staged movement rate in 0..100
function HgssEncounterRate.movementRate(facts)
  if type(facts) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter movement staging requires a facts record", {})
  end
  assert(type(facts) == "table", "movement staging reads its attempt facts")
  local locomotion = facts.locomotion
  if LOCOMOTION[locomotion] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter movement staging requires a known locomotion", {
      locomotion = locomotion,
    })
  end
  assert(
    locomotion == "walk" or locomotion == "run" or locomotion == "cycle" or locomotion == "surf",
    "movement staging reads its locomotion"
  )
  local veryTallGrass = facts.veryTallGrass
  if type(veryTallGrass) ~= "boolean" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter movement staging requires a very-tall-grass fact", {
      veryTallGrass = veryTallGrass,
    })
  end
  assert(type(veryTallGrass) == "boolean", "movement staging reads its very-tall-grass fact")
  local radio = facts.radio
  if MUSIC_RATES[radio] == nil then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter movement staging requires a known music effect", {
      radio = radio,
    })
  end
  assert(type(radio) == "string", "movement staging reads its music effect")
  -- The attempt pipeline carries no reverse-turn counter yet; the
  -- transcribed thresholds engage only when a producer supplies one.
  local reverseTurnSteps = facts.reverseTurnSteps or 0
  if type(reverseTurnSteps) ~= "number" or reverseTurnSteps % 1 ~= 0 or reverseTurnSteps < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter movement staging requires whole reverse-turn steps", {
      reverseTurnSteps = facts.reverseTurnSteps,
    })
  end
  local staged = HgssEncounterRate.BASE_RATE
  if locomotion == "walk" then
    staged = staged - HgssEncounterRate.WALK_REDUCTION
  end
  if veryTallGrass then
    staged = staged + HgssEncounterRate.VERY_TALL_GRASS_BONUS
  elseif locomotion == "cycle" then
    staged = staged + HgssEncounterRate.CYCLING_BONUS
  end
  staged = staged + stepBoost(reverseTurnSteps) + assert(MUSIC_RATES[radio], "the music effect carries its shift")
  -- NOTE (retail fidelity): the native stage runs in unsigned 8-bit
  -- arithmetic, transcribed here exactly. Underflow wraps instead of
  -- flooring, so walking under Lullaby (twenty minus twenty-five) stages
  -- 251 and lands on the cap below, passing the movement roll
  -- unconditionally; the table roll still gates the encounter, so Lullaby
  -- on foot paces the raw table rate. The wrap only ever bites the
  -- walking base: every other term stays in range, and the positive side
  -- never overflows (at most forty plus forty plus sixty plus twenty-five).
  staged = staged % 256
  if staged > HgssEncounterRate.MAX_RATE then
    staged = HgssEncounterRate.MAX_RATE
  end
  return staged
end

-- Stages one table rate from explicit immutable facts, in native order:
-- the fishing-friendship bite bonus behind an active follower, then the
-- lead-ability doubling or halving with its clamp, then the flute shift,
-- then the held-item two-thirds. An empty base rate refuses before the
-- friendship bonus, matching the native early return; only snow names a
-- weather effect. The lead ability arrives validated by the caller (egg
-- leads arrive with none); validated non-rate abilities stage nothing.
-- The result may exceed one hundred on the egg-plus-flute corner the
-- native clamp skips; the roll site caps it back. The facts record stays
-- untouched; no RNG, no retained state.
---@param facts { baseRate: integer, isFishing: boolean, leadAbility?: string, weather?: string, flute?: string, heldItem?: string, friendship?: integer, followActive?: boolean }
---@return integer the staged table rate
function HgssEncounterRate.tableRate(facts)
  if type(facts) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging requires a facts record", {})
  end
  assert(type(facts) == "table", "table staging reads its attempt facts")
  local baseRate = facts.baseRate
  if type(baseRate) ~= "number" or baseRate % 1 ~= 0 or baseRate < 0 or baseRate > 255 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging requires a base rate in 0..255", {
      baseRate = baseRate,
    })
  end
  assert(type(baseRate) == "number", "table staging reads its base rate")
  local isFishing = facts.isFishing
  if type(isFishing) ~= "boolean" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging requires a fishing fact", {
      isFishing = isFishing,
    })
  end
  assert(type(isFishing) == "boolean", "table staging reads its fishing fact")
  local leadAbility = facts.leadAbility
  if leadAbility ~= nil and HgssEncounterRate.LEAD_ABILITIES[leadAbility] ~= true then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging names an unknown lead ability", {
      leadAbility = leadAbility,
    })
  end
  local weather = facts.weather or "none"
  if weather ~= "none" and weather ~= "snow" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging names an unknown weather", {
      weather = weather,
    })
  end
  assert(type(weather) == "string", "table staging reads its weather")
  local flute = facts.flute
  if flute ~= nil and flute ~= "black" and flute ~= "white" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging names an unknown flute", {
      flute = flute,
    })
  end
  local heldItem = facts.heldItem
  if heldItem ~= nil and type(heldItem) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging requires a held-item key", {
      heldItem = heldItem,
    })
  end
  local followActive = facts.followActive or false
  if type(followActive) ~= "boolean" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging requires a follower fact", {
      followActive = facts.followActive,
    })
  end
  assert(type(followActive) == "boolean", "table staging reads its follower fact")
  local friendship = facts.friendship or 0
  if type(friendship) ~= "number" or friendship % 1 ~= 0 or friendship < 0 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter table staging requires whole friendship", {
      friendship = facts.friendship,
    })
  end
  assert(type(friendship) == "number", "table staging reads its friendship")
  -- An empty bite rate refuses before any bonus, matching the native
  -- early return.
  if baseRate == 0 then
    return 0
  end
  local staged = baseRate
  if isFishing and followActive then
    -- NOTE (retail fidelity): the native bonus accumulates in an unsigned
    -- byte and wraps; only synthetic rates above two hundred can bite.
    staged = (staged + friendshipBoost(friendship)) % 256
  end
  if leadAbility ~= nil and RATE_ABILITIES[leadAbility] == true then
    if isFishing then
      if leadAbility == "sticky_hold" or leadAbility == "suction_cups" then
        staged = staged * 2
      end
    elseif leadAbility == "arena_trap" or leadAbility == "no_guard" or leadAbility == "illuminate" then
      staged = staged * 2
    elseif leadAbility == "snow_cloak" then
      if weather == "snow" then
        staged = math.floor(staged / 2)
      end
    elseif leadAbility == "white_smoke" or leadAbility == "quick_feet" or leadAbility == "stench" then
      staged = math.floor(staged / 2)
    end
    if staged > HgssEncounterRate.MAX_RATE then
      staged = HgssEncounterRate.MAX_RATE
    end
  end
  if flute == "black" then
    staged = math.floor(staged / 2)
  elseif flute == "white" then
    -- NOTE (retail fidelity): the native white shift runs in an unsigned
    -- byte past the ability clamp; only the egg-plus-flute corner with a
    -- synthetic base above one hundred can wrap, and the roll site caps
    -- the result back to one hundred either way.
    staged = (staged + math.floor(staged / 2)) % 256
  end
  if heldItem == "CLEANSE_TAG" or heldItem == "PURE_INCENSE" then
    staged = math.floor(staged * 2 / 3)
  end
  return staged
end

return HgssEncounterRate
