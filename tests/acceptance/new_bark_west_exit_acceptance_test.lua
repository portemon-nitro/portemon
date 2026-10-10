-- Production-composed New Bark west-exit scene: Elm leaves the lab through its
-- outdoor door prop, stops the player, and the prop slot is released so the
-- scene can run again after crossing the border.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:60" },
    tags = { "field", "script", "elm", "outdoor" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK"

local function harness()
  local base = AcceptanceHarness.new()
  local defaultFactory = base.gameFactory
  base.gameFactory = function(versionId, map)
    local game = defaultFactory(versionId, map)
    game.location = { mapSymbol = MAP, fieldX = 5, fieldZ = 15, facing = "west" }
    game.worldState = FieldEventState.new({
      flags = { [FieldScriptSymbols.flagsByName.FLAG_GOT_POKEGEAR] = true },
    })
    return game
  end
  return base
end

local DOOR_SLOT = 77

-- Elm's door opens, he walks out, and the door closes: the open and close
-- waits resolve against the lab door prop, and the slot is released so the
-- scene can run again on the same map.
function T.tests.west_exit_scene_plays_elm_door_and_releases_slot()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    local slots = game.runtime.propAnimations.slots
    local loaded = false
    local released = false
    game:moveTo({ fieldX = 676, fieldZ = 399 })
    for _ = 1, 3000 do
      loaded = loaded or slots[DOOR_SLOT] ~= nil
      if loaded and slots[DOOR_SLOT] == nil then
        released = true
        break
      end
      if game:snapshot().dialogue.modal then
        game.runtime:pressAction()
        game:step()
        game.runtime:releaseAction()
      end
      game:step()
    end
    Assert.isTrue(loaded, "the scene loads the lab door slot")
    Assert.isTrue(released, "the scene releases the lab door slot after the door closes")
    for _, record in ipairs(game:recordsNamed("script.error")) do
      Assert.isFalse(
        record.payload.message:find("PC terminal", 1, true) ~= nil,
        "a map prop wait must not poll the PC terminal"
      )
    end
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
