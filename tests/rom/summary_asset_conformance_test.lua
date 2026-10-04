-- ROM conformance for the native summary presentation family: the compiled
-- manifest matches source resources, keeps the main/sub assignment, carries
-- no source identities for runtime readers, resolves every generated path,
-- and joins picture frames with their motion programs into exactly
-- terminated tracks. Assertions are relationships and source facts, never
-- committed commercial payloads.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local PngReader = require("tests.support.PngReader")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local SUMMARY_SCHEMA = "g4-summary-manifest-v1"
local SUMMARY_ASSET_DIR = "assets/generated/summary/"
local MOTION_ARCHIVE_PATH = "a/0/9/0"

local function requireCompiler()
  local ok, compiler = pcall(require, "romdump.src.digest.ui.SummaryAssetCompiler")
  Assert.isTrue(ok, "the summary asset compiler is missing: native resources have no lowering owner")
  return compiler
end

local function requireSchema()
  local ok, schema = pcall(require, "libs.assets.src.SummaryAssetSchema")
  Assert.isTrue(ok, "the summary consumer schema is missing: compiled output has no strict gate")
  return schema
end

local function requireCache()
  local ok, cache = pcall(require, "libs.assets.src.SummaryCache")
  Assert.isTrue(ok, "the summary consumer cache is missing: generated paths have no readiness owner")
  return cache
end

local function compileCatalog(romFs, versionId)
  return assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
end

local function portraitManifest(versionId)
  local cache = CacheFs.forVersion(versionId)
  local manifest = assert(cache:loadLua(MonCache.portraitManifestPath()), "the portrait manifest must load")
  return manifest
end

local compiledByVersion = {}

local function compileBundle(romFs, versionId)
  local compiler = requireCompiler()
  local catalog = compileCatalog(romFs, versionId)
  local portraits = portraitManifest(versionId)
  return assert(compiler.compile(romFs, catalog, portraits))
end

local function bundleFor(romFs, versionId)
  if compiledByVersion[versionId] == nil then
    compiledByVersion[versionId] = compileBundle(romFs, versionId)
  end
  return compiledByVersion[versionId]
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function canonical(value)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  elseif kind == "number" then
    Assert.isTrue(isFiniteNumber(value), "compiled records carry only finite numbers")
    return tostring(value)
  elseif kind == "boolean" then
    return tostring(value)
  elseif kind == "table" then
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = "[" .. canonical(key) .. "]=" .. canonical(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("compiled records carry no " .. kind .. " values", 0)
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

local function hasForbiddenKey(value, seen)
  seen = seen or {}
  if type(value) ~= "table" or seen[value] then
    return nil
  end
  seen[value] = true
  for key, child in pairs(value) do
    if key == "narcId" or key == "bank" or key == "bankId" or key == "messageBank" or key == "messageId" then
      return key
    end
    local nested = hasForbiddenKey(child, seen)
    if nested ~= nil then
      return nested
    end
  end
  return nil
end

-- The compiled family is a closed envelope over native 256x192 panes: no
-- unrecognized top-level section survives lowering.
function T.compiled_family_matches_the_closed_envelope(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local manifest = assert(bundle.manifest, "compilation publishes a manifest")
  Assert.equal(manifest.schema, SUMMARY_SCHEMA, "the compiled manifest carries the family schema")
  Assert.equal(manifest.paneSize.width, 256, "the native pane is 256 wide")
  Assert.equal(manifest.paneSize.height, 192, "the native pane is 192 tall")
  Assert.keySet(manifest, "bars,dexNumbers,groups,hitboxes,memo,palettes,paneSize,performance,pictures,"
    .. "ribbons,schema,sounds,sprites,text,transitions,visuals,windows",
    "the manifest carries exactly the closed field set")
end

-- The three native groups keep their physical assignment: every group
-- carries both a main-pane and a sub-pane variant, info keeps its sub
-- variant, and every source window resolves to a named native pane.
function T.groups_keep_the_native_main_sub_assignment(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local groups = assert(bundle.manifest.groups, "the compiled manifest carries its groups")
  Assert.keySet(groups, "info,performance,skills", "exactly the three native groups compile")
  for _, name in ipairs({ "info", "skills", "performance" }) do
    local group = assert(groups[name], "the " .. name .. " group resolves")
    Assert.notNil(group.main, "the " .. name .. " group carries its main-pane variant")
    Assert.notNil(group.sub, "the " .. name .. " group carries its sub-pane variant")
  end
  local windows = assert(bundle.manifest.windows, "the compiled manifest carries its windows")
  local panes = {}
  local count = 0
  for key, window in pairs(windows) do
    Assert.isTrue(window.pane == "main" or window.pane == "sub", "window " .. tostring(key) .. " names a native pane")
    panes[window.pane] = true
    count = count + 1
  end
  Assert.isTrue(count > 0, "the compiled manifest carries source windows")
  Assert.isTrue(panes.main == true, "main-pane windows resolve")
  Assert.isTrue(panes.sub == true, "sub-pane windows resolve")
end

-- Source identities stop at the compiler boundary: text templates and the
-- manifest carry no archive, bank, member, or message identities for
-- runtime interpretation.
function T.compiled_records_carry_no_source_identities(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local forbidden = hasForbiddenKey(bundle.manifest)
  Assert.isNil(forbidden, "a source identity survives lowering: " .. tostring(forbidden))
  local templates = assert(
    bundle.manifest.text and bundle.manifest.text.templates,
    "the compiled manifest carries named text templates"
  )
  local names = 0
  for name, template in pairs(templates) do
    names = names + 1
    Assert.isNil(template.bank, "template " .. tostring(name) .. " omits its source bank")
    Assert.isNil(template.index, "template " .. tostring(name) .. " omits its source message identity")
  end
  Assert.isTrue(names > 0, "bank lowering yields named templates")
end

-- Every generated path a consumer can read is enumerated, present, local,
-- and unambiguous: referenced outputs resolve in the bundle, manifest
-- image references participate in readiness, and no path escapes the cache.
function T.every_generated_path_resolves_through_the_family(romFs, versionId)
  local SummaryCache = requireCache()
  local bundle = bundleFor(romFs, versionId)
  local referenced = assert(SummaryCache.referencedPaths(bundle.manifest), "the manifest enumerates its outputs")
  Assert.isTrue(#referenced > 0, "the family enumerates its generated outputs")
  local referencedSet = {}
  for _, path in ipairs(referenced) do
    Assert.isNil(referencedSet[path], "generated outputs are enumerated once: " .. path)
    referencedSet[path] = true
    Assert.isTrue(path:sub(1, 2) ~= ".." and not path:find("/%.%./"), "no generated path escapes: " .. path)
    Assert.notNil(bundle.assets[path], "enumerated output has compiled bytes: " .. path)
  end
  local leaves = {}
  stringLeaves(bundle.manifest, leaves)
  for _, leaf in ipairs(leaves) do
    if leaf:sub(-4) == ".png" then
      Assert.isTrue(referencedSet[leaf] == true, "a manifest image escapes readiness: " .. leaf)
    end
  end
end

-- The compiled manifest satisfies its own consumer gate.
function T.compiled_manifest_passes_the_consumer_schema(romFs, versionId)
  local schema = requireSchema()
  local bundle = bundleFor(romFs, versionId)
  local ok, err = pcall(schema.assertManifest, bundle.manifest)
  Assert.isTrue(ok, "the compiled manifest fails its consumer schema: " .. tostring(err))
end

local function checkSample(sample, entryKey, index)
  local what = "picture " .. tostring(entryKey) .. " sample " .. index
  Assert.isTrue(
    type(sample.durationTicks) == "number"
      and sample.durationTicks % 1 == 0
      and sample.durationTicks > 0,
    what .. " carries a positive integral duration"
  )
  Assert.isTrue(
    type(sample.frameIndex) == "number" and sample.frameIndex % 1 == 0 and sample.frameIndex >= 0,
    what .. " selects a frame"
  )
  for _, field in ipairs({ "offsetX", "offsetY", "scaleX", "scaleY", "rotationTurns" }) do
    Assert.isTrue(isFiniteNumber(sample[field]), what .. " carries finite " .. field)
  end
  Assert.isTrue(type(sample.visible) == "boolean", what .. " carries visibility")
  local blend = sample.paletteBlend
  if blend ~= nil then
    Assert.equal(type(blend), "table", what .. " blend is a normalized palette state")
    local target = assert(blend.target, what .. " blend carries its 5-bit target")
    for _, channel in ipairs({ "r", "g", "b" }) do
      Assert.isTrue(
        type(target[channel]) == "number" and target[channel] % 1 == 0 and target[channel] >= 0 and target[channel] <= 31,
        what .. " blend target " .. channel .. " is a 5-bit component"
      )
    end
    Assert.isTrue(
      type(blend.coefficient) == "number" and blend.coefficient % 1 == 0,
      what .. " blend carries its integer coefficient"
    )
  end
end

-- Every compiled picture joins its frames with the selected motion program:
-- samples are complete per-tick states with integral timing, and each track
-- ends exactly once, by holding its terminal state or by naming its cycle.
function T.picture_tracks_join_frames_and_motion_with_exact_termination(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local pictures = assert(bundle.manifest.pictures, "the compiled manifest carries picture tracks")
  local count = 0
  for _, _ in pairs(pictures) do
    count = count + 1
  end
  Assert.isTrue(count > 0, "the picture closure is nonempty")
  for key, entry in pairs(pictures) do
    local samples = assert(entry.samples, "picture " .. tostring(key) .. " carries samples")
    Assert.isTrue(#samples > 0, "picture " .. tostring(key) .. " carries a nonempty track")
    for index, sample in ipairs(samples) do
      checkSample(sample, key, index)
    end
    local hasTerminal = entry.terminal ~= nil
    local hasLoop = entry.loopFrom ~= nil
    Assert.isTrue(hasTerminal ~= hasLoop, "picture " .. tostring(key) .. " ends exactly once")
    if hasLoop then
      Assert.isTrue(
        type(entry.loopFrom) == "number"
          and entry.loopFrom % 1 == 0
          and entry.loopFrom >= 1
          and entry.loopFrom <= #samples,
        "picture " .. tostring(key) .. " restarts inside its own track"
      )
    end
    Assert.isTrue(
      type(entry.cryDelayTicks) == "number"
        and entry.cryDelayTicks % 1 == 0
        and entry.cryDelayTicks >= 0,
      "picture " .. tostring(key) .. " carries its cry delay"
    )
  end
end

-- Picture art resolves without substituting party icons: every picture
-- image reference is a family-owned visual, and at least one family-owned
-- front-picture visual (the egg artwork path) compiles from the
-- front-picture decoder with opaque content.
function T.picture_art_uses_family_owned_front_pictures(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local pictures = assert(bundle.manifest.pictures, "the compiled manifest carries picture tracks")
  local portraits = portraitManifest(versionId)
  local portraitEntries = assert(portraits.entries, "the portrait manifest carries its entries")
  local ownedCount = 0
  for key, entry in pairs(pictures) do
    local leaves = {}
    stringLeaves(entry, leaves)
    local resolved = false
    for _, leaf in ipairs(leaves) do
      if leaf:sub(-4) == ".png" then
        Assert.equal(
          leaf:sub(1, #SUMMARY_ASSET_DIR),
          SUMMARY_ASSET_DIR,
          "picture " .. tostring(key) .. " art stays family-owned: " .. leaf
        )
        local bytes = assert(bundle.assets[leaf], "picture " .. tostring(key) .. " art has compiled bytes")
        if type(bytes) ~= "string" then
          bytes = bytes:getString()
        end
        local width, height, rgba = PngReader.rgba(assert(bytes, "picture art decodes: " .. leaf))
        Assert.equal(width, 80, "picture " .. tostring(key) .. " front art is 80 wide")
        Assert.equal(height, 80, "picture " .. tostring(key) .. " front art is 80 tall")
        local opaque = 0
        for offset = 4, #rgba, 4 do
          if string.byte(rgba, offset) ~= 0 then
            opaque = opaque + 1
          end
        end
        Assert.isTrue(opaque > 0, "picture " .. tostring(key) .. " front art carries opaque content")
        ownedCount = ownedCount + 1
        resolved = true
      elseif portraitEntries[leaf] ~= nil then
        resolved = true
      end
    end
    Assert.isTrue(resolved, "picture " .. tostring(key) .. " art resolves to a portrait or a family visual")
  end
  Assert.isTrue(ownedCount > 0, "the picture closure carries family-owned front-picture visuals")
end

-- Identical source inputs yield identical normalized records.
function T.recompilation_is_deterministic(romFs, versionId)
  local first = bundleFor(romFs, versionId)
  compiledByVersion[versionId] = nil
  local second = bundleFor(romFs, versionId)
  Assert.equal(canonical(second.manifest), canonical(first.manifest), "recompilation preserves every record")
end

local function romFsWithoutArchivePath(romFs, blockedPath)
  local proxy = setmetatable({}, { __index = romFs })
  function proxy:resolvedNarc(symbol)
    local entry = romFs:resolvedNarc(symbol)
    if entry ~= nil and entry.path == blockedPath then
      return nil
    end
    return entry
  end
  function proxy:openNarc(symbol)
    local entry = self:resolvedNarc(symbol)
    if entry == nil then
      return nil,
        Errors.new("ROMFS_NARC_UNRESOLVED", "blocked native archive " .. tostring(symbol), { name = symbol })
    end
    return romFs:openNarc(symbol)
  end
  function proxy:readSourcePath(sourcePath)
    if sourcePath == blockedPath then
      return nil, Errors.new("ROMFS_BLOCKED_SOURCE", "blocked native source " .. sourcePath, { path = sourcePath })
    end
    return romFs:readSourcePath(sourcePath)
  end
  function proxy:fileIdForPath(sourcePath)
    if sourcePath == blockedPath then
      return nil
    end
    return romFs:fileIdForPath(sourcePath)
  end
  return proxy
end

-- The motion programs belong to the picture closure: removing their archive
-- fails compilation instead of publishing motionless pictures.
function T.removing_the_motion_source_fails_compilation(romFs, versionId)
  local compiler = requireCompiler()
  local catalog = compileCatalog(romFs, versionId)
  local portraits = portraitManifest(versionId)
  local proxy = romFsWithoutArchivePath(romFs, MOTION_ARCHIVE_PATH)
  local bundle, err = compiler.compile(proxy, catalog, portraits)
  Assert.isNil(bundle, "compilation without the motion programs must not publish a family")
  Assert.notNil(err, "compilation without the motion programs reports its failure")
end

-- Every numeric window palette slot the presentation can pass resolves to
-- a source-grounded foreground/shadow/background triple: the compiled text
-- roles carry one entry per used window slot plus the printer-ink variants
-- the summary application selects at its window/text call sites, each
-- resolved against the window palette bank the slots index.
function T.window_palette_slots_resolve_through_text_roles(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local manifest = assert(bundle.manifest, "compilation publishes a manifest")
  local windows = assert(manifest.windows, "the compiled manifest carries its windows")
  local slots = {}
  for name, window in pairs(windows) do
    Assert.isTrue(
      type(window.palette) == "number",
      "window " .. tostring(name) .. " carries its numeric palette slot"
    )
    slots[window.palette] = true
  end
  local text = assert(manifest.text, "the compiled manifest carries its lowered text")
  local roles = assert(text.roles, "the compiled text carries its palette roles")
  local palettes = assert(manifest.palettes, "the compiled manifest carries its palettes")
  local bank = assert(palettes.banks and palettes.banks.bg13, "the window palette bank resolves")
  -- Printer triples of the summary window/text module: { foreground,
  -- shadow, background } slots in the window bank, one entry per ink the
  -- application selects (ordinary, dark, gender marks, nature-modified
  -- stats, move-panel ink over its filled window).
  local expected = {
    ordinary = { 14, 15, 0 },
    slot13 = { 14, 15, 0 },
    dark = { 1, 2, 0 },
    male = { 3, 4, 0 },
    female = { 5, 6, 0 },
    statLowered = { 14, 8, 0 },
    statRaised = { 14, 7, 0 },
    movePanel = { 1, 2, 15 },
  }
  Assert.keySet(
    roles,
    "dark,female,male,movePanel,ordinary,slot13,statLowered,statRaised",
    "the text roles carry exactly the transcribed printer roles"
  )
  for name, triple in pairs(expected) do
    local role = assert(roles[name], "the text roles carry " .. name)
    local classes = { "foreground", "shadow", "background" }
    for position, class in ipairs(classes) do
      local entry = assert(
        bank[triple[position] + 1],
        "the window bank carries slot " .. triple[position] .. " for role " .. name
      )
      local color = assert(role[class], "role " .. name .. " carries " .. class)
      Assert.equal(color.r, entry.r, "role " .. name .. "." .. class .. " resolves red")
      Assert.equal(color.g, entry.g, "role " .. name .. "." .. class .. " resolves green")
      Assert.equal(color.b, entry.b, "role " .. name .. "." .. class .. " resolves blue")
      if class == "background" then
        Assert.equal(color.a, 0, "role " .. name .. " prints over its filled window")
      else
        Assert.equal(color.a, 255, "role " .. name .. "." .. class .. " stays opaque")
      end
    end
  end
  for slot in pairs(slots) do
    Assert.notNil(
      roles["slot" .. slot],
      "window palette slot " .. slot .. " resolves through the text roles"
    )
  end
end

-- Bar content carries the source gauge rules with provenance: the health
-- track spans 48 pixels over six 8-pixel background tiles and the
-- experience track spans 56 pixels over seven, both filled left to right
-- by the shared integer gauge quotient with a minimum of one filled
-- pixel for any nonzero value. Health selects its tile run by the
-- threshold color decision (full, green, yellow, red, fainted); experience
-- uses its single blue run. Every color below is resolved against the
-- background palette bank its tile run indexes, read live from the dump:
-- no payload bytes are frozen into this test, only the bank/slot
-- relationship. The empty and full strips are the exact source tile runs
-- at zero and full fill; partial fill composes from the rule at runtime.
function T.bar_rules_lengths_colors_and_visuals_carry_source_provenance(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local bars = assert(bundle.manifest.bars, "the compiled manifest carries bar rules")
  local hp = assert(bars.hp, "the health bar rule compiles")
  local exp = assert(bars.exp, "the experience bar rule compiles")
  Assert.equal(hp.length, 48, "the health track spans 48 pixels")
  Assert.equal(exp.length, 56, "the experience track spans 56 pixels")
  Assert.keySet(hp.colors, "critical,high,low", "the health rule carries exactly its state inks")
  Assert.keySet(exp.colors, "critical,high,low", "the experience rule carries exactly its state inks")
  local archive = assert(romFs:openNarc("NARC_a_1_6_2"))
  local paletteBytes = assert(archive:readMember(0))
  local palette = assert(G2dDecoder.decodePalette(paletteBytes, { label = "conformance-bars" }))
  local function bankColor(bank, slot, what)
    local color = assert(palette.colors[bank * 16 + slot + 1], "the background palette carries " .. what)
    return color
  end
  local function assertResolves(entry, bank, slot, what)
    local expected = bankColor(bank, slot, what)
    Assert.equal(entry.r, expected.r, what .. " resolves red")
    Assert.equal(entry.g, expected.g, what .. " resolves green")
    Assert.equal(entry.b, expected.b, what .. " resolves blue")
  end
  assertResolves(hp.colors.high, 15, 6, "the healthy ink")
  assertResolves(hp.colors.low, 15, 8, "the weakened ink")
  assertResolves(hp.colors.critical, 15, 10, "the critical ink")
  assertResolves(exp.colors.high, 14, 11, "the experience ink")
  Assert.equal(exp.colors.low.r, exp.colors.high.r, "the experience rule keeps its single ink")
  Assert.equal(exp.colors.critical.b, exp.colors.high.b, "the experience rule keeps its single ink")
  local visuals = assert(bundle.manifest.visuals, "the compiled manifest carries its visuals")
  local strips = {
    { rule = hp, emptyWidth = 48, fullWidth = 48, name = "health" },
    { rule = exp, emptyWidth = 56, fullWidth = 56, name = "experience" },
  }
  for _, strip in ipairs(strips) do
    for _, state in ipairs({ "empty", "full" }) do
      local visual = assert(strip.rule[state], "the " .. strip.name .. " rule carries its " .. state .. " visual")
      local bytes = assert(bundle.assets[visual.image], "the " .. strip.name .. " " .. state .. " visual has bytes")
      if type(bytes) ~= "string" then
        bytes = bytes:getString()
      end
      local width, height, rgba = PngReader.rgba(assert(bytes, "the " .. strip.name .. " art decodes"))
      local want = state == "empty" and strip.emptyWidth or strip.fullWidth
      Assert.equal(width, want, "the " .. strip.name .. " " .. state .. " strip spans its track")
      Assert.equal(height, 8, "the " .. strip.name .. " " .. state .. " strip is one tile tall")
      local opaque = 0
      for offset = 4, #rgba, 4 do
        if string.byte(rgba, offset) ~= 0 then
          opaque = opaque + 1
        end
      end
      Assert.isTrue(opaque > 0, "the " .. strip.name .. " " .. state .. " strip carries visible pixels")
      Assert.notNil(visuals[strip.name == "health" and (state == "empty" and "hp-empty" or "hp-full") or (state == "empty" and "exp-empty" or "exp-full")], "the " .. strip.name .. " " .. state .. " tile resolves")
    end
  end
end

-- Touch targets transcribe the overlay hitbox tables in source order:
-- the root tab/member/exit list, the four move rows, the nine-cell
-- ribbon grid with its page arrows and exit, then the state panel
-- boxes. Every box is a { top, bottom, left, right } byte rect on the
-- 256x192 touch pane. Rows and cells stay separate boxes so blank-cell
-- ineligibility remains representable to the consumer; no box is
-- invented and none of the source set is dropped.
local EXPECTED_TOUCH_ORDER = {
  { key = "tabInfo", top = 165, bottom = 191, left = 2, right = 45 },
  { key = "tabSkills", top = 165, bottom = 191, left = 48, right = 96 },
  { key = "tabPerformance", top = 165, bottom = 191, left = 99, right = 140 },
  { key = "exitChrome", top = 165, bottom = 191, left = 189, right = 250 },
  { key = "member0", top = 38, bottom = 66, left = 165, right = 203 },
  { key = "member1", top = 46, bottom = 74, left = 205, right = 243 },
  { key = "member2", top = 70, bottom = 98, left = 165, right = 203 },
  { key = "member3", top = 78, bottom = 106, left = 205, right = 243 },
  { key = "member4", top = 102, bottom = 130, left = 165, right = 203 },
  { key = "member5", top = 110, bottom = 138, left = 205, right = 243 },
  { key = "moveRow0", top = 8, bottom = 39, left = 8, right = 127 },
  { key = "moveRow1", top = 40, bottom = 71, left = 8, right = 127 },
  { key = "moveRow2", top = 72, bottom = 103, left = 8, right = 127 },
  { key = "moveRow3", top = 104, bottom = 135, left = 8, right = 127 },
  { key = "ribbonCell0", top = 8, bottom = 39, left = 16, right = 47 },
  { key = "ribbonCell1", top = 8, bottom = 39, left = 48, right = 79 },
  { key = "ribbonCell2", top = 8, bottom = 39, left = 80, right = 112 },
  { key = "ribbonCell3", top = 48, bottom = 79, left = 16, right = 47 },
  { key = "ribbonCell4", top = 48, bottom = 79, left = 48, right = 79 },
  { key = "ribbonCell5", top = 48, bottom = 79, left = 80, right = 112 },
  { key = "ribbonCell6", top = 88, bottom = 119, left = 16, right = 47 },
  { key = "ribbonCell7", top = 88, bottom = 119, left = 48, right = 79 },
  { key = "ribbonCell8", top = 88, bottom = 119, left = 80, right = 112 },
  { key = "ribbonPagePrev", top = 12, bottom = 51, left = 116, right = 139 },
  { key = "ribbonPageNext", top = 76, bottom = 115, left = 116, right = 139 },
  { key = "ribbonExit", top = 176, bottom = 191, left = 208, right = 255 },
  { key = "skillsWideRow", top = 136, bottom = 151, left = 8, right = 87 },
  { key = "moveWideRow", top = 152, bottom = 183, left = 8, right = 127 },
  { key = "exitPanel", top = 165, bottom = 188, left = 190, right = 249 },
  { key = "selectorPair0", top = 40, bottom = 63, left = 192, right = 239 },
  { key = "selectorPair1", top = 104, bottom = 127, left = 192, right = 239 },
}

function T.touch_targets_cover_every_native_control_in_source_order(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local hitboxes = assert(bundle.manifest.hitboxes, "the compiled manifest carries its hitboxes")
  local touch = assert(hitboxes.touch, "the touch target set compiles")
  local count = 0
  for _ in pairs(touch) do
    count = count + 1
  end
  Assert.equal(count, #EXPECTED_TOUCH_ORDER, "the touch set drops no source box and invents none")
  for _, expected in ipairs(EXPECTED_TOUCH_ORDER) do
    local box = assert(touch[expected.key], "the touch set carries " .. expected.key)
    Assert.equal(box.top, expected.top, expected.key .. " keeps its top edge")
    Assert.equal(box.bottom, expected.bottom, expected.key .. " keeps its bottom edge")
    Assert.equal(box.left, expected.left, expected.key .. " keeps its left edge")
    Assert.equal(box.right, expected.right, expected.key .. " keeps its right edge")
  end
end

-- Sounds and transitions compile to their calibrated empty records: the
-- overlay selects numeric effect ids and hardcodes its sprite timing at
-- the state call sites, and no generated-family consumer resolves either
-- section yet. The envelope keeps both closed keys with their shape
-- validators so a future populated section validates; emptiness is the
-- documented complete state, not a missing population.
function T.absent_sections_carry_the_documented_closed_excuse(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local sounds = assert(bundle.manifest.sounds, "the manifest keeps its closed sounds key")
  Assert.isTrue(next(sounds) == nil, "no sound role compiles without a resolving consumer")
  local transitions = assert(bundle.manifest.transitions, "the manifest keeps its closed transitions key")
  Assert.isTrue(next(transitions) == nil, "no transition track compiles without a resolving consumer")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "mon-catalog:global", "mon-layout:global" }
return suite
