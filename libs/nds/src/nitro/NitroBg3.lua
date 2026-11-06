-- CPU mechanics for tiled Nintendo DS BG3 planes: 4bpp palette banks,
-- 8bpp color indices, SCRN map entries, flips and mutable patches.

local ffi = require("ffi")

---@class NitroBg3
---@field _characters string packed indexed character tiles
---@field _colorMode "4bpp"|"8bpp" character pixel encoding
---@field _map { width: integer, height: integer, entries: table[] } owned mutable map
---@field _palette { colors: table[] } owned mutable RGB888 palette
---@field _transparentZero boolean whether palette index zero clears pixels
---@field _indexPlane table<integer, integer>? cached effective palette index per pixel
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
---@field transparentZero boolean index-zero behavior policy

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
  -- Trusted staged reads land here already decoded: copy the records
  -- without a per-entry numeric census. Tile, byte, and palette bounds
  -- still fail at their actual indexed access during composition.
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
    _indexPlane = nil,
    _raster = nil,
  }, NitroBg3)
end

-- SCRN and palette indices are zero-based source indices.
---@param index integer zero-based screen entry
---@param entry table<string, unknown> normalized map entry
function NitroBg3:patchMap(index, entry)
  assert(type(index) == "number" and index % 1 == 0 and index >= 0, "map patch index is nonnegative")
  assert(self._map.entries[index + 1] ~= nil, "map patch index is in range")
  assert(type(entry) == "table", "map patches carry normalized entries")
  assert(
    type(entry.tile) == "number" and entry.tile % 1 == 0 and entry.tile >= 0 and entry.tile < 1024,
    "map patches carry a 10-bit tile index"
  )
  assert(
    type(entry.palette) == "number" and entry.palette % 1 == 0 and entry.palette >= 0 and entry.palette < 16,
    "map patches carry a 4-bit palette bank"
  )
  assert(type(entry.flipH) == "boolean" and type(entry.flipV) == "boolean", "map patches carry both flip bits")
  self._map.entries[index + 1] = copyEntry(entry)
  self._indexPlane = nil
  self._raster = nil
end

---@param index integer zero-based palette color
---@param color table<string, unknown> RGB888 color
function NitroBg3:patchPalette(index, color)
  assert(type(index) == "number" and index % 1 == 0 and index >= 0, "palette patch index is nonnegative")
  assert(self._palette.colors[index + 1] ~= nil, "palette patch index is in range")
  assert(type(color) == "table", "palette patches carry RGB colors")
  for _, channel in ipairs({ color.r, color.g, color.b }) do
    assert(
      type(channel) == "number" and channel % 1 == 0 and channel >= 0 and channel <= 255,
      "RGB888 channels are bytes"
    )
  end
  self._palette.colors[index + 1] = copyColor(color)
  self._raster = nil
end

-- Applies one complete staged palette in a single update: every word is
-- checked before any owned color changes, so a malformed bank never
-- publishes a half-replaced plane. An identical palette keeps the cached
-- raster; a changed one recolors the cached index plane without any map
-- traversal.
---@param colors table<integer, { r: integer, g: integer, b: integer }> 256 staged RGB888 colors
function NitroBg3:replacePalette(colors)
  assert(type(colors) == "table" and #colors == 256, "palette replacement carries 256 staged colors")
  local staged = {}
  for index = 1, 256 do
    local color = colors[index]
    assert(type(color) == "table", "palette replacement carries RGB colors")
    for _, channel in ipairs({ color.r, color.g, color.b }) do
      assert(
        type(channel) == "number" and channel % 1 == 0 and channel >= 0 and channel <= 255,
        "RGB888 channels are bytes"
      )
    end
    staged[index] = { r = color.r, g = color.g, b = color.b }
  end
  local current = self._palette.colors
  local identical = #current == 256
  if identical then
    for index = 1, 256 do
      local owned, next = current[index], staged[index]
      if owned.r ~= next.r or owned.g ~= next.g or owned.b ~= next.b then
        identical = false
        break
      end
    end
  end
  if identical then
    return
  end
  self._palette = { colors = staged }
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

-- Decodes the tiled map into the cached per-pixel index plane once per
-- characters/map identity: every pixel keeps its effective palette index
-- across palette changes, so recolors never walk tiles again. The plane
-- rebuilds only after a map patch.
---@param bg NitroBg3
---@return table<integer, integer> effective palette index per pixel
local function indexPlaneFor(bg)
  local cached = bg._indexPlane
  if cached ~= nil then
    return cached
  end
  local width, height = bg._map.width, bg._map.height
  local characters = bg._characters
  local charLen = #characters
  local source = ffi.cast("const uint8_t *", characters)
  local mapWidth = width / 8
  local plane = {}
  local tileBytes = bg._colorMode == "4bpp" and 32 or 64
  local tileCount = charLen / tileBytes
  local nextSlot = 1
  for y = 0, height - 1 do
    local tileY, localY = math.floor(y / 8), y % 8
    for x = 0, width - 1 do
      local tileX, localX = math.floor(x / 8), x % 8
      local entry = bg._map.entries[tileY * mapWidth + tileX + 1]
      local sourceX = entry.flipH and 7 - localX or localX
      local sourceY = entry.flipV and 7 - localY or localY
      assert(
        type(entry.tile) == "number" and entry.tile % 1 == 0 and entry.tile >= 0 and entry.tile < tileCount,
        "map tile references staged characters"
      )
      local colorIndex
      -- Hardware 4bpp tiles pack eight rows of four bytes, so every
      -- source row addresses its own bytes: even rows never repeat.
      if bg._colorMode == "4bpp" then
        assert(
          type(entry.palette) == "number" and entry.palette % 1 == 0 and entry.palette >= 0 and entry.palette < 16,
          "map palette bank is four bits"
        )
        local byteOffset = entry.tile * 32 + sourceY * 4 + math.floor(sourceX / 2)
        assert(byteOffset >= 0 and byteOffset < charLen, "map tile references staged characters")
        local tile = source[byteOffset]
        colorIndex = entry.palette * 16 + (sourceX % 2 == 0 and tile % 16 or math.floor(tile / 16))
      else
        local byteOffset = entry.tile * 64 + sourceY * 8 + sourceX
        assert(byteOffset >= 0 and byteOffset < charLen, "map tile references staged characters")
        colorIndex = source[byteOffset]
      end
      plane[nextSlot] = colorIndex
      nextSlot = nextSlot + 1
    end
  end
  bg._indexPlane = plane
  return plane
end

---@return NitroBg3.Raster immutable composed RGBA8 surface
function NitroBg3:render()
  if self._raster ~= nil then
    return self._raster --[[@as NitroBg3.Raster]]
  end
  local width, height = self._map.width, self._map.height
  local plane = indexPlaneFor(self)
  local colors = self._palette.colors
  -- The character anchors stay alive for the synchronous copy below.
  local held = self._characters
  assert(held ~= nil, "BG3 composition anchors its character bytes")
  local count = width * height
  local size = count * 4
  -- Only sampled palette words are ever validated: a modded word no
  -- composed pixel references never blocks the raster.
  local reds = ffi.new("uint8_t[?]", #colors)
  local greens = ffi.new("uint8_t[?]", #colors)
  local blues = ffi.new("uint8_t[?]", #colors)
  local expanded = ffi.new("uint8_t[?]", #colors)
  local transparentZero = self._transparentZero
  local out = ffi.new("uint8_t[?]", size)
  for pixel = 0, count - 1 do
    local colorIndex = plane[pixel + 1]
    assert(
      type(colorIndex) == "number" and colorIndex % 1 == 0 and colorIndex >= 0 and colorIndex < #colors,
      "map palette bank references staged colors"
    )
    if expanded[colorIndex] == 0 then
      local color = colors[colorIndex + 1]
      assert(
        type(color) == "table"
          and type(color.r) == "number"
          and color.r % 1 == 0
          and color.r >= 0
          and color.r <= 255
          and type(color.g) == "number"
          and color.g % 1 == 0
          and color.g >= 0
          and color.g <= 255
          and type(color.b) == "number"
          and color.b % 1 == 0
          and color.b >= 0
          and color.b <= 255,
        "map palette bank references staged colors"
      )
      reds[colorIndex] = color.r
      greens[colorIndex] = color.g
      blues[colorIndex] = color.b
      expanded[colorIndex] = 1
    end
    local target = pixel * 4
    out[target] = reds[colorIndex]
    out[target + 1] = greens[colorIndex]
    out[target + 2] = blues[colorIndex]
    out[target + 3] = (transparentZero and colorIndex == 0) and 0 or 255
  end
  ---@type NitroBg3.Raster
  local raster = { width = width, height = height, pixels = ffi.string(out, size) }
  setmetatable(raster, { __index = NitroBg3 })
  self._raster = raster
  return raster
end

---@param entry table<string, unknown>
---@return table<string, unknown>
function copyEntry(entry)
  assert(type(entry) == "table", "BG3 map entries are records")
  return { tile = entry.tile, flipH = entry.flipH, flipV = entry.flipV, palette = entry.palette }
end

---@param color table<string, unknown>
---@return table<string, unknown>
function copyColor(color)
  assert(type(color) == "table", "BG3 palette colors are records")
  return { r = color.r, g = color.g, b = color.b }
end

return NitroBg3
