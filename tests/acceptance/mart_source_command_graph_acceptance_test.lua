-- Script mart launches and queries use the production field scheduler and
-- the real ROM-derived catalogs.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local BagSave = require("libs.hgss.src.save.BagSave")
local MartSave = require("libs.hgss.src.save.MartSave")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:7", "mart:global" },
    tags = { "field", "mart", "acceptance" },
  },
  tests = {},
}

local SCRIPT_ID = "acceptance.mart_source_command_graph"
local ATHLETE_AVAILABLE = FieldScriptSymbols.variablesByName.VAR_UNK_407C
local CARD_PREFIX = FieldScriptSymbols.variablesByName.VAR_UNK_407D
local CONTINUATION = FieldScriptSymbols.variablesByName.VAR_UNK_407F

local customScripts = {}
for id, source in pairs(AcceptanceScripts) do
  customScripts[id] = source
end
customScripts[SCRIPT_ID] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "acceptance.mart_source_command_graph",
  steps = {
    S.martQuery({ kind = "athlete_available", result = S.var("VAR_UNK_407C") }),
    S.martQuery({ kind = "card_prefix", result = S.var("VAR_UNK_407D") }),
    S.mart({ kind = "standard" }),
    S.setVar({ variable = "VAR_UNK_407F", value = 7 }),
    S.stop(),
  },
})
]]

local function withGame(fn)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map, fieldX = 4, fieldZ = 10, facing = "south" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = BagSave.empty(),
        mart = MartSave.empty(),
      }
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = { acceptanceScripts = customScripts },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "mart command acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.script_queries_and_standard_mart_share_the_live_field_host()
  withGame(function(game)
    game:waitForFieldEntry()
    game.runtime.scripts.worldState:setFlag(0x09A)
    game:startScript(SCRIPT_ID)
    game:advanceUntil("the standard mart child opens", function()
      return game.runtime.martHost ~= nil and game.runtime.martHost:isActive()
    end, 480)

    local vars = game.runtime.scripts.worldState
    Assert.equal(vars:getVar(ATHLETE_AVAILABLE), 1, "the source athlete query observes seeded Saturday stock")
    Assert.equal(vars:getVar(CARD_PREFIX), 0, "the source card query observes the empty-card save")
    Assert.isTrue(
      vars:getVar(CONTINUATION) ~= 7,
      "the foreground source script waits for the modal child"
    )

    local host = assert(game.runtime.martHost)
    local status = assert(host:status(), "the production mart host exposes the standard child")
    Assert.equal(status.state, "browse")
    Assert.equal(status.martKind, "buy")
    Assert.isTrue(status.entryCount > 0, "the standard launch resolves real catalog stock")
    Assert.equal(status.currentEntry.displayItemKey, "POKE_BALL", "standard stock preserves retail tier ordering")

    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    game:advanceUntil("the standard child closes and the script resumes", function()
      return not host:isActive() and vars:getVar(CONTINUATION) == 7
    end, 240)
  end)
end

return T
