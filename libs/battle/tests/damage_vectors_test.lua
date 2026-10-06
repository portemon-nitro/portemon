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
  Assert.equal(plain.amount, 60, "the recorded zero draw rolls the 85 minimum")
  Assert.equal(plainStream:capture().calls, 1, "the roll consumes exactly one labeled draw")

  local tracedStream = BattleRng.new(0)
  local traced = Damage.trace(spec, tracedStream)
  Assert.equal(traced.amount, 60, "traced calculation matches the untraced result")
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

  local stream = BattleRng.new(9)
  Assert.equal(Damage.fixed({ amount = 40 }, stream).amount, 40, "fixed amounts pass through unmodified")
  Assert.equal(stream:capture().calls, 0, "fixed damage draws nothing from the stream")
end

return { tests = T }
