-- Consumption proof for the summary projection over the prepared native
-- family: the compiled heartgold manifest drives facts for every reachable
-- memo branch, real ribbon bindings including the normalized special slots,
-- and the native bar widths. Synthetic party service, prepared manifest;
-- no committed commercial payloads, only relationships and source facts.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local RomImporter = require("romdump.src.source.RomImporter")
local SummaryCache = require("libs.assets.src.SummaryCache")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")

local T = {
  metadata = { capabilities = { "rom_dump", "derived_assets" }, derivedAssets = { "summary:global" } },
  tests = {},
}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(SummaryCache.markerPath())
      if marker ~= nil and SummaryCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x5A5A5A5A):capture(), catalog:fingerprint()),
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

local function give(service, species, level, location)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = level,
      heldItem = "NONE",
      form = 0,
      location = location,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

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

local function build(service, slot, manifest, context)
  local facts = SummaryModel.build(
    service,
    slot,
    context or SummaryPresentationFixture.context(service:partyCount()),
    manifest
  )
  Assert.notNil(facts.memo, "the projection carries the source memo over the prepared family")
  Assert.notNil(facts.info, "the projection carries native info over the prepared family")
  return facts
end

local function memoText(blocks)
  local parts = {}
  for _, block in ipairs(blocks) do
    for _, run in ipairs(block.runs) do
      parts[#parts + 1] = run.text or run.value or ""
    end
  end
  return table.concat(parts, "\n")
end

local function lineMap(blocks)
  local map = {}
  for _, block in ipairs(blocks) do
    local parts = {}
    for _, run in ipairs(block.runs) do
      parts[#parts + 1] = run.text or run.value or ""
    end
    map[block.line] = table.concat(parts)
  end
  return map
end

local function containsAny(haystack, needles)
  for _, needle in ipairs(needles) do
    if haystack:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function labelOf(manifest, key)
  local text = manifest.text.labels[key]
  Assert.isTrue(type(text) == "string" and text ~= "", "the prepared family resolves " .. tostring(key))
  return text
end

function T.tests.prepared_native_family_drives_facts(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("summary consumption needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = SummaryCache.loadManifest(cacheFs)
    local service = openService()
    give(service, "CHIKORITA", 5, 7)
    give(service, "CHIKORITA", 100, 7)
    give(service, "TOTODILE", 1, 7)

    local mine = build(service, 0, manifest)
    Assert.equal(mine.memo.condition, "wildEncounter", "the own wild record reads its own branch")
    local wildRule = assert(manifest.memo.conditions.wildEncounter, "the prepared family covers wildEncounter")
    local wildLines = lineMap(mine.memo.blocks)
    Assert.isTrue(#(wildLines[wildRule.nature] or "") > 0, "the wild nature line carries text")
    local wildLandmark = labelOf(manifest, manifest.memo.landmarks.wildByLocation[7])
    Assert.isTrue(
      (wildLines[wildRule.date] or ""):find(wildLandmark, 1, true) ~= nil,
      "the wild date block names the prepared landmark"
    )
    local metDate = CatalogFixture.metDate()
    local monthLabel = labelOf(manifest, manifest.memo.months[metDate.month])
    Assert.isTrue(
      (wildLines[wildRule.date] or ""):find(monthLabel, 1, true) ~= nil,
      "the wild date block names the prepared month"
    )
    local characteristics = {}
    for _, row in pairs(manifest.memo.characteristics) do
      for _, key in ipairs(row) do
        characteristics[#characteristics + 1] = labelOf(manifest, key)
      end
    end
    Assert.isTrue(
      containsAny(memoText(mine.memo.blocks), characteristics),
      "the wild memo resolves a prepared characteristic"
    )
    local flavors = { labelOf(manifest, manifest.memo.flavors.default) }
    for _, key in ipairs(manifest.memo.flavors.byFlavor) do
      flavors[#flavors + 1] = labelOf(manifest, key)
    end
    Assert.equal(mine.skills.hpBar.length, 48, "full health spans the native health width")
    Assert.equal(mine.skills.hpBar.color, "high", "full health reads the high color")
    Assert.isTrue(
      mine.info.expBar.length >= 0 and mine.info.expBar.length <= 56,
      "experience pixels stay inside the native experience width"
    )
    Assert.isTrue(mine.revision ~= nil, "the snapshot carries its party revision")
    Assert.isTrue(mine.contextKey ~= nil, "the snapshot carries its context key")

    setMon(service, 0, function(mon)
      mon.personality = 1
    end)
    local lonely = build(service, 0, manifest)
    Assert.isTrue(
      containsAny(memoText(lonely.memo.blocks), flavors),
      "a raised stat resolves a prepared flavor"
    )
    setMon(service, 0, function(mon)
      mon.origin.trainerId = 9
      mon.origin.trainerName = "BLUE"
    end)
    local traded = build(service, 0, manifest)
    Assert.equal(traded.memo.condition, "wildEncounterTraded", "a differing full identity reads traded")
    Assert.isTrue(
      memoText(traded.memo.blocks) ~= memoText(lonely.memo.blocks),
      "ownership changes the prepared wording"
    )

    local hatched = build(service, 2, manifest)
    Assert.equal(hatched.memo.condition, "eggHatched", "meeting at level one reads hatched")
    local hatchedRule = assert(manifest.memo.conditions.eggHatched, "the prepared family covers eggHatched")
    Assert.notNil(
      lineMap(hatched.memo.blocks)[hatchedRule.characteristic],
      "the hatched characteristic keeps its prepared line"
    )
    Assert.notNil(lineMap(hatched.memo.blocks)[hatchedRule.flavor], "the hatched flavor keeps its prepared line")

    setMon(service, 0, function(mon)
      mon.origin.trainerId = CatalogFixture.profile().trainerId
      mon.origin.trainerName = CatalogFixture.profile().name
      mon.met.location = 4001
    end)
    local gifted = build(service, 0, manifest)
    Assert.equal(gifted.memo.condition, "wildGift", "the gift range selects its template")
    local giftLandmark = labelOf(manifest, manifest.memo.landmarks.giftByLocation[4001])
    Assert.isTrue(
      memoText(gifted.memo.blocks):find(giftLandmark, 1, true) ~= nil,
      "the gift block names the prepared gift landmark"
    )
    setMon(service, 0, function(mon)
      mon.origin.trainerId = 9
      mon.origin.trainerName = "BLUE"
    end)
    local giftedTraded = build(service, 0, manifest)
    Assert.equal(giftedTraded.memo.condition, "wildGiftTraded", "a traded gift keeps a resolvable branch")

    setMon(service, 0, function(mon)
      mon.origin.trainerId = CatalogFixture.profile().trainerId
      mon.origin.trainerName = CatalogFixture.profile().name
      mon.met.location = 2001
    end)
    local linked = build(service, 0, manifest)
    Assert.isTrue(
      memoText(linked.memo.blocks):find(labelOf(manifest, manifest.memo.landmarks.wildByLocation[2001]), 1, true)
        ~= nil,
      "the source gift range resolves its prepared landmark"
    )
    setMon(service, 0, function(mon)
      mon.met.location = 3001
    end)
    Assert.isTrue(
      memoText(build(service, 0, manifest).memo.blocks):find(
        labelOf(manifest, manifest.memo.landmarks.wildByLocation[3001]),
        1,
        true
      ) ~= nil,
      "the source external range resolves its prepared landmark"
    )
    setMon(service, 0, function(mon)
      mon.met.location = 60000
    end)
    local faraway = memoText(build(service, 0, manifest).memo.blocks)
    Assert.isTrue(
      faraway:find(labelOf(manifest, manifest.memo.landmarks.fallback), 1, true) ~= nil,
      "an out-of-range location reads the prepared fallback"
    )
    Assert.isTrue(faraway:find("60000", 1, true) == nil, "the raw numeric id never leaks into wording")

    setMon(service, 0, function(mon)
      mon.met.location = 0
    end)
    Assert.equal(build(service, 0, manifest).memo.condition, "migrated", "the pal-park location selects migration")
    local plain = build(service, 0, manifest)
    setMon(service, 0, function(mon)
      mon.met.location = 7
      mon.fatefulEncounter = true
    end)
    local fateful = build(service, 0, manifest)
    Assert.equal(fateful.memo.condition, "fatefulEncounter", "the fateful flag selects its branch")
    Assert.isTrue(
      memoText(fateful.memo.blocks) ~= memoText(plain.memo.blocks),
      "the fateful branch keeps its own prepared wording"
    )

    setMon(service, 0, function(mon)
      mon.condition.currentHp = 1
    end)
    local hanging = build(service, 0, manifest).skills.hpBar.length
    Assert.isTrue(hanging >= 1 and hanging < 48, "one health keeps a partial positive fill")
    setMon(service, 0, function(mon)
      mon.condition.currentHp = 0
    end)
    Assert.equal(build(service, 0, manifest).skills.hpBar.length, 0, "no health fills no pixels")
    local capped = build(service, 1, manifest)
    Assert.equal(capped.info.expToNext, 0, "level 100 keeps the source zero-to-next value")
    Assert.equal(capped.info.expBar.length, 0, "level 100 fills no experience pixels")

    local marine = nil
    local cool = nil
    for _, entry in ipairs(manifest.ribbons.entries) do
      if entry.key == "marine_ribbon" then
        marine = entry
      elseif entry.key == "cool_ribbon" then
        cool = entry
      end
    end
    Assert.notNil(marine, "the prepared family defines the special ribbon")
    Assert.notNil(cool, "the prepared family defines the ordinary ribbon")
    Assert.isTrue(type(marine.special) == "number", "the special ribbon carries its normalized slot")
    setMon(service, 2, function(mon)
      mon.ribbons = {
        ds1 = 0,
        gba = 2 ^ marine.bit + 2 ^ cool.bit,
        ds2 = 0,
      }
    end)
    local earned = build(service, 2, manifest).ribbons
    local function byKey(ribbons, key)
      for _, entry in ipairs(ribbons) do
        if entry.key == key then
          return entry
        end
      end
      error("earned ribbons carry " .. key, 0)
    end
    local specialContext = SummaryPresentationFixture.context(service:partyCount())
    local facts = SummaryModel.build(service, 2, specialContext, manifest)
    Assert.equal(
      byKey(facts.ribbons, "marine_ribbon").description,
      specialContext.specialRibbonDescriptions[marine.special],
      "the normalized special slot resolves through the context"
    )
    Assert.equal(
      byKey(facts.ribbons, "cool_ribbon").description,
      labelOf(manifest, cool.description),
      "the ordinary ribbon resolves its prepared description"
    )
    Assert.isTrue(#earned > 0, "earned ribbons resolve over the prepared family")

    setMon(service, 0, function(mon)
      mon.isEgg = true
      mon.moves = {}
      mon.fatefulEncounter = false
    end)
    local egg = build(service, 0, manifest)
    Assert.equal(egg.memo.condition, "egg", "the unhatched record reads the egg branch")
    Assert.deepEqual(egg.moves, {}, "eggs expose no battle-move rows over the prepared family")
    local watch = {}
    for _, key in ipairs(manifest.memo.eggWatch.templates) do
      watch[#watch + 1] = labelOf(manifest, key)
    end
    Assert.isTrue(containsAny(memoText(egg.memo.blocks), watch), "the egg reads prepared watch text")
  end
end

return T
