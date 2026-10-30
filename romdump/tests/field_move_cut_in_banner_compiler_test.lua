-- Deterministic field-move cut-in banner compilation using a synthetic
-- source archive: the HeartGold banner triple (members 0/1/2) and the
-- SoulSilver triple (members 3/4/5) render as 256x256 BG3 surfaces through
-- the sixteen colors the retail loader places at hardware palette slot 12,
-- the generated manifest carries only semantic keys, and the publication
-- matrix (stage write failure, stage validation failure) reuses
-- ArtifactPublisher through a FakeCache so the previous ready class stays
-- readable and the marker never claims an incomplete class.
--
-- Source basis: the retail ROM's field/move cut-in banner load steps
-- (FieldMoveCutIn_InitBannerGraphics with its HEARTGOLD/SOULSILVER member
-- selection, CutInBanner_LoadPalette/LoadChar/LoadScreen, and the full
-- 32x32 tilemap palette rewrite to slot 12 in field_move_cut_in.c).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMoveCutInBannerCompiler = require("romdump.src.digest.field.FieldMoveCutInBannerCompiler")
local FieldMoveCutInBannerCacheWriter = require("romdump.src.digest.field.FieldMoveCutInBannerCacheWriter")
local FieldMoveCutInBannerAssetCache = require("libs.assets.src.field.FieldMoveCutInBannerAssetCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local PngReader = require("tests.support.PngReader")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")

local T = {}

local ARCHIVE_ALIAS = "cut_in_banner"

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
  local running = 0
  for _, bytes in ipairs(members) do
    btaf = btaf .. u32(running) .. u32(running + #bytes)
    running = running + #bytes
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

-- Tile 0 carries a bright marker value that must never appear in the
-- output (screens address tiles 1..63); tile 1 is an all-zero source tile
-- that must render transparent under the hardware transparent-zero role.
local function bannerCharData(style)
  local tiles = {}
  tiles[1] = string.rep(string.char(0xFF), 32)
  tiles[2] = string.rep("\0", 32)
  for tile = 2, 63 do
    tiles[tile + 1] = string.rep(string.char((((tile + style) % 14) + 1) * 0x11), 32)
  end
  return charDataWithTiles(tiles)
end

-- A 16-color banner palette whose slot s decodes to base + s: the two
-- editions render distinct artwork, and the text of the pixel expectation
-- resolves each value through palette bank 0 alone.
local function bannerPalette(base)
  local colors = {}
  for slot = 0, 15 do
    colors[slot + 1] = base + slot
  end
  return paletteData(colors)
end

-- A 32x32 banner screen exercising the NSCR flip bits and nonzero palette
-- numbers: retail rewrites the whole tilemap to slot 12, so the compiler
-- must render every entry through bank 0 regardless of the stored number.
local function bannerScreen()
  local entries = {}
  for index = 1, 1024 do
    local tile = ((index - 1) % 63) + 1
    local flipH = (index - 1) % 3 == 0
    local flipV = (index - 1) % 5 == 0
    entries[index] = tile + (flipH and 1024 or 0) + (flipV and 2048 or 0) + 5 * 4096
  end
  return screenDataWH(256, 256, entries)
end

-- A synthetic RomFs whose cut-in banner archive carries the audited member
-- selection: HeartGold char/screen/palette at 0/1/2 and SoulSilver at 3/4/5.
-- `opts` selects the edition (`version`), tampers with the raw members
-- (`tamper`), or drops one member read (`missingMember`).
local function fixture(opts)
  opts = opts or {}
  local version = opts.version or "heartgold"
  local members = {
    lz10Wrap(bannerCharData(0)),
    lz10Wrap(bannerScreen()),
    bannerPalette(0),
    lz10Wrap(bannerCharData(7)),
    lz10Wrap(bannerScreen()),
    bannerPalette(64),
  }
  if opts.tamper then
    opts.tamper(members)
  end
  local archiveBytes = narc(members)

  local entry = {
    fileId = 93,
    narcId = 93,
    path = "a/0/9/3",
    symbol = "NARC_application_choose_starter_choose_starter_sub_res",
    alias = ARCHIVE_ALIAS,
  }
  local archives = { [ARCHIVE_ALIAS] = entry }
  archives[entry.symbol] = entry

  local romFs = {
    resolvedNarc = function(_, alias)
      return archives[alias]
    end,
    read = function(_, fileId)
      if fileId == 93 then
        return archiveBytes
      end
      Assert.fail("unexpected read " .. tostring(fileId))
    end,
    openNarc = function(_, alias)
      local Narc = require("libs.nds.src.nitro.Narc")
      local archive = assert(Narc.open(archiveBytes, alias))
      if opts.missingMember ~= nil then
        local missing = opts.missingMember
        local originalRead = archive.readMember
        archive.readMember = function(self, memberId)
          if memberId == missing then
            return nil
          end
          return originalRead(self, memberId)
        end
      end
      return archive
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return version
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
  return FieldMoveCutInBannerCompiler.compile(romFs, sha1, hashLua)
end

local function memberBytes(romFs, memberId)
  local archive = assert(romFs:openNarc(ARCHIVE_ALIAS))
  local bytes = assert(archive:readMember(memberId))
  if string.byte(bytes, 1) == 0x10 then
    local plain, err = Lz10.decode(bytes)
    assert(plain, err and err.message)
    return plain
  end
  return bytes
end

-- The expected banner pixels, computed independently from the source
-- members: every NSCR entry renders through palette bank 0 (the retail
-- full-tilemap rewrite to slot 12), with source-zero transparent.
local function expectedPixels(romFs, charMember, screenMember, paletteMember)
  local char = assert(G2dDecoder.decodeChar(memberBytes(romFs, charMember), { label = "banner char" }))
  local pal = assert(G2dDecoder.decodePalette(memberBytes(romFs, paletteMember), { label = "banner palette" }))
  local screen = assert(G2dDecoder.decodeScreen(memberBytes(romFs, screenMember), { label = "banner screen" }))
  local forced = { width = screen.width, height = screen.height, entries = {} }
  for index, entry in ipairs(screen.entries) do
    forced.entries[index] = { tile = entry.tile, palette = 0, flipH = entry.flipH, flipV = entry.flipV }
  end
  return G2dRasterizer.renderScreen(char, { colors = pal.colors }, forced, { asset = "banner expectation" })
end

local function pngPixels(bundle)
  local entry = assert(bundle.manifest.assets.banner, "the manifest indexes the banner asset")
  local bytes = assert(bundle.assets[entry.image], "the asset carries generated bytes: " .. tostring(entry.image))
  local width, height, rgba = PngReader.rgba(bytes)
  return width, height, rgba
end

local function codeMatches(err, suffix)
  return type(assert(err).code) == "string" and assert(err).code:match(suffix) ~= nil
end

function T.compiles_the_banner_manifest_and_asset()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  Assert.equal(bundle.manifest.schema, FieldMoveCutInBannerAssetCache.SCHEMA)
  Assert.equal(bundle.manifest.reference.width, 256)
  Assert.equal(bundle.manifest.reference.height, 256)
  Assert.equal(bundle.manifest.banner, "banner")
  Assert.equal(bundle.manifest.paletteSlot, 12)
  Assert.isTrue(FieldMoveCutInBannerAssetCache.validateManifest(bundle.manifest))
  Assert.equal(bundle.marker, FieldMoveCutInBannerAssetCache.marker("rom-sha", "dependency-sha"))
  local entry = assert(bundle.manifest.assets.banner, "the manifest indexes the banner")
  Assert.isTrue(entry.image:find("^assets/generated/field/cutin%-banner/") ~= nil)
  Assert.equal(entry.width, 256)
  Assert.equal(entry.height, 256)
  Assert.isTrue(#assert(bundle.assets[entry.image]) > 0)
end

function T.heartgold_and_soulsilver_select_their_own_triples()
  local hgFs, hgSha, hgHash = fixture({ version = "heartgold" })
  local hg = assert(compile(hgFs, hgSha, hgHash))
  local ssFs, ssSha, ssHash = fixture({ version = "soulsilver" })
  local ss = assert(compile(ssFs, ssSha, ssHash))

  local _, _, hgRgba = pngPixels(hg)
  local _, _, ssRgba = pngPixels(ss)
  Assert.isTrue(hgRgba ~= ssRgba, "the editions render distinct banner artwork")

  local hgImage = expectedPixels(hgFs, 0, 1, 2)
  Assert.equal(hgImage.width, 256)
  Assert.equal(hgImage.height, 256)
  Assert.equal(hgRgba, hgImage.pixels, "the HeartGold banner follows members 0/1/2 through bank 0")
  local ssImage = expectedPixels(ssFs, 3, 4, 5)
  Assert.equal(ssRgba, ssImage.pixels, "the SoulSilver banner follows members 3/4/5 through bank 0")

  local function memberIds(bundle)
    local ids = {}
    for _, dep in ipairs(assert(bundle.dependencies)) do
      if dep.memberId ~= nil then
        ids[#ids + 1] = dep.memberId
      end
    end
    table.sort(ids)
    return ids
  end
  Assert.deepEqual(memberIds(hg), { 0, 1, 2 }, "the HeartGold dependency record pins members 0/1/2")
  Assert.deepEqual(memberIds(ss), { 3, 4, 5 }, "the SoulSilver dependency record pins members 3/4/5")
end

function T.banner_renders_with_transparent_source_zero()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local width, height, rgba = pngPixels(bundle)
  -- Screen entry 0 addresses tile 1, the all-zero source tile: under the
  -- hardware transparent-zero role its pixels stay transparent.
  local _, _, _, alpha = PngReader.pixel(rgba, width, 0, 0)
  Assert.equal(alpha, 0, "the source-zero grid tile stays transparent")
  Assert.equal(width, 256)
  Assert.equal(height, 256)
end

function T.manifest_is_closed_and_carries_no_source_identities()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))

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

function T.missing_source_members_are_typed_source_errors()
  local romFs, sha1, hashLua = fixture({ missingMember = 2 })
  local bundle, err = compile(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.isTrue(Errors.is(err))
  Assert.isTrue(codeMatches(err, "SOURCE_INVALID"), "a missing banner member is a typed source defect")
end

function T.truncated_lz10_members_are_typed_stream_errors()
  local romFs, sha1, hashLua = fixture({
    tamper = function(members)
      members[1] = lz10Wrap(bannerCharData(0)):sub(1, 24)
    end,
  })
  local bundle, err = compile(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

function T.duplicate_g2d_chunks_are_typed_errors()
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
    tamper = function(members)
      members[1] = lz10Wrap(container("RGCN", { block("CHAR", payload), block("CHAR", payload) }))
    end,
  })
  local bundle, err = compile(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_DUPLICATE)
end

function T.non_banner_screens_are_typed_source_errors()
  local shortEntries = {}
  for index = 1, 768 do
    shortEntries[index] = ((index - 1) % 63) + 1
  end
  local romFs, sha1, hashLua = fixture({
    tamper = function(members)
      members[2] = lz10Wrap(screenDataWH(256, 192, shortEntries))
    end,
  })
  local bundle, err = compile(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.isTrue(Errors.is(err))
  Assert.isTrue(codeMatches(err, "SOURCE_INVALID"), "a non-32x32 banner tilemap is a typed source defect")
end

function T.writer_commits_marker_last_and_reads_back()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMoveCutInBannerCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldMoveCutInBannerAssetCache.isReady(cache, bundle.marker))
  Assert.isFalse(FieldMoveCutInBannerAssetCache.isReady(cache, bundle.marker .. "-stale"))
  local manifest = assert(cache:loadLua(FieldMoveCutInBannerAssetCache.manifestPath()))
  Assert.equal(manifest.schema, FieldMoveCutInBannerAssetCache.SCHEMA)
end

function T.failed_rebuild_preserves_the_previous_class()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldMoveCutInBannerCacheWriter.write(cache, first)
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find(FieldMoveCutInBannerAssetCache.assetDir(), 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(compile(romFs, sha1, hashLua))
  second.marker = FieldMoveCutInBannerAssetCache.marker("rom-sha", "new-dep-hash")
  Assert.throws(function()
    FieldMoveCutInBannerCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldMoveCutInBannerAssetCache.isReady(cache, first.marker), "the previous class remains ready")
  Assert.equal(cache:read(FieldMoveCutInBannerAssetCache.markerPath()), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-move-cut-in-banner"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldMoveCutInBannerCacheWriter.write(cache, second)
  Assert.isTrue(FieldMoveCutInBannerAssetCache.isReady(cache, second.marker), "a retry publishes the new class")
end

function T.stage_validation_failure_is_typed_and_preserves_the_previous_class()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMoveCutInBannerCacheWriter.write(cache, first)
  local second = assert(compile(romFs, sha1, hashLua))
  second.manifest.paletteSlot = 0
  second.marker = FieldMoveCutInBannerAssetCache.marker("rom-sha", "new-dep-hash")
  Assert.throws(function()
    FieldMoveCutInBannerCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldMoveCutInBannerAssetCache.isReady(cache, first.marker), "the previous class remains ready")
  Assert.equal(cache:read(FieldMoveCutInBannerAssetCache.markerPath()), first.marker)
end

-- The session worker path stages through a caller-owned prepared artifact:
-- staging alone never reads ready, and publication makes the class ready
-- with the marker last.
function T.stages_through_a_prepared_artifact_without_touching_live_before_publish()
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = "test-generation",
    epoch = 1,
    kind = "field-move-cut-in-banner",
    key = "global",
    jobKey = "field-move-cut-in-banner:global",
    stageName = "cut-in-banner-stage-test",
  })
  Assert.equal(FieldMoveCutInBannerCacheWriter.stage(artifact, bundle), bundle.marker)
  Assert.isFalse(FieldMoveCutInBannerAssetCache.isReady(cache, bundle.marker), "staging alone never reads ready")
  artifact:finishSuccess({ marker = bundle.marker })
  artifact:publish({
    generationId = "test-generation",
    epoch = 1,
    kind = "field-move-cut-in-banner",
    key = "global",
    jobKey = "field-move-cut-in-banner:global",
  })
  Assert.isTrue(FieldMoveCutInBannerAssetCache.isReady(cache, bundle.marker), "the published class reads ready")
end

return { tests = T }
