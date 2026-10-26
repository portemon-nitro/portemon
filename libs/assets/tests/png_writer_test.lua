-- PngWriter: PNG framing, indexed encoding for low-color images with a
-- lossless RGBA fallback, exact pixel round-trips through LÖVE (including
-- transparency), and staged-byte dimension reporting for readiness checks.

local Assert = require("tests.support.Assert")
local PngWriter = require("libs.assets.src.PngWriter")
local Errors = require("libs.errors.src.Errors")

local T = {}

local PNG_SIGNATURE = string.char(137, 80, 78, 71, 13, 10, 26, 10)

local function px(r, g, b, a)
  return string.char(r, g, b, a)
end

local function readU32(png, position)
  local a, b, c, d = png:byte(position, position + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Minimal chunk walk over an encoded PNG: IHDR geometry and color shape
-- plus PLTE/tRNS presence. Raises when the framing is not a PNG.
local function parseChunks(png)
  assert(png:sub(1, 8) == PNG_SIGNATURE, "not a PNG file")
  local position = 9
  local info = { plte = false, trns = false, idat = false }
  while position <= #png do
    assert(position + 7 <= #png, "truncated PNG chunk header")
    local length = readU32(png, position)
    local kind = png:sub(position + 4, position + 7)
    local dataStart = position + 8
    assert(dataStart + length + 3 <= #png, "truncated " .. kind .. " chunk")
    if kind == "IHDR" then
      assert(length == 13, "IHDR carries its 13 content bytes")
      info.width = readU32(png, dataStart)
      info.height = readU32(png, dataStart + 4)
      info.bitDepth, info.colorType = png:byte(dataStart + 8, dataStart + 9)
    elseif kind == "PLTE" then
      info.plte = true
    elseif kind == "tRNS" then
      info.trns = true
    elseif kind == "IDAT" then
      info.idat = true
    elseif kind == "IEND" then
      break
    end
    position = dataStart + length + 4
  end
  assert(info.width ~= nil, "PNG carries its IHDR geometry")
  return info
end

local function decodePixels(png, name)
  local data = love.image.newImageData(love.filesystem.newFileData(png, name or "t.png"))
  local rows = {}
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local r, g, b, a = data:getPixel(x, y)
      rows[#rows + 1] = string.char(
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5),
        math.floor(a * 255 + 0.5)
      )
    end
  end
  return { width = data:getWidth(), height = data:getHeight(), pixels = table.concat(rows) }
end

local function assertRoundTrip(width, height, pixels, name)
  local decoded = decodePixels(PngWriter.encode(width, height, pixels), name)
  Assert.equal(decoded.width, width, "decoded width")
  Assert.equal(decoded.height, height, "decoded height")
  Assert.equal(decoded.pixels, pixels, "decoded pixels match exactly")
end

function T.starts_with_signature_and_has_ihdr_idat_iend()
  local png = PngWriter.encode(1, 1, px(10, 20, 30, 255))
  Assert.equal(png:sub(1, 8), PNG_SIGNATURE)
  Assert.equal(png:sub(13, 16), "IHDR")
  Assert.isTrue(png:find("IDAT", 1, true) ~= nil, "has IDAT")
  Assert.equal(png:sub(#png - 7, #png - 4), "IEND") -- type precedes its 4-byte CRC
end

function T.rejects_wrong_length()
  local ok, err = pcall(PngWriter.encode, 2, 2, "short")
  Assert.isTrue(not ok, "raises")
  Assert.isTrue(Errors.is(err), "raises a structured error")
  Assert.equal(tostring(rawget(err, "code")), "PNG_BAD_RGBA_LENGTH")
end

function T.rejects_bad_dimensions()
  for _, case in ipairs({ { 0, 1 }, { 1, 0 }, { -1, 1 }, { 1.5, 2 } }) do
    local ok, err = pcall(PngWriter.encode, case[1], case[2], "")
    Assert.isTrue(not ok, "rejects " .. tostring(case[1]) .. "x" .. tostring(case[2]))
    Assert.isTrue(Errors.is(err), "rejection stays structured")
    Assert.equal(tostring(rawget(err, "code")), "PNG_BAD_DIMENSIONS")
  end
end

function T.decodes_back_to_the_same_pixels()
  local pixels = px(10, 20, 30, 255)
    .. px(200, 150, 100, 128)
    .. px(0, 0, 0, 0)
    .. px(255, 128, 64, 0)
  assertRoundTrip(2, 2, pixels, "roundtrip.png")
end

function T.uses_indexed_encoding_for_256_or_fewer_colors()
  -- Eight distinct RGBA tuples: opaque, partial, fully transparent, and
  -- same-RGB/different-alpha pairs that must stay distinct entries.
  local pixels = px(10, 20, 30, 255)
    .. px(10, 20, 30, 128)
    .. px(10, 20, 30, 0)
    .. px(255, 0, 0, 0)
    .. px(0, 0, 0, 0)
    .. px(1, 2, 3, 4)
    .. px(200, 150, 100, 77)
    .. px(5, 6, 7, 8)
  local png = PngWriter.encode(4, 2, pixels)
  local info = parseChunks(png)
  Assert.equal(info.width, 4, "IHDR width")
  Assert.equal(info.height, 2, "IHDR height")
  Assert.equal(info.colorType, 3, "low-color images encode indexed")
  Assert.isTrue(info.plte, "indexed output carries its palette")
  Assert.isTrue(info.trns, "indexed output carries its alpha table")
  local decoded = decodePixels(png, "indexed.png")
  Assert.equal(decoded.pixels, pixels, "indexed pixels survive exactly")
end

function T.preserves_transparent_rgb_exactly()
  -- An image with no opaque pixel at all: transparent RGB must survive
  -- rather than collapsing to black.
  local pixels = px(0, 0, 0, 0) .. px(255, 128, 64, 0)
  assertRoundTrip(2, 1, pixels, "transparent.png")
end

function T.falls_back_to_lossless_rgba_beyond_256_colors()
  local parts = {}
  for i = 0, 288 do
    parts[#parts + 1] = px(i % 256, math.floor(i / 256), 77, 255)
  end
  local pixels = table.concat(parts)
  local png = PngWriter.encode(17, 17, pixels)
  local info = parseChunks(png)
  Assert.equal(info.colorType, 6, "high-color images fall back to truecolor with alpha")
  local decoded = decodePixels(png, "fallback.png")
  Assert.equal(decoded.pixels, pixels, "fallback pixels survive exactly")
end

function T.dimensions_reports_staged_image_extents()
  local png = PngWriter.encode(3, 2, string.rep(px(9, 9, 9, 255), 3 * 2))
  local width, height = PngWriter.dimensions(png)
  Assert.equal(width, 3, "staged width")
  Assert.equal(height, 2, "staged height")
  Assert.isNil(PngWriter.dimensions("not a png"), "garbage has no dimensions")
  Assert.isNil(PngWriter.dimensions(png:sub(1, 20)), "truncated headers have no dimensions")
end

return { tests = T }
