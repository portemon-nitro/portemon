-- Real-context presentation fixtures verify the framed field-menu list at
-- 4:3, wide, and portrait geometry. Pixel checks keep these smokes stable
-- without coupling them to host font rasterization.

local Assert = require("tests.support.Assert")
local FieldMenuRenderer = require("libs.hgss.src.ui.FieldMenuRenderer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MenuLayout = require("libs.hgss.src.ui.MenuLayout")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local FILL = { 0.9, 0.8, 0.7, 1 }

local function fixture(width, height, count)
  local items = {}
  for index = 1, count do
    items[index] = { text = "Choice " .. index, value = index }
  end
  local layout = MenuLayout.resolve({
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = false,
    }),
    menu = { items = items, cancellable = false },
    measureText = function(text)
      return #text * 8
    end,
  })
  return layout
end

local function fakeText()
  local palette = {}
  for index = 1, 16 do
    palette[index] = { r = 0, g = 0, b = 0 }
  end
  return {
    fontDef = { palette = palette },
    windowBackgroundColor = function()
      return FILL
    end,
    drawTextWithPalette = function() end,
  }
end

function T.presentation_fixtures_draw_a_framed_top_right_list_in_4_3_wide_and_portrait(scope)
  local renderer = FieldMenuRenderer.new({
    text = fakeText(),
    window = { drawApplicationFrame = function() end },
  })
  for _, case in ipairs({
    { width = 256, height = 192 },
    { width = 1280, height = 720 },
    { width = 390, height = 844 },
  }) do
    local layout = fixture(case.width, case.height, 3)
    local canvas = scope:own(love.graphics.newCanvas(case.width, case.height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw({ status = { selectedIndex = 0 }, layout = layout }, 0)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())

    local placement = layout.placement
    local box = layout.listSurface.surface
    local x = math.floor(placement.origin.x + (box.x + box.width - 4) * placement.scale)
    local y = math.floor(placement.origin.y + (box.y + box.height - 4) * placement.scale)
    local r, g, b, a = image:getPixel(x, y)
    Assert.near(r, FILL[1], 0.02)
    Assert.near(g, FILL[2], 0.02)
    Assert.near(b, FILL[3], 0.02)
    Assert.near(a, 1, 0.01)

    local regionRight = placement.origin.x + 256 * placement.scale
    Assert.isTrue(
      regionRight - (placement.origin.x + (box.x + box.width) * placement.scale) <= 16 * placement.scale,
      "the list is anchored to the right of the 4:3 region"
    )
  end
end

return GraphicsSmoke.suite(T)
