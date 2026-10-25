-- Deterministic field-entry compilation and cache publication using synthetic
-- source archives: the nine areawindow banner skins compose source tiles
-- 1..68 as a 17x4 grid with source-palette transparency and decoded text
-- roles, the 228-member preview archive deduplicates to the 76 selected
-- triples with their decoded palette/flip geometry, the generated manifest
-- carries only semantic keys, and the publication matrix (stage write
-- failure, stage validation failure, first/second publish rename failure)
-- reuses ArtifactPublisher through a FakeCache so the previous ready class
-- stays readable and the marker never claims an incomplete class.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldEntryAssetCompiler = require("romdump.src.digest.ui.FieldEntryAssetCompiler")
local FieldEntryCacheWriter = require("romdump.src.digest.ui.FieldEntryCacheWriter")
local FieldEntryAssetCache = require("libs.assets.src.field.FieldEntryAssetCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local PngReader = require("tests.support.PngReader")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local FieldEntryFixture = require("tests.support.FieldEntryFixture")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")

local T = {}

local AREA_WINDOWS_ALIAS = "field_area_windows"
local PREVIEWS_ALIAS = "field_map_previews"

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function swap4(s)
  return s:reverse()
end

local function lz10Wrap(data)
  local head = string.char(0x10, #data % 65536 % 256, math.floor(#data / 256) % 256, math.floor(#data / 65536) % 256)
  local flags = string.char(0)
  local chunks = {}
  for i = 1, #data, 8 do
    chunks[#chunks + 1] = flags .. data:sub(i, math.min(i + 7, #data))
  end
  return head .. table.concat(chunks)
end

local function container(magic, blocks)
  local body = {}
  local size = 0x10
  for _, blk in ipairs(blocks) do
    body[#body + 1] = blk
    size = size + #blk
  end
  return magic .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(size) .. u16(0x10) .. u16(#blocks) .. table.concat(body)
end

local function block(magic, payload)
  return swap4(magic) .. u32(8 + #payload) .. payload
end

local function paletteData(colors)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = u16(c)
  end
  local bodyBytes = table.concat(body)
  local ttlp = "TTLP" .. u32(24 + #bodyBytes) .. u32(3) .. u32(0) .. u32(#colors * 2) .. u32(16) .. bodyBytes
  return "RLCN" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x10 + #ttlp) .. u16(0x10) .. u16(1) .. ttlp
end

local function charDataWithTiles(tileBytes)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#tileBytes * 32) .. u32(0x18)
  return container("RGCN", { block("CHAR", payload .. table.concat(tileBytes)) })
end

local function screenDataWH(width, height, entries)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return container(
    "RCSN",
    { block("SCRN", u16(width) .. u16(height) .. u32(0) .. u32(#entries * 2) .. table.concat(body)) }
  )
end

local function narc(members)
  local btaf = u16(#members) .. u16(0)
  local offset = 0
  local sizes = {}
  for _, bytes in ipairs(members) do
    sizes[#sizes + 1] = #bytes
    offset = offset + #bytes
  end
  local running = 0
  for _, size in ipairs(sizes) do
    btaf = btaf .. u32(running) .. u32(running + size)
    running = running + size
  end
  local function narcBlock(magic, payload)
    return magic .. u32(8 + #payload) .. payload
  end
  local btafBlock = narcBlock("BTAF", btaf)
  local gmifBlock = narcBlock("GMIF", table.concat(members))
  return "NARC"
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(0x10 + #btafBlock + #gmifBlock)
    .. u16(0x10)
    .. u16(2)
    .. btafBlock
    .. gmifBlock
end

-- The nine banner skins compose source tiles 1..68 as a 17x4 grid. Tile 0
-- carries a bright marker value that must never appear in the output (the
-- grid starts at tile 1); tile 1 is an all-zero source tile that must render
-- transparent under the default transparent-source-zero role.
local function bannerCharData(style)
  local tiles = {}
  tiles[1] = string.rep(string.char(0xFF), 32)
  tiles[2] = string.rep("\0", 32)
  for tile = 2, 68 do
    tiles[tile + 1] = string.rep(string.char((((tile + style) % 14) + 1) * 0x11), 32)
  end
  return charDataWithTiles(tiles)
end

-- A 16-color banner palette whose slot s decodes to s + style*16: no two
-- (style, slot) pairs share a color, so a wrong skin palette is visibly wrong
-- and the text roles (index 1 foreground, index 2 shadow, index 0 background)
-- are independently resolved.
local function bannerPalette(style)
  local colors = {}
  for slot = 0, 15 do
    colors[slot + 1] = slot + style * 16
  end
  return paletteData(colors)
end

-- Two 16-color preview palette banks; slot s decodes to base*16 + s.
local function previewPalette(base)
  local colors = {}
  for slot = 0, 31 do
    colors[slot + 1] = base * 16 + slot
  end
  return paletteData(colors)
end

local function previewChar(base)
  local tiles = {}
  for tile = 0, 199 do
    tiles[tile + 1] = string.rep(string.char((((tile + base) % 14) + 1) * 0x11), 32)
  end
  return charDataWithTiles(tiles)
end

-- A 32x24 preview screen exercising both palette banks and the NSCR flip bits.
local function previewScreen()
  local entries = {}
  for index = 1, 768 do
    local tile = (index - 1) % 200
    local palette = (index - 1) % 2
    local flipH = (index - 1) % 3 == 0
    local flipV = (index - 1) % 5 == 0
    entries[index] = tile + (flipH and 1024 or 0) + (flipV and 2048 or 0) + palette * 4096
  end
  return screenDataWH(256, 192, entries)
end

-- A synthetic RomFs whose two field-entry NARCs carry the audited source
-- geometry: NARC163's nine 2*i char / 2*i+1 palette banner pairs, and
-- NARC150's 76 base NCLR / base+1 NCGR.lz / base+2 NSCR.lz preview triples.
-- `opts.tamper` receives both member arrays (1-based; member id is index-1)
-- for malformed-source scenarios.
local function fixture(opts)
  opts = opts or {}
  local areaWindowMembers = {}
  for style = 0, FieldEntryFixture.BANNER_STYLE_COUNT - 1 do
    areaWindowMembers[style * 2 + 1] = lz10Wrap(bannerCharData(style))
    areaWindowMembers[style * 2 + 2] = bannerPalette(style)
  end
  local previewMembers = {}
  for _, base in ipairs(FieldEntryFixture.uniqueBases()) do
    previewMembers[base + 1] = previewPalette(base)
    previewMembers[base + 2] = lz10Wrap(previewChar(base))
    previewMembers[base + 3] = lz10Wrap(previewScreen())
  end
  if opts.tamper then
    opts.tamper(areaWindowMembers, previewMembers)
  end

  local function narcBytes(alias)
    if alias == AREA_WINDOWS_ALIAS then
      return narc(areaWindowMembers)
    end
    return narc(previewMembers)
  end

  local archives = {
    field_area_windows = {
      fileId = 150,
      narcId = 163,
      path = "a/1/6/3",
      symbol = "NARC_data_gs_areawindow",
      alias = AREA_WINDOWS_ALIAS,
    },
    field_map_previews = {
      fileId = 151,
      narcId = 150,
      path = "a/1/5/0",
      symbol = "NARC_a_1_5_0",
      alias = PREVIEWS_ALIAS,
    },
  }
  archives.NARC_data_gs_areawindow = archives.field_area_windows
  archives.NARC_a_1_5_0 = archives.field_map_previews

  local romFs = {
    resolvedNarc = function(_, alias)
      return archives[alias]
    end,
    read = function(_, fileId)
      if fileId == 150 then
        return narcBytes(AREA_WINDOWS_ALIAS)
      end
      if fileId == 151 then
        return narcBytes(PREVIEWS_ALIAS)
      end
      Assert.fail("unexpected read " .. tostring(fileId))
    end,
    openNarc = function(_, alias)
      local Narc = require("libs.nds.src.nitro.Narc")
      return assert(Narc.open(narcBytes(alias), alias))
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  return romFs, function()
    return "member-sha"
  end, function()
    return "dependency-sha"
  end
end

local function compile(romFs, sha1, hashLua)
  romFs = romFs or fixture()
  return FieldEntryAssetCompiler.compile(romFs, sha1, hashLua)
end

local function memberBytes(romFs, alias, memberId)
  local narcArchive = assert(romFs:openNarc(alias))
  local bytes = assert(narcArchive:readMember(memberId))
  if string.byte(bytes, 1) == 0x10 then
    local plain, err = Lz10.decode(bytes)
    assert(plain, err and err.message)
    return plain
  end
  return bytes
end

local function bannerEntries()
  local entries = {}
  for index, tile in ipairs(FieldEntryFixture.bannerEntries()) do
    entries[index] = { tile = tile, palette = 0, flipH = false, flipV = false }
  end
  return { width = 136, height = 32, entries = entries }
end

-- The expected banner pixels and decoded text-role palette for one skin,
-- computed independently from the source members.
local function expectedBanner(romFs, style)
  local char =
    assert(G2dDecoder.decodeChar(memberBytes(romFs, AREA_WINDOWS_ALIAS, style * 2), { label = "banner char" }))
  local pal = assert(
    G2dDecoder.decodePalette(memberBytes(romFs, AREA_WINDOWS_ALIAS, style * 2 + 1), { label = "banner palette" })
  )
  local image = G2dRasterizer.renderScreen(char, { colors = pal.colors }, bannerEntries(), {
    asset = "banner expectation",
  })
  return image.pixels, pal.colors
end

local function expectedPreview(romFs, base)
  local pal = assert(G2dDecoder.decodePalette(memberBytes(romFs, PREVIEWS_ALIAS, base), { label = "preview palette" }))
  local char = assert(G2dDecoder.decodeChar(memberBytes(romFs, PREVIEWS_ALIAS, base + 1), { label = "preview char" }))
  local screen =
    assert(G2dDecoder.decodeScreen(memberBytes(romFs, PREVIEWS_ALIAS, base + 2), { label = "preview screen" }))
  local image = G2dRasterizer.renderScreen(char, { colors = pal.colors }, screen, { asset = "preview expectation" }, {
    backdrop = true,
  })
  return image.pixels
end

local function pngPixels(bundle, key)
  local entry = assert(bundle.manifest.assets[key], "the manifest indexes asset " .. tostring(key))
  local bytes = assert(bundle.assets[entry.image], "the asset carries generated bytes: " .. tostring(entry.image))
  local width, height, rgba = PngReader.rgba(bytes)
  return width, height, rgba
end

local function codeMatches(err, suffix)
  return type(assert(err).code) == "string" and assert(err).code:match(suffix) ~= nil
end

function T.compiles_the_manifest_and_all_assets()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  Assert.equal(bundle.manifest.schema, FieldEntryAssetCache.SCHEMA)
  Assert.equal(bundle.manifest.reference.width, 256)
  Assert.equal(bundle.manifest.reference.height, 192)
  Assert.isTrue(FieldEntryAssetCache.validateManifest(bundle.manifest))
  Assert.equal(bundle.marker, FieldEntryAssetCache.marker("rom-sha", "dependency-sha"))
  for style = 0, FieldEntryFixture.BANNER_STYLE_COUNT - 1 do
    Assert.notNil(bundle.manifest.bannerStyles[style], "the manifest carries banner style " .. style)
    Assert.notNil(bundle.manifest.bannerTextPalettes[style], "the manifest carries text roles for style " .. style)
  end
  for _, entry in pairs(bundle.manifest.assets) do
    Assert.isTrue(entry.image:find("^assets/generated/field/entry/") ~= nil, "asset image stays under the entry root")
    Assert.isTrue(#assert(bundle.assets[entry.image]) > 0)
  end
end

function T.nine_banner_skins_compose_the_17x4_grid_with_source_transparency()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local seen = {}
  for style = 0, FieldEntryFixture.BANNER_STYLE_COUNT - 1 do
    local key = bundle.manifest.bannerStyles[style]
    local expected, colors = expectedBanner(romFs, style)
    local width, height, rgba = pngPixels(bundle, key)
    Assert.equal(width, 136, "banner style " .. style .. " width")
    Assert.equal(height, 32, "banner style " .. style .. " height")
    Assert.equal(rgba, expected, "banner style " .. style .. " pixels follow the source 17x4 grid")
    Assert.isNil(seen[rgba], "banner style " .. style .. " renders distinct artwork")
    seen[rgba] = true

    local roles = assert(bundle.manifest.bannerTextPalettes[style])
    local foreground = assert(colors[2], "the palette carries index 1")
    local shadow = assert(colors[3], "the palette carries index 2")
    local background = assert(colors[1], "the palette carries index 0")
    Assert.deepEqual(roles.foreground, { r = foreground.r, g = foreground.g, b = foreground.b })
    Assert.deepEqual(roles.shadow, { r = shadow.r, g = shadow.g, b = shadow.b })
    Assert.deepEqual(roles.background, { r = background.r, g = background.g, b = background.b })
  end

  -- Tile 1 is the all-zero source tile at grid cell 0: under the default
  -- transparent-source-zero role its pixels stay transparent.
  local _, _, bannerRgba = pngPixels(bundle, bundle.manifest.bannerStyles[0])
  local _, _, _, alpha = PngReader.pixel(bannerRgba, 136, 0, 0)
  Assert.equal(alpha, 0, "the source-zero grid tile stays transparent")
end

function T.pinned_preview_inventory_matches_the_source_triples()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))

  local distinctKeys = {}
  local distinctBytes = {}
  local destinationCount = 0
  for _, destination in ipairs(FieldEntryFixture.DESTINATIONS) do
    local mapId = assert(MapCatalog.idForSymbol(destination.symbol), destination.symbol)
    local slots =
      assert(bundle.manifest.previewByMapId[mapId], "destination " .. destination.symbol .. " carries slots")
    destinationCount = destinationCount + 1
    for slot = 0, 3 do
      local key = assert(slots[slot], destination.symbol .. " slot " .. slot)
      distinctKeys[key] = true
      local width, height, rgba = pngPixels(bundle, key)
      Assert.equal(width, 256, destination.symbol .. " slot " .. slot .. " width")
      Assert.equal(height, 192, destination.symbol .. " slot " .. slot .. " height")
      local base = assert(destination.bases[slot + 1])
      Assert.equal(rgba, expectedPreview(romFs, base), destination.symbol .. " slot " .. slot .. " pixels")
      distinctBytes[rgba] = true
    end
  end
  Assert.equal(destinationCount, 25, "the selector carries exactly the 25 destination map ids")

  local keyCount = 0
  for _ in pairs(distinctKeys) do
    keyCount = keyCount + 1
  end
  Assert.equal(keyCount, 76, "the 25 destinations collapse to 76 unique preview images")
  local byteCount = 0
  for _ in pairs(distinctBytes) do
    byteCount = byteCount + 1
  end
  Assert.equal(byteCount, 76, "each unique preview image renders distinct pixels")
end

function T.alias_identity_is_preserved_across_shared_triples()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local function slots(symbol)
    return assert(bundle.manifest.previewByMapId[assert(MapCatalog.idForSymbol(symbol))], symbol)
  end
  local function image(symbol, slot)
    local _, _, rgba = pngPixels(bundle, slots(symbol)[slot])
    return rgba
  end

  -- Ilex Forest evening uses its own graphic, distinct from daytime.
  Assert.isTrue(slots("MAP_ILEX_FOREST")[2] ~= slots("MAP_ILEX_FOREST")[1], "Ilex evening is a distinct key")
  Assert.isTrue(image("MAP_ILEX_FOREST", 2) ~= image("MAP_ILEX_FOREST", 1), "Ilex evening renders distinct pixels")

  -- Union Cave aliases evening to daytime: one key, one PNG.
  Assert.equal(slots("MAP_UNION_CAVE_1F")[2], slots("MAP_UNION_CAVE_1F")[1], "Union Cave evening aliases day")

  -- Alternate Ruins of Alph maps and both Victory Road maps share graphics.
  for _, pair in ipairs({
    { "MAP_RUINS_OF_ALPH_HALL_ENTRANCE", "MAP_RUINS_OF_ALPH_HALL_ENTRANCE_SINJOH_EVENT" },
    { "MAP_VICTORY_ROAD_1F", "MAP_VICTORY_ROAD_3F" },
  }) do
    for slot = 0, 3 do
      Assert.equal(slots(pair[1])[slot], slots(pair[2])[slot], pair[1] .. " and " .. pair[2] .. " share slot " .. slot)
    end
  end
end

function T.banner_style_by_map_id_follows_the_area_icon_and_suppresses_zero()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local mapStyle = bundle.manifest.bannerStyleByMapId
  local maps = require("romdump.src.catalog.hgss.maps").byId
  local count = 0
  for id, style in pairs(mapStyle) do
    count = count + 1
    Assert.isTrue(type(id) == "number" and id % 1 == 0, "banner style keys are numeric map ids")
    Assert.isTrue(style >= 0 and style <= 8, "banner style is a source-independent index 0..8")
    local record = assert(maps[id], "the banner style names a frozen map header")
    Assert.equal(style, record.areaIcon - 1, "the style is the 1-based area icon minus one")
    Assert.notNil(bundle.manifest.bannerStyles[style], "every emitted style names a generated banner")
  end
  Assert.isTrue(count > 0, "eligible map headers carry banner styles")

  local zeroMap
  for id = 0, 539 do
    if maps[id].areaIcon == 0 then
      zeroMap = id
      break
    end
  end
  Assert.notNil(zeroMap, "the catalog carries a map with no area icon")
  Assert.isNil(mapStyle[zeroMap], "a map without an area icon is suppressed")
end

-- Retail draws the area-name banner only outdoors: an interior or Pokemon
-- Center header carries no banner style even when its area icon is non-zero,
-- so the runtime banner controller can gate on membership alone.
function T.banner_styles_exclude_buildings()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local mapStyle = bundle.manifest.bannerStyleByMapId
  local maps = require("romdump.src.catalog.hgss.maps").byId

  local interiors = 0
  for id in pairs(mapStyle) do
    local record = assert(maps[id], "a banner style names a frozen map header")
    Assert.isTrue(
      record.mapType ~= "INTERIOR" and record.mapType ~= "POKEMON_CENTER",
      "no building map header carries a banner style: " .. tostring(record.symbol)
    )
  end
  for id = 0, 539 do
    local record = maps[id]
    if (record.mapType == "INTERIOR" or record.mapType == "POKEMON_CENTER") and record.areaIcon ~= 0 then
      interiors = interiors + 1
      Assert.isNil(mapStyle[id], "the building " .. record.symbol .. " carries no banner style")
    end
  end
  Assert.isTrue(interiors > 0, "the catalog carries an interior with a non-zero area icon")

  local buildingId = assert(MapCatalog.idForSymbol("MAP_NEW_BARK_PLAYER_HOUSE_1F"))
  local building = assert(maps[buildingId])
  Assert.equal(building.mapType, "INTERIOR")
  Assert.isTrue(building.areaIcon >= 1, "the sampled building carries an area icon")
  Assert.isNil(mapStyle[buildingId], "an interior building is absent from bannerStyleByMapId")
end

function T.manifest_is_closed_and_carries_no_source_identities()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))

  local referenced = {}
  for style = 0, FieldEntryFixture.BANNER_STYLE_COUNT - 1 do
    referenced[bundle.manifest.bannerStyles[style]] = true
  end
  for _, slots in pairs(bundle.manifest.previewByMapId) do
    for slot = 0, 3 do
      referenced[slots[slot]] = true
    end
  end
  for key in pairs(bundle.manifest.assets) do
    Assert.notNil(referenced[key], "every indexed asset is referenced by the manifest: " .. tostring(key))
  end
  for key in pairs(referenced) do
    Assert.notNil(bundle.manifest.assets[key], "every referenced key is indexed: " .. tostring(key))
  end

  local forbidden = { member = true, memberId = true, narcId = true, fileId = true, alias = true }
  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for k, nested in pairs(value) do
      if type(k) == "string" and forbidden[k] then
        Assert.fail("manifest leaks source detail '" .. k .. "' at " .. path)
      end
      scan(nested, path .. "." .. tostring(k))
    end
  end
  scan(bundle.manifest, "manifest")
end

function T.compilation_is_deterministic()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compile(romFs, sha1, hashLua))
  local second = assert(compile(romFs, sha1, hashLua))
  Assert.equal(first.marker, second.marker)
  Assert.equal(LuaWriter.encode(first.manifest), LuaWriter.encode(second.manifest))
  for path, bytes in pairs(first.assets) do
    Assert.equal(bytes, second.assets[path])
  end
end

function T.truncated_lz10_members_are_typed_stream_errors()
  local base = FieldEntryFixture.uniqueBases()[1]
  local romFs, sha1, hashLua = fixture({
    tamper = function(_, previewMembers)
      previewMembers[base + 2] = lz10Wrap(previewChar(base)):sub(1, 24)
    end,
  })
  local bundle, err = compile(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

function T.duplicate_g2d_chunks_are_typed_errors()
  local base = FieldEntryFixture.uniqueBases()[1]
  local payload = u16(8)
    .. u16(0x20)
    .. u32(3)
    .. u16(0)
    .. u16(0)
    .. u32(0)
    .. u32(32)
    .. u32(0x18)
    .. string.rep("\1", 32)
  local romFs, sha1, hashLua = fixture({
    tamper = function(_, previewMembers)
      previewMembers[base + 2] = container("RGCN", { block("CHAR", payload), block("CHAR", payload) })
    end,
  })
  local bundle, err = compile(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_DUPLICATE)
end

-- A banner char too short for the 1..68 grid, and a banner palette too short
-- for the emitted pixel values, are typed source defects at the compiler
-- boundary (the entry class owns its own source diagnostic), never raw
-- arithmetic failures.
function T.renderer_defects_are_typed_source_errors()
  local shortCharTiles = {}
  for tile = 0, 2 do
    shortCharTiles[tile + 1] = string.rep(string.char(0x11), 32)
  end
  local shortChar = fixture({
    tamper = function(areaWindowMembers)
      areaWindowMembers[1] = lz10Wrap(charDataWithTiles(shortCharTiles))
    end,
  })
  local bundle, err = compile(shortChar)
  Assert.isNil(bundle)
  Assert.isTrue(Errors.is(err))
  Assert.isTrue(codeMatches(err, "SOURCE_INVALID"), "an out-of-range grid tile is a typed source defect")

  local shortPalette = fixture({
    tamper = function(areaWindowMembers)
      areaWindowMembers[2] = paletteData({ 0x7FFF })
    end,
  })
  local paletteBundle, paletteErr = compile(shortPalette)
  Assert.isNil(paletteBundle)
  Assert.isTrue(Errors.is(paletteErr))
  Assert.isTrue(codeMatches(paletteErr, "SOURCE_INVALID"), "an uncovered banner pixel is a typed source defect")
end

function T.writer_commits_marker_last_and_reads_back()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldEntryCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, bundle.marker))
  Assert.isFalse(FieldEntryAssetCache.isReady(cache, bundle.marker .. "-stale"))
  local manifest = assert(cache:loadLua(FieldEntryAssetCache.manifestPath()))
  Assert.equal(manifest.schema, FieldEntryAssetCache.SCHEMA)
end

function T.failed_rebuild_preserves_the_previous_class()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldEntryCacheWriter.write(cache, first)
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find(FieldEntryAssetCache.assetDir(), 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(compile(romFs, sha1, hashLua))
  second.marker = FieldEntryAssetCache.marker("rom-sha", "new-dep-hash")
  Assert.throws(function()
    FieldEntryCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, first.marker), "the previous class remains ready")
  Assert.equal(cache:read(FieldEntryAssetCache.markerPath()), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-entry"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldEntryCacheWriter.write(cache, second)
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, second.marker), "a retry publishes the new class")
end

function T.stage_validation_failure_is_typed_and_preserves_the_previous_class()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldEntryCacheWriter.write(cache, first)
  local second = assert(compile(romFs, sha1, hashLua))
  second.manifest.bannerStyles[8] = nil
  second.marker = FieldEntryAssetCache.marker("rom-sha", "new-dep-hash")
  Assert.throws(function()
    FieldEntryCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, first.marker), "the previous class remains ready")
  Assert.equal(cache:read(FieldEntryAssetCache.markerPath()), first.marker)
end

function T.first_publish_rename_failure_rolls_back()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldEntryCacheWriter.write(cache, first)
  local originalReplace = backend.replace
  local calls = 0
  backend.replace = function(self, source, destination)
    calls = calls + 1
    if calls == 1 then
      error("injected rename failure")
    end
    return originalReplace(self, source, destination)
  end
  local second = assert(compile(romFs, sha1, hashLua))
  second.marker = FieldEntryAssetCache.marker("rom-sha", "new-dep-hash")
  Assert.throws(function()
    FieldEntryCacheWriter.write(cache, second)
  end)
  backend.replace = originalReplace
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, first.marker), "the previous class remains ready after rollback")
  Assert.equal(cache:read(FieldEntryAssetCache.markerPath()), first.marker)
end

function T.second_publish_rename_failure_rolls_back_both_roots()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldEntryCacheWriter.write(cache, first)
  local originalReplace = backend.replace
  local calls = 0
  backend.replace = function(self, source, destination)
    calls = calls + 1
    if calls == 2 then
      error("injected second rename failure")
    end
    return originalReplace(self, source, destination)
  end
  local second = assert(compile(romFs, sha1, hashLua))
  second.marker = FieldEntryAssetCache.marker("rom-sha", "new-dep-hash")
  Assert.throws(function()
    FieldEntryCacheWriter.write(cache, second)
  end)
  backend.replace = originalReplace
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, first.marker), "the previous class remains ready after rollback")
  Assert.equal(cache:read(FieldEntryAssetCache.markerPath()), first.marker)
end

-- The session worker path stages through a caller-owned prepared artifact:
-- staging alone never reads ready, and publication makes the class ready with
-- the marker last.
function T.stages_through_a_prepared_artifact_without_touching_live_before_publish()
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = "test-generation",
    epoch = 1,
    kind = "field-entry",
    key = "global",
    jobKey = "field-entry:global",
    stageName = "field-entry-stage-test",
  })
  Assert.equal(FieldEntryCacheWriter.stage(artifact, bundle), bundle.marker)
  Assert.isFalse(FieldEntryAssetCache.isReady(cache, bundle.marker), "staging alone never reads ready")
  artifact:finishSuccess({ marker = bundle.marker })
  artifact:publish({
    generationId = "test-generation",
    epoch = 1,
    kind = "field-entry",
    key = "global",
    jobKey = "field-entry:global",
  })
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, bundle.marker), "the published class reads ready")
end

return { tests = T }
