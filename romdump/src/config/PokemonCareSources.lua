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
