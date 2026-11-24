-- The app71 trade sequence state machine: the seven source scenes advance in
-- their own order on the fixed tick, each plays the sounds, cries, fanfare and
-- bank-179 line its scene owns, the snapshot reports the active scene, and a
-- failed presentation is reported without stopping the sequence.

local Assert = require("tests.support.Assert")
local NpcTradeState = require("game.hgss.src.field.NpcTradeState")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")

local T = {}

local function recordingAudio()
  local record = { played = {}, music = {}, cries = {}, fanfares = {} }
  local audio = {}
  function audio:play(sound)
    record.played[#record.played + 1] = sound
  end
  function audio:playMusic(music)
    record.music[#record.music + 1] = music
  end
  function audio:playCry(species, _, form)
    record.cries[#record.cries + 1] = { species = species, form = form }
  end
  function audio:playFanfare(fanfare)
    record.fanfares[#record.fanfares + 1] = fanfare
  end
  return audio, record
end

local function request(overrides)
  local typed = {
    kind = PokemonCareInterface.KINDS.trade,
    outgoing = { species = 95, form = 0, nickname = "Bellsprout", speciesKey = "BELLSPROUT", gender = "male", shiny = false },
    incoming = { species = 95, form = 0, nickname = "Rocky", speciesKey = "ONIX", gender = "female", shiny = false },
    playerName = "Rudy",
    backdrop = PokemonCareInterface.TRADE_BACKDROPS.day,
  }
  for key, value in pairs(overrides or {}) do
    typed[key] = value
  end
  return typed
end

local function newState(overrides)
  local audio, record = recordingAudio()
  local state = NpcTradeState.new({ request = request(overrides), audio = audio })
  return state, record
end

---@param state NpcTradeState
---@param ticks integer
local function advance(state, ticks)
  for _ = 1, ticks do
    state:updateFixed({})
  end
end

function T.the_seven_source_scenes_play_in_order()
  local state = newState()
  local phases = {}
  local last = nil
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    if snapshot.phase ~= last then
      phases[#phases + 1] = snapshot.phase
      last = snapshot.phase
    end
    if snapshot.done then
      break
    end
    state:updateFixed({})
  end
  Assert.deepEqual(phases, {
    PokemonCareInterface.TRADE_PHASES.SEND,
    PokemonCareInterface.TRADE_PHASES.DEPART,
    PokemonCareInterface.TRADE_PHASES.RECEDE,
    PokemonCareInterface.TRADE_PHASES.EXCHANGE,
    PokemonCareInterface.TRADE_PHASES.APPROACH,
    PokemonCareInterface.TRADE_PHASES.ARRIVE,
    PokemonCareInterface.TRADE_PHASES.RECEIVE,
    PokemonCareInterface.TRADE_PHASES.DONE,
  }, "the sequence plays every source scene once, in order")
  Assert.isTrue(state:isDone(), "the sequence finishes")
  Assert.deepEqual(state:result(), { kind = "trade", done = true }, "the sequence answers its terminal result")
end

function T.the_scene_owns_its_source_music_sounds_and_cries()
  local state, audio = newState()
  advance(state, 4000)
  Assert.deepEqual(audio.music, { "SEQ_GS_KOUKAN" }, "the trade music starts exactly once")
  local function count(wanted)
    local found = 0
    for _, sound in ipairs(audio.played) do
      if sound == wanted then
        found = found + 1
      end
    end
    return found
  end
  Assert.equal(count("SEQ_SE_DP_KOUKAN01"), 1, "the send scene plays its own sound")
  Assert.equal(count("SEQ_SE_DP_KOUKAN10"), 1, "the depart scene plays its own sound")
  Assert.equal(count("SEQ_SE_DP_KOUKAN06"), 1, "the recede scene plays its first slide sound")
  Assert.equal(count("SEQ_SE_DP_KOUKAN07"), 1, "the recede scene plays its second slide sound")
  Assert.equal(count("SEQ_SE_DP_KOUKAN03"), 1, "the exchange scene plays its own sound")
  Assert.equal(count("SEQ_SE_DP_KOUKAN05"), 1, "the approach scene plays its own sound")
  Assert.deepEqual(audio.cries, {
    { species = 95, form = 0 },
    { species = 95, form = 0 },
  }, "the sent and received records each cry once")
  Assert.deepEqual(audio.fanfares, { "SEQ_ME_SHINKAOME" }, "the receipt scene plays its fanfare")
end

function T.the_snapshot_reports_the_active_scene_and_printed_line()
  local state = newState()
  local seen = {}
  for _ = 1, 4000 do
    local snapshot = PokemonCareInterface.assertTradeStatus(state:snapshot())
    if snapshot.messageId ~= nil then
      seen[#seen + 1] = snapshot.messageId
    end
    if snapshot.done then
      break
    end
    state:updateFixed({})
  end
  local unique = {}
  for _, id in ipairs(seen) do
    if unique[#unique] ~= id then
      unique[#unique + 1] = id
    end
  end
  Assert.deepEqual(unique, { 0, 1, 2, 3 }, "the scenes print the four bank-179 lines in source order")
end

-- The background transforms are the source's own: the depart scene grows its
-- affine map from the source's starting scale to one, its vertical scroll
-- accelerates past the source's 128-pixel streak mark, and the arrive scene
-- scrolls its map up into place. A scene without a transform reports a neutral
-- scale and no scroll.
function T.the_scene_background_transforms_follow_their_source_recursion()
  local state = newState()
  local departZoom = nil
  local departScroll = 0
  local arriveScroll = nil
  local arriveZoom = nil
  local neutralZoom = nil
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    if snapshot.phase == PokemonCareInterface.TRADE_PHASES.DEPART then
      departZoom = departZoom or snapshot.bgZoom
      if snapshot.bgScrollY < departScroll then
        departScroll = snapshot.bgScrollY
      end
    elseif snapshot.phase == PokemonCareInterface.TRADE_PHASES.ARRIVE then
      arriveScroll = arriveScroll == nil and snapshot.bgScrollY or math.max(arriveScroll, snapshot.bgScrollY)
      if snapshot.bgZoom < 1 then
        arriveZoom = snapshot.bgZoom
      end
    elseif snapshot.phase == PokemonCareInterface.TRADE_PHASES.SEND then
      neutralZoom = neutralZoom or snapshot.bgZoom
    end
    if snapshot.done then
      break
    end
    state:updateFixed({})
  end
  Assert.equal(neutralZoom, 1, "the send scene has no background zoom")
  Assert.equal(departZoom, 0x480 / 4096, "the depart scene starts at the source's starting scale")
  Assert.isTrue(departScroll < -256, "the depart scene scrolls its map past the source's resting y")
  Assert.equal(arriveScroll, 0, "the arrive scroll lands the map at its source resting y")
  Assert.isTrue(
    assert(arriveZoom) < 0.5,
    "the arrive scene zooms its map out toward the source's quarter scale"
  )
end

-- The depart scene runs the source's whole cascade: the fly-off, the scroll
-- that starts the light-streak fall at 128 pixels, and the fade-out. The
-- streaks fall 33 pixels a frame, wrap 452 pixels back, and are revealed one
-- per twelve frames.
function T.the_depart_cascade_runs_the_streak_fall_after_the_scroll()
  local state = newState()
  local firstStreak = nil
  local lastStreak = nil
  local maxCount = 0
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    if snapshot.phase == PokemonCareInterface.TRADE_PHASES.DEPART then
      if #snapshot.streaks > 0 then
        firstStreak = firstStreak or { frame = snapshot.frame, streak = snapshot.streaks[1] }
        lastStreak = { frame = snapshot.frame, streak = snapshot.streaks[1] }
      end
      maxCount = math.max(maxCount, #snapshot.streaks)
    end
    if snapshot.done then
      break
    end
    state:updateFixed({})
  end
  local first = assert(firstStreak, "the depart scene falls light streaks")
  Assert.isTrue(first.frame > 128, "the fall starts only after the scroll passes its 128-pixel mark")
  Assert.isTrue(maxCount > 1, "the fall reveals more than one streak")
  local last = assert(lastStreak, "the fall keeps running")
  Assert.equal(last.streak.tick, last.frame, "a streak's sheet ticks with the scene")
  -- The head and tail are the source's 56-pixel pair, and every head stays
  -- inside the source's own fall window (it wraps 452 pixels before it leaves).
  Assert.equal(last.streak.tailY - last.streak.headY, 56, "the tail trails the head by the source offset")
  Assert.isTrue(last.streak.headY >= -28 and last.streak.headY < 424, "a falling streak stays inside the source window")
  Assert.isTrue(last.frame > first.frame, "the fall keeps advancing")
end

-- The scene effect sprites are the source's own: each scene draws the sheet
-- sequence its scene sets, at the origin its CreateSprite call passes, starting
-- on the frame the scene shows it and running one animation tick per frame.
function T.the_scene_draws_its_source_effect_sprites()
  local state = newState()
  local seen = {}
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    local sprites = PokemonCareInterface.assertTradeStatus(snapshot).sprites
    if #sprites > 0 and seen[snapshot.phase] == nil then
      seen[snapshot.phase] = { frame = snapshot.frame, sprites = sprites }
    end
    if snapshot.done then
      break
    end
    state:updateFixed({})
  end

  local send = assert(seen.send, "the send scene draws its effect sprites")
  Assert.equal(send.frame, 16, "the send effect appears when the source fade-in finishes")
  Assert.deepEqual(send.sprites, {
    { sequence = 1, x = 128, y = 100, tick = 0 },
  }, "the send scene draws its sequence 1 sprite at the source origin")

  local receive = assert(seen.receive, "the receive scene draws its effect sprites")
  Assert.equal(receive.sprites[1].sequence, 1, "the receive scene starts with its sequence 1 sprite")
  local recede = assert(seen.recede, "the recede scene draws its effect sprite")
  Assert.deepEqual(recede.sprites, {
    { sequence = 3, x = 128, y = 96, tick = 0 },
  }, "the recede scene draws its sequence 3 sprite once the ball has flown")
  local approach = assert(seen.approach, "the approach scene draws its effect sprite")
  Assert.equal(approach.frame, 8, "the approach sprite appears with the source eight-frame fade")
  Assert.equal(approach.sprites[1].sequence, 3, "the approach scene reuses the sequence 3 sprite")
  Assert.isNil(seen.exchange, "the exchange scene draws no effect sheet sprite")
  Assert.isNil(seen.depart, "the depart scene draws no effect sheet sprite")
end

-- A scene's second sprite enters on its own source frame, and every sprite's
-- animation advances one tick per frame after it appears.
function T.the_second_sprite_enters_on_its_own_source_frame()
  local state = newState()
  local previous = nil
  local entered = nil
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    if snapshot.phase == PokemonCareInterface.TRADE_PHASES.SEND then
      if entered ~= nil then
        break
      end
      if #snapshot.sprites == 2 then
        entered = { frame = snapshot.frame, sprites = snapshot.sprites }
        break
      end
      previous = snapshot
    elseif entered ~= nil then
      break
    end
    state:updateFixed()
  end
  local entry = assert(entered, "the send scene draws its ball burst")
  -- The source chain: 16 fade frames, the sending line (timer > 10), the
  -- farewell (timer > 60), the window clear (timer > 60), the end wait
  -- (timer > 20), the twelve-frame flash, then the burst.
  Assert.equal(entry.frame, 183, "the ball burst replaces the picture when the source flash ends")
  Assert.equal(entry.sprites[1].sequence, 0, "the burst is the sheet's sequence 0")
  Assert.equal(entry.sprites[1].x, 128, "the burst keeps the source x origin")
  Assert.equal(entry.sprites[1].y, 90, "the burst keeps the source y origin")
  Assert.equal(entry.sprites[2].tick, 167, "the send effect keeps ticking under the burst")
  Assert.equal(#assert(previous).sprites, 1, "the burst enters on its own frame, not before")
end

-- The Poke Ball model follows the source's own scene lifecycles: the send
-- scene bounces it, the depart scene flies it away and back in, the arrive
-- scene lowers it onto the screen, and the receive scene bounces it in.
function T.the_balloon_follows_its_scene_flights()
  local state = newState()
  local sendY = {}
  local departFrames = 0
  local departVisible = false
  local departHiddenAgain = false
  local arriveStart = nil
  local arriveEnd = nil
  local receiveAlpha = nil
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    local balloon = snapshot.balloon
    if snapshot.phase == PokemonCareInterface.TRADE_PHASES.SEND and balloon ~= nil then
      sendY[#sendY + 1] = balloon.y
    elseif snapshot.phase == PokemonCareInterface.TRADE_PHASES.DEPART then
      departFrames = departFrames + 1
      if balloon ~= nil then
        departVisible = true
      elseif departVisible then
        departHiddenAgain = true
      end
    elseif snapshot.phase == PokemonCareInterface.TRADE_PHASES.ARRIVE then
      if balloon ~= nil and arriveStart == nil then
        arriveStart = balloon.y
      elseif balloon ~= nil then
        arriveEnd = balloon.y
      end
    elseif snapshot.phase == PokemonCareInterface.TRADE_PHASES.RECEIVE and balloon ~= nil then
      receiveAlpha = receiveAlpha or balloon.alpha
    end
    if snapshot.done then
      break
    end
    state:updateFixed()
  end
  Assert.isTrue(#sendY > 10, "the send scene draws the bouncing ball")
  local moved = false
  for index = 2, #sendY do
    if sendY[index] ~= sendY[1] then
      moved = true
    end
  end
  Assert.isTrue(moved, "the send ball bounces")
  Assert.isTrue(departVisible, "the depart scene draws the flying ball")
  Assert.isTrue(departHiddenAgain, "the departed ball leaves the view")
  Assert.equal(arriveStart, 140, "the arrive ball starts at the source's height")
  Assert.equal(arriveEnd, 50, "the arrive ball lands at the source's final height")
  Assert.equal(receiveAlpha, 0, "the receive ball fades in from the source's zero alpha")
end

-- The send picture is the sent record at the source's pokepic anchor until the
-- flash replaces it, and the receive picture stays vanished until the received
-- record's reveal.
function T.the_mon_pictures_follow_their_scene_reveals()
  local state = newState()
  local sendPicture = nil
  local sendHidden = false
  local receiveHiddenFirst = false
  local receiveShown = nil
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    if snapshot.phase == PokemonCareInterface.TRADE_PHASES.SEND then
      for _, picture in ipairs(snapshot.pictures) do
        if picture.visible then
          sendPicture = sendPicture or picture
        else
          sendHidden = true
        end
      end
    elseif snapshot.phase == PokemonCareInterface.TRADE_PHASES.RECEIVE then
      for _, picture in ipairs(snapshot.pictures) do
        if not picture.visible then
          receiveHiddenFirst = true
        elseif receiveShown == nil then
          receiveShown = picture
        end
      end
    end
    if snapshot.done then
      break
    end
    state:updateFixed()
  end
  Assert.notNil(sendPicture, "the send scene draws the sent record")
  Assert.equal(sendPicture.subject, "outgoing", "the send picture shows the sent record")
  Assert.equal(sendPicture.x, 128, "the pokepic keeps the source's centre x")
  Assert.equal(sendPicture.y, 80, "the pokepic keeps the source's base centre y")
  Assert.isTrue(sendHidden, "the flash hides the picture before the model appears")
  Assert.isTrue(receiveHiddenFirst, "the receive picture starts vanished")
  Assert.notNil(receiveShown, "the receive scene reveals its picture")
  Assert.equal(receiveShown.subject, "incoming", "the receive picture shows the received record")
end

-- The exchange scene slides its two pictures along the source's background y
-- offsets: the sent picture rises from the bottom of the 512-pixel map to the
-- source's final row and the received one follows it.
function T.the_exchange_pictures_slide_from_the_source_offsets()
  local state = newState()
  local first = nil
  local last = nil
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    if snapshot.phase == PokemonCareInterface.TRADE_PHASES.EXCHANGE then
      for _, picture in ipairs(snapshot.pictures) do
        if picture.subject == "outgoing" then
          first = first or picture.y
          last = picture.y
        end
      end
    end
    if snapshot.done then
      break
    end
    state:updateFixed()
  end
  Assert.equal(first, 384, "the sent picture starts at the source's first slide row")
  Assert.equal(last, 48, "the sent picture lands on the source's final slide row")
end

-- The link pulses walk the layer palette one white colour every two frames:
-- the depart scene walks up from the first colour, the arrive scene walks down
-- from the last.
function T.the_link_pulses_walk_the_source_palette()
  local state = newState()
  local departWalk = {}
  local arriveWalk = {}
  for _ = 1, 4000 do
    local snapshot = state:snapshot()
    if snapshot.phase == PokemonCareInterface.TRADE_PHASES.DEPART and #snapshot.pulses == 1 then
      if departWalk[#departWalk] ~= snapshot.pulses[1] then
        departWalk[#departWalk + 1] = snapshot.pulses[1]
      end
    elseif snapshot.phase == PokemonCareInterface.TRADE_PHASES.ARRIVE and #snapshot.pulses == 1 then
      if arriveWalk[#arriveWalk] ~= snapshot.pulses[1] then
        arriveWalk[#arriveWalk + 1] = snapshot.pulses[1]
      end
    end
    if snapshot.done then
      break
    end
    state:updateFixed({})
  end
  Assert.isTrue(#departWalk >= 15, "the depart pulses walk the source's fifteen colours")
  for index = 1, 15 do
    Assert.equal(departWalk[index], index - 1, "the departing pulse walks up one colour every two frames")
  end
  Assert.isTrue(#arriveWalk >= 15, "the arrive pulses walk the source's fifteen colours")
  for index = 1, 15 do
    Assert.equal(arriveWalk[index], 16 - index, "the arriving pulse walks down one colour every two frames")
  end
end

-- The walk holds one white colour per pulse for two frames at a time, and the
-- depart scene drains its pulses before the scroll starts: no pulse survives
-- into the rest of the sequence.
function T.the_link_pulses_step_every_two_frames_and_drain()
  local state = newState()
  local previous = nil
  local heldFrames = 0
  local drainedAt = nil
  local latePulses = 0
  for tick = 1, 4000 do
    local snapshot = state:snapshot()
    local key = table.concat(snapshot.pulses, ",")
    if snapshot.phase == PokemonCareInterface.TRADE_PHASES.DEPART then
      if key == previous then
        heldFrames = heldFrames + 1
      else
        if previous ~= nil then
          Assert.isTrue(heldFrames >= 1, "a pulse colour is held for more than one frame")
        end
        previous = key
        heldFrames = 0
      end
      if drainedAt == nil and key == "" and previous ~= nil then
        drainedAt = snapshot.frame
      end
    elseif
      drainedAt ~= nil
      and snapshot.phase ~= PokemonCareInterface.TRADE_PHASES.ARRIVE
      and #snapshot.pulses > 0
    then
      -- The arrive scene creates its own pulses; between the depart drain and
      -- that scene nothing may carry a pulse.
      latePulses = latePulses + 1
    end
    if snapshot.done then
      break
    end
    state:updateFixed({})
  end
  Assert.notNil(drainedAt, "the depart scene drains its pulses")
  Assert.equal(heldFrames > 0, true, "the walk was still holding a colour when the scene ended")
  Assert.equal(latePulses, 0, "no pulse survives the depart scene")
end

function T.a_failed_presentation_is_reported_without_stopping_the_scene()
  local state = newState()
  state:setPresentation(false, "acceptance presentation failure")
  local snapshot = state:snapshot()
  Assert.equal(snapshot.preparationError, "acceptance presentation failure", "the scene reports its cause")
  Assert.isFalse(snapshot.presentationReady, "an unusable bundle is not ready")
  advance(state, 4000)
  Assert.isTrue(state:isDone(), "the sequence still runs to its end")
  state:setPresentation(true, nil)
  local ready = state:snapshot()
  Assert.isTrue(ready.presentationReady, "a usable bundle becomes ready")
  Assert.isNil(ready.preparationError, "a usable bundle clears the failure")
end

function T.a_disposed_or_repeating_tick_never_restarts_the_scene()
  local state, audio = newState()
  advance(state, 4000)
  local played = #audio.played
  advance(state, 10)
  Assert.equal(#audio.played, played, "a finished sequence plays nothing more")
  Assert.equal(#audio.music, 1, "the finished sequence starts no second music")
  state:dispose()
  Assert.isTrue(state:isDone(), "disposal marks the scene finished")
  state:updateFixed({})
  Assert.equal(#audio.played, played, "a disposed scene advances nothing")
end

return { tests = T }
