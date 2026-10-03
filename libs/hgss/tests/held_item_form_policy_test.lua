-- Held-item form policy: pure source-shaped Arceus plate and Giratina orb
-- effects on a copied mon. Plates select the fire/water/electric/grass/ice/
-- fighting/poison/ground/flying/psychic/bug/rock/ghost/dragon/dark/steel
-- forms through the Multitype gate (pret/pokeheartgold
-- GetArceusTypeByHeldItemEffect, Gen-IV type order); the griseous orb
-- selects the origin form, anything else restores the base form. Stat
-- derivation stays with the real mon service; gated-out mons never touch it.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HeldItemFormPolicy = require("libs.hgss.src.mons.HeldItemFormPolicy")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local function statSet(hp)
  return { hp = hp, attack = 50, defense = 50, speed = 50, specialAttack = 50, specialDefense = 50 }
end

local function zeroYield()
  return { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
end

local function formEntry(baseStats, types, abilities)
  return {
    baseStats = baseStats,
    types = types,
    abilities = abilities,
    tmhm = {},
    levelUpMoves = {},
    evolutions = {},
    icon = "X/f0",
    portrait = "X/f0/male/plain",
    performance = {
      power = { base = 3, min = 2, max = 5 },
      skill = { base = 3, min = 2, max = 5 },
      speed = { base = 3, min = 2, max = 5 },
      jump = { base = 3, min = 2, max = 5 },
      stamina = { base = 3, min = 2, max = 5 },
    },
  }
end

local function catalog()
  local monRoot = CatalogFixture.buildAssetRoot()
  monRoot.abilities.MULTITYPE = { nativeId = 121, name = "Multitype", description = "Multitype" }
  monRoot.abilities.PRESSURE = { nativeId = 46, name = "Pressure", description = "Pressure" }
  monRoot.abilities.LEVITATE = { nativeId = 26, name = "Levitate", description = "Levitate" }
  local forms = {}
  for form = 0, 16 do
    forms[form] = formEntry(statSet(50), { "normal" }, { "MULTITYPE" })
  end
  forms[10] = formEntry(statSet(60), { "fire" }, { "MULTITYPE" })
  monRoot.species.ARCEUS = {
    nativeId = 493,
    name = "ARCEUS",
    growthCurve = "medium_fast",
    baseFriendship = 0,
    genderRatio = 255,
    eggCycles = 120,
    eggGroups = { "undiscovered", "undiscovered" },
    catchRate = 3,
    baseExpYield = 255,
    evYield = zeroYield(),
    heldItems = {
      common = { item = "NONE", nativeId = 0 },
      rare = { item = "NONE", nativeId = 0 },
    },
    color = 4,
    flip = false,
    forms = forms,
  }
  monRoot.species.GIRATINA = {
    nativeId = 487,
    name = "GIRATINA",
    growthCurve = "slow",
    baseFriendship = 0,
    genderRatio = 255,
    eggCycles = 120,
    eggGroups = { "undiscovered", "undiscovered" },
    catchRate = 3,
    baseExpYield = 255,
    evYield = zeroYield(),
    heldItems = {
      common = { item = "NONE", nativeId = 0 },
      rare = { item = "NONE", nativeId = 0 },
    },
    color = 1,
    flip = false,
    forms = {
      [0] = formEntry(statSet(70), { "ghost", "dragon" }, { "PRESSURE" }),
      [1] = formEntry(statSet(80), { "ghost", "dragon" }, { "LEVITATE" }),
    },
  }
  local itemRoot = ItemFixture.buildAssetRoot()
  for _, record in pairs(itemRoot.items) do
    record.isHm = false
    record.canHold = true
    record.heldFormEffect = "none"
  end
  itemRoot.items["ITEM_112"].heldFormEffect = "griseous_orb"
  for nativeId = 298, 313 do
    itemRoot.items["ITEM_" .. nativeId].heldFormEffect = "arceus_plate"
  end
  local items = require("libs.items.src.ItemCatalog").new(itemRoot)
  return MonCatalog.new(monRoot, items)
end

local function service(monCatalog)
  return HgssMonService.new({
    catalog = monCatalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x99999999):capture(), monCatalog:fingerprint()),
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
end

local function arceusMon(monCatalog, leaves)
  local factory = CatalogFixture.makeFactory(0x66666666, monCatalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "ARCEUS", form = 0 }))
  mon.shinyLeaves = leaves or 0
  return mon
end

local function giratinaMon(monCatalog, leaves)
  local factory = CatalogFixture.makeFactory(0x77777777, monCatalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "GIRATINA", form = 0 }))
  mon.shinyLeaves = leaves or 0
  return mon
end

local T = {}

function T.plates_select_type_forms_and_removal_restores_normal()
  local monCatalog = catalog()
  local mons = service(monCatalog)
  local flame = monCatalog:item("ITEM_298")
  local updated = HeldItemFormPolicy.apply(arceusMon(monCatalog), flame, mons)
  Assert.equal(updated.form, 10, "the flame plate selects the fire form")
  Assert.equal(updated.heldItem, "NONE", "the policy never assigns the held item itself")
  local spooky = monCatalog:item("ITEM_310")
  local ghost = HeldItemFormPolicy.apply(arceusMon(monCatalog), spooky, mons)
  Assert.equal(ghost.form, 7, "the spooky plate selects the ghost form")
  local plain = monCatalog:item("POTION")
  local restored = HeldItemFormPolicy.apply(updated, plain, mons)
  Assert.equal(restored.form, 0, "a non-plate restores the normal form")
end

function T.orb_selects_origin_and_removal_restores_altered()
  local monCatalog = catalog()
  local mons = service(monCatalog)
  local orb = monCatalog:item("ITEM_112")
  local origin = HeldItemFormPolicy.apply(giratinaMon(monCatalog), orb, mons)
  Assert.equal(origin.form, 1)
  Assert.equal(origin.ability, "LEVITATE", "the origin form recomputes the ability")
  local plain = monCatalog:item("POTION")
  local altered = HeldItemFormPolicy.apply(origin, plain, mons)
  Assert.equal(altered.form, 0)
  Assert.equal(altered.ability, "PRESSURE", "the altered form recomputes the ability")
end

function T.form_changes_preserve_every_leaf_mask_and_clamp_hp()
  local monCatalog = catalog()
  local mons = service(monCatalog)
  local flame = monCatalog:item("ITEM_298")
  local plain = monCatalog:item("POTION")
  for mask = 0, 63 do
    local mon = arceusMon(monCatalog, mask)
    mon.condition.currentHp = mons:derive(mon).maxHp
    local updated = HeldItemFormPolicy.apply(mon, flame, mons)
    Assert.equal(updated.shinyLeaves, mask, "leaves survive a form change: mask " .. mask)
    Assert.equal(mon.shinyLeaves, mask, "the input copy stays untouched: mask " .. mask)
    local injured = arceusMon(monCatalog, mask)
    injured.condition.currentHp = 1
    local hurt = HeldItemFormPolicy.apply(injured, flame, mons)
    Assert.equal(hurt.condition.currentHp, 1, "an injured mon keeps its HP: mask " .. mask)
    Assert.equal(hurt.condition.status, injured.condition.status)
    local back = HeldItemFormPolicy.apply(updated, plain, mons)
    Assert.isTrue(back.condition.currentHp <= mons:derive(back).maxHp, "HP never exceeds the restored maximum")
  end
end

function T.policy_ignores_ordinary_species_and_non_multitype_arceus()
  local monCatalog = catalog()
  local flame = monCatalog:item("ITEM_298")
  local factory = CatalogFixture.makeFactory(0x88888888, monCatalog)
  local eevee = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", form = 0 }))
  local same = HeldItemFormPolicy.apply(eevee, flame, nil)
  Assert.equal(same.form, eevee.form, "ordinary species keep their form without derivation")
  local plain = arceusMon(monCatalog)
  plain.ability = "OVERGROW"
  local gated = HeldItemFormPolicy.apply(plain, flame, nil)
  Assert.equal(gated.form, 0, "a non-Multitype Arceus keeps its form without derivation")
end

return { tests = T }
