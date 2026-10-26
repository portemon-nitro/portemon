-- Production trainer card journey: unlocking the card enables its Start Menu
-- action, opening it plays through the real field audio stack (the
-- trainer card open sound must resolve in the generated cache or the open
-- raises instead of staying silent), and cancel returns to the menu. Only
-- host boundaries (save root, render trap, audio-output fake) stand in for
-- production; the runtime, controller, and generated assets stay
-- production. No renderer or GPU call may occur.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:7" },
    tags = { "field", "trainer-card" },
  },
  tests = {},
}

local FLAG_GOT_TRAINER_CARD = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD
local TRAINER_CARD_ACTION = "vanilla.trainer_card"
local TRAINER_CARD_APPLICATION = FieldApplicationIds.TRAINER_CARD

local function hostCallbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function hostPhase(game)
  return game.runtime.applicationHost:status().phase
end

local function openStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  return game:advanceUntil("start menu becomes modal", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 120)
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the start menu must own the tick")
  return assert(status.menu, "the menu phase must expose the controller status")
end

local function actionById(status, id)
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.id == id then
      return action
    end
  end
  return nil
end

local function cursorActionId(status)
  local position = assert(status.selectedPosition, "menu status must expose the selected position")
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.position == position then
      return action.id
    end
  end
  error("start menu cursor does not resolve to a visible action", 0)
end

local function navigateTo(game, state, id)
  for _ = 1, #menuStatus(game).actions + 1 do
    if cursorActionId(menuStatus(game)) == id then
      return
    end
    state:keypressed("s")
    game:step()
    state:keyreleased("s")
  end
  error("start menu never focuses the trainer card action", 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function cancel(game)
  game.runtime.input:pressCancel("key:escape")
  game:step()
  game.runtime.input:releaseCancel("key:escape")
end

local function cardView(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(
    status.phase,
    FieldApplicationHost.PHASES.application,
    "the trainer card application must own the tick while open"
  )
  Assert.equal(status.applicationId, TRAINER_CARD_APPLICATION, "the launched application must be the trainer card")
  return assert(status.application, "the trainer card application must expose its status")
end

function T.tests.trainer_card_opens_over_production_audio_and_closes_to_menu()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      audioOutput = FakeAudioOutput.new(),
      recordingScriptHosts = true,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:advanceUntil("field ready for ordinary input", function(snapshot)
      return not snapshot.fieldLocked and not snapshot.dialogue.modal
    end, 480)
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_TRAINER_CARD })

    openStartMenu(game)
    local action = actionById(menuStatus(game), TRAINER_CARD_ACTION)
    Assert.isTrue(
      action ~= nil and action.enabled == true,
      "the unlocked trainer card must enable its start menu action through policy/capability composition"
    )
    navigateTo(game, state, TRAINER_CARD_ACTION)
    -- The open plays the card sound through the production audio stack:
    -- a missing card bank raises here instead of opening silently.
    confirm(game)
    game:advanceUntil("trainer card opens over the retained menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)
    local view = cardView(game)
    Assert.isTrue(view.open == true, "the trainer card must report itself open")
    Assert.equal(type(view.name), "string", "the open card must carry the authoritative profile name")

    cancel(game)
    game:advanceUntil("trainer card closes back to the menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    menuStatus(game)
    Assert.equal(game:renderAttempts(), 0, "the trainer card journey must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
