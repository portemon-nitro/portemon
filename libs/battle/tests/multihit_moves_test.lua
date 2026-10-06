-- Multi-hit sequences land genuine staged damage per hit: sampled
-- members draw two to five with the native two-draw law and five under
-- skill link, fixed doubles land twice with one shared critical roll,
-- twineedle poisons through the usual gates, triple kick climbs ten per
-- kick with per-kick accuracy, and beat up sends every eligible party
-- member once under one accuracy check and one critical roll.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local HANDLER_SEED = 0x6E1D64

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
  NativeTypeChart.install(builder, "multihit-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "multihit-tests"
  )
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table<string, unknown> session type chart over the complete native matrix
local function nativeChart(content)
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  return assert(content:typeChart(Executor.RULESET), "the native chart resolves for the multi-hit probes")
end

---@param move string strike identity under the probe
---@param chance integer compiled effect chance under the probe
---@return table<string, unknown> compiled-shaped move facts for the probe
local function strikeFacts(move, chance)
  return {
    nativeId = 1,
    name = move,
    description = "",
    effect = 0,
    category = "physical",
    power = move == "BEAT_UP" and 10 or 25,
    moveType = "normal",
    accuracy = 100,
    basePp = 10,
    effectChance = chance,
    range = 0,
    priority = 0,
    behavior = { key = "damage", params = {} },
    target = "range_0",
    flags = { dealsDamage = true, checksAccuracy = true },
  }
end

---@param moveKey string strike identity under execution
---@param extra table<string, unknown> frame facts under the probe
---@return table terminal execution step plus observed damage and context
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
    moveFacts = {
      FURY_ATTACK = strikeFacts("FURY_ATTACK", 0),
      DOUBLE_HIT = strikeFacts("DOUBLE_HIT", 0),
      TWINEEDLE = strikeFacts("TWINEEDLE", 100),
      TRIPLE_KICK = strikeFacts("TRIPLE_KICK", 0),
      BEAT_UP = strikeFacts("BEAT_UP", 0),
    },
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
    stream = BattleRng.new(HANDLER_SEED),
    abilities = { user = "NONE", foe = "NONE" },
  }
  for key, value in pairs(extra or {}) do
    inputs[key] = value
  end
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

function T.sampled_sequences_deal_staged_damage_per_hit()
  local probe = runStrike("FURY_ATTACK", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the sampled sequence connects")
  -- Pre-bonus 12 rolls 99/85/85/88 across the four hits (13/11/11/12)
  -- before the same-type bonus lands 19/16/16/18 for 69 total.
  Assert.equal(probe.dealt, 69, "the sampled sequence deals four staged hits")
  Assert.equal(probe.strikes, 4, "the pinned seed samples four hits")
end

function T.skill_link_strikes_five_times()
  local probe = runStrike("FURY_ATTACK", { abilities = { user = "SKILL_LINK", foe = "NONE" } })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the skill-link sequence connects")
  -- Pre-bonus 12 rolls 98/99/85/85/88 (13/13/11/11/12) before the
  -- same-type bonus lands 19/19/16/16/18 for 88 total.
  Assert.equal(probe.dealt, 88, "skill link deals five staged hits")
  Assert.equal(probe.strikes, 5, "skill link always strikes five times")
end

function T.fixed_doubles_land_twice()
  local probe = runStrike("DOUBLE_HIT", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the fixed double connects")
  -- Pre-bonus 12 rolls 98 then 93 (13/13) before the same-type bonus
  -- lands 19 per hit for 38 total.
  Assert.equal(probe.dealt, 38, "the fixed double lands twice")
  Assert.equal(probe.strikes, 2, "fixed doubles strike exactly twice")
end

function T.twineedle_poisons_through_the_usual_gates()
  local probe = runStrike("TWINEEDLE", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the twineedle connects")
  -- Pre-bonus 12 rolls 98 then 99 (13/13) before the same-type bonus
  -- lands 19 per hit for 38 total.
  Assert.equal(probe.dealt, 38, "twineedle lands twice")
  Assert.equal(probe.strikes, 2, "twineedle strikes exactly twice")
  local ctx = probe.ctx
  Assert.equal(ctx:statusOf(2), "poison", "twineedle poisons its target")
end

function T.triple_kick_climbs_ten_per_kick()
  local probe = runStrike("TRIPLE_KICK", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the triple kick connects")
  -- Powers 10/20/30 run pre-bonus 4/9/14, roll 98/99/85 (5/10/13), and
  -- the same-type bonus lands 7/15/19 for 41 total.
  Assert.equal(probe.dealt, 41, "triple kick climbs ten per kick")
  Assert.equal(probe.strikes, 3, "triple kick lands three kicks")
end

function T.beat_up_sends_every_eligible_party_member_once()
  local probe = runStrike("BEAT_UP", {
    beatup = {
      defense = 60,
      members = {
        { attack = 70, level = 20 },
        { attack = 50, level = 15 },
      },
    },
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the beat up connects")
  Assert.equal(probe.dealt, 5, "beat up lands one hit per eligible member")
  Assert.equal(probe.strikes, 2, "both party members answer")
end

return { tests = T }
