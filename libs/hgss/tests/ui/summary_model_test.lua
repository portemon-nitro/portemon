-- Core summary facts and six-bit leaf visibility over the live mon
-- service. Every value is read from current domain/catalog data; the
-- projection never mutates the stored record.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Experience = require("libs.mons.src.gen4.Experience")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Personality = require("libs.mons.src.gen4.Personality")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")

local T = {}

local function openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
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

local function gift(service, species, level)
  local added = service:giveMon({
    species = species,
    level = level or 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "setup gift must enter the party")
end

-- Publishes one edited mon copy through the owned preparation path, so
-- the stored record stays valid and the revision advances exactly once.
local function setMon(service, slot, edit)
  local revision = service:partyRevision()
  local copy = service:partyMon(slot)
  edit(copy)
  local preparation, reason = service:preparePartyChanges(revision, { { slot = slot, mon = copy } })
  Assert.isNil(reason, "setup edit must prepare cleanly")
  Assert.notNil(preparation, "setup edit must produce a preparation")
  Assert.isTrue(preparation.isCurrent(), "setup edit must stay current")
  preparation.publish()
end

local function leafBits(leaves)
  local bits = {}
  for index = 1, 5 do
    bits[index] = leaves[index] == true
  end
  return bits
end

function T.leaf_visibility_covers_all_64_masks_with_explicit_crown()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x11111111)
  gift(service, "CHIKORITA")
  for mask = 0, 63 do
    setMon(service, 0, function(mon)
      mon.shinyLeaves = mask
    end)
    local facts = SummaryModel.build(service, 0)
    local crown = mask >= 32
    Assert.equal(facts.leaves.crown, crown, "mask " .. mask .. " crowns explicitly")
    for index = 0, 4 do
      local bit = math.floor(mask / (2 ^ index)) % 2 == 1
      Assert.equal(
        facts.leaves.leaves[index + 1],
        (not crown) and bit,
        "mask " .. mask .. " leaf " .. (index + 1) .. " stays independent"
      )
    end
  end
  setMon(service, 0, function(mon)
    mon.shinyLeaves = 31
  end)
  local leaves31 = leafBits(SummaryModel.build(service, 0).leaves.leaves)
  Assert.deepEqual(leaves31, { true, true, true, true, true }, "mask 31 shows five leaves, never a crown")
end

function T.mask_32_crowns_with_no_lower_bits_and_mask_0_shows_nothing()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x22222222)
  gift(service, "TOTODILE")
  setMon(service, 0, function(mon)
    mon.shinyLeaves = 32
  end)
  local crowned = SummaryModel.build(service, 0)
  Assert.isTrue(crowned.leaves.crown, "mask 32 crowns with no lower bits")
  Assert.deepEqual(
    leafBits(crowned.leaves.leaves),
    { false, false, false, false, false },
    "the crown suppresses every leaf visual"
  )
  setMon(service, 0, function(mon)
    mon.shinyLeaves = 0
  end)
  local bare = SummaryModel.build(service, 0)
  Assert.isFalse(bare.leaves.crown, "mask 0 crowns nothing")
  Assert.deepEqual(leafBits(bare.leaves.leaves), { false, false, false, false, false }, "mask 0 displays no badges")
end

function T.viewing_never_mutates_stored_masks_or_revisions()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x33333333)
  gift(service, "CHIKORITA")
  setMon(service, 0, function(mon)
    mon.shinyLeaves = 47
  end)
  local before = service:partyRevision()
  SummaryModel.build(service, 0)
  SummaryModel.build(service, 0)
  Assert.equal(service:partyRevision(), before, "viewing advances no revision")
  Assert.equal(service:partyMon(0).shinyLeaves, 47, "viewing preserves the stored mask")
end

function T.overview_carries_real_domain_and_catalog_facts()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x44444444)
  gift(service, "CHIKORITA", 5)
  setMon(service, 0, function(mon)
    mon.nickname = "LEAFY"
  end)
  local mon = service:partyMon(0)
  local derived = service:derive(mon)
  local facts = SummaryModel.build(service, 0)
  Assert.isFalse(facts.isEgg, "a gifted mon is not an egg")
  Assert.equal(facts.displayName, "LEAFY", "the nickname leads the header")
  Assert.equal(facts.speciesName, "CHIKORITA", "the species name stays available")
  Assert.equal(facts.level, derived.level, "the level comes from derivation")
  local species = catalog:species("CHIKORITA")
  Assert.equal(
    facts.gender,
    Personality.gender(species.genderRatio, mon.personality),
    "gender follows the personality ratio"
  )
  Assert.equal(
    facts.shiny,
    Personality.shiny(mon.origin.trainerId, mon.personality),
    "shininess follows the trainer/personality check"
  )
  Assert.deepEqual(facts.types, { "grass" }, "CHIKORITA carries its single catalog type")
  Assert.equal(facts.otName, "RED", "the original-trainer name is observed")
  Assert.equal(facts.otVisibleId, mon.origin.trainerId % 65536, "the visible ID is the public trainer identity")
  Assert.equal(facts.nature, Personality.nature(mon.personality), "nature follows personality")
  local ability = catalog:ability(mon.ability)
  Assert.equal(facts.abilityName, ability.name, "the ability name is observed")
  Assert.equal(facts.abilityDescription, ability.description, "the description explains the ability")
  Assert.equal(facts.heldItem, "NONE", "no held item is observed")
  Assert.isNil(facts.heldItemName, "no held item carries no name")
  Assert.equal(facts.status, "ok", "a fresh mon carries no status")
  Assert.equal(facts.currentHp, derived.maxHp, "a fresh mon is at full health")
  Assert.equal(facts.maxHp, derived.maxHp, "max HP comes from derivation")
  Assert.equal(facts.stats.attack, derived.attack, "battle stats come from derivation")
  Assert.equal(facts.experience, mon.experience, "experience is observed")
  Assert.notNil(facts.expToNext, "level 5 leaves progress to the next level")
  local curve = catalog:growthCurve(species.growthCurve)
  Assert.equal(
    facts.expToNext,
    Experience.expFor(curve, derived.level + 1) - mon.experience,
    "progress counts down to the next level"
  )
  Assert.isTrue(#facts.moves >= 1, "learned moves are observed")
end

function T.move_entries_carry_max_pp_and_raw_zero_power()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x55555555)
  gift(service, "CHIKORITA", 5)
  service:setMove(0, 1, "RAZOR_LEAF")
  service:setMove(0, 0, "GROWL")
  local facts = SummaryModel.build(service, 0)
  local growl = facts.moves[1]
  Assert.equal(growl.key, "GROWL", "move order follows the stored slots")
  Assert.equal(growl.power, 0, "zero power is carried raw, never invented")
  Assert.equal(growl.pp, growl.maxPp, "a fresh move starts at full power points")
  local razor = facts.moves[2]
  Assert.equal(razor.maxPp, 25, "max power points follow the catalog base value")
  local copy = service:partyMon(0)
  copy.moves[2].ppUps = 3
  copy.moves[2].pp = 1
  local preparation = assert(service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = copy } }))
  preparation.publish()
  local boosted = SummaryModel.build(service, 0)
  Assert.equal(boosted.moves[2].pp, 1, "current power points stay with the entry")
  Assert.equal(boosted.moves[2].maxPp, 25 + math.floor(25 * 3 / 5), "power-point ups widen the maximum")
end

function T.egg_view_suppresses_battle_detail_and_shows_met_facts()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x66666666)
  gift(service, "TOTODILE", 5)
  setMon(service, 0, function(mon)
    mon.isEgg = true
    mon.moves = {}
  end)
  local facts = SummaryModel.build(service, 0)
  Assert.isTrue(facts.isEgg, "the egg flag is observed")
  Assert.isNil(facts.stats, "eggs carry no battle stats")
  Assert.isNil(facts.expToNext, "eggs carry no experience progress")
  Assert.deepEqual(facts.moves, {}, "eggs carry no move detail")
  Assert.equal(facts.egg.location, 0, "the egg location is observed")
  Assert.equal(facts.egg.metLocation, 7, "the met location is observed")
  Assert.equal(facts.egg.metLevel, 5, "the met level is observed")
end

function T.wrap_estimate_splits_words_without_silent_loss()
  local lines = SummaryModel.wrapLines("Cuts with sharp leaves.", 10)
  Assert.deepEqual(lines, { "Cuts with", "sharp", "leaves." }, "words wrap without loss")
  local long = SummaryModel.wrapLines("Raises defense.", 30)
  Assert.deepEqual(long, { "Raises defense." }, "fitting text stays whole")
end

return { tests = T }
