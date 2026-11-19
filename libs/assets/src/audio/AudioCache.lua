-- Paths and contract constants for the derived audio cache. The audio class
-- shares the per-version derived-cache identity with every other derived
-- class (the build-state identity includes the whole DerivedAssetContract),
-- so a sound-archive compiler change alone never disturbs the raw ROM dump,
-- and an audio contract change is not rebuildable in isolation from the
-- other classes. The generated files are the runtime index, one file per
-- indexed sequence and bank, one payload per unique semantic sample key, and
-- one playback-metadata record per payload; completion is the producer job
-- receipt (romdump), never a file here. An explicit exhaustive audit lives in
-- AudioCacheValidator; a missing artifact is never interpreted as silence.
-- Paths are cache-relative; all IO goes through a CacheFs.

local AudioCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")

AudioCache.FORMAT = Contract.audio.cacheFormat
AudioCache.INDEX_SCHEMA = Contract.audio.indexSchema
AudioCache.SEQUENCE_SCHEMA = Contract.audio.sequenceSchema
AudioCache.BANK_SCHEMA = Contract.audio.bankSchema
AudioCache.SAMPLE_SCHEMA = Contract.audio.sampleSchema

local DATA_DIR = "data/generated/audio"

function AudioCache.dir()
  return DATA_DIR
end

function AudioCache.indexPath()
  return DATA_DIR .. "/index.lua"
end

function AudioCache.sequencePath(id)
  return string.format("%s/sequences/%04d.lua", DATA_DIR, id)
end

function AudioCache.bankPath(id)
  return string.format("%s/banks/%04d.lua", DATA_DIR, id)
end

function AudioCache.samplePath(key)
  return string.format("%s/samples/%s.pcm16le", DATA_DIR, key)
end

function AudioCache.sampleMetadataPath(key)
  return string.format("%s/sample-metadata/%s.lua", DATA_DIR, key)
end

function AudioCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", AudioCache.FORMAT, romSha1, depHash)
end

return AudioCache
