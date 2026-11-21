-- The story-effect adapter presents the gym mechanisms' runtime-loaded source
-- props: the Violet car's ambient loop and the four Azalea Spinarak, each drawn
-- only at the transform the mechanism publishes.

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
        build()
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
      car = overrides.car or {
        model = { key = "field-effect:violet_gym_car", geometry = "car-mesh", animations = { { name = "gym01_lift" } } },
      },
      spider = overrides.spider or {
        model = { key = "field-effect:azalea_gym_spinarak", geometry = "spider-mesh", animations = { { name = "gym02lift" } } },
      },
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
    local afterStop = renderer:drawItems({ car = nil, spiders = { { slot = 2, x = 0, y = 0, z = 0, rotationDegrees = 0 } } })
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
    Assert.equal(
      #renderer:drawItems({
        car = { x = 0, y = 0, z = 0, rotationDegrees = 0 },
        spiders = { { slot = 1, x = 0, y = 0, z = 0, rotationDegrees = 0 } },
      }),
      0,
      "a released prop draws nothing"
    )
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

T.tests["the adapter requires both source prop models"] = function()
  withRendererMocks({ spider = { model = nil }, expectFailure = true }, function() end)
end

return T
