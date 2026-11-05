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

local NAME_WINDOW = { x = 32, y = 128, width = 72, height = 16 }
local SPEECH_WINDOW = { x = 16, y = 152, width = 216, height = 32 }

-- Source call-window colors on SUB_2 (sWindowTemplates windows[0,1],
-- palette 1): the source clears both pixel buffers to fill 0 and prints
-- every call line in text color (1,2,0), so both fills and both text
-- cells resolve through the window palette, never invented triples or
-- plain text.
local CALL_WINDOW_FILL = 0
local CALL_TEXT_FOREGROUND = 1
local CALL_TEXT_SHADOW = 2
local CALL_TEXT_BACKGROUND = 0

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
-- logical destination jump.
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
        drawSprite(graphics, images, sprites, PHONE_SET, CORNER_SEQUENCES[index], 1, point[1], point[2])
      end
    end
  end
  local first = visualFirst(list, scrollOffset)
  if first > 0 then
    drawSprite(graphics, images, sprites, PHONE_SET, SCROLL_UP_SEQUENCE, 1, 124, 8)
  end
  if type(total) == "number" and first + VISIBLE_ROWS < total then
    drawSprite(graphics, images, sprites, PHONE_SET, SCROLL_DOWN_SEQUENCE, 1, 124, 156)
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
---@param selected integer
---@param manual boolean
---@param sprites table<string, unknown>
---@param palette table<integer, table<string, number>>
---@param colorIdx integer zero-based row color set
local function drawRow(graphics, images, nameText, classText, entry, absolute, top, selected, manual, sprites, palette, colorIdx)
  local colors = ROW_COLORS[colorIdx + 1]
  fillPalette(graphics, palette, colors.fill1, LIST_X, top, ROW_WIDTH, ROW_HEIGHT)
  fillPalette(graphics, palette, colors.bg1, LIST_X + NAME_CELL_X, top, NAME_CELL_WIDTH, CELL_HEIGHT)
  fillPalette(graphics, palette, colors.bg2, LIST_X + CLASS_CELL_X, top, CLASS_CELL_WIDTH, CELL_HEIGHT)
  fillPalette(graphics, palette, colors.fill2, LIST_X + 1, top + 1, 2, 2)
  fillPalette(graphics, palette, colors.fill1, LIST_X + 8, top, 2, 7)
  for _, dotY in ipairs({ 9, 13, 17 }) do
    fillPalette(graphics, palette, colors.fill1, LIST_X + 9, top + dotY, 2, 2)
  end
  local isSelected = absolute == selected
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
    local sequence = isSelected and MOVE_SELECTED_SEQUENCE or MOVE_SEQUENCE
    drawSprite(graphics, images, sprites, PHONE_SET, sequence, 1, 12, top + 12)
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
local function drawList(graphics, images, nameText, classText, list, sprites, palette)
  local rows = list.rows --[[@as table[] ]]
  local selected = list.selected --[[@as integer]]
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
      for slot = 0, VISIBLE_ROWS - 1 do
        local entry = bySlot[slot]
        local top = LIST_Y + slot * ROW_HEIGHT
        if entry ~= nil then
          local resolved = assert(
            (entry --[[@as table<string, unknown>]]).absolute,
            "the settled strip carries absolute contact indices"
          ) --[[@as integer]]
          local settled = PokegearPhoneRenderer.slotColorIndex(slot, firstBgColor)
          drawRow(graphics, images, nameText, classText, entry, resolved, top, selected, manual, sprites, palette, settled)
        else
          drawEmptyBand(graphics, top, palette, PokegearPhoneRenderer.slotColorIndex(slot, firstBgColor))
        end
      end
    end
  end
  -- The viewport clip follows the active placement transform, so the
  -- rows stay inside the list window on every display configuration.
  -- A raw device scissor would pin unscaled pixels and hide the list
  -- whenever the placement scales or offsets the surface.
  LogicalSurface.clip(
    graphics,
    { x = LIST_X, y = LIST_Y, width = ROW_WIDTH, height = VISIBLE_ROWS * ROW_HEIGHT },
    paintRows
  )
  graphics.setColor(1, 1, 1, 1)
  drawListChrome(graphics, images, list, sprites)
end

-- Draws the context menu through the shared touchscreen list-menu
-- frame: the same staged tile strip every framed app menu draws. The
-- detached frame stays in tiles end-to-end.
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
  })
end

-- Draws the call speech/name windows from the conversation projection
-- through the window palette: the resolved caller name and the current
-- source text page. Owed choices never paint here; they ride the
-- shared list-menu frame beside the windows.
---@param graphics love.graphics
---@param nameText table<string, unknown>? the borrowed font-4 name renderer
---@param text table<string, unknown>? the borrowed message renderer
---@param call table<string, unknown>
---@param palette table<integer, table<string, number>> sixteen window colors, one-based
local function drawCall(graphics, nameText, text, call, palette)
  fillPalette(graphics, palette, CALL_WINDOW_FILL, NAME_WINDOW.x, NAME_WINDOW.y, NAME_WINDOW.width, NAME_WINDOW.height)
  drawPaletteText(
    nameText,
    palette,
    tostring(call.name),
    NAME_WINDOW.x + 4,
    NAME_WINDOW.y + 2,
    CALL_TEXT_FOREGROUND,
    CALL_TEXT_SHADOW,
    CALL_TEXT_BACKGROUND
  )
  fillPalette(
    graphics,
    palette,
    CALL_WINDOW_FILL,
    SPEECH_WINDOW.x,
    SPEECH_WINDOW.y,
    SPEECH_WINDOW.width,
    SPEECH_WINDOW.height
  )
  local pages = call.lines
  local page = call.page
  local body = ""
  if type(pages) == "table" and type(page) == "number" and type(pages[page]) == "table" then
    body = tostring(pages[page].text)
  end
  drawPaletteText(
    text,
    palette,
    body,
    SPEECH_WINDOW.x + 4,
    SPEECH_WINDOW.y + 4,
    CALL_TEXT_FOREGROUND,
    CALL_TEXT_SHADOW,
    CALL_TEXT_BACKGROUND
  )
  graphics.setColor(1, 1, 1, 1)
end

-- Source palette indices of the context tooltip window (windows[3])
-- in its own palette bank: the strip fill, and the foreground, shadow,
-- and background of the centered prompt.
local TOOLTIP_FILL = 5
local TOOLTIP_FOREGROUND = 3
local TOOLTIP_SHADOW = 2

-- windows[3] behind the context tooltip (MAIN_1 tile (0,21), 32x2): the
-- strip the source fills behind the centered prompt.
local TOOLTIP_STRIP = { x = 0, y = 168, width = 256, height = 16 }

-- The bottom tooltip bar: windows[3] paints its strip in fill 5 behind
-- the menu prompt centered in the 3/2/5 combination of the window's
-- own palette bank, never the list palette. The source saves and
-- restores the covered tilemap rect around the window; the
-- retained-mode renderer repaints every frame, so it paints only.
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
  drawPaletteText(text, palette, line, x, TOOLTIP_STRIP.y, TOOLTIP_FOREGROUND, TOOLTIP_SHADOW, TOOLTIP_FILL)
end

-- Draws the published phone surface with borrowed collaborators: the
-- per-skin background plane with the clipped contact list, its tooltip
-- strip, and the context window while browsing; the conversation
-- windows with the owed-choice list menu while a call is live. The
-- live call never repaints the contact list here: the list rides the
-- information-pane render path. Reads only; draws deterministically
-- with no allocation.
---@param resources table<string, unknown> borrowed host collaborators
---@param view table<string, unknown> the detached phone view
---@param content table<string, unknown> the plan payload with resolved paths
function PokegearPhoneRenderer.draw(resources, view, content)
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
  local foreground = assert(content.foreground, "the phone render reads its foreground plane from the plan")
  assert(
    type(foreground) == "string",
    "the phone render reads its foreground plane from the plan, got " .. type(content.foreground)
  )
  drawRequiredPlane(
    graphics --[[@as love.graphics]],
    images --[[@as table<string, unknown>]],
    foreground --[[@as string]],
    "foreground"
  )
  local list = view.list
  local call = view.call
  if type(call) == "table" then
    drawCall(
      graphics --[[@as love.graphics]],
      nameText --[[@as table<string, unknown>?]],
      text --[[@as table<string, unknown>?]],
      call --[[@as table<string, unknown>]],
      assert(content.windowPalette, "the phone plan resolves its window palette") --[[@as table]]
    )
    local callMenu = view.callMenu
    if type(callMenu) == "table" then
      drawMenu(
        graphics --[[@as love.graphics]],
        images --[[@as table<string, unknown>]],
        text --[[@as table<string, unknown>?]],
        callMenu --[[@as table<string, unknown>]],
        content
      )
    end
  else
    if type(list) == "table" then
      drawList(
        graphics --[[@as love.graphics]],
        images --[[@as table<string, unknown>]],
        nameText --[[@as table<string, unknown>?]],
        text --[[@as table<string, unknown>?]],
        list --[[@as table<string, unknown>]],
        assert(content.sprites, "the phone plan resolves its sprite set") --[[@as table<string, unknown>]],
        assert(content.listPalette, "the phone plan resolves its list palette") --[[@as table]]
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
  end
  local tooltip = view.tooltip
  if type(tooltip) == "string" and tooltip ~= "" and type(list) == "table" then
    drawTooltip(
      graphics --[[@as love.graphics]],
      text --[[@as table<string, unknown>?]],
      assert(content.tooltipPalette, "the phone plan resolves its tooltip palette") --[[@as table]],
      tooltip
    )
  end
  (graphics --[[@as love.graphics]]).setColor(1, 1, 1, 1)
end

-- Draws the phone's information pane: the static upper plane with the
-- live contact list from the plan payload, so the MAIN_3 rows stay
-- visible while the controls pane carries the call speech and name.
-- Names print through the borrowed name-font renderer exactly like the
-- browsing list, falling back to the class renderer when the host
-- composes no name font.
---@param resources table<string, unknown> borrowed host collaborators
---@param content table<string, unknown> the plan payload with resolved paths
function PokegearPhoneRenderer.drawInformation(resources, content)
  local graphics = assert(resources.graphics, "the phone render borrows its host graphics") --[[@as love.graphics]]
  local images = assert(resources.images, "the phone render borrows its prepared images") --[[@as table<string, unknown>]]
  local text = resources.textRenderer
  local nameText = resources.phoneNameTextRenderer
  if nameText == nil then
    nameText = text
  end
  local upper = assert(content.upper, "the phone render reads its upper plane from the plan")
  assert(type(upper) == "string", "the phone render reads its upper plane from the plan, got " .. type(content.upper))
  drawRequiredPlane(graphics, images --[[@as table<string, unknown>]], upper --[[@as string]], "upper")
  local callList = content.callList
  if type(callList) == "table" then
    drawList(
      graphics,
      images,
      nameText --[[@as table<string, unknown>?]],
      text --[[@as table<string, unknown>?]],
      callList --[[@as table<string, unknown>]],
      assert(content.sprites, "the phone plan resolves its sprite set") --[[@as table<string, unknown>]],
      assert(content.listPalette, "the phone plan resolves its list palette") --[[@as table]]
    )
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearPhoneRenderer
