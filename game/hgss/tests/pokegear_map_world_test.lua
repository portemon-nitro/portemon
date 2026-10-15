-- The region map's world view model: the visible window, scroll, and affine
-- zoom follow the source map application's invariants. Expectations are
-- derived from the source's closed rest relations (the window is centred
-- on the selected cell and clamped to the unlock tier, the layer scroll is
-- eight pixels per cell left of the window, and a cell's centre lands on
-- the screen origin plus its window offset), never from the model itself.

local Assert = require("tests.support.Assert")
local MapWorld = require("game.hgss.src.pokegear.map.MapWorld")

local T = {
  metadata = { tags = { "pokegear" } },
  tests = {},
}

local function settle(world)
  for _ = 1, 8 do
    world:tick()
  end
end

---@param world MapWorld
local function assertCursorOnCell(world, label)
  local x, y = world:cellCentre(world.cell.x, world.cell.y)
  Assert.equal(world.cursorX, x, label .. ": the cursor sits on its cell horizontally")
  Assert.equal(world.cursorY, y, label .. ": the cursor sits on its cell vertically")
end

function T.tests.initial_window_centres_on_the_player_and_clamps_to_the_tier()
  local world = MapWorld.new({ kind = "gear", unlock = 2, matrix = { x = 21, y = 12 } })
  Assert.equal(world.cell.y, 14, "rows gain the source offset of two")
  Assert.equal(world.top, 1, "the unzoomed window always spans the full rows")
  Assert.equal(world.bottom, 17, "the unzoomed window always spans the full rows")
  Assert.equal(world.left, 21 - 11, "the window centres the cell on its twelfth column")
  Assert.equal(world.right, world.left + 23, "the unzoomed window is twenty-four cells wide")
  Assert.equal(world.scrollX, 8 * (world.left - 1), "the scroll sits eight pixels per cell left of the window")
  Assert.equal(world.scrollY, 0, "the unzoomed rows never scroll")
  assertCursorOnCell(world, "centred")

  local edge = MapWorld.new({ kind = "gear", unlock = 0, matrix = { x = 3, y = 5 } })
  Assert.equal(edge.left, 1, "a cell near the western edge clamps the window to the first column")
  Assert.equal(edge.scrollX, 0, "the clamped window starts at the layer origin")
  assertCursorOnCell(edge, "clamped west")

  local tier0 = MapWorld.new({ kind = "gear", unlock = 0, matrix = { x = 24, y = 8 } })
  Assert.equal(tier0.right, 26, "Johto-only maps stop the window at column twenty-six")
  Assert.equal(tier0.left, 26 - 23, "the clamped window keeps its width")
  assertCursorOnCell(tier0, "clamped east")
end

function T.tests.fly_frame_shifts_the_window_origin_and_scroll_bias()
  local world = MapWorld.new({ kind = "fly", unlock = 2, matrix = { x = 21, y = 12 } })
  Assert.equal(world.frame.centerX, 32, "the fly window starts at screen column thirty-two")
  Assert.equal(world.frame.xOffset, -24, "the fly layer carries its scroll bias")
  assertCursorOnCell(world, "fly")
  local x = world:cellCentre(world.left, world.top)
  Assert.equal(x, 32 + 4, "the first window cell is centred a half cell past the window origin")
end

function T.tests.a_keyboard_move_takes_two_ticks_and_walks_the_cursor_one_cell()
  local world = MapWorld.new({ kind = "gear", unlock = 2, matrix = { x = 21, y = 12 } })
  local startX = world.cursorX
  local moved = world:moveSelection(false, false, false, true)
  Assert.notNil(moved, "the cell moves immediately")
  Assert.equal(world.cell.x, 22, "the selected cell advances at once")
  world:beginMove(moved --[[@as table]])
  Assert.isTrue(world:busy(), "the tween gates input")
  world:tick()
  world:tick()
  Assert.isFalse(world:busy(), "a cell move lasts exactly two ticks")
  Assert.equal(world.cursorX, startX + 8, "two four-pixel steps move the cursor one cell")
  assertCursorOnCell(world, "after a move")
end

function T.tests.moving_past_the_window_edge_scrolls_the_world_under_the_cursor()
  local world = MapWorld.new({ kind = "gear", unlock = 2, matrix = { x = 21, y = 12 } })
  -- Walk right until the cursor reaches window column twenty-two.
  local scrollBefore
  for _ = 1, 14 do
    local moved = world:moveSelection(false, false, false, true)
    world:beginMove(moved --[[@as table]])
    scrollBefore = world.scrollX
    world:tick()
    world:tick()
  end
  Assert.isTrue(world.scrollX > scrollBefore - 16, "the layer has scrolled across the walk")
  assertCursorOnCell(world, "after scrolling")
  Assert.equal(world.right - world.left, 23, "the window keeps its width")
end

function T.tests.zoom_takes_four_ticks_and_lands_on_the_zoomed_rest_relation()
  local world = MapWorld.new({ kind = "gear", unlock = 2, matrix = { x = 21, y = 12 } })
  world:toggleZoom()
  Assert.isTrue(world:zooming(), "the toggle starts the tween")
  for _ = 1, 3 do
    world:tick()
  end
  Assert.isTrue(world:zooming(), "the tween is still running after three ticks")
  Assert.equal(world.ratio, 1.75, "the scale grows by a quarter per tick")
  world:tick()
  Assert.isFalse(world:zooming(), "a zoom lasts exactly four ticks")
  Assert.equal(world.ratio, 2, "the zoom settles at twice the scale")
  Assert.equal(world.scrollX + world.affineX, 16 * world.left - 8, "the zoomed rest relation holds horizontally")
  Assert.equal(world.scrollY + world.affineY, 16 * world.top - 8, "the zoomed rest relation holds vertically")
  Assert.equal(world.right - world.left, 11, "the zoomed window is twelve cells wide")
  Assert.equal(world.bottom - world.top, 7, "the zoomed window is eight cells tall")
  assertCursorOnCell(world, "zoomed")
  world:toggleZoom()
  settle(world)
  Assert.equal(world.ratio, 1, "zooming out restores the unit scale")
  Assert.equal(world.scrollX, 8 * (world.left - 1), "the unzoomed rest relation holds again")
  assertCursorOnCell(world, "zoomed out")
end

function T.tests.touch_selection_clamps_to_the_inner_window_cells()
  local world = MapWorld.new({ kind = "gear", unlock = 2, matrix = { x = 21, y = 12 } })
  local x, y = world:cellFromTouch(8, 8)
  Assert.equal(x, world.left + 1, "the first column is excluded from touch selection")
  Assert.equal(y, world.top + 1, "the first row is excluded from touch selection")
  x, y = world:cellFromTouch(250, 150)
  Assert.equal(x, world.left + 22, "the last columns clamp to column twenty-two")
  Assert.equal(y, world.top + 16, "the last rows clamp to row sixteen")
end

function T.tests.a_touch_drag_scrolls_half_a_cell_per_tick_pair_and_keeps_the_selection_inside()
  local world = MapWorld.new({ kind = "gear", unlock = 2, matrix = { x = 21, y = 12 } })
  local cellBefore = { x = world.cell.x, y = world.cell.y }
  local leftBefore = world.left
  world:beginDrag(100, 80)
  -- Finger drags right by two steps (five pixels each): the window moves west.
  Assert.isTrue(world:stepDrag(true, 110, 80), "the drag continues while held")
  Assert.equal(world.left, leftBefore - 2, "the window bounds move by the whole step at once")
  Assert.equal(world.scrollX, 8 * (leftBefore - 1) - 2 * 4, "half of the scroll applies on the first tick")
  Assert.isTrue(world:stepDrag(true, 110, 80), "the second half completes next tick")
  Assert.equal(world.scrollX, 8 * (leftBefore - 1) - 2 * 4 - 2 * 4 + 0, "the remaining half scroll follows")
  Assert.equal(world.cell.x, cellBefore.x, "dragging never changes the selected cell")
  assertCursorOnCell(world, "dragged")
  Assert.isFalse(world:stepDrag(false, 110, 80), "lifting the finger ends the drag")
end

return T
