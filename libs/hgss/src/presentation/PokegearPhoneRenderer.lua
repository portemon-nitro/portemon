-- The phone card's exact list/call composition: the six-row scroll
-- viewport with its source slot offsets, the name/class text cells in
-- their own palette combinations, the scroll strip and manual-move
-- arrows, the context window, the call speech/name windows driven by the
-- conversation view, and the 240x48 panel cells behind the list-to-call
-- transition. Consumes the controller's detached view and the plan's
-- resolved image paths only; allocates no images while drawing. Name
-- cells use the list font path, class cells their own palette path, and
-- every fill stays explicit so a skin, selection, or panel change is a
-- pixel change. Pure presentation: no love globals, the host graphics
-- namespace arrives through resources.

---@class PokegearPhoneRenderer
local PokegearPhoneRenderer = {}

local SURFACE_WIDTH = 256
local SURFACE_HEIGHT = 192

PokegearPhoneRenderer.SURFACE_WIDTH = SURFACE_WIDTH
PokegearPhoneRenderer.SURFACE_HEIGHT = SURFACE_HEIGHT

-- List window origin in surface coordinates; row text sits at the source
-- window-local offsets x16 and x94, y24*slot+2 over the (8, 8) origin.
local NAME_TEXT_X = 24
local CLASS_TEXT_X = 102
local ROW_WIDTH = 216
local ROW_HEIGHT = 24
local VISIBLE_ROWS = 6

-- Surface row bands behind the clipped viewport: six 24-pixel rows at
-- y16..160 with the scroll strip alongside at x224..248.
local ROW_BAND_X = 8
local FIRST_BAND_Y = 16
local SCROLL_X = 224
local SCROLL_WIDTH = 24

local PANEL_RECT = { x = 8, y = 0, width = 240, height = 48 }
local PANEL_CLOSED_CELL = 10
local PANEL_OPEN_CELL = 11

local MENU_RECT = { x = 128, y = 32, width = 120, height = 16 }
local MENU_ROW_HEIGHT = 14

local NAME_WINDOW = { x = 32, y = 128, width = 72, height = 16 }
local SPEECH_WINDOW = { x = 16, y = 152, width = 216, height = 32 }
local TOOLTIP_RECT = { x = 0, y = 168, width = 256, height = 16 }

-- Procedural fallback fills behind the resolved planes: one hue per skin
-- so a skin swap repaints from the plan content alone, plus the
-- alternating name/class palette combinations and the selected-state
-- colors. Real planes arrive as prepared images whenever the plan
-- resolves them.
local SKIN_FILLS = {
  { 0.16, 0.16, 0.20 },
  { 0.14, 0.22, 0.16 },
  { 0.16, 0.20, 0.30 },
  { 0.26, 0.22, 0.12 },
  { 0.24, 0.14, 0.24 },
  { 0.12, 0.24, 0.26 },
}
local NAME_FILLS = {
  { 0.92, 0.92, 0.94 },
  { 0.78, 0.80, 0.86 },
}
local CLASS_FILLS = {
  { 0.70, 0.72, 0.78 },
  { 0.82, 0.84, 0.88 },
}
local SELECTED_NAME_FILL = { 0.12, 0.28, 0.62 }
local SELECTED_CLASS_FILL = { 0.16, 0.34, 0.70 }
local PANEL_CLOSED_FILL = { 0.30, 0.30, 0.34 }
local PANEL_OPEN_FILL = { 0.88, 0.88, 0.92 }

---@param graphics love.graphics
---@param images table<string, unknown>
---@param path string?
---@return boolean drawn
local function drawPrepared(graphics, images, path)
  if path == nil then
    return false
  end
  local image = images[path]
  if image == nil then
    return false
  end
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(image, 0, 0)
  return true
end

---@param graphics love.graphics
---@param color number[]
---@param x number
---@param y number
---@param width number
---@param height number
local function fillRect(graphics, color, x, y, width, height)
  graphics.setColor(color[1], color[2], color[3], 1)
  graphics.rectangle("fill", x, y, width, height)
end

---@param text table<string, unknown>?
---@param line string
---@param x number
---@param y number
local function drawLine(text, line, x, y)
  if
    text ~= nil and type((text --[[@as table<string, unknown>]]).drawText) == "function"
  then
    local drawText = (text --[[@as table<string, unknown>]]).drawText --[[@as fun(self: table, line: string, x: number, y: number)]]
    drawText(text, line, x, y)
  end
end

---@param slot integer zero-based visible slot
---@return integer band top in surface coordinates
local function bandY(slot)
  return FIRST_BAND_Y + slot * ROW_HEIGHT
end

-- Draws the six-row clipped viewport: alternating name/class palette
-- cells with the selected-state colors on the selected band, the scroll
-- thumb alongside, and the manual-move arrows while a move is armed.
---@param graphics love.graphics
---@param text table<string, unknown>?
---@param list table<string, unknown>
local function drawList(graphics, text, list)
  local rows = list.rows --[[@as table[] ]]
  local selected = list.selected --[[@as integer]]
  local scrollOffset = list.scrollOffset --[[@as integer]]
  local manual = list.manual == true
  assert(type(rows) == "table", "the list projection carries its rows")
  assert(type(selected) == "number", "the list projection carries its selection")
  assert(type(scrollOffset) == "number", "the list projection carries its scroll offset")
  local count = #rows
  for slot = 0, VISIBLE_ROWS - 1 do
    local row = rows[slot + 1]
    local y = bandY(slot)
    if row == nil then
      fillRect(graphics, { 0.10, 0.10, 0.12 }, ROW_BAND_X, y, ROW_WIDTH, ROW_HEIGHT)
    else
      local entry = row --[[@as table<string, unknown>]]
      local absolute = scrollOffset + slot
      local isSelected = absolute == selected
      local parity = (absolute % 2) + 1
      local nameFill = isSelected and SELECTED_NAME_FILL or NAME_FILLS[parity]
      local classFill = isSelected and SELECTED_CLASS_FILL or CLASS_FILLS[parity]
      assert(nameFill ~= nil and classFill ~= nil, "alternating row palettes cover both parities")
      fillRect(graphics, nameFill, ROW_BAND_X, y, CLASS_TEXT_X - ROW_BAND_X, ROW_HEIGHT)
      fillRect(graphics, classFill, CLASS_TEXT_X, y, ROW_BAND_X + ROW_WIDTH - CLASS_TEXT_X, ROW_HEIGHT)
      graphics.setColor(1, 1, 1, 1)
      drawLine(text, tostring(entry.label or entry.contact), NAME_TEXT_X, y + 2)
      local class = entry.class
      if type(class) == "string" and class ~= "" then
        drawLine(text, class, CLASS_TEXT_X, y + 2)
      end
      if manual then
        if isSelected then
          fillRect(graphics, { 0.95, 0.80, 0.20 }, 0, y + 8, 8, 8)
        else
          fillRect(graphics, { 0.45, 0.45, 0.50 }, 0, y + 8, 8, 8)
        end
      end
    end
  end
  fillRect(graphics, { 0.08, 0.08, 0.10 }, SCROLL_X, FIRST_BAND_Y, SCROLL_WIDTH, VISIBLE_ROWS * ROW_HEIGHT)
  if count > 0 then
    local span = VISIBLE_ROWS * ROW_HEIGHT
    local thumbHeight = math.max(12, math.floor(span * math.min(1, VISIBLE_ROWS / count)))
    local maxOffset = math.max(0, count - VISIBLE_ROWS)
    local thumbY = FIRST_BAND_Y
    if maxOffset > 0 then
      thumbY = FIRST_BAND_Y + math.floor((span - thumbHeight) * (math.min(scrollOffset, maxOffset) / maxOffset))
    end
    fillRect(graphics, { 0.75, 0.75, 0.80 }, SCROLL_X + 6, thumbY, SCROLL_WIDTH - 12, thumbHeight)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Draws the context window with its options and cursor highlight.
---@param graphics love.graphics
---@param text table<string, unknown>?
---@param menu table<string, unknown>
local function drawMenu(graphics, text, menu)
  local options = menu.options --[[@as string[] ]]
  assert(type(options) == "table", "context menus carry their options")
  local cursor = menu.cursor
  if type(cursor) ~= "number" then
    cursor = 0
  end
  local height = MENU_RECT.height + #options * MENU_ROW_HEIGHT
  fillRect(graphics, { 0.10, 0.10, 0.14 }, MENU_RECT.x, MENU_RECT.y, MENU_RECT.width, height)
  graphics.setColor(1, 1, 1, 1)
  graphics.rectangle("line", MENU_RECT.x + 0.5, MENU_RECT.y + 0.5, MENU_RECT.width - 1, height - 1)
  for index, option in ipairs(options) do
    local y = MENU_RECT.y + 8 + (index - 1) * MENU_ROW_HEIGHT
    if index - 1 == cursor then
      fillRect(graphics, SELECTED_NAME_FILL, MENU_RECT.x + 4, y - 2, MENU_RECT.width - 8, MENU_ROW_HEIGHT)
    end
    graphics.setColor(1, 1, 1, 1)
    drawLine(text, tostring(option), MENU_RECT.x + 8, y)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Draws the call speech/name windows from the conversation projection:
-- the resolved caller name and current source text page.
---@param graphics love.graphics
---@param text table<string, unknown>?
---@param call table<string, unknown>
local function drawCall(graphics, text, call)
  fillRect(graphics, { 0.10, 0.10, 0.14 }, NAME_WINDOW.x, NAME_WINDOW.y, NAME_WINDOW.width, NAME_WINDOW.height)
  graphics.setColor(1, 1, 1, 1)
  drawLine(text, tostring(call.name), NAME_WINDOW.x + 4, NAME_WINDOW.y + 2)
  fillRect(graphics, { 0.94, 0.94, 0.96 }, SPEECH_WINDOW.x, SPEECH_WINDOW.y, SPEECH_WINDOW.width, SPEECH_WINDOW.height)
  graphics.setColor(0.08, 0.08, 0.10, 1)
  graphics.rectangle(
    "line",
    SPEECH_WINDOW.x + 0.5,
    SPEECH_WINDOW.y + 0.5,
    SPEECH_WINDOW.width - 1,
    SPEECH_WINDOW.height - 1
  )
  graphics.setColor(1, 1, 1, 1)
  local pages = call.lines
  local page = call.page
  local body = ""
  if type(pages) == "table" and type(page) == "number" and type(pages[page]) == "table" then
    body = tostring(pages[page].text)
  end
  drawLine(text, body, SPEECH_WINDOW.x + 4, SPEECH_WINDOW.y + 4)
  local choices = call.choices
  if type(choices) == "table" then
    local cursor = call.choiceCursor
    if type(cursor) ~= "number" then
      cursor = 0
    end
    local list = choices --[[@as string[] ]]
    for index, choice in ipairs(list) do
      local y = SPEECH_WINDOW.y + SPEECH_WINDOW.height - (#list - index + 1) * MENU_ROW_HEIGHT
      if index - 1 == cursor then
        fillRect(graphics, SELECTED_NAME_FILL, SPEECH_WINDOW.x + 4, y - 2, 96, MENU_ROW_HEIGHT)
      end
      graphics.setColor(1, 1, 1, 1)
      drawLine(text, tostring(choice), SPEECH_WINDOW.x + 8, y)
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Draws the 240x48 panel cell behind the list-to-call transition: the
-- resolved closed/open plane when prepared, otherwise the matching
-- fallback fill so the 1+6+1 swap always paints.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param cell integer
---@param content table<string, unknown>
local function drawPanel(graphics, images, cell, content)
  local path = nil
  if cell == PANEL_OPEN_CELL then
    path = content.panelOpen --[[@as string?]]
  else
    path = content.panelClosed --[[@as string?]]
  end
  local drawn = false
  if path ~= nil then
    local image = images[path]
    if image ~= nil then
      graphics.setColor(1, 1, 1, 1)
      graphics.draw(image, PANEL_RECT.x, PANEL_RECT.y)
      drawn = true
    end
  end
  if not drawn then
    local fill = cell == PANEL_OPEN_CELL and PANEL_OPEN_FILL or PANEL_CLOSED_FILL
    fillRect(graphics, fill, PANEL_RECT.x, PANEL_RECT.y, PANEL_RECT.width, PANEL_RECT.height)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Draws the published phone surface with borrowed collaborators: the
-- per-skin background plane, the clipped contact list with its tooltip
-- strip, the context window while one is open, the conversation windows
-- while a call is live, and the panel cell across the transition. Reads
-- only; draws deterministically with no allocation.
---@param resources table<string, unknown> borrowed host collaborators
---@param view table<string, unknown> the detached phone view
---@param content table<string, unknown> the plan payload with resolved paths
function PokegearPhoneRenderer.draw(resources, view, content)
  local graphics = assert(resources.graphics, "the phone render borrows its host graphics")
  assert(type(graphics) == "table", "the phone render borrows its host graphics")
  local images = assert(resources.images, "the phone render borrows its prepared images")
  assert(type(images) == "table", "the phone render borrows its prepared images")
  local text = resources.textRenderer
  assert(type(view) == "table", "the phone render reads its detached view")
  assert(type(content) == "table", "the phone render reads its plan payload")
  local skin = content.skin
  if type(skin) ~= "number" then
    skin = 0
  end
  local background = SKIN_FILLS[(math.floor(skin) % #SKIN_FILLS) + 1]
  assert(background ~= nil, "every skin resolves its fallback fill")
  if
    not drawPrepared(
      graphics --[[@as love.graphics]],
      images --[[@as table<string, unknown>]],
      content.foreground --[[@as string?]]
    )
  then
    fillRect(graphics --[[@as love.graphics]], background, 0, 0, SURFACE_WIDTH, SURFACE_HEIGHT)
  end
  local list = view.list
  if type(list) == "table" then
    drawList(
      graphics --[[@as love.graphics]],
      text --[[@as table<string, unknown>?]],
      list --[[@as table<string, unknown>]]
    )
    fillRect(
      graphics --[[@as love.graphics]],
      { 0.10, 0.10, 0.14 },
      TOOLTIP_RECT.x,
      TOOLTIP_RECT.y,
      TOOLTIP_RECT.width,
      TOOLTIP_RECT.height
    )
    graphics.setColor(1, 1, 1, 1)
  end
  local panel = view.panel
  if type(panel) == "table" then
    local cell = (panel --[[@as table<string, unknown>]]).cell
    if type(cell) ~= "number" then
      cell = PANEL_CLOSED_CELL
    end
    drawPanel(graphics --[[@as love.graphics]], images --[[@as table<string, unknown>]], cell, content)
  end
  local menu = view.contextMenu
  if type(menu) == "table" then
    drawMenu(
      graphics --[[@as love.graphics]],
      text --[[@as table<string, unknown>?]],
      menu --[[@as table<string, unknown>]]
    )
  end
  local call = view.call
  if type(call) == "table" then
    drawCall(
      graphics --[[@as love.graphics]],
      text --[[@as table<string, unknown>?]],
      call --[[@as table<string, unknown>]]
    )
  end
  (graphics --[[@as love.graphics]]).setColor(1, 1, 1, 1)
end

return PokegearPhoneRenderer
