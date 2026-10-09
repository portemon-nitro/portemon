-- Framed scrollable list geometry: bounded visible windows, shared text and
-- marker rects, and measured preferred width.

local Assert = require("tests.support.Assert")
local List = require("libs.ui.src.ListSurface")

local T = { tests = {} }

function T.tests.resolves_bounded_row_major_windows_inside_the_surface()
  for _, bounds in ipairs({
    { x = 0, y = 0, width = 256, height = 192 },
    { x = 0, y = 0, width = 800, height = 600 },
  }) do
    local list = List.resolve({
      bounds = bounds,
      rowCount = 12,
      rowHeight = 24,
      gap = 2,
      maxWidth = 480,
    })
    Assert.isTrue(list.surface.x >= bounds.x)
    Assert.isTrue(list.surface.x + list.surface.width <= bounds.x + bounds.width)
    Assert.equal(list.surface.width, math.min(bounds.width, 480), "the list width clamps to its maximum")
    Assert.equal(
      list.surface.x,
      bounds.x + (bounds.width - list.surface.width) / 2,
      "the list is horizontally centered"
    )
    Assert.isTrue(
      list.content.x >= list.surface.x and list.content.x + list.content.width <= list.surface.x + list.surface.width
    )
    Assert.equal(list.contentHeight, 12 * 24 + 11 * 2, "the total extent still covers every logical row")
    Assert.isTrue(list.firstIndex >= 1 and list.lastIndex <= 12, "the window stays within the logical rows")
    Assert.isTrue(#list.rows <= 12, "only the visible window materializes row geometry")
    Assert.equal(#list.rows, list.lastIndex - list.firstIndex + 1, "the window is densely packed")
    for position, row in ipairs(list.rows) do
      Assert.equal(row.index, list.firstIndex + position - 1, "visible rows keep their logical identity")
      Assert.isTrue(row.hitRect.width > 0 and row.hitRect.height > 0)
      Assert.isTrue(row.rect.y >= list.content.y)
      if position > 1 then
        Assert.isTrue(row.rect.y >= list.rows[position - 1].rect.y + list.rows[position - 1].rect.height + 2)
      end
    end

    local scrolled = List.resolve({
      bounds = bounds,
      rowCount = 12,
      rowHeight = 24,
      gap = 2,
      maxWidth = 480,
      scrollOffset = 12 * (24 + 2),
    })
    Assert.equal(scrolled.contentHeight, list.contentHeight, "scrolling never changes the total extent")
    Assert.equal(#scrolled.rows, scrolled.lastIndex - scrolled.firstIndex + 1, "a scrolled window stays densely packed")
    for position, row in ipairs(scrolled.rows) do
      Assert.equal(row.index, scrolled.firstIndex + position - 1)
    end
    if list.contentHeight > list.content.height then
      Assert.isTrue(scrolled.firstIndex > 1, "a scrolled window starts past the first logical row")
      Assert.isTrue(#scrolled.rows < 12, "a scrolled window still materializes a bounded subset")
    else
      Assert.equal(scrolled.firstIndex, 1, "a fitting list keeps its first row under scroll pressure")
    end
  end

  Assert.throws(function()
    List.resolve({
      bounds = { x = 0, y = 0, width = 0, height = 192 },
      rowCount = 1,
      rowHeight = 24,
      gap = 0,
      maxWidth = 300,
    })
  end, "invalid list bounds fail loudly")
end

function T.tests.preferred_width_measures_a_bounded_stable_sample()
  local List = require("libs.ui.src.ListSurface")
  local measuredRows = {}
  local labels = { "short", "a much longer flag label", "later catalog row" }
  local preferred = List.preferredWidth({
    bounds = { x = 0, y = 0, width = 180, height = 72 },
    rowCount = 10000,
    rowHeight = 18,
    gap = 0,
    hasTrailingValue = true,
    trailingValueWidth = 18,
    font = {
      lineHeight = 16,
      measure = function(text)
        return #text * 6
      end,
    },
    rowAt = function(index)
      measuredRows[#measuredRows + 1] = index
      return { label = labels[index] or "later catalog row" }
    end,
  })

  Assert.equal(
    preferred,
    math.ceil(math.min(24 * 6, #labels[2] * 6) + 10 + 18 + 4 + 10),
    "the measured row and value fit their C02 gutters"
  )
  Assert.equal(#measuredRows, 8, "measurement visits at most two viewport windows")
  Assert.deepEqual(measuredRows, { 1, 2, 3, 4, 5, 6, 7, 8 }, "the intrinsic sample is stable from the projection head")
end

function T.tests.marker_outline_restores_line_width_and_leaves_the_requested_color()
  local state = { lineWidth = 3 }
  local calls = {}
  local graphics = {
    getLineWidth = function()
      return state.lineWidth
    end,
    setLineWidth = function(width)
      state.lineWidth = width
    end,
    setColor = function(r, g, b, a)
      state.color = { r, g, b, a }
    end,
    rectangle = function(mode, x, y, width, height, rx, ry)
      calls[#calls + 1] = { mode, x, y, width, height, rx, ry, state.lineWidth }
    end,
  }

  List.drawMarker(graphics, { x = 10, y = 20, width = 100, height = 6 }, 4, { 1, 0, 0, 1 })

  Assert.deepEqual(calls, { { "line", 11, 21, 98, 4, 3, 3, 2 } }, "the radius clamps to half the marker height")
  Assert.equal(state.lineWidth, 3)
  Assert.deepEqual(state.color, { 1, 0, 0, 1 })
end

return T
