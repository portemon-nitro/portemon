-- Battle Bag planning stays pure over declared state: previews validate
-- and reserve without consuming or touching the live Bag, canceled plans
-- release the shared stack by disappearing, stale and illegal choices fail
-- with typed errors and no side effects, and execution consumes exactly
-- once at its own checkpoint into the battle-owned ledger.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")

local T = {}

local NATIVE_SEED = 3

---@param behavior string missing owner under test
---@return table the loaded battle item planner
local function itemUse(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.ItemUse", behavior)
end

---@return table live bag service holding the shared stack under observation
local function liveService()
  local service = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(service:add("POTION", 1), "the shared stack starts with one unit")
  return service
end

---@return table declared battle inventory with one potion and a wounded holder
local function declaredView()
  return {
    inventories = { party = { quantities = { POTION = 1, REVIVE = 0 }, revision = 0 } },
    outstanding = {},
    combatants = { [1] = { hp = 10, maxHp = 30 } },
  }
end

---@return table<string, table<string, unknown>> generated semantic facts for the shared potion stock
local function potionFacts()
  return {
    POTION = {
      partyUse = {
        kind = "medicine",
        restore = { kind = "fixed", amount = 20 },
        cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
        revive = "none",
        mood = 0,
      },
    },
  }
end

---@param combatant integer holder receiving the item under test
---@return table item choice over the shared stack
local function potionChoice(combatant)
  return { inventoryId = "party", item = "POTION", target = { kind = "combatant", combatant = combatant } }
end

---@param view table declared battle state under test
---@return table battle-owned execution state copied from the declared view
local function executionState(view)
  return {
    inventories = { party = { quantities = { POTION = view.inventories.party.quantities.POTION }, revision = 0 } },
    ledger = {},
    combatants = { [1] = { hp = view.combatants[1].hp, maxHp = view.combatants[1].maxHp } },
  }
end

-- Planning validates, reserves, and reports a deterministic checkpoint
-- while the live Bag, the declared quantities, and the plan inputs stay
-- exactly as they were.
function T.planning_leaves_live_state_and_declared_state_untouched()
  local ItemUse = itemUse("battle bag planning owns selection without consuming")
  local live = liveService()
  local revisionBefore = live:revision()
  local view = declaredView()
  local choice = potionChoice(1)

  Assert.isTrue(ItemUse.validateChoice(choice, view), "the legal choice validates")
  local plan = ItemUse.plan(choice, view, potionFacts())
  Assert.isNil(plan.failureReason, "the legal plan carries no failure")
  Assert.equal(plan.item, "POTION", "the plan names its item")
  Assert.equal(plan.inventoryId, "party", "the plan names its inventory owner")
  Assert.deepEqual(plan.target, choice.target, "the plan retargets the chosen holder")
  Assert.isTrue(plan.target ~= choice.target, "the plan target shares no mutable state with the choice")
  Assert.isTrue(
    type(plan.consumptionCheckpoint) == "string" and plan.consumptionCheckpoint ~= "",
    "the plan names its consumption checkpoint"
  )
  Assert.isTrue(type(plan.effectOperations) == "table" and #plan.effectOperations >= 1, "the plan lists its effects")

  local again = ItemUse.plan(choice, view, potionFacts())
  Assert.equal(again.consumptionCheckpoint, plan.consumptionCheckpoint, "planning is deterministic per checkpoint")
  Assert.deepEqual(again.effectOperations, plan.effectOperations, "planning is deterministic per effect")

  Assert.equal(live:revision(), revisionBefore, "planning never touches the live Bag revision")
  Assert.equal(live:quantity("POTION"), 1, "planning never touches the live Bag stack")
  Assert.deepEqual(
    view.inventories.party.quantities,
    { POTION = 1, REVIVE = 0 },
    "planning never consumes declared stock"
  )
  Assert.deepEqual(view.outstanding, {}, "planning never books hidden reservations")
end

-- Outstanding plans gate the same stack: a second plan for the last unit
-- carries its failure while dropping the canceled plan restores legality
-- without any release call mutating shared state.
function T.canceled_plans_release_the_shared_stack()
  local ItemUse = itemUse("battle bag planning owns selection without consuming")
  local live = liveService()
  local revisionBefore = live:revision()
  local view = declaredView()
  local choice = potionChoice(1)

  local first = ItemUse.plan(choice, view, potionFacts())
  Assert.isNil(first.failureReason, "the first plan for the last unit succeeds")
  view.outstanding = { first }

  local ok, err = ItemUse.validateChoice(choice, view)
  Assert.isNil(ok, "the shared last unit validates only once")
  Assert.equal((err --[[@as table]]).code, "empty", "the second attempt reports the empty stack")
  local blocked = ItemUse.plan(choice, view, potionFacts())
  Assert.equal(blocked.failureReason, "empty", "the second plan carries its failure")
  Assert.deepEqual(blocked.effectOperations, {}, "a failed plan lists no effects")

  view.outstanding = {}
  Assert.isTrue(ItemUse.validateChoice(choice, view), "dropping the canceled plan restores legality")
  local revived = ItemUse.plan(choice, view, potionFacts())
  Assert.isNil(revived.failureReason, "the replanned choice succeeds after the cancel")

  Assert.equal(live:revision(), revisionBefore, "reservation bookkeeping never touches the live Bag")
  Assert.equal(live:quantity("POTION"), 1, "the shared stack is still whole")
end

-- Unknown owners, unknown items, empty stacks, and stale holders fail with
-- typed errors; failed plans never execute, and neither failure consumes
-- stock, writes the ledger, draws, or touches the live Bag.
function T.stale_and_illegal_choices_fail_without_side_effects()
  local ItemUse = itemUse("battle bag planning owns selection without consuming")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local live = liveService()
  local revisionBefore = live:revision()
  local view = declaredView()

  local cases = {
    {
      choice = { inventoryId = "satchel", item = "POTION", target = potionChoice(1).target },
      code = "unknown_inventory",
    },
    {
      choice = { inventoryId = "party", item = "MYSTERY_TONIC", target = potionChoice(1).target },
      code = "unknown_item",
    },
    { choice = { inventoryId = "party", item = "REVIVE", target = potionChoice(1).target }, code = "empty" },
    { choice = potionChoice(9), code = "invalid_target" },
  }
  for _, case in ipairs(cases) do
    local ok, err = ItemUse.validateChoice(case.choice, view)
    Assert.isNil(ok, "the illegal choice validates never: " .. case.code)
    Assert.equal((err --[[@as table]]).code, case.code, "the illegal choice reports its reason")
    local refused = ItemUse.plan(case.choice, view)
    Assert.equal(refused.failureReason, case.code, "the refused plan carries its failure")
  end

  local battle = executionState(view)
  local rng = BattleRng.new(NATIVE_SEED)
  local callsBefore = rng:capture().calls
  local refused = ItemUse.plan({ inventoryId = "party", item = "REVIVE", target = potionChoice(1).target }, view)
  local refusedErr = Assert.throws(function()
    ItemUse.execute(refused, battle, rng)
  end)
  Assert.equal((refusedErr --[[@as table]]).code, "empty", "executing a refused plan raises its typed failure")

  battle.combatants[1].hp = 0
  local doomed = ItemUse.plan(potionChoice(1), view, potionFacts())
  Assert.isNil(doomed.failureReason, "planning precedes the faint")
  local staleErr = Assert.throws(function()
    ItemUse.execute(doomed, battle, rng)
  end)
  Assert.equal((staleErr --[[@as table]]).code, "invalid_target", "a fainted holder fails at execution")

  Assert.deepEqual(battle.ledger, {}, "failed executions write no ledger")
  Assert.equal(battle.inventories.party.quantities.POTION, 1, "failed executions consume nothing")
  Assert.equal(rng:capture().calls, callsBefore, "failed executions draw nothing")
  Assert.equal(live:revision(), revisionBefore, "failures never touch the live Bag")
  Assert.equal(live:quantity("POTION"), 1, "the shared stack is still whole")
end

-- Execution consumes exactly one unit at the plan checkpoint into the
-- battle ledger, heals the holder, and stamps the plan: rerunning it or
-- planning again for the spent stack fails without double consumption.
function T.execution_consumes_exactly_once_at_its_checkpoint()
  local ItemUse = itemUse("battle bag planning owns selection without consuming")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local live = liveService()
  local revisionBefore = live:revision()
  local view = declaredView()
  local battle = executionState(view)
  local rng = BattleRng.new(NATIVE_SEED)
  local callsBefore = rng:capture().calls

  local plan = ItemUse.plan(potionChoice(1), view, potionFacts())
  local outcome = ItemUse.execute(plan, battle, rng)

  Assert.isTrue(outcome.consumed, "the legal execution consumes")
  Assert.equal(battle.inventories.party.quantities.POTION, 0, "the battle stock drops by exactly one unit")
  Assert.equal(#battle.ledger, 1, "the execution writes exactly one ledger delta")
  local delta = battle.ledger[1]
  Assert.equal(delta.inventoryId, "party", "the delta names its inventory owner")
  Assert.equal(delta.item, "POTION", "the delta names its item")
  Assert.equal(delta.delta, -1, "the delta consumes exactly one unit")
  Assert.equal(delta.checkpoint, plan.consumptionCheckpoint, "consumption happens at the plan checkpoint")
  Assert.isTrue(battle.combatants[1].hp > 10, "the holder recovers health")
  Assert.isTrue(battle.combatants[1].hp <= 30, "recovery respects the maximum")

  local repeatErr = Assert.throws(function()
    ItemUse.execute(plan, battle, rng)
  end)
  Assert.isTrue(type((repeatErr --[[@as table]]).code) == "string", "rerunning a plan raises its typed failure")
  Assert.equal(#battle.ledger, 1, "rerunning a plan writes no second delta")
  Assert.equal(battle.inventories.party.quantities.POTION, 0, "rerunning a plan consumes nothing more")

  view.inventories.party.quantities.POTION = battle.inventories.party.quantities.POTION
  local spent = ItemUse.plan(potionChoice(1), view)
  Assert.equal(spent.failureReason, "empty", "the spent stack plans its failure")

  Assert.equal(rng:capture().calls, callsBefore, "deterministic use draws nothing")
  Assert.equal(live:revision(), revisionBefore, "execution never mutates the live Bag")
  Assert.equal(live:quantity("POTION"), 1, "the live stack waits for the later commit")
end

-- Fixed restoration larger than the wound caps at the maximum: the
-- holder keeps the ceiling while the event reports only the actual gain.
function T.over_large_fixed_restoration_caps_at_maximum()
  local ItemUse = itemUse("battle servings cap restoration at the maximum")
  local view = declaredView()
  view.combatants[1] = { hp = 25, maxHp = 30 }
  local plan = ItemUse.plan(potionChoice(1), view, potionFacts())
  Assert.isNil(plan.failureReason, "the capped serving plans its restoration")
  local battle = executionState(view)
  local outcome = ItemUse.execute(plan, battle, nil)
  Assert.isTrue(outcome.consumed, "the capped serving consumes")
  Assert.equal(battle.combatants[1].hp, 30, "the capped serving keeps the ceiling")
  Assert.equal(outcome.restored, 5, "the outcome reports only the actual gain")
  Assert.equal(battle.inventories.party.quantities.POTION, 0, "the capped serving consumes once")
end

-- Malformed and unknown choices fail with their typed codes and plan
-- their refusal without operations; executing a malformed plan raises
-- before any mutation.
function T.malformed_choices_fail_typed_without_side_effects()
  local ItemUse = itemUse("battle bag planning owns selection without consuming")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local live = liveService()
  local revisionBefore = live:revision()
  local view = declaredView()

  local shapelessOk, shapelessErr = ItemUse.validateChoice("POTION", view)
  Assert.isNil(shapelessOk, "a shapeless choice never validates")
  Assert.equal((shapelessErr --[[@as table]]).code, "unknown_inventory", "a shapeless choice names its owner")

  local nameless = { inventoryId = "party", target = potionChoice(1).target }
  local refused = ItemUse.plan(nameless, view)
  Assert.equal(refused.failureReason, "unknown_item", "a nameless plan carries its failure")
  Assert.deepEqual(refused.effectOperations, {}, "a refused plan lists no effects")

  local battle = executionState(view)
  local rng = BattleRng.new(NATIVE_SEED)
  local callsBefore = rng:capture().calls
  local malformedErr = Assert.throws(function()
    ItemUse.execute({ failureReason = nil }, battle, rng)
  end)
  Assert.equal((malformedErr --[[@as table]]).code, "invalid_plan", "a malformed plan raises its typed failure")

  Assert.deepEqual(battle.ledger, {}, "malformed executions write no ledger")
  Assert.equal(battle.inventories.party.quantities.POTION, 1, "malformed executions consume nothing")
  Assert.equal(rng:capture().calls, callsBefore, "malformed executions draw nothing")
  Assert.equal(live:revision(), revisionBefore, "malformed choices never touch the live Bag")
end

---@param hp integer holder health under test preparation
---@param maxHp integer holder maximum under test preparation
---@param effectKey string? persistent condition carried by the holder, healthy when absent
---@return table holder combatant carrying its mon condition mirror
local function ailingHolder(hp, maxHp, effectKey)
  local effects = {}
  if effectKey ~= nil then
    effects[1] = { key = effectKey }
  end
  return { hp = hp, maxHp = maxHp, mon = { condition = { currentHp = hp, effects = effects } } }
end

---@param flag string cure flag enabled on the serving under test preparation
---@param restore table<string, unknown>? generated restore record, cure-only when absent
---@return table<string, table<string, unknown>> semantic facts for one cure serving
local function cureFacts(flag, restore)
  local cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false }
  cures[flag] = true
  return {
    REMEDY = {
      partyUse = { kind = "medicine", restore = restore, cures = cures, revive = "none", mood = 0 },
    },
  }
end

---@param holder table holder combatant under test preparation
---@return table item choice serving the shared remedy to the holder
local function remedyChoice(holder)
  return {
    inventoryId = "party",
    item = "REMEDY",
    target = { kind = "combatant", combatant = holder },
  }
end

---@param holder table holder combatant under test preparation
---@return table declared battle state carrying one remedy and the holder
local function remedyView(holder)
  return {
    inventories = { party = { quantities = { REMEDY = 1 }, revision = 0 } },
    outstanding = {},
    combatants = { [1] = holder },
  }
end

---@param holder table holder combatant under test preparation
---@return table battle-owned execution state carrying one remedy and the holder
local function remedyBattle(holder)
  return {
    inventories = { party = { quantities = { REMEDY = 1 }, revision = 0 } },
    ledger = {},
    combatants = { [1] = holder },
  }
end

-- The shared poison cure clears the toxic record: a toxic holder served a
-- poison-cure serving recovers its condition with health untouched and
-- exactly one unit consumed.
function T.poison_cure_clears_toxic_without_healing()
  local ItemUse = itemUse("battle servings clear persistent conditions through their facts")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local holder = ailingHolder(30, 30, "toxic")
  local view = remedyView(holder)
  local facts = cureFacts("poison", nil)
  local rng = BattleRng.new(NATIVE_SEED)
  local callsBefore = rng:capture().calls

  local plan = ItemUse.plan(remedyChoice(1), view, facts)
  Assert.isNil(plan.failureReason, "the matching cure plans its serving")

  local battle = remedyBattle(ailingHolder(30, 30, "toxic"))
  local outcome = ItemUse.execute(plan, battle, rng)
  Assert.isTrue(outcome.consumed, "the cure consumes")
  Assert.equal(outcome.restored, 0, "cure-only servings restore nothing")
  Assert.equal(outcome.target.combatant, 1, "the outcome names its holder")
  Assert.deepEqual(battle.combatants[1].mon.condition.effects, {}, "the toxic record clears")
  Assert.equal(battle.combatants[1].hp, 30, "cure-only servings heal nothing")
  Assert.equal(battle.inventories.party.quantities.REMEDY, 0, "the serving consumes exactly one unit")
  Assert.equal(#battle.ledger, 1, "the serving writes exactly one ledger delta")
  Assert.equal(rng:capture().calls, callsBefore, "deterministic cures draw nothing")
end

-- Every standard cure flag clears its matching condition on a healthy
-- holder without touching health or drawing.
function T.every_standard_cure_flag_clears_its_matching_condition()
  local ItemUse = itemUse("battle servings clear persistent conditions through their facts")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local cases = { { "sleep", "sleep" }, { "poison", "poison" }, { "burn", "burn" }, { "freeze", "freeze" }, {
    "paralysis",
    "paralysis",
  } }
  for _, case in ipairs(cases) do
    local flag, condition = case[1], case[2]
    local view = remedyView(ailingHolder(30, 30, condition))
    local facts = cureFacts(flag, nil)
    local rng = BattleRng.new(NATIVE_SEED)
    local callsBefore = rng:capture().calls
    local plan = ItemUse.plan(remedyChoice(1), view, facts)
    Assert.isNil(plan.failureReason, "the " .. flag .. " cure plans its serving")
    local battle = remedyBattle(ailingHolder(30, 30, condition))
    local outcome = ItemUse.execute(plan, battle, rng)
    Assert.isTrue(outcome.consumed, "the " .. flag .. " cure consumes")
    Assert.equal(outcome.restored, 0, "the " .. flag .. " cure restores nothing")
    Assert.deepEqual(battle.combatants[1].mon.condition.effects, {}, "the " .. flag .. " record clears")
    Assert.equal(battle.combatants[1].hp, 30, "the " .. flag .. " cure heals nothing")
    Assert.equal(battle.inventories.party.quantities.REMEDY, 0, "the " .. flag .. " cure consumes once")
    Assert.equal(#battle.ledger, 1, "the " .. flag .. " cure writes one delta")
    Assert.equal(rng:capture().calls, callsBefore, "the " .. flag .. " cure draws nothing")
  end
end

-- Mixed servings apply both effects before one consumption: an injured
-- burned holder recovers health and condition together.
function T.mixed_restoration_and_cure_apply_together_before_single_consumption()
  local ItemUse = itemUse("battle servings combine generated restoration with their cures")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local view = remedyView(ailingHolder(10, 30, "burn"))
  local facts = cureFacts("burn", { kind = "fixed", amount = 20 })
  local plan = ItemUse.plan(remedyChoice(1), view, facts)
  Assert.isNil(plan.failureReason, "the mixed serving plans its effects")
  local battle = remedyBattle(ailingHolder(10, 30, "burn"))
  local rng = BattleRng.new(NATIVE_SEED)
  local outcome = ItemUse.execute(plan, battle, rng)
  Assert.isTrue(outcome.consumed, "the mixed serving consumes")
  Assert.equal(outcome.restored, 20, "the mixed serving reports its actual restoration")
  Assert.equal(battle.combatants[1].hp, 30, "the mixed serving heals its holder")
  Assert.equal(
    battle.combatants[1].mon.condition.currentHp,
    30,
    "the mixed serving synchronizes the condition mirror"
  )
  Assert.deepEqual(battle.combatants[1].mon.condition.effects, {}, "the mixed serving clears the burn")
  Assert.equal(battle.inventories.party.quantities.REMEDY, 0, "the mixed serving consumes exactly once")
  Assert.equal(#battle.ledger, 1, "the mixed serving writes exactly one ledger delta")
end

-- Cure-only servings refuse without effect when no cure applies: neither
-- full health alone nor an injury without a matching condition qualifies.
function T.unmatched_cures_refuse_without_consumption()
  local ItemUse = itemUse("battle servings refuse servings without effect")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local facts = cureFacts("paralysis", nil)
  local holders = { ailingHolder(30, 30, nil), ailingHolder(10, 30, nil), ailingHolder(10, 30, "burn") }
  for index, holder in ipairs(holders) do
    local view = remedyView(holder)
    local plan = ItemUse.plan(remedyChoice(1), view, facts)
    Assert.equal(plan.failureReason, "no_effect", "unmatched cure " .. index .. " plans its refusal")
    Assert.deepEqual(plan.effectOperations, {}, "unmatched cure " .. index .. " lists no effects")
    local battle = remedyBattle(holder)
    local rng = BattleRng.new(NATIVE_SEED)
    local callsBefore = rng:capture().calls
    local refusal = Assert.throws(function()
      ItemUse.execute(plan, battle, rng)
    end)
    Assert.equal((refusal --[[@as table]]).code, "no_effect", "unmatched cure " .. index .. " names its reason")
    Assert.deepEqual(battle.ledger, {}, "unmatched cure " .. index .. " writes no ledger")
    Assert.equal(battle.inventories.party.quantities.REMEDY, 1, "unmatched cure " .. index .. " consumes nothing")
    Assert.equal(battle.combatants[1].hp, holder.hp, "unmatched cure " .. index .. " heals nothing")
    Assert.equal(rng:capture().calls, callsBefore, "unmatched cure " .. index .. " draws nothing")
  end
end

-- Servings without usable facts fail as missing behavior before any
-- consumption: absent maps, absent entries, records without party use,
-- and records carrying foreign fields never plan.
function T.servings_without_facts_fail_before_consumption()
  local ItemUse = itemUse("battle servings read their immutable item facts")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local view = remedyView(ailingHolder(10, 30, nil))
  local choice = remedyChoice(1)
  local candidates = {
    { facts = nil, reason = "absent fact map" },
    { facts = {}, reason = "absent fact entry" },
    { facts = { REMEDY = {} }, reason = "entry without party use" },
    {
      facts = {
        REMEDY = {
          partyUse = { kind = "medicine", revive = "none", mood = 0 },
          price = 300,
        },
      },
      reason = "entry carrying foreign fields",
    },
  }
  for _, candidate in ipairs(candidates) do
    local rng = BattleRng.new(NATIVE_SEED)
    local callsBefore = rng:capture().calls
    local ok, failure = pcall(ItemUse.plan, choice, view, candidate.facts)
    Assert.isFalse(ok, "the serving with " .. candidate.reason .. " never plans")
    Assert.equal(
      (failure --[[@as table]]).code,
      "BATTLE_MISSING_BEHAVIOR",
      "the serving with " .. candidate.reason .. " reports its missing behavior"
    )
    Assert.deepEqual(view.inventories.party.quantities, { REMEDY = 1 }, "missing facts consume no stock")
    Assert.equal(rng:capture().calls, callsBefore, "missing facts draw nothing")
  end
end

-- Revival servings stay unmodeled: a revival-flagged serving fails as
-- missing behavior even for a living holder instead of healing.
function T.revival_servings_fail_as_unmodeled()
  local ItemUse = itemUse("battle servings leave revival unmodeled")
  local view = remedyView(ailingHolder(10, 30, nil))
  local facts = {
    REMEDY = {
      partyUse = {
        kind = "medicine",
        restore = { kind = "fixed", amount = 20 },
        cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
        revive = "single",
        mood = 0,
      },
    },
  }
  local ok, failure = pcall(ItemUse.plan, remedyChoice(1), view, facts)
  Assert.isFalse(ok, "the revival serving never plans")
  Assert.equal(
    (failure --[[@as table]]).code,
    "BATTLE_MISSING_BEHAVIOR",
    "the revival serving reports its missing behavior"
  )
  Assert.deepEqual(view.inventories.party.quantities, { REMEDY = 1 }, "revival failures consume no stock")
end

-- Battle-only servings plan from their generated battle use: X-items
-- raise stages, dire hits focus, guard specs screen the side, and
-- battle cures clear volatiles. Servings without any applicable effect
-- refuse, and execution consumes exactly once into the ledger.

---@return table<string, integer> flat battle-local stages under test preparation
local function flatStages()
  return {
    attack = 0,
    defense = 0,
    speed = 0,
    specialAttack = 0,
    specialDefense = 0,
    accuracy = 0,
    evasion = 0,
  }
end

---@param stages table<string, integer>? battle-local stages, flat when absent
---@return table holder combatant with health, stages, and an entry token
local function battleHolder(stages)
  return {
    hp = 10,
    maxHp = 30,
    mon = { condition = { currentHp = 10, effects = {} } },
    stages = stages or flatStages(),
    active = { position = 1, activation = 7 },
    participant = 1,
  }
end

---@param key string item key stocked under test preparation
---@param holder table holder combatant under test preparation
---@return table declared battle state carrying one battle item and the holder
local function battleView(key, holder)
  return {
    inventories = { pack = { quantities = { [key] = 1 }, revision = 0 } },
    outstanding = {},
    combatants = { [1] = holder },
  }
end

---@param key string item key stocked under test preparation
---@param holder table holder combatant under test preparation
---@return table battle-owned execution state carrying one battle item and the holder
local function battleState(key, holder)
  local EffectBag = SessionFixture.requirePresent(
    "libs.battle.src.EffectBag",
    "the live effect owner holds battle-local instances"
  )
  return {
    inventories = { pack = { quantities = { [key] = 1 }, revision = 0 } },
    ledger = {},
    combatants = { [1] = holder },
    participants = { [1] = { side = 1 } },
    effectBag = EffectBag.new(),
    sequence = 0,
    outbox = {},
  }
end

---@param key string item key choosing under test preparation
---@return table item choice serving the shared battle item to the holder
local function battleChoice(key)
  return { inventoryId = "pack", item = key, target = { kind = "combatant", combatant = 1 } }
end

---@param stages table<string, integer> decoded native stage flags under test preparation
---@param cures table<string, boolean>? battle cure flags, none when absent
---@param guardSpec boolean? guard screen flag, unset when absent
---@return table<string, table<string, unknown>> semantic facts for one battle serving
local function battleFacts(stages, cures, guardSpec)
  return {
    X_ITEM = {
      partyUse = { kind = "deferred", reason = "battle_only" },
      battleUse = {
        cures = cures or { confusion = false, infatuation = false },
        guardSpec = guardSpec or false,
        stages = stages,
      },
    },
  }
end

local function attackStage()
  return {
    attack = 1,
    defense = 0,
    specialAttack = 0,
    specialDefense = 0,
    speed = 0,
    accuracy = 0,
    critical = 0,
  }
end

function T.x_items_plan_a_stage_serving_from_battle_use()
  local ItemUse = itemUse("battle servings read their generated battle use")
  local holder = battleHolder()
  local plan = ItemUse.plan(battleChoice("X_ITEM"), battleView("X_ITEM", holder), battleFacts(attackStage()))
  Assert.isNil(plan.failureReason, "the stage serving plans")
  Assert.equal(#plan.effectOperations, 1, "the stage serving carries one operation")
  local operation = plan.effectOperations[1] --[[@as table<string, unknown>]]
  Assert.equal(operation.kind, "stage", "the operation raises a stage")
  Assert.equal(operation.stat, "attack", "the operation names its stat")
end

function T.capped_stages_refuse_without_effect()
  local ItemUse = itemUse("battle servings refuse without an applicable effect")
  local stages = flatStages()
  stages.attack = 6
  local plan =
    ItemUse.plan(battleChoice("X_ITEM"), battleView("X_ITEM", battleHolder(stages)), battleFacts(attackStage()))
  Assert.equal(plan.failureReason, "no_effect", "the capped serving refuses")
  Assert.deepEqual(plan.effectOperations, {}, "a refused plan lists no effects")
end

function T.x_attack_execution_raises_the_stage_exactly_once()
  local ItemUse = itemUse("battle servings execute their generated battle use")
  local holder = battleHolder()
  local battle = battleState("X_ITEM", holder)
  local plan = ItemUse.plan(battleChoice("X_ITEM"), battleView("X_ITEM", holder), battleFacts(attackStage()))
  Assert.isNil(plan.failureReason, "the stage serving plans")
  local outcome = ItemUse.execute(plan, battle)
  Assert.isTrue(outcome.consumed, "the serving consumes")
  Assert.equal(battle.inventories.pack.quantities.X_ITEM, 0, "execution spends exactly one unit")
  Assert.equal(#battle.ledger, 1, "execution writes exactly one ledger delta")
  Assert.equal(battle.ledger[1].delta, -1, "the ledger delta consumes one unit")
  Assert.equal(holder.stages.attack, 1, "execution raises attack by one stage")
  local ok, failure = pcall(ItemUse.execute, plan, battle)
  Assert.isFalse(ok, "the plan never executes twice")
  Assert.equal((failure --[[@as table]]).code, "already_executed", "reruns report their stamp")
end

function T.dire_hits_focus_through_battle_use()
  local ItemUse = itemUse("battle servings focus through their generated battle use")
  local stages = {
    attack = 0,
    defense = 0,
    specialAttack = 0,
    specialDefense = 0,
    speed = 0,
    accuracy = 0,
    critical = 1,
  }
  local holder = battleHolder()
  local battle = battleState("X_ITEM", holder)
  local plan = ItemUse.plan(battleChoice("X_ITEM"), battle, battleFacts(stages))
  Assert.isNil(plan.failureReason, "the focus serving plans")
  ItemUse.execute(plan, battle)
  local BattleContext = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics reads"
  )
  local context = BattleContext.wrap(battle)
  Assert.isTrue(context:hasBattleEffect(1, "focusenergy"), "execution focuses its holder")
  Assert.equal(holder.stages.attack, 0, "focus moves no stage")
end

function T.guard_specs_screen_the_side_through_battle_use()
  local ItemUse = itemUse("battle servings screen through their generated battle use")
  local holder = battleHolder()
  local battle = battleState("X_ITEM", holder)
  local plan =
    ItemUse.plan(battleChoice("X_ITEM"), battle, battleFacts(attackStage(), nil, true))
  Assert.isNil(plan.failureReason, "the guard serving plans")
  ItemUse.execute(plan, battle)
  local BattleContext = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics reads"
  )
  local context = BattleContext.wrap(battle)
  Assert.isTrue(context:sideEffect(1, "mist") ~= nil, "execution screens the holder side")
end

function T.battle_cures_clear_volatiles_through_battle_use()
  local ItemUse = itemUse("battle servings clear volatiles through their generated battle use")
  local NativeEffects = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "typed battle-local writes own volatile definitions"
  )
  local holder = battleHolder()
  local battle = battleState("X_ITEM", holder)
  local BattleContext = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local context = BattleContext.wrap(battle)
  context:addBattleEffect(
    NativeEffects.definitionFor("confusion"),
    { kind = "active", combatant = 1, activation = 7 },
    { kind = "item", combatant = 1 },
    { version = 1, turns = 3 }
  )
  Assert.isTrue(context:hasBattleEffect(1, "confusion"), "setup confuses the holder")
  local cures = { confusion = true, infatuation = false }
  local plan =
    ItemUse.plan(battleChoice("X_ITEM"), battle, battleFacts(attackStage(), cures, false))
  Assert.isNil(plan.failureReason, "the cure serving plans")
  ItemUse.execute(plan, battle)
  Assert.isFalse(context:hasBattleEffect(1, "confusion"), "execution clears the volatile")
end

---@return table<string, integer> decoded native stage flags carrying only the critical rider
local function criticalOnlyStages()
  return {
    attack = 0,
    defense = 0,
    specialAttack = 0,
    specialDefense = 0,
    speed = 0,
    accuracy = 0,
    critical = 1,
  }
end

---@return table<string, integer> decoded native stage flags carrying no rider
local function quietStages()
  return {
    attack = 0,
    defense = 0,
    specialAttack = 0,
    specialDefense = 0,
    speed = 0,
    accuracy = 0,
    critical = 0,
  }
end

---@param battle table battle-owned execution state receiving focus on its holder
local function seedFocus(battle)
  local BattleContext = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local NativeEffects = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "typed battle-local writes own volatile definitions"
  )
  BattleContext.wrap(battle):addBattleEffect(
    NativeEffects.definitionFor("focusenergy"),
    { kind = "active", combatant = 1, activation = 7 },
    { kind = "item", combatant = 1 },
    { version = 1 }
  )
end

---@param battle table battle-owned execution state receiving mist on the holder side
local function seedMist(battle)
  local BattleContext = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local NativeEffects = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "typed battle-local writes own volatile definitions"
  )
  BattleContext.wrap(battle):addBattleEffect(
    NativeEffects.definitionFor("mist"),
    { kind = "side", side = 1 },
    { kind = "item", combatant = 1 },
    { version = 1, turns = 5 }
  )
end

---@return table<string, table<string, unknown>> semantic facts for one focusing serving
local function focusFacts()
  return {
    DIRE_HIT = {
      partyUse = { kind = "deferred", reason = "battle_only" },
      battleUse = {
        cures = { confusion = false, infatuation = false },
        guardSpec = false,
        stages = criticalOnlyStages(),
      },
    },
  }
end

---@return table<string, table<string, unknown>> semantic facts for one screening serving
local function guardFacts()
  return {
    GUARD_SPEC = {
      partyUse = { kind = "deferred", reason = "battle_only" },
      battleUse = {
        cures = { confusion = false, infatuation = false },
        guardSpec = true,
        stages = quietStages(),
      },
    },
  }
end

---@param flag string battle cure flag enabled on the serving under test preparation
---@return table<string, table<string, unknown>> semantic facts for one volatile-cure serving
local function volatileCureFacts(flag)
  local cures = { confusion = false, infatuation = false }
  cures[flag] = true
  return {
    CURE_CHARM = {
      partyUse = { kind = "deferred", reason = "battle_only" },
      battleUse = { cures = cures, guardSpec = false, stages = quietStages() },
    },
  }
end

---@param key string item key choosing under test preparation
---@return table item choice serving the shared battle item to the holder
local function servingChoice(key)
  return { inventoryId = "pack", item = key, target = { kind = "combatant", combatant = 1 } }
end

-- A holder already under focus gains nothing from another focusing
-- serving: planning refuses, and the refusal consumes no stock, writes no
-- ledger, draws nothing, and leaves the existing focus in place.
function T.focused_holders_refuse_another_focusing_serving()
  local ItemUse = itemUse("battle servings gate focus on the live holder")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local BattleContext = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics reads"
  )
  local holder = battleHolder()
  local battle = battleState("DIRE_HIT", holder)
  seedFocus(battle)
  local context = BattleContext.wrap(battle)
  Assert.isTrue(context:hasBattleEffect(1, "focusenergy"), "setup focuses the holder")

  local rng = BattleRng.new(NATIVE_SEED)
  local callsBefore = rng:capture().calls
  local plan = ItemUse.plan(servingChoice("DIRE_HIT"), battle, focusFacts())
  Assert.equal(plan.failureReason, "no_effect", "the repeated focus plans its refusal")
  Assert.deepEqual(plan.effectOperations, {}, "a refused plan lists no effects")
  Assert.isTrue(plan.executed ~= true, "refused plans carry no execution stamp")
  local refusal = Assert.throws(function()
    ItemUse.execute(plan, battle, rng)
  end)
  Assert.equal((refusal --[[@as table]]).code, "no_effect", "executing a refused plan raises its typed failure")
  Assert.equal(battle.inventories.pack.quantities.DIRE_HIT, 1, "refusals consume nothing")
  Assert.deepEqual(battle.ledger, {}, "refusals write no ledger")
  Assert.equal(rng:capture().calls, callsBefore, "refusals draw nothing")
  Assert.isTrue(context:hasBattleEffect(1, "focusenergy"), "the existing focus remains")
end

-- A side already behind mist gains nothing from another screening
-- serving: planning refuses with the screened side left exactly as it was.
function T.screened_sides_refuse_another_screening_serving()
  local ItemUse = itemUse("battle servings gate screens on the live side")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local BattleContext = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics reads"
  )
  local holder = battleHolder()
  local battle = battleState("GUARD_SPEC", holder)
  seedMist(battle)
  local context = BattleContext.wrap(battle)
  Assert.isTrue(context:sideEffect(1, "mist") ~= nil, "setup screens the holder side")

  local rng = BattleRng.new(NATIVE_SEED)
  local callsBefore = rng:capture().calls
  local plan = ItemUse.plan(servingChoice("GUARD_SPEC"), battle, guardFacts())
  Assert.equal(plan.failureReason, "no_effect", "the repeated screen plans its refusal")
  Assert.deepEqual(plan.effectOperations, {}, "a refused plan lists no effects")
  Assert.isTrue(plan.executed ~= true, "refused plans carry no execution stamp")
  local refusal = Assert.throws(function()
    ItemUse.execute(plan, battle, rng)
  end)
  Assert.equal((refusal --[[@as table]]).code, "no_effect", "executing a refused plan raises its typed failure")
  Assert.equal(battle.inventories.pack.quantities.GUARD_SPEC, 1, "refusals consume nothing")
  Assert.deepEqual(battle.ledger, {}, "refusals write no ledger")
  Assert.equal(rng:capture().calls, callsBefore, "refusals draw nothing")
  Assert.isTrue(context:sideEffect(1, "mist") ~= nil, "the existing screen remains")
end

-- Volatile cures need their volatile: without confusion or infatuation on
-- the holder, a cure-only serving refuses instead of consuming.
function T.volatile_cures_without_their_volatile_refuse()
  local ItemUse = itemUse("battle servings gate volatile cures on the live holder")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  for _, flag in ipairs({ "confusion", "infatuation" }) do
    local holder = battleHolder()
    local battle = battleState("CURE_CHARM", holder)
    local rng = BattleRng.new(NATIVE_SEED)
    local callsBefore = rng:capture().calls
    local plan = ItemUse.plan(servingChoice("CURE_CHARM"), battle, volatileCureFacts(flag))
    Assert.equal(plan.failureReason, "no_effect", "the cure without " .. flag .. " plans its refusal")
    Assert.deepEqual(plan.effectOperations, {}, "a refused plan lists no effects")
    local refusal = Assert.throws(function()
      ItemUse.execute(plan, battle, rng)
    end)
    Assert.equal(
      (refusal --[[@as table]]).code,
      "no_effect",
      "the cure without " .. flag .. " names its reason"
    )
    Assert.equal(
      battle.inventories.pack.quantities.CURE_CHARM,
      1,
      "the cure without " .. flag .. " consumes nothing"
    )
    Assert.deepEqual(battle.ledger, {}, "the cure without " .. flag .. " writes no ledger")
    Assert.equal(rng:capture().calls, callsBefore, "the cure without " .. flag .. " draws nothing")
  end
end

-- An unrelated applicable rider still makes the serving effectful: with no
-- volatile present, the stage climbs once for one unit while the
-- already-satisfied cure is left out of the plan.
function T.mixed_cure_and_stage_serves_only_the_applicable_stage()
  local ItemUse = itemUse("battle servings keep only the applicable riders")
  local holder = battleHolder()
  local battle = battleState("X_ITEM", holder)
  local cures = { confusion = true, infatuation = false }
  local plan =
    ItemUse.plan(battleChoice("X_ITEM"), battle, battleFacts(attackStage(), cures, false))
  Assert.isNil(plan.failureReason, "the mixed serving plans its applicable rider")
  Assert.equal(#plan.effectOperations, 1, "the mixed serving carries one operation")
  local operation = plan.effectOperations[1] --[[@as table<string, unknown>]]
  Assert.equal(operation.kind, "stage", "the carried operation raises a stage")
  Assert.equal(operation.stat, "attack", "the carried operation names its stat")
  local outcome = ItemUse.execute(plan, battle)
  Assert.isTrue(outcome.consumed, "the mixed serving consumes")
  Assert.equal(battle.inventories.pack.quantities.X_ITEM, 0, "the mixed serving spends exactly one unit")
  Assert.equal(#battle.ledger, 1, "the mixed serving writes exactly one ledger delta")
  Assert.equal(holder.stages.attack, 1, "the mixed serving raises attack by one stage")
end

-- Item facts may travel beside held, fling, and gift records without
-- changing serving semantics; genuinely foreign fields still fail closed.
function T.sibling_item_records_leave_serving_semantics_unchanged()
  local ItemUse = itemUse("battle servings read only their serving facts")
  local view = declaredView()
  local plain = ItemUse.plan(potionChoice(1), view, potionFacts())
  Assert.isNil(plain.failureReason, "the plain serving plans")
  local travelingFacts = {
    POTION = {
      partyUse = potionFacts().POTION.partyUse,
      heldBehavior = {},
      fling = {},
      naturalGift = {},
    },
  }
  local traveling = ItemUse.plan(potionChoice(1), view, travelingFacts)
  Assert.isNil(traveling.failureReason, "the serving beside sibling records plans")
  Assert.deepEqual(
    traveling.effectOperations,
    plain.effectOperations,
    "sibling records change no serving operation"
  )
  local battle = executionState(view)
  local outcome = ItemUse.execute(traveling, battle, nil)
  Assert.isTrue(outcome.consumed, "the serving beside sibling records consumes")
  Assert.equal(battle.inventories.party.quantities.POTION, 0, "the serving spends exactly one unit")

  local holder = battleHolder()
  local staged = battleState("X_ITEM", holder)
  local stagedEntry = battleFacts(attackStage()).X_ITEM
  local stagedTraveling = {
    X_ITEM = {
      partyUse = stagedEntry.partyUse,
      battleUse = stagedEntry.battleUse,
      heldBehavior = {},
      fling = {},
      naturalGift = {},
    },
  }
  local stagedPlan = ItemUse.plan(battleChoice("X_ITEM"), staged, stagedTraveling)
  Assert.isNil(stagedPlan.failureReason, "the battle serving beside sibling records plans")
  Assert.equal(#stagedPlan.effectOperations, 1, "the battle serving keeps its operation")

  local foreignFacts = {
    POTION = {
      partyUse = potionFacts().POTION.partyUse,
      lore = { tale = "shiny" },
    },
  }
  local ok, failure = pcall(ItemUse.plan, potionChoice(1), view, foreignFacts)
  Assert.isFalse(ok, "the serving carrying a foreign field never plans")
  Assert.equal(
    (failure --[[@as table]]).code,
    "BATTLE_MISSING_BEHAVIOR",
    "the foreign field reports its missing behavior"
  )
  Assert.deepEqual(
    view.inventories.party.quantities,
    { POTION = 1, REVIVE = 0 },
    "foreign fields consume no stock"
  )
end

return { tests = T }
