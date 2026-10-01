-- Semantic chart, STAB, and immunity resolver. Directed effectiveness
-- pairs come from the composed session chart with their exact integer
-- rationals: chart immunities resolve to zero, dual types multiply their
-- exact pairs, and unknown attacking types or undeclared pairs fail before
-- execution instead of falling back to neutral. Ability immunity, chart
-- immunity, and grounding are separate checkpoints with distinct reasons:
-- ability immunity suppresses the resolved multiplier without rewriting
-- it, and airborne grounding only immunizes ground attacks. Mystery and
-- typeless attacks, and defenders that lost their type, stay neutral.

---@class EffectivenessContext
---@field abilityImmunity boolean?
---@field airborne boolean?
---@field typeless boolean?

---@class EffectivenessResult
---@field numerator integer
---@field denominator integer
---@field immune boolean
---@field reason string
local TypeEffectiveness = {}

---@param value integer value under test
---@param other integer other value under test
---@return integer greatest common divisor for canonical ratios
local function gcd(value, other)
  local remaining = value
  local divisor = other
  while divisor ~= 0 do
    local next = remaining % divisor
    remaining = divisor
    divisor = next
  end
  if remaining < 0 then
    return -remaining
  end
  return remaining
end

---@param numerator integer combined numerator under test
---@param denominator integer combined denominator under test
---@return integer
---@return integer canonical reduced pair
local function reduce(numerator, denominator)
  local divisor = gcd(numerator, denominator)
  assert(divisor >= 1, "effectiveness ratios reduce over a positive divisor")
  return math.floor(numerator / divisor), math.floor(denominator / divisor)
end

---@param chart TypeChart session-scoped chart view under test
---@param attack string attacking type under test
---@param defendList string[] defending types in declared order
---@param context EffectivenessContext immunity checkpoints under test
---@return EffectivenessResult resolved multiplier with its immunity reason
function TypeEffectiveness.resolve(chart, attack, defendList, context)
  assert(type(chart) == "table" and type(chart.effectiveness) == "function", "effectiveness resolves through its chart")
  assert(type(attack) == "string" and attack ~= "", "effectiveness names its attacking type")
  assert(type(defendList) == "table", "effectiveness reads its defending types")
  local seen = context or {}
  assert(type(seen) == "table", "effectiveness reads its immunity checkpoints")

  if #defendList == 0 then
    return { numerator = 1, denominator = 1, immune = false, reason = "lost_type" }
  end
  if attack == "mystery" or attack == "typeless" or seen.typeless == true then
    return { numerator = 1, denominator = 1, immune = false, reason = "neutral_special" }
  end

  local numerator = 1
  local denominator = 1
  for _, defend in ipairs(defendList) do
    assert(type(defend) == "string" and defend ~= "", "effectiveness names each defending type")
    local pair = chart:effectiveness(attack, defend)
    assert(
      type(pair.numerator) == "number" and type(pair.denominator) == "number",
      "chart pairs carry their exact rational"
    )
    if pair.numerator == 0 then
      return { numerator = 0, denominator = 1, immune = true, reason = "chart_immunity" }
    end
    numerator = numerator * pair.numerator
    denominator = denominator * pair.denominator
  end
  local reducedNumerator, reducedDenominator = reduce(numerator, denominator)
  if seen.abilityImmunity == true then
    return { numerator = reducedNumerator, denominator = reducedDenominator, immune = true, reason = "ability_immunity" }
  end
  if seen.airborne == true and attack == "ground" then
    return { numerator = reducedNumerator, denominator = reducedDenominator, immune = true, reason = "grounding" }
  end
  return { numerator = reducedNumerator, denominator = reducedDenominator, immune = false, reason = "effective" }
end

---@param moveType string attacking move type under test
---@param attackerTypes string[] attacker types in declared order
---@return boolean whether the attacker grants STAB to the move
function TypeEffectiveness.stab(moveType, attackerTypes)
  assert(type(moveType) == "string" and moveType ~= "", "STAB names its move type")
  assert(type(attackerTypes) == "table", "STAB reads its attacker types")
  if moveType == "typeless" then
    return false
  end
  for _, attackerType in ipairs(attackerTypes) do
    if attackerType == moveType then
      return true
    end
  end
  return false
end

return TypeEffectiveness
