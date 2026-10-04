-- Counter-style reactions return twice the recorded damage of their
-- staged category from the last live opposing damager, with neutral
-- effectiveness and no accuracy roll: missing damagers fail, wrong
-- categories fail, and fainted damagers fail.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local HANDLER_SEED = 0xC0E771C

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@return table level-100 combatant seed whose health survives the probes
local function sturdyCombatant(id, seed)
  local mon = SessionFixture.makeMon(seed, { level = 100 })
  return { id = id, mon = mon }
end

---@return table frozen battle content carrying the native ruleset over the real chart
local function nativeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "counter-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "counter-tests"
  )
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table<string, unknown> session type chart over the complete native matrix
local function nativeChart(content)
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  return assert(content:typeChart(Executor.RULESET), "the native chart resolves for the counter probes")
end

---@param move string strike identity under the probe
---@return table<string, unknown> compiled-shaped move facts for the probe
local function strikeFacts(move)
  return {
    nativeId = 1,
    name = move,
    description = "",
    effect = 0,
    category = move == "MIRROR_COAT" and "special" or "physical",
    power = 1,
    moveType = move == "MIRROR_COAT" and "psychic" or "fighting",
    accuracy = 100,
    basePp = 20,
    effectChance = 0,
    range = 0,
    priority = -5,
    behavior = { key = "damage", params = {} },
    target = "range_0",
    flags = { dealsDamage = true, checksAccuracy = true },
  }
end

---@param moveKey string strike identity under execution
---@param duel table<string, unknown> turn facts under the probe
---@return table terminal execution step plus observed damage
local function runStrike(moveKey, duel)
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = SessionFixture.requirePresent("libs.battle.src.BattleState", "live battle state owns the probe")
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
  local live = state.create(contracts.Scenario.validate(scenario))
  local Context = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local ctx = Context.wrap(live)
  local content = nativeContent()
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
    combat = { level = 50, attack = 120, defense = 110 },
    attackerTypes = { "fighting" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = nativeChart(content),
    stream = BattleRng.new(HANDLER_SEED),
    duel = duel,
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
  return {
    outcome = finished,
    dealt = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before,
  }
end

---@return table<string, unknown> turn facts with no prior action or damage
local function freshDuel()
  return {
    foeActed = false,
    foeHurt = false,
    userHurt = false,
    revengePhysical = nil,
    revengeSpecial = nil,
  }
end

function T.counter_returns_twice_the_physical_damage_taken()
  local probe = runStrike("COUNTER", {
    foeActed = true,
    foeHurt = false,
    userHurt = true,
    revengePhysical = { attacker = 2, amount = 40 },
    revengeSpecial = nil,
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the answered counter connects")
  Assert.equal(probe.dealt, 80, "counter returns twice the recorded damage")
end

function T.counter_fails_without_physical_damage()
  local probe = runStrike("COUNTER", freshDuel())
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the unanswered counter fails")
end

function T.counter_ignores_special_damage()
  local probe = runStrike("COUNTER", {
    foeActed = true,
    foeHurt = false,
    userHurt = true,
    revengePhysical = nil,
    revengeSpecial = { attacker = 2, amount = 40 },
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "counter answers only its own category")
end

function T.mirror_coat_returns_twice_the_special_damage_taken()
  local probe = runStrike("MIRROR_COAT", {
    foeActed = true,
    foeHurt = false,
    userHurt = true,
    revengePhysical = nil,
    revengeSpecial = { attacker = 2, amount = 40 },
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the answered mirror coat connects")
  Assert.equal(probe.dealt, 80, "mirror coat returns twice the recorded damage")
end

function T.mirror_coat_fails_without_special_damage()
  local probe = runStrike("MIRROR_COAT", freshDuel())
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the unanswered mirror coat fails")
end

function T.mirror_coat_ignores_physical_damage()
  local probe = runStrike("MIRROR_COAT", {
    foeActed = true,
    foeHurt = false,
    userHurt = true,
    revengePhysical = { attacker = 2, amount = 40 },
    revengeSpecial = nil,
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "mirror coat answers only its own category")
end

return { tests = T }
