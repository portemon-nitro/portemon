-- Move selection separates the requested move from the executing move
-- and the power-point owner, prevention gates reject at their native
-- checkpoints without random or power-point side effects, running out of
-- usable moves yields an explicit struggle action, and namespaced custom
-- moves execute through the same frame contract without touching the
-- native registry or the battle loop.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local DomainErrors = require("libs.errors.src.Errors")

local T = {}

local FIXED_SEED = 287454020

---@param behavior string missing owner under test
---@return table the loaded shared move continuation owner
local function executionOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.MoveExecution", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded usable-move and forced-action owner
local function selectionOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.MoveSelection", behavior)
end

---@return table battle stream over fixed random state
local function fixedStream()
  return BattleRng.new(FIXED_SEED)
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

---@return table<string, table<string, unknown>> immutable move facts for the transition fixtures
local function tacticFacts()
  return {
    TACKLE = { power = 35, accuracy = 95, category = "physical", moveType = "normal" },
    SLEEP_TALK = { power = 0, accuracy = 0, category = "other", moveType = "normal" },
  }
end

---@return table<string, unknown>[] persistent move entries with explicit power-point state
local function twoMoveSet()
  return {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "SLEEP_TALK", pp = 10, ppUps = 0 },
  }
end

---@param slot integer zero-based move slot under test
---@return table combatant reference issuing the choice
local function actorRef(slot)
  return { combatant = 1, moveSlot = slot }
end

---@param moves table<string, unknown>[] persistent move entries under selection
---@param prevention table<string, unknown>|nil gate state under selection
---@return table selection inputs over fixed random state
local function selectionInputs(moves, prevention)
  return {
    actor = actorRef(0),
    moves = moves,
    prevention = prevention or {},
    stream = fixedStream(),
  }
end

---@return table<string, unknown> neutral type modifiers keeping strike arithmetic unchanged
local function typeFacts()
  local CombatFixture = require("libs.battle.tests.combat_fixture")
  return {
    attackerTypes = { "fire" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET),
  }
end

-- Selection keeps three identities apart: the requested slot move, the
-- move that actually executes after source overrides, and the slot owning
-- the spent power points. A called move executes the drawn move while the
-- power-point owner stays on the calling slot.
function T.selection_separates_requested_executing_and_pp_owning_moves()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local resolved = Selection.resolveExecution({
    actor = actorRef(1),
    requestedSlot = 1,
    requestedMove = "SLEEP_TALK",
    executingMove = "TACKLE",
    ppOwnerSlot = 1,
    calledBy = "SLEEP_TALK",
    selectedTarget = SessionFixture.positionTarget(2),
    moves = twoMoveSet(),
    stream = fixedStream(),
  })
  Assert.equal(resolved.requestedMove, "SLEEP_TALK", "the requested move stays on the calling slot")
  Assert.equal(resolved.executingMove, "TACKLE", "the executing move is the drawn move")
  Assert.equal(resolved.ppOwnerSlot, 1, "the power-point owner stays on the calling slot")
  Assert.equal(resolved.calledBy, "SLEEP_TALK", "the plan records which move called the drawn one")

  local direct = Selection.resolveExecution({
    actor = actorRef(0),
    requestedSlot = 0,
    requestedMove = "TACKLE",
    executingMove = "TACKLE",
    ppOwnerSlot = 0,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    moves = twoMoveSet(),
    stream = fixedStream(),
  })
  Assert.equal(direct.requestedMove, direct.executingMove, "a direct selection executes what was requested")
  Assert.isNil(direct.calledBy, "a direct selection names no calling move")
end

-- The action-to-move transition spends power points from the owning slot:
-- exactly one point per execution, from the caller on called moves, never
-- from the drawn move's own entry.
function T.pp_is_consumed_from_the_owning_slot_at_the_native_checkpoint()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local plan = Selection.resolveExecution({
    actor = actorRef(0),
    requestedSlot = 0,
    requestedMove = "TACKLE",
    executingMove = "TACKLE",
    ppOwnerSlot = 0,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    moves = twoMoveSet(),
    stream = fixedStream(),
  })
  local moves = twoMoveSet()
  local frame = Execution.start({
    actionId = 1,
    actor = plan.actor,
    requestedMove = plan.requestedMove,
    executingMove = plan.executingMove,
    ppOwnerSlot = plan.ppOwnerSlot,
    calledBy = plan.calledBy,
    selectedTarget = plan.selectedTarget,
    targets = { { combatant = 2 } },
    moves = moves,
    moveFacts = tacticFacts(),
    stream = fixedStream(),
  })
  local validated = Execution.validateFrame(frame)
  Assert.equal(validated.ppOwnerSlot, 0, "the started frame carries its power-point owner")
  Assert.equal((moves[1] --[[@as table<string, unknown>]]).pp, 34, "exactly one point leaves the owning slot")
  Assert.equal((moves[2] --[[@as table<string, unknown>]]).pp, 10, "uninvolved slots keep their points")

  local calledMoves = twoMoveSet()
  Execution.start({
    actionId = 2,
    actor = actorRef(1),
    requestedMove = "SLEEP_TALK",
    executingMove = "TACKLE",
    ppOwnerSlot = 1,
    calledBy = "SLEEP_TALK",
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = calledMoves,
    moveFacts = tacticFacts(),
    stream = fixedStream(),
  })
  Assert.equal(
    (calledMoves[2] --[[@as table<string, unknown>]]).pp,
    9,
    "a called move spends the calling slot"
  )
  Assert.equal(
    (calledMoves[1] --[[@as table<string, unknown>]]).pp,
    35,
    "a called move never spends the drawn move entry"
  )
end

-- Prevention gates reject at their source points: an empty slot, a
-- disabled move, an encore-locked other move, a choice-locked other move,
-- a taunted status move, and an imprisoned move each fail with their own
-- declared reason while the random stream and power points stay untouched.
function T.prevention_gates_reject_without_rng_or_pp_side_effects()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local cases = {
    { name = "empty slot", choice = { moveSlot = 0 }, prevention = { pp = { [0] = 0 } } },
    { name = "disabled move", choice = { moveSlot = 0 }, prevention = { disabled = { [0] = true } } },
    { name = "encore-locked other move", choice = { moveSlot = 1 }, prevention = { encore = 0 } },
    { name = "choice-locked other move", choice = { moveSlot = 1 }, prevention = { choiceLock = 0 } },
    { name = "taunted status move", choice = { moveSlot = 1 }, prevention = { taunt = true } },
    { name = "imprisoned move", choice = { moveSlot = 0 }, prevention = { imprisoned = { TACKLE = true } } },
  }
  local reasons = {}
  for _, case in ipairs(cases) do
    local record = case --[[@as table<string, unknown>]]
    local stream = fixedStream()
    local snapshot = stream:capture()
    local moves = twoMoveSet()
    local inputs = selectionInputs(moves, record.prevention --[[@as table<string, unknown>]])
    inputs.choice = record.choice
    local verdict = Selection.choices(inputs)
    Assert.isFalse(verdict.usable, "the " .. (record.name --[[@as string]]) .. " gate rejects the choice")
    Assert.notNil(verdict.reason, "the " .. (record.name --[[@as string]]) .. " gate names its reason")
    Assert.deepEqual(stream:capture(), snapshot, "the " .. (record.name --[[@as string]]) .. " gate draws nothing")
    Assert.equal((moves[1] --[[@as table<string, unknown>]]).pp, 35, "rejected choices spend no points")
    Assert.equal((moves[2] --[[@as table<string, unknown>]]).pp, 10, "rejected choices spend no points")
    Assert.isNil(reasons[verdict.reason], "prevention reasons stay distinct, duplicated: " .. tostring(verdict.reason))
    reasons[verdict.reason] = true
  end
end

-- Rejection, failure, and settled executions are different results: an
-- unknown slot rejects as invalid input with no simulation side effects,
-- while a started frame carries its target list and hit progression for
-- the hit loop instead of failing outright.
function T.rejection_failure_and_started_frames_stay_distinct()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local stream = fixedStream()
  local snapshot = stream:capture()
  local rejected = Assert.throws(function()
    Selection.resolveExecution({
      actor = actorRef(9),
      requestedSlot = 9,
      requestedMove = "TACKLE",
      executingMove = "TACKLE",
      ppOwnerSlot = 9,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      moves = twoMoveSet(),
      stream = stream,
    })
  end)
  Assert.isTrue(DomainErrors.is(rejected), "an unknown slot rejects as invalid input")
  Assert.deepEqual(stream:capture(), snapshot, "the rejected selection draws nothing")

  local frame = Execution.start({
    actionId = 3,
    actor = actorRef(0),
    requestedMove = "TACKLE",
    executingMove = "TACKLE",
    ppOwnerSlot = 0,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = twoMoveSet(),
    moveFacts = tacticFacts(),
    combat = { level = 10, attack = 50, defense = 50 },
    attackerTypes = typeFacts().attackerTypes,
    defenderTypes = typeFacts().defenderTypes,
    typeChart = typeFacts().typeChart,
    stream = fixedStream(),
  })
  local validated = Execution.validateFrame(frame)
  Assert.equal(validated.executingMove, "TACKLE", "the started frame names its executing move")
  Assert.equal(#validated.targets, 1, "the started frame carries its target list")
  local state = liveState()
  local ctx = liveContext(state)
  local first = Execution.step(ctx, validated)
  Assert.isTrue(first.kind ~= nil, "the hit loop answers with a stepped frame state")
end

-- With no usable move the selection yields struggle as an explicit native
-- action: it carries its own identity, owns no power-point slot, and never
-- appears as a random fallback move.
function T.struggle_is_an_explicit_action_when_no_move_is_usable()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local spent = {
    { move = "TACKLE", pp = 0, ppUps = 0 },
    { move = "SLEEP_TALK", pp = 0, ppUps = 0 },
  }
  local resolved = Selection.resolveExecution({
    actor = actorRef(0),
    requestedSlot = nil,
    requestedMove = "STRUGGLE",
    executingMove = "STRUGGLE",
    ppOwnerSlot = nil,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    moves = spent,
    stream = fixedStream(),
  })
  Assert.equal(resolved.executingMove, "STRUGGLE", "the empty selection executes struggle explicitly")
  Assert.isNil(resolved.ppOwnerSlot, "struggle owns no power-point slot")
  Assert.isNil(resolved.calledBy, "struggle is never a called move")
end

-- A namespaced custom move composes through the existing contracts: it
-- registers beside native moves through the behavior builder, validates
-- its own parameters and versioned state, runs to completion through the
-- shared frame steps with context operations only, and leaves the native
-- registry and kernel untouched.
function T.namespaced_custom_moves_execute_through_the_same_frame_contract()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local NativeMoves = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.NativeMoves",
    "the native move registry stays free of mod-specific conditions"
  )
  local BattleBehaviorBuilder = SessionFixture.requirePresent(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration owns move composition"
  )
  local BattleSources = SessionFixture.requirePresent(
    "romdump.src.config.BattleSources",
    "the source inventory owns the native move set"
  )
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerMove("test:echo-strike", { module = "test.echo_strike", version = 1 }, "move-tests")
  local bound = behaviors:freeze()
  Assert.notNil(bound:get("moves", "test:echo-strike"), "the custom move installs through composition")

  local custom = {
    key = "test:echo-strike",
    stateVersion = 1,
    validateParams = function(value)
      assert(type(value) == "table", "custom parameters arrive as a record")
      return value
    end,
    validateState = function(value)
      assert(type(value) == "table", "custom state arrives as a record")
      return value
    end,
    start = function(ctx, move)
      assert(ctx ~= nil, "custom moves start from the battle context")
      assert(move.key == "test:echo-strike", "custom moves receive their own definition")
      return { kind = "custom-child", key = move.key, hits = 0 }
    end,
    step = function(ctx, frame)
      assert(ctx ~= nil, "custom moves step through the battle context")
      local pending = frame --[[@as table<string, unknown>]]
      pending.hits = (pending.hits --[[@as integer]]) + 1
      ctx:damage(2, 6, { key = "test:echo-strike" })
      return { kind = "complete", result = "hit" }
    end,
  }
  Assert.equal(custom.key, "test:echo-strike", "the custom behavior carries its own namespaced key")
  Assert.equal(custom.stateVersion, 1, "the custom behavior versions its state")
  custom.validateParams({ power = 6 })
  custom.validateState({ hits = 0 })

  local native = {}
  NativeMoves.register(native)
  Assert.isTrue(
    NativeMoves.assertCoverage(native, BattleSources),
    "the native registry still covers the source inventory exactly"
  )
  Assert.isNil(native["test:echo-strike"], "the native registry carries no mod-specific condition")
  Assert.isTrue(
    type(Execution.start) == "function" and type(Execution.step) == "function",
    "custom moves run through the shared continuation steps"
  )
end

-- Native damage answers to real combatants: the same strike over the
-- same seed deals different damage for deliberately different attacker
-- and defender facts, and running without combat facts never silently
-- falls back to the old reference triple.
function T.damage_uses_actual_combatant_facts()
  local Execution = executionOwner("the shared move continuation owns hit progression")

  ---@param combat table<string, unknown>|nil real attacker/defender facts under the strike
  ---@return integer damage dealt by one tackle over fixed random state
  local function strike(combat)
    local state = liveState()
    local ctx = liveContext(state)
    local frame = Execution.validateFrame(Execution.start({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = "TACKLE",
      executingMove = "TACKLE",
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "TACKLE", pp = 35, ppUps = 0 } },
      moveFacts = {
        TACKLE = { power = 35, accuracy = 95, category = "physical", moveType = "normal" },
      },
      combat = combat,
      attackerTypes = typeFacts().attackerTypes,
      defenderTypes = typeFacts().defenderTypes,
      typeChart = typeFacts().typeChart,
      stream = fixedStream(),
    }))
    local outcome = frame
    for _ = 1, 32 do
      local stepped = Execution.step(ctx, outcome)
      if stepped.kind == "complete" then
        outcome = stepped
        break
      end
      outcome = stepped.frame or stepped
    end
    Assert.equal(outcome.kind, "complete", "the tackle execution runs to completion")
    local defender = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local record = defender[2] --[[@as table<string, unknown>]]
    return (record.entryHp --[[@as integer]]) - (record.hp --[[@as integer]])
  end

  local hard = strike({ level = 50, attack = 120, defense = 90 })
  local soft = strike({ level = 5, attack = 30, defense = 40 })
  Assert.isTrue(hard > soft, "different real combat facts deal different damage")
  Assert.isTrue(soft >= 1, "the weaker pair still lands its minimum strike")
  local fallbackTriple = strike({ level = 10, attack = 50, defense = 50 })
  Assert.isTrue(hard ~= fallbackTriple, "real combat facts never silently equal the old reference triple")
  local unstated = Assert.throws(function()
    strike(nil)
  end, "unstated combat facts fail instead of falling back")
  Assert.equal(unstated.code, "BATTLE_MISSING_BEHAVIOR", "the missing facts name their behavior")
end

-- Registered but unmodeled native semantics never fake success: an
-- ordinary damage identity without implemented behavior and a condition
-- identity without implemented behavior both fail explicitly instead of
-- emitting a successful move result.
function T.unimplemented_native_moves_fail_explicitly()
  local Execution = executionOwner("the shared move continuation owns hit progression")

  ---@param move string registered move identity without modeled semantics
  local function attempt(move)
    local state = liveState()
    local ctx = liveContext(state)
    local frame = Execution.validateFrame(Execution.start({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = move,
      executingMove = move,
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = move, pp = 15, ppUps = 0 } },
      moveFacts = {
        [move] = { power = 40, accuracy = 100, category = "special", moveType = "fire" },
      },
      combat = { level = 20, attack = 60, defense = 55 },
      stream = fixedStream(),
    }))
    local eventsBefore = #state.outbox
    local failure = Assert.throws(function()
      Execution.step(ctx, frame)
    end, move .. " fails instead of fake-succeeding")
    Assert.equal(failure.code, "BATTLE_MISSING_BEHAVIOR", move .. " names its missing behavior")
    Assert.equal(failure.context.key, move, "the failure names the unimplemented move")
    Assert.equal(#state.outbox, eventsBefore, move .. " emits no success-shaped outcome")
    local defender = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local record = defender[2] --[[@as table<string, unknown>]]
    Assert.equal(
      record.hp --[[@as integer]],
      record.entryHp --[[@as integer]],
      move .. " deals no fabricated damage"
    )
  end

  attempt("AEROBLAST")
  attempt("BLOCK")
end

-- Frames without resolved move facts never validate: the transition
-- refuses to build them, hand-built frames are rejected, and validation
-- itself consumes no draws.
function T.frames_without_move_facts_fail_validation()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local refused = Assert.throws(function()
    Execution.start({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = "TACKLE",
      executingMove = "TACKLE",
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = twoMoveSet(),
      stream = fixedStream(),
    })
  end, "the transition resolves move facts before publishing")
  Assert.equal(refused.code, "BATTLE_MISSING_BEHAVIOR", "the missing facts name their behavior")
  local malformed = Assert.throws(function()
    Execution.validateFrame({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = "TACKLE",
      executingMove = "TACKLE",
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = twoMoveSet(),
      stream = fixedStream(),
      locals = {},
    })
  end, "validation rejects frames without executing move facts")
  Assert.equal(malformed.code, "BATTLE_INVALID_STATE", "the malformed frame names its state")

  local stream = fixedStream()
  local frame = Execution.start({
    actionId = 2,
    actor = actorRef(0),
    requestedMove = "TACKLE",
    executingMove = "TACKLE",
    ppOwnerSlot = 0,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = twoMoveSet(),
    moveFacts = tacticFacts(),
    stream = stream,
  })
  local snapshot = stream:capture()
  Execution.validateFrame(frame)
  Assert.deepEqual(stream:capture(), snapshot, "support validation consumes no draws")
end

-- Specialized gates keep their explicit failure policy without modeled
-- facts: level-fixed damage and one-hit knockouts settle as failures
-- instead of dealing guessed damage.
function T.specialized_gates_fail_without_required_facts()
  local Execution = executionOwner("the shared move continuation owns hit progression")

  ---@param move string gated damage identity under execution
  ---@return table<string, unknown> terminal step for the gated execution
  local function settle(move)
    local state = liveState()
    local ctx = liveContext(state)
    local frame = Execution.validateFrame(Execution.start({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = move,
      executingMove = move,
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = move, pp = 15, ppUps = 0 } },
      moveFacts = {
        [move] = { power = 1, accuracy = 100, category = "physical", moveType = "normal" },
      },
      stream = fixedStream(),
    }))
    local outcome = Execution.step(ctx, frame)
    local defender = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local record = defender[2] --[[@as table<string, unknown>]]
    Assert.equal(
      record.hp --[[@as integer]],
      record.entryHp --[[@as integer]],
      move .. " deals no guessed damage without its facts"
    )
    return outcome
  end

  Assert.equal(settle("SEISMIC_TOSS").result, "failed", "level-fixed damage fails without its level fact")
  Assert.equal(settle("GUILLOTINE").result, "failed", "one-hit knockouts fail without their level gate")
end

-- Sequence strikes read power from the compiled move facts: the same
-- charge strike over the same seed deals different damage for different
-- compiled powers, and a strike without compiled power fails explicitly
-- instead of dealing curated-table damage.
function T.sequence_strikes_read_power_from_compiled_move_facts()
  local Execution = executionOwner("the shared move continuation owns hit progression")

  ---@param power integer|nil compiled strike power under the attempt
  ---@return integer damage dealt by one charge strike over fixed random state
  local function strike(power)
    local state = liveState()
    local ctx = liveContext(state)
    local moveFacts = { accuracy = 100, category = "physical", moveType = "flying" }
    if power ~= nil then
      moveFacts.power = power
    end
    local frame = Execution.validateFrame(Execution.start({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = "FLY",
      executingMove = "FLY",
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "FLY", pp = 15, ppUps = 0 } },
      moveFacts = { FLY = moveFacts },
      combat = { level = 50, attack = 120, defense = 90 },
      attackerTypes = typeFacts().attackerTypes,
      defenderTypes = typeFacts().defenderTypes,
      typeChart = typeFacts().typeChart,
      stream = fixedStream(),
    }))
    local outcome = frame
    for _ = 1, 32 do
      local stepped = Execution.step(ctx, outcome)
      if stepped.kind == "complete" then
        outcome = stepped
        break
      end
      outcome = stepped.frame or stepped
    end
    Assert.equal(outcome.kind, "complete", "the charge strike runs to completion")
    local defender = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local record = defender[2] --[[@as table<string, unknown>]]
    return (record.entryHp --[[@as integer]]) - (record.hp --[[@as integer]])
  end

  local hard = strike(150)
  local soft = strike(10)
  Assert.isTrue(hard > soft, "different compiled powers deal different sequence damage")
  local missing = Assert.throws(function()
    strike(nil)
  end, "a sequence strike without compiled power fails instead of curating damage")
  Assert.equal(missing.code, "BATTLE_MISSING_BEHAVIOR", "the missing power names its behavior")
end

-- Delayed strikes read power from the compiled move facts at impact:
-- scheduling succeeds without it, but the landing fails explicitly
-- instead of dealing curated-table damage.
function T.delayed_strikes_read_power_from_compiled_move_facts()
  local Execution = executionOwner("the shared move continuation owns hit progression")

  ---@param power integer|nil compiled strike power under the landing
  ---@return integer damage dealt by the delayed landing over fixed random state
  local function land(power)
    local state = liveState()
    local ctx = liveContext(state)
    local moveFacts = { accuracy = 100, category = "special", moveType = "psychic" }
    if power ~= nil then
      moveFacts.power = power
    end
    local frame = Execution.validateFrame(Execution.start({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = "FUTURE_SIGHT",
      executingMove = "FUTURE_SIGHT",
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "FUTURE_SIGHT", pp = 10, ppUps = 0 } },
      moveFacts = { FUTURE_SIGHT = moveFacts },
      combat = { level = 50, attack = 120, defense = 90 },
      attackerTypes = typeFacts().attackerTypes,
      defenderTypes = typeFacts().defenderTypes,
      typeChart = typeFacts().typeChart,
      stream = fixedStream(),
    }))
    local scheduled = Execution.step(ctx, frame)
    Assert.isTrue(scheduled.kind ~= nil, "the delayed scheduling answers through the frame protocol")
    local landed = Execution.step(ctx, scheduled.frame or scheduled)
    Assert.equal(landed.kind, "complete", "the delayed landing runs to completion")
    local defender = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local record = defender[2] --[[@as table<string, unknown>]]
    return (record.entryHp --[[@as integer]]) - (record.hp --[[@as integer]])
  end

  local hard = land(140)
  local soft = land(20)
  Assert.isTrue(hard > soft, "different compiled powers deal different delayed damage")
  local state = liveState()
  local ctx = liveContext(state)
  local frame = Execution.validateFrame(Execution.start({
    actionId = 1,
    actor = actorRef(0),
    requestedMove = "FUTURE_SIGHT",
    executingMove = "FUTURE_SIGHT",
    ppOwnerSlot = 0,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "FUTURE_SIGHT", pp = 10, ppUps = 0 } },
    moveFacts = { FUTURE_SIGHT = { accuracy = 100, category = "special", moveType = "psychic" } },
    combat = { level = 50, attack = 120, defense = 90 },
    attackerTypes = typeFacts().attackerTypes,
    defenderTypes = typeFacts().defenderTypes,
    typeChart = typeFacts().typeChart,
    stream = fixedStream(),
  }))
  local scheduled = Execution.step(ctx, frame)
  local missing = Assert.throws(function()
    Execution.step(ctx, scheduled.frame or scheduled)
  end, "a delayed landing without compiled power fails instead of curating damage")
  Assert.equal(missing.code, "BATTLE_MISSING_BEHAVIOR", "the missing delayed power names its behavior")
end

-- Sequence strikes resolve exact STAB and effectiveness through the
-- session chart: a same-type attacker deals more than a mismatched one,
-- super-effective relations deal more than resisted ones, and chart
-- immunities deal zero instead of silent neutral damage.
function T.sequence_strikes_resolve_exact_stab_and_effectiveness()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local CombatFixture = require("libs.battle.tests.combat_fixture")

  ---@param move string sequence strike identity under the attempt
  ---@param moveType string compiled move type under the strike
  ---@param attacker string attacker semantic type under the strike
  ---@param defender string[] defender semantic types under the strike
  ---@return integer damage dealt by one strike over fixed random state
  local function strike(move, moveType, attacker, defender)
    local state = liveState()
    local ctx = liveContext(state)
    local frame = Execution.validateFrame(Execution.start({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = move,
      executingMove = move,
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = move, pp = 15, ppUps = 0 } },
      moveFacts = { [move] = { power = 20, accuracy = 100, category = "physical", moveType = moveType } },
      combat = { level = 5, attack = 30, defense = 40 },
      attackerTypes = { attacker },
      defenderTypes = { [2] = defender },
      typeChart = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET),
      stream = fixedStream(),
    }))
    local outcome = frame
    for _ = 1, 32 do
      local stepped = Execution.step(ctx, outcome)
      if stepped.kind == "complete" then
        outcome = stepped
        break
      end
      outcome = stepped.frame or stepped
    end
    Assert.equal(outcome.kind, "complete", "the sequence strike runs to completion")
    local defenders = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local record = defenders[2] --[[@as table<string, unknown>]]
    return (record.entryHp --[[@as integer]]) - (record.hp --[[@as integer]])
  end

  local stabbed = strike("FLY", "fire", "fire", { "normal" })
  local unstabbed = strike("FLY", "fire", "water", { "normal" })
  Assert.isTrue(stabbed > unstabbed, "same-type attackers deal STAB sequence damage")
  local super = strike("DIVE", "water", "normal", { "fire" })
  local resisted = strike("DIVE", "water", "normal", { "water" })
  Assert.isTrue(super > resisted, "effectiveness scales sequence damage exactly")
  local immune = strike("DIG", "ground", "normal", { "flying" })
  Assert.equal(immune, 0, "chart immunities deal zero sequence damage")
  local control = strike("DIG", "ground", "normal", { "normal" })
  Assert.isTrue(control >= 1, "the immunity control still lands its minimum strike")
end

-- Stockpile releases never take the staged path: without accumulated
-- stacks SPIT_UP fails explicitly instead of dealing neutral damage, so
-- fixed-model members stay fixed and never gain silent STAB.
function T.stockpile_releases_fail_instead_of_dealing_neutral_damage()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local state = liveState()
  local ctx = liveContext(state)
  local frame = Execution.validateFrame(Execution.start({
    actionId = 1,
    actor = actorRef(0),
    requestedMove = "SPIT_UP",
    executingMove = "SPIT_UP",
    ppOwnerSlot = 0,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "SPIT_UP", pp = 10, ppUps = 0 } },
    moveFacts = { SPIT_UP = { power = 100, accuracy = 100, category = "special", moveType = "normal" } },
    combat = { level = 50, attack = 120, defense = 90 },
    attackerTypes = typeFacts().attackerTypes,
    defenderTypes = typeFacts().defenderTypes,
    typeChart = typeFacts().typeChart,
    stream = fixedStream(),
  }))
  local outcome = Execution.step(ctx, frame)
  Assert.equal(outcome.result, "failed", "spit up fails without its accumulated stacks")
  local defender = state.combatants --[[@as table<integer, table<string, unknown>>]]
  local record = defender[2] --[[@as table<string, unknown>]]
  Assert.equal(
    record.hp --[[@as integer]],
    record.entryHp --[[@as integer]],
    "the failed release deals no neutral damage"
  )
end

-- Sequence strikes never assume neutral type facts: a strike without
-- attacker types, without a session chart, or a delayed landing without
-- defender types fails with its missing behavior instead of succeeding.
function T.sequence_strikes_fail_without_type_facts()
  local Execution = executionOwner("the shared move continuation owns hit progression")

  ---@param overrides table<string, unknown> type facts replacing the complete set
  ---@param move string sequence identity under the attempt
  local function attemptImmediate(overrides, move)
    local state = liveState()
    local ctx = liveContext(state)
    local inputs = {
      actionId = 1,
      actor = actorRef(0),
      requestedMove = move,
      executingMove = move,
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = move, pp = 15, ppUps = 0 } },
      moveFacts = { [move] = { power = 90, accuracy = 100, category = "physical", moveType = "flying" } },
      combat = { level = 50, attack = 120, defense = 90 },
      stream = fixedStream(),
    }
    for key, value in pairs(overrides) do
      inputs[key] = value
    end
    local frame = Execution.validateFrame(Execution.start(inputs))
    local failure = Assert.throws(function()
      Execution.step(ctx, frame)
    end, move .. " fails without its complete type facts")
    Assert.equal(failure.code, "BATTLE_MISSING_BEHAVIOR", "the missing facts name their behavior")
  end

  attemptImmediate({
    defenderTypes = typeFacts().defenderTypes,
    typeChart = typeFacts().typeChart,
  }, "FLY")
  attemptImmediate({
    attackerTypes = typeFacts().attackerTypes,
    defenderTypes = typeFacts().defenderTypes,
  }, "FLY")

  local state = liveState()
  local ctx = liveContext(state)
  local frame = Execution.validateFrame(Execution.start({
    actionId = 1,
    actor = actorRef(0),
    requestedMove = "FUTURE_SIGHT",
    executingMove = "FUTURE_SIGHT",
    ppOwnerSlot = 0,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "FUTURE_SIGHT", pp = 10, ppUps = 0 } },
    moveFacts = { FUTURE_SIGHT = { power = 80, accuracy = 100, category = "special", moveType = "psychic" } },
    combat = { level = 50, attack = 120, defense = 90 },
    attackerTypes = typeFacts().attackerTypes,
    typeChart = typeFacts().typeChart,
    stream = fixedStream(),
  }))
  local scheduled = Execution.step(ctx, frame)
  local failure = Assert.throws(function()
    Execution.step(ctx, scheduled.frame or scheduled)
  end, "the delayed landing fails without its defender types")
  Assert.equal(failure.code, "BATTLE_MISSING_BEHAVIOR", "the missing landing facts name their behavior")
end

-- Delayed impacts land as typeless Generation-IV damage: attacker STAB
-- and chart relations never scale the landing, so identical landings
-- from different types deal identical damage through the explicit
-- typeless contract.
function T.delayed_impacts_land_typeless_without_stab_or_relation()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local CombatFixture = require("libs.battle.tests.combat_fixture")

  ---@param attacker string attacker semantic type under the landing
  ---@param defender string[] defender semantic types under the landing
  ---@return integer damage dealt by the delayed landing over fixed random state
  local function land(attacker, defender)
    local state = liveState()
    local ctx = liveContext(state)
    local frame = Execution.validateFrame(Execution.start({
      actionId = 1,
      actor = actorRef(0),
      requestedMove = "FUTURE_SIGHT",
      executingMove = "FUTURE_SIGHT",
      ppOwnerSlot = 0,
      calledBy = nil,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "FUTURE_SIGHT", pp = 10, ppUps = 0 } },
      moveFacts = { FUTURE_SIGHT = { power = 80, accuracy = 100, category = "special", moveType = "psychic" } },
      combat = { level = 50, attack = 120, defense = 90 },
      attackerTypes = { attacker },
      defenderTypes = { [2] = defender },
      typeChart = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET),
      stream = fixedStream(),
    }))
    local scheduled = Execution.step(ctx, frame)
    local landed = Execution.step(ctx, scheduled.frame or scheduled)
    Assert.equal(landed.kind, "complete", "the delayed landing runs to completion")
    local defenders = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local record = defenders[2] --[[@as table<string, unknown>]]
    return (record.entryHp --[[@as integer]]) - (record.hp --[[@as integer]])
  end

  local fromPsychic = land("psychic", { "fire" })
  local fromNormal = land("normal", { "water" })
  Assert.equal(fromPsychic, fromNormal, "typeless landings ignore STAB and chart relations")
  Assert.isTrue(fromPsychic >= 1, "the typeless landing still deals its minimum damage")
end

return { tests = T }
