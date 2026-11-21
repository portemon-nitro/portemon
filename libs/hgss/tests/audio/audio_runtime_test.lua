-- AudioRuntime composes HGSS semantic audio over the NDS sound runtime
-- without requiring an application output device.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")

local T = {}

-- The selected runtime's resident reader and source-acquisition boundary: the
-- composition borrows both and never owns them.
local function residentCache()
  local cache, store = AudioFixture.residentCache()
  return cache, store
end

local function acquireSource(reference)
  local lease = { value = reference.data }
  function lease:release()
    self.value = nil
  end
  return lease
end

function T.composes_the_semantic_facade_and_pcm_renderer_without_love_output()
  local cache = residentCache()
  local composition = AudioRuntime.compose({
    cacheFs = cache,
    outputRate = 32768,
    acquireSource = acquireSource,
  })

  Assert.notNil(composition.sound)
  Assert.equal(type(composition.sound.playMusic), "function")
  Assert.notNil(composition.renderer)
  Assert.equal(type(composition.renderer.render), "function")
  Assert.equal(type(composition.dispose), "function", "the composition disposes its complete audio core")
  composition:dispose()
  composition:dispose()
end

return { tests = T }
