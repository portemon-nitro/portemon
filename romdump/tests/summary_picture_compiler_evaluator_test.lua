-- Compile-time picture evaluator unit contract: hand-traced frame and
-- motion programs lower to exact per-tick samples, and every malformed
-- or missing input fails loudly. Synthetic archives only; no dump
-- required. Each trace below is transcribed independently from the
-- source recurrences, never from the evaluator output.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function requireCompiler()
  local ok, compiler = pcall(require, "romdump.src.digest.ui.SummaryPictureCompiler")
  Assert.isTrue(ok, "the summary picture evaluator is missing")
  return compiler
end

local function words(values)
  local parts = {}
  for _, value in ipairs(values) do
    local unsigned = value % 4294967296
    parts[#parts + 1] = string.char(
      unsigned % 256,
      math.floor(unsigned / 256) % 256,
      math.floor(unsigned / 65536) % 256,
      math.floor(unsigned / 16777216) % 256
    )
  end
  return table.concat(parts)
end

local function frameBytes(records)
  local parts = {}
  for _, record in ipairs(records) do
    local nextValue = record.next % 256
    parts[#parts + 1] = string.char(nextValue, record.duration % 256, record.x % 256, 0)
  end
  while #parts < 10 do
    parts[#parts + 1] = string.char(255, 0, 0, 0)
  end
  return table.concat(parts)
end

local function metadataBlob(specs)
  local records = {}
  for species = 0, 493 do
    local spec = specs[species] or { cry = 0, program = 0, delay = 0, frames = {} }
    local entry = string.char(spec.cry % 256, spec.program % 256, spec.delay % 256) .. frameBytes(spec.frames)
    local back = string.char(0, 0, 0) .. frameBytes({})
    records[#records + 1] = entry .. back .. string.char(0, 0, 0)
  end
  return table.concat(records)
end

local function romFsWith(metadataBytes, programs)
  local archives = {}
  local metadataArchive = {}
  function metadataArchive:readMember(memberId)
    if memberId == 0 then
      return metadataBytes
    end
    return nil
  end
  function metadataArchive:memberCount()
    return 1
  end
  archives.metadata = metadataArchive
  local motionArchive = {}
  function motionArchive:readMember(memberId)
    return programs[memberId]
  end
  function motionArchive:memberCount()
    local count = 0
    for id in pairs(programs) do
      count = math.max(count, id + 1)
    end
    return count
  end
  archives.motion = motionArchive
  local romFs = {}
  function romFs:openNarc(symbol)
    if symbol == "NARC_a_1_8_0" then
      return archives.metadata
    end
    if symbol == "NARC_a_0_9_0" then
      return archives.motion
    end
    return nil
  end
  return romFs
end

local function mustCompile(romFs, selections)
  local compiler = requireCompiler()
  local bundle, err = compiler.compile(romFs, selections)
  if bundle == nil then
    error("picture compilation failed: " .. tostring(err and err.code or err), 0)
  end
  return bundle
end

local function totalTicks(track)
  local total = 0
  for _, sample in ipairs(track.samples) do
    total = total + sample.durationTicks
  end
  return total
end

-- An empty frame script with an immediate end program yields one held
-- terminal sample: nothing advances, nothing blends, the track ends on
-- its first tick.
function T.empty_script_and_bare_end_hold_one_terminal_sample()
  local romFs = romFsWith(metadataBlob({}), { [0] = words({ 0 }) })
  local bundle = mustCompile(romFs, { { key = "still", species = 7 } })
  local track = assert(bundle.tracks.still, "the selection resolves")
  Assert.equal(#track.samples, 1, "one held sample")
  Assert.equal(track.samples[1].durationTicks, 1, "the sample spans its tick")
  Assert.equal(track.samples[1].frameIndex, 0, "the terminal frame shows")
  Assert.equal(track.samples[1].offsetX, 0, "no horizontal drift")
  Assert.equal(track.samples[1].offsetY, 0, "no vertical drift")
  Assert.equal(track.samples[1].scaleX, 1, "unit horizontal scale")
  Assert.equal(track.samples[1].scaleY, 1, "unit vertical scale")
  Assert.equal(track.samples[1].rotationTurns, 0, "no rotation")
  Assert.isTrue(track.samples[1].visible, "the picture shows")
  Assert.isNil(track.samples[1].paletteBlend, "no blend without a fade")
  Assert.notNil(track.terminal, "the track holds its terminal state")
  Assert.isNil(track.loopFrom, "a finished track names no cycle")
  Assert.equal(track.cryDelayTicks, 0, "the header cry delay survives")
end

-- A two-frame bounce lowers to its exact tick plan: five ticks on frame
-- zero, ten on frame one, one terminal tick on frame zero, then the hold.
function T.two_frame_bounce_matches_its_tick_plan()
  local frames = {
    { next = 0, duration = 4, x = 0 },
    { next = 1, duration = 10, x = 0 },
  }
  local romFs = romFsWith(metadataBlob({ [1] = { cry = 0, program = 2, delay = 0, frames = frames } }), {
    [2] = words({ 0 }),
  })
  local bundle = mustCompile(romFs, { { key = "bounce", species = 1 } })
  local track = assert(bundle.tracks.bounce, "the selection resolves")
  Assert.equal(#track.samples, 3, "three runs compress the bounce")
  Assert.equal(track.samples[1].frameIndex, 0, "the bounce opens on frame zero")
  Assert.equal(track.samples[1].durationTicks, 4, "duration four holds four ticks")
  Assert.equal(track.samples[2].frameIndex, 1, "the bounce swings to frame one")
  Assert.equal(track.samples[2].durationTicks, 11, "duration ten holds eleven ticks")
  Assert.equal(track.samples[3].frameIndex, 0, "the terminal tick rests on frame zero")
  Assert.equal(track.samples[3].durationTicks, 1, "the terminal tick holds once")
  Assert.equal(totalTicks(track), 16, "sixteen ticks in total")
  Assert.notNil(track.terminal, "the track holds its terminal state")
end

-- A counted loop repeats its body exactly three times: the accumulator
-- lands on eight, and the restore operation publishes it to the picture
-- origin before the end operation finishes the track.
function T.counted_loop_repeats_its_body_exactly()
  local romFs = romFsWith(metadataBlob({}), {
    [0] = words({ 4, 0, 5, 11, 3, 19, 0, 8, 12, 21, 1, 0 }),
  })
  local bundle = mustCompile(romFs, { { key = "looped", species = 3 } })
  local track = assert(bundle.tracks.looped, "the selection resolves")
  Assert.equal(totalTicks(track), 2, "the yield splits the burst across ticks")
  Assert.equal(track.samples[1].offsetX, 15, "three iterations accumulate fifteen")
  Assert.equal(track.samples[1].offsetY, 0, "the untouched vertical lane stays put")
  Assert.equal(track.samples[2].offsetX, 0, "the end operation restores the anchor")
  Assert.notNil(track.terminal, "the track holds its terminal state")
end

-- The restore operation publishes accumulator state to the picture: three
-- loop iterations add one each to the vertical lane, so the sample rests
-- eight above the anchor once restored.
function T.restore_publishes_accumulated_state()
  local romFs = romFsWith(metadataBlob({}), {
    [0] = words({ 20, 8, 20, 5, 22, 21, 1, 0 }),
  })
  local bundle = mustCompile(romFs, { { key = "restored", species = 3 } })
  local track = assert(bundle.tracks.restored, "the selection resolves")
  Assert.equal(totalTicks(track), 2, "the yield splits the burst across ticks")
  Assert.equal(track.samples[1].offsetX, 5, "the restore publishes the accumulator")
  Assert.equal(track.samples[1].offsetY, 0, "the untouched vertical lane stays put")
  Assert.equal(track.samples[2].offsetX, 0, "the end operation restores the anchor")
end

-- A two-tick wait delays the register write: the track spans four ticks
-- and compresses to one held sample because nothing visible changes.
function T.wait_delays_execution_across_ticks()
  local romFs = romFsWith(metadataBlob({}), {
    [0] = words({ 31, 2, 4, 0, 7, 0 }),
  })
  local bundle = mustCompile(romFs, { { key = "waiting", species = 3 } })
  local track = assert(bundle.tracks.waiting, "the selection resolves")
  Assert.equal(totalTicks(track), 4, "two idle ticks plus two burst ticks")
  Assert.notNil(track.terminal, "the track holds its terminal state")
end

-- A same-start-and-end fade blends exactly once at full strength toward
-- the white target, then the track ends with the tint held.
function T.same_start_end_fade_blends_once_at_full_strength()
  local romFs = romFsWith(metadataBlob({}), {
    [0] = words({ 32, 16, 16, 0, 1023, 1, 0 }),
  })
  local bundle = mustCompile(romFs, { { key = "flash", species = 3 } })
  local track = assert(bundle.tracks.flash, "the selection resolves")
  Assert.equal(totalTicks(track), 2, "the fade tick plus the end tick")
  for _, sample in ipairs(track.samples) do
    local blend = assert(sample.paletteBlend, "every sample carries the held tint")
    Assert.equal(blend.coefficient, 16, "full-strength coefficient")
    Assert.equal(blend.target.r, 31, "white target red")
    Assert.equal(blend.target.g, 31, "white target green")
    Assert.equal(blend.target.b, 0, "white target blue")
  end
end

-- A sine channel poses its accumulator on the burst tick, but without a
-- restore the picture never moves: the samples stay at their defaults.
function T.unrestored_channel_motion_stays_invisible()
  local romFs = romFsWith(metadataBlob({}), {
    [0] = words({ 27, 24, 0, 32, 38, 32, 98304, 0, 24, 25, 28, 0 }),
  })
  local bundle = mustCompile(romFs, { { key = "posed", species = 3 } })
  local track = assert(bundle.tracks.posed, "the selection resolves")
  for _, sample in ipairs(track.samples) do
    Assert.equal(sample.offsetX, 0, "no horizontal drift without restore")
    Assert.equal(sample.offsetY, 0, "no vertical drift without restore")
    Assert.equal(sample.scaleX, 1, "no horizontal scaling without restore")
    Assert.equal(sample.scaleY, 1, "no vertical scaling without restore")
  end
end

-- A restored sine channel drives the vertical scale on later ticks: the
-- second tick samples the exact source sine recurrence.
function T.restored_sine_channel_drives_vertical_scale()
  local romFs = romFsWith(metadataBlob({}), {
    [0] = words({ 27, 24, 0, 32, 38, 32, 98304, 0, 24, 24, 1, 0 }),
  })
  local bundle = mustCompile(romFs, { { key = "wobble", species = 3 } })
  local track = assert(bundle.tracks.wobble, "the selection resolves")
  Assert.isTrue(#track.samples > 1, "the channel animates across ticks")
  Assert.equal(track.samples[1].scaleY, 244 / 256, "the burst tick applies the posed accumulator")
  Assert.equal(track.samples[2].scaleY, 234 / 256, "the second tick matches the sine recurrence")
end

-- A program index past the archive falls back to program zero instead of
-- failing, transcribing the source index guard.
function T.out_of_range_program_falls_back_to_zero()
  local frames = {
    { next = 0, duration = 1, x = 0 },
  }
  local romFs = romFsWith(metadataBlob({ [9] = { cry = 0, program = 200, delay = 0, frames = frames } }), {
    [0] = words({ 0 }),
  })
  local bundle = mustCompile(romFs, { { key = "fallback", species = 9 } })
  local track = assert(bundle.tracks.fallback, "the selection resolves")
  Assert.notNil(track.terminal, "the fallback program terminates")
end

-- Every failure mode reports its owner: unreadable archives, malformed
-- metadata, missing programs, unknown operations, and division by zero.
function T.every_failure_mode_reports_its_owner()
  local compiler = requireCompiler()
  local goodMetadata = metadataBlob({})
  local goodPrograms = { [0] = words({ 0 }) }
  local function fails(romFs, selections, code)
    local bundle, err = compiler.compile(romFs, selections)
    Assert.isNil(bundle, "malformed input publishes nothing")
    Assert.isTrue(Errors.is(err), "malformed input fails structurally")
    Assert.equal(err.code, code, "the failure names its owner")
  end
  local noMotion = romFsWith(goodMetadata, goodPrograms)
  function noMotion:openNarc(symbol)
    if symbol == "NARC_a_0_9_0" then
      return nil
    end
    return romFsWith(goodMetadata, goodPrograms):openNarc(symbol)
  end
  fails(noMotion, { { key = "x", species = 1 } }, compiler.ERROR.SOURCE_INVALID)
  local shortMetadata = romFsWith("short", goodPrograms)
  fails(shortMetadata, { { key = "x", species = 1 } }, compiler.ERROR.SOURCE_INVALID)
  fails(romFsWith(goodMetadata, goodPrograms), { { key = "x", species = 494 } }, compiler.ERROR.SOURCE_INVALID)
  local missingProgram = romFsWith(goodMetadata, {})
  fails(missingProgram, { { key = "x", species = 1 } }, compiler.ERROR.SOURCE_INVALID)
  local badOpcode = romFsWith(goodMetadata, { [0] = words({ 99 }) })
  fails(badOpcode, { { key = "x", species = 1 } }, compiler.ERROR.EVALUATION_FAILED)
  local divZero = romFsWith(goodMetadata, { [0] = words({ 9, 2, 19, 18, 2, 0, 1 }) })
  fails(divZero, { { key = "x", species = 1 } }, compiler.ERROR.EVALUATION_FAILED)
end

local function stoppedScript()
  local script = {}
  for _ = 1, 10 do
    script[#script + 1] = { next = -1, duration = 0, xOffset = 0 }
  end
  return script
end

local function frameScript(records)
  local script = {}
  for _, record in ipairs(records) do
    script[#script + 1] = { next = record.next, duration = record.duration, xOffset = record.x or 0 }
  end
  while #script < 10 do
    script[#script + 1] = { next = -1, duration = 0, xOffset = 0 }
  end
  return script
end

local function wordArray(encoded)
  assert(#encoded % 4 == 0, "motion words arrive whole")
  local out = {}
  for offset = 1, #encoded, 4 do
    local unsigned = string.byte(encoded, offset)
      + string.byte(encoded, offset + 1) * 256
      + string.byte(encoded, offset + 2) * 65536
      + string.byte(encoded, offset + 3) * 16777216
    out[#out + 1] = unsigned >= 2147483648 and unsigned - 4294967296 or unsigned
  end
  return out
end

local function metadataEntry(spec)
  local parts = { string.char(spec.cry % 256, spec.program % 256, spec.delay % 256) }
  parts[#parts + 1] = frameBytes(spec.frames or {})
  return table.concat(parts)
end

-- Battle send-out playback reads the back-facing record: the second
-- 43-byte entry decodes its own header and frame script.
function T.battle_back_entry_decodes_the_second_facing_record()
  local compiler = requireCompiler()
  local frontFrames = { { next = 0, duration = 1, x = 0 } }
  local backFrames = { { next = 1, duration = 2, x = -4 } }
  local records = {}
  for species = 0, 493 do
    local front = { cry = 1, program = 2, delay = 3, frames = species == 1 and frontFrames or {} }
    local back = { cry = 7, program = 9, delay = 5, frames = species == 1 and backFrames or {} }
    records[#records + 1] = metadataEntry(front) .. metadataEntry(back) .. string.char(0, 0, 0)
  end
  local member = table.concat(records)
  local front = compiler.decodeBattleRecord(member, 1, 0)
  Assert.equal(front.cryDelay, 1, "the front entry keeps its cry delay")
  Assert.equal(front.program, 2, "the front entry keeps its program")
  Assert.equal(front.motionDelay, 3, "the front entry keeps its motion delay")
  Assert.equal(front.script[1].next, 0, "the front entry keeps its frame script")
  local back = compiler.decodeBattleRecord(member, 1, 1)
  Assert.equal(back.cryDelay, 7, "the back entry keeps its cry delay")
  Assert.equal(back.program, 9, "the back entry keeps its program")
  Assert.equal(back.motionDelay, 5, "the back entry keeps its motion delay")
  Assert.equal(back.script[1].next, 1, "the back entry keeps its frame script")
  Assert.equal(back.script[1].xOffset, -4, "the back entry keeps its frame offset")
end

-- Battle motion playback bakes program deltas without cell frames: the
-- counted loop accumulates fifteen horizontally, restores to the anchor,
-- and names no frame selection. Programs bake once per program identity
-- while delays and totals stay per-species headers, so both entry points
-- agree on the same samples.
function T.battle_motion_bakes_program_deltas_once_without_cell_frames()
  local compiler = requireCompiler()
  local programWords = wordArray(words({ 4, 0, 5, 11, 3, 19, 0, 8, 12, 21, 1, 0 }))
  local record = { cryDelay = 0, program = 0, motionDelay = 0, script = stoppedScript() }
  local baked = compiler.simulateBattleMotion(programWords, record)
  local samples = compiler.simulateBattleMotionSamples(programWords)
  Assert.deepEqual(samples.samples, baked.samples, "both entry points bake the same program samples")
  Assert.equal(#baked.samples, 2, "two runs: the pose and its restore")
  Assert.equal(baked.samples[1].dx, 15, "three iterations accumulate fifteen")
  Assert.equal(baked.samples[1].dy, 0, "the untouched vertical lane stays put")
  Assert.equal(baked.samples[1].durationTicks, 1, "the pose holds its tick")
  Assert.isNil(baked.samples[1].frameIndex, "motion samples name no cell frame")
  Assert.equal(baked.samples[2].dx, 0, "the end operation restores the anchor")
  Assert.equal(baked.endTick, 2, "the yield splits the burst across two ticks")
  Assert.equal(baked.delay, 0, "the header motion delay survives")
  Assert.equal(baked.cryDelay, 0, "the header cry delay survives")
end

-- Battle motion totals cover the whole send-out task: the motion delay
-- and program run while the cell script finishes later, so the hold
-- spans the longest lane.
function T.battle_motion_total_covers_delay_frame_and_fade_end()
  local compiler = requireCompiler()
  local record = {
    cryDelay = 4,
    program = 0,
    motionDelay = 2,
    script = frameScript({ { next = 0, duration = 4, x = 0 } }),
  }
  local baked = compiler.simulateBattleMotion(wordArray(words({ 0 })), record)
  Assert.equal(baked.samples[1].dx, 0, "the delay holds the anchor")
  Assert.equal(baked.samples[1].durationTicks, 3, "the delay plus the bare end tick compress")
  Assert.equal(baked.endTick, 5, "the five-tick cell lane outlasts the delayed motion")
  Assert.equal(baked.delay, 2, "the header motion delay survives")
  Assert.equal(baked.cryDelay, 4, "the header cry delay survives")
end

return { tests = T }
