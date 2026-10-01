-- Field, trainer, and wild sources mapped to one detached scenario: wild
-- descriptors and records copy once without rerolling, trainer parties are
-- never invented, scripted fights pass through verbatim, and malformed
-- sources fail loudly.

local Assert = require("tests.support.Assert")
local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")

local T = {}

local function wildPayload(overrides)
  local payload = {
    attemptId = "attempt-7",
    species = "TOTODILE",
    form = 0,
    level = 4,
    personality = 0x12345678,
    ability = "TORRENT",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

local function fullRecord()
  return {
    schema = "g4-mon-v2",
    species = "TOTODILE",
    level = 4,
    condition = { currentHp = 18 },
  }
end

function T.wild_descriptors_copy_once_without_rerolling()
  local payload = wildPayload()
  local scenario = ScenarioFactory.fromEncounter(payload, {})
  Assert.equal(scenario.attemptId, "attempt-7")
  Assert.equal(scenario.kind, "wild")
  Assert.equal(scenario.mon.personality, 0x12345678)
  Assert.equal(scenario.mon.species, "TOTODILE")
  payload.level = 99
  payload.personality = 0x1
  Assert.equal(scenario.mon.level, 4, "later caller mutations never reach the scenario")
  Assert.equal(scenario.mon.personality, 0x12345678, "the prepared identity never rerolls")
  Assert.equal(#scenario.participants, 2)
  Assert.equal(#scenario.positions, 2)
  Assert.equal(scenario.random.seed, 0x12345678, "the prepared personality anchors the seed")
end

function T.wild_records_ride_through_untouched()
  local mon = fullRecord()
  local scenario = ScenarioFactory.fromEncounter({ attemptId = "attempt-9", mon = mon }, {})
  Assert.deepEqual(scenario.mon, mon)
  Assert.equal(scenario.participants[2].roster[1].mon.condition.currentHp, 18)
  mon.condition.currentHp = 1
  Assert.equal(
    scenario.participants[2].roster[1].mon.condition.currentHp,
    18,
    "live record mutations never reach the scenario"
  )
end

function T.wild_sources_reject_malformed_input()
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, { species = "MISSING_NO" }, {}))
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, { species = "TOTODILE", level = 0 }, {}))
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, { species = "TOTODILE", level = 101 }, {}))
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, { level = 4 }, {}))
end

function T.trainer_parties_are_never_invented()
  Assert.isTrue(not pcall(ScenarioFactory.fromTrainer, { trainer = "rival" }, {}))
  local party = { fullRecord(), fullRecord() }
  local scenario = ScenarioFactory.fromTrainer({ trainer = "rival", party = party }, {})
  Assert.equal(scenario.kind, "trainer")
  Assert.equal(#scenario.participants[2].roster, 2)
  party[1].condition.currentHp = 1
  Assert.equal(
    scenario.participants[2].roster[1].mon.condition.currentHp,
    18,
    "trainer records copy once"
  )
  Assert.equal(scenario.participants[2].controller, "trainer:rival")
end

function T.simultaneous_trainers_keep_their_double_engagement()
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { fullRecord() } },
      { id = "b", party = { fullRecord() } },
    },
  }, {})
  Assert.equal(#scenario.participants, 3)
  Assert.equal(#scenario.positions, 3)
  Assert.equal(scenario.format, "double")
  Assert.equal(scenario.participants[2].controller, "trainer:a")
  Assert.equal(scenario.participants[3].controller, "trainer:b")
end

function T.scripted_fights_pass_through_verbatim()
  local sides = { { id = 1, participants = { 1 } }, { id = 2, participants = { 2 } } }
  local participants = {
    { id = 1, side = 1, controller = "player", roster = { { id = 1, mon = fullRecord() } }, context = {} },
    { id = 2, side = 2, controller = "scripted", roster = { { id = 2, mon = fullRecord() } }, context = {} },
  }
  local positions = {
    { id = 1, side = 1, eligibleParticipants = { 1 }, occupant = 1 },
    { id = 2, side = 2, eligibleParticipants = { 2 }, occupant = 2 },
  }
  local scenario = ScenarioFactory.fromScript({
    attemptId = "tutorial-1",
    sides = sides,
    participants = participants,
    positions = positions,
  }, {})
  Assert.equal(scenario.kind, "scripted")
  Assert.equal(scenario.attemptId, "tutorial-1")
  Assert.deepEqual(scenario.sides, sides)
  participants[1].id = 99
  Assert.equal(scenario.participants[1].id, 1, "staged fights detach")
  Assert.isTrue(not pcall(ScenarioFactory.fromScript, { sides = sides }, {}))
end

return { tests = T }
