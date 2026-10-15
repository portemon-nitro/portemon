-- Producer-side source facts for the shared move icons: the type and
-- damage-category sprites that the Bag move summary and the Summary
-- screen both draw. Audited against asm/unk_02077678.s: the table at
-- _02100048 carries the type char members in its first 18 entries (indexed
-- by sub_02077678), the table at _021000A4 the 18 type palette overrides
-- (sub_0207769C), the table at _0210003C {0xF4, 0xF6, 0xF5} as the category
-- char members (sub_02077800), and the table at _02100038 {0, 1, 0} as the
-- category palette overrides (sub_02077818); the shared palette/cell/
-- animation members and the NARC 8 archive identity come from the
-- sub_02077690, sub_02077694, sub_02077698, and sub_020776B4 selectors.
-- Resource kinds and source compression state come from
-- files/data/resdat/resdat_00000024.json (animation member 243,
-- compressed), resdat_00000025.json (cell member 242, compressed),
-- resdat_00000026.json (char member 234, compressed), and
-- resdat_00000055.json (palette member 74, uncompressed). Pure data; no
-- I/O. Never imported by runtime.

local MoveIconSources = {}

MoveIconSources.archive = { alias = "NARC_a_0_0_8", symbol = "NARC_a_0_0_8" }

MoveIconSources.shared = { palette = 74, cell = 242, animation = 243, frame = 0 }

-- Character member by type id (include/constants/pokemon.h TYPE_*).
MoveIconSources.typeChars = {
  [0] = 234,
  [1] = 225,
  [2] = 227,
  [3] = 235,
  [4] = 229,
  [5] = 237,
  [6] = 231,
  [7] = 228,
  [8] = 238,
  [9] = 236,
  [10] = 226,
  [11] = 241,
  [12] = 233,
  [13] = 222,
  [14] = 223,
  [15] = 230,
  [16] = 221,
  [17] = 224,
}

-- Palette bank by type id plus one.
MoveIconSources.typePaletteOverrides = { 0, 0, 1, 1, 0, 0, 2, 1, 0, 2, 0, 1, 2, 0, 1, 1, 2, 0 }

-- Character member by damage category id.
MoveIconSources.categoryChars = { [0] = 244, [1] = 246, [2] = 245 }

-- Palette bank by damage category id plus one.
MoveIconSources.categoryPaletteOverrides = { 0, 1, 0 }

return MoveIconSources
