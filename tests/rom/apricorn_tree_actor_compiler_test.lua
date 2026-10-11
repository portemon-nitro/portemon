-- ROM conformance: colored Apricorn trees are static ripe sprites; sprite 262
-- owns the shared animation timeline used for shaking and depleted trees.

local Assert = require("tests.support.Assert")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local ApricornSources = require("romdump.src.config.ApricornSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}
local colorSpriteIds = { 263, 264, 265, 266, 267, 268, 269 }

function T.colored_ripe_sprites_use_idle_frame_and_base_sprite_owns_gestures(romFs)
  local ripe = assert(FieldActorCompiler.compileSprites(romFs, colorSpriteIds))
  for _, spriteId in ipairs(colorSpriteIds) do
    local visual = assert(ripe.visuals[spriteId], "ripe Apricorn sprite is compiled")
    Assert.equal(visual.spriteId, spriteId)
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

return RomSuite.fromFacts(T)
