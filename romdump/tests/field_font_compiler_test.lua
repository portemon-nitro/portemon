-- Deterministic field-font compilation and cache readiness/rollback using a
-- synthetic font member and RLCN palette.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldFontCompiler = require("romdump.src.digest.ui.FieldFontCompiler")
local FieldFontDecoder = require("romdump.src.digest.ui.FieldFontDecoder")
local FieldFontCacheWriter = require("romdump.src.digest.ui.FieldFontCacheWriter")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local PngReader = require("tests.support.PngReader")
local FieldFontSourceFixture = require("tests.support.FieldFontSourceFixture")

local T = {}

local fixture = FieldFontSourceFixture.build
local buildFontMember = FieldFontSourceFixture.buildFontMember
local glyph64 = FieldFontSourceFixture.glyph64

function T.compiles_font_zero_one_and_four_as_one_deterministic_class()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  Assert.deepEqual(FieldFontCache.REQUIRED_FONT_IDS, { 0, 1, 4 })
  Assert.notNil(bundle.fonts, "the compiler must return the complete field-font class")
  Assert.equal(bundle.fonts[0].font.fontId, 0)
  Assert.equal(bundle.fonts[1].font.fontId, 1)
  Assert.equal(bundle.fonts[4].font.fontId, 4)
  Assert.equal(bundle.fonts[0].font.atlasPath, FieldFontCache.atlasPath(0))
  Assert.equal(bundle.fonts[1].font.atlasPath, FieldFontCache.atlasPath(1))
  Assert.equal(bundle.fonts[4].font.atlasPath, FieldFontCache.atlasPath(4))
  Assert.equal(bundle.fonts[0].font.focusIndicators.imagePath, FieldFontCache.focusIndicatorsPath(0))
  Assert.equal(bundle.fonts[1].font.focusIndicators.imagePath, FieldFontCache.focusIndicatorsPath(1))
  Assert.equal(bundle.fonts[4].font.focusIndicators.imagePath, FieldFontCache.focusIndicatorsPath(4))
  Assert.equal(bundle.dependencies.glyphMembers[1].memberId, 0)
  Assert.equal(bundle.dependencies.glyphMembers[2].memberId, 1)
  Assert.equal(bundle.dependencies.glyphMembers[2].sha1, "font1-member-sha")
  Assert.equal(bundle.dependencies.glyphMembers[3].memberId, 4)
  Assert.equal(bundle.dependencies.glyphMembers[3].sha1, "font4-member-sha")
  Assert.equal(bundle.marker, "field-font-cache-v6:rom-sha:dependency-sha")
end

function T.changing_font_four_source_bytes_changes_the_class_marker()
  local hashLua = function(value)
    return LuaWriter.encode(value)
  end
  local romFs, sha1 = fixture()
  local first = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local changedFont4 = buildFontMember(1, glyph64(string.rep(string.char(255), 16)), { 7 })
  local changedRomFs = fixture({ font4Member = changedFont4 })
  local second = assert(FieldFontCompiler.compile(changedRomFs, sha1, hashLua))
  Assert.isTrue(first.marker ~= second.marker, "font member 4 bytes must participate in the class marker")
end

function T.compiles_font_def_and_atlas()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local font = bundle.fonts[0].font
  Assert.equal(font.schema, FieldFontCache.SCHEMA)
  Assert.equal(font.fontId, 0)
  Assert.equal(font.lineHeight, 16)
  Assert.equal(font.maxLetterHeight, 16)
  Assert.equal(font.letterSpacing, 0)
  Assert.equal(font.glyphCount, 1)
  Assert.equal(font.atlas.width, 1024)
  Assert.equal(font.atlas.height, 16 * 7)
  Assert.equal(font.atlas.baseHeight, 16)
  Assert.equal(font.glyphs[1].advance, 6)
  Assert.equal(font.charmap["A"], 0x12B)
  Assert.equal(font.charmap[" "], 0x01DE)
  Assert.equal(font.glyphs[1].w, 16)
  -- Fallback resolves to glyph index 427 (its atlas cell in the grid).
  Assert.equal(font.glyphs[0].x, 688)
  Assert.equal(font.glyphs[0].y, 96)
  Assert.isNil(font.source, "font source identity lives in the dependency record")
  Assert.equal(bundle.dependencies.glyphMembers[1].sha1, "font0-member-sha")
  Assert.equal(bundle.dependencies.paletteMemberSha1, "palette-member-sha")
  Assert.equal(bundle.dependencies.glyphMembers[1].memberId, 0)
  Assert.equal(bundle.dependencies.paletteMemberId, 7)
  Assert.equal(bundle.marker, "field-font-cache-v6:rom-sha:dependency-sha")

  -- The 8x8 sub-tile is repeated for all four quadrants: each row is
  -- (right=0xAA shadow, left=0x55 fg), so every quadrant's left half is
  -- fg (slot 1, 0x296B -> RGB555(r5=11,g5=11,b5=10) -> 90,90,82) and its right half is shadow
  -- (slot 2, 0x5EF5 -> RGB555(r5=21,g5=23,b5=23) -> 173,189,189), resolved at colors[slot+1].
  local atlasWidth, _, rgba = PngReader.rgba(bundle.fonts[0].atlas)
  Assert.equal(atlasWidth, 1024)
  local r, g, b, a = PngReader.pixel(rgba, atlasWidth, 0, 0)
  Assert.equal(a, 255)
  Assert.equal(r, 90)
  Assert.equal(g, 90)
  Assert.equal(b, 82)
  local r2, g2, b2, a2 = PngReader.pixel(rgba, atlasWidth, 4, 0)
  Assert.equal(a2, 255)
  Assert.equal(r2, 173)
  Assert.equal(g2, 189)
  Assert.equal(b2, 189)
  local r3, _, _, a3 = PngReader.pixel(rgba, atlasWidth, 0, 8)
  Assert.equal(a3, 255) -- BL tile repeats the same pattern
  Assert.equal(r3, 90)
  local r4, _, _, a4 = PngReader.pixel(rgba, atlasWidth, 12, 8)
  Assert.equal(a4, 255)
  Assert.equal(r4, 173) -- BR right half carries the shadow too
  -- Background-slot pixels (value 3) composite as transparent so glyph cells
  -- never paint opaque rectangles over the narrower glyphs before them.
  local r5, _, _, a5 = PngReader.pixel(rgba, atlasWidth, 5, 0)
  Assert.equal(a5, 0)
  Assert.equal(r5, 0)
  local _, _, _, a6 = PngReader.pixel(rgba, atlasWidth, 7, 0)
  Assert.equal(a6, 0)
end

function T.compilation_is_deterministic()
  local romFs, sha1, hashLua = fixture()
  local a = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local b = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  Assert.deepEqual(a.fonts[0].atlas, b.fonts[0].atlas)
  Assert.equal(LuaWriter.encode(a.fonts[0].font), LuaWriter.encode(b.fonts[0].font))
  Assert.equal(a.marker, b.marker)
end

function T.writer_commits_marker_last_and_reads_back()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldFontCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldFontCache.isReady(cache, bundle.marker))
  Assert.isFalse(FieldFontCache.isReady(cache, bundle.marker .. "-stale"))
  local def = assert(cache:loadLua(FieldFontCache.defPath(0)))
  Assert.equal(def.schema, FieldFontCache.SCHEMA)
  Assert.isTrue(cache:exists(FieldFontCache.atlasPath(0), "file"))
  Assert.isTrue(cache:exists(FieldFontCache.defPath(4), "file"))
end

function T.writer_failure_invalidates_the_class()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local backend = FakeCache.new()
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("font-4.png", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  Assert.throws(function()
    FieldFontCacheWriter.write(cache, bundle)
  end)
  Assert.isFalse(cache:exists(FieldFontCache.dir()))
end

function T.failed_rebuild_preserves_the_previous_font()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldFontCacheWriter.write(cache, first)
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("font-4.png", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  second.marker = FieldFontCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldFontCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldFontCache.isReady(cache, first.marker), "the previous font class remains ready")
  Assert.equal(cache:read(FieldFontCache.markerPath()), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-font"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldFontCacheWriter.write(cache, second)
  Assert.isTrue(FieldFontCache.isReady(cache, second.marker), "a retry publishes the new font class")
end

function T.corrupt_palette_member_is_typed()
  local glyphMember = buildFontMember(1, glyph64(), { 6 })
  local romFs, sha1, hashLua = fixture()
  romFs.openNarc = function()
    return {
      readMember = function(_, memberId)
        if memberId == 0 then
          return glyphMember
        end
        return "not-rlcn"
      end,
    }
  end
  local bundle, err = FieldFontCompiler.compile(romFs, sha1, hashLua)
  Assert.isNil(bundle, "expected a failure result")
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "FONT_FORMAT_INVALID")
end

-- The font derived class imports member 6 and reports four source-slot masks
-- per 24x32 focus frame, with explicit in-bounds rects and the dependency record.
function T.font_def_exposes_four_24x32_focus_frames_and_member6_dependencies()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local focus = bundle.fonts[0].font.focusIndicators
  Assert.notNil(focus, "the font definition must expose the focus indicator asset")
  Assert.equal(focus.imagePath, "assets/generated/field/font/font-0-focus-indicators.png")
  Assert.equal(focus.count, 4)
  Assert.equal(focus.width, 24)
  Assert.equal(focus.height, 32)
  local focusW, focusH, _ = PngReader.rgba(bundle.fonts[0].focusIndicators)
  local sourceSlots = { 11, 12, 13, 14 }
  for field = 0, focus.count - 1 do
    for index, layer in ipairs(focus.frames[field].layers) do
      local rect = assert(layer.rect)
      Assert.equal(layer.paletteSlot, sourceSlots[index])
      Assert.equal(rect.width, 24, "focus mask " .. layer.paletteSlot .. " must be 24 wide")
      Assert.equal(rect.height, 32, "focus mask " .. layer.paletteSlot .. " must be 32 tall")
      Assert.isTrue(rect.x >= 0 and rect.y >= 0, "focus mask rects are non-negative")
      Assert.isTrue(
        rect.x + rect.width <= focusW and rect.y + rect.height <= focusH,
        "focus mask " .. layer.paletteSlot .. " must lie inside the focus PNG"
      )
    end
  end
  Assert.equal(bundle.dependencies.focusIndicatorMemberId, 6)
  Assert.equal(bundle.dependencies.focusIndicatorMemberSha1, "focus-member-a-sha")
end

-- A malformed focus member (invalid container or truncated payload) fails
-- the whole font compile with a typed format error; the compiler never emits
-- fewer frames.
function T.malformed_focus_members_fail_with_a_typed_format_error()
  for _, bad in ipairs({ "not-an-ncgr", "RGCN" .. string.rep("\0", 12) }) do
    local romFs, sha1, hashLua = fixture({ focusMember = bad })
    local bundle, err = FieldFontCompiler.compile(romFs, sha1, hashLua)
    Assert.isNil(bundle, "a malformed focus member must fail the font compile")
    Assert.isTrue(Errors.is(err), "the focus failure must be a typed format error")
  end
end

function T.malformed_font_four_fails_the_complete_class_with_a_typed_format_error()
  local romFs, sha1, hashLua = fixture({ font4Member = "not-a-font" })
  local bundle, err = FieldFontCompiler.compile(romFs, sha1, hashLua)
  Assert.isNil(bundle, "a malformed font 4 member must fail the complete class")
  Assert.isTrue(Errors.is(err), "the font 4 failure must be a typed format error")
end

-- The compiled definition reports seven color bands that share the base
-- atlas geometry via a positive stride, and the atlas is tall enough for every
-- band.
function T.the_font_def_reports_seven_color_bands_over_the_base_geometry()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local variants = bundle.fonts[0].font.colorVariants
  Assert.notNil(variants, "the font definition must expose colorVariants")
  Assert.equal(variants.count, 7)
  Assert.isTrue(
    variants.strideY > 0 and variants.strideY == math.floor(variants.strideY),
    "strideY must be a positive integer"
  )
  Assert.equal(bundle.fonts[0].font.atlas.height / variants.count, bundle.fonts[0].font.atlas.baseHeight)
  local _, atlasH, _ = PngReader.rgba(bundle.fonts[0].atlas)
  Assert.equal(atlasH, bundle.fonts[0].font.atlas.height)
  for variant = 1, variants.count - 1 do
    Assert.isTrue(
      bundle.fonts[0].font.glyphs[1].y + variant * variants.strideY + bundle.fonts[0].font.glyphs[1].h
        <= bundle.fonts[0].font.atlas.height,
      "variant " .. variant .. " band must fit inside the atlas"
    )
  end
end

-- Each color variant resolves the source 1/2 pixel pair to palette slots
-- 2n+1 (foreground) and 2n+2 (shadow), verified against the imported palette.
function T.color_variants_resolve_the_foreground_and_shadow_palette_pairs()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local variants = bundle.fonts[0].font.colorVariants
  Assert.notNil(variants, "the font definition must expose colorVariants")
  local atlasW, _, rgba = PngReader.rgba(bundle.fonts[0].atlas)
  for variant = 0, 6 do
    local fgSlot = variant * 2 + 1
    local shadowSlot = variant * 2 + 2
    local fg = bundle.fonts[0].font.palette[fgSlot + 1]
    local shadow = bundle.fonts[0].font.palette[shadowSlot + 1]
    local r, g, b, a = PngReader.pixel(rgba, atlasW, 0, variant * variants.strideY)
    Assert.equal(a, 255, "variant " .. variant .. " foreground pixel must be opaque")
    Assert.deepEqual({ r = r, g = g, b = b }, fg, "variant " .. variant .. " foreground uses slot " .. fgSlot)
    local r2, g2, b2, a2 = PngReader.pixel(rgba, atlasW, 4, variant * variants.strideY)
    Assert.equal(a2, 255, "variant " .. variant .. " shadow pixel must be opaque")
    Assert.deepEqual({ r = r2, g = g2, b = b2 }, shadow, "variant " .. variant .. " shadow uses slot " .. shadowSlot)
  end
end

-- The default band keeps the previous default palette slots (FG 1,
-- shadow 2), so Trainer Card and unstyled dialogue stay unchanged.
function T.variant_zero_keeps_the_previous_default_palette_slots()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local atlasW, _, rgba = PngReader.rgba(bundle.fonts[0].atlas)
  local r, g, b, _ = PngReader.pixel(rgba, atlasW, 0, 0)
  Assert.deepEqual(
    { r = r, g = g, b = b },
    bundle.fonts[0].font.palette[FieldFontDecoder.FG_PALETTE_INDEX + 1],
    "default variant foreground stays the previous FG_PALETTE_INDEX slot"
  )
  local r2, g2, b2, _ = PngReader.pixel(rgba, atlasW, 4, 0)
  Assert.deepEqual(
    { r = r2, g = g2, b = b2 },
    bundle.fonts[0].font.palette[FieldFontDecoder.SHADOW_PALETTE_INDEX + 1],
    "default variant shadow stays the previous SHADOW_PALETTE_INDEX slot"
  )
end

-- Each source focus role is retained as a white alpha mask, while source zero
-- remains transparent in every role layer.
function T.focus_indicator_layers_preserve_source_roles_and_transparency()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local focus = bundle.fonts[0].font.focusIndicators
  Assert.notNil(focus, "the font definition must expose focusIndicators")
  local focusW, _, rgba = PngReader.rgba(bundle.fonts[0].focusIndicators)
  local sourceSlots = { 11, 12, 13, 14 }
  local fillSlots = { 11, 12, 13, 14 }
  local borderSlots = { 14, 13, 11, 12 }
  for field = 0, 3 do
    local layers = assert(focus.frames[field].layers)
    for index, layer in ipairs(layers) do
      local sourceSlot = layer.paletteSlot
      Assert.equal(sourceSlot, sourceSlots[index], "focus layers preserve source palette order")
      local rect = assert(layer.rect)
      local fillX = rect.x + 2
      local fillY = rect.y + 2
      local fillR, fillG, fillB, fillA = PngReader.pixel(rgba, focusW, fillX, fillY)
      local expectedFill = sourceSlot == fillSlots[field + 1]
      Assert.deepEqual(
        { fillR, fillG, fillB, fillA },
        expectedFill and { 255, 255, 255, 255 } or { 0, 0, 0, 0 },
        "field " .. field .. " fill belongs only to source slot " .. fillSlots[field + 1]
      )
      local borderX = rect.x
      local borderY = rect.y
      local borderR, borderG, borderB, borderA = PngReader.pixel(rgba, focusW, borderX, borderY)
      local expectedBorder = sourceSlot == borderSlots[field + 1]
      Assert.deepEqual(
        { borderR, borderG, borderB, borderA },
        expectedBorder and { 255, 255, 255, 255 } or { 0, 0, 0, 0 },
        "field " .. field .. " border belongs only to source slot " .. borderSlots[field + 1]
      )
      local holeR, holeG, holeB, holeA = PngReader.pixel(rgba, focusW, rect.x + 12, rect.y + 16)
      Assert.deepEqual({ holeR, holeG, holeB, holeA }, { 0, 0, 0, 0 }, "source zero is transparent")
    end
  end
end

-- When only the member 6 bytes change, the font dependency marker
-- changes; hashing the member id alone would not catch a recompiled member.
function T.changing_only_member6_bytes_changes_the_font_marker()
  local hashLua = function(value)
    return LuaWriter.encode(value)
  end
  local romFs, sha1 = fixture()
  local first = assert(FieldFontCompiler.compile(romFs, sha1, hashLua))
  local _, _, _, members = fixture()
  local second = assert(FieldFontCompiler.compile(fixture({ focusMember = members.focusB }), sha1, hashLua))
  Assert.isTrue(first.marker ~= second.marker, "member 6 bytes must participate in the font dependency marker")
end

-- A cache that is missing the focus-indicator PNG must not be ready, so a
-- stale pre-change font cache cannot pass readiness after the contract bump.
function T.cache_missing_the_focus_indicator_png_is_not_ready()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldFontCacheWriter.write(cache, bundle)
  cache:remove(FieldFontCache.focusIndicatorsPath(0))
  Assert.isFalse(FieldFontCache.isReady(cache, bundle.marker), "a cache without the focus PNG must not be ready")
end

function T.cache_missing_font_one_is_not_ready()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldFontCacheWriter.write(cache, bundle)
  cache:remove(FieldFontCache.defPath(1))
  Assert.isFalse(FieldFontCache.isReady(cache, bundle.marker), "a cache without narration font 1 must not be ready")
end

-- The compiled definition names the required v4 semantic glyph mask atlas,
-- and the bundle carries the mask atlas RGBA rows themselves.
function T.v4_definition_names_the_mask_atlas_and_the_bundle_carries_its_image()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  Assert.equal(bundle.fonts[0].font.schema, "g4-field-font-v5")
  Assert.equal(bundle.fonts[0].font.maskAtlasPath, FieldFontCache.maskAtlasPath(0))
  local mask = bundle.fonts[0].maskAtlas
  Assert.isTrue(type(mask) == "table", "the mask atlas leaves the source phase as an image record")
  Assert.equal(#mask.pixels, mask.width * mask.height * 4, "the mask atlas carries complete RGBA rows")
end

-- The mask atlas repeats the base glyph-layout geometry exactly once (no
-- stacked color bands): its dimensions equal the composited atlas's own
-- base-band dimensions.
function T.mask_atlas_dimensions_equal_the_base_glyph_atlas_dimensions()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local maskW, maskH = PngReader.rgba(bundle.fonts[0].maskAtlas)
  Assert.equal(maskW, bundle.fonts[0].font.atlas.width, "the mask atlas width matches the base glyph atlas width")
  Assert.equal(
    maskH,
    bundle.fonts[0].font.atlas.baseHeight,
    "the mask atlas height matches the base glyph atlas baseHeight"
  )
end

-- The mask atlas encodes the raw 0..3 glyph pixel value categorically, using
-- the exact channel markers a palette shader reads (never a baked color):
-- 0 transparent, 1 red foreground, 2 green shadow, 3 blue background. The
-- same fixture pixel positions the composited-atlas test already proved
-- carry foreground (0,0), shadow (4,0), and background (5,0) classes.
function T.mask_atlas_encodes_the_categorical_glyph_class_exactly()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local maskW, _, maskRgba = PngReader.rgba(bundle.fonts[0].maskAtlas)

  local r, g, b, a = PngReader.pixel(maskRgba, maskW, 0, 0)
  Assert.deepEqual({ r = r, g = g, b = b, a = a }, { r = 255, g = 0, b = 0, a = 255 }, "foreground encodes as red")

  local r2, g2, b2, a2 = PngReader.pixel(maskRgba, maskW, 4, 0)
  Assert.deepEqual({ r = r2, g = g2, b = b2, a = a2 }, { r = 0, g = 255, b = 0, a = 255 }, "shadow encodes as green")

  local r3, g3, b3, a3 = PngReader.pixel(maskRgba, maskW, 5, 0)
  Assert.deepEqual(
    { r = r3, g = g3, b = b3, a = a3 },
    { r = 0, g = 0, b = 255, a = 255 },
    "background encodes as opaque blue, never transparent"
  )

  -- Every atlas cell the single fixture glyph never touches stays exactly
  -- the "0 transparent" encoding, matching the buffer's own zero-fill.
  local r4, g4, b4, a4 = PngReader.pixel(maskRgba, maskW, 16, 0)
  Assert.deepEqual(
    { r = r4, g = g4, b = b4, a = a4 },
    { r = 0, g = 0, b = 0, a = 0 },
    "untouched cells stay transparent"
  )
end

-- A cache that is missing the semantic glyph mask atlas PNG must not be
-- ready: readiness fails just like a missing focus-indicator PNG.
function T.cache_missing_the_mask_atlas_png_is_not_ready()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldFontCompiler.compile(romFs, sha1, hashLua)) --[[@as table]]
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldFontCacheWriter.write(cache, bundle)
  cache:remove(FieldFontCache.maskAtlasPath(0))
  Assert.isFalse(FieldFontCache.isReady(cache, bundle.marker), "a cache without the mask atlas PNG must not be ready")
end

return { tests = T }
