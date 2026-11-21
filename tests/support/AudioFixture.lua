-- Synthetic audio bundle and cache fixtures for the asset/cache contract
-- tests and the NDS/HGSS audio runtime tests. The bundle follows the
-- writer-input shape (marker/index/sequences/banks/samples/sampleMetadata)
-- with assets matching the frozen audio shapes:
-- zero-based sequence/bank ids, content-addressed samples, semantic
-- instruction IR with index branch targets, direct/key_split/drum_set
-- instruments, and sample/square/noise voices. readyCache writes a bundle
-- straight into a CacheFs (paths via AudioCache) without the production
-- writer, so libs/assets and audio runtime tests can build
-- ready caches without importing romdump. Test-only fixture.

local AudioCache = require("libs.assets.src.audio.AudioCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ResidentCache = require("libs.storage.src.ResidentCache")
local Pcm16 = require("libs.nds.src.nitro.sound.Pcm16")

local AudioFixture = {}

---@class AudioFixture.Program
---@field entry number
---@field initialTrackMask number
---@field instructions table[]

---@class AudioFixture.Player
---@field id number
---@field maxSequences number?
---@field channelMask number?
---@field initialVolume number?
---@field playerPriority number?
---@field channelPriority number?

---@class AudioFixture.SequenceIndex
---@field id number
---@field symbol string|number|nil
---@field bankId number
---@field playerId number?
---@field file string?

---@class AudioFixture.BankIndex
---@field id number
---@field symbol string|number
---@field file string?

---@class AudioFixture.SampleMetadata
---@field schema string
---@field key string
---@field frames number
---@field baseTimer number
---@field loopEnabled boolean
---@field loop table

---@class AudioFixture.Sequence
---@field schema string
---@field id number
---@field symbol string|number|nil
---@field bankId number
---@field player AudioFixture.Player
---@field program AudioFixture.Program
---@field [string] table|string|number|boolean|nil

---@class AudioFixture.Bank
---@field schema string
---@field id number
---@field symbol string|number
---@field instruments table<integer, AudioBank.Instrument>

---@class AudioFixture.Generator
---@field kind string
---@field sample string?
---@field duty number?

---@class AudioFixture.Voice
---@field generator AudioFixture.Generator
---@field originalKey number
---@field envelope table
---@field pan number

---@class AudioFixture.SampleOptions
---@field frames number?
---@field baseTimer number?
---@field loopEnabled boolean?
---@field loop table?

---@class AudioFixture.Index
---@field schema string
---@field sequences table<integer, AudioFixture.SequenceIndex>
---@field banks table<integer, AudioFixture.BankIndex>
---@field players table<integer, AudioFixture.Player>
---@field sequenceBySymbol table<string, integer>
---@field bankBySymbol table<string, integer>

---@class AudioFixture.Bundle
---@field marker string
---@field index AudioFixture.Index
---@field sequences table<integer, AudioFixture.Sequence>
---@field banks table<integer, AudioFixture.Bank>
---@field samples table<string, string>
---@field sampleMetadata table<string, AudioFixture.SampleMetadata>

-- A deterministic sha1-shaped content key (40 lowercase hex chars). Content
-- addressing keys are also file-path components, so only the sha1 shape is
-- ever valid.
function AudioFixture.key(n)
  return string.format("%040x", n)
end

-- Packs explicit int16 samples into the shared immutable packed shape that
-- mixer voices borrow: the samples go through pcm16le bytes, then one FFI
-- copy owns the single backing.
---@param samples integer[]
---@return Pcm16
function AudioFixture.packed(samples)
  return Pcm16.fromBytes(AudioFixture.pcm16le(samples))
end

-- Encodes signed int16 samples as little-endian PCM16LE bytes.
---@param samples integer[]
---@return string
function AudioFixture.pcm16le(samples)
  local bytes = {}
  for i = 1, #samples do
    local s = samples[i]
    if s < 0 then
      s = s + 65536
    end
    bytes[#bytes + 1] = string.char(s % 256, math.floor(s / 256) % 256)
  end
  return table.concat(bytes)
end

---@param key string
---@return AudioFixture.Voice
function AudioFixture.sampleVoice(key)
  local voice = {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  } ---@cast voice AudioFixture.Voice
  return voice
end

---@return AudioFixture.Voice
function AudioFixture.squareVoice()
  local voice = {
    generator = { kind = "square", duty = 4 },
    originalKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  } ---@cast voice AudioFixture.Voice
  return voice
end

---@return AudioFixture.Voice
function AudioFixture.noiseVoice()
  local voice = {
    generator = { kind = "noise" },
    originalKey = 60,
    envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
    pan = 64,
  } ---@cast voice AudioFixture.Voice
  return voice
end

-- A valid sequence asset. `program` overrides the default program so engine
-- tests can author hand-written programs over the frozen
-- instruction shapes; `player` overrides the player block fields.
---@param id number
---@param symbol string|number|nil
---@param bankId number
---@param playerId number
---@param program AudioFixture.Program?
---@param player AudioFixture.Player?
---@return AudioFixture.Sequence
function AudioFixture.sequence(id, symbol, bankId, playerId, program, player)
  if program ~= nil and program.initialTrackMask == nil then
    program.initialTrackMask = 0x0001
  end
  local sequence = {
    schema = AudioCache.SEQUENCE_SCHEMA,
    id = id,
    symbol = symbol,
    bankId = bankId,
    player = player or {
      id = playerId,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    },
    program = program or {
      entry = 1,
      initialTrackMask = 0x0001,
      instructions = {
        { op = "program", program = 4 },
        { op = "note", key = 60, velocity = 96, duration = 24 },
        { op = "wait", duration = 12 },
        { op = "jump", target = 2 },
      },
    },
  }
  return sequence ---@cast sequence AudioFixture.Sequence
end

-- `instruments` overrides the default instrument map so engine tests can
-- author banks over the frozen instrument/voice shapes.
---@param id number
---@param symbol string|number
---@param sampleKeys string[]?
---@param instruments table<integer, AudioBank.Instrument>?
---@return AudioFixture.Bank
function AudioFixture.bank(id, symbol, sampleKeys, instruments)
  sampleKeys = sampleKeys or { AudioFixture.key(1), AudioFixture.key(2) }
  local bank = {
    schema = AudioCache.BANK_SCHEMA,
    id = id,
    symbol = symbol,
    instruments = instruments or {
      [0] = { kind = "direct", voice = AudioFixture.sampleVoice(sampleKeys[1]) },
      [1] = {
        kind = "key_split",
        ranges = {
          { lowKey = 0, highKey = 59, voice = AudioFixture.sampleVoice(sampleKeys[1]) },
          { lowKey = 60, highKey = 127, voice = AudioFixture.sampleVoice(sampleKeys[2]) },
        },
      },
      [2] = {
        kind = "drum_set",
        lowKey = 35,
        highKey = 36,
        voices = { AudioFixture.squareVoice(), AudioFixture.noiseVoice() },
      },
    },
  } ---@cast bank AudioFixture.Bank
  return bank
end

-- `opts` overrides frames/baseTimer/loop/loopEnabled so engine tests can pin
-- a wave's base timer, loop flag, and loop window; `file` and the source
-- `sampleRate` are deliberately absent from the derived shape (the payload
-- path derives from the content key, and playback comes from the DS sound
-- clock and the calculated timer). One-shot waves (loopEnabled false) must
-- carry the full-range window, mirroring the compiler's normalization.
-- baseTimer defaults to 8006, the DS PSG base timer (the DS sample clock
-- 16756991 Hz over 8006 is about 2093 Hz); it is the value the mixer suites
-- pin, and it makes octave ratios exact (key 72 -> ratio exactly 2.0).
---@param key string
---@param opts AudioFixture.SampleOptions?
---@return AudioFixture.SampleMetadata
function AudioFixture.sampleMetadata(key, opts)
  opts = opts or {}
  local frames = opts.frames or 8214
  local loop = opts.loop or { startFrame = 0, endFrame = frames }
  local metadata = {
    schema = AudioCache.SAMPLE_SCHEMA,
    key = key,
    frames = frames,
    baseTimer = opts.baseTimer or 8006,
    loopEnabled = opts.loopEnabled ~= false,
    loop = loop,
  } ---@cast metadata AudioFixture.SampleMetadata
  return metadata
end

-- A full E1-shaped audio bundle over a small synthetic archive: two
-- sequences on one bank, three instruments, two content-addressed samples
-- whose payloads are real PCM16LE bytes matching their metadata frames.
---@return AudioFixture.Bundle
function AudioFixture.bundle()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local pcmA = AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 })
  local pcmB = AudioFixture.pcm16le({ 5000, 6000 })
  local bundle = {
    marker = AudioCache.marker("rom-sha", "dep-sha"),
    index = {
      schema = AudioCache.INDEX_SCHEMA,
      version = "heartgold",
      -- Sequence/bank index records deliberately carry no stored payload path:
      -- every path derives from the numeric id (AudioCache.sequencePath/bankPath),
      -- so a redundant `file` field is malformed index data.
      sequences = {
        [0] = { id = 0, symbol = "SEQ_TEST_A", bankId = 12, playerId = 1 },
        [37] = { id = 37, symbol = "SEQ_TEST_B", bankId = 12, playerId = 1 },
      },
      banks = {
        [12] = { id = 12, symbol = "BANK_TEST" },
      },
      players = {
        [1] = { id = 1, maxSequences = 16, channelMask = 0xFFFF },
      },
      sequenceBySymbol = {
        ["SEQ_TEST_A"] = 0,
        ["SEQ_TEST_B"] = 37,
      },
      bankBySymbol = {
        ["BANK_TEST"] = 12,
      },
    },
    sequences = {
      [0] = AudioFixture.sequence(0, "SEQ_TEST_A", 12, 1),
      [37] = AudioFixture.sequence(37, "SEQ_TEST_B", 12, 1),
    },
    banks = {
      [12] = AudioFixture.bank(12, "BANK_TEST"),
    },
    samples = {
      [keyA] = pcmA,
      [keyB] = pcmB,
    },
    sampleMetadata = {
      [keyA] = AudioFixture.sampleMetadata(keyA, { frames = 4 }),
      [keyB] = AudioFixture.sampleMetadata(keyB, { frames = 2 }),
    },
  } ---@cast bundle AudioFixture.Bundle
  return bundle
end

-- The base resident source acquisition capability a selected runtime injects
-- into the audio composition: a lease roots the store's own bytes and its
-- release clears that reference, exactly like the selected queue's base source
-- lease. Nothing is charged and no eviction entry is created.
---@return fun(reference: table): { value: love.Data?, release: fun(self: table) }
function AudioFixture.acquireSource()
  return function(reference)
    local lease = { value = reference.data }
    function lease:release()
      self.value = nil
    end
    return lease
  end
end

-- One mixer-shaped sample acquisition over an already packed PCM backing: the
-- voice that sounds it owns the lease until physical removal, so tests that
-- only render never return it by hand. The released lease clears its value like
-- every production acquisition does.
---@param pcm Pcm16
---@param metadata table<string, unknown>?
---@return { value: table<string, unknown>?, release: fun(self: table<string, unknown>): boolean }
function AudioFixture.sampleLease(pcm, metadata)
  local lease = {
    value = {
      metadata = metadata
        or { baseTimer = 8006, loop = { startFrame = 0, endFrame = pcm.frames }, loopEnabled = false },
      pcm = pcm,
    },
  }
  function lease:release()
    if self.value == nil then
      return false
    end
    self.value = nil
    return true
  end
  return lease
end

-- Writes a bundle into a fresh FakeCache-backed CacheFs at AudioCache's
-- canonical paths, mirroring the writer's layout without using the writer.
---@param bundle AudioFixture.Bundle?
---@param backend table?
---@return CacheFs
function AudioFixture.readyCache(bundle, backend)
  bundle = bundle or AudioFixture.bundle()
  local cache = CacheFs.forVersion("heartgold", backend or FakeCache.new())
  cache:writeLua(AudioCache.indexPath(), bundle.index)
  for id, sequence in pairs(bundle.sequences) do
    cache:writeLua(AudioCache.sequencePath(id), sequence)
  end
  for id, bank in pairs(bundle.banks) do
    cache:writeLua(AudioCache.bankPath(id), bank)
  end
  for key, bytes in pairs(bundle.samples) do
    cache:write(AudioCache.samplePath(key), bytes)
    cache:writeLua(AudioCache.sampleMetadataPath(key), bundle.sampleMetadata[key])
  end
  return cache
end

-- The same bundle as one resident store: the reader shape a selected epoch
-- installs, so a provider borrows the exact compact PCM bytes the store owns
-- instead of reading a physical fixture file. Compiled Lua assets and packed
-- payloads become one entry each.
---@param bundle AudioFixture.Bundle?
---@return CacheFs reader
---@return ResidentCache store
function AudioFixture.residentCache(bundle)
  local physical = AudioFixture.readyCache(bundle)
  local versionId = physical.versionId
  local sourceId = "base:audio-fixture"
  local function collect(relative, entries)
    for _, name in ipairs(physical:getDirectoryItems(relative)) do
      local child = relative == "" and name or relative .. "/" .. name
      local info = physical:getInfo(child)
      if info ~= nil and info.type == "directory" then
        collect(child, entries)
      elseif info ~= nil then
        local bytes = assert(physical:read(child), "an audio fixture payload must be readable: " .. child)
        -- A resident store holds real payload bytes only, so an empty fixture
        -- payload is simply absent from the installed view.
        if #bytes > 0 then
          entries[#entries + 1] = {
            path = child,
            data = assert(love.data.newByteData(bytes)),
            size = #bytes,
            sourceId = sourceId,
            contentId = versionId .. "\0" .. child,
          }
        end
      end
    end
  end
  local entries = {}
  collect("", entries)
  local store = ResidentCache.new(versionId, sourceId)
  store:commit(store:prepare(entries))
  return CacheFs.fromStore(store), store
end

return AudioFixture
