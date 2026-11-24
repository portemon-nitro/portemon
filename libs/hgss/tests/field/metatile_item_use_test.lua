-- The tile predicates behind the Bicycle and fishing-rod use checks.

local Assert = require("tests.support.Assert")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local T = {}

local RIVER_WATER = 16
local VERY_TALL_GRASS = 3
local MUD = 164
local BRIDGE_START = 112
local BRIDGE = 113

function T.bikes_refuse_very_tall_grass_and_mud_underfoot()
  Assert.isTrue(MetatileBehavior.isBikeHostileGround(VERY_TALL_GRASS))
  Assert.isTrue(MetatileBehavior.isBikeHostileGround(MUD))
  Assert.isFalse(MetatileBehavior.isBikeHostileGround(0))
end

function T.rods_cast_into_water_ahead_but_never_from_a_bridge_deck()
  Assert.isTrue(MetatileBehavior.canFishFrom(0, RIVER_WATER))
  Assert.isTrue(MetatileBehavior.canFishFrom(RIVER_WATER, RIVER_WATER), "a surfing player fishes too")
  Assert.isFalse(MetatileBehavior.canFishFrom(0, 0))
  Assert.isFalse(MetatileBehavior.canFishFrom(BRIDGE_START, RIVER_WATER))
  Assert.isFalse(MetatileBehavior.canFishFrom(BRIDGE, RIVER_WATER))
end

return { tests = T }
