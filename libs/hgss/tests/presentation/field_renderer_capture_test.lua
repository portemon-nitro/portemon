-- Transition snapshot fidelity: launch-owned plane copies keep the native
-- pipeline spec, so the battle transition composites the same crisp pixels
-- the live field renders instead of a blurred DPI-following copy.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local Matrix4 = require("libs.math.src.Matrix4")
local Overlay116Effect = require("libs.hgss.src.transition.battle.Overlay116Effect")

local T = {}

local function fakeCanvas(width, height)
  local canvas = { _width = width, _height = height, _filters = {}, _released = false, _releaseCount = 0 }
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
    self._releaseCount = self._releaseCount + 1
  end
  return canvas
end

local function fakeGraphics(ledger, opts)
  opts = opts or {}
  local graphics = {}
  local canvasCalls = 0
  graphics.created = {}
  graphics.draws = {}
  graphics.drawTargets = {}
  graphics.drawColors = {}
  graphics._boundCanvas = nil
  graphics._drawColor = { 1, 1, 1, 1 }
  graphics.rectangles = {}
  graphics.quads = {}
  graphics.stencilCalls = {}
  graphics.stencilTest = nil
  graphics._pushDepth = 0
  function graphics.newCanvas(width, height, spec)
    canvasCalls = canvasCalls + 1
    if opts.failOnCanvasCall == canvasCalls then
      error("injected canvas failure")
    end
    ledger[#ledger + 1] = { width = width, height = height, spec = spec }
    local canvas = fakeCanvas(width, height)
    graphics.created[#graphics.created + 1] = canvas
    return canvas
  end
  function graphics.getCanvas()
    return graphics._boundCanvas
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
  function graphics.setCanvas(canvas)
    graphics._boundCanvas = canvas
  end
  function graphics.setScissor() end
  function graphics.setShader() end
  function graphics.setBlendMode(_, _) end
  function graphics.setColor(red, green, blue, alpha)
    graphics._drawColor = { red, green, blue, alpha }
  end
  function graphics.clear(_, _, _, _) end
  function graphics.push(_)
    graphics._pushDepth = graphics._pushDepth + 1
  end
  function graphics.pop()
    graphics._pushDepth = graphics._pushDepth - 1
  end
  function graphics.stencil(fn, mode, value)
    graphics.stencilCalls[#graphics.stencilCalls + 1] = { mode = mode, value = value }
    fn()
  end
  function graphics.setStencilTest(mode, value)
    if mode == nil then
      graphics.stencilTest = nil
    else
      graphics.stencilTest = { mode = mode, value = value }
    end
  end
  function graphics.rectangle(mode, x, y, w, h)
    graphics.rectangles[#graphics.rectangles + 1] = { mode = mode, x = x, y = y, w = w, h = h }
  end
  function graphics.newQuad(x, y, w, h, imgW, imgH)
    local quad = { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    graphics.quads[#graphics.quads + 1] = quad
    return quad
  end
  function graphics.draw(image, quad, x, y, rotation, sx, sy)
    if type(quad) == "number" then
      quad, x, y, rotation, sx, sy = nil, quad, x, y, rotation, sx or rotation
    end
    graphics.draws[#graphics.draws + 1] = {
      image = image,
      quad = quad,
      x = x,
      y = y,
      rotation = rotation,
      sx = sx,
      sy = sy,
    }
    graphics.drawTargets[#graphics.drawTargets + 1] = graphics._boundCanvas
    local color = graphics._drawColor
    graphics.drawColors[#graphics.drawColors + 1] = { color[1], color[2], color[3], color[4] }
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
  local capture = renderer:captureTransitionLayers(
    {},
    camera,
    {},
    nil,
    { x = 0, y = 0, width = 256, height = 192 },
    1,
    3
  )
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

-- A larger live viewport keeps every captured plane at the viewport's own
-- pixel size: the transition background must not upscale a native-sized
-- snapshot, and object pixels must keep their own independent plane.
function T.captured_planes_match_the_live_world_viewport()
  local ledger = {}
  local renders = 0
  local seenViewport = nil
  local gxRenderer = {
    draw = function(_, frame)
      renders = renders + 1
      seenViewport = frame.viewport
      return { world = fakeCanvas(256, 192), objects = fakeCanvas(256, 192) }
    end,
  }
  local renderer = FieldRenderer.new({ gxRenderer = gxRenderer, graphics = fakeGraphics(ledger) })
  local camera = stubCamera()
  local capture = renderer:captureTransitionLayers(
    {},
    camera,
    {},
    {},
    { x = 0, y = 0, width = 768, height = 576 },
    1,
    3
  )
  Assert.notNil(capture, "a large-viewport capture publishes its planes")
  Assert.equal(capture.world:getWidth(), 768, "the world plane matches the live viewport width")
  Assert.equal(capture.world:getHeight(), 576, "the world plane matches the live viewport height")
  Assert.notNil(capture.objects, "the object plane survives alongside the world plane")
  Assert.equal(capture.objects:getWidth(), 768, "the object plane matches the live viewport width")
  Assert.equal(capture.objects:getHeight(), 576, "the object plane matches the live viewport height")
  Assert.isTrue(capture.world ~= capture.objects, "world and object planes stay independent")
  Assert.equal(renders, 1, "one accepted capture runs a single world render")
  Assert.equal(
    seenViewport.worldViewport.width,
    768,
    "the single render covers the live viewport instead of the native lattice"
  )
  capture:dispose()
  local offsetCapture = renderer:captureTransitionLayers(
    {},
    camera,
    {},
    {},
    { x = 24, y = 12, width = 511.2, height = 383.4 },
    1,
    3
  )
  Assert.equal(offsetCapture.world:getWidth(), 512, "fractional viewport widths round up to whole pixels")
  Assert.equal(offsetCapture.world:getHeight(), 384, "fractional viewport heights round up to whole pixels")
  Assert.isTrue(
    offsetCapture.objects ~= nil and offsetCapture.objects:getWidth() == 512,
    "a nonzero viewport origin keeps source-local plane pixels"
  )
  offsetCapture:dispose()
end

-- A failed plane copy never publishes a partial capture: the acquired
-- planes release, the temporary presentation target releases, and the
-- retained frame state restores before the failure rethrows.
function T.failed_capture_releases_partial_planes_and_restores_frame_state()
  local ledger = {}
  local graphics = fakeGraphics(ledger, { failOnCanvasCall = 3 })
  local seenViewport = nil
  local gxRenderer = {
    draw = function(_, frame)
      seenViewport = frame.viewport
      return { world = fakeCanvas(768, 576), objects = fakeCanvas(768, 576) }
    end,
  }
  local renderer = FieldRenderer.new({ gxRenderer = gxRenderer, graphics = graphics })
  local camera = stubCamera()
  local viewport = { x = 0, y = 0, width = 768, height = 576 }
  local ok, err = pcall(renderer.captureTransitionLayers, renderer, {}, camera, {}, {}, viewport, 1, 3)
  Assert.isFalse(ok, "the injected plane failure rethrows instead of publishing")
  Assert.notNil(err, "the rethrown failure carries its injected cause")
  Assert.equal(#graphics.created, 2, "only the temporary target and the first plane were attempted")
  Assert.isTrue(graphics.created[1]._released, "the temporary presentation target releases on failure")
  Assert.isTrue(graphics.created[2]._released, "the partial world plane releases on failure")
  Assert.isTrue(renderer._frame.viewport == viewport, "the retained frame viewport restores after failure")
  Assert.isTrue(
    renderer._frame.captureLayers == true,
    "the retained frame keeps its requested capture mode after failure"
  )
  Assert.equal(
    seenViewport.worldViewport.width,
    768,
    "the failed capture still ran its single render at the live viewport"
  )
end

-- Native wipe spans, HBlank offsets, and transition sprites keep their
-- 256x192 meaning while the physical capture blits 1:1; drawing or
-- resizing alone never advances the source frame.
function T.transition_composition_maps_native_commands_to_the_live_destination()
  local graphics = fakeGraphics({})
  local renderer = FieldRenderer.new({ gxRenderer = {}, graphics = graphics })
  local world = fakeCanvas(512, 384)
  local objects = fakeCanvas(512, 384)
  local capture = { world = world, objects = objects }
  local rows = {}
  for y = 1, 192 do
    rows[y] = { { 0, 256 } }
  end
  rows[96] = { { 0, 128 } }
  local offsets = {}
  for line = 1, 192 do
    offsets[line] = 0
  end
  offsets[100] = 32
  offsets[101] = 32
  local frame = { wipe = { rows = rows }, scanlineOffsets = offsets }
  local destination = { x = 0, y = 0, width = 512, height = 384 }
  renderer:drawTransition(capture, frame, destination)
  local halfRow = nil
  for _, rect in ipairs(graphics.rectangles) do
    if rect.y == 190 then
      halfRow = rect
    end
  end
  Assert.notNil(halfRow, "the half wipe row reaches the stencil mask")
  Assert.equal(halfRow.x, 0, "the wipe span starts at the native left edge")
  Assert.equal(halfRow.w, 256, "the native half span covers half the live destination")
  Assert.equal(halfRow.h, 2, "one native scanline covers two physical rows")
  local wrapped = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image == world and draw.quad ~= nil and draw.quad.x == 64 then
      wrapped[#wrapped + 1] = draw
    end
  end
  Assert.equal(#wrapped, 1, "the nonzero HBlank run samples one wrapped physical band")
  Assert.equal(wrapped[1].quad.w, 448, "the wrapped band keeps the physical remainder width")
  Assert.equal(wrapped[1].quad.y, 198, "HBlank bands address physical scanline rows")
  Assert.equal(wrapped[1].x, 0, "the wrapped band starts at the destination edge")
  Assert.equal(wrapped[1].y, 198, "native rows map to the matching destination rows")
  Assert.equal(wrapped[1].sx, 1, "physical capture pixels blit without a native rescale")
  Assert.equal(wrapped[1].sy, 1, "physical capture rows blit without a native rescale")
  local hblankDraws = 0
  for _, draw in ipairs(graphics.draws) do
    if draw.image == world and draw.quad ~= nil then
      hblankDraws = hblankDraws + 1
    end
  end
  Assert.equal(hblankDraws, 4, "equal scanline shifts stay grouped instead of drawing per line")
  local objectDraw = nil
  for _, draw in ipairs(graphics.draws) do
    if draw.image == objects then
      objectDraw = draw
    end
  end
  Assert.notNil(objectDraw, "the object plane composes above the world plane")
  Assert.equal(objectDraw.sx, 1, "object pixels blit without a native rescale")
  Assert.isTrue(graphics.stencilTest == nil, "the stencil test restores after the wipe mask")
  Assert.equal(graphics._pushDepth, 0, "the graphics stack balances after composition")
  local function signature(draw)
    if draw.quad == nil then
      return "plain:" .. tostring(draw.x) .. "," .. tostring(draw.y)
    end
    return table.concat({
      tostring(draw.quad.x),
      tostring(draw.quad.y),
      tostring(draw.quad.w),
      tostring(draw.quad.h),
      tostring(draw.x),
      tostring(draw.y),
      tostring(draw.sx),
      tostring(draw.sy),
    }, ":")
  end
  local firstPass = {}
  for _, draw in ipairs(graphics.draws) do
    firstPass[#firstPass + 1] = signature(draw)
  end
  local firstRects = #graphics.rectangles
  renderer:drawTransition(capture, frame, destination)
  Assert.equal(#graphics.draws, 2 * #firstPass, "a repeated draw replays the same composition")
  for index, sig in ipairs(firstPass) do
    Assert.equal(signature(graphics.draws[#firstPass + index]), sig, "repeated draws never advance the source frame")
  end
  Assert.equal(rows[96][1][2], 128, "drawing leaves the native wipe rows untouched")
  Assert.equal(offsets[100], 32, "drawing leaves the native scanline offsets untouched")
  renderer:drawTransition(capture, frame, { x = 0, y = 0, width = 256, height = 192 })
  local resized = graphics.draws[#graphics.draws]
  Assert.equal(resized.sx, 0.5, "a resized destination rescales the held capture without a new tick")
  Assert.equal(#graphics.rectangles > firstRects, true, "the resized mask still replays the native spans")
end

-- Overlay motion blur follows the capture's physical size across a
-- viewport change: the old triplet releases exactly once after its
-- replacement succeeds, and a failed replacement keeps the last
-- known-good feedback without advancing the source task.
function T.encounter_blur_follows_capture_dimensions_with_exactly_once_release()
  local ledger = {}
  local graphics = fakeGraphics(ledger, { failOnCanvasCall = 6 })
  local renderer = FieldRenderer.new({ gxRenderer = {}, graphics = graphics })
  local camera = {
    captureTransitionState = function()
      return {}
    end,
    setTransitionPose = function() end,
    restoreTransitionState = function() end,
  }
  local services = {
    beginEncounterMotionBlur = function(_, layers)
      return renderer:beginEncounterMotionBlur(layers)
    end,
    stepEncounterMotionBlur = function(_, blur, layers)
      return renderer:stepEncounterMotionBlur(blur, layers)
    end,
  }
  local route = {
    role = "camera-and-fade-transition",
    task = {
      kind = "field-camera-perspective-distance-fade",
      parameters = { perspectiveDeltaRaw = 0, perspectiveTicks = 1, fadeTicks = 2 },
    },
  }
  local effect = Overlay116Effect.new(route, { camera = camera, fieldRenderer = services })
  effect:start()
  effect:acceptFieldLayers({ world = fakeCanvas(256, 192) })
  local first = assert(effect._motionBlur, "the first capture seeds the feedback triplet")
  Assert.equal(first.previous:getWidth(), 256, "the seed feedback matches its capture width")
  local phase = effect._phase
  local ok, err = pcall(effect.acceptFieldLayers, effect, { world = fakeCanvas(512, 384) })
  Assert.isFalse(ok, "a failed reseed never publishes a partial buffer: " .. tostring(err))
  Assert.isTrue(effect._motionBlur == first, "the last known-good feedback survives a failed reseed")
  Assert.equal(#graphics.created, 5, "only the replacement canvases were attempted")
  Assert.isTrue(graphics.created[4]._released, "the failed replacement frees its first canvas")
  Assert.isTrue(graphics.created[5]._released, "the failed replacement frees its second canvas")
  Assert.isFalse(first.previous._released, "the failed reseed keeps the old feedback alive")
  Assert.equal(effect._phase, phase, "the failed reseed never advances the source task")
  effect:acceptFieldLayers({ world = fakeCanvas(512, 384) })
  local second = effect._motionBlur
  Assert.isTrue(second ~= first, "a dimension change replaces the feedback triplet")
  Assert.equal(second.previous:getWidth(), 512, "the replacement feedback matches the new capture width")
  Assert.equal(second.previous:getHeight(), 384, "the replacement feedback matches the new capture height")
  Assert.isTrue(
    first.previous._released and first.current._released and first.composite._released,
    "the old triplet releases after its replacement succeeds"
  )
  Assert.equal(first.previous._releaseCount, 1, "the old feedback releases exactly once")
  Assert.equal(effect._phase, phase, "the reseed never advances the source task")
  effect:dispose()
  Assert.isTrue(second.previous._released, "completion releases the replacement triplet")
  Assert.equal(second.previous._releaseCount, 1, "the replacement releases exactly once")
  effect:dispose()
  Assert.equal(second.previous._releaseCount, 1, "disposal stays exactly once")
end

-- A launch-owned capture slot survives across source ticks: a compatible
-- slot keeps its ownership record and canvases with no new allocation,
-- each tick copies the current source planes into those canvases, a resize
-- replaces only the mismatched canvases before retiring them exactly once,
-- and a failed replacement leaves the last accepted frame untouched.
-- Captures requested without a slot stay independent.
function T.capture_reuses_compatible_slot_surfaces_across_source_ticks()
  local ledger = {}
  local graphics = fakeGraphics(ledger)
  local ticks = 0
  local scratchFirst = fakeCanvas(256, 192)
  local scratchSecond = fakeCanvas(256, 192)
  local gxRenderer = {
    draw = function(_)
      ticks = ticks + 1
      if ticks == 1 then
        return { world = scratchFirst }
      end
      return { world = scratchSecond }
    end,
  }
  local renderer = FieldRenderer.new({ gxRenderer = gxRenderer, graphics = graphics })
  local camera = stubCamera()
  local viewport = { x = 0, y = 0, width = 256, height = 192 }

  local slot = renderer:captureTransitionLayers({}, camera, {}, nil, viewport, 1, 3)
  Assert.notNil(slot, "the first launch capture publishes its planes")
  Assert.notNil(slot.world, "the first launch capture owns its world plane")
  local slotWorld = slot.world
  local allocated = #ledger

  local reused = renderer:captureTransitionLayers({}, camera, {}, nil, viewport, 1, 3, slot)
  Assert.isTrue(reused == slot, "a compatible slot keeps its ownership record across ticks")
  Assert.isTrue(slot.world == slotWorld, "a compatible slot keeps its world canvas")
  Assert.equal(#ledger, allocated, "a compatible slot allocates no new surfaces")
  local latestCopy = nil
  for index = #graphics.draws, 1, -1 do
    if graphics.drawTargets[index] == slotWorld then
      latestCopy = graphics.draws[index]
      break
    end
  end
  Assert.notNil(latestCopy, "the reused slot copies the current tick into its own canvas")
  Assert.isTrue(latestCopy.image == scratchSecond, "the reused slot samples the latest source tick")

  local wide = { x = 0, y = 0, width = 512, height = 384 }
  local resized = renderer:captureTransitionLayers({}, camera, {}, nil, wide, 1, 3, slot)
  Assert.isTrue(resized == slot, "a resized slot keeps its ownership record")
  Assert.equal(slot.world:getWidth(), 512, "the resized slot matches the new capture width")
  Assert.equal(slot.world:getHeight(), 384, "the resized slot matches the new capture height")
  Assert.isTrue(slot.world ~= slotWorld, "a resize replaces the mismatched canvas")
  Assert.isTrue(slotWorld._released, "a resize retires the incompatible canvas")
  Assert.equal(slotWorld._releaseCount, 1, "a resize retires the old canvas exactly once")

  local solo = renderer:captureTransitionLayers({}, camera, {}, nil, viewport, 1, 3)
  Assert.isTrue(solo ~= slot, "captures without a slot stay independent of the reused slot")
  Assert.isTrue(solo.world ~= slot.world, "a standalone capture owns its own world canvas")
  solo:dispose()
  Assert.isTrue(solo.world._released, "a standalone capture still releases its own canvas")

  slot:dispose()
  slot:dispose()
  Assert.equal(slot.world._releaseCount, 1, "slot disposal stays exactly once")

  -- A failed replacement never publishes a partial frame: the error
  -- rethrows, the slot keeps its last accepted canvases unreleased, every
  -- newly attempted surface releases, and a retry at the accepted size
  -- reuses the surviving slot.
  local failingLedger = {}
  local failingGraphics = fakeGraphics(failingLedger)
  local realNewCanvas = failingGraphics.newCanvas
  failingGraphics.newCanvas = function(width, height, spec)
    if width == 512 then
      error("injected replacement allocation failure")
    end
    return realNewCanvas(width, height, spec)
  end
  local failingGx = {
    draw = function(_)
      return { world = fakeCanvas(256, 192), objects = fakeCanvas(256, 192) }
    end,
  }
  local failingRenderer = FieldRenderer.new({ gxRenderer = failingGx, graphics = failingGraphics })
  local accepted = failingRenderer:captureTransitionLayers({}, camera, {}, nil, viewport, 1, 3)
  local acceptedWorld, acceptedObjects = accepted.world, accepted.objects
  Assert.notNil(acceptedObjects, "the accepted slot owns its object plane")
  local ok, err =
    pcall(failingRenderer.captureTransitionLayers, failingRenderer, {}, camera, {}, nil, wide, 1, 3, accepted)
  Assert.isFalse(ok, "the failed replacement rethrows instead of publishing")
  Assert.notNil(err, "the rethrown failure carries its injected cause")
  Assert.isTrue(accepted.world == acceptedWorld, "the failed replacement keeps the accepted world canvas")
  Assert.isTrue(accepted.objects == acceptedObjects, "the failed replacement keeps the accepted object canvas")
  Assert.isFalse(acceptedWorld._released, "the failed replacement never retires the accepted world")
  Assert.isFalse(acceptedObjects._released, "the failed replacement never retires the accepted objects")
  Assert.equal(accepted.world:getWidth(), 256, "the failed replacement keeps the accepted dimensions")
  for _, canvas in ipairs(failingGraphics.created) do
    if canvas ~= acceptedWorld and canvas ~= acceptedObjects then
      Assert.isTrue(canvas._released, "the failed replacement releases only its new surfaces")
    end
  end
  local retry = failingRenderer:captureTransitionLayers({}, camera, {}, nil, viewport, 1, 3, accepted)
  Assert.isTrue(retry == accepted, "a retry at the accepted size reuses the surviving slot")
  Assert.isTrue(accepted.world == acceptedWorld, "the retry keeps the accepted world canvas")
  accepted:dispose()
end

-- Encounter motion blur swaps its feedback roles instead of copying the
-- current frame back into the previous one: the composite still blends the
-- fresh frame weakly against the last raw input strongly, the strong term
-- is never the prior composite, and every buffer releases exactly once.
function T.motion_blur_swaps_feedback_roles_instead_of_copying_back()
  local graphics = fakeGraphics({})
  local renderer = FieldRenderer.new({ gxRenderer = {}, graphics = graphics })
  local blur = renderer:beginEncounterMotionBlur({ world = fakeCanvas(256, 192) })
  local previousRole, currentRole, composite = blur.previous, blur.current, blur.composite

  local fresh = fakeCanvas(256, 192)
  local drawsBefore = #graphics.draws
  renderer:stepEncounterMotionBlur(blur, { world = fresh })
  Assert.isTrue(blur.previous == currentRole, "the step hands the previous role to the just-drawn frame")
  Assert.isTrue(blur.current == previousRole, "the step hands the current role to the older frame")
  Assert.isTrue(blur.composite == composite, "the composite buffer keeps its role")
  local copyBack = 0
  local compositeDraws = {}
  for index = drawsBefore + 1, #graphics.draws do
    if graphics.drawTargets[index] == composite then
      compositeDraws[#compositeDraws + 1] = index
    end
    if graphics.drawTargets[index] == blur.previous and graphics.draws[index].image == blur.current then
      copyBack = copyBack + 1
    end
  end
  Assert.equal(copyBack, 0, "the step never blits the current frame back into the previous role")
  Assert.equal(#compositeDraws, 2, "one step composites exactly the fresh frame and its feedback")
  local weak = compositeDraws[1]
  local strong = compositeDraws[2]
  Assert.isTrue(graphics.draws[weak].image == currentRole, "the weak term samples the fresh frame")
  Assert.equal(graphics.drawColors[weak][1], 3 / 16, "the fresh frame keeps its weak blend weight")
  Assert.equal(graphics.drawColors[weak][4], 1, "the weak blend term stays opaque")
  Assert.isTrue(graphics.draws[strong].image == previousRole, "the strong term samples the last raw input")
  Assert.isTrue(
    graphics.draws[strong].image ~= composite,
    "the strong term is raw input, never the prior composite"
  )
  Assert.equal(graphics.drawColors[strong][1], 15 / 16, "the last raw input keeps its strong blend weight")
  Assert.equal(graphics.drawColors[strong][4], 1, "the strong blend term stays opaque")

  renderer:stepEncounterMotionBlur(blur, { world = fakeCanvas(256, 192) })
  Assert.isTrue(blur.previous == previousRole, "feedback roles alternate back on the next tick")
  Assert.isTrue(blur.current == currentRole, "feedback roles alternate back on the next tick")

  blur:dispose()
  Assert.isTrue(
    previousRole._released and currentRole._released and composite._released,
    "completion releases every feedback buffer"
  )
  Assert.equal(previousRole._releaseCount, 1, "the previous role releases exactly once")
  Assert.equal(currentRole._releaseCount, 1, "the current role releases exactly once")
  Assert.equal(composite._releaseCount, 1, "the composite releases exactly once")
  blur:dispose()
  Assert.equal(previousRole._releaseCount, 1, "feedback disposal stays exactly once")
  Assert.equal(composite._releaseCount, 1, "composite disposal stays exactly once")
end

return { tests = T }
