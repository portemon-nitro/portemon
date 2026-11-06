-- Samples one source-indexed RGBA8 image from its displayed RGB555 palette.

local ffi = require("ffi")
local Rgb555 = require("libs.codec.src.Rgb555")

local BattleEncounterIndexedRaster = {}

---@param indexRGBA8 string source indices in red and coverage in alpha
---@param width integer raster width
---@param height integer raster height
---@param paletteRGB555 table<integer, integer> displayed words keyed by one-based palette slot
---@return { width: integer, height: integer, pixels: string } sampled RGBA8 raster
function BattleEncounterIndexedRaster.render(indexRGBA8, width, height, paletteRGB555)
  assert(type(indexRGBA8) == "string", "source-index pixels are a byte string")
  assert(type(width) == "number" and width % 1 == 0 and width > 0, "source-index raster has a positive width")
  assert(type(height) == "number" and height % 1 == 0 and height > 0, "source-index raster has a positive height")
  assert(#indexRGBA8 == width * height * 4, "source-index bytes match their raster dimensions")
  assert(type(paletteRGB555) == "table", "source-index raster samples a displayed palette")
  local count = width * height
  local size = count * 4
  -- One 256-entry lookup from the referenced display words with the
  -- authoritative 5-to-8-bit rounding; absent slots stay nil so only a
  -- sampled visible slot can fail below.
  local reds = ffi.new("uint8_t[256]")
  local greens = ffi.new("uint8_t[256]")
  local blues = ffi.new("uint8_t[256]")
  local present = ffi.new("uint8_t[256]")
  for slot = 0, 255 do
    local word = paletteRGB555[slot + 1]
    if word ~= nil then
      local color = Rgb555.decode(word)
      reds[slot] = color.r
      greens[slot] = color.g
      blues[slot] = color.b
      present[slot] = 1
    end
  end
  -- Both inputs stay anchored in locals until the synchronous copy completes.
  local sourceBytes = indexRGBA8
  local source = ffi.cast("const uint8_t *", sourceBytes)
  local out = ffi.new("uint8_t[?]", size)
  for pixel = 0, count - 1 do
    local base = pixel * 4
    local slot = source[base]
    local alpha = source[base + 3]
    local target = pixel * 4
    if alpha == 0 then
      out[target] = 0
      out[target + 1] = 0
      out[target + 2] = 0
      out[target + 3] = 0
    else
      assert(present[slot] == 1, "visible source index has a displayed palette word")
      out[target] = reds[slot]
      out[target + 1] = greens[slot]
      out[target + 2] = blues[slot]
      out[target + 3] = alpha
    end
  end
  return { width = width, height = height, pixels = ffi.string(out, size) }
end

return BattleEncounterIndexedRaster
