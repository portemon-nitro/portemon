-- Game-stats save bucket: strict persisted shape, canonical detached
-- output, and evidence-preserving migration from a missing bucket or an
-- exact earlier bucket. Each step adds bounded counters (v2 the written Mail
-- total, v3 the steps-biked total, v4 the League-win total, v5 the Day Care
-- deposit and hatch totals); migration never invents a historical count.
-- Uses literal buckets plus small synthetic species sets; no ROM, GPU, or
-- product cache is touched.

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
    schema = "hgss-stats-v5",
    stateVersion = 5,
    uniqueCaught = { "TOTODILE", "CHIKORITA" },
    uniqueTotal = 3,
    score = 40,
    mailWritten = 7,
    stepsBiked = 1500,
    leagueWins = 2,
    daycareDeposits = 5,
    eggsHatched = 1,
    battlePointsReceived = 96,
    battlePointsSpent = 64,
  }
end
local function v4Bucket()
  return {
    schema = "hgss-stats-v4",
    stateVersion = 4,
    uniqueCaught = { "TOTODILE", "CHIKORITA" },
    uniqueTotal = 3,
    score = 40,
    mailWritten = 7,
    stepsBiked = 1500,
    leagueWins = 2,
  }
end

local function v3Bucket()
  return {
    schema = "hgss-stats-v3",
    stateVersion = 3,
    uniqueCaught = { "TOTODILE", "CHIKORITA" },
    uniqueTotal = 3,
    score = 40,
    mailWritten = 7,
    stepsBiked = 1500,
  }
end

local function v2Bucket()
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
  Assert.equal(canonical.schema, "hgss-stats-v5", "validation publishes the current schema")
  Assert.equal(canonical.stateVersion, GameStatsSave.STATE_VERSION, "validation publishes the current state version")
  Assert.deepEqual(canonical.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "validation sorts its registrations")
  Assert.equal(canonical.uniqueTotal, 3, "validation keeps the blind total")
  Assert.equal(canonical.score, 40, "validation keeps the saved score")
  Assert.equal(canonical.mailWritten, 7, "validation keeps the written-Mail total")
  Assert.equal(canonical.stepsBiked, 1500, "validation keeps the steps-biked total")
  Assert.equal(canonical.leagueWins, 2, "validation keeps the League-win total")
  Assert.equal(canonical.daycareDeposits, 5, "validation keeps the Day Care deposit total")
  Assert.equal(canonical.eggsHatched, 1, "validation keeps the hatch total")
  Assert.equal(canonical.battlePointsReceived, 96, "validation keeps the received-point total")
  Assert.equal(canonical.battlePointsSpent, 64, "validation keeps the spent-point total")
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
  Assert.equal(migrated.stepsBiked, 0, "migration invents no steps-biked count")
  Assert.equal(migrated.leagueWins, 0, "migration invents no League win")
  Assert.equal(migrated.daycareDeposits, 0, "migration invents no Day Care deposit")
  Assert.equal(migrated.eggsHatched, 0, "migration invents no hatch")
  local owner = GameStats.restore(nil, refs())
  Assert.equal(owner:uniqueCount(), 0, "a missing bucket restores nothing counted")
  Assert.equal(owner:score(), 0, "a missing bucket restores a zero score")
  Assert.equal(owner:mailWrittenCount(), 0, "a missing bucket restores no written Mail")
  Assert.equal(owner:leagueWins(), 0, "a missing bucket restores no League win")
  local roundTrip = GameStats.restore(migrated, refs())
  Assert.deepEqual(roundTrip:bucket(), migrated, "migration output restores and republishes unchanged")
end

function T.exact_v1_buckets_migrate_with_zero_untracked_totals()
  local migrated = GameStatsSave.migrate(legacyBucket(), refs())
  Assert.equal(migrated.schema, GameStatsSave.SCHEMA, "migration publishes the current schema")
  Assert.equal(migrated.stateVersion, GameStatsSave.STATE_VERSION, "migration publishes the current state version")
  Assert.deepEqual(migrated.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "migration preserves the species totals")
  Assert.equal(migrated.uniqueTotal, 3, "migration preserves the blind total")
  Assert.equal(migrated.score, 40, "migration never resets existing score")
  Assert.equal(migrated.mailWritten, 0, "migration sets no historical written-Mail count")
  Assert.equal(migrated.stepsBiked, 0, "migration sets no historical steps-biked count")
  Assert.equal(migrated.leagueWins, 0, "migration sets no historical League win")
  Assert.equal(migrated.daycareDeposits, 0, "migration sets no historical Day Care deposit")
  Assert.equal(migrated.eggsHatched, 0, "migration sets no historical hatch")
  local owner = GameStats.restore(legacyBucket(), refs())
  Assert.equal(owner:mailWrittenCount(), 0, "a v1 bucket restores no written Mail")
  Assert.equal(owner:score(), 40, "a v1 bucket restores its score")
  local roundTrip = GameStats.restore(migrated, refs())
  Assert.deepEqual(roundTrip:bucket(), migrated, "v1 migration output restores and republishes unchanged")
end

function T.exact_v2_buckets_migrate_with_zero_later_counts()
  local migrated = GameStatsSave.migrate(v2Bucket(), refs())
  Assert.equal(migrated.schema, GameStatsSave.SCHEMA, "migration publishes the current schema")
  Assert.equal(migrated.stateVersion, GameStatsSave.STATE_VERSION, "migration publishes the current state version")
  Assert.deepEqual(migrated.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "migration preserves the species totals")
  Assert.equal(migrated.uniqueTotal, 3, "migration preserves the blind total")
  Assert.equal(migrated.score, 40, "migration never resets existing score")
  Assert.equal(migrated.mailWritten, 7, "migration preserves the written-Mail total")
  Assert.equal(migrated.stepsBiked, 0, "migration sets no historical steps-biked count")
  Assert.equal(migrated.leagueWins, 0, "migration sets no historical League win")
  Assert.equal(migrated.daycareDeposits, 0, "migration sets no historical Day Care deposit")
  Assert.equal(migrated.eggsHatched, 0, "migration sets no historical hatch")
  local owner = GameStats.restore(v2Bucket(), refs())
  Assert.equal(owner:mailWrittenCount(), 7, "a v2 bucket restores its written Mail")
  Assert.equal(owner:stepsBikedCount(), 0, "a v2 bucket restores no biked steps")
  Assert.equal(owner:leagueWins(), 0, "a v2 bucket restores no League win")
  local roundTrip = GameStats.restore(migrated, refs())
  Assert.deepEqual(roundTrip:bucket(), migrated, "v2 migration output restores and republishes unchanged")
end

function T.exact_v3_buckets_migrate_with_zero_later_counts()
  local migrated = GameStatsSave.migrate(v3Bucket(), refs())
  Assert.equal(migrated.schema, GameStatsSave.SCHEMA, "migration publishes the current schema")
  Assert.equal(migrated.stateVersion, GameStatsSave.STATE_VERSION, "migration publishes the current state version")
  Assert.equal(migrated.score, 40, "migration keeps the score")
  Assert.equal(migrated.mailWritten, 7, "migration keeps the written-Mail total")
  Assert.equal(migrated.stepsBiked, 1500, "migration keeps the steps-biked total")
  Assert.equal(migrated.leagueWins, 0, "migration sets no historical League win")
  Assert.equal(migrated.daycareDeposits, 0, "migration sets no historical Day Care deposit")
  Assert.equal(migrated.eggsHatched, 0, "migration sets no historical hatch")
  local owner = GameStats.restore(v3Bucket(), refs())
  Assert.equal(owner:stepsBikedCount(), 1500, "a v3 bucket restores its biked steps")
  Assert.equal(owner:leagueWins(), 0, "a v3 bucket restores no League win")
  Assert.deepEqual(GameStats.restore(migrated, refs()):bucket(), migrated, "v3 migration output round-trips")
end

-- The v5 step adds the two Day Care counters at zero and keeps every earlier
-- statistic: no historical deposit or hatch can be inferred, and the hatch
-- total stays at zero until its own owner lands.
function T.exact_v4_buckets_migrate_with_zero_care_counters()
  local migrated = GameStatsSave.migrate(v4Bucket(), refs())
  Assert.equal(migrated.schema, GameStatsSave.SCHEMA, "migration publishes the current schema")
  Assert.equal(migrated.stateVersion, GameStatsSave.STATE_VERSION, "migration publishes the current state version")
  Assert.equal(migrated.daycareDeposits, 0, "migration invents no deposit count")
  Assert.equal(migrated.eggsHatched, 0, "migration invents no hatch count")
  Assert.deepEqual(migrated.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "earlier registrations survive")
  Assert.equal(migrated.uniqueTotal, 3, "migration preserves the blind total")
  Assert.equal(migrated.score, 40, "migration keeps the score")
  Assert.equal(migrated.mailWritten, 7, "migration keeps the written-Mail total")
  Assert.equal(migrated.stepsBiked, 1500, "migration keeps the steps-biked total")
  Assert.equal(migrated.leagueWins, 2, "the League-win total survives the care step")
end

-- The save envelope's own step has no catalog: it advances the schema and the
-- care counters while the stored registration set rides along for the runtime
-- restore that validates it against the generated species catalog.
function T.envelope_advance_keeps_the_stored_registrations_without_a_catalog()
  local bucket = v4Bucket()
  bucket.uniqueCaught = { "CUSTOM_SPECIES", "CHIKORITA" }
  local advanced = GameStatsSave.migrate(bucket, nil)
  Assert.equal(advanced.schema, GameStatsSave.SCHEMA)
  Assert.deepEqual(advanced.uniqueCaught, { "CUSTOM_SPECIES", "CHIKORITA" }, "the stored set is copied verbatim")
  Assert.equal(advanced.daycareDeposits, 0)
  Assert.equal(advanced.eggsHatched, 0)
  assertInvalid(function()
    GameStatsSave.validate({
      schema = GameStatsSave.SCHEMA,
      stateVersion = GameStatsSave.STATE_VERSION,
      uniqueCaught = { "CUSTOM_SPECIES" },
      uniqueTotal = 1,
      score = 0,
      mailWritten = 0,
      stepsBiked = 0,
      leagueWins = 0,
      daycareDeposits = 0,
      eggsHatched = 0,
    }, refs())
  end, "a catalogued restore still refuses an unknown species")
end

-- Both care counters are bounded u16 statistics.
function T.care_counters_are_bounded()
  for _, field in ipairs({ "daycareDeposits", "eggsHatched" }) do
    for _, value in ipairs({ -1, 10000, 1.5, "3" }) do
      local bucket = validBucket()
      bucket[field] = value
      assertInvalid(function()
        GameStatsSave.validate(bucket, refs())
      end, "the stats bucket bounds " .. field .. " to its u16 range")
    end
  end
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
    local bucket = { schema = "hgss-stats-v4", stateVersion = 4, uniqueCaught = {}, score = 0, extra = true }
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
    bucket.stateVersion = 4
    GameStatsSave.validate(bucket, refs())
  end, "incompatible state versions never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.leagueWins = nil
    GameStatsSave.validate(bucket, refs())
  end, "a missing League-win total never validates")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.leagueWins = -1
    GameStatsSave.validate(bucket, refs())
  end, "negative League-win totals never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.leagueWins = 1.5
    GameStatsSave.validate(bucket, refs())
  end, "fractional League-win totals never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.leagueWins = GameStatsSave.LEAGUE_WINS_CAP + 1
    GameStatsSave.validate(bucket, refs())
  end, "League-win totals above the source ceiling never validate")
  assertInvalid(function()
    local bucket = v4Bucket()
    bucket.leagueWins = nil
    GameStatsSave.migrate(bucket, refs())
  end, "a v4 bucket missing its League-win total never migrates")
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
    local bucket = validBucket()
    bucket.stepsBiked = nil
    GameStatsSave.validate(bucket, refs())
  end, "a missing steps-biked count never validates")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.stepsBiked = 1000000000
    GameStatsSave.validate(bucket, refs())
  end, "steps-biked counts above the retail ceiling never validate")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.daycareDeposits = nil
    GameStatsSave.validate(bucket, refs())
  end, "a missing Day Care deposit count never validates")
  assertInvalid(function()
    local bucket = validBucket()
    bucket.eggsHatched = nil
    GameStatsSave.validate(bucket, refs())
  end, "a missing hatch count never validates")
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
    local bucket = v2Bucket()
    bucket.stepsBiked = 3
    GameStatsSave.migrate(bucket, refs())
  end, "extended v2 buckets never migrate")
  assertInvalid(function()
    GameStatsSave.migrate(
      {
        schema = "hgss-stats-v3",
        stateVersion = 2,
        uniqueCaught = {},
        uniqueTotal = 0,
        score = 0,
        mailWritten = 0,
        stepsBiked = 0,
      },
      refs()
    )
  end, "shifted v3 versions never migrate")
  assertInvalid(function()
    local bucket = v3Bucket()
    bucket.leagueWins = 1
    GameStatsSave.migrate(bucket, refs())
  end, "a v3 bucket carrying a League-win total never migrates")
  assertInvalid(function()
    local bucket = v4Bucket()
    bucket.eggsHatched = 1
    GameStatsSave.migrate(bucket, refs())
  end, "a v4 bucket carrying a care counter never migrates")
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

-- The v4 bucket predates both Day Care and Battle Point counters.
function T.v4_bucket_migrates_with_zero_battle_point_counters()
  local migrated = GameStatsSave.migrate(v4Bucket(), refs())
  Assert.equal(migrated.battlePointsReceived, 0, "migration invents no received point")
  Assert.equal(migrated.battlePointsSpent, 0, "migration invents no spent point")
  Assert.equal(migrated.daycareDeposits, 0, "migration invents no deposit count")
  Assert.equal(migrated.eggsHatched, 0, "migration invents no hatch count")
  Assert.equal(migrated.stepsBiked, 1500, "the earlier steps-biked total survives")
  Assert.equal(migrated.leagueWins, 2, "the earlier League-win total survives")
  local owner = GameStats.restore(v4Bucket(), refs())
  Assert.equal(owner:battlePointsReceived(), 0, "a v4 bucket restores no received point")
  Assert.equal(owner:battlePointsSpent(), 0, "a v4 bucket restores no spent point")
  Assert.deepEqual(owner:bucket(), migrated, "the migrated bucket round trips through its owner")
end

-- Both Point counters use the source's extra-wide statistic ceiling.
function T.battle_point_counters_are_bounded()
  for _, field in ipairs({ "battlePointsReceived", "battlePointsSpent" }) do
    for _, value in ipairs({ -1, 1000000000, 1.5, "3" }) do
      local bucket = validBucket()
      bucket[field] = value
      assertInvalid(function()
        GameStatsSave.validate(bucket, refs())
      end, "the stats bucket bounds " .. field .. " to the source range")
    end
    local bucket = validBucket()
    bucket[field] = 999999999
    Assert.equal(
      GameStatsSave.validate(bucket, refs())[field],
      999999999,
      "the source ceiling validates for " .. field
    )
  end
end
return { tests = T }
