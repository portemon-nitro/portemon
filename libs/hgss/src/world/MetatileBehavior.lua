-- MetatileBehavior: the TILE_BEHAVIOR_* metatile behavior byte vocabulary
-- (sequential enum, NONE = 255) plus the pure behavior predicates the field runtime
-- shares. The vocabulary lives below gameplay trigger policy so door-tile
-- enumeration and door lookup never depend on the whole TransitionTrigger
-- module. Pure domain module (no love).

local MetatileBehavior = {}

local LEDGE_DIRECTIONS = {}
local WALKING_ENCOUNTER_BEHAVIORS = {
  [2] = true,
  [3] = true,
  [5] = true,
  [8] = true,
  [11] = true,
  [16] = true,
  [18] = true,
  [21] = true,
  [37] = true,
  [42] = true,
  [114] = true,
  [119] = true,
  [123] = true,
  [166] = true,
  [167] = true,
}

-- TILE_BEHAVIOR_* warp-relevant values.
MetatileBehavior.BEHAVIOR = {
  TALL_GRASS = 2,
  VERY_TALL_GRASS = 3,
  HEADBUTT = 6,
  RIVER_WATER = 16,
  WHIRLPOOL = 17,
  WATERFALL = 19,
  SEA_WATER = 21,
  JUMP_EAST = 56,
  JUMP_WEST = 57,
  JUMP_NORTH = 58,
  JUMP_SOUTH = 59,
  ROCK_CLIMB_NORTH_SOUTH = 75,
  ROCK_CLIMB_EAST_WEST = 76,
  LADDER_NORTH = 60,
  LADDER_SOUTH = 61,
  LADDER_DOWN = 62,
  WARP_STAIRS_EAST = 94,
  WARP_STAIRS_WEST = 95,
  WARP_ENTRANCE_EAST = 98,
  WARP_ENTRANCE_WEST = 99,
  WARP_ENTRANCE_NORTH = 100,
  WARP_ENTRANCE_SOUTH = 101,
  WARP_PANEL = 103,
  DOOR = 105,
  ESCALATOR_FLIP_FACE = 106,
  ESCALATOR = 107,
  WARP_EAST = 108,
  WARP_WEST = 109,
  WARP_NORTH = 110,
  WARP_SOUTH = 111,
  -- TILE_BEHAVIOR_128: objects behind it answer the Action button.
  COUNTER = 128,
  PC = 131,
}

LEDGE_DIRECTIONS[MetatileBehavior.BEHAVIOR.JUMP_EAST] = "east"
LEDGE_DIRECTIONS[MetatileBehavior.BEHAVIOR.JUMP_WEST] = "west"
LEDGE_DIRECTIONS[MetatileBehavior.BEHAVIOR.JUMP_NORTH] = "north"
LEDGE_DIRECTIONS[MetatileBehavior.BEHAVIOR.JUMP_SOUTH] = "south"

-- Whether a behavior byte is the DOOR metatile (behavior 105).
---@param behavior integer?
---@return boolean
function MetatileBehavior.isDoor(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.DOOR
end

-- TILE_BEHAVIOR_* values flagged surfable by the source behavior flag table
-- (MetatileBehavior_IsSurfableWater).
local SURFABLE_WATER = {}
for _, behavior in ipairs({ 16, 17, 18, 19, 20, 21, 25, 42, 80, 81, 82, 83, 115, 120, 124 }) do
  SURFABLE_WATER[behavior] = true
end

---@param behavior integer?
---@return boolean
function MetatileBehavior.isSurfableWater(behavior)
  return SURFABLE_WATER[behavior] == true
end

-- Field_PlayerCanSurfOnTile: the facing tile must be surfable water and the
-- standing tile must not be a bridge/bridge-start tile (the source refuses
-- while the avatar's on-bridge flag is set, which bridge tiles maintain) or
-- behavior 34.
---@param standing integer?
---@param facing integer?
---@return boolean
function MetatileBehavior.canSurfOnto(standing, facing)
  if not MetatileBehavior.isSurfableWater(facing) then
    return false
  end
  return not (standing == 112 or standing == 113 or standing == 114 or standing == 115 or standing == 34)
end

-- MetatileBehavior_IsRockClimbInDirection: north/south facing needs the
-- north/south climb behavior, east/west facing the east/west one.
---@param behavior integer?
---@param facing string
---@return boolean
function MetatileBehavior.isRockClimbInDirection(behavior, facing)
  if facing == "north" or facing == "south" then
    return behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH
  end
  assert(facing == "east" or facing == "west", "rock climb needs a cardinal facing")
  return behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_EAST_WEST
end

---@param behavior integer?
---@return string?
function MetatileBehavior.fieldAction(behavior)
  if behavior == MetatileBehavior.BEHAVIOR.WATERFALL then
    return "waterfall"
  elseif behavior == MetatileBehavior.BEHAVIOR.WHIRLPOOL then
    return "whirlpool"
  elseif MetatileBehavior.isSurfableWater(behavior) then
    return "surf"
  elseif
    behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_EAST_WEST
    or behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH
  then
    return "rock_climb"
  end
  return nil
end

---@param behavior integer?
---@return string?
function MetatileBehavior.ledgeDirection(behavior)
  return LEDGE_DIRECTIONS[behavior]
end

---@param behavior integer?
---@return boolean
function MetatileBehavior.isTallGrass(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.TALL_GRASS
end

---@param behavior integer?
---@return boolean
function MetatileBehavior.isVeryTallGrass(behavior)
  return behavior == MetatileBehavior.BEHAVIOR.VERY_TALL_GRASS
end

---@param behavior integer?
---@return boolean
function MetatileBehavior.suppressesFollowerReaction(behavior)
  return behavior == 46 or behavior == 113 or behavior == 114
end

---@param behavior integer?
---@return boolean
function MetatileBehavior.canGenerateWalkingEncounters(behavior)
  return WALKING_ENCOUNTER_BEHAVIORS[behavior] == true
end

local WARP_ENTRANCE_DIRECTIONS = {
  [MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_NORTH] = "north",
  [MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_SOUTH] = "south",
  [MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_WEST] = "west",
  [MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST] = "east",
}

---@param behavior integer?
---@return string?
function MetatileBehavior.warpEntranceDirection(behavior)
  return WARP_ENTRANCE_DIRECTIONS[behavior]
end

return MetatileBehavior
