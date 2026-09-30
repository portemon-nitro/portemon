-- Party-screen view projection: one fresh immutable six-slot model per
-- party revision. Occupied slots carry the nickname-or-species display
-- name, derived level, derived gender, derived max HP, live current HP, HP
-- fraction, source status key, and catalog icon key; empty slots carry only
-- position and occupancy. Every derived value comes from the domain owners
-- (Mon, Personality, the service derivation seam, the catalog); the model
-- copies no formula.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")

local T = {}

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  return catalog,
    HgssMonService.new({
      catalog = catalog,
      bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xAAAAAAAA):capture(), catalog:fingerprint()),
      profile = CatalogFixture.profile(),
      game = "heartgold",
      language = "english",
      charmap = CatalogFixture.CHARMAP,
      games = CatalogFixture.GAMES,
      languages = CatalogFixture.LANGUAGES,
      items = CatalogFixture.ITEMS,
      balls = CatalogFixture.BALLS,
    })
end

local function give(service, species)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

local function store(service, slot, mutate)
  local mon = service:partyMon(slot)
  mutate(mon)
  service:removeMon(slot)
  Assert.isTrue(service:addMon(mon), "the mutated fixture mon must stay legal")
end

function T.mixed_party_projects_authoritative_display_values()
  local _, service = openService()
  give(service, "CHIKORITA")
  local maxHp = service:partyMonDerived(0).maxHp
  store(service, 0, function(mon)
    mon.nickname = "LEAFY"
    mon.condition = { status = 0x8, currentHp = maxHp - 2 }
  end)
  give(service, "SHEDINJA")

  local view = PartyScreenModel.build(service)
  Assert.equal(#view.slots, 6, "the projection always covers six slots")
  local lead = view.slots[1]
  Assert.isTrue(lead.occupied)
  Assert.equal(lead.slot, 0)
  Assert.equal(lead.displayName, "LEAFY", "nicknames win over species names")
  Assert.equal(lead.level, 5)
  Assert.isTrue(
    lead.gender == "male" or lead.gender == "female",
    "the starter gender derives, got " .. tostring(lead.gender)
  )
  Assert.equal(lead.status, "poison")
  Assert.equal(lead.currentHp, maxHp - 2)
  Assert.equal(lead.maxHp, maxHp)
  Assert.equal(lead.hpFraction, (maxHp - 2) / maxHp)
  Assert.equal(lead.iconKey, "CHIKORITA/f0")
  Assert.isTrue(lead.eligible, "the default policy admits occupied slots")

  local second = view.slots[2]
  Assert.equal(second.displayName, "SHEDINJA", "nickname falls back to the species name")
  Assert.equal(second.gender, "genderless")
  Assert.equal(second.status, "ok")
  Assert.equal(second.currentHp, second.maxHp)
  Assert.equal(second.maxHp, 1, "the service derivation owns the shedinja rule")
  Assert.equal(second.iconKey, "SHEDINJA/f0")

  for index = 3, 6 do
    local empty = view.slots[index]
    Assert.isFalse(empty.occupied, "trailing slots stay empty")
    Assert.equal(empty.slot, index - 1)
    Assert.isNil(empty.displayName)
    Assert.isNil(empty.iconKey)
    Assert.isNil(empty.level)
    Assert.isNil(empty.status)
    Assert.isFalse(empty.eligible)
  end
end

function T.eggs_project_the_egg_icon()
  local _, service = openService()
  give(service, "CHIKORITA")
  store(service, 0, function(mon)
    mon.isEgg = true
  end)
  local view = PartyScreenModel.build(service)
  Assert.equal(view.slots[1].iconKey, "CHIKORITA/egg")
end

function T.projection_refreshes_with_the_party_revision()
  local _, service = openService()
  give(service, "CHIKORITA")
  local before = PartyScreenModel.build(service)
  give(service, "TOTODILE")
  local after = PartyScreenModel.build(service)
  Assert.isTrue(after.revision ~= before.revision, "the model carries the live revision")
  Assert.isFalse(before.slots[2].occupied, "the earlier model keeps its snapshot")
  Assert.isTrue(after.slots[2].occupied, "the fresh model sees the new mon")
  Assert.isTrue(before.slots[1] ~= after.slots[1], "slot records are fresh tables per build")
end

function T.injected_eligibility_marks_slots_without_touching_values()
  local _, service = openService()
  give(service, "CHIKORITA")
  give(service, "TOTODILE")
  local view = PartyScreenModel.build(service, {
    isEligible = function(slot)
      return slot == 1
    end,
  })
  Assert.isFalse(view.slots[1].eligible)
  Assert.isTrue(view.slots[2].eligible)
  Assert.equal(view.slots[1].displayName, "CHIKORITA", "eligibility never rewrites display values")
end

function T.facts_carry_egg_held_capsule_move_and_leaf_records()
  local catalog, service = openService()
  give(service, "CHIKORITA")
  store(service, 0, function(mon)
    mon.isEgg = true
    mon.heldItem = "SITRUS_BERRY"
    mon.capsule = { id = 3, seals = {} }
    mon.moves = { { move = "CUT", pp = 30, ppUps = 0 }, { move = "TACKLE", pp = 35, ppUps = 1 } }
    mon.shinyLeaves = 21
  end)
  local view = PartyScreenModel.build(service)
  local lead = view.slots[1]
  Assert.isTrue(lead.isEgg, "egg state projects for presentation policy")
  Assert.equal(lead.heldItem, "SITRUS_BERRY", "the held semantic key projects, never a source id")
  Assert.equal(lead.heldItemName, catalog:item("SITRUS_BERRY").name, "detail presentation uses the catalog display name")
  Assert.equal(lead.heldMarkerKind, "item", "ordinary held items project the ordinary marker kind")
  Assert.deepEqual(lead.capsule, { id = 3, seals = {} }, "the capsule record projects for its indicator")
  Assert.deepEqual(
    lead.moves,
    { { key = "CUT", pp = 30, ppUps = 0 }, { key = "TACKLE", pp = 35, ppUps = 1 } },
    "learned moves project in move-slot order with semantic keys"
  )
  Assert.equal(lead.shinyLeaves, 21, "the six-bit leaf mask projects for badge display")
end

function T.mail_pocket_projects_the_mail_marker_kind()
  local _, service = openService()
  give(service, "CHIKORITA")
  local grassMail = "ITEM_137"

  local sourceCatalog = service:catalog()
  local mailCatalog = {
    species = function(_, key)
      return sourceCatalog:species(key)
    end,
    iconSelection = function(_, mon)
      return sourceCatalog:iconSelection(mon)
    end,
    item = function(_, key)
      local definition = sourceCatalog:item(key)
      if key == grassMail then
        return { name = definition.name, pocket = "mail" }
      end
      return definition
    end,
  }
  local mailService = {
    partyCount = function()
      return service:partyCount()
    end,
    partyRevision = function()
      return service:partyRevision()
    end,
    partyMon = function(_, slot)
      local mon = service:partyMon(slot)
      if slot == 0 then
        mon.heldItem = grassMail
      end
      return mon
    end,
    partyMonDerived = function(_, slot)
      return service:partyMonDerived(slot)
    end,
    catalog = function()
      return mailCatalog
    end,
  }

  local lead = PartyScreenModel.build(mailService).slots[1]
  Assert.equal(lead.heldItem, grassMail, "mail classification preserves the semantic item key")
  Assert.equal(lead.heldItemName, sourceCatalog:item(grassMail).name)
  Assert.equal(lead.heldMarkerKind, "mail", "the catalog pocket determines the mail marker")
end

function T.unset_facts_default_to_empty_values()
  local catalog, service = openService()
  give(service, "CHIKORITA")
  local view = PartyScreenModel.build(service)
  local lead = view.slots[1]
  Assert.isFalse(lead.isEgg)
  Assert.equal(lead.heldItem, "NONE")
  Assert.equal(lead.heldItemName, catalog:item("NONE").name, "itemless mons carry the catalog display name")
  Assert.isNil(lead.heldMarkerKind, "mons without an item carry no marker kind")
  Assert.isNil(lead.capsule, "mons without capsules carry no capsule record")
  Assert.isTrue(#lead.moves >= 0, "moves project as an array")
  for _, move in ipairs(lead.moves) do
    Assert.isTrue(type(move.key) == "string", "projected moves carry semantic keys")
  end
  Assert.equal(lead.shinyLeaves, 0)
end

return { tests = T }
