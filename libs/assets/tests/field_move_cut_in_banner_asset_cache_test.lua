-- FieldMoveCutInBannerAssetCache contract: strict paths, the
-- FORMAT:romSha1:depHash marker written last, isReady semantics (marker,
-- persisted manifest, and the indexed banner file), strict rejection of
-- malformed generated metadata, and loadManifest's borrowed validated
-- manifest. The manifest is the single strict structural boundary: the
-- banner key is semantic and the manifest never carries NARC/member ids.
-- The cache is per game version (CacheFs.forVersion), so one banner image
-- per versioned cache; the compiler pins the edition through its source
-- selection instead.

local Assert = require("tests.support.Assert")
local FieldMoveCutInBannerAssetCache = require("libs.assets.src.field.FieldMoveCutInBannerAssetCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

-- The cache's own owned error constant, with the contract literal as the
-- fallback spelling so the suite pins the diagnostic without inventing an
-- export the contract may not name.
local MANIFEST_INVALID = FieldMoveCutInBannerAssetCache.MANIFEST_INVALID or "FIELD_MOVE_CUT_IN_BANNER_MANIFEST_INVALID"

local ASSET_DIR = FieldMoveCutInBannerAssetCache.assetDir()

-- A strict valid manifest: one 256x256 banner image (the retail 32x32 BG3
-- tilemap composed through the sixteen colors the source loads at hardware
-- palette slot 12) referenced by the single semantic banner key.
local function validManifest()
  return {
    schema = FieldMoveCutInBannerAssetCache.SCHEMA,
    reference = { width = 256, height = 256 },
    assets = {
      banner = { image = ASSET_DIR .. "/banner.png", width = 256, height = 256 },
    },
    banner = "banner",
    paletteSlot = 12,
  }
end

local MARKER = "field-move-cut-in-banner-cache-v1:rom-sha:dep-hash"

local function publishedCache(manifest)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldMoveCutInBannerAssetCache.manifestPath(), manifest or validManifest())
  cache:write(FieldMoveCutInBannerAssetCache.markerPath(), MARKER)
  for _, entry in pairs((manifest or validManifest()).assets) do
    cache:write(entry.image, "png")
  end
  return cache
end

function T.contract_constants_flow_from_the_contract_owner()
  Assert.equal(FieldMoveCutInBannerAssetCache.FORMAT, DerivedAssetContract.fieldMoveCutInBanner.cacheFormat)
  Assert.equal(FieldMoveCutInBannerAssetCache.SCHEMA, DerivedAssetContract.fieldMoveCutInBanner.schema)
  Assert.equal(FieldMoveCutInBannerAssetCache.marker("abc", "def"), "field-move-cut-in-banner-cache-v1:abc:def")
  Assert.isTrue(
    FieldMoveCutInBannerAssetCache.manifestPath():match("^data/generated/field/cutin%-banner/") ~= nil,
    "the semantic manifest lives under the cut-in banner data root"
  )
  Assert.equal(FieldMoveCutInBannerAssetCache.assetDir(), "assets/generated/field/cutin-banner")
end

function T.a_valid_manifest_validates_and_reads_ready_after_publication()
  local manifest = validManifest()
  local ok, err = FieldMoveCutInBannerAssetCache.validateManifest(manifest)
  Assert.isTrue(ok, "a strict valid manifest validates: " .. tostring(err))
  local cache = publishedCache(manifest)
  Assert.isTrue(FieldMoveCutInBannerAssetCache.isReady(cache, MARKER))
  Assert.isFalse(FieldMoveCutInBannerAssetCache.isReady(cache, MARKER .. "-stale"), "the marker must match exactly")
end

local function reject(mutate)
  local manifest = validManifest()
  mutate(manifest)
  local ok, err = FieldMoveCutInBannerAssetCache.validateManifest(manifest)
  Assert.isFalse(ok, "the malformed manifest must be rejected")
  Assert.equal(assert(err).code, MANIFEST_INVALID)
end

function T.schema_reference_and_top_level_shape_are_strict()
  reject(function(m)
    m.schema = "g4-field-move-cut-in-banner-v0"
  end)
  reject(function(m)
    m.reference = { width = 256, height = 192 }
  end)
  reject(function(m)
    m.reference = nil
  end)
  reject(function(m)
    m.extra = {}
  end)
end

function T.assets_must_carry_exactly_the_banner_in_root_dimensions()
  reject(function(m)
    m.assets = {}
  end)
  reject(function(m)
    m.assets.banner.width = 0
  end)
  reject(function(m)
    m.assets.banner.height = -1
  end)
  reject(function(m)
    m.assets.banner.width = 1.5
  end)
  reject(function(m)
    m.assets.banner.width = math.huge
  end)
  reject(function(m)
    m.assets.banner.image = "assets/generated/field/other/banner.png"
  end)
  reject(function(m)
    m.assets.banner.image = "assets/generated/field/cutin-banner/../cutin-banner/banner.png"
  end)
  reject(function(m)
    m.assets.banner.image = ""
  end)
  reject(function(m)
    m.assets.orphan = { image = ASSET_DIR .. "/orphan.png", width = 8, height = 8 }
  end)
end

function T.banner_key_must_reference_the_indexed_banner()
  reject(function(m)
    m.banner = "missing"
  end)
  reject(function(m)
    m.banner = nil
  end)
end

function T.palette_slot_pins_the_retail_hardware_slot()
  reject(function(m)
    m.paletteSlot = 0
  end)
  reject(function(m)
    m.paletteSlot = nil
  end)
end

function T.readiness_requires_the_marker_manifest_and_the_banner_file()
  local cache = publishedCache()
  Assert.isTrue(FieldMoveCutInBannerAssetCache.isReady(cache, MARKER))
  cache:remove(FieldMoveCutInBannerAssetCache.markerPath())
  Assert.isFalse(FieldMoveCutInBannerAssetCache.isReady(cache, MARKER), "an absent marker is not ready")
  local missingFile = publishedCache()
  missingFile:remove(ASSET_DIR .. "/banner.png")
  Assert.isFalse(FieldMoveCutInBannerAssetCache.isReady(missingFile, MARKER), "a missing banner file is not ready")
  local wrongSchema = validManifest()
  wrongSchema.schema = "g4-field-move-cut-in-banner-v0"
  Assert.isFalse(
    FieldMoveCutInBannerAssetCache.isReady(publishedCache(wrongSchema), MARKER),
    "a wrong schema is not ready"
  )
end

function T.load_manifest_returns_the_validated_borrowed_manifest()
  local cache = publishedCache()
  local manifest = FieldMoveCutInBannerAssetCache.loadManifest(cache)
  Assert.equal(manifest.schema, FieldMoveCutInBannerAssetCache.SCHEMA)
  Assert.equal(manifest.banner, "banner")
  Assert.equal(manifest.paletteSlot, 12)
  Assert.isTrue(
    FieldMoveCutInBannerAssetCache.validateManifest(manifest),
    "loadManifest returns a manifest that still validates"
  )
end

function T.load_manifest_raises_for_an_absent_or_invalid_manifest()
  Assert.throws(function()
    FieldMoveCutInBannerAssetCache.loadManifest(CacheFs.forVersion("heartgold", FakeCache.new()))
  end)
  local invalid = validManifest()
  invalid.schema = "g4-field-move-cut-in-banner-v0"
  Assert.throws(function()
    FieldMoveCutInBannerAssetCache.loadManifest(publishedCache(invalid))
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
  local ok, err = pcall(FieldMoveCutInBannerAssetCache.validateManifest, manifest)
  Assert.isFalse(ok, "an unrelated access failure is not a success")
  Assert.isTrue(err == sentinel, "the unrelated failure escapes unchanged")
end

return { tests = T }
