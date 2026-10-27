-- App-selected startup audio lifetime and source-frame timing.

local Assert = require("tests.support.Assert")
local StartupAudioSession = require("app.src.audio.StartupAudioSession")

local T = { tests = {} }

local function composition(failSinkUpdate)
  local events = {}
  local sound = {}
  function sound:playMusic(sequence)
    events[#events + 1] = { "music", sequence }
    return true
  end
  function sound:playCry(species, pattern)
    events[#events + 1] = { "cry", species, pattern }
  end
  function sound:fadeMusicOut(spec)
    events[#events + 1] = { "fade", spec.target, spec.durationTicks }
  end
  function sound:stopMusic()
    events[#events + 1] = { "stop" }
  end
  function sound:play(sequence)
    events[#events + 1] = { "effect", sequence }
  end
  function sound:updateSoundFrame()
    events[#events + 1] = { "tick" }
  end
  local sink = { updates = 0, releases = 0 }
  function sink:update()
    self.updates = self.updates + 1
    if failSinkUpdate then
      error("synthetic host output failure")
    end
    return true
  end
  function sink:release()
    self.releases = self.releases + 1
  end
  return { sound = sound, sink = sink }, events, sink
end

function T.tests.title_events_use_the_existing_sound_and_bounded_source_clock()
  local audio, events, sink = composition()
  local session = StartupAudioSession.new({
    versionId = "soulsilver",
    titleRecord = { crySpeciesId = 249 },
    audioComposition = audio,
  })
  session:beginTitle()
  session:beginTitle()
  session:notifySkip()
  session:notifySkip()
  Assert.deepEqual(events, {
    { "music", "SEQ_GS_POKEMON_THEME" },
    { "cry", 249, 0 },
  }, "title music and the edition's legendary cry each start once")

  session:beginFade()
  session:beginFade()
  Assert.deepEqual(events[3], { "fade", 0, 60 }, "the fade uses the retail target and source duration")
  session:update(1 / 60)
  Assert.equal(sink.updates, 1, "the queueable output sink pumps once per App update")
  Assert.equal(#events, 3, "a fractional half source frame does not advance semantic audio")
  session:update(1 / 60)
  Assert.equal(sink.updates, 2, "the next host update pumps once")
  Assert.equal(#events, 4, "two half frames advance exactly one source frame")
  for _ = 1, 59 do
    session:update(1 / 30)
  end
  local stops = 0
  for _, event in ipairs(events) do
    if event[1] == "stop" then
      stops = stops + 1
    end
  end
  Assert.equal(stops, 1, "music stops once after sixty source ticks")
  Assert.equal(sink.updates, 61, "the sink pump is independent from source frame count")

  session:playMenuCue("select")
  Assert.deepEqual(events[#events], { "effect", "SEQ_SE_DP_SELECT" }, "menu feedback uses the source select sequence")
  session:dispose()
  session:dispose()
  Assert.equal(sink.releases, 1, "the borrowed composition sink is released exactly once")
end

function T.tests.opening_theme_plays_once_and_yields_to_the_title_theme()
  local audio, events, sink = composition()
  local session = StartupAudioSession.new({
    versionId = "heartgold",
    titleRecord = { crySpeciesId = 250 },
    audioComposition = audio,
  })
  Assert.equal(
    type(session.beginOpening),
    "function",
    "the session owns the movie opening cue"
  )
  session:beginOpening()
  session:beginOpening()
  Assert.deepEqual(events, {
    { "music", "SEQ_GS_TITLE" },
  }, "the opening movie track starts exactly once")
  session:beginTitle()
  Assert.deepEqual(
    events[2],
    { "music", "SEQ_GS_POKEMON_THEME" },
    "title entry switches from the opening track to the title track"
  )
  session:beginOpening()
  Assert.equal(#events, 2, "the opening cue never replays after the title track started")
  session:dispose()
  Assert.equal(sink.releases, 1, "the borrowed composition sink is released exactly once")
end

function T.tests.failed_host_output_disables_only_the_optional_sink()
  local audio, events, sink = composition(true)
  local session = StartupAudioSession.new({
    versionId = "heartgold",
    titleRecord = { crySpeciesId = 250 },
    audioComposition = audio,
  })
  session:beginTitle()
  session:update(1 / 30)
  Assert.notNil(session.diagnostic, "host output failure is retained as an audio diagnostic")
  Assert.equal(sink.releases, 1, "failed output is released once")
  Assert.equal(events[#events][1], "tick", "semantic sound state still advances without the optional sink")
  session:playMenuCue("select")
  Assert.deepEqual(
    events[#events],
    { "effect", "SEQ_SE_DP_SELECT" },
    "menu behavior remains available after output failure"
  )
  session:dispose()
  Assert.equal(sink.releases, 1, "dispose does not release the failed sink twice")
end

function T.tests.returned_menu_can_play_cues_without_a_title_record()
  local audio, events, sink = composition()
  local session = StartupAudioSession.new({
    versionId = "heartgold",
    audioComposition = audio,
  })
  session:playMenuCue("select")
  Assert.deepEqual(events, { { "effect", "SEQ_SE_DP_SELECT" } })
  session:dispose()
  Assert.equal(sink.releases, 1)
end

function T.tests.movie_first_borrowed_session_plays_one_edition_cry_without_invented_effects()
  local GameAudio = require("game.hgss.src.audio.GameAudio")
  local App = require("app.src.App")
  local savedCompose = GameAudio.compose
  local savedEpoch = App.epoch
  local savedVersionId = App.selectedVersionId
  local savedProvisioner = App.provisioner
  local savedSession = App.startupAudioSession
  local savedError = App.startupAudioError
  local cases = {
    { versionId = "heartgold", species = 250 },
    { versionId = "soulsilver", species = 249 },
  }
  local ok, failure = xpcall(function()
    for _, case in ipairs(cases) do
      local events = {}
      local sound = {}
      function sound:playMusic(sequence)
        events[#events + 1] = { "music", sequence }
      end
      function sound:playCry(species, pattern)
        events[#events + 1] = { "cry", species, pattern }
      end
      function sound:fadeMusicOut(spec)
        events[#events + 1] = { "fade", spec.target, spec.durationTicks }
      end
      function sound:stopMusic()
        events[#events + 1] = { "stop" }
      end
      function sound:play(sequence)
        events[#events + 1] = { "effect", sequence }
      end
      function sound:updateSoundFrame()
        events[#events + 1] = { "tick" }
      end
      GameAudio.compose = function(_)
        return { sound = sound, sink = nil }
      end
      App.epoch = 41
      App.selectedVersionId = case.versionId
      App.provisioner = {
        gameHost = function()
          return {
            requestMilestone = function()
              return true, nil
            end,
          }
        end,
      }
      App.startupAudioSession = nil
      App.startupAudioError = nil
      local session = App._ensureStartupAudio(case.versionId, App.epoch, nil)
      Assert.notNil(session, "movie-first audio starts without its title record")
      session:beginOpening()
      local same = App._ensureStartupAudio(case.versionId, App.epoch, { crySpeciesId = case.species })
      Assert.equal(same, session, "the title handoff reuses its movie-first session")
      session:beginTitle()
      local cried, cryFailure = pcall(function()
        session:notifySkip()
      end)
      Assert.isTrue(cried, "the accepted title tap still delivers its bound legendary cry")
      Assert.isNil(cryFailure, "the accepted tap raises no audio failure")
      session:beginFade()
      session:playMenuCue("select")
      Assert.deepEqual(events, {
        { "music", "SEQ_GS_TITLE" },
        { "music", "SEQ_GS_POKEMON_THEME" },
        { "cry", case.species, 0 },
        { "fade", 0, 60 },
        { "effect", "SEQ_SE_DP_SELECT" },
      }, "acceptance plays only its sourced cry and fade while menu navigation keeps the select cue")
      session:dispose()
      App.startupAudioSession = nil
      App.startupAudioError = nil
    end
  end, debug.traceback)
  GameAudio.compose = savedCompose
  App.epoch = savedEpoch
  App.selectedVersionId = savedVersionId
  App.provisioner = savedProvisioner
  App.startupAudioSession = savedSession
  App.startupAudioError = savedError
  if not ok then
    error(failure, 0)
  end
end

function T.tests.same_species_binding_is_a_noop_while_drift_is_rejected()
  local audio, events, sink = composition()
  local session = StartupAudioSession.new({
    versionId = "heartgold",
    audioComposition = audio,
  })
  session:bindTitleRecord({ crySpeciesId = 250 })
  session:bindTitleRecord({ crySpeciesId = 250 })
  local ok, failure = pcall(session.bindTitleRecord, session, { crySpeciesId = 249 })
  Assert.isFalse(ok, "a different cry for the same selection is rejected")
  Assert.notNil(failure, "the drift rejection carries a diagnostic")
  session:beginTitle()
  session:notifySkip()
  Assert.deepEqual(events, {
    { "music", "SEQ_GS_POKEMON_THEME" },
    { "cry", 250, 0 },
  }, "the original cry survives the rejected drift")
  session:dispose()
  Assert.equal(sink.releases, 1)
end

function T.tests.repeated_entries_restart_each_track_while_keeping_the_cry()
  local audio, events, sink = composition()
  local session = StartupAudioSession.new({
    versionId = "soulsilver",
    audioComposition = audio,
  })
  session:beginOpening()
  session:beginOpening()
  session:bindTitleRecord({ crySpeciesId = 249 })
  session:beginTitle()
  session:beginTitle()
  session:notifySkip()
  session:notifySkip()
  Assert.deepEqual(events, {
    { "music", "SEQ_GS_TITLE" },
    { "music", "SEQ_GS_POKEMON_THEME" },
    { "cry", 249, 0 },
  }, "reentrant updates never duplicate a track or the cry")
  session:beginMovieCycle()
  session:beginOpening()
  session:beginTitle()
  Assert.deepEqual(events, {
    { "music", "SEQ_GS_TITLE" },
    { "music", "SEQ_GS_POKEMON_THEME" },
    { "cry", 249, 0 },
    { "music", "SEQ_GS_TITLE" },
    { "music", "SEQ_GS_POKEMON_THEME" },
  }, "a fresh entry restarts both tracks in order without clearing the cry")
  session:dispose()
  Assert.equal(sink.releases, 1)
end

function T.tests.title_only_session_never_replays_a_movie_track()
  local audio, events, sink = composition()
  local session = StartupAudioSession.new({
    versionId = "heartgold",
    titleRecord = { crySpeciesId = 250 },
    audioComposition = audio,
  })
  session:beginTitle()
  session:beginOpening()
  session:notifySkip()
  session:beginFade()
  Assert.deepEqual(events, {
    { "music", "SEQ_GS_POKEMON_THEME" },
    { "cry", 250, 0 },
    { "fade", 0, 60 },
  }, "a session born at the title never plays a belated movie track")
  session:dispose()
  Assert.equal(sink.releases, 1)
end

function T.tests.disposal_during_fading_releases_once_and_stays_silent()
  local audio, events, sink = composition()
  local session = StartupAudioSession.new({
    versionId = "heartgold",
    titleRecord = { crySpeciesId = 250 },
    audioComposition = audio,
  })
  session:beginTitle()
  session:notifySkip()
  session:beginFade()
  session:dispose()
  local fades = #events
  session:update(1)
  session:beginTitle()
  session:notifySkip()
  session:beginFade()
  session:dispose()
  Assert.equal(#events, fades, "updates and cues after disposal stay silent")
  Assert.equal(sink.releases, 1, "the sink is released exactly once")
end

-- The opening cue confirms only a successful play: a successful start and
-- its repeat acknowledge, a rejected play leaves the start unlatched for
-- retry, a disposed session refuses, and a title-born session never
-- replays the movie track.
function T.tests.opening_start_confirms_only_a_successful_play()
  local audio, events, sink = composition()
  local session = StartupAudioSession.new({
    versionId = "heartgold",
    titleRecord = { crySpeciesId = 250 },
    audioComposition = audio,
  })
  Assert.equal(session:beginOpening(), true, "a successful play acknowledges the opening start")
  Assert.equal(session:beginOpening(), true, "the started opening acknowledges its repeat without replaying")
  Assert.deepEqual(events, {
    { "music", "SEQ_GS_TITLE" },
  }, "the opening track starts exactly once")
  session:beginMovieCycle()
  Assert.equal(session:beginOpening(), true, "a fresh entry acknowledges its own opening start")
  Assert.deepEqual(events, {
    { "music", "SEQ_GS_TITLE" },
    { "music", "SEQ_GS_TITLE" },
  }, "each admitted entry starts the opening track once")
  session:dispose()
  Assert.equal(sink.releases, 1, "the borrowed composition sink is released exactly once")
  Assert.equal(session:beginOpening(), false, "a disposed session refuses a new start")

  local attempts = 0
  local played = {}
  local flaky = {}
  function flaky:playMusic(sequence)
    attempts = attempts + 1
    if attempts == 1 then
      error("synthetic play failure")
    end
    played[#played + 1] = sequence
    return true
  end
  function flaky:play(sequence)
    played[#played + 1] = sequence
  end
  function flaky:playCry() end
  function flaky:fadeMusicOut() end
  function flaky:stopMusic() end
  function flaky:updateSoundFrame() end
  local retriedSink = { updates = 0 }
  function retriedSink:update()
    self.updates = self.updates + 1
    return true
  end
  function retriedSink:release() end
  local retried = StartupAudioSession.new({
    versionId = "heartgold",
    titleRecord = { crySpeciesId = 250 },
    audioComposition = { sound = flaky, sink = retriedSink },
  })
  local failure = Assert.throws(function()
    retried:beginOpening()
  end, "a rejected play surfaces instead of acknowledging")
  Assert.notNil(failure, "the rejected play carries a diagnostic")
  Assert.equal(retried:beginOpening(), true, "the unlatched start retries after the rejection")
  Assert.deepEqual(played, { "SEQ_GS_TITLE" }, "the retry plays the opening track once")
  retried:dispose()

  local titleAudio, titleEvents = composition()
  local titleSession = StartupAudioSession.new({
    versionId = "heartgold",
    titleRecord = { crySpeciesId = 250 },
    audioComposition = titleAudio,
  })
  titleSession:beginTitle()
  Assert.equal(titleSession:beginOpening(), false, "a title-born session never replays the movie track")
  Assert.deepEqual(titleEvents, {
    { "music", "SEQ_GS_POKEMON_THEME" },
  }, "the title-born session keeps only its title track")
  titleSession:dispose()
end

-- A rejected underlying voice never admits the movie: the semantic identity
-- still tracks the request, the start reports refusal, and no host output
-- is claimed.
function T.tests.rejected_opening_voice_holds_the_start_without_priming_output()
  local playCalls = 0
  local current = nil
  local sound = {}
  function sound:playMusic(sequence)
    playCalls = playCalls + 1
    current = 7
    return false
  end
  function sound:play() end
  function sound:playCry() end
  function sound:fadeMusicOut() end
  function sound:stopMusic() end
  function sound:updateSoundFrame() end
  function sound:currentMusic()
    return current
  end
  local sink = { updates = 0, releases = 0 }
  function sink:update()
    self.updates = self.updates + 1
    return true
  end
  function sink:release()
    self.releases = self.releases + 1
  end
  local session = StartupAudioSession.new({
    versionId = "soulsilver",
    titleRecord = { crySpeciesId = 249 },
    audioComposition = { sound = sound, sink = sink },
  })
  local acknowledged, reason = session:beginOpening()
  Assert.isFalse(acknowledged, "a rejected voice must not acknowledge the opening")
  Assert.notNil(reason, "the refusal carries a diagnostic")
  Assert.equal(current, 7, "the semantic identity still tracks the request")
  Assert.equal(session.openingStarted, false, "the opening latch stays clear")
  Assert.equal(sink.updates, 0, "no host output is claimed without an accepted voice")
  local second, _ = session:beginOpening()
  Assert.isFalse(second, "the unlatched start stays unacknowledged")
  Assert.equal(playCalls, 2, "an unaccepted voice retries instead of latching")
  session:dispose()
  Assert.equal(sink.releases, 1, "the borrowed sink releases exactly once")
end

-- An accepted voice without primed output holds the start for retry: the
-- retry must not restart the voice, and only primed output acknowledges.
function T.tests.accepted_voice_without_primed_output_holds_for_retry()
  local playCalls = 0
  local sound = {}
  function sound:playMusic(_)
    playCalls = playCalls + 1
    return true
  end
  function sound:play() end
  function sound:playCry() end
  function sound:fadeMusicOut() end
  function sound:stopMusic() end
  function sound:updateSoundFrame() end
  local primed = false
  local sink = { updates = 0, releases = 0 }
  function sink:update()
    self.updates = self.updates + 1
    return primed
  end
  function sink:release()
    self.releases = self.releases + 1
  end
  function sink:resetForNewTrack() end
  local session = StartupAudioSession.new({
    versionId = "heartgold",
    titleRecord = { crySpeciesId = 250 },
    audioComposition = { sound = sound, sink = sink },
  })
  Assert.isFalse(session:beginOpening(), "unprimed output must not acknowledge the opening")
  Assert.equal(session.openingStarted, false, "the opening latch stays clear without priming")
  Assert.equal(playCalls, 1, "the voice is attempted once")
  primed = true
  Assert.isTrue(session:beginOpening(), "primed output acknowledges the opening")
  Assert.equal(session.openingStarted, true, "the opening latch sets only after priming")
  Assert.equal(playCalls, 1, "the retry must not restart the accepted voice")
  Assert.isTrue(session:beginOpening(), "the admitted opening repeats as acknowledged")
  Assert.equal(playCalls, 1, "repeats never replay the voice")
  session:dispose()
  Assert.equal(sink.releases, 1, "the borrowed sink releases exactly once")
end

return { tests = T.tests }
