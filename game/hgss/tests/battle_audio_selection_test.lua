-- Source battle-music selection behind one launch: the complete
-- setup-parameter matrix, the wild special-species and trainer-class
-- derivation with their precedence, and the Kanto regional override.
-- Synthetic setup facts only: no ROM, no battle runtime.

local Assert = require("tests.support.Assert")
local BattleMusicSelection = require("game.hgss.src.battle.BattleMusicSelection")

local T = {}

function T.every_setup_row_selects_its_transition_and_track()
  local expected = {
    [0] = { 12, "SEQ_GS_VS_GYMREADER" },
    [1] = { 13, "SEQ_GS_VS_GYMREADER" },
    [2] = { 14, "SEQ_GS_VS_GYMREADER" },
    [3] = { 15, "SEQ_GS_VS_GYMREADER" },
    [4] = { 16, "SEQ_GS_VS_GYMREADER" },
    [5] = { 17, "SEQ_GS_VS_GYMREADER" },
    [6] = { 18, "SEQ_GS_VS_GYMREADER" },
    [7] = { 19, "SEQ_GS_VS_GYMREADER" },
    [8] = { 20, "SEQ_GS_VS_GYMREADER_KANTO" },
    [9] = { 21, "SEQ_GS_VS_GYMREADER_KANTO" },
    [10] = { 22, "SEQ_GS_VS_GYMREADER_KANTO" },
    [11] = { 23, "SEQ_GS_VS_GYMREADER_KANTO" },
    [12] = { 24, "SEQ_GS_VS_GYMREADER_KANTO" },
    [13] = { 25, "SEQ_GS_VS_GYMREADER_KANTO" },
    [14] = { 26, "SEQ_GS_VS_GYMREADER_KANTO" },
    [15] = { 27, "SEQ_GS_VS_GYMREADER_KANTO" },
    [16] = { 29, "SEQ_GS_VS_GYMREADER" },
    [17] = { 30, "SEQ_GS_VS_GYMREADER" },
    [18] = { 31, "SEQ_GS_VS_GYMREADER" },
    [19] = { 32, "SEQ_GS_VS_GYMREADER" },
    [20] = { 33, "SEQ_GS_VS_CHAMP" },
    [21] = { 28, "SEQ_GS_VS_RIVAL" },
    [22] = { nil, "SEQ_GS_VS_RAIKOU" },
    [23] = { nil, "SEQ_GS_VS_ENTEI" },
    [24] = { nil, "SEQ_GS_VS_SUICUNE" },
    [25] = { 35, "SEQ_GS_VS_HOUOU" },
    [26] = { 36, "SEQ_GS_VS_LUGIA" },
    [27] = { 34, "SEQ_GS_VS_KODAI" },
    [28] = { 34, "SEQ_GS_VS_NORAPOKE_KANTO" },
    [29] = { 39, "SEQ_GS_VS_ROCKET" },
    [30] = { 40, "SEQ_GS_VS_ROCKET" },
    [31] = { 41, "SEQ_GS_VS_ROCKET" },
    [32] = { 42, "SEQ_GS_VS_ROCKET" },
    [33] = { 43, "SEQ_GS_VS_ROCKET" },
    [34] = { 44, "SEQ_GS_VS_ROCKET" },
    [35] = { 37, "SEQ_GS_VS_TRAINER" },
    [36] = { 37, "SEQ_GS_VS_TRAINER" },
    [37] = { 38, "SEQ_GS_VS_TRAINER" },
    [38] = { 38, "SEQ_GS_VS_NORAPOKE" },
    [39] = { 37, "SEQ_GS_BA_BRAIN" },
    [40] = { 38, "SEQ_GS_VS_GYMREADER" },
    [41] = { nil, "SEQ_GS_VS_TRAINER" },
    [42] = { nil, "SEQ_GS_VS_NORAPOKE" },
    [43] = { 45, "SEQ_GS_VS_TRAINER" },
    [44] = { 46, "SEQ_GS_VS_CHAMP" },
  }
  for param = 0, 44 do
    local selected = BattleMusicSelection.select({ kind = "wild", setupParam = param })
    local want = expected[param]
    Assert.equal(selected.param, param, "row " .. param .. " keeps its parameter")
    Assert.equal(selected.transition, want[1], "row " .. param .. " keeps its transition route")
    Assert.equal(selected.music, want[2], "row " .. param .. " keeps its track")
  end
  local badLow = pcall(BattleMusicSelection.select, { kind = "wild", setupParam = -1 })
  Assert.isFalse(badLow, "parameters below the matrix never select")
  local badHigh = pcall(BattleMusicSelection.select, { kind = "wild", setupParam = 45 })
  Assert.isFalse(badHigh, "parameters above the matrix never select")
end

function T.wild_encounters_prefer_the_special_species_table()
  local ordinary = BattleMusicSelection.select({ kind = "wild", species = "CATERPIE" })
  Assert.equal(ordinary.music, "SEQ_GS_VS_NORAPOKE", "ordinary wild encounters keep the wild track")
  Assert.equal(ordinary.param, 42, "ordinary wild encounters keep the wild parameter")
  for species, param in pairs(BattleMusicSelection.SPECIAL_SPECIES) do
    local selected = BattleMusicSelection.select({ kind = "wild", species = species })
    Assert.equal(selected.param, param, "special species " .. species .. " keeps its parameter")
    Assert.equal(
      selected.music,
      BattleMusicSelection.PARAM_TRACKS[param].music,
      "special species " .. species .. " keeps its track"
    )
    Assert.isTrue(selected.music ~= "SEQ_GS_VS_NORAPOKE", "special species never collapse onto the wild track")
  end
  local lugia = BattleMusicSelection.select({ kind = "wild", species = "LUGIA" })
  Assert.equal(lugia.music, "SEQ_GS_VS_LUGIA", "the lugia encounter keeps its own track")
end

function T.trainer_encounters_prefer_class_then_rival_then_default()
  local ordinary = BattleMusicSelection.select({ kind = "trainer" })
  Assert.equal(ordinary.music, "SEQ_GS_VS_TRAINER", "ordinary trainers keep the trainer track")
  Assert.equal(ordinary.param, 41, "ordinary trainers keep the trainer parameter")
  for class, param in pairs(BattleMusicSelection.TRAINER_CLASSES) do
    if class ~= "RIVAL" and class ~= "PASSERBY" then
      local selected = BattleMusicSelection.select({ kind = "trainer", trainerClass = class })
      Assert.equal(selected.param, param, "trainer class " .. class .. " keeps its parameter")
    end
  end
  local rival = BattleMusicSelection.select({ kind = "trainer", trainerClass = "LEADER_FALKNER", rivalName = "RIVAL" })
  Assert.equal(rival.music, "SEQ_GS_VS_RIVAL", "the rival override wins over the class table")
  Assert.equal(rival.param, 21, "the rival override keeps the rival parameter")
  local blankRival = BattleMusicSelection.select({ kind = "trainer", trainerClass = "RIVAL", rivalName = "" })
  Assert.equal(blankRival.param, 21, "the rival class keeps its parameter without an override name")
  local rocket = BattleMusicSelection.select({ kind = "trainer", trainerClass = "TEAM_ROCKET" })
  Assert.equal(rocket.music, "SEQ_GS_VS_ROCKET", "rocket grunts keep the rocket track")
  local red = BattleMusicSelection.select({ kind = "trainer", trainerClass = "PKMN_TRAINER_RED" })
  Assert.equal(red.music, "SEQ_GS_VS_CHAMP", "the final challenge keeps the champion track")
end

function T.numeric_trainer_classes_resolve_through_the_source_identity_table()
  local Sources = require("romdump.src.config.BattleSources")
  for id = 0, 128 do
    Assert.equal(
      BattleMusicSelection.TRAINER_CLASS_KEYS[id],
      Sources.trainerClassKeys[id],
      "numeric class " .. id .. " keeps its pinned semantic identity"
    )
  end
  Assert.equal(BattleMusicSelection.trainerClassName(66), "LEADER_FALKNER", "the first leader identity resolves")
  Assert.equal(BattleMusicSelection.trainerClassName(23), "RIVAL", "the rival identity resolves")
  Assert.isNil(BattleMusicSelection.trainerClassName(129), "identities outside the table stay unmapped")
  Assert.isNil(BattleMusicSelection.trainerClassName(200), "phone aliases stay unmapped")
end

function T.numeric_trainer_classes_select_their_precise_two_hop_tracks()
  local falkner = BattleMusicSelection.select({ kind = "trainer", trainerClass = 66 })
  Assert.equal(falkner.param, 0, "the numeric leader keeps the leader parameter")
  Assert.equal(falkner.music, "SEQ_GS_VS_GYMREADER", "the numeric leader keeps the leader track")
  local rival = BattleMusicSelection.select({ kind = "trainer", trainerClass = 23 })
  Assert.equal(rival.param, 21, "the numeric rival keeps the rival parameter")
  Assert.equal(rival.music, "SEQ_GS_VS_RIVAL", "the numeric rival keeps the rival track")
  local rocket = BattleMusicSelection.select({ kind = "trainer", trainerClass = 55 })
  Assert.equal(rocket.param, 29, "the numeric grunt keeps the grunt parameter")
  Assert.equal(rocket.music, "SEQ_GS_VS_ROCKET", "the numeric grunt keeps the rocket track")
  local kimono = BattleMusicSelection.select({ kind = "trainer", trainerClass = 47 })
  Assert.equal(kimono.param, 43, "the numeric kimono girl keeps her parameter")
  local red = BattleMusicSelection.select({ kind = "trainer", trainerClass = 109 })
  Assert.equal(red.param, 44, "the numeric final challenge keeps its parameter")
  Assert.equal(red.music, "SEQ_GS_VS_CHAMP", "the numeric final challenge keeps the champion track")
  local youngster = BattleMusicSelection.select({ kind = "trainer", trainerClass = 2 })
  Assert.equal(youngster.param, 41, "ordinary numeric classes keep the trainer default")
  Assert.equal(youngster.music, "SEQ_GS_VS_TRAINER", "ordinary numeric classes keep the trainer track")
  local absent = BattleMusicSelection.select({ kind = "trainer", trainerClass = 129 })
  Assert.equal(absent.param, BattleMusicSelection.TRAINER_DEFAULT, "absent numeric classes keep the unknown path")
  Assert.equal(absent.music, "SEQ_GS_VS_TRAINER", "absent numeric classes keep the unknown track")
end

function T.kanto_region_remaps_only_the_recorded_tracks()
  local wildKanto = BattleMusicSelection.select({ kind = "wild", species = "CATERPIE", region = "KANTO" })
  Assert.equal(wildKanto.music, "SEQ_GS_VS_NORAPOKE_KANTO", "kanto wild encounters remap the wild track")
  local trainerKanto = BattleMusicSelection.select({ kind = "trainer", region = "KANTO" })
  Assert.equal(trainerKanto.music, "SEQ_GS_VS_TRAINER_KANTO", "kanto trainers remap the trainer track")
  local gymKanto =
    BattleMusicSelection.select({ kind = "trainer", trainerClass = "LEADER_FALKNER", region = "KANTO" })
  Assert.equal(gymKanto.music, "SEQ_GS_VS_GYMREADER_KANTO", "kanto leaders remap the leader track")
  local lugiaKanto = BattleMusicSelection.select({ kind = "wild", species = "LUGIA", region = "KANTO" })
  Assert.equal(lugiaKanto.music, "SEQ_GS_VS_LUGIA", "special tracks ignore the regional remap")
  local wildHome = BattleMusicSelection.select({ kind = "wild", species = "CATERPIE", region = "JOHTO" })
  Assert.equal(wildHome.music, "SEQ_GS_VS_NORAPOKE", "other regions keep the recorded track")
end

function T.victory_music_follows_the_native_trainer_class_routing()
  -- Native battle victory is a plain BGM swap (PlayBGM): wild wins voice
  -- SEQ_GS_WIN2 (battle_command.c exp-gain and capture-gotcha paths),
  -- regular trainer wins SEQ_GS_WIN1, gym leaders/champion/elite-four
  -- SEQ_GS_WIN3, and frontier brains SEQ_GS_WINBRAIN
  -- (battle_controller_player.c class switch). The old wild->WIN1 /
  -- trainer->WIN2 fanfare mapping was transposed on both axes.
  local select = BattleMusicSelection.victoryMusicSymbol
  Assert.equal(select("wild", nil), "SEQ_GS_WIN2", "wild wins keep the wild-win BGM")
  Assert.equal(select("trainer", nil), "SEQ_GS_WIN1", "trainers default to WIN1")
  Assert.equal(select("trainer", "YOUNGSTER"), "SEQ_GS_WIN1", "ordinary classes keep WIN1")
  Assert.equal(select("trainer", "RIVAL"), "SEQ_GS_WIN1", "the rival is not a WIN3 class")
  Assert.equal(select("trainer", "PKMN_TRAINER_RED"), "SEQ_GS_WIN1", "Red keeps the native default")
  Assert.equal(select("trainer", 2), "SEQ_GS_WIN1", "numeric ordinary classes keep WIN1")
  Assert.equal(select("trainer", 99999), "SEQ_GS_WIN1", "unresolvable classes keep the default")
  for _, leader in ipairs({
    "LEADER_FALKNER",
    "LEADER_BUGSY",
    "LEADER_WHITNEY",
    "LEADER_MORTY",
    "LEADER_PRYCE",
    "LEADER_JASMINE",
    "LEADER_CHUCK",
    "LEADER_CLAIR",
    "LEADER_BROCK",
    "LEADER_MISTY",
    "LEADER_LT_SURGE",
    "LEADER_ERIKA",
    "LEADER_JANINE",
    "LEADER_SABRINA",
    "LEADER_BLAINE",
    "LEADER_BLUE",
    "CHAMPION",
    "ELITE_FOUR_WILL",
    "ELITE_FOUR_KAREN",
    "ELITE_FOUR_KOGA",
    "ELITE_FOUR_BRUNO",
  }) do
    Assert.equal(select("trainer", leader), "SEQ_GS_WIN3", leader .. " voices the leader victory BGM")
  end
  for _, brain in ipairs({
    "TOWER_TYCOON",
    "HALL_MATRON",
    "FACTORY_HEAD",
    "ARCADE_STAR",
    "CASTLE_VALET",
  }) do
    Assert.equal(select("trainer", brain), "SEQ_GS_WINBRAIN", brain .. " voices the frontier-brain victory BGM")
  end
  Assert.equal(select("trainer", 66), "SEQ_GS_WIN3", "numeric leader classes route by identity")
end

return { tests = T }
