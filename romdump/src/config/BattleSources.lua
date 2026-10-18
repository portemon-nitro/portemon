-- Pinned native battle/trainer/encounter source inventory. Every table below is
-- generated from the retail ROM:
-- the move table with its move-effect vocabulary, trainer records with the
-- TRTYPE_* selection bits and the rival-name rule (TRAINERCLASS_RIVAL), and
-- encounter members with slot/replacement selection. Semantic keys reuse MonSources/ItemSources;
-- this module adds no new identities. Pure data; no I/O. Never imported by
-- runtime: libs/assets and game packages must not require this module.

local MonSources = require("romdump.src.config.MonSources")
local ItemSources = require("romdump.src.config.ItemSources")

---@class BattleSources
local BattleSources = {}

BattleSources.provenance = {
  repo = "retail ROM",
}

-- One semantic binding per usable native move, keyed by the MonSources move
-- key. Behavior keys stay per-move: the move-to-effect mapping lives in ROM,
-- so effect families are resolved by the move-execution consumer, while this
-- inventory guarantees every usable move has exactly one binding and no
-- silent fallback. Sentinels (NONE) carry no binding.
---@type table<string, { key: string, params: table<string, integer> }>
BattleSources.moveBindings = {}
for moveId = 1, MonSources.NUM_MOVES do
  local moveKey = assert(MonSources.moveKeys[moveId], "move identity has no key: " .. moveId)
  BattleSources.moveBindings[moveKey] =
    { key = "move_" .. moveKey:lower(), params = { nativeId = moveId } }
end

-- One semantic binding per usable native ability, keyed by the MonSources
-- ability key. Ability NONE is a sentinel, not a usable binding.
---@type table<string, { key: string, params: table<string, integer> }>
BattleSources.abilityBindings = {}
for abilityId = 1, MonSources.NUM_ABILITIES do
  local abilityKey = assert(MonSources.abilityKeys[abilityId], "ability identity has no key: " .. abilityId)
  BattleSources.abilityBindings[abilityKey] =
    { key = "ability_" .. abilityKey:lower(), params = { nativeId = abilityId } }
end

-- Static held-item classes by ItemSources identity: "ball" for balls,
-- "arceus_plate" for plates, "griseous_orb" for the Griseous Orb,
-- "no_hold" for mail (never attaches to a mon). Every other item carries
-- the "held" class and resolves its precise hold effect from the ROM
-- hold-effect byte at compile time, so the inventory stays total without
-- pinning unverified per-item effects.
---@type table<string, { key: string, params: table<string, integer> }>
BattleSources.heldItemBindings = {}
-- Item identities are 0..536 per the ItemSources key table header.
for nativeId = 0, 536 do
  local itemKey = assert(ItemSources.itemKeys[nativeId], "item identity has no key: " .. nativeId)
  local class = "held"
  if ItemSources.ballItemIds[nativeId] then
    class = "ball"
  elseif nativeId == ItemSources.GRISEOUS_ORB_ID then
    class = "griseous_orb"
  elseif nativeId >= ItemSources.FIRST_PLATE and nativeId <= ItemSources.LAST_PLATE then
    class = "arceus_plate"
  elseif nativeId >= ItemSources.FIRST_MAIL and nativeId <= ItemSources.LAST_MAIL then
    class = "no_hold"
  end
  BattleSources.heldItemBindings[itemKey] = { key = class, params = { nativeId = nativeId } }
end

-- Encounter-dispatch command families from the retail ROM
-- (ENCOUNTER_TYPE_* selection, rod types, and the safari/contest contexts).
-- Each family carries its native slot count; battle-script commands belong
-- to the move-execution consumer, not this import inventory.
---@type table<string, { key: string, params: table<string, integer> }>
BattleSources.commandBindings = {
  land = { key = "encounter_land", params = { slots = 12 } },
  surfing = { key = "encounter_surfing", params = { slots = 5 } },
  fishing = { key = "encounter_fishing", params = { slots = 5 } },
  rock_smash = { key = "encounter_rock_smash", params = { slots = 2 } },
  headbutt = { key = "encounter_headbutt", params = { slots = 6 } },
  safari = { key = "encounter_safari", params = { slots = 12 } },
  bug_contest = { key = "encounter_bug_contest", params = { slots = 12 } },
}

-- Native slot-selection weights from the EncounterSlot_WildMonSlotRoll_*
-- interval ladders in the retail ROM. Entries are per-slot
-- interval widths in selection order; they sum to 100 per method.
BattleSources.slotWeights = {
  land = { 20, 20, 10, 10, 10, 10, 5, 5, 4, 4, 1, 1 },
  surf = { 60, 30, 5, 4, 1 },
  rod = { 40, 30, 15, 10, 5 },
  rock = { 80, 20 },
  headbutt = { 50, 15, 15, 10, 5, 5 },
}

-- Native replacement targets from the retail ROM: radio music
-- replaces land slots 2,3 (first species) and 4,5 (second species); the land
-- swarm replaces land slots 0,1; the surf swarm replaces surf slot 0; night
-- fishing replaces the rod slot by rod (good 3, super 1); the fishing swarm
-- replaces rod slots by rod (old {2}, good {0,2,3}, super {0,1,2,3,4}).
BattleSources.replacementSlots = {
  radioFirst = { 2, 3 },
  radioSecond = { 4, 5 },
  landSwarm = { 0, 1 },
  surfSwarm = { 0 },
  nightFishRods = { good_rod = 3, super_rod = 1 },
  fishSwarmRods = {
    old_rod = { 2 },
    good_rod = { 0, 2, 3 },
    super_rod = { 0, 1, 2, 3, 4 },
  },
}

-- Pinned species weight-table selection facts from
-- the retail ROM's battle weight lookup: member 1
-- of NARC_application_zukanlist_zkn_data_zukan_data (narcId 74, path
-- "a/0/7/4") is an s32 array indexed by species id carrying weight in
-- hectograms. The units follow the Heavy Ball site in the same file, which
-- comments that weight is in kilograms moved left by one decimal point and
-- thresholds at 4096/3072/2048. The read site indexes by species only: no
-- form dimension exists, so the catalog carries weight per species, never
-- per form. No HgssArchives alias exists for this archive (checked against
-- its alias table), so the selection is pinned here; compilers resolve the
-- raw source symbol through RomFs. Height is deliberately out of scope: no
-- HGSS ball rule consumes height (Heavy Ball consumes weight only).
BattleSources.weightSources = {
  symbol = "NARC_application_zukanlist_zkn_data_zukan_data",
  narcId = 74,
  path = "a/0/7/4",
  memberId = 1,
  units = "hectograms",
  entrySize = 4,
  minSpecies = 0,
  -- Species-indexed 0..MAX_SPECIES; kept numeric here so the pin stays
  -- readable without requiring MonSources at this layer.
  maxSpecies = 493,
}

-- Pinned TRDATA/TRPOKE selection facts from the retail ROM and
-- the retail ROM: the 20-byte header, the four member shapes
-- selected by the TRTYPE_* moves/item bits, the species-word packing, and
-- the rival class whose name resolves from the save.
BattleSources.trainerSources = {
  recordSize = 20,
  memberSizes = { [0] = 8, [1] = 16, [2] = 10, [3] = 18 },
  speciesMask = 0x3FF,
  formShift = 10,
  rivalClass = 23,
  aiDoublesBit = 7,
  -- NARC members align to 4 bytes: item-variant parties (10/18-byte
  -- members) carry up to two trailing packing bytes the native reader
  -- never indexes. Plain/custom-move parties (8/16-byte members) are
  -- always aligned and carry no padding.
  memberAlignment = 4,
}

-- Pinned numeric trainer-class identities from include/constants/trainer_class.h
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36): the header
-- byte of the 20-byte trainer record behind each TRAINERCLASS_* symbol, in
-- numeric order. Phone contact aliases (200-207) never enter battles and
-- stay out; Kanto variant classes keep their own distinct identities. The
-- trainer compiler and the battle selection mirrors derive from this table;
-- no other module carries its own copy of these identities.
---@type table<integer, string>
BattleSources.trainerClassKeys = {
  [0] = "PKMN_TRAINER_ETHAN", [1] = "PKMN_TRAINER_LYRA", [2] = "YOUNGSTER", [3] = "LASS",
  [4] = "CAMPER", [5] = "PICNICKER", [6] = "BUG_CATCHER", [7] = "AROMA_LADY",
  [8] = "TWINS", [9] = "HIKER", [10] = "BATTLE_GIRL", [11] = "FISHERMAN",
  [12] = "CYCLIST_M", [13] = "CYCLIST_F", [14] = "BLACK_BELT", [15] = "ARTIST",
  [16] = "PKMN_BREEDER_M", [17] = "PKMN_BREEDER_F", [18] = "COWGIRL", [19] = "JOGGER",
  [20] = "POKEFAN_M", [21] = "POKEFAN", [22] = "POKE_KID", [23] = "RIVAL",
  [24] = "ACE_TRAINER_M", [25] = "ACE_TRAINER_F", [26] = "WAITRESS", [27] = "VETERAN",
  [28] = "NINJA_BOY", [29] = "DRAGON_TAMER", [30] = "BIRD_KEEPER", [31] = "JUGGLER",
  [32] = "RICH_BOY", [33] = "LADY", [34] = "GENTLEMAN", [35] = "SOCIALITE",
  [36] = "BEAUTY", [37] = "COLLECTOR", [38] = "POLICEMAN", [39] = "PKMN_RANGER_M",
  [40] = "PKMN_RANGER_F", [41] = "SCIENTIST", [42] = "SWIMMER_M", [43] = "SWIMMER_F",
  [44] = "TUBER_M", [45] = "TUBER_F", [46] = "SAILOR", [47] = "KIMONO_GIRL",
  [48] = "RUIN_MANIAC", [49] = "PSYCHIC_M", [50] = "PSYCHIC_F", [51] = "PI",
  [52] = "GUITARIST", [53] = "ACE_TRAINER_M_GS", [54] = "ACE_TRAINER_F_GS", [55] = "TEAM_ROCKET",
  [56] = "SKIER", [57] = "ROUGHNECK", [58] = "CLOWN", [59] = "WORKER",
  [60] = "SCHOOL_KID_M", [61] = "SCHOOL_KID_F", [62] = "TEAM_ROCKET_F", [63] = "BURGLAR",
  [64] = "FIREBREATHER", [65] = "BIKER", [66] = "LEADER_FALKNER", [67] = "LEADER_BUGSY",
  [68] = "POKE_MANIAC", [69] = "BIRD_KEEPER_GS", [70] = "LEADER_WHITNEY", [71] = "RANCHER",
  [72] = "LEADER_MORTY", [73] = "LEADER_PRYCE", [74] = "LEADER_JASMINE", [75] = "LEADER_CHUCK",
  [76] = "LEADER_CLAIR", [77] = "TEACHER", [78] = "SUPER_NERD", [79] = "SAGE",
  [80] = "PARASOL_LADY", [81] = "WAITER", [82] = "MEDIUM", [83] = "CAMERAMAN",
  [84] = "REPORTER", [85] = "IDOL", [86] = "CHAMPION", [87] = "ELITE_FOUR_WILL",
  [88] = "ELITE_FOUR_KAREN", [89] = "ELITE_FOUR_KOGA", [90] = "PKMN_TRAINER_CHERYL", [91] = "PKMN_TRAINER_RILEY",
  [92] = "PKMN_TRAINER_BUCK", [93] = "PKMN_TRAINER_MIRA", [94] = "PKMN_TRAINER_MARLEY",
  [95] = "PKMN_TRAINER_FTR_LUCAS", [96] = "PKMN_TRAINER_FTR_DAWN", [97] = "TOWER_TYCOON",
  [98] = "LEADER_BROCK", [99] = "HALL_MATRON", [100] = "FACTORY_HEAD", [101] = "ARCADE_STAR",
  [102] = "CASTLE_VALET", [103] = "LEADER_MISTY", [104] = "LEADER_LT_SURGE", [105] = "LEADER_ERIKA",
  [106] = "LEADER_JANINE", [107] = "LEADER_SABRINA", [108] = "LEADER_BLAINE",
  [109] = "PKMN_TRAINER_RED", [110] = "LEADER_BLUE", [111] = "ELDER", [112] = "ELITE_FOUR_BRUNO",
  [113] = "SCIENTIST_GS", [114] = "EXECUTIVE_ARIANA", [115] = "BOARDER", [116] = "EXECUTIVE_ARCHER",
  [117] = "EXECUTIVE_PROTON", [118] = "EXECUTIVE_PETREL", [119] = "PASSERBY", [120] = "MYSTERY_MAN",
  [121] = "DOUBLE_TEAM", [122] = "YOUNG_COUPLE", [123] = "PKMN_TRAINER_LANCE", [124] = "ROCKET_BOSS",
  [125] = "PKMN_TRAINER_LUCAS_DP", [126] = "PKMN_TRAINER_DAWN_DP", [127] = "PKMN_TRAINER_LUCAS_PT",
  [128] = "PKMN_TRAINER_DAWN_PT",
}

-- Pinned trainer-class payout rates from
-- the retail ROM's prize-money table: one
-- non-negative integer rate per numeric trainer class 0..128, keyed by
-- that class identity. The source table order is not numeric order; this
-- projection is keyed so consumers never depend on row position. The
-- battle consequence planner and the trainer compiler are the only
-- readers; no other module carries a copy of these rates.
---@type table<integer, integer>
BattleSources.prizeMoneyRates = {
  [0] = 0, [1] = 0, [2] = 4, [3] = 4, [4] = 4, [5] = 4, [6] = 4, [7] = 8,
  [8] = 4, [9] = 8, [10] = 4, [11] = 8, [12] = 8, [13] = 8, [14] = 6, [15] = 12,
  [16] = 12, [17] = 12, [18] = 4, [19] = 8, [20] = 16, [21] = 16, [22] = 2, [23] = 16,
  [24] = 15, [25] = 15, [26] = 8, [27] = 20, [28] = 2, [29] = 8, [30] = 8, [31] = 8,
  [32] = 40, [33] = 40, [34] = 50, [35] = 50, [36] = 14, [37] = 16, [38] = 10, [39] = 15,
  [40] = 15, [41] = 12, [42] = 4, [43] = 4, [44] = 1, [45] = 1, [46] = 8, [47] = 30,
  [48] = 12, [49] = 8, [50] = 8, [51] = 30, [52] = 6, [53] = 15, [54] = 15, [55] = 10,
  [56] = 8, [57] = 6, [58] = 6, [59] = 10, [60] = 5, [61] = 5, [62] = 10, [63] = 4,
  [64] = 8, [65] = 4, [66] = 30, [67] = 30, [68] = 16, [69] = 8, [70] = 30, [71] = 10,
  [72] = 30, [73] = 30, [74] = 30, [75] = 30, [76] = 30, [77] = 12, [78] = 12, [79] = 12,
  [80] = 8, [81] = 8, [82] = 12, [83] = 8, [84] = 10, [85] = 18, [86] = 50, [87] = 30,
  [88] = 30, [89] = 30, [90] = 30, [91] = 30, [92] = 30, [93] = 30, [94] = 30, [95] = 25,
  [96] = 25, [97] = 0, [98] = 30, [99] = 0, [100] = 0, [101] = 0, [102] = 0, [103] = 30,
  [104] = 30, [105] = 30, [106] = 30, [107] = 30, [108] = 30, [109] = 50, [110] = 40, [111] = 30,
  [112] = 30, [113] = 8, [114] = 20, [115] = 8, [116] = 20, [117] = 10, [118] = 10, [119] = 25,
  [120] = 30, [121] = 30, [122] = 16, [123] = 0, [124] = 45, [125] = 0, [126] = 0, [127] = 0,
  [128] = 0,
}
-- Pinned EncounterData member facts from the retail ROM: the
-- 0xC4-byte member with per-method slot counts and byte offsets of every
-- rate array, level/species array, and replacement field.
BattleSources.encounterSources = {
  memberSize = 0xC4,
  landSlots = 12,
  surfSlots = 5,
  rockSlots = 2,
  rodSlots = 5,
  radioSlots = 2,
  offsets = {
    walkRate = 0,
    surfRate = 1,
    rockRate = 2,
    oldRate = 3,
    goodRate = 4,
    superRate = 5,
    landLevels = 8,
    morning = 20,
    day = 44,
    night = 68,
    radioHoenn = 92,
    radioSinnoh = 96,
    surf = 100,
    rock = 120,
    oldRod = 128,
    goodRod = 148,
    superRod = 164,
    landSwarm = 188,
    surfSwarm = 190,
    nightFish = 192,
    fishSwarm = 194,
  },
}

return BattleSources
