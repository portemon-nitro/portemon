-- Source-shaped doubles targeting: selected policies resolve to ordered
-- target sets at the sample point, departed selections retarget through
-- the native policy instead of fizzling, redirection owns its own entry
-- point, and spread moves apply the exact quarter reduction only while
-- more than one target stands.
--
-- Vector method: field layouts are hand-specified plain data (positions 0/2
-- near side, 1/3 far side); the spread literals reuse the pinned base-48
-- vector (two targets reduce 48 to floor(48*3072/4096) = 36).

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table target policy owner under test
local function targetingOwner()
  local Targeting =
    SessionFixture.requirePresent("libs.battle.src.gen4.Targeting", "ordered target policies own resolution")
  Assert.isTrue(type(Targeting.validateSelection) == "function", "target policies own selection validation")
  Assert.isTrue(type(Targeting.resolve) == "function", "target policies own ordered resolution")
  Assert.isTrue(type(Targeting.redirect) == "function", "target policies own redirection")
  return Targeting
end

---@param occupant integer|nil combatant holding the slot, nil once departed
---@return table field slot in plain data
local function slot(id, side, occupant)
  local entry = { id = id, side = side }
  if occupant ~= nil then
    entry.occupant = { combatant = occupant, activation = 1, active = true }
  end
  return entry
end

---@return table doubles field with near positions 0/2 and far positions 1/3
local function doublesField()
  return {
    positions = {
      slot(0, 0, 1),
      slot(1, 1, 2),
      slot(2, 0, 3),
      slot(3, 1, 4),
    },
    sides = { { id = 0, positions = { 0, 2 } }, { id = 1, positions = { 1, 3 } } },
  }
end

---@param resolved table ordered resolution result under test
---@return integer[] position identities in resolution order
local function orderedPositions(resolved)
  Assert.isTrue(type(resolved.targets) == "table", "resolutions publish their ordered target set")
  local ids = {}
  for index, ref in ipairs(resolved.targets) do
    Assert.equal(ref.kind, "position", "targets keep positional identity")
    ids[index] = ref.position
  end
  return ids
end

function T.spread_and_side_policies_resolve_in_source_order()
  local Targeting = targetingOwner()
  local field = doublesField()

  local foes = Targeting.resolve({ policy = "both_foes", user = { kind = "position", position = 0 } }, field)
  Assert.deepEqual(orderedPositions(foes), { 1, 3 }, "both foes resolve far side in ascending slot order")

  local others = Targeting.resolve({ policy = "all_others", user = { kind = "position", position = 0 } }, field)
  Assert.deepEqual(orderedPositions(others), { 1, 2, 3 }, "all others resolve every occupied slot in slot order")

  local ally = Targeting.resolve({ policy = "ally", user = { kind = "position", position = 0 } }, field)
  Assert.deepEqual(orderedPositions(ally), { 2 }, "ally policy resolves the live partner slot")
end

function T.departed_selections_retarget_instead_of_fizzling()
  local Targeting = targetingOwner()
  local field = doublesField()
  field.positions[2].occupant = nil

  local retargeted = Targeting.resolve(
    {
      policy = "selected_foe",
      user = { kind = "position", position = 0 },
      selected = { kind = "position", position = 1 },
    },
    field
  )
  Assert.deepEqual(orderedPositions(retargeted), { 3 }, "departed selections fall through to the live foe")

  local redirected = Targeting.redirect(
    {
      policy = "selected_foe",
      user = { kind = "position", position = 0 },
      selected = { kind = "position", position = 3 },
      redirectTo = { kind = "position", position = 1 },
    },
    doublesField()
  )
  Assert.deepEqual(orderedPositions(redirected), { 1 }, "redirection owns its own target entry point")
end

function T.selections_validate_before_resolution()
  local Targeting = targetingOwner()
  local field = doublesField()

  Assert.isTrue(
    Targeting.validateSelection({ policy = "selected_foe", selected = { kind = "position", position = 1 } }),
    "live selections validate"
  )
  Assert.throws(function()
    Targeting.validateSelection({ policy = "selected_foe", selected = { kind = "position", position = 9 } })
  end, "unknown slots fail before resolution")
  Assert.throws(function()
    Targeting.resolve({ policy = "selected_foe", user = { kind = "position", position = 0 } }, field)
  end, "missing selections never resolve silently")
end

function T.spread_reduction_follows_the_sampled_target_count()
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  ---@param count integer eligible targets sampled at the native point
  ---@return integer calculated amount for the pinned base-48 vector
  local function spreadAmount(count)
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
      category = "physical",
      burned = false,
      guts = false,
      stab = { numerator = 1, denominator = 1 },
      effectiveness = { numerator = 1, denominator = 1 },
      effectivenessFactors = { { numerator = 1, denominator = 1 } },
      targetCount = count,
      weather = "none",
      weatherSuppressed = false,
      moveType = "normal",
      solarBeam = false,
      randomPercent = 100,
    }, BattleRng.new(5)).amount
  end

  Assert.equal(spreadAmount(1), 48, "a lone remaining target takes the full amount")
  Assert.equal(spreadAmount(2), 36, "two sampled targets spread the pre-bonus damage before the bonus addition")
end

return { tests = T }
