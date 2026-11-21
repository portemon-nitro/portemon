-- The Azalea Gym Spinarak transports (src/field/gymmick/azalea.c). Four
-- Spinarak props stand on the source's twelve route nodes; a ride script names
-- the endpoint the spider currently stands on, resolves the spider standing
-- there, and carries the avatar and the visible follower along the source
-- route for the current switch mask. Routes are the source tables, never a
-- shortest path, and a segment vector is normalized and multiplied by two
-- source units per tick (2/16 of a tile) exactly like the source SysTask.
--
-- The node a roller is parked on is committed only when the route's last node
-- is reached, so a cancelled ride leaves the source endpoints untouched. The
-- reversed selectors (3, 4, 5, 9, 10, 11) walk their route table backwards and
-- board one tile south of their arrival tile, which is the source's
-- playerZOffset.

local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")

---@class AzaleaGym
---@field _player table<string, unknown> the transport player that carries both riders
---@field _actors table<string, unknown>
---@field _followingMon table<string, unknown>
---@field _audio table<string, unknown>
---@field _state table<string, unknown> the saved union this ride reads and commits
---@field _camera table<string, unknown>?
---@field _model table<string, unknown>? the presented spider's own model handle
---@field _phase string?
---@field _reason string?
---@field _selector integer the record set one started ride carries
---@field _spiderSlot integer
---@field _switchMask integer
---@field _nodes integer[][]
---@field _destination integer
---@field _reversed boolean
---@field _nodeIndex integer
---@field _playerZOffset integer
---@field _arrivalNode integer[]
---@field _partnerId unknown the visible follower's actor identity, while it rides along
---@field _segmentDone boolean?
---@field _segmentX number
---@field _segmentZ number
---@field _segmentTarget integer[]
---@field _segmentTicks integer
---@field _spiderX number
---@field _spiderZ number
---@field _spiderWorldX number?
---@field _spiderWorldY number?
---@field _spiderWorldZ number?
---@field _stepDirection string
---@field _stepTicks integer
---@field _stepDuration integer
---@field _shakeCount integer?
---@field _shakeFrame integer?
---@field _waitTicks integer?
local AzaleaGym = {}
AzaleaGym.__index = AzaleaGym

-- The pinned source sound identities (src/field/gymmick/azalea.c).
AzaleaGym.RIDE_SEQUENCE = "SEQ_SE_GS_ITOMARU_ROBO"
AzaleaGym.SWITCH_SEQUENCE = "SEQ_SE_DP_KI_GASYAN"

-- Source units: one tile is sixteen units, and one motion tick advances the
-- normalized segment vector by two.
AzaleaGym.UNITS_PER_TILE = 16
AzaleaGym.UNITS_PER_TICK = 2

-- The source prop's own offset from its route node: the ride adds only the
-- model-space x offset (spinarakPos.x += FX32_CONST(8)) and keeps z on the
-- node, so the prop stands at the node tile's centre in x and half a tile
-- north of that centre in z.
AzaleaGym.SPIDER_OFFSET_Z = 0.5

-- The source camera shake runs four alternating offsets two frames apart, then
-- a terminal wait of eight frames before the rider steps off.
AzaleaGym.SHAKE_COUNT = 4
AzaleaGym.SHAKE_INTERVAL_TICKS = 2
AzaleaGym.STEP_OFF_DELAY_TICKS = 8

-- The selectors whose route table is walked backwards, which also board and
-- leave one tile south of the spider (src/field/gymmick/azalea.c,
-- BeginAzaleaGymSpinarakRide).
local REVERSED_SELECTORS = { [3] = true, [4] = true, [5] = true, [9] = true, [10] = true, [11] = true }

-- The source node table (AzaleaGymmickSpinarakRouteNode). Field coordinates
-- are the source map's own tile coordinates.
local NODES = {
  [0] = { x = 3, z = 31 },
  [1] = { x = 9, z = 31 },
  [2] = { x = 15, z = 31 },
  [3] = { x = 3, z = 24 },
  [4] = { x = 9, z = 24 },
  [5] = { x = 15, z = 24 },
  [6] = { x = 3, z = 16 },
  [7] = { x = 9, z = 16 },
  [8] = { x = 15, z = 16 },
  [9] = { x = 3, z = 9 },
  [10] = { x = 9, z = 9 },
  [11] = { x = 15, z = 9 },
}

-- The route tables, keyed by the start node and then by the switch mask. The
-- destination is the node the spider ends parked on.
local function route(nodes, destination)
  return { nodes = nodes, destination = destination }
end

local ROUTES = {
  [0] = {
    route({ { 3, 31 }, { 3, 29 }, { 9, 29 }, { 9, 27 }, { 15, 28 }, { 15, 25 }, { 9, 25 }, { 9, 24 } }, 4),
    route({ { 3, 31 }, { 3, 29 }, { 9, 29 }, { 9, 27 }, { 15, 28 }, { 15, 25 }, { 9, 25 }, { 9, 24 } }, 4),
    route({ { 3, 31 }, { 3, 29 }, { 9, 29 }, { 9, 27 }, { 15, 28 }, { 15, 25 }, { 9, 25 }, { 9, 24 } }, 4),
    route({ { 3, 31 }, { 3, 29 }, { 9, 29 }, { 9, 27 }, { 15, 28 }, { 15, 25 }, { 9, 25 }, { 9, 24 } }, 4),
  },
  [1] = {
    route({ { 9, 31 }, { 9, 29 }, { 3, 29 }, { 3, 27 }, { 9, 26 }, { 9, 25 }, { 15, 25 }, { 15, 24 } }, 5),
    route({ { 9, 31 }, { 9, 29 }, { 3, 29 }, { 3, 27 }, { 9, 26 }, { 9, 25 }, { 15, 25 }, { 15, 24 } }, 5),
    route({ { 9, 31 }, { 9, 29 }, { 3, 29 }, { 3, 27 }, { 9, 26 }, { 9, 25 }, { 15, 25 }, { 15, 24 } }, 5),
    route({ { 9, 31 }, { 9, 29 }, { 3, 29 }, { 3, 27 }, { 9, 26 }, { 9, 25 }, { 15, 25 }, { 15, 24 } }, 5),
  },
  [2] = {
    route({ { 15, 31 }, { 15, 28 }, { 9, 27 }, { 9, 26 }, { 3, 27 }, { 3, 24 } }, 3),
    route({ { 15, 31 }, { 15, 28 }, { 9, 27 }, { 9, 26 }, { 3, 27 }, { 3, 24 } }, 3),
    route({ { 15, 31 }, { 15, 28 }, { 9, 27 }, { 9, 26 }, { 3, 27 }, { 3, 24 } }, 3),
    route({ { 15, 31 }, { 15, 28 }, { 9, 27 }, { 9, 26 }, { 3, 27 }, { 3, 24 } }, 3),
  },
  [3] = {
    route({ { 15, 31 }, { 15, 28 }, { 9, 27 }, { 9, 26 }, { 3, 27 }, { 3, 24 } }, 2),
    route({ { 15, 31 }, { 15, 28 }, { 9, 27 }, { 9, 26 }, { 3, 27 }, { 3, 24 } }, 2),
    route({ { 15, 31 }, { 15, 28 }, { 9, 27 }, { 9, 26 }, { 3, 27 }, { 3, 24 } }, 2),
    route({ { 15, 31 }, { 15, 28 }, { 9, 27 }, { 9, 26 }, { 3, 27 }, { 3, 24 } }, 2),
  },
  [4] = {
    route({ { 3, 31 }, { 3, 29 }, { 9, 29 }, { 9, 27 }, { 15, 28 }, { 15, 25 }, { 9, 25 }, { 9, 24 } }, 0),
    route({ { 3, 31 }, { 3, 29 }, { 9, 29 }, { 9, 27 }, { 15, 28 }, { 15, 25 }, { 9, 25 }, { 9, 24 } }, 0),
    route({ { 3, 31 }, { 3, 29 }, { 9, 29 }, { 9, 27 }, { 15, 28 }, { 15, 25 }, { 9, 25 }, { 9, 24 } }, 0),
    route({ { 3, 31 }, { 3, 29 }, { 9, 29 }, { 9, 27 }, { 15, 28 }, { 15, 25 }, { 9, 25 }, { 9, 24 } }, 0),
  },
  [5] = {
    route({ { 9, 31 }, { 9, 29 }, { 3, 29 }, { 3, 27 }, { 9, 26 }, { 9, 25 }, { 15, 25 }, { 15, 24 } }, 1),
    route({ { 9, 31 }, { 9, 29 }, { 3, 29 }, { 3, 27 }, { 9, 26 }, { 9, 25 }, { 15, 25 }, { 15, 24 } }, 1),
    route({ { 9, 31 }, { 9, 29 }, { 3, 29 }, { 3, 27 }, { 9, 26 }, { 9, 25 }, { 15, 25 }, { 15, 24 } }, 1),
    route({ { 9, 31 }, { 9, 29 }, { 3, 29 }, { 3, 27 }, { 9, 26 }, { 9, 25 }, { 15, 25 }, { 15, 24 } }, 1),
  },
  [6] = {
    nil,
    route({ { 3, 16 }, { 3, 12 }, { 9, 13 }, { 9, 10 }, { 3, 10 }, { 3, 9 } }, 9),
    nil,
    route({ { 3, 16 }, { 3, 12 }, { 9, 13 }, { 9, 9 } }, 10),
  },
  [7] = {
    route({ { 9, 16 }, { 9, 14 }, { 15, 14 }, { 15, 11 }, { 9, 12 }, { 9, 10 }, { 3, 10 }, { 3, 9 } }, 9),
    route({ { 9, 16 }, { 9, 14 }, { 15, 14 }, { 15, 9 } }, 11),
    route({ { 9, 16 }, { 9, 14 }, { 15, 14 }, { 15, 11 }, { 9, 12 }, { 9, 9 } }, 10),
    route({ { 9, 16 }, { 9, 14 }, { 15, 14 }, { 15, 9 } }, 11),
  },
  [8] = { nil, nil, nil, nil },
  [9] = {
    route({ { 9, 16 }, { 9, 14 }, { 15, 14 }, { 15, 11 }, { 9, 12 }, { 9, 10 }, { 3, 10 }, { 3, 9 } }, 7),
    route({ { 3, 16 }, { 3, 12 }, { 9, 13 }, { 9, 10 }, { 3, 10 }, { 3, 9 } }, 6),
    nil,
    nil,
  },
  [10] = {
    nil,
    nil,
    route({ { 9, 16 }, { 9, 14 }, { 15, 14 }, { 15, 11 }, { 9, 12 }, { 9, 9 } }, 7),
    route({ { 3, 16 }, { 3, 12 }, { 9, 13 }, { 9, 9 } }, 6),
  },
  [11] = {
    nil,
    route({ { 9, 16 }, { 9, 14 }, { 15, 14 }, { 15, 9 } }, 7),
    nil,
    route({ { 9, 16 }, { 9, 14 }, { 15, 14 }, { 15, 9 } }, 7),
  },
}

-- The source's "route node progress" test
-- (src/field/gymmick/azalea.c::AzaleaGymmick_GetMovementDoneParams): the next
-- position either lands exactly on the node component, steps past it in its
-- own direction, or has not arrived yet. A passed component stops for the rest
-- of the segment, and the segment ends when neither component can still move,
-- which is how a diagonal segment lands on the axis that arrives last.
---@param positive boolean
---@param current number
---@param delta number
---@param target number
---@return string progress
local function componentProgress(positive, current, delta, target)
  local next_ = current + delta
  if next_ == target then
    return "reached"
  end
  if (positive and next_ > target) or (not positive and next_ < target) then
    return "passed"
  end
  return "not_reached"
end

local PHASES = {
  boarding = true,
  starting = true,
  moving = true,
  arriving = true,
  shaking = true,
  steppingOff = true,
  arrived = true,
  cancelled = true,
}

---@param options table<string, unknown>
---@return AzaleaGym
function AzaleaGym.new(options)
  assert(type(options) == "table", "the spider ride needs its collaborators")
  assert(options.player and options.player.beginTransport, "the spider ride carries a transport player")
  assert(options.actors and options.actors.partnerId, "the spider ride needs the actor owner")
  assert(
    options.followingMon and options.followingMon.repositionRelativeToPlayer,
    "the spider ride needs the follower owner"
  )
  assert(options.audio and options.audio.play and options.audio.stop, "the spider ride needs the source audio host")
  assert(options.state and options.state.spiderAtEndpoint, "the spider ride reads its own settled union")
  if options.model ~= nil then
    assert(
      type(options.model.startRideAnimation) == "function" and type(options.model.stopRideAnimation) == "function",
      "a presented spider carries its model handle"
    )
  end
  return setmetatable({
    _player = options.player,
    _actors = options.actors,
    _followingMon = options.followingMon,
    _audio = options.audio,
    _state = options.state,
    _camera = options.camera,
    _model = options.model,
    _phase = nil,
  }, AzaleaGym)
end

-- The source route for one selector under one switch mask, or nil when the
-- table carries no route (the ride script still runs; nothing moves).
---@param selector integer
---@param switchMask integer
---@return table<string, unknown>|nil
function AzaleaGym.routeFor(selector, switchMask)
  local byMask = ROUTES[selector]
  if byMask == nil then
    return nil
  end
  return byMask[switchMask + 1]
end

-- The source route node tile one endpoint names.
---@param endpoint integer
---@return { x: number, z: number }
function AzaleaGym.nodePosition(endpoint)
  local node = assert(NODES[endpoint], "the spider endpoint names no source route node")
  return { x = node.x, z = node.z }
end

-- The world position the source prop occupies while it stands on one endpoint.
---@param runtimeMap table<string, unknown>
---@param endpoint integer
---@param worldY number
---@return { x: number, y: number, z: number }
function AzaleaGym.nodeWorldPosition(runtimeMap, endpoint, worldY)
  local node = assert(NODES[endpoint], "the spider endpoint names no source route node")
  local origin = assert(runtimeMap.coordinateOrigin, "a spider node needs the map coordinate origin")
  local worldX, worldZ = FieldGrid.tileCenterToWorld(node.x - origin.x, node.z - origin.z)
  return { x = worldX, y = worldY, z = worldZ - AzaleaGym.SPIDER_OFFSET_Z }
end

-- The spider slot this ride carries, while it carries one.
---@return integer|nil
function AzaleaGym:spiderSlot()
  return self._spiderSlot
end

-- Where the source prop itself stands this tick. The source moves the prop
-- from the route position with only its own model-space offsets, so the
-- presentation reads the ride's own position instead of re-deriving the
-- motion. Nil before the first motion tick, when the settled endpoint still
-- owns the prop's placement.
---@return { x: number, y: number, z: number }|nil
function AzaleaGym:spiderWorldPosition()
  if self._spiderWorldX == nil then
    return nil
  end
  return { x = self._spiderWorldX, y = self._spiderWorldY, z = self._spiderWorldZ }
end

---@return table<string, unknown> detached view of the ride
function AzaleaGym:view()
  return {
    phase = self._phase,
    selector = self._selector,
    playerZOffset = self._playerZOffset,
    nodeIndex = self._nodeIndex,
    segmentTicks = self._segmentTicks or 0,
  }
end

-- Start one ride. Answers false when the source table has no route for this
-- selector and mask: the script still ran, but no transport starts and nothing
-- is lost.
---@param selector integer
---@return boolean started
function AzaleaGym:start(selector)
  assert(self._phase == nil, "the spider ride already started")
  local switchMask = self._state:switchMask()
  local rideRoute = AzaleaGym.routeFor(selector, switchMask)
  if rideRoute == nil then
    self._phase = "arrived"
    return false
  end
  local spiderSlot = self._state:spiderAtEndpoint(selector)
  assert(spiderSlot ~= nil, "the ride selector names an endpoint no spider stands on")
  local reversed = REVERSED_SELECTORS[selector] == true
  local nodes = rideRoute.nodes
  self._selector = selector
  self._spiderSlot = spiderSlot
  self._switchMask = switchMask
  self._nodes = nodes
  self._destination = rideRoute.destination
  self._reversed = reversed
  -- Reversed selectors walk the table backwards and board one tile south.
  self._nodeIndex = reversed and #nodes or 1
  self._playerZOffset = reversed and 1 or 0
  self._spiderWorldX, self._spiderWorldY, self._spiderWorldZ = nil, nil, nil
  self._segmentDone = true
  self._arrivalNode = nodes[self._nodeIndex]
  self._spiderX = self._arrivalNode[1] * AzaleaGym.UNITS_PER_TILE
  self._spiderZ = self._arrivalNode[2] * AzaleaGym.UNITS_PER_TILE
  self._player:beginTransport()
  self._partnerId = self._actors:partnerId()
  -- The source's held movement is one cosmetic step in the travel direction,
  -- started on the ride's own first frame: the coordinate event that started
  -- the script settles its arrival tile in the same tick and must find an idle
  -- player there. A rider already standing on the spider's own node has
  -- nothing to step onto, so the ride carries them straight away instead of
  -- walking them off the node and back.
  self._stepDirection = reversed and "south" or "north"
  self._stepTicks = 0
  self._stepDuration = MovementCalibration.actionTicks({ action = "walk", speed = "normal" })
  local player = self._player
  if player.fieldX == self._arrivalNode[1] and player.fieldZ == self._arrivalNode[2] then
    self._phase = "starting"
  else
    self._phase = "boarding"
  end
  return true
end

---@param self AzaleaGym
local function placeRider(self)
  local player = self._player
  local node = self._arrivalNode
  local targetX, targetZ = node[1], node[2]
  local targetY = player.worldY
  player:commitTransport(targetX, targetZ + self._playerZOffset, targetY)
  local partnerId = self._partnerId
  if partnerId == nil or self._actors:getById(partnerId) == nil then
    return
  end
  -- The follower rides one tile behind the arrival tile: south of a forward
  -- selector's rider and north of a reversed one.
  self._followingMon:repositionRelativeToPlayer(self._playerZOffset == 0 and 1 or 0, 1)
end

---@param self AzaleaGym
local function beginMoving(self)
  self._audio:play(AzaleaGym.RIDE_SEQUENCE)
  -- The source plays the model's one-shot clip on this same frame
  -- (MapPropOneShotAnimationManager_PlayAnimation in START_MOVING).
  if self._model ~= nil then
    self._model:startRideAnimation()
  end
  self._phase = "moving"
end

---@param self AzaleaGym
local function advanceSegment(self)
  local index = self._nodeIndex
  local nodes = self._nodes
  local target = nodes[self._reversed and index - 1 or index + 1]
  assert(target ~= nil, "the source route ran past its last node")
  local dx = target[1] * AzaleaGym.UNITS_PER_TILE - self._spiderX
  local dz = target[2] * AzaleaGym.UNITS_PER_TILE - self._spiderZ
  local length = math.sqrt(dx * dx + dz * dz)
  assert(length > 0, "a route segment needs a length")
  self._segmentX = dx / length * AzaleaGym.UNITS_PER_TICK
  self._segmentZ = dz / length * AzaleaGym.UNITS_PER_TICK
  self._segmentTarget = target
  self._segmentDone = false
  self._segmentTicks = 0
end

-- One motion tick: advance along the current segment, stop a component that
-- would pass its node, and snap onto the node when both components arrived.
---@param self AzaleaGym
local function advanceMotion(self)
  if self._segmentDone then
    advanceSegment(self)
  end
  local target = self._segmentTarget
  local targetX = target[1] * AzaleaGym.UNITS_PER_TILE
  local targetZ = target[2] * AzaleaGym.UNITS_PER_TILE
  local progressX = componentProgress(self._segmentX >= 0, self._spiderX, self._segmentX, targetX)
  local progressZ = componentProgress(self._segmentZ >= 0, self._spiderZ, self._segmentZ, targetZ)
  if progressX == "passed" then
    self._segmentX = 0
  end
  if progressZ == "passed" then
    self._segmentZ = 0
  end
  self._segmentTicks = self._segmentTicks + 1
  if progressX ~= "not_reached" and progressZ ~= "not_reached" then
    self._spiderX, self._spiderZ = targetX, targetZ
    self._nodeIndex = self._reversed and self._nodeIndex - 1 or self._nodeIndex + 1
    self._arrivalNode = assert(self._nodes[self._nodeIndex], "the source route left its node table")
    local last = self._reversed and self._nodeIndex == 1 or self._nodeIndex == #self._nodes
    if last then
      self._state:setSpiderEndpoint(self._spiderSlot, self._destination)
      self._audio:stop(AzaleaGym.RIDE_SEQUENCE)
      if self._model ~= nil then
        self._model:stopRideAnimation()
      end
      self._phase = "arriving"
      return
    end
    self._segmentDone = true
    return
  end
  self._spiderX = self._spiderX + self._segmentX
  self._spiderZ = self._spiderZ + self._segmentZ
end

-- Carry both riders: the player sits on the spider and the visible follower
-- rides one tile behind in the source's own offset.
-- The follower rides one tile behind the spider in the source's own offset
-- (FollowMon position = spider position + 1 - playerZOffset tiles in Z). It is
-- carried as a presentation displacement from its own committed tile: the ride
-- never changes the follower's logical placement or occupancy.
---@param self AzaleaGym
local function carryRiders(self)
  local player = self._player
  local runtimeMap = assert(player.currentMap, "the ride needs the active runtime map")
  local origin = assert(runtimeMap.coordinateOrigin, "the ride needs the map coordinate origin")
  local localX = self._spiderX / AzaleaGym.UNITS_PER_TILE - origin.x
  local localZ = self._spiderZ / AzaleaGym.UNITS_PER_TILE - origin.z
  local worldX, worldZ = FieldGrid.tileCenterToWorld(localX, localZ)
  player:applyTransportPose(worldX, player.worldY, worldZ)
  -- The prop rides with its rider at the node's north edge, half a tile from
  -- the rider's own tile centre (see SPIDER_OFFSET_Z).
  self._spiderWorldX, self._spiderWorldY = worldX, player.worldY
  self._spiderWorldZ = worldZ - AzaleaGym.SPIDER_OFFSET_Z
  local partnerId = self._partnerId
  if partnerId == nil or self._actors:getById(partnerId) == nil then
    return
  end
  local position = self._actors:getPosition(partnerId)
  if position == nil then
    return
  end
  local followerX, followerZ = FieldGrid.tileCenterToWorld(position.fieldX - origin.x, position.fieldZ - origin.z)
  local followerY = position.worldY or player.worldY
  self._actors:setPresentationOffset(partnerId, {
    x = worldX - followerX,
    y = player.worldY - followerY,
    z = worldZ + (1 - self._playerZOffset) - followerZ,
  })
end

---@return string phase
function AzaleaGym:updateFixed()
  assert(PHASES[self._phase] == true, "the spider ride is not running")
  if self._phase == "boarding" then
    if self._stepTicks == 0 then
      self._player:beginScriptedAction({ action = "walk", direction = self._stepDirection, speed = "normal" })
    end
    self._stepTicks = self._stepTicks + 1
    self._player:advanceScriptedAction(self._stepTicks, self._stepDuration)
    if self._stepTicks >= self._stepDuration then
      self._player:commitScriptedAction()
      self._phase = "starting"
    end
    return self._phase
  end
  if self._phase == "starting" then
    beginMoving(self)
    return self._phase
  end
  if self._phase == "moving" then
    advanceMotion(self)
    carryRiders(self)
    return self._phase
  end
  if self._phase == "arriving" then
    placeRider(self)
    self._shakeCount = 0
    self._shakeFrame = 0
    self._phase = "shaking"
    if self._camera ~= nil and type(self._camera.startShake) == "function" then
      self._camera:startShake({
        amplitudeX = 0,
        amplitudeY = 1,
        intervalTicks = AzaleaGym.SHAKE_INTERVAL_TICKS,
        count = AzaleaGym.SHAKE_COUNT,
      })
    end
    return self._phase
  end
  if self._phase == "shaking" then
    self._shakeFrame = self._shakeFrame + 1
    if self._shakeFrame > 1 then
      self._shakeFrame = 0
      self._shakeCount = self._shakeCount + 1
    end
    if self._shakeCount >= AzaleaGym.SHAKE_COUNT then
      self._waitTicks = 0
      self._phase = "steppingOff"
    end
    return self._phase
  end
  if self._phase == "steppingOff" then
    self._waitTicks = self._waitTicks + 1
    if self._waitTicks >= AzaleaGym.STEP_OFF_DELAY_TICKS then
      self._phase = "arrived"
    end
    return self._phase
  end
  return self._phase
end

-- Cancel a ride before its arrival: the rider returns to the boarding tile,
-- the source endpoints stay untouched, and the ride's sound is released.
---@param reason string?
function AzaleaGym:cancel(reason)
  if self._phase == nil or self._phase == "arrived" or self._phase == "cancelled" then
    return
  end
  self._reason = reason
  if self._phase ~= "boarding" then
    self._audio:stop(AzaleaGym.RIDE_SEQUENCE)
  end
  if self._model ~= nil then
    self._model:stopRideAnimation()
  end
  local partnerId = self._partnerId
  if partnerId ~= nil and self._actors:getById(partnerId) ~= nil then
    self._actors:clearPresentationOffset(partnerId)
  end
  self._player:cancelTransport()
  self._phase = "cancelled"
end

-- Release everything the ride owns exactly once.
function AzaleaGym:dispose()
  if self._phase ~= nil and self._phase ~= "arrived" and self._phase ~= "cancelled" then
    self:cancel("the spider ride was disposed")
  end
end

---@return boolean
function AzaleaGym:isComplete()
  return self._phase == "arrived"
end

return AzaleaGym
