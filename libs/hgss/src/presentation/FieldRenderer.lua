-- Adapts HGSS field presentation state into the frame consumed by
-- the concrete Nintendo DS LÖVE renderer.

local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local SplParticleDraw = require("libs.hgss.src.presentation.SplParticleDraw")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

-- Resolves the ceil-allocated physical capture dimensions from the live
-- field viewport. Accepts the viewport record or a bare world rectangle so
-- capture stays viewport-local: a nonzero viewport origin never shifts the
-- source-local image pixels.
---@param viewport table<string, unknown> live field viewport or bare world rectangle
---@return integer captureWidth
---@return integer captureHeight
local function liveCaptureDimensions(viewport)
  local rectangle = viewport.worldViewport or viewport
  assert(
    type(rectangle.width) == "number" and rectangle.width > 0 and rectangle.width < math.huge,
    "transition capture requires a positive finite live viewport width"
  )
  assert(
    type(rectangle.height) == "number" and rectangle.height > 0 and rectangle.height < math.huge,
    "transition capture requires a positive finite live viewport height"
  )
  return math.ceil(rectangle.width), math.ceil(rectangle.height)
end

---@alias FieldRenderer.CaptureLayers { world: GxRenderer.Canvas, objects: GxRenderer.Canvas?, objectCoverage: GxRenderer.Canvas? }

---@class FieldRenderer.TransitionFrame
---@field blendAlpha number?
---@field wipe { rows: integer[][][] }?
---@field sprites {visible: boolean, imageHandle: unknown?, position: {x: number, y: number}, affine: {translateX: number, translateY: number, scaleX: number, scaleY: number, rotation: number}, matrix: number[]?, image: {origin: {x: number, y: number}}, tint: {r: number, g: number, b: number}?, opacity: number?}[] | nil
---@field affineValue number?
---@field motionBlur FieldRenderer.MotionBlur?
---@field requiresCurrentFieldLayers boolean? true when the source task consumes fresh world/object planes per tick
---@field whiteFadeAlpha number? source white palette fade within 0..1
---@field screenBrightness number? source engine master-brightness value, -16..16
---@field brightness number|table<string, unknown>? source engine master-brightness value or an opaque native task record
---@field scanlineOffsets integer[]? source HBlank BG0 horizontal offsets, one per native scanline
---@field particleSystem { draw: FieldRenderer.TransitionParticles? }? source particle mode state
---@class FieldRenderer.TransitionParticles the 3D particle layer of a source task
---@field simulation SplParticleSimulation live emitters and particles
---@field textures table<integer, love.Image> repeat-wrapped drawable by source texture id
---@field aboveSprites boolean true when the layer outranks the sprite plane

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
---@param captureLayers boolean? return the world's resolved color and object surfaces
---@param captureOnly boolean? omit presentation output and return only the requested planes
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
  assert(captureOnly ~= true or captureLayers == true, "capture-only field draws request planes")
  local viewMatrix = camera:view(alpha)
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()
  local queue =
    RenderQueue.buildInto(worldParts or {}, viewMatrix, worldProjection, billboardProjection, self._queueScratch)
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
    local captureWidth, captureHeight = liveCaptureDimensions(viewport)
    local presentationTarget = graphics.newCanvas(captureWidth, captureHeight, {
      format = "rgba8",
      readable = true,
      dpiscale = 1,
    })
    local previousCanvas = graphics.getCanvas()
    local previousViewport = frame.viewport
    local previousCaptureLayers = frame.captureLayers
    local ok, result = pcall(function()
      -- Capture through one viewport-local presentation target at the live
      -- dimensions, using the same ordinary projections as the live field.
      -- The world snapshot keeps presentation pixels while the source
      -- transition keeps interpreting native 256x192 commands.
      frame.viewport = {
        worldViewport = { x = 0, y = 0, width = captureWidth, height = captureHeight },
      }
      frame.captureLayers = true
      graphics.setCanvas(presentationTarget)
      local layers = self.gxRenderer:draw(frame)
      return self:_captureLayers(
        assert(layers, "GxRenderer must publish requested field planes"),
        captureWidth,
        captureHeight
      )
    end)
    local restored, restoreError = pcall(function()
      graphics.setCanvas(previousCanvas)
      frame.viewport = previousViewport
      frame.captureLayers = previousCaptureLayers
    end)
    presentationTarget:release()
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
---@param presentationPixelScale integer? presentation scale for sprite composition
---@return FieldRenderer.CaptureLayers fresh launch-owned presentation-sized planes
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
    "transition tick capture publishes its presentation planes"
  )
end

-- Draws a source task's particle layer under the retail particle camera,
-- scaled from the native 256x192 screen to the destination viewport.
---@param graphics table<string, function> host graphics namespace
---@param particles FieldRenderer.TransitionParticles
---@param destination { x: number, y: number, width: number, height: number }
local function drawTransitionParticles(graphics, particles, destination)
  local function resolveTexture(_, particle, child)
    return assert(particles.textures[child ~= nil and child.texNo or particle.texNo], "particle texture is uploaded")
  end
  graphics.push()
  graphics.translate(destination.x, destination.y)
  graphics.scale(destination.width / NativeDisplay.WIDTH, destination.height / NativeDisplay.HEIGHT)
  SplParticleDraw.draw(graphics, particles.simulation, {
    centerX = NativeDisplay.WIDTH / 2,
    centerY = NativeDisplay.HEIGHT / 2,
    resolveTexture = resolveTexture,
  })
  graphics.pop()
end

---@param capture { world: GxRenderer.Canvas, objects: GxRenderer.Canvas? } launch-owned presentation-sized planes
---@param transitionFrame FieldRenderer.TransitionFrame source transition sprites and coefficients
---@param destination { x: number, y: number, width: number, height: number } live field viewport
function FieldRenderer:drawTransition(capture, transitionFrame, destination)
  local graphics = assert(self._graphics, "transition field composition requires host graphics")
  assert(capture and capture.world, "transition composition requires its launch-owned world plane")
  local captureWidth = capture.world:getWidth()
  local captureHeight = capture.world:getHeight()
  assert(captureWidth > 0 and captureHeight > 0, "transition composition requires positive capture planes")
  if capture.objects ~= nil then
    assert(
      capture.objects:getWidth() == captureWidth and capture.objects:getHeight() == captureHeight,
      "transition object plane matches the captured world plane"
    )
  end
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
  -- Native wipe rows, HBlank offsets, sprite anchors, and brightness stay
  -- in 256x192 source units; physical field pixels blit through the
  -- capture-to-destination transform.
  local sourceScaleX = destination.width / NativeDisplay.WIDTH
  local sourceScaleY = destination.height / NativeDisplay.HEIGHT
  local captureScaleX = destination.width / captureWidth
  local captureScaleY = destination.height / captureHeight
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
                destination.x + left * sourceScaleX,
                destination.y + (y - 1) * sourceScaleY,
                (right - left) * sourceScaleX,
                sourceScaleY
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
      local composite = assert(motionBlur.composite, "encounter motion blur draws its composite plane")
      graphics.setBlendMode("replace", "premultiplied")
      graphics.setColor(1, 1, 1, blend)
      graphics.draw(
        composite,
        destination.x,
        destination.y,
        0,
        destination.width / composite:getWidth(),
        destination.height / composite:getHeight()
      )
      graphics.setBlendMode("alpha", "alphamultiply")
    else
      graphics.setColor(1, 1, 1, 1)
      local scanlineOffsets = transitionFrame.scanlineOffsets
      if scanlineOffsets ~= nil then
        assert(
          type(scanlineOffsets) == "table" and #scanlineOffsets == NativeDisplay.HEIGHT,
          "source HBlank transitions carry one horizontal offset per native scanline"
        )
        local imageWidth = captureWidth
        local imageHeight = captureHeight
        local sampleScaleX = imageWidth / NativeDisplay.WIDTH
        local sampleScaleY = imageHeight / NativeDisplay.HEIGHT
        local y = 1
        while y <= NativeDisplay.HEIGHT do
          local offset = scanlineOffsets[y]
          assert(type(offset) == "number" and offset % 1 == 0, "source scanline offsets are integer pixels")
          -- HBlank offsets wrap in native units; the wrapped offset samples
          -- the physical capture at the matching source fraction.
          local wrappedOffset = offset % NativeDisplay.WIDTH
          local endY = y + 1
          while endY <= NativeDisplay.HEIGHT do
            local nextOffset = scanlineOffsets[endY]
            assert(type(nextOffset) == "number" and nextOffset % 1 == 0, "source scanline offsets are integer pixels")
            if nextOffset % NativeDisplay.WIDTH ~= wrappedOffset then
              break
            end
            endY = endY + 1
          end
          local sourceY = (y - 1) * sampleScaleY
          local groupHeight = (endY - y) * sampleScaleY
          local sourceX = wrappedOffset * sampleScaleX
          local firstWidth = imageWidth - sourceX
          local firstQuad = graphics.newQuad(sourceX, sourceY, firstWidth, groupHeight, imageWidth, imageHeight)
          local destinationY = destination.y + (y - 1) * sourceScaleY
          graphics.draw(capture.world, firstQuad, destination.x, destinationY, 0, captureScaleX, captureScaleY)
          if sourceX > 0 then
            local secondQuad = graphics.newQuad(0, sourceY, sourceX, groupHeight, imageWidth, imageHeight)
            graphics.draw(
              capture.world,
              secondQuad,
              destination.x + firstWidth * captureScaleX,
              destinationY,
              0,
              captureScaleX,
              captureScaleY
            )
          end
          y = endY
        end
      else
        graphics.draw(capture.world, destination.x, destination.y, 0, captureScaleX, captureScaleY)
      end
      if capture.objects ~= nil then
        graphics.setColor(1, 1, 1, 1)
        graphics.draw(capture.objects, destination.x, destination.y, 0, captureScaleX, captureScaleY)
      end
    end
    local particles = transitionFrame.particleSystem and transitionFrame.particleSystem.draw
    if particles ~= nil and not particles.aboveSprites then
      drawTransitionParticles(graphics, particles, destination)
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
          destination.x + x * sourceScaleX,
          destination.y + y * sourceScaleY,
          rotation,
          scaleSpriteX * sourceScaleX,
          scaleSpriteY * sourceScaleY,
          -sprite.image.origin.x,
          -sprite.image.origin.y
        )
      end
    end
    if particles ~= nil and particles.aboveSprites then
      drawTransitionParticles(graphics, particles, destination)
    end
    if wipe ~= nil then
      graphics.setStencilTest()
    end
    local screenBrightness = transitionFrame.screenBrightness
    local brightness = transitionFrame.brightness
    if type(screenBrightness) ~= "number" and type(brightness) == "number" then
      screenBrightness = brightness --[[@as number]]
    end
    if type(screenBrightness) == "number" then
      -- GX master brightness uses positive values for white and negative
      -- values for black (src/field/encounter_effect.c).
      assert(screenBrightness >= -16 and screenBrightness <= 16, "source master brightness stays within -16..16")
      local alpha = math.abs(screenBrightness) / 16
      if screenBrightness < 0 then
        graphics.setColor(0, 0, 0, alpha)
      else
        graphics.setColor(1, 1, 1, alpha)
      end
      graphics.rectangle("fill", destination.x, destination.y, destination.width, destination.height)
    elseif transitionFrame.whiteFadeAlpha ~= nil then
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

---@param seedLayers FieldRenderer.CaptureLayers first previous-frame source planes for the encounter blend
---@return FieldRenderer.MotionBlur transition-owned feedback pair
function FieldRenderer:beginEncounterMotionBlur(seedLayers)
  assert(seedLayers and seedLayers.world, "encounter motion blur requires its first world plane")
  local captureWidth, captureHeight = seedLayers.world:getWidth(), seedLayers.world:getHeight()
  assert(captureWidth > 0 and captureHeight > 0, "encounter motion blur requires positive capture planes")
  if seedLayers.objects ~= nil then
    assert(
      seedLayers.objects:getWidth() == captureWidth and seedLayers.objects:getHeight() == captureHeight,
      "encounter motion blur object plane matches the captured world plane"
    )
  end
  local graphics = assert(self._graphics, "encounter motion blur requires host graphics")
  local motionBlur = {
    _canvases = {},
    _disposed = false,
    dispose = FieldRenderer._disposeCapture,
  }
  local ok, result = pcall(function()
    for _, key in ipairs({ "previous", "current", "composite" }) do
      local canvas = graphics.newCanvas(captureWidth, captureHeight, {
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
  assert(
    currentLayers.world:getWidth() == motionBlur.previous:getWidth()
      and currentLayers.world:getHeight() == motionBlur.previous:getHeight(),
    "motion blur advances only on capture planes matching its feedback dimensions"
  )
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

---@param target GxRenderer.Canvas physical capture-sized feedback output
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
---@param captureWidth integer ceil-allocated live viewport width
---@param captureHeight integer ceil-allocated live viewport height
---@return FieldRenderer.Capture independent surfaces owned by the caller
function FieldRenderer:_captureLayers(layers, captureWidth, captureHeight)
  local graphics = assert(self._graphics, "field plane capture requires the LÖVE graphics boundary")
  assert(
    type(captureWidth) == "number" and captureWidth > 0 and type(captureHeight) == "number" and captureHeight > 0,
    "transition capture copies its planes at positive physical dimensions"
  )
  local capture = {
    _canvases = {},
    _disposed = false,
    dispose = FieldRenderer._disposeCapture,
  }
  local ok, result = pcall(function()
    capture.world = self:_copyCanvas(graphics, layers.world, capture, captureWidth, captureHeight)
    if layers.objects ~= nil then
      capture.objects = self:_copyCanvas(graphics, layers.objects, capture, captureWidth, captureHeight)
    end
    if layers.objectCoverage ~= nil then
      capture.objectCoverage = self:_copyCanvas(graphics, layers.objectCoverage, capture, captureWidth, captureHeight)
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
---@param targetWidth integer physical capture width
---@param targetHeight integer physical capture height
---@return GxRenderer.Canvas
function FieldRenderer:_copyCanvas(graphics, source, capture, targetWidth, targetHeight)
  -- Launch-owned transition planes keep the live presentation sampling: the
  -- copy resamples each renderer-owned scratch plane into an independent
  -- physical capture through one GPU blit, so a default-filtered
  -- DPI-following canvas would blur and mis-size the frozen field behind
  -- the effect.
  assert(
    type(targetWidth) == "number" and targetWidth > 0 and type(targetHeight) == "number" and targetHeight > 0,
    "transition plane copies target positive physical dimensions"
  )
  local canvas = graphics.newCanvas(targetWidth, targetHeight, {
    format = "rgba8",
    dpiscale = 1,
  })
  canvas:setFilter("nearest", "nearest")
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
    graphics.draw(source, 0, 0, 0, targetWidth / source:getWidth(), targetHeight / source:getHeight())
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
