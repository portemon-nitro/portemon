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
      bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xAAAAAAAA):capture()),
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

-- The party view publishes a presentation-only gender symbol: eggs and
-- genderless mons never carry one, unnicknamed Nidoran suppress theirs
-- while nicknamed Nidoran and ordinary mons use the derived gender.
-- Nidoran species ride a wrapped catalog/service pair because the shared
-- catalog fixture carries no Nidoran entries; the mon records themselves
-- keep the semantic Nidoran species keys the view rule matches on.
local function nidoranView(speciesKey, speciesName, genderRatio, nickname)
  local _, service = openService()
  give(service, "CHIKORITA")
  local baseCatalog = service:catalog()
  local catalog = {
    species = function(_, key)
      if key == speciesKey then
        return { name = speciesName, genderRatio = genderRatio }
      end
      return baseCatalog:species(key)
    end,
    iconSelection = function(_, mon)
      if mon.species == speciesKey then
        return speciesKey .. "/f0"
      end
      return baseCatalog:iconSelection(mon)
    end,
    item = function(_, key)
      return baseCatalog:item(key)
    end,
  }
  local inner = service:partyMon(0)
  local derived = service:partyMonDerived(0)
  local viewService = {
    partyCount = function()
      return 1
    end,
    partyRevision = function()
      return service:partyRevision()
    end,
    partyMon = function()
      local mon = {}
      for key, value in pairs(inner) do
        mon[key] = value
      end
      mon.species = speciesKey
      mon.nickname = nickname
      mon.isEgg = false
      return mon
    end,
    partyMonDerived = function()
      return derived
    end,
    catalog = function()
      return catalog
    end,
  }
  return PartyScreenModel.build(viewService).slots[1]
end

function T.eggs_and_genderless_mons_carry_no_gender_symbol()
  local _, service = openService()
  give(service, "CHIKORITA")
  store(service, 0, function(mon)
    mon.isEgg = true
  end)
  give(service, "SHEDINJA")
  local view = PartyScreenModel.build(service)
  Assert.isNil(view.slots[1].genderSymbol, "eggs print no gender symbol")
  Assert.isNil(view.slots[2].genderSymbol, "genderless mons print no gender symbol")
end

function T.unnicknamed_nidoran_suppress_their_gender_symbol()
  local female = nidoranView("NIDORAN_F", "NIDORAN F", 254, nil)
  Assert.isNil(female.genderSymbol, "the unnicknamed Nidoran female prints no symbol")
  Assert.equal(female.displayName, "NIDORAN F", "suppression keeps the species display name")
  local male = nidoranView("NIDORAN_M", "NIDORAN M", 0, nil)
  Assert.isNil(male.genderSymbol, "the unnicknamed Nidoran male prints no symbol")
  Assert.equal(male.displayName, "NIDORAN M", "suppression keeps the species display name")
end

function T.nicknamed_nidoran_restore_the_ordinary_gender_symbol()
  local female = nidoranView("NIDORAN_F", "NIDORAN F", 254, "QUEEN")
  Assert.equal(female.genderSymbol, "female", "a nickname restores the derived female symbol")
  local male = nidoranView("NIDORAN_M", "NIDORAN M", 0, "KING")
  Assert.equal(male.genderSymbol, "male", "a nickname restores the derived male symbol")
end

function T.ordinary_mons_project_their_derived_gender_symbol()
  local _, service = openService()
  give(service, "CHIKORITA")
  local lead = PartyScreenModel.build(service).slots[1]
  Assert.isTrue(
    lead.genderSymbol == "male" or lead.genderSymbol == "female",
    "ordinary mons print their derived symbol, got " .. tostring(lead.genderSymbol)
  )
  Assert.equal(lead.genderSymbol, lead.gender, "the symbol follows the derived gender")
end

return { tests = T }
