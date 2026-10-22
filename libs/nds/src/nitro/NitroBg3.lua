-- CPU mechanics for tiled Nintendo DS BG3 planes: 4bpp palette banks,
-- 8bpp color indices, SCRN map entries, flips and mutable patches.

---@class NitroBg3
---@field _characters string packed indexed character tiles
---@field _colorMode "4bpp"|"8bpp" character pixel encoding
---@field _map { width: integer, height: integer, entries: table[] } owned mutable map
---@field _palette { colors: table[] } owned mutable RGB888 palette
---@field _transparentZero boolean whether palette index zero clears pixels
---@field _raster table<string, unknown>? last composed immutable surface
local NitroBg3 = {}
NitroBg3.__index = NitroBg3
local copyEntry
local copyColor

---@class NitroBg3.Options
---@field characters string packed indexed tile bytes
---@field colorMode "4bpp"|"8bpp" character pixel encoding
---@field map { width: integer, height: integer, entries: table[] } decoded SCRN map
---@field palette { colors: table[] } decoded RGB888 palette banks
---@field transparentZero boolean index-zero transparency policy

---@param opts NitroBg3.Options
---@return NitroBg3
function NitroBg3.new(opts)
  assert(type(opts) == "table", "BG3 requires decoded layer records")
  assert(opts.colorMode == "4bpp" or opts.colorMode == "8bpp", "BG3 declares its pixel encoding")
  local tileBytes = opts.colorMode == "4bpp" and 32 or 64
  assert(
    type(opts.characters) == "string" and #opts.characters % tileBytes == 0,
    "BG3 characters contain complete tiles"
  )
  assert(type(opts.map) == "table" and type(opts.map.entries) == "table", "BG3 requires its decoded map")
  local width, height = opts.map.width, opts.map.height
  assert(type(width) == "number" and width > 0 and width % 8 == 0, "BG3 map width is a positive tile span")
  assert(type(height) == "number" and height > 0 and height % 8 == 0, "BG3 map height is a positive tile span")
  assert(#opts.map.entries == width / 8 * (height / 8), "BG3 map entries cover its dimensions")
  assert(type(opts.palette) == "table" and type(opts.palette.colors) == "table", "BG3 requires decoded palette colors")
  local paletteSize = opts.colorMode == "4bpp" and 16 or 256
  assert(
    #opts.palette.colors >= paletteSize and #opts.palette.colors % paletteSize == 0,
    "BG3 palette contains complete color sets"
  )
  assert(type(opts.transparentZero) == "boolean", "BG3 declares index-zero behavior")
  local entries = {}
  for index, entry in ipairs(opts.map.entries) do
    entries[index] = copyEntry(entry)
  end
  local colors = {}
  for index, color in ipairs(opts.palette.colors) do
    colors[index] = copyColor(color)
  end
  return setmetatable({
    _characters = opts.characters,
    _colorMode = opts.colorMode,
    _map = { width = width, height = height, entries = entries },
    _palette = { colors = colors },
    _transparentZero = opts.transparentZero,
    _raster = nil,
  }, NitroBg3)
end

-- SCRN and palette indices are zero-based source indices.
---@param index integer zero-based screen entry
---@param entry table<string, unknown> normalized map entry
function NitroBg3:patchMap(index, entry)
  assert(type(index) == "number" and index % 1 == 0 and index >= 0, "map patch index is nonnegative")
  assert(self._map.entries[index + 1] ~= nil, "map patch index is in range")
  self._map.entries[index + 1] = copyEntry(entry)
  self._raster = nil
end

---@param index integer zero-based palette color
---@param color table<string, unknown> RGB888 color
function NitroBg3:patchPalette(index, color)
  assert(type(index) == "number" and index % 1 == 0 and index >= 0, "palette patch index is nonnegative")
  assert(self._palette.colors[index + 1] ~= nil, "palette patch index is in range")
  self._palette.colors[index + 1] = copyColor(color)
  self._raster = nil
end

---@class NitroBg3.Raster
---@field width integer raster width
---@field height integer raster height
---@field pixels string packed RGBA8 pixels

---@param raster NitroBg3.Raster immutable composed RGBA8 surface
---@param x integer pixel x
---@param y integer pixel y
---@return integer red
---@return integer green
---@return integer blue
---@return integer alpha
function NitroBg3.pixel(raster, x, y)
  assert(type(x) == "number" and x % 1 == 0 and x >= 0 and x < raster.width, "pixel x is within the raster")
  assert(type(y) == "number" and y % 1 == 0 and y >= 0 and y < raster.height, "pixel y is within the raster")
  local offset = (y * raster.width + x) * 4 + 1
  return raster.pixels:byte(offset, offset + 3)
end

---@return NitroBg3.Raster immutable composed RGBA8 surface
function NitroBg3:render()
  if self._raster ~= nil then
    return self._raster --[[@as NitroBg3.Raster]]
  end
  local width, height = self._map.width, self._map.height
  local pixels = {}
  local mapWidth = width / 8
  for y = 0, height - 1 do
    local tileY, localY = math.floor(y / 8), y % 8
    for x = 0, width - 1 do
      local tileX, localX = math.floor(x / 8), x % 8
      local entry = self._map.entries[tileY * mapWidth + tileX + 1]
      local sourceX = entry.flipH and 7 - localX or localX
      local sourceY = entry.flipV and 7 - localY or localY
      local colorIndex
      if self._colorMode == "4bpp" then
        local tile = assert(
          self._characters:byte(entry.tile * 32 + math.floor(sourceY / 2) * 4 + math.floor(sourceX / 2) + 1),
          "map tile references staged characters"
        )
        colorIndex = entry.palette * 16 + (sourceX % 2 == 0 and tile % 16 or math.floor(tile / 16))
      else
        colorIndex = assert(
          self._characters:byte(entry.tile * 64 + sourceY * 8 + sourceX + 1),
          "map tile references staged characters"
        )
      end
      local color = assert(self._palette.colors[colorIndex + 1], "map palette bank references staged colors")
      local alpha = (self._transparentZero and colorIndex == 0) and 0 or 255
      pixels[#pixels + 1] = string.char(color.r, color.g, color.b, alpha)
    end
  end
  ---@type NitroBg3.Raster
  local raster = { width = width, height = height, pixels = table.concat(pixels) }
  setmetatable(raster, { __index = NitroBg3 })
  self._raster = raster
  return raster
end

---@param entry table<string, unknown>
---@return table<string, unknown>
function copyEntry(entry)
  assert(type(entry) == "table", "BG3 map entries are records")
  assert(
    type(entry.tile) == "number" and entry.tile % 1 == 0 and entry.tile >= 0 and entry.tile < 1024,
    "BG3 map tile is ten bits"
  )
  assert(
    type(entry.palette) == "number" and entry.palette % 1 == 0 and entry.palette >= 0 and entry.palette < 16,
    "BG3 palette bank is four bits"
  )
  assert(type(entry.flipH) == "boolean" and type(entry.flipV) == "boolean", "BG3 map carries both flip bits")
  return { tile = entry.tile, flipH = entry.flipH, flipV = entry.flipV, palette = entry.palette }
end

---@param color table<string, unknown>
---@return table<string, unknown>
function copyColor(color)
  assert(type(color) == "table", "BG3 palette colors are records")
  local r, g, b = color.r, color.g, color.b
  for _, channel in ipairs({ r, g, b }) do
    assert(
      type(channel) == "number" and channel % 1 == 0 and channel >= 0 and channel <= 255,
      "BG3 RGB channels are bytes"
    )
  end
  return { r = r, g = g, b = b }
end

return NitroBg3
