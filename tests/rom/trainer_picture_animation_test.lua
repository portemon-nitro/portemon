-- ROM-backed trainer portrait compilation preserves source blanking frames
-- as transparent images without dropping their sequence timing or attrs.

local Assert = require("tests.support.Assert")
local BattlePresentationCompiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.koga_objectless_animation_frames_compile_as_transparent(romFs)
  local archive = assert(romFs:openNarc("NARC_a_0_5_8"))
  local cells = assert(G2dDecoder.decodeCell(assert(archive:readMember(447))))
  local animation = assert(G2dDecoder.decodeAnimation(assert(archive:readMember(448))))
  for _, sequenceIndex in ipairs({ 2, 3 }) do
    local frame = assert(animation.anims[sequenceIndex].frames[1])
    Assert.equal(frame.cell, 3, "Koga blank phases reference the source objectless cell")
    Assert.equal(#cells.cells[frame.cell + 1].objs, 0, "the referenced source cell carries no objects")
    Assert.equal(frame.userAttr or 0, 0, "the blank phases carry no user-attribute transition")
  end
  Assert.equal(animation.anims[2].frames[1].duration, 20, "the throw sequence keeps its blank phase duration")
  Assert.equal(animation.anims[3].frames[1].duration, 4, "the entry sequence keeps its blank phase duration")

  local entries, slices = BattlePresentationCompiler.compileTrainerPictures(romFs)
  local koga = assert(entries["front:ELITE_FOUR_KOGA"])
  local sequences = assert(koga.animation and koga.animation.sequences)
  for sequenceIndex, duration in ipairs({ 20, 4 }) do
    local frame = assert(sequences[sequenceIndex + 1].frames[1])
    Assert.equal(frame.durationTicks, duration, "compiled blank phases retain source duration")
    Assert.equal(frame.userAttr, 0, "compiled blank phases retain source user attributes")
    Assert.deepEqual(frame.rasterOffset, { x = 0, y = 0 }, "blank cells have no source raster origin")
    local imageName = assert(frame.image:match("([^/]+)%.png$"))
    local image = assert(slices[imageName], "compiled blank phase has a staged raster")
    Assert.deepEqual(
      { image.width, image.height, image.pixels },
      { 1, 1, string.rep("\0", 4) },
      "objectless source frames stage a transparent pixel"
    )
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "producer", "trainer-pictures" }
return suite
