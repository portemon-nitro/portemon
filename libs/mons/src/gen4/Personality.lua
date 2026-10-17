-- Personality derivations. Canonical sources: pret/pokeheartgold,
-- src/pokemon.c (GetNatureFromPersonality, gender and ability selection).
-- Nature is personality mod 25. Gender compares the low personality byte
-- against the species ratio, with fixed-gender and genderless ratios
-- short-circuiting. Shininess XORs the trainer and personality halves with
-- the source threshold below 8. The ability slot follows personality parity
-- for two-ability definitions; single-ability definitions always use slot 1.

local Stats = require("libs.mons.src.gen4.Stats")
local U32 = require("libs.codec.src.U32")

---@class Personality
local Personality = {}

local NATURE_COUNT = Stats.MAX_NATURE + 1
local SHINY_XOR_THRESHOLD = 8
local GENDER_RATIO_MALE = 0 -- always male
local GENDER_RATIO_FEMALE = 254 -- always female
local GENDER_RATIO_GENDERLESS = 255
local BYTE_RANGE = 256

---@param personality integer
---@return integer
function Personality.nature(personality)
  assert(
    type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= U32.MAX,
    "personality must be an unsigned 32-bit integer"
  )
  return personality % NATURE_COUNT
end

---@param ratio integer
---@param personality integer
---@return string
function Personality.gender(ratio, personality)
  assert(type(ratio) == "number" and ratio % 1 == 0 and ratio >= 0 and ratio <= 255, "gender ratio must be a u8")
  assert(
    type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= U32.MAX,
    "personality must be an unsigned 32-bit integer"
  )
  if ratio == GENDER_RATIO_GENDERLESS then
    return "genderless"
  end
  if ratio == GENDER_RATIO_MALE then
    return "male"
  end
  if ratio == GENDER_RATIO_FEMALE then
    return "female"
  end
  if (personality % BYTE_RANGE) < ratio then
    return "female"
  end
  return "male"
end

---@param a integer
---@param b integer
---@return integer
local function xor16(a, b)
  local value = 0
  local place = 1
  for _ = 1, 16 do
    local abit = math.floor(a / place) % 2
    local bbit = math.floor(b / place) % 2
    if abit ~= bbit then
      value = value + place
    end
    place = place * 2
  end
  return value
end
---@param trainerId integer
---@param personality integer
---@return boolean
function Personality.shiny(trainerId, personality)
  assert(
    type(trainerId) == "number" and trainerId % 1 == 0 and trainerId >= 0 and trainerId <= U32.MAX,
    "trainer id must be an unsigned 32-bit integer"
  )
  assert(
    type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= U32.MAX,
    "personality must be an unsigned 32-bit integer"
  )
  local a = math.floor(trainerId / U32.HALF_BASE) % U32.HALF_BASE
  local b = trainerId % U32.HALF_BASE
  local c = math.floor(personality / U32.HALF_BASE) % U32.HALF_BASE
  local d = personality % U32.HALF_BASE
  return xor16(xor16(a, b), xor16(c, d)) < SHINY_XOR_THRESHOLD
end

-- Forced personality convolution for event distributions.
-- pret/pokeheartgold src/pokemon.c
-- ChangePersonalityToNatureGenderAndAbility in its non-generator branch
-- (the Spiky-Ear Pichu and Pokewalker path): the input doubles as the
-- trainer ID, the high word is folded arithmetically (no generator
-- draws), the low word is nudged to the requested nature, and the low
-- byte is nudged to the requested gender while keeping nature and
-- ability parity. Fixed ratios (0/254/255) skip the gender nudge but
-- still force the nature. All arithmetic wraps mod 2^32 like the source
-- u32 operations.
---@param trainerId integer unsigned 32-bit trainer ID doubling as the seed
---@param ratio integer u8 species gender ratio
---@param nature integer 0..24 requested nature
---@param gender string "male"|"female" requested gender
---@param ability integer 0|1 requested ability slot parity
---@return integer personality
function Personality.forcedNatureGenderAbility(trainerId, ratio, nature, gender, ability)
  assert(
    type(trainerId) == "number" and trainerId % 1 == 0 and trainerId >= 0 and trainerId <= U32.MAX,
    "trainer id must be an unsigned 32-bit integer"
  )
  assert(type(ratio) == "number" and ratio % 1 == 0 and ratio >= 0 and ratio <= 255, "gender ratio must be a u8")
  assert(
    type(nature) == "number" and nature % 1 == 0 and nature >= 0 and nature <= Stats.MAX_NATURE,
    "nature must be an integer in 0.." .. Stats.MAX_NATURE
  )
  assert(gender == "male" or gender == "female", "forced gender must be male or female")
  assert(ability == 0 or ability == 1, "forced ability parity must be 0 or 1")
  assert(nature % 2 == ability, "forced nature and ability parities must agree")
  local trainerIdXor = xor16(math.floor(trainerId / U32.HALF_BASE) % U32.HALF_BASE, trainerId % U32.HALF_BASE)
  local pid = xor16(0xFF00, math.floor(trainerIdXor / 256) % 256 * 256) * U32.HALF_BASE
  pid = (pid + nature - (pid % NATURE_COUNT)) % U32.MOD
  if ratio ~= GENDER_RATIO_MALE and ratio ~= GENDER_RATIO_FEMALE and ratio ~= GENDER_RATIO_GENDERLESS then
    if gender == "male" then
      local low = pid % BYTE_RANGE
      if ratio > low then
        pid = (pid + NATURE_COUNT * (math.floor((ratio - low) / NATURE_COUNT) + 1)) % U32.MOD
        if pid % 2 ~= ability then
          pid = (pid + NATURE_COUNT) % U32.MOD
        end
      end
    else
      local low = pid % BYTE_RANGE
      if ratio < low then
        pid = (pid - NATURE_COUNT * (math.floor((low - ratio) / NATURE_COUNT) + 1)) % U32.MOD
        if pid % 2 ~= ability then
          pid = (pid - NATURE_COUNT) % U32.MOD
        end
      end
    end
  end
  return pid
end

---@param abilityCount integer
---@param personality integer
---@return integer
function Personality.abilitySlot(abilityCount, personality)
  assert(abilityCount == 1 or abilityCount == 2, "ability count must be 1 or 2")
  assert(
    type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= U32.MAX,
    "personality must be an unsigned 32-bit integer"
  )
  if abilityCount == 1 then
    return 1
  end
  return (personality % 2) + 1
end

return Personality
