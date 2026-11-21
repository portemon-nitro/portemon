-- The story-effect adapter presents the gym mechanisms' runtime-loaded source
-- props: the Violet car's ambient loop, the four Azalea Spinarak and the four
-- Ecruteak candles, each drawn only at the transform the mechanism publishes.

local Assert = require("tests.support.Assert")

local T = { tests = {} }

local MODULES = {
  "libs.hgss.src.presentation.ModelDefinition",
  "libs.hgss.src.presentation.ModelInstance",
  "libs.hgss.src.presentation.SceneDescriptor",
  "libs.hgss.src.presentation.StoryEffectRenderer",
}

---@param overrides { car: table?, spider: table?, expectFailure: boolean? }?
local function withRendererMocks(overrides, fn)
  overrides = overrides or {}
  local saved = {}
  for _, name in ipairs(MODULES) do
    saved[name] = package.loaded[name]
  end
  local plays = {}
  local updates = 0
  package.loaded["libs.hgss.src.presentation.ModelDefinition"] = {
    fromNitroDescriptor = function(descriptor)
      return {
        key = descriptor.key,
        meshes = { { id = 0, geometry = descriptor.geometry } },
        materials = {},
        animations = descriptor.animations,
      }
    end,
  }
  package.loaded["libs.hgss.src.presentation.ModelInstance"] = {
    new = function(definition)
      local instance = { transform = nil, definition = definition }
      function instance:play(name, options)
        plays[#plays + 1] = { name = name, loopMode = options and options.loopMode }
        local handle = { name = name }
        self.playing = handle
        return handle
      end
      function instance:stop(handle)
        if self.playing == handle then
          self.playing = nil
        end
      end
      function instance:updateFixed()
        updates = updates + 1
      end
      function instance:evaluatePose() end
      function instance:drawItems()
        return { { transform = self.transform, clip = self.playing and self.playing.name or nil } }
      end
      return instance
    end,
  }
  package.loaded["libs.hgss.src.presentation.SceneDescriptor"] = {
    wrapByMaterial = function()
      return {}
    end,
  }
  package.loaded["libs.hgss.src.presentation.StoryEffectRenderer"] = nil
  local ok, err = pcall(function()
    local Renderer = require("libs.hgss.src.presentation.StoryEffectRenderer")
    local meshPaths = {}
    local pool = {
      build = function(_, build)
        return build()
      end,
      meshFor = function(_, path)
        meshPaths[#meshPaths + 1] = path
        return { mesh = { path = path }, center = { 0, 0, 0 } }
      end,
      sharedImage = function(_, path)
        return { image = { path = path }, palette = nil, indexed = false }
      end,
    }
    local definitions = {
      platform = overrides.platform,
      car = overrides.car or {
        model = {
          key = "field-effect:violet_gym_car",
          geometry = "car-mesh",
          animations = { { name = "gym01_lift" } },
        },
      },
      spider = overrides.spider or {
        model = {
          key = "field-effect:azalea_gym_spinarak",
          geometry = "spider-mesh",
          animations = { { name = "gym02lift" } },
        },
      },
      candle = overrides.candle,
    }
    fn({
      Renderer = Renderer,
      renderer = Renderer.new(definitions, pool),
      plays = plays,
      meshPaths = meshPaths,
      updates = function()
        return updates
      end,
    })
  end)
  for _, name in ipairs(MODULES) do
    package.loaded[name] = saved[name]
  end
  package.loaded["libs.hgss.src.presentation.StoryEffectRenderer"] = nil
  if overrides.expectFailure then
    Assert.isFalse(ok, "an incomplete definition set must not construct")
    return
  end
  Assert.isTrue(ok, tostring(err))
end

T.tests["draws the car and every placed spider at the published transform"] = function()
  withRendererMocks(nil, function(harness)
    local renderer = harness.renderer
    Assert.deepEqual(harness.meshPaths, { "car-mesh", "spider-mesh" }, "both source models realize their meshes")

    local car = renderer:newCar()
    Assert.equal(#harness.plays, 1, "the car claims its model")
    Assert.equal(harness.plays[1].name, "gym01_lift")
    Assert.equal(harness.plays[1].loopMode, "loop", "the source ambient loop runs until the model is released")

    local spiders = {}
    for slot = 1, 4 do
      spiders[slot] = renderer:newSpider(slot)
    end
    Assert.equal(#harness.plays, 1, "a parked spider plays no clip")

    spiders[2]:startRideAnimation()
    spiders[2]:startRideAnimation()
    Assert.equal(#harness.plays, 2, "one ride starts the source one-shot exactly once")
    Assert.equal(harness.plays[2].name, "gym02lift")
    Assert.equal(harness.plays[2].loopMode, "once")

    local items = renderer:drawItems({
      car = { x = 15.5, y = 31, z = 20.5, rotationDegrees = 0 },
      spiders = {
        { slot = 1, x = -12.5, y = 0, z = -0.5, rotationDegrees = 0 },
        { slot = 2, x = 1.5, y = 0, z = 4, rotationDegrees = 0 },
        { slot = 3, x = 2.5, y = 0, z = 6, rotationDegrees = 0 },
        { slot = 4, x = 3.5, y = 0, z = 8, rotationDegrees = 0 },
      },
    })
    Assert.equal(#items, 5, "the car and all four spiders draw")
    Assert.equal(items[1].transform[13], 15.5)
    Assert.equal(items[1].transform[14], 31)
    Assert.equal(items[1].transform[15], 20.5)
    for index = 1, 5 do
      Assert.isTrue(items[index].worldSpace == true, "a source prop draws as world geometry")
      Assert.isNil(items[index].fieldEffect, "a solid prop never takes the flat-billboard projection")
    end
    Assert.equal(items[3].transform[13], 1.5, "each spider draws at its own placeholder node")
    Assert.equal(items[3].transform[15], 4)

    car:updateFixed()
    spiders[2]:updateFixed()
    Assert.equal(harness.updates(), 2, "each live model advances its own clip clock")

    spiders[2]:stopRideAnimation()
    local afterStop =
      renderer:drawItems({ car = nil, spiders = { { slot = 2, x = 0, y = 0, z = 0, rotationDegrees = 0 } } })
    Assert.equal(#afterStop, 1)
    Assert.isNil(afterStop[1].clip, "arrival unloads the one-shot like the source animation manager")
  end)
end

T.tests["a released model drops out of the draw and its handle stays closed"] = function()
  withRendererMocks(nil, function(harness)
    local renderer = harness.renderer
    local car = renderer:newCar()
    local spider = renderer:newSpider(1)
    car:dispose()
    spider:dispose()
    Assert.equal(#renderer:drawItems({
      car = { x = 0, y = 0, z = 0, rotationDegrees = 0 },
      spiders = { { slot = 1, x = 0, y = 0, z = 0, rotationDegrees = 0 } },
    }), 0, "a released prop draws nothing")
    renderer:dispose()
  end)
end

T.tests["one source prop owns one live model and four spiders fill the quartet"] = function()
  withRendererMocks(nil, function(harness)
    local renderer = harness.renderer
    renderer:newCar()
    Assert.throws(function()
      renderer:newCar()
    end)
    for slot = 1, 4 do
      renderer:newSpider(slot)
    end
    Assert.throws(function()
      renderer:newSpider(5)
    end, "the source loads exactly four Spinarak")
    Assert.throws(function()
      renderer:newSpider(1)
    end, "a spider slot keeps one model")
    renderer:dispose()
  end)
end

-- The candle props stand at their trainer's own point, take the source shrink
-- scale, and a culled candle keeps its model while drawing nothing.
T.tests["the candle props follow the source scale and cull state"] = function()
  local candle = {
    model = {
      key = "field-effect:ecruteak_gym_candle",
      geometry = "candle-mesh",
      animations = { { name = "g04_light", frameCount = 8 } },
    },
  }
  withRendererMocks({ candle = candle }, function(harness)
    local renderer = harness.renderer
    local handles = {}
    for index = 1, 4 do
      handles[index] = renderer:newCandle(index)
    end
    Assert.equal(#harness.plays, 0, "a candle never starts an animation the source does not start")
    Assert.throws(function()
      renderer:newCandle(5)
    end, "the source loads exactly four candles")
    Assert.throws(function()
      renderer:newCandle(1)
    end, "a candle slot keeps one model")

    local items = renderer:drawItems({
      candles = {
        { index = 1, x = 4.5, y = 0, z = 6.5, scale = 1, culled = false, rotationDegrees = 0 },
        { index = 2, x = 10.5, y = 0, z = 6.5, scale = 0.5, culled = false, rotationDegrees = 0 },
        { index = 3, x = 4.5, y = 0, z = 12.5, scale = 1, culled = true, rotationDegrees = 0 },
        { index = 4, x = 11.5, y = 0, z = 19.5, scale = 0.25, culled = false, rotationDegrees = 0 },
      },
    })
    Assert.equal(#items, 3, "an extinguished candle draws nothing")
    Assert.equal(items[1].transform[13], 4.5, "the first candle stands on its trainer")
    Assert.near(items[1].transform[1], 1, 1e-9, "a full-scale candle draws its own size")
    Assert.near(items[2].transform[1], 0.5, 1e-9, "the source shrink scale reaches the model transform")
    Assert.near(items[3].transform[1], 0.25, 1e-9)
    Assert.near(items[3].transform[13], 11.5, 1e-9, "the fourth candle draws at its own trainer")

    handles[1]:updateFixed()
    Assert.equal(harness.updates(), 1, "a presented candle advances its own clip clock")
    handles[1]:dispose()
    local afterRelease = renderer:drawItems({
      candles = { { index = 1, x = 0, y = 0, z = 0, scale = 1, culled = false, rotationDegrees = 0 } },
    })
    Assert.equal(#afterRelease, 0, "a released candle draws nothing")
    renderer:dispose()
  end)
end

-- A composition that publishes no candle model still presents the car and the
-- spiders: the candle role only joins the props the bundle carries.
T.tests["a bundle without the candle model still presents the other props"] = function()
  withRendererMocks(nil, function(harness)
    Assert.isNil(harness.renderer.resources.candle, "no candle resource is built without its model")
    harness.renderer:newCar()
    Assert.equal(#harness.plays, 1)
    Assert.throws(function()
      harness.renderer:newCandle(1)
    end, "a candle claim without its model fails loudly")
    harness.renderer:dispose()
  end)
end

-- The Blackthorn platforms are static build models of their own area: no clip
-- is ever registered for them, so each claim draws its own batch list through
-- the world projection at the transform the mechanism publishes.
T.tests["the platform props draw their static batches at the published transform"] = function()
  local platform = {
    wide = {
      model = {
        kind = "static",
        batches = {
          {
            geometry = "platform-mesh",
            material = 0,
            alphaClass = "opaque",
            cullMode = "back",
            polygonAlpha = 31,
            polygonMode = "modulation",
            polygonId = 0,
            translucentDepthWrite = false,
            depthEqual = false,
            lightMask = 5,
            fogEnabled = false,
          },
        },
        materials = {
          { id = 0, name = "platform", texture = "platform-texture", wrap = { x = "clamp", y = "clamp" } },
        },
      },
    },
    narrow = { model = { kind = "static", batches = {}, materials = {} } },
  }
  withRendererMocks({ platform = platform }, function(harness)
    local handles = {}
    handles[1] = harness.renderer:newPlatform(1, "wide")
    handles[2] = harness.renderer:newPlatform(2, "narrow")
    handles[3] = harness.renderer:newPlatform(3, "wide")
    Assert.throws(function()
      harness.renderer:newPlatform(4, "wide")
    end, "the source loads exactly three platforms")
    Assert.throws(function()
      harness.renderer:newPlatform(1, "wide")
    end, "a platform slot keeps one model")

    local items = harness.renderer:drawItems({
      platforms = {
        { slot = 1, x = 13.5, y = 3, z = 75.5, rotationDegrees = -4 },
        { slot = 2, x = 9.5, y = 3, z = 58.5, rotationDegrees = 0 },
        { slot = 3, x = 14.5, y = 3, z = 32.5, rotationDegrees = 0 },
      },
    })
    Assert.equal(#items, 2, "both wide platforms draw their own batch and the narrow one draws none")
    Assert.equal(items[1].transform[13], 13.5, "the prop stands on its anchor column")
    Assert.equal(items[1].transform[14], 3, "the prop stands at the source native height")
    Assert.equal(items[1].transform[15], 75.5, "the prop stands on its anchor row")
    Assert.equal(items[2].transform[13], 14.5, "the second wide platform draws at its own anchor")
    Assert.isTrue(items[1].worldSpace == true, "a platform draws as world geometry")
    Assert.isNil(items[1].fieldEffect, "a solid prop never takes the flat-billboard projection")
    Assert.near(items[1].transform[1], math.cos(math.rad(-4)), 1e-9, "the settled source angle reaches the model")

    handles[1]:updateFixed()
    handles[1]:dispose()
    Assert.equal(#harness.renderer:drawItems({
      platforms = { { slot = 1, x = 0, y = 0, z = 0, rotationDegrees = 0 } },
    }), 0, "a released platform draws nothing")
    harness.renderer:dispose()
  end)
end

-- A composition that publishes no platform models still presents the other
-- props; a platform claim without its model fails loudly.
T.tests["a bundle without the platform models still presents the other props"] = function()
  withRendererMocks(nil, function(harness)
    Assert.isNil(harness.renderer.resources.platform, "no platform resource is built without its model")
    Assert.throws(function()
      harness.renderer:newPlatform(1, "wide")
    end, "a platform claim without its model fails loudly")
    harness.renderer:dispose()
  end)
end

T.tests["the adapter requires both source prop models"] = function()
  withRendererMocks({ spider = { model = nil }, expectFailure = true }, function() end)
end

return T
