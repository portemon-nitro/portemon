-- Source geometry of the PC Storage box screen (touch screen, 256x192).
-- Authority: the retail ROM — the touch hit table, the box icon sprite
-- placement, and the wallpaper tilemap writer.

local PcStorageGeometry = {}

PcStorageGeometry.BOX_COLUMNS = 6
PcStorageGeometry.BOX_ROWS = 5
PcStorageGeometry.SLOT_SIZE = 24
-- The 168x160 wallpaper tilemap starts one tile row below the screen top.
PcStorageGeometry.WALLPAPER = { x = 0, y = 8 }

local BOX_ORIGIN = { x = 12, y = 40 }

---@param slot integer zero-based box slot
---@return { x: integer, y: integer, width: integer, height: integer }
function PcStorageGeometry.boxSlotRect(slot)
  local column, row = slot % PcStorageGeometry.BOX_COLUMNS, math.floor(slot / PcStorageGeometry.BOX_COLUMNS)
  local size = PcStorageGeometry.SLOT_SIZE
  return { x = BOX_ORIGIN.x + column * size, y = BOX_ORIGIN.y + row * size, width = size, height = size }
end

-- The party tray is an 88x144 strip that slides in at the left (x=16) or the
-- right band (x=168) of the touch screen; its 32x32 icons are centred at these
-- offsets from its origin.
PcStorageGeometry.PARTY_TRAY_SIZE = { width = 88, height = 144 }
PcStorageGeometry.PARTY_TRAY_ORIGINS = { left = { x = 16, y = 48 }, right = { x = 168, y = 48 } }
PcStorageGeometry.PARTY_ICON_SIZE = 32
local PARTY_ICON_CENTERS = { { 24, 16 }, { 64, 24 }, { 24, 48 }, { 64, 56 }, { 24, 80 }, { 64, 88 } }

---@param slot integer zero-based party slot
---@param side "left"|"right"
---@return { x: integer, y: integer, width: integer, height: integer } icon rectangle on the touch screen
function PcStorageGeometry.partySlotRect(slot, side)
  local center = assert(PARTY_ICON_CENTERS[slot + 1], "party slot is within the six-slot tray")
  local origin = assert(PcStorageGeometry.PARTY_TRAY_ORIGINS[side], "party tray side is left or right")
  local half = PcStorageGeometry.PARTY_ICON_SIZE / 2
  return {
    x = origin.x + center[1] - half,
    y = origin.y + center[2] - half,
    width = PcStorageGeometry.PARTY_ICON_SIZE,
    height = PcStorageGeometry.PARTY_ICON_SIZE,
  }
end

-- Action buttons are 88x24 strips in the right panel; a list of n actions
-- fills the bottom n of its five slots (the bottom alignment follows the
-- retail window-id arithmetic).
PcStorageGeometry.ACTION_SLOTS = 5
-- The source list carries a per-entry kind: MOVE (kind 1) draws with the tab
-- plate and its own palette, every other entry with the framed button plate.
PcStorageGeometry.ACTION_STYLES = { move = "tab" }

---@param action string
---@return string? style "tab" for the tab-styled list entry
function PcStorageGeometry.actionStyle(action)
  return PcStorageGeometry.ACTION_STYLES[action]
end

---@param count integer number of actions listed
---@param index integer zero-based position within the list
---@return { x: integer, y: integer, width: integer, height: integer }
function PcStorageGeometry.actionButtonRect(count, index)
  assert(count >= 1 and count <= PcStorageGeometry.ACTION_SLOTS, "an action list fits the five button slots")
  return { x = 168, y = 40 + 24 * (PcStorageGeometry.ACTION_SLOTS - count + index), width = 88, height = 24 }
end

-- The marking panel replaces the tray; its six 16x16 marks sit at these
-- touch rectangles (two columns, three rows).
---@param bit integer zero-based mark
---@return { x: integer, y: integer, width: integer, height: integer }
function PcStorageGeometry.markingRect(bit)
  return { x = 188 + 32 * (bit % 2), y = 60 + 24 * math.floor(bit / 2), width = 16, height = 16 }
end

-- Wallpaper chooser: a row
-- of four swatch slots centred on x = 59 + 46k inside a 256x56 bar, page
-- arrows at both edges, a confirm button strip and Cancel.
PcStorageGeometry.WALLPAPER_PAGE_SIZE = 4
PcStorageGeometry.WALLPAPER_ARROW_CENTERS = { left = { x = 12, y = 35 }, right = { x = 244, y = 35 } }
PcStorageGeometry.WALLPAPER_ARROW_RECTS = {
  left = { x = 2, y = 23, width = 22, height = 24 },
  right = { x = 232, y = 23, width = 22, height = 24 },
}
PcStorageGeometry.WALLPAPER_CONFIRM_RECT = { x = 168, y = 112, width = 88, height = 48 }
PcStorageGeometry.WALLPAPER_CANCEL_RECT = { x = 192, y = 168, width = 64, height = 24 }

---@param slot integer zero-based swatch slot within the page
---@return { x: integer, y: integer, width: integer, height: integer }
function PcStorageGeometry.wallpaperSlotRect(slot)
  return { x = 59 + 46 * slot - 12, y = 23, width = 24, height = 24 }
end

-- Box title plate and box arrows: the
-- plate opens the Wallpaper / Name pair; the arrows step to the neighbour box.
PcStorageGeometry.BOX_TITLE_RECT = { x = 26, y = 17, width = 116, height = 22 }
PcStorageGeometry.BOX_ARROW_CENTERS = { left = { x = 12, y = 28 }, right = { x = 156, y = 28 } }
PcStorageGeometry.BOX_ARROW_RECTS = {
  left = { x = 1, y = 17, width = 22, height = 22 },
  right = { x = 145, y = 17, width = 22, height = 22 },
}

-- Box tray and deposit box selector (source panel/sprite geometry).
PcStorageGeometry.BOX_TRAY_PANEL = { x = 0, y = 0, width = 256, height = 48 }
PcStorageGeometry.DEPOSIT_TRAY_PANEL = { x = 0, y = 48, width = 256, height = 56 }
PcStorageGeometry.DEPOSIT_TRAY_BACKDROP = { x = 0, y = 32, width = 256, height = 88 }
PcStorageGeometry.TRAY_PAGE_SIZE = 6
PcStorageGeometry.TRAY_BOX_SIZE = 32
PcStorageGeometry.TRAY_BOX_CENTERS = { 43, 77, 111, 145, 179, 213 }
PcStorageGeometry.TRAY_CURSOR_X = { 80, 96, 112, 144, 160, 176 }
PcStorageGeometry.TRAY_ARROW_CENTERS = { prev = { x = 12, y = 27 }, next = { x = 244, y = 27 } }
PcStorageGeometry.DEPOSIT_ARROW_CENTERS = { prev = { x = 12, y = 84 }, next = { x = 244, y = 84 } }
PcStorageGeometry.TRAY_PLATE_Y = 8
PcStorageGeometry.DEPOSIT_PLATE_Y = 65
PcStorageGeometry.TRAY_NAME_OFFSET = { x = -72, y = -8 }
PcStorageGeometry.TRAY_COUNT_OFFSET = { x = 32, y = -8 }
PcStorageGeometry.TRAY_BOX_TOP = 11
PcStorageGeometry.DEPOSIT_BOX_TOP = 68
PcStorageGeometry.TRAY_CHANGE_BOX_RECT = { x = 0, y = 168, width = 136, height = 24 }
PcStorageGeometry.DEPOSIT_TITLE_RECT = { x = 176, y = 128, width = 72, height = 32 }
PcStorageGeometry.DEPOSIT_CONFIRM_RECT = { x = 168, y = 112, width = 88, height = 48 }

---@param column integer zero-based tray column
---@param deposit boolean?
---@return { x: integer, y: integer, width: integer, height: integer }
function PcStorageGeometry.traySlotRect(column, deposit)
  local center = assert(PcStorageGeometry.TRAY_BOX_CENTERS[column + 1], "tray column is within the page")
  local top = deposit and PcStorageGeometry.DEPOSIT_BOX_TOP or PcStorageGeometry.TRAY_BOX_TOP
  local size = PcStorageGeometry.TRAY_BOX_SIZE
  return { x = center - size / 2, y = top, width = size, height = size }
end

-- Custody drop geometry. The drag resolver is PCBox_IsPointInRect
-- (x >= left && x <= right && y >= top && y < bottom) over the box grid rect
-- and the per-panel party drop rects; the tray thumbnails keep their own
-- 24x23 source rects.
PcStorageGeometry.BOX_DROP_BOUNDS = { left = 8, right = 159, top = 40, bottom = 159 }
local PARTY_DROP_COLUMNS = {
  left = { 26, 62 },
  right = { 178, 214 },
}
local PARTY_DROP_ROWS = { 58, 90, 122 }
PcStorageGeometry.PARTY_DROP_SIZE = { width = 32, height = 23 }
local TRAY_DROP = { left = 31, pitch = 34, width = 24, height = 23, top = 15, depositTop = 71 }

-- PCBox_GetTouchedBoxSlot: the grid rect clamps the edge columns rather than
-- rejecting points in the outer gutter.
---@param x number
---@param y number
---@return integer? zero-based box slot
function PcStorageGeometry.boxDropSlot(x, y)
  local bounds = PcStorageGeometry.BOX_DROP_BOUNDS
  if x < bounds.left or x > bounds.right or y < bounds.top or y > bounds.bottom then
    return nil
  end
  local column
  if x < 12 then
    column = 0
  elseif x >= 156 then
    column = PcStorageGeometry.BOX_COLUMNS - 1
  else
    column = math.floor((x - 12) / PcStorageGeometry.SLOT_SIZE)
  end
  local row = math.floor((y - bounds.top) / PcStorageGeometry.SLOT_SIZE)
  return row * PcStorageGeometry.BOX_COLUMNS + column
end

---@param slot integer zero-based party slot
---@param side "left"|"right"
---@return { x: integer, y: integer, width: integer, height: integer }
function PcStorageGeometry.partyDropRect(slot, side)
  local columns = assert(PARTY_DROP_COLUMNS[side], "party drop side is left or right")
  local x = columns[slot % 2 + 1]
  local row = math.floor(slot / 2)
  local y = PARTY_DROP_ROWS[row + 1] + slot % 2 * 8
  return {
    x = x,
    y = y,
    width = PcStorageGeometry.PARTY_DROP_SIZE.width,
    height = PcStorageGeometry.PARTY_DROP_SIZE.height,
  }
end

---@param x number
---@param y number
---@param side "left"|"right"
---@return integer? zero-based party slot
function PcStorageGeometry.partyDropSlot(x, y, side)
  for slot = 0, 5 do
    local rect = PcStorageGeometry.partyDropRect(slot, side)
    if x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height then
      return slot
    end
  end
  return nil
end

---@param column integer zero-based tray column
---@param deposit boolean?
---@return { x: integer, y: integer, width: integer, height: integer }
function PcStorageGeometry.trayDropRect(column, deposit)
  assert(column >= 0 and column < PcStorageGeometry.TRAY_PAGE_SIZE, "tray drop column is within the page")
  return {
    x = TRAY_DROP.left + column * TRAY_DROP.pitch,
    y = deposit and TRAY_DROP.depositTop or TRAY_DROP.top,
    width = TRAY_DROP.width,
    height = TRAY_DROP.height,
  }
end

---@param x number
---@param y number
---@param deposit boolean?
---@return integer? zero-based tray column
function PcStorageGeometry.trayDropColumn(x, y, deposit)
  for column = 0, PcStorageGeometry.TRAY_PAGE_SIZE - 1 do
    local rect = PcStorageGeometry.trayDropRect(column, deposit)
    if x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height then
      return column
    end
  end
  return nil
end

-- Release animation contract (PCBox_StartReleaseScale/UpdateReleaseShrink/
-- UpdateReleaseGrow): the shrink runs 40 fixed ticks at -0.025 scale, and the
-- protected move's grow-back runs 20 ticks at +0.05.
PcStorageGeometry.RELEASE_SHRINK_TICKS = 40
PcStorageGeometry.RELEASE_GROW_TICKS = 20
PcStorageGeometry.RELEASE_SHRINK_STEP = 0.025
PcStorageGeometry.RELEASE_GROW_STEP = 0.05

-- Top-screen information layout (source sprite/window anchors).
PcStorageGeometry.INFO_MON_PICTURE = { x = 100, y = 60, width = 80, height = 80 }
-- Sprite centres; the shared move-icon visual carries the -16/-8 anchor.
PcStorageGeometry.INFO_TYPE_ICONS = { { x = 160, y = 48 }, { x = 194, y = 48 } }
PcStorageGeometry.INFO_MOVES_PANEL = { x = 160, y = 96, width = 96, height = 80 }
PcStorageGeometry.INFO_MOVE_ROWS = { 104, 120, 136, 152 }
PcStorageGeometry.INFO_ITEM_PANEL = { x = 0, y = 120, width = 256, height = 72 }
PcStorageGeometry.INFO_ITEM_NAME = { x = 8, y = 128, width = 96, height = 16 }
PcStorageGeometry.INFO_ITEM_DESC = { x = 32, y = 144, width = 216, height = 48 }
PcStorageGeometry.INFO_ITEM_ICON = { x = 2, y = 144, width = 32, height = 32 }

-- Message windows: W39 leaves the right panel free, W37 and W40
-- span the screen, and W38 sits at the top of the touch screen. The frame is the
-- player's own window frame one tile outside the content box.
PcStorageGeometry.MESSAGE_WINDOWS = {
  W37 = { x = 16, y = 168, width = 216, height = 16 },
  W38 = { x = 16, y = 8, width = 216, height = 16 },
  W39 = { x = 16, y = 168, width = 152, height = 16 },
  W40 = { x = 16, y = 168, width = 216, height = 16 },
}

-- The shared Yes/No prompt (E5EFC): bg0 at x=200, y=96 and y=128.
PcStorageGeometry.YES_RECT = { x = 200, y = 96, width = 48, height = 32 }
PcStorageGeometry.NO_RECT = { x = 200, y = 128, width = 48, height = 32 }

-- The bottom button bar (source cells y 21..23, pixels 168..191). Deposit and
-- Withdraw only show RETURN; Move and Item add PARTY and their tray tab
-- (MOVE / SORT ITEMS). An open list replaces the bar with its EXIT plate, a
-- pick-up hides the bar, and an open party panel shows the panel's own EXIT.
---@class PcStorageButton
---@field rect { x: integer, y: integer, width: integer, height: integer }
---@field messageId integer
---@field target table<string, unknown>
---@field style string? plate role: nil for the framed plate, "tab"/"summary" otherwise

---@param view table<string, unknown>
---@return PcStorageButton[]
function PcStorageGeometry.bottomButtons(view)
  if view.editor ~= nil or view.carry ~= nil then
    return {}
  end
  local right = { x = 192, y = 168, width = 64, height = 24 }
  if view.menu ~= nil then
    return { { rect = right, messageId = 71, target = { type = "cancel" } } }
  end
  if view.boxTray ~= nil then
    local buttons = {}
    if view.boxTray.mode == "box" then
      -- The tray strip's left plate is SUMMARY while the cursor sits on an
      -- occupied box slot and CHANGE BOX while it sits on another box.
      local node = view.cursor and view.cursor.node
      local onSlot = type(node) == "number" and node < 30 and view.cursor.layout == "tray"
      local onThumbnail = type(node) == "number" and node >= 37 and node <= 42 and view.cursor.layout == "tray"
      local occupied = onSlot and type(view.boxSlots) == "table" and type(view.boxSlots[node + 1]) == "table"
      if occupied then
        buttons[#buttons + 1] = {
          rect = PcStorageGeometry.TRAY_CHANGE_BOX_RECT,
          messageId = 65,
          style = "summary",
          target = { type = "action", action = "summary" },
        }
      elseif onThumbnail and view.boxTray.changeBox then
        buttons[#buttons + 1] = {
          rect = PcStorageGeometry.TRAY_CHANGE_BOX_RECT,
          messageId = 63,
          target = { type = "box_tray_change" },
        }
      end
    end
    buttons[#buttons + 1] = { rect = right, messageId = 76, target = { type = "box_tray_cancel" } }
    return buttons
  end
  if view.mode >= 2 and view.tray ~= "closed" then
    return { { rect = right, messageId = 76, target = { type = "tray_close" } } }
  end
  if view.mode >= 2 then
    return {
      { rect = { x = 0, y = 168, width = 88, height = 24 }, messageId = 60, target = { type = "party" } },
      {
        rect = { x = 96, y = 168, width = 88, height = 24 },
        messageId = view.mode == 3 and 64 or 61,
        style = "tab",
        target = { type = "box_tab" },
      },
      { rect = right, messageId = 62, target = { type = "return" } },
    }
  end
  return { { rect = right, messageId = 62, target = { type = "return" } } }
end

-- The party panel's own label plate: SWITCH opens the box tray, EXIT closes
-- the panel. The strip sits at panel-local (2,15) tiles.
PcStorageGeometry.PARTY_PANEL_LABEL = { x = 16, y = 120, width = 56, height = 16 }
PcStorageGeometry.PARTY_PANEL_LABEL_MESSAGES = { switch = 74, exit = 75 }

---@param view table<string, unknown>
---@return { x: integer, y: integer, width: integer, height: integer, messageId: integer, target: table<string, unknown> }?
function PcStorageGeometry.partyPanelLabel(view)
  if view.mode < 2 or view.tray == "closed" or view.editor ~= nil then
    return nil
  end
  local origin = PcStorageGeometry.PARTY_TRAY_ORIGINS[view.tray]
  local label = PcStorageGeometry.PARTY_PANEL_LABEL
  -- One plate: SWITCH opens the box tray beside the party, EXIT closes it.
  local open = view.boxTray ~= nil
  return {
    x = origin.x + label.x,
    y = origin.y + label.y,
    width = label.width,
    height = label.height,
    messageId = open and PcStorageGeometry.PARTY_PANEL_LABEL_MESSAGES.exit
      or PcStorageGeometry.PARTY_PANEL_LABEL_MESSAGES["switch"],
    target = open and { type = "tray_close" } or { type = "box_tray_open" },
  }
end

-- Framed title plates at the source panel cells.
PcStorageGeometry.BOX_MENU_TITLE_RECT = { x = 168, y = 64, width = 88, height = 48 }
PcStorageGeometry.WALLPAPER_TITLE_RECT = { x = 168, y = 112, width = 88, height = 48 }
-- Marking panel Confirm/Cancel labels at panel-local (2,11)/(2,15) tiles.
PcStorageGeometry.MARKING_CONFIRM_RECT = { x = 184, y = 136, width = 56, height = 16 }
PcStorageGeometry.MARKING_CANCEL_RECT = { x = 184, y = 168, width = 56, height = 16 }

return PcStorageGeometry
