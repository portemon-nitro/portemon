-- Synthetic field-font source: a one-glyph char member, the RLCN font palette,
-- two 4-frame focus char members, and a RomFs-shaped reader. Shared by the
-- compiler suite and the deferred-PNG worker scenario so both prove the same
-- source shape.

local Assert = require("tests.support.Assert")

local FieldFontSourceFixture = {}

local function buildFontMember(numGlyphs, glyphBytes, widths)
  local writer = require("libs.codec.src.BinaryWriter").new()
  writer:u32(16)
  writer:u32(16 + #glyphBytes)
  writer:u32(numGlyphs)
  writer:u8(16)
  writer:u8(16)
  writer:u8(2)
  writer:u8(2)
  writer:bytes(glyphBytes)
  for i = 1, numGlyphs do
    writer:u8(widths[i] or 6)
  end
  return writer:tostring()
end

local function buildPalette(colors)
  local paletteBytes = #colors * 2
  local chunkSize = 0x18 + paletteBytes
  local ttlp = "TTLP"
    .. string.char(
      chunkSize % 256,
      math.floor(chunkSize / 256) % 256,
      math.floor(chunkSize / 65536) % 256,
      math.floor(chunkSize / 16777216) % 256
    )
    .. string.char(3, 0, 0, 0, 0, 0, 0, 0)
    .. string.char(
      paletteBytes % 256,
      math.floor(paletteBytes / 256) % 256,
      math.floor(paletteBytes / 65536) % 256,
      math.floor(paletteBytes / 16777216) % 256
    )
    .. string.char(0x10, 0, 0, 0)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = string.char(c % 256, math.floor(c / 256))
  end
  local total = 0x10 + #ttlp + #table.concat(body)
  local header = "RLCN"
    .. string.char(0xFF, 0xFE, 0x00, 0x01)
    .. string.char(
      total % 256,
      math.floor(total / 256) % 256,
      math.floor(total / 65536) % 256,
      math.floor(total / 16777216) % 256
    )
    .. string.char(0x10, 0, 1, 0)
  return header .. ttlp .. table.concat(body)
end

local function glyph64(tile)
  local tiles = {}
  for _ = 1, 4 do
    tiles[#tiles + 1] = tile or string.rep("\0", 16)
  end
  return table.concat(tiles)
end

-- Builds a 4bpp NCGR char container over `tiles` (32 bytes per tile). The
-- layout follows GBATEK and is the shape decodeChar accepts: a 16-byte header,
-- then one CHAR block whose body carries the depth at +4, the tile byte count
-- at +0x10, the tile offset at +0x14, then the tiles.
local function buildFocusMember(tiles)
  local function u32le(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
  end
  local chunkSize = 0x18 + #tiles
  local blockSize = 8 + chunkSize
  local fileSize = 0x10 + blockSize
  local charChunk = string.char(0x00, 0x00, 0x00, 0x00)
    .. u32le(3)
    .. string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    .. u32le(#tiles)
    .. u32le(0x18)
    .. tiles
  local block = "RAHC" .. u32le(blockSize) .. charChunk
  return "RGCN"
    .. string.char(0xFF, 0xFE)
    .. string.char(0x01, 0x01)
    .. u32le(fileSize)
    .. string.char(0x10, 0x00)
    .. string.char(0x01, 0x00)
    .. block
end

-- Encodes one 24x32 frame as its 12 row-major 8x8 4bpp tiles. `pattern` maps
-- a zero-based pixel coordinate to a 0..15 palette index. 4bpp tile bytes
-- hold two pixels with the left (even) pixel in the low nibble (GBATEK).
local function frameTiles(pattern)
  local tiles = {}
  for tileY = 0, 3 do
    for tileX = 0, 2 do
      local bytes = {}
      for row = 0, 7 do
        for pair = 0, 3 do
          local x0 = tileX * 8 + pair * 2
          local y0 = tileY * 8 + row
          bytes[#bytes + 1] = string.char(pattern(x0 + 1, y0) * 16 + pattern(x0, y0))
        end
      end
      tiles[#tiles + 1] = table.concat(bytes)
    end
  end
  return table.concat(tiles)
end

-- A bordered 24x32 rectangle of `fill` with an empty 8x8 hole in the middle, so
-- tests can probe both a visible indicator index and the transparent
-- background index in one frame.
local function indicatorsFrame(fill, border)
  return frameTiles(function(x, y)
    if x == 0 or x == 23 or y == 0 or y == 31 then
      return border
    end
    if x >= 8 and x <= 15 and y >= 12 and y <= 19 then
      return 0
    end
    return fill
  end)
end

-- Two distinct 4-frame focus members so a member-6 dependency test can swap
-- only those bytes. Each carries the 24x32 4bpp protocol shape (48 tiles).
local function focusMembers()
  local a = table.concat({
    indicatorsFrame(0x0B, 0x0E),
    indicatorsFrame(0x0C, 0x0D),
    indicatorsFrame(0x0D, 0x0B),
    indicatorsFrame(0x0E, 0x0C),
  })
  local b = table.concat({
    indicatorsFrame(0x0D, 0x0B),
    indicatorsFrame(0x0B, 0x0D),
    indicatorsFrame(0x0C, 0x0D),
    indicatorsFrame(0x0D, 0x0B),
  })
  return buildFocusMember(a), buildFocusMember(b)
end

function FieldFontSourceFixture.build(opts)
  opts = opts or {}
  -- One glyph: value-1 pixels on the left half, value-2 on the right, so the
  -- atlas and def expose both ink colors; the first row's right half also
  -- carries value-3 (background-slot) pixels, which must composite as
  -- transparent (0xBB = pixels 2,3,2,3 with pixel 0 = high bits, matching
  -- DecompressGlyphTile).
  -- Row bytes (right, left): left half = value 1 (fg), right half = value 2.
  local tile = string.char(0xBB, 0x55) .. string.rep(string.char(0xAA, 0x55), 7)
  local glyphMember = buildFontMember(1, glyph64(tile), { 6 })
  local font1Member = buildFontMember(1, glyph64(string.rep(string.char(0x55), 16)), { 8 })
  local font4Member = buildFontMember(1, glyph64(tile), { 7 })
  -- Font palette slots mirroring the ROM font palette
  -- (fgColor=1, shadowColor=2, bgColor=0xF): slot 0 = unused
  -- green, 1 = fg (0x296B dark), 2 = shadow (0x5EF5 gray), 15 = bg (white).
  -- Slots 3..10 are the additional color-band foreground/shadow pairs and
  -- slots 11..14 the focus-indicator colors; all are distinct so the
  -- color-band and indicator mapping tests cannot pass with a degenerate
  -- palette. palette.colors is 1-based, so the compiler resolves slot N at
  -- colors[N+1].
  local paletteMember = buildPalette({
    0x3713,
    0x296B,
    0x5EF5,
    0x089D,
    0x5EBF,
    0x0F45,
    0x47B3,
    0x7DC0,
    0x76EF,
    0x5E5F,
    0x737F,
    0x001F,
    0x03E0,
    0x7C00,
    0x4A94,
    0x7FFF,
  })
  local focusA, focusB = focusMembers()
  local romFs = {
    _version = "heartgold",
    _metadata = { sha1 = "rom-sha" },
    resolvedNarc = function(_, alias)
      Assert.equal(alias, "font")
      return { symbol = "NARC_graphic_font", alias = "font", narcId = 16, fileId = 66, path = "a/0/1/6" }
    end,
    read = function(_, fileId)
      Assert.equal(fileId, 66)
      return "archive-bytes"
    end,
    openNarc = function(_, alias)
      Assert.equal(alias, "font")
      return {
        readMember = function(_, memberId)
          if memberId == 0 then
            return glyphMember
          end
          if memberId == 1 then
            return font1Member
          end
          if memberId == 4 then
            return opts.font4Member or font4Member
          end
          if memberId == 6 then
            return opts.focusMember or focusA
          end
          if memberId == 7 then
            return paletteMember
          end
          Assert.fail("unexpected font member " .. tostring(memberId))
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  } --[[@as RomFs]]
  local function sha1(bytes)
    if bytes == glyphMember then
      return "font0-member-sha"
    end
    if bytes == font1Member then
      return "font1-member-sha"
    end
    if bytes == font4Member then
      return "font4-member-sha"
    end
    if bytes == paletteMember then
      return "palette-member-sha"
    end
    if bytes == focusA then
      return "focus-member-a-sha"
    end
    if bytes == focusB then
      return "focus-member-b-sha"
    end
    return "archive-sha"
  end
  return romFs, sha1, function()
    return "dependency-sha"
  end, { focusA = focusA, focusB = focusB }
end

FieldFontSourceFixture.buildFontMember = buildFontMember
FieldFontSourceFixture.glyph64 = glyph64

return FieldFontSourceFixture
