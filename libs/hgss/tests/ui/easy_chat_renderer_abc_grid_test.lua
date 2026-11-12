-- ABC initial grid geometry: all 27 initials draw exactly once at
-- distinct anchors spread across rows from their authored grid cells.
-- Synthetic menu and recording text owner; no ROM data, no love, no GPU.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local EasyChatRenderer = require("libs.hgss.src.ui.EasyChatRenderer")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

local function textOwner(positions)
  return {
    fontDef = { glyphs = {}, letterSpacing = 0, palette = { { r = 1, g = 1, b = 1 }, { r = 1, g = 1, b = 1 }, { r = 0, g = 0, b = 0 }, { r = 0, g = 0, b = 0 } } },
    _graphics = {
      newQuad = function()
        return {}
      end,
    },
    drawLineWithPalette = function(_, tokens, x, y, _)
      if type(tokens) == "table" and #tokens > 0 then
        positions[#positions + 1] = { x = x, y = y }
      end
    end,
  }
end

local function placement()
  local rect = { x = 0, y = 0, width = 256, height = 192 }
  return { frame = rect, origin = { x = 0, y = 0 }, clipRect = rect, scale = 1 }
end

function T.tests.abc_initials_draw_once_each_on_distinct_grid_rows()
  local positions = {}
  local text0 = textOwner(positions)
  local renderer = EasyChatRenderer.new({
    manifest = { layers = {}, sequences = {} },
    images = {},
    text0 = text0,
  })
  local initials, grid = {}, {}
  for index = 1, 27 do
    initials[index] = { labelTokens = { { kind = "glyph", code = 1 } } }
    grid[index] = { x = ((index - 1) % 9) * 8, y = math.floor((index - 1) / 9) * 24 }
  end
  local graphics = FakeGraphics.new()
  local status = {
    view = { level = "abc", mode = 0, time = 0, browser = { group = 0, tab = "abc" } },
    catalog = {},
    assets = { menu = { groups = {}, initials = initials, grid = grid }, interface = { tabs = {} } },
    brightness = 0,
  }
  local plan = {
    panes = {
      { id = "information", placement = placement() },
      { id = "controls", placement = placement() },
    },
  }
  renderer:drawPair(graphics, status, plan)
  Assert.equal(#positions, 27, "all 27 initials draw exactly once")
  local rows, cells = {}, {}
  for _, pos in ipairs(positions) do
    rows[pos.y] = true
    cells[pos.x .. "," .. pos.y] = true
  end
  local rowCount, pairCount = 0, 0
  for _ in pairs(rows) do
    rowCount = rowCount + 1
  end
  for _ in pairs(cells) do
    pairCount = pairCount + 1
  end
  Assert.isTrue(rowCount >= 3, "the authored grid spreads initials across rows (" .. rowCount .. ")")
  Assert.equal(pairCount, 27, "every initial owns a distinct grid anchor")
  -- The first cell anchors its label at the authored origin (20,64):
  -- cell (0,0) centers a zero-width label at x=28, y=64.
  Assert.equal(positions[1].x, 28, "the first initial anchors at its grid cell")
  Assert.equal(positions[1].y, 64, "the first initial anchors at its grid row")
  renderer:dispose()
end

return T
