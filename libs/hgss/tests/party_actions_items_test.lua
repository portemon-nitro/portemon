-- Composed party-item actions over the live mon and bag services: no-effect
-- preservation, combined restoration, Sacred Ash single consumption, and
-- full-cost HP transfer publish atomically with stale-target protection.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyActions = require("libs.hgss.src.field.PartyActions")

local function cures(all)
  return {
    sleep = all,
    poison = all,
    burn = all,
    freeze = all,
    paralysis = all,
  }
end

local function friendship(lo, med, hi)
  return { lo = lo, med = med, hi = hi }
end

local function itemRoot()
  local root = ItemFixture.buildAssetRoot()
  -- Custom records replace their numeric placeholders so native identities
  -- resolve exactly once.
  for _, nativeId in ipairs({ 23, 28, 38, 44, 45, 51 }) do
    root.items["ITEM_" .. nativeId] = nil
  end
  root.items.POTION.partyUse = {
    kind = "medicine",
    cures = cures(false),
    restore = { kind = "fixed", amount = 20 },
    revive = "none",
    mood = 0,
  }
  root.items.FULL_RESTORE = {
    nativeId = 23,
    pocket = "medicine",
    name = "Full Restore",
    nameIndefinite = "a Full Restore",
    namePlural = "Full Restores",
    description = "Full Restore description",
    preventToss = false,
    selectable = true,
    isBall = false,
    friendshipBoost = false,
    icon = "FULL_RESTORE",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = {
      kind = "medicine",
      cures = cures(true),
      restore = { kind = "full" },
      revive = "none",
      mood = 0,
    },
  }
  root.items.REVIVE = {
    nativeId = 28,
    pocket = "medicine",
    name = "Revive",
    nameIndefinite = "a Revive",
    namePlural = "Revives",
    description = "Revive description",
    preventToss = false,
    selectable = true,
    isBall = false,
    friendshipBoost = false,
    icon = "REVIVE",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = {
      kind = "medicine",
      cures = cures(false),
      restore = { kind = "half" },
      revive = "single",
      mood = 0,
    },
  }
  root.items.SACRED_ASH = {
    nativeId = 44,
    pocket = "medicine",
    name = "Sacred Ash",
    nameIndefinite = "some Sacred Ash",
    namePlural = "Sacred Ashes",
    description = "Sacred Ash description",
    preventToss = false,
    selectable = true,
    isBall = false,
    friendshipBoost = false,
    icon = "SACRED_ASH",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = { kind = "revive_all" },
  }
  root.items.ETHER = {
    nativeId = 38,
    pocket = "medicine",
    name = "Ether",
    nameIndefinite = "an Ether",
    namePlural = "Ethers",
    description = "Ether description",
    preventToss = false,
    selectable = true,
    isBall = false,
    friendshipBoost = false,
    icon = "ETHER",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = {
      kind = "pp",
      target = "one",
      restore = 10,
      mood = 0,
    },
  }
  root.items.PP_UP = {
    nativeId = 51,
    pocket = "medicine",
    name = "PP Up",
    nameIndefinite = "a PP Up",
    namePlural = "PP Ups",
    description = "PP Up description",
    preventToss = false,
    selectable = true,
    isBall = false,
    friendshipBoost = false,
    icon = "PP_UP",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = {
      kind = "pp",
      target = "one",
      boost = 1,
      friendship = friendship(5, 3, 2),
      mood = 0,
    },
  }
  root.items.HP_UP = {
    nativeId = 45,
    pocket = "medicine",
    name = "HP Up",
    nameIndefinite = "an HP Up",
    namePlural = "HP Ups",
    description = "HP Up description",
    preventToss = false,
    selectable = true,
    isBall = false,
    friendshipBoost = false,
    icon = "HP_UP",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = {
      kind = "ev",
      changes = { { stat = "hp", delta = 10 } },
      friendship = friendship(5, 3, 2),
      mood = 8,
    },
  }
  root.items.ITEM_169.partyUse = {
    kind = "ev",
    changes = { { stat = "hp", delta = -10 } },
    friendship = friendship(10, 5, 2),
    mood = 0,
  }
  -- ITEM_88 stands in for a flagged-but-effectless record: valid metadata
  -- that can never apply.
  root.items.ITEM_88.partyUse = {
    kind = "medicine",
    cures = cures(false),
    revive = "none",
    mood = 0,
  }
  root.items.ITEM_34.partyUse = {
    kind = "medicine",
    cures = cures(false),
    restore = { kind = "fixed", amount = 50 },
    revive = "none",
    friendship = friendship(-5, -5, -10),
    mood = -20,
  }
  return root
end

local function openServices()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local itemCatalog = ItemCatalog.new(itemRoot())
  local catalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), itemCatalog)
  local mons = require("libs.hgss.src.mons.HgssMonService").new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x33333333):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local bag = require("libs.hgss.src.items.HgssBagService").new({ catalog = itemCatalog })
  local factory = CatalogFixture.makeFactory(0x44444444, catalog)
  return mons, bag, factory, catalog
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = deepCopy(item)
  end
  return out
end

local function addGifted(mons, factory, species, form)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, form = form or 0 }))
  Assert.isTrue(mons:addMon(mon), "setup mon must enter the party")
  return mons:partyCount() - 1
end

local function restage(mons, slot, mutate)
  local mon = deepCopy(mons:partyMon(slot))
  mutate(mon)
  local change, reason = mons:preparePartyChanges(mons:partyRevision(), { { slot = slot, mon = mon } })
  Assert.notNil(change, "setup restage must prepare: " .. tostring(reason))
  change.publish()
end

local function useRequest(mons, bag, slot, item, moveSlot)
  return {
    kind = "use_item",
    slot = slot,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = item,
    moveSlot = moveSlot,
  }
end

local function transferRequest(mons, bag, donor, target)
  return {
    kind = "transfer_hp",
    slot = donor,
    targetSlot = target,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  }
end

local T = {}

function T.no_effect_use_preserves_everything()
  local mons, bag, factory = openServices()
  local slot = addGifted(mons, factory, "CHIKORITA", 0)
  Assert.isTrue(bag:add("POTION", 2))
  local monBefore = deepCopy(mons:partyMon(slot))
  local bagBefore = bag:capture()
  local monRevision = mons:partyRevision()
  local bagRevision = bag:revision()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local preview = actions:preview(useRequest(mons, bag, slot, "POTION"))
  Assert.equal(preview.kind, "no_effect")
  local outcome = actions:commit(useRequest(mons, bag, slot, "POTION"))
  Assert.equal(outcome.kind, "no_effect")
  Assert.deepEqual(mons:partyMon(slot), monBefore, "a no-effect use preserves the mon")
  Assert.deepEqual(bag:capture(), bagBefore, "a no-effect use preserves the bag")
  Assert.equal(mons:partyRevision(), monRevision, "a no-effect use publishes no mon revision")
  Assert.equal(bag:revision(), bagRevision, "a no-effect use publishes no bag revision")
  Assert.equal(bag:quantity("POTION"), 2, "a no-effect use consumes nothing")
end

function T.stale_use_consumes_nothing()
  local mons, bag, factory = openServices()
  local slot = addGifted(mons, factory, "CHIKORITA", 0)
  restage(mons, slot, function(mon)
    mon.condition.currentHp = mon.condition.currentHp - 10
  end)
  Assert.isTrue(bag:add("POTION", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local request = useRequest(mons, bag, slot, "POTION")
  addGifted(mons, factory, "EEVEE", 0)

  Assert.equal(actions:preview(request).kind, "stale")
  Assert.equal(actions:commit(request).kind, "stale")
  Assert.equal(bag:quantity("POTION"), 1, "a stale use consumes nothing")
end

function T.effectless_party_use_is_no_effect_not_success()
  local mons, bag, factory = openServices()
  local slot = addGifted(mons, factory, "CHIKORITA", 0)
  Assert.isTrue(bag:add("ITEM_88", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  -- A flagged-but-effectless record is valid metadata that can never apply,
  -- that can never apply, so it stays no_effect instead of succeeding.
  Assert.equal(actions:preview(useRequest(mons, bag, slot, "ITEM_88")).kind, "no_effect")
  Assert.equal(actions:commit(useRequest(mons, bag, slot, "ITEM_88")).kind, "no_effect")
  Assert.equal(bag:quantity("ITEM_88"), 1, "an effectless use consumes nothing")
end

function T.full_restore_heals_combined_flags()
  local mons, bag, factory = openServices()
  local slot = addGifted(mons, factory, "CHIKORITA", 0)
  local maxHp = mons:derive(mons:partyMon(slot)).maxHp
  restage(mons, slot, function(mon)
    mon.condition.currentHp = maxHp - 25
    mon.condition.effects = { { key = "poison", version = 1, state = {} } }
  end)
  Assert.isTrue(bag:add("FULL_RESTORE", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })

  Assert.equal(actions:preview(useRequest(mons, bag, slot, "FULL_RESTORE")).kind, "ready")
  local outcome = actions:commit(useRequest(mons, bag, slot, "FULL_RESTORE"))
  Assert.equal(outcome.kind, "changed")
  local after = mons:partyMon(slot)
  Assert.equal(after.condition.currentHp, maxHp, "combined restore heals to full")
  Assert.deepEqual(after.condition.effects, {}, "combined restore clears the condition")
  Assert.equal(bag:quantity("FULL_RESTORE"), 0, "exactly one item is consumed")
  Assert.equal(outcome.feedback.slots[1].hpBefore, maxHp - 25)
  Assert.equal(outcome.feedback.slots[1].hpAfter, maxHp)
end

function T.revive_restores_half_at_zero_only()
  local mons, bag, factory = openServices()
  local slot = addGifted(mons, factory, "CHIKORITA", 0)
  local maxHp = mons:derive(mons:partyMon(slot)).maxHp
  restage(mons, slot, function(mon)
    mon.condition.currentHp = 0
  end)
  Assert.isTrue(bag:add("REVIVE", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local outcome = actions:commit(useRequest(mons, bag, slot, "REVIVE"))
  Assert.equal(outcome.kind, "changed")
  Assert.equal(mons:partyMon(slot).condition.currentHp, math.floor(maxHp / 2), "revive restores half")
  Assert.equal(bag:quantity("REVIVE"), 0)

  restage(mons, slot, function(mon)
    mon.condition.currentHp = maxHp - 5
  end)
  Assert.isTrue(bag:add("REVIVE", 1))
  Assert.equal(actions:commit(useRequest(mons, bag, slot, "REVIVE")).kind, "no_effect")
  Assert.equal(bag:quantity("REVIVE"), 1, "revive on the living has no effect and consumes nothing")
end

function T.sacred_ash_revives_once_across_slots()
  local mons, bag, factory = openServices()
  local first = addGifted(mons, factory, "CHIKORITA", 0)
  local second = addGifted(mons, factory, "EEVEE", 0)
  local eggSlot = addGifted(mons, factory, "CHIKORITA", 0)
  local healthy = addGifted(mons, factory, "EEVEE", 0)
  restage(mons, first, function(mon)
    mon.condition.currentHp = 0
  end)
  restage(mons, second, function(mon)
    mon.condition.currentHp = 0
  end)
  restage(mons, eggSlot, function(mon)
    mon.isEgg = true
    mon.condition.currentHp = 0
  end)
  local firstMax = mons:derive(mons:partyMon(first)).maxHp
  local secondMax = mons:derive(mons:partyMon(second)).maxHp
  local monRevision = mons:partyRevision()
  Assert.isTrue(bag:add("SACRED_ASH", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local outcome = actions:commit(useRequest(mons, bag, healthy, "SACRED_ASH"))
  Assert.equal(outcome.kind, "changed")
  Assert.equal(mons:partyMon(first).condition.currentHp, firstMax, "the first fainted mon revives fully")
  Assert.equal(mons:partyMon(second).condition.currentHp, secondMax, "the second fainted mon revives fully")
  Assert.equal(mons:partyMon(eggSlot).condition.currentHp, 0, "the egg stays fainted")
  Assert.equal(bag:quantity("SACRED_ASH"), 0, "sacred ash consumes exactly once")
  Assert.equal(mons:partyRevision(), monRevision + 1, "sacred ash publishes one party revision")
  Assert.equal(#outcome.feedback.slots, 2, "feedback visits exactly the affected slots")

  Assert.isTrue(bag:add("SACRED_ASH", 1))
  local replay = actions:commit(useRequest(mons, bag, healthy, "SACRED_ASH"))
  Assert.equal(replay.kind, "no_effect", "a replay with no fainted mons changes nothing")
  Assert.equal(bag:quantity("SACRED_ASH"), 1, "an effectless replay consumes nothing")
end

function T.vitamin_preserves_damage_and_consumes_once()
  local mons, bag, factory = openServices()
  local slot = addGifted(mons, factory, "CHIKORITA", 0)
  local maxHp = mons:derive(mons:partyMon(slot)).maxHp
  restage(mons, slot, function(mon)
    mon.condition.currentHp = maxHp - 4
  end)
  local monRevision = mons:partyRevision()
  Assert.isTrue(bag:add("HP_UP", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local outcome = actions:commit(useRequest(mons, bag, slot, "HP_UP"))
  Assert.equal(outcome.kind, "changed")
  local after = mons:partyMon(slot)
  Assert.equal(after.evs.hp, 10, "the vitamin raises effort")
  local newMax = mons:derive(after).maxHp
  Assert.equal(
    after.condition.currentHp,
    math.min(maxHp - 4 + (newMax - maxHp), newMax),
    "damage survives the recalculation"
  )
  Assert.equal(after.friendship, 75, "low-band friendship applies without bonuses")
  Assert.equal(after.mood, 8, "vitamin mood applies")
  Assert.equal(bag:quantity("HP_UP"), 0, "exactly one vitamin is consumed")
  Assert.equal(mons:partyRevision(), monRevision + 1, "one party revision publishes")
end

function T.hp_transfer_costs_the_full_fifth()
  local mons, bag, factory = openServices()
  local donor = addGifted(mons, factory, "CHIKORITA", 0)
  local recipient = addGifted(mons, factory, "EEVEE", 0)
  local donorMax = mons:derive(mons:partyMon(donor)).maxHp
  local recipientMax = mons:derive(mons:partyMon(recipient)).maxHp
  restage(mons, donor, function(mon)
    mon.condition.currentHp = donorMax
  end)
  restage(mons, recipient, function(mon)
    mon.condition.currentHp = recipientMax - 3
  end)
  local donorRevision = mons:partyRevision()
  local bagBefore = bag:capture()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local cost = math.floor(donorMax / 5)
  Assert.isTrue(cost >= 1 and donorMax > cost, "the fixture donor can afford a full fifth")
  Assert.isTrue(cost > 3, "the fifth exceeds the recipient missing health, proving full cost")
  local outcome = actions:commit(transferRequest(mons, bag, donor, recipient))
  Assert.equal(outcome.kind, "changed")
  Assert.equal(mons:partyMon(donor).condition.currentHp, donorMax - cost, "the donor loses the full fifth")
  Assert.equal(mons:partyMon(recipient).condition.currentHp, recipientMax, "the recipient gains up to full health")
  Assert.equal(mons:partyRevision(), donorRevision + 1, "transfer publishes one party revision")
  Assert.deepEqual(bag:capture(), bagBefore, "transfer consumes no bag item")
end

function T.hp_transfer_rejects_bad_targets()
  local mons, bag, factory = openServices()
  local donor = addGifted(mons, factory, "CHIKORITA", 0)
  local recipient = addGifted(mons, factory, "EEVEE", 0)
  local donorMax = mons:derive(mons:partyMon(donor)).maxHp
  restage(mons, donor, function(mon)
    mon.condition.currentHp = donorMax
  end)
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local before = deepCopy(mons:partyMon(donor))

  Assert.equal(actions:commit(transferRequest(mons, bag, donor, donor)).kind, "ineligible")
  Assert.equal(actions:commit(transferRequest(mons, bag, recipient, donor)).kind, "ineligible")
  restage(mons, recipient, function(mon)
    mon.condition.currentHp = 0
  end)
  Assert.equal(actions:commit(transferRequest(mons, bag, donor, recipient)).kind, "ineligible")
  Assert.deepEqual(mons:partyMon(donor), before, "rejected transfers change nothing")
end

function T.pp_restore_needs_a_move_choice()
  local mons, bag, factory = openServices()
  local slot = addGifted(mons, factory, "CHIKORITA", 0)
  restage(mons, slot, function(mon)
    mon.moves[1].pp = mon.moves[1].pp - 15
  end)
  Assert.isTrue(bag:add("ETHER", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })

  Assert.equal(actions:preview(useRequest(mons, bag, slot, "ETHER")).kind, "needs_move")
  Assert.equal(actions:commit(useRequest(mons, bag, slot, "ETHER")).kind, "needs_move")
  Assert.equal(bag:quantity("ETHER"), 1, "a cancelled move choice consumes nothing")

  local spent = mons:partyMon(slot).moves[1].pp
  local outcome = actions:commit(useRequest(mons, bag, slot, "ETHER", 0))
  Assert.equal(outcome.kind, "changed")
  Assert.equal(mons:partyMon(slot).moves[1].pp, spent + 10, "ether restores ten points")
  Assert.equal(bag:quantity("ETHER"), 0)
end

return { tests = T }
