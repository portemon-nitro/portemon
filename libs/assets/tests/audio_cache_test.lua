-- AudioCache contract: the g4-audio cache layout and the contract constants,
-- plus the authoritative audio audit. The audit is an explicit payload walk
-- (AudioCacheValidator) over the index schema and sections (sequences, banks,
-- players plus both symbol maps), every indexed sequence/bank file with its
-- leaf validator passing and its identity matching, sequence bank-id and
-- player-id resolution, player-entry validity, symbol-map consistency in both
-- directions, and every bank-referenced sample's metadata and PCM payload. A
-- missing artifact is never silence, and a current job receipt -- not a file
-- here -- is what ordinary warm reuse trusts.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioCacheValidator = require("libs.assets.src.audio.AudioCacheValidator")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local AudioFixture = require("tests.support.AudioFixture")

local T = {}

-- The authoritative walk is the only payload check: the audit reports a
-- problem instead of a readiness boolean.
local function auditProblem(cache)
  return AudioCacheValidator.validate(cache)
end

function T.constants_and_layout_paths_follow_the_contract()
  Assert.equal(AudioCache.FORMAT, DerivedAssetContract.audio.cacheFormat)
  Assert.equal(AudioCache.INDEX_SCHEMA, DerivedAssetContract.audio.indexSchema)
  Assert.equal(AudioCache.SEQUENCE_SCHEMA, DerivedAssetContract.audio.sequenceSchema)
  Assert.equal(AudioCache.BANK_SCHEMA, DerivedAssetContract.audio.bankSchema)
  Assert.equal(AudioCache.SAMPLE_SCHEMA, DerivedAssetContract.audio.sampleSchema)
  Assert.equal(AudioCache.dir(), "data/generated/audio")
  Assert.equal(AudioCache.indexPath(), "data/generated/audio/index.lua")
  Assert.equal(AudioCache.sequencePath(0), "data/generated/audio/sequences/0000.lua")
  Assert.equal(AudioCache.sequencePath(37), "data/generated/audio/sequences/0037.lua")
  Assert.equal(AudioCache.bankPath(12), "data/generated/audio/banks/0012.lua")
  local key = AudioFixture.key(1)
  Assert.equal(AudioCache.samplePath(key), "data/generated/audio/samples/" .. key .. ".pcm16le")
  Assert.equal(AudioCache.sampleMetadataPath(key), "data/generated/audio/sample-metadata/" .. key .. ".lua")
end

function T.marker_combines_format_rom_and_dependency_identity()
  Assert.equal(AudioCache.marker("rom-sha", "dep-sha"), "g4-audio-cache-v1:rom-sha:dep-sha")
end

function T.complete_artifact_passes_the_audit()
  Assert.isNil(auditProblem(AudioFixture.readyCache()), "a complete audio cache has no audit problem")
end

function T.index_schema_mismatch_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.schema = "g4-audio-index-v9"
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache))
end

function T.missing_indexed_sequence_fails_the_audit()
  local bundle = AudioFixture.bundle()
  local cache = AudioFixture.readyCache(bundle)
  cache:remove(AudioCache.sequencePath(37))
  Assert.notNil(auditProblem(cache), "every indexed sequence must exist")
end

function T.sequence_with_wrong_schema_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.sequences[0].schema = "g4-audio-sequence-v7"
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "indexed sequence must carry the expected schema")
end

function T.sequence_with_wrong_identity_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.sequences[0].id = 5
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "sequence file identity must match its index entry")
end

function T.sequence_with_unresolved_bank_id_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[37].bankId = 99
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "sequence bank ids must resolve into the index")
end

function T.negative_indexed_ids_fail_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[-1] = { id = -1, symbol = nil, bankId = 12, playerId = 1 }
  bundle.sequences[-1] = AudioFixture.sequence(-1, nil, 12, 1)
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "ids become path components; negatives are malformed")
end

function T.missing_index_players_section_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.players = nil
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "the runtime resolves players from the index")
end

function T.malformed_player_entries_fail_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.players[1].id = 2
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "player entries must identify themselves")
end

function T.sequence_player_reference_mismatch_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[0].playerId = 9
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "every sequence player id must resolve to a player entry")
end

-- The sequence asset duplicates index identity fields (bank reference and
-- symbol plus the player block it starts from); a disagreement between the
-- asset and its index entry means the index no longer describes the cache.
function T.sequence_asset_identity_fields_must_agree_with_the_index()
  local bundle = AudioFixture.bundle()
  bundle.sequences[0].bankId = 99
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "sequence bank reference must match its index entry")

  bundle = AudioFixture.bundle()
  bundle.sequences[0].symbol = "SEQ_TEST_RENAMED"
  cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "sequence symbol must match its index entry")

  bundle = AudioFixture.bundle()
  bundle.sequences[0].player.id = 2
  cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "sequence player block must match its index entry")
end

function T.bank_asset_symbol_must_agree_with_the_index()
  local bundle = AudioFixture.bundle()
  bundle.banks[12].symbol = "BANK_TEST_RENAMED"
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "bank symbol must match its index entry")
end

function T.symbol_map_entries_that_do_not_resolve_fail_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.sequenceBySymbol.SEQ_TEST_C = 999
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "every sequence map entry must resolve into the index")

  bundle = AudioFixture.bundle()
  bundle.index.bankBySymbol.BANK_TEST_C = 999
  cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "every bank map entry must resolve into the index")
end

function T.indexed_symbols_must_be_covered_by_the_symbol_map()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[0].symbol = "SEQ_TEST_RENAMED"
  bundle.sequences[0].symbol = "SEQ_TEST_RENAMED"
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "an indexed symbol with no map entry is not resolvable")
end

function T.missing_indexed_bank_fails_the_audit()
  local bundle = AudioFixture.bundle()
  local cache = AudioFixture.readyCache(bundle)
  cache:remove(AudioCache.bankPath(12))
  Assert.notNil(auditProblem(cache), "every indexed bank must exist")
end

function T.bank_with_wrong_identity_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.banks[12].id = 13
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "bank file identity must match its index entry")
end

function T.missing_referenced_sample_metadata_fails_the_audit()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  local cache = AudioFixture.readyCache(bundle)
  cache:remove(AudioCache.sampleMetadataPath(key))
  Assert.notNil(auditProblem(cache), "every bank-referenced sample needs its metadata")
end

function T.sample_metadata_with_wrong_key_fails_the_audit()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  bundle.sampleMetadata[key].key = AudioFixture.key(2)
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "sample metadata key must match its address")
end

function T.sample_metadata_without_pcm_payload_fails_the_audit()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  local cache = AudioFixture.readyCache(bundle)
  cache:remove(AudioCache.samplePath(key))
  Assert.notNil(auditProblem(cache), "every sample metadata record needs its payload")
end

function T.bank_sample_reference_without_metadata_fails_the_audit()
  local bundle = AudioFixture.bundle()
  local instrument = bundle.banks[12].instruments[0]
  local voice = assert(instrument.voice) ---@cast voice AudioFixture.Voice
  voice.generator.sample = AudioFixture.key(99)
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "bank sample ids must resolve into sample metadata")
end

-- Readiness runs the authoritative asset validators, never a weaker
-- presence-only or shape-walk-only check: content that fails its validator
-- is not ready even when every referenced file exists and every reference
-- resolves.
function T.sequence_content_failing_its_validator_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.sequences[0].program = nil
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "an indexed sequence must pass its validator")
end

function T.bank_content_failing_its_validator_fails_the_audit()
  local bundle = AudioFixture.bundle()
  local instrument = bundle.banks[12].instruments[0]
  local voice = assert(instrument.voice) ---@cast voice AudioFixture.Voice
  voice.envelope.attack = 0xFFFF
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "an indexed bank must pass its validator")
end

function T.sample_payload_with_wrong_byte_count_fails_the_audit()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  bundle.samples[key] = bundle.samples[key] .. "\0"
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "payload byte count must match the metadata frames")
end

function T.logical_player_domain_accepts_thirty_one_and_rejects_thirty_two()
  local bundle = AudioFixture.bundle()
  bundle.index.players[31] = { id = 31, maxSequences = 16, channelMask = 0xFFFF }
  bundle.index.sequences[0].playerId = 31
  bundle.sequences[0].player.id = 31
  local cache = AudioFixture.readyCache(bundle)
  Assert.isNil(auditProblem(cache), "logical player 31 is valid")

  bundle = AudioFixture.bundle()
  bundle.index.players[32] = { id = 32, maxSequences = 16, channelMask = 0xFFFF }
  bundle.index.sequences[0].playerId = 32
  bundle.sequences[0].player.id = 32
  cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "logical player 32 is outside the domain")
end

-- A used player (referenced by a compiled sequence) must declare at least one
-- playable slot: zero or negative maxSequences means the runtime cannot
-- schedule the sequence's player at all.
function T.used_player_with_nonpositive_max_sequences_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.players[1].maxSequences = 0
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "a used player needs a positive maxSequences")

  bundle = AudioFixture.bundle()
  bundle.index.players[1].maxSequences = -1
  cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "a used player needs a positive maxSequences")
end

function T.used_player_with_malformed_channel_mask_fails_the_audit()
  for _, mask in ipairs({ 0x10000, -1, 1.5, "wide" }) do
    local bundle = AudioFixture.bundle()
    bundle.index.players[1].channelMask = mask
    local cache = AudioFixture.readyCache(bundle)
    Assert.notNil(auditProblem(cache), "channelMask is an integer U16")
  end
end

-- Only used players must declare a positive slot count: an unused slot may
-- genuinely have no playable sequences (the compiler still emits every INFO
-- slot), so the positivity requirement stays scoped to referenced players.
function T.unused_player_with_zero_max_sequences_stays_valid()
  local bundle = AudioFixture.bundle()
  bundle.index.players[2] = { id = 2, maxSequences = 0, channelMask = 0 }
  local cache = AudioFixture.readyCache(bundle)
  Assert.isNil(auditProblem(cache), "unused players are not required positive")
end

-- The index contract stores no payload path on sequence/bank records: every
-- path derives from the numeric id (AudioCache.sequencePath/bankPath), so a
-- stale or foreign `file` field is malformed index data, never tolerated.
function T.sequence_index_record_with_a_redundant_file_field_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[0].file = AudioCache.sequencePath(0)
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "index records carry no stored payload path")
end

function T.bank_index_record_with_a_redundant_file_field_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.index.banks[12].file = AudioCache.bankPath(12)
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "index records carry no stored payload path")
end

-- A bank with out-of-order key_split ranges fails its leaf validator; the
-- walk converts that structured raise into a problem, so the audit reports the
-- malformed instrument shape without ever raising.
function T.bank_with_out_of_order_key_split_ranges_fails_the_audit()
  local bundle = AudioFixture.bundle()
  bundle.banks[12].instruments[1].ranges = {
    { lowKey = 60, highKey = 127, voice = AudioFixture.squareVoice() },
    { lowKey = 0, highKey = 59, voice = AudioFixture.sampleVoice(AudioFixture.key(1)) },
  }
  local cache = AudioFixture.readyCache(bundle)
  Assert.notNil(auditProblem(cache), "key_split ranges must ascend")
end

-- Catalog validation is payload-free: a structurally valid runtime index
-- passes on its own, while a dangling reference is reported by the catalog
-- check and by the full walk.
function T.catalog_validation_is_payload_free()
  local bundle = AudioFixture.bundle()
  local cache = AudioFixture.readyCache(bundle)
  Assert.isNil(AudioCacheValidator.validateCatalog(cache:loadLua(AudioCache.indexPath())))
  local dangling = AudioFixture.bundle()
  dangling.index.sequences[0].bankId = 9999
  Assert.notNil(AudioCacheValidator.validateCatalog(dangling.index), "the catalog check reports a dangling reference")
  Assert.notNil(
    auditProblem(AudioFixture.readyCache(dangling)),
    "the full walk reports a dangling bank reference without any payload read"
  )
end

return { tests = T }
