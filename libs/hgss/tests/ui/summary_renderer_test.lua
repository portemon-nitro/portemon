-- Pure summary presentation contracts: measured pagination windows
-- and the closed native geometry. Drawing itself needs the graphics
-- capability and lives in the graphics suite.

local Assert = require("tests.support.Assert")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")

local T = {}

local function measure(value)
  return #value
end

function T.paginate_splits_measured_words_with_windows()
  local page = SummaryRenderer.paginate(measure, "Cuts with sharp leaves.", 10, 2, 0)
  Assert.deepEqual(page.lines, { "Cuts with", "sharp" }, "words wrap by measured width")
  Assert.equal(page.total, 3, "the total counts every line")
  Assert.isTrue(page.truncated, "overflow reports truncation")
  Assert.isFalse(page.leading, "the first window leads nothing")
  local rest = SummaryRenderer.paginate(measure, "Cuts with sharp leaves.", 10, 2, 2)
  Assert.deepEqual(rest.lines, { "leaves." }, "offsets page forward")
  Assert.isFalse(rest.truncated, "the last window truncates nothing")
  Assert.isTrue(rest.leading, "later windows report their lead")
end

function T.paginate_preserves_source_line_breaks()
  local page = SummaryRenderer.paginate(measure, "first\nsecond", 30, 4, 0)
  Assert.deepEqual(page.lines, { "first", "", "second" }, "hard breaks survive pagination")
  Assert.equal(page.total, 3, "blank separators count toward the total")
end

function T.layout_matches_the_required_native_geometry()
  local layout = SummaryRenderer.layout(4)
  Assert.deepEqual(layout.header, { x = 8, y = 4, width = 240, height = 16 }, "the nickname header keeps its contract")
  Assert.equal(#layout.tabs, 3, "three page tabs exist")
  Assert.deepEqual(layout.tabs[2], { x = 88, y = 24, width = 80, height = 16 }, "the second tab keeps its contract")
  Assert.deepEqual(layout.body, { x = 8, y = 48, width = 240, height = 120 }, "the body keeps its contract")
  Assert.deepEqual(layout.returnRect, { x = 192, y = 172, width = 56, height = 16 }, "return keeps its contract")
  Assert.deepEqual(layout.leafRow, { x = 88, y = 176, width = 48, height = 15 }, "the leaf row keeps its contract")
  Assert.equal(#layout.moveRows, 4, "four move rows exist")
end

function T.hit_test_maps_tabs_rows_and_footer_controls()
  local layout = SummaryRenderer.layout(2)
  local hitTest = assert(layout.hitTest, "layouts carry a hit test")
  Assert.deepEqual(hitTest(90, 30), { kind = "tab", page = "stats" }, "tab taps name their page")
  Assert.deepEqual(hitTest(100, 55), { kind = "move", index = 0 }, "row taps name their row")
  Assert.deepEqual(hitTest(200, 180), { kind = "return" }, "return taps close")
  Assert.deepEqual(hitTest(10, 180), { kind = "member", direction = -1 }, "footer taps navigate members")
  Assert.isNil(hitTest(200, 100), "body taps select nothing")
  Assert.isNil(SummaryRenderer.layout(0).hitTest(100, 55), "empty move lists hit nothing")
end

return { tests = T }
