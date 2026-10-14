local Assert = require("tests.support.Assert")
local DaycareState = require("libs.hgss.src.save.DaycareState")

local T = {}

local function monCatalog()
  local species = {
    alpha = { growthCurve = "linear", eggGroups = { "field", "field" }, genderRatio = 127 },
    beta = { growthCurve = "linear", eggGroups = { "field", "field" }, genderRatio = 127 },
    ditto = { growthCurve = "linear", eggGroups = { "ditto", "ditto" }, genderRatio = 255 },
    genderless = { growthCurve = "linear", eggGroups = { "mineral", "mineral" }, genderRatio = 255 },
  }
  return {
    species = function(_, key) return assert(species[key]) end,
    growthCurve = function()
      local curve = {}
      for level = 1, 100 do curve[level] = (level - 1) * 100 end
      return curve
    end,
  }
end

local function mon(species, nickname, personality, otId, experience, steps)
  return {
    species = species,
    nickname = nickname,
    personality = personality,
    otId = otId,
    experience = experience,
    steps = steps,
  }
end

function T.capture_returns_a_detached_native_empty_record()
  local state = DaycareState.empty()
  local first = state:capture()
  first.mons[1] = mon("alpha", "MUTATED", 0, 1, 100, 100)
  Assert.deepEqual(state:capture(), {
    schema = DaycareState.SCHEMA,
    mons = { false, false },
    eggPid = 0,
  })
end

function T.phone_facts_follow_slot_order_growth_and_native_compatibility()
  local state = DaycareState.restore({
    schema = DaycareState.SCHEMA,
    mons = {
      mon("alpha", "SPROUT", 0, 7, 100, 100),
      mon("beta", "BLOOM", 127, 8, 0, 99),
    },
    eggPid = 123,
  }, monCatalog())
  Assert.deepEqual(state:phoneFacts(monCatalog()), {
    mons = {
      { nickname = "SPROUT", growth = 1 },
      { nickname = "BLOOM", growth = 0 },
    },
    eggPid = 123,
    compatibility = 1,
  })
end

function T.phone_facts_match_native_compatibility_score_conversion()
  local function score(firstSpecies, firstPersonality, firstOt, secondSpecies, secondPersonality, secondOt)
    local state = DaycareState.restore({
      schema = DaycareState.SCHEMA,
      mons = {
        mon(firstSpecies, "FIRST", firstPersonality, firstOt, 0, 0),
        mon(secondSpecies, "SECOND", secondPersonality, secondOt, 0, 0),
      },
      eggPid = 0,
    }, monCatalog())
    return state:phoneFacts(monCatalog()).compatibility
  end

  Assert.equal(0, score("alpha", 0, 1, "alpha", 127, 2), "same species and different OTs map max compatibility to zero")
  Assert.equal(1, score("alpha", 0, 1, "alpha", 127, 1), "same species and OT map medium compatibility to one")
  Assert.equal(1, score("alpha", 0, 1, "beta", 127, 2), "different species and OTs map medium compatibility to one")
  Assert.equal(2, score("alpha", 0, 1, "beta", 127, 1), "different species and OT map low compatibility to two")
  Assert.equal(3, score("alpha", 0, 1, "beta", 0, 2), "same derived gender maps incompatible to three")
  Assert.equal(3, score("genderless", 0, 1, "alpha", 127, 2), "genderless non-Ditto pairs map incompatible to three")
  Assert.equal(3, score("ditto", 0, 1, "ditto", 0, 2), "two Ditto map incompatible to three")
  Assert.equal(1, score("ditto", 0, 1, "alpha", 127, 2), "a Ditto pair with different OTs maps medium compatibility to one")
  Assert.equal(2, score("ditto", 0, 1, "alpha", 127, 1), "a Ditto pair with the same OT maps low compatibility to two")
end

function T.restore_rejects_unknown_and_invalid_daycare_facts()
  local base = { schema = DaycareState.SCHEMA, mons = { false, false }, eggPid = 0 }
  local unknown = { schema = base.schema, mons = base.mons, eggPid = 0, hidden = true }
  Assert.throws(function() DaycareState.restore(unknown) end)
  local badId = {
    schema = base.schema,
    mons = { mon("missing", "X", 0, 0, 0, 0), false },
    eggPid = 0,
  }
  Assert.throws(function() DaycareState.restore(badId, monCatalog()) end)
  local badSlots = { schema = base.schema, mons = { [1] = false, [3] = false }, eggPid = 0 }
  Assert.throws(function() DaycareState.restore(badSlots) end)
  local suppliedGender = {
    schema = DaycareState.SCHEMA,
    mons = { {
      species = "alpha",
      nickname = "X",
      personality = 0,
      gender = "female",
      otId = 0,
      experience = 0,
      steps = 0,
    }, false },
    eggPid = 0,
  }
  Assert.throws(function() DaycareState.restore(suppliedGender, monCatalog()) end)
  local missingPersonality = {
    schema = DaycareState.SCHEMA,
    mons = { { species = "alpha", nickname = "X", otId = 0, experience = 0, steps = 0 }, false },
    eggPid = 0,
  }
  Assert.throws(function() DaycareState.restore(missingPersonality, monCatalog()) end)
end

return { tests = T }
