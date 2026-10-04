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

local function bindingNames(program)
  local names = {}
  for _, part in ipairs(program.parts) do
    if part.kind == "binding" then
      names[#names + 1] = part.name
    end
  end
  return names
end

local function point(x, y)
  return { x = x, y = y }
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function boxCoordinates(box)
  return { x = box.x, y = box.y, width = box.width, height = box.height }
end

local function assertPoint(actual, expected, label)
  Assert.deepEqual({ x = actual.x, y = actual.y }, expected, label)
end

local function assertBox(actual, expected, label)
  Assert.deepEqual(boxCoordinates(actual), expected, label)
end

local function assertTextBox(actual, expected, label)
  Assert.deepEqual({
    textX = actual.textX,
    textY = actual.textY,
    alignment = actual.alignment,
  }, expected, label)
end

function T.compiled_messages_preserve_each_source_substitution_role(romFs)
  local templates = compile(romFs).manifest.text.templates
  local expected = {
    quantityPrompt = { "item" },
    moneyConfirm = { "quantity", "total" },
    itemReceived = { "item", "pocket" },
    moneyPrice = { "price" },
    pointsPrice = { "price" },
    sealReceived = { "item" },
    moneyBalance = { "balance" },
    pointsBalance = { "balance" },
    ownedCount = { "owned" },
    quantityTotal = { "total" },
    pageNumber = { "currentPage", "pageCount" },
    tensDigit = { "digit" },
    unitsDigit = { "digit" },
    pointsConfirm = { "item" },
    premierBonus = {},
  }
  for role, names in pairs(expected) do
    Assert.deepEqual(bindingNames(templates[role]), names, role .. " bindings preserve source meaning")
  end
end

function T.compiled_geometry_matches_audited_logical_coordinates(romFs)
  local manifest = compile(romFs).manifest
  local upper, lower = manifest.upper, manifest.lower

  assertBox(upper.description.items, rect(40, 144, 216, 48), "item description box")
  assertBox(upper.description.legacy, rect(8, 144, 216, 48), "legacy description box")
  assertPoint(upper.itemAnchor, point(22, 172), "upper item preview")

  local slotExpected = {
    { rect(0, 32, 128, 42), point(22, 59), rect(32, 40, 88, 32), point(68, 56), point(48, 56) },
    { rect(128, 32, 128, 42), point(152, 59), rect(160, 40, 88, 32), point(196, 56), point(176, 56) },
    { rect(0, 74, 128, 44), point(22, 100), rect(32, 80, 88, 32), point(68, 96), point(48, 96) },
    { rect(128, 74, 128, 44), point(152, 100), rect(160, 80, 88, 32), point(196, 96), point(176, 96) },
    { rect(0, 118, 128, 36), point(22, 139), rect(32, 120, 88, 32), point(68, 136), point(48, 136) },
    { rect(128, 118, 128, 36), point(152, 139), rect(160, 120, 88, 32), point(196, 136), point(176, 136) },
  }
  for index, expected in ipairs(slotExpected) do
    local slot = lower.slots[index]
    assertBox(slot.hitbox, expected[1], "slot " .. index .. " hitbox")
    assertPoint(slot.iconAnchor, expected[2], "slot " .. index .. " item icon")
    assertBox(slot.labelBox, expected[3], "slot " .. index .. " label")
    assertPoint(slot.priceAt, expected[4], "slot " .. index .. " price")
    assertPoint(slot.focusAnchor, expected[5], "slot " .. index .. " focus")
  end

  local browseControls = {
    { lower.pagePrevious, point(24, 176), rect(0, 168, 40, 24), "previous page" },
    { lower.pageNext, point(64, 176), rect(40, 168, 40, 24), "next page" },
    { lower.cancel, point(224, 176), rect(192, 168, 64, 24), "browse cancel" },
  }
  for _, expected in ipairs(browseControls) do
    assertPoint(expected[1].anchor, expected[2], expected[4] .. " anchor")
    assertBox(expected[1].hitbox, expected[3], expected[4] .. " hitbox")
  end

  local quantity = lower.quantity
  assertPoint(quantity.selectedItemAnchor, point(86, 76), "quantity selected item")
  assertBox(quantity.itemBox, rect(96, 56, 88, 32), "quantity item label")
  assertBox(quantity.owned.labelBox, rect(8, 104, 64, 40), "owned label")
  assertBox(quantity.owned.valueBox, rect(8, 104, 64, 40), "owned value")
  assertBox(quantity.totalBox, rect(184, 112, 64, 24), "quantity total")
  local quantityControls = {
    { quantity.increment10, point(136, 104), rect(120, 88, 32, 24), "+10" },
    { quantity.increment1, point(168, 104), rect(152, 88, 32, 24), "+1" },
    { quantity.decrement10, point(136, 152), rect(120, 136, 32, 24), "-10" },
    { quantity.decrement1, point(168, 152), rect(152, 136, 32, 24), "-1" },
    { quantity.confirm, point(136, 176), rect(96, 168, 78, 24), "quantity confirm" },
    { quantity.cancel, point(224, 176), rect(178, 168, 78, 24), "quantity cancel" },
  }
  for _, expected in ipairs(quantityControls) do
    assertPoint(expected[1].anchor, expected[2], expected[4] .. " anchor")
    assertBox(expected[1].hitbox, expected[3], expected[4] .. " hitbox")
  end
  assertBox(quantity.digitBoxes[1], rect(128, 112, 16, 24), "tens digit box")
  assertBox(quantity.digitBoxes[2], rect(160, 112, 16, 24), "units digit box")
  assertTextBox(quantity.digitBoxes[1], { textX = 0, textY = 4, alignment = "right" }, "tens digit baseline")
  assertTextBox(quantity.digitBoxes[2], { textX = 0, textY = 4, alignment = "right" }, "units digit baseline")

  assertBox(lower.balance.labelBox, rect(8, 0, 72, 32), "balance label")
  assertBox(lower.balance.valueBox, rect(8, 0, 72, 32), "balance value")
  assertTextBox(lower.balance.labelBox, { textX = 0, textY = 0, alignment = "left" }, "balance label baseline")
  assertTextBox(lower.balance.valueBox, { textX = 0, textY = 16, alignment = "right" }, "balance value baseline")
  assertBox(lower.pageBox, rect(80, 168, 56, 16), "page indicator")
  assertTextBox(lower.pageBox, { textX = 0, textY = 0, alignment = "right" }, "page indicator baseline")
  assertBox(lower.cancelLabelBox, rect(200, 168, 48, 16), "browse cancel label")
  assertTextBox(lower.cancelLabelBox, { textX = 0, textY = 0, alignment = "center" }, "browse cancel label baseline")
  assertTextBox(quantity.owned.labelBox, { textX = 0, textY = 4, alignment = "left" }, "owned label baseline")
  assertTextBox(quantity.owned.valueBox, { textX = 0, textY = 20, alignment = "right" }, "owned value baseline")
  assertTextBox(quantity.totalBox, { textX = 0, textY = 4, alignment = "right" }, "quantity total baseline")
  assertBox(quantity.buyLabelBox, rect(112, 168, 56, 16), "quantity BUY label")
  assertTextBox(quantity.buyLabelBox, { textX = 4, textY = 0, alignment = "left" }, "quantity BUY label baseline")
  assertBox(lower.messages.short, rect(16, 8, 216, 16), "short message")
  assertBox(lower.messages.tall, rect(16, 8, 216, 32), "tall message")
  assertBox(lower.messages.confirm, rect(96, 8, 136, 32), "quantity message")
  assertPoint(lower.yesNo.anchor, point(208, 48), "compact Yes/No")
end

function T.source_configuration_changes_the_mart_family_identity(romFs)
  local original = compile(romFs)
  local MartSources = feature("romdump.src.config.MartSources", "mart source configuration is fingerprinted")
  local Compiler =
    feature("romdump.src.digest.ui.MartAssetCompiler", "mart source configuration recompiles through its owner")
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
    readFlag = function()
      return false
    end,
    readVariable = function()
      return 0
    end,
  })
  local sourceTier = {}
  for _, row in ipairs(bundle.catalog.normalTiers) do
    if row.minimumTier == 1 then
      sourceTier[#sourceTier + 1] = row.itemKey
    end
  end
  Assert.equal(#vanilla.entries, #sourceTier, "the provider emits the source's first badge tier")
  for index, key in ipairs(sourceTier) do
    Assert.equal(vanilla.entries[index].displayItemKey, key, "standard items retain source order")
    Assert.equal(
      vanilla.entries[index].unitPrice,
      items:item(key).price,
      "standard prices resolve from the compiled item catalog"
    )
  end

  for selector = 0, 29 do
    for _, tutorialComplete in ipairs({ false, true }) do
      local special = resolve({ kind = "special", selector = selector }, {
        badges = 0,
        nationalDex = false,
        weekday = 0,
        dayOrdinal = 1,
        cardPrefix = 0,
        readFlag = function(flag)
          return flag == 0x09A and tutorialComplete
        end,
        readVariable = function()
          return 0
        end,
      })
      local expected = {}
      for _, row in ipairs(bundle.catalog.specialStocks[selector + 1]) do
        if not (tutorialComplete and row.subjectKey == "POKE_BALL") then
          expected[#expected + 1] = row.subjectKey
        end
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
        readFlag = function()
          return false
        end,
        readVariable = function()
          return 0
        end,
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
      readFlag = function()
        return false
      end,
      readVariable = function()
        return 0
      end,
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
  Assert.equal(
    cache:read(PartyCache.markerPath()),
    "party-marker",
    "failed mart publication preserves the party marker"
  )
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
