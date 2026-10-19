-- Persistent dex knowledge over real specimen projections: detached
-- descriptors, first-gender and logical-variant arrival order, the first
-- Spinda personality, Unown caught order, ordered and automatic source
-- policies, and foreign-language acquisition. Uses the small synthetic
-- mon/catalog fixtures; no ROM, GPU, or product cache is touched.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Personality = require("libs.mons.src.gen4.Personality")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local T = {}

local function newOwner()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local pokedexCatalog = PokedexDexFixture.buildPokedexCatalog()
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, pokedexCatalog))
  return owner, monCatalog, pokedexCatalog
end

local function observe(owner, monCatalog, fields, kind)
  local specimen = PokedexDexFixture.makeMon(monCatalog, fields)
  local descriptor = owner:describe(specimen)
  owner:prepareChanges({ observations = { { kind = kind or "caught", specimen = descriptor } } }):publish()
  return descriptor
end

local function assertInvalid(fn, what)
  local err = Assert.throws(fn, what)
  Assert.isTrue(Errors.is(err), "rejections use the structured error path: " .. tostring(err))
  Assert.equal(err.code, "POKEDEX_INVALID", "rejections carry the dex error identity")
end

function T.describe_returns_a_detached_specimen_projection()
  local owner, monCatalog = newOwner()
  local mon =
    PokedexDexFixture.makeMon(monCatalog, { species = "CHIKORITA", form = 0, personality = 0, language = "french" })
  local descriptor = owner:describe(mon)
  Assert.deepEqual(descriptor, {
    species = "CHIKORITA",
    form = 0,
    gender = "female",
    personality = 0,
    language = "french",
    isEgg = false,
    shiny = Personality.shiny(2271560481, 0),
  }, "the descriptor projects the seven detached specimen facts")
  mon.personality = 31
  mon.form = 1
  mon.origin.language = "german"
  Assert.equal(descriptor.personality, 0, "later caller edits never rewrite the detached projection")
  Assert.equal(descriptor.form, 0, "later caller edits never rewrite the detached projection")
  Assert.equal(descriptor.language, "french", "later caller edits never rewrite the detached projection")
  Assert.equal(descriptor.gender, "female", "the projected gender stays frozen with the projection")
end

function T.ordered_observations_keep_arrival_order_across_save_restore()
  local owner, monCatalog, pokedexCatalog = newOwner()
  local female = observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 }, "seen")
  Assert.equal(female.gender, "female", "the pinned low personality byte reads female")
  local male = observe(owner, monCatalog, { species = "CHIKORITA", personality = 31 }, "seen")
  Assert.equal(male.gender, "male", "the pinned boundary personality byte reads male")
  observe(owner, monCatalog, { species = "CHIKORITA", personality = 0 }, "seen")
  Assert.deepEqual(
    owner:observedGenders("CHIKORITA"),
    { "female", "male" },
    "repeat sightings never reorder the first-gender history"
  )
  local pichuMale = observe(owner, monCatalog, { species = "PICHU", form = 0, personality = 127 }, "seen")
  local pichuSkirt = observe(owner, monCatalog, { species = "PICHU", form = 1, personality = 0 }, "caught")
  local pichuFemale = observe(owner, monCatalog, { species = "PICHU", personality = 0 }, "seen")
  Assert.deepEqual({ pichuMale.shiny, pichuSkirt.shiny, pichuFemale.shiny }, {
    Personality.shiny(2271560481, 127),
    Personality.shiny(2271560481, 0),
    Personality.shiny(2271560481, 0),
  }, "shiny derives from the trainer identity and personality through the shared derivation")
  Assert.deepEqual(
    { pichuMale.species, pichuSkirt.form, pichuFemale.form },
    { "PICHU", 1, 0 },
    "descriptors carry the resolved physical facts behind each logical variant"
  )
  Assert.deepEqual(
    owner:observedVariants("PICHU"),
    { 0, 2, 1 },
    "logical variants arrive in observation order, never as physical form ordinals"
  )
  Assert.deepEqual(
    owner:observedGenders("PICHU"),
    { "male", "female" },
    "variant arrivals never fabricate a gender cross-product"
  )
  observe(owner, monCatalog, { species = "SPINDA", personality = 0 }, "seen")
  observe(owner, monCatalog, { species = "SPINDA", personality = 4294967295 }, "caught")
  Assert.equal(owner:firstPersonality("SPINDA"), 0, "the first actual Spinda personality is retained")
  Assert.deepEqual(
    owner:observedGenders("SPINDA"),
    { "female", "male" },
    "the boundary personalities pin the first-then-different gender order"
  )
  observe(owner, monCatalog, { species = "TOTODILE", personality = 0 }, "caught")
  Assert.isTrue(owner:isSeen("TOTODILE"), "a catch records its sighting as well")
  Assert.isTrue(owner:isCaught("TOTODILE"), "a catch records its capture")
  local bucket = owner:bucket()
  local function containsShiny(value)
    if type(value) ~= "table" then
      return false
    end
    for key, item in pairs(value) do
      if key == "shiny" then
        return true
      end
      if containsShiny(item) then
        return true
      end
    end
    return false
  end
  Assert.isFalse(containsShiny(bucket), "no shiny fact ever persists in save history")
  local restored = PokedexKnowledge.restore(bucket, PokedexDexFixture.refs(monCatalog, pokedexCatalog))
  Assert.deepEqual(
    restored:observedGenders("CHIKORITA"),
    { "female", "male" },
    "gender arrival order survives serialization"
  )
  Assert.deepEqual(restored:observedVariants("PICHU"), { 0, 2, 1 }, "variant arrival order survives serialization")
  Assert.equal(restored:firstPersonality("SPINDA"), 0, "the first Spinda personality survives serialization")
  Assert.isTrue(restored:isCaught("TOTODILE"), "caught facts survive serialization")
end

function T.gender_ratio_classes_derive_without_mutation()
  local owner, monCatalog = newOwner()
  local alwaysMale = owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "BURMY", personality = 0 }))
  Assert.equal(alwaysMale.gender, "male", "the always-male ratio reads male at personality zero")
  local alwaysMaleMax =
    owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "BURMY", personality = 4294967295 }))
  Assert.equal(alwaysMaleMax.gender, "male", "the always-male ratio reads male at the u32 ceiling")
  local alwaysFemale =
    owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "WORMADAM", personality = 4294967295 }))
  Assert.equal(alwaysFemale.gender, "female", "the always-female ratio reads female at the u32 ceiling")
  local genderless =
    owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "SHEDINJA", personality = 4294967295 }))
  Assert.equal(genderless.gender, "genderless", "genderless stays genderless at the u32 ceiling")
  local mixedCeiling =
    owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "CHIKORITA", personality = 4294967295 }))
  Assert.equal(mixedCeiling.gender, "male", "the mixed ratio reads male at the u32 ceiling")
end

function T.ordered_and_automatic_policies_keep_distinct_variant_histories()
  local owner, monCatalog = newOwner()
  observe(owner, monCatalog, { species = "UNOWN", form = 5, personality = 0 }, "seen")
  observe(owner, monCatalog, { species = "UNOWN", form = 0, personality = 0 }, "seen")
  Assert.isFalse(owner:isCaught("UNOWN"), "seeing letters never counts the species caught")
  observe(owner, monCatalog, { species = "UNOWN", form = 0, personality = 0 }, "caught")
  observe(owner, monCatalog, { species = "UNOWN", form = 5, personality = 0 }, "caught")
  observe(owner, monCatalog, { species = "UNOWN", form = 5, personality = 0 }, "caught")
  Assert.deepEqual(owner:observedVariants("UNOWN"), { 5, 0 }, "seen letter order is arrival order")
  Assert.deepEqual(
    owner:caughtVariants("UNOWN"),
    { 0, 5 },
    "caught letters keep their own arrival order behind the seen set"
  )
  observe(owner, monCatalog, { species = "CASTFORM", form = 3, personality = 0 }, "seen")
  observe(owner, monCatalog, { species = "CHERRIM", form = 1, personality = 0 }, "caught")
  Assert.deepEqual(owner:observedVariants("CASTFORM"), {}, "automatic display forms never persist fabricated arrivals")
  Assert.deepEqual(owner:observedVariants("CHERRIM"), {}, "automatic display forms never persist fabricated arrivals")
  Assert.isTrue(owner:isSeen("CASTFORM"), "automatic forms still record the sighting")
  Assert.isTrue(owner:isCaught("CHERRIM"), "automatic forms still record the capture")
  observe(owner, monCatalog, { species = "EEVEE", form = 1, personality = 31 }, "seen")
  Assert.deepEqual(owner:observedVariants("EEVEE"), {}, "ordinary policies persist genders only, never variant lists")
  observe(owner, monCatalog, { species = "BURMY", form = 2, personality = 0 }, "seen")
  observe(owner, monCatalog, { species = "WORMADAM", form = 0, personality = 0 }, "seen")
  observe(owner, monCatalog, { species = "DEOXYS", form = 3, personality = 0 }, "seen")
  observe(owner, monCatalog, { species = "ROTOM", form = 5, personality = 0 }, "seen")
  Assert.deepEqual(owner:observedVariants("BURMY"), { 2 }, "three-form families record their arrivals")
  Assert.deepEqual(owner:observedVariants("DEOXYS"), { 3 }, "four-form families record their arrivals")
  Assert.deepEqual(owner:observedVariants("ROTOM"), { 5 }, "six-form families record their arrivals")
end

function T.foreign_acquisition_enables_international_without_inventing_banks()
  local owner, monCatalog = newOwner()
  observe(owner, monCatalog, { species = "EEVEE", personality = 31, language = "french" }, "seen")
  Assert.isFalse(owner:hasInternationalDex(), "a foreign sighting alone never enables the international capability")
  Assert.deepEqual(owner:caughtLanguages("EEVEE"), {}, "a foreign sighting alone never populates the language bank")
  observe(owner, monCatalog, { species = "EEVEE", personality = 31, language = "french" }, "caught")
  Assert.isTrue(owner:hasInternationalDex(), "a foreign capture enables the international capability")
  Assert.deepEqual(owner:caughtLanguages("EEVEE"), { "french" }, "a foreign capture joins the language bank")
  observe(owner, monCatalog, { species = "EEVEE", personality = 32, language = "german" }, "caught")
  observe(owner, monCatalog, { species = "EEVEE", personality = 33, language = "japanese" }, "caught")
  observe(owner, monCatalog, { species = "EEVEE", personality = 0, language = "english" }, "caught")
  Assert.deepEqual(
    owner:caughtLanguages("EEVEE"),
    { "japanese", "english", "french", "german" },
    "caught languages persist in canonical order, never in arrival order"
  )
  observe(owner, monCatalog, { species = "TOTODILE", personality = 31, language = "korean" }, "caught")
  Assert.isTrue(owner:hasInternationalDex(), "an unsupported foreign capture keeps the global capability")
  Assert.deepEqual(
    owner:caughtLanguages("TOTODILE"),
    {},
    "an unsupported language grants no translated bank membership"
  )
end

function T.resume_distinguishes_unset_from_explicit_modes()
  local owner = newOwner()
  Assert.deepEqual(owner:resume(), {}, "a fresh owner carries no resume mode")
  owner:prepareChanges({ resume = { mode = "johto" } }):publish()
  Assert.deepEqual(owner:resume(), { mode = "johto" }, "an explicit resume mode persists")
  owner:prepareChanges({}):publish()
  Assert.deepEqual(owner:resume(), { mode = "johto" }, "an omitted resume never rewrites history")
  owner:prepareChanges({ resume = { mode = "national", species = "CHIKORITA" } }):publish()
  Assert.deepEqual(
    owner:resume(),
    { mode = "national", species = "CHIKORITA" },
    "a national resume stays valid history while national mode stays locked"
  )
  Assert.isFalse(owner:hasNationalDex(), "a national resume never unlocks national mode by itself")
  owner:prepareChanges({ resume = {} }):publish()
  Assert.deepEqual(owner:resume(), {}, "an explicit empty resume restores the unset state")
end

function T.caught_implies_seen_and_closure_holds_across_reordered_batches()
  local owner, monCatalog = newOwner()
  local first = PokedexDexFixture.makeMon(monCatalog, { species = "UNOWN", form = 2, personality = 0 })
  local second = PokedexDexFixture.makeMon(monCatalog, { species = "UNOWN", form = 7, personality = 0 })
  owner
    :prepareChanges({
      observations = {
        { kind = "caught", specimen = owner:describe(second) },
        { kind = "seen", specimen = owner:describe(first) },
      },
    })
    :publish()
  owner
    :prepareChanges({
      observations = {
        { kind = "seen", specimen = owner:describe(second) },
        { kind = "caught", specimen = owner:describe(first) },
      },
    })
    :publish()
  Assert.deepEqual(owner:observedVariants("UNOWN"), { 7, 2 }, "reordered batches keep first-seen arrival order")
  Assert.deepEqual(
    owner:caughtVariants("UNOWN"),
    { 7, 2 },
    "every caught variant stays inside the observed set in arrival order"
  )
  Assert.isTrue(owner:isSeen("UNOWN") and owner:isCaught("UNOWN"), "caught species stay seen")
end

function T.a_thousand_duplicate_sightings_stabilize_storage_and_revision()
  local owner, monCatalog = newOwner()
  local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "CHIKORITA", personality = 0 }))
  owner:prepareChanges({ observations = { { kind = "seen", specimen = specimen } } }):publish()
  local revision = owner:revision()
  for _ = 1, 1000 do
    owner:prepareChanges({ observations = { { kind = "seen", specimen = specimen } } }):publish()
  end
  Assert.deepEqual(
    owner:observedGenders("CHIKORITA"),
    { "female" },
    "duplicate sightings never grow the stored history"
  )
  Assert.equal(owner:revision(), revision, "duplicate sightings never advance the revision")
end

function T.prepare_changes_rejects_eggs_and_unknown_descriptors()
  local owner, monCatalog = newOwner()
  local egg =
    owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "CHIKORITA", personality = 0, isEgg = true }))
  Assert.equal(egg.isEgg, true, "the projection can describe an egg without mutating it")
  local revision = owner:revision()
  assertInvalid(function()
    owner:prepareChanges({ observations = { { kind = "caught", specimen = egg } } })
  end, "a direct egg observation is rejected")
  assertInvalid(function()
    owner:prepareChanges({
      observations = {
        {
          kind = "caught",
          specimen = {
            species = "MISSINGNO",
            form = 0,
            gender = "male",
            personality = 1,
            language = "english",
            isEgg = false,
            shiny = false,
          },
        },
      },
    })
  end, "an unmapped species reference is rejected")
  assertInvalid(function()
    owner:prepareChanges({
      observations = {
        {
          kind = "hatched",
          specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, { species = "CHIKORITA", personality = 0 })),
        },
      },
    })
  end, "an unknown observation kind is rejected")
  Assert.deepEqual(owner:bucket().seen, {}, "rejected observations never publish partial history")
  Assert.equal(owner:revision(), revision, "rejected observations never advance the revision")
end

return { tests = T }
