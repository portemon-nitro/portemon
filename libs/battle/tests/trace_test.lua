-- Inert bounded battle diagnostics: the same scripted battle executed
-- without observation and with every event, draw, and arithmetic stage
-- mirrored into an explicitly bounded collector ends on identical state,
-- events, and stream positions. Mirroring twice yields identical
-- collectors, so entry identifiers never depend on the wall clock, the
-- renderer, or extra random draws; over-bound recording fails instead of
-- growing; and a diverged copy reports its first divergent entry with both
-- sides attached. A late formatting consumer reads only the stored
-- entries, never live battle objects.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local AI_MODULE = "libs.hgss.src.battle.HgssTrainerAi"
local AI_SEED = 24681357
local PROBE_SEED = 777

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
  return Ai.new({
    program = { key = "youngster_opening", revision = "native-1", instructions = {}, entryPoints = {} },
    aiPasses = {},
  })
end

---@param bound integer maximum entries the collector accepts
---@return table empty bounded collector owned by the caller
local function collectorWithBound(bound)
  return { bound = bound, entries = {} }
end

-- Runs one full scripted battle to its outcome, returning every emitted
-- event, the terminal outcome, the final capture, and the AI stream state.
---@param contracts table session owners under test
---@param controller table native AI answering owned requests
---@param aiStream table real labeled stream owned by this run
---@return table run facts for inertness comparison
local function runBattle(contracts, controller, aiStream)
  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
  local events = {}
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
      return { events = events, outcome = outcome, finalCapture = held, aiCalls = aiStream:capture() }
    end
    Assert.equal(frame.status, "waiting", "open battles wait for decisions")
    for _, request in ipairs(frame.request.requests) do
      local reply
      if request.controller == "ai" then
        reply = controller:decide(request, session:view("ai"), aiStream)
      else
        reply = SessionFixture.replyFor(request, strikeEveryone(request))
      end
      local ok, err = session:submit(reply)
      Assert.isTrue(ok, "scripted answers to open requests are accepted")
      Assert.isNil(err, "accepted replies carry no input error")
    end
  end
  error("the scripted battle did not end within its operation bound")
end

-- Formats stored diagnostic entries long after the battle ended: pure text
-- derived only from entry kinds and ordinals, never from live objects.
---@param entries table[] stored diagnostic entries
---@return string one line per entry in record order
local function formatEntries(entries)
  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = tostring(entry.kind) .. ":" .. tostring(entry.ordinal)
  end
  return table.concat(lines, "\n")
end

function T.diagnostics_observe_without_changing_mechanics_and_within_bounds()
  local Trace =
    SessionFixture.requirePresent("libs.battle.src.BattleTrace", "inert mechanics diagnostics own bounded observation")
  Assert.isTrue(type(Trace.random) == "function", "diagnostics own labeled draw recording")
  Assert.isTrue(type(Trace.arithmetic) == "function", "diagnostics own staged arithmetic recording")
  Assert.isTrue(type(Trace.event) == "function", "diagnostics own semantic event recording")
  Assert.isTrue(type(Trace.mismatch) == "function", "diagnostics own first-divergence reporting")

  local contracts = SessionFixture.sessionContracts()
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  local plain = runBattle(contracts, boundAi(), BattleRng.new(AI_SEED))
  Assert.isTrue(#plain.events > 0, "the unobserved battle emits events")

  -- Level 50, power 80, attack 120, defense 90, neutral modifiers, maximum
  -- roll: floor(2*50/5+2) = 22; floor(22*80*120/90) = 2346;
  -- floor(2346/50)+2 = 48; every later stage holds 48. Hand-evaluated from
  -- the staged Generation-IV sequence and pinned by the staged damage
  -- vector suite, never read out of the implementation under test.
  local damageSpec = {
    level = 50,
    power = 80,
    attack = 120,
    defense = 90,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    randomPercent = 100,
  }
  local Damage = SessionFixture.requirePresent("libs.battle.src.gen4.Damage", "exact phased arithmetic owns damage")
  local untracedStream = BattleRng.new(PROBE_SEED)
  local untraced = Damage.calculate(damageSpec, untracedStream)
  local stagedStream = BattleRng.new(PROBE_SEED)
  local staged = Damage.trace(damageSpec, stagedStream)
  Assert.equal(untraced.amount, 48, "the hand-evaluated damage amount holds")
  Assert.equal(staged.amount, untraced.amount, "traced and untraced calculations agree")
  Assert.deepEqual(stagedStream:capture(), untracedStream:capture(), "tracing consumes no extra draws")
  Assert.isTrue(#staged.stages > 0, "traced calculations expose their staged intermediates")
  Assert.equal(staged.stages[1].name, "base", "stages open with the base truncation")
  Assert.equal(staged.stages[1].output, 48, "the base stage truncates to the hand-evaluated value")

  -- The mirrored run observes the identical battle: every emitted event, a
  -- fixed labeled probe draw sequence from its own stream, and the staged
  -- arithmetic intermediates above are recorded into the collector.
  local mirroredStream = BattleRng.new(AI_SEED)
  local probeStream = BattleRng.new(PROBE_SEED)
  local probeBefore = probeStream:capture()
  local seen = collectorWithBound(4096)
  local mirroredController = boundAi()
  local mirroredSession = SessionFixture.newSession(contracts, SessionFixture.buildScenario(duel()))
  local mirroredEvents = {}
  for _ = 1, 512 do
    local frame = mirroredSession:advance(1)
    Assert.notNil(frame, "the mirrored battle advances through battle frames")
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        mirroredEvents[#mirroredEvents + 1] = event
        Trace.event(seen, event)
      end
    end
    if frame.status == "ended" then
      break
    end
    Assert.equal(frame.status, "waiting", "mirrored battles wait for decisions")
    for _, request in ipairs(frame.request.requests) do
      local reply
      if request.controller == "ai" then
        reply = mirroredController:decide(request, mirroredSession:view("ai"), mirroredStream)
      else
        reply = SessionFixture.replyFor(request, strikeEveryone(request))
      end
      local ok, err = mirroredSession:submit(reply)
      Assert.isTrue(ok, "mirrored answers to open requests are accepted")
      Assert.isNil(err, "accepted mirrored replies carry no input error")
    end
  end
  for probeIndex = 1, 3 do
    local raw = probeStream:nextU16("trace_probe", { kind = "trace_probe", index = probeIndex })
    Trace.random(seen, { raw = raw, reason = "trace_probe", ordinal = probeIndex, cause = { kind = "trace_probe" } })
  end
  for _, stage in ipairs(staged.stages) do
    Trace.arithmetic(seen, stage)
  end
  local mirroredHeld = mirroredSession:capture()
  mirroredSession:dispose()
  SessionFixture.assertPlainData(seen.entries, "diagnostics.entries")

  Assert.deepEqual(mirroredEvents, plain.events, "observation never changes the emitted events")
  Assert.deepEqual(mirroredHeld, plain.finalCapture, "observation never changes the terminal state")
  Assert.deepEqual(mirroredStream:capture(), plain.aiCalls, "observation never changes controller draw counts")
  Assert.isTrue(#seen.entries > #plain.events, "the collector holds draws and stages beyond the events")
  Assert.isTrue(#seen.entries <= seen.bound, "collection stays within its explicit bound")
  for index, entry in ipairs(seen.entries) do
    Assert.isTrue(type(entry.kind) == "string", "stored entries name their record kind")
    Assert.equal(entry.ordinal, index, "stored entries carry exact sequence ordinals")
    Assert.notNil(entry.detail, "stored entries carry their recorded detail")
  end

  local probeAfter = probeStream:capture()
  Assert.equal(probeAfter.calls, probeBefore.calls + 3, "probe draws advance exactly three calls")
  local replayedStream = BattleRng.new(PROBE_SEED)
  for probeIndex = 1, 3 do
    replayedStream:nextU16("trace_probe", { kind = "trace_probe", index = probeIndex })
  end
  Assert.deepEqual(replayedStream:capture(), probeAfter, "probe draws replay exactly")

  local formattedOnce = formatEntries(seen.entries)
  Assert.equal(formatEntries(seen.entries), formattedOnce, "late formatting is stable")
  Assert.isTrue(#formattedOnce > 0, "the late consumer formats every stored entry")

  local overflow = collectorWithBound(2)
  Trace.event(overflow, plain.events[1])
  Trace.event(overflow, plain.events[1])
  Assert.throws(function()
    Trace.event(overflow, plain.events[1])
  end, "over-bound recording fails instead of growing")

  local function eventIndices(entries)
    local found = {}
    for index, entry in ipairs(entries) do
      if entry.kind == "event" then
        found[#found + 1] = index
      end
    end
    return found
  end
  local at = eventIndices(seen.entries)
  Assert.isTrue(#at >= 2, "the collector holds at least two recorded events")

  local function copied(entries)
    local out = {}
    for index, entry in ipairs(entries) do
      local detail = {}
      for key, value in
        pairs(entry.detail --[[@as table<unknown, unknown>]])
      do
        detail[key] = value
      end
      out[index] = { kind = entry.kind, ordinal = entry.ordinal, detail = detail }
    end
    return out
  end
  local single = copied(seen.entries)
  local firstAt = at[1]
  single[firstAt].detail.sequence = single[firstAt].detail.sequence --[[@as integer]] + 1000000
  local singleMismatch = Trace.mismatch(seen.entries, single)
  Assert.isTrue(type(singleMismatch) == "table", "diverged entries report their mismatch")
  Assert.equal(singleMismatch.kind, "event", "event divergence reports at the event boundary")
  Assert.equal(singleMismatch.ordinal, firstAt, "divergence reports its first divergent ordinal")
  Assert.notNil(singleMismatch.expected, "mismatches carry the expected entry")
  Assert.notNil(singleMismatch.actual, "mismatches carry the actual entry")

  local double = copied(seen.entries)
  double[at[1]].detail.sequence = double[at[1]].detail.sequence --[[@as integer]] + 1000000
  double[at[2]].detail.sequence = double[at[2]].detail.sequence --[[@as integer]] + 1000000
  local doubleMismatch = Trace.mismatch(seen.entries, double)
  Assert.equal(doubleMismatch.ordinal, at[1], "double divergence still reports the first entry")

  Assert.isNil(Trace.mismatch(seen.entries, copied(seen.entries)), "identical entries report no mismatch")
end

-- Rejects collector misuse at the boundary: collectors carry an explicit
-- positive bound with their entry array, every recorded detail is a
-- record, bounds fail on every record kind, and length divergence
-- reports its first missing position with both sides attached.
function T.trace_collectors_reject_misuse_and_report_boundaries()
  local Trace =
    SessionFixture.requirePresent("libs.battle.src.BattleTrace", "inert mechanics diagnostics own bounded observation")
  Assert.throws(function()
    Trace.event(nil, { sequence = 1 })
  end, "missing collectors never record")
  Assert.throws(function()
    Trace.event({ bound = 0, entries = {} }, { sequence = 1 })
  end, "non-positive bounds never record")
  Assert.throws(function()
    Trace.event({ bound = 4 }, { sequence = 1 })
  end, "collectors without an entry array never record")
  Assert.throws(function()
    Trace.event({ bound = 4, entries = {} }, "not-a-record")
  end, "non-record details never record")

  local single = { bound = 1, entries = {} }
  Trace.random(single, { raw = 42, reason = "probe", ordinal = 1, cause = {} })
  Assert.equal(single.entries[1].kind, "random", "draws record under their kind")
  Assert.equal(single.entries[1].ordinal, 1, "first entries carry the first ordinal")
  Assert.throws(function()
    Trace.random(single, { raw = 43, reason = "probe", ordinal = 2, cause = {} })
  end, "over-bound draws fail instead of growing")
  Assert.throws(function()
    Trace.arithmetic(single, { name = "base", input = 80, output = 48 })
  end, "over-bound stages fail instead of growing")

  local pair = { bound = 8, entries = {} }
  Trace.event(pair, { sequence = 1 })
  Trace.event(pair, { sequence = 2 })
  Assert.equal(pair.entries[2].ordinal, 2, "later entries carry their own ordinal")

  local longer = { bound = 8, entries = {} }
  Trace.event(longer, { sequence = 1 })
  Trace.event(longer, { sequence = 2 })
  Trace.event(longer, { sequence = 3 })
  local shortfall = Trace.mismatch(longer.entries, pair.entries)
  Assert.isTrue(type(shortfall) == "table", "length divergence reports its mismatch")
  Assert.equal(shortfall.kind, "event", "length divergence keeps the entry kind")
  Assert.equal(shortfall.ordinal, 3, "length divergence reports its first missing position")
  Assert.notNil(shortfall.expected, "length divergence carries the expected entry")
  Assert.isNil(shortfall.actual, "length divergence marks the missing actual side")

  Assert.isNil(Trace.mismatch({}, {}), "empty collectors report no mismatch")
  Assert.throws(function()
    Trace.mismatch(nil, {})
  end, "mismatch reports compare two arrays")
end

return { tests = T }
