-- Internal fixed-channel NNS WaveOut playback over the shared VoiceMixer.

local WaveOutPlayer = {}
WaveOutPlayer.__index = WaveOutPlayer

---@class WaveOutHandle
---@field channel integer
---@field generation integer
---@field mixerHandle { channel: integer, generation: integer }
---@field sample { metadata: table<string, unknown>, pcm: Pcm16 }

---@class WaveOutPlayer
---@field private _mixer VoiceMixer
---@field private _handles table<WaveOutHandle, WaveOutHandle>
---@field new fun(opts: { mixer: VoiceMixer }): WaveOutPlayer
---@field start fun(self: WaveOutPlayer, channel: integer, sample: { metadata: table<string, unknown>, pcm: Pcm16 }, options: { volume: integer, pan: integer, speed: integer, reverse: boolean }): WaveOutHandle?
---@field isPlaying fun(self: WaveOutPlayer, handle: WaveOutHandle): boolean
---@field setVolume fun(self: WaveOutPlayer, handle: WaveOutHandle, volume: integer)
---@field setPan fun(self: WaveOutPlayer, handle: WaveOutHandle, pan: integer)
---@field setSpeed fun(self: WaveOutPlayer, handle: WaveOutHandle, speed: integer)
---@field stop fun(self: WaveOutPlayer, handle: WaveOutHandle)

local function validHandle(self, handle)
  return type(handle) == "table" and self._handles[handle] ~= nil
end

function WaveOutPlayer.new(opts)
  assert(opts and opts.mixer, "WaveOutPlayer requires a mixer")
  return setmetatable({ _mixer = opts.mixer, _handles = {} }, WaveOutPlayer) --[[@as WaveOutPlayer]]
end

function WaveOutPlayer:start(channel, sample, options)
  assert(channel == 14 or channel == 15, "WaveOut channel must be 14 or 15")
  assert(sample and sample.metadata and sample.pcm, "WaveOut requires a sample")
  assert(options and options.reverse ~= nil, "WaveOut options are required")
  -- The provider sample is borrowed unchanged: reversal is a logical
  -- voice flag indexing the whole buffer backwards, never a second copy.
  local mixerHandle = self._mixer:waveOn({
    channel = channel,
    pcm = sample.pcm,
    metadata = sample.metadata,
    volume = options.volume,
    pan = options.pan,
    speed = options.speed,
    reverse = options.reverse,
  })
  if mixerHandle == nil then
    return nil
  end
  local handle = {
    channel = mixerHandle.channel,
    generation = mixerHandle.generation,
    mixerHandle = mixerHandle,
    sample = sample,
  } ---@type WaveOutHandle
  self._handles[handle] = handle
  return handle
end

function WaveOutPlayer:isPlaying(handle)
  if not validHandle(self, handle) then
    return false
  end
  local alive = self._mixer:isVoiceAlive(handle.mixerHandle)
  if not alive then
    self._handles[handle] = nil
  end
  return alive
end

function WaveOutPlayer:setVolume(handle, volume)
  if validHandle(self, handle) then
    assert(volume >= 0 and volume <= 127 and volume % 1 == 0, "WaveOut volume must be 0..127")
    self._mixer:updateVoice(handle.mixerHandle, { trackVolume = volume })
  end
end

function WaveOutPlayer:setPan(handle, pan)
  if validHandle(self, handle) then
    assert(pan >= 0 and pan <= 127 and pan % 1 == 0, "WaveOut pan must be 0..127")
    self._mixer:updateVoice(handle.mixerHandle, { trackPanOffset = pan - 64 })
  end
end

function WaveOutPlayer:setSpeed(handle, speed)
  if validHandle(self, handle) then
    assert(speed > 0 and speed <= 0xFFFF and speed % 1 == 0, "WaveOut speed must be a timer")
    self._mixer:updateVoice(handle.mixerHandle, { fixedTimer = speed })
  end
end

function WaveOutPlayer:stop(handle)
  if validHandle(self, handle) then
    self._mixer:stopVoice(handle.mixerHandle)
    self._handles[handle] = nil
  end
end

return WaveOutPlayer
