-- Retail battle-bag pocket grouping (battle_bag_menu.c
-- AddItemToBattlePockets, battle_menu_data.s sBattleBagPocketOrder).
-- Bit->pocket map [2,3,0,1,0]: bit0 BALLS, bit1 BATTLE ITEMS, bit2 HP/PP,
-- bit3 STATUS, bit4 HP/PP. Mask 0 stays hidden in battle. Within-pocket
-- order follows native id ascending as the interim deterministic stand-in
-- for saved-bag slot order (SortItemsIntoPockets appends in bag-slot
-- order; the detached inventory map has no slot order yet). Pure data
-- projection: no love, no I/O.

local BattleBagPockets = {}

-- Zero-based bit index to zero-based battle pocket index, transcribed
-- from sBattleBagPocketOrder (.byte 0x02,0x03,0x00,0x01,0x00).
BattleBagPockets.BIT_TO_POCKET = { [0] = 2, [1] = 3, [2] = 0, [3] = 1, [4] = 0 }

-- Zero-based pocket index order: 0 HP/PP, 1 STATUS, 2 BALLS, 3 BATTLE ITEMS.
BattleBagPockets.POCKET_KEYS = { "hp_pp", "status", "balls", "battle_items" }

-- Retail touchscreen hitboxes transcribed from battle_menu_data.s
-- (top,bottom,left,right per touchscreen.h). Indices match the Handle
-- input orders exactly: pocket menu 0-3 pockets, 4 last-used, 5 cancel;
-- item list 0-5 cells, 6 cancel, 7 prev page, 8 next page; use-item
-- 0 USE, 1 cancel.
BattleBagPockets.HITBOXES = {
  pocketMenu = {
    { top = 8, bottom = 79, left = 0, right = 127 },
    { top = 80, bottom = 151, left = 0, right = 127 },
    { top = 8, bottom = 79, left = 128, right = 255 },
    { top = 80, bottom = 151, left = 128, right = 255 },
    { top = 152, bottom = 191, left = 0, right = 207 },
    { top = 152, bottom = 191, left = 216, right = 255 },
  },
  itemList = {
    { top = 8, bottom = 55, left = 0, right = 127 },
    { top = 8, bottom = 55, left = 128, right = 255 },
    { top = 56, bottom = 103, left = 0, right = 127 },
    { top = 56, bottom = 103, left = 128, right = 255 },
    { top = 104, bottom = 151, left = 0, right = 127 },
    { top = 104, bottom = 151, left = 128, right = 255 },
    { top = 152, bottom = 191, left = 216, right = 255 },
    { top = 152, bottom = 191, left = 0, right = 39 },
    { top = 152, bottom = 191, left = 40, right = 79 },
  },
  useItem = {
    { top = 152, bottom = 191, left = 0, right = 207 },
    { top = 152, bottom = 191, left = 216, right = 255 },
  },
}

-- Center-anchored item icon spots (battle_bag_menu.c ShowPageSprites
-- family): six list positions from sBattleBagItemListIconPos with the
-- fixed last-used (ShowLastUsedItemIcon) and use-item (ShowUseItemIcon)
-- sprite spots. Sprites center on these spots: code_entry.c seats its
-- button sprites at hitbox midpoints through the same ManagedSprite
-- positioning, and the centers sit inside their rows while top-left
-- corners would overflow them.
BattleBagPockets.ICON_SPOTS = {
  list = {
    { x = 44, y = 45 },
    { x = 172, y = 45 },
    { x = 44, y = 93 },
    { x = 172, y = 93 },
    { x = 44, y = 141 },
    { x = 172, y = 141 },
  },
  lastUsed = { x = 24, y = 178 },
  useItem = { x = 40, y = 44 },
}

-- Zero-based battle pocket index behind a pocket key, for palette
-- bank lookups that only know the staged key.
---@param key string? battle pocket key under lookup
---@return integer? zero-based pocket index, nil for unknown keys
function BattleBagPockets.pocketIndex(key)
  for index, pocketKey in ipairs(BattleBagPockets.POCKET_KEYS) do
    if pocketKey == key then
      return index - 1
    end
  end
  return nil
end

-- Retail button identities behind the press animation and disabled
-- faces (BattleBagMenu_GetButtonTilemap): 0-3 pockets, 4 last-used, 5
-- pocket cancel, 6-11 item cells, 12 prev page, 13 next page, 14 list
-- cancel, 15 USE, 16 use cancel. Page steppers and cancels share their
-- tile art across pages; the control map below names the button behind
-- each stable hit identity per browser page.
BattleBagPockets.BUTTON_FOR = {
  pocket_menu = {
    ["bagpocket:0"] = 0,
    ["bagpocket:1"] = 1,
    ["bagpocket:2"] = 2,
    ["bagpocket:3"] = 3,
    last_used = 4,
    back = 5,
  },
  item_list = {
    ["bag:0"] = 6,
    ["bag:1"] = 7,
    ["bag:2"] = 8,
    ["bag:3"] = 9,
    ["bag:4"] = 10,
    ["bag:5"] = 11,
    page_prev = 12,
    page_next = 13,
    back = 14,
  },
  use_item = { use = 15, back = 16 },
  message = { use = 15, back = 16 },
}

-- Retail button palette banks behind the press faces
-- (BattleBagMenu_GetButtonPalette, frames 0-2; frame 3 always rides
-- bank 5): pockets bank 0, last-used 3, cancels and steppers 2, item
-- cells and USE the current pocket bank (pocket + 8).
---@param button integer retail button identity under lookup
---@param pocket integer zero-based battle pocket under lookup
---@return integer sixteen-color palette bank
function BattleBagPockets.buttonBank(button, pocket)
  assert(type(button) == "number" and button % 1 == 0 and button >= 0 and button <= 16, "buttons span 0..16")
  assert(type(pocket) == "number" and pocket % 1 == 0 and pocket >= 0 and pocket <= 3, "pockets span 0..3")
  if button >= 0 and button <= 3 then
    return 0
  end
  if button == 4 then
    return 3
  end
  if button == 5 or button == 12 or button == 13 or button == 14 or button == 16 then
    return 2
  end
  return pocket + 8
end

-- Page origins in the 512x512 bag screen map (SetPageBgOffset: page 0
-- at (0,0), page 1 at (0x100,0), page 2 at (0,0x100)). BUTTON_RECTS ride
-- map space; subtract the visible page origin for page-relative paint.
BattleBagPockets.PAGE_ORIGINS = {
  pocket_menu = { x = 0, y = 0 },
  item_list = { x = 256, y = 0 },
  use_item = { x = 0, y = 256 },
  message = { x = 0, y = 256 },
}

-- Focused cursor corners for the visible browser page
-- (BattleDpadCursor_SetRect over sBattleBagPageCursorBoxes): four
-- corner draws framing the focused box while the cursor is active
-- (BattleDpadCursor_TryActivate: set by the first key press, cleared
-- by touch). Sprites center on the corners like the item spots.
-- Retail ticks every corner sprite each task (BattleCursor_Update)
-- through a per-frame translate pulse, so the tick selects the
-- duration-weighted frame offset and a focus move restarts at zero
-- offset because SetRect reseats the animation.
-- Pure data projection: callers resolve drawables.
---@param native table<string, unknown>? detached bag browser status under reading
---@param bagPage string visible browser page under projection
---@param focusId string? projected focus identity under projection
---@param tick integer? presentation tick behind the corner shimmer under projection
---@param frames table<string, table<string, unknown>>? staged corner records with frame durations and offsets by corner under projection
---@return table<integer, { key: string, x: integer, y: integer }> corner draws in TL/TR/BL/BR order
function BattleBagPockets.cursorDraws(native, bagPage, focusId, tick, frames)
  local function frameOffset(corner)
    local staged = type(frames) == "table" and frames[corner] or nil
    local list = type(staged) == "table" and staged.frames or nil
    if type(list) ~= "table" then
      return 0, 0
    end
    local total = 0
    for _, frame in ipairs(list) do
      total = total + (tonumber(frame.duration) or 0)
    end
    if total <= 0 then
      return 0, 0
    end
    local elapsed = 0
    local at = (tonumber(tick) or 0) % total
    for _, frame in ipairs(list) do
      local duration = tonumber(frame.duration) or 0
      if duration > 0 and at < elapsed + duration then
        return tonumber(frame.x) or 0, tonumber(frame.y) or 0
      end
      elapsed = elapsed + duration
    end
    return 0, 0
  end
  if type(native) ~= "table" or native.open == false or native.cursorActive ~= true then
    return {}
  end
  local boxes = BattleBagPockets.CURSOR_BOXES[bagPage]
  if boxes == nil and bagPage == "message" then
    -- The message page borrows no cursor page of its own (ShowMessage
    -- never reseats the cursor): it keeps the use-item boxes behind
    -- the refusal.
    boxes = BattleBagPockets.CURSOR_BOXES.use_item
  end
  boxes = boxes or BattleBagPockets.CURSOR_BOXES.item_list
  local index = nil
  if bagPage == "pocket_menu" then
    local pocket = tonumber(type(focusId) == "string" and focusId:match("^bagpocket:(%d+)$") or "")
    if pocket ~= nil and pocket % 1 == 0 and pocket >= 0 and pocket <= 3 then
      index = pocket + 1
    elseif focusId == "last_used" then
      index = 5
    elseif focusId == "back" then
      index = 6
    end
  elseif bagPage == "use_item" or bagPage == "message" then
    if focusId == "use" then
      index = 1
    elseif focusId == "back" then
      index = 2
    end
  else
    local cell = tonumber(type(focusId) == "string" and focusId:match("^bag:(%d+)$") or "")
    if cell ~= nil and cell % 1 == 0 and cell >= 0 and cell <= 5 then
      index = cell + 1
    elseif focusId == "back" then
      index = 7
    end
  end
  local box = type(index) == "number" and boxes[index] or nil
  if box == nil then
    return {}
  end
  local corners = { "tl", "tr", "bl", "br" }
  local spots = {
    { x = box.x, y = box.y },
    { x = box.x + box.w, y = box.y },
    { x = box.x, y = box.y + box.h },
    { x = box.x + box.w, y = box.y + box.h },
  }
  local draws = {}
  for i = 1, 4 do
    local dx, dy = frameOffset(corners[i])
    draws[i] = {
      key = "battle:cursor-" .. corners[i],
      x = spots[i].x + dx,
      y = spots[i].y + dy,
    }
  end
  return draws
end
-- 17 entries of (x, y, width, height) tile units from 0x02225E9C).
-- Buttons 0-3 are the pocket buttons, 4 the last-used shortcut, 5/14/16
-- the cancel button, 6-11 the item cells, 12/13 the page steppers, and
-- 15 the USE button. Tile coords ride LoadRectToBgTilemapRect; multiply
-- by 8 for pixels. The pocket tile rects sit exactly behind the
-- touchscreen hitboxes above (e.g. button 2 at tiles (16,1,16,9) is
-- pixels (128,8,128,72) behind hitbox 2 at (128,8,127,71)).
BattleBagPockets.BUTTON_RECTS = {
  { x = 0, y = 1, width = 16, height = 9 },
  { x = 0, y = 10, width = 16, height = 9 },
  { x = 16, y = 1, width = 16, height = 9 },
  { x = 16, y = 10, width = 16, height = 9 },
  { x = 0, y = 19, width = 26, height = 5 },
  { x = 27, y = 19, width = 5, height = 5 },
  { x = 32, y = 1, width = 16, height = 6 },
  { x = 48, y = 1, width = 16, height = 6 },
  { x = 32, y = 7, width = 16, height = 6 },
  { x = 48, y = 7, width = 16, height = 6 },
  { x = 32, y = 13, width = 16, height = 6 },
  { x = 48, y = 13, width = 16, height = 6 },
  { x = 32, y = 19, width = 5, height = 5 },
  { x = 37, y = 19, width = 5, height = 5 },
  { x = 59, y = 19, width = 5, height = 5 },
  { x = 0, y = 51, width = 26, height = 5 },
  { x = 27, y = 51, width = 5, height = 5 },
}

-- Retail D-pad cursor boxes (battle_menu_data.s sBattleBagPage0CursorBoxes,
-- sBattleBagPage1CursorBoxes, sBattleBagPage2CursorBoxes): pixel boxes
-- with (up, down, left, right) neighbor indices. Page 0 carries the
-- four pockets plus last-used (4) and cancel (5); page 1 carries the
-- six cells plus Back (6); page 2 carries USE (0) and Back (1).
-- The 0x80 bit on a neighbor marks the cancel-adjacent edge
-- (Page0 box 5 up 0x83, Page1 Back up 0x85); the low 7 bits name the
-- neighbor. Edge motion against a multi-page item grid turns the page
-- instead (HandleItemListInput), it never leaves the grid.
BattleBagPockets.CURSOR_BOXES = {
  pocket_menu = {
    { x = 8, y = 16, w = 112, h = 56, up = 0, down = 1, left = 0, right = 2 },
    { x = 8, y = 88, w = 112, h = 56, up = 0, down = 4, left = 1, right = 3 },
    { x = 136, y = 16, w = 112, h = 56, up = 2, down = 3, left = 0, right = 2 },
    { x = 136, y = 88, w = 112, h = 56, up = 2, down = 5, left = 1, right = 3 },
    { x = 8, y = 160, w = 192, h = 24, up = 1, down = 4, left = 4, right = 5 },
    { x = 224, y = 160, w = 24, h = 24, up = 3, down = 5, left = 4, right = 5 },
  },
  item_list = {
    { x = 8, y = 16, w = 112, h = 32, up = 0, down = 2, left = 0, right = 1 },
    { x = 136, y = 16, w = 112, h = 32, up = 1, down = 3, left = 0, right = 1 },
    { x = 8, y = 64, w = 112, h = 32, up = 0, down = 4, left = 2, right = 3 },
    { x = 136, y = 64, w = 112, h = 32, up = 1, down = 5, left = 2, right = 3 },
    { x = 8, y = 112, w = 112, h = 32, up = 2, down = 6, left = 4, right = 5 },
    { x = 136, y = 112, w = 112, h = 32, up = 3, down = 6, left = 4, right = 5 },
    { x = 224, y = 160, w = 24, h = 24, up = 5, down = 6, left = 6, right = 6 },
  },
  use_item = {
    { x = 8, y = 160, w = 192, h = 24, up = 0, down = 0, left = 0, right = 1 },
    { x = 224, y = 160, w = 24, h = 24, up = 1, down = 1, left = 0, right = 1 },
  },
}

-- Retail window templates (battle_menu_data.s WindowTemplate is 8 bytes:
-- bg, left, top, width, height, palette, baseTile u16 LE).
-- Pocket menu (5), item list (26: two 12-window banks plus pocket-name
-- and page-number windows), use-item (4), and message (1) windows.
-- Transcribed from 0x02225B90/0x02225B98/0x02225BB8/0x02225C10.
BattleBagPockets.WINDOWS = {
  message = { { bg = 4, left = 2, top = 19, width = 27, height = 4, palette = 15, baseTile = 0x0376 } },
  useItem = {
    { bg = 5, left = 7, top = 4, width = 12, height = 2, palette = 4, baseTile = 0x02C7 },
    { bg = 5, left = 20, top = 4, width = 4, height = 2, palette = 4, baseTile = 0x02DF },
    { bg = 5, left = 2, top = 9, width = 28, height = 6, palette = 4, baseTile = 0x02E7 },
    { bg = 5, left = 8, top = 20, width = 10, height = 3, palette = 0, baseTile = 0x038F },
  },
  pocketMenu = {
    { bg = 4, left = 2, top = 4, width = 12, height = 5, palette = 0, baseTile = 0x02CE },
    { bg = 4, left = 2, top = 13, width = 12, height = 5, palette = 0, baseTile = 0x030A },
    { bg = 4, left = 18, top = 5, width = 12, height = 3, palette = 0, baseTile = 0x0286 },
    { bg = 4, left = 18, top = 14, width = 12, height = 3, palette = 0, baseTile = 0x02AA },
    { bg = 4, left = 5, top = 20, width = 20, height = 3, palette = 0, baseTile = 0x024A },
  },
}

-- Retail text styles behind each bag printer (battle_bag_menu.c Print*
-- family): font id plus MAKE_TEXT_COLOR(fg, shadow, bg) slots out of
-- the staged bag window palette. List and pocket-menu names ride font 4
-- (3,2,1) centered on their windows; quantities, pocket names, page
-- numbers, use-item names, and descriptions ride font 0 (1,2,0); the
-- refusal message rides font 1 through the narration role into the
-- palette-15 message window with AB speedup.
BattleBagPockets.TEXT_STYLES = {
  pocketName = { font = 4, fg = 3, shadow = 2, bg = 1 },
  itemName = { font = 4, fg = 3, shadow = 2, bg = 1 },
  itemQuantity = { font = 0, fg = 1, shadow = 2, bg = 0 },
  pocketTitle = { font = 0, fg = 1, shadow = 2, bg = 0 },
  pageNumber = { font = 0, fg = 1, shadow = 2, bg = 0 },
  useName = { font = 0, fg = 1, shadow = 2, bg = 0 },
  useDescription = { font = 0, fg = 1, shadow = 2, bg = 0 },
  useButton = { font = 4, fg = 3, shadow = 2, bg = 1 },
  message = { font = 1, fg = 1, shadow = 2, bg = 15 },
}

-- Tutorial finger spots per browser page (battle_bag_menu.c
-- UpdateTutorialFinger reading sBattleBagTutorialFingerPos[page][0] and
-- sBattleBagTutorialFingerPosY[page][0] in asm/battle_menu_data.s):
-- pocket menu (192,24) over the balls button, item list (64,16) over the
-- first cell, use item (104,152) over USE. The finger centers on these
-- spots like the item sprites.
BattleBagPockets.TUTORIAL_FINGER_SPOTS = {
  pocket_menu = { x = 192, y = 24 },
  item_list = { x = 64, y = 16 },
  use_item = { x = 104, y = 152 },
  message = { x = 104, y = 152 },
}

-- Control identities behind the retail hitbox order per browser page.
BattleBagPockets.PAGE_CONTROLS = {
  pocket_menu = { "bagpocket:0", "bagpocket:1", "bagpocket:2", "bagpocket:3", "last_used", "back" },
  item_list = { "bag:0", "bag:1", "bag:2", "bag:3", "bag:4", "bag:5", "back", "page_prev", "page_next" },
  use_item = { "use", "back" },
  message = { "use", "back" },
}

---@param boxes table<integer, table<string, integer>> transcribed hitboxes under testing
---@param x number tap horizontal position under testing
---@param y number tap vertical position under testing
---@return integer? zero-based hit index, nil outside every box
function BattleBagPockets.hitIndex(boxes, x, y)
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  for index, box in ipairs(boxes) do
    -- Retail range check (touchscreen.c FindRectAtPoint): the
    -- subtraction is unsigned, so the lower bounds bind as well as the
    -- upper ones. Lua numbers never wrap, so the bounds stay explicit.
    if x >= box.left and x < box.right and y >= box.top and y < box.bottom then
      return index - 1
    end
  end
  return nil
end

---@param bagPage string browser page under mapping
---@return table<integer, table<string, unknown>> hit regions with stable control identities
function BattleBagPockets.hitRegions(bagPage)
  local key = "itemList"
  if bagPage == "pocket_menu" then
    key = "pocketMenu"
  elseif bagPage == "use_item" or bagPage == "message" then
    key = "useItem"
  end
  local boxes = BattleBagPockets.HITBOXES[key]
  local ids = BattleBagPockets.PAGE_CONTROLS[bagPage] or BattleBagPockets.PAGE_CONTROLS.item_list
  local regions = {}
  for index, id in ipairs(ids) do
    local box = assert(boxes[index], "bag hitboxes carry every retail index")
    regions[#regions + 1] = {
      id = id,
      x = box.left,
      y = box.top,
      w = box.right - box.left,
      h = box.bottom - box.top,
    }
  end
  return regions
end

-- Centered item icon draws for the visible browser page (battle_bag_menu.c
-- ShowPageSprites family): list cells ride their table spots, the
-- pocket menu shows the validated last-used item, and the use-item and
-- message pages show the chosen item. Empty cells and closed browsers
-- draw nothing. Pure data projection: callers resolve drawables.
---@param native table<string, unknown>? detached bag browser status under reading
---@return table<integer, { key: string, x: integer, y: integer }> centered icon draws in page order
function BattleBagPockets.iconDraws(native)
  local draws = {}
  if type(native) ~= "table" or native.open == false then
    return draws
  end
  local bagPage = type(native.bagPage) == "string" and native.bagPage or "item_list"
  if bagPage == "pocket_menu" then
    local lastUsed = native.lastUsed
    if type(lastUsed) == "table" and type(lastUsed.item) == "string" then
      local spot = BattleBagPockets.ICON_SPOTS.lastUsed
      draws[#draws + 1] = { key = lastUsed.item, x = spot.x, y = spot.y }
    end
    return draws
  end
  if bagPage == "use_item" or bagPage == "message" then
    local useItem = native.useItem
    if type(useItem) == "table" and type(useItem.item) == "string" then
      local spot = BattleBagPockets.ICON_SPOTS.useItem
      draws[#draws + 1] = { key = useItem.item, x = spot.x, y = spot.y }
    end
    return draws
  end
  local cells = native.visibleSlots
  if type(cells) ~= "table" then
    return draws
  end
  for index = 1, 6 do
    local cell = cells[index]
    local spot = BattleBagPockets.ICON_SPOTS.list[index]
    if type(cell) == "table" and cell.empty ~= true and type(cell.item) == "string" and spot ~= nil then
      draws[#draws + 1] = { key = cell.item, x = spot.x, y = spot.y }
    end
  end
  return draws
end

-- Staged label keys behind each battle pocket (msg 0005 pocket names and
-- list headers). Producer owns the bank/member selection; runtime
-- resolves the text.
BattleBagPockets.POCKET_LABEL_KEYS = {
  "battle/bag/pocket/hp-pp",
  "battle/bag/pocket/status",
  "battle/bag/pocket/balls",
  "battle/bag/pocket/battle-items",
}

BattleBagPockets.LIST_LABEL_KEYS = {
  "battle/bag/list-pocket/hp-pp",
  "battle/bag/list-pocket/status",
  "battle/bag/list-pocket/balls",
  "battle/bag/list-pocket/battle-items",
}

-- Retail item-list pocket title lines per battle pocket
-- (PrintPocketName msg 22-27): HP/PP prints 22+23, STATUS 24+25,
-- BALLS 26, BATTLE ITEMS 27.
BattleBagPockets.LIST_TITLE_KEYS = {
  { "battle/bag/list-pocket/hp-pp", "battle/bag/list-pocket/restore" },
  { "battle/bag/list-pocket/status", "battle/bag/list-pocket/healers" },
  { "battle/bag/list-pocket/balls" },
  { "battle/bag/list-pocket/battle-items" },
}

---@param mask integer 5-bit battlePocket mask under mapping
---@return table<integer, integer> zero-based pocket indices in bit order, no duplicates
function BattleBagPockets.pocketsForMask(mask)
  assert(type(mask) == "number" and mask % 1 == 0 and mask >= 0 and mask <= 31, "battle masks span 0..31")
  local out = {}
  local seen = {}
  for bit = 0, 4 do
    if math.floor(mask / (2 ^ bit)) % 2 == 1 then
      local pocket = BattleBagPockets.BIT_TO_POCKET[bit]
      assert(type(pocket) == "number", "every battle bit maps to a pocket")
      if seen[pocket] ~= true then
        seen[pocket] = true
        out[#out + 1] = pocket
      end
    end
  end
  return out
end

---@param inventory table<string, integer> detached battle stock under grouping
---@param catalog table<string, unknown> borrowed immutable item catalog
---@param slotOrder string[]? stocked keys in saved-bag slot order under grouping
---@return table<string, table<integer, table<string, unknown>>> grouped slots by battle pocket key
function BattleBagPockets.group(inventory, catalog, slotOrder)
  assert(type(inventory) == "table", "the battle bag reads its detached stock")
  assert(type(catalog) == "table", "grouping resolves items through the catalog")
  local lookup = catalog.item --[[@as fun(collab: table<string, unknown>, key: string): table<string, unknown>]]
  assert(type(lookup) == "function", "the item catalog answers item records")
  local rank = nil ---@type table<string, integer>?
  if slotOrder ~= nil then
    assert(type(slotOrder) == "table", "the bag slot order arrives as a sequence")
    rank = {}
    for index, key in ipairs(slotOrder) do
      assert(type(key) == "string" and key ~= "", "bag slot order names its items")
      assert(rank[key] == nil, "bag slot order names each item once")
      rank[key] = index
    end
  end
  local groups = { hp_pp = {}, status = {}, balls = {}, battle_items = {} }
  for key, quantity in pairs(inventory) do
    if type(key) == "string" and type(quantity) == "number" and quantity >= 1 then
      local definition = lookup(catalog, key)
      assert(type(definition) == "table", "stocked items resolve through the catalog")
      local rawMask = tonumber(definition.battlePocket) or 0
      assert(rawMask % 1 == 0 and rawMask >= 0 and rawMask <= 31, "battle masks span 0..31")
      local mask = rawMask --[[@as integer]]
      for _, pocket in ipairs(BattleBagPockets.pocketsForMask(mask)) do
        local pocketKey = BattleBagPockets.POCKET_KEYS[pocket + 1]
        groups[pocketKey][#groups[pocketKey] + 1] = {
          item = key,
          quantity = quantity,
          nativeId = definition.nativeId,
        }
      end
    end
  end
  -- Within-pocket order follows saved-bag slot order
  -- (SortItemsIntoPockets appends in bag-slot order). Stock without a
  -- carried order keeps the deterministic native-id stand-in.
  for _, list in pairs(groups) do
    if rank ~= nil then
      for _, entry in ipairs(list) do
        entry.order = assert(rank[entry.item], "bag slot order names every stocked item")
      end
    end
    table.sort(list, function(a, b)
      if a.order ~= nil or b.order ~= nil then
        assert(a.order ~= nil and b.order ~= nil, "bag slot order names every stocked item")
        return a.order < b.order
      end
      if a.nativeId ~= b.nativeId then
        return a.nativeId < b.nativeId
      end
      return a.item < b.item
    end)
    for _, entry in ipairs(list) do
      entry.order = nil
    end
  end
  return groups
end

-- Tutorial finger draw for the visible browser page (battle_bag_menu.c
-- UpdateTutorialFinger): the finger centers on its per-page spot while
-- the tutorial auto-plays, and draws nothing outside tutorial mode.
-- Pure data projection: callers resolve drawables.
---@param native table<string, unknown>? detached bag browser status under reading
---@return { key: string, x: integer, y: integer }? centered finger draw, nil outside tutorial mode
function BattleBagPockets.fingerDraw(native)
  if type(native) ~= "table" or native.open == false or native.tutorial ~= true then
    return nil
  end
  local bagPage = type(native.bagPage) == "string" and native.bagPage or "item_list"
  local spot = BattleBagPockets.TUTORIAL_FINGER_SPOTS[bagPage] or BattleBagPockets.TUTORIAL_FINGER_SPOTS.item_list
  return { key = "battle:finger", x = spot.x, y = spot.y }
end

return BattleBagPockets
