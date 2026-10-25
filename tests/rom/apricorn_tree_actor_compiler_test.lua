-- ROM conformance: colored Apricorn trees are static ripe sprites; sprite 262
-- owns the shared animation timeline used for shaking and depleted trees.

local Assert = require("tests.support.Assert")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local ApricornSources = require("romdump.src.config.ApricornSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}
local APRICORN_KEYS = {
  "RED_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
}

local function apricornSpriteIds(spritesByKey)
  local spriteIds = {}
  for _, apricornKey in ipairs(APRICORN_KEYS) do
    spriteIds[#spriteIds + 1] = assert(spritesByKey[apricornKey], "source Apricorn sprite identity is configured")
  end
  return spriteIds
end

function T.colored_ripe_sprites_use_idle_frame_and_base_sprite_owns_gestures(romFs)
  local colorSpriteIds = apricornSpriteIds(ApricornSources.treeSpriteIdByKey)
  local ripe = assert(FieldActorCompiler.compileSprites(romFs, colorSpriteIds))
  for index, apricornKey in ipairs(APRICORN_KEYS) do
    local spriteId = colorSpriteIds[index]
    Assert.equal(spriteId, 262 + index, apricornKey .. " uses the source ripe-tree sprite order")
    local visual = assert(ripe.visuals[spriteId], "ripe Apricorn sprite is compiled")
    Assert.equal(visual.spriteId, spriteId)
    Assert.equal(ripe.graphics.bySpriteId[spriteId].visualDescriptor, 21, "ripe tree uses the BONGURI descriptor")
    Assert.equal(#visual.frames, 1, "ripe sprite publishes its valid idle frame only")
    Assert.equal(visual.directions.north.walk.durationTicks, 1, "ripe sprite is static in the source idle range")
    Assert.keySet(visual.gestures, "")
  end

  local base = assert(FieldActorCompiler.compileSprites(romFs, { ApricornSources.depletedTreeSpriteId }))
  local visual = assert(base.visuals[ApricornSources.depletedTreeSpriteId])
  Assert.isTrue(#visual.frames > 1, "base tree has all source animation frames")
  Assert.notNil(visual.gestures.apricorn_tree_wiggle, "base tree carries the source wiggle clip")
  Assert.notNil(visual.gestures.apricorn_tree_expel, "base tree carries the source expel clip")
end

function T.generated_bundle_includes_depleted_tree_and_fruit_sprites(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  local compiled = {}
  for _, spriteId in ipairs(bundle.index.spriteIds) do
    compiled[spriteId] = true
  end

  local depletedTreeSpriteId = ApricornSources.depletedTreeSpriteId
  Assert.equal(depletedTreeSpriteId, 262, "BONGURI is the shared tree gesture and depleted-tree sprite")
  Assert.equal(bundle.provenance.records[depletedTreeSpriteId].visualDescriptor, 21)
  local depletedVisual = assert(bundle.visuals[depletedTreeSpriteId])
  Assert.notNil(depletedVisual.gestures.apricorn_tree_wiggle)
  Assert.notNil(depletedVisual.gestures.apricorn_tree_expel)
  Assert.isTrue(compiled[depletedTreeSpriteId], "generated field actor bundle lists the depleted tree sprite")
  Assert.notNil(bundle.atlases[depletedTreeSpriteId], "generated field actor bundle publishes the depleted tree atlas")
  local runtimeApricorn =
    assert(bundle.index.runtime.apricorn, "actor index publishes runtime Apricorn sprite identities")
  Assert.equal(runtimeApricorn.depletedTreeSpriteId, depletedTreeSpriteId)

  for index, apricornKey in ipairs(APRICORN_KEYS) do
    local ripeTreeSpriteId = ApricornSources.treeSpriteIdByKey[apricornKey]
    local fruitSpriteId = ApricornSources.fruitSpriteIdByKey[apricornKey]
    Assert.equal(ripeTreeSpriteId, 262 + index, apricornKey .. " maps to BONGURI's source color order")
    Assert.equal(fruitSpriteId, 269 + index, apricornKey .. " maps to BONMI's source color order")
    Assert.equal(runtimeApricorn.treeSpriteIdByKey[apricornKey], ripeTreeSpriteId)
    Assert.equal(runtimeApricorn.fruitSpriteIdByKey[apricornKey], fruitSpriteId)
    Assert.equal(bundle.provenance.records[ripeTreeSpriteId].visualDescriptor, 21)
    Assert.equal(bundle.provenance.records[fruitSpriteId].visualDescriptor, 22)

    for _, spriteId in ipairs({ ripeTreeSpriteId, fruitSpriteId }) do
      Assert.isTrue(compiled[spriteId], "generated field actor bundle lists Apricorn sprite " .. spriteId)
      Assert.notNil(bundle.visuals[spriteId], "generated field actor bundle compiles Apricorn sprite " .. spriteId)
      Assert.notNil(bundle.atlases[spriteId], "generated field actor bundle publishes Apricorn atlas " .. spriteId)
    end
  end
end

return RomSuite.fromFacts(T)
