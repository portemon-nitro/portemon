-- Production-composed field Yes/No flow: the real script task, dialogue host,
-- message provider, and field runtime remain the owners of the journey.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:7" },
    tags = { "field", "dialogue", "yes-no", "acceptance" },
  },
  tests = {},
}

local VAR_FIRST_RESULT = FieldScriptSymbols.variablesByName.VAR_UNK_407C
local VAR_SECOND_RESULT = FieldScriptSymbols.variablesByName.VAR_UNK_407D
local VAR_THIRD_RESULT = FieldScriptSymbols.variablesByName.VAR_UNK_407F

local function singleDisplay(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function withGame(topology, fn)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map, fieldX = 10, fieldZ = 10, facing = "south" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
          options = { textSpeed = "fastest", textFrame = 1 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      acceptanceScripts = AcceptanceScripts,
      screenTopology = topology,
    },
  })
  local ok, err = xpcall(function()
    fn(game)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function pressDirection(game, direction)
  game.runtime:press(direction, "acceptance")
  game:step()
  game.runtime:release(direction, "acceptance")
end

local function pressAction(game)
  game.runtime:pressAction("acceptance")
  local snapshot = game:step()
  game.runtime:releaseAction("acceptance")
  return snapshot
end

local function pressCancel(game)
  game.runtime:pressCancel("acceptance")
  local snapshot = game:step()
  game.runtime:releaseCancel("acceptance")
  return snapshot
end

-- Resolves the host pixel center of a Yes/No row through the live
-- presentation host: the same resolved geometry the field draws and the
-- fixed-tick pointer mapping consumes. The row rectangles are the two 16px
-- rows of the drawn content box.
local function yesNoRowCenter(game, row)
  local runtime = game.runtime
  local host = assert(runtime.yesNoHost, "the field owns a live Yes/No host while choosing")
  local presentation = host:presentation()
  Assert.isTrue(presentation ~= nil, "a Yes/No choice must be open to resolve its rows")
  local layout = assert(presentation).layout
  local content = assert(layout.content, "Yes/No layout must publish its content box")
  local hostX, hostY = LayoutGeometry.logicalToHost(
    assert(layout.placement, "Yes/No layout must publish its placement"),
    content.x + content.width / 2,
    content.y + row * 16 + 8
  )
  return hostX, hostY
end

-- A field script reaches the production Yes/No owner and writes source-shaped
-- values through the scheduler. The selected frame and ordinary dialogue
-- remain live until the script's explicit close_message operation.
function T.tests.field_script_yes_no_is_interactive_and_preserves_dialogue()
  local function exercise(game)
    game:waitForFieldEntry()
    game:startScript("acceptance.field_yes_no")
    local opened = game:advanceUntil("field Yes/No choice opens", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 480)
    Assert.equal(opened.dialogue.frameIndex, 1, "the choice must inherit the selected dialogue frame")

    pressAction(game)
    game:advanceUntil("second field Yes/No choice opens", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 120)
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT), 0, "Yes writes source value 0")
    pressDirection(game, "south")
    local afterConfirm = pressAction(game)
    Assert.isTrue(afterConfirm.dialogue.modal, "answering must not close the ordinary dialogue")

    game:advanceUntil("third field Yes/No choice opens", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 120)
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_SECOND_RESULT), 1, "No writes source value 1")
    pressCancel(game)
    game:advanceUntil("field question script closes its dialogue", function(snapshot)
      return snapshot.foregroundScript == nil and not snapshot.dialogue.modal
    end, 120)
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_THIRD_RESULT), 1, "B writes source value 1")
  end

  withGame(singleDisplay(640, 480), exercise)
  withGame(singleDisplay(360, 640), exercise)
end

-- Pointer gestures answer a field Yes/No through the fixed-tick modal lane.
-- A same-row press/release writes the source result while drags and outside
-- releases answer nothing, leave ordinary dialogue open, and never move
-- the player with the consumed edge.
function T.tests.pointer_gestures_answer_field_yes_no_without_moving_the_world()
  withGame(singleDisplay(640, 480), function(game)
    game:waitForFieldEntry()
    game:startScript("acceptance.field_yes_no")
    game:advanceUntil("field Yes/No choice opens for pointer input", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 480)

    local before = game:snapshot().player

    local noX, noY = yesNoRowCenter(game, 1)
    game.runtime.input:pointerDown("acceptance:yes-no-no", noX, noY)
    game:step()
    game.runtime.input:pointerUp("acceptance:yes-no-no", noX, noY)
    game:advanceUntil("pointer No writes its source result", function()
      return game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT) == 1
    end, 120)
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT), 1, "pointer No writes source value 1")
    Assert.isTrue(game:snapshot().dialogue.modal, "answering by pointer keeps ordinary dialogue open")
    local afterNo = game:snapshot().player
    Assert.equal(afterNo.fieldX, before.fieldX, "a pointer choice must not step the player")
    Assert.equal(afterNo.fieldZ, before.fieldZ, "a pointer choice must not step the player")

    game:advanceUntil("second field Yes/No choice opens for pointer input", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 120)
    local yesX, yesY = yesNoRowCenter(game, 0)
    game.runtime.input:pointerDown("acceptance:yes-no-yes", yesX, yesY)
    game:step()
    game.runtime.input:pointerUp("acceptance:yes-no-yes", yesX, yesY)
    game:advanceUntil("pointer Yes writes its source result", function()
      return game.runtime.scripts.worldState:getVar(VAR_SECOND_RESULT) == 0
    end, 120)
    Assert.isTrue(game:snapshot().dialogue.modal, "answering Yes by pointer keeps ordinary dialogue open")
    local afterYes = game:snapshot().player
    Assert.equal(afterYes.fieldX, before.fieldX, "a pointer choice must not step the player")
    Assert.equal(afterYes.fieldZ, before.fieldZ, "a pointer choice must not step the player")

    game:advanceUntil("third field Yes/No choice opens for negative gestures", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 120)
    local thirdBefore = game.runtime.scripts.worldState:getVar(VAR_THIRD_RESULT)
    local dragX, dragY = yesNoRowCenter(game, 0)
    game.runtime.input:pointerDown("acceptance:yes-no-drag", dragX, dragY)
    game:step()
    game.runtime.input:pointerMove("acceptance:yes-no-drag", dragX + 160, dragY + 160)
    game:step()
    game.runtime.input:pointerUp("acceptance:yes-no-drag", dragX + 160, dragY + 160)
    game:step()
    game:step()
    Assert.isTrue(
      game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil,
      "a dragged gesture must not answer the choice"
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(VAR_THIRD_RESULT),
      thirdBefore,
      "a dragged gesture writes no source result"
    )

    game.runtime.input:pointerDown("acceptance:yes-no-outside", 4, 4)
    game:step()
    game.runtime.input:pointerUp("acceptance:yes-no-outside", 8, 8)
    game:step()
    game:step()
    Assert.isTrue(
      game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil,
      "an outside gesture must not answer the choice"
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(VAR_THIRD_RESULT),
      thirdBefore,
      "an outside gesture writes no source result"
    )
    Assert.isTrue(game:snapshot().dialogue.modal, "negative gestures keep ordinary dialogue open")

    pressAction(game)
    game:advanceUntil("keyboard answer still completes the dragged choice", function()
      return game.runtime.scripts.worldState:getVar(VAR_THIRD_RESULT) == 0
    end, 120)
    Assert.isTrue(game:snapshot().dialogue.modal, "answering leaves the ordinary message open for its script owner")
  end)
end

-- Resolves the contextual row center through the shared runtime presentation
-- record: the same status draw consumes, mapped through the same host
-- geometry the fixed-tick pointer translation consumes.
local function contextRowCenter(game, row)
  local runtime = game.runtime
  local status = assert(
    runtime:contextChoicePresentation(),
    "a contextual choice must be open to resolve its rows"
  )
  local host = assert(runtime.yesNoHost, "the field owns the shared choice host")
  local layout = host:layoutFor(status)
  local content = assert(layout.content, "contextual layout must publish its content box")
  local hostX, hostY = LayoutGeometry.logicalToHost(
    assert(layout.placement, "contextual layout must publish its placement"),
    content.x + content.width / 2,
    content.y + row * 16 + 8
  )
  return hostX, hostY
end

local function waitForContextChoice(game, label)
  game:advanceUntil(label, function()
    return game.runtime.contextChoiceProvider:isActive()
  end, 480)
end

-- Pointer taps answer a contextual two-choice prompt through the shared
-- Yes/No geometry: a same-row press/release writes the source result, closes
-- the choice, and never steps the player with the consumed edge.
function T.tests.pointer_taps_answer_contextual_choice_without_moving_the_world()
  local function exercise(game)
    game:waitForFieldEntry()
    game:startScript("acceptance.field_context_choice")
    waitForContextChoice(game, "contextual choice opens for pointer input")

    local before = game:snapshot().player
    local noX, noY = contextRowCenter(game, 1)
    game.runtime.input:pointerDown("acceptance:context-no", noX, noY)
    game:step()
    game.runtime.input:pointerUp("acceptance:context-no", noX, noY)
    game:advanceUntil("pointer No answers the contextual choice", function()
      return game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT) == 1
    end, 120)
    Assert.isFalse(
      game.runtime.contextChoiceProvider:isActive(),
      "answering closes the contextual choice"
    )
    local afterNo = game:snapshot().player
    Assert.equal(afterNo.fieldX, before.fieldX, "a contextual tap must not step the player")
    Assert.equal(afterNo.fieldZ, before.fieldZ, "a contextual tap must not step the player")

    waitForContextChoice(game, "second contextual choice opens for pointer input")
    local yesX, yesY = contextRowCenter(game, 0)
    game.runtime.input:pointerDown("acceptance:context-yes", yesX, yesY)
    game:step()
    game.runtime.input:pointerUp("acceptance:context-yes", yesX, yesY)
    game:advanceUntil("pointer Yes answers the contextual choice", function()
      return game.runtime.scripts.worldState:getVar(VAR_SECOND_RESULT) == 0
    end, 120)
    local afterYes = game:snapshot().player
    Assert.equal(afterYes.fieldX, before.fieldX, "a contextual tap must not step the player")
    Assert.equal(afterYes.fieldZ, before.fieldZ, "a contextual tap must not step the player")
  end

  withGame(singleDisplay(640, 480), exercise)
  withGame(singleDisplay(360, 640), exercise)
end

-- Invalid contextual gestures confirm nothing and leak nothing to the world:
-- cross-row and outside releases, drags, and a resize between press and
-- release all leave the choice open, and a later valid tap still answers.
function T.tests.invalid_contextual_gestures_answer_nothing_without_leaking()
  withGame(singleDisplay(640, 480), function(game)
    game:waitForFieldEntry()
    game:startScript("acceptance.field_context_choice")
    waitForContextChoice(game, "contextual choice opens for negative gestures")

    local before = game:snapshot().player
    local thirdBefore = game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT)
    local yesX, yesY = contextRowCenter(game, 0)
    local noX, noY = contextRowCenter(game, 1)

    game.runtime.input:pointerDown("acceptance:context-cross", yesX, yesY)
    game:step()
    game.runtime.input:pointerUp("acceptance:context-cross", noX, noY)
    game:step()
    game:step()
    Assert.isTrue(
      game.runtime.contextChoiceProvider:isActive(),
      "a cross-row release must not answer the choice"
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT),
      thirdBefore,
      "a cross-row release writes no source result"
    )

    game.runtime.input:pointerDown("acceptance:context-drag", yesX, yesY)
    game:step()
    game.runtime.input:pointerMove("acceptance:context-drag", yesX + 160, yesY + 160)
    game:step()
    game.runtime.input:pointerUp("acceptance:context-drag", yesX + 160, yesY + 160)
    game:step()
    game:step()
    Assert.isTrue(
      game.runtime.contextChoiceProvider:isActive(),
      "a dragged gesture must not answer the choice"
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT),
      thirdBefore,
      "a dragged gesture writes no source result"
    )

    game.runtime.input:pointerDown("acceptance:context-outside", 4, 4)
    game:step()
    game.runtime.input:pointerUp("acceptance:context-outside", 8, 8)
    game:step()
    game:step()
    Assert.isTrue(
      game.runtime.contextChoiceProvider:isActive(),
      "an outside gesture must not answer the choice"
    )

    game.runtime.input:pointerDown("acceptance:context-resize", yesX, yesY)
    game:step()
    game.runtime.yesNoHost:resize(640, 480)
    game:step()
    game.runtime.input:pointerUp("acceptance:context-resize", yesX, yesY)
    game:step()
    game:step()
    Assert.isTrue(
      game.runtime.contextChoiceProvider:isActive(),
      "a resize between press and release invalidates the gesture"
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT),
      thirdBefore,
      "an invalidated gesture writes no source result"
    )

    local still = game:snapshot().player
    Assert.equal(still.fieldX, before.fieldX, "negative gestures must not step the player")
    Assert.equal(still.fieldZ, before.fieldZ, "negative gestures must not step the player")

    local tapX, tapY = contextRowCenter(game, 0)
    game.runtime.input:pointerDown("acceptance:context-valid", tapX, tapY)
    game:step()
    game.runtime.input:pointerUp("acceptance:context-valid", tapX, tapY)
    game:advanceUntil("a later valid tap answers the choice", function()
      return game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT) == 0
    end, 120)
  end)
end

function T.tests.cancelling_active_field_yes_no_releases_only_the_choice()
  withGame(singleDisplay(640, 480), function(game)
    game:waitForFieldEntry()
    game:startScript("acceptance.field_yes_no_cancel")
    game:advanceUntil("field Yes/No choice opens for cancellation", function(snapshot)
      return snapshot.dialogue.modal and game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 480)

    local dialogueHost = game.runtime.scripts.dialogueHost
    Assert.isTrue(game:snapshot().dialogue.modal, "ordinary dialogue is open before cancellation")
    local scheduler = game.runtime.scripts.scheduler
    local environmentId = assert(scheduler:foregroundEnvironmentId(), "the choice script owns the foreground")
    scheduler:cancelEnvironment(environmentId, "acceptance choice cleanup")

    Assert.isNil(dialogueHost:yesNoPresentation(), "cancelling the task removes the choice surface")
    Assert.isTrue(game:snapshot().dialogue.modal, "cancelling the task leaves ordinary dialogue open")
    scheduler:cancelEnvironment(environmentId, "repeat cleanup")
    Assert.isNil(dialogueHost:yesNoPresentation(), "repeated cleanup keeps the choice closed")
    Assert.isTrue(game:snapshot().dialogue.modal, "repeated cleanup still preserves ordinary dialogue")
  end)
end

function T.tests.message_bearing_field_yes_no_prints_before_opening_choice()
  withGame(singleDisplay(640, 480), function(game)
    game:waitForFieldEntry()
    local dialogueHost = game.runtime.scripts.dialogueHost
    Assert.isFalse(dialogueHost:isOpen(), "the standalone question starts without ordinary dialogue")
    game:startScript("acceptance.field_yes_no_message")

    game:advanceUntil("message-bearing Yes/No reaches its dialogue or choice boundary", function()
      return dialogueHost:isOpen() or dialogueHost:yesNoPresentation() ~= nil
    end, 480)
    Assert.isTrue(dialogueHost:isOpen(), "message-bearing Yes/No opens ordinary dialogue before its choice")
    Assert.isNil(dialogueHost:yesNoPresentation(), "the choice waits for the ordinary message printer")
    Assert.isTrue(game:snapshot().dialogue.modal, "the standalone message is presented as ordinary dialogue")

    game:advanceUntil("message-bearing Yes/No printer completes", function()
      return dialogueHost:printProgress().done
    end, 480)
    Assert.isNil(dialogueHost:yesNoPresentation(), "the choice does not open in the printer completion tick")
    game:advanceUntil("message-bearing Yes/No choice opens after printing", function()
      return dialogueHost:yesNoPresentation() ~= nil
    end, 4)
    Assert.isTrue(dialogueHost:printProgress().done, "the choice opens only after printing completes")

    pressAction(game)
    game:advanceUntil("message-bearing Yes/No answer completes", function()
      return game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT) == 0
    end, 120)
    Assert.isTrue(dialogueHost:isOpen(), "answering leaves the ordinary message open for its script owner")
    Assert.isTrue(game:snapshot().dialogue.modal, "ordinary dialogue remains visible after the choice")
  end)
end

function T.tests.cancelling_message_bearing_field_yes_no_releases_owned_dialogue()
  withGame(singleDisplay(640, 480), function(game)
    game:waitForFieldEntry()
    local dialogueHost = game.runtime.scripts.dialogueHost
    local scheduler = game.runtime.scripts.scheduler

    local function cancelMessageBearingChoice(label, predicate)
      game:startScript("acceptance.field_yes_no_message")
      game:advanceUntil(label, predicate, 480)
      local environmentId =
        assert(scheduler:foregroundEnvironmentId(), "the message-bearing choice script owns the foreground")
      scheduler:cancelEnvironment(environmentId, "acceptance owned dialogue cleanup")

      Assert.isNil(dialogueHost:yesNoPresentation(), "cancelling removes the choice surface")
      Assert.isFalse(dialogueHost:isOpen(), "cancelling closes the task-owned ordinary dialogue")
      Assert.isFalse(game:snapshot().dialogue.modal, "the task-owned dialogue is no longer modal")
    end

    cancelMessageBearingChoice("message-bearing Yes/No starts printing", function()
      return dialogueHost:isOpen() and dialogueHost:yesNoPresentation() == nil
    end)
    cancelMessageBearingChoice("message-bearing Yes/No opens its choice", function()
      return dialogueHost:yesNoPresentation() ~= nil
    end)
  end)
end

return T
