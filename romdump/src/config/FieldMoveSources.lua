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
FieldMoveSources.OBSTACLE_KINDS = {
  "cut_tree",
  "smash_rock",
  "strength_boulder",
  "headbutt_tree",
}

-- Sprite id -> obstacle kind, verified against ROM script correlations.
-- Empty until the first cited entry: the compiler decorates only proven
-- identities, and an undecorated actor fails obstacle checks loudly.
local SPRITE_OBSTACLE_KINDS = {}

---@param spriteId integer
---@return string|nil
function FieldMoveSources.obstacleKindForSprite(spriteId)
  return SPRITE_OBSTACLE_KINDS[spriteId]
end

return FieldMoveSources
