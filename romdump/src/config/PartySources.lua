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
-- strides, and the switch-selection state resolves bank 7; empty panels use
-- absolute bank 1.
PartySources.panelPalette = {
  firstColor = 0x60 / 2,
  stateBanks = { normal = 0, fainted = 2, selected = 4, selectedFainted = 6, switchSelection = 7 },
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
PartySources.status = {
  animationMember = 62,
  cellMember = 63,
  charMember = 64,
  paletteMember = 65,
  paletteBank = 0,
  -- PartyMonStatusIconId maps PRZ/FRZ/SLP/PSN/BRN/FNT to sequences 1..6.
  semanticSequences = {
    { key = "paralysis", sequence = 1 },
    { key = "freeze", sequence = 2 },
    { key = "sleep", sequence = 3 },
    { key = "poison", sequence = 4 },
    { key = "burn", sequence = 5 },
    { key = "faint", sequence = 6 },
  },
}
-- The palette resource is local to this marker. Source OBJ allocator slots
-- are not bank indices within the decoded member 21 palette.
PartySources.heldItemPaletteBank = 0
PartySources.feedback =
  { animationMember = 27, cellMember = 28, charMember = 29, paletteMember = 23, sequence = 0, durations = { 3, 2, 1 } }

-- Fixed numeric font: NARC 16 member 5 holds consecutive 8x8 4bpp digit
-- cells at byte offsets digit*32, the slash glyph at 0x140 (width 8) and
-- the level glyph at 0x160 (width 16), all height 8. Glyph pixels recolor
-- through the party text roles above, never bare font palette entries.
-- Placement is window-relative pixels transcribed from the panel number
-- routines: level numerals at level-window (5,2), current HP as a 3-digit
-- right-aligned field at HP-window (0,2), the slash at (28,2), max HP as a
-- 3-digit left-aligned field at (36,2)
-- (PartyMenu_PrintMonLevelOnWindow/CurHp/DrawSlash/MaxHpOnWindow).
PartySources.numeric = {
  fontSymbol = "NARC_graphic_font",
  member = 5,
  digitWidth = 8,
  digitHeight = 8,
  slashOffset = 0x140,
  slashWidth = 8,
  levelOffset = 0x160,
  levelWidth = 16,
  placement = {
    level = { x = 5, y = 2 },
    current = { x = 0, y = 2 },
    slash = { x = 28, y = 2 },
    max = { x = 36, y = 2 },
  },
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
-- (party_context_menu.c): browse is source window 32 (template index 2),
-- context is source window 33 (template index 3), action is source window 34
-- (template index 4). Tile units become pixels. The confirm prompt anchors at
-- the source tile-derived position (tile 25,10), in pixels.
PartySources.windows = {
  browse = { x = 16, y = 168, width = 160, height = 16 },
  context = { x = 16, y = 152, width = 104, height = 32 },
  action = { x = 16, y = 152, width = 216, height = 32 },
  prompt = { x = 200, y = 80 },
}

-- Party text palette roles transcribed from the source printer slots:
-- ordinary nickname text uses MAKE_TEXT_COLOR(15, 14, 0), the male symbol
-- uses (3, 4, 0), the female symbol uses (5, 6, 0)
-- (PartyMenu_PrintMonNicknameOnWindow). Each triple is
-- { foreground, shadow, background } slots in the palette bank below; the
-- bank-0 resolution is what carries the white/blue/red ink seen in-game.
-- The background slot keeps its source RGB, but the compiler lowers it to
-- transparent runtime ink because panel text prints over existing chrome.
PartySources.textRoles = {
  bank = 0,
  ordinary = { 15, 14, 0 },
  male = { 3, 4, 0 },
  female = { 5, 6, 0 },
}

-- Lower-message palette selection: party message windows print through
-- font 1 over fill color 15, so their ink comes from the loaded font
-- palette member 8 (LoadFontPal1 in src/font.c loads NARC_graphic_font
-- member 8; PartyMenu_PrintMessageOnWindowEx in src/party_context_menu.c
-- fills with color index 15). Entries name { foreground, shadow,
-- background } slots in that font palette member.
PartySources.messageRole = { paletteMember = 8, foreground = 1, shadow = 2, background = 15 }

-- Context-button presentation roles transcribed from
-- PartyMenu_PrintContextMenuItemText/getButtonColorRaised/getButtonColorDepressed:
-- button windows carry palette selector 2. Command entries, later field
-- entries, and the fixed cancel entry each resolve a raised/depressed
-- foreground/shadow/background triple; command and cancel share the bright
-- ink pair while field entries keep their own ink. Each triple names source
-- palette slots in the bank below.
PartySources.contextRoles = {
  bank = 2,
  command = { raised = { 14, 15, 4 }, depressed = { 14, 15, 11 } },
  field = { raised = { 9, 10, 4 }, depressed = { 9, 10, 11 } },
  cancel = { raised = { 14, 15, 4 }, depressed = { 14, 15, 11 } },
}

-- Context-button frame source transcribed from sub_0207E3A8 and the member-26
-- load in sub_02079A14 (member 26 NCGR loads at BG tile base 10; the raised,
-- selected, and pressed VRAM tile starts 0x200A/0x2013/0x201C are member tiles
-- 0/9/18). Tile offsets are sButtonFrameTileOffsets: corner, corner, corner,
-- corner, left edge, right edge, top edge, bottom edge. Frames carry tilemap
-- palette selector 2, resolved against the bank below.
PartySources.contextFrames = {
  member = 26,
  tileBases = { raised = 0, selected = 9, pressed = 18 },
  tileOffsets = { 0, 2, 6, 8, 3, 5, 1, 7 },
  paletteBank = 2,
}

-- Context-menu button inventory transcribed from party_context_menu.c.
-- textWindows are sButtonWindowTemplates in tile units { x, y, width, height };
-- frames are sButtonRects in tile units (indices 0-6 and 8-11 are 16x4-tile
-- standard buttons, index 7 is the 7x5-tile cancel button); windowIds are
-- sButtonWindowIDs keyed by entry count with the producer state naming the
-- slot menu (top) versus the item/mail submenu (sub), mapping each semantic
-- entry to its button index; navTopLevel is sDpadNavParam_PartyMenu keyed by
-- entry count ({ up, down, lateral } zero-based selections, -1 no move, one
-- lateral relation shared by left and right); navSubcontext is
-- sDpadNavParam_ContextMenu ({ up, down } only); hitboxes are sHitboxes and
-- subHitboxes sContextMenuHitboxes in pixels { top, bottom, left, right }
-- with right 0 encoding 256, indexed by button index and sub-hitbox index.
PartySources.contextButtons = {
  textWindows = {
    { x = 17, y = 4, width = 14, height = 2 },
    { x = 17, y = 8, width = 14, height = 2 },
    { x = 17, y = 12, width = 14, height = 2 },
    { x = 1, y = 3, width = 14, height = 2 },
    { x = 1, y = 7, width = 14, height = 2 },
    { x = 1, y = 11, width = 14, height = 2 },
    { x = 1, y = 15, width = 14, height = 2 },
    { x = 26, y = 20, width = 5, height = 3 },
    { x = 17, y = 3, width = 14, height = 2 },
    { x = 17, y = 7, width = 14, height = 2 },
    { x = 17, y = 11, width = 14, height = 2 },
    { x = 17, y = 15, width = 14, height = 2 },
  },
  frames = {
    { x = 16, y = 3, width = 16, height = 4 },
    { x = 16, y = 7, width = 16, height = 4 },
    { x = 16, y = 11, width = 16, height = 4 },
    { x = 0, y = 2, width = 16, height = 4 },
    { x = 0, y = 6, width = 16, height = 4 },
    { x = 0, y = 10, width = 16, height = 4 },
    { x = 0, y = 14, width = 16, height = 4 },
    { x = 25, y = 19, width = 7, height = 5 },
    { x = 16, y = 2, width = 16, height = 4 },
    { x = 16, y = 6, width = 16, height = 4 },
    { x = 16, y = 10, width = 16, height = 4 },
    { x = 16, y = 14, width = 16, height = 4 },
  },
  windowIds = {
    top = {
      [2] = { 0, 7 },
      [3] = { 0, 1, 7 },
      [4] = { 0, 1, 2, 7 },
      [5] = { 0, 1, 2, 7, 3 },
      [6] = { 0, 1, 2, 7, 3, 4 },
      [7] = { 0, 1, 2, 7, 3, 4, 5 },
      [8] = { 0, 1, 2, 7, 3, 4, 5, 6 },
    },
    sub = {
      [2] = { 8, 7 },
      [3] = { 8, 9, 7 },
      [4] = { 8, 9, 10, 7 },
      [5] = { 8, 9, 10, 11, 7 },
    },
  },
  navTopLevel = {
    [2] = { { 1, 1, -1 }, { 0, 0, -1 } },
    [3] = { { 2, 1, -1 }, { 0, 2, -1 }, { 1, 0, -1 } },
    [4] = { { 3, 1, -1 }, { 0, 2, -1 }, { 1, 3, -1 }, { 2, 0, -1 } },
    [5] = { { 3, 1, 4 }, { 0, 2, 4 }, { 1, 3, 4 }, { 2, 0, -1 }, { -1, -1, 0 } },
    [6] = { { 3, 1, 4 }, { 0, 2, 5 }, { 1, 3, 5 }, { 2, 0, -1 }, { 5, 5, 0 }, { 4, 4, 1 } },
    [7] = {
      { 3, 1, 4 },
      { 0, 2, 5 },
      { 1, 3, 6 },
      { 2, 0, -1 },
      { 6, 5, 0 },
      { 4, 6, 1 },
      { 5, 4, 2 },
    },
    [8] = {
      { 3, 1, 4 },
      { 0, 2, 5 },
      { 1, 3, 6 },
      { 2, 0, -1 },
      { 7, 5, 0 },
      { 4, 6, 1 },
      { 5, 7, 2 },
      { 6, 4, 2 },
    },
  },
  navSubcontext = {
    [2] = { { 1, 1 }, { 0, 0 } },
    [3] = { { 2, 1 }, { 0, 2 }, { 1, 0 } },
    [4] = { { 3, 1 }, { 0, 2 }, { 1, 3 }, { 2, 0 } },
    [5] = { { 4, 1 }, { 0, 2 }, { 1, 3 }, { 2, 4 }, { 3, 0 } },
  },
  hitboxes = {
    { top = 24, bottom = 56, left = 128, right = 0 },
    { top = 56, bottom = 88, left = 128, right = 0 },
    { top = 88, bottom = 120, left = 128, right = 0 },
    { top = 16, bottom = 48, left = 0, right = 128 },
    { top = 48, bottom = 80, left = 0, right = 128 },
    { top = 80, bottom = 112, left = 0, right = 128 },
    { top = 112, bottom = 144, left = 0, right = 128 },
    { top = 152, bottom = 192, left = 200, right = 0 },
  },
  subHitboxes = {
    { top = 16, bottom = 48, left = 128, right = 0 },
    { top = 48, bottom = 80, left = 128, right = 0 },
    { top = 80, bottom = 112, left = 128, right = 0 },
    { top = 112, bottom = 144, left = 128, right = 0 },
    { top = 152, bottom = 192, left = 200, right = 0 },
  },
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
    male = { bank = 300, index = 27 },
    female = { bank = 300, index = 28 },
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
    takeNoItem = { bank = 300, index = 82 },
    bagFull = { bank = 300, index = 84 },
    switchHeldPrompt = { bank = 300, index = 79 },
    switchHeldResult = { bank = 300, index = 85 },
    giveHeldItem = { bank = 300, index = 107 },
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
  -- PartyMenu_SetMonHeldItemIconCoords derives held from icon +(8,8);
  -- PartyMenu_RefreshMonCapsuleIconSpritePos derives capsule from held +(8,0).
  indicatorOffsets = { heldFromIcon = { x = 8, y = 8 }, capsuleFromHeld = { x = 8, y = 0 } },
  -- Values select source cursor sequences; the compiler lowers them to the
  -- one-based index used by the generated manifest.
  cursorSequenceSelectors = { 1, 0, 0, 0, 0, 0 },
  -- sub_02079D38 moves the raw sprite template by y-8 during normal setup.
  controls = {
    cancel = {
      templateAnchor = { x = 232, y = 184 },
      normalSetupOffset = { x = 0, y = -8 },
      textRect = { x = 208, y = 168, width = 40, height = 16 },
      align = "center",
    },
  },
  detail = {
    iconAnchor = { x = 30, y = 200 },
    statusAnchor = { x = 50, y = 220 },
    nicknameTextOrigin = { x = 56, y = 192 },
    heldItemTextOrigin = { x = 138, y = 212 },
  },
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

-- Gender mark placement transcribed from PartyMenu_PrintMonNicknameOnWindow
-- (party_context_menu.c): the nickname prints at name-window-local (0,0)
-- and the gender mark at name-window-local (64,0), inside the 72px-wide
-- name window. The compiler lowers this offset against each panel's
-- name-subrect origin; the decomp symbol name stays in this producer
-- comment only and never reaches the runtime manifest.
PartySources.genderOffset = { x = 64, y = 0 }

return PartySources
