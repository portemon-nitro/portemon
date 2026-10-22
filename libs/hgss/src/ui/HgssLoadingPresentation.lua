-- Shared ROM-independent loading art with optional verified walking sprites.

local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

local HgssLoadingPresentation = {}
HgssLoadingPresentation.__index = HgssLoadingPresentation

-- Edition stage themes. The generated backdrop is neutral gray so this runtime
-- tint is the only edition color policy; hero and follower pixels stay untinted.
local THEMES = {
  heartgold = {
    skyTop = { 0.30, 0.17, 0.08, 1 },
    skyBottom = { 0.58, 0.40, 0.20, 1 },
    ground = { 0.40, 0.27, 0.13, 1 },
    spark = { 1.0, 0.88, 0.60, 0.55 },
    mark = { 0.86, 0.66, 0.36, 0.8 },
    accent = { 0.93, 0.71, 0.35, 1 },
    caption = { 0.99, 0.95, 0.86, 1 },
    backdropTint = { 1.0, 0.93, 0.78, 1 },
  },
  soulsilver = {
    skyTop = { 0.07, 0.13, 0.21, 1 },
    skyBottom = { 0.26, 0.39, 0.51, 1 },
    ground = { 0.19, 0.27, 0.34, 1 },
    spark = { 0.80, 0.90, 1.0, 0.55 },
    mark = { 0.62, 0.74, 0.85, 0.8 },
    accent = { 0.73, 0.85, 0.95, 1 },
    caption = { 0.92, 0.96, 1.0, 1 },
    backdropTint = { 0.88, 0.95, 1.0, 1 },
  },
  neutral = {
    skyTop = { 0.10, 0.13, 0.15, 1 },
    skyBottom = { 0.26, 0.31, 0.33, 1 },
    ground = { 0.19, 0.23, 0.24, 1 },
    spark = { 0.82, 0.86, 0.84, 0.55 },
    mark = { 0.60, 0.66, 0.64, 0.8 },
    accent = { 0.78, 0.82, 0.80, 1 },
    caption = { 0.94, 0.95, 0.93, 1 },
    backdropTint = { 1, 1, 1, 1 },
  },
}
local SKY_BANDS = 4
local CAPTIONS = {
  "Enraging the lake…",
  "Poisoning Amphy…",
  "Reviving Team Rocket…",
  "Delivering the SecretPotion…",
  "Waking Snorlax…",
  "Polishing Poké Balls…",
  "Calling Professor Elm…",
}
local CAPTION_SECONDS = 4
local CAPTION_TRANSITION_SECONDS = 0.4
local FRAME_SECONDS = 1 / 30
local STAGE_WIDTH, STAGE_HEIGHT = 256, 192
local GROUND_DASHES = {
  { x = 18, y = 159, width = 13 },
  { x = 61, y = 168, width = 9 },
  { x = 104, y = 157, width = 12 },
  { x = 153, y = 166, width = 10 },
  { x = 204, y = 158, width = 14 },
}
local SKY_SPARKS = {
  { x = 30, y = 44 },
  { x = 84, y = 31 },
  { x = 145, y = 52 },
  { x = 219, y = 35 },
}

---@class HgssLoadingSprite
---@field speciesId integer?
---@field visual { pivot: { x: number, y: number }, directions: { east: { walk: { frames: { frameIndex: integer, ticks: integer }[] } } }, render: { frameWidth: integer, frameHeight: integer, frameCount: integer } }
---@field image love.Image
---@field quads table<integer, love.Quad>

---@class HgssLoadingPresentation
---@field versionId string?
---@field pairIndex integer?
---@field width number
---@field height number
---@field graphics love.graphics
---@field random fun(): number
---@field displayContext DisplayContext
---@field configuration string
---@field primaryBounds { x: number, y: number, width: number, height: number }?
---@field secondaryBounds { x: number, y: number, width: number, height: number }?
---@field elapsed number
---@field captionBase integer
---@field captionIndex integer
---@field hero HgssLoadingSprite?
---@field heroId "ethan"|"lyra"?
---@field follower HgssLoadingSprite?
---@field artFailure unknown?
---@field disposed boolean
---@class HgssLoadingPresentation.Options
---@field width number
---@field height number
---@field versionId string?
---@field pairIndex integer?
---@field graphics love.graphics?
---@field random (fun(): number)?
---@field displayContext DisplayContext?
local function requireDimensions(width, height)
  assert(type(width) == "number" and width > 0, "loading presentation width must be positive")
  assert(type(height) == "number" and height > 0, "loading presentation height must be positive")
end

local function chooseFrame(visual, elapsed)
  local walk = assert(visual.directions.east.walk)
  local totalTicks = 0
  for _, frame in ipairs(walk.frames) do
    totalTicks = totalTicks + frame.ticks
  end
  local tick = math.floor(elapsed / FRAME_SECONDS) % totalTicks
  for _, frame in ipairs(walk.frames) do
    if tick < frame.ticks then
      return frame.frameIndex
    end
    tick = tick - frame.ticks
  end
  error("walk animation ticks do not resolve a frame", 0)
end

---@param random fun(): number
---@return integer
local function chooseCaption(random)
  local value = random()
  assert(type(value) == "number" and value >= 0 and value < 1, "loading random source must return [0,1)")
  return math.floor(value * #CAPTIONS) + 1
end

---@param options HgssLoadingPresentation.Options
---@return HgssLoadingPresentation
function HgssLoadingPresentation.new(options)
  assert(type(options) == "table", "loading presentation requires options")
  -- A legacy purpose key is accepted and ignored; the selected edition and
  -- generated asset readiness drive the visuals.
  requireDimensions(options.width, options.height)
  if options.pairIndex ~= nil then
    assert(
      type(options.pairIndex) == "number"
        and options.pairIndex % 1 == 0
        and options.pairIndex >= 1
        and options.pairIndex <= 32,
      "walking pair index must be an integer 1..32"
    )
  end
  local random = options.random or love.math.random
  assert(type(random) == "function", "loading presentation requires a random source")
  local graphics = options.graphics or love.graphics
  local displayContext = options.displayContext or DisplayContext.new({ graphics = graphics })
  local firstCaption = chooseCaption(random)
  local self = setmetatable({
    versionId = options.versionId,
    pairIndex = options.pairIndex,
    width = options.width,
    height = options.height,
    graphics = graphics,
    displayContext = displayContext,
    random = random,
    elapsed = 0,
    captionBase = firstCaption,
    captionIndex = firstCaption,
    hero = nil,
    heroId = nil,
    follower = nil,
    artFailure = nil,
    disposed = false,
  }, HgssLoadingPresentation)
  self:resize(options.width, options.height)
  return self
end

function HgssLoadingPresentation:_frameIndex(subject)
  local sprite
  if subject == "hero" then
    sprite = self.hero
  elseif subject == "follower" then
    sprite = self.follower
  else
    error("unknown loading sprite " .. tostring(subject), 0)
  end
  if sprite == nil then
    return nil
  end
  return chooseFrame(sprite.visual, self.elapsed)
end

function HgssLoadingPresentation:_loadImage(cacheFs, path)
  local bytes = assert(cacheFs:read(path), "generated loading image is missing: " .. path)
  local fileData = love.filesystem.newFileData(bytes, path)
  return self.graphics.newImage(fileData)
end

function HgssLoadingPresentation:adoptGeneratedAssets(cacheFs)
  assert(not self.disposed, "disposed loading presentation cannot adopt art")
  if self.hero ~= nil then
    return true
  end
  if self.pairIndex == nil then
    local missing = "walking pair selection is unavailable"
    self.artFailure = missing
    return false, missing
  end
  local manifest, manifestError = StartupAssetCache.loadWalker(cacheFs, self.pairIndex)
  if manifest == nil then
    self.artFailure = manifestError
    return false, manifestError
  end
  if self.versionId == nil or manifest.versionId ~= self.versionId then
    local mismatch = "selected-version loader assets are unavailable"
    self.artFailure = mismatch
    return false, mismatch
  end
  local hero = manifest.hero
  local follower = manifest.follower
  local staged = {}
  local ok, result = pcall(function()
    local heroImage = self:_loadImage(cacheFs, hero.atlasPath)
    staged[#staged + 1] = heroImage
    heroImage:setFilter("nearest", "nearest")
    local followerImage = self:_loadImage(cacheFs, follower.atlasPath)
    staged[#staged + 1] = followerImage
    followerImage:setFilter("nearest", "nearest")
    local function frames(image, visual)
      local render = visual.render
      assert(image:getWidth() >= render.frameWidth * render.frameCount, "loading atlas is narrower than its frame list")
      assert(image:getHeight() >= render.frameHeight, "loading atlas is shorter than its frame height")
      local quads = {}
      for frameIndex = 1, render.frameCount do
        quads[frameIndex] = self.graphics.newQuad(
          (frameIndex - 1) * render.frameWidth,
          0,
          render.frameWidth,
          render.frameHeight,
          image:getWidth(),
          image:getHeight()
        )
      end
      return quads
    end
    return {
      heroImage = heroImage,
      heroQuads = frames(heroImage, hero.visual),
      followerImage = followerImage,
      followerQuads = frames(followerImage, follower.visual),
    }
  end)
  if not ok then
    for _, image in ipairs(staged) do
      pcall(image.release, image)
    end
    self.artFailure = result
    return false, result
  end
  local choice = StartupAssetCache.walkerChoice(self.pairIndex)
  self.heroId = choice.heroId
  self.hero = { visual = hero.visual, image = result.heroImage, quads = result.heroQuads }
  self.follower = {
    speciesId = follower.speciesId,
    visual = follower.visual,
    image = result.followerImage,
    quads = result.followerQuads,
  }
  self.artFailure = nil
  return true
end

function HgssLoadingPresentation:update(dt)
  if self.disposed then
    return
  end
  assert(type(dt) == "number" and dt >= 0, "loading presentation dt must be non-negative")
  self.elapsed = self.elapsed + dt
  self.captionIndex = ((self.captionBase - 1 + math.floor(self.elapsed / CAPTION_SECONDS)) % #CAPTIONS) + 1
end

function HgssLoadingPresentation:_theme()
  if self.versionId == "heartgold" then
    return THEMES.heartgold
  elseif self.versionId == "soulsilver" then
    return THEMES.soulsilver
  end
  return THEMES.neutral
end

local function blendChannel(top, bottom, t)
  return top + (bottom - top) * t
end

-- One full-bleed animated stage shared before and after generated art arrives,
-- so adopting the walking pair never recomposes the scene.
function HgssLoadingPresentation:_drawStage()
  local graphics = self.graphics
  local theme = self:_theme()
  local width, height = self.width, self.height
  graphics.setColor(theme.skyTop[1], theme.skyTop[2], theme.skyTop[3], theme.skyTop[4])
  graphics.rectangle("fill", 0, 0, width, height)
  local horizon = height * 0.62
  for band = 1, SKY_BANDS do
    local t = (band - 0.5) / SKY_BANDS
    graphics.setColor(
      blendChannel(theme.skyTop[1], theme.skyBottom[1], t),
      blendChannel(theme.skyTop[2], theme.skyBottom[2], t),
      blendChannel(theme.skyTop[3], theme.skyBottom[3], t),
      1
    )
    graphics.rectangle("fill", 0, horizon * (band - 1) / SKY_BANDS, width, horizon / SKY_BANDS + 1)
  end
  graphics.setColor(theme.ground[1], theme.ground[2], theme.ground[3], theme.ground[4])
  graphics.rectangle("fill", 0, horizon, width, height - horizon)
  local skyOffset = (self.elapsed * 5) % 272
  graphics.setColor(theme.spark[1], theme.spark[2], theme.spark[3], theme.spark[4])
  for _, spark in ipairs(SKY_SPARKS) do
    local x = ((spark.x / STAGE_WIDTH) * width - skyOffset) % (width + 16) - 8
    graphics.rectangle("fill", x, (spark.y / STAGE_HEIGHT) * height, 2, 2)
  end
  local dashOffset = (self.elapsed * 20) % 288
  graphics.setColor(theme.mark[1], theme.mark[2], theme.mark[3], theme.mark[4])
  for _, dash in ipairs(GROUND_DASHES) do
    local x = ((dash.x / STAGE_WIDTH) * width - dashOffset) % (width + 32) - 16
    graphics.rectangle("fill", x, (dash.y / STAGE_HEIGHT) * height, math.max(2, (dash.width / STAGE_WIDTH) * width), 2)
  end
end

function HgssLoadingPresentation:_drawCopy(status)
  local graphics = self.graphics
  local theme = self:_theme()
  local bounds = self.secondaryBounds or self.primaryBounds
  if bounds == nil then
    return
  end
  local x, y, width, height = bounds.x, bounds.y, bounds.width, bounds.height
  local caption = theme.caption
  local cycle = self.elapsed % CAPTION_SECONDS
  local fade = (cycle - (CAPTION_SECONDS - CAPTION_TRANSITION_SECONDS)) / CAPTION_TRANSITION_SECONDS
  fade = math.max(0, math.min(1, fade))
  local nextCaption = self.captionIndex % #CAPTIONS + 1
  local slide = 5 * fade
  local captionY = self.configuration == "tall" and 0.78 or 0.75
  graphics.setColor(caption[1], caption[2], caption[3], 1 - fade)
  graphics.printf(CAPTIONS[self.captionIndex], x + width * 0.08, y + height * captionY - slide, width * 0.84, "center")
  if fade > 0 then
    graphics.setColor(caption[1], caption[2], caption[3], fade)
    graphics.printf(
      CAPTIONS[nextCaption],
      x + width * 0.08,
      y + height * captionY + 5 * (1 - fade),
      width * 0.84,
      "center"
    )
  end
  if status ~= nil then
    local label = type(status) == "string" and status or status.label or status.message
    local detail = type(status) == "table" and status.detail or nil
    local errorText = type(status) == "table" and status.error or nil
    if type(label) == "string" and label ~= "" then
      graphics.setColor(0.72, 0.81, 0.83, 1)
      graphics.printf(
        label,
        x + width * 0.08,
        y + height * (self.configuration == "tall" and 0.87 or 0.84),
        width * 0.84,
        "center"
      )
    end
    if type(detail) == "string" and detail ~= "" then
      graphics.setColor(0.63, 0.74, 0.77, 1)
      graphics.printf(
        detail,
        x + width * 0.08,
        y + height * (self.configuration == "tall" and 0.91 or 0.89),
        width * 0.84,
        "center"
      )
    end
    if type(errorText) == "string" and errorText ~= "" then
      graphics.setColor(1, 0.67, 0.53, 1)
      graphics.printf(errorText, x + width * 0.04, y + height * 0.95, width * 0.92, "center")
    end
    if type(status) == "table" and type(status.fraction) == "number" then
      assert(status.fraction >= 0 and status.fraction <= 1, "loading status fraction must be in [0,1]")
      graphics.setColor(theme.accent[1], theme.accent[2], theme.accent[3], 1)
      graphics.rectangle("fill", x + width * 0.2, y + height * 0.975, width * 0.6 * status.fraction, 2)
    end
  end
  -- An optional art failure never becomes stage copy: the fallback scene stays
  -- usable and the diagnostic travels through the adoption return value.
end

-- Shared ground-plane foot baseline in stage space: both sprites rest on
-- the same line, with each top-left derived from its source pivot so
-- differently sized atlases stay aligned. The follower walks behind the
-- hero at a separate horizontal anchor.
local GROUND_STAGE_Y = 150
local FOLLOWER_CENTER_X = 97
local HERO_CENTER_X = 133

function HgssLoadingPresentation:draw(status)
  local maybeBounds = self.primaryBounds
  if self.disposed or maybeBounds == nil then
    return
  end
  self:_drawStage()
  if self.hero ~= nil then
    local graphics = self.graphics
    local bounds = maybeBounds
    local stageHeight = self.configuration == "tall" and bounds.height * 0.66 or bounds.height
    local scale = math.max(1, math.floor(math.min(bounds.width / STAGE_WIDTH, stageHeight / STAGE_HEIGHT)))
    local originX = math.floor(bounds.x + (bounds.width - STAGE_WIDTH * scale) / 2)
    local originY = math.floor(bounds.y + (stageHeight - STAGE_HEIGHT * scale) / 2)
    LogicalSurface.clip(graphics, bounds, function()
      local followerFrame = self:_frameIndex("follower")
      local heroFrame = self:_frameIndex("hero")
      graphics.setColor(1, 1, 1, 1)
      local function drawSprite(sprite, frameIndex, centerX)
        local quad = assert(sprite.quads[frameIndex])
        local pivot = sprite.visual.pivot or { x = 0.5, y = 1 }
        local topLeftX = centerX - sprite.visual.render.frameWidth * pivot.x
        local topLeftY = GROUND_STAGE_Y - sprite.visual.render.frameHeight * pivot.y
        graphics.draw(sprite.image, quad, originX + topLeftX * scale, originY + topLeftY * scale, 0, scale, scale)
      end
      drawSprite(self.follower, followerFrame, FOLLOWER_CENTER_X)
      drawSprite(self.hero, heroFrame, HERO_CENTER_X)
    end)
  end
  self:_drawCopy(status)
end

function HgssLoadingPresentation:resize(width, height)
  requireDimensions(width, height)
  self.width, self.height = width, height
  local measurement = self.displayContext:measure(width, height)
  self.configuration = ApplicationLayout.classify(measurement)
  local selected = ApplicationLayout.selectSurfaces(measurement)
  self.primaryBounds = selected.primary.usableBounds
  self.secondaryBounds = selected.secondary and selected.secondary.usableBounds or nil
end

function HgssLoadingPresentation:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local images = { self.hero and self.hero.image, self.follower and self.follower.image }
  self.hero, self.follower, self.heroId = nil, nil, nil
  for _, image in ipairs(images) do
    if image ~= nil then
      image:release()
    end
  end
end

return HgssLoadingPresentation
