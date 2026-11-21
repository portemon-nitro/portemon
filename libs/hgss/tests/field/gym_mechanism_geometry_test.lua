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
  },
    plates
end

-- The Blackthorn gym's own map: a generated permission grid whose lava tiles are
-- walkable, one non-magma tile per column set by the test, and the same generated
-- floors as any other gym tile.
local function blackthornMap(options)
  options = options or {}
  local originX, originZ = options.originX or 0, options.originZ or 40
  local cells = {}
  local function at(x, z)
    local key = x .. ":" .. z
    local cell = cells[key]
    if cell == nil then
      local behavior = options.behavior and options.behavior[key] or 44
      cell = { behavior = behavior, terrainResponseId = 0, blocked = options.blocked and options.blocked[key] or false }
      cells[key] = cell
    end
    return cell
  end
  local generated = {
    width = 96,
    height = 96,
    cells = {},
    containsLocal = function(self, localX, localZ)
      return localX >= 0 and localZ >= 0 and localX < self.width and localZ < self.height
    end,
    getLocal = function(self, localX, localZ)
      local cell = at(localX + originX, localZ + originZ)
      return { behavior = cell.behavior, terrainResponseId = cell.terrainResponseId, blocked = cell.blocked }
    end,
    isBlockedLocal = function(self, localX, localZ)
      return at(localX + originX, localZ + originZ).blocked == true
    end,
  }
  local plates = { flatPlate(0, 3) }
  return {
    mapId = 141,
    mapSymbol = "MAP_BLACKTHORN_GYM",
    coordinateOrigin = { x = originX, z = originZ },
    collision = generated,
    terrain = TerrainSurface.new({ plates = plates, schema = "test-terrain" }),
  },
    plates,
    generated
end

local BLACKTHORN_BUCKETS = {
  { x = 13, z = 75, rotation = 0 },
  { x = 9, z = 58, rotation = 1 },
  { x = 14, z = 32, rotation = 0 },
}

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

-- The Blackthorn floors answer before the map's own permission: a platform
-- floor is walkable, the lava outside one is blocked, and every other tile keeps
-- the generated permission.
function T.the_blackthorn_floors_answer_before_the_generated_permission()
  local map, _, generated = blackthornMap({ blocked = { ["13:75"] = true } })
  local geometry = GymMechanismGeometry.new()
  geometry:setBlackthornPlatforms(BLACKTHORN_BUCKETS)
  geometry:bindMap(map)
  Assert.isTrue(map.collision ~= generated, "the map answers through the platform projection")

  local function blocked(fieldX, fieldZ)
    local localX, localZ = fieldX - map.coordinateOrigin.x, fieldZ - map.coordinateOrigin.z
    return map.collision:isBlockedLocal(localX, localZ)
  end
  Assert.isFalse(blocked(13, 75), "a platform floor overrides a blocked generated tile")
  Assert.isFalse(blocked(13, 79), "the whole 3x6 floor is walkable")
  Assert.isTrue(blocked(30, 60), "the lava outside every platform floor is blocked")
  Assert.isTrue(blocked(9, 56), "the lava beyond the second platform's turned floor is blocked")
  Assert.isFalse(blocked(9, 58), "the second platform's turned floor is walkable")

  local cell = map.collision:getLocal(13 - map.coordinateOrigin.x, 75 - map.coordinateOrigin.z)
  Assert.isFalse(cell.blocked == true, "the cell record carries the projected verdict")
  Assert.equal(cell.behavior, 44, "the projected cell keeps the generated behavior byte")
  local lava = map.collision:getLocal(30 - map.coordinateOrigin.x, 60 - map.coordinateOrigin.z)
  Assert.isTrue(lava.blocked == true)

  -- The decoded permission grid is read, never rewritten.
  local lavaLocalX, lavaLocalZ = 30 - map.coordinateOrigin.x, 60 - map.coordinateOrigin.z
  Assert.deepEqual(generated:getLocal(lavaLocalX, lavaLocalZ), {
    behavior = 44,
    terrainResponseId = 0,
    blocked = false,
  }, "the generated cell keeps its own verdict")
  Assert.isTrue(
    generated:isBlockedLocal(13 - map.coordinateOrigin.x, 75 - map.coordinateOrigin.z),
    "the decoded floor stays blocked"
  )
end

-- A tile that is neither platform floor nor magma keeps whatever the generated
-- permission says, in both directions.
function T.the_blackthorn_projection_defers_to_the_generated_permission()
  local openMap = blackthornMap({ behavior = { ["30:60"] = 0 } })
  local openGeometry = GymMechanismGeometry.new()
  openGeometry:setBlackthornPlatforms(BLACKTHORN_BUCKETS)
  openGeometry:bindMap(openMap)
  local openX, openZ = 30 - openMap.coordinateOrigin.x, 60 - openMap.coordinateOrigin.z
  Assert.isFalse(openMap.collision:isBlockedLocal(openX, openZ), "a non-magma room tile keeps its walkable permission")

  local wallMap = blackthornMap({ behavior = { ["30:60"] = 0 }, blocked = { ["30:60"] = true } })
  local wallGeometry = GymMechanismGeometry.new()
  wallGeometry:setBlackthornPlatforms(BLACKTHORN_BUCKETS)
  wallGeometry:bindMap(wallMap)
  local wallX, wallZ = 30 - wallMap.coordinateOrigin.x, 60 - wallMap.coordinateOrigin.z
  Assert.isTrue(wallMap.collision:isBlockedLocal(wallX, wallZ), "a non-magma blocked tile keeps its permission")
end

-- The source tile facts the platform algorithms read come from the generated map,
-- never from the mechanism's own projection.
function T.the_source_tile_facts_read_the_generated_map()
  local map = blackthornMap({ behavior = { ["20:70"] = 0 }, blocked = { ["21:70"] = true } })
  local geometry = GymMechanismGeometry.new()
  geometry:setBlackthornPlatforms(BLACKTHORN_BUCKETS)
  geometry:bindMap(map)
  local blocked, magma = geometry:mapTile(20, 70)
  Assert.isFalse(blocked)
  Assert.isFalse(magma, "the source algorithm reads the generated behavior")
  blocked, magma = geometry:mapTile(21, 70)
  Assert.isTrue(blocked, "the generated permission is what the wall check reads")
  Assert.isTrue(magma)
  blocked, magma = geometry:mapTile(500, 500)
  Assert.isFalse(blocked, "a tile outside the map answers the source's 0xFF attribute")
  Assert.isFalse(magma, "an out-of-map tile is never magma")
end

-- Once the union owns no platform, the generated permission answers again, and a
-- rebind or an unbind never leaves the projection behind.
function T.dropping_the_platforms_gives_the_generated_permission_back()
  local map = blackthornMap()
  local base = map.terrain
  local geometry = GymMechanismGeometry.new()
  geometry:setBlackthornPlatforms(BLACKTHORN_BUCKETS)
  geometry:bindMap(map)
  Assert.isTrue(map.collision ~= nil)
  local projected = map.collision
  geometry:setBlackthornPlatforms(nil)
  Assert.isTrue(map.collision ~= projected, "clearing the union removes the projection")
  local localX, localZ = 30 - map.coordinateOrigin.x, 60 - map.coordinateOrigin.z
  Assert.isFalse(map.collision:isBlockedLocal(localX, localZ), "the generated lava is walkable again")

  geometry:setBlackthornPlatforms(BLACKTHORN_BUCKETS)
  geometry:bindMap(map)
  Assert.equal(map.terrain, base, "binding keeps the generated terrain when no plate applies")
  geometry:unbind()
  Assert.isFalse(map.collision:isBlockedLocal(localX, localZ), "an unbound mechanism projects nothing")
end

-- A physical coverage commit re-publishes the map's composed owners through the
-- runtime hook; the settled projection follows the new frame.
function T.a_physical_commit_reinstalls_the_projection()
  local map = blackthornMap()
  local geometry = GymMechanismGeometry.new()
  geometry:setBlackthornPlatforms(BLACKTHORN_BUCKETS)
  geometry:bindMap(map)
  -- The runtime re-publishes generated owners in a new frame and then calls the
  -- hook the projection installed for exactly this.
  local replacement = blackthornMap({ originX = 0, originZ = 40 })
  map.collision = replacement.collision
  map.coordinateOrigin = replacement.coordinateOrigin
  map:reprojectFieldGeometry()
  Assert.isTrue(map.collision ~= replacement.collision, "the projection is installed over the new owner")
  local localX, localZ = 13 - map.coordinateOrigin.x, 75 - map.coordinateOrigin.z
  Assert.isFalse(map.collision:isBlockedLocal(localX, localZ), "the platform floor answers again")
  local lavaX, lavaZ = 30 - map.coordinateOrigin.x, 60 - map.coordinateOrigin.z
  Assert.isTrue(map.collision:isBlockedLocal(lavaX, lavaZ), "the lava answers again through the new owner")
end

-- One field tile's centre in world space is the placement origin of every source
-- prop a mechanism loads.
function T.a_field_tile_centre_is_the_source_prop_placement()
  local map = runtimeMap(40, 60)
  local geometry = GymMechanismGeometry.new()
  geometry:bindMap(map)
  local point = assert(geometry:tileCentre(15, 20))
  local expectedX, expectedZ = FieldGrid.tileCenterToWorld(15 - 40, 20 - 60)
  Assert.equal(point.x, expectedX)
  Assert.equal(point.z, expectedZ)
  geometry:unbind()
  Assert.isNil(geometry:tileCentre(15, 20), "an unbound mechanism places no prop")
end

return { tests = T }
