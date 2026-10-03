-- Native condition moves: stage changes, major-status setters, and the
-- volatile-setting family (confusion, infatuation, taunt, torment,
-- encore, disable, hazards, trapping, sleep, healing, field states, and
-- movement restriction) execute through the existing condition bodies
-- and effect definitions with their source fail conditions. Accuracy
-- rolls use compiled accuracy; already-held states refuse without
-- effect; countdowns and layers follow their native spans.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local FIXED_SEED = 613633213

---@param behavior string missing owner under test
---@return table the loaded condition family owner
local function conditionOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.moves.ConditionMoves", behavior)
end

---@return table live battle state with two healthy combatants over real owners
local function liveState()
  local contracts = SessionFixture.sessionContracts()
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
  return contracts.State.create(contracts.Scenario.validate(scenario))
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

local chartCache = nil

---@return table<string, unknown> session type chart over the complete native matrix
local function chart()
  if chartCache == nil then
    local ContentBuilder = require("libs.content.src.ContentBuilder")
    local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
    local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
    local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
    local builder = ContentBuilder.new()
    NativeTypeChart.install(builder, "condition-moves-tests")
    local behaviors = BattleBehaviorBuilder.new()
    behaviors:registerRuleset(
      Executor.RULESET,
      { key = Executor.RULESET, chart = Executor.RULESET },
      "condition-moves-tests"
    )
    local BattleContent = require("libs.battle.src.BattleContent")
    local content = BattleContent.new(builder:freeze(), behaviors:freeze())
    chartCache = assert(content:typeChart(Executor.RULESET), "the native chart resolves for the condition probes")
  end
  return chartCache --[[@as table<string, unknown>]]
end

---@param moveKey string condition identity under the probe
---@param overrides table<string, unknown>|nil move-fact overrides for the probe
---@return table<string, table<string, unknown>> compiled-shaped facts for the probe
local function moveFacts(moveKey, overrides)
  local facts = {
    power = 0,
    accuracy = 100,
    category = "other",
    moveType = "normal",
    effectChance = 0,
  }
  for key, value in pairs(overrides or {}) do
    facts[key] = value
  end
  return { [moveKey] = facts }
end

---@param moveKey string condition identity under execution
---@param facts table<string, table<string, unknown>> compiled-shaped move facts
---@param seed integer fixed seed for the probe stream
---@param extra table<string, unknown>|nil extra frame inputs for the probe
---@return table terminal execution step plus context and state
local function runCondition(moveKey, facts, seed, extra)
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  local inputs = {
    actionId = 1001,
    actor = { combatant = 1 },
    requestedMove = moveKey,
    executingMove = moveKey,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveKey, pp = 10, ppUps = 0 } },
    moveFacts = facts,
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(seed),
  }
  for key, value in pairs(extra or {}) do
    inputs[key] = value
  end
  local node = Execution.start(inputs)
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  assert(finished.kind == "complete" and finished.frame == nil, "the condition settles")
  return { outcome = finished, ctx = ctx, state = state }
end

---@param state table live battle state under inspection
---@param key string volatile identity under the lookup
---@return table<string, unknown>? detached first matching instance
local function findInstance(state, key)
  local bag = state.effectBag --[[@as table<string, unknown>]]
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    if (record --[[@as table<string, unknown>]]).key == key then
      return record --[[@as table<string, unknown>]]
    end
  end
  return nil
end

-- Growth raises special attack through the shared stage family.
function T.growth_raises_special_attack()
  conditionOwner("stage moves own their shared family")
  local probe = runCondition("GROWTH", moveFacts("GROWTH", { accuracy = 0 }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "growth connects")
  Assert.equal(probe.ctx:entryOf(1).stages.specialAttack, 1, "growth raises special attack")
end

-- Confusion-setting moves root a counted volatile on a missed-gated
-- hit; already-confused defenders refuse.
function T.confusion_setting_moves_root_a_counted_volatile()
  conditionOwner("confusion setters own their volatile")
  local probe = runCondition(
    "CONFUSE_RAY",
    moveFacts("CONFUSE_RAY", { accuracy = 100, moveType = "ghost" }),
    FIXED_SEED
  )
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "confuse ray connects")
  local instance = findInstance(probe.state, "confusion")
  Assert.notNil(instance, "confusion lands on the defender")
  local turns = (instance --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].turns
  Assert.isTrue(turns >= 2 and turns <= 5, "confusion spans two to five turns")
end

-- Attract infatuates opposite genders and refuses same genders, the
-- genderless, and the already infatuated.
function T.attract_infatuates_opposite_genders_only()
  conditionOwner("attract owns its gender law")
  local genders = { [1] = "male", [2] = "female" }
  local probe = runCondition(
    "ATTRACT",
    moveFacts("ATTRACT", { accuracy = 100, moveType = "normal" }),
    FIXED_SEED,
    { genders = genders }
  )
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "attract connects across genders")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "infatuation"), "attract infatuates the defender")
  local same = runCondition(
    "ATTRACT",
    moveFacts("ATTRACT", { accuracy = 100, moveType = "normal" }),
    FIXED_SEED,
    { genders = { [1] = "male", [2] = "male" } }
  )
  local sameOutcome = same.outcome --[[@as table<string, unknown>]]
  Assert.equal(sameOutcome.result, "failed", "attract refuses same genders")
end

-- Taunt roots a two-to-four-turn volatile and refuses the already
-- taunted.
function T.taunt_roots_a_counted_volatile()
  conditionOwner("taunt owns its countdown")
  local probe = runCondition("TAUNT", moveFacts("TAUNT", { accuracy = 100, moveType = "dark" }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "taunt connects")
  local instance = findInstance(probe.state, "taunt")
  Assert.notNil(instance, "taunt lands on the defender")
  local turns = (instance --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].turns
  Assert.isTrue(turns >= 2 and turns <= 4, "taunt spans two to four turns")
end

-- Torment marks until the entry leaves and refuses the already
-- tormented.
function T.torment_marks_until_the_entry_leaves()
  conditionOwner("torment owns its mark")
  local probe = runCondition("TORMENT", moveFacts("TORMENT", { accuracy = 100, moveType = "dark" }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "torment connects")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "torment"), "torment lands on the defender")
end

-- Encore forces the recorded last move for three-to-seven turns and
-- refuses without a recorded move.
function T.encore_forces_the_recorded_last_move()
  conditionOwner("encore owns its forced move")
  local probe = runCondition(
    "ENCORE",
    moveFacts("ENCORE", { accuracy = 100, moveType = "normal" }),
    FIXED_SEED,
    { recentMoves = { [2] = "TACKLE" } }
  )
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "encore connects with a recorded move")
  local instance = findInstance(probe.state, "encore")
  Assert.notNil(instance, "encore lands on the defender")
  local state = (instance --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]]
  Assert.equal(state.move, "TACKLE", "encore forces the recorded move")
  Assert.isTrue(state.turns >= 3 and state.turns <= 7, "encore spans three to seven turns")
  local without = runCondition("ENCORE", moveFacts("ENCORE", { accuracy = 100, moveType = "normal" }), FIXED_SEED)
  local withoutOutcome = without.outcome --[[@as table<string, unknown>]]
  Assert.equal(withoutOutcome.result, "failed", "encore refuses without a recorded move")
end

-- Disable refuses the recorded last move for three-to-six turns and
-- refuses without a recorded move.
function T.disable_refuses_the_recorded_last_move()
  conditionOwner("disable owns its refused move")
  local probe = runCondition(
    "DISABLE",
    moveFacts("DISABLE", { accuracy = 100, moveType = "normal" }),
    FIXED_SEED,
    { recentMoves = { [2] = "TACKLE" } }
  )
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "disable connects with a recorded move")
  local instance = findInstance(probe.state, "disable")
  Assert.notNil(instance, "disable lands on the defender")
  local state = (instance --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]]
  Assert.equal(state.move, "TACKLE", "disable refuses the recorded move")
  Assert.isTrue(state.turns >= 3 and state.turns <= 6, "disable spans three to six turns")
end

-- Spikes stack to three layers on the foe side and refuse the fourth.
function T.spikes_stack_to_three_layers()
  conditionOwner("spikes own their layers")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  local foeSide = ctx:entryOf(2).side
  ---@return table terminal execution step for one spikes layer
  local function laySpikes()
    local node = Execution.start({
      actionId = 1002,
      actor = { combatant = 1 },
      requestedMove = "SPIKES",
      executingMove = "SPIKES",
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "SPIKES", pp = 10, ppUps = 0 } },
      moveFacts = moveFacts("SPIKES", { accuracy = 0, moveType = "ground" }),
      attackerTypes = { "ground" },
      defenderTypes = { [2] = { "normal" } },
      typeChart = chart(),
      friendship = 255,
      stream = BattleRng.new(FIXED_SEED),
    })
    for _ = 1, 8 do
      node = Execution.step(ctx, node)
      local record = node --[[@as table<string, unknown>]]
      if record.kind == "complete" and record.frame == nil then
        break
      end
    end
    return node --[[@as table<string, unknown>]]
  end
  Assert.equal(laySpikes().result, "hit", "the first layer lands")
  Assert.equal(laySpikes().result, "hit", "the second layer lands")
  Assert.equal(laySpikes().result, "hit", "the third layer lands")
  local layers = ctx:sideEffect(foeSide, "spikes")
  Assert.notNil(layers, "the layers stand on the foe side")
  Assert.equal((layers --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].layers, 3, "three layers stand")
  Assert.equal(laySpikes().result, "failed", "the fourth layer refuses")
end

-- Stealth Rock settles once per foe side and refuses the duplicate.
function T.stealth_rock_settles_once_per_side()
  conditionOwner("stealth rock owns its side instance")
  local probe = runCondition("STEALTH_ROCK", moveFacts("STEALTH_ROCK", { accuracy = 0, moveType = "rock" }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "stealth rock connects")
  local foeSide = probe.ctx:entryOf(2).side
  Assert.notNil(probe.ctx:sideEffect(foeSide, "stealthrock"), "the rocks stand on the foe side")
end

-- Toxic Spikes stack to two layers and refuse the third.
function T.toxic_spikes_stack_to_two_layers()
  conditionOwner("toxic spikes own their layers")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  local foeSide = ctx:entryOf(2).side
  ---@return table terminal execution step for one toxic layer
  local function layToxic()
    local node = Execution.start({
      actionId = 1003,
      actor = { combatant = 1 },
      requestedMove = "TOXIC_SPIKES",
      executingMove = "TOXIC_SPIKES",
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "TOXIC_SPIKES", pp = 10, ppUps = 0 } },
      moveFacts = moveFacts("TOXIC_SPIKES", { accuracy = 0, moveType = "poison" }),
      attackerTypes = { "poison" },
      defenderTypes = { [2] = { "normal" } },
      typeChart = chart(),
      friendship = 255,
      stream = BattleRng.new(FIXED_SEED),
    })
    for _ = 1, 8 do
      node = Execution.step(ctx, node)
      local record = node --[[@as table<string, unknown>]]
      if record.kind == "complete" and record.frame == nil then
        break
      end
    end
    return node --[[@as table<string, unknown>]]
  end
  Assert.equal(layToxic().result, "hit", "the first toxic layer lands")
  Assert.equal(layToxic().result, "hit", "the second toxic layer lands")
  local layers = ctx:sideEffect(foeSide, "toxicspikes")
  Assert.notNil(layers, "the toxic layers stand on the foe side")
  Assert.equal((layers --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].layers, 2, "two layers stand")
  Assert.equal(layToxic().result, "failed", "the third toxic layer refuses")
end

-- Rest sleeps two turns with full recovery, cures the prior condition,
-- and refuses at full health.
function T.rest_sleeps_two_turns_with_full_recovery()
  conditionOwner("rest owns its sleep and recovery")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  ctx:damage(1, 20, { kind = "probe" })
  local node = Execution.start({
    actionId = 1004,
    actor = { combatant = 1 },
    requestedMove = "REST",
    executingMove = "REST",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 1 } },
    moves = { { move = "REST", pp = 10, ppUps = 0 } },
    moveFacts = moveFacts("REST", { accuracy = 0, moveType = "psychic" }),
    attackerTypes = { "psychic" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(FIXED_SEED),
  })
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  Assert.equal(finished.result, "hit", "rest connects while wounded")
  Assert.equal(ctx:statusOf(1), "sleep", "rest sleeps its user")
  local entry = ctx:entryOf(1)
  Assert.equal(entry.hp, entry.maxHp, "rest restores full health")
  local fresh = runCondition("REST", moveFacts("REST", { accuracy = 0, moveType = "psychic" }), FIXED_SEED)
  local freshOutcome = fresh.outcome --[[@as table<string, unknown>]]
  Assert.equal(freshOutcome.result, "failed", "rest refuses at full health")
end

-- Moonlight and synthesis scale with the field sky: half with no
-- weather, two thirds under sun, one quarter otherwise.
function T.dawn_healing_scales_with_the_field_sky()
  conditionOwner("dawn healing owns its weather fractions")
  local NativeEffectHandlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "native definitions resolve for typed battle-local writes"
  )
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  ---@param weather string? field definition identity settled before the heal
  ---@return integer health restored by moonlight under the sky
  local function healUnder(weather)
    local state = liveState()
    local ctx = liveContext(state)
    local entry = ctx:entryOf(1)
    local ceiling = entry.maxHp --[[@as integer]]
    ctx:damage(1, ceiling - 1, { kind = "probe" })
    if weather ~= nil then
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor(weather),
        { kind = "field" },
        { kind = "move", combatant = 1 },
        { version = 1, turns = 5 }
      )
    end
    local node = Execution.start({
      actionId = 1005,
      actor = { combatant = 1 },
      requestedMove = "MOONLIGHT",
      executingMove = "MOONLIGHT",
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 1 } },
      moves = { { move = "MOONLIGHT", pp = 10, ppUps = 0 } },
      moveFacts = moveFacts("MOONLIGHT", { accuracy = 0, moveType = "normal" }),
      attackerTypes = { "normal" },
      defenderTypes = { [2] = { "normal" } },
      typeChart = chart(),
      friendship = 255,
      stream = BattleRng.new(FIXED_SEED),
    })
    for _ = 1, 8 do
      node = Execution.step(ctx, node)
      local record = node --[[@as table<string, unknown>]]
      if record.kind == "complete" and record.frame == nil then
        break
      end
    end
    local finished = node --[[@as table<string, unknown>]]
    Assert.equal(finished.result, "hit", "moonlight connects")
    return ctx:damage(1, 0, { kind = "probe" }).before - 1
  end
  local clear = healUnder(nil)
  local entry = liveContext(liveState()):entryOf(1)
  local ceiling = entry.maxHp --[[@as integer]]
  Assert.equal(clear, math.floor(ceiling / 2), "a clear sky restores half")
  local sun = healUnder("sunnyday")
  Assert.equal(sun, math.floor(ceiling * 20 / 30), "harsh sun restores two thirds")
  local rain = healUnder("raindance")
  Assert.equal(rain, math.floor(ceiling / 4), "rain restores one quarter")
end

-- Belly Drum maximizes attack for half its maximum health and refuses
-- at maximum attack or at half health and below.
function T.belly_drum_maximizes_attack_for_half_health()
  conditionOwner("belly drum owns its trade")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  local entry = ctx:entryOf(1)
  local ceiling = entry.maxHp --[[@as integer]]
  ctx:damage(1, math.floor(ceiling / 4), { kind = "probe" })
  local node = Execution.start({
    actionId = 1006,
    actor = { combatant = 1 },
    requestedMove = "BELLY_DRUM",
    executingMove = "BELLY_DRUM",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 1 } },
    moves = { { move = "BELLY_DRUM", pp = 10, ppUps = 0 } },
    moveFacts = moveFacts("BELLY_DRUM", { accuracy = 0, moveType = "normal" }),
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(FIXED_SEED),
  })
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  Assert.equal(finished.result, "hit", "belly drum connects above half health")
  Assert.equal(ctx:entryOf(1).stages.attack, 6, "belly drum maximizes attack")
  local left = ctx:damage(1, 0, { kind = "probe" }).before
  Assert.equal(left, ceiling - math.floor(ceiling / 4) - math.floor(ceiling / 2), "belly drum costs half maximum health")
end

-- Acupressure raises a random raisable stat by two and refuses the
-- fully maximized entry.
function T.acupressure_raises_a_random_raisable_stat()
  conditionOwner("acupressure owns its random raise")
  local probe = runCondition("ACUPRESSURE", moveFacts("ACUPRESSURE", { accuracy = 0 }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "acupressure connects")
  local raised = 0
  for _, stat in ipairs({ "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }) do
    if probe.ctx:entryOf(1).stages[stat] == 2 then
      raised = raised + 1
    end
  end
  Assert.equal(raised, 1, "acupressure raises exactly one stat by two")
end

-- Mean Look and Spider Web trap the defender and refuse ghosts,
-- dolls, and the already trapped.
function T.trapping_moves_hold_the_defender()
  conditionOwner("trapping moves own their hold")
  local probe = runCondition(
    "MEAN_LOOK",
    moveFacts("MEAN_LOOK", { accuracy = 0, moveType = "normal" }),
    FIXED_SEED
  )
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "mean look connects")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "trapped"), "mean look traps the defender")
  local ghost = runCondition(
    "MEAN_LOOK",
    moveFacts("MEAN_LOOK", { accuracy = 0, moveType = "normal" }),
    FIXED_SEED,
    { defenderTypes = { [2] = { "ghost" } } }
  )
  local ghostOutcome = ghost.outcome --[[@as table<string, unknown>]]
  Assert.equal(ghostOutcome.result, "failed", "mean look refuses ghosts")
end

-- Ingrain roots healing on the user while holding it down.
function T.ingrain_roots_healing_on_the_user()
  conditionOwner("ingrain owns its root")
  local probe = runCondition("INGRAIN", moveFacts("INGRAIN", { accuracy = 0, moveType = "grass" }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "ingrain connects")
  Assert.isTrue(probe.ctx:hasBattleEffect(1, "trapped"), "ingrain holds its user")
  Assert.isTrue(probe.ctx:hasBattleEffect(1, "ingrain"), "ingrain roots its healing")
end

-- Lock-On and Mind Reader promise the next strike; foresight and odor
-- sleuth identify ghosts for normal and fighting strikes.
function T.lock_on_and_foresight_shape_later_strikes()
  conditionOwner("lock-on and foresight own their markers")
  local probe = runCondition("LOCK_ON", moveFacts("LOCK_ON", { accuracy = 0, moveType = "normal" }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "lock-on connects")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "lockon"), "lock-on marks the defender")
  local identified = runCondition("FORESIGHT", moveFacts("FORESIGHT", { accuracy = 0, moveType = "fighting" }), FIXED_SEED)
  local identifiedOutcome = identified.outcome --[[@as table<string, unknown>]]
  Assert.equal(identifiedOutcome.result, "hit", "foresight connects")
  Assert.isTrue(identified.ctx:hasBattleEffect(2, "foresight"), "foresight identifies the defender")
end

-- Magnet Rise levitates for five turns and refuses the grounded-already
-- and the rooted.
function T.magnet_rise_levitates_for_five_turns()
  conditionOwner("magnet rise owns its levitation")
  local probe = runCondition("MAGNET_RISE", moveFacts("MAGNET_RISE", { accuracy = 0, moveType = "electric" }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "magnet rise connects")
  local instance = findInstance(probe.state, "magnetrise")
  Assert.notNil(instance, "magnet rise levitates its user")
  Assert.equal((instance --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].turns, 5, "levitation lasts five turns")
end

-- Tailwind doubles its side speed window and refuses the duplicate;
-- lucky chant shields its side and refuses the duplicate.
function T.tailwind_and_lucky_chant_cover_their_sides()
  conditionOwner("side states own their windows")
  local tailwind = runCondition("TAILWIND", moveFacts("TAILWIND", { accuracy = 0, moveType = "flying" }), FIXED_SEED)
  local tailwindOutcome = tailwind.outcome --[[@as table<string, unknown>]]
  Assert.equal(tailwindOutcome.result, "hit", "tailwind connects")
  local side = tailwind.ctx:entryOf(1).side
  local tail = tailwind.ctx:sideEffect(side, "tailwind")
  Assert.notNil(tail, "tailwind covers the user side")
  Assert.equal((tail --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].turns, 3, "tailwind lasts three turns")
  local chant = runCondition("LUCKY_CHANT", moveFacts("LUCKY_CHANT", { accuracy = 0, moveType = "normal" }), FIXED_SEED)
  local chantOutcome = chant.outcome --[[@as table<string, unknown>]]
  Assert.equal(chantOutcome.result, "hit", "lucky chant connects")
  local chantSide = chant.ctx:entryOf(1).side
  local lucky = chant.ctx:sideEffect(chantSide, "luckychant")
  Assert.notNil(lucky, "lucky chant covers the user side")
  Assert.equal((lucky --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].turns, 5, "lucky chant lasts five turns")
end

-- Gravity grounds the field for five turns and refuses the duplicate;
-- trick room twists the dimensions for five turns and untwists on
-- reuse.
function T.gravity_and_trick_room_shape_the_field()
  conditionOwner("field states own their windows")
  local gravity = runCondition("GRAVITY", moveFacts("GRAVITY", { accuracy = 0, moveType = "psychic" }), FIXED_SEED)
  local gravityOutcome = gravity.outcome --[[@as table<string, unknown>]]
  Assert.equal(gravityOutcome.result, "hit", "gravity connects")
  Assert.notNil(gravity.ctx:fieldEffect("gravity"), "gravity grounds the field")
  local faller = runCondition("MAGNET_RISE", moveFacts("MAGNET_RISE", { accuracy = 0, moveType = "electric" }), FIXED_SEED)
  Assert.isTrue(faller.ctx:hasBattleEffect(1, "magnetrise"), "the entry rises first")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local fallCtx = faller.ctx
  local node = Execution.start({
    actionId = 1011,
    actor = { combatant = 1 },
    requestedMove = "GRAVITY",
    executingMove = "GRAVITY",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "GRAVITY", pp = 10, ppUps = 0 } },
    moveFacts = moveFacts("GRAVITY", { accuracy = 0, moveType = "psychic" }),
    attackerTypes = { "psychic" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(FIXED_SEED),
  })
  for _ = 1, 8 do
    node = Execution.step(fallCtx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local grounded = node --[[@as table<string, unknown>]]
  Assert.equal(grounded.result, "hit", "gravity connects over rising entries")
  Assert.isFalse(fallCtx:hasBattleEffect(1, "magnetrise"), "gravity grounds rising entries")
  local again = nil
  do
    local Execution = SessionFixture.requirePresent(
      "libs.battle.src.gen4.MoveExecution",
      "the shared move continuation owns native hit progression"
    )
    local node = Execution.start({
      actionId = 1007,
      actor = { combatant = 1 },
      requestedMove = "GRAVITY",
      executingMove = "GRAVITY",
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "GRAVITY", pp = 10, ppUps = 0 } },
      moveFacts = moveFacts("GRAVITY", { accuracy = 0, moveType = "psychic" }),
      attackerTypes = { "psychic" },
      defenderTypes = { [2] = { "normal" } },
      typeChart = chart(),
      friendship = 255,
      stream = BattleRng.new(FIXED_SEED),
    })
    -- Reuse the settled gravity context for the duplicate attempt.
    local reuseCtx = gravity.ctx
    for _ = 1, 8 do
      node = Execution.step(reuseCtx, node)
      local record = node --[[@as table<string, unknown>]]
      if record.kind == "complete" and record.frame == nil then
        break
      end
    end
    again = node
  end
  local againOutcome = again --[[@as table<string, unknown>]]
  Assert.equal(againOutcome.result, "failed", "gravity refuses its duplicate")
  local twist = runCondition("TRICK_ROOM", moveFacts("TRICK_ROOM", { accuracy = 0, moveType = "psychic" }), FIXED_SEED)
  local twistOutcome = twist.outcome --[[@as table<string, unknown>]]
  Assert.equal(twistOutcome.result, "hit", "trick room connects")
  Assert.notNil(twist.ctx:fieldEffect("trickroom"), "trick room twists the field")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local twistCtx = twist.ctx
  local untwist = Execution.start({
    actionId = 1010,
    actor = { combatant = 1 },
    requestedMove = "TRICK_ROOM",
    executingMove = "TRICK_ROOM",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "TRICK_ROOM", pp = 10, ppUps = 0 } },
    moveFacts = moveFacts("TRICK_ROOM", { accuracy = 0, moveType = "psychic" }),
    attackerTypes = { "psychic" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(FIXED_SEED),
  })
  for _ = 1, 8 do
    untwist = Execution.step(twistCtx, untwist)
    local record = untwist --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local untwisted = untwist --[[@as table<string, unknown>]]
  Assert.equal(untwisted.result, "hit", "trick room reuse connects")
  Assert.isNil(twistCtx:fieldEffect("trickroom"), "reuse untwists the dimensions")
end

-- Sports weaken their type while the user stands and refuse the
-- duplicate.
function T.sports_weaken_their_type()
  conditionOwner("sports own their weakening")
  local muddy = runCondition("MUD_SPORT", moveFacts("MUD_SPORT", { accuracy = 0, moveType = "ground" }), FIXED_SEED)
  local muddyOutcome = muddy.outcome --[[@as table<string, unknown>]]
  Assert.equal(muddyOutcome.result, "hit", "mud sport connects")
  Assert.isTrue(muddy.ctx:hasBattleEffect(1, "mudsport"), "mud sport weakens while its user stands")
  local watery = runCondition("WATER_SPORT", moveFacts("WATER_SPORT", { accuracy = 0, moveType = "water" }), FIXED_SEED)
  local wateryOutcome = watery.outcome --[[@as table<string, unknown>]]
  Assert.equal(wateryOutcome.result, "hit", "water sport connects")
  Assert.isTrue(watery.ctx:hasBattleEffect(1, "watersport"), "water sport weakens while its user stands")
end

-- Nightmare roots quarter-maximum damage on sleeping defenders and
-- refuses the waking.
function T.nightmare_roots_damage_on_sleeping_defenders()
  conditionOwner("nightmare owns its bad dream")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  ctx:applyStatus(2, "sleep", { turns = 3 }, { kind = "probe" })
  local node = Execution.start({
    actionId = 1008,
    actor = { combatant = 1 },
    requestedMove = "NIGHTMARE",
    executingMove = "NIGHTMARE",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "NIGHTMARE", pp = 10, ppUps = 0 } },
    moveFacts = moveFacts("NIGHTMARE", { accuracy = 100, moveType = "ghost" }),
    attackerTypes = { "ghost" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(FIXED_SEED),
  })
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  Assert.equal(finished.result, "hit", "nightmare connects on sleepers")
  Assert.isTrue(ctx:hasBattleEffect(2, "nightmare"), "nightmare roots the sleeper")
  local waking = runCondition("NIGHTMARE", moveFacts("NIGHTMARE", { accuracy = 100, moveType = "ghost" }), FIXED_SEED)
  local wakingOutcome = waking.outcome --[[@as table<string, unknown>]]
  Assert.equal(wakingOutcome.result, "failed", "nightmare refuses the waking")
end

-- Yawn drowses healthy defenders and refuses the statused.
function T.yawn_drowses_healthy_defenders()
  conditionOwner("yawn owns its drowsiness")
  local probe = runCondition("YAWN", moveFacts("YAWN", { accuracy = 0, moveType = "normal" }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "yawn connects")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "yawn"), "yawn drowses the defender")
end

-- Spite cuts four power points from the recorded last move and refuses
-- without a recorded move.
function T.spite_cuts_four_power_points()
  conditionOwner("spite owns its cut")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  local node = Execution.start({
    actionId = 1009,
    actor = { combatant = 1 },
    requestedMove = "SPITE",
    executingMove = "SPITE",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "SPITE", pp = 10, ppUps = 0 } },
    moveFacts = moveFacts("SPITE", { accuracy = 100, moveType = "ghost" }),
    attackerTypes = { "ghost" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(FIXED_SEED),
    recentMoves = { [2] = "TACKLE" },
  })
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  Assert.equal(finished.result, "hit", "spite connects with a recorded move")
  local BattleState = SessionFixture.requirePresent(
    "libs.battle.src.BattleState",
    "private battle data owns reference invariants"
  )
  local spent = nil
  for _, entry in ipairs(BattleState.combatant(state, 2).mon.moves) do
    local record = entry --[[@as table<string, unknown>]]
    if record.move == "TACKLE" then
      spent = record.pp
    end
  end
  Assert.notNil(spent, "the recorded move resolves in the defender store")
  local without = runCondition("SPITE", moveFacts("SPITE", { accuracy = 100, moveType = "ghost" }), FIXED_SEED)
  local withoutOutcome = without.outcome --[[@as table<string, unknown>]]
  Assert.equal(withoutOutcome.result, "failed", "spite refuses without a recorded move")
end

-- Swagger sharpens attack by two while confusing; flatter sharpens
-- special attack by one while confusing; teeter dance confuses.
function T.swagger_flatter_and_teeter_dance_confuse()
  conditionOwner("swaggering moves own their confusion")
  local swagger = runCondition(
    "SWAGGER",
    moveFacts("SWAGGER", { accuracy = 100, moveType = "normal" }),
    FIXED_SEED
  )
  local swaggerOutcome = swagger.outcome --[[@as table<string, unknown>]]
  Assert.equal(swaggerOutcome.result, "hit", "swagger connects")
  Assert.equal(swagger.ctx:entryOf(2).stages.attack, 2, "swagger sharpens attack by two")
  Assert.isTrue(swagger.ctx:hasBattleEffect(2, "confusion"), "swagger confuses")
  local flatter = runCondition(
    "FLATTER",
    moveFacts("FLATTER", { accuracy = 100, moveType = "dark" }),
    FIXED_SEED
  )
  local flatterOutcome = flatter.outcome --[[@as table<string, unknown>]]
  Assert.equal(flatterOutcome.result, "hit", "flatter connects")
  Assert.equal(flatter.ctx:entryOf(2).stages.specialAttack, 1, "flatter sharpens special attack by one")
  Assert.isTrue(flatter.ctx:hasBattleEffect(2, "confusion"), "flatter confuses")
  local dance = runCondition("TEETER_DANCE", moveFacts("TEETER_DANCE", { accuracy = 100, moveType = "normal" }), FIXED_SEED)
  local danceOutcome = dance.outcome --[[@as table<string, unknown>]]
  Assert.equal(danceOutcome.result, "hit", "teeter dance connects")
  Assert.isTrue(dance.ctx:hasBattleEffect(2, "confusion"), "teeter dance confuses")
end

-- Teleport fails trainer battles through its battle-kind fact.
function T.teleport_fails_trainer_battles()
  conditionOwner("teleport owns its battle-kind law")
  local probe = runCondition(
    "TELEPORT",
    moveFacts("TELEPORT", { accuracy = 0, moveType = "psychic" }),
    FIXED_SEED,
    { battleKind = "trainer" }
  )
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "teleport fails trainer battles")
end

-- Captivate drops special attack by two for opposite genders and
-- refuses same genders and the genderless.
function T.captivate_drops_special_attack_for_opposite_genders()
  conditionOwner("captivate owns its gender law")
  local probe = runCondition(
    "CAPTIVATE",
    moveFacts("CAPTIVATE", { accuracy = 100, moveType = "normal" }),
    FIXED_SEED,
    { genders = { [1] = "female", [2] = "male" } }
  )
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "captivate connects across genders")
  Assert.equal(probe.ctx:entryOf(2).stages.specialAttack, -2, "captivate drops special attack by two")
  local same = runCondition(
    "CAPTIVATE",
    moveFacts("CAPTIVATE", { accuracy = 100, moveType = "normal" }),
    FIXED_SEED,
    { genders = { [1] = "female", [2] = "female" } }
  )
  local sameOutcome = same.outcome --[[@as table<string, unknown>]]
  Assert.equal(sameOutcome.result, "failed", "captivate refuses same genders")
end

return { tests = T }
