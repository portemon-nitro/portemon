-- Shared ROM-independent loading art with optional verified walking sprites.

local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

local HgssLoadingPresentation = {}
HgssLoadingPresentation.__index = HgssLoadingPresentation

local PURPOSES = { import = true, startup = true, continue = true, editor = true }
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
---@field visual { directions: { east: { walk: { frames: { frameIndex: integer, ticks: integer }[] } } }, render: { frameWidth: integer, frameHeight: integer, frameCount: integer } }
---@field image love.Image
---@field quads table<integer, love.Quad>

---@class HgssLoadingPresentation
---@field purpose string
---@field versionId string?
---@field width number
---@field height number
---@field graphics love.graphics
---@field random fun(): number
---@field displayContext DisplayContext
---@field configuration string
---@field primaryBounds { x: number, y: number, width: number, height: number }?
---@field secondaryBounds { x: number, y: number, width: number, height: number }?
---@field elapsed number
---@field captionIndex integer
---@field hero HgssLoadingSprite?
---@field heroId "ethan"|"lyra"?
---@field follower HgssLoadingSprite?
---@field backdrop love.Image?
---@field backdropQuad love.Quad?
---@field artFailure unknown?
---@field disposed boolean
---@class HgssLoadingPresentation.Options
---@field purpose "import"|"startup"|"continue"|"editor"
---@field width number
---@field height number
---@field versionId string?
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

---@param options HgssLoadingPresentation.Options
---@return HgssLoadingPresentation
function HgssLoadingPresentation.new(options)
  assert(type(options) == "table", "loading presentation requires options")
  assert(PURPOSES[options.purpose], "loading presentation purpose is invalid")
  requireDimensions(options.width, options.height)
  local random = options.random or love.math.random
  assert(type(random) == "function", "loading presentation requires a random source")
  local graphics = options.graphics or love.graphics
  local displayContext = options.displayContext or DisplayContext.new({ graphics = graphics })
  local self = setmetatable({
    purpose = options.purpose,
    versionId = options.versionId,
    width = options.width,
    height = options.height,
    graphics = graphics,
    displayContext = displayContext,
    random = random,
    elapsed = 0,
    captionIndex = 1,
    hero = nil,
    heroId = nil,
    follower = nil,
    backdrop = nil,
    backdropQuad = nil,
    heroQuad = nil,
    followerQuad = nil,
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
  local manifest, manifestError = StartupAssetCache.loadLoader(cacheFs)
  if manifest == nil then
    self.artFailure = manifestError
    return false, manifestError
  end
  if self.versionId == nil or manifest.versionId ~= self.versionId then
    local mismatch = "selected-version loader assets are unavailable"
    self.artFailure = mismatch
    return false, mismatch
  end
  local function choose(count)
    local value = self.random()
    assert(type(value) == "number" and value >= 0 and value < 1, "loading random source must return [0,1)")
    return math.floor(value * count) + 1
  end
  local heroId = ({ "ethan", "lyra" })[choose(2)]
  local followerIndex = choose(#manifest.followers)
  local hero = assert(manifest.heroes[heroId])
  local follower = assert(manifest.followers[followerIndex])
  local staged = {}
  local ok, result = pcall(function()
    local backdrop = self:_loadImage(cacheFs, manifest.backdrop.image)
    staged[#staged + 1] = backdrop
    backdrop:setFilter("nearest", "nearest")
    local heroImage = self:_loadImage(cacheFs, hero.atlasPath)
    staged[#staged + 1] = heroImage
    heroImage:setFilter("nearest", "nearest")
    local followerImage = self:_loadImage(cacheFs, follower.atlasPath)
    staged[#staged + 1] = followerImage
    followerImage:setFilter("nearest", "nearest")
    assert(
      backdrop:getWidth() >= 256 and backdrop:getHeight() >= 192,
      "loading backdrop is smaller than its source frame"
    )
    local backdropQuad = self.graphics.newQuad(0, 0, 256, 192, backdrop:getWidth(), backdrop:getHeight())
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
      backdrop = backdrop,
      backdropQuad = backdropQuad,
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
  self.backdrop = result.backdrop
  self.backdropQuad = result.backdropQuad
  self.heroId = heroId
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
  self.elapsed = self.elapsed + math.min(dt, 1)
  self.captionIndex = (math.floor(self.elapsed / CAPTION_SECONDS) % #CAPTIONS) + 1
end

function HgssLoadingPresentation:_drawCopy(status, drawBackdrop)
  local graphics = self.graphics
  local bounds = self.secondaryBounds or self.primaryBounds
  if bounds == nil then
    return
  end
  local x, y, width, height = bounds.x, bounds.y, bounds.width, bounds.height
  if drawBackdrop then
    graphics.setColor(0.035, 0.075, 0.12, 1)
    graphics.rectangle("fill", 0, 0, self.width, self.height)
    graphics.setColor(0.08, 0.19, 0.24, 1)
    graphics.rectangle("fill", x + width * 0.12, y + height * 0.2, width * 0.76, height * 0.42, 20, 20)
    graphics.setColor(0.89, 0.71, 0.39, 0.8)
    graphics.rectangle("line", x + width * 0.12, y + height * 0.2, width * 0.76, height * 0.42, 20, 20)
  end
  local cycle = self.elapsed % CAPTION_SECONDS
  local fade = (cycle - (CAPTION_SECONDS - CAPTION_TRANSITION_SECONDS)) / CAPTION_TRANSITION_SECONDS
  fade = math.max(0, math.min(1, fade))
  local nextCaption = self.captionIndex % #CAPTIONS + 1
  local slide = 5 * fade
  local captionY = self.configuration == "tall" and 0.78 or 0.75
  graphics.setColor(0.95, 0.94, 0.86, 1 - fade)
  graphics.printf(CAPTIONS[self.captionIndex], x + width * 0.08, y + height * captionY - slide, width * 0.84, "center")
  if fade > 0 then
    graphics.setColor(0.95, 0.94, 0.86, fade)
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
      graphics.setColor(0.89, 0.71, 0.39, 1)
      graphics.rectangle("fill", x + width * 0.2, y + height * 0.975, width * 0.6 * status.fraction, 2)
    end
  end
  local artFailure = type(status) == "table" and status.artFailure or self.artFailure
  if artFailure ~= nil then
    graphics.setColor(1, 0.67, 0.53, 1)
    graphics.printf(
      "Walking art unavailable: " .. tostring(artFailure),
      x + width * 0.04,
      y + height * 0.93,
      width * 0.92,
      "center"
    )
  end
end

function HgssLoadingPresentation:draw(status)
  local maybeBounds = self.primaryBounds
  if self.disposed or maybeBounds == nil then
    return
  end
  if self.hero == nil then
    self:_drawCopy(status, true)
    return
  end
  local graphics = self.graphics
  local bounds = maybeBounds
  local stageHeight = self.configuration == "tall" and bounds.height * 0.66 or bounds.height
  local scale = math.max(1, math.floor(math.min(bounds.width / STAGE_WIDTH, stageHeight / STAGE_HEIGHT)))
  local originX = math.floor(bounds.x + (bounds.width - STAGE_WIDTH * scale) / 2)
  local originY = math.floor(bounds.y + (stageHeight - STAGE_HEIGHT * scale) / 2)
  LogicalSurface.clip(graphics, bounds, function()
    graphics.setColor(1, 1, 1, 1)
    local backgroundScale = self.configuration == "wide"
        and math.max(bounds.width / STAGE_WIDTH, bounds.height / STAGE_HEIGHT)
      or scale
    local backgroundWidth = STAGE_WIDTH * backgroundScale
    local backgroundX = bounds.x + (bounds.width - backgroundWidth) / 2
    graphics.draw(self.backdrop, self.backdropQuad, backgroundX, originY, 0, backgroundScale, scale)
    local skyOffset = (self.elapsed * 5) % 272
    graphics.setColor(0.82, 0.87, 0.8, 0.55)
    for _, spark in ipairs(SKY_SPARKS) do
      local x = (spark.x - skyOffset) % 272 - 8
      graphics.rectangle("fill", originX + x * scale, originY + spark.y * scale, math.max(1, scale), math.max(1, scale))
    end
    local dashOffset = (self.elapsed * 20) % 288
    graphics.setColor(0.74, 0.81, 0.67, 0.8)
    for _, dash in ipairs(GROUND_DASHES) do
      local x = (dash.x - dashOffset) % 288 - 16
      graphics.rectangle("fill", originX + x * scale, originY + dash.y * scale, dash.width * scale, math.max(1, scale))
    end
    local followerFrame = self:_frameIndex("follower")
    local heroFrame = self:_frameIndex("hero")
    local function drawSprite(sprite, frameIndex, x, y)
      local quad = assert(sprite.quads[frameIndex])
      graphics.draw(sprite.image, quad, originX + x * scale, originY + y * scale, 0, scale, scale)
    end
    drawSprite(self.follower, followerFrame, 80, 96)
    drawSprite(self.hero, heroFrame, 112, 80)
  end)
  self:_drawCopy(status, false)
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
  local images = { self.backdrop, self.hero and self.hero.image, self.follower and self.follower.image }
  self.backdrop, self.hero, self.follower, self.heroId = nil, nil, nil, nil
  self.heroQuad, self.followerQuad, self.backdropQuad = nil, nil, nil
  for _, image in ipairs(images) do
    if image ~= nil then
      image:release()
    end
  end
end

return HgssLoadingPresentation
