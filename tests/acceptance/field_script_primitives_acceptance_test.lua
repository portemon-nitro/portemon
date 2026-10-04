-- Elm's generated healing choice exercises the real blocking 436/150
-- lifecycle sequence through the production field-script composition.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:61", "message-bank:543" },
    tags = { "field", "script-primitives", "elm" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local ELM_HEAL_SCRIPT = "vanilla.hgss.scr_seq.0843.script_013"
local FLAG_GOT_STARTER = FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local worldState = FieldEventState.new()
      worldState:setFlag(FLAG_GOT_STARTER)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        playTime = PlayTime.new(),
        worldState = worldState,
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
end

function T.tests.elm_healing_choice_runs_the_blocking_overworld_lifecycle()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:startScript(ELM_HEAL_SCRIPT)

    local ended = false
    local sawHealingChoice = false
    for _ = 1, 180 do
      if game.runtime.errorText ~= nil then
        break
      end
      for _, record in ipairs(game:recordsNamed("script.ended")) do
        if record.payload.scriptId == ELM_HEAL_SCRIPT then
          ended = true
        end
      end
      if ended then
        break
      end
      if game:contextChoiceStatus() ~= nil then
        sawHealingChoice = true
        game:pressAction()
      elseif game:snapshot().dialogue.modal then
        game:pressAction()
      else
        game:step()
      end
    end

    Assert.isNil(game.runtime.errorText, "Elm's generated healing path must not reach an unsupported command")
    local completion = nil
    for _, record in ipairs(game:recordsNamed("script.ended")) do
      if record.payload.scriptId == ELM_HEAL_SCRIPT then
        completion = record.payload
      end
    end
    Assert.notNil(completion, "the generated healing path must reach its source end")
    Assert.isTrue(sawHealingChoice, "the generated healing path must reach its production choice before lifecycle")
    local completedScript = assert(completion)
    if completedScript.completed ~= true then
      Assert.equal(
        completedScript.reason,
        "SCRIPT_UNSUPPORTED_REACHABLE",
        "an incomplete healing path must identify the missing source lifecycle command"
      )
    end
    Assert.isTrue(
      completedScript.completed == true,
      "leave/restore must block until the source script can continue; reason=" .. tostring(completedScript.reason)
    )
    local settled = game:advanceUntil("Elm's lab returns to an idle field", function()
      return game:snapshot().transition.phase == "idle" and not game:snapshot().fieldLocked
    end, 120)
    Assert.equal(settled.mapSymbol, MAP, "lifecycle restoration keeps the active lab map")
    Assert.equal(settled.transition.phase, "idle", "the source fades settle around the lifecycle sequence")
    Assert.equal(game:renderAttempts(), 0, "field-script acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
