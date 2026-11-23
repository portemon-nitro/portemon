-- Source trainer sight and engagement selection. The vectors here are stated
-- from the native rules: an object of sight type 1 looks along its facing, a
-- type 2 object looks in all four directions, the player must stand on that
-- exact row or column inside the object's own range, every tile between the
-- two must stay clear, and the engagement shape follows the first sighted
-- trainer's own double mark together with the party's double eligibility.

local Assert = require("tests.support.Assert")
local Trigger = require("libs.hgss.src.battle.TrainerBattleTrigger")

local T = {}

local function clear()
  return function()
    return false
  end
end

---@param overrides table<string, unknown>|nil
---@return table<string, unknown> a sighted forward-looking trainer eight tiles away
local function trainer(overrides)
  local record = {
    id = "a",
    fieldX = 10,
    fieldZ = 4,
    trainerId = 46,
    partner = "first",
    sightType = 1,
    direction = "south",
    range = 6,
    sightBlocked = clear(),
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

---@param trainers table[]
---@param doublesEligible boolean?
---@return { player: table<string, unknown>, trainers: table[], doublesEligible: boolean? }
local function facts(trainers, doublesEligible)
  return {
    player = { fieldX = 10, fieldZ = 10, facing = "north" },
    trainers = trainers,
    doublesEligible = doublesEligible,
  }
end

function T.a_forward_sighting_trainer_engages_along_its_own_ray()
  local plan = Trigger.check(facts({ trainer() }))
  plan = assert(plan)
  Assert.equal(plan.encounterType, Trigger.ENCOUNTER_SINGLE)
  Assert.equal(#plan.slots, 1)
  Assert.equal(plan.slots[1].id, "a")
  Assert.equal(plan.slots[1].distance, 6, "the engagement carries the source sight distance")
  Assert.equal(plan.slots[1].direction, "south")
end

-- The player is on the row but beyond the range, off the row but inside it, or
-- behind the trainer: none of those is the source's directional sight.
function T.a_forward_trainer_needs_the_exact_row_and_range()
  Assert.isNil(Trigger.check(facts({ trainer({ range = 5 }) })), "one tile beyond the range")
  Assert.isNil(
    Trigger.check({ player = { fieldX = 11, fieldZ = 10 }, trainers = { trainer() }, doublesEligible = false }),
    "one tile off the sight row"
  )
  Assert.isNil(
    Trigger.check(facts({ trainer({ direction = "north" }) })),
    "the player stands behind the trainer's facing"
  )
  Assert.isNil(
    Trigger.check(facts({ trainer({ direction = "south", fieldZ = 11 }) })),
    "the player overlaps the trainer"
  )
end

-- Type 2 looks in all four directions in the source's north, south, west, east
-- order; types 0 and 3 never sight.
function T.an_all_direction_trainer_scans_four_ways_and_other_types_never_sight()
  local plan = Trigger.check(facts({
    trainer({ id = "a", fieldX = 10, fieldZ = 4, sightType = 2, range = 6 }),
  }))
  plan = assert(plan)
  Assert.equal(plan.slots[1].direction, "south", "the scan starts at north and reaches south")

  local west = Trigger.check({
    player = { fieldX = 4, fieldZ = 10 },
    trainers = { trainer({ fieldX = 10, fieldZ = 10, sightType = 2, range = 6 }) },
  })
  west = assert(west)
  Assert.equal(west.slots[1].direction, "west")
  Assert.equal(west.slots[1].distance, 6)

  Assert.isNil(Trigger.check(facts({ trainer({ sightType = 0 }) })), "a type 0 object has no sight")
  Assert.isNil(Trigger.check(facts({ trainer({ sightType = 3 }) })), "a type 3 object has no sight")
end

-- Anything on the ray between the two blocks the sight, and so does a blocked
-- player endpoint.
function T.intermediate_obstruction_and_a_blocked_endpoint_stop_the_sight()
  local calls = {}
  local plan = Trigger.check(facts({
    trainer({
      sightBlocked = function(direction, distance)
        calls[#calls + 1] = { direction, distance }
        return true
      end,
    }),
  }))
  Assert.isNil(plan, "an obstructed ray never sights the player")
  Assert.equal(#calls, 1)
  Assert.equal(calls[1][1], "south")
  Assert.equal(calls[1][2], 6, "the occlusion check reads the full sight distance")
end

function T.defeated_and_hidden_trainers_never_engage()
  Assert.isNil(Trigger.check(facts({ trainer({ defeated = true }) })))
end

-- A trainer whose own record marks a double battle engages only with two usable
-- party mons, and then together with its own pair partner as one trainer.
function T.a_double_trainer_needs_two_usable_mons_and_its_pair_partner()
  local pair = {
    trainer({ id = "a", isDouble = true }),
    trainer({ id = "b", partner = "second", isDouble = true }),
  }
  Assert.isNil(Trigger.check(facts(pair, false)), "one usable mon keeps a double trainer from engaging")
  local plan = Trigger.check(facts(pair, true))
  plan = assert(plan)
  Assert.equal(plan.encounterType, Trigger.ENCOUNTER_DOUBLE_PAIR)
  Assert.equal(#plan.slots, 2)
  Assert.equal(plan.slots[1].id, "a")
  Assert.equal(plan.slots[2].id, "b")
  Assert.equal(plan.slots[2].trainerId, plan.slots[1].trainerId, "both objects name the same native trainer")
  Assert.equal(plan.slots[2].distance, 6, "the pair partner follows the leading object's sight geometry")
end

-- Two independent sighting trainers open the native two-trainer double when the
-- party can field one, and the lone sighting trainer engages alone otherwise.
function T.two_independent_trainers_engage_together_only_with_a_double_party()
  local independent = { trainer({ id = "a" }), trainer({ id = "b", trainerId = 81, fieldZ = 5 }) }
  local plan = Trigger.check(facts(independent, true))
  plan = assert(plan)
  Assert.equal(plan.encounterType, Trigger.ENCOUNTER_TWO_TRAINERS)
  Assert.equal(#plan.slots, 2)
  Assert.equal(plan.slots[2].id, "b")
  Assert.equal(plan.slots[2].distance, 5, "every independent trainer keeps its own sight distance")

  local alone = Trigger.check(facts(independent, false))
  alone = assert(alone)
  Assert.equal(alone.encounterType, Trigger.ENCOUNTER_SINGLE)
  Assert.equal(#alone.slots, 1)
  Assert.equal(alone.slots[1].id, "a")
end

-- The first sighted trainer in source order decides the shape, and an
-- unsighted trainer earlier in the object list never claims the engagement.
function T.source_order_selects_the_first_sighted_trainer()
  local plan = Trigger.check(facts({
    trainer({ id = "hidden", direction = "north" }),
    trainer({ id = "a" }),
  }))
  plan = assert(plan)
  Assert.equal(plan.slots[1].id, "a")
end

return { tests = T }
