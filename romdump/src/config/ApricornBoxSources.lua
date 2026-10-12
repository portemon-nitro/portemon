-- HGSS Apricorn Box sources traced in pret/pokeheartgold's overlay59 and
-- resdat resource records. Source IDs stay in the ROM producer.

local ApricornBoxSources = {}

ApricornBoxSources.provenance = {
  repo = "pret/pokeheartgold",
  commit = "0985e8718df4f25e64d6507d89c0c97c0d288981",
  sources = {
    "asm/overlay_59.s",
    "src/touchscreen_list_menu.c",
    "files/data/sbox_gra.mk",
    "src/sprite_system.c",
    "include/sprite_system.h",
    "include/unk_02009D48.h",
    "files/data/resdat/resdat_00000016.json",
    "files/data/resdat/resdat_00000017.json",
    "files/data/resdat/resdat_00000018.json",
    "files/data/resdat/resdat_00000019.json",
    "files/data/resdat/resdat_00000076.json",
  },
}

ApricornBoxSources.backgroundArchive = {
  alias = "apricorn_box_ui",
  narcId = 220,
  path = "a/2/1/8",
  members = {
    lower = { palette = 0, char = 1, screen = 2 },
    upper = { palette = 3, char = 4, screen = 5 },
    apricornSprite = { palette = 7, char = 8, cell = 9, animation = 10 },
  },
}

ApricornBoxSources.resdatArchive = {
  alias = "apricorn_box_resdat",
  narcId = 175,
  path = "a/1/7/5",
  members = {
    animation = 16,
    cell = 17,
    char = 18,
    palette = 19,
    header = 76,
  },
}

ApricornBoxSources.actionMenuArchive = {
  alias = "sbox_gra",
  narcId = 165,
  path = "a/1/6/5",
  members = { palette = 0, char = 1 },
}

ApricornBoxSources.messages = {
  bankId = 21,
  itemNames = { 7, 8, 9, 10, 11, 12, 13 },
  actionLabels = { 2, 3, 4, 5, 6 },
  flowMessages = { selection = 37, quantity = 38, confirmation = 39 },
  modeMessages = { 25, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48 },
}

ApricornBoxSources.itemKeys = {
  "RED_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
}

ApricornBoxSources.geometry = {
  selectionCursorResourceSet = 0,
  rowIcons = {
    { x = 27, y = 49, animation = 9 },
    { x = 75, y = 65, animation = 10 },
    { x = 27, y = 81, animation = 11 },
    { x = 75, y = 97, animation = 12 },
    { x = 27, y = 113, animation = 13 },
    { x = 75, y = 129, animation = 14 },
    { x = 27, y = 145, animation = 15 },
  },
  rowHitboxes = {
    { x = 26, y = 48, radius = 24 },
    { x = 74, y = 64, radius = 24 },
    { x = 26, y = 80, radius = 24 },
    { x = 74, y = 96, radius = 24 },
    { x = 26, y = 112, radius = 24 },
    { x = 74, y = 128, radius = 24 },
    { x = 26, y = 144, radius = 24 },
  },
  countWindows = {
    { x = 5, y = 6, width = 2, height = 2 },
    { x = 11, y = 8, width = 2, height = 2 },
    { x = 5, y = 10, width = 2, height = 2 },
    { x = 11, y = 12, width = 2, height = 2 },
    { x = 5, y = 14, width = 2, height = 2 },
    { x = 11, y = 16, width = 2, height = 2 },
    { x = 5, y = 18, width = 2, height = 2 },
  },
  countText = { alignment = "center", width = 16, height = 16, color = 2 },
  selectedDetail = {
    window = { bg = 7, x = 2, y = 17, width = 28, height = 6, palette = 12, baseTile = 0x358 },
    messageWindowIndex = 4,
  },
  touchMenu = {
    sourceTable = { 0, 2, 1, 0, 0, 4, 3, 0, 0, 6, 5, 0, 3, 4, 0, 11, 0, 0, 58, 0, 31, 0, 48, 0 },
    windowCount = 3,
    windowOriginTiles = { x = 14, y = 8 },
    windowWidthTiles = 22,
    selection = 0,
    actions = {
      browse = { x = 22, y = 14, width = 8, windowCount = 3, messageIds = { 2, 3, 4 } },
      kurtSelect = { x = 17, y = 12, width = 8, windowCount = 2, messageIds = { 5, 6 } },
    },
    actionCharOffset = 31,
    quantityHitboxes = {
      { x = 104, y = 136, width = 16, height = 48 },
      { x = 128, y = 136, width = 16, height = 48 },
      { x = 88, y = 94, width = 16, height = 14 },
      { x = 128, y = 94, width = 16, height = 14 },
      { x = 88, y = 74, width = 16, height = 14 },
      { x = 128, y = 74, width = 16, height = 14 },
    },
  },
}

return ApricornBoxSources
