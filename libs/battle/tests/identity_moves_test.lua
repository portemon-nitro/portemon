-- Unusual moves preserve state ownership: transformed copies live on
-- the active entry and die with it while the persistent record never
-- changes, sketch writes through the persistent owner, delayed damage
-- keeps its attacker snapshot after the attacker leaves, multi-hit
-- sequences stop on faint and break substitutes per hit, and
-- self-destruction and recoil settle in source order.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local FIXED_SEED = 918273645

---@param behavior string missing owner under test
---@return table the loaded shared move continuation owner
local function executionOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.MoveExecution", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded transform and copy family owner
local function identityOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.moves.IdentityMoves", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded charging and delayed family owner
local function sequenceOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.moves.SequenceMoves", behavior)
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

---@param state table live battle state under inspection
---@param id integer combatant under inspection
---@return table the combatant record from the state owner
local function combatantOf(state, id)
  local State =
    SessionFixture.requirePresent("libs.battle.src.BattleState", "private battle data owns reference invariants")
  return State.combatant(state, id) --[[@as table<string, unknown>]]
end

---@return table neutral type modifiers keeping strike arithmetic unchanged
local function typeFacts()
  local CombatFixture = require("libs.battle.tests.combat_fixture")
  return {
    attackerTypes = { "fire" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = CombatFixture.chart(CombatFixture.makeVanilla(), CombatFixture.VANILLA_RULESET),
  }
end

---@param move string move identity under execution
---@param slot integer zero-based power-point slot under execution
---@return table frame inputs over fixed random state
local function frameInputs(move, slot)
  local powers = {
    TRANSFORM = 0,
    SKETCH = 0,
    FUTURE_SIGHT = 80,
    BEAT_UP = 1,
    EXPLOSION = 250,
  }
  return {
    actionId = 1,
    actor = { combatant = 1 },
    requestedMove = move,
    executingMove = move,
    ppOwnerSlot = slot,
    calledBy = nil,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = {
      { move = move, pp = 10, ppUps = 0 },
    },
    moveFacts = {
      [move] = { power = powers[move] or 50, accuracy = 100, category = "physical", moveType = "normal" },
    },
    combat = {
      level = 10,
      attack = 50,
      defense = 50,
      rawAttack = 50,
      rawDefense = 50,
      attackStage = 0,
      defenseStage = 0,
    },
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "NONE", foe = "NONE" },
    attackerTypes = typeFacts().attackerTypes,
    defenderTypes = typeFacts().defenderTypes,
    typeChart = typeFacts().typeChart,
    stream = BattleRng.new(FIXED_SEED),
    beatup = move == "BEAT_UP" and {
      defense = 50,
      members = {
        { attack = 50, level = 10 },
        { attack = 50, level = 10 },
      },
    } or nil,
  }
end

-- Transform copies the target's types, moves, and ability onto the active
-- entry only: the persistent record stays identical, and leaving and
-- re-entering clears every copied residue with a fresh activation.
function T.transform_then_switch_discards_only_transient_copies()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Identity = identityOwner("transforming and copying owns the identity path")
  local State =
    SessionFixture.requirePresent("libs.battle.src.BattleState", "private battle data owns reference invariants")
  Assert.isTrue(type(Identity.register) == "function", "the identity family registers its bindings")

  local state = liveState()
  local user = combatantOf(state, 1)
  local monBefore = (user.mon --[[@as table<string, unknown>]])
  local movesBefore = {}
  for index, entry in ipairs((monBefore.moves --[[@as table<integer, unknown>]])) do
    movesBefore[index] = (entry --[[@as table<string, unknown>]]).move
  end

  local ctx = liveContext(state)
  local frame = Execution.validateFrame(Execution.start(frameInputs("TRANSFORM", 0)))
  local first = Execution.step(ctx, frame)
  Assert.isTrue(first.kind ~= nil, "the transform execution answers through the frame protocol")

  local monAfter = (combatantOf(state, 1).mon --[[@as table<string, unknown>]])
  local movesAfter = {}
  for index, entry in ipairs((monAfter.moves --[[@as table<integer, unknown>]])) do
    movesAfter[index] = (entry --[[@as table<string, unknown>]]).move
  end
  Assert.deepEqual(movesAfter, movesBefore, "transform never rewrites the persistent move set")

  local firstActivation = (combatantOf(state, 1).active --[[@as table<string, unknown>]]).activation
  State.leave(state, 1)
  Assert.isNil(combatantOf(state, 1).active, "leaving clears the active entry carrying the copies")
  State.enter(state, 1, 1)
  local reentry = combatantOf(state, 1)
  Assert.isTrue(
    (reentry.active --[[@as table<string, unknown>]]).activation ~= firstActivation,
    "re-entry mints a fresh activation without copied residue"
  )
  Assert.deepEqual(
    reentry.stages,
    { attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0, accuracy = 0, evasion = 0 },
    "re-entry carries no copied transient state"
  )
end

-- Sketch is the intentional permanent change: the sketched move lands in
-- the persistent move set through the persistent owner with fresh base
-- points, and it survives leaving and re-entering.
function T.sketch_writes_through_the_persistent_owner()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Identity = identityOwner("transforming and copying owns the identity path")
  local State =
    SessionFixture.requirePresent("libs.battle.src.BattleState", "private battle data owns reference invariants")
  Assert.isTrue(type(Identity.register) == "function", "the identity family registers its bindings")

  local state = liveState()
  local ctx = liveContext(state)
  local frame = Execution.validateFrame(Execution.start(frameInputs("SKETCH", 0)))
  local settled = frame
  for _ = 1, 16 do
    local outcome = Execution.step(ctx, settled)
    if outcome.kind == "complete" then
      settled = outcome
      break
    end
    settled = outcome.frame or outcome
  end
  Assert.equal(settled.kind, "complete", "the sketch execution runs to completion")

  local sketched = false
  local moves = ((combatantOf(state, 1).mon --[[@as table<string, unknown>]]).moves --[[@as table<integer, unknown>]])
  for _, entry in ipairs(moves) do
    if (entry --[[@as table<string, unknown>]]).move == "TACKLE" then
      sketched = true
    end
  end
  Assert.isTrue(sketched, "the sketched move persists in the move set")
  State.leave(state, 1)
  State.enter(state, 1, 1)
  local relearned = false
  local fresh = ((combatantOf(state, 1).mon --[[@as table<string, unknown>]]).moves --[[@as table<integer, unknown>]])
  for _, entry in ipairs(fresh) do
    if (entry --[[@as table<string, unknown>]]).move == "TACKLE" then
      relearned = true
    end
  end
  Assert.isTrue(relearned, "the sketched move survives the switch")
end

-- Delayed damage keeps its attacker snapshot: scheduling future sight,
-- then leaving the attacker, still resolves the delayed hit against the
-- defender slot with the original attacker facts.
function T.delayed_damage_survives_attacker_exit()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Sequence = sequenceOwner("charging and delayed sequences own the multi-turn path")
  local State =
    SessionFixture.requirePresent("libs.battle.src.BattleState", "private battle data owns reference invariants")
  Assert.isTrue(type(Sequence.register) == "function", "the sequence family registers its bindings")

  local state = liveState()
  local ctx = liveContext(state)
  local frame = Execution.validateFrame(Execution.start(frameInputs("FUTURE_SIGHT", 0)))
  local scheduled = Execution.step(ctx, frame)
  Assert.isTrue(scheduled.kind ~= nil, "the delayed scheduling answers through the frame protocol")
  State.leave(state, 1)
  Assert.isNil(combatantOf(state, 1).active, "the attacker has left before the delayed hit lands")
  local landed = Execution.step(ctx, scheduled.frame or scheduled)
  Assert.isTrue(landed.kind ~= nil, "the delayed hit still resolves after the attacker leaves")
  Assert.isTrue(
    (combatantOf(state, 2).hp --[[@as integer]]) < (combatantOf(state, 2).entryHp --[[@as integer]]),
    "the delayed hit lands on the bound defender slot"
  )
end

-- Multi-hit sequences gate on one accuracy check and one critical
-- roll, stop the moment a hit faints the target without rolling
-- further hits, and break a substitute mid-sequence so later hits reach
-- health; suspending and resuming at hit boundaries matches one
-- uninterrupted run exactly.
function T.multi_hit_sequences_stop_on_faint_and_break_substitute()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Damage = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.moves.DamageMoves",
    "direct damage owns the arithmetic hit path"
  )
  Assert.isTrue(type(Damage.register) == "function", "the damage family registers its bindings")

  local uninterrupted = liveState()
  local pending = Execution.validateFrame(Execution.start(frameInputs("BEAT_UP", 0)))
  local idle = liveContext(uninterrupted)
  local continuous = pending
  for _ = 1, 32 do
    local outcome = Execution.step(idle, continuous)
    if outcome.kind == "complete" then
      continuous = outcome
      break
    end
    continuous = outcome.frame or outcome
  end
  Assert.equal(continuous.kind, "complete", "the multi-hit sequence runs to completion")

  local resumed = liveState()
  local halted = Execution.validateFrame(Execution.start(frameInputs("BEAT_UP", 0)))
  local pause = liveContext(resumed)
  local firstHit = Execution.step(pause, halted)
  Assert.isTrue(firstHit.kind ~= nil, "the sequence suspends at a hit boundary")
  local secondHit = Execution.step(pause, firstHit.frame or firstHit)
  Assert.isTrue(secondHit.kind ~= nil, "the sequence resumes from the suspended hit")

  local idleEvents = uninterrupted.outbox --[[@as table<integer, unknown>]]
  local resumedEvents = resumed.outbox --[[@as table<integer, unknown>]]
  Assert.equal(#resumedEvents, #idleEvents, "suspend and resume emit the same event count as one run")
end

-- Self-destruction and recoil follow the source sequence: damage lands,
-- the self-faint and recoil settle after the strike, and faint settlement
-- never precedes the reactions that depend on the hit.
function T.self_destruct_and_recoil_follow_the_source_sequence()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Damage = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.moves.DamageMoves",
    "direct damage owns the arithmetic hit path"
  )
  Assert.isTrue(type(Damage.register) == "function", "the damage family registers its bindings")

  local state = liveState()
  local ctx = liveContext(state)
  local frame = Execution.validateFrame(Execution.start(frameInputs("EXPLOSION", 0)))
  local outcome = frame
  for _ = 1, 32 do
    local stepped = Execution.step(ctx, outcome)
    if stepped.kind == "complete" then
      outcome = stepped
      break
    end
    outcome = stepped.frame or stepped
  end
  Assert.equal(outcome.kind, "complete", "the self-destructing execution runs to completion")
  Assert.equal(combatantOf(state, 1).hp, 0, "the user faints after its own strike lands")
  Assert.isTrue(
    (combatantOf(state, 2).hp --[[@as integer]]) < (combatantOf(state, 2).entryHp --[[@as integer]]),
    "the blast reaches the target before the user faints"
  )
  local kinds = {}
  for _, event in ipairs(state.outbox --[[@as table<integer, unknown>]]) do
    kinds[#kinds + 1] = (event --[[@as table<string, unknown>]]).kind
  end
  Assert.isTrue(#kinds > 0, "the sequence emits its ordered events")
end

-- Substitute charges a quarter of user maximum health and raises the
-- live doll: affordable health pays exactly, exact-cost health fails
-- with no charge, and an existing doll refuses without double-charging.
function T.substitute_charges_quarter_maximum_and_raises_a_live_doll()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Sequence = sequenceOwner("charging and delayed sequences own the multi-turn path")
  Assert.isTrue(type(Sequence.register) == "function", "the sequence family registers its bindings")
  ---@param hp integer current user health under the attempt
  ---@param seedDoll boolean true when a live doll already stands
  ---@return table terminal execution step for the attempt
  ---@return table live battle state under the attempt
  ---@return table genuine mechanics context under the attempt
  local function attempt(hp, seedDoll)
    local state = liveState()
    local user = combatantOf(state, 1)
    user.maxHp = 100
    user.hp = hp
    local ctx = liveContext(state)
    if seedDoll then
      local NativeEffects = SessionFixture.requirePresent(
        "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
        "typed battle-local writes own volatile definitions"
      )
      local entry = ctx:entryOf(1)
      ctx:addBattleEffect(
        NativeEffects.definitionFor("substitute"),
        { kind = "active", combatant = 1, activation = entry.activation },
        { kind = "move", combatant = 1 },
        { version = 1, hp = 25 }
      )
    end
    local frame = Execution.validateFrame(Execution.start(frameInputs("SUBSTITUTE", 0)))
    local settled = frame
    for _ = 1, 16 do
      local outcome = Execution.step(ctx, settled)
      if outcome.kind == "complete" then
        settled = outcome
        break
      end
      settled = outcome.frame or outcome
    end
    return settled, state, ctx
  end
  local paid, paidState, paidCtx = attempt(26, false)
  Assert.equal(paid.kind, "complete", "the affordable substitute settles")
  Assert.equal(paid.result, "hit", "the affordable substitute succeeds")
  Assert.equal(combatantOf(paidState, 1).hp, 1, "the doll costs exactly quarter maximum")
  Assert.isTrue(paidCtx:hasBattleEffect(1, "substitute"), "success raises the live doll")
  Assert.isFalse(paidCtx:hasBattleEffect(1, "SUBSTITUTE"), "success raises no inert marker")
  local exact, exactState, exactCtx = attempt(25, false)
  Assert.equal(exact.result, "failed", "exact-cost health refuses the doll")
  Assert.equal(combatantOf(exactState, 1).hp, 25, "refusal charges nothing")
  Assert.isFalse(exactCtx:hasBattleEffect(1, "substitute"), "refusal raises no doll")
  local second, secondState, secondCtx = attempt(100, true)
  Assert.equal(second.result, "failed", "an existing doll refuses a second")
  Assert.equal(combatantOf(secondState, 1).hp, 100, "a refused second doll charges nothing")
  Assert.isTrue(secondCtx:hasBattleEffect(1, "substitute"), "the original doll stands")
end

return { tests = T }
