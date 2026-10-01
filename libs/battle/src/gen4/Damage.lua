-- Exact phased damage arithmetic. The staged order is base damage, the
-- multi-target spread reduction, the critical doubling, STAB, type
-- effectiveness, the random roll, and the minimum-damage clamp. Every
-- stage truncates on its own intermediate with integer floor division, so
-- a collapsed single-rounding port computes different answers at spread
-- and STAB boundaries. Supplying an explicit random percentage performs a
-- deterministic estimate that draws nothing; otherwise exactly one labeled
-- battle-stream draw selects the 85..100 roll. Tracing records each staged
-- intermediate without moving the shared stream.

---@class DamageRational
---@field numerator integer
---@field denominator integer

---@class DamageSpec
---@field level integer
---@field power integer
---@field attack integer
---@field defense integer
---@field stab DamageRational
---@field effectiveness DamageRational
---@field targetCount integer?
---@field randomPercent integer?
---@field critical boolean?

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

---@param spec DamageSpec staged damage input under test
local function requireSpec(spec)
  assert(type(spec) == "table", "staged damage reads its specification")
  requirePositiveInteger(spec.level, "level")
  requirePositiveInteger(spec.power, "power")
  requirePositiveInteger(spec.attack, "attack")
  requirePositiveInteger(spec.defense, "defense")
  requireRational(spec.stab, "stab")
  requireRational(spec.effectiveness, "effectiveness")
  if spec.targetCount ~= nil then
    requirePositiveInteger(spec.targetCount, "target count")
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

---@param spec DamageSpec staged damage input under test
---@param stream BattleRng labeled native battle stream
---@param stages DamageTraceStage[]? trace sink recording staged intermediates
---@return integer final damage amount after every staged truncation
local function runStages(spec, stream, stages)
  local targetCount = spec.targetCount or 1
  -- floor(floor(floor(2 * level / 5 + 2) * power * attack / defense) / 50) + 2.
  local step = math.floor((2 * spec.level) / 5) + 2
  step = math.floor((step * spec.power * spec.attack) / spec.defense)
  local base = math.floor(step / 50) + 2
  if stages ~= nil then
    stages[#stages + 1] = {
      name = "base",
      input = spec.power,
      output = base,
      source = "floor(floor(floor(2*level/5+2)*power*attack/defense)/50)+2",
    }
  end

  local current = base
  if targetCount > 1 then
    local spread = math.floor((current * Damage.SPREAD_NUMERATOR) / Damage.SPREAD_DENOMINATOR)
    if stages ~= nil then
      stages[#stages + 1] =
        { name = "spread", input = current, output = spread, source = "floor(damage*3072/4096) across sampled targets" }
    end
    current = spread
  end

  if spec.critical == true then
    local doubled = current * 2
    if stages ~= nil then
      stages[#stages + 1] =
        { name = "critical", input = current, output = doubled, source = "critical hits double staged damage" }
    end
    current = doubled
  end

  local stabbed = math.floor((current * spec.stab.numerator) / spec.stab.denominator)
  if stages ~= nil then
    stages[#stages + 1] =
      { name = "stab", input = current, output = stabbed, source = "floor(damage*stabNumerator/stabDenominator)" }
  end
  current = stabbed

  local typed = math.floor((current * spec.effectiveness.numerator) / spec.effectiveness.denominator)
  if stages ~= nil then
    stages[#stages + 1] = {
      name = "effectiveness",
      input = current,
      output = typed,
      source = "floor(damage*effectNumerator/effectDenominator)",
    }
  end
  current = typed

  local percent = spec.randomPercent
  if percent == nil then
    local draw = stream:nextU16("damage_roll", { kind = "damage_roll" })
    percent = Damage.ROLL_MIN + math.floor((draw * Damage.ROLL_SPAN) / Damage.ROLL_MODULUS)
  end
  local rolled = math.floor((current * percent) / 100)
  if stages ~= nil then
    stages[#stages + 1] =
      { name = "random", input = current, output = rolled, source = "floor(damage*rollPercent/100) with roll 85..100" }
  end
  current = rolled

  if current < 1 then
    if stages ~= nil then
      stages[#stages + 1] =
        { name = "minimum", input = current, output = 1, source = "positive hits deal at least 1 damage" }
    end
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
      critical = spec.critical == true,
      effectiveness = { numerator = spec.effectiveness.numerator, denominator = spec.effectiveness.denominator },
      immunityReason = "immunity",
    }
  end
  local amount = runStages(spec, stream, nil)
  return {
    amount = amount,
    critical = spec.critical == true,
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
      critical = spec.critical == true,
      effectiveness = { numerator = spec.effectiveness.numerator, denominator = spec.effectiveness.denominator },
      immunityReason = "immunity",
      stages = {},
    }
  end
  local stages = {} ---@type DamageTraceStage[]
  local amount = runStages(spec, stream, stages)
  return {
    amount = amount,
    critical = spec.critical == true,
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
