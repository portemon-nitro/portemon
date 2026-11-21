-- GameAudio composition tests cover the shared production wiring and its
-- failure ownership boundary. AudioFixture supplies a generated-cache-shaped
-- input; host output is replaced only at the true sink boundary.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local GameAudio = require("game.hgss.src.audio.GameAudio")
local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")
local LoveAudioSink = require("game.src.audio.LoveAudioSink")

local T = {}

function T.a_failure_after_sink_creation_releases_the_sink_once()
  local cacheFs = AudioFixture.residentCache()
  local originalCompose = AudioRuntime.compose
  local originalSinkNew = LoveAudioSink.new
  local releaseCalls = 0

  rawset(AudioRuntime, "compose", function()
    return { renderer = {} }
  end)
  rawset(LoveAudioSink, "new", function()
    return {
      release = function()
        releaseCalls = releaseCalls + 1
      end,
    }
  end)

  local ok, err = pcall(function()
    GameAudio.compose({
      cacheFs = cacheFs,
      outputRate = 32768,
      outputHost = { audio = {}, sound = {} },
    })
  end)

  rawset(AudioRuntime, "compose", originalCompose)
  rawset(LoveAudioSink, "new", originalSinkNew)

  Assert.isFalse(ok, "a later composition failure must propagate")
  Assert.equal(releaseCalls, 1, "a sink acquired before failure is released exactly once")
  Assert.isTrue(
    type(err) == "string" and string.find(err, "usable audio composition", 1, true) ~= nil,
    "the original construction failure must propagate"
  )
end

-- The selected runtime's resident reader and its source-acquisition boundary.
local function residentRuntime()
  local cache = AudioFixture.residentCache()
  return cache,
    function(reference)
      local lease = { value = reference.data }
      function lease:release()
        self.value = nil
      end
      return lease
    end
end

function T.core_composition_exposes_the_hgss_facade_and_renderer()
  local cache, acquireSource = residentRuntime()
  local core = GameAudio.compose({
    cacheFs = cache,
    outputRate = 32768,
    acquireSource = acquireSource,
  })
  Assert.notNil(core.sound)
  Assert.notNil(core.renderer)
  Assert.isNil(core.sink)
  core:dispose()
  core:dispose()
end

return { tests = T }
