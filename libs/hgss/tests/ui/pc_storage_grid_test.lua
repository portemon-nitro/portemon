-- Source focus navigation for the PC Storage grid layouts.

local Assert = require("tests.support.Assert")
local PcStorageGrid = require("libs.hgss.src.ui.PcStorageGrid")

local T = { tests = {} }

local function grid(name, index)
  return PcStorageGrid.new(name, index)
end

function T.tests.box_rows_wrap_sideways_and_reach_title_and_bottom_buttons()
  local box = grid("move", 0)
  Assert.equal(box:move("left"), 5, "the first column wraps to the last column")
  Assert.equal(box:move("right"), 0, "the last column wraps back to the first")
  box:setNode(3)
  Assert.equal(box:move("up"), 30, "the first row rises to the box title")
  Assert.equal(box:kind(), "title", "the title plate is its own focus target")
  box:setNode(27)
  Assert.equal(box:move("down"), 33, "the last row reaches the PARTY button")
  Assert.equal(box:kind(), "party_button", "the source PARTY button receives focus")
  Assert.equal(box:move("right"), 34, "PARTY steps to the BOX tab")
  Assert.equal(box:kind(), "tray_tab", "the box tray tab is a focus target")
  Assert.equal(box:move("right"), 35, "the BOX tab steps to RETURN")
  Assert.equal(box:kind(), "return", "RETURN is the rightmost bottom control")
end

function T.tests.forced_links_remember_the_column_the_player_left()
  local box = grid("move", 27)
  Assert.equal(box:move("down"), 33, "down leaves the box through the PARTY button")
  Assert.equal(box:move("up"), 27, "up returns to the column the player left")
  box:setNode(33)
  Assert.equal(box:move("right"), 34, "stepping sideways clears the remembered column")
  Assert.equal(box:move("up"), 24, "a fresh move up uses the source link target")
end

function T.tests.tray_and_wallpaper_restore_the_last_cell_of_a_row()
  local tray = grid("tray", 5)
  tray:setRowCursor(37)
  Assert.equal(tray:move("up"), 37, "the top box row rises into the current tray cell")
  Assert.equal(tray:move("down"), 5, "the tray remembers the box column it came from")
  local wallpaper = grid("wallpaper", 1)
  Assert.equal(wallpaper:move("down"), 6, "a swatch drops to Confirm")
  Assert.equal(wallpaper:move("up"), 1, "Confirm returns to the swatch column")
  Assert.equal(wallpaper:move("down"), 6, "dropping again lands on Confirm")
  Assert.equal(wallpaper:move("down"), 7, "Confirm steps down to Cancel")
  Assert.equal(wallpaper:move("up"), 6, "Cancel rises to Confirm")
  Assert.equal(wallpaper:move("up"), 1, "Confirm rises to the remembered swatch")
end

function T.tests.editor_controls_follow_the_source_graph()
  local marking = grid("marking", 0)
  Assert.equal(marking:move("right"), 1, "marks step across their column pair")
  Assert.equal(marking:move("down"), 3, "the second mark drops a row")
  Assert.equal(marking:move("down"), 5, "the last row holds the fifth and sixth marks")
  Assert.equal(marking:move("down"), 6, "the last mark reaches Confirm")
  Assert.equal(marking:kind(), "confirm", "the marking panel owns a Confirm target")
  Assert.equal(marking:move("down"), 7, "Confirm steps to Cancel")
  Assert.equal(marking:kind(), "cancel", "the marking panel owns a Cancel target")
  Assert.equal(marking:move("up"), 6, "Cancel rises to Confirm")

  local rows = grid("deposit", 0)
  Assert.equal(rows:move("down"), 2, "party slots move down a row, not a slot")
  Assert.equal(rows:move("down"), 4, "the second party row drops again")
  Assert.equal(rows:move("down"), 6, "the last party row reaches RETURN")
  Assert.equal(rows:kind(), "return", "Deposit exposes its RETURN control")
  Assert.equal(rows:move("up"), 4, "RETURN returns to the remembered party row")
end

function T.tests.menus_open_and_close_through_their_source_nodes()
  local deposit = grid("deposit", 7)
  Assert.equal(deposit:kind(), "menu", "the first Deposit action row is a menu node")
  Assert.equal(deposit:move("down"), 8, "menu rows walk downward")
  Assert.equal(deposit:move("down"), 9, "the third row stays inside the list")
  Assert.equal(deposit:move("down"), 10, "the fourth row stays inside the list")
  Assert.equal(deposit:move("down"), 11, "the last row drops to the menu exit")
  Assert.equal(deposit:kind(), "menu_exit", "the menu exit is separate from RETURN")
  Assert.equal(deposit:move("up"), 10, "the exit rises back into the list")

  local move = grid("move", 36)
  local seen = {}
  for _ = 1, 5 do
    seen[#seen + 1] = move:index()
    move:move("down")
  end
  Assert.deepEqual(seen, { 36, 37, 38, 39, 40 }, "the five Move actions sit in source order")
  Assert.equal(move:kind(), "menu_exit", "the fifth Move row drops to the menu exit")

  local boxMenu = grid("boxMenu", 9)
  Assert.equal(boxMenu:move("down"), 10, "Wallpaper steps down to Name")
  Assert.equal(boxMenu:move("down"), 11, "Name steps down to the box menu exit")
  Assert.equal(boxMenu:kind(), "exit", "the box menu exit is its own target")
end

function T.tests.disabled_nodes_are_skipped_along_the_source_direction()
  local boxMenu = grid("boxMenu", 9)
  boxMenu:setNode(8)
  for index = 0, 7 do
    boxMenu:setEnabled(index, false)
  end
  Assert.isNil(boxMenu:move("up"), "a disabled tray keeps focus on the title")
  Assert.equal(boxMenu:index(), 8, "the title keeps the cursor")
  boxMenu:setNode(5)
  boxMenu:setEnabled(8, false)
  boxMenu:setEnabled(9, false)
  Assert.equal(boxMenu:move("down"), 10, "disabled menu rows are skipped downward")
end

function T.tests.cursor_pose_follows_the_source_animation_roles()
  Assert.equal(grid("move", 0):pose(), "menu", "box cells use the pointing hand")
  Assert.equal(grid("move", 30):pose(), "browse", "the title uses the open hand")
  Assert.equal(grid("deposit", 7):pose(), "browse", "action rows use the open hand")
  Assert.equal(grid("marking", 2):pose(), "menu", "marks use the pointing hand")
  Assert.equal(grid("wallpaper", 0):pose(), "menu", "wallpaper swatches use the pointing hand")
  Assert.equal(grid("wallpaper", 6):pose(), "browse", "Confirm uses the open hand")
end

function T.tests.touch_hit_boxes_match_the_source_rects()
  Assert.equal(PcStorageGrid.hitTest("move", 12, 40), 0, "the first box cell starts at its source rect")
  Assert.equal(PcStorageGrid.hitTest("move", 36, 40), 1, "the adjacent cell starts at its own source rect")
  Assert.equal(PcStorageGrid.hitTest("move", 35, 62), nil, "the source leaves a one-pixel gap between cells")
  Assert.equal(PcStorageGrid.hitTest("move", 90, 180), nil, "the gap between controls is inert")
  Assert.equal(PcStorageGrid.hitTest("deposit", 224, 168), 6, "Deposit RETURN is hit through its source rect")
  Assert.equal(PcStorageGrid.hitTest("wallpaper", 212, 112), 6, "Confirm spans the source rectangle")
end

return T
