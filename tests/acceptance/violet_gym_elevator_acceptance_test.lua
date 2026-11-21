-- Violet Gym's elevator. The original map's own coordinate event starts the
-- source lift script; the ride then carries the player and the visible
-- follower along the source height timeline (one tile per tick for 29 ticks)
-- with the source motor and arrival sounds while publishing no walking step.
-- The render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local TransportTrace = require("tests.acceptance.support.TransportTrace")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:135", "map:135" },
    tags = { "field", "script", "gym" },
  },
  tests = {},
}

local MAP = "MAP_VIOLET_GYM"
local ELEVATOR_TILE = { fieldX = 15, fieldZ = 20 }
local APPROACH_TILE = { fieldX = 15, fieldZ = 21 }
-- The gym guide the source event data places on the elevator pad.
local GUIDE_ACTOR = "map:135:object:4"
local INIT_SCRIPT = "vanilla.hgss.scr_seq.0859.script_000"
local LIFT_SCRIPT = "vanilla.hgss.scr_seq.0859.script_004"

-- Source facts (src/field/gymmick/violet.c): the car rises FX32_CONST(16) per
-- tick from FX32_CONST(32) to FX32_CONST(496), i.e. one tile per tick for 29
-- ticks with one tile per 16 source units. Both sounds are the pinned
-- sequence identities the source plays.
local LIFT_TILES = 29
local TILE_PER_TICK = 1
local MOTOR_SEQUENCE = "SEQ_SE_DP_ELEBETA"
local ARRIVAL_SEQUENCE = "SEQ_SE_DP_KI_GASYAN"

local function failureText(game, scriptId)
  local faults = game:recordsForScript(scriptId, "script.error")
  if #faults == 0 then
    return "no fault"
  end
  local payload = faults[1].payload or {}
  local context = payload.context or {}
  return tostring(payload.code) .. " (command " .. tostring(context.command or context.originalName or "unknown") .. ")"
end

local function effectIndex(effects, entry)
  for index, effect in ipairs(effects) do
    if effect == entry then
      return index
    end
  end
  return nil
end

local function withLiftGame(fn)
  local versionId = AcceptanceHarness.defaultVersion()
  local baseFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(requestedVersion, map)
      local game = baseFactory(requestedVersion, map)
      game.location.fieldX = APPROACH_TILE.fieldX
      game.location.fieldZ = APPROACH_TILE.fieldZ
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
    -- The pad is a walkable tile; the source event data standing an NPC on it
    -- would otherwise block the coordinate event the elevator uses.
    game:setActorRemovalFlag(GUIDE_ACTOR)
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the elevator acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- One real step onto the pad, then the ride observed until the script
-- releases the field.
---@param game table
---@param options { onTick: (fun(snapshot: table): void)? }|nil
---@return TransportTrace.Sample[]
local function ride(game, options)
  game:face("north")
  game:move("north")
  return TransportTrace.observe(game, { label = "the elevator ride", onTick = options and options.onTick or nil })
end

function T.tests.elevator_carries_the_player_and_follower_on_the_source_timeline()
  withLiftGame(function(game)
    Assert.equal(
      #game:recordsForScript(INIT_SCRIPT, "script.started"),
      1,
      "the gym's own map init script runs once on entry"
    )
    Assert.equal(
      #game:recordsForScript(INIT_SCRIPT, "script.error"),
      0,
      "the map init script completes: " .. failureText(game, INIT_SCRIPT)
    )
    local partnerId = game.runtime.actors:partnerId()
    Assert.equal(partnerId, "field:partner", "the party lead is the visible follower")

    game:face("north")
    local boarding = game:snapshot()
    Assert.equal(boarding.player.fieldX, ELEVATOR_TILE.fieldX, "the start tile is the source pad column")
    Assert.equal(boarding.player.fieldZ, APPROACH_TILE.fieldZ, "the approach stands one tile south of the pad")
    Assert.equal(boarding.player.facing, "north", "the ride starts facing the pad")
    local groundHeight = boarding.player.worldY
    Assert.notNil(boarding.actors[partnerId], "the follower is published before the ride")

    local saveDuringRide = {}
    local samples = ride(game, {
      onTick = function()
        saveDuringRide[#saveDuringRide + 1] = game.runtime:captureGameSave()
      end,
    })

    Assert.equal(
      #game:recordsForScript(LIFT_SCRIPT, "script.started"),
      1,
      "the pad's coordinate event starts the source lift script"
    )
    Assert.equal(
      #game:recordsForScript(LIFT_SCRIPT, "script.error"),
      0,
      "the source lift script completes: " .. failureText(game, LIFT_SCRIPT)
    )
    Assert.isNil(
      game.runtime.errorText,
      "the lift leaves the field runtime healthy: " .. tostring(game.runtime.errorText)
    )

    -- The claim tick itself may still belong to the script's own setup, so the
    -- in-flight denial is asserted from the first ride tick on.
    for index = 2, #saveDuringRide do
      Assert.isNil(saveDuringRide[index], "an in-flight ride prohibits save capture at sample " .. index)
    end

    local arrivesAt = samples[#samples]
    Assert.equal(arrivesAt.fieldX, ELEVATOR_TILE.fieldX, "the ride never publishes a walking step across the pad")
    Assert.equal(arrivesAt.fieldZ, ELEVATOR_TILE.fieldZ, "the ride never publishes a walking step across the pad")
    Assert.equal(TransportTrace.travel(samples), 0, "the ride moves no horizontal distance")

    local rising = {}
    for _, step in ipairs(TransportTrace.heightSteps(samples)) do
      if step ~= 0 then
        rising[#rising + 1] = step
      end
    end
    Assert.equal(#rising, LIFT_TILES, "the car rises for the source 29 motion ticks")
    for index, step in ipairs(rising) do
      Assert.near(step, TILE_PER_TICK, 1e-6, "car motion tick " .. index .. " rises one source tile")
    end
    Assert.near(
      TransportTrace.lastHeight(samples) - groundHeight,
      LIFT_TILES * TILE_PER_TICK,
      1e-6,
      "the car stops at the source upper floor height"
    )
    for _, sample in ipairs(samples) do
      Assert.isTrue(sample.motion ~= "walk", "no walking movement is presented during the transport")
    end
    Assert.isNil(game.runtime.pendingEncounterId, "the transport never queues an encounter")

    local carriedFollower = arrivesAt.follower
    Assert.notNil(carriedFollower, "the follower stays published through the ride")
    Assert.near(carriedFollower.y, arrivesAt.y, 1e-6, "the follower rides at the player's height")
    Assert.equal(carriedFollower.fieldX, arrivesAt.fieldX, "the follower arrives on the player's column")
    Assert.equal(carriedFollower.fieldZ, arrivesAt.fieldZ, "the follower arrives with the player")

    local effects = game:hostEffects()
    local motor = effectIndex(effects, "audio:" .. MOTOR_SEQUENCE)
    local motorStop = effectIndex(effects, "stop:" .. MOTOR_SEQUENCE)
    local arrival = effectIndex(effects, "audio:" .. ARRIVAL_SEQUENCE)
    Assert.notNil(motor, "the ride starts the source motor sequence")
    Assert.notNil(motorStop, "the ride stops the source motor sequence")
    Assert.notNil(arrival, "the ride plays the source arrival sequence")
    Assert.isTrue(motor < motorStop, "the motor runs before it is stopped")
    Assert.isTrue(motorStop < arrival, "the arrival chime follows the stopped motor")
  end)
end

return T
