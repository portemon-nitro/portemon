-- Live game-stats ownership: unique registrations increment blindly like
-- the retail counter (even for re-registrations), register scores award
-- their authoritative points, validation never partially mutates live
-- state, and stale or repeated publications fail before touching
-- anything. Uses literal species sets and mon records; the owner needs
-- no catalog, ROM, GPU, or product cache.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameStats = require("libs.hgss.src.mons.GameStats")
local GameStatsSave = require("libs.hgss.src.save.GameStatsSave")

local T = {}

local function speciesSet()
  return { CHIKORITA = true, TOTODILE = true, EEVEE = true }
end

local function newOwner()
  return GameStats.new({ species = speciesSet() })
end

local function refs()
  return { species = speciesSet() }
end

local function registerObservations(species)
  return {
    { kind = "unique_caught", species = species },
    {
      kind = "score",
      species = species,
      event = GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT,
      points = GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT],
    },
  }
end

local function scoreObservation(species)
  return {
    kind = "score",
    species = species,
    event = GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT,
    points = GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT],
  }
end

local function assertInvalid(fn, what)
  local err = Assert.throws(fn, what)
  Assert.isTrue(Errors.is(err), "rejections use the structured error path: " .. tostring(err))
  Assert.equal(err.code, "GAME_STATS_INVALID", "rejections carry the stats error identity")
end

function T.fresh_owner_counts_nothing_with_a_zero_score()
  local owner = newOwner()
  Assert.equal(owner:uniqueCount(), 0, "fresh stats count no registration")
  Assert.equal(owner:mailWrittenCount(), 0, "fresh stats count no written Mail")
  Assert.equal(owner:score(), 0, "fresh stats carry a zero score")
  Assert.equal(owner:revision(), 0, "fresh stats start at the initial revision")
  Assert.isFalse(owner:isCounted("CHIKORITA"), "fresh stats count no species")
end

function T.registration_counts_and_scores_with_its_retail_register_score()
  local owner = newOwner()
  local staged = owner:prepareChanges({ observations = registerObservations("CHIKORITA") })
  Assert.isTrue(staged.changed, "a fresh registration reports a change")
  Assert.isTrue(staged.isCurrent(), "the candidate is current before publication")
  staged.publish()
  Assert.isTrue(owner:isCounted("CHIKORITA"), "publication registers the staged species")
  Assert.equal(owner:uniqueCount(), 1, "publication counts exactly one registration")
  Assert.equal(
    owner:score(),
    GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT],
    "publication awards the authoritative register points"
  )
  Assert.equal(owner:revision(), 1, "one batch advances the revision exactly once")
end

function T.republished_species_counts_again_blindly_like_retail()
  local owner = newOwner()
  owner:prepareChanges({ observations = registerObservations("CHIKORITA") }):publish()
  local revision = owner:revision()
  local again = owner:prepareChanges({ observations = registerObservations("CHIKORITA") })
  Assert.isTrue(again.changed, "re-staging a registered species reports a change")
  Assert.isTrue(again.isCurrent(), "the second candidate is current before publication")
  again.publish()
  Assert.isFalse(again.isCurrent(), "publication consumes the second candidate")
  Assert.equal(owner:revision(), revision + 1, "the second publication advances the revision")
  Assert.equal(
    owner:score(),
    GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT] * 2,
    "the second publication awards its register points again"
  )
  Assert.equal(owner:uniqueCount(), 2, "the second publication increments the blind total again")
  Assert.isTrue(owner:isCounted("CHIKORITA"), "the counted set keeps the registered species")
end

function T.stale_and_repeated_publication_fail_before_mutation()
  local owner = newOwner()
  local revision = owner:revision()
  local earlier = owner:prepareChanges({ observations = registerObservations("CHIKORITA") })
  local later = owner:prepareChanges({ observations = registerObservations("TOTODILE") })
  Assert.isTrue(earlier.isCurrent() and later.isCurrent(), "both candidates start current")
  later.publish()
  Assert.isFalse(earlier.isCurrent(), "the first publication moves the revision past the older candidate")
  assertInvalid(function()
    earlier.publish()
  end, "a stale candidate never publishes after the revision moved")
  assertInvalid(function()
    later.publish()
  end, "a consumed candidate never publishes twice")
  Assert.isFalse(owner:isCounted("CHIKORITA"), "a stale publication never touches live stats")
  Assert.isTrue(owner:isCounted("TOTODILE"), "only the current publication lands")
  Assert.equal(owner:revision(), revision + 1, "exactly one publication advances the revision")
end

function T.invalid_observation_aborts_the_whole_batch_without_mutation()
  local owner = newOwner()
  local revision = owner:revision()
  assertInvalid(function()
    owner:prepareChanges({
      observations = {
        { kind = "unique_caught", species = "CHIKORITA" },
        { kind = "score", event = GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT, points = 9999 },
      },
    })
  end, "mismatched score points fail the whole preparation")
  Assert.isFalse(owner:isCounted("CHIKORITA"), "no earlier valid observation leaks through a failed batch")
  Assert.equal(owner:score(), 0, "a failed batch awards no points")
  Assert.equal(owner:revision(), revision, "a failed batch never advances the revision")
  assertInvalid(function()
    owner:prepareChanges({ observations = { { kind = "unique_caught", species = "MISSINGNO" } } })
  end, "unknown species never stage")
  assertInvalid(function()
    owner:prepareChanges({ observations = { { kind = "seen", species = "CHIKORITA" } } })
  end, "unknown observation kinds never stage")
  assertInvalid(function()
    owner:prepareChanges({ observations = { { kind = "mail_written", species = "CHIKORITA" } } })
  end, "written-Mail observations carry no species")
  assertInvalid(function()
    owner:prepareChanges({
      observations = { { kind = "score", event = "no_such_event", points = 1 } },
    })
  end, "unknown score events never stage")
  assertInvalid(function()
    owner:prepareChanges({
      observations = {
        { kind = "score", event = GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT, points = -20 },
      },
    })
  end, "negative score points never stage")
  assertInvalid(function()
    owner:prepareChanges({
      observations = { { kind = "unique_caught", species = "CHIKORITA", extra = true } },
    })
  end, "observations with unknown fields never stage")
  assertInvalid(function()
    owner:prepareChanges({
      observations = {
        {
          kind = "score",
          event = GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT,
          points = GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT],
        },
      },
    })
  end, "score observations without a species never stage")
  assertInvalid(function()
    owner:prepareChanges({ seen = { "CHIKORITA" } })
  end, "changes with unknown fields never stage")
  assertInvalid(function()
    owner:prepareChanges({})
  end, "changes without observations never stage")
  assertInvalid(function()
    owner:isCounted("MISSINGNO")
  end, "count reads reject unknown species")
end

function T.describe_projects_a_detached_registration_record()
  local owner = newOwner()
  local mon = { species = "EEVEE", form = 0, isEgg = false, personality = 7 }
  local described = owner:describe(mon)
  Assert.deepEqual(described, { species = "EEVEE", isEgg = false }, "description projects species and egg state")
  described.species = "TOTODILE"
  Assert.isFalse(owner:isCounted("TOTODILE"), "the detached record never aliases live state")
  assertInvalid(function()
    owner:describe({ species = "MISSINGNO", isEgg = false })
  end, "description rejects unknown species")
  assertInvalid(function()
    owner:describe({ species = "EEVEE" })
  end, "description requires the explicit egg flag")
  assertInvalid(function()
    owner:describe("EEVEE")
  end, "description requires an admitted mon record")
end

function T.score_accumulates_per_registration_and_caps_at_the_retail_ceiling()
  local owner = newOwner()
  owner:prepareChanges({ observations = registerObservations("CHIKORITA") }):publish()
  owner:prepareChanges({ observations = registerObservations("TOTODILE") }):publish()
  local points = GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT]
  Assert.equal(owner:score(), points * 2, "each fresh registration awards its register points")
  local nearCap = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = { "EEVEE" },
    uniqueTotal = 1,
    score = GameStats.SCORE_CAP - 10,
    mailWritten = 0,
    stepsBiked = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs())
  local clamped = nearCap:prepareChanges({ observations = registerObservations("CHIKORITA") })
  Assert.isTrue(clamped.changed, "a registration below the ceiling still reports a change")
  clamped.publish()
  Assert.equal(nearCap:score(), GameStats.SCORE_CAP, "the total never exceeds the retail ceiling")
  local capped = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = GameStats.SCORE_CAP,
    mailWritten = 0,
    stepsBiked = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs())
  local revision = capped:revision()
  local held = capped:prepareChanges({ observations = { scoreObservation("CHIKORITA") } })
  Assert.isFalse(held.changed, "points at the ceiling report no change")
  held.publish()
  Assert.equal(capped:score(), GameStats.SCORE_CAP, "points at the ceiling move nothing")
  Assert.equal(capped:revision(), revision, "a capped publication never advances the revision")
  Assert.isTrue(capped:isCounted("CHIKORITA"), "scoring still registers the earning species")
end

function T.restore_rebuilds_from_a_bucket_and_missing_starts_empty()
  local restored = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = { "TOTODILE", "CHIKORITA" },
    uniqueTotal = 5,
    score = 40,
    mailWritten = 9,
    stepsBiked = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs())
  Assert.isTrue(restored:isCounted("CHIKORITA"), "every saved registration survives restore")
  Assert.isTrue(restored:isCounted("TOTODILE"), "every saved registration survives restore")
  Assert.isFalse(restored:isCounted("EEVEE"), "restore invents no unregistered species")
  Assert.equal(restored:uniqueCount(), 5, "restore keeps the blind total independently of the set")
  Assert.equal(restored:score(), 40, "restore keeps the saved score")
  Assert.equal(restored:mailWrittenCount(), 9, "restore keeps the written-Mail total")
  Assert.equal(restored:revision(), 0, "restore starts at the initial revision")
  local missing = GameStats.restore(nil, refs())
  Assert.equal(missing:uniqueCount(), 0, "a missing bucket counts nothing")
  Assert.equal(missing:score(), 0, "a missing bucket scores nothing")
  Assert.equal(missing:mailWrittenCount(), 0, "a missing bucket counts no written Mail")
  local bucket = restored:bucket()
  Assert.equal(bucket.schema, GameStatsSave.SCHEMA, "the bucket publishes the current schema")
  Assert.equal(bucket.stateVersion, GameStatsSave.STATE_VERSION, "the bucket publishes the current state version")
  Assert.deepEqual(bucket.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "the bucket sorts its registrations")
  Assert.equal(bucket.uniqueTotal, 5, "the bucket carries the blind total")
  Assert.equal(bucket.score, 40, "the bucket carries the live score")
  Assert.equal(bucket.mailWritten, 9, "the bucket carries the written-Mail total")
  Assert.equal(bucket.stepsBiked, 0, "the bucket carries the steps-biked total")
  bucket.uniqueCaught[1] = "EEVEE"
  Assert.isFalse(restored:isCounted("EEVEE"), "the canonical bucket never aliases live state")
end

-- Every step taken on the Bicycle counts once (PlayerAvatar_CountStep),
-- saturating at the source's extra-wide stat ceiling.
function T.biked_steps_count_once_each_up_to_the_retail_ceiling()
  local owner = newOwner()
  local revision = owner:revision()
  owner:countBikedStep()
  owner:countBikedStep()
  Assert.equal(owner:stepsBikedCount(), 2, "each biked step counts once")
  Assert.equal(owner:revision(), revision + 2, "each counted step publishes")
  Assert.equal(owner:bucket().stepsBiked, 2, "the bucket carries the count")
  Assert.equal(owner:score(), 0, "biking scores nothing")
  local capped = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = 0,
    mailWritten = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
    stepsBiked = GameStats.STEPS_BIKED_CAP,
  }, refs())
  local cappedRevision = capped:revision()
  capped:countBikedStep()
  Assert.equal(capped:stepsBikedCount(), GameStats.STEPS_BIKED_CAP, "the count never exceeds its ceiling")
  Assert.equal(capped:revision(), cappedRevision, "a capped step publishes nothing")
end

function T.written_mail_counts_once_with_its_score_and_no_species_freshness()
  local owner = newOwner()
  local staged = owner:prepareChanges({ observations = { { kind = "mail_written" } } })
  Assert.isTrue(staged.changed, "a fresh write reports a change")
  staged.publish()
  Assert.equal(owner:mailWrittenCount(), 1, "one write increments its count once")
  Assert.equal(owner:score(), 1, "one write increments the score by one")
  Assert.isFalse(owner:isCounted("CHIKORITA"), "a write marks no species as counted")
  Assert.equal(owner:revision(), 1, "one write advances the revision exactly once")
end

function T.written_mail_caps_at_its_retail_ceiling_without_resetting_score()
  local owner = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = GameStats.SCORE_CAP - 3,
    mailWritten = 999998,
    stepsBiked = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs())
  owner:prepareChanges({ observations = { { kind = "mail_written" } } }):publish()
  Assert.equal(owner:mailWrittenCount(), 999999, "writes stop at the retail count ceiling")
  Assert.equal(owner:score(), GameStats.SCORE_CAP - 2, "the capped write still scores once")
  local capped = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = GameStats.SCORE_CAP,
    mailWritten = 999999,
    stepsBiked = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs())
  local revision = capped:revision()
  local held = capped:prepareChanges({ observations = registerObservations("CHIKORITA") })
  Assert.isTrue(held.changed, "a capped write still reports its registration change")
  held.publish()
  held = capped:prepareChanges({ observations = { { kind = "mail_written" } } })
  Assert.isFalse(held.changed, "writes at both ceilings report no change")
  held.publish()
  Assert.equal(capped:mailWrittenCount(), 999999, "the count never exceeds its ceiling")
  Assert.equal(capped:score(), GameStats.SCORE_CAP, "the score never exceeds its ceiling")
  Assert.equal(capped:revision(), revision + 1, "only the registration advanced the revision")
end

function T.written_mail_joins_mixed_batches_atomically()
  local owner = newOwner()
  local revision = owner:revision()
  local mixed = owner:prepareChanges({
    observations = {
      { kind = "unique_caught", species = "CHIKORITA" },
      { kind = "mail_written" },
    },
  })
  Assert.isTrue(mixed.changed, "a mixed batch reports a change")
  mixed.publish()
  Assert.equal(owner:uniqueCount(), 1, "the mixed batch counts its registration")
  Assert.equal(owner:mailWrittenCount(), 1, "the mixed batch counts its write")
  Assert.isTrue(owner:isCounted("CHIKORITA"), "the mixed batch marks its species")
  Assert.equal(owner:revision(), revision + 1, "a mixed batch advances the revision exactly once")
  assertInvalid(function()
    owner:prepareChanges({
      observations = {
        { kind = "mail_written" },
        { kind = "unique_caught", species = "MISSINGNO" },
      },
    })
  end, "a later invalid observation fails the whole batch")
  Assert.equal(owner:mailWrittenCount(), 1, "a failed batch adds no write")
  Assert.equal(owner:revision(), revision + 1, "a failed batch never advances the revision")
  local stale = owner:prepareChanges({ observations = registerObservations("TOTODILE") })
  local write = owner:prepareChanges({ observations = { { kind = "mail_written" } } })
  write.publish()
  Assert.isFalse(stale.isCurrent(), "the write publication moves past the older candidate")
  assertInvalid(function()
    stale.publish()
  end, "a stale candidate never publishes after a write")
  Assert.equal(owner:mailWrittenCount(), 2, "only the current write lands")
end

-- Scripted score events come from the source's sScoreMods table
-- (src/game_stats.c): ScrCmd_AddSpecialGameStat names the event only, and
-- the owner applies that event's weight under the existing ceiling and
-- revision rules. Event 1 (the Apricorn harvest) is one point, event 21 is
-- the retail species-caught receipt weight, and 26/31/39 sit at the
-- table's large end.
function T.script_score_events_credit_their_source_weights()
  local owner = newOwner()
  local expected = 0
  for _, case in ipairs({
    { event = 0, points = 1 },
    { event = 1, points = 1 },
    { event = 21, points = 20 },
    { event = 26, points = 10000 },
    { event = 31, points = 1000 },
    { event = 39, points = 10 },
  }) do
    local revision = owner:revision()
    owner:awardScriptScoreEvent(case.event)
    expected = expected + case.points
    Assert.equal(owner:score(), expected, "event " .. case.event .. " credits its source weight")
    Assert.equal(owner:revision(), revision + 1, "one award publishes exactly one change")
  end
  Assert.equal(owner:uniqueCount(), 0, "a scripted score registers no species")
  Assert.equal(owner:mailWrittenCount(), 0, "a scripted score writes no Mail")
  local bucket = owner:bucket()
  Assert.equal(bucket.score, expected, "the awarded score is the persisted score")
  Assert.equal(GameStats.restore(bucket, refs()):score(), expected, "the awarded score survives its saved bucket")
end

function T.script_score_event_rejects_events_outside_the_source_table()
  local owner = newOwner()
  owner:awardScriptScoreEvent(1)
  local score = owner:score()
  local revision = owner:revision()
  for _, event in ipairs({ 40, 41, 1000, 65535, -1, 1.5, "1" }) do
    assertInvalid(function()
      owner:awardScriptScoreEvent(event)
    end, "source event " .. tostring(event) .. " is outside the score table")
    Assert.equal(owner:score(), score, "a rejected event awards nothing")
    Assert.equal(owner:revision(), revision, "a rejected event publishes nothing")
  end
  assertInvalid(function()
    owner:awardScriptScoreEvent(nil)
  end, "an absent event is never scored")
  Assert.equal(owner:score(), score, "an absent event leaves the score alone")
end

function T.script_score_event_saturates_at_the_retail_ceiling()
  local nearCap = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = GameStats.SCORE_CAP - 5,
    mailWritten = 0,
    stepsBiked = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs())
  local revision = nearCap:revision()
  nearCap:awardScriptScoreEvent(21)
  Assert.equal(nearCap:score(), GameStats.SCORE_CAP, "the total never exceeds the retail ceiling")
  Assert.equal(nearCap:revision(), revision + 1, "a bounded award still publishes its change")
  local capped = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = GameStats.SCORE_CAP,
    mailWritten = 0,
    stepsBiked = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs())
  revision = capped:revision()
  capped:awardScriptScoreEvent(21)
  Assert.equal(capped:score(), GameStats.SCORE_CAP, "an award at the ceiling moves nothing")
  Assert.equal(capped:revision(), revision, "an award that changes nothing publishes nothing")
end

function T.script_score_event_never_revives_a_stale_candidate()
  local owner = newOwner()
  owner:prepareChanges({ observations = { { kind = "mail_written" } } }):publish()
  local stale = owner:prepareChanges({ observations = { { kind = "mail_written" } } })
  local revision = owner:revision()
  owner:awardScriptScoreEvent(21)
  Assert.equal(owner:score(), 21, "the scripted event lands on the live score")
  Assert.equal(owner:revision(), revision + 1, "the award publishes one change")
  assertInvalid(function()
    stale.publish()
  end, "a candidate staged before the award is stale")
  Assert.equal(owner:score(), 21, "the stale candidate never rewinds the awarded score")
  Assert.equal(owner:revision(), revision + 1, "the stale publication moves no revision")
end

function T.league_win_counts_once_per_clear_and_caps_at_the_source_ceiling()
  local owner = newOwner()
  Assert.equal(owner:leagueWins(), 0, "a fresh owner records no League win")
  owner:awardLeagueWin()
  Assert.equal(owner:leagueWins(), 1, "one award records one League win")
  Assert.equal(owner:score(), 0, "the League-win statistic earns no score")
  Assert.isFalse(owner:isCounted("CHIKORITA"), "the League-win statistic marks no species")
  local revision = owner:revision()
  owner:awardLeagueWin()
  Assert.equal(owner:leagueWins(), 2, "every completed clear records one win")
  Assert.equal(owner:revision(), revision + 1, "each award publishes one change")
  local capped = GameStats.restore({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = 0,
    mailWritten = 0,
    stepsBiked = 0,
    leagueWins = GameStats.LEAGUE_WINS_CAP,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs())
  Assert.equal(capped:leagueWins(), GameStats.LEAGUE_WINS_CAP, "the saved total restores")
  local cappedRevision = capped:revision()
  capped:awardLeagueWin()
  Assert.equal(capped:leagueWins(), GameStats.LEAGUE_WINS_CAP, "the total never exceeds the source ceiling")
  Assert.equal(capped:revision(), cappedRevision, "an award at the ceiling publishes nothing")
  Assert.equal(capped:bucket().leagueWins, GameStats.LEAGUE_WINS_CAP, "the bucket carries the capped total")
end

-- The Day Care deposit statistic joins the revisioned preparation: one
-- completed deposit adds one under the shared u16 ceiling, marks no species,
-- awards no score, and survives the bucket round trip. The hatch counter has no
-- producer yet, so it stays at zero and round-trips unchanged.
function T.daycare_deposits_count_once_without_scoring()
  local owner = newOwner()
  local revision = owner:revision()
  local prepared = owner:prepareChanges({ observations = { { kind = "daycare_deposit" } } })
  Assert.isTrue(prepared.changed)
  Assert.isTrue(prepared.isCurrent())
  Assert.equal(owner:daycareDeposits(), 0, "staging never mutates live counters")
  prepared.publish()
  Assert.equal(owner:daycareDeposits(), 1)
  Assert.equal(owner:score(), 0, "a deposit awards no score")
  Assert.equal(owner:uniqueCount(), 0, "a deposit registers no species")
  Assert.equal(owner:revision(), revision + 1)
  Assert.isFalse(prepared.isCurrent())
  Assert.throws(function()
    prepared.publish()
  end, "a repeated publication is a programming error")
  Assert.equal(owner:daycareDeposits(), 1, "a duplicate publish never counts twice")

  local bucket = owner:bucket()
  Assert.equal(bucket.daycareDeposits, 1)
  Assert.equal(bucket.eggsHatched, 0, "the hatch counter has no producer in this slice")
  local restored = GameStats.restore(bucket, refs())
  Assert.equal(restored:daycareDeposits(), 1, "the deposit total round-trips")
  Assert.deepEqual(restored:bucket(), bucket, "the rest of the bucket round-trips unchanged")
end

function T.daycare_deposits_saturate_at_the_statistic_ceiling()
  local owner = newOwner()
  local observations = {}
  for index = 1, 40 do
    observations[index] = { kind = "daycare_deposit" }
  end
  for _ = 1, 300 do
    owner:prepareChanges({ observations = observations }):publish()
  end
  Assert.equal(owner:daycareDeposits(), GameStats.DAYCARE_DEPOSITS_CAP, "the u16 ceiling holds")
end

function T.daycare_deposit_observations_carry_no_payload()
  local owner = newOwner()
  Assert.throws(function()
    owner:prepareChanges({
      observations = { { kind = "daycare_deposit", species = "CHIKORITA" } },
    })
  end, "a deposit observation carries no payload")
end

return { tests = T }
