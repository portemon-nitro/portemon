-- The Violet Gym lift over the field's own owners: the source height timeline,
-- the settled dynamic plate, the carried follower, the source sound order, and
-- the cancellation that restores the anchor instead of leaving a half ride.

local Assert = require("tests.support.Assert")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")
local VioletGym = require("libs.hgss.src.field.gymmick.VioletGym")

local T = {}

local GROUND = 2

local function newHost(raised)
  local host = { effects = {}, commits = {}, offsets = {}, cleared = 0 }
  local player = {
    fieldX = 15,
    fieldZ = 20,
    worldX = 15.5,
    worldY = GROUND,
    worldZ = 20.5,
    surfaceId = 0,
    motion = "idle",
    _lease = false,
  }
  function player:beginTransport()
    Assert.isFalse(self._lease, "one transport lease at a time")
    self._lease = true
    host.anchor = { fieldX = self.fieldX, fieldZ = self.fieldZ, worldY = self.worldY }
  end
  function player:applyTransportPose(worldX, worldY, worldZ)
    Assert.isTrue(self._lease, "a pose needs the lease")
    self.worldX, self.worldY, self.worldZ = worldX, worldY, worldZ
  end
  function player:commitTransport(fieldX, fieldZ, worldY)
    Assert.isTrue(self._lease, "a commit needs the lease")
    self._lease = false
    self.fieldX, self.fieldZ = fieldX, fieldZ
    self.worldY = worldY
    host.commits[#host.commits + 1] = { fieldX = fieldX, fieldZ = fieldZ, worldY = worldY }
  end
  function player:cancelTransport()
    if not self._lease then
      return
    end
    self._lease = false
    self.fieldX, self.fieldZ, self.worldY = host.anchor.fieldX, host.anchor.fieldZ, host.anchor.worldY
    host.cancelled = true
  end
  host.player = player
  host.actors = {
    partnerId = function()
      return "field:partner"
    end,
    getById = function()
      return { actorId = "field:partner" }
    end,
    setPresentationOffset = function(_, actorId, offset)
      host.offsets[#host.offsets + 1] = { actorId = actorId, offset = offset }
    end,
    clearPresentationOffset = function()
      host.cleared = host.cleared + 1
    end,
  }
  host.followingMon = {
    moveToPlayer = function()
      host.followerPlaced = true
    end,
  }
  host.geometry = {
    _raised = raised,
    isVioletRaised = function(self)
      return self._raised
    end,
    setVioletRaised = function(self, value)
      Assert.equal(type(value), "boolean", "the plate takes its settled floor")
      self._raised = value
    end,
  }
  host.audio = {
    play = function(_, sound)
      host.effects[#host.effects + 1] = "play:" .. sound
    end,
    stop = function(_, sound)
      host.effects[#host.effects + 1] = "stop:" .. sound
    end,
  }
  host.state = GymMechanismState.restore({
    schema = GymMechanismState.SCHEMA,
    kind = "violet",
    data = { raised = raised },
  })
  return host
end

local function newRide(host)
  return VioletGym.new({
    player = host.player,
    actors = host.actors,
    followingMon = host.followingMon,
    geometry = host.geometry,
    audio = host.audio,
    state = host.state,
  })
end

local function drive(ride)
  local heights = {}
  local previous = ride._player.worldY
  while not ride:isComplete() do
    ride:updateFixed()
    heights[#heights + 1] = ride._player.worldY - previous
    previous = ride._player.worldY
  end
  return heights
end

-- The ascent: exactly one source tile per motion tick for the source's 29
-- ticks, the motor loop started then stopped before the arrival chime, the
-- plate settled on the upper floor and the persisted union committed there.
function T.the_lift_rises_one_source_tile_per_tick_and_settles_on_the_upper_floor()
  local host = newHost(false)
  local ride = newRide(host)
  ride:start()
  local steps = drive(ride)
  Assert.equal(#steps, VioletGym.MOTION_TICKS, "the car stops after the source 29 motion ticks")
  for index, step in ipairs(steps) do
    Assert.equal(step, 1, "car motion tick " .. index .. " rises one source tile")
  end
  Assert.equal(host.player.worldY, GROUND + VioletGym.MOTION_TICKS, "the car settles on the upper floor")
  Assert.deepEqual(host.commits, {
    { fieldX = 15, fieldZ = 20, worldY = GROUND + VioletGym.MOTION_TICKS },
  }, "the arrival commits the pad tile once at the settled height")
  Assert.isTrue(host.geometry:isVioletRaised(), "the dynamic plate follows the car up")
  Assert.isTrue(host.state:violetRaised(), "the settled union records the upper floor")
  Assert.isTrue(host.followerPlaced, "the visible follower is carried to the rider")
  Assert.equal(host.cleared, 1, "the carried presentation is released exactly once")
  Assert.deepEqual(host.effects, {
    "play:" .. VioletGym.MOTOR_SEQUENCE,
    "stop:" .. VioletGym.MOTOR_SEQUENCE,
    "play:" .. VioletGym.ARRIVAL_SEQUENCE,
  }, "the source runs the motor loop, stops it, then chimes")
end

-- The descent from the upper floor is the same timeline downwards and settles
-- the union on the lower floor.
function T.the_lift_descends_back_to_the_ground_floor()
  local host = newHost(true)
  host.player.worldY = GROUND + VioletGym.MOTION_TICKS
  local ride = newRide(host)
  ride:start()
  local steps = drive(ride)
  Assert.equal(#steps, VioletGym.MOTION_TICKS)
  for index, step in ipairs(steps) do
    Assert.equal(step, -1, "car motion tick " .. index .. " drops one source tile")
  end
  Assert.equal(host.player.worldY, GROUND, "the car returns to the ground floor")
  Assert.isFalse(host.geometry:isVioletRaised())
  Assert.isFalse(host.state:violetRaised(), "the settled union records the lower floor")
end

-- A cancelled ride stops its motor, restores the rider anchor and keeps the
-- floor the car settled on before the ride; the live presentation offset never
-- survives it.
function T.a_cancelled_ride_restores_the_anchor_and_its_settled_floor()
  local host = newHost(false)
  local ride = newRide(host)
  ride:start()
  for _ = 1, 12 do
    ride:updateFixed()
  end
  Assert.isTrue(#host.offsets > 0, "the follower was carried while the ride ran")
  ride:cancel("cancelled")
  Assert.isTrue(host.cancelled, "the rider returns to the anchor it boarded from")
  Assert.equal(host.player.worldY, GROUND, "the cancelled ride settles back on its origin floor")
  Assert.isFalse(host.geometry:isVioletRaised(), "a cancelled ascent never leaves the car up")
  Assert.isFalse(host.state:violetRaised(), "and commits nothing to the union")
  Assert.equal(host.effects[#host.effects], "stop:" .. VioletGym.MOTOR_SEQUENCE, "the motor is released")
  Assert.equal(host.cleared, 1, "the follower carry is released once")
  Assert.equal(#host.commits, 0, "a cancelled ride commits no arrival tile")
  ride:dispose()
  ride:dispose()
  Assert.equal(host.cleared, 1, "dispose is idempotent")
end

-- Disposing a live ride cancels it; disposing a settled ride keeps its
-- committed floor.
function T.dispose_cancels_a_live_ride_and_keeps_a_settled_one()
  local live = newHost(false)
  local liveRide = newRide(live)
  liveRide:start()
  liveRide:updateFixed()
  liveRide:dispose()
  Assert.isTrue(live.cancelled, "a disposed live ride restores its anchor")
  Assert.isFalse(live.state:violetRaised())

  local settled = newHost(false)
  local settledRide = newRide(settled)
  settledRide:start()
  drive(settledRide)
  settledRide:dispose()
  Assert.isTrue(settled.state:violetRaised(), "a disposed settled ride keeps the floor it reached")
end

return { tests = T }
