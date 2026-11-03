-- Transcribed table-rate staging behind wild encounters: the native
-- ability, flute, held-item, and fishing-friendship adjustments applied to
-- the table rate after the empty-table refusal, in native order. Rolls are
-- fixed here from the decomp (ability doubling/halving with its clamp,
-- flute halving and fifty-percent boost, held-item two-thirds, friendship
-- bite tiers with follow gating and unsigned wrapping); nothing is produced
-- by the staging owner. The lead ability arrives validated by the caller
-- (only rate abilities shift the rate); egg leads arrive with no ability.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local RATE_MODULE = "libs.hgss.src.encounters.HgssEncounterRate"

local function rate()
  local ok, loaded = pcall(require, RATE_MODULE)
  Assert.isTrue(ok, "missing encounter rate owner: the table stage transcribes the native adjustments")
  assert(loaded ~= nil, "the rate module loads")
  return loaded --[[@as table]]
end

local function rejectionCode(fn, expected)
  local err = Assert.throws(fn, "the invalid facts must fail")
  Assert.isTrue(Errors.is(err), "rejection uses the structured error path")
  Assert.equal(assert(err).code, expected, "rejection names its contract")
  return assert(err)
end

---@param overrides table<string, unknown>?
---@return table<string, unknown> staging facts with neutral defaults
local function facts(overrides)
  local staged = {
    baseRate = 30,
    isFishing = false,
  }
  for key, value in pairs(overrides or {}) do
    staged[key] = value
  end
  return staged
end

function T.unmodified_rates_stage_unchanged()
  local TableRate = rate()
  Assert.equal(TableRate.tableRate(facts()), 30)
  Assert.equal(TableRate.tableRate(facts({ baseRate = 0 })), 0, "an empty rate stays empty")
  Assert.equal(TableRate.tableRate(facts({ baseRate = 100 })), 100)
end

function T.lead_abilities_double_or_halve_the_table_rate()
  local TableRate = rate()
  -- Non-fishing doublers: arena trap, no guard, illuminate.
  for _, ability in ipairs({ "arena_trap", "no_guard", "illuminate" }) do
    Assert.equal(TableRate.tableRate(facts({ leadAbility = ability })), 60, ability .. " doubles the table rate")
  end
  -- Fishing doublers: sticky hold, suction cups. Arena trap stays quiet
  -- on the fishing path, and the fishing pair stays quiet on land.
  for _, ability in ipairs({ "sticky_hold", "suction_cups" }) do
    Assert.equal(
      TableRate.tableRate(facts({ leadAbility = ability, isFishing = true })),
      60,
      ability .. " doubles the bite rate"
    )
    Assert.equal(TableRate.tableRate(facts({ leadAbility = ability })), 30, ability .. " ignores land rates")
  end
  Assert.equal(
    TableRate.tableRate(facts({ leadAbility = "arena_trap", isFishing = true })),
    30,
    "arena trap ignores bite rates"
  )
  -- Halvers: white smoke, quick feet, stench always halve; snow cloak
  -- halves only in snow.
  for _, ability in ipairs({ "white_smoke", "quick_feet", "stench" }) do
    Assert.equal(TableRate.tableRate(facts({ leadAbility = ability })), 15, ability .. " halves the table rate")
  end
  Assert.equal(TableRate.tableRate(facts({ leadAbility = "snow_cloak", weather = "snow" })), 15)
  Assert.equal(TableRate.tableRate(facts({ leadAbility = "snow_cloak" })), 30)
  Assert.equal(TableRate.tableRate(facts({ leadAbility = "snow_cloak", weather = "none" })), 30)
  -- Selection abilities never touch the rate.
  for _, ability in ipairs({ "synchronize", "intimidate", "keen_eye", "hustle", "cute_charm", "compoundeyes" }) do
    Assert.equal(TableRate.tableRate(facts({ leadAbility = ability })), 30, ability .. " stages no rate effect")
  end
  -- The ability clamp lands at one hundred, matching the native stage.
  Assert.equal(TableRate.tableRate(facts({ baseRate = 80, leadAbility = "arena_trap" })), 100)
  Assert.equal(TableRate.tableRate(facts({ baseRate = 60, leadAbility = "sticky_hold", isFishing = true })), 100)
end

function T.flutes_shift_the_staged_rate_after_abilities()
  local TableRate = rate()
  Assert.equal(TableRate.tableRate(facts({ baseRate = 60, flute = "black" })), 30)
  Assert.equal(TableRate.tableRate(facts({ baseRate = 60, flute = "white" })), 90)
  -- A white flute on a full rate stages 150, exactly like the native
  -- unsigned stage; the roll site caps it back to one hundred.
  Assert.equal(TableRate.tableRate(facts({ baseRate = 100, flute = "white" })), 150)
  -- Order is ability, then flute: arena trap doubles fifty to the clamp
  -- before the white flute boosts it past one hundred again.
  Assert.equal(TableRate.tableRate(facts({ baseRate = 50, leadAbility = "arena_trap", flute = "white" })), 150)
  Assert.equal(TableRate.tableRate(facts({ baseRate = 50, leadAbility = "arena_trap", flute = "black" })), 50)
end

function T.held_items_take_two_thirds_after_flutes()
  local TableRate = rate()
  Assert.equal(TableRate.tableRate(facts({ baseRate = 90, heldItem = "CLEANSE_TAG" })), 60)
  Assert.equal(TableRate.tableRate(facts({ baseRate = 90, heldItem = "PURE_INCENSE" })), 60)
  Assert.equal(TableRate.tableRate(facts({ baseRate = 90, heldItem = "SITRUS_BERRY" })), 90)
  Assert.equal(TableRate.tableRate(facts({ baseRate = 90 })), 90)
  -- Order is ability, flute, then held: arena trap doubles forty to
  -- eighty, black halves to forty, cleanse takes two thirds to twenty-six.
  Assert.equal(
    TableRate.tableRate(
      facts({ baseRate = 40, leadAbility = "arena_trap", flute = "black", heldItem = "CLEANSE_TAG" })
    ),
    26
  )
end

function T.fishing_friendship_boosts_the_bite_rate()
  local TableRate = rate()
  -- Tiers from the native friendship ladder, gated on an active follower.
  local tiers = {
    { friendship = 0, want = 30 },
    { friendship = 99, want = 30 },
    { friendship = 100, want = 50 },
    { friendship = 149, want = 50 },
    { friendship = 150, want = 60 },
    { friendship = 199, want = 60 },
    { friendship = 200, want = 70 },
    { friendship = 249, want = 70 },
    { friendship = 250, want = 80 },
    { friendship = 255, want = 80 },
  }
  for _, tier in ipairs(tiers) do
    Assert.equal(
      TableRate.tableRate(facts({ isFishing = true, friendship = tier.friendship, followActive = true })),
      tier.want,
      "friendship " .. tier.friendship .. " stages +" .. (tier.want - 30)
    )
  end
  -- An absent follower stages nothing, and land rates never read friendship.
  Assert.equal(TableRate.tableRate(facts({ isFishing = true, friendship = 250 })), 30)
  Assert.equal(TableRate.tableRate(facts({ isFishing = true, friendship = 250, followActive = false })), 30)
  Assert.equal(TableRate.tableRate(facts({ friendship = 250, followActive = true })), 30)
  -- The native unsigned byte wraps: a boosted bite past 255 wraps around.
  Assert.equal(TableRate.tableRate(facts({ baseRate = 250, isFishing = true, friendship = 250, followActive = true })), 44)
  -- An empty bite rate refuses before the boost, matching the native
  -- early return.
  Assert.equal(TableRate.tableRate(facts({ baseRate = 0, isFishing = true, friendship = 250, followActive = true })), 0)
end

function T.table_facts_reject_malformed_input()
  local TableRate = rate()
  rejectionCode(function()
    TableRate.tableRate({ baseRate = 30, isFishing = "sometimes" })
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    TableRate.tableRate({ baseRate = -1, isFishing = false })
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    TableRate.tableRate({ baseRate = 256, isFishing = false })
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    TableRate.tableRate(facts({ leadAbility = "wonder_guard" }))
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    TableRate.tableRate(facts({ weather = "rain" }))
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    TableRate.tableRate(facts({ flute = "pokeflute" }))
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    TableRate.tableRate(facts({ isFishing = true, friendship = -1, followActive = true }))
  end, "ENCOUNTER_INVALID_INPUT")
end

return { tests = T }
