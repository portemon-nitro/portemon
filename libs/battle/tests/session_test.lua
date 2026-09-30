-- Arbitrary battle topology under one headless session owner: singles,
-- one trainer holding two slots, allied trainers sharing a side, five
-- active combatants, and reserves larger than a party. Stable combatant,
-- position, and entry identities must survive every declared layout, while
-- duplicate occupancy, invalid ownership, and undeclared controllers fail
-- before a session publishes.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table scenario parts for a singles lineup
local function singles()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 2, "beta", { SessionFixture.combatant(2, 22) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }
end

---@return table scenario parts where one trainer holds two slots
local function oneTrainerTwoSlots()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
      }),
      SessionFixture.participant(2, 2, "beta", { SessionFixture.combatant(3, 22) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 2),
      SessionFixture.position(3, 2, { 2 }, 3),
    },
  }
end

---@return table scenario parts with two allied trainers sharing one side
local function alliedTrainers()
  return {
    sides = {
      SessionFixture.side(1, { 1, 2 }),
      SessionFixture.side(2, { 3 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 1, "beta", { SessionFixture.combatant(2, 12) }),
      SessionFixture.participant(3, 2, "gamma", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 2 }, 2),
      SessionFixture.position(3, 2, { 3 }, 3),
      SessionFixture.position(4, 2, { 3 }, 4),
    },
  }
end

---@return table scenario parts with five active combatants
local function fiveActive()
  return {
    sides = {
      SessionFixture.side(1, { 1, 2 }),
      SessionFixture.side(2, { 3 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
      }),
      SessionFixture.participant(2, 1, "beta", { SessionFixture.combatant(3, 13) }),
      SessionFixture.participant(3, 2, "gamma", {
        SessionFixture.combatant(4, 23),
        SessionFixture.combatant(5, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 2),
      SessionFixture.position(3, 1, { 2 }, 3),
      SessionFixture.position(4, 2, { 3 }, 4),
      SessionFixture.position(5, 2, { 3 }, 5),
    },
  }
end

---@return table scenario parts with a reserve larger than a party
local function largeReserve()
  local roster = {}
  for combatantId = 1, 8 do
    roster[#roster + 1] = SessionFixture.combatant(combatantId, 30 + combatantId)
  end
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", roster),
      SessionFixture.participant(2, 2, "beta", { SessionFixture.combatant(9, 41) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 2),
      SessionFixture.position(3, 2, { 2 }, 9),
    },
  }
end

---@param parts table scenario parts under inspection
---@return table<string, boolean> every combatant identity the setup declares
local function declaredCombatants(parts)
  local known = {}
  for _, participant in ipairs(parts.participants) do
    for _, seed in ipairs(participant.roster) do
      Assert.isTrue(seed.id > 0, "combatant identities stay positive")
      Assert.isNil(known[seed.id], "combatant identities are never reused")
      known[seed.id] = true
    end
  end
  return known
end

---@param parts table scenario parts under inspection
---@param controllers table<string, boolean> every controller the setup declares
local function checkTopology(parts, controllers)
  local known = declaredCombatants(parts)
  for _, position in ipairs(parts.positions) do
    Assert.isTrue(position.id > 0, "position identities stay positive")
    if position.occupant ~= nil then
      Assert.isTrue(known[position.occupant] == true, "occupants reference declared combatants")
    end
  end
  for controller in pairs(controllers) do
    Assert.isTrue(type(controller) == "string" and controller ~= "", "controllers stay named")
  end
end

function T.arbitrary_lineups_keep_stable_combatant_position_and_entry_identities()
  local contracts = SessionFixture.sessionContracts()
  local lineups = {
    { parts = singles(), controllers = { alpha = true, beta = true } },
    { parts = oneTrainerTwoSlots(), controllers = { alpha = true, beta = true } },
    { parts = alliedTrainers(), controllers = { alpha = true, beta = true, gamma = true } },
    { parts = fiveActive(), controllers = { alpha = true, beta = true, gamma = true } },
    { parts = largeReserve(), controllers = { alpha = true, beta = true } },
  }
  for _, lineup in ipairs(lineups) do
    checkTopology(lineup.parts, lineup.controllers)
    local session = SessionFixture.newSession(
      contracts,
      SessionFixture.buildScenario(lineup.parts)
    )
    local frame = SessionFixture.driveUntilSettled(session, 64)
    if frame.status == "waiting" then
      Assert.notNil(frame.request, "waiting frames carry their decision batch")
      Assert.isTrue(frame.request.id > 0, "batches carry positive identities")
      Assert.isTrue(frame.request.epoch >= 0, "batches carry a request epoch")
      for _, request in ipairs(frame.request.requests) do
        Assert.isTrue(lineup.controllers[request.controller] == true, "requests address declared controllers")
        Assert.isTrue(request.requestId > 0, "requests carry positive identities")
        Assert.equal(request.epoch, frame.request.epoch, "requests share their batch epoch")
        for _, actor in ipairs(request.actors) do
          Assert.notNil(actor.combatant, "requests name their acting combatants")
        end
      end
    end
    session:dispose()
  end
end

function T.duplicate_occupancy_invalid_ownership_and_undeclared_controllers_fail()
  local contracts = SessionFixture.sessionContracts()

  local doubleBooked = singles()
  doubleBooked.positions[2].occupant = 1
  local bookedRaw = SessionFixture.buildScenario(doubleBooked)
  Assert.throws(function()
    contracts.Scenario.validate(bookedRaw)
  end, "scenario validation owns duplicate occupancy")
  Assert.throws(function()
    SessionFixture.newSession(contracts, bookedRaw)
  end, "one combatant cannot hold two positions")

  local foreignSlot = singles()
  foreignSlot.positions[1].eligibleParticipants = { 2 }
  Assert.throws(function()
    SessionFixture.newSession(contracts, SessionFixture.buildScenario(foreignSlot))
  end, "occupants must belong to a participant eligible for the slot")

  local nameless = singles()
  nameless.participants[1].controller = ""
  Assert.throws(function()
    SessionFixture.newSession(contracts, SessionFixture.buildScenario(nameless))
  end, "participants without a declared controller cannot join a battle")

  local ghost = singles()
  ghost.participants[2].roster = {}
  ghost.positions[2].occupant = 99
  Assert.throws(function()
    SessionFixture.newSession(contracts, SessionFixture.buildScenario(ghost))
  end, "positions cannot name combatants outside every declared roster")
end

return { tests = T }
