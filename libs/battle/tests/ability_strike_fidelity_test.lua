-- Source-backed ability behavior on the real move continuation.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local StatStages = require("libs.battle.src.gen4.StatStages")

local T = { tests = {} }
local seed = 771626189

local function state()
  local contracts = SessionFixture.sessionContracts()
  local user = { id = 1, mon = SessionFixture.makeMon(11, { level = 50 }) }
  local foe = { id = 2, mon = SessionFixture.makeMon(23, { level = 50 }) }
  local scenario = SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { user }),
      SessionFixture.participant(2, 2, "scripted", { foe }),
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
    NativeTypeChart.install(builder, "ability-strike-fidelity-tests")
    local behaviors = BattleBehaviorBuilder.new()
    behaviors:registerRuleset(Executor.RULESET, { key = Executor.RULESET, chart = Executor.RULESET }, "tests")
    chartCache = assert(BattleContent.new(builder:freeze(), behaviors:freeze()):typeChart(Executor.RULESET))
  end
  return chartCache
end

local function strike(live, move, moveType, category, options)
  local opts = options or {}
  local Execution = require("libs.battle.src.gen4.MoveExecution")
  local ctx = SessionFixture.sessionContracts().Context.wrap(live)
  local facts = {
    power = opts.power or 40,
    accuracy = opts.accuracy or 0,
    category = category,
    moveType = moveType,
    effectChance = opts.effectChance or 0,
    flags = opts.flags or {},
  }
  local attackStage = opts.attackStage or 0
  local defenseStage = opts.defenseStage or 0
  if opts.moveContact == true then
    facts.contact = true
  end
  local stream = BattleRng.new(opts.seed or seed)
  if opts.forcedRoll ~= nil then
    stream.nextU16 = function(_self, _label, _cause)
      if opts.draws ~= nil then
        opts.draws[#opts.draws + 1] = _label
      end
      return opts.forcedRoll
    end
  end
  local inputs = {
    actionId = 9021,
    actor = { combatant = 1 },
    requestedMove = move,
    executingMove = move,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = move, pp = 10, ppUps = 0 } },
    moveFacts = { [move] = facts },
    combat = {
      level = 50,
      attack = StatStages.effective(120, attackStage, category == "physical" and "attack" or "specialAttack"),
      defense = StatStages.effective(90, defenseStage, category == "physical" and "defense" or "specialDefense"),
      rawAttack = 120,
      rawDefense = 90,
      attackStage = attackStage,
      defenseStage = defenseStage,
    },
    burned = false,
    guts = false,
    weather = opts.weather or "none",
    weatherSuppressed = false,
    abilities = { user = opts.userAbility or "NONE", foe = opts.foeAbility or "NONE" },
    attackerTypes = opts.attackerTypes or { "normal" },
    defenderTypes = { [2] = opts.defenderTypes or { "normal" } },
    typeChart = chart(),
    friendship = 255,
    genders = opts.genders or { [1] = "male", [2] = "female" },
    stream = stream,
  }
  local node = Execution.start(inputs)
  for _ = 1, 12 do
    node = Execution.step(ctx, node)
    if node.kind == "complete" and node.frame == nil then
      break
    end
  end
  return ctx, node
end

local function dealt(ctx)
  local entry = ctx:entryOf(2)
  return entry.maxHp - ctx:damage(2, 0, { kind = "probe" }).after
end

function T.tests.flash_fire_persists_into_a_later_fire_strike_boost()
  local ordinary = state()
  local boosted = state()
  local boostedCtx = SessionFixture.sessionContracts().Context.wrap(boosted)
  boostedCtx:addBattleEffect(
    require("libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers").definitionFor("flashfire"),
    { kind = "active", combatant = 1, activation = boostedCtx:entryOf(1).activation },
    { kind = "probe" },
    { version = 1 }
  )
  strike(ordinary, "TACKLE", "fire", "physical")
  strike(boosted, "TACKLE", "fire", "physical")
  Assert.isTrue(
    dealt(boostedCtx) > dealt(SessionFixture.sessionContracts().Context.wrap(ordinary)),
    "Flash Fire increases a later Fire strike's damage"
  )
end

function T.tests.unaware_ignores_the_attacking_pokemon_attack_stages()
  local boosted = state()
  local unaware = state()
  strike(boosted, "TACKLE", "normal", "physical", { attackStage = 6 })
  strike(unaware, "TACKLE", "normal", "physical", { attackStage = 6, foeAbility = "UNAWARE" })
  Assert.isTrue(
    dealt(SessionFixture.sessionContracts().Context.wrap(boosted))
      > dealt(SessionFixture.sessionContracts().Context.wrap(unaware)),
    "Unaware ignores the foe's positive Attack stages: "
      .. dealt(SessionFixture.sessionContracts().Context.wrap(boosted))
      .. " vs "
      .. dealt(SessionFixture.sessionContracts().Context.wrap(unaware))
  )
end

function T.tests.unaware_ignores_the_defending_pokemon_defense_stages()
  local guarded = state()
  local unaware = state()
  strike(guarded, "TACKLE", "normal", "physical", { defenseStage = 6 })
  strike(unaware, "TACKLE", "normal", "physical", { defenseStage = 6, userAbility = "UNAWARE" })
  Assert.isTrue(
    dealt(SessionFixture.sessionContracts().Context.wrap(unaware))
      > dealt(SessionFixture.sessionContracts().Context.wrap(guarded)),
    "Unaware ignores the target's positive Defense stages"
  )
end

function T.tests.serene_grace_doubles_a_damage_move_secondary_chance()
  local found = false
  for currentSeed = 1, 100 do
    local ordinary = state()
    local serene = state()
    local ordinaryCtx = strike(ordinary, "FLAME_WHEEL", "fire", "physical", {
      effectChance = 50,
      seed = currentSeed,
    })
    local sereneCtx = strike(serene, "FLAME_WHEEL", "fire", "physical", {
      effectChance = 50,
      userAbility = "SERENE_GRACE",
      seed = currentSeed,
    })
    if ordinaryCtx:statusOf(2) == nil and sereneCtx:statusOf(2) == "burn" then
      found = true
      break
    end
  end
  Assert.isTrue(found, "Serene Grace doubles Flame Wheel's secondary chance")
end

function T.tests.liquid_ooze_backfires_direct_drain_damage()
  local live = state()
  local ctx = SessionFixture.sessionContracts().Context.wrap(live)
  ctx:damage(1, 25, { kind = "probe" })
  local before = ctx:damage(1, 0, { kind = "probe" }).before
  local _, result = strike(live, "GIGA_DRAIN", "grass", "special", { foeAbility = "LIQUID_OOZE" })
  Assert.equal(result.result, "hit", "Giga Drain resolves against Liquid Ooze")
  Assert.isTrue(ctx:damage(1, 0, { kind = "probe" }).before < before, "Liquid Ooze damages the draining attacker")
end

function T.tests.cute_charm_cannot_infatuate_after_its_holder_faints()
  local survivor = state()
  local draws = {}
  local survivorCtx = strike(survivor, "TACKLE", "normal", "physical", {
    foeAbility = "CUTE_CHARM",
    moveContact = true,
    forcedRoll = 0,
    draws = draws,
  })
  Assert.isTrue(
    table.concat(draws, ","):find("contact_chance", 1, true) ~= nil,
    "the source contact ability checkpoint consumes its chance roll"
  )
  Assert.isTrue(survivorCtx:hasBattleEffect(1, "infatuation"), "Cute Charm triggers on a contact hit")
  local lethal = state()
  local ctx = strike(lethal, "TACKLE", "normal", "physical", {
    power = 500,
    foeAbility = "CUTE_CHARM",
    moveContact = true,
    forcedRoll = 0,
  })
  Assert.equal(ctx:damage(2, 0, { kind = "probe" }).after, 0, "the contact hit faints the Cute Charm holder")
  Assert.isFalse(ctx:hasBattleEffect(1, "infatuation"), "a fainted Cute Charm holder cannot infatuate the attacker")
end

return T
