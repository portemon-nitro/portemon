-- Exact executable battle replays: one full battle recorded through the
-- production session kernel, crossing a snapshot restore midway, replays to
-- identical state, events, and random consumption under any operation
-- budget. Controller decisions come from the real native AI bound to a real
-- labeled draw stream, so reexecuting the AI from the same seed must return
-- the recorded replies with the same draw count. Reading the recorded event
-- log back is presentation only and never simulates, and any changed
-- executable identity or diverged expectation reports its first mismatch
-- instead of silently passing.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local AI_MODULE = "libs.hgss.src.battle.HgssTrainerAi"
local AI_SEED = 11259375

---@return table scenario parts with a human side and a native-AI side
local function duel()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "human", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
      }),
      SessionFixture.participant(2, 2, "ai", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 3),
    },
    inventories = {},
  }
end

---@param request table pending decision request
---@return table[] one strike per addressed actor
local function strikeEveryone(request)
  local choices = {}
  for _, actor in ipairs(request.actors) do
    choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
  end
  return choices
end

---@return table native AI controller bound to its fixed opening program
local function boundAi()
  local Ai = SessionFixture.requirePresent(AI_MODULE, "the native controller binds flags and programs to decisions")
  Assert.isTrue(type(Ai.new) == "function", "the native controller exposes its constructor")
  return Ai.new({
    program = { key = "youngster_opening", revision = "native-1", instructions = {}, entryPoints = {} },
    aiPasses = {},
  })
end

-- Read-only draw observer around the real labeled stream: every delegated
-- draw is logged with its raw value, label, ordinal, and cause while the
-- mechanics see the untouched production stream.
---@param stream table real labeled battle stream
---@param log table[] draw entries in call order
---@return table observing stream with the same call surface
local function observing(stream, log)
  return {
    nextU16 = function(_, label, cause)
      local raw = stream:nextU16(label, cause)
      log[#log + 1] = { raw = raw, reason = label, ordinal = #log + 1, cause = cause }
      return raw
    end,
    capture = function(_)
      return stream:capture()
    end,
  }
end

---@param value unknown
---@return unknown detached plain copy
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in
    pairs(value --[[@as table<unknown, unknown>]])
  do
    out[key] = deepCopy(item)
  end
  return out
end

---@param contracts table session owners under test
---@param controller table native AI answering owned requests
---@param drawLog table[] controller draw entries in call order
---@param aiStream table real labeled stream behind the observer
---@return table recording holding decisions, events, outcome, and RNG facts
local function recordBattle(contracts, controller, drawLog, aiStream)
  local watched = observing(aiStream, drawLog)
  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
  local decisions = {}
  local events = {}
  local boundaryRng = nil
  local prefixLength = 0
  local restored = false
  for _ = 1, 512 do
    local frame = session:advance(1)
    Assert.notNil(frame, "advance returns a battle frame")
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        events[#events + 1] = event
      end
    end
    if frame.status == "ended" then
      local held = session:capture()
      local outcome = frame.outcome
      session:dispose()
      Assert.notNil(outcome, "ended battles carry their outcome")
      Assert.notNil(boundaryRng, "the recording crossed its restore boundary")
      return {
        decisions = decisions,
        events = events,
        outcome = outcome,
        controllerDraws = drawLog,
        kernelBoundaryRng = boundaryRng,
        kernelFinalRng = held.rng,
        prefixLength = prefixLength,
      }
    end
    Assert.equal(frame.status, "waiting", "open battles wait for decisions")
    if not restored then
      restored = true
      prefixLength = #events
      local held = session:capture()
      boundaryRng = deepCopy(held.rng)
      local continuing = contracts.Session.restore(held, SessionFixture.makeContent())
      Assert.notNil(continuing, "restoring resumes from captured data")
      session:dispose()
      session = continuing
    end
    Assert.notNil(frame.request, "waiting frames carry their decision batch")
    for _, request in ipairs(frame.request.requests) do
      local reply
      if request.controller == "ai" then
        reply = controller:decide(request, session:view("ai"), watched)
      else
        reply = SessionFixture.replyFor(request, strikeEveryone(request))
      end
      decisions[#decisions + 1] = reply
      local ok, err = session:submit(reply)
      Assert.isTrue(ok, "scripted answers to open requests are accepted")
      Assert.isNil(err, "accepted replies carry no input error")
    end
  end
  error("the scripted battle did not end within its operation bound")
end

-- Pins the exact executable configuration the recording was made under:
-- every field comes from the real fixture constants, so any changed build,
-- ruleset, content revision, stream algorithm, or seed must reject.
---@return table executable identity under test
local function executableIdentity()
  return {
    engineBuild = "test-session-kernel",
    ruleset = SessionFixture.RULESET,
    format = SessionFixture.FORMAT,
    contentRevision = "session-tests",
    randomAlgorithm = "gen4-lcrng",
    seed = SessionFixture.RANDOM_SEED,
  }
end

function T.exact_replays_reproduce_ai_draws_events_and_state()
  local Replay = SessionFixture.requirePresent(
    "libs.battle.src.BattleReplay",
    "strict executable envelopes own deterministic battle replays"
  )
  Assert.isTrue(type(Replay.capture) == "function", "replay envelopes own their recording capture")
  Assert.isTrue(type(Replay.validateIdentity) == "function", "replay envelopes own strict identity checks")
  Assert.isTrue(type(Replay.replay) == "function", "replay envelopes own exact simulation replay")
  Assert.isTrue(type(Replay.playbackEvents) == "function", "replay envelopes own presentation-only playback")

  local contracts = SessionFixture.sessionContracts()
  local drawLog = {}
  local aiStream =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
      .new(AI_SEED)
  local recording = recordBattle(contracts, boundAi(), drawLog, aiStream)
  Assert.isTrue(#recording.decisions > 0, "the recording holds every submitted decision")
  Assert.isTrue(#recording.events > 0, "the recording holds every emitted event")
  Assert.isTrue(#recording.controllerDraws > 0, "the native AI drew from its stream during the recording")
  for index, entry in ipairs(recording.controllerDraws) do
    Assert.equal(entry.ordinal, index, "controller draws carry exact call ordinals")
    Assert.isTrue(type(entry.raw) == "number", "controller draws record their raw value")
    Assert.isTrue(type(entry.reason) == "string", "controller draws record their call-site reason")
    Assert.notNil(entry.cause, "controller draws record their semantic cause")
  end
  SessionFixture.assertPlainData(recording.decisions, "recording.decisions")

  local identity = executableIdentity()
  local envelope = Replay.capture({
    identity = deepCopy(identity),
    scenario = SessionFixture.buildScenario(duel()),
    decisions = recording.decisions,
    externalInputs = {},
    randomTrace = {
      controllerDraws = recording.controllerDraws,
      kernelBoundaryRng = recording.kernelBoundaryRng,
      kernelFinalRng = recording.kernelFinalRng,
    },
    expectedEvents = recording.events,
    expectedOutcome = recording.outcome,
  })
  Assert.equal(envelope.schema, "portemon-battle-replay-v1", "replay envelopes carry their versioned schema")
  Assert.notNil(envelope.identity, "replay envelopes pin their executable identity")
  Assert.notNil(envelope.expectedEvents, "replay envelopes carry their expected event log")
  Assert.notNil(envelope.expectedOutcome, "replay envelopes carry their expected outcome")

  Replay.validateIdentity(envelope, executableIdentity())

  local content = SessionFixture.makeContent()
  local narrow = Replay.replay(envelope, { budget = 1, content = content })
  local wide = Replay.replay(envelope, { budget = 1000, content = content })
  Assert.isNil(narrow.mismatch, "exact replays report no mismatch")
  Assert.isNil(wide.mismatch, "exact replays report no mismatch under wide budgets")
  Assert.deepEqual(narrow.events, envelope.expectedEvents, "narrow replays reproduce the recorded events")
  Assert.deepEqual(wide.events, envelope.expectedEvents, "wide replays reproduce the recorded events")
  Assert.deepEqual(narrow.events, wide.events, "operation budgets never change replayed events")
  Assert.deepEqual(narrow.outcome, envelope.expectedOutcome, "replays reproduce the recorded outcome")
  Assert.deepEqual(narrow.randomTrace, wide.randomTrace, "operation budgets never change replayed draws")
  Assert.deepEqual(narrow.randomTrace, envelope.randomTrace, "replays reproduce the recorded draw stream exactly")

  local played = Replay.playbackEvents(envelope)
  Assert.deepEqual(played, envelope.expectedEvents, "playback reads back the recorded event log")
  played[1] = nil
  Assert.notNil(envelope.expectedEvents[1], "playback hands out detached copies, never the log itself")

  local changedIdentity = executableIdentity()
  changedIdentity.contentRevision = "session-tests-changed"
  Assert.throws(function()
    Replay.validateIdentity(envelope, changedIdentity)
  end, "changed executable content never replays exactly")

  local tampered = deepCopy(envelope --[[@as table<unknown, unknown>]]) --[[@as table<string, unknown>]]
  tampered.identity = changedIdentity
  local identityMismatch = Replay.replay(tampered, { budget = 1 })
  Assert.isTrue(type(identityMismatch.mismatch) == "table", "changed identity replays report their mismatch")
  Assert.equal(identityMismatch.mismatch.kind, "identity", "changed builds mismatch at the identity boundary")

  local diverged = deepCopy(envelope --[[@as table<unknown, unknown>]]) --[[@as table<string, unknown>]]
  local expectedEvents = diverged.expectedEvents --[[@as table<integer, table<string, unknown>>]]
  local last = expectedEvents[#expectedEvents]
  last.sequence = last.sequence --[[@as integer]] + 1000000
  local divergence = Replay.replay(diverged, { budget = 1, content = content })
  Assert.isTrue(type(divergence.mismatch) == "table", "diverged expectations report their first mismatch")
  Assert.isTrue(type(divergence.mismatch.kind) == "string", "mismatches name their boundary")
  Assert.isTrue(
    divergence.mismatch.ordinal ~= nil or divergence.mismatch.phase ~= nil,
    "mismatches locate their first divergence"
  )
  Assert.notNil(divergence.mismatch.expected, "mismatches carry the expected value")
  Assert.notNil(divergence.mismatch.actual, "mismatches carry the actual value")

  local freshLog = {}
  local freshStream =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
      .new(AI_SEED)
  local freshAi = boundAi()
  local watched = observing(freshStream, freshLog)
  local humanReplies = {}
  for _, reply in ipairs(recording.decisions) do
    if reply.controller ~= "ai" then
      humanReplies[#humanReplies + 1] = reply
    end
  end
  local reexecutedEvents = {}
  local reexecutedOutcome = nil
  local reSession = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
  local humanCursor = 0
  for _ = 1, 512 do
    local frame = reSession:advance(1)
    Assert.notNil(frame, "reexecution advances through battle frames")
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        reexecutedEvents[#reexecutedEvents + 1] = event
      end
    end
    if frame.status == "ended" then
      reexecutedOutcome = frame.outcome
      break
    end
    Assert.equal(frame.status, "waiting", "reexecuted battles wait for the same decisions")
    for _, request in ipairs(frame.request.requests) do
      local reply
      if request.controller == "ai" then
        reply = freshAi:decide(request, reSession:view("ai"), watched)
      else
        humanCursor = humanCursor + 1
        reply = humanReplies[humanCursor]
        Assert.notNil(reply, "reexecution reuses every recorded human reply in order")
        Assert.equal(reply.controller, request.controller, "human replies answer their recorded controller")
      end
      local ok, err = reSession:submit(reply)
      Assert.isTrue(ok, "reexecuted replies are accepted")
      Assert.isNil(err, "accepted reexecuted replies carry no input error")
    end
  end
  local reHeld = reSession:capture()
  reSession:dispose()
  Assert.notNil(reexecutedOutcome, "reexecuted battles reach their outcome")
  Assert.equal(humanCursor, #humanReplies, "reexecution consumes every recorded human reply")
  Assert.deepEqual(reexecutedEvents, recording.events, "reexecuted AI reproduces the recorded event stream")
  Assert.deepEqual(reexecutedOutcome, recording.outcome, "reexecuted AI reproduces the recorded outcome")
  Assert.deepEqual(freshLog, recording.controllerDraws, "reexecuted AI consumes the identical draw stream")
  Assert.deepEqual(freshStream:capture(), aiStream:capture(), "reexecuted AI ends on the identical stream state")
  Assert.deepEqual(reHeld.rng, recording.kernelFinalRng, "reexecution consumes the kernel stream exactly")
end

-- Rejects malformed envelopes at their boundary: every identity field is
-- pinned exactly, unknown fields never validate, captures copy their
-- recording, and foreign schemas never replay or play back.
function T.replay_envelopes_reject_malformed_records_and_foreign_identity()
  local Replay = SessionFixture.requirePresent(
    "libs.battle.src.BattleReplay",
    "strict executable envelopes own deterministic battle replays"
  )
  local identity = {
    engineBuild = "test-session-kernel",
    ruleset = SessionFixture.RULESET,
    format = SessionFixture.FORMAT,
    contentRevision = "session-tests",
    randomAlgorithm = "gen4-lcrng",
    seed = SessionFixture.RANDOM_SEED,
  }
  local recording = {
    identity = identity,
    scenario = SessionFixture.buildScenario(duel()),
    decisions = {
      { requestId = 1, epoch = 1, controller = "human", choices = {} },
    },
    externalInputs = {},
    randomTrace = {
      controllerDraws = {},
      kernelBoundaryRng = { state = SessionFixture.RANDOM_SEED, calls = 0 },
      kernelFinalRng = { state = SessionFixture.RANDOM_SEED, calls = 0 },
    },
    expectedEvents = {},
    expectedOutcome = { kind = "scripted_complete", rounds = 3 },
  }
  local envelope = Replay.capture(recording)
  Assert.equal(envelope.schema, "portemon-battle-replay-v1", "captures carry the versioned schema")
  Assert.isTrue(type(envelope.seal) == "string" and envelope.seal ~= "", "captures seal their inputs")
  Assert.isTrue(Replay.validateIdentity(envelope, identity), "matching identities validate")

  recording.decisions[1].requestId = 9999
  Assert.equal(envelope.decisions[1].requestId, 1, "captures copy their recording")

  for _, field in ipairs({ "engineBuild", "ruleset", "format", "contentRevision", "randomAlgorithm", "seed" }) do
    local changed = {}
    for key, value in pairs(identity) do
      changed[key] = value
    end
    if type(changed[field]) == "string" then
      changed[field] = changed[field] .. "-changed"
    else
      changed[field] = changed[field] + 1
    end
    Assert.throws(function()
      Replay.validateIdentity(envelope, changed)
    end, "changed " .. field .. " never validates")
  end
  local missing = {}
  for key, value in pairs(identity) do
    missing[key] = value
  end
  missing.seed = nil
  Assert.throws(function()
    Replay.validateIdentity(envelope, missing)
  end, "missing identity fields never validate")
  local unknown = {}
  for key, value in pairs(identity) do
    unknown[key] = value
  end
  unknown.renderer = "headless"
  Assert.throws(function()
    Replay.validateIdentity(envelope, unknown)
  end, "unknown identity fields never validate")

  local withoutIdentity = {}
  for key, value in pairs(recording) do
    withoutIdentity[key] = value
  end
  withoutIdentity.identity = nil
  Assert.throws(function()
    Replay.capture(withoutIdentity)
  end, "recordings without identity never capture")
  local badSeed = {}
  for key, value in pairs(recording) do
    badSeed[key] = value
  end
  badSeed.identity = {}
  for key, value in pairs(identity) do
    badSeed.identity[key] = value
  end
  badSeed.identity.seed = "not-a-seed"
  Assert.throws(function()
    Replay.capture(badSeed)
  end, "recordings with a malformed seed never capture")
  local liveDecision = {}
  for key, value in pairs(recording) do
    liveDecision[key] = value
  end
  liveDecision.decisions = { { requestId = 1, epoch = 1, controller = "human", choices = function() end } }
  Assert.throws(function()
    Replay.capture(liveDecision)
  end, "recordings carrying live functions never capture")
  Assert.throws(function()
    Replay.capture("not-a-recording")
  end, "non-record captures never publish")

  local foreignSchema = {}
  for key, value in pairs(envelope) do
    foreignSchema[key] = value
  end
  foreignSchema.schema = "other-schema"
  Assert.throws(function()
    Replay.validateIdentity(foreignSchema, identity)
  end, "foreign schemas never validate")
  Assert.throws(function()
    Replay.replay(foreignSchema, { budget = 1 })
  end, "foreign schemas never replay")
  Assert.throws(function()
    Replay.playbackEvents(foreignSchema)
  end, "foreign schemas never play back")
end

return { tests = T }
