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
-- host identifies the item. The vectors below reuse the real mon and item
-- catalogs with local slot edits only, so delegation is proved against
-- production arithmetic.
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
---@param item string identified item key for this vector
---@return table<string, unknown> progression planning context
local function progressionContext(catalog, item)
  return { location = 7, catalog = catalog, item = item }
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

local BANDS = { lo = 5, med = 3, hi = 2 }

---@param bands table<string, integer>|nil friendship bands carried by the candy
---@return table<string, unknown> generated-style Rare Candy definition
local function candyDefinition(bands)
  return { nativeId = 43, partyUse = { kind = "deferred", reason = "level_up", friendship = bands } }
end

function T.deferred_sweets_stage_the_level_and_report_the_windows()
  local catalog = progressionCatalog()
  local target = progressionMon(catalog, 811, 11)
  target.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  target.condition.currentHp = target.condition.currentHp - 3
  local plan = PartyItemEffects.plan(
    target,
    candyDefinition(nil),
    nil,
    progressionContext(catalog, "RARE_CANDY"),
    liveDerived(catalog, target)
  )
  Assert.equal(plan.kind, "ready", "a sweet stages a ready plan")
  local curve = catalog:growthCurve(catalog:species("CHIKORITA").growthCurve)
  Assert.equal(plan.updates.experience, ProgressionExperience.expFor(curve, 12), "the staged record is one level up")
  Assert.equal(plan.feedback.textKey, "level_up", "the feedback names the level gain")
  Assert.deepEqual(plan.feedback.bindings, { item = "RARE_CANDY", level = 12 }, "the feedback names item and level")
  Assert.equal(plan.feedback.statsAfter.maxHp, ProgressionStats.derive(plan.updates, catalog).maxHp, "after window")
  Assert.equal(plan.feedback.statsBefore.maxHp, ProgressionStats.derive(target, catalog).maxHp, "before window")
  Assert.deepEqual(plan.feedback.learning, { { level = 12, move = "SYNTHESIS" } }, "the new level's move is offered")
  Assert.equal(plan.feedback.slots[1].hpBefore, target.condition.currentHp, "the slot reports the health before")
  Assert.equal(plan.feedback.slots[1].hpAfter, plan.updates.condition.currentHp, "the slot reports the health after")
  Assert.equal(#plan.updates.moves, 1, "learning stays with the host")
  local capped = progressionMon(catalog, 827, 100)
  capped.experience = curve[100]
  Assert.equal(
    PartyItemEffects.plan(
      capped,
      candyDefinition(nil),
      nil,
      progressionContext(catalog, "RARE_CANDY"),
      liveDerived(catalog, capped)
    ).kind,
    "no_effect",
    "a level-100 mon takes no sweet"
  )
end

-- The candy's friendship bands apply after the level, by the band of the
-- friendship held at use, with the Luxury Ball, egg-location, and held
-- friendship-boost bonuses and the 255 cap.
function T.deferred_sweets_apply_their_friendship_bands()
  local catalog = progressionCatalog()
  local function friendshipAfter(friendship, overrides)
    local target = progressionMon(catalog, 841, 9)
    target.friendship = friendship
    target.mood = 0
    target.origin = { ball = "POKE_BALL" }
    target.egg = { location = 99 }
    for key, value in pairs(overrides or {}) do
      target[key] = value
    end
    local plan = PartyItemEffects.plan(
      target,
      candyDefinition(BANDS),
      nil,
      progressionContext(catalog, "RARE_CANDY"),
      liveDerived(catalog, target)
    )
    Assert.equal(plan.kind, "ready", "the sweet applies")
    Assert.equal(plan.updates.mood, 0, "the candy defines no mood change")
    return plan.updates.friendship
  end
  Assert.equal(friendshipAfter(99), 99 + 5, "low band")
  Assert.equal(friendshipAfter(100), 100 + 3, "middle band starts at 100")
  Assert.equal(friendshipAfter(199), 199 + 3, "middle band ends at 199")
  Assert.equal(friendshipAfter(200), 200 + 2, "high band starts at 200")
  Assert.equal(friendshipAfter(254), 255, "the sum caps at 255")
  Assert.equal(friendshipAfter(255), 255, "a maxed mon stays maxed")
  Assert.equal(friendshipAfter(50, { origin = { ball = "LUXURY_BALL" } }), 50 + 5 + 1, "luxury ball bonus")
  Assert.equal(friendshipAfter(50, { egg = { location = 7 } }), 50 + 5 + 1, "egg location bonus")
  Assert.equal(friendshipAfter(50, { heldItem = "SOOTHE_BELL" }), 50 + math.floor(5 * 150 / 100), "held boost")
  Assert.equal(
    friendshipAfter(50, { heldItem = "SOOTHE_BELL", origin = { ball = "LUXURY_BALL" } }),
    50 + math.floor((5 + 1) * 150 / 100),
    "boost multiplies after the ball bonus"
  )
end

-- Evolution items only answer whether they evolve the mon.
function T.deferred_stones_answer_whether_they_evolve_the_mon()
  local root = CatalogFixture.buildAssetRoot()
  root.species.CHIKORITA.forms[0].evolutions = {
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
  local definition = { nativeId = 210, partyUse = { kind = "deferred", reason = "evolution" } }
  local plan = PartyItemEffects.plan(
    target,
    definition,
    nil,
    progressionContext(catalog, "FIRE_STONE"),
    liveDerived(catalog, target)
  )
  Assert.deepEqual(plan, { kind = "evolution" }, "the matching stone evolves the mon")
  Assert.equal(
    PartyItemEffects.plan(
      target,
      definition,
      nil,
      progressionContext(catalog, "WATER_STONE"),
      liveDerived(catalog, target)
    ).kind,
    "no_effect",
    "a stone with no slot has no effect"
  )
end

function T.deferred_items_keep_eggs_and_other_deferrals_out()
  local catalog = progressionCatalog()
  local target = progressionMon(catalog, 853, 9)
  Assert.equal(
    PartyItemEffects.plan(
      target,
      deferredDefinition("battle_only"),
      nil,
      progressionContext(catalog, "RARE_CANDY"),
      liveDerived(catalog, target)
    ).kind,
    "feature_unavailable",
    "non-progression deferrals stay unavailable"
  )
  local egg = progressionMon(catalog, 859, 9)
  egg.isEgg = true
  for _, reason in ipairs({ "level_up", "evolution" }) do
    Assert.equal(
      PartyItemEffects.plan(
        egg,
        deferredDefinition(reason),
        nil,
        progressionContext(catalog, "RARE_CANDY"),
        liveDerived(catalog, egg)
      ).kind,
      "ineligible",
      "eggs stay ineligible for " .. reason
    )
  end
end

return { tests = T }
