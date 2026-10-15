-- FieldEntryAssetCache contract: strict paths, the
-- FORMAT:romSha1:depHash marker written last, isReady semantics (marker,
-- persisted manifest, every indexed file, and referential closure), strict
-- rejection of malformed generated metadata, and loadManifest's borrowed
-- validated manifest. Asset keys are semantic; the cache validates
-- referential integrity and file closure, never source archive or member
-- identities.

local Assert = require("tests.support.Assert")
local FieldEntryAssetCache = require("libs.assets.src.field.FieldEntryAssetCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldEntryFixture = require("tests.support.FieldEntryFixture")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")

local T = {}

-- The cache's own owned error constant, with the contract literal as the
-- fallback spelling so the suite pins the diagnostic without inventing an
-- export the contract may not name.
local MANIFEST_INVALID = FieldEntryAssetCache.MANIFEST_INVALID or "FIELD_ENTRY_MANIFEST_INVALID"

local ASSET_DIR = FieldEntryAssetCache.assetDir()

-- Deterministic preview key per distinct source triple base: the 25
-- destinations collapse onto the 76 unique preview images the producer
-- emits, so a reused triple shares one semantic key and one PNG.
local function previewKeyByBase()
  local index = {}
  for position, base in ipairs(FieldEntryFixture.uniqueBases()) do
    index[base] = position - 1
  end
  return index
end

local function color(r, g, b)
  return { r = r, g = g, b = b }
end

-- A strict valid manifest: nine footer-banner skins (136x32) with their
-- decoded text palette roles, every native map header carrying an area icon
-- keyed to its style, and the 25 destination map ids carrying four
-- source-backed preview slots each (deduped to 76 unique 256x192 images).
local function validManifest()
  local index = previewKeyByBase()
  local assets = {}
  local bannerStyles = {}
  local bannerTextPalettes = {}
  for style = 0, FieldEntryFixture.BANNER_STYLE_COUNT - 1 do
    assets["banner/" .. style] = {
      image = ASSET_DIR .. "/banner-" .. style .. ".png",
      width = 136,
      height = 32,
    }
    bannerStyles[style] = "banner/" .. style
    bannerTextPalettes[style] = {
      foreground = color(style * 16 + 31, 0, 0),
      shadow = color(0, style * 16 + 31, 0),
      background = color(0, 0, style * 16 + 31),
    }
  end

  local previewByMapId = {}
  for _, destination in ipairs(FieldEntryFixture.DESTINATIONS) do
    local mapId = assert(MapCatalog.idForSymbol(destination.symbol), destination.symbol)
    local slots = {}
    for slot = 0, 3 do
      local key = "preview/" .. index[assert(destination.bases[slot + 1])]
      slots[slot] = key
      assets[key] = { image = ASSET_DIR .. "/" .. key:gsub("/", "-") .. ".png", width = 256, height = 192 }
    end
    previewByMapId[mapId] = slots
  end

  local bannerStyleByMapId = {}
  local maps = require("romdump.src.reference.hgss.maps").byId
  for id = 0, 539 do
    local record = maps[id]
    local areaIcon = record and record.areaIcon
    if type(areaIcon) == "number" and areaIcon >= 1 and areaIcon <= FieldEntryFixture.BANNER_STYLE_COUNT then
      bannerStyleByMapId[id] = areaIcon - 1
    end
  end

  return {
    schema = FieldEntryAssetCache.SCHEMA,
    reference = { width = 256, height = 192 },
    assets = assets,
    bannerStyles = bannerStyles,
    bannerTextPalettes = bannerTextPalettes,
    bannerStyleByMapId = bannerStyleByMapId,
    previewByMapId = previewByMapId,
  }
end

local MARKER = "field-entry-cache-v1:rom-sha:dep-hash"

local function publishedCache(manifest)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldEntryAssetCache.manifestPath(), manifest or validManifest())
  cache:write(FieldEntryAssetCache.markerPath(), MARKER)
  for _, entry in pairs((manifest or validManifest()).assets) do
    cache:write(entry.image, "png")
  end
  return cache
end

local function firstPreviewMapId(manifest)
  local mapId = next(manifest.previewByMapId)
  return assert(mapId, "the valid manifest carries at least one preview destination")
end

local function firstBannerMapId(manifest)
  local mapId = next(manifest.bannerStyleByMapId)
  return assert(mapId, "the valid manifest carries at least one banner style")
end

function T.contract_constants_flow_from_the_contract_owner()
  Assert.equal(FieldEntryAssetCache.FORMAT, DerivedAssetContract.fieldEntry.cacheFormat)
  Assert.equal(FieldEntryAssetCache.SCHEMA, DerivedAssetContract.fieldEntry.schema)
  Assert.equal(FieldEntryAssetCache.marker("abc", "def"), "field-entry-cache-v1:abc:def")
  Assert.isTrue(
    FieldEntryAssetCache.manifestPath():match("^data/generated/field/entry/") ~= nil,
    "the semantic manifest lives under the field-entry data root"
  )
  Assert.equal(FieldEntryAssetCache.assetDir(), "assets/generated/field/entry")
end

function T.a_valid_manifest_validates_and_reads_ready_after_publication()
  local manifest = validManifest()
  local ok, err = FieldEntryAssetCache.validateManifest(manifest)
  Assert.isTrue(ok, "a strict valid manifest validates: " .. tostring(err))
  local cache = publishedCache(manifest)
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, MARKER))
  Assert.isFalse(FieldEntryAssetCache.isReady(cache, MARKER .. "-stale"), "the marker must match exactly")
end

local function reject(mutate)
  local manifest = validManifest()
  mutate(manifest)
  local ok, err = FieldEntryAssetCache.validateManifest(manifest)
  Assert.isFalse(ok, "the malformed manifest must be rejected")
  Assert.equal(assert(err).code, MANIFEST_INVALID)
end

function T.schema_reference_and_top_level_shape_are_strict()
  reject(function(m)
    m.schema = "g4-field-entry-v0"
  end)
  reject(function(m)
    m.reference = { width = 320, height = 240 }
  end)
  reject(function(m)
    m.reference = nil
  end)
  reject(function(m)
    m.extra = {}
  end)
end

function T.assets_must_be_non_empty_with_finite_in_root_dimensions()
  reject(function(m)
    m.assets = {}
  end)
  reject(function(m)
    m.assets["banner/0"].width = 0
  end)
  reject(function(m)
    m.assets["banner/0"].height = -1
  end)
  reject(function(m)
    m.assets["banner/0"].width = 1.5
  end)
  reject(function(m)
    m.assets["banner/0"].width = math.huge
  end)
  reject(function(m)
    m.assets["banner/0"].image = "assets/generated/field/other/banner-0.png"
  end)
  reject(function(m)
    m.assets["banner/0"].image = "assets/generated/field/entry/../entry/banner-0.png"
  end)
  reject(function(m)
    m.assets["banner/0"].image = ""
  end)
end

function T.references_must_be_dangling_free_and_closed()
  reject(function(m)
    m.bannerStyles[3] = "banner/missing"
  end)
  reject(function(m)
    m.assets["preview/orphan"] = { image = ASSET_DIR .. "/preview-orphan.png", width = 256, height = 192 }
  end)
  reject(function(m)
    local mapId = firstPreviewMapId(m)
    m.previewByMapId[mapId][0] = "preview/missing"
  end)
end

function T.banner_styles_and_text_palettes_require_all_nine_indices()
  reject(function(m)
    m.bannerStyles[8] = nil
  end)
  reject(function(m)
    m.bannerStyles[0] = nil
  end)
  reject(function(m)
    m.bannerTextPalettes[8] = nil
  end)
  reject(function(m)
    m.bannerTextPalettes[0].shadow = nil
  end)
  reject(function(m)
    m.bannerTextPalettes[0].foreground.r = 256
  end)
  reject(function(m)
    m.bannerTextPalettes[0].background.g = -1
  end)
end

function T.banner_style_by_map_id_must_name_a_real_banner_style()
  reject(function(m)
    m.bannerStyleByMapId[firstBannerMapId(m)] = 9
  end)
  reject(function(m)
    m.bannerStyleByMapId[firstBannerMapId(m)] = -1
  end)
end

function T.preview_destinations_require_four_source_backed_slots()
  reject(function(m)
    local mapId = firstPreviewMapId(m)
    m.previewByMapId[mapId][3] = nil
  end)
  reject(function(m)
    m.previewByMapId = {}
  end)
end

function T.readiness_requires_the_marker_manifest_and_every_indexed_file()
  local cache = publishedCache()
  Assert.isTrue(FieldEntryAssetCache.isReady(cache, MARKER))
  cache:remove(FieldEntryAssetCache.markerPath())
  Assert.isFalse(FieldEntryAssetCache.isReady(cache, MARKER), "an absent marker is not ready")
  local missingFile = publishedCache()
  missingFile:remove(ASSET_DIR .. "/banner-0.png")
  Assert.isFalse(FieldEntryAssetCache.isReady(missingFile, MARKER), "a missing indexed file is not ready")
  local wrongSchema = validManifest()
  wrongSchema.schema = "g4-field-entry-v0"
  Assert.isFalse(FieldEntryAssetCache.isReady(publishedCache(wrongSchema), MARKER), "a wrong schema is not ready")
end

function T.load_manifest_returns_the_validated_borrowed_manifest()
  local cache = publishedCache()
  local manifest = FieldEntryAssetCache.loadManifest(cache)
  Assert.equal(manifest.schema, FieldEntryAssetCache.SCHEMA)
  Assert.equal(#FieldEntryFixture.uniqueBases(), 76)
  Assert.isTrue(
    FieldEntryAssetCache.validateManifest(manifest),
    "loadManifest returns a manifest that still validates"
  )
end

function T.load_manifest_raises_for_an_absent_or_invalid_manifest()
  Assert.throws(function()
    FieldEntryAssetCache.loadManifest(CacheFs.forVersion("heartgold", FakeCache.new()))
  end)
  local invalid = validManifest()
  invalid.schema = "g4-field-entry-v0"
  Assert.throws(function()
    FieldEntryAssetCache.loadManifest(publishedCache(invalid))
  end)
end

-- An unrelated failure during validation is not reported as invalid data:
-- the sentinel raised by a test-local accessor escapes unchanged.
function T.unrelated_access_failure_escapes_without_invalid_manifest_substitution()
  local sentinel = {}
  local manifest = setmetatable({}, {
    __index = function()
      error(sentinel, 0)
    end,
  })
  local ok, err = pcall(FieldEntryAssetCache.validateManifest, manifest)
  Assert.isFalse(ok, "an unrelated access failure is not a success")
  Assert.isTrue(err == sentinel, "the unrelated failure escapes unchanged")
end

return { tests = T }
