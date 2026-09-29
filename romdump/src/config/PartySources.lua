-- Producer-side semantic inventory of the native party presentation
-- sources: NARC member selection, canonical geometry, sprite/text/numeric/
-- badge selection, and normalized presentation facts. The audit basis is
-- pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- src/party_menu.c (the core-menu application; PartyMenu opens NARC 21 and
-- every member below is loaded by an audited call site),
-- src/party_menu_sprites.c (the 24-entry sprite template table and the
-- per-slot icon/ball/status/held/capsule creation),
-- src/party_context_menu.c (context window templates, button rects, and the
-- bank-300 action/field-move message selection), plus
-- files/data/resdat/resdat_00000085.json (the 45-entry party resource
-- header: graphics member, palette/cell/animation indices per resource set)
-- and files/data/resdat/resdat_00000084.json (the 12-entry sub-screen set).
-- Pure data and pure functions; no I/O. Never imported by runtime:
-- libs/assets, game, and script packages must not require this module.

local PartySources = {}

PartySources.provenance = {
  repoPin = "0301aa5868b961e5c860477b9bc47300663a609d",
  decompPin = "pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981",
  symbols = {
    "src/party_menu.c",
    "src/party_menu_sprites.c",
    "src/party_context_menu.c",
    "files/data/resdat/resdat_00000085.json",
    "files/data/resdat/resdat_00000084.json",
  },
}

-- Curated archive identities. NARC and NitroFS IDs are not interchangeable;
-- the symbol form is the only selector the compiler resolves.
PartySources.archive = { symbol = "NARC_graphic_plist_gra", narcId = 21, path = "a/0/2/1", memberCount = 27 }
PartySources.iconArchive = { symbol = "NARC_poketool_icongra_poke_icon", narcId = 20, path = "a/0/2/0" }
PartySources.statusArchive = { symbol = "NARC_a_0_3_9", narcId = 39, path = "a/0/3/9" }
PartySources.feedbackArchive = { symbol = "NARC_a_0_1_5", narcId = 15, path = "a/0/1/5" }
PartySources.headerArchive = { symbol = "NARC_data_resdat", narcId = 175, path = "a/1/7/5" }

-- Audited member groups inside NARC 21 (zero-based). Member 3/4 load sub
-- character/palette data before later sub compositions; the sub backdrop,
-- detail, and decoration members compose per the loader call sites, never
-- by compositing every similarly named picture together.
PartySources.members = {
  ball = { 0, 1, 2 },
  cursor = { 5, 6, 7 },
  buttons = { 9, 10, 11 },
  subBackdrop = { 12, 13, 14 },
  mainBackdrop = { 15, 16, 17 },
  heldMailCapsule = { 18, 19, 20, 21 },
  panelTemplates = { 22 },
  feedbackPalette = { 23 },
  subDetail = { 24, 25 },
  mainDecoration = { 26 },
  subPreload = { 3, 4 },
  buttonPlate = { 8 },
}

-- Panel templates are the three 16x6-tile rows of member 22: the first
-- panel (slot 0, or slot 1 in the alternate layout) copies rows 0-5, every
-- other panel copies rows 6-11, and rows 12-17 feed the auxiliary panel.
PartySources.panelTemplates = {
  member = 22,
  tilesWide = 16,
  tilesHigh = 6,
  rows = {
    { tileRow = 0, use = "first" },
    { tileRow = 6, use = "rest" },
    { tileRow = 12, use = "aux" },
  },
}

-- The main palette's Party panel data begins at NCLR byte offset 0x60. The
-- ordinary browse loader selects four of its 16-color states at two-bank
-- strides; empty panels use absolute bank 1.
PartySources.panelPalette = {
  firstColor = 0x60 / 2,
  stateBanks = { normal = 0, fainted = 2, selected = 4, selectedFainted = 6 },
  emptyBank = 1,
  hpBars = {
    green = { bank = 0, edge = 10, body = 9 },
    yellow = { bank = 1, edge = 10, body = 9 },
    red = { bank = 2, edge = 10, body = 9 },
  },
}

-- Resource-set relationships transcribed from resdat_00000085.json: each
-- entry names the NARC 21 graphics member plus the palette/cell/animation
-- indices into the header lists. Icons use sets 4-9 (one per party slot)
-- with species-selected graphics resolved through the existing mon class.
PartySources.resourceSets = {
  { graphics = 0, palette = 6, cell = 0, anim = 0 },
  { graphics = 1, palette = 0, cell = 1, anim = 1 },
  { graphics = 2, palette = 0, cell = 2, anim = 2 },
  { graphics = 3, palette = 1, cell = 3, anim = 3 },
  { graphics = 4, palette = 1, cell = 3, anim = 3 },
  { graphics = 5, palette = 1, cell = 3, anim = 3 },
  { graphics = 6, palette = 1, cell = 3, anim = 3 },
  { graphics = 7, palette = 1, cell = 3, anim = 3 },
  { graphics = 8, palette = 1, cell = 3, anim = 3 },
  { graphics = 9, palette = 1, cell = 3, anim = 3 },
  { graphics = 10, palette = 1, cell = 3, anim = 3 },
  { graphics = 11, palette = 8, cell = 4, anim = 4 },
  { graphics = 12, palette = 3, cell = 5, anim = 5 },
  { graphics = 13, palette = 0, cell = 6, anim = 6 },
  { graphics = 14, palette = 0, cell = 7, anim = 7 },
  { graphics = 16, palette = 0, cell = 10, anim = 10 },
  { graphics = 17, palette = 0, cell = 10, anim = 10 },
  { graphics = 15, palette = 0, cell = 8, anim = 8 },
  { graphics = 21, palette = 0, cell = 8, anim = 8 },
  { graphics = 20, palette = 0, cell = 8, anim = 8 },
  { graphics = 22, palette = 0, cell = 8, anim = 8 },
  { graphics = 18, palette = 0, cell = 8, anim = 8 },
  { graphics = 19, palette = 0, cell = 8, anim = 8 },
  { graphics = 23, palette = 0, cell = 8, anim = 8 },
  { graphics = 24, palette = 0, cell = 11, anim = 11 },
  { graphics = 25, palette = 5, cell = 12, anim = 12 },
  { graphics = 26, palette = 5, cell = 12, anim = 12 },
  { graphics = 27, palette = 5, cell = 12, anim = 12 },
  { graphics = 28, palette = 5, cell = 12, anim = 12 },
  { graphics = 29, palette = 5, cell = 12, anim = 12 },
  { graphics = 30, palette = 5, cell = 12, anim = 12 },
  { graphics = 31, palette = 5, cell = 12, anim = 12 },
  { graphics = 32, palette = 5, cell = 12, anim = 12 },
  { graphics = 33, palette = 5, cell = 12, anim = 12 },
  { graphics = 34, palette = 9, cell = 15, anim = 15 },
  { graphics = 35, palette = 0, cell = 13, anim = 13 },
  { graphics = 36, palette = 0, cell = 0, anim = 0 },
  { graphics = 37, palette = 0, cell = 16, anim = 16 },
  { graphics = 38, palette = 8, cell = 4, anim = 4 },
  { graphics = 39, palette = 8, cell = 4, anim = 4 },
  { graphics = 40, palette = 8, cell = 4, anim = 4 },
  { graphics = 41, palette = 8, cell = 4, anim = 4 },
  { graphics = 42, palette = 8, cell = 4, anim = 4 },
  { graphics = 43, palette = 8, cell = 4, anim = 4 },
  { graphics = 44, palette = 7, cell = 17, anim = 17 },
}

-- Sub-screen resource sets transcribed from resdat_00000084.json.
PartySources.subResourceSets = {
  { graphics = 0, palette = 0, cell = 0, anim = 0 },
  { graphics = 1, palette = 0, cell = 1, anim = 1 },
  { graphics = 2, palette = 0, cell = 2, anim = 2 },
  { graphics = 3, palette = 1, cell = 3, anim = 3 },
  { graphics = 4, palette = 2, cell = 4, anim = 4 },
  { graphics = 5, palette = 2, cell = 4, anim = 4 },
  { graphics = 6, palette = 2, cell = 4, anim = 4 },
  { graphics = 7, palette = 2, cell = 4, anim = 4 },
  { graphics = 8, palette = 2, cell = 4, anim = 4 },
  { graphics = 9, palette = 2, cell = 4, anim = 4 },
  { graphics = 10, palette = 3, cell = 5, anim = 5 },
  { graphics = 11, palette = 4, cell = 6, anim = 6 },
}

-- Resource-header members verifying the set relationships above. The
-- animation/cell/char/palette header lists plus the graphics header list
-- resolve each set's indices to concrete NARC 21 members at compile time.
PartySources.headers = { animation = 48, cell = 49, char = 50, palette = 51, graphics = 84 }

-- Shared icon selectors (NARC 20 members 0/3/4) and the expected sequence
-- periods: the species-selected icon graphics resolve through the existing
-- mon class, never here.
PartySources.iconShared =
  { archive = "NARC_poketool_icongra_poke_icon", paletteMember = 0, cellMember = 4, animationMember = 3 }
PartySources.iconPeriods = { 1, 8, 12, 24, 40, 36 }
PartySources.iconReplacement = { durations = { 32, 2, 2 }, shiftX = { 0, 1, -1 } }

-- Status labels (NARC 39 members) and the short-feedback selector (NARC 15
-- members, palette from party member 23). The status animation carries
-- seven static sequences with OK hidden; feedback hides its sprite when
-- frame index 2 is reached instead of drawing all six ticks. Member roles
-- verified by decode against the canonical dump.
PartySources.status = { animationMember = 62, cellMember = 63, charMember = 64, paletteMember = 65 }
PartySources.feedback =
  { animationMember = 27, cellMember = 28, charMember = 29, paletteMember = 23, sequence = 0, durations = { 3, 2, 1 } }

-- Fixed numeric font: NARC 16 member 5 holds consecutive 8x8 4bpp digit
-- cells at byte offsets digit*32, the slash glyph at 0x140 (width 8) and
-- the level glyph at 0x160 (width 16), all height 8. The source recolors
-- indices 1/2/0 to foreground/shadow/background.
PartySources.numeric = {
  fontSymbol = "NARC_graphic_font",
  member = 5,
  digitWidth = 8,
  digitHeight = 8,
  slashOffset = 0x140,
  slashWidth = 8,
  levelOffset = 0x160,
  levelWidth = 16,
}

-- Shiny Leaf/crown source: a/1/6/2 members 65-68 with animations 6 (leaf)
-- and 7 (crown). The templates' main palette bank 6 resolves to the second
-- bank in member 65 after the resource allocator's preceding allocations;
-- the manifest records local bank 1. Anchors are sprite anchors, not
-- cropped top-left coordinates. Source identity stays in this producer
-- configuration only.
PartySources.badges = {
  archiveSymbol = "NARC_a_1_6_2",
  narcPath = "a/1/6/2",
  paletteMember = 65,
  charMember = 66,
  cellMember = 67,
  animationMember = 68,
  leafSequence = 6,
  crownSequence = 7,
  paletteBank = 1,
  leafAnchors = {
    { x = 91, y = 182 },
    { x = 101, y = 182 },
    { x = 111, y = 182 },
    { x = 121, y = 182 },
    { x = 131, y = 182 },
  },
  crownAnchor = { x = 111, y = 182 },
}

-- Message/context window placements transcribed from sAdditionalWindowTemplates
-- (party_context_menu.c): window 32 (lower message) is template index 2,
-- window 36 (context menu) is template index 6. Tile units become pixels.
PartySources.windows = {
  message = { x = 16, y = 168, width = 160, height = 16 },
  context = { x = 152, y = 120, width = 96, height = 64 },
}
-- never through map-script reachability. Labels carry display text only;
-- templates carry the closed substitution vocabulary below.
PartySources.messages = {
  archiveSymbol = "NARC_msgdata_msg",
  bank = 300,
  labels = {
    switch = { bank = 300, index = 128 },
    summary = { bank = 300, index = 129 },
    item = { bank = 300, index = 130 },
    mail = { bank = 300, index = 131 },
    read = { bank = 300, index = 132 },
    take = { bank = 300, index = 133 },
    store = { bank = 300, index = 134 },
    quit = { bank = 300, index = 135 },
    enter = { bank = 300, index = 137 },
    noEntry = { bank = 300, index = 138 },
    give = { bank = 300, index = 143 },
    takeBack = { bank = 300, index = 144 },
    set = { bank = 300, index = 149 },
    confirm = { bank = 300, index = 186 },
    cancel = { bank = 300, index = 1 },
    compatAltAble = { bank = 300, index = 158 },
    compatAltUnable = { bank = 300, index = 159 },
    compatAltLearned = { bank = 300, index = 160 },
    compatAble = { bank = 300, index = 161 },
    compatUnable = { bank = 300, index = 162 },
  },
  templates = {
    chooseMon = { bank = 300, index = 29 },
    moveTarget = { bank = 300, index = 31 },
    giveTarget = { bank = 300, index = 32 },
    useTarget = { bank = 300, index = 33 },
    teachTarget = { bank = 300, index = 34 },
    confirmChoice = { bank = 300, index = 35 },
    itemAction = { bank = 300, index = 38 },
    restoreMove = { bank = 300, index = 41 },
    boostPp = { bank = 300, index = 42 },
    setBall = { bank = 300, index = 43 },
    sendMail = { bank = 300, index = 44 },
    learnMove = { bank = 300, index = 53 },
    stopTeach = { bank = 300, index = 56 },
    didNotLearn = { bank = 300, index = 59 },
    forgetMove = { bank = 300, index = 60 },
    noEffect = { bank = 300, index = 102 },
    fieldMoveConfirm = { bank = 300, index = 139 },
    levelTotal = { bank = 300, index = 167 },
    eggSelect = { bank = 300, index = 184 },
  },
}

-- Canonical geometry. Panel origins and mon/ball anchors are transcribed
-- from the per-slot placement rows (default variant; the alternate variant
-- serves the internal alternate layout). Status rectangles derive from the
-- audited 24-entry sprite template centers with 24x8 labels. Dpad boxes
-- are {left,top,width,height,up,down,left,right} pixels; touch rects are
-- {top,bottom,left,right} with right 0 encoding 256.
PartySources.geometry = {
  paneWidth = 256,
  paneHeight = 192,
  panels = {
    { origin = { x = 0, y = 0 }, template = "first" },
    { origin = { x = 128, y = 8 }, template = "rest" },
    { origin = { x = 0, y = 48 }, template = "rest" },
    { origin = { x = 128, y = 56 }, template = "rest" },
    { origin = { x = 0, y = 96 }, template = "rest" },
    { origin = { x = 128, y = 104 }, template = "rest" },
  },
  panelSize = { width = 128, height = 48 },
  alternatePanels = {
    { origin = { x = 0, y = 0 }, template = "first" },
    { origin = { x = 128, y = 0 }, template = "rest" },
    { origin = { x = 0, y = 48 }, template = "rest" },
    { origin = { x = 128, y = 48 }, template = "rest" },
    { origin = { x = 0, y = 96 }, template = "rest" },
    { origin = { x = 128, y = 96 }, template = "rest" },
  },
  monAnchors = {
    { x = 30, y = 16 },
    { x = 158, y = 24 },
    { x = 30, y = 64 },
    { x = 158, y = 72 },
    { x = 30, y = 112 },
    { x = 158, y = 120 },
  },
  ballAnchors = {
    { x = 16, y = 14 },
    { x = 144, y = 22 },
    { x = 16, y = 62 },
    { x = 144, y = 70 },
    { x = 16, y = 110 },
    { x = 144, y = 118 },
  },
  heldAnchors = {
    { x = 47, y = 25 },
    { x = 175, y = 33 },
    { x = 47, y = 73 },
    { x = 175, y = 81 },
    { x = 47, y = 121 },
    { x = 175, y = 129 },
  },
  capsuleAnchors = {
    { x = 12, y = 25 },
    { x = 140, y = 33 },
    { x = 12, y = 73 },
    { x = 140, y = 81 },
    { x = 12, y = 121 },
    { x = 140, y = 129 },
  },
  -- Values select source cursor sequences; the compiler lowers them to the
  -- one-based index used by the generated manifest.
  cursorSequenceSelectors = { 1, 0, 0, 0, 0, 0 },
  controls = { cancelAnchor = { x = 232, y = 184 } },
  statusRects = {
    { x = 24, y = 40, width = 24, height = 8 },
    { x = 152, y = 48, width = 24, height = 8 },
    { x = 24, y = 88, width = 24, height = 8 },
    { x = 152, y = 96, width = 24, height = 8 },
    { x = 24, y = 136, width = 24, height = 8 },
    { x = 152, y = 144, width = 24, height = 8 },
  },
  dpad = {
    default = {
      { left = 64, top = 25, width = 0, height = 0, up = 7, down = 2, leftNeighbor = 7, rightNeighbor = 1 },
      { left = 192, top = 33, width = 0, height = 0, up = 7, down = 3, leftNeighbor = 0, rightNeighbor = 2 },
      { left = 64, top = 73, width = 0, height = 0, up = 0, down = 4, leftNeighbor = 1, rightNeighbor = 3 },
      { left = 192, top = 81, width = 0, height = 0, up = 1, down = 5, leftNeighbor = 2, rightNeighbor = 4 },
      { left = 64, top = 121, width = 0, height = 0, up = 2, down = 7, leftNeighbor = 3, rightNeighbor = 5 },
      { left = 192, top = 129, width = 0, height = 0, up = 3, down = 7, leftNeighbor = 4, rightNeighbor = 7 },
      { left = 0, top = 0, width = 0, height = 0, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 0 },
      { left = 224, top = 168, width = 0, height = 0, up = 5, down = 1, leftNeighbor = 5, rightNeighbor = 0 },
    },
    alternate = {
      { left = 64, top = 25, width = 0, height = 0, up = 4, down = 2, leftNeighbor = 1, rightNeighbor = 1 },
      { left = 192, top = 25, width = 0, height = 0, up = 7, down = 3, leftNeighbor = 0, rightNeighbor = 0 },
      { left = 64, top = 73, width = 0, height = 0, up = 0, down = 4, leftNeighbor = 3, rightNeighbor = 3 },
      { left = 192, top = 73, width = 0, height = 0, up = 1, down = 5, leftNeighbor = 2, rightNeighbor = 2 },
      { left = 64, top = 121, width = 0, height = 0, up = 2, down = 0, leftNeighbor = 5, rightNeighbor = 5 },
      { left = 192, top = 121, width = 0, height = 0, up = 3, down = 7, leftNeighbor = 4, rightNeighbor = 4 },
      { left = 224, top = 168, width = 0, height = 0, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 0 },
      { left = 224, top = 168, width = 0, height = 0, up = 5, down = 1, leftNeighbor = 255, rightNeighbor = 255 },
    },
    union = {
      { left = 64, top = 25, width = 0, height = 0, up = 7, down = 2, leftNeighbor = 7, rightNeighbor = 1 },
      { left = 192, top = 33, width = 0, height = 0, up = 7, down = 3, leftNeighbor = 0, rightNeighbor = 2 },
      { left = 64, top = 73, width = 0, height = 0, up = 0, down = 4, leftNeighbor = 1, rightNeighbor = 3 },
      { left = 192, top = 81, width = 0, height = 0, up = 1, down = 5, leftNeighbor = 2, rightNeighbor = 4 },
      { left = 64, top = 121, width = 0, height = 0, up = 2, down = 6, leftNeighbor = 3, rightNeighbor = 5 },
      { left = 192, top = 129, width = 0, height = 0, up = 3, down = 6, leftNeighbor = 4, rightNeighbor = 6 },
      { left = 224, top = 168, width = 0, height = 0, up = 5, down = 7, leftNeighbor = 5, rightNeighbor = 7 },
      { left = 224, top = 184, width = 0, height = 0, up = 6, down = 1, leftNeighbor = 6, rightNeighbor = 0 },
    },
    contest = {
      { left = 64, top = 25, width = 0, height = 0, up = 5, down = 2, leftNeighbor = 5, rightNeighbor = 1 },
      { left = 192, top = 33, width = 0, height = 0, up = 5, down = 3, leftNeighbor = 0, rightNeighbor = 2 },
      { left = 64, top = 73, width = 0, height = 0, up = 0, down = 4, leftNeighbor = 1, rightNeighbor = 3 },
      { left = 192, top = 81, width = 0, height = 0, up = 1, down = 5, leftNeighbor = 2, rightNeighbor = 4 },
      { left = 64, top = 121, width = 0, height = 0, up = 2, down = 0, leftNeighbor = 3, rightNeighbor = 5 },
      { left = 192, top = 129, width = 0, height = 0, up = 3, down = 0, leftNeighbor = 4, rightNeighbor = 0 },
      { left = 0, top = 0, width = 0, height = 0, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 0 },
      { left = 0, top = 0, width = 0, height = 0, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 0 },
    },
  },
  touch = {
    default = {
      { top = 0, bottom = 48, left = 0, right = 128 },
      { top = 8, bottom = 56, left = 128, right = 0 },
      { top = 48, bottom = 96, left = 0, right = 128 },
      { top = 56, bottom = 104, left = 128, right = 0 },
      { top = 96, bottom = 144, left = 0, right = 128 },
      { top = 104, bottom = 152, left = 128, right = 0 },
      { top = 152, bottom = 192, left = 200, right = 0 },
    },
    alternate = {
      { top = 0, bottom = 48, left = 0, right = 128 },
      { top = 0, bottom = 48, left = 128, right = 0 },
      { top = 48, bottom = 96, left = 0, right = 128 },
      { top = 48, bottom = 96, left = 128, right = 0 },
      { top = 96, bottom = 144, left = 0, right = 128 },
      { top = 96, bottom = 144, left = 128, right = 0 },
      { top = 152, bottom = 192, left = 200, right = 0 },
    },
    context = {
      { top = 0, bottom = 48, left = 0, right = 128 },
      { top = 8, bottom = 56, left = 128, right = 0 },
      { top = 48, bottom = 96, left = 0, right = 128 },
      { top = 56, bottom = 104, left = 128, right = 0 },
      { top = 96, bottom = 144, left = 0, right = 128 },
      { top = 104, bottom = 152, left = 128, right = 0 },
      { top = 176, bottom = 192, left = 200, right = 0 },
      { top = 160, bottom = 176, left = 200, right = 0 },
    },
  },
}

-- Per-slot text/HP/compat window rects are the panel origin plus these
-- slot-0-relative pixel rects, transcribed from sMainWindowTemplates
-- (party_context_menu.c): nickname (48,8,72,16), level (0,32,48,16),
-- HP number (56,32,64,16), HP bar (64,24,48,8), compat (48,32,80,16).
PartySources.panelWindows = {
  name = { x = 48, y = 8, width = 72, height = 16 },
  level = { x = 0, y = 32, width = 48, height = 16 },
  number = { x = 56, y = 32, width = 64, height = 16 },
  bar = { x = 64, y = 24, width = 48, height = 8 },
  compat = { x = 48, y = 32, width = 80, height = 16 },
}

return PartySources
