-- ROM conformance for the shared move-icons family: every semantic type and
-- damage-category key realizes one image, and the published family stages,
-- reads back, and reports ready through the cache writer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MoveIconAssetCompiler = require("romdump.src.digest.ui.MoveIconAssetCompiler")
local MoveIconAssetSchema = require("libs.assets.src.MoveIconAssetSchema")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local MoveIconCacheWriter = require("romdump.src.digest.ui.MoveIconCacheWriter")
local MoveIconSources = require("romdump.src.config.MoveIconSources")
local MonSources = require("romdump.src.config.MonSources")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Lz10 = require("romdump.src.digest.Lz10")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}
local bundles = {}

local function compile(romFs)
  local versionId = romFs:version()
  if bundles[versionId] == nil then
    bundles[versionId] = assert(MoveIconAssetCompiler.compile(romFs))
  end
  return bundles[versionId]
end

function T.every_type_and_category_realizes_one_image(romFs)
  local bundle = compile(romFs)
  MoveIconAssetSchema.assertManifest(bundle.manifest)
  for _, key in ipairs(MoveIconCache.TYPE_KEYS) do
    local visual = bundle.manifest.types[key]
    Assert.notNil(visual, "the family carries the " .. key .. " type icon")
    Assert.notNil(bundle.assets[visual.image], "the " .. key .. " type icon carries its image")
  end
  for _, key in ipairs(MoveIconCache.CATEGORY_KEYS) do
    Assert.notNil(bundle.manifest.categories[key], "the family carries the " .. key .. " category icon")
  end
  local distinct = {}
  for _, visual in pairs(bundle.manifest.types) do
    distinct[bundle.assets[visual.image]] = true
  end
  local count = 0
  for _ in pairs(distinct) do
    count = count + 1
  end
  Assert.equal(count, #MoveIconCache.TYPE_KEYS, "each type icon draws distinct art")
end

function T.published_family_reads_back_ready(romFs)
  local bundle = compile(romFs)
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion(romFs:version(), backend)
  Assert.isFalse(MoveIconCache.isReady(cache, bundle.marker), "an empty cache is not ready")
  MoveIconCacheWriter.write(cache, bundle)
  Assert.isTrue(MoveIconCache.isReady(cache, bundle.marker), "the published family is ready")
  local manifest = MoveIconCache.loadManifest(cache)
  Assert.deepEqual(manifest, bundle.manifest, "the manifest reads back unchanged")
  local missing = MoveIconCache.referencedPaths(manifest)[1]
  backend:remove(romFs:version() .. "/" .. missing)
  Assert.isFalse(MoveIconCache.isReady(cache, bundle.marker), "a missing image breaks readiness")
end

-- Raw NARC members carry their transport wrapper: normalize LZ10 exactly as
-- the producer member reader does before handing bytes to the plain G2D
-- decoder. Uncompressed members pass through unchanged.
local function plainMember(bytes)
  if string.byte(bytes, 1) ~= 0x10 then
    return bytes
  end
  return assert(Lz10.decode(bytes))
end

function T.archive_sources_decode_for_every_semantic_key(romFs)
  local archive = assert(romFs:openNarc(MoveIconSources.archive.symbol))
  local function assertDecodes(kind, memberId)
    local bytes = assert(archive:readMember(memberId), "member " .. memberId .. " must exist")
    local record, err = G2dDecoder[kind](plainMember(bytes), { label = "move icon member " .. memberId })
    Assert.notNil(record, "member " .. memberId .. " must decode: " .. (err and err.message or "?"))
  end
  assertDecodes("decodePalette", MoveIconSources.shared.palette)
  assertDecodes("decodeCell", MoveIconSources.shared.cell)
  assertDecodes("decodeAnimation", MoveIconSources.shared.animation)
  for typeId = 0, 17 do
    Assert.notNil(MonSources.typeKeys[typeId], "type " .. typeId .. " keeps its semantic key")
    assertDecodes("decodeChar", assert(MoveIconSources.typeChars[typeId]))
  end
  for categoryId = 0, 2 do
    Assert.notNil(MonSources.damageCategories[categoryId], "category " .. categoryId .. " keeps its semantic key")
    assertDecodes("decodeChar", assert(MoveIconSources.categoryChars[categoryId]))
  end
end

-- The source members enter the cache marker in semantic id order: shared
-- palette/cell/animation first, then type members 0..17, then category
-- members 0..2, never in Lua table traversal order.
function T.marker_dependencies_follow_semantic_id_order(romFs)
  local facts = MoveIconSources
  local expected = {
    "move-icons:member:" .. facts.shared.palette,
    "move-icons:member:" .. facts.shared.cell,
    "move-icons:member:" .. facts.shared.animation,
  }
  for typeId = 0, 17 do
    expected[#expected + 1] = "move-icons:member:" .. facts.typeChars[typeId]
  end
  for categoryId = 0, 2 do
    expected[#expected + 1] = "move-icons:member:" .. facts.categoryChars[categoryId]
  end
  local actual = {}
  for _, dependency in ipairs(compile(romFs).provenance.dependencies) do
    if dependency.name:find("move-icons:member:", 1, true) == 1 then
      actual[#actual + 1] = dependency.name
    end
  end
  Assert.deepEqual(actual, expected, "dependencies follow shared, type id, then category id order")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "rom_source" }
return suite
