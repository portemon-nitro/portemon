-- Wild-encounter selection and generation vectors: the opportunity check,
-- ordered slot ladders for every method, level windows, catalog table
-- resolution with swarm/radio/night replacements and special contexts, and
-- wild identity construction with lead-ability coercion and held items.
-- Rolls and expected outcomes are fixed here from the native branches
-- (per-method interval ladders, replacement targets, and the fixed-draw
-- mon identity order); they are never produced by the modules under test.
-- The final case integrates the real compiled encounter catalog as
-- native-source evidence and runs wherever a source ROM is registered.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("libs.hgss.tests.encounter_fixture")
local Personality = require("libs.mons.src.gen4.Personality")

local T = {}

local CATALOG_MODULE = "libs.hgss.src.encounters.HgssEncounterCatalog"
local SELECTION_MODULE = "libs.hgss.src.encounters.EncounterSelection"
local WILD_MODULE = "libs.hgss.src.encounters.WildMonFactory"

local function selection()
  return Fixture.requirePresent(SELECTION_MODULE, "native table, rate, and level selection owns trigger order")
end

local function wildFactory(catalogs)
  local WildMonFactory = Fixture.requirePresent(WILD_MODULE, "source wild identity and held-item generation")
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  return WildMonFactory.new({
    catalog = catalogs.catalog,
    items = catalogs.items,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    game = "soulsilver",
    language = "english",
  })
end

local function standardFactory()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local ItemFixture = require("libs.items.tests.item_fixture")
  return wildFactory({ catalog = CatalogFixture.makeCatalog(), items = ItemFixture.makeCatalog() })
end

local function wildOptions(overrides)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local options = {
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return options
end

local function rejectionCode(fn, expected)
  local err = Assert.throws(fn, "the invalid selection must fail")
  Assert.isTrue(Errors.is(err), "rejection uses the structured error path")
  Assert.equal(assert(err).code, expected, "rejection names its contract")
  return assert(err)
end

function T.trigger_compares_the_roll_against_the_method_rate()
  local Selection = selection()
  for _, roll in ipairs({ 0, 50, 99 }) do
    Assert.isFalse(Selection.trigger(0, roll), "a zero rate never opens an encounter")
  end
  for _, roll in ipairs({ 0, 50, 99 }) do
    Assert.isTrue(Selection.trigger(100, roll), "a full rate always opens an encounter")
  end
  Assert.isTrue(Selection.trigger(30, 29), "rolls below the rate trigger")
  Assert.isFalse(Selection.trigger(30, 30), "rolls at the rate boundary do not trigger")
  Assert.isTrue(Selection.trigger(255, 99), "rates above the roll range always trigger")
  rejectionCode(function()
    Selection.trigger(256, 0)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.trigger(20, 100)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.trigger(20, -1)
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.slot_selection_walks_the_ordered_land_intervals()
  local Selection = selection()
  local day = Fixture.vectorCatalog().tables[11].land.day
  -- Land ladder widths in order: 20,20,10,10,10,10,5,5,4,4,1,1.
  local cases = {
    { 0, 1 },
    { 19, 1 },
    { 20, 2 },
    { 39, 2 },
    { 40, 3 },
    { 49, 3 },
    { 50, 4 },
    { 59, 4 },
    { 60, 5 },
    { 69, 5 },
    { 70, 6 },
    { 74, 6 },
    { 79, 6 },
    { 80, 7 },
    { 84, 7 },
    { 85, 8 },
    { 89, 8 },
    { 90, 9 },
    { 93, 9 },
    { 94, 10 },
    { 97, 10 },
    { 98, 11 },
    { 99, 12 },
  }
  for _, case in ipairs(cases) do
    Assert.equal(Selection.selectSlot(day, case[1]), case[2], "land roll " .. case[1] .. " selects slot " .. case[2])
  end
  Assert.equal(day[Selection.selectSlot(day, 0)].species, "CHIKORITA")
  Assert.equal(day[Selection.selectSlot(day, 20)].species, "CHIKORITA")
  Assert.isTrue(Selection.selectSlot(day, 0) ~= Selection.selectSlot(day, 20), "duplicate species keep distinct slots")
  rejectionCode(function()
    Selection.selectSlot(day, 100)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.selectSlot(day, -1)
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.slot_selection_covers_every_method_ladder()
  local Selection = selection()
  local tables = Fixture.vectorCatalog().tables[11]
  local surfCases = { { 0, 1 }, { 59, 1 }, { 60, 2 }, { 89, 2 }, { 90, 3 }, { 94, 3 }, { 95, 4 }, { 98, 4 }, { 99, 5 } }
  for _, case in ipairs(surfCases) do
    Assert.equal(Selection.selectSlot(tables.surf, case[1]), case[2], "surf roll " .. case[1])
  end
  Assert.equal(Selection.selectSlot(tables.rockSmash, 0), 1)
  Assert.equal(Selection.selectSlot(tables.rockSmash, 79), 1)
  Assert.equal(Selection.selectSlot(tables.rockSmash, 80), 2)
  Assert.equal(Selection.selectSlot(tables.rockSmash, 99), 2)
  local rodCases = { { 0, 1 }, { 39, 1 }, { 40, 2 }, { 69, 2 }, { 70, 3 }, { 84, 3 }, { 85, 4 }, { 94, 4 }, { 95, 5 } }
  for _, case in ipairs(rodCases) do
    Assert.equal(Selection.selectSlot(tables.oldRod, case[1]), case[2], "rod roll " .. case[1])
  end
  local headbutt = {
    { species = "CHIKORITA", form = 0, minLevel = 4, maxLevel = 4, weight = 50 },
    { species = "TOTODILE", form = 0, minLevel = 5, maxLevel = 5, weight = 15 },
    { species = "EEVEE", form = 0, minLevel = 6, maxLevel = 6, weight = 15 },
    { species = "SHEDINJA", form = 0, minLevel = 7, maxLevel = 7, weight = 10 },
    { species = "CHIKORITA", form = 0, minLevel = 8, maxLevel = 8, weight = 5 },
    { species = "TOTODILE", form = 0, minLevel = 9, maxLevel = 9, weight = 5 },
  }
  local headbuttCases = {
    { 0, 1 },
    { 49, 1 },
    { 50, 2 },
    { 64, 2 },
    { 65, 3 },
    { 79, 3 },
    { 80, 4 },
    { 89, 4 },
    { 90, 5 },
    { 94, 5 },
    { 95, 6 },
    { 99, 6 },
  }
  for _, case in ipairs(headbuttCases) do
    Assert.equal(Selection.selectSlot(headbutt, case[1]), case[2], "headbutt roll " .. case[1])
  end
end

function T.type_coercion_collects_only_matching_slots()
  local Selection = selection()
  -- The native slot-coercion scan reads each slot's base types and
  -- keeps the ordered matching indices; the provider answers the
  -- lower-case mon-catalog type keys per species and form.
  local slots = {
    { species = "CHIKORITA", form = 0, minLevel = 4, maxLevel = 4, weight = 20 },
    { species = "MAGNEMITE", form = 0, minLevel = 5, maxLevel = 5, weight = 20 },
    { species = "EEVEE", form = 0, minLevel = 6, maxLevel = 6, weight = 10 },
    { species = "MAGNETON", form = 0, minLevel = 7, maxLevel = 7, weight = 10 },
  }
  local function typeOf(species, form)
    assert(form == 0, "coercion reads the base form")
    if species == "MAGNEMITE" or species == "MAGNETON" then
      return { "electric", "steel" }
    end
    if species == "CHIKORITA" then
      return { "grass" }
    end
    return { "normal" }
  end
  Assert.deepEqual(Selection.matchingTypeSlots(slots, "steel", typeOf), { 2, 4 })
  Assert.deepEqual(
    Selection.matchingTypeSlots(slots, "electric", typeOf),
    { 2, 4 },
    "either base type matches"
  )
  Assert.deepEqual(Selection.matchingTypeSlots(slots, "grass", typeOf), { 1 })
  Assert.isNil(
    Selection.matchingTypeSlots(slots, "fire", typeOf),
    "no matching slot falls through to the normal roll"
  )
  local uniform = {
    { species = "MAGNEMITE", form = 0, minLevel = 5, maxLevel = 5, weight = 50 },
    { species = "MAGNETON", form = 0, minLevel = 7, maxLevel = 7, weight = 50 },
  }
  Assert.isNil(
    Selection.matchingTypeSlots(uniform, "steel", typeOf),
    "every slot matching falls through without a pick draw"
  )
  -- An unreadable slot (an inert NONE entry with no catalog record)
  -- reads as no match, matching the native scan that never faults.
  local function flaky(species, form)
    assert(form == 0, "coercion reads the base form")
    if species == "NONE" then
      error("unknown species NONE", 0)
    end
    return typeOf(species, form)
  end
  local inert = {
    { species = "NONE", form = 0, minLevel = 0, maxLevel = 0, weight = 20 },
    { species = "MAGNEMITE", form = 0, minLevel = 5, maxLevel = 5, weight = 20 },
  }
  Assert.deepEqual(Selection.matchingTypeSlots(inert, "steel", flaky), { 2 })
  rejectionCode(function()
    Selection.matchingTypeSlots({}, "steel", typeOf)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.matchingTypeSlots(slots, "", typeOf)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.matchingTypeSlots(slots, "steel", nil)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.matchingTypeSlots({ { form = 0, minLevel = 4, maxLevel = 4, weight = 20 } }, "steel", typeOf)
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.level_selection_stays_inside_the_source_window()
  local Selection = selection()
  local fixed = { species = "EEVEE", form = 0, minLevel = 8, maxLevel = 8, weight = 10 }
  Assert.equal(Selection.selectLevel(fixed, 0), 8)
  Assert.equal(Selection.selectLevel(fixed, 21105), 8, "fixed land levels ignore the roll")
  local window = { species = "CHIKORITA", form = 0, minLevel = 5, maxLevel = 9, weight = 15 }
  Assert.equal(Selection.selectLevel(window, 0), 5)
  Assert.equal(Selection.selectLevel(window, 4), 9)
  Assert.equal(Selection.selectLevel(window, 5), 5, "windows wrap on their span")
  Assert.equal(Selection.selectLevel(window, 21105), 5, "21105 mod 5 is 0")
  local inverted = { species = "EEVEE", form = 0, minLevel = 9, maxLevel = 5, weight = 10 }
  rejectionCode(function()
    Selection.selectLevel(inverted, 0)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.selectLevel(window, -1)
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.land_level_reads_the_fixed_slot_maximum_without_a_roll()
  local Selection = selection()
  -- Native land tables carry one level per slot: generation reads the
  -- slot maximum with no level roll, so selection takes no roll at all.
  local fixed = { species = "EEVEE", form = 0, minLevel = 8, maxLevel = 8, weight = 10 }
  Assert.equal(Selection.selectLandLevel(fixed), 8)
  local native = { species = "CHIKORITA", form = 0, minLevel = 4, maxLevel = 4, weight = 20 }
  Assert.equal(Selection.selectLandLevel(native), 4)
  rejectionCode(function()
    Selection.selectLandLevel({ species = "EEVEE", minLevel = 8, maxLevel = 300, weight = 10 })
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.selectLandLevel({ species = "EEVEE", minLevel = 8, weight = 10 })
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.slot_level_reselects_the_highest_matching_slot()
  local Selection = selection()
  local day = Fixture.vectorCatalog().tables[11].land.day
  -- The third land slot (TOTODILE 5) yields to the ninth (TOTODILE 11),
  -- past the fourth (TOTODILE 6); the first (CHIKORITA 4) yields to the
  -- twelfth (CHIKORITA 14).
  Assert.equal(Selection.highestSameSpeciesSlot(day, 3), 9)
  Assert.equal(Selection.highestSameSpeciesSlot(day, 4), 9, "a lower sibling yields to the highest")
  Assert.equal(Selection.highestSameSpeciesSlot(day, 9), 9, "the highest slot keeps itself")
  Assert.equal(Selection.highestSameSpeciesSlot(day, 1), 12, "a lower slot yields across twins")
  Assert.equal(Selection.highestSameSpeciesSlot(day, 11), 11, "a unique species keeps itself")
  Assert.equal(Selection.highestSameSpeciesSlot(day, 5), 10, "the fifth land slot yields to the tenth")
  rejectionCode(function()
    Selection.highestSameSpeciesSlot(day, 0)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.highestSameSpeciesSlot(day, 13)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.highestSameSpeciesSlot({}, 1)
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.method_resolution_selects_slots_and_rates()
  local Selection = selection()
  local member = Fixture.vectorCatalog().tables[11]
  local grass = Selection.selectTable(member, "grass", { timeOfDay = "day" })
  Assert.equal(grass.rate, 100)
  Assert.equal(#grass.slots, 12)
  Assert.equal(grass.slots[6].species, "EEVEE")
  local night = Selection.selectTable(member, "grass", { timeOfDay = "night" })
  Assert.equal(#night.slots, 12, "every time of day resolves its own ordered slots")
  local surf = Selection.selectTable(member, "surf", {})
  Assert.equal(surf.rate, 0)
  Assert.equal(#surf.slots, 5)
  local fished = Selection.selectTable(Fixture.vectorCatalog().tables[14], "fish", { rod = "old_rod" })
  Assert.equal(fished.rate, 100)
  Assert.equal(#fished.slots, 5)
  local smashed = Selection.selectTable(member, "rock_smash", {})
  Assert.equal(#smashed.slots, 2)
  rejectionCode(function()
    Selection.selectTable(member, "fish", {})
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    Selection.selectTable(member, "headbutt", {})
  end, "ENCOUNTER_MISSING_TABLE")
  rejectionCode(function()
    Selection.selectTable(member, "safari", {})
  end, "ENCOUNTER_MISSING_TABLE")
  rejectionCode(function()
    Selection.selectTable(member, "warp", {})
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.table_resolution_applies_replacements_at_lookup()
  local Catalog = Fixture.requirePresent(CATALOG_MODULE, "validated encounter-table lookup owns ordered slots")
  local catalog = Catalog.new(Fixture.vectorCatalog())
  local plain = catalog:tableFor(11, { timeOfDay = "day", swarm = false, radio = "none", game = "soulsilver" })
  Assert.equal(plain.day[1].species, "CHIKORITA")
  Assert.equal(plain.day[3].species, "TOTODILE")
  local swarmed = catalog:tableFor(11, { timeOfDay = "day", swarm = true, radio = "none", game = "soulsilver" })
  Assert.equal(swarmed.day[1].species, "EEVEE", "the land swarm replaces the first two slots")
  Assert.equal(swarmed.day[2].species, "EEVEE")
  Assert.equal(swarmed.day[3].species, "TOTODILE", "slots outside the swarm stay untouched")
  local hoenn = catalog:tableFor(11, { timeOfDay = "day", swarm = false, radio = "hoenn", game = "soulsilver" })
  Assert.equal(hoenn.day[3].species, "SHEDINJA", "hoenn music replaces the third and fourth slots")
  Assert.equal(hoenn.day[4].species, "SHEDINJA")
  -- Native radio music replaces two pairs: the first species covers the
  -- third and fourth slots while the second covers the fifth and sixth,
  -- with levels and weights staying on the slots.
  Assert.equal(hoenn.day[5].species, "TOTODILE", "hoenn music replaces the fifth and sixth slots")
  Assert.equal(hoenn.day[6].species, "TOTODILE")
  local sinnoh = catalog:tableFor(11, { timeOfDay = "day", swarm = false, radio = "sinnoh", game = "soulsilver" })
  Assert.equal(sinnoh.day[3].species, "EEVEE", "sinnoh music replaces the same music slots")
  Assert.equal(sinnoh.day[4].species, "EEVEE")
  Assert.equal(sinnoh.day[5].species, "CHIKORITA", "sinnoh music replaces the fifth and sixth slots")
  Assert.equal(sinnoh.day[6].species, "CHIKORITA")
  Assert.equal(#plain.day, 12, "lookup preserves the twelve ordered slots")
  local fished = catalog:tableFor(14, { timeOfDay = "day", rod = "good_rod", game = "soulsilver" })
  Assert.equal(fished.goodRod[4].species, "EEVEE", "night fishing replaces the good-rod slot")
  Assert.equal(plain.goodRod[4].species, "CHIKORITA")
  local fishSwarmed = catalog:tableFor(14, { timeOfDay = "day", swarm = true, rod = "old_rod", game = "soulsilver" })
  Assert.equal(fishSwarmed.oldRod[3].species, "SHEDINJA", "the fishing swarm replaces the old-rod slot")
  local surfSwarmed = catalog:tableFor(11, { timeOfDay = "day", swarm = true, game = "soulsilver" })
  Assert.equal(surfSwarmed.surf[1].species, "TOTODILE", "the surf swarm replaces the first surf slot")
  rejectionCode(function()
    catalog:tableFor(999, { timeOfDay = "day", game = "soulsilver" })
  end, "ENCOUNTER_MISSING_TABLE")
  rejectionCode(function()
    catalog:tableFor(11, { timeOfDay = "dawn", game = "soulsilver" })
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    catalog:tableFor(11, { timeOfDay = "day", radio = "unova", game = "soulsilver" })
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.table_resolution_keeps_inactive_and_foreign_replacements()
  local Catalog = Fixture.requirePresent(CATALOG_MODULE, "validated encounter-table lookup owns ordered slots")
  local compiled = Fixture.vectorCatalog()
  compiled.tables[11].replacements.landSwarm.species = "NONE"
  local catalog = Catalog.new(compiled)
  local quiet = catalog:tableFor(11, { timeOfDay = "day", swarm = true, radio = "none", game = "soulsilver" })
  Assert.equal(quiet.day[1].species, "CHIKORITA", "an absent swarm reads as its inactive state")
  local foreign = catalog:tableFor(11, { timeOfDay = "day", swarm = true, radio = "none", game = "heartgold" })
  Assert.equal(foreign.day[1].species, "CHIKORITA", "foreign-game replacements never apply")
end

function T.table_resolution_exposes_special_contexts_without_inventing_slots()
  local Catalog = Fixture.requirePresent(CATALOG_MODULE, "validated encounter-table lookup owns ordered slots")
  local catalog = Catalog.new(Fixture.vectorCatalog())
  Assert.equal(catalog:specialTable(11, "safari").context, "safari")
  Assert.equal(catalog:specialTable(11, "bug_contest").context, "bug_contest")
  rejectionCode(function()
    catalog:specialTable(11, "frontier")
  end, "ENCOUNTER_MISSING_TABLE")
  rejectionCode(function()
    catalog:specialTable(999, "safari")
  end, "ENCOUNTER_MISSING_TABLE")
end

function T.wild_creation_follows_the_four_draw_identity_order()
  local factory = standardFactory()
  local stream = Fixture.spyStream(0)
  -- Seed 0 draws: personality 0/59774, ivs 21105/12720, then the single
  -- held-item roll 36418. Natively the held item is one percent roll
  -- against the 45/95 odds table, not two uniform draws.
  local mon = factory:create("CHIKORITA", 5, stream, wildOptions())
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.met.level, 5)
  Assert.equal(mon.personality, 3917348864)
  Assert.deepEqual(mon.ivs, { hp = 17, attack = 19, defense = 20, speed = 16, specialAttack = 13, specialDefense = 12 })
  Assert.equal(mon.ability, "OVERGROW", "single-ability species keep their only slot")
  Assert.equal(Personality.gender(31, mon.personality), "female", "gender follows the low personality byte")
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 5, "identity takes four draws plus the single held-item roll")
  Assert.deepEqual(
    stream:labels(),
    { "personality_low", "personality_high", "iv_first", "iv_second", "held_item" }
  )
  for _, cause in ipairs(stream:causes()) do
    Assert.isTrue(type(cause) == "table" and cause.kind == "encounter", "every draw carries its semantic cause")
  end
  local before = stream:calls()
  rejectionCode(function()
    factory:create("BOGUS_SPECIES", 5, stream, wildOptions())
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stream:calls(), before, "unknown species consume no draws")
  rejectionCode(function()
    factory:create("CHIKORITA", 0, stream, wildOptions())
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stream:calls(), before, "out-of-range levels consume no draws")
end

function T.wild_creation_assigns_held_items_from_the_species_entries()
  local catalogs = Fixture.berryCatalogs()
  local factory = wildFactory(catalogs)
  -- Seed 2 draws: personality 33676/28355, ivs 21356/3517, held roll
  -- 88, inside the common window below ninety-five.
  local common = factory:create("EEVEE", 8, Fixture.spyStream(2), wildOptions())
  Assert.equal(common.personality, 1858306956)
  Assert.deepEqual(common.ivs, { hp = 12, attack = 27, defense = 20, speed = 29, specialAttack = 13, specialDefense = 3 })
  Assert.equal(common.ability, "RUN_AWAY")
  Assert.equal(common.heldItem, "SITRUS_BERRY", "a common-window roll keeps the common entry")
  -- Seed 20 draws: personality 9086/7730, ivs 23619/51762, held roll
  -- 95, at the rare threshold.
  local rareStream = Fixture.spyStream(20)
  local rare = factory:create("EEVEE", 8, rareStream, wildOptions())
  Assert.equal(rare.personality, 506602366)
  Assert.deepEqual(rare.ivs, { hp = 3, attack = 2, defense = 23, speed = 18, specialAttack = 17, specialDefense = 18 })
  Assert.equal(rare.heldItem, "CHERI_BERRY", "a rare-window roll keeps the rare entry")
  Assert.equal(rareStream:calls(), 5)
  Assert.equal(rareStream:labels()[5], "held_item", "the held item is a single percent roll")
  local plainStream = Fixture.spyStream(0)
  local plain = standardFactory():create("EEVEE", 8, plainStream, wildOptions())
  Assert.equal(plain.heldItem, "NONE", "a roll below forty-five holds nothing")
  Assert.equal(plainStream:calls(), 5, "the held-item trace stays uniform")
end

function T.wild_creation_compound_eyes_widens_the_held_windows()
  local catalogs = Fixture.berryCatalogs()
  local factory = wildFactory(catalogs)
  local eyed = { leadAbility = "compoundeyes" }
  -- Seed 5 draws: personality 18655/46763, ivs 54501/55249, held roll
  -- 44, below the plain forty-five but inside the widened twenty.
  local plain = factory:create("EEVEE", 8, Fixture.spyStream(5), wildOptions())
  Assert.equal(plain.personality, 3064678623)
  Assert.deepEqual(plain.ivs, { hp = 5, attack = 7, defense = 21, speed = 17, specialAttack = 30, specialDefense = 21 })
  Assert.equal(plain.heldItem, "NONE", "a narrow roll holds nothing without compound eyes")
  local widened = factory:create("EEVEE", 8, Fixture.spyStream(5), wildOptions(eyed))
  Assert.equal(widened.personality, 3064678623, "the widened odds replay the same identity")
  Assert.deepEqual(widened.ivs, plain.ivs)
  Assert.equal(widened.heldItem, "SITRUS_BERRY", "compound eyes keeps the common entry from twenty")
  -- Seed 11 draws: personality 54149/18043, ivs 55256/27640, held roll
  -- 92, common without eyes but rare once eighty opens the rare window.
  local common = factory:create("EEVEE", 8, Fixture.spyStream(11), wildOptions())
  Assert.equal(common.personality, 1182520197)
  Assert.deepEqual(common.ivs, { hp = 24, attack = 30, defense = 21, speed = 24, specialAttack = 31, specialDefense = 26 })
  Assert.equal(common.heldItem, "SITRUS_BERRY")
  local rare = factory:create("EEVEE", 8, Fixture.spyStream(11), wildOptions(eyed))
  Assert.equal(rare.personality, 1182520197, "the rare window replays the same identity")
  Assert.equal(rare.heldItem, "CHERI_BERRY", "compound eyes keeps the rare entry from eighty")
  local stray = Fixture.spyStream(5)
  local before = stray:calls()
  rejectionCode(function()
    factory:create("EEVEE", 8, stray, wildOptions({ leadAbility = "compoundeyes", leadNature = 4 }))
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray:calls(), before, "mismatched lead facts consume no draws")
end

function T.wild_creation_matching_held_entries_always_hold()
  -- Matching common and rare entries hold unconditionally, still
  -- consuming the single held roll: seed 0 rolls 18, below even the
  -- widened twenty, yet keeps the shared entry.
  local factory = wildFactory(Fixture.berryCatalogs({ rare = { item = "SITRUS_BERRY", nativeId = 158 } }))
  local stream = Fixture.spyStream(0)
  local mon = factory:create("EEVEE", 8, stream, wildOptions())
  Assert.equal(mon.personality, 3917348864)
  Assert.equal(mon.heldItem, "SITRUS_BERRY", "matching entries always hold")
  Assert.equal(stream:calls(), 5, "the unconditional hold still draws once")
end

function T.wild_creation_rejects_unknown_held_entries()
  local factory = wildFactory(Fixture.berryCatalogs({ common = { item = "BOGUS_BERRY", nativeId = 500 } }))
  -- Seed 2 rolls 88, inside the common window, selecting the unknown entry.
  local stream = Fixture.spyStream(2)
  local before = stream:calls()
  rejectionCode(function()
    factory:create("EEVEE", 8, stream, wildOptions())
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stream:calls(), before + 5, "the unknown entry fails after its selection draws")
end

function T.wild_held_item_is_admitted_with_the_final_record_once()
  local catalogs = Fixture.berryCatalogs()
  local factory = wildFactory(catalogs)
  local Mon = require("libs.mons.src.Mon")
  local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
  local originalValidate = Mon.validate
  local originalProject = NativeLegality.project
  local validations = 0
  local projections = 0
  Mon.validate = function(...)
    validations = validations + 1
    return originalValidate(...)
  end
  NativeLegality.project = function(...)
    projections = projections + 1
    return originalProject(...)
  end
  local ok, mon = pcall(function()
    return factory:create("EEVEE", 8, Fixture.spyStream(2), wildOptions())
  end)
  Mon.validate = originalValidate
  NativeLegality.project = originalProject

  Assert.isTrue(ok, "the wild mon remains valid with its selected held item")
  Assert.equal(assert(mon).heldItem, "SITRUS_BERRY")
  Assert.equal(validations, 1, "the final held-item record receives semantic admission once")
  Assert.equal(projections, 1, "the final held-item record receives native projection once")
end

function T.lead_synchronize_coerces_nature_after_its_check_draw()
  local factory = standardFactory()
  local forced =
    factory:create("EEVEE", 8, Fixture.spyStream(0), wildOptions({ leadAbility = "synchronize", leadNature = 4 }))
  Assert.equal(Personality.nature(forced.personality), 4, "an even check draw forces the lead nature")
  local checkStream = Fixture.spyStream(0)
  factory:create("EEVEE", 8, checkStream, wildOptions({ leadAbility = "synchronize", leadNature = 4 }))
  Assert.equal(checkStream:labels()[1], "synchronize", "coercion draws before identity")
  Assert.equal(checkStream:calls(), 6)
  -- Seed 42 opens with an odd check draw, so identity proceeds normally.
  local missedStream = Fixture.spyStream(42)
  local missed = factory:create("EEVEE", 8, missedStream, wildOptions({ leadAbility = "synchronize", leadNature = 4 }))
  Assert.equal(missed.personality, 1729288235)
  Assert.equal(Personality.nature(missed.personality), 10, "a failed check keeps the drawn nature")
  Assert.equal(missedStream:calls(), 6)
  local before = missedStream:calls()
  rejectionCode(function()
    factory:create("EEVEE", 8, missedStream, wildOptions({ leadAbility = "synchronize" }))
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(missedStream:calls(), before, "coercion without a lead nature consumes no draws")
  rejectionCode(function()
    factory:create("EEVEE", 8, missedStream, wildOptions({ leadAbility = "wonder_sense" }))
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(missedStream:calls(), before, "unknown lead abilities consume no draws")
end

function T.static_construction_fixes_species_and_level()
  local factory = standardFactory()
  local stream = Fixture.spyStream(0)
  local mon = factory:createStatic("CHIKORITA", 5, stream, wildOptions())
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.met.level, 5)
  Assert.equal(mon.personality, 3917348864)
  Assert.deepEqual(mon.ivs, { hp = 17, attack = 19, defense = 20, speed = 16, specialAttack = 13, specialDefense = 12 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 5, "scripted construction keeps the uniform trace")
  rejectionCode(function()
    factory:createStatic("CHIKORITA", 5, stream, wildOptions({ leadAbility = "synchronize", leadNature = 1 }))
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.lead_cute_charm_coerces_the_opposite_gender()
  local factory = standardFactory()
  local charmed = { leadAbility = "cute_charm", leadGender = "male" }
  -- Seed 1 opens with a coercing check draw (16838 mod 3 is 2), so the
  -- drawn personality is forced female: low byte cleared on the fourth draw.
  local stream = Fixture.spyStream(1)
  local mon = factory:create("EEVEE", 8, stream, wildOptions(charmed))
  Assert.equal(mon.personality, 3538856960)
  Assert.deepEqual(mon.ivs, { hp = 23, attack = 29, defense = 7, speed = 3, specialAttack = 15, specialDefense = 30 })
  Assert.equal(Personality.gender(31, mon.personality), "female", "coercion forces the opposite gender")
  Assert.equal(stream:calls(), 6, "coercion draws its check before identity")
  Assert.deepEqual(
    stream:labels(),
    { "cute_charm", "personality_low", "personality_high", "iv_first", "iv_second", "held_item" }
  )
  -- Seed 0 opens with a refusal (0 mod 3 is 0): identity proceeds
  -- unforced from the second draw on.
  local plainStream = Fixture.spyStream(0)
  local plain = factory:create("EEVEE", 8, plainStream, wildOptions(charmed))
  Assert.equal(plain.personality, 1383197054, "a refused check shifts identity by one draw")
  Assert.equal(Personality.gender(31, plain.personality), "male")
  Assert.equal(plainStream:calls(), 6)
  -- Genderless species never roll the check: SHEDINJA opens on identity.
  local noneStream = Fixture.spyStream(1)
  local noneMon = factory:create("SHEDINJA", 8, noneStream, wildOptions(charmed))
  Assert.equal(noneStream:labels()[1], "personality_low", "genderless species skip the check")
  Assert.equal(noneStream:calls(), 5)
  Assert.equal(Personality.gender(255, noneMon.personality), "genderless")
  local stray = Fixture.spyStream(0)
  local before = stray:calls()
  rejectionCode(function()
    factory:create("EEVEE", 8, stray, wildOptions({ leadAbility = "cute_charm" }))
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray:calls(), before, "coercion without a lead gender consumes no draws")
  rejectionCode(function()
    factory:create("EEVEE", 8, stray, wildOptions({ leadAbility = "cute_charm", leadGender = "unknown" }))
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray:calls(), before, "coercion with an unknown gender consumes no draws")
  rejectionCode(function()
    factory:create("EEVEE", 8, stray, wildOptions({ leadGender = "male" }))
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray:calls(), before, "a lead gender without cute charm consumes no draws")
end

function T.compiled_catalog_lookup_preserves_native_order(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local ready = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready[#ready + 1] = versionId
    end
  end
  if #ready == 0 then
    if context ~= nil and type(context.skip) == "function" then
      context:skip("requires a registered source ROM")
    end
    error("the native catalog integration needs a registered source ROM", 0)
  end
  local Catalog = Fixture.requirePresent(CATALOG_MODULE, "validated encounter-table lookup owns ordered slots")
  local EncounterCatalogCompiler = require("romdump.src.digest.encounters.EncounterCatalogCompiler")
  local BattleSources = require("romdump.src.config.BattleSources")
  local RomSourcePath = require("tests.rom.support.RomSourcePath")
  for _, versionId in ipairs(ready) do
    local romFs, romSource = assert(RomSourcePath.openReader(versionId))
    local compiled = assert(EncounterCatalogCompiler.compileFromDump(romFs, { versionId = versionId }))
    romFs:close()
    romSource:release()
    local catalog = Catalog.new(compiled)
    local memberId = nil
    for key in pairs(compiled.tables) do
      memberId = key
      break
    end
    Assert.notNil(memberId, versionId .. " must yield at least one encounter table")
    assert(memberId ~= nil, "the dump carries encounter tables")
    local resolved = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "none", game = versionId })
    Assert.equal(#resolved.land.day, 12, versionId .. " member " .. memberId .. " keeps twelve day slots")
    local weights = {}
    for _, entry in ipairs(resolved.land.day) do
      Assert.isTrue(type(entry.species) == "string" and entry.species ~= "", "slots resolve semantic species")
      weights[#weights + 1] = entry.weight
    end
    Assert.deepEqual(weights, BattleSources.slotWeights.land, "lookup preserves the ordered native intervals")
    for name, replacement in pairs(resolved.replacements) do
      Assert.equal(replacement.game, versionId, "replacement " .. name .. " names the supported game")
    end
    Assert.equal(catalog:specialTable(memberId, "safari").context, "safari")
    local probe = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "none", game = versionId })
    probe.land.day[1].species = "MUTATED"
    local fresh = catalog:tableFor(memberId, { timeOfDay = "day", swarm = false, radio = "none", game = versionId })
    Assert.isTrue(fresh.land.day[1].species ~= "MUTATED", "lookup returns detached tables")
  end
end

return { tests = T }
