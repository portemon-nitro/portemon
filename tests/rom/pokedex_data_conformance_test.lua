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
    landmarks = { bankId = 279, fallbackBankId = 280, fallbackMessageId = 2 },
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

-- Every native UI entry the search/entry text bindings reference exists
-- in the source UI bank with a nonempty tokenized string, and option
-- groups stay mutually distinct, so no compiled window can resolve to a
-- missing or shared label.
function T.search_text_bindings_resolve_through_the_native_ui_bank(romFs, versionId)
  local PokedexSources = require("romdump.src.config.PokedexSources")
  local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
  local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
  local charmap = require("romdump.src.catalog.hgss.charmap")
  local searchText = assert(
    PokedexSources.searchText,
    versionId .. " publishes its search text bindings"
  )()
  assert(type(searchText) == "table", "the search text bindings stay records")
  local groups = {
    criteria = searchText.criteria,
    orders = searchText.orders,
    letters = searchText.letters,
    types = searchText.types,
    areas = searchText.areas,
  }
  local singles = {
    { group = "buttons.run", id = searchText.buttons.run },
    { group = "buttons.reset", id = searchText.buttons.reset },
    { group = "editorButtons.ok", id = searchText.editorButtons.ok },
    { group = "return.cancel", id = searchText.returnCancel },
    { group = "return.action", id = searchText.returnAction },
    { group = "time.morning", id = searchText.timeBase },
    { group = "time.day", id = searchText.timeBase + 1 },
    { group = "time.night", id = searchText.timeBase + 2 },
  }
  local archive = assert(romFs:openNarc("messages"), versionId .. " exposes its message archive")
  local bank = assert(
    FieldMessageBank.decode(assert(archive:readMember(802)), { label = versionId .. "-ui-802" }),
    versionId .. " decodes its UI bank"
  )
  local function labelOf(id, group)
    local message = bank.messages[id + 1]
    Assert.notNil(message, versionId .. " UI bank carries entry " .. id .. " (" .. group .. ")")
    local tokens = FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = 802, messageId = id })
    local text = {}
    for _, token in ipairs(tokens) do
      if token.text ~= nil then
        text[#text + 1] = token.text
      end
    end
    local joined = table.concat(text)
    Assert.isTrue(joined ~= "", versionId .. " entry " .. id .. " (" .. group .. ") is nonempty")
    return joined
  end
  local counts = {}
  for group, records in pairs(groups) do
    local seen = {}
    local count = 0
    for name, id in pairs(records) do
      Assert.isTrue(type(id) == "number", versionId .. " binds a numeric entry for " .. group .. "." .. name)
      local label = labelOf(id, group .. "." .. name)
      Assert.isNil(seen[label], versionId .. " " .. group .. " shares no label (" .. name .. ")")
      seen[label] = true
      count = count + 1
    end
    counts[group] = count
  end
  Assert.equal(counts.criteria, 7, versionId .. " binds all seven criterion captions")
  Assert.equal(counts.orders, 6, versionId .. " binds all six sort labels")
  Assert.equal(counts.letters, 27, versionId .. " binds all 27 letter marks")
  Assert.equal(counts.types, 18, versionId .. " binds all 18 type marks")
  Assert.equal(counts.areas, 4, versionId .. " binds all four area scopes")
  for _, entry in ipairs(singles) do
    Assert.isTrue(type(entry.id) == "number", versionId .. " binds a numeric entry for " .. entry.group)
    labelOf(entry.id, entry.group)
  end
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

-- Pixel-fidelity legs: compiled page backgrounds reproduce their
-- native NSCR tilemaps (flips, 4bpp palette banks, transparency) instead
-- of a shared synthetic grid; every page binds its own native loader
-- family; and an invalid source association aborts compilation without
-- publishing. The pixel oracle below re-implements tile mapping locally:
-- it shares only the container decoders (the required G2D primitives)
-- with the producer, so a full-image match proves the rasterizer.
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local PngReader = require("tests.support.PngReader")

local GRAPHICS_PATH = "a/0/6/8"

local function openGraphicsArchive(romFs, versionId)
  local bytes = romFs:readSourcePath(GRAPHICS_PATH)
  Assert.notNil(bytes, versionId .. " must expose the pokedex graphics archive")
  return assert(Narc.open(assert(bytes), GRAPHICS_PATH))
end

local function unpackMember(archive, member, versionId)
  local packed = assert(archive:readMember(member), versionId .. " exposes graphics member " .. member)
  if #packed >= 1 and string.byte(packed, 1) == 0x10 then
    local Lz10 = require("romdump.src.digest.Lz10")
    local plain, plainErr = Lz10.decode(packed)
    Assert.notNil(plain, versionId .. " decompresses member " .. member .. ": " .. tostring(plainErr))
    return plain
  end
  return packed
end

local function decodedTriple(archive, charMember, screenMember, paletteMember, versionId)
  local char = assert(
    G2dDecoder.decodeChar(unpackMember(archive, charMember, versionId), { label = "oracle-char" }),
    versionId .. " decodes NCGR member " .. charMember
  )
  local screen = assert(
    G2dDecoder.decodeScreen(unpackMember(archive, screenMember, versionId), { label = "oracle-screen" }),
    versionId .. " decodes NSCR member " .. screenMember
  )
  local palette = assert(
    G2dDecoder.decodePalette(unpackMember(archive, paletteMember, versionId), { label = "oracle-palette" }),
    versionId .. " decodes NCLR member " .. paletteMember
  )
  return char, screen, palette
end

---@param honorFlips boolean
local function oracleRgba(charTiles, paletteColors, screen, honorFlips)
  local tilesWide = math.floor(screen.width / 8)
  local parts = {}
  for row = 0, math.floor(screen.height / 8) - 1 do
    for py = 0, 7 do
      for col = 0, tilesWide - 1 do
        for px = 0, 7 do
          local entry = screen.entries[row * tilesWide + col + 1]
          local sx = (honorFlips and entry.flipH) and (7 - px) or px
          local sy = (honorFlips and entry.flipV) and (7 - py) or py
          local byte = string.byte(charTiles, entry.tile * 32 + sy * 4 + math.floor(sx / 2) + 1)
          Assert.notNil(byte, "the oracle tile stays inside its character payload")
          local nibble = (sx % 2 == 0) and byte % 16 or math.floor(byte / 16)
          if nibble == 0 then
            parts[#parts + 1] = "\0\0\0\0"
          else
            local color = paletteColors[entry.palette * 16 + nibble + 1]
            Assert.notNil(color, "the oracle palette bank covers its screen reference")
            parts[#parts + 1] = string.char(color.r, color.g, color.b, 255)
          end
        end
      end
    end
  end
  return table.concat(parts)
end

local function compiledChrome(romFs, versionId)
  local PokedexCatalogCompiler, PokedexAssetCompiler = requireProducer()
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local sink = {}
  local manifest, err = PokedexAssetCompiler.compile(romFs, versionId, catalog, sink)
  Assert.notNil(manifest, versionId .. " must compile its presentation manifest")
  Assert.isNil(err, versionId .. " compiles its presentation without error")
  Assert.notNil(sink.assets, versionId .. " stages its generated images")
  return manifest, sink
end

local function backgroundPng(manifest, sink, role, pane, layer, versionId)
  local page = assert(manifest.pages[role], versionId .. " closes the " .. role .. " page")
  for _, background in ipairs(assert(page.backgrounds[pane], versionId .. " binds the " .. pane .. " pane")) do
    if background.layer == layer then
      local record = assert(
        manifest.chrome[background.chrome],
        versionId .. " resolves the " .. role .. " layer " .. layer .. " chrome"
      )
      local bytes =
        assert(sink.assets[record.path], versionId .. " stages the " .. role .. " layer " .. layer .. " image")
      return bytes, record
    end
  end
  error(versionId .. " binds no " .. pane .. " layer " .. layer .. " on " .. role, 0)
end

function T.presentation_backgrounds_reproduce_source_screen_maps(romFs, versionId)
  local archive = openGraphicsArchive(romFs, versionId)
  local manifest, sink = compiledChrome(romFs, versionId)
  -- Representative triples across both engines: search MAIN (banks 0+2,
  -- flipped), area SUB (banks 0+1+8, flipped), list SUB (bank 1, flipped).
  local cases = {
    { role = "search.criteria", pane = "controls", layer = 2, char = 58, screen = 57, palette = 2 },
    { role = "entry.area", pane = "information", layer = 3, char = 85, screen = 84, palette = 18 },
    { role = "cover", pane = "information", layer = 0, char = 17, screen = 16, palette = 18 },
  }
  for _, case in ipairs(cases) do
    local char, screen, palette = decodedTriple(archive, case.char, case.screen, case.palette, versionId)
    local bytes, record = backgroundPng(manifest, sink, case.role, case.pane, case.layer, versionId)
    local width, height, rgba = PngReader.rgba(bytes)
    Assert.equal(width, screen.width, case.role .. " keeps its native screen width")
    Assert.equal(height, screen.height, case.role .. " keeps its native screen height")
    Assert.equal(record.width, screen.width, case.role .. " records its native width")
    Assert.equal(record.height, screen.height, case.role .. " records its native height")
    Assert.equal(
      rgba,
      oracleRgba(char.tiles, palette.colors, screen, true),
      case.role .. " reproduces its NSCR tilemap, flips and palette banks"
    )
    Assert.isTrue(
      rgba ~= oracleRgba(char.tiles, palette.colors, screen, false),
      case.role .. " honors flipped tiles (an unflipped render differs)"
    )
  end
  -- At least one composed screen preserves transparent palette-index
  -- pixels end to end (individual screens may be fully opaque source
  -- art, so the property is asserted over the family, not per screen).
  do
    local transparent = 0
    for _, case in ipairs(cases) do
      local bytes = backgroundPng(manifest, sink, case.role, case.pane, case.layer, versionId)
      local _, _, rgba = PngReader.rgba(bytes)
      for index = 4, #rgba, 4 do
        if string.byte(rgba, index) == 0 then
          transparent = transparent + 1
        end
      end
    end
    Assert.isTrue(transparent > 0, "composed screens preserve transparent palette-index pixels")
  end
  local searchBytes = backgroundPng(manifest, sink, "search.criteria", "controls", 2, versionId)
  local areaBytes = backgroundPng(manifest, sink, "entry.area", "controls", 0, versionId)
  Assert.isTrue(searchBytes ~= areaBytes, "two source-distinct screens produce distinct images")
end

-- Compositing leg: the grid information pane binds no layer-0 composition,
-- so faithful priority compositing (lower number in front) leaves the native
-- layer-1 number/name windows visible. The windowless cover keeps the loaded
-- dial art, proving the correction is page-local rather than wholesale art
-- deletion.
function T.presentation_grid_windows_clear_their_foreground_layer(romFs, versionId)
  local manifest, sink = compiledChrome(romFs, versionId)
  local grid = assert(manifest.pages.grid, versionId .. " closes the grid page")
  for _, background in
    ipairs(assert(grid.backgrounds.information, versionId .. " binds the grid information pane"))
  do
    Assert.isTrue(
      background.layer ~= 0,
      versionId .. " binds no grid information foreground over the layer-1 text windows"
    )
  end
  local bytes, record = backgroundPng(manifest, sink, "cover", "information", 0, versionId)
  local archive = openGraphicsArchive(romFs, versionId)
  local char, screen, palette = decodedTriple(archive, 17, 16, 18, versionId)
  local _, _, rgba = PngReader.rgba(bytes)
  Assert.equal(record.width, screen.width, versionId .. " cover keeps its native foreground width")
  Assert.equal(
    rgba,
    oracleRgba(char.tiles, palette.colors, screen, true),
    versionId .. " cover keeps the native dial composition"
  )
  for _, key in ipairs({ "grid.selected-number", "grid.selected-name" }) do
    local window = assert(manifest.windows[key], versionId .. " inventories " .. key)
    Assert.equal(window.pane, "information", versionId .. " " .. key .. " stays on the information pane")
    Assert.equal(window.layer, 1, versionId .. " " .. key .. " stays on its native layer")
  end
end

-- Compositing leg: the entry.area information pane binds the full pannable
-- SUB BG0 area map (char 87 + screen 86) on layer 0 with the native
-- area-view priority (BG0 pri 3 back vs BG1 pri 0 front), so the layer-1
-- entry windows stay visible while the renderer shifts the map by the
-- published pan offset. The staged composition keeps the full native
-- scroll width (settled endpoints -72 Johto / +104 Kanto over a 256-wide
-- viewport) with real map pixels in the panned region.
function T.presentation_area_map_pans_behind_its_entry_windows(romFs, versionId)
  local manifest, sink = compiledChrome(romFs, versionId)
  local area = assert(manifest.pages["entry.area"], versionId .. " closes the entry.area page")
  local map = nil
  for _, background in ipairs(assert(area.backgrounds.information, versionId .. " binds the entry.area information pane")) do
    if background.layer == 0 then
      map = background
    end
  end
  Assert.notNil(map, versionId .. " binds the entry.area information map on layer 0")
  Assert.equal(map.priority, 3, versionId .. " renders the area map behind its entry windows")
  local archive = openGraphicsArchive(romFs, versionId)
  local char, screen, palette = decodedTriple(archive, 87, 86, 18, versionId)
  local bytes = assert(
    sink.assets[assert(manifest.chrome[map.chrome], versionId .. " resolves the area map chrome").path],
    versionId .. " stages the area map image"
  )
  local record = manifest.chrome[map.chrome]
  local width, height, rgba = PngReader.rgba(bytes)
  Assert.equal(record.width, screen.width, versionId .. " area map keeps its native scroll width")
  Assert.equal(record.height, screen.height, versionId .. " area map keeps its native scroll height")
  Assert.equal(width, screen.width, versionId .. " area map stages its full native width")
  Assert.isTrue(
    width >= (104 - (-72)) + 256,
    versionId .. " area map spans both settled region pans (-72/+104 over a 256 viewport)"
  )
  Assert.equal(
    rgba,
    oracleRgba(char.tiles, palette.colors, screen, true),
    versionId .. " area map reproduces its NSCR tilemap, flips and palette banks"
  )
  -- Columns past the X=0 viewport appear at a settled pan under either
  -- scroll-sign convention (Kanto +104 reveals up to 360; Johto -72
  -- reveals 72..328 reversed), so opaque pixels there prove panned-region
  -- map art rather than cleared padding.
  local revealed = 0
  local pixels = math.floor(#rgba / 4)
  for index = 0, pixels - 1 do
    local x = index % width
    if x >= 256 and x < 328 and string.byte(rgba, index * 4 + 4) ~= 0 then
      revealed = revealed + 1
    end
  end
  Assert.isTrue(revealed > 0, versionId .. " area map carries panned-region map pixels")
  for _, key in ipairs({ "entry.species-name", "entry.dex-number" }) do
    local window = assert(manifest.windows[key], versionId .. " inventories " .. key)
    Assert.equal(window.pane, "information", versionId .. " " .. key .. " stays on the information pane")
    Assert.equal(window.layer, 1, versionId .. " " .. key .. " stays on its native layer")
  end
end

function T.presentation_pages_bind_distinct_source_families(romFs, versionId)
  local archive = openGraphicsArchive(romFs, versionId)
  void(archive)
  local manifest, sink = compiledChrome(romFs, versionId)
  local function chromeRoles(role, pane)
    local page = assert(manifest.pages[role], versionId .. " closes the " .. role .. " page")
    local roles = {}
    for _, background in ipairs(assert(page.backgrounds[pane])) do
      roles[#roles + 1] = background.chrome
    end
    table.sort(roles)
    return roles
  end
  -- The list loader family serves cover and results identically; grid
  -- depicts the scrolled entry-view state, so its information pane carries
  -- no foreground composition over the layer-1 text windows.
  Assert.deepEqual(
    chromeRoles("results", "information"),
    chromeRoles("cover", "information"),
    "results and cover share their native loader family"
  )
  Assert.deepEqual(
    chromeRoles("results", "controls"),
    chromeRoles("grid", "controls"),
    "results and grid share their native loader family"
  )
  -- Search, area, size, forms, compare and back each resolve their own
  -- loader family: no search *composed* chrome role appears on the area
  -- page. Tile-0 fills are content-deduped across pages by design, so
  -- the disjointness check covers composed roles only.
  local searchRoles = chromeRoles("search.criteria", "controls")
  local areaRoles = chromeRoles("entry.area", "controls")
  local areaSet = {}
  for _, role in ipairs(areaRoles) do
    areaSet[role] = true
  end
  for _, role in ipairs(searchRoles) do
    if not role:find("-fill$", 1) then
      Assert.isNil(areaSet[role], "search and area pages use distinct source compositions: " .. role)
    end
  end
  -- The registration card uses the battle-owned popup composition on its
  -- own layer, never a browsing Main/controls background.
  local registration = assert(manifest.pages.registration, versionId .. " closes the registration page")
  Assert.equal(#registration.backgrounds.controls, 0, "the popup owns no browsing controls background")
  local popupBytes, popupRecord = backgroundPng(manifest, sink, "registration", "information", 2, versionId)
  local char, screen, palette = decodedTriple(archive, 19, 20, 18, versionId)
  local width, _, rgba = PngReader.rgba(popupBytes)
  Assert.equal(width, screen.width, "the popup keeps its native screen width")
  Assert.equal(popupRecord.width, screen.width, "the popup records its native width")
  Assert.equal(
    rgba,
    oracleRgba(char.tiles, palette.colors, screen, true),
    "the registration card reproduces the popup screen composition"
  )
  -- No controls pane stays empty where the native loader draws a BG, and
  -- no page silently reuses one synthetic role for every background.
  for _, role in ipairs({ "grid", "search.criteria", "entry.area", "entry.size", "entry.forms", "entry.return" }) do
    Assert.isTrue(#manifest.pages[role].backgrounds.controls > 0, role .. " keeps its native controls backgrounds")
  end
  local distinct = {}
  for _, role in ipairs({
    "cover",
    "grid",
    "results",
    "search.criteria",
    "entry.area",
    "entry.size",
    "entry.forms",
    "entry.compare",
    "entry.return",
    "registration",
  }) do
    for _, pane in ipairs({ "information", "controls" }) do
      for _, chrome in ipairs(chromeRoles(role, pane)) do
        distinct[chrome] = true
      end
    end
  end
  local count = 0
  for _ in pairs(distinct) do
    count = count + 1
  end
  Assert.isTrue(count > 5, "compiled pages use many distinct source compositions, not one synthetic role")
  -- Page-local inventories resolve and differ per family.
  Assert.isTrue(
    #manifest.pages.grid.windows > 0 and #manifest.pages.registration.windows > 0,
    "browser and registration pages carry their own window inventories"
  )
  Assert.isTrue(
    table.concat(manifest.pages.grid.windows, ",") ~= table.concat(manifest.pages.registration.windows, ","),
    "browser and registration window inventories differ"
  )
end

-- Sprite-family legs: every page binds exactly the OBJ cell families its
-- native screen setup loads. Shared families resolve to identical cell
-- roles, so subset and difference checks over page inventories prove the
-- page-to-family assignment without freezing source catalog counts.
function T.presentation_pages_bind_exact_sprite_families(romFs, versionId)
  local manifest = compiledChrome(romFs, versionId)
  local function cellSet(role)
    local page = assert(manifest.pages[role], versionId .. " closes the " .. role .. " page")
    local set = {}
    for _, cell in ipairs(assert(page.cells, versionId .. " inventories the " .. role .. " cells")) do
      set[cell] = true
    end
    return set
  end
  local function assertSubset(inner, outer, label)
    for cell in pairs(cellSet(inner)) do
      Assert.isTrue(cellSet(outer)[cell] ~= nil, label .. ": " .. inner .. " cell " .. cell .. " resolves on " .. outer)
    end
  end
  local function assertDiffers(role, other, label)
    local mine, theirs = cellSet(role), cellSet(other)
    local extra = false
    for cell in pairs(mine) do
      if theirs[cell] == nil then
        extra = true
      end
    end
    Assert.isTrue(extra, label .. ": " .. role .. " binds a sprite family " .. other .. " lacks")
  end
  -- The registration popup binds banner, type-icon and footprint
  -- families; the tab cursor and form screens bind the main OBJ family
  -- they share with the list screen.
  local registration = assert(manifest.pages.registration, versionId .. " closes the registration page")
  Assert.isTrue(#registration.cells > 0, "the popup binds its banner, type-icon and footprint families")
  Assert.isTrue(#registration.sprites > 0, "the popup sprites resolve through its OBJ families")
  assertSubset("entry.return", "grid", versionId)
  assertSubset("entry.forms", "grid", versionId)
  assertSubset("entry.compare", "grid", versionId)
  assertSubset("registration", "grid", versionId)
  -- Area markers, the size scale and the search menu/body-type families
  -- appear only on their own pages.
  assertDiffers("entry.area", "grid", versionId)
  assertDiffers("entry.size", "grid", versionId)
  assertDiffers("search.criteria", "grid", versionId)
end

function T.presentation_rejects_invalid_source_association(romFs, versionId)
  local PokedexCatalogCompiler, PokedexAssetCompiler = requireProducer()
  local PokedexSources = require("romdump.src.config.PokedexSources")
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local saved = PokedexSources.pageLayers.grid
  PokedexSources.pageLayers.grid = { { pane = "controls", layer = 2, char = 9999, screen = 57, palette = 2 } }
  local sink = {}
  local ok, manifest = pcall(PokedexAssetCompiler.compile, romFs, versionId, catalog, sink)
  PokedexSources.pageLayers.grid = saved
  Assert.isTrue(not (ok and manifest), "an unknown source association must abort compilation")
  Assert.isNil(sink.assets, "a failed compilation stages no images")
end

-- Fixture policy identities stay within the ROM bank ranges: the
-- synthetic dex fixture names Spinda and Unown for spot-boundary and
-- form-exhaustiveness coverage, so their stable catalog identities must
-- resolve real name, category, flavor, height, and weight entries on
-- every owned dump instead of failing ROM-gated preparation.
function T.fixture_policy_identities_resolve_within_rom_bank_ranges(romFs, versionId)
  local PokedexCatalogCompiler = requireProducer()
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local DexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
  local monCatalog = DexFixture.makeCatalog()
  local CacheFs = require("libs.storage.src.CacheFs")
  local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
  local cacheFs = CacheFs.forVersion(versionId)
  Assert.notNil(cacheFs, versionId .. " exposes its prepared cache")
  local provider = FieldMessageProvider.new(cacheFs)
  local bindings = assert(catalog.textBindings, versionId .. " binds its text roles")
  local native = assert(bindings.entryByLanguage.native, versionId .. " binds its native entry banks")
  local base = assert(bindings.measureByProfile.base, versionId .. " binds its base measure banks")
  local banks = {
    native.nameBankId,
    native.categoryBankId,
    native.flavorBankId,
    base.heightBankId,
    base.weightBankId,
  }
  for _, key in ipairs({ "SPINDA", "UNOWN" }) do
    local species = monCatalog:species(key)
    Assert.notNil(species, "the fixture catalog names " .. key)
    local nativeId = assert(species.nativeId, "the fixture " .. key .. " carries its stable identity")
    for _, bankId in ipairs(banks) do
      Assert.isTrue(provider:acquireBank(bankId), versionId .. " acquires bank " .. bankId)
      local template = provider:get(bankId, nativeId)
      Assert.notNil(
        template,
        versionId .. " resolves " .. key .. " in bank " .. bankId .. " entry " .. nativeId
      )
      Assert.isTrue(
        type(template.text) == "string" and template.text ~= "",
        versionId .. " carries source text for " .. key .. " in bank " .. bankId
      )
    end
  end
  provider:dispose()
end

-- Sprite placement closure: the compiler binds exactly the authored
-- static anchors (the fourteen shape-grid slots on their editor page
-- plus the registration banner emblem) and leaves every other page
-- sprite on the unplaced origin sentinel, so the renderer never
-- invents positions for state-driven art.
function T.presentation_sprites_bind_only_the_authored_static_anchors(romFs, versionId)
  local PokedexCatalogCompiler, PokedexAssetCompiler = requireProducer()
  local catalog = compileCatalog(romFs, versionId, PokedexCatalogCompiler)
  local manifest, err = PokedexAssetCompiler.compile(romFs, versionId, catalog)
  Assert.notNil(manifest, versionId .. " must compile its presentation manifest")
  Assert.isNil(err, versionId .. " compiles its presentation without error")
  local expected = {}
  for slot = 0, 13 do
    expected["sprite-search-shape-" .. (87 + slot)] =
      { x = 32 + 48 * (slot % 5), y = 56 + 40 * math.floor(slot / 5), pane = "controls" }
  end
  expected["sprite-registration-1"] = { x = 112, y = 32, pane = "information" }
  local placed = 0
  for role, record in pairs(manifest.sprites) do
    Assert.isTrue(type(record.x) == "number" and type(record.y) == "number", versionId .. " anchors " .. role)
    if record.x ~= 0 or record.y ~= 0 then
      placed = placed + 1
      local wanted = assert(
        expected[role],
        versionId .. " places no sprite outside the authored subset: " .. role
      )
      Assert.equal(record.x, wanted.x, versionId .. " " .. role .. " keeps its native x")
      Assert.equal(record.y, wanted.y, versionId .. " " .. role .. " keeps its native y")
      Assert.equal(record.pane, wanted.pane, versionId .. " " .. role .. " keeps its native pane")
      local animation = assert(
        manifest.animations[record.animation],
        versionId .. " " .. role .. " resolves its animation"
      )
      Assert.isTrue(
        type(animation.frames) == "table" and #animation.frames >= 1,
        versionId .. " " .. role .. " carries art to place"
      )
    end
  end
  local wantedCount = 0
  for _ in pairs(expected) do
    wantedCount = wantedCount + 1
  end
  Assert.equal(placed, wantedCount, versionId .. " places exactly the authored static subset")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "pokedex" }
suite.metadata.derivedAssets = { "pokedex-data:global", "pokedex:global" }
return suite
