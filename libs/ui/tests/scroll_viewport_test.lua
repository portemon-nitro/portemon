-- Stateless logical scroll geometry for measured viewports and uniform rows.

local Assert = require("tests.support.Assert")

local T = {}

local function viewport()
  local loaded, value = pcall(require, "libs.ui.src.ScrollViewport")
  Assert.isTrue(loaded, "shared scroll viewport geometry must be available")
  return value
end

local function enumeratedRange(offset, viewportExtent, itemExtent, gap, count)
  local first1, last1 = nil, nil
  local viewportEnd = offset + viewportExtent
  for index = 1, count do
    local rowStart = (index - 1) * (itemExtent + gap)
    local rowEnd = rowStart + itemExtent
    if rowEnd > offset and rowStart < viewportEnd then
      first1 = first1 or index
      last1 = index
    end
  end
  return first1 or 1, last1 or 0
end

function T.shared_geometry_clamps_reveals_and_enumerates_half_open_rows()
  local ScrollViewport = viewport()

  Assert.equal(ScrollViewport.clamp(11.5, 30, 8), 11.5)
  Assert.equal(ScrollViewport.clamp(30, 30, 8), 22)
  Assert.equal(ScrollViewport.clamp(4, 3, 8), 0)

  Assert.equal(ScrollViewport.reveal(4.25, 10, 8, 2), 4.25, "visible items keep the exact fractional offset")
  Assert.equal(ScrollViewport.reveal(12.5, 10, 3, 2), 3, "items above the viewport align to their start")
  Assert.equal(ScrollViewport.reveal(4, 6, 14, 10), 14, "oversize items align to their start")
  Assert.equal(ScrollViewport.reveal(4, 0, 12, 2), 12, "a zero viewport aligns the item start")

  local cases = {
    { 3.5, 12, 5, 2, 5 },
    { 10, 4, 10, 0, 4 },
    { 11, 2, 10, 4, 5 },
    { 0, 0, 10, 4, 5 },
    { 0, 20, 10, 4, 0 },
  }
  for _, case in ipairs(cases) do
    local expectedFirst, expectedLast = enumeratedRange(case[1], case[2], case[3], case[4], case[5])
    local first1, last1 = ScrollViewport.visibleRange(case[1], case[2], case[3], case[4], case[5])
    Assert.equal(first1, expectedFirst)
    Assert.equal(last1, expectedLast)
  end
  Assert.deepEqual({ ScrollViewport.visibleRange(11, 2, 10, 4, 5) }, { 1, 0 }, "a viewport in a gap is empty")
  Assert.deepEqual({ ScrollViewport.visibleRange(0, 0, 10, 4, 5) }, { 1, 0 }, "a zero viewport is empty")

  Assert.throws(function()
    ScrollViewport.clamp(0 / 0, 1, 1)
  end)
  Assert.throws(function()
    ScrollViewport.clamp(0, -1, 1)
  end)
  Assert.throws(function()
    ScrollViewport.clamp(0, 1, -1)
  end)
  Assert.throws(function()
    ScrollViewport.reveal(0, math.huge, 0, 1)
  end)
  Assert.throws(function()
    ScrollViewport.reveal(0, 1, -1, 1)
  end)
  Assert.throws(function()
    ScrollViewport.reveal(0, 1, 0, -1)
  end)
  Assert.throws(function()
    ScrollViewport.visibleRange(0, 1, 0, 0, 1)
  end)
  Assert.throws(function()
    ScrollViewport.visibleRange(0, 1, 1, -1, 1)
  end)
  Assert.throws(function()
    ScrollViewport.visibleRange(0, 1, 1, 0, 1.5)
  end)
end

return { tests = T }
