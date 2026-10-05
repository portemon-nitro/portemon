-- Verified source move/badge/map/object policy facts for field-move
-- eligibility and map compilation. Producer-only: runtime packages work
-- with the semantic keys projected into generated records, never with the
-- numeric source identities pinned here. Pure data plus small resolvers;
-- no love dependency and no I/O.
--
-- Source basis: pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36
-- src/field_move.c (FieldMove_InitCheckData and the FieldMove_Check*
-- eligibility predicates) and src/save_local_field_data.c
-- (Save_LocalFieldData_Init, whose default lastSpawn is GetMomSpawnId).
-- The obstacle sprite table below starts empty: entries land only with a
-- cited ROM correlation (the map object script invoking the matching
-- field_* standard script), never from sprite-name heuristics.

local FieldMoveSources = {}

-- The complete field-check table: every move the party menu can offer.
FieldMoveSources.MOVE_KEYS = {
  "cut",
  "fly",
  "surf",
  "strength",
  "flash",
  "rock_smash",
  "waterfall",
  "whirlpool",
  "rock_climb",
  "dig",
  "teleport",
  "headbutt",
  "sweet_scent",
  "chatter",
  "defog",
  "escape_rope",
}

-- Semantic badge order shared with the durable progression owner.
FieldMoveSources.BADGE_ORDER = {
  "zephyr",
  "hive",
  "plain",
  "fog",
  "storm",
  "mineral",
  "glacier",
  "rising",
  "boulder",
  "cascade",
  "thunder",
  "rainbow",
  "soul",
  "marsh",
  "volcano",
  "earth",
}

-- The badge gate per move, from the source check predicates. Moves without
-- an entry need no badge: Flash works in any dark place, Headbutt/Sweet
-- Scent/Chatter/Defog/Escape Rope/Dig/Teleport gate on map state instead.
FieldMoveSources.badgeGate = {
  cut = "hive",
  surf = "fog",
  strength = "plain",
  fly = "storm",
  rock_smash = "zephyr",
  waterfall = "rising",
  whirlpool = "glacier",
  rock_climb = "earth",
}

-- Source map-header weather ids where Flash is usable (dark caves).
FieldMoveSources.FLASH_WEATHER_IDS = { 11 }

-- The Ruins of Alph underground hall lights with Flash despite clear
-- weather (the source Alph chamber exception).
FieldMoveSources.ALPH_FLASH_SYMBOL = "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL"

-- Ice Path B2F carries the source Strength exception.
FieldMoveSources.ICE_PATH_B2F_SYMBOL = "MAP_ICE_PATH_B2F"

-- The Union Room link-battle map rejects every external field check.
FieldMoveSources.UNION_COLOSSEUM_SYMBOLS = {
  MAP_UNION = true,
}

-- The default respawn is the mother's house spawn (GetMomSpawnId), pinned
-- against the frozen spawn catalog.
FieldMoveSources.MOTHER_SPAWN_ID = 1
FieldMoveSources.MOTHER_SPAWN_NAME = "SPAWN_NEW_BARK"

-- Source numeric badge indexes (pret/pokeheartgold badge constants) in
-- semantic order: Johto 0..7, Kanto 8..15. The lowering resolves numbers
-- here so generic script code only ever sees semantic badge keys.
FieldMoveSources.BADGE_KEYS = {
  "zephyr",
  "hive",
  "plain",
  "fog",
  "storm",
  "mineral",
  "glacier",
  "rising",
  "boulder",
  "cascade",
  "thunder",
  "rainbow",
  "soul",
  "marsh",
  "volcano",
  "earth",
}

---@param index integer
---@return string|nil
function FieldMoveSources.badgeKeyForIndex(index)
  if type(index) ~= "number" or index % 1 ~= 0 then
    return nil
  end
  return FieldMoveSources.BADGE_KEYS[index + 1]
end
-- Teleport landing table: spawn key -> outdoor arrival map plus
-- destination-global tiles, transcribed from asm/unk_0203BA5C.s
-- sSpawnMaps (30 rows; macro columns flagIdx, isBlackoutSpawn,
-- isFlyPoint, deathSpawnMapNo, deathSpawnX, deathSpawnY,
-- flyPointMapNo, flyPointX, flyPointY, specialWarpMapNo, specialWarpX,
-- specialWarpY). Entries below take the FLY-point columns
-- (GetFlyWarpData reads entry offsets +6/+8/+10): Teleport arrives
-- outdoors at the last-healed vicinity, like Fly, never inside the
-- blackout-interior death columns. Coordinates are destination-global
-- tiles: the fly values track real geography (Cherrygrove west of New
-- Bark, Violet north, Azalea southwest, and so on down both regions).
--
-- Entries are keyed by location identity (the fly/death map columns),
-- cross-checked name-by-name against the frozen spawn catalog
-- (romdump/src/reference/hgss/spawns.lua) and include/constants/spawns.h
-- (SPAWN_NEW_BARK = 1 .. SPAWN_ROCK_TUNNEL = 30): every row's fly map
-- matches its spawn name except rows 5-8, where the file order reads
-- CIANWOOD, GOLDENROD, OLIVINE, ECRUTEAK against catalog ids
-- 5 = GOLDENROD, 6 = ECRUTEAK, 7 = OLIVINE, 8 = CIANWOOD. Location
-- identity governs here: a Goldenrod heal resolves to Goldenrod even
-- where row position disagrees, and the runtime never consumes numeric
-- source identities. Two rows diverge between fly and special columns
-- and keep the fly value: FRONTIER (special = MAP_ROUTE_40) and
-- POKEATHLON (special = MAP_ROUTE_35). Source carries no arrival
-- facing; the runtime stamps the standard arrival facing instead.
FieldMoveSources.SPAWN_DESTINATIONS = {
  SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 },
  SPAWN_CHERRYGROVE = { map = "MAP_CHERRYGROVE", fieldX = 564, fieldZ = 392 },
  SPAWN_VIOLET = { map = "MAP_VIOLET", fieldX = 497, fieldZ = 272 },
  SPAWN_AZALEA = { map = "MAP_AZALEA", fieldX = 410, fieldZ = 461 },
  SPAWN_GOLDENROD = { map = "MAP_GOLDENROD", fieldX = 352, fieldZ = 369 },
  SPAWN_ECRUTEAK = { map = "MAP_ECRUTEAK", fieldX = 397, fieldZ = 184 },
  SPAWN_OLIVINE = { map = "MAP_OLIVINE", fieldX = 272, fieldZ = 258 },
  SPAWN_CIANWOOD = { map = "MAP_CIANWOOD", fieldX = 187, fieldZ = 370 },
  SPAWN_MAHOGANY = { map = "MAP_MAHOGANY", fieldX = 534, fieldZ = 184 },
  SPAWN_LAKE_OF_RAGE = { map = "MAP_LAKE_OF_RAGE", fieldX = 536, fieldZ = 90 },
  SPAWN_BLACKTHORN = { map = "MAP_BLACKTHORN", fieldX = 674, fieldZ = 177 },
  SPAWN_MT_SILVER = { map = "MAP_MOUNT_SILVER", fieldX = 820, fieldZ = 266 },
  SPAWN_PALLET = { map = "MAP_PALLET", fieldX = 1033, fieldZ = 364 },
  SPAWN_VIRIDIAN = { map = "MAP_VIRIDIAN", fieldX = 1032, fieldZ = 263 },
  SPAWN_PEWTER = { map = "MAP_PEWTER", fieldX = 1048, fieldZ = 107 },
  SPAWN_CERULEAN = { map = "MAP_CERULEAN", fieldX = 1309, fieldZ = 132 },
  SPAWN_LAVENDER = { map = "MAP_LAVENDER", fieldX = 1418, fieldZ = 235 },
  SPAWN_VERMILION = { map = "MAP_VERMILION", fieldX = 1297, fieldZ = 295 },
  SPAWN_CELADON = { map = "MAP_CELADON", fieldX = 1231, fieldZ = 238 },
  SPAWN_FUCHSIA = { map = "MAP_FUCHSIA", fieldX = 1209, fieldZ = 440 },
  SPAWN_CINNABAR = { map = "MAP_CINNABAR_ISLAND", fieldX = 1039, fieldZ = 503 },
  SPAWN_INDIGO = { map = "MAP_INDIGO_PLATEAU", fieldX = 912, fieldZ = 201 },
  SPAWN_SAFFRON = { map = "MAP_SAFFRON", fieldX = 1294, fieldZ = 243 },
  SPAWN_SAFARI = { map = "MAP_SAFARI_ZONE_GATE", fieldX = 82, fieldZ = 303 },
  SPAWN_FRONTIER = { map = "MAP_BATTLE_FRONTIER_FRONTIER_ACCESS", fieldX = 8, fieldZ = 15 },
  SPAWN_POKEATHLON = { map = "MAP_POKEATHLON_DOME", fieldX = 42, fieldZ = 23 },
  SPAWN_VICTORY_ROAD = { map = "MAP_ROUTE_26", fieldX = 909, fieldZ = 297 },
  SPAWN_UNION_CAVE = { map = "MAP_ROUTE_32", fieldX = 468, fieldZ = 419 },
  SPAWN_MT_MOON = { map = "MAP_ROUTE_3", fieldX = 1167, fieldZ = 107 },
  SPAWN_ROCK_TUNNEL = { map = "MAP_ROUTE_10", fieldX = 1426, fieldZ = 164 },
}

-- Retail sSpawnMaps death destinations, keyed by the same semantic spawn
-- identity as the outdoor table. Coordinates are local to the death map.
FieldMoveSources.BLACKOUT_DESTINATIONS = {
  SPAWN_NEW_BARK = { map = "MAP_NEW_BARK_PLAYER_HOUSE_1F", fieldX = 6, fieldZ = 8, facing = "north" },
  SPAWN_CHERRYGROVE = { map = "MAP_CHERRYGROVE_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_VIOLET = { map = "MAP_VIOLET_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_AZALEA = { map = "MAP_AZALEA_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_CIANWOOD = { map = "MAP_CIANWOOD_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_GOLDENROD = { map = "MAP_GOLDENROD_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_OLIVINE = { map = "MAP_OLIVINE_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_ECRUTEAK = { map = "MAP_ECRUTEAK_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_MAHOGANY = { map = "MAP_MAHOGANY_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_LAKE_OF_RAGE = { map = "MAP_LAKE_OF_RAGE", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_BLACKTHORN = { map = "MAP_BLACKTHORN_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_MT_SILVER = { map = "MAP_MOUNT_SILVER_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_PALLET = { map = "MAP_PALLET", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_VIRIDIAN = { map = "MAP_VIRIDIAN_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_PEWTER = { map = "MAP_PEWTER_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_CERULEAN = { map = "MAP_CERULEAN_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_LAVENDER = { map = "MAP_LAVENDER_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_VERMILION = { map = "MAP_VERMILION_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_CELADON = { map = "MAP_CELADON_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_FUCHSIA = { map = "MAP_FUCHSIA_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_CINNABAR = { map = "MAP_CINNABAR_ISLAND_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_INDIGO = { map = "MAP_POKEMON_LEAGUE_ENTRANCE", fieldX = 6, fieldZ = 21, facing = "north" },
  SPAWN_SAFFRON = { map = "MAP_SAFFRON_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_SAFARI = { map = "MAP_SAFARI_ZONE_GATE_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_FRONTIER = { map = "MAP_FRONTIER_ACCESS_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_POKEATHLON = { map = "MAP_POKEATHLON_DOME", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_VICTORY_ROAD = { map = "MAP_ROUTE_22_POKEMON_LEAGUE_RECEPTION_GATE", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_UNION_CAVE = { map = "MAP_ROUTE_32_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_MT_MOON = { map = "MAP_ROUTE_3_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
  SPAWN_ROCK_TUNNEL = { map = "MAP_ROUTE_10_POKECENTER_1F", fieldX = 8, fieldZ = 13, facing = "north" },
}

---@param spawnKey string|nil
---@return table<string, unknown>|nil a fresh destination record, never a live table
function FieldMoveSources.spawnDestinationForKey(spawnKey)
  if type(spawnKey) ~= "string" then
    return nil
  end
  local entry = FieldMoveSources.SPAWN_DESTINATIONS[spawnKey]
  if type(entry) ~= "table" then
    return nil
  end
  return { map = entry.map, fieldX = entry.fieldX, fieldZ = entry.fieldZ }
end

FieldMoveSources.OBSTACLE_KINDS = {
  "cut_tree",
  "smash_rock",
  "strength_boulder",
  "headbutt_tree",
}

-- Sprite id -> obstacle kind, verified against ROM script correlations.
-- Empty until the first cited entry: the compiler decorates only proven
-- identities, and an undecorated actor fails obstacle checks loudly.
--
-- Cited entries (pret/pokeheartgold@9d8b7591 src/field_move.c,
-- FieldMove_InitCheckData maps facing-object sprites to check flags:
-- SPRITE_TREE (86) -> TREE, SPRITE_ROCK (84) -> ROCK, SPRITE_BREAKROCK
-- (85) -> BREAKROCK; include/constants/sprites.h pins the numbers; the
-- menu entries std_menu_cut/strength/rock_smash consume the same facing
-- object):
-- ROM correlation on the canonical SoulSilver dump (540 maps, 2667 object
-- events): sprite 86 appears 48 times (all with per-object presence flags
-- 16..22, e.g. MAP_ROUTE_2/MAP_ROUTE_9), sprite 84 appears 33 times, and
-- sprite 85 appears 103 times (e.g. MAP_BURNED_TOWER_1F/MAP_ROUTE_3).
-- The identities are live shipped data used through the same facing-object
-- mechanism, never sprite-name heuristics.
local SPRITE_OBSTACLE_KINDS = {
  [86] = "cut_tree",
  [84] = "strength_boulder",
  [85] = "smash_rock",
}

---@param spriteId integer
---@return string|nil
function FieldMoveSources.obstacleKindForSprite(spriteId)
  return SPRITE_OBSTACLE_KINDS[spriteId]
end

return FieldMoveSources
