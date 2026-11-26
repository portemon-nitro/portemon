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

-- One plate list with its own source record order: the composite region keeps
-- every cell's records in the order that cell's BDHC declared them.
---@param plates { minX: number, maxX: number, minZ: number, maxZ: number, distance: number }[]
---@return TerrainSurface
local function flatCells(plates)
  local records = {}
  for index, plate in ipairs(plates) do
    records[index] = {
      id = index - 1,
      minX = plate.minX,
      minZ = plate.minZ,
      maxX = plate.maxX,
      maxZ = plate.maxZ,
      normal = { x = 0, y = 1, z = 0 },
      distance = plate.distance,
      slopeClass = "flat",
      walkable = true,
    }
  end
  return TerrainSurface.new({ schema = "g4-terrain-surfaces-v1", plates = records })
end

-- A neighbor cell whose BDHC declares the same floor twice: retail resolves a
-- BDHC's records in source order, and the Rocket Hideout's own neighbor chunk
-- carries exactly this overlap (a wide strip plus a one-tile split of it at the
-- same height). The composite region joins the two cells, so the duplicated
-- record must not become an equal candidate of its own cell.
function T.duplicate_neighbor_plates_resolve_to_the_first_source_record()
  local region = FieldRegion.new(collision(), flatCells({ { minX = 0, maxX = 32, minZ = 0, maxZ = 32, distance = 1 } }), {
    {
      offsetTilesX = 32,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      collision = collision(),
      terrain = flatCells({
        { minX = 12, maxX = 20, minZ = 0, maxZ = 32, distance = 1 },
        { minX = 12, maxX = 20, minZ = 3, maxZ = 4, distance = 1 },
        { minX = 12, maxX = 13, minZ = 3, maxZ = 4, distance = 1 },
      }),
    },
  })
  local candidates = region.terrain:candidatesAt(44.5, 3.5)
  Assert.equal(#candidates, 1, "the neighbor's duplicated floor record is one surface")
  Assert.equal(candidates[1].minX, 44, "the first source record carries the surface identity")
  Assert.equal(region.terrain:sampleHeight(candidates[1].id, 44.5, 3.5), 1)
end

-- A coordinate the central cell covers resolves against the central cell's own
-- plates, even when a translated neighbor plate reaches over the seam: the
-- central cell is the first containing cell, never a tie between two cells.
function T.central_cell_plates_win_a_coordinate_both_cells_cover()
  local region = FieldRegion.new(
    collision(),
    flatCells({ { minX = 0, maxX = 33, minZ = 0, maxZ = 32, distance = 2 } }),
    {
      {
        offsetTilesX = 32,
        offsetTilesY = 0,
        offsetTilesZ = 0,
        collision = collision(),
        terrain = flatCells({ { minX = -1, maxX = 20, minZ = 0, maxZ = 32, distance = 3 } }),
      },
    }
  )
  local candidates = region.terrain:candidatesAt(32.5, 4.5)
  Assert.equal(#candidates, 1, "both cells cover the coordinate through one resolved cell")
  Assert.equal(candidates[1].cellOffsetX, 0, "the central cell is the first containing cell")
  Assert.equal(region.terrain:sampleHeight(candidates[1].id, 32.5, 4.5), 2)
end

-- Coverage outside the central cell still resolves through the neighbor: the
-- cell preference never drops a coordinate the central cell does not reach.
function T.neighbor_coverage_outside_the_central_cell_is_preserved()
  local region = FieldRegion.new(collision(), flatCells({ { minX = 0, maxX = 32, minZ = 0, maxZ = 32, distance = 1 } }), {
    {
      offsetTilesX = 32,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      collision = collision(),
      terrain = flatCells({ { minX = 0, maxX = 32, minZ = 0, maxZ = 32, distance = 5 } }),
    },
  })
  local candidates = region.terrain:candidatesAt(40.5, 8.5)
  Assert.equal(#candidates, 1)
  Assert.equal(candidates[1].cellOffsetX, 32, "the neighbor covers the coordinate on its own")
  Assert.equal(region.terrain:sampleHeight(candidates[1].id, 40.5, 8.5), 5)
  Assert.equal(#region.terrain:candidatesAt(70.5, 8.5), 0, "a coordinate no cell covers has no surface")
end

-- Genuinely distinct plates that share a height still raise: a flat floor and a
-- ramp crossing it at the sampled point are two different surfaces, and picking
-- one silently would change the slope a walker stands on.
function T.distinct_plates_at_one_height_still_report_ambiguity()
  local normal = { x = -0.70710678118654757, y = 0.70710678118654757, z = 0 }
  local function rampDistanceAt(localY)
    return localY * normal.y + normal.x * 12.5
  end
  local opposing = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 12,
        minZ = 0,
        maxX = 20,
        maxZ = 32,
        normal = { x = normal.x, y = normal.y, z = normal.z },
        distance = rampDistanceAt(1),
        slopeClass = "ramp_x",
        walkable = true,
      },
      {
        id = 1,
        minX = 12,
        maxX = 20,
        minZ = 0,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 1,
        slopeClass = "flat",
        walkable = true,
      },
    },
  })
  Assert.isTrue(
    math.abs(opposing:sampleHeight(0, 12.5, 3.5) - 1) < 1e-9,
    "the two distinct planes share the sampled height"
  )
  local region = FieldRegion.new(collision(), flatCells({ { minX = 0, maxX = 32, minZ = 0, maxZ = 32, distance = 1 } }), {
    { offsetTilesX = 32, offsetTilesY = 0, offsetTilesZ = 0, collision = collision(), terrain = opposing },
  })
  local err = Assert.throws(function()
    SurfaceResolver.new(region.terrain):resolve({ localX = 44.5, localZ = 3.5, currentY = 1 })
  end)
  Assert.equal(err.code, "TERRAIN_SURFACE_AMBIGUOUS")
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
