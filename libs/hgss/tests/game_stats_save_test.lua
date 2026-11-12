-- Game-stats save bucket: strict persisted shape, canonical detached
-- output, and evidence-preserving migration from a missing bucket or an
-- exact v1 bucket. v2 adds the bounded written-Mail count; migration
-- never invents a historical count. Uses literal buckets plus small
-- synthetic species sets; no ROM, GPU, or product cache is touched.

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
    schema = "hgss-stats-v2",
    stateVersion = 2,
    uniqueCaught = { "TOTODILE", "CHIKORITA" },
    uniqueTotal = 3,
    score = 40,
    mailWritten = 7,
  }
end

local function legacyBucket()
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
  Assert.equal(canonical.schema, "hgss-stats-v2", "validation publishes the current schema")
  Assert.equal(canonical.stateVersion, 2, "validation publishes the current state version")
  Assert.deepEqual(canonical.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "validation sorts its registrations")
  Assert.equal(canonical.uniqueTotal, 3, "validation keeps the blind total")
  Assert.equal(canonical.score, 40, "validation keeps the saved score")
  Assert.equal(canonical.mailWritten, 7, "validation keeps the written-Mail total")
  local again = GameStatsSave.validate(canonical, refs())
  Assert.deepEqual(again, canonical, "canonical buckets validate idempotently")
end

function T.missing_buckets_migrate_empty_without_invention()
  local migrated = GameStatsSave.migrate(nil, refs())
  Assert.deepEqual(migrated, GameStatsSave.initial(), "a missing bucket migrates to the initial state")
  Assert.deepEqual(migrated.uniqueCaught, {}, "migration invents no registrations")
  Assert.equal(migrated.uniqueTotal, 0, "migration invents no unique count")
  Assert.equal(migrated.score, 0, "migration invents no score")
  Assert.equal(migrated.mailWritten, 0, "migration invents no written-Mail count")
  local owner = GameStats.restore(nil, refs())
  Assert.equal(owner:uniqueCount(), 0, "a missing bucket restores nothing counted")
  Assert.equal(owner:score(), 0, "a missing bucket restores a zero score")
  Assert.equal(owner:mailWrittenCount(), 0, "a missing bucket restores no written Mail")
  local roundTrip = GameStats.restore(migrated, refs())
  Assert.deepEqual(roundTrip:bucket(), migrated, "migration output restores and republishes unchanged")
end

function T.exact_v1_buckets_migrate_with_a_zero_written_count()
  local migrated = GameStatsSave.migrate(legacyBucket(), refs())
  Assert.equal(migrated.schema, "hgss-stats-v2", "migration publishes the current schema")
  Assert.equal(migrated.stateVersion, 2, "migration publishes the current state version")
  Assert.deepEqual(migrated.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "migration preserves the species totals")
  Assert.equal(migrated.uniqueTotal, 3, "migration preserves the blind total")
  Assert.equal(migrated.score, 40, "migration never resets existing score")
  Assert.equal(migrated.mailWritten, 0, "migration sets no historical written-Mail count")
  local owner = GameStats.restore(legacyBucket(), refs())
  Assert.equal(owner:mailWrittenCount(), 0, "a v1 bucket restores no written Mail")
  Assert.equal(owner:score(), 40, "a v1 bucket restores its score")
  local roundTrip = GameStats.restore(migrated, refs())
  Assert.deepEqual(roundTrip:bucket(), migrated, "v1 migration output restores and republishes unchanged")
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
    local bucket = { schema = "hgss-stats-v2", stateVersion = 2, uniqueCaught = {}, score = 0, extra = true }
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
    bucket.stateVersion = 3
    GameStatsSave.validate(bucket, refs())
  end, "incompatible state versions never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.mailWritten = nil
    GameStatsSave.validate(bucket, refs())
  end, "a missing written-Mail count never validates")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.mailWritten = -1
    GameStatsSave.validate(bucket, refs())
  end, "negative written-Mail counts never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.mailWritten = 1.5
    GameStatsSave.validate(bucket, refs())
  end, "fractional written-Mail counts never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.mailWritten = 1000000
    GameStatsSave.validate(bucket, refs())
  end, "written-Mail counts above the retail ceiling never validate")
  assertInvalid(function()
    GameStatsSave.migrate({ schema = "hgss-pokedex-v1", stateVersion = 1, seen = {}, caught = {} }, refs())
  end, "unsupported schemas never migrate")
  assertInvalid(function()
    GameStatsSave.migrate(
      { schema = "hgss-stats-v1", stateVersion = 1, uniqueCaught = {}, uniqueTotal = 0, score = 0, extra = true },
      refs()
    )
  end, "extended v1 buckets never migrate")
  assertInvalid(function()
    GameStatsSave.migrate(
      { schema = "hgss-stats-v1", stateVersion = 2, uniqueCaught = {}, uniqueTotal = 0, score = 0 },
      refs()
    )
  end, "shifted v1 versions never migrate")
  assertInvalid(function()
    GameStatsSave.migrate(
      { schema = "hgss-stats-v2", stateVersion = 1, uniqueCaught = {}, uniqueTotal = 0, score = 0, mailWritten = 0 },
      refs()
    )
  end, "shifted v2 versions never migrate")
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
