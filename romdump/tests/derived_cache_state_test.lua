-- DerivedCacheState: the per-version strict-success attestation. Proves the
-- identity is sensitive to every input (dump marker, producer fingerprint,
-- asset contract, script API version, schema), that missing or malformed
-- state is stale, that publish stages a temporary sibling and atomically
-- replaces the live state, and that a failed publication propagates without
-- disturbing the previous state.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local GameVersion = require("romdump.src.source.GameVersion")
local Schema = require("libs.script.src.Schema")

local T = {}

local CONTRACT = {
  revision = 1,
  map = { cacheFormat = "map-cache-v7" },
}

local function inputs(overrides)
  local base = {
    dump = "g4-rom-dump-v1:heartgold:deadbeef",
    producer = "producer-fingerprint",
    assetContract = CONTRACT,
    scriptApi = 1,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

local function identity(overrides)
  return DerivedCacheState.current(inputs(overrides))
end

function T.exact_identity_match_succeeds()
  Assert.isTrue(DerivedCacheState.matches(identity(), identity()))
end

function T.missing_state_is_stale()
  Assert.isFalse(DerivedCacheState.matches(nil, identity()))
end

function T.malformed_state_is_stale()
  Assert.isFalse(DerivedCacheState.matches("not a table", identity()))
  Assert.isFalse(DerivedCacheState.matches({}, identity()))
end

function T.dump_marker_change_invalidates()
  local stored = identity({ dump = "g4-rom-dump-v1:heartgold:oldsha" })
  Assert.isFalse(DerivedCacheState.matches(stored, identity()))
end

function T.producer_change_invalidates()
  local stored = identity({ producer = "old-producer-fingerprint" })
  Assert.isFalse(DerivedCacheState.matches(stored, identity()))
end

function T.asset_contract_change_invalidates()
  local stored =
    DerivedCacheState.current(inputs({ assetContract = { revision = 1, map = { cacheFormat = "map-cache-v5" } } }))
  Assert.isFalse(DerivedCacheState.matches(stored, identity()))
end

function T.script_api_change_invalidates()
  local stored = identity({ scriptApi = 2 })
  Assert.isFalse(DerivedCacheState.matches(stored, identity()))
end

-- The shared asset revision is part of the release identity, so a complete fact
-- or receipt written before the compact message representation cannot be
-- reused: with the same version, ROM, and release producer identity, only the
-- revision moves and the generation no longer matches.
function T.previous_asset_revision_release_identity_never_matches()
  local romSha1 = GameVersion.VERSIONS.heartgold.sha1
  local producerId = "r7"
  local previous = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = romSha1,
    mode = "release",
    producerId = producerId,
    assetRevision = 19,
    scriptApi = Schema.API_VERSION,
  })
  local current = DerivedCacheState.currentForSelection({
    versionId = "heartgold",
    romSha1 = romSha1,
    producerId = producerId,
  })
  Assert.equal(DerivedAssetContract.revision, 20, "the current shared asset revision is 20")
  Assert.equal(current.assetRevision, 20)
  Assert.equal(previous.assetRevision, 19)
  Assert.isTrue(previous.generationId ~= current.generationId, "the revision alone changes the generation")
  Assert.isFalse(DerivedCacheState.matches(previous, current), "a revision-19 identity must read as stale")
  Assert.isTrue(DerivedCacheState.matches(current, current), "the current identity still matches itself")
end

-- The release generation token callers derive on the game thread without a
-- producer scan: accepted ROM SHA-1, the per-game release counter, the asset
-- revision, and the script API version, and nothing else.
function T.release_generation_id_uses_pure_release_constants()
  local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
  local generation = DerivedCacheState.releaseGenerationId("heartgold")
  local expected = DerivedCacheState.currentForSelection({
    versionId = "heartgold",
    romSha1 = GameVersion.VERSIONS.heartgold.sha1,
    producerId = "r" .. tostring(DerivedCacheVersions.heartgold),
  }).generationId
  Assert.equal(generation, expected, "the release token is the current release selection identity")
  local identity = DerivedCacheState.currentForSelection({
    versionId = "heartgold",
    romSha1 = GameVersion.VERSIONS.heartgold.sha1,
    producerId = "r" .. tostring(DerivedCacheVersions.heartgold),
  })
  Assert.isTrue(identity.mode == "release", "the release token derives a release identity")
  Assert.throws(function()
    DerivedCacheState.releaseGenerationId("unregistered-version")
  end, "an unknown version has no release generation")
end

function T.pre_hidden_item_release_generations_are_stale()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local current = DerivedCacheState.releaseGenerationId(versionId)
    for _, producerId in ipairs({ "r8", "r9" }) do
      local previous = DerivedCacheState.currentForSelection({
        versionId = versionId,
        romSha1 = GameVersion.VERSIONS[versionId].sha1,
        producerId = producerId,
      })
      Assert.isTrue(previous.generationId ~= current, versionId .. " must not reuse its " .. producerId .. " cache")
    end
  end
end

return { tests = T }
