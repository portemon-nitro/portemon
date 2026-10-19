-- The Bell Tower coordinate event must run the generated Ho-Oh appearance
-- script through the production field and script composition without reaching
-- an unsupported command before its opening message.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:340", "map:340" },
    tags = { "field", "script", "ho-oh" },
  },
  tests = {},
}

local MAP = "MAP_BELL_TOWER_ROOF"
local SCRIPT = "vanilla.hgss.scr_seq.0021.script_006"
local HO_OH_TRIGGER_VAR = FieldScriptSymbols.variablesByName.VAR_UNK_40FA
local HO_OH_APPEARANCE_FLAG = FieldScriptSymbols.flagsByName.FLAG_UNK_10A

function T.tests.bell_tower_coordinate_runs_ho_oh_opening_without_script_fault()
  local baseGameFactory = AcceptanceHarness.new().gameFactory
  local function gameFactory(versionId, map)
    local game = baseGameFactory(versionId, map)
    game.location.fieldX = 15
    game.location.fieldZ = 21
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
    game:setWorldState({ variable = HO_OH_TRIGGER_VAR, value = 1 })
    game:move("north")

    local boundary = game:advanceUntil("Ho-Oh opening message or script fault", function(snapshot)
      return snapshot.dialogue.modal or #game:recordsForScript(SCRIPT, "script.error") > 0
    end, 240)
    local faults = game:recordsForScript(SCRIPT, "script.error")
    Assert.equal(
      #faults,
      0,
      "the Bell Tower Ho-Oh script must run its opening commands without faulting; got "
        .. (faults[1] and faults[1].payload.code or "no record")
    )
    Assert.notNil(boundary, "the coordinate event must reach the Ho-Oh opening message")
    Assert.isTrue(boundary.dialogue.modal, "the Kimono Girls' opening message must be active")
    Assert.equal(#game:recordsForScript(SCRIPT, "script.started"), 1, "the map trigger starts Ho-Oh script 006")
    game:pressAction()
    local completed
    local cinematicShots = {}
    for _ = 1, 4000 do
      local cinematicScene = game.runtime.hoOhAppearanceScene
      local cinematicStatus = cinematicScene and cinematicScene:status() or nil
      if cinematicStatus and cinematicStatus.cinematicShot then
        cinematicShots[cinematicStatus.cinematicShot] = true
      end
      local snapshot = game:snapshot()
      if snapshot.dialogue.modal then
        game:pressAction()
      end
      if
        game.runtime.scripts.worldState:getVar(HO_OH_TRIGGER_VAR) == 2
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
      "the Ho-Oh appearance must complete its dance, cinematic, and dialogue; tasks=" .. table.concat(taskTypes, ",")
    )
    Assert.equal(#game:recordsForScript(SCRIPT, "script.error"), 0, "the full Ho-Oh appearance script must not fault")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(HO_OH_TRIGGER_VAR),
      2,
      "the event marks the appearance complete"
    )
    Assert.isTrue(cinematicShots.first == true, "the production event presents the first Ho-Oh cinematic shot")
    Assert.isTrue(cinematicShots.second == true, "the production event presents the second Ho-Oh cinematic shot")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(HO_OH_APPEARANCE_FLAG),
      "the event sets the post-appearance story flag"
    )
    Assert.equal(game:renderAttempts(), 0, "the cutscene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
