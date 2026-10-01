-- Source trainer sight and approach planning: undefeated trainers in
-- range engage, defeated and rangeless trainers never do, simultaneous
-- engagements stay simultaneous, and preparation turns an engagement into
-- a trainer-battle launch request.

local Assert = require("tests.support.Assert")
local Trigger = require("libs.hgss.src.battle.TrainerBattleTrigger")

local T = {}

local function factsWith(trainers)
  return { player = { fieldX = 10, fieldZ = 10 }, trainers = trainers }
end

function T.no_engagement_without_trainers_in_range()
  Assert.isNil(Trigger.check(factsWith({})))
  Assert.isNil(Trigger.check(factsWith({
    { id = "a", fieldX = 0, fieldZ = 0, range = 3 },
  })))
  Assert.isNil(Trigger.check(factsWith({
    { id = "a", fieldX = 10, fieldZ = 10, defeated = true, range = 5 },
  }), "defeated trainers never re-engage"))
  Assert.isNil(Trigger.check(factsWith({
    { id = "a", fieldX = 10, fieldZ = 10 },
  }), "sight without a range never engages"))
end

function T.sight_reaches_through_its_range()
  local sighting = Trigger.check(factsWith({
    { id = "a", fieldX = 12, fieldZ = 11, range = 2 },
  }))
  Assert.notNil(sighting)
  Assert.equal(#sighting.trainers, 1)
  Assert.equal(sighting.trainers[1].id, "a")
  Assert.isNil(Trigger.check(factsWith({
    { id = "a", fieldX = 13, fieldZ = 10, range = 2 },
  })))
end

function T.simultaneous_engagements_stay_simultaneous()
  local sighting = Trigger.check(factsWith({
    { id = "a", fieldX = 9, fieldZ = 9, range = 2 },
    { id = "b", fieldX = 11, fieldZ = 11, range = 2, defeated = true },
    { id = "c", fieldX = 10, fieldZ = 12, range = 2 },
  }))
  Assert.notNil(sighting)
  Assert.equal(#sighting.trainers, 2)
  Assert.equal(sighting.trainers[1].id, "a")
  Assert.equal(sighting.trainers[2].id, "c")
end

function T.prepare_turns_engagements_into_launch_requests()
  local single = Trigger.prepare({ trainers = { { id = "a" } } }, {})
  Assert.equal(single.launch.kind, "trainer")
  Assert.equal(single.launch.payload.trainer, "a")
  Assert.deepEqual(single.trainers, { "a" })

  local pair = Trigger.prepare({ trainers = { { id = "a" }, { id = "c" } } }, { launchId = "fixed" })
  Assert.equal(pair.launch.id, "fixed")
  Assert.equal(#pair.launch.payload.trainers, 2)
  Assert.deepEqual(pair.trainers, { "a", "c" })
  Assert.isTrue(not pcall(Trigger.prepare, { trainers = {} }, {}))
end

return { tests = T }
