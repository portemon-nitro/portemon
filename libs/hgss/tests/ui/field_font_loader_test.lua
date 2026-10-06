-- Field font definitions are trusted published data. Loading them must not
-- allocate a presentation resource, so field composition can lay out dialogue
-- before a renderer exists. The loader checks presence and the current schema
-- identity; whole-definition shape rules stay with the producer pipeline and
-- explicit audit. Consumers assert the fields they actually read.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local T = {}

local COLOR_COUNT = FieldMessageText.COLOR_VARIANT_COUNT
local FOCUS_COUNT = FieldMessageText.FOCUS_INDICATOR_COUNT

local function validDef(fontId)
  fontId = fontId or 0
  local baseHeight = 16
  local focusFrames = {}
  for field = 0, FOCUS_COUNT - 1 do
    local layers = {}
    for index, slot in ipairs({ 2, 5, 8, 11 }) do
      layers[index] = {
        paletteSlot = slot,
        rect = {
          x = (index - 1) * FieldFontCache.FOCUS_FRAME_WIDTH,
          y = field * FieldFontCache.FOCUS_FRAME_HEIGHT,
          width = FieldFontCache.FOCUS_FRAME_WIDTH,
          height = FieldFontCache.FOCUS_FRAME_HEIGHT,
        },
      }
    end
    focusFrames[field] = { layers = layers }
  end
  return {
    schema = FieldFontCache.SCHEMA,
    fontId = fontId,
    maskAtlasPath = FieldFontCache.maskAtlasPath(fontId),
    lineHeight = 16,
    maxLetterHeight = 16,
    letterSpacing = 0,
    glyphCount = 1,
    fallbackCode = 0,
    atlas = {
      width = 1024,
      height = baseHeight * COLOR_COUNT,
      baseHeight = baseHeight,
      glyphsPerRow = 64,
      glyphWidth = 16,
      glyphHeight = 16,
    },
    colorVariants = { count = COLOR_COUNT, strideY = baseHeight },
    focusIndicators = {
      imagePath = FieldFontCache.focusIndicatorsPath(fontId),
      count = FOCUS_COUNT,
      width = 24,
      height = 32,
      frames = focusFrames,
    },
    glyphs = {
      [0] = { x = 0, y = 0, w = 16, h = 16, advance = 6, bearingX = 0, bearingY = 0 },
    },
    charmap = {},
    palette = {},
  }
end

local function cacheWith(def, fontId)
  fontId = fontId or def.fontId
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldFontCache.defPath(fontId), def)
  return cache
end

local function loadExpectRaised(def, context)
  local raised = Assert.throws(function()
    FieldFontLoader.load(cacheWith(def))
  end, context)
  Assert.isTrue(Errors.is(raised), context .. " must be a typed error")
end

function T.loads_the_compiled_definition_without_a_graphics_namespace()
  local definition = validDef()
  local loaded = FieldFontLoader.load(cacheWith(definition)) --[[@as table]]
  Assert.deepEqual(loaded, definition)
  Assert.equal(loaded.colorVariants.count, FieldMessageText.COLOR_VARIANT_COUNT)
  Assert.equal(loaded.focusIndicators.count, FieldMessageText.FOCUS_INDICATOR_COUNT)
end

function T.loads_font_four_from_its_parameterized_definition_path()
  local definition = validDef(4)
  local loaded = FieldFontLoader.load(cacheWith(definition), 4) --[[@as table]]
  Assert.deepEqual(loaded, definition)
  Assert.equal(loaded.fontId, 4)
end

-- The old single-rect focus definition must never pass as the layered contract.
function T.load_rejects_a_stale_single_rect_focus_definition()
  local v3 = validDef()
  v3.schema = "g4-field-font-v3"
  for field = 0, FOCUS_COUNT - 1 do
    v3.focusIndicators.frames[field] = {
      x = field * FieldFontCache.FOCUS_FRAME_WIDTH,
      y = 0,
      width = FieldFontCache.FOCUS_FRAME_WIDTH,
      height = FieldFontCache.FOCUS_FRAME_HEIGHT,
    }
  end
  loadExpectRaised(v3, "a stale single-rect focus definition must be rejected")
end

function T.load_trusts_the_published_definition_without_revalidating()
  local originalValidate = FieldFontCache.validateDefinition
  local calls = 0
  rawset(FieldFontCache, "validateDefinition", function()
    calls = calls + 1
    error("the published definition must not be revalidated at load", 0)
  end)
  local ok, loaded = pcall(FieldFontLoader.load, cacheWith(validDef()))
  rawset(FieldFontCache, "validateDefinition", originalValidate)
  Assert.isTrue(ok, "a published font definition loads without invoking the comprehensive validator")
  Assert.equal(calls, 0, "the comprehensive font validator must not run during trusted load")
  Assert.equal(loaded --[[@as table]].schema, FieldFontCache.SCHEMA)
end

-- Whole-definition shape rules (color bands, atlas geometry, mask atlas,
-- focus layers) stay with the producer pipeline and explicit audit: the
-- schema tests and writer readback prove them, so trusted load needs no
-- per-field rejection tests here. Consumers assert the fields they read at
-- their own use sites.

return { tests = T }
