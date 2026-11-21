-- Gym mechanism ownership across the save boundary. A settled ride is captured,
-- continued at the height it settled on (the raised plate exists before the
-- loaded position is sampled), and rides back down; a cancelled ride releases
-- its leases and saves no handles; a non-connection map change clears the
-- active mechanism so the gym initialises its own source state again. The
-- render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local TransportTrace = require("tests.acceptance.support.TransportTrace")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:135", "map:135", "map-data:180", "map:180", "map-data:136", "map:136" },
    tags = { "field", "script", "gym", "save" },
  },
  tests = {},
}

local VIOLET_MAP = "MAP_VIOLET_GYM"
local PAD_TILE = { fieldX = 15, fieldZ = 20 }
local APPROACH_TILE = { fieldX = 15, fieldZ = 21 }
local GUIDE_ACTOR = "map:135:object:4"
local INIT_SCRIPT = "vanilla.hgss.scr_seq.0859.script_000"
local LIFT_SCRIPT = "vanilla.hgss.scr_seq.0859.script_004"
local LIFT_TILES = 29
local TILE_PER_TICK = 1
local MOTOR_SEQUENCE = "SEQ_SE_DP_ELEBETA"

local AZALEA_MAP = "MAP_AZALEA_GYM"
local AZALEA_SPAWN = { fieldX = 9, fieldZ = 36 }
local AZALEA_INIT_SCRIPT = "vanilla.hgss.scr_seq.0869.script_016"
local AZALEA_RIDE_SCRIPT = "vanilla.hgss.scr_seq.0869.script_003"
local AZALEA_DOOR = { fieldX = 9, fieldZ = 37 }
local AZALEA_FIRST_FLOOR_TRIGGER = { fieldX = 9, fieldZ = 32 }

local function bootViolet()
  local baseFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local game = baseFactory(versionId, map)
      game.location.fieldX = APPROACH_TILE.fieldX
      game.location.fieldZ = APPROACH_TILE.fieldZ
      game.location.facing = "north"
      return game
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = VIOLET_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  game:waitForFieldEntry()
  local added = game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, form = 0 })
  Assert.isTrue(added, "the fixture party lead enters through the production gift operation")
  game:advanceUntil("the lead gift installs a visible follower", function()
    return game.runtime.actors:partnerId() ~= nil
  end, 240)
  game:setActorRemovalFlag(GUIDE_ACTOR)
  return game
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

local function startLift(game)
  game:face("north")
  game:move("north")
  return TransportTrace.observe(game, { label = "the elevator ride" })
end

local function nonZeroSteps(samples)
  local steps = {}
  for _, step in ipairs(TransportTrace.heightSteps(samples)) do
    if step ~= 0 then
      steps[#steps + 1] = step
    end
  end
  return steps
end

local function effectCount(game, entry)
  local count = 0
  for _, effect in ipairs(game:hostEffects()) do
    if effect == entry then
      count = count + 1
    end
  end
  return count
end

function T.tests.settled_ride_survives_save_and_continue_and_rides_back_down()
  local game = bootViolet()
  local ok, err = xpcall(function()
    Assert.equal(
      #game:recordsForScript(INIT_SCRIPT, "script.error"),
      0,
      "the gym's map init script completes before the ride: " .. failureText(game, INIT_SCRIPT)
    )
    local groundHeight = game:snapshot().player.worldY
    local up = startLift(game)
    Assert.equal(#game:recordsForScript(LIFT_SCRIPT, "script.error"), 0, "the source lift script completes")
    local raisedHeight = TransportTrace.lastHeight(up)
    Assert.near(
      raisedHeight - groundHeight,
      LIFT_TILES * TILE_PER_TICK,
      1e-6,
      "the ride settles on the source upper floor"
    )
    local settled = game:snapshot()
    Assert.equal(settled.player.fieldX, PAD_TILE.fieldX, "the settled ride stands on the source pad")
    Assert.equal(settled.player.fieldZ, PAD_TILE.fieldZ, "the settled ride stands on the source pad")
    Assert.isFalse(settled.fieldLocked, "the settled ride returns ordinary input")

    game:save()
    Assert.isTrue(game.lifecycle.saveWrites > 0, "the settled ride publishes through the ordinary save store")
    game:restart()

    -- The raised plate has to exist before the loaded position is sampled, so
    -- the very first continued snapshot already reports the raised height.
    local continued = game:snapshot()
    Assert.equal(continued.mapSymbol, VIOLET_MAP, "Continue returns to the gym")
    Assert.equal(continued.player.fieldX, PAD_TILE.fieldX, "Continue restores the pad column")
    Assert.equal(continued.player.fieldZ, PAD_TILE.fieldZ, "Continue restores the pad row")
    Assert.near(continued.player.worldY, raisedHeight, 1e-6, "Continue restores the settled raised height")
    Assert.isNil(
      game.runtime.errorText,
      "Continue leaves the field runtime healthy: " .. tostring(game.runtime.errorText)
    )

    -- From the raised pad the same coordinate event rides back down to the
    -- ground floor the ride started from.
    game:moveTo({ fieldX = PAD_TILE.fieldX, fieldZ = APPROACH_TILE.fieldZ })
    local before = game:snapshot()
    Assert.near(before.player.worldY, raisedHeight, 1e-6, "the pad approach stays on the raised plate")
    game:face("north")
    game:move("north")
    local down = TransportTrace.observe(game, { label = "the descent ride" })
    Assert.equal(#game:recordsForScript(LIFT_SCRIPT, "script.error"), 0, "the descent script completes")
    local descending = nonZeroSteps(down)
    Assert.equal(#descending, LIFT_TILES, "the car descends for the source 29 motion ticks")
    for index, step in ipairs(descending) do
      Assert.near(step, -TILE_PER_TICK, 1e-6, "car motion tick " .. index .. " drops one source tile")
    end
    Assert.near(TransportTrace.lastHeight(down), groundHeight, 1e-6, "the descent settles on the ground floor")
    Assert.equal(game:snapshot().player.fieldZ, PAD_TILE.fieldZ, "the descent keeps the pad tile")
    Assert.equal(game:renderAttempts(), 0, "the save acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.cancelled_ride_releases_its_owner_and_saves_no_handles()
  local game = bootViolet()
  local ok, err = xpcall(function()
    Assert.equal(
      #game:recordsForScript(INIT_SCRIPT, "script.error"),
      0,
      "the gym's map init script completes before a cancelled ride: " .. failureText(game, INIT_SCRIPT)
    )
    local groundHeight = game:snapshot().player.worldY
    local motorStops = effectCount(game, "stop:" .. MOTOR_SEQUENCE)
    game:face("north")
    game:move("north")
    game:advanceUntil("the lift claims the field", function(snapshot)
      return snapshot.fieldLocked
    end, 240)
    for _ = 1, 12 do
      game:step()
    end
    local inFlight = game:snapshot()
    Assert.isNil(game.runtime:captureGameSave(), "an in-flight ride prohibits save capture")

    local environmentId = game.runtime.scripts.scheduler:foregroundEnvironmentId()
    Assert.notNil(environmentId, "the ride owns one foreground environment")
    game.runtime.scripts.scheduler:cancelEnvironment(environmentId, "the ride is cancelled")
    local released = game:advanceUntil("the cancelled ride releases the field", function(snapshot)
      return not snapshot.fieldLocked
    end, 240)

    Assert.equal(released.player.fieldX, PAD_TILE.fieldX, "a cancelled ride keeps the pad column")
    Assert.equal(released.player.fieldZ, PAD_TILE.fieldZ, "a cancelled ride keeps the pad tile")
    local settledHeight = released.player.worldY
    local onGround = math.abs(settledHeight - groundHeight) < 1e-6
    local onUpperFloor = math.abs(settledHeight - (groundHeight + LIFT_TILES * TILE_PER_TICK)) < 1e-6
    Assert.isTrue(
      onGround or onUpperFloor,
      string.format("a cancelled ride settles on a source stop height, not mid-flight (%.3f)", settledHeight)
    )
    Assert.isTrue(
      effectCount(game, "stop:" .. MOTOR_SEQUENCE) > motorStops,
      "a cancelled ride releases the source motor sound"
    )
    Assert.notNil(game.runtime:captureGameSave(), "a cancelled ride leaves no in-flight claim behind")

    -- No handle may reach the save: the continued runtime must restore the
    -- settled stop height with no fault and no active transport.
    game:save()
    game:restart()
    local continued = game:snapshot()
    Assert.equal(continued.mapSymbol, VIOLET_MAP, "Continue returns to the gym after a cancelled ride")
    Assert.near(continued.player.worldY, settledHeight, 1e-6, "Continue restores the settled stop height")
    Assert.isFalse(continued.fieldLocked, "Continue restores no in-flight transport")
    Assert.isNil(
      game.runtime.errorText,
      "Continue after a cancelled ride stays healthy: " .. tostring(game.runtime.errorText)
    )
    Assert.equal(game:renderAttempts(), 0, "the cancellation acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.non_connection_map_change_resets_the_active_mechanism()
  local versionId = AcceptanceHarness.defaultVersion()
  local baseFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(requestedVersion, map)
      local game = baseFactory(requestedVersion, map)
      game.location.fieldX = AZALEA_SPAWN.fieldX
      game.location.fieldZ = AZALEA_SPAWN.fieldZ
      game.location.facing = "north"
      return game
    end,
  })
  local game = harness:boot({
    versionId = versionId,
    map = AZALEA_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.equal(
      #game:recordsForScript(AZALEA_INIT_SCRIPT, "script.error"),
      0,
      "the gym's map init script completes on entry: " .. failureText(game, AZALEA_INIT_SCRIPT)
    )

    -- Move the spider standing at endpoint 1 to endpoint 5 with the gym's own
    -- ride, so a retained mechanism would refuse the same selector later.
    game:moveTo({ fieldX = 9, fieldZ = 33 })
    game:face("north")
    game:move("north")
    local first = TransportTrace.observe(game, { label = "the first ride" })
    Assert.isTrue(TransportTrace.travel(first) > 0, "the first ride transports the player")
    Assert.equal(#game:recordsForScript(AZALEA_RIDE_SCRIPT, "script.error"), 0, "the first ride script completes")

    -- Ride the same spider back to the first floor, then leave through the gym
    -- door and come back: an ordinary warp, not a connection, so the source
    -- clears the active mechanism on the way in.
    game:moveTo({ fieldX = 15, fieldZ = 23 })
    game:face("south")
    game:move("south")
    local back = TransportTrace.observe(game, { label = "the return ride" })
    Assert.isTrue(TransportTrace.travel(back) > 0, "the return ride transports the player")
    Assert.equal(back[#back].fieldZ, AZALEA_FIRST_FLOOR_TRIGGER.fieldZ, "the return ride lands back on the first floor")
    local fromMap = game:snapshot().mapSymbol
    game:moveTo({ fieldX = AZALEA_DOOR.fieldX, fieldZ = AZALEA_DOOR.fieldZ - 1 })
    game:face("south")
    game:move("south")
    -- The gym door is the source's south warp entrance: it evaluates while the
    -- player stands on it and presses south, not on the step that arrives.
    game:advanceUntil("the player stands on the gym door", function(snapshot)
      return snapshot.player.motion == "idle" and snapshot.player.fieldZ == AZALEA_DOOR.fieldZ
    end, 240)
    game:move("south")
    local left = game:advanceUntil("the gym door leaves the map", function(snapshot)
      return snapshot.mapSymbol ~= fromMap
    end, 960)
    Assert.equal(left.mapSymbol, "MAP_AZALEA_GYM_ENTRANCE", "the gym door leads to its entrance hall")
    game:waitForFieldReady(960)

    local entrance = game.runtime.runtimeMap
    local door
    for _, warp in ipairs(entrance.fieldData.events.warps or {}) do
      if warp.destinationMapId == 180 then
        door = warp
      end
    end
    Assert.notNil(door, "the entrance hall has a warp back into the gym")
    game:face("south")
    game:step({ direction = "south" })
    game:advanceUntil("the player steps off the arrival warp", function(snapshot)
      return snapshot.player.motion == "idle" and snapshot.player.fieldZ ~= door.z
    end, 240)
    game:moveTo({ fieldX = door.x, fieldZ = door.z })
    game:face("north")
    game:move("north")
    game:step()
    local returned = game:advanceUntil("the gym door re-enters the gym", function(snapshot)
      return snapshot.mapSymbol == AZALEA_MAP
    end, 960)
    Assert.equal(returned.mapSymbol, AZALEA_MAP, "the entrance hall returns into the gym")
    game:waitForFieldReady(960)
    Assert.equal(
      #game:recordsForScript(AZALEA_INIT_SCRIPT, "script.started"),
      2,
      "the gym's own map init script runs again on the new entry"
    )
    Assert.equal(#game:recordsForScript(AZALEA_INIT_SCRIPT, "script.error"), 0, "the re-entry init script completes")

    -- The mechanism was cleared, so the source spiders stand on their initial
    -- endpoints again and selector 1 rides from the first floor.
    game:moveTo({ fieldX = 9, fieldZ = 33 })
    game:face("north")
    game:move("north")
    local second = TransportTrace.observe(game, { label = "the ride after re-entry" })
    Assert.equal(#game:recordsForScript(AZALEA_RIDE_SCRIPT, "script.error"), 0, "the ride after re-entry completes")
    local arrived = second[#second]
    Assert.equal(arrived.fieldX, 15, "the re-entered mechanism rides to the source arrival column")
    Assert.equal(arrived.fieldZ, 24, "the re-entered mechanism rides to the source arrival row")
    Assert.isTrue(TransportTrace.travel(second) > 0, "the re-entered mechanism transports the player")
    Assert.equal(game:renderAttempts(), 0, "the lifecycle acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
