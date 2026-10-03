-- ROM conformance for the HGSS mart presentation family. A single compiled
-- bundle serves source identity checks and staged-cache readiness checks.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local RomSuite = require("tests.rom.support.RomSuite")
local Hashing = require("romdump.src.digest.Hashing")

local T = {}
local bundles = {}

local function feature(moduleName, behavior)
  local ok, module = pcall(require, moduleName)
  Assert.isTrue(ok, behavior .. " must be available")
  return module
end

local function compile(romFs)
  local versionId = romFs:version()
  if bundles[versionId] == nil then
    local compiler = feature(
      "romdump.src.digest.ui.MartAssetCompiler",
      "the ROM-derived mart compiler must compile the required presentation"
    )
    bundles[versionId] = assert(compiler.compile(romFs))
  end
  return bundles[versionId]
end

local function dependency(bundle, name)
  for _, entry in ipairs(bundle.provenance.dependencies) do
    if entry.name == name then
      return entry
    end
  end
  error("mart provenance is missing dependency " .. name, 2)
end

function T.source_configuration_changes_the_mart_family_identity(romFs)
  local original = compile(romFs)
  local MartSources = feature("romdump.src.config.MartSources", "mart source configuration is fingerprinted")
  local Compiler = feature("romdump.src.digest.ui.MartAssetCompiler", "mart source configuration recompiles through its owner")
  local originalSourceHash = dependency(original, "martSources").sha1
  Assert.equal(originalSourceHash, Hashing.hashLua(MartSources), "provenance records the current source configuration")

  local originalTicks = MartSources.controls.feedback.selectedTicks
  MartSources.controls.feedback.selectedTicks = originalTicks + 1
  local ok, changed, compileError = pcall(Compiler.compile, romFs)
  MartSources.controls.feedback.selectedTicks = originalTicks

  Assert.isTrue(ok, "changing a source configuration value must remain compilable")
  Assert.notNil(changed, tostring(compileError))
  local changedSourceHash = dependency(changed, "martSources").sha1
  Assert.isFalse(changedSourceHash == originalSourceHash, "source configuration bytes affect the dependency hash")
  Assert.isFalse(changed.provenance.dependencyHash == original.provenance.dependencyHash)
  Assert.isFalse(changed.marker == original.marker, "a source configuration change makes the family stale")
end

function T.compiled_presentation_is_complete_and_cache_readiness_checks_every_image(romFs)
  local bundle = compile(romFs)
  local MartCache = feature("libs.assets.src.MartCache", "the published mart family must have a cache reader")
  local BagCache = feature("libs.assets.src.BagCache", "the bag family remains an independent cache owner")
  local PartyCache = feature("libs.assets.src.PartyCache", "the party family remains an independent cache owner")
  local Writer = feature("romdump.src.digest.ui.MartCacheWriter", "the mart presentation must be publishable")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion(romFs:version(), backend)
  cache:write(BagCache.markerPath(), "bag-marker")
  cache:write(BagCache.assetDir() .. "/family-sentinel", "bag-bytes")
  cache:write(PartyCache.markerPath(), "party-marker")
  cache:write(PartyCache.assetDir() .. "/family-sentinel", "party-bytes")

  Assert.equal(Writer.write(cache, bundle), bundle.marker, "writer returns the bundle's family marker")
  Assert.isTrue(MartCache.isReady(cache, bundle.marker), "complete presentation is ready")
  Assert.equal(cache:read(BagCache.markerPath()), "bag-marker", "mart publication leaves the bag family intact")
  Assert.equal(cache:read(BagCache.assetDir() .. "/family-sentinel"), "bag-bytes")
  Assert.equal(cache:read(PartyCache.markerPath()), "party-marker", "mart publication leaves the party family intact")
  Assert.equal(cache:read(PartyCache.assetDir() .. "/family-sentinel"), "party-bytes")

  local manifest = MartCache.loadManifest(cache)
  for count = 0, 6 do
    local visual = assert(manifest.lower.backgrounds.browse[count], "browse count " .. count .. " must be present")
    Assert.isTrue(type(visual.image) == "string" and visual.image ~= "", "browse variants reference a family image")
  end
  Assert.isTrue(
    manifest.lower.backgrounds.quantity.image ~= manifest.lower.backgrounds.confirm.image,
    "quantity and confirmation use separate source maps"
  )

  local paths = MartCache.referencedPaths(manifest)
  Assert.isTrue(#paths > 0, "the presentation references its realized images")
  backend:remove("heartgold/" .. paths[1])
  Assert.isFalse(MartCache.isReady(cache, bundle.marker), "readiness fails when a referenced image is missing")
end

function T.vanilla_stock_and_animation_timelines_retain_source_identity(romFs)
  local bundle = compile(romFs)
  local catalog, manifest = bundle.catalog, bundle.manifest
  Assert.equal(#catalog.specialStocks, 30, "all special stock tables are represented in source order")
  Assert.equal(#catalog.athleteStocks, 14, "all AP stock tables are represented in source order")
  Assert.equal(#catalog.dataCardStocks, 5, "all Data Card groups are represented")
  Assert.equal(#catalog.sealStocks, 7, "all seal lists are represented")
  Assert.equal(#catalog.decorationStocks, 2, "both decoration lists are represented")
  Assert.equal(#catalog.normalTiers, 19, "normal stock retains its source tier table")

  local clip = manifest.animations.selectionEntry
  Assert.equal(#clip.frames, 4, "selection entry retains its four source states, including invisible frames")
  for _, frame in ipairs(clip.frames) do
    Assert.equal(frame.ticks, 6, "each selection state preserves its six-tick source duration")
  end
  Assert.equal(clip.totalTicks, 24, "selection timeline totals four six-tick states")
  Assert.equal(manifest.feedback.selectedTicks, 4)
  Assert.equal(manifest.feedback.restoredTicks, 2)
  Assert.equal(manifest.feedback.dispatchTicks, 1)
end

function T.vanilla_provider_uses_the_compiled_source_catalog_without_rendering(romFs, versionId)
  local bundle = compile(romFs)
  local ItemCatalogCompiler = require("romdump.src.digest.items.ItemCatalogCompiler")
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local VanillaMartStock = require("game.hgss.src.mart.VanillaMartStock")
  local items = ItemCatalog.new(assert(ItemCatalogCompiler.compileCatalog(romFs, { versionId = versionId })))
  local runtimeCatalog = { mart = bundle.catalog, items = items }
  local function resolve(descriptor, facts)
    return VanillaMartStock.resolve(descriptor, facts, runtimeCatalog)
  end

  local vanilla = resolve({ kind = "standard" }, {
    badges = 0,
    nationalDex = false,
    weekday = 0,
    dayOrdinal = 1,
    cardPrefix = 0,
    readFlag = function() return false end,
    readVariable = function() return 0 end,
  })
  local sourceTier = {}
  for _, row in ipairs(bundle.catalog.normalTiers) do
    if row.minimumTier == 1 then sourceTier[#sourceTier + 1] = row.itemKey end
  end
  Assert.equal(#vanilla.entries, #sourceTier, "the provider emits the source's first badge tier")
  for index, key in ipairs(sourceTier) do
    Assert.equal(vanilla.entries[index].displayItemKey, key, "standard items retain source order")
    Assert.equal(vanilla.entries[index].unitPrice, items:item(key).price, "standard prices resolve from the compiled item catalog")
  end

  for selector = 0, 29 do
    for _, tutorialComplete in ipairs({ false, true }) do
      local special = resolve({ kind = "special", selector = selector }, {
        badges = 0,
        nationalDex = false,
        weekday = 0,
        dayOrdinal = 1,
        cardPrefix = 0,
        readFlag = function(flag) return flag == 0x09A and tutorialComplete end,
        readVariable = function() return 0 end,
      })
      local expected = {}
      for _, row in ipairs(bundle.catalog.specialStocks[selector + 1]) do
        if not (tutorialComplete and row.subjectKey == "POKE_BALL") then expected[#expected + 1] = row.subjectKey end
      end
      Assert.equal(#special.entries, #expected, "special stock keeps the source list and tutorial filter")
      for index, key in ipairs(expected) do
        Assert.equal(special.entries[index].displayItemKey, key, "special entries retain source order")
      end
    end
  end

  for weekday = 0, 6 do
    for _, nationalDex in ipairs({ false, true }) do
      local stockIndex = weekday + (nationalDex and 7 or 0)
      local athlete = resolve({ kind = "athlete" }, {
        badges = 0,
        nationalDex = nationalDex,
        weekday = weekday,
        dayOrdinal = 1,
        cardPrefix = 0,
        readFlag = function() return false end,
        readVariable = function() return 0 end,
      })
      local expected = bundle.catalog.athleteStocks[stockIndex + 1]
      Assert.equal(#athlete.entries, #expected, "the AP weekday/Dex pair chooses its compiled source list")
      for index, row in ipairs(expected) do
        Assert.equal(athlete.entries[index].displayItemKey, row.subjectKey, "AP entries retain source order")
        Assert.equal(athlete.entries[index].unitPrice, row.price.value, "AP price is fixed by source data")
      end
    end
  end

  for _, prefix in ipairs({ 0, 5, 6, 11, 12, 23, 24, 26, 27 }) do
    local group = math.min(math.floor(prefix / 6), 4)
    local cards = resolve({ kind = "data_cards" }, {
      badges = 0,
      nationalDex = false,
      weekday = 0,
      dayOrdinal = 1,
      cardPrefix = prefix,
      readFlag = function() return false end,
      readVariable = function() return 0 end,
    })
    local expected = bundle.catalog.dataCardStocks[group + 1]
    Assert.equal(#cards.entries, #expected, "the first-missing card index chooses its source group")
    for index, row in ipairs(expected) do
      Assert.equal(cards.entries[index].displayItemKey, row.subjectKey, "Data Cards retain source order")
      Assert.equal(cards.entries[index].unitPrice, row.price.value, "Data Card price comes from the source table")
    end
  end
end

function T.failed_rebuild_and_truncated_manifest_leave_no_usable_partial_family(romFs)
  local bundle = compile(romFs)
  local MartCache = feature("libs.assets.src.MartCache", "the mart family must validate readiness")
  local MartAssetSchema = feature("libs.assets.src.MartAssetSchema", "the mart manifest schema must reject truncation")
  local Writer = feature("romdump.src.digest.ui.MartCacheWriter", "the mart family must publish atomically")
  local BagCache = feature("libs.assets.src.BagCache", "the bag family remains an independent cache owner")
  local PartyCache = feature("libs.assets.src.PartyCache", "the party family remains an independent cache owner")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion(romFs:version(), backend)
  cache:write(BagCache.markerPath(), "bag-marker")
  cache:write(BagCache.assetDir() .. "/family-sentinel", "bag-bytes")
  cache:write(PartyCache.markerPath(), "party-marker")
  cache:write(PartyCache.assetDir() .. "/family-sentinel", "party-bytes")
  Writer.write(cache, bundle)
  Assert.isTrue(MartCache.isReady(cache, bundle.marker), "the starting family is ready")

  local markerBefore = cache:read(MartCache.markerPath())
  local manifestBefore = cache:read(MartCache.manifestPath())
  local originalWrite = backend.write
  local stagedWriteAttempts = 0
  backend.write = function(self, path, data)
    if path:match("^staging/heartgold/") then
      stagedWriteAttempts = stagedWriteAttempts + 1
      return false
    end
    return originalWrite(self, path, data)
  end
  local replacement = {}
  for key, value in pairs(bundle) do
    replacement[key] = value
  end
  replacement.provenance = {}
  for key, value in pairs(bundle.provenance) do
    replacement.provenance[key] = value
  end
  replacement.provenance.dependencyHash = string.rep("b", 40)
  replacement.marker = MartCache.marker(replacement.provenance.versionRomSha1, replacement.provenance.dependencyHash)
  local ok = pcall(Writer.write, cache, replacement)
  backend.write = originalWrite

  Assert.isFalse(ok, "a staged write failure aborts the rebuild")
  Assert.isTrue(stagedWriteAttempts > 0, "the injected fault must reach the staged writer")
  Assert.equal(cache:read(MartCache.markerPath()), markerBefore, "the previous marker remains live")
  Assert.equal(cache:read(MartCache.manifestPath()), manifestBefore, "the previous manifest remains live")
  Assert.isTrue(MartCache.isReady(cache, bundle.marker), "the prior family stays ready after failure")
  Assert.equal(cache:read(BagCache.markerPath()), "bag-marker", "failed mart publication preserves the bag marker")
  Assert.equal(cache:read(BagCache.assetDir() .. "/family-sentinel"), "bag-bytes")
  Assert.equal(cache:read(PartyCache.markerPath()), "party-marker", "failed mart publication preserves the party marker")
  Assert.equal(cache:read(PartyCache.assetDir() .. "/family-sentinel"), "party-bytes")

  local truncated = {}
  for key, value in pairs(replacement) do
    truncated[key] = value
  end
  truncated.manifest = {}
  for key, value in pairs(replacement.manifest) do
    truncated.manifest[key] = value
  end
  truncated.manifest.lower = {}
  for key, value in pairs(replacement.manifest.lower) do
    truncated.manifest.lower[key] = value
  end
  truncated.manifest.lower.quantity = {}
  for key, value in pairs(replacement.manifest.lower.quantity) do
    truncated.manifest.lower.quantity[key] = value
  end
  truncated.manifest.lower.quantity.digitBoxes = nil
  Assert.isFalse(MartAssetSchema.isValidManifest(truncated.manifest), "a truncated manifest is invalid")
  Assert.isFalse(pcall(Writer.write, cache, truncated), "the writer rejects a truncated manifest")
  Assert.equal(cache:read(MartCache.markerPath()), markerBefore, "truncated output cannot replace the marker")
  Assert.equal(cache:read(MartCache.manifestPath()), manifestBefore, "truncated output cannot replace the manifest")
  Assert.isTrue(MartCache.isReady(cache, bundle.marker), "the previous family remains ready")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "rom_source" }
return suite
