-- Move family handler bindings: every family member resolves to its own
-- executable handler through the closed family tables, aliases share
-- behavior but never wrapper identity, unmodeled members keep failing
-- naming the move, and member registration stays explicit about
-- duplicates and unknown identities.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local DomainErrors = require("libs.errors.src.Errors")

local T = {}

local FIXED_SEED = 613633213
local STRIKE_SEED = 0x6E1D64

---@param path string family module under test
---@param behavior string missing owner under test
---@return table the loaded move behavior family
local function familyOwner(path, behavior)
  return SessionFixture.requirePresent(path, behavior)
end

---@return table the loaded condition move family
local function conditionFamily()
  return familyOwner(
    "libs.battle.src.gen4.behaviors.moves.ConditionMoves",
    "the condition family owns its move bindings"
  )
end

---@return table the loaded damage move family
local function damageFamily()
  return familyOwner(
    "libs.battle.src.gen4.behaviors.moves.DamageMoves",
    "the damage family owns its move bindings"
  )
end

---@return table<string, fun(ctx: table, frame: table): table> fresh condition bindings by move
local function boundConditions()
  local family = conditionFamily()
  local owned = {}
  family.register(owned)
  return owned
end

---@return table<string, fun(ctx: table, frame: table): table> fresh damage bindings by move
local function boundDamage()
  local family = damageFamily()
  local owned = {}
  family.register(owned)
  return owned
end

---@param err unknown raised failure under test
---@param identity string move identity the failure must name
local function assertFailureNames(err, identity)
  if DomainErrors.is(err) then
    local context = (err --[[@as table]]).context
    if type(context) == "table" and context.key == identity then
      return
    end
  end
  local text = tostring(err)
  Assert.isTrue(text:find(identity, 1, true) ~= nil, "the failure names " .. identity .. ", got: " .. text)
end

---@param family table move family under the probe
---@param extra string[] member identities to append for the probe
---@param probe fun() registration probe running under the appended members
local function withExtraMembers(family, extra, probe)
  local members = family.MEMBERS --[[@as table<integer, string>]]
  assert(type(members) == "table", "the family carries its member list")
  local count = #members
  for _, key in ipairs(extra) do
    members[#members + 1] = key
  end
  local ok, err = pcall(probe)
  for index = #members, count + 1, -1 do
    members[index] = nil
  end
  Assert.equal(#members, count, "the member list restores after the probe")
  if not ok then
    error(err, 0)
  end
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
    NativeTypeChart.install(builder, "move-binding-tests")
    local behaviors = BattleBehaviorBuilder.new()
    behaviors:registerRuleset(
      Executor.RULESET,
      { key = Executor.RULESET, chart = Executor.RULESET },
      "move-binding-tests"
    )
    local BattleContent = require("libs.battle.src.BattleContent")
    local content = BattleContent.new(builder:freeze(), behaviors:freeze())
    chartCache = assert(content:typeChart(Executor.RULESET), "the native chart resolves for the binding probes")
  end
  return chartCache --[[@as table<string, unknown>]]
end

---@param moveKey string condition identity under the probe
---@param overrides table<string, unknown>|nil move-fact overrides for the probe
---@return table<string, table<string, unknown>> compiled-shaped facts for the probe
local function conditionFacts(moveKey, overrides)
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
  local woundUser = extra ~= nil and extra.woundUser == true
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
    if key ~= "woundUser" then
      inputs[key] = value
    end
  end
  if woundUser then
    local wounded = ctx:entryOf(1)
    ctx:damage(1, math.floor((wounded.maxHp --[[@as integer]]) / 2), { kind = "probe" })
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

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@return table level-100 combatant seed whose health survives the probes
local function sturdyCombatant(id, seed)
  local mon = SessionFixture.makeMon(seed, { level = 100 })
  return { id = id, mon = mon }
end

---@param move string strike identity under the probe
---@return table<string, unknown> compiled-shaped move facts for the probe
local function strikeFacts(move)
  return {
    nativeId = 1,
    name = move,
    description = "",
    effect = 0,
    category = "physical",
    power = 25,
    moveType = "normal",
    accuracy = 100,
    basePp = 10,
    effectChance = 0,
    range = 0,
    priority = 0,
    behavior = { key = "damage", params = {} },
    target = "range_0",
    flags = { dealsDamage = true, checksAccuracy = true },
  }
end

---@param moveKey string strike identity under execution
---@return table terminal execution step plus observed damage and context
local function runStrike(moveKey)
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local stateMod = SessionFixture.requirePresent("libs.battle.src.BattleState", "live battle state owns the probe")
  local contracts = SessionFixture.sessionContracts()
  local scenario = SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { sturdyCombatant(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { sturdyCombatant(2, 23) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
  })
  local live = stateMod.create(contracts.Scenario.validate(scenario))
  local Context = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local ctx = Context.wrap(live)
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
    moveFacts = { [moveKey] = strikeFacts(moveKey) },
    combat = {
      level = 50,
      attack = 120,
      defense = 110,
      rawAttack = 120,
      rawDefense = 110,
      attackStage = 0,
      defenseStage = 0,
    },
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    stream = BattleRng.new(STRIKE_SEED),
    abilities = { user = "NONE", foe = "NONE" },
  }
  local node = Execution.start(inputs)
  for _ = 1, 16 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  assert(finished.kind == "complete" and finished.frame == nil, "the strike settles")
  local strikes = 0
  for _, event in ipairs(live.outbox --[[@as table<integer, unknown>]]) do
    if (event --[[@as table<string, unknown>]]).kind == "struck" then
      strikes = strikes + 1
    end
  end
  return {
    outcome = finished,
    dealt = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before,
    strikes = strikes,
    ctx = ctx,
  }
end

function T.condition_members_each_bind_a_handler()
  local family = conditionFamily()
  local owned = boundConditions()
  for _, key in ipairs(family.MEMBERS) do
    Assert.equal(type(owned[key]), "function", "condition member " .. key .. " binds its handler")
  end
end

function T.damage_members_each_bind_a_handler()
  local family = damageFamily()
  local owned = boundDamage()
  for _, key in ipairs(family.MEMBERS) do
    Assert.equal(type(owned[key]), "function", "damage member " .. key .. " binds its handler")
  end
end

function T.recovery_aliases_share_behavior_but_not_identity()
  local owned = boundConditions()
  local members = { "RECOVER", "SOFTBOILED", "MILK_DRINK", "SLACK_OFF", "HEAL_ORDER" }
  for _, key in ipairs(members) do
    Assert.equal(type(owned[key]), "function", "recovery member " .. key .. " binds its handler")
  end
  for index = 2, #members do
    Assert.isTrue(owned[members[1]] ~= owned[members[index]], "recovery aliases keep distinct bindings")
  end
  local first = runCondition("RECOVER", conditionFacts("RECOVER", { accuracy = 0 }), FIXED_SEED, { woundUser = true })
  local second =
    runCondition("SOFTBOILED", conditionFacts("SOFTBOILED", { accuracy = 0 }), FIXED_SEED, { woundUser = true })
  local firstOutcome = first.outcome --[[@as table<string, unknown>]]
  local secondOutcome = second.outcome --[[@as table<string, unknown>]]
  Assert.equal(firstOutcome.result, "hit", "recover connects")
  Assert.equal(secondOutcome.result, firstOutcome.result, "recovery aliases share their outcome")
end

function T.lock_on_aliases_share_behavior_but_not_identity()
  local owned = boundConditions()
  Assert.equal(type(owned.LOCK_ON), "function", "lock-on binds its handler")
  Assert.equal(type(owned.MIND_READER), "function", "mind reader binds its handler")
  Assert.isTrue(owned.LOCK_ON ~= owned.MIND_READER, "sight aliases keep distinct bindings")
  local first = runCondition("LOCK_ON", conditionFacts("LOCK_ON", { accuracy = 0 }), FIXED_SEED)
  local second = runCondition("MIND_READER", conditionFacts("MIND_READER", { accuracy = 0 }), FIXED_SEED)
  local firstOutcome = first.outcome --[[@as table<string, unknown>]]
  local secondOutcome = second.outcome --[[@as table<string, unknown>]]
  Assert.equal(firstOutcome.result, "hit", "lock-on connects")
  Assert.equal(secondOutcome.result, firstOutcome.result, "sight aliases share their outcome")
end

function T.damage_aliases_share_behavior_but_not_identity()
  local owned = boundDamage()
  Assert.equal(type(owned.REVENGE), "function", "revenge binds its handler")
  Assert.equal(type(owned.AVALANCHE), "function", "avalanche binds its handler")
  Assert.isTrue(owned.REVENGE ~= owned.AVALANCHE, "revenge aliases keep distinct bindings")
  Assert.equal(type(owned.ERUPTION), "function", "eruption binds its handler")
  Assert.equal(type(owned.WATER_SPOUT), "function", "water spout binds its handler")
  Assert.isTrue(owned.ERUPTION ~= owned.WATER_SPOUT, "eruption aliases keep distinct bindings")
  Assert.equal(type(owned.PLUCK), "function", "pluck binds its handler")
  Assert.equal(type(owned.BUG_BITE), "function", "bug bite binds its handler")
  Assert.isTrue(owned.PLUCK ~= owned.BUG_BITE, "berry-eating aliases keep distinct bindings")
end

function T.representative_condition_bindings_keep_their_outcomes()
  local growth = runCondition("GROWTH", conditionFacts("GROWTH", { accuracy = 0 }), FIXED_SEED)
  local growthOutcome = growth.outcome --[[@as table<string, unknown>]]
  Assert.equal(growthOutcome.result, "hit", "growth connects")
  Assert.equal(growth.ctx:entryOf(1).stages.specialAttack, 1, "growth raises special attack")
  local confuse = runCondition("CONFUSE_RAY", conditionFacts("CONFUSE_RAY", { moveType = "ghost" }), FIXED_SEED)
  local confuseOutcome = confuse.outcome --[[@as table<string, unknown>]]
  Assert.equal(confuseOutcome.result, "hit", "confuse ray connects")
  Assert.isTrue(confuse.ctx:hasBattleEffect(2, "confusion"), "confuse ray roots confusion")
  local spikes = runCondition("SPIKES", conditionFacts("SPIKES", { accuracy = 0 }), FIXED_SEED)
  local spikesOutcome = spikes.outcome --[[@as table<string, unknown>]]
  Assert.equal(spikesOutcome.result, "hit", "spikes connect")
end

function T.representative_damage_bindings_keep_their_outcomes()
  local tackle = runStrike("TACKLE")
  local tackleOutcome = tackle.outcome --[[@as table<string, unknown>]]
  Assert.equal(tackleOutcome.result, "hit", "tackle connects")
  Assert.isTrue(tackle.dealt > 0, "tackle deals staged damage")
  Assert.equal(tackle.strikes, 1, "tackle strikes once")
  local fang = runStrike("SUPER_FANG")
  local fangOutcome = fang.outcome --[[@as table<string, unknown>]]
  Assert.equal(fangOutcome.result, "hit", "super fang connects")
  Assert.isTrue(fang.dealt > 0, "super fang deals its fractional damage")
  local double = runStrike("DOUBLE_HIT")
  local doubleOutcome = double.outcome --[[@as table<string, unknown>]]
  Assert.equal(doubleOutcome.result, "hit", "double hit connects")
  Assert.equal(double.strikes, 2, "double hit strikes twice")
end

function T.unmodeled_members_still_fail_naming_the_move()
  local blockErr = Assert.throws(function()
    runCondition("BLOCK", conditionFacts("BLOCK", { accuracy = 0 }), FIXED_SEED)
  end, "unmodeled condition members fail")
  assertFailureNames(blockErr, "BLOCK")
  local aeroblastErr = Assert.throws(function()
    runStrike("AEROBLAST")
  end, "unmodeled damage members fail")
  assertFailureNames(aeroblastErr, "AEROBLAST")
end

function T.duplicate_member_registration_fails()
  local family = conditionFamily()
  withExtraMembers(family, { "SPLASH" }, function()
    local err = Assert.throws(function()
      family.register({})
    end, "duplicate condition members fail at registration")
    assertFailureNames(err, "SPLASH")
  end)
  local damage = damageFamily()
  withExtraMembers(damage, { "TACKLE" }, function()
    local err = Assert.throws(function()
      damage.register({})
    end, "duplicate damage members fail at registration")
    assertFailureNames(err, "TACKLE")
  end)
end

function T.unknown_member_registration_fails()
  local family = conditionFamily()
  withExtraMembers(family, { "UNBOUND_PROBE" }, function()
    local err = Assert.throws(function()
      family.register({})
    end, "unknown condition members fail at registration")
    assertFailureNames(err, "UNBOUND_PROBE")
  end)
  local damage = damageFamily()
  withExtraMembers(damage, { "UNBOUND_PROBE" }, function()
    local err = Assert.throws(function()
      damage.register({})
    end, "unknown damage members fail at registration")
    assertFailureNames(err, "UNBOUND_PROBE")
  end)
end

function T.family_registration_replaces_prior_table_content()
  local owned = {
    SPLASH = "sentinel",
    TACKLE = "sentinel",
  }
  conditionFamily().register(owned)
  damageFamily().register(owned)
  Assert.equal(type(owned.SPLASH), "function", "condition registration owns its member binding")
  Assert.equal(type(owned.TACKLE), "function", "damage registration owns its member binding")
end

function T.duplicate_contributed_moves_still_conflict()
  local BattleBehaviorBuilder = SessionFixture.requirePresent(
    "libs.battle.src.BattleBehaviorBuilder",
    "the behavior builder owns contribution conflicts"
  )
  local builder = BattleBehaviorBuilder.new()
  builder:registerMove("probe:bolt", { module = "probe.bolt", version = 1 }, "probe-pack")
  local err = Assert.throws(function()
    builder:registerMove("probe:bolt", { module = "probe.bolt", version = 1 }, "other-pack")
  end, "duplicate contributed moves conflict")
  assertFailureNames(err, "probe:bolt")
end

return { tests = T }
