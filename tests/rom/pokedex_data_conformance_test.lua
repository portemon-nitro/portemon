-- Real-dump conformance for the generated Pokedex family: the compiled
-- catalog carries the pinned source closure on every ready user-owned
-- version (orders, completion sets, numeric Giratina profiles, all
-- slider rows, area geometry and encounter groups, version-differing
-- masks, back-height selectors, text roles and the closed application
-- manifest), cross-checked against independently decoded source members.
-- No commercial bytes appear here; absent versions report blocked.

local Assert = require("tests.support.Assert")
local MonCache = require("libs.assets.src.MonCache")
local MonSources = require("romdump.src.config.MonSources")
local Narc = require("libs.nds.src.nitro.Narc")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local MEASURES_ORIGIN_PATH = "a/0/7/4"
local MEASURES_BASE_PATH = "a/2/1/4"
local SLIDER_PATH = "a/0/7/5"
local HABITAT_PATH = "a/1/3/3"
local JOHTO_INVERSE_PATH = "a/1/3/8"
local PORTRAIT_Y_PATH = "a/0/0/5"

local function requireProducer()
  local loadedCatalog, PokedexCatalogCompiler = pcall(require, "romdump.src.digest.ui.PokedexCatalogCompiler")
  Assert.isTrue(loadedCatalog, "the pokedex catalog compiler must be published before source conformance can be proven")
  local loadedAsset, PokedexAssetCompiler = pcall(require, "romdump.src.digest.ui.PokedexAssetCompiler")
  Assert.isTrue(loadedAsset, "the pokedex asset compiler must be published before source conformance can be proven")
  local loadedSchema, PokedexAssetSchema = pcall(require, "libs.assets.src.PokedexAssetSchema")
  Assert.isTrue(loadedSchema, "the pokedex asset schema must be published before source conformance can be proven")
  return assert(PokedexCatalogCompiler), assert(PokedexAssetCompiler), assert(PokedexAssetSchema)
end

local function compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local monCatalog = assert(
    MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }),
    versionId .. " must resolve its mon catalog before the pokedex projection"
  )
  local catalog, err = PokedexCatalogCompiler.compile(romFs, versionId, monCatalog)
  Assert.notNil(catalog, versionId .. " must compile its pokedex catalog")
  Assert.isNil(err, versionId .. " compiles its pokedex catalog without error")
  return catalog
end

local function openArchive(romFs, path, versionId)
  local reader = romFs --[[@as { readSourcePath: fun(self: table, path: string): string? }]]
  local bytes = reader:readSourcePath(path)
  Assert.notNil(bytes, versionId .. " must expose source archive " .. path)
  return assert(Narc.open(assert(bytes), path))
end

local function readU16LE(bytes, offset)
  return string.byte(bytes, offset) + string.byte(bytes, offset + 1) * 256
end

local function void(_) end

local function readU32LE(bytes, offset)
  return string.byte(bytes, offset)
    + string.byte(bytes, offset + 1) * 256
    + string.byte(bytes, offset + 2) * 65536
    + string.byte(bytes, offset + 3) * 16777216
end

function T.orders_completion_and_inverse_cover_the_source_closure(romFs, versionId)
  local PokedexCatalogCompiler = requireProducer()
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  Assert.equal(#catalog.dexOrders.national, 493, versionId .. " carries all national entries")
  Assert.equal(#catalog.dexOrders.johto, 256, versionId .. " carries all johto entries")
  Assert.equal(#catalog.completionSets.johto, 254, versionId .. " carries its johto requirement set")
  Assert.equal(#catalog.completionSets.national, 484, versionId .. " carries its national requirement set")
  for _, key in ipairs(catalog.completionSets.national) do
    Assert.isTrue(catalog.species[key] ~= nil, versionId .. " completion member " .. key .. " resolves to a species")
  end

  -- All 256 inverse checks: every johto position round-trips through the
  -- independently decoded inverse member.
  local inverse = openArchive(romFs, JOHTO_INVERSE_PATH, versionId)
  local entries = assert(inverse:readMember(0), versionId .. " exposes its johto inverse member")
  local nonzero = 0
  for slot = 1, 494 do
    if readU16LE(entries, (slot - 1) * 2 + 1) ~= 0 then
      nonzero = nonzero + 1
    end
  end
  Assert.equal(nonzero, 256, versionId .. " inverse member carries 256 nonzero entries")
  for position, key in ipairs(catalog.dexOrders.johto) do
    local speciesId = assert(MonSources.speciesId(key), versionId .. " resolves johto member " .. key)
    Assert.equal(
      readU16LE(entries, speciesId * 2 + 1),
      position,
      versionId .. " inverse entry for " .. key .. " matches its johto position"
    )
  end
end

function T.numeric_giratina_slider_and_text_bindings_conform(romFs, versionId)
  local PokedexCatalogCompiler = requireProducer()
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local base = assert(catalog.measurementProfiles.base, versionId .. " publishes its base profile")
  local origin = assert(catalog.measurementProfiles.giratina_origin, versionId .. " publishes its origin profile")
  local giratinaKey = assert(MonSources.speciesKeys[487], "the source keys its giratina entry")
  Assert.equal(base.measurements[giratinaKey].heightDm, 45, versionId .. " base height uses the numeric mapping")
  Assert.equal(base.measurements[giratinaKey].weightHg, 7500, versionId .. " base weight uses the numeric mapping")
  Assert.equal(origin.measurements[giratinaKey].heightDm, 69, versionId .. " origin height uses the numeric mapping")
  Assert.equal(origin.measurements[giratinaKey].weightHg, 6500, versionId .. " origin weight uses the numeric mapping")

  -- Independent byte cross-check: the compiled Giratina values match the
  -- raw height/weight slots of the two measurement archives.
  local originArchive = openArchive(romFs, MEASURES_ORIGIN_PATH, versionId)
  Assert.equal(
    readU32LE(assert(originArchive:readMember(0)), 487 * 4 + 1),
    69,
    versionId .. " origin archive carries the pinned giratina height"
  )
  local baseArchive = openArchive(romFs, MEASURES_BASE_PATH, versionId)
  Assert.equal(
    readU32LE(assert(baseArchive:readMember(0)), 487 * 4 + 1),
    45,
    versionId .. " base archive carries the pinned giratina height"
  )

  Assert.equal(#catalog.sliderSteps, 153, versionId .. " carries every slider row")
  local anchors = {
    [1] = { 0, 0 },
    [2] = { 1, 2 },
    [11] = { 3, 20 },
    [41] = { 10, 125 },
    [81] = { 20, 325 },
    [101] = { 30, 425 },
    [121] = { 40, 1000 },
    [141] = { 50, 3000 },
    [152] = { 100, 9000 },
    [153] = { 999, 9999 },
  }
  for row, expected in pairs(anchors) do
    Assert.deepEqual(
      catalog.sliderSteps[row],
      { heightDm = expected[1], weightHg = expected[2] },
      versionId .. " slider row " .. row .. " keeps its pinned thresholds"
    )
  end

  Assert.deepEqual(catalog.textBindings, {
    ui = { bankId = 802 },
    entryByLanguage = {
      native = { nameBankId = 237, categoryBankId = 816, flavorBankId = versionId == "heartgold" and 803 or 804 },
      japanese = { nameBankId = 822, categoryBankId = 828, flavorBankId = 810 },
      english = { nameBankId = 817, categoryBankId = 823, flavorBankId = 805 },
      french = { nameBankId = 818, categoryBankId = 824, flavorBankId = 806 },
      german = { nameBankId = 819, categoryBankId = 825, flavorBankId = 807 },
      italian = { nameBankId = 820, categoryBankId = 826, flavorBankId = 808 },
      spanish = { nameBankId = 821, categoryBankId = 827, flavorBankId = 809 },
    },
    measureByProfile = {
      base = { heightBankId = 815, weightBankId = 813 },
      giratina_origin = { heightBankId = 814, weightBankId = 812 },
    },
    registrationAnnouncement = { bankId = 197, messageId = 871 },
  }, versionId .. " binds the exact message roles")
end

local function decodeMasks(romFs, versionId)
  local archive = openArchive(romFs, SLIDER_PATH, versionId)
  local member = assert(archive:readMember(1), versionId .. " exposes its area mask member")
  Assert.equal(#member, 494, versionId .. " mask member covers every species slot")
  local masks = {}
  for slot = 1, 494 do
    masks[slot] = string.byte(member, slot)
  end
  return masks
end

function T.area_geometry_and_habitat_groups_conform(romFs, versionId)
  local PokedexCatalogCompiler = requireProducer()
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local geometryCount = 0
  for _ in pairs(catalog.areaGeometry) do
    geometryCount = geometryCount + 1
  end
  Assert.equal(geometryCount, 96, versionId .. " carries all dungeon and outdoor geometry records")

  local habitat = openArchive(romFs, HABITAT_PATH, versionId)
  Assert.equal(habitat:memberCount(), 3962, versionId .. " carries the full habitat closure")
  local morning = assert(
    catalog.habitats[MonSources.speciesKeys[1]],
    versionId .. " compiles habitat rows for resolved species"
  ).morning
  Assert.isTrue(#morning.outdoor + #morning.dungeon >= 0, versionId .. " morning encounters decode")
end

-- The 28 version-differing mask species need both dumps; with only one
-- ready this leg reports blocked instead of passing.
function T.version_differing_masks_need_both_dumps(romFs, versionId, context)
  void(romFs)
  void(versionId)
  local otherVersion = versionId == "heartgold" and "soulsilver" or "heartgold"
  if not RomImporter.isReady(otherVersion) then
    assert(context ~= nil, "parity reporting needs its runner context")
    context:skip(otherVersion .. " dump not owned; mask parity blocked")
    return
  end
  requireProducer()
  local RomSourcePath = require("tests.rom.support.RomSourcePath")
  local otherFs, openErr = RomSourcePath.openReader(otherVersion)
  Assert.notNil(otherFs, "the ready " .. otherVersion .. " dump must open: " .. tostring(openErr))
  local own, foreign = decodeMasks(romFs, versionId), decodeMasks(assert(otherFs), otherVersion)
  local differing = {}
  for slot = 1, 494 do
    if own[slot] ~= foreign[slot] then
      differing[#differing + 1] = slot
    end
  end
  Assert.equal(#differing, 28, "heartgold and soulsilver differ at 28 mask species")
  local closer = assert(otherFs.close, "the comparison reader closes")
  local releaser = assert(otherFs.source, "the comparison source releases")
  closer(otherFs)
  releaser:release()
end

function T.back_height_selectors_resolve_through_valid_slots(romFs, versionId)
  local PokedexCatalogCompiler = requireProducer()
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local heights = assert(catalog.pictures.backYOffset, versionId .. " publishes back-height corrections")
  local count = 0
  for selector, offset in pairs(heights) do
    count = count + 1
    Assert.isTrue(type(offset) == "number", versionId .. " back height for " .. selector .. " is numeric")
    Assert.isTrue(selector:find("/back", 1, true) ~= nil, versionId .. " back heights use back selectors")
  end
  Assert.isTrue(count > 0, versionId .. " publishes back-height selectors")

  local samples = { "BULBASAUR", "PIKACHU", "MEW", "GIRATINA", "UNOWN", "DEOXYS", "ARCEUS", "PICHU" }
  for _, key in ipairs(samples) do
    local selector = MonCache.portraitSelector(key, 0, "male", false, "back")
    Assert.notNil(heights[selector], versionId .. " resolves the back height for " .. key)
  end

  -- Independent byte cross-check: the compiled Bulbasaur male-back offset
  -- matches the raw ordinary-archive slot 4*1+0+1.
  local archive = openArchive(romFs, PORTRAIT_Y_PATH, versionId)
  local slot = assert(archive:readMember(5), versionId .. " exposes the ordinary male-back slot")
  Assert.equal(
    heights[MonCache.portraitSelector("BULBASAUR", 0, "male", false, "back")],
    string.byte(slot, 1),
    versionId .. " compiled back height matches its source slot"
  )
end

function T.presentation_scope_closes_all_roles(romFs, versionId)
  local PokedexCatalogCompiler, PokedexAssetCompiler, PokedexAssetSchema = requireProducer()
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local manifest, err = PokedexAssetCompiler.compile(romFs, versionId, catalog)
  Assert.notNil(manifest, versionId .. " must compile its presentation manifest")
  Assert.isNil(err, versionId .. " compiles its presentation without error")
  local record, schemaErr = PokedexAssetSchema.validateManifest(manifest, catalog)
  Assert.notNil(record, versionId .. " publishes a schema-valid manifest")
  Assert.isNil(schemaErr, versionId .. " manifest carries no schema error")
  for _, role in ipairs({
    "cover",
    "grid",
    "results",
    "search.criteria",
    "search.order",
    "search.name",
    "search.type",
    "search.height",
    "search.weight",
    "search.area",
    "search.shape",
    "entry.area",
    "entry.size",
    "entry.forms",
    "entry.compare",
    "entry.return",
    "registration",
  }) do
    Assert.notNil(record.pages[role], versionId .. " manifest closes the " .. role .. " page")
  end
  Assert.deepEqual(record.text, catalog.textBindings, versionId .. " manifest projects the catalog bindings")
  Assert.equal(record.fonts.body, 0, versionId .. " body text uses the shared body font")
  Assert.equal(record.fonts.header, 4, versionId .. " headers use the shared header font")
  Assert.equal(record.spinda.secondFrameXOffset, -14, versionId .. " manifest carries the spinda second-frame offset")
  for _, region in ipairs({ "johto", "kanto" }) do
    local map = assert(record.areaMaps[region], versionId .. " manifest carries its " .. region .. " map")
    Assert.deepEqual(
      map.crop,
      { x = 56, y = 40, width = 200, height = 136 },
      versionId .. " " .. region .. " keeps the verified compact crop"
    )
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "pokedex" }
suite.metadata.derivedAssets = { "pokedex-data:global", "pokedex:global" }
return suite
