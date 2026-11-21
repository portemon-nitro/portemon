-- GameAudio: the application-owned composition of the HGSS audio runtime and
-- the optional LÖVE output sink.

local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")
local LoveAudioSink = require("game.src.audio.LoveAudioSink")

local GameAudio = {}

---@class GameAudioComposeOptions
---@field cacheFs CacheFs
---@field outputRate integer
---@field outputHost table<string, unknown>?
---@field channelMode string? "stereo" or "mono"; defaults to stereo where no player save selects a mode
---@field assetPreparation table<string, unknown>?
---@field acquireSource fun(reference: ResidentCache.BlobRef): table<string, unknown>?
---@field field table<string, unknown>?

---@class GameAudioComposition
---@field sound GameSound
---@field renderer { render: fun(self: table<string, unknown>, frames: integer): integer[], renderIntoInt16: fun(self: table<string, unknown>, ptr: ffi.cdata*, frames: integer) }
---@field fieldService FieldAudioController?
---@field sink LoveAudioSink|nil
---@field dispose fun(self: GameAudioComposition)

---@param opts GameAudioComposeOptions
---@return GameAudioComposition
function GameAudio.compose(opts)
  assert(opts and opts.cacheFs and opts.outputRate, "GameAudio.compose requires cacheFs and outputRate")

  local core = AudioRuntime.compose(opts --[[@as HgssAudioRuntimeOptions]])

  local sink
  local ok, composition = pcall(function()
    local outputHost = opts.outputHost
    if outputHost == nil and love ~= nil and love.audio ~= nil then
      outputHost = { audio = love.audio, sound = love.sound }
    end
    if outputHost ~= nil then
      sink = LoveAudioSink.new({
        audio = outputHost.audio,
        sound = outputHost.sound,
        renderer = core.renderer,
        sampleRate = opts.outputRate,
        channelMode = opts.channelMode or "stereo",
      })
    end

    assert(core.sound and core.renderer, "AudioRuntime.compose must return a usable audio composition")

    return {
      sound = core.sound,
      renderer = core.renderer,
      fieldService = core.fieldService,
      sink = sink,
    }
  end)

  if not ok then
    -- A sink and a core created before the failure are both released: a
    -- sink-only teardown would leave sounding voices and source interests live.
    if sink ~= nil then
      pcall(sink.release, sink)
    end
    pcall(core.dispose, core)
    error(composition, 0)
  end
  ---@cast composition GameAudioComposition
  ---@cast core HgssAudioRuntimeComposition
  local disposed = false
  -- The sink is output only: it stops before the core returns every physical
  -- voice's sample acquisition and releases the provider's active records.
  function composition:dispose()
    if disposed then
      return
    end
    disposed = true
    local failure
    local function attempt(fn)
      local callOk, err = pcall(fn)
      if not callOk and failure == nil then
        failure = err
      end
    end
    if sink ~= nil then
      attempt(function()
        sink:release()
      end)
    end
    attempt(function()
      core:dispose()
    end)
    if failure ~= nil then
      error(failure, 0)
    end
  end
  return composition
end

return GameAudio
