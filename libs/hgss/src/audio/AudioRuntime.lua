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
---@field assetPreparation table<string, unknown>? shared preparation queue of the selected runtime
---@field acquireSource fun(reference: ResidentCache.BlobRef): table<string, unknown>? selected runtime's resident source acquirer, when the queue is not supplied

---@class HgssAudioRuntimeComposition
---@field sound GameSound
---@field renderer { render: fun(self: table<string, unknown>, frames: integer): integer[], renderIntoInt16: fun(self: table<string, unknown>, ptr: ffi.cdata*, frames: integer) }
---@field fieldService FieldAudioController?
---@field dispose fun(self: HgssAudioRuntimeComposition)

---@param opts HgssAudioRuntimeOptions
---@return HgssAudioRuntimeComposition
function AudioRuntime.compose(opts)
  assert(opts and opts.cacheFs and opts.outputRate, "AudioRuntime.compose requires cacheFs and outputRate")

  -- The selected runtime owns the resident bytes and the queue that borrows
  -- them; this composition only borrows the acquisition capability.
  local acquireSource = opts.acquireSource
  if acquireSource == nil then
    local queue = assert(
      opts.assetPreparation,
      "audio composition requires the selected runtime's source acquirer or preparation queue"
    )
    local function acquireFromQueue(reference)
      return queue:acquireSource(reference)
    end
    acquireSource = acquireFromQueue
  end

  local provider = AudioAssetProvider.new(opts.cacheFs, {
    acquireSource = acquireSource,
    assetPreparation = opts.assetPreparation,
  })
  -- A small provider adapter for the sequence engine: player 9 resolves to
  -- the radio configuration above while every other player record and every
  -- sample acquisition delegates unchanged to the asset provider. GameSound
  -- keeps the ordinary provider for its own asset resolution.
  local soundProvider = {}
  function soundProvider:player(id)
    if id == RADIO_PLAYER_ID then
      return RADIO_PLAYER_RECORD
    end
    return provider:player(id)
  end
  function soundProvider:acquireSample(key)
    return provider:acquireSample(key)
  end
  local mixer = VoiceMixer.new({ sampleRate = opts.outputRate })
  local player
  local ok, coreOrError = pcall(function()
    player = SequencePlayer.new({
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
    return { sound = sound, renderer = player, fieldService = fieldService }
  end)
  if not ok then
    -- A partially composed core owns nothing but its own empty voice table and
    -- metadata memos: unwind both before the failure propagates.
    pcall(mixer.dispose, mixer)
    pcall(provider.dispose, provider)
    error(coreOrError, 0)
  end

  ---@type HgssAudioRuntimeComposition
  local composition = coreOrError --[[@as HgssAudioRuntimeComposition]]
  local disposed = false
  -- Ordered teardown: stop the sequenced voices and cry interest, return
  -- every physical voice's acquisition through the mixer, then release the
  -- provider's active records. The shared queue and its resident bytes are
  -- borrowed and never disposed here.
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
    attempt(function()
      player:stop()
    end)
    -- Every cry wave action is a physical mixer voice, so the mixer's own
    -- disposal returns those acquisitions once the sequences released theirs.
    attempt(function()
      mixer:dispose()
    end)
    attempt(function()
      provider:dispose()
    end)
    if failure ~= nil then
      error(failure, 0)
    end
  end
  return composition
end

return AudioRuntime
