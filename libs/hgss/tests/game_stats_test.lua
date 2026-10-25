-- Live game-stats ownership: unique registrations increment blindly like
-- the retail counter (even for re-registrations), register scores award
-- their authoritative points, validation never partially mutates live
-- state, and stale or repeated publications fail before touching
-- anything. Uses literal species sets and mon records; the owner needs
-- no catalog, ROM, GPU, or product cache.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameStats = require("libs.hgss.src.mons.GameStats")

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
    schema = "hgss-stats-v1",
    stateVersion = 1,
    uniqueCaught = { "EEVEE" },
    uniqueTotal = 1,
    score = GameStats.SCORE_CAP - 10,
  }, refs())
  local clamped = nearCap:prepareChanges({ observations = registerObservations("CHIKORITA") })
  Assert.isTrue(clamped.changed, "a registration below the ceiling still reports a change")
  clamped.publish()
  Assert.equal(nearCap:score(), GameStats.SCORE_CAP, "the total never exceeds the retail ceiling")
  local capped = GameStats.restore({
    schema = "hgss-stats-v1",
    stateVersion = 1,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = GameStats.SCORE_CAP,
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
    schema = "hgss-stats-v1",
    stateVersion = 1,
    uniqueCaught = { "TOTODILE", "CHIKORITA" },
    uniqueTotal = 5,
    score = 40,
  }, refs())
  Assert.isTrue(restored:isCounted("CHIKORITA"), "every saved registration survives restore")
  Assert.isTrue(restored:isCounted("TOTODILE"), "every saved registration survives restore")
  Assert.isFalse(restored:isCounted("EEVEE"), "restore invents no unregistered species")
  Assert.equal(restored:uniqueCount(), 5, "restore keeps the blind total independently of the set")
  Assert.equal(restored:score(), 40, "restore keeps the saved score")
  Assert.equal(restored:revision(), 0, "restore starts at the initial revision")
  local missing = GameStats.restore(nil, refs())
  Assert.equal(missing:uniqueCount(), 0, "a missing bucket counts nothing")
  Assert.equal(missing:score(), 0, "a missing bucket scores nothing")
  local bucket = restored:bucket()
  Assert.equal(bucket.schema, "hgss-stats-v1", "the bucket publishes the current schema")
  Assert.equal(bucket.stateVersion, 1, "the bucket publishes the current state version")
  Assert.deepEqual(bucket.uniqueCaught, { "CHIKORITA", "TOTODILE" }, "the bucket sorts its registrations")
  Assert.equal(bucket.uniqueTotal, 5, "the bucket carries the blind total")
  Assert.equal(bucket.score, 40, "the bucket carries the live score")
  bucket.uniqueCaught[1] = "EEVEE"
  Assert.isFalse(restored:isCounted("EEVEE"), "the canonical bucket never aliases live state")
end

return { tests = T }
