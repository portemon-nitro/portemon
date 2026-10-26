-- PNG encoding with palette indexing for low-color images and a lossless
-- truecolor fallback beyond 256 distinct RGBA colors. Indexed output uses
-- 8-bit palette indices with PLTE/tRNS chunks, preserving every color and
-- alpha value exactly, including the RGB of fully transparent pixels. Both
-- shapes compress their filter-zero scanlines with zlib through LÖVE, so the
-- encoded length varies with content: callers must treat the output as an
-- opaque byte string, never a fixed function of the dimensions.

local bit = require("bit")
local Errors = require("libs.errors.src.Errors")

local PngWriter = {}

---@class PngWriter
---@field encode fun(width: integer, height: integer, rgba: string): string
---@field dimensions fun(png: string?): integer?, integer?
---@field validateDimensions fun(width: integer, height: integer)

local CRC_TABLE = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
    else
      c = bit.rshift(c, 1)
    end
  end
  CRC_TABLE[n] = c
end

local SIGNATURE = string.char(137, 80, 78, 71, 13, 10, 26, 10)

---@param value integer
---@param shift integer bit position of the wanted byte
---@return integer nearest byte of value
local function byteAt(value, shift)
  return bit.band(bit.rshift(value, shift), 0xFF)
end

---@param value integer
---@return string value as 4 big-endian bytes
local function u32(value)
  return string.char(byteAt(value, 24), byteAt(value, 16), byteAt(value, 8), bit.band(value, 0xFF))
end

---@param crc integer
---@param value integer
---@return integer updated crc
local function updateCrc(crc, value)
  ---@cast value integer
  local index = bit.band(bit.bxor(crc, value), 0xFF)
  return bit.bxor(bit.rshift(crc, 8), CRC_TABLE[index])
end

---@param kind string 4-byte chunk type
---@param data string chunk content bytes
---@return string framed chunk with length and CRC
local function chunk(kind, data)
  local crc = 0xFFFFFFFF
  for index = 1, 4 do
    crc = updateCrc(crc, kind:byte(index))
  end
  for index = 1, #data do
    crc = updateCrc(crc, data:byte(index))
  end
  return u32(#data) .. kind .. data .. u32(bit.bnot(crc))
end

---@param width integer
---@param height integer
function PngWriter.validateDimensions(width, height)
  if type(width) ~= "number" or width ~= math.floor(width) or width <= 0 then
    Errors.raise("PNG_BAD_DIMENSIONS", "PNG width must be a positive integer", { width = width })
  end
  if type(height) ~= "number" or height ~= math.floor(height) or height <= 0 then
    Errors.raise("PNG_BAD_DIMENSIONS", "PNG height must be a positive integer", { height = height })
  end
end

---@param png string? staged bytes
---@return integer? width image width, nil unless the IHDR geometry parses
---@return integer? height image height, nil unless the IHDR geometry parses
function PngWriter.dimensions(png)
  if type(png) ~= "string" or #png < 33 then
    return nil
  end
  if png:sub(1, 8) ~= SIGNATURE then
    return nil
  end
  local a, b, c, d = png:byte(9, 12)
  local length = ((a * 256 + b) * 256 + c) * 256 + d
  if length ~= 13 or png:sub(13, 16) ~= "IHDR" then
    return nil
  end
  local w1, w2, w3, w4 = png:byte(17, 20)
  local h1, h2, h3, h4 = png:byte(21, 24)
  return ((w1 * 256 + w2) * 256 + w3) * 256 + w4, ((h1 * 256 + h2) * 256 + h3) * 256 + h4
end

---@param width integer
---@param height integer
---@param colorType integer PNG color type
---@return string IHDR chunk
local function ihdr(width, height, colorType)
  local data = u32(width) .. u32(height) .. string.char(8, colorType, 0, 0, 0)
  return chunk("IHDR", data)
end

---@param raw string filter-zero scanlines
---@return string IDAT chunk with the zlib-compressed scanlines
local function idat(raw)
  local compressed = love.data.compress("string", "zlib", raw)
  assert(type(compressed) == "string", "string-container compression returns its bytes as a string")
  return chunk("IDAT", compressed)
end

-- rgba: width*height*4 bytes, row-major, top-left origin, straight alpha.
-- Returns the indexed encoding when the pixels hold at most 256 distinct
-- RGBA tuples, else the truecolor-alpha encoding. Both decode to the exact
-- input pixels through the standard image pipeline.
---@param width integer
---@param height integer
---@param rgba string
---@return string png encoded image bytes
function PngWriter.encode(width, height, rgba)
  PngWriter.validateDimensions(width, height)
  assert(type(rgba) == "string", "PngWriter.encode requires an RGBA string")
  local expectedLength = width * height * 4
  if #rgba ~= expectedLength then
    Errors.raise(
      "PNG_BAD_RGBA_LENGTH",
      string.format("rgba is %d bytes, expected %d (%dx%d*4)", #rgba, expectedLength, width, height),
      { width = width, height = height, length = #rgba }
    )
  end

  -- First-seen palette order keeps the encoding deterministic; stopping
  -- past 257 distinct tuples selects the fallback without scanning the
  -- rest. Fully transparent tuples stay distinct entries so their RGB
  -- survives exactly.
  local palette = {}
  local paletteIndex = {}
  local indices = {}
  local indexed = true
  for offset = 1, #rgba, 4 do
    local key = rgba:sub(offset, offset + 3)
    local found = paletteIndex[key]
    if found == nil then
      if #palette == 256 then
        indexed = false
        break
      end
      palette[#palette + 1] = key
      found = #palette - 1
      paletteIndex[key] = found
    end
    indices[#indices + 1] = found
  end

  if not indexed then
    local rows = {}
    local stride = width * 4
    for row = 0, height - 1 do
      rows[#rows + 1] = "\0"
      rows[#rows + 1] = rgba:sub(row * stride + 1, (row + 1) * stride)
    end
    return SIGNATURE .. ihdr(width, height, 6) .. idat(table.concat(rows)) .. chunk("IEND", "")
  end

  local plte, trns = {}, {}
  for _, key in ipairs(palette) do
    local r, g, b, a = key:byte(1, 4)
    plte[#plte + 1] = string.char(r, g, b)
    trns[#trns + 1] = string.char(a)
  end
  -- string.char/unpack are limited by the Lua stack; build index rows in
  -- row chunks.
  local rows = {}
  for row = 0, height - 1 do
    rows[#rows + 1] = "\0"
    local base = row * width
    local stop = base + width
    local start = base + 1
    while start <= stop do
      local last = math.min(start + 4095, stop)
      rows[#rows + 1] = string.char(unpack(indices, start, last))
      start = last + 1
    end
  end
  return SIGNATURE
    .. ihdr(width, height, 3)
    .. chunk("PLTE", table.concat(plte))
    .. chunk("tRNS", table.concat(trns))
    .. idat(table.concat(rows))
    .. chunk("IEND", "")
end

return PngWriter
