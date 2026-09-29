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
  if ratio == 255 then
    return "genderless"
  end
  if ratio == 0 then
    return "male"
  end
  if ratio == 254 then
    return "female"
  end
  if (personality % 256) < ratio then
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
