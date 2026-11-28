-- The Rocket costume scene. The original Goldenrod Tunnel script performs the
-- source costume avatar transition and then sets the costume flag; the costume
-- stays with the saved player across Continue and party changes, and it is
-- never an avatar replacement or a follower-inhibit signal of its own. The
-- render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:199", "map:199", "message-bank:117" },
    tags = { "field", "script", "avatar", "rocket" },
  },
  tests = {},
}

local MAP = "MAP_GOLDENROD_TUNNEL_B1F"
-- The source coordinate event claims x=15, z=7 through 13 while the takeover
-- sits at stage 2 (zone_event/192_D37R0102): the acceptance starts one step
-- outside that authored region and walks in so event arbitration, not a
-- direct script call, owns the trigger.
local OUTSIDE_TILE = { fieldX = 15, fieldZ = 6 }
local TRIGGER_TILE = { fieldX = 15, fieldZ = 7 }
local COSTUME_SCRIPT = "vanilla.hgss.scr_seq.0094.script_004"
local COSTUME_FLAG = FieldScriptSymbols.flagsByName.FLAG_SYS_ROCKET_COSTUME
local TAKEOVER_STAGE_VAR = FieldScriptSymbols.variablesByName.VAR_SCENE_ROCKET_TAKEOVER
local COSTUME_TRANSITION = "rocket"

local function boot()
  local baseFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, requestedMap)
      -- The tunnel's own map entry branches on the takeover stage; the costume
      -- scene belongs to the stage that has already begun.
      return FinalizedGameFixture.build(versionId, {
        location = {
          mapSymbol = requestedMap,
          fieldX = OUTSIDE_TILE.fieldX,
          fieldZ = OUTSIDE_TILE.fieldZ,
          facing = "south",
        },
        worldState = FieldEventState.new({ vars = { [TAKEOVER_STAGE_VAR] = 2 } }),
      })
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  game:waitForFieldEntry()
  return game
end

local function failureText(game, scriptId)
  local faults = game:recordsForScript(scriptId, "script.error")
  if #faults == 0 then
    return "no fault"
  end
  local payload = faults[1].payload or {}
  local context = payload.context or {}
  return tostring(payload.code)
    .. " ("
    .. tostring(context.command or context.originalName or "unknown")
    .. ": "
    .. tostring(payload.message)
    .. ")"
end

-- Advances the scene through its own messages and fixed-tick waits with
-- semantic confirm edges only, until the source script completes.
---@param game table booted acceptance game
---@param scriptId string source script driven by the scene
---@param maxTicks integer tick budget
local function runScene(game, scriptId, maxTicks)
  local function done()
    for _, record in ipairs(game:recordsForScript(scriptId, "script.ended")) do
      if record.payload and record.payload.completed == true then
        return true
      end
    end
    return false
  end
  for _ = 1, maxTicks do
    if done() then
      return
    end
    game:pressAction()
    game:step()
  end
  Assert.isTrue(done(), "the source costume scene completes: " .. failureText(game, scriptId))
end

local function costumeFlag(game)
  return game.runtime.scripts.worldState:isFlagSet(COSTUME_FLAG)
end

function T.tests.costume_scene_sets_the_source_flag_and_keeps_the_avatar_identity()
  local game = boot()
  local ok, err = xpcall(function()
    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "CHIKORITA", level = 12, form = 0, heldItem = "NONE" }),
      "the scene runs with the party lead the source follower belongs to"
    )
    game:advanceUntil("the lead gift installs a visible follower", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 240)
    local avatarIdBefore = game:snapshot().avatarId

    game:waitForFieldReady()
    -- Walk into the authored coordinate region: the source zone event must
    -- claim the costume script on its own.
    game:face("south")
    game:move("south")
    local stepped = game:advanceUntil("the costume step settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 240)
    Assert.equal(stepped.player.fieldX, TRIGGER_TILE.fieldX, "the step enters the authored trigger tile")
    Assert.equal(stepped.player.fieldZ, TRIGGER_TILE.fieldZ, "the step enters the authored trigger tile")
    game:advanceUntil("the source costume script starts", function()
      return #game:recordsForScript(COSTUME_SCRIPT, "script.started") > 0
    end, 240)
    runScene(game, COSTUME_SCRIPT, 2400)
    Assert.equal(
      #game:recordsForScript(COSTUME_SCRIPT, "script.error"),
      0,
      "the source costume scene completes: " .. failureText(game, COSTUME_SCRIPT)
    )

    Assert.isTrue(costumeFlag(game), "the scene sets the source Rocket costume flag")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(TAKEOVER_STAGE_VAR),
      3,
      "the source scene advances the takeover to stage 3"
    )
    local avatar = game.runtime.playerAvatar:status()
    Assert.equal(avatar.durableState, COSTUME_TRANSITION, "the source avatar transition owns the costume appearance")
    Assert.equal(game:snapshot().avatarId, avatarIdBefore, "the costume never replaces the player's avatar identity")
    Assert.equal(game.runtime.followingMonState:isInhibited(), false, "the costume is not a follower-inhibit signal")

    game:save()
    game:restart()
    Assert.isTrue(costumeFlag(game), "Continue keeps the source costume flag")
    Assert.equal(
      game.runtime.playerAvatar:status().durableState,
      COSTUME_TRANSITION,
      "Continue restores the costume appearance"
    )
    Assert.equal(game:snapshot().avatarId, avatarIdBefore, "Continue restores the same avatar identity")

    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "TOTODILE", level = 6, form = 0, heldItem = "NONE" }),
      "a party change runs through the production gift operation"
    )
    game:advanceUntil("the party addition settles", function()
      return game.runtime.monService:partyCount() == 2
    end, 240)
    Assert.isTrue(costumeFlag(game), "a party change never clears the source costume flag")
    Assert.equal(
      game.runtime.playerAvatar:status().durableState,
      COSTUME_TRANSITION,
      "a party change never clears the costume appearance"
    )
    Assert.equal(game:renderAttempts(), 0, "the costume acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
