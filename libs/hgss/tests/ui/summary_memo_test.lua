-- Source encounter-memo selection, authored line placement, and egg
-- concealment over the live mon service. Every expectation reads the
-- synthetic presentation rules, never renderer output: the memo must pick
-- the source branch from origin/met/egg/fateful values plus full-identity
-- ownership, keep authored line indices, and never expose hatch-hidden
-- battle detail. The memo is exercised through the summary projection so
-- the contract observes missing behavior rather than module presence.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")

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
    location = SummaryPresentationFixture.WILD_LOCATION,
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

local function build(service, slot, context, manifest)
  local facts = SummaryModel.build(
    service,
    slot,
    context or SummaryPresentationFixture.context(service:partyCount()),
    manifest or SummaryPresentationFixture.manifest()
  )
  Assert.notNil(facts.memo, "the projection carries the source memo")
  Assert.notNil(facts.info, "the projection carries native info")
  return facts
end

-- Flattens ordered memo blocks into a line-indexed text map; runs carry
-- their display text with an optional color role.
local function lineMap(blocks)
  Assert.notNil(blocks, "the memo carries ordered blocks")
  local map = {}
  for _, block in ipairs(blocks) do
    Assert.isTrue(type(block.line) == "number" and block.line >= 1, "memo blocks keep positive source lines")
    Assert.isTrue(type(block.runs) == "table" and #block.runs >= 1, "memo blocks carry text runs")
    local parts = {}
    for _, run in ipairs(block.runs) do
      parts[#parts + 1] = run.text or run.value or ""
    end
    map[block.line] = table.concat(parts)
  end
  return map
end

local function memoText(blocks)
  Assert.isTrue(type(blocks) == "table", "the memo carries ordered blocks")
  local parts = {}
  for _, block in ipairs(blocks) do
    for _, run in ipairs(block.runs) do
      parts[#parts + 1] = run.text or run.value or ""
    end
  end
  return table.concat(parts, "\n")
end

local function rule(manifest, condition)
  local entry = manifest.memo.conditions[condition]
  Assert.notNil(entry, "the synthetic rules cover " .. condition)
  return entry
end

function T.ownership_decides_the_branch_while_the_visible_id_stays_five_digits()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xA0A0A0A0)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  local profile = CatalogFixture.profile()
  local mine = build(service, 0)
  Assert.equal(mine.memo.condition, "wildEncounter", "the own wild record reads its own branch")
  Assert.equal(
    mine.info.otIdText,
    string.format("%05d", profile.trainerId % 65536),
    "the visible trainer id keeps five digits"
  )
  local expected = rule(manifest, "wildEncounter")
  local lines = lineMap(mine.memo.blocks)
  Assert.notNil(lines[expected.nature], "the ordinary wild nature opens its authored line")
  Assert.isTrue(#lines[expected.nature] > 0, "the ordinary wild nature carries text")
  Assert.notNil(lines[expected.date], "the ordinary wild date block is present")
  Assert.isTrue(lines[expected.date]:find("SYN NEW BARK", 1, true) ~= nil, "the date block names the wild landmark")
  Assert.isTrue(lines[expected.characteristic] ~= nil, "the characteristic keeps authored line 6")
  Assert.isTrue(lines[expected.flavor] ~= nil, "the flavor keeps authored line 7")
  setMon(service, 0, function(mon)
    mon.origin.trainerId = profile.trainerId % 65536
  end)
  local traded = build(service, 0)
  Assert.equal(traded.info.otIdText, mine.info.otIdText, "the traded record shares the visible id")
  Assert.equal(traded.memo.condition, "wildEncounterTraded", "a differing full identity reads traded")
  local tradedRule = rule(manifest, "wildEncounterTraded")
  local tradedLines = lineMap(traded.memo.blocks)
  Assert.notNil(tradedLines[tradedRule.nature], "the traded branch keeps its own authored template")
  Assert.isTrue(memoText(traded.memo.blocks) ~= memoText(mine.memo.blocks), "ownership changes the authored wording")
end

function T.fateful_hatched_gift_and_migrated_records_keep_their_own_lines()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xB0B0B0B0)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE", 1)
  gift(service, "EEVEE")
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  setMon(service, 0, function(mon)
    mon.fatefulEncounter = true
  end)
  setMon(service, 2, function(mon)
    mon.met.location = SummaryPresentationFixture.GIFT_LOCATION
  end)
  setMon(service, 3, function(mon)
    mon.met.location = SummaryPresentationFixture.PAL_PARK_LOCATION
  end)
  local fateful = build(service, 0)
  Assert.equal(fateful.memo.condition, "fatefulEncounter", "the fateful flag selects its branch")
  local fatefulRule = rule(manifest, "fatefulEncounter")
  local fatefulLines = lineMap(fateful.memo.blocks)
  Assert.notNil(fatefulLines[fatefulRule.characteristic], "the fateful characteristic keeps line 7")
  Assert.notNil(fatefulLines[fatefulRule.flavor], "the fateful flavor keeps line 8")
  local hatched = build(service, 1)
  Assert.equal(hatched.memo.condition, "eggHatched", "meeting at level one reads hatched")
  local hatchedRule = rule(manifest, "eggHatched")
  local hatchedLines = lineMap(hatched.memo.blocks)
  Assert.notNil(hatchedLines[hatchedRule.characteristic], "the hatched characteristic keeps line 8")
  Assert.notNil(hatchedLines[hatchedRule.flavor], "the hatched flavor keeps line 9")
  local gifted = build(service, 2)
  Assert.equal(gifted.memo.condition, "wildGift", "the gift location selects its template")
  local giftDate = lineMap(gifted.memo.blocks)[rule(manifest, "wildGift").date]
  Assert.notNil(giftDate, "the gift date block is present")
  Assert.isTrue(giftDate:find("SYN GIFT SHOP", 1, true) ~= nil, "the gift block names the gift landmark")
  local migrated = build(service, 3)
  Assert.equal(migrated.memo.condition, "migrated", "the pal-park location selects migration")
end

function T.unknown_landmarks_use_the_source_fallback_text()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC0C0C0C0)
  gift(service, "CHIKORITA")
  setMon(service, 0, function(mon)
    mon.met.location = SummaryPresentationFixture.UNKNOWN_LOCATION
  end)
  local facts = build(service, 0)
  local text = memoText(facts.memo.blocks)
  Assert.isTrue(text:find("SYN FARAWAY", 1, true) ~= nil, "an out-of-range location reads the fallback")
  Assert.isTrue(text:find("60000", 1, true) == nil, "the raw numeric id never leaks into wording")
end

function T.characteristic_names_the_top_iv_while_flavor_follows_nature()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xD0D0D0D0)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  setMon(service, 0, function(mon)
    mon.ivs = { hp = 10, attack = 10, defense = 10, speed = 31, specialAttack = 10, specialDefense = 10 }
  end)
  local facts = build(service, 0)
  local expected = manifest.text.labels[manifest.memo.characteristics[4][(31 % 5) + 1]]
  Assert.isTrue(
    memoText(facts.memo.blocks):find(expected, 1, true) ~= nil,
    "the highest remainder names the speed characteristic"
  )
  local flavors = {}
  for _, label in ipairs(manifest.memo.flavors.byFlavor) do
    flavors[#flavors + 1] = manifest.text.labels[label]
  end
  flavors[#flavors + 1] = manifest.text.labels[manifest.memo.flavors.default]
  local text = memoText(facts.memo.blocks)
  local seen = false
  for _, flavor in ipairs(flavors) do
    if text:find(flavor, 1, true) ~= nil then
      seen = true
    end
  end
  Assert.isTrue(seen, "the flavor run comes from the source flavor set")
  gift(service, "TOTODILE")
  setMon(service, 1, function(mon)
    mon.personality = service:partyMon(0).personality
  end)
  local sibling = build(service, 1)
  local function flavorLine(blocks)
    return lineMap(blocks)[rule(manifest, sibling.memo.condition).flavor]
  end
  local siblingFlavor = flavorLine(sibling.memo.blocks)
  local ownFlavor = flavorLine(facts.memo.blocks)
  Assert.notNil(siblingFlavor, "the sibling flavor line is present")
  Assert.notNil(ownFlavor, "the own flavor line is present")
  Assert.equal(siblingFlavor, ownFlavor, "one nature keeps one flavor")
  setMon(service, 1, function(mon)
    mon.ivs = { hp = 31, attack = 5, defense = 5, speed = 5, specialAttack = 5, specialDefense = 31 }
  end)
  local tied = build(service, 1)
  local tiedText = memoText(tied.memo.blocks)
  local hpLabel = manifest.text.labels[manifest.memo.characteristics[1][(31 % 5) + 1]]
  local spDefenseLabel = manifest.text.labels[manifest.memo.characteristics[6][(31 % 5) + 1]]
  Assert.isTrue(
    tiedText:find(hpLabel, 1, true) ~= nil or tiedText:find(spDefenseLabel, 1, true) ~= nil,
    "a tied top iv names one tied characteristic"
  )
  Assert.equal(memoText(build(service, 1).memo.blocks), tiedText, "the tie order stays deterministic")
end

function T.eggs_hide_battle_detail_and_vary_the_watch_text()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xE0E0E0E0)
  gift(service, "TOTODILE")
  setMon(service, 0, function(mon)
    mon.isEgg = true
    mon.moves = {}
  end)
  local manifest = SummaryPresentationFixture.manifest()
  local egg = build(service, 0)
  Assert.isTrue(egg.isEgg, "the egg flag is observed")
  Assert.equal(egg.memo.condition, "egg", "the unhatched record reads the egg branch")
  Assert.deepEqual(egg.moves, {}, "eggs expose no battle-move rows")
  Assert.isNil(egg.skills, "eggs expose no skills content")
  Assert.isNil(egg.performance, "eggs expose no performance content")
  Assert.equal(egg.pictureKey, "EGG", "eggs resolve the declared egg picture")
  local watchLabels = {}
  for _, label in ipairs(manifest.memo.eggWatch.templates) do
    watchLabels[#watchLabels + 1] = manifest.text.labels[label]
  end
  local seen = {}
  for _, friendship in ipairs({ 10, 60, 150, 250 }) do
    setMon(service, 0, function(mon)
      mon.friendship = friendship
    end)
    local text = memoText(build(service, 0).memo.blocks)
    local matched = false
    for _, label in ipairs(watchLabels) do
      if text:find(label, 1, true) ~= nil then
        matched = true
        seen[label] = true
      end
    end
    Assert.isTrue(matched, "friendship " .. friendship .. " reads authored watch text")
  end
  local distinct = 0
  for _ in pairs(seen) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct >= 2, "the watch thresholds change the authored wording")
  setMon(service, 0, function(mon)
    mon.origin.trainerId = 7
    mon.origin.trainerName = "BLUE"
  end)
  Assert.equal(build(service, 0).memo.condition, "eggTraded", "a traded egg reads its own branch")
end

function T.traded_gift_fateful_hatched_and_hatched_gift_records_keep_their_own_branches()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xB1B1B1B1)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE", 1)
  gift(service, "EEVEE")
  local hatchedGift = service:giveMon({
    species = "CHIKORITA",
    level = 1,
    heldItem = "NONE",
    form = 0,
    location = SummaryPresentationFixture.GIFT_LOCATION,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(hatchedGift, "setup gift must enter the party")
  local manifest = SummaryPresentationFixture.manifest()
  local function traded(edit)
    setMon(service, edit, function(mon)
      mon.origin.trainerId = 9
      mon.origin.trainerName = "BLUE"
    end)
  end
  setMon(service, 0, function(mon)
    mon.fatefulEncounter = true
    mon.origin.trainerId = 9
    mon.origin.trainerName = "BLUE"
  end)
  traded(1)
  setMon(service, 2, function(mon)
    mon.met.location = SummaryPresentationFixture.GIFT_LOCATION
    mon.origin.trainerId = 9
    mon.origin.trainerName = "BLUE"
  end)
  local fatefulTraded = build(service, 0)
  Assert.equal(fatefulTraded.memo.condition, "fatefulEncounterTraded", "a traded fateful record reads its own branch")
  Assert.notNil(
    lineMap(fatefulTraded.memo.blocks)[rule(manifest, "fatefulEncounterTraded").flavor],
    "the traded fateful flavor keeps its authored line"
  )
  local hatchedTraded = build(service, 1)
  Assert.equal(hatchedTraded.memo.condition, "eggHatchedTraded", "a traded level-one meeting reads hatched traded")
  local giftedTraded = build(service, 2)
  Assert.equal(giftedTraded.memo.condition, "wildGiftTraded", "a traded gift location reads its own branch")
  local giftedTradedDate = lineMap(giftedTraded.memo.blocks)[rule(manifest, "wildGiftTraded").date]
  Assert.isTrue(
    giftedTradedDate:find("SYN GIFT SHOP", 1, true) ~= nil,
    "the traded gift block names the gift landmark"
  )
  local giftedHatched = build(service, 3)
  Assert.equal(giftedHatched.memo.condition, "eggHatchedGift", "a level-one gift meeting reads hatched gift")
  local giftedHatchedDate = lineMap(giftedHatched.memo.blocks)[rule(manifest, "eggHatchedGift").date]
  Assert.isTrue(
    giftedHatchedDate:find("SYN GIFT SHOP", 1, true) ~= nil,
    "the hatched gift block names the gift landmark"
  )
end

return { tests = T }
