-- Battle ability stage and volatile-status rules match the Gen-IV ability
-- checkpoints when real move handlers run through the shared continuation.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = { tests = {} }

local SEED = 613633213

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

---@return table session chart covering every native type relation
local function chart()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "ability-stage-fidelity-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    SessionFixture.RULESET,
    { key = SessionFixture.RULESET, chart = SessionFixture.RULESET },
    "ability-stage-fidelity-tests"
  )
  local content = BattleContent.new(builder:freeze(), behaviors:freeze())
  return assert(content:typeChart(SessionFixture.RULESET), "the native type chart resolves for ability tests")
end

---@param moveKey string move identity under the probe
---@param overrides table<string, unknown>? additional compiled-shaped facts
---@return table<string, table<string, unknown>> move facts for the continuation
local function facts(moveKey, overrides)
  local result = {
    power = 0,
    accuracy = 100,
    category = "other",
    moveType = "normal",
    effectChance = 0,
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return { [moveKey] = result }
end

---@param moveKey string move under execution
---@param moveFacts table<string, table<string, unknown>> move facts for the continuation
---@param extra table<string, unknown>? additional move context
---@return table terminal execution and live context/state
local function runMove(moveKey, moveFacts, extra)
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns ability-sensitive condition moves"
  )
  local state = liveState()
  local Context = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local ctx = Context.wrap(state)
  local inputs = {
    actionId = 1001,
    actor = { combatant = 1 },
    requestedMove = moveKey,
    executingMove = moveKey,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveKey, pp = 10, ppUps = 0 } },
    moveFacts = moveFacts,
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    stream = BattleRng.new(SEED),
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
  assert(finished.kind == "complete" and finished.frame == nil, "the ability-sensitive move settles")
  return { outcome = finished, ctx = ctx, state = state }
end

function T.tests.simple_doubles_a_positive_stage_change()
  local probe = runMove("GROWTH", facts("GROWTH"), { abilities = { user = "SIMPLE" } })
  Assert.equal(probe.outcome.result, "hit", "Growth resolves")
  Assert.equal(probe.ctx:entryOf(1).stages.specialAttack, 2, "Simple doubles Growth's one-stage increase")
end

function T.tests.clear_body_blocks_an_opponents_attack_drop()
  local baseline = runMove("GROWL", facts("GROWL"))
  local probe = runMove("GROWL", facts("GROWL"), { abilities = { foe = "CLEAR_BODY" } })
  Assert.equal(baseline.ctx:entryOf(2).stages.attack, -1, "Growl lowers Attack without an ability guard")
  Assert.equal(probe.ctx:entryOf(2).stages.attack, 0, "Clear Body preserves the target's Attack stage")
end

function T.tests.mold_breaker_bypasses_stat_drop_abilities()
  local guarded = runMove("GROWL", facts("GROWL"), { abilities = { foe = "CLEAR_BODY" } })
  local bypassed = runMove("GROWL", facts("GROWL"), {
    abilities = { user = "MOLD_BREAKER", foe = "CLEAR_BODY" },
  })
  Assert.equal(guarded.ctx:entryOf(2).stages.attack, 0, "Clear Body blocks the ordinary drop")
  Assert.equal(bypassed.ctx:entryOf(2).stages.attack, -1, "Mold Breaker bypasses Clear Body")
end

function T.tests.white_smoke_blocks_an_opponents_stat_drop()
  local baseline = runMove("GROWL", facts("GROWL"))
  local probe = runMove("GROWL", facts("GROWL"), { abilities = { foe = "WHITE_SMOKE" } })
  Assert.equal(baseline.ctx:entryOf(2).stages.attack, -1, "Growl lowers Attack without an ability guard")
  Assert.equal(probe.ctx:entryOf(2).stages.attack, 0, "White Smoke preserves the target's Attack stage")
end

function T.tests.hyper_cutter_only_blocks_attack_drops()
  local baseline = runMove("SCARY_FACE", facts("SCARY_FACE"))
  local attackDrop = runMove("GROWL", facts("GROWL"), { abilities = { foe = "HYPER_CUTTER" } })
  local speedDrop = runMove("SCARY_FACE", facts("SCARY_FACE"), { abilities = { foe = "HYPER_CUTTER" } })
  local mixedDrop = runMove("TICKLE", facts("TICKLE"), { abilities = { foe = "HYPER_CUTTER" } })
  Assert.equal(baseline.ctx:entryOf(2).stages.speed, -2, "Scary Face lowers Speed without an ability guard")
  Assert.equal(attackDrop.ctx:entryOf(2).stages.attack, 0, "Hyper Cutter blocks Attack loss")
  Assert.equal(speedDrop.ctx:entryOf(2).stages.speed, -2, "Hyper Cutter does not block Speed loss")
  Assert.equal(mixedDrop.ctx:entryOf(2).stages.attack, 0, "Hyper Cutter blocks Attack from a mixed move")
  Assert.equal(mixedDrop.ctx:entryOf(2).stages.defense, -1, "Hyper Cutter allows the other mixed stat loss")
end

function T.tests.keen_eye_only_blocks_accuracy_drops()
  local accuracyDrop = runMove("SAND_ATTACK", facts("SAND_ATTACK"), { abilities = { foe = "KEEN_EYE" } })
  local speedDrop = runMove("SCARY_FACE", facts("SCARY_FACE"), { abilities = { foe = "KEEN_EYE" } })
  Assert.equal(accuracyDrop.ctx:entryOf(2).stages.accuracy, 0, "Keen Eye blocks accuracy loss")
  Assert.equal(speedDrop.ctx:entryOf(2).stages.speed, -2, "Keen Eye does not block Speed loss")
end

function T.tests.simple_doubles_negative_stage_changes()
  local probe = runMove("GROWL", facts("GROWL"), { abilities = { foe = "SIMPLE" } })
  Assert.equal(probe.ctx:entryOf(2).stages.attack, -2, "Simple doubles a one-stage Attack drop")
end

function T.tests.captivate_respects_stat_drop_prevention()
  local probe = runMove("CAPTIVATE", facts("CAPTIVATE"), {
    abilities = { foe = "CLEAR_BODY" },
    genders = { [1] = "male", [2] = "female" },
  })
  Assert.equal(probe.ctx:entryOf(2).stages.specialAttack, 0, "Clear Body blocks Captivate")
end

function T.tests.memento_respects_stat_drop_prevention()
  local probe = runMove("MEMENTO", facts("MEMENTO"), { abilities = { foe = "CLEAR_BODY" } })
  Assert.equal(probe.ctx:entryOf(2).stages.attack, 0, "Clear Body blocks Memento's Attack drop")
  Assert.equal(probe.ctx:entryOf(2).stages.specialAttack, 0, "Clear Body blocks Memento's Sp. Atk drop")
  Assert.equal(probe.outcome.result, "hit", "Memento still resolves after its user faints")
end

function T.tests.acupressure_applies_simple_to_its_random_boost()
  local probe = runMove("ACUPRESSURE", facts("ACUPRESSURE"), { abilities = { user = "SIMPLE" } })
  local stages = probe.ctx:entryOf(1).stages
  local total = 0
  for _, stage in pairs(stages) do
    total = total + math.abs(stage)
  end
  Assert.equal(total, 4, "Simple doubles Acupressure's selected two-stage boost")
end

function T.tests.swagger_and_flatter_apply_simple_to_their_boosts()
  local swagger = runMove("SWAGGER", facts("SWAGGER"), { abilities = { foe = "SIMPLE", user = "MOLD_BREAKER" } })
  local flatter = runMove("FLATTER", facts("FLATTER"), { abilities = { foe = "SIMPLE", user = "MOLD_BREAKER" } })
  Assert.equal(swagger.ctx:entryOf(2).stages.attack, 4, "Simple doubles Swagger's Attack boost")
  Assert.equal(flatter.ctx:entryOf(2).stages.specialAttack, 2, "Simple doubles Flatter's Sp. Atk boost")
end

function T.tests.curse_applies_simple_to_every_stat_delta()
  local probe = runMove("CURSE", facts("CURSE"), { abilities = { user = "SIMPLE" } })
  local stages = probe.ctx:entryOf(1).stages
  Assert.equal(stages.speed, -2, "Simple doubles Curse's Speed loss")
  Assert.equal(stages.attack, 2, "Simple doubles Curse's Attack boost")
  Assert.equal(stages.defense, 2, "Simple doubles Curse's Defense boost")
end

function T.tests.defog_respects_stat_drop_prevention()
  local probe = runMove("DEFOG", facts("DEFOG"), { abilities = { foe = "CLEAR_BODY" } })
  Assert.equal(probe.ctx:entryOf(2).stages.evasion, 0, "Clear Body blocks Defog's evasion loss")
end

function T.tests.own_tempo_prevents_confusion()
  local probe = runMove("CONFUSE_RAY", facts("CONFUSE_RAY", { moveType = "ghost" }), {
    abilities = { foe = "OWN_TEMPO" },
  })
  Assert.equal(probe.outcome.result, "failed", "Own Tempo refuses the confusion attempt")
  Assert.isFalse(probe.ctx:hasBattleEffect(2, "confusion"), "Own Tempo leaves no confusion volatile")
end

function T.tests.oblivious_prevents_infatuation()
  local probe = runMove("ATTRACT", facts("ATTRACT"), {
    abilities = { foe = "OBLIVIOUS" },
    genders = { [1] = "male", [2] = "female" },
  })
  Assert.equal(probe.outcome.result, "failed", "Oblivious refuses the infatuation attempt")
  Assert.isFalse(probe.ctx:hasBattleEffect(2, "infatuation"), "Oblivious leaves no infatuation volatile")
end

function T.tests.major_status_abilities_prevent_matching_status_moves()
  local cases = {
    { move = "THUNDER_WAVE", status = "paralysis", ability = "LIMBER" },
    { move = "TOXIC", status = "toxic", ability = "IMMUNITY" },
    { move = "HYPNOSIS", status = "sleep", ability = "INSOMNIA" },
    { move = "HYPNOSIS", status = "sleep", ability = "VITAL_SPIRIT" },
    { move = "WILL_O_WISP", status = "burn", ability = "WATER_VEIL" },
  }
  for _, case in ipairs(cases) do
    local probe = runMove(case.move, facts(case.move, { moveType = "normal" }), {
      abilities = { foe = case.ability },
    })
    Assert.equal(probe.outcome.result, "failed", case.ability .. " prevents " .. case.status)
    Assert.isNil(probe.ctx:statusOf(2), case.ability .. " leaves the target unstatused")
  end
end

function T.tests.mold_breaker_bypasses_major_status_ability_prevention()
  local move = facts("TOXIC", { moveType = "normal" })
  local warded = runMove("TOXIC", move, { abilities = { foe = "IMMUNITY" } })
  local bypassed = runMove("TOXIC", move, { abilities = { user = "MOLD_BREAKER", foe = "IMMUNITY" } })
  Assert.equal(warded.outcome.result, "failed", "Immunity rejects Toxic without a breaker")
  Assert.equal(bypassed.outcome.result, "hit", "Mold Breaker opens the status gate")
  Assert.equal(bypassed.ctx:statusOf(2), "toxic", "the bypassed target receives Toxic")
end

return T
