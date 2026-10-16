-- Readiness, paths, and strict validation for the generated HGSS field-entry
-- class: one manifest (`entry.lua`) carrying the nine map-name banner skins
-- with their decoded text-palette roles, the native map-header banner
-- selection, and the 25 selected destinations with their four time-slot
-- preview images; binary assets (PNG) under the entry asset root; and a
-- completion marker written last with the ROM SHA-1 and producer dependency
-- hash. The manifest is the single mod-facing contract: banner and preview
-- keys are semantic and the manifest never carries NARC/member ids. A class
-- is ready only when the marker matches exactly, the persisted manifest
-- still satisfies the consumer-safe contract, and every indexed file exists.
-- Paths are cache-relative; all IO goes through a CacheFs.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")
local Validate = require("libs.assets.src.Validate")

local FieldEntryAssetCache = {}

---@class FieldEntryAssetCache.Asset
---@field image string
---@field width integer
---@field height integer

---@class FieldEntryAssetCache.Color
---@field r integer
---@field g integer
---@field b integer

---@class FieldEntryAssetCache.BannerTextPalette
---@field foreground FieldEntryAssetCache.Color
---@field shadow FieldEntryAssetCache.Color
---@field background FieldEntryAssetCache.Color

---@class FieldEntryAssetCache.Manifest
---@field schema string
---@field reference { width: integer, height: integer }
---@field assets table<string, FieldEntryAssetCache.Asset>
---@field bannerStyles table<integer, string>
---@field bannerTextPalettes table<integer, FieldEntryAssetCache.BannerTextPalette>
---@field bannerStyleByMapId table<integer, integer>
---@field previewByMapId table<integer, table<integer, string>>

FieldEntryAssetCache.FORMAT = Contract.fieldEntry.cacheFormat
FieldEntryAssetCache.SCHEMA = Contract.fieldEntry.schema

-- The banner grid the source composes from its char member: a 17-column by
-- four-row matrix of 8x8 tiles (136x32). The producer and the validator
-- consume this one geometry from the contract owner.
FieldEntryAssetCache.BANNER_WIDTH = 136
FieldEntryAssetCache.BANNER_HEIGHT = 32
FieldEntryAssetCache.BANNER_STYLE_COUNT = 9
FieldEntryAssetCache.PREVIEW_WIDTH = 256
FieldEntryAssetCache.PREVIEW_HEIGHT = 192
FieldEntryAssetCache.PREVIEW_SLOTS = 4

-- One error code for every malformed generated class: the manifest is the
-- single strict structural boundary, so all violations share the code while
-- the message names the exact broken field.
FieldEntryAssetCache.MANIFEST_INVALID = "FIELD_ENTRY_MANIFEST_INVALID"
local MANIFEST_INVALID = FieldEntryAssetCache.MANIFEST_INVALID

local DATA_DIR = "data/generated/field/entry"
local ASSET_DIR = "assets/generated/field/entry"
local ASSET_PREFIX = ASSET_DIR .. "/"

local TOP_LEVEL_FIELDS = {
  schema = true,
  reference = true,
  assets = true,
  bannerStyles = true,
  bannerTextPalettes = true,
  bannerStyleByMapId = true,
  previewByMapId = true,
}

local PALETTE_ROLES = { "foreground", "shadow", "background" }
local RGB_CHANNELS = { "r", "g", "b" }

---@param message string
---@param context Errors.Context?
---@noreturn
local function reject(message, context)
  Errors.raise(MANIFEST_INVALID, message, context)
end

local function isPositiveInteger(value)
  return Validate.isNonNegativeInteger(value) and value >= 1
end

-- Strict manifest validation: the exact top-level field set, the exact
-- asset/banner/preview index shapes, every dimension finite, integral, and
-- positive, every path confined to the entry asset root, and referential
-- closure in both directions. Private checks reject malformed data through
-- one owned error; validateManifest is the only boundary that translates it
-- into the public false-plus-error result, so unrelated failures still
-- propagate to the caller. Validation never mutates the manifest.
function FieldEntryAssetCache.dir()
  return DATA_DIR
end

function FieldEntryAssetCache.assetDir()
  return ASSET_DIR
end

function FieldEntryAssetCache.manifestPath()
  return DATA_DIR .. "/entry.lua"
end

function FieldEntryAssetCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function FieldEntryAssetCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param romSha1 string
---@param depHash string
---@return string
function FieldEntryAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldEntryAssetCache.FORMAT, romSha1, depHash)
end

local function checkAssets(manifest)
  if type(manifest.assets) ~= "table" or next(manifest.assets) == nil then
    reject("manifest assets must be a non-empty table", {})
  end
  local assets = {}
  for key, entry in pairs(manifest.assets) do
    if type(key) ~= "string" or key == "" then
      reject("asset key must be a non-empty string", {})
    end
    if type(entry) ~= "table" or type(entry.image) ~= "string" or entry.image == "" then
      reject("asset " .. key .. " must name an image path", { key = key })
    end
    local image = entry.image
    if image:find("..", 1, true) ~= nil or image:sub(1, #ASSET_PREFIX) ~= ASSET_PREFIX then
      reject("asset " .. key .. " image must stay under the entry root", { key = key, image = image })
    end
    if not isPositiveInteger(entry.width) or not isPositiveInteger(entry.height) then
      reject("asset " .. key .. " needs positive integral dimensions", { key = key })
    end
    assets[key] = { width = entry.width, height = entry.height }
  end
  return assets
end

local function checkBannerStyles(manifest, assets)
  local styles = manifest.bannerStyles
  if type(styles) ~= "table" then
    reject("manifest bannerStyles must be a table", {})
  end
  local referenced = {}
  for style = 0, FieldEntryAssetCache.BANNER_STYLE_COUNT - 1 do
    local key = styles[style]
    if type(key) ~= "string" or assets[key] == nil then
      reject("banner style " .. style .. " must reference an indexed banner", { style = style })
    end
    referenced[key] = true
  end
  for style in pairs(styles) do
    if type(style) ~= "number" or style % 1 ~= 0 or style < 0 or style >= FieldEntryAssetCache.BANNER_STYLE_COUNT then
      reject("bannerStyles has an invalid style index", { style = style })
    end
  end
  return referenced
end

local function checkColor(color, what)
  if type(color) ~= "table" then
    reject(what .. " must be a byte-RGB color", { what = what })
  end
  for _, channel in ipairs(RGB_CHANNELS) do
    local value = color[channel]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 255 then
      reject(what .. " must carry integral byte RGB channels", { what = what, channel = channel })
    end
  end
end

local function checkBannerTextPalettes(manifest)
  local palettes = manifest.bannerTextPalettes
  if type(palettes) ~= "table" then
    reject("manifest bannerTextPalettes must be a table", {})
  end
  for style = 0, FieldEntryAssetCache.BANNER_STYLE_COUNT - 1 do
    local palette = palettes[style]
    if type(palette) ~= "table" then
      reject("banner style " .. style .. " must carry its text palette", { style = style })
    end
    for _, role in ipairs(PALETTE_ROLES) do
      checkColor(palette[role], "banner style " .. style .. " " .. role)
    end
    for role in pairs(palette) do
      if role ~= "foreground" and role ~= "shadow" and role ~= "background" then
        reject("banner style " .. style .. " has an unknown palette role", { style = style, role = role })
      end
    end
  end
  for style in pairs(palettes) do
    if type(style) ~= "number" or style % 1 ~= 0 or style < 0 or style >= FieldEntryAssetCache.BANNER_STYLE_COUNT then
      reject("bannerTextPalettes has an invalid style index", { style = style })
    end
  end
end

local function checkBannerStyleByMapId(manifest, styles)
  local byMapId = manifest.bannerStyleByMapId
  if type(byMapId) ~= "table" then
    reject("manifest bannerStyleByMapId must be a table", {})
  end
  for mapId, style in pairs(byMapId) do
    if not Validate.isNonNegativeInteger(mapId) then
      reject("banner style map keys must be non-negative integers", { mapId = mapId })
    end
    if
      type(style) ~= "number"
      or style % 1 ~= 0
      or style < 0
      or style >= FieldEntryAssetCache.BANNER_STYLE_COUNT
      or styles[style] == nil
    then
      reject("banner style " .. tostring(mapId) .. " must name a real banner", { mapId = mapId, style = style })
    end
  end
end

local function checkPreviewByMapId(manifest, assets, referenced)
  local byMapId = manifest.previewByMapId
  if type(byMapId) ~= "table" or next(byMapId) == nil then
    reject("manifest previewByMapId must be a non-empty table", {})
  end
  for mapId, slots in pairs(byMapId) do
    if not Validate.isNonNegativeInteger(mapId) then
      reject("preview map keys must be non-negative integers", { mapId = mapId })
    end
    if type(slots) ~= "table" then
      reject("preview destination " .. tostring(mapId) .. " must carry its four slots", { mapId = mapId })
    end
    for slot = 0, FieldEntryAssetCache.PREVIEW_SLOTS - 1 do
      local key = slots[slot]
      if type(key) ~= "string" or assets[key] == nil then
        reject(
          "preview destination " .. tostring(mapId) .. " slot " .. slot .. " must reference an indexed image",
          { mapId = mapId, slot = slot }
        )
      end
      referenced[key] = true
    end
    for slot in pairs(slots) do
      if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot >= FieldEntryAssetCache.PREVIEW_SLOTS then
        reject("preview destination " .. tostring(mapId) .. " has an invalid slot", { mapId = mapId, slot = slot })
      end
    end
  end
end

local function checkClosure(assets, referenced)
  for key in pairs(assets) do
    if not referenced[key] then
      reject("every indexed asset must be referenced by the manifest: " .. key, { key = key })
    end
  end
  for key in pairs(referenced) do
    if assets[key] == nil then
      reject("every referenced key must be indexed: " .. key, { key = key })
    end
  end
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
  if manifest.schema ~= FieldEntryAssetCache.SCHEMA then
    reject("manifest schema mismatch", {
      schema = manifest.schema,
      expected = FieldEntryAssetCache.SCHEMA,
    })
  end
  local reference = manifest.reference
  if
    type(reference) ~= "table"
    or reference.width ~= FieldEntryAssetCache.PREVIEW_WIDTH
    or reference.height ~= FieldEntryAssetCache.PREVIEW_HEIGHT
  then
    reject("manifest reference must be the 256x192 field screen", { reference = reference })
  end
  local assets = checkAssets(manifest)
  local referenced = checkBannerStyles(manifest, assets)
  checkBannerTextPalettes(manifest)
  checkBannerStyleByMapId(manifest, manifest.bannerStyles)
  checkPreviewByMapId(manifest, assets, referenced)
  checkClosure(assets, referenced)
end

---@param manifest table<string, unknown>
---@return boolean, Errors.Error?
function FieldEntryAssetCache.validateManifest(manifest)
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
function FieldEntryAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldEntryAssetCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(FieldEntryAssetCache.manifestPath())
  if type(manifest) ~= "table" then
    return false
  end
  local valid = FieldEntryAssetCache.validateManifest(manifest)
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
---@return FieldEntryAssetCache.Manifest
function FieldEntryAssetCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(FieldEntryAssetCache.manifestPath())
  assert(type(manifest) == "table", "the field-entry manifest is unavailable")
  local ok, err = FieldEntryAssetCache.validateManifest(manifest)
  if not ok then
    error(err, 0)
  end
  ---@cast manifest FieldEntryAssetCache.Manifest
  return manifest
end

return FieldEntryAssetCache
