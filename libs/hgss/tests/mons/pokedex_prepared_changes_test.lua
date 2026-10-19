-- Dex prepared-change atomicity: validation never partially mutates live
-- knowledge, stale and repeated publications fail before touching state,
-- no-op publications consume without advancing the revision, and one batch
-- advances the revision exactly once. Uses the small synthetic
-- mon/catalog fixtures; no ROM, GPU, or product cache is touched.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local T = {}

local function newOwner()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, PokedexDexFixture.buildPokedexCatalog()))
  return owner, monCatalog
end

local function assertInvalid(fn, what)
  local err = Assert.throws(fn, what)
  Assert.isTrue(Errors.is(err), "rejections use the structured error path: " .. tostring(err))
  Assert.equal(err.code, "POKEDEX_INVALID", "rejections carry the dex error identity")
end

local function seenDescriptor(owner, monCatalog, fields)
  return owner:describe(PokedexDexFixture.makeMon(monCatalog, fields))
end

function T.invalid_observation_aborts_the_whole_batch_without_mutation()
  local owner, monCatalog = newOwner()
  local valid = seenDescriptor(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local revision = owner:revision()
  assertInvalid(function()
    owner:prepareChanges({
      observations = {
        { kind = "seen", specimen = valid },
        {
          kind = "caught",
          specimen = {
            species = "CHIKORITA",
            form = 0,
            gender = "female",
            personality = "not-a-personality",
            language = "english",
            isEgg = false,
            shiny = false,
          },
        },
      },
    })
  end, "a later invalid observation fails the whole preparation")
  Assert.isFalse(owner:isSeen("CHIKORITA"), "no earlier valid observation leaks through a failed batch")
  Assert.deepEqual(owner:bucket().seen, {}, "a failed batch leaves every persisted field unchanged")
  Assert.equal(owner:revision(), revision, "a failed batch never advances the revision")
end

function T.stale_and_repeated_publication_fail_before_mutation()
  local owner, monCatalog = newOwner()
  local first = seenDescriptor(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  local second = seenDescriptor(owner, monCatalog, { species = "TOTODILE", personality = 31 })
  local revision = owner:revision()
  local earlier = owner:prepareChanges({ observations = { { kind = "seen", specimen = first } } })
  local later = owner:prepareChanges({ observations = { { kind = "seen", specimen = second } } })
  Assert.isTrue(earlier.isCurrent() and later.isCurrent(), "both candidates start current")
  later.publish()
  Assert.isFalse(earlier.isCurrent(), "the first publication moves the revision past the older candidate")
  assertInvalid(function()
    earlier.publish()
  end, "a stale candidate never publishes after the revision moved")
  assertInvalid(function()
    later.publish()
  end, "a consumed candidate never publishes twice")
  Assert.isFalse(owner:isSeen("CHIKORITA"), "a stale publication never touches live knowledge")
  Assert.isTrue(owner:isSeen("TOTODILE"), "only the current publication lands")
  Assert.equal(owner:revision(), revision + 1, "exactly one publication advances the revision")
end

function T.noop_publication_consumes_without_advancing_revision()
  local owner, monCatalog = newOwner()
  local specimen = seenDescriptor(owner, monCatalog, { species = "CHIKORITA", personality = 0 })
  owner:prepareChanges({ observations = { { kind = "seen", specimen = specimen } } }):publish()
  local revision = owner:revision()
  local noop = owner:prepareChanges({ observations = { { kind = "seen", specimen = specimen } } })
  Assert.isFalse(noop.changed, "repeating settled history reports no change")
  Assert.isTrue(noop.isCurrent(), "the no-op candidate is current before publication")
  noop.publish()
  Assert.isFalse(noop.isCurrent(), "publication consumes the no-op candidate")
  Assert.equal(owner:revision(), revision, "a no-op publication never advances the revision")
  assertInvalid(function()
    noop.publish()
  end, "a consumed no-op candidate never publishes twice")
end

function T.one_batch_advances_revision_exactly_once()
  local owner, monCatalog = newOwner()
  local revision = owner:revision()
  local batch = owner:prepareChanges({
    observations = {
      {
        kind = "seen",
        specimen = seenDescriptor(owner, monCatalog, { species = "CHIKORITA", personality = 0 }),
      },
      {
        kind = "caught",
        specimen = seenDescriptor(owner, monCatalog, { species = "TOTODILE", personality = 31 }),
      },
      {
        kind = "caught",
        specimen = seenDescriptor(owner, monCatalog, { species = "EEVEE", personality = 31, language = "french" }),
      },
    },
    flags = { canDetectForms = true },
    resume = { mode = "johto" },
  })
  Assert.isTrue(batch.changed, "a batch with fresh facts reports a change")
  batch.publish()
  Assert.equal(owner:revision(), revision + 1, "one batch advances the revision exactly once")
  Assert.isTrue(owner:isSeen("CHIKORITA"), "every staged observation lands in one publication")
  Assert.isTrue(owner:isCaught("TOTODILE"), "every staged observation lands in one publication")
  Assert.isTrue(owner:canDetectForms(), "staged flags land with the same publication")
  Assert.deepEqual(owner:resume(), { mode = "johto" }, "the staged resume lands with the same publication")
end

function T.flags_and_resume_stage_through_the_same_candidate()
  local owner = newOwner()
  local seed = owner:prepareChanges({ flags = { dexEnabled = true, nationalDex = true } })
  Assert.isTrue(seed.changed, "capability flags stage as a change")
  seed.publish()
  Assert.isTrue(owner:hasPokedex(), "staged dex ownership publishes")
  Assert.isTrue(owner:hasNationalDex(), "staged national ownership publishes")
  Assert.isFalse(owner:hasInternationalDex(), "omitted flags stay unchanged")
  Assert.isFalse(owner:canDetectForms(), "omitted flags stay unchanged")
  local revision = owner:revision()
  assertInvalid(function()
    owner:prepareChanges({ flags = { dexEnabled = "yes" } })
  end, "a mistyped flag fails the whole preparation")
  Assert.equal(owner:revision(), revision, "a failed flag preparation never advances the revision")
  local resumeOnly = owner:prepareChanges({ resume = { mode = "national", species = "EEVEE" } })
  resumeOnly.publish()
  Assert.deepEqual(
    owner:resume(),
    { mode = "national", species = "EEVEE" },
    "a resume-only candidate publishes without touching flags"
  )
  Assert.isTrue(owner:hasPokedex(), "a resume-only candidate never clears staged flags")
end

return { tests = T }
