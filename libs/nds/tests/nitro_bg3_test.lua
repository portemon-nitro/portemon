-- BG3 raster vectors cover tile addressing, map flips, palette banks and
-- mutable map/palette patches without requiring LÖVE or a ROM.

local Assert = require("tests.support.Assert")
local NitroBg3 = require("libs.nds.src.nitro.NitroBg3")

local T = {}

-- Hardware 4bpp tiles pack eight rows of four bytes: byte four holds row
-- one, so each source row reads its own bytes instead of its even
-- neighbor. This vector pins rows the row-zero-only coverage missed.
function T.renders_packed_tile_rows_with_hardware_byte_layout()
  local tile = string.char(0x21) .. string.rep("\0", 3) .. string.char(0x43) .. string.rep("\0", 27)
  local colors = {}
  for index = 0, 31 do
    colors[index + 1] = { r = index, g = index + 1, b = index + 2 }
  end
  local bg = NitroBg3.new({
    characters = tile,
    map = { width = 8, height = 8, entries = {
      { tile = 0, flipH = false, flipV = false, palette = 0 },
    } },
    palette = { colors = colors },
    colorMode = "4bpp",
    transparentZero = false,
  })
  local raster = bg:render()
  Assert.deepEqual({ raster:pixel(0, 0) }, { 1, 2, 3, 255 }, "row zero reads byte zero")
  Assert.deepEqual({ raster:pixel(0, 1) }, { 3, 4, 5, 255 }, "row one reads byte four")
  Assert.deepEqual({ raster:pixel(1, 1) }, { 4, 5, 6, 255 }, "row one advances nibbles within its own byte")
end

function T.renders_packed_tiles_with_map_flips_palette_banks_and_patches()
  local tile = string.char(0x21) .. string.rep("\0", 31)
  local chars = tile .. string.rep("\0", 32)
  local colors = {}
  for index = 0, 31 do
    colors[index + 1] = { r = index, g = index + 1, b = index + 2 }
  end
  local bg = NitroBg3.new({
    characters = chars,
    map = {
      width = 16,
      height = 8,
      entries = {
        { tile = 0, flipH = false, flipV = false, palette = 0 },
        { tile = 0, flipH = true, flipV = false, palette = 1 },
      },
    },
    palette = { colors = colors },
    colorMode = "4bpp",
    transparentZero = false,
  })

  local first = bg:render()
  Assert.equal(bg:render(), first, "unchanged BG state reuses its composed surface")
  Assert.deepEqual({ first.width, first.height }, { 16, 8 }, "the map determines its raster size")
  Assert.deepEqual({ first:pixel(0, 0) }, { 1, 2, 3, 255 }, "low nibble uses the first palette bank")
  Assert.deepEqual({ first:pixel(1, 0) }, { 2, 3, 4, 255 }, "high nibble is the next pixel")
  Assert.deepEqual({ first:pixel(8, 0) }, { 16, 17, 18, 255 }, "map flip and palette bank select source color")

  bg:patchMap(1, { tile = 1, flipH = false, flipV = false, palette = 0 })
  bg:patchPalette(1, { r = 90, g = 91, b = 92 })
  local patched = bg:render()
  Assert.isTrue(patched ~= first, "patches invalidate the cached composed surface")
  Assert.deepEqual({ patched:pixel(0, 0) }, { 90, 91, 92, 255 }, "palette patches change composed pixels")
  Assert.deepEqual({ patched:pixel(8, 0) }, { 0, 1, 2, 255 }, "map patches change selected tile pixels")
  Assert.deepEqual({ first:pixel(0, 0) }, { 1, 2, 3, 255 }, "published raster snapshots remain stable")
end

function T.renders_native_8bpp_tiles_without_nibble_or_palette_bank_indexing()
  local tile = string.char(0x21) .. string.rep("\0", 63)
  local colors = {}
  for index = 0, 255 do
    colors[index + 1] = { r = index, g = 255 - index, b = index % 2 }
  end
  local bg = NitroBg3.new({
    characters = tile,
    map = { width = 8, height = 8, entries = {
      { tile = 0, flipH = false, flipV = false, palette = 0 },
    } },
    palette = { colors = colors },
    colorMode = "8bpp",
    transparentZero = false,
  })

  local raster = bg:render()
  Assert.deepEqual({ raster:pixel(0, 0) }, { 33, 222, 1, 255 }, "8bpp pixels use the whole byte as a palette index")
  Assert.deepEqual({ raster:pixel(1, 0) }, { 0, 255, 0, 255 }, "8bpp pixels advance one byte per pixel")
end

return { tests = T }
