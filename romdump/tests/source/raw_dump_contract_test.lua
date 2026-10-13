-- Raw-dump contract: the extractor (writer) produces its identity files
-- through the shared RawDumpContract module, and readiness follows the
-- strict source binding recorded at import. A contract path/schema change
-- breaks one authoritative constant here, not duplicated test literals.

local Assert = require("tests.support.Assert")
local RawDumpContract = require("romdump.src.source.RawDumpContract")
local RomImporter = require("romdump.src.source.RomImporter")
local RomExtractor = require("romdump.src.source.RomExtractor")
local DumpFixture = require("tests.support.DumpFixture")

local T = {}

local HG = "heartgold/"

local function extract()
  local r = DumpFixture.extract()
  Assert.notNil(r.report, "fixture extraction failed: " .. tostring(r.err))
  return r
end

-- Every generated identity file the writer produces lands at exactly the path
-- the shared contract names.
function T.writer_writes_identity_files_at_contract_paths()
  local r = extract()
  Assert.notNil(r.backend.files[HG .. RawDumpContract.METADATA_PATH], "metadata at the contract path")
  Assert.notNil(r.backend.files[HG .. RawDumpContract.ROMFS_INDEX_PATH], "romfs index at the contract path")
  Assert.notNil(r.backend.files[HG .. RawDumpContract.OVERLAY_INDEX_PATH], "overlay index at the contract path")
  Assert.notNil(r.backend.files[HG .. RawDumpContract.MARKER_PATH], "completion marker at the contract path")
end

-- The written schema identifiers are exactly the contract's, and the marker
-- content still names the extractor's cache format, so writer and readers
-- share one schema source.
function T.writer_writes_contract_schemas_and_marker()
  local r = extract()
  local metadata = assert(r.cache:loadLua(RawDumpContract.METADATA_PATH))
  local index = assert(r.cache:loadLua(RawDumpContract.ROMFS_INDEX_PATH))
  local overlayIndex = assert(r.cache:loadLua(RawDumpContract.OVERLAY_INDEX_PATH))
  Assert.equal(metadata.schema, RawDumpContract.METADATA_SCHEMA)
  Assert.equal(index.schema, RawDumpContract.ROMFS_INDEX_SCHEMA)
  Assert.equal(overlayIndex.schema, RawDumpContract.OVERLAY_INDEX_SCHEMA)
  Assert.equal(
    r.backend.files[HG .. RawDumpContract.MARKER_PATH],
    RomExtractor.markerContent(r.versionId, r.report.sha1)
  )
end

-- Readiness follows the strict source binding recorded at import: a missing
-- or misshapen record is not ready, while a recorded binding is ready
-- without opening the ROM, so a moved source never blocks reuse.
function T.readiness_follows_the_strict_source_binding()
  local RomBinding = require("romdump.src.source.RomBinding")
  local NdsBuilder = require("tests.support.NdsBuilder")
  local RomSource = require("romdump.src.source.RomSource")
  local NdsRom = require("romdump.src.source.NdsRom")
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local data = NdsBuilder.build(DumpFixture.spec())
  local sha1 = RomSource.fromString(data):sha1()
  local info = { id = "heartgold", sha1 = sha1, gameCode = "IPKE", expectedSize = #data }
  local versions = {
    info = function(id)
      return id == "heartgold" and info or nil
    end,
    forSha1 = function(h)
      return h == sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == "IPKE" and info or nil
    end,
  }
  local rom = assert(NdsRom.open(RomSource.fromString(data), versions))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.isFalse(RomImporter.isReady("heartgold", cache, versions), "a missing binding is not ready")
  Assert.isTrue(
    RomBinding.record(cache, rom, {
      kind = "nds",
      path = false,
      displayName = "synthetic.nds",
      zipEntry = false,
    }, versions),
    "the binding records without extracting"
  )
  Assert.isTrue(
    RomImporter.isReady("heartgold", cache, versions),
    "a recorded binding is ready without opening the ROM"
  )
  cache:writeLua("rom-source.lua", { schema = 1, versionId = "heartgold" })
  Assert.isFalse(RomImporter.isReady("heartgold", cache, versions), "a misshapen binding is not ready")
end

return { tests = T }
