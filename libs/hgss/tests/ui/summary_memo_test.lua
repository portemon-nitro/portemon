-- Source encounter-memo selection, authored line placement, and egg
-- concealment over the live mon service. Every expectation reads the
-- ordered presentation rules, never renderer output: the memo must pick
-- the source branch from origin/met/egg/fateful values plus full-identity
-- ownership, keep authored line indices, expand the published date
-- templates, and never expose hatch-hidden battle detail. The memo is
-- exercised through the summary projection so the contract observes
-- missing behavior rather than module presence.

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
    local runs = {}
    for _, run in ipairs(block.runs) do
      runs[#runs + 1] = run.text or run.value or ""
    end
    parts[#parts + 1] = table.concat(runs)
  end
  return table.concat(parts, "\n")
end

local function findBranch(manifest, key)
  local conditions = assert(manifest.memo.conditions, "the family carries ordered memo rules")
  Assert.isTrue(type(conditions) == "table" and #conditions > 0, "the family carries ordered memo rules")
  for _, branch in ipairs(conditions) do
    if branch.key == key then
      return branch
    end
  end
  error("the family covers branch " .. tostring(key), 0)
end

local function labelOf(manifest, key)
  local text = manifest.text.labels[key]
  Assert.isTrue(type(text) == "string" and text ~= "", "the family resolves " .. tostring(key))
  return text
end

local function wildLocation(manifest)
  local wildByLocation = assert(manifest.memo.landmarks.wildByLocation, "the family carries wild landmarks")
  for location in pairs(wildByLocation) do
    Assert.isTrue(type(location) == "number", "wild locations are numeric")
    return location
  end
  error("the family carries a wild location", 0)
end

local function blockByLine(blocks, line)
  for _, block in ipairs(blocks) do
    if block.line == line then
      return block
    end
  end
  return nil
end

local function makeTraded()
  return function(mon)
    mon.origin.trainerId = 9
    mon.origin.trainerName = "BLUE"
  end
end

local function applyMemoFields(manifest, service, slot, fields)
  local locations = assert(manifest.memo.locations, "the family carries memo locations")
  setMon(service, slot, function(mon)
    if fields.isEgg ~= nil then
      mon.isEgg = fields.isEgg
    end
    if fields.fateful ~= nil then
      mon.fatefulEncounter = fields.fateful
    end
    if fields.traded ~= nil then
      if fields.traded then
        -- A different full identity that keeps the visible five digits,
        -- so branch selection proves ownership rather than the display id.
        mon.origin.trainerId = CatalogFixture.profile().trainerId % 65536
        mon.origin.trainerName = "BLUE"
      else
        local profile = CatalogFixture.profile()
        mon.origin.trainerId = profile.trainerId
        mon.origin.trainerName = profile.name
        mon.origin.trainerGender = profile.gender
      end
    end
    if fields.eggLocation ~= nil then
      local eggValue = fields.eggLocation
      if eggValue == "none" then
        mon.egg.location = 0
      elseif eggValue == "hatched" then
        mon.egg.location = wildLocation(manifest)
        if mon.egg.location == 0 then
          mon.egg.location = 7
        end
      elseif eggValue == "giftSet" then
        mon.egg.location = locations.giftEggOrigins[1]
      elseif eggValue == "linkTrade2" then
        mon.egg.location = locations.linkTrade2
      elseif eggValue == "ranger" then
        mon.egg.location = locations.ranger
      elseif eggValue == "egg" then
        mon.egg.location = 0
      else
        error("unknown egg location class " .. tostring(eggValue), 0)
      end
    end
    if fields.metLocation ~= nil then
      local metValue = fields.metLocation
      if metValue == "wild" then
        mon.met.location = wildLocation(manifest)
      elseif metValue == "linkTrade" then
        mon.met.location = locations.linkTrade
      elseif metValue == "palPark" then
        mon.met.location = locations.palPark
      else
        error("unknown met location class " .. tostring(metValue), 0)
      end
    end
    if fields.metLevel ~= nil then
      mon.met.level = fields.metLevel
    end
  end)
end

local function checkBranchLines(manifest, facts, key)
  local branch = findBranch(manifest, key)
  Assert.equal(facts.memo.condition, key, "the record reads its own branch")
  local lines = assert(branch.lines, "branches carry line placement")
  for _, name in ipairs({ "nature", "date", "characteristic", "flavor", "eggWatch" }) do
    local placement = assert(lines[name], "branches place " .. name)
    if placement > 0 then
      local text = lineMap(facts.memo.blocks)[placement]
      Assert.notNil(text, "the " .. key .. " " .. name .. " keeps its authored line")
      Assert.isTrue(#text > 0, "the " .. key .. " " .. name .. " carries text")
    end
  end
  return branch
end

function T.ownership_decides_the_branch_while_the_visible_id_stays_five_digits()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xA0A0A0A0)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  local profile = CatalogFixture.profile()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local mine = build(service, 0, nil, manifest)
  local branch = checkBranchLines(manifest, mine, "wildEncounter")
  Assert.equal(
    mine.info.otIdText,
    string.format("%05d", profile.trainerId % 65536),
    "the visible trainer id keeps five digits"
  )
  local lines = lineMap(mine.memo.blocks)
  Assert.notNil(lines[branch.lines.nature], "the ordinary wild nature opens its authored line")
  Assert.notNil(lines[branch.lines.date], "the ordinary wild date block is present")
  local wildKey = manifest.memo.landmarks.wildByLocation[wildLocation(manifest)]
  local wildSegments = assert(branch.dateTemplate, "the branch carries its date template").segments
  local wildBreaks = 0
  for _, segment in ipairs(wildSegments) do
    if segment.kind == "lineBreak" then
      wildBreaks = wildBreaks + 1
    end
  end
  local wildDated = {}
  for offset = 0, wildBreaks do
    wildDated[#wildDated + 1] = lines[branch.lines.date + offset] or ""
  end
  Assert.isTrue(
    table.concat(wildDated, "\n"):find(labelOf(manifest, wildKey), 1, true) ~= nil,
    "the date block names the wild landmark"
  )
  Assert.notNil(lines[branch.lines.characteristic], "the characteristic keeps its authored line")
  Assert.notNil(lines[branch.lines.flavor], "the flavor keeps its authored line")
  applyMemoFields(manifest, service, 0, { traded = true })
  local traded = build(service, 0, nil, manifest)
  Assert.equal(traded.info.otIdText, mine.info.otIdText, "the traded record shares the visible id")
  local tradedBranch = checkBranchLines(manifest, traded, "wildEncounterTraded")
  local tradedLines = lineMap(traded.memo.blocks)
  Assert.notNil(tradedLines[tradedBranch.lines.nature], "the traded branch keeps its own authored template")
  Assert.isTrue(memoText(traded.memo.blocks) ~= memoText(mine.memo.blocks), "ownership changes the authored wording")
end

function T.link_trade_meetings_keep_the_shared_branch_when_traded()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xB4B4B4B4)
  gift(service, "CHIKORITA")
  gift(service, "EEVEE")
  local manifest = SummaryPresentationFixture.manifest()
  local locations = manifest.memo.locations
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "linkTrade",
    metLevel = 5,
  })
  local mine = build(service, 0, nil, manifest)
  checkBranchLines(manifest, mine, "wildGift")
  local giftKey = manifest.memo.landmarks.giftByLocation[locations.linkTrade]
  if giftKey ~= nil then
    local branch = findBranch(manifest, "wildGift")
    local giftSegments = assert(branch.dateTemplate, "the branch carries its date template").segments
    local giftBreaks = 0
    for _, segment in ipairs(giftSegments) do
      if segment.kind == "lineBreak" then
        giftBreaks = giftBreaks + 1
      end
    end
    local dated = {}
    for offset = 0, giftBreaks do
      dated[#dated + 1] = lineMap(mine.memo.blocks)[branch.lines.date + offset] or ""
    end
    Assert.isTrue(
      table.concat(dated, "\n"):find(labelOf(manifest, giftKey), 1, true) ~= nil,
      "the gift block names the gift landmark"
    )
  end
  applyMemoFields(manifest, service, 1, {
    traded = true,
    fateful = false,
    eggLocation = "none",
    metLocation = "linkTrade",
    metLevel = 5,
  })
  local traded = build(service, 1, nil, manifest)
  Assert.equal(
    traded.memo.condition,
    "wildGift",
    "a traded link-trade meeting keeps the shared branch while the closure entry stays unselectable"
  )
  local selectable = nil
  for _, branch in ipairs(manifest.memo.conditions) do
    if branch.key == "wildGiftTraded" then
      selectable = branch.selectable
    end
  end
  Assert.equal(selectable, false, "the traded gift closure entry never selects")
end

function T.level_one_meetings_do_not_imply_hatching()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xB5B5B5B5)
  gift(service, "CHIKORITA", 1)
  gift(service, "EEVEE", 5)
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 1,
  })
  local wild = build(service, 0, nil, manifest)
  Assert.equal(wild.memo.condition, "wildEncounter", "a level-one wild meeting stays wild without egg origin")
  local locations = manifest.memo.locations
  applyMemoFields(manifest, service, 1, {
    traded = false,
    fateful = false,
    eggLocation = "giftSet",
    metLocation = "wild",
    metLevel = 5,
  })
  local hatched = build(service, 1, nil, manifest)
  Assert.equal(
    hatched.memo.condition,
    "eggHatchedGift",
    "a non-level-one meeting with gift egg origin reads hatched gift"
  )
  local branch = findBranch(manifest, "eggHatchedGift")
  local giftKey = manifest.memo.landmarks.giftByLocation[locations.linkTrade]
  if giftKey ~= nil then
    Assert.isTrue(
      (lineMap(hatched.memo.blocks)[branch.lines.date] or ""):find(labelOf(manifest, giftKey), 1, true) ~= nil
        or #(lineMap(hatched.memo.blocks)[branch.lines.date] or "") > 0,
      "the hatched gift date block carries text"
    )
  end
end

function T.migration_fateful_and_hatched_variants_follow_source_order()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xB0B0B0B0)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  gift(service, "EEVEE")
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  gift(service, "EEVEE")
  local manifest = SummaryPresentationFixture.manifest()
  -- Six party slots cover the eight branches in two rounds; every case
  -- keeps its authored branch and line assertions.
  local first = {
    { slot = 0, expect = "migrated", fields = { traded = false, fateful = false, eggLocation = "none", metLocation = "palPark", metLevel = 5 } },
    { slot = 1, expect = "fatefulEncounter", fields = { traded = false, fateful = true, eggLocation = "none", metLocation = "wild", metLevel = 5 } },
    { slot = 2, expect = "fatefulEncounterTraded", fields = { traded = true, fateful = true, eggLocation = "none", metLocation = "wild", metLevel = 5 } },
    { slot = 3, expect = "eggHatched", fields = { traded = false, fateful = false, eggLocation = "hatched", metLocation = "wild", metLevel = 5 } },
    { slot = 4, expect = "eggHatchedTraded", fields = { traded = true, fateful = false, eggLocation = "hatched", metLocation = "wild", metLevel = 5 } },
    { slot = 5, expect = "eggHatchedGift", fields = { traded = false, fateful = false, eggLocation = "giftSet", metLocation = "wild", metLevel = 5 } },
  }
  for _, kase in ipairs(first) do
    applyMemoFields(manifest, service, kase.slot, kase.fields)
  end
  for _, kase in ipairs(first) do
    local facts = build(service, kase.slot, nil, manifest)
    checkBranchLines(manifest, facts, kase.expect)
  end
  local second = {
    { slot = 0, expect = "fatefulEggHatched", fields = { traded = false, fateful = true, eggLocation = "hatched", metLocation = "wild", metLevel = 5 } },
    { slot = 1, expect = "fatefulEggHatchedArrived", fields = { traded = false, fateful = true, eggLocation = "ranger", metLocation = "wild", metLevel = 5 } },
  }
  for _, kase in ipairs(second) do
    applyMemoFields(manifest, service, kase.slot, kase.fields)
  end
  for _, kase in ipairs(second) do
    local facts = build(service, kase.slot, nil, manifest)
    checkBranchLines(manifest, facts, kase.expect)
  end
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "palPark",
    metLevel = 5,
  })
  local migrated = build(service, 0, nil, manifest)
  checkBranchLines(manifest, migrated, "migrated")
  Assert.isTrue(
    memoText(migrated.memo.blocks):find(tostring(manifest.memo.locations.palPark), 1, true) == nil,
    "the raw numeric id never leaks into wording"
  )
end

function T.fateful_link_trade_hatched_cases_follow_their_own_branches()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xB6B6B6B6)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = true,
    eggLocation = "linkTrade2",
    metLocation = "wild",
    metLevel = 5,
  })
  checkBranchLines(manifest, build(service, 0, nil, manifest), "fatefulEggHatchedGift")
  applyMemoFields(manifest, service, 1, {
    traded = true,
    fateful = true,
    eggLocation = "linkTrade2",
    metLocation = "wild",
    metLevel = 5,
  })
  checkBranchLines(manifest, build(service, 1, nil, manifest), "fatefulEggHatchedGiftTraded")
end

function T.current_eggs_follow_ownership_fateful_and_ranger_branches()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xE1E1E1E1)
  gift(service, "TOTODILE")
  gift(service, "CHIKORITA")
  gift(service, "EEVEE")
  gift(service, "TOTODILE")
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  local function makeEgg(slot, fields)
    setMon(service, slot, function(mon)
      mon.isEgg = true
      mon.moves = {}
    end)
    applyMemoFields(manifest, service, slot, fields)
  end
  makeEgg(0, { traded = false, fateful = false, eggLocation = "egg" })
  makeEgg(1, { traded = true, fateful = false, eggLocation = "egg" })
  makeEgg(2, { traded = false, fateful = true, eggLocation = "egg" })
  makeEgg(3, { traded = true, fateful = true, eggLocation = "egg" })
  makeEgg(4, { traded = false, fateful = true, eggLocation = "ranger" })
  local expectations = { "egg", "eggTraded", "fatefulEgg", "fatefulEggTraded", "fatefulEggArrived" }
  for slot, expect in ipairs(expectations) do
    local facts = build(service, slot - 1, nil, manifest)
    Assert.isTrue(facts.isEgg, "the egg flag is observed")
    checkBranchLines(manifest, facts, expect)
    Assert.deepEqual(facts.moves, {}, "eggs expose no battle-move rows")
    Assert.isNil(facts.skills, "eggs expose no skills content")
    Assert.isNil(facts.performance, "eggs expose no performance content")
    Assert.equal(facts.pictureKey, "EGG", "eggs resolve the declared egg picture")
  end
end

function T.date_templates_expand_through_generated_words_breaks_and_levels()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC4C4C4C4)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local wild = build(service, 0, nil, manifest)
  local wildBranch = findBranch(manifest, wild.memo.condition)
  local wildSegments = assert(wildBranch.dateTemplate, "the branch carries its date template").segments
  local wildBreaks = 0
  for _, segment in ipairs(wildSegments) do
    if segment.kind == "lineBreak" then
      wildBreaks = wildBreaks + 1
    end
  end
  local wildLines = lineMap(wild.memo.blocks)
  local wildDate = wildLines[wildBranch.lines.date]
  Assert.notNil(wildDate, "the wild date block is present")
  -- The date template carries source line breaks, so its landmark and
  -- level bindings live on the following source lines while no run
  -- carries a newline glyph.
  local dated = { wildDate }
  for offset = 1, wildBreaks do
    local text = wildLines[wildBranch.lines.date + offset]
    Assert.notNil(text, "the wild date keeps its source line " .. offset)
    dated[#dated + 1] = text
  end
  for _, block in ipairs(wild.memo.blocks) do
    for _, run in ipairs(block.runs) do
      Assert.isTrue(run.text:find("\n", 1, true) == nil, "line breaks never reach run text")
    end
  end
  dated = table.concat(dated, "\n")
  local wildLandmark = labelOf(manifest, manifest.memo.landmarks.wildByLocation[wildLocation(manifest)])
  Assert.isTrue(dated:find(wildLandmark, 1, true) ~= nil, "the wild date names the generated landmark")
  local metDate = CatalogFixture.metDate()
  Assert.isTrue(
    wildDate:find(labelOf(manifest, manifest.memo.months[metDate.month]), 1, true) ~= nil,
    "the wild date names the generated month"
  )
  Assert.isTrue(wildDate:find(tostring(metDate.day), 1, true) ~= nil, "the wild date names the meeting day")
  Assert.isTrue(dated:find("Lv.", 1, true) ~= nil, "the wild date expands the level binding from segments")
  Assert.isTrue(
    wildDate:find(tostring(service:partyMon(0).met.location), 1, true) == nil
      or wildLandmark:find(tostring(service:partyMon(0).met.location), 1, true) ~= nil,
    "the raw numeric id never leaks into wording"
  )
  local wildNature = lineMap(wild.memo.blocks)[wildBranch.lines.nature]
  Assert.notNil(wildNature, "the wild nature line is present")
  Assert.isTrue(wildNature:find(wildLandmark, 1, true) == nil, "the nature line carries no date wording")
  Assert.isTrue(wildNature:find("Lv.", 1, true) == nil, "the nature line carries no date template literal")
  gift(service, "TOTODILE")
  setMon(service, 1, function(mon)
    mon.isEgg = true
    mon.moves = {}
  end)
  applyMemoFields(manifest, service, 1, { traded = false, fateful = false, eggLocation = "egg" })
  local egg = build(service, 1, nil, manifest)
  local eggBranch = findBranch(manifest, egg.memo.condition)
  local watchLabels = {}
  for _, key in ipairs(manifest.memo.eggWatch.templates) do
    watchLabels[#watchLabels + 1] = labelOf(manifest, key)
  end
  local seen = {}
  for _, friendship in ipairs({ 10, 60, 150, 250 }) do
    setMon(service, 1, function(mon)
      mon.friendship = friendship
    end)
    local text = memoText(build(service, 1, nil, manifest).memo.blocks)
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
  local eggWatchLine = eggBranch.lines.eggWatch
  if eggWatchLine > 0 then
    local watchText = lineMap(egg.memo.blocks)[eggWatchLine]
    Assert.notNil(watchText, "the egg watch keeps its authored line")
    local oldHeader = nil
    for _, key in ipairs({ "synMemoWild", "synMemoEgg", "synMemoEggTraded" }) do
      local candidate = manifest.text.labels[key]
      if type(candidate) == "string" and watchText:find(candidate, 1, true) ~= nil then
        oldHeader = candidate
      end
    end
    Assert.isNil(oldHeader, "the egg watch carries no prepended header label")
  end
end

function T.template_segments_reject_unknown_kinds()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC5C5C5C5)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local valid = build(service, 0, nil, manifest)
  Assert.equal(valid.memo.condition, "wildEncounter", "the valid template builds its branch first")
  local broken = SummaryPresentationFixture.manifest()
  for _, branch in ipairs(broken.memo.conditions) do
    if branch.key == "wildEncounter" then
      branch.dateTemplate.segments[#branch.dateTemplate.segments + 1] = { kind = "bogusKind" }
    end
  end
  Assert.throws(function()
    build(service, 0, nil, broken)
  end, "an unknown template segment kind fails instead of guessing")
end

function T.unknown_landmarks_use_the_source_fallback_text()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC0C0C0C0)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  setMon(service, 0, function(mon)
    mon.met.location = SummaryPresentationFixture.UNKNOWN_LOCATION
  end)
  local facts = build(service, 0, nil, manifest)
  local text = memoText(facts.memo.blocks)
  Assert.isTrue(
    text:find(labelOf(manifest, manifest.memo.landmarks.fallback), 1, true) ~= nil,
    "an out-of-range location reads the fallback"
  )
  Assert.isTrue(text:find("60000", 1, true) == nil, "the raw numeric id never leaks into wording")
end

function T.characteristic_names_the_top_iv_while_flavor_follows_nature()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xD0D0D0D0)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  setMon(service, 0, function(mon)
    mon.ivs = { hp = 10, attack = 10, defense = 10, speed = 31, specialAttack = 10, specialDefense = 10 }
  end)
  local facts = build(service, 0, nil, manifest)
  local expected = labelOf(manifest, manifest.memo.characteristics[4][(31 % 5) + 1])
  Assert.isTrue(
    memoText(facts.memo.blocks):find(expected, 1, true) ~= nil,
    "the highest remainder names the speed characteristic"
  )
  local flavors = {}
  for _, label in ipairs(manifest.memo.flavors.byFlavor) do
    flavors[#flavors + 1] = labelOf(manifest, label)
  end
  flavors[#flavors + 1] = labelOf(manifest, manifest.memo.flavors.default)
  local text = memoText(facts.memo.blocks)
  local seen = false
  for _, flavor in ipairs(flavors) do
    if text:find(flavor, 1, true) ~= nil then
      seen = true
    end
  end
  Assert.isTrue(seen, "the flavor run comes from the source flavor set")
  gift(service, "TOTODILE")
  applyMemoFields(manifest, service, 1, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  setMon(service, 1, function(mon)
    mon.personality = service:partyMon(0).personality
  end)
  local sibling = build(service, 1, nil, manifest)
  local function flavorLine(blocks, condition)
    return lineMap(blocks)[findBranch(manifest, condition).lines.flavor]
  end
  local siblingFlavor = flavorLine(sibling.memo.blocks, sibling.memo.condition)
  local ownFlavor = flavorLine(facts.memo.blocks, facts.memo.condition)
  Assert.notNil(siblingFlavor, "the sibling flavor line is present")
  Assert.notNil(ownFlavor, "the own flavor line is present")
  Assert.equal(siblingFlavor, ownFlavor, "one nature keeps one flavor")
  setMon(service, 1, function(mon)
    mon.ivs = { hp = 31, attack = 5, defense = 5, speed = 5, specialAttack = 5, specialDefense = 31 }
  end)
  local tied = build(service, 1, nil, manifest)
  local tiedText = memoText(tied.memo.blocks)
  local hpLabel = labelOf(manifest, manifest.memo.characteristics[1][(31 % 5) + 1])
  local spDefenseLabel = labelOf(manifest, manifest.memo.characteristics[6][(31 % 5) + 1])
  Assert.isTrue(
    tiedText:find(hpLabel, 1, true) ~= nil or tiedText:find(spDefenseLabel, 1, true) ~= nil,
    "a tied top iv names one tied characteristic"
  )
  Assert.equal(memoText(build(service, 1, nil, manifest).memo.blocks), tiedText, "the tie order stays deterministic")
end

function T.traded_hatched_variants_keep_their_own_branches()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xB1B1B1B1)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  gift(service, "EEVEE")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = true,
    fateful = true,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local fatefulTraded = build(service, 0, nil, manifest)
  checkBranchLines(manifest, fatefulTraded, "fatefulEncounterTraded")
  applyMemoFields(manifest, service, 1, {
    traded = true,
    fateful = false,
    eggLocation = "hatched",
    metLocation = "wild",
    metLevel = 5,
  })
  local hatchedTraded = build(service, 1, nil, manifest)
  checkBranchLines(manifest, hatchedTraded, "eggHatchedTraded")
  applyMemoFields(manifest, service, 2, {
    traded = false,
    fateful = false,
    eggLocation = "giftSet",
    metLocation = "wild",
    metLevel = 5,
  })
  local giftedHatched = build(service, 2, nil, manifest)
  checkBranchLines(manifest, giftedHatched, "eggHatchedGift")
end

function T.unknown_predicates_and_classes_fail_before_matching()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC6C6C6C6)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local valid = build(service, 0, nil, manifest)
  Assert.equal(valid.memo.condition, "wildEncounter", "the valid rules match their branch first")
  local bogusPredicate = SummaryPresentationFixture.manifest()
  bogusPredicate.memo.conditions[1].match = { isEgg = false, fateful = false, bogusPredicate = true }
  Assert.throws(function()
    build(service, 0, nil, bogusPredicate)
  end, "an unknown predicate key fails instead of constraining nothing")
  local bogusClass = SummaryPresentationFixture.manifest()
  bogusClass.memo.conditions[1].match = { isEgg = false, fateful = false, eggLocation = "bogusClass" }
  Assert.throws(function()
    build(service, 0, nil, bogusClass)
  end, "an unknown location class fails instead of matching nothing")
end

function T.mons_without_a_selectable_branch_fail_instead_of_guessing()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC7C7C7C7)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local valid = build(service, 0, nil, manifest)
  Assert.equal(valid.memo.condition, "wildEncounter", "the valid rules match their branch first")
  local eggOnly = SummaryPresentationFixture.manifest()
  local only = {}
  for _, branch in ipairs(eggOnly.memo.conditions) do
    if branch.key == "egg" then
      only[#only + 1] = branch
    end
  end
  Assert.equal(#only, 1, "the egg branch is present")
  eggOnly.memo.conditions = only
  Assert.throws(function()
    build(service, 0, nil, eggOnly)
  end, "a mon without a selectable branch fails instead of guessing wild")
end

function T.memo_blocks_are_owned_values_detached_from_later_refreshes()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC8C8C8C8)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local first = build(service, 0, nil, manifest)
  local blockCount = #first.memo.blocks
  Assert.isTrue(blockCount >= 1, "the memo carries blocks")
  first.memo.blocks[1].runs[1].text = "MUTATED"
  first.memo.blocks[1].runs[1].ink = "MUTATED"
  first.memo.condition = "MUTATED"
  local second = build(service, 0, nil, manifest)
  Assert.equal(#second.memo.blocks, blockCount, "mutating blocks never leaks into later refreshes")
  Assert.isTrue(
    memoText(second.memo.blocks):find("MUTATED", 1, true) == nil,
    "mutating run text reaches no later refresh"
  )
  for _, block in ipairs(second.memo.blocks) do
    for _, run in ipairs(block.runs) do
      Assert.isTrue(run.ink ~= "MUTATED", "mutating run ink reaches no later refresh")
    end
  end
  Assert.equal(second.memo.condition, "wildEncounter", "the branch stays authoritative after local mutation")
end

-- The migrated region wording comes from the game-keyed producer mapping,
-- never from gift-bank packing: the memo prints the mapped wording, and
-- repointing the mapping moves the wording with it.
function T.migrated_region_wording_comes_from_the_game_keyed_mapping()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC0C0C0C0)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "palPark",
    metLevel = 5,
  })
  local facts = build(service, 0, nil, manifest)
  Assert.equal(facts.memo.condition, "migrated", "the record reads its migrated branch")
  local regions = assert(manifest.memo.migrationRegions, "the family carries migration regions")
  Assert.equal(regions.heartgold, regions.soulsilver, "both supported games bind the Johto wording")
  Assert.isTrue(
    memoText(facts.memo.blocks):find(labelOf(manifest, regions.heartgold), 1, true) ~= nil,
    "the migrated region prints the mapped wording"
  )
  manifest.memo.migrationRegions.heartgold = "synLandmarkGift"
  local remapped = build(service, 0, nil, manifest)
  Assert.isTrue(
    memoText(remapped.memo.blocks):find(labelOf(manifest, "synLandmarkGift"), 1, true) ~= nil,
    "the migrated region follows the game mapping, not packed ids"
  )
end

-- Generated line breaks are geometric: each one opens a new absolute
-- memo baseline with the active ink carried over, so no published run
-- may contain a newline glyph. The exercised wild template carries two
-- source breaks, so its date wording must span three baselines.
function T.date_line_breaks_open_their_own_baselines_without_newline_glyphs()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xA11CE101)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local facts = build(service, 0, nil, manifest)
  Assert.equal(facts.memo.condition, "wildEncounter", "the ordinary wild meeting keeps its branch")
  local branch = findBranch(manifest, facts.memo.condition)
  local segments = assert(branch.dateTemplate, "the branch carries its date template").segments
  Assert.isTrue(type(segments) == "table" and #segments >= 1, "the date template carries segments")
  local breaks = 0
  for _, segment in ipairs(segments) do
    if segment.kind == "lineBreak" then
      breaks = breaks + 1
    end
  end
  Assert.isTrue(breaks >= 1, "the exercised template carries source line breaks")
  for _, block in ipairs(facts.memo.blocks) do
    for _, run in ipairs(block.runs) do
      Assert.isTrue(type(run.text) == "string" and #run.text > 0, "runs carry single-line text")
      Assert.isTrue(run.text:find("\n", 1, true) == nil, "line breaks never reach run text")
    end
  end
  local base = assert(branch.lines.date, "the branch places its date line")
  for offset = 0, breaks do
    Assert.notNil(
      blockByLine(facts.memo.blocks, base + offset),
      "break " .. offset .. " opens its own baseline"
    )
  end
end

local function openServiceForGame(catalog, seed, game)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
    profile = CatalogFixture.profile(),
    game = game,
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

-- Every canonical origin game renders its generated arrival-region
-- wording through the producer map, never through a HeartGold/SoulSilver
-- assertion. Region classes mirror the source mapping with invented
-- test wording; the contract proved here is lookup without a runtime
-- game switch, plus a loud game-named failure for a missing mapping.
function T.every_canonical_origin_renders_its_generated_migration_wording()
  local regions = {
    sapphire = "synRegionHoenn",
    ruby = "synRegionHoenn",
    emerald = "synRegionHoenn",
    firered = "synRegionKanto",
    leafgreen = "synRegionKanto",
    heartgold = "synLandmarkJohto",
    soulsilver = "synLandmarkJohto",
    diamond = "synRegionDashes",
    pearl = "synRegionDashes",
    platinum = "synRegionDashes",
    gamecube = "synRegionDistant",
  }
  local games = {}
  for game in pairs(regions) do
    Assert.notNil(CatalogFixture.GAMES[game], "the canonical domain covers " .. game)
    games[#games + 1] = game
  end
  table.sort(games)
  local catalog = CatalogFixture.makeCatalog()
  local seed = 0xA11CE103
  for _, game in ipairs(games) do
    seed = seed + 1
    local service = openServiceForGame(catalog, seed, game)
    gift(service, "CHIKORITA")
    local manifest = SummaryPresentationFixture.manifest()
    manifest.text.labels["synRegionKanto"] = "SYN KANTO"
    manifest.text.labels["synRegionHoenn"] = "SYN HOENN"
    manifest.text.labels["synRegionDistant"] = "SYN DISTANT LAND"
    manifest.text.labels["synRegionDashes"] = "SYN ---"
    local mapping = {}
    for name, key in pairs(regions) do
      mapping[name] = key
    end
    manifest.memo.migrationRegions = mapping
    applyMemoFields(manifest, service, 0, {
      traded = false,
      fateful = false,
      eggLocation = "none",
      metLocation = "palPark",
      metLevel = 5,
    })
    local facts = build(service, 0, nil, manifest)
    Assert.equal(facts.memo.condition, "migrated", game .. " reads the migrated branch")
    Assert.isTrue(
      memoText(facts.memo.blocks):find(labelOf(manifest, regions[game]), 1, true) ~= nil,
      game .. " prints its generated region wording"
    )
  end
  local service = openService(catalog, 0xA11CE104)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  manifest.memo.migrationRegions.heartgold = nil
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "palPark",
    metLevel = 5,
  })
  local ok, err = pcall(build, service, 0, nil, manifest)
  Assert.isFalse(ok, "a missing migration mapping fails instead of guessing")
  Assert.isTrue(
    tostring(err):find("heartgold", 1, true) ~= nil,
    "the failure names the origin game"
  )
end

-- Builds the ordinary wild meeting while swapping the branch date
-- template for synthetic control segments, so break/color geometry is
-- proved without depending on the fixture wording.
local function setMeetingYear(service, slot, year)
  setMon(service, slot, function(mon)
    mon.met.date.year = year
  end)
end

-- A year-bearing arrival template mirroring the migrated date shape
-- (month, day, year substitution, then the arrival region), so the
-- arrival branch selection stays production while the year substitution
-- is isolated exactly like the wild and hatched templates isolate it.
local function arrivalYearSegments()
  return {
    { kind = "text", value = "SYN " },
    { kind = "metMonth" },
    { kind = "text", value = " SYN " },
    { kind = "metDay" },
    { kind = "text", value = ", 20" },
    { kind = "metYear" },
    { kind = "lineBreak" },
    { kind = "migrationRegion" },
    { kind = "lineBreak" },
    { kind = "text", value = "SYN arrived at Lv. " },
    { kind = "metLevel" },
    { kind = "text", value = "." },
  }
end
local function buildWithDateSegments(service, manifest, segments)
  for _, branch in ipairs(manifest.memo.conditions) do
    if branch.key == "wildEncounter" then
      branch.dateTemplate = { segments = segments }
    end
  end
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local facts = build(service, 0, nil, manifest)
  Assert.equal(facts.memo.condition, "wildEncounter", "the synthetic template keeps its branch")
  return facts.memo.blocks
end

-- Two back-to-back breaks advance two source lines: the authored empty
-- line in the middle carries no block and no run, while the text
-- around it lands on its own baselines.
function T.consecutive_line_breaks_skip_an_empty_source_line_without_empty_runs()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xA11CE10A)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  local base = findBranch(manifest, "wildEncounter").lines.date
  local blocks = buildWithDateSegments(service, manifest, {
    { kind = "text", value = "SYN A" },
    { kind = "lineBreak" },
    { kind = "lineBreak" },
    { kind = "text", value = "SYN B" },
  })
  Assert.isNil(blockByLine(blocks, base + 1), "the authored empty line carries no block")
  local first = blockByLine(blocks, base)
  Assert.notNil(first, "the text before the breaks keeps its source line")
  Assert.equal(#first.runs, 1, "the first line carries one run")
  Assert.equal(first.runs[1].text, "SYN A", "the first line keeps its text")
  local last = blockByLine(blocks, base + 2)
  Assert.notNil(last, "the text after the breaks advances two source lines")
  Assert.equal(#last.runs, 1, "the last line carries one run")
  Assert.equal(last.runs[1].text, "SYN B", "the last line keeps its text")
  for _, block in ipairs(blocks) do
    for _, run in ipairs(block.runs) do
      Assert.isTrue(type(run.text) == "string" and #run.text > 0, "runs carry single-line text")
      Assert.isTrue(run.text:find("\n", 1, true) == nil, "line breaks never reach run text")
    end
  end
end

-- The ink selected before a break stays active on the next source
-- line: the run after the break prints through the pre-break ink.
function T.the_active_ink_carries_over_a_line_break()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xA11CE10B)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  local base = findBranch(manifest, "wildEncounter").lines.date
  local blocks = buildWithDateSegments(service, manifest, {
    { kind = "text", value = "SYN A" },
    { kind = "color", color = 7 },
    { kind = "text", value = "SYN B" },
    { kind = "lineBreak" },
    { kind = "text", value = "SYN C" },
  })
  local first = blockByLine(blocks, base)
  Assert.notNil(first, "the text before the break keeps its source line")
  Assert.equal(#first.runs, 2, "the color change splits the first line")
  Assert.equal(first.runs[2].ink, "slot7", "the color change selects its ink")
  local second = blockByLine(blocks, base + 1)
  Assert.notNil(second, "the text after the break opens its own source line")
  Assert.equal(#second.runs, 1, "the second line carries one run")
  Assert.equal(second.runs[1].text, "SYN C", "the second line keeps its text")
  Assert.equal(second.runs[1].ink, "slot7", "the pre-break ink carries over the break")
end

-- A color change alone splits the ink without inserting text: no
-- empty run appears on either side of the boundary.
function T.a_color_change_alone_creates_no_empty_run()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xA11CE10C)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  local base = findBranch(manifest, "wildEncounter").lines.date
  local blocks = buildWithDateSegments(service, manifest, {
    { kind = "text", value = "SYN A" },
    { kind = "color", color = 7 },
    { kind = "text", value = "SYN B" },
  })
  local first = blockByLine(blocks, base)
  Assert.notNil(first, "the one-line template keeps its source line")
  Assert.equal(#first.runs, 2, "the color change splits one line into two runs")
  for _, run in ipairs(first.runs) do
    Assert.isTrue(type(run.text) == "string" and #run.text > 0, "no empty run appears at the ink boundary")
  end
  Assert.equal(first.runs[1].ink, "ordinary", "the text before the change keeps its ink")
  Assert.equal(first.runs[2].ink, "slot7", "the text after the change takes the new ink")
end

-- A template without breaks keeps its previous shape exactly: one
-- block on the branch base line with adjacent same-ink text coalesced
-- into one run.
function T.one_line_templates_keep_their_single_block_shape()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xA11CE10D)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  local base = findBranch(manifest, "wildEncounter").lines.date
  local blocks = buildWithDateSegments(service, manifest, {
    { kind = "text", value = "SYN " },
    { kind = "metLevel" },
    { kind = "text", value = "." },
  })
  local dated = blockByLine(blocks, base)
  Assert.notNil(dated, "the one-line template produces its block")
  Assert.equal(#dated.runs, 1, "adjacent same-ink text coalesces into one run")
  Assert.equal(dated.runs[1].text, "SYN 5.", "the one-line template keeps its wording")
  Assert.equal(dated.runs[1].ink, "ordinary", "the one-line template keeps its ink")
end

-- Encounter dates render the stored year as a two-character
-- zero-padded value: the century prefix in the template wording stays
-- literal while the substitution carries only the stored year offset.
-- The stored meeting date keeps its full canonical year.
function T.encounter_years_render_as_two_digit_values_while_the_stored_date_keeps_full_years()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xE40701)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  applyMemoFields(manifest, service, 1, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local monthWord = labelOf(manifest, manifest.memo.months[9])
  local cases = {
    { slot = 0, year = 2009, suffix = "09" },
    { slot = 1, year = 2026, suffix = "26" },
  }
  for _, kase in ipairs(cases) do
    setMeetingYear(service, kase.slot, kase.year)
    local facts = build(service, kase.slot, nil, manifest)
    Assert.equal(facts.memo.condition, "wildEncounter", "the ordinary meeting keeps its branch")
    local branch = findBranch(manifest, facts.memo.condition)
    local lines = lineMap(facts.memo.blocks)
    Assert.equal(
      lines[branch.lines.date],
      "SYN " .. monthWord .. " SYN 13, 20" .. kase.suffix,
      "the meeting year renders its two-digit value"
    )
    Assert.isTrue(
      (lines[branch.lines.date] or ""):find(", 20" .. kase.year, 1, true) == nil,
      "the full stored year never reaches the memo text"
    )
    local dated = blockByLine(facts.memo.blocks, branch.lines.date)
    Assert.notNil(dated, "the date line keeps its authored position")
    for _, run in ipairs(dated.runs) do
      Assert.equal(run.ink, "ordinary", "the date line keeps its ink")
    end
    Assert.isTrue(
      memoText(facts.memo.blocks):find("SYN met at Lv. 5.", 1, true) ~= nil,
      "the surrounding level wording stays unchanged"
    )
    Assert.equal(
      service:partyMon(kase.slot).met.date.year,
      kase.year,
      "the stored meeting date keeps its full year"
    )
  end
end

-- Hatched and arrival dates share the same two-digit year rule: the egg
-- substitution and the arrival meeting substitution both render the
-- stored year offset with a leading zero, while each record keeps its
-- own branch and the stored dates keep full years.
function T.hatched_and_arrival_years_share_the_two_digit_rule_without_changing_branches()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xE40702)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local manifest = SummaryPresentationFixture.manifest()
  for _, branch in ipairs(manifest.memo.conditions) do
    if branch.key == "migrated" then
      branch.dateTemplate = { segments = arrivalYearSegments() }
    end
  end
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "giftSet",
    metLocation = "wild",
    metLevel = 5,
  })
  applyMemoFields(manifest, service, 1, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "palPark",
    metLevel = 5,
  })
  local monthWord = labelOf(manifest, manifest.memo.months[9])
  setMeetingYear(service, 0, 2000)
  local hatched = build(service, 0, nil, manifest)
  Assert.equal(hatched.memo.condition, "eggHatchedGift", "the hatched gift keeps its branch")
  local hatchedBranch = findBranch(manifest, hatched.memo.condition)
  local hatchedLines = lineMap(hatched.memo.blocks)
  Assert.equal(
    hatchedLines[hatchedBranch.lines.date],
    "SYN " .. monthWord .. " SYN 13, 2000",
    "the hatched year renders its two-digit value"
  )
  Assert.isTrue(
    (hatchedLines[hatchedBranch.lines.date] or ""):find(", 202000", 1, true) == nil,
    "the full stored year never reaches the hatched text"
  )
  Assert.equal(service:partyMon(0).met.date.year, 2000, "the stored hatched date keeps its full year")
  setMeetingYear(service, 1, 2009)
  local arrived = build(service, 1, nil, manifest)
  Assert.equal(arrived.memo.condition, "migrated", "the arrival keeps its branch")
  local arrivedBranch = findBranch(manifest, arrived.memo.condition)
  local arrivedLines = lineMap(arrived.memo.blocks)
  Assert.equal(
    arrivedLines[arrivedBranch.lines.date],
    "SYN " .. monthWord .. " SYN 13, 2009",
    "the arrival year renders its two-digit value"
  )
  Assert.isTrue(
    (arrivedLines[arrivedBranch.lines.date] or ""):find(", 202009", 1, true) == nil,
    "the full stored year never reaches the arrival text"
  )
  Assert.isTrue(
    memoText(arrived.memo.blocks):find(labelOf(manifest, manifest.memo.migrationRegions.heartgold), 1, true)
      ~= nil,
    "the arrival region wording stays unchanged"
  )
  Assert.equal(service:partyMon(1).met.date.year, 2009, "the stored arrival date keeps its full year")
end

-- Year suffixes stay exact across the century edges: early, recent, and
-- late offsets keep two digits with leading zeros, while offsets past
-- two digits keep their full width instead of wrapping the century.
function T.year_suffixes_keep_their_width_across_the_century_edges()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xE40703)
  gift(service, "CHIKORITA")
  local manifest = SummaryPresentationFixture.manifest()
  applyMemoFields(manifest, service, 0, {
    traded = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "wild",
    metLevel = 5,
  })
  local monthWord = labelOf(manifest, manifest.memo.months[9])
  local cases = {
    { year = 2000, suffix = "00" },
    { year = 2009, suffix = "09" },
    { year = 2010, suffix = "10" },
    { year = 2026, suffix = "26" },
    { year = 2099, suffix = "99" },
    { year = 2100, suffix = "100" },
  }
  for _, kase in ipairs(cases) do
    setMeetingYear(service, 0, kase.year)
    local facts = build(service, 0, nil, manifest)
    Assert.equal(facts.memo.condition, "wildEncounter", "the ordinary meeting keeps its branch")
    local branch = findBranch(manifest, facts.memo.condition)
    Assert.equal(
      lineMap(facts.memo.blocks)[branch.lines.date],
      "SYN " .. monthWord .. " SYN 13, 20" .. kase.suffix,
      "stored year " .. kase.year .. " renders its offset"
    )
    Assert.equal(service:partyMon(0).met.date.year, kase.year, "the stored date keeps its full year")
  end
end

return { tests = T }
