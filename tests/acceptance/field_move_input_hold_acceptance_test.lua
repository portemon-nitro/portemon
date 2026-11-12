-- Production-composed field-move input hold: while a menu field-move task owns
-- the foreground (Teleport departure here), held directional input must not
-- turn or step the player. The retail field tasks own the field until the
-- arrival settles; the warp sequence drives facing itself, so ordinary
-- movement during the departure flaps the avatar between turn frames and
-- spin facings (the reported Teleport flicker) and can walk the player away
-- before the warp fires.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:33",
      "map:33",
      "audio-bank:152",
      "audio-bank:702",
      "audio-bank:703",
      "message-bank:23",
      "message-bank:150",
    },
    tags = { "field", "field-move", "acceptance" },
  },
  tests = {},
}

local function withGame(fn)
  local game = AcceptanceHarness.new({
    gameFactory = function(versionId)
      return FinalizedGameFixture.build(versionId, {
        location = { mapSymbol = "MAP_ROUTE_30", fieldX = 10, fieldZ = 10, facing = "south" },
      })
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_ROUTE_30",
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      audioOutput = FakeAudioOutput.new(),
      recordingScriptHosts = true,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "field-move input-hold acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function equipTeleport(game)
  local mons = assert(game.runtime.monService, "live mon service required")
  Assert.isTrue(
    mons:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0, location = 7 }),
    "setup gift must enter the party"
  )
  mons:setMove(0, 0, "TELEPORT")
end

-- The harness stands in for the field-move presentation by finishing
-- blocking cues and effects each tick, so a cut-in or cry the departure
-- plays observes the same one-tick completion production reports.
local function pumpCue(game)
  local scheduler = game.runtime.scripts.scheduler
  local cue = scheduler ~= nil and scheduler._services.fieldMoveCue or nil
  if cue ~= nil then
    cue:finishBlockingCue()
    cue:finishEffects()
  end
end

-- Steps until the named application script ends, failing on a script fault.
local function runEntryToEnd(game, scriptId, firstEvent)
  for _ = 1, 900 do
    for index = firstEvent + 1, #game:hostEvents().records do
      local event = game:hostEvents().records[index]
      Assert.isTrue(event.name ~= "script.error", scriptId .. " must not fault: " .. tostring(event.payload.message))
      if event.name == "script.ended" and event.payload.scriptId == scriptId then
        return event.payload
      end
    end
    if game:snapshot().dialogue.waiting or game:snapshot().dialogue.modal then
      game.runtime:pressAction()
      game:step()
      pumpCue(game)
      game.runtime:releaseAction()
    else
      game:step()
      pumpCue(game)
    end
  end
  error(scriptId .. " did not end", 0)
end

function T.tests.teleport_departure_ignores_held_directions_until_arrival()
  withGame(function(game)
    equipTeleport(game)
    local player = game.runtime.player
    local startX, startZ = player.fieldX, player.fieldZ
    local events = #game:hostEvents().records
    game.runtime:_admitFieldAction("pokemon.field_move", { move = "teleport", slot = 0 })
    -- Hold east through the departure: the warp sequence spins for ~100
    -- ticks before the white/black cover completes, so 40 held ticks stay
    -- well inside the departure on every version.
    game.runtime:press("east")
    for _ = 1, 40 do
      game:step()
      pumpCue(game)
      local snapshot = game:snapshot()
      Assert.equal(snapshot.player.fieldX, startX, "held input must not step the player during the departure")
      Assert.equal(snapshot.player.fieldZ, startZ, "held input must not step the player during the departure")
      Assert.equal(snapshot.player.motion, "idle", "held input must not turn the player during the departure")
    end
    game.runtime:release("east")
    local ended = runEntryToEnd(game, "runtime.field_move_entry", events)
    Assert.isTrue(ended.completed, "the entry script settles the arrival after the hold releases")
  end)
end

return T
