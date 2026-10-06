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

local SUMMARY_SCHEMA = "g4-summary-manifest-v3"
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
-- variant, and every semantic role resolves to a named native pane
-- through the fixed and group role records.
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
  local function checkRole(role, key)
    Assert.isTrue(role.pane == "main" or role.pane == "sub", "role " .. tostring(key) .. " names a native pane")
    panes[role.pane] = true
    count = count + 1
  end
  for key, role in pairs(assert(windows.fixed, "the fixed roles compile")) do
    checkRole(role, "fixed." .. tostring(key))
  end
  for _, name in ipairs({ "info", "skills", "performance" }) do
    local roles = assert(windows.groups, "the group roles compile")[name]
    Assert.notNil(roles, "the " .. name .. " roles resolve")
    for key, role in pairs(assert(roles.main, "the " .. name .. " main roles resolve")) do
      checkRole(role, name .. ".main." .. tostring(key))
    end
    for key, role in pairs(assert(roles.sub, "the " .. name .. " sub roles resolve")) do
      checkRole(role, name .. ".sub." .. tostring(key))
    end
  end
  Assert.isTrue(count > 0, "the compiled manifest carries semantic window roles")
  Assert.isTrue(panes.main == true, "main-pane roles resolve")
  Assert.isTrue(panes.sub == true, "sub-pane roles resolve")
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
  local function checkRole(name, window)
    Assert.isTrue(
      type(window.palette) == "number",
      "role " .. tostring(name) .. " carries its numeric palette slot"
    )
    slots[window.palette] = true
  end
  for name, window in pairs(assert(windows.fixed, "the fixed roles compile")) do
    checkRole("fixed." .. tostring(name), window)
  end
  for _, group in ipairs({ "info", "skills", "performance" }) do
    local roles = assert(windows.groups, "the group roles compile")[group]
    for name, window in pairs(assert(roles.main, "the " .. group .. " main roles resolve")) do
      checkRole(group .. ".main." .. tostring(name), window)
    end
    for name, window in pairs(assert(roles.sub, "the " .. group .. " sub roles resolve")) do
      checkRole(group .. ".sub." .. tostring(name), window)
    end
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

-- Sounds compile to their calibrated empty record: the overlay selects
-- numeric effect ids at its state call sites and no generated-family
-- consumer resolves sound roles yet. Transition tracks are required
-- content now: the nested move/ribbon states consume generated BG
-- position traces, so the envelope keeps a populated transition section
-- beside the empty sounds.
function T.absent_sections_carry_the_documented_closed_excuse(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local sounds = assert(bundle.manifest.sounds, "the manifest keeps its closed sounds key")
  Assert.isTrue(next(sounds) == nil, "no sound role compiles without a resolving consumer")
  local transitions = assert(bundle.manifest.transitions, "the manifest keeps its closed transitions key")
  Assert.isTrue(next(transitions) ~= nil, "the nested detail tracks compile for their resolving consumer")
end

-- The compiled windows keep source geometry under semantic ownership:
-- persistent fixed roles plus per-group main/sub roles whose pixel
-- rects are the pinned tile rows scaled by 8. No ordinal top-level
-- contract survives: consumers never infer a role from a position.
local EXPECTED_GROUP_RECTS = {
  { pane = "sub", x = 96, y = 8, width = 24, height = 16 },
  { pane = "sub", x = 72, y = 24, width = 72, height = 16 },
  { pane = "sub", x = 72, y = 56, width = 72, height = 16 },
  { pane = "sub", x = 88, y = 72, width = 40, height = 16 },
  { pane = "sub", x = 80, y = 104, width = 56, height = 16 },
  { pane = "sub", x = 88, y = 136, width = 48, height = 16 },
  { pane = "main", x = 0, y = 24, width = 144, height = 144 },
  { pane = "main", x = 8, y = 176, width = 88, height = 16 },
  { pane = "main", x = 88, y = 24, width = 56, height = 16 },
  { pane = "main", x = 104, y = 48, width = 24, height = 16 },
  { pane = "main", x = 104, y = 64, width = 24, height = 16 },
  { pane = "main", x = 104, y = 80, width = 24, height = 16 },
  { pane = "main", x = 104, y = 96, width = 24, height = 16 },
  { pane = "main", x = 104, y = 112, width = 24, height = 16 },
  { pane = "main", x = 72, y = 136, width = 72, height = 16 },
  { pane = "main", x = 0, y = 152, width = 152, height = 32 },
  { pane = "sub", x = 40, y = 8, width = 88, height = 32 },
  { pane = "sub", x = 40, y = 40, width = 88, height = 32 },
  { pane = "sub", x = 40, y = 72, width = 88, height = 32 },
  { pane = "sub", x = 40, y = 104, width = 88, height = 32 },
  { pane = "sub", x = 40, y = 152, width = 88, height = 32 },
  { pane = "sub", x = 216, y = 48, width = 24, height = 16 },
  { pane = "sub", x = 216, y = 64, width = 24, height = 16 },
  { pane = "sub", x = 136, y = 80, width = 120, height = 80 },
  { pane = "sub", x = 8, y = 160, width = 120, height = 16 },
  { pane = "sub", x = 8, y = 136, width = 80, height = 16 },
  { pane = "sub", x = 104, y = 136, width = 40, height = 16 },
  { pane = "sub", x = 8, y = 128, width = 168, height = 16 },
  { pane = "sub", x = 8, y = 144, width = 240, height = 32 },
  { pane = "main", x = 8, y = 24, width = 80, height = 16 },
  { pane = "main", x = 8, y = 56, width = 80, height = 16 },
  { pane = "main", x = 8, y = 88, width = 80, height = 16 },
  { pane = "main", x = 8, y = 120, width = 80, height = 16 },
  { pane = "main", x = 8, y = 152, width = 80, height = 16 },
}

local function rectKey(pane, rect)
  return pane .. ":" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "x" .. rect.height
end

local function collectRoleRects(roles, out, what)
  for name, role in pairs(roles) do
    local label = what .. "." .. tostring(name)
    Assert.isTrue(type(role) == "table", label .. " is a semantic role record")
    Assert.isTrue(role.pane == "main" or role.pane == "sub", label .. " names a native pane")
    Assert.isTrue(type(role.rect) == "table", label .. " carries its geometry")
    for _, axis in ipairs({ "x", "y", "width", "height" }) do
      Assert.isTrue(
        type(role.rect[axis]) == "number" and role.rect[axis] % 1 == 0 and role.rect[axis] >= 0,
        label .. " keeps integral geometry"
      )
    end
    Assert.isTrue(
      role.rect.x + role.rect.width <= 256 and role.rect.y + role.rect.height <= 192,
      label .. " fits the native pane"
    )
    Assert.isTrue(type(role.palette) == "number", label .. " carries its palette slot")
    out[#out + 1] = rectKey(role.pane, role.rect)
  end
end

function T.compiled_windows_carry_semantic_fixed_and_group_roles(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local windows = assert(bundle.manifest.windows, "the compiled manifest carries its windows")
  Assert.keySet(windows, "fixed,groups", "windows expose fixed roles and group roles only")
  local fixedCount = 0
  local fixedRects = {}
  collectRoleRects(assert(windows.fixed, "the fixed roles compile"), fixedRects, "fixed")
  for _ in pairs(windows.fixed) do
    fixedCount = fixedCount + 1
  end
  Assert.isTrue(fixedCount >= 10, "the fixed roles cover the persistent header and label windows")
  local groups = assert(windows.groups, "the group roles compile")
  Assert.keySet(groups, "info,performance,skills", "exactly the three native groups compile roles")
  local actual = {}
  for _, name in ipairs({ "info", "skills", "performance" }) do
    local group = assert(groups[name], "the " .. name .. " roles resolve")
    Assert.isTrue(type(group.main) == "table", "the " .. name .. " main roles resolve")
    Assert.isTrue(type(group.sub) == "table", "the " .. name .. " sub roles resolve")
    collectRoleRects(group.main, actual, name .. ".main")
    collectRoleRects(group.sub, actual, name .. ".sub")
  end
  Assert.equal(#actual, #EXPECTED_GROUP_RECTS, "the groups keep 8/18/8 source windows")
  local expected = {}
  for _, rect in ipairs(EXPECTED_GROUP_RECTS) do
    expected[#expected + 1] = rectKey(rect.pane, rect)
  end
  table.sort(actual)
  table.sort(expected)
  Assert.deepEqual(actual, expected, "group geometry matches the pinned source rows")
end

-- Memo branches evaluate first-match in source condition order. The
-- traded gift-location closure entry never selects on its own, and
-- location classes arrive normalized instead of as packed source ids.
local EXPECTED_MEMO_ORDER = {
  "migrated",
  "fatefulEncounter",
  "fatefulEncounterTraded",
  "wildGift",
  "wildEncounter",
  "wildEncounterTraded",
  "fatefulEggHatchedGift",
  "fatefulEggHatchedGiftTraded",
  "fatefulEggHatchedArrived",
  "fatefulEggHatchedArrivedTraded",
  "fatefulEggHatched",
  "fatefulEggHatchedTraded",
  "eggHatchedGift",
  "eggHatchedGiftTraded",
  "eggHatched",
  "eggHatchedTraded",
  "fatefulEggArrived",
  "fatefulEgg",
  "fatefulEggTraded",
  "egg",
  "eggTraded",
}

function T.compiled_memo_branches_keep_the_source_evaluation_order(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local memo = assert(bundle.manifest.memo, "the compiled manifest carries its memo records")
  local conditions = assert(memo.conditions, "the memo branches compile")
  Assert.isTrue(conditions[1] ~= nil, "the memo branches keep first-match order")
  local keys = {}
  for index, entry in ipairs(conditions) do
    local key = assert(entry.key, "branch " .. index .. " names its semantic key")
    keys[#keys + 1] = key
    if key == "wildGiftTraded" then
      Assert.equal(entry.selectable, false, "the traded gift closure never selects on its own")
    else
      Assert.equal(entry.selectable, true, "branch " .. key .. " participates in selection")
    end
    Assert.isTrue(type(entry.match) == "table", "branch " .. key .. " carries its match predicates")
    Assert.isTrue(type(entry.lines) == "table", "branch " .. key .. " carries its line placement")
    Assert.isTrue(
      type(entry.dateTemplate) == "table", "branch " .. key .. " carries its date template"
    )
  end
  local selectable = {}
  for _, key in ipairs(keys) do
    if key ~= "wildGiftTraded" then
      selectable[#selectable + 1] = key
    end
  end
  Assert.deepEqual(selectable, EXPECTED_MEMO_ORDER, "selectable branches mirror the source condition order")
  local locations = assert(memo.locations, "the memo location classes compile")
  for _, field in ipairs({ "palPark", "linkTrade", "linkTrade2", "ranger", "giftEggOrigins" }) do
    Assert.notNil(locations[field], "the location classes carry " .. field)
  end
  Assert.isTrue(
    type(locations.giftEggOrigins) == "table" and #locations.giftEggOrigins > 0,
    "the gift-egg origins keep their source set"
  )
  -- The migrated-region wording is bound per supported origin game by the
  -- producer: both games resolve the source Johto region entry, and the
  -- bound keys name real generated wording.
  local regions = assert(memo.migrationRegions, "the memo binds migration regions per game")
  Assert.equal(regions.heartgold, regions.soulsilver, "both supported games bind the Johto wording")
  local landmarks = assert(memo.landmarks, "the memo carries landmark records")
  local giftByLocation = assert(landmarks.giftByLocation, "the memo carries gift locations")
  local SummarySources = require("romdump.src.config.SummarySources")
  Assert.equal(
    regions.heartgold,
    giftByLocation[SummarySources.memoLocations.johto],
    "the migration mapping normalizes the source Johto region entry"
  )
  local labels = assert(bundle.manifest.text, "the manifest carries lowered text").labels
  Assert.isTrue(
    type(labels[regions.heartgold]) == "string" and labels[regions.heartgold] ~= "",
    "the migration region names generated wording"
  )
end

-- Memo date templates bind semantic substitutions: met/egg date,
-- location, level, and migration bindings by name, with literal text,
-- line breaks, and color operations retained. No raw message-format
-- field number survives for runtime to decode.
local MEMO_SEGMENT_VOCABULARY = {
  text = true,
  lineBreak = true,
  color = true,
  metYear = true,
  metMonth = true,
  metDay = true,
  metLevel = true,
  metLocation = true,
  eggYear = true,
  eggMonth = true,
  eggDay = true,
  eggLocation = true,
  migrationRegion = true,
}

local function conditionByKey(conditions, key)
  for _, entry in ipairs(conditions) do
    if entry.key == key then
      return entry
    end
  end
  error("the compiled memo carries no ordered branch " .. key, 0)
end

local function checkSemanticTemplate(entry, requiredKinds, what)
  local template = assert(entry.dateTemplate, "branch " .. entry.key .. " carries its " .. what .. " template")
  local segments = assert(template.segments, "the " .. what .. " template carries segments")
  Assert.isTrue(#segments > 0, "the " .. what .. " template is nonempty")
  local kinds = {}
  for _, segment in ipairs(segments) do
    Assert.isTrue(
      MEMO_SEGMENT_VOCABULARY[segment.kind] == true,
      "the " .. what .. " template uses semantic kinds, not " .. tostring(segment.kind)
    )
    Assert.isNil(segment.field, "the " .. what .. " template carries no raw placeholder field")
    kinds[segment.kind] = true
  end
  local found = false
  for _, kind in ipairs(requiredKinds) do
    if kinds[kind] == true then
      found = true
    end
  end
  Assert.isTrue(found, "the " .. what .. " template binds its semantic substitution")
  return kinds
end

function T.compiled_memo_templates_bind_semantic_substitutions(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local memo = assert(bundle.manifest.memo, "the compiled manifest carries its memo records")
  local conditions = assert(memo.conditions, "the memo branches compile")
  local metKinds = checkSemanticTemplate(
    conditionByKey(conditions, "wildEncounter"),
    { "metYear", "metMonth", "metDay", "metLevel", "metLocation" },
    "ordinary met"
  )
  checkSemanticTemplate(
    conditionByKey(conditions, "eggHatched"),
    { "eggYear", "eggMonth", "eggDay", "eggLocation", "metYear", "metMonth", "metDay", "metLocation" },
    "hatched"
  )
  checkSemanticTemplate(
    conditionByKey(conditions, "egg"),
    { "eggYear", "eggMonth", "eggDay", "eggLocation" },
    "egg"
  )
  checkSemanticTemplate(conditionByKey(conditions, "migrated"), { "migrationRegion" }, "migrated")
  local textSeen, breakSeen = false, false
  for _, entry in ipairs(conditions) do
    for _, segment in ipairs(assert(entry.dateTemplate, "branch carries its template").segments) do
      if segment.kind == "text" then
        textSeen = true
      elseif segment.kind == "lineBreak" then
        breakSeen = true
      end
    end
  end
  Assert.isTrue(metKinds.text == true or textSeen, "memo templates retain their literal text")
  Assert.isTrue(breakSeen, "memo templates retain their line breaks")
end

-- Migrated memo wording covers the canonical origin-game domain: every
-- game identity the mon service accepts resolves to generated wording
-- through its source region entry. GBA groups share their region entry,
-- both HGSS games share Johto, the D/P/Pt group resolves the source
-- dashes entry rather than Sinnoh, and GameCube resolves Distant Land.
function T.migrated_memo_wording_covers_every_canonical_origin_game(romFs, versionId)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local SummarySources = require("romdump.src.config.SummarySources")
  local bundle = bundleFor(romFs, versionId)
  local memo = assert(bundle.manifest.memo, "the compiled manifest carries its memo records")
  local regions = assert(memo.migrationRegions, "the memo binds migration regions per game")
  local canonical = {}
  for key in pairs(HgssMonService.GAMES) do
    canonical[#canonical + 1] = key
  end
  table.sort(canonical)
  local actual = {}
  for key in pairs(regions) do
    actual[#actual + 1] = key
  end
  table.sort(actual)
  Assert.deepEqual(actual, canonical, "the migration map covers the canonical origin-game domain")
  local landmarks = assert(memo.landmarks, "the memo carries landmark records")
  local giftByLocation = assert(landmarks.giftByLocation, "the memo carries gift locations")
  local sourceLocations = SummarySources.memoLocations
  Assert.equal(regions.ruby, giftByLocation[sourceLocations.hoenn], "ruby resolves the Hoenn wording")
  Assert.equal(regions.sapphire, regions.ruby, "sapphire shares the Hoenn wording")
  Assert.equal(regions.emerald, regions.ruby, "emerald shares the Hoenn wording")
  Assert.equal(regions.firered, giftByLocation[sourceLocations.kanto], "firered resolves the Kanto wording")
  Assert.equal(regions.leafgreen, regions.firered, "leafgreen shares the Kanto wording")
  Assert.equal(regions.heartgold, giftByLocation[sourceLocations.johto], "heartgold resolves the Johto wording")
  Assert.equal(regions.soulsilver, regions.heartgold, "soulsilver shares the Johto wording")
  Assert.equal(
    regions.diamond,
    giftByLocation[sourceLocations.dashes],
    "diamond resolves the source dashes wording"
  )
  Assert.equal(regions.pearl, regions.diamond, "pearl shares the dashes wording")
  Assert.equal(regions.platinum, regions.diamond, "platinum shares the dashes wording")
  Assert.isTrue(
    regions.diamond ~= giftByLocation[sourceLocations.sinnoh],
    "the D/P/Pt wording keeps the dashes entry instead of Sinnoh"
  )
  Assert.equal(
    regions.gamecube,
    giftByLocation[sourceLocations.distantLand],
    "gamecube resolves the Distant Land wording"
  )
  local labels = assert(bundle.manifest.text, "the manifest carries lowered text").labels
  for _, key in ipairs(canonical) do
    local wording = regions[key]
    Assert.isTrue(type(wording) == "string" and wording ~= "", "origin game " .. key .. " binds wording")
    Assert.isTrue(
      type(labels[wording]) == "string" and labels[wording] ~= "",
      "origin game " .. key .. " names generated wording text"
    )
  end
end

-- Source-pinned dynamic chrome anchors, as "x,y" pairs: the six primary
-- member/mode anchors, the secondary cancel and restricted-special
-- anchors, the five performance rows of five star anchors, the five
-- modifier anchors, the five leaf anchors, and the ribbon cursor plus
-- page controls.
local EXPECTED_SPRITE_ANCHORS = {
  "183,55",
  "223,63",
  "183,87",
  "223,95",
  "183,119",
  "223,127",
  "68,168",
  "220,176",
  "64,48",
  "80,48",
  "96,48",
  "112,48",
  "128,48",
  "64,80",
  "80,80",
  "96,80",
  "112,80",
  "128,80",
  "64,112",
  "80,112",
  "96,112",
  "112,112",
  "128,112",
  "64,144",
  "80,144",
  "96,144",
  "112,144",
  "128,144",
  "64,176",
  "80,176",
  "96,176",
  "112,176",
  "128,176",
  "80,32",
  "80,64",
  "80,96",
  "80,128",
  "80,160",
  "91,182",
  "101,182",
  "111,182",
  "121,182",
  "131,182",
  "32,24",
  "128,32",
  "128,96",
}

local function collectAnchorPairs(value, out, seen)
  if type(value) ~= "table" or seen[value] then
    return
  end
  seen[value] = true
  if type(value.x) == "number" and type(value.y) == "number" then
    local fields = 0
    for _ in pairs(value) do
      fields = fields + 1
    end
    if fields == 2 then
      out[value.x .. "," .. value.y] = true
    end
  end
  for _, child in pairs(value) do
    collectAnchorPairs(child, out, seen)
  end
end

local function spriteFrameBytes(bundle, path, what)
  local bytes = assert(bundle.assets[path], what .. " has compiled bytes: " .. path)
  if type(bytes) ~= "string" then
    bytes = bytes:getString()
  end
  return assert(bytes, what .. " decodes: " .. path)
end

-- The dynamic chrome family is complete and source-backed: every required
-- semantic role and animation descriptor is present, every frame resolves
-- to a family-owned visual with compiled bytes, and every source-pinned
-- anchor survives lowering. No frame points into party art.
function T.dynamic_chrome_roles_carry_source_rasterized_animation_visuals(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local manifest = assert(bundle.manifest, "compilation publishes a manifest")
  Assert.equal(manifest.schema, "g4-summary-manifest-v3", "the compiled manifest carries the family schema")
  local sprites = assert(manifest.sprites, "the compiled manifest carries its dynamic chrome")
  for _, role in ipairs({ "animations", "primaryCursor", "secondaryMoveCursor", "performance", "leaves", "ribbons" }) do
    Assert.notNil(sprites[role], "the dynamic chrome carries " .. role)
  end
  local visuals = assert(manifest.visuals, "the compiled manifest carries its visuals")
  local animations = assert(sprites.animations, "the dynamic chrome carries animation descriptors")
  local descriptorCount = 0
  for _ in pairs(animations) do
    descriptorCount = descriptorCount + 1
  end
  Assert.isTrue(descriptorCount > 0, "the animation closure is nonempty")
  local frameCount = 0
  for name, descriptor in pairs(animations) do
    local what = "animation " .. tostring(name)
    Assert.isTrue(type(descriptor) == "table", what .. " is a descriptor record")
    local frames = assert(descriptor.frames, what .. " carries frames")
    Assert.isTrue(#frames > 0, what .. " carries a nonempty sequence")
    for index, frame in ipairs(frames) do
      local label = what .. " frame " .. index
      Assert.isTrue(
        type(frame.durationTicks) == "number" and frame.durationTicks % 1 == 0 and frame.durationTicks > 0,
        label .. " carries a positive integral duration"
      )
      local visualName = assert(frame.visual, label .. " names its visual")
      local visual = assert(visuals[visualName], label .. " resolves to a family visual")
      local image = assert(visual.image, label .. " visual carries its image path")
      Assert.equal(
        image:sub(1, #SUMMARY_ASSET_DIR),
        SUMMARY_ASSET_DIR,
        label .. " art stays family-owned: " .. image
      )
      Assert.isTrue(image:find("party", 1, true) == nil, label .. " art never reuses party pixels")
      local width, height = PngReader.rgba(spriteFrameBytes(bundle, image, label))
      Assert.isTrue(width > 0 and height > 0, label .. " rasterizes to a real surface")
      frameCount = frameCount + 1
    end
    Assert.isTrue(
      descriptor.playback == "static" or descriptor.playback == "once" or descriptor.playback == "loop",
      what .. " carries source playback"
    )
    Assert.isTrue(
      type(descriptor.loopFrom) == "number"
        and descriptor.loopFrom % 1 == 0
        and descriptor.loopFrom >= 1
        and descriptor.loopFrom <= #frames,
      what .. " carries its loop origin inside its own sequence"
    )
  end
  Assert.isTrue(frameCount > 0, "the animation closure references frame visuals")
  local leaves = {}
  stringLeaves(sprites, leaves)
  for _, leaf in ipairs(leaves) do
    if leaf:sub(-4) == ".png" then
      Assert.isTrue(leaf:find("party", 1, true) == nil, "no dynamic image reuses party art: " .. leaf)
    end
  end
  local anchors = {}
  collectAnchorPairs(sprites, anchors, {})
  for _, expected in ipairs(EXPECTED_SPRITE_ANCHORS) do
    Assert.isTrue(anchors[expected] == true, "the dynamic chrome keeps anchor " .. expected)
  end
end

-- Nested move/ribbon presentation moves on native BG position traces over
-- one common backing: the generated tracks carry the source axes and
-- positions, and the shared member-21 visual keeps its renamed role.
function T.nested_detail_tracks_use_native_bg_positions_over_the_common_backing(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local manifest = assert(bundle.manifest, "compilation publishes a manifest")
  local transitions = assert(manifest.transitions, "the manifest carries transition tracks")
  Assert.keySet(transitions, "moveDetail,ribbonDetail", "exactly the two nested detail tracks compile")
  local move = assert(transitions.moveDetail, "the move detail track compiles")
  Assert.equal(move.pane, "sub", "the move track drives the sub pane")
  Assert.equal(move.axis, "x", "the move track moves along X")
  Assert.deepEqual(move.positions, { 0, 64, 128 }, "the move track keeps the native BG5 positions")
  local ribbon = assert(transitions.ribbonDetail, "the ribbon detail track compiles")
  Assert.equal(ribbon.pane, "sub", "the ribbon track drives the sub pane")
  Assert.equal(ribbon.axis, "y", "the ribbon track moves along Y")
  Assert.deepEqual(ribbon.positions, { 0, 36, 72 }, "the ribbon track keeps the native BG5 positions")
  local visuals = assert(manifest.visuals, "the compiled manifest carries its visuals")
  local backing = assert(visuals.detailBacking, "the common detail backing visual compiles")
  local image = assert(backing.image, "the detail backing carries its image path")
  Assert.equal(
    image:sub(1, #SUMMARY_ASSET_DIR),
    SUMMARY_ASSET_DIR,
    "the detail backing stays family-owned"
  )
  Assert.notNil(bundle.assets[image], "the detail backing has compiled bytes")
  Assert.isNil(visuals.moveBacking, "the move-only backing name does not survive the rename")
end

-- A reader that forwards every source call to the wrapped dump except
-- the overridden archives. Corrupted members exercise the chrome
-- resolver failure paths while the remaining closure stays real.
local function corruptFs(romFs, overrides)
  local wrapper = {}
  setmetatable(wrapper, {
    __index = function(_, key)
      if key == "openNarc" then
        return function(_, symbol)
          if overrides[symbol] ~= nil then
            return overrides[symbol]
          end
          return romFs:openNarc(symbol)
        end
      end
      local value = romFs[key]
      if type(value) == "function" then
        return function(_, ...)
          return value(romFs, ...)
        end
      end
      return value
    end,
  })
  return wrapper
end

local function corruptArchive(realArchive, corrupt)
  local fake = {}
  function fake:memberCount()
    return realArchive:memberCount()
  end
  function fake:readMember(memberId)
    if corrupt[memberId] ~= nil then
      local replacement = corrupt[memberId]
      if replacement == false then
        return nil, Errors.new("ROMFS_MEMBER_MISSING", "test archive drops member " .. memberId, {
          member = memberId,
        })
      end
      return replacement
    end
    return realArchive:readMember(memberId)
  end
  return fake
end

local function u32le(bytes, offset)
  return string.byte(bytes, offset + 1)
    + string.byte(bytes, offset + 2) * 256
    + string.byte(bytes, offset + 3) * 65536
    + string.byte(bytes, offset + 4) * 16777216
end

-- Splits one resource table into its head, its 24-byte record slices
-- keyed by object id, and its terminator slice.
local function tableSlices(bytes)
  local head = bytes:sub(1, 4)
  local records, offset = {}, 4
  local terminator = nil
  while offset + 24 <= #bytes do
    local slice = bytes:sub(offset + 1, offset + 24)
    if u32le(bytes, offset) == 0xFFFFFFFE then
      terminator = slice
      break
    end
    records[#records + 1] = { objectId = u32le(bytes, offset + 12), raw = slice }
    offset = offset + 24
  end
  return head, records, terminator
end

local function packU32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function dropTableRecord(bytes, objectId)
  local head, records, terminator = tableSlices(bytes)
  assert(terminator ~= nil, "the source table carries its terminator")
  local parts = { head }
  for _, record in ipairs(records) do
    if record.objectId ~= objectId then
      parts[#parts + 1] = record.raw
    end
  end
  parts[#parts + 1] = terminator
  return table.concat(parts)
end

-- Rewrites the file word (second word) of one table record, keeping
-- every other word verbatim.
local function repointTableRecord(bytes, objectId, fileId)
  local head, records, terminator = tableSlices(bytes)
  assert(terminator ~= nil, "the source table carries its terminator")
  local parts = { head }
  for _, record in ipairs(records) do
    if record.objectId ~= objectId then
      parts[#parts + 1] = record.raw
    else
      parts[#parts + 1] = record.raw:sub(1, 4) .. packU32(fileId) .. record.raw:sub(9, 24)
    end
  end
  parts[#parts + 1] = terminator
  return table.concat(parts)
end

-- A chrome header that does not open fails compilation instead of
-- publishing a family without dynamic chrome.
function T.missing_chrome_header_member_fails_compilation(romFs, versionId)
  local compiler = requireCompiler()
  local catalog = compileCatalog(romFs, versionId)
  local portraits = portraitManifest(versionId)
  local SummarySources = require("romdump.src.config.SummarySources")
  local realResdat = assert(romFs:openNarc(SummarySources.archives.resdat.symbol))
  local resdat = corruptArchive(realResdat, { [SummarySources.resdat.header] = false })
  local bundle, err =
    compiler.compile(corruptFs(romFs, { [SummarySources.archives.resdat.symbol] = resdat }), catalog, portraits)
  Assert.isNil(bundle, "an unreadable chrome header publishes nothing")
  Assert.isTrue(Errors.is(err), "an unreadable chrome header fails structurally")
  Assert.equal(err.code, "SUMMARY_SOURCE_INVALID", "the failure names its producer owner")
end

-- A chrome resource table that does not open fails compilation instead
-- of publishing a family without dynamic chrome.
function T.missing_chrome_table_member_fails_compilation(romFs, versionId)
  local compiler = requireCompiler()
  local catalog = compileCatalog(romFs, versionId)
  local portraits = portraitManifest(versionId)
  local SummarySources = require("romdump.src.config.SummarySources")
  local realResdat = assert(romFs:openNarc(SummarySources.archives.resdat.symbol))
  local resdat = corruptArchive(realResdat, { [SummarySources.resdat.animationTable] = false })
  local bundle, err =
    compiler.compile(corruptFs(romFs, { [SummarySources.archives.resdat.symbol] = resdat }), catalog, portraits)
  Assert.isNil(bundle, "an unreadable chrome table publishes nothing")
  Assert.isTrue(Errors.is(err), "an unreadable chrome table fails structurally")
  Assert.equal(err.code, "SUMMARY_SOURCE_INVALID", "the failure names its producer owner")
end

-- A resource set whose character entry leaves its table fails
-- compilation naming the affected role instead of rasterizing without
-- art.
function T.chrome_set_missing_its_table_entry_fails_compilation(romFs, versionId)
  local compiler = requireCompiler()
  local catalog = compileCatalog(romFs, versionId)
  local portraits = portraitManifest(versionId)
  local SummarySources = require("romdump.src.config.SummarySources")
  local realResdat = assert(romFs:openNarc(SummarySources.archives.resdat.symbol))
  local header = assert(realResdat:readMember(SummarySources.resdat.header))
  local set = assert(SummarySources.chromeResources.primaryCursor.resourceSet, "the inventory selects its set")
  local charObject = u32le(header, set * 32)
  local table54 = assert(realResdat:readMember(SummarySources.resdat.charTable))
  local resdat = corruptArchive(realResdat, { [SummarySources.resdat.charTable] = dropTableRecord(table54, charObject) })
  local bundle, err =
    compiler.compile(corruptFs(romFs, { [SummarySources.archives.resdat.symbol] = resdat }), catalog, portraits)
  Assert.isNil(bundle, "a chrome set without its table entry publishes nothing")
  Assert.isTrue(Errors.is(err), "a chrome set without its table entry fails structurally")
  Assert.equal(err.code, "SUMMARY_SOURCE_INVALID", "the failure names its producer owner")
end

-- A chrome animation that does not decode fails compilation instead of
-- publishing a family with blank frames. Repointing the selected
-- animation entry at the palette member feeds non-animation bytes to
-- the decoder.
function T.undecodable_chrome_animation_fails_compilation(romFs, versionId)
  local compiler = requireCompiler()
  local catalog = compileCatalog(romFs, versionId)
  local portraits = portraitManifest(versionId)
  local SummarySources = require("romdump.src.config.SummarySources")
  local realResdat = assert(romFs:openNarc(SummarySources.archives.resdat.symbol))
  local header = assert(realResdat:readMember(SummarySources.resdat.header))
  local set = assert(SummarySources.chromeResources.performance.resourceSet, "the inventory selects its set")
  local animObject = u32le(header, set * 32 + 8)
  local table52 = assert(realResdat:readMember(SummarySources.resdat.animationTable))
  local resdat =
    corruptArchive(realResdat, { [SummarySources.resdat.animationTable] = repointTableRecord(table52, animObject, 0) })
  local bundle, err =
    compiler.compile(corruptFs(romFs, { [SummarySources.archives.resdat.symbol] = resdat }), catalog, portraits)
  Assert.isNil(bundle, "an undecodable chrome animation publishes nothing")
  Assert.isTrue(Errors.is(err), "an undecodable chrome animation fails structurally")
  Assert.equal(err.code, "SUMMARY_SOURCE_INVALID", "the failure names its producer owner")
end

-- Frame timing and placement survive lowering: single-frame sequences
-- normalize to static playback without discarding their rasterizer
-- offsets, and multi-frame sequences keep their source playback.
function T.chrome_animation_timing_keeps_source_offsets_and_playback(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local manifest = assert(bundle.manifest, "compilation publishes a manifest")
  local visuals = assert(manifest.visuals, "the compiled manifest carries its visuals")
  local animations = assert(manifest.sprites.animations, "the dynamic chrome carries animation descriptors")
  local staticOffsetSeen, multiSeen = false, false
  for name, descriptor in pairs(animations) do
    local frames = assert(descriptor.frames, "animation " .. tostring(name) .. " carries frames")
    if #frames == 1 then
      Assert.equal(descriptor.playback, "static", "single-frame " .. tostring(name) .. " rests instead of cycling")
      local visual = assert(visuals[frames[1].visual], "single-frame " .. tostring(name) .. " resolves its visual")
      if visual.offset ~= nil then
        Assert.isTrue(
          type(visual.offset.x) == "number" and type(visual.offset.y) == "number",
          "single-frame " .. tostring(name) .. " keeps its integral raster offset"
        )
        staticOffsetSeen = true
      end
    else
      multiSeen = true
      Assert.isTrue(
        descriptor.playback == "once" or descriptor.playback == "loop",
        "multi-frame " .. tostring(name) .. " keeps its source playback"
      )
    end
  end
  Assert.isTrue(staticOffsetSeen, "single-frame normalization keeps a source raster offset")
  Assert.isTrue(multiSeen, "multi-frame sequences keep source playback")
end

-- Dynamic-chrome placement keeps its source scalars and counts: the
-- nested move rows, the five performance rows of five stars with
-- modifier slots, the six member anchors, the five leaves, and the
-- ribbon grid controls.
function T.dynamic_chrome_geometry_keeps_its_source_scalars(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local sprites = assert(bundle.manifest.sprites, "the compiled manifest carries its dynamic chrome")
  local secondary = assert(sprites.secondaryMoveCursor, "the dynamic chrome carries its nested move geometry")
  Assert.equal(secondary.x, 68, "nested move rows keep their horizontal origin")
  Assert.equal(secondary.rowBaseY, 24, "nested move rows keep their vertical origin")
  Assert.equal(secondary.rowStep, 32, "nested move rows keep their row step")
  Assert.equal(secondary.cancelY, 152, "the ordinary cancel row keeps its position")
  Assert.equal(secondary.restrictedCancelY, 168, "the restricted cancel row keeps its position")
  local rows = assert(sprites.performance.rows, "the dynamic chrome carries its performance rows")
  Assert.equal(#rows, 5, "all five contest rows compile")
  local stats = { "speed", "power", "skill", "stamina", "jump" }
  local rowYs = { 48, 80, 112, 144, 176 }
  local modifierYs = { 32, 64, 96, 128, 160 }
  for index, row in ipairs(rows) do
    Assert.equal(row.stat, stats[index], "performance row " .. index .. " keeps its contest")
    Assert.equal(#row.stars, 5, "performance row " .. tostring(row.stat) .. " keeps five stars")
    for star, anchor in ipairs(row.stars) do
      Assert.equal(anchor.x, 64 + (star - 1) * 16, "star " .. star .. " keeps its column")
      Assert.equal(anchor.y, rowYs[index], "star " .. star .. " keeps its row")
    end
    Assert.equal(row.modifier.x, 80, "the modifier slot keeps its column")
    Assert.equal(row.modifier.y, modifierYs[index], "the modifier slot keeps its row")
  end
  Assert.equal(#sprites.primaryCursor.anchors, 6, "all six member anchors compile")
  Assert.equal(#sprites.leaves.anchors, 5, "all five leaf anchors compile")
  local ribbons = assert(sprites.ribbons, "the dynamic chrome carries its ribbon controls")
  Assert.equal(ribbons.columns, 3, "the ribbon grid keeps three columns")
  Assert.equal(ribbons.columnStep, 32, "the ribbon grid keeps its column step")
  Assert.equal(ribbons.rowStep, 40, "the ribbon grid keeps its row step")
  Assert.deepEqual(ribbons.origin, { x = 32, y = 24 }, "the ribbon grid keeps its origin")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "mon-catalog:global", "mon-layout:global" }
return suite
