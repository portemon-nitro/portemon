-- Paths, readiness, and validation for the generated field-font cache. The field font is one
-- of the independently rebuildable derived classes (map geometry, actor
-- visuals, messages/font): changing the font compiler must not disturb the raw
-- ROM dump, compiled maps, or message banks. A font is ready only when the
-- completion marker matches exactly and the definition, the glyph atlas, the
-- semantic glyph mask atlas, and the focus-indicator PNG are present. Paths
-- are cache-relative; all IO goes
-- through a CacheFs (PNG binaries live under the derived assets root).

local FieldFontCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local Validate = require("libs.assets.src.Validate")
local FOCUS_LAYER_COUNT = 4

---@class FieldFontDef
---@field schema string
---@field fontId integer
---@field lineHeight integer
---@field maxLetterHeight integer
---@field letterSpacing integer
---@field glyphCount integer
---@field fallbackCode integer
---@field atlasPath string
---@field maskAtlasPath string
---@field atlas { width: integer, height: integer, baseHeight: integer, glyphsPerRow: integer, glyphWidth: integer, glyphHeight: integer }
---@field colorVariants { count: integer, strideY: integer }
---@field focusIndicators { imagePath: string, count: integer, width: integer, height: integer, frames: table<integer, { layers: { paletteSlot: integer, rect: { x: integer, y: integer, width: integer, height: integer } }[] }> }
---@field glyphs table<integer, { x: integer, y: integer, w: integer, h: integer, advance: integer, bearingX: integer, bearingY: integer }>
---@field charmap table<string, integer>
---@field palette { r: integer, g: integer, b: integer }[]

FieldFontCache.FORMAT = Contract.font.cacheFormat
FieldFontCache.SCHEMA = Contract.font.schema
FieldFontCache.REQUIRED_FONT_IDS = { 0, 4 }

-- The source focus-indicator frames are 24x32 (the text printer's YESNO
-- screen-focus graphic); the compiled definition's frame rects must match.
FieldFontCache.FOCUS_FRAME_WIDTH = 24
FieldFontCache.FOCUS_FRAME_HEIGHT = 32

local DATA_DIR = "data/generated/field/font"
local ASSET_DIR = "assets/generated/field/font"

function FieldFontCache.dir()
  return DATA_DIR
end
function FieldFontCache.assetDir()
  return ASSET_DIR
end
function FieldFontCache.defPath(fontId)
  return string.format("%s/font-%d.lua", DATA_DIR, fontId)
end
function FieldFontCache.atlasPath(fontId)
  return string.format("%s/font-%d.png", ASSET_DIR, fontId)
end

-- The semantic glyph mask atlas: the same base-band glyph-layout geometry as
-- the composited atlas, but encoding the raw categorical glyph class per
-- pixel (transparent/foreground/shadow/background) instead of baked colors,
-- so a palette-driven draw path can recolor glyphs against any runtime
-- palette.
function FieldFontCache.maskAtlasPath(fontId)
  return string.format("%s/font-%d-mask.png", ASSET_DIR, fontId)
end

function FieldFontCache.focusIndicatorsPath(fontId)
  return string.format("%s/font-%d-focus-indicators.png", ASSET_DIR, fontId)
end
function FieldFontCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function FieldFontCache.markerPath()
  return DATA_DIR .. "/complete"
end

function FieldFontCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldFontCache.FORMAT, romSha1, depHash)
end

local function validateColorVariants(variants)
  if type(variants) ~= "table" or variants.count ~= FieldMessageText.COLOR_VARIANT_COUNT then
    return "colorVariants must declare exactly " .. FieldMessageText.COLOR_VARIANT_COUNT .. " bands"
  end
  if not Validate.isNonNegativeInteger(variants.strideY) or variants.strideY == 0 then
    return "colorVariants.strideY must be a positive integer"
  end
end

local function validateAtlas(atlas, variants)
  if type(atlas) ~= "table" or not Validate.isNonNegativeInteger(atlas.baseHeight) or atlas.baseHeight == 0 then
    return "atlas.baseHeight must be a positive integer"
  end
  if type(atlas.height) ~= "number" or atlas.height < atlas.baseHeight * variants.count then
    return "atlas height must fit every color band"
  end
end

local function validateFocusLayer(layer, index, field, seenPaletteSlots)
  if type(layer) ~= "table" then
    return "focus frame " .. field .. " layer " .. index .. " must be a record"
  end
  local paletteSlot = layer.paletteSlot
  if not Validate.isNonNegativeInteger(paletteSlot) or paletteSlot > 15 or seenPaletteSlots[paletteSlot] then
    return "focus frame " .. field .. " has an invalid or duplicate palette slot"
  end
  seenPaletteSlots[paletteSlot] = true
  local rect = layer.rect
  local expectedX = (index - 1) * FieldFontCache.FOCUS_FRAME_WIDTH
  local expectedY = field * FieldFontCache.FOCUS_FRAME_HEIGHT
  if
    type(rect) ~= "table"
    or rect.x ~= expectedX
    or rect.y ~= expectedY
    or rect.width ~= FieldFontCache.FOCUS_FRAME_WIDTH
    or rect.height ~= FieldFontCache.FOCUS_FRAME_HEIGHT
  then
    return "focus frame " .. field .. " layer " .. index .. " has invalid geometry"
  end
end

local function validateFocusIndicators(focus)
  if
    type(focus) ~= "table"
    or focus.count ~= FieldMessageText.FOCUS_INDICATOR_COUNT
    or type(focus.frames) ~= "table"
  then
    return "focusIndicators must declare exactly " .. FieldMessageText.FOCUS_INDICATOR_COUNT .. " frames"
  end
  for field = 0, focus.count - 1 do
    local frame = focus.frames[field]
    if type(frame) ~= "table" or not Validate.isArray(frame.layers) or #frame.layers ~= FOCUS_LAYER_COUNT then
      return "focus frame " .. field .. " must carry exactly four ordered layers"
    end
    local seenPaletteSlots = {}
    for index, layer in ipairs(frame.layers) do
      local reason = validateFocusLayer(layer, index, field, seenPaletteSlots)
      if reason then
        return reason
      end
    end
  end
  for field in pairs(focus.frames) do
    if not Validate.isNonNegativeInteger(field) or field >= focus.count then
      return "focusIndicators.frames has an unsupported frame"
    end
  end
end

---@param definition table<string, unknown>
---@return boolean valid, string? reason
function FieldFontCache.validateDefinition(definition)
  local variants = definition.colorVariants
  local reason = validateColorVariants(variants)
  if reason then
    return false, reason
  end
  reason = validateAtlas(definition.atlas, variants)
  if reason then
    return false, reason
  end
  if type(definition.maskAtlasPath) ~= "string" or definition.maskAtlasPath == "" then
    return false, "maskAtlasPath must name the semantic glyph mask atlas"
  end
  reason = validateFocusIndicators(definition.focusIndicators)
  if reason then
    return false, reason
  end
  return true
end

function FieldFontCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldFontCache.markerPath()) ~= expectedMarker then
    return false
  end
  for _, fontId in ipairs(FieldFontCache.REQUIRED_FONT_IDS) do
    if not cacheFs:exists(FieldFontCache.defPath(fontId), "file") then
      return false
    end
    if not cacheFs:exists(FieldFontCache.atlasPath(fontId), "file") then
      return false
    end
    if not cacheFs:exists(FieldFontCache.maskAtlasPath(fontId), "file") then
      return false
    end
    if not cacheFs:exists(FieldFontCache.focusIndicatorsPath(fontId), "file") then
      return false
    end
  end
  return true
end

return FieldFontCache
