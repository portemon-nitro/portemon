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
    rawAttack = 120,
    rawDefense = 90,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    effectivenessFactors = { { numerator = 1, denominator = 1 } },
    targetCount = 1,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
    randomPercent = 100,
  }, BattleRng.new(3))
  Assert.equal(plain.amount, 48, "base intermediates truncate before the final addition")

  -- Post-bonus 48 rolls 85 first: floor(48*85/100) = 40; STAB 3/2 after
  -- the roll: floor(40*3/2) = 60.
  local stabbed = owners.Damage.calculate({
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    rawAttack = 120,
    rawDefense = 90,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 3, denominator = 2 },
    effectiveness = { numerator = 1, denominator = 1 },
    effectivenessFactors = { { numerator = 1, denominator = 1 } },
    targetCount = 1,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
    randomPercent = 85,
  }, BattleRng.new(3))
  Assert.equal(stabbed.amount, 60, "the random roll truncates before STAB at its own stage")

  -- Doubly effective on top of STAB: 60*2 = 120.
  local doubled = owners.Damage.calculate({
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    rawAttack = 120,
    rawDefense = 90,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 3, denominator = 2 },
    effectiveness = { numerator = 2, denominator = 1 },
    effectivenessFactors = { { numerator = 2, denominator = 1 } },
    targetCount = 1,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
    randomPercent = 85,
  }, BattleRng.new(3))
  Assert.equal(doubled.amount, 120, "effectiveness applies after STAB at its own stage")
end

-- Level 5, power 35, attack 55, defense 45:
-- floor(2*5/5+2) = 4; 4*35*55 = 7700; floor(7700/45) = 171;
-- floor(171/50) = 3. Spread 3/4 before the bonus: floor(3*3072/4096)
-- = 2; +2 = 4. STAB 3/2 after the roll: floor(4*3/2) = 6. A port that
-- spreads the post-bonus 5 answers 3, and a collapsed float port
-- computes 5*0.75*1.5 = 5.625 -> 5, so the literals 4 and 6 kill both.
function T.spread_then_stab_boundaries_catch_collapsed_rounding()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local function spreadSpec(stab)
    return {
      level = 5,
      power = 35,
      attack = 55,
      defense = 45,
      rawAttack = 55,
      rawDefense = 45,
      attackStage = 0,
      defenseStage = 0,
      criticalMultiplier = 1,
      category = "physical",
      burned = false,
      guts = false,
      stab = stab,
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      targetCount = 2,
      weather = "none",
      weatherSuppressed = false,
      moveType = "normal",
      solarBeam = false,
      randomPercent = 100,
    }
  end

  local spread = Damage.calculate(spreadSpec({ numerator = 1, denominator = 1 }), BattleRng.new(11))
  Assert.equal(spread.amount, 4, "spread reduction truncates before the bonus addition")

  local spreadStab = Damage.calculate(spreadSpec({ numerator = 3, denominator = 2 }), BattleRng.new(11))
  Assert.equal(spreadStab.amount, 6, "STAB truncates on the spread intermediate, never the float product")

  local single = Damage.calculate({
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    rawAttack = 120,
    rawDefense = 90,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    effectivenessFactors = { { numerator = 1, denominator = 1 } },
    targetCount = 2,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
    randomPercent = 100,
  }, BattleRng.new(11))
  -- Pre-bonus 46 spreads to floor(46*3072/4096) = 34 before the bonus
  -- addition lands 36: this vector cannot separate the two spread
  -- checkpoints, so the level-5 vector above carries the separation.
  Assert.equal(single.amount, 36, "two targets spread the pre-bonus damage before the bonus addition")
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
    rawAttack = 10,
    rawDefense = 200,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 4 },
    effectivenessFactors = { { numerator = 1, denominator = 4 } },
    targetCount = 1,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
    randomPercent = 85,
  }, BattleRng.new(23))
  Assert.equal(chip.amount, 1, "positive hits never round down to zero")
end

-- First draw of seed 0 is the recorded literal 0, mapping to roll 100 via
-- 100 - draw % 16; both calculation modes must agree exactly.
function T.traced_and_untraced_calculations_share_one_draw_stream()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local spec = {
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    rawAttack = 120,
    rawDefense = 90,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 3, denominator = 2 },
    effectiveness = { numerator = 1, denominator = 1 },
    effectivenessFactors = { { numerator = 1, denominator = 1 } },
    targetCount = 1,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
  }
  local plainStream = BattleRng.new(0)
  local plain = Damage.calculate(spec, plainStream)
  Assert.equal(plain.amount, 72, "the recorded zero draw rolls the 100 maximum")
  Assert.equal(plainStream:capture().calls, 1, "the roll consumes exactly one labeled draw")

  local tracedStream = BattleRng.new(0)
  local traced = Damage.trace(spec, tracedStream)
  Assert.equal(traced.amount, 72, "traced calculation matches the untraced result")
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

-- Critical stages are exact divisors of the 16-bit draw: stage 0 crits
-- on multiples of 16. Seed 0 opens with the recorded draw 0, seed 1
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
  Assert.isFalse(Critical.resolve(0, high, cause).critical, "draw 16838 misses the stage-0 divisor of 16")
  Assert.equal(high:capture().calls, 1, "missed critical checks still advance the stream")
end

-- A critical strike selects its stats from the raw values whenever the
-- stage is unfavorable, while favorable stages stay applied. Hand
-- evaluation with level 50, power 80, and raw 100/100 stats:
-- attacker stage -2 stages attack to 50 and defender stage +2 stages
-- defense to 200, so the plain hit runs 22*80*50 = 88000, floor(/200) =
-- 440, floor(/50) = 8, +2 = 10. The critical hit instead runs
-- 22*80*100 = 176000 on the raw pair, floor(/100) = 1760, floor(/50) =
-- 35, +2 = 37, doubled to 74. A port that merely doubles staged damage
-- answers 20. Favorable stages (+2 attack to 200, -2 defense to 50) run
-- 22*80*200 = 352000, floor(/50) = 7040, floor(/50) = 140, +2 = 142,
-- doubled to 284 on a critical hit and 142 plain.
function T.critical_hits_ignore_only_unfavorable_stages()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local function strike(attack, defense, rawAttack, rawDefense, attackStage, defenseStage, multiplier)
    return {
      level = 50,
      power = 80,
      attack = attack,
      defense = defense,
      rawAttack = rawAttack,
      rawDefense = rawDefense,
      attackStage = attackStage,
      defenseStage = defenseStage,
      criticalMultiplier = multiplier,
      category = "physical",
      burned = false,
      guts = false,
      stab = { numerator = 1, denominator = 1 },
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      targetCount = 1,
      weather = "none",
      weatherSuppressed = false,
      moveType = "normal",
      solarBeam = false,
      randomPercent = 100,
    }
  end

  local plain = Damage.calculate(strike(50, 200, 100, 100, -2, 2, 1), BattleRng.new(3))
  Assert.equal(plain.amount, 10, "the plain hit uses the staged pair")

  local critical = Damage.calculate(strike(50, 200, 100, 100, -2, 2, 2), BattleRng.new(3))
  Assert.equal(critical.amount, 74, "the critical hit recovers both raw stats")

  local favored = Damage.calculate(strike(200, 50, 100, 100, 2, -2, 2), BattleRng.new(3))
  Assert.equal(favored.amount, 284, "the critical hit keeps favorable stages")

  local favoredPlain = Damage.calculate(strike(200, 50, 100, 100, 2, -2, 1), BattleRng.new(3))
  Assert.equal(favoredPlain.amount, 142, "the plain hit matches the favored critical before doubling")
end

-- The native critical multiplier is triple for the sniping ability and
-- double otherwise, with identical probability and draw counts. The same
-- neutral level-50 strike runs a pre-roll 48, so doubling lands 96 and
-- tripling lands 144 at a fixed maximum roll.
function T.sniping_criticals_triple_after_the_bonus()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local Critical =
    SessionFixture.requirePresent("libs.battle.src.gen4.Critical", "native critical checks own their roll")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local cause = { kind = "probe", combatant = 1, activation = 1 }

  local function strike(multiplier)
    return {
      level = 50,
      power = 80,
      attack = 120,
      defense = 90,
      rawAttack = 120,
      rawDefense = 90,
      attackStage = 0,
      defenseStage = 0,
      criticalMultiplier = multiplier,
      category = "physical",
      burned = false,
      guts = false,
      stab = { numerator = 1, denominator = 1 },
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      targetCount = 1,
      weather = "none",
      weatherSuppressed = false,
      moveType = "normal",
      solarBeam = false,
      randomPercent = 100,
    }
  end

  local doubled = Damage.calculate(strike(2), BattleRng.new(3))
  Assert.equal(doubled.amount, 96, "the ordinary critical doubles the post-bonus damage")
  local tripled = Damage.calculate(strike(3), BattleRng.new(3))
  Assert.equal(tripled.amount, 144, "the sniping critical triples the post-bonus damage")

  local plainStream = BattleRng.new(0)
  local plain = Critical.resolve(0, plainStream, cause, false)
  Assert.isTrue(plain.critical, "the recorded zero draw crits without the ability")
  Assert.equal(plain.multiplier, 2, "the ordinary critical carries double")
  Assert.equal(plainStream:capture().calls, 1, "the ordinary check draws exactly once")

  local snipingStream = BattleRng.new(0)
  local sniping = Critical.resolve(0, snipingStream, cause, true)
  Assert.isTrue(sniping.critical, "the recorded zero draw crits with the ability")
  Assert.equal(sniping.multiplier, 3, "the sniping critical carries triple")
  Assert.equal(snipingStream:capture().calls, 1, "the sniping check draws exactly once")

  local missedStream = BattleRng.new(1)
  local missed = Critical.resolve(0, missedStream, cause, true)
  Assert.isFalse(missed.critical, "draw 16838 still misses with the ability")
  Assert.equal(missed.multiplier, 1, "a missed check never multiplies")
end

-- Spread and burn truncate before the bonus addition. Level 5, power 35,
-- attack 55, defense 45 runs a pre-bonus 3: the old order spreads 5 to 3
-- while the native order spreads 3 to 2 and then adds 2 for 4. Level 50,
-- power 80, odd attack 123, defense 90 runs a pre-bonus 48: halving the
-- attack stat first lands 25 while halving post-division damage lands
-- floor(48/2) = 24 and then adds 2 for 26. The resilient ability and
-- special strikes skip the halving and land 50.
function T.spread_and_burn_truncate_before_the_bonus()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local spread = Damage.calculate({
    level = 5,
    power = 35,
    attack = 55,
    defense = 45,
    rawAttack = 55,
    rawDefense = 45,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    effectivenessFactors = { { numerator = 1, denominator = 1 } },
    targetCount = 2,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
    randomPercent = 100,
  }, BattleRng.new(11))
  Assert.equal(spread.amount, 4, "spread reduces the pre-bonus damage")

  local function burnedStrike(category, guts)
    return {
      level = 50,
      power = 80,
      attack = 123,
      defense = 90,
      rawAttack = 123,
      rawDefense = 90,
      attackStage = 0,
      defenseStage = 0,
      criticalMultiplier = 1,
      category = category,
      burned = true,
      guts = guts,
      stab = { numerator = 1, denominator = 1 },
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      targetCount = 1,
      weather = "none",
      weatherSuppressed = false,
      moveType = "normal",
      solarBeam = false,
      randomPercent = 100,
    }
  end

  local burned = Damage.calculate(burnedStrike("physical", false), BattleRng.new(11))
  Assert.equal(burned.amount, 26, "burn halves post-division damage, never the attack stat")
  local resilient = Damage.calculate(burnedStrike("physical", true), BattleRng.new(11))
  Assert.equal(resilient.amount, 50, "the resilient ability keeps the full pre-bonus damage")
  local special = Damage.calculate(burnedStrike("special", false), BattleRng.new(11))
  Assert.equal(special.amount, 50, "special strikes ignore the burn penalty")
end

-- Field weather and the charging grass strike scale at the pre-bonus
-- checkpoint. Level 50, power 80, attack 120, defense 90 runs pre-bonus
-- 46: rain halves fire to 23 and boosts water to floor(46*15/10) = 69,
-- sun inverts the pair, suppression holds 48, and the charging grass
-- strike halves to 23 under rain while holding 48 under sun and clear
-- skies.
function T.field_weather_and_charging_grass_scale_before_the_bonus()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  ---@param moveType string striking move type under weather law
  ---@param weather string active field weather identity
  ---@param weatherSuppressed boolean whether a live ability suppresses the sky
  ---@param solarBeam boolean whether the strike is the charging grass case
  ---@return integer damage at the fixed maximum roll
  local function weatherStrike(moveType, weather, weatherSuppressed, solarBeam)
    return Damage.calculate({
      level = 50,
      power = 80,
      attack = 120,
      defense = 90,
      rawAttack = 120,
      rawDefense = 90,
      attackStage = 0,
      defenseStage = 0,
      criticalMultiplier = 1,
      category = "special",
      burned = false,
      guts = false,
      stab = { numerator = 1, denominator = 1 },
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      targetCount = 1,
      weather = weather,
      weatherSuppressed = weatherSuppressed,
      moveType = moveType,
      solarBeam = solarBeam,
      randomPercent = 100,
    }, BattleRng.new(11)).amount
  end

  Assert.equal(weatherStrike("fire", "rain", false, false), 25, "rain halves the fire strike")
  Assert.equal(weatherStrike("water", "rain", false, false), 71, "rain boosts the water strike")
  Assert.equal(weatherStrike("fire", "sun", false, false), 71, "sun boosts the fire strike")
  Assert.equal(weatherStrike("water", "sun", false, false), 25, "sun halves the water strike")
  Assert.equal(weatherStrike("fire", "rain", true, false), 48, "suppression restores the neutral amount")
  Assert.equal(weatherStrike("grass", "rain", false, true), 25, "the charging grass strike halves off sun")
  Assert.equal(weatherStrike("grass", "sun", false, true), 48, "the charging grass strike holds under sun")
  Assert.equal(weatherStrike("grass", "none", false, true), 48, "the charging grass strike holds under clear skies")
end

-- The random roll precedes same-type bonus and effectiveness. Level 5,
-- power 35, attack 55, defense 45 runs pre-bonus 3 and post-bonus 5: the
-- native tail rolls 85 first (floor(5*85/100) = 4) and then applies the
-- 3/2 bonus for 6, while the swapped order bonuses first to 7 and rolls
-- second for 5.
function T.random_roll_precedes_bonus_and_effectiveness()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local spec = {
    level = 5,
    power = 35,
    attack = 55,
    defense = 45,
    rawAttack = 55,
    rawDefense = 45,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 3, denominator = 2 },
    effectiveness = { numerator = 1, denominator = 1 },
    effectivenessFactors = { { numerator = 1, denominator = 1 } },
    targetCount = 1,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
    randomPercent = 85,
  }
  local rolled = Damage.calculate(spec, BattleRng.new(11))
  Assert.equal(rolled.amount, 6, "the roll applies before the same-type bonus")

  local traced = Damage.trace(spec, BattleRng.new(11))
  Assert.equal(traced.amount, 6, "traced calculation matches the untraced result")
  local names = {}
  for _, stage in ipairs(traced.stages) do
    names[#names + 1] = stage.name
  end
  local randomAt, bonusAt, typeAt = nil, nil, nil
  for index, name in ipairs(names) do
    if name == "random" and randomAt == nil then
      randomAt = index
    end
    if name == "stab" and bonusAt == nil then
      bonusAt = index
    end
    if name == "effectiveness" and typeAt == nil then
      typeAt = index
    end
  end
  Assert.notNil(randomAt, "the trace records the random roll")
  Assert.notNil(bonusAt, "the trace records the same-type bonus")
  Assert.notNil(typeAt, "the trace records effectiveness")
  Assert.isTrue(randomAt < bonusAt, "the random roll precedes the same-type bonus")
  Assert.isTrue(bonusAt < typeAt, "the same-type bonus precedes effectiveness")
end

-- Each defending type truncates in declared order instead of collapsing
-- into one aggregate. Level 50, power 40, attack 100, defense 250 runs
-- 22*40*100 = 88000, floor(/250) = 352, floor(/50) = 7, +2 = 9: factors
-- 1/2 then 2/1 floor 9 to 4 and back up to 8, while the collapsed neutral
-- aggregate would hold 9.
function T.dual_type_effectiveness_truncates_each_factor_in_order()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local spec = {
    level = 50,
    power = 40,
    attack = 100,
    defense = 250,
    rawAttack = 100,
    rawDefense = 250,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    effectivenessFactors = { { numerator = 1, denominator = 2 }, { numerator = 2, denominator = 1 } },
    targetCount = 1,
    weather = "none",
    weatherSuppressed = false,
    moveType = "fire",
    solarBeam = false,
    randomPercent = 100,
  }
  local split = Damage.calculate(spec, BattleRng.new(11))
  Assert.equal(split.amount, 8, "sequential truncation floors each defending type")

  local traced = Damage.trace(spec, BattleRng.new(11))
  local typed = {}
  for _, stage in ipairs(traced.stages) do
    if stage.name == "effectiveness" then
      typed[#typed + 1] = stage
    end
  end
  Assert.equal(#typed, 2, "each defending type records its own stage")
  Assert.equal(typed[1].input, 9, "the first factor reads the post-bonus damage")
  Assert.equal(typed[1].output, 4, "the halving factor floors first")
  Assert.equal(typed[2].input, 4, "the second factor reads the floored intermediate")
  Assert.equal(typed[2].output, 8, "the doubling factor floors second")
end

-- Level-shaped fixed damage travels its own path without random draws.
function T.fixed_damage_uses_its_own_path()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local fixedStream = BattleRng.new(9)
  Assert.equal(Damage.fixed({ amount = 40 }, fixedStream).amount, 40, "fixed amounts pass through unmodified")
  Assert.equal(fixedStream:capture().calls, 0, "fixed damage draws nothing from the stream")
end

-- The live random roll maps one raw draw with remainder arithmetic:
-- 100 - raw % 16, so draws 0 and 16 land the maximum while draw 15 lands
-- the minimum. Each live calculation spends exactly one labeled roll, and
-- an explicit percentage stays draw-free for arithmetic-only estimates.
function T.random_roll_maps_raw_draws_with_remainder_arithmetic()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local function liveSpec()
    return {
      level = 50,
      power = 80,
      attack = 120,
      defense = 90,
      rawAttack = 120,
      rawDefense = 90,
      attackStage = 0,
      defenseStage = 0,
      criticalMultiplier = 1,
      category = "physical",
      burned = false,
      guts = false,
      stab = { numerator = 1, denominator = 1 },
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      targetCount = 1,
      weather = "none",
      weatherSuppressed = false,
      moveType = "normal",
      solarBeam = false,
    }
  end

  local function scriptedStream(raw, log)
    local stream = {}
    function stream:nextU16(label, cause)
      assert(type(label) == "string" and label ~= "", "the roll names its draw site")
      assert(type(cause) == "table", "the roll carries its semantic cause")
      log.calls = log.calls + 1
      log.labels[#log.labels + 1] = label
      return raw
    end
    function stream:capture()
      return { calls = log.calls }
    end
    return stream
  end

  -- Pre-bonus 46 takes +2 to 48, so the maximum roll lands 48 and the
  -- minimum roll lands floor(48*85/100) = 40.
  local cases = {
    { raw = 0, amount = 48 },
    { raw = 15, amount = 40 },
    { raw = 16, amount = 48 },
    { raw = 65535, amount = 40 },
  }
  for _, case in ipairs(cases) do
    local log = { calls = 0, labels = {} }
    local dealt = Damage.calculate(liveSpec(), scriptedStream(case.raw, log))
    Assert.equal(dealt.amount, case.amount, "raw draw " .. case.raw .. " rolls its remainder-mapped damage")
    Assert.equal(log.calls, 1, "raw draw " .. case.raw .. " spends exactly one roll")
    Assert.deepEqual(log.labels, { "damage_roll" }, "the roll draws at its labeled site")
  end

  local tracedLog = { calls = 0, labels = {} }
  local traced = Damage.trace(liveSpec(), scriptedStream(0, tracedLog))
  Assert.equal(traced.amount, 48, "the traced maximum roll matches the untraced result")
  local rolled = nil
  for _, stage in ipairs(traced.stages) do
    if stage.name == "random" then
      rolled = stage
    end
  end
  Assert.notNil(rolled, "the trace records the random roll")
  Assert.equal(rolled.input, 48, "the roll reads the post-bonus damage")
  Assert.equal(rolled.output, 48, "the maximum raw draw keeps the full post-bonus damage")

  local estimatedStream = BattleRng.new(3)
  local estimated = liveSpec()
  estimated.randomPercent = 100
  Assert.equal(Damage.calculate(estimated, estimatedStream).amount, 48, "the explicit percentage estimates the maximum")
  Assert.equal(estimatedStream:capture().calls, 0, "explicit percentages draw nothing from the stream")
end

-- Critical stages roll remainder checks against the native divisors
-- 16/8/4/3/2: a draw crits exactly when raw % divisor == 0. Stages below
-- the table behave as stage 0 and stages above as stage 4, and every
-- check spends exactly one labeled draw while reporting its divisor.
function T.critical_stages_roll_remainder_checks_against_native_divisors()
  local Critical =
    SessionFixture.requirePresent("libs.battle.src.gen4.Critical", "native critical checks own their roll")
  local cause = { kind = "probe", combatant = 1, activation = 1 }

  local function scriptedStream(raw, log)
    local stream = {}
    function stream:nextU16(label, checkCause)
      assert(type(label) == "string" and label ~= "", "the check names its draw site")
      assert(type(checkCause) == "table", "the check carries its semantic cause")
      log.calls = log.calls + 1
      log.labels[#log.labels + 1] = label
      return raw
    end
    return stream
  end

  local cases = {
    { stage = 0, divisor = 16, raw = 32, critical = true },
    { stage = 0, divisor = 16, raw = 17, critical = false },
    { stage = 1, divisor = 8, raw = 24, critical = true },
    { stage = 1, divisor = 8, raw = 17, critical = false },
    { stage = 2, divisor = 4, raw = 20, critical = true },
    { stage = 2, divisor = 4, raw = 18, critical = false },
    { stage = 3, divisor = 3, raw = 21846, critical = true },
    { stage = 3, divisor = 3, raw = 21845, critical = false },
    { stage = 4, divisor = 2, raw = 65534, critical = true },
    { stage = 4, divisor = 2, raw = 65535, critical = false },
    { stage = -2, divisor = 16, raw = 32, critical = true },
    { stage = -2, divisor = 16, raw = 17, critical = false },
    { stage = 7, divisor = 2, raw = 65534, critical = true },
    { stage = 7, divisor = 2, raw = 65535, critical = false },
  }
  for _, case in ipairs(cases) do
    local log = { calls = 0, labels = {} }
    local result = Critical.resolve(case.stage, scriptedStream(case.raw, log), cause)
    if case.critical then
      Assert.isTrue(result.critical, "stage " .. case.stage .. " crits on raw draw " .. case.raw)
      Assert.equal(result.multiplier, 2, "stage " .. case.stage .. " doubles raw draw " .. case.raw)
    else
      Assert.isFalse(result.critical, "stage " .. case.stage .. " misses on raw draw " .. case.raw)
      Assert.equal(result.multiplier, 1, "stage " .. case.stage .. " never multiplies raw draw " .. case.raw)
    end
    Assert.equal(result.divisor, case.divisor, "stage " .. case.stage .. " reports its native divisor")
    Assert.equal(log.calls, 1, "stage " .. case.stage .. " spends exactly one check")
    Assert.deepEqual(log.labels, { "critical_check" }, "the check draws at its labeled site")
  end
end

-- Anti-critical protection negates a successful roll after it is spent: a
-- blocked success still advances the stream exactly once, the unblocked
-- twin crits, and the sniping ability only replaces the multiplier on a
-- surviving critical.
function T.blocked_critical_rolls_still_spend_their_draw()
  local Critical =
    SessionFixture.requirePresent("libs.battle.src.gen4.Critical", "native critical checks own their roll")
  local cause = { kind = "probe", combatant = 1, activation = 1 }

  local function check(stage, raw, sniper, blockers)
    local log = { calls = 0, labels = {} }
    local stream = {}
    function stream:nextU16(label, checkCause)
      assert(type(label) == "string" and label ~= "", "the check names its draw site")
      assert(type(checkCause) == "table", "the check carries its semantic cause")
      log.calls = log.calls + 1
      log.labels[#log.labels + 1] = label
      return raw
    end
    return Critical.resolve(stage, stream, cause, sniper, blockers), log
  end

  local shielded, shieldedLog = check(0, 32, false, { antiCriticalAbility = true })
  Assert.isFalse(shielded.critical, "the ability-warded success stays non-critical")
  Assert.equal(shielded.multiplier, 1, "the ability-warded success never multiplies")
  Assert.equal(shieldedLog.calls, 1, "the ability-warded roll still spends its draw")
  Assert.deepEqual(shieldedLog.labels, { "critical_check" }, "the warded check draws at its labeled site")

  local chanted, chantedLog = check(0, 32, false, { luckyChant = true })
  Assert.isFalse(chanted.critical, "the chanted success stays non-critical")
  Assert.equal(chanted.multiplier, 1, "the chanted success never multiplies")
  Assert.equal(chantedLog.calls, 1, "the chanted roll still spends its draw")
  Assert.deepEqual(chantedLog.labels, { "critical_check" }, "the chanted check draws at its labeled site")

  local open, openLog = check(0, 32, false, nil)
  Assert.isTrue(open.critical, "the unblocked twin crits")
  Assert.equal(open.multiplier, 2, "the unblocked twin doubles")
  Assert.equal(openLog.calls, 1, "the unblocked check spends exactly one draw")

  local sniping, snipingLog = check(0, 32, true, nil)
  Assert.isTrue(sniping.critical, "the sniping twin crits")
  Assert.equal(sniping.multiplier, 3, "the sniping twin triples the surviving critical")
  Assert.equal(snipingLog.calls, 1, "the sniping check spends exactly one draw")

  local snipingShielded, snipingShieldedLog = check(0, 32, true, { antiCriticalAbility = true })
  Assert.isFalse(snipingShielded.critical, "protection still negates the sniping success")
  Assert.equal(snipingShielded.multiplier, 1, "the negated sniping success never multiplies")
  Assert.equal(snipingShieldedLog.calls, 1, "the negated sniping roll still spends its draw")
end

-- Malformed critical inputs fail before the stream moves: a non-integer
-- stage, a missing stream, a missing cause, and a misshapen blocker
-- record each spend zero draws, so a later mechanics checkpoint still
-- reads the same stream head it would have read.
function T.malformed_critical_inputs_fail_before_the_draw()
  local Critical =
    SessionFixture.requirePresent("libs.battle.src.gen4.Critical", "native critical checks own their roll")
  local cause = { kind = "probe", combatant = 1, activation = 1 }

  local function scriptedStream(log)
    local stream = {}
    function stream:nextU16(label, checkCause)
      assert(type(label) == "string" and label ~= "", "the check names its draw site")
      assert(type(checkCause) == "table", "the check carries its semantic cause")
      log.calls = log.calls + 1
      return 0
    end
    return stream
  end

  local cases = {
    { stage = 1.5, stream = true, cause = cause, blockers = nil },
    { stage = "1", stream = true, cause = cause, blockers = nil },
    { stage = 0, stream = false, cause = cause, blockers = nil },
    { stage = 0, stream = true, cause = nil, blockers = nil },
    { stage = 0, stream = true, cause = cause, blockers = { luckyChant = "yes" } },
    { stage = 0, stream = true, cause = cause, blockers = { unknownWard = true } },
  }
  for index, case in ipairs(cases) do
    local log = { calls = 0 }
    local stream = nil
    if case.stream then
      stream = scriptedStream(log)
    end
    Assert.throws(function()
      Critical.resolve(case.stage, stream, case.cause, false, case.blockers)
    end, "malformed critical input " .. index .. " fails loudly")
    Assert.equal(log.calls, 0, "malformed critical input " .. index .. " spends no draw")
  end
end

-- Shared barrier-probe combat: level 50, power 80, attack 120, defense
-- 90 runs a pre-bonus 46 and a post-bonus 48 at the fixed maximum roll,
-- so the halving checkpoint answers 25 and the unscreened strike answers
-- 48. Barrier facts arrive pre-resolved from the live side: the barrier
-- applies to the strike, the reduction names the half versus two-thirds
-- mode, and the removal flag marks strikes that shatter the barrier.
---@param overrides table<string, unknown>|nil staged spec overrides for the probe
---@return table staged damage spec carrying the barrier facts
local function screenSpec(overrides)
  local spec = {
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    rawAttack = 120,
    rawDefense = 90,
    attackStage = 0,
    defenseStage = 0,
    criticalMultiplier = 1,
    category = "physical",
    burned = false,
    guts = false,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    effectivenessFactors = { { numerator = 1, denominator = 1 } },
    targetCount = 1,
    weather = "none",
    weatherSuppressed = false,
    moveType = "normal",
    solarBeam = false,
    screenApplies = false,
    screenReduction = "half",
    removesScreens = false,
    randomPercent = 100,
  }
  for key, value in pairs(overrides or {}) do
    spec[key] = value
  end
  return spec
end

---@param traced table traced staged result under inspection
---@return string[] stage names in recorded order
local function stageNames(traced)
  local names = {}
  for _, stage in ipairs(traced.stages) do
    names[#names + 1] = stage.name
  end
  return names
end

---@param traced table traced staged result under inspection
---@param name string stage operation under lookup
---@return table the first recorded stage carrying the name
local function stageNamed(traced, name)
  for _, stage in ipairs(traced.stages) do
    if stage.name == name then
      return stage
    end
  end
  error("the trace records a " .. name .. " stage")
end

-- The physical barrier halves after base division and burn: the plain
-- strike holds 48 while the screened strike lands floor(46/2)+2 = 25.
-- A burned attacker chains floor(46/2) = 23 into floor(23/2) = 11 before
-- the bonus lands 13, so burn precedes the barrier at its own stage.
function T.reflect_halves_physical_damage_between_burn_and_spread()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local plain = Damage.calculate(screenSpec(), BattleRng.new(3))
  Assert.equal(plain.amount, 48, "the unscreened strike holds the post-bonus damage")

  local screened = Damage.calculate(screenSpec({ screenApplies = true }), BattleRng.new(3))
  Assert.equal(screened.amount, 25, "the physical barrier halves the pre-bonus damage")

  local burned = Damage.calculate(screenSpec({ screenApplies = true, burned = true }), BattleRng.new(3))
  Assert.equal(burned.amount, 13, "burn halves before the barrier halves")

  local traced = Damage.trace(screenSpec({ screenApplies = true, burned = true }), BattleRng.new(3))
  Assert.deepEqual(
    stageNames(traced),
    { "base", "burn", "screen", "bonus", "random", "stab", "effectiveness" },
    "the barrier stage sits between burn and the bonus"
  )
  local screen = stageNamed(traced, "screen")
  Assert.equal(screen.input, 23, "the barrier reads the burned intermediate")
  Assert.equal(screen.output, 11, "the barrier floors its own halving")
end

-- The special barrier halves special strikes and leaves physical strikes
-- alone: the screened special strike lands 25 while both unscreened
-- controls hold 48. Applicability is pre-resolved by the live side, so a
-- non-matching barrier arrives as not applying and changes nothing.
function T.light_screen_halves_special_damage_only()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local screened = Damage.calculate(screenSpec({ category = "special", screenApplies = true }), BattleRng.new(3))
  Assert.equal(screened.amount, 25, "the special barrier halves the pre-bonus damage")

  local specialPlain = Damage.calculate(screenSpec({ category = "special" }), BattleRng.new(3))
  Assert.equal(specialPlain.amount, 48, "the unscreened special strike holds the post-bonus damage")

  local mismatched = Damage.calculate(screenSpec({ category = "physical", screenApplies = false }), BattleRng.new(3))
  Assert.equal(mismatched.amount, 48, "a non-matching barrier leaves the physical strike alone")
end

-- Critical hits and barrier-shattering strikes skip the barrier stage
-- without disturbing the draw stream: the ordinary screened strike is
-- halved to 25 first, the critical screened strike doubles the
-- post-bonus 48 to 96, the shattering strike holds 48, and the critical
-- calculation still spends exactly its one damage draw.
function T.critical_and_screen_removing_strikes_skip_the_barrier_stage()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local ordinary = Damage.calculate(screenSpec({ screenApplies = true }), BattleRng.new(0))
  Assert.equal(ordinary.amount, 25, "the ordinary screened strike is halved first")

  local stream = BattleRng.new(0)
  -- The draw-count case runs live: clearing the pinned estimate lets the
  -- bypass spend exactly its one native damage draw (seed 0 rolls 100).
  local liveSpec = screenSpec({ screenApplies = true, criticalMultiplier = 2 })
  liveSpec.randomPercent = nil
  local critical = Damage.calculate(liveSpec, stream)
  Assert.equal(critical.amount, 96, "the critical strike doubles past the barrier")
  Assert.equal(stream:capture().calls, 1, "the bypassing strike still spends its one damage draw")

  local traced = Damage.trace(screenSpec({ screenApplies = true, criticalMultiplier = 2 }), BattleRng.new(0))
  Assert.deepEqual(
    stageNames(traced),
    { "base", "bonus", "critical", "random", "stab", "effectiveness" },
    "the critical trace records no barrier stage"
  )

  local shattering =
    Damage.calculate(screenSpec({ screenApplies = true, removesScreens = true }), BattleRng.new(3))
  Assert.equal(shattering.amount, 48, "the shattering strike ignores the raised barrier")
  local shattered = Damage.trace(screenSpec({ screenApplies = true, removesScreens = true }), BattleRng.new(3))
  Assert.deepEqual(
    stageNames(shattered),
    { "base", "bonus", "random", "stab", "effectiveness" },
    "the shattering trace records no barrier stage"
  )
end

-- The paired-battle barrier reduction is an explicit fact, never inferred
-- from the spread target count: two-thirds lands floor(46*2/3) = 30
-- before the bonus for 32, while the half mode under two targets chains
-- floor(46/2) = 23 into the spread floor(23*3072/4096) = 17 for 19, and
-- the two-thirds mode under two targets chains 30 into
-- floor(30*3072/4096) = 22 for 24. Spread always follows the barrier.
function T.doubles_barrier_reduction_uses_two_thirds_before_spread()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local paired = Damage.calculate(
    screenSpec({ screenApplies = true, screenReduction = "two_thirds" }),
    BattleRng.new(3)
  )
  Assert.equal(paired.amount, 32, "the paired-battle barrier keeps two thirds")

  local singleSpread = Damage.calculate(
    screenSpec({ screenApplies = true, screenReduction = "half", targetCount = 2 }),
    BattleRng.new(3)
  )
  Assert.equal(singleSpread.amount, 19, "the half barrier still halves under two targets")

  local pairedSpread = Damage.calculate(
    screenSpec({ screenApplies = true, screenReduction = "two_thirds", targetCount = 2 }),
    BattleRng.new(3)
  )
  Assert.equal(pairedSpread.amount, 24, "spread follows the two-thirds barrier at its own stage")

  local traced = Damage.trace(
    screenSpec({ screenApplies = true, screenReduction = "two_thirds", targetCount = 2 }),
    BattleRng.new(3)
  )
  Assert.deepEqual(
    stageNames(traced),
    { "base", "screen", "spread", "bonus", "random", "stab", "effectiveness" },
    "spread follows the barrier in trace order"
  )
  local screen = stageNamed(traced, "screen")
  Assert.equal(screen.input, 46, "the barrier reads the pre-spread damage")
  Assert.equal(screen.output, 30, "the barrier keeps two thirds before spread")
  local spread = stageNamed(traced, "spread")
  Assert.equal(spread.input, 30, "spread reads the screened intermediate")
  Assert.equal(spread.output, 22, "spread truncates on the screened intermediate")
end

-- The charging grass strike halves under rain, sand, and hail only while
-- the sky answers: unsuppressed bad weather lands floor(46/2)+2 = 25
-- while suppression holds 48, and sun and clear skies hold 48 either
-- way. The penalty shares the suppression guard with the other sky
-- modifiers instead of sitting outside it.
function T.adverse_weather_grass_penalty_shares_the_suppression_guard()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  ---@param weather string active field weather identity under the probe
  ---@param weatherSuppressed boolean whether a live ability stills the sky
  ---@return integer damage at the fixed maximum roll
  local function grassStrike(weather, weatherSuppressed)
    return Damage.calculate(
      screenSpec({
        category = "special",
        moveType = "grass",
        weather = weather,
        weatherSuppressed = weatherSuppressed,
        solarBeam = true,
      }),
      BattleRng.new(11)
    ).amount
  end

  for _, weather in ipairs({ "rain", "sand", "hail" }) do
    Assert.equal(grassStrike(weather, false), 25, "the charging grass strike halves under " .. weather)
    Assert.equal(grassStrike(weather, true), 48, "the stilled sky spares the charging grass strike")
  end
  Assert.equal(grassStrike("sun", false), 48, "the charging grass strike holds under sun")
  Assert.equal(grassStrike("sun", true), 48, "suppression changes nothing under sun")
  Assert.equal(grassStrike("none", false), 48, "the charging grass strike holds under clear skies")

  local traced = Damage.trace(
    screenSpec({ category = "special", moveType = "grass", weather = "rain", solarBeam = true }),
    BattleRng.new(11)
  )
  Assert.deepEqual(
    stageNames(traced),
    { "base", "solarbeam", "bonus", "random", "stab", "effectiveness" },
    "the grass penalty sits with the sky stages before the bonus"
  )
end

-- The full pre-bonus order truncates stage by stage: base 46, burn 23,
-- barrier 11, spread floor(11*3072/4096) = 8, rain on fire floor(8/2) =
-- 4, bonus 6, and the roll, bonus-type, and effectiveness stages follow.
function T.trace_orders_barrier_after_burn_and_before_spread()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local traced = Damage.trace(
    screenSpec({
      burned = true,
      screenApplies = true,
      targetCount = 2,
      weather = "rain",
      moveType = "fire",
    }),
    BattleRng.new(11)
  )
  Assert.equal(traced.amount, 6, "every pre-bonus stage truncates in order")
  Assert.deepEqual(
    stageNames(traced),
    { "base", "burn", "screen", "spread", "weather", "bonus", "random", "stab", "effectiveness" },
    "traced stages follow base, burn, barrier, spread, sky, bonus, roll, bonus-type, effectiveness"
  )
end

-- Barrier facts validate before the damage draw: an unknown reduction
-- mode and a missing reduction mode both fail loudly without spending
-- the roll, so malformed live facts never silently halve or pass.
function T.malformed_barrier_facts_fail_before_the_damage_draw()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local cases = {
    screenSpec({ screenApplies = true, screenReduction = "sideways" }),
    (function()
      local spec = screenSpec({ screenApplies = true })
      spec.screenReduction = nil
      return spec
    end)(),
  }
  for index, spec in ipairs(cases) do
    local stream = BattleRng.new(0)
    Assert.throws(function()
      Damage.calculate(spec, stream)
    end, "malformed barrier facts " .. index .. " fail loudly")
    Assert.equal(stream:capture().calls, 0, "malformed barrier facts " .. index .. " spend no draw")
  end
end

-- Fixed damage answers from its amount alone: the draw-free path never
-- consults the battle stream, so callers without a live stream still get
-- the exact amount with neutral classification, while non-positive
-- amounts still fail loudly.
function T.fixed_damage_answers_without_a_live_stream()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local streamless = Damage.fixed({ amount = 40 })
  Assert.equal(streamless.amount, 40, "fixed amounts pass through without a stream")
  Assert.isFalse(streamless.critical, "fixed damage never crits")
  Assert.deepEqual(
    streamless.effectiveness,
    { numerator = 1, denominator = 1 },
    "fixed damage stays neutrally classified"
  )

  Assert.throws(function()
    Damage.fixed({ amount = 0 })
  end, "non-positive fixed amounts fail loudly")

  local stream = BattleRng.new(9)
  local streamed = Damage.fixed({ amount = 40 }, stream)
  Assert.equal(streamed.amount, 40, "fixed amounts pass through unmodified")
  Assert.equal(stream:capture().calls, 0, "fixed damage draws nothing from a supplied stream")
end

return { tests = T }
