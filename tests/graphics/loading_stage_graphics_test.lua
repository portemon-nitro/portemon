-- The selected-edition loading stage is one continuous themed scene that is
-- already distinct before generated sprite art arrives: warm gold for the
-- selected HeartGold, cool silver for SoulSilver, and a subdued neutral
-- stage with no selection. The scene paints every pixel of the drawable and
-- keeps animating; no outlined card or generic headline is ever composed.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PngWriter = require("libs.assets.src.PngWriter")
local Presentation = require("libs.hgss.src.ui.HgssLoadingPresentation")

local WIDTH, HEIGHT = 480, 360

local T = {}

local function renderStage(scope, presentation)
  local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  presentation:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  return scope:own(canvas:newImageData())
end

local function cornerAlpha(image)
  local minimum = 1
  for _, corner in ipairs({ { 0, 0 }, { WIDTH - 1, 0 }, { 0, HEIGHT - 1 }, { WIDTH - 1, HEIGHT - 1 } }) do
    local _, _, _, alpha = image:getPixel(corner[1], corner[2])
    minimum = math.min(minimum, alpha)
  end
  return minimum
end

function T.selected_edition_stages_differ_without_card_outlines(scope)
  local presentations = {}
  local function stage(versionId)
    local presentation = Presentation.new({ versionId = versionId, width = WIDTH, height = HEIGHT })
    presentations[#presentations + 1] = presentation
    return presentation
  end
  scope:own({
    release = function()
      for _, presentation in ipairs(presentations) do
        presentation:dispose()
      end
    end,
  })
  local gold = stage("heartgold")
  local silver = stage("soulsilver")
  local neutral = stage(nil)
  local outlined = 0
  local originalRectangle = love.graphics.rectangle
  local ok, err = xpcall(function()
    love.graphics.rectangle = function(mode, ...)
      if mode == "line" then
        outlined = outlined + 1
      end
      return originalRectangle(mode, ...)
    end
    local goldPixels = renderStage(scope, gold)
    local silverPixels = renderStage(scope, silver)
    local neutralPixels = renderStage(scope, neutral)
    Assert.isTrue(goldPixels:getString() ~= silverPixels:getString(), "gold and silver stages render distinct pixels")
    Assert.isTrue(goldPixels:getString() ~= neutralPixels:getString(), "the gold stage differs from neutral")
    Assert.isTrue(silverPixels:getString() ~= neutralPixels:getString(), "the silver stage differs from neutral")
    Assert.isTrue(cornerAlpha(goldPixels) > 0, "the gold stage covers the full drawable")
    Assert.isTrue(cornerAlpha(silverPixels) > 0, "the silver stage covers the full drawable")
    Assert.isTrue(cornerAlpha(neutralPixels) > 0, "the neutral stage covers the full drawable")
    gold:update(0.2)
    local laterGold = renderStage(scope, gold)
    Assert.isTrue(laterGold:getString() ~= goldPixels:getString(), "the pre-art stage keeps animating")
  end, debug.traceback)
  love.graphics.rectangle = originalRectangle
  if not ok then
    error(err, 0)
  end
  Assert.equal(outlined, 0, "the continuous stage draws no outlined card")
end

local function startupPairVisual(frameWidth, frameHeight)
  return {
    render = { kind = "atlas", frameWidth = frameWidth, frameHeight = frameHeight, frameCount = 2 },
    pivot = { x = 0.5, y = 1 },
    directions = {
      east = {
        walk = {
          frames = {
            { frameIndex = 1, ticks = 1 },
            { frameIndex = 2, ticks = 3 },
          },
        },
      },
    },
  }
end

-- Two-frame atlas bytes with transparent margins around an opaque sprite
-- block; the second frame shifts by one pixel so clip ticks are observable.
local function startupTransparentAtlas(frameWidth, frameHeight)
  local width = frameWidth * 2
  local parts = {}
  for y = 0, frameHeight - 1 do
    for x = 0, width - 1 do
      local localX = x % frameWidth
      local shift = math.floor(x / frameWidth)
      local inSprite = localX >= 2 + shift and localX < frameWidth - 2 + shift and y >= 2 and y < frameHeight - 2
      if inSprite then
        parts[#parts + 1] = string.char(240, 200, 120, 255)
      else
        parts[#parts + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  return PngWriter.encode(width, frameHeight, table.concat(parts))
end

local function startupPairCacheFs(pairIndex, versionId)
  local heroPath = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/hero.png"
  local followerPath = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/follower.png"
  local manifest = {
    schema = "g4-startup-walker-v1",
    versionId = versionId,
    generationId = "test-generation",
    pairIndex = pairIndex,
    hero = { atlasPath = heroPath, visual = startupPairVisual(16, 24) },
    follower = { speciesId = 25, atlasPath = followerPath, visual = startupPairVisual(12, 20) },
  }
  local files = {
    [heroPath] = startupTransparentAtlas(16, 24),
    [followerPath] = startupTransparentAtlas(12, 20),
  }
  return {
    loadLua = function()
      return manifest
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      return assert(files[path], "unexpected generated read " .. tostring(path))
    end,
  }
end

local function startupDiffBytes(left, right)
  Assert.equal(#left, #right, "compared stages share their dimensions")
  local changed = 0
  for index = 1, #left do
    if left:byte(index) ~= right:byte(index) then
      changed = changed + 1
    end
  end
  return changed
end

function T.startup_pair_paints_transparent_sprites_over_the_live_stage(scope)
  local presentation = Presentation.new({
    versionId = "heartgold",
    width = WIDTH,
    height = HEIGHT,
    pairIndex = 5,
    random = function()
      return 0.25
    end,
  })
  scope:own({
    release = function()
      presentation:dispose()
    end,
  })
  local pre = renderStage(scope, presentation)
  Assert.isTrue(
    presentation:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
    "the chosen pair adopts its two transparent atlases"
  )
  local post = renderStage(scope, presentation)
  local total = WIDTH * HEIGHT * 4
  local changed = startupDiffBytes(pre:getString(), post:getString())
  Assert.isTrue(changed > 0, "the adopted pair is visible over the live stage")
  Assert.isTrue(
    changed < total * 0.05,
    "transparent sprite margins leave the live stage visible around the pair"
  )
  presentation:update(1 / 30)
  local advanced = renderStage(scope, presentation)
  Assert.isTrue(
    advanced:getString() ~= post:getString(),
    "the adopted stage keeps animating through source walk ticks"
  )
  Assert.isTrue(cornerAlpha(advanced) > 0, "the adopted stage still covers the full drawable")
end

function T.startup_stage_opens_on_a_random_line_and_stays_animated(scope)
  local presentations = {}
  local function present(firstRandom)
    local presentation = Presentation.new({
      versionId = "heartgold",
      width = WIDTH,
      height = HEIGHT,
      pairIndex = 5,
      random = function()
        return firstRandom
      end,
    })
    presentations[#presentations + 1] = presentation
    return presentation
  end
  scope:own({
    release = function()
      for _, presentation in ipairs(presentations) do
        presentation:dispose()
      end
    end,
  })
  local first = present(0.1)
  local second = present(0.9)
  local firstPixels = renderStage(scope, first)
  local secondPixels = renderStage(scope, second)
  Assert.isTrue(
    firstPixels:getString() ~= secondPixels:getString(),
    "the opening flavor line follows the injected random stream"
  )
  Assert.isTrue(
    first:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
    "the chosen pair adopts its two transparent atlases"
  )
  local adopted = renderStage(scope, first)
  first:update(1 / 60)
  local moved = renderStage(scope, first)
  Assert.isTrue(
    moved:getString() ~= adopted:getString(),
    "the scenery keeps moving behind the adopted pair"
  )
end

return GraphicsSmoke.suite(T, { tags = { "startup" } })
