-- The phone card's exact list/call composition: the six-row scroll
-- viewport with its source slot offsets, the name/class text cells in
-- their own palette combinations, the selected-row corner frame, the
-- scroll strip and manual-move arrows, the context window, the call speech/name windows driven by the
-- conversation view, and the 240x48 panel cells behind the list-to-call
-- transition. Consumes the controller's detached view and the plan's
-- resolved image paths only; allocates no images while drawing. Name
-- cells use the list font path, class cells their own palette path, and
-- every fill stays explicit so a skin, selection, or panel change is a
-- pixel change. Pure presentation: no love globals, the host graphics
-- namespace arrives through resources.

---@class PokegearPhoneRenderer
local PokegearPhoneRenderer = {}

local PokegearMapLayers = require("libs.hgss.src.presentation.PokegearMapLayers")

local drawSprite = PokegearMapLayers.drawSprite

-- The compiled phone OBJ set (one-based compiled sequences): the scroll
-- arrows, the four selected-row corners in template order (top-left,
-- bottom-left, top-right, bottom-right), and the manual-move chevrons
-- (plain, then selected). Sprite positions are source surface centers;
-- the compiled center anchors land them exactly like the map objects.
local PHONE_SET = "phone"
local SCROLL_UP_SEQUENCE = 1
local SCROLL_DOWN_SEQUENCE = 2
local CORNER_SEQUENCES = { 3, 4, 5, 6 }
local MOVE_SEQUENCE = 7
local MOVE_SELECTED_SEQUENCE = 8

local SURFACE_WIDTH = 256
local SURFACE_HEIGHT = 192

PokegearPhoneRenderer.SURFACE_WIDTH = SURFACE_WIDTH
PokegearPhoneRenderer.SURFACE_HEIGHT = SURFACE_HEIGHT

-- The list window sits at surface (8, 16); each of its rows is a 216x24
-- band of the window bitmap, printed at the source window-local offsets
-- x16 (name) and x94 (class) with y24*slot+2.
local LIST_X = 8
local LIST_Y = 16
local ROW_WIDTH = 216
local ROW_HEIGHT = 24
local VISIBLE_ROWS = 6
local NAME_TEXT_X = 16
local CLASS_TEXT_X = 94
local NAME_CELL_X, NAME_CELL_WIDTH = 8, 82
local CLASS_CELL_X, CLASS_CELL_WIDTH = 90, 126
local CELL_HEIGHT = 20

-- Source palette indices of the two alternating row color sets (zero-based
-- into the sixteen-color list bank): band fill, name and class cell
-- backgrounds, corner fill, and the foreground/shadow pairs of the
-- deselected and selected name and class text.
local ROW_COLORS = {
  {
    fill1 = 11,
    fill2 = 10,
    bg1 = 9,
    bg2 = 10,
    nameFg = 1,
    nameSh = 2,
    classFg = 5,
    classSh = 6,
    nameSelectedFg = 3,
    nameSelectedSh = 4,
    classSelectedFg = 7,
    classSelectedSh = 8,
  },
  {
    fill1 = 14,
    fill2 = 13,
    bg1 = 12,
    bg2 = 13,
    nameFg = 1,
    nameSh = 2,
    classFg = 5,
    classSh = 6,
    nameSelectedFg = 3,
    nameSelectedSh = 4,
    classSelectedFg = 7,
    classSelectedSh = 8,
  },
}

local PANEL_RECT = { x = 8, y = 0, width = 240, height = 48 }
local PANEL_CLOSED_CELL = 10
local PANEL_OPEN_CELL = 11

local MENU_RECT = { x = 128, y = 32, width = 120, height = 16 }
local MENU_ROW_HEIGHT = 14

-- The context window at its source frame with its options and cursor
-- highlight: sixteen-pixel text rows on the shared twenty-four pitch.
local MENU_FRAME_ROW_PITCH = 24
local MENU_FRAME_TEXT_TOP = 8
local MENU_FRAME_TEXT_HEIGHT = 16

local NAME_WINDOW = { x = 32, y = 128, width = 72, height = 16 }
local SPEECH_WINDOW = { x = 16, y = 152, width = 216, height = 32 }

-- Procedural fallback fills behind the resolved planes: one hue per skin
-- so a skin swap repaints from the plan content alone, plus the call and
-- panel window colors. Real planes arrive as prepared images whenever the
-- plan resolves them.
local SKIN_FILLS = {
  { 0.16, 0.16, 0.20 },
  { 0.14, 0.22, 0.16 },
  { 0.16, 0.20, 0.30 },
  { 0.26, 0.22, 0.12 },
  { 0.24, 0.14, 0.24 },
  { 0.12, 0.24, 0.26 },
}
local SELECTED_NAME_FILL = { 0.12, 0.28, 0.62 }
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
  local lease = images[path]
  if lease == nil then
    return false
  end
  graphics.setColor(1, 1, 1, 1)
  lease:draw(graphics, 0, 0)
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

---@param palette table<integer, table<string, number>> sixteen list colors, one-based
---@param index integer zero-based source palette index
---@return table<string, number>
local function paletteColor(palette, index)
  return assert(palette[index + 1], "the list palette carries all sixteen source colors")
end

---@param graphics love.graphics
---@param palette table<integer, table<string, number>>
---@param index integer zero-based source palette index
---@param x number
---@param y number
---@param width number
---@param height number
local function fillPalette(graphics, palette, index, x, y, width, height)
  local color = paletteColor(palette, index)
  graphics.setColor(color.r / 255, color.g / 255, color.b / 255, 1)
  graphics.rectangle("fill", x, y, width, height)
end

---@param text table<string, unknown>?
---@param palette table<integer, table<string, number>>
---@param line string
---@param x number
---@param y number
---@param foreground integer zero-based source palette index
---@param shadow integer zero-based source palette index
---@param background integer zero-based source palette index
local function drawPaletteText(text, palette, line, x, y, foreground, shadow, background)
  if
    text == nil or type((text --[[@as table<string, unknown>]]).drawTextWithPalette) ~= "function"
  then
    return
  end
  local drawText = (text --[[@as table<string, unknown>]]).drawTextWithPalette --[[@as fun(self: table, line: string, x: number, y: number, palette: table)]]
  drawText(text, line, x, y, {
    foreground = paletteColor(palette, foreground),
    shadow = paletteColor(palette, shadow),
    background = paletteColor(palette, background),
  })
end

-- Draws the four compiled corner sprites framing the selected row at
-- the source sprite positions, and the compiled scroll arrows above and
-- below the list while paging is available.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param list table<string, unknown>
---@param sprites table<string, unknown>
local function drawListChrome(graphics, images, list, sprites)
  local selected = list.selected --[[@as integer]]
  local scrollOffset = list.scrollOffset --[[@as integer]]
  local total = list.total --[[@as integer?]]
  graphics.setColor(1, 1, 1, 1)
  if list.cursorVisible == true then
    local slot = selected - scrollOffset
    local top = slot * ROW_HEIGHT + 8
    local corners = { { 16, top }, { 16, top + 22 }, { 224, top }, { 224, top + 22 } }
    for index, point in ipairs(corners) do
      drawSprite(graphics, images, sprites, PHONE_SET, CORNER_SEQUENCES[index], 1, point[1], point[2])
    end
  end
  if scrollOffset > 0 then
    drawSprite(graphics, images, sprites, PHONE_SET, SCROLL_UP_SEQUENCE, 1, 124, 8)
  end
  if type(total) == "number" and scrollOffset + VISIBLE_ROWS < total then
    drawSprite(graphics, images, sprites, PHONE_SET, SCROLL_DOWN_SEQUENCE, 1, 124, 156)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Draws the six-row viewport the way the source prints its window bitmap:
-- per row the band fill, the name and class cells, the marker dots, then
-- the name and class text in the selected or deselected palette colors.
-- Manual move mode swaps the corner frame for per-row move chevrons. A
-- running slide displaces every row band by the view's pixel offset while
-- the alternating colors follow the settled viewport's first color.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param text table<string, unknown>?
---@param list table<string, unknown>
---@param sprites table<string, unknown>
---@param palette table<integer, table<string, number>>
local function drawList(graphics, images, text, list, sprites, palette)
  local rows = list.rows --[[@as table[] ]]
  local selected = list.selected --[[@as integer]]
  local scrollOffset = list.scrollOffset --[[@as integer]]
  local manual = list.manual == true
  assert(type(rows) == "table", "the list projection carries its rows")
  assert(type(selected) == "number", "the list projection carries its selection")
  assert(type(scrollOffset) == "number", "the list projection carries its scroll offset")
  local offset = list.scrollPixels
  if type(offset) ~= "number" then
    offset = 0
  end
  local firstBg = list.firstBgColor
  if type(firstBg) ~= "number" then
    firstBg = scrollOffset % 2
  end
  for slot = 0, VISIBLE_ROWS - 1 do
    local row = rows[slot + 1]
    local absolute = scrollOffset + slot
    local colors = ROW_COLORS[((firstBg + slot) % 2) + 1]
    local top = LIST_Y + slot * ROW_HEIGHT + offset
    fillPalette(graphics, palette, colors.fill1, LIST_X, top, ROW_WIDTH, ROW_HEIGHT)
    fillPalette(graphics, palette, colors.bg1, LIST_X + NAME_CELL_X, top, NAME_CELL_WIDTH, CELL_HEIGHT)
    fillPalette(graphics, palette, colors.bg2, LIST_X + CLASS_CELL_X, top, CLASS_CELL_WIDTH, CELL_HEIGHT)
    fillPalette(graphics, palette, colors.fill2, LIST_X + 1, top + 1, 2, 2)
    fillPalette(graphics, palette, colors.fill1, LIST_X + 8, top, 2, 7)
    for _, dotY in ipairs({ 9, 13, 17 }) do
      fillPalette(graphics, palette, colors.fill1, LIST_X + 9, top + dotY, 2, 2)
    end
    if row ~= nil then
      local entry = row --[[@as table<string, unknown>]]
      local isSelected = absolute == selected
      drawPaletteText(
        text,
        palette,
        tostring(entry.label or entry.contact),
        LIST_X + NAME_TEXT_X,
        top + 2,
        isSelected and colors.nameSelectedFg or colors.nameFg,
        isSelected and colors.nameSelectedSh or colors.nameSh,
        colors.bg1
      )
      local class = entry.class
      if type(class) == "string" and class ~= "" then
        drawPaletteText(
          text,
          palette,
          class,
          LIST_X + CLASS_TEXT_X,
          top + 2,
          isSelected and colors.classSelectedFg or colors.classFg,
          isSelected and colors.classSelectedSh or colors.classSh,
          colors.bg2
        )
      end
      if manual then
        graphics.setColor(1, 1, 1, 1)
        local sequence = isSelected and MOVE_SELECTED_SEQUENCE or MOVE_SEQUENCE
        drawSprite(graphics, images, sprites, PHONE_SET, sequence, 1, 12, top + 12)
      end
    end
  end
  graphics.setColor(1, 1, 1, 1)
  drawListChrome(graphics, images, list, sprites)
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
  local frame = menu.frame --[[@as table<string, integer>?]]
  local x, y, width, height = MENU_RECT.x, MENU_RECT.y, MENU_RECT.width, MENU_RECT.height
  if type(frame) == "table" then
    x = frame.x or x
    y = frame.y or y
    width = frame.width or width
    height = frame.height or height
  else
    height = height + #options * MENU_ROW_HEIGHT
  end
  fillRect(graphics, { 0.10, 0.10, 0.14 }, x, y, width, height)
  graphics.setColor(1, 1, 1, 1)
  graphics.rectangle("line", x + 0.5, y + 0.5, width - 1, height - 1)
  local pitch = MENU_ROW_HEIGHT
  local textHeight = MENU_ROW_HEIGHT
  if type(frame) == "table" then
    pitch, textHeight = MENU_FRAME_ROW_PITCH, MENU_FRAME_TEXT_HEIGHT
  end
  for index, option in ipairs(options) do
    local rowY = y + MENU_FRAME_TEXT_TOP + (index - 1) * pitch
    if index - 1 == cursor then
      fillRect(graphics, SELECTED_NAME_FILL, x + 4, rowY - 2, width - 8, textHeight)
    end
    graphics.setColor(1, 1, 1, 1)
    drawLine(text, tostring(option), x + 8, rowY)
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
    local lease = images[path]
    if lease ~= nil then
      graphics.setColor(1, 1, 1, 1)
      lease:draw(graphics, PANEL_RECT.x, PANEL_RECT.y)
      drawn = true
    end
  end
  if not drawn then
    local fill = cell == PANEL_OPEN_CELL and PANEL_OPEN_FILL or PANEL_CLOSED_FILL
    fillRect(graphics, fill, PANEL_RECT.x, PANEL_RECT.y, PANEL_RECT.width, PANEL_RECT.height)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- The bottom tooltip bar: the source centres the menu prompt in the
-- lower window in the list palette's 3/2/5 combination.
---@param text table<string, unknown>?
---@param palette table<integer, table<string, number>>
---@param line string
local function drawTooltip(text, palette, line)
  local x = 8
  if
    text ~= nil and type((text --[[@as table<string, unknown>]]).textWidth) == "function"
  then
    local measure = (text --[[@as table<string, unknown>]]).textWidth --[[@as fun(self: table, line: string): number]]
    local ok, width = pcall(measure, text, line)
    if ok and type(width) == "number" then
      x = math.max(0, math.floor((SURFACE_WIDTH - width) / 2))
    end
  end
  drawPaletteText(text, palette, line, x, 168, 3, 2, 5)
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
      images --[[@as table<string, unknown>]],
      text --[[@as table<string, unknown>?]],
      list --[[@as table<string, unknown>]],
      assert(content.sprites, "the phone plan resolves its sprite set") --[[@as table<string, unknown>]],
      assert(content.listPalette, "the phone plan resolves its list palette") --[[@as table]]
    )
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
  local tooltip = view.tooltip
  if type(tooltip) == "string" and tooltip ~= "" and type(list) == "table" then
    drawTooltip(
      text --[[@as table<string, unknown>?]],
      assert(content.listPalette, "the phone plan resolves its list palette") --[[@as table]],
      tooltip
    )
  end
  (graphics --[[@as love.graphics]]).setColor(1, 1, 1, 1)
end

-- Draws the phone's upper plane into the information pane.
---@param resources table<string, unknown> borrowed host collaborators
---@param content table<string, unknown> the plan payload with resolved paths
function PokegearPhoneRenderer.drawInformation(resources, content)
  local graphics = assert(resources.graphics, "the phone render borrows its host graphics") --[[@as love.graphics]]
  local images = assert(resources.images, "the phone render borrows its prepared images") --[[@as table<string, unknown>]]
  if type(content.upper) == "string" then
    local lease = assert(images[content.upper], "the phone render needs its prepared upper image")
    graphics.setColor(1, 1, 1, 1)
    lease:draw(graphics, 0, 0)
  end
end

return PokegearPhoneRenderer
