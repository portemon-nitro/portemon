-- Exact staged damage arithmetic: hand-specified vectors pin every integer
-- truncation in source order, so a collapsed single-rounding port fails.
-- Base damage truncates after each multiply/divide step, spread and STAB
-- truncate at their own stages, the random roll spans 85..100, and any
-- positive hit deals at least 1. Traced and untraced calculations consume
-- identical random draws.
--
-- Vector method: each literal below was fixed by hand from the Generation-IV
-- operation sequence (base = floor(floor(floor(2*Level/5+2)*Power*Attack /
-- Defense)/50)+2, then staged exact multipliers) and cross-checked with a
-- throwaway script that is not the production implementation.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param Damage table staged damage owner under test
---@param StatStages table stage clamp and ratio owner under test
---@param Critical table critical check owner under test
---@return table loaded combat arithmetic owners
local function arithmeticOwners(Damage, StatStages, Critical)
  Assert.isTrue(type(Damage.calculate) == "function", "staged damage owns its phased calculation")
  Assert.isTrue(type(Damage.fixed) == "function", "fixed damage owns its distinct path")
  Assert.isTrue(type(Damage.trace) == "function", "staged damage owns its debug trace")
  Assert.isTrue(type(StatStages.change) == "function", "stages own their signed clamped deltas")
  Assert.isTrue(type(StatStages.multiplier) == "function", "stages own their exact ratios")
  Assert.isTrue(type(StatStages.effective) == "function", "stages own their applied stat")
  Assert.isTrue(type(Critical.resolve) == "function", "critical checks own their staged roll")
  return { Damage = Damage, StatStages = StatStages, Critical = Critical }
end

---@param owners table loaded combat arithmetic owners
---@return table battle stream owner under test
local function streamOwner(owners)
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  Assert.notNil(owners.Damage, "damage arithmetic loads before its stream is read")
  return BattleRng
end

-- Level 50, power 80, attack 120, defense 90:
-- floor(2*50/5+2) = 22; 22*80*120 = 211200; floor(211200/90) = 2346;
-- floor(2346/50) = 46; +2 = 48.
function T.staged_multipliers_truncate_in_order()
  local owners = arithmeticOwners(
    SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage"),
    SessionFixture.requirePresent("libs.battle.src.gen4.StatStages", "source stage clamps own stat ratios"),
    SessionFixture.requirePresent("libs.battle.src.gen4.Critical", "native critical checks own their roll")
  )
  local BattleRng = streamOwner(owners)

  local plain = owners.Damage.calculate({
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    targetCount = 1,
    randomPercent = 100,
  }, BattleRng.new(3))
  Assert.equal(plain.amount, 48, "base intermediates truncate before the final addition")

  -- STAB 3/2 on 48: floor(48*3/2) = 72; roll 85: floor(72*85/100) = 61.
  local stabbed = owners.Damage.calculate({
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    stab = { numerator = 3, denominator = 2 },
    effectiveness = { numerator = 1, denominator = 1 },
    targetCount = 1,
    randomPercent = 85,
  }, BattleRng.new(3))
  Assert.equal(stabbed.amount, 61, "STAB truncates at its own stage before the random roll")

  -- Doubly effective on top of STAB: 72*2 = 144; roll 85: floor(144*85/100) = 122.
  local doubled = owners.Damage.calculate({
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    stab = { numerator = 3, denominator = 2 },
    effectiveness = { numerator = 2, denominator = 1 },
    targetCount = 1,
    randomPercent = 85,
  }, BattleRng.new(3))
  Assert.equal(doubled.amount, 122, "effectiveness applies after STAB at its own stage")
end

-- Level 5, power 35, attack 55, defense 45:
-- floor(2*5/5+2) = 4; 4*35*55 = 7700; floor(7700/45) = 171;
-- floor(171/50) = 3; +2 = 5. Spread 3/4: floor(5*3072/4096) = 3.
-- STAB 3/2: floor(3*3/2) = 4. A collapsed float port computes
-- 5*0.75*1.5 = 5.625 -> 5, so the literal 4 kills it.
function T.spread_then_stab_boundaries_catch_collapsed_rounding()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local spread = Damage.calculate({
    level = 5,
    power = 35,
    attack = 55,
    defense = 45,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    targetCount = 2,
    randomPercent = 100,
  }, BattleRng.new(11))
  Assert.equal(spread.amount, 3, "spread reduction truncates before later stages")

  local spreadStab = Damage.calculate({
    level = 5,
    power = 35,
    attack = 55,
    defense = 45,
    stab = { numerator = 3, denominator = 2 },
    effectiveness = { numerator = 1, denominator = 1 },
    targetCount = 2,
    randomPercent = 100,
  }, BattleRng.new(11))
  Assert.equal(spreadStab.amount, 4, "STAB truncates on the spread intermediate, never the float product")

  local single = Damage.calculate({
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    targetCount = 2,
    randomPercent = 100,
  }, BattleRng.new(11))
  Assert.equal(single.amount, 36, "two targets reduce 48 by exactly one quarter")
end

-- Level 5, power 10, attack 10, defense 200:
-- floor(2*5/5+2) = 4; 4*10*10 = 400; floor(400/200) = 2;
-- floor(2/50) = 0; +2 = 2. Resisted 1/4: floor(2*1/4) = 0, clamped to 1.
function T.resisted_hits_deal_at_least_one()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local chip = Damage.calculate({
    level = 5,
    power = 10,
    attack = 10,
    defense = 200,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 4 },
    targetCount = 1,
    randomPercent = 85,
  }, BattleRng.new(23))
  Assert.equal(chip.amount, 1, "positive hits never round down to zero")
end

-- First draw of seed 0 is the recorded literal 0, mapping to roll 85 via
-- 85 + floor(draw*16/65536); both calculation modes must agree exactly.
function T.traced_and_untraced_calculations_share_one_draw_stream()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local spec = {
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    stab = { numerator = 3, denominator = 2 },
    effectiveness = { numerator = 1, denominator = 1 },
    targetCount = 1,
  }
  local plainStream = BattleRng.new(0)
  local plain = Damage.calculate(spec, plainStream)
  Assert.equal(plain.amount, 61, "the recorded zero draw rolls the 85 minimum")
  Assert.equal(plainStream:capture().calls, 1, "the roll consumes exactly one labeled draw")

  local tracedStream = BattleRng.new(0)
  local traced = Damage.trace(spec, tracedStream)
  Assert.equal(traced.amount, 61, "traced calculation matches the untraced result")
  Assert.equal(tracedStream:capture().calls, 1, "tracing never moves the shared stream")
  Assert.isTrue(type(traced.stages) == "table" and #traced.stages > 0, "traces record their staged intermediates")
  for _, stage in ipairs(traced.stages) do
    Assert.isTrue(type(stage.name) == "string", "trace stages name their operation")
    Assert.isTrue(type(stage.input) == "number" and stage.input % 1 == 0, "trace stages record integer inputs")
    Assert.isTrue(type(stage.output) == "number" and stage.output % 1 == 0, "trace stages record integer outputs")
    Assert.isTrue(type(stage.source) == "string", "trace stages name their source operation")
  end
end

-- Stat stages are exact ratios: attack +2 is 4/2, attack -1 is 2/3,
-- accuracy +1 is 133/100; effective stats floor at application; deltas clamp.
function T.stage_ratios_clamp_and_floor_exactly()
  local StatStages =
    SessionFixture.requirePresent("libs.battle.src.gen4.StatStages", "source stage clamps own stat ratios")

  Assert.deepEqual(StatStages.multiplier(2, "attack"), { numerator = 4, denominator = 2 }, "attack +2 doubles")
  Assert.deepEqual(StatStages.multiplier(-1, "attack"), { numerator = 2, denominator = 3 }, "attack -1 is two thirds")
  Assert.deepEqual(StatStages.multiplier(1, "accuracy"), { numerator = 133, denominator = 100 }, "accuracy +1 is 133/100")
  Assert.deepEqual(
    StatStages.multiplier(-1, "evasion"),
    { numerator = 75, denominator = 100 },
    "evasion -1 on the target is 75/100"
  )
  Assert.equal(StatStages.effective(100, 2, "attack"), 200, "doubled 100 stays exact")
  Assert.equal(StatStages.effective(100, -1, "attack"), 66, "two thirds of 100 floors to 66")
  Assert.equal(StatStages.change(3, 2), 5, "deltas add inside the bounds")
  Assert.equal(StatStages.change(5, 2), 6, "deltas clamp at the upper bound")
  Assert.equal(StatStages.change(-5, -2), -6, "deltas clamp at the lower bound")
end

-- Critical stages are exact thresholds of the 16-bit draw: stage 0 crits
-- below 4096 (65536/16). Seed 0 opens with the recorded draw 0, seed 1
-- opens with the recorded draw 16838.
function T.critical_stages_gate_exact_draw_thresholds()
  local Critical =
    SessionFixture.requirePresent("libs.battle.src.gen4.Critical", "native critical checks own their roll")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local cause = { kind = "probe", combatant = 1, activation = 1 }

  local low = BattleRng.new(0)
  Assert.isTrue(Critical.resolve(0, low, cause).critical, "the recorded zero draw crits at stage 0")
  Assert.equal(low:capture().calls, 1, "critical checks consume exactly one labeled draw")

  local high = BattleRng.new(1)
  Assert.isFalse(Critical.resolve(0, high, cause).critical, "draw 16838 clears the stage-0 threshold of 4096")
  Assert.equal(high:capture().calls, 1, "missed critical checks still advance the stream")
end

-- Level-shaped fixed damage travels its own path without random draws.
function T.fixed_damage_uses_its_own_path()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local stream = BattleRng.new(9)
  Assert.equal(Damage.fixed({ amount = 40 }, stream).amount, 40, "fixed amounts pass through unmodified")
  Assert.equal(stream:capture().calls, 0, "fixed damage draws nothing from the stream")
end

return { tests = T }
