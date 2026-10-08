-- Shared decision batch admission: replies that overbook one batch are
-- rejected atomically, while the surrounding protocol envelope behaves
-- identically no matter which controller answers first.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table scenario parts where one side fields two leads beside a benched reserve
local function reserveDoubles()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
        SessionFixture.combatant(5, 15),
      }),
      SessionFixture.participant(2, 2, "beta", { SessionFixture.combatant(3, 23) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 2),
      SessionFixture.position(3, 2, { 2 }, 3),
    },
  }
end

---@return table scenario parts where one side fields two leads over a single shared unit
local function stockedDoubles()
  local parts = reserveDoubles()
  parts.participants[1].inventoryId = "bag"
  parts.inventories = {
    SessionFixture.inventory("bag", { 1 }, { POTION = 1 }),
  }
  return parts
end

---@param frame table waiting battle frame under inspection
---@param controller string decision producer owning the wanted request
---@return table the pending decision request for the controller
local function requestFor(frame, controller)
  for _, request in ipairs(frame.request.requests) do
    if request.controller == controller then
      return request
    end
  end
  error("the " .. controller .. " request stays open")
end

---@param actor table combatant reference the choice is issued for
---@return table validated decision payload spending one shared unit on its holder
local function itemChoice(actor)
  return {
    actor = actor,
    kind = "item",
    payload = { item = "POTION", target = { kind = "combatant", combatant = actor.combatant } },
  }
end

-- Two leads answering together cannot book the same reserve or spend one
-- shared unit twice: each overbooking reply is rejected whole, keeps no
-- partial reservation, draws nothing, and leaves a later valid reply
-- accepted. A reply that fails only on its second choice is rejected the
-- same way.
function T.shared_reservations_reject_same_reply_double_booking_without_side_effects()
  local contracts = SessionFixture.sessionContracts()

  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(reserveDoubles()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(waiting.status, "waiting", "the doubled battle waits for both sides")
  local alpha = requestFor(waiting, "alpha")
  Assert.equal(#alpha.actors, 2, "one reply answers both leads together")
  local firstActor = assert(alpha.actors[1], "the shared reply addresses its first lead")
  local secondActor = assert(alpha.actors[2], "the shared reply addresses its second lead")
  local pristine = session:capture()
  local callsBefore = pristine.rng.calls

  local doubled, doubleErr = session:submit(SessionFixture.replyFor(alpha, {
    SessionFixture.switchChoice(firstActor, 5),
    SessionFixture.switchChoice(secondActor, 5),
  }))
  Assert.isFalse(doubled, "one reserve cannot answer twice in the same reply")
  Assert.notNil(doubleErr, "rejected double bookings name their input error")
  Assert.deepEqual(session:capture(), pristine, "rejected replies keep no partial reservation")

  local mixed, mixedErr = session:submit(SessionFixture.replyFor(alpha, {
    SessionFixture.attackChoice(firstActor, 0, SessionFixture.positionTarget(3)),
    SessionFixture.switchChoice(secondActor, 99),
  }))
  Assert.isFalse(mixed, "a reply failing only on its second choice is rejected whole")
  Assert.notNil(mixedErr, "rejected late choices name their input error")
  Assert.deepEqual(session:capture(), pristine, "late failures keep no earlier choice")
  Assert.equal(session:capture().rng.calls, callsBefore, "rejected replies draw nothing")

  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, {
    SessionFixture.switchChoice(firstActor, 5),
    SessionFixture.attackChoice(secondActor, 0, SessionFixture.positionTarget(3)),
  }))
  Assert.isTrue(ok, "a later valid reply is accepted: " .. tostring(replyErr))
  Assert.isNil(replyErr, "accepted replies carry no input error")
  local beta = requestFor(SessionFixture.driveUntilSettled(session, 64), "beta")
  local foe = assert(beta.actors[1], "the opposing request addresses its lead")
  local foeOk, foeErr = session:submit(SessionFixture.replyFor(beta, {
    SessionFixture.attackChoice(foe, 0, SessionFixture.positionTarget(1)),
  }))
  Assert.isTrue(foeOk, "the waiting peer still answers: " .. tostring(foeErr))
  Assert.isNil(foeErr, "accepted peer replies carry no input error")
  local turn = session:advance(64)
  Assert.isTrue(turn.status ~= nil, "the completed batch commits")
  session:dispose()

  local stocked = SessionFixture.newSession(contracts, SessionFixture.buildScenario(stockedDoubles()))
  local stockedWaiting = SessionFixture.driveUntilSettled(stocked, 64)
  Assert.equal(stockedWaiting.status, "waiting", "the stocked battle waits for both sides")
  local stockedAlpha = requestFor(stockedWaiting, "alpha")
  local stockedFirst = assert(stockedAlpha.actors[1], "the stocked reply addresses its first lead")
  local stockedSecond = assert(stockedAlpha.actors[2], "the stocked reply addresses its second lead")
  local stockedPristine = stocked:capture()
  local spent, spentErr = stocked:submit(SessionFixture.replyFor(stockedAlpha, {
    itemChoice(stockedFirst),
    itemChoice(stockedSecond),
  }))
  Assert.isFalse(spent, "one shared unit cannot serve twice in the same reply")
  Assert.notNil(spentErr, "rejected double spending names its input error")
  Assert.deepEqual(stocked:capture(), stockedPristine, "rejected spending keeps the shared stock")
  local healed, healedErr = stocked:submit(SessionFixture.replyFor(stockedAlpha, {
    itemChoice(stockedFirst),
    SessionFixture.attackChoice(stockedSecond, 0, SessionFixture.positionTarget(3)),
  }))
  Assert.isTrue(healed, "spending the single unit once is accepted: " .. tostring(healedErr))
  Assert.isNil(healedErr, "accepted spending carries no input error")
  stocked:dispose()
end

-- The decision envelope is order independent: stale epochs, duplicates,
-- foreign controllers, and unknown requests fail as input errors without
-- touching the batch, while answering in either arrival order commits
-- the identical events.
function T.decision_envelopes_behave_identically_across_executors_and_arrival_orders()
  local contracts = SessionFixture.sessionContracts()

  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(reserveDoubles()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(waiting.status, "waiting", "open battles wait for both controllers")
  local alpha = requestFor(waiting, "alpha")
  local beta = requestFor(waiting, "beta")
  local pristine = session:capture()

  local staleReply = SessionFixture.replyFor(alpha, {
    SessionFixture.attackChoice(alpha.actors[1], 0, SessionFixture.positionTarget(3)),
    SessionFixture.attackChoice(alpha.actors[2], 0, SessionFixture.positionTarget(3)),
  })
  staleReply.epoch = waiting.request.epoch + 1
  local staleOk, staleErr = session:submit(staleReply)
  Assert.isFalse(staleOk, "stale epochs cannot answer a frozen batch")
  Assert.notNil(staleErr, "rejected epochs name their input error")

  local foreignReply = SessionFixture.replyFor(alpha, {
    SessionFixture.attackChoice(beta.actors[1], 0, SessionFixture.positionTarget(1)),
  })
  local foreignOk, foreignErr = session:submit(foreignReply)
  Assert.isFalse(foreignOk, "controllers cannot answer for foreign actors")
  Assert.notNil(foreignErr, "rejected foreign actors name their input error")

  local unknownReply = SessionFixture.replyFor(alpha, {
    SessionFixture.attackChoice(alpha.actors[1], 0, SessionFixture.positionTarget(3)),
    SessionFixture.attackChoice(alpha.actors[2], 0, SessionFixture.positionTarget(3)),
  })
  unknownReply.requestId = 999999
  local unknownOk, unknownErr = session:submit(unknownReply)
  Assert.isFalse(unknownOk, "unknown requests answer nothing")
  Assert.notNil(unknownErr, "rejected unknown requests name their input error")

  local validChoices = {
    SessionFixture.attackChoice(alpha.actors[1], 0, SessionFixture.positionTarget(3)),
    SessionFixture.attackChoice(alpha.actors[2], 0, SessionFixture.positionTarget(3)),
  }
  local ok, replyErr = session:submit(SessionFixture.replyFor(alpha, validChoices))
  Assert.isTrue(ok, "the first valid reply is accepted: " .. tostring(replyErr))
  Assert.isNil(replyErr, "accepted replies carry no input error")
  local again, againErr = session:submit(SessionFixture.replyFor(alpha, validChoices))
  Assert.isFalse(again, "duplicate replies cannot answer twice")
  Assert.notNil(againErr, "rejected duplicates name their input error")

  local betaActor = assert(beta.actors[1], "the opposing request addresses its lead")
  local betaOk, betaErr = session:submit(SessionFixture.replyFor(beta, {
    SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
  }))
  Assert.isTrue(betaOk, "the waiting peer still answers: " .. tostring(betaErr))
  Assert.isNil(betaErr, "accepted peer replies carry no input error")
  local firstEvents = SessionFixture.driveToEnd(session, 64, function(request)
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(3))
    end
    return choices
  end)
  session:dispose()

  local reversed = SessionFixture.newSession(contracts, SessionFixture.buildScenario(reserveDoubles()))
  local reopened = SessionFixture.driveUntilSettled(reversed, 64)
  local reopenedBeta = requestFor(reopened, "beta")
  local reopenedAlpha = requestFor(reopened, "alpha")
  local reopenedFoe = assert(reopenedBeta.actors[1], "the reversed peer answers first")
  local reversedBetaOk, reversedBetaErr = reversed:submit(SessionFixture.replyFor(reopenedBeta, {
    SessionFixture.attackChoice(reopenedFoe, 0, SessionFixture.positionTarget(1)),
  }))
  Assert.isTrue(reversedBetaOk, "reordered legal replies are accepted: " .. tostring(reversedBetaErr))
  Assert.isNil(reversedBetaErr, "accepted reordered replies carry no input error")
  local reopenedChoices = {}
  for _, actor in ipairs(reopenedAlpha.actors) do
    reopenedChoices[#reopenedChoices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(3))
  end
  local reversedAlphaOk, reversedAlphaErr = reversed:submit(SessionFixture.replyFor(reopenedAlpha, reopenedChoices))
  Assert.isTrue(reversedAlphaOk, "the delayed side still answers: " .. tostring(reversedAlphaErr))
  Assert.isNil(reversedAlphaErr, "accepted delayed replies carry no input error")
  local secondEvents = SessionFixture.driveToEnd(reversed, 64, function(request)
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(3))
    end
    return choices
  end)
  reversed:dispose()

  Assert.deepEqual(firstEvents, secondEvents, "submission order never affects the outcome")
  Assert.isTrue(#firstEvents > 0, "the committed batches settle their strikes")
end

return { tests = T }
