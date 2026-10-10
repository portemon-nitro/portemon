-- Producer source selection for battle presentation: the ordinary
-- background/terrain/time vocabularies, the exact member roles, palette
-- formulas, and scene-key validation. Pure tables; no ROM access.

local Assert = require("tests.support.Assert")

local T = {}

local function sources()
  return require("romdump.src.config.BattlePresentationSources")
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
  Assert.equal(count, 18, "all eighteen terrains are inventoried")
  local seen = 0
  for _ in pairs(Sources.TERRAIN) do
    seen = seen + 1
  end
  Assert.equal(seen, 18, "no extra terrain hides beside the table")
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

return { tests = T }
