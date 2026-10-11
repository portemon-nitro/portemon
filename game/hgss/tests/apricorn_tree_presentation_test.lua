local Assert = require("tests.support.Assert")
local ApricornTreePresentation = require("game.hgss.src.apricorn.ApricornTreePresentation")

local T = {}

local function treeActor()
  return {
    spriteId = 266,
    sourceEvent = {
      spriteId = 266,
      apricorn = { treeIndex = 6, apricornKey = "GRN_APRICORN" },
    },
    getWorldPosition = function()
      return { x = 2, y = 1, z = 3 }
    end,
  }
end

function T.uses_source_ripe_and_depleted_tree_sprites()
  local available = true
  local actor = treeActor()
  local presentation = ApricornTreePresentation.new({
    martService = {
      treeAvailable = function(_, treeIndex)
        Assert.equal(treeIndex, 6)
        return available
      end,
    },
  })

  Assert.equal(presentation:spriteIdForTree(actor), 266)
  available = false
  Assert.equal(presentation:spriteIdForTree(actor), 262)
end

function T.draws_the_color_fruit_along_the_source_jump_curve()
  local presentation = ApricornTreePresentation.new({
    actors = {
      getActor = function(_, actorId)
        Assert.equal(actorId, "map:34:object:2")
        return treeActor()
      end,
    },
    player = { facing = "north" },
  })
  presentation:spawnFruit("map:34:object:2", "GRN_APRICORN")
  local fruit = assert(presentation:drawRecord())
  Assert.equal(fruit.spriteId, 273)
  Assert.equal(fruit.world.x, 2)
  Assert.equal(fruit.world.y, 1.75)
  Assert.equal(fruit.world.z, 3)

  presentation:advanceFruit(0)
  fruit = assert(presentation:drawRecord())
  Assert.equal(fruit.world.x, 2)
  Assert.equal(fruit.world.y, 2)
  Assert.equal(fruit.world.z, 3 + 1 / 16)

  presentation:clearFruit()
  Assert.isNil(presentation:drawRecord())
end

return { tests = T }
