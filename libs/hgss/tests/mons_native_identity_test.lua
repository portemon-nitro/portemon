-- Native identity authority for mon creation and encoding: starter and
-- script-gift met metadata resolve the native map-section identity the
-- service is constructed with, creation draws stay fixed, the first-starter
-- boxed bytes freeze at the corrected section, native projection follows
-- the generated catalog even when independently maintained runtime maps
-- disagree, and save capture preserves the corrected bytes exactly.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local Party = require("libs.mons.src.Party")

local T = {}

-- Fixed starter inputs shared with the integrated starter journey: bucket
-- seed 7, GOLD with trainer id 1, host date 2000-01-01, starter policy.
local SEED = 7
local PROFILE = { name = "GOLD", gender = 0, trainerId = 1 }
local MET_DATE = { year = 2000, month = 1, day = 1 }
local NATIVE_SECTION = 126
-- The first-candidate personality produced by four creation draws from seed
-- 7; the location-61 journey vector decodes to this same personality, which
-- pins the draw order while the section correction lands.
local FIRST_PERSONALITY = 1005636716
-- Independent 0x88 boxed bytes for the first candidate at the corrected
-- section: the creation pipeline reproduces the frozen location-61 journey
-- vector byte-for-byte when run with the old substitute, so rerunning it
-- with only the location corrected refreshes the vector without touching
-- draws, personality, IVs, or identity. Never computed by the codec under
-- test at assertion time.
local CORRECTED_HEX =
  "6cccf03b0000d10401cc855a0b30fa9e2c5a104b9a3b7b9374ba3f8fae86510962d9c6692508ce8be4ec2691a6e1bd9ac6d28e5b6ba193986b3e5766c780e5938acb2dec997d1a76b138d069162654d0cef342a7e30cda3a47fa657861403dd1a9aded22409e28a3efeb1e05661054a75c5f025a2467ae0019c984791e858d713049c20a905c7a12"

local function openService(catalog, seed, mapSection)
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
    profile = PROFILE,
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = mapSection,
    date = function()
      return { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day }
    end,
  })
end

local function toHex(bytes)
  local parts = {}
  for index = 1, #bytes do
    parts[#parts + 1] = string.format("%02x", string.byte(bytes, index))
  end
  return table.concat(parts)
end

local function contextFor(catalog)
  return {
    catalog = catalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  }
end

function T.starter_met_uses_the_native_section_identity()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED, function()
    return NATIVE_SECTION
  end)
  local candidate = service:buildStarter("CHIKORITA", {
    date = { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day },
  })
  Assert.equal(candidate.met.location, NATIVE_SECTION, "the starter records the native section, not the map id")
  Assert.equal(candidate.met.date.year, 2000, "the met date still flows from the supplied context")
  Assert.equal(candidate.met.level, 5, "starter policy still opens at level five")
  Assert.equal(service:partyCount(), 0, "generation never publishes into the party")
end

function T.corrected_section_keeps_draws_identity_and_bytes()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED, NATIVE_SECTION)
  local candidate = service:buildStarter("CHIKORITA", {
    date = { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day },
  })
  Assert.equal(service:capture().rng.calls, 4, "one candidate still consumes exactly four generator draws")
  Assert.equal(candidate.personality, FIRST_PERSONALITY, "the draw order and personality never move")
  local context = contextFor(catalog)
  Assert.equal(toHex(BoxCodec.encode(candidate, context)), CORRECTED_HEX, "the corrected bytes freeze literally")
  local projection = BoxCodec.decode(CatalogFixture.fromHex(CORRECTED_HEX), context)
  Assert.equal(projection.personality, FIRST_PERSONALITY, "the frozen bytes carry the same candidate")
  Assert.equal(projection.met.location, NATIVE_SECTION, "the frozen bytes carry the corrected section")
  Assert.equal(projection.met.level, 5, "the frozen bytes carry the starter level")
  local ok = pcall(function()
    NativeLegality.project(candidate, context)
  end)
  Assert.isTrue(ok, "the corrected candidate passes native legality")
end

function T.native_projection_follows_the_generated_catalog()
  local catalog = CatalogFixture.makeCatalog()
  local authoritative = contextFor(catalog)
  local factory = CatalogFixture.makeFactory(0x10000021, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))
  record.heldItem = "SITRUS_BERRY"
  local expectedId = catalog:item("SITRUS_BERRY").nativeId
  Assert.equal(expectedId, 158, "the fixture pins the representative native item identity")
  local expectedBytes = BoxCodec.encode(record, authoritative)
  -- Independently maintained runtime maps disagree with the catalog about
  -- the same semantic item; every native consumer must still resolve the
  -- generated identity.
  local divergent = {
    catalog = catalog,
    charmap = authoritative.charmap,
    games = authoritative.games,
    languages = authoritative.languages,
    items = { NONE = 0, POKE_BALL = 4, GREAT_BALL = 3, SITRUS_BERRY = 999 },
    balls = { POKE_BALL = 999, GREAT_BALL = 3 },
  }
  Assert.equal(
    NativeLegality.project(record, divergent).heldItemId,
    expectedId,
    "legality resolves the catalog identity under divergent runtime maps"
  )
  Assert.equal(
    toHex(BoxCodec.encode(record, divergent)),
    toHex(expectedBytes),
    "encoding resolves the catalog identity under divergent runtime maps"
  )
  local decodeOk, decoded = pcall(function()
    return BoxCodec.decode(expectedBytes, divergent)
  end)
  Assert.isTrue(decodeOk, "decoding with divergent runtime maps must still resolve the catalog")
  Assert.equal(
    assert(decodeOk and decoded).heldItem,
    "SITRUS_BERRY",
    "decoding resolves the catalog identity under divergent maps"
  )
  Assert.equal(
    assert(decodeOk and decoded).origin.ball,
    "POKE_BALL",
    "decoding resolves the catalog ball under divergent maps"
  )
end

function T.save_capture_preserves_the_corrected_bytes()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED, NATIVE_SECTION)
  service:createStarter("CHIKORITA", {
    date = { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day },
  })
  local context = contextFor(catalog)
  local before = toHex(BoxCodec.encode(service:partyMon(0), context))
  Assert.equal(before, CORRECTED_HEX, "the published starter matches the frozen vector")
  local restored = HgssMonService.new({
    catalog = catalog,
    bucket = service:capture(),
    profile = PROFILE,
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = NATIVE_SECTION,
    date = function()
      return { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day }
    end,
  })
  Assert.equal(restored:partyCount(), 1, "capture restores exactly the chosen mon")
  Assert.equal(
    toHex(BoxCodec.encode(restored:partyMon(0), context)),
    CORRECTED_HEX,
    "capture changes no corrected byte"
  )
end

---@param value unknown
---@return unknown
local function copyRecord(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyRecord(item)
  end
  return out
end

-- A composed catalog with namespaced species, move, ability, and type
-- entries that resolve semantically with no native identities.
---@return table<string, unknown>
local function customCatalogRoot()
  local root = CatalogFixture.buildAssetRoot()
  local species = copyRecord(root.species.CHIKORITA)
  species.name = "EMBERPUP"
  species.nativeId = nil
  species.forms[0].types = { "ember:CRYSTAL" }
  species.forms[0].abilities = { "ember:BLAZE_HEART" }
  root.species["ember:EMBERPUP"] = species
  local move = copyRecord(root.moves.TACKLE)
  move.name = "Ember Bite"
  move.nativeId = nil
  root.moves["ember:EMBER_BITE"] = move
  local ability = copyRecord(root.abilities.OVERGROW)
  ability.name = "Blaze Heart"
  ability.nativeId = nil
  root.abilities["ember:BLAZE_HEART"] = ability
  return root
end

-- A hand-built healthy custom mon: level five on the copied medium-slow
-- curve carries experience 135, and the copied base health with individual
-- value ten derives maximum health 20.
---@return table<string, unknown>
local function customMon()
  return {
    schema = "g4-mon-v2",
    species = "ember:EMBERPUP",
    form = 0,
    personality = 0x1B1B1B1B,
    experience = 135,
    friendship = 70,
    ability = "ember:BLAZE_HEART",
    heldItem = "NONE",
    markings = 0,
    evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 },
    moves = { { move = "ember:EMBER_BITE", pp = 35, ppUps = 0 } },
    ivs = { hp = 10, attack = 12, defense = 14, speed = 8, specialAttack = 11, specialDefense = 13 },
    isEgg = false,
    nickname = nil,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = {
      location = 7,
      date = { year = 2000, month = 1, day = 1 },
      level = 5,
      terrain = 4,
    },
    origin = {
      trainerId = 1,
      trainerName = "GOLD",
      trainerGender = 0,
      game = "heartgold",
      ball = "POKE_BALL",
      language = "english",
    },
    pokerus = 0,
    mood = 0,
    condition = { currentHp = 20, effects = {} },
    capsule = { id = 0, seals = {} },
    mail = {},
  }
end

---@param catalog MonCatalog
---@param bucket table<string, unknown>
---@return HgssMonService
local function reopenService(catalog, bucket)
  return HgssMonService.new({
    catalog = catalog,
    bucket = bucket,
    profile = PROFILE,
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = NATIVE_SECTION,
    date = function()
      return { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day }
    end,
  })
end

---@param err any
---@return boolean
local function mentionsNamespacedIdentity(err)
  if not Errors.is(err) then
    return false
  end
  return tostring(Errors.format(err)):find("ember:", 1, true) ~= nil
end

---@param err any
---@param key string
---@return boolean
local function mentionsKey(err, key)
  if not Errors.is(err) then
    return false
  end
  return tostring(Errors.format(err)):find(key, 1, true) ~= nil
end

function T.custom_mons_publish_and_save_but_never_pass_as_native()
  local Mon = require("libs.mons.src.Mon")
  Assert.equal(Mon.SCHEMA, "g4-mon-v2", "the canonical record must carry semantic condition effects")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local ResolvedMonSchema = require("libs.mons.src.ResolvedMonSchema")

  local root = customCatalogRoot()
  Assert.isTrue(ResolvedMonSchema.assertCatalog(root) ~= false, "the composed schema accepts the custom entries")
  local catalog = MonCatalog.fromResolved(root, CatalogFixture.makeItemCatalog())
  Assert.isNil(catalog:species("ember:EMBERPUP").nativeId, "custom species resolve without a native identity")

  local service = openService(catalog, SEED, NATIVE_SECTION)
  Assert.isTrue(service:addMon(customMon()), "domain-valid custom mons publish into the party")
  Assert.equal(service:partyCount(), 1)

  local revision = service:partyRevision()
  local nicknamed = copyRecord(service:partyMon(0))
  nicknamed.nickname = "EMBER"
  local staged, stale = service:preparePartyChanges(revision, { { slot = 0, mon = nicknamed } })
  Assert.notNil(staged, "staged party updates accept custom mons")
  Assert.isNil(stale)
  assert(staged ~= nil, "staged preparation validated above")
  Assert.isTrue(staged.changed)
  staged.publish()
  Assert.equal(service:partyMon(0).nickname, "EMBER")

  local restored = reopenService(catalog, service:capture())
  Assert.equal(restored:partyCount(), 1, "capture restores the custom mon")
  Assert.deepEqual(restored:partyMon(0), service:partyMon(0))

  local live = restored:partyMon(0)
  local settledRevision = restored:partyRevision()
  local context = contextFor(catalog)
  local exportErr = Assert.throws(function()
    NativeLegality.project(live, context)
  end, "native export of a custom mon must fail")
  Assert.isTrue(Errors.is(exportErr), "native export must fail with a structured identity failure")
  Assert.equal(exportErr.code, "MON_LEGALITY_INVALID", "native export fails at the representability boundary")
  Assert.isTrue(
    mentionsNamespacedIdentity(exportErr),
    "native export must name the unrepresentable identity: " .. Errors.format(exportErr)
  )

  local typeErr = Assert.throws(function()
    restored:monTypes(0)
  end, "the native type opcode must reject the custom type")
  Assert.isTrue(Errors.is(typeErr), "the type opcode must fail with a structured identity failure")
  Assert.isTrue(
    mentionsKey(typeErr, "ember:CRYSTAL"),
    "the type opcode must name the custom type: " .. Errors.format(typeErr)
  )

  Assert.equal(restored:partyCount(), 1, "rejected native operations never mutate the party")
  Assert.equal(restored:partyRevision(), settledRevision)
  Assert.deepEqual(restored:partyMon(0), live)
end

function T.materialized_battle_facts_move_only_at_explicit_reload()
  local ok, loaded = pcall(require, "libs.mons.src.gen4.MonStats")
  Assert.isTrue(ok, "missing shared battle-stat projection: libs.mons.src.gen4.MonStats is not implemented")
  local MonStats = assert(loaded, "the shared projection loads its module")
  Assert.isTrue(type(MonStats.derive) == "function", "shared projection must expose derive")
  Assert.isTrue(type(MonStats.adjustHpForMaxChange) == "function", "shared projection must expose adjustHpForMaxChange")

  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())

  local Experience = require("libs.mons.src.gen4.Experience")
  local Personality = require("libs.mons.src.gen4.Personality")
  local Stats = require("libs.mons.src.gen4.Stats")
  local species = catalog:species(mon.species)
  local level = Experience.level(catalog:growthCurve(species.growthCurve), mon.experience)
  local nature = Personality.nature(mon.personality)
  local form = catalog:form(mon.species, mon.form)
  local expected = Stats.calculate(form.baseStats, mon.ivs, mon.evs, level, nature)

  local facts = MonStats.derive(mon, catalog)
  Assert.keySet(facts, "attack,defense,level,maxHp,specialAttack,specialDefense,speed")
  Assert.equal(facts.level, level)
  Assert.equal(facts.maxHp, expected.hp)
  Assert.equal(facts.attack, expected.attack)
  Assert.equal(facts.defense, expected.defense)
  Assert.equal(facts.speed, expected.speed)
  Assert.equal(facts.specialAttack, expected.specialAttack)
  Assert.equal(facts.specialDefense, expected.specialDefense)

  -- The single-health species keeps one point through the shared owner.
  local shedinjaMaker = CatalogFixture.makeFactory(0x44444444, catalog)
  local shedinja = shedinjaMaker:createNormal(CatalogFixture.normalRequest({ species = "SHEDINJA", level = 5 }))
  Assert.equal(MonStats.derive(shedinja, catalog).maxHp, 1)

  -- The service derivation agrees with the shared owner.
  local service = openService(catalog, SEED, NATIVE_SECTION)
  Assert.deepEqual(MonStats.derive(mon, catalog), service:derive(mon))

  -- Materialize battle facts, then award effort values: the materialized
  -- facts must not move until the explicit reload runs.
  local materialized = MonStats.derive(mon, catalog)
  local frozen = copyRecord(materialized)
  local trained = copyRecord(mon)
  trained.evs.hp = 100
  Assert.deepEqual(materialized, frozen, "effort awards never rewrite materialized facts")
  local reloaded = MonStats.derive(trained, catalog)
  local reloadedExpected = Stats.calculate(form.baseStats, mon.ivs, trained.evs, level, nature)
  Assert.equal(reloaded.maxHp, reloadedExpected.hp, "the explicit reload picks up the new effort values")
  Assert.isTrue(reloaded.maxHp > materialized.maxHp, "the award must grow health here")
  for _, key in ipairs({ "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    Assert.equal(reloaded[key], materialized[key], "unrelated stats survive the reload")
  end
  Assert.equal(reloaded.level, materialized.level)

  -- Health follows the shared adjustment on both owners.
  local delta = reloaded.maxHp - materialized.maxHp
  local currentHp = mon.condition.currentHp
  local kept = MonStats.adjustHpForMaxChange(materialized.maxHp, reloaded.maxHp, currentHp)
  Assert.equal(
    kept,
    HgssMonService.adjustHpForMaxChange(materialized.maxHp, reloaded.maxHp, currentHp),
    "health adjustment agrees with the service owner"
  )
  Assert.equal(kept, currentHp + delta, "living mons keep their damage across the reload")
  Assert.equal(MonStats.adjustHpForMaxChange(materialized.maxHp, reloaded.maxHp, 0), 0, "fainted mons stay fainted")
  Assert.equal(
    MonStats.adjustHpForMaxChange(reloaded.maxHp, materialized.maxHp, reloaded.maxHp),
    materialized.maxHp,
    "shrinking maxima clamp to the new maximum"
  )
  Assert.equal(
    MonStats.adjustHpForMaxChange(reloaded.maxHp, materialized.maxHp, reloaded.maxHp),
    HgssMonService.adjustHpForMaxChange(reloaded.maxHp, materialized.maxHp, reloaded.maxHp),
    "the clamp agrees with the service owner"
  )

  -- Level-up reload moves the level.
  local leveled = copyRecord(trained)
  leveled.experience = 560
  leveled.met.level = 10
  Assert.equal(MonStats.derive(leveled, catalog).level, 10)
end

function T.staged_health_follows_the_new_maximum_and_survives_failed_derivation()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED, NATIVE_SECTION)
  service:createStarter("CHIKORITA", {
    date = { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day },
  })
  local fresh = service:partyMon(0)
  local oldMax = service:derive(fresh).maxHp
  Assert.equal(fresh.condition.currentHp, oldMax, "the fresh mon opens at full health")

  local probe = copyRecord(fresh)
  probe.experience = 0
  probe.condition.currentHp = 0
  local newMax = service:derive(probe).maxHp
  Assert.isTrue(newMax < oldMax, "the lowered record recalculates a smaller maximum")

  local lowered = copyRecord(fresh)
  lowered.experience = 0
  lowered.condition.currentHp = oldMax - 2
  local healed = service:refreshStagedHp(lowered, oldMax)
  Assert.isTrue(healed == lowered, "recalculation finalizes the staged record in place")
  Assert.equal(healed.condition.currentHp, newMax - 2, "living mons keep their damage across the new maximum")

  local fainted = copyRecord(fresh)
  fainted.experience = 0
  fainted.condition.currentHp = 0
  Assert.equal(service:refreshStagedHp(fainted, oldMax).condition.currentHp, 0, "fainted mons stay at zero")

  local broken = copyRecord(fresh)
  broken.condition.currentHp = oldMax - 2
  broken.species = "NOT_A_SPECIES"
  local healthBefore = broken.condition.currentHp
  local ok = pcall(function()
    service:refreshStagedHp(broken, oldMax)
  end)
  Assert.isFalse(ok, "unusable calculation inputs fail the recalculation")
  Assert.equal(broken.condition.currentHp, healthBefore, "a failed derivation leaves staged health intact")
end

return { tests = T }
