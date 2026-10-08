-- Compile-time picture contract for the native summary family: front-frame
-- records join their motion/palette programs into finite per-tick samples
-- with exact termination, and the consumer schema enforces that shape.
-- Synthetic inputs only; no dump required.

local Assert = require("tests.support.Assert")

local T = {}

local SUMMARY_SCHEMA = "g4-summary-manifest-v2"

local function requirePictureCompiler()
  local ok, compiler = pcall(require, "romdump.src.digest.ui.SummaryPictureCompiler")
  Assert.isTrue(
    ok,
    "the summary picture evaluator is missing: front-frame and motion programs have no compile-time owner"
  )
  Assert.equal(type(compiler.compile), "function", "the summary picture evaluator exposes its compile entrypoint")
  return compiler
end

-- Synthetic motion-program harness for the native command families: every
-- word stream below is hand-encoded from the source word layout (operand
-- kinds that double as accumulator destinations, skipped reads that still
-- advance the program counter, paired opcodes), and every expectation was
-- traced from the native recurrence before the opcode dispatch was
-- factored. The frame script stays empty so all motion shows.
local function encodeWords(values)
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

local function emptyFrames()
  local parts = {}
  for _ = 1, 10 do
    parts[#parts + 1] = string.char(255, 0, 0, 0)
  end
  return table.concat(parts)
end

local function metadataWithProgram()
  local records = {}
  for _ = 0, 493 do
    local entry = string.char(0, 0, 0) .. emptyFrames()
    local back = string.char(0, 0, 0) .. emptyFrames()
    records[#records + 1] = entry .. back .. string.char(0, 0, 0)
  end
  return table.concat(records)
end

local function fakeMotionRomFs(program)
  local metadataBytes = metadataWithProgram()
  local programBytes = encodeWords(program)
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
  local motionArchive = {}
  function motionArchive:readMember(memberId)
    if memberId == 0 then
      return programBytes
    end
    return nil
  end
  function motionArchive:memberCount()
    return 1
  end
  local romFs = {}
  function romFs:openNarc(symbol)
    if symbol == "NARC_a_1_8_0" then
      return metadataArchive
    end
    if symbol == "NARC_a_0_9_0" then
      return motionArchive
    end
    return nil
  end
  return romFs
end

local function compileProgram(program)
  local compiler = requirePictureCompiler()
  local bundle, err = compiler.compile(fakeMotionRomFs(program), { { key = "probe", species = 3 } })
  if bundle == nil then
    error("the synthetic motion program must compile: " .. tostring(err and err.code), 0)
  end
  return assert(bundle.tracks.probe, "the selection resolves")
end

local function trackTicks(track)
  local total = 0
  for _, sample in ipairs(track.samples) do
    total = total + sample.durationTicks
  end
  return total
end

-- Every native command family lowers through the public compile boundary
-- to its exact per-tick samples: word consumption, accumulator
-- destinations, signed wrapping, loop/channel/fade timing and the
-- restore vocabulary all stay observable after dispatch factoring.
function T.motion_command_families_keep_exact_word_and_machine_behavior()
  local cases = {
    {
      program = { 4, 0, 7, 5, 0, 1, 3, 21, 0, 1, 17, 20, 2, 99, 13, 0, 2, 1, 0 },
      ticks = 2,
      samples = { { x = -109, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 7, 5, 0, 1, 3, 21, 0, 1, 15, 20, 2, 99, 13, 0, 2, 1, 0 },
      ticks = 2,
      samples = { { x = -208, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 5, 3, 20, 0, 10, 15, 21, 2, 0, 13, 0, 2, 1, 0 },
      ticks = 2,
      samples = { { x = -203, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 10, 6, 3, 18, 0, 4, 21, 1, 0 },
      ticks = 2,
      samples = { { y = 14, dur = 1 }, { y = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 6, 4, 1, 7, 7, 5, 19, 0, 1, 21, 1, 0 },
      ticks = 2,
      samples = { { sx = 1.1640625, dur = 1 }, { sx = 1, dur = 1 } },
    },
    {
      program = { 4, 0, 3, 4, 1, 4, 6, 0, 19, 0, 1, 21, 1, 0 },
      ticks = 2,
      samples = { { sx = 1.02734375, dur = 1 }, { sx = 1, dur = 1 } },
    },
    {
      program = { 4, 0, 8, 8, 0, 18, 19, 20, 0, 21, 1, 0 },
      ticks = 2,
      samples = { { sx = 1.046875, dur = 1 }, { sx = 1, dur = 1 } },
    },
    {
      program = { 4, 0, 20, 8, 0, 19, 18, 0, 8, 21, 1, 0 },
      ticks = 2,
      samples = { { y = 12, dur = 1 }, { y = 0, dur = 1 } },
    },
    {
      program = { 9, 0, 18, 18, 17, 5, 21, 1, 0 },
      ticks = 2,
      samples = { { y = 3, dur = 1 }, { y = 0, dur = 1 } },
    },
    {
      program = { 9, 0, 18, 18, -7, 2, 21, 1, 0 },
      ticks = 2,
      samples = { { y = -3, dur = 1 }, { y = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 20, 4, 1, 6, 9, 0, 19, 19, 0, 1, 21, 1, 0 },
      ticks = 2,
      samples = { { sx = 1.01171875, dur = 1 }, { sx = 1, dur = 1 } },
    },
    {
      program = { 10, 0, 18, 18, 17, 5, 21, 1, 0 },
      ticks = 2,
      samples = { { y = 2, dur = 1 }, { y = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 20, 4, 1, 6, 10, 0, 19, 19, 0, 1, 21, 1, 0 },
      ticks = 2,
      samples = { { sx = 1.0078125, dur = 1 }, { sx = 1, dur = 1 } },
    },
    {
      program = { 4, 0, 2147483647, 6, 0, 18, 0, 1, 21, 1, 0 },
      ticks = 2,
      samples = { { y = -2147483648, dur = 1 }, { y = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 5, 11, 2, 19, 0, 8, 12, 21, 1, 0 },
      ticks = 2,
      samples = { { x = 10, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 15, 1, 20, 130, 22, 1, 0 },
      ticks = 2,
      samples = { { y = 26, dur = 1 }, { y = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 3, 14, 0, 0, 1, 0 },
      ticks = 2,
      samples = { { x = 3, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 15, 0, 20, 5, 23, 1, 0 },
      ticks = 2,
      samples = { { x = 5, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 16, 0, 0, 20, 777, 20, 4096, 21, 1, 0 },
      ticks = 2,
      samples = { { sy = 7.12109375, dur = 1 }, { sy = 1, dur = 1 } },
    },
    {
      program = { 16, 0, 0, 21, 1, 20, 4096, 21, 1, 0 },
      ticks = 2,
      samples = { { sy = 7.12109375, dur = 1 }, { sy = 1, dur = 1 } },
    },
    {
      program = { 17, 0, 0, 20, 777, 20, 4096, 21, 1, 0 },
      ticks = 2,
      samples = { { sy = 15.78125, dur = 1 }, { sy = 1, dur = 1 } },
    },
    {
      program = { 4, 1, 4096, 17, 0, 0, 20, 777, 21, 1, 21, 1, 0 },
      ticks = 2,
      samples = { { rot = 0.0577392578125, dur = 1 }, { rot = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 4, 18, 0, 8, 19, 0, 8, 21, 1, 0 },
      ticks = 2,
      samples = { { x = 8, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 9, 23, 0, 8, 21, 1, 0 },
      ticks = 2,
      samples = { { x = 9, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 20, 8, 20, 5, 22, 22, 1, 0 },
      ticks = 2,
      samples = { { x = 5, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 20, 8, 20, 5, 22, 24, 1, 0 },
      ticks = 3,
      samples = { { x = 5, dur = 2 }, { x = 0, dur = 1 } },
    },
    {
      program = { 25, 28, 20, 8, 20, 5, 22, 21, 1, 0 },
      ticks = 2,
      samples = { { x = 5, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 26, 24, 0, 30, 38, 4096, 16, 0, 1, 24, 1, 0 },
      ticks = 3,
      samples = { { sy = 1.0234375, dur = 2 }, { sy = 1, dur = 1 } },
    },
    {
      program = { 27, 24, 0, 30, 38, 4096, 16, 0, 1, 24, 1, 0 },
      ticks = 3,
      samples = { { sy = 1.0234375, dur = 2 }, { sy = 1, dur = 1 } },
    },
    {
      program = { 28, 24, 0, 35, 2, 3, 2, 24, 1, 0 },
      ticks = 4,
      samples = { { x = 2, dur = 1 }, { x = 7, dur = 2 }, { x = 0, dur = 1 } },
    },
    {
      program = { 29, 24, 0, 35, 7, 3, 24, 1, 0 },
      ticks = 5,
      samples = { { x = 2, dur = 1 }, { x = 4, dur = 1 }, { x = 7, dur = 2 }, { x = 0, dur = 1 } },
    },
    {
      program = { 30, 24, 0, 35, 1, 2, 5, 24, 1, 0 },
      ticks = 5,
      samples = { { x = 1, dur = 1 }, { x = 4, dur = 1 }, { x = 5, dur = 2 }, { x = 0, dur = 1 } },
    },
    {
      program = { 4, 0, 9, 31, 1, 13, 0, 0, 1, 0 },
      ticks = 4,
      samples = { { x = 0, dur = 2 }, { x = -199, dur = 1 }, { x = 0, dur = 1 } },
    },
    {
      program = { 32, 2, 0, 0, 31, 33, 0 },
      ticks = 4,
      samples = {
        { blend = { 31, 0, 0, 2 }, dur = 1 },
        { blend = { 31, 0, 0, 1 }, dur = 1 },
        { dur = 2 },
      },
    },
    {
      program = { 4, 0, 9, 13, 0, 0, 2, 1, 0 },
      ticks = 2,
      samples = { { x = 0, dur = 2 } },
    },
  }
  for caseIndex, case in ipairs(cases) do
    local label = "motion case " .. caseIndex
    local track = compileProgram(case.program)
    Assert.equal(trackTicks(track), case.ticks, label .. ": tick count")
    Assert.equal(#track.samples, #case.samples, label .. ": sample count")
    for sampleIndex, want in ipairs(case.samples) do
      local got = track.samples[sampleIndex]
      local where = label .. " sample " .. sampleIndex
      Assert.equal(got.offsetX, want.x or 0, where .. ": horizontal offset")
      Assert.equal(got.offsetY, want.y or 0, where .. ": vertical offset")
      Assert.equal(got.scaleX, want.sx or 1, where .. ": horizontal scale")
      Assert.equal(got.scaleY, want.sy or 1, where .. ": vertical scale")
      Assert.equal(got.rotationTurns, want.rot or 0, where .. ": rotation")
      if want.blend ~= nil then
        local blend = assert(got.paletteBlend, where .. ": blend shows")
        Assert.equal(blend.target.r, want.blend[1], where .. ": blend red")
        Assert.equal(blend.target.g, want.blend[2], where .. ": blend green")
        Assert.equal(blend.target.b, want.blend[3], where .. ": blend blue")
        Assert.equal(blend.coefficient, want.blend[4], where .. ": blend strength")
      else
        Assert.isNil(got.paletteBlend, where .. ": no blend")
      end
      Assert.equal(got.durationTicks, want.dur, where .. ": tick span")
    end
    Assert.notNil(track.terminal, label .. ": the track holds its terminal state")
    Assert.isNil(track.loopFrom, label .. ": a finished track names no cycle")
  end
end

-- Truncated operands, unknown kinds and opcodes, and misused loops keep
-- their strict malformed-source failures: no handler guesses a default
-- operand or publishes a partial track.
function T.malformed_motion_streams_fail_without_default_operands()
  local Errors = require("libs.errors.src.Errors")
  local compiler = requirePictureCompiler()
  local programs = {
    { 4 },
    { 3, 153 },
    { 3, 20, 0, 5, 99 },
    { 99 },
    { 11, 2, 11, 3 },
    { 12 },
    { 4, 9, 0, 5 },
    { 9, 0, 18, 18, 5, 0 },
    { 15, 0, 20, 5, 99 },
    { 18, 0, 7 },
    { 25, 99 },
    { 28, 24, 0, 99, 1, 1, 1 },
    { 20, 8 },
    { 16, 0, 0, 99 },
    { 8, 0, 18 },
  }
  for caseIndex, program in ipairs(programs) do
    local label = "malformed motion case " .. caseIndex
    local bundle, err = compiler.compile(fakeMotionRomFs(program), { { key = "probe", species = 3 } })
    Assert.isNil(bundle, label .. ": malformed input publishes nothing")
    Assert.isTrue(Errors.is(err), label .. ": malformed input fails structurally")
    Assert.equal(err.code, compiler.ERROR.EVALUATION_FAILED, label .. ": the failure names its owner")
  end
end

-- Representative compiled pictures need a ready user-owned dump: without
-- one this gate stays explicitly unverified instead of passing on
-- synthetic data alone.
function T.representative_pictures_compile_from_the_ready_dump(context)
  if context == nil or type(context.hasCapability) ~= "function" or not context:hasCapability("rom_dump") then
    Assert.isTrue(context ~= nil, "the runner provides a skip context without a ready dump")
    context:skip("representative picture equivalence needs a ready user-owned dump")
  end
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local RomFs = require("romdump.src.source.RomFs")
  local compiler = requirePictureCompiler()
  local selections = {
    { key = "bulbasaur", species = 1 },
    { key = "pikachu", species = 25 },
    { key = "mewtwo", species = 150 },
    { key = "chikorita", species = 152 },
    { key = "piplup", species = 387 },
    { key = "arceus", species = 493 },
    { key = "egg", species = 25, egg = true },
  }
  local exercised = false
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      exercised = true
      local romFs, openErr = RomFs.open(versionId)
      Assert.isTrue(romFs ~= nil, "the ready dump opens: " .. tostring(openErr))
      assert(romFs ~= nil, "unopenable dumps fail above")
      local bundle, err = compiler.compile(romFs, selections)
      Assert.isTrue(bundle ~= nil, "representative pictures compile: " .. tostring(err and err.code))
      assert(bundle ~= nil, "failed pictures fail above")
      for _, selection in ipairs(selections) do
        local track = bundle.tracks[selection.key]
        Assert.notNil(track, versionId .. " " .. selection.key .. ": the selection resolves")
        Assert.isTrue(#track.samples >= 1, versionId .. " " .. selection.key .. ": samples exist")
        local ticks = 0
        for _, sample in ipairs(track.samples) do
          Assert.isTrue(
            sample.durationTicks >= 1 and sample.durationTicks % 1 == 0,
            versionId .. " " .. selection.key .. ": positive integral spans"
          )
          ticks = ticks + sample.durationTicks
        end
        Assert.isTrue(
          ticks >= 1 and ticks <= compiler.TICK_BUDGET,
          versionId .. " " .. selection.key .. ": the track terminates"
        )
        local hasEnd = track.terminal ~= nil
        local hasLoop = track.loopFrom ~= nil
        Assert.isTrue(hasEnd ~= hasLoop, versionId .. " " .. selection.key .. ": exactly one ending")
        if hasLoop then
          Assert.isTrue(
            track.loopFrom ~= nil and track.loopFrom >= 1 and track.loopFrom <= #track.samples,
            versionId .. " " .. selection.key .. ": the cycle restarts inside its track"
          )
        end
      end
      romFs:close()
    end
  end
  Assert.isTrue(exercised, "a ready dump backs the representative check")
end

local function requireSchema()
  local ok, schema = pcall(require, "libs.assets.src.SummaryAssetSchema")
  Assert.isTrue(ok, "the summary consumer schema is missing: picture tracks have no strict gate")
  return schema
end

local function stringLeaves(value, out)
  if type(value) == "string" then
    out[#out + 1] = value
  elseif type(value) == "table" then
    for _, child in pairs(value) do
      stringLeaves(child, out)
    end
  end
end

local function numberLeaves(value, out)
  if type(value) == "number" then
    out[#out + 1] = value
  elseif type(value) == "table" then
    for _, child in pairs(value) do
      numberLeaves(child, out)
    end
  end
end

-- The picture closure depends on both halves of the animation input: the
-- front metadata archive and the motion-program archive both belong to the
-- producer inventory.
function T.picture_inventory_covers_frames_and_motion_programs()
  local ok, sources = pcall(require, "romdump.src.config.SummarySources")
  Assert.isTrue(ok, "the summary source catalog is missing: picture inputs have no producer owner")
  local strings = {}
  stringLeaves(sources, strings)
  local seen = {}
  for _, leaf in ipairs(strings) do
    seen[leaf] = true
  end
  Assert.isTrue(seen["a/1/8/0"] == true, "the picture metadata archive is absent from the producer inventory")
  Assert.isTrue(seen["a/0/9/0"] == true, "the motion-program archive is absent from the producer inventory")
  local numbers = {}
  numberLeaves(sources, numbers)
  local counts = {}
  for _, leaf in ipairs(numbers) do
    counts[leaf] = true
  end
  Assert.isTrue(counts[494] == true, "the 494 metadata records are absent from the producer inventory")
  Assert.isTrue(counts[89] == true, "the 89-byte metadata record is absent from the producer inventory")
end

function T.picture_evaluator_boundary_names_its_owner()
  requirePictureCompiler()
end

local function groupShell()
  return { main = {}, sub = {} }
end

-- Synthetic semantic layout with the source-pinned per-pane role census
-- (info 2/6, skills 8/10, performance 5/3) plus one ordered memo branch:
-- picture-shape tests need a schema-valid envelope so rejections
-- attribute to the picture track under test.
local GROUP_ROLE_CENSUS = { info = { main = 2, sub = 6 }, skills = { main = 8, sub = 10 }, performance = { main = 5, sub = 3 } }

local function semanticRole(pane, seed)
  return {
    pane = pane,
    rect = { x = 8, y = 8 + (seed * 16) % 176, width = 64, height = 8 },
    palette = 13,
    ink = "ordinary",
  }
end

local function semanticWindows()
  local fixed = { synHeader = semanticRole("sub", 0) }
  local groups = {}
  for group, census in pairs(GROUP_ROLE_CENSUS) do
    groups[group] = { main = {}, sub = {} }
    for pane, count in pairs(census) do
      for index = 1, count do
        groups[group][pane]["syn" .. group .. pane .. index] = semanticRole(pane, index)
      end
    end
  end
  return { fixed = fixed, groups = groups }
end

local function semanticMemo()
  return {
    conditions = {
      {
        key = "synBranch",
        selectable = true,
        match = { isEgg = false, fateful = false, mine = true, metLocation = "wild" },
        lines = { nature = 1, date = 2, characteristic = 6, flavor = 7, eggWatch = 0 },
        dateTemplate = {
          segments = {
            { kind = "text", value = "SYN" },
            { kind = "metMonth" },
            { kind = "lineBreak" },
            { kind = "metLocation" },
          },
        },
      },
    },
    locations = { palPark = 55, linkTrade = 4001, linkTrade2 = 4002, ranger = 6001, giftEggOrigins = { 4009 } },
    migrationRegions = { heartgold = "synRegion", soulsilver = "synRegion" },
  }
end

local function skeletonManifest()
  return {
    schema = SUMMARY_SCHEMA,
    paneSize = { width = 256, height = 192 },
    groups = { info = groupShell(), skills = groupShell(), performance = groupShell() },
    windows = semanticWindows(),
    visuals = {},
    sprites = {},
    hitboxes = {},
    text = {},
    palettes = {},
    bars = {},
    pictures = {},
    ribbons = {},
    performance = {},
    dexNumbers = {},
    memo = semanticMemo(),
    sounds = {},
    transitions = {},
  }
end

local function finitePicture()
  return {
    portrait = "EXEMPLAR_PORTRAIT",
    cryDelayTicks = 0,
    samples = {
      {
        durationTicks = 2,
        frameIndex = 0,
        offsetX = 0,
        offsetY = 0,
        scaleX = 1,
        scaleY = 1,
        rotationTurns = 0,
        visible = true,
      },
    },
    terminal = {},
  }
end

-- A finished animation holds one terminal state; a looping animation names
-- its cycle restart. Carrying both, or neither, is malformed: the runtime
-- must never guess whether to hold or to repeat.
function T.picture_track_carries_exactly_one_ending()
  local schema = requireSchema()
  local both = skeletonManifest()
  both.pictures = { exemplar = finitePicture() }
  both.pictures.exemplar.loopFrom = 1
  Assert.isTrue(pcall(schema.assertManifest, both) == false, "a track with terminal and loop must not validate")
  local neither = skeletonManifest()
  neither.pictures = { exemplar = finitePicture() }
  neither.pictures.exemplar.terminal = nil
  Assert.isTrue(pcall(schema.assertManifest, neither) == false, "a track with no ending must not validate")
end

-- Source control records carry no runtime duration: a zero-length sample
-- frame is malformed, never a held frame.
function T.picture_samples_carry_positive_integral_ticks()
  local schema = requireSchema()
  local manifest = skeletonManifest()
  manifest.pictures = { exemplar = finitePicture() }
  manifest.pictures.exemplar.samples[1].durationTicks = 0
  Assert.isTrue(pcall(schema.assertManifest, manifest) == false, "a zero-duration sample must not validate")
end

-- Sample geometry is finite source arithmetic: NaN is never a valid offset.
function T.picture_samples_reject_nonfinite_geometry()
  local schema = requireSchema()
  local manifest = skeletonManifest()
  manifest.pictures = { exemplar = finitePicture() }
  manifest.pictures.exemplar.samples[1].offsetX = 0 / 0
  Assert.isTrue(pcall(schema.assertManifest, manifest) == false, "a non-finite sample offset must not validate")
end

-- A cycle restart must land inside its own track.
function T.picture_loop_restart_stays_inside_its_track()
  local schema = requireSchema()
  local manifest = skeletonManifest()
  manifest.pictures = { exemplar = finitePicture() }
  manifest.pictures.exemplar.terminal = nil
  manifest.pictures.exemplar.loopFrom = 4
  Assert.isTrue(pcall(schema.assertManifest, manifest) == false, "a loop past the last sample must not validate")
end

return { tests = T }
