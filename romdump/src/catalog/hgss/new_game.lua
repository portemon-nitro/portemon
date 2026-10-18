-- Frozen producer facts for the fresh-New-Game player-room start, normalized
-- from the retail ROM: the player-room start location is
-- MAP_NEW_BARK_PLAYER_HOUSE_2F (map id 64) at x/y 0x6 facing 0x1, and
-- DIR_SOUTH is 1.
-- Producer-only reference data: game and asset code must never require this
-- module; producers publish only the normalized facing downstream.

return {
  repository = "retail ROM",
  sourcePaths = {
    "src/location_backup.c",
    "include/constants/maps.h",
    "include/constants/global_fieldmap.h",
  },
  playerRoom = {
    mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
    mapId = 64,
    fieldX = 6,
    fieldZ = 6,
    sourceDirection = 1,
    facing = "south",
  },
}
