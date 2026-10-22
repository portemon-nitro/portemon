-- The selected-edition loading stage is one continuous themed scene that is
-- already distinct before generated sprite art arrives: warm gold for the
-- selected HeartGold, cool silver for SoulSilver, and a subdued neutral
-- stage with no selection. The scene paints every pixel of the drawable and
-- keeps animating; no outlined card or generic headline is ever composed.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Presentation = require("libs.hgss.src.ui.HgssLoadingPresentation")

local WIDTH, HEIGHT = 480, 360

local T = {}

local function renderStage(scope, presentation)
  local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  presentation:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  return scope:own(canvas:newImageData())
end

local function cornerAlpha(image)
  local minimum = 1
  for _, corner in ipairs({ { 0, 0 }, { WIDTH - 1, 0 }, { 0, HEIGHT - 1 }, { WIDTH - 1, HEIGHT - 1 } }) do
    local _, _, _, alpha = image:getPixel(corner[1], corner[2])
    minimum = math.min(minimum, alpha)
  end
  return minimum
end

function T.selected_edition_stages_differ_without_card_outlines(scope)
  local presentations = {}
  local function stage(versionId)
    local presentation = Presentation.new({ versionId = versionId, width = WIDTH, height = HEIGHT })
    presentations[#presentations + 1] = presentation
    return presentation
  end
  scope:own({
    release = function()
      for _, presentation in ipairs(presentations) do
        presentation:dispose()
      end
    end,
  })
  local gold = stage("heartgold")
  local silver = stage("soulsilver")
  local neutral = stage(nil)
  local outlined = 0
  local originalRectangle = love.graphics.rectangle
  local ok, err = xpcall(function()
    love.graphics.rectangle = function(mode, ...)
      if mode == "line" then
        outlined = outlined + 1
      end
      return originalRectangle(mode, ...)
    end
    local goldPixels = renderStage(scope, gold)
    local silverPixels = renderStage(scope, silver)
    local neutralPixels = renderStage(scope, neutral)
    Assert.isTrue(goldPixels:getString() ~= silverPixels:getString(), "gold and silver stages render distinct pixels")
    Assert.isTrue(goldPixels:getString() ~= neutralPixels:getString(), "the gold stage differs from neutral")
    Assert.isTrue(silverPixels:getString() ~= neutralPixels:getString(), "the silver stage differs from neutral")
    Assert.isTrue(cornerAlpha(goldPixels) > 0, "the gold stage covers the full drawable")
    Assert.isTrue(cornerAlpha(silverPixels) > 0, "the silver stage covers the full drawable")
    Assert.isTrue(cornerAlpha(neutralPixels) > 0, "the neutral stage covers the full drawable")
    gold:update(0.2)
    local laterGold = renderStage(scope, gold)
    Assert.isTrue(laterGold:getString() ~= goldPixels:getString(), "the pre-art stage keeps animating")
  end, debug.traceback)
  love.graphics.rectangle = originalRectangle
  if not ok then
    error(err, 0)
  end
  Assert.equal(outlined, 0, "the continuous stage draws no outlined card")
end

return GraphicsSmoke.suite(T, { tags = { "startup" } })
