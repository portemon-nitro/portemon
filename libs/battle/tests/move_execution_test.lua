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

return { tests = T }
