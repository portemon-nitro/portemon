-- Condition move ability gates follow the Gen-IV battle checkpoints.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = { tests = {} }
local SEED = 613633213

local function battleChart()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "condition-ability-fidelity")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    SessionFixture.RULESET,
    { key = SessionFixture.RULESET, chart = SessionFixture.RULESET },
    "condition-ability-fidelity"
  )
  local content = BattleContent.new(builder:freeze(), behaviors:freeze())
  return assert(content:typeChart(SessionFixture.RULESET))
end

local function moveFacts(move, overrides)
  local facts = { power = 0, accuracy = 100, category = "other", moveType = "normal", effectChance = 0 }
  for key, value in pairs(overrides or {}) do
    facts[key] = value
  end
  return { [move] = facts }
end

local function execute(move, overrides, extra)
  local contracts = SessionFixture.sessionContracts()
  local scenario = SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { SessionFixture.combatant(2, 23) }),
    },
    positions = { SessionFixture.position(1, 1, { 1 }, 1), SessionFixture.position(2, 2, { 2 }, 2) },
    inventories = {},
  })
  local state = contracts.State.create(contracts.Scenario.validate(scenario))
  local Context = require("libs.battle.src.BattleContext")
  local ctx = Context.wrap(state)
  local inputs = {
    actionId = 1001,
    actor = { combatant = 1 },
    requestedMove = move,
    executingMove = move,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = move, pp = 10, ppUps = 0 } },
    moveFacts = moveFacts(move, overrides),
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = battleChart(),
    friendship = 255,
    stream = BattleRng.new(SEED),
  }
  for key, value in pairs(extra or {}) do
    inputs[key] = value
  end
  local Execution = require("libs.battle.src.gen4.MoveExecution")
  local node = Execution.start(inputs)
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    if node.kind == "complete" and node.frame == nil then
      break
    end
  end
  assert(node.kind == "complete" and node.frame == nil, "condition ability execution settles")
  return { outcome = node, ctx = ctx }
end

function T.tests.compound_eyes_improves_condition_move_accuracy()
  local baseline = execute("THUNDER_WAVE", { accuracy = 31 })
  local boosted = execute("THUNDER_WAVE", { accuracy = 31 }, { abilities = { user = "COMPOUNDEYES" } })
  Assert.equal(baseline.outcome.result, "missed", "the seeded ordinary accuracy roll misses at 31 percent")
  Assert.equal(boosted.outcome.result, "hit", "Compound Eyes raises the same roll to a hit")
end

function T.tests.no_guard_removes_condition_move_accuracy_check()
  local baseline = execute("THUNDER_WAVE", { accuracy = 1 })
  local guaranteed = execute("THUNDER_WAVE", { accuracy = 1 }, { abilities = { user = "NO_GUARD" } })
  Assert.equal(baseline.outcome.result, "missed", "the seeded ordinary accuracy roll misses at one percent")
  Assert.equal(guaranteed.outcome.result, "hit", "No Guard guarantees condition move accuracy")
end

function T.tests.synchronize_reflects_a_primary_major_status_move()
  local probe = execute("THUNDER_WAVE", { accuracy = 100 }, { abilities = { foe = "SYNCHRONIZE" } })
  Assert.equal(probe.ctx:statusOf(2), "paralysis", "the target receives Thunder Wave")
  Assert.equal(probe.ctx:statusOf(1), "paralysis", "Synchronize reflects the inflicted paralysis")
end

function T.tests.synchronize_reflects_psycho_shift_status()
  local contracts = SessionFixture.sessionContracts()
  local scenario = SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { SessionFixture.combatant(2, 23) }),
    },
    positions = { SessionFixture.position(1, 1, { 1 }, 1), SessionFixture.position(2, 2, { 2 }, 2) },
    inventories = {},
  })
  local state = contracts.State.create(contracts.Scenario.validate(scenario))
  local Context = require("libs.battle.src.BattleContext")
  local ctx = Context.wrap(state)
  ctx:applyStatus(1, "burn", {}, { actionId = 1, actor = { combatant = 1 }, move = "WILL_O_WISP" })
  local Execution = require("libs.battle.src.gen4.MoveExecution")
  local node = Execution.start({
    actionId = 2,
    actor = { combatant = 1 },
    requestedMove = "PSYCHO_SHIFT",
    executingMove = "PSYCHO_SHIFT",
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = "PSYCHO_SHIFT", pp = 10, ppUps = 0 } },
    moveFacts = moveFacts("PSYCHO_SHIFT"),
    attackerTypes = { "psychic" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = battleChart(),
    friendship = 255,
    stream = BattleRng.new(SEED),
    abilities = { foe = "SYNCHRONIZE" },
  })
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    if node.kind == "complete" and node.frame == nil then
      break
    end
  end
  Assert.equal(node.result, "hit", "Psycho Shift transfers the status")
  Assert.equal(ctx:statusOf(2), "burn", "the target receives the transferred burn")
  Assert.equal(ctx:statusOf(1), "burn", "Synchronize acts when Psycho Shift inflicts burn")
end

return T
