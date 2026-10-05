-- The blackout message keeps the retail window geometry and shared line anchor.

local Assert = require("tests.support.Assert")
local FieldBlackoutRenderer = require("game.hgss.src.field.FieldBlackoutRenderer")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

local T = {}

function T.message_uses_source_window_palette_and_shared_centered_line_anchor()
  local calls = {}
  local fontPalette = {
    { r = 8, g = 16, b = 24 },
    { r = 32, g = 48, b = 64 },
    { r = 80, g = 96, b = 112 },
  }
  local controller = {
    isModal = function()
      return true
    end,
    status = function()
      return {
        visibleLines = {
          { { kind = "glyph", code = 1, colorIndex = 1 }, { kind = "glyph", code = 1, colorIndex = 1 } },
          { { kind = "glyph", code = 1, colorIndex = 1 } },
        },
      }
    end,
  }
  local window = {
    drawWindow = function(_, box, framePalette, background)
      calls.window = { box = box, palette = framePalette, background = background }
    end,
  }
  local text = {
    fontDef = { glyphs = { [1] = { advance = 10 } }, letterSpacing = 0, palette = fontPalette },
    drawLineWithPalette = function(_, tokens, x, y, palette)
      calls[#calls + 1] = { tokens = tokens, x = x, y = y, palette = palette }
    end,
  }
  local graphics = {
    push = function() end,
    translate = function() end,
    scale = function() end,
    pop = function() end,
  }
  local priorLove = love
  local priorProtectedDraw = FieldDrawState.protectedDraw
  love = { graphics = graphics }
  FieldDrawState.protectedDraw = function(_, draw)
    draw()
  end
  local ok, err =
    pcall(FieldBlackoutRenderer.draw, controller, window, text, { x = 0, y = 0, width = 256, height = 192 })
  FieldDrawState.protectedDraw = priorProtectedDraw
  love = priorLove
  if not ok then
    error(err)
  end

  Assert.equal(calls.window.box.x, 32)
  Assert.equal(calls.window.box.y, 40)
  Assert.equal(calls.window.box.width, 200)
  Assert.equal(calls.window.box.height, 120)
  Assert.equal(calls.window.palette, 13)
  Assert.deepEqual(calls.window.background, { 8 / 255, 16 / 255, 24 / 255, 1 })
  Assert.equal(#calls, 2)
  Assert.equal(calls[1].x, 118)
  Assert.equal(calls[2].x, 118)
  Assert.equal(calls[1].y, 40)
  Assert.equal(calls[2].y, 56)
  Assert.equal(calls[1].palette.foreground, fontPalette[2])
  Assert.equal(calls[1].palette.shadow, fontPalette[3])
  Assert.equal(calls[1].palette.background, fontPalette[1])
  Assert.equal(calls[1].tokens[1].colorIndex, 1)
end

return { tests = T }
