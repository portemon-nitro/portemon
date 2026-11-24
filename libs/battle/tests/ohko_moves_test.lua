-- One-hit knockouts resolve outside the staged arithmetic: sturdy
-- answers first, lower-level users fail, locked-on targets fall without
-- a roll, and every other attempt rolls flat percent under the
-- level-plus-accuracy chance with no stage scaling.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local HANDLER_SEED = 0x00A001

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
  NativeTypeChart.install(builder, "ohko-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(Executor.RULESET, { key = Executor.RULESET, chart = Executor.RULESET }, "ohko-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table<string, unknown> session type chart over the complete native matrix
local function nativeChart(content)
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  return assert(content:typeChart(Executor.RULESET), "the native chart resolves for the knockout probes")
end

---@param move string strike identity under the probe
---@param moveType string compiled move type under the probe
---@return table<string, unknown> compiled-shaped move facts for the probe
local function strikeFacts(move, moveType)
  return {
    nativeId = 1,
    name = move,
    description = "",
    effect = 0,
    category = "physical",
    power = 1,
    moveType = moveType,
    accuracy = 30,
    basePp = 5,
    effectChance = 0,
    range = 0,
    priority = 0,
    behavior = { key = "damage", params = {} },
    target = "range_0",
    flags = { dealsDamage = true, checksAccuracy = true },
  }
end

---@param moveKey string strike identity under execution
---@param extra table<string, unknown> frame facts under the probe
---@return table terminal execution step plus observed damage
local function runStrike(moveKey, extra)
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
  local facts = {
    FISSURE = strikeFacts("FISSURE", "ground"),
    GUILLOTINE = strikeFacts("GUILLOTINE", "normal"),
  }
  if type(extra.accuracy) == "number" then
    facts.FISSURE.accuracy = extra.accuracy
  end
  if type(extra.lockOnAttacker) == "number" then
    local entry = ctx:entryOf(2)
    local handlers = require("libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers")
    ctx:addBattleEffect(
      handlers.definitionFor("lockon"),
      { kind = "active", combatant = 2, activation = entry.activation },
      { kind = "move", key = "LOCK_ON" },
      { version = 1, attacker = extra.lockOnAttacker }
    )
  end
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  local stream = BattleRng.new(extra.seed or HANDLER_SEED)
  local inputs = {
    actionId = 901,
    actor = { combatant = 1 },
    requestedMove = moveKey,
    executingMove = moveKey,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveKey, pp = 5, ppUps = 0 } },
    moveFacts = facts,
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
    typeChart = nativeChart(content),
    stream = stream,
    abilities = { user = "NONE", foe = "NONE" },
    foeLevel = 50,
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
    foeAfter = ctx:damage(2, 0, { kind = "probe" }).after,
    draws = stream:capture().calls,
  }
end

function T.knockout_falls_against_an_equal_level_foe()
  -- Seed pins the flat percent roll under the level-plus-accuracy
  -- chance, so the strike lands and spends the whole health bar.
  local probe = runStrike("FISSURE", { foeLevel = 50 })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the knockout connects")
  Assert.equal(probe.foeAfter, 0, "the knockout spends the whole health bar")
end

function T.knockout_fails_against_a_higher_level_foe()
  local probe = runStrike("GUILLOTINE", { foeLevel = 51 })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the outleveled knockout fails")
  Assert.isTrue(probe.foeAfter > 0, "the failed knockout deals nothing")
  Assert.equal(probe.draws, 1, "the outleveled attempt still spends its retail hit draw")
end

function T.underleveled_guaranteed_ohko_still_spends_the_fallback_draw()
  local probe = runStrike("GUILLOTINE", {
    foeLevel = 51,
    abilities = { user = "NO_GUARD", foe = "NONE" },
  })
  Assert.equal(probe.outcome.result, "failed", "No Guard cannot bypass the level gate")
  Assert.equal(probe.draws, 1, "underlevel guarantees follow the random fallback before the level failure")
end

function T.knockout_fails_against_sturdy()
  local probe = runStrike("FISSURE", { foeLevel = 30, abilities = { user = "NONE", foe = "STURDY" } })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "sturdy answers the knockout")
  Assert.isTrue(probe.foeAfter > 0, "the sturdy foe keeps its health")
end

function T.lock_on_guarantees_an_ohko_only_for_its_original_attacker()
  local aimed = runStrike("FISSURE", { foeLevel = 50, accuracy = 1, lockOnAttacker = 1 })
  Assert.equal(aimed.outcome.result, "hit", "the aiming attacker keeps its Lock-On guarantee")
  local other = runStrike("FISSURE", { foeLevel = 50, accuracy = 1, seed = 2, lockOnAttacker = 3 })
  Assert.equal(other.outcome.result, "missed", "another attacker must make the OHKO accuracy roll")
end

function T.no_guard_guarantees_ohko_accuracy_for_either_combatant()
  local user =
    runStrike("FISSURE", { foeLevel = 50, accuracy = 1, seed = 2, abilities = { user = "NO_GUARD", foe = "NONE" } })
  Assert.equal(user.outcome.result, "hit", "the user's No Guard guarantees the OHKO")
  local foe =
    runStrike("FISSURE", { foeLevel = 50, accuracy = 1, seed = 2, abilities = { user = "NONE", foe = "NO_GUARD" } })
  Assert.equal(foe.outcome.result, "hit", "the target's No Guard guarantees the OHKO")
end

function T.mold_breaker_bypasses_sturdy_for_an_ohko()
  local probe = runStrike("FISSURE", {
    foeLevel = 50,
    abilities = { user = "MOLD_BREAKER", foe = "STURDY" },
  })
  Assert.equal(probe.outcome.result, "hit", "Mold Breaker bypasses Sturdy's OHKO immunity")
  Assert.equal(probe.foeAfter, 0, "the OHKO removes the sturdy foe's health")
end

return { tests = T }
