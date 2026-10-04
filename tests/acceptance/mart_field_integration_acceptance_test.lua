-- A field script opens custom stock through the production mart host, blocks
-- while the player buys, and resumes only after the shop closes.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
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

local SCRIPT_ID = "acceptance.mart_field"
local CONTINUATION = FieldScriptSymbols.variablesByName.VAR_UNK_407C

local customScripts = {}
for id, source in pairs(AcceptanceScripts) do
  customScripts[id] = source
end
customScripts[SCRIPT_ID] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "acceptance.mart_field",
  steps = {
    S.mart({
      kind = "custom",
      stock = {
        key = "acceptance-potion-stock",
        currency = "money",
        presentationKind = "items",
        quantityMode = "multiple",
        bonusPolicy = "none",
        entries = {
          {
            key = "potion",
            displayItemKey = "POTION",
            description = { kind = "item" },
            unitPrice = 25,
            destination = { kind = "bag", key = "POTION" },
          },
        },
      },
    }),
    S.setVar({ variable = "VAR_UNK_407C", value = 7 }),
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
    Assert.equal(game:renderAttempts(), 0, "mart field acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function childStatus(game)
  local host = assert(game.runtime.martHost, "field composition must own the script mart host")
  Assert.isTrue(host:isActive(), "the script operation keeps its mart child active")
  return assert(host:status(), "the active mart host exposes its child status")
end

local function pressMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

local function acknowledgeMartPrinter(game, label, printerState, targetState, maxEdges)
  for _ = 1, maxEdges do
    local state = childStatus(game).state
    if state == targetState then
      return
    end
    Assert.equal(state, printerState, label .. " only consumes " .. printerState .. " (current=" .. state .. ")")
    game:pressAction()
  end
  Assert.equal(childStatus(game).state, targetState, label .. " reaches its target state")
end

function T.tests.field_script_blocks_on_custom_mart_until_purchase_and_close()
  withGame(function(game)
    game:waitForFieldEntry()
    game:startScript(SCRIPT_ID)
    game:advanceUntil("the custom mart child opens", function()
      return game.runtime.martHost ~= nil and game.runtime.martHost:isActive()
    end, 480)

    Assert.isTrue(
      game.runtime.scripts.worldState:getVar(CONTINUATION) ~= 7,
      "the script continuation remains blocked while the mart owns the field"
    )
    local captured, reason = game.runtime:captureGameSave()
    Assert.isNil(captured, "an active purchase child must prohibit save capture")
    Assert.notNil(reason, "save denial explains that the field operation is active")

    local initial = childStatus(game)
    Assert.equal(initial.state, "browse", "the custom entry is presented in the real child")
    Assert.equal(initial.entryCount, 1, "the inline stock supplies one authoritative entry")
    Assert.equal(initial.currentEntry.displayItemKey, "POTION", "the custom item reaches the visible stock")
    Assert.equal(initial.currentEntry.unitPrice, 25, "the custom price reaches the visible stock")

    -- Menu edges and field movement are consumed while the child owns the
    -- fixed tick; they must not leave a queued Start Menu or move the player.
    local before = game:snapshot().player
    game:move("north")
    pressMenu(game)
    Assert.isTrue(game.runtime.martHost:isActive(), "field input does not close the mart child")
    Assert.equal(game:snapshot().player.fieldX, before.fieldX, "modal input does not move the field player")
    Assert.equal(game:snapshot().player.fieldZ, before.fieldZ, "modal input does not move the field player")
    Assert.isFalse(game.runtime.applicationHost:isActive(), "modal menu input does not open Start Menu")

    game:move("south")
    Assert.equal(childStatus(game).selection, 0, "restoring the cursor reaches the only custom stock entry")
    game:pressAction()
    game:advanceUntil("the quantity prompt finishes printing", function()
      return childStatus(game).state == "quantity_prompt"
    end, 240)
    for _ = 1, 120 do
      local state = childStatus(game).state
      if state == "quantity" then
        break
      end
      Assert.equal(state, "quantity_prompt", "only the quantity prompt consumes these acknowledgements")
      game:pressAction()
    end
    Assert.equal(childStatus(game).state, "quantity", "the selected item enters quantity choice")
    game:pressAction()
    acknowledgeMartPrinter(game, "the purchase confirmation opens", "confirm_prompt", "confirm", 120)
    game:pressAction()
    game:advanceUntil("the confirmation choice settles", function()
      return childStatus(game).state == "success_print"
    end, 120)
    acknowledgeMartPrinter(game, "the purchase result finishes printing and commits", "success_print", "success_ack", 480)
    Assert.equal(game.runtime.playerData.profile.money, 2975, "the custom transaction charges its declared price")
    Assert.equal(game.runtime.bagService:quantity("POTION"), 1, "the confirmed transaction grants one Potion")

    game:pressAction()
    game:advanceUntil("the acknowledged purchase returns to browsing", function()
      return childStatus(game).state == "browse"
    end, 120)
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    game:advanceUntil("the shop closes and the field script resumes", function()
      return not game.runtime.martHost:isActive()
        and game.runtime.scripts.worldState:getVar(CONTINUATION) == 7
        and game:snapshot().foregroundScript == nil
    end, 240)

    Assert.equal(game.runtime.playerData.profile.money, 2975, "closing the child does not replay the transaction")
    Assert.equal(game.runtime.bagService:quantity("POTION"), 1, "closing the child does not replay the grant")
    Assert.notNil(game.runtime:captureGameSave(), "save capture resumes after the child closes")

    pressMenu(game)
    Assert.equal(
      game.runtime.applicationHost:status().phase,
      FieldApplicationHost.PHASES.menu,
      "ordinary field Start Menu input works after the script-owned child closes"
    )
  end)
end

return T
