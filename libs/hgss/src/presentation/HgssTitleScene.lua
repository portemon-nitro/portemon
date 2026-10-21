-- Renders the generated HGSS title through the existing Nitro model renderer.

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
---@field images love.Image[]
---@field canvas love.Canvas?
---@field pool GpuAssetPool?
---@field renderer FieldRenderer?
---@field legend ModelInstance?
---@field sparkle ModelInstance?
---@field bundle table<string, unknown>
---@field surfaces table<string, love.Image>?
---@field disposed boolean
---@field layout table<string, unknown>?
---@field buttonBounds { x: number, y: number, width: number, height: number }?
local HgssTitleScene = {}
HgssTitleScene.__index = HgssTitleScene

local WIDTH, HEIGHT = 256, 192
local FRAME_SECONDS = 1 / 30
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
      assert(
        key == "startup-title:" .. self.versionId
          and clip.category == "material"
          and (clip.kind == "color" or clip.kind == "pattern"),
        "title animation channel has no model binding: " .. clip.id
      )
    end
  end
  instance:evaluatePose()
  return instance
end

local function interpolate(a, b, amount)
  return {
    a[1] + (b[1] - a[1]) * amount,
    a[2] + (b[2] - a[2]) * amount,
    a[3] + (b[3] - a[3]) * amount,
  }
end

local function cameraPosition(timeline, seconds)
  local camera = timeline.camera
  local elapsed = seconds
  local previous = camera.start.position
  for _, point in ipairs(camera.points) do
    if elapsed <= point.durationSeconds then
      return interpolate(previous, point.position, elapsed / point.durationSeconds)
    end
    elapsed = elapsed - point.durationSeconds
    previous = point.position
  end
  return camera.endPosition
end

local function drawItems(instance)
  local items = instance:drawItems(assert(instance.renderMeshesById))
  for _, item in ipairs(items) do
    item.worldSpace = true
  end
  return items
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
    images = {},
    canvas = nil,
    pool = nil,
    renderer = nil,
    legend = nil,
    sparkle = nil,
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
    self.canvas = graphics.newCanvas(WIDTH, HEIGHT, { format = "rgba8", readable = true, dpiscale = 1 })
    self:resize(options.width, options.height)
  end)
  if not ok then
    self:dispose()
    error(failure, 0)
  end
  return self
end

function HgssTitleScene:updateFixed()
  assert(not self.disposed, "disposed title cannot advance")
  self.tick = self.tick + 1
  self.promptFrame = math.max(0, self.tick - self.bundle.prompt.flash.initialDelayFrames)
  self.legend:updateFixed()
  self.sparkle:updateFixed()
  self.legend:evaluatePose()
  self.sparkle:evaluatePose()
end

function HgssTitleScene:_camera()
  local source = self.bundle.timeline.camera
  local eye = cameraPosition(self.bundle.timeline, self.tick * FRAME_SECONDS)
  local startTarget = source.start.target
  local target = source.target
  local blend = math.min(1, self.tick / (30 * 30))
  local center = interpolate(startTarget, target, blend)
  local viewMatrix = Matrix4.lookAt(eye, center, { 0, 1, 0 })
  local projectionMatrix = Matrix4.perspective(math.rad(42), WIDTH / HEIGHT, 1, 5000)
  local function cameraView()
    return viewMatrix
  end
  local function cameraProjection()
    return projectionMatrix
  end
  return {
    far = 5000,
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
    local camera = self:_camera()
    self.renderer:draw(TITLE_ENVIRONMENT, camera, { drawItems(self.legend), drawItems(self.sparkle) }, nil, {
      worldViewport = { x = 0, y = 0, width = WIDTH, height = HEIGHT },
      referenceFrame = { x = 0, y = 0, width = WIDTH, height = HEIGHT },
    }, 1)
  end)
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
end

function HgssTitleScene:_stageBounds()
  local layout = assert(self.layout)
  if layout.configuration == "dualDisplay" then
    return layout.primary
  end
  return layout.main
end

function HgssTitleScene:_drawSingle(
  bounds,
  stageWidth,
  stageHeight,
  modelX,
  lowerX,
  lowerY,
  lowerScale,
  drawSubscreenLayers
)
  local graphics = self.graphics
  local scale = math.max(0.25, math.min(bounds.width / stageWidth, bounds.height / stageHeight))
  if scale >= 1 then
    scale = math.floor(scale)
  end
  local x = math.floor(bounds.x + (bounds.width - stageWidth * scale) / 2)
  local y = math.floor(bounds.y + (bounds.height - stageHeight * scale) / 2)
  local function drawSurface(surface, sx, sy, surfaceScale)
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(surface, x + sx * scale, y + sy * scale, 0, surfaceScale * scale, surfaceScale * scale)
  end
  LogicalSurface.clip(graphics, bounds, function()
    if drawSubscreenLayers and self.surfaces.editionLogo ~= nil then
      drawSurface(self.surfaces.editionLogo, lowerX, lowerY, lowerScale)
    end
    if drawSubscreenLayers and self.surfaces.subscreenDecor ~= nil then
      drawSurface(self.surfaces.subscreenDecor, lowerX, lowerY, lowerScale)
    end
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(self.canvas, x + modelX * scale, y, 0, scale, scale)
    if drawSubscreenLayers then
      drawSurface(self.surfaces.subscreenLower, lowerX, lowerY, lowerScale)
    end
  end)
  return { x = x, y = y, scale = scale, width = stageWidth * scale, height = stageHeight * scale }
end

function HgssTitleScene:_drawDual()
  local layout = assert(self.layout)
  local primary, auxiliary = layout.primary, layout.secondary
  if primary ~= nil then
    self:_drawSingle(primary, WIDTH, HEIGHT, 0, 0, 0, 1, false)
  end
  if auxiliary ~= nil then
    local graphics = self.graphics
    local scale = math.max(0.25, math.min(auxiliary.width / WIDTH, auxiliary.height / HEIGHT))
    if scale >= 1 then
      scale = math.floor(scale)
    end
    local x = auxiliary.x + (auxiliary.width - WIDTH * scale) / 2
    local y = auxiliary.y + (auxiliary.height - HEIGHT * scale) / 2
    LogicalSurface.clip(graphics, auxiliary, function()
      graphics.setColor(1, 1, 1, 1)
      graphics.draw(self.surfaces.editionLogo, x, y, 0, scale, scale)
      graphics.draw(self.surfaces.subscreenDecor, x, y, 0, scale, scale)
      graphics.draw(self.surfaces.subscreenLower, x, y, 0, scale, scale)
    end)
  end
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
  local flash = self.bundle.prompt.flash
  local promptVisible = self.tick < flash.initialDelayFrames
    or self.promptFrame % flash.cycleFrames < flash.visibleFrames
  if promptVisible then
    local colorIndex = self.bundle.prompt.color.foreground
    local promptColor = colorIndex == 1 and { 1, 0.82, 0.42 } or { 0.55, 0.82, 1 }
    graphics.setColor(promptColor[1], promptColor[2], promptColor[3], 1)
    local rect = assert(self.layout.prompt)
    graphics.printf(self.bundle.prompt.text, rect.x, rect.y, rect.width, "center")
  end
  if status and status.preparingMenu then
    local rect = assert(self.layout.prompt)
    graphics.setColor(0.87, 0.9, 0.92, 0.9)
    graphics.printf("Preparing menu…", rect.x, rect.y + 24, rect.width, "center")
  end
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
  else
    self:_drawSingle(
      composition.bounds,
      composition.stageWidth,
      composition.stageHeight,
      composition.legend.x,
      composition.lower.x,
      composition.lower.y,
      1,
      true
    )
  end
  self:_drawUi(status)
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
    composition = {
      configuration = configuration,
      bounds = main,
      stageWidth = WIDTH,
      stageHeight = HEIGHT,
      legend = { x = 0, y = 0, width = WIDTH, height = HEIGHT },
      lower = secondary and { x = 0, y = 0, width = WIDTH, height = HEIGHT } or nil,
      lowerPanel = false,
    }
  elseif configuration == "wide" then
    composition = {
      configuration = configuration,
      bounds = main,
      stageWidth = WIDTH * 2,
      stageHeight = HEIGHT,
      legend = { x = WIDTH, y = 0, width = WIDTH, height = HEIGHT },
      lower = { x = 0, y = 0, width = WIDTH, height = HEIGHT },
      lowerPanel = true,
    }
  elseif configuration == "tall" then
    composition = {
      configuration = configuration,
      bounds = main,
      stageWidth = WIDTH,
      stageHeight = HEIGHT * 2,
      legend = { x = 0, y = 0, width = WIDTH, height = HEIGHT },
      lower = { x = 0, y = HEIGHT, width = WIDTH, height = HEIGHT },
      lowerPanel = true,
    }
  else
    composition = {
      configuration = configuration,
      bounds = main,
      stageWidth = WIDTH,
      stageHeight = HEIGHT,
      legend = { x = 0, y = 0, width = WIDTH, height = HEIGHT },
      lower = { x = 0, y = 0, width = WIDTH, height = HEIGHT },
      lowerPanel = false,
    }
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
  self.legend, self.sparkle, self.surfaces, self.bundle = nil, nil, nil, nil
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
