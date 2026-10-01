-- Party batch staging: validated replacements plus caught-mon appends in
-- one candidate, published atomically. Battle-temporary identity (a
-- borrowed species or form, projected combat stats, volatile conditions,
-- and frame-local item loans) never reaches the staged records: only the
-- canonical persistent identity, health, pp, status, experience, effort,
-- learned moves, and settled held items stage.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Party = require("libs.mons.src.Party")

local OUTCOME_MODULE = "libs.battle.src.BattleOutcome"

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded result owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing party result owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the party result module loads")
  return loaded --[[@as table]]
end

---@return Party party holding two fixed mons
local function twoMonParty()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x77777777, catalog)
  local party = Party.new()
  for _, species in ipairs({ "CHIKORITA", "EEVEE" }) do
    Assert.isTrue(party:add(factory:createNormal(CatalogFixture.normalRequest({ species = species }))))
  end
  return party
end

---@return table<string, unknown> a fixed caught mon record
local function caughtMon()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x88888888, catalog)
  return factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))
end

local T = {}

function T.staged_batch_combines_updates_and_appends_atomically()
  local party = twoMonParty()
  local revision = party:revision()
  Assert.isTrue(type(Party.withChanges) == "function", "missing party batch owner: candidate updates plus appends (Party.withChanges)")
  local replacement = party:get(1)
  replacement.heldItem = "SITRUS_BERRY"
  local candidate = party:withChanges({ { slot = 1, mon = replacement } }, { caughtMon() })
  Assert.equal(candidate:count(), 3, "the candidate carries the appended catch")
  Assert.equal(candidate:get(1).heldItem, "SITRUS_BERRY", "the candidate carries the replacement")
  Assert.equal(candidate:get(2).species, "TOTODILE", "the appended catch keeps its identity")
  Assert.equal(candidate:revision(), revision + 1, "one batch advances the revision exactly once")
  Assert.equal(party:count(), 2, "staging never touches the live party")
  Assert.equal(party:revision(), revision, "staging never moves the live revision")
end

function T.finalized_records_carry_only_persistent_identity()
  local party = twoMonParty()
  local Outcome = requirePresent(OUTCOME_MODULE, "detached completion result validation")
  Assert.isTrue(type(Outcome.validate) == "function", "the outcome validates detached results")
  Assert.isTrue(type(Outcome.finalize) == "function", "the outcome finalizes persistent records")

  local transformed = party:get(0)
  transformed.species = "EEVEE"
  transformed.form = 1
  local finalized = Outcome.finalize({
    id = "outcome-temporary-identity",
    result = "win",
    combatants = { { persistent = party:get(0), battle = transformed } },
  })
  Assert.equal(finalized.monUpdates[1].mon.species, "CHIKORITA", "a borrowed species never persists")
  Assert.equal(finalized.monUpdates[1].mon.form, 0, "a borrowed form never persists")
  Assert.isNil(
    finalized.monUpdates[1].mon.stages,
    "projected combat stages never persist"
  )
  Assert.isNil(
    finalized.monUpdates[1].mon.frame,
    "frame-local references never persist"
  )
end

function T.empty_batch_preserves_the_live_revision()
  local party = twoMonParty()
  local revision = party:revision()
  local candidate = party:withChanges({}, {})
  Assert.equal(candidate:count(), 2, "an empty batch stages nothing")
  Assert.equal(candidate:revision(), revision, "an empty batch moves no revision")
end

function T.append_beyond_six_raises_without_touching_the_party()
  local party = twoMonParty()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x99999999, catalog)
  local appends = {}
  for _ = 1, 5 do
    appends[#appends + 1] = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE" }))
  end
  local ok, err = pcall(party.withChanges, party, {}, appends)
  Assert.isFalse(ok, "an overflowing batch never stages: " .. tostring(err))
  Assert.equal(party:count(), 2, "a rejected batch leaves the live party alone")
end

function T.batch_rejects_duplicate_slots_without_touching_the_party()
  local party = twoMonParty()
  local revision = party:revision()
  local first = party:get(0)
  local ok, err = pcall(party.withChanges, party, { { slot = 0, mon = first }, { slot = 0, mon = first } }, {})
  Assert.isFalse(ok, "a duplicated slot never stages: " .. tostring(err))
  Assert.equal(party:revision(), revision, "a rejected batch moves no revision")
end

function T.staged_copies_isolate_later_caller_edits()
  local party = twoMonParty()
  local replacement = party:get(1)
  replacement.heldItem = "SITRUS_BERRY"
  local caught = caughtMon()
  local candidate = party:withChanges({ { slot = 1, mon = replacement } }, { caught })
  replacement.heldItem = "NONE"
  caught.species = "EEVEE"
  Assert.equal(candidate:get(1).heldItem, "SITRUS_BERRY", "the candidate keeps its replacement copy")
  Assert.equal(candidate:get(2).species, "TOTODILE", "the candidate keeps its appended copy")
end

function T.with_updates_keeps_its_same_size_contract()
  local party = twoMonParty()
  local revision = party:revision()
  local replacement = party:get(0)
  replacement.nickname = "LEAF"
  local candidate = party:withUpdates({ { slot = 0, mon = replacement } })
  Assert.equal(candidate:count(), 2, "updates never change the roster size")
  Assert.equal(candidate:get(0).nickname, "LEAF", "updates still replace")
  Assert.equal(candidate:revision(), revision + 1, "updates still bump once")
  local empty = party:withUpdates({})
  Assert.equal(empty:revision(), revision, "empty updates still preserve the revision")
end

function T.finalize_detaches_from_later_input_edits()
  local party = twoMonParty()
  local Outcome = requirePresent(OUTCOME_MODULE, "detached completion result validation")
  local input = {
    id = "outcome-detached-copy",
    result = "win",
    combatants = { { persistent = party:get(0), battle = party:get(0) } },
  }
  local finalized = Outcome.finalize(input)
  input.combatants[1].persistent.species = "EEVEE"
  Assert.equal(finalized.monUpdates[1].mon.species, "CHIKORITA", "finalized records own their copies")
end

function T.validate_rejects_malformed_results()
  local Outcome = requirePresent(OUTCOME_MODULE, "detached completion result validation")
  Assert.isFalse(pcall(Outcome.validate, { id = "", result = "win", monUpdates = {} }), "an empty id never validates")
  Assert.isFalse(
    pcall(Outcome.validate, { id = "outcome-bad", result = "retreat", monUpdates = {} }),
    "an unknown result never validates"
  )
  Assert.isFalse(
    pcall(Outcome.validate, { id = "outcome-bad", result = "win" }),
    "a missing update array never validates"
  )
end

return { tests = T }
