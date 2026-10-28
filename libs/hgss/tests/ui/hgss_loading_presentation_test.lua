-- The shared loading view stays useful before and after verified sprite art arrives.

local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FakeGraphics = require("tests.support.FakeGraphics")
local Presentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local DisplayContext = require("libs.ui.src.DisplayContext")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function visual(frameWidth, frameHeight)
  return {
    render = { kind = "atlas", frameWidth = frameWidth or 16, frameHeight = frameHeight or 16, frameCount = 2 },
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

local SPECIES_IDS = { 1, 4, 7, 152, 155, 158, 252, 255, 258, 387, 390, 393, 133, 25, 143, 183 }

local function cache(versionId, _)
  local heroes = {
    ethan = {
      atlasPath = "assets/generated/startup/loader/subjects/heroes/ethan.png",
      visual = visual(),
    },
    lyra = {
      atlasPath = "assets/generated/startup/loader/subjects/heroes/lyra.png",
      visual = visual(),
    },
  }
  local followers = {}
  for _, speciesId in ipairs(SPECIES_IDS) do
    followers[tostring(speciesId)] = {
      atlasPath = "assets/generated/startup/loader/subjects/followers/" .. speciesId .. ".png",
      visual = visual(),
    }
  end
  local record = {
    schema = Contract.startupWalker.schema,
    versionId = versionId or "heartgold",
    generationId = "test",
    heroes = heroes,
    followers = followers,
  }
  return {
    loadLua = function()
      return record
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      return path
    end,
  }
end

local function fillColors(host, from)
  local colors = {}
  for index = (from or 0) + 1, #host.rectangles do
    local record = host.rectangles[index]
    if record.mode == "fill" then
      local color = record.color
      colors[#colors + 1] = string.format("%.3f,%.3f,%.3f,%.3f", color[1], color[2], color[3], color[4])
    end
  end
  return table.concat(colors, "|")
end

local function hasLineRectangle(host, from)
  for index = (from or 0) + 1, #host.rectangles do
    if host.rectangles[index].mode == "line" then
      return true
    end
  end
  return false
end

local function drawnCopy(host)
  local lines = {}
  for _, call in ipairs(host.printfCalls) do
    lines[#lines + 1] = tostring(call.text)
  end
  return table.concat(lines, "\n")
end

local function graphics()
  local value = FakeGraphics.new({ imageSizes = { { 256, 192 }, { 32, 16 }, { 32, 16 }, { 32, 16 } } })
  value.printfCalls = {}
  value.getDimensions = function()
    return 256, 192
  end
  value.getDPIScale = function()
    return 1
  end
  value.printf = function(text, x, y, width, align)
    value.printfCalls[#value.printfCalls + 1] = { text = text, x = x, y = y, width = width, align = align }
    value.print(text, x, y)
  end
  return value
end

function T.allocation_failure_leaves_static_view_and_releases_staged_images()
  local graphics = FakeGraphics.new({ failOnImageCall = 2 })
  graphics.getDimensions = function()
    return 800, 450
  end
  graphics.getDPIScale = function()
    return 1
  end
  graphics.printf = function(text, x, y)
    graphics.print(text, x, y)
  end
  local presentation = Presentation.new({
    purpose = "continue",
    versionId = "heartgold",
    pairIndex = 1,
    width = 800,
    height = 450,
    graphics = graphics,
    random = function()
      return 0.5
    end,
  })
  Assert.isFalse(presentation:adoptGeneratedAssets(cache(nil, 1)))
  Assert.equal(#graphics.images, 1)
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1)
  end
  presentation:draw()
  presentation:dispose()
end

function T.mismatched_version_manifest_never_acquires_images()
  local graphics = graphics()
  local presentation = Presentation.new({
    purpose = "startup",
    versionId = "soulsilver",
    pairIndex = 1,
    width = 256,
    height = 192,
    graphics = graphics,
    random = function()
      return 0
    end,
  })
  Assert.isFalse(presentation:adoptGeneratedAssets(cache("heartgold", 1)))
  Assert.equal(#graphics.images, 0, "a stale edition cannot authorize loader images")
  graphics.printfCalls = {}
  local mark = #graphics.rectangles
  presentation:draw()
  local plainCopy = drawnCopy(graphics)
  graphics.printfCalls = {}
  presentation:draw({ label = "Preparing destination" })
  local copy = drawnCopy(graphics)
  Assert.isTrue(
    copy:find("Walking art unavailable", 1, true) == nil,
    "an optional art failure never becomes stage copy"
  )
  Assert.equal(copy, plainCopy, "a passed status never paints on the decorative stage")
  Assert.isTrue(
    copy:find("Preparing destination", 1, true) == nil,
    "caller-supplied progress never renders over the fallback stage"
  )
  Assert.isTrue(#copy > 0, "the fallback stage keeps its flavor caption")
  Assert.isFalse(hasLineRectangle(graphics, mark), "the fallback stage draws no outlined card")
  presentation:dispose()
end

function T.ignores_legacy_purpose_option()
  local host = graphics()
  local presentation = Presentation.new({
    purpose = "startup",
    versionId = "heartgold",
    width = 256,
    height = 192,
    graphics = host,
    random = function()
      return 0
    end,
  })
  presentation:draw()
  Assert.isFalse(hasLineRectangle(host), "a legacy purpose key never restores the outlined card")
  Assert.isTrue(#drawnCopy(host) > 0, "a legacy purpose key keeps the flavor stage")
  presentation:dispose()
end

function T.repeated_adoption_reuses_the_first_walking_pair()
  local randomCalls = 0
  local host = graphics()
  local presentation = Presentation.new({
    versionId = "heartgold",
    pairIndex = 1,
    width = 480,
    height = 360,
    graphics = host,
    random = function()
      randomCalls = randomCalls + 1
      return 0
    end,
  })
  Assert.isTrue(presentation:adoptGeneratedAssets(cache(nil, 1)))
  Assert.equal(randomCalls, 1, "the opening caption draws the random stream once")
  Assert.isTrue(presentation:adoptGeneratedAssets(cache(nil, 1)))
  Assert.equal(randomCalls, 1, "a repeated adoption never reselects the walking pair")
  Assert.equal(#host.images, 2, "a repeated adoption acquires no additional images")
  Assert.equal(presentation.heroId, "ethan")
  Assert.equal(presentation.follower.speciesId, 1)
  Assert.equal(presentation.pairIndex, 1, "the adopted presenter never changes its pair")
  presentation:dispose()
  for _, image in ipairs(host.images) do
    Assert.equal(image.releaseCount, 1, "every owned image is released once")
  end
end

function T.failed_adoption_keeps_the_same_stage_and_recovers_on_retry()
  local randomCalls = 0
  local host = FakeGraphics.new({
    failOnImageCall = 2,
    imageSizes = { { 32, 16 }, { 32, 16 }, { 32, 16 }, { 32, 16 } },
  })
  host.getDimensions = function()
    return 256, 192
  end
  host.getDPIScale = function()
    return 1
  end
  host.printfCalls = {}
  host.printf = function(text, x, y, width, align)
    host.printfCalls[#host.printfCalls + 1] = { text = text, x = x, y = y, width = width, align = align }
    host.print(text, x, y)
  end
  local presentation = Presentation.new({
    versionId = "heartgold",
    pairIndex = 1,
    width = 256,
    height = 192,
    graphics = host,
    random = function()
      randomCalls = randomCalls + 1
      return 0
    end,
  })
  local function freshFills()
    local other = graphics()
    local view = Presentation.new({
      versionId = "heartgold",
      width = 256,
      height = 192,
      graphics = other,
      random = function()
        return 0
      end,
    })
    view:draw()
    local fills = fillColors(other)
    view:dispose()
    return fills
  end
  local expectedFills = freshFills()
  Assert.isFalse(presentation:adoptGeneratedAssets(cache(nil, 1)))
  Assert.equal(randomCalls, 1, "the failed adoption keeps its opening caption draw")
  Assert.equal(#host.images, 1, "the failed adoption staged one image before the failure")
  for _, image in ipairs(host.images) do
    Assert.equal(image.releaseCount, 1, "every staged image is released after the failure")
  end
  local mark = #host.rectangles
  host.printfCalls = {}
  presentation:draw()
  Assert.equal(fillColors(host, mark), expectedFills, "the failed adoption keeps the same full-bleed stage")
  Assert.isFalse(hasLineRectangle(host, mark), "the failed adoption draws no outlined card")
  Assert.isTrue(#drawnCopy(host) > 0, "the failed adoption keeps the flavor caption")
  host.failOnImageCall = nil
  Assert.isTrue(presentation:adoptGeneratedAssets(cache(nil, 1)), "retrying adoption recovers the walking pair")
  Assert.equal(presentation.heroId, "ethan")
  Assert.equal(presentation.follower.speciesId, 1)
  Assert.equal(#host.images, 3, "the retry stages exactly its own duo")
  presentation:dispose()
  for _, image in ipairs(host.images) do
    Assert.equal(image.releaseCount, 1, "every owned image is released once")
  end
end

function T.responsive_layout_uses_safe_regions_and_routes_dual_copy_to_auxiliary()
  local function make(width, height, surfaces)
    local host = graphics()
    local context = DisplayContext.new({
      graphics = host,
      topologyProvider = function()
        return ScreenTopology.new({
          surfaces = surfaces or {
            {
              id = "main",
              rect = { x = 0, y = 0, width = width, height = height },
              role = "world",
              touch = false,
              safeRect = { x = 12, y = 8, width = width - 24, height = height - 16 },
            },
          },
        })
      end,
    })
    return Presentation.new({
      purpose = "import",
      versionId = "heartgold",
      pairIndex = 1,
      width = width,
      height = height,
      graphics = host,
      displayContext = context,
      random = function()
        return 0
      end,
    })
  end

  local wide = make(1280, 720)
  Assert.equal(wide.configuration, "wide")
  Assert.equal(wide.primaryBounds.x, 12)
  Assert.equal(wide.primaryBounds.y, 8)
  Assert.isTrue(wide:adoptGeneratedAssets(cache(nil, 1)))
  wide:draw()
  Assert.isTrue(#wide.graphics.draws > 0, "the wide layout walks the adopted pair")
  wide:dispose()

  local tall = make(360, 800)
  Assert.equal(tall.configuration, "tall")
  tall:draw({ label = "Preparing destination", detail = "Loading saved game" })
  tall:dispose()

  local small = make(192, 144)
  Assert.isTrue(small:adoptGeneratedAssets(cache(nil, 1)))
  small:draw()
  Assert.equal(
    small.graphics.draws[#small.graphics.draws].sx,
    1,
    "small displays clip source pixels instead of distorting them"
  )
  small:dispose()

  local dual = make(256, 392, {
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, role = "world", touch = false },
    { id = "lower", rect = { x = 0, y = 200, width = 256, height = 192 }, role = "auxiliary", touch = false },
  })
  Assert.equal(dual.configuration, "dualDisplay")
  Assert.equal(dual.primaryBounds.y, 0)
  Assert.equal(dual.secondaryBounds.y, 200)
  dual:draw({ label = "Preparing destination" })
  dual:dispose()

  local hidden = make(256, 192, {
    {
      id = "covered",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      role = "world",
      touch = false,
      occupiedRegions = { { x = 0, y = 0, width = 256, height = 192 } },
    },
  })
  Assert.isNil(hidden.primaryBounds, "fully occupied displays are temporarily not presentable")
  hidden:draw({ label = "Waiting" })
  hidden:dispose()
end

function T.edition_themed_stages_stay_card_free_before_sprite_art()
  local randomCalls = 0
  local function fresh(versionId, width, height)
    local host = graphics()
    local presentation = Presentation.new({
      versionId = versionId,
      width = width,
      height = height,
      graphics = host,
      random = function()
        randomCalls = randomCalls + 1
        return 0
      end,
    })
    return host, presentation
  end
  for _, geometry in ipairs({ { 480, 360 }, { 1280, 720 }, { 360, 800 } }) do
    local width, height = geometry[1], geometry[2]
    local themes = {}
    for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
      local host, presentation = fresh(versionId, width, height)
      presentation:draw()
      Assert.isFalse(hasLineRectangle(host), versionId .. " draws no outlined card before sprite art")
      local copy = drawnCopy(host)
      Assert.isTrue(copy:find("Preparing", 1, true) == nil, versionId .. " shows no generic headline")
      Assert.isTrue(#copy > 0, versionId .. " keeps its flavor caption without sprite art")
      themes[versionId] = fillColors(host)
      presentation:dispose()
    end
    local neutralHost, neutral = fresh(nil, width, height)
    neutral:draw()
    Assert.isFalse(hasLineRectangle(neutralHost), "the neutral stage draws no outlined card")
    themes.neutral = fillColors(neutralHost)
    neutral:dispose()
    Assert.isTrue(themes.heartgold ~= themes.soulsilver, "gold and silver stages differ before sprite art")
    Assert.isTrue(themes.heartgold ~= themes.neutral, "the gold stage differs from the neutral stage")
    Assert.isTrue(themes.soulsilver ~= themes.neutral, "the silver stage differs from the neutral stage")
  end
  local host, presentation = fresh("heartgold", 480, 360)
  local mark = #host.rectangles
  presentation:draw()
  local firstCopy = drawnCopy(host)
  local firstFills = fillColors(host, mark)
  presentation:update(4.1)
  host.printfCalls = {}
  mark = #host.rectangles
  presentation:draw()
  Assert.isTrue(drawnCopy(host) ~= firstCopy, "flavor captions advance without sprite art")
  Assert.isFalse(hasLineRectangle(host, mark), "caption ticks never introduce an outlined card")
  mark = #host.rectangles
  presentation:resize(1280, 720)
  presentation:draw()
  Assert.equal(fillColors(host, mark), firstFills, "resizing keeps the selected edition theme")
  Assert.isTrue(randomCalls > 0, "the opening caption draws the random stream once")
  local callsAfterConstruction = randomCalls
  presentation:draw()
  presentation:resize(1280, 720)
  presentation:draw()
  Assert.equal(randomCalls, callsAfterConstruction, "drawing and resizing never consume the stream again")
  presentation:dispose()
end

function T.adopted_walking_pair_keeps_the_same_full_bleed_stage()
  local randomCalls = 0
  local host = graphics()
  local presentation = Presentation.new({
    versionId = "heartgold",
    pairIndex = 19,
    width = 480,
    height = 360,
    graphics = host,
    random = function()
      randomCalls = randomCalls + 1
      return 0
    end,
  })
  local mark = #host.rectangles
  presentation:draw()
  local preFills = fillColors(host, mark)
  Assert.isTrue(drawnCopy(host):find("Preparing", 1, true) == nil, "the pre-art stage shows no generic headline")
  Assert.isTrue(presentation:adoptGeneratedAssets(cache(nil, 19)))
  Assert.equal(presentation.heroId, "lyra", "the chosen pair fixes its hero")
  Assert.equal(presentation.follower.speciesId, 7, "the chosen pair fixes its follower")
  Assert.equal(randomCalls, 1, "the opening caption draws the random stream once")
  mark = #host.rectangles
  local drawsMark = #host.draws
  presentation:draw()
  Assert.equal(fillColors(host, mark), preFills, "generated art upgrades the same full-bleed stage")
  Assert.isFalse(hasLineRectangle(host, mark), "adopted art never introduces an outlined card")
  local covers = false
  for index = mark + 1, #host.rectangles do
    local record = host.rectangles[index]
    if record.mode == "fill" and record.x == 0 and record.y == 0 and record.w == 480 and record.h == 360 then
      covers = true
    end
  end
  Assert.isTrue(covers, "the adopted stage still paints the full drawable")
  local sprites = {}
  for index = drawsMark + 1, #host.draws do
    local draw = host.draws[index]
    if draw.quad ~= nil and draw.quad.w < 64 then
      sprites[#sprites + 1] = draw
    end
  end
  Assert.equal(#sprites, 2, "exactly one hero and one follower walk the adopted stage")
  Assert.isTrue(sprites[1].x < sprites[2].x, "the follower walks behind and left of the hero")
  for _, sprite in ipairs(sprites) do
    local color = sprite.color
    Assert.isTrue(
      color[1] == 1 and color[2] == 1 and color[3] == 1 and color[4] == 1,
      "walking sprites are never tinted"
    )
  end
  local first = host.draws[#host.draws].quad.x
  presentation:update(1 / 60)
  presentation:draw()
  Assert.equal(host.draws[#host.draws].quad.x, first, "walking cadence follows 30 Hz source ticks")
  presentation:update(1 / 60)
  presentation:draw()
  Assert.isTrue(host.draws[#host.draws].quad.x ~= first, "clip ticks advance the hero frame")
  presentation:update(8)
  host.printfCalls = {}
  presentation:draw()
  Assert.equal(presentation.heroId, "lyra", "captions never reselect the walking pair")
  Assert.equal(presentation.follower.speciesId, 7, "captions never reselect the walking pair")
  Assert.equal(randomCalls, 1, "caption ticks never consume the stream again")
  Assert.equal(presentation.pairIndex, 19, "the adopted presenter never changes its pair")
  presentation:dispose()
  Assert.equal(#host.images, 2, "the stage owns exactly its duo images")
  for _, image in ipairs(host.images) do
    Assert.equal(image.releaseCount, 1, "every owned image is released once")
  end
  presentation:dispose()
  local titleHost = graphics()
  local titleFirst = Presentation.new({
    versionId = "heartgold",
    width = 480,
    height = 360,
    graphics = titleHost,
    random = function()
      return 0
    end,
  })
  titleFirst:dispose()
  Assert.equal(#titleHost.images, 0, "a title-first handoff disposes the loader before any art arrives")
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

local function startupPairCacheFs(pairIndex, versionId, heroWidth, heroHeight, followerWidth, followerHeight)
  local choice = require("libs.assets.src.StartupAssetCache").walkerChoice(pairIndex)
  local heroPath = "assets/generated/startup/loader/subjects/heroes/" .. choice.heroId .. ".png"
  local followerPath = "assets/generated/startup/loader/subjects/followers/" .. choice.followerSpeciesId .. ".png"
  local reads = {}
  local heroes = {
    ethan = {
      atlasPath = "assets/generated/startup/loader/subjects/heroes/ethan.png",
      visual = startupPairVisual(heroWidth, heroHeight),
    },
    lyra = {
      atlasPath = "assets/generated/startup/loader/subjects/heroes/lyra.png",
      visual = startupPairVisual(heroWidth, heroHeight),
    },
  }
  local followers = {}
  for _, speciesId in ipairs(SPECIES_IDS) do
    followers[tostring(speciesId)] = {
      atlasPath = "assets/generated/startup/loader/subjects/followers/" .. speciesId .. ".png",
      visual = startupPairVisual(followerWidth, followerHeight),
    }
  end
  local record = {
    schema = "g4-startup-walker-v2",
    versionId = versionId,
    generationId = "test-generation",
    heroes = heroes,
    followers = followers,
  }
  return {
    reads = reads,
    heroPath = heroPath,
    followerPath = followerPath,
    loadLua = function()
      return record
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      reads[#reads + 1] = path
      return path
    end,
  }
end

local function startupPairGraphics()
  local host = FakeGraphics.new({ imageSizes = { { 32, 24 }, { 24, 20 } } })
  host.printfCalls = {}
  host.getDimensions = function()
    return 480, 360
  end
  host.getDPIScale = function()
    return 1
  end
  host.printf = function(text, x, y, width, align)
    host.printfCalls[#host.printfCalls + 1] = { text = text, x = x, y = y, width = width, align = align }
    host.print(text, x, y)
  end
  return host
end

local function startupSpriteDraws(host, from)
  local sprites = {}
  for index = (from or 0) + 1, #host.draws do
    local draw = host.draws[index]
    if draw.quad ~= nil then
      if draw.quad.w < 64 then
        sprites[#sprites + 1] = draw
      else
        Assert.isTrue(false, "no full-stage cover is drawn over the live stage")
      end
    end
  end
  return sprites
end

local function startupStageGeometry(host, from)
  local parts = {}
  for index = (from or 0) + 1, #host.rectangles do
    local record = host.rectangles[index]
    if record.mode == "fill" then
      parts[#parts + 1] = string.format("%.3f,%.3f,%.3f,%.3f", record.x, record.y, record.w, record.h)
    end
  end
  return table.concat(parts, "|")
end

function T.startup_pair_feet_share_one_baseline_with_no_opaque_cover()
  local host = startupPairGraphics()
  local presentation = Presentation.new({
    versionId = "heartgold",
    width = 480,
    height = 360,
    pairIndex = 5,
    graphics = host,
    random = function()
      return 0.25
    end,
  })
  local cacheFs = startupPairCacheFs(5, "heartgold", 16, 24, 12, 20)
  Assert.isTrue(presentation:adoptGeneratedAssets(cacheFs), "the chosen pair adopts its two transparent atlases")
  Assert.equal(#host.images, 2, "exactly one hero and one follower atlas are resident, with no opaque cover")
  Assert.equal(#cacheFs.reads, 2, "adoption reads exactly the two pair atlases")
  local readSet = {}
  for _, path in ipairs(cacheFs.reads) do
    readSet[path] = true
  end
  Assert.isTrue(
    readSet[cacheFs.heroPath] == true and readSet[cacheFs.followerPath] == true,
    "adoption reads the hero and follower atlases and no cover image"
  )
  local drawsMark = #host.draws
  presentation:draw()
  local sprites = startupSpriteDraws(host, drawsMark)
  Assert.equal(#sprites, 2, "exactly one hero and one follower walk the adopted stage")
  Assert.equal(sprites[1].quad.w, 12, "the follower walks behind the hero")
  Assert.equal(sprites[2].quad.w, 16, "the hero walks ahead of the follower")
  local function footY(draw)
    return draw.y + draw.quad.h * draw.sy
  end
  local function footX(draw)
    return draw.x + draw.quad.w * draw.sx / 2
  end
  Assert.near(
    footY(sprites[1]),
    footY(sprites[2]),
    0.001,
    "both feet land on one common baseline from differently sized source sprites"
  )
  Assert.near(
    (footX(sprites[2]) - footX(sprites[1])) / sprites[1].sx - (12 + 16) / 2,
    6,
    0.001,
    "the frame boxes keep a clear gap between follower and hero"
  )
  local firstFrame = host.draws[#host.draws].quad.x
  presentation:update(1 / 60)
  presentation:draw()
  Assert.equal(host.draws[#host.draws].quad.x, firstFrame, "walking cadence follows 30 Hz source ticks")
  presentation:update(1 / 60)
  presentation:draw()
  Assert.isTrue(host.draws[#host.draws].quad.x ~= firstFrame, "clip ticks advance the walk frame in source order")
  presentation:resize(360, 800)
  drawsMark = #host.draws
  presentation:draw()
  local tallSprites = startupSpriteDraws(host, drawsMark)
  Assert.equal(#tallSprites, 2, "the tall layout walks the same chosen pair")
  Assert.near(
    (footX(tallSprites[2]) - footX(tallSprites[1])) / tallSprites[1].sx - (12 + 16) / 2,
    6,
    0.001,
    "the tall layout keeps the clear gap behind the hero"
  )
  Assert.near(
    math.abs(footY(tallSprites[1]) - footY(tallSprites[2])),
    tallSprites[1].sy,
    0.001,
    "only the mid-stride lift separates the tall feet on their shared travel line"
  )
  presentation:dispose()
  presentation:dispose()
  for _, image in ipairs(host.images) do
    Assert.equal(image.releaseCount, 1, "every owned image is released once")
  end
end

function T.startup_captions_open_on_a_random_line_and_keep_the_stage_moving()
  local function present(firstRandom)
    local host = startupPairGraphics()
    local values = { firstRandom, 0.5 }
    local calls = 0
    local presentation = Presentation.new({
      versionId = "heartgold",
      width = 480,
      height = 360,
      pairIndex = 5,
      graphics = host,
      random = function()
        calls = calls + 1
        return values[calls] or 0.5
      end,
    })
    return host, presentation, function()
      return calls
    end
  end
  local hostA, presentationA, callsA = present(0.1)
  local hostB, presentationB, callsB = present(0.9)
  presentationA:draw()
  presentationB:draw()
  local firstCaption = hostA.printfCalls[1].text
  Assert.isTrue(
    hostB.printfCalls[1].text ~= firstCaption,
    "the first flavor line is drawn from the injected random stream"
  )
  Assert.equal(callsA(), 1, "the opening line consumes the random stream once")
  Assert.equal(callsB(), 1, "the opening line consumes the random stream once")
  local cacheFs = startupPairCacheFs(5, "heartgold", 16, 24, 12, 20)
  local mark = #hostA.rectangles
  presentationA:draw()
  local preGeometry = startupStageGeometry(hostA, mark)
  Assert.isTrue(presentationA:adoptGeneratedAssets(cacheFs), "the chosen pair adopts its two transparent atlases")
  mark = #hostA.rectangles
  presentationA:draw()
  Assert.equal(
    startupStageGeometry(hostA, mark),
    preGeometry,
    "adoption keeps the running stage instead of resetting it"
  )
  local adoptedFrame = hostA.draws[#hostA.draws].quad.x
  presentationA:update(1 / 60)
  mark = #hostA.rectangles
  presentationA:draw()
  Assert.equal(
    hostA.draws[#hostA.draws].quad.x,
    adoptedFrame,
    "the walk frame is held across one host tick"
  )
  Assert.isTrue(
    startupStageGeometry(hostA, mark) ~= preGeometry,
    "the scenery keeps moving behind the held sprite frame"
  )
  presentationA:update(4)
  hostA.printfCalls = {}
  presentationA:draw()
  local secondCaption = hostA.printfCalls[1].text
  Assert.isTrue(secondCaption ~= firstCaption, "the flavor line rotates without an immediate repeat")
  presentationA:update(4)
  hostA.printfCalls = {}
  presentationA:draw()
  Assert.isTrue(
    hostA.printfCalls[1].text ~= secondCaption,
    "successive flavor lines never repeat adjacently"
  )
  presentationA:dispose()
  presentationB:dispose()
end

local function generationCacheFs(pairIndex, versionId, generationId, heroWidth, followerWidth)
  local choice = require("libs.assets.src.StartupAssetCache").walkerChoice(pairIndex)
  local heroes = {
    ethan = {
      atlasPath = "assets/generated/startup/loader/subjects/heroes/ethan.png",
      visual = startupPairVisual(heroWidth, 24),
    },
    lyra = {
      atlasPath = "assets/generated/startup/loader/subjects/heroes/lyra.png",
      visual = startupPairVisual(heroWidth, 24),
    },
  }
  local followers = {}
  for _, speciesId in ipairs(SPECIES_IDS) do
    followers[tostring(speciesId)] = {
      atlasPath = "assets/generated/startup/loader/subjects/followers/" .. speciesId .. ".png",
      visual = startupPairVisual(followerWidth, 20),
    }
  end
  local record = {
    schema = "g4-startup-walker-v2",
    versionId = versionId,
    generationId = generationId,
    heroes = heroes,
    followers = followers,
  }
  return {
    loadLua = function()
      return record
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      return path
    end,
  }
end

function T.catalog_refresh_reuses_same_images_and_swaps_newer_catalog_atomically()
  local host = FakeGraphics.new({
    imageSizes = { { 64, 24 }, { 64, 20 }, { 64, 24 }, { 64, 20 }, { 64, 24 }, { 64, 20 } },
    failOnImageCall = 6,
  })
  host.getDimensions = function()
    return 256, 192
  end
  host.getDPIScale = function()
    return 1
  end
  host.printfCalls = {}
  host.printf = function(text, x, y, width, align)
    host.printfCalls[#host.printfCalls + 1] = { text = text, x = x, y = y, width = width, align = align }
    host.print(text, x, y)
  end
  local presentation = Presentation.new({
    versionId = "heartgold",
    pairIndex = 5,
    width = 256,
    height = 192,
    graphics = host,
    random = function()
      return 0
    end,
  })
  local firstCache = generationCacheFs(5, "heartgold", "catalog-a", 16, 12)
  Assert.isTrue(presentation:adoptGeneratedAssets(firstCache), "the first catalog adopts")
  Assert.equal(#host.images, 2, "the first catalog owns exactly two images")
  Assert.equal(presentation.hero.visual.render.frameWidth, 16, "the first catalog fixes the hero width")
  local sameCache = generationCacheFs(5, "heartgold", "catalog-a", 16, 12)
  Assert.isTrue(presentation:adoptGeneratedAssets(sameCache), "re-observing the same catalog stays adopted")
  Assert.equal(#host.images, 2, "the same catalog never uploads again")
  local newerCache = generationCacheFs(5, "heartgold", "catalog-b", 20, 14)
  Assert.isTrue(presentation:adoptGeneratedAssets(newerCache), "the newer catalog adopts")
  Assert.equal(#host.images, 4, "the newer catalog stages its own duo")
  Assert.equal(presentation.hero.visual.render.frameWidth, 20, "the newer catalog replaces the hero")
  Assert.equal(presentation.follower.visual.render.frameWidth, 14, "the newer catalog replaces the follower")
  Assert.equal(host.images[1].releaseCount, 1, "the older hero releases exactly once after the swap")
  Assert.equal(host.images[2].releaseCount, 1, "the older follower releases exactly once after the swap")
  local brokenCache = generationCacheFs(5, "heartgold", "catalog-c", 22, 15)
  local adopted, failure = presentation:adoptGeneratedAssets(brokenCache)
  Assert.isFalse(adopted, "a failed refresh never reports success")
  Assert.notNil(failure, "a failed refresh carries its diagnosis")
  Assert.equal(
    presentation.hero.visual.render.frameWidth,
    20,
    "a failed refresh keeps the previous hero visible"
  )
  Assert.equal(#host.images, 5, "the failed refresh stages before releasing")
  Assert.equal(host.images[5].releaseCount, 1, "the failed staged image releases exactly once")
  presentation:dispose()
  for _, image in ipairs(host.images) do
    Assert.isTrue(image.releaseCount >= 1, "every touched image releases at least once")
  end
end

return { tests = T }
