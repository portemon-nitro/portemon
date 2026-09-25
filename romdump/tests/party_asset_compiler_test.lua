-- Selected-payload scenarios for the party asset compiler. Every fact here
-- is decoded from the canonical dump: archive census, animation periods and
-- durations, realized dimensions, and the feedback hide rule. No committed
-- commercial payloads: assertions are counts, durations, and dimensions.

local Assert = require("tests.support.Assert")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Lz10 = require("romdump.src.digest.Lz10")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function openParty(romFs)
  local archive = assert(romFs:openNarc("NARC_graphic_plist_gra"), "the party archive must resolve")
  Assert.equal(archive:memberCount(), 27, "the party archive carries all 27 members")
  return archive
end

local function plain(bytes)
  if string.byte(bytes, 1) == 0x10 then
    return assert(Lz10.decode(bytes))
  end
  return bytes
end

local function memberBytes(archive, memberId)
  return plain(assert(archive:readMember(memberId), "party member " .. memberId .. " must exist"))
end

function T.party_archive_resolves_through_the_raw_symbol(romFs, _)
  local entry = assert(romFs:resolvedNarc("NARC_graphic_plist_gra"), "the party symbol must resolve")
  Assert.equal(entry.narcId, 21)
  Assert.equal(entry.path, "a/0/2/1")
  openParty(romFs)
end

function T.icon_sequences_carry_the_expected_periods(romFs, _)
  local PartySources = require("romdump.src.config.PartySources")
  local archive = assert(romFs:openNarc(PartySources.iconShared.archive), "the icon archive must resolve")
  local animation = assert(
    G2dDecoder.decodeAnimation(memberBytes(archive, PartySources.iconShared.animationMember), { label = "icon anim" }),
    "the shared icon animation must decode"
  )
  local expected = { 1, 8, 12, 24, 40, 36 }
  Assert.equal(#animation.anims, 6, "six icon sequences are addressable")
  for sequenceNo, period in ipairs(expected) do
    local total = 0
    for _, frame in ipairs(animation.anims[sequenceNo].frames) do
      total = total + frame.duration
    end
    Assert.equal(total, period, "icon sequence " .. (sequenceNo - 1) .. " spans " .. period .. " ticks")
  end
  local replacement = animation.anims[6].frames
  Assert.deepEqual(
    { replacement[1].duration, replacement[2].duration, replacement[3].duration },
    { 32, 2, 2 },
    "the replacement sequence keeps its 32/2/2 keyframe durations"
  )
  Assert.deepEqual(
    { replacement[1].translateX, replacement[2].translateX, replacement[3].translateX },
    { 0, 1, -1 },
    "the replacement sequence keeps its 0/+1/-1 shifts"
  )
end

function T.status_archive_carries_seven_static_sequences(romFs, _)
  local archive = assert(romFs:openNarc("NARC_a_0_3_9"), "the status archive must resolve")
  local PartySources = require("romdump.src.config.PartySources")
  local animation = assert(
    G2dDecoder.decodeAnimation(memberBytes(archive, PartySources.status.animationMember), { label = "status anim" }),
    "the status animation must decode"
  )
  Assert.equal(#animation.anims, 7, "seven status sequences exist")
  for sequenceNo, sequence in ipairs(animation.anims) do
    Assert.equal(#sequence.frames, 1, "status sequence " .. (sequenceNo - 1) .. " is static")
  end
end

function T.feedback_animation_hides_at_frame_two(romFs, _)
  local archive = assert(romFs:openNarc("NARC_a_0_1_5"), "the feedback archive must resolve")
  local PartySources = require("romdump.src.config.PartySources")
  local animation = assert(
    G2dDecoder.decodeAnimation(memberBytes(archive, PartySources.feedback.animationMember), { label = "feedback anim" }),
    "the feedback animation must decode"
  )
  local sequence = animation.anims[PartySources.feedback.sequence + 1]
  Assert.notNil(sequence, "the feedback sequence is addressable")
  Assert.deepEqual(
    { sequence.frames[1].duration, sequence.frames[2].duration, sequence.frames[3].duration },
    { 3, 2, 1 },
    "feedback keeps its 3/2/1 cadence"
  )
end

function T.badge_sequences_six_and_seven_decode(romFs, _)
  local archive = assert(romFs:openNarc("NARC_a_1_6_2"), "the badge archive must resolve")
  local PartySources = require("romdump.src.config.PartySources")
  local animation = assert(
    G2dDecoder.decodeAnimation(memberBytes(archive, PartySources.badges.animationMember), { label = "badge anim" }),
    "the badge animation must decode"
  )
  Assert.notNil(animation.anims[PartySources.badges.leafSequence + 1], "leaf sequence 6 exists")
  Assert.notNil(animation.anims[PartySources.badges.crownSequence + 1], "crown sequence 7 exists")
  for _, sequenceNo in ipairs({ PartySources.badges.leafSequence, PartySources.badges.crownSequence }) do
    local sequence = animation.anims[sequenceNo + 1]
    Assert.isTrue(#sequence.frames > 0, "badge sequence " .. sequenceNo .. " carries frames")
    for _, frame in ipairs(sequence.frames) do
      Assert.isTrue(frame.duration > 0 and frame.duration % 1 == 0, "badge frame timing is integral")
    end
  end
end

function T.numeric_font_member5_layout(romFs, _)
  local archive = assert(romFs:openNarc("NARC_graphic_font"), "the font archive must resolve")
  local PartySources = require("romdump.src.config.PartySources")
  local bytes = memberBytes(archive, PartySources.numeric.member)
  Assert.isTrue(#bytes >= PartySources.numeric.levelOffset + 32, "member 5 reaches the level cell")
  Assert.equal(PartySources.numeric.slashOffset, 0x140)
  Assert.equal(PartySources.numeric.levelOffset, 0x160)
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
