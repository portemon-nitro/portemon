local Assert = require("tests.support.Assert")
local RomFs = require("romdump.src.source.RomFs")
local MapMatrix = require("romdump.src.digest.map.MapMatrix")
local DumpFixture = require("tests.support.DumpFixture")
local BackwardsLz = require("tests.support.BackwardsLz")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("romdump.src.source.GameVersion")
local Narc = require("libs.nds.src.nitro.Narc")
local NdsBuilder = require("tests.support.NdsBuilder")
local NdsRom = require("romdump.src.source.NdsRom")
local RomSource = require("romdump.src.source.RomSource")

local T = {}

-- Direct-from-cartridge fixtures use an unclaimed game code so the shared
-- version table never confuses them with a canonical release discard check.
local DIRECT_VERSION_ID = "directcartridge"
local DIRECT_GAME_CODE = "IXXX"
local COMPRESSED_FLAG_BIT = 16777216 -- bit 24

local function directSpec()
  local spec = DumpFixture.spec()
  spec.gameCode = DIRECT_GAME_CODE
  return spec
end

local function openDirectCartridge(spec)
  local data = NdsBuilder.build(spec)
  local info = {
    id = DIRECT_VERSION_ID,
    sha1 = RomSource.fromString(data):sha1(),
    gameCode = spec.gameCode or DIRECT_GAME_CODE,
    expectedSize = #data,
  }
  local versions = {
    forSha1 = function(h)
      return h == info.sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == info.gameCode and info or nil
    end,
  }
  local source = RomSource.fromString(data)
  local rom, err = NdsRom.open(source, versions)
  Assert.notNil(rom, "synthetic cartridge failed to open: " .. tostring(err))
  return { data = data, source = source, rom = assert(rom), info = info }
end

-- Temporarily catalogues the synthetic cartridge so identity checks that
-- consult the shared version table can recognize it. Restores the table even
-- when the body fails.
local function withDirectVersion(info, fn)
  local saved = GameVersion.VERSIONS[DIRECT_VERSION_ID]
  GameVersion.VERSIONS[DIRECT_VERSION_ID] = {
    id = DIRECT_VERSION_ID,
    label = "Synthetic",
    displayName = "Synthetic Cartridge",
    sha1 = info.sha1,
    gameCode = info.gameCode,
    expectedSize = info.expectedSize,
  }
  local ok, err = pcall(fn)
  GameVersion.VERSIONS[DIRECT_VERSION_ID] = saved
  if not ok then
    error(err, 0)
  end
end

local function openDirectFs(cartridge, backend)
  backend = backend or FakeCache.new()
  local results = { pcall(RomFs.open, DIRECT_VERSION_ID, cartridge.source) }
  Assert.isTrue(results[1], "direct open raised: " .. tostring(results[2]))
  local fs, err = results[2], results[3]
  Assert.notNil(fs, "expected reads directly from the cartridge without an extracted tree; got: " .. tostring(err))
  return assert(fs), backend
end

local function sortedKeyString(value)
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return table.concat(keys, ",")
end

-- RomFs.open returns its error unannotated, so err arrives typed as RomFs
-- itself; cast to the Errors.Error contract the test has already verified.
---@param e any
---@return { code: string }
local function asError(e)
  return e
end

local function openFs()
  local r = DumpFixture.extract()
  Assert.notNil(r.report, "fixture extraction failed: " .. tostring(r.err))
  local fs, err = RomFs.open(r.versionId, r.cache)
  Assert.notNil(fs, "RomFs.open failed: " .. tostring(err))
  return assert(fs), r
end

function T.loads_index_and_builds_path_map()
  local fs, r = openFs()
  Assert.equal(fs:version(), "heartgold")
  Assert.equal(fs:fileCount(), r.rom:fatCount())
  Assert.equal(fs:fileIdForPath("a/0/0/2"), 2)
  Assert.equal(fs:fileIdForPath("a/0/4/1"), 5)
  Assert.equal(fs:info("data/sound/gs_sound_data.sdat").path, "romfs/data/sound/gs_sound_data.sdat")
end

function T.reads_by_file_id_and_source_path()
  local fs = openFs()
  local soundFileId = fs:fileIdForPath("data/sound/gs_sound_data.sdat")
  Assert.equal(fs:read(soundFileId), "SDAT-STUB")
  Assert.equal(fs:readSourcePath("data/sound/gs_sound_data.sdat"), "SDAT-STUB")
  -- fileId and source path resolve to the same bytes.
  Assert.equal(fs:read(soundFileId), fs:readSourcePath("data/sound/gs_sound_data.sdat"))
end

function T.info_resolves_source_path_and_file_id()
  local fs = openFs()
  Assert.equal(fs:info("a/0/4/1").fileId, 5)
  Assert.equal(fs:info(5).sourcePath, "a/0/4/1")
  Assert.equal(fs:info(0).kind, "overlay9")
end

function T.reads_overlay_by_cpu_and_overlay_id()
  local fs = openFs()
  local info = assert(fs:overlayInfo("arm9", 0))
  Assert.equal(info.cpu, "arm9")
  Assert.equal(info.overlayId, 0)
  Assert.equal(info.fileId, 0)
  Assert.equal(info.path, "system/overlay9/overlay_0.bin")
  local bytes, readInfo = fs:readOverlay("arm9", 0)
  Assert.equal(bytes, "OVERLAY0-DATA")
  assert(readInfo)
  Assert.equal(readInfo.fileId, info.fileId)
end

function T.overlay_lookup_returns_typed_errors()
  local fs = openFs()
  local info, cpuErr = fs:overlayInfo("arm11", 0)
  Assert.isNil(info)
  Assert.equal(assert(cpuErr).code, "ROMFS_OVERLAY_UNKNOWN_CPU")
  local bytes, idErr = fs:readOverlay("arm9", 99)
  Assert.isNil(bytes)
  Assert.equal(assert(idErr).code, "ROMFS_OVERLAY_UNKNOWN_ID")
end

function T.missing_overlay_file_returns_overlay_error()
  local fs, fixture = openFs()
  fixture.cache:remove("system/overlay9/overlay_0.bin")
  local bytes, err = fs:readOverlay("arm9", 0)
  Assert.isNil(bytes)
  Assert.equal(assert(err).code, "ROMFS_OVERLAY_FILE_MISSING")
  Assert.equal(assert(err).context.fileId, 0)
end

function T.resolves_alias_and_symbol_to_path_and_file_id()
  local fs = openFs()
  local byAlias = assert(fs:resolvedNarc("map_matrices"))
  Assert.equal(byAlias.path, "a/0/4/1")
  Assert.equal(byAlias.fileId, 5)
  local bySymbol = assert(fs:resolvedNarc("NARC_fielddata_mapmatrix_map_matrix"))
  Assert.equal(bySymbol.fileId, 5)
end

function T.opens_narc_and_decodes_matrix()
  local fs = openFs()
  local narc, err = fs:openNarc("map_matrices")
  Assert.notNil(narc, "openNarc failed: " .. tostring(err))
  assert(narc)
  Assert.equal(narc:memberCount(), 1)
  local matrix = assert(MapMatrix.decode(narc:readMember(0), 0))
  Assert.equal(matrix.width, 2)
  Assert.equal(matrix.name, "MM")
  Assert.equal(matrix:modelIdAt(0, 0), 40)
end

-- NARC aliases resolve purely from the checked-in manifest plus the FNT path
-- index; no baked resolved_narcs table is produced or required. This means an
-- alias added after a dump was imported works without re-importing the ROM.
function T.resolves_without_a_baked_narc_table()
  local r = DumpFixture.extract()
  Assert.isNil(
    r.backend.files[r.versionId .. "/data/generated/resolved_narcs.lua"],
    "resolved_narcs.lua should no longer be produced"
  )
  local fs = assert(RomFs.open(r.versionId, r.cache))
  local entry = assert(fs:resolvedNarc("map_matrices"))
  Assert.notNil(entry, "alias must resolve from manifest + FNT index")
  Assert.equal(entry.path, "a/0/4/1")
  Assert.equal(entry.fileId, 5)
  Assert.isNil(entry.memberCount, "member count is not precomputed; open the NARC for it")
  local narc, err = fs:openNarc("map_matrices")
  Assert.notNil(narc, "openNarc failed: " .. tostring(err))
  assert(narc)
  Assert.equal(narc:memberCount(), 1)
end

function T.unknown_source_path_returns_error()
  local fs = openFs()
  local data, err = fs:read("a/9/9/9")
  Assert.isNil(data)
  Assert.equal(assert(err).code, "ROMFS_PATH_UNKNOWN")
end

function T.open_fails_when_not_ready()
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local fs, err = RomFs.open("heartgold", cache)
  Assert.isNil(fs)
  Assert.equal(asError(err).code, "ROMFS_NOT_READY")
end

function T.open_rejects_schema_mismatch()
  local r = DumpFixture.extract()
  r.cache:writeLua("data/generated/romfs_index.lua", { schema = 2 })
  local fs, err = RomFs.open(r.versionId, r.cache)
  Assert.isNil(fs)
  Assert.equal(asError(err).code, "ROMFS_SCHEMA_MISMATCH")
end

function T.open_rejects_overlay_schema_mismatch()
  local r = DumpFixture.extract()
  r.cache:writeLua("data/generated/overlay_index.lua", { schema = 2 })
  local fs, err = RomFs.open(r.versionId, r.cache)
  Assert.isNil(fs)
  Assert.equal(asError(err).code, "ROMFS_OVERLAY_INDEX_SCHEMA")
end

function T.reads_named_unmapped_and_overlay_entries_directly_from_the_cartridge()
  local cartridge = openDirectCartridge(directSpec())
  local backend = FakeCache.new()
  withDirectVersion(cartridge.info, function()
    local fs = openDirectFs(cartridge, backend)
    Assert.equal(fs:read(0), "OVERLAY0-DATA")
    Assert.equal(fs:read(1), "UNMAPPED-DATA")
    Assert.equal(fs:readSourcePath("data/sound/gs_sound_data.sdat"), "SDAT-STUB")
    Assert.equal(fs:read(0), cartridge.rom:readFatFile(0))
    local narcFileId = fs:fileIdForPath("a/0/4/1")
    Assert.equal(fs:read(narcFileId), cartridge.rom:readFatFile(narcFileId))
    Assert.isNil(next(backend.files), "direct reads must not stage bytes under the cache")
    Assert.isNil(next(backend.dirs), "direct reads must not create cache directories")
    fs:close()
  end)
end

function T.direct_index_matches_the_canonical_cartridge_map()
  local cartridge = openDirectCartridge(directSpec())
  withDirectVersion(cartridge.info, function()
    local fs = openDirectFs(cartridge)
    local map = cartridge.rom:fileMap()
    Assert.equal(fs:fileCount(), cartridge.rom:fatCount())
    Assert.equal(fs:fileIdForPath("a/0/4/1"), 5)
    local entry, entryErr = fs:info(5)
    Assert.notNil(entry, "expected an index entry for fileId 5; got: " .. tostring(entryErr))
    assert(entry)
    Assert.equal(entry.sourcePath, "a/0/4/1")
    Assert.equal(entry.offset, map[5].offset)
    Assert.equal(entry.size, map[5].size)
    Assert.equal(entry.kind, map[5].kind)
    Assert.equal(entry.path, map[5].path)
    local zero, zeroErr = fs:info(0)
    Assert.notNil(zero, "fileId 0 must resolve; got: " .. tostring(zeroErr))
    assert(zero)
    Assert.equal(zero.kind, "overlay9")
    Assert.equal(fs:pathForFileId(0), map[0].path)
    local byPath, pathErr = fs:info("data/sound/gs_sound_data.sdat")
    Assert.notNil(byPath, "source-path lookup failed: " .. tostring(pathErr))
    assert(byPath)
    Assert.equal(byPath.fileId, fs:fileIdForPath("data/sound/gs_sound_data.sdat"))
    fs:close()
  end)
end

function T.direct_metadata_keeps_the_extracted_record_shape_with_data_derived_identity()
  local cartridge = openDirectCartridge(directSpec())
  withDirectVersion(cartridge.info, function()
    local fs = openDirectFs(cartridge)
    local metadata = fs:metadata()
    local anchor = DumpFixture.extract()
    local anchorFs, anchorErr = RomFs.open(anchor.versionId, anchor.cache)
    Assert.notNil(anchorFs, "extracted anchor failed to open: " .. tostring(anchorErr))
    local anchorMetadata = assert(anchorFs):metadata()
    Assert.equal(sortedKeyString(metadata), sortedKeyString(anchorMetadata))
    Assert.equal(metadata.sha1, cartridge.info.sha1)
    Assert.equal(metadata.version, DIRECT_VERSION_ID)
    Assert.equal(metadata.size, #cartridge.data)
    Assert.equal(metadata.title, anchorMetadata.title)
    Assert.equal(metadata.headerSize, anchorMetadata.headerSize)
    Assert.deepEqual(metadata.fnt, anchorMetadata.fnt)
    Assert.deepEqual(metadata.fat, anchorMetadata.fat)
    Assert.deepEqual(metadata.arm9, anchorMetadata.arm9)
    Assert.deepEqual(metadata.arm7, anchorMetadata.arm7)
    Assert.deepEqual(metadata.arm9Overlays, anchorMetadata.arm9Overlays)
    Assert.deepEqual(metadata.arm7Overlays, anchorMetadata.arm7Overlays)
    fs:close()
  end)
end

function T.direct_narc_aliases_decode_the_same_members()
  local cartridge = openDirectCartridge(directSpec())
  withDirectVersion(cartridge.info, function()
    local fs = openDirectFs(cartridge)
    local byAlias = assert(fs:resolvedNarc("map_matrices"))
    Assert.equal(byAlias.path, "a/0/4/1")
    local narc, narcErr = fs:openNarc("map_matrices")
    Assert.notNil(narc, "openNarc failed: " .. tostring(narcErr))
    assert(narc)
    Assert.equal(narc:memberCount(), 1)
    local matrix = assert(MapMatrix.decode(narc:readMember(0), 0))
    Assert.equal(matrix.width, 2)
    Assert.equal(matrix:modelIdAt(0, 0), 40)
    local bySymbol = assert(fs:resolvedNarc("NARC_fielddata_mapmatrix_map_matrix"))
    Assert.equal(bySymbol.fileId, byAlias.fileId)
    local raw = fs:readSourcePath("a/0/0/2")
    Assert.equal(raw, cartridge.rom:readFatFile(fs:fileIdForPath("a/0/0/2")))
    local second = assert(Narc.open(raw, "a/0/0/2"))
    Assert.equal(second:memberCount(), 2)
    Assert.equal(second:readMember(0), "P0")
    Assert.equal(second:readMember(1), "P1")
    fs:close()
  end)
end

function T.direct_stats_match_the_extracted_index_counts()
  local cartridge = openDirectCartridge(directSpec())
  withDirectVersion(cartridge.info, function()
    local fs = openDirectFs(cartridge)
    local anchor = DumpFixture.extract()
    local anchorFs, anchorErr = RomFs.open(anchor.versionId, anchor.cache)
    Assert.notNil(anchorFs, "extracted anchor failed to open: " .. tostring(anchorErr))
    Assert.deepEqual(fs:stats(), assert(anchorFs):stats())
    fs:close()
  end)
end

function T.direct_overlays_decode_like_the_canonical_reader()
  local spec = directSpec()
  local compressed, decodedLength = BackwardsLz.growing(string.byte("O"), 40)
  spec.overlays9 = {
    "OVERLAY0-DATA",
    {
      content = compressed,
      ramAddress = 0x02200000,
      ramSize = decodedLength,
      flags = COMPRESSED_FLAG_BIT + #compressed,
    },
  }
  local cartridge = openDirectCartridge(spec)
  withDirectVersion(cartridge.info, function()
    local fs = openDirectFs(cartridge)
    local raw, rawErr = fs:readOverlay("arm9", 0)
    Assert.notNil(raw, "raw overlay read failed: " .. tostring(rawErr))
    Assert.equal(raw, "OVERLAY0-DATA")
    local decoded, decodedErr = fs:readOverlay("arm9", 1)
    Assert.notNil(decoded, "compressed overlay read failed: " .. tostring(decodedErr))
    local expected, expectedErr = cartridge.rom:readOverlay("arm9", 1)
    Assert.notNil(expected, "canonical overlay read failed: " .. tostring(expectedErr))
    Assert.equal(decoded, string.rep("O", decodedLength))
    Assert.equal(decoded, expected)
    local _, readInfo = fs:readOverlay("arm9", 1)
    Assert.isTrue(assert(readInfo).isCompressed, "the decoded overlay must report its compressed origin")
    local info = assert(fs:overlayInfo("arm9", 1))
    Assert.equal(info.path, "system/overlay9/overlay_1.bin")
    Assert.equal(info.isCompressed, true)
    Assert.equal(info.ramSize, decodedLength)
    fs:close()
  end)
end

function T.direct_overlay_lookup_reports_typed_errors()
  local cartridge = openDirectCartridge(directSpec())
  withDirectVersion(cartridge.info, function()
    local fs = openDirectFs(cartridge)
    local _, cpuErr = fs:overlayInfo("arm11", 0)
    Assert.equal(assert(cpuErr).code, "ROMFS_OVERLAY_UNKNOWN_CPU")
    local _, idErr = fs:readOverlay("arm9", 99)
    Assert.equal(assert(idErr).code, "ROMFS_OVERLAY_UNKNOWN_ID")
    local _, arm7Err = fs:readOverlay("arm7", 0)
    Assert.equal(assert(arm7Err).code, "ROMFS_OVERLAY_UNKNOWN_ID")
    fs:close()
  end)
end

function T.direct_reader_over_a_shared_buffer_matches_the_string_reader()
  local cartridge = openDirectCartridge(directSpec())
  withDirectVersion(cartridge.info, function()
    local buffered = RomSource.fromByteData(love.data.newByteData(cartridge.data), "rom.nds")
    local fs, fsErr = RomFs.open(DIRECT_VERSION_ID, buffered)
    Assert.notNil(fs, "expected a reader over the shared buffer; got: " .. tostring(fsErr))
    assert(fs)
    local stringFs, stringErr = RomFs.open(DIRECT_VERSION_ID, cartridge.source)
    Assert.notNil(stringFs, "expected a reader over the string view; got: " .. tostring(stringErr))
    assert(stringFs)
    Assert.equal(
      fs:readSourcePath("data/sound/gs_sound_data.sdat"),
      stringFs:readSourcePath("data/sound/gs_sound_data.sdat")
    )
    Assert.equal(fs:read(0), "OVERLAY0-DATA")
    local overlay, overlayErr = fs:readOverlay("arm9", 0)
    Assert.notNil(overlay, "buffered overlay read failed: " .. tostring(overlayErr))
    Assert.equal(overlay, stringFs:readOverlay("arm9", 0))
    Assert.deepEqual(fs:stats(), stringFs:stats())
    fs:close()
    stringFs:close()
  end)
end

function T.direct_close_keeps_the_caller_owned_buffer_usable()
  local cartridge = openDirectCartridge(directSpec())
  withDirectVersion(cartridge.info, function()
    local shared = love.data.newByteData(cartridge.data)
    local source = RomSource.fromByteData(shared, "rom.nds")
    local fs = assert(RomFs.open(DIRECT_VERSION_ID, source))
    Assert.equal(fs:read(1), "UNMAPPED-DATA")
    fs:close()
    Assert.equal(source:read(0, #cartridge.data), cartridge.data)
    Assert.isTrue(source:byteData() == shared, "closing the reader must not release the shared buffer")
  end)
end

function T.direct_open_rejects_a_mismatched_version()
  local cartridge = openDirectCartridge(directSpec())
  withDirectVersion(cartridge.info, function()
    local fs, err = RomFs.open("heartgold", cartridge.source)
    Assert.isNil(fs, "a cartridge must not open under another version")
    Assert.equal(assert(err).code, "ROMFS_VERSION_MISMATCH")
  end)
end

function T.direct_open_rejects_a_non_source()
  local fs, err = RomFs.open(DIRECT_VERSION_ID, {})
  Assert.isNil(fs, "a non-source must not open as a direct reader")
  Assert.equal(assert(err).code, "ROMFS_BAD_SOURCE")
end

return { tests = T }
