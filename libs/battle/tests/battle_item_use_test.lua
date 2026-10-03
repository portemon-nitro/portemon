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

return { tests = T }
