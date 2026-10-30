-- Readiness, paths, and strict validation for the generated HGSS
-- field-move cut-in banner class: one manifest (`banner.lua`) carrying the
-- single semantic banner key with its 256x256 BG3 surface and the hardware
-- palette slot the composition was built against; the binary PNG asset
-- under the banner asset root; and a completion marker written last with
-- the ROM SHA-1 and producer dependency hash. The manifest is the single
-- mod-facing contract: the banner key is semantic and the manifest never
-- carries NARC/member ids. The cache is per game version, so one banner
-- image per versioned cache; the compiler pins the edition through its
-- source selection instead. A class is ready only when the marker matches
-- exactly, the persisted manifest still satisfies the consumer-safe
-- contract, and the indexed file exists. Paths are cache-relative; all IO
-- goes through a CacheFs.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")
local Validate = require("libs.assets.src.Validate")

local FieldMoveCutInBannerAssetCache = {}

---@class FieldMoveCutInBannerAssetCache.Asset
---@field image string
---@field width integer
---@field height integer

---@class FieldMoveCutInBannerAssetCache.Manifest
---@field schema string
---@field reference { width: integer, height: integer }
---@field assets table<string, FieldMoveCutInBannerAssetCache.Asset>
---@field banner string
---@field paletteSlot integer

FieldMoveCutInBannerAssetCache.FORMAT = Contract.fieldMoveCutInBanner.cacheFormat
FieldMoveCutInBannerAssetCache.SCHEMA = Contract.fieldMoveCutInBanner.schema

-- The BG3 tilemap the retail rewrite covers: a 32x32-tile (256x256-pixel)
-- surface. The producer and the validator consume this geometry from the
-- contract owner.
FieldMoveCutInBannerAssetCache.BANNER_WIDTH = 256
FieldMoveCutInBannerAssetCache.BANNER_HEIGHT = 256
-- The hardware BG palette slot the retail loader places the banner colors
-- at; the generated PNG bakes those sixteen colors.
FieldMoveCutInBannerAssetCache.PALETTE_SLOT = 12

-- One error code for every malformed generated class: the manifest is the
-- single strict structural boundary, so all violations share the code while
-- the message names the exact broken field.
FieldMoveCutInBannerAssetCache.MANIFEST_INVALID = "FIELD_MOVE_CUT_IN_BANNER_MANIFEST_INVALID"
local MANIFEST_INVALID = FieldMoveCutInBannerAssetCache.MANIFEST_INVALID

local DATA_DIR = "data/generated/field/cutin-banner"
local ASSET_DIR = "assets/generated/field/cutin-banner"
local ASSET_PREFIX = ASSET_DIR .. "/"

local TOP_LEVEL_FIELDS = {
  schema = true,
  reference = true,
  assets = true,
  banner = true,
  paletteSlot = true,
}

---@param message string
---@param context Errors.Context?
---@noreturn
local function reject(message, context)
  Errors.raise(MANIFEST_INVALID, message, context)
end

local function isPositiveInteger(value)
  return Validate.isNonNegativeInteger(value) and value >= 1
end

-- Strict manifest validation: the exact top-level field set, the 256x256
-- reference, exactly the semantic banner asset with finite, integral, and
-- positive dimensions confined to the banner asset root, the banner key
-- resolving to that asset, and the retail hardware palette slot. Private
-- checks reject malformed data through one owned error;
-- validateManifest is the only boundary that translates it into the public
-- false-plus-error result, so unrelated failures still propagate to the
-- caller. Validation never mutates the manifest.
function FieldMoveCutInBannerAssetCache.dir()
  return DATA_DIR
end

function FieldMoveCutInBannerAssetCache.assetDir()
  return ASSET_DIR
end

function FieldMoveCutInBannerAssetCache.manifestPath()
  return DATA_DIR .. "/banner.lua"
end

function FieldMoveCutInBannerAssetCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function FieldMoveCutInBannerAssetCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param romSha1 string
---@param depHash string
---@return string
function FieldMoveCutInBannerAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldMoveCutInBannerAssetCache.FORMAT, romSha1, depHash)
end

local function checkManifest(manifest)
  if type(manifest) ~= "table" then
    reject("manifest is not a table", {})
  end
  for key in pairs(manifest) do
    if not TOP_LEVEL_FIELDS[key] then
      reject("manifest has an unknown top-level field", { field = key })
    end
  end
  if manifest.schema ~= FieldMoveCutInBannerAssetCache.SCHEMA then
    reject("manifest schema mismatch", {
      schema = manifest.schema,
      expected = FieldMoveCutInBannerAssetCache.SCHEMA,
    })
  end
  local reference = manifest.reference
  if
    type(reference) ~= "table"
    or reference.width ~= FieldMoveCutInBannerAssetCache.BANNER_WIDTH
    or reference.height ~= FieldMoveCutInBannerAssetCache.BANNER_HEIGHT
  then
    reject("manifest reference must be the 256x256 banner surface", { reference = reference })
  end
  local assets = manifest.assets
  if type(assets) ~= "table" then
    reject("manifest assets must be a table", {})
  end
  local count = 0
  for key, entry in pairs(assets) do
    count = count + 1
    if key ~= "banner" then
      reject("manifest assets carry only the semantic banner", { key = key })
    end
    if type(entry) ~= "table" or type(entry.image) ~= "string" or entry.image == "" then
      reject("the banner must name an image path", { key = key })
    end
    local image = entry.image
    if image:find("..", 1, true) ~= nil or image:sub(1, #ASSET_PREFIX) ~= ASSET_PREFIX then
      reject("the banner image must stay under the banner root", { key = key, image = image })
    end
    if not isPositiveInteger(entry.width) or not isPositiveInteger(entry.height) then
      reject("the banner needs positive integral dimensions", { key = key })
    end
  end
  if count ~= 1 then
    reject("manifest assets must carry exactly the banner", { count = count })
  end
  if manifest.banner ~= "banner" then
    reject("manifest banner must reference the indexed banner", { banner = manifest.banner })
  end
  if manifest.paletteSlot ~= FieldMoveCutInBannerAssetCache.PALETTE_SLOT then
    reject("manifest paletteSlot must be the retail hardware slot", { paletteSlot = manifest.paletteSlot })
  end
end

---@param manifest table<string, unknown>
---@return boolean, Errors.Error?
function FieldMoveCutInBannerAssetCache.validateManifest(manifest)
  local ok, result = pcall(checkManifest, manifest)
  if ok then
    return true
  end
  if Errors.is(result) then
    ---@cast result Errors.Error
    if result.code == MANIFEST_INVALID then
      return false, result
    end
  end
  error(result, 0)
end

-- Every generated file the manifest indexes must exist for the class to be
-- ready. The marker must also match exactly and the persisted manifest must
-- still satisfy the current consumer-safe contract: publication proved the
-- staged bytes, not that the live files remain intact, so readiness
-- revalidates the persisted structure before checking file closure.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function FieldMoveCutInBannerAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldMoveCutInBannerAssetCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(FieldMoveCutInBannerAssetCache.manifestPath())
  if type(manifest) ~= "table" then
    return false
  end
  local valid = FieldMoveCutInBannerAssetCache.validateManifest(manifest)
  if not valid then
    return false
  end
  for _, entry in pairs(manifest.assets) do
    if not cacheFs:exists(entry.image, "file") then
      return false
    end
  end
  return true
end

-- The validated manifest, borrowed immutable: callers must not mutate it.
---@param cacheFs CacheFs
---@return FieldMoveCutInBannerAssetCache.Manifest
function FieldMoveCutInBannerAssetCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(FieldMoveCutInBannerAssetCache.manifestPath())
  assert(type(manifest) == "table", "the cut-in banner manifest is unavailable")
  local ok, err = FieldMoveCutInBannerAssetCache.validateManifest(manifest)
  if not ok then
    error(err, 0)
  end
  ---@cast manifest FieldMoveCutInBannerAssetCache.Manifest
  return manifest
end

return FieldMoveCutInBannerAssetCache
