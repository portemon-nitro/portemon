-- Transcribed battle-party wrapper input geometry: mon-menu, summary,
-- check-moves, and move-detail hitboxes, d-pad cursor boxes, and input
-- orders follow battle_party_menu.c exactly (GetMonMenuInput/
-- GetSummaryInput/GetCheckMovesInput/GetMoveDetailInput with
-- FindNextMon paging handled by the caller). Staged manifest tables win
-- while present; the pinned decomp fallback keeps unit and old-cache
-- behavior identical to staged resolution.

local Assert = require("tests.support.Assert")

local BattlePartyPages = nil

local T = {}

local function pages()
  if BattlePartyPages == nil then
    BattlePartyPages = require("game.hgss.src.battle.BattlePartyPages")
  end
  return BattlePartyPages
end

function T.touch_follows_hitbox_order_with_half_open_edges()
  local P = pages()
  -- Summary hitbox 0 is { top = 152, bottom = 191, left = 0, right = 39 }.
  Assert.equal(P.touchInput("summary", nil, 20, 170), 0, "a tap inside the first summary box names input 0")
  Assert.equal(P.touchInput("summary", nil, 50, 170), 1, "a tap inside the second summary box names input 1")
  Assert.equal(P.touchInput("summary", nil, 150, 170), 2, "a tap inside the moves box names input 2")
  Assert.equal(P.touchInput("summary", nil, 230, 170), 3, "a tap inside the shared cancel box names cancel")
  Assert.isNil(P.touchInput("summary", nil, 200, 170), "the gap between moves and cancel names no input")
  Assert.isNil(P.touchInput("summary", nil, 20, 100), "a tap outside every box names no input")
  -- Half-open edges: the right edge belongs to no box when the next
  -- box starts later (the 39/40 gap), and to the next box when the
  -- boxes abut.
  Assert.isNil(P.touchInput("summary", nil, 39, 170), "the gap pixel names no input")
  Assert.equal(P.touchInput("summary", nil, 40, 170), 1, "the abutting edge resolves to the next box")
  Assert.equal(P.touchInput("moves", nil, 64, 70), 0, "check-moves taps name their move slot")
  Assert.equal(P.touchInput("moves", nil, 200, 70), 1, "check-moves taps name the second move slot")
  Assert.equal(P.touchInput("moves", nil, 64, 120), 2, "check-moves taps name the third move slot")
  Assert.equal(P.touchInput("moves", nil, 20, 170), 4, "check-moves prev names input 4")
  Assert.equal(P.touchInput("moves", nil, 150, 170), 6, "check-moves summary names input 6")
  Assert.equal(P.touchInput("moves", nil, 230, 170), 7, "check-moves cancel names input 7")
  Assert.equal(P.touchInput("move_detail", nil, 100, 160), 0, "move-detail tabs name their slot")
  Assert.equal(P.touchInput("move_detail", nil, 150, 175), 3, "move-detail tabs name the fourth slot")
  Assert.equal(P.touchInput("move_detail", nil, 230, 170), 4, "move-detail cancel names input 4")
end

function T.initial_cursor_matches_set_page_cursor()
  local P = pages()
  -- BattlePartyMenu_SetPageCursor seats no position for the summary
  -- page (SetBoxes resets to 0) and the selected move for the move
  -- pages.
  Assert.equal(P.initialCursor("summary", 2), 0, "summary opens on the prev-mon box")
  Assert.equal(P.initialCursor("moves", 2), 2, "check-moves opens on the selected move")
  Assert.equal(P.initialCursor("move_detail", 3), 3, "move detail opens on the selected move")
end

function T.dpad_follows_neighbor_links_with_return_links()
  local P = pages()
  -- Summary row: left/right walk the four boxes, up/down stay.
  local step = P.stepCursor("summary", nil, 2, nil, "left")
  Assert.equal(step.pos, 1, "left from the moves box reaches next-mon")
  Assert.isTrue(step.moved, "the step reports movement")
  step = P.stepCursor("summary", nil, 2, nil, "up")
  Assert.equal(step.pos, 2, "up from the moves box stays")
  Assert.isFalse(step.moved, "a staying step reports no movement")
  -- Check-moves return link: down from move slot 2 (box 2, down = 0x84)
  -- lands on the prev-mon box, and up returns through the recorded link.
  step = P.stepCursor("moves", nil, 2, nil, "down")
  Assert.equal(step.pos, 4, "down from the third move strips the return flag to prev-mon")
  local back = P.stepCursor("moves", nil, step.pos, step.prev, "up")
  Assert.equal(back.pos, 2, "up returns through the recorded link")
  Assert.equal(back.prev, 4, "the return records where it came from")
  local forth = P.stepCursor("moves", nil, back.pos, back.prev, "down")
  Assert.equal(forth.pos, 4, "down follows the recorded link back")
end

function T.cancel_input_matches_the_dpad_cancel_button()
  local P = pages()
  Assert.equal(P.cancelInput("summary"), 3, "summary B names input 3")
  Assert.equal(P.cancelInput("moves"), 7, "check-moves B names input 7")
  Assert.equal(P.cancelInput("move_detail"), 4, "move-detail B names input 4")
end

function T.staged_tables_override_the_pinned_fallback()
  local P = pages()
  local staged = {
    hitboxes = {
      summary = {
        { top = 0, bottom = 10, left = 0, right = 10 },
        { top = 0, bottom = 10, left = 10, right = 20 },
        { top = 0, bottom = 10, left = 20, right = 30 },
      },
    },
    cursorBoxes = {
      summary = {
        { left = 0, top = 0, right = 1, bottom = 1, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 0 },
        { left = 0, top = 0, right = 1, bottom = 1, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 0 },
        { left = 0, top = 0, right = 1, bottom = 1, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 0 },
        { left = 0, top = 0, right = 1, bottom = 1, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 0 },
      },
    },
  }
  Assert.equal(P.touchInput("summary", staged, 5, 5), 0, "staged hitboxes resolve first")
  Assert.isNil(P.touchInput("summary", staged, 20, 170), "staged hitboxes replace the pinned ones")
  local step = P.stepCursor("summary", staged, 0, nil, "right")
  Assert.equal(step.pos, 0, "staged cursor boxes drive the dpad")
end

function T.mon_menu_touch_follows_the_full_screen_hitboxes()
  local P = pages()
  -- Mon-menu hitboxes in Handle order: the large upper SHIFT box, the
  -- SUMMARY and CHECK MOVES buttons, then the shared cancel rect.
  Assert.equal(P.touchInput("mon_menu", nil, 100, 100), 0, "a tap inside the upper box names SHIFT")
  Assert.equal(P.touchInput("mon_menu", nil, 50, 170), 1, "a tap inside the left button names SUMMARY")
  Assert.equal(P.touchInput("mon_menu", nil, 150, 170), 2, "a tap inside the right button names CHECK MOVES")
  Assert.equal(P.touchInput("mon_menu", nil, 230, 170), 3, "a tap inside the shared cancel box names cancel")
  Assert.isNil(P.touchInput("mon_menu", nil, 210, 170), "the gap between buttons names no input")
  Assert.isNil(P.touchInput("mon_menu", nil, 100, 150), "a tap between the box and the buttons names no input")
end

function T.mon_menu_dpad_walks_the_full_screen_boxes()
  local P = pages()
  -- Box 0 (SHIFT) carries the 0x80 return link downward; without a
  -- recorded position the flag strips to the SUMMARY box.
  local step = P.stepCursor("mon_menu", nil, 0, nil, "down")
  Assert.equal(step.pos, 1, "down from SHIFT strips the return flag to SUMMARY")
  Assert.isTrue(step.moved, "the stripping step reports movement")
  step = P.stepCursor("mon_menu", nil, 0, nil, "right")
  Assert.equal(step.pos, 0, "right from SHIFT stays")
  Assert.isFalse(step.moved, "a staying step reports no movement")
  step = P.stepCursor("mon_menu", nil, 1, nil, "right")
  Assert.equal(step.pos, 2, "right from SUMMARY reaches CHECK MOVES")
  step = P.stepCursor("mon_menu", nil, 2, nil, "right")
  Assert.equal(step.pos, 3, "right from CHECK MOVES reaches cancel")
  step = P.stepCursor("mon_menu", nil, 2, nil, "left")
  Assert.equal(step.pos, 1, "left from CHECK MOVES reaches SUMMARY")
end

function T.mon_menu_names_its_retail_controls()
  local P = pages()
  Assert.deepEqual(
    P.inputIds("mon_menu"),
    { "switch", "summary", "moves", "back" },
    "mon-menu ids follow the GetMonMenuInput order with cancel last"
  )
  Assert.equal(P.cancelInput("mon_menu"), 3, "mon-menu B names input 3")
  Assert.equal(P.pageArtKey("mon_menu"), "party:page/mon-menu", "the mon menu stages its page art")
end

function T.mon_menu_text_rides_its_four_windows()
  local P = pages()
  local layout = P.textLayout("mon_menu")
  Assert.equal(layout["mon-name"].window, 0, "the mon name rides window 0")
  Assert.equal(layout["mon-name"].font, "menu", "the mon name prints in the menu font")
  Assert.equal(layout["mon-name"].y, 7, "the mon name prints at the retail origin")
  Assert.equal(layout["mon-gender"].window, 0, "the gender symbol rides the name window")
  Assert.equal(layout["mon-gender"].fg, 10, "the centered male symbol prints in the menu ink")
  Assert.equal(layout["mon-gender"].sh, 11, "the centered male symbol shadows in the menu ink")
  Assert.equal(layout["shift-button"].window, 1, "SHIFT rides window 1")
  Assert.equal(layout["summary-button"].window, 2, "SUMMARY rides window 2")
  Assert.equal(layout["moves-button"].window, 3, "CHECK MOVES rides window 3")
  for _, role in ipairs({ "shift-button", "summary-button", "moves-button" }) do
    Assert.equal(layout[role].font, "menu", role .. " prints in the menu font")
    Assert.equal(layout[role].fg, 7, role .. " prints in the button ink")
    Assert.equal(layout[role].sh, 8, role .. " prints in the button shadow")
    Assert.equal(layout[role].bg, 9, role .. " prints on the button background")
    Assert.equal(layout[role].y, 5, role .. " prints at the label origin")
  end
end

function T.input_ids_name_stable_controls_in_decomp_order()
  local P = pages()
  Assert.deepEqual(
    P.inputIds("summary"),
    { "summary:prev", "summary:next", "summary:moves", "back" },
    "summary ids follow the GetSummaryInput order with cancel last"
  )
  Assert.deepEqual(
    P.inputIds("moves"),
    { "move:0", "move:1", "move:2", "move:3", "moves:prev", "moves:next", "moves:summary", "back" },
    "check-moves ids follow the GetCheckMovesInput order with cancel last"
  )
  Assert.deepEqual(
    P.inputIds("move_detail"),
    { "move:0", "move:1", "move:2", "move:3", "back" },
    "move-detail ids follow the GetMoveDetailInput order with cancel last"
  )
end

function T.move_pages_print_the_gender_symbol_with_their_name()
  local P = pages()
  -- PrintCheckMovesPage and PrintMoveDetailPage print through
  -- PrintMonName with font 0, so the gender symbol pastes to the right
  -- edge of the mon-name window (male (7,8,0), female (3,4,0)
  -- resolved per entry at paint time).
  for _, page in ipairs({ "moves", "move_detail" }) do
    local layout = P.textLayout(page)
    local gender = assert(layout["mon-gender"], page .. " carries its gender role")
    local name = assert(layout["mon-name"], page .. " carries its name role")
    Assert.equal(gender.window, name.window, page .. " pastes gender to the name window")
    Assert.equal(gender.align, "right", page .. " pastes gender to the window edge")
    Assert.equal(gender.fg, 7, page .. " males print in the hud ink")
    Assert.equal(gender.sh, 8, page .. " males shadow in the hud ink")
    Assert.equal(gender.bg, 0, page .. " gender prints transparent")
  end
end

return { tests = T }
