-- App-selected startup audio lifetime and source-frame timing.

local Assert = require("tests.support.Assert")
local StartupAudioSession = require("app.src.audio.StartupAudioSession")

local T = { tests = {} }

local function composition(failSinkUpdate)
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
  local sink = { updates = 0, releases = 0 }
  function sink:update()
    self.updates = self.updates + 1
    if failSinkUpdate then
      error("synthetic host output failure")
    end
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

return { tests = T.tests }
