-- Azalea Gym's Spinarak transports. The gym's own coordinate events and switch
-- events drive the source ride scripts; each ride must resolve the spider by
-- its persisted endpoint, follow the source route (not a shortest path), carry
-- the visible follower, move the spider to the source destination endpoint and
-- commit it only on arrival. The switch mask selects a different source route
-- for the same selector. The render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local TransportTrace = require("tests.acceptance.support.TransportTrace")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:180", "map:180" },
    tags = { "field", "script", "gym" },
  },
  tests = {},
}

local MAP = "MAP_AZALEA_GYM"
local SPAWN = { fieldX = 9, fieldZ = 36 }
local INIT_SCRIPT = "vanilla.hgss.scr_seq.0869.script_016"
local SWITCH_LOW_SCRIPT = "vanilla.hgss.scr_seq.0869.script_014"

-- Source facts (src/field/gymmick/azalea.c). The twelve selector operands are
-- the endpoints the four spiders can occupy; the ride scripts start at selector
-- 2 in the generated script table. `travel` is the route's own length in tiles,
-- `arrival`/`follower` are the source tiles the ride ends on: a reversed
-- selector starts at the route's last node and boards one tile south of its
-- arrival tile (playerZOffset 1).
local RIDE_SEQUENCE = "SEQ_SE_GS_ITOMARU_ROBO"
local SWITCH_SEQUENCE = "SEQ_SE_DP_KI_GASYAN"

local function selectorScript(selector)
  return string.format("vanilla.hgss.scr_seq.0869.script_%03d", selector + 2)
end

local ROUTES = {
  -- sSpinarakRoute_1to5, destination endpoint 4.
  [0] = {
    [0] = { travel = 27, arrival = { 9, 24 }, follower = { 9, 25 } },
    [1] = { travel = 27, arrival = { 9, 24 }, follower = { 9, 25 } },
  },
  -- sSpinarakRoute_2to6, destination endpoint 5.
  [1] = {
    [0] = { travel = 25, arrival = { 15, 24 }, follower = { 15, 25 } },
    [1] = { travel = 25, arrival = { 15, 24 }, follower = { 15, 25 } },
  },
  -- sSpinarakRoute_3to4, destination endpoint 3.
  [2] = {
    [0] = { travel = 20, arrival = { 3, 24 }, follower = { 3, 25 } },
    [1] = { travel = 20, arrival = { 3, 24 }, follower = { 3, 25 } },
  },
  -- The same three tracks ridden back, destination endpoints 2, 0 and 1.
  [3] = {
    [0] = { travel = 20, arrival = { 15, 32 }, follower = { 15, 31 } },
    [1] = { travel = 20, arrival = { 15, 32 }, follower = { 15, 31 } },
  },
  [4] = {
    [0] = { travel = 27, arrival = { 3, 32 }, follower = { 3, 31 } },
    [1] = { travel = 27, arrival = { 3, 32 }, follower = { 3, 31 } },
  },
  [5] = {
    [0] = { travel = 25, arrival = { 9, 32 }, follower = { 9, 31 } },
    [1] = { travel = 25, arrival = { 9, 32 }, follower = { 9, 31 } },
  },
  -- Endpoint 7, the only initially occupied endpoint whose track depends on
  -- the switch mask: sSpinarakRoute_8to10 with mask 0, sSpinarakRoute_8to12
  -- with mask 1.
  [7] = {
    [0] = { travel = 27, arrival = { 3, 9 }, follower = { 3, 10 } },
    [1] = { travel = 13, arrival = { 15, 9 }, follower = { 15, 10 } },
  },
  -- Endpoint 9 rides the mask-0 track back to endpoint 7, or the shorter
  -- sSpinarakRoute_7to10 back to endpoint 6 with mask 1.
  [9] = {
    [0] = { travel = 27, arrival = { 9, 17 }, follower = { 9, 16 } },
    [1] = { travel = 21, arrival = { 3, 17 }, follower = { 3, 16 } },
  },
  -- Endpoint 6 has no route for masks 0 and 2; with mask 1 the source rides
  -- sSpinarakRoute_7to10 back down to endpoint 9.
  [6] = {
    [1] = { travel = 21, arrival = { 3, 9 }, follower = { 3, 10 } },
  },
  -- Endpoint 11 rides sSpinarakRoute_8to12 back to endpoint 7 with mask 1.
  [11] = {
    [1] = { travel = 13, arrival = { 9, 17 }, follower = { 9, 16 } },
  },
}

local function routeFor(selector, mask)
  local routes = ROUTES[selector]
  return routes and routes[mask] or nil
end

local function failureText(game, scriptId)
  local faults = game:recordsForScript(scriptId, "script.error")
  if #faults == 0 then
    return "no fault"
  end
  local payload = faults[1].payload or {}
  local context = payload.context or {}
  return tostring(payload.code) .. " (command " .. tostring(context.command or context.originalName or "unknown") .. ")"
end

local function withGymGame(fn)
  local versionId = AcceptanceHarness.defaultVersion()
  local baseFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(requestedVersion, map)
      local game = baseFactory(requestedVersion, map)
      game.location.fieldX = SPAWN.fieldX
      game.location.fieldZ = SPAWN.fieldZ
      game.location.facing = "north"
      return game
    end,
  })
  local game = harness:boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local added = game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, form = 0 })
    Assert.isTrue(added, "the fixture party lead enters through the production gift operation")
    game:advanceUntil("the lead gift installs a visible follower", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 240)
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the transport acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Walks to `approach` and takes one real step onto the trigger tile.
local function stepOnto(game, approach, direction, trigger)
  game:moveTo({ fieldX = approach[1], fieldZ = approach[2] })
  local standing = game:snapshot()
  Assert.equal(standing.player.fieldX, approach[1], "the approach tile is reached in x")
  Assert.equal(standing.player.fieldZ, approach[2], "the approach tile is reached in z")
  game:face(direction)
  game:move(direction)
  local entered = game:advanceUntil("the trigger step settles", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 240)
  Assert.equal(entered.player.fieldX, trigger[1], "the step enters the source trigger column")
  Assert.equal(entered.player.fieldZ, trigger[2], "the step enters the source trigger row")
  return entered
end

-- One source ride: proves the selector's own script ran, the ride followed the
-- source route travel, and the player and follower arrived on the source tiles.
local function ride(game, step)
  local selector, mask = step.selector, step.mask
  local route = assert(routeFor(selector, mask), "the source route table covers selector " .. selector)
  local scriptId = selectorScript(selector)
  local before = #game:recordsForScript(scriptId, "script.started")
  stepOnto(game, step.approach, step.direction, step.trigger)
  local samples = TransportTrace.observe(game, { label = step.label })

  Assert.equal(
    #game:recordsForScript(scriptId, "script.started"),
    before + 1,
    "the gym's own coordinate event starts the source ride script for selector " .. selector
  )
  Assert.equal(
    #game:recordsForScript(scriptId, "script.error"),
    0,
    "the source ride script for selector " .. selector .. " completes: " .. failureText(game, scriptId)
  )
  Assert.isNil(
    game.runtime.errorText,
    "the ride leaves the field runtime healthy: " .. tostring(game.runtime.errorText)
  )
  local arrived = samples[#samples]
  Assert.equal(arrived.fieldX, route.arrival[1], "selector " .. selector .. " arrives on the source tile column")
  Assert.equal(arrived.fieldZ, route.arrival[2], "selector " .. selector .. " arrives on the source tile row")
  local travel = TransportTrace.travel(samples)
  Assert.isTrue(
    travel >= route.travel - 1e-6,
    string.format(
      "selector %d covers the source route travel (%.3f of at least %d tiles)",
      selector,
      travel,
      route.travel
    )
  )
  Assert.isTrue(
    travel <= route.travel + 2 + 1e-6,
    string.format("selector %d detours beyond the source route (%.3f tiles)", selector, travel)
  )
  local follower = arrived.follower
  Assert.notNil(follower, "the follower stays published through selector " .. selector .. "'s ride")
  Assert.equal(
    follower.fieldX,
    route.follower[1],
    "the follower arrives on the source column for selector " .. selector
  )
  Assert.equal(follower.fieldZ, route.follower[2], "the follower arrives on the source row for selector " .. selector)
  return samples
end

-- The gym's own switch event: a background tile the player answers with the
-- action button, which toggles one switch bit and plays the source sound.
local function flipSwitch(game, stand, facing, scriptId)
  local effectsBefore = #game:hostEffects()
  local before = #game:recordsForScript(scriptId, "script.started")
  game:moveTo({ fieldX = stand[1], fieldZ = stand[2] })
  game:face(facing)
  game:pressAction()
  Assert.equal(game:interaction().kind, "background", "the gym switch is a source background event")
  game:advanceUntil("the switch releases the field", function(snapshot)
    return not snapshot.fieldLocked
  end, 240)
  Assert.equal(
    #game:recordsForScript(scriptId, "script.started"),
    before + 1,
    "the switch's own source script answers the action"
  )
  Assert.equal(#game:recordsForScript(scriptId, "script.error"), 0, "the switch script completes")
  local effects = game:hostEffects()
  local played = false
  for index = effectsBefore + 1, #effects do
    if effects[index] == "audio:" .. SWITCH_SEQUENCE then
      played = true
    end
  end
  Assert.isTrue(played, "the switch plays the source flip sound")
end

function T.tests.spinarak_rides_follow_the_source_routes_endpoints_and_switch_mask()
  withGymGame(function(game)
    Assert.equal(#game:recordsForScript(INIT_SCRIPT, "script.started"), 1, "the gym's map init script runs on entry")
    Assert.equal(
      #game:recordsForScript(INIT_SCRIPT, "script.error"),
      0,
      "the gym's map init script completes: " .. failureText(game, INIT_SCRIPT)
    )
    Assert.notNil(game:snapshot().actors["field:partner"], "the follower is visible for the rides")

    -- Selectors 0..5 with mask 0: the mask-independent shuttle between the
    -- gym's first two floors, each track ridden out and back so both of its
    -- endpoints end up occupied by the same spider.
    local first = ride(game, {
      label = "the first Spinarak ride",
      selector = 1,
      mask = 0,
      approach = { 9, 33 },
      direction = "north",
      trigger = { 9, 32 },
    })
    ride(game, {
      label = "the return ride",
      selector = 5,
      mask = 0,
      approach = { 15, 23 },
      direction = "south",
      trigger = { 15, 24 },
    })
    ride(game, {
      label = "the west ride",
      selector = 0,
      mask = 0,
      approach = { 3, 33 },
      direction = "north",
      trigger = { 3, 32 },
    })
    ride(game, {
      label = "the west return ride",
      selector = 4,
      mask = 0,
      approach = { 9, 23 },
      direction = "south",
      trigger = { 9, 24 },
    })
    ride(game, {
      label = "the east ride",
      selector = 2,
      mask = 0,
      approach = { 15, 33 },
      direction = "north",
      trigger = { 15, 32 },
    })
    ride(game, {
      label = "the east return ride",
      selector = 3,
      mask = 0,
      approach = { 3, 23 },
      direction = "south",
      trigger = { 3, 24 },
    })

    -- The transport plays its own source loop and releases it on arrival.
    local started, stopped = false, false
    for _, effect in ipairs(game:hostEffects()) do
      if effect == "audio:" .. RIDE_SEQUENCE then
        started = true
      elseif started and effect == "stop:" .. RIDE_SEQUENCE then
        stopped = true
      end
    end
    Assert.isTrue(started, "the ride starts the source spider sound")
    Assert.isTrue(stopped, "the ride stops the source spider sound on arrival")
    Assert.isTrue(TransportTrace.travel(first) > 0, "the ride transports the player")

    -- Mask 0 sends the spider standing at endpoint 7 down the long track; the
    -- same track ridden back from endpoint 9 is the return ride.
    ride(game, {
      label = "the north ride",
      selector = 0,
      mask = 0,
      approach = { 3, 33 },
      direction = "north",
      trigger = { 3, 32 },
    })
    ride(game, {
      label = "the long mask-0 ride",
      selector = 7,
      mask = 0,
      approach = { 9, 18 },
      direction = "north",
      trigger = { 9, 17 },
    })
    ride(game, {
      label = "the long return ride",
      selector = 9,
      mask = 0,
      approach = { 3, 8 },
      direction = "south",
      trigger = { 3, 9 },
    })

    -- Switch 0 toggles the low mask bit, and the same selector then takes the
    -- gym's other source track.
    flipSwitch(game, { 10, 18 }, "east", SWITCH_LOW_SCRIPT)
    ride(game, {
      label = "the short mask-1 ride",
      selector = 7,
      mask = 1,
      approach = { 9, 18 },
      direction = "north",
      trigger = { 9, 17 },
    })
    ride(game, {
      label = "the short return ride",
      selector = 11,
      mask = 1,
      approach = { 15, 8 },
      direction = "south",
      trigger = { 15, 9 },
    })

    -- A cancelled ride returns the rider to where it boarded, commits no
    -- endpoint and releases its sound, so the same selector then takes the
    -- same source track again.
    stepOnto(game, { 9, 18 }, "north", { 9, 17 })
    game:advanceUntil("the cancelled ride claims the field", function(snapshot)
      return snapshot.fieldLocked
    end, 240)
    for _ = 1, 20 do
      game:step()
    end
    local environmentId = game.runtime.scripts.scheduler:foregroundEnvironmentId()
    Assert.notNil(environmentId, "the cancelled ride owns one foreground environment")
    game.runtime.scripts.scheduler:cancelEnvironment(environmentId, "the ride is cancelled")
    local released = game:advanceUntil("the cancelled ride releases the field", function(snapshot)
      return not snapshot.fieldLocked
    end, 240)
    Assert.equal(released.player.fieldX, 9, "a cancelled ride returns the rider to the boarding column")
    Assert.equal(released.player.fieldZ, 17, "a cancelled ride returns the rider to the boarding row")
    Assert.notNil(game.runtime:captureGameSave(), "a cancelled ride leaves no in-flight claim behind")
    local releasedSound = false
    for _, effect in ipairs(game:hostEffects()) do
      if effect == "stop:" .. RIDE_SEQUENCE then
        releasedSound = true
      end
    end
    Assert.isTrue(releasedSound, "a cancelled ride stops the source spider sound")
    ride(game, {
      label = "the resumed mask-1 ride",
      selector = 7,
      mask = 1,
      approach = { 9, 18 },
      direction = "north",
      trigger = { 9, 17 },
    })

    -- The third floor's left chamber is reached only by the mask-1 ride from
    -- endpoint 9; the selector standing there has no source route, so it must
    -- refuse the ride.
    ride(game, {
      label = "the mask-1 return ride",
      selector = 11,
      mask = 1,
      approach = { 15, 8 },
      direction = "south",
      trigger = { 15, 9 },
    })
    flipSwitch(game, { 10, 18 }, "east", SWITCH_LOW_SCRIPT)
    ride(game, {
      label = "the repeated mask-0 ride",
      selector = 7,
      mask = 0,
      approach = { 9, 18 },
      direction = "north",
      trigger = { 9, 17 },
    })
    flipSwitch(game, { 4, 8 }, "north", SWITCH_LOW_SCRIPT)
    ride(game, {
      label = "the mask-1 descent",
      selector = 9,
      mask = 1,
      approach = { 3, 8 },
      direction = "south",
      trigger = { 3, 9 },
    })
    -- The third floor's left chamber is reached only by the mask-1 descent,
    -- which parks the spider on endpoint 6. With mask 1 that endpoint carries
    -- the source 7to10 track back to endpoint 9.
    ride(game, {
      label = "the endpoint-6 ride",
      selector = 6,
      mask = 1,
      approach = { 3, 18 },
      direction = "north",
      trigger = { 3, 17 },
    })
  end)
end

return T
