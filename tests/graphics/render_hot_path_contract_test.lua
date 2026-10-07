-- Hot-path ownership for shared render primitives: resolving owners check
-- their records once, while paint helpers borrow already-resolved plans,
-- placements, buttons, and palettes and perform only the graphics operations
-- needed for the current pixels. Each test below drives a real production
-- painter through the injected fake graphics namespace, counts calls at the
-- explicit validator/resolver module seam, and pins both the removed
-- repeated work and the preserved successful-draw behavior. A test fails
-- while the paint path still validates, copies, resolves, or unwinds per
-- draw, and passes once that work lives only on the
-- resolve/layout/owner boundary.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

-- Counts calls through explicit module seams while the body runs, delegating
-- to the original functions so behavior is unchanged. Every seam is
-- restored even when the body fails, so a red run never leaks
-- instrumentation into sibling suites sharing the process.
---@param seams { [1]: table, [2]: string }[] module tables with the function key to observe
---@param body fun(counts: integer[])
local function withCallCounts(seams, body)
  local counts = {}
  local originals = {}
  for index, seam in ipairs(seams) do
    local moduleTable, key = seam[1], seam[2]
    local original = assert(moduleTable[key], "the observed seam must exist: " .. tostring(key))
    assert(type(original) == "function", "the observed seam must be a function: " .. tostring(key))
    counts[index] = 0
    originals[index] = original
    local slot = index
    moduleTable[key] = function(...)
      counts[slot] = counts[slot] + 1
      return original(...)
    end
  end
  local ok, err = pcall(body, counts)
  for index, seam in ipairs(seams) do
    seam[1][seam[2]] = originals[index]
  end
  if not ok then
    error(err, 0)
  end
end

local function stubMeasurement(width, height)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "hot-path:" .. width .. "x" .. height,
  }
end

-- One already-resolvable plan shape: a single interactive pane with a fully
-- specified placement, so resolution-time checking has something real to
-- accept before the draw path must leave it alone.
local function stubInterfaces(render)
  local full = function(_, _)
    return {
      panes = {
        {
          id = "content",
          placement = {
            frame = { x = 0, y = 0, width = 256, height = 192 },
            origin = { x = 0, y = 0 },
            scale = 1,
            logicalWidth = 256,
            logicalHeight = 192,
            clipRect = { x = 0, y = 0, width = 256, height = 192 },
          },
          interactive = true,
        },
      },
      frames = {},
      content = {},
      inputKey = "hot-path-stub",
      render = render,
      mapInput = function(event, _, _)
        return event
      end,
    }
  end
  return { dualDisplay = full, nativeLike = full, wide = full, tall = full }
end

-- One already-resolved application plan is drawn repeatedly: resolution
-- performs the plan/layout checks once, and subsequent draws invoke the
-- published render callback in order without calling the validation or
-- geometry-copy seams again.
function T.resolved_plan_draws_repeatedly_without_revalidating()
  local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local renders = 0
  local session = ApplicationPresentation.new(stubInterfaces(function()
    renders = renders + 1
  end))
  local view = {}
  withCallCounts({ { LayoutGeometry, "validatePlacement" }, { LayoutGeometry, "rect" } }, function(counts)
    session:resolve(stubMeasurement(256, 192), view)
    Assert.isTrue(counts[1] > 0, "resolution owns plan validation (observed through the layout seam)")
    local validated = counts[1]
    local copied = counts[2]
    local lg = FakeGraphics.new()
    for _ = 1, 3 do
      ApplicationPresentation.draw(lg, {}, {}, session:plan())
    end
    Assert.equal(renders, 3, "every draw invokes the published render callback exactly once")
    Assert.equal(lg:pushDepth(), 0, "draws leave the graphics stack balanced")
    Assert.equal(counts[1], validated, "draws add no placement validation beyond resolution")
    Assert.equal(counts[2], copied, "draws copy no geometry beyond resolution")
  end)
end

-- Nested logical surfaces with clipping and transforms paint through the
-- already-resolved placement: the visible clip is intersected in order,
-- borrowed state is restored on success, and neither the placement
-- validator nor the geometry-copy seam is called from the paint path.
function T.nested_surfaces_paint_without_contract_revalidation()
  local Surface = require("libs.ui.src.LogicalSurface")
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local placement = {
    frame = { x = -9, y = -8, width = 768, height = 576 },
    origin = { x = -9, y = -8 },
    scale = 3,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = { x = 0, y = 1, width = 750, height = 558 },
  }
  withCallCounts({ { LayoutGeometry, "validatePlacement" }, { LayoutGeometry, "rect" } }, function(counts)
    local lg = FakeGraphics.new({
      color = { 0.2, 0.4, 0.6, 0.8 },
      lineWidth = 3,
      scissor = { -100, -100, 2000, 2000 },
    })
    local paints = 0
    Surface.draw(lg, placement, function()
      paints = paints + 1
      lg.setColor(0.8, 0.1, 0.1, 1)
      lg.rectangle("fill", 3, 4, 248, 184)
      Surface.clip(lg, { x = 10, y = 10, width = 20, height = 20 }, function()
        paints = paints + 1
        lg.setColor(1, 0, 0, 1)
        lg.rectangle("fill", 0, 0, 256, 192)
      end)
    end)
    Assert.equal(paints, 2, "the root scope and the nested clip each paint exactly once")
    local transforms = lg.transforms
    Assert.equal(transforms[#transforms - 1][1], "translate", "the root scope translates to the placement origin")
    Assert.equal(transforms[#transforms][1], "scale", "the root scope scales uniformly after translating")
    Assert.equal(#lg.scissorIntersections, 2, "both scopes intersect the scissor, never replace it")
    Assert.deepEqual(
      lg.scissorIntersections[1].requested,
      { 0, 1, 750, 558 },
      "the root scope clips to the resolved placement clip"
    )
    Assert.equal(lg:pushDepth(), 0, "the pushed scopes are popped exactly once")
    local r, g, b, a = lg.getColor()
    Assert.deepEqual({ r, g, b, a }, { 0.2, 0.4, 0.6, 0.8 }, "borrowed color is restored after success")
    Assert.equal(lg.getLineWidth(), 3, "borrowed line width is restored after success")
    local sx, sy, sw, sh = lg.getScissor()
    Assert.deepEqual({ sx, sy, sw, sh }, { -100, -100, 2000, 2000 }, "the outer scissor is restored after success")
    Assert.equal(counts[1], 0, "paint performs no placement validation")
    Assert.equal(counts[2], 0, "paint copies no geometry")
  end)
end

-- A draw failure is terminal: the original error object propagates unwrapped
-- and no generic state snapshot is restored for continued rendering, while a
-- successful draw through the same helpers still restores exactly the state
-- it changed.
function T.draw_failures_propagate_without_generic_restore()
  local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
  local Surface = require("libs.ui.src.LogicalSurface")

  local lg = FakeGraphics.new({ color = { 0.2, 0.4, 0.6, 0.8 } })
  local paints = 0
  local session = ApplicationPresentation.new(stubInterfaces(function()
    paints = paints + 1
  end))
  local view = {}
  local plan = session:resolve(stubMeasurement(256, 192), view)
  ApplicationPresentation.draw(lg, {}, {}, plan)
  Assert.equal(paints, 1, "a successful draw invokes the published render callback")
  Assert.equal(lg:pushDepth(), 0, "a successful draw leaves the stack balanced")
  local r, g, b, a = lg.getColor()
  Assert.deepEqual({ r, g, b, a }, { 0.2, 0.4, 0.6, 0.8 }, "a successful draw restores borrowed color")

  local marker = {}
  local failing = session:resolve(stubMeasurement(256, 192), view)
  failing.render = function()
    lg.setColor(1, 0, 0, 1)
    error(marker, 0)
  end
  local ok, err = pcall(ApplicationPresentation.draw, lg, {}, {}, failing)
  Assert.isFalse(ok, "an application draw failure reaches the caller")
  Assert.isTrue(err == marker, "the original error object propagates unwrapped")
  Assert.equal(lg:pushDepth(), 1, "no generic unwind pops the failed application scope")
  local fr, fg, fb, fa = lg.getColor()
  Assert.deepEqual({ fr, fg, fb, fa }, { 1, 0, 0, 1 }, "no generic unwind restores state after the failure")

  local surfaceGraphics = FakeGraphics.new({ color = { 0.2, 0.4, 0.6, 0.8 } })
  local placement = {
    frame = { x = 0, y = 0, width = 256, height = 192 },
    origin = { x = 0, y = 0 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = { x = 0, y = 0, width = 256, height = 192 },
  }
  local surfaceMarker = {}
  local surfaceOk, surfaceErr = pcall(Surface.draw, surfaceGraphics, placement, function()
    surfaceGraphics.setColor(1, 0, 0, 1)
    error(surfaceMarker, 0)
  end)
  Assert.isFalse(surfaceOk, "a surface draw failure reaches the caller")
  Assert.isTrue(surfaceErr == surfaceMarker, "the surface error object propagates unwrapped")
  Assert.equal(surfaceGraphics:pushDepth(), 1, "no generic unwind pops the failed surface scope")

  local clipMarker = {}
  local nestedGraphics = FakeGraphics.new({ color = { 0.2, 0.4, 0.6, 0.8 } })
  local clipOk, clipErr = pcall(Surface.draw, nestedGraphics, placement, function()
    Surface.clip(nestedGraphics, { x = 10, y = 10, width = 20, height = 20 }, function()
      error(clipMarker, 0)
    end)
  end)
  Assert.isFalse(clipOk, "a nested clip failure reaches the caller")
  Assert.isTrue(clipErr == clipMarker, "the nested error object propagates unwrapped")
  Assert.equal(nestedGraphics:pushDepth(), 2, "no generic unwind pops failed nested scopes")
end

-- A menu paints the same buttons across frames: button geometry resolves
-- only when the layout changes rather than once per button per frame, while
-- the painted text/image/border output stays identical frame to frame.
function T.menu_buttons_reuse_resolved_geometry_across_frames()
  local ProductMenuSkin = require("app.src.ui.ProductMenuSkin")
  local ImageButton = require("libs.ui.src.ImageButton")
  local skin = ProductMenuSkin.forVersion("heartgold")
  local rect = { x = 10, y = 20, width = 120, height = 56 }
  withCallCounts({ { ImageButton, "resolve" } }, function(counts)
    local card = ProductMenuSkin.resolveCard(rect)
    local frames = {}
    for _ = 1, 4 do
      local lg = FakeGraphics.new()
      ProductMenuSkin.drawCard(lg, skin, card, "normal", false, false)
      frames[#frames + 1] = lg.rectangles
    end
    Assert.isTrue(#frames[1] > 0, "the menu button paints border geometry")
    for index = 2, 4 do
      Assert.deepEqual(frames[index], frames[1], "an unchanged button paints identical output on frame " .. index)
    end
    Assert.isTrue(
      counts[1] <= 1,
      "geometry resolves on layout change, not once per paint (resolved " .. counts[1] .. " times for 4 identical frames)"
    )
  end)
end

return GraphicsSmoke.suite(T)
