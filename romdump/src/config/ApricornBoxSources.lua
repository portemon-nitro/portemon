-- HGSS Apricorn Box sources traced in the retail ROM's overlay 59 and
-- resdat resource records. Source IDs stay in the ROM producer.

local ApricornBoxSources = {}

ApricornBoxSources.provenance = {
  repo = "retail ROM",
}

ApricornBoxSources.backgroundArchive = {
  alias = "apricorn_box_ui",
  narcId = 220,
  path = "a/2/1/8",
  -- The member names follow the retail displays, not the archive order:
  -- ApricornBoxScreen_LoadBgGraphics loads members 0-2 onto SUB (the upper
  -- display) and members 3-5 onto MAIN (the lower touchscreen).
  members = {
    upper = { palette = 0, char = 1, screen = 2 },
    lower = { palette = 3, char = 4, screen = 5 },
    -- The Kurt quantity overlay shares the lower display tiles and palettes.
    quantityPanel = 6,
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
  title = 0,
  close = 1,
  browseHeader = 27,
  -- Message 26 is the reserved quantity window line; retail ships it empty.
  panelMessage = 26,
  itemNames = { 7, 8, 9, 10, 11, 12, 13 },
  itemDescriptions = { 40, 41, 42, 43, 44, 45, 46 },
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

-- Native item identities parallel to itemKeys, verified against
-- ItemSources.itemKeys at compile time; the confirm header resolves plural
-- names through ItemSources.messageBanks.namePlural by these identities.
ApricornBoxSources.itemIds = { 485, 486, 487, 488, 489, 490, 491 }

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
  -- Text windows in tile units from sApricornBoxWindowTemplates: the header
  -- sits at the top of the lower touchscreen, the title and close labels
  -- share its bottom row, and the description fills the upper display base.
  -- The close button anchor is the sApricornBoxSpriteTemplates close entry.
  closeButton = { x = 224, y = 176 },
  -- Kurt quantity overlay in pixels from the window templates, the digit
  -- offsets, and the confirm-button/arrow sprite templates: the name prints
  -- at its window origin while digits sit inside their count windows.
  quantityLayout = {
    name = { x = 72, y = 56 },
    unitsDigit = { x = 98, y = 107 },
    tensDigit = { x = 80, y = 107 },
    extraMessage = { x = 114, y = 112 },
    confirmOk = { x = 136, y = 104, width = 48 },
    confirmClose = { x = 136, y = 128, width = 48 },
    buttonOkSprite = { x = 160, y = 112, sequence = 28, pressedSequence = 29 },
    buttonCloseSprite = { x = 160, y = 136, sequence = 30, pressedSequence = 31 },
    arrows = {
      { x = 103, y = 96, sequence = 24 },
      { x = 103, y = 136, sequence = 26 },
      { x = 81, y = 96, sequence = 24 },
      { x = 81, y = 136, sequence = 26 },
    },
  },
  headerWindow = { x = 3, y = 1, width = 28, height = 2 },
  titleWindow = { x = 2, y = 21, width = 10, height = 2 },
  closeWindow = { x = 25, y = 21, width = 6, height = 2 },
  -- Chrome text ink from sApricornBoxWindowTemplates and the Draw color
  -- arguments: CLOSE is window 2 (BG palette 9) printed with
  -- MAKE_TEXT_COLOR(1,2,0) while the title is window 3 (palette 12, the
  -- LoadFontPal1 font slot) printed with MAKE_TEXT_COLOR(15,2,0). Only
  -- the CLOSE ink rides the compiled manifest; title and confirm inks
  -- resolve through the runtime field font palette like every other
  -- paletted caller.
  closeInk = { palette = 9, foreground = 1, shadow = 2 },
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
