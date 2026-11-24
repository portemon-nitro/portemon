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
