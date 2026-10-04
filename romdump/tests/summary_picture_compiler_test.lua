-- Compile-time picture contract for the native summary family: front-frame
-- records join their motion/palette programs into finite per-tick samples
-- with exact termination, and the consumer schema enforces that shape.
-- Synthetic inputs only; no dump required.

local Assert = require("tests.support.Assert")

local T = {}

local SUMMARY_SCHEMA = "g4-summary-manifest-v1"

local function requirePictureCompiler()
  local ok, compiler = pcall(require, "romdump.src.digest.ui.SummaryPictureCompiler")
  Assert.isTrue(
    ok,
    "the summary picture evaluator is missing: front-frame and motion programs have no compile-time owner"
  )
  Assert.equal(type(compiler.compile), "function", "the summary picture evaluator exposes its compile entrypoint")
  return compiler
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

local function skeletonManifest()
  return {
    schema = SUMMARY_SCHEMA,
    paneSize = { width = 256, height = 192 },
    groups = { info = groupShell(), skills = groupShell(), performance = groupShell() },
    windows = {},
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
    memo = {},
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
