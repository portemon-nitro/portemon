-- Contact retaliation and Color Change persist through native strike execution.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = { tests = {} }

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

local chartCache = nil
local function chart()
  if chartCache == nil then
    local ContentBuilder = require("libs.content.src.ContentBuilder")
    local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
    local BattleContent = require("libs.battle.src.BattleContent")
    local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
    local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
    local builder = ContentBuilder.new()
    NativeTypeChart.install(builder, "ability-contact-fidelity-tests")
    local behaviors = BattleBehaviorBuilder.new()
    behaviors:registerRuleset(Executor.RULESET, { key = Executor.RULESET, chart = Executor.RULESET }, "tests")
    chartCache = assert(BattleContent.new(builder:freeze(), behaviors:freeze()):typeChart(Executor.RULESET))
  end
  return chartCache
end

local function strike(state, moveName, moveType, ability, flags, userAbility, weather)
  local loaded, execution = pcall(require, "libs.battle.src.gen4.MoveExecution")
  Assert.isTrue(loaded, "the shared continuation loads: " .. tostring(execution))
  local Execution = execution --[[@as table]]
  local ctx = SessionFixture.sessionContracts().Context.wrap(state)
  local facts = {
    power = 40,
    accuracy = 0,
    category = "physical",
    moveType = moveType,
    effectChance = 100,
    flags = flags or {},
  }
  local inputs = {
    actionId = 9001,
    actor = { combatant = 1 },
    requestedMove = moveName,
    executingMove = moveName,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveName, pp = 10, ppUps = 0 } },
    moveFacts = { [moveName] = facts },
    combat = {
      level = 50,
      attack = 120,
      defense = 90,
      rawAttack = 120,
      rawDefense = 90,
      attackStage = 0,
      defenseStage = 0,
    },
    burned = false,
    guts = false,
    weather = weather or "none",
    weatherSuppressed = false,
    abilities = { user = userAbility or "NONE", foe = ability },
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = chart(),
    friendship = 255,
    genders = { [1] = "male", [2] = "female" },
    stream = BattleRng.new(771626189),
  }
  local node = Execution.start(inputs)
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    if node.kind == "complete" and node.frame == nil then
      break
    end
  end
  Assert.equal(node.result, "hit", "the strike completes")
  return ctx
end

function T.tests.rough_skin_retaliates_on_contact()
  local state = liveState()
  local ctx = SessionFixture.sessionContracts().Context.wrap(state)
  local before = ctx:damage(1, 0, { kind = "probe" }).before
  strike(state, "TACKLE", "normal", "ROUGH_SKIN", { contact = true })
  Assert.isTrue(ctx:damage(1, 0, { kind = "probe" }).before < before, "Rough Skin damages the contacting attacker")
end

function T.tests.color_change_records_a_persistent_type_override()
  local state = liveState()
  local ctx = strike(state, "TACKLE", "fire", "COLOR_CHANGE")
  local bag = state.effectBag
  local found = false
  for _, effect in ipairs(bag:capture()) do
    if effect.key == "colorchange" and effect.scope.combatant == 2 then
      local stored = bag:get(effect.id)
      Assert.equal(stored.state.type, "fire", "Color Change stores the striking type")
      found = true
    end
  end
  Assert.isTrue(found, "Color Change persists for the defender entry")
  Assert.isTrue(ctx:entryOf(2).activation ~= nil, "the override belongs to the active entry")
end

function T.tests.flash_fire_persists_after_absorbing_fire()
  local state = liveState()
  local ctx = strike(state, "TACKLE", "fire", "FLASH_FIRE")
  local found = false
  for _, effect in ipairs(state.effectBag:capture()) do
    if effect.key == "flashfire" and effect.scope.combatant == 2 then
      found = true
    end
  end
  Assert.isTrue(found, "Flash Fire records its battle-long fire boost")
  Assert.isTrue(ctx:damage(2, 0, { kind = "probe" }).before > 0, "the fire strike is absorbed")
end

function T.tests.inner_focus_blocks_a_damaging_move_flinch()
  local state = liveState()
  local ctx = strike(state, "BITE", "dark", "INNER_FOCUS")
  Assert.isFalse(ctx:hasBattleEffect(2, "flinch"), "Inner Focus blocks a secondary flinch")
end

function T.tests.steadfast_raises_speed_after_a_flinch()
  local state = liveState()
  local ctx = strike(state, "BITE", "dark", "STEADFAST")
  Assert.equal(ctx:entryOf(2).stages.speed, 1, "Steadfast raises Speed when flinched")
end

function T.tests.own_tempo_blocks_a_damaging_move_confusion()
  local state = liveState()
  local ctx = strike(state, "CONFUSION", "psychic", "OWN_TEMPO")
  Assert.isFalse(ctx:hasBattleEffect(2, "confusion"), "Own Tempo blocks Confusion's secondary volatile")
end

function T.tests.shield_dust_blocks_a_damaging_move_stat_drop()
  local state = liveState()
  local ctx = strike(state, "ROCK_SMASH", "fighting", "SHIELD_DUST")
  Assert.equal(ctx:entryOf(2).stages.defense, 0, "Shield Dust blocks damaging move stat-drop secondaries")
end

function T.tests.clear_body_blocks_a_damaging_move_stat_drop()
  local state = liveState()
  local ctx = strike(state, "ROCK_SMASH", "fighting", "CLEAR_BODY")
  Assert.equal(ctx:entryOf(2).stages.defense, 0, "Clear Body blocks Rock Smash's Defense drop")
end

return T
