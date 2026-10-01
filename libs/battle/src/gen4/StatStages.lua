-- Source stage clamps and ratios. Battle stat stages are signed semantic
-- deltas in [-6, 6]: the attack family (attack, defense, speed, special
-- attack, special defense) scales on halves of the materialized battle
-- stat, while accuracy and evasion scale on thirds. Ratios stay exact
-- integer pairs and apply with a truncating floor, so halved odd stats
-- round down exactly as the native division does.

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
    if stage >= 0 then
      return { numerator = 3 + stage, denominator = 3 }
    end
    return { numerator = 3, denominator = 3 - stage }
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
