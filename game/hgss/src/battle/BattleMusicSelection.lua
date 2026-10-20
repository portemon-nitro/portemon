-- Source battle-music selection behind one launch: the wild
-- special-species table, the trainer-class table, and the
-- transition/music row table behind pret/pokeheartgold
-- asm/unk_020517A4.s (9d8b7591f09b65804da2fb2dfd56f320633e0d36),
-- resolved to normalized sequence symbols. Pure data and pure
-- functions; no I/O, no randomness, no display-string inference. The
-- launch passes immutable setup facts; tests pin every row directly
-- through an explicit setup parameter alongside the derived paths.

---@class BattleMusicSelection
local BattleMusicSelection = {}

-- Wild special-species parameters in source order: beasts, the tower
-- pair, the ancient trio, and the Kanto guests. Any other wild species
-- keeps the ordinary wild parameter.
BattleMusicSelection.SPECIAL_SPECIES = {
  RAIKOU = 22,
  ENTEI = 23,
  SUICUNE = 24,
  HO_OH = 25,
  LUGIA = 26,
  GROUDON = 27,
  KYOGRE = 27,
  RAYQUAZA = 27,
  MEWTWO = 28,
  LATIOS = 28,
  LATIAS = 28,
}

-- Trainer-class parameters in source order: gym leaders, the elite
-- four, the champion, the rival, the rocket executives and grunts, the
-- kimono girl, and Red. Any other trainer class keeps the ordinary
-- trainer parameter.
BattleMusicSelection.TRAINER_CLASSES = {
  LEADER_FALKNER = 0,
  LEADER_BUGSY = 1,
  LEADER_WHITNEY = 2,
  LEADER_MORTY = 3,
  LEADER_JASMINE = 4,
  LEADER_CHUCK = 5,
  LEADER_PRYCE = 6,
  LEADER_CLAIR = 7,
  LEADER_BROCK = 8,
  LEADER_MISTY = 9,
  LEADER_LT_SURGE = 10,
  LEADER_ERIKA = 11,
  LEADER_JANINE = 12,
  LEADER_SABRINA = 13,
  LEADER_BLAINE = 14,
  LEADER_BLUE = 15,
  ELITE_FOUR_WILL = 16,
  ELITE_FOUR_KOGA = 17,
  ELITE_FOUR_BRUNO = 18,
  ELITE_FOUR_KAREN = 19,
  CHAMPION = 20,
  RIVAL = 21,
  PASSERBY = 21,
  EXECUTIVE_PROTON = 31,
  EXECUTIVE_PETREL = 30,
  EXECUTIVE_ARCHER = 32,
  EXECUTIVE_ARIANA = 33,
  ROCKET_BOSS = 34,
  TEAM_ROCKET = 29,
  TEAM_ROCKET_F = 29,
  KIMONO_GIRL = 43,
  PKMN_TRAINER_RED = 44,
}

-- Numeric trainer-class identities behind the class table, derived from the
-- pinned producer inventory (romdump/src/config/BattleSources.lua
-- trainerClassKeys): the header byte of the native 20-byte trainer record
-- behind each TRAINERCLASS_* symbol in include/constants/trainer_class.h
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36). Phone
-- contact aliases never enter battles and stay out; Kanto variants keep
-- their own distinct identities. A numeric class resolves to its semantic
-- key before the class table; an identity outside this table keeps the
-- ordinary trainer default below.
BattleMusicSelection.TRAINER_CLASS_KEYS = {
  [0] = "PKMN_TRAINER_ETHAN",
  [1] = "PKMN_TRAINER_LYRA",
  [2] = "YOUNGSTER",
  [3] = "LASS",
  [4] = "CAMPER",
  [5] = "PICNICKER",
  [6] = "BUG_CATCHER",
  [7] = "AROMA_LADY",
  [8] = "TWINS",
  [9] = "HIKER",
  [10] = "BATTLE_GIRL",
  [11] = "FISHERMAN",
  [12] = "CYCLIST_M",
  [13] = "CYCLIST_F",
  [14] = "BLACK_BELT",
  [15] = "ARTIST",
  [16] = "PKMN_BREEDER_M",
  [17] = "PKMN_BREEDER_F",
  [18] = "COWGIRL",
  [19] = "JOGGER",
  [20] = "POKEFAN_M",
  [21] = "POKEFAN",
  [22] = "POKE_KID",
  [23] = "RIVAL",
  [24] = "ACE_TRAINER_M",
  [25] = "ACE_TRAINER_F",
  [26] = "WAITRESS",
  [27] = "VETERAN",
  [28] = "NINJA_BOY",
  [29] = "DRAGON_TAMER",
  [30] = "BIRD_KEEPER",
  [31] = "JUGGLER",
  [32] = "RICH_BOY",
  [33] = "LADY",
  [34] = "GENTLEMAN",
  [35] = "SOCIALITE",
  [36] = "BEAUTY",
  [37] = "COLLECTOR",
  [38] = "POLICEMAN",
  [39] = "PKMN_RANGER_M",
  [40] = "PKMN_RANGER_F",
  [41] = "SCIENTIST",
  [42] = "SWIMMER_M",
  [43] = "SWIMMER_F",
  [44] = "TUBER_M",
  [45] = "TUBER_F",
  [46] = "SAILOR",
  [47] = "KIMONO_GIRL",
  [48] = "RUIN_MANIAC",
  [49] = "PSYCHIC_M",
  [50] = "PSYCHIC_F",
  [51] = "PI",
  [52] = "GUITARIST",
  [53] = "ACE_TRAINER_M_GS",
  [54] = "ACE_TRAINER_F_GS",
  [55] = "TEAM_ROCKET",
  [56] = "SKIER",
  [57] = "ROUGHNECK",
  [58] = "CLOWN",
  [59] = "WORKER",
  [60] = "SCHOOL_KID_M",
  [61] = "SCHOOL_KID_F",
  [62] = "TEAM_ROCKET_F",
  [63] = "BURGLAR",
  [64] = "FIREBREATHER",
  [65] = "BIKER",
  [66] = "LEADER_FALKNER",
  [67] = "LEADER_BUGSY",
  [68] = "POKE_MANIAC",
  [69] = "BIRD_KEEPER_GS",
  [70] = "LEADER_WHITNEY",
  [71] = "RANCHER",
  [72] = "LEADER_MORTY",
  [73] = "LEADER_PRYCE",
  [74] = "LEADER_JASMINE",
  [75] = "LEADER_CHUCK",
  [76] = "LEADER_CLAIR",
  [77] = "TEACHER",
  [78] = "SUPER_NERD",
  [79] = "SAGE",
  [80] = "PARASOL_LADY",
  [81] = "WAITER",
  [82] = "MEDIUM",
  [83] = "CAMERAMAN",
  [84] = "REPORTER",
  [85] = "IDOL",
  [86] = "CHAMPION",
  [87] = "ELITE_FOUR_WILL",
  [88] = "ELITE_FOUR_KAREN",
  [89] = "ELITE_FOUR_KOGA",
  [90] = "PKMN_TRAINER_CHERYL",
  [91] = "PKMN_TRAINER_RILEY",
  [92] = "PKMN_TRAINER_BUCK",
  [93] = "PKMN_TRAINER_MIRA",
  [94] = "PKMN_TRAINER_MARLEY",
  [95] = "PKMN_TRAINER_FTR_LUCAS",
  [96] = "PKMN_TRAINER_FTR_DAWN",
  [97] = "TOWER_TYCOON",
  [98] = "LEADER_BROCK",
  [99] = "HALL_MATRON",
  [100] = "FACTORY_HEAD",
  [101] = "ARCADE_STAR",
  [102] = "CASTLE_VALET",
  [103] = "LEADER_MISTY",
  [104] = "LEADER_LT_SURGE",
  [105] = "LEADER_ERIKA",
  [106] = "LEADER_JANINE",
  [107] = "LEADER_SABRINA",
  [108] = "LEADER_BLAINE",
  [109] = "PKMN_TRAINER_RED",
  [110] = "LEADER_BLUE",
  [111] = "ELDER",
  [112] = "ELITE_FOUR_BRUNO",
  [113] = "SCIENTIST_GS",
  [114] = "EXECUTIVE_ARIANA",
  [115] = "BOARDER",
  [116] = "EXECUTIVE_ARCHER",
  [117] = "EXECUTIVE_PROTON",
  [118] = "EXECUTIVE_PETREL",
  [119] = "PASSERBY",
  [120] = "MYSTERY_MAN",
  [121] = "DOUBLE_TEAM",
  [122] = "YOUNG_COUPLE",
  [123] = "PKMN_TRAINER_LANCE",
  [124] = "ROCKET_BOSS",
  [125] = "PKMN_TRAINER_LUCAS_DP",
  [126] = "PKMN_TRAINER_DAWN_DP",
  [127] = "PKMN_TRAINER_LUCAS_PT",
  [128] = "PKMN_TRAINER_DAWN_PT",
}

-- Resolves one numeric native trainer class to its semantic key behind the
-- class table. Identities outside the pinned table answer nil so the
-- caller keeps the designed unknown path instead of guessing a name.
---@param classId number? numeric native trainer class
---@return string? semantic trainer class key, nil when genuinely absent
function BattleMusicSelection.trainerClassName(classId)
  if type(classId) == "number" and classId % 1 == 0 then
    return BattleMusicSelection.TRAINER_CLASS_KEYS[classId]
  end
  return nil
end

-- Setup parameters behind the row table: the ordinary wild and trainer
-- defaults the source falls back to outside both tables.
BattleMusicSelection.WILD_DEFAULT = 42
BattleMusicSelection.TRAINER_DEFAULT = 41

-- Transition/music rows by setup parameter: the transition route the
-- encounter effect consumes and the battle-music sequence symbol the
-- audio voice starts. A nil transition marks the special-transition
-- rows the transition owner resolves.
---@type table<integer, { transition: integer?, music: string }>
BattleMusicSelection.PARAM_TRACKS = {
  [0] = { transition = 12, music = "SEQ_GS_VS_GYMREADER" },
  [1] = { transition = 13, music = "SEQ_GS_VS_GYMREADER" },
  [2] = { transition = 14, music = "SEQ_GS_VS_GYMREADER" },
  [3] = { transition = 15, music = "SEQ_GS_VS_GYMREADER" },
  [4] = { transition = 16, music = "SEQ_GS_VS_GYMREADER" },
  [5] = { transition = 17, music = "SEQ_GS_VS_GYMREADER" },
  [6] = { transition = 18, music = "SEQ_GS_VS_GYMREADER" },
  [7] = { transition = 19, music = "SEQ_GS_VS_GYMREADER" },
  [8] = { transition = 20, music = "SEQ_GS_VS_GYMREADER_KANTO" },
  [9] = { transition = 21, music = "SEQ_GS_VS_GYMREADER_KANTO" },
  [10] = { transition = 22, music = "SEQ_GS_VS_GYMREADER_KANTO" },
  [11] = { transition = 23, music = "SEQ_GS_VS_GYMREADER_KANTO" },
  [12] = { transition = 24, music = "SEQ_GS_VS_GYMREADER_KANTO" },
  [13] = { transition = 25, music = "SEQ_GS_VS_GYMREADER_KANTO" },
  [14] = { transition = 26, music = "SEQ_GS_VS_GYMREADER_KANTO" },
  [15] = { transition = 27, music = "SEQ_GS_VS_GYMREADER_KANTO" },
  [16] = { transition = 29, music = "SEQ_GS_VS_GYMREADER" },
  [17] = { transition = 30, music = "SEQ_GS_VS_GYMREADER" },
  [18] = { transition = 31, music = "SEQ_GS_VS_GYMREADER" },
  [19] = { transition = 32, music = "SEQ_GS_VS_GYMREADER" },
  [20] = { transition = 33, music = "SEQ_GS_VS_CHAMP" },
  [21] = { transition = 28, music = "SEQ_GS_VS_RIVAL" },
  [22] = { transition = nil, music = "SEQ_GS_VS_RAIKOU" },
  [23] = { transition = nil, music = "SEQ_GS_VS_ENTEI" },
  [24] = { transition = nil, music = "SEQ_GS_VS_SUICUNE" },
  [25] = { transition = 35, music = "SEQ_GS_VS_HOUOU" },
  [26] = { transition = 36, music = "SEQ_GS_VS_LUGIA" },
  [27] = { transition = 34, music = "SEQ_GS_VS_KODAI" },
  [28] = { transition = 34, music = "SEQ_GS_VS_NORAPOKE_KANTO" },
  [29] = { transition = 39, music = "SEQ_GS_VS_ROCKET" },
  [30] = { transition = 40, music = "SEQ_GS_VS_ROCKET" },
  [31] = { transition = 41, music = "SEQ_GS_VS_ROCKET" },
  [32] = { transition = 42, music = "SEQ_GS_VS_ROCKET" },
  [33] = { transition = 43, music = "SEQ_GS_VS_ROCKET" },
  [34] = { transition = 44, music = "SEQ_GS_VS_ROCKET" },
  [35] = { transition = 37, music = "SEQ_GS_VS_TRAINER" },
  [36] = { transition = 37, music = "SEQ_GS_VS_TRAINER" },
  [37] = { transition = 38, music = "SEQ_GS_VS_TRAINER" },
  [38] = { transition = 38, music = "SEQ_GS_VS_NORAPOKE" },
  [39] = { transition = 37, music = "SEQ_GS_BA_BRAIN" },
  [40] = { transition = 38, music = "SEQ_GS_VS_GYMREADER" },
  [41] = { transition = nil, music = "SEQ_GS_VS_TRAINER" },
  [42] = { transition = nil, music = "SEQ_GS_VS_NORAPOKE" },
  [43] = { transition = 45, music = "SEQ_GS_VS_TRAINER" },
  [44] = { transition = 46, music = "SEQ_GS_VS_CHAMP" },
}

-- Kanto regional remaps behind the wild music override: ordinary wild,
-- trainer, and gym-leader tracks recorded in Johto become their Kanto
-- counterparts while the region flag stands.
BattleMusicSelection.KANTO_REMAPPED = {
  SEQ_GS_VS_NORAPOKE = "SEQ_GS_VS_NORAPOKE_KANTO",
  SEQ_GS_VS_TRAINER = "SEQ_GS_VS_TRAINER_KANTO",
  SEQ_GS_VS_GYMREADER = "SEQ_GS_VS_GYMREADER_KANTO",
}

---@class BattleMusicSelection.Inputs
---@field kind string "wild" or "trainer" launch kind behind the lookup
---@field species string? wild species key behind the special-species table
---@field trainerClass string|number? trainer class key or numeric native class behind the class table
---@field rivalName string? non-empty rival override behind the rival track
---@field region string? "KANTO" behind the regional override, anything else ordinary
---@field setupParam integer? explicit native setup parameter behind direct row selection

-- Selects the battle-music track for one launch: an explicit setup
-- parameter selects its row directly; otherwise the wild
-- special-species table wins first, then the trainer class table with
-- the rival override, then the ordinary kind default; the Kanto region
-- remaps the three ordinary recorded tracks last.
---@param inputs BattleMusicSelection.Inputs immutable setup facts behind the lookup
---@return { music: string, transition: integer?, param: integer } selected track, transition route, and setup parameter
function BattleMusicSelection.select(inputs)
  assert(type(inputs) == "table", "battle music selection needs its setup facts")
  local param = inputs.setupParam
  if param == nil then
    if inputs.kind == "wild" then
      param = BattleMusicSelection.WILD_DEFAULT
      if type(inputs.species) == "string" and BattleMusicSelection.SPECIAL_SPECIES[inputs.species] ~= nil then
        param = BattleMusicSelection.SPECIAL_SPECIES[inputs.species]
      end
    else
      param = BattleMusicSelection.TRAINER_DEFAULT
      local trainerClass = inputs.trainerClass
      if type(trainerClass) == "number" then
        trainerClass = BattleMusicSelection.trainerClassName(trainerClass)
      end
      if type(inputs.rivalName) == "string" and inputs.rivalName ~= "" then
        param = BattleMusicSelection.TRAINER_CLASSES.RIVAL
      elseif type(trainerClass) == "string" and BattleMusicSelection.TRAINER_CLASSES[trainerClass] ~= nil then
        param = BattleMusicSelection.TRAINER_CLASSES[trainerClass]
      end
    end
  end
  assert(
    type(param) == "number" and param % 1 == 0 and param >= 0 and param <= 44,
    "battle music selection resolves a setup parameter in 0..44"
  )
  local row = BattleMusicSelection.PARAM_TRACKS[param]
  assert(type(row) == "table", "battle music selection covers every setup parameter")
  local music = row.music --[[@as string]]
  if inputs.region == "KANTO" and BattleMusicSelection.KANTO_REMAPPED[music] ~= nil then
    music = BattleMusicSelection.KANTO_REMAPPED[music]
  end
  return { music = music, transition = row.transition, param = param }
end

-- Victory BGM behind the result handoff: native battle victory is a plain
-- BGM swap (PlayBGM), never a fanfare. Wild wins voice SEQ_GS_WIN2
-- (battle_command.c exp-gain and capture-gotcha paths); regular trainer
-- wins SEQ_GS_WIN1; gym leaders, the champion, and the elite four voice
-- SEQ_GS_WIN3; frontier brains voice SEQ_GS_WINBRAIN
-- (battle_controller_player.c class switch). The class sets below name
-- the native TRAINERCLASS_* identities behind those switch arms.
BattleMusicSelection.VICTORY_LEADER_CLASSES = {
  LEADER_FALKNER = true,
  LEADER_BUGSY = true,
  LEADER_WHITNEY = true,
  LEADER_MORTY = true,
  LEADER_PRYCE = true,
  LEADER_JASMINE = true,
  LEADER_CHUCK = true,
  LEADER_CLAIR = true,
  LEADER_BROCK = true,
  LEADER_MISTY = true,
  LEADER_LT_SURGE = true,
  LEADER_ERIKA = true,
  LEADER_JANINE = true,
  LEADER_SABRINA = true,
  LEADER_BLAINE = true,
  LEADER_BLUE = true,
  CHAMPION = true,
  ELITE_FOUR_WILL = true,
  ELITE_FOUR_KAREN = true,
  ELITE_FOUR_KOGA = true,
  ELITE_FOUR_BRUNO = true,
}

BattleMusicSelection.VICTORY_BRAIN_CLASSES = {
  TOWER_TYCOON = true,
  HALL_MATRON = true,
  FACTORY_HEAD = true,
  ARCADE_STAR = true,
  CASTLE_VALET = true,
}

-- Selects the victory BGM symbol behind one result: wild launches voice
-- the wild win; trainer launches route by native class (leaders WIN3,
-- brains WINBRAIN, everything else — including the rival and Red — the
-- WIN1 default). Numeric classes resolve through the pinned key table;
-- unresolvable classes keep the default instead of guessing a track.
---@param kind string "wild" or "trainer" launch kind behind the lookup
---@param trainerClass string|number? trainer class key or numeric native class
---@return string victory BGM sequence symbol
function BattleMusicSelection.victoryMusicSymbol(kind, trainerClass)
  if kind ~= "trainer" then
    return "SEQ_GS_WIN2"
  end
  local name = trainerClass
  if type(name) == "number" then
    name = BattleMusicSelection.trainerClassName(name)
  end
  if type(name) == "string" and BattleMusicSelection.VICTORY_LEADER_CLASSES[name] == true then
    return "SEQ_GS_WIN3"
  end
  if type(name) == "string" and BattleMusicSelection.VICTORY_BRAIN_CLASSES[name] == true then
    return "SEQ_GS_WINBRAIN"
  end
  return "SEQ_GS_WIN1"
end

return BattleMusicSelection
