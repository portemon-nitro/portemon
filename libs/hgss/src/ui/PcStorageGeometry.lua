-- Source geometry of the PC Storage box screen (touch screen, 256x192).
-- Authority: pret/pokeheartgold asm/overlay_14.s — the touch hit table
-- (_021F7BBC), the box icon sprite placement (ov14_021F2F88), and the wallpaper
-- tilemap writer (ov14_021E7808).

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
-- offsets from its origin (ov14_021F32E0, table ov14_021F808C).
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
-- fills the bottom n of its five slots (hit table _021F7BBC, lists
-- ov14_021F5EE4; the bottom alignment follows the window-id arithmetic).
PcStorageGeometry.ACTION_SLOTS = 5

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

-- Wallpaper chooser (ov14_021F44B4, ov14_021E8560, hit table _021F7BBC): a row
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

-- Box title plate and box arrows (hit table _021F7BBC, ov14_021F44B4): the
-- plate opens the Wallpaper / Name pair; the arrows step to the neighbour box.
PcStorageGeometry.BOX_TITLE_RECT = { x = 26, y = 17, width = 116, height = 22 }
PcStorageGeometry.BOX_ARROW_CENTERS = { left = { x = 12, y = 28 }, right = { x = 156, y = 28 } }
PcStorageGeometry.BOX_ARROW_RECTS = {
  left = { x = 1, y = 17, width = 22, height = 22 },
  right = { x = 145, y = 17, width = 22, height = 22 },
}

-- Hand cursor nodes (nav tables ov14_021F8B10 family): the cursor sprite sits at
-- the node anchor, which is 12 px above an icon's centre.
---@param slot integer zero-based box slot
---@return number x
---@return number y
function PcStorageGeometry.boxCursorAnchor(slot)
  local rect = PcStorageGeometry.boxSlotRect(slot)
  return rect.x + rect.width / 2, rect.y - 4
end

---@param slot integer zero-based party slot
---@param side "left"|"right"
---@return number x
---@return number y
function PcStorageGeometry.partyCursorAnchor(slot, side)
  local rect = PcStorageGeometry.partySlotRect(slot, side)
  return rect.x + rect.width / 2, rect.y + rect.height / 2 - 12
end

---@param count integer
---@param index integer zero-based position within the list
---@return number x
---@return number y
function PcStorageGeometry.actionCursorAnchor(count, index)
  return 212, PcStorageGeometry.actionButtonRect(count, index).y
end

---@param bit integer zero-based mark
---@return number x
---@return number y
function PcStorageGeometry.markingCursorAnchor(bit)
  return 204 + 32 * (bit % 2), 56 + 24 * math.floor(bit / 2)
end

---@param slot integer zero-based swatch slot within the page
---@return number x
---@return number y
function PcStorageGeometry.wallpaperCursorAnchor(slot)
  return 59 + 46 * slot, 31
end

PcStorageGeometry.WALLPAPER_CONFIRM_CURSOR = { x = 212, y = 130 }
PcStorageGeometry.WALLPAPER_CANCEL_CURSOR = { x = 212, y = 162 }

-- Message windows (ov14_021F84B4): W39 leaves the right panel free, W37 and W40
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

-- The bottom buttons (y 168..191, ov14_021F6244 and neighbours) and the item
-- button above them, with the message ids (bank 24) and the event each press
-- raises. PARTY opens the tray in modes 2 and 3; the right button is RETURN,
-- or EXIT while the tray is open or a mon is picked or a list is up.
---@param view table<string, unknown>
---@return { rect: table<string, integer>, messageId: integer, target: table<string, unknown> }[]
function PcStorageGeometry.bottomButtons(view)
  local buttons = {}
  if view.editor ~= nil then
    return buttons
  end
  local right = { x = 192, y = 168, width = 64, height = 24 }
  if view.carry ~= nil or view.menu ~= nil then
    buttons[#buttons + 1] = { rect = right, messageId = 71, target = { type = "cancel" } }
  elseif view.mode >= 2 and view.tray ~= "closed" then
    buttons[#buttons + 1] = { rect = right, messageId = 76, target = { type = "tray_close" } }
  else
    buttons[#buttons + 1] = { rect = right, messageId = 62, target = { type = "return" } }
    if view.mode >= 2 then
      buttons[#buttons + 1] =
        { rect = { x = 0, y = 168, width = 88, height = 24 }, messageId = 60, target = { type = "party" } }
    end
  end
  if view.mode == 3 and view.menu == nil then
    local holding = view.carry ~= nil and view.carry.kind == "items"
    buttons[#buttons + 1] = {
      rect = { x = 168, y = 136, width = 88, height = 24 },
      messageId = holding and 80 or 81,
      target = { type = "action", action = holding and "bagItem" or "giveItem" },
    }
  end
  return buttons
end

return PcStorageGeometry
