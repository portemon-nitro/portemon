-- Producer-side bank keypad resource selectors and audited source geometry.
-- Source authority: src/field/number_entry.c (NumberEntry_Init, the sRodata
-- tables, NumberEntry_LoadSpriteResources/LoadBgGraphics) and
-- files/msgdata/msg/msg_0196.gmm. Every constant below is a source fact; the
-- compiler reads the ROM members this manifest names and never guesses.

local BankSources = {}

BankSources.provenance = {
  repo = "retail ROM",
}

-- The number-entry screen reads one archive: `NARC_New(NARC_a_2_3_6)` in
-- NumberEntry_Init. Members 8/9/10 are its BG palette/char/screen; the two
-- sprite resource groups load through NumberEntry_LoadSpriteResources.
BankSources.archive = {
  alias = "NARC_a_2_3_6",
  symbol = "NARC_a_2_3_6",
  resources = {
    -- NumberEntry_LoadBgGraphics: char member 9 and screen member 10 on
    -- GF_BG_LYR_SUB_1, palette member 8 at sub-BG slot 0.
    bg = { char = 9, palette = 8, screen = 10 },
    -- The digit pad's sprite resources: char 5, pltt 4, cell 6, anim 7.
    pad = { char = 5, palette = 4, cell = 6, animation = 7 },
    -- The entered digit glyphs' sprite resources: char 1, pltt 0, cell 2,
    -- anim 3.
    digit = { char = 1, palette = 0, cell = 2, animation = 3 },
  },
}

-- NumberEntry_CreateButtonLabels reads msg_0196_00024 + i for its three
-- windows: BACK, CONFIRM and QUIT.
BankSources.messages = {
  archive = { alias = "messages", symbol = "NARC_msgdata_msg" },
  bank = 196,
  roles = {
    back = 24,
    confirm = 25,
    quit = 26,
  },
}

-- The bottom display the keypad paints on.
BankSources.display = { width = 256, height = 192 }

-- NUMBER_ENTRY_MAX_DIGITS.
BankSources.maxDigits = 6

-- sRodata.padHitboxes: five 48-pixel digit columns from x 8, digits 0-4 on the
-- first row at y 56 and 5-9 on the second at y 104, then the three action
-- buttons on their own 32-pixel row at y 160.
BankSources.digitGrid = {
  originX = 8,
  originY = 56,
  cell = 48,
  columns = 5,
}
BankSources.actionRow = {
  y = 160,
  height = 32,
  keys = {
    { key = "back", x = 0, width = 80 },
    { key = "confirm", x = 88, width = 80 },
    { key = "quit", x = 176, width = 80 },
  },
}

-- sRodata.padDpadBoxes: the walkable grid. A neighbour with bit 7 set names a
-- digit-row position after the source's mode switch, so the table records the
-- destination position each direction reaches.
BankSources.dpadBoxes = {
  { x = 32, y = 80, up = 0, down = 5, left = 4, right = 1 },
  { x = 80, y = 80, up = 1, down = 6, left = 0, right = 2 },
  { x = 128, y = 80, up = 2, down = 7, left = 1, right = 3 },
  { x = 176, y = 80, up = 3, down = 8, left = 2, right = 4 },
  { x = 224, y = 80, up = 4, down = 9, left = 3, right = 0 },
  { x = 32, y = 128, up = 0, down = 10, left = 9, right = 6 },
  { x = 80, y = 128, up = 1, down = 10, left = 5, right = 7 },
  { x = 128, y = 128, up = 2, down = 11, left = 6, right = 8 },
  { x = 176, y = 128, up = 3, down = 12, left = 7, right = 9 },
  { x = 224, y = 128, up = 4, down = 12, left = 8, right = 5 },
  { x = 40, y = 176, up = 5, down = 10, left = 12, right = 11 },
  { x = 128, y = 176, up = 7, down = 11, left = 10, right = 12 },
  { x = 216, y = 176, up = 9, down = 12, left = 11, right = 10 },
}

-- sRodata.xOffsets, indexed by the entry's digit count: the x of each entered
-- digit glyph and of the underline cursor.
BankSources.digitCellOffsets = {
  [1] = { 0x80 },
  [2] = { 0x70, 0x90 },
  [3] = { 0x60, 0x80, 0xA0 },
  [4] = { 0x50, 0x70, 0x90, 0xB0 },
  [5] = { 0x40, 0x60, 0x80, 0xA0, 0xC0 },
  [6] = { 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0 },
}
-- The entered digits ride the entry row and the underline one row below
-- (NumberEntry_CreateSprite offsets the whole sub layer by 256 pixels).
BankSources.digitRowY = 280 - 256
BankSources.cursorRowY = 292 - 256
-- The source hitboxes that select a digit cell for editing: one 32x32 strip
-- around each cell's own x offset on the entry row.
BankSources.cursorStrip = { top = 8, width = 32, height = 32 }

-- sRodata.spriteSpecs: { x, y, drawPriority, animation sequence } for the five
-- pad sprites (cursor, underline, back, confirm, quit) and the six digit
-- glyphs. The cursor's second sequence is the action-row variant.
BankSources.sprites = {
  cursor = { animation = 1, x = 0x20, y = 0x20 },
  cursorButton = { animation = 2, x = 0x20, y = 0x20 },
  underline = { animation = 0, x = 0x30, y = 0x24 },
  back = { animation = 3, x = 0x28, y = 0xB0 },
  confirm = { animation = 3, x = 0x80, y = 0xB0 },
  quit = { animation = 3, x = 0xD8, y = 0xB0 },
  -- digits[d] draws seq d + 1 at the cell anchor the open digit count names.
  digitFirstAnimation = 1,
}

-- NumberEntry_UpdateBlink: the first frame holds four ticks, the second two.
BankSources.blink = { firstTicks = 4, secondTicks = 2, width = 6, height = 6 }

return BankSources
