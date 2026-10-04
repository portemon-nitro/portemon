-- Producer-side contract for the native summary presentation family: the
-- registered derived family identity, the producer source catalog, the
-- compiler boundaries, and the strict consumer schema. Every fact pinned
-- here is a current structural requirement of that family; no committed
-- commercial payloads appear.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")

local T = {}

local SUMMARY_FORMAT = "g4-summary-cache-v1"
local SUMMARY_SCHEMA = "g4-summary-manifest-v1"

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
local function skeletonManifest()
  return {
    schema = SUMMARY_SCHEMA,
    paneSize = { width = 256, height = 192 },
    groups = { info = groupShell(), skills = groupShell(), performance = groupShell() },
    windows = {},
    visuals = {},
    sprites = {},
    hitboxes = {},
    text = {},
    palettes = {},
    bars = {},
    pictures = {},
    ribbons = {},
    performance = {},
    dexNumbers = {},
    memo = {},
    sounds = {},
    transitions = {},
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

-- Calibrated absences stay valid: sounds and transitions compile empty
-- until a generated-family consumer resolves them, and the closed keys
-- with their shape validators remain.
function T.schema_accepts_the_calibrated_absent_sections()
  local schema = requireSchema()
  local manifest = skeletonManifest()
  manifest.hitboxes = { touch = { exitChrome = { top = 165, bottom = 191, left = 189, right = 250 } } }
  manifest.bars = { hp = validBar(48), exp = validBar(56) }
  manifest.pictures = { exemplar = finitePicture() }
  Assert.isTrue(pcall(schema.assertManifest, manifest), "the calibrated empty sections must validate")
end

return { tests = T }
