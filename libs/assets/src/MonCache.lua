-- Readiness and paths for the derived mon cache. The mons class is one
-- independently rebuildable derived class: a coarse semantic catalog, one
-- selector layout manifest per presentation kind, one bounded atlas page
-- image per declared page, and a summary index binding them. Changing the
-- mon compilers must not disturb the raw ROM dump or any other compiled
-- class. The catalog, the layout, the icon set, one page, and the whole
-- family report readiness separately: a partial page set never reads as a
-- complete family, and layout presence alone never reads as page readiness.
-- Paths are cache-relative; all IO goes through a CacheFs. Following-mon
-- drawable definitions live in FieldActorCache, never here: the catalog
-- references field-actor visual IDs only.

---@class MonCache
local MonCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local PngWriter = require("libs.assets.src.PngWriter")

MonCache.FORMAT = Contract.mons.cacheFormat
MonCache.CATALOG_SCHEMA = Contract.mons.catalogSchema
MonCache.INDEX_SCHEMA = Contract.mons.indexSchema
MonCache.ICON_MANIFEST_SCHEMA = Contract.mons.iconManifestSchema
MonCache.PORTRAIT_MANIFEST_SCHEMA = Contract.mons.portraitManifestSchema

local DATA_DIR = "data/generated/mon"
local ASSET_DIR = "assets/generated/mon"

function MonCache.dir()
  return DATA_DIR
end
function MonCache.assetDir()
  return ASSET_DIR
end
function MonCache.indexPath()
  return DATA_DIR .. "/index.lua"
end
function MonCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end
function MonCache.iconManifestPath()
  return DATA_DIR .. "/icons.lua"
end
function MonCache.portraitManifestPath()
  return DATA_DIR .. "/portraits.lua"
end
function MonCache.iconImagePath()
  return ASSET_DIR .. "/icons.png"
end
function MonCache.portraitImagePath()
  return ASSET_DIR .. "/portraits.png"
end
-- The retired whole-atlas paths above name no staged output: page images
-- below are the only presentation pixels, and no reader falls back to the
-- global paths.

---@param pageId integer zero-based page identity
---@return integer the checked page identity
local function checkPageId(pageId)
  assert(type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0, "mon page id must be a non-negative integer")
  return pageId
end

---@param pageId integer zero-based icon page identity
---@return string cache-relative page image path
function MonCache.iconPagePath(pageId)
  return ASSET_DIR .. "/icons/" .. checkPageId(pageId) .. ".png"
end

---@param pageId integer zero-based portrait page identity
---@return string cache-relative page image path
function MonCache.portraitPagePath(pageId)
  return ASSET_DIR .. "/portraits/" .. checkPageId(pageId) .. ".png"
end

---@return string cache-relative catalog completion marker path
function MonCache.catalogMarkerPath()
  return DATA_DIR .. "/catalog.complete"
end

---@return string cache-relative layout completion marker path
function MonCache.layoutMarkerPath()
  return DATA_DIR .. "/layout.complete"
end

---@param pageId integer zero-based icon page identity
---@return string cache-relative icon page marker path
function MonCache.iconPageMarkerPath(pageId)
  return DATA_DIR .. "/icon-pages/" .. checkPageId(pageId) .. ".complete"
end

---@param pageId integer zero-based portrait page identity
---@return string cache-relative portrait page marker path
function MonCache.portraitPageMarkerPath(pageId)
  return DATA_DIR .. "/portrait-pages/" .. checkPageId(pageId) .. ".complete"
end

---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@return string cache-relative page marker path
function MonCache.pageMarkerPath(kind, pageId)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  if kind == "icons" then
    return MonCache.iconPageMarkerPath(pageId)
  end
  return MonCache.portraitPageMarkerPath(pageId)
end

---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@return string cache-relative page image path
function MonCache.pageImagePath(kind, pageId)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  if kind == "icons" then
    return MonCache.iconPagePath(pageId)
  end
  return MonCache.portraitPagePath(pageId)
end

---@param pageId integer zero-based portrait page identity
---@return string cache-relative decoded index plane path
function MonCache.portraitIndexPagePath(pageId)
  return ASSET_DIR .. "/portraits/" .. checkPageId(pageId) .. ".indices.r8"
end

---@param pageId integer zero-based portrait page identity
---@return string cache-relative base palette path
function MonCache.portraitPalettePagePath(pageId)
  return ASSET_DIR .. "/portraits/" .. checkPageId(pageId) .. ".palettes.rgb555"
end

-- Narrow CPU source reader behind native copy operations: crops the two
-- exact 80x80 index frames using the validated manifest rectangles and
-- reads the sixteen untouched base RGB555 words by palette slot. It
-- returns immutable source data, never personalized instance pixels.
-- Errors identify the selector and sidecar path.
---@param cacheFs CacheFs cache filesystem behind the staged sidecars
---@param manifest table<string, unknown> validated portrait manifest
---@param selector string canonical portrait selector
---@return table<string, unknown>|nil source width, height, index frames, base palette and personalization
---@return string? cause diagnostic cause when no source is available
function MonCache.loadPortraitSource(cacheFs, manifest, selector)
  if type(cacheFs) ~= "table" then
    return nil, "portrait source reads through a cache filesystem"
  end
  if type(manifest) ~= "table" then
    return nil, "portrait source reads through a portrait manifest"
  end
  if type(selector) ~= "string" or selector == "" then
    return nil, "portrait source names its canonical selector"
  end
  local entries = manifest.entries
  if type(entries) ~= "table" then
    return nil, "portrait manifest carries its entries for selector " .. selector
  end
  local entry = entries[selector]
  if type(entry) ~= "table" then
    return nil, "portrait manifest has no entry for selector " .. selector
  end
  local pages = manifest.pages
  if type(pages) ~= "table" then
    return nil, "portrait manifest carries its pages for selector " .. selector
  end
  local page = pages[entry.pageId]
  if type(page) ~= "table" then
    return nil, "portrait manifest has no page for selector " .. selector
  end
  local indexed = page.indexed
  if type(indexed) ~= "table" then
    return nil, "portrait page " .. tostring(entry.pageId) .. " publishes no index plane"
  end
  local paletteCount = indexed.paletteCount
  if type(paletteCount) ~= "number" or paletteCount % 1 ~= 0 or paletteCount < 1 or paletteCount > 16 then
    return nil, "portrait page " .. tostring(entry.pageId) .. " names its palette count"
  end
  local paletteIndex = entry.paletteIndex
  if type(paletteIndex) ~= "number" or paletteIndex % 1 ~= 0 or paletteIndex < 0 or paletteIndex >= paletteCount then
    return nil, "portrait entry " .. selector .. " names its palette slot"
  end
  local frames = entry.frames
  if type(frames) ~= "table" or type(frames[1]) ~= "table" or type(frames[2]) ~= "table" then
    return nil, "portrait entry " .. selector .. " carries both frame rectangles"
  end
  local indices = cacheFs:read(indexed.indices)
  if type(indices) ~= "string" then
    return nil, "portrait index plane is missing at " .. tostring(indexed.indices)
  end
  if #indices ~= page.width * page.height then
    return nil, "portrait index plane has no full page at " .. tostring(indexed.indices)
  end
  local palettes = cacheFs:read(indexed.palettes)
  if type(palettes) ~= "string" then
    return nil, "portrait base palettes are missing at " .. tostring(indexed.palettes)
  end
  if #palettes ~= paletteCount * 32 then
    return nil, "portrait base palettes mismatch their page count at " .. tostring(indexed.palettes)
  end
  local function cropFrame(rect)
    if
      type(rect.x) ~= "number"
      or type(rect.y) ~= "number"
      or type(rect.width) ~= "number"
      or type(rect.height) ~= "number"
      or rect.width ~= 80
      or rect.height ~= 80
    then
      return nil
    end
    local parts = {}
    for row = 0, 79 do
      local base = (rect.y + row) * page.width + rect.x + 1
      parts[#parts + 1] = string.sub(indices, base, base + 79)
    end
    return table.concat(parts)
  end
  local frame0 = cropFrame(frames[1])
  local frame1 = cropFrame(frames[2])
  if frame0 == nil or frame1 == nil or #frame0 ~= 6400 or #frame1 ~= 6400 then
    return nil, "portrait entry " .. selector .. " crops two 80x80 index frames"
  end
  local palette = {}
  for word = 0, 15 do
    local at = math.floor(paletteIndex) * 32 + word * 2 + 1
    local lo = string.byte(palettes, at) or 0
    local hi = string.byte(palettes, at + 1) or 0
    palette[#palette + 1] = lo + hi * 256
  end
  local personalization = nil
  if entry.personalization == "spinda" then
    local definitions = manifest.personalizations
    local spinda = type(definitions) == "table" and definitions.spinda or nil
    if type(spinda) ~= "table" then
      return nil, "portrait entry " .. selector .. " names its personalization rows"
    end
    personalization = { kind = "spinda", spotRows = spinda.spotRows, secondFrameXOffset = -14 }
  end
  return {
    width = 80,
    height = 80,
    indexFrames = { frame0, frame1 },
    basePaletteRgb555 = palette,
    personalization = personalization,
  },
    nil
end
function MonCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function MonCache.markerPath()
  return DATA_DIR .. "/complete"
end

function MonCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", MonCache.FORMAT, romSha1, depHash)
end

-- Canonical presentation selectors. Icon variants cover the default form
-- icon plus the egg icon; portrait variants cover gender and shininess for
-- every form. Consumers build selectors only through these constructors so a
-- catalog selection and its manifest entry can never disagree on spelling.
function MonCache.iconSelector(speciesKey, form, isEgg)
  assert(type(speciesKey) == "string" and speciesKey ~= "", "icon selector requires a species key")
  assert(type(form) == "number" and form % 1 == 0 and form >= 0, "icon selector requires a form")
  if isEgg then
    return speciesKey .. "/egg"
  end
  return speciesKey .. "/f" .. form
end

-- Canonical portrait selectors. The optional facing keeps the established
-- front spelling as its default: "front" spells the same selector as no
-- facing, while "back" appends the explicit facing mark so a back-facing
-- portrait never collapses onto its front-facing selector.
---@param speciesKey string
---@param form integer zero-based form identity
---@param gender "male"|"female"
---@param shiny boolean
---@param facing? "front"|"back" facing mark, defaulting to front
---@return string canonical portrait selector
function MonCache.portraitSelector(speciesKey, form, gender, shiny, facing)
  assert(type(speciesKey) == "string" and speciesKey ~= "", "portrait selector requires a species key")
  assert(type(form) == "number" and form % 1 == 0 and form >= 0, "portrait selector requires a form")
  assert(gender == "male" or gender == "female", "portrait selector requires a gender")
  assert(facing == nil or facing == "front" or facing == "back", "portrait facing must be front or back")
  local base = speciesKey .. "/f" .. form .. "/" .. gender .. "/" .. (shiny and "shiny" or "plain")
  if facing == "back" then
    return base .. "/back"
  end
  return base
end

-- True only when the catalog stage marker is exact and the catalog payload
-- is present. Pixel or page stages never satisfy this on their own.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function MonCache.isCatalogReady(cacheFs, expectedMarker)
  if cacheFs:read(MonCache.catalogMarkerPath()) ~= expectedMarker then
    return false
  end
  return cacheFs:exists(MonCache.catalogPath(), "file")
end

-- True only when the layout stage marker is exact and both persisted
-- selector manifests still satisfy their current consumer-safe contracts.
-- Publication proved the staged bytes, not that the live files remain
-- intact, so readiness revalidates both manifests. Manifest presence alone
-- never reads as page readiness.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function MonCache.isLayoutReady(cacheFs, expectedMarker)
  if cacheFs:read(MonCache.layoutMarkerPath()) ~= expectedMarker then
    return false
  end
  local icons = cacheFs:loadLua(MonCache.iconManifestPath())
  if not MonAssetSchema.isValidIconManifest(icons) then
    return false
  end
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if not MonAssetSchema.isValidPortraitManifest(portraits) then
    return false
  end
  return true
end

-- True only when one page's marker is exact and its page image carries a
-- complete PNG envelope.
---@param cacheFs CacheFs
---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@param expectedMarker string
---@return boolean
function MonCache.isPageReady(cacheFs, kind, pageId, expectedMarker)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  if cacheFs:read(MonCache.pageMarkerPath(kind, pageId)) ~= expectedMarker then
    return false
  end
  local image = cacheFs:read(MonCache.pageImagePath(kind, pageId))
  local width, height = PngWriter.completeDimensions(image)
  if width == nil or height == nil then
    return false
  end
  if kind == "icons" then
    return true
  end
  -- A portrait page is cold without its exact CPU source sidecars: the
  -- index plane must cover the full page, every index must be a palette
  -- slot, and the palette payload must hold whole 16-word RGB555 banks.
  local indices = cacheFs:read(MonCache.portraitIndexPagePath(pageId))
  if type(indices) ~= "string" or #indices ~= width * height then
    return false
  end
  for position = 1, #indices do
    local index = string.byte(indices, position) or 255
    if index > 15 then
      return false
    end
  end
  local palettes = cacheFs:read(MonCache.portraitPalettePagePath(pageId))
  if type(palettes) ~= "string" or #palettes < 32 or #palettes > 512 or #palettes % 32 ~= 0 then
    return false
  end
  for position = 1, #palettes, 2 do
    local lo = string.byte(palettes, position) or 0
    local hi = string.byte(palettes, position + 1) or 0
    if lo + hi * 256 > 32767 then
      return false
    end
  end
  return true
end

-- True only when the layout manifest is loadable and every icon page it
-- declares is ready under its expected marker. Portrait coverage is never
-- required here: the icon set covers party-demanded pages without the portraits.
---@param cacheFs CacheFs
---@param expectedMarkers table<integer, string> expected marker by zero-based page id
---@return boolean
function MonCache.isIconSetReady(cacheFs, expectedMarkers)
  if type(expectedMarkers) ~= "table" then
    return false
  end
  local manifest = cacheFs:loadLua(MonCache.iconManifestPath())
  if not MonAssetSchema.isValidIconManifest(manifest) then
    return false
  end
  assert(manifest ~= nil, "the icon manifest carries its page inventory")
  for _, pageId in ipairs(manifest.pageIds) do
    if not MonCache.isPageReady(cacheFs, "icons", pageId, expectedMarkers[pageId]) then
      return false
    end
  end
  return true
end

-- True only when the summary marker is exact, the page-inventory index
-- loads with the expected schema, the catalog and both manifests are
-- present, and every page the index declares is ready under its indexed
-- marker. Any partial page set reads as incomplete.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function MonCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(MonCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(MonCache.indexPath())
  if not MonAssetSchema.isValidIndex(index) then
    return false
  end
  assert(index ~= nil, "the mon index carries its page inventory")
  if not cacheFs:exists(MonCache.catalogPath(), "file") then
    return false
  end
  local icons = cacheFs:loadLua(MonCache.iconManifestPath())
  if not MonAssetSchema.isValidIconManifest(icons) then
    return false
  end
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if not MonAssetSchema.isValidPortraitManifest(portraits) then
    return false
  end
  assert(icons ~= nil and portraits ~= nil, "the mon manifests carry their page inventories")
  if #index.iconPages ~= #icons.pageIds or #index.portraitPages ~= #portraits.pageIds then
    return false
  end
  for position, marker in ipairs(index.iconPages) do
    if not MonCache.isPageReady(cacheFs, "icons", position - 1, marker) then
      return false
    end
  end
  for position, marker in ipairs(index.portraitPages) do
    if not MonCache.isPageReady(cacheFs, "portraits", position - 1, marker) then
      return false
    end
  end
  return true
end

function MonCache.loadIndex(cacheFs)
  local index = cacheFs:loadLua(MonCache.indexPath())
  MonAssetSchema.assertIndex(index)
  return index
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-catalog validation stays with the producer writers,
-- schema tests, and explicit audit (see isReady).
function MonCache.loadCatalog(cacheFs)
  local catalog = cacheFs:loadLua(MonCache.catalogPath())
  assert(type(catalog) == "table" and catalog.schema == MonCache.CATALOG_SCHEMA, "mon catalog is unavailable")
  return catalog
end

return MonCache
