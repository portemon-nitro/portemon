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

-- Sixteen list colors with distinct red channels so fills map back to indices.
---@return table palette
local function distinctPalette()
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = index, g = 0, b = 0 }
  end
  return palette
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
    { graphics = graphics, images = {}, textRenderer = stubText() },
    { list = list },
    { skin = 0, sprites = {}, listPalette = distinctPalette() }
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
    { graphics = graphics, images = {}, textRenderer = stubText() },
    { list = list },
    { skin = 0, sprites = {}, listPalette = distinctPalette() }
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

---@return table recorder logging its palette lines
local function recordingText()
  local calls = {}
  local renderer = {}
  function renderer.drawTextWithPalette(_, line, x, y, _)
    calls[#calls + 1] = { line = line, x = x, y = y }
  end
  function renderer.drawText(_, line, x, y)
    calls[#calls + 1] = { line = line, x = x, y = y }
  end
  renderer._calls = calls
  return renderer --[[@as table]]
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
    { graphics = graphics, images = {}, textRenderer = classText, phoneNameTextRenderer = nameText },
    { list = list },
    { skin = 0, sprites = {}, listPalette = distinctPalette() }
  )
  Assert.equal(#nameText._calls, 1, "the name cell prints once through the name font")
  Assert.equal(recordedLine(nameText._calls[1]), "NAME-1", "the name cell prints the contact name")
  Assert.equal(#classText._calls, 1, "the class cell prints once through the class font")
  Assert.equal(recordedLine(classText._calls[1]), "CLASS-1", "the class cell prints the contact class")
end

-- Without a composed name font the list keeps its single-renderer path:
-- both cells print through the borrowed text renderer.
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
    { graphics = graphics, images = {}, textRenderer = shared },
    { list = list },
    { skin = 0, sprites = {}, listPalette = distinctPalette() }
  )
  Assert.equal(#shared._calls, 2, "both cells print through the borrowed renderer")
end

return { tests = T }
