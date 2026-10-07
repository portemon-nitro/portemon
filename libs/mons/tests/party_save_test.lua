-- Ordered parties and the persisted bucket: six dense zero-based slots
-- with explicit full handling, revision tracking, alive-lead selection,
-- canonical snapshots, and fingerprint-free save round trips.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

local function makePartyMons(catalog)
  local factory = CatalogFixture.makeFactory(0x50000000, catalog)
  local specs = {
    { species = "CHIKORITA", level = 5 },
    { species = "TOTODILE", level = 5 },
    { species = "EEVEE", level = 5 },
    { species = "CHIKORITA", level = 6 },
    { species = "TOTODILE", level = 6 },
    { species = "EEVEE", level = 6 },
    { species = "CHIKORITA", level = 7 },
  }
  local mons = {}
  for _, spec in ipairs(specs) do
    mons[#mons + 1] = factory:createNormal(CatalogFixture.normalRequest(spec))
  end
  return mons
end

function T.party_keeps_dense_slots_revision_and_alive_lead()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local Party = require("libs.mons.src.Party")

  local party = Party.new()
  Assert.equal(party:count(), 0)
  Assert.isNil(party:leadSlot())
  Assert.isNil(party:leadAliveSlot())
  Assert.equal(party:revision(), 0)

  local mons = makePartyMons(catalog)
  for slot = 1, 6 do
    Assert.equal(party:add(mons[slot]), true)
  end
  Assert.equal(party:count(), 6)
  Assert.equal(party:revision(), 6)
  Assert.equal(party:add(mons[7]), false)
  Assert.equal(party:count(), 6)
  Assert.equal(party:revision(), 6)

  Assert.deepEqual(party:get(0), mons[1])
  Assert.throws(function()
    party:get(6)
  end)
  Assert.throws(function()
    party:get(-1)
  end)
  Assert.equal(party:leadSlot(), 0)
  Assert.equal(party:leadAliveSlot(), 0)

  local snapshot = party:capture()
  Assert.keySet(snapshot, "max,mons")
  Assert.equal(snapshot.max, 6)
  Assert.deepEqual(snapshot.mons, { mons[1], mons[2], mons[3], mons[4], mons[5], mons[6] })

  local revived = Party.restore(snapshot, context)
  Assert.equal(revived:count(), 6)
  Assert.deepEqual(revived:get(0), mons[1])
  Assert.equal(revived:leadSlot(), 0)
  Assert.isTrue(Party.validate(snapshot, context))

  local function isTotodile(mon)
    return mon.species == "TOTODILE"
  end
  Assert.equal(party:findFirst(isTotodile), 1)

  party:swap(0, 1)
  Assert.deepEqual(party:get(0), mons[2])
  Assert.deepEqual(party:get(1), mons[1])
  Assert.equal(party:revision(), 7)
  Assert.throws(function()
    party:swap(0, 6)
  end)
  Assert.throws(function()
    party:swap(-1, 0)
  end)
  Assert.equal(party:revision(), 7)

  local removed = party:remove(0)
  Assert.deepEqual(removed, mons[2])
  Assert.equal(party:count(), 5)
  Assert.equal(party:revision(), 8)
  Assert.throws(function()
    party:remove(5)
  end)

  -- A fully depleted lead yields to the next living companion.
  local fainted = copy(mons[1])
  fainted.condition.currentHp = 0
  local tired = Party.new()
  tired:add(Mon.validate(fainted, context))
  tired:add(mons[3])
  Assert.equal(tired:leadSlot(), 0)
  Assert.equal(tired:leadAliveSlot(), 1)
  Assert.equal(tired:revision(), 2)

  -- Eggs travel with the party but never lead it.
  local egg = copy(mons[1])
  egg.isEgg = true
  local brood = Party.new()
  brood:add(Mon.validate(egg, context))
  brood:add(mons[3])
  Assert.equal(brood:leadSlot(), 0)
  Assert.equal(brood:leadAliveSlot(), 1)
end

function T.save_bucket_round_trips_without_a_catalog_fingerprint()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Party = require("libs.mons.src.Party")
  local MonsSave = require("libs.mons.src.MonsSave")
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  local args = CatalogFixture.factoryArgs(0x12345678, catalog)
  local factory = MonFactory.new(args)

  local first = factory:createNormal(CatalogFixture.normalRequest({ level = 5 }))
  local second = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 6 }))
  local party = Party.new()
  party:add(first)
  party:add(second)

  local rngCapture = args.rng:capture()
  Assert.deepEqual(rngCapture, { state = 0x05856380, calls = 8 })

  local bucket = MonsSave.capture(party:capture(), rngCapture)
  Assert.equal(bucket.schema, "g4-mons-save-v3")
  Assert.keySet(bucket, "boxes,party,rng,schema")
  Assert.deepEqual(bucket.rng, rngCapture)
  Assert.deepEqual(bucket.party, party:capture())
  Assert.isTrue(MonsSave.validate(bucket, context))

  local restored = MonsSave.restore(bucket, context)
  Assert.equal(restored.party:count(), 2)
  Assert.equal(restored.party:leadSlot(), 0)
  Assert.deepEqual(restored.party:get(1), second)
  Assert.deepEqual(restored.rng:capture(), rngCapture)

  local again = MonsSave.capture(restored.party:capture(), restored.rng:capture())
  Assert.deepEqual(again, bucket)

  -- The restored generator continues the exact sequence.
  Assert.equal(restored.rng:nextU16(), args.rng:nextU16())

  -- The catalog is a runtime dependency, not a persisted identity check:
  -- the same bucket restores under a different catalog generation.
  local otherRoot = CatalogFixture.buildAssetRoot()
  otherRoot.species.BAYLEEF = copy(otherRoot.species.CHIKORITA)
  otherRoot.species.BAYLEEF.nativeId = 153
  otherRoot.species.BAYLEEF.name = "BAYLEEF"
  local OtherCatalog = require("libs.mons.src.MonCatalog")
  local otherCatalog = OtherCatalog.new(otherRoot, CatalogFixture.makeItemCatalog())
  local otherContext = CatalogFixture.domainContext(otherCatalog)
  local restoredOther = MonsSave.restore(bucket, otherContext)
  Assert.equal(restoredOther.party:count(), 2)
  Assert.deepEqual(restoredOther.party:get(1).species, second.species)

  -- A v2 predecessor bucket carries its obsolete fingerprint forward into
  -- migration, which drops only that field and preserves all live state.
  local predecessor = copy(bucket)
  predecessor.schema = "g4-mons-save-v2"
  predecessor.catalogFingerprint = "stale-catalog-fingerprint"
  local migrated = MonsSave.migrateV2(predecessor)
  Assert.equal(migrated.schema, "g4-mons-save-v3")
  Assert.keySet(migrated, "boxes,party,rng,schema")
  Assert.deepEqual(migrated.rng, rngCapture)
  Assert.deepEqual(migrated.party, party:capture())
  local migratedRestored = MonsSave.restore(migrated, context)
  Assert.equal(migratedRestored.party:count(), 2)
  Assert.deepEqual(migratedRestored.rng:capture(), rngCapture)
  Assert.equal(predecessor.schema, "g4-mons-save-v2", "migration leaves its input untouched")
  Assert.equal(predecessor.catalogFingerprint, "stale-catalog-fingerprint")

  -- Malformed buckets fail with a structured save error.
  local stalePrint = copy(bucket)
  stalePrint.catalogFingerprint = "stale-catalog-fingerprint"
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(stalePrint, context)
  end)
  local missing = copy(bucket)
  missing.rng = nil
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(missing, context)
  end)
  local badRng = copy(bucket)
  badRng.rng = { state = "current", calls = 8 }
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(badRng, context)
  end)
  local overfull = copy(bucket)
  for _ = 1, 5 do
    overfull.party.mons[#overfull.party.mons + 1] = copy(first)
  end
  Assert.equal(#overfull.party.mons, 7)
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(overfull, context)
  end)
  local badMon = copy(bucket)
  badMon.party.mons[2].species = "BOGUS"
  local err = Assert.throws(function()
    MonsSave.validate(badMon, context)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "MONS_SAVE_INVALID")
  Assert.equal(err.context.slot, 1)
end

-- Counts explicit validator calls while delegating to them, so the trusted
-- path under observation keeps working. Returns a stop function that always
-- uninstalls every counter and reports the per-validator totals.
local function watchValidators(entries)
  local originals = {}
  local counts = {}
  for _, entry in ipairs(entries) do
    originals[entry] = entry.module[entry.name]
    counts[entry] = 0
    local slot = entry
    entry.module[entry.name] = function(...)
      counts[slot] = counts[slot] + 1
      return originals[slot](...)
    end
  end
  return function()
    local totals = {}
    for _, entry in ipairs(entries) do
      entry.module[entry.name] = originals[entry]
      totals[entry.key] = counts[entry]
    end
    return totals
  end
end

function T.trusted_restore_reproduces_owner_state_without_semantic_validation()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local Party = require("libs.mons.src.Party")
  local Boxes = require("libs.mons.src.Boxes")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")

  local factory = CatalogFixture.makeFactory(0x1EADBEEF, catalog)
  local first = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 5 }))
  local second = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 6 }))
  local stored = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 5 }))
  local party = Party.new()
  Assert.equal(party:add(first), true)
  Assert.equal(party:add(second), true)
  local boxes = Boxes.new()
  local placement = boxes:prepareChanges(boxes:revision(), {
    updates = { { box = 0, slot = 0, mon = stored } },
  })
  Assert.notNil(placement)
  placement.publish()
  local rng = Lcrng.new(0x60000001)
  local rngCapture = rng:capture()

  local bucket = MonsSave.capture(party:capture(), rngCapture, boxes:capture())
  Assert.isTrue(MonsSave.validate(bucket, context))

  local stop = watchValidators({
    { module = MonsSave, name = "validate", key = "bucket" },
    { module = Party, name = "validate", key = "party" },
    { module = Boxes, name = "validate", key = "boxes" },
    { module = Mon, name = "validate", key = "mon" },
    { module = Lcrng, name = "validate", key = "rng" },
  })
  local restoreOk, restored = pcall(MonsSave.restore, bucket, context)
  local partyOk, revivedParty = pcall(Party.restore, bucket.party, context)
  local captureOk, recaptured = pcall(MonsSave.capture, party:capture(), rngCapture, boxes:capture())
  local calls = stop()
  Assert.isTrue(restoreOk, "trusted mons restore succeeds")
  Assert.isTrue(partyOk, "trusted party restore succeeds")
  Assert.isTrue(captureOk, "owner-state capture succeeds")
  Assert.equal(calls.bucket, 0, "trusted mons restore must not revalidate the whole bucket")
  Assert.equal(calls.party, 0, "trusted party restore must not revalidate owner snapshots")
  Assert.equal(calls.boxes, 0, "trusted boxes restore must not revalidate owner snapshots")
  Assert.equal(calls.mon, 0, "trusted restore must not revalidate every owned mon")
  Assert.equal(calls.rng, 0, "trusted generator restore must not revalidate owner state")

  Assert.equal(restored.party:count(), 2)
  Assert.deepEqual(restored.party:get(0), first)
  Assert.deepEqual(restored.party:get(1), second)
  Assert.equal(restored.party:leadSlot(), 0)
  Assert.equal(restored.party:leadAliveSlot(), 0)
  Assert.deepEqual(revivedParty:get(1), second)
  Assert.deepEqual(restored.boxes:mon(0, 0), stored)
  Assert.equal(restored.boxes:mon(0, 1), nil)
  Assert.deepEqual(
    MonsSave.capture(restored.party:capture(), restored.rng:capture(), restored.boxes:capture()),
    bucket,
    "restored owners capture back to the persisted bucket"
  )
  Assert.deepEqual(recaptured, bucket, "owner-state capture round-trips without validation")
  local probe = Lcrng.restore(rngCapture)
  Assert.equal(restored.rng:nextU16(), probe:nextU16(), "the restored generator continues the sequence")
end

function T.explicit_mons_validation_still_rejects_malformed_records()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local Party = require("libs.mons.src.Party")
  local MonsSave = require("libs.mons.src.MonsSave")

  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local source = factory:createNormal(CatalogFixture.normalRequest())
  local canonical = Mon.validate(source, context)
  Assert.deepEqual(canonical, source)
  Assert.isTrue(canonical ~= source, "explicit validation returns an owned copy")
  Assert.isTrue(canonical.evs ~= source.evs, "explicit validation copies nested records")

  local party = Party.new()
  Assert.equal(party:add(source), true)
  Assert.equal(party:add(source), true)
  local snapshot = party:capture()
  Assert.isTrue(Party.validate(snapshot, context))
  local sparse = copy(snapshot)
  sparse.mons[1] = nil
  throwsCode("MONS_SAVE_INVALID", function()
    Party.validate(sparse, context)
  end)
  local overfull = copy(snapshot)
  for _ = 1, Party.MAX do
    overfull.mons[#overfull.mons + 1] = copy(source)
  end
  throwsCode("MONS_SAVE_INVALID", function()
    Party.validate(overfull, context)
  end)

  local rng = require("libs.mons.src.gen4.Lcrng").new(0x60000002)
  local bucket = MonsSave.capture(snapshot, rng:capture())
  local drifted = copy(bucket)
  drifted.unknownField = true
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(drifted, context)
  end)
  local badMon = copy(bucket)
  badMon.party.mons[1].species = "BOGUS"
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(badMon, context)
  end)
end

function T.validated_copies_stay_independent_across_party_and_save_capture()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local Party = require("libs.mons.src.Party")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")

  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local source = factory:createNormal(CatalogFixture.normalRequest())
  local pristine = copy(source)

  local first = Mon.validate(source, context)
  local second = Mon.validate(source, context)
  Assert.deepEqual(first, second)
  Assert.deepEqual(first, pristine)
  Assert.isTrue(first ~= second)
  Assert.isTrue(first.evs ~= second.evs)
  Assert.isTrue(first.moves ~= second.moves)
  Assert.isTrue(first.origin ~= second.origin)

  -- Mutating nested fields in one copy leaves the source and the other
  -- copy untouched.
  first.nickname = "LEAF"
  first.evs.hp = 252
  first.contest.cool = 200
  first.moves[1].ppUps = 3
  first.condition.currentHp = 0
  first.origin.trainerName = "BLUE"
  first.met.location = 9
  Assert.deepEqual(source, pristine)
  Assert.deepEqual(second, pristine)

  -- The untouched copy remains canonical under the same validator and
  -- flows through party capture unchanged.
  Assert.deepEqual(Mon.validate(second, context), second)
  local party = Party.new()
  Assert.equal(party:add(second), true)
  first.condition.currentHp = 1
  first.markings = 7
  local snapshot = party:capture()
  Assert.deepEqual(snapshot.mons, { second })
  Assert.isTrue(Party.validate(snapshot, context))
  Assert.deepEqual(party:get(0), second)

  -- Save capture of the party snapshot round-trips the untouched copy.
  local rng = Lcrng.new(0x60000000)
  local rngCapture = rng:capture()
  local bucket = MonsSave.capture(snapshot, rngCapture)
  local restored = MonsSave.restore(bucket, context)
  Assert.equal(restored.party:count(), 1)
  Assert.deepEqual(restored.party:get(0), second)
  Assert.deepEqual(Mon.validate(restored.party:get(0), context), second)
end

return { tests = T }
