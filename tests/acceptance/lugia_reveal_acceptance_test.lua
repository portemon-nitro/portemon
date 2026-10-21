-- The Whirl Islands coordinate event must run the generated Lugia reveal
-- script through the production field and script composition without reaching
-- an unsupported command before its closing message.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:244", "map:244" },
    tags = { "field", "script", "lugia" },
  },
  tests = {},
}

local MAP = "MAP_WHIRL_ISLANDS_B3F_LUGIA_CAVE"
local SCRIPT = "vanilla.hgss.scr_seq.0104.script_005"
local LUGIA_TRIGGER_VAR = FieldScriptSymbols.variablesByName.VAR_UNK_40FA
local LUGIA_REVEALED_FLAG = FieldScriptSymbols.flagsByName.FLAG_UNK_10B

function T.tests.whirl_islands_coordinate_runs_lugia_reveal_without_script_fault()
  local baseGameFactory = AcceptanceHarness.new().gameFactory
  local function gameFactory(versionId, map)
    local game = baseGameFactory(versionId, map)
    game.location.fieldX = 16
    game.location.fieldZ = 37
    game.location.facing = "north"
    return game
  end
  local harness = AcceptanceHarness.new({
    gameFactory = gameFactory,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    -- The legend object starts hidden by its event flag until the script shows it.
    game:setActorRemovalFlag("map:244:object:5")
    game:setWorldState({ variable = LUGIA_TRIGGER_VAR, value = 1 })
    game:move("north")

    local boundary = game:advanceUntil("Lugia opening message or script fault", function(snapshot)
      return snapshot.dialogue.modal or #game:recordsForScript(SCRIPT, "script.error") > 0
    end, 240)
    local faults = game:recordsForScript(SCRIPT, "script.error")
    Assert.equal(
      #faults,
      0,
      "the Whirl Islands Lugia script must run its opening commands without faulting; got "
        .. (faults[1] and faults[1].payload.code or "no record")
    )
    Assert.notNil(boundary, "the coordinate event must reach the Lugia opening message")
    Assert.isTrue(boundary.dialogue.modal, "the Kimono Girls' opening message must be active")
    Assert.equal(#game:recordsForScript(SCRIPT, "script.started"), 1, "the map trigger starts Lugia script 005")
    game:pressAction()
    local completed
    local cinematicShots = {}
    local eyeGlimmerSeen = false
    local legendFirstY, legendLastY, legendFlapped
    local stopBlockerShown = false
    local legendActorId = "map:244:object:5"
    for _ = 1, 9000 do
      for _, record in ipairs(game.runtime.actors:drawRecords()) do
        if record.actorId == legendActorId and record.visible then
          legendFirstY = legendFirstY or record.world.y
          legendLastY = record.world.y
          legendFlapped = legendFlapped or record.gesturePose == "legend_flap"
        end
      end
      local lugiaScene = game.runtime.hoOhAppearanceScene
      local lugiaStatus = lugiaScene and lugiaScene:status() or nil
      if lugiaStatus and lugiaStatus.cinematicShot then
        cinematicShots[lugiaStatus.cinematicShot] = true
      end
      if lugiaScene and legendLastY ~= nil and legendFirstY ~= legendLastY and cinematicShots.lugia then
        stopBlockerShown = false
        for index = 6, 10 do
          for _, record in ipairs(game.runtime.actors:drawRecords()) do
            if record.actorId == "map:244:object:" .. index and record.visible then
              stopBlockerShown = true
            end
          end
        end
      end
      eyeGlimmerSeen = eyeGlimmerSeen or (lugiaStatus and lugiaStatus.eyeGlimmerFrame ~= nil)
      local snapshot = game:snapshot()
      if snapshot.dialogue.modal then
        game:pressAction()
      end
      if
        game.runtime.scripts.worldState:getVar(LUGIA_TRIGGER_VAR) == 2
        or #game:recordsForScript(SCRIPT, "script.error") > 0
      then
        completed = snapshot
        break
      end
      game:step()
    end
    local taskTypes = {}
    for _, task in ipairs(game.runtime.scripts.scheduler:tasks()) do
      taskTypes[#taskTypes + 1] = task.taskType .. ":" .. task.status
    end
    Assert.notNil(
      completed,
      "the Lugia reveal must complete its dance, cinematic, and dialogue; tasks=" .. table.concat(taskTypes, ",")
    )
    Assert.equal(#game:recordsForScript(SCRIPT, "script.error"), 0, "the full Lugia reveal script must not fault")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(LUGIA_TRIGGER_VAR),
      2,
      "the event marks the appearance complete"
    )
    Assert.isTrue(cinematicShots.lugia == true, "the production event presents the Lugia cinematic shot")
    Assert.isTrue(eyeGlimmerSeen, "the production event presents the eye-glimmer effect")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(LUGIA_REVEALED_FLAG),
      "the event sets the post-appearance story flag"
    )
    Assert.notNil(legendFirstY, "the legend object is drawn during the approach")
    Assert.isTrue(
      legendFirstY >= legendLastY + 7,
      "the legend object first appears at its descent height, never lowered (first " .. legendFirstY .. ", landed " .. legendLastY .. ")"
    )
    Assert.isFalse(stopBlockerShown, "the map's resume script hides the STOP blockers once the cinematic exits")
    Assert.isTrue(legendFlapped == true, "the legend object plays its flap sequence")
    Assert.equal(game:renderAttempts(), 0, "the cutscene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
