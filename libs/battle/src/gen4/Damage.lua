-- Exact phased damage arithmetic. The staged order is base damage, the
-- burn halving, the multi-target spread reduction, field weather and the
-- charging grass special case, the bonus addition, the critical
-- multiplier, the random roll, STAB, one effectiveness truncation per
-- distinct defending type, and the minimum-damage clamp. Every stage
-- truncates on its own intermediate with integer floor division, so a
-- collapsed single-rounding port computes different answers at spread,
-- burn, random, and dual-type boundaries. Supplying an explicit random
-- percentage performs a deterministic estimate that draws nothing;
-- otherwise exactly one labeled battle-stream draw selects the 85..100
-- roll. Tracing records each staged intermediate without moving the
-- shared stream.

---@class DamageRational
---@field numerator integer
---@field denominator integer

---@class DamageSpec
---@field level integer
---@field power integer
---@field attack integer staged relevant attack after stat stages
---@field defense integer staged relevant defense after stat stages
---@field rawAttack integer unstaged relevant attack before stat stages
---@field rawDefense integer unstaged relevant defense before stat stages
---@field attackStage integer signed stage behind the staged attack
---@field defenseStage integer signed stage behind the staged defense
---@field criticalMultiplier integer native critical multiplier 1, 2, or 3
---@field category string physical or special strike category
---@field burned boolean whether the attacker carries burn
---@field guts boolean whether the attacker carries the resilient ability
---@field stab DamageRational
---@field effectiveness DamageRational aggregate immunity and classification pair
---@field effectivenessFactors DamageRational[] ordered per-type factors in declared defender order
---@field targetCount integer?
---@field weather string? active field weather identity
---@field weatherSuppressed boolean? whether a live ability suppresses weather damage
---@field moveType string striking move type under weather law
---@field solarBeam boolean? whether the strike is the charging grass special case
---@field randomPercent integer?

---@class DamageFixedSpec
---@field amount integer

---@class DamageResult
---@field amount integer
---@field critical boolean
---@field effectiveness DamageRational
---@field immunityReason string?
---@field stages DamageTraceStage[]?

---@class DamageTraceStage
---@field name string
---@field input integer
---@field output integer
---@field source string
local Damage = {}

Damage.SPREAD_NUMERATOR = 3072
Damage.SPREAD_DENOMINATOR = 4096
Damage.ROLL_MIN = 85
Damage.ROLL_SPAN = 16
Damage.ROLL_MODULUS = 65536

---@param value integer value under test
---@param name string value being read
local function requirePositiveInteger(value, name)
  assert(type(value) == "number" and value % 1 == 0 and value >= 1, name .. " must be a positive integer")
end

---@param ratio DamageRational exact multiplier under test
---@param name string value being read
local function requireRational(ratio, name)
  assert(type(ratio) == "table", name .. " must be an exact rational")
  assert(
    type(ratio.numerator) == "number" and ratio.numerator % 1 == 0 and ratio.numerator >= 0,
    name .. " carries a non-negative integer numerator"
  )
  assert(
    type(ratio.denominator) == "number" and ratio.denominator % 1 == 0 and ratio.denominator >= 1,
    name .. " carries a positive integer denominator"
  )
end

---@param value integer value under test
---@param name string value being read
local function requireStage(value, name)
  assert(type(value) == "number" and value % 1 == 0 and value >= -6 and value <= 6, name .. " stays a clamped stage")
end

---@param spec DamageSpec staged damage input under test
local function requireSpec(spec)
  assert(type(spec) == "table", "staged damage reads its specification")
  requirePositiveInteger(spec.level, "level")
  requirePositiveInteger(spec.power, "power")
  requirePositiveInteger(spec.attack, "attack")
  requirePositiveInteger(spec.defense, "defense")
  requirePositiveInteger(spec.rawAttack, "raw attack")
  requirePositiveInteger(spec.rawDefense, "raw defense")
  requireStage(spec.attackStage, "attack stage")
  requireStage(spec.defenseStage, "defense stage")
  assert(
    spec.criticalMultiplier == 1 or spec.criticalMultiplier == 2 or spec.criticalMultiplier == 3,
    "critical multipliers stay native 1, 2, or 3"
  )
  assert(spec.category == "physical" or spec.category == "special", "strikes name their physical/special category")
  assert(type(spec.burned) == "boolean", "strikes name their attacker burn")
  assert(type(spec.guts) == "boolean", "strikes name their resilient ability")
  requireRational(spec.stab, "stab")
  requireRational(spec.effectiveness, "effectiveness")
  assert(
    type(spec.effectivenessFactors) == "table" and #spec.effectivenessFactors >= 1,
    "strikes carry ordered type factors"
  )
  for _, factor in ipairs(spec.effectivenessFactors) do
    requireRational(factor, "type factor")
  end
  if spec.targetCount ~= nil then
    requirePositiveInteger(spec.targetCount, "target count")
  end
  assert(type(spec.weather) == "string" and spec.weather ~= "", "strikes name their field weather")
  assert(type(spec.weatherSuppressed) == "boolean", "strikes name their weather suppression")
  assert(type(spec.moveType) == "string" and spec.moveType ~= "", "strikes name their move type")
  if spec.solarBeam ~= nil then
    assert(type(spec.solarBeam) == "boolean", "strikes name their charging-grass case")
  end
  if spec.randomPercent ~= nil then
    assert(
      type(spec.randomPercent) == "number"
        and spec.randomPercent % 1 == 0
        and spec.randomPercent >= 1
        and spec.randomPercent <= 100,
      "random percentages name an integer roll in 1..100"
    )
  end
end

---@param stream BattleRng labeled native battle stream
local function requireStream(stream)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "staged damage draws from the battle stream")
end

---@param evaluated integer intermediate under recording
---@param stages DamageTraceStage[]? trace sink recording staged intermediates
---@param name string staged operation under recording
---@param input integer intermediate entering the stage
---@param source string staged operation naming its source arithmetic
local function recordStage(evaluated, stages, name, input, source)
  if stages ~= nil then
    stages[#stages + 1] = { name = name, input = input, output = evaluated, source = source }
  end
end

-- Native weather identities halving the charging grass strike: every
-- active weather beside sun and clear skies.
local NO_SUN_WEATHER = { rain = true, sand = true, hail = true }

---@param spec DamageSpec staged damage input under test
---@param stream BattleRng labeled native battle stream
---@param stages DamageTraceStage[]? trace sink recording staged intermediates
---@return integer final damage amount after every staged truncation
local function runStages(spec, stream, stages)
  local targetCount = spec.targetCount or 1
  -- Critical hits ignore only unfavorable stages: a lowered attack or a
  -- raised defense falls back to the raw stat, while favorable stages
  -- stay applied.
  local attackForDamage = spec.attack
  if spec.criticalMultiplier > 1 and spec.attackStage < 0 then
    attackForDamage = spec.rawAttack
  end
  local defenseForDamage = spec.defense
  if spec.criticalMultiplier > 1 and spec.defenseStage > 0 then
    defenseForDamage = spec.rawDefense
  end
  -- floor(floor(floor(2 * level / 5 + 2) * power * attack / defense) / 50).
  local step = math.floor((2 * spec.level) / 5) + 2
  step = math.floor((step * spec.power * attackForDamage) / defenseForDamage)
  local current = math.floor(step / 50)
  recordStage(current, stages, "base", spec.power, "floor(floor(floor(2*level/5+2)*power*attack/defense)/50)")

  -- Burn halves post-division physical damage unless the resilient
  -- ability answers; the attack stat itself is never pre-halved.
  if spec.category == "physical" and spec.burned and not spec.guts then
    local burned = math.floor(current / 2)
    recordStage(burned, stages, "burn", current, "floor(damage/2) for burned physical attackers")
    current = burned
  end

  if targetCount > 1 then
    local spread = math.floor((current * Damage.SPREAD_NUMERATOR) / Damage.SPREAD_DENOMINATOR)
    recordStage(spread, stages, "spread", current, "floor(damage*3072/4096) across sampled targets")
    current = spread
  end

  -- Rain halves fire and boosts water by 15/10; sun inverts the pair.
  -- Suppressed weather reads neutral without deleting the field state.
  if not spec.weatherSuppressed then
    if spec.weather == "rain" then
      if spec.moveType == "fire" then
        local rained = math.floor(current / 2)
        recordStage(rained, stages, "weather", current, "floor(damage/2) for fire strikes under rain")
        current = rained
      elseif spec.moveType == "water" then
        local rained = math.floor((current * 15) / 10)
        recordStage(rained, stages, "weather", current, "floor(damage*15/10) for water strikes under rain")
        current = rained
      end
    elseif spec.weather == "sun" then
      if spec.moveType == "fire" then
        local shone = math.floor((current * 15) / 10)
        recordStage(shone, stages, "weather", current, "floor(damage*15/10) for fire strikes under sun")
        current = shone
      elseif spec.moveType == "water" then
        local shone = math.floor(current / 2)
        recordStage(shone, stages, "weather", current, "floor(damage/2) for water strikes under sun")
        current = shone
      end
    end
  end

  if spec.solarBeam == true and NO_SUN_WEATHER[spec.weather] == true then
    local beamed = math.floor(current / 2)
    recordStage(beamed, stages, "solarbeam", current, "floor(damage/2) for the charging grass strike off sun")
    current = beamed
  end

  local bonused = current + 2
  recordStage(bonused, stages, "bonus", current, "damage+2 after the pre-bonus modifiers")
  current = bonused

  if spec.criticalMultiplier > 1 then
    local multiplied = current * spec.criticalMultiplier
    recordStage(
      multiplied,
      stages,
      "critical",
      current,
      "critical hits multiply post-bonus damage by " .. tostring(spec.criticalMultiplier)
    )
    current = multiplied
  end

  local percent = spec.randomPercent
  if percent == nil then
    local draw = stream:nextU16("damage_roll", { kind = "damage_roll" })
    percent = Damage.ROLL_MIN + math.floor((draw * Damage.ROLL_SPAN) / Damage.ROLL_MODULUS)
  end
  local rolled = math.floor((current * percent) / 100)
  recordStage(rolled, stages, "random", current, "floor(damage*rollPercent/100) with roll 85..100")
  current = rolled

  local stabbed = math.floor((current * spec.stab.numerator) / spec.stab.denominator)
  recordStage(stabbed, stages, "stab", current, "floor(damage*stabNumerator/stabDenominator)")
  current = stabbed

  for _, factor in ipairs(spec.effectivenessFactors) do
    local typed = math.floor((current * factor.numerator) / factor.denominator)
    recordStage(
      typed,
      stages,
      "effectiveness",
      current,
      "floor(damage*effectNumerator/effectDenominator) per defending type"
    )
    current = typed
  end

  if current < 1 then
    recordStage(1, stages, "minimum", current, "positive hits deal at least 1 damage")
    current = 1
  end
  return current
end

---@param spec DamageSpec staged damage input under test
---@param stream BattleRng labeled native battle stream
---@return DamageResult staged amount with its applied effectiveness
function Damage.calculate(spec, stream)
  requireSpec(spec)
  requireStream(stream)
  if spec.effectiveness.numerator == 0 then
    return {
      amount = 0,
      critical = spec.criticalMultiplier > 1,
      effectiveness = { numerator = spec.effectiveness.numerator, denominator = spec.effectiveness.denominator },
      immunityReason = "immunity",
    }
  end
  local amount = runStages(spec, stream, nil)
  return {
    amount = amount,
    critical = spec.criticalMultiplier > 1,
    effectiveness = { numerator = spec.effectiveness.numerator, denominator = spec.effectiveness.denominator },
  }
end

---@param spec DamageSpec staged damage input under test
---@param stream BattleRng labeled native battle stream
---@return DamageResult staged amount with every integer intermediate
function Damage.trace(spec, stream)
  requireSpec(spec)
  requireStream(stream)
  if spec.effectiveness.numerator == 0 then
    return {
      amount = 0,
      critical = spec.criticalMultiplier > 1,
      effectiveness = { numerator = spec.effectiveness.numerator, denominator = spec.effectiveness.denominator },
      immunityReason = "immunity",
      stages = {},
    }
  end
  local stages = {} ---@type DamageTraceStage[]
  local amount = runStages(spec, stream, stages)
  return {
    amount = amount,
    critical = spec.criticalMultiplier > 1,
    effectiveness = { numerator = spec.effectiveness.numerator, denominator = spec.effectiveness.denominator },
    stages = stages,
  }
end

---@param spec DamageFixedSpec fixed damage input under test
---@param stream BattleRng labeled native battle stream
---@return DamageResult fixed amount traveling its own draw-free path
function Damage.fixed(spec, stream)
  assert(type(spec) == "table", "fixed damage reads its specification")
  requirePositiveInteger(spec.amount, "fixed amount")
  requireStream(stream)
  return { amount = spec.amount, critical = false, effectiveness = { numerator = 1, denominator = 1 } }
end

return Damage
