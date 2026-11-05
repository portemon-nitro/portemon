-- Producer-side semantic inventory of the native options application
-- sources: NARC member selection, the resdat resource-set relationships,
-- the source animation/message roles, and the baseline face crop origins.
-- The audit basis is the retail ROM: members are identified by decoding
-- every member of the options archive through the production G2D decoders
-- and cross-checking the char/palette/cell/animation sets through the
-- resource lists and headers; the screen-18 selection overlay
-- and the Button Mode label row stay outside this contract. Pure data and
-- pure functions; no I/O. Never imported by runtime: libs/assets, game,
-- and script packages must not require this module.

local OptionsSources = {}

OptionsSources.provenance = {
  romAudit = "retail ROM",
}

-- Curated archive identities. NARC and NitroFS IDs are not interchangeable;
-- the symbol form is the only selector the compiler resolves. narcId 72 is
-- the catalog identity, never the physical ROM fileId the reader resolves.
OptionsSources.archive = { symbol = "NARC_a_0_7_2", path = "a/0/7/2", narcId = 72, memberCount = 20 }
OptionsSources.messagesArchive = { symbol = "NARC_msgdata_msg", path = "a/0/2/7" }
OptionsSources.messageBank = 45
OptionsSources.resdat = {
  symbol = "NARC_data_resdat",
  path = "a/1/7/5",
  lists = { animation = 20, cell = 21, char = 22, palette = 23 },
  headers = 77,
}

-- Audited member groups inside the options archive (zero-based).
-- Palettes 0 and 1 and chars 4, 5, and 6 serve the sprite sets through
-- the resdat lists; palette 2 and char 7 serve the MAIN base outside
-- those lists. Char 7 carries the 128-tile baseline face bank the
-- unselected patches crop; screen 17 is the 256x256 MAIN base. The SUB
-- base pairs palette 3 and char 8 with screen 19. Screen 18 is the
-- separate MAIN selected-row overlay, never an opaque base.
OptionsSources.members = {
  palettes = { 0, 1 },
  facePalette = 2,
  chars = { 4, 5, 6 },
  faceChar = 7,
  cells = { 9, 10, 11, 12 },
  animations = { 13, 14, 15, 16 },
  faceScreen = 17,
  previewPalette = 3,
  previewChar = 8,
  previewScreen = 19,
}

-- The two opaque source planes the generated backdrops compile, keyed by
-- their display binding. The selection overlay screen 18 stays outside
-- this table: it animates the selected row on MAIN_0, it never backs
-- the full plane. The MAIN base (screen 17, char 7, palette 2) carries
-- the 256x256 controls plane: the header shell band is pixel rows 0..23
-- (tile rows 0..2) and the footer shell band is pixel rows 168..191
-- (tile rows 21..23). Both bands keep their exact source entries; only
-- the scrolling row plates scrub the preprinted control faces.
OptionsSources.bases = {
  controls = { display = "MAIN" },
  preview = { display = "SUB" },
}

OptionsSources.bases.controls.paletteMember = OptionsSources.members.facePalette
OptionsSources.bases.controls.charMember = OptionsSources.members.faceChar
OptionsSources.bases.controls.screenMember = OptionsSources.members.faceScreen
OptionsSources.bases.preview.paletteMember = OptionsSources.members.previewPalette
OptionsSources.bases.preview.charMember = OptionsSources.members.previewChar
OptionsSources.bases.preview.screenMember = OptionsSources.members.previewScreen

-- The selected-row overlay member: a MAIN animation layer, not a base.
OptionsSources.selectionOverlayScreen = 18

-- Resource-set relationships transcribed from the options header set: each
-- entry names the char/palette/cell/animation resource ids the resdat lists
-- resolve to archive members. Set 0 carries the small/wide pills (sequences
-- 0/1 select the size), sets 1 and 2 carry the left/right frame arrows
-- (idle and pressed animation states), and set 3 carries the Confirm/Quit
-- action chrome (normal/focused/pressed/pressed-focused).
OptionsSources.sets = {
  pills = { char = 0, palette = 0, cell = 0, animation = 0 },
  leftArrow = { char = 1, palette = 0, cell = 1, animation = 1 },
  rightArrow = { char = 1, palette = 0, cell = 2, animation = 2 },
  actions = { char = 2, palette = 1, cell = 3, animation = 3 },
}

-- Message bank slots (zero-based) for the semantic labels. Only the
-- offered rows are exposed: the Button Mode name (slot 5), the legacy Slow
-- value (slot 9), and the unselected name/confirm values (slots 18/19)
-- stay outside the generated labels. Slots 7 and 8 carry a display prefix
-- control the tokenizer lowers through the shared message text.
OptionsSources.messages = {
  title = 0,
  textSpeed = 1,
  battleScene = 2,
  battleStyle = 3,
  soundMode = 4,
  textFrame = 6,
  confirm = 7,
  quit = 8,
  textSpeedValues = { mid = 10, fast = 11 },
  battleSceneValues = { on = 12, off = 13 },
  battleStyleValues = { shift = 14, set = 15 },
  soundModeValues = { stereo = 16, mono = 17 },
  firstFrameValue = 20,
  frameValueCount = 20,
  firstFramePreview = 40,
  framePreviewCount = 20,
}

-- Baseline face crop origins in baseline-screen pixels. The small patch
-- backs the small pill and the wide patch backs the wide pill; the crop
-- extents always come from the decoded pill frame footprints, never from
-- these origins.
OptionsSources.faceOrigins = {
  small = { x = 112, y = 24 },
  wide = { x = 112, y = 72 },
}

-- Audited material for the scrolling list row plates and the shell
-- bands, verified against the retail MAIN base (screen 17 with char 7
-- and palette 2). The header shell band is tile rows 0..2 (pixel rows
-- 0..23, the title band) and the footer shell band is tile rows 21..23
-- (pixel rows 168..191, the Confirm/Quit band); both keep exact source
-- entries with no scrubbing. The first two native 24px bands are the alternating row references: tile rows 3..5 carry
-- the odd band, tile rows 6..8 the even band. Columns 13..30 (x104..247)
-- are the control span: the tile scrub first hides the preprinted faces
-- behind the filler entry observed at interior column 4 of the same tile
-- row, then the staged plate levels every interior pixel inside the outer
-- window frame (x4..251, all but the top/bottom rows) to the mid-band
-- filler backing, so custom option layouts can relocate controls without
-- a baked native divider, separator, control-side backing, divider
-- remnant, or lighter edge-cap strip ghosting underneath. The recorded
-- filler tile ids are the cross-check expectation, so a source revision
-- carrying different backing material fails instead of shipping new art.
-- The outer frame keeps exact source pixels: the top/bottom rows carry
-- the row separators, column 0 starts the left window border, and the
-- right border columns close it, so every row type shares one interior
-- color per band behind one identical frame.
-- Observed tile palette entries: odd mid tile 12 is one flat color, even
-- mid tile 38 is one flat color, edge tiles 24/32 pair one backing color
-- with one edge line color. The compound frame
-- plate is 72px (9 tile rows): the odd top, mid, and bottom rows, then
-- the odd mid row five more times, closed by the odd bottom row; its
-- per-row fillers match oddFillers[1], [2], [3], [2] x5, [3].
OptionsSources.rowPlates = {
  oddBand = { topTileRow = 3, midTileRow = 4, bottomTileRow = 5 },
  evenBand = { topTileRow = 6, midTileRow = 7, bottomTileRow = 8 },
  faceFirstColumn = 13,
  faceLastColumn = 30,
  fillerColumn = 4,
  -- Expected filler tile per band tile row (top, mid, bottom), palette 0.
  oddFillers = { 24, 12, 24 },
  evenFillers = { 32, 38, 32 },
}

return OptionsSources
