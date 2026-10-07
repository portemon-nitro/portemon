-- Knockout effort eligibility and award order. Native anchor:
-- pret/pokeheartgold src/battle/battle_command.c
-- BattleScript_CalcEffortValues (held power-item bonus first, Pokerus
-- doubling, Macho Brace doubling, then the 510-total trim before the
-- 255-per-stat trim) called from Task_GetExp only for conscious non-egg
-- mons below level 100, so level-capped battlers bank nothing here. Award
-- calculation stays pure modifier arithmetic; application owns the native
-- caps and eligibility gates without mutating its inputs.

---@class Effort
local Effort = {}

local STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }
local POWER_BONUS = 4
local MAX_LEVEL = 100
local MAX_PER_STAT = 255
local MAX_TOTAL = 510

---@param value unknown
---@return boolean
local function isNonNegativeInt(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

---@param record unknown
---@param what string
local function checkYield(record, what)
  assert(type(record) == "table", what .. " carries a six-stat record")
  for _, key in ipairs(STAT_KEYS) do
    assert(isNonNegativeInt(record[key]), what .. " carries a non-negative integer " .. key)
  end
end

---@param subject table<string, unknown>
---@return boolean
local function isEligible(subject)
  if subject.fainted == true then
    return false
  end
  if subject.isEgg == true then
    return false
  end
  return type(subject.level) ~= "number" or subject.level < MAX_LEVEL
end

--- Stages one knockout yield in source modifier order: the held power
--- item adds its bonus to its stat first, then Pokerus doubles every
--- stat, then the Macho Brace doubles again. No caps apply here.
---@param yield table<string, integer>
---@param modifiers table<string, unknown>
---@return table<string, integer>
function Effort.calculate(yield, modifiers)
  checkYield(yield, "effort calculation reads the knockout")
  assert(type(modifiers) == "table", "effort calculation reads the modifier record")
  local staged = {}
  for _, key in ipairs(STAT_KEYS) do
    local gained = yield[key]
    if modifiers.powerStat == key then
      gained = gained + POWER_BONUS
    end
    if modifiers.pokerus == true then
      gained = gained * 2
    end
    if modifiers.machoBrace == true then
      gained = gained * 2
    end
    staged[key] = gained
  end
  return staged
end

--- Banks a staged award under the native caps: stats accumulate in
--- source order while the running total stays below 510, trimming first
--- to the total and then to 255 per stat. Fainted battlers, eggs, and
--- level-capped battlers keep their prior values untouched. The incoming
--- record is never mutated.
---@param current table<string, integer>
---@param award table<string, integer>
---@param subject table<string, unknown>
---@return table<string, integer>
function Effort.apply(current, award, subject)
  checkYield(current, "effort application reads current values")
  checkYield(award, "effort application reads the staged")
  assert(type(subject) == "table", "effort application reads the award subject")
  local banked = {}
  for _, key in ipairs(STAT_KEYS) do
    banked[key] = current[key]
  end
  if not isEligible(subject) then
    return banked
  end
  local total = 0
  for _, key in ipairs(STAT_KEYS) do
    total = total + banked[key]
  end
  for _, key in ipairs(STAT_KEYS) do
    if total >= MAX_TOTAL then
      break
    end
    local gained = award[key]
    if total + gained > MAX_TOTAL then
      gained = gained - (total + gained - MAX_TOTAL)
    end
    if banked[key] + gained > MAX_PER_STAT then
      gained = gained - (banked[key] + gained - MAX_PER_STAT)
    end
    banked[key] = banked[key] + gained
    total = total + gained
  end
  return banked
end

-- Held items behind knockout effort: each power training item names
-- its bonus stat while Macho Brace names its doubling. Source
-- reference: BattleScript_CalcEffortValues in
-- src/battle/battle_command.c, where the power bonus stages before the
-- Pokerus and brace doublings the calculate owner already orders.
local POWER_STAT = {
  POWER_BRACER = "attack",
  POWER_BELT = "defense",
  POWER_LENS = "specialAttack",
  POWER_BAND = "specialDefense",
  POWER_ANKLET = "speed",
  POWER_WEIGHT = "hp",
}

--- Maps a held item key to its effort modifiers: power training items
--- carry their bonus stat, Macho Brace carries its doubling, and
--- anything else -- empty hands included -- carries no modifier. The
--- explicit mark doubles every staged stat; only an explicit true flag
--- sets it, so absent or loosely truthy shapes never double.
---@param heldItem unknown held item key under the mapping
---@param hasPokerus boolean|nil explicit doubling mark for the award staging
---@return table<string, unknown> effort modifiers for the award staging
function Effort.modifiersFor(heldItem, hasPokerus)
  local pokerus = hasPokerus == true
  if
    type(heldItem) == "string" and POWER_STAT[
      heldItem --[[@as string]]
    ] ~= nil
  then
    return {
      powerStat = POWER_STAT[
        heldItem --[[@as string]]
      ],
      pokerus = pokerus,
      machoBrace = false,
    }
  end
  if heldItem == "MACHO_BRACE" then
    return { powerStat = nil, pokerus = pokerus, machoBrace = true }
  end
  return { powerStat = nil, pokerus = pokerus, machoBrace = false }
end

return Effort
