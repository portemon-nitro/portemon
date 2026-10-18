-- Source selectors and shared geometry for the retained HGSS PC applications.
-- Overlay call sites were verified against the retail ROM.

local PcSources = {}

PcSources.provenance = {
  romAudit = "retail ROM",
  symbols = { "asm/overlay_14.s", "asm/overlay_103.s", "asm/overlay_109.s" },
}

PcSources.archives = {
  storage = { alias = "NARC_a_0_1_9", path = "a/0/1/9", memberCount = 87, selectedMemberCount = 87 },
  mailbox = { alias = "NARC_a_2_5_0", path = "a/2/5/0", memberCount = 11, selectedMemberCount = 11 },
  -- Member 36 is present in the archive but unused by all twelve source
  -- stationery triplets (palette 0..11, character 12..23, screen 24..35).
  stationery = { alias = "NARC_a_0_7_9", path = "a/0/7/9", memberCount = 37, selectedMemberCount = 36 },
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
  -- The Marking editor's panel strip, drawn to main BG0 at (168,48).
  markingPanel = { character = 14, palette = 4, screen = 10 },
  -- The wallpaper chooser's 256x56 bar with four swatch wells, main BG1 at (0,0).
  wallpaperBar = { character = 14, palette = 4, screen = 13 },
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
PcSources.storageWallpaperSwatches = { palette = 75, count = 24, lockedIndex = 24 }
-- Sprite loaders in ov103_021EE2E0 and ov109_021E6EE4 bind these archive
-- resources to the Mailbox and Photo Album application sprites.
PcSources.mailboxUiMembers = { character = 7, palette = 10, cell = 8, animation = 9 }
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
  albumBank = 0,
  -- The retail ROM resolves native map sections through this bank.
  landmarkBank = 279,
  lineBanks = { 294, 296, 292, 293, 295 },
  wordBanks = {
    { messageBank = 237, firstWordId = 0, wordCount = 496 },
    { messageBank = 751, firstWordId = 496, wordCount = 468 },
    { messageBank = 735, firstWordId = 964, wordCount = 18 },
    { messageBank = 721, firstWordId = 982, wordCount = 124 },
    { messageBank = 285, firstWordId = 1106, wordCount = 38 },
    { messageBank = 286, firstWordId = 1144, wordCount = 38 },
    { messageBank = 287, firstWordId = 1182, wordCount = 107 },
    { messageBank = 288, firstWordId = 1289, wordCount = 104 },
    { messageBank = 289, firstWordId = 1393, wordCount = 47 },
    { messageBank = 290, firstWordId = 1440, wordCount = 32 },
    { messageBank = 291, firstWordId = 1472, wordCount = 23 },
  },
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
