-- The phone card's exact list/call composition: the six-row scroll
-- viewport with its source slot offsets, the name/class text cells in
-- their own palette combinations, the selected-row corner frame, the
-- scroll strip and manual-move arrows, the context window, and the call
-- speech/name windows driven by the conversation view. Consumes the
-- controller's detached view and the plan's resolved image paths only;
-- allocates no images while drawing. Name cells print through the
-- borrowed name-font renderer, class cells through the borrowed class
-- renderer, and every fill stays explicit so a skin or selection change
-- is a pixel change. Pure presentation: no love globals, the host
-- graphics namespace arrives through resources.

---@class PokegearPhoneRenderer
local PokegearPhoneRenderer = {}

local PokegearMapLayers = require("libs.hgss.src.presentation.PokegearMapLayers")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

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
-- The in-call fast-forward sprite (compiled sequence 9, source
-- animation 8) at its source surface position.
local FAST_FORWARD_SEQUENCE = 9
local FAST_FORWARD_X = 128
local FAST_FORWARD_Y = 160
-- The static lower phone plane covers the source MAIN_2 copy of 32x20
-- tiles, so it ends where the shared strip begins.
local MAIN_PLANE_HEIGHT = 160

local SURFACE_WIDTH = 256
local SURFACE_HEIGHT = 192

PokegearPhoneRenderer.SURFACE_WIDTH = SURFACE_WIDTH
PokegearPhoneRenderer.SURFACE_HEIGHT = SURFACE_HEIGHT

-- Ports PhoneContactListUI_GetBackgroundIndex: the alternating row color
-- follows the visible slot with the controller's scroll-flip flag, never
-- the absolute contact. The source numbers slots one-based; this port
-- takes the zero-based viewport slot this renderer already paints.
---@param slot integer zero-based viewport slot, possibly transient
---@param firstBgColor integer the source scroll-flip flag, 0 or 1
---@return integer zero-based row color set
function PokegearPhoneRenderer.slotColorIndex(slot, firstBgColor)
  assert(type(slot) == "number", "the slot color reads its viewport slot")
  assert(firstBgColor == 0 or firstBgColor == 1, "the slot color reads the source flip flag")
  local bit = (slot + 1) % 2
  if firstBgColor == 1 then
    bit = 1 - bit
  end
  return bit
end

-- The list window sits at surface (8, 16) on MAIN_3, but the layer
-- scrolls 32px up behind the MAIN_2 plane: rows paint at screen y8 with
-- the plane frame covering the window's left 5px, so the visible
-- viewport is the frame interior x13/y5/211x152. Each row stays a 216x24
-- band of the window bitmap, printed at the source window-local offsets
-- x16 (name) and x94 (class) with y24*slot+2.
local LIST_X = 8
local LIST_Y = 8
local LIST_CLIP = { x = 13, y = 5, width = 211, height = 152 }
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

local NAME_WINDOW = { x = 32, y = 128, width = 72, height = 16 }
local SPEECH_WINDOW = { x = 16, y = 152, width = 216, height = 32 }

-- Source call-window colors on SUB_2 (sWindowTemplates windows[0,1],
-- palette 1): the source clears both pixel buffers to fill 0 and prints
-- every call line in text color (1,2,0). Fill 0 is the transparent pen
-- of the auto-transparent palettes, and the static upper plane already
-- carries the message box art, so the caller windows paint text only:
-- no opaque fill, and a transparent text background. Text cells resolve
-- through the window palette, never invented triples or plain text.
local CALL_TEXT_FOREGROUND = 1
local CALL_TEXT_SHADOW = 2
local CALL_TEXT_TRANSPARENT = { r = 0, g = 0, b = 0, a = 0 }

-- The source always loads both planes before the first paint
-- (PokegearPhone_LoadBgGraphics and PokegearPhone_AddWindows in
-- pokegear_phone_gfx.c), so a plan without its resolved plane is a
-- broken plan, never a fallback fill: the draws below fail loudly
-- and name the missing plane instead of painting skin fills or
-- skipping the information pane.

---@param graphics love.graphics
---@param images table<string, unknown>
---@param path string the resolved plane behind the surface
---@param plane string the plane role named on failure
local function drawRequiredPlane(graphics, images, path, plane)
  local lease = (images --[[@as table<string, unknown>]])[path]
  assert(lease ~= nil, "the phone render needs its prepared " .. plane .. " image")
  graphics.setColor(1, 1, 1, 1)
  local draw = (lease --[[@as table]]).draw
  assert(type(draw) == "function", "the phone render needs its prepared " .. plane .. " image")
  draw(lease, graphics, 0, 0)
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

-- Returns the signed screen displacement of the running slide, or zero
-- when the viewport rests on a row boundary.
---@param list table<string, unknown>
---@return integer
local function slidePixels(list)
  local slide = list.slide
  if
    type(slide) == "table" and type((slide --[[@as table<string, unknown>]]).pixels) == "number"
  then
    return (slide --[[@as table<string, unknown>]]).pixels --[[@as integer]]
  end
  return 0
end

-- Returns the visual first-contact offset the arrows follow: the slide's
-- intermediate first row while animating, otherwise the settled scroll.
---@param list table<string, unknown>
---@param scrollOffset integer
---@return integer
local function visualFirst(list, scrollOffset)
  local slide = list.slide
  if
    type(slide) == "table" and type((slide --[[@as table<string, unknown>]]).first) == "number"
  then
    return (slide --[[@as table<string, unknown>]]).first --[[@as integer]]
  end
  return scrollOffset
end

-- Draws the four compiled corner sprites framing the selected row at
-- the source sprite positions, and the compiled scroll arrows above and
-- below the list while paging is available. Corners track the actual
-- visible transient row; arrows track the visual first row, never the
-- logical destination jump. A live call hides the corners with the row
-- cursor by original source rules. Corners and arrows blink on their
-- source durations instead of sticking on frame one.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param list table<string, unknown>
---@param sprites table<string, unknown>
---@param cursorAllowed boolean whether the row cursor may show beside the list
---@param tick integer? the fixed source tick behind the blink
local function drawListChrome(graphics, images, list, sprites, cursorAllowed, tick)
  local selected = list.selected --[[@as integer]]
  local scrollOffset = list.scrollOffset --[[@as integer]]
  local total = list.total --[[@as integer?]]
  graphics.setColor(1, 1, 1, 1)
  if list.cursorVisible == true and cursorAllowed then
    local rows = list.rows --[[@as table[] ]]
    local pixels = slidePixels(list)
    local found = nil
    if type(rows) == "table" then
      for _, node in ipairs(rows) do
        local entry = node --[[@as table<string, unknown>]]
        if entry.absolute == selected and type(entry.slot) == "number" then
          found = entry
          break
        end
      end
    end
    if found ~= nil then
      local top = (found --[[@as table<string, unknown>]]).slot --[[@as integer]] * ROW_HEIGHT + 8 + pixels
      local corners = { { 16, top }, { 16, top + 22 }, { 224, top }, { 224, top + 22 } }
      for index, point in ipairs(corners) do
        local frame = PokegearMapLayers.animationFrame(sprites, PHONE_SET, CORNER_SEQUENCES[index], tick)
        drawSprite(graphics, images, sprites, PHONE_SET, CORNER_SEQUENCES[index], frame, point[1], point[2])
      end
    end
  end
  local first = visualFirst(list, scrollOffset)
  if first > 0 then
    local upFrame = PokegearMapLayers.animationFrame(sprites, PHONE_SET, SCROLL_UP_SEQUENCE, tick)
    drawSprite(graphics, images, sprites, PHONE_SET, SCROLL_UP_SEQUENCE, upFrame, 124, 8)
  end
  if type(total) == "number" and first + VISIBLE_ROWS < total then
    local downFrame = PokegearMapLayers.animationFrame(sprites, PHONE_SET, SCROLL_DOWN_SEQUENCE, tick)
    drawSprite(graphics, images, sprites, PHONE_SET, SCROLL_DOWN_SEQUENCE, downFrame, 124, 156)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Draws one contact row at its shifted viewport position: the band
-- fill, the name and class cells, the marker dots, then the name and
-- class text. The caller resolves the color set: settled rows follow the
-- viewport slot with the scroll-flip flag, sliding rows follow the
-- scroll-start slot so moving bands keep their colors like the source
-- window-bitmap shift.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param nameText table<string, unknown>? the borrowed font-4 name renderer
---@param classText table<string, unknown>? the borrowed font-0 class renderer
---@param entry table<string, unknown>
---@param absolute integer
---@param top number
---@param selected integer cursor focus for the move chevron
---@param selectedContact integer? the source selectedIndex for contact text, nil while browsing
---@param manual boolean
---@param sprites table<string, unknown>
---@param palette table<integer, table<string, number>>
---@param colorIdx integer zero-based row color set
local function drawRow(
  graphics,
  images,
  nameText,
  classText,
  entry,
  absolute,
  top,
  selected,
  selectedContact,
  manual,
  sprites,
  palette,
  colorIdx
)
  local colors = ROW_COLORS[colorIdx + 1]
  fillPalette(graphics, palette, colors.fill1, LIST_X, top, ROW_WIDTH, ROW_HEIGHT)
  fillPalette(graphics, palette, colors.bg1, LIST_X + NAME_CELL_X, top, NAME_CELL_WIDTH, CELL_HEIGHT)
  fillPalette(graphics, palette, colors.bg2, LIST_X + CLASS_CELL_X, top, CLASS_CELL_WIDTH, CELL_HEIGHT)
  fillPalette(graphics, palette, colors.fill2, LIST_X + 1, top + 1, 2, 2)
  fillPalette(graphics, palette, colors.fill1, LIST_X + 8, top, 2, 7)
  for _, dotY in ipairs({ 9, 13, 17 }) do
    fillPalette(graphics, palette, colors.fill1, LIST_X + 9, top + dotY, 2, 2)
  end
  local isCursor = absolute == selected
  -- The source selects contact text only after pressing A
  -- (selectedIndex): cursor focus alone keeps deselected colors.
  local isSelected = selectedContact ~= nil and absolute == selectedContact
  drawPaletteText(
    nameText,
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
      classText,
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
    local sequence = isCursor and MOVE_SELECTED_SEQUENCE or MOVE_SEQUENCE
    -- The 32px chevron centers on the source row center (12, 16+slot*24).
    drawSprite(graphics, images, sprites, PHONE_SET, sequence, 1, 12, top + 8)
  end
end

-- Draws an empty band with the caller's resolved color set.
---@param graphics love.graphics
---@param top number
---@param palette table<integer, table<string, number>>
---@param colorIdx integer zero-based row color set
local function drawEmptyBand(graphics, top, palette, colorIdx)
  local colors = ROW_COLORS[colorIdx + 1]
  fillPalette(graphics, palette, colors.fill1, LIST_X, top, ROW_WIDTH, ROW_HEIGHT)
  fillPalette(graphics, palette, colors.bg1, LIST_X + NAME_CELL_X, top, NAME_CELL_WIDTH, CELL_HEIGHT)
  fillPalette(graphics, palette, colors.bg2, LIST_X + CLASS_CELL_X, top, CLASS_CELL_WIDTH, CELL_HEIGHT)
  fillPalette(graphics, palette, colors.fill2, LIST_X + 1, top + 1, 2, 2)
  fillPalette(graphics, palette, colors.fill1, LIST_X + 8, top, 2, 7)
  for _, dotY in ipairs({ 9, 13, 17 }) do
    fillPalette(graphics, palette, colors.fill1, LIST_X + 9, top + dotY, 2, 2)
  end
end

-- Draws the six-row viewport the way the source prints its window bitmap:
-- per row the band fill, the name and class cells, the marker dots, then
-- the name and class text in the selected or deselected palette colors.
-- Manual move mode swaps the corner frame for per-row move chevrons. A
-- running slide paints the transient seven-row strip at its per-row
-- displacement under a viewport clip; sliding colors resolve against the
-- scroll-start slot so the bands travel with their rows.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param nameText table<string, unknown>? the borrowed font-4 name renderer
---@param classText table<string, unknown>? the borrowed font-0 class renderer
---@param list table<string, unknown>
---@param sprites table<string, unknown>
---@param palette table<integer, table<string, number>>
---@param cursorAllowed boolean whether the row cursor may show beside the list
---@param tick integer? the fixed source tick behind the corner/arrow blink
local function drawList(graphics, images, nameText, classText, list, sprites, palette, cursorAllowed, tick)
  local rows = list.rows --[[@as table[] ]]
  local selected = list.selected --[[@as integer]]
  local selectedContact = list.selectedContact --[[@as integer?]]
  local scrollOffset = list.scrollOffset --[[@as integer]]
  local firstBgColor = list.firstBgColor --[[@as integer]]
  local manual = list.manual == true
  assert(type(rows) == "table", "the list projection carries its rows")
  assert(type(selected) == "number", "the list projection carries its selection")
  assert(type(scrollOffset) == "number", "the list projection carries its scroll offset")
  assert(firstBgColor == 0 or firstBgColor == 1, "the list projection carries the source scroll-flip flag")
  local pixels = slidePixels(list)
  local slideActive = type(list.slide) == "table"
  local slideFrom = nil
  if slideActive then
    local slide = list.slide --[[@as table<string, unknown>]]
    slideFrom = slide.from --[[@as integer]]
    assert(type(slideFrom) == "number", "the sliding strip anchors colors at its scroll start")
  end
  local function paintRows()
    if slideActive then
      for _, node in ipairs(rows) do
        local entry = node --[[@as table<string, unknown>]]
        local absolute = entry.absolute --[[@as integer]]
        local slot = entry.slot --[[@as integer]]
        assert(type(absolute) == "number", "the sliding strip carries absolute contact indices")
        assert(type(slot) == "number", "the sliding strip carries relative slots")
        local traveling = PokegearPhoneRenderer.slotColorIndex(absolute - slideFrom --[[@as integer]], firstBgColor)
        drawRow(
          graphics,
          images,
          nameText,
          classText,
          entry,
          absolute,
          LIST_Y + slot * ROW_HEIGHT + pixels,
          selected,
          selectedContact,
          manual,
          sprites,
          palette,
          traveling
        )
      end
    else
      local bySlot = {}
      for _, node in ipairs(rows) do
        local entry = node --[[@as table<string, unknown>]]
        if type(entry.slot) == "number" then
          bySlot[
            entry.slot --[[@as integer]]
          ] = entry
        end
      end
      -- Settled slivers at slots -1/6 paint through the same clip so
      -- the frame interior shows 3px of the leading row and 5px of the
      -- trailing row like the source window bitmap.
      for slot = -1, VISIBLE_ROWS do
        local entry = bySlot[slot]
        local top = LIST_Y + slot * ROW_HEIGHT
        if entry ~= nil then
          local resolved = assert(
            (entry --[[@as table<string, unknown>]]).absolute,
            "the settled strip carries absolute contact indices"
          ) --[[@as integer]]
          local settled = PokegearPhoneRenderer.slotColorIndex(slot, firstBgColor)
          drawRow(
            graphics,
            images,
            nameText,
            classText,
            entry,
            resolved,
            top,
            selected,
            selectedContact,
            manual,
            sprites,
            palette,
            settled
          )
        else
          drawEmptyBand(graphics, top, palette, PokegearPhoneRenderer.slotColorIndex(slot, firstBgColor))
        end
      end
    end
  end
  -- The viewport clip follows the active placement transform, so the
  -- rows stay inside the plane frame interior on every display
  -- configuration. A raw device scissor would pin unscaled pixels and
  -- hide the list whenever the placement scales or offsets the surface.
  LogicalSurface.clip(graphics, LIST_CLIP, paintRows)
  graphics.setColor(1, 1, 1, 1)
  drawListChrome(graphics, images, list, sprites, cursorAllowed ~= false, tick)
end

-- Draws the context menu through the shared touchscreen list-menu
-- frame: the same staged tile strip every framed app menu draws. The
-- detached frame stays in tiles end-to-end. Retail touchscreen menus
-- highlight only the frame at the cursor and keep every entry's
-- deselected fill and text, so the selected cell background never
-- repaints on cursor moves.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param text table<string, unknown>?
---@param menu table<string, unknown>
---@param content table<string, unknown>
local function drawMenu(graphics, images, text, menu, content)
  local options = menu.options --[[@as string[] ]]
  assert(type(options) == "table" and #options > 0, "context menus carry their options")
  local cursor = menu.cursor
  if type(cursor) ~= "number" then
    cursor = 0
  end
  local frame = assert(menu.frame, "context menus carry their window frame") --[[@as table<string, integer>]]
  local tiles =
    PokegearMapLayers.imageAt(images, assert(content.menuTiles, "the phone plan resolves its list-menu tile strip"))
  local palette = assert(content.menuPalette, "the phone plan resolves its list-menu palette")
  PokegearMapLayers.drawListMenuFrame(graphics, tiles, palette --[[@as table<integer, table<string, number>>]], text, {
    x = frame.x,
    y = frame.y,
    width = frame.width,
    labels = options,
    cursor = cursor,
    highlightFill = false,
  })
end

-- Draws one call line through the window palette with a transparent
-- background pen: the glyph cells never repaint the message box behind
-- the text.
---@param text table<string, unknown>? the borrowed font-0 call renderer
---@param palette table<integer, table<string, number>> sixteen window colors, one-based
---@param line string
---@param x number
---@param y number
local function drawCallText(text, palette, line, x, y)
  if
    text == nil or type((text --[[@as table<string, unknown>]]).drawTextWithPalette) ~= "function"
  then
    return
  end
  local drawText = (text --[[@as table<string, unknown>]]).drawTextWithPalette --[[@as fun(self: table, line: string, x: number, y: number, palette: table)]]
  drawText(text, line, x, y, {
    foreground = paletteColor(palette, CALL_TEXT_FOREGROUND),
    shadow = paletteColor(palette, CALL_TEXT_SHADOW),
    background = CALL_TEXT_TRANSPARENT,
  })
end

-- Measures one row through the borrowed text renderer, if it measures.
---@param text table<string, unknown>? the borrowed font-0 call renderer
---@param line string
---@return number? measured width, when the renderer measures
local function measureRow(text, line)
  if
    text == nil or type((text --[[@as table<string, unknown>]]).textWidth) ~= "function"
  then
    return nil
  end
  local measure = (text --[[@as table<string, unknown>]]).textWidth --[[@as fun(self: table, line: string): number]]
  local ok, width = pcall(measure, text, line)
  if ok and type(width) == "number" then
    return width
  end
  return nil
end

-- Wraps one source row to the speech width at word boundaries. Rows the
-- renderer cannot measure stay whole; overlong single words overflow
-- into the window clip exactly like an unmeasured draw.
---@param text table<string, unknown>? the borrowed font-0 call renderer
---@param line string
---@param maxWidth number
---@return string[] wrapped rows
local function wrapRow(text, line, maxWidth)
  local rows, current = {}, ""
  for word in tostring(line):gmatch("%S+") do
    local candidate = current == "" and word or (current .. " " .. word)
    local width = measureRow(text, candidate)
    if current == "" or width == nil or width <= maxWidth then
      current = candidate
    else
      rows[#rows + 1] = current
      current = word
    end
  end
  rows[#rows + 1] = current
  return rows
end

-- Rebuilds one page's visible text from its compiled tokens up to the
-- revealed glyph count: glyph text prints in order with the source
-- breaks, while non-glyph controls reuse their exact marker text so a
-- partially typed page never invents or drops a visible control. Pages
-- without tokens, or without a reveal count, print whole exactly like
-- the historical untyped draw.
---@param page table<string, unknown>
---@param revealed unknown glyph count, when the conversation types
---@return string visible text
local function pageVisibleText(page, revealed)
  local full = tostring(page.text)
  local tokens = page.tokens
  if type(tokens) ~= "table" or type(revealed) ~= "number" then
    return full
  end
  local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
  local out, seen = {}, 0
  for _, token in
    ipairs(tokens --[[@as table<integer, unknown>]])
  do
    if type(token) ~= "table" then
      break
    end
    local record = token --[[@as table<string, unknown>]]
    if record.kind == "glyph" then
      if seen >= revealed then
        break
      end
      seen = seen + 1
      out[#out + 1] = tostring(record.text)
    elseif record.kind == "line_break" then
      out[#out + 1] = "\n"
    elseif record.kind == "prompt_break" then
      out[#out + 1] = "\r"
    elseif record.kind == "page_break" then
      out[#out + 1] = "\f"
    elseif record.kind == "substitution" and record.control == FieldMessageText.TRNAME then
      out[#out + 1] = "{TRNAME}"
    elseif type(record.control) == "number" then
      out[#out + 1] = FieldMessageText.marker(record.control, unpack((record.args or {}) --[[@as table]]))
    else
      out[#out + 1] = ""
    end
  end
  return table.concat(out)
end

-- Draws the call speech/name windows from the conversation projection
-- through the window palette: the resolved caller name and the current
-- source text page at their window-local origins. The caller name prints
-- through the class font like every other call line. Typing stages print
-- only the revealed glyph prefix; instant stages print the whole page.
-- Source line breaks become 16px window rows and long rows wrap at the
-- speech width under a window clip; owed choices never paint here, they
-- ride the shared list-menu frame beside the windows.
---@param graphics love.graphics
---@param text table<string, unknown>? the borrowed font-0 call renderer
---@param call table<string, unknown>
---@param palette table<integer, table<string, number>> sixteen window colors, one-based
local function drawCall(graphics, text, call, palette)
  drawCallText(text, palette, tostring(call.name), NAME_WINDOW.x, NAME_WINDOW.y)
  local pages = call.lines
  local page = call.page
  local body = ""
  if type(pages) == "table" and type(page) == "number" and type(pages[page]) == "table" then
    body = pageVisibleText(pages[page] --[[@as table<string, unknown>]], call.revealed)
  end
  local rows = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    for _, row in ipairs(wrapRow(text, line, SPEECH_WINDOW.width)) do
      rows[#rows + 1] = row
    end
  end
  LogicalSurface.clip(graphics, SPEECH_WINDOW, function()
    for index, row in ipairs(rows) do
      drawCallText(text, palette, row, SPEECH_WINDOW.x, SPEECH_WINDOW.y + (index - 1) * 16)
    end
  end)
  graphics.setColor(1, 1, 1, 1)
end

-- Source palette indices of the context tooltip window (windows[3])
-- in its own palette bank: the strip fill, and the foreground, shadow,
-- and background of the centered prompt.
local TOOLTIP_FILL = 5
local TOOLTIP_FOREGROUND = 3
local TOOLTIP_SHADOW = 2

-- The tooltip bar behind the context prompt: it spans the full bottom
-- strip (y160..192) so the message covers the card icons across the
-- entire lower area. The prompt keeps its source window text row at
-- y168, vertically centered in the taller bar, in the 3/2/5 combination
-- of the window's own palette bank, never the list palette. The source
-- saves and restores the covered tilemap rect around the window; the
-- retained-mode renderer repaints every frame, so it paints only.
local TOOLTIP_STRIP = { x = 0, y = 160, width = 256, height = 32 }
-- The source window text row behind the centered prompt.
local TOOLTIP_TEXT_Y = 168
-- The source window text row behind the centered prompt.

-- The bottom tooltip bar: fill 5 spans the full bottom strip behind
-- the menu prompt centered in the 3/2/5 combination of the window's
-- own palette bank, never the list palette. The source saves and
-- restores the covered tilemap rect around the window; the
-- retained-mode renderer repaints every frame, so it paints only.
-- Retail shows the bar over the bottom strip, so the composed shell
-- paints it after its strip; direct draws without a shell paint it
-- here to keep the same pixels. Exported for the shell's after-strip
-- pass.
---@param graphics love.graphics
---@param text table<string, unknown>?
---@param palette table<integer, table<string, number>> sixteen tooltip colors, one-based
---@param line string
local function drawTooltip(graphics, text, palette, line)
  fillPalette(
    graphics,
    palette,
    TOOLTIP_FILL,
    TOOLTIP_STRIP.x,
    TOOLTIP_STRIP.y,
    TOOLTIP_STRIP.width,
    TOOLTIP_STRIP.height
  )
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
  drawPaletteText(text, palette, line, x, TOOLTIP_TEXT_Y, TOOLTIP_FOREGROUND, TOOLTIP_SHADOW, TOOLTIP_FILL)
end

-- Paints the phone tooltip bar over the bottom strip from borrowed
-- collaborators: the tooltip strip fill with the centered prompt. The
-- shell calls this after its strip whenever the phone child owes a
-- prompt, so the message stays visible over the card icons.
---@param graphics love.graphics host graphics namespace
---@param text table<string, unknown>? borrowed text primitives
---@param palette table<integer, table<string, number>> sixteen tooltip colors, one-based
---@param line string the centered prompt
function PokegearPhoneRenderer.drawTooltipBar(graphics, text, palette, line)
  drawTooltip(graphics, text, palette, line)
  graphics.setColor(1, 1, 1, 1)
end

-- Draws the published phone surface on the lower pane with borrowed
-- collaborators: the per-skin background plane with the contact list in
-- every phone state, the tooltip strip, the context window while
-- browsing, and the owed-choice menu with the fast-forward sprite while
-- a call is live. The caller windows never paint here; they ride the
-- information-pane render path. A live call selects the dimmed plane,
-- palette, and sprite set, and an open choice swaps to the
-- choice-dimmed plane hiding the sprite. Reads only; draws
-- deterministically with no allocation.
---@param resources table<string, unknown> borrowed host collaborators
---@param view table<string, unknown> the detached phone view
---@param content table<string, unknown> the plan payload with resolved paths
---@param shell table<string, unknown>? the shell view carrying strip focus, when composed
function PokegearPhoneRenderer.draw(resources, view, content, shell)
  local graphics = assert(resources.graphics, "the phone render borrows its host graphics")
  assert(type(graphics) == "table", "the phone render borrows its host graphics")
  local images = assert(resources.images, "the phone render borrows its prepared images")
  assert(type(images) == "table", "the phone render borrows its prepared images")
  local text = resources.textRenderer
  -- The source prints the contact name with font 4 and the class with
  -- font 0: the name renderer arrives beside the borrowed class
  -- renderer and falls back to it when the host composes no name font.
  local nameText = resources.phoneNameTextRenderer
  if nameText == nil then
    nameText = text
  end
  assert(type(view) == "table", "the phone render reads its detached view")
  assert(type(content) == "table", "the phone render reads its plan payload")
  local list = view.list
  local call = view.call
  local callMenu = view.callMenu
  local dimmed = type(call) == "table" and call.dim == true
  local foreground = content.foreground
  local palette = content.listPalette
  local sprites = content.sprites
  if dimmed then
    if type(callMenu) == "table" then
      foreground = assert(content.foregroundDimChoice, "the phone plan resolves its choice-dimmed plane")
    else
      foreground = assert(content.foregroundDim, "the phone plan resolves its dimmed plane")
    end
    palette = assert(content.listPaletteDim, "the phone plan resolves its dimmed list palette")
    sprites = assert(content.spritesDim, "the phone plan resolves its dimmed sprite set")
  end
  assert(
    type(foreground) == "string",
    "the phone render reads its foreground plane from the plan, got " .. type(content.foreground)
  )
  -- The static plane covers the source 20 tile rows only, so the
  -- reordered child never repaints the shared strip below it; the list
  -- chrome, menus, sprite, and tooltip stay free to overlap the strip.
  -- The MAIN_1 strip art (screenData rows 24..27 at y160..184) composites
  -- in the shell, not here: the phone child stays transparent below
  -- y160 so the shell strip (bright/dimmed atlases) shows through.
  -- Painting the phone foreground below 160 would cover the shell
  -- strip, so the isolated y160..168 canvas-black never reaches the
  -- product.
  LogicalSurface.clip(
    graphics --[[@as love.graphics]],
    { x = 0, y = 0, width = SURFACE_WIDTH, height = MAIN_PLANE_HEIGHT },
    function()
      drawRequiredPlane(
        graphics --[[@as love.graphics]],
        images --[[@as table<string, unknown>]],
        foreground --[[@as string]],
        "foreground"
      )
    end
  )
  -- The selected-row corners answer card focus, never the list alone:
  -- while the shell strip owns focus the strip paints its own corners
  -- at the focused cell, so the list hides its frame instead of
  -- doubling the indicator (source PhoneContactListUI_SetCursorSpritePos
  -- hides the list cursor in the switch zone). A live call hides the
  -- corners with the row cursor by the same rule. Direct draws without
  -- a shell keep the historical card-owned frame.
  local stripOwnsFocus = type(shell) == "table" and (shell --[[@as table<string, unknown>]]).entered == false
  -- The fixed tick behind the corner/arrow blink: the composed shell
  -- owns the clock so every focus indicator steps together; direct
  -- draws without a shell fall back to the list's own tick.
  local animTick = 0
  if
    type(shell) == "table" and type((shell --[[@as table<string, unknown>]]).ticks) == "number"
  then
    animTick = (shell --[[@as table<string, unknown>]]).ticks --[[@as integer]]
  elseif
    type(list) == "table" and type((list --[[@as table<string, unknown>]]).animationTick) == "number"
  then
    animTick = (list --[[@as table<string, unknown>]]).animationTick --[[@as integer]]
  end
  if type(list) == "table" then
    drawList(
      graphics --[[@as love.graphics]],
      images --[[@as table<string, unknown>]],
      nameText --[[@as table<string, unknown>?]],
      text --[[@as table<string, unknown>?]],
      list --[[@as table<string, unknown>]],
      assert(sprites, "the phone plan resolves its sprite set") --[[@as table<string, unknown>]],
      assert(palette, "the phone plan resolves its list palette") --[[@as table]],
      type(call) ~= "table" and not stripOwnsFocus,
      animTick
    )
  end
  local menu = view.contextMenu
  if type(menu) == "table" then
    drawMenu(
      graphics --[[@as love.graphics]],
      images --[[@as table<string, unknown>]],
      text --[[@as table<string, unknown>?]],
      menu --[[@as table<string, unknown>]],
      content
    )
  end
  if type(callMenu) == "table" then
    drawMenu(
      graphics --[[@as love.graphics]],
      images --[[@as table<string, unknown>]],
      text --[[@as table<string, unknown>?]],
      callMenu --[[@as table<string, unknown>]],
      content
    )
  end
  if type(call) == "table" and type(callMenu) ~= "table" then
    graphics --[[@as love.graphics]].setColor(1, 1, 1, 1)
    drawSprite(
      graphics --[[@as love.graphics]],
      images --[[@as table<string, unknown>]],
      sprites --[[@as table<string, unknown>]],
      PHONE_SET,
      FAST_FORWARD_SEQUENCE,
      1,
      FAST_FORWARD_X,
      FAST_FORWARD_Y
    )
  end
  local tooltip = view.tooltip
  -- The composed shell paints the tooltip after its strip so the
  -- message stays visible over the card icons; direct draws without a
  -- shell paint it here instead.
  if shell == nil and type(tooltip) == "string" and tooltip ~= "" and type(list) == "table" then
    drawTooltip(
      graphics --[[@as love.graphics]],
      text --[[@as table<string, unknown>?]],
      assert(content.tooltipPalette, "the phone plan resolves its tooltip palette") --[[@as table]],
      tooltip
    )
  end
  (graphics --[[@as love.graphics]]).setColor(1, 1, 1, 1)
end

-- Draws the phone's information pane: the static upper plane, then the
-- live caller name and speech windows only while a call exists. Never
-- paints the contact list here. Names and speech print through the
-- class font at their window-local origins. Reads only; draws
-- deterministically with no allocation.
---@param resources table<string, unknown> borrowed host collaborators
---@param view table<string, unknown> the detached phone view
---@param content table<string, unknown> the plan payload with resolved paths
function PokegearPhoneRenderer.drawInformation(resources, view, content)
  local graphics = assert(resources.graphics, "the phone render borrows its host graphics") --[[@as love.graphics]]
  local images = assert(resources.images, "the phone render borrows its prepared images") --[[@as table<string, unknown>]]
  local text = resources.textRenderer
  assert(type(view) == "table", "the phone render reads its detached view")
  assert(type(content) == "table", "the phone render reads its plan payload")
  local upper = assert(content.upper, "the phone render reads its upper plane from the plan")
  assert(type(upper) == "string", "the phone render reads its upper plane from the plan, got " .. type(content.upper))
  drawRequiredPlane(graphics, images --[[@as table<string, unknown>]], upper --[[@as string]], "upper")
  local call = view.call
  if type(call) == "table" then
    drawCall(
      graphics,
      text --[[@as table<string, unknown>?]],
      call --[[@as table<string, unknown>]],
      assert(content.windowPalette, "the phone plan resolves its window palette") --[[@as table]]
    )
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearPhoneRenderer
