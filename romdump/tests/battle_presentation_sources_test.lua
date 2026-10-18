-- Producer source selection for battle presentation: the ordinary
-- background/terrain/time vocabularies, the exact member roles, palette
-- formulas, and scene-key validation. Pure tables; no ROM access.

local Assert = require("tests.support.Assert")

local T = {}

local function sources()
  return require("romdump.src.config.BattlePresentationSources")
end

function T.pokepic_shadow_source_reconstructs_the_native_texture_copy_geometry()
  local shadow = sources().POKE_SHADOW
  Assert.equal(shadow.characterMember, 259)
  Assert.equal(shadow.paletteMember, 260)
  Assert.equal(shadow.textureWidth, 256)
  Assert.equal(shadow.textureHeight, 256)
  Assert.equal(shadow.textureRowBytes, 0x80)
  Assert.equal(shadow.sourceRowBytes, 0x50)
  Assert.equal(shadow.sourceRows, 80)
  Assert.equal(shadow.copiedRowBytes, 0x28)
  Assert.equal(shadow.textureOriginByteOffset, 0x5050)
  Assert.deepEqual(shadow.regions, {
    { size = 0, x = 160, y = 160, width = 64, height = 16 },
    { size = 1, x = 160, y = 160, width = 64, height = 16 },
    { size = 2, x = 160, y = 176, width = 64, height = 16 },
    { size = 3, x = 160, y = 192, width = 64, height = 16 },
  })
end

function T.ordinary_backgrounds_keep_their_source_order()
  local Sources = sources()
  Assert.deepEqual(Sources.BACKGROUNDS, {
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
  })
end

function T.outdoor_backgrounds_take_time_variants_while_indoor_uses_zero()
  local Sources = sources()
  Assert.equal(Sources.paletteVariant("general", "day"), 0, "outdoor day selects variant zero")
  Assert.equal(Sources.paletteVariant("general", "evening"), 1, "outdoor evening selects variant one")
  Assert.equal(Sources.paletteVariant("general", "night"), 2, "outdoor night selects variant two")
  Assert.equal(Sources.paletteVariant("snow", "night"), 2, "the last outdoor background still varies")
  for _, background in ipairs({ "building_1", "cave_1", "will", "distortion_world" }) do
    Assert.equal(Sources.paletteVariant(background, "day"), 0, background .. " day collapses to variant zero")
    Assert.equal(Sources.paletteVariant(background, "evening"), 0, background .. " evening collapses to variant zero")
    Assert.equal(Sources.paletteVariant(background, "night"), 0, background .. " night collapses to variant zero")
  end
end

function T.base_palette_members_follow_the_background_variant_rule()
  local Sources = sources()
  Assert.equal(Sources.basePaletteMember(0, 0), 176, "background zero day reads member 176")
  Assert.equal(Sources.basePaletteMember(0, 2), 178, "background zero night reads member 178")
  Assert.equal(Sources.basePaletteMember(5, 1), 192, "the last outdoor background keeps three variants")
  Assert.equal(Sources.basePaletteMember(6, 0), 194, "indoor backgrounds start at member 194")
  Assert.equal(Sources.basePaletteMember(17, 0), 227, "the last background reads member 227")
end

function T.every_terrain_carries_its_type_and_daylight_triple()
  local Sources = sources()
  local expected = {
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
    battle_tower = { ordinal = 18, type0 = 165, type1 = 166, day = 52, evening = 53, night = 54 },
    battle_factory = { ordinal = 19, type0 = 167, type1 = 168, day = 55, evening = 56, night = 57 },
    battle_arcade = { ordinal = 20, type0 = 169, type1 = 170, day = 58, evening = 59, night = 60 },
    battle_castle = { ordinal = 21, type0 = 171, type1 = 172, day = 61, evening = 62, night = 63 },
    battle_hall = { ordinal = 22, type0 = 173, type1 = 174, day = 64, evening = 65, night = 66 },
    giratina = { ordinal = 23, type0 = 175, type1 = 176, day = 67, evening = 68, night = 69 },
  }
  local count = 0
  for terrain, triple in pairs(expected) do
    local record = assert(Sources.TERRAIN[terrain], terrain .. " has a terrain record")
    Assert.equal(record.ordinal, triple.ordinal, terrain .. " keeps its native ordinal")
    Assert.equal(record.type0, triple.type0, terrain .. " keeps its type-0 cells member")
    Assert.equal(record.type1, triple.type1, terrain .. " keeps its type-1 cells member")
    Assert.equal(record.day, triple.day, terrain .. " keeps its day palette member")
    Assert.equal(record.evening, triple.evening, terrain .. " keeps its evening palette member")
    Assert.equal(record.night, triple.night, terrain .. " keeps its night palette member")
    count = count + 1
  end
  Assert.equal(count, 24, "all twenty-four terrains are inventoried")
  local seen = 0
  for _ in pairs(Sources.TERRAIN) do
    seen = seen + 1
  end
  Assert.equal(seen, 24, "no extra terrain hides beside the table")
end

function T.doubled_health_box_families_keep_their_archive_members()
  local Sources = sources()
  local roles = assert(Sources.ROLES, "the source inventory carries its member roles")
  Assert.deepEqual(
    roles.enemyHudDoubleLeft,
    { nanr = 192, ncer = 193, ncgr = 194 },
    "the enemy left health box keeps its animation, cell, and character members"
  )
  Assert.deepEqual(
    roles.enemyHudDoubleRight,
    { nanr = 195, ncer = 196, ncgr = 197 },
    "the enemy right health box keeps its animation, cell, and character members"
  )
  Assert.deepEqual(
    roles.playerHudDoubleLeft,
    { nanr = 198, ncer = 199, ncgr = 200 },
    "the player left health box keeps its animation, cell, and character members"
  )
  Assert.deepEqual(
    roles.playerHudDoubleRight,
    { nanr = 201, ncer = 202, ncgr = 203 },
    "the player right health box keeps its animation, cell, and character members"
  )
  Assert.isTrue(Sources.validate(), "the source tables validate with the doubled families")
end

function T.health_box_patch_spans_follow_all_source_bar_templates()
  local Sources = sources()
  Assert.deepEqual(Sources.HUD_PATCH_SPANS, {
    hp = {
      { sideType = 0, spans = { { tile = 39, count = 0 }, { tile = 97, count = 6 } } },
      { sideType = 1, spans = { { tile = 39, count = 1 }, { tile = 96, count = 5 } } },
      { sideType = 2, spans = { { tile = 39, count = 0 }, { tile = 96, count = 6 } } },
      { sideType = 3, spans = { { tile = 39, count = 1 }, { tile = 96, count = 5 } } },
      { sideType = 4, spans = { { tile = 39, count = 0 }, { tile = 96, count = 6 } } },
      { sideType = 5, spans = { { tile = 39, count = 1 }, { tile = 96, count = 5 } } },
    },
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
    caught = {
      { sideType = 0, tile = 35, count = 1 },
      { sideType = 1, tile = 33, count = 1 },
      { sideType = 2, tile = 34, count = 1 },
      { sideType = 3, tile = 33, count = 1 },
      { sideType = 4, tile = 34, count = 1 },
      { sideType = 5, tile = 33, count = 1 },
    },
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
  }, "health and experience targets normalize the source byte offsets into character tile spans")
  Assert.isTrue(Sources.validate(), "source tile spans validate with all side-type templates")
end

function T.double_player_mode_patch_sources_cover_only_native_player_rows()
  local Sources = sources()
  local spans = Sources.HUD_PATCH_SPANS.playerDoubleMode
  local original = spans[2]
  spans[2] = { sideType = 3, gauge = original.gauge, numbers = original.numbers }
  Assert.isFalse(Sources.validate(), "double-player mode patches reject enemy side types")
  spans[2] = original
  Assert.isTrue(Sources.validate(), "source mode patches cover both double-player rows")
end

function T.hp_number_sources_require_bounded_complete_side_type_coverage()
  local Sources = sources()
  local patchSpans = Sources.HUD_PATCH_SPANS
  local original = patchSpans.currentHp
  local originalMaximum = patchSpans.maximumHp
  patchSpans.currentHp = { original[1], original[2], original[3], original[4], original[5] }
  local missingSide = Sources.validate()
  patchSpans.currentHp = original
  Assert.isFalse(missingSide, "every HP number span covers all six native side types")

  local invalid = { unpack(original) }
  invalid[1] = { sideType = 0, tile = -1, count = 3 }
  patchSpans.maximumHp = invalid
  local invalidTile = Sources.validate()
  patchSpans.maximumHp = originalMaximum
  Assert.isFalse(invalidTile, "HP number spans reject negative source tile indices")
end

function T.native_hud_component_tiles_match_the_pinned_source_array()
  local components = sources().HUD_COMPONENTS
  local bytes = {}
  for index = 1, #components.hex, 2 do
    bytes[#bytes + 1] = string.char(tonumber(components.hex:sub(index, index + 1), 16))
  end
  Assert.equal(components.source.revision, "9d8b7591f09b65804da2fb2dfd56f320633e0d36")
  Assert.equal(components.source.symbol, "gBattleHpBar_RawGraphicComponents")
  Assert.equal(components.tileCount, 78)
  Assert.equal(require("romdump.src.digest.Hashing").sha1hex(table.concat(bytes)), "d4e734fd6a3ad2afdd13d5c09926eae173c506f8")
  Assert.isTrue(sources().validate(), "native health-box component tiles retain exact pinned bytes")
end

function T.pokepic_shadow_members_and_source_uv_sizes_are_published_exactly()
  local shadow = sources().POKE_SHADOW
  Assert.deepEqual(shadow, {
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
  })
end

function T.scene_keys_round_trip_and_reject_effect_backgrounds()
  local Sources = sources()
  local key = Sources.sceneKey("general", "grass", "day")
  Assert.equal(key, "general/grass/day", "scene keys join their semantic axes")
  local parsed = assert(Sources.parseSceneKey(key), "the scene key parses")
  Assert.equal(parsed.background, "general", "the key carries its background")
  Assert.equal(parsed.terrain, "grass", "the key carries its terrain")
  Assert.equal(parsed.time, "day", "the key carries its time")
  Assert.isTrue(Sources.validateSceneKey(key), "an ordinary scene key validates")
  Assert.isNil(Sources.parseSceneKey("effect/flash/day"), "an effect background never parses as a scene")
  Assert.isFalse(Sources.validateSceneKey("effect/flash/day"), "an effect background never validates as a scene")
  Assert.isFalse(Sources.validateSceneKey("general/grass/dawn"), "an unknown time never validates")
  Assert.isFalse(Sources.validateSceneKey("general"), "a partial key never validates")
end

function T.every_supported_role_has_a_complete_recipe()
  local Sources = sources()
  Assert.isTrue(Sources.validate(), "the source tables validate")
end

function T.native_picture_geometry_covers_every_source_side_type()
  local Sources = sources()
  Assert.deepEqual(Sources.SLOT_GEOMETRY, {
    { sideType = 0, settledX = 64, settledY = 112, entryX = 336, entryY = 112, depth = -512, hudX = 192, hudY = 116, hudPriority = 23, hudBgPriority = 0 },
    { sideType = 1, settledX = 192, settledY = 50, entryX = -80, entryY = 50, depth = -640, hudX = 58, hudY = 36, hudPriority = 24, hudBgPriority = 0 },
    { sideType = 2, settledX = 40, settledY = 112, entryX = 316, entryY = 112, depth = -512, hudX = 192, hudY = 103, hudPriority = 28, hudBgPriority = 0 },
    { sideType = 4, settledX = 80, settledY = 120, entryX = 356, entryY = 120, depth = 0, hudX = 198, hudY = 132, hudPriority = 26, hudBgPriority = 0 },
    { sideType = 3, settledX = 216, settledY = 50, entryX = -60, entryY = 50, depth = -100, hudX = 64, hudY = 16, hudPriority = 25, hudBgPriority = 0 },
    { sideType = 5, settledX = 176, settledY = 42, entryX = -100, entryY = 42, depth = -640, hudX = 58, hudY = 45, hudPriority = 27, hudBgPriority = 0 },
  }, "producer publishes all six semantic native geometry rows")
end

function T.menu_and_message_sources_keep_semantic_keys_separate_from_selector_ids()
  local Sources = sources()
  Assert.equal(Sources.MENU_MESSAGE_BANK, "NARC_msgdata_msg", "battle menu text uses the pinned message archive")
  Assert.notNil(Sources.MENU_ROUTES["menu/main/initial"], "the initial main menu has a semantic route")
  Assert.equal(Sources.MENU_ROUTES["menu/main/initial"].sourceSelector, 1, "selector identity stays producer-side")
  Assert.equal(
    Sources.MENU_ROUTES["menu/main/initial"].screenGroup,
    "command",
    "main menus bind the staged screen group"
  )
  Assert.isNil(
    Sources.MENU_ROUTES["menu/main/initial-alias"],
    "generic source selectors are not assigned guessed menu meanings"
  )
  Assert.notNil(Sources.MENU_ROUTES["menu/bug-contest/initial"], "Bug Contest initial selector has a semantic route")
  Assert.notNil(Sources.MENU_ROUTES["menu/bug-contest/ordinary"], "Bug Contest ordinary selector has a semantic route")
  Assert.equal(Sources.MENU_ROUTES["menu/bug-contest/initial"].sourceSelector, 19)
  Assert.equal(Sources.MENU_ROUTES["menu/bug-contest/ordinary"].sourceSelector, 20)
  Assert.equal(Sources.MENU_ROUTES["menu/bug-contest/initial"].phase, "initial")
  Assert.equal(Sources.MENU_ROUTES["menu/bug-contest/ordinary"].phase, "ordinary")
  Assert.equal(Sources.MENU_MESSAGES["label/fight"], 924, "the Fight label binds its source message")
  Assert.equal(Sources.MENU_MESSAGES["label/yes"], 940, "yes/no text binds source message records")
  Assert.isNil(Sources.MENU_MESSAGES[924], "message IDs are not runtime catalog keys")
end

function T.menu_display_modes_preserve_source_branches_without_native_flags()
  local Sources = sources()
  Assert.deepEqual(Sources.menuDisplay("standard", false, false), {
    key = "menu/main/standard",
    layoutVariant = "standard",
    labels = { fight = "label/fight", bag = "label/bag", pokemon = "label/pokemon", run = "label/run" },
    dynamicFields = {},
  })
  Assert.deepEqual(Sources.menuDisplay("safari", false, true), {
    key = "menu/main/safari",
    layoutVariant = "standard",
    labels = {
      fight = "label/safari-ball",
      bag = "label/safari-bait",
      pokemon = "label/safari-mud",
      run = "label/cancel",
    },
    dynamicFields = {},
  })
  Assert.deepEqual(Sources.menuDisplay("pal-park", false, false), {
    key = "menu/main/pal-park",
    layoutVariant = "standard",
    labels = {
      fight = "label/pal-park-ball",
      bag = "label/safari-bait",
      pokemon = "label/safari-mud",
      run = "label/run",
    },
    dynamicFields = {},
  })
  local bugContest = Sources.menuDisplay("bug-contest", true, false)
  Assert.equal(bugContest.layoutVariant, "frontier", "Frontier has a source-confirmed art variant")
  Assert.equal(bugContest.labels.bag, "label/bug-contest-ball", "contest mode substitutes the ball label")
  Assert.deepEqual(bugContest.dynamicFields, { "caughtPokemonGender", "caughtPokemonLevel", "remainingBalls" })
  Assert.isNil(bugContest.labels.sourceSelector, "source selector IDs never enter semantic menu records")
end

function T.menu_layout_sources_keep_frontier_and_recorder_routes_separate()
  local Sources = sources()
  Assert.equal(Sources.MENU_ROUTES["menu/vs-recorder"].screenGroup, "vs-recorder")
  Assert.equal(Sources.MENU_LAYOUT_RESOURCES.frontier.character.memberId, 173)
  Assert.equal(Sources.MENU_LAYOUT_RESOURCES.frontier.palette.memberId, 349)
  Assert.equal(Sources.MENU_LAYOUT_RESOURCES.frontier.tilemap.memberId, 174)
  Assert.equal(Sources.MENU_LAYOUT_RESOURCES.frontier.touchPalette.memberId, 350)
  Assert.equal(Sources.MENU_LAYOUT_RESOURCES.frontier.touchPalette.kind, "palette")
  Assert.equal(Sources.MENU_LAYOUT_RESOURCES.vsRecorder.tilemap.memberId, 40)
  Assert.deepEqual(Sources.MENU_LAYOUT_RESOURCES.bugContest, {
    character = { archive = "NARC_a_0_0_8", memberId = 343, kind = "texture" },
    palette = { archive = "NARC_a_0_0_8", memberId = 72, kind = "palette" },
    cell = { archive = "NARC_a_0_0_8", memberId = 344, kind = "cell" },
    animation = { archive = "NARC_a_0_0_8", memberId = 345, kind = "animation" },
  }, "Bug Contest's fixed sport-ball/net assets use the source-selected scene members")
  Assert.deepEqual(Sources.BUG_CONTEST_SPRITES, {
    sportBall = { x = 208, y = 16, palette = 5, animation = 0 },
    bugNet = { x = 88, y = 8, palette = 4, animation = 1 },
  }, "the two fixed contest sprites retain their native semantic attributes")
  Assert.deepEqual(Sources.MENU_MESSAGE_ROUTES["menu/vs-recorder-feedback"].branches, {
    paused = { "status/recorder-0", "status/recorder-1" },
    corrupted = { "status/recorder-2", "status/recorder-3" },
  })
  Assert.equal(Sources.recorderFeedbackRoute(0), "paused")
  Assert.equal(Sources.recorderFeedbackRoute(1), "corrupted")
  Assert.isNil(Sources.recorderFeedbackRoute(2), "no pinned callsite selects the battle-too-long feedback pair")
  Assert.equal(Sources.RECORDER_FEEDBACK_UNREACHABLE_FLAGS[2], "battleTooLong")
  Assert.equal(Sources.MENU_MESSAGES["template/mon-male-level"], 944)
  Assert.equal(Sources.MENU_MESSAGES["template/mon-female-level"], 945)
  Assert.equal(Sources.MENU_MESSAGES["template/mon-neutral-level"], 946)
  Assert.equal(Sources.MENU_TEXT_FONT_ID, 4)
  Assert.equal(Sources.HUD_MESSAGE_FONT_ID, 0)
  Assert.equal(Sources.RECORDER_FEEDBACK_FONT_ID, 0)
  Assert.equal(Sources.BUG_CONTEST_FONT_ID, 0)
  Assert.deepEqual(Sources.MENU_MESSAGE_ROUTES["menu/bug-contest-caught-gender"], {
    variants = { "label/bug-contest-gender-male", "label/bug-contest-gender-female" },
    inputs = { "caughtPokemonGender" },
  })
end

function T.transition_setup_fallback_uses_pinned_terrain_time_and_trainer_axes()
  local Sources = sources()
  Assert.equal(Sources.transitionFallbackSelector("cave", "night", true), 11)
  Assert.equal(Sources.transitionFallbackSelector("water", "evening", false), 2)
  Assert.equal(Sources.transitionFallbackSelector("plain", "late", true), 7)
  Assert.equal(Sources.transitionFallbackSelector("unknown", "day", false), 0)
  Assert.isNil(Sources.transitionFallbackSelector("unknown-terrain", "dawn", false), "invalid context stays unresolved")
end

function T.transition_source_catalog_contains_only_verified_resource_tuples()
  local Sources = sources()
  Assert.equal(Sources.TRANSITION_ARCHIVE, "NARC_a_1_0_9", "transition archive resolves by version symbol")
  local spriteSet = Sources.TRANSITION_RESOURCE_SETS[1]
  Assert.equal(spriteSet.key, "transition/sprite-set/a", "transition resource keys are semantic")
  Assert.equal(spriteSet.resources[1].kind, "palette", "the helper loads the palette first")
  Assert.equal(spriteSet.resources[2].kind, "texture", "the helper loads character data second")
  Assert.equal(spriteSet.resources[3].kind, "cell", "the helper loads cell data third")
  Assert.equal(spriteSet.resources[4].kind, "animation", "the helper loads animation data fourth")
end

function T.transition_inventory_names_decoder_supported_payloads_by_source_role()
  local Sources = sources()
  local inventory = assert(Sources.TRANSITION_TYPED_RESOURCES, "transition source payload inventory is required")
  local function has(memberId, kind, selector)
    for _, resource in ipairs(inventory) do
      if resource.memberId == memberId and resource.kind == kind then
        for _, sourceSelector in ipairs(resource.selectors) do
          if sourceSelector == selector then
            return true
          end
        end
      end
    end
    return false
  end
  Assert.isTrue(has(0x3f, "palette", 12), "overlay 115 begins its parameter-selected quartet at palette member 0x3f")
  for memberId, kind in ipairs({ "palette", "texture", "cell", "animation" }) do
    local sourceMember = ({ 1, 7, 9, 8 })[memberId]
    Assert.isTrue(
      has(sourceMember, kind, 9),
      "overlay 119 selector 9 statically loads its source-confirmed sprite quartet member " .. sourceMember
    )
  end
  Assert.isTrue(has(0xd3, "palette", 29), "alternate overlay 115 context includes its second source quartet")
  for _, selector in ipairs({ 29, 30, 31, 32, 33 }) do
    Assert.isTrue(
      has(0x30, "texture", selector),
      "overlay 115 shared character payload is typed for selector " .. selector
    )
    Assert.isTrue(has(0x31, "cell", selector), "overlay 115 shared cell payload is typed for selector " .. selector)
    Assert.isTrue(
      has(0x32, "animation", selector),
      "overlay 115 shared animation payload is typed for selector " .. selector
    )
  end
  for selector, paletteMember in ipairs({ 0x2f, 0x33, 0x34, 0x35, 0x36 }) do
    Assert.isTrue(
      has(paletteMember, "palette", selector + 28),
      "overlay 115 record-selected palette member is typed for selector " .. (selector + 28)
    )
  end
  Assert.isTrue(has(0xdf, "texture", 40), "overlay 117 selectors retain their source sprite quartet")
  Assert.isTrue(has(0xa8, "map", 45), "selector 45 retains the transition screen role")
  Assert.isFalse(has(0x97, "model", 29), "opaque model members stay outside the decoded resource catalog")
  Assert.deepEqual(Sources.TRANSITION_PARTICLE_MEMBERS, { 0x97, 0x98 })
end

function T.transition_message_sources_keep_text_and_frontier_members_distinct()
  local Sources = sources()
  Assert.equal(Sources.TRANSITION_MESSAGE_MEMBER, 189)
  Assert.equal(Sources.TRANSITION_MESSAGE_ID, 0)
  Assert.deepEqual(Sources.FRONTIER_TRAINER_MESSAGE_ROUTE, {
    archive = "NARC_msgdata_msg",
    profileVersionZero = 723,
    noProfileVersionZero = 724,
    trainerMessageString = { multiplier = 3, winOffset = 1, lossOffset = 2 },
    mailMessage = { trainerId = 0x2710, battleTypeBit = 13 },
    printerFontId = 1,
  })
  Assert.deepEqual(Sources.TRANSITION_MESSAGE_SOURCE_ROUTES, {
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
  }, "transition message dependencies retain the pinned overlay call routes")
end

function T.message_source_routes_bind_native_callers_to_typed_semantic_inputs()
  local Sources = sources()
  local routes = assert(Sources.MESSAGE_SOURCE_ROUTES, "message source routes are inventoried")
  Assert.deepEqual(routes.scriptLiteral, {
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
  })
  Assert.deepEqual(routes.controllerMessage, {
    key = "battle/controller-message",
    source = { file = "src/battle/battle_system.c", symbol = "BattleSystem_PrintBattleMessage" },
    banks = { "message-bank/battle-script-controller" },
    operands = { "messageRecord", "battleMessageTag", "tagParameters" },
    placeholderPlan = "battleMessageTags",
  })
  Assert.deepEqual(routes.scriptGlobal, {
    key = "battle/global-script-message",
    source = {
      callsite = { file = "files/battledata/script", symbol = "PrintGlobalMessage" },
      macro = { file = "asm/macros/btlcmd.inc", symbol = "PrintGlobalMessage" },
      handlerTable = { file = "asm/overlay_12_battle_command.s", symbol = "BtlCmd_PrintGlobalMessage" },
      command = { file = "src/battle/battle_command.c", symbol = "BtlCmd_PrintGlobalMessage" },
      readOperands = { file = "src/battle/battle_command.c", symbol = "InitBattleMsgData" },
      resolveContext = { file = "src/battle/battle_command.c", symbol = "InitBattleMsg" },
      scope = { file = "src/battle/battle_command.c", symbol = "BtlCmd_PrintGlobalMessage", semantic = "global-message" },
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
  })
  Assert.deepEqual(routes.recorderFeedback, {
    key = "battle/recorder-feedback",
    source = { file = "src/battle/battle_input.c", symbol = "BattleInput_PrintSystemMessage" },
    banks = { "message-bank/battle-script-controller" },
    input = "feedbackKind",
    reachable = { "paused", "corrupted" },
    unreachable = { "battleTooLong" },
  })
  Assert.deepEqual(routes.battleCommand, {
    key = "battle/command-message",
    source = { file = "src/battle/battle_command.c", symbol = "Task_GetPokemon" },
    banks = { "message-bank/battle-script-controller" },
    routes = { "captureShake", "metBillPCTransfer" },
  })
  Assert.deepEqual(routes.frontierTrainerSpeech, {
    key = "battle/frontier-trainer-speech",
    source = { file = "src/battle/battle_system.c", symbol = "BattleSystem_PrintTrainerMessage" },
    banks = { "message-bank/trainer-profile-zero", "message-bank/trainer-profile-fallback" },
    inputs = { "trainerIndex", "outcome", "playerProfiles", "trainerMail" },
    mailExpansion = "frontierTrainerMail",
    mailCase = "special-trainer-or-frontier-battle-type",
  })
  Assert.deepEqual(routes.trainerPairSpeech, {
    key = "battle/trainer-pair-speech",
    source = { file = "src/trainer_data.c", symbol = "GetTrainerMessageByIdPair" },
    banks = { "message-bank/trainer-pair-lookup" },
    inputs = { "trainerIndex", "trainerMessageKind" },
    resources = { "trainer-message-index/offsets", "trainer-message-index/pairs" },
    selection = "trainer-pair-table-match",
  })
  Assert.deepEqual(routes.tutorialAuthor, {
    key = "battle/tutorial-author",
    source = { file = "src/battle/battle_setup.c", symbol = "BattleSetup_New_Tutorial" },
    banks = { "message-bank/tutorial-author" },
    input = "playerGender",
    selection = "gender-xor-one",
  })
  Assert.isNil(routes[197], "physical message bank IDs are not route keys")
end

function T.message_placeholder_slots_name_the_native_source_and_input_contract()
  local Sources = sources()
  local slots = assert(Sources.MESSAGE_PLACEHOLDER_SCHEMAS, "placeholder inputs are source-typed")
  Assert.deepEqual(slots.species, {
    bankRole = "speciesPlaceholder",
    source = "BufferSpeciesName",
    input = "speciesId",
  })
  Assert.deepEqual(slots.move, {
    bankRole = "movePlaceholder",
    source = "BattleMessage_BufferMove",
    input = "moveId",
  })
  Assert.deepEqual(slots.ability, {
    bankRole = "abilityPlaceholder",
    source = "BattleMessage_BufferAbility",
    input = "abilityId",
  })
  Assert.deepEqual(slots.item, {
    bankRole = "itemPlaceholder",
    source = "BattleMessage_BufferItem",
    input = "itemId",
  })
  Assert.deepEqual(slots.type, {
    bankRole = "typePlaceholder",
    source = "BattleMessage_BufferType",
    input = "typeId",
  })
  Assert.deepEqual(slots.stat, {
    bankRole = "statPlaceholder",
    source = "BattleMessage_BufferStat",
    input = "battleStatId",
  })
  Assert.deepEqual(slots.status, {
    bankRole = "statusPlaceholder",
    source = "BattleMessage_BufferStatus",
    input = "battleStatusId",
  })
  Assert.deepEqual(slots.trainerClass, {
    bankRole = "trainerClassPlaceholder",
    source = "BattleMessage_BufferTrainerClass",
    input = "trainerClassId",
  })
  Assert.deepEqual(slots.trainerName, {
    bankRole = "trainerNamePlaceholder",
    source = "BattleMessage_BufferTrainerName",
    input = "trainerIndex",
  })
  Assert.deepEqual(slots.flavorPreference, {
    bankRole = "flavorPlaceholder",
    source = "BattleMessage_BufferFlavorPreference",
    input = "flavorId",
  })
  Assert.deepEqual(Sources.MESSAGE_TEMPLATE_INPUTS, {
    nickname = {
      source = "BattleMessage_BufferNickname",
      input = "battlerAndPartySlot",
      dependency = "partyBoxMon",
    },
    boxName = { source = "BattleMessage_BufferBoxName", input = "boxIndex", dependency = "saveStorage" },
    number = { source = "BattleMessage_BufferNumber", input = "integer" },
    numbers = { source = "BattleMessage_BufferNumbers", input = "integerAndDigitWidth" },
    poffin = { source = "BattleMessage_BufferPoffin", supported = false, reason = "unused-in-HGSS" },
  })
  Assert.equal(Sources.MESSAGE_TEMPLATE_EXPANSION.source, "BattleMessage_ExpandPlaceholders")
  Assert.equal(Sources.MESSAGE_TEMPLATE_EXPANSION.input, "tagSelectedBuffers")
  Assert.equal(Sources.MESSAGE_PLACEHOLDER_BANKS.flavorPreference, "flavorPlaceholder")
  Assert.equal(Sources.MESSAGE_BANKS.trainerNamePlaceholder, 729)
  Assert.equal(Sources.MESSAGE_BANKS.flavorPlaceholder, 639)
  Assert.equal(Sources.MESSAGE_BANK_RESOURCE_KEYS.trainerNamePlaceholder, "message-bank/trainer-name-placeholder")
  Assert.equal(Sources.MESSAGE_BANK_RESOURCE_KEYS.flavorPlaceholder, "message-bank/flavor-placeholder")
  for slot, bankRole in pairs(Sources.MESSAGE_PLACEHOLDER_BANKS) do
    Assert.equal(slots[slot].bankRole, bankRole, slot .. " has a typed source contract")
    Assert.notNil(Sources.MESSAGE_BANKS[bankRole], slot .. " resolves to a pinned message bank")
    Assert.notNil(Sources.MESSAGE_BANK_RESOURCE_KEYS[bankRole], slot .. " has a semantic dependency key")
  end
  local sourceFiles = {}
  local function collectSourceFiles(value)
    if type(value) ~= "table" then
      return
    end
    if type(value.file) == "string" then
      sourceFiles[value.file] = true
    end
    for _, nested in pairs(value) do
      collectSourceFiles(nested)
    end
  end
  collectSourceFiles(Sources.MESSAGE_SOURCE_ROUTES)
  collectSourceFiles(Sources.FRONTIER_TRAINER_MAIL)
  sourceFiles[Sources.MESSAGE_TAG_DISPATCH.tags] = true
  for _, sourceFile in ipairs({
    "files/battledata/script",
    "src/battle/battle_input.c",
    "src/battle/battle_command.c",
    "src/battle/battle_setup.c",
    "src/battle/battle_system.c",
    "src/trainer_data.c",
    "src/mail_message.c",
    "asm/macros/btlcmd.inc",
    "asm/overlay_12_battle_command.s",
    "include/constants/message_tags.h",
  }) do
    Assert.isTrue(sourceFiles[sourceFile], sourceFile .. " is part of pinned message provenance")
  end
end

function T.script_message_operands_expand_through_source_tag_and_context_contracts()
  local Sources = sources()
  Assert.deepEqual(Sources.MESSAGE_SOURCE_ROUTES.scriptLiteral, {
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
  })
  Assert.deepEqual(Sources.MESSAGE_TAG_SCHEMAS.TAG_NICKNAME_POKE, { "nickname", "species" })
  Assert.deepEqual(Sources.MESSAGE_TAG_SCHEMAS.TAG_ITEM_NICKNAME_FLAVOR, { "item", "nickname", "flavorPreference" })
  Assert.deepEqual(Sources.MESSAGE_TAG_SCHEMAS.TAG_TRCLASS_TRNAME_NICKNAME_TRCLASS_TRNAME_NICKNAME, {
    "trainerClass",
    "trainerName",
    "nickname",
    "trainerClass",
    "trainerName",
    "nickname",
  })
  Assert.deepEqual(Sources.MESSAGE_TAG_SCHEMAS.TAG_NONE_SIDE, {})
  Assert.equal(Sources.MESSAGE_TAG_DISPATCH.source, "BattleSystem_BufferMessage")
  Assert.equal(Sources.MESSAGE_TAG_DISPATCH.mask, "low-six-bits")
  Assert.deepEqual(Sources.MESSAGE_TAG_CONTEXT_RESOLVERS.move, {
    source = "GetMoveMessageNo",
    input = "moveSelector",
    result = "moveMessageRecord",
    selectors = { "currentMove", "temporaryMove" },
  })
  Assert.deepEqual(Sources.MESSAGE_TAG_CONTEXT_RESOLVERS.nickname, {
    source = "ov12_022480C0",
    input = "battlerCategory",
    result = "battlerAndPartySlot",
  })
  for tag, slots in pairs(Sources.MESSAGE_TAG_SCHEMAS) do
    for _, slot in ipairs(slots) do
      Assert.isTrue(
        Sources.MESSAGE_PLACEHOLDER_BANKS[slot] ~= nil or Sources.MESSAGE_TEMPLATE_INPUTS[slot] ~= nil,
        tag .. " resolves every parameter slot"
      )
    end
  end
  for role, resolver in pairs(Sources.MESSAGE_TAG_CONTEXT_RESOLVERS) do
    Assert.isTrue(
      type(resolver.result) == "string" and resolver.result ~= "",
      role .. " resolver names its normalized semantic output"
    )
  end
  Assert.equal(Sources.MESSAGE_TEMPLATE_INPUTS.poffin.supported, false)
  Assert.isNil(Sources.MESSAGE_PLACEHOLDER_BANKS.speciesAlternate, "no battle tag reaches the article-species bank")
end

function T.trainer_pair_and_frontier_mail_routes_resolve_dynamic_source_inputs()
  local Sources = sources()
  Assert.deepEqual(Sources.TRAINER_MESSAGE_TABLES, {
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
  })
  Assert.deepEqual(Sources.MESSAGE_ROUTES.trainerPairSpeech, {
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
  })
  local frontierMail = Sources.FRONTIER_TRAINER_MAIL
  Assert.deepEqual({
    source = frontierMail.source,
    expander = frontierMail.expander,
    inputs = frontierMail.inputs,
    messageBanks = frontierMail.messageBanks,
    selection = frontierMail.selection,
    expansion = frontierMail.expansion,
    placeholderFields = frontierMail.placeholderFields,
    easyChatBanks = frontierMail.easyChatBanks,
  }, {
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
  })
  Assert.deepEqual(Sources.MESSAGE_SOURCE_ROUTES.recorderFeedback.unreachable, { "battleTooLong" })
  Assert.isNil(Sources.MESSAGE_SOURCE_ROUTES.recorderFeedback.unresolved)
  local sourceResources = Sources.FRONTIER_TRAINER_MAIL.sourceResources
  Assert.isTrue(#sourceResources > 0, "Frontier mail source closure has producer resource descriptors")
  local resourceKeys = {}
  for _, resource in ipairs(sourceResources) do
    Assert.equal(resource.archive, "NARC_msgdata_msg")
    Assert.equal(resource.format, "HGSS_MSG_BANK")
    Assert.equal(resource.memberId, Sources.MESSAGE_BANKS[resource.bankRole])
    Assert.equal(resource.key, Sources.MESSAGE_BANK_RESOURCE_KEYS[resource.bankRole])
    resourceKeys[resource.key] = true
  end
  for _, key in ipairs(Sources.FRONTIER_TRAINER_MAIL.messageBanks) do
    Assert.isTrue(resourceKeys[key], key .. " has a source-selected mail message bank")
  end
  for _, key in ipairs(Sources.FRONTIER_TRAINER_MAIL.easyChatBanks) do
    Assert.isTrue(resourceKeys[key], key .. " has a source-selected Easy Chat bank")
  end
end

function T.transition_selector_table_partitions_the_source_dispatch_ranges()
  local Sources = sources()
  local families = assert(Sources.TRANSITION_SELECTOR_FAMILIES, "transition selector family provenance is required")
  for selector = 0, 46 do
    Assert.notNil(families[selector], "source dispatch family exists for selector " .. selector)
  end
  Assert.equal(families[0], "overlay-120")
  Assert.equal(families[11], "overlay-119")
  Assert.equal(families[12], "overlay-115")
  Assert.equal(families[33], "overlay-115")
  Assert.equal(families[34], "overlay-116")
  Assert.equal(families[36], "overlay-116")
  Assert.equal(families[37], "overlay-114")
  Assert.equal(families[38], "overlay-114")
  Assert.equal(families[39], "overlay-117")
  Assert.equal(families[44], "overlay-117")
  Assert.equal(families[45], "overlay-118")
  Assert.equal(families[46], "overlay-120")
end

function T.transition_routes_preserve_verified_selector_context_and_resource_roles()
  local Sources = sources()
  local routes =
    assert(Sources.TRANSITION_SELECTOR_ROUTES, "transition selectors require source-derived semantic routes")
  for selector = 0, 46 do
    Assert.notNil(routes[selector], "every native callback selector has a semantic source route: " .. selector)
    Assert.equal(routes[selector].family, Sources.TRANSITION_SELECTOR_FAMILIES[selector])
  end
  Assert.deepEqual(routes[9], {
    family = "overlay-119",
    key = "fallback/water/late/trainer",
    role = "water-trainer-fallback",
    context = { terrain = "water", timeOfDay = "late", isTrainer = true },
    sprite = { palette = 1, character = 7, cell = 9, animation = 8 },
  }, "fallback selector 9 resolves to its literal overlay tuple")
  Assert.deepEqual(routes[29], {
    family = "overlay-115",
    key = "trainer/will",
    role = "trainer-intro",
    trainer = { key = "will", trainerId = 0xf5 },
    messageRoute = "transition/trainer-name",
    context = { playerTrainerGender = true },
    spriteVariants = {
      male = { palette = 0xcf, character = 0xd0, cell = 0xd1, animation = 0xd2 },
      female = { palette = 0xd3, character = 0xd4, cell = 0xd5, animation = 0xd6 },
    },
    extraSprite = { character = 0x30, cell = 0x31, animation = 0x32 },
    fixedSprite = { palette = 0x3b, character = 0x3c, cell = 0x3d, animation = 0x3e },
    particleMembers = { 0x97, 0x98 },
    message = { archive = "NARC_msgdata_msg", member = 189, name = "trainer" },
  }, "late overlay 115 records preserve the source gender and name branches")
  Assert.deepEqual(routes[33].trainer, { key = "lance", trainerId = 0xf4 })
  for selector = 12, 27 do
    Assert.equal(routes[selector].messageRoute, "transition/trainer-name")
  end
  Assert.equal(routes[28].messageRoute, "transition/rival-name")
  for selector = 29, 33 do
    local trainer = assert(routes[selector].trainer)
    Assert.equal(routes[selector].messageRoute, "transition/trainer-name")
  end
  Assert.deepEqual(routes[46], {
    family = "overlay-120",
    key = "trainer/red",
    role = "red-trainer-transition",
    trainer = { key = "red", transitionRecord = 46 },
    sprite = { palette = 1, character = 10, cell = 12, animation = 11 },
    background = { palette = 0xa6, character = 0xa7, map = 0xa8 },
  }, "selector 46 has the single proven internal Red tuple, no fabricated variant input")
  Assert.isNil(Sources.TRANSITION_INTERNAL_RESOURCE_VARIANTS, "the unsupported two-variant input is removed")
end

function T.transition_preselection_resolves_only_source_proven_semantic_routes()
  local Sources = sources()
  local preselection = assert(Sources.TRANSITION_PRESELECTION, "caller-side transition selectors are source data")
  Assert.equal(preselection.trainerClasses.LEADER_FALKNER, "trainer/falkner")
  Assert.equal(preselection.trainerCategoryByKey["trainer/falkner"], 0)
  Assert.equal(preselection.categoryRoutes[0], Sources.TRANSITION_SELECTOR_ROUTES[12].key)
  Assert.equal(preselection.trainerClasses.ELITE_FOUR_WILL, "trainer/will")
  Assert.equal(preselection.categoryRoutes[16], Sources.TRANSITION_SELECTOR_ROUTES[29].key)
  Assert.equal(preselection.wildSpecies.HO_OH, "wild/ho-oh")
  Assert.equal(preselection.wildCategoryByKey["wild/ho-oh"], 25)
  Assert.equal(preselection.categoryRoutes[25], Sources.TRANSITION_SELECTOR_ROUTES[35].key)
  Assert.deepEqual(preselection.categoryRoutes[22], { fallback = true })
  Assert.equal(preselection.categoryRoutes[27], "wild/special-legendary")
  Assert.equal(preselection.categoryRoutes[28], Sources.TRANSITION_SELECTOR_ROUTES[34].key)
  Assert.equal(preselection.categoryRoutes[27], Sources.TRANSITION_SELECTOR_ROUTES[34].key)
  Assert.equal(preselection.categoryRoutes[35], Sources.TRANSITION_SELECTOR_ROUTES[37].key)
  Assert.equal(preselection.categoryRoutes[36], Sources.TRANSITION_SELECTOR_ROUTES[37].key)
  Assert.equal(preselection.categoryRoutes[39], Sources.TRANSITION_SELECTOR_ROUTES[37].key)
  Assert.equal(preselection.categoryRoutes[37], Sources.TRANSITION_SELECTOR_ROUTES[38].key)
  Assert.equal(preselection.categoryRoutes[38], Sources.TRANSITION_SELECTOR_ROUTES[38].key)
  Assert.equal(preselection.categoryRoutes[40], Sources.TRANSITION_SELECTOR_ROUTES[38].key)
  Assert.equal(preselection.callInputs.trainerBit, 0x01)
  Assert.equal(preselection.callInputs.doublesBit, 0x02)
  Assert.equal(preselection.callInputs.specialBattleBit, 0x80)
  Assert.equal(preselection.callInputs.wildSecondArgument, 0x6d)
  Assert.deepEqual(preselection.selectionRules.trainer, {
    input = "trainerClass",
    specialBattleBit = 0x80,
    specialBattle = { preserveCategory = 39, doublesCategory = 37, defaultCategory = 35 },
    preserveCategories = { 29, 30, 31, 32, 33, 34, 43, 44 },
    doublesCategory = 37,
    alternateTransitionBit = 0x04,
    alternateCategory = 36,
    otherwise = "trainerCategory",
  })
  Assert.deepEqual(preselection.selectionRules.wild, {
    input = "firstLivingPokemonSpecies",
    fallbackWhenSecondArgumentEquals = 0x6d,
    fallbackCategory = 42,
    doublesCategoryWhenCategoryAtLeast = { threshold = 42, category = 38 },
    otherwise = "wildSpeciesCategory",
  })
end

function T.overlay_117_stages_bg_resources_only_on_selectors_40_through_44()
  local Sources = sources()
  local routes = Sources.TRANSITION_SELECTOR_ROUTES
  Assert.isNil(routes[39].background, "selector 39 only uses its fixed sprite route")
  for selector = 40, 44 do
    Assert.deepEqual(routes[selector].background, {
      palette = 0xd7,
      character = 0xd8,
      maps = { 0xd9, 0xda },
    }, "overlay 117's shared BG helper uses its callsite members for selector " .. selector)
  end
  local function has(memberId, kind, selector)
    for _, resource in ipairs(Sources.TRANSITION_TYPED_RESOURCES) do
      if resource.memberId == memberId and resource.kind == kind then
        for _, sourceSelector in ipairs(resource.selectors) do
          if sourceSelector == selector then
            return true
          end
        end
      end
    end
    return false
  end
  for selector = 40, 44 do
    Assert.isTrue(has(0xd7, "palette", selector))
    Assert.isTrue(has(0xd8, "texture", selector))
    Assert.isTrue(has(0xd9, "map", selector))
    Assert.isTrue(has(0xda, "map", selector))
  end
  Assert.isFalse(has(0xd7, "palette", 39), "selector 39 does not dispatch through the BG helper")
end

function T.overlay_115_routes_publish_complete_semantic_sprite_and_bg_groups()
  local routes = sources().TRANSITION_SELECTOR_ROUTES
  local gym = assert(routes[12])
  Assert.deepEqual(gym.background, { palette = 21, character = 20, map = 22 })
  Assert.deepEqual(gym.task, {
    kind = "overlay115-gym-rival-intro",
    parameters = { endXFx32 = 214 * 4096 },
  })
  local expectedShakeTicks = { 32, 32, 32, 32, 9 }
  local expectedOpponentStart = { 0x83, 0x87, 0x8b, 0x8f, 0x93 }
  local expectedNameplatePalette = { 0x2f, 0x33, 0x34, 0x35, 0x36 }
  for index, selector in ipairs({ 29, 30, 31, 32, 33 }) do
    local route = assert(routes[selector])
    local opponent = expectedOpponentStart[index]
    Assert.deepEqual(route.task, {
      kind = "overlay115-elite-intro",
      parameters = { shakeTicks = expectedShakeTicks[index] },
    })
    Assert.deepEqual(route.opponent, {
      palette = opponent,
      character = opponent + 1,
      cell = opponent + 2,
      animation = opponent + 3,
    })
    Assert.deepEqual(route.nameplate, {
      palette = expectedNameplatePalette[index],
      character = 0x30,
      cell = 0x31,
      animation = 0x32,
    })
    Assert.deepEqual(route.particleMembers, { 151, 152 })
    Assert.deepEqual(route.fixedSprite, { palette = 0x3b, character = 0x3c, cell = 0x3d, animation = 0x3e })
    Assert.deepEqual(route.spriteVariants.male, { palette = 0xcf, character = 0xd0, cell = 0xd1, animation = 0xd2 })
    Assert.deepEqual(
      route.spriteVariants.female,
      { palette = 0xd3, character = 0xd4, cell = 0xd5, animation = 0xd6 }
    )
  end
end

function T.menu_context_contracts_preserve_dynamic_source_inputs()
  local contexts = assert(sources().MENU_CONTEXTS, "menu context contracts are source data")
  Assert.deepEqual(contexts.main, {
    inputs = {
      mode = { type = "enum", values = { "standard", "safari", "pal-park", "bug-contest" } },
      cancelRun = { type = "boolean" },
      frontier = { type = "boolean" },
    },
    modes = { "standard", "safari", "pal-park", "bug-contest" },
  })
  Assert.deepEqual(contexts.bugContest, {
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
  })
  Assert.deepEqual(contexts.frontier, {
    input = "isFrontier",
    predicate = "BattleSystem_IsInFrontier",
    overrides = "frontier",
  })
  Assert.deepEqual(contexts.moveSelection, {
    slotCount = 4,
    slots = {
      move = "move",
      currentPP = "integer",
      maximumPP = "integer",
      derived = { moveName = "move-name", moveType = "move-type", typeIcon = "move-type-icon" },
      emptyMove = "move/none",
    },
  })
  Assert.deepEqual(contexts.targetSelection, {
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
  })
  Assert.deepEqual(contexts.vsRecorder, {
    sourceSelector = 18,
    inputs = { playbackStatus = { type = "enum", values = { "paused", "corrupted" } } },
    screenRole = "vsRecorder",
    stopMessage = "label/recorder-stop",
    feedbackRoute = "menu/vs-recorder-feedback",
  })
  Assert.equal(sources().MENU_ROUTES["menu/vs-recorder"].sourceSelector, 18)
end

function T.semantic_roots_cover_source_menu_message_and_transition_routes()
  local Sources = sources()
  local roots = assert(Sources.listSemanticRoots, "presentation roots are source-derived")()
  local rootByKey = {}
  for _, root in ipairs(roots) do
    Assert.isNil(rootByKey[root.key], "semantic root keys are unique")
    Assert.isTrue(
      root.kind == "menu-route" or root.kind == "message-route" or root.kind == "transition-route",
      "root operation is from the supported presentation families"
    )
    Assert.isTrue(type(root.sourceRouteKey) == "string", "root points to a semantic source route")
    Assert.isFalse(type(root.selection) == "number", "source selectors do not escape into root records")
    Assert.deepEqual(root.selection, { route = root.sourceRouteKey }, "selection points to its semantic route")
    rootByKey[root.key] = root
  end

  for routeKey in pairs(Sources.MENU_ROUTES) do
    local root = assert(rootByKey[routeKey], "menu route has a semantic root: " .. routeKey)
    Assert.equal(root.kind, "menu-route")
    Assert.equal(root.sourceRouteKey, routeKey)
  end
  for routeKey, route in pairs(Sources.MESSAGE_SOURCE_ROUTES) do
    local root = assert(rootByKey[route.key], "message source route has a semantic root: " .. routeKey)
    Assert.equal(root.kind, "message-route")
    Assert.equal(root.sourceRouteKey, routeKey)
  end
  for routeKey in pairs(Sources.MENU_MESSAGE_ROUTES) do
    local root = assert(rootByKey[routeKey], "menu message has a semantic root: " .. routeKey)
    Assert.equal(root.kind, "message-route")
    Assert.equal(root.sourceRouteKey, routeKey)
  end

  local transitionKeys = {}
  for _, route in pairs(Sources.TRANSITION_SELECTOR_ROUTES) do
    Assert.isTrue(type(route.key) == "string", "each native transition callback has a semantic route")
    transitionKeys[route.key] = true
  end
  for routeKey in pairs(transitionKeys) do
    local key = "transition/" .. routeKey
    local root = assert(rootByKey[key], "transition selector route has a semantic root: " .. routeKey)
    Assert.equal(root.kind, "transition-route")
    Assert.equal(root.sourceRouteKey, routeKey)
  end
  for routeKey, route in pairs(Sources.TRANSITION_MESSAGE_SOURCE_ROUTES) do
    local root = assert(rootByKey[route.key], "transition name source has a semantic root: " .. routeKey)
    Assert.equal(root.kind, "message-route")
    Assert.equal(root.sourceRouteKey, routeKey)
  end
end

function T.audio_roles_cover_source_selected_heartgold_battle_music()
  Assert.deepEqual(sources().AUDIO_ROLES, {
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
  })
end

return { tests = T }
