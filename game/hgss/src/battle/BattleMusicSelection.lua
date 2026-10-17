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
---@field trainerClass string? trainer class key behind the class table
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
      if type(inputs.rivalName) == "string" and inputs.rivalName ~= "" then
        param = BattleMusicSelection.TRAINER_CLASSES.RIVAL
      elseif
        type(inputs.trainerClass) == "string" and BattleMusicSelection.TRAINER_CLASSES[inputs.trainerClass] ~= nil
      then
        param = BattleMusicSelection.TRAINER_CLASSES[inputs.trainerClass]
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

return BattleMusicSelection
