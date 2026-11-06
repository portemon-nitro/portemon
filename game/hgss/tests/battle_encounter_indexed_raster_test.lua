-- Indexed battle art samples source slots from the displayed plane palette.

local Assert = require("tests.support.Assert")
local BattleEncounterIndexedRaster = require("game.hgss.src.battle.BattleEncounterIndexedRaster")
local Rgb555 = require("libs.codec.src.Rgb555")

local T = {}

function T.renders_indexed_pixels_from_the_selected_words_and_keeps_transparency()
  local indices = table.concat({
    string.char(0, 0, 0, 255),
    string.char(223, 0, 0, 255),
    string.char(4, 0, 0, 0),
    string.char(5, 0, 0, 255),
  })
  local palette = {
    [1] = Rgb555.encode(31, 0, 0),
    [224] = Rgb555.encode(0, 0, 31),
    [6] = Rgb555.encode(0, 31, 0),
  }
  local raster = BattleEncounterIndexedRaster.render(indices, 4, 1, palette)
  Assert.equal(raster.width, 4, "indexed mapping retains width")
  Assert.equal(raster.height, 1, "indexed mapping retains height")
  Assert.deepEqual({ raster.pixels:byte(1, 4) }, { 255, 0, 0, 255 }, "slot zero samples its displayed word")
  Assert.deepEqual({ raster.pixels:byte(5, 8) }, { 0, 0, 255, 255 }, "slot 223 remains a valid MAIN_OBJ word")
  Assert.deepEqual({ raster.pixels:byte(9, 12) }, { 0, 0, 0, 0 }, "transparent pixels need no palette word")
  Assert.deepEqual({ raster.pixels:byte(13, 16) }, { 0, 255, 0, 255 }, "indices select words instead of matching RGB")
end

function T.rejects_a_visible_index_without_a_displayed_palette_word()
  local indices = string.char(224, 0, 0, 255)
  local ok, failure = pcall(BattleEncounterIndexedRaster.render, indices, 1, 1, {})
  Assert.isFalse(ok, "source slot 224 is not defined by the 224-word MAIN_OBJ plane")
  Assert.isTrue(tostring(failure):find("displayed palette word", 1, true) ~= nil, "the missing slot is diagnosed")
end

function T.ignores_non_semantic_channels_and_preserves_modded_coverage()
  local indices = table.concat({
    string.char(3, 200, 77, 255),
    string.char(3, 0, 0, 128),
    string.char(0, 0, 0, 0),
  })
  local palette = {
    [1] = Rgb555.encode(0, 0, 0),
    [4] = Rgb555.encode(31, 0, 0),
  }
  local raster = BattleEncounterIndexedRaster.render(indices, 3, 1, palette)
  Assert.equal(raster.width, 3, "modded channels keep the raster width")
  Assert.equal(#raster.pixels, 12, "output length matches the packed source length")
  Assert.deepEqual({ raster.pixels:byte(1, 4) }, { 255, 0, 0, 255 }, "nonzero garbage channels never tint the sample")
  Assert.deepEqual(
    { raster.pixels:byte(5, 8) },
    { 255, 0, 0, 128 },
    "modded nonzero coverage is preserved instead of forced to opaque"
  )
  Assert.deepEqual({ raster.pixels:byte(9, 12) }, { 0, 0, 0, 0 }, "transparent coverage stays zero")
end

return { tests = T }
