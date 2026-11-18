-- FieldTerrainResponse maps a committed destination behavior to a semantic
-- presentation response without depending on runtime or presentation state.

local Assert = require("tests.support.Assert")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local FieldTerrainResponse = require("libs.hgss.src.world.FieldTerrainResponse")

local T = { metadata = { capabilities = {} }, tests = {} }

local function resolve(behavior)
  return FieldTerrainResponse.resolve({
    committed = true,
    destination = {
      behavior = behavior,
      fieldX = 12,
      fieldZ = 18,
      worldY = 2.5,
      cellKey = "1:2",
      sourceSurfaceId = 7,
    },
    direction = "north",
  })
end

T.tests["grass behaviors produce non-directional destination responses"] = function()
  local tall = resolve(MetatileBehavior.BEHAVIOR.TALL_GRASS)
  Assert.equal(#tall, 1)
  Assert.equal(tall[1].kind, "tall_grass")
  Assert.equal(tall[1].fieldX, 12)
  Assert.equal(tall[1].fieldZ, 18)
  Assert.equal(tall[1].worldY, 2.5)
  Assert.keySet(tall[1], "cellKey,fieldX,fieldZ,kind,sourceSurfaceId,worldY")
  Assert.equal(tall[1].cellKey, "1:2")
  Assert.equal(tall[1].sourceSurfaceId, 7)

  local veryTall = resolve(MetatileBehavior.BEHAVIOR.VERY_TALL_GRASS)
  Assert.equal(#veryTall, 1)
  Assert.equal(veryTall[1].kind, "very_tall_grass")
  Assert.equal(veryTall[1].fieldX, 12)
  Assert.equal(veryTall[1].fieldZ, 18)
  Assert.equal(veryTall[1].worldY, 2.5)
  Assert.keySet(veryTall[1], "cellKey,fieldX,fieldZ,kind,sourceSurfaceId,worldY")
  Assert.equal(veryTall[1].cellKey, "1:2")
  Assert.equal(veryTall[1].sourceSurfaceId, 7)
end

-- One stepping map object's committed destination. The follower is the only
-- non-player object the runtime steps through this resolver; a large follower
-- (source shape nibble above zero) also disturbs the grass behind it when it
-- faces east or west, exactly like MapObject_SpawnTallGrassOnStep.
local function followerMap(behaviors)
  return {
    coordinateOrigin = { x = 10, z = 20 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 8 and z >= 0 and z < 8
      end,
      getLocal = function(_, x, z)
        return { behavior = behaviors[x + 10 .. ":" .. (z + 20)] or 0 }
      end,
    },
  }
end

local function resolveStep(map, overrides)
  local input = {
    map = map,
    fieldX = 12,
    fieldZ = 22,
    worldY = 2.5,
    facing = "south",
    cellKey = "1:2",
    sourceSurfaceId = 7,
    large = false,
  }
  for key, value in pairs(overrides or {}) do
    input[key] = value
  end
  return FieldTerrainResponse.resolveActorStep(input)
end

T.tests["a follower step resolves grass at its own committed tile"] = function()
  local map = followerMap({ ["12:22"] = MetatileBehavior.BEHAVIOR.TALL_GRASS })
  local responses = resolveStep(map)
  Assert.equal(#responses, 1)
  Assert.equal(responses[1].kind, "tall_grass")
  Assert.equal(responses[1].fieldX, 12)
  Assert.equal(responses[1].fieldZ, 22)
  Assert.equal(responses[1].worldY, 2.5)
  Assert.equal(responses[1].cellKey, "1:2")
  Assert.equal(responses[1].sourceSurfaceId, 7)
end

T.tests["a follower step on ordinary ground resolves nothing"] = function()
  Assert.equal(#resolveStep(followerMap({})), 0)
  local outside = followerMap({})
  outside.collision.containsLocal = function()
    return false
  end
  Assert.equal(#resolveStep(outside), 0)
end

T.tests["a large eastward or westward follower also disturbs the tile behind it"] = function()
  local map = followerMap({
    ["12:22"] = MetatileBehavior.BEHAVIOR.TALL_GRASS,
    ["11:22"] = MetatileBehavior.BEHAVIOR.VERY_TALL_GRASS,
    ["13:22"] = MetatileBehavior.BEHAVIOR.VERY_TALL_GRASS,
  })
  local east = resolveStep(map, { facing = "east", large = true })
  Assert.equal(#east, 2, "a large east-facing follower disturbs both tiles")
  Assert.equal(east[1].kind, "tall_grass")
  Assert.equal(east[2].kind, "very_tall_grass")
  Assert.equal(east[2].fieldX, 11, "behind an east-facing object is one tile west")

  local west = resolveStep(map, { facing = "west", large = true })
  Assert.equal(#west, 2, "a large west-facing follower disturbs both tiles")
  Assert.equal(west[2].fieldX, 13, "behind a west-facing object is one tile east")

  Assert.equal(#resolveStep(map, { facing = "east", large = false }), 1, "a small follower never reaches behind")
  Assert.equal(#resolveStep(map, { facing = "north", large = true }), 1, "a vertical large follower has no side tile")
end

T.tests["uncommitted or non-grass movement produces no response"] = function()
  Assert.equal(#resolve(0), 0)
  local result = FieldTerrainResponse.resolve({
    committed = false,
    destination = { behavior = MetatileBehavior.BEHAVIOR.TALL_GRASS, fieldX = 1, fieldZ = 1, worldY = 0 },
    direction = "south",
  })
  Assert.equal(#result, 0)
end

return T
