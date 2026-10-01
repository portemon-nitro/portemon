-- Owning-boundary validation for the battle-era buckets: encounter and dex
-- state validate against the runtime composition's selected references
-- (custom content resolves, removed references fail naming theirs), while
-- a context without reference sets fails closed and malformed present
-- buckets fail at their owning boundary.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")

local T = {}

local function roamerBucket()
  return {
    schema = EncounterSave.SCHEMA,
    stateVersion = EncounterSave.STATE_VERSION,
    steps = 41,
    repelSteps = 0,
    swarm = false,
    radio = "none",
    roamers = {
      raikou = {
        key = "raikou",
        stateVersion = EncounterSave.STATE_VERSION,
        mon = { species = "CUSTOM_MON" },
        location = 60,
        lifecycle = "roaming",
        revision = 3,
      },
    },
  }
end

local function dexBucket()
  return {
    schema = PokedexSave.SCHEMA,
    stateVersion = PokedexSave.STATE_VERSION,
    seen = { "CUSTOM_MON" },
    caught = {},
  }
end

local CUSTOM_REFS = { species = { CHIKORITA = true, CUSTOM_MON = true }, maps = { [60] = true } }

function T.selected_custom_content_resolves_through_composition_refs()
  local encounters = EncounterSave.validate(roamerBucket(), CUSTOM_REFS)
  Assert.equal(encounters.roamers.raikou.location, 60)
  local dex = PokedexSave.validate(dexBucket(), { species = CUSTOM_REFS.species })
  Assert.deepEqual(dex.seen, { "CUSTOM_MON" })
end

function T.removed_references_fail_naming_their_bucket()
  local refs = { species = { CHIKORITA = true }, maps = { [60] = true } }
  local invalid, err = pcall(EncounterSave.validate, roamerBucket(), refs)
  Assert.isFalse(invalid)
  assert(Errors.is(err), "removed encounter references fail with a structured error")
  Assert.equal(err.code, "ENCOUNTER_SAVE_INVALID")
  Assert.equal(err.context.species, "CUSTOM_MON")
  local dexInvalid, dexErr = pcall(PokedexSave.validate, dexBucket(), { species = refs.species })
  Assert.isFalse(dexInvalid)
  assert(Errors.is(dexErr), "removed dex references fail with a structured error")
  Assert.equal(dexErr.code, "POKEDEX_INVALID")
end

function T.unknown_roamer_locations_fail_closed()
  local refs = { species = { CHIKORITA = true, CUSTOM_MON = true }, maps = { [61] = true } }
  local invalid, err = pcall(EncounterSave.validate, roamerBucket(), refs)
  Assert.isFalse(invalid)
  assert(Errors.is(err), "unknown roamer locations fail with a structured error")
  Assert.equal(err.code, "ENCOUNTER_SAVE_INVALID")
  Assert.equal(err.context.location, 60)
end

function T.reference_free_contexts_fail_closed()
  local invalid, err = pcall(EncounterSave.validate, roamerBucket(), nil)
  Assert.isFalse(invalid, "a context without sets approves no selected references")
  assert(Errors.is(err), "missing reference sets fail with a structured error")
  Assert.equal(err.code, "ENCOUNTER_SAVE_INVALID")
  local dexInvalid, dexErr = pcall(PokedexSave.validate, dexBucket(), nil)
  Assert.isFalse(dexInvalid)
  assert(Errors.is(dexErr), "missing dex reference sets fail with a structured error")
  Assert.equal(dexErr.code, "POKEDEX_INVALID")
end

function T.malformed_new_buckets_fail_at_their_owning_boundary()
  local broken = { schema = "bogus", stateVersion = 1 }
  local invalid, err = pcall(EncounterSave.validate, broken, CUSTOM_REFS)
  Assert.isFalse(invalid)
  assert(Errors.is(err), "malformed encounter buckets fail with a structured error")
  Assert.equal(err.code, "ENCOUNTER_SAVE_INVALID")
end

return { tests = T }
