-- Direct coverage of SourcePlan.validate's rejection branches: the schema
-- gate that stands between a persisted/tampered cache record and scheduler
-- adoption. Each case mutates one field of an otherwise-valid synthetic
-- record and checks that the matching section is what rejects it, so every
-- branch of the validator has a cheap, isolated regression distinct from the
-- compile/stage/session contracts exercised in source_plan_test.lua.

local Assert = require("tests.support.Assert")
local SourcePlan = require("romdump.src.build.SourcePlan")

local T = {}

local PRODUCER_ID = "d" .. string.rep("3", 64)
local ROM_SHA1 = string.rep("a", 40)
local AUDIO_ARCHIVE_SHA1 = string.rep("b", 40)

local function identity()
  return { versionId = "heartgold", generationId = "validate-generation", producerId = PRODUCER_ID }
end

-- Every field required by SourcePlan.validate, already mutually consistent.
local function validPlan()
  return {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = ROM_SHA1,
    generationId = "validate-generation",
    producerId = PRODUCER_ID,
    world = {
      maps = { { id = 7 }, { id = 9 } },
      analysis = { excluded = { { id = 3, reason = "placeholder header" } } },
    },
    fieldCellIndexBundle = {
      index = {
        matrices = {
          { matrixMemberId = 11, cells = { { matrixMemberId = 11, index = 0 }, { matrixMemberId = 11, index = 1 } } },
        },
      },
      indexMarker = "validate-index-marker",
    },
    scriptPlan = { members = { { memberId = 4 }, { memberId = 6 } }, generationKey = "validate-script-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = { { bankId = 2 }, { bankId = 5 } } },
    audioIdentity = { romSha1 = ROM_SHA1, sdatSha1 = AUDIO_ARCHIVE_SHA1, sdatFileId = 9 },
    mapCellKeys = { [7] = { "11-0", "11-1" }, [9] = {} },
  }
end

---@param mutate fun(plan: table)
---@param needle string substring expected in the rejection reason
local function expectRejected(mutate, needle)
  local plan = validPlan()
  mutate(plan)
  local ok, reason = SourcePlan.validate(plan, identity())
  Assert.isNil(ok, "the mutated inventory must not validate")
  Assert.notNil(reason, "a rejected inventory names a reason")
  Assert.isTrue(
    tostring(reason):find(needle, 1, true) ~= nil,
    "unexpected rejection reason: " .. tostring(reason)
  )
end

function T.well_formed_plan_validates()
  Assert.isTrue(SourcePlan.validate(validPlan(), identity()), "a fully-formed inventory validates")
end

-- Envelope: field membership, schema/identity match, ROM identity shape,
-- and the data-only sweep.
function T.unknown_field_is_rejected()
  expectRejected(function(plan)
    plan.bogus = true
  end, "unknown field")
end

function T.missing_field_is_rejected()
  expectRejected(function(plan)
    plan.audioPlan = nil
  end, "is missing audioPlan")
end

function T.schema_mismatch_is_rejected()
  expectRejected(function(plan)
    plan.schema = "g4-source-plan-v2"
  end, "schema mismatch")
end

function T.version_mismatch_is_rejected()
  expectRejected(function(plan)
    plan.versionId = "soulsilver"
  end, "version is not current")
end

function T.generation_mismatch_is_rejected()
  expectRejected(function(plan)
    plan.generationId = "another-generation"
  end, "generation is not current")
end

function T.producer_mismatch_is_rejected()
  expectRejected(function(plan)
    plan.producerId = "d" .. string.rep("4", 64)
  end, "producer is not current")
end

function T.malformed_rom_identity_is_rejected()
  expectRejected(function(plan)
    plan.romSha1 = "not-hex"
  end, "no ROM identity")
end

function T.non_data_value_is_rejected()
  expectRejected(function(plan)
    plan.world.bogusClosure = function() end
  end, "non-data value")
end

-- World membership.
function T.world_not_a_table_is_rejected()
  expectRejected(function(plan)
    plan.world = "oops"
  end, "no world membership")
end

function T.unidentified_world_map_is_rejected()
  expectRejected(function(plan)
    plan.world.maps[1] = { id = -1 }
  end, "unidentified world map")
end

function T.duplicate_world_map_is_rejected()
  expectRejected(function(plan)
    plan.world.maps[2] = { id = 7 }
  end, "duplicate world map")
end

function T.missing_exclusion_analysis_is_rejected()
  expectRejected(function(plan)
    plan.world.analysis = nil
  end, "no source exclusion analysis")
end

function T.unexplained_exclusion_is_rejected()
  expectRejected(function(plan)
    plan.world.analysis.excluded[1].reason = ""
  end, "unexplained source exclusion")
end

-- Field cell index bundle.
function T.missing_cell_index_is_rejected()
  expectRejected(function(plan)
    plan.fieldCellIndexBundle.index = "oops"
  end, "no canonical cell index")
end

function T.unidentified_cell_matrix_is_rejected()
  expectRejected(function(plan)
    plan.fieldCellIndexBundle.index.matrices[1].matrixMemberId = nil
  end, "unidentified cell matrix")
end

function T.unidentified_cell_is_rejected()
  expectRejected(function(plan)
    plan.fieldCellIndexBundle.index.matrices[1].cells[1].matrixMemberId = 99
  end, "unidentified cell")
end

-- Script membership.
function T.missing_script_membership_is_rejected()
  expectRejected(function(plan)
    plan.scriptPlan.members = nil
  end, "no script membership")
end

function T.missing_script_generation_is_rejected()
  expectRejected(function(plan)
    plan.scriptPlan.generationKey = ""
  end, "no script generation")
end

function T.non_ascending_script_members_is_rejected()
  expectRejected(function(plan)
    plan.scriptPlan.members = { { memberId = 6 }, { memberId = 4 } }
  end, "script members are not ascending")
end

-- Audio membership and sound archive identity.
function T.missing_audio_membership_is_rejected()
  expectRejected(function(plan)
    plan.audioPlan.bankPlans = nil
  end, "no audio membership")
end

function T.non_ascending_audio_banks_is_rejected()
  expectRejected(function(plan)
    plan.audioPlan.bankPlans = { { bankId = 5 }, { bankId = 2 } }
  end, "audio banks are not ascending")
end

function T.missing_audio_identity_is_rejected()
  expectRejected(function(plan)
    plan.audioIdentity = "oops"
  end, "no sound archive identity")
end

function T.unexpected_audio_identity_field_is_rejected()
  expectRejected(function(plan)
    plan.audioIdentity.extra = true
  end, "unexpected field")
end

function T.malformed_audio_rom_identity_is_rejected()
  expectRejected(function(plan)
    plan.audioIdentity.romSha1 = "not-hex"
  end, "no ROM identity")
end

function T.malformed_audio_archive_digest_is_rejected()
  expectRejected(function(plan)
    plan.audioIdentity.sdatSha1 = "not-hex"
  end, "no archive digest")
end

function T.malformed_audio_archive_file_identity_is_rejected()
  expectRejected(function(plan)
    plan.audioIdentity.sdatFileId = -1
  end, "no archive file identity")
end

function T.audio_identity_rom_mismatch_is_rejected()
  expectRejected(function(plan)
    plan.audioIdentity.romSha1 = string.rep("c", 40)
  end, "disagrees with the ROM identity")
end

-- Map cell keys.
function T.missing_map_cell_keys_is_rejected()
  expectRejected(function(plan)
    plan.mapCellKeys = "oops"
  end, "no map cell keys")
end

function T.incomplete_map_membership_is_rejected()
  expectRejected(function(plan)
    plan.mapCellKeys[9] = nil
  end, "map membership is incomplete")
end

function T.unsorted_cell_keys_is_rejected()
  expectRejected(function(plan)
    plan.mapCellKeys[7] = { "11-1", "11-0" }
  end, "are not sorted and unique")
end

function T.non_canonical_cell_key_is_rejected()
  expectRejected(function(plan)
    plan.mapCellKeys[7] = { "99-99" }
  end, "is not canonical")
end

return { tests = T }
