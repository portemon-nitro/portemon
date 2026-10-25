-- Game-stats save bucket: strict persisted shape, canonical detached
-- output, and migration from a missing bucket without inventing
-- registrations or score. Uses literal buckets plus small synthetic
-- species sets; no ROM, GPU, or product cache is touched.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameStats = require("libs.hgss.src.mons.GameStats")
local GameStatsSave = require("libs.hgss.src.save.GameStatsSave")

local T = {}

local function refs()
  return { species = { CHIKORITA = true, TOTODILE = true, EEVEE = true } }
end

local function validBucket()
  return {
    schema = "hgss-stats-v1",
    stateVersion = 1,
    uniqueCaught = { "TOTODILE", "CHIKORITA" },
    uniqueTotal = 3,
    score = 40,
  }
end

local function assertInvalid(fn, what)
  local err = Assert.throws(fn, what)
  Assert.isTrue(Errors.is(err), "rejections use the structured error path: " .. tostring(err))
  Assert.equal(err.code, "GAME_STATS_INVALID", "rejections carry the stats error identity")
end

function T.valid_buckets_canonicalize_deterministically()
  local canonical = GameStatsSave.validate(validBucket(), refs())
  Assert.equal(canonical.schema, "hgss-stats-v1", "validation publishes the current schema")
  Assert.equal(canonical.stateVersion, 1, "validation publishes the current state version")
  Assert.deepEqual(canonical.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "validation sorts its registrations")
  Assert.equal(canonical.uniqueTotal, 3, "validation keeps the blind total")
  Assert.equal(canonical.score, 40, "validation keeps the saved score")
  local again = GameStatsSave.validate(canonical, refs())
  Assert.deepEqual(again, canonical, "canonical buckets validate idempotently")
end

function T.missing_buckets_migrate_empty_without_invention()
  local migrated = GameStatsSave.migrate(nil, refs())
  Assert.deepEqual(migrated, GameStatsSave.initial(), "a missing bucket migrates to the initial state")
  Assert.deepEqual(migrated.uniqueCaught, {}, "migration invents no registrations")
  Assert.equal(migrated.uniqueTotal, 0, "migration invents no unique count")
  Assert.equal(migrated.score, 0, "migration invents no score")
  local owner = GameStats.restore(nil, refs())
  Assert.equal(owner:uniqueCount(), 0, "a missing bucket restores nothing counted")
  Assert.equal(owner:score(), 0, "a missing bucket restores a zero score")
  local roundTrip = GameStats.restore(migrated, refs())
  Assert.deepEqual(roundTrip:bucket(), migrated, "migration output restores and republishes unchanged")
end

function T.owner_buckets_round_trip_through_validation()
  local owner = GameStats.restore(validBucket(), refs())
  local bucket = owner:bucket()
  local canonical = GameStatsSave.validate(bucket, refs())
  Assert.deepEqual(canonical, bucket, "live buckets validate without repair")
  bucket.uniqueCaught[1] = "EEVEE"
  bucket.score = 0
  Assert.isFalse(owner:isCounted("EEVEE"), "the canonical bucket never aliases live registrations")
  Assert.equal(owner:score(), 40, "the canonical bucket never aliases the live score")
end

function T.malformed_buckets_fail_with_attribution()
  assertInvalid(function()
    local bucket = { schema = "hgss-stats-v1", stateVersion = 1, uniqueCaught = {}, score = 0, extra = true }
    GameStatsSave.validate(bucket, refs())
  end, "unknown top-level fields never validate")
  assertInvalid(function()
    GameStatsSave.validate("not a record", refs())
  end, "non-table buckets never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.schema = "hgss-pokedex-v2"
    GameStatsSave.validate(bucket, refs())
  end, "foreign schemas never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.stateVersion = 2
    GameStatsSave.validate(bucket, refs())
  end, "incompatible state versions never validate")
  assertInvalid(function()
    GameStatsSave.migrate({ schema = "hgss-pokedex-v1", stateVersion = 1, seen = {}, caught = {} }, refs())
  end, "unsupported schemas never migrate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.uniqueCaught = { "MISSINGNO" }
    GameStatsSave.validate(bucket, refs())
  end, "unknown species never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.uniqueCaught = { "CHIKORITA", "CHIKORITA" }
    GameStatsSave.validate(bucket, refs())
  end, "duplicate registrations never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.uniqueCaught = { [1] = "CHIKORITA", [3] = "TOTODILE" }
    GameStatsSave.validate(bucket, refs())
  end, "sparse registration arrays never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.uniqueTotal = -1
    GameStatsSave.validate(bucket, refs())
  end, "negative unique totals never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.uniqueTotal = 1.5
    GameStatsSave.validate(bucket, refs())
  end, "fractional unique totals never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.uniqueTotal = nil
    GameStatsSave.validate(bucket, refs())
  end, "missing unique totals never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.score = -1
    GameStatsSave.validate(bucket, refs())
  end, "negative scores never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.score = 1.5
    GameStatsSave.validate(bucket, refs())
  end, "fractional scores never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.score = GameStatsSave.SCORE_CAP + 1
    GameStatsSave.validate(bucket, refs())
  end, "scores above the retail ceiling never validate")
  assertInvalid(function()
    GameStatsSave.validate(validBucket(), { species = {} })
  end, "empty species sets never validate")
  assertInvalid(function()
    GameStatsSave.validate(nil, refs())
  end, "a nil bucket never validates directly")
end

return { tests = T }
