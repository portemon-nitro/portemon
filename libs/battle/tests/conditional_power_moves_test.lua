-- Conditional power strikes scale their staged power from live battle
-- facts: brine doubles against a half-health target, facade doubles
-- through burn, poison, and paralysis, eruption and water spout fall off
-- with user health, flail and reversal climb the native 64th ladder,
-- wring out scales with defender health, gyro ball scales with the speed
-- ratio capped at one-fifty, and low kick and grass knot climb the
-- weight ladder in kilograms.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local HANDLER_SEED = 0xC04D1710

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
  NativeTypeChart.install(builder, "conditional-power-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "conditional-power-tests"
  )
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table<string, unknown> session type chart over the complete native matrix
local function nativeChart(content)
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  return assert(content:typeChart(Executor.RULESET), "the native chart resolves for the conditional probes")
end

---@param move string strike identity under the probe
---@param power integer compiled base power under the probe
---@param moveType string compiled move type under the probe
---@param category string compiled damage category under the probe
---@return table<string, unknown> compiled-shaped move facts for the probe
local function strikeFacts(move, power, moveType, category)
  return {
    nativeId = 1,
    name = move,
    description = "",
    effect = 0,
    category = category,
    power = power,
    moveType = moveType,
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

---@return table<string, table<string, unknown>> immutable move facts for the probes
local function probeMoveFacts()
  return {
    BRINE = strikeFacts("BRINE", 65, "water", "special"),
    FACADE = strikeFacts("FACADE", 70, "normal", "physical"),
    ERUPTION = strikeFacts("ERUPTION", 150, "fire", "special"),
    WATER_SPOUT = strikeFacts("WATER_SPOUT", 150, "water", "special"),
    FLAIL = strikeFacts("FLAIL", 1, "normal", "physical"),
    REVERSAL = strikeFacts("REVERSAL", 1, "fighting", "physical"),
    WRING_OUT = strikeFacts("WRING_OUT", 1, "normal", "special"),
    GYRO_BALL = strikeFacts("GYRO_BALL", 1, "steel", "physical"),
    LOW_KICK = strikeFacts("LOW_KICK", 1, "fighting", "physical"),
    GRASS_KNOT = strikeFacts("GRASS_KNOT", 1, "grass", "special"),
  }
end

---@param moveKey string strike identity under execution
---@param extra table<string, unknown> frame facts under the probe
---@param userHp integer? user health override before the strike, full when nil
---@param foeHp integer? defender health override before the strike, full when nil
---@param userStatus string? persistent condition on the user mon, healthy when nil
---@return table terminal execution step plus observed damage
local function runStrike(moveKey, extra, userHp, foeHp, userStatus)
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
  if userHp ~= nil then
    local user = state.combatant(live, 1)
    user.hp = userHp
  end
  if foeHp ~= nil then
    local foe = state.combatant(live, 2)
    foe.hp = foeHp
  end
  if userStatus ~= nil then
    local user = state.combatant(live, 1)
    user.mon.condition = { currentHp = user.hp, effects = { { key = userStatus, version = 1, state = {} } } }
  end
  local facts = probeMoveFacts()
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
    combat = { level = 50, attack = 120, defense = 110 },
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = nativeChart(content),
    stream = BattleRng.new(HANDLER_SEED),
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
  }
end

function T.brine_doubles_against_a_half_health_target()
  local probe = runStrike("BRINE", {}, nil, 40)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the brine connects")
  Assert.equal(probe.dealt, 40, "brine doubles against a half-health target")
end

function T.brine_holds_base_power_against_a_healthy_target()
  local probe = runStrike("BRINE", {}, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the brine connects")
  Assert.equal(probe.dealt, 28, "brine holds base power against a healthy target")
end

function T.facade_doubles_through_burn()
  local probe = runStrike("FACADE", {}, nil, nil, "burn")
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the facade connects")
  Assert.equal(probe.dealt, 89, "facade doubles through burn")
end

function T.facade_holds_base_power_when_healthy()
  local probe = runStrike("FACADE", {}, nil, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the facade connects")
  Assert.equal(probe.dealt, 45, "facade holds base power when healthy")
end

function T.eruption_falls_off_with_user_health()
  local probe = runStrike("ERUPTION", {}, 30, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the eruption connects")
  Assert.equal(probe.dealt, 9, "eruption falls off with user health")
end

function T.water_spout_falls_off_with_user_health()
  local probe = runStrike("WATER_SPOUT", {}, 30, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the spout connects")
  Assert.equal(probe.dealt, 9, "water spout falls off with user health")
end

function T.flail_climbs_the_low_health_ladder()
  local probe = runStrike("FLAIL", {}, 5, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the flail connects")
  Assert.equal(probe.dealt, 127, "flail climbs the low-health ladder")
end

function T.reversal_climbs_the_low_health_ladder()
  local probe = runStrike("REVERSAL", {}, 5, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the reversal connects")
  Assert.equal(probe.dealt, 170, "reversal climbs the low-health ladder")
end

function T.wring_out_scales_with_defender_health()
  local probe = runStrike("WRING_OUT", {}, nil, 40, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the wring out connects")
  Assert.equal(probe.dealt, 15, "wring out scales with defender health")
end

function T.gyro_ball_scales_with_the_speed_ratio()
  local probe = runStrike("GYRO_BALL", { speeds = { user = 40, foe = 200 } }, nil, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the gyro ball connects")
  Assert.equal(probe.dealt, 53, "gyro ball scales with the speed ratio")
end

function T.low_kick_climbs_the_weight_ladder()
  local probe = runStrike("LOW_KICK", { foeWeightHg = 900 }, nil, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the low kick connects")
  Assert.equal(probe.dealt, 69, "low kick climbs the weight ladder")
end

function T.grass_knot_climbs_the_weight_ladder()
  local probe = runStrike("GRASS_KNOT", { foeWeightHg = 3000 }, nil, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the grass knot connects")
  Assert.equal(probe.dealt, 51, "grass knot climbs the weight ladder")
end

return { tests = T }
