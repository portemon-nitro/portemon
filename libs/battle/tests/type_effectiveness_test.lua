-- Custom charts compose through the same arithmetic without changing vanilla
-- semantics: declared custom relations resolve exactly, vanilla pairs stay
-- identical across sessions, unknown types and undeclared pairs fail before
-- execution, and mystery/typeless plus temporary type loss keep their
-- pinned neutral behavior.
--
-- Vector method: every directed pair in the shared chart fixture is a fixed
-- literal (custom sound into water 2/1, water into sound 1/2, vanilla
-- ground into flying 0/1, custom ground into flying 1/1 because airborne
-- grounding is a separate checkpoint); assertions compare those literals,
-- never production output.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table chart resolver owner under test
local function effectivenessOwner()
  local Effectiveness = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TypeEffectiveness",
    "semantic charts own effectiveness resolution"
  )
  Assert.isTrue(type(Effectiveness.resolve) == "function", "charts own directed resolution")
  Assert.isTrue(type(Effectiveness.stab) == "function", "charts own STAB eligibility")
  return Effectiveness
end

function T.custom_relations_apply_only_in_custom_sessions()
  local Effectiveness = effectivenessOwner()
  local CombatFixture = require("libs.battle.tests.combat_fixture")

  local vanilla = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET)
  local custom = CombatFixture.chart(CombatFixture.makeCustom(), CombatFixture.CUSTOM_RULESET)

  Assert.deepEqual(
    (function()
      local resolved = Effectiveness.resolve(custom, "sound", { "water" }, {})
      return { numerator = resolved.numerator, denominator = resolved.denominator }
    end)(),
    { numerator = 2, denominator = 1 },
    "declared custom relations resolve exactly"
  )
  Assert.deepEqual(
    (function()
      local resolved = Effectiveness.resolve(custom, "water", { "sound" }, {})
      return { numerator = resolved.numerator, denominator = resolved.denominator }
    end)(),
    { numerator = 1, denominator = 2 },
    "declared custom resistances resolve exactly"
  )

  for _, pair in ipairs({ { "fire", "water" }, { "water", "fire" }, { "normal", "fire" } }) do
    local first = Effectiveness.resolve(vanilla, pair[1], { pair[2] }, {})
    local second = Effectiveness.resolve(custom, pair[1], { pair[2] }, {})
    Assert.deepEqual(
      { numerator = second.numerator, denominator = second.denominator },
      { numerator = first.numerator, denominator = first.denominator },
      "vanilla pairs stay identical in custom sessions"
    )
  end
  local vanillaFire = Effectiveness.resolve(vanilla, "fire", { "water" }, {})
  Assert.deepEqual(
    { numerator = vanillaFire.numerator, denominator = vanillaFire.denominator },
    { numerator = 1, denominator = 2 },
    "vanilla fire into water stays resisted"
  )
end

function T.unknown_types_and_pairs_fail_before_execution()
  local Effectiveness = effectivenessOwner()
  local CombatFixture = require("libs.battle.tests.combat_fixture")

  local vanilla = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET)
  Assert.throws(function()
    Effectiveness.resolve(vanilla, "sound", { "water" }, {})
  end, "custom types fail outside their own session")
  Assert.throws(function()
    Effectiveness.resolve(vanilla, "fire", { "sound" }, {})
  end, "custom defenders fail outside their own session")

  local custom = CombatFixture.chart(CombatFixture.makeCustom(), CombatFixture.CUSTOM_RULESET)
  Assert.throws(function()
    Effectiveness.resolve(custom, "static", { "water" }, {})
  end, "undeclared attacking types fail before execution")
end

function T.grounding_stays_a_separate_checkpoint_from_chart_immunity()
  local Effectiveness = effectivenessOwner()
  local CombatFixture = require("libs.battle.tests.combat_fixture")

  local vanilla = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET)
  local custom = CombatFixture.chart(CombatFixture.makeCustom(), CombatFixture.CUSTOM_RULESET)

  local chartImmune = Effectiveness.resolve(vanilla, "ground", { "flying" }, {})
  Assert.isTrue(chartImmune.immune, "vanilla ground into flying is immune")
  Assert.isTrue(type(chartImmune.reason) == "string" and chartImmune.reason ~= "", "chart immunity names its reason")

  -- The custom chart deliberately declares ground into flying neutral, so an
  -- airborne defender there isolates the grounding checkpoint.
  local grounded = Effectiveness.resolve(custom, "ground", { "flying" }, { airborne = true })
  Assert.isTrue(grounded.immune, "airborne defenders stay immune without chart immunity")
  Assert.isTrue(
    type(grounded.reason) == "string" and grounded.reason ~= "",
    "grounding names its own reason"
  )
  Assert.isTrue(grounded.reason ~= chartImmune.reason, "grounding never reuses the chart immunity reason")

  local landed = Effectiveness.resolve(custom, "ground", { "flying" }, { airborne = false })
  Assert.isFalse(landed.immune, "landed defenders take the declared neutral relation")
  Assert.deepEqual(
    { numerator = landed.numerator, denominator = landed.denominator },
    { numerator = 1, denominator = 1 },
    "landed defenders take the declared neutral multiplier"
  )
end

function T.mystery_typeless_and_lost_types_stay_neutral()
  local Effectiveness = effectivenessOwner()
  local CombatFixture = require("libs.battle.tests.combat_fixture")

  local vanilla = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET)

  local mystery = Effectiveness.resolve(vanilla, "mystery", { "fire" }, {})
  Assert.deepEqual(
    { numerator = mystery.numerator, denominator = mystery.denominator },
    { numerator = 1, denominator = 1 },
    "mystery attacks stay neutral"
  )
  Assert.isFalse(mystery.immune, "mystery attacks never immunize")

  local typeless = Effectiveness.resolve(vanilla, "typeless", { "fire", "water" }, { typeless = true })
  Assert.deepEqual(
    { numerator = typeless.numerator, denominator = typeless.denominator },
    { numerator = 1, denominator = 1 },
    "typeless attacks multiply to neutral across both types"
  )

  -- Temporary type loss defends as no type at all: water loses its 2/1 edge.
  local lost = Effectiveness.resolve(vanilla, "water", {}, {})
  Assert.deepEqual(
    { numerator = lost.numerator, denominator = lost.denominator },
    { numerator = 1, denominator = 1 },
    "type loss removes the multiplier instead of keeping it"
  )
end

function T.stab_follows_attacker_types_only()
  local Effectiveness = effectivenessOwner()

  Assert.isTrue(Effectiveness.stab("fire", { "fire", "flying" }), "matching primary types grant STAB")
  Assert.isTrue(Effectiveness.stab("flying", { "fire", "flying" }), "matching secondary types grant STAB")
  Assert.isFalse(Effectiveness.stab("water", { "fire", "flying" }), "unlisted types grant no STAB")
  Assert.isFalse(Effectiveness.stab("typeless", { "typeless" }), "typeless attacks grant no STAB")
end

return { tests = T }
