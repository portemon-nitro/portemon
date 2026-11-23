-- Source selectors and shared geometry for the retained HGSS PC applications.
-- Overlay call sites were verified against the retail ROM.

local PcSources = {}

PcSources.provenance = {
  romAudit = "retail ROM",
}

PcSources.archives = {
  storage = { alias = "NARC_a_0_1_9", path = "a/0/1/9", memberCount = 87, selectedMemberCount = 87 },
  -- The message-printer glyph bank: member 5 holds the small bitmaps the box
  -- info panel blits raw ("Lv."/"No."), member 7 the font palette their
  -- two-bit pixels index.
  font = { alias = "NARC_graphic_font", path = "a/0/1/6", memberCount = 11, selectedMemberCount = 11 },
  -- The shared confirmation-prompt art: palette, characters, then the four
  -- compact 48x32 button tilemaps (and the unused wide shape).
  touch_subwindow = {
    alias = "NARC_system_touch_subwindow",
    path = "a/1/5/2",
    memberCount = 10,
    selectedMemberCount = 10,
  },
  mailbox = { alias = "NARC_a_2_5_0", path = "a/2/5/0", memberCount = 11, selectedMemberCount = 11 },
  -- Member 36 is the shared write-mode button tilemap: the write chrome
  -- pairs it with each type's own character tile set (palette 0..11,
  -- character 12..23, screen 24..35).
  stationery = { alias = "NARC_a_0_7_9", path = "a/0/7/9", memberCount = 37, selectedMemberCount = 37 },
  photoAlbum = { alias = "NARC_a_1_7_1", path = "a/1/7/1", memberCount = 13, selectedMemberCount = 13 },
}

PcSources.wallpaperIds = {}
for wallpaperId = 0, 15 do
  PcSources.wallpaperIds[#PcSources.wallpaperIds + 1] = wallpaperId
end
for wallpaperId = 32, 39 do
  PcSources.wallpaperIds[#PcSources.wallpaperIds + 1] = wallpaperId
end

PcSources.stationeryTypes = {}
for stationeryType = 0, 11 do
  PcSources.stationeryTypes[#PcSources.stationeryTypes + 1] = stationeryType
end
-- Mail type order follows the retail ROM's mail table and the names remain the
-- existing ItemCatalog keys from ItemSources.itemKeys.
PcSources.stationeryItemKeys = {
  "GRASS_MAIL",
  "FLAME_MAIL",
  "BUBBLE_MAIL",
  "BLOOM_MAIL",
  "TUNNEL_MAIL",
  "STEEL_MAIL",
  "HEART_MAIL",
  "SNOW_MAIL",
  "SPACE_MAIL",
  "AIR_MAIL",
  "MOSAIC_MAIL",
  "BRICK_MAIL",
}

PcSources.mailboxBackground = { role = "mainBg3", character = 1, screen = 0, palette = 2, engine = "main", bg = 3 }
PcSources.mailboxLoaderRoles = {
  ov103_021ECC1C = {
    { role = "subBg7", character = 5, screen = 4, palette = 6, engine = "sub", bg = 7 },
    { role = "mainBg3", character = 1, screen = 0, palette = 2, engine = "main", bg = 3 },
    { role = "mainBg1", character = 1, engine = "main", bg = 1 },
  },
  mailboxBackground = { role = "mainBg3", character = 1, screen = 0, palette = 2, engine = "main", bg = 3 },
}
PcSources.photoAlbumBackgrounds = {
  {
    role = "albumCanvas",
    character = 9,
    palette = 4,
    screen = 10,
    bg = 6,
  },
  {
    role = "albumControls",
    character = 5,
    palette = 4,
    screen = 6,
    bg = 3,
  },
}
PcSources.wallpaperMembers = { characterBase = 16, paletteBase = 40, screen = 15 }
PcSources.stationeryMembers = { paletteBase = 0, characterBase = 12, screenBase = 24 }
-- Write-mode source selection behind the stationery write chrome
-- (application/mail_view.c MailView_LoadBgGraphics): member 36 carries
-- the shared button tilemap; the write palette views the type palette's
-- bytes 0x60..0x7F at display bank 1; the cursor pulse modifies display
-- entry 0x22 plus the cursor position through an RGB5 blend to white;
-- the top display repeats tile 1 at palette 2. The five highlight
-- controls follow source cursor order: three line windows, Confirm,
-- then Cancel. Geometry is logical source pixels.
PcSources.stationeryWrite = {
  buttonScreen = 36,
  writePaletteByteBase = 0x60,
  writePaletteBank = 1,
  highlightEntryBase = 0x22,
  highlightLevelMax = 13,
  backdropTile = 1,
  backdropPalette = 2,
  controls = {
    { x = 24, y = 24, width = 208, height = 32 },
    { x = 24, y = 64, width = 208, height = 32 },
    { x = 24, y = 104, width = 208, height = 32 },
    { x = 24, y = 148, width = 64, height = 24 },
    { x = 160, y = 148, width = 64, height = 24 },
  },
  -- G2_SetBlendAlpha(BG2, BG3, 28, 4): the hardware saturates the
  -- coefficients to 16 and 4 over a divisor of 16.
  blendEvA = 16,
  blendEvB = 4,
  blendDivisor = 16,
  -- The touch pixel test rejects BG2 character pixel index 1.
  touchRejectIndex = 1,
}
-- The shared touchscreen list-menu graphics behind the Mailbox action menu
-- (mailbox_app.c sMailboxMailMenuTemplate via TouchscreenListMenuSpawner):
-- data/sbox_gra carries the 8x8 frame tiles in member 1 and their palette in
-- member 0, the same pair the Pokegear context menus draw with.
PcSources.listMenu = { path = "a/1/6/5", char = 1, palette = 0 }

-- ov14_021F5950 selects the byte offsets; member65 banks0/1 load to
-- MAIN_BG slots12/13, and Window.paletteNum selects the palette.
PcSources.storageWindowFrames = {
  character = 64,
  palette = 65,
  styles = {
    standard = { characterByteOffset = 0 },
    accent = { characterByteOffset = 384 },
  },
  tileCount = 12,
  paletteBankCount = 2,
  destinationPaletteBase = 12,
  -- PCBox_DrawButtonWindow fills the plate interior with window palette entry 4
  -- (style 0) or 11 (style 1); both live in member 65 bank 0.
  fillEntry = 4,
  accentFillEntry = 11,
}
-- PCBox_DrawTabWindow (tray MOVE / SORT ITEMS tab) and PCBox_DrawSummaryButton
-- compose their plates from member 14 tiles through BG cell palette bank 2:
-- an 8px left cap, a repeatable 8px middle and an 8px right cap per 8px row.
PcSources.storagePlateRoles = {
  tab = {
    palette = 4,
    paletteBank = 2,
    left = { 87, 91, 89 },
    middle = { 88, 92, 90 },
    right = { 107, 105, 106 },
  },
  summary = {
    palette = 4,
    paletteBank = 2,
    left = { 61, 93, 125 },
    middle = { 97, 101, 100 },
    right = { 104, 103, 102 },
  },
}
-- The marking editor writes one 8x8 member-14 tile per mark into the member-10
-- panel map, keeping the cell's palette bank (member 4 bank 1).
PcSources.storagePanelMarkings = {
  character = 14,
  palette = 4,
  paletteBank = 1,
  clearTileBase = 11,
  setTileBase = 43,
  count = 6,
}
-- ov14_021E895C writes these source tile IDs to BG5 from member 6; ov14_021E5C54
-- loads member 7 into BG palette bank zero.
PcSources.storageMarkings = {
  character = 6,
  palette = 7,
  paletteBank = 0,
  clearTileBase = 0x1a,
  setTileBase = 0x3a,
  count = 6,
}
-- ov14_021E5C54 loads member 1 (character) and member 0 (screen) into main
-- BG3, the touch screen's cream base under the wallpaper tilemap; the palette
-- is the member 4 bank shared with the box pane.
PcSources.storageBaseMembers = { character = 1, palette = 4, screen = 0 }
-- BG loaders in ov14_021E5C54 install these paired screen/character/palette
-- compositions for the Storage application.
-- boxPane: main BG2 (touch screen); infoPane: sub BG5 (top screen);
-- partyTray: the 88x144 strip drawn to main BG1 at (168,48) while open
-- (ov14_021E7BA4 strip manager; member 14 is the shared strip character set).
PcSources.storageUiMembers = {
  boxPane = { character = 3, palette = 4, screen = 2 },
  infoPane = { character = 6, palette = 7, screen = 5 },
  partyTray = { character = 14, palette = 4, screen = 9 },
  -- Move and Move-Items modes load member 8, whose lower band carries the
  -- SWITCH/EXIT label plate that Deposit/Withdraw's member 9 leaves flat.
  partyTrayMove = { character = 14, palette = 4, screen = 8 },
  -- The Marking editor's panel strip, drawn to main BG0 at (168,48).
  markingPanel = { character = 14, palette = 4, screen = 10 },
  -- The wallpaper chooser's 256x56 bar with four swatch wells, main BG1 at (0,0).
  wallpaperBar = { character = 14, palette = 4, screen = 13 },
  -- The Move/Item info panel tilemaps (BG6 cells): 96x80 moves, 256x72 items.
  movesPanel = { character = 6, palette = 7, screen = 86 },
  itemPanel = { character = 6, palette = 7, screen = 85 },
  -- The box tray strip (32x6 or 32x7 tiles): 256x48 in Move/Item, 256x56 in
  -- Deposit where the selector opens below the party panel.
  boxTray = { character = 14, palette = 4, screen = 11 },
  depositBoxTray = { character = 14, palette = 4, screen = 12 },
}
-- OBJ set A (ov14_021F44B4): the box arrows are animation 1 (left) and 3
-- (right). The wallpaper chooser's swatches are flat colors from the 32-color
-- OBJ palette member 75, indexed by logical wallpaper id; entry 24 is the
-- locked swatch (ov14_021F46B0).
PcSources.storageArrows = {
  character = 66,
  cell = 67,
  animation = 68,
  palette = 69,
  animations = { left = 1, right = 3 },
}
-- The hand cursor is OBJ set A's anim 8 (browsing), 14 (menu rows and
-- wallpaper swatches) and 10 (carrying), anchored at the nav-table node.
PcSources.storageCursorAnimations = { browse = 8, menu = 14, carry = 10 }
PcSources.storageWallpaperSwatches = { palette = 75, count = 24, colorBase = 16, lockedColorIndex = 0x28 }
-- Box thumbnails and the wallpaper list swatches are colored character art:
-- a source palette index is replaced by the wallpaper color before the sprite
-- is uploaded. PCBox_ColorWallpaperThumbnail uses the logical id + 16, or the
-- locked entry 0x28; the canonical RGB comes from the wallpaper color palette.
PcSources.storageBoxThumbnail = {
  character = 70,
  palette = 71,
  size = 32,
  columns = 4,
  rows = 4,
  fillIndex = 8,
  colorBase = 16,
  lockedColorIndex = 0x28,
  -- gPCBoxThumbnailTiles indexed by the mon's BASE_COLOR (0..9); each value
  -- adds the 0x20 dot-palette base.
  dotColors = { 14, 15, 5, 2, 13, 12, 6, 11, 10, 9 },
  dotPaletteBase = 0x20,
  dotOrigin = { x = 10, y = 11 },
  dotStep = 2,
}
-- The 24x24 swatch is one NCER cell of four objects, not a row-major 3x3 tile
-- grid: (-12,-12) 16x16 tile 0, (4,-12) 8x16 tile 4, (-12,4) 16x8 tile 6 and
-- (4,4) 8x8 tile 8 (member 76).
PcSources.storageWallpaperSwatch = {
  character = 0x4a,
  palette = 0x4b,
  cell = 0x4c,
  size = 24,
  fillIndex = 30,
  colorBase = 16,
  lockedColorIndex = 0x28,
}
-- OBJ set A animations used by the box tray and the wallpaper list: page
-- arrows 2/4, the current-box marker/selection cursor 5, the tray label 6 and
-- the wallpaper cursor 7. The hand cursor animations stay separate.
PcSources.storageTrayAnimations = { prev = 1, next = 3, marker = 0, cursor = 5, wallpaperCursor = 7, label = 6 }
-- The Item info windows fill with palette member 7 bank 1, index 13
-- (FillWindowPixelBuffer(window, 13) after PCBox_LoadBgGraphics loads member 7
-- into SUB BG palette bank 0).
PcSources.storageItemPanelFill = { palette = 7, paletteBank = 1, entry = 13 }
-- PCBox_PrintLevel and PCBox_PrintDexNumber blit raw 16x8 bitmaps from the
-- message-printer glyph bank instead of printing text: MessagePrinter_PrintGlyph
-- reads NARC_graphic_font member 5 at byte offsets 0x160 (glyph 1, "Lv.") and
-- 0x1A0 (glyph 2, "No.") with the 4bpp tile layout of that member. The two-bit
-- pixel values index the member-7 font palette (1 ink, 2 shadow, 0 clear).
PcSources.storageInfoGlyphs = {
  character = 5,
  palette = 7,
  paletteBank = 0,
  tiles = { lv = { 11, 2 }, no = { 13, 2 } },
}
-- The box screen's confirmation prompts are the shared YesNoPrompt component
-- (PCBox_ShowYesNoPrompt): shape 0 at tile (25,12), palette slots 8/9, from
-- NARC_system_touch_subwindow members 0 (palette), 1 (characters) and
-- 2..5 (YES normal/selected, NO normal/selected tilemaps).
PcSources.storageYesNo = {
  alias = "touch_subwindow",
  paletteMember = 0,
  charMember = 1,
  paletteBanks = { 0, 1 },
  yesNormalScreen = 2,
  yesSelectedScreen = 3,
  noNormalScreen = 4,
  noSelectedScreen = 5,
  x = 200,
  y = 96,
}
-- Sprite loaders in ov103_021EE2E0 and ov109_021E6EE4 bind these archive
-- resources to the Mailbox and Photo Album application sprites.
PcSources.mailboxUiMembers = { character = 7, palette = 10, cell = 8, animation = 9 }
-- Mailbox sprite roles over the compiled mailbox.animation.* sequences
-- (gMailboxSpriteTemplates, MailboxApp_CreateSprites/MoveCursor/
-- SetSpriteAnim in mailbox_app.c). Anims 4/5 are the list-cursor flash
-- (cells 7/8: 64- and 112-pixel highlights); anims 0/1 are the
-- previous/next page arrows (cells 0/1: mirrored 32x32 arrow tiles) at
-- (24,176)/(56,176). Sprite 3 is the static quit/close target at
-- (224,176), anim 2, never re-animated. Anim 3 is set by no code and
-- no template: it stays compiled but undrawn.
PcSources.mailboxSpriteRoles = {
  cursor = { animations = { 4, 5 } },
  pagePrevious = { animation = 0 },
  pageNext = { animation = 1 },
  -- Grid inputs 0-9 are the mail cells (MoveCursor :1594-1601: x
  -- 64/192, y 16+32k with k = row); input 10 is CLOSE at (224,176)
  -- (MoveCursorToCloseButton :1353-1356) and selects cursor anim 4,
  -- every other grid input selects anim 5. Cells are 1-based so
  -- cells[inputId + 1] is the input's anchor.
  cursorGrid = {
    closeInput = 10,
    cells = {
      { x = 64, y = 16 },
      { x = 192, y = 16 },
      { x = 64, y = 48 },
      { x = 192, y = 48 },
      { x = 64, y = 80 },
      { x = 192, y = 80 },
      { x = 64, y = 112 },
      { x = 192, y = 112 },
      { x = 64, y = 144 },
      { x = 192, y = 144 },
      { x = 224, y = 176 },
    },
  },
  sprite3 = { animation = 2, x = 224, y = 176 },
}
PcSources.photoAlbumSpriteMembers = { character = 1, palette = 0, cell = 2, animation = 3 }
-- Source prop policy from overlay_02_02248728.s.
PcSources.terminal = {
  buildModels = {
    { archiveAlias = "interior_build_models", memberId = 33 },
    { archiveAlias = "interior_build_models", memberId = 138 },
  },
  slots = {
    [0] = { role = "terminal.on", playMode = "forward" },
    [1] = { role = "terminal.off", playMode = "forward" },
  },
}
-- Bank counts and ordering follow the retail ROM's Easy Chat tables.
PcSources.mailText = {
  storageBanks = { 24, 25 },
  mailboxBank = 232,
  -- The MailView chrome: Confirm/Cancel labels (0, 1), the all-blank
  -- warning (2), and the whole-letter quit confirmation (3).
  mailViewBank = 233,
  -- Bank 300 carries the party-menu TakeMail custody messages
  -- (party_menu_list_items.c): 44 send-to-PC confirm, 48 erase
  -- follow-up, 47 sent, 51 mailbox full, 52 taken, 78 held-Mail
  -- refusal, 84 bag full.
  partyMailBank = 300,
  albumBank = 0,
  -- The retail ROM resolves native map sections through this bank.
  landmarkBank = 279,
}

-- Logical display geometry follows the DS 256x192 source screen. These
-- records are semantic anchors consumed by the PC presentation family.
PcSources.geometry = {
  mailboxPageSize = 10,
  wallpaperMap = { width = 168, height = 160, columns = 21, rows = 20, tileIdWrap = 64 },
  stationeryIconLocations = {
    -- Sprite slots 4..6 in ov103_021EED58, addressed by the three-iteration
    -- word-icon loop in ov103_021EE210. Logical screen coordinates are pixels.
    { x = 128, y = 160 },
    { x = 88, y = 160 },
    { x = 48, y = 160 },
  },
}

local function wallpaperArtOrdinals(wallpaperId)
  assert(type(wallpaperId) == "number" and wallpaperId % 1 == 0, "wallpaper identity must be an integer")
  if wallpaperId >= 0 and wallpaperId <= 15 then
    return wallpaperId
  end
  if wallpaperId >= 32 and wallpaperId <= 39 then
    return wallpaperId - 16
  end
  error("unsupported wallpaper identity: " .. tostring(wallpaperId), 2)
end

PcSources.geometry.wallpaperArtOrdinals = wallpaperArtOrdinals

return PcSources
