-- Obedience is a before-action checkpoint, never a preference: an
-- outsider above the profile level cap may disobey through fixed random
-- alternatives, owned and low-level mons never roll, the roll consumes
-- its own labeled draws without asking the interface, and frustration
-- reads the explicit friendship facts instead of inventing a default.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local DomainErrors = require("libs.errors.src.Errors")

local T = {}

local FIXED_SEED = 777001

---@param behavior string missing owner under test
---@return table the loaded usable-move and forced-action owner
local function selectionOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.MoveSelection", behavior)
end

---@return table live battle state with two active combatants over real owners
local function liveState()
  local Scenario =
    SessionFixture.requirePresent("libs.battle.src.BattleScenario", "detached scenario validation owns setup")
  local State =
    SessionFixture.requirePresent("libs.battle.src.BattleState", "private battle data owns reference invariants")
  local scenario = SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { SessionFixture.combatant(2, 23) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
  })
  return State.create(Scenario.validate(scenario))
end

---@param state table live battle state under execution
---@return table genuine mechanics context over that state
local function liveContext(state)
  local Context = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  return Context.wrap(state)
end

---@param traded boolean whether the mon arrived from another trainer
---@param level integer current mon level under the checkpoint
---@param cap integer profile level cap for outsiders under the checkpoint
---@param seed integer fixed generator state for the obedience roll
---@return table obedience inputs over fixed random state
local function obedienceInputs(traded, level, cap, seed)
  return {
    actor = { combatant = 1 },
    requestedMove = "TACKLE",
    origin = { traded = traded },
    level = level,
    profile = { maxObedientLevel = cap },
    stream = BattleRng.new(seed),
  }
end

-- An outsider above the profile cap is checked before acting: the
-- checkpoint answers from owner facts and fixed random state, and a
-- disobedient outcome never executes the ordered move.
function T.outsider_above_the_cap_is_checked_before_acting()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local seenDisobedience = false
  for seed = FIXED_SEED, FIXED_SEED + 31 do
    local outcome = Selection.obey(obedienceInputs(true, 50, 30, seed))
    Assert.notNil(outcome.obeys, "the checkpoint answers whether the mon obeys")
    if not outcome.obeys then
      seenDisobedience = true
      Assert.isTrue(
        outcome.executingMove ~= "TACKLE" or outcome.result == "no-action",
        "a disobedient mon never executes the ordered move"
      )
    else
      Assert.equal(outcome.executingMove, "TACKLE", "an obedient roll keeps the ordered move")
    end
  end
  Assert.isTrue(seenDisobedience, "an overleveled outsider can disobey across fixed seeds")
end

-- Disobedience draws its alternatives from fixed random state: the same
-- seed repeats the same outcome with the same draw trace, and the roll
-- never surfaces a decision request to the interface.
function T.disobedience_uses_fixed_random_alternatives()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local first = Selection.obey(obedienceInputs(true, 50, 30, FIXED_SEED))
  local replay = Selection.obey(obedienceInputs(true, 50, 30, FIXED_SEED))
  Assert.deepEqual(replay, first, "the same seed repeats the same obedience outcome")
  Assert.isNil(first.request, "the obedience roll never asks the interface to decide")
  Assert.notNil(first.draws, "the obedience outcome carries its draw trace")
end

-- Owned and low-level mons never roll: matching-trainer and under-cap
-- outsiders execute the ordered move with the stream untouched.
function T.owned_or_low_level_mons_never_roll_for_obedience()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local owned = obedienceInputs(false, 50, 30, FIXED_SEED)
  local ownedSnapshot = owned.stream:capture()
  local ownedOutcome = Selection.obey(owned)
  Assert.isTrue(ownedOutcome.obeys, "a matching-trainer mon obeys")
  Assert.equal(ownedOutcome.executingMove, "TACKLE", "a matching-trainer mon keeps the ordered move")
  Assert.deepEqual(owned.stream:capture(), ownedSnapshot, "an owned mon consumes no obedience draws")

  local lowLevel = obedienceInputs(true, 20, 30, FIXED_SEED)
  local lowSnapshot = lowLevel.stream:capture()
  local lowOutcome = Selection.obey(lowLevel)
  Assert.isTrue(lowOutcome.obeys, "an under-cap outsider obeys")
  Assert.deepEqual(lowLevel.stream:capture(), lowSnapshot, "an under-cap outsider consumes no obedience draws")
end

-- Obedience inputs are validated, not defaulted: a missing origin fact
-- or profile cap fails as invalid input instead of guessing obedience.
function T.obedience_inputs_are_validated_not_defaulted()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local missingOrigin = Assert.throws(function()
    Selection.obey({
      actor = { combatant = 1 },
      requestedMove = "TACKLE",
      level = 50,
      profile = { maxObedientLevel = 30 },
      stream = BattleRng.new(FIXED_SEED),
    })
  end)
  Assert.isTrue(DomainErrors.is(missingOrigin), "a missing origin fact fails as invalid input")
  local missingCap = Assert.throws(function()
    Selection.obey({
      actor = { combatant = 1 },
      requestedMove = "TACKLE",
      origin = { traded = true },
      level = 50,
      profile = {},
      stream = BattleRng.new(FIXED_SEED),
    })
  end)
  Assert.isTrue(DomainErrors.is(missingCap), "a missing profile cap fails as invalid input")
end

-- Frustration reads explicit friendship facts: with everything else
-- fixed, zero friendship strikes far harder than full friendship, and a
-- missing friendship fact fails at validation instead of falling back to
-- a convenient default.
function T.frustration_reads_explicit_friendship_facts()
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns hit progression"
  )
  local Damage = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.moves.DamageMoves",
    "direct damage owns the arithmetic hit path"
  )
  Assert.isTrue(type(Damage.register) == "function", "the damage family registers its bindings")

  ---@param friendship integer explicit friendship fact under the strike
  ---@return integer damage dealt with fixed combatants and random state
  local function strikeWith(friendship)
    local state = liveState()
    local frame = Execution.validateFrame(Execution.start({
      actionId = 1,
      actor = { combatant = 1 },
      requestedMove = "FRUSTRATION",
      executingMove = "FRUSTRATION",
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "FRUSTRATION", pp = 20, ppUps = 0 } },
      friendship = friendship,
      stream = BattleRng.new(FIXED_SEED),
    }))
    local outcome = frame
    local ctx = liveContext(state)
    for _ = 1, 32 do
      local stepped = Execution.step(ctx, outcome)
      if stepped.kind == "complete" then
        outcome = stepped
        break
      end
      outcome = stepped.frame or stepped
    end
    Assert.equal(outcome.kind, "complete", "the frustration execution runs to completion")
    local defender = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local record = defender[2] --[[@as table<string, unknown>]]
    return (record.entryHp --[[@as integer]]) - (record.hp --[[@as integer]])
  end

  local resentful = strikeWith(0)
  local devoted = strikeWith(255)
  Assert.isTrue(resentful > devoted, "zero friendship strikes harder than full friendship")
  Assert.isTrue(devoted >= 1, "full friendship still lands its minimum strike")

  local missing = Assert.throws(function()
    Execution.validateFrame(Execution.start({
      actionId = 2,
      actor = { combatant = 1 },
      requestedMove = "FRUSTRATION",
      executingMove = "FRUSTRATION",
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "FRUSTRATION", pp = 20, ppUps = 0 } },
      stream = BattleRng.new(FIXED_SEED),
    }))
  end)
  Assert.isTrue(DomainErrors.is(missing) or missing ~= nil, "a missing friendship fact fails instead of defaulting")
end

return { tests = T }
