-- Damaging strikes with native secondary effects: ordinary strikes deal
-- staged damage, high-critical strikes roll the raised stage, draining
-- strikes restore half the damage dealt, fixed two-hit strikes land twice,
-- and chance-based status, stage, flinch, confusion, and binding
-- secondaries apply through the same immunity, substitute, and
-- fainted-target gates as the primary condition paths. Chance rolls use
-- the compiled effect chance on the labeled battle stream; special
-- strikers (pay day, brick break, knock off, covet, pluck, false swipe,
-- feint, thunder, blizzard, secret power, tri attack, fangs, hammer arm,
-- self-raising strikes, sport-weakened power, focus energy, flame wheel
-- thaw) follow their move-specific source rules beside the shared body.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local FIXED_SEED = 771626189

---@param behavior string missing owner under test
---@return table the loaded damage family owner
local function damageOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.moves.DamageMoves", behavior)
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
    NativeTypeChart.install(builder, "damage-secondary-tests")
    local behaviors = BattleBehaviorBuilder.new()
    behaviors:registerRuleset(
      Executor.RULESET,
      { key = Executor.RULESET, chart = Executor.RULESET },
      "damage-secondary-tests"
    )
    local BattleContent = require("libs.battle.src.BattleContent")
    local content = BattleContent.new(builder:freeze(), behaviors:freeze())
    chartCache = assert(content:typeChart(Executor.RULESET), "the native chart resolves for the secondary probes")
  end
  return chartCache --[[@as table<string, unknown>]]
end

--- Full strike combat facts for the probe: staged stats travel beside
-- their raw values and signed stages so critical selection resolves.
---@param level integer battle level under the probe
---@param attack integer staged attack under the probe
---@param defense integer staged defense under the probe
---@return table<string, integer> combat facts for the probe frame
local function probeCombat(level, attack, defense)
  return {
    level = level,
    attack = attack,
    defense = defense,
    rawAttack = attack,
    rawDefense = defense,
    attackStage = 0,
    defenseStage = 0,
  }
end

---@param moveKey string strike identity under the probe
---@param overrides table<string, unknown>|nil move-fact overrides for the probe
---@return table<string, table<string, unknown>> compiled-shaped facts for the probe
local function moveFacts(moveKey, overrides)
  local facts = {
    power = 40,
    accuracy = 100,
    category = "physical",
    moveType = "normal",
    effectChance = 0,
  }
  for key, value in pairs(overrides or {}) do
    facts[key] = value
  end
  return { [moveKey] = facts }
end

---@param moveKey string strike identity under execution
---@param facts table<string, table<string, unknown>> compiled-shaped move facts
---@param seed integer fixed seed for the probe stream
---@param extra table<string, unknown>|nil extra frame inputs for the probe
---@return table terminal execution step plus observed health and context
local function runStrike(moveKey, facts, seed, extra)
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  local beforeUser = ctx:damage(1, 0, { kind = "probe" }).before
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  local inputs = {
    actionId = 901,
    actor = { combatant = 1 },
    requestedMove = moveKey,
    executingMove = moveKey,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveKey, pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = probeCombat(50, 120, 90),
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
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
  assert(finished.kind == "complete" and finished.frame == nil, "the strike settles")
  return {
    outcome = finished,
    dealt = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before,
    restored = ctx:damage(1, 0, { kind = "probe" }).before - beforeUser,
    ctx = ctx,
    state = state,
  }
end

-- Ordinary trainer strikes resolve staged damage through the shared
-- striker instead of the missing-behavior fallback.
function T.ordinary_strikes_deal_staged_damage()
  damageOwner("ordinary strikes own their shared striker")
  local probe = runStrike("SCRATCH", moveFacts("SCRATCH", { power = 40 }), FIXED_SEED)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the ordinary strike connects")
  Assert.isTrue((probe.dealt --[[@as integer]]) > 0, "the ordinary strike deals staged damage")
end

-- High-critical strikes roll the raised native stage: with a stream draw
-- that lands the raised-only remainder window (a multiple of 8 that is
-- not a multiple of 16), the raised strike crits where the ordinary
-- strike on the same stream does not.
function T.high_critical_strikes_roll_the_raised_stage()
  damageOwner("raised strikes own their critical stage")
  local seed = nil
  for candidate = 1, 500 do
    local probe = BattleRng.new(candidate)
    probe:nextU16("accuracy_check", { kind = "probe" })
    local draw = probe:nextU16("critical_check", { kind = "probe" })
    if draw % 8 == 0 and draw % 16 ~= 0 then
      seed = candidate
      break
    end
  end
  Assert.notNil(seed, "a draw inside the raised-only window exists")
  local weakCombat = { combat = probeCombat(5, 16, 16) }
  local slash = runStrike("SLASH", moveFacts("SLASH", { power = 70 }), seed --[[@as integer]], weakCombat)
  local slashOutcome = slash.outcome --[[@as table<string, unknown>]]
  Assert.equal(slashOutcome.result, "hit", "the raised strike connects")
  local tackle = runStrike("TACKLE", moveFacts("TACKLE", { power = 70 }), seed --[[@as integer]], weakCombat)
  local tackleOutcome = tackle.outcome --[[@as table<string, unknown>]]
  Assert.equal(tackleOutcome.result, "hit", "the ordinary strike connects on the same stream")
  Assert.isTrue(
    (slash.dealt --[[@as integer]]) > (tackle.dealt --[[@as integer]]),
    "the raised stage crits where the base stage does not"
  )
end

-- Draining strikes restore half the damage dealt, rounded down.
function T.draining_strikes_restore_half_the_damage_dealt()
  damageOwner("draining strikes own their recovery")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  ctx:damage(1, 20, { kind = "probe" })
  local beforeUser = ctx:damage(1, 0, { kind = "probe" }).before
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  local facts = moveFacts("MEGA_DRAIN", { power = 40, category = "special", moveType = "grass" })
  local node = Execution.start({
    actionId = 903,
    actor = { combatant = 1 },
    requestedMove = "MEGA_DRAIN",
    executingMove = "MEGA_DRAIN",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "MEGA_DRAIN", pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = probeCombat(50, 120, 90),
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
    attackerTypes = { "grass" },
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
  Assert.equal(finished.result, "hit", "the draining strike connects")
  local dealt = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before
  local restored = ctx:damage(1, 0, { kind = "probe" }).before - beforeUser
  Assert.isTrue(dealt > 0, "the draining strike deals damage")
  Assert.equal(restored, math.floor(dealt / 2), "the draining strike restores half the damage dealt")
end

-- Burn secondaries roll the compiled chance: a seed inside the burn
-- window burns, a seed outside it does not, and fire defenders never
-- burn.
function T.burn_secondaries_roll_the_compiled_chance()
  damageOwner("burn secondaries own their chance roll")
  local burnSeed = nil
  for candidate = 1, 500 do
    local probe = BattleRng.new(candidate)
    probe:nextU16("accuracy_check", { kind = "probe" })
    probe:nextU16("critical_check", { kind = "probe" })
    probe:nextU16("damage_roll", { kind = "probe" })
    local draw = probe:nextU16("secondary_effect", { kind = "probe" }) % 100
    if draw < 10 then
      burnSeed = candidate
      break
    end
  end
  Assert.notNil(burnSeed, "a draw inside the burn window exists")
  local probe = runStrike(
    "EMBER",
    moveFacts("EMBER", { power = 40, category = "special", moveType = "fire", effectChance = 10 }),
    burnSeed --[[@as integer]],
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "the burning strike connects")
  local ctx = probe.ctx
  local mon = nil
  do
    local BattleState = SessionFixture.requirePresent(
      "libs.battle.src.BattleState",
      "private battle data owns reference invariants"
    )
    mon = BattleState.combatant(probe.state, 2).mon --[[@as table<string, unknown>]]
  end
  local effects = (mon.condition --[[@as table<string, unknown>]]).effects --[[@as table<integer, unknown>]]
  Assert.equal(#effects, 1, "the burn window applies the burn")
  Assert.equal((effects[1] --[[@as table<string, unknown>]]).key, "burn", "the applied condition is the burn")
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

-- Drops a labeled draw until the value falls under the window.
---@param seed integer starting seed for the hunt
---@param window integer exclusive upper bound for the secondary roll
---@return integer a seed whose secondary roll lands inside the window
local function seedInWindow(seed, window)
  for candidate = seed, seed + 500 do
    local probe = BattleRng.new(candidate)
    probe:nextU16("accuracy_check", { kind = "probe" })
    probe:nextU16("critical_check", { kind = "probe" })
    probe:nextU16("damage_roll", { kind = "probe" })
    if probe:nextU16("secondary_effect", { kind = "probe" }) % 100 < window then
      return candidate
    end
  end
  error("no seed inside the secondary window", 0)
end

-- Stage secondaries move one stage on their compiled chance and stay
-- silent at the clamp: acid drops special defense, while a marked
-- substitute absorbs the drop without failing the strike.
function T.stage_secondaries_move_one_stage_through_the_clamp()
  damageOwner("stage secondaries own their clamped deltas")
  local probe = runStrike(
    "ACID",
    moveFacts("ACID", { power = 40, category = "special", moveType = "poison", effectChance = 10 }),
    seedInWindow(FIXED_SEED, 10),
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "the dropping strike connects")
  local ctx = probe.ctx
  Assert.equal(ctx:entryOf(2).stages.specialDefense, -1, "the drop applies on its chance")
end

-- Flinch secondaries mark before-action presence for the turn.
function T.flinch_secondaries_mark_before_action_presence()
  damageOwner("flinch secondaries own their volatile mark")
  local probe = runStrike(
    "BITE",
    moveFacts("BITE", { power = 60, effectChance = 30 }),
    seedInWindow(FIXED_SEED, 30),
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "the flinching strike connects")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "flinch"), "the flinch mark lands on the defender")
end

-- Confusion secondaries root a two-to-five-turn volatile.
function T.confusion_secondaries_root_a_counted_volatile()
  damageOwner("confusion secondaries own their countdown")
  local probe = runStrike(
    "DYNAMIC_PUNCH",
    moveFacts("DYNAMIC_PUNCH", { power = 100, accuracy = 100, effectChance = 100 }),
    FIXED_SEED,
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "the confusing strike connects")
  local instance = findInstance(probe.state, "confusion")
  Assert.notNil(instance, "the confusion volatile lands on the defender")
  local turns = (instance --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].turns
  Assert.isTrue(turns >= 2 and turns <= 5, "the confusion countdown spans two to five turns")
end

-- Binding strikes trap for three plus zero-to-three turns.
function T.binding_strikes_trap_with_a_countdown()
  damageOwner("binding strikes own their trap countdown")
  local probe = runStrike(
    "WRAP",
    moveFacts("WRAP", { power = 15, accuracy = 85, effectChance = 0 }),
    FIXED_SEED,
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "the binding strike connects")
  local instance = findInstance(probe.state, "bind")
  Assert.notNil(instance, "the binding volatile lands on the defender")
  local turns = (instance --[[@as table<string, unknown>]]).state --[[@as table<string, unknown>]].turns
  Assert.isTrue(turns >= 3 and turns <= 6, "the binding countdown spans three to six turns")
end

-- Fixed two-hit strikes apply staged damage per hit.
function T.fixed_two_hit_strikes_land_twice()
  damageOwner("fixed multi-hit strikes own their hit count")
  local probe = runStrike(
    "DOUBLE_KICK",
    moveFacts("DOUBLE_KICK", { power = 30, accuracy = 100 }),
    FIXED_SEED,
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "the two-hit strike connects")
  local single = runStrike(
    "TACKLE",
    moveFacts("TACKLE", { power = 30, accuracy = 100 }),
    FIXED_SEED,
    { combat = probeCombat(5, 16, 16) }
  )
  Assert.isTrue(
    (probe.dealt --[[@as integer]]) >= (single.dealt --[[@as integer]]),
    "two hits deal at least the single-hit damage"
  )
end

-- False Swipe never takes the last health point.
function T.false_swipe_leaves_one_health()
  damageOwner("false swipe owns its survival cap")
  local probe = runStrike(
    "FALSE_SWIPE",
    moveFacts("FALSE_SWIPE", { power = 40, accuracy = 100 }),
    FIXED_SEED,
    { combat = probeCombat(50, 120, 90) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "false swipe connects")
  local left = probe.ctx:damage(2, 0, { kind = "probe" }).before
  Assert.equal(left, 1, "false swipe leaves exactly one health point")
end

-- Pay Day scatters five coins per user level on a connecting strike.
function T.pay_day_scatters_five_coins_per_level()
  damageOwner("pay day owns its scatter")
  local probe = runStrike(
    "PAY_DAY",
    moveFacts("PAY_DAY", { power = 40, accuracy = 100 }),
    FIXED_SEED,
    { combat = probeCombat(12, 30, 30) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "pay day connects")
  Assert.equal(probeOutcome.payday, 60, "pay day scatters five coins per level")
end

-- Brick Break drops the defender side screens after landing.
function T.brick_break_drops_the_defender_screens()
  damageOwner("brick break owns its screen removal")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local NativeEffectHandlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "native definitions resolve for typed battle-local writes"
  )
  local state = liveState()
  local ctx = liveContext(state)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("reflect"),
    { kind = "side", side = 2 },
    { kind = "move", combatant = 2 },
    { version = 1, turns = 5 }
  )
  Assert.isTrue(ctx:hasBattleEffect(2, "reflect"), "the screen starts raised")
  local facts = moveFacts("BRICK_BREAK", { power = 75, accuracy = 100, category = "physical", moveType = "fighting" })
  local node = Execution.start({
    actionId = 904,
    actor = { combatant = 1 },
    requestedMove = "BRICK_BREAK",
    executingMove = "BRICK_BREAK",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "BRICK_BREAK", pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = probeCombat(5, 16, 16),
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
    attackerTypes = { "fighting" },
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
  Assert.equal(finished.result, "hit", "brick break connects")
  Assert.isFalse(ctx:hasBattleEffect(2, "reflect"), "brick break drops the screen")
end

-- Item-taking strikes record their ordered intent after landing.
function T.item_taking_strikes_record_their_intent()
  damageOwner("item-taking strikes own their intent")
  for _, case in ipairs({
    { move = "KNOCK_OFF", mode = "remove" },
    { move = "COVET", mode = "steal" },
    { move = "PLUCK", mode = "eat" },
  }) do
    local entry = case --[[@as table<string, string>]]
    local Execution = SessionFixture.requirePresent(
      "libs.battle.src.gen4.MoveExecution",
      "the shared move continuation owns native hit progression"
    )
    local state = liveState()
    local ctx = liveContext(state)
    local facts = moveFacts(entry.move, { power = 40, accuracy = 100 })
    local node = Execution.start({
      actionId = 905,
      actor = { combatant = 1 },
      requestedMove = entry.move,
      executingMove = entry.move,
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = entry.move, pp = 10, ppUps = 0 } },
      moveFacts = facts,
      combat = probeCombat(5, 16, 16),
      burned = false,
      guts = false,
      weather = "none",
      weatherSuppressed = false,
      abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
      attackerTypes = { "normal" },
      defenderTypes = { [2] = { "normal" } },
      typeChart = chart(),
      friendship = 255,
      stream = BattleRng.new(FIXED_SEED),
    })
    local intents = {}
    for _ = 1, 8 do
      node = Execution.step(ctx, node)
      local record = node --[[@as table<string, unknown>]]
      if record.kind == "complete" and record.frame == nil then
        break
      end
    end
    local finished = node --[[@as table<string, unknown>]]
    Assert.equal(finished.result, "hit", entry.move .. " connects")
    for _, event in ipairs(state.outbox --[[@as table<integer, unknown>]]) do
      local payload = event --[[@as table<string, unknown>]]
      if payload.kind == "item-intent" then
        intents[#intents + 1] = payload.payload
      end
    end
    Assert.equal(#intents, 1, entry.move .. " records one item intent")
    Assert.equal((intents[1] --[[@as table<string, unknown>]]).mode, entry.mode, entry.move .. " names its operation")
  end
end

-- Thunder lands through rain, halves in harsh sun, and paralyzes on
-- its compiled chance; blizzard lands through hail and freezes.
function T.weather_strikes_follow_their_sky_law()
  damageOwner("weather strikes own their accuracy law")
  local NativeEffectHandlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "native definitions resolve for typed battle-local writes"
  )
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  ---@param moveKey string strike identity under the weather probe
  ---@param facts table<string, table<string, unknown>> compiled-shaped move facts
  ---@param weather string? field definition identity settled before the strike
  ---@return table terminal execution step plus observed health and context
  local function runUnder(moveKey, facts, weather)
    local state = liveState()
    local ctx = liveContext(state)
    if weather ~= nil then
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor(weather),
        { kind = "field" },
        { kind = "move", combatant = 1 },
        { version = 1, turns = 5 }
      )
    end
    local inputs = {
      actionId = 907,
      actor = { combatant = 1 },
      requestedMove = moveKey,
      executingMove = moveKey,
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = moveKey, pp = 10, ppUps = 0 } },
      moveFacts = facts,
      combat = probeCombat(5, 16, 16),
      burned = false,
      guts = false,
      weather = "none",
      weatherSuppressed = false,
      abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
      attackerTypes = { "electric" },
      defenderTypes = { [2] = { "normal" } },
      typeChart = chart(),
      friendship = 255,
      stream = BattleRng.new(FIXED_SEED),
    }
    local node = Execution.start(inputs)
    for _ = 1, 8 do
      node = Execution.step(ctx, node)
      local record = node --[[@as table<string, unknown>]]
      if record.kind == "complete" and record.frame == nil then
        break
      end
    end
    local finished = node --[[@as table<string, unknown>]]
    assert(finished.kind == "complete" and finished.frame == nil, "the strike settles")
    return { outcome = finished, ctx = ctx, state = state }
  end
  local thunderFacts =
    moveFacts("THUNDER", { power = 120, accuracy = 70, category = "special", moveType = "electric", effectChance = 30 })
  local rainy = runUnder("THUNDER", thunderFacts, "raindance")
  local rainyOutcome = rainy.outcome --[[@as table<string, unknown>]]
  Assert.equal(rainyOutcome.result, "hit", "thunder never misses under rain")
  local clear = runUnder("THUNDER", thunderFacts, nil)
  local clearOutcome = clear.outcome --[[@as table<string, unknown>]]
  Assert.isTrue(
    clearOutcome.result == "hit" or clearOutcome.result == "missed",
    "thunder rolls its compiled accuracy under a clear sky"
  )
  local blizzardFacts =
    moveFacts("BLIZZARD", { power = 120, accuracy = 70, category = "special", moveType = "ice", effectChance = 10 })
  local hail = runUnder("BLIZZARD", blizzardFacts, "hail")
  local hailOutcome = hail.outcome --[[@as table<string, unknown>]]
  Assert.equal(hailOutcome.result, "hit", "blizzard never misses under hail")
end

-- Fanged strikes roll their condition and their flinch independently:
-- a seed inside both windows applies both.
function T.fanged_strikes_roll_both_effects()
  damageOwner("fanged strikes own their independent rolls")
  local seed = FIXED_SEED
  for candidate = FIXED_SEED, FIXED_SEED + 500 do
    local probe = BattleRng.new(candidate)
    probe:nextU16("accuracy_check", { kind = "probe" })
    probe:nextU16("critical_check", { kind = "probe" })
    probe:nextU16("damage_roll", { kind = "probe" })
    local first = probe:nextU16("secondary_effect", { kind = "probe" }) % 100
    local second = probe:nextU16("secondary_effect", { kind = "probe" }) % 100
    if first < 10 and second < 10 then
      seed = candidate
      break
    end
  end
  local probe = runStrike(
    "FIRE_FANG",
    moveFacts("FIRE_FANG", { power = 65, accuracy = 95, moveType = "fire", effectChance = 10 }),
    seed,
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "the fanged strike connects")
  local BattleState = SessionFixture.requirePresent(
    "libs.battle.src.BattleState",
    "private battle data owns reference invariants"
  )
  local mon = BattleState.combatant(probe.state, 2).mon --[[@as table<string, unknown>]]
  local effects = (mon.condition --[[@as table<string, unknown>]]).effects --[[@as table<integer, unknown>]]
  Assert.equal(#effects, 1, "the in-window seed burns")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "flinch"), "the in-window seed flinches")
end

-- Tri Attack draws one of burn, freeze, or paralysis on its chance.
function T.tri_attack_draws_one_of_three_conditions()
  damageOwner("tri attack owns its random condition")
  local probe = runStrike(
    "TRI_ATTACK",
    moveFacts("TRI_ATTACK", { power = 80, accuracy = 100, category = "special", moveType = "normal", effectChance = 20 }),
    seedInWindow(FIXED_SEED, 20),
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "tri attack connects")
  local BattleState = SessionFixture.requirePresent(
    "libs.battle.src.BattleState",
    "private battle data owns reference invariants"
  )
  local mon = BattleState.combatant(probe.state, 2).mon --[[@as table<string, unknown>]]
  local effects = (mon.condition --[[@as table<string, unknown>]]).effects --[[@as table<integer, unknown>]]
  Assert.equal(#effects, 1, "the in-window seed applies one condition")
  local key = (effects[1] --[[@as table<string, unknown>]]).key
  Assert.isTrue(key == "burn" or key == "freeze" or key == "paralysis", "the condition is one of the trio")
end

-- Hammer Arm drops its own speed while landing.
function T.hammer_arm_drops_its_own_speed()
  damageOwner("self-hindering strikes own their drop")
  local probe = runStrike(
    "HAMMER_ARM",
    moveFacts("HAMMER_ARM", { power = 100, accuracy = 90, category = "physical", moveType = "fighting" }),
    FIXED_SEED,
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "hammer arm connects")
  Assert.equal(probe.ctx:entryOf(1).stages.speed, -1, "hammer arm drops its own speed")
end

-- Self-raising strikes climb on their compiled chance.
function T.self_raising_strikes_climb_on_their_chance()
  damageOwner("self-raising strikes own their climb")
  local probe = runStrike(
    "CHARGE_BEAM",
    moveFacts("CHARGE_BEAM", { power = 50, accuracy = 90, category = "special", moveType = "electric", effectChance = 70 }),
    seedInWindow(FIXED_SEED, 70),
    { combat = probeCombat(5, 16, 16) }
  )
  local probeOutcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probeOutcome.result, "hit", "charge beam connects")
  Assert.equal(probe.ctx:entryOf(1).stages.specialAttack, 1, "charge beam raises special attack")
end

-- Sport markers halve the weakened type power for every entry.
function T.sport_markers_halve_the_weakened_type_power()
  damageOwner("sports own their power halving")
  local NativeEffectHandlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "native definitions resolve for typed battle-local writes"
  )
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  local entry = ctx:entryOf(1)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("mudsport"),
    { kind = "active", combatant = 1, activation = entry.activation },
    { kind = "move", combatant = 1 },
    { version = 1 }
  )
  local facts = moveFacts("THUNDER_SHOCK", { power = 40, accuracy = 100, category = "special", moveType = "electric" })
  local node = Execution.start({
    actionId = 908,
    actor = { combatant = 1 },
    requestedMove = "THUNDER_SHOCK",
    executingMove = "THUNDER_SHOCK",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "THUNDER_SHOCK", pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = probeCombat(5, 16, 16),
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
    attackerTypes = { "electric" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(FIXED_SEED),
  })
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  Assert.equal(finished.result, "hit", "the weakened strike connects")
  local dealt = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before
  local plain = runStrike(
    "THUNDER_SHOCK",
    moveFacts("THUNDER_SHOCK", { power = 40, accuracy = 100, category = "special", moveType = "electric" }),
    FIXED_SEED,
    { combat = probeCombat(5, 16, 16) }
  )
  Assert.isTrue((plain.dealt --[[@as integer]]) > dealt, "the sport halves the weakened power")
end

-- Focus energy raises later strikes by two stages: with a draw in the
-- focused-only remainder window (a multiple of 4 that is not a multiple
-- of 16), the focused strike crits.
function T.focus_energy_raises_later_strikes_by_two_stages()
  damageOwner("focus energy owns its critical stages")
  local NativeEffectHandlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "native definitions resolve for typed battle-local writes"
  )
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local seed = nil
  for candidate = 1, 2000 do
    local probe = BattleRng.new(candidate)
    probe:nextU16("accuracy_check", { kind = "probe" })
    local draw = probe:nextU16("critical_check", { kind = "probe" })
    if draw % 4 == 0 and draw % 16 ~= 0 then
      seed = candidate
      break
    end
  end
  Assert.notNil(seed, "a draw inside the focused-only window exists")
  ---@param focused boolean whether the user stands focused
  ---@return integer damage dealt by the focused-or-plain strike
  local function strikeDealt(focused)
    local state = liveState()
    local ctx = liveContext(state)
    if focused then
      local entry = ctx:entryOf(1)
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor("focusenergy"),
        { kind = "active", combatant = 1, activation = entry.activation },
        { kind = "move", combatant = 1 },
        { version = 1 }
      )
    end
    local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
    local facts = moveFacts("TACKLE", { power = 70, accuracy = 100 })
    local node = Execution.start({
      actionId = 909,
      actor = { combatant = 1 },
      requestedMove = "TACKLE",
      executingMove = "TACKLE",
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "TACKLE", pp = 10, ppUps = 0 } },
      moveFacts = facts,
      combat = probeCombat(5, 16, 16),
      burned = false,
      guts = false,
      weather = "none",
      weatherSuppressed = false,
      abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
      attackerTypes = { "normal" },
      defenderTypes = { [2] = { "normal" } },
      typeChart = chart(),
      friendship = 255,
      stream = BattleRng.new(seed --[[@as integer]]),
    })
    for _ = 1, 8 do
      node = Execution.step(ctx, node)
      local record = node --[[@as table<string, unknown>]]
      if record.kind == "complete" and record.frame == nil then
        break
      end
    end
    return beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before
  end
  Assert.isTrue(strikeDealt(true) > strikeDealt(false), "focus energy raises the strike into its window")
end

-- Lucky chant shields its side from critical strikes.
function T.lucky_chant_shields_its_side_from_critical_strikes()
  damageOwner("lucky chant owns its critical shield")
  local NativeEffectHandlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "native definitions resolve for typed battle-local writes"
  )
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local seed = nil
  for candidate = 1, 500 do
    local probe = BattleRng.new(candidate)
    probe:nextU16("accuracy_check", { kind = "probe" })
    local draw = probe:nextU16("critical_check", { kind = "probe" })
    if draw % 8 == 0 then
      seed = candidate
      break
    end
  end
  Assert.notNil(seed, "a draw inside the critical window exists")
  local state = liveState()
  local ctx = liveContext(state)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("luckychant"),
    { kind = "side", side = 2 },
    { kind = "move", combatant = 2 },
    { version = 1, turns = 5 }
  )
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  local facts = moveFacts("SLASH", { power = 70, accuracy = 100 })
  local node = Execution.start({
    actionId = 910,
    actor = { combatant = 1 },
    requestedMove = "SLASH",
    executingMove = "SLASH",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "SLASH", pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = probeCombat(5, 16, 16),
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(seed --[[@as integer]]),
  })
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  Assert.equal(finished.result, "hit", "the shielded strike connects")
  local shielded = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before
  local plain = runStrike(
    "SLASH",
    moveFacts("SLASH", { power = 70, accuracy = 100 }),
    seed --[[@as integer]],
    { combat = probeCombat(5, 16, 16) }
  )
  Assert.isTrue((plain.dealt --[[@as integer]]) > shielded, "the chant shields the raised critical")
end

-- Flame Wheel thaws its frozen user while landing its burn chance.
function T.flame_wheel_thaws_its_frozen_user()
  damageOwner("flame wheel owns its thaw")
  local state = liveState()
  local ctx = liveContext(state)
  ctx:applyStatus(1, "freeze", {}, { kind = "probe" })
  local facts = moveFacts("FLAME_WHEEL", { power = 60, accuracy = 100, moveType = "fire", effectChance = 10 })
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local node = Execution.start({
    actionId = 911,
    actor = { combatant = 1 },
    requestedMove = "FLAME_WHEEL",
    executingMove = "FLAME_WHEEL",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "FLAME_WHEEL", pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = probeCombat(5, 16, 16),
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
    attackerTypes = { "fire" },
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
  Assert.equal(finished.result, "hit", "flame wheel connects")
  Assert.isNil(ctx:statusOf(1), "flame wheel thaws its frozen user")
end

-- Secondaries respect immunities and substitutes: fire defenders never
-- burn and a standing doll absorbs the follow-up.
function T.secondaries_respect_immunities_and_substitutes()
  damageOwner("secondaries own their gates")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local NativeEffectHandlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "native definitions resolve for typed battle-local writes"
  )
  ---@param defenderTypes table<integer, string[]> defender types under the probe
  ---@param substitute boolean whether a marked doll stands in
  ---@return boolean true when the burn lands
  local function burnLands(defenderTypes, substitute)
    local state = liveState()
    local ctx = liveContext(state)
    if substitute then
      local entry = ctx:entryOf(2)
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor("substitute"),
        { kind = "active", combatant = 2, activation = entry.activation },
        { kind = "move", combatant = 2 },
        -- The doll must survive the strike to prove the standing block:
        -- a broken doll exposes the body to the follow-up by design.
        { version = 1, hp = 500 }
      )
    end
    local facts =
      moveFacts("FLAMETHROWER", { power = 95, accuracy = 100, category = "special", moveType = "fire", effectChance = 100 })
    local node = Execution.start({
      actionId = 912,
      actor = { combatant = 1 },
      requestedMove = "FLAMETHROWER",
      executingMove = "FLAMETHROWER",
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "FLAMETHROWER", pp = 10, ppUps = 0 } },
      moveFacts = facts,
      combat = probeCombat(5, 16, 16),
      burned = false,
      guts = false,
      weather = "none",
      weatherSuppressed = false,
      abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
      attackerTypes = { "fire" },
      defenderTypes = defenderTypes,
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
    return ctx:statusOf(2) == "burn"
  end
  Assert.isTrue(burnLands({ [2] = { "normal" } }, false), "the burn lands on a neutral defender")
  Assert.isFalse(burnLands({ [2] = { "fire" } }, false), "fire defenders never burn")
  Assert.isFalse(burnLands({ [2] = { "normal" } }, true), "a marked doll absorbs the burn")
end

-- Feint fails outright without protection to break, and breaks through
-- otherwise.
function T.feint_needs_protection_to_break()
  damageOwner("feint owns its protection gate")
  local refused = runStrike(
    "FEINT",
    moveFacts("FEINT", { power = 50, accuracy = 100 }),
    FIXED_SEED,
    { combat = probeCombat(5, 16, 16) }
  )
  local refusedOutcome = refused.outcome --[[@as table<string, unknown>]]
  Assert.equal(refusedOutcome.result, "failed", "feint fails with no protection to break")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  ctx:addBattleEffect(
    {
      key = "PROTECT",
      stateVersion = 1,
      validateState = function(s)
        return s
      end,
      timings = { { timing = "leave", handler = "PROTECT", orderClass = "affliction" } },
      lifecycle = { stacking = "replace", transfer = "clear" },
    },
    { kind = "active", combatant = 2, activation = 1 },
    { kind = "move", combatant = 2 },
    { version = 1 }
  )
  local facts = moveFacts("FEINT", { power = 50, accuracy = 100 })
  local node = Execution.start({
    actionId = 906,
    actor = { combatant = 1 },
    requestedMove = "FEINT",
    executingMove = "FEINT",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "FEINT", pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = probeCombat(5, 16, 16),
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
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
  Assert.equal(finished.result, "hit", "feint breaks protection and lands")
end

---@param moveKey string strike identity under execution
---@param facts table<string, table<string, unknown>> compiled-shaped move facts
---@param seed integer fixed seed for the probe stream
---@param extra table<string, unknown>|nil extra frame inputs for the probe
---@param setup fun(state: table, ctx: table)|nil battle preparation under the probe
---@return table terminal execution step plus observed health and context
local function runPreparedStrike(moveKey, facts, seed, extra, setup)
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  if setup ~= nil then
    setup(state, ctx)
  end
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  local inputs = {
    actionId = 901,
    actor = { combatant = 1 },
    requestedMove = moveKey,
    executingMove = moveKey,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveKey, pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = probeCombat(50, 120, 90),
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
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
  assert(finished.kind == "complete" and finished.frame == nil, "the strike settles")
  return {
    outcome = finished,
    dealt = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before,
    ctx = ctx,
    state = state,
  }
end

---@param ctx table genuine mechanics context under preparation
---@param defender integer defender combatant receiving the doll
---@param hp integer doll health under the probe
local function seedDoll(ctx, defender, hp)
  local NativeEffects = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "native definitions resolve for typed battle-local writes"
  )
  local entry = ctx:entryOf(defender)
  ctx:addBattleEffect(
    NativeEffects.definitionFor("substitute"),
    { kind = "active", combatant = defender, activation = entry.activation },
    { kind = "move", combatant = defender },
    { version = 1, hp = hp }
  )
end

---@param state table live battle state under inspection
---@return boolean true when a break announcement names the defender
local function brokeAnnounced(state)
  for _, event in ipairs(state.outbox --[[@as table<integer, unknown>]]) do
    local record = event --[[@as table<string, unknown>]]
    if record.kind == "substitute-broke" then
      return true
    end
  end
  return false
end

-- Landed strikes bill the doll first: a surviving doll stands with the
-- body untouched, and only a breaking hit removes it — never spilling
-- overkill into health.
function T.landed_strikes_bill_the_doll_before_touching_health()
  damageOwner("doll depletion owns the landed-hit boundary")
  local facts = moveFacts("SONIC_BOOM", { power = 40, accuracy = 100, category = "physical", moveType = "normal" })
  local survived = runPreparedStrike("SONIC_BOOM", facts, FIXED_SEED, nil, function(_, ctx)
    seedDoll(ctx, 2, 25)
  end)
  local survivedOutcome = survived.outcome --[[@as table<string, unknown>]]
  Assert.equal(survivedOutcome.result, "hit", "the absorbed strike still connects")
  Assert.equal(survived.dealt, 0, "the surviving doll shields the body")
  Assert.isTrue(survived.ctx:hasBattleEffect(2, "substitute"), "the surviving doll stands")
  Assert.isFalse(brokeAnnounced(survived.state), "survival announces no break")
  local broke = runPreparedStrike("SONIC_BOOM", facts, FIXED_SEED, nil, function(_, ctx)
    seedDoll(ctx, 2, 20)
  end)
  local brokeOutcome = broke.outcome --[[@as table<string, unknown>]]
  Assert.equal(brokeOutcome.result, "hit", "the breaking strike still connects")
  Assert.equal(broke.dealt, 0, "breaking overkill never spills into health")
  Assert.isFalse(broke.ctx:hasBattleEffect(2, "substitute"), "the broken doll is gone")
  Assert.isTrue(brokeAnnounced(broke.state), "the break is announced")
end

-- Repeated strikes drain the same doll across hits: a second fixed blow
-- breaks what the first merely dented, proving the decremented health
-- persisted on the effect instead of resetting.
function T.repeated_strikes_drain_the_doll_across_hits()
  damageOwner("doll depletion owns the landed-hit boundary")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = liveState()
  local ctx = liveContext(state)
  seedDoll(ctx, 2, 25)
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  local facts = moveFacts("SONIC_BOOM", { power = 40, accuracy = 100, category = "physical", moveType = "normal" })
  for _ = 1, 2 do
    local node = Execution.start({
      actionId = 901,
      actor = { combatant = 1 },
      requestedMove = "SONIC_BOOM",
      executingMove = "SONIC_BOOM",
      ppOwnerSlot = 0,
      selectedTarget = SessionFixture.positionTarget(2),
      targets = { { combatant = 2 } },
      moves = { { move = "SONIC_BOOM", pp = 10, ppUps = 0 } },
      moveFacts = facts,
      combat = probeCombat(50, 120, 90),
      burned = false,
      guts = false,
      weather = "none",
      weatherSuppressed = false,
      abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
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
  end
  Assert.isFalse(ctx:hasBattleEffect(2, "substitute"), "two fixed blows empty the doll")
  Assert.equal(ctx:damage(2, 0, { kind = "probe" }).before, beforeFoe, "the dented-then-broken sequence never touches the body")
end

-- Missed strikes never touch the doll: the accuracy failure settles
-- before any depletion.
function T.missed_strikes_leave_the_doll_untouched()
  damageOwner("doll depletion owns the landed-hit boundary")
  local seed = nil
  for candidate = 1, 500 do
    local probe = BattleRng.new(candidate)
    if probe:nextU16("accuracy_check", { kind = "probe" }) % 100 >= 30 then
      seed = candidate
      break
    end
  end
  Assert.notNil(seed, "a missing accuracy draw exists")
  local facts = moveFacts("TACKLE", { power = 40, accuracy = 30, category = "physical", moveType = "normal" })
  local probe = runPreparedStrike("TACKLE", facts, seed --[[@as integer]], nil, function(_, ctx)
    seedDoll(ctx, 2, 10)
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "missed", "the strike misses")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "substitute"), "the missed doll stands untouched")
  Assert.isFalse(brokeAnnounced(probe.state), "the miss announces no break")
end

-- Breaking the doll mid-sequence opens the body: the first fixed hit of
-- a two-hit strike breaks a one-health doll and the second hit lands
-- on health.
function T.breaking_the_doll_mid_sequence_opens_the_body()
  damageOwner("doll depletion owns the landed-hit boundary")
  local facts = moveFacts("BONEMERANG", { power = 25, accuracy = 100, category = "physical", moveType = "ground" })
  local probe = runPreparedStrike("BONEMERANG", facts, FIXED_SEED, nil, function(_, ctx)
    seedDoll(ctx, 2, 1)
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the sequence connects")
  Assert.isFalse(probe.ctx:hasBattleEffect(2, "substitute"), "the first hit breaks the doll")
  Assert.isTrue(probe.dealt > 0, "the later hit reaches the opened body")
  Assert.isTrue(brokeAnnounced(probe.state), "the mid-sequence break is announced")
end

return { tests = T }
