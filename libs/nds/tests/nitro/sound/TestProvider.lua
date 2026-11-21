-- Test-only normalized sound provider for NDS player tests.

local Pcm16 = require("libs.nds.src.nitro.sound.Pcm16")

local TestProvider = {}

---@param bundle table
---@return table
function TestProvider.new(bundle)
  assert(bundle and bundle.index and bundle.sequences and bundle.banks and bundle.samples and bundle.sampleMetadata)
  local active = {}
  local provider = {
    sequence = function(_, id)
      return assert(bundle.sequences[id])
    end,
    bank = function(_, id)
      return assert(bundle.banks[id])
    end,
    player = function(_, id)
      return assert(bundle.index.players[id])
    end,
  }
  -- One packed backing per key, shared by every live acquisition and dropped
  -- with the last return: the release capability the sequence player hands to
  -- the sounding voice.
  function provider:acquireSample(key)
    local record = active[key]
    if record == nil then
      record = {
        metadata = assert(bundle.sampleMetadata[key]),
        pcm = Pcm16.fromBytes(assert(bundle.samples[key])),
        references = 0,
      }
      active[key] = record
    end
    record.references = record.references + 1
    local lease = { value = { metadata = record.metadata, pcm = record.pcm } }
    function lease:release()
      if self.value == nil then
        return false
      end
      self.value = nil
      record.references = record.references - 1
      if record.references == 0 and active[key] == record then
        active[key] = nil
      end
      return true
    end
    return lease
  end
  return provider
end

return TestProvider
