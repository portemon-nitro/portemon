-- Native battle-presentation source inventory: the ordinary
-- persistent-scene axes, the exact shared menu/HUD member roles, and the
-- palette formulas behind the lower screen and the BG3 bake. Member
-- selection follows the retail ROM's battle background setup; the main
-- scene is the overlay-12 BG3 recipe, never the overlay-7 effect
-- backgrounds. Pure data and pure functions; no I/O. Never imported by
-- runtime: libs/assets and game packages must not require this module (see
-- tests/architecture/module_boundaries_test.lua).

---@class BattlePresentationSources
local BattlePresentationSources = {}
local BattleSources = require("romdump.src.config.BattleSources")
local MonSources = require("romdump.src.config.MonSources")

BattlePresentationSources.provenance = {
  repo = "retail ROM",
}

-- Version-filesystem NARC symbols behind the two battle archives. The
-- symbols resolve through the version's ROM filesystem; no physical file
-- identity is assumed here or anywhere downstream.
BattlePresentationSources.LOWER_NARC = "NARC_a_0_0_7"
BattlePresentationSources.SCENE_NARC = "NARC_a_0_0_8"

-- Battler-picture attributes follow GetMonPicHeightBySpeciesGenderForm and
-- NARC_ReadPokepicAnimScript in src/pokemon.c. The animation archive is
-- opened as NARC_a_1_8_0 by the battle picture controller. The version
-- filesystem resolves these symbols; member selection remains producer-only.
BattlePresentationSources.PICTURE_HEIGHT_NARC = "NARC_poketool_pokegra_height"
BattlePresentationSources.PICTURE_HEIGHT_OTHER_NARC = "NARC_poketool_pokegra_height_o"
BattlePresentationSources.PICTURE_ANIMATION_NARC = "NARC_a_1_8_0"
BattlePresentationSources.PICTURE_ANIMATION_MEMBER = 0
BattlePresentationSources.PICTURE_ANIMATION_RECORD_SIZE = 89

-- Pokepic's shared 4bpp texture atlas uses the shadow entry from the
-- other-pokemon graphics archive. The coordinates are the source UV table
-- in src/pokepic.c; runtime receives the same four regions normalized into
-- the staged 64x64 image.
BattlePresentationSources.POKE_SHADOW = {
  archive = "pokemon_graphics_other",
  characterMember = 259,
  paletteMember = 260,
  depth = 3,
  textureWidth = 256,
  textureHeight = 256,
  textureRowBytes = 0x80,
  sourceRowBytes = 0x50,
  sourceRows = 80,
  copiedRowBytes = 0x28,
  textureOriginByteOffset = 0x5050,
  regions = {
    { size = 0, x = 160, y = 160, width = 64, height = 16 },
    { size = 1, x = 160, y = 160, width = 64, height = 16 },
    { size = 2, x = 160, y = 176, width = 64, height = 16 },
    { size = 3, x = 160, y = 192, width = 64, height = 16 },
  },
}

-- Ordinary persistent backgrounds in source order. The first six are the
-- outdoor recipes whose palettes follow the time of day; the rest use
-- palette variant zero. The last entry is a known source recipe, not a new
-- gameplay region commitment.
BattlePresentationSources.BACKGROUNDS = {
  "general",
  "ocean",
  "city",
  "forest",
  "mountain",
  "snow",
  "building_1",
  "building_2",
  "building_3",
  "cave_1",
  "cave_2",
  "cave_3",
  "will",
  "koga",
  "bruno",
  "karen",
  "lance",
  "distortion_world",
}

BattlePresentationSources.OUTDOOR_BACKGROUNDS = 6

BattlePresentationSources.TIMES = { "day", "evening", "night" }

-- Native Pokepic centers, spawn positions and Z values follow
-- asm/overlay_07.s::ov07_022377DC/F4. Health-box anchors and OBJ/BG
-- priorities follow the single and doubled templates in
-- src/battle/battle_hp_bar.c; drawPriority is separate from Pokepic Z.
-- The runtime catalog contains only normalized semantic values.
BattlePresentationSources.SLOT_GEOMETRY = {
  {
    sideType = 0,
    settledX = 64,
    settledY = 112,
    entryX = 336,
    entryY = 112,
    depth = -512,
    hudX = 192,
    hudY = 116,
    hudPriority = 23,
    hudBgPriority = 0,
  },
  {
    sideType = 1,
    settledX = 192,
    settledY = 50,
    entryX = -80,
    entryY = 50,
    depth = -640,
    hudX = 58,
    hudY = 36,
    hudPriority = 24,
    hudBgPriority = 0,
  },
  {
    sideType = 2,
    settledX = 40,
    settledY = 112,
    entryX = 316,
    entryY = 112,
    depth = -512,
    hudX = 192,
    hudY = 103,
    hudPriority = 28,
    hudBgPriority = 0,
  },
  {
    sideType = 4,
    settledX = 80,
    settledY = 120,
    entryX = 356,
    entryY = 120,
    depth = 0,
    hudX = 198,
    hudY = 132,
    hudPriority = 26,
    hudBgPriority = 0,
  },
  {
    sideType = 3,
    settledX = 216,
    settledY = 50,
    entryX = -60,
    entryY = 50,
    depth = -100,
    hudX = 64,
    hudY = 16,
    hudPriority = 25,
    hudBgPriority = 0,
  },
  {
    sideType = 5,
    settledX = 176,
    settledY = 42,
    entryX = -100,
    entryY = 42,
    depth = -640,
    hudX = 58,
    hudY = 45,
    hudPriority = 27,
    hudBgPriority = 0,
  },
}

-- Character-tile targets normalized from pinned battle_hp_bar.c routines.
-- Tile numbers are relative to each staged OBJ character buffer, not VRAM.
BattlePresentationSources.HUD_PATCH_SPANS = {
  hp = {
    { sideType = 0, spans = { { tile = 39, count = 0 }, { tile = 97, count = 6 } } },
    { sideType = 1, spans = { { tile = 39, count = 1 }, { tile = 96, count = 5 } } },
    { sideType = 2, spans = { { tile = 39, count = 0 }, { tile = 96, count = 6 } } },
    { sideType = 3, spans = { { tile = 39, count = 1 }, { tile = 96, count = 5 } } },
    { sideType = 4, spans = { { tile = 39, count = 0 }, { tile = 96, count = 6 } } },
    { sideType = 5, spans = { { tile = 39, count = 1 }, { tile = 96, count = 5 } } },
  },
  -- Native OBJ character-buffer writes from pinned
  -- battle_hp_bar.c::ov12_0226D450 and ov12_0226D3F0. Tile positions are
  -- byte offsets divided by the 32-byte 4bpp tile size.
  currentHp = {
    { sideType = 0, tile = 104, count = 3 },
    { sideType = 1, tile = 49, count = 3 },
    { sideType = 2, tile = 96, count = 3 },
    { sideType = 3, tile = 49, count = 3 },
    { sideType = 4, tile = 96, count = 3 },
    { sideType = 5, tile = 49, count = 3 },
  },
  maximumHp = {
    { sideType = 0, tile = 108, count = 3 },
    { sideType = 1, tile = 53, count = 3 },
    { sideType = 2, tile = 100, count = 3 },
    { sideType = 3, tile = 53, count = 3 },
    { sideType = 4, tile = 100, count = 3 },
    { sideType = 5, tile = 53, count = 3 },
  },
  experience = { { tile = 51, count = 5 }, { tile = 112, count = 7 } },
  -- Native OBJ character-buffer write tables from battle_hp_bar.c,
  -- normalized from byte offsets to 8x8 4bpp tile indices.
  status = {
    { sideType = 0, tile = 36, count = 3 },
    { sideType = 1, tile = 34, count = 3 },
    { sideType = 2, tile = 35, count = 3 },
    { sideType = 3, tile = 34, count = 3 },
    { sideType = 4, tile = 35, count = 3 },
    { sideType = 5, tile = 34, count = 3 },
  },
  gender = {
    { sideType = 0, spans = { { tile = 83, count = 2 }, { tile = 91, count = 2 } } },
    { sideType = 1, spans = { { tile = 81, count = 2 }, { tile = 89, count = 2 } } },
    { sideType = 2, spans = { { tile = 82, count = 2 }, { tile = 90, count = 2 } } },
    { sideType = 3, spans = { { tile = 81, count = 2 }, { tile = 89, count = 2 } } },
    { sideType = 4, spans = { { tile = 82, count = 2 }, { tile = 90, count = 2 } } },
    { sideType = 5, spans = { { tile = 81, count = 2 }, { tile = 89, count = 2 } } },
  },
  -- Nickname window tiles (sNicknameVramRegions): the 8x2-tile text
  -- window's first columns of each row, then each row's remaining columns.
  nickname = {
    {
      sideType = 0,
      spans = { { tile = 19, count = 5 }, { tile = 27, count = 5 }, { tile = 80, count = 3 }, { tile = 88, count = 3 } },
    },
    {
      sideType = 1,
      spans = { { tile = 17, count = 7 }, { tile = 25, count = 7 }, { tile = 80, count = 1 }, { tile = 88, count = 1 } },
    },
    {
      sideType = 2,
      spans = { { tile = 18, count = 6 }, { tile = 26, count = 6 }, { tile = 80, count = 2 }, { tile = 88, count = 2 } },
    },
    {
      sideType = 3,
      spans = { { tile = 17, count = 7 }, { tile = 25, count = 7 }, { tile = 80, count = 1 }, { tile = 88, count = 1 } },
    },
    {
      sideType = 4,
      spans = { { tile = 18, count = 6 }, { tile = 26, count = 6 }, { tile = 80, count = 2 }, { tile = 88, count = 2 } },
    },
    {
      sideType = 5,
      spans = { { tile = 17, count = 7 }, { tile = 25, count = 7 }, { tile = 80, count = 1 }, { tile = 88, count = 1 } },
    },
  },
  -- Level digit tiles (sLevelVramRegions): three upper-row tiles receive
  -- each digit's top half in their lower rows, three lower-row tiles its
  -- bottom half in their upper rows.
  level = {
    { sideType = 0, spans = { { tile = 85, count = 3 }, { tile = 93, count = 3 } } },
    { sideType = 1, spans = { { tile = 83, count = 3 }, { tile = 91, count = 3 } } },
    { sideType = 2, spans = { { tile = 84, count = 3 }, { tile = 92, count = 3 } } },
    { sideType = 3, spans = { { tile = 83, count = 3 }, { tile = 91, count = 3 } } },
    { sideType = 4, spans = { { tile = 84, count = 3 }, { tile = 92, count = 3 } } },
    { sideType = 5, spans = { { tile = 83, count = 3 }, { tile = 91, count = 3 } } },
  },
  caught = {
    { sideType = 0, tile = 35, count = 1 },
    { sideType = 1, tile = 33, count = 1 },
    { sideType = 2, tile = 34, count = 1 },
    { sideType = 3, tile = 33, count = 1 },
    { sideType = 4, tile = 34, count = 1 },
    { sideType = 5, tile = 33, count = 1 },
  },
  -- Native double-player mode writes from battle_hp_bar.c::ov12_02264C84.
  -- Tiles are normalized from OBJ character byte offsets; component tiles
  -- are relative to gBattleHpBar_RawGraphicComponents.
  playerDoubleMode = {
    {
      sideType = 2,
      gauge = {
        { tile = 38, sourceTile = 66 },
        { tile = 39, sourceTile = 67 },
        { tile = 102, sourceTile = 68 },
        { tile = 103, sourceTile = 38 },
      },
      numbers = {
        { tile = 39, sourceTile = 70 },
        { tile = 103, sourceTile = 71 },
        { tile = 99, sourceTile = 69 },
      },
    },
    {
      sideType = 4,
      gauge = {
        { tile = 38, sourceTile = 66 },
        { tile = 39, sourceTile = 67 },
        { tile = 102, sourceTile = 68 },
        { tile = 103, sourceTile = 38 },
      },
      numbers = {
        { tile = 39, sourceTile = 70 },
        { tile = 103, sourceTile = 71 },
        { tile = 99, sourceTile = 69 },
      },
    },
  },
}

-- The health-box number printer (MessagePrinter_New(14, 2, 15)): digit
-- tiles 0..9 from graphic/font member 5 with raw values 0/1/2 recolored to
-- the HUD palette's background, foreground, and shadow slots.
BattlePresentationSources.HUD_DIGITS = {
  narc = "NARC_graphic_font",
  member = 5,
  foreground = 14,
  shadow = 2,
  background = 15,
}

-- Native battle health-box OBJ tiles from battle_hp_bar_data.h::gBattleHpBar_RawGraphicComponents.
BattlePresentationSources.HUD_COMPONENTS = {
  depth = 3,
  tileCount = 78,
  source = {
    repository = "pret/pokeheartgold",
    revision = "9d8b7591f09b65804da2fb2dfd56f320633e0d36",
    file = "src/battle/battle_hp_bar_data.h",
    symbol = "gBattleHpBar_RawGraphicComponents",
  },
  hex = table.concat({
    "e3eeeeeeee888ee8ee888ee8ee8888e8ee888ee8ee888ee8e3eeeeee32333333eeeeeeee8888e8ee888ee8ee8888e8ee88eeeeee88eeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee222222224444444444444444eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee252222224644444446444444eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee552222226644444466444444eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee552522226646444466464444eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee555522226666444466664444eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee555525226666464466664644eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee555555226666664466666644eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee555555256666664666666646eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee555555556666666666666666eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee222222224444444444444444eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee272222224844444448444444eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee772222228844444488444444eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee772722228848444488484444eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee777722228888444488884444eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee777727228888484488884844eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee777777228888884488888844eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee777777278888884888888848eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee777777778888888888888888eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee222222224444444444444444eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee292222224a4444444a444444eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee99222222aa444444aa444444eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee99292222aa4a4444aa4a4444eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee99992222aaaa4444aaaa4444eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee99992922aaaa4a44aaaa4a44eeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee99999922aaaaaa44aaaaaa44eeeeeeeeeeeeeeee33333333eeeeeeeeeeeeeeee99999929aaaaaa4aaaaaaa4aeeeeeeeeeeeeeeee33333333",
    "eeeeeeeeeeeeeeee99999999aaaaaaaaaaaaaaaaeeeeeeeeeeeeeeee3333333333333333eeeeeeeeeeeeeeee2222222244444444eeeeeeeeeeeeeeee44444444",
    "33333333eeeeeeeeeeeeeeee2b2222224c444444eeeeeeeeeeeeeeee4444444433333333eeeeeeeeeeeeeeeebb222222cc444444eeeeeeeeeeeeeeee44444444",
    "33333333eeeeeeeeeeeeeeeebb2b2222cc4c4444eeeeeeeeeeeeeeee4444444433333333eeeeeeeeeeeeeeeebbbb2222cccc4444eeeeeeeeeeeeeeee44444444",
    "33333333eeeeeeeeeeeeeeeebbbb2b22cccc4c44eeeeeeeeeeeeeeee4444444433333333eeeeeeeeeeeeeeeebbbbbb22cccccc44eeeeeeeeeeeeeeee44444444",
    "33333333eeeeeeeeeeeeeeeebbbbbb2bcccccc4ceeeeeeeeeeeeeeee4444444433333333eeeeeeeeeeeeeeeebbbbbbbbcccccccceeeeeeeeeeeeeeee44444444",
    "ffffffff22222222ffffffff2222222222222222222222222222222222222222ffffffff22222222ffffffff2222222222222222222222222222222222222222",
    "ffffffff22222222ffffffff2222222222222222222222222222222222222222ff888888824844448f4877478248874882484444824877778248878822788788",
    "8888888847444447477747474787484747444447477747474887484778877877888888ff44748828774787f88748872844448728477787284744872877778722",
    "ffccccccc24c4444cf4cbbbbc24c4444c24cbbbbc24ccbccc24ccbcc22bccbcccccccccc4b44b44c4bbb4bbb4bcb4ccb4b44444b4c4bbb4b4c4b444bbcbbbbbb",
    "ccccccff4444cb2cbb4bcbfc44b4cb2cbbbbcc2ccbcccc2c4444cb2cbbbbcb22ff333333324344443f4311113243444432131141323333433243444422131111",
    "3333333341313343413133434131334341313343413133434144444111111111333333ff44443123114131f33143312344443123111131233133332331333322",
    "ffddddddd24d4444df4d9949d24dd94dd24d4444d24d9999d24dd9dd229dd9dddddddddd49444449499999494944444999994949d9dd4d494d4444499d999999",
    "ddddddff4449d92d4949d9fd4949d92d4949d92d4949d92d4944d92d9999d922ffaaaaaaa24a4494af4a9949a24a4444a24a9949a24aa94aa24a4444229a9999",
    "aaaaaaaa4a44944a4999494949a94a4949444449494999494949444999999999aaaaaaff4449a92a4949a9fa4949a92a4949a92a4949a92a4944a92a9999a922",
    "ffffffff22222222ffffffff2222222222222222222222222222222222222222ffffffff22222222ffffffff2222222222222222222222222222222222222222",
    "ffffffff22222222ffffffff22222222222222222222222222222222222222222fee2effe2aaea22aee9a9feee4eee2e4ee2422ee344e42332ee3e2222222222",
    "ffffffffffffffffffffffffafaaf2ff2a222aff2aff2aefa2aa22ef2f2af2efffffffffffffffffffffffffffffffffffffffff2effffff2effffff2eef2e2e",
    "ffffffffffffffffffffffffff2bffffbfbbf2ff2b2b2beff22b22efbfbbf2efffffffffffffffffffffffffffffffffffffffff2effffff2effffff2eef2e2e",
    "ffffffffffffffffffffffffffffffffffffffffffffffefffffffefffffffefffffffffffffffffffffffffffffffffffffffff2effffff2effffff2eef2e2e",
    "e3eeeeeeee888ee8ee888ee8ee8888e8ee888ee8ee888ee8e3eeeeee32333333eeeeeeee8888e8ee888ee8ee8888e8ee88eeeeee88eeeeeeeeeeeeee33333333",
    "3effffffee222222eeffffffee222222ee222222ee2222223e22222223222222ffffffffffffeffeffffeef2ffef2ef2ffee22ffef2ef2ffef22ffff2ff2ffff",
    "eeeeeef38888e8fe888ee8fe8888e8fe88eeeefe88eeeefeeeeeeef3333333ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "aaaa2aef222a22efff2affefff22ff2fffffffffffffffffffffffffffffffff2eef2e2e2eef2e2eee2eee22222222f2ffffffffffffffffffffffffffffffff",
    "2b222bef2bff2befb2bb22ef2f22f22fffffffffffffffffffffffffffffffff2ee42e2e2ee42e2eee2eee22222222f2ffffffffffffffffffffffffffffffff",
    "ffffffefffffffefffffffefffffff2fffffffffffffffffffffffffffffffff2ee42e2e2ee42e2eee2eee22222222f2ffffffffffffffffffffffffffffffff",
  }, ""),
}

-- Terrain recipes by native ordinal: the two 4bpp cell members plus the
-- day/evening/night palette members. Every member below lives in the scene
-- archive. The unknown recipe reuses the great-marsh daylight with puddle
-- type-0 cells; it is source data, not a gap.
---@type table<string, { ordinal: integer, type0: integer, type1: integer, day: integer, evening: integer, night: integer, playerChar?: integer, foeChar?: integer }>
BattlePresentationSources.TERRAIN = {
  plain = { ordinal = 0, type0 = 135, type1 = 136, day = 7, evening = 8, night = 9 },
  sand = { ordinal = 1, type0 = 145, type1 = 146, day = 22, evening = 23, night = 24 },
  grass = { ordinal = 2, type0 = 127, type1 = 130, day = 1, evening = 2, night = 3 },
  puddle = { ordinal = 3, type0 = 151, type1 = 152, day = 31, evening = 32, night = 33 },
  mountain = { ordinal = 4, type0 = 139, type1 = 140, day = 13, evening = 14, night = 15 },
  cave = { ordinal = 5, type0 = 149, type1 = 150, day = 28, evening = 29, night = 30 },
  snow = { ordinal = 6, type0 = 141, type1 = 142, day = 16, evening = 17, night = 18 },
  water = { ordinal = 7, type0 = 133, type1 = 134, day = 4, evening = 5, night = 6 },
  ice = { ordinal = 8, type0 = 137, type1 = 138, day = 10, evening = 11, night = 12 },
  building = { ordinal = 9, type0 = 143, type1 = 144, day = 19, evening = 20, night = 21 },
  great_marsh = { ordinal = 10, type0 = 147, type1 = 148, day = 25, evening = 26, night = 27 },
  unknown = { ordinal = 11, type0 = 151, type1 = 148, day = 25, evening = 26, night = 27 },
  will = { ordinal = 12, type0 = 153, type1 = 154, day = 34, evening = 35, night = 36 },
  koga = { ordinal = 13, type0 = 155, type1 = 156, day = 37, evening = 38, night = 39 },
  bruno = { ordinal = 14, type0 = 157, type1 = 158, day = 40, evening = 41, night = 42 },
  karen = { ordinal = 15, type0 = 159, type1 = 160, day = 43, evening = 44, night = 45 },
  lance = { ordinal = 16, type0 = 161, type1 = 162, day = 46, evening = 47, night = 48 },
  distortion_world = { ordinal = 17, type0 = 163, type1 = 164, day = 49, evening = 50, night = 51 },
  -- Frontier facility and distortion terrains in native ordinal order:
  -- the player-side cell member is the even file, the foe-side member
  -- the odd file, and the three palette members follow the time of
  -- day. Normalized semantic values only; no archive identities leak
  -- past this catalog.
  battle_tower = { ordinal = 18, type0 = 165, type1 = 166, day = 52, evening = 53, night = 54 },
  battle_factory = { ordinal = 19, type0 = 167, type1 = 168, day = 55, evening = 56, night = 57 },
  battle_arcade = { ordinal = 20, type0 = 169, type1 = 170, day = 58, evening = 59, night = 60 },
  battle_castle = { ordinal = 21, type0 = 171, type1 = 172, day = 61, evening = 62, night = 63 },
  battle_hall = { ordinal = 22, type0 = 173, type1 = 174, day = 64, evening = 65, night = 66 },
  giratina = { ordinal = 23, type0 = 175, type1 = 176, day = 67, evening = 68, night = 69 },
}

-- battle_terrain.c's side-specific character tables indexed by terrain ordinal.
local terrainPlayerCharacters = {
  0x87,
  0x91,
  0x7F,
  0x97,
  0x8B,
  0x95,
  0x8D,
  0x85,
  0x89,
  0x8F,
  0x93,
  0x97,
  0x99,
  0x9B,
  0x9D,
  0x9F,
  0xA1,
  0xA3,
  0xA5,
  0xA7,
  0xA9,
  0xAB,
  0xAD,
  0xAF,
}
local terrainFoeCharacters = {
  0x88,
  0x92,
  0x82,
  0x98,
  0x8C,
  0x96,
  0x8E,
  0x86,
  0x8A,
  0x90,
  0x94,
  0x94,
  0x9A,
  0x9C,
  0x9E,
  0xA0,
  0xA2,
  0xA4,
  0xA6,
  0xA8,
  0xAA,
  0xAC,
  0xAE,
  0xB0,
}
for _, terrain in pairs(BattlePresentationSources.TERRAIN) do
  terrain.playerChar = terrainPlayerCharacters[terrain.ordinal + 1]
  terrain.foeChar = terrainFoeCharacters[terrain.ordinal + 1]
  assert(terrain.playerChar ~= nil and terrain.foeChar ~= nil, "terrain OBJ source tables cover each terrain ordinal")
end

-- Exact shared menu/HUD member roles. All numbers below are zero-based
-- archive members: lower-screen roles live in the lower archive, HUD/arrow
-- and terrain roles in the scene archive. The doubled health-box
-- families follow the retail ROM's double HP bar sprite templates: one
-- animation, cell, and character member per slot, in left/right row
-- order per side.
BattlePresentationSources.ROLES = {
  lowerChars = 28,
  commandScreens = { 36, 41, 43 },
  fightScreens = { 37, 43 },
  targetScreens = { 38, 42, 43 },
  twoOptionScreens = { 39, 43 },
  lowerPalette = 246,
  hudPalette = 71,
  lowerObjPalette = 72,
  cursorPalette = 80,
  playerHud = { nanr = 189, ncer = 190, ncgr = 191 },
  enemyHud = { nanr = 186, ncer = 187, ncgr = 188 },
  playerHudDoubleLeft = { nanr = 198, ncer = 199, ncgr = 200 },
  playerHudDoubleRight = { nanr = 201, ncer = 202, ncgr = 203 },
  enemyHudDoubleLeft = { nanr = 192, ncer = 193, ncgr = 194 },
  enemyHudDoubleRight = { nanr = 195, ncer = 196, ncgr = 197 },
  arrow = { nanr = 183, ncer = 184, ncgr = 185 },
  cursor = { nanr = 252, ncer = 251, ncgr = 250 },
  gauges = {
    { ncer = 204, ncgr = 205, nanr = 206 },
    { ncer = 207, ncgr = 208, nanr = 209 },
  },
  backdropScreen = 2,
  terrainCells0 = 128,
  terrainAnim0 = 129,
  terrainCells1 = 131,
  terrainAnim1 = 132,
}

-- Source battle font behind narration. It resolves to an existing generated
-- font at compile time.
BattlePresentationSources.BATTLE_FONT_ID = 1

-- Ordinary single-battle audio roles: symbolic sequence references the
-- adopted audio plan resolves, never hard-coded bank numbers.
BattlePresentationSources.AUDIO_ROLES = {
  wild = "SEQ_GS_VS_NORAPOKE",
  trainer = "SEQ_GS_VS_TRAINER",
  rival = "SEQ_GS_VS_RIVAL",
  select = "SEQ_SE_DP_SELECT",
  gymLeader = "SEQ_GS_VS_GYMREADER",
  rocket = "SEQ_GS_VS_ROCKET",
  suicune = "SEQ_GS_VS_SUICUNE",
  entei = "SEQ_GS_VS_ENTEI",
  raikou = "SEQ_GS_VS_RAIKOU",
  champion = "SEQ_GS_VS_CHAMP",
  kantoWild = "SEQ_GS_VS_NORAPOKE_KANTO",
  kantoTrainer = "SEQ_GS_VS_TRAINER_KANTO",
  kantoGymLeader = "SEQ_GS_VS_GYMREADER_KANTO",
}

-- BattleSetup_GetWildBattleMusic and BattleStartGetMusic select the music
-- column of _020FC40A independently of the transition column. Row positions
-- are producer-only category IDs (zero-based); runtime routes use role keys.
-- Source: asm/unk_020517A4.s and include/constants/sndseq.h at the pinned
-- HeartGold decomp revision above.
BattlePresentationSources.INTRO_MUSIC = {
  inputs = {
    "encounterKind",
    "trainerClass",
    "wildSpecies",
    "battleType",
    "frontierBattle",
    "doubleBattle",
    "tagBattle",
    "wildSetupParameter",
    "firstLivingOpponent",
    "kantoRegion",
  },
  inputTypes = {
    encounterKind = "battle-encounter-kind",
    trainerClass = "battle-trainer-class",
    wildSpecies = "pokemon-species",
    battleType = "battle-type-flags",
    frontierBattle = "boolean",
    doubleBattle = "boolean",
    tagBattle = "boolean",
    wildSetupParameter = "wild-intro-setup-case",
    firstLivingOpponent = "opponent-party-selection",
    kantoRegion = "boolean",
  },
  rows = {
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER_KANTO",
    "SEQ_GS_VS_GYMREADER_KANTO",
    "SEQ_GS_VS_GYMREADER_KANTO",
    "SEQ_GS_VS_GYMREADER_KANTO",
    "SEQ_GS_VS_GYMREADER_KANTO",
    "SEQ_GS_VS_GYMREADER_KANTO",
    "SEQ_GS_VS_GYMREADER_KANTO",
    "SEQ_GS_VS_GYMREADER_KANTO",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_CHAMP",
    "SEQ_GS_VS_RIVAL",
    "SEQ_GS_VS_RAIKOU",
    "SEQ_GS_VS_ENTEI",
    "SEQ_GS_VS_SUICUNE",
    "SEQ_GS_VS_HOUOU",
    "SEQ_GS_VS_LUGIA",
    "SEQ_GS_VS_KODAI",
    "SEQ_GS_VS_NORAPOKE_KANTO",
    "SEQ_GS_VS_ROCKET",
    "SEQ_GS_VS_ROCKET",
    "SEQ_GS_VS_ROCKET",
    "SEQ_GS_VS_ROCKET",
    "SEQ_GS_VS_ROCKET",
    "SEQ_GS_VS_ROCKET",
    "SEQ_GS_VS_TRAINER",
    "SEQ_GS_VS_TRAINER",
    "SEQ_GS_VS_TRAINER",
    "SEQ_GS_VS_NORAPOKE",
    "SEQ_GS_BA_BRAIN",
    "SEQ_GS_VS_GYMREADER",
    "SEQ_GS_VS_TRAINER",
    "SEQ_GS_VS_NORAPOKE",
    "SEQ_GS_VS_TRAINER",
    "SEQ_GS_VS_CHAMP",
  },
  roles = {
    SEQ_GS_VS_GYMREADER = "gym-leader",
    SEQ_GS_VS_GYMREADER_KANTO = "kanto-gym-leader",
    SEQ_GS_VS_CHAMP = "champion",
    SEQ_GS_VS_RIVAL = "rival",
    SEQ_GS_VS_RAIKOU = "raikou",
    SEQ_GS_VS_ENTEI = "entei",
    SEQ_GS_VS_SUICUNE = "suicune",
    SEQ_GS_VS_HOUOU = "ho-oh",
    SEQ_GS_VS_LUGIA = "lugia",
    SEQ_GS_VS_KODAI = "special-legendary",
    SEQ_GS_VS_NORAPOKE_KANTO = "kanto-wild",
    SEQ_GS_VS_TRAINER_KANTO = "kanto-trainer",
    SEQ_GS_VS_ROCKET = "rocket",
    SEQ_GS_VS_TRAINER = "trainer",
    SEQ_GS_VS_NORAPOKE = "wild",
    SEQ_GS_BA_BRAIN = "battle-arcade-brain",
  },
  transitionFallbackCategories = { [22] = true, [23] = true, [24] = true, [41] = true, [42] = true },
  kantoOverrides = { "wild/ordinary", "trainer/generic" },
  routeContexts = {
    ["gym-leader"] = { "encounterKind", "trainerClass", "battleType", "frontierBattle", "doubleBattle", "tagBattle" },
    ["kanto-gym-leader"] = { "encounterKind", "trainerClass", "battleType" },
    champion = { "encounterKind", "trainerClass", "battleType", "frontierBattle", "doubleBattle", "tagBattle" },
    rival = { "encounterKind", "trainerClass", "battleType" },
    raikou = {
      "encounterKind",
      "wildSpecies",
      "firstLivingOpponent",
      "wildSetupParameter",
      "battleType",
      "doubleBattle",
    },
    entei = {
      "encounterKind",
      "wildSpecies",
      "firstLivingOpponent",
      "wildSetupParameter",
      "battleType",
      "doubleBattle",
    },
    suicune = {
      "encounterKind",
      "wildSpecies",
      "firstLivingOpponent",
      "wildSetupParameter",
      "battleType",
      "doubleBattle",
    },
    ["ho-oh"] = {
      "encounterKind",
      "wildSpecies",
      "firstLivingOpponent",
      "wildSetupParameter",
      "battleType",
      "doubleBattle",
    },
    lugia = {
      "encounterKind",
      "wildSpecies",
      "firstLivingOpponent",
      "wildSetupParameter",
      "battleType",
      "doubleBattle",
    },
    ["special-legendary"] = {
      "encounterKind",
      "wildSpecies",
      "firstLivingOpponent",
      "wildSetupParameter",
      "battleType",
      "doubleBattle",
    },
    ["kanto-wild"] = {
      "encounterKind",
      "wildSpecies",
      "firstLivingOpponent",
      "wildSetupParameter",
      "battleType",
      "doubleBattle",
      "kantoRegion",
    },
    ["kanto-trainer"] = {
      "encounterKind",
      "trainerClass",
      "battleType",
      "frontierBattle",
      "doubleBattle",
      "tagBattle",
      "kantoRegion",
    },
    rocket = { "encounterKind", "trainerClass", "battleType", "frontierBattle", "doubleBattle", "tagBattle" },
    trainer = {
      "encounterKind",
      "trainerClass",
      "battleType",
      "frontierBattle",
      "doubleBattle",
      "tagBattle",
      "kantoRegion",
    },
    wild = {
      "encounterKind",
      "wildSpecies",
      "firstLivingOpponent",
      "wildSetupParameter",
      "battleType",
      "doubleBattle",
      "kantoRegion",
    },
    ["battle-arcade-brain"] = { "encounterKind", "trainerClass", "battleType", "frontierBattle" },
  },
  selectionRules = {
    trainer = {
      predicate = "battleType-trainer",
      classSource = "selected-opponent-trainer-class",
      categorySource = "NPCTrainerGetBattleIntroAndMusicParam",
      modifiers = { "frontierBattle", "doubleBattle", "tagBattle" },
    },
    wild = {
      predicate = "not-battleType-trainer",
      speciesSource = "first-living-opponent",
      specialSetupCase = "special-wild-transition-parameter",
      modifier = "doubleBattle",
    },
    kantoOverride = {
      predicate = { "kanto-flypoint-flag", "map-region-nonzero" },
      appliesAfterCategorySelection = true,
      routes = { ["wild/ordinary"] = "kanto-wild", ["trainer/generic"] = "kanto-trainer" },
    },
  },
  selectionSound = {
    role = "menu-selection",
    sequenceSymbol = "SEQ_SE_DP_SELECT",
    eventInput = "menuSelectionEvent",
  },
  transitionFallbackIndependent = true,
}

-- BattleInput menu-template selectors from src/battle/battle_input.c and
-- include/constants/battle_menu.h. Selector values are producer-only; only
-- routes with source-established behavior receive semantic catalog keys.
-- Selectors 19/20 are selected in ov12_0225DAD4 when BATTLE_TYPE_BUG_CONTEST
-- is set: byte 0x197 in the controller work record selects initial (zero)
-- versus ordinary (nonzero) menu construction. Their template callbacks are
-- the initial and ordinary main-menu constructors, respectively.
BattlePresentationSources.MENU_ROUTES = {
  ["menu/none"] = { sourceSelector = 0, screenGroup = "none", textSet = "none" },
  ["menu/main/initial"] = { sourceSelector = 1, screenGroup = "command", textSet = "main" },
  ["menu/main/ordinary"] = { sourceSelector = 2, screenGroup = "command", textSet = "main" },
  ["menu/main/context"] = { sourceSelector = 3, screenGroup = "command", textSet = "main" },
  ["menu/main/context-alt"] = { sourceSelector = 4, screenGroup = "command", textSet = "main" },
  ["menu/main/fight-initial"] = { sourceSelector = 5, screenGroup = "command", textSet = "main" },
  ["menu/main/fight"] = { sourceSelector = 6, screenGroup = "command", textSet = "main" },
  ["menu/main/single-initial"] = { sourceSelector = 7, screenGroup = "command", textSet = "main" },
  ["menu/main/single"] = { sourceSelector = 8, screenGroup = "command", textSet = "main" },
  ["menu/bug-contest/initial"] = {
    sourceSelector = 19,
    screenGroup = "command",
    textSet = "main",
    mode = "bug-contest",
    phase = "initial",
  },
  ["menu/bug-contest/ordinary"] = {
    sourceSelector = 20,
    screenGroup = "command",
    textSet = "main",
    mode = "bug-contest",
    phase = "ordinary",
  },
  ["menu/pal-park/initial"] = { sourceSelector = 9, screenGroup = "command", textSet = "pal-park" },
  ["menu/pal-park"] = { sourceSelector = 10, screenGroup = "command", textSet = "pal-park" },
  ["menu/fight"] = { sourceSelector = 11, screenGroup = "fight", textSet = "fight" },
  ["menu/target"] = { sourceSelector = 12, screenGroup = "target", textSet = "target" },
  ["menu/yes-no"] = { sourceSelector = 13, screenGroup = "two-option", textSet = "yes-no" },
  ["menu/keep-forget"] = { sourceSelector = 14, screenGroup = "two-option", textSet = "keep-forget" },
  ["menu/give-up"] = { sourceSelector = 15, screenGroup = "two-option", textSet = "give-up" },
  ["menu/switch-or-flee"] = { sourceSelector = 16, screenGroup = "two-option", textSet = "switch-or-flee" },
  ["menu/switch-or-keep"] = { sourceSelector = 17, screenGroup = "two-option", textSet = "switch-or-keep" },
  ["menu/vs-recorder"] = { sourceSelector = 18, screenGroup = "vs-recorder", textSet = "vs-recorder" },
}

-- Source-selected battle menu assets. Physical member IDs are producer
-- inputs only; these records describe decoded resources and fixed sprite roles.
BattlePresentationSources.MENU_LAYOUT_RESOURCES = {
  frontier = {
    character = { archive = "NARC_a_0_0_7", memberId = 173, kind = "texture" },
    palette = { archive = "NARC_a_0_0_7", memberId = 349, kind = "palette" },
    tilemap = { archive = "NARC_a_0_0_7", memberId = 174, kind = "map" },
    touchPalette = { archive = "NARC_a_0_0_7", memberId = 350, kind = "palette" },
  },
  vsRecorder = {
    tilemap = { archive = "NARC_a_0_0_7", memberId = 40, kind = "map" },
  },
  bugContest = {
    character = { archive = "NARC_a_0_0_8", memberId = 343, kind = "texture" },
    palette = { archive = "NARC_a_0_0_8", memberId = 72, kind = "palette" },
    cell = { archive = "NARC_a_0_0_8", memberId = 344, kind = "cell" },
    animation = { archive = "NARC_a_0_0_8", memberId = 345, kind = "animation" },
  },
}

BattlePresentationSources.BUG_CONTEST_SPRITES = {
  sportBall = { x = 208, y = 16, palette = 5, animation = 0 },
  bugNet = { x = 88, y = 8, palette = 4, animation = 1 },
}

-- BallThrow loads four G2D resources selected by BallAnim_GetSpriteResource
-- from sBallSpriteResources in battle_anim_data.s.  The table is indexed by
-- ballId - 1 for IDs 1..24; each family advances its member IDs by the
-- source stride shown here.
local ballPictureKeys = {
  "MASTER_BALL",
  "ULTRA_BALL",
  "GREAT_BALL",
  "POKE_BALL",
  "SAFARI_BALL",
  "NET_BALL",
  "DIVE_BALL",
  "NEST_BALL",
  "REPEAT_BALL",
  "TIMER_BALL",
  "LUXURY_BALL",
  "PREMIER_BALL",
  "DUSK_BALL",
  "HEAL_BALL",
  "QUICK_BALL",
  "CHERISH_BALL",
  "FAST_BALL",
  "LEVEL_BALL",
  "LURE_BALL",
  "HEAVY_BALL",
  "LOVE_BALL",
  "FRIEND_BALL",
  "MOON_BALL",
  "SPORT_BALL",
}
local ballPictures = {}
for ballId, itemKey in ipairs(ballPictureKeys) do
  local resourceBase = 259 + (ballId - 1) * 3
  ballPictures[itemKey] = {
    ballId = ballId,
    animationMember = resourceBase,
    cellMember = resourceBase + 1,
    characterMember = resourceBase + 2,
    paletteMember = 83 + ballId - 1,
  }
end

BattlePresentationSources.BALL_PICTURES = {
  archive = "NARC_a_0_0_8",
  source = {
    symbol = "BallAnim_GetSpriteResource",
    table = "sBallSpriteResources",
    index = "BallAnim_GetBallTableIndex(ballId)",
  },
  memberOffsets = {
    animation = 0,
    cell = 1,
    character = 2,
    palette = 0,
  },
  entries = ballPictures,
  -- sBallColors in the overlay-12 data (battle_controller_opponent.c): one
  -- BGR555 word per ball id 0..24, the Pokepic palette-fade target of the
  -- recall and send-out. The address is the retail overlay-12 symbol.
  fadeColors = { cpu = "arm9", overlayId = 12, address = 0x0226D15A, count = 25 },
}

-- Exact battle-menu text selectors from battle_input.c's message-bank
-- constructors. Dynamic mon/move names and other battle dialogue are
-- published by their own source routes, not guessed into this static set.
BattlePresentationSources.MENU_MESSAGE_BANK = "NARC_msgdata_msg"
BattlePresentationSources.MENU_TEXT_FONT_ID = 4
BattlePresentationSources.HUD_MESSAGE_FONT_ID = 0
BattlePresentationSources.RECORDER_FEEDBACK_FONT_ID = 0
BattlePresentationSources.BUG_CONTEST_FONT_ID = 0
-- Source palettes behind each battle text printer, as leading sixteen-color
-- banks: Battle_BattleInit loads graphic/font member 8 into the narration
-- window's palette; health-box names and digits print in the HUD OBJ
-- palette; menu text OBJs select a bank of the seven-bank lower OBJ palette
-- through their palOffset.
BattlePresentationSources.TEXT_PALETTES = {
  narration = { narc = "NARC_graphic_font", member = 8, banks = 1 },
  hud = { narc = "NARC_a_0_0_8", member = 71, banks = 1 },
  menu = { narc = "NARC_a_0_0_8", member = 72, banks = 7 },
}
BattlePresentationSources.TRANSITION_MESSAGE_MEMBER = 189
BattlePresentationSources.TRANSITION_MESSAGE_ID = 0
BattlePresentationSources.FRONTIER_TRAINER_MESSAGE_ROUTE = {
  archive = "NARC_msgdata_msg",
  profileVersionZero = 723,
  noProfileVersionZero = 724,
  trainerMessageString = { multiplier = 3, winOffset = 1, lossOffset = 2 },
  mailMessage = { trainerId = 0x2710, battleTypeBit = 13 },
  printerFontId = 1,
}
BattlePresentationSources.FRONTIER_TRAINER_MAIL = {
  source = { file = "src/battle/battle_system.c", symbol = "BattleSystem_PrintTrainerMessage" },
  expander = { file = "src/mail_message.c", symbol = "MailMsg_GetExpandedString" },
  inputs = { "trainerWinOrLossMail", "trainerOutcome" },
  messageBanks = {
    "message-bank/mail-text/a",
    "message-bank/mail-text/b",
    "message-bank/mail-text/c",
    "message-bank/mail-text/d",
    "message-bank/mail-text/e",
  },
  selection = { mailBank = "runtime-mail-bank", message = "runtime-mail-message-number" },
  expansion = "easyChatWordIndices",
  placeholderFields = "easyChatWordIndices",
  easyChatBanks = {
    "message-bank/easy-chat/species",
    "message-bank/easy-chat/moves",
    "message-bank/easy-chat/types",
    "message-bank/easy-chat/abilities",
    "message-bank/easy-chat/trainers",
    "message-bank/easy-chat/people",
    "message-bank/easy-chat/greetings",
    "message-bank/easy-chat/lifestyle",
    "message-bank/easy-chat/feelings",
    "message-bank/easy-chat/tough-words",
    "message-bank/easy-chat/union",
  },
}
BattlePresentationSources.TRANSITION_MESSAGE_SOURCE_ROUTES = {
  trainerName = {
    key = "transition/trainer-name",
    selectors = {
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
      29,
      30,
      31,
      32,
      33,
      40,
      41,
      42,
      43,
      44,
    },
  },
  rivalName = { key = "transition/rival-name", selectors = { 28 } },
}
-- Battle message banks selected by pinned HGSS text loaders. Member values
-- remain build inputs; the manifest uses only these semantic role keys.
BattlePresentationSources.MESSAGE_BANKS = {
  scriptController = 197,
  attackMessage = 3,
  itemFeedback = 5,
  partyResult = 6,
  frontierTrainerProfileZero = 723,
  frontierTrainerProfileFallback = 724,
  trainerPairLookup = 728,
  tutorialAuthor = 445,
  transitionName = 189,
  speciesPlaceholder = 237,
  movePlaceholder = 750,
  abilityPlaceholder = 720,
  itemPlaceholder = 222,
  typePlaceholder = 735,
  statPlaceholder = 443,
  statusPlaceholder = 44,
  trainerClassPlaceholder = 730,
  trainerNamePlaceholder = 729,
  flavorPlaceholder = 639,
  mailTextA = 294,
  mailTextB = 296,
  mailTextC = 292,
  mailTextD = 293,
  mailTextE = 295,
  easyChatSpecies = 237,
  easyChatMoves = 751,
  easyChatTypes = 735,
  easyChatAbilities = 721,
  easyChatTrainers = 285,
  easyChatPeople = 286,
  easyChatGreetings = 287,
  easyChatLifestyle = 288,
  easyChatFeelings = 289,
  easyChatToughWords = 290,
  easyChatUnion = 291,
}
BattlePresentationSources.MESSAGE_BANK_RESOURCE_KEYS = {
  scriptController = "message-bank/battle-script-controller",
  attackMessage = "message-bank/attack-message",
  itemFeedback = "message-bank/battle-item-feedback",
  partyResult = "message-bank/battle-party-result",
  frontierTrainerProfileZero = "message-bank/trainer-profile-zero",
  frontierTrainerProfileFallback = "message-bank/trainer-profile-fallback",
  trainerPairLookup = "message-bank/trainer-pair-lookup",
  tutorialAuthor = "message-bank/tutorial-author",
  transitionName = "message-bank/transition-names",
  speciesPlaceholder = "message-bank/species-placeholder",
  movePlaceholder = "message-bank/move-placeholder",
  abilityPlaceholder = "message-bank/ability-placeholder",
  itemPlaceholder = "message-bank/item-placeholder",
  typePlaceholder = "message-bank/type-placeholder",
  statPlaceholder = "message-bank/stat-placeholder",
  statusPlaceholder = "message-bank/status-placeholder",
  trainerClassPlaceholder = "message-bank/trainer-class-placeholder",
  trainerNamePlaceholder = "message-bank/trainer-name-placeholder",
  flavorPlaceholder = "message-bank/flavor-placeholder",
  mailTextA = "message-bank/mail-text/a",
  mailTextB = "message-bank/mail-text/b",
  mailTextC = "message-bank/mail-text/c",
  mailTextD = "message-bank/mail-text/d",
  mailTextE = "message-bank/mail-text/e",
  easyChatSpecies = "message-bank/easy-chat/species",
  easyChatMoves = "message-bank/easy-chat/moves",
  easyChatTypes = "message-bank/easy-chat/types",
  easyChatAbilities = "message-bank/easy-chat/abilities",
  easyChatTrainers = "message-bank/easy-chat/trainers",
  easyChatPeople = "message-bank/easy-chat/people",
  easyChatGreetings = "message-bank/easy-chat/greetings",
  easyChatLifestyle = "message-bank/easy-chat/lifestyle",
  easyChatFeelings = "message-bank/easy-chat/feelings",
  easyChatToughWords = "message-bank/easy-chat/tough-words",
  easyChatUnion = "message-bank/easy-chat/union",
}
BattlePresentationSources.TRAINER_MESSAGE_TABLES = {
  offsetsArchive = "NARC_poketool_trmsg_trtblofs",
  pairsArchive = "NARC_poketool_trmsg_trtbl",
  memberId = 0,
  offsetsResource = "trainer-message-index/offsets",
  pairsResource = "trainer-message-index/pairs",
  offsetSelection = {
    input = "trainerIndex",
    elementStrideBytes = 2,
    valueWidthBytes = 2,
    result = "pair-record-byte-offset",
  },
  pairSelection = {
    inputs = { "trainerIndex", "trainerMessageKind" },
    recordStrideBytes = 4,
    match = "trainer-and-message-kind",
    result = "messageRecordReference",
  },
}
BattlePresentationSources.MESSAGE_ROUTES = {
  captureShake = {
    bank = "scriptController",
    input = "captureShakeCount",
    firstRecord = "battle/capture-shakes/0",
    minimum = 0,
    maximum = 4,
    recordCount = 5,
  },
  metBillPCTransfer = {
    inputs = { "metBill", "pcHasSpace" },
    banks = { "scriptController" },
    cases = {
      { key = "battle/pc-transfer/has-space/someone", metBill = false, pcHasSpace = true },
      { key = "battle/pc-transfer/has-space/bill", metBill = true, pcHasSpace = true },
      { key = "battle/pc-transfer/box-full/someone", metBill = false, pcHasSpace = false },
      { key = "battle/pc-transfer/box-full/bill", metBill = true, pcHasSpace = false },
    },
  },
  frontierTrainerSpeech = {
    inputs = { "trainerIndex", "outcome", "playerProfiles" },
    banks = { "message-bank/trainer-profile-zero", "message-bank/trainer-profile-fallback" },
    profilePredicate = "anyPlayerProfileVersionZero",
    recordFormula = { trainerIndexMultiplier = 3, winOffset = 1, lossOffset = 2 },
    mailExpansion = "frontierTrainerMail",
  },
  trainerPairSpeech = {
    inputs = { "trainerIndex", "trainerMessageKind" },
    selection = {
      lookup = "trainer-message-index",
      matchingFields = { "trainerIndex", "trainerMessageKind" },
      output = "messageRecordReference",
    },
    offsetsResource = "trainer-message-index/offsets",
    pairsResource = "trainer-message-index/pairs",
    bank = "message-bank/trainer-pair-lookup",
    recordSelection = "matching-trainer-and-message-kind",
    semanticKey = "battle/trainer-pair-speech",
  },
  tutorialAuthor = {
    input = "playerGender",
    bank = "tutorialAuthor",
    variants = { malePlayer = "tutorial/author/male-player", femalePlayer = "tutorial/author/female-player" },
    nativeSelection = "playerGender-xor-one",
  },
}
-- Semantic source families and typed operands consumed by the message
-- producer. Native message IDs and source member identities stay in the
-- bank/record tables above; these records describe the source call contracts.
BattlePresentationSources.MESSAGE_SOURCE_ROUTES = {
  scriptLiteral = {
    key = "battle/script-message",
    source = {
      callsite = { file = "files/battledata/script", symbol = "PrintMessage" },
      macro = { file = "asm/macros/btlcmd.inc", symbol = "PrintMessage" },
      handlerTable = { file = "asm/overlay_12_battle_command.s", symbol = "BtlCmd_PrintMessage" },
      command = { file = "src/battle/battle_command.c", symbol = "BtlCmd_PrintMessage" },
      readOperands = { file = "src/battle/battle_command.c", symbol = "InitBattleMsgData" },
      resolveContext = { file = "src/battle/battle_command.c", symbol = "InitBattleMsg" },
    },
    banks = { "message-bank/battle-script-controller" },
    operands = { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" },
    recordSelection = "literal-at-script-callsite",
    placeholderPlan = "battleMessageTags",
    programContext = {
      program = "battle-script",
      context = "battle-message",
      delivery = "message-scope-local",
      record = {
        input = "messageRecordReference",
        bank = "message-bank/battle-script-controller",
        selection = "link-time-record-reference",
      },
      placeholders = {
        tagInput = "messageTagSymbol",
        parametersInput = "tagTypedParameters",
        schemaCatalog = "tagSchemas",
        contextCatalog = "tagInputs",
        placeholderCatalog = "placeholders",
        bufferCatalog = "templateInputs",
        expansionRoute = "battle/message-template",
      },
    },
  },
  scriptGlobal = {
    key = "battle/global-script-message",
    source = {
      callsite = { file = "files/battledata/script", symbol = "PrintGlobalMessage" },
      macro = { file = "asm/macros/btlcmd.inc", symbol = "PrintGlobalMessage" },
      handlerTable = { file = "asm/overlay_12_battle_command.s", symbol = "BtlCmd_PrintGlobalMessage" },
      command = { file = "src/battle/battle_command.c", symbol = "BtlCmd_PrintGlobalMessage" },
      readOperands = { file = "src/battle/battle_command.c", symbol = "InitBattleMsgData" },
      resolveContext = { file = "src/battle/battle_command.c", symbol = "InitBattleMsg" },
      scope = {
        file = "src/battle/battle_command.c",
        symbol = "BtlCmd_PrintGlobalMessage",
        semantic = "global-message",
      },
    },
    banks = { "message-bank/battle-script-controller" },
    operands = { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" },
    recordSelection = "literal-at-script-callsite",
    placeholderPlan = "battleMessageTags",
    programContext = {
      program = "battle-script",
      context = "battle-message",
      delivery = "message-scope-global",
      record = {
        input = "messageRecordReference",
        bank = "message-bank/battle-script-controller",
        selection = "link-time-record-reference",
      },
      placeholders = {
        tagInput = "messageTagSymbol",
        parametersInput = "tagTypedParameters",
        schemaCatalog = "tagSchemas",
        contextCatalog = "tagInputs",
        placeholderCatalog = "placeholders",
        bufferCatalog = "templateInputs",
        expansionRoute = "battle/message-template",
      },
    },
  },
  recorderFeedback = {
    key = "battle/recorder-feedback",
    source = { file = "src/battle/battle_input.c", symbol = "BattleInput_PrintSystemMessage" },
    banks = { "message-bank/battle-script-controller" },
    input = "feedbackKind",
    reachable = { "paused", "corrupted" },
    unreachable = { "battleTooLong" },
  },
  battleCommand = {
    key = "battle/command-message",
    source = { file = "src/battle/battle_command.c", symbol = "Task_GetPokemon" },
    banks = { "message-bank/battle-script-controller" },
    routes = { "captureShake", "metBillPCTransfer" },
  },
  frontierTrainerSpeech = {
    key = "battle/frontier-trainer-speech",
    source = { file = "src/battle/battle_system.c", symbol = "BattleSystem_PrintTrainerMessage" },
    banks = { "message-bank/trainer-profile-zero", "message-bank/trainer-profile-fallback" },
    inputs = { "trainerIndex", "outcome", "playerProfiles", "trainerMail" },
    mailExpansion = "frontierTrainerMail",
    mailCase = "special-trainer-or-frontier-battle-type",
  },
  frontierTrainerMail = {
    key = "battle/frontier-trainer-mail",
    source = { file = "src/battle/battle_system.c", symbol = "BattleSystem_PrintTrainerMessage" },
    expander = { file = "src/mail_message.c", symbol = "MailMsg_GetExpandedString" },
    inputs = { "trainerWinOrLossMail", "trainerOutcome" },
    banks = {
      "message-bank/mail-text/a",
      "message-bank/mail-text/b",
      "message-bank/mail-text/c",
      "message-bank/mail-text/d",
      "message-bank/mail-text/e",
      "message-bank/easy-chat/species",
      "message-bank/easy-chat/moves",
      "message-bank/easy-chat/types",
      "message-bank/easy-chat/abilities",
      "message-bank/easy-chat/trainers",
      "message-bank/easy-chat/people",
      "message-bank/easy-chat/greetings",
      "message-bank/easy-chat/lifestyle",
      "message-bank/easy-chat/feelings",
      "message-bank/easy-chat/tough-words",
      "message-bank/easy-chat/union",
    },
    selection = "runtime-mail-bank-and-message-number",
    placeholders = "easyChatWordIndices",
  },
  trainerPairSpeech = {
    key = "battle/trainer-pair-speech",
    source = { file = "src/trainer_data.c", symbol = "GetTrainerMessageByIdPair" },
    banks = { "message-bank/trainer-pair-lookup" },
    inputs = { "trainerIndex", "trainerMessageKind" },
    resources = { "trainer-message-index/offsets", "trainer-message-index/pairs" },
    selection = "trainer-pair-table-match",
  },
  tutorialAuthor = {
    key = "battle/tutorial-author",
    source = { file = "src/battle/battle_setup.c", symbol = "BattleSetup_New_Tutorial" },
    banks = { "message-bank/tutorial-author" },
    input = "playerGender",
    selection = "gender-xor-one",
  },
  messageTemplate = {
    key = "battle/message-template",
    source = { file = "src/battle/battle_system.c", symbol = "BattleMessage_ExpandPlaceholders" },
    inputs = { "messageRecord", "battleMessageTag", "tagParameters" },
    buffers = "tagSelectedBuffers",
    banks = {
      "message-bank/species-placeholder",
      "message-bank/move-placeholder",
      "message-bank/ability-placeholder",
      "message-bank/item-placeholder",
      "message-bank/type-placeholder",
      "message-bank/stat-placeholder",
      "message-bank/status-placeholder",
      "message-bank/trainer-class-placeholder",
      "message-bank/trainer-name-placeholder",
      "message-bank/flavor-placeholder",
    },
  },
  controllerMessage = {
    key = "battle/controller-message",
    source = { file = "src/battle/battle_system.c", symbol = "BattleSystem_PrintBattleMessage" },
    banks = { "message-bank/battle-script-controller" },
    operands = { "messageRecord", "battleMessageTag", "tagParameters" },
    placeholderPlan = "battleMessageTags",
  },
}
-- Ordered message-buffer operands from BattleSystem_BufferMessage. Symbols
-- stay producer-side; semantic slot names describe which source values are
-- resolved from the script context and which placeholder banks are needed.
BattlePresentationSources.MESSAGE_TAG_DISPATCH = {
  source = "BattleSystem_BufferMessage",
  mask = "low-six-bits",
  tags = "include/constants/message_tags.h",
  unresolvedTag = "GF_ASSERT",
}
BattlePresentationSources.MESSAGE_TAG_SCHEMAS = {
  TAG_NONE = {},
  TAG_NONE_SIDE = {},
  TAG_NICKNAME = { "nickname" },
  TAG_MOVE = { "move" },
  TAG_STAT = { "stat" },
  TAG_ITEM = { "item" },
  TAG_NUMBER = { "number" },
  TAG_NUMBERS = { "numbers" },
  TAG_TRNAME = { "trainerName" },
  TAG_NICKNAME_NICKNAME = { "nickname", "nickname" },
  TAG_NICKNAME_MOVE = { "nickname", "move" },
  TAG_NICKNAME_ABILITY = { "nickname", "ability" },
  TAG_NICKNAME_STAT = { "nickname", "stat" },
  TAG_NICKNAME_TYPE = { "nickname", "type" },
  TAG_NICKNAME_POKE = { "nickname", "species" },
  TAG_NICKNAME_ITEM = { "nickname", "item" },
  TAG_NICKNAME_POFFIN = { "nickname", "poffin" },
  TAG_NICKNAME_NUM = { "nickname", "number" },
  TAG_NICKNAME_TRNAME = { "nickname", "trainerName" },
  TAG_NICKNAME_BOX = { "nickname", "boxName" },
  TAG_MOVE_SIDE = { "move" },
  TAG_MOVE_NICKNAME = { "move", "nickname" },
  TAG_MOVE_MOVE = { "move", "move" },
  TAG_ABILITY_NICKNAME = { "ability", "nickname" },
  TAG_ITEM_MOVE = { "item", "move" },
  TAG_NUMBER_NUMBER = { "number", "number" },
  TAG_TRNAME_TRNAME = { "trainerName", "trainerName" },
  TAG_TRNAME_NICKNAME = { "trainerName", "nickname" },
  TAG_TRNAME_ITEM = { "trainerName", "item" },
  TAG_TRNAME_NUM = { "trainerName", "number" },
  TAG_TRCLASS_TRNAME = { "trainerClass", "trainerName" },
  TAG_NICKNAME_NICKNAME_MOVE = { "nickname", "nickname", "move" },
  TAG_NICKNAME_NICKNAME_ABILITY = { "nickname", "nickname", "ability" },
  TAG_NICKNAME_NICKNAME_ITEM = { "nickname", "nickname", "item" },
  TAG_NICKNAME_MOVE_MOVE = { "nickname", "move", "move" },
  TAG_NICKNAME_MOVE_NUMBER = { "nickname", "move", "number" },
  TAG_NICKNAME_ABILITY_NICKNAME = { "nickname", "ability", "nickname" },
  TAG_NICKNAME_ABILITY_MOVE = { "nickname", "ability", "move" },
  TAG_NICKNAME_ABILITY_ITEM = { "nickname", "ability", "item" },
  TAG_NICKNAME_ABILITY_STAT = { "nickname", "ability", "stat" },
  TAG_NICKNAME_ABILITY_TYPE = { "nickname", "ability", "type" },
  TAG_NICKNAME_ABILITY_STATUS = { "nickname", "ability", "status" },
  TAG_NICKNAME_ABILITY_NUMBER = { "nickname", "ability", "number" },
  TAG_NICKNAME_ITEM_NICKNAME = { "nickname", "item", "nickname" },
  TAG_NICKNAME_ITEM_MOVE = { "nickname", "item", "move" },
  TAG_NICKNAME_ITEM_STAT = { "nickname", "item", "stat" },
  TAG_NICKNAME_ITEM_STATUS = { "nickname", "item", "status" },
  TAG_NICKNAME_BOX_BOX = { "nickname", "boxName", "boxName" },
  TAG_ITEM_NICKNAME_FLAVOR = { "item", "nickname", "flavorPreference" },
  TAG_TRNAME_NICKNAME_NICKNAME = { "trainerName", "nickname", "nickname" },
  TAG_TRCLASS_TRNAME_NICKNAME = { "trainerClass", "trainerName", "nickname" },
  TAG_TRCLASS_TRNAME_ITEM = { "trainerClass", "trainerName", "item" },
  TAG_NICKNAME_ABILITY_NICKNAME_MOVE = { "nickname", "ability", "nickname", "move" },
  TAG_NICKNAME_ABILITY_NICKNAME_ABILITY = { "nickname", "ability", "nickname", "ability" },
  TAG_NICKNAME_ABILITY_NICKNAME_STAT = { "nickname", "ability", "nickname", "stat" },
  TAG_NICKNAME_ITEM_NICKNAME_ITEM = { "nickname", "item", "nickname", "item" },
  TAG_TRNAME_NICKNAME_TRNAME_NICKNAME = { "trainerName", "nickname", "trainerName", "nickname" },
  TAG_TRCLASS_TRNAME_NICKNAME_NICKNAME = { "trainerClass", "trainerName", "nickname", "nickname" },
  TAG_TRCLASS_TRNAME_NICKNAME_TRNAME = { "trainerClass", "trainerName", "nickname", "trainerName" },
  TAG_TRCLASS_TRNAME_TRCLASS_TRNAME = { "trainerClass", "trainerName", "trainerClass", "trainerName" },
  TAG_TRCLASS_TRNAME_NICKNAME_TRCLASS_TRNAME_NICKNAME = {
    "trainerClass",
    "trainerName",
    "nickname",
    "trainerClass",
    "trainerName",
    "nickname",
  },
}
BattlePresentationSources.MESSAGE_TAG_CONTEXT_RESOLVERS = {
  nickname = { source = "ov12_022480C0", input = "battlerCategory", result = "battlerAndPartySlot" },
  species = { source = "ov12_022481E8", input = "battlerCategory", result = "battlerAndSelectedPartySlot" },
  move = {
    source = "GetMoveMessageNo",
    input = "moveSelector",
    result = "moveMessageRecord",
    selectors = { "currentMove", "temporaryMove" },
  },
  item = { source = "ov12_0224810C", input = "itemSourceCategory", result = "selectedBattleItem" },
  ability = { source = "ov12_0224819C", input = "battlerCategory", result = "selectedBattleAbility" },
  stat = { source = "ov12_022481D0", input = "messageTemporaryCategory", result = "messageTemporaryValue" },
  type = { source = "ov12_02248190", input = "messageTemporaryCategory", result = "messageTemporaryValue" },
  status = { source = "ov12_022481DC", input = "messageTemporaryCategory", result = "messageTemporaryValue" },
  number = { source = "ov12_02248184", input = "messageTemporaryCategory", result = "messageTemporaryValue" },
  flavorPreference = { source = "ov12_0224820C", input = "messageTemporaryCategory", result = "messageTemporaryValue" },
  trainerClass = { source = "ov12_02248218", input = "battlerCategory", result = "battlerTrainerClass" },
  trainerName = { source = "ov12_02248220", input = "battlerCategory", result = "battlerTrainerName" },
  boxName = { source = "InitBattleMsg", input = "boxIndex", result = "boxName" },
  numbers = { source = "ov12_02248184", input = "messageTemporaryCategory", result = "messageTemporaryValue" },
  poffin = { source = "ov12_02248200", input = "messageTemporaryCategory", result = "unusedInHGSS" },
}
BattlePresentationSources.MESSAGE_PLACEHOLDER_BANKS = {
  species = "speciesPlaceholder",
  move = "movePlaceholder",
  ability = "abilityPlaceholder",
  item = "itemPlaceholder",
  type = "typePlaceholder",
  stat = "statPlaceholder",
  status = "statusPlaceholder",
  trainerClass = "trainerClassPlaceholder",
  trainerName = "trainerNamePlaceholder",
  flavorPreference = "flavorPlaceholder",
}
BattlePresentationSources.MESSAGE_PLACEHOLDER_SCHEMAS = {
  species = {
    bankRole = "speciesPlaceholder",
    source = "BufferSpeciesName",
    input = "speciesId",
  },
  move = { bankRole = "movePlaceholder", source = "BattleMessage_BufferMove", input = "moveId" },
  ability = { bankRole = "abilityPlaceholder", source = "BattleMessage_BufferAbility", input = "abilityId" },
  item = { bankRole = "itemPlaceholder", source = "BattleMessage_BufferItem", input = "itemId" },
  type = { bankRole = "typePlaceholder", source = "BattleMessage_BufferType", input = "typeId" },
  stat = { bankRole = "statPlaceholder", source = "BattleMessage_BufferStat", input = "battleStatId" },
  status = { bankRole = "statusPlaceholder", source = "BattleMessage_BufferStatus", input = "battleStatusId" },
  trainerClass = {
    bankRole = "trainerClassPlaceholder",
    source = "BattleMessage_BufferTrainerClass",
    input = "trainerClassId",
  },
  trainerName = {
    bankRole = "trainerNamePlaceholder",
    source = "BattleMessage_BufferTrainerName",
    input = "trainerIndex",
  },
  flavorPreference = {
    bankRole = "flavorPlaceholder",
    source = "BattleMessage_BufferFlavorPreference",
    input = "flavorId",
  },
}
BattlePresentationSources.MESSAGE_TEMPLATE_INPUTS = {
  nickname = { source = "BattleMessage_BufferNickname", input = "battlerAndPartySlot", dependency = "partyBoxMon" },
  boxName = { source = "BattleMessage_BufferBoxName", input = "boxIndex", dependency = "saveStorage" },
  number = { source = "BattleMessage_BufferNumber", input = "integer" },
  numbers = { source = "BattleMessage_BufferNumbers", input = "integerAndDigitWidth" },
  poffin = { source = "BattleMessage_BufferPoffin", supported = false, reason = "unused-in-HGSS" },
}
BattlePresentationSources.MESSAGE_TEMPLATE_EXPANSION = {
  source = "BattleMessage_ExpandPlaceholders",
  input = "tagSelectedBuffers",
}
BattlePresentationSources.MESSAGE_RECORDS = {
  ["tutorial/author/male-player"] = { bank = "tutorialAuthor", messageId = 1 },
  ["tutorial/author/female-player"] = { bank = "tutorialAuthor", messageId = 0 },
  ["battle/narration/wild-appeared"] = { bank = "scriptController", messageId = 965 },
  ["battle/narration/trainer-challenged"] = { bank = "scriptController", messageId = 969 },
  ["battle/narration/player-sent-out"] = { bank = "scriptController", messageId = 979 },
  ["battle/narration/trainer-withdrew"] = { bank = "scriptController", messageId = 989 },
  ["battle/narration/trainer-sent-out"] = { bank = "scriptController", messageId = 972 },
  ["battle/narration/player-withdrew/switch-out"] = { bank = "scriptController", messageId = 984 },
  ["battle/narration/player-withdrew/come-back"] = { bank = "scriptController", messageId = 985 },
  ["battle/narration/player-withdrew/ok"] = { bank = "scriptController", messageId = 986 },
  ["battle/narration/player-withdrew/enough"] = { bank = "scriptController", messageId = 987 },
  ["battle/narration/player-withdrew/good"] = { bank = "scriptController", messageId = 988 },
  ["battle/narration/trainer-used-item"] = { bank = "scriptController", messageId = 858 },
  ["battle/narration/throw-ball"] = { bank = "scriptController", messageId = 857 },
  ["battle/narration/ball-blocked"] = { bank = "scriptController", messageId = 859 },
  ["battle/narration/no-stealing"] = { bank = "scriptController", messageId = 860 },
  ["battle/child/party-title"] = { bank = "partyResult", messageId = 6 },
  ["battle/child/target-title"] = { bank = "partyResult", messageId = 7 },
  ["battle/child/move-prompt"] = { bank = "partyResult", messageId = 94 },
  ["battle/child/command-prompt"] = { bank = "scriptController", messageId = 921 },
  ["battle/child/learn-prompt"] = { bank = "scriptController", messageId = 1183 },
  ["battle/narration/trainer-victory"] = { bank = "scriptController", messageId = 839 },
  ["battle/narration/won-money"] = { bank = "scriptController", messageId = 33 },
  ["battle/narration/defeated-last-mon"] = { bank = "scriptController", messageId = 36 },
  ["battle/narration/wild-lost-money"] = { bank = "scriptController", messageId = 34 },
  ["battle/narration/trainer-lost-money"] = { bank = "scriptController", messageId = 35 },
  ["battle/narration/player-blacked-out"] = { bank = "scriptController", messageId = 37 },
  ["battle/narration/ellipsis"] = { bank = "scriptController", messageId = 38 },
  ["battle/narration/got-away"] = { bank = "scriptController", messageId = 781 },
  ["battle/narration/fled-with-item"] = { bank = "scriptController", messageId = 782 },
  ["battle/narration/fled-run-away"] = { bank = "scriptController", messageId = 783 },
  ["battle/narration/cannot-escape"] = { bank = "scriptController", messageId = 42 },
  ["battle/narration/player-sent-out/foe-weak"] = { bank = "scriptController", messageId = 982 },
  ["battle/narration/player-sent-out/foe-hurt"] = { bank = "scriptController", messageId = 983 },
  ["battle/narration/player-sent-out/go-for-it"] = { bank = "scriptController", messageId = 981 },
  ["battle/narration/player-sent-out/in-charge"] = { bank = "scriptController", messageId = 980 },
  ["battle/narration/critical-hit"] = { bank = "scriptController", messageId = 774 },
  ["battle/narration/recoil/own"] = { bank = "scriptController", messageId = 279 },
  ["battle/narration/recoil/wild"] = { bank = "scriptController", messageId = 280 },
  ["battle/narration/recoil/foe"] = { bank = "scriptController", messageId = 281 },
  ["battle/narration/drained/own"] = { bank = "scriptController", messageId = 82 },
  ["battle/narration/drained/wild"] = { bank = "scriptController", messageId = 83 },
  ["battle/narration/drained/foe"] = { bank = "scriptController", messageId = 84 },
  ["battle/narration/multi-hit"] = { bank = "scriptController", messageId = 46 },
  ["battle/narration/move-failed"] = { bank = "scriptController", messageId = 796 },
  ["battle/narration/super-effective"] = { bank = "scriptController", messageId = 780 },
  ["battle/narration/not-very-effective"] = { bank = "scriptController", messageId = 779 },
  ["battle/narration/fainted/own"] = { bank = "scriptController", messageId = 30 },
  ["battle/narration/fainted/wild"] = { bank = "scriptController", messageId = 31 },
  ["battle/narration/fainted/foe"] = { bank = "scriptController", messageId = 32 },
  ["battle/narration/missed/own"] = { bank = "scriptController", messageId = 12 },
  ["battle/narration/missed/wild"] = { bank = "scriptController", messageId = 13 },
  ["battle/narration/missed/foe"] = { bank = "scriptController", messageId = 14 },
  ["battle/narration/avoided/own"] = { bank = "scriptController", messageId = 24 },
  ["battle/narration/avoided/wild"] = { bank = "scriptController", messageId = 25 },
  ["battle/narration/avoided/foe"] = { bank = "scriptController", messageId = 26 },
  ["battle/narration/immune/own"] = { bank = "scriptController", messageId = 27 },
  ["battle/narration/immune/wild"] = { bank = "scriptController", messageId = 28 },
  ["battle/narration/immune/foe"] = { bank = "scriptController", messageId = 29 },
  ["battle/narration/protected/own"] = { bank = "scriptController", messageId = 15 },
  ["battle/narration/protected/wild"] = { bank = "scriptController", messageId = 16 },
  ["battle/narration/protected/foe"] = { bank = "scriptController", messageId = 17 },
  ["battle/narration/experience"] = { bank = "scriptController", messageId = 1 },
  ["battle/narration/experience/boosted"] = { bank = "scriptController", messageId = 2 },
  ["battle/narration/level-up"] = { bank = "scriptController", messageId = 3 },
  ["battle/level-up/stat-name"] = { bank = "scriptController", messageId = 947 },
  ["battle/level-up/stat-delta"] = { bank = "scriptController", messageId = 948 },
  ["battle/level-up/stat-total"] = { bank = "scriptController", messageId = 949 },
  ["battle/narration/learn-move"] = { bank = "scriptController", messageId = 4 },
  ["battle/narration/gotcha"] = { bank = "scriptController", messageId = 867 },
  ["battle/narration/caught-nickname-question"] = { bank = "scriptController", messageId = 868 },
  ["battle/narration/bag-used-item"] = { bank = "scriptController", messageId = 1206 },
  ["battle/narration/bag-stat-up"] = { bank = "scriptController", messageId = 1203 },
  ["battle/narration/bag-woke-up"] = { bank = "scriptController", messageId = 1210 },
  ["battle/narration/bag-cured-poison"] = { bank = "scriptController", messageId = 1207 },
  ["battle/narration/bag-cured-paralysis"] = { bank = "scriptController", messageId = 1208 },
  ["battle/narration/bag-healed-burn"] = { bank = "scriptController", messageId = 1209 },
  ["battle/narration/bag-thawed"] = { bank = "scriptController", messageId = 1211 },
  ["battle/narration/bag-snapped-out"] = { bank = "scriptController", messageId = 1212 },
  ["battle/narration/bag-restored-hp"] = { bank = "scriptController", messageId = 1214 },
  ["battle/narration/bag-guard-spec"] = { bank = "scriptController", messageId = 1204 },
  ["battle/narration/bag-getting-pumped"] = { bank = "scriptController", messageId = 1205 },
  ["battle/narration/item-could-not-be-used"] = { bank = "scriptController", messageId = 593 },
  ["battle/narration/item-no-effect"] = { bank = "itemFeedback", messageId = 34 },
  ["battle/narration/pp-restored"] = { bank = "partyResult", messageId = 87 },
  ["battle/narration/transformed"] = { bank = "scriptController", messageId = 345 },
  ["battle/narration/foretold/own"] = { bank = "scriptController", messageId = 472 },
  ["battle/narration/foretold/wild"] = { bank = "scriptController", messageId = 473 },
  ["battle/narration/foretold/foe"] = { bank = "scriptController", messageId = 474 },
  ["battle/narration/did-not-learn"] = { bank = "scriptController", messageId = 10 },
  ["battle/narration/charged/own"] = { bank = "scriptController", messageId = 487 },
  ["battle/narration/charged/wild"] = { bank = "scriptController", messageId = 488 },
  ["battle/narration/charged/foe"] = { bank = "scriptController", messageId = 489 },
  ["battle/narration/substitute-broke/own"] = { bank = "scriptController", messageId = 357 },
  ["battle/narration/substitute-broke/wild"] = { bank = "scriptController", messageId = 358 },
  ["battle/narration/substitute-broke/foe"] = { bank = "scriptController", messageId = 359 },
  ["battle/narration/sketched/own"] = { bank = "scriptController", messageId = 385 },
  ["battle/narration/sketched/wild"] = { bank = "scriptController", messageId = 386 },
  ["battle/narration/sketched/foe"] = { bank = "scriptController", messageId = 387 },
  ["battle/narration/bide-release"] = { bank = "scriptController", messageId = 335 },
  ["battle/narration/bide-release/wild"] = { bank = "scriptController", messageId = 336 },
  ["battle/narration/bide-release/foe"] = { bank = "scriptController", messageId = 337 },
}
local STATUS_VARIANT_RECORDS = {
  sleep = { own = 47, wild = 48, foe = 49 },
  poison = { own = 63, wild = 64, foe = 65 },
  toxic = { own = 79, wild = 80, foe = 81 },
  burn = { own = 85, wild = 86, foe = 87 },
  freeze = { own = 101, wild = 102, foe = 103 },
  paralysis = { own = 120, wild = 121, foe = 122 },
  confusion = { own = 156, wild = 157, foe = 158 },
}
for status, variants in pairs(STATUS_VARIANT_RECORDS) do
  for side, messageId in pairs(variants) do
    BattlePresentationSources.MESSAGE_RECORDS["battle/narration/status/" .. status .. "/" .. side] = {
      bank = "scriptController",
      messageId = messageId,
    }
  end
end
local RESIDUAL_VARIANT_RECORDS = {
  poison = { own = 73, wild = 74, foe = 75 },
  toxic = { own = 73, wild = 74, foe = 75 },
  burn = { own = 95, wild = 96, foe = 97 },
}
for condition, variants in pairs(RESIDUAL_VARIANT_RECORDS) do
  for side, messageId in pairs(variants) do
    BattlePresentationSources.MESSAGE_RECORDS["battle/narration/residual/" .. condition .. "/" .. side] = {
      bank = "scriptController",
      messageId = messageId,
    }
  end
end
local STATUS_GATE_RECORDS = {
  ["asleep/own"] = 299,
  ["asleep/wild"] = 300,
  ["asleep/foe"] = 301,
  ["paralysis/wild"] = 131,
  ["paralysis/foe"] = 132,
  ["paralysis/own"] = 130,
  ["freeze/wild"] = 112,
  ["freeze/foe"] = 113,
  ["freeze/own"] = 111,
  ["woke/own"] = 302,
  ["woke/wild"] = 303,
  ["woke/foe"] = 304,
  ["thawed/own"] = 114,
  ["thawed/wild"] = 115,
  ["thawed/foe"] = 116,
}
for route, messageId in pairs(STATUS_GATE_RECORDS) do
  BattlePresentationSources.MESSAGE_RECORDS["battle/narration/status-gate/" .. route] = {
    bank = "scriptController",
    messageId = messageId,
  }
end
local CURED_RECORDS = {
  ["thawed/own"] = 114,
  ["thawed/wild"] = 115,
  ["thawed/foe"] = 116,
  ["paralysis-healed/own"] = 136,
  ["paralysis-healed/wild"] = 137,
  ["paralysis-healed/foe"] = 138,
  ["confusion-cured/own"] = 153,
  ["confusion-cured/wild"] = 154,
  ["confusion-cured/foe"] = 155,
}
for route, messageId in pairs(CURED_RECORDS) do
  BattlePresentationSources.MESSAGE_RECORDS["battle/narration/cured/" .. route] = {
    bank = "scriptController",
    messageId = messageId,
  }
end
for classId, classKey in pairs(BattleSources.trainerClassKeys) do
  BattlePresentationSources.MESSAGE_RECORDS["battle/trainer-class/" .. classKey] = {
    bank = "trainerClassPlaceholder",
    messageId = classId,
  }
end
local ATTACK_MESSAGE_OFFSETS = { own = 0, wild = 1, foe = 2 }
for moveId, moveKey in pairs(MonSources.moveKeys) do
  if moveId > 0 then
    for side, offset in pairs(ATTACK_MESSAGE_OFFSETS) do
      BattlePresentationSources.MESSAGE_RECORDS["battle/move-use/" .. moveKey .. "/" .. side] = {
        bank = "attackMessage",
        messageId = moveId * 3 + offset,
      }
    end
  end
end
local STAT_PLACEHOLDER_IDS = {
  hp = 0,
  attack = 1,
  defense = 2,
  speed = 3,
  specialAttack = 4,
  specialDefense = 5,
  accuracy = 6,
  evasion = 7,
}
for statKey, statId in pairs(STAT_PLACEHOLDER_IDS) do
  BattlePresentationSources.MESSAGE_RECORDS["battle/stat/" .. statKey] = {
    bank = "statPlaceholder",
    messageId = statId,
  }
end
local STAGE_MESSAGE_IDS = {
  ["up/normal"] = { own = 750, wild = 751, foe = 752 },
  ["up/sharp"] = { own = 753, wild = 754, foe = 755 },
  ["down/normal"] = { own = 762, wild = 763, foe = 764 },
  ["down/harsh"] = { own = 765, wild = 766, foe = 767 },
  ["max-up"] = { own = 142, wild = 143, foe = 144 },
  ["max-down"] = { own = 145, wild = 146, foe = 147 },
}
for action, variants in pairs(STAGE_MESSAGE_IDS) do
  for side, messageId in pairs(variants) do
    BattlePresentationSources.MESSAGE_RECORDS["battle/narration/stage/" .. action .. "/" .. side] = {
      bank = "scriptController",
      messageId = messageId,
    }
  end
end
local ITEM_STAGE_MESSAGE_IDS = {
  normal = { own = 756, wild = 757, foe = 758 },
  sharp = { own = 759, wild = 760, foe = 761 },
}
for strength, variants in pairs(ITEM_STAGE_MESSAGE_IDS) do
  for side, messageId in pairs(variants) do
    BattlePresentationSources.MESSAGE_RECORDS["battle/narration/trainer-stat-raised/" .. strength .. "/" .. side] = {
      bank = "scriptController",
      messageId = messageId,
    }
  end
end
-- Front trainer portraits follow GetTrainerPicFileIds with battlerPosition
-- 2 in pokemon.c. Keep the physical member formula here; published keys
-- are trainer:<semantic class key> and never expose class/member numbers.
BattlePresentationSources.TRAINER_PICTURES = {
  source = {
    file = "src/pokemon.c",
    symbol = "GetTrainerPicFileIds",
  },
  backpicSource = {
    file = "src/pokemon.c",
    symbol = "TrainerClassToBackpicID",
  },
  frontArchive = "NARC_a_0_5_8",
  backArchive = "NARC_a_0_0_6",
  frontClasses = BattleSources.trainerClassKeys,
  backClasses = { PKMN_TRAINER_ETHAN = 0, PKMN_TRAINER_LYRA = 1 },
  throwOffsets = {
    source = { file = "asm/battle_controller_opponent_data.s", symbol = "gBallThrowOffsets" },
    [0] = {
      { x = 0, y = 128 },
      { x = -34, y = 4 },
      { x = -28, y = -11 },
      { x = 50, y = -12 },
      { x = 32767, y = 32767 },
      { x = 32767, y = 32767 },
    },
    [1] = {
      { x = 0, y = 128 },
      { x = -34, y = 4 },
      { x = -28, y = -11 },
      { x = 50, y = -12 },
      { x = 50, y = -12 },
      { x = 32767, y = 32767 },
    },
  },
  membersPerClass = 5,
  memberOffsets = { character = 0, palette = 1, cell = 2, animation = 3, auxiliary = 4 },
  outputPrefix = "trainer:",
}
BattlePresentationSources.MENU_MESSAGES = {
  ["battle/bide-release"] = 335,
  ["battle/bide-release/wild"] = 336,
  ["battle/bide-release/foe"] = 337,
  ["battle/capture-shakes/0"] = 863,
  ["battle/capture-shakes/1"] = 864,
  ["battle/capture-shakes/2"] = 865,
  ["battle/capture-shakes/3"] = 866,
  ["battle/capture-shakes/4"] = 867,
  ["battle/pc-transfer/has-space/someone"] = 1174,
  ["battle/pc-transfer/has-space/bill"] = 1175,
  ["battle/pc-transfer/box-full/someone"] = 1176,
  ["battle/pc-transfer/box-full/bill"] = 1177,
  ["label/fight"] = 924,
  ["label/bag"] = 925,
  ["label/pokemon"] = 926,
  ["label/run"] = 927,
  ["label/cancel"] = 928,
  ["label/target-cancel"] = 929,
  ["label/party-cancel"] = 930,
  ["label/safari-ball"] = 931,
  ["label/safari-bait"] = 932,
  ["label/safari-mud"] = 933,
  ["label/pp"] = 937,
  ["label/pp-max"] = 938,
  ["label/yes"] = 940,
  ["label/no"] = 941,
  ["label/target-gender-male"] = 962,
  ["label/target-gender-female"] = 963,
  ["label/target-gender-unknown"] = 964,
  ["template/mon-male-level"] = 944,
  ["template/mon-female-level"] = 945,
  ["template/mon-neutral-level"] = 946,
  ["label/pal-park-ball"] = 1223,
  ["label/recorder-stop"] = 1260,
  ["status/recorder-0"] = 1261,
  ["status/recorder-1"] = 1262,
  ["status/recorder-2"] = 1263,
  ["status/recorder-3"] = 1264,
  ["status/recorder-4"] = 1265,
  ["status/recorder-5"] = 1266,
  ["label/bug-contest-ball"] = 1270,
  ["template/bug-contest-remaining-balls"] = 1271,
  ["label/forget-move"] = 1181,
  ["label/keep-move"] = 1182,
  ["prompt/give-up"] = 1186,
  ["prompt/keep-battling"] = 1187,
  ["label/safari-balls"] = 950,
  ["status/safari-balls-remaining"] = 951,
  ["label/switch"] = 1215,
  ["label/keep-battling-switch"] = 1216,
  ["label/flee"] = 1217,
  ["label/switch-flee"] = 1218,
  ["label/pal-park-balls"] = 1220,
  ["status/pal-park-balls-remaining"] = 1221,
  ["label/bug-contest-gender-male"] = 1272,
  ["label/bug-contest-gender-female"] = 1273,
  ["template/bug-contest-level"] = 1274,
}

-- Message choices whose branches are source-visible at battle-menu callsites.
-- Message IDs stay here as producer inputs; the compiler emits only semantic
-- keys and placeholder requirements.
BattlePresentationSources.MENU_MODE_RULES = {
  standard = {
    labels = { fight = "label/fight", bag = "label/bag", pokemon = "label/pokemon" },
    dynamicFields = {},
  },
  safari = {
    labels = { fight = "label/safari-ball", bag = "label/safari-bait", pokemon = "label/safari-mud" },
    dynamicFields = {},
  },
  ["pal-park"] = {
    labels = { fight = "label/pal-park-ball", bag = "label/safari-bait", pokemon = "label/safari-mud" },
    dynamicFields = {},
  },
  ["bug-contest"] = {
    labels = { fight = "label/fight", bag = "label/bug-contest-ball", pokemon = "label/pokemon" },
    dynamicFields = { "caughtPokemonGender", "caughtPokemonLevel", "remainingBalls" },
  },
}

BattlePresentationSources.MENU_MESSAGE_ROUTES = {
  ["menu/bug-contest-level"] = {
    template = "template/bug-contest-level",
    inputs = { "caughtPokemonLevel" },
  },
  ["menu/bug-contest-caught-gender"] = {
    variants = { "label/bug-contest-gender-male", "label/bug-contest-gender-female" },
    inputs = { "caughtPokemonGender" },
  },
  ["menu/bug-contest-remaining-balls"] = {
    template = "template/bug-contest-remaining-balls",
    inputs = { "remainingBalls" },
  },
  ["menu/give-up-move"] = {
    templates = { "prompt/give-up", "prompt/keep-battling" },
    inputs = { "moveName" },
  },
  ["menu/vs-recorder-feedback"] = {
    variants = {
      "status/recorder-0",
      "status/recorder-1",
      "status/recorder-2",
      "status/recorder-3",
    },
    inputs = { "playbackStatus" },
    branches = {
      paused = { "status/recorder-0", "status/recorder-1" },
      corrupted = { "status/recorder-2", "status/recorder-3" },
    },
  },
}

-- Battle menu renderers consume these values from live battle state. Their
-- referenced icon and type visuals are owned by the mon and bag catalogs.
BattlePresentationSources.MENU_RUNTIME_CONTEXTS = {
  bugContest = {
    inputs = {
      "caughtPokemonSpecies",
      "caughtPokemonForm",
      "caughtPokemonGender",
      "caughtPokemonLevel",
      "remainingSafariBalls",
    },
    assetRoles = { "pokemonIcon" },
  },
  targetSelection = {
    inputs = {
      "targetCandidates",
      "selectedTarget",
      "targetHitMask",
      "nickname",
      "gender",
      "species",
      "form",
      "hpCondition",
      "statusAnimation",
    },
    assetRoles = { "pokemonIcon", "battleCondition" },
  },
  moveSelection = {
    inputs = { "moveIds", "currentPP", "maximumPP" },
    assetRoles = { "moveTypeIcon" },
  },
  frontierLayout = {
    inputs = { "frontierBattle" },
    assetRoles = { "frontierMenuLayout" },
  },
}

-- Typed semantic inputs read by the pinned battle-menu constructors and
-- their direct callers. These records complement the compact runtime index:
-- they preserve the source data needed to render dynamic rows without
-- exposing NARC identities or packed battle flags.
BattlePresentationSources.MENU_CONTEXTS = {
  main = {
    inputs = {
      mode = { type = "enum", values = { "standard", "safari", "pal-park", "bug-contest" } },
      cancelRun = { type = "boolean" },
      frontier = { type = "boolean" },
    },
    modes = { "standard", "safari", "pal-park", "bug-contest" },
  },
  bugContest = {
    caughtPokemon = {
      optional = true,
      fields = {
        species = "species",
        form = "form",
        gender = { type = "enum", values = { "male", "female", "genderless" } },
        level = "integer",
      },
      absentSpecies = "species/none",
    },
    remainingSafariBalls = "integer",
    sprites = "bugContest",
  },
  frontier = {
    input = "isFrontier",
    predicate = "BattleSystem_IsInFrontier",
    overrides = "frontier",
  },
  moveSelection = {
    slotCount = 4,
    slots = {
      move = "move",
      currentPP = "integer",
      maximumPP = "integer",
      derived = { moveName = "move-name", moveType = "move-type", typeIcon = "move-type-icon" },
      emptyMove = "move/none",
    },
  },
  targetSelection = {
    slotCount = 4,
    order = "targetOrder",
    hitMask = "targetHitMask",
    visibility = { candidateFlag = "hide", requiredValue = true, hitRequired = true },
    candidate = {
      battler = "battler",
      gender = "gender",
      selectedPartyMon = "party-index",
      hp = "integer",
      maximumHP = "integer",
      status = "battle-status",
      nickname = "box-mon-nickname",
      species = "species",
      form = "form",
    },
    iconAssetRoles = { "pokemonIcon", "battleCondition" },
  },
  vsRecorder = {
    sourceSelector = 18,
    inputs = { playbackStatus = { type = "enum", values = { "paused", "corrupted" } } },
    screenRole = "vsRecorder",
    stopMessage = "label/recorder-stop",
    feedbackRoute = "menu/vs-recorder-feedback",
  },
}

-- BattleInput_PrintSystemMessage accepts an index from ov12_0223BFFC.
-- Pinned callers pass 0 for recorder pause and 1 for an invalid recorded
-- action/exit path. Index 2 (battle too long) has no pinned caller.
BattlePresentationSources.RECORDER_FEEDBACK_SOURCE_FLAGS = { [0] = "paused", [1] = "corrupted" }
BattlePresentationSources.RECORDER_FEEDBACK_UNREACHABLE_FLAGS = { [2] = "battleTooLong" }

---@param sourceFlag integer source-only BattleInput_PrintSystemMessage index
---@return string|nil semantic feedback route
function BattlePresentationSources.recorderFeedbackRoute(sourceFlag)
  return BattlePresentationSources.RECORDER_FEEDBACK_SOURCE_FLAGS[sourceFlag]
end

local TRANSITION_TERRAIN_KEYS = {
  plain = true,
  sand = true,
  grass = true,
  puddle = true,
  mountain = true,
  cave = true,
  snow = true,
  water = true,
  ice = true,
  building = true,
  great_marsh = true,
  unknown = true,
  will = true,
  koga = true,
  bruno = true,
  karen = true,
  lance = true,
  distortion_world = true,
  battle_tower = true,
  battle_factory = true,
  battle_arcade = true,
  battle_castle = true,
  battle_hall = true,
  giratina = true,
}

local TRANSITION_TIME_KEYS = { morning = true, day = true, evening = true, night = true, late = true }

---@param mode "standard"|"safari"|"pal-park"|"bug-contest"
---@param isFrontier boolean
---@param cancelRun boolean
---@return { key: string, layoutVariant: string, labels: table<string, string>, dynamicFields: string[] }
function BattlePresentationSources.menuDisplay(mode, isFrontier, cancelRun)
  local sourceRule = assert(BattlePresentationSources.MENU_MODE_RULES[mode], "menu mode is source-defined")
  assert(type(isFrontier) == "boolean", "Frontier state is explicit")
  assert(type(cancelRun) == "boolean", "cancel/run display state is explicit")
  local labels = {}
  for key, messageKey in pairs(sourceRule.labels) do
    labels[key] = messageKey
  end
  labels.run = cancelRun and "label/cancel" or "label/run"
  local dynamicFields = {}
  for index, field in ipairs(sourceRule.dynamicFields) do
    dynamicFields[index] = field
  end
  return {
    key = "menu/main/" .. mode,
    layoutVariant = isFrontier and "frontier" or "standard",
    labels = labels,
    dynamicFields = dynamicFields,
  }
end

-- The fallback formula is source logic from ov01_021F0D20. These inputs
-- choose a native table selector; callers keep that integer in provenance.
BattlePresentationSources.TRANSITION_FALLBACK = {
  terrainOffset = { cave = 4, water = 2 },
  offsetTimes = { "night", "late" },
  trainerOffset = 6,
}

---@param terrain string semantic source terrain
---@param timeOfDay string source time of day
---@param isTrainer boolean trainer battle bit
---@return integer|nil native fallback selector; nil for an unknown source axis
function BattlePresentationSources.transitionFallbackSelector(terrain, timeOfDay, isTrainer)
  if TRANSITION_TERRAIN_KEYS[terrain] ~= true or TRANSITION_TIME_KEYS[timeOfDay] ~= true then
    return nil
  end
  if type(isTrainer) ~= "boolean" then
    return nil
  end
  local selector = BattlePresentationSources.TRANSITION_FALLBACK.terrainOffset[terrain] or 0
  if timeOfDay == "night" or timeOfDay == "late" then
    selector = selector + 1
  end
  if isTrainer then
    selector = selector + BattlePresentationSources.TRANSITION_FALLBACK.trainerOffset
  end
  return selector
end

-- The source initializes four SUB BG layers at the origin. Menu payloads use
-- 32x32 tile maps; the visible touch surface is 256x192.
BattlePresentationSources.MENU_LAYOUT = {
  width = 256,
  height = 192,
  tilemapWidth = 32,
  tilemapHeight = 32,
  layers = {
    { key = "menu/background-0", index = 0, x = 0, y = 0 },
    { key = "menu/background-1", index = 1, x = 0, y = 0 },
    { key = "menu/background-2", index = 2, x = 0, y = 0 },
    { key = "menu/background-3", index = 3, x = 0, y = 0 },
  },
}

-- Shared lower-screen backdrop member whose bank-zero color 1 pulses while
-- the battle command touch menu is open.
BattlePresentationSources.MENU_PULSE_SCREEN = 43

-- Button feedback is applied to the selected source screen buffer by
-- battle_input.c::ov12_02268EE4. Rectangles are inclusive 8x8 tile bounds;
-- offsets are raw 16-bit screen-entry increments for idle, selected, and
-- pressed feedback. The runtime receives only generated patch images.
BattlePresentationSources.MENU_FEEDBACK = {
  command = {
    screenIndex = 1,
    states = { selected = 192, pressed = 384 },
    buttons = {
      { id = "fight", left = 2, top = 4, right = 29, bottom = 15 },
      { id = "bag", left = 0, top = 17, right = 9, bottom = 23 },
      { id = "pokemon", left = 22, top = 17, right = 31, bottom = 23 },
      { id = "run", left = 11, top = 18, right = 20, bottom = 23 },
    },
  },
  moves = {
    screenIndex = 1,
    states = { selected = 192, pressed = 384 },
    buttons = {
      { id = "move:0", left = 0, top = 2, right = 15, bottom = 9 },
      { id = "move:1", left = 16, top = 2, right = 31, bottom = 9 },
      { id = "move:2", left = 0, top = 10, right = 15, bottom = 17 },
      { id = "move:3", left = 16, top = 10, right = 31, bottom = 17 },
      { id = "cancel", left = 1, top = 18, right = 30, bottom = 23 },
    },
  },
  target = {
    screenIndex = 1,
    states = { selected = 192, pressed = 384 },
    buttons = {
      { id = "target:0", left = 0, top = 10, right = 14, bottom = 17 },
      { id = "target:1", left = 17, top = 0, right = 31, bottom = 9 },
      { id = "target:2", left = 17, top = 10, right = 31, bottom = 17 },
      { id = "target:3", left = 0, top = 0, right = 14, bottom = 9 },
      { id = "cancel", left = 1, top = 18, right = 30, bottom = 23 },
    },
  },
  twoOption = {
    screenIndex = 1,
    states = { selected = 5, pressed = 10 },
    buttons = {
      { id = "yes", left = 0, top = 4, right = 31, bottom = 11 },
      { id = "cancel", left = 0, top = 13, right = 31, bottom = 20 },
    },
  },
}

-- Fight-menu move buttons (BattleInput_CreateFightMenuObjects): each move
-- loads its type palette (overlay_06.c sMoveTypePalettes, an 18-entry
-- pointer table discovered in ARM9 overlay 6) over lower palette bank
-- 8 + slot; the first empty slot onward copies the blank button tiles
-- (sEmptyMoveButtonsScreenOffsets over sEmptyMoveButtonsTouchscreenRect)
-- and loads lower bank 14 into the slot's bank.
BattlePresentationSources.MOVE_BUTTONS = {
  typePalettes = { cpu = "arm9", overlayId = 6, count = 18 },
  firstBank = 8,
  emptyBank = 14,
  empty = {
    { offset = 0x22F, left = 0, top = 3, right = 15, bottom = 9 },
    { offset = 0x22C, left = 16, top = 3, right = 31, bottom = 9 },
    { offset = 0x229, left = 0, top = 11, right = 15, bottom = 17 },
    { offset = 0x226, left = 16, top = 11, right = 31, bottom = 17 },
  },
}

-- Physical lower BG planes receiving each menu's screen buffers: the
-- sBattleMenuTemplates screenBufferIds slot is the plane BattleInput_ChangeMenu
-- loads (SUB_0 + slot). Order matches each ordinary menu's role members.
BattlePresentationSources.MENU_PLANES = {
  command = { 0, 1, 2 },
  moves = { 0, 2 },
  target = { 0, 1, 2 },
  twoOption = { 0, 2 },
}

-- NARC-109 loads whose complete resource-kind/member tuples are source-
-- confirmed by overlay_01_021EFB38.s and overlays 114/117. These tuples are
-- producer-only; runtime descriptors use semantic resource keys and hashes.
BattlePresentationSources.TRANSITION_ARCHIVE = "NARC_a_1_0_9"
BattlePresentationSources.TRANSITION_SELECTOR_FAMILIES = {}
local function assignTransitionFamily(first, last, family)
  for selector = first, last do
    BattlePresentationSources.TRANSITION_SELECTOR_FAMILIES[selector] = family
  end
end
assignTransitionFamily(0, 5, "overlay-120")
assignTransitionFamily(6, 11, "overlay-119")
assignTransitionFamily(12, 33, "overlay-115")
assignTransitionFamily(34, 36, "overlay-116")
assignTransitionFamily(37, 38, "overlay-114")
assignTransitionFamily(39, 44, "overlay-117")
assignTransitionFamily(45, 45, "overlay-118")
assignTransitionFamily(46, 46, "overlay-120")

-- Semantic edges before callback dispatch. The native table slot and class
-- ordinal are provenance; callers resolve these symbolic route keys.
BattlePresentationSources.TRANSITION_PRESELECTION = {
  trainerClasses = {
    LEADER_FALKNER = "trainer/falkner",
    LEADER_BUGSY = "trainer/bugsy",
    LEADER_WHITNEY = "trainer/whitney",
    LEADER_MORTY = "trainer/morty",
    LEADER_JASMINE = "trainer/jasmine",
    LEADER_CHUCK = "trainer/chuck",
    LEADER_PRYCE = "trainer/pryce",
    LEADER_CLAIR = "trainer/clair",
    LEADER_BROCK = "trainer/brock",
    LEADER_MISTY = "trainer/misty",
    LEADER_LT_SURGE = "trainer/lt-surge",
    LEADER_ERIKA = "trainer/erika",
    LEADER_JANINE = "trainer/janine",
    LEADER_SABRINA = "trainer/sabrina",
    LEADER_BLAINE = "trainer/blaine",
    LEADER_BLUE = "trainer/blue",
    ELITE_FOUR_WILL = "trainer/will",
    ELITE_FOUR_KOGA = "trainer/koga",
    ELITE_FOUR_BRUNO = "trainer/bruno",
    ELITE_FOUR_KAREN = "trainer/karen",
    CHAMPION = "trainer/lance",
    RIVAL = "trainer/rival-or-passerby",
    PASSERBY = "trainer/rival-or-passerby",
    EXECUTIVE_ARCHER = "trainer/archer",
    EXECUTIVE_ARIANA = "trainer/ariana",
    EXECUTIVE_PROTON = "trainer/proton",
    EXECUTIVE_PETREL = "trainer/petrel",
    ROCKET_BOSS = "trainer/rocket-boss",
    TEAM_ROCKET = "trainer/team-rocket",
    TEAM_ROCKET_F = "trainer/team-rocket",
    KIMONO_GIRL = "trainer/kimono-girl",
    PKMN_TRAINER_RED = "trainer/red",
  },
  wildSpecies = {
    RAIKOU = "wild/raikou",
    ENTEI = "wild/entei",
    SUICUNE = "wild/suicune",
    HO_OH = "wild/ho-oh",
    LUGIA = "wild/lugia",
    GROUDON = "wild/hoenn-legendary-trio",
    KYOGRE = "wild/hoenn-legendary-trio",
    RAYQUAZA = "wild/hoenn-legendary-trio",
    MEWTWO = "wild/kanto-legendary-trio",
    LATIOS = "wild/kanto-legendary-trio",
    LATIAS = "wild/kanto-legendary-trio",
  },
  callInputs = {
    trainerBit = 0x01,
    doublesBit = 0x02,
    specialBattleBit = 0x80,
    alternateTrainerTransitionBit = 0x04,
    wildSecondArgument = 0x6d,
    genericFrontierTrainerCategory = 39,
    fallbackCategories = { 22, 23, 24, 41, 42 },
    fallback = { terrain = { water = 2, cave = 4 }, lateOrNight = 1, trainer = 6 },
  },
  selectionRules = {
    trainer = {
      input = "trainerClass",
      specialBattleBit = 0x80,
      specialBattle = { preserveCategory = 39, doublesCategory = 37, defaultCategory = 35 },
      preserveCategories = { 29, 30, 31, 32, 33, 34, 43, 44 },
      doublesCategory = 37,
      alternateTransitionBit = 0x04,
      alternateCategory = 36,
      otherwise = "trainerCategory",
    },
    wild = {
      input = "firstLivingPokemonSpecies",
      fallbackWhenSecondArgumentEquals = 0x6d,
      fallbackCategory = 42,
      doublesCategoryWhenCategoryAtLeast = { threshold = 42, category = 38 },
      otherwise = "wildSpeciesCategory",
    },
  },
  trainerCategoryByKey = {
    ["trainer/falkner"] = 0,
    ["trainer/bugsy"] = 1,
    ["trainer/whitney"] = 2,
    ["trainer/morty"] = 3,
    ["trainer/jasmine"] = 4,
    ["trainer/chuck"] = 5,
    ["trainer/pryce"] = 6,
    ["trainer/clair"] = 7,
    ["trainer/brock"] = 8,
    ["trainer/misty"] = 9,
    ["trainer/lt-surge"] = 10,
    ["trainer/erika"] = 11,
    ["trainer/janine"] = 12,
    ["trainer/sabrina"] = 13,
    ["trainer/blaine"] = 14,
    ["trainer/blue"] = 15,
    ["trainer/will"] = 16,
    ["trainer/koga"] = 17,
    ["trainer/bruno"] = 18,
    ["trainer/karen"] = 19,
    ["trainer/lance"] = 20,
    ["trainer/rival-or-passerby"] = 21,
    ["trainer/team-rocket"] = 29,
    ["trainer/petrel"] = 30,
    ["trainer/proton"] = 31,
    ["trainer/archer"] = 32,
    ["trainer/ariana"] = 33,
    ["trainer/rocket-boss"] = 34,
    ["trainer/kimono-girl"] = 43,
    ["trainer/red"] = 44,
  },
  wildCategoryByKey = {
    ["wild/raikou"] = 22,
    ["wild/entei"] = 23,
    ["wild/suicune"] = 24,
    ["wild/ho-oh"] = 25,
    ["wild/lugia"] = 26,
    ["wild/hoenn-legendary-trio"] = 27,
    ["wild/kanto-legendary-trio"] = 28,
  },
  categoryRoutes = {
    [0] = "trainer/falkner",
    [1] = "trainer/bugsy",
    [2] = "trainer/whitney",
    [3] = "trainer/morty",
    [4] = "trainer/jasmine",
    [5] = "trainer/chuck",
    [6] = "trainer/pryce",
    [7] = "trainer/clair",
    [8] = "trainer/brock",
    [9] = "trainer/misty",
    [10] = "trainer/lt-surge",
    [11] = "trainer/erika",
    [12] = "trainer/janine",
    [13] = "trainer/sabrina",
    [14] = "trainer/blaine",
    [15] = "trainer/blue",
    [16] = "trainer/will",
    [17] = "trainer/koga",
    [18] = "trainer/bruno",
    [19] = "trainer/karen",
    [20] = "trainer/lance",
    [21] = "trainer/rival-or-passerby",
    [22] = { fallback = true },
    [23] = { fallback = true },
    [24] = { fallback = true },
    [25] = "wild/ho-oh",
    [26] = "wild/lugia",
    [27] = "wild/special-legendary",
    [28] = "wild/special-legendary",
    [29] = "trainer/team-rocket",
    [30] = "trainer/petrel",
    [31] = "trainer/proton",
    [32] = "trainer/archer",
    [33] = "trainer/ariana",
    [34] = "trainer/rocket-boss",
    [35] = "trainer/generic",
    [36] = "trainer/generic",
    [37] = "wild/generic",
    [38] = "wild/generic",
    [39] = "trainer/generic",
    [40] = "wild/generic",
    [41] = { fallback = true },
    [42] = { fallback = true },
    [43] = "trainer/kimono-girl",
    [44] = "trainer/red",
  },
}

-- Transition selector roles retain the caller context and payload branches
-- proven by the pinned callback table and overlay consumers. These are build
-- inputs; runtime descriptors use semantic transition keys.
BattlePresentationSources.TRANSITION_SELECTOR_ROUTES = {}
local function addTransitionRoute(selector, route)
  route.family = BattlePresentationSources.TRANSITION_SELECTOR_FAMILIES[selector]
  BattlePresentationSources.TRANSITION_SELECTOR_ROUTES[selector] = route
end

local fallbackRoles = {
  [0] = "plain-wild-fallback",
  [1] = "plain-wild-fallback",
  [2] = "water-wild-fallback",
  [3] = "water-wild-fallback",
  [4] = "cave-wild-fallback",
  [5] = "cave-wild-fallback",
  [6] = "plain-trainer-fallback",
  [7] = "plain-trainer-fallback",
  [8] = "water-trainer-fallback",
  [9] = "water-trainer-fallback",
  [10] = "cave-trainer-fallback",
  [11] = "cave-trainer-fallback",
}
local fallbackContexts = {
  [0] = { terrain = "plain", timeOfDay = "day", isTrainer = false },
  [1] = { terrain = "plain", timeOfDay = "late", isTrainer = false },
  [2] = { terrain = "water", timeOfDay = "day", isTrainer = false },
  [3] = { terrain = "water", timeOfDay = "late", isTrainer = false },
  [4] = { terrain = "cave", timeOfDay = "day", isTrainer = false },
  [5] = { terrain = "cave", timeOfDay = "late", isTrainer = false },
  [6] = { terrain = "plain", timeOfDay = "day", isTrainer = true },
  [7] = { terrain = "plain", timeOfDay = "late", isTrainer = true },
  [8] = { terrain = "water", timeOfDay = "day", isTrainer = true },
  [9] = { terrain = "water", timeOfDay = "late", isTrainer = true },
  [10] = { terrain = "cave", timeOfDay = "day", isTrainer = true },
  [11] = { terrain = "cave", timeOfDay = "late", isTrainer = true },
}

-- EncounterEffectCellGrid order data from
-- pokeheartgold/asm/encounter_effect_wild_data.s.
BattlePresentationSources.WILD_CELL_GRID_ORDERS = {
  rows = {
    7,
    6,
    5,
    4,
    3,
    2,
    1,
    0,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    23,
    22,
    21,
    20,
    19,
    18,
    17,
    16,
  },
  rowsReverse = {
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    15,
    14,
    13,
    12,
    11,
    10,
    9,
    8,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
  },
  diagonalsA = {
    0,
    2,
    9,
    16,
    4,
    11,
    18,
    25,
    32,
    6,
    13,
    20,
    27,
    34,
    41,
    15,
    22,
    29,
    36,
    43,
    31,
    38,
    45,
    47,
  },
  diagonalsB = {
    1,
    8,
    3,
    10,
    17,
    24,
    5,
    12,
    19,
    26,
    33,
    40,
    7,
    14,
    21,
    28,
    35,
    42,
    23,
    30,
    37,
    44,
    39,
    46,
  },
}

for selector = 0, 11 do
  local context = fallbackContexts[selector]
  local route = {
    key = string.format(
      "fallback/%s/%s/%s",
      context.terrain,
      context.timeOfDay,
      context.isTrainer and "trainer" or "wild"
    ),
    role = fallbackRoles[selector],
    context = context,
  }
  if selector <= 5 then
    route.sceneAssets = {
      palette = 0xa0,
      characters = { 0xa1, 0xa4 },
      maps = { 0xa2, 0xa5 },
      transitionBackground = { palette = 0xa6, character = 0xa7, map = 0xa8 },
    }
    if selector <= 5 then
      route.wildCellOrders = "wild-cell-orders"
    end
  elseif selector == 6 or selector == 8 or selector >= 10 then
    route.sprite = { palette = 1, character = 4, cell = 6, animation = 5 }
  elseif selector == 7 then
    route.sprite = { palette = 1, character = 7, cell = 9, animation = 8 }
  end
  if selector == 9 then
    route.sprite = { palette = 1, character = 7, cell = 9, animation = 8 }
  end
  addTransitionRoute(selector, route)
end

local standardTrainerRecordIds = {
  0x3f,
  0x43,
  0x47,
  0x4b,
  0x4f,
  0x53,
  0x57,
  0x5b,
  0x5f,
  0x63,
  0x67,
  0x6b,
  0x6f,
  0x73,
  0x77,
  0x7b,
}
local gymLeaderBackgrounds = {
  { 21, 20, 22 },
  { 24, 23, 25 },
  { 27, 26, 28 },
  { 30, 29, 31 },
  { 33, 32, 34 },
  { 36, 35, 37 },
  { 39, 38, 40 },
  { 42, 41, 43 },
  { 21, 20, 22 },
  { 24, 23, 25 },
  { 27, 26, 28 },
  { 30, 29, 31 },
  { 33, 32, 34 },
  { 36, 35, 37 },
  { 39, 38, 40 },
  { 42, 41, 43 },
  { 45, 44, 46 },
}
for selector = 12, 27 do
  local member = standardTrainerRecordIds[selector - 11]
  local trainerKeys = {
    "falkner",
    "bugsy",
    "whitney",
    "morty",
    "jasmine",
    "chuck",
    "pryce",
    "clair",
    "brock",
    "misty",
    "lt-surge",
    "erika",
    "janine",
    "sabrina",
    "blaine",
    "blue",
  }
  addTransitionRoute(selector, {
    key = "trainer/" .. trainerKeys[selector - 11],
    role = "trainer-transition",
    messageRoute = "transition/trainer-name",
    record = { palette = member, character = member + 1, cell = member + 2, animation = member + 3 },
    fixedSprite = { palette = 0x3b, character = 0x3c, cell = 0x3d, animation = 0x3e },
    background = {
      palette = gymLeaderBackgrounds[selector - 11][1],
      character = gymLeaderBackgrounds[selector - 11][2],
      map = gymLeaderBackgrounds[selector - 11][3],
    },
    task = { kind = "overlay115-gym-rival-intro", parameters = { endXFx32 = 876544 } },
    sharedPalette = 0x10,
  })
end
addTransitionRoute(28, {
  key = "trainer/rival-or-passerby",
  role = "rival-transition",
  record = { palette = 0x7f, character = 0x80, cell = 0x81, animation = 0x82 },
  fixedSprite = { palette = 0x3b, character = 0x3c, cell = 0x3d, animation = 0x3e },
  background = { palette = 0x2d, character = 0x2c, map = 0x2e },
  task = { kind = "overlay115-gym-rival-intro", parameters = { endXFx32 = 876544 } },
  sharedPalette = 0x10,
  messageRoute = "transition/rival-name",
  message = { archive = "NARC_msgdata_msg", member = 189, stringId = 0, name = "rival" },
})

local eliteTrainerRoutes = {
  { key = "will", trainerId = 0xf5, opponent = 131, nameplatePalette = 0x2f, shakeTicks = 32 },
  { key = "koga", trainerId = 0xf7, opponent = 135, nameplatePalette = 0x33, shakeTicks = 32 },
  { key = "bruno", trainerId = 0x1a2, opponent = 139, nameplatePalette = 0x34, shakeTicks = 32 },
  { key = "karen", trainerId = 0xf6, opponent = 143, nameplatePalette = 0x35, shakeTicks = 32 },
  { key = "lance", trainerId = 0xf4, opponent = 147, nameplatePalette = 0x36, shakeTicks = 9 },
}
for selector = 29, 33 do
  local source = eliteTrainerRoutes[selector - 28]
  addTransitionRoute(selector, {
    key = "trainer/" .. source.key,
    role = "trainer-intro",
    trainer = { key = source.key },
    messageRoute = "transition/trainer-name",
    context = { playerGender = true },
    spriteVariants = {
      male = { palette = 0xcf, character = 0xd0, cell = 0xd1, animation = 0xd2 },
      female = { palette = 0xd3, character = 0xd4, cell = 0xd5, animation = 0xd6 },
    },
    opponent = {
      palette = source.opponent,
      character = source.opponent + 1,
      cell = source.opponent + 2,
      animation = source.opponent + 3,
    },
    nameplate = {
      palette = source.nameplatePalette,
      character = 0x30,
      cell = 0x31,
      animation = 0x32,
    },
    fixedSprite = { palette = 0x3b, character = 0x3c, cell = 0x3d, animation = 0x3e },
    particles = { intro = 0x97, followup = 0x98 },
    particleMembers = { 0x97, 0x98 },
    task = { kind = "overlay115-elite-intro", parameters = { shakeTicks = source.shakeTicks } },
    message = { archive = "NARC_msgdata_msg", member = 189, name = "trainer" },
  })
end

addTransitionRoute(34, {
  key = "wild/special-legendary",
  role = "camera-and-fade-transition",
  task = {
    kind = "field-camera-pose-sequence",
    parameters = {
      poses = {
        { distanceFx32 = 2731713, angleXRaw = 54786, angleYRaw = 0, perspectiveRaw = 1473, waitTicks = 4 },
        { distanceFx32 = 2731713, angleXRaw = 52994, angleYRaw = 65280, perspectiveRaw = 1537, waitTicks = 4 },
        { distanceFx32 = 2731713, angleXRaw = 58882, angleYRaw = 4096, perspectiveRaw = 1681, waitTicks = 4 },
        { distanceFx32 = 2731713, angleXRaw = 54786, angleYRaw = 2560, perspectiveRaw = 1809, waitTicks = 3 },
        { distanceFx32 = 2731713, angleXRaw = 57602, angleYRaw = 61440, perspectiveRaw = 1920, waitTicks = 3 },
        { distanceFx32 = 2731713, angleXRaw = 50690, angleYRaw = 0, perspectiveRaw = 1873, waitTicks = 3 },
        { distanceFx32 = 2731713, angleXRaw = 57346, angleYRaw = 61440, perspectiveRaw = 2048, waitTicks = 3 },
        { distanceFx32 = 2731713, angleXRaw = 54786, angleYRaw = 0, perspectiveRaw = 2050, waitTicks = 3 },
        { distanceFx32 = 2731713, angleXRaw = 53250, angleYRaw = 4096, perspectiveRaw = 2048, waitTicks = 3 },
        { distanceFx32 = 2731713, angleXRaw = 55554, angleYRaw = 62720, perspectiveRaw = 1873, waitTicks = 3 },
        { distanceFx32 = 2731713, angleXRaw = 53250, angleYRaw = 2560, perspectiveRaw = 1217, waitTicks = 2 },
        { distanceFx32 = 2731713, angleXRaw = 57346, angleYRaw = 61440, perspectiveRaw = 961, waitTicks = 2 },
        { distanceFx32 = 2731713, angleXRaw = 53250, angleYRaw = 61440, perspectiveRaw = 1616, waitTicks = 1 },
        { distanceFx32 = 2731713, angleXRaw = 57346, angleYRaw = 40960, perspectiveRaw = 577, waitTicks = 1 },
        { distanceFx32 = 2731713, angleXRaw = 57762, angleYRaw = 1280, perspectiveRaw = 1280, waitTicks = 1 },
        { distanceFx32 = 2731713, angleXRaw = 54786, angleYRaw = 0, perspectiveRaw = 577, waitTicks = 1 },
      },
      fadeTicks = 10,
      graphicsMode = { mode = 3, bank = 15 },
    },
  },
})
local cameraDistanceTasks = {
  [35] = { key = "wild/ho-oh", distanceDeltaFx32 = -2703360, fadeTicks = 60 },
  [36] = { key = "wild/lugia", distanceDeltaFx32 = -2252800, fadeTicks = 13 },
}
for selector, source in pairs(cameraDistanceTasks) do
  addTransitionRoute(selector, {
    key = source.key,
    role = "camera-and-fade-transition",
    task = {
      kind = "field-camera-perspective-distance-fade",
      parameters = {
        perspectiveDeltaRaw = 0x100,
        perspectiveTicks = 40,
        waitTicks = 5,
        distanceDeltaFx32 = source.distanceDeltaFx32,
        distanceVelocityFx32 = 2048,
        distanceTicks = 8,
        fadeTicks = source.fadeTicks,
        graphicsMode = { mode = 5, bank = 13 },
      },
    },
  })
end
addTransitionRoute(37, {
  key = "trainer/generic",
  role = "generic-trainer-transition",
  sprite = { palette = 1, character = 7, cell = 9, animation = 8 },
})
addTransitionRoute(38, {
  key = "wild/generic",
  role = "generic-wild-transition",
  sprite = { palette = 1, character = 4, cell = 6, animation = 5 },
})
addTransitionRoute(39, {
  key = "trainer/team-rocket",
  role = "trainer-transition",
  sprite = { palette = 1, character = 0x9c, cell = 0x9e, animation = 0x9d },
})
local rocketTrainerRecordIds = { 0xde, 0xe2, 0xe6, 0xea, 0xee }
for selector = 40, 44 do
  local member = rocketTrainerRecordIds[selector - 39]
  local rocketTrainerKeys = { "petrel", "proton", "archer", "ariana", "rocket-boss" }
  addTransitionRoute(selector, {
    key = "trainer/" .. rocketTrainerKeys[selector - 39],
    role = "trainer-transition",
    messageRoute = "transition/trainer-name",
    record = { palette = member, character = member + 1, cell = member + 2, animation = member + 3 },
    background = { palette = 0xd7, character = 0xd8, maps = { 0xd9, 0xda } },
    message = { archive = "NARC_msgdata_msg", member = 189, stringId = 0, name = "trainer" },
  })
end
addTransitionRoute(45, {
  key = "trainer/kimono-girl",
  role = "background-transition",
  background = { palette = 0xa6, character = 0xa7, map = 0xa8 },
})
addTransitionRoute(46, {
  key = "trainer/red",
  role = "red-trainer-transition",
  trainer = { key = "red", transitionRecord = 46 },
  sprite = { palette = 1, character = 10, cell = 12, animation = 11 },
  background = { palette = 0xa6, character = 0xa7, map = 0xa8 },
})
BattlePresentationSources.TRANSITION_RESOURCE_SETS = {
  {
    key = "transition/sprite-set/a",
    resources = {
      { key = "palette", kind = "palette", member = 1 },
      { key = "characters", kind = "texture", member = 7 },
      { key = "cells", kind = "cell", member = 9 },
      { key = "animation", kind = "animation", member = 8 },
    },
  },
  {
    key = "transition/sprite-set/b",
    resources = {
      { key = "palette", kind = "palette", member = 1 },
      { key = "characters", kind = "texture", member = 4 },
      { key = "cells", kind = "cell", member = 6 },
      { key = "animation", kind = "animation", member = 5 },
    },
  },
  {
    key = "transition/sprite-set/c",
    resources = {
      { key = "palette", kind = "palette", member = 1 },
      { key = "characters", kind = "texture", member = 156 },
      { key = "cells", kind = "cell", member = 158 },
      { key = "animation", kind = "animation", member = 157 },
    },
  },
}

-- Decoder-supported transition payloads established by native loader calls.
-- Member IDs and selector numbers are build provenance; runtime resource keys
-- are content-addressed after decoding.
BattlePresentationSources.TRANSITION_TYPED_RESOURCES = {}
-- Overlay 115's Elite Four callbacks load these whole members as intro and
-- follow-up particle programs.
BattlePresentationSources.TRANSITION_PARTICLE_MEMBERS = { 0x97, 0x98 }
-- Overlay 120's selector 46 callback resolves to Red's fixed resource tuple.
BattlePresentationSources.TRANSITION_INTERNAL_RESOURCES = {
  sprite = { palette = 1, character = 10, cell = 12, animation = 11 },
}
local function addTransitionResource(memberId, kind, selectors)
  BattlePresentationSources.TRANSITION_TYPED_RESOURCES[#BattlePresentationSources.TRANSITION_TYPED_RESOURCES + 1] = {
    memberId = memberId,
    kind = kind,
    selectors = selectors,
  }
end
local function addTransitionQuartet(palette, character, cell, animation, selectors)
  addTransitionResource(palette, "palette", selectors)
  addTransitionResource(character, "texture", selectors)
  addTransitionResource(cell, "cell", selectors)
  addTransitionResource(animation, "animation", selectors)
end

addTransitionQuartet(1, 7, 9, 8, { 9, 37 })
addTransitionQuartet(1, 4, 6, 5, { 38, 6, 8, 10, 11 })
addTransitionQuartet(1, 156, 158, 157, { 39 })
addTransitionResource(1, "palette", { 6, 7, 8, 10, 11 })
addTransitionResource(7, "texture", { 7 })
addTransitionResource(9, "cell", { 7 })
addTransitionResource(8, "animation", { 7 })
addTransitionResource(4, "texture", { 6, 8, 10, 11 })
addTransitionResource(6, "cell", { 6, 8, 10, 11 })
addTransitionResource(5, "animation", { 6, 8, 10, 11 })

addTransitionResource(0x10, "palette", { 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28 })
addTransitionQuartet(
  0x3b,
  0x3c,
  0x3d,
  0x3e,
  { 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33 }
)
for selector = 12, 28 do
  local first = 0x3f + (selector - 12) * 4
  addTransitionQuartet(first, first + 1, first + 2, first + 3, { selector })
end
for selector = 12, 28 do
  local background = gymLeaderBackgrounds[selector - 11]
  addTransitionResource(background[1], "palette", { selector })
  addTransitionResource(background[2], "texture", { selector })
  addTransitionResource(background[3], "map", { selector })
end
for selector = 29, 33 do
  addTransitionQuartet(0xcf, 0xd0, 0xd1, 0xd2, { selector })
  addTransitionQuartet(0xd3, 0xd4, 0xd5, 0xd6, { selector })
end
for selector = 29, 33 do
  local opponent = 131 + (selector - 29) * 4
  addTransitionQuartet(opponent, opponent + 1, opponent + 2, opponent + 3, { selector })
end
-- The second overlay-115 sprite loader takes a record-selected palette byte
-- followed by fixed character, cell, and animation members. Its helper's
-- parameter order establishes the resource kinds; the five callback records
-- supply palette members 0x2f and 0x33..0x36.
addTransitionResource(0x30, "texture", { 29, 30, 31, 32, 33 })
addTransitionResource(0x31, "cell", { 29, 30, 31, 32, 33 })
addTransitionResource(0x32, "animation", { 29, 30, 31, 32, 33 })
for selector, paletteMember in ipairs({ 0x2f, 0x33, 0x34, 0x35, 0x36 }) do
  addTransitionResource(paletteMember, "palette", { selector + 28 })
end

addTransitionResource(0xd7, "palette", { 40, 41, 42, 43, 44 })
addTransitionResource(0x9c, "texture", { 39 })
addTransitionResource(0x9e, "cell", { 39 })
addTransitionResource(0x9d, "animation", { 39 })
for selector = 40, 44 do
  local first = 0xde + (selector - 40) * 4
  addTransitionQuartet(first, first + 1, first + 2, first + 3, { selector })
end
addTransitionResource(0xd8, "texture", { 40, 41, 42, 43, 44 })
addTransitionResource(0xd9, "map", { 40, 41, 42, 43, 44 })
addTransitionResource(0xda, "map", { 40, 41, 42, 43, 44 })

-- The first overlay-120 callback group uses distinct sprite and BG paths.
for _, selector in ipairs({ 0, 1, 2, 3, 4, 5 }) do
  addTransitionResource(0xa0, "palette", { selector })
  addTransitionResource(0xa1, "texture", { selector })
  addTransitionResource(0xa2, "map", { selector })
  addTransitionResource(0xa4, "texture", { selector })
  addTransitionResource(0xa5, "map", { selector })
  addTransitionResource(0xa6, "palette", { selector })
  addTransitionResource(0xa7, "texture", { selector })
  addTransitionResource(0xa8, "map", { selector })
end
-- The Red callback's asynchronous helper uploads the same typed background
-- members used by the first overlay-120 family before its child tasks run.
addTransitionResource(0xa0, "palette", { 46 })
addTransitionResource(0xa1, "texture", { 46 })
addTransitionResource(0xa4, "texture", { 46 })
addTransitionResource(0xa2, "map", { 46 })
addTransitionResource(0xa5, "map", { 46 })
addTransitionResource(0xa6, "palette", { 45 })
addTransitionResource(0xa7, "texture", { 45 })
addTransitionResource(0xa8, "map", { 45 })
addTransitionQuartet(1, 10, 12, 11, { 46 })

-- The retail lower load keeps the first 0x6000 bytes of the shared
-- 1024-tile lower characters: 384 tiles of 64 bytes in 8bpp terms, read
-- here as the staged 4bpp run's leading 384 tiles.
BattlePresentationSources.LOWER_USED_TILES = 384

-- Height-member formulas are the species switch in
-- GetMonPicHeightBySpeciesGenderForm (src/pokemon.c). Values are source
-- member identities and stay in this producer catalog.
local SPECIAL_HEIGHT_BASES = {
  DEOXYS = 0x00,
  UNOWN = 0x08,
  CASTFORM = 0x40,
  BURMY = 0x48,
  WORMADAM = 0x4E,
  SHELLOS = 0x54,
  GASTRODON = 0x58,
  CHERRIM = 0x5C,
  ARCEUS = 0x60,
  SHAYMIN = 0x88,
  ROTOM = 0x8C,
  GIRATINA = 0x98,
  PICHU = 0x9C,
}

---@param speciesId integer source species identity
---@param speciesKey string semantic species key
---@param form integer normalized runtime form
---@param facing integer 0 for back or 2 for front
---@param gender string "male" or "female"
---@return string archiveSymbol
---@return integer memberId
function BattlePresentationSources.pictureHeightSource(speciesId, speciesKey, form, facing, gender)
  assert(facing == 0 or facing == 2, "picture facing must be 0 (back) or 2 (front)")
  assert(gender == "male" or gender == "female", "picture gender must be male or female")
  local halfFacing = facing / 2
  if speciesKey == "EGG" then
    return BattlePresentationSources.PICTURE_HEIGHT_OTHER_NARC, 0x84 + form
  elseif speciesKey == "BAD_EGG" then
    return BattlePresentationSources.PICTURE_HEIGHT_OTHER_NARC, 0x84
  elseif speciesKey == "CASTFORM" then
    return BattlePresentationSources.PICTURE_HEIGHT_OTHER_NARC, 0x40 + 2 * facing + form
  elseif speciesKey == "SHELLOS" or speciesKey == "GASTRODON" or speciesKey == "CHERRIM" then
    return BattlePresentationSources.PICTURE_HEIGHT_OTHER_NARC, assert(SPECIAL_HEIGHT_BASES[speciesKey]) + facing + form
  elseif
    speciesKey == "DEOXYS"
    or speciesKey == "UNOWN"
    or speciesKey == "BURMY"
    or speciesKey == "WORMADAM"
    or speciesKey == "ARCEUS"
    or speciesKey == "SHAYMIN"
    or speciesKey == "ROTOM"
    or speciesKey == "GIRATINA"
    or speciesKey == "PICHU"
  then
    return BattlePresentationSources.PICTURE_HEIGHT_OTHER_NARC,
      assert(SPECIAL_HEIGHT_BASES[speciesKey]) + halfFacing + form * 2
  end
  return BattlePresentationSources.PICTURE_HEIGHT_NARC, speciesId * 4 + facing + (gender == "female" and 0 or 1)
end

local backgroundIndex = {}
for index, background in ipairs(BattlePresentationSources.BACKGROUNDS) do
  backgroundIndex[background] = index - 1
end

local timeIndex = {}
for index, time in ipairs(BattlePresentationSources.TIMES) do
  timeIndex[time] = index - 1
end

---@param background string
---@return integer|nil zero-based source background identity
function BattlePresentationSources.backgroundId(background)
  return backgroundIndex[background]
end

---@param background string
---@return boolean true for the outdoor recipes whose palettes follow the time
function BattlePresentationSources.isOutdoor(background)
  local id = backgroundIndex[background]
  return id ~= nil and id < BattlePresentationSources.OUTDOOR_BACKGROUNDS
end

---@param background string
---@param time string
---@return integer|nil palette variant, or nil for an unknown axis
function BattlePresentationSources.paletteVariant(background, time)
  if backgroundIndex[background] == nil or timeIndex[time] == nil then
    return nil
  end
  if not BattlePresentationSources.isOutdoor(background) then
    return 0
  end
  return timeIndex[time]
end

---@param backgroundId integer zero-based source background identity
---@param variant integer palette variant
---@return integer base palette member
function BattlePresentationSources.basePaletteMember(backgroundId, variant)
  return 176 + 3 * backgroundId + variant
end

---@param backgroundId integer zero-based source background identity
---@return integer base character member
function BattlePresentationSources.baseCharMember(backgroundId)
  return backgroundId + 3
end

---@param backgroundId integer zero-based source background identity
---@return integer base lower palette member
function BattlePresentationSources.lowerBasePaletteMember(backgroundId)
  if backgroundId == 17 then
    return 288
  end
  return 247 + backgroundId
end

---@param backgroundId integer zero-based source background identity
---@return integer touch lower palette member
function BattlePresentationSources.lowerTouchPaletteMember(backgroundId)
  if backgroundId == 17 then
    return 289
  end
  return 271 + backgroundId
end

---@param background string
---@param terrain string
---@param time string
---@return string canonical semantic scene key
function BattlePresentationSources.sceneKey(background, terrain, time)
  return background .. "/" .. terrain .. "/" .. time
end

---@param key string
---@return { background: string, terrain: string, time: string }|nil
function BattlePresentationSources.parseSceneKey(key)
  if type(key) ~= "string" then
    return nil
  end
  local background, terrain, time = key:match("^([^/]+)/([^/]+)/([^/]+)$")
  if background == nil or terrain == nil or time == nil then
    return nil
  end
  if backgroundIndex[background] == nil then
    return nil
  end
  if BattlePresentationSources.TERRAIN[terrain] == nil then
    return nil
  end
  if timeIndex[time] == nil then
    return nil
  end
  return { background = background, terrain = terrain, time = time }
end

---@param key string
---@return boolean
function BattlePresentationSources.validateSceneKey(key)
  return BattlePresentationSources.parseSceneKey(key) ~= nil
end

-- Every ordinary role/variant resolves to a complete recipe: the background
-- and terrain axes are fully inventoried, every role member is a
-- non-negative integer, and the palette formulas stay inside the evidenced
-- member ranges.
---@return boolean
function BattlePresentationSources.validate()
  if #BattlePresentationSources.BACKGROUNDS ~= 18 then
    return false
  end
  local ordinals = {}
  local terrainCount = 0
  for _, record in pairs(BattlePresentationSources.TERRAIN) do
    terrainCount = terrainCount + 1
    if type(record.ordinal) ~= "number" or ordinals[record.ordinal] then
      return false
    end
    ordinals[record.ordinal] = true
    for _, field in ipairs({ "type0", "type1", "day", "evening", "night" }) do
      if type(record[field]) ~= "number" or record[field] < 0 then
        return false
      end
    end
  end
  if terrainCount ~= 24 then
    return false
  end
  if #BattlePresentationSources.SLOT_GEOMETRY ~= 6 then
    return false
  end
  local sideTypes = {}
  for _, row in ipairs(BattlePresentationSources.SLOT_GEOMETRY) do
    if type(row.sideType) ~= "number" or row.sideType ~= math.floor(row.sideType) or sideTypes[row.sideType] then
      return false
    end
    sideTypes[row.sideType] = true
    for _, field in ipairs({
      "settledX",
      "settledY",
      "entryX",
      "entryY",
      "depth",
      "hudX",
      "hudY",
      "hudPriority",
      "hudBgPriority",
    }) do
      if type(row[field]) ~= "number" or row[field] ~= math.floor(row[field]) then
        return false
      end
    end
    if row.hudPriority < 0 or row.hudPriority > 31 or row.hudBgPriority < 0 or row.hudBgPriority > 3 then
      return false
    end
  end
  for _, sideType in ipairs({ 0, 1, 2, 3, 4, 5 }) do
    if not sideTypes[sideType] then
      return false
    end
  end
  local patchSpans = BattlePresentationSources.HUD_PATCH_SPANS
  if type(patchSpans) ~= "table" or type(patchSpans.hp) ~= "table" or #patchSpans.hp ~= 6 then
    return false
  end
  local patchSideTypes = {}
  for _, record in ipairs(patchSpans.hp) do
    if
      type(record.sideType) ~= "number"
      or record.sideType ~= math.floor(record.sideType)
      or patchSideTypes[record.sideType]
      or not sideTypes[record.sideType]
      or type(record.spans) ~= "table"
      or #record.spans ~= 2
    then
      return false
    end
    patchSideTypes[record.sideType] = true
    local count = 0
    for _, span in ipairs(record.spans) do
      if
        type(span.tile) ~= "number"
        or span.tile ~= math.floor(span.tile)
        or span.tile < 0
        or span.tile > 1023
        or type(span.count) ~= "number"
        or span.count ~= math.floor(span.count)
        or span.count < 0
        or span.count > 12
        or span.tile + span.count > 1024
      then
        return false
      end
      count = count + span.count
    end
    if count ~= 6 then
      return false
    end
  end
  for _, sideType in ipairs({ 0, 1, 2, 3, 4, 5 }) do
    if not patchSideTypes[sideType] then
      return false
    end
  end
  if type(patchSpans.experience) ~= "table" or #patchSpans.experience ~= 2 then
    return false
  end
  local experienceCount = 0
  for _, span in ipairs(patchSpans.experience) do
    if
      type(span.tile) ~= "number"
      or span.tile ~= math.floor(span.tile)
      or span.tile < 0
      or span.tile > 1023
      or type(span.count) ~= "number"
      or span.count ~= math.floor(span.count)
      or span.count < 0
      or span.count > 12
      or span.tile + span.count > 1024
    then
      return false
    end
    experienceCount = experienceCount + span.count
  end
  if experienceCount ~= 12 then
    return false
  end
  for category, expectedCounts in pairs({
    currentHp = { 3 },
    maximumHp = { 3 },
    status = { 3 },
    gender = { 2, 2 },
    level = { 3, 3 },
    caught = { 1 },
  }) do
    local records = patchSpans[category]
    if type(records) ~= "table" or #records ~= 6 then
      return false
    end
    local covered = {}
    for _, record in ipairs(records) do
      if
        type(record.sideType) ~= "number"
        or record.sideType ~= math.floor(record.sideType)
        or record.sideType < 0
        or record.sideType > 5
        or covered[record.sideType]
        or not sideTypes[record.sideType]
      then
        return false
      end
      covered[record.sideType] = true
      local spans = record.spans or { record }
      if type(spans) ~= "table" or #spans ~= #expectedCounts then
        return false
      end
      for index, span in ipairs(spans) do
        if
          type(span.tile) ~= "number"
          or span.tile ~= math.floor(span.tile)
          or span.tile < 0
          or span.tile > 1023
          or type(span.count) ~= "number"
          or span.count ~= math.floor(span.count)
          or span.count < 1
          or span.count > 12
          or span.tile + span.count > 1024
          or span.count ~= expectedCounts[index]
        then
          return false
        end
      end
    end
    for _, sideType in ipairs({ 0, 1, 2, 3, 4, 5 }) do
      if not covered[sideType] then
        return false
      end
    end
  end
  if type(patchSpans.playerDoubleMode) ~= "table" or #patchSpans.playerDoubleMode ~= 2 then
    return false
  end
  local doubleModeSides = {}
  for _, record in ipairs(patchSpans.playerDoubleMode) do
    if
      (record.sideType ~= 2 and record.sideType ~= 4)
      or doubleModeSides[record.sideType]
      or type(record.gauge) ~= "table"
      or #record.gauge ~= 4
      or type(record.numbers) ~= "table"
      or #record.numbers ~= 3
    then
      return false
    end
    doubleModeSides[record.sideType] = true
    for _, mode in ipairs({ record.gauge, record.numbers }) do
      local destinations = {}
      for _, patch in ipairs(mode) do
        if
          type(patch.tile) ~= "number"
          or patch.tile ~= math.floor(patch.tile)
          or patch.tile < 0
          or patch.tile > 1023
          or destinations[patch.tile]
          or type(patch.sourceTile) ~= "number"
          or patch.sourceTile ~= math.floor(patch.sourceTile)
          or patch.sourceTile < 0
          or patch.sourceTile >= BattlePresentationSources.HUD_COMPONENTS.tileCount
        then
          return false
        end
        destinations[patch.tile] = true
      end
    end
  end
  if not doubleModeSides[2] or not doubleModeSides[4] then
    return false
  end
  local hudComponents = BattlePresentationSources.HUD_COMPONENTS
  if
    type(hudComponents) ~= "table"
    or hudComponents.depth ~= 3
    or hudComponents.tileCount ~= 78
    or type(hudComponents.hex) ~= "string"
    or #hudComponents.hex ~= hudComponents.tileCount * 64
    or hudComponents.hex:find("[^0-9a-f]") ~= nil
  then
    return false
  end
  for ordinal = 0, 23 do
    if not ordinals[ordinal] then
      return false
    end
  end
  local roles = BattlePresentationSources.ROLES
  local function member(value)
    return type(value) == "number" and value >= 0
  end
  for _, field in ipairs({
    "lowerChars",
    "lowerPalette",
    "hudPalette",
    "lowerObjPalette",
    "backdropScreen",
    "terrainCells0",
    "terrainAnim0",
    "terrainCells1",
    "terrainAnim1",
  }) do
    if not member(roles[field]) then
      return false
    end
  end
  for _, field in ipairs({ "commandScreens", "fightScreens", "targetScreens", "twoOptionScreens" }) do
    if type(roles[field]) ~= "table" or #roles[field] == 0 then
      return false
    end
    for _, id in ipairs(roles[field]) do
      if not member(id) then
        return false
      end
    end
  end
  for _, field in ipairs({
    "playerHud",
    "enemyHud",
    "playerHudDoubleLeft",
    "playerHudDoubleRight",
    "enemyHudDoubleLeft",
    "enemyHudDoubleRight",
    "arrow",
    "cursor",
  }) do
    local role = roles[field]
    if type(role) ~= "table" or not member(role.nanr) or not member(role.ncer) or not member(role.ncgr) then
      return false
    end
  end
  if type(roles.gauges) ~= "table" or #roles.gauges ~= 2 then
    return false
  end
  for _, family in ipairs(roles.gauges) do
    if not member(family.ncer) or not member(family.ncgr) or not member(family.nanr) then
      return false
    end
  end
  return true
end

local function sourceMessageResources(bankRoles)
  local resources = {}
  for _, bankRole in ipairs(bankRoles) do
    resources[#resources + 1] = {
      archive = "NARC_msgdata_msg",
      memberId = BattlePresentationSources.MESSAGE_BANKS[bankRole],
      format = "HGSS_MSG_BANK",
      bankRole = bankRole,
      key = BattlePresentationSources.MESSAGE_BANK_RESOURCE_KEYS[bankRole],
    }
  end
  return resources
end

local frontierMailBankRoles = {
  "mailTextA",
  "mailTextB",
  "mailTextC",
  "mailTextD",
  "mailTextE",
  "easyChatSpecies",
  "easyChatMoves",
  "easyChatTypes",
  "easyChatAbilities",
  "easyChatTrainers",
  "easyChatPeople",
  "easyChatGreetings",
  "easyChatLifestyle",
  "easyChatFeelings",
  "easyChatToughWords",
  "easyChatUnion",
}
BattlePresentationSources.FRONTIER_TRAINER_MAIL.sourceResources = sourceMessageResources(frontierMailBankRoles)
BattlePresentationSources.MESSAGE_SOURCE_ROUTES.frontierTrainerMail.sourceResources =
  BattlePresentationSources.FRONTIER_TRAINER_MAIL.sourceResources

---@return { key: string, kind: "menu-route"|"message-route"|"transition-route", sourceRouteKey: string, selection: { route: string }}[] source-derived non-animation roots
function BattlePresentationSources.listSemanticRoots()
  local roots = {}
  local rootsByKey = {}
  local function addRoot(key, kind, sourceRouteKey)
    local prior = rootsByKey[key]
    if prior ~= nil then
      assert(prior.kind == kind, "semantic root kind agrees across source aliases")
      return
    end
    local root = {
      key = key,
      kind = kind,
      sourceRouteKey = sourceRouteKey,
      selection = { route = sourceRouteKey },
    }
    rootsByKey[key] = root
    roots[#roots + 1] = root
  end

  for routeKey in pairs(BattlePresentationSources.MENU_ROUTES) do
    addRoot(routeKey, "menu-route", routeKey)
  end
  for routeKey, route in pairs(BattlePresentationSources.MESSAGE_SOURCE_ROUTES) do
    addRoot(route.key, "message-route", routeKey)
  end
  for routeKey in pairs(BattlePresentationSources.MENU_MESSAGE_ROUTES) do
    addRoot(routeKey, "message-route", routeKey)
  end
  for routeKey, route in pairs(BattlePresentationSources.TRANSITION_SELECTOR_ROUTES) do
    addRoot("transition/" .. route.key, "transition-route", route.key)
  end
  for routeKey, route in pairs(BattlePresentationSources.TRANSITION_MESSAGE_SOURCE_ROUTES) do
    addRoot(route.key, "message-route", routeKey)
  end

  table.sort(roots, function(left, right)
    return left.key < right.key
  end)
  return roots
end

return BattlePresentationSources
