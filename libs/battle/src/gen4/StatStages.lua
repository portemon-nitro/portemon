-- Source stage clamps and ratios. Battle stat stages are signed semantic
-- deltas in [-6, 6]: the attack family (attack, defense, speed, special
-- attack, special defense) scales on halves of the materialized battle
-- stat, while accuracy and evasion resolve through a literal 13-entry
-- hit-chance lookup. Ratios stay exact integer pairs and apply with a
-- truncating floor, so halved odd stats round down exactly as the native
-- division does.

---@class StatStages
---@field attack integer
---@field defense integer
---@field speed integer
---@field specialAttack integer
---@field specialDefense integer
---@field accuracy integer
---@field evasion integer
---@field private _sealed boolean?
local StatStages = {}

StatStages.MIN = -6
StatStages.MAX = 6

--- Literal hit-chance factor per clamped signed stage. The paired values
--- are the exact source table entries, so callers must never re-derive
--- them from stage thirds.
local ACCURACY_RATIOS = {
  [-6] = { numerator = 33, denominator = 100 },
  [-5] = { numerator = 36, denominator = 100 },
  [-4] = { numerator = 43, denominator = 100 },
  [-3] = { numerator = 50, denominator = 100 },
  [-2] = { numerator = 60, denominator = 100 },
  [-1] = { numerator = 75, denominator = 100 },
  [0] = { numerator = 1, denominator = 1 },
  [1] = { numerator = 133, denominator = 100 },
  [2] = { numerator = 166, denominator = 100 },
  [3] = { numerator = 2, denominator = 1 },
  [4] = { numerator = 233, denominator = 100 },
  [5] = { numerator = 133, denominator = 50 },
  [6] = { numerator = 3, denominator = 1 },
}

---@class StatStageRatio
---@field numerator integer
---@field denominator integer

---@param stage integer signed stage delta under test
---@param name string stage value being read
local function requireStage(stage, name)
  assert(type(stage) == "number" and stage % 1 == 0, name .. " must be an integer stage")
end

---@param current integer signed stage before the delta
---@param delta integer signed stage movement to apply
---@return integer clamped stage inside the native bounds
function StatStages.change(current, delta)
  requireStage(current, "current stage")
  requireStage(delta, "stage delta")
  local moved = current + delta
  if moved > StatStages.MAX then
    return StatStages.MAX
  end
  if moved < StatStages.MIN then
    return StatStages.MIN
  end
  return moved
end

---@param stage integer signed stage delta to express
---@param key string stat the ratio applies to
---@return StatStageRatio exact native ratio for the stage
function StatStages.multiplier(stage, key)
  requireStage(stage, "stage")
  assert(type(key) == "string", "stage ratios name their stat")
  if key == "accuracy" or key == "evasion" then
    local clamped = stage
    if clamped > StatStages.MAX then
      clamped = StatStages.MAX
    elseif clamped < StatStages.MIN then
      clamped = StatStages.MIN
    end
    local ratio = ACCURACY_RATIOS[clamped]
    return { numerator = ratio.numerator, denominator = ratio.denominator }
  end
  assert(
    key == "attack" or key == "defense" or key == "speed" or key == "specialAttack" or key == "specialDefense",
    "unknown stat stage key " .. key
  )
  if stage >= 0 then
    return { numerator = 2 + stage, denominator = 2 }
  end
  return { numerator = 2, denominator = 2 - stage }
end

---@param stat integer materialized battle stat before stages
---@param stage integer signed stage delta to apply
---@param key string stat the stage applies to
---@return integer staged stat truncated exactly once
function StatStages.effective(stat, stage, key)
  assert(type(stat) == "number" and stat % 1 == 0 and stat >= 0, "staged stats apply to a non-negative integer stat")
  local ratio = StatStages.multiplier(stage, key)
  return math.floor((stat * ratio.numerator) / ratio.denominator)
end

return StatStages
