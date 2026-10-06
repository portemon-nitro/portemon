-- Special-law strikes follow their source scripts exactly: hidden
-- power derives type and power from user individual values, present
-- rolls damage or healing, snore demands sleep, stomp doubles against
-- minimizing targets, wake-up slap doubles and wakes sleepers, last
-- resort demands every other known move used, weather ball answers the
-- field weather, natural gift throws the held berry and spends it, fling
-- throws the held item for its fling effect and spends it, and the
-- self-hindering trio drops its stages on every connecting strike.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local HANDLER_SEED = 0x5EC1A1

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
  NativeTypeChart.install(builder, "special-law-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "special-law-tests"
  )
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table<string, unknown> session type chart over the complete native matrix
local function nativeChart(content)
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  return assert(content:typeChart(Executor.RULESET), "the native chart resolves for the special probes")
end

---@param move string strike identity under the probe
---@param power integer compiled base power under the probe
---@param moveType string compiled move type under the probe
---@param category string compiled damage category under the probe
---@param accuracy integer compiled accuracy under the probe
---@param chance integer compiled effect chance under the probe
---@return table<string, unknown> compiled-shaped move facts for the probe
local function strikeFacts(move, power, moveType, category, accuracy, chance)
  return {
    nativeId = 1,
    name = move,
    description = "",
    effect = 0,
    category = category,
    power = power,
    moveType = moveType,
    accuracy = accuracy,
    basePp = 10,
    effectChance = chance,
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
    HIDDEN_POWER = strikeFacts("HIDDEN_POWER", 1, "normal", "special", 100, 0),
    PRESENT = strikeFacts("PRESENT", 1, "normal", "physical", 90, 0),
    SNORE = strikeFacts("SNORE", 40, "normal", "special", 100, 30),
    STOMP = strikeFacts("STOMP", 65, "normal", "physical", 100, 30),
    WAKE_UP_SLAP = strikeFacts("WAKE_UP_SLAP", 60, "fighting", "physical", 100, 0),
    LAST_RESORT = strikeFacts("LAST_RESORT", 130, "normal", "physical", 100, 0),
    WEATHER_BALL = strikeFacts("WEATHER_BALL", 50, "normal", "special", 100, 0),
    NATURAL_GIFT = strikeFacts("NATURAL_GIFT", 1, "normal", "physical", 100, 0),
    FLING = strikeFacts("FLING", 1, "dark", "physical", 100, 0),
    DREAM_EATER = strikeFacts("DREAM_EATER", 100, "psychic", "special", 100, 0),
    STRUGGLE = strikeFacts("STRUGGLE", 50, "normal", "physical", 100, 0),
    TAKE_DOWN = strikeFacts("TAKE_DOWN", 90, "normal", "physical", 100, 0),
    CLOSE_COMBAT = strikeFacts("CLOSE_COMBAT", 120, "fighting", "physical", 100, 0),
    SUPERPOWER = strikeFacts("SUPERPOWER", 120, "fighting", "physical", 100, 0),
    DRACO_METEOR = strikeFacts("DRACO_METEOR", 140, "dragon", "special", 90, 100),
    LEAF_STORM = strikeFacts("LEAF_STORM", 140, "grass", "special", 90, 100),
    OVERHEAT = strikeFacts("OVERHEAT", 140, "fire", "special", 90, 100),
  }
end

---@param live table live battle state under preparation
---@param combatantId integer holder combatant under preparation
---@param item string item key the holder carries under preparation
local function seedHeldItem(live, combatantId, item)
  local state = SessionFixture.requirePresent("libs.battle.src.BattleState", "live battle state owns the probe")
  local holder = state.combatant(live, combatantId)
  local mon = holder.mon --[[@as table<string, unknown>]]
  mon.heldItem = item
end

---@param live table live battle state under preparation
---@param combatantId integer combatant receiving the persistent condition
---@param key string condition key under preparation
local function seedCondition(live, combatantId, key)
  local state = SessionFixture.requirePresent("libs.battle.src.BattleState", "live battle state owns the probe")
  local combatant = state.combatant(live, combatantId)
  local mon = combatant.mon --[[@as table<string, unknown>]]
  mon.condition = { currentHp = combatant.hp, effects = { { key = key, version = 1, state = { turns = 3 } } } }
end

---@param moveKey string strike identity under execution
---@param extra table<string, unknown> frame facts under the probe
---@param setup fun(live: table, ctx: table)|nil battle preparation under the probe
---@param foeHp integer? defender health override before the strike, full when nil
---@param foeTypes string[]? semantic defender types under the strike, normal when nil
---@return table terminal execution step plus observed damage and context
local function runStrike(moveKey, extra, setup, foeHp, foeTypes, seed)
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
  if setup ~= nil then
    setup(live, ctx)
  end
  if foeHp ~= nil then
    local foe = state.combatant(live, 2)
    foe.hp = foeHp
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
    moveFacts = probeMoveFacts(),
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
    abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" },
    attackerTypes = { "normal" },
    defenderTypes = { [2] = foeTypes or { "normal" } },
    typeChart = nativeChart(content),
    stream = BattleRng.new(seed or HANDLER_SEED),
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


  local afterFoe = ctx:damage(2, 0, { kind = "probe" }).after
  local holder = state.combatant(live, 1)
  return {
    outcome = finished,
    dealt = beforeFoe - afterFoe,
    foeAfter = afterFoe,
    held = (holder.mon --[[@as table<string, unknown>]]).heldItem,
    ctx = ctx,
  }
end

local ALL_ONES_IVS = { hp = 31, attack = 31, defense = 31, speed = 31, specialAttack = 31, specialDefense = 31 }

function T.hidden_power_derives_dark_seventy_from_all_ones()
  -- All set bits: type index 63 maps past mystery to dark, power index
  -- 63 maps to seventy.
  local probe = runStrike("HIDDEN_POWER", { userIvs = ALL_ONES_IVS })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the hidden power connects")
  Assert.equal(probe.dealt, 30, "all set bits derive dark seventy")
end

function T.hidden_power_fighting_fails_against_ghosts()
  local probe = runStrike("HIDDEN_POWER", {
    userIvs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
  }, nil, nil, { "ghost" })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(probe.dealt, 0, "fighting hidden power cannot touch ghosts")
end

function T.hidden_power_dark_hits_ghosts_super_effectively()
  local probe = runStrike("HIDDEN_POWER", { userIvs = ALL_ONES_IVS }, nil, nil, { "ghost" })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the dark hidden power connects")
  Assert.isTrue(probe.dealt > 30, "dark hidden power punishes ghosts")
end

function T.hidden_power_derives_fighting_thirty_from_all_zeroes()
  local probe = runStrike("HIDDEN_POWER", {
    userIvs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the hidden power connects")
  Assert.equal(probe.dealt, 28, "all clear bits derive fighting thirty")
end

function T.present_heals_on_its_top_branch()
  local probe = runStrike("PRESENT", {}, nil, 100, nil, 7)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the present connects")
  Assert.equal(probe.dealt, -57, "the top present branch heals a quarter ceiling")
  Assert.equal(probe.foeAfter, 157, "the healed target keeps its restoration")
end

function T.present_strikes_forty_on_its_low_branch()
  local probe = runStrike("PRESENT", {}, nil, nil, nil, 1)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the present connects")
  -- Pre-bonus 19 rolls 86 first (floor(21*86/100) = 18) and then takes
  -- the same-type bonus for 27.
  Assert.equal(probe.dealt, 27, "forty-power presents strike at forty")
end

function T.present_strikes_eighty_on_its_middle_branch()
  local probe = runStrike("PRESENT", {}, nil, nil, nil, 3)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the present connects")
  Assert.equal(probe.dealt, 60, "eighty-power presents strike at eighty")
end

function T.present_strikes_one_twenty_on_its_high_branch()
  local probe = runStrike("PRESENT", {}, nil, nil, nil)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the present connects")
  -- Pre-bonus 57 rolls 92 first (floor(59*92/100) = 54) and then takes
  -- the same-type bonus for 81.
  Assert.equal(probe.dealt, 81, "one-twenty-power presents strike at one-twenty")
end

function T.snore_demands_sleep()
  local probe = runStrike("SNORE", { userAsleep = true })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the sleeping snore connects")
  Assert.equal(probe.dealt, 27, "sleeping snores connect at full power")
end

function T.snore_fails_while_awake()
  local probe = runStrike("SNORE", { userAsleep = false })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the waking snore fails")
end

function T.stomp_doubles_against_minimizing_targets()
  local NativeEffects = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "typed battle-local writes own volatile definitions"
  )
  local probe = runStrike("STOMP", {}, function(live, ctx)
    local state = SessionFixture.requirePresent("libs.battle.src.BattleState", "live battle state owns the probe")
    local foe = state.combatant(live, 2)
    local activation = (foe.active --[[@as table<string, unknown>]]).activation
    ctx:addBattleEffect(
      NativeEffects.definitionFor("minimize"),
      { kind = "active", combatant = 2, activation = activation },
      { kind = "move", combatant = 2 },
      { version = 1 }
    )
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the stomp connects")
  Assert.equal(probe.dealt, 84, "stomps double against minimizing targets")
end

function T.stomp_holds_base_power_otherwise()
  local probe = runStrike("STOMP", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the stomp connects")
  Assert.equal(probe.dealt, 43, "stomps hold base power otherwise")
end

function T.wake_up_slap_doubles_and_wakes_sleepers()
  local probe = runStrike("WAKE_UP_SLAP", {}, function(live, ctx)
    seedCondition(live, 2, "sleep")
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the slap connects")
  -- Doubled pre-bonus 57 rolls 92 first (floor(59*92/100) = 51) and then
  -- doubles into the sleeping target for 102.
  Assert.equal(probe.dealt, 102, "slaps double and wake sleepers")
  local ctx = probe.ctx
  Assert.isNil(ctx:statusOf(2), "the slap wakes its target")
end

function T.wake_up_slap_holds_base_power_when_awake()
  local probe = runStrike("WAKE_UP_SLAP", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the slap connects")
  Assert.equal(probe.dealt, 52, "slaps hold base power when awake")
end

function T.last_resort_demands_every_other_known_move_used()
  local probe = runStrike("LAST_RESORT", {
    userMoves = { "TACKLE", "GROWL", "LAST_RESORT" },
    usedMoves = { "TACKLE", "GROWL" },
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the earned last resort connects")
  Assert.equal(probe.dealt, 84, "earned last resorts connect at full power")
end

function T.last_resort_fails_with_an_unused_move()
  local probe = runStrike("LAST_RESORT", {
    userMoves = { "TACKLE", "GROWL", "LAST_RESORT" },
    usedMoves = { "TACKLE" },
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the unearned last resort fails")
end

function T.weather_ball_answers_rain()
  local NativeEffects = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "typed battle-local writes own weather definitions"
  )
  local probe = runStrike("WEATHER_BALL", {}, function(_, ctx)
    ctx:addBattleEffect(
      NativeEffects.definitionFor("raindance"),
      { kind = "field" },
      { kind = "move", combatant = 1 },
      { version = 1, turns = 5 }
    )
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the rain weather ball connects")
  Assert.equal(probe.dealt, 44, "rain doubles weather ball into water typing")
end

function T.weather_ball_holds_base_power_without_weather()
  local probe = runStrike("WEATHER_BALL", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the plain weather ball connects")
  -- Pre-bonus 24 rolls 88 first (floor(26*88/100) = 22) and then takes
  -- the same-type bonus for 33.
  Assert.equal(probe.dealt, 33, "calm weather balls hold base power")
end

function T.natural_gift_throws_the_held_berry_and_spends_it()
  local probe = runStrike("NATURAL_GIFT", {
    heldItem = "SITRUS_BERRY",
    itemFacts = { SITRUS_BERRY = { naturalGift = { power = 60, typeId = 14, type = "psychic" } } },
  }, function(live, _)
    seedHeldItem(live, 1, "SITRUS_BERRY")
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the natural gift connects")
  Assert.equal(probe.dealt, 26, "the berry gift strikes at berry power")
  Assert.equal(probe.held, "NONE", "the gift spends its berry")
end

function T.natural_gift_fails_empty_handed()
  local probe = runStrike("NATURAL_GIFT", { heldItem = nil, itemFacts = {} })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the empty-handed gift fails")
end

function T.fling_throws_the_held_item_for_toxic_and_spends_it()
  local probe = runStrike("FLING", {
    heldItem = "TOXIC_ORB",
    itemFacts = { TOXIC_ORB = { fling = { effect = 29, power = 30 } } },
  }, function(live, _)
    seedHeldItem(live, 1, "TOXIC_ORB")
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the fling connects")
  Assert.equal(probe.dealt, 14, "the orb fling strikes at fling power")
  Assert.equal(probe.held, "NONE", "the fling spends its item")
  local ctx = probe.ctx
  Assert.equal(ctx:statusOf(2), "toxic", "the orb fling badly poisons its target")
end

function T.fling_fails_empty_handed()
  local probe = runStrike("FLING", { heldItem = nil, itemFacts = {} })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the empty-handed fling fails")
end

function T.close_combat_drops_both_defenses_on_a_hit()
  local probe = runStrike("CLOSE_COMBAT", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the close combat connects")
  local ctx = probe.ctx
  local stages = ctx:entryOf(1).stages --[[@as table<string, integer>]]
  Assert.equal(stages.defense, -1, "close combat drops user defense")
  Assert.equal(stages.specialDefense, -1, "close combat drops user special defense")
end

function T.superpower_drops_the_attacking_pair_on_a_hit()
  local probe = runStrike("SUPERPOWER", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the superpower connects")
  local ctx = probe.ctx
  local stages = ctx:entryOf(1).stages --[[@as table<string, integer>]]
  Assert.equal(stages.attack, -1, "superpower drops user attack")
  Assert.equal(stages.defense, -1, "superpower drops user defense")
end

function T.draco_meteor_drops_special_attack_twice_on_a_hit()
  local probe = runStrike("DRACO_METEOR", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the draco meteor connects")
  local ctx = probe.ctx
  local stages = ctx:entryOf(1).stages --[[@as table<string, integer>]]
  Assert.equal(stages.specialAttack, -2, "draco meteor drops special attack twice")
end

function T.leaf_storm_drops_special_attack_twice_on_a_hit()
  local probe = runStrike("LEAF_STORM", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the leaf storm connects")
  local ctx = probe.ctx
  local stages = ctx:entryOf(1).stages --[[@as table<string, integer>]]
  Assert.equal(stages.specialAttack, -2, "leaf storm drops special attack twice")
end

function T.overheat_drops_special_attack_twice_on_a_hit()
  local probe = runStrike("OVERHEAT", {})
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the overheat connects")
  local ctx = probe.ctx
  local stages = ctx:entryOf(1).stages --[[@as table<string, integer>]]
  Assert.equal(stages.specialAttack, -2, "overheat drops special attack twice")
end

---@param seed integer fixed generator state for the recording stream
---@param labels table<integer, string> draw labels recorded in stream order
---@return table recording battle stream proxy over the native generator
local function recordingStream(seed, labels)
  local inner = BattleRng.new(seed)
  local proxy = {}
  setmetatable(proxy, {
    __index = function(_, key)
      if key == "nextU16" then
        return function(_, label, cause)
          labels[#labels + 1] = label
          return inner:nextU16(label, cause)
        end
      end
      local value = inner[key]
      if type(value) == "function" then
        return function(_, ...)
          return value(inner, ...)
        end
      end
      return value
    end,
  })
  return proxy
end

---@param live table live battle state under preparation
---@param combatantId integer combatant receiving the health projection
---@param maxHp integer battle maximum health under the probe
---@param hp integer current health under the probe
local function seedHealth(live, combatantId, maxHp, hp)
  local state = SessionFixture.requirePresent("libs.battle.src.BattleState", "live battle state owns the probe")
  local combatant = state.combatant(live, combatantId)
  combatant.maxHp = maxHp
  combatant.hp = hp
end

-- Dream Eater fails outright against awake targets: no damage lands, no
-- health returns, and no critical or damage-family draw is consumed.
function T.dream_eater_fails_against_awake_targets_without_damage_draws()
  local labels = {}
  local beforeUser = nil
  local probe = runStrike("DREAM_EATER", { stream = recordingStream(HANDLER_SEED, labels) }, function(live, ctx)
    seedHealth(live, 1, 200, 150)
    beforeUser = ctx:damage(1, 0, { kind = "probe" }).before
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the dream eater fails against awake targets")
  Assert.equal(probe.dealt, 0, "awake targets take no dream damage")
  local afterUser = probe.ctx:damage(1, 0, { kind = "probe" }).before
  Assert.equal(afterUser, beforeUser, "no health returns from an awake target")
  for _, label in ipairs(labels) do
    Assert.isTrue(
      label ~= "critical_check" and label ~= "damage_roll",
      "awake dream eater spends no critical or damage draw"
    )
  end
end

-- Dream Eater strikes sleeping targets for ordinary staged damage and
-- restores half the damage dealt, rounded down.
function T.dream_eater_drains_half_against_sleeping_targets()
  local beforeUser = nil
  local probe = runStrike("DREAM_EATER", {}, function(live, ctx)
    seedCondition(live, 2, "sleep")
    seedHealth(live, 1, 200, 150)
    beforeUser = ctx:damage(1, 0, { kind = "probe" }).before
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the dream eater connects against sleepers")
  Assert.isTrue(probe.dealt > 0, "sleeping targets take dream damage")
  local afterUser = probe.ctx:damage(1, 0, { kind = "probe" }).before
  Assert.equal(afterUser - beforeUser --[[@as integer]], math.floor(probe.dealt / 2), "dream eater restores half dealt")
end

-- A live doll keeps Dream Eater from reaching its sleeping target: the
-- body takes nothing and the doll itself is untouched.
function T.dream_eater_cannot_reach_behind_a_doll()
  local probe = runStrike("DREAM_EATER", {}, function(live, ctx)
    seedCondition(live, 2, "sleep")
    local NativeEffects = SessionFixture.requirePresent(
      "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
      "typed battle-local writes own volatile definitions"
    )
    local entry = ctx:entryOf(2)
    ctx:addBattleEffect(
      NativeEffects.definitionFor("substitute"),
      { kind = "active", combatant = 2, activation = entry.activation },
      { kind = "move", combatant = 2 },
      { version = 1, hp = 10 }
    )
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "failed", "the doll blocks the dream eater")
  Assert.equal(probe.dealt, 0, "the shielded body takes no dream damage")
  Assert.isTrue(probe.ctx:hasBattleEffect(2, "substitute"), "the doll survives the blocked dream")
end

-- Struggle recoil follows user maximum health, not dealt damage: two
-- materially different blows cost the same quarter, and tiny maxima
-- still cost at least one.
function T.struggle_recoil_follows_user_maximum_health()
  ---@param defense integer staged defender defense under the probe
  ---@return integer recoil paid after the successful struggle
  ---@return integer damage dealt to the defender by the struggle
  local function recoilAfter(defense)
    local probe = runStrike("STRUGGLE", {
      combat = {
        level = 50,
        attack = 120,
        defense = defense,
        rawAttack = 120,
        rawDefense = defense,
        attackStage = 0,
        defenseStage = 0,
      },
    }, function(live, _)
      seedHealth(live, 1, 100, 100)
    end)
    local outcome = probe.outcome --[[@as table<string, unknown>]]
    Assert.equal(outcome.result, "hit", "the struggle connects")
    return 100 - probe.ctx:damage(1, 0, { kind = "probe" }).before, probe.dealt
  end
  local soft, softDealt = recoilAfter(50)
  local hard, hardDealt = recoilAfter(200)
  Assert.isTrue(softDealt > hardDealt, "the two struggles deal materially different damage")
  Assert.equal(soft, 25, "soft-target struggles cost quarter maximum")
  Assert.equal(hard, 25, "hard-target struggles cost quarter maximum")
  local tiny = runStrike("STRUGGLE", {}, function(live, _)
    seedHealth(live, 1, 3, 3)
  end)
  local tinyOutcome = tiny.outcome --[[@as table<string, unknown>]]
  Assert.equal(tinyOutcome.result, "hit", "the tiny struggle connects")
  Assert.equal(3 - tiny.ctx:damage(1, 0, { kind = "probe" }).before, 1, "tiny maxima still cost one")
end

-- Ordinary recoil answers Rock Head and Magic Guard: the unguarded
-- control pays while both guarded strikers pay nothing.
function T.ordinary_recoil_yields_to_rock_head_and_magic_guard()
  ---@param ability string|nil attacker ability under the probe
  ---@return integer recoil paid after the connecting take-down
  local function recoilAfter(ability)
    local probe = runStrike("TAKE_DOWN", { abilities = { user = ability, foe = "ADAPTABILITY" } }, function(live, _)
      seedHealth(live, 1, 200, 200)
    end)
    local outcome = probe.outcome --[[@as table<string, unknown>]]
    Assert.equal(outcome.result, "hit", "the take-down connects")
    Assert.isTrue(probe.dealt > 0, "the take-down deals damage")
    return 200 - probe.ctx:damage(1, 0, { kind = "probe" }).before
  end
  Assert.isTrue(recoilAfter("ADAPTABILITY") > 0, "unguarded recoil is paid")
  Assert.equal(recoilAfter("ROCK_HEAD"), 0, "rock head suppresses ordinary recoil")
  Assert.equal(recoilAfter("MAGIC_GUARD"), 0, "magic guard suppresses ordinary recoil")
end

-- Unguarded ordinary recoil keeps its dealt-derived fraction: a quarter
-- of the inflicted damage with a minimum of one.
function T.unguarded_recoil_keeps_quarter_dealt_minimum_one()
  local probe = runStrike("TAKE_DOWN", { abilities = { user = "ADAPTABILITY", foe = "ADAPTABILITY" } }, function(live, _)
    seedHealth(live, 1, 200, 200)
  end)
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the take-down connects")
  local expected = math.floor(probe.dealt / 4)
  if expected < 1 then
    expected = 1
  end
  Assert.equal(200 - probe.ctx:damage(1, 0, { kind = "probe" }).before, expected, "unguarded recoil bills quarter dealt")
end

-- Struggle recoil ignores both guards: the source performs no ability
-- check on its maximum-health backlash.
function T.struggle_recoil_ignores_rock_head_and_magic_guard()
  ---@param ability string attacker ability under the probe
  ---@return integer recoil paid after the successful struggle
  local function recoilAfter(ability)
    local probe = runStrike("STRUGGLE", { abilities = { user = ability, foe = "ADAPTABILITY" } }, function(live, _)
      seedHealth(live, 1, 100, 100)
    end)
    local outcome = probe.outcome --[[@as table<string, unknown>]]
    Assert.equal(outcome.result, "hit", "the guarded struggle connects")
    return 100 - probe.ctx:damage(1, 0, { kind = "probe" }).before
  end
  Assert.equal(recoilAfter("ROCK_HEAD"), 25, "rock head cannot stop struggle backlash")
  Assert.equal(recoilAfter("MAGIC_GUARD"), 25, "magic guard cannot stop struggle backlash")
end

return { tests = T }
