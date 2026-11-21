-- The player's native transport lease: a carried rider publishes world poses
-- without a committed step, commits one arrival tile on the active surface, and
-- restores its anchor on cancellation; ordinary movement stays out of a lease.

local Assert = require("tests.support.Assert")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local function plate(id, distance)
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

local function runtimeMap()
  return {
    mapId = 60,
    mapSymbol = "test-map",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= -64 and x < 64 and z >= -64 and z < 64
      end,
      isBlockedLocal = function()
        return false
      end,
      getLocal = function()
        return { blocked = false }
      end,
    },
    terrain = TerrainSurface.new({ plates = { plate(0, 0) } }),
    terrainDependencyHash = "test-terrain",
    mapProps = {},
    release = function() end,
    updateAnimated = function() end,
  }
end

local function player()
  return FieldPlayer.new({ currentMap = runtimeMap(), fieldX = 4, fieldZ = 4, surfaceId = 0, facing = "north" })
end

-- A carried pose never publishes a step: the logical tile, the movement
-- revision and the committed terrain steps stay exactly as they were.
function T.a_carried_pose_publishes_no_step()
  local p = player()
  local revision = p:movementRevision()
  local lease = p:beginTransport()
  Assert.equal(lease.fieldX, 4, "the lease captures the anchor it will restore")
  Assert.isTrue(p:isTransporting())
  for _ = 1, 5 do
    p:applyTransportPose(p.worldX, p.worldY + 1, p.worldZ)
  end
  Assert.equal(p.worldY, 5, "the pose accumulates the source motion")
  Assert.equal(p.fieldZ, 4, "the carried rider keeps its standing tile")
  Assert.equal(p:movementRevision(), revision, "a carried rider publishes no movement revision")
  Assert.isNil(p:takeCommittedTerrainSteps(), "a carried rider owes no terrain response")
end

-- The arrival stop writes the settled tile once, on the surface the map (or
-- the mechanism's dynamic plate) answers there.
function T.the_arrival_stop_commits_one_tile_without_a_step()
  local map = runtimeMap()
  local p = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 4, surfaceId = 0, facing = "north" })
  local revision = p:movementRevision()
  p:beginTransport()
  p:applyTransportPose(p.worldX, 7, p.worldZ)
  p:commitTransport(4, 6, 7)
  Assert.equal(p.fieldX, 4)
  Assert.equal(p.fieldZ, 6)
  Assert.equal(p.worldY, 0, "the destination surface decides the arrival height")
  Assert.equal(p.surfaceId, 0)
  Assert.isFalse(p:isTransporting(), "the arrival ends the lease")
  Assert.equal(p:movementRevision(), revision, "a carried arrival is not a walked step")
  Assert.isNil(p:takeCommittedTerrainSteps())
end

-- Cancellation restores the captured anchor exactly, and cancelling an ended
-- lease is a clean no-op.
function T.cancellation_restores_the_captured_anchor()
  local p = player()
  local anchor = { fieldX = p.fieldX, fieldZ = p.fieldZ, worldX = p.worldX, worldY = p.worldY, worldZ = p.worldZ }
  p:beginTransport()
  p:applyTransportPose(p.worldX + 2, p.worldY + 3, p.worldZ + 1)
  p:cancelTransport()
  Assert.equal(p.fieldX, anchor.fieldX)
  Assert.equal(p.fieldZ, anchor.fieldZ)
  Assert.equal(p.worldX, anchor.worldX)
  Assert.equal(p.worldY, anchor.worldY)
  Assert.equal(p.worldZ, anchor.worldZ)
  Assert.equal(p.motion, "idle", "a cancelled ride leaves an idle rider")
  p:cancelTransport()
  Assert.equal(p.worldY, anchor.worldY, "a repeated cancellation restores nothing twice")
end

-- Ordinary movement, turning and buffered input stay out of an active lease.
function T.ordinary_movement_does_not_run_inside_a_lease()
  local p = player()
  p:beginTransport()
  Assert.isFalse(p:updateFixed({ pressedDirection = "north" }), "a carried rider takes no own step")
  Assert.equal(p.fieldZ, 4)
  Assert.equal(p.motion, "idle")
end

-- One lease at a time, and only an idle rider may start one.
function T.a_lease_requires_an_idle_rider_and_is_not_nested()
  local p = player()
  p:beginTransport()
  -- Both of these are programming invariants of the one owner, so they assert
  -- rather than raise a recoverable field error.
  Assert.throws(function()
    p:beginTransport()
  end, "a nested lease is a programming fault")
  p:cancelTransport()

  local moving = player()
  moving.motion = "walking"
  Assert.throws(function()
    moving:beginTransport()
  end, "a moving rider cannot start a transport")
  Assert.isFalse(moving:isTransporting())
end

return { tests = T }
