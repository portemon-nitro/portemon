-- Interruptions resume from plain data: a parent operation yields a
-- replacement decision and later a move-learning decision, captures taken
-- between atomic operations restore on another session, identical replies
-- reproduce identical events and randomness under any operation budget, and
-- no capture carries functions, threads, userdata, or cycles.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table scenario parts where combatants hold reserves to call on
local function interruptible()
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
      SessionFixture.participant(2, 2, "beta", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 3),
    },
  }
end

---@param request table pending decision request
---@return table[] scripted answers following the interruption policy
local function answer(request)
  local choices = {}
  for _, actor in ipairs(request.actors) do
    if request.kind == "switch" then
      local replacement = actor.combatant + 1
      choices[#choices + 1] = SessionFixture.switchChoice(actor, replacement)
    elseif request.kind == "learn" then
      choices[#choices + 1] = SessionFixture.confirmChoice(actor)
    else
      choices[#choices + 1] =
        SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
    end
  end
  return choices
end

---@param session table live headless session
---@param budget integer operations per advance call
---@return table run holding every event, every capture, and the event count preceding the first capture
local function runWithCaptures(session, budget)
  local events = {}
  local captures = {}
  local prefixLength = nil
  for _ = 1, 256 do
    local frame = session:advance(budget)
    Assert.notNil(frame, "advance returns a battle frame")
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        events[#events + 1] = event
      end
    end
    if frame.status == "ended" then
      return { events = events, captures = captures, prefixLength = prefixLength or 0 }
    end
    Assert.equal(frame.status, "waiting", "open sessions wait for decisions")
    if prefixLength == nil then
      prefixLength = #events
    end
    captures[#captures + 1] = session:capture()
    for _, request in ipairs(frame.request.requests) do
      local ok, err = session:submit(SessionFixture.replyFor(request, answer(request)))
      Assert.isTrue(ok, "scripted answers to open requests are accepted")
      Assert.isNil(err, "accepted replies carry no input error")
    end
  end
  error("session did not end within its operation bound")
end

function T.nested_interruptions_resume_from_plain_data_with_identical_results()
  local contracts = SessionFixture.sessionContracts()

  local narrow = SessionFixture.newSession(contracts, SessionFixture.buildScenario(interruptible()))
  local narrowRun = runWithCaptures(narrow, 1)
  local narrowFinal = narrow:capture()
  narrow:dispose()

  local wide = SessionFixture.newSession(contracts, SessionFixture.buildScenario(interruptible()))
  local wideRun = runWithCaptures(wide, 1000)
  local wideFinal = wide:capture()
  wide:dispose()

  Assert.deepEqual(wideRun.events, narrowRun.events, "operation budgets never change the event stream")
  Assert.deepEqual(wideFinal, narrowFinal, "operation budgets never change the final state")
  Assert.isTrue(#narrowRun.captures > 0, "the run waited for decisions at least once")

  local resumed = SessionFixture.newSession(contracts, SessionFixture.buildScenario(interruptible()))
  local firstHeld = narrowRun.captures[1]
  Assert.notNil(firstHeld, "the uninterrupted run held its first capture")
  local continuing = contracts.Session.restore(firstHeld, SessionFixture.makeContent())
  Assert.notNil(continuing, "restoring resumes from captured data")
  local resumedEvents = {}
  for _ = 1, 256 do
    local frame = continuing:advance(1)
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        resumedEvents[#resumedEvents + 1] = event
      end
    end
    if frame.status == "ended" then
      break
    end
    Assert.equal(frame.status, "waiting", "resumed sessions wait for decisions")
    for _, request in ipairs(frame.request.requests) do
      local ok, err = continuing:submit(SessionFixture.replyFor(request, answer(request)))
      Assert.isTrue(ok, "resumed sessions accept the same replies")
      Assert.isNil(err, "accepted replies carry no input error")
    end
  end
  continuing:dispose()
  resumed:dispose()

  local remaining = {}
  for index = narrowRun.prefixLength + 1, #narrowRun.events do
    remaining[#remaining + 1] = narrowRun.events[index]
  end
  Assert.deepEqual(
    resumedEvents,
    remaining,
    "resuming replays the exact remaining stream without repeating parents"
  )

  local seenSequences = {}
  for _, event in ipairs(narrowRun.events) do
    Assert.isTrue(type(event.sequence) == "number", "events carry sequence ordinals")
    Assert.isNil(seenSequences[event.sequence], "parent steps never execute twice")
    seenSequences[event.sequence] = true
  end
  Assert.isTrue(#resumedEvents > 0, "resumed sessions emit their remaining events")
end

function T.captured_state_holds_no_live_references_and_restores_exactly()
  local contracts = SessionFixture.sessionContracts()

  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(interruptible()))
  local frame = SessionFixture.driveUntilSettled(session, 64)
  Assert.equal(frame.status, "waiting", "open battles wait for decisions")
  local held = session:capture()
  SessionFixture.assertPlainData(held, "pending")

  local twin = contracts.Session.restore(held, SessionFixture.makeContent())
  Assert.notNil(twin, "plain captures restore without host services")
  Assert.deepEqual(twin:capture(), held, "restore round-trips the held state exactly")
  twin:dispose()
  session:dispose()
end

return { tests = T }
