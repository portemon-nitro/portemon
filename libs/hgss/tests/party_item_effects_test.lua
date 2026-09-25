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
    condition = { status = 0, currentHp = 30 },
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
  local target = mon({ condition = { status = 0, currentHp = 10 } })
  local snapshot = {
    hp = target.condition.currentHp,
    status = target.condition.status,
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
  Assert.equal(target.condition.status, snapshot.status, "planning never mutates status")
  Assert.equal(target.friendship, snapshot.friendship, "planning never mutates friendship")
  Assert.equal(target.evs.hp, snapshot.ev, "planning never mutates effort values")
end

function T.fixed_restore_heals_without_overheal()
  local definition = medicine({ restore = { kind = "fixed", amount = 20 } })
  local small = mon({ condition = { status = 0, currentHp = 25 } })
  local smallPlan = PartyItemEffects.plan(small, { partyUse = definition }, nil, context(), derived(30))
  Assert.equal(smallPlan.kind, "ready")
  Assert.equal(smallPlan.updates.condition.currentHp, 30, "healing clamps at the derived maximum")
  local hurt = mon({ condition = { status = 0, currentHp = 5 } })
  local plan = PartyItemEffects.plan(hurt, { partyUse = definition }, nil, context(), derived(30))
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.updates.condition.currentHp, 25, "fixed amounts add exactly")
  Assert.equal(plan.feedback.slots[1].hpBefore, 5)
  Assert.equal(plan.feedback.slots[1].hpAfter, 25)
end

function T.quarter_restore_uses_integer_division()
  local definition = medicine({ restore = { kind = "quarter" } })
  local target = mon({ condition = { status = 0, currentHp = 10 } })
  local plan = PartyItemEffects.plan(target, { partyUse = definition }, nil, context(), derived(31))
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.updates.condition.currentHp, 10 + math.floor(31 / 4), "quarters divide down")
end

function T.max_hp_one_restores_single_point()
  local definition = medicine({ restore = { kind = "fixed", amount = 20 } })
  local shedinja = mon({ species = "SHEDINJA", condition = { status = 0, currentHp = 0 } })
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
  local target = mon({ condition = { status = 0x8 + 0x80 + 0x500, currentHp = 30 } })
  local plan = PartyItemEffects.plan(target, { partyUse = definition }, nil, context(), derived(30))
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.updates.condition.status, 0, "poison cure clears poison, toxic and counter bits")
  Assert.equal(plan.updates.condition.currentHp, 30, "a pure cure changes no hit points")
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
  local target = mon({ evs = evSet(95, 0, 0, 0, 0, 0), condition = { status = 0, currentHp = 20 } })
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
  local donor = mon({ condition = { status = 0, currentHp = 50 } })
  local recipient = mon({ condition = { status = 0, currentHp = 27 } })
  local plan = PartyItemEffects.planTransfer(donor, recipient, derived(100), derived(30))
  Assert.equal(plan.kind, "ready")
  Assert.equal(plan.donor.condition.currentHp, 30, "the donor loses the full fifth")
  Assert.equal(plan.recipient.condition.currentHp, 30, "the recipient gains up to full health")
  Assert.equal(donor.condition.currentHp, 50, "transfer planning never mutates the donor")
end

function T.transfer_rejects_bad_targets()
  local donor = mon({ condition = { status = 0, currentHp = 50 } })
  Assert.equal(PartyItemEffects.planTransfer(donor, donor, derived(100), derived(100)).kind, "ineligible")
  local fainted = mon({ condition = { status = 0, currentHp = 0 } })
  Assert.equal(PartyItemEffects.planTransfer(donor, fainted, derived(100), derived(30)).kind, "ineligible")
  local full = mon({ condition = { status = 0, currentHp = 30 } })
  Assert.equal(PartyItemEffects.planTransfer(donor, full, derived(100), derived(30)).kind, "ineligible")
  local weak = mon({ condition = { status = 0, currentHp = 20 } })
  Assert.equal(PartyItemEffects.planTransfer(weak, full, derived(100), derived(30)).kind, "ineligible")
  local egg = mon({ isEgg = true, condition = { status = 0, currentHp = 10 } })
  Assert.equal(PartyItemEffects.planTransfer(donor, egg, derived(100), derived(30)).kind, "ineligible")
end

return { tests = T }
