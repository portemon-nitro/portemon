-- Presentation-unit tests keep the menu renderer isolated from script and
-- message infrastructure.

local Assert = require("tests.support.Assert")
local FieldMenuRenderer = require("libs.hgss.src.ui.FieldMenuRenderer")
local MenuLayout = require("libs.hgss.src.ui.MenuLayout")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local FRAME_INDEX = 3

local function fakeGraphics()
  local calls = {}
  local depth = 0
  local lineWidth = 1
  return {
    calls = calls,
    depth = function()
      return depth
    end,
    getLineWidth = function()
      return lineWidth
    end,
    setLineWidth = function(width)
      lineWidth = width
    end,
    push = function(_)
      depth = depth + 1
    end,
    pop = function()
      depth = depth - 1
    end,
    origin = function() end,
    translate = function(_, _) end,
    scale = function(_, _) end,
    transformPoint = function(x, y)
      return x, y
    end,
    intersectScissor = function(_, _, _, _) end,
    setColor = function(_, _, _, _) end,
    rectangle = function(mode, x, y, width, height)
      calls[#calls + 1] = { kind = "rectangle", mode = mode, x = x, y = y, width = width, height = height }
    end,
    polygon = function(mode, ...)
      calls[#calls + 1] = { kind = "polygon", mode = mode, points = { ... } }
    end,
  }
end

local function fakeText(graphics)
  local palette = {}
  for index = 1, 16 do
    palette[index] = { r = index * 10, g = index * 10, b = index * 10 }
  end
  return {
    fontDef = { palette = palette },
    windowBackgroundColor = function()
      return { 0.9, 0.9, 0.9, 1 }
    end,
    drawTextWithPalette = function(_, value, x, y)
      graphics.calls[#graphics.calls + 1] = { kind = "text", text = value, x = x, y = y }
    end,
  }
end

local function fakeWindow(graphics)
  return {
    drawApplicationFrame = function(_, box, frameIndex)
      graphics.calls[#graphics.calls + 1] = { kind = "frame", box = box, frameIndex = frameIndex }
    end,
  }
end

local function renderer(graphics)
  return FieldMenuRenderer.new({ graphics = graphics, text = fakeText(graphics), window = fakeWindow(graphics) })
end

local function layout(count, cancellable, selectedIndex)
  local items = {}
  for index = 1, count do
    items[index] = { text = "Option " .. index, value = index }
  end
  return MenuLayout.resolve({
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      role = "world",
      touch = cancellable,
    }),
    menu = { items = items, cancellable = cancellable, selectedIndex = selectedIndex or 0 },
    measureText = function(text)
      return #text * 8
    end,
  })
end

local function callsOfKind(graphics, kind)
  local result = {}
  for _, call in ipairs(graphics.calls) do
    if call.kind == kind then
      result[#result + 1] = call
    end
  end
  return result
end

function T.draws_the_surface_with_the_players_frame_and_the_selected_row_marker()
  local resolved = layout(3, false, 1)
  local graphics = fakeGraphics()

  renderer(graphics):draw({ status = { selectedIndex = 1 }, layout = resolved }, FRAME_INDEX)

  local frames = callsOfKind(graphics, "frame")
  Assert.equal(#frames, 1)
  Assert.equal(frames[1].frameIndex, FRAME_INDEX)
  Assert.deepEqual(frames[1].box, resolved.listSurface.surface)
  local markers = {}
  for _, call in ipairs(callsOfKind(graphics, "rectangle")) do
    if call.mode == "line" then
      markers[#markers + 1] = call
    end
  end
  Assert.equal(#markers, 1, "only the selected row carries the marker")
  local marker = resolved.rows[2].marker
  Assert.equal(markers[1].x, marker.x + 1)
  Assert.equal(markers[1].y, marker.y + 1)
  Assert.equal(graphics.depth(), 0, "the draw scope is balanced")
end

function T.draws_zero_based_layout_rows_in_visual_order()
  local resolved = layout(3, false)
  local graphics = fakeGraphics()

  renderer(graphics):draw({ status = { selectedIndex = 0 }, layout = resolved }, FRAME_INDEX)

  local texts = {}
  for _, call in ipairs(callsOfKind(graphics, "text")) do
    texts[#texts + 1] = call.text
  end
  Assert.deepEqual(texts, { "Option 1", "Option 2", "Option 3" })
end

function T.scrolled_lists_draw_only_resolved_rows_with_indicators_and_touch_cancel()
  local resolved = layout(20, true, 19)
  local graphics = fakeGraphics()

  renderer(graphics):draw({ status = { selectedIndex = 19 }, layout = resolved }, FRAME_INDEX)

  local texts = {}
  for _, call in ipairs(callsOfKind(graphics, "text")) do
    texts[#texts + 1] = call.text
  end
  Assert.equal(texts[#texts], "Cancel")
  Assert.equal(#texts - 1, #resolved.rows, "only materialized rows are drawn")
  Assert.isTrue(#resolved.rows < 20)
  Assert.equal(texts[#texts - 1], "Option 20")
  Assert.equal(#callsOfKind(graphics, "polygon"), 1, "only the upward indicator shows at the end of the list")
end

function T.rejects_a_presentation_selection_outside_the_resolved_layout()
  local resolved = layout(2, false)
  local graphics = fakeGraphics()

  local err = Assert.throws(function()
    renderer(graphics):draw({ status = { selectedIndex = 2 }, layout = resolved }, FRAME_INDEX)
  end)

  Assert.isTrue(tostring(err):find("field menu selected index is outside the resolved layout", 1, true) ~= nil)
end

return { tests = T }
