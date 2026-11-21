-- Persists a compiled item bundle through the shared staged publication
-- primitive: the catalog, index, icon manifest and atlas, and provenance
-- are written into a disposable staging root, read back and validated there
-- (schemas, the icon-pixel identity, and catalog-to-manifest icon resolution),
-- and only then is the completed stage published over the live item roots with
-- the marker last. The icon atlas reaches the stage either encoded here or
-- deferred to the owning job's low-priority PNG continuation. A failure at any
-- point leaves the previous live class untouched; the stage is discarded. The
-- raw ROM dump and any other derived class are never touched.

local Errors = require("libs.errors.src.Errors")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local Hashing = require("romdump.src.digest.Hashing")

---@class ItemCacheWriter
local ItemCacheWriter = {}

function ItemCacheWriter.isReady(cacheFs, marker)
  return ItemCache.isReady(cacheFs, marker)
end

local function fail(code, message, context)
  Errors.raise(code, message, context or {})
end

local function checkImage(image, context, code, field)
  if type(image) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  if type(image.width) ~= "number" or image.width % 1 ~= 0 or image.width <= 0 then
    fail(code, field .. " width must be positive", context)
  end
  if type(image.height) ~= "number" or image.height % 1 ~= 0 or image.height <= 0 then
    fail(code, field .. " height must be positive", context)
  end
  if type(image.pixels) ~= "string" or #image.pixels ~= image.width * image.height * 4 then
    fail(code, field .. " pixels must be width*height*4 bytes", context)
  end
end

local function checkRectsInBounds(manifest, image, context, code, field)
  for selector, entry in pairs(manifest.entries) do
    if entry.x + entry.width > image.width or entry.y + entry.height > image.height then
      fail(code, field .. " entry " .. selector .. " escapes the atlas", context)
    end
  end
end

local function checkBundle(bundle)
  if type(bundle) ~= "table" then
    fail("ITEM_WRITER_BAD_BUNDLE", "item bundle must be a record", {})
  end
  if type(bundle.marker) ~= "string" or bundle.marker == "" then
    fail("ITEM_WRITER_BAD_BUNDLE", "item bundle marker must be a non-empty string", {})
  end
  for _, field in ipairs({ "index", "catalog", "icons", "iconManifest", "provenance" }) do
    if type(bundle[field]) ~= "table" then
      fail("ITEM_WRITER_BAD_BUNDLE", "item bundle field " .. field .. " must be a record", {})
    end
  end
  ItemAssetSchema.assertCatalog(bundle.catalog)
  ItemAssetSchema.assertIndex(bundle.index)
  ItemAssetSchema.assertIconManifest(bundle.iconManifest)
  ItemAssetSchema.assertCatalogIcons(bundle.catalog, bundle.iconManifest)
  if bundle.index.catalog ~= ItemCache.catalogPath() then
    fail("ITEM_WRITER_BAD_INDEX", "index catalog path does not match ItemCache", {})
  end
  if bundle.index.icons ~= ItemCache.iconImagePath() or bundle.index.iconManifest ~= ItemCache.iconManifestPath() then
    fail("ITEM_WRITER_BAD_INDEX", "index icon paths do not match ItemCache", {})
  end
  if bundle.index.catalogHash ~= Hashing.hashLua(bundle.catalog) then
    fail("ITEM_WRITER_HASH_MISMATCH", "index catalog hash does not match the catalog", {})
  end
  checkImage(bundle.icons, {}, "ITEM_WRITER_BAD_IMAGE", "icons")
  if Hashing.sha1hex(bundle.icons.pixels) ~= bundle.index.iconHash then
    fail("ITEM_WRITER_HASH_MISMATCH", "index icon hash does not match the atlas pixels", {})
  end
  checkRectsInBounds(bundle.iconManifest, bundle.icons, {}, "ITEM_WRITER_RECT_OUT_OF_BOUNDS", "icon")
end

-- The icon atlas reaches the stage either encoded here (a direct write) or
-- deferred to the owning job's low-priority continuation. Everything else is
-- small Lua and marker data, so only the image write differs between paths.
local function persist(stage, bundle, writeIcon)
  stage:writeLua(ItemCache.catalogPath(), bundle.catalog)
  stage:writeLua(ItemCache.indexPath(), bundle.index)
  stage:writeLua(ItemCache.iconManifestPath(), bundle.iconManifest)
  writeIcon()
  stage:writeLua(ItemCache.provenancePath(), bundle.provenance)

  local catalog = stage:loadLua(ItemCache.catalogPath())
  ItemAssetSchema.assertCatalog(catalog)
  local index = stage:loadLua(ItemCache.indexPath())
  ItemAssetSchema.assertIndex(index)
  local iconManifest = stage:loadLua(ItemCache.iconManifestPath())
  ItemAssetSchema.assertIconManifest(iconManifest)
  ItemAssetSchema.assertCatalogIcons(catalog, iconManifest)

  stage:write(ItemCache.markerPath(), bundle.marker)
  return bundle.marker
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function ItemCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.write, "item staging requires a PreparedArtifact")
  checkBundle(bundle)
  artifact:addOwnedRoot(ItemCache.assetDir())
  artifact:addOwnedRoot(ItemCache.dir())
  local icons = bundle.icons
  return persist(artifact, bundle, function()
    artifact:deferImage(ItemCache.iconImagePath(), icons.width, icons.height, icons.pixels)
  end)
end

return ItemCacheWriter
