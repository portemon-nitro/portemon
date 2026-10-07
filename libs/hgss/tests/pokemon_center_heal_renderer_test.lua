local Assert = require("tests.support.Assert")

local T = { tests = {} }

T.tests["draws each live healing model at its world position and releases it"] = function()
  local moduleNames = {
    "libs.hgss.src.presentation.ModelDefinition",
    "libs.hgss.src.presentation.ModelInstance",
    "libs.hgss.src.presentation.SceneDescriptor",
    "libs.hgss.src.presentation.PokemonCenterHealRenderer",
  }
  local saved = {}
  for _, name in ipairs(moduleNames) do
    saved[name] = package.loaded[name]
  end
  local instanceCounts = { created = 0, updated = 0, drawn = 0 }
  package.loaded["libs.hgss.src.presentation.ModelDefinition"] = {
    fromNitroDescriptor = function()
      return { meshes = { { id = 1, geometry = "ball-mesh" } } }
    end,
  }
  package.loaded["libs.hgss.src.presentation.ModelInstance"] = {
    new = function()
      instanceCounts.created = instanceCounts.created + 1
      local instance = { transform = nil, completed = false }
      function instance:play(name, options)
        Assert.equal(name, "pc_mb")
        Assert.equal(options.loopMode, "once")
        local player = { completed = false }
        function player:isComplete()
          return self.completed
        end
        self.animationPlayer = player
        return { player = player }
      end
      function instance:updateFixed()
        instanceCounts.updated = instanceCounts.updated + 1
        self.animationPlayer.completed = true
      end
      function instance:evaluatePose() end
      function instance:drawItems()
        instanceCounts.drawn = instanceCounts.drawn + 1
        return { { transform = self.transform } }
      end
      return instance
    end,
  }
  package.loaded["libs.hgss.src.presentation.SceneDescriptor"] = {
    wrapByMaterial = function()
      return {}
    end,
  }
  package.loaded["libs.hgss.src.presentation.PokemonCenterHealRenderer"] = nil
  local ok, err = pcall(function()
    local Renderer = require("libs.hgss.src.presentation.PokemonCenterHealRenderer")
    local pool = {
      build = function(_, fn)
        fn()
      end,
      meshFor = function(_, path)
        Assert.equal(path, "ball-mesh")
        return { mesh = {}, center = { 0, 0, 0 } }
      end,
      imageFor = function() end,
    }
    local renderer =
      Renderer.new({ definition = { models = { { dynamic = {}, materials = {} } }, ballAnimation = "pc_mb" } }, pool)
    local handle = renderer:newBall({ x = -4.5, y = 12, z = -4.5 }, { role = "northwest" }, 1)
    handle:startAnimation()
    Assert.isFalse(handle:isFinished())
    handle:updateFixed()
    Assert.equal(instanceCounts.updated, 1, "the flow handle advances the model's fixed clock")
    Assert.isTrue(handle:isFinished(), "the generated clip completes through ModelInstance's play handle")
    local draws = renderer:drawItems({
      balls = { { index = 1, position = { x = -4.5, y = 12, z = -4.5 } } },
    })
    Assert.equal(instanceCounts.created, 1)
    Assert.equal(instanceCounts.drawn, 1)
    Assert.equal(#draws, 1)
    Assert.equal(draws[1].transform[13], -4.5)
    Assert.equal(draws[1].transform[14], 12)
    Assert.equal(draws[1].transform[15], -4.5)
    Assert.equal(draws[1].fieldEffect, "pokemon_center_heal")
    handle:dispose()
    Assert.equal(#renderer:drawItems({ balls = {} }), 0)
    renderer:dispose()
  end)
  for _, name in ipairs(moduleNames) do
    package.loaded[name] = saved[name]
  end
  Assert.isTrue(ok, tostring(err))
end

return T
