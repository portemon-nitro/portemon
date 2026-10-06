-- Producer-side semantic inventory of the native summary presentation
-- sources: NARC member selection, canonical geometry, sprite/text/numeric/
-- ribbon/performance/memo selection, and normalized presentation facts.
-- The audit basis is pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36:
-- src/pokemon.c (picture metadata and performance readers), src/pokepic.c
-- (frame interpreter), asm/unk_02016EDC.s (motion interpreter),
-- src/trainer_memo.c (encounter conditions and line placement),
-- src/ribbon.c (ribbon table and description rules), src/palette.c
-- (blend arithmetic), src/message_format.c (landmark/month names), and the
-- summary application/windows/picture/object modules (group maps, window
-- templates, picture anchor, sprite resources). Pure data and pure
-- functions; no I/O. Never imported by runtime: libs/assets, game, and
-- script packages must not require this module.

local SummarySources = {}

SummarySources.provenance = {
  repoPin = "0db201af99db913e5a90cdb9f372f4e0b63f4401",
  decompPin = "pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36",
  symbols = {
    "src/pokemon.c",
    "src/pokepic.c",
    "asm/unk_02016EDC.s",
    "src/trainer_memo.c",
    "src/ribbon.c",
    "src/palette.c",
    "src/message_format.c",
    "asm/unk_02088288.s",
    "asm/unk_0208B1AC.s",
    "asm/unk_0208C3E4.s",
    "asm/unk_0208DE40.s",
  },
}

-- Curated archive identities. NARC and NitroFS IDs are not interchangeable;
-- the symbol form is the only selector the compiler resolves.
SummarySources.archives = {
  ui = { symbol = "NARC_a_1_6_2", path = "a/1/6/2", members = 79 },
  shared = { symbol = "NARC_a_0_3_9", path = "a/0/3/9" },
  metadata = { symbol = "NARC_a_1_8_0", path = "a/1/8/0", records = 494, recordSize = 89 },
  motion = { symbol = "NARC_a_0_9_0", path = "a/0/9/0" },
  messages = { symbol = "NARC_msgdata_msg", path = "a/0/2/7" },
  resdat = { symbol = "NARC_data_resdat", path = "a/1/7/5" },
  performance = { symbol = "NARC_poketool_personal_performance", path = "a/1/6/9" },
  dexOrder = { symbol = "NARC_poketool_johtozukan", path = "a/1/3/8" },
  font = { symbol = "NARC_graphic_font", path = "a/0/1/6" },
}

-- Native group background selection, transcribed from the summary
-- application map tables. Main content renders on the main engine, touch
-- content on the sub engine. The locked and excluded alternatives cover
-- the hidden-performance, absent-group, and move-picker conditions; they
-- are distinct selections, never synonyms.
SummarySources.groupMaps = {
  info = { main = 13, sub = 12, restricted = 14, performanceExcludedSub = 77 },
  skills = { main = 19, sub = 17, restricted = 18, performanceExcludedSub = 78 },
  performance = { main = 10, sub = 9, lockedMain = 11 },
}

-- The 34 fixed window templates in tile units, transcribed from the
-- persistent summary window table. Each row names its background engine
-- (bg4 is the sub/touch engine, bg1 the main engine), tile origin and
-- size, source palette slot, and character base. The compiler lowers
-- tile units to pixels and the engine to its native pane; the source
-- base-tile allocator never reaches runtime. Semantic role names for
-- these rows live in SummarySources.fixedRoles below, aligned
-- positionally with this inventory.
SummarySources.fixedWindows = {
  { bg = "bg4", x = 20, y = 1, width = 11, height = 2, palette = 13, charBase = 0x001 },
  { bg = "bg1", x = 20, y = 1, width = 11, height = 2, palette = 13, charBase = 0x017 },
  { bg = "bg1", x = 20, y = 1, width = 11, height = 2, palette = 13, charBase = 0x02D },
  { bg = "bg1", x = 1, y = 0, width = 11, height = 2, palette = 13, charBase = 0x043 },
  { bg = "bg4", x = 20, y = 1, width = 11, height = 2, palette = 13, charBase = 0x059 },
  { bg = "bg1", x = 20, y = 1, width = 11, height = 2, palette = 13, charBase = 0x06F },
  { bg = "bg1", x = 20, y = 20, width = 6, height = 2, palette = 13, charBase = 0x085 },
  { bg = "bg4", x = 1, y = 1, width = 9, height = 2, palette = 13, charBase = 0x091 },
  { bg = "bg4", x = 1, y = 3, width = 5, height = 2, palette = 13, charBase = 0x0A3 },
  { bg = "bg4", x = 1, y = 5, width = 5, height = 2, palette = 13, charBase = 0x0AD },
  { bg = "bg4", x = 1, y = 7, width = 5, height = 2, palette = 13, charBase = 0x0B7 },
  { bg = "bg4", x = 1, y = 9, width = 5, height = 2, palette = 13, charBase = 0x0C1 },
  { bg = "bg4", x = 1, y = 11, width = 15, height = 2, palette = 13, charBase = 0x0CB },
  { bg = "bg4", x = 1, y = 15, width = 12, height = 2, palette = 13, charBase = 0x0E9 },
  { bg = "bg4", x = 6, y = 17, width = 3, height = 2, palette = 13, charBase = 0x101 },
  { bg = "bg1", x = 5, y = 3, width = 2, height = 2, palette = 13, charBase = 0x107 },
  { bg = "bg1", x = 3, y = 6, width = 6, height = 2, palette = 13, charBase = 0x10B },
  { bg = "bg1", x = 3, y = 8, width = 6, height = 2, palette = 13, charBase = 0x117 },
  { bg = "bg1", x = 3, y = 10, width = 6, height = 2, palette = 13, charBase = 0x123 },
  { bg = "bg1", x = 3, y = 12, width = 6, height = 2, palette = 13, charBase = 0x12F },
  { bg = "bg1", x = 3, y = 14, width = 6, height = 2, palette = 13, charBase = 0x13B },
  { bg = "bg1", x = 0, y = 17, width = 7, height = 2, palette = 13, charBase = 0x147 },
  { bg = "bg1", x = 1, y = 22, width = 6, height = 2, palette = 13, charBase = 0x147 },
  { bg = "bg4", x = 25, y = 21, width = 5, height = 2, palette = 13, charBase = 0x153 },
  { bg = "bg4", x = 18, y = 4, width = 6, height = 2, palette = 13, charBase = 0x169 },
  { bg = "bg4", x = 18, y = 6, width = 6, height = 2, palette = 13, charBase = 0x169 },
  { bg = "bg4", x = 18, y = 8, width = 8, height = 2, palette = 13, charBase = 0x175 },
  { bg = "bg1", x = 18, y = 11, width = 9, height = 2, palette = 13, charBase = 0x185 },
  { bg = "bg1", x = 2, y = 13, width = 12, height = 2, palette = 13, charBase = 0x197 },
  { bg = "bg4", x = 1, y = 17, width = 12, height = 2, palette = 13, charBase = 0x1AF },
  { bg = "bg4", x = 20, y = 1, width = 11, height = 2, palette = 13, charBase = 0x1C7 },
  { bg = "bg1", x = 20, y = 22, width = 12, height = 2, palette = 13, charBase = 0x1DD },
  { bg = "bg1", x = 20, y = 6, width = 6, height = 2, palette = 13, charBase = 0x1F5 },
  { bg = "bg1", x = 22, y = 4, width = 9, height = 2, palette = 13, charBase = 0x201 },
}

-- The normal-group window rows in tile units, transcribed from the three
-- group window tables in source order (info, skills, performance). The
-- compiler splits each inventory by background engine into its native
-- pane roles; tile units become pixels exactly like the fixed rows.
-- Semantic role names for these rows live in SummarySources.groupRoles
-- below: each pane list aligns positionally with that pane's rows of the
-- matching inventory.
SummarySources.groupWindows = {
  info = {
    { bg = "bg4", x = 12, y = 1, width = 3, height = 2, palette = 13 },
    { bg = "bg4", x = 9, y = 3, width = 9, height = 2, palette = 13 },
    { bg = "bg4", x = 9, y = 7, width = 9, height = 2, palette = 13 },
    { bg = "bg4", x = 11, y = 9, width = 5, height = 2, palette = 13 },
    { bg = "bg4", x = 10, y = 13, width = 7, height = 2, palette = 13 },
    { bg = "bg4", x = 11, y = 17, width = 6, height = 2, palette = 13 },
    { bg = "bg1", x = 0, y = 3, width = 18, height = 18, palette = 13 },
    { bg = "bg1", x = 1, y = 22, width = 11, height = 2, palette = 13 },
  },
  skills = {
    { bg = "bg1", x = 11, y = 3, width = 7, height = 2, palette = 13 },
    { bg = "bg1", x = 13, y = 6, width = 3, height = 2, palette = 13 },
    { bg = "bg1", x = 13, y = 8, width = 3, height = 2, palette = 13 },
    { bg = "bg1", x = 13, y = 10, width = 3, height = 2, palette = 13 },
    { bg = "bg1", x = 13, y = 12, width = 3, height = 2, palette = 13 },
    { bg = "bg1", x = 13, y = 14, width = 3, height = 2, palette = 13 },
    { bg = "bg1", x = 9, y = 17, width = 9, height = 2, palette = 13 },
    { bg = "bg1", x = 0, y = 19, width = 19, height = 4, palette = 13 },
    { bg = "bg4", x = 5, y = 1, width = 11, height = 4, palette = 13 },
    { bg = "bg4", x = 5, y = 5, width = 11, height = 4, palette = 13 },
    { bg = "bg4", x = 5, y = 9, width = 11, height = 4, palette = 13 },
    { bg = "bg4", x = 5, y = 13, width = 11, height = 4, palette = 13 },
    { bg = "bg4", x = 5, y = 19, width = 11, height = 4, palette = 13 },
    { bg = "bg4", x = 27, y = 6, width = 3, height = 2, palette = 13 },
    { bg = "bg4", x = 27, y = 8, width = 3, height = 2, palette = 13 },
    { bg = "bg4", x = 17, y = 10, width = 15, height = 10, palette = 13 },
    { bg = "bg4", x = 1, y = 20, width = 15, height = 2, palette = 13 },
    { bg = "bg4", x = 1, y = 17, width = 10, height = 2, palette = 13 },
  },
  performance = {
    { bg = "bg4", x = 13, y = 17, width = 5, height = 2, palette = 13 },
    { bg = "bg4", x = 1, y = 16, width = 21, height = 2, palette = 13 },
    { bg = "bg4", x = 1, y = 18, width = 30, height = 4, palette = 13 },
    { bg = "bg1", x = 1, y = 3, width = 10, height = 2, palette = 13 },
    { bg = "bg1", x = 1, y = 7, width = 10, height = 2, palette = 13 },
    { bg = "bg1", x = 1, y = 11, width = 10, height = 2, palette = 13 },
    { bg = "bg1", x = 1, y = 15, width = 10, height = 2, palette = 13 },
    { bg = "bg1", x = 1, y = 19, width = 10, height = 2, palette = 13 },
  },
}

-- Producer-only semantic role bindings for the fixed window inventory,
-- aligned positionally with SummarySources.fixedWindows. Names follow
-- the static label/header setup: group tabs and titles, the trainer-memo
-- header, the move-panel footer, the persistent info stat labels, the
-- skills stat and ability labels, the move-detail and power-point labels,
-- and the exit, ribbon-count, contest-mark, and move-warning labels.
-- These names never reach runtime directly; the compiler resolves them
-- to pane geometry records.
SummarySources.fixedRoles = {
  "infoTab",
  "infoTitle",
  "skillsTitle",
  "trainerMemo",
  "skillsTab",
  "performanceTitle",
  "cancelButton",
  "dexNoLabel",
  "nameLabel",
  "typeLabel",
  "otLabel",
  "idNoLabel",
  "expPointsLabel",
  "toNextLabel",
  "shinyLeaf",
  "hpLabel",
  "attackLabel",
  "defenseLabel",
  "spAttackLabel",
  "spDefenseLabel",
  "speedLabel",
  "abilityLabel",
  "switchButton",
  "exitLabel",
  "movePpHeader",
  "movePpCurrent",
  "movePpMax",
  "moveDetailHeader",
  "moveDetailNote",
  "battleMoves",
  "performanceTab",
  "ribbonsCountLabel",
  "performanceStarLabel",
  "hmWarning",
}

-- Producer-only semantic role bindings for the normal-group window
-- inventories. Each pane list aligns positionally with that pane's rows
-- of the matching SummarySources.groupWindows inventory, following the
-- group population routines: info carries its memo composition on the
-- main pane and its dex, species, ownership, and experience values on
-- the sub pane; skills carries its health, stat, and ability values on
-- the main pane and its move rows, prospective row, move-detail blocks,
-- and footer text on the sub pane; performance carries its five contest
-- rows on the main pane and its ribbon count, name, and description on
-- the sub pane. The compiler resolves these names to pane geometry
-- records; runtime never sees source table positions.
SummarySources.groupRoles = {
  info = {
    main = { "memoBody", "memoAuxLine" },
    sub = { "dexNumber", "speciesName", "otName", "idNumber", "expPoints", "expToNext" },
  },
  skills = {
    main = {
      "hpValue",
      "attackValue",
      "defenseValue",
      "spAttackValue",
      "spDefenseValue",
      "speedValue",
      "abilityName",
      "abilityDescription",
    },
    sub = {
      "moveRow0",
      "moveRow1",
      "moveRow2",
      "moveRow3",
      "prospectiveRow",
      "detailPower",
      "detailAccuracy",
      "detailDescription",
      "moveFooter",
      "detailCategory",
    },
  },
  performance = {
    main = { "speed", "power", "skill", "stamina", "jump" },
    sub = { "ribbonCount", "ribbonName", "ribbonDescription" },
  },
}

-- NSCR stamp fragments: archive members with their native pixel
-- dimensions. These are stamp compositions, never object frames; the
-- compiler crops each screen to its fragment size before stamping.
SummarySources.stamps = {
  { member = 69, width = 136, height = 48 },
  { member = 70, width = 136, height = 48 },
  { member = 71, width = 80, height = 32 },
  { member = 72, width = 80, height = 32 },
  { member = 73, width = 88, height = 112 },
  { member = 74, width = 48, height = 24 },
  { member = 75, width = 48, height = 24 },
}

-- Background members of the ui archive: per-engine character blocks, the
-- shared palette, the full-size screens selected by map id, and the
-- move-panel transition backing. Main screens address at most 258 tiles
-- and resolve through the main character block; sub screens and stamps
-- address up to their block through the sub character block. The backing
-- role is detail-scoped: the same member-21 screen backs both nested
-- move and ribbon states, so runtime never sees a move-only name.
SummarySources.backgrounds = {
  mainChar = 2,
  subChar = 1,
  palette = 0,
  moveChar = 20,
  detailBacking = 21,
}

-- Dynamic gauge rules transcribed from the summary application bar
-- routines (asm/unk_02088288.s, same pin): sub_0208A0EC draws the health
-- track and sub_0208A1A0 draws the experience track. Both fill
-- left to right through FillBgTilemapRect one 8-pixel tile column per
-- iteration: six columns for health (tile origin x=10, y=5) and seven
-- for experience (tile origin x=9, y=19), which fixes the native pixel
-- lengths below. Each column selects tile (base + remaining) while eight
-- or more fill pixels remain and the full tile (base + 8) otherwise, so
-- every run spans nine tiles from its empty tile to its full tile. The
-- fill quotient and the threshold color decision both reuse the shared
-- gauge helpers (src/unk_0208805C.c, same pin): the quotient is
-- floor(value * length / total) with a minimum of one filled pixel for
-- any nonzero value, and the color reads full when value equals total,
-- green above one half, yellow above one fifth, red above zero, and
-- fainted at zero. The division is unguarded at the source: a zero total
-- is outside the reachable domain (every stored mon carries total >= 1
-- and the track only evaluates for non-eggs); the experience span
-- collapses to 0/0 at level 100 and resolves to an empty track, which
-- the consumer reproduces by treating a zero span as empty fill.
-- tileBase selects the run in the named character block; paletteBank is
-- the background palette bank the tile fill value indexes; inkSlots name
-- the bright fill slot per state inside that bank (the dark companion
-- slot of each run carries the same hue one row above the bright rows).
-- The health runs share their empty track tiles; the fainted state draws
-- the green run at zero fill. Experience keeps its single blue run with
-- no threshold switch. Each run occurs in exactly one character block
-- with the matching palette nibble; the sibling blocks carry no such
-- nine-tile gradient at these indices (verified against the dump).
SummarySources.bars = {
  hp = {
    length = 48,
    columns = 6,
    charBlock = "mainChar",
    paletteBank = 15,
    runs = {
      full = 0x97,
      high = 0x97,
      mid = 0xB7,
      low = 0xD7,
    },
    tileBase = 0x97,
    inkSlots = { high = 6, low = 8, critical = 10 },
  },
  exp = {
    length = 56,
    columns = 7,
    charBlock = "subChar",
    paletteBank = 14,
    runs = {
      fill = 0x37,
    },
    tileBase = 0x37,
    inkSlots = { fill = 11 },
  },
}

-- Touch targets transcribed from the overlay hitbox tables in source
-- order (asm/unk_02088288.s and asm/unk_0208DE40.s, same pin). Rects
-- are { top, bottom, left, right } bytes on the 256x192 touch pane; a
-- right edge of 0 encodes 256. Entries keep their source table order:
-- the root tab/member/exit list first, then the move rows, then the
-- ribbon cells with page arrows and exit, then the state panel boxes.
--   tabs/member/exit: the ten-entry FindRect list. Indices 0-2 switch
--     groups through the enabled-group mask (skills/performance reject
--     eggs); index 3 exits; indices 4-9 switch party members through
--     the per-member eligibility check and are masked while the
--     application selector reads its picker mode.
--   moveRow0-3: the four-entry FindRect list; touched rows resolve only
--     when their move slot is occupied (blank rows are ineligible).
--   ribbonCell0-8: the twelve-entry FindRect list; cells resolve only
--     below the earned ribbon count (blank cells are ineligible) while
--     the page arrows and exit keep indices 9-11.
--   skillsWideRow/moveWideRow: the single-touch panel rows below the
--     move list. The skills row ignores eggs and otherwise confirms
--     with the decide effect; the move row confirms the pending detail
--     selection in move states and switches groups in the performance
--     root, so its effect is state-dependent, never a fixed action.
--   exitPanel: the single-touch state exit shared by the info, skills,
--     move, and ribbon states (one pixel inset from the root exit box).
--   selectorPair0-1: the two-entry FindRect list resolved only while the
--     application selector reads its restricted mode, through the
--     member-eligibility dispatcher.
-- Same-tab touches resolve through the group switch with the tab effect
-- even when the group does not change, so feedback is distinct from a
-- content rebuild. Member touches never apply in picker mode.
SummarySources.touch = {
  { key = "tabInfo", top = 165, bottom = 191, left = 2, right = 45 },
  { key = "tabSkills", top = 165, bottom = 191, left = 48, right = 96 },
  { key = "tabPerformance", top = 165, bottom = 191, left = 99, right = 140 },
  { key = "exitChrome", top = 165, bottom = 191, left = 189, right = 250 },
  { key = "member0", top = 38, bottom = 66, left = 165, right = 203 },
  { key = "member1", top = 46, bottom = 74, left = 205, right = 243 },
  { key = "member2", top = 70, bottom = 98, left = 165, right = 203 },
  { key = "member3", top = 78, bottom = 106, left = 205, right = 243 },
  { key = "member4", top = 102, bottom = 130, left = 165, right = 203 },
  { key = "member5", top = 110, bottom = 138, left = 205, right = 243 },
  { key = "moveRow0", top = 8, bottom = 39, left = 8, right = 127 },
  { key = "moveRow1", top = 40, bottom = 71, left = 8, right = 127 },
  { key = "moveRow2", top = 72, bottom = 103, left = 8, right = 127 },
  { key = "moveRow3", top = 104, bottom = 135, left = 8, right = 127 },
  { key = "ribbonCell0", top = 8, bottom = 39, left = 16, right = 47 },
  { key = "ribbonCell1", top = 8, bottom = 39, left = 48, right = 79 },
  { key = "ribbonCell2", top = 8, bottom = 39, left = 80, right = 112 },
  { key = "ribbonCell3", top = 48, bottom = 79, left = 16, right = 47 },
  { key = "ribbonCell4", top = 48, bottom = 79, left = 48, right = 79 },
  { key = "ribbonCell5", top = 48, bottom = 79, left = 80, right = 112 },
  { key = "ribbonCell6", top = 88, bottom = 119, left = 16, right = 47 },
  { key = "ribbonCell7", top = 88, bottom = 119, left = 48, right = 79 },
  { key = "ribbonCell8", top = 88, bottom = 119, left = 80, right = 112 },
  { key = "ribbonPagePrev", top = 12, bottom = 51, left = 116, right = 139 },
  { key = "ribbonPageNext", top = 76, bottom = 115, left = 116, right = 139 },
  { key = "ribbonExit", top = 176, bottom = 191, left = 208, right = 255 },
  { key = "skillsWideRow", top = 136, bottom = 151, left = 8, right = 87 },
  { key = "moveWideRow", top = 152, bottom = 183, left = 8, right = 127 },
  { key = "exitPanel", top = 165, bottom = 188, left = 190, right = 249 },
  { key = "selectorPair0", top = 40, bottom = 63, left = 192, right = 239 },
  { key = "selectorPair1", top = 104, bottom = 127, left = 192, right = 239 },
}

-- Calibrated absences: sections the compiler intentionally leaves empty.
-- The overlay selects numeric sound ids at its state call sites and no
-- generated-family consumer resolves sound roles yet: controller sound
-- decisions are optional feedback. The manifest keeps the closed sounds
-- key with its shape validator so a future populated section validates;
-- emptiness is the documented complete state, never a missing
-- population. Transition tracks are no longer absent: the nested
-- move/ribbon states consume generated BG position traces.
SummarySources.absences = {
  sounds = "no generated-family consumer resolves sound roles",
}

-- The front-picture anchor the summary picture setup centers on.
SummarySources.pictureAnchor = { x = 208, y = 104 }

-- Message banks consumed by the summary lowering. Bank identities stop
-- at the compiler boundary; runtime sees named templates only.
SummarySources.textBanks = {
  summary = 302,
  ribbons = 424,
  landmarks = 279,
  giftLandmarks = 281,
  externalLandmarks = 280,
  months = 239,
}

-- Substitution roles for the summary bank: control code to semantic
-- field. Placeholder indices follow the trainer-memo buffer order
-- (0 met year, 1 month, 2 met day, 3 met level, 4 location, 5 egg year,
-- 6 egg month, 7 egg day, 8 egg location); other templates carry field 0.
SummarySources.substitutions = {
  [0x0100] = { role = "species" },
  [0x0101] = { role = "nickname" },
  [0x0103] = { role = "otName" },
  [0x0104] = { role = "landmark" },
  [0x0105] = { role = "ability" },
  [0x0106] = { role = "move" },
  [0x0108] = { role = "item" },
  [0x0133] = { role = "number" },
  [0x0134] = { role = "number" },
  [0x0136] = { role = "idNumber" },
  [0x0137] = { role = "expToNext" },
  [0x0138] = { role = "expPoints" },
  [0x3410] = { role = "month" },
}

-- Window text palette roles transcribed from the printer triples at the
-- summary window/text module call sites (asm/unk_0208C3E4.s, same pin as
-- the window templates above). Every site prints through
-- AddTextPrinterParameterizedWithColor, whose color word is
-- MAKE_TEXT_COLOR(fg, sh, bg) (include/text.h): each triple names
-- { foreground, shadow, background } slots in the window palette bank
-- below. All 34 window templates select bank 13, so every triple indexes
-- that bank; the background slot matches the window fill the call site
-- applies first (FillWindowPixelBuffer 0 for ordinary windows, 15 for
-- the move-panel window), which the runtime keeps as transparent ink
-- over its realized chrome.
--   ordinary { 14, 15, 0 } (0x000E0F00): the default light ink, the base
--     the gender and nature variants deviate from (sub_0208C57C,
--     _0208CA1E, twenty sub_0208C850 selections, helpers at the
--     memo/ribbon/panel blocks).
--   dark { 1, 2, 0 } (0x00010200): the dominant dark ink for stat, move,
--     and panel rows (over thirty direct and helper selections,
--     including the computed r6 << 7 window at sub_0208C614).
--   male { 3, 4, 0 } (0x30400, 0xC1 << 10): the male gender mark
--     (sub_0208C57C message genderMale, _0208CE2A).
--   female { 5, 6, 0 } (0x00050600): the female gender mark
--     (sub_0208C57C message genderFemale, _0208CE96).
--   statLowered { 14, 8, 0 } (0x000E0800): nature-lowered stat values
--     (sub_0208C7F8 selects it while gNatureStatMods reads negative).
--   statRaised { 14, 7, 0 } (0x000E0700): nature-raised stat values
--     (sub_0208C7F8 selects it while gNatureStatMods reads positive).
--   movePanel { 1, 2, 15 } (0x0001020F): move-detail ink over the
--     fill-15 panel window (_0208DDE4).
-- windowSlots binds every numeric window palette slot the templates use
-- to its resolving ink; the compiler rejects a used slot without a
-- binding instead of publishing an unresolvable family.
SummarySources.textRoles = {
  bank = 13,
  windowSlots = { [13] = "ordinary" },
  inks = {
    ordinary = { 14, 15, 0 },
    dark = { 1, 2, 0 },
    male = { 3, 4, 0 },
    female = { 5, 6, 0 },
    statLowered = { 14, 8, 0 },
    statRaised = { 14, 7, 0 },
    movePanel = { 1, 2, 15 },
  },
}

-- The 80 ribbon definitions in source order, transcribing src/ribbon.c
-- `sRibbonInfo`. `monData` is the native mon-data field id; the bit
-- binding resolves it to the boxed ribbon group/bit on the producer side.
-- `art` selects the shared-graphics character member, `palette` its
-- palette bank. `name` selects the ribbon message; plain descriptions
-- select one too while special descriptions select a caller-context slot.
SummarySources.ribbons = {
  {
    key = "champion_ribbon",
    monData = 98,
    bitGroup = "gba",
    bit = 20,
    art = 72,
    palette = 0,
    name = 0,
    description = 80,
  },
  { key = "cool_ribbon", monData = 78, bitGroup = "gba", bit = 0, art = 73, palette = 0, name = 1, description = 81 },
  {
    key = "cool_ribbon_super",
    monData = 79,
    bitGroup = "gba",
    bit = 1,
    art = 74,
    palette = 0,
    name = 2,
    description = 82,
  },
  {
    key = "cool_ribbon_hyper",
    monData = 80,
    bitGroup = "gba",
    bit = 2,
    art = 75,
    palette = 0,
    name = 3,
    description = 83,
  },
  {
    key = "cool_ribbon_master",
    monData = 81,
    bitGroup = "gba",
    bit = 3,
    art = 76,
    palette = 0,
    name = 4,
    description = 84,
  },
  { key = "beauty_ribbon", monData = 82, bitGroup = "gba", bit = 4, art = 73, palette = 1, name = 5, description = 85 },
  {
    key = "beauty_ribbon_super",
    monData = 83,
    bitGroup = "gba",
    bit = 5,
    art = 74,
    palette = 1,
    name = 6,
    description = 86,
  },
  {
    key = "beauty_ribbon_hyper",
    monData = 84,
    bitGroup = "gba",
    bit = 6,
    art = 75,
    palette = 1,
    name = 7,
    description = 87,
  },
  {
    key = "beauty_ribbon_master",
    monData = 85,
    bitGroup = "gba",
    bit = 7,
    art = 76,
    palette = 1,
    name = 8,
    description = 88,
  },
  { key = "cute_ribbon", monData = 86, bitGroup = "gba", bit = 8, art = 73, palette = 2, name = 9, description = 89 },
  {
    key = "cute_ribbon_super",
    monData = 87,
    bitGroup = "gba",
    bit = 9,
    art = 74,
    palette = 2,
    name = 10,
    description = 90,
  },
  {
    key = "cute_ribbon_hyper",
    monData = 88,
    bitGroup = "gba",
    bit = 10,
    art = 75,
    palette = 2,
    name = 11,
    description = 91,
  },
  {
    key = "cute_ribbon_master",
    monData = 89,
    bitGroup = "gba",
    bit = 11,
    art = 76,
    palette = 2,
    name = 12,
    description = 92,
  },
  {
    key = "smart_ribbon",
    monData = 90,
    bitGroup = "gba",
    bit = 12,
    art = 73,
    palette = 3,
    name = 13,
    description = 93,
  },
  {
    key = "smart_ribbon_super",
    monData = 91,
    bitGroup = "gba",
    bit = 13,
    art = 74,
    palette = 3,
    name = 14,
    description = 94,
  },
  {
    key = "smart_ribbon_hyper",
    monData = 92,
    bitGroup = "gba",
    bit = 14,
    art = 75,
    palette = 3,
    name = 15,
    description = 95,
  },
  {
    key = "smart_ribbon_master",
    monData = 93,
    bitGroup = "gba",
    bit = 15,
    art = 76,
    palette = 3,
    name = 16,
    description = 96,
  },
  {
    key = "tough_ribbon",
    monData = 94,
    bitGroup = "gba",
    bit = 16,
    art = 73,
    palette = 4,
    name = 17,
    description = 97,
  },
  {
    key = "tough_ribbon_super",
    monData = 95,
    bitGroup = "gba",
    bit = 17,
    art = 74,
    palette = 4,
    name = 18,
    description = 98,
  },
  {
    key = "tough_ribbon_hyper",
    monData = 96,
    bitGroup = "gba",
    bit = 18,
    art = 75,
    palette = 4,
    name = 19,
    description = 99,
  },
  {
    key = "tough_ribbon_master",
    monData = 97,
    bitGroup = "gba",
    bit = 19,
    art = 76,
    palette = 4,
    name = 20,
    description = 100,
  },
  {
    key = "winning_ribbon",
    monData = 99,
    bitGroup = "gba",
    bit = 21,
    art = 78,
    palette = 0,
    name = 21,
    description = 101,
  },
  {
    key = "victory_ribbon",
    monData = 100,
    bitGroup = "gba",
    bit = 22,
    art = 77,
    palette = 0,
    name = 22,
    description = 102,
  },
  {
    key = "artist_ribbon",
    monData = 101,
    bitGroup = "gba",
    bit = 23,
    art = 79,
    palette = 1,
    name = 23,
    description = 103,
  },
  {
    key = "effort_ribbon",
    monData = 102,
    bitGroup = "gba",
    bit = 24,
    art = 80,
    palette = 2,
    name = 24,
    description = 104,
  },
  { key = "marine_ribbon", monData = 103, bitGroup = "gba", bit = 25, art = 81, palette = 1, name = 25, special = 0 },
  { key = "land_ribbon", monData = 104, bitGroup = "gba", bit = 26, art = 81, palette = 3, name = 26, special = 1 },
  { key = "sky_ribbon", monData = 105, bitGroup = "gba", bit = 27, art = 81, palette = 4, name = 27, special = 2 },
  {
    key = "country_ribbon",
    monData = 106,
    bitGroup = "gba",
    bit = 28,
    art = 82,
    palette = 3,
    name = 28,
    description = 178,
  },
  {
    key = "national_ribbon",
    monData = 107,
    bitGroup = "gba",
    bit = 29,
    art = 82,
    palette = 4,
    name = 29,
    description = 190,
  },
  {
    key = "earth_ribbon",
    monData = 108,
    bitGroup = "gba",
    bit = 30,
    art = 83,
    palette = 0,
    name = 30,
    description = 191,
  },
  {
    key = "world_ribbon",
    monData = 109,
    bitGroup = "gba",
    bit = 31,
    art = 83,
    palette = 1,
    name = 31,
    description = 178,
  },
  {
    key = "sinnoh_champ_ribbon",
    monData = 25,
    bitGroup = "ds1",
    bit = 0,
    art = 88,
    palette = 0,
    name = 32,
    description = 105,
  },
  {
    key = "super_cool_ribbon",
    monData = 123,
    bitGroup = "ds2",
    bit = 0,
    art = 89,
    palette = 0,
    name = 33,
    description = 106,
  },
  {
    key = "super_cool_ribbon_great",
    monData = 124,
    bitGroup = "ds2",
    bit = 1,
    art = 90,
    palette = 0,
    name = 34,
    description = 107,
  },
  {
    key = "super_cool_ribbon_ultra",
    monData = 125,
    bitGroup = "ds2",
    bit = 2,
    art = 91,
    palette = 0,
    name = 35,
    description = 108,
  },
  {
    key = "super_cool_ribbon_master",
    monData = 126,
    bitGroup = "ds2",
    bit = 3,
    art = 92,
    palette = 0,
    name = 36,
    description = 109,
  },
  {
    key = "super_beauty_ribbon",
    monData = 127,
    bitGroup = "ds2",
    bit = 4,
    art = 89,
    palette = 1,
    name = 37,
    description = 110,
  },
  {
    key = "super_beauty_ribbon_great",
    monData = 128,
    bitGroup = "ds2",
    bit = 5,
    art = 90,
    palette = 1,
    name = 38,
    description = 111,
  },
  {
    key = "super_beauty_ribbon_ultra",
    monData = 129,
    bitGroup = "ds2",
    bit = 6,
    art = 91,
    palette = 1,
    name = 39,
    description = 112,
  },
  {
    key = "super_beauty_ribbon_master",
    monData = 130,
    bitGroup = "ds2",
    bit = 7,
    art = 92,
    palette = 1,
    name = 40,
    description = 113,
  },
  {
    key = "super_cute_ribbon",
    monData = 131,
    bitGroup = "ds2",
    bit = 8,
    art = 89,
    palette = 2,
    name = 41,
    description = 114,
  },
  {
    key = "super_cute_ribbon_great",
    monData = 132,
    bitGroup = "ds2",
    bit = 9,
    art = 90,
    palette = 2,
    name = 42,
    description = 115,
  },
  {
    key = "super_cute_ribbon_ultra",
    monData = 133,
    bitGroup = "ds2",
    bit = 10,
    art = 91,
    palette = 2,
    name = 43,
    description = 116,
  },
  {
    key = "super_cute_ribbon_master",
    monData = 134,
    bitGroup = "ds2",
    bit = 11,
    art = 92,
    palette = 2,
    name = 44,
    description = 117,
  },
  {
    key = "super_smart_ribbon",
    monData = 135,
    bitGroup = "ds2",
    bit = 12,
    art = 89,
    palette = 3,
    name = 45,
    description = 118,
  },
  {
    key = "super_smart_ribbon_great",
    monData = 136,
    bitGroup = "ds2",
    bit = 13,
    art = 90,
    palette = 3,
    name = 46,
    description = 119,
  },
  {
    key = "super_smart_ribbon_ultra",
    monData = 137,
    bitGroup = "ds2",
    bit = 14,
    art = 91,
    palette = 3,
    name = 47,
    description = 120,
  },
  {
    key = "super_smart_ribbon_master",
    monData = 138,
    bitGroup = "ds2",
    bit = 15,
    art = 92,
    palette = 3,
    name = 48,
    description = 121,
  },
  {
    key = "super_tough_ribbon",
    monData = 139,
    bitGroup = "ds2",
    bit = 16,
    art = 89,
    palette = 4,
    name = 49,
    description = 122,
  },
  {
    key = "super_tough_ribbon_great",
    monData = 140,
    bitGroup = "ds2",
    bit = 17,
    art = 90,
    palette = 4,
    name = 50,
    description = 123,
  },
  {
    key = "super_tough_ribbon_ultra",
    monData = 141,
    bitGroup = "ds2",
    bit = 18,
    art = 91,
    palette = 4,
    name = 51,
    description = 124,
  },
  {
    key = "super_tough_ribbon_master",
    monData = 142,
    bitGroup = "ds2",
    bit = 19,
    art = 92,
    palette = 4,
    name = 52,
    description = 125,
  },
  {
    key = "ability_ribbon",
    monData = 26,
    bitGroup = "ds1",
    bit = 1,
    art = 93,
    palette = 0,
    name = 53,
    description = 126,
  },
  {
    key = "great_ability_ribbon",
    monData = 27,
    bitGroup = "ds1",
    bit = 2,
    art = 94,
    palette = 0,
    name = 54,
    description = 127,
  },
  {
    key = "double_ability_ribbon",
    monData = 28,
    bitGroup = "ds1",
    bit = 3,
    art = 95,
    palette = 0,
    name = 55,
    description = 128,
  },
  {
    key = "multi_ability_ribbon",
    monData = 29,
    bitGroup = "ds1",
    bit = 4,
    art = 96,
    palette = 0,
    name = 56,
    description = 129,
  },
  {
    key = "pair_ability_ribbon",
    monData = 30,
    bitGroup = "ds1",
    bit = 5,
    art = 97,
    palette = 0,
    name = 57,
    description = 130,
  },
  {
    key = "world_ability_ribbon",
    monData = 31,
    bitGroup = "ds1",
    bit = 6,
    art = 98,
    palette = 0,
    name = 58,
    description = 131,
  },
  {
    key = "alert_ribbon",
    monData = 32,
    bitGroup = "ds1",
    bit = 7,
    art = 99,
    palette = 2,
    name = 59,
    description = 132,
  },
  {
    key = "shock_ribbon",
    monData = 33,
    bitGroup = "ds1",
    bit = 8,
    art = 100,
    palette = 0,
    name = 60,
    description = 133,
  },
  {
    key = "downcast_ribbon",
    monData = 34,
    bitGroup = "ds1",
    bit = 9,
    art = 101,
    palette = 1,
    name = 61,
    description = 134,
  },
  {
    key = "careless_ribbon",
    monData = 35,
    bitGroup = "ds1",
    bit = 10,
    art = 102,
    palette = 2,
    name = 62,
    description = 135,
  },
  {
    key = "relax_ribbon",
    monData = 36,
    bitGroup = "ds1",
    bit = 11,
    art = 103,
    palette = 3,
    name = 63,
    description = 136,
  },
  {
    key = "snooze_ribbon",
    monData = 37,
    bitGroup = "ds1",
    bit = 12,
    art = 104,
    palette = 0,
    name = 64,
    description = 137,
  },
  {
    key = "smile_ribbon",
    monData = 38,
    bitGroup = "ds1",
    bit = 13,
    art = 105,
    palette = 2,
    name = 65,
    description = 138,
  },
  {
    key = "gorgeous_ribbon",
    monData = 39,
    bitGroup = "ds1",
    bit = 14,
    art = 106,
    palette = 1,
    name = 66,
    description = 139,
  },
  {
    key = "royal_ribbon",
    monData = 40,
    bitGroup = "ds1",
    bit = 15,
    art = 107,
    palette = 3,
    name = 67,
    description = 140,
  },
  {
    key = "gorgeous_royal_ribbon",
    monData = 41,
    bitGroup = "ds1",
    bit = 16,
    art = 108,
    palette = 0,
    name = 68,
    description = 141,
  },
  {
    key = "footprint_ribbon",
    monData = 42,
    bitGroup = "ds1",
    bit = 17,
    art = 109,
    palette = 0,
    name = 69,
    description = 142,
  },
  {
    key = "record_ribbon",
    monData = 43,
    bitGroup = "ds1",
    bit = 18,
    art = 110,
    palette = 1,
    name = 70,
    description = 143,
  },
  {
    key = "history_ribbon",
    monData = 44,
    bitGroup = "ds1",
    bit = 19,
    art = 111,
    palette = 3,
    name = 71,
    description = 144,
  },
  {
    key = "legend_ribbon",
    monData = 45,
    bitGroup = "ds1",
    bit = 20,
    art = 112,
    palette = 0,
    name = 72,
    description = 145,
  },
  { key = "red_ribbon", monData = 46, bitGroup = "ds1", bit = 21, art = 113, palette = 0, name = 73, special = 7 },
  { key = "green_ribbon", monData = 47, bitGroup = "ds1", bit = 22, art = 114, palette = 3, name = 74, special = 8 },
  { key = "blue_ribbon", monData = 48, bitGroup = "ds1", bit = 23, art = 115, palette = 1, name = 75, special = 9 },
  {
    key = "festival_ribbon",
    monData = 49,
    bitGroup = "ds1",
    bit = 24,
    art = 116,
    palette = 1,
    name = 76,
    special = 10,
  },
  {
    key = "carnival_ribbon",
    monData = 50,
    bitGroup = "ds1",
    bit = 25,
    art = 117,
    palette = 0,
    name = 77,
    special = 11,
  },
  { key = "classic_ribbon", monData = 51, bitGroup = "ds1", bit = 26, art = 118, palette = 1, name = 78, special = 12 },
  { key = "premier_ribbon", monData = 52, bitGroup = "ds1", bit = 27, art = 119, palette = 0, name = 79, special = 13 },
}

-- Special ribbon description slots, transcribing the RIBBON_DESC slot
-- values in src/ribbon.c. The runtime description is message
-- `descriptionBase + context[slot]`; the initial context is caller
-- supplied per open, so the producer records the zero context the
-- zero-initialized caller state provides.
SummarySources.ribbonSpecials = {
  base = 146,
  slots = { 0, 1, 2, 7, 8, 9, 10, 11, 12, 13 },
}

-- Species to performance-member indices, transcribing
-- `sPokeathlonPerformanceArcIdxs` in src/pokemon.c. The member for one
-- form is the species index plus the form id.
SummarySources.performanceArcIdxs = {
  0,
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  35,
  36,
  37,
  38,
  39,
  40,
  41,
  42,
  43,
  44,
  45,
  46,
  47,
  48,
  49,
  50,
  51,
  52,
  53,
  54,
  55,
  56,
  57,
  58,
  59,
  60,
  61,
  62,
  63,
  64,
  65,
  66,
  67,
  68,
  69,
  70,
  71,
  72,
  73,
  74,
  75,
  76,
  77,
  78,
  79,
  80,
  81,
  82,
  83,
  84,
  85,
  86,
  87,
  88,
  89,
  90,
  91,
  92,
  93,
  94,
  95,
  96,
  97,
  98,
  99,
  100,
  101,
  102,
  103,
  104,
  105,
  106,
  107,
  108,
  109,
  110,
  111,
  112,
  113,
  114,
  115,
  116,
  117,
  118,
  119,
  120,
  121,
  122,
  123,
  124,
  125,
  126,
  127,
  128,
  129,
  130,
  131,
  132,
  133,
  134,
  135,
  136,
  137,
  138,
  139,
  140,
  141,
  142,
  143,
  144,
  145,
  146,
  147,
  148,
  149,
  150,
  151,
  152,
  153,
  154,
  155,
  156,
  157,
  158,
  159,
  160,
  161,
  162,
  163,
  164,
  165,
  166,
  167,
  168,
  169,
  170,
  171,
  173,
  174,
  175,
  176,
  177,
  178,
  179,
  180,
  181,
  182,
  183,
  184,
  185,
  186,
  187,
  188,
  189,
  190,
  191,
  192,
  193,
  194,
  195,
  196,
  197,
  198,
  199,
  200,
  201,
  229,
  230,
  231,
  232,
  233,
  234,
  235,
  236,
  237,
  238,
  239,
  240,
  241,
  242,
  243,
  244,
  245,
  246,
  247,
  248,
  249,
  250,
  251,
  252,
  253,
  254,
  255,
  256,
  257,
  258,
  259,
  260,
  261,
  262,
  263,
  264,
  265,
  266,
  267,
  268,
  269,
  270,
  271,
  272,
  273,
  274,
  275,
  276,
  277,
  278,
  279,
  280,
  281,
  282,
  283,
  284,
  285,
  286,
  287,
  288,
  289,
  290,
  291,
  292,
  293,
  294,
  295,
  296,
  297,
  298,
  299,
  300,
  301,
  302,
  303,
  304,
  305,
  306,
  307,
  308,
  309,
  310,
  311,
  312,
  313,
  314,
  315,
  316,
  317,
  318,
  319,
  320,
  321,
  322,
  323,
  324,
  325,
  326,
  327,
  328,
  329,
  330,
  331,
  332,
  333,
  334,
  335,
  336,
  337,
  338,
  339,
  340,
  341,
  342,
  343,
  344,
  345,
  346,
  347,
  348,
  349,
  350,
  351,
  352,
  353,
  354,
  355,
  356,
  357,
  358,
  359,
  360,
  361,
  362,
  363,
  364,
  365,
  366,
  367,
  368,
  369,
  370,
  371,
  372,
  373,
  374,
  375,
  376,
  377,
  378,
  379,
  380,
  381,
  382,
  383,
  384,
  385,
  386,
  387,
  388,
  389,
  390,
  391,
  392,
  393,
  394,
  395,
  396,
  397,
  398,
  399,
  400,
  401,
  402,
  403,
  404,
  405,
  406,
  407,
  408,
  409,
  410,
  411,
  412,
  413,
  417,
  418,
  419,
  420,
  421,
  422,
  423,
  424,
  425,
  426,
  427,
  428,
  429,
  430,
  431,
  432,
  433,
  434,
  435,
  436,
  437,
  438,
  439,
  440,
  441,
  442,
  445,
  448,
  449,
  450,
  451,
  452,
  453,
  454,
  455,
  456,
  458,
  460,
  461,
  462,
  463,
  464,
  465,
  466,
  467,
  468,
  469,
  470,
  471,
  472,
  473,
  474,
  475,
  476,
  477,
  478,
  479,
  480,
  481,
  482,
  483,
  484,
  485,
  486,
  487,
  488,
  489,
  490,
  491,
  492,
  493,
  494,
  495,
  496,
  497,
  498,
  499,
  500,
  501,
  502,
  503,
  504,
  505,
  506,
  507,
  508,
  509,
  510,
  511,
  512,
  513,
  514,
  515,
  521,
  522,
  523,
  524,
  525,
  526,
  527,
  528,
  530,
  531,
  532,
  533,
  534,
  536,
}

-- Nature modifiers per stat, transcribing
-- `sPokeathlonPerformanceNatureMods` in src/pokemon.c. Rows follow nature
-- order; columns follow power, skill, speed, jump, stamina.
SummarySources.performanceNatureMods = {
  { 10, 0, 0, 0, -10 },
  { 35, -35, 0, 0, 0 },
  { 35, 0, 0, 0, -35 },
  { 35, 0, 0, -35, 0 },
  { 35, 0, -35, 0, 0 },
  { -35, 35, 0, 0, 0 },
  { 0, 10, 0, -10, 0 },
  { 0, 35, 0, 0, -35 },
  { 0, 35, 0, -35, 0 },
  { 0, 35, -35, 0, 0 },
  { -35, 0, 0, 0, 35 },
  { 0, -35, 0, 0, 35 },
  { 0, 0, -10, 0, 10 },
  { 0, 0, 0, -35, 35 },
  { 0, 0, -35, 0, 35 },
  { -35, 0, 0, 35, 0 },
  { 0, -35, 0, 35, 0 },
  { 0, 0, 0, 35, -35 },
  { -10, 0, 0, 10, 0 },
  { 0, 0, -35, 35, 0 },
  { -35, 0, 35, 0, 0 },
  { 0, -35, 35, 0, 0 },
  { 0, 0, 35, 0, -35 },
  { 0, 0, 35, -35, 0 },
  { 0, -10, 10, 0, 0 },
}

-- Encounter conditions in source evaluation order, transcribing
-- `MonMetCondition` and the notepad switch in src/trainer_memo.c. The
-- first condition whose predicate holds selects the template; line
-- numbers place each formatted run, with 0 meaning the run is absent.
-- Location predicates use packed map-section ids (normal mapsec,
-- 4000 + gift offset, 6000 + external offset). Every entry participates
-- in first-match runtime selection except entries flagged as closure
-- helpers, which only document template inheritance for the compiler.
-- Predicate classes are producer-side semantics: `egg`/`fateful`/`mine`
-- are mon facts, while `eggLocation`/`metLocation` name the normalized
-- location classes the compiler publishes (see memoGiftEggOrigins and
-- memoFieldSemantics below). Absent fields constrain nothing; order
-- makes the negative classes (`notPalPark`) and the ordinary classes
-- (`wild`, `hatched`, `egg`) well-defined fallbacks.
SummarySources.memoConditions = {
  {
    key = "migrated",
    template = 64,
    nature = 1,
    date = 2,
    characteristic = 6,
    flavor = 7,
    eggWatch = 0,
    egg = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "palPark",
  },
  {
    key = "fatefulEncounter",
    template = 56,
    nature = 1,
    date = 2,
    characteristic = 7,
    flavor = 8,
    eggWatch = 0,
    egg = false,
    fateful = true,
    mine = true,
    eggLocation = "none",
    metLocation = "notPalPark",
  },
  {
    key = "fatefulEncounterTraded",
    template = 57,
    nature = 1,
    date = 2,
    characteristic = 7,
    flavor = 8,
    eggWatch = 0,
    egg = false,
    fateful = true,
    mine = false,
    eggLocation = "none",
    metLocation = "notPalPark",
  },
  {
    key = "wildGift",
    template = 51,
    nature = 1,
    date = 2,
    characteristic = 6,
    flavor = 7,
    eggWatch = 0,
    egg = false,
    fateful = false,
    eggLocation = "none",
    metLocation = "linkTrade",
  },
  -- Consumer-closure entry, not a source branch: MonMetCondition maps a
  -- traded gift-location mon to MET_CONDITION_WILD_GIFT above, so the
  -- traded variant inherits that branch's template and line placement.
  -- The closure flag marks the inheritance for the compiler and reviewers.
  {
    key = "wildGiftTraded",
    template = 51,
    nature = 1,
    date = 2,
    characteristic = 6,
    flavor = 7,
    eggWatch = 0,
    egg = false,
    fateful = false,
    mine = false,
    eggLocation = "none",
    metLocation = "linkTrade",
    closure = true,
  },
  {
    key = "wildEncounter",
    template = 49,
    nature = 1,
    date = 2,
    characteristic = 6,
    flavor = 7,
    eggWatch = 0,
    egg = false,
    fateful = false,
    mine = true,
    eggLocation = "none",
    metLocation = "wild",
  },
  {
    key = "wildEncounterTraded",
    template = 50,
    nature = 1,
    date = 2,
    characteristic = 6,
    flavor = 7,
    eggWatch = 0,
    egg = false,
    fateful = false,
    mine = false,
    eggLocation = "none",
    metLocation = "wild",
  },
  {
    key = "fatefulEggHatchedGift",
    template = 62,
    nature = 1,
    date = 2,
    characteristic = 9,
    flavor = 0,
    eggWatch = 0,
    egg = false,
    fateful = true,
    mine = true,
    eggLocation = "linkTrade2",
  },
  {
    key = "fatefulEggHatchedGiftTraded",
    template = 63,
    nature = 1,
    date = 2,
    characteristic = 9,
    flavor = 0,
    eggWatch = 0,
    egg = false,
    fateful = true,
    mine = false,
    eggLocation = "linkTrade2",
  },
  {
    key = "fatefulEggHatchedArrived",
    template = 60,
    nature = 1,
    date = 2,
    characteristic = 9,
    flavor = 0,
    eggWatch = 0,
    egg = false,
    fateful = true,
    mine = true,
    eggLocation = "ranger",
  },
  {
    key = "fatefulEggHatchedArrivedTraded",
    template = 61,
    nature = 1,
    date = 2,
    characteristic = 9,
    flavor = 0,
    eggWatch = 0,
    egg = false,
    fateful = true,
    mine = false,
    eggLocation = "ranger",
  },
  {
    key = "fatefulEggHatched",
    template = 58,
    nature = 1,
    date = 2,
    characteristic = 9,
    flavor = 0,
    eggWatch = 0,
    egg = false,
    fateful = true,
    mine = true,
    eggLocation = "hatched",
  },
  {
    key = "fatefulEggHatchedTraded",
    template = 59,
    nature = 1,
    date = 2,
    characteristic = 9,
    flavor = 0,
    eggWatch = 0,
    egg = false,
    fateful = true,
    mine = false,
    eggLocation = "hatched",
  },
  {
    key = "eggHatchedGift",
    template = 54,
    nature = 1,
    date = 2,
    characteristic = 8,
    flavor = 9,
    eggWatch = 0,
    egg = false,
    fateful = false,
    mine = true,
    eggLocation = "giftSet",
  },
  {
    key = "eggHatchedGiftTraded",
    template = 55,
    nature = 1,
    date = 2,
    characteristic = 8,
    flavor = 9,
    eggWatch = 0,
    egg = false,
    fateful = false,
    mine = false,
    eggLocation = "giftSet",
  },
  {
    key = "eggHatched",
    template = 52,
    nature = 1,
    date = 2,
    characteristic = 8,
    flavor = 9,
    eggWatch = 0,
    egg = false,
    fateful = false,
    mine = true,
    eggLocation = "hatched",
  },
  {
    key = "eggHatchedTraded",
    template = 53,
    nature = 1,
    date = 2,
    characteristic = 8,
    flavor = 9,
    eggWatch = 0,
    egg = false,
    fateful = false,
    mine = false,
    eggLocation = "hatched",
  },
  {
    key = "fatefulEggArrived",
    template = 104,
    nature = 0,
    date = 1,
    characteristic = 0,
    flavor = 0,
    eggWatch = 6,
    egg = true,
    fateful = true,
    mine = true,
    eggLocation = "ranger",
  },
  {
    key = "fatefulEgg",
    template = 103,
    nature = 0,
    date = 1,
    characteristic = 0,
    flavor = 0,
    eggWatch = 6,
    egg = true,
    fateful = true,
    mine = true,
    eggLocation = "egg",
  },
  {
    key = "fatefulEggTraded",
    template = 103,
    nature = 0,
    date = 1,
    characteristic = 0,
    flavor = 0,
    eggWatch = 6,
    egg = true,
    fateful = true,
    mine = false,
    eggLocation = "egg",
  },
  {
    key = "egg",
    template = 101,
    nature = 0,
    date = 1,
    characteristic = 0,
    flavor = 0,
    eggWatch = 6,
    egg = true,
    fateful = false,
    mine = true,
    eggLocation = "egg",
  },
  {
    key = "eggTraded",
    template = 102,
    nature = 0,
    date = 1,
    characteristic = 0,
    flavor = 0,
    eggWatch = 6,
    egg = true,
    fateful = false,
    mine = false,
    eggLocation = "egg",
  },
}

-- Memo placeholder fields by trainer-memo buffer position, transcribing
-- the message-format buffer order: 0 met year, 1 met month, 2 met day,
-- 3 met level, 4 met location, 5 egg year, 6 egg month, 7 egg day,
-- 8 egg location. The compiler maps each lowered substitution to its
-- semantic segment kind through this table; a lowered kind that does not
-- match its semantic (month kinds to month bindings, number kinds to
-- year/day/level bindings, landmark kinds to location bindings) fails
-- compilation instead of publishing a misbound template.
SummarySources.memoFieldSemantics = {
  [0] = "metYear",
  [1] = "metMonth",
  [2] = "metDay",
  [3] = "metLevel",
  [4] = "metLocation",
  [5] = "eggYear",
  [6] = "eggMonth",
  [7] = "eggDay",
  [8] = "eggLocation",
}

-- Memo templates whose location slot carries the origin-game region
-- instead of a landmark, keyed by summary message id. Migrated mons show
-- their arrival region where ordinary mons show a met landmark, so the
-- compiler binds field 4 of these templates to the migration binding
-- rather than the landmark binding.
SummarySources.memoMigrationTemplates = { [64] = true }

-- Exact gift-egg origin set in display-consumer spelling, transcribing
-- the non-player egg sources of the gift landmark bank in bank order:
-- the traveling giver, the island, route, and city gifters, the mystery
-- zone, the egg researcher, and the lottery presenter. Day-care breeding
-- stays outside this set: bred eggs read the ordinary hatched branch.
-- Link-trade eggs and ranger-arrived eggs keep their own singleton
-- classes and never enter this set.
SummarySources.memoGiftEggOrigins = { 4009, 4010, 4011, 4012, 4013, 4014 }

-- Packed map-section bases for the location predicates above, transcribing
-- the sub_02017FE4 pack table: normal mapsec ids pass through, gift ids
-- add 2000, external ids add 3000. The display consumer classifies the
-- synthetic 4000 range as gifts; both spellings resolve through the same
-- gift bank below.
SummarySources.memoLocationBases = { normal = 0, gift = 2000, external = 3000 }

-- Packed map-section ids for the location predicates above in the display
-- consumer's spelling: normal mapsec ids pass through, gift offsets add
-- 4000, external offsets add 6000. The source pack table uses 2000/3000
-- bases instead; see memoLocationBases above for the source spelling.
SummarySources.memoLocations = {
  palPark = 55,
  linkTrade = 4001,
  linkTrade2 = 4002,
  dayCareCouple = 4000,
  travelingMan = 4009,
  riley = 4010,
  cynthia = 4011,
  mrPokemon = 4013,
  primo = 4014,
  ranger = 6001,
  mysteryZone = 4012,
  farawayPlace = 6002,
  kanto = 4003,
  johto = 4004,
  hoenn = 4005,
  sinnoh = 4006,
  dashes = 4007,
  distantLand = 4008,
}

-- Characteristic messages by stat and lowest-IV remainder, transcribing
-- `sCharactersticMsgs`: rows follow HP, Attack, Defense, Speed, Special
-- Attack, Special Defense; the column is the winning IV modulo five.
SummarySources.memoCharacteristics = {
  { 71, 72, 73, 74, 75 },
  { 76, 77, 78, 79, 80 },
  { 81, 82, 83, 84, 85 },
  { 86, 87, 88, 89, 90 },
  { 91, 92, 93, 94, 95 },
  { 96, 97, 98, 99, 100 },
}

-- Flavor messages, transcribing `sFlavorMsgs`: the default run plus one
-- per flavor in spicy, dry, sweet, bitter, sour order.
SummarySources.memoFlavors = { default = 70, byFlavor = { 65, 66, 67, 68, 69 } }

-- Egg Watch thresholds on the remaining hatch cycles with their
-- templates, transcribing `FormatEggWatch`.
SummarySources.memoEggWatch = { thresholds = { 5, 10, 40 }, templates = { 105, 106, 107, 108 } }

-- Origin-game to arrival-region mapping, transcribing the migrated
-- branch of `FormatDateAndLocation_Migrated` in src/trainer_memo.c (same
-- pin): FireRed/LeafGreen arrive from Kanto, HeartGold/SoulSilver from
-- Johto, Ruby/Sapphire/Emerald from Hoenn, GameCube arrivals read the
-- Distant Land entry, and Diamond/Pearl/Platinum arrivals read the
-- dashes entry. Values name the gift-bank region keys in
-- SummarySources.memoLocations; the compiler binds each game to the
-- corresponding generated wording.
SummarySources.memoMigrationRegions = {
  sapphire = "hoenn",
  ruby = "hoenn",
  emerald = "hoenn",
  firered = "kanto",
  leafgreen = "kanto",
  heartgold = "johto",
  soulsilver = "johto",
  diamond = "dashes",
  pearl = "dashes",
  platinum = "dashes",
  gamecube = "distantLand",
}

-- Summary object-resource inventory, transcribing the `_02103A2C` table
-- selection in asm/unk_0208B1AC.s (same pin): header member 85 selects
-- one resource set per dynamic role, and members 54/55/53/52 list the
-- character, palette, cell, and animation resources each set draws from.
-- Records follow the same on-disk resource-table/header layout the intro
-- compiler resolves; see the compiler helpers there for the format.
SummarySources.resdat = {
  header = 85,
  charTable = 54,
  paletteTable = 55,
  cellTable = 53,
  animationTable = 52,
}

-- Dynamic-role resource selection: the header-85 resource set, the local
-- object palette bank, and the animation sequences each semantic role
-- rasterizes. Sequence keys are the semantic animation names the
-- manifest publishes; values are the zero-based source sequence
-- selections. The primary member cursor keeps its three state visuals,
-- the move-reorder cursor keeps its cancel and follow visuals, the
-- performance rows keep the four star states plus the two Aprijuice
-- modifier visuals, the Shiny Leaf row keeps its leaf and crown
-- visuals, and the ribbon grid keeps its cursor plus both page-arrow
-- visuals. Unlisted sets and sequences never reach runtime.
SummarySources.chromeResources = {
  primaryCursor = {
    resourceSet = 2,
    paletteBank = 0,
    sequences = { rootFocus = 0, moveRowFocus = 1, restrictedCancel = 2 },
  },
  secondaryMoveCursor = {
    resourceSet = 14,
    paletteBank = 0,
    sequences = { moveCancel = 0, moveFollow = 1 },
  },
  performance = {
    resourceSet = 44,
    paletteBank = 0,
    sequences = {
      starBase = 0,
      starAbove = 1,
      starBelow = 2,
      starEmpty = 3,
      modifierPositive = 4,
      modifierNegative = 5,
    },
  },
  leaves = {
    resourceSet = 44,
    paletteBank = 0,
    sequences = { leaf = 6, crown = 7 },
  },
  ribbonControls = {
    resourceSet = 34,
    paletteBank = 0,
    sequences = { ribbonCursor = 0, ribbonPagePrev = 4, ribbonPageNext = 5 },
  },
}

-- Dynamic-chrome placement in native pixels, transcribed from the
-- overlay object-setup routines (asm/unk_0208B1AC.s and
-- asm/unk_02088288.s, same pin). The primary cursor visits the six
-- party-member slots in column-major display order; nested move rows
-- start at the row base and advance by the row step with the two cancel
-- rows below; performance rows list in display order with five star
-- slots per row and one modifier slot above each row; the five leaves
-- share one baseline with the crown centered on the middle leaf; the
-- ribbon grid starts at its origin with three columns and advances by
-- row below the grid for paging. The compiler lowers these constants
-- verbatim; runtime never recomputes them.
SummarySources.chromeGeometry = {
  primaryCursor = {
    anchors = {
      { x = 183, y = 55 },
      { x = 223, y = 63 },
      { x = 183, y = 87 },
      { x = 223, y = 95 },
      { x = 183, y = 119 },
      { x = 223, y = 127 },
    },
  },
  moveDetail = {
    x = 68,
    rowBaseY = 24,
    rowStep = 32,
    cancelY = 152,
    restrictedCancelY = 168,
    cancelAnchor = { x = 68, y = 168 },
    restrictedSpecialAnchor = { x = 220, y = 176 },
  },
  performance = {
    starXs = { 64, 80, 96, 112, 128 },
    modifierX = 80,
    rows = {
      { stat = "speed", y = 48, modifierY = 32 },
      { stat = "power", y = 80, modifierY = 64 },
      { stat = "skill", y = 112, modifierY = 96 },
      { stat = "stamina", y = 144, modifierY = 128 },
      { stat = "jump", y = 176, modifierY = 160 },
    },
  },
  leaves = {
    anchors = {
      { x = 91, y = 182 },
      { x = 101, y = 182 },
      { x = 111, y = 182 },
      { x = 121, y = 182 },
      { x = 131, y = 182 },
    },
    crownAnchor = { x = 111, y = 182 },
  },
  ribbons = {
    origin = { x = 32, y = 24 },
    columns = 3,
    columnStep = 32,
    rowStep = 40,
    pagePrevAnchor = { x = 128, y = 32 },
    pageNextAnchor = { x = 128, y = 96 },
  },
}

-- Nested-state background motion, transcribing the overlay BG5 position
-- traces (asm/unk_02088288.s, same pin): the move detail state steps
-- the sub-pane background along X through 0/64/128 and the ribbon
-- detail state steps it along Y through 0/36/72. The compiler lowers
-- these traces verbatim; closing a nested state replays its trace in
-- reverse under the consumer.
SummarySources.transitions = {
  moveDetail = { pane = "sub", axis = "x", positions = { 0, 64, 128 } },
  ribbonDetail = { pane = "sub", axis = "y", positions = { 0, 36, 72 } },
}

return SummarySources
