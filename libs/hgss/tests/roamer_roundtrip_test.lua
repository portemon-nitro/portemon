-- Roaming encounter persistence: stable identities borrowed by encounter
-- construction instead of regenerated, revision-checked flee, capture,
-- and defeat deltas committed through the roamer owner, and a versioned
-- save bucket that survives unrelated content changes while rejecting
-- malformed records and missing selected references precisely. Reference
-- sets and roamer mons are fixed here from the mon domain owner; nothing
-- is produced by the persistence modules under test.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("libs.hgss.tests.encounter_fixture")

local T = {}

local ROAMER_MODULE = "libs.hgss.src.encounters.HgssRoamerState"
local SAVE_MODULE = "libs.hgss.src.save.EncounterSave"

local function roamers(records, refs)
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  return Roamers.new({ records = records, species = refs.species, maps = refs.maps })
end

local function saveModule()
  return Fixture.requirePresent(SAVE_MODULE, "semantic encounter persistence")
end

local function rejectionCode(fn, expected)
  local err = Assert.throws(fn, "the invalid roamer operation must fail")
  Assert.isTrue(Errors.is(err), "rejection uses the structured error path")
  Assert.equal(assert(err).code, expected, "rejection names its contract")
  return assert(err)
end

---@param values integer[] raw draws to answer in order
---@return table world stream stand-in
---@return fun(): integer consumed draw count
local function rawStream(values)
  local drawn = 0
  local stream = {}
  function stream.nextRaw()
    drawn = drawn + 1
    local value = values[drawn]
    Assert.isTrue(value ~= nil, "the roamer owner drew beyond the supplied raw values")
    return assert(value)
  end
  return stream, function()
    return drawn
  end
end

local function roamingState()
  local refs = Fixture.refs()
  local stored = Fixture.roamerMon()
  local state = roamers({ Fixture.roamerRecord(stored, 11, "roaming", 0) }, refs)
  return state, stored, refs
end

function T.repel_steps_decrement_once_per_committed_step()
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local refs = Fixture.refs()
  -- A fresh owner counts no repel: stepping at zero wears nothing off.
  local quiet = Roamers.new({ records = {}, species = refs.species, maps = refs.maps })
  Assert.equal(quiet:repelSteps(), 0)
  Assert.isFalse(quiet:stepRepel(), "a counter at zero stays there without wearing off")
  Assert.equal(quiet:repelSteps(), 0)
  -- An armed counter decrements once per committed step and reports the
  -- step that wears it off, matching the native per-step update.
  local armed = Roamers.new({ records = {}, species = refs.species, maps = refs.maps, repelSteps = 3 })
  Assert.equal(armed:repelSteps(), 3)
  Assert.isFalse(armed:stepRepel())
  Assert.equal(armed:repelSteps(), 2)
  Assert.isFalse(armed:stepRepel())
  Assert.equal(armed:repelSteps(), 1)
  Assert.isTrue(armed:stepRepel(), "the step that reaches zero wears the repel off")
  Assert.equal(armed:repelSteps(), 0)
  Assert.isFalse(armed:stepRepel(), "a worn-off repel stays spent")
  Assert.equal(armed:capture().repelSteps, 0, "the spent counter persists")
end

function T.roamer_encounters_reuse_the_stored_identity()
  local state, stored = roamingState()
  local found = state:prepareEncounter("roamer-eevee")
  Assert.equal(found.key, "roamer-eevee")
  Assert.equal(found.location, 11)
  Assert.equal(found.lifecycle, "roaming")
  Assert.equal(found.revision, 0)
  Assert.equal(found.mon.species, "EEVEE")
  Assert.equal(found.mon.personality, stored.personality, "encounter construction borrows the stored identity")
  Assert.deepEqual(found.mon.ivs, stored.ivs)
  Assert.equal(found.mon.condition.currentHp, 12)
  Assert.deepEqual(found.mon.condition.effects, { { key = "burn" } })
  rejectionCode(function()
    state:prepareEncounter("roamer-missing")
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.flee_capture_and_defeat_commit_revision_checked_deltas()
  local state = roamingState()
  local fled = state:prepareResult("roamer-eevee", "fled", 0, { location = 22, hp = 7 })
  Assert.equal(fled.revision, 1)
  Assert.equal(fled.location, 22)
  Assert.equal(fled.lifecycle, "roaming")
  local again = state:prepareEncounter("roamer-eevee")
  Assert.equal(again.location, 22)
  Assert.equal(again.revision, 1)
  Assert.equal(again.mon.condition.currentHp, 7, "battle hp updates commit through the roamer owner")
  rejectionCode(function()
    state:prepareResult("roamer-eevee", "fled", 0, { location = 11 })
  end, "ENCOUNTER_INVALID_INPUT")
  local settled = state:prepareEncounter("roamer-eevee")
  Assert.equal(settled.revision, 1, "stale revisions never mutate")
  local caught = state:prepareResult("roamer-eevee", "captured", 1, {})
  Assert.equal(caught.revision, 2)
  Assert.equal(caught.lifecycle, "caught")
  rejectionCode(function()
    state:prepareEncounter("roamer-eevee")
  end, "ENCOUNTER_INVALID_INPUT")
  local refs = Fixture.refs()
  local fresh = roamers({ Fixture.roamerRecord(Fixture.roamerMon(), 11, "roaming", 0) }, refs)
  local defeated = fresh:prepareResult("roamer-eevee", "defeated", 0, { hp = 0 })
  Assert.equal(defeated.lifecycle, "defeated")
  Assert.equal(defeated.revision, 1)
  rejectionCode(function()
    fresh:prepareEncounter("roamer-eevee")
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.flee_rejects_bad_destinations()
  local state = roamingState()
  rejectionCode(function()
    state:prepareResult("roamer-eevee", "fled", 0, {})
  end, "ENCOUNTER_INVALID_INPUT")
  local stray = rejectionCode(function()
    state:prepareResult("roamer-eevee", "fled", 0, { location = 999 })
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray.context.location, 999, "rejection names the missing map")
  rejectionCode(function()
    state:prepareResult("roamer-eevee", "vanished", 0, { location = 22 })
  end, "ENCOUNTER_INVALID_INPUT")
  local settled = state:prepareEncounter("roamer-eevee")
  Assert.equal(settled.revision, 0, "rejected outcomes never mutate")
  Assert.equal(settled.location, 11)
end

function T.save_round_trip_preserves_roamers_across_flee_and_reload()
  local state, stored, refs = roamingState()
  local Save = saveModule()
  state:prepareResult("roamer-eevee", "fled", 0, { location = 22, hp = 7 })
  local bucket = Save.capture(state)
  local valid = assert(Save.validate(bucket, refs), "the capture validates")
  Assert.equal(valid.schema, "hgss-encounter-v2")
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local reloaded = Roamers.restore(valid, refs)
  local found = reloaded:prepareEncounter("roamer-eevee")
  Assert.equal(found.mon.personality, stored.personality, "reloads keep the stored identity")
  Assert.equal(found.location, 22)
  Assert.equal(found.revision, 1)
  Assert.equal(found.mon.condition.currentHp, 7)
  local grown = { species = {}, maps = {} }
  for key in pairs(refs.species) do
    grown.species[key] = true
  end
  for key in pairs(refs.maps) do
    grown.maps[key] = true
  end
  grown.species.CHIKORITA = true
  grown.maps[99] = true
  local tolerant = assert(Save.validate(bucket, grown), "unrelated content changes stay compatible")
  Assert.equal(tolerant.roamers["roamer-eevee"].revision, 1)
  reloaded:prepareResult("roamer-eevee", "captured", 1, {})
  local caughtBucket = assert(Save.validate(Save.capture(reloaded), refs))
  local caught = Roamers.restore(caughtBucket, refs)
  rejectionCode(function()
    caught:prepareEncounter("roamer-eevee")
  end, "ENCOUNTER_INVALID_INPUT")
end

function T.save_validation_names_missing_selected_references()
  local Save = saveModule()
  local refs = Fixture.refs()
  local mon = Fixture.roamerMon()
  local function bucketWith(record)
    return {
      schema = "hgss-encounter-v2",
      stateVersion = 2,
      steps = 0,
      repelSteps = 0,
      swarm = false,
      radio = "none",
      playerRoutes = { current = false, previous = false },
      roamers = { ["roamer-eevee"] = record },
    }
  end
  local stray = bucketWith(Fixture.roamerRecord({ species = "BOGUS_SPECIES" }, 11, "roaming", 0))
  local speciesErr = rejectionCode(function()
    assert(Save.validate(stray, refs))
  end, "ENCOUNTER_SAVE_INVALID")
  Assert.equal(speciesErr.context.species, "BOGUS_SPECIES", "rejection names the missing species")
  local lost = bucketWith(Fixture.roamerRecord(mon, 999, "roaming", 0))
  local mapErr = rejectionCode(function()
    assert(Save.validate(lost, refs))
  end, "ENCOUNTER_SAVE_INVALID")
  Assert.equal(mapErr.context.location, 999, "rejection names the missing map")
  local function invalidBucket(mutator)
    local bucket = bucketWith(Fixture.roamerRecord(mon, 11, "roaming", 0))
    mutator(bucket)
    return bucket
  end
  rejectionCode(function()
    assert(Save.validate(
      invalidBucket(function(bucket)
        bucket.schema = "hgss-encounter-v0"
      end),
      refs
    ))
  end, "ENCOUNTER_SAVE_INVALID")
  rejectionCode(function()
    assert(Save.validate(
      invalidBucket(function(bucket)
        bucket.stateVersion = 1
      end),
      refs
    ))
  end, "ENCOUNTER_SAVE_INVALID")
  rejectionCode(function()
    assert(Save.validate(
      invalidBucket(function(bucket)
        bucket.roamers["roamer-eevee"].lifecycle = "flying"
      end),
      refs
    ))
  end, "ENCOUNTER_SAVE_INVALID")
  rejectionCode(function()
    assert(Save.validate(
      invalidBucket(function(bucket)
        bucket.roamers["roamer-eevee"].revision = -1
      end),
      refs
    ))
  end, "ENCOUNTER_SAVE_INVALID")
  rejectionCode(function()
    assert(Save.validate(
      invalidBucket(function(bucket)
        bucket.roamers["roamer-eevee"].key = "roamer-other"
      end),
      refs
    ))
  end, "ENCOUNTER_SAVE_INVALID")
  rejectionCode(function()
    assert(Save.validate("not-a-bucket", refs))
  end, "ENCOUNTER_SAVE_INVALID")
end

function T.old_saves_without_a_bucket_start_from_the_defined_initial_state()
  local Save = saveModule()
  local refs = Fixture.refs()
  local initial = Save.initial()
  Assert.equal(initial.schema, "hgss-encounter-v2")
  Assert.equal(initial.stateVersion, 2)
  Assert.deepEqual(initial.roamers, {})
  local valid = assert(Save.validate(initial, refs), "the initial bucket validates")
  Assert.deepEqual(valid, initial, "validation preserves the initial state exactly")
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local state = Roamers.restore(valid, refs)
  rejectionCode(function()
    state:prepareEncounter("roamer-eevee")
  end, "ENCOUNTER_INVALID_INPUT")
  local roundTripped = assert(Save.validate(Save.capture(state), refs))
  Assert.deepEqual(roundTripped, initial, "empty states round-trip without invention")
end

function T.caught_roamers_never_reactivate_after_reload()
  local refs = Fixture.refs()
  local Save = saveModule()
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local totodile = Fixture.mon("TOTODILE", 18, 43)
  local records = {
    Fixture.roamerRecord(Fixture.roamerMon(), 11, "roaming", 0),
    { key = "roamer-totodile", stateVersion = 2, mon = totodile, location = 12, lifecycle = "roaming", revision = 0 },
  }
  local state = roamers(records, refs)
  state:prepareResult("roamer-eevee", "captured", 0, {})
  local bucket = assert(Save.validate(Save.capture(state), refs))
  local reloaded = Roamers.restore(bucket, refs)
  rejectionCode(function()
    reloaded:prepareEncounter("roamer-eevee")
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    reloaded:prepareResult("roamer-eevee", "captured", 1, {})
  end, "ENCOUNTER_INVALID_INPUT")
  local survivor = reloaded:prepareEncounter("roamer-totodile")
  Assert.equal(survivor.mon.personality, totodile.personality, "unrelated roamers stay encounterable")
  Assert.equal(survivor.revision, 0)
end

function T.step_encounters_meet_only_a_roaming_slot_standing_on_the_player_map()
  local refs = Fixture.refs()
  local totodile = Fixture.mon("TOTODILE", 18, 43)
  -- Two active slots stand on map 11 in record order; map 12 stays empty.
  local pair = roamers({
    Fixture.roamerRecord(Fixture.roamerMon(), 11, "roaming", 0),
    { key = "roamer-totodile", stateVersion = 2, mon = totodile, location = 11, lifecycle = "roaming", revision = 0 },
  }, refs)
  local idle, idleDraws = rawStream({})
  Assert.isNil(pair:stepEncounterKey(12, idle), "a map without a standing roamer meets nothing")
  Assert.equal(idleDraws(), 0, "a map without a standing roamer draws nothing")
  -- The source's own 1-in-2 refusal draw: LCRandRange(2) refuses on zero.
  local refused, refusedDraws = rawStream({ 8 })
  Assert.isNil(pair:stepEncounterKey(11, refused), "an even gate draw refuses the meeting")
  Assert.equal(refusedDraws(), 1, "the refusal consumes exactly its own draw")
  -- One standing slot needs no pick draw; several take one uniform pick.
  local single = roamers({ Fixture.roamerRecord(Fixture.roamerMon(), 11, "roaming", 0) }, refs)
  local met, metDraws = rawStream({ 9 })
  Assert.equal(single:stepEncounterKey(11, met), "roamer-eevee", "an odd gate draw meets the standing roamer")
  Assert.equal(metDraws(), 1, "a single standing slot consumes only the gate draw")
  local picked, pickedDraws = rawStream({ 3, 1 })
  Assert.equal(pair:stepEncounterKey(11, picked), "roamer-totodile", "the pick draw selects its standing slot")
  Assert.equal(pickedDraws(), 2, "several standing slots consume one uniform pick")
  -- Only a roaming lifecycle may be met, and only on its own route.
  local settled = roamers({ Fixture.roamerRecord(Fixture.roamerMon(), 11, "caught", 1) }, refs)
  local quiet, quietDraws = rawStream({})
  Assert.isNil(settled:stepEncounterKey(11, quiet), "a caught roamer never meets the player")
  Assert.equal(quietDraws(), 0, "a settled roamer draws nothing")
  local moved = roamers({ Fixture.roamerRecord(Fixture.roamerMon(), 22, "roaming", 0) }, refs)
  local elsewhere, elsewhereDraws = rawStream({})
  Assert.isNil(moved:stepEncounterKey(11, elsewhere), "a roamer on another route never meets the player")
  Assert.equal(elsewhereDraws(), 0, "route locality draws nothing")
  rejectionCode(function()
    pair:stepEncounterKey("11", rawStream({ 1 }))
  end, "ENCOUNTER_INVALID_INPUT")
end

-- The compiled source graph this suite drives: two adjacent eligible routes,
-- four created slots inside them.
---@return table native, table mapIdBySymbol, table refs
local function nativeGraph()
  local native = {
    routes = { "R1", "R2" },
    adjacency = { { 1 }, { 0 } },
    slots = {
      { slot = 0, key = "native.zero", species = "EEVEE", level = 20, regionMin = 0, regionCount = 2 },
      { slot = 1, key = "native.one", species = "EEVEE", level = 20, regionMin = 0, regionCount = 2 },
      { slot = 2, key = "native.two", species = "EEVEE", level = 20, regionMin = 0, regionCount = 2 },
      { slot = 3, key = "native.three", species = "EEVEE", level = 20, regionMin = 0, regionCount = 2 },
    },
  }
  local mapIdBySymbol = { R1 = 11, R2 = 12 }
  return native, mapIdBySymbol, { species = { EEVEE = true }, maps = { [11] = true, [12] = true } }
end

---@param state table roamer owner over a native graph
---@param native table the source graph whose slot order the owner must follow
---@param created table<string, unknown>[] created records
local function createAllSlots(state, native, created)
  -- A zero draw places every created slot on the graph's first route.
  local rng = rawStream({ 0, 0, 0, 0 })
  for index, fact in ipairs(native.slots) do
    created[#created + 1] = state:createNativeSlot(fact.slot, function(slotFact)
      return Fixture.mon(slotFact.species, slotFact.level, 90 + index)
    end, rng)
  end
end

function T.every_source_slot_moves_on_a_connection_including_the_last()
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local native, mapIdBySymbol, refs = nativeGraph()
  local state = Roamers.new({ records = {}, species = refs.species, maps = refs.maps, native = native, mapIdBySymbol = mapIdBySymbol })
  local created = {}
  createAllSlots(state, native, created)
  Assert.equal(#created, 4, "every source slot is created")
  -- The single neighbour of route zero is route one, so no draw is needed; one
  -- draw per slot answers the 1/16 randomize roll.
  local rng, draws = rawStream({ 1, 1, 1, 1 })
  state:updateOnConnectionEntry(rng)
  Assert.equal(draws(), 4, "every active slot takes its own source roll")
  local captured = state:capture().roamers
  for slot = 0, 3 do
    local record = assert(captured[assert(native.slots[slot + 1]).key], "the slot keeps its record")
    Assert.equal(record.native.routeIndex, 1, "slot " .. slot .. " moves onto its single neighbour")
    Assert.equal(record.revision, 1, "slot " .. slot .. " advances exactly one revision")
  end
end

function T.every_source_slot_randomizes_on_a_fly_warp_including_the_last()
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local native, mapIdBySymbol, refs = nativeGraph()
  local state = Roamers.new({ records = {}, species = refs.species, maps = refs.maps, native = native, mapIdBySymbol = mapIdBySymbol })
  local created = {}
  createAllSlots(state, native, created)
  -- Each slot starts on route zero: candidate zero names its own route and is
  -- rejected, so each slot consumes two draws to reach route one.
  local rng, draws = rawStream({ 0, 1, 0, 1, 0, 1, 0, 1 })
  state:randomizeLocations(rng)
  Assert.equal(draws(), 8, "every active slot takes its own in-region draws")
  local captured = state:capture().roamers
  for slot = 0, 3 do
    local record = assert(captured[assert(native.slots[slot + 1]).key], "the slot keeps its record")
    Assert.equal(record.native.routeIndex, 1, "slot " .. slot .. " randomizes onto the other route")
    Assert.equal(record.revision, 1, "slot " .. slot .. " advances exactly one revision")
  end
end

function T.a_defeated_source_slot_is_recreated_in_place_by_the_league_ending()
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local native, mapIdBySymbol, refs = nativeGraph()
  local state = Roamers.new({ records = {}, species = refs.species, maps = refs.maps, native = native, mapIdBySymbol = mapIdBySymbol })
  local first = state:createNativeSlot(1, function(fact)
    return Fixture.mon(fact.species, fact.level, 5)
  end, rawStream({ 1 }))
  Assert.equal(first.lifecycle, "roaming", "the source slot starts roaming")
  local defeated = state:prepareResult("native.one", "defeated", 0, {})
  Assert.equal(defeated.lifecycle, "defeated", "a committed defeat closes the slot")
  Assert.equal(defeated.revision, 1, "the defeat advances the revision")
  local recreated = state:createNativeSlot(1, function(fact)
    return Fixture.mon(fact.species, fact.level, 6)
  end, rawStream({ 1 }))
  Assert.equal(recreated.lifecycle, "roaming", "the ending recreates the defeated slot as roaming")
  Assert.equal(recreated.revision, 2, "the recreation invalidates the defeated revision")
  Assert.equal(recreated.native.slot, 1, "the recreation keeps its source slot")
  Assert.isTrue(recreated.mon.personality ~= first.mon.personality, "the recreation materializes a fresh identity")
  rejectionCode(function()
    state:prepareResult("native.one", "defeated", 1, {})
  end, "ENCOUNTER_INVALID_INPUT")
  local captured = state:capture()
  Assert.equal(captured.roamers["native.one"].revision, 2, "the stale defeated outcome can never overwrite the recreation")
  local stored = 0
  for _ in pairs(captured.roamers) do
    stored = stored + 1
  end
  Assert.equal(stored, 1, "the recreation replaces its existing record")
  rejectionCode(function()
    state:createNativeSlot(1, function(fact)
      return Fixture.mon(fact.species, fact.level, 7)
    end, rawStream({ 1 }))
  end, "ENCOUNTER_INVALID_INPUT")
  -- A captured slot is not a recreation target either.
  local captureState = Roamers.new({ records = {}, species = refs.species, maps = refs.maps, native = native, mapIdBySymbol = mapIdBySymbol })
  captureState:createNativeSlot(0, function(fact)
    return Fixture.mon(fact.species, fact.level, 8)
  end, rawStream({ 1 }))
  captureState:prepareResult("native.zero", "captured", 0, {})
  rejectionCode(function()
    captureState:createNativeSlot(0, function(fact)
      return Fixture.mon(fact.species, fact.level, 9)
    end, rawStream({ 1 }))
  end, "ENCOUNTER_INVALID_INPUT")
end

return { tests = T }
