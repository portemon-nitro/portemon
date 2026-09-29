-- Production-composed New Bark rival contract. Boots the real field
-- runtime on the real town map, talks to the real generated rival object
-- through the production script composition, and stops before rendering.
-- The rival script reads the player's facing through the script-facing
-- service and compares it against its numeric source direction codes; on
-- the matching branch it shoves the player one tile south through a
-- scripted movement sequence. The test proves the talk reaches that push:
-- the rival script starts, a movement task runs under its instance, and
-- the committed player tile moves south with no script fault.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:60" },
    tags = { "field", "interaction" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local RIVAL_SCRIPT = "vanilla.hgss.scr_seq.0842.script_000"

local function rivalTile(snapshot)
  for _, actorId in ipairs({ "map:60:object:0", "map:60:object:5", "map:60:object:7" }) do
    local actor = snapshot.actors[actorId]
    if actor ~= nil then
      return actorId, actor
    end
  end
  return nil, nil
end

local function movementTasksFor(game, instanceId)
  local kept = {}
  for _, record in ipairs(game:recordsNamed("script.task_started")) do
    local payload = record.payload or {}
    if payload.taskType == "movement" and payload.instanceId == instanceId then
      kept[#kept + 1] = record
    end
  end
  return kept
end

local function describeState(game)
  local snapshot = game:snapshot()
  return "player="
    .. tostring(snapshot.player.fieldX)
    .. ","
    .. tostring(snapshot.player.fieldZ)
    .. "/"
    .. tostring(snapshot.player.facing)
    .. " motion="
    .. tostring(snapshot.player.motion)
    .. " locked="
    .. tostring(snapshot.fieldLocked)
    .. " foreground="
    .. tostring(snapshot.foregroundScript)
    .. " dialogueModal="
    .. tostring(snapshot.dialogue.modal)
end

function T.tests.rival_talk_pushes_the_player_south_through_scripted_movement()
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness:boot({
    versionId = versionId,
    map = TOWN,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER })
    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, form = 0 }),
      "the setup gift must enter the party"
    )
    game:advanceUntil("partner installs", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 120)
    local settled = game:snapshot()
    local rivalId, rival = rivalTile(settled)
    Assert.notNil(
      rival,
      "the town rival object must be published after the starter gift"
        .. " (partner="
        .. tostring(game.runtime.actors:partnerId())
        .. " actors visible for map:60:object:5="
        .. tostring(settled.actors["map:60:object:5"] ~= nil)
        .. " map:60:object:7="
        .. tostring(settled.actors["map:60:object:7"] ~= nil)
        .. ")"
    )
    game:moveTo({ fieldX = 681, fieldZ = 391 })
    game:face("east")
    game:pressAction()
    local interaction = game:interaction()
    Assert.equal(
      interaction.scriptId,
      RIVAL_SCRIPT,
      "talking to the rival from the west must start the town rival script"
        .. " (kind="
        .. tostring(interaction.kind)
        .. " actor="
        .. tostring(interaction.actorId)
        .. " script="
        .. tostring(interaction.scriptId)
        .. " rival="
        .. tostring(rivalId)
        .. ")"
    )
    local starts = game:recordsForScript(RIVAL_SCRIPT)
    Assert.equal(#starts, 1, "the rival talk must start its foreground script exactly once")
    local instanceId = assert(starts[1].payload.instanceId, "the rival start must carry instance identity")
    local startZ = game:snapshot().player.fieldZ
    -- Drive the talk through its dialogue pages with production confirm
    -- edges until the scripted push displaces the player south or the
    -- budget runs out. Quiet ticks only advance the scheduler; a confirm
    -- edge only fires while the dialogue modal owns the field.
    local pushed = nil
    local lowestY = game:snapshot().player.worldY
    local peakY = lowestY
    for _ = 1, 1500 do
      local snapshot = game:snapshot()
      lowestY = math.min(lowestY, snapshot.player.worldY)
      peakY = math.max(peakY, snapshot.player.worldY)
      if snapshot.player.fieldZ > startZ then
        pushed = pushed or snapshot
      end
      if snapshot.player.fieldZ >= startZ + 3 then
        pushed = snapshot
        break
      end
      if snapshot.dialogue.modal then
        game.runtime:pressAction()
        game:step()
        game.runtime:releaseAction()
      else
        game:step()
      end
    end
    local faults = game:recordsForScript(RIVAL_SCRIPT, "script.error")
    Assert.equal(
      #faults,
      0,
      "the rival talk must run without a script fault; got " .. tostring(faults[1] and faults[1].payload.code)
    )
    local movements = movementTasksFor(game, instanceId)
    Assert.isTrue(
      #movements >= 1,
      "the rival flow must reach its scripted movement after the facing branch (" .. describeState(game) .. ")"
    )
    Assert.notNil(
      pushed,
      "the rival talk must push the player south of tile row "
        .. tostring(startZ)
        .. " ("
        .. describeState(game)
        .. " movement tasks under the rival instance="
        .. tostring(#movements)
        .. ")"
    )
    local shovePeak = peakY - lowestY
    Assert.isTrue(shovePeak > 0.5, "the rival shove visibly lifts the player")
    Assert.isTrue(
      math.abs(shovePeak - 0.75) < 1e-9,
      "the rival shove peaks at the retail far-jump height, got " .. tostring(shovePeak)
    )
    Assert.equal(game:renderAttempts(), 0, "the rival flow must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
