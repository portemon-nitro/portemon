-- The Violet Gym elevator (src/field/gymmick/violet.c). The source carries the
-- avatar and the visible follower up or down on the car itself: it toggles the
-- avatar's automatic height updating off, plays the motor loop, moves the car
-- and both riders one tile per tick between FX32_CONST(32) and FX32_CONST(496)
-- (29 source tiles of 16 units), stops the loop and plays the arrival chime,
-- then settles the dynamic height plate on the floor it reached.
--
-- The leaf owns exactly one ride: the transport lease on the player, the
-- follower's carried height, the source sounds, and the plate's settled
-- height. Direction is the source's own test - the avatar standing on the
-- lower floor rides up, otherwise it rides down - and the persisted union is
-- committed only at a stop, so a cancelled ride never leaves a settled floor
-- behind. Nothing here walks the avatar: the car carries it, so no committed
-- step, terrain response, or encounter is published.

-- The collaborators one ride reads: the transport player that carries it,
-- the actor and follower owners it carries along, the runtime plate it settles,
-- and the saved union it commits.
---@class VioletGymOptions
---@field player table<string, unknown>
---@field actors table<string, unknown>
---@field followingMon table<string, unknown>
---@field geometry table<string, unknown>
---@field audio table<string, unknown>
---@field state table<string, unknown>

---@class VioletGym
---@field private _player table<string, unknown>
---@field private _actors table<string, unknown>
---@field private _followingMon table<string, unknown>
---@field private _geometry table<string, unknown>
---@field private _audio table<string, unknown>
---@field private _state table<string, unknown>
local VioletGym = {}
VioletGym.__index = VioletGym

-- The pinned source sound identities (include/constants/sndseq.h).
VioletGym.MOTOR_SEQUENCE = "SEQ_SE_DP_ELEBETA"
VioletGym.ARRIVAL_SEQUENCE = "SEQ_SE_DP_KI_GASYAN"

VioletGym.DIRECTIONS = { up = 1, down = -1 }
VioletGym.MOTION_TICKS = 29

local PHASES = { moving = true, stopped = true, cancelled = true }

---@param options VioletGymOptions
---@return VioletGym
function VioletGym.new(options)
  assert(type(options) == "table", "the violet ride needs its collaborators")
  assert(options.player and options.player.beginTransport, "the violet ride carries a transport player")
  assert(options.actors and options.actors.partnerId, "the violet ride needs the actor owner")
  assert(options.followingMon and options.followingMon.moveToPlayer, "the violet ride needs the follower owner")
  assert(options.geometry and options.geometry.setVioletRaised, "the violet ride needs its dynamic plate")
  assert(options.audio and options.audio.play and options.audio.stop, "the violet ride needs the source audio host")
  assert(options.state and options.state.violetRaised, "the violet ride reads its own settled union")
  return setmetatable({
    _player = options.player,
    _actors = options.actors,
    _followingMon = options.followingMon,
    _geometry = options.geometry,
    _audio = options.audio,
    _state = options.state,
    _phase = nil,
  }, VioletGym)
end

-- The source's own direction test: a rider standing on the lower stop rides
-- up; anyone else rides down.
---@return string
function VioletGym:direction()
  return self._geometry:isVioletRaised() and "down" or "up"
end

-- Start the ride: claim the player transport, start the source motor loop and
-- fix the settled floor this ride will reach.
function VioletGym:start()
  assert(self._phase == nil, "the violet ride already started")
  local direction = self:direction()
  local player = self._player
  local origin = {
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    localX = player.localX,
    localZ = player.localZ,
    worldX = player.worldX,
    worldY = player.worldY,
    worldZ = player.worldZ,
    surfaceId = player.surfaceId,
    raised = self._geometry:isVioletRaised(),
  }
  player:beginTransport()
  self._origin = origin
  self._direction = direction
  self._remaining = VioletGym.MOTION_TICKS
  self._carried = 0
  self._partnerId = self._actors:partnerId()
  self._motor = true
  self._phase = "moving"
  self._audio:play(VioletGym.MOTOR_SEQUENCE)
end

---@return table<string, unknown> detached view of the ride
function VioletGym:view()
  return {
    direction = self._direction,
    phase = self._phase,
    remainingTicks = self._remaining or 0,
    carriedTiles = self._carried or 0,
  }
end

local function carryFollower(self, delta)
  local partnerId = self._partnerId
  if partnerId == nil or self._actors:getById(partnerId) == nil then
    return
  end
  self._carried = self._carried + delta
  self._actors:setPresentationOffset(partnerId, { x = 0, y = self._carried, z = 0 })
end

-- Release the carried presentation exactly once, whatever stopped the ride.
local function releaseFollowerCarry(self)
  if self._carryReleased then
    return
  end
  self._carryReleased = true
  local partnerId = self._partnerId
  if partnerId == nil or self._actors:getById(partnerId) == nil then
    return
  end
  self._actors:clearPresentationOffset(partnerId)
end

-- The arrival stop: stop the motor, settle the plate on the floor the car
-- reached, commit the rider's tile once, and put the visible follower beside
-- it on the same plate.
local function stop(self)
  local target = self._origin.worldY + VioletGym.DIRECTIONS[self._direction] * VioletGym.MOTION_TICKS
  if self._motor then
    self._motor = false
    self._audio:stop(VioletGym.MOTOR_SEQUENCE)
  end
  self._geometry:setVioletRaised(self._direction == "up")
  self._state:setVioletRaised(self._direction == "up")
  releaseFollowerCarry(self)
  self._player:commitTransport(self._origin.fieldX, self._origin.fieldZ, target)
  -- The source carries the follow mon at the rider's height; the port lands it
  -- on the same plate through the follower's own placement operation.
  self._followingMon:moveToPlayer()
  self._audio:play(VioletGym.ARRIVAL_SEQUENCE)
  self._phase = "stopped"
end

-- One fixed tick of the ride: one car tile, both riders carried with it, then
-- the arrival stop on the last tick.
---@return string phase
function VioletGym:updateFixed()
  assert(PHASES[self._phase] == true, "the violet ride is not running")
  if self._phase ~= "moving" then
    return self._phase
  end
  local delta = VioletGym.DIRECTIONS[self._direction]
  local player = self._player
  player:applyTransportPose(player.worldX, player.worldY + delta, player.worldZ)
  carryFollower(self, delta)
  self._remaining = self._remaining - 1
  if self._remaining == 0 then
    stop(self)
  end
  return self._phase
end

-- Cancel a ride: stop the source loop, restore the settled floor the ride
-- started from and put the rider back on the anchor it boarded from. The
-- source has no cancellation path, so the mechanism reverts to the last
-- settled stop instead of inventing a floor between the two.
---@param reason string?
function VioletGym:cancel(reason)
  if self._phase == nil or self._phase ~= "moving" then
    return
  end
  self._reason = reason
  if self._motor then
    self._motor = false
    self._audio:stop(VioletGym.MOTOR_SEQUENCE)
  end
  releaseFollowerCarry(self)
  self._geometry:setVioletRaised(self._origin.raised)
  self._state:setVioletRaised(self._origin.raised)
  self._player:cancelTransport()
  self._phase = "cancelled"
end

-- Release everything the ride owns exactly once. A stopped ride keeps its
-- committed floor; a live one is cancelled first.
function VioletGym:dispose()
  if self._phase == "moving" then
    self:cancel("the violet ride was disposed")
  end
  releaseFollowerCarry(self)
end

---@return boolean
function VioletGym:isComplete()
  return self._phase == "stopped" or self._phase == "cancelled"
end

return VioletGym
