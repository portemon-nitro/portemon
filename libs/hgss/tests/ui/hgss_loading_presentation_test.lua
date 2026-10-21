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

local function cache()
  local record = {
    schema = Contract.startupLoader.schema,
    versionId = "heartgold",
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
  presentation:draw({ label = "Preparing destination" })
  Assert.isTrue(
    graphics.printfCalls[#graphics.printfCalls].text:find("Walking art unavailable", 1, true) ~= nil,
    "the static presentation reports the optional art failure"
  )
  presentation:dispose()
end

function T.rejects_unknown_purpose()
  Assert.throws(function()
    Presentation.new({ purpose = "field", width = 1, height = 1 })
  end)
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

return { tests = T }
