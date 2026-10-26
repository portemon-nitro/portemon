-- Battle narration matches the retail message window and its font palette.

local Assert = require("tests.support.Assert")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")

local T = {}

function T.narration_uses_the_retail_window_and_font_background()
  local drawnWindow, drawnColors = nil, nil
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = index, g = index * 2, b = index * 3 }
  end
  local graphics = {}
  function graphics.getColor()
    return 1, 1, 1, 1
  end
  function graphics.setColor() end
  function graphics.transformPoint(x, y)
    return x, y
  end
  function graphics.push() end
  function graphics.pop() end
  function graphics.intersectScissor() end
  BattleRenderer.drawPane({
    graphics = graphics,
    text = {
      drawTextForRole = function(role, _, _, _, colors)
        Assert.equal(role, "narration", "battle message uses the narration font")
        drawnColors = colors
      end,
    },
    windows = {
      drawWindow = function(box, _, background)
        drawnWindow = { box = box, background = background }
      end,
    },
    assets = {
      drawable = function()
        return nil
      end,
    },
    frameKey = "default",
  }, {
    battlers = {},
    effectInstances = {},
    hudPatchSpans = {},
    message = "message",
    textPalettes = { narration = { colors = palette } },
  }, "detail", {})

  Assert.deepEqual(drawnWindow.box, { x = 16, y = 152, width = 216, height = 32 }, "retail message window bounds")
  Assert.deepEqual(
    drawnWindow.background,
    { 15 / 255, 30 / 255, 45 / 255, 1 },
    "the window fills with message palette color 15"
  )
  Assert.deepEqual(drawnColors.foreground, { r = 1, g = 2, b = 3 }, "message prints in palette color 1")
  Assert.deepEqual(drawnColors.shadow, { r = 2, g = 4, b = 6 }, "message shadows in palette color 2")
  Assert.deepEqual(drawnColors.background, { r = 15, g = 30, b = 45 }, "glyph cells match the window fill")
end

function T.narration_window_uses_its_live_source_scroll()
  local drawnWindow = nil
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = index, g = index * 2, b = index * 3 }
  end
  local graphics = {}
  function graphics.getColor()
    return 1, 1, 1, 1
  end
  function graphics.setColor() end
  function graphics.transformPoint(x, y)
    return x, y
  end
  function graphics.push() end
  function graphics.pop() end
  function graphics.intersectScissor() end
  BattleRenderer.drawPane({
    graphics = graphics,
    text = { drawTextForRole = function() end },
    windows = {
      drawWindow = function(box)
        drawnWindow = box
      end,
    },
    assets = {
      drawable = function()
        return nil
      end,
    },
    frameKey = "default",
  }, {
    battlers = {},
    effectInstances = {},
    hudPatchSpans = {},
    message = "message",
    messageScrollY = -51,
    textPalettes = { narration = { colors = palette } },
  }, "detail", {})

  Assert.equal(drawnWindow.y, 101, "the retail message window begins 51 pixels below its resting position")
end

return { tests = T }
