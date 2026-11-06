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

function T.reuses_its_index_plane_across_palette_updates()
  local tile = string.char(0x21) .. string.rep("\0", 31)
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
  bg:render()
  local plane = assert(bg._indexPlane, "the first render builds the cached index plane")
  bg:patchPalette(1, { r = 90, g = 91, b = 92 })
  local repainted = bg:render()
  Assert.isTrue(bg._indexPlane == plane, "palette-only changes keep the cached index plane")
  Assert.deepEqual({ repainted:pixel(0, 0) }, { 90, 91, 92, 255 }, "palette changes still recolor composed pixels")
  bg:patchMap(0, { tile = 0, flipH = false, flipV = false, palette = 1 })
  Assert.isNil(bg._indexPlane, "map patches invalidate the cached index plane")
  local remapped = bg:render()
  Assert.isTrue(bg._indexPlane ~= nil and bg._indexPlane ~= plane, "the next render rebuilds the index plane")
  Assert.deepEqual({ remapped:pixel(0, 0) }, { 17, 18, 19, 255 }, "map patches change selected tile pixels")
end

function T.replaces_the_full_palette_in_one_atomic_update()
  local tile = string.char(0x21) .. string.rep("\0", 31)
  local colors = {}
  for index = 0, 255 do
    colors[index + 1] = { r = index % 256, g = (index + 1) % 256, b = (index + 2) % 256 }
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
  local first = bg:render()
  local plane = assert(bg._indexPlane, "the first render builds the cached index plane")
  local faded = {}
  for index = 1, 256 do
    faded[index] = { r = (index * 3) % 256, g = (index * 5) % 256, b = (index * 7) % 256 }
  end
  bg:replacePalette(faded)
  Assert.isTrue(bg._indexPlane == plane, "the atomic update keeps the cached index plane")
  local second = bg:render()
  Assert.isTrue(second ~= first, "changed colors compose a new raster")
  Assert.deepEqual(
    { second:pixel(1, 0) },
    { faded[3].r, faded[3].g, faded[3].b, 255 },
    "the atomic update recolors through the new palette"
  )
  bg:replacePalette(faded)
  Assert.equal(bg:render(), second, "identical colors reuse the cached raster")
end

function T.tolerates_unreferenced_palette_words_without_a_construction_census()
  local tile = string.rep("\0", 32)
  local colors = {}
  for index = 0, 31 do
    colors[index + 1] = { r = 8, g = 16, b = 24 }
  end
  colors[32] = { r = 999, g = 0, b = 0 }
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
  Assert.deepEqual({ raster:pixel(0, 0) }, { 8, 16, 24, 255 }, "referenced words still compose")
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
