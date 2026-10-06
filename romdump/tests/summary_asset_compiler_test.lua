-- Producer-side contract for the native summary presentation family: the
-- registered derived family identity, the producer source catalog, the
-- compiler boundaries, and the strict consumer schema. Every fact pinned
-- here is a current structural requirement of that family; no committed
-- commercial payloads appear.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")

local T = {}

local SUMMARY_FORMAT = "g4-summary-cache-v1"
local SUMMARY_SCHEMA = "g4-summary-manifest-v3"

local function requireSources()
  local ok, sources = pcall(require, "romdump.src.config.SummarySources")
  Assert.isTrue(ok, "the summary source catalog is missing: native ui/metadata/motion roles have no producer owner")
  return assert(sources)
end

local function requireCompiler()
  local ok, compiler = pcall(require, "romdump.src.digest.ui.SummaryAssetCompiler")
  Assert.isTrue(ok, "the summary asset compiler is missing: native backgrounds/windows/text have no lowering owner")
  Assert.equal(type(compiler.compile), "function", "the summary asset compiler exposes its compile entrypoint")
  return compiler
end

local function requireSchema()
  local ok, schema = pcall(require, "libs.assets.src.SummaryAssetSchema")
  Assert.isTrue(ok, "the summary consumer schema is missing: no strict gate owns the family envelope")
  Assert.equal(type(schema.assertManifest), "function", "the summary schema exposes its manifest assertion")
  return schema
end

local function requireCache()
  local ok, cache = pcall(require, "libs.assets.src.SummaryCache")
  Assert.isTrue(ok, "the summary consumer cache is missing: no reader owns family paths and readiness")
  for _, name in ipairs({
    "dir",
    "assetDir",
    "manifestPath",
    "provenancePath",
    "markerPath",
    "marker",
    "loadManifest",
    "referencedPaths",
    "isReady",
  }) do
    Assert.equal(type(cache[name]), "function", "the summary cache exposes " .. name)
  end
  return cache
end

-- The family is registered centrally without touching the existing mon,
-- party, or bag identities.
function T.derived_contract_registers_the_summary_family()
  local summary = DerivedAssetContract.summary
  Assert.notNil(summary, "the derived contract carries no summary family")
  Assert.equal(summary.cacheFormat, SUMMARY_FORMAT, "the summary family carries its cache format")
  Assert.equal(summary.schema, SUMMARY_SCHEMA, "the summary family carries its manifest schema")
  Assert.notNil(DerivedAssetContract.mons, "the mon family registration survives alongside summary")
  Assert.notNil(DerivedAssetContract.party, "the party family registration survives alongside summary")
  Assert.notNil(DerivedAssetContract.bag, "the bag family registration survives alongside summary")
end

local function stringLeaves(value, out)
  if type(value) == "string" then
    out[#out + 1] = value
  elseif type(value) == "table" then
    for _, child in pairs(value) do
      stringLeaves(child, out)
    end
  end
end

local function numberLeaves(value, out)
  if type(value) == "number" then
    out[#out + 1] = value
  elseif type(value) == "table" then
    for _, child in pairs(value) do
      numberLeaves(child, out)
    end
  end
end

local function sizePairs(value, out)
  if type(value) == "table" then
    if type(value.width) == "number" and type(value.height) == "number" then
      out[#out + 1] = { width = value.width, height = value.height }
    end
    for _, child in pairs(value) do
      sizePairs(child, out)
    end
  end
end

-- The producer catalog transcribes the native source closure: the ui
-- archive, the shared-graphics archive, the picture metadata archive, and
-- the motion-program archive resolve to their physical paths.
function T.source_catalog_lists_the_native_source_closure()
  local sources = requireSources()
  local strings = {}
  stringLeaves(sources, strings)
  local seen = {}
  for _, leaf in ipairs(strings) do
    seen[leaf] = true
  end
  for _, path in ipairs({ "a/1/6/2", "a/0/3/9", "a/1/8/0", "a/0/9/0" }) do
    Assert.isTrue(seen[path] == true, "the source catalog omits the native archive path " .. path)
  end
end

-- The group/background selection values of the native application survive
-- transcription: every map in the info/skills/performance selection,
-- including the restricted, locked-performance, and excluded-group
-- alternatives, is present in the producer catalog.
function T.source_catalog_keeps_the_group_map_selection()
  local sources = requireSources()
  local numbers = {}
  numberLeaves(sources, numbers)
  local seen = {}
  for _, leaf in ipairs(numbers) do
    seen[leaf] = true
  end
  for _, map in ipairs({ 9, 10, 11, 12, 13, 14, 17, 18, 19, 77, 78 }) do
    Assert.isTrue(seen[map] == true, "the source catalog omits the native group map " .. map)
  end
end

-- The stamp fragments keep their native dimensions: they are stamp
-- compositions, never object frames, and their sizes survive lowering.
function T.source_catalog_keeps_the_stamp_fragment_dimensions()
  local sources = requireSources()
  local pairs = {}
  sizePairs(sources, pairs)
  local seen = {}
  for _, pair in ipairs(pairs) do
    seen[pair.width .. "x" .. pair.height] = true
  end
  for _, size in ipairs({ "136x48", "80x32", "88x112", "48x24" }) do
    Assert.isTrue(seen[size] == true, "the source catalog omits the native stamp size " .. size)
  end
end

-- The picture metadata inventory keeps its native shape: 494 records of 89
-- bytes, read through the front entry.
function T.source_catalog_keeps_the_picture_metadata_shape()
  local sources = requireSources()
  local numbers = {}
  numberLeaves(sources, numbers)
  local seen = {}
  for _, leaf in ipairs(numbers) do
    seen[leaf] = true
  end
  Assert.isTrue(seen[494] == true, "the source catalog omits the 494 metadata records")
  Assert.isTrue(seen[89] == true, "the source catalog omits the 89-byte metadata record")
end

function T.asset_compiler_boundary_names_its_owner()
  requireCompiler()
end

function T.picture_compiler_boundary_names_its_owner()
  local ok, compiler = pcall(require, "romdump.src.digest.ui.SummaryPictureCompiler")
  Assert.isTrue(
    ok,
    "the summary picture evaluator is missing: front-frame and motion programs have no compile-time owner"
  )
  Assert.equal(type(compiler.compile), "function", "the summary picture evaluator exposes its compile entrypoint")
end

function T.cache_writer_boundary_names_its_owner()
  local ok, writer = pcall(require, "romdump.src.digest.ui.SummaryCacheWriter")
  Assert.isTrue(ok, "the summary cache writer is missing: the family has no marker-last staging owner")
  Assert.equal(type(writer.stage), "function", "the summary cache writer exposes its staging entrypoint")
  Assert.equal(type(writer.write), "function", "the summary cache writer exposes its direct-write entrypoint")
end

-- The consumer cache owns the family roots: generated records live under
-- the summary data root with pixels beside them under the summary asset
-- root, and the marker relationship stays exact.
function T.consumer_cache_owns_the_family_roots()
  local cache = requireCache()
  Assert.equal(cache.dir(), "data/generated/summary", "the summary data root is owned by this family")
  Assert.equal(cache.assetDir(), "assets/generated/summary", "the summary asset root is owned by this family")
  Assert.equal(
    cache.markerPath(),
    cache.dir() .. "/complete",
    "readiness is the completion marker inside the family root"
  )
  Assert.equal(cache.manifestPath(), cache.dir() .. "/manifest.lua", "the manifest lives inside the family root")
  Assert.equal(
    cache.provenancePath(),
    cache.dir() .. "/provenance.lua",
    "provenance lives beside the manifest inside the family root"
  )
end

function T.consumer_marker_carries_the_family_format()
  local cache = requireCache()
  local marker = assert(cache.marker("abc", "dep"), "the summary cache issues a marker")
  Assert.equal(marker:sub(1, #SUMMARY_FORMAT + 1), SUMMARY_FORMAT .. ":", "the marker names the family format")
end

local function groupShell()
  return { main = {}, sub = {} }
end

-- Minimal envelope skeleton for schema rejection tests. Structural detail
-- beyond the closed field set, native geometry, group keys, and picture
-- termination rules belongs to the compiled-output conformance coverage;
-- this skeleton only keeps rejection attribution on the field under test.
-- Bar and touch stubs below mirror the required content sections so
-- rejection tests attribute to their own field rather than to a missing
-- required section.
local function barVisual(name)
  return { image = "assets/generated/summary/syn-" .. name .. ".png", width = 8, height = 8 }
end

local function validBar(length)
  return {
    length = length,
    colors = {
      high = { r = 0, g = 255, b = 0 },
      low = { r = 255, g = 255, b = 0 },
      critical = { r = 255, g = 0, b = 0 },
    },
    empty = barVisual("bar-empty"),
    full = barVisual("bar-full"),
  }
end

local function finitePicture()
  return {
    portrait = "EXEMPLAR_PORTRAIT",
    cryDelayTicks = 0,
    samples = {
      {
        durationTicks = 2,
        frameIndex = 0,
        offsetX = 0,
        offsetY = 0,
        scaleX = 1,
        scaleY = 1,
        rotationTurns = 0,
        visible = true,
      },
    },
    terminal = {},
  }
end

-- Source-pinned per-pane role census for the synthetic semantic layout:
-- info carries 2 main and 6 sub roles, skills 8 and 10, performance 5
-- and 3. Role geometry is synthetic but pane-correct; structural detail
-- beyond the closed record shapes belongs to the compiled-output
-- conformance coverage.
local GROUP_ROLE_CENSUS = { info = { main = 2, sub = 6 }, skills = { main = 8, sub = 10 }, performance = { main = 5, sub = 3 } }

local function semanticRole(pane, seed)
  return {
    pane = pane,
    rect = { x = 8, y = 8 + (seed * 16) % 176, width = 64, height = 8 },
    palette = 13,
    ink = "ordinary",
  }
end

local function semanticWindows()
  local fixed = { synHeader = semanticRole("sub", 0) }
  local groups = {}
  for group, census in pairs(GROUP_ROLE_CENSUS) do
    groups[group] = { main = {}, sub = {} }
    for pane, count in pairs(census) do
      for index = 1, count do
        groups[group][pane]["syn" .. group .. pane .. index] = semanticRole(pane, index)
      end
    end
  end
  return { fixed = fixed, groups = groups }
end

local function semanticMemoBranch()
  return {
    key = "synBranch",
    selectable = true,
    match = { isEgg = false, fateful = false, mine = true, metLocation = "wild" },
    lines = { nature = 1, date = 2, characteristic = 6, flavor = 7, eggWatch = 0 },
    dateTemplate = {
      segments = {
        { kind = "text", value = "SYN" },
        { kind = "metMonth" },
        { kind = "lineBreak" },
        { kind = "metLocation" },
      },
    },
  }
end

local function semanticMemo()
  return {
    conditions = { semanticMemoBranch() },
    locations = { palPark = 55, linkTrade = 4001, linkTrade2 = 4002, ranger = 6001, giftEggOrigins = { 4009 } },
    migrationRegions = { heartgold = "synRegion", soulsilver = "synRegion" },
  }
end

-- Minimal valid dynamic-chrome section for schema rejection tests. Role
-- geometry is synthetic but shape-correct; structural detail beyond the
-- closed record shapes belongs to the compiled-output conformance
-- coverage. The animation names mirror the generated semantic roles so
-- reference resolution is exercised.
local CHROME_ANIMATIONS = {
  "rootFocus",
  "moveRowFocus",
  "restrictedCancel",
  "moveCancel",
  "moveFollow",
  "starBase",
  "starAbove",
  "starBelow",
  "starEmpty",
  "modifierPositive",
  "modifierNegative",
  "leaf",
  "crown",
  "ribbonCursor",
  "ribbonPagePrev",
  "ribbonPageNext",
}

local function chromeVisuals()
  local visuals = { detailBacking = { image = "assets/generated/summary/syn-detail-backing.png", width = 8, height = 8 } }
  for _, name in ipairs(CHROME_ANIMATIONS) do
    visuals["syn-" .. name] = { image = "assets/generated/summary/syn-" .. name .. ".png", width = 16, height = 16 }
  end
  return visuals
end

local function chromeSprites()
  local animations = {}
  for _, name in ipairs(CHROME_ANIMATIONS) do
    animations[name] = { frames = { { visual = "syn-" .. name, durationTicks = 2 } }, loopFrom = 1, playback = "static" }
  end
  local primaryAnchors = {}
  for index = 1, 6 do
    primaryAnchors[index] = { x = 8 * index, y = 8 }
  end
  local leafAnchors = {}
  for index = 1, 5 do
    leafAnchors[index] = { x = 8 * index, y = 16 }
  end
  local rows = {}
  for index = 1, 5 do
    local stars = {}
    for star = 1, 5 do
      stars[star] = { x = 8 * star, y = 8 * index }
    end
    rows[index] = {
      stat = "synStat" .. index,
      stars = stars,
      modifier = { x = 8, y = 8 * index },
      starBase = "starBase",
      starAbove = "starAbove",
      starBelow = "starBelow",
      starEmpty = "starEmpty",
      modifierPositive = "modifierPositive",
      modifierNegative = "modifierNegative",
    }
  end
  return {
    animations = animations,
    primaryCursor = {
      anchors = primaryAnchors,
      rootFocus = "rootFocus",
      moveRowFocus = "moveRowFocus",
      restrictedCancel = "restrictedCancel",
    },
    secondaryMoveCursor = {
      x = 68,
      rowBaseY = 24,
      rowStep = 32,
      cancelY = 152,
      restrictedCancelY = 168,
      cancelAnchor = { x = 68, y = 168 },
      restrictedSpecialAnchor = { x = 220, y = 176 },
      moveCancel = "moveCancel",
      moveFollow = "moveFollow",
    },
    performance = { rows = rows },
    leaves = { anchors = leafAnchors, crownAnchor = { x = 8, y = 16 }, leaf = "leaf", crown = "crown" },
    ribbons = {
      origin = { x = 32, y = 24 },
      columns = 3,
      columnStep = 32,
      rowStep = 40,
      cursor = "ribbonCursor",
      pagePrev = { anchor = { x = 128, y = 32 }, animation = "ribbonPagePrev" },
      pageNext = { anchor = { x = 128, y = 96 }, animation = "ribbonPageNext" },
    },
  }
end

local function chromeTransitions()
  return {
    moveDetail = { pane = "sub", axis = "x", positions = { 0, 64, 128 } },
    ribbonDetail = { pane = "sub", axis = "y", positions = { 0, 36, 72 } },
  }
end

local function skeletonManifest()
  return {
    schema = SUMMARY_SCHEMA,
    paneSize = { width = 256, height = 192 },
    groups = { info = groupShell(), skills = groupShell(), performance = groupShell() },
    windows = semanticWindows(),
    visuals = chromeVisuals(),
    sprites = chromeSprites(),
    hitboxes = {},
    text = {},
    palettes = {},
    bars = {},
    pictures = {},
    ribbons = {},
    performance = {},
    dexNumbers = {},
    memo = semanticMemo(),
    sounds = {},
    transitions = chromeTransitions(),
  }
end

function T.schema_rejects_an_unrecognized_top_level_field()
  local schema = requireSchema()
  local manifest = skeletonManifest()
  manifest.extraField = {}
  local ok, err = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok == false, "an unrecognized manifest field must not validate")
  Assert.notNil(err, "an unrecognized manifest field reports its rejection")
end

function T.schema_rejects_a_missing_or_wrong_schema_identity()
  local schema = requireSchema()
  local missing = skeletonManifest()
  missing.schema = nil
  Assert.isTrue(pcall(schema.assertManifest, missing) == false, "a missing schema identity must not validate")
  local wrong = skeletonManifest()
  wrong.schema = "g4-party-presentation-v6"
  Assert.isTrue(pcall(schema.assertManifest, wrong) == false, "another family's schema must not validate")
end

function T.schema_enforces_the_native_pane_geometry()
  local schema = requireSchema()
  local manifest = skeletonManifest()
  manifest.paneSize = { width = 200, height = 100 }
  Assert.isTrue(pcall(schema.assertManifest, manifest) == false, "a non-native pane size must not validate")
end

-- The bar inventory transcribes the overlay gauge geometry: the health
-- track spans 48 pixels over six background tiles and the experience
-- track spans 56 over seven, each with its tile-run base and palette
-- bank. Thresholds follow the shared gauge color decision.
function T.source_catalog_keeps_the_bar_rule_selection()
  local sources = requireSources()
  local bars = assert(sources.bars, "the source catalog carries the bar rule selection")
  Assert.equal(bars.hp.length, 48, "the health track spans 48 pixels")
  Assert.equal(bars.exp.length, 56, "the experience track spans 56 pixels")
  Assert.equal(bars.hp.columns, 6, "the health track fills six tiles")
  Assert.equal(bars.exp.columns, 7, "the experience track fills seven tiles")
  Assert.isTrue(type(bars.hp.tileBase) == "number", "the health tile run carries its base")
  Assert.isTrue(type(bars.exp.tileBase) == "number", "the experience tile run carries its base")
end

-- The touch inventory transcribes every overlay hitbox table in source
-- order: root tabs, exit, and member icons, move rows, ribbon cells
-- with page arrows and exit, then the state panel boxes.
function T.source_catalog_keeps_the_touch_target_selection()
  local sources = requireSources()
  local touch = assert(sources.touch, "the source catalog carries the touch target selection")
  Assert.isTrue(#touch >= 31, "the touch inventory covers every overlay hitbox")
  local keys = {}
  for _, entry in ipairs(touch) do
    Assert.isTrue(type(entry.key) == "string" and entry.key ~= "", "touch entries carry their semantic key")
    keys[#keys + 1] = entry.key
  end
  for _, key in ipairs({ "tabInfo", "tabSkills", "tabPerformance", "member0", "moveRow0", "ribbonCell0" }) do
    local found = false
    for _, name in ipairs(keys) do
      if name == key then
        found = true
      end
    end
    Assert.isTrue(found, "the touch inventory carries " .. key)
  end
end

function T.schema_enforces_exactly_the_three_native_groups()
  local schema = requireSchema()
  local missing = skeletonManifest()
  missing.groups.performance = nil
  Assert.isTrue(pcall(schema.assertManifest, missing) == false, "a missing native group must not validate")
  local extra = skeletonManifest()
  extra.groups.contests = groupShell()
  Assert.isTrue(pcall(schema.assertManifest, extra) == false, "an invented fourth group must not validate")
end

-- Bar rules are required content: a family without health or experience
-- tracks must not validate, since read-only facts project through them.
function T.schema_requires_complete_bar_rules()
  local schema = requireSchema()
  local missing = skeletonManifest()
  Assert.isTrue(pcall(schema.assertManifest, missing) == false, "a family without bar rules must not validate")
  local partial = skeletonManifest()
  partial.bars = { hp = validBar(48) }
  Assert.isTrue(pcall(schema.assertManifest, partial) == false, "a family without the experience rule must not validate")
end

-- Touch targets are required content: an empty touch set must not
-- validate, since native pointer control resolves through it.
function T.schema_requires_populated_touch_targets()
  local schema = requireSchema()
  local missing = skeletonManifest()
  missing.hitboxes = { touch = {} }
  missing.bars = { hp = validBar(48), exp = validBar(56) }
  Assert.isTrue(pcall(schema.assertManifest, missing) == false, "a family without touch targets must not validate")
end

-- Calibrated sound absence stays valid: sounds compile empty until a
-- generated-family consumer resolves them, and the closed key with its
-- shape validator remains. Transition tracks are required content now:
-- the nested move/ribbon states consume generated BG position traces.
function T.schema_accepts_the_calibrated_absent_sounds()
  local schema = requireSchema()
  local manifest = skeletonManifest()
  manifest.hitboxes = { touch = { exitChrome = { top = 165, bottom = 191, left = 189, right = 250 } } }
  manifest.bars = { hp = validBar(48), exp = validBar(56) }
  manifest.pictures = { exemplar = finitePicture() }
  Assert.isTrue(pcall(schema.assertManifest, manifest), "the calibrated empty sounds must validate")
end

-- Minimal otherwise-valid envelope for layout/memo rejection tests.
-- Mirrors the sounds-absence recipe so each rejection attributes to
-- the field under test rather than to a missing required section.
local function contractReadyManifest()
  local manifest = skeletonManifest()
  manifest.hitboxes = { touch = { exitChrome = { top = 165, bottom = 191, left = 189, right = 250 } } }
  manifest.bars = { hp = validBar(48), exp = validBar(56) }
  manifest.pictures = { exemplar = finitePicture() }
  return manifest
end

local function ordinalWindow(pane, x, y, width, height)
  return { pane = pane, rect = { x = x, y = y, width = width, height = height }, palette = 13 }
end

-- Semantic window roles replace ordinal slots: a manifest that still
-- addresses windows as numbered main/sub positions must not validate,
-- since no consumer may infer a window's purpose from its array position.
function T.schema_rejects_ordinal_window_slots()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.windows = {
    sub01 = ordinalWindow("sub", 160, 8, 88, 16),
    main01 = ordinalWindow("main", 160, 8, 88, 16),
  }
  local ok = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok == false, "numbered window slots must not validate once semantic roles own the layout")
end

-- Memo selection is first-match over an ordered rule list, so an
-- unordered map of branches without selectability must not validate.
function T.schema_rejects_unordered_memo_branches()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.memo = {
    conditions = {
      wildEncounter = {
        template = "synMemoWild",
        nature = 1,
        date = 2,
        characteristic = 6,
        flavor = 7,
        eggWatch = 0,
      },
    },
  }
  local ok = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok == false, "unordered memo branches must not validate once selection is first-match")
end

-- Memo templates carry normalized semantic bindings: a segment that
-- still holds a raw message-format placeholder field must not
-- validate, since source buffer layout never reaches runtime.
function T.schema_rejects_raw_placeholder_fields_in_memo_templates()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.memo.conditions[1].dateTemplate.segments = {
    { kind = "landmark", field = 4 },
  }
  local ok, err = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok == false, "a raw placeholder field must not validate inside a memo template")
  Assert.isTrue(
    Errors.format(err):find("raw placeholder field", 1, true) ~= nil,
    "the rejection names the raw placeholder field: " .. tostring(Errors.format(err))
  )
end

-- Substitution segments outside the memo vocabulary must not validate,
-- even when the kind exists elsewhere: bank lowering roles such as
-- species or nickname never appear inside memo date templates.
function T.schema_rejects_unknown_memo_segment_kinds()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.memo.conditions[1].dateTemplate.segments = {
    { kind = "nickname" },
  }
  local ok, err = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok == false, "a foreign substitution kind must not validate inside a memo template")
  Assert.isTrue(
    Errors.format(err):find("memo substitution vocabulary", 1, true) ~= nil,
    "the rejection names the memo substitution vocabulary: " .. tostring(err)
  )
end

-- Group roles live under their native pane: a role filed under the main
-- composition that claims the sub pane must not validate.
function T.schema_rejects_group_roles_on_the_wrong_pane()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.windows.groups.skills.main.synskillsmain1.pane = "sub"
  local ok, err = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok == false, "a group role on the wrong pane must not validate")
  Assert.isTrue(
    Errors.format(err):find("must match its group pane", 1, true) ~= nil,
    "the rejection names the pane mismatch: " .. tostring(err)
  )
end

-- Role geometry stays inside the canonical pane: a role rectangle that
-- escapes the 256x192 surface must not validate.
function T.schema_rejects_roles_escaping_the_native_pane()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.windows.fixed.synHeader.rect = { x = 200, y = 8, width = 64, height = 8 }
  local ok, err = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok == false, "a role escaping the native pane must not validate")
  Assert.isTrue(
    Errors.format(err):find("escapes the canonical pane", 1, true) ~= nil,
    "the rejection names the pane escape: " .. tostring(err)
  )
end

-- The migrated-region wording is bound per supported origin game by the
-- producer: a manifest without the game-keyed mapping, or with an empty
-- game entry, must not validate, so runtime can never resolve gift-bank
-- packing itself.
function T.schema_rejects_a_missing_migration_region_mapping()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.memo.migrationRegions = nil
  local ok = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok == false, "a manifest without migration regions must not validate")
  local empty = contractReadyManifest()
  empty.memo.migrationRegions.heartgold = ""
  local emptyOk = pcall(schema.assertManifest, empty)
  Assert.isTrue(emptyOk == false, "an empty migration region entry must not validate")
end

-- Required dynamic chrome and transition tracks cannot be omitted: a
-- family with an empty sprite record or an empty transition record must
-- not validate, so the reviewed behaviors cannot silently drop out of
-- the generated family.
function T.schema_rejects_a_family_omitting_dynamic_chrome_or_transition_tracks()
  local schema = requireSchema()
  local withoutChrome = contractReadyManifest()
  withoutChrome.sprites = {}
  local chromeOk = pcall(schema.assertManifest, withoutChrome)
  Assert.isFalse(chromeOk, "a family without dynamic chrome must not validate")
  local withoutTracks = contractReadyManifest()
  withoutTracks.transitions = {}
  local tracksOk = pcall(schema.assertManifest, withoutTracks)
  Assert.isFalse(tracksOk, "a family without transition tracks must not validate")
end

-- Source identities never leak into the new records: a sprite role
-- carrying a producer archive/bank/message key must not validate.
function T.schema_rejects_source_identities_inside_dynamic_chrome()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.sprites.primaryCursor.bank = 0
  local ok = pcall(schema.assertManifest, manifest)
  Assert.isFalse(ok, "a source bank key must not validate inside dynamic chrome")
end

-- Animation frames resolve to family visuals: a frame naming no
-- visual must not validate, so a dropped frame cannot read as complete.
function T.schema_rejects_animation_frames_without_family_visuals()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  manifest.sprites.animations.rootFocus.frames[1].visual = "syn-missing"
  local ok = pcall(schema.assertManifest, manifest)
  Assert.isFalse(ok, "a frame without its visual must not validate")
end

-- The synthetic presentation data mirrors the generated envelope: it
-- tracks the current schema identity and carries structured memo
-- templates, so unit tests cannot pass with label-only strings where
-- template records belong.
function T.synthetic_presentation_data_mirrors_the_generated_envelope()
  local Fixture = require("tests.support.SummaryPresentationFixture")
  Assert.equal(Fixture.SCHEMA, "g4-summary-manifest-v3", "the synthetic data tracks the generated schema")
  local manifest = Fixture.manifest()
  Assert.notNil(manifest, "the synthetic data builds a manifest")
  Assert.equal(manifest.schema, Fixture.SCHEMA, "the synthetic manifest carries the tracked schema")
  local conditions = assert(
    manifest.memo and manifest.memo.conditions,
    "the synthetic memo carries its ordered branches"
  )
  Assert.isTrue(conditions[1] ~= nil, "the synthetic memo branches keep first-match order")
  local firstTemplate = assert(conditions[1].dateTemplate, "the first synthetic branch carries its date template")
  Assert.isTrue(
    type(firstTemplate.segments) == "table" and #firstTemplate.segments > 0,
    "the synthetic memo template keeps structured segments"
  )
  local schema = requireSchema()
  local ok, err = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok, "the synthetic manifest passes the consumer schema: " .. tostring(err))
end

-- Memo branches bind structured date templates, never plain label
-- strings: a branch that references its wording through a label-only
-- `template` name instead of carrying its own substitution segments
-- must not validate, so the header-label workaround cannot return.
function T.synthetic_memo_branches_carry_no_label_only_template_references()
  local Fixture = require("tests.support.SummaryPresentationFixture")
  local manifest = Fixture.manifest()
  local conditions = assert(
    manifest.memo and manifest.memo.conditions,
    "the synthetic memo carries its ordered branches"
  )
  Assert.isTrue(conditions[1] ~= nil, "the synthetic memo branches keep first-match order")
  for index, branch in ipairs(conditions) do
    Assert.isNil(
      branch.template,
      "synthetic branch " .. index .. " carries no label-only template reference"
    )
    local template = assert(branch.dateTemplate, "synthetic branch " .. index .. " carries its date template")
    Assert.isTrue(
      type(template.segments) == "table" and #template.segments > 0,
      "synthetic branch " .. index .. " keeps structured substitution segments"
    )
  end
end

-- The semantic envelope itself validates: named fixed and group roles
-- with pane-correct geometry plus ordered memo branches with
-- substitution segments pass the consumer schema.
function T.schema_accepts_a_semantic_window_and_memo_envelope()
  local schema = requireSchema()
  local manifest = contractReadyManifest()
  local ok, err = pcall(schema.assertManifest, manifest)
  Assert.isTrue(ok, "the semantic window and memo envelope passes the consumer schema: " .. tostring(err))
end

return { tests = T }
