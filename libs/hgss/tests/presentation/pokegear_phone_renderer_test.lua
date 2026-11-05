-- Phone list band parity: the alternating row colors follow the visible slot
-- with the source scroll-flip flag, never the absolute contact index. Pure
-- presentation mapping ported from PhoneContactListUI_GetBackgroundIndex.

local Assert = require("tests.support.Assert")
local PokegearPhoneRenderer = require("libs.hgss.src.presentation.PokegearPhoneRenderer")

local T = {}

local LIST_X = 8
local ROW_WIDTH = 216

---@return table fake graphics recording fills
local function recordingGraphics()
  local fills = {}
  local graphics = {}
  function graphics.setColor(r, g, b, a)
    graphics._color = { r = r, g = g, b = b, a = a }
  end
  function graphics.rectangle(mode, x, y, width, height)
    fills[#fills + 1] = { mode = mode, x = x, y = y, width = width, height = height, color = graphics._color }
  end
  function graphics.push(_)
  end
  function graphics.pop()
  end
  function graphics.origin()
  end
  function graphics.translate(_, _)
  end
  function graphics.scale(_, _)
  end
  function graphics.intersectScissor(_, _, _, _)
  end
  function graphics.transformPoint(x, y)
    return x, y
  end
  graphics._fills = fills
  return graphics --[[@as table]]
end

---@return table stub text renderer recording nothing
local function stubText()
  return {
    drawText = function(_, _, _, _)
    end,
    drawTextWithPalette = function(_, _, _, _, _)
    end,
  }
end

-- windows[3] behind the context tooltip (MAIN_1 tile (0,21), 32x2,
-- palette 10): the strip fills with palette index 5 behind the prompt
-- centered in the 3/2/5 combination.
local TOOLTIP_STRIP = { x = 0, y = 168, width = 256, height = 16 }

---@param width number measured text width
---@return table stub text renderer recording palette draws
local function recordingText(width)
  local calls = {}
  return {
    textWidth = function(_, _)
      return width
    end,
    drawText = function(_, _, _, _)
    end,
    drawTextWithPalette = function(_, line, x, y, palette)
      calls[#calls + 1] = { line = line, x = x, y = y, palette = palette }
    end,
    _calls = calls,
  }
end

-- Sixteen list colors with distinct red channels so fills map back to indices.
---@return table palette
local function distinctPalette()
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = index, g = 0, b = 0 }
  end
  return palette
end

-- Prepared plane leases behind the required foreground and upper planes:
-- the source always loads both before the first paint, so every draw
-- composes them and never exercises a fallback fill.
---@return table images
local function planeImages()
  local lease = {
    draw = function(_, _, _, _) end,
  }
  return { ["test-foreground"] = lease, ["test-upper"] = lease }
end

---@param count integer
---@return table rows with settled slots
local function settledRows(count)
  local rows = {}
  for slot = 0, count - 1 do
    rows[#rows + 1] = { absolute = slot, slot = slot, contact = "c" .. slot, label = "N", class = "C" }
  end
  return rows
end

---@param graphics table
---@param firstBg integer
local function drawList(graphics, firstBg)
  local list = {
    rows = settledRows(6),
    selected = 0,
    scrollOffset = 0,
    firstBgColor = firstBg,
    manual = false,
    total = 6,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = planeImages(), textRenderer = stubText() },
    { list = list },
    { skin = 0, sprites = {}, foreground = "test-foreground", listPalette = distinctPalette() }
  )
end

---@param graphics table
---@param slot integer zero-based slot
---@return number? red channel of the 216x24 band fill at that slot
local function bandRed(graphics, slot)
  for _, fill in ipairs(graphics._fills) do
    if fill.width == ROW_WIDTH and fill.height == 24 and fill.x == LIST_X and fill.y == 16 + slot * 24 then
      return fill.color.r
    end
  end
  return nil
end

-- Source row set 0 carries palette index 14, set 1 carries 11
-- (PokegearPhoneRenderer ROW_COLORS fill1 entries).
function T.band_colors_follow_slot_parity_not_absolute_index()
  local graphics = recordingGraphics()
  drawList(graphics, 0)
  Assert.equal(bandRed(graphics, 0), 14 / 255, "slot 0 paints the set-1 band")
  Assert.equal(bandRed(graphics, 1), 11 / 255, "slot 1 paints the set-0 band")
  Assert.equal(bandRed(graphics, 2), 14 / 255, "slot 2 paints the set-1 band")
end

---@param graphics table
---@param y number
---@return number? red channel of the 216x24 band fill at that surface y
local function bandRedAt(graphics, y)
  for _, fill in ipairs(graphics._fills) do
    if fill.width == ROW_WIDTH and fill.height == 24 and fill.x == LIST_X and fill.y == y then
      return fill.color.r
    end
  end
  return nil
end

function T.sliding_bands_travel_with_their_rows()
  local graphics = recordingGraphics()
  local rows = {}
  for slot = 0, 6 do
    rows[#rows + 1] = { absolute = slot, slot = slot, contact = "c" .. slot, label = "N", class = "C" }
  end
  local list = {
    rows = rows,
    selected = 6,
    scrollOffset = 1,
    firstBgColor = 0,
    slide = { first = 0, from = 0, direction = 1, pixels = -8 },
    manual = false,
    -- Six contacts keep the chrome quiet so the band fills speak alone.
    total = 6,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = planeImages(), textRenderer = stubText() },
    { list = list },
    { skin = 0, sprites = {}, foreground = "test-foreground", listPalette = distinctPalette() }
  )
  Assert.equal(
    bandRedAt(graphics, 16 - 8),
    14 / 255,
    "the outgoing row keeps its band one tick in"
  )
  Assert.equal(
    bandRedAt(graphics, 16 + 24 - 8),
    11 / 255,
    "the next traveling row keeps its alternating band"
  )
  Assert.equal(
    bandRedAt(graphics, 16 + 2 * 24 - 8),
    14 / 255,
    "a further traveling row keeps its band one tick in"
  )
end

function T.scroll_flip_flag_inverts_every_band()
  local graphics = recordingGraphics()
  drawList(graphics, 1)
  Assert.equal(bandRed(graphics, 0), 11 / 255, "slot 0 paints the set-0 band while flipped")
  Assert.equal(bandRed(graphics, 1), 14 / 255, "slot 1 paints the set-1 band while flipped")
end

---@param record table a recorded palette line
---@return string its printed line
local function recordedLine(record)
  return record.line
end

-- The source prints the contact name with font 4 and the class with
-- font 0 (PrintNameAndClass): the two cells draw through separate
-- font-baked text renderers, never one shared path.
function T.list_name_and_class_print_through_their_source_fonts()
  local graphics = recordingGraphics()
  local nameText = recordingText()
  local classText = recordingText()
  local list = {
    rows = { { absolute = 0, slot = 0, contact = "mom", label = "NAME-1", class = "CLASS-1" } },
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = false,
    total = 1,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = planeImages(), textRenderer = classText, phoneNameTextRenderer = nameText },
    { list = list },
    { skin = 0, sprites = {}, foreground = "test-foreground", listPalette = distinctPalette() }
  )
  Assert.equal(#nameText._calls, 1, "the name cell prints once through the name font")
  Assert.equal(recordedLine(nameText._calls[1]), "NAME-1", "the name cell prints the contact name")
  Assert.equal(#classText._calls, 1, "the class cell prints once through the class font")
  Assert.equal(recordedLine(classText._calls[1]), "CLASS-1", "the class cell prints the contact class")
end

-- Without a composed name font the list keeps its single-renderer path:
-- both cells print through the borrowed text renderer.
-- The information pane prints the live list with the same font split:
-- names through the borrowed name font, classes through the class
-- renderer, falling back to the single renderer when no name font
-- is composed.
function T.information_list_keeps_the_source_font_split()
  local graphics = recordingGraphics()
  local nameText = recordingText()
  local classText = recordingText()
  local content = {
    skin = 0,
    sprites = {},
    foreground = "test-foreground",
    upper = "test-upper",
    listPalette = distinctPalette(),
    callList = {
      rows = { { absolute = 0, slot = 0, contact = "mom", label = "NAME-1", class = "CLASS-1" } },
      selected = 0,
      scrollOffset = 0,
      firstBgColor = 0,
      manual = false,
      total = 1,
      cursorVisible = false,
    },
  }
  PokegearPhoneRenderer.drawInformation(
    { graphics = graphics, images = planeImages(), textRenderer = classText, phoneNameTextRenderer = nameText },
    content
  )
  Assert.equal(#nameText._calls, 1, "the information name prints once through the name font")
  Assert.equal(recordedLine(nameText._calls[1]), "NAME-1", "the information name prints the contact name")
  Assert.equal(#classText._calls, 1, "the information class prints once through the class font")
end

function T.list_cells_share_the_borrowed_renderer_without_a_name_font()
  local graphics = recordingGraphics()
  local shared = recordingText()
  local list = {
    rows = { { absolute = 0, slot = 0, contact = "mom", label = "NAME-1", class = "CLASS-1" } },
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = false,
    total = 1,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = planeImages(), textRenderer = shared },
    { list = list },
    { skin = 0, sprites = {}, foreground = "test-foreground", listPalette = distinctPalette() }
  )
  Assert.equal(#shared._calls, 2, "both cells print through the borrowed renderer")
end

---@param graphics table
---@param text table
---@param line string
local function drawWithTooltip(graphics, text, line)
  local list = {
    rows = settledRows(6),
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = false,
    total = 6,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = planeImages(), textRenderer = text },
    { list = list, tooltip = line },
    { skin = 0, sprites = {}, foreground = "test-foreground", listPalette = distinctPalette(), tooltipPalette = distinctPalette() }
  )
end

function T.tooltip_paints_its_strip_behind_centered_text()
  local graphics = recordingGraphics()
  local text = recordingText(100)
  drawWithTooltip(graphics, text, "tip")
  local strip = nil
  for _, fill in ipairs(graphics._fills) do
    if
      fill.x == TOOLTIP_STRIP.x
      and fill.y == TOOLTIP_STRIP.y
      and fill.width == TOOLTIP_STRIP.width
      and fill.height == TOOLTIP_STRIP.height
    then
      strip = fill
    end
  end
  Assert.notNil(strip, "the tooltip paints its windows[3] strip")
  assert(strip ~= nil, "the tooltip strip painted above")
  Assert.equal(strip.color.r, 5 / 255, "the strip fills with palette index 5")
  local prompt = nil
  for _, call in ipairs(text._calls) do
    if call.line == "tip" then
      prompt = call
    end
  end
  Assert.notNil(prompt, "the tooltip prints its prompt")
  assert(prompt ~= nil, "the tooltip prompt printed above")
  Assert.equal(prompt.x, 78, "the prompt centers in the surface")
  Assert.equal(prompt.y, 168, "the prompt prints at the strip top")
  Assert.equal(prompt.palette.foreground.r, 3, "the prompt foreground is palette index 3")
  Assert.equal(prompt.palette.shadow.r, 2, "the prompt shadow is palette index 2")
  Assert.equal(prompt.palette.background.r, 5, "the prompt background is palette index 5")
end

-- The context menu keeps tile geometry end-to-end: sContextMenuParam
-- tiles reach the shared list-menu frame with no pixel round-trip, so
-- width 16 frames the interior sixteen tiles (eighteen total).
function T.context_menu_frame_stays_in_tiles()
  local graphics = recordingGraphics()
  function graphics.newQuad(_, _, _, _, _, _, _)
    return {}
  end
  local tileDraws = {}
  local lease = {
    image = {
      getDimensions = function()
        return 256, 16
      end,
    },
    drawQuad = function(_, _, _, x, y)
      tileDraws[#tileDraws + 1] = { x = x, y = y }
    end,
  }
  local text = recordingText(40)
  local list = {
    rows = settledRows(6),
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = false,
    total = 6,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw({
    graphics = graphics,
    images = { ["menu-tiles"] = lease, ["test-foreground"] = planeImages()["test-foreground"] },
    textRenderer = text,
  }, {
    list = list,
    contextMenu = {
      options = { "a", "b", "c" },
      cursor = 0,
      frame = { x = 13, y = 9, width = 16, height = 10 },
    },
  }, {
    skin = 0,
    sprites = {},
    foreground = "test-foreground",
    listPalette = distinctPalette(),
    menuTiles = "menu-tiles",
    menuPalette = distinctPalette(),
  })
  local topLeft = nil
  for _, tile in ipairs(tileDraws) do
    if tile.x == 13 * 8 and tile.y == 9 * 8 then
      topLeft = tile
    end
  end
  Assert.notNil(topLeft, "the frame paints its top-left tile at the tile origin")
  local entry = nil
  for _, fill in ipairs(graphics._fills) do
    if fill.x == 14 * 8 and fill.y == 13 * 8 and fill.width == 128 and fill.height == 16 then
      entry = fill
    end
  end
  Assert.notNil(entry, "the deselected entry fills inside the tile frame")
  assert(entry ~= nil, "the deselected entry filled above")
  Assert.equal(entry.color.r, 3 / 255, "the deselected entry fills with palette index 3")
end

return { tests = T }
