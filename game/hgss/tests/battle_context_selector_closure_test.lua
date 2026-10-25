-- Complete selector and state coverage for the battle presentation
-- context matrix: music/transition derivation with precedence, the
-- transition fallback formula, the source menu-mode branch, the
-- background/terrain/time namespace distinction, and the terrain resource
-- inventory. Pure data and pure functions only: no screen, no dump
-- capability. Passing tests pin implemented source branches; the terrain
-- inventory tests fail on their final assertion because the additional
-- facility/giratina terrain members are absent from the catalog.

local Assert = require("tests.support.Assert")
local BattleMusicSelection = require("game.hgss.src.battle.BattleMusicSelection")
local Sources = require("romdump.src.config.BattlePresentationSources")

local T = {}

-- The source-defined default is its own explicit path: an omitted
-- parameter resolves exactly the ordinary default, while a parameter
-- outside the matrix fails instead of silently choosing that default.
function T.unknown_setup_values_never_silently_choose_the_default()
  local wildDefault = BattleMusicSelection.select({ kind = "wild" })
  Assert.equal(wildDefault.param, BattleMusicSelection.WILD_DEFAULT, "wild encounters keep the wild default")
  local wildExplicit = BattleMusicSelection.select({ kind = "wild", setupParam = BattleMusicSelection.WILD_DEFAULT })
  Assert.equal(wildExplicit.music, wildDefault.music, "the explicit default row matches the derived default")
  Assert.equal(wildExplicit.transition, wildDefault.transition, "the explicit default keeps the default route")
  local trainerDefault = BattleMusicSelection.select({ kind = "trainer" })
  Assert.equal(trainerDefault.param, BattleMusicSelection.TRAINER_DEFAULT, "trainers keep the trainer default")
  local unknownClass = BattleMusicSelection.select({ kind = "trainer", trainerClass = "NO_SUCH_CLASS" })
  Assert.equal(unknownClass.param, BattleMusicSelection.TRAINER_DEFAULT, "unknown classes keep the explicit default")
  local unknownSpecies = BattleMusicSelection.select({ kind = "wild", species = "NO_SUCH_SPECIES" })
  Assert.equal(unknownSpecies.param, BattleMusicSelection.WILD_DEFAULT, "unknown species keep the explicit default")
  Assert.isFalse(
    pcall(BattleMusicSelection.select, { kind = "wild", setupParam = -1 }),
    "parameters below the matrix never select"
  )
  Assert.isFalse(
    pcall(BattleMusicSelection.select, { kind = "wild", setupParam = 45 }),
    "parameters above the matrix never select"
  )
end

-- Derivation precedence: the wild special-species table wins for wild
-- launches, the rival-name override wins over any trainer class, and an
-- explicit parameter wins over both derivations.
function T.music_derivation_keeps_its_source_precedence()
  local legendary = BattleMusicSelection.select({ kind = "wild", species = "LUGIA" })
  Assert.equal(legendary.param, BattleMusicSelection.SPECIAL_SPECIES.LUGIA, "special wild species keep their parameter")
  local rivalNamed = BattleMusicSelection.select({ kind = "trainer", trainerClass = "LEADER_FALKNER", rivalName = "X" })
  Assert.equal(
    rivalNamed.param,
    BattleMusicSelection.TRAINER_CLASSES.RIVAL,
    "the rival-name override wins over the trainer class"
  )
  local gym = BattleMusicSelection.select({ kind = "trainer", trainerClass = "LEADER_FALKNER" })
  Assert.equal(
    gym.param,
    BattleMusicSelection.TRAINER_CLASSES.LEADER_FALKNER,
    "gym classes keep their own parameter without a rival override"
  )
  local passerby = BattleMusicSelection.select({ kind = "trainer", trainerClass = "PASSERBY" })
  Assert.equal(passerby.music, rivalNamed.music, "passerby encounters share the rival track")
  local explicit = BattleMusicSelection.select({ kind = "wild", species = "LUGIA", setupParam = 0 })
  Assert.equal(explicit.param, 0, "an explicit parameter wins over the species derivation")
end

-- The regional override remaps only the three ordinary recorded tracks:
-- special legendary, rocket, and facility tracks keep their identity in
-- every region.
function T.regional_override_touches_only_the_ordinary_recorded_tracks()
  local wildKanto = BattleMusicSelection.select({ kind = "wild", region = "KANTO" })
  Assert.equal(wildKanto.music, "SEQ_GS_VS_NORAPOKE_KANTO", "ordinary wild music remaps in its region")
  local trainerKanto = BattleMusicSelection.select({ kind = "trainer", region = "KANTO" })
  Assert.equal(trainerKanto.music, "SEQ_GS_VS_TRAINER_KANTO", "ordinary trainer music remaps in its region")
  local gymKanto = BattleMusicSelection.select({ kind = "trainer", trainerClass = "LEADER_FALKNER", region = "KANTO" })
  Assert.equal(gymKanto.music, "SEQ_GS_VS_GYMREADER_KANTO", "gym music remaps in its region")
  local legendaryKanto = BattleMusicSelection.select({ kind = "wild", species = "LUGIA", region = "KANTO" })
  local legendaryHome = BattleMusicSelection.select({ kind = "wild", species = "LUGIA" })
  Assert.equal(legendaryKanto.music, legendaryHome.music, "legendary tracks never remap")
  local rocketKanto = BattleMusicSelection.select({ kind = "trainer", trainerClass = "TEAM_ROCKET", region = "KANTO" })
  local rocketHome = BattleMusicSelection.select({ kind = "trainer", trainerClass = "TEAM_ROCKET" })
  Assert.equal(rocketKanto.music, rocketHome.music, "rocket tracks never remap")
end

-- The fallback formula resolves every terrain/time/trainer combination
-- to its native selector, and unknown axes answer nil instead of a
-- guessed ordinary selector.
function T.transition_fallback_formula_covers_its_axes_without_guessing()
  Assert.equal(Sources.transitionFallbackSelector("plain", "day", false), 0, "plain day wild keeps selector 0")
  Assert.equal(Sources.transitionFallbackSelector("plain", "late", false), 1, "late hours shift the selector by one")
  Assert.equal(Sources.transitionFallbackSelector("water", "day", false), 2, "water shifts the selector by two")
  Assert.equal(Sources.transitionFallbackSelector("cave", "night", false), 5, "cave at night keeps selector 5")
  Assert.equal(Sources.transitionFallbackSelector("plain", "day", true), 6, "trainers shift the selector by six")
  Assert.equal(Sources.transitionFallbackSelector("cave", "night", true), 11, "cave night trainers keep selector 11")
  Assert.isNil(Sources.transitionFallbackSelector("no-such-terrain", "day", false), "unknown terrain never selects")
  Assert.isNil(Sources.transitionFallbackSelector("plain", "dawn", false), "unknown time never selects")
  Assert.isNil(Sources.transitionFallbackSelector("plain", "day", nil), "an untyped trainer bit never selects")
end

-- The source menu-mode branch selects distinct label families per mode
-- with the frontier layout variant and the cancel/run distinction kept
-- explicit; an unknown mode fails instead of falling back to standard.
function T.source_menu_modes_select_distinct_label_families()
  local standard = Sources.menuDisplay("standard", false, false)
  Assert.equal(standard.labels.fight, "label/fight", "standard keeps the fight label")
  Assert.equal(standard.labels.run, "label/run", "standard keeps the run label")
  Assert.equal(standard.layoutVariant, "standard", "non-facility launches keep the standard layout")
  local safari = Sources.menuDisplay("safari", false, false)
  Assert.equal(safari.labels.fight, "label/safari-ball", "safari replaces the fight label")
  Assert.equal(safari.labels.bag, "label/safari-bait", "safari replaces the bag label")
  Assert.equal(safari.labels.pokemon, "label/safari-mud", "safari replaces the third label")
  local park = Sources.menuDisplay("pal-park", false, false)
  Assert.equal(park.labels.fight, "label/pal-park-ball", "pal-park keeps its own ball label")
  local contest = Sources.menuDisplay("bug-contest", false, false)
  Assert.equal(contest.labels.bag, "label/bug-contest-ball", "the contest replaces the ball label")
  Assert.isTrue(#contest.dynamicFields == 3, "the contest carries its ball-count and caught fields")
  local frontier = Sources.menuDisplay("standard", true, false)
  Assert.equal(frontier.layoutVariant, "frontier", "facility launches keep the facility layout variant")
  local cancel = Sources.menuDisplay("standard", false, true)
  Assert.equal(cancel.labels.run, "label/cancel", "cancel contexts replace the run label")
  Assert.isFalse(pcall(Sources.menuDisplay, "no-such-mode", false, false), "unknown menu modes never select")
end

-- Background, terrain, and time are different namespaces: several
-- ordinary values coincide as words but never as identities, so a key
-- that swaps two axes must not parse and a terrain name must not index
-- the background table.
function T.background_terrain_and_time_are_distinct_namespaces()
  local parsed = Sources.parseSceneKey("general/grass/day")
  Assert.notNil(parsed, "an ordinary scene key parses")
  Assert.equal(parsed.background, "general", "the first axis is the background")
  Assert.equal(parsed.terrain, "grass", "the second axis is the terrain")
  Assert.equal(parsed.time, "day", "the third axis is the time")
  Assert.isNil(Sources.parseSceneKey("grass/general/day"), "swapped background and terrain never parse")
  Assert.isNil(Sources.TERRAIN["general"], "a background name never indexes the terrain table")
  Assert.isNil(Sources.backgroundId("grass"), "a terrain name never indexes the background table")
  Assert.isNil(Sources.parseSceneKey("general/grass/dawn"), "unknown times never parse")
  Assert.isNil(Sources.parseSceneKey("general/grass"), "partial keys never parse")
  Assert.isTrue(Sources.validateSceneKey("city/sand/night"), "a second ordinary key validates")
  Assert.isFalse(Sources.validateSceneKey("city/sand/dawn"), "an unknown time never validates")
end

-- The ordinary terrain inventory holds all eighteen ordinals with
-- non-negative members; this setup passes before the additional
-- facility and distortion members below are checked.
function T.ordinary_terrain_inventory_holds_eighteen_complete_ordinals()
  local seen = {}
  local count = 0
  for _, record in pairs(Sources.TERRAIN) do
    count = count + 1
    Assert.isTrue(type(record.ordinal) == "number" and record.ordinal % 1 == 0, "terrain ordinals stay integral")
    Assert.isNil(seen[record.ordinal], "terrain ordinals never repeat")
    seen[record.ordinal] = true
    for _, field in ipairs({ "type0", "type1", "day", "evening", "night" }) do
      Assert.isTrue(type(record[field]) == "number" and record[field] >= 0, "terrain members stay non-negative")
    end
  end
  Assert.equal(count, 24, "the terrain inventory holds twenty-four families")
  for ordinal = 0, 23 do
    Assert.isTrue(seen[ordinal] == true, "ordinary ordinal " .. ordinal .. " is inventoried")
  end
  Assert.equal(#Sources.BACKGROUNDS, 18, "the ordinary background inventory holds eighteen families")
end

-- The additional facility and distortion terrain cell members (tower,
-- factory, arcade, castle, hall, and the distortion pair) must be
-- inventoried with their exact members; they are currently absent.
function T.additional_terrain_cell_members_are_inventoried()
  local found = {}
  for _, record in pairs(Sources.TERRAIN) do
    found[record.type0] = record
    found[record.type1] = record
  end
  Assert.isTrue(next(Sources.TERRAIN) ~= nil, "setup: the terrain inventory is non-empty")
  Assert.equal(#Sources.BACKGROUNDS, 18, "setup: the ordinary background count is intact")
  for _, member in ipairs({ 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176 }) do
    Assert.notNil(found[member], "terrain cell member " .. member .. " is inventoried")
  end
end

-- The additional facility and distortion palette members must be
-- inventoried beside their cells; they are currently absent.
function T.additional_terrain_palette_members_are_inventoried()
  local palettes = {}
  for _, record in pairs(Sources.TERRAIN) do
    palettes[record.day] = true
    palettes[record.evening] = true
    palettes[record.night] = true
  end
  Assert.isTrue(next(palettes) ~= nil, "setup: the palette inventory is non-empty")
  for _, member in ipairs({ 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69 }) do
    Assert.isTrue(palettes[member] == true, "terrain palette member " .. member .. " is inventoried")
  end
end

return { tests = T }
