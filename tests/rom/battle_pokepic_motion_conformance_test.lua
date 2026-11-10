-- Real-dump conformance for battle send-out motion tracks: every species
-- and facing resolves a baked program, and every staged program bakes at
-- least one sample. No commercial bytes appear; the test asserts only
-- the structural contracts the runtime playback depends on.

local Assert = require("tests.support.Assert")
local Narc = require("libs.nds.src.nitro.Narc")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function openArchive(romFs, path, versionId)
  local bytes = romFs:readSourcePath(path)
  Assert.notNil(bytes, versionId .. " must expose source archive " .. path)
  return assert(Narc.open(assert(bytes), path))
end

function T.every_species_and_facing_resolves_a_baked_motion_track(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local meta = openArchive(romFs, "a/1/8/0", versionId)
  local animationBytes = assert(meta:readMember(0), versionId .. " exposes its picture metadata")
  local motion = openArchive(romFs, "a/0/9/0", versionId)
  local memberCount = motion:memberCount()
  Assert.isTrue(memberCount >= 1, versionId .. " stages at least one motion program")
  local motionWords = {}
  for programId = 0, memberCount - 1 do
    local member = assert(motion:readMember(programId), versionId .. " exposes program " .. programId)
    Assert.equal(#member % 4, 0, versionId .. " program " .. programId .. " is a word stream")
    local words = {}
    for offset = 1, #member, 4 do
      local unsigned = string.byte(member, offset)
        + string.byte(member, offset + 1) * 256
        + string.byte(member, offset + 2) * 65536
        + string.byte(member, offset + 3) * 16777216
      words[#words + 1] = unsigned >= 0x80000000 and unsigned - 0x100000000 or unsigned
    end
    motionWords[programId] = words
  end
  local speciesTracks, programTracks = compiler.compilePictureMotions(animationBytes, motionWords)
  for _, track in pairs(programTracks) do
    Assert.isTrue(#track.samples >= 1, versionId .. " programs bake at least one sample")
  end
  local headerCount = 0
  for key, header in pairs(speciesTracks) do
    headerCount = headerCount + 1
    Assert.isTrue(header.totalTicks >= 1, versionId .. " header " .. key .. " holds a send-out span")
    Assert.isTrue(programTracks[header.program] ~= nil, versionId .. " header " .. key .. " names a baked program")
  end
  Assert.isTrue(headerCount >= 1, versionId .. " bakes at least one species header")
end

return RomSuite.fromFacts(T)
