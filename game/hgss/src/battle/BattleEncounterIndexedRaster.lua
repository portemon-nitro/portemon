-- Samples one source-indexed RGBA8 image from its displayed RGB555 palette.

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
  local pixels = {}
  for offset = 1, #indexRGBA8, 4 do
    local slot = string.byte(indexRGBA8, offset)
    local green = string.byte(indexRGBA8, offset + 1)
    local blue = string.byte(indexRGBA8, offset + 2)
    local alpha = string.byte(indexRGBA8, offset + 3)
    assert(slot ~= nil and green == 0 and blue == 0, "source-index pixels encode only an index and alpha")
    assert(alpha == 0 or alpha == 255, "source-index pixels use binary coverage")
    if alpha == 0 then
      pixels[#pixels + 1] = "\0\0\0\0"
    else
      local word = assert(paletteRGB555[slot + 1], "visible source index has a displayed palette word")
      local color = Rgb555.decode(word)
      pixels[#pixels + 1] = string.char(color.r, color.g, color.b, 255)
    end
  end
  return { width = width, height = height, pixels = table.concat(pixels) }
end

return BattleEncounterIndexedRaster
