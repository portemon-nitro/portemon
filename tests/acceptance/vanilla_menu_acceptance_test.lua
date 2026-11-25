-- Production-composed field-menu contracts. Real generated HGSS menus run
-- through FieldRuntime: the auxiliary touchscreen list family (a complete
-- selection path and a mid-menu restart) and the source foreground multichoice
-- (its native window, a resumed run, and cancellation).

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldState = require("game.hgss.src.field.FieldState")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:7", "map-data:7", "script-member:4" },
    tags = { "field", "menu", "responsive", "topology", "script" },
  },
  tests = {},
}

-- This compact three-choice vanilla menu is a source-faithful 749--752 flow.
-- Its second value is 1, so selection is observably distinct from both the
-- initial row and the source-message id.
local VANILLA_MENU = "vanilla.hgss.scr_seq.0003.script_056"
local RESULT_VARIABLE = 32780

-- Source foreground multichoice (ScrCmd_MultichoiceInitStdGmm, three
-- ScrCmd_MultichoiceItemAdd, ScrCmd_MultichoiceExec) at native tile (1, 1) with
-- source item values 0, 1, and 2.
local FOREGROUND_MULTICHOICE = "vanilla.hgss.scr_seq.0004.script_011"
local MULTICHOICE_TILE_X = 1
local MULTICHOICE_TILE_Y = 1
local MULTICHOICE_ITEM_COUNT = 3

local function withGame(fieldOptions, fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Acceptance owns the non-rendering runtime, while this thin host adapter
-- invokes the same FieldState callbacks that LÖVE dispatches in production.
-- It deliberately has no synthetic input behavior of its own.
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

local function menuIsModal(snapshot)
  return snapshot.menu ~= nil and snapshot.menu.modal == true
end

-- A committed menu stops presenting on its close tick, while the script-owned
-- result lands on the scheduler's next promotion tick. Wait for the result the
-- source variable actually carries instead of assuming the close tick published
-- it.
local function waitForResult(game, variableName, expected, label)
  return game:advanceUntil(label, function()
    return game.runtime.scripts.worldState:getVar(variableName) == expected
  end, 120)
end

local function openVanillaMenu(game)
  game:startScript(VANILLA_MENU)
  return game:advanceUntil("vanilla field menu becomes modal", menuIsModal, 120)
end

local function pressConfirm(game, source)
  game.runtime.input:pressAction(source)
  game:step()
  game.runtime.input:releaseAction(source)
end

local function pressKey(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

local function itemCenter(snapshot, itemIndex)
  local menu = assert(snapshot.menu, "field menu snapshot is required")
  local rect = assert(menu.itemRects[itemIndex], "field menu item rectangle is required")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function selectSecondItem(game)
  local opened = openVanillaMenu(game)
  local state = hostCallbacks(game)
  pressKey(game, state, "s")
  pressConfirm(game, "key:return")
  game:advanceUntil("field menu closes after selection", function(snapshot)
    return snapshot.menu ~= nil and not snapshot.menu.modal
  end, 120)
  waitForResult(game, RESULT_VARIABLE, 1, "the vanilla selection reaches its script result")
  return opened
end

-- The source multichoice script opens with two prints under a full field lock,
-- so advance the production printer until the choice itself is modal. A script
-- that stops before its window opens reports its recorded source reason.
local function scriptStopReport(game)
  local ended = game:recordsForScript(FOREGROUND_MULTICHOICE, "script.ended")[1]
  local failed = game:recordsForScript(FOREGROUND_MULTICHOICE, "script.error")[1]
  if ended == nil and failed == nil then
    return nil
  end
  return "reason=" .. tostring(ended and ended.payload.reason) .. ", error=" .. tostring(failed and failed.payload.code)
end

local function openForegroundMultichoice(game)
  for _ = 1, 480 do
    local snapshot = game:snapshot()
    if menuIsModal(snapshot) then
      return snapshot
    end
    local stopped = scriptStopReport(game)
    if stopped ~= nil then
      error("the source multichoice never opened: " .. stopped, 0)
    end
    if snapshot.dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error("the source multichoice never opened within the source print sequence", 0)
end

local function assertSourceWindow(snapshot)
  local layout = assert(snapshot.menu.layout, "modal menu must expose production layout")
  Assert.isTrue(layout.surface.role ~= "auxiliary", "a source multichoice does not use the auxiliary surface")
  local surface = layout.listSurface.surface
  -- ScriptMenu_ShowMultichoice adds its main-display window at the stored source
  -- tiles with the measured width and two tile rows per item. A framed window
  -- spends at most one of those tiles per side on its border.
  Assert.isTrue(
    surface.x >= MULTICHOICE_TILE_X * 8 and surface.x <= (MULTICHOICE_TILE_X + 1) * 8,
    "the window starts at its source tile column: " .. surface.x
  )
  Assert.isTrue(
    surface.y >= MULTICHOICE_TILE_Y * 8 and surface.y <= (MULTICHOICE_TILE_Y + 1) * 8,
    "the window starts at its source tile row: " .. surface.y
  )
  Assert.isTrue(
    surface.height >= MULTICHOICE_ITEM_COUNT * 2 * 8 - 16 and surface.height <= MULTICHOICE_ITEM_COUNT * 2 * 8,
    "the window is two source tile rows per item: " .. surface.height
  )
  Assert.equal(surface.width % 8, 0, "the source window stays on the tile grid")
  Assert.equal(layout.itemCount, MULTICHOICE_ITEM_COUNT)
  return layout, surface
end

-- A real 749--752 menu reaches the script-owned controller and writes the
-- vanilla value, never the visual row number or source message id.
function T.tests.vanilla_menu_selection_commits_its_script_result()
  withGame({}, function(game)
    local opened = selectSecondItem(game)
    local layout = assert(opened.menu.layout, "modal menu must expose production layout")
    Assert.isTrue(layout.surface.touch == false, "default desktop surface must not claim touch capability")
    local placement, box = layout.placement, layout.listSurface.surface
    local frame = game.runtime.viewport.referenceFrame
    local right = placement.origin.x + (box.x + box.width) * placement.scale
    Assert.isTrue(right <= frame.x + frame.width, "the menu stays inside the central 4:3 region")
    Assert.isTrue(frame.x + frame.width - right <= 16 * placement.scale, "the menu anchors to the region's right edge")
    Assert.isTrue(placement.origin.y + box.y * placement.scale - frame.y <= 16 * placement.scale, "and its top edge")
    Assert.equal(game.runtime.scripts.worldState:getVar(RESULT_VARIABLE), 1)
  end)
end

-- Opcode 749 deliberately yields after creating its builder.
-- A process restart at that source-faithful boundary must retain the builder
-- in the foreground script instance, so the later 751/752 operations can
-- publish the same real menu and write its selected HGSS value.
function T.tests.restart_after_hgss_menu_begin_resumes_the_real_menu_builder()
  withGame({}, function(game)
    game:waitForFieldEntry()
    game:startScript(VANILLA_MENU)
    game:step()

    local resumed = game:restart({ save = "resume" })
    local opened = resumed:advanceUntil("resumed HGSS menu becomes modal", menuIsModal, 120)

    local x, y = itemCenter(opened, 1)
    resumed.runtime.input:pointerDown("mouse:1", x, y)
    resumed:step()
    resumed.runtime.input:pointerUp("mouse:1", x, y)
    resumed:advanceUntil("resumed HGSS menu closes after selection", function(snapshot)
      return snapshot.menu ~= nil and not snapshot.menu.modal
    end, 120)
    waitForResult(resumed, RESULT_VARIABLE, 1, "the resumed selection reaches its script result")
    Assert.equal(resumed.runtime.scripts.worldState:getVar(RESULT_VARIABLE), 1)
  end)
end

-- The source foreground multichoice is a main-display window at its native tile
-- position, and a resumed run publishes the same window before committing the
-- clicked source value.
function T.tests.foreground_multichoice_opens_at_its_source_window_and_resumes_into_a_clicked_choice()
  withGame({ recordingScriptHosts = true }, function(game)
    game:waitForFieldEntry()
    game:startScript(FOREGROUND_MULTICHOICE)
    local opened = openForegroundMultichoice(game)
    local _, surface = assertSourceWindow(opened)

    -- A display resize keeps the logical source window geometry.
    game.runtime.menuHost:resize(640, 480)
    game:step()
    local resized = game:snapshot()
    local _, resizedSurface = assertSourceWindow(resized)
    Assert.equal(resizedSurface.x, surface.x, "a resize never moves the source window")
    Assert.equal(resizedSurface.height, surface.height, "a resize never rescales the source window")

    -- A save while the choice waits restores the same window, not a second one.
    local resumed = game:restart({ save = "resume" })
    local reopened = resumed:advanceUntil("resumed source multichoice becomes modal", menuIsModal, 120)
    assertSourceWindow(reopened)

    local x, y = itemCenter(reopened, 2)
    resumed.runtime.input:pointerDown("mouse:1", x, y)
    resumed:step()
    resumed.runtime.input:pointerUp("mouse:1", x, y)
    resumed:advanceUntil("resumed source multichoice closes after selection", function(snapshot)
      return snapshot.menu ~= nil and not snapshot.menu.modal
    end, 120)
    waitForResult(resumed, "VAR_SPECIAL_RESULT", 2, "the clicked source byte commits")
    Assert.equal(resumed.runtime.scripts.worldState:getVar("VAR_SPECIAL_RESULT"), 2, "the clicked source byte commits")
    Assert.equal(resumed.runtime.menuHost:isModal(), false, "the foreground window closes once")
  end)
end

-- ScrCmd_MultichoiceExec waits while the source result variable is unchanged, so
-- B commits the retail cancellation sentinel and resumes the script.
function T.tests.foreground_multichoice_cancels_to_the_source_cancel_value()
  withGame({ recordingScriptHosts = true }, function(game)
    game:waitForFieldEntry()
    game:startScript(FOREGROUND_MULTICHOICE)
    openForegroundMultichoice(game)
    local state = hostCallbacks(game)
    pressKey(game, state, "backspace")
    game:advanceUntil("source multichoice closes after cancellation", function(snapshot)
      return snapshot.menu ~= nil and not snapshot.menu.modal
    end, 120)
    waitForResult(game, "VAR_SPECIAL_RESULT", 0xFFFE, "the cancellation sentinel reaches its script result")
    Assert.equal(game.runtime.scripts.worldState:getVar("VAR_SPECIAL_RESULT"), 0xFFFE)
    Assert.equal(game.runtime.menuHost:isModal(), false, "the cancelled window closes once")
  end)
end

return T
