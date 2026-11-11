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
  function graphics.draw() end
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
      renderPictures = function(_, drawGraphics, frame)
        local CompositionFrameDrain = require("tests.support.CompositionFrameDrain")
        CompositionFrameDrain.drain(drawGraphics, frame)
        return { handle = "picture-composite" }
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
  function graphics.draw() end
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
      renderPictures = function(_, drawGraphics, frame)
        local CompositionFrameDrain = require("tests.support.CompositionFrameDrain")
        CompositionFrameDrain.drain(drawGraphics, frame)
        return { handle = "picture-composite" }
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

-- Strip quads segregate by graphics namespace and strip dimensions: the same
-- tile index through another namespace allocates a distinct quad, a modded
-- wider strip allocates wider geometry, and returning to the original width
-- reuses the original quad object without reallocation.
function T.strip_quads_segregate_by_graphics_namespace_and_strip_dimensions()
  local FakeGraphics = require("tests.support.FakeGraphics")
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = index, g = index, b = index }
  end
  local stripWidth = 128
  local art = {
    getWidth = function()
      return stripWidth
    end,
    getHeight = function()
      return 8
    end,
  }
  local assets = {
    drawable = function()
      return art
    end,
  }
  local objects = { { tile = 0, width = 256, height = 64, x = 0, y = 0 } }
  local view = {
    hudPatchSpans = {
      nickname = { { sideType = 0, spans = {
        { tile = 0, count = 8 },
        { tile = 8, count = 8 },
        { tile = 16, count = 8 },
        { tile = 24, count = 8 },
      } } },
      level = { { sideType = 0, spans = { { tile = 100, count = 3 }, { tile = 110, count = 3 } } } },
    },
    textPalettes = { hud = { colors = palette } },
  }
  local section = { digitBase = 200 }
  local battler = { name = "ABC", level = 5 }
  local text = { drawTextForRole = function() end }
  local transform = { x = 0, y = 0, scale = 1 }
  local function instrumented()
    local graphics = FakeGraphics.new()
    local calls = 0
    local originalNewQuad = graphics.newQuad
    graphics.newQuad = function(x, y, w, h, imgW, imgH)
      calls = calls + 1
      return originalNewQuad(x, y, w, h, imgW, imgH)
    end
    return graphics, function()
      return calls
    end
  end
  local graphicsA, callsA = instrumented()
  local graphicsB, callsB = instrumented()
  local function drawWith(graphics)
    BattleRenderer.drawCompactHudPrinters(
      graphics,
      text,
      assets,
      view,
      "hud",
      section,
      objects,
      battler,
      0,
      false,
      transform
    )
  end
  drawWith(graphicsA)
  Assert.isTrue(callsA() > 0, "the first draw allocates quads for its geometry")
  local quadsA = {}
  for _, record in ipairs(graphicsA.draws) do
    if record.quad ~= nil then
      quadsA[#quadsA + 1] = record.quad
    end
  end
  drawWith(graphicsB)
  Assert.equal(callsB(), callsA(), "another namespace allocates its own quads")
  local quadsB = {}
  for _, record in ipairs(graphicsB.draws) do
    if record.quad ~= nil then
      quadsB[#quadsB + 1] = record.quad
    end
  end
  Assert.equal(#quadsB, #quadsA, "both namespaces draw the same quad sequence")
  for index, quad in ipairs(quadsA) do
    Assert.isTrue(quad ~= quadsB[index], "quads never leak across graphics namespaces")
    Assert.deepEqual(
      { quadsB[index].x, quadsB[index].y, quadsB[index].w, quadsB[index].h },
      { quad.x, quad.y, quad.w, quad.h },
      "the other namespace draws the same quad geometry"
    )
  end
  stripWidth = 256
  local beforeWide = callsA()
  drawWith(graphicsA)
  Assert.isTrue(callsA() > beforeWide, "a modded wider strip allocates new quads")
  local wideQuad = nil
  for _, record in ipairs(graphicsA.draws) do
    if record.quad ~= nil and record.quad.imgW == 256 then
      wideQuad = record.quad
    end
  end
  Assert.notNil(wideQuad, "the wider strip draws with wider quad geometry")
  Assert.equal(wideQuad.imgW, 256, "the modded strip width reaches the quad")
  stripWidth = 128
  local beforeReuse = callsA()
  local drawsBefore = #graphicsA.draws
  drawWith(graphicsA)
  Assert.equal(callsA(), beforeReuse, "returning to the original width allocates no new quads")
  local position = 0
  for index = drawsBefore + 1, #graphicsA.draws do
    local record = graphicsA.draws[index]
    if record.quad ~= nil then
      position = position + 1
      Assert.isTrue(
        record.quad == quadsA[position],
        "the original width reuses its original quad object"
      )
    end
  end
  Assert.equal(position, #quadsA, "the redraw draws the full original quad sequence")
end

return { tests = T }
