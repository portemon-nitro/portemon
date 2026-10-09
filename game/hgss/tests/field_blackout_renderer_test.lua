-- The blackout message keeps the retail window geometry and shared line anchor.

local Assert = require("tests.support.Assert")
local FieldBlackoutRenderer = require("game.hgss.src.field.FieldBlackoutRenderer")

local T = {}

function T.message_uses_source_window_palette_and_shared_centered_line_anchor()
  local calls = { scales = {}, pushes = 0, pops = 0 }
  local fontPalette = {
    { r = 8, g = 16, b = 24 },
    { r = 32, g = 48, b = 64 },
    { r = 80, g = 96, b = 112 },
  }
  local status = {
    phase = "message_in",
    message = {
      tokens = {
        { kind = "glyph", code = 1, colorIndex = 1 },
        { kind = "glyph", code = 1, colorIndex = 1 },
        { kind = "line_break" },
        { kind = "glyph", code = 1, colorIndex = 1 },
        { kind = "eos" },
      },
    },
  }
  local window = {
    drawWindow = function(_, box, framePalette, background)
      calls.window = { box = box, palette = framePalette, background = background }
      calls.order = calls.order or {}
      calls.order[#calls.order + 1] = "window"
    end,
  }
  local text = {
    fontDef = { glyphs = { [1] = { advance = 10 } }, letterSpacing = 0, palette = fontPalette },
    drawLineWithPalette = function(_, tokens, x, y, palette)
      calls[#calls + 1] = { tokens = tokens, x = x, y = y, palette = palette }
    end,
  }
  local graphics = {
    push = function() calls.pushes = calls.pushes + 1 end,
    translate = function() end,
    scale = function(x, y) calls.scales[#calls.scales + 1] = { x, y } end,
    pop = function() calls.pops = calls.pops + 1 end,
    setScissor = function(x, y, width, height)
      calls.clip = { x = x, y = y, width = width, height = height }
    end,
    getScissor = function() return nil end,
    intersectScissor = function(x, y, width, height)
      calls.clip = { x = x, y = y, width = width, height = height }
    end,
    setColor = function(red, green, blue, alpha)
      calls.backingColor = { red, green, blue, alpha }
    end,
    rectangle = function(mode, x, y, width, height)
      calls.backing = { mode = mode, x = x, y = y, width = width, height = height }
      calls.order = calls.order or {}
      calls.order[#calls.order + 1] = "backing"
    end,
  }
  local priorLove = love
  love = { graphics = graphics }
  local ok, err = pcall(FieldBlackoutRenderer.draw, status, window, text, { x = 0, y = 0, width = 256, height = 192 })
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
  Assert.notNil(calls.backing, "opaque white backing draw is missing")
  Assert.deepEqual(calls.backingColor, { 1, 1, 1, 1 })
  Assert.deepEqual(calls.backing, { mode = "fill", x = 0, y = 0, width = 256, height = 192 })
  Assert.deepEqual(calls.order, { "backing", "window" })
  Assert.equal(#calls, 2)
  Assert.equal(calls[1].x, 118)
  Assert.equal(calls[2].x, 118)
  Assert.equal(calls[1].y, 40)
  Assert.equal(calls[2].y, 56)
  Assert.equal(calls[1].palette.foreground, fontPalette[2])
  Assert.equal(calls[1].palette.shadow, fontPalette[3])
  Assert.equal(calls[1].palette.background, fontPalette[1])
  Assert.equal(calls[1].tokens[1].colorIndex, 1)
  Assert.equal(#calls[1].tokens, 2, "all first-line glyphs draw immediately")
  Assert.equal(#calls[2].tokens, 1, "all second-line glyphs draw immediately")
  Assert.deepEqual(calls.scales[1], { 1, 1 }, "native-size bounds use native pixel magnification")

  local priorTinyLove = love
  love = { graphics = graphics }
  local okTiny, tinyErr = pcall(FieldBlackoutRenderer.draw, status, window, text, { x = 0, y = 0, width = 200, height = 150 })
  love = priorTinyLove
  Assert.isTrue(okTiny, tostring(tinyErr))
  local tinyScale = assert(calls.scales[2], "the constrained draw records its magnification")
  Assert.isTrue(tinyScale[1] >= 1 and tinyScale[1] == math.floor(tinyScale[1]), "undersized bounds never minify pixels")
  Assert.equal(tinyScale[1], tinyScale[2], "pixel art keeps uniform scale")
  Assert.deepEqual(calls.clip, { x = 0, y = 0, width = 200, height = 150 }, "undersized draw clips to its host bounds")
  Assert.deepEqual(calls.window.box, { x = 32, y = 40, width = 200, height = 120 }, "retail window stays source-sized")
  Assert.equal(calls.window.palette, 13, "retail frame palette is unchanged")
  Assert.equal(calls[3].x, 118, "blackout text remains positioned in source pixels")
  Assert.equal(calls.pushes, calls.pops, "both draws restore their graphics scopes")
end

return { tests = T }
