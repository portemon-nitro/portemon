-- Transcribed battle-party wrapper page input geometry. Mon-menu,
-- summary, check-moves, and move-detail hitboxes and d-pad cursor boxes
-- follow battle_party_menu.c exactly (sBattlePartyMonMenuHitboxes,
-- sBattlePartySummaryHitboxes, sBattlePartyCheckMovesHitboxes,
-- sBattlePartyMoveDetailHitboxes and gBattlePartyPageCursorBoxes pages
-- 1-4; rects are top/bottom/left/right,
-- cursor boxes carry left/top/right/bottom edges with up/down/left/right
-- neighbor indices where bit 7 marks a return link). Touch resolves
-- first-match in table order with half-open edges (touchscreen.c
-- FindRectAtTouchNew/FindRectAtPoint); the d-pad follows
-- BattleDpadCursor_HandleInput with its activation gate, neighbor walk,
-- return-link records, and per-direction SELECT/DECIDE sounds owned by
-- the barrier. The shared cancel touch rect is the trailing cancel entry
-- every wrapper table ends with ({152,191,216,255}); it is not staged
-- because the manifest hitbox counts follow the Handle input orders,
-- which exclude the cancel button.
--
-- Staged manifest tables (manifest.party.hitboxes/cursorBoxes) win while
-- present and well-formed; the pinned transcriptions keep headless, unit,
-- and old-cache behavior identical to staged resolution. Pure module:
-- no love, no I/O.

local BattlePartyPages = {}

-- Trailing cancel touch rect shared by every wrapper page table
-- (battle_party_menu.c sBattleParty*Hitboxes final rect before
-- TOUCHSCREEN_RECTLIST_END, identical on all eight tables).
BattlePartyPages.CANCEL_RECT = { top = 152, bottom = 191, left = 216, right = 255 }

-- Pinned mon-menu hitboxes in Handle order (SHIFT, SUMMARY, CHECK
-- MOVES); cancel rides CANCEL_RECT.
local PINNED_MONMENU_HITBOXES = {
  { top = 8, bottom = 143, left = 8, right = 247 },
  { top = 152, bottom = 191, left = 0, right = 103 },
  { top = 152, bottom = 191, left = 104, right = 207 },
}

-- Pinned summary hitboxes in Handle order (prev-mon, next-mon,
-- summary-to-moves); cancel rides CANCEL_RECT.
local PINNED_SUMMARY_HITBOXES = {
  { top = 152, bottom = 191, left = 0, right = 39 },
  { top = 152, bottom = 191, left = 40, right = 79 },
  { top = 152, bottom = 191, left = 96, right = 199 },
}

-- Pinned check-moves hitboxes in Handle order (moves 0-3, prev-mon,
-- next-mon, moves-to-summary); cancel rides CANCEL_RECT.
local PINNED_MOVES_HITBOXES = {
  { top = 48, bottom = 95, left = 0, right = 127 },
  { top = 48, bottom = 95, left = 128, right = 255 },
  { top = 96, bottom = 143, left = 0, right = 127 },
  { top = 96, bottom = 143, left = 128, right = 255 },
  { top = 152, bottom = 191, left = 0, right = 39 },
  { top = 152, bottom = 191, left = 40, right = 79 },
  { top = 152, bottom = 191, left = 96, right = 199 },
}

-- Pinned move-detail hitboxes in Handle order (move tabs 0-3); cancel
-- rides CANCEL_RECT.
local PINNED_DETAIL_HITBOXES = {
  { top = 152, bottom = 167, left = 88, right = 127 },
  { top = 152, bottom = 167, left = 128, right = 167 },
  { top = 168, bottom = 183, left = 88, right = 127 },
  { top = 168, bottom = 183, left = 128, right = 167 },
}

-- Pinned mon-menu cursor boxes in page order (SHIFT, SUMMARY, CHECK
-- MOVES, cancel). Box 0 (down) = 129 carries the 0x80 return-link flag
-- back through the recorded position.
local PINNED_MONMENU_BOXES = {
  { left = 16, top = 16, right = 240, bottom = 136, up = 0, down = 129, leftNeighbor = 0, rightNeighbor = 0 },
  { left = 8, top = 160, right = 96, bottom = 184, up = 0, down = 1, leftNeighbor = 1, rightNeighbor = 2 },
  { left = 112, top = 160, right = 200, bottom = 184, up = 0, down = 2, leftNeighbor = 1, rightNeighbor = 3 },
  { left = 224, top = 160, right = 248, bottom = 184, up = 0, down = 3, leftNeighbor = 2, rightNeighbor = 3 },
}

-- Pinned summary cursor boxes in page order (prev, next, moves, cancel).
local PINNED_SUMMARY_BOXES = {
  { left = 8, top = 160, right = 32, bottom = 184, up = 0, down = 0, leftNeighbor = 0, rightNeighbor = 1 },
  { left = 48, top = 160, right = 72, bottom = 184, up = 1, down = 1, leftNeighbor = 0, rightNeighbor = 2 },
  { left = 104, top = 160, right = 192, bottom = 184, up = 2, down = 2, leftNeighbor = 1, rightNeighbor = 3 },
  { left = 224, top = 160, right = 248, bottom = 184, up = 3, down = 3, leftNeighbor = 2, rightNeighbor = 3 },
}

-- Pinned check-moves cursor boxes in page order (moves 0-3, prev, next,
-- summary, cancel). Box 3 (up) = 135 and box 2 (down) = 132 carry the
-- 0x80 return-link flag back to the move the cursor came from.
local PINNED_MOVES_BOXES = {
  { left = 8, top = 56, right = 120, bottom = 88, up = 0, down = 2, leftNeighbor = 0, rightNeighbor = 1 },
  { left = 136, top = 56, right = 248, bottom = 88, up = 1, down = 3, leftNeighbor = 0, rightNeighbor = 1 },
  { left = 8, top = 104, right = 120, bottom = 136, up = 0, down = 132, leftNeighbor = 2, rightNeighbor = 3 },
  { left = 136, top = 104, right = 248, bottom = 136, up = 1, down = 135, leftNeighbor = 2, rightNeighbor = 3 },
  { left = 8, top = 160, right = 32, bottom = 184, up = 2, down = 4, leftNeighbor = 4, rightNeighbor = 5 },
  { left = 48, top = 160, right = 72, bottom = 184, up = 2, down = 5, leftNeighbor = 4, rightNeighbor = 6 },
  { left = 104, top = 160, right = 192, bottom = 184, up = 3, down = 6, leftNeighbor = 5, rightNeighbor = 7 },
  { left = 224, top = 160, right = 248, bottom = 184, up = 3, down = 7, leftNeighbor = 6, rightNeighbor = 7 },
}

-- Pinned move-detail cursor boxes in page order (tabs 0-3, cancel).
-- Box 4 (left) = 131 carries the return-link flag; the tab boxes hold
-- the plain neighbor grid.
local PINNED_DETAIL_BOXES = {
  { left = 92, top = 157, right = 124, bottom = 165, up = 0, down = 2, leftNeighbor = 0, rightNeighbor = 1 },
  { left = 132, top = 157, right = 164, bottom = 165, up = 1, down = 3, leftNeighbor = 0, rightNeighbor = 4 },
  { left = 92, top = 173, right = 124, bottom = 181, up = 0, down = 2, leftNeighbor = 2, rightNeighbor = 3 },
  { left = 132, top = 173, right = 164, bottom = 181, up = 1, down = 3, leftNeighbor = 2, rightNeighbor = 4 },
  { left = 224, top = 160, right = 248, bottom = 184, up = 4, down = 4, leftNeighbor = 131, rightNeighbor = 4 },
}

local PINNED_HITBOXES = {
  mon_menu = PINNED_MONMENU_HITBOXES,
  summary = PINNED_SUMMARY_HITBOXES,
  moves = PINNED_MOVES_HITBOXES,
  move_detail = PINNED_DETAIL_HITBOXES,
}

local PINNED_BOXES = {
  mon_menu = PINNED_MONMENU_BOXES,
  summary = PINNED_SUMMARY_BOXES,
  moves = PINNED_MOVES_BOXES,
  move_detail = PINNED_DETAIL_BOXES,
}

-- Stable control identities in decomp Handle input order; cancel is
-- always last, matching the B-button cancelButton per page.
local INPUT_IDS = {
  mon_menu = { "switch", "summary", "moves", "back" },
  summary = { "summary:prev", "summary:next", "summary:moves", "back" },
  moves = { "move:0", "move:1", "move:2", "move:3", "moves:prev", "moves:next", "moves:summary", "back" },
  move_detail = { "move:0", "move:1", "move:2", "move:3", "back" },
}

-- B-button input per page (DEFINE_GET_PAGE_INPUT cancelButton:
-- mon-menu 3, summary 3, check-moves 7, move-detail 4).
local CANCEL_INPUT = { mon_menu = 3, summary = 3, moves = 7, move_detail = 4 }

---@param value unknown candidate box under validation
---@return boolean valid true while the box carries numeric rect edges
local function isHitbox(value)
  return type(value) == "table"
    and type(value.top) == "number"
    and type(value.bottom) == "number"
    and type(value.left) == "number"
    and type(value.right) == "number"
end

---@param value unknown candidate cursor box under validation
---@return boolean valid true while the box carries edges and neighbors
local function isCursorBox(value)
  return type(value) == "table"
    and type(value.left) == "number"
    and type(value.top) == "number"
    and type(value.right) == "number"
    and type(value.bottom) == "number"
    and type(value.up) == "number"
    and type(value.down) == "number"
    and type(value.leftNeighbor) == "number"
    and type(value.rightNeighbor) == "number"
end

---@param page string wrapper page under lookup
---@return string? staged hitbox section key, nil outside the wrapper pages
local function hitboxKey(page)
  if page == "mon_menu" then
    return "monMenu"
  end
  if page == "summary" then
    return "summary"
  end
  if page == "moves" then
    return "checkMoves"
  end
  if page == "move_detail" then
    return "moveDetail"
  end
  return nil
end

---@param page string wrapper page under lookup
---@return string? staged cursor-box section key, nil outside the wrapper pages
local function cursorKey(page)
  return hitboxKey(page)
end

---@param page string wrapper page under lookup
---@return string? staged party page drawable key, nil outside the wrapper pages
function BattlePartyPages.pageArtKey(page)
  if page == "mon_menu" then
    return "party:page/mon-menu"
  end
  if page == "summary" then
    return "party:page/summary"
  end
  if page == "moves" then
    return "party:page/check-moves"
  end
  if page == "move_detail" then
    return "party:page/move-detail"
  end
  return nil
end

---@param page string wrapper page under resolution
---@param partySection table<string, unknown>? battle manifest party section under resolution
---@return table<integer, table<string, unknown>> hitboxes in Handle order without the cancel rect
function BattlePartyPages.hitboxes(page, partySection)
  local key = hitboxKey(page)
  local pinned = PINNED_HITBOXES[page]
  assert(pinned ~= nil, "wrapper hitboxes name their page")
  if type(partySection) == "table" then
    local sections = partySection.hitboxes --[[@as table<string, unknown>?]]
    local staged = type(sections) == "table" and sections[key] or nil
    if type(staged) == "table" and #staged == #pinned then
      local valid = true
      for _, box in ipairs(staged) do
        if not isHitbox(box) then
          valid = false
          break
        end
      end
      if valid then
        return staged --[[@as table<integer, table<string, unknown>>]]
      end
    end
  end
  return pinned
end

---@param page string wrapper page under resolution
---@param partySection table<string, unknown>? battle manifest party section under resolution
---@return table<integer, table<string, unknown>> cursor boxes in page order
function BattlePartyPages.cursorBoxes(page, partySection)
  local key = cursorKey(page)
  local pinned = PINNED_BOXES[page]
  assert(pinned ~= nil, "wrapper cursor boxes name their page")
  if type(partySection) == "table" then
    local sections = partySection.cursorBoxes --[[@as table<string, unknown>?]]
    local staged = type(sections) == "table" and sections[key] or nil
    if type(staged) == "table" and #staged == #pinned then
      local valid = true
      for _, box in ipairs(staged) do
        if not isCursorBox(box) then
          valid = false
          break
        end
      end
      if valid then
        return staged --[[@as table<integer, table<string, unknown>>]]
      end
    end
  end
  return pinned
end

---@param page string wrapper page under touch lookup
---@param partySection table<string, unknown>? battle manifest party section under lookup
---@param x number tap horizontal position under lookup
---@param y number tap vertical position under lookup
---@return integer? decomp input index in Handle order, nil outside every box
function BattlePartyPages.touchInput(page, partySection, x, y)
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  local boxes = BattlePartyPages.hitboxes(page, partySection)
  for index, box in ipairs(boxes) do
    -- Half-open edges (touchscreen.c PointIsInRect): the shared edge
    -- belongs to the later box, and the first match wins.
    if x >= box.left and x < box.right and y >= box.top and y < box.bottom then
      return index - 1
    end
  end
  local cancel = BattlePartyPages.CANCEL_RECT
  if x >= cancel.left and x < cancel.right and y >= cancel.top and y < cancel.bottom then
    return CANCEL_INPUT[page]
  end
  return nil
end

---@param page string wrapper page under lookup
---@return integer B-button input index behind the page
function BattlePartyPages.cancelInput(page)
  local input = CANCEL_INPUT[page]
  assert(input ~= nil, "wrapper cancel names its page")
  return input
end

-- Code window indices behind wrapper page text (battle_party_menu.c
-- Print* call sites with windowSet 0): shared windows ride their
-- fixed indices while per-set windows read the first set. Fonts follow
-- the Print call sites (font 0 reads hud, font 4 reads menu) and inks
-- the MAKE_TEXT_COLOR slots. Multi-part roles (gender, HP/PP splits,
-- bars) resolve through the same windows in paint code.
---@param page string wrapper page under lookup
---@return table<string, table<string, unknown>> text layout by role
function BattlePartyPages.textLayout(page)
  if page == "mon_menu" then
    -- PrintMonMenuPage: the mon name centered in window 0 (the gender
    -- symbol rides the same window, offset past the centered name at
    -- paint time) and the SHIFT/SUMMARY/CHECK MOVES labels centered in
    -- windows 1-3. Eggs leave the SUMMARY/CHECK MOVES windows blank.
    -- PrintMonNameCentered inks male (10,11,0) and female (12,13,0);
    -- the table carries the male slots while paint resolves the female
    -- case per entry like the other pages.
    return {
      ["mon-name"] = { window = 0, font = "menu", align = "center", y = 7, fg = 7, sh = 8, bg = 9 },
      ["mon-gender"] = { window = 0, font = "hud", y = 8, fg = 10, sh = 11, bg = 0 },
      ["shift-button"] = { window = 1, font = "menu", align = "center", y = 5, fg = 7, sh = 8, bg = 9 },
      ["summary-button"] = { window = 2, font = "menu", align = "center", y = 5, fg = 7, sh = 8, bg = 9 },
      ["moves-button"] = { window = 3, font = "menu", align = "center", y = 5, fg = 7, sh = 8, bg = 9 },
    }
  end
  if page == "summary" then
    return {
      ["mon-name"] = { window = 0, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["mon-gender"] = { window = 0, font = "hud", align = "right", y = 0, fg = 7, sh = 8, bg = 0 },
      ["level-label"] = { window = 19, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["level-value"] = { window = 11, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["exp-label"] = { window = 20, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["exp-value"] = { window = 12, font = "hud", align = "right", y = 0, fg = 1, sh = 2, bg = 0 },
      ["hp-label"] = { window = 13, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["hp-value"] = { window = 4, font = "hud", parts = "hp", fg = 1, sh = 2, bg = 0 },
      ["hp-bar"] = { window = 10, bar = true },
      ["attack-label"] = { window = 14, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["attack-value"] = { window = 5, font = "hud", align = "right", y = 0, fg = 1, sh = 2, bg = 0 },
      ["defense-label"] = { window = 15, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["defense-value"] = { window = 6, font = "hud", align = "right", y = 0, fg = 1, sh = 2, bg = 0 },
      ["speed-label"] = { window = 16, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["speed-value"] = { window = 7, font = "hud", align = "right", y = 0, fg = 1, sh = 2, bg = 0 },
      ["sp-attack-label"] = { window = 17, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["sp-attack-value"] = { window = 8, font = "hud", align = "right", y = 0, fg = 1, sh = 2, bg = 0 },
      ["sp-defense-label"] = { window = 18, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["sp-defense-value"] = { window = 9, font = "hud", align = "right", y = 0, fg = 1, sh = 2, bg = 0 },
      ["ability-name"] = { window = 1, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["ability-desc"] = { window = 2, font = "hud", x = 0, y = 0, fg = 1, sh = 2, bg = 0 },
      ["held-item"] = { window = 3, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      ["button"] = { window = 21, font = "menu", align = "center", y = 5, fg = 7, sh = 8, bg = 9 },
    }
  end
  if page == "moves" then
    local layout = {
      ["mon-name"] = { window = 0, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
      -- PrintCheckMovesPage prints the gender symbol past the mon name
      -- through the same window (PrintMonName font 0: male (7,8,0),
      -- female (3,4,0)); paint resolves the female case per entry.
      ["mon-gender"] = { window = 0, font = "hud", align = "right", y = 0, fg = 7, sh = 8, bg = 0 },
      ["button"] = { window = 5, font = "menu", align = "center", y = 5, fg = 7, sh = 8, bg = 9 },
    }
    for moveSlot = 0, 3 do
      layout["move-name:" .. tostring(moveSlot)] =
        { window = 1 + moveSlot, font = "menu", align = "center", y = 7, fg = 7, sh = 8, bg = 9 }
      layout["move-pp:" .. tostring(moveSlot)] =
        { window = 1 + moveSlot, font = "hud", parts = "move-pp", fg = 15, sh = 14, bg = 0 }
    end
    return layout
  end
  assert(page == "move_detail", "wrapper text names its page")
  return {
    ["mon-name"] = { window = 6, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
    -- PrintMoveDetailPage prints through PrintMonName like the summary
    -- page, so the gender symbol rides the mon-name window's right edge
    -- (male (7,8,0), female (3,4,0) resolved per entry at paint time).
    ["mon-gender"] = { window = 6, font = "hud", align = "right", y = 0, fg = 7, sh = 8, bg = 0 },
    ["move-name"] = { window = 0, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
    ["power-label"] = { window = 9, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
    ["power-value"] = { window = 3, font = "hud", align = "right", y = 0, fg = 1, sh = 2, bg = 0 },
    ["accuracy-label"] = { window = 8, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
    ["accuracy-value"] = { window = 2, font = "hud", align = "right", y = 0, fg = 1, sh = 2, bg = 0 },
    ["category-label"] = { window = 10, font = "hud", align = "center", y = 0, fg = 15, sh = 14, bg = 0 },
    ["category-value"] = { window = 5, font = "hud", x = 0, y = 0, fg = 1, sh = 2, bg = 0 },
    ["move-desc"] = { window = 4, font = "hud", x = 0, y = 0, fg = 1, sh = 2, bg = 0 },
    ["pp-label"] = { window = 7, font = "hud", x = 0, y = 0, fg = 15, sh = 14, bg = 0 },
    ["pp-value"] = { window = 1, font = "hud", parts = "pp", fg = 15, sh = 14, bg = 0 },
  }
end

---@param page string wrapper page under lookup
---@return table<integer, string> stable control identities in Handle order
function BattlePartyPages.inputIds(page)
  local ids = INPUT_IDS[page]
  assert(ids ~= nil, "wrapper inputs name their page")
  local out = {}
  for index, id in ipairs(ids) do
    out[index] = id
  end
  return out
end

---@param page string wrapper page under cursor lookup
---@param selectedMove integer selected move slot behind move pages
---@return integer opening cursor position behind SetPageCursor
function BattlePartyPages.initialCursor(page, selectedMove)
  -- SetPageCursor seats no position for the summary page (SetBoxes
  -- resets it to 0) and the selected move for the move pages.
  if page == "summary" then
    return 0
  end
  assert(page == "moves" or page == "move_detail", "wrapper cursors name their page")
  assert(
    type(selectedMove) == "number" and selectedMove % 1 == 0 and selectedMove >= 0 and selectedMove <= 3,
    "move pages open on their selected move"
  )
  return selectedMove
end

---@param direction string dpad direction under stepping
---@return integer decomp direction code behind the step
local function directionCode(direction)
  if direction == "up" then
    return 0
  end
  if direction == "down" then
    return 1
  end
  if direction == "left" then
    return 2
  end
  assert(direction == "right", "wrapper dpad steps name their direction")
  return 3
end

---@param box table<string, unknown> cursor box behind the neighbor lookup
---@param direction integer decomp direction code under lookup
---@return integer neighbor box index with its return-link flag
local function neighborInDirection(box, direction)
  if direction == 0 then
    return box.up
  end
  if direction == 1 then
    return box.down
  end
  if direction == 2 then
    return box.leftNeighbor
  end
  return box.rightNeighbor
end

---@param box table<string, unknown> newly entered cursor box under link lookup
---@param direction integer decomp direction code under lookup
---@return boolean linked true while the opposite edge carries the return flag
local function hasReturnLink(box, direction)
  -- The neighbor in the direction opposite to the move is flagged as
  -- a link back to the box the cursor came from.
  if direction == 0 then
    return (box.down % 256) >= 128
  end
  if direction == 1 then
    return (box.up % 256) >= 128
  end
  if direction == 2 then
    return (box.rightNeighbor % 256) >= 128
  end
  return (box.leftNeighbor % 256) >= 128
end

---@param page string wrapper page under stepping
---@param partySection table<string, unknown>? battle manifest party section under stepping
---@param pos integer current cursor position under stepping
---@param prev integer? recorded return-link position under stepping
---@param direction string dpad direction under stepping
---@return { pos: integer, prev: integer?, moved: boolean } settled cursor behind the step
function BattlePartyPages.stepCursor(page, partySection, pos, prev, direction)
  local boxes = BattlePartyPages.cursorBoxes(page, partySection)
  assert(type(boxes[pos + 1]) == "table", "wrapper dpad steps from a real position")
  local code = directionCode(direction)
  local input = neighborInDirection(boxes[pos + 1], code) % 256
  -- A flagged neighbor links back through the recorded position when
  -- one exists, else strips its flag like the source.
  if input >= 128 then
    if prev ~= nil then
      input = prev
    else
      input = input - 128
    end
  end
  -- No enabled mask is ever staged for these pages
  -- (BattlePartyMenu_SetPageCursor sets none), so every box admits and
  -- the source skip loop never advances.
  assert(type(boxes[input + 1]) == "table", "wrapper dpad neighbors stay on their page")
  if input == pos then
    return { pos = pos, prev = prev, moved = false }
  end
  local next = nil
  if hasReturnLink(boxes[input + 1], code) then
    next = pos
  end
  return { pos = input, prev = next, moved = true }
end

return BattlePartyPages
