-- Leaving battle is gated law, not a shortcut: trapping holds the
-- combatant without spending the odds roll, guaranteed conditions leave
-- without rolling, trainer refusal is a failed action that ends nothing,
-- failed wild odds record exactly one attempt per spent roll with improving
-- odds afterwards, and forced exits record which side left for the result
-- selector.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded run-and-trap owner
local function escapeOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Escape", behavior)
end

---@param values integer[] scripted draw results in consumption order
---@return table stream double with labeled-draw accounting
local function scriptedStream(values)
  local used = 0
  local seen = {}
  return {
    nextU16 = function(self, label, cause)
      assert(self ~= nil, "draws arrive through the stream")
      seen.label = label
      seen.cause = cause
      used = used + 1
      return values[used] or 0
    end,
    capture = function()
      return { used = used }
    end,
    seen = seen,
  }
end

---@param overrides table<string, unknown>|nil field replacements for this attempt
---@return table wild attempt inputs over a fresh fixed stream
local function wildAttempt(overrides)
  local attempt = {
    battleKind = "wild",
    trapped = false,
    guaranteed = false,
    attempts = 0,
    speeds = { player = 10, enemy = 100 },
    stream = scriptedStream({ 250 }),
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      attempt[key] = value
    end
  end
  return attempt
end

-- A trapped run fails before any roll: the stream is untouched, the attempt
-- counter is untouched, and the reason names the trap.
function T.trapped_runs_fail_before_any_roll()
  local Escape = escapeOwner("run, trap, and flee mechanics own leaving battle")
  Assert.isTrue(type(Escape.canRun) == "function", "the escape owner judges flight")
  Assert.isTrue(type(Escape.attempt) == "function", "the escape owner attempts flight")
  Assert.isTrue(type(Escape.forceExit) == "function", "the escape owner forces exits")
  local gate = Escape.canRun({ battleKind = "wild", trapped = true, guaranteed = false, attempts = 0 })
  Assert.isFalse(gate.ok, "a trapped combatant cannot run")
  Assert.notNil(gate.reason, "the refusal names its reason")
  local stream = scriptedStream({ 250 })
  local outcome = Escape.attempt({
    battleKind = "wild",
    trapped = true,
    guaranteed = false,
    attempts = 0,
    speeds = { player = 10, enemy = 100 },
    stream = stream,
  })
  Assert.isFalse(outcome.escaped, "a trapped run never escapes")
  Assert.equal(outcome.reason, "trapped", "a trapped run names the trap")
  Assert.equal(outcome.attempts, 0, "a trapped run records no attempt")
  Assert.deepEqual(stream:capture(), { used = 0 }, "a trapped run spends no roll")
end

-- Guaranteed conditions leave without a roll: the stream is untouched and
-- the attempt counter is untouched.
function T.guaranteed_conditions_leave_without_a_roll()
  local Escape = escapeOwner("run, trap, and flee mechanics own leaving battle")
  local stream = scriptedStream({ 250 })
  local outcome = Escape.attempt({
    battleKind = "wild",
    trapped = false,
    guaranteed = true,
    attempts = 0,
    speeds = { player = 10, enemy = 100 },
    stream = stream,
  })
  Assert.isTrue(outcome.escaped, "a guaranteed run always escapes")
  Assert.deepEqual(stream:capture(), { used = 0 }, "a guaranteed run spends no roll")
  Assert.equal(outcome.attempts, 0, "a guaranteed run records no attempt")
end

-- Trainer refusal is a failed action, not an ending: no roll is spent, no
-- attempt is recorded, and the result selector stays silent afterwards.
function T.trainer_refusal_consumes_no_roll_and_ends_nothing()
  local Escape = escapeOwner("run, trap, and flee mechanics own leaving battle")
  local OutcomePolicy = SessionFixture.requirePresent(
    "libs.battle.src.gen4.OutcomePolicy",
    "the terminal result selector owns result gates"
  )
  local stream = scriptedStream({ 250 })
  local outcome = Escape.attempt({
    battleKind = "trainer",
    trapped = false,
    guaranteed = false,
    attempts = 0,
    speeds = { player = 100, enemy = 10 },
    stream = stream,
  })
  Assert.isFalse(outcome.escaped, "there is no running from a trainer battle")
  Assert.equal(outcome.reason, "refused", "trainer refusal keeps its own reason")
  Assert.equal(outcome.attempts, 0, "trainer refusal never advances the wild attempt counter")
  Assert.deepEqual(stream:capture(), { used = 0 }, "trainer refusal spends no roll")
  local result = OutcomePolicy.evaluate({
    sides = {
      { id = 1, standing = 1, fled = false },
      { id = 2, standing = 1, fled = false },
    },
    pendingReplacements = 0,
    captured = {},
  })
  Assert.isNil(result, "a refused run ends nothing")
end

-- Failed wild odds record exactly one attempt per spent roll: the counter
-- advances by one, the stream advances by one labeled draw, and the reason
-- names the odds.
function T.failed_wild_odds_record_the_attempt_and_spend_one_roll()
  local Escape = escapeOwner("run, trap, and flee mechanics own leaving battle")
  local stream = scriptedStream({ 250 })
  local outcome = Escape.attempt(wildAttempt({ stream = stream }))
  Assert.isFalse(outcome.escaped, "the scripted slow run fails its odds")
  Assert.equal(outcome.reason, "odds", "a failed wild run names the odds")
  Assert.equal(outcome.attempts, 1, "a failed wild run records exactly one attempt")
  Assert.deepEqual(stream:capture(), { used = 1 }, "a failed wild run spends exactly one roll")
  Assert.isTrue(
    type(stream.seen.label) == "string" and stream.seen.label ~= "",
    "escape rolls carry their call-site label"
  )
end

-- Later attempts run better odds: with the counter advanced, the same
-- scripted draw that once failed now escapes.
function T.improving_odds_apply_on_later_attempts()
  local Escape = escapeOwner("run, trap, and flee mechanics own leaving battle")
  local early = Escape.attempt(wildAttempt({ attempts = 0, stream = scriptedStream({ 200 }) }))
  Assert.isFalse(early.escaped, "the early attempt fails its odds")
  local late = Escape.attempt(wildAttempt({ attempts = 7, stream = scriptedStream({ 200 }) }))
  Assert.isTrue(late.escaped, "the same draw escapes once attempts have improved the odds")
  Assert.equal(late.attempts, 7, "a successful run leaves the counter alone")
end

-- Forced exits record which side left: the wild side's flight reaches the
-- result selector as flight with that side losing and no winner's honors.
function T.forced_exits_record_which_side_left()
  local Escape = escapeOwner("run, trap, and flee mechanics own leaving battle")
  local OutcomePolicy = SessionFixture.requirePresent(
    "libs.battle.src.gen4.OutcomePolicy",
    "the terminal result selector owns result gates"
  )
  local exit = Escape.forceExit({ side = 2, cause = "fled" })
  Assert.equal(exit.fledSide, 2, "the forced exit records which side left")
  local result = OutcomePolicy.evaluate({
    sides = {
      { id = 1, standing = 1, fled = false },
      { id = 2, standing = 1, fled = true },
    },
    pendingReplacements = 0,
    captured = {},
  })
  Assert.notNil(result, "a fled side names its result")
  Assert.equal(result.reason, "flee", "a forced wild exit selects flight, never victory")
  Assert.deepEqual(result.losingSides, { 2 }, "the result names the side that left")
end

return { tests = T }
