-- Pure party-item effect planning: source-shaped eligibility, arithmetic and
-- feedback on copied mon facts. No service is touched; the planner never
-- mutates its inputs and returns candidate changes only.

local Assert = require("tests.support.Assert")
local PartyItemEffects = require("libs.hgss.src.mons.PartyItemEffects")

local function evSet(hp, attack, defense, speed, specialAttack, specialDefense)
  return {
    hp = hp,
    attack = attack,
    defense = defense,
    speed = speed,
    specialAttack = specialAttack,
    specialDefense = specialDefense,
  }
end

local function effect(key, state)
  return { key = key, version = 1, state = state or {} }
end

local function condition(currentHp, effects)
  return { currentHp = currentHp, effects = effects or {} }
end

local function mon(overrides)
  local record = {
    species = "CHIKORITA",
    form = 0,
    heldItem = "NONE",
    isEgg = false,
    friendship = 70,
    mood = 0,
    evs = evSet(0, 0, 0, 0, 0, 0),
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
    },
    origin = { ball = "POKE_BALL" },
    egg = { location = 7 },
    condition = condition(30, {}),
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function moveCatalog(basePp)
  return {
    move = function(_, key)
      local pp = basePp[key]
      assert(pp ~= nil, "test catalog is missing move " .. tostring(key))
      return { basePp = pp }
    end,
    item = function(_, _)
      return { friendshipBoost = false }
    end,
  }
end

local function context(overrides)
  local record = {
    location = 7,
    catalog = moveCatalog({ TACKLE = 35, GROWL = 40, SYNTHESIS = 5 }),
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function derived(maxHp)
  return { level = 9, maxHp = maxHp or 30 }
end

local function medicine(overrides)
  local record = {
    kind = "medicine",
    cures = {
      sleep = false,
      poison = false,
      burn = false,
      freeze = false,
      paralysis = false,
    },
    revive = "none",
    mood = 0,
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local T = {}

function T.malformed_metadata_raises()
  local badKind = Assert.throws(function()
    PartyItemEffects.plan(mon(), { kind = "bogus" }, nil, context(), derived())
  end, "an unknown effect kind must raise")
  Assert.equal(badKind.code, "ITEM_CATALOG_INVALID", "the failure must carry the catalog code")
  local missing = Assert.throws(function()
    PartyItemEffects.plan(mon(), {}, nil, context(), derived())
  end, "a missing effect kind must raise")
  Assert.equal(missing.code, "ITEM_CATALOG_INVALID", "the failure must carry the catalog code")
end

function T.inputs_are_never_mutated()
  local target = mon({ condition = condition(10, {}) })
  local snapshot = {
    hp = target.condition.currentHp,
    effects = target.condition.effects,
    friendship = target.friendship,
    ev = target.evs.hp,
  }
  local definition = medicine({
    restore = { kind = "fixed", amount = 20 },
    friendship = { lo = 5, med = 3, hi = 2 },
  })
  local plan = PartyItemEffects.plan(target, { partyUse = definition }, nil, context(), derived())
  Assert.equal(plan.kind, "ready")
  Assert.equal(target.condition.currentHp, snapshot.hp, "planning never mutates hit points")
  Assert.deepEqual(target.condition.effects, snapshot.effects, "planning never mutates conditions")
  Assert.equal(target.friendship, snapshot.friendship, "planning never mutates friendship")
  Assert.equal(target.evs.hp, snapshot.ev, "planning never mutates effort values")
end

function T.fixed_restore_heals_without_overheal()
  local definition = medicine({ restore = { kind = "fixed", amount = 20 } })
  local small = mon({ condition = condition(25, {}) })
  local smallPlan = PartyItemEffects.plan(small, { partyUse = definition }, nil, context(), derived(30))
  Assert.equal(smallPlan.kind, "ready")
  Assert.equal(smallPlan.updates.condition.currentHp, 30, "healing clamps at the derived maximum")
  local hurt = mon({ condition = condition(5, {}) })
  local plan = PartyItemEffects.plan(hurt, { partyUse = definition }, nil, context(), derived(30))
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.updates.condition.currentHp, 25, "fixed amounts add exactly")
  Assert.equal(plan.feedback.slots[1].hpBefore, 5)
  Assert.equal(plan.feedback.slots[1].hpAfter, 25)
end

function T.quarter_restore_uses_integer_division()
  local definition = medicine({ restore = { kind = "quarter" } })
  local target = mon({ condition = condition(10, {}) })
  local plan = PartyItemEffects.plan(target, { partyUse = definition }, nil, context(), derived(31))
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.updates.condition.currentHp, 10 + math.floor(31 / 4), "quarters divide down")
end

function T.max_hp_one_restores_single_point()
  local definition = medicine({ restore = { kind = "fixed", amount = 20 } })
  local shedinja = mon({ species = "SHEDINJA", condition = condition(0, {}) })
  local plan = PartyItemEffects.plan(shedinja, { partyUse = definition }, nil, context(), derived(1))
  Assert.equal(plan.kind, "no_effect", "plain medicine cannot revive the one-health mon")
end

function T.poison_cure_clears_toxic_bits()
  local definition = medicine({
    cures = {
      sleep = false,
      poison = true,
      burn = false,
      freeze = false,
      paralysis = false,
    },
  })
  local target = mon({ condition = condition(30, { effect("poison"), effect("toxic", { counter = 5 }) }) })
  local plan = PartyItemEffects.plan(target, { partyUse = definition }, nil, context(), derived(30))
  Assert.equal(plan.kind, "ready")
  Assert.deepEqual(plan.updates.condition.effects, {}, "poison cure clears poison and toxic records")
  Assert.equal(plan.updates.condition.currentHp, 30, "a pure cure changes no hit points")
end

function T.targeted_cures_match_only_their_condition()
  local sleeping = mon({ condition = condition(30, { effect("sleep", { turns = 3 }) }) })
  local wakeful = medicine({
    cures = {
      sleep = true,
      poison = false,
      burn = false,
      freeze = false,
      paralysis = false,
    },
  })
  local woken = PartyItemEffects.plan(sleeping, { partyUse = wakeful }, nil, context(), derived(30))
  Assert.equal(woken.kind, "ready")
  Assert.deepEqual(woken.updates.condition.effects, {}, "a sleep cure clears the sleep record")
  Assert.deepEqual(woken.feedback.slots[1].effectsBefore, sleeping.condition.effects, "feedback keeps the entry state")
  Assert.deepEqual(woken.feedback.slots[1].effectsAfter, {}, "feedback reports the cleared state")

  local burned = mon({ condition = condition(30, { effect("burn") }) })
  Assert.equal(
    PartyItemEffects.plan(burned, { partyUse = wakeful }, nil, context(), derived(30)).kind,
    "no_effect",
    "a sleep cure ignores a burn"
  )
  local thawing = medicine({
    cures = {
      sleep = false,
      poison = false,
      burn = false,
      freeze = true,
      paralysis = false,
    },
  })
  Assert.equal(
    PartyItemEffects.plan(burned, { partyUse = thawing }, nil, context(), derived(30)).kind,
    "no_effect",
    "a freeze cure ignores a burn"
  )
end

function T.unmatched_cure_is_no_effect()
  local definition = medicine({
    cures = {
      sleep = false,
      poison = true,
      burn = false,
      freeze = false,
      paralysis = false,
    },
  })
  Assert.equal(PartyItemEffects.plan(mon(), { partyUse = definition }, nil, context(), derived()).kind, "no_effect")
end

function T.pp_restore_needs_a_chosen_move()
  local definition = { kind = "pp", target = "one", restore = 10, mood = 0 }
  Assert.equal(PartyItemEffects.plan(mon(), { partyUse = definition }, nil, context(), derived()).kind, "needs_move")
  local missing = PartyItemEffects.plan(mon(), { partyUse = definition }, 5, context(), derived())
  Assert.equal(missing.kind, "ineligible", "a move slot past the known moves is ineligible")
end

function T.pp_up_preserves_spent_points()
  local target = mon()
  target.moves = { { move = "SYNTHESIS", pp = 2, ppUps = 0 } }
  local definition = { kind = "pp", target = "one", boost = 1, mood = 0 }
  local plan = PartyItemEffects.plan(target, { partyUse = definition }, 0, context(), derived())
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.updates.moves[1].ppUps, 1, "one up is recorded")
  Assert.equal(plan.updates.moves[1].pp, 2 + (6 - 5), "spent points survive the new maximum")
  local capped = mon()
  capped.moves = { { move = "SYNTHESIS", pp = 6, ppUps = 3 } }
  Assert.equal(PartyItemEffects.plan(capped, { partyUse = definition }, 0, context(), derived()).kind, "no_effect")
  local weak = mon()
  weak.moves = { { move = "GROWL", pp = 40, ppUps = 0 } }
  Assert.equal(
    PartyItemEffects.plan(
      weak,
      { partyUse = { kind = "pp", target = "one", boost = 1, mood = 0 } },
      0,
      context(),
      derived()
    ).kind,
    "ready"
  )
end

function T.vitamin_caps_and_preserves_damage()
  local definition = {
    kind = "ev",
    changes = { { stat = "hp", delta = 10 } },
    friendship = { lo = 5, med = 3, hi = 2 },
    mood = 8,
  }
  local target = mon({ evs = evSet(95, 0, 0, 0, 0, 0), condition = condition(20, {}) })
  local plan = PartyItemEffects.plan(target, { partyUse = definition }, nil, context(), derived(30))
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.updates.evs.hp, 100, "vitamins cap the affected value at one hundred")
  Assert.equal(plan.updates.friendship, 76, "low-band friendship plus the home bonus applies")
  Assert.equal(plan.updates.mood, 8, "vitamin mood applies on success")
end

function T.berry_reduction_applies_try_mod_order()
  local definition = {
    kind = "ev",
    changes = { { stat = "attack", delta = -10 } },
    friendship = { lo = 10, med = 5, hi = 2 },
    mood = 0,
  }
  local target = mon({ evs = evSet(0, 6, 0, 0, 0, 0), friendship = 70 })
  local plan = PartyItemEffects.plan(target, { partyUse = definition }, nil, context(), derived())
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.updates.evs.attack, 0, "reductions clamp at zero")
  local empty = mon({ evs = evSet(0, 0, 0, 0, 0, 0), friendship = 70 })
  local friendshipOnly = PartyItemEffects.plan(empty, { partyUse = definition }, nil, context(), derived())
  Assert.equal(friendshipOnly.kind, "ready", "friendship-only berries stay usable")
  Assert.equal(friendshipOnly.updates.friendship, 81, "only friendship plus the home bonus changes")
  Assert.equal(friendshipOnly.updates.evs.attack, 0, "no effort value is invented")
  local capped = mon({ evs = evSet(0, 0, 0, 0, 0, 0), friendship = 255 })
  Assert.equal(PartyItemEffects.plan(capped, { partyUse = definition }, nil, context(), derived()).kind, "no_effect")
end

function T.friendship_bonuses_follow_source_order()
  local definition = {
    kind = "ev",
    changes = { { stat = "hp", delta = 10 } },
    friendship = { lo = 5, med = 3, hi = 2 },
    mood = 0,
  }
  local luxury = mon({ friendship = 70, origin = { ball = "LUXURY_BALL" } })
  local plan = PartyItemEffects.plan(luxury, { partyUse = definition }, nil, context(), derived())
  Assert.equal(plan.updates.friendship, 70 + 5 + 1 + 1, "luxury and home bonuses precede the multiplier")
end

function T.transfer_moves_the_full_fifth()
  local donor = mon({ condition = condition(50, {}) })
  local recipient = mon({ condition = condition(27, {}) })
  local plan = PartyItemEffects.planTransfer(donor, recipient, derived(100), derived(30))
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.donor.condition.currentHp, 30, "the donor loses the full fifth")
  Assert.equal(plan.recipient.condition.currentHp, 30, "the recipient gains up to full health")
  Assert.equal(donor.condition.currentHp, 50, "transfer planning never mutates the donor")
end

function T.transfer_rejects_bad_targets()
  local donor = mon({ condition = condition(50, {}) })
  Assert.equal(PartyItemEffects.planTransfer(donor, donor, derived(100), derived(100)).kind, "ineligible")
  local fainted = mon({ condition = condition(0, {}) })
  Assert.equal(PartyItemEffects.planTransfer(donor, fainted, derived(100), derived(30)).kind, "ineligible")
  local full = mon({ condition = condition(30, {}) })
  Assert.equal(PartyItemEffects.planTransfer(donor, full, derived(100), derived(30)).kind, "ineligible")
  local weak = mon({ condition = condition(20, {}) })
  Assert.equal(PartyItemEffects.planTransfer(weak, full, derived(100), derived(30)).kind, "ineligible")
  local egg = mon({ isEgg = true, condition = condition(10, {}) })
  Assert.equal(PartyItemEffects.planTransfer(donor, egg, derived(100), derived(30)).kind, "ineligible")
end

-- Deferred progression items plan through the progression owner once the
-- host identifies the item and supplies bag, party, and clock facts. The
-- vectors below reuse the real mon and item catalogs with local slot edits
-- only, so delegation is proved against production arithmetic.
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ProgressionExperience = require("libs.mons.src.gen4.Experience")
local ProgressionStats = require("libs.mons.src.gen4.MonStats")

---@return table mon catalog with a level slot and a stone slot on CHIKORITA
local function progressionCatalog()
  local root = CatalogFixture.buildAssetRoot()
  local ItemFixture = require("libs.items.tests.item_fixture")
  local asset = ItemFixture.buildAssetRoot()
  for _, swap in ipairs({ { from = "ITEM_43", to = "RARE_CANDY" }, { from = "ITEM_210", to = "FIRE_STONE" } }) do
    local record = asset.items[swap.from]
    assert(record ~= nil, "the item fixture carries placeholder " .. swap.from)
    asset.items[swap.from] = nil
    asset.items[swap.to] = record
  end
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local catalog = require("libs.mons.src.MonCatalog").new(root, ItemCatalog.new(asset))
  local species = root.species
  assert(species.CHIKORITA ~= nil, "the fixture carries CHIKORITA")
  return catalog
end

---@param catalog table mon catalog under test
---@param seed integer fixed generator state for this roster member
---@param level integer pinned level for this vector
---@return table persistent mon record at exactly the pinned level
local function progressionMon(catalog, seed, level)
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({}))
  local species = catalog:species(record.species)
  record.experience = ProgressionExperience.expFor(catalog:growthCurve(species.growthCurve), level)
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    record.ivs[key] = 10
    record.evs[key] = 0
  end
  record.condition.currentHp = ProgressionStats.derive(record, catalog).maxHp
  return record
end

---@param catalog table mon catalog under test
---@param record table mon record under test
---@param item string identified item key for this vector
---@param inventory table<string, integer> bag counts visible to the vector
---@return table<string, unknown> progression planning context with frozen world facts
local function progressionContext(catalog, record, item, inventory)
  return {
    location = 7,
    catalog = catalog,
    item = item,
    inventory = inventory,
    party = { record },
    timeOfDay = "day",
    game = "heartgold",
  }
end

---@param reason string deferred party-use reason for this vector
---@return table<string, unknown> generated-style item definition carrying the deferral
local function deferredDefinition(reason)
  return { nativeId = 43, partyUse = { kind = "deferred", reason = reason } }
end

---@param catalog table mon catalog under test
---@param record table mon record under test
---@return table<string, unknown> derived facts carrying the live maximum
local function liveDerived(catalog, record)
  return { maxHp = ProgressionStats.derive(record, catalog).maxHp }
end

function T.deferred_sweets_stage_real_levels()
  local catalog = progressionCatalog()
  local target = progressionMon(catalog, 811, 9)
  target.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 35, ppUps = 0 },
  }
  local plan = PartyItemEffects.plan(
    target,
    deferredDefinition("level_up"),
    nil,
    progressionContext(catalog, target, "RARE_CANDY", { RARE_CANDY = 1 }),
    liveDerived(catalog, target)
  )
  Assert.equal(plan.kind, "ready", "a decision-free sweet stages a ready plan")
  local species = catalog:species("CHIKORITA")
  local curve = catalog:growthCurve(species.growthCurve)
  Assert.equal(
    plan.updates.experience,
    ProgressionExperience.expFor(curve, 10),
    "the staged record carries next-level experience"
  )
  Assert.equal(plan.feedback.textKey, "level_up", "the feedback names the level gain")
  Assert.equal(plan.feedback.bindings.level, 10, "the feedback names the crossed level")
end

function T.deferred_sweets_wait_on_pending_decisions()
  local catalog = progressionCatalog()
  local target = progressionMon(catalog, 823, 5)
  target.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local plan = PartyItemEffects.plan(
    target,
    deferredDefinition("level_up"),
    nil,
    progressionContext(catalog, target, "RARE_CANDY", { RARE_CANDY = 1 }),
    liveDerived(catalog, target)
  )
  Assert.equal(plan.kind, "needs_confirmation", "pending learning waits on confirmation")
  Assert.isTrue(#plan.candidate.learningOpportunities > 0, "the candidate carries the chances")
  local capped = progressionMon(catalog, 827, 9)
  local refused = PartyItemEffects.plan(
    capped,
    deferredDefinition("level_up"),
    nil,
    progressionContext(catalog, capped, "RARE_CANDY", {}),
    liveDerived(catalog, capped)
  )
  Assert.equal(refused.kind, "no_effect", "an empty pocket reports no effect")
end

function T.deferred_stones_stage_confirmable_plans()
  local root = CatalogFixture.buildAssetRoot()
  local forms = root.species.CHIKORITA.forms
  forms[0].evolutions = {
    { method = "stone", item = "FIRE_STONE", target = "EEVEE", form = 0 },
  }
  local ItemFixture = require("libs.items.tests.item_fixture")
  local asset = ItemFixture.buildAssetRoot()
  local stone = asset.items.ITEM_210
  assert(stone ~= nil, "the item fixture carries placeholder ITEM_210")
  asset.items.ITEM_210 = nil
  asset.items.FIRE_STONE = stone
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local catalog = MonCatalog.new(root, ItemCatalog.new(asset))
  local target = progressionMon(catalog, 839, 12)
  local plan = PartyItemEffects.plan(
    target,
    { nativeId = 210, partyUse = { kind = "deferred", reason = "evolution" } },
    nil,
    progressionContext(catalog, target, "FIRE_STONE", { FIRE_STONE = 2 }),
    liveDerived(catalog, target)
  )
  Assert.equal(plan.kind, "needs_confirmation", "stones wait on confirmation")
  Assert.equal(plan.candidate.plan.monAfter.species, "EEVEE", "the candidate carries the stone target")
  Assert.deepEqual(
    plan.candidate.plan.inventoryDeltas,
    { { item = "FIRE_STONE", delta = -1 } },
    "the candidate spends exactly one stone"
  )
  Assert.equal(plan.candidate.consumedOnAccept, 1, "accepting spends exactly one")
  Assert.equal(plan.candidate.consumedOnCancel, 0, "declining spends nothing")
  local wrong = PartyItemEffects.plan(
    target,
    { nativeId = 210, partyUse = { kind = "deferred", reason = "evolution" } },
    nil,
    progressionContext(catalog, target, "FIRE_STONE", {}),
    liveDerived(catalog, target)
  )
  Assert.equal(wrong.kind, "no_effect", "an empty pocket reports no effect")
end

function T.deferred_items_without_identified_facts_stay_deferred()
  local catalog = progressionCatalog()
  local target = progressionMon(catalog, 853, 9)
  local bare = { location = 7, catalog = catalog }
  Assert.equal(
    PartyItemEffects.plan(target, deferredDefinition("level_up"), nil, bare, liveDerived(catalog, target)).kind,
    "feature_unavailable",
    "an unidentified item stays deferred"
  )
  local noBag = progressionContext(catalog, target, "RARE_CANDY", { RARE_CANDY = 1 })
  noBag.inventory = nil
  Assert.equal(
    PartyItemEffects.plan(target, deferredDefinition("level_up"), nil, noBag, liveDerived(catalog, target)).kind,
    "feature_unavailable",
    "missing bag facts stay deferred"
  )
  Assert.equal(
    PartyItemEffects.plan(
      target,
      deferredDefinition("battle_only"),
      nil,
      progressionContext(catalog, target, "RARE_CANDY", { RARE_CANDY = 1 }),
      liveDerived(catalog, target)
    ).kind,
    "feature_unavailable",
    "non-progression deferrals stay unavailable"
  )
  local egg = progressionMon(catalog, 859, 9)
  egg.isEgg = true
  Assert.equal(
    PartyItemEffects.plan(
      egg,
      deferredDefinition("level_up"),
      nil,
      progressionContext(catalog, egg, "RARE_CANDY", { RARE_CANDY = 1 }),
      liveDerived(catalog, egg)
    ).kind,
    "ineligible",
    "eggs stay ineligible"
  )
end

return { tests = T }
