-- The shared loading view stays useful before and after verified sprite art arrives.

local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FakeGraphics = require("tests.support.FakeGraphics")
local Presentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local DisplayContext = require("libs.ui.src.DisplayContext")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function visual()
  return {
    render = { kind = "atlas", frameWidth = 16, frameHeight = 16, frameCount = 2 },
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

local function cache(versionId)
  local record = {
    schema = Contract.startupLoader.schema,
    versionId = versionId or "heartgold",
    generationId = "test",
    heroes = {
      ethan = { atlasPath = "assets/generated/startup/loader/hero.png", visual = visual() },
      lyra = { atlasPath = "assets/generated/startup/loader/hero2.png", visual = visual() },
    },
    followers = {},
    backdrop = {
      kind = "authored",
      width = 256,
      height = 192,
      image = "assets/generated/startup/loader/backdrop.png",
    },
  }
  for speciesId = 1, 4 do
    record.followers[speciesId] = {
      speciesId = speciesId,
      atlasPath = "assets/generated/startup/loader/follower" .. speciesId .. ".png",
      visual = visual(),
    }
  end
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

function T.static_copy_and_generated_walk_animation_have_separate_lifetimes()
  local graphics = graphics()
  local presentation = Presentation.new({
    purpose = "import",
    versionId = "heartgold",
    width = 480,
    height = 360,
    graphics = graphics,
    random = function()
      return 0
    end,
  })
  presentation:draw({ state = "verifying", message = "Verifying cartridge identity…" })
  Assert.equal(#graphics.images, 0, "the static view creates no ROM-derived images")
  Assert.equal(graphics.printfCalls[1].text, "Enraging the lake…")

  Assert.isTrue(presentation:adoptGeneratedAssets(cache()))
  presentation:draw()
  local first = graphics.draws[#graphics.draws].quad.x
  presentation:update(1 / 60)
  presentation:draw()
  Assert.equal(first, graphics.draws[#graphics.draws].quad.x, "walking cadence follows 30 Hz source ticks")
  presentation:update(1 / 60)
  presentation:draw()
  local second = graphics.draws[#graphics.draws].quad.x
  Assert.isTrue(first ~= second, "clip ticks advance the hero frame")
  Assert.equal(presentation.follower.speciesId, 1, "injected random source chooses one follower once")
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.filters[1].min, "nearest", "pixel atlases retain nearest sampling")
    Assert.equal(image.filters[1].mag, "nearest", "pixel atlases retain nearest sampling")
  end
  presentation:resize(1280, 720)
  presentation:draw({ state = "verifying" })
  presentation:dispose()
  presentation:dispose()
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "every owned image is released once")
  end
end

function T.allocation_failure_leaves_static_view_and_releases_staged_images()
  local graphics = FakeGraphics.new({ failOnImageCall = 3 })
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
    width = 800,
    height = 450,
    graphics = graphics,
    random = function()
      return 0.5
    end,
  })
  Assert.isFalse(presentation:adoptGeneratedAssets(cache()))
  Assert.equal(#graphics.images, 2)
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
    width = 256,
    height = 192,
    graphics = graphics,
    random = function()
      return 0
    end,
  })
  Assert.isFalse(presentation:adoptGeneratedAssets(cache()))
  Assert.equal(#graphics.images, 0, "a stale edition cannot authorize loader images")
  graphics.printfCalls = {}
  local mark = #graphics.rectangles
  presentation:draw({ label = "Preparing destination" })
  local copy = drawnCopy(graphics)
  Assert.isTrue(
    copy:find("Walking art unavailable", 1, true) == nil,
    "an optional art failure never becomes stage copy"
  )
  Assert.isTrue(
    copy:find("Preparing destination", 1, true) ~= nil,
    "caller-supplied progress still renders over the fallback stage"
  )
  Assert.isTrue(#copy:gsub("Preparing destination", "") > 0, "the fallback stage keeps its flavor caption")
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
    width = 480,
    height = 360,
    graphics = host,
    random = function()
      randomCalls = randomCalls + 1
      return 0
    end,
  })
  Assert.isTrue(presentation:adoptGeneratedAssets(cache()))
  Assert.equal(randomCalls, 2, "the first adoption draws hero and follower once")
  Assert.isTrue(presentation:adoptGeneratedAssets(cache()))
  Assert.equal(randomCalls, 2, "a repeated adoption never reselects the walking pair")
  Assert.equal(#host.images, 3, "a repeated adoption acquires no additional images")
  Assert.equal(presentation.heroId, "ethan")
  Assert.equal(presentation.follower.speciesId, 1)
  presentation:dispose()
  for _, image in ipairs(host.images) do
    Assert.equal(image.releaseCount, 1, "every owned image is released once")
  end
end

function T.failed_adoption_keeps_the_same_stage_and_recovers_on_retry()
  local randomCalls = 0
  local host = FakeGraphics.new({
    failOnImageCall = 3,
    imageSizes = { { 256, 192 }, { 32, 16 }, { 256, 192 }, { 32, 16 }, { 32, 16 } },
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
  Assert.isFalse(presentation:adoptGeneratedAssets(cache()))
  Assert.equal(randomCalls, 2, "the failed adoption drew hero and follower before staging images")
  Assert.equal(#host.images, 2, "the failed adoption staged two images before the failure")
  for _, image in ipairs(host.images) do
    Assert.equal(image.releaseCount, 1, "every staged image is released after the failure")
  end
  local mark = #host.rectangles
  host.printfCalls = {}
  presentation:draw()
  Assert.equal(fillColors(host, mark), expectedFills, "the failed adoption keeps the same full-bleed stage")
  Assert.isFalse(hasLineRectangle(host, mark), "the failed adoption draws no outlined card")
  Assert.isTrue(#drawnCopy(host) > 0, "the failed adoption keeps the flavor caption")
  Assert.isTrue(presentation:adoptGeneratedAssets(cache()), "retrying adoption recovers the walking pair")
  Assert.equal(presentation.heroId, "ethan")
  Assert.equal(presentation.follower.speciesId, 1)
  Assert.equal(#host.images, 5, "the retry stages exactly its own backdrop and duo")
  presentation:dispose()
  for _, image in ipairs(host.images) do
    Assert.equal(image.releaseCount, 1, "every owned image is released once")
  end
end

function T.caption_cycle_contains_the_authored_examples_and_randomizes_actor_once()
  local graphics = graphics()
  local values = { 0.9, 0.5 }
  local nextValue = 0
  local presentation = Presentation.new({
    purpose = "startup",
    versionId = "heartgold",
    width = 256,
    height = 192,
    graphics = graphics,
    random = function()
      nextValue = nextValue + 1
      return values[nextValue]
    end,
  })
  Assert.isTrue(presentation:adoptGeneratedAssets(cache()))
  Assert.equal(presentation.heroId, "lyra")
  Assert.equal(presentation.follower.speciesId, 3)
  local expected = {
    "Enraging the lake…",
    "Poisoning Amphy…",
    "Reviving Team Rocket…",
    "Delivering the SecretPotion…",
    "Waking Snorlax…",
    "Polishing Poké Balls…",
    "Calling Professor Elm…",
  }
  for index = 1, #expected do
    graphics.printfCalls = {}
    presentation:draw()
    Assert.equal(graphics.printfCalls[1].text, expected[index])
    if index < #expected then
      for _ = 1, 4 do
        presentation:update(1)
      end
    end
  end
  Assert.equal(nextValue, 2, "actor choices are fixed for the presentation lifetime")
  for _ = 1, 3 do
    presentation:update(1)
  end
  presentation:update(0.8)
  graphics.printfCalls = {}
  presentation:draw({ label = "Preparing destination", error = "Source unavailable" })
  Assert.equal(graphics.printfCalls[1].text, "Calling Professor Elm…")
  Assert.equal(
    graphics.printfCalls[2].text,
    "Enraging the lake…",
    "caption handoff draws both phrases during its crossfade"
  )
  Assert.equal(graphics.printfCalls[3].text, "Preparing destination")
  Assert.equal(graphics.printfCalls[4].text, "Source unavailable")
  presentation:dispose()
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
  Assert.isTrue(wide:adoptGeneratedAssets(cache()))
  wide:draw()
  Assert.isTrue(wide.graphics.draws[1].sx > wide.graphics.draws[1].sy, "wide layouts expand the backdrop horizontally")
  wide:dispose()

  local tall = make(360, 800)
  Assert.equal(tall.configuration, "tall")
  tall:draw({ label = "Preparing destination", detail = "Loading saved game" })
  tall:dispose()

  local small = make(192, 144)
  Assert.isTrue(small:adoptGeneratedAssets(cache()))
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
  Assert.equal(randomCalls, 0, "drawing and resizing never consume the actor random source")
  presentation:dispose()
end

function T.adopted_walking_pair_keeps_the_same_full_bleed_stage()
  local randomCalls = 0
  local host = graphics()
  local presentation = Presentation.new({
    versionId = "heartgold",
    width = 480,
    height = 360,
    graphics = host,
    random = function()
      randomCalls = randomCalls + 1
      if randomCalls == 1 then
        return 0.9
      end
      return 0.5
    end,
  })
  local mark = #host.rectangles
  presentation:draw()
  local preFills = fillColors(host, mark)
  Assert.isTrue(drawnCopy(host):find("Preparing", 1, true) == nil, "the pre-art stage shows no generic headline")
  Assert.isTrue(presentation:adoptGeneratedAssets(cache("heartgold")))
  Assert.equal(presentation.heroId, "lyra", "the seeded random source selects the expected hero")
  Assert.equal(presentation.follower.speciesId, 3, "the seeded random source selects one follower once")
  Assert.equal(randomCalls, 2, "adoption consumes the actor random source exactly once per slot")
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
  Assert.equal(presentation.follower.speciesId, 3, "captions never reselect the walking pair")
  Assert.equal(randomCalls, 2, "caption ticks never consume the actor random source")
  presentation:dispose()
  Assert.equal(#host.images, 3, "the stage owns exactly its backdrop and duo images")
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

return { tests = T }
