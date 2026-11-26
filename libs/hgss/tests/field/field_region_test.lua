-- FieldRegion tests cover collision routing and translated BDHC surfaces over
-- the central cell plus cached neighbors, including a connected edge crossing.

local Assert = require("tests.support.Assert")
local FieldRegion = require("libs.hgss.src.world.FieldRegion")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local function collision(blocked)
  return {
    containsLocal = function(_, x, z)
      return x >= 0 and x < 32 and z >= 0 and z < 32
    end,
    isBlockedLocal = function(_, x, z)
      return blocked and blocked[x .. ":" .. z] or false
    end,
    getLocal = function(_, x, z)
      return { x = x, z = z, blocked = false }
    end,
  }
end

local function flatTerrain(height)
  return TerrainSurface.new({
    schema = "g4-terrain-surfaces-v1",
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = height,
        slopeClass = "flat",
        walkable = true,
      },
    },
  })
end

function T.routes_collision_to_neighbor_cell_coordinates()
  local region = FieldRegion.new(collision(), flatTerrain(0), {
    {
      offsetTilesX = 32,
      offsetTilesY = 1,
      offsetTilesZ = 0,
      collision = collision({ ["0:4"] = true }),
      terrain = flatTerrain(0),
    },
  })
  Assert.isTrue(region.collision:containsLocal(63, 4))
  Assert.isFalse(region.collision:containsLocal(64, 4))
  Assert.isTrue(region.collision:isBlockedLocal(32, 4))
  Assert.isFalse(region.collision:isBlockedLocal(31, 4))
  Assert.equal(region.collision:getLocal(33, 5).x, 1)
end

function T.translates_neighbor_surfaces_and_connects_shared_edge()
  local region = FieldRegion.new(collision(), flatTerrain(2), {
    {
      key = "1:0",
      offsetTilesX = 32,
      offsetTilesY = 1,
      offsetTilesZ = 0,
      collision = collision(),
      terrain = flatTerrain(2),
    },
  }, "0:0")
  local candidates = region.terrain:candidatesAt(32.5, 4.5)
  Assert.equal(#candidates, 1)
  Assert.equal(candidates[1].sourceSurfaceId, 0)
  Assert.equal(candidates[1].cellOffsetX, 32)
  Assert.equal(candidates[1].cellOffsetY, 1)
  Assert.equal(region.terrain:sampleHeight(candidates[1].id, 32.5, 4.5), 3)

  local resolved = SurfaceResolver.new(region.terrain):resolve({
    localX = 32.5,
    localZ = 4.5,
    currentSurfaceId = 0,
    currentY = 2,
    crossing = { fromX = 31.5, fromZ = 4.5, toX = 32.5, toZ = 4.5 },
  })
  Assert.equal(resolved.surfaceId, candidates[1].id)
end

function T.leaves_central_surfaces_local_without_a_physical_cell_key()
  local region = FieldRegion.new(collision(), flatTerrain(0), {})
  local plate = assert(region.terrain:plate(0))
  Assert.isNil(plate.cellKey)
  Assert.isNil(plate.sourceSurfaceId)
end

function T.translates_sloped_plane_distance_with_vertical_offset()
  local slope = TerrainSurface.new({
    plates = {
      {
        id = 4,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = -1, y = 1, z = 0 },
        distance = 0,
        slopeClass = "ramp-east",
        walkable = true,
      },
    },
  })
  local region = FieldRegion.new(collision(), flatTerrain(0), {
    { offsetTilesX = -32, offsetTilesY = 1, offsetTilesZ = 32, collision = collision(), terrain = slope },
  })
  local plate = region.terrain:candidatesAt(-31.5, 32.5)[1]
  Assert.equal(region.terrain:sampleHeight(plate.id, -31.5, 32.5), 1.5)
end

-- The composition is resumable: advancing one plate at a time produces the same
-- composite region as the blocking constructor, so a caller may spread a whole
-- window over frames without changing what commits.
function T.resumable_composition_matches_the_blocking_constructor()
  local neighborCollision = collision({ ["0:4"] = true })
  local neighborTerrain = flatTerrain(2)
  local neighbors = {
    {
      key = "1:0",
      offsetTilesX = 32,
      offsetTilesY = 1,
      offsetTilesZ = 0,
      collision = neighborCollision,
      terrain = neighborTerrain,
    },
  }
  local blocking = FieldRegion.new(collision(), flatTerrain(2), neighbors, "0:0")
  local task = FieldRegion.begin(collision(), flatTerrain(2), neighbors, "0:0")
  Assert.isFalse(task:isReady(), "beginning the composition copies nothing yet")
  local first = task:advance(1)
  Assert.equal(first, 1, "one unit copies exactly one plate")
  Assert.isFalse(task:isReady(), "one plate is not the whole region")
  local resumed = task:finish()

  Assert.equal(#resumed.terrain.plates, #blocking.terrain.plates, "the resumable composition copies every plate")
  for index, plate in ipairs(blocking.terrain.plates) do
    local other = resumed.terrain.plates[index]
    Assert.equal(other.id, plate.id, "plate identity survives the split composition")
    Assert.equal(other.cellKey, plate.cellKey)
    Assert.equal(other.sourceSurfaceId, plate.sourceSurfaceId)
    Assert.equal(other.minX, plate.minX)
    Assert.equal(other.distance, plate.distance)
  end
  Assert.equal(resumed:sourceSurface("1:0", 0), blocking:sourceSurface("1:0", 0))
  Assert.equal(resumed.terrain:sampleHeight(resumed:sourceSurface("1:0", 0), 32.5, 4.5), 3)
  Assert.isTrue(resumed.collision:isBlockedLocal(32, 4), "the composed collision still routes to the neighbor")
end

return { tests = T }
