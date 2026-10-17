-- Adapts HGSS field presentation state into the frame consumed by
-- the concrete Nintendo DS LÖVE renderer.

local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

local NATIVE_VIEWPORT = {
  worldViewport = { x = 0, y = 0, width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT },
}

---@alias FieldRenderer.CaptureLayers { world: GxRenderer.Canvas, objects: GxRenderer.Canvas?, objectCoverage: GxRenderer.Canvas? }

---@class FieldRenderer.TransitionFrame
---@field blendAlpha number?
---@field wipe { rows: integer[][][] }?
---@field sprites {visible: boolean, imageHandle: unknown?, position: {x: number, y: number}, affine: {translateX: number, translateY: number, scaleX: number, scaleY: number, rotation: number}, matrix: number[]?, image: {origin: {x: number, y: number}}, tint: {r: number, g: number, b: number}?, opacity: number?}[] | nil
---@field affineValue number?
---@field motionBlur FieldRenderer.MotionBlur?
---@field requiresCurrentFieldLayers boolean? true when the source task consumes fresh world/object planes per tick
---@field whiteFadeAlpha number? source white palette fade within 0..1

---@class FieldRenderer.MotionBlur
---@field previous GxRenderer.Canvas
---@field current GxRenderer.Canvas
---@field composite GxRenderer.Canvas
---@field _canvases GxRenderer.Canvas[]
---@field _disposed boolean
---@field dispose fun(self: FieldRenderer.MotionBlur): boolean

---@class FieldRenderer
---@field gxRenderer GxRenderer
---@field stats table<string, unknown>
---@field _ownsRenderer boolean
---@field _queueScratch RenderQueueScratch
---@field _frame table<string, unknown> retained Gx frame record, overwritten every draw
---@field _graphics table<string, function> graphics boundary used for launch-owned plane snapshots
---@field _lightingProfile table<string, unknown>? profile identity of the cached lighting selection
---@field _lightingBucket integer? effective half-second bucket of the cached lighting selection
---@field _lightingRecord table<string, unknown>? cached lighting selection
---@field clearColor number[]?
local FieldRenderer = {}
FieldRenderer.__index = FieldRenderer

-- Selects the active time-of-day lighting record from a runtime render
-- environment: the normalized lighting profile plus the optional
-- presentation time override. Needs only environment state, never scene
-- geometry or map identity. The selection is cached by profile identity
-- plus the effective half-second bucket and reused while both are stable.
---@param renderEnvironment table<string, unknown>
---@return table<string, unknown>?
function FieldRenderer:_selectedLighting(renderEnvironment)
  local profile = renderEnvironment.lighting
  if profile == nil or profile.records == nil then
    return nil
  end
  local timeSeconds = renderEnvironment.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS
  local bucket = FieldLightProfile.bucket(timeSeconds)
  if self._lightingProfile == profile and self._lightingBucket == bucket then
    return self._lightingRecord
  end
  local record = FieldLightProfile.select(profile, timeSeconds)
  self._lightingProfile = profile
  self._lightingBucket = bucket
  self._lightingRecord = record
  return record
end

---@param opts table<string, unknown>?
---@return FieldRenderer
function FieldRenderer.new(opts)
  opts = opts or {}
  local gxRenderer = opts.gxRenderer
  local ownsRenderer = gxRenderer == nil
  if gxRenderer == nil then
    local backendOpts = {}
    for key, value in pairs(opts) do
      backendOpts[key] = value
    end
    gxRenderer = GxRenderer.new(backendOpts)
  end
  return setmetatable({
    gxRenderer = gxRenderer,
    stats = gxRenderer.stats,
    _ownsRenderer = ownsRenderer,
    clearColor = opts.clearColor,
    _queueScratch = RenderQueue.newScratch(),
    _graphics = opts.graphics or (love and love.graphics),
    _frame = {},
    _lightingProfile = nil,
    _lightingBucket = nil,
    _lightingRecord = nil,
  }, FieldRenderer)
end

---@param renderEnvironment table<string, unknown> runtime lighting, edge-color, and fog state; a full scene runtime stays structurally valid here
---@param camera table<string, unknown>
---@param worldParts table[][]?
---@param spriteItems table[]?
---@param viewport table<string, unknown>
---@param alpha number
---@param presentationPixelScale integer?
---@param captureLayers boolean? return the native world's resolved color and object surfaces
---@param captureOnly boolean? omit presentation output and return only the requested native planes
---@return FieldRenderer.CaptureLayers?
function FieldRenderer:draw(
  renderEnvironment,
  camera,
  worldParts,
  spriteItems,
  viewport,
  alpha,
  presentationPixelScale,
  captureLayers,
  captureOnly
)
  assert(captureOnly ~= true or captureLayers == true, "capture-only field draws request native planes")
  local viewMatrix = camera:view(alpha)
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()
  local queue = RenderQueue.buildInto(worldParts or {}, viewMatrix, self._queueScratch)
  -- The retained Gx frame record is overwritten every draw: no per-frame
  -- frame allocation remains on the steady 3D path. Assigning nil clears
  -- the optional presentation scale on sprite-less frames.
  local frame = self._frame
  frame.lighting = self:_selectedLighting(renderEnvironment)
  frame.edgeColors = renderEnvironment.edgeColors
  frame.fog = renderEnvironment.fog
  frame.viewMatrix = viewMatrix
  frame.cameraZoom = camera.zoom
  frame.presentationPixelScale = presentationPixelScale
  frame.worldProjection = worldProjection
  frame.billboardProjection = billboardProjection
  frame.clearColor = self.clearColor
  frame.queue = queue
  frame.spriteItems = spriteItems
  frame.viewport = viewport
  frame.captureLayers = captureLayers
  local capture
  if captureLayers then
    local graphics = assert(self._graphics, "field plane capture requires the LÖVE graphics boundary")
    local nativeTarget = graphics.newCanvas(NativeDisplay.WIDTH, NativeDisplay.HEIGHT, {
      format = "rgba8",
      readable = true,
      dpiscale = 1,
    })
    local previousCanvas = graphics.getCanvas()
    local previousViewport = frame.viewport
    local previousWorldProjection = frame.worldProjection
    local previousBillboardProjection = frame.billboardProjection
    local previousCaptureLayers = frame.captureLayers
    local ok, result = pcall(function()
      frame.viewport = NATIVE_VIEWPORT
      frame.worldProjection = camera:canonicalProjection()
      frame.billboardProjection = camera:canonicalBillboardProjection()
      frame.captureLayers = true
      graphics.setCanvas(nativeTarget)
      local layers = self.gxRenderer:draw(frame)
      return self:_captureLayers(assert(layers, "GxRenderer must publish requested field planes"))
    end)
    local restored, restoreError = pcall(function()
      graphics.setCanvas(previousCanvas)
      frame.viewport = previousViewport
      frame.worldProjection = previousWorldProjection
      frame.billboardProjection = previousBillboardProjection
      frame.captureLayers = previousCaptureLayers
    end)
    nativeTarget:release()
    if not ok then
      error(result, 0)
    end
    if not restored then
      result:dispose()
      error(restoreError, 0)
    end
    capture = result
  end
  frame.captureLayers = nil
  if not captureOnly then
    local drawOk, drawError = pcall(self.gxRenderer.draw, self.gxRenderer, frame)
    if not drawOk then
      if capture ~= nil then
        capture:dispose()
      end
      error(drawError, 0)
    end
  end
  return capture
end

---@param renderEnvironment table<string, unknown> runtime field render state
---@param camera table<string, unknown> current source-tick field camera
---@param worldParts table[][]? current field world planes
---@param spriteItems table[]? current field object plane
---@param viewport table<string, unknown> current field viewport
---@param alpha number current field interpolation alpha
---@param presentationPixelScale integer? presentation scale for native sprite composition
---@return FieldRenderer.CaptureLayers fresh launch-owned native planes
function FieldRenderer:captureTransitionLayers(
  renderEnvironment,
  camera,
  worldParts,
  spriteItems,
  viewport,
  alpha,
  presentationPixelScale
)
  return assert(
    self:draw(renderEnvironment, camera, worldParts, spriteItems, viewport, alpha, presentationPixelScale, true, true),
    "transition tick capture publishes its native planes"
  )
end

---@param capture { world: GxRenderer.Canvas, objects: GxRenderer.Canvas? } immutable native launch planes
---@param transitionFrame FieldRenderer.TransitionFrame source transition sprites and coefficients
---@param destination { x: number, y: number, width: number, height: number } live field viewport
function FieldRenderer:drawTransition(capture, transitionFrame, destination)
  local graphics = assert(self._graphics, "transition field composition requires host graphics")
  assert(capture and capture.world, "transition composition requires its launch-owned world plane")
  assert(capture.world:getWidth() == NativeDisplay.WIDTH, "transition world plane has native width")
  assert(capture.world:getHeight() == NativeDisplay.HEIGHT, "transition world plane has native height")
  assert(
    type(destination) == "table"
      and type(destination.x) == "number"
      and type(destination.y) == "number"
      and type(destination.width) == "number"
      and type(destination.height) == "number"
      and destination.width > 0
      and destination.height > 0,
    "transition destination is a positive live viewport"
  )
  local scaleX = destination.width / NativeDisplay.WIDTH
  local scaleY = destination.height / NativeDisplay.HEIGHT
  local blend = transitionFrame.blendAlpha and transitionFrame.blendAlpha / 16 or 1
  local wipe = transitionFrame.wipe
  assert(blend >= 0 and blend <= 1, "source blend coefficient stays within 0..16")

  graphics.push("all")
  local ok, result = pcall(function()
    graphics.setShader()
    graphics.setBlendMode("alpha", "alphamultiply")
    if wipe ~= nil then
      assert(type(wipe.rows) == "table" and #wipe.rows == NativeDisplay.HEIGHT, "source wipe has native scanlines")
      graphics.stencil(function()
        for y, spans in ipairs(wipe.rows) do
          for _, span in ipairs(spans) do
            local left, right = span[1], span[2]
            assert(left >= 0 and right <= NativeDisplay.WIDTH and right >= left, "source wipe span is native bounded")
            if right > left then
              graphics.rectangle(
                "fill",
                destination.x + left * scaleX,
                destination.y + (y - 1) * scaleY,
                (right - left) * scaleX,
                scaleY
              )
            end
          end
        end
      end, "replace", 1, true)
      graphics.setColor(0, 0, 0, 1)
      graphics.rectangle("fill", destination.x, destination.y, destination.width, destination.height)
      graphics.setStencilTest("equal", 1)
    end
    if transitionFrame.motionBlur ~= nil then
      local motionBlur = assert(transitionFrame.motionBlur, "encounter motion blur draws while attached")
      assert(not motionBlur._disposed, "disposed encounter motion blur cannot draw")
      graphics.setBlendMode("replace", "premultiplied")
      graphics.setColor(1, 1, 1, blend)
      graphics.draw(motionBlur.composite, destination.x, destination.y, 0, scaleX, scaleY)
      graphics.setBlendMode("alpha", "alphamultiply")
    else
      graphics.setColor(1, 1, 1, 1)
      graphics.draw(capture.world, destination.x, destination.y, 0, scaleX, scaleY)
      if capture.objects ~= nil then
        graphics.setColor(1, 1, 1, 1)
        graphics.draw(capture.objects, destination.x, destination.y, 0, scaleX, scaleY)
      end
    end
    for _, sprite in ipairs(transitionFrame.sprites or {}) do
      if sprite.visible then
        assert(sprite.imageHandle ~= nil, "visible source sprites have launch-owned GPU images")
        local x = sprite.position.x / 4096 + sprite.affine.translateX
        local y = sprite.position.y / 4096 + sprite.affine.translateY
        local scaleSpriteX = sprite.affine.scaleX
        local scaleSpriteY = sprite.affine.scaleY
        local rotation = math.rad(sprite.affine.rotation)
        if sprite.matrix ~= nil then
          x = sprite.matrix[1] / 4096
          y = sprite.matrix[2] / 4096
        elseif (transitionFrame.affineValue or 0) ~= 0 then
          local affine = transitionFrame.affineValue / 4096
          scaleSpriteX = scaleSpriteX * affine
          scaleSpriteY = scaleSpriteY * affine
        end
        local tint = sprite.tint or { r = 1, g = 1, b = 1 }
        local opacity = sprite.opacity or 1
        assert(tint.r >= 0 and tint.r <= 1, "transition sprite red tint stays within 0..1")
        assert(tint.g >= 0 and tint.g <= 1, "transition sprite green tint stays within 0..1")
        assert(tint.b >= 0 and tint.b <= 1, "transition sprite blue tint stays within 0..1")
        assert(opacity >= 0 and opacity <= 1, "transition sprite opacity stays within 0..1")
        graphics.setColor(tint.r, tint.g, tint.b, blend * opacity)
        graphics.draw(
          sprite.imageHandle,
          destination.x + x * scaleX,
          destination.y + y * scaleY,
          rotation,
          scaleSpriteX * scaleX,
          scaleSpriteY * scaleY,
          -sprite.image.origin.x,
          -sprite.image.origin.y
        )
      end
    end
    if wipe ~= nil then
      graphics.setStencilTest()
    end
    if transitionFrame.whiteFadeAlpha ~= nil then
      local alpha = transitionFrame.whiteFadeAlpha
      assert(alpha >= 0 and alpha <= 1, "source white palette fade stays within 0..1")
      graphics.setColor(1, 1, 1, alpha)
      graphics.rectangle("fill", destination.x, destination.y, destination.width, destination.height)
    end
  end)
  graphics.pop()
  if not ok then
    error(result, 0)
  end
end

---@param seedLayers FieldRenderer.CaptureLayers first previous-frame source planes for the DS capture blend
---@return FieldRenderer.MotionBlur transition-owned feedback pair
function FieldRenderer:beginEncounterMotionBlur(seedLayers)
  assert(seedLayers and seedLayers.world, "encounter motion blur requires its first native world plane")
  assert(seedLayers.world:getWidth() == NativeDisplay.WIDTH, "motion blur source has native width")
  assert(seedLayers.world:getHeight() == NativeDisplay.HEIGHT, "motion blur source has native height")
  local graphics = assert(self._graphics, "encounter motion blur requires host graphics")
  local motionBlur = {
    _canvases = {},
    _disposed = false,
    dispose = FieldRenderer._disposeCapture,
  }
  local ok, result = pcall(function()
    for _, key in ipairs({ "previous", "current", "composite" }) do
      local canvas = graphics.newCanvas(NativeDisplay.WIDTH, NativeDisplay.HEIGHT, {
        format = "rgba8",
        readable = true,
        dpiscale = 1,
      })
      motionBlur[key] = canvas
      motionBlur._canvases[#motionBlur._canvases + 1] = canvas
    end
    self:_drawMotionBlurLayers(motionBlur.previous, seedLayers)
    return motionBlur
  end)
  if not ok then
    motionBlur:dispose()
    error(result, 0)
  end
  return result
end

---@param motionBlur FieldRenderer.MotionBlur transition-owned previous and composite canvases
---@param currentLayers FieldRenderer.CaptureLayers source planes rendered after this source tick's mutations
function FieldRenderer:stepEncounterMotionBlur(motionBlur, currentLayers)
  assert(not motionBlur._disposed, "disposed encounter motion blur cannot advance")
  assert(currentLayers.world:getWidth() == NativeDisplay.WIDTH, "motion blur current frame has native width")
  assert(currentLayers.world:getHeight() == NativeDisplay.HEIGHT, "motion blur current frame has native height")
  local graphics = assert(self._graphics)
  graphics.push("all")
  local ok, result = pcall(function()
    self:_drawMotionBlurLayers(motionBlur.current, currentLayers)
    graphics.setCanvas(motionBlur.composite)
    graphics.setScissor()
    graphics.setBlendMode("replace", "premultiplied")
    graphics.clear(0, 0, 0, 0)
    graphics.setBlendMode("add", "alphamultiply")
    graphics.setColor(3 / 16, 3 / 16, 3 / 16, 1)
    graphics.draw(motionBlur.current, 0, 0)
    graphics.setColor(15 / 16, 15 / 16, 15 / 16, 1)
    graphics.draw(motionBlur.previous, 0, 0)

    graphics.setCanvas(motionBlur.previous)
    graphics.setBlendMode("replace", "premultiplied")
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(motionBlur.current, 0, 0)
  end)
  graphics.pop()
  if not ok then
    error(result, 0)
  end
end

---@param target GxRenderer.Canvas native source output canvas
---@param layers FieldRenderer.CaptureLayers resolved world and object source planes
function FieldRenderer:_drawMotionBlurLayers(target, layers)
  local graphics = assert(self._graphics)
  graphics.push("all")
  local ok, result = pcall(function()
    graphics.setCanvas(target)
    graphics.setScissor()
    graphics.setShader()
    graphics.setBlendMode("replace", "premultiplied")
    graphics.clear(0, 0, 0, 0)
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(layers.world, 0, 0)
    if layers.objects ~= nil then
      graphics.setBlendMode("alpha", "alphamultiply")
      graphics.draw(layers.objects, 0, 0)
    end
  end)
  graphics.pop()
  if not ok then
    error(result, 0)
  end
end

---@class FieldRenderer.Capture
---@field world GxRenderer.Canvas
---@field objects GxRenderer.Canvas?
---@field objectCoverage GxRenderer.Canvas?
---@field _canvases GxRenderer.Canvas[]
---@field _disposed boolean
---@field dispose fun(self: FieldRenderer.Capture): boolean

---@param layers FieldRenderer.CaptureLayers renderer-owned scratch surfaces
---@return FieldRenderer.Capture independent surfaces owned by the caller
function FieldRenderer:_captureLayers(layers)
  local graphics = assert(self._graphics, "field plane capture requires the LÖVE graphics boundary")
  local capture = {
    _canvases = {},
    _disposed = false,
    dispose = FieldRenderer._disposeCapture,
  }
  local ok, result = pcall(function()
    capture.world = self:_copyCanvas(graphics, layers.world, capture)
    if layers.objects ~= nil then
      capture.objects = self:_copyCanvas(graphics, layers.objects, capture)
    end
    if layers.objectCoverage ~= nil then
      capture.objectCoverage = self:_copyCanvas(graphics, layers.objectCoverage, capture)
    end
    return capture
  end)
  if not ok then
    capture:dispose()
    error(result, 0)
  end
  return result
end

---@param graphics GxRenderer.Graphics
---@param source GxRenderer.Canvas
---@param capture { _canvases: GxRenderer.Canvas[] } partial capture accumulating its canvases
---@return GxRenderer.Canvas
function FieldRenderer:_copyCanvas(graphics, source, capture)
  local canvas = graphics.newCanvas(source:getWidth(), source:getHeight())
  capture._canvases[#capture._canvases + 1] = canvas

  local previousCanvas = graphics.getCanvas()
  local previousShader = graphics.getShader()
  local previousBlend, previousBlendAlpha = graphics.getBlendMode()
  local red, green, blue, alpha = graphics.getColor()
  local sx, sy, sw, sh = graphics.getScissor()
  local ok, err = pcall(function()
    graphics.setCanvas(canvas)
    graphics.setScissor()
    graphics.setShader()
    graphics.setBlendMode("replace", "premultiplied")
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(source, 0, 0)
  end)
  local restored, restoreErr = pcall(function()
    graphics.setCanvas(previousCanvas)
    graphics.setShader(previousShader)
    graphics.setBlendMode(previousBlend, previousBlendAlpha)
    graphics.setColor(red, green, blue, alpha)
    if sx == nil then
      graphics.setScissor()
    else
      graphics.setScissor(sx, sy, sw, sh)
    end
  end)
  if not ok then
    error(err, 0)
  end
  if not restored then
    error(restoreErr, 0)
  end
  return canvas
end

---@param capture FieldRenderer.Capture
---@return boolean true when this call released the canvases
function FieldRenderer._disposeCapture(capture)
  if capture._disposed then
    return false
  end
  capture._disposed = true
  for _, canvas in ipairs(capture._canvases) do
    canvas:release()
  end
  return true
end

function FieldRenderer:release()
  if self._ownsRenderer then
    self.gxRenderer:release()
    self._ownsRenderer = false
  end
end

return FieldRenderer
