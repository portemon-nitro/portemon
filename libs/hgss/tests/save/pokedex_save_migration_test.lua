-- Dex save migration and strict persisted shape: legacy and missing
-- buckets preserve every valid bit without inventing provenance, valid v2
-- flags stay authoritative over stale legacy seeds, malformed v2 records
-- fail with attribution, and unrelated catalog additions never renumber
-- saved logical variants. Uses literal buckets plus the small synthetic
-- fixtures; no ROM, GPU, or product cache is touched.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")

local T = {}

local function fixtures()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local pokedexCatalog = PokedexDexFixture.buildPokedexCatalog()
  return monCatalog, pokedexCatalog
end

local function refsWithLegacy(monCatalog, pokedexCatalog, legacyFlags)
  local refs = PokedexDexFixture.refs(monCatalog, pokedexCatalog)
  refs.legacyFlags = legacyFlags
  return refs
end

local function legacySeeds()
  return {
    dexEnabled = true,
    nationalDex = true,
    enabledInternational = false,
    canDetectForms = false,
  }
end

local function legacyBucket()
  return {
    schema = "hgss-pokedex-v1",
    stateVersion = 1,
    seen = { "CHIKORITA", "TOTODILE" },
    caught = { "TOTODILE", "SPINDA" },
  }
end

local function validBucket()
  return {
    schema = "hgss-pokedex-v2",
    stateVersion = 2,
    seen = { "CHIKORITA", "PICHU", "SPINDA", "TOTODILE", "UNOWN" },
    caught = { "SPINDA", "TOTODILE", "UNOWN" },
    flags = {
      dexEnabled = true,
      nationalDex = false,
      enabledInternational = false,
      canDetectForms = false,
    },
    history = {
      CHIKORITA = { genders = { "female" } },
      PICHU = { genders = { "male", "female" }, variants = { 0, 2 } },
      SPINDA = { genders = { "female" }, languages = { "english" }, firstPersonality = 0 },
      TOTODILE = { genders = { "female" }, languages = { "french" } },
      UNOWN = {
        genders = { "genderless" },
        variants = { 0, 5 },
        caughtVariants = { 0 },
        languages = { "english" },
      },
    },
    resume = {},
  }
end

local function assertInvalid(fn, what)
  local err = Assert.throws(fn, what)
  Assert.isTrue(Errors.is(err), "rejections use the structured error path: " .. tostring(err))
  Assert.equal(err.code, "POKEDEX_INVALID", "rejections carry the dex error identity")
end

function T.legacy_bits_migrate_without_inventing_provenance()
  local monCatalog, pokedexCatalog = fixtures()
  local input = legacyBucket()
  local refs = refsWithLegacy(monCatalog, pokedexCatalog, legacySeeds())
  local owner = PokedexKnowledge.restore(input, refs)
  Assert.isTrue(owner:isSeen("CHIKORITA"), "every valid seen bit survives migration")
  Assert.isTrue(owner:isSeen("SPINDA"), "caught-only keys union into seen as before")
  Assert.isTrue(owner:isCaught("SPINDA"), "every valid caught bit survives migration")
  Assert.deepEqual(owner:observedGenders("SPINDA"), {}, "migrated bits carry no invented gender history")
  Assert.deepEqual(owner:observedGenders("TOTODILE"), {}, "migrated bits carry no invented gender history")
  Assert.deepEqual(owner:observedVariants("PICHU"), {}, "migrated bits carry no invented variant history")
  Assert.isNil(owner:firstPersonality("SPINDA"), "a migrated caught Spinda keeps its personality unknown")
  Assert.deepEqual(owner:resume(), {}, "migration preserves the unset resume mode")
  Assert.isTrue(owner:hasPokedex(), "the dex seed enables ownership")
  Assert.isTrue(owner:hasNationalDex(), "the national seed enables national ownership")
  Assert.isFalse(owner:hasInternationalDex(), "historically absent capabilities seed false")
  Assert.isFalse(owner:canDetectForms(), "historically absent capabilities seed false")
  local bucket = owner:bucket()
  Assert.equal(bucket.schema, "hgss-pokedex-v2", "migration publishes the current schema")
  Assert.equal(bucket.stateVersion, 2, "migration publishes the current state version")
  Assert.deepEqual(bucket.seen, { "CHIKORITA", "SPINDA", "TOTODILE" }, "the canonical bits sort unioned")
  Assert.deepEqual(bucket.caught, { "SPINDA", "TOTODILE" }, "the canonical caught bits sort")
  Assert.deepEqual(bucket.flags, legacySeeds(), "migration publishes exactly the seeded capability flags")
  Assert.deepEqual(bucket.history, {}, "migration publishes no fabricated history rows")
  Assert.deepEqual(bucket.resume, {}, "migration publishes the unset resume")
  Assert.deepEqual(input, legacyBucket(), "migration never mutates its persisted input")
end

function T.missing_bucket_starts_empty_with_legacy_seeds()
  local monCatalog, pokedexCatalog = fixtures()
  local refs = refsWithLegacy(monCatalog, pokedexCatalog, legacySeeds())
  local owner = PokedexKnowledge.restore(nil, refs)
  Assert.deepEqual(owner:bucket().seen, {}, "a missing bucket starts with no seen bits")
  Assert.deepEqual(owner:bucket().caught, {}, "a missing bucket starts with no caught bits")
  Assert.deepEqual(owner:bucket().history, {}, "a missing bucket starts with no history")
  Assert.isTrue(owner:hasPokedex(), "a missing bucket still honors the dex seed")
  Assert.isTrue(owner:hasNationalDex(), "a missing bucket still honors the national seed")
  Assert.deepEqual(owner:resume(), {}, "a missing bucket starts with the unset resume")
end

function T.later_observations_initialize_unknown_provenance()
  local monCatalog, pokedexCatalog = fixtures()
  local refs = refsWithLegacy(monCatalog, pokedexCatalog, legacySeeds())
  local owner = PokedexKnowledge.restore(legacyBucket(), refs)
  local specimen =
    owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "SPINDA", personality = 305420031 }))
  owner:prepareChanges({ observations = { { kind = "caught", specimen = specimen } } }):publish()
  Assert.equal(
    owner:firstPersonality("SPINDA"),
    305420031,
    "the first actual observation initializes the unknown provenance"
  )
  Assert.deepEqual(
    owner:observedGenders("SPINDA"),
    { "male" },
    "the first actual observation initializes the unknown gender history"
  )
end

function T.valid_v2_flags_ignore_stale_legacy_seeds()
  local monCatalog, pokedexCatalog = fixtures()
  local refs = PokedexDexFixture.refs(monCatalog, pokedexCatalog)
  local owner = PokedexKnowledge.restore(validBucket(), refs)
  Assert.isTrue(owner:hasPokedex(), "valid v2 flags stand without legacy seeds")
  Assert.isFalse(owner:hasNationalDex(), "valid v2 flags stand without legacy seeds")
  Assert.deepEqual(owner:bucket().flags, validBucket().flags, "v2 buckets round-trip their own flags")
  local conflicting = refsWithLegacy(monCatalog, pokedexCatalog, {
    dexEnabled = false,
    nationalDex = true,
    enabledInternational = true,
    canDetectForms = true,
  })
  local again = PokedexKnowledge.restore(owner:bucket(), conflicting)
  Assert.isTrue(again:hasPokedex(), "stale legacy seeds never overwrite valid v2 ownership")
  Assert.isFalse(again:hasNationalDex(), "stale legacy seeds never overwrite valid v2 ownership")
  Assert.isFalse(again:hasInternationalDex(), "stale legacy seeds never overwrite valid v2 capabilities")
  Assert.isFalse(again:canDetectForms(), "stale legacy seeds never overwrite valid v2 capabilities")
end

function T.migration_leaves_its_input_untouched_and_canonicalizes_idempotently()
  local monCatalog, pokedexCatalog = fixtures()
  local refs = PokedexDexFixture.refs(monCatalog, pokedexCatalog)
  local canonical = PokedexSave.validate(validBucket(), refs)
  Assert.deepEqual(canonical, validBucket(), "a canonical bucket validates to itself")
  local again = PokedexSave.validate(canonical, refs)
  Assert.deepEqual(again, canonical, "validation is idempotent over canonical buckets")
  local migrated = PokedexSave.migrate(legacyBucket(), refsWithLegacy(monCatalog, pokedexCatalog, legacySeeds()))
  local recanonical = PokedexSave.validate(migrated, refs)
  Assert.deepEqual(recanonical, migrated, "migrated buckets validate as current canonical state")
  local initial = PokedexSave.initial()
  Assert.equal(initial.schema, "hgss-pokedex-v2", "fresh games start at the current schema")
  Assert.equal(initial.stateVersion, 2, "fresh games start at the current state version")
  Assert.deepEqual(initial.seen, {}, "fresh games start with no seen bits")
  Assert.deepEqual(initial.caught, {}, "fresh games start with no caught bits")
  Assert.deepEqual(
    initial.flags,
    { dexEnabled = false, nationalDex = false, enabledInternational = false, canDetectForms = false },
    "fresh games start with every capability locked"
  )
  Assert.deepEqual(initial.history, {}, "fresh games start with no history")
  Assert.deepEqual(initial.resume, {}, "fresh games start with the unset resume")
end

function T.bucket_shape_violations_fail_with_attribution()
  local monCatalog, pokedexCatalog = fixtures()
  local refs = PokedexDexFixture.refs(monCatalog, pokedexCatalog)
  local cases = {
    unknown_field = function(bucket)
      bucket.extra = true
    end,
    sparse_seen = function(bucket)
      bucket.seen = { [1] = "CHIKORITA", [3] = "TOTODILE" }
    end,
    duplicate_seen = function(bucket)
      bucket.seen = { "CHIKORITA", "CHIKORITA" }
    end,
    duplicate_caught = function(bucket)
      bucket.caught = { "SPINDA", "SPINDA" }
    end,
    seen_not_an_array = function(bucket)
      bucket.seen = "CHIKORITA"
    end,
    unknown_seen_species = function(bucket)
      bucket.seen = { "MISSINGNO" }
    end,
    mistyped_flag = function(bucket)
      bucket.flags.dexEnabled = "yes"
    end,
    unknown_resume_mode = function(bucket)
      bucket.resume = { mode = "kanto" }
    end,
    unknown_resume_species = function(bucket)
      bucket.resume = { mode = "national", species = "MISSINGNO" }
    end,
  }
  for name, mutate in pairs(cases) do
    local bucket = validBucket()
    mutate(bucket)
    assertInvalid(function()
      PokedexSave.validate(bucket, refs)
    end, "malformed bucket " .. name .. " is rejected")
  end
  assertInvalid(function()
    PokedexSave.validate(nil, refs)
  end, "a nil bucket is rejected by direct validation")
end

function T.reference_and_consistency_violations_fail_with_attribution()
  local monCatalog, pokedexCatalog = fixtures()
  local refs = PokedexDexFixture.refs(monCatalog, pokedexCatalog)
  local cases = {
    duplicate_genders = function(bucket)
      bucket.history.CHIKORITA.genders = { "female", "female" }
    end,
    impossible_gender_for_genderless = function(bucket)
      bucket.history.SHEDINJA = { genders = { "female" } }
      bucket.seen[#bucket.seen + 1] = "SHEDINJA"
    end,
    variant_outside_policy = function(bucket)
      bucket.history.PICHU.variants = { 7 }
    end,
    duplicate_variants = function(bucket)
      bucket.history.PICHU.variants = { 0, 0 }
    end,
    caught_variant_outside_observed = function(bucket)
      bucket.history.UNOWN.caughtVariants = { 7 }
    end,
    caught_without_seen = function(bucket)
      bucket.caught[#bucket.caught + 1] = "EEVEE"
      bucket.history.EEVEE = { genders = { "male" }, languages = { "english" } }
    end,
    first_personality_on_ordinary_species = function(bucket)
      bucket.history.CHIKORITA.firstPersonality = 12
    end,
    first_personality_outside_u32 = function(bucket)
      bucket.history.SPINDA.firstPersonality = 4294967296
    end,
    unsupported_language_bank = function(bucket)
      bucket.history.TOTODILE.languages = { "korean" }
    end,
    duplicate_languages = function(bucket)
      bucket.history.TOTODILE.languages = { "french", "french" }
    end,
  }
  for name, mutate in pairs(cases) do
    local bucket = validBucket()
    mutate(bucket)
    assertInvalid(function()
      PokedexSave.validate(bucket, refs)
    end, "inconsistent bucket " .. name .. " is rejected")
  end
end

function T.unrelated_catalog_additions_preserve_saved_variants()
  local monCatalog, pokedexCatalog = fixtures()
  local refs = PokedexDexFixture.refs(monCatalog, pokedexCatalog)
  local owner = PokedexKnowledge.new(refs)
  local maleForm = owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "PICHU", personality = 127 }))
  local skirtForm =
    owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "PICHU", form = 1, personality = 0 }))
  owner
    :prepareChanges({
      observations = {
        { kind = "seen", specimen = maleForm },
        { kind = "seen", specimen = skirtForm },
      },
    })
    :publish()
  local bucket = owner:bucket()
  local extendedRoot = PokedexDexFixture.buildMonRoot()
  local eevee = assert(extendedRoot.species.EEVEE, "the mon root carries its multi-form species")
  eevee.forms[2] = eevee.forms[0]
  local extendedCatalog = PokedexDexFixture.makeCatalog(extendedRoot)
  local restored = PokedexKnowledge.restore(bucket, PokedexDexFixture.refs(extendedCatalog, pokedexCatalog))
  Assert.deepEqual(
    restored:observedVariants("PICHU"),
    { 0, 2 },
    "an unrelated added form never renumbers saved logical variants"
  )
  Assert.deepEqual(
    restored:observedGenders("PICHU"),
    { "male", "female" },
    "an unrelated added form never reorders saved gender history"
  )
end

function T.removed_references_fail_explicitly()
  local monCatalog, pokedexCatalog = fixtures()
  local refs = PokedexDexFixture.refs(monCatalog, pokedexCatalog)
  local owner = PokedexKnowledge.new(refs)
  local skirtForm =
    owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "PICHU", form = 1, personality = 0 }))
  owner:prepareChanges({ observations = { { kind = "seen", specimen = skirtForm } } }):publish()
  local narrowed = PokedexDexFixture.buildPokedexCatalog()
  narrowed.species.PICHU.formPolicy = {
    kind = "ordered",
    variants = { { id = 0, form = 0, gender = "male" } },
    defaultVariant = 0,
    rememberCaughtVariants = false,
    rememberFirstPersonality = false,
  }
  assertInvalid(function()
    PokedexKnowledge.restore(owner:bucket(), PokedexDexFixture.refs(monCatalog, narrowed))
  end, "a removed referenced variant fails instead of silently remapping")
  local reducedSpecies = {}
  for key, allowed in pairs(refs.species) do
    if key ~= "SPINDA" then
      reducedSpecies[key] = allowed
    end
  end
  assertInvalid(function()
    PokedexKnowledge.restore(owner:bucket(), {
      species = reducedSpecies,
      monCatalog = monCatalog,
      pokedexCatalog = pokedexCatalog,
      nativeLanguage = "english",
    })
  end, "a removed referenced species fails instead of dropping its history")
end

return { tests = T }
