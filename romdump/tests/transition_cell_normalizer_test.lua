local Assert = require("tests.support.Assert")
local TransitionCellNormalizer = require("romdump.src.digest.battle.TransitionCellNormalizer")

local T = {}

function T.normalizes_nitro_obj_units_to_character_tile_indices()
  local fourBpp = { cells = { { objs = { { tile = 3 } } } } }
  local eightBpp = { cells = { { objs = { { tile = 3 } } } } }
  TransitionCellNormalizer.normalize(fourBpp, 2, 3)
  TransitionCellNormalizer.normalize(eightBpp, 2, 4)
  Assert.equal(fourBpp.cells[1].objs[1].tile, 12, "4bpp unit stride multiplies the source tile base by mapping scale")
  Assert.equal(eightBpp.cells[1].objs[1].tile, 6, "8bpp unit stride converts source 32-byte units to 64-byte tiles")
end

function T.mapping_zero_preserves_the_source_tile_base()
  local cells = { cells = { { objs = { { tile = 7 } } } } }
  TransitionCellNormalizer.normalize(cells, 0, 3)
  Assert.equal(cells.cells[1].objs[1].tile, 7, "32-byte mapping already addresses one 4bpp character tile")
end

return { tests = T }
