local Assert = require("tests.support.Assert")
local ApricornTreePresentation = require("game.hgss.src.apricorn.ApricornTreePresentation")

local T = {}

local function apricornAssets()
  return {
    depletedTreeSpriteId = 898,
    treeSpriteIdByKey = {
      RED_APRICORN = 901,
      YLW_APRICORN = 902,
      BLU_APRICORN = 903,
      GRN_APRICORN = 904,
      PNK_APRICORN = 905,
      WHT_APRICORN = 906,
      BLK_APRICORN = 907,
    },
    fruitSpriteIdByKey = {
      RED_APRICORN = 911,
      YLW_APRICORN = 912,
      BLU_APRICORN = 913,
      GRN_APRICORN = 914,
      PNK_APRICORN = 915,
      WHT_APRICORN = 916,
      BLK_APRICORN = 917,
    },
  }
end

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
    presentationState = function()
      return { gesturePose = nil }
    end,
  }
end

function T.uses_source_ripe_and_depleted_tree_sprites()
  local available = true
  local actor = treeActor()
  local presentation = ApricornTreePresentation.new({
    actors = {
      actorsOf = function()
        return { actor }
      end,
    },
    runtimeMap = { mapId = 1 },
    actorConfig = { apricorn = apricornAssets() },
    martService = {
      treeAvailable = function(_, treeIndex)
        Assert.equal(treeIndex, 6)
        return available
      end,
    },
  })

  Assert.equal(presentation:spriteIdForTree(actor), 904)
  available = false
  Assert.equal(presentation:spriteIdForTree(actor), 898)

  local spriteIds = {}
  presentation:collectSpriteIds(spriteIds)
  Assert.isTrue(spriteIds[898], "the generated depleted-tree sprite is prepared")
  Assert.isNil(spriteIds[262], "the presentation does not embed a source sprite ID")
end

function T.draws_the_color_fruit_along_the_source_jump_curve()
  local presentation = ApricornTreePresentation.new({
    actorConfig = { apricorn = apricornAssets() },
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
  Assert.equal(fruit.spriteId, 914)
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
