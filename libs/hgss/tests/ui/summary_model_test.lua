-- Core summary facts and six-bit leaf visibility over the live mon
-- service. Every value is read from current domain/catalog data; the
-- projection never mutates the stored record.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCache = require("libs.assets.src.MonCache")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Personality = require("libs.mons.src.gen4.Personality")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")

local T = {}

local function openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
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

-- Native read-only projection over the generated presentation family.
-- Every build below supplies the explicit display context and the
-- synthetic presentation manifest; the projection must return owned
-- snapshot values without touching saves, the catalog, or the RNG.

local SNAPSHOT_KEYS =
  "contextKey,iconKey,identity,indicators,info,isEgg,memo,moves,performance,pictureKey,portraitSelector,revision,ribbons,roster,skills,slot,slotCount"
local MOVE_ROW_KEYS = "accuracyText,category,description,key,kind,moveSlot,name,powerText,pp,ppMax,ppUps,type"
local DISPLAY_ORDER = { "speed", "power", "skill", "stamina", "jump" }
local SOURCE_INDEX = { power = 0, stamina = 1, skill = 2, jump = 3, speed = 4 }
local BOUNDARY_SCORES = {
  -121,
  -120,
  -119,
  -81,
  -80,
  -79,
  -41,
  -40,
  -39,
  -16,
  -15,
  -14,
  -1,
  0,
  14,
  15,
  38,
  39,
  40,
  78,
  79,
  80,
  118,
  119,
  120,
  121,
}

local function buildFacts(service, slot, context, manifest)
  local facts = SummaryModel.build(
    service,
    slot,
    context or SummaryPresentationFixture.context(service:partyCount()),
    manifest or SummaryPresentationFixture.manifest()
  )
  Assert.notNil(facts.identity, "the snapshot carries mon identity")
  Assert.notNil(facts.info, "the snapshot carries native info")
  Assert.notNil(facts.skills, "the snapshot carries native skills")
  Assert.notNil(facts.memo, "the snapshot carries the source memo")
  Assert.notNil(facts.ribbons, "the snapshot carries earned ribbons")
  Assert.notNil(facts.performance, "the snapshot carries performance rows")
  Assert.notNil(facts.roster, "the snapshot carries the navigation roster")
  Assert.notNil(facts.indicators, "the snapshot carries read-only indicators")
  Assert.notNil(facts.contextKey, "the snapshot carries its context signature")
  Assert.notNil(facts.pictureKey, "the snapshot carries its picture selection")
  return facts
end

local function digit(value, position)
  return math.floor(value / (10 ^ position)) % 10
end

-- Source daily modifier: nature row plus twice the pid/day residue,
-- centered by nine. Calculation order is power, stamina, skill, jump,
-- speed; presentation order differs and is asserted separately.
local function dailyScore(modifier, pid, day, sourceIndex)
  local residue = (digit(pid, sourceIndex) + (day + 7 - sourceIndex) * (day + sourceIndex + 3)) % 10
  return modifier + 2 * residue - 9
end

local function starAdjustment(score)
  if score <= -120 then
    return -4
  elseif score <= -80 then
    return -3
  elseif score <= -40 then
    return -2
  elseif score <= -15 then
    return -1
  elseif score <= 14 then
    return 0
  elseif score <= 39 then
    return 1
  elseif score <= 79 then
    return 2
  elseif score <= 119 then
    return 3
  else
    return 4
  end
end

local function clampStars(stars, lo, hi)
  return math.min(hi, math.max(lo, stars))
end

local function expectedRow(manifest, formKey, stat, pid, day, aprijuice)
  local form = manifest.performance.forms[formKey]
  Assert.notNil(form, "the synthetic performance covers " .. formKey)
  local nature = pid % 25
  local modifier = manifest.performance.natureModifiers[nature + 1][stat]
  local score = dailyScore(modifier, pid, day, SOURCE_INDEX[stat]) + aprijuice
  local stars = clampStars(form[stat].base + starAdjustment(score), form[stat].lo, form[stat].hi)
  local tone = "base"
  if stars < form[stat].base then
    tone = "below"
  elseif stars > form[stat].base then
    tone = "above"
  end
  return { stat = stat, base = form[stat].base, min = form[stat].lo, max = form[stat].hi, stars = stars, tone = tone }
end

local function performanceRow(facts, stat)
  for _, row in ipairs(facts.performance) do
    if row.stat == stat then
      return row
    end
  end
  error("performance carries no " .. stat .. " row", 0)
end

local function earnedKeys(facts)
  local keys = {}
  for _, entry in ipairs(facts.ribbons) do
    keys[#keys + 1] = entry.key
  end
  return keys
end

local function ribbonBit(mon, group, bit)
  return math.floor(mon.ribbons[group] / (2 ^ bit)) % 2 == 1
end

function T.native_identity_and_skills_project_through_the_manifest_context()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x10101010)
  gift(service, "CHIKORITA", 5)
  setMon(service, 0, function(mon)
    mon.nickname = "LEAFY"
    mon.personality = 200
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local context = SummaryPresentationFixture.context(1)
  local facts = buildFacts(service, 0, context, manifest)
  Assert.keySet(facts, SNAPSHOT_KEYS, "the snapshot carries exactly the native sections")
  Assert.equal(facts.revision, service:partyRevision(), "the snapshot pins its service revision")
  Assert.equal(facts.slot, 0, "the snapshot pins its slot")
  Assert.equal(facts.slotCount, 1, "the snapshot pins its roster size")
  local rebuilt = buildFacts(service, 0, SummaryPresentationFixture.context(1), manifest)
  Assert.equal(rebuilt.contextKey, facts.contextKey, "equal contexts share one signature")
  Assert.deepEqual(rebuilt, facts, "equal contexts rebuild equal facts")
  Assert.equal(facts.identity.species, "CHIKORITA", "identity keeps the semantic species")
  Assert.equal(facts.identity.nickname, "LEAFY", "identity keeps the nickname apart from species")
  Assert.equal(facts.identity.gender, "male", "identity keeps the derived gender")
  local mon = service:partyMon(0)
  local derived = service:derive(mon)
  Assert.equal(
    facts.info.otIdText,
    string.format("%05d", mon.origin.trainerId % 65536),
    "the visible trainer id keeps five digits"
  )
  Assert.equal(facts.info.dexNumber, 1, "the regional map selects the regional dex number")
  Assert.isTrue(facts.info.dexText:find("1", 1, true) ~= nil, "the dex text shows the selected number")
  local national = buildFacts(service, 0, SummaryPresentationFixture.context(1, { dexMode = "national" }), manifest)
  Assert.equal(national.info.dexNumber, 152, "the national mode selects the national dex number")
  Assert.equal(facts.skills.level, derived.level, "skills keep the derived level")
  Assert.equal(facts.skills.currentHp, derived.maxHp, "a fresh mon is at full health")
  Assert.equal(facts.skills.maxHp, derived.maxHp, "skills keep maximum health")
  Assert.equal(facts.skills.attack, derived.attack, "battle stats come from derivation")
  Assert.equal(facts.skills.abilityName, "Overgrow", "skills name the localized ability")
  Assert.isTrue(#facts.skills.abilityDescription > 0, "skills explain the ability")
  Assert.equal(facts.skills.nature.up, "none", "a neutral nature raises no stat")
  Assert.equal(facts.skills.nature.down, "none", "a neutral nature lowers no stat")
  Assert.equal(facts.skills.hpBar.length, 48, "the health bar spans the source pixel width")
  Assert.equal(facts.skills.hpBar.color, "high", "full health reads the high color")
  Assert.isTrue(facts.info.expBar.length >= 0 and facts.info.expBar.length <= 56, "the exp bar fits its width")
  Assert.isTrue(facts.info.expToNext > 0, "level 5 leaves progress to the next level")
  Assert.equal(facts.pictureKey, "CHIKORITA", "the picture selects the species closure")
  Assert.notNil(manifest.pictures[facts.pictureKey], "the picture selection exists in the family")
  Assert.equal(facts.iconKey, "CHIKORITA/f0", "the roster icon keeps the semantic selector")
  Assert.equal(#facts.roster, 1, "the roster covers the party")
  Assert.equal(facts.roster[1].slot, 0, "roster entries keep domain slots")
  Assert.isFalse(facts.roster[1].isEgg, "roster entries flag eggs")
  Assert.equal(facts.indicators.status, "ok", "a fresh mon carries no status")
  Assert.equal(facts.indicators.pokerus, "none", "a fresh mon carries no pokerus")
  Assert.isFalse(facts.indicators.crown, "no crown without the crown bit")
end

function T.trainer_id_formatting_uses_five_digits_while_ownership_uses_the_full_id()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x20202020)
  gift(service, "CHIKORITA", 5)
  gift(service, "TOTODILE", 5)
  local profile = CatalogFixture.profile()
  setMon(service, 0, function(mon)
    mon.origin.trainerId = 7
  end)
  setMon(service, 1, function(mon)
    mon.origin.trainerId = profile.trainerId % 65536
  end)
  local low = buildFacts(service, 0)
  Assert.equal(low.info.otIdText, "00007", "a small id keeps leading zeroes")
  Assert.equal(low.memo.condition, "wildEncounterTraded", "a bare matching visible id is not ownership")
  local shared = buildFacts(service, 1)
  Assert.equal(
    shared.info.otIdText,
    string.format("%05d", profile.trainerId % 65536),
    "the shared visible id formats identically"
  )
  Assert.equal(shared.memo.condition, "wildEncounterTraded", "a shared visible id without the full id is traded")
end

function T.refresh_is_read_only_and_snapshots_are_isolated_values()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x30303030)
  gift(service, "CHIKORITA", 5)
  gift(service, "TOTODILE", 5)
  local manifest = SummaryPresentationFixture.manifest()
  local before = service:capture()
  local facts = buildFacts(service, 0, SummaryPresentationFixture.context(2), manifest)
  buildFacts(service, 1, SummaryPresentationFixture.context(2, { dexMode = "national", dayOfMonth = 20 }), manifest)
  local disabledFacts =
    SummaryModel.build(service, 0, SummaryPresentationFixture.context(2, { performanceEnabled = false }), manifest)
  Assert.isNil(disabledFacts.performance, "disabled performance exposes no rows here either")
  Assert.deepEqual(service:capture(), before, "display work leaves the save and rng byte-equivalent")
  facts.info.extra = "MUTATED"
  facts.moves[1].pp = -1
  facts.ribbons.extra = true
  Assert.deepEqual(service:capture(), before, "mutating the snapshot reaches no service state")
  local clean = buildFacts(service, 0, SummaryPresentationFixture.context(2), manifest)
  Assert.isNil(clean.info.extra, "local mutation never leaks into later refreshes")
  Assert.isTrue(clean.moves[1].pp >= 0, "move points stay authoritative after local mutation")
  Assert.throws(function()
    SummaryModel.build(service, 2, SummaryPresentationFixture.context(2), manifest)
  end, "an unoccupied slot fails before returning facts")
  Assert.throws(function()
    SummaryModel.build(service, 0, SummaryPresentationFixture.context(2, { dexMode = "kantonian" }), manifest)
  end, "an unknown dex mode fails before returning facts")
  Assert.throws(function()
    SummaryModel.build(service, 0, SummaryPresentationFixture.context(2, { dayOfMonth = 32 }), manifest)
  end, "an impossible day fails before returning facts")
  local missing = {}
  for key, value in pairs(manifest) do
    missing[key] = value
  end
  missing.dexNumbers = nil
  Assert.throws(function()
    SummaryModel.build(service, 0, SummaryPresentationFixture.context(2), missing)
  end, "a missing generated role fails before returning facts")
  local unmapped = {}
  for key, value in pairs(manifest) do
    unmapped[key] = value
  end
  unmapped.dexNumbers = { CHIKORITA = { national = 152, regional = 1 } }
  Assert.throws(function()
    SummaryModel.build(service, 1, SummaryPresentationFixture.context(2), unmapped)
  end, "an unmapped species fails instead of guessing a dex number")
end

function T.level_100_reports_zero_to_next_and_genderless_resolves_a_declared_alias()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x40404040)
  gift(service, "CHIKORITA", 100)
  gift(service, "SHEDINJA", 5)
  local capped = buildFacts(service, 0)
  Assert.equal(capped.info.expToNext, 0, "level 100 keeps the source zero-to-next value")
  local genderless = buildFacts(service, 1)
  Assert.equal(genderless.identity.gender, "genderless", "the genderless ratio is observed")
  Assert.equal(genderless.pictureKey, "SHEDINJA", "genderless mons resolve the species picture")
  local manifest = SummaryPresentationFixture.manifest()
  Assert.equal(
    manifest.pictures[genderless.pictureKey].portrait,
    "SHEDINJA/f0/male/plain",
    "the alias is declared before preparation, never caught at draw"
  )
end

function T.move_rows_keep_four_logical_slots_with_display_text_policy()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x50505050)
  gift(service, "CHIKORITA", 5)
  while #service:partyMon(0).moves > 1 do
    service:deleteMove(0, 0)
  end
  service:setMove(0, 0, "GROWL")
  service:setMove(0, 1, "CUT")
  local facts = buildFacts(service, 0)
  Assert.equal(#facts.moves, 4, "hatched mons always expose four logical rows")
  Assert.keySet(facts.moves[1], MOVE_ROW_KEYS, "occupied rows carry the full move contract")
  Assert.equal(facts.moves[1].kind, "move", "occupied rows are marked")
  Assert.equal(facts.moves[1].moveSlot, 0, "rows keep zero-based domain slots")
  Assert.equal(facts.moves[1].key, "GROWL", "rows keep the semantic move key")
  Assert.isTrue(type(facts.moves[1].powerText) == "string", "power renders as display text")
  Assert.isTrue(facts.moves[1].powerText ~= "0", "zero power uses authored text, never an invented zero")
  Assert.equal(facts.moves[2].key, "CUT", "the second row keeps its move")
  Assert.isTrue(facts.moves[2].powerText:find("50", 1, true) ~= nil, "real power shows its value")
  Assert.isTrue(facts.moves[2].accuracyText:find("95", 1, true) ~= nil, "real accuracy shows its value")
  Assert.equal(facts.moves[2].pp, facts.moves[2].ppMax, "a fresh move starts at full points")
  Assert.keySet(facts.moves[3], "kind,moveSlot", "empty rows carry no invented move")
  Assert.equal(facts.moves[3].kind, "empty", "absent rows are explicit")
  Assert.equal(facts.moves[3].moveSlot, 2, "empty rows keep their domain slot")
  Assert.equal(facts.moves[4].moveSlot, 3, "the fourth row keeps its domain slot")
  local copy = service:partyMon(0)
  copy.moves[2].ppUps = 3
  copy.moves[2].pp = 1
  local preparation = assert(service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = copy } }))
  preparation.publish()
  local boosted = buildFacts(service, 0)
  Assert.equal(boosted.moves[2].pp, 1, "current points stay with the entry")
  Assert.equal(boosted.moves[2].ppMax, 30 + math.floor(30 * 3 / 5), "point ups widen the maximum")
  Assert.equal(boosted.moves[2].ppUps, 3, "point ups stay with the entry")
end

function T.status_pokerus_markings_and_leaves_stay_independent()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x60606060)
  gift(service, "CHIKORITA", 5)
  local function indicators(edit)
    setMon(service, 0, edit)
    return buildFacts(service, 0).indicators
  end
  Assert.equal(indicators(function() end).status, "ok", "a fresh mon carries no status")
  Assert.equal(
    indicators(function(mon)
      mon.condition.status = 3
    end).status,
    "sleep",
    "sleep bits read sleep"
  )
  Assert.equal(
    indicators(function(mon)
      mon.condition.status = 0x8
    end).status,
    "poison",
    "poison reads poison"
  )
  Assert.equal(
    indicators(function(mon)
      mon.condition.status = 0x10
    end).status,
    "burn",
    "burn reads burn"
  )
  Assert.equal(
    indicators(function(mon)
      mon.condition.status = 0x20
    end).status,
    "freeze",
    "freeze reads freeze"
  )
  Assert.equal(
    indicators(function(mon)
      mon.condition.status = 0x40
    end).status,
    "paralysis",
    "paralysis reads paralysis"
  )
  Assert.equal(
    indicators(function(mon)
      mon.condition.status = 0
      mon.condition.currentHp = 0
    end).status,
    "faint",
    "zero health reads faint"
  )
  setMon(service, 0, function(mon)
    mon.condition.status = 0
    mon.condition.currentHp = service:derive(mon).maxHp
    mon.pokerus = 0
  end)
  Assert.equal(buildFacts(service, 0).indicators.pokerus, "none", "a clear byte reads no pokerus")
  setMon(service, 0, function(mon)
    mon.pokerus = 0x13
  end)
  Assert.equal(buildFacts(service, 0).indicators.pokerus, "active", "remaining days read active infection")
  local cured = indicators(function(mon)
    mon.condition.status = 0x8
    mon.pokerus = 0x10
  end)
  Assert.equal(cured.pokerus, "cured", "a strain without days reads cured")
  Assert.equal(cured.status, "poison", "a cured marker coexists with status")
  local marked = indicators(function(mon)
    mon.condition.status = 0
    mon.condition.currentHp = service:derive(mon).maxHp
    mon.pokerus = 0
    mon.markings = 21
    mon.shinyLeaves = 31
  end)
  Assert.deepEqual(marked.markings, { true, false, true, false, true, false }, "markings keep their bit order")
  Assert.deepEqual(marked.leaves, { true, true, true, true, true }, "five leaves stay independent")
  Assert.isFalse(marked.crown, "leaves never crown")
  local crowned = indicators(function(mon)
    mon.shinyLeaves = 32
  end)
  Assert.isTrue(crowned.crown, "the crown bit crowns explicitly")
  Assert.deepEqual(crowned.leaves, { false, false, false, false, false }, "the crown suppresses every leaf")
end

function T.earned_ribbons_follow_source_order_without_a_nine_item_cap()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x70707070)
  gift(service, "CHIKORITA", 5)
  gift(service, "TOTODILE", 5)
  gift(service, "EEVEE", 5)
  gift(service, "CHIKORITA", 5)
  gift(service, "TOTODILE", 5)
  local manifest = SummaryPresentationFixture.manifest()
  local function select(slot, ribbons)
    setMon(service, slot, function(mon)
      mon.ribbons = ribbons
    end)
    return buildFacts(service, slot, SummaryPresentationFixture.context(5), manifest).ribbons
  end
  Assert.deepEqual(select(0, { ds1 = 0, gba = 0, ds2 = 0 }), {}, "no bits earns no ribbons")
  local function expectedKeys(ribbons)
    local mon = { ribbons = ribbons }
    local keys = {}
    for _, entry in ipairs(manifest.ribbons.entries) do
      if ribbonBit(mon, entry.bitGroup, entry.bit) then
        keys[#keys + 1] = entry.key
      end
    end
    return keys
  end
  local one = select(1, { ds1 = 1, gba = 0, ds2 = 0 })
  Assert.deepEqual(earnedKeys({ ribbons = one }), { "syn_ds1_00" }, "one bit earns one ribbon")
  local nine = select(2, { ds1 = 511, gba = 0, ds2 = 0 })
  Assert.equal(#nine, 9, "nine bits earn nine ribbons")
  local ten = select(3, { ds1 = 511, gba = 1, ds2 = 0 })
  Assert.equal(#ten, 10, "ten bits earn ten ribbons across groups, never capped at nine")
  Assert.deepEqual(
    earnedKeys({ ribbons = ten }),
    expectedKeys({ ds1 = 511, gba = 1, ds2 = 0 }),
    "order follows the source definitions"
  )
  local full = select(4, { ds1 = 4294967295, gba = 33554431, ds2 = 8388607 })
  Assert.equal(#full, 80, "every bit earns its ribbon exactly once")
  Assert.deepEqual(
    earnedKeys({ ribbons = full }),
    expectedKeys({ ds1 = 4294967295, gba = 33554431, ds2 = 8388607 }),
    "all eighty keep source order"
  )
  local before = service:capture()
  buildFacts(service, 4, SummaryPresentationFixture.context(5), manifest)
  Assert.deepEqual(service:capture(), before, "ribbon reads never award or mutate")
  for _, entry in ipairs(full) do
    Assert.isTrue(type(entry.name) == "string" and #entry.name > 0, "earned ribbons carry names")
    Assert.isTrue(type(entry.description) == "string" and #entry.description > 0, "earned ribbons carry text")
    Assert.notNil(entry.art, "earned ribbons carry their visuals")
  end
end

function T.only_the_context_selected_special_description_changes()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x80808080)
  gift(service, "CHIKORITA", 5)
  setMon(service, 0, function(mon)
    mon.ribbons = { ds1 = 2147483649, gba = 16777216, ds2 = 0 }
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local plain = SummaryPresentationFixture.context(1)
  local changed = SummaryPresentationFixture.context(1)
  changed.specialRibbonDescriptions[2] = "SYN CHANGED SLOT TWO"
  local before = service:capture()
  local first = buildFacts(service, 0, plain, manifest).ribbons
  local second = buildFacts(service, 0, changed, manifest).ribbons
  Assert.equal(#first, #second, "the description context changes no membership")
  local function byKey(ribbons, key)
    for _, entry in ipairs(ribbons) do
      if entry.key == key then
        return entry
      end
    end
    error("earned ribbons carry " .. key, 0)
  end
  Assert.equal(
    byKey(second, "syn_ds1_00").description,
    byKey(first, "syn_ds1_00").description,
    "ordinary descriptions ignore the special slots"
  )
  Assert.equal(
    byKey(second, "syn_ds1_special").description,
    byKey(first, "syn_ds1_special").description,
    "unselected special slots stay stable"
  )
  Assert.isTrue(
    byKey(second, "syn_gba_special").description:find("SYN CHANGED SLOT TWO", 1, true) ~= nil,
    "the selected slot resolves its new description"
  )
  Assert.deepEqual(service:capture(), before, "description reads never touch the save")
end

function T.performance_applies_source_order_thresholds_and_display_order()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x90909090)
  gift(service, "CHIKORITA", 5)
  gift(service, "EEVEE", 5)
  setMon(service, 0, function(mon)
    mon.personality = 12345
  end)
  setMon(service, 1, function(mon)
    mon.personality = 12345
    mon.form = 1
    mon.ability = "ADAPTABILITY"
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local day13 = SummaryPresentationFixture.context(2, { dayOfMonth = 13 })
  local facts = buildFacts(service, 0, day13, manifest)
  Assert.equal(#facts.performance, 5, "performance exposes five named rows")
  local order = {}
  for _, row in ipairs(facts.performance) do
    order[#order + 1] = row.stat
  end
  Assert.deepEqual(order, DISPLAY_ORDER, "display order differs from the source calculation order")
  for _, stat in ipairs(DISPLAY_ORDER) do
    local expected = expectedRow(manifest, "CHIKORITA/f0", stat, 12345, 13, 0)
    local row = performanceRow(facts, stat)
    Assert.equal(row.base, expected.base, stat .. " keeps its source base")
    Assert.equal(row.min, expected.min, stat .. " keeps its source minimum")
    Assert.equal(row.max, expected.max, stat .. " keeps its source maximum")
    Assert.equal(row.stars, expected.stars, stat .. " converts its score exactly")
    Assert.equal(row.tone, expected.tone, stat .. " colors against its own base")
  end
  local day1 = buildFacts(service, 0, SummaryPresentationFixture.context(2, { dayOfMonth = 1 }), manifest)
  for _, stat in ipairs(DISPLAY_ORDER) do
    local expected = expectedRow(manifest, "CHIKORITA/f0", stat, 12345, 1, 0)
    Assert.equal(performanceRow(day1, stat).stars, expected.stars, stat .. " follows the explicit day")
  end
  local alternate = buildFacts(service, 1, day13, manifest)
  Assert.equal(performanceRow(alternate, "power").base, 6, "alternate forms read their own base")
  Assert.equal(performanceRow(facts, "power").base, 5, "the base form keeps its own base")
end

function T.star_thresholds_use_inclusive_bounds_and_clamp_before_coloring()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xA1A1A1A1)
  gift(service, "TOTODILE", 5)
  setMon(service, 0, function(mon)
    mon.personality = 6
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local pid = 6
  local day = 13
  local modifier = manifest.performance.natureModifiers[(pid % 25) + 1].power
  local center = dailyScore(modifier, pid, day, SOURCE_INDEX.power)
  for _, target in ipairs(BOUNDARY_SCORES) do
    local aprijuice = target - center
    Assert.isTrue(aprijuice >= -128 and aprijuice <= 127, "target " .. target .. " stays in the signed range")
    local apri = { power = aprijuice, stamina = 0, skill = 0, jump = 0, speed = 0 }
    local context = SummaryPresentationFixture.context(1, { dayOfMonth = day })
    context.aprijuiceBySlot[1] = apri
    local row = performanceRow(buildFacts(service, 0, context, manifest), "power")
    local stars = clampStars(5 + starAdjustment(target), 3, 7)
    local tone = "base"
    if stars < 5 then
      tone = "below"
    elseif stars > 5 then
      tone = "above"
    end
    Assert.equal(row.stars, stars, "score " .. target .. " converts through its inclusive bound")
    Assert.equal(row.tone, tone, "score " .. target .. " colors after clamping")
  end
  local function swept(aprijuice)
    local context = SummaryPresentationFixture.context(1, { dayOfMonth = day })
    context.aprijuiceBySlot[1] = { power = aprijuice, stamina = 0, skill = 0, jump = 0, speed = 0 }
    return performanceRow(buildFacts(service, 0, context, manifest), "power")
  end
  local top = swept(127)
  Assert.equal(top.stars, 7, "extreme modifiers clamp to the source maximum")
  Assert.equal(top.tone, "above", "clamped highs color above base")
  local bottom = swept(-128)
  Assert.equal(bottom.stars, 3, "extreme modifiers clamp to the source minimum")
  Assert.equal(bottom.tone, "below", "clamped lows color below base")
end

function T.disabled_performance_hides_rows_but_keeps_ribbons_without_clock_or_rng()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xB1B1B1B1)
  gift(service, "CHIKORITA", 5)
  setMon(service, 0, function(mon)
    mon.ribbons = { ds1 = 1, gba = 0, ds2 = 0 }
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local enabled = SummaryPresentationFixture.context(1, { performanceEnabled = true })
  local disabled = SummaryPresentationFixture.context(1, { performanceEnabled = false })
  local shown = buildFacts(service, 0, enabled, manifest)
  Assert.equal(#shown.performance, 5, "enabled performance exposes five rows")
  local hidden = SummaryModel.build(service, 0, disabled, manifest)
  Assert.isNil(hidden.performance, "disabled performance exposes no rows")
  Assert.notNil(hidden.ribbons, "disabled performance keeps the ribbon list")
  Assert.equal(#hidden.ribbons, 1, "disabled performance keeps ribbons available")
  Assert.equal(hidden.ribbons[1].key, "syn_ds1_00", "the ribbon survives the flag")
  local before = service:capture()
  local again = SummaryModel.build(service, 0, enabled, manifest)
  Assert.deepEqual(again, shown, "one context rebuilds one stable snapshot")
  Assert.deepEqual(service:capture(), before, "performance reads touch no clock, save, or rng")
  local later = SummaryModel.build(service, 0, SummaryPresentationFixture.context(1, { dayOfMonth = 14 }), manifest)
  Assert.isTrue(later.contextKey ~= shown.contextKey, "a changed day changes the signature")
  Assert.isTrue(later.performance ~= nil, "a changed day keeps performance")
  local same = true
  for index, row in ipairs(shown.performance) do
    if row.stars ~= later.performance[index].stars then
      same = false
    end
  end
  Assert.isFalse(same, "the explicit day drives the daily values")
end

function T.performance_covers_all_twenty_five_natures_and_pid_extremes()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC2C2C2C2)
  gift(service, "CHIKORITA", 5)
  local manifest = SummaryPresentationFixture.manifest()
  for nature = 0, 24 do
    setMon(service, 0, function(mon)
      mon.personality = nature
    end)
    local facts = buildFacts(service, 0, SummaryPresentationFixture.context(1, { dayOfMonth = 13 }), manifest)
    for _, stat in ipairs(DISPLAY_ORDER) do
      local expected = expectedRow(manifest, "CHIKORITA/f0", stat, nature, 13, 0)
      local row = performanceRow(facts, stat)
      Assert.equal(row.stars, expected.stars, "nature " .. nature .. " " .. stat .. " converts its score exactly")
      Assert.equal(row.tone, expected.tone, "nature " .. nature .. " " .. stat .. " colors against its own base")
    end
  end
  for _, pid in ipairs({ 0, 4294967295 }) do
    setMon(service, 0, function(mon)
      mon.personality = pid
    end)
    local facts = buildFacts(service, 0, SummaryPresentationFixture.context(1, { dayOfMonth = 13 }), manifest)
    for _, stat in ipairs(DISPLAY_ORDER) do
      local expected = expectedRow(manifest, "CHIKORITA/f0", stat, pid, 13, 0)
      local row = performanceRow(facts, stat)
      Assert.equal(row.stars, expected.stars, "personality " .. pid .. " " .. stat .. " converts its score exactly")
      Assert.equal(row.tone, expected.tone, "personality " .. pid .. " " .. stat .. " colors against its own base")
    end
  end
end

function T.nature_labels_split_raise_and_lower_with_neutral_none()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC3C3C3C3)
  gift(service, "CHIKORITA", 5)
  local manifest = SummaryPresentationFixture.manifest()
  local battleKeys = { attack = true, defense = true, speed = true, specialAttack = true, specialDefense = true }
  for nature = 0, 24 do
    setMon(service, 0, function(mon)
      mon.personality = nature
    end)
    local shift = buildFacts(service, 0).skills.nature
    if nature == 0 or nature == 6 or nature == 12 or nature == 18 or nature == 24 then
      Assert.equal(shift.up, "none", "neutral nature " .. nature .. " raises no stat")
      Assert.equal(shift.down, "none", "neutral nature " .. nature .. " lowers no stat")
    else
      Assert.isTrue(battleKeys[shift.up] == true, "nature " .. nature .. " raises a battle stat")
      Assert.isTrue(battleKeys[shift.down] == true, "nature " .. nature .. " lowers a battle stat")
      Assert.isTrue(shift.up ~= shift.down, "nature " .. nature .. " raises and lowers distinct stats")
    end
  end
  setMon(service, 0, function(mon)
    mon.personality = 1
  end)
  local lonely = buildFacts(service, 0).skills.nature
  Assert.equal(lonely.up, "attack", "the lonely nature raises attack")
  Assert.equal(lonely.down, "defense", "the lonely nature lowers defense")
end

function T.bars_keep_source_floor_minimum_positive_and_level_100_edges()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xD3D3D3D3)
  gift(service, "CHIKORITA", 5)
  gift(service, "CHIKORITA", 100)
  local full = buildFacts(service, 0)
  Assert.equal(full.skills.hpBar.length, 48, "full health spans the source pixel width")
  Assert.equal(full.skills.hpBar.color, "high", "full health reads the high color")
  setMon(service, 1, function(mon)
    mon.condition.currentHp = 1
  end)
  local hanging = buildFacts(service, 1)
  Assert.equal(hanging.skills.hpBar.length, 1, "one remaining health keeps one pixel past the floor")
  Assert.equal(hanging.indicators.status, "ok", "one health with no ailment reads ok")
  setMon(service, 0, function(mon)
    mon.condition.currentHp = 0
  end)
  local fainted = buildFacts(service, 0)
  Assert.equal(fainted.skills.hpBar.length, 0, "no health fills no pixels")
  Assert.equal(fainted.indicators.status, "faint", "no health reads faint")
  local capped = buildFacts(service, 1)
  Assert.equal(capped.info.expToNext, 0, "level 100 keeps the source zero-to-next value")
  Assert.equal(capped.info.expBar.length, 0, "level 100 fills no experience pixels")
end

local function expectedSelector(catalog, mon)
  local species = assert(mon.species, "stored mons carry their species")
  local form = assert(mon.form, "stored mons carry their form")
  local personality = assert(mon.personality, "stored mons carry their personality")
  local origin = assert(mon.origin, "stored mons carry their origin")
  local shiny = Personality.shiny(assert(origin.trainerId, "origins carry the trainer identity"), personality)
  local speciesRecord = catalog:species(species)
  local gender = Personality.gender(assert(speciesRecord.genderRatio, "species carry a ratio"), personality)
  if gender ~= "genderless" then
    return MonCache.portraitSelector(species, form, gender, shiny)
  end
  local formRecord = catalog:form(species, form)
  local declared = assert(formRecord.portrait, "generated forms declare their portrait variant")
  local variant = declared:match("^[^/]+/[^/]+/([^/]+)/[^/]+$")
  Assert.notNil(variant, "the declared portrait names its gender variant")
  Assert.isTrue(variant == "male" or variant == "female", "the generated variant stays binary")
  return MonCache.portraitSelector(species, form, variant, shiny)
end

function T.roster_and_selected_facts_carry_exact_portrait_selectors()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xE4E4E4E4)
  gift(service, "CHIKORITA", 5)
  gift(service, "TOTODILE", 5)
  gift(service, "SHEDINJA", 5)
  gift(service, "EEVEE", 5)
  gift(service, "CHIKORITA", 5)
  setMon(service, 1, function(mon)
    mon.personality = 0
  end)
  setMon(service, 3, function(mon)
    mon.form = 1
    mon.ability = "ADAPTABILITY"
  end)
  setMon(service, 4, function(mon)
    mon.isEgg = true
    mon.moves = {}
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local context = SummaryPresentationFixture.context(service:partyCount())
  local selected = nil
  for slot = 0, 3 do
    local facts = SummaryModel.build(service, slot, context, manifest)
    local mon = service:partyMon(slot)
    local expected = expectedSelector(catalog, mon)
    Assert.equal(facts.portraitSelector, expected, "slot " .. slot .. " keeps its exact portrait identity")
    Assert.isTrue(type(facts.portraitSelector) == "string", "slot " .. slot .. " names its selector")
    Assert.isTrue(facts.pictureKey ~= facts.portraitSelector, "the timeline key stays distinct from pixels")
    Assert.notNil(manifest.pictures[facts.pictureKey], "the timeline key resolves its picture")
    if slot == 0 then
      selected = facts
    end
  end
  Assert.equal(selected.roster[1].portraitSelector, selected.portraitSelector, "the roster reuses the selected row")
  for slot = 0, 3 do
    local facts = SummaryModel.build(service, slot, context, manifest)
    Assert.equal(
      facts.roster[slot + 1].portraitSelector,
      facts.portraitSelector,
      "roster row " .. slot .. " matches its selected facts"
    )
  end
  local egg = SummaryModel.build(service, 4, context, manifest)
  Assert.isNil(egg.portraitSelector, "eggs demand no portrait page")
  Assert.isNil(egg.roster[5].portraitSelector, "egg roster rows stay page-free")
  Assert.equal(egg.pictureKey, "EGG", "eggs keep their picture key")
  local genderless = SummaryModel.build(service, 2, context, manifest)
  Assert.equal(genderless.identity.gender, "genderless", "the genderless ratio is observed")
  Assert.equal(
    genderless.portraitSelector,
    expectedSelector(catalog, service:partyMon(2)),
    "genderless selectors use the generated form variant"
  )
  local alternate = SummaryModel.build(service, 3, context, manifest)
  Assert.isTrue(
    alternate.portraitSelector:find("EEVEE/f1/", 1, true) ~= nil,
    "alternate forms keep their form identity"
  )
end

function T.shiny_variants_change_only_the_finish_suffix()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xE5E5E5E5)
  gift(service, "CHIKORITA", 5)
  local profile = CatalogFixture.profile()
  local shinyPid = nil
  for pid = 0, 300000 do
    if Personality.shiny(profile.trainerId, pid) then
      shinyPid = pid
      break
    end
  end
  Assert.notNil(shinyPid, "the search finds a shiny personality")
  local shinyGender = Personality.gender(31, shinyPid)
  local plainPid = nil
  for pid = 0, 300000 do
    if not Personality.shiny(profile.trainerId, pid) and Personality.gender(31, pid) == shinyGender then
      plainPid = pid
      break
    end
  end
  Assert.notNil(plainPid, "the search finds a plain personality of the same gender")
  local manifest = SummaryPresentationFixture.manifest()
  local context = SummaryPresentationFixture.context(1)
  setMon(service, 0, function(mon)
    mon.personality = plainPid
  end)
  local plain = SummaryModel.build(service, 0, context, manifest)
  Assert.isFalse(plain.identity.shiny, "the plain personality reads plain")
  Assert.isTrue(plain.portraitSelector:find("/plain", 1, true) ~= nil, "plain selectors keep the plain finish")
  setMon(service, 0, function(mon)
    mon.personality = shinyPid
  end)
  local shiny = SummaryModel.build(service, 0, context, manifest)
  Assert.isTrue(shiny.identity.shiny, "the shiny personality reads shiny")
  Assert.isTrue(shiny.portraitSelector:find("/shiny", 1, true) ~= nil, "shiny selectors keep the shiny finish")
  Assert.equal(
    shiny.portraitSelector:gsub("/shiny$", "/plain"),
    plain.portraitSelector:gsub("/shiny$", "/plain"),
    "only the finish suffix changes with shininess"
  )
end

function T.selected_facts_carry_source_display_values()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xE6E6E6E6)
  gift(service, "CHIKORITA", 5)
  setMon(service, 0, function(mon)
    mon.nickname = "LEAFY"
    mon.heldItem = "SITRUS_BERRY"
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local facts = SummaryModel.build(service, 0, SummaryPresentationFixture.context(1), manifest)
  local mon = service:partyMon(0)
  local speciesRecord = catalog:species(assert(mon.species, "stored mons carry their species"))
  local formRecord = catalog:form(mon.species, assert(mon.form, "stored mons carry their form"))
  Assert.equal(facts.identity.speciesName, speciesRecord.name, "identity names the catalog species")
  Assert.deepEqual(facts.identity.types, formRecord.types, "identity lists the generated form types")
  Assert.equal(
    facts.identity.otName,
    assert(mon.origin, "stored mons carry their origin").trainerName,
    "identity names the original trainer"
  )
  local itemRecord = catalog:item(assert(mon.heldItem, "stored mons carry their held item"))
  Assert.equal(facts.info.heldItem, mon.heldItem, "info keeps the held-item key")
  Assert.equal(facts.info.heldItemName, itemRecord.name, "info names the held item from the catalog")
  Assert.equal(
    facts.info.experience,
    assert(mon.experience, "stored mons carry experience"),
    "info keeps current experience"
  )
end

function T.performance_rows_publish_their_signed_aprijuice_modifier()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xD03D0301)
  gift(service, "CHIKORITA", 5)
  setMon(service, 0, function(mon)
    mon.personality = 12345
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local juice = { power = 40, stamina = -128, skill = 0, jump = 127, speed = -1 }
  local context = SummaryPresentationFixture.context(1, { dayOfMonth = 13 })
  context.aprijuiceBySlot[1] = juice
  local facts = buildFacts(service, 0, context, manifest)
  Assert.equal(#facts.performance, 5, "performance exposes five named rows")
  for _, stat in ipairs(DISPLAY_ORDER) do
    local expected = expectedRow(manifest, "CHIKORITA/f0", stat, 12345, 13, juice[stat])
    local row = performanceRow(facts, stat)
    Assert.equal(row.base, expected.base, stat .. " keeps its source base under aprijuice")
    Assert.equal(row.min, expected.min, stat .. " keeps its source minimum under aprijuice")
    Assert.equal(row.max, expected.max, stat .. " keeps its source maximum under aprijuice")
    Assert.equal(row.stars, expected.stars, stat .. " keeps its converted stars under aprijuice")
    Assert.equal(row.tone, expected.tone, stat .. " keeps its tone under aprijuice")
    Assert.equal(row.modifier, juice[stat], stat .. " publishes its signed aprijuice modifier")
  end
end

function T.detached_subject_sets_share_the_rich_projection_without_per_member_rows()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  gift(service, "CHIKORITA", 5)
  local subject = service:partyMon(0)
  local subjects = {}
  for index = 1, 7 do
    subjects[index] = subject
  end
  local seen = {}
  local reader = {
    partyCount = function()
      return #subjects
    end,
    partyRevision = function()
      return 41
    end,
    partyMon = function(_, index)
      seen[#seen + 1] = index
      return assert(subjects[index + 1], "detached reads stay inside the occupied set")
    end,
    catalog = function()
      return catalog
    end,
    derive = function(_, mon)
      return service:derive(mon)
    end,
  }
  -- One context row for seven subjects: detached sets carry no
  -- per-subject aprijuice state, so the projection resolves the generated
  -- zero modifiers instead of demanding a padded row per member.
  local facts =
    SummaryModel.build(reader, 6, SummaryPresentationFixture.context(1), SummaryPresentationFixture.manifest())
  Assert.equal(facts.slot, 6, "the selected dense index addresses the seventh subject")
  Assert.equal(facts.slotCount, 7, "the detached set spans every occupied subject")
  Assert.equal(#facts.roster, 7, "navigation facts cover the whole detached set")
  Assert.equal(facts.identity.species, "CHIKORITA", "the selected subject projects through the rich path")
  local performance = assert(facts.performance, "performance stays available without per-member rows")
  Assert.equal(#performance, 5, "performance exposes five named rows")
  for _, row in ipairs(performance) do
    Assert.equal(row.modifier, 0, "detached subjects resolve the zero modifier")
  end
  Assert.isTrue(#seen >= 7, "the projection reads through the subject set")
end

return { tests = T }
