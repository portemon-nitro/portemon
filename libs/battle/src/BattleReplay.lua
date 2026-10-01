-- Strict executable battle replay envelopes. An envelope binds its recorded
-- scenario, submitted decisions, external deterministic inputs, controller
-- draw stream, expected events, and expected outcome to one executable
-- identity (engine build, ruleset, content revision, stream algorithm, and
-- seed) under a versioned schema. Exact simulation replay rebuilds a
-- session from the recorded scenario, resubmits the recorded replies in
-- order under the requested operation budget, and compares the re-executed
-- events, outcome, and kernel stream against the recording, reporting the
-- first divergence with both sides attached. Reading the recorded event
-- log back is presentation only and never simulates. The scripted decision
-- point executes entirely in the session kernel, so replay resolves the
-- recorded ruleset through a minimal resolver unless the caller passes its
-- frozen content; recorded controller intents travel with their recorded
-- draw stream instead of being silently skipped. Recording never alters
-- mechanics: capture only copies already-recorded data.

local BattleErrors = require("libs.battle.src.errors")
local BattleScenario = require("libs.battle.src.BattleScenario")
local BattleSession = require("libs.battle.src.BattleSession")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local U32 = require("libs.codec.src.U32")

---@class BattleExecutionIdentity
---@field engineBuild string executable build under recording
---@field ruleset string decision vocabulary under recording
---@field format string? topology identity under recording
---@field contentRevision string mechanical content revision under recording
---@field randomAlgorithm string generator identity under recording
---@field seed integer unsigned 32-bit seed under recording

---@class RecordedDecision
---@field requestId integer open request the reply answered
---@field epoch integer batch epoch the reply answered
---@field controller string decision producer owning the reply
---@field choices table<integer, table<string, unknown>> one choice per addressed actor

---@class RecordedExternalInput
---@field kind string deterministic input kind outside decisions and draws

---@class RandomTraceEntry
---@field raw integer recorded draw value
---@field reason string call-site label of the recorded draw
---@field ordinal integer one-based position in the draw stream
---@field cause table<string, unknown> semantic reason that ordered the draw

---@class BattleRandomTrace
---@field controllerDraws table<integer, table<string, unknown>> controller draws in call order
---@field kernelBoundaryRng table<string, integer> kernel stream position at the first decision boundary
---@field kernelFinalRng table<string, integer> kernel stream position at the recorded outcome

---@class BattleReplayEnvelope
---@field schema string versioned envelope schema
---@field identity BattleExecutionIdentity pinned executable identity
---@field scenario table<string, unknown> detached scenario under recording
---@field decisions table<integer, table<string, unknown>> submitted replies in order
---@field externalInputs table<integer, table<string, unknown>> external deterministic inputs in order
---@field randomTrace BattleRandomTrace recorded draw streams and kernel positions
---@field expectedEvents table<integer, table<string, unknown>> recorded events in sequence order
---@field expectedOutcome table<string, unknown> recorded terminal outcome
---@field seal string integrity binding over the recorded inputs

---@class ReplayMismatch
---@field kind string divergence boundary: identity, state, event, random, or arithmetic
---@field ordinal integer? position of the first divergence
---@field phase string? semantic phase of the first divergence
---@field expected table<string, unknown>? expected value at the divergence
---@field actual table<string, unknown>? actual value at the divergence

---@class BattleReplay
local BattleReplay = {}

BattleReplay.SCHEMA = "portemon-battle-replay-v1"

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local input = value --[[@as table<unknown, unknown>]]
  local out = {}
  for key, item in pairs(input) do
    out[key] = copyValue(item)
  end
  return out
end

---@param value unknown
---@param active table<table, boolean> tables on the current traversal path
local function checkPlain(value, active)
  local kind = type(value)
  if kind == "function" or kind == "thread" or kind == "userdata" then
    error(BattleErrors.incompatibleSnapshot("battle replays carry plain data only", { kind = kind }))
  end
  if kind ~= "table" then
    return
  end
  local node = value --[[@as table<unknown, unknown>]]
  if active[node] == true then
    error(BattleErrors.incompatibleSnapshot("battle replays must not loop back on themselves", {}))
  end
  active[node] = true
  for key, item in pairs(node) do
    checkPlain(key, active)
    checkPlain(item, active)
  end
  active[node] = nil
end

---@param value unknown
---@param what string value under inspection
---@return table<integer, unknown> the ordered array
local function checkArray(value, what)
  if type(value) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays carry " .. what .. " as an ordered array", {}))
  end
  local array = value --[[@as table<integer, unknown>]]
  for index = 1, #array do
    if array[index] == nil then
      error(
        BattleErrors.incompatibleSnapshot("battle replays must not skip " .. what .. " positions", { index = index })
      )
    end
  end
  return array
end

---@param want unknown expected side under comparison
---@param got unknown actual side under comparison
---@param active table<string, boolean> traversal keys on the current path
---@return boolean true when both sides match structurally
local function valuesEqual(want, got, active)
  if type(want) ~= type(got) then
    return false
  end
  if type(want) ~= "table" then
    return want == got
  end
  local key = tostring(want) .. "/" .. tostring(got)
  if active[key] == true then
    return true
  end
  active[key] = true
  local expected = want --[[@as table<unknown, unknown>]]
  local actual = got --[[@as table<unknown, unknown>]]
  for field, value in pairs(expected) do
    if not valuesEqual(value, actual[field], active) then
      return false
    end
  end
  for field in pairs(actual) do
    if expected[field] == nil then
      return false
    end
  end
  active[key] = nil
  return true
end

---@param want unknown
---@param got unknown
---@return boolean true when both sides match structurally
local function deepEqual(want, got)
  return valuesEqual(want, got, {})
end

---@param value unknown
---@param parts string[] canonical encoding under construction
local function encodeCanonical(value, parts)
  local kind = type(value)
  if kind == "nil" then
    parts[#parts + 1] = "0"
  elseif kind == "boolean" then
    parts[#parts + 1] = value and "t" or "f"
  elseif kind == "number" then
    assert(value == value, "replay records carry no NaN")
    parts[#parts + 1] = "n:" .. tostring(value)
  elseif kind == "string" then
    local text = value --[[@as string]]
    parts[#parts + 1] = "s" .. #text .. ":" .. text
  elseif kind == "table" then
    local record = value --[[@as table<unknown, unknown>]]
    local keys = {}
    for key in pairs(record) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      if type(a) ~= type(b) then
        return type(a) < type(b)
      end
      return tostring(a) < tostring(b)
    end)
    parts[#parts + 1] = "{"
    for _, key in ipairs(keys) do
      encodeCanonical(key, parts)
      parts[#parts + 1] = "="
      encodeCanonical(record[key], parts)
      parts[#parts + 1] = ";"
    end
    parts[#parts + 1] = "}"
  else
    error(BattleErrors.incompatibleSnapshot("battle replays seal plain data only", { kind = kind }))
  end
end

---@param a integer byte under mixing
---@param b integer byte under mixing
---@return integer the mixed byte
local function mixByte(a, b)
  local out = 0
  local bit = 1
  for _ = 1, 8 do
    if (a % 2) ~= (b % 2) then
      out = out + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return out
end

---@param text string canonical encoding under digest
---@return string eight hex digits binding the encoding
local function sealDigest(text)
  local hash = 2166136261
  for index = 1, #text do
    local low = hash % 256
    hash = U32.mul(hash - low + mixByte(low, string.byte(text, index)), 16777619)
  end
  return string.format("%08x", hash)
end

---@param identity table<string, unknown> executable identity under recording
---@param scenario table<string, unknown> scenario under recording
---@param decisions table<integer, unknown> submitted replies under recording
---@param externalInputs table<integer, unknown> external inputs under recording
---@return string integrity binding over the recorded inputs
local function sealFor(identity, scenario, decisions, externalInputs)
  local parts = {}
  encodeCanonical({
    identity = identity,
    scenario = scenario,
    decisions = decisions,
    externalInputs = externalInputs,
  }, parts)
  return sealDigest(table.concat(parts))
end

---@param identity unknown executable identity under inspection
local function checkIdentity(identity)
  if type(identity) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays pin their executable identity", {}))
  end
  local record = identity --[[@as table<string, unknown>]]
  for _, field in ipairs({ "engineBuild", "ruleset", "contentRevision", "randomAlgorithm" }) do
    if type(record[field]) ~= "string" or record[field] == "" then
      error(BattleErrors.incompatibleSnapshot("replay identities name their " .. field, { field = field }))
    end
  end
  if record.format ~= nil and (type(record.format) ~= "string" or record.format == "") then
    error(BattleErrors.incompatibleSnapshot("replay identities name their format", {}))
  end
  local seed = record.seed
  if type(seed) ~= "number" or seed ~= seed or seed % 1 ~= 0 or seed < 0 or seed > U32.MAX then
    error(BattleErrors.incompatibleSnapshot("replay identities carry an unsigned 32-bit seed", {}))
  end
end

---@param reply unknown recorded reply under inspection
---@param index integer position in the decision order
local function checkDecision(reply, index)
  if type(reply) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("replay decisions must be records", { index = index }))
  end
  local record = reply --[[@as table<string, unknown>]]
  if type(record.requestId) ~= "number" or type(record.epoch) ~= "number" then
    error(BattleErrors.incompatibleSnapshot("replay decisions carry their request identity", { index = index }))
  end
  if type(record.controller) ~= "string" or record.controller == "" then
    error(BattleErrors.incompatibleSnapshot("replay decisions name their controller", { index = index }))
  end
  checkArray(record.choices, "decision choices")
end

---@param trace unknown recorded draw stream under inspection
local function checkRandomTrace(trace)
  if type(trace) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays carry their recorded draw stream", {}))
  end
  local record = trace --[[@as table<string, unknown>]]
  checkArray(record.controllerDraws, "controller draws")
  for _, field in ipairs({ "kernelBoundaryRng", "kernelFinalRng" }) do
    Lcrng.validate(record[field])
  end
end

--- Records one battle under its executable identity. The recording is
--- copied field by field and sealed; malformed records, foreign schemas,
--- and live host values fail here before anything publishes.
---@param recording table<string, unknown> identity, scenario, decisions, inputs, draws, events, and outcome
---@return BattleReplayEnvelope the sealed versioned replay envelope
function BattleReplay.capture(recording)
  if type(recording) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays capture a recording record", {}))
  end
  checkPlain(recording, {})
  checkIdentity(recording.identity)
  local scenario = BattleScenario.validate(recording.scenario)
  local decisions = checkArray(recording.decisions, "recorded decisions")
  for index, reply in ipairs(decisions) do
    checkDecision(reply, index)
  end
  local externalInputs = checkArray(recording.externalInputs, "external inputs")
  checkRandomTrace(recording.randomTrace)
  local expectedEvents = checkArray(recording.expectedEvents, "expected events")
  if type(recording.expectedOutcome) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays carry their expected outcome", {}))
  end
  local identity = copyValue(recording.identity) --[[@as table<string, unknown>]]
  local envelope = {
    schema = BattleReplay.SCHEMA,
    identity = identity,
    scenario = scenario,
    decisions = copyValue(decisions),
    externalInputs = copyValue(externalInputs),
    randomTrace = copyValue(recording.randomTrace),
    expectedEvents = copyValue(expectedEvents),
    expectedOutcome = copyValue(recording.expectedOutcome),
  }
  envelope.seal = sealFor(identity, envelope.scenario, envelope.decisions, envelope.externalInputs)
  return envelope --[[@as BattleReplayEnvelope]]
end

---@param envelope unknown replay envelope under inspection
---@return table<string, unknown> the pinned executable identity
local function checkEnvelope(envelope)
  if type(envelope) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays must be records", {}))
  end
  local record = envelope --[[@as table<string, unknown>]]
  if record.schema ~= BattleReplay.SCHEMA then
    error(BattleErrors.incompatibleSnapshot("battle replays carry the current envelope schema", {}))
  end
  if type(record.identity) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays pin their executable identity", {}))
  end
  if type(record.scenario) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays carry their scenario", {}))
  end
  checkArray(record.decisions, "recorded decisions")
  checkArray(record.externalInputs, "external inputs")
  if type(record.randomTrace) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays carry their recorded draw stream", {}))
  end
  checkArray(record.expectedEvents, "expected events")
  if type(record.expectedOutcome) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle replays carry their expected outcome", {}))
  end
  if type(record.seal) ~= "string" or record.seal == "" then
    error(BattleErrors.incompatibleSnapshot("battle replays carry their integrity binding", {}))
  end
  return record.identity --[[@as table<string, unknown>]]
end

--- Checks an envelope against the caller's current executable identity.
--- Every pinned field must match exactly; unknown or mismatching identity
--- throws instead of replaying under changed rules.
---@param envelope table<string, unknown> replay envelope under checking
---@param current table<string, unknown> executable identity the caller runs under
---@return boolean true when the envelope replays exactly under the caller identity
function BattleReplay.validateIdentity(envelope, current)
  local identity = checkEnvelope(envelope)
  if type(current) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("replay identity checks compare two identity records", {}))
  end
  for key, value in pairs(current) do
    if not deepEqual(identity[key], value) then
      error(BattleErrors.incompatibleSnapshot("replay executables must match their recorded " .. tostring(key), {
        field = tostring(key),
      }))
    end
  end
  for key in pairs(identity) do
    if current[key] == nil then
      error(BattleErrors.incompatibleSnapshot("replay envelopes carry no unknown identity fields", {
        field = tostring(key),
      }))
    end
  end
  return true
end

---@return table<string, unknown> empty ruleset binding for kernel-owned decision points
local function resolveAnyRuleset()
  return {}
end

---@return table<string, unknown> minimal ruleset resolver for kernel-owned decision points
local function defaultContent()
  return { ruleset = resolveAnyRuleset }
end

---@param event unknown event side under kind lookup
---@return string the event kind, or unknown when unnamed
local function eventKind(event)
  if type(event) == "table" then
    local record = event --[[@as table<string, unknown>]]
    if type(record.kind) == "string" then
      return record.kind --[[@as string]]
    end
  end
  return "unknown"
end

--- Re-executes an envelope through the session kernel and compares the
--- outcome against the recording. Returns the re-executed events, outcome,
--- and draw stream with a nil mismatch on exact replay, or the first
--- divergence (identity, event, outcome, or kernel-stream) with both sides
--- attached. Operation budgets never change the comparison.
---@param envelope table<string, unknown> sealed replay envelope under replay
---@param opts { budget: integer?, content: table<string, unknown>? }? replay budget and frozen content
---@return { events: table<integer, table<string, unknown>>, outcome: table<string, unknown>?, randomTrace: BattleRandomTrace, mismatch: ReplayMismatch? }
function BattleReplay.replay(envelope, opts)
  local options = opts or {}
  local budget = options.budget or 1024
  assert(
    type(budget) == "number" and budget --[[@as integer]] % 1 == 0 and budget --[[@as integer]] >= 1,
    "replay budgets stay positive integers"
  )
  local identity = checkEnvelope(envelope)
  local record = envelope --[[@as table<string, unknown>]]
  local recomputed = sealFor(
    identity,
    record.scenario,
    record.decisions --[[@as table<integer, unknown>]],
    record.externalInputs --[[@as table<integer, unknown>]]
  )
  if recomputed ~= record.seal then
    return {
      events = copyValue(record.expectedEvents),
      outcome = copyValue(record.expectedOutcome),
      randomTrace = copyValue(record.randomTrace),
      mismatch = {
        kind = "identity",
        phase = "identity",
        expected = { seal = record.seal },
        actual = { seal = recomputed },
      },
    }
  end
  local content = options.content or defaultContent()
  local session = BattleSession.new(copyValue(record.scenario), content --[[@as table<string, unknown>]])
  local decisions = record.decisions --[[@as table<integer, table<string, unknown>>]]
  local expectedEvents = record.expectedEvents --[[@as table<integer, table<string, unknown>>]]
  local cursor = 0
  local events = {} ---@type table<integer, table<string, unknown>>
  local boundaryRng = nil ---@type table<string, integer>?
  local outcome = nil ---@type table<string, unknown>?
  local mismatch = nil ---@type ReplayMismatch?
  for _ = 1, 4096 do
    local frame = session:advance(budget --[[@as integer]])
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        events[#events + 1] = event
      end
    end
    if frame.status == "ended" then
      outcome = frame.outcome
      break
    end
    if frame.status == "waiting" then
      if boundaryRng == nil then
        boundaryRng = copyValue(session:capture().rng) --[[@as table<string, integer>]]
      end
      assert(frame.request ~= nil, "waiting replays carry their decision batch")
      for _, request in ipairs(frame.request.requests) do
        cursor = cursor + 1
        local reply = decisions[cursor]
        if type(reply) ~= "table" or reply.requestId ~= request.requestId or reply.controller ~= request.controller then
          mismatch = {
            kind = "state",
            ordinal = cursor,
            phase = "decisions",
            expected = {
              requestId = (type(reply) == "table" and reply.requestId or nil),
              controller = (type(reply) == "table" and reply.controller or nil),
            },
            actual = { requestId = request.requestId, controller = request.controller },
          }
          break
        end
        local ok, err = session:submit(reply)
        if not ok then
          mismatch = {
            kind = "state",
            ordinal = cursor,
            phase = "submit",
            expected = copyValue(reply),
            actual = copyValue(err),
          }
          break
        end
      end
      if mismatch ~= nil then
        break
      end
    end
  end
  local finalRng = copyValue(session:capture().rng) --[[@as table<string, integer>]]
  session:dispose()
  if outcome == nil and mismatch == nil then
    error(BattleErrors.invalidState("replays end at their recorded outcome", {}))
  end
  local randomTrace = {
    controllerDraws = copyValue((record.randomTrace --[[@as table<string, unknown>]]).controllerDraws),
    kernelBoundaryRng = boundaryRng or copyValue(finalRng),
    kernelFinalRng = finalRng,
  }
  if mismatch == nil then
    local count = math.max(#events, #expectedEvents)
    for ordinal = 1, count do
      local want = expectedEvents[ordinal]
      local got = events[ordinal]
      if not deepEqual(want, got) then
        mismatch = {
          kind = "event",
          ordinal = ordinal,
          phase = eventKind(want ~= nil and want or got),
          expected = copyValue(want),
          actual = copyValue(got),
        }
        break
      end
    end
  end
  if mismatch == nil and not deepEqual(outcome, record.expectedOutcome) then
    mismatch = {
      kind = "state",
      phase = "outcome",
      expected = copyValue(record.expectedOutcome),
      actual = copyValue(outcome),
    }
  end
  if mismatch == nil then
    local expectedTrace = record.randomTrace --[[@as table<string, unknown>]]
    for _, field in ipairs({ "kernelBoundaryRng", "kernelFinalRng" }) do
      if not deepEqual(randomTrace[field], expectedTrace[field]) then
        mismatch = {
          kind = "random",
          phase = "kernel-stream",
          expected = copyValue(expectedTrace[field]),
          actual = copyValue(randomTrace[field]),
        }
        break
      end
    end
  end
  return {
    events = events,
    outcome = outcome,
    randomTrace = randomTrace --[[@as BattleRandomTrace]],
    mismatch = mismatch,
  }
end

--- Reads the recorded event log back without simulating. The returned
--- array is detached: mutating it never touches the envelope.
---@param envelope table<string, unknown> sealed replay envelope under playback
---@return table<integer, table<string, unknown>> detached copy of the recorded events
function BattleReplay.playbackEvents(envelope)
  checkEnvelope(envelope)
  local record = envelope --[[@as table<string, unknown>]]
  return copyValue(record.expectedEvents) --[[@as table<integer, table<string, unknown>>]]
end

return BattleReplay
