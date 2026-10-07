-- FieldMoveSources contract tests: verified source move/badge/map/object
-- policy facts stay producer-owned, with numeric source identities resolved
-- here and semantic keys crossing to runtime.
-- Source basis: pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36,
-- asm/unk_0203BA5C.s (sSpawnMaps and GetDeathWarpData).

local Assert = require("tests.support.Assert")
local FieldMoveSources = require("romdump.src.config.FieldMoveSources")
local Spawns = require("romdump.src.reference.hgss.spawns")

local T = {}

function T.sixteen_moves_have_ordered_badge_gates()
  Assert.equal(#FieldMoveSources.MOVE_KEYS, 16)
  local gates = FieldMoveSources.badgeGate
  Assert.equal(gates.cut, "hive")
  Assert.equal(gates.fly, "storm")
  Assert.equal(gates.surf, "fog")
  Assert.equal(gates.strength, "plain")
  Assert.equal(gates.rock_smash, "zephyr")
  Assert.equal(gates.waterfall, "rising")
  Assert.equal(gates.rock_climb, "earth")
  Assert.equal(gates.whirlpool, "glacier")
  Assert.isNil(gates.flash)
  Assert.isNil(gates.headbutt)
end

function T.badge_order_matches_progression_order()
  Assert.deepEqual(FieldMoveSources.BADGE_ORDER, FieldMoveSources.BADGE_KEYS)
end

function T.badge_indexes_resolve_in_semantic_order()
  Assert.equal(FieldMoveSources.badgeKeyForIndex(0), "zephyr")
  Assert.equal(FieldMoveSources.badgeKeyForIndex(1), "hive")
  Assert.equal(FieldMoveSources.badgeKeyForIndex(7), "rising")
  Assert.equal(FieldMoveSources.badgeKeyForIndex(8), "boulder")
  Assert.equal(FieldMoveSources.badgeKeyForIndex(15), "earth")
  Assert.isNil(FieldMoveSources.badgeKeyForIndex(16))
  Assert.isNil(FieldMoveSources.badgeKeyForIndex(-1))
end

function T.mother_spawn_resolves_through_the_frozen_spawn_catalog()
  local id = FieldMoveSources.MOTHER_SPAWN_ID
  Assert.equal(Spawns.byId[id], "SPAWN_NEW_BARK")
  Assert.equal(FieldMoveSources.MOTHER_SPAWN_NAME, "SPAWN_NEW_BARK")
end

function T.flash_weather_ids_cover_the_dark_caves()
  local snowy = false
  for _, id in ipairs(FieldMoveSources.FLASH_WEATHER_IDS) do
    Assert.isTrue(type(id) == "number")
    if id == 11 then
      snowy = true
    end
  end
  Assert.isTrue(snowy)
end

function T.obstacle_kinds_form_a_closed_vocabulary()
  Assert.deepEqual(FieldMoveSources.OBSTACLE_KINDS, {
    "cut_tree",
    "smash_rock",
    "strength_boulder",
    "headbutt_tree",
  })
  Assert.equal(FieldMoveSources.obstacleKindForSprite(1), nil)
end

function T.obstacle_sprites_resolve_their_verified_kinds()
  Assert.equal(FieldMoveSources.obstacleKindForSprite(86), "cut_tree")
  Assert.equal(FieldMoveSources.obstacleKindForSprite(84), "strength_boulder")
  Assert.equal(FieldMoveSources.obstacleKindForSprite(85), "smash_rock")
end

function T.exception_maps_are_explicit_symbols()
  Assert.equal(FieldMoveSources.ICE_PATH_B2F_SYMBOL, "MAP_ICE_PATH_B2F")
  Assert.equal(FieldMoveSources.ALPH_FLASH_SYMBOL, "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL")
end

function T.spawn_destinations_cover_every_frozen_spawn_name()
  local count = 0
  for _, name in pairs(Spawns.byId) do
    if name ~= "SPAWN_NONE" then
      local destination = assert(
        FieldMoveSources.spawnDestinationForKey(name),
        "every frozen spawn resolves: " .. name .. " (id " .. tostring(id) .. ")"
      )
      Assert.equal(type(destination.map), "string", name .. " names a map")
      count = count + 1
    end
  end
  Assert.equal(count, 30, "all thirty source spawns resolve")
end

function T.spawn_destinations_pin_mother_and_updated_history()
  local mother = FieldMoveSources.spawnDestinationForKey("SPAWN_NEW_BARK")
  Assert.deepEqual(mother, { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 })
  local goldenrod = FieldMoveSources.spawnDestinationForKey("SPAWN_GOLDENROD")
  Assert.deepEqual(goldenrod, { map = "MAP_GOLDENROD", fieldX = 352, fieldZ = 369 })
end

function T.spawn_destinations_answer_fresh_records_and_refuse_garbage()
  local first = assert(FieldMoveSources.spawnDestinationForKey("SPAWN_VIOLET"), "violet resolves")
  first.map = "MAP_MUTATED"
  local second = assert(FieldMoveSources.spawnDestinationForKey("SPAWN_VIOLET"), "violet resolves again")
  Assert.equal(second.map, "MAP_VIOLET", "callers receive copies, never the live table")
  Assert.isNil(FieldMoveSources.spawnDestinationForKey("SPAWN_NOWHERE"))
  Assert.isNil(FieldMoveSources.spawnDestinationForKey(nil))
  ---@diagnostic disable-next-line: param-type-mismatch -- the integer is the invalid input under test
  Assert.isNil(FieldMoveSources.spawnDestinationForKey(7))
end

function T.blackout_destinations_match_all_semantic_spawn_keys()
  local expected = {
    SPAWN_NEW_BARK = { map = "MAP_NEW_BARK_PLAYER_HOUSE_1F", fieldX = 6, fieldZ = 8 },
    SPAWN_CHERRYGROVE = { map = "MAP_CHERRYGROVE_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_VIOLET = { map = "MAP_VIOLET_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_AZALEA = { map = "MAP_AZALEA_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_GOLDENROD = { map = "MAP_GOLDENROD_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_ECRUTEAK = { map = "MAP_ECRUTEAK_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_OLIVINE = { map = "MAP_OLIVINE_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_CIANWOOD = { map = "MAP_CIANWOOD_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_MAHOGANY = { map = "MAP_MAHOGANY_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_LAKE_OF_RAGE = { map = "MAP_LAKE_OF_RAGE", fieldX = 8, fieldZ = 13 },
    SPAWN_BLACKTHORN = { map = "MAP_BLACKTHORN_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_MT_SILVER = { map = "MAP_MOUNT_SILVER_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_PALLET = { map = "MAP_PALLET", fieldX = 8, fieldZ = 13 },
    SPAWN_VIRIDIAN = { map = "MAP_VIRIDIAN_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_PEWTER = { map = "MAP_PEWTER_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_CERULEAN = { map = "MAP_CERULEAN_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_LAVENDER = { map = "MAP_LAVENDER_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_VERMILION = { map = "MAP_VERMILION_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_CELADON = { map = "MAP_CELADON_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_FUCHSIA = { map = "MAP_FUCHSIA_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_CINNABAR = { map = "MAP_CINNABAR_ISLAND_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_INDIGO = { map = "MAP_POKEMON_LEAGUE_ENTRANCE", fieldX = 6, fieldZ = 21 },
    SPAWN_SAFFRON = { map = "MAP_SAFFRON_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_SAFARI = { map = "MAP_SAFARI_ZONE_GATE_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_FRONTIER = { map = "MAP_FRONTIER_ACCESS_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_POKEATHLON = { map = "MAP_POKEATHLON_DOME", fieldX = 8, fieldZ = 13 },
    SPAWN_VICTORY_ROAD = { map = "MAP_ROUTE_22_POKEMON_LEAGUE_RECEPTION_GATE", fieldX = 8, fieldZ = 13 },
    SPAWN_UNION_CAVE = { map = "MAP_ROUTE_32_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_MT_MOON = { map = "MAP_ROUTE_3_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
    SPAWN_ROCK_TUNNEL = { map = "MAP_ROUTE_10_POKECENTER_1F", fieldX = 8, fieldZ = 13 },
  }
  local destinations = FieldMoveSources.BLACKOUT_DESTINATIONS
  Assert.equal(type(destinations), "table")

  local count = 0
  for id, name in pairs(Spawns.byId) do
    if name ~= "SPAWN_NONE" then
      local destination = assert(destinations[name], "missing blackout spawn " .. name)
      Assert.deepEqual(
        { map = destination.map, fieldX = destination.fieldX, fieldZ = destination.fieldZ },
        expected[name]
      )
      Assert.equal(destination.facing, "north", name .. " faces north")
      count = count + 1
    end
  end
  Assert.equal(count, 30)

  local destinationKeys = 0
  for name in pairs(destinations) do
    Assert.notNil(expected[name], "blackout destination has a semantic spawn key")
    destinationKeys = destinationKeys + 1
  end
  Assert.equal(destinationKeys, count)
end

function T.blackout_destinations_reconcile_source_rows_five_through_eight_by_map()
  local destinations = FieldMoveSources.BLACKOUT_DESTINATIONS
  Assert.equal(destinations.SPAWN_GOLDENROD.map, "MAP_GOLDENROD_POKECENTER_1F")
  Assert.equal(destinations.SPAWN_ECRUTEAK.map, "MAP_ECRUTEAK_POKECENTER_1F")
  Assert.equal(destinations.SPAWN_OLIVINE.map, "MAP_OLIVINE_POKECENTER_1F")
  Assert.equal(destinations.SPAWN_CIANWOOD.map, "MAP_CIANWOOD_POKECENTER_1F")
end

return { tests = T }
