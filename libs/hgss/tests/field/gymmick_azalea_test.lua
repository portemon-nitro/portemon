-- The Azalea Gym Spinarak transport over the closed mechanism: the source
-- route table for every selector and switch mask, the source travel length,
-- the arrival tiles, the endpoint committed at arrival, and the no-route
-- refusal for the table's genuinely empty entries.

local Assert = require("tests.support.Assert")
local AzaleaGym = require("libs.hgss.src.field.gymmick.AzaleaGym")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")

local T = {}

local TILE = 16

-- A field host that records the ride's observable effect: the rider's world
-- position, the tiles the mechanism commits, the follower placement, and the
-- source sound sequence.
local function newHost(union)
  local host = {
    player = {
      fieldX = 0,
      fieldZ = 0,
      worldX = 0,
      worldY = 0,
      worldZ = 0,
      motion = "idle",
      currentMap = { coordinateOrigin = { x = 0, z = 0 } },
      _transport = false,
      _step = nil,
    },
    route = {},
    commits = {},
    placements = {},
    effects = {},
    offsets = {},
    partner = { actorId = "field:partner", fieldX = 0, fieldZ = 0, worldY = 0 },
  }
  local player = host.player
  function player:beginTransport()
    assert(self._transport == false, "a transport is already active")
    self._transport = true
    host.anchor = { fieldX = self.fieldX, fieldZ = self.fieldZ }
  end
  function player:isTransporting()
    return self._transport
  end
  function player:applyTransportPose(worldX, worldY, worldZ)
    assert(self._transport, "no transport owns the player")
    self.worldX, self.worldY, self.worldZ = worldX, worldY, worldZ
    local last = host.route[#host.route]
    local distance = 0
    if last ~= nil then
      distance = math.sqrt((worldX - last.x) ^ 2 + (worldZ - last.z) ^ 2)
    end
    host.route[#host.route + 1] = { x = worldX, z = worldZ, distance = distance }
  end
  function player:commitTransport(fieldX, fieldZ, worldY)
    assert(self._transport, "no transport owns the player")
    self._transport = false
    self.fieldX, self.fieldZ = fieldX, fieldZ
    self.worldY = worldY or self.worldY
    host.commits[#host.commits + 1] = { fieldX = fieldX, fieldZ = fieldZ }
  end
  function player:cancelTransport()
    if not self._transport then
      return
    end
    self._transport = false
    self.fieldX, self.fieldZ = host.anchor.fieldX, host.anchor.fieldZ
    host.cancelled = true
  end
  function player:beginScriptedAction(action)
    host.started = { action = action }
    self.motion = "walking"
    self._step = { fieldX = self.fieldX, fieldZ = self.fieldZ }
    if action.direction == "north" then
      self._step.fieldZ = self.fieldZ - 1
    elseif action.direction == "south" then
      self._step.fieldZ = self.fieldZ + 1
    end
  end
  function player:advanceScriptedAction()
    host.stepTicks = (host.stepTicks or 0) + 1
  end
  function player:commitScriptedAction()
    self.motion = "idle"
    if self._step ~= nil then
      self.fieldX, self.fieldZ = self._step.fieldX, self._step.fieldZ
      self._step = nil
    end
  end
  host.actors = {
    partnerId = function()
      return host.partner.actorId
    end,
    getById = function()
      return host.partner
    end,
    getPosition = function()
      return { fieldX = host.partner.fieldX, fieldZ = host.partner.fieldZ, worldY = host.partner.worldY }
    end,
    setPresentationOffset = function(_, actorId, offset)
      host.offsets[#host.offsets + 1] = { actorId = actorId, offset = offset }
    end,
    clearPresentationOffset = function()
      host.clearedOffset = true
    end,
  }
  host.followingMon = {
    repositionRelativeToPlayer = function(_, offsetSelector, directionRaw)
      local anchor = { fieldX = host.player.fieldX, fieldZ = host.player.fieldZ }
      local dz = offsetSelector == 0 and -1 or 1
      host.placements[#host.placements + 1] = {
        fieldX = anchor.fieldX,
        fieldZ = anchor.fieldZ + dz,
        direction = directionRaw,
      }
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
  host.state = GymMechanismState.restore(union)
  return host
end

local function newRide(host)
  return AzaleaGym.new({
    player = host.player,
    actors = host.actors,
    followingMon = host.followingMon,
    audio = host.audio,
    state = host.state,
  })
end

-- The source route table, as the ride's own contract: one entry per
-- (selector, mask) the source can actually transport, keyed by its travel
-- length in tiles, arrival tile (node + playerZOffset), and follower tile
-- (node + 1 - playerZOffset).
local ROUTES = {
  [0] = {
    [0] = { travel = 27, arrival = { 9, 24 }, follower = { 9, 25 }, destination = 4 },
    [1] = { travel = 27, arrival = { 9, 24 }, follower = { 9, 25 }, destination = 4 },
    [2] = { travel = 27, arrival = { 9, 24 }, follower = { 9, 25 }, destination = 4 },
    [3] = { travel = 27, arrival = { 9, 24 }, follower = { 9, 25 }, destination = 4 },
  },
  [1] = {
    [0] = { travel = 25, arrival = { 15, 24 }, follower = { 15, 25 }, destination = 5 },
    [1] = { travel = 25, arrival = { 15, 24 }, follower = { 15, 25 }, destination = 5 },
    [2] = { travel = 25, arrival = { 15, 24 }, follower = { 15, 25 }, destination = 5 },
    [3] = { travel = 25, arrival = { 15, 24 }, follower = { 15, 25 }, destination = 5 },
  },
  [2] = {
    [0] = { travel = 20, arrival = { 3, 24 }, follower = { 3, 25 }, destination = 3 },
    [1] = { travel = 20, arrival = { 3, 24 }, follower = { 3, 25 }, destination = 3 },
    [2] = { travel = 20, arrival = { 3, 24 }, follower = { 3, 25 }, destination = 3 },
    [3] = { travel = 20, arrival = { 3, 24 }, follower = { 3, 25 }, destination = 3 },
  },
  [3] = {
    [0] = { travel = 20, arrival = { 15, 32 }, follower = { 15, 31 }, destination = 2 },
    [1] = { travel = 20, arrival = { 15, 32 }, follower = { 15, 31 }, destination = 2 },
    [2] = { travel = 20, arrival = { 15, 32 }, follower = { 15, 31 }, destination = 2 },
    [3] = { travel = 20, arrival = { 15, 32 }, follower = { 15, 31 }, destination = 2 },
  },
  [4] = {
    [0] = { travel = 27, arrival = { 3, 32 }, follower = { 3, 31 }, destination = 0 },
    [1] = { travel = 27, arrival = { 3, 32 }, follower = { 3, 31 }, destination = 0 },
    [2] = { travel = 27, arrival = { 3, 32 }, follower = { 3, 31 }, destination = 0 },
    [3] = { travel = 27, arrival = { 3, 32 }, follower = { 3, 31 }, destination = 0 },
  },
  [5] = {
    [0] = { travel = 25, arrival = { 9, 32 }, follower = { 9, 31 }, destination = 1 },
    [1] = { travel = 25, arrival = { 9, 32 }, follower = { 9, 31 }, destination = 1 },
    [2] = { travel = 25, arrival = { 9, 32 }, follower = { 9, 31 }, destination = 1 },
    [3] = { travel = 25, arrival = { 9, 32 }, follower = { 9, 31 }, destination = 1 },
  },
  [6] = {
    [1] = { travel = 21, arrival = { 3, 9 }, follower = { 3, 10 }, destination = 9 },
    [3] = { travel = 14, arrival = { 9, 9 }, follower = { 9, 10 }, destination = 10 },
  },
  [7] = {
    [0] = { travel = 27, arrival = { 3, 9 }, follower = { 3, 10 }, destination = 9 },
    [1] = { travel = 13, arrival = { 15, 9 }, follower = { 15, 10 }, destination = 11 },
    [2] = { travel = 21, arrival = { 9, 9 }, follower = { 9, 10 }, destination = 10 },
    [3] = { travel = 13, arrival = { 15, 9 }, follower = { 15, 10 }, destination = 11 },
  },
  [9] = {
    [0] = { travel = 27, arrival = { 9, 17 }, follower = { 9, 16 }, destination = 7 },
    [1] = { travel = 20, arrival = { 3, 17 }, follower = { 3, 16 }, destination = 6 },
  },
  [10] = {
    [2] = { travel = 21, arrival = { 9, 17 }, follower = { 9, 16 }, destination = 7 },
    [3] = { travel = 14, arrival = { 3, 17 }, follower = { 3, 16 }, destination = 6 },
  },
  [11] = {
    [1] = { travel = 13, arrival = { 9, 17 }, follower = { 9, 16 }, destination = 7 },
    [3] = { travel = 13, arrival = { 9, 17 }, follower = { 9, 16 }, destination = 7 },
  },
}

-- Every selector the source can transport: its spider slot, the endpoint it
-- starts on, and the switch masks the table carries a route for.
local OCCUPANCY = {
  [0] = { 0 },
  [1] = { 1 },
  [2] = { 2 },
  [3] = { 3 },
  [4] = { 4 },
  [5] = { 5 },
  [6] = { 6 },
  [7] = { 7 },
  [8] = { 8 },
  [9] = { 9 },
  [10] = { 10 },
  [11] = { 11 },
}

-- A source-valid union with the tested endpoint occupied by the first spider
-- and its destination left free: two spiders never share an endpoint.
local function unionFor(selector, switchMask)
  local destination = ROUTES[selector] and ROUTES[selector][switchMask]
  local endpoints = { selector }
  local candidate = 0
  while #endpoints < 4 do
    local taken = candidate == selector or (destination ~= nil and candidate == destination.destination)
    for _, value in ipairs(endpoints) do
      if value == candidate then
        taken = true
      end
    end
    if not taken then
      endpoints[#endpoints + 1] = candidate
    end
    candidate = candidate + 1
  end
  return {
    schema = GymMechanismState.SCHEMA,
    kind = "azalea",
    data = { endpoints = endpoints, switchMask = switchMask },
  }
end

local function drive(host, ride, limit)
  local ticks = 0
  while not ride:isComplete() do
    ticks = ticks + 1
    Assert.isTrue(ticks <= (limit or 4000), "the ride terminates")
    ride:updateFixed()
  end
  return ticks
end

local function travel(host)
  local total = 0
  for _, point in ipairs(host.route) do
    total = total + point.distance
  end
  return total
end

-- Every selector × switch mask the source table can transport: the ride
-- follows the source route, arrives on the source tiles, commits the source
-- destination endpoint and places the follower one tile behind.
function T.every_source_route_carries_the_rider_to_its_own_destination()
  local checked = 0
  local reversedSelectors = { [3] = true, [4] = true, [5] = true, [9] = true, [10] = true, [11] = true }
  for selector, occupancy in pairs(OCCUPANCY) do
    local endpoint = occupancy[1]
    for mask = 0, 3 do
      local expected = ROUTES[selector] and ROUTES[selector][mask]
      local union = unionFor(endpoint, mask)
      local host = newHost(union)
      local route = AzaleaGym.routeFor(selector, mask)
      -- The rider boards from the route's own first node (reversed selectors
      -- walk the table backwards, exactly like the source's curNodeIndex).
      local startNode
      if route ~= nil then
        startNode = reversedSelectors[selector] and route.nodes[#route.nodes] or route.nodes[1]
      else
        startNode = { 0, 0 }
      end
      host.player.fieldX, host.player.fieldZ = startNode[1], startNode[2]
      local ride = newRide(host)
      local started = ride:start(selector)
      if expected == nil then
        Assert.isFalse(started, string.format("selector %d mask %d has no source route", selector, mask))
        Assert.equal(#host.route, 0, "a refused ride transports nothing")
        Assert.equal(host.player.fieldX, startNode[1], "a refused ride keeps the rider on its tile")
        Assert.equal(host.player.fieldZ, startNode[2])
        Assert.deepEqual(host.state:capture().data.endpoints, union.data.endpoints, "a refusal commits no endpoint")
        Assert.equal(#host.effects, 0, "a refusal plays no source sound")
        drive(host, ride)
      else
        Assert.isTrue(started, string.format("selector %d mask %d rides its source route", selector, mask))
        drive(host, ride)
        Assert.equal(
          host.player.fieldX,
          expected.arrival[1],
          string.format("selector %d mask %d arrives on the source column", selector, mask)
        )
        Assert.equal(host.player.fieldZ, expected.arrival[2], "and on the source row")
        local measured = travel(host)
        -- The ride starts on the route's own first node here, so the boarding
        -- hop a production trigger tile adds is not part of this length; the
        -- sampled length stays within the route's own tick budget plus the
        -- arrival snap, and a shortest-path substitution still fails it.
        Assert.isTrue(
          measured >= expected.travel - 2 and measured <= expected.travel + 2,
          string.format(
            "selector %d mask %d travels its source route (%.3f of %d)",
            selector,
            mask,
            measured,
            expected.travel
          )
        )
        local placed = host.placements[#host.placements]
        Assert.notNil(placed, "the ride places the follower")
        Assert.equal(placed.fieldX, expected.follower[1])
        Assert.equal(placed.fieldZ, expected.follower[2])
        local endpoints = host.state:capture().data.endpoints
        local slot
        for index, value in ipairs(endpoints) do
          if value == expected.destination then
            slot = index
          end
        end
        Assert.notNil(slot, "the arrival committed the source destination endpoint")
        Assert.equal(host.commits[1].fieldX, expected.arrival[1], "the arrival tile is committed once")
        Assert.equal(#host.commits, 1, "the ride commits exactly one arrival tile")
        checked = checked + 1
      end
    end
  end
  Assert.isTrue(checked >= 28, "the matrix covers the source's transportable selectors and masks")
end

-- The source table's empty entries: node 6 has no route for masks 0 and 2, so
-- the script runs but no transport starts, nothing is committed, and the save
-- stays available.
function T.an_empty_source_table_refuses_without_losing_anything()
  for mask = 0, 2, 2 do
    local host = newHost(unionFor(6, mask))
    host.player.fieldX, host.player.fieldZ = 3, 16
    local ride = newRide(host)
    Assert.isFalse(ride:start(6), "mask " .. mask .. " has no route from node 6")
    Assert.isTrue(ride:isComplete(), "a refused ride completes at once")
    Assert.isFalse(host.player:isTransporting(), "a refusal claims no transport")
    Assert.equal(#host.commits, 0)
    Assert.equal(#host.placements, 0)
    Assert.equal(#host.effects, 0)
  end
end

-- A cancelled ride returns the rider to the boarding tile and commits no
-- endpoint, so the same selector takes the same source track afterwards.
function T.a_cancelled_ride_keeps_the_source_endpoints()
  local union = unionFor(7, 0)
  local host = newHost(union)
  host.endpoints = union.data.endpoints
  host.player.fieldX, host.player.fieldZ = 9, 17
  local ride = newRide(host)
  Assert.isTrue(ride:start(7))
  for _ = 1, 40 do
    ride:updateFixed()
  end
  ride:cancel("cancelled")
  Assert.isTrue(host.cancelled, "the rider returns to its boarding tile")
  Assert.equal(host.player.fieldX, 9)
  Assert.equal(host.player.fieldZ, 17)
  Assert.deepEqual(
    host.state:capture().data.endpoints,
    host.endpoints,
    "a cancelled ride commits no endpoint"
  )
  Assert.equal(host.effects[#host.effects], "stop:" .. AzaleaGym.RIDE_SEQUENCE, "the ride sound is released")
  ride:dispose()
  Assert.isFalse(host.player:isTransporting(), "dispose leaves no transport behind")
end

-- The reversed selectors board one tile south and therefore carry the
-- follower one tile north of the rider, exactly like the source's
-- playerZOffset.
function T.reversed_selectors_carry_the_follower_on_the_other_side()
  local host = newHost(unionFor(3, 0))
  local route = assert(AzaleaGym.routeFor(3, 0))
  local node = route.nodes[#route.nodes]
  -- The reversed selectors' own trigger tile is the spider's node, so the
  -- rider boards from one tile north of it.
  host.player.fieldX, host.player.fieldZ = node[1], node[2] - 1
  local ride = newRide(host)
  Assert.equal(ride:view().phase == nil, true, "the ride starts unclaimed")
  Assert.isTrue(ride:start(3))
  ride:updateFixed()
  local started = assert(host.started, "the ride boards with one source step")
  Assert.equal(started.action.direction, "south", "a reversed selector boards south")
  drive(host, ride)
  local placed = host.placements[#host.placements]
  Assert.equal(placed.fieldZ, host.player.fieldZ - 1, "the follower rides north of a reversed arrival")
end

return { tests = T }
