-- Knockout experience eligibility and award stages. Native anchor:
-- pret/pokeheartgold src/battle/battle_command.c BtlCmd_CalcExpGain (base
-- yield times fainted level over seven, halved shares with minimum-one
-- floors) and Task_GetExp (per-recipient order: share addition, Lucky Egg
-- three halves, trainer three halves, traded seventeen tenths for a
-- foreign original or three halves for a same-language trade; the whole
-- per-recipient block runs only for conscious non-egg mons below level
-- 100). Recipient selection and award staging stay pure: no party is read
-- or mutated, and capture-time awards have no surface here.

---@class Experience
local Experience = {}

local MAX_LEVEL = 100

---@param value unknown
---@return boolean
local function isNonNegativeInt(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

---@param battler table<string, unknown>
local function checkBattler(battler)
  assert(type(battler) == "table", "recipient selection reads battler records")
  assert(
    type(battler.combatant) == "number" and battler.combatant % 1 == 0 and battler.combatant >= 1,
    "recipient selection names the combatant identity"
  )
end

---@param knockout table<string, unknown>
local function checkKnockout(knockout)
  assert(type(knockout) == "table", "experience awards read the knockout facts")
  assert(
    type(knockout.baseYield) == "number" and knockout.baseYield % 1 == 0 and knockout.baseYield >= 0,
    "experience awards read a non-negative integer base yield"
  )
  assert(
    type(knockout.level) == "number" and knockout.level % 1 == 0 and knockout.level >= 1,
    "experience awards read the fainted positive integer level"
  )
end

---@param battler table<string, unknown>
---@return boolean
local function isConscious(battler)
  return battler.fainted ~= true
end

---@param battler table<string, unknown>
---@return boolean
local function isEligible(battler)
  if not isConscious(battler) then
    return false
  end
  if battler.isEgg == true then
    return false
  end
  if type(battler.level) == "number" and battler.level >= MAX_LEVEL then
    return false
  end
  return battler.participated == true or battler.expShare == true
end

--- Names exactly the conscious non-egg participants and share holders
--- below the level cap, in selection order. Fainted battlers, eggs,
--- level-capped mons, and idle battlers without a share earn nothing.
--- Participation and shareholding are independent facts: a participating
--- holder carries both flags and later earns both portions.
---@param query table<string, unknown>
---@return { combatant: integer, participated: boolean, share: boolean }[]
function Experience.recipients(query)
  assert(type(query) == "table", "recipient selection reads a query record")
  assert(type(query.battlers) == "table", "recipient selection reads the battler array")
  local selected = {}
  for _, battler in ipairs(query.battlers) do
    checkBattler(battler)
    if isEligible(battler) then
      selected[#selected + 1] = {
        combatant = battler.combatant,
        participated = battler.participated == true,
        share = battler.expShare == true,
      }
    end
  end
  return selected
end

---@param recipient table<string, unknown>
---@param what string
local function checkShareCount(recipient, what)
  assert(
    type(recipient[what]) == "number" and recipient[what] % 1 == 0 and recipient[what] >= 0,
    "experience awards read non-negative integer " .. what .. " counts"
  )
end

--- Stages one recipient award in native order: the base stage floors
--- yield times fainted level over seven, then each earned portion splits
--- the staged total with its own minimum-one floor. Holders halve the
--- staged total first: the participant portion divides that half across
--- the participants and the share portion across the holders, so one
--- recipient earning both keeps their sum. Without holders the
--- participant portion divides the whole staged total. Each per-recipient
--- multiplier floors in turn (Lucky Egg, trainer, traded). A foreign
--- original takes seventeen tenths instead of the same-language three
--- halves; the two trade bonuses never stack.
---@param knockout table<string, unknown>
---@param recipient table<string, unknown>
---@return integer
function Experience.calculate(knockout, recipient)
  checkKnockout(knockout)
  assert(type(recipient) == "table", "experience awards read the recipient record")
  assert(type(recipient.participated) == "boolean", "experience awards read the participation fact")
  assert(type(recipient.share) == "boolean", "experience awards read the share fact")
  checkShareCount(recipient, "battlers")
  checkShareCount(recipient, "holders")
  local staged = math.floor((knockout.baseYield * knockout.level) / 7)
  local award = 0
  if recipient.participated == true then
    assert(recipient.battlers >= 1, "a participant portion splits across at least one battler")
    local portion
    if recipient.holders > 0 then
      portion = math.floor(math.floor(staged / 2) / recipient.battlers)
    else
      portion = math.floor(staged / recipient.battlers)
    end
    if portion == 0 then
      portion = 1
    end
    award = award + portion
  end
  if recipient.share == true then
    assert(recipient.holders >= 1, "a share portion splits across at least one holder")
    local portion = math.floor(math.floor(staged / 2) / recipient.holders)
    if portion == 0 then
      portion = 1
    end
    award = award + portion
  end
  if recipient.luckyEgg == true then
    award = math.floor((award * 150) / 100)
  end
  if knockout.trainerBattle == true then
    award = math.floor((award * 150) / 100)
  end
  if recipient.traded == true or recipient.foreign == true then
    if recipient.foreign == true then
      award = math.floor((award * 170) / 100)
    else
      award = math.floor((award * 150) / 100)
    end
  end
  assert(isNonNegativeInt(award), "experience awards stay non-negative integers")
  return award
end

return Experience
