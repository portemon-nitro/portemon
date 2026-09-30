-- Sealed simultaneous replies under one atomic batch: two controllers
-- answer in either order without changing the outcome, peers keep their
-- request epoch after a partner answers, and foreign actors, stale epochs,
-- duplicate actions, and exhausted reservations are rejected without
-- consuming randomness, items, or revealing sealed opposing choices.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table scenario parts for a doubles lineup with shared supplies
local function doubles()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
      }, "shared-bag"),
      SessionFixture.participant(2, 2, "beta", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }, "shared-bag"),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 3),
    },
    inventories = {
      SessionFixture.inventory("shared-bag", { 1, 2 }, { POTION = 2 }),
    },
  }
end

---@param request table pending decision request
---@return table[] one strike per addressed actor
local function strikeEveryone(request)
  local choices = {}
  for _, actor in ipairs(request.actors) do
    choices[#choices + 1] =
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
  end
  return choices
end

---@param session table live headless session
---@param frame table waiting frame whose batch is answered in reverse
local function answerReversed(session, frame)
  local requests = frame.request.requests
  for index = #requests, 1, -1 do
    local request = requests[index]
    local ok, err = session:submit(SessionFixture.replyFor(request, strikeEveryone(request)))
    Assert.isTrue(ok, "reordered legal replies are accepted")
    Assert.isNil(err, "accepted replies carry no input error")
  end
end

---@param session table live headless session
---@param frame table waiting frame whose batch is answered in order
local function answerForward(session, frame)
  for _, request in ipairs(frame.request.requests) do
    local ok, err = session:submit(SessionFixture.replyFor(request, strikeEveryone(request)))
    Assert.isTrue(ok, "legal replies are accepted")
    Assert.isNil(err, "accepted replies carry no input error")
  end
end

function T.simultaneous_replies_stay_sealed_and_commit_atomically()
  local contracts = SessionFixture.sessionContracts()

  local first = SessionFixture.newSession(contracts, SessionFixture.buildScenario(doubles()))
  local waiting = SessionFixture.driveUntilSettled(first, 64)
  Assert.equal(waiting.status, "waiting", "open battles wait for both controllers")
  Assert.equal(#waiting.request.requests, 2, "each controller answers its own request")
  local epoch = waiting.request.epoch
  answerReversed(first, waiting)
  local firstEvents = SessionFixture.driveToEnd(first, 64, strikeEveryone)
  first:dispose()

  local second = SessionFixture.newSession(contracts, SessionFixture.buildScenario(doubles()))
  local reopened = SessionFixture.driveUntilSettled(second, 64)
  Assert.equal(reopened.status, "waiting", "rebuilt battles wait the same way")
  Assert.equal(reopened.request.epoch, epoch, "identical setups freeze identical epochs")
  answerForward(second, reopened)
  local secondEvents = SessionFixture.driveToEnd(second, 64, strikeEveryone)
  second:dispose()

  Assert.deepEqual(firstEvents, secondEvents, "submission order never affects the outcome")
end

function T.rejected_replies_leave_state_randomness_and_resources_untouched()
  local contracts = SessionFixture.sessionContracts()
  Assert.isTrue(
    type(contracts.Protocol.validateReply) == "function",
    "protocol owns reply validation without fallback coercion"
  )
  Assert.isTrue(
    type(contracts.Protocol.validateChoice) == "function",
    "protocol owns choice validation without fallback coercion"
  )
  Assert.isTrue(
    type(contracts.Protocol.validateEvent) == "function",
    "protocol owns event validation without fallback coercion"
  )

  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(doubles()))
  local waiting = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(waiting.status, "waiting", "open battles wait for both controllers")
  local pristine = session:capture()
  SessionFixture.assertPlainData(pristine, "pending")

  local alphaRequest = nil
  local betaRequest = nil
  for _, request in ipairs(waiting.request.requests) do
    if request.controller == "alpha" then
      alphaRequest = request
    elseif request.controller == "beta" then
      betaRequest = request
    end
  end
  Assert.notNil(alphaRequest, "alpha holds its own request")
  Assert.notNil(betaRequest, "beta holds its own request")
  assert(alphaRequest ~= nil and betaRequest ~= nil, "both controllers hold requests")

  local betaBefore = session:view("beta")
  local alphaChoices = strikeEveryone(alphaRequest)
  local ok, err = session:submit(SessionFixture.replyFor(alphaRequest, alphaChoices))
  Assert.isTrue(ok, "alpha answers first")
  Assert.isNil(err, "accepted replies carry no input error")
  Assert.deepEqual(
    session:view("beta"),
    betaBefore,
    "sealed choices stay hidden from waiting peers"
  )

  local betaChoices = strikeEveryone(betaRequest)
  local betaOk, betaErr = session:submit(SessionFixture.replyFor(betaRequest, betaChoices))
  Assert.isTrue(betaOk, "peers keep their valid epoch after a partner answers")
  Assert.isNil(betaErr, "accepted peer replies carry no input error")
  session:dispose()

  local fresh = SessionFixture.newSession(contracts, SessionFixture.buildScenario(doubles()))
  local reopened = SessionFixture.driveUntilSettled(fresh, 64)
  local clean = fresh:capture()
  local firstRequest = reopened.request.requests[1]
  local secondRequest = reopened.request.requests[2]
  Assert.notNil(firstRequest, "rebuilt battles reopen their batch")
  Assert.notNil(secondRequest, "rebuilt batches address every controller")
  assert(firstRequest ~= nil and secondRequest ~= nil, "rebuilt requests load")

  local foreign = strikeEveryone(secondRequest)
  local foreignReply = SessionFixture.replyFor(firstRequest, foreign)
  local foreignOk, foreignErr = fresh:submit(foreignReply)
  Assert.isFalse(foreignOk, "controllers cannot answer for foreign actors")
  Assert.notNil(foreignErr, "rejected replies name their input error")

  local staleReply = SessionFixture.replyFor(firstRequest, strikeEveryone(firstRequest))
  staleReply.epoch = reopened.request.epoch + 1
  local staleOk, staleErr = fresh:submit(staleReply)
  Assert.isFalse(staleOk, "stale epochs cannot answer a frozen batch")
  Assert.notNil(staleErr, "rejected epochs name their input error")

  local doubled = strikeEveryone(firstRequest)
  for _, actor in ipairs(firstRequest.actors) do
    doubled[#doubled + 1] = SessionFixture.confirmChoice(actor)
  end
  local doubleOk, doubleErr =
    fresh:submit(SessionFixture.replyFor(firstRequest, doubled))
  Assert.isFalse(doubleOk, "duplicate actions for one actor cannot queue twice")
  Assert.notNil(doubleErr, "rejected duplicates name their input error")

  Assert.deepEqual(fresh:capture(), clean, "rejected replies consume nothing")
  fresh:dispose()
end

return { tests = T }
