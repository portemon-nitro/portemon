-- Fixed-tick sampling of compiled picture tracks: the player exposes the
-- authored initial sample, consumes exactly one duration unit per fixed
-- update, holds finite terminals, cycles proved loops, and emits a delayed
-- cry cue exactly once. Status reads never advance playback, disposal
-- before the cry stays silent, and malformed definitions fail upfront.

local Assert = require("tests.support.Assert")

local HAVE_PLAYER, PicturePlayer = pcall(require, "libs.hgss.src.ui.SummaryPicturePlayer")

local function playerOf(definition, epoch)
  Assert.isTrue(HAVE_PLAYER, "the picture player samples compiled tracks once per native tick")
  return PicturePlayer.new(definition, epoch)
end

local function sample(frameIndex, durationTicks)
  return {
    durationTicks = durationTicks,
    frameIndex = frameIndex,
    offsetX = 0,
    offsetY = 0,
    scaleX = 1,
    scaleY = 1,
    rotationTurns = 0,
    visible = true,
  }
end

local function definition(samples, extra)
  extra = extra or {}
  return {
    portrait = "SYN",
    cryDelayTicks = extra.cryDelayTicks,
    samples = samples,
    loopFrom = extra.loopFrom,
    terminal = {},
  }
end

local function traceFrames(player, ticks)
  local frames = {}
  for _ = 1, ticks do
    player:updateFixed()
    frames[#frames + 1] = player:status().frameIndex
  end
  return frames
end

local function traceIndices(player, ticks)
  local indices = {}
  for _ = 1, ticks do
    player:updateFixed()
    indices[#indices + 1] = player:status().sampleIndex
  end
  return indices
end

local T = {}

function T.starts_on_the_authored_initial_sample_without_consuming_it()
  local player = playerOf(definition({ sample(3, 2), sample(7, 3) }), 0)
  player:start()
  local status = player:status()
  Assert.equal(status.sampleIndex, 1, "playback begins on the first sample")
  Assert.equal(status.frameIndex, 3, "playback begins on the authored frame")
  Assert.equal(status.epoch, 0, "status carries the picture epoch")
  Assert.deepEqual(player:takeEffects(), {}, "starting schedules but never emits")
  Assert.equal(player:status().sampleIndex, 1, "status reads never advance the track")
  Assert.equal(player:status().frameIndex, 3, "status reads hold the authored frame")
  player:updateFixed()
  Assert.equal(player:status().frameIndex, 3, "the first tick consumes duration, not the sample")
end

function T.consumes_one_duration_unit_per_fixed_tick_and_holds_the_terminal()
  local player = playerOf(definition({ sample(3, 2), sample(7, 3) }), 0)
  player:start()
  Assert.deepEqual(
    traceFrames(player, 8),
    { 3, 7, 7, 7, 7, 7, 7, 7 },
    "each tick consumes one duration unit, then the finite terminal holds"
  )
  Assert.equal(player:status().sampleIndex, 2, "the terminal sample stays selected")
  Assert.equal(player:status().frameIndex, 7, "the terminal frame stays visible")
end

function T.cycles_the_proved_loop_without_replaying_the_prefix()
  local player = playerOf(definition({ sample(1, 1), sample(2, 1), sample(3, 1) }, { loopFrom = 2 }), 0)
  player:start()
  Assert.equal(player:status().frameIndex, 1, "loops still open on the authored sample")
  Assert.deepEqual(traceFrames(player, 5), { 2, 3, 2, 3, 2 }, "playback cycles from the proved entry")
  Assert.deepEqual(traceIndices(player, 4), { 3, 2, 3, 2 }, "cycle indices skip the prefix")
end

function T.emits_the_delayed_cry_once_then_goes_quiet()
  local player = playerOf(definition({ sample(3, 1), sample(7, 1) }, { cryDelayTicks = 3 }), 0)
  player:start()
  Assert.deepEqual(player:takeEffects(), {}, "the cry waits out its delay")
  player:updateFixed()
  Assert.deepEqual(player:takeEffects(), {}, "the cry stays quiet on its first tick")
  player:updateFixed()
  Assert.deepEqual(player:takeEffects(), {}, "the cry stays quiet on its second tick")
  player:updateFixed()
  local effects = player:takeEffects()
  Assert.equal(#effects, 1, "the cry emits exactly once")
  Assert.equal(effects[1].kind, "cry", "the delayed cue is a cry")
  Assert.deepEqual(player:takeEffects(), {}, "drained cues never repeat")
  player:updateFixed()
  player:updateFixed()
  Assert.deepEqual(player:takeEffects(), {}, "later ticks stay quiet")
end

function T.definitions_without_a_cry_stay_silent()
  local player = playerOf(definition({ sample(3, 1), sample(7, 1) }), 0)
  player:start()
  for _ = 1, 10 do
    player:updateFixed()
    Assert.deepEqual(player:takeEffects(), {}, "silent definitions emit nothing")
  end
end

function T.disposal_before_the_cry_emits_nothing_after_close()
  local player = playerOf(definition({ sample(3, 1), sample(7, 1) }, { cryDelayTicks = 3 }), 0)
  player:start()
  player:updateFixed()
  player:dispose()
  player:updateFixed()
  player:updateFixed()
  player:updateFixed()
  Assert.deepEqual(player:takeEffects(), {}, "disposal drops the pending cry")
end

function T.rejects_malformed_definitions_before_playback()
  Assert.isTrue(HAVE_PLAYER, "the picture player samples compiled tracks once per native tick")
  Assert.throws(function()
    PicturePlayer.new(nil, 0)
  end, "a missing definition fails")
  Assert.throws(function()
    PicturePlayer.new({}, 0)
  end, "a definition without samples fails")
  Assert.throws(function()
    PicturePlayer.new(definition({}), 0)
  end, "an empty sample list fails")
  Assert.throws(function()
    PicturePlayer.new(definition({ sample(3, 0) }), 0)
  end, "a zero-duration sample fails")
  Assert.throws(function()
    PicturePlayer.new(definition({ sample(3, -1) }), 0)
  end, "a negative duration fails")
  Assert.throws(function()
    PicturePlayer.new(definition({ sample(3, 1) }), nil)
  end, "a missing epoch fails")
end

return { tests = T }
