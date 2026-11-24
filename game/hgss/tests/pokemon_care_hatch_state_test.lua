-- The hatch application's scene state machine: the source frame order from the
-- fade through the shake, burst, cry, fanfare and nickname question, the
-- particle requests the scene makes, and the source answers the task reads.
-- Frames, effects and waits are fixed ticks; no audio device, graphics or ROM
-- is involved.

local Assert = require("tests.support.Assert")
local EggHatchState = require("game.hgss.src.field.EggHatchState")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")

local T = { tests = {} }

local PHASES = PokemonCareInterface.HATCH_PHASES

-- A recording audio host with the source queries the scene polls.
local function recordingAudio(options)
  local record = { effects = {}, cries = 0, fanfarePolls = (options and options.fanfarePolls) or 0 }
  record.play = function(_, sound)
    record.effects[#record.effects + 1] = "audio:" .. sound
  end
  record.playMusic = function(_, music)
    record.effects[#record.effects + 1] = "music:" .. music
  end
  record.playFanfare = function(_, fanfare)
    record.effects[#record.effects + 1] = "fanfare:" .. fanfare
  end
  record.playCry = function()
    record.cries = record.cries + 1
  end
  record.isCryFinished = function()
    return true
  end
  record.isFanfarePlaying = function()
    if record.fanfarePolls <= 0 then
      return false
    end
    record.fanfarePolls = record.fanfarePolls - 1
    return true
  end
  return record
end

local function scene(variant, options)
  return EggHatchState.new({
    variant = variant or "egg",
    species = 172,
    form = 0,
    audio = recordingAudio(options),
    hatched = { messageId = 0, frames = 2 },
    question = { messageId = 1, frames = 2 },
  })
end

---@param state table hatch scene
---@param predicate fun(phase: string): boolean
---@param limit integer?
local function advanceUntil(state, predicate, limit)
  for _ = 1, limit or 2000 do
    if predicate(state:phase()) then
      return
    end
    state:updateFixed(nil)
  end
  error("the hatch scene never reached the requested phase; phase=" .. tostring(state:phase()), 0)
end

function T.tests.the_scene_starts_music_after_the_fade()
  local audio = recordingAudio()
  local state = EggHatchState.new({
    variant = "egg",
    species = 172,
    form = 0,
    audio = audio,
    hatched = { messageId = 0, frames = 2 },
    question = { messageId = 1, frames = 2 },
  })
  advanceUntil(state, function(phase)
    return phase == PHASES.WAIT_BEFORE_SHAKE
  end)
  Assert.deepEqual(audio.effects, { "music:SEQ_GS_SHINKA" }, "the fade ends before the scene music starts")
  advanceUntil(state, function()
    return #audio.effects >= 2
  end)
  Assert.equal(audio.effects[2], "audio:SEQ_SE_DP_EGG01", "the first source shake sound follows the wait")
end

function T.tests.the_egg_shakes_four_times_before_the_fanfare()
  local audio = recordingAudio()
  local state = EggHatchState.new({
    variant = "egg",
    species = 172,
    form = 0,
    audio = audio,
    hatched = { messageId = 0, frames = 2 },
    question = { messageId = 1, frames = 2 },
  })
  advanceUntil(state, function(phase)
    return phase == PHASES.CHOOSE_NICKNAME
  end)
  local shakes = 0
  local burstPosition = nil
  local fanfarePosition = nil
  for index, effect in ipairs(audio.effects) do
    if effect == "audio:SEQ_SE_DP_EGG01" then
      shakes = shakes + 1
    elseif effect == "audio:SEQ_SE_DP_BOWA3" then
      burstPosition = burstPosition or index
    elseif effect == "fanfare:SEQ_ME_SHINKAOME" then
      fanfarePosition = fanfarePosition or index
    end
  end
  Assert.equal(shakes, 4, "the egg shakes exactly four times before it cracks")
  Assert.notNil(burstPosition, "the egg bursts")
  Assert.notNil(fanfarePosition, "the scene plays the hatch fanfare")
  Assert.isTrue(
    assert(burstPosition) < assert(fanfarePosition),
    "the fanfare follows the burst in source order"
  )
  Assert.equal(audio.cries, 1, "the reveal plays the hatched record's cry once")
  Assert.isTrue(state:snapshot().question, "the nickname question is on screen once it printed")
end

function T.tests.the_scene_requests_the_source_particles()
  local state = EggHatchState.new({
    variant = "egg",
    species = 172,
    form = 0,
    audio = recordingAudio(),
    hatched = { messageId = 0, frames = 2 },
    question = { messageId = 1, frames = 2 },
  })
  local requested = {}
  for _ = 1, 2000 do
    state:updateFixed(nil)
    for _, emitterId in ipairs(state:snapshot().particles --[[@as integer[] ]]) do
      requested[#requested + 1] = emitterId
    end
    if state:phase() == PHASES.CHOOSE_NICKNAME then
      break
    end
  end
  Assert.deepEqual(requested, { 0, 1, 2, 3 }, "the egg scene emits its four source emitters in order")
end

function T.tests.the_manaphy_scene_runs_its_own_frames_and_emitters()
  local audio = recordingAudio()
  local state = EggHatchState.new({
    variant = "manaphy",
    species = 490,
    form = 0,
    audio = audio,
    hatched = { messageId = 0, frames = 2 },
    question = { messageId = 1, frames = 2 },
  })
  local requested = {}
  for _ = 1, 2000 do
    state:updateFixed(nil)
    for _, emitterId in ipairs(state:snapshot().particles --[[@as integer[] ]]) do
      requested[#requested + 1] = emitterId
    end
    if state:phase() == PHASES.CHOOSE_NICKNAME then
      break
    end
  end
  Assert.equal(state:snapshot().variant, "manaphy", "the scene keeps its own variant")
  for _, effect in ipairs(audio.effects) do
    Assert.isTrue(effect ~= "audio:SEQ_SE_DP_EGG01", "the Manaphy scene runs no egg-shake sound")
  end
  Assert.deepEqual(requested, { 0, 1, 2, 3 }, "the Manaphy scene emits its four emitters once")
  Assert.equal(audio.cries, 1, "the Manaphy reveal plays one cry")
end

function T.tests.answers_follow_the_source_yes_no()
  local function drive(button)
    local state = EggHatchState.new({
      variant = "egg",
      species = 172,
      form = 0,
      audio = recordingAudio(),
      hatched = { messageId = 0, frames = 2 },
      question = { messageId = 1, frames = 2 },
    })
    advanceUntil(state, function(phase)
      return phase == PHASES.WAIT_BEFORE_SHAKE
    end)
    -- Frames outside the question ignore input: the scene runs its own waits.
    state:handleInput({ pressedAction = true })
    Assert.equal(state:phase(), PHASES.WAIT_BEFORE_SHAKE, "input outside the question is ignored")
    advanceUntil(state, function(phase)
      return phase == PHASES.CHOOSE_NICKNAME
    end)
    state:handleInput({ pressedDirection = "down" })
    Assert.equal(state:snapshot().selection, "no", "the source cursor moves to the second answer")
    local input = button == "yes" and { pressedDirection = "up", pressedAction = true } or { pressedCancel = true }
    state:handleInput(input)
    advanceUntil(state, function(phase)
      return phase == PHASES.DONE
    end)
    return state:result()
  end
  local yes = drive("yes")
  Assert.isTrue(yes.wantToName, "the yes answer opens the naming screen")
  local no = drive("no")
  Assert.isFalse(no.wantToName, "the no answer keeps the default name")
end

function T.tests.presentation_readiness_is_reported_not_awaited()
  local state = scene("egg")
  Assert.isFalse(state:snapshot().presentationReady, "a headless scene reports no presentation bundle")
  state:setPresentation(false, "missing art")
  Assert.equal(state:snapshot().preparationError, "missing art", "a failed bundle surfaces its cause")
  state:setPresentation(true, nil)
  Assert.isTrue(state:snapshot().presentationReady, "a committed bundle reports readiness")
  state:updateFixed(nil)
  Assert.isTrue(state:phase() ~= PHASES.DONE, "gameplay frames never wait for a renderer")
end

return T
