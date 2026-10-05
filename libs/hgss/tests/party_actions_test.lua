-- Compound held-item actions over the live mon and bag services: give, take
-- and exchange publish atomically with stale-target protection, and source
-- form rules follow the held item while unrelated mon data round-trips.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyActions = require("libs.hgss.src.field.PartyActions")

-- Source item identities used below (include/constants/items.h): the flame
-- plate is 298, the plate run ends at the iron plate 313, and the griseous
-- orb is 112. The synthetic keys stay untouched so shared placeholder
-- expectations keep holding; only the action metadata is specialized here.
local FLAME_PLATE = "ITEM_298"
local GRISEOUS_ORB = "ITEM_112"
local GRASS_MAIL = "ITEM_137"

local function statSet(hp, attack, defense, speed, specialAttack, specialDefense)
  return {
    hp = hp,
    attack = attack,
    defense = defense,
    speed = speed,
    specialAttack = specialAttack,
    specialDefense = specialDefense,
  }
end

local function itemRoot()
  local root = ItemFixture.buildAssetRoot()
  for _, record in pairs(root.items) do
    record.isHm = false
    record.canHold = record.pocket ~= "key_items" and record.pocket ~= "mail"
    record.heldFormEffect = "none"
  end
  root.items.TM01.isHm = false
  root.items.TM01.canHold = true
  local orb = root.items[GRISEOUS_ORB]
  orb.pocket = "items"
  orb.canHold = true
  orb.heldFormEffect = "griseous_orb"
  for nativeId = 298, 313 do
    local plate = root.items["ITEM_" .. nativeId]
    plate.pocket = "items"
    plate.canHold = true
    plate.heldFormEffect = "arceus_plate"
  end
  local mail = root.items[GRASS_MAIL]
  mail.pocket = "mail"
  mail.canHold = false
  return root
end

local function formEntry(baseStats, types, abilities)
  return {
    baseStats = baseStats,
    types = types,
    abilities = abilities,
    tmhm = {},
    levelUpMoves = {},
    evolutions = {},
    icon = "ARCEUS/f0",
    portrait = "ARCEUS/f0/male/plain",
    performance = {
      power = { base = 3, min = 2, max = 5 },
      skill = { base = 3, min = 2, max = 5 },
      speed = { base = 3, min = 2, max = 5 },
      jump = { base = 3, min = 2, max = 5 },
      stamina = { base = 3, min = 2, max = 5 },
    },
  }
end

local function monRoot()
  local root = CatalogFixture.buildAssetRoot()
  root.abilities.MULTITYPE = { nativeId = 121, name = "Multitype", description = "Multitype" }
  local forms = {}
  for form = 0, 16 do
    forms[form] = formEntry(statSet(50, 50, 50, 50, 50, 50), { "normal" }, { "MULTITYPE" })
  end
  forms[10] = formEntry(statSet(60, 60, 60, 60, 60, 60), { "fire" }, { "MULTITYPE" })
  root.species.ARCEUS = {
    nativeId = 493,
    name = "ARCEUS",
    growthCurve = "medium_fast",
    baseFriendship = 0,
    genderRatio = 255,
    eggCycles = 120,
    eggGroups = { "undiscovered", "undiscovered" },
    catchRate = 3,
    baseExpYield = 255,
    evYield = statSet(0, 0, 0, 0, 0, 0),
    heldItems = {
      common = { item = "NONE", nativeId = 0 },
      rare = { item = "NONE", nativeId = 0 },
    },
    color = 4,
    flip = false,
    forms = forms,
  }
  local giratinaForms = {
    [0] = formEntry(statSet(70, 70, 70, 70, 70, 70), { "ghost", "dragon" }, { "PRESSURE" }),
    [1] = formEntry(statSet(80, 80, 80, 80, 80, 80), { "ghost", "dragon" }, { "LEVITATE" }),
  }
  root.species.GIRATINA = {
    nativeId = 487,
    name = "GIRATINA",
    growthCurve = "slow",
    baseFriendship = 0,
    genderRatio = 255,
    eggCycles = 120,
    eggGroups = { "undiscovered", "undiscovered" },
    catchRate = 3,
    baseExpYield = 255,
    evYield = statSet(0, 0, 0, 0, 0, 0),
    heldItems = {
      common = { item = "NONE", nativeId = 0 },
      rare = { item = "NONE", nativeId = 0 },
    },
    color = 1,
    flip = false,
    forms = giratinaForms,
  }
  root.abilities.PRESSURE = { nativeId = 46, name = "Pressure", description = "Pressure" }
  root.abilities.LEVITATE = { nativeId = 26, name = "Levitate", description = "Levitate" }
  return root
end

local function openServices()
  local items = itemRoot()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local itemCatalog = ItemCatalog.new(items)
  local catalog = MonCatalog.new(monRoot(), itemCatalog)
  local mons = require("libs.hgss.src.mons.HgssMonService").new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x11111111):capture(), catalog:fingerprint()),
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
  local factory = CatalogFixture.makeFactory(0x22222222, catalog)
  return mons, bag, factory, catalog
end

local function addGifted(mons, factory, species, form, heldItem)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, form = form or 0 }))
  if heldItem ~= nil then
    mon.heldItem = heldItem
  end
  Assert.isTrue(mons:addMon(mon), "setup mon must enter the party")
  return mons:partyMon(mons:partyCount() - 1)
end

local function giveRequest(mons, bag, slot, item, confirmed)
  return {
    kind = "give",
    slot = slot,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = item,
    confirmed = confirmed,
  }
end

local function takeRequest(mons, bag, slot)
  return {
    kind = "take",
    slot = slot,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  }
end

local T = {}

function T.capacity_failure_leaves_both_owners_untouched()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 0, "POTION")
  Assert.isTrue(bag:add("SITRUS_BERRY", 1))
  -- Fill the medicine pocket so the held potion has nowhere to return to.
  for nativeId = 0, 536 do
    if #bag:pocketItems("medicine") >= bag:catalog():pocket("medicine").capacity then
      break
    end
    local key = bag:catalog():itemKeyByNativeId(nativeId)
    local definition = bag:catalog():item(key)
    if definition.pocket == "medicine" and key ~= "POTION" and bag:quantity(key) == 0 then
      Assert.isTrue(bag:add(key, 1), "setup must occupy the held item return pocket")
    end
  end
  Assert.isFalse(bag:hasSpace("POTION", 1), "setup must leave the return pocket full")

  local monBefore = mons:partyMon(0)
  local bagBefore = bag:capture()
  local monRevision = mons:partyRevision()
  local bagRevision = bag:revision()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local preview = actions:preview(giveRequest(mons, bag, 0, "SITRUS_BERRY", true))
  Assert.equal(preview.kind, "ready", "capacity is decided after the staged removal")
  local outcome = actions:commit(giveRequest(mons, bag, 0, "SITRUS_BERRY", true))
  Assert.equal(outcome.kind, "bag_full")
  local takeOutcome = actions:commit(takeRequest(mons, bag, 0))
  Assert.equal(takeOutcome.kind, "bag_full")

  Assert.deepEqual(mons:partyMon(0), monBefore, "a refused exchange preserves the mon")
  Assert.deepEqual(bag:capture(), bagBefore, "a refused exchange preserves the bag")
  Assert.equal(mons:partyRevision(), monRevision, "a refused exchange publishes no mon revision")
  Assert.equal(bag:revision(), bagRevision, "a refused exchange publishes no bag revision")
end

function T.confirmed_exchange_publishes_both_owners_once()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 0, "CHERI_BERRY")
  Assert.isTrue(bag:add("SITRUS_BERRY", 1))
  Assert.isTrue(bag:add("ITEM_160", 2))
  local monRevision = mons:partyRevision()
  local bagRevision = bag:revision()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local unconfirmed = actions:preview(giveRequest(mons, bag, 0, "SITRUS_BERRY", false))
  Assert.equal(unconfirmed.kind, "needs_confirmation")
  local untouched = actions:commit(giveRequest(mons, bag, 0, "SITRUS_BERRY", false))
  Assert.equal(untouched.kind, "needs_confirmation")
  Assert.equal(mons:partyMon(0).heldItem, "CHERI_BERRY", "an unconfirmed exchange moves nothing")

  local preview = actions:preview(giveRequest(mons, bag, 0, "SITRUS_BERRY", true))
  Assert.equal(preview.kind, "ready")
  local outcome = actions:commit(giveRequest(mons, bag, 0, "SITRUS_BERRY", true))
  Assert.equal(outcome.kind, "changed")
  Assert.equal(mons:partyMon(0).heldItem, "SITRUS_BERRY", "the holder keeps the new berry")
  Assert.equal(bag:quantity("SITRUS_BERRY"), 0, "exactly one new berry leaves the bag")
  Assert.equal(bag:quantity("CHERI_BERRY"), 1, "the old berry returns to the bag")
  Assert.equal(mons:partyRevision(), monRevision + 1, "the party publishes exactly once")
  Assert.equal(bag:revision(), bagRevision + 1, "the bag publishes exactly once")
  Assert.equal(outcome.partyRevision, monRevision + 1)
  Assert.equal(outcome.bagRevision, bagRevision + 1)
  local berries = bag:pocketItems("berries")
  Assert.equal(berries[1].item, "CHERI_BERRY", "the returned berry sorts by native identity")
  Assert.equal(berries[2].item, "ITEM_160")
end

function T.stale_request_consumes_nothing()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 0, "NONE")
  Assert.isTrue(bag:add("POTION", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local request = giveRequest(mons, bag, 0, "POTION", true)
  addGifted(mons, factory, "EEVEE", 0, "NONE")

  local preview = actions:preview(request)
  Assert.equal(preview.kind, "stale")
  local outcome = actions:commit(request)
  Assert.equal(outcome.kind, "stale")
  Assert.equal(bag:quantity("POTION"), 1, "a stale give consumes nothing")
  local fresh = mons:partyMon(0)
  Assert.notNil(fresh.species, "fresh facts stay readable after a stale refusal")
end

function T.held_item_changes_update_form_and_preserve_fields()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "ARCEUS", 0, "NONE")
  Assert.isTrue(bag:add(FLAME_PLATE, 1))
  Assert.isTrue(bag:add(GRISEOUS_ORB, 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local before = mons:partyMon(0)
  local derivedBefore = mons:partyMonDerived(0)

  local outcome = actions:commit(giveRequest(mons, bag, 0, FLAME_PLATE, true))
  Assert.equal(outcome.kind, "changed")
  local changed = mons:partyMon(0)
  Assert.equal(changed.form, 10, "the flame plate selects the fire form")
  Assert.equal(changed.species, before.species)
  Assert.equal(changed.personality, before.personality)
  Assert.equal(changed.experience, before.experience)
  Assert.equal(changed.shinyLeaves, before.shinyLeaves)
  Assert.equal(changed.capsule.id, before.capsule.id)
  Assert.deepEqual(changed.mail, before.mail, "mail survives a form change")
  local derivedAfter = mons:partyMonDerived(0)
  Assert.isTrue(derivedAfter.maxHp ~= derivedBefore.maxHp, "derived stats follow the new form")
  Assert.equal(outcome.before.form, 0)
  Assert.equal(outcome.after.form, 10)

  addGifted(mons, factory, "GIRATINA", 0, "NONE")
  local giratinaBefore = mons:partyMon(1)
  local giratinaOutcome = actions:commit(giveRequest(mons, bag, 1, GRISEOUS_ORB, true))
  Assert.equal(giratinaOutcome.kind, "changed")
  local giratina = mons:partyMon(1)
  Assert.equal(giratina.form, 1, "the griseous orb selects the origin form")
  Assert.equal(giratina.species, giratinaBefore.species)
  Assert.equal(giratina.shinyLeaves, giratinaBefore.shinyLeaves)

  local takeOutcome = actions:commit(takeRequest(mons, bag, 1))
  Assert.equal(takeOutcome.kind, "changed")
  Assert.equal(mons:partyMon(1).form, 0, "removing the orb restores the altered form")
  Assert.equal(mons:partyMon(1).heldItem, "NONE")
end

local function firstMedicineKeyExcept(bag, excluded)
  local catalog = bag:catalog()
  for nativeId = 0, 536 do
    local key = catalog:itemKeyByNativeId(nativeId)
    if key ~= excluded and catalog:item(key).pocket == "medicine" then
      return key
    end
  end
  error("the catalog carries no spare medicine item", 0)
end

-- Occupies every medicine slot while keeping the held item out, so the
-- displaced item can only return if a staged removal frees its slot.
local function fillMedicineExcept(bag, excluded)
  local catalog = bag:catalog()
  for nativeId = 0, 536 do
    if #bag:pocketItems("medicine") >= catalog:pocket("medicine").capacity then
      break
    end
    local key = catalog:itemKeyByNativeId(nativeId)
    if key ~= excluded and catalog:item(key).pocket == "medicine" and bag:quantity(key) == 0 then
      Assert.isTrue(bag:add(key, 1), "setup must occupy the held item return pocket")
    end
  end
  Assert.equal(
    #bag:pocketItems("medicine"),
    catalog:pocket("medicine").capacity,
    "setup must leave the return pocket full"
  )
end

function T.confirmed_exchange_reuses_the_replacement_slot_in_a_full_pocket()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 0, "POTION")
  local replacement = firstMedicineKeyExcept(bag, "POTION")
  Assert.isTrue(bag:add(replacement, 1), "setup must stock the replacement as a lone stack")
  fillMedicineExcept(bag, "POTION")
  Assert.equal(bag:quantity("POTION"), 0, "the held potion starts absent from the bag")
  Assert.isFalse(bag:hasSpace("POTION", 1), "setup must leave the return pocket full")

  local monRevision = mons:partyRevision()
  local bagRevision = bag:revision()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local preview = actions:preview(giveRequest(mons, bag, 0, replacement, true))
  Assert.equal(preview.kind, "ready", "removing the lone replacement stack frees its slot")
  local outcome = actions:commit(giveRequest(mons, bag, 0, replacement, true))
  Assert.equal(outcome.kind, "changed")
  Assert.equal(mons:partyMon(0).heldItem, replacement, "the holder keeps the replacement")
  Assert.equal(bag:quantity(replacement), 0, "exactly one replacement leaves the bag")
  Assert.equal(bag:quantity("POTION"), 1, "the displaced potion returns to the freed slot")
  Assert.equal(mons:partyRevision(), monRevision + 1, "the party publishes exactly once")
  Assert.equal(bag:revision(), bagRevision + 1, "the bag publishes exactly once")
end

function T.confirmed_exchange_without_a_freed_slot_refuses_atomically()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 0, "POTION")
  Assert.isTrue(bag:add("SITRUS_BERRY", 1), "setup must stock the cross-pocket replacement")
  fillMedicineExcept(bag, "POTION")
  Assert.isFalse(bag:hasSpace("POTION", 1), "setup must leave the return pocket full")

  local monBefore = mons:partyMon(0)
  local bagBefore = bag:capture()
  local monRevision = mons:partyRevision()
  local bagRevision = bag:revision()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local preview = actions:preview(giveRequest(mons, bag, 0, "SITRUS_BERRY", true))
  Assert.equal(preview.kind, "ready", "capacity is decided after the staged removal")
  local outcome = actions:commit(giveRequest(mons, bag, 0, "SITRUS_BERRY", true))
  Assert.equal(outcome.kind, "bag_full")
  Assert.deepEqual(mons:partyMon(0), monBefore, "a refused exchange preserves the mon")
  Assert.deepEqual(bag:capture(), bagBefore, "a refused exchange preserves the bag")
  Assert.equal(mons:partyRevision(), monRevision, "a refused exchange publishes no mon revision")
  Assert.equal(bag:revision(), bagRevision, "a refused exchange publishes no bag revision")
end

return { tests = T }
