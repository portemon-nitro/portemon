-- The gym mechanism's runtime geometry: the source 3x3 lift plate projected
-- over the map's generated terrain, its absolute-ambiguity-free down state, the
-- settled floor, and the wrapper that never mutates the generated plates.

local Assert = require("tests.support.Assert")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local GymMechanismGeometry = require("libs.hgss.src.field.GymMechanismGeometry")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local function flatPlate(id, distance)
  return {
    id = id,
    minX = -64,
    minZ = -64,
    maxX = 64,
    maxZ = 64,
    normal = { x = 0, y = 1, z = 0 },
    distance = distance,
    slopeClass = "flat",
  }
end

local function runtimeMap(originX, originZ)
  local plates = { flatPlate(0, 0), flatPlate(1, 0) }
  return {
    mapId = 135,
    mapSymbol = "MAP_VIOLET_GYM",
    coordinateOrigin = { x = originX or 0, z = originZ or 0 },
    collision = {
      containsLocal = function()
        return true
      end,
    },
    terrain = TerrainSurface.new({ plates = plates, schema = "test-terrain" }),
  }, plates
end

-- The lower stop publishes no plate at all: the generated floor answers those
-- samples, so one point is never two coincident surfaces.
function T.the_lower_stop_publishes_no_dynamic_plate()
  local map = runtimeMap()
  local base = map.terrain
  local geometry = GymMechanismGeometry.new()
  geometry:restoreViolet(false)
  geometry:bindMap(map)
  Assert.isNil(geometry:plate(), "a car on the lower stop needs no plate")
  Assert.equal(#map.terrain:candidatesAt(15.5, 20.5), #base:candidatesAt(15.5, 20.5))
  Assert.equal(map.terrain:sample(0, 15.5, 20.5).worldY, 0, "the floor still answers the pad")
end

-- The upper stop projects the source 3x3 plate at tile (14,19): the covered
-- tiles answer the raised floor as one more walkable surface, everything else
-- is untouched, and the generated plate list is never modified.
function T.the_upper_stop_projects_the_source_plate_over_the_map_floor()
  local map, plates = runtimeMap()
  local plateCount = #plates
  local geometry = GymMechanismGeometry.new()
  geometry:restoreViolet(true)
  geometry:bindMap(map)
  local plate = assert(geometry:plate(), "the raised car publishes its plate")
  Assert.equal(plate.minX, 14)
  Assert.equal(plate.maxX, 17)
  Assert.equal(plate.minZ, 19)
  Assert.equal(plate.maxZ, 22)
  Assert.equal(plate.height, GymMechanismGeometry.ELEVATOR_TILES, "the plate sits the source 29 tiles up")

  local surfaceId = GymMechanismGeometry.PLATE_SURFACE_ID
  Assert.isTrue(map.terrain:contains(surfaceId, 15.5, 20.5), "the pad is on the plate")
  Assert.isTrue(map.terrain:contains(surfaceId, 15.5, 21.5), "the approach tile is on the plate")
  Assert.isFalse(map.terrain:contains(surfaceId, 15.5, 22.5), "a tile past the plate is not")
  Assert.equal(map.terrain:sampleHeight(surfaceId, 15.5, 20.5), 29)
  local candidates = map.terrain:candidatesAt(15.5, 20.5)
  local dynamic
  for _, candidate in ipairs(candidates) do
    if candidate.id == surfaceId then
      dynamic = candidate
    end
  end
  Assert.notNil(dynamic, "the raised plate is one more candidate at the pad")
  Assert.equal(#plates, plateCount, "the generated plate list is never mutated")
  Assert.notNil(map.terrain:plate(surfaceId), "the plate resolves by id")
  Assert.isFalse(map.terrain:contains(surfaceId, 20.5, 20.5), "the wider floor is not part of the car")
  local cellKey, sourceSurfaceId = map.terrain:sourceIdentity(map.terrain:plate(surfaceId))
  Assert.isNil(cellKey, "the dynamic plate carries no source-cell identity")
  Assert.isNil(sourceSurfaceId)
end

-- Map-origin arithmetic: the plate follows the map's own coordinate origin, so
-- a shifted runtime map projects the same source tile.
function T.the_plate_follows_the_map_coordinate_origin()
  local map = runtimeMap(40, 60)
  local geometry = GymMechanismGeometry.new()
  geometry:restoreViolet(true)
  geometry:bindMap(map)
  local plate = assert(geometry:plate())
  Assert.equal(plate.minX, 14 - 40)
  Assert.equal(plate.minZ, 19 - 60)
  Assert.isTrue(map.terrain:contains(GymMechanismGeometry.PLATE_SURFACE_ID, 15.5 - 40, 20.5 - 60))
end

-- Rebinding and releasing: the settled floor survives a rebind (the map load,
-- not the rebind, owns it), and detaching gives the generated terrain back.
function T.rebinding_keeps_the_floor_and_detaching_restores_the_terrain()
  local map = runtimeMap()
  local base = map.terrain
  local geometry = GymMechanismGeometry.new()
  geometry:restoreViolet(true)
  geometry:bindMap(map)
  Assert.isTrue(map.terrain ~= base, "the map answers through the plate wrapper")
  geometry:restoreViolet(true)
  geometry:bindMap(map)
  Assert.isTrue(geometry:isVioletRaised(), "a rebind keeps the settled floor")
  geometry:restoreViolet(false)
  geometry:bindMap(map)
  Assert.isNil(geometry:plate(), "the map load owns the settled floor")
  geometry:unbind()
  Assert.equal(map.terrain, base, "the generated terrain answers again")
  Assert.equal(#base:candidatesAt(15.5, 20.5), 2, "the generated candidates are untouched")
end

-- The car's own source transform: it stands on the pad centre tile at the
-- floor the plate covers, and the settled height is that floor plus the source
-- travel only while the car is raised.
function T.the_car_stands_on_the_pad_centre_at_its_settled_height()
  local map = runtimeMap(40, 60)
  local geometry = GymMechanismGeometry.new()
  geometry:restoreViolet(false)
  geometry:bindMap(map)
  Assert.equal(geometry:violetCarWorldY(), 0, "the lowered car stands on the generated floor")
  local point = assert(geometry:violetCarWorldPoint(), "the bound map answers the car placement")
  local expectedX, expectedZ = FieldGrid.tileCenterToWorld(
    GymMechanismGeometry.ELEVATOR_CAR_FIELD_X - 40,
    GymMechanismGeometry.ELEVATOR_CAR_FIELD_Z - 60
  )
  Assert.equal(point.x, expectedX, "the source prop position is the pad centre tile in x")
  Assert.equal(point.z, expectedZ, "the source prop position is the pad centre tile in z")
  Assert.equal(geometry:floorWorldY(15, 20), 0, "the pad floor is the map's own surface")

  geometry:setVioletRaised(true)
  Assert.equal(geometry:violetCarWorldY(), GymMechanismGeometry.ELEVATOR_TILES)
  Assert.equal(geometry:violetCarWorldY(), assert(geometry:plate()).height, "the car stands on its own plate")
  geometry:unbind()
  Assert.isNil(geometry:violetCarWorldPoint(), "an unbound mechanism presents no car")
end

return { tests = T }
