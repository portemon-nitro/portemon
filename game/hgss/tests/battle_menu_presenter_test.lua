-- Verifies the native lower menu composition owner uses source BG planes.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local BattleMenuPresenter = require("game.hgss.src.battle.BattleMenuPresenter")

local T = {}
local SCROLL_X = { 1, 64, 128, 192, 255 }
local OUTSIDE_WIDTH = { 0, 63, 127, 191, 254 }
local SCROLL_Y = { 40, -30, -20, -10, 0 }
local PARTNER_TOP_X = { 256, 192, 128, 64, 1 }
local PARTNER_OUTSIDE_WIDTH = { 0, 64, 128, 192, 255 }
local PARTNER_SCROLL_X = { 0, 64, 128, 192, 255 }

local function windowsForSoloPlayer(edge, step)
  local scroll = SCROLL_X[step + 1]
  local outsideWidth = OUTSIDE_WIDTH[step + 1]
  return {
    edge = edge,
    outsideTop = { x = 1, y = 0, width = outsideWidth, height = 144 },
    outsideBottom = { x = 0, y = edge, width = 256, height = 192 - edge },
    scroll = {
      [0] = { x = scroll, topY = 0, bottomY = SCROLL_Y[step + 1] },
      [1] = { x = scroll, topY = 0, bottomY = SCROLL_Y[step + 1] },
    },
  }
end

local function windowsForSecondPlayer(edge, step)
  return {
    edge = edge,
    outsideTop = { x = PARTNER_TOP_X[step + 1], y = 0, width = PARTNER_OUTSIDE_WIDTH[step + 1], height = 144 },
    outsideBottom = { x = 0, y = edge, width = 256, height = 192 - edge },
    scroll = {
      [0] = { x = PARTNER_SCROLL_X[step + 1], topY = 0, bottomY = SCROLL_Y[step + 1] },
      [1] = { x = PARTNER_SCROLL_X[step + 1], topY = 0, bottomY = SCROLL_Y[step + 1] },
    },
  }
end

function T.command_plane_one_blends_over_the_other_native_planes()
  local graphics = FakeGraphics.new({})
  local assets = {
    drawable = function(_, key)
      return { key = key }
    end,
  }
  local layers = {
    { plane = 1, priority = 2 },
    { plane = 2, priority = 3 },
    { plane = 0, priority = 3 },
  }

  BattleMenuPresenter.draw(graphics, assets, "command", layers, {})

  Assert.equal(#graphics.canvases, 2, "the native alpha blend owns one target per source plane group")
  Assert.equal(graphics.draws[1].image.key, "menu:command:screen:2", "BG2 is drawn behind the equal-priority BG0")
  Assert.equal(graphics.draws[2].image.key, "menu:command:screen:3", "BG0 is drawn above BG2 at equal priority")
  Assert.equal(#graphics.shaders, 1, "BG1 uses the native alpha blend shader")
  Assert.equal(graphics.shaders[1].sends[1].name, "underlay", "BG1 blends against the composed lower planes")
  Assert.equal(graphics.shaders[1].sends[1].value, graphics.canvases[1], "the underlay is the non-BG1 target")
  Assert.equal(graphics.draws[#graphics.draws].image, graphics.canvases[2], "the blended plane is the final menu image")
  Assert.isTrue(graphics.canvases[1].released, "the lower-plane render target is released after composition")
  Assert.isTrue(graphics.canvases[2].released, "the BG1 render target is released after composition")
  Assert.isTrue(graphics.shaders[1].released, "the temporary blend shader is released after composition")
  Assert.equal(graphics.pushDepth(), 0, "the compositor restores borrowed graphics state")
end

function T.offscreen_planes_ignore_pane_transform_and_restore_it_for_composition()
  local graphics = FakeGraphics.new({})
  local originalDraw = graphics.draw
  local sourceDraws = {}
  graphics.draw = function(image, ...)
    if type(image) == "table" and type(image.key) == "string" then
      local x, y = graphics.transformPoint(0, 0)
      local scissor = { graphics.getScissor() }
      sourceDraws[#sourceDraws + 1] = { x = x, y = y, scissor = scissor }
    end
    return originalDraw(image, ...)
  end
  graphics.translate(32, 48)
  graphics.setScissor(32, 48, 256, 192)
  local assets = {
    drawable = function(_, key)
      return { key = key }
    end,
  }
  local layers = {
    { plane = 1, priority = 2 },
    { plane = 2, priority = 3 },
    { plane = 0, priority = 3 },
  }

  BattleMenuPresenter.draw(graphics, assets, "command", layers, {})

  Assert.equal(#sourceDraws, 3, "the source lower planes draw into their own native targets")
  for _, draw in ipairs(sourceDraws) do
    Assert.equal(draw.x, 0, "offscreen source planes use the native horizontal origin")
    Assert.equal(draw.y, 0, "offscreen source planes use the native vertical origin")
    Assert.equal(#draw.scissor, 0, "offscreen source planes clear the parent pane scissor")
  end
  local output = graphics.draws[#graphics.draws]
  Assert.equal(graphics.transformPoint(output.x, output.y), 32, "the blended plane keeps the interaction pane x offset")
  local outputY = select(2, graphics.transformPoint(output.x, output.y))
  Assert.equal(outputY, 48, "the blended plane keeps the interaction pane y offset")
  Assert.deepEqual({ graphics.getScissor() }, { 32, 48, 256, 192 }, "the presenter restores the parent pane scissor")
  Assert.equal(graphics.pushDepth(), 0, "offscreen composition restores the host graphics stack")
end

function T.slide_windows_mask_bg0_and_bg1_below_the_native_w1_edge()
  local graphics = FakeGraphics.new({})
  local assets = {
    drawable = function(_, key)
      return { key = key }
    end,
  }
  local layers = {
    { plane = 1, priority = 2 },
    { plane = 2, priority = 3 },
    { plane = 0, priority = 3 },
  }

  BattleMenuPresenter.draw(graphics, assets, "command", layers, {}, windowsForSoloPlayer(174, 1))

  Assert.equal(#graphics.scissorIntersections, 4, "BG0/BG1 each use both source outside-window regions")
  Assert.deepEqual(graphics.scissorIntersections[1].requested, { 1, 0, 63, 144 }, "upper region clips outside W0")
  Assert.deepEqual(graphics.scissorIntersections[2].requested, { 0, 174, 256, 18 }, "lower region clips outside W1")
end

function T.source_slide_edges_keep_each_menu_plane_inside_and_outside_pixels()
  local edges = { 184, 174, 164, 154, 145 }
  local planeByLayer = { 1, 2, 0 }
  local outsideWidths = OUTSIDE_WIDTH
  local scrollX = SCROLL_X
  for step, edge in ipairs(edges) do
    local graphics = FakeGraphics.new({})
    local originalDraw = graphics.draw
    local sourceDraws = {}
    graphics.draw = function(image, ...)
      if type(image) == "table" and type(image.key) == "string" then
        local layerIndex = tonumber(image.key:match("screen:(%d+)$"))
        if layerIndex ~= nil then
          local x, y, width, height = graphics.getScissor()
          local plane = planeByLayer[layerIndex]
          sourceDraws[plane] = sourceDraws[plane] or {}
          local originX, originY = graphics.transformPoint(0, 0)
          sourceDraws[plane][#sourceDraws[plane] + 1] = {
            clip = x ~= nil and { x, y, width, height } or false,
            origin = { originX, originY },
          }
        end
      end
      originalDraw(image, ...)
    end
    local assets = {
      drawable = function(_, key)
        return { key = key }
      end,
    }
    local layers = {
      { plane = 1, priority = 2 },
      { plane = 2, priority = 3 },
      { plane = 0, priority = 3 },
    }

    BattleMenuPresenter.draw(graphics, assets, "command", layers, {}, windowsForSoloPlayer(edge, step - 1))

    local function sampleVisible(plane, x, y)
      local regions = sourceDraws[plane]
      if regions == nil then
        return false
      end
      for _, draw in ipairs(regions) do
        local clip = draw.clip
        if clip == false or (x >= clip[1] and x < clip[1] + clip[3] and y >= clip[2] and y < clip[2] + clip[4]) then
          return true
        end
      end
      return false
    end
    for _, plane in ipairs({ 0, 1 }) do
      Assert.isFalse(sampleVisible(plane, 0, 143), "BG" .. plane .. " is masked inside native W0")
      Assert.isFalse(sampleVisible(plane, 0, edge - 1), "BG" .. plane .. " is masked inside native W1")
      Assert.isTrue(sampleVisible(plane, 0, edge), "BG" .. plane .. " returns at the native W1 boundary")
      Assert.isTrue(sampleVisible(plane, 0, 191), "BG" .. plane .. " is visible outside both windows")
      local hasTop = outsideWidths[step] > 0
      Assert.equal(#sourceDraws[plane], hasTop and 2 or 1, "BG" .. plane .. " composes visible outside-window regions")
      local bottomIndex = hasTop and 2 or 1
      Assert.equal(
        sourceDraws[plane][bottomIndex].origin[1],
        -scrollX[step],
        "BG" .. plane .. " applies native horizontal offset"
      )
      if hasTop then
        Assert.equal(sourceDraws[plane][1].origin[2], 0, "BG" .. plane .. " upper scanlines keep zero Y scroll")
      end
      Assert.equal(
        sourceDraws[plane][bottomIndex].origin[2],
        -SCROLL_Y[step],
        "BG" .. plane .. " lower scanlines use HBlank Y offset"
      )
    end
    Assert.isTrue(sampleVisible(2, 0, 143), "BG2 is visible inside native W0")
    Assert.isTrue(sampleVisible(2, 0, edge - 1), "BG2 is visible inside native W1")
    Assert.isTrue(sampleVisible(2, 0, 191), "BG2 is visible outside the windows")
  end
end

function T.second_player_slot_uses_the_opposite_native_w0_and_bg_scroll()
  local edges = { 184, 174, 164, 154, 145 }
  for step, edge in ipairs(edges) do
    local graphics = FakeGraphics.new({})
    local assets = {
      drawable = function(_, key)
        return { key = key }
      end,
    }
    local layers = {
      { plane = 1, priority = 2 },
      { plane = 2, priority = 3 },
      { plane = 0, priority = 3 },
    }

    BattleMenuPresenter.draw(graphics, assets, "command", layers, {}, windowsForSecondPlayer(edge, step - 1))

    if PARTNER_OUTSIDE_WIDTH[step] > 0 then
      Assert.deepEqual(graphics.scissorIntersections[1].requested, {
        PARTNER_TOP_X[step],
        0,
        PARTNER_OUTSIDE_WIDTH[step],
        144,
      }, "the partner-side W0 outside region follows its source edge")
      Assert.equal(graphics.scissorIntersections[2].requested[2], edge, "W1 keeps the source lower boundary")
    else
      Assert.equal(graphics.scissorIntersections[1].requested[2], edge, "entry starts with only the W1 outside region")
    end
  end
end

return { tests = T }
