-- A committed script-mart purchase uses the ordinary field save store and
-- remains canonical after a persisted record is loaded into a new runtime.

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
    derivedAssets = { "field-runtime", "map:7", "map:60", "mart:global" },
    tags = { "field", "mart", "save", "acceptance" },
  },
  tests = {},
}

local SCRIPT_ID = "acceptance.mart_save_roundtrip"
local CONTINUATION = FieldScriptSymbols.variablesByName.VAR_UNK_407C
local SAVE_UNLOCK = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON

local customScripts = {}
for id, source in pairs(AcceptanceScripts) do
  customScripts[id] = source
end
customScripts[SCRIPT_ID] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "acceptance.mart_save_roundtrip",
  steps = {
    S.mart({
      kind = "custom",
      stock = {
        key = "acceptance-save-stock",
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
      local worldState = FieldEventState.new()
      worldState:setFlag(SAVE_UNLOCK)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map, fieldX = 4, fieldZ = 10, facing = "south" },
        playerData = {
          profile = {
            name = "GOLD",
            gender = 0,
            trainerId = 1,
            money = 3000,
            badges = 0,
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
          },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = worldState,
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
    Assert.equal(game:renderAttempts(), 0, "mart persistence acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function childStatus(game)
  local host = assert(game.runtime.martHost)
  Assert.isTrue(host:isActive(), "the task-owned child remains active")
  return assert(host:status())
end

local function acknowledgePrinter(game, from, to, maximum)
  if from == "confirm_prompt" and childStatus(game).state == "quantity" then
    game:advanceUntil("quantity control feedback releases", function()
      return childStatus(game).state ~= "quantity"
    end, 20)
  end
  for _ = 1, maximum do
    local state = childStatus(game).state
    if state == to then
      return
    end
    Assert.equal(state, from, "only the active mart printer consumes this acknowledgement")
    game:pressAction()
  end
  Assert.equal(childStatus(game).state, to, "the mart printer reaches its next state")
end

local function buyPotion(game)
  game:pressAction()
  game:advanceUntil("the quantity prompt finishes printing", function()
    return childStatus(game).state == "quantity_prompt"
  end, 240)
  for _ = 1, 120 do
    local state = childStatus(game).state
    if state == "quantity" then
      break
    end
    Assert.equal(state, "quantity_prompt", "quantity input waits for its prompt")
    game:pressAction()
  end
  Assert.equal(childStatus(game).state, "quantity", "the selected Potion enters quantity choice")
  game:pressAction()
  acknowledgePrinter(game, "confirm_prompt", "confirm", 120)
  game:pressAction()
  game:advanceUntil("the purchase commits", function()
    return childStatus(game).state == "success_print"
  end, 120)
  acknowledgePrinter(game, "success_print", "success_ack", 480)
end

local function saveThroughFieldMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  local host = game.runtime.applicationHost
  local status = assert(host:status().menu, "the unlocked Start Menu is active")
  local savePosition
  for _, action in ipairs(status.actions) do
    if action.id == "vanilla.save" then
      Assert.isTrue(action.enabled, "the seeded save action is enabled")
      savePosition = action.position
    end
  end
  savePosition = assert(savePosition, "the production menu includes Save")
  for _ = 1, 24 do
    status = assert(host:status().menu)
    if status.selectedPosition == savePosition then
      break
    end
    game:move("south")
  end
  Assert.equal(assert(host:status().menu).selectedPosition, savePosition, "semantic menu navigation selects Save")
  game:pressAction()
  Assert.equal(host:phase(), "closed", "the save action returns to the field")
  Assert.isTrue(game.lifecycle.saveWrites > 0, "the normal field action publishes through the save store")
end

local function loadStoredRuntime(game)
  local saveId = game.runtime.saveId
  local persisted = assert(game.runtime.saveStore:load(saveId), "the actual save store reloads the published record")
  game:_disposeRuntime()
  local runtime = game.harness:_newRuntime(
    persisted,
    game.saveNamespace,
    game.faults,
    game.lifecycle,
    game.fieldOptions,
    false
  )
  game.runtime = runtime
  game.hosts = runtime.scriptHosts or {}
  game.runtimeDisposed = false
  game.disposeErr = nil
  game.saveStatus = runtime.saveStatus
end

local function savedQuantity(record, itemKey)
  for _, pocket in pairs(record.bag.pockets) do
    for _, slot in ipairs(pocket) do
      if slot.item == itemKey then
        return slot.quantity
      end
    end
  end
  return 0
end

function T.tests.committed_purchase_survives_field_store_and_runtime_reload()
  withGame(function(game)
    game:waitForFieldEntry()
    game:startScript(SCRIPT_ID)
    game:advanceUntil("the custom mart child opens", function()
      return game.runtime.martHost:isActive()
    end, 480)
    Assert.isNil(game.runtime:captureGameSave(), "an active browse child prohibits save capture")

    buyPotion(game)
    Assert.equal(game.runtime.playerData.profile.money, 2975, "the committed purchase charges its canonical profile")
    Assert.equal(game.runtime.bagService:quantity("POTION"), 1, "the committed purchase grants its canonical Bag item")
    Assert.equal(childStatus(game).state, "success_ack", "the terminal purchase acknowledgement is still modal")
    Assert.isNil(game.runtime:captureGameSave(), "a committed but unacknowledged child still prohibits capture")

    game:pressAction()
    game:advanceUntil("the purchase acknowledgement returns to browsing", function()
      return childStatus(game).state == "browse"
    end, 120)
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    game:advanceUntil("the child returns field ownership", function()
      return not game.runtime.martHost:isActive()
    end, 240)
    Assert.notNil(game.runtime:captureGameSave(), "field capture resumes after the modal child closes")

    saveThroughFieldMenu(game)
    local saveId = game.runtime.saveId
    local saved = assert(game.runtime.saveStore:load(saveId), "the published save payload loads from storage")
    Assert.equal(saved.playerData.profile.money, 2975, "the stored record carries the purchase debit")
    Assert.equal(savedQuantity(saved, "POTION"), 1, "the stored record carries the granted item")

    loadStoredRuntime(game)
    game:waitForFieldEntry()
    Assert.equal(game.runtime.playerData.profile.money, 2975, "a fresh runtime restores the saved wallet")
    Assert.equal(game.runtime.bagService:quantity("POTION"), 1, "a fresh runtime restores the saved purchase")
    Assert.isFalse(game.runtime.martHost:isActive(), "modal child state is not restored from save data")
    Assert.isTrue(game.lifecycle.saveReads > 0, "the isolated store backend served the reload")
  end)
end

return T
