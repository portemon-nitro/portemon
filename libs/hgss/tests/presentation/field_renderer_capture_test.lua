-- Transition snapshot fidelity: launch-owned plane copies keep the native
-- pipeline spec, so the battle transition composites the same crisp pixels
-- the live field renders instead of a blurred DPI-following copy.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function fakeCanvas(width, height)
  local canvas = { _width = width, _height = height, _filters = {}, _released = false }
  function canvas:getWidth()
    return self._width
  end
  function canvas:getHeight()
    return self._height
  end
  function canvas:setFilter(min, mag)
    self._filters[#self._filters + 1] = { min = min, mag = mag }
  end
  function canvas:release()
    self._released = true
  end
  return canvas
end

local function fakeGraphics(ledger)
  local graphics = {}
  function graphics.newCanvas(width, height, spec)
    ledger[#ledger + 1] = { width = width, height = height, spec = spec }
    return fakeCanvas(width, height)
  end
  function graphics.getCanvas()
    return nil
  end
  function graphics.getShader()
    return nil
  end
  function graphics.getBlendMode()
    return "alpha", "alphamultiply"
  end
  function graphics.getColor()
    return 1, 1, 1, 1
  end
  function graphics.getScissor()
    return nil
  end
  function graphics.setCanvas(_)
  end
  function graphics.setScissor()
  end
  function graphics.setShader()
  end
  function graphics.setBlendMode(_, _)
  end
  function graphics.setColor(_, _, _, _)
  end
  function graphics.draw(_, _, _)
  end
  return graphics
end

local function stubCamera()
  local projection = Matrix4.identity()
  return {
    zoom = 1,
    view = function()
      return Matrix4.identity()
    end,
    projection = function()
      return projection
    end,
    canonicalProjection = function()
      return Matrix4.identity()
    end,
    billboardProjection = function()
      return projection
    end,
    canonicalBillboardProjection = function()
      return Matrix4.identity()
    end,
  }
end

function T.captured_planes_keep_native_format_scale_and_filter()
  local ledger = {}
  local published = {}
  local gxRenderer = {
    draw = function(_)
      local world = fakeCanvas(256, 192)
      published[#published + 1] = world
      return { world = world }
    end,
  }
  local renderer = FieldRenderer.new({ gxRenderer = gxRenderer, graphics = fakeGraphics(ledger) })
  local camera = stubCamera()
  local capture = renderer:captureTransitionLayers({}, camera, {}, nil, { x = 0, y = 0, width = 256, height = 192 }, 1, 3)
  Assert.notNil(capture, "capture-only draws publish their native planes")
  Assert.notNil(capture.world, "the captured world plane survives the copy")
  -- One render target plus one launch-owned copy of the world plane.
  Assert.equal(#ledger, 2, "the capture allocates its render target and its plane copy")
  for index, created in ipairs(ledger) do
    Assert.equal(created.width, 256, "created canvas keeps native width")
    Assert.equal(created.height, 192, "created canvas keeps native height")
    local spec = created.spec or {}
    Assert.equal(spec.format, "rgba8", "created canvas keeps the native pipeline format")
    Assert.equal(spec.dpiscale, 1, "created canvas ignores window DPI like the native target")
  end
  local copyFilters = capture.world._filters
  Assert.isTrue(#copyFilters >= 1, "the launch-owned copy selects its sampling filter")
  Assert.equal(copyFilters[#copyFilters].min, "nearest", "the transition composite minifies with nearest")
  Assert.equal(copyFilters[#copyFilters].mag, "nearest", "the transition composite magnifies with nearest")
  capture:dispose()
end

return { tests = T }
