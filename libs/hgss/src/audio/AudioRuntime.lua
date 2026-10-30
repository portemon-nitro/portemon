-- Composes the HGSS semantic audio services over the Nintendo sound runtime.

local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local CryPlayer = require("libs.hgss.src.audio.CryPlayer")
local FieldAudioController = require("libs.hgss.src.audio.FieldAudioController")
local GameSound = require("libs.hgss.src.audio.GameSound")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local WaveOutPlayer = require("libs.nds.src.nitro.sound.WaveOutPlayer")

local AudioRuntime = {}

-- The source radio player configuration (fixed HGSS runtime data, not
-- catalog data): logical player 9 carries one simultaneous radio sequence
-- with channels masked to 0xA7FE.
local RADIO_PLAYER_ID = 9
local RADIO_PLAYER_RECORD = { id = 9, maxSequences = 1, channelMask = 0xA7FE }

---@class HgssAudioRuntimeFieldOptions
---@field eventState unknown
---@field fieldPosition fun(): integer, integer
---@field dayNight fun(): "day"|"night"
---@field fieldDataForMap fun(mapId: integer|string): unknown
---@field traversal (fun(): string)?

---@class HgssAudioRuntimeOptions
---@field cacheFs CacheFs
---@field outputRate integer
---@field field HgssAudioRuntimeFieldOptions?
---@field assetPreparation table<string, unknown>? shared background preparation queue bound to the sample provider when a presented field exists

---@class HgssAudioRuntimeComposition
---@field sound GameSound
---@field renderer { render: fun(self: table<string, unknown>, frames: integer): integer[], renderIntoInt16: fun(self: table<string, unknown>, ptr: ffi.cdata*, frames: integer) }
---@field fieldService FieldAudioController?

---@param opts HgssAudioRuntimeOptions
---@return HgssAudioRuntimeComposition
function AudioRuntime.compose(opts)
  assert(opts and opts.cacheFs and opts.outputRate, "AudioRuntime.compose requires cacheFs and outputRate")

  local provider = AudioAssetProvider.new(opts.cacheFs)
  -- A presented field shares one background preparation queue with the
  -- scene/image owners, so predicted sample payloads arrive as worker
  -- ByteData instead of main-thread decodes. Headless audio keeps no queue
  -- and stays on the synchronous-safe sample path.
  if opts.field ~= nil and opts.assetPreparation ~= nil then
    provider:bindQueue(opts.assetPreparation)
  end
  -- A small provider adapter for the sequence engine: player 9 resolves to
  -- the radio configuration above while every other player record and
  -- every sample delegates unchanged to the asset provider. GameSound keeps
  -- the ordinary provider for its own asset resolution.
  local soundProvider = {}
  function soundProvider:player(id)
    if id == RADIO_PLAYER_ID then
      return RADIO_PLAYER_RECORD
    end
    return provider:player(id)
  end
  function soundProvider:loadSample(key)
    return provider:loadSample(key)
  end
  local mixer = VoiceMixer.new({ sampleRate = opts.outputRate })
  local player = SequencePlayer.new({
    sampleRate = opts.outputRate,
    mixer = mixer,
    provider = soundProvider,
  })
  local cry = CryPlayer.new({ player = player, provider = provider, waveOut = WaveOutPlayer.new({ mixer = mixer }) })
  local sound = GameSound.new({
    provider = provider,
    player = player,
    cry = cry,
  })
  local fieldService
  if opts.field ~= nil then
    fieldService = FieldAudioController.new({
      sound = sound,
      provider = provider,
      eventState = opts.field.eventState,
      fieldPosition = opts.field.fieldPosition,
      dayNight = opts.field.dayNight,
      fieldDataForMap = opts.field.fieldDataForMap,
      traversal = opts.field.traversal,
    })
  end
  -- The sample idle budget must never take bytes a mixer voice still
  -- sounds: the predicate runs only on trim passes, and the provider holds
  -- no voice itself, so teardown order stays ownership-safe either way.
  local function sampleIsActive(sample)
    return mixer:isSampleActive(sample.pcm)
  end
  provider:setBusyPredicate(sampleIsActive)
  return {
    sound = sound,
    renderer = player,
    fieldService = fieldService,
  }
end

return AudioRuntime
