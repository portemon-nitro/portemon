-- Called moves enforce their source restrictions: metronome draws
-- only from its eligible set with the native draw count, assist reads
-- only party moves, sleep talk calls only usable moves through the
-- calling slot, mirror move copies the last move targeting the caller,
-- empty eligible sets fail without side effects, and called execution
-- never charges a second ordinary action.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local BattleSources = require("romdump.src.config.BattleSources")

local T = {}

local FIXED_SEED = 44556677

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

---@param behavior string missing owner under test
---@return table the loaded called-move eligibility owner
local function calledOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.moves.CalledMoves", behavior)
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

---@param caller string calling move identity under execution
---@param seed integer fixed generator state for the candidate roll
---@return table frame inputs for a called-move attempt
local function calledInputs(caller, seed)
  return {
    actionId = 1,
    actor = { combatant = 1 },
    requestedMove = caller,
    executingMove = caller,
    ppOwnerSlot = 0,
    calledBy = caller,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = {
      { move = caller, pp = 10, ppUps = 0 },
    },
    stream = BattleRng.new(seed),
  }
end

--- Source-banned metronome identities from pret/pokeheartgold
--- sMetronomeUnuseableMoves (src/battle/overlay_12_0224E4FC.c): the static
--- exclusion list applied on top of the gravity/heal-block dynamic checks.
---@return string[] every statically banned metronome identity in source order
local function bannedMetronomeMoves()
  return {
    "METRONOME",
    "STRUGGLE",
    "SKETCH",
    "MIMIC",
    "CHATTER",
    "SLEEP_TALK",
    "ASSIST",
    "MIRROR_MOVE",
    "COUNTER",
    "MIRROR_COAT",
    "PROTECT",
    "DETECT",
    "ENDURE",
    "DESTINY_BOND",
    "THIEF",
    "FOLLOW_ME",
    "SNATCH",
    "HELPING_HAND",
    "COVET",
    "TRICK",
    "FOCUS_PUNCH",
    "FEINT",
    "COPYCAT",
    "ME_FIRST",
    "SWITCHEROO",
  }
end

---@return table<string, boolean> every move the caller may legally draw
local function eligibleSet()
  local banned = {}
  for _, move in ipairs(bannedMetronomeMoves()) do
    banned[move] = true
  end
  local eligible = {}
  for key in pairs(BattleSources.moveBindings) do
    if banned[key] ~= true then
      eligible[key] = true
    end
  end
  return eligible
end

-- Metronome carries the source static ban list exactly: every banned
-- identity names a real inventory move, and the production table matches
-- the pinned source list with no additions or omissions.
function T.metronome_ban_list_matches_the_source_table()
  local Called = calledOwner("metronome-class selection owns the called-move path")
  Assert.isTrue(type(Called.METRONOME_BANNED) == "table", "the called family publishes its metronome ban set")
  local pinned = bannedMetronomeMoves()
  Assert.equal(#pinned, 25, "the pinned source ban list stays complete")
  local seen = {}
  for _, move in ipairs(pinned) do
    Assert.isTrue(BattleSources.moveBindings[move] ~= nil, "banned " .. move .. " names a real inventory move")
    Assert.isTrue(Called.METRONOME_BANNED[move] == true, "production bans " .. move)
    seen[move] = true
  end
  local extra = 0
  for move in pairs(Called.METRONOME_BANNED) do
    if seen[move] ~= true then
      extra = extra + 1
    end
  end
  Assert.equal(extra, 0, "production bans nothing beyond the source list")
end

-- Metronome selects only eligible moves and never struggle: sweeping
-- fixed seeds keeps every drawn move inside the eligible set, the same
-- seed always draws the same move, banned identities never surface, and
-- the pool spans the source inventory rather than a stand-in handful.
function T.metronome_selects_only_eligible_moves_with_native_draws()
  local Called = calledOwner("metronome-class selection owns the called-move path")
  local Execution = executionOwner("the shared move continuation owns hit progression")
  Assert.isTrue(type(Called.register) == "function", "the called family registers its bindings")
  local eligible = eligibleSet()
  local distinct = {}
  local firstDraw = nil
  for seed = FIXED_SEED, FIXED_SEED + 31 do
    local frame = Execution.validateFrame(Execution.start(calledInputs("METRONOME", seed)))
    local drawn = frame.executingMove
    Assert.isTrue(eligible[drawn] == true, "seed " .. seed .. " draws an eligible move, got " .. tostring(drawn))
    Assert.isTrue(drawn ~= "STRUGGLE", "the called draw never falls back to struggle")
    Assert.isTrue(drawn ~= "PROTECT", "the source ban list excludes protections from the draw")
    distinct[drawn] = true
    if seed == FIXED_SEED then
      firstDraw = drawn
    end
  end
  local replay = Execution.validateFrame(Execution.start(calledInputs("METRONOME", FIXED_SEED)))
  Assert.equal(replay.executingMove, firstDraw, "the same seed draws the same move")
  local count = 0
  for _ in pairs(distinct) do
    count = count + 1
  end
  Assert.isTrue(count > 3, "the draw pool spans the inventory, got " .. count .. " distinct draws")
end

-- Assist reads only party moves: members outside the party roster never
-- appear, forbidden moves stay excluded, and the drawn move executes
-- through the calling slot.
function T.assist_reads_only_party_moves()
  local Called = calledOwner("metronome-class selection owns the called-move path")
  local Execution = executionOwner("the shared move continuation owns hit progression")
  Assert.isTrue(type(Called.register) == "function", "the called family registers its bindings")
  local party = { "TACKLE", "SPLASH" }
  local outsiders = { PROTECT = true, EXPLOSION = true }
  for seed = FIXED_SEED, FIXED_SEED + 15 do
    local inputs = calledInputs("ASSIST", seed)
    inputs.party = party
    local frame = Execution.validateFrame(Execution.start(inputs))
    local drawn = frame.executingMove
    local member = false
    for _, move in ipairs(party) do
      if move == drawn then
        member = true
      end
    end
    Assert.isTrue(member, "assist draws a party move, got " .. tostring(drawn))
    Assert.isNil(outsiders[drawn], "assist never draws outside the party roster")
    Assert.equal(frame.ppOwnerSlot, 0, "the drawn move charges the calling slot")
  end
end

-- Assist refuses the remaining source-banned thieves and mimics: party
-- rosters carrying covet, feint, or switcheroo never see them drawn, per
-- the source ban table shared with metronome legality.
function T.assist_refuses_covet_feint_and_switcheroo()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local party = { "TACKLE", "COVET", "FEINT", "SWITCHEROO" }
  local refused = { COVET = true, FEINT = true, SWITCHEROO = true }
  for seed = FIXED_SEED, FIXED_SEED + 31 do
    local inputs = calledInputs("ASSIST", seed)
    inputs.party = party
    local frame = Execution.validateFrame(Execution.start(inputs))
    local drawn = frame.executingMove
    Assert.isNil(refused[drawn], "assist never draws a banned move, got " .. tostring(drawn))
    Assert.equal(drawn, "TACKLE", "the lone eligible party move answers every draw")
  end
end

-- Sleep talk calls only usable moves: the caller stays asleep, the drawn
-- move executes with the power-point owner on the sleep-talk slot, and
-- the calling slot itself is never drawn.
function T.sleep_talk_calls_only_usable_moves_through_the_calling_slot()
  local Selection = selectionOwner("usable-move and forced-action checks own move selection")
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Called = calledOwner("metronome-class selection owns the called-move path")
  Assert.isTrue(type(Called.register) == "function", "the called family registers its bindings")
  local usable = { "TACKLE", "SPLASH" }
  for seed = FIXED_SEED, FIXED_SEED + 15 do
    local inputs = calledInputs("SLEEP_TALK", seed)
    inputs.usable = usable
    inputs.status = { sleep = true }
    local plan = Selection.resolveExecution(inputs)
    Assert.equal(plan.requestedMove, "SLEEP_TALK", "the requested move stays on the calling slot")
    Assert.equal(plan.ppOwnerSlot, 0, "the power-point owner stays on the calling slot")
    local drawn = plan.executingMove
    Assert.isTrue(drawn ~= "SLEEP_TALK", "sleep talk never calls its own slot")
    local allowed = false
    for _, move in ipairs(usable) do
      if move == drawn then
        allowed = true
      end
    end
    Assert.isTrue(allowed, "sleep talk draws a usable move, got " .. tostring(drawn))
    local frame = Execution.validateFrame(Execution.start(plan))
    Assert.equal(frame.calledBy, "SLEEP_TALK", "the frame records the calling move")
  end
end

-- Mirror move copies the last move targeting the caller: with a recorded
-- incoming strike it executes that identity from its own slot, and with
-- no copied move it fails instead of striking.
function T.mirror_move_copies_the_last_move_targeting_the_caller()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Called = calledOwner("metronome-class selection owns the called-move path")
  Assert.isTrue(type(Called.register) == "function", "the called family registers its bindings")
  local state = liveState()
  local ctx = liveContext(state)
  local inputs = calledInputs("MIRROR_MOVE", FIXED_SEED)
  inputs.copiedMove = "TACKLE"
  local frame = Execution.validateFrame(Execution.start(inputs))
  Assert.equal(frame.executingMove, "TACKLE", "mirror move executes the copied identity")
  Assert.equal(frame.ppOwnerSlot, 0, "the copied move charges the mirror-move slot")
  local outcome = Execution.step(ctx, frame)
  Assert.isTrue(outcome.kind ~= nil, "the copied execution answers through the frame protocol")

  local unopposed = calledInputs("MIRROR_MOVE", FIXED_SEED)
  unopposed.copiedMove = nil
  local failed = Execution.validateFrame(Execution.start(unopposed))
  local settled = Execution.step(ctx, failed)
  Assert.equal(settled.kind, "complete", "mirror move with nothing to copy settles")
  Assert.equal(settled.result, "failed", "mirror move with nothing to copy fails instead of striking")
end

-- Empty eligible sets fail without side effects: no power points leave,
-- no selection draws are consumed, and no damage events are emitted.
function T.empty_eligible_sets_fail_without_side_effects()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local Called = calledOwner("metronome-class selection owns the called-move path")
  Assert.isTrue(type(Called.register) == "function", "the called family registers its bindings")
  local state = liveState()
  local ctx = liveContext(state)
  local inputs = calledInputs("ASSIST", FIXED_SEED)
  inputs.party = {}
  local moves = inputs.moves
  local stream = inputs.stream
  local beforeDraws = stream:capture()
  local eventsBefore = #state.outbox
  local frame = Execution.validateFrame(Execution.start(inputs))
  local settled = Execution.step(ctx, frame)
  Assert.equal(settled.kind, "complete", "the empty call settles")
  Assert.equal(settled.result, "failed", "the empty call fails instead of falling back to damage")
  Assert.equal((moves[1] --[[@as table<string, unknown>]]).pp, 10, "the failed call spends no points")
  Assert.deepEqual(stream:capture(), beforeDraws, "the failed call consumes no selection draws")
  Assert.equal(#state.outbox, eventsBefore, "the failed call emits no strike")
end

-- Called execution never charges a second ordinary action: exactly one
-- point leaves the calling slot, the drawn move entry keeps its points,
-- and the turn budget is consumed once.
function T.called_execution_never_charges_a_second_ordinary_action()
  local Execution = executionOwner("the shared move continuation owns hit progression")
  local state = liveState()
  local ctx = liveContext(state)
  local moves = {
    { move = "METRONOME", pp = 10, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local inputs = calledInputs("METRONOME", FIXED_SEED)
  inputs.moves = moves
  local frame = Execution.validateFrame(Execution.start(inputs))
  local outcome = frame
  for _ = 1, 32 do
    local stepped = Execution.step(ctx, outcome)
    if stepped.kind == "complete" then
      outcome = stepped
      break
    end
    outcome = stepped.frame or stepped
  end
  Assert.equal(outcome.kind, "complete", "the called execution runs to completion")
  Assert.equal((moves[1] --[[@as table<string, unknown>]]).pp, 9, "exactly one point leaves the calling slot")
  Assert.equal((moves[2] --[[@as table<string, unknown>]]).pp, 35, "the drawn move entry keeps its points")
end

return { tests = T }
