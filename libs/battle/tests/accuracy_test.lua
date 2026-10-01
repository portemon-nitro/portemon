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

return { tests = T }
