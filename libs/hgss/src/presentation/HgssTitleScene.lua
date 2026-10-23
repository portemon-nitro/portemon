-- Renders the generated HGSS title through the existing Nitro model renderer.
-- The scene owns two independent transforms: the sourced camera (a fixed
-- projection with axis-stepped waypoints advanced on the 30 Hz title tick)
-- and the host composition (the safe-area stage, accent placement and draw
-- offsets). Presentation offsets never alter the sourced camera track.

local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
local DisplayContext = require("libs.ui.src.DisplayContext")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local Matrix4 = require("libs.math.src.Matrix4")

---@class HgssTitleScene
---@field versionId string
---@field cacheFs table<string, function>
---@field graphics table<string, function>
---@field displayContext DisplayContext
---@field width number
---@field height number
---@field tick integer
---@field promptFrame integer
---@field cameraPos number[]? sourced camera position, snap-initialized to the end pose
---@field cameraPointIndex integer? active waypoint, 1-based
---@field cameraWait integer? remaining hold ticks before the active waypoint steps
---@field canvasWidth number? live 3D target width
---@field canvasHeight number? live 3D target height
---@field images love.Image[]
---@field canvas love.Canvas?
---@field pool GpuAssetPool?
---@field renderer FieldRenderer?
---@field legend ModelInstance?
---@field sparkle ModelInstance?
---@field proceedRequested boolean latched accepted title input; the prompt holds steady instead of flashing
---@field bundle table<string, unknown>
---@field sourceEnvironment table<string, unknown>?
---@field surfaces table<string, love.Image>?
---@field disposed boolean
---@field layout table<string, unknown>?
---@field buttonBounds { x: number, y: number, width: number, height: number }?
local HgssTitleScene = {}
HgssTitleScene.__index = HgssTitleScene

local WIDTH, HEIGHT = 256, 192
-- The source Nitro half-angle index 0xB60 converts to a narrow vertical
-- field of view of about 32 degrees, not the 42 degrees a generic
-- presentation default would assume.
local HALF_ANGLE_INDEX = 0xB60
-- The source (0, 0.5) clip pair cannot reach a host depth projection: a
-- zero near plane is not representable. The runtime maps it onto a stable
-- positive range that contains the whole camera script instead. Every
-- scripted eye stays hundreds of units from the title target, so the near
-- plane keeps close geometry while the far plane preserves the
-- model-visible depth equivalent.
local GPU_NEAR, GPU_FAR = 1, 5000
-- Bounded 3D target heights per stage class; widths derive from the stage
-- aspect and stay under the canvas cap below. The target never tracks the
-- host window: a full-window canvas would break the field-memory budget.
local CANVAS_HEIGHT_NATIVE = 192
local CANVAS_HEIGHT_WIDE = 288
local CANVAS_MAX_WIDTH, CANVAS_MAX_HEIGHT = 1024, 576
local EDITION_NAMES = { heartgold = "SOULSILVER", soulsilver = "HEARTGOLD" }
local EDITION_COLORS = {
  heartgold = { 0.79, 0.40, 0.19 },
  soulsilver = { 0.38, 0.65, 0.88 },
}
local TITLE_ENVIRONMENT = {
  edgeColors = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0, [7] = 0 },
  fog = {
    enabled = false,
    color = 0,
    offset = 0,
    slope = 0,
    alpha = 0,
    table = {
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    },
  },
}

-- The constant title lighting profile, matching the compiled title record:
-- exactly two enabled neutral-white lights pointing straight up (the
-- normalized retail title vectors) over four slots, with a white diffuse
-- key, a mid ambient floor and specular/emission off. Production bundles
-- always carry this record after strict validation; the built-in copy keeps
-- synthetic scenes without a compiled record rendering lit instead of
-- falling back to an unlit renderer default.
local WHITE_RGB555 = 31 + 31 * 32 + 31 * 1024
local AMBIENT_RGB555 = 10 + 10 * 32 + 10 * 1024
local FX12_ONE = 4096
local function titleLightSlot(enabled, x, y, z)
  return {
    enabled = enabled,
    colorRgb555 = enabled and WHITE_RGB555 or 0,
    color = enabled and { 1, 1, 1 } or { 0, 0, 0 },
    vectorFx12 = { x, y, z },
    direction = { x / FX12_ONE, y / FX12_ONE, z / FX12_ONE },
  }
end
local DEFAULT_TITLE_LIGHTING = {
  records = {
    {
      endHalfSeconds = 43200,
      lights = {
        titleLightSlot(true, 0, FX12_ONE, 0),
        titleLightSlot(true, 0, FX12_ONE, 0),
        titleLightSlot(false, 0, 0, 0),
        titleLightSlot(false, 0, 0, 0),
      },
      diffuseRgb555 = WHITE_RGB555,
      ambientRgb555 = AMBIENT_RGB555,
      specularRgb555 = 0,
      emissionRgb555 = 0,
    },
  },
}

local function copyWithAnimations(descriptor, clips)
  local copy = {}
  for key, value in pairs(descriptor) do
    copy[key] = value
  end
  copy.animations = {}
  local seen = {}
  for _, clip in ipairs(descriptor.animations) do
    copy.animations[#copy.animations + 1] = clip
    seen[clip.id] = true
  end
  for _, clip in pairs(clips) do
    if not seen[clip.id] then
      copy.animations[#copy.animations + 1] = clip
      seen[clip.id] = true
    end
  end
  return copy
end

local function ownedImage(self, path, width, height)
  local bytes = assert(self.cacheFs:read(path), "generated title image is missing: " .. path)
  local data = love.filesystem.newFileData(bytes, path)
  local image = self.graphics.newImage(data)
  image:setFilter("nearest", "nearest")
  if width ~= nil then
    assert(image:getWidth() == width and image:getHeight() == height, "generated title surface dimensions changed")
  end
  self.images[#self.images + 1] = image
  return image
end

local function buildModel(self, descriptor, clips, key)
  local definition = ModelDefinition.fromNitroDescriptor(copyWithAnimations(descriptor, clips), { key = key })
  local meshes = {}
  for _, mesh in ipairs(definition.meshes) do
    local resource = self.pool:meshFor(mesh.geometry)
    mesh.center = resource.center
    meshes[mesh.id] = resource.mesh
  end
  local wraps = SceneDescriptor.wrapByMaterial(descriptor.materials)
  local imageByKey = {}
  local function resolveImage(path, materialId)
    if path == nil then
      return nil
    end
    local wrap = assert(wraps[materialId], "title material has no sampler wrap")
    local imageKey = table.concat({ path, wrap.x, wrap.y }, "|")
    local image = imageByKey[imageKey]
    if image == nil then
      image = ownedImage(self, path)
      image:setWrap(wrap.x, wrap.y)
      imageByKey[imageKey] = image
    end
    return image
  end
  local instance = ModelInstance.new(definition, { resolveImage = resolveImage })
  instance.renderMeshesById = meshes
  for _, clip in pairs(clips) do
    local boundClip = assert(definition:animation(clip.id), "title definition dropped a validated animation channel")
    local binding = definition:binding(boundClip)
    if next(binding.map) ~= nil then
      instance:play(clip.id, { loopMode = "loop" })
    else
      -- An unbound title material channel plays nothing: retail soulsilver's
      -- sparkle pattern targets a material its untextured mesh does not
      -- carry. Both title scenes (legend and sparkle) may skip such
      -- channels; anything else binding nothing is a corrupt composition.
      local isTitleScene = key == "startup-title:" .. self.versionId
        or key == "startup-title-sparkle:" .. self.versionId
      assert(
        isTitleScene and clip.category == "material" and (clip.kind == "color" or clip.kind == "pattern"),
        "title animation channel has no model binding: " .. clip.id
      )
    end
  end
  instance:evaluatePose()
  return instance
end

local function drawItems(instance)
  local items = instance:drawItems(instance.renderMeshesById)
  for _, item in ipairs(items) do
    item.worldSpace = true
  end
  return items
end

-- First-render state snaps to the sourced end pose with the first waypoint
-- wait loaded; the camera never interpolates toward its destination.
local function initCameraState(self)
  local camera = self.bundle.timeline.camera
  self.cameraPos = { camera.endPosition[1], camera.endPosition[2], camera.endPosition[3] }
  self.cameraPointIndex = 1
  local first = camera.points[1]
  self.cameraWait = math.max(0, math.floor(first.durationSeconds * camera.movement.waitFramesPerSecond + 0.5))
end

-- The sourced stepping rule: hold the pose for the waypoint wait, then move
-- each axis toward the waypoint by the sourced increment per tick, snapping
-- a component that reaches the point. A component closer than one increment
-- snaps directly so hostile spacings cannot oscillate around the target.
local function advanceCamera(self)
  if self.cameraPos == nil or self.cameraPointIndex == nil or self.cameraWait == nil then
    initCameraState(self)
  end
  local camera = self.bundle.timeline.camera
  if self.cameraWait > 0 then
    self.cameraWait = self.cameraWait - 1
    return
  end
  local point = camera.points[self.cameraPointIndex]
  local step = camera.movement.unitsPerFrame
  local tolerance = camera.movement.tolerance
  for axis = 1, 3 do
    local goal = point.position[axis]
    local diff = goal - self.cameraPos[axis]
    if math.abs(diff) <= tolerance or math.abs(diff) <= step then
      self.cameraPos[axis] = goal
    else
      self.cameraPos[axis] = self.cameraPos[axis] + (diff > 0 and step or -step)
    end
  end
  local reached = true
  for axis = 1, 3 do
    if math.abs(point.position[axis] - self.cameraPos[axis]) > tolerance then
      reached = false
      break
    end
  end
  if reached then
    self.cameraPointIndex = self.cameraPointIndex % #camera.points + 1
    local nextPoint = camera.points[self.cameraPointIndex]
    self.cameraWait = math.max(0, math.floor(nextPoint.durationSeconds * camera.movement.waitFramesPerSecond + 0.5))
  end
end

-- The 2D title layer fades in after the sourced delay and completes after
-- the sourced transition; before the delay the layer draws fully
-- transparent rather than popping in.
local function revealAlpha(self)
  local reveal = self.bundle.timeline.titleReveal
  if reveal == nil then
    return 1
  end
  if self.tick < reveal.delayFrames then
    return 0
  end
  if self.tick >= reveal.delayFrames + reveal.durationFrames then
    return 1
  end
  return (self.tick - reveal.delayFrames + 1) / reveal.durationFrames
end

-- The sourced glow breathes rise/hold/fall over its full cycle and rests at
-- zero through the pause; the 2D overlay tone follows it.
local function glowLevel(self)
  local glow = self.bundle.timeline.glow
  if glow == nil then
    return 0
  end
  local cycle = glow.fadeInSteps + glow.fadeOutSteps + glow.pauseFrames
  local phase = self.tick % cycle
  if phase < glow.fadeInSteps then
    return phase / glow.fadeInSteps
  end
  if phase < glow.fadeInSteps + glow.fadeOutSteps then
    return (glow.fadeInSteps + glow.fadeOutSteps - phase) / glow.fadeOutSteps
  end
  return 0
end

-- The start prompt stays hidden through its opening delay, then flashes
-- visible/hidden over its cycle. Visibility is a pure function of the title
-- tick, never of menu readiness.
local function promptVisible(self)
  local flash = self.bundle.prompt.flash
  local elapsed = self.tick - flash.initialDelayFrames
  if elapsed < 0 then
    return false
  end
  if self.proceedRequested then
    return true
  end
  return (elapsed % flash.cycleFrames) < flash.visibleFrames
end

local function overlayTone(self)
  local shade = 1 - 0.5 * glowLevel(self)
  return shade, revealAlpha(self)
end

---@param options { versionId: string, cacheFs: table<string, unknown>, width: number, height: number, graphics?: table<string, unknown>, displayContext?: DisplayContext }
---@return HgssTitleScene
function HgssTitleScene.new(options)
  assert(type(options) == "table", "title scene requires composition options")
  assert(options.versionId == "heartgold" or options.versionId == "soulsilver", "title scene edition is invalid")
  assert(options.cacheFs and type(options.cacheFs.loadLua) == "function", "title scene requires generated cache access")
  local graphics = options.graphics or love.graphics
  local displayContext = options.displayContext or DisplayContext.new({ graphics = graphics })
  local self = setmetatable({
    versionId = options.versionId,
    cacheFs = options.cacheFs,
    graphics = graphics,
    displayContext = displayContext,
    width = options.width,
    height = options.height,
    tick = 0,
    promptFrame = 0,
    proceedRequested = false,
    cameraPos = nil,
    cameraPointIndex = nil,
    cameraWait = nil,
    canvasWidth = nil,
    canvasHeight = nil,
    images = {},
    canvas = nil,
    pool = nil,
    renderer = nil,
    legend = nil,
    sparkle = nil,
    sourceEnvironment = nil,
    disposed = false,
    layout = nil,
    buttonBounds = nil,
  }, HgssTitleScene)
  local ok, failure = pcall(function()
    local bundle = StartupAssetCache.loadTitle(self.cacheFs, self.versionId)
    assert(bundle, "validated title assets are unavailable")
    self.bundle = bundle
    self.pool = GpuAssetPool.new(self.cacheFs, { graphics = graphics })
    self.renderer = FieldRenderer.new({ clearColor = { 0, 0, 0, 0 }, graphics = graphics })
    self.legend = buildModel(self, bundle.model, bundle.clips, "startup-title:" .. self.versionId)
    self.sparkle =
      buildModel(self, bundle.sparkle.model, bundle.sparkle.clips, "startup-title-sparkle:" .. self.versionId)
    self.surfaces = {}
    for role, surface in pairs(bundle.surfaces) do
      self.surfaces[role] = ownedImage(self, surface.image, WIDTH, HEIGHT)
    end
    self.sourceEnvironment = {
      lighting = bundle.lighting,
      edgeColors = TITLE_ENVIRONMENT.edgeColors,
      fog = TITLE_ENVIRONMENT.fog,
    }
    initCameraState(self)
    self:resize(options.width, options.height)
    assert(self.canvas ~= nil, "title canvas allocation failed")
  end)
  if not ok then
    self:dispose()
    error(failure, 0)
  end
  return self
end

-- Records the single accepted title input. The latched flag only holds the
-- start prompt steady for the white-fade handoff; camera, lighting and
-- model animation keep advancing on the source tick.
function HgssTitleScene:beginProceed()
  assert(not self.disposed, "disposed title cannot proceed")
  self.proceedRequested = true
end

function HgssTitleScene:updateFixed()
  assert(not self.disposed, "disposed title cannot advance")
  self.tick = self.tick + 1
  self.promptFrame = math.max(0, self.tick - self.bundle.prompt.flash.initialDelayFrames)
  advanceCamera(self)
  self.legend:updateFixed()
  self.sparkle:updateFixed()
  self.legend:evaluatePose()
  self.sparkle:evaluatePose()
end

function HgssTitleScene:_camera()
  if self.cameraPos == nil then
    initCameraState(self)
  end
  local camera = self.bundle.timeline.camera
  -- The sourced title lens is always the fixed source 4:3 projection:
  -- host shape only repositions the bounded source target, never the lens.
  local aspect = 4 / 3
  local halfAngle = (HALF_ANGLE_INDEX / 65536) * (2 * math.pi)
  local viewMatrix = Matrix4.lookAt(assert(self.cameraPos), camera.target, { 0, 1, 0 })
  local projectionMatrix = Matrix4.perspective(2 * halfAngle, aspect, GPU_NEAR, GPU_FAR)
  local function cameraView()
    return viewMatrix
  end
  local function cameraProjection()
    return projectionMatrix
  end
  return {
    far = GPU_FAR,
    zoom = 1,
    view = cameraView,
    projection = cameraProjection,
    billboardProjection = cameraProjection,
  }
end

function HgssTitleScene:_drawModel()
  local graphics = self.graphics
  graphics.push("all")
  local ok, failure = pcall(function()
    graphics.setCanvas(self.canvas)
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0)
    local environment = self.sourceEnvironment
    if environment == nil then
      environment = {
        lighting = self.bundle.lighting or DEFAULT_TITLE_LIGHTING,
        edgeColors = TITLE_ENVIRONMENT.edgeColors,
        fog = TITLE_ENVIRONMENT.fog,
      }
    end
    local camera = self:_camera()
    local canvasWidth = self.canvasWidth or WIDTH
    local canvasHeight = self.canvasHeight or HEIGHT
    self.renderer:draw(environment, camera, { drawItems(self.legend), drawItems(self.sparkle) }, nil, {
      worldViewport = { x = 0, y = 0, width = canvasWidth, height = canvasHeight },
      referenceFrame = { x = 0, y = 0, width = canvasWidth, height = canvasHeight },
    }, 1)
  end)
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
end

-- Draws the bounded 3D target over the stage with cover composition: the
-- image keeps the sourced projection aspect and any overflow crops against
-- the stage clip below the stage top, never over the accent strip. A
-- sub-pixel cover excess from canvas rounding fits exactly instead, so
-- neighboring art rects stay strictly disjoint.
local function drawStageCanvas(self, stage)
  local graphics = self.graphics
  local canvasWidth = assert(self.canvasWidth, "title canvas dimensions are missing")
  local canvasHeight = assert(self.canvasHeight, "title canvas dimensions are missing")
  local scaleX, scaleY = stage.width / canvasWidth, stage.height / canvasHeight
  local scale = math.max(scaleX, scaleY)
  local drawnWidth, drawnHeight = canvasWidth * scale, canvasHeight * scale
  local x, y, sx, sy = stage.x + (stage.width - drawnWidth) / 2, stage.y, scale, scale
  if drawnWidth - stage.width < 1 and drawnHeight - stage.height < 1 then
    x, y, sx, sy = stage.x, stage.y, scaleX, scaleY
    drawnWidth, drawnHeight = stage.width, stage.height
  end
  LogicalSurface.clip(graphics, stage, function()
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(self.canvas, x, y, 0, sx, sy)
  end)
  return { x = x, y = y, width = drawnWidth, height = drawnHeight }
end

local function drawOverlaySurface(self, clip, image, x, y, scale)
  local graphics = self.graphics
  local shade, alpha = overlayTone(self)
  LogicalSurface.clip(graphics, clip, function()
    graphics.setColor(shade, shade, shade, alpha)
    graphics.draw(image, x, y, 0, scale, scale)
  end)
end

-- Single-screen stages (native-like and wide) keep the sourced 4:3 model
-- target regardless of host shape: the host only cover-composes the fixed
-- target into the 3D stage below the accent strip.
local function stageComposition(safe, canvasHeight)
  local accentScale = 1
  while accentScale > 0.25 and (WIDTH * accentScale > safe.width or HEIGHT * accentScale > safe.height * 0.35) do
    accentScale = accentScale / 2
  end
  local stripHeight = HEIGHT * accentScale
  if safe.height - stripHeight < 1 then
    stripHeight = math.max(0, safe.height - 1)
  end
  local stage = { x = safe.x, y = safe.y + stripHeight, width = safe.width, height = safe.height - stripHeight }
  local accentWidth = WIDTH * accentScale
  local accent = {
    clip = { x = safe.x, y = safe.y, width = safe.width, height = stripHeight },
    x = safe.x + (safe.width - accentWidth) / 2,
    y = safe.y + (stripHeight - HEIGHT * accentScale) / 2,
    scale = accentScale,
  }
  local boundedHeight = math.min(canvasHeight, CANVAS_MAX_HEIGHT)
  local canvasWidth = math.min(CANVAS_MAX_WIDTH, math.max(1, math.floor(boundedHeight * 4 / 3)))
  return {
    stage = stage,
    accent = accent,
    canvasWidth = canvasWidth,
    canvasHeight = boundedHeight,
  }
end

-- Tall host: upper 3D cover over the top half, the edition mark covering
-- the lower half fractionally without edge bars, and the lower art at the
-- largest fitting integer scale top-aligned inside its half. The model
-- target stays the fixed sourced 4:3 shape; only the upper stage rect
-- adapts to the host.
local function tallComposition(safe)
  local upper = { x = safe.x, y = safe.y, width = safe.width, height = safe.height / 2 }
  local lower = { x = safe.x, y = safe.y + safe.height / 2, width = safe.width, height = safe.height / 2 }
  local canvasWidth = math.min(CANVAS_MAX_WIDTH, math.max(1, math.floor(CANVAS_HEIGHT_NATIVE * 4 / 3)))
  local integer = math.floor(math.min(lower.width / WIDTH, lower.height / HEIGHT))
  local artScale, artWidth, artHeight
  if integer >= 1 then
    artScale, artWidth, artHeight = integer, WIDTH * integer, HEIGHT * integer
  else
    artScale = math.min(lower.width / WIDTH, lower.height / HEIGHT)
    artWidth, artHeight = WIDTH * artScale, HEIGHT * artScale
  end
  return {
    upper = upper,
    lower = lower,
    art = {
      scale = artScale,
      x = lower.x + (lower.width - artWidth) / 2,
      y = lower.y,
      width = artWidth,
      height = artHeight,
    },
    canvasWidth = canvasWidth,
    canvasHeight = CANVAS_HEIGHT_NATIVE,
  }
end

function HgssTitleScene:_drawSingleStage(composition)
  drawStageCanvas(self, composition.bounds)
  local accent = composition.accent
  if accent ~= nil and accent.clip.height > 0 then
    drawOverlaySurface(self, accent.clip, assert(self.surfaces).subscreenLower, accent.x, accent.y, accent.scale)
  end
end

function HgssTitleScene:_drawTall()
  local composition = self.layout.composition
  local graphics = self.graphics
  local surfaces = assert(self.surfaces)
  drawStageCanvas(self, composition.upper)
  local lower = composition.lower
  local logoScale = math.max(lower.width / WIDTH, lower.height / HEIGHT)
  local logoWidth, logoHeight = WIDTH * logoScale, HEIGHT * logoScale
  local art = composition.art
  LogicalSurface.clip(graphics, lower, function()
    local shade, alpha = overlayTone(self)
    graphics.setColor(shade, shade, shade, alpha)
    graphics.draw(
      surfaces.editionLogo,
      lower.x + (lower.width - logoWidth) / 2,
      lower.y + (lower.height - logoHeight) / 2,
      0,
      logoScale,
      logoScale
    )
    graphics.setColor(shade, shade, shade, alpha)
    graphics.draw(surfaces.subscreenLower, art.x, art.y, 0, art.scale, art.scale)
  end)
end

function HgssTitleScene:_drawDual()
  local composition = self.layout.composition
  local graphics = self.graphics
  local surfaces = assert(self.surfaces)
  self:_drawSingleStage(composition.principal)
  local auxiliary = composition.auxiliary
  local lower = auxiliary.lower
  local logoScale = math.max(lower.width / WIDTH, lower.height / HEIGHT)
  local logoWidth, logoHeight = WIDTH * logoScale, HEIGHT * logoScale
  local art = auxiliary.art
  LogicalSurface.clip(graphics, lower, function()
    local shade, alpha = overlayTone(self)
    graphics.setColor(shade, shade, shade, alpha)
    graphics.draw(
      surfaces.editionLogo,
      lower.x + (lower.width - logoWidth) / 2,
      lower.y + (lower.height - logoHeight) / 2,
      0,
      logoScale,
      logoScale
    )
    graphics.setColor(shade, shade, shade, alpha)
    graphics.draw(surfaces.subscreenLower, art.x, art.y, 0, art.scale, art.scale)
  end)
end

function HgssTitleScene:_drawUi(status)
  local bounds = assert(self.buttonBounds)
  local graphics = self.graphics
  local color = EDITION_COLORS[self.versionId]
  graphics.push("all")
  graphics.setColor(0.04, 0.08, 0.13, 0.88)
  graphics.circle("fill", bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, bounds.width / 2)
  graphics.setColor(color[1], color[2], color[3], 1)
  graphics.setLineWidth(2)
  graphics.circle("line", bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, bounds.width / 2 - 2)
  graphics.setColor(1, 1, 1, 1)
  graphics.printf(
    EDITION_NAMES[self.versionId],
    bounds.x - 20,
    bounds.y + bounds.height / 2 - 5,
    bounds.width + 40,
    "center"
  )
  -- The prompt tint is the compiled retail text-palette RGB per edition
  -- (src/title_screen.c): HeartGold RGB(27, 8, 0), SoulSilver
  -- RGB(0, 28, 31). The shadow index matches the foreground index, so a
  -- shadow pass reuses this same RGB.
  if promptVisible(self) then
    local promptColor = assert(self.bundle.prompt.color.foregroundRgb, "title prompt ink is missing")
    graphics.setColor(promptColor[1], promptColor[2], promptColor[3], 1)
    local rect = assert(self.layout.prompt)
    graphics.printf(self.bundle.prompt.text, rect.x, rect.y, rect.width, "center")
  end
  -- While the menu stages the title holds its art and prompt with no
  -- staging copy: only a genuine failure earns a line below.
  if status and status.titleError ~= nil then
    graphics.setColor(1, 0.65, 0.5, 1)
    graphics.printf("Title unavailable — Esc to return", 24, self.height - 30, math.max(1, self.width - 48), "center")
  elseif status and (status.menuError ~= nil or status.error ~= nil) then
    graphics.setColor(1, 0.65, 0.5, 1)
    graphics.printf(
      "Menu unavailable — press R to retry",
      24,
      self.height - 30,
      math.max(1, self.width - 48),
      "center"
    )
  end
  graphics.pop()
end

function HgssTitleScene:draw(status)
  if self.disposed then
    return
  end
  self:_drawModel()
  local composition = self.layout.composition
  if composition.configuration == "dualDisplay" then
    self:_drawDual()
  elseif composition.configuration == "tall" then
    self:_drawTall()
  else
    self:_drawSingleStage(composition)
  end
  self:_drawUi(status)
end

-- Rebuilds the bounded 3D target transactionally: the new canvas swaps in
-- only after a successful allocation, so a failed resize keeps the last
-- drawable scene. Source tick, camera and animation state never reset.
-- A failed rebuild keeps the previous canvas and reports nothing: resize
-- has no error channel back through the running state, and the cover draw
-- below keeps the stale target filling the new stage.
local function rebuildCanvas(self, width, height)
  if self.canvas ~= nil and self.canvasWidth == width and self.canvasHeight == height then
    return true
  end
  local ok, canvas = pcall(self.graphics.newCanvas, width, height, {
    format = "rgba8",
    readable = true,
    dpiscale = 1,
  })
  if not ok then
    return false
  end
  if self.canvas ~= nil then
    self.canvas:release()
  end
  self.canvas = canvas
  self.canvasWidth, self.canvasHeight = width, height
  return true
end

function HgssTitleScene:resize(width, height)
  assert(width > 0 and height > 0, "title dimensions must be positive")
  self.width, self.height = width, height
  local measurement = self.displayContext:measure(width, height)
  local configuration = ApplicationLayout.classify(measurement, self.layout and self.layout.configuration)
  local selected = ApplicationLayout.selectSurfaces(measurement)
  local primary = selected.primary.usableBounds
  local secondary = selected.secondary and selected.secondary.usableBounds or nil
  local main = primary
  if configuration == "dualDisplay" and secondary == nil then
    configuration = "nativeLike"
  end
  if configuration == "wide" or configuration == "tall" then
    main = primary
  end
  assert(main ~= nil, "title display has no unoccupied safe area")
  local buttonSize = math.max(28, math.min(56, math.floor(math.min(main.width, main.height) * 0.12)))
  local buttonBounds = {
    x = self.versionId == "heartgold" and main.x + main.width - buttonSize - 2 or main.x + 2,
    y = main.y + main.height - buttonSize - 2,
    width = buttonSize,
    height = buttonSize,
  }
  local prompt = {
    x = main.x + main.width * 0.2,
    y = main.y + main.height * 0.82,
    width = main.width * 0.6,
    height = 30,
  }
  local composition
  if configuration == "dualDisplay" then
    local principal = stageComposition(primary, CANVAS_HEIGHT_NATIVE)
    local auxiliary = tallComposition(assert(secondary))
    composition = {
      configuration = configuration,
      bounds = principal.stage,
      stageWidth = principal.stage.width,
      stageHeight = principal.stage.height,
      principal = {
        configuration = configuration,
        bounds = principal.stage,
        stageWidth = principal.stage.width,
        stageHeight = principal.stage.height,
        accent = principal.accent,
      },
      auxiliary = auxiliary,
      accent = principal.accent,
      lowerPanel = false,
    }
    rebuildCanvas(self, principal.canvasWidth, principal.canvasHeight)
  elseif configuration == "tall" then
    local tall = tallComposition(main)
    composition = {
      configuration = configuration,
      bounds = { x = main.x, y = main.y, width = main.width, height = main.height },
      stageWidth = main.width,
      stageHeight = main.height,
      upper = tall.upper,
      lower = tall.lower,
      art = tall.art,
      lowerPanel = true,
    }
    rebuildCanvas(self, tall.canvasWidth, tall.canvasHeight)
  else
    local canvasHeight = configuration == "wide" and CANVAS_HEIGHT_WIDE or CANVAS_HEIGHT_NATIVE
    local staged = stageComposition(main, canvasHeight)
    composition = {
      configuration = configuration,
      bounds = staged.stage,
      stageWidth = staged.stage.width,
      stageHeight = staged.stage.height,
      accent = staged.accent,
      lowerPanel = false,
    }
    rebuildCanvas(self, staged.canvasWidth, staged.canvasHeight)
  end
  self.layout = {
    configuration = configuration,
    composition = composition,
    primary = primary,
    secondary = secondary,
    main = main,
    prompt = prompt,
    safe = main,
  }
  self.buttonBounds = buttonBounds
end

function HgssTitleScene:editionButtonBounds()
  local bounds = assert(self.buttonBounds)
  return { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height }
end

function HgssTitleScene:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local images, pool, renderer, canvas = self.images, self.pool, self.renderer, self.canvas
  self.images, self.pool, self.renderer, self.canvas = {}, nil, nil, nil
  self.legend, self.sparkle, self.surfaces, self.bundle, self.sourceEnvironment = nil, nil, nil, nil, nil
  for _, image in ipairs(images) do
    image:release()
  end
  if canvas ~= nil then
    canvas:release()
  end
  if pool ~= nil then
    pool:release()
  end
  if renderer ~= nil then
    renderer:release()
  end
end

return HgssTitleScene
