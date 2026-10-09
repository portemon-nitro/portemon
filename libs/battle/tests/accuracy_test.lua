-- Distinct hit-prevention reasons: a rolled miss, an intact protection, an
-- unreachable semi-invulnerable target, and immunities each report their
-- own kind and reason. Accuracy 100 still rolls its check, moves that skip
-- the ordinary roll never skip unrelated prevention, and every branch
-- consumes its exact draw count.
--
-- Vector method: thresholds are hand-specified as floor(accuracy*65536/100)
-- against recorded generator draws (seed 1 opens with draw 16838, seed
-- 12345 opens with draw 54236); accuracy 25 thresholds at 16384 so draw
-- 16838 misses, while accuracy 100 thresholds at 65536 so every draw hits.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table accuracy owner under test
local function accuracyOwner()
  local Accuracy =
    SessionFixture.requirePresent("libs.battle.src.gen4.Accuracy", "accuracy and hit prevention own their checks")
  Assert.isTrue(type(Accuracy.resolve) == "function", "hit prevention owns its resolution")
  return Accuracy
end

---@return table battle stream owner under test
local function streamOwner()
  return SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
end

---@param position integer field slot under test
---@return table position reference in plain data
local function target(position)
  return { kind = "position", position = position }
end

---@return table semantic cause carried with every draw
local function cause()
  return { kind = "strike", combatant = 1, activation = 1 }
end

function T.rolled_checks_report_misses_with_exact_draw_counts()
  local Accuracy = accuracyOwner()
  local BattleRng = streamOwner()

  local missed = BattleRng.new(1)
  local miss = Accuracy.resolve({ accuracy = 25, target = target(1), cause = cause() }, missed)
  Assert.equal(miss.kind, "miss", "draw 16838 clears the accuracy-25 threshold of 16384")
  Assert.isTrue(type(miss.reason) == "string" and miss.reason ~= "", "misses name their roll reason")
  Assert.equal(missed:capture().calls, 1, "rolled checks consume exactly one labeled draw")

  local hitStream = BattleRng.new(12345)
  local hit = Accuracy.resolve({ accuracy = 100, target = target(1), cause = cause() }, hitStream)
  Assert.equal(hit.kind, "hit", "accuracy 100 hits even on the recorded draw 54236")
  Assert.equal(hitStream:capture().calls, 1, "full accuracy still rolls its check")
end

function T.unrelated_prevention_blocks_without_a_roll()
  local Accuracy = accuracyOwner()
  local BattleRng = streamOwner()

  local guarded = BattleRng.new(1)
  local protection = Accuracy.resolve(
    { accuracy = 25, target = target(1), cause = cause(), protected = true },
    guarded
  )
  Assert.equal(protection.kind, "protected", "intact protection reports its own kind")
  Assert.isTrue(type(protection.reason) == "string" and protection.reason ~= "", "protection names its reason")
  Assert.equal(guarded:capture().calls, 0, "protection is decided before the roll")

  local airborne = BattleRng.new(1)
  local unreachable = Accuracy.resolve(
    { accuracy = 100, target = target(1), cause = cause(), semiInvulnerable = true },
    airborne
  )
  Assert.equal(unreachable.kind, "unreachable", "semi-invulnerable targets report their own kind")
  Assert.isTrue(
    type(unreachable.reason) == "string" and unreachable.reason ~= "",
    "unreachable targets name their reason"
  )
  Assert.equal(airborne:capture().calls, 0, "unreachable targets are decided before the roll")
end

function T.skipped_rolls_never_skip_unrelated_prevention()
  local Accuracy = accuracyOwner()
  local BattleRng = streamOwner()

  local free = BattleRng.new(1)
  local freeHit = Accuracy.resolve({ target = target(1), cause = cause(), skipCheck = true }, free)
  Assert.equal(freeHit.kind, "hit", "skipped rolls hit without consulting the stream")
  Assert.equal(free:capture().calls, 0, "skipped rolls draw nothing")

  local guarded = BattleRng.new(1)
  local protection = Accuracy.resolve(
    { target = target(1), cause = cause(), skipCheck = true, protected = true },
    guarded
  )
  Assert.equal(protection.kind, "protected", "skipped rolls never bypass protection")
  Assert.equal(guarded:capture().calls, 0, "blocked skipped rolls still draw nothing")

  local airborne = BattleRng.new(1)
  local unreachable = Accuracy.resolve(
    { target = target(1), cause = cause(), skipCheck = true, semiInvulnerable = true },
    airborne
  )
  Assert.equal(unreachable.kind, "unreachable", "skipped rolls never reach semi-invulnerable targets")

  local reasons = { freeHit.reason, protection.reason, unreachable.reason }
  for index = 1, #reasons do
    Assert.isTrue(type(reasons[index]) == "string" and reasons[index] ~= "", "every outcome names its reason")
    for other = index + 1, #reasons do
      Assert.isTrue(reasons[index] ~= reasons[other], "hit, protection, and unreachable never share a reason")
    end
  end
end

-- Combined accuracy law: the signed stages merge into one effective stage
-- (accuracy minus evasion), clamp to [-6, +6], and reshape the integer
-- percentage through the literal stage entry. +1 accuracy against -1
-- evasion is effective +2 (166/100): base 30 becomes exactly 49, so roll
-- 50 misses while roll 49 still hits. +6 against -6 clamps at +6 (3/1),
-- never 9x: base 30 becomes exactly 90, so roll 95 misses while roll 90
-- hits. -1 against +1 is effective -2 (60/100): base 50 becomes exactly
-- 30, so roll 31 misses while roll 30 hits. Every rolled check draws
-- exactly once from the labeled accuracy site.
---@param draws integer[] canned raw battle-stream draws in consumption order
---@return table stub stream replaying the canned draws with its label log
local function cannedStream(draws)
  local calls = 0
  local labels = {}
  local stream = {}
  function stream:nextU16(label, cause)
    calls = calls + 1
    assert(type(label) == "string" and label ~= "", "rolled checks name their draw site")
    assert(type(cause) == "table", "rolled checks carry their semantic cause")
    labels[#labels + 1] = label
    assert(calls <= #draws, "rolled checks draw exactly once")
    return draws[calls]
  end
  function stream:calls()
    return calls
  end
  function stream:drawLabels()
    local out = {}
    for index, label in ipairs(labels) do
      out[index] = label
    end
    return out
  end
  return stream
end

function T.combined_stage_vectors_follow_the_literal_stage_table()
  local Accuracy = accuracyOwner()

  local plusTwo = { accuracy = 30, target = target(1), cause = cause(), accuracyStage = 1, evasionStage = -1 }
  local miss = Accuracy.resolve(plusTwo, cannedStream({ 149 }))
  Assert.equal(miss.kind, "miss", "effective +2 turns base 30 into 49, so roll 50 misses")
  local edge = Accuracy.resolve(plusTwo, cannedStream({ 148 }))
  Assert.equal(edge.kind, "hit", "roll 49 meets the combined chance exactly")

  local clamped = { accuracy = 30, target = target(1), cause = cause(), accuracyStage = 6, evasionStage = -6 }
  local capped = Accuracy.resolve(clamped, cannedStream({ 194 }))
  Assert.equal(capped.kind, "miss", "effective stages clamp at +6, so roll 95 misses a base-30 chance")
  local capEdge = Accuracy.resolve(clamped, cannedStream({ 189 }))
  Assert.equal(capEdge.kind, "hit", "roll 90 meets the clamped chance exactly")

  local negative = { accuracy = 50, target = target(1), cause = cause(), accuracyStage = -1, evasionStage = 1 }
  local low = Accuracy.resolve(negative, cannedStream({ 130 }))
  Assert.equal(low.kind, "miss", "effective -2 turns base 50 into 30, so roll 31 misses")
  local lowEdge = Accuracy.resolve(negative, cannedStream({ 129 }))
  Assert.equal(lowEdge.kind, "hit", "roll 30 meets the reduced chance exactly")
end

-- Modulo hit law: one raw draw becomes roll (draw % 100) + 1 against the
-- final percentage. Accuracy 99 with draw 99 rolls 100 and misses, while
-- draw 98 rolls 99 and hits and draw 0 rolls 1 and always hits. Full
-- accuracy still rolls its single check but cannot miss: even the maximum
-- raw draw rolls at most 100.
function T.modulo_roll_compares_one_to_one_hundred()
  local Accuracy = accuracyOwner()

  local query = { accuracy = 99, target = target(1), cause = cause() }
  local miss = Accuracy.resolve(query, cannedStream({ 99 }))
  Assert.equal(miss.kind, "miss", "draw 99 rolls 100 against a final chance of 99")
  local edge = Accuracy.resolve(query, cannedStream({ 98 }))
  Assert.equal(edge.kind, "hit", "draw 98 rolls 99 and meets the chance exactly")
  local lowest = Accuracy.resolve(query, cannedStream({ 0 }))
  Assert.equal(lowest.kind, "hit", "draw 0 rolls 1 and always connects")

  local full = cannedStream({ 65535 })
  local fullHit = Accuracy.resolve({ accuracy = 100, target = target(1), cause = cause() }, full)
  Assert.equal(fullHit.kind, "hit", "full accuracy survives even the maximum raw draw")
  Assert.equal(full:calls(), 1, "the ordinary check draws exactly once")
  Assert.deepEqual(full:drawLabels(), { "accuracy_check" }, "the ordinary check draws at its labeled site")
end

function T.type_and_ability_immunities_report_distinct_reasons()
  local Effectiveness = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TypeEffectiveness",
    "semantic charts own immunity resolution"
  )
  Assert.isTrue(type(Effectiveness.resolve) == "function", "immunity resolution owns its resolver")
  local CombatFixture = require("libs.battle.tests.combat_fixture")

  local chart = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET)

  -- Ground into flying is the declared chart immunity pair of the fixture.
  local chartImmune = Effectiveness.resolve(chart, "ground", { "flying" }, {})
  Assert.equal(chartImmune.numerator, 0, "chart immunities resolve to zero")
  Assert.equal(chartImmune.denominator, 1, "chart immunities keep the unit denominator")
  Assert.isTrue(chartImmune.immune, "chart immunities flag their outcome")
  Assert.isTrue(type(chartImmune.reason) == "string" and chartImmune.reason ~= "", "chart immunities name their reason")

  local abilityImmune = Effectiveness.resolve(chart, "water", { "fire" }, { abilityImmunity = true })
  Assert.isTrue(abilityImmune.immune, "ability immunities flag their outcome")
  Assert.isTrue(
    type(abilityImmune.reason) == "string" and abilityImmune.reason ~= "",
    "ability immunities name their reason"
  )
  Assert.isTrue(
    abilityImmune.reason ~= chartImmune.reason,
    "ability and chart immunities never share a reason"
  )
  Assert.deepEqual(
    { numerator = abilityImmune.numerator, denominator = abilityImmune.denominator },
    { numerator = 2, denominator = 1 },
    "ability immunity suppresses the resolved water-into-fire multiplier without rewriting it"
  )
end

-- Literal hit-chance table: accuracy and evasion stages resolve through
-- the exact native 13-entry lookup, not derived thirds. Every clamped
-- signed stage maps to its literal numerator/denominator pair, and both
-- stage keys share the one canonical ratio owner.
function T.stage_table_matches_the_literal_native_entries()
  local StatStages = SessionFixture.requirePresent(
    "libs.battle.src.gen4.StatStages",
    "source stage clamps own stat ratios"
  )
  local expected = {
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
  for stage = -6, 6 do
    Assert.deepEqual(
      StatStages.multiplier(stage, "accuracy"),
      expected[stage],
      "accuracy stage " .. stage .. " keeps its literal native ratio"
    )
    Assert.deepEqual(
      StatStages.multiplier(stage, "evasion"),
      expected[stage],
      "evasion stage " .. stage .. " keeps its literal native ratio"
    )
  end
end

-- Native truncation counterexamples: the literal percentages floor before
-- the hit draw. Base 90 at +1 becomes 119 (not 120), base 60 at +2
-- becomes 99 (not 100), and base 100 at -5 becomes 36 (not 37). Chances
-- at or above 100 always hit, so the +1 vector is proved through the
-- staged floor while the +2 and -5 vectors also separate a meeting roll
-- from a missing one; base 75 at +1 floors to 99 (not 100) and splits
-- the top roll exactly.
function T.truncation_vectors_match_the_literal_table()
  local Accuracy = accuracyOwner()
  local StatStages = SessionFixture.requirePresent(
    "libs.battle.src.gen4.StatStages",
    "source stage clamps own stat ratios"
  )

  Assert.equal(StatStages.effective(90, 1, "accuracy"), 119, "base 90 at +1 floors to 119")
  Assert.equal(StatStages.effective(60, 2, "accuracy"), 99, "base 60 at +2 floors to 99")
  Assert.equal(StatStages.effective(100, -5, "accuracy"), 36, "base 100 at -5 floors to 36")

  local plusOne = { accuracy = 75, target = target(1), cause = cause(), accuracyStage = 1 }
  Assert.equal(Accuracy.resolve(plusOne, cannedStream({ 98 })).kind, "hit", "draw 98 rolls 99 and meets 75 at +1")
  Assert.equal(Accuracy.resolve(plusOne, cannedStream({ 99 })).kind, "miss", "draw 99 rolls 100 past 75 at +1")

  local plusTwo = { accuracy = 60, target = target(1), cause = cause(), accuracyStage = 2 }
  Assert.equal(Accuracy.resolve(plusTwo, cannedStream({ 98 })).kind, "hit", "draw 98 rolls 99 and meets 60 at +2")
  Assert.equal(Accuracy.resolve(plusTwo, cannedStream({ 99 })).kind, "miss", "draw 99 rolls 100 past 60 at +2")

  local minusFive = { accuracy = 100, target = target(1), cause = cause(), accuracyStage = -5 }
  Assert.equal(Accuracy.resolve(minusFive, cannedStream({ 35 })).kind, "hit", "draw 35 rolls 36 and meets 100 at -5")
  Assert.equal(Accuracy.resolve(minusFive, cannedStream({ 36 })).kind, "miss", "draw 36 rolls 37 past 100 at -5")
end

-- Modded strikes compose through the same staged arithmetic: a
-- beyond-retail power with a nonstandard finite bonus resolves
-- deterministically at a pinned roll, an undeclared attacking type still
-- fails through the chart owner, and a zero denominator fails before any
-- draw instead of dividing.
function T.modded_strikes_compose_through_the_staged_arithmetic()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local Effectiveness = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TypeEffectiveness",
    "semantic charts own immunity resolution"
  )
  local CombatFixture = require("libs.battle.tests.combat_fixture")

  ---@param bonus table<string, integer> exact same-type bonus under the strike
  ---@return table<string, unknown> staged damage spec carrying the modded facts
  local function strike(bonus)
    return {
      level = 50,
      power = 400,
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
      stab = bonus,
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      targetCount = 1,
      weather = "none",
      weatherSuppressed = false,
      moveType = "sound",
      solarBeam = false,
      randomPercent = 100,
    }
  end

  -- floor(2*50/5+2) = 22; 22*400*120 = 1056000; floor(/90) = 11733;
  -- floor(/50) = 234; +2 = 236; the pinned roll keeps 236;
  -- floor(236*5/4) = 295.
  local estimated = BattleRng.new(7)
  local dealt = Damage.calculate(strike({ numerator = 5, denominator = 4 }), estimated)
  Assert.equal(dealt.amount, 295, "beyond-retail power scales through the staged truncations")
  Assert.equal(estimated:capture().calls, 0, "pinned rolls estimate without drawing")

  local chart = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET)
  Assert.throws(function()
    Effectiveness.resolve(chart, "plasma", { "fire" }, {})
  end, "undeclared attacking types fail through the chart owner")

  local doomed = BattleRng.new(7)
  Assert.throws(function()
    Damage.calculate(strike({ numerator = 1, denominator = 0 }), doomed)
  end, "zero denominators fail before division")
  Assert.equal(doomed:capture().calls, 0, "zero denominators spend no draw")
end

return { tests = T }
