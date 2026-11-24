-- Producer-side HGSS care-family source inventory: the two breeding archives,
-- the source compatibility/incense/cycle constants, and the semantic
-- identities those tables carry. Source authority: the retail ROM and the
-- pinned native symbols named beside each entry. Pure data and pure functions;
-- no I/O. Never imported by runtime packages (see
-- tests/architecture/module_boundaries_test.lua).

local PokemonCareSources = {}

PokemonCareSources.provenance = {
  repo = "retail ROM",
}

-- ReadFromPersonalPmsNarc (src/pokemon.c) opens "poketool/personal/pms.narc"
-- as a flat byte file and reads the u16 at species * 2, so the member is the
-- species table itself rather than a NARC member: entry N is the egg species
-- the Day Care resolves for mother species N. The source asserts
-- species < SPECIES_EGG.
PokemonCareSources.eggSpeciesSource = {
  path = "poketool/personal/pms.narc",
  entrySize = 2,
  -- Every real species is a legal Day Care parent; the trailing pseudo-form
  -- members of the source table are unreachable from the Day Care.
  firstSpecies = 1,
  lastSpecies = 493,
  maxSpecies = 495,
}

-- NARC_fielddata_breeding_egg_move_list (a/2/2/9), member 0, read by
-- LoadEggMoves: a flat u16 list in which an entry above EGG_MOVE_HEADER_BASE
-- opens the next species' block as `species + EGG_MOVE_HEADER_BASE`, and the
-- block runs until the next header or MAX_EGG_MOVES moves.
PokemonCareSources.eggMoveSource = {
  alias = "NARC_fielddata_breeding_egg_move_list",
  symbol = "NARC_fielddata_breeding_egg_move_list",
  path = "a/2/2/9",
  memberId = 0,
  headerBase = 20000,
  -- LoadEggMoves scans at most this many entries for one header.
  scanLimit = 2045,
  maxMoves = 16,
}

-- sIncenseMons (src/get_egg.c): baby, incense item, and evolved parent, in
-- source row order. A baby only survives when either parent holds its incense.
PokemonCareSources.incenseRows = {
  { baby = "WYNAUT", item = "LAX_INCENSE", parent = "WOBBUFFET" },
  { baby = "AZURILL", item = "SEA_INCENSE", parent = "MARILL" },
  { baby = "MIME_JR", item = "ODD_INCENSE", parent = "MR_MIME" },
  { baby = "BONSLY", item = "ROCK_INCENSE", parent = "SUDOWOODO" },
  { baby = "MUNCHLAX", item = "FULL_INCENSE", parent = "SNORLAX" },
  { baby = "MANTYKE", item = "WAVE_INCENSE", parent = "MANTINE" },
  { baby = "BUDEW", item = "ROSE_INCENSE", parent = "ROSELIA" },
  { baby = "HAPPINY", item = "LUCK_INCENSE", parent = "CHANSEY" },
  { baby = "CHINGLING", item = "PURE_INCENSE", parent = "CHIMECHO" },
}

-- The hatch application's own art (src/application/hatch_egg_gfx.c): the
-- background char/map/palette, the egg sprite's char/palette/cell/animation,
-- and the reveal bars' char/palette/cell/animation, all from
-- NARC_a_1_1_5; the particle resources come from NARC_a_1_1_6 member 0 (egg
-- scene) and member 1 (Manaphy scene). The message window prints the
-- src/msgdata/msg/msg_0187 lines.
PokemonCareSources.hatchArt = {
  alias = "NARC_a_1_1_5",
  symbol = "NARC_a_1_1_5",
  path = "a/1/1/5",
  background = { char = 0, screen = 1, palette = 8 },
  egg = { char = 4, palette = 9, cell = 3, anim = 2, paletteBank = 0, sequence = 0 },
  bars = { char = 7, palette = 10, cell = 6, anim = 5, paletteBank = 0, sequence = 0 },
}

PokemonCareSources.hatchParticles = {
  alias = "NARC_a_1_1_6",
  symbol = "NARC_a_1_1_6",
  path = "a/1/1/6",
  egg = { member = 0 },
  manaphy = { member = 1 },
}

-- NARC_msgdata_msg member 187: the hatch window's own lines. Message 0 names
-- the hatched species, message 1 asks about a nickname, and messages 2 and 3
-- are the yes/no the source shows.
PokemonCareSources.hatchMessages = {
  alias = "messages",
  symbol = "NARC_msgdata_msg",
  path = "a/0/2/7",
  memberId = 187,
  hatched = 0,
  nicknameQuestion = 1,
  yes = 2,
  no = 3,
}

-- The source message window geometry in tiles
-- (HatchEggApp_CreateMessageWindow: x 2, y 19, width 27, height 4).
PokemonCareSources.hatchWindow = { x = 2, y = 19, width = 27, height = 4 }

-- The move reminder / singleton tutor application's own art
-- (src/application/move_relearner/move_relearner_app.c,
-- MoveRelearner_LoadBgGraphics): the main screen's char/map/palette members,
-- the sub screen's, and the button tile screen copied into the sub layer. The
-- window templates are the source's own tile rectangles in enum order
-- (sMoveRelearnerWindowTemplates).
PokemonCareSources.relearnerArt = {
  alias = "NARC_a_1_1_0",
  symbol = "NARC_a_1_1_0",
  path = "a/1/1/0",
  main = { char = 1, screen = 4, palette = 0 },
  sub = { char = 1, screen = 2, palette = 0 },
  buttons = { char = 1, screen = 3, palette = 0 },
  windows = {
    { key = "categoryLabel", x = 17, y = 4, width = 6, height = 2 },
    { key = "powerLabel", x = 17, y = 6, width = 6, height = 2 },
    { key = "accuracyLabel", x = 17, y = 8, width = 8, height = 2 },
    { key = "power", x = 28, y = 6, width = 3, height = 2 },
    { key = "accuracy", x = 28, y = 8, width = 3, height = 2 },
    { key = "description", x = 17, y = 10, width = 15, height = 10 },
    { key = "message", x = 2, y = 19, width = 27, height = 4, framed = true },
    { key = "title", x = 1, y = 0, width = 30, height = 3 },
    { key = "teach", x = 15, y = 21, width = 8, height = 3 },
    { key = "returnButton", x = 24, y = 21, width = 8, height = 3 },
    { key = "list", x = 5, y = 4, width = 10, height = 16 },
    { key = "knownTitle", x = 23, y = 13, width = 7, height = 4, framed = true },
    { key = "monName", x = 19, y = 5, width = 10, height = 16 },
    -- The yes/no prompt the source opens over the message window
    -- (MoveRelearner_ShowYesNo: template x 26, y 10, shapeParam 0 -> 6x4 tiles
    -- per button, stacked). Its first button answers yes.
    { key = "promptYes", x = 26, y = 10, width = 6, height = 4, framed = true },
    { key = "promptNo", x = 26, y = 14, width = 6, height = 4, framed = true },
  },
}

-- NARC_msgdata_msg member 747: the application's own lines. The tutor lesson
-- prints ids 0..10, the reminder 11..21, and the static texts carry the detail
-- labels, the two button captions and the list titles.
PokemonCareSources.relearnerMessages = {
  alias = "messages",
  symbol = "NARC_msgdata_msg",
  path = "a/0/2/7",
  memberId = 747,
  columns = {
    tutor = { first = 0, last = 10 },
    relearn = { first = 11, last = 21 },
  },
  labels = {
    category = 22,
    power = 23,
    accuracy = 24,
    pp = 25,
    none = 33,
    returnButton = 34,
    teach = 35,
    title = 36,
    monName = 37,
    knownMoves = 39,
  },
}

-- The NPC trade table (NARC_a_1_1_2, one member per NpcTradeNum in source
-- order: sixteen ints of identity, item and content plus the five contest
-- values, the source ability/sheen pair and the unused flag). Read by
-- _CreateTradeMon (src/npc_trade.c).
PokemonCareSources.tradeTable = {
  alias = "NARC_a_1_1_2",
  symbol = "NARC_a_1_1_2",
  path = "a/1/1/2",
  entrySize = 84,
  count = 13,
}

-- NARC_msgdata_msg member 200: the NPC trade nicknames are messages 0..12 and
-- the OT names are NPC_TRADE_OT_NUM(tradeNum) = tradeNum + NPC_TRADE_MAX.
PokemonCareSources.tradeMessages = {
  alias = "messages",
  symbol = "NARC_msgdata_msg",
  path = "a/0/2/7",
  memberId = 200,
  otNameOffset = 13,
}

-- The app71 trade sequence's own art (src/application/trade_sequence): the
-- shared backdrop's screen map, character data and colour banks, and the
-- message bank whose lines the sequence prints.
PokemonCareSources.tradeArt = {
  alias = "NARC_a_0_8_9",
  symbol = "NARC_a_0_8_9",
  path = "a/0/8/9",
  -- AddWindowParameterized(bg, window, MAIN_1, 2, 19, 27, 4, 1, 1).
  window = { x = 2, y = 19, width = 27, height = 4 },
  -- TradeSequence_LoadModel(NARC_a_0_8_9, 27): the Poke Ball every scene's
  -- 3D layer loads (BMD0 with one MDL0 and its TEX0).
  balloonMember = 27,
}

-- The mon picture the send and receive scenes draw: the front portrait of the
-- subject's own selector (GetBoxmonSpriteCharAndPlttNarcIds with
-- MON_PIC_FACING_FRONT) and its source height offset
-- (GetBoxMonPicHeightEx, which reads the front height member).
PokemonCareSources.tradePicture = {
  facing = 2,
  -- The source anchors the 80x80 picture's bottom at height + 80.
  baseY = 80,
  -- The exchange scene's two picture layers: 10x10 tiles at these tile columns
  -- on a 256x512 text background (TradeSequence_LoadMonPicTilemap).
  sentTileX = 20,
  receivedTileX = 2,
}

-- The member ids each trade scene loads from the trade NARC, in the source's
-- own layer order. Read from the seven scene modules:
--   send/receive  trade_sequence_send.c / _receive.c: screen 21, char 22, palette 23
--   depart        trade_sequence_depart.c: layer 2 (affine, 256 colours) screen 0,
--                 char 2, palette 3; layer 3 (256x16 PLTT) screen 4, char 5, palette 6
--   arrive        trade_sequence_arrive.c: layer 2 screen 1, char 2, palette 3;
--                 layer 3 screen 4, char 5, palette 6
--   recede        trade_sequence_recede.c: screen 15, char 16, palette 17
--   approach      trade_sequence_approach.c: screen 15, char 16, palette 17
--   exchange      trade_sequence_exchange.c: screen 18, char 19, palette 20
-- `affine` marks the 256-colour NNS affine map whose entries are one tile-index
-- byte; `paletteColors` names the colour blocks the scene loads per time of
-- day, in source load order.
PokemonCareSources.tradeScenes = {
  send = { layers = { { screen = 21, char = 22, palette = 23 } } },
  receive = { layers = { { screen = 21, char = 22, palette = 23 } } },
  depart = {
    layers = {
      {
        screen = 0,
        char = 2,
        palette = 3,
        affine = true,
        -- GXLoadPal(slot 0, 0x20) then GXLoadPalWithSrcOffset(slot 1, 0x40)
        -- from sTradeSequenceDepartPaletteOffsets.
        paletteLoads = { { source = 0, colors = 16 }, { source = "timeOfDay", colors = 32, firstColor = 16 } },
        -- sTradeSequenceDepartPaletteOffsets, indexed by the animation's own
        -- time-of-day code (0 morning/day, 1 evening, 2 night).
        paletteOffsets = { day = 0x20, evening = 0x60, night = 0xA0 },
      },
      {
        screen = 4,
        char = 5,
        palette = 6,
        -- GF_BG_TYPE_256x16PLTT: every entry has a 256-colour bank index, and
        -- the scene loads one bank at slot 0.
        paletteLoads = { { source = 0, colors = 256 } },
      },
    },
  },
  arrive = {
    layers = {
      {
        screen = 1,
        char = 2,
        palette = 3,
        affine = true,
        paletteLoads = { { source = 0, colors = 16 }, { source = "timeOfDay", colors = 32, firstColor = 16 } },
        -- sTradeSequenceDepartPaletteOffsets, indexed by the animation's own
        -- time-of-day code (0 morning/day, 1 evening, 2 night).
        paletteOffsets = { day = 0x20, evening = 0x60, night = 0xA0 },
      },
      { screen = 4, char = 5, palette = 6, paletteLoads = { { source = 0, colors = 256 } } },
    },
  },
  recede = {
    layers = {
      {
        screen = 15,
        char = 16,
        palette = 17,
        paletteOffsets = { day = 0x00, evening = 0x20, night = 0x40 },
        paletteLoads = { { source = "timeOfDay", colors = 16 } },
      },
    },
  },
  approach = {
    layers = {
      {
        screen = 15,
        char = 16,
        palette = 17,
        paletteOffsets = { day = 0x00, evening = 0x20, night = 0x40 },
        paletteLoads = { { source = "timeOfDay", colors = 16 } },
      },
    },
  },
  exchange = { layers = { { screen = 18, char = 19, palette = 20 } } },
}

-- The trade sequence's shared effect sheet: the member set the send, receive,
-- recede and approach scenes load (TradeSequence_LoadCellAnim 7/8 plus
-- GfGfxLoader_LoadImageMapping 9 and PartiallyLoadPalette 10). Each scene
-- selects one of the sheet's animation sequences by index
-- (Sprite_SetAnimCtrlSeq):
--   send     sprite 0 sequence 1, sprite 1 sequence 0
--   receive  sprite 0 sequence 1, sprite 1 sequence 2
--   recede   sprite 0 sequence 3
--   approach sprite 0 sequence 3
PokemonCareSources.tradeSprites = {
  effect = { char = 9, palette = 10, cell = 7, anim = 8, paletteBank = 0, sequences = { 0, 1, 2, 3 } },
}

-- TradeSequenceBackdrop: morning and day share the first outdoor backdrop,
-- evening the second and night the third (NPCTrade_CreateTradeAnim).
PokemonCareSources.tradeBackdropsByTimeOfDay = {
  [0] = "day",
  [1] = "day",
  [2] = "evening",
  [3] = "night",
  [4] = "night",
}

-- The composed surfaces whose palette the scene's time-of-day code selects.
-- Named so the manifest never carries a raw selector. The animation itself only
-- ever receives 0 (morning/day), 1 (evening) or 2 (night).
PokemonCareSources.tradeBackdropNames = { "day", "evening", "night" }

-- The seven scenes in the order sTradeSequenceScenes plays them.
PokemonCareSources.tradePhaseOrder =
  { "send", "depart", "recede", "exchange", "approach", "arrive", "receive" }

PokemonCareSources.tradeSequenceMessages = {
  alias = "messages",
  symbol = "NARC_msgdata_msg",
  path = "a/0/2/7",
  memberId = 179,
}

-- The bank-179 lines of the ordinary in-game exchange: the send scene prints
-- "sending" and its farewell, the receive scene prints the receipt and its
-- take-care line.
PokemonCareSources.tradeSequenceLines = {
  send = 0,
  farewell = 1,
  received = 2,
  takeCare = 3,
}

-- GAME_LANGUAGE ids (include/constants/pokemon.h) of the dumps this port
-- supports; the table's language column stores one of them.
PokemonCareSources.tradeLanguages = {
  [1] = "japanese",
  [2] = "english",
  [3] = "french",
  [4] = "italian",
  [5] = "german",
  [7] = "spanish",
  [8] = "korean",
}

-- EGG_GENDER_MALE (include/constants/daycare.h): the pending egg personality
-- bit the Nidoran and Illumise families read as their offspring's gender
-- split.
PokemonCareSources.eggGenderMale = 0x8000
-- SPECIES_DITTO, the role-swapping parent (Daycare_GetEggSpecies).
PokemonCareSources.ditto = "DITTO"
-- Manaphy is forced to Phione because the source PMS table does not carry it.
PokemonCareSources.manaphy = "MANAPHY"
PokemonCareSources.phione = "PHIONE"

return PokemonCareSources
