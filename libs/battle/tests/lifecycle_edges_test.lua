-- Boundaries around the battle lifecycle owners: malformed frames and
-- summaries fail loudly, refused exchanges and gate checks spend no random
-- draws, forced draws spend exactly one labeled roll, the odds boundary is
-- strict, faster combatants leave without a roll, faint records keep their
-- own cause copies, and open settlements repeat their replacement request
-- without emitting twice.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleErrors = require("libs.battle.src.errors")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

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

-- Unknown reserves fail as invalid input before anything moves: no arrival
-- is named and the battle stream is untouched.
function T.start_rejects_unknown_reserves_as_input_without_drawing()
  local Switching = SessionFixture.requirePresent(
    "libs.battle.src.gen4.Switching",
    "the source exchange continuation owns switch sequencing"
  )
  local stream = BattleRng.new(287454020)
  local snapshot = stream:capture()
  local failure = Assert.throws(function()
    Switching.start({
      position = 1,
      outgoing = { combatant = 1, activation = 7 },
      incoming = 9,
      reason = "voluntary",
      trap = { held = false },
      reserves = { 2, 3 },
      stream = stream,
    })
  end)
  Assert.isTrue(type(failure) == "table" and failure.code == BattleErrors.INPUT, "unknown reserves fail as input")
  Assert.deepEqual(stream:capture(), snapshot, "the refused exchange draws nothing")
end

-- Forced replacement without a named arrival spends exactly one labeled
-- roll and lands on an eligible reserve.
function T.forced_draw_spends_exactly_one_labeled_roll()
  local Switching = SessionFixture.requirePresent(
    "libs.battle.src.gen4.Switching",
    "the source exchange continuation owns switch sequencing"
  )
  local stream = scriptedStream({ 41 })
  local frame = Switching.validateFrame(Switching.start({
    position = 1,
    outgoing = { combatant = 1, activation = 7 },
    reason = "forced",
    trap = { held = false },
    reserves = { 2, 3, 4 },
    fainted = { 2 },
    stream = stream,
  }))
  Assert.isTrue(frame.incoming == 3 or frame.incoming == 4, "the forced pick lands on an eligible reserve")
  Assert.deepEqual(stream:capture(), { used = 1 }, "the forced pick spends exactly one roll")
  Assert.isTrue(type(stream.seen.label) == "string" and stream.seen.label ~= "", "forced draws carry their label")
end

-- Forced replacement with every reserve fainted fails as invalid input
-- instead of naming a knocked-out arrival.
function T.forced_replacement_with_no_eligible_reserve_fails()
  local Switching = SessionFixture.requirePresent(
    "libs.battle.src.gen4.Switching",
    "the source exchange continuation owns switch sequencing"
  )
  local failure = Assert.throws(function()
    Switching.start({
      position = 1,
      outgoing = { combatant = 1, activation = 7 },
      reason = "forced",
      trap = { held = false },
      reserves = { 2, 3 },
      fainted = { 2, 3 },
      stream = BattleRng.new(287454020),
    })
  end)
  Assert.isTrue(type(failure) == "table" and failure.code == BattleErrors.INPUT, "a reserveless forced pick fails")
end

-- Malformed exchange frames fail validation: unknown reasons, missing
-- arrivals, and voluntary flags that disagree with the reason.
function T.validateFrame_rejects_malformed_exchange_frames()
  local Switching = SessionFixture.requirePresent(
    "libs.battle.src.gen4.Switching",
    "the source exchange continuation owns switch sequencing"
  )
  local valid = {
    position = 1,
    outgoing = { combatant = 1, activation = 7 },
    incoming = 2,
    reason = "voluntary",
    voluntary = true,
    activation = 8,
    cursor = "start",
    transferredEffects = {},
  }
  Switching.validateFrame(valid)
  Assert.throws(function()
    Switching.validateFrame({ position = 1 })
  end, "a bare record is not an exchange frame")
  local mismatch = {}
  for key, value in pairs(valid) do
    mismatch[key] = value
  end
  mismatch.voluntary = false
  Assert.throws(function()
    Switching.validateFrame(mismatch)
  end, "the voluntary flag follows the reason")
  local unknown = {}
  for key, value in pairs(valid) do
    unknown[key] = value
  end
  unknown.reason = "retreat"
  unknown.voluntary = false
  Assert.throws(function()
    Switching.validateFrame(unknown)
  end, "exchange reasons stay closed")
end

-- The shift prompt accepts only the exchange choice through the decision
-- protocol; other choice kinds are rejected as invalid input.
function T.shift_prompt_rejects_non_exchange_choices()
  local Protocol = SessionFixture.requirePresent(
    "libs.battle.src.BattleProtocol",
    "the typed decision protocol owns prompt vocabulary"
  )
  Assert.isTrue(Protocol.isDecisionKind("shift"), "the shift prompt vocabulary exists")
  local failure = Assert.throws(function()
    Protocol.validateChoice(
      { actor = { combatant = 1 }, kind = "attack", payload = { moveSlot = 0, target = { kind = "none" } } },
      "shift"
    )
  end)
  Assert.isTrue(type(failure) == "table" and failure.code == BattleErrors.INPUT, "strikes miss the shift prompt")
end

-- Malformed faint reports fail loudly: missing entry tokens and
-- non-positive ordinals never reach the queue.
function T.detect_rejects_malformed_faint_reports()
  local Fainting = SessionFixture.requirePresent("libs.battle.src.gen4.Fainting", "the native faint queue owns settlement")
  Assert.throws(function()
    Fainting.detect({}, { combatant = 1 }, { kind = "damage" }, 1)
  end, "reports pin their entry token")
  Assert.throws(function()
    Fainting.detect({}, { combatant = 1, activation = 7 }, { kind = "damage" }, 0)
  end, "reports order by positive ordinal")
  local queue = {}
  Fainting.detect(queue, { combatant = 1, activation = 7 }, { kind = "damage" }, 1)
  Assert.equal(#queue, 1, "valid reports still queue")
end

-- Queued faint records keep their own cause copy: later caller mutations
-- never rewrite the queued report.
function T.detect_keeps_its_own_cause_copy()
  local Fainting = SessionFixture.requirePresent("libs.battle.src.gen4.Fainting", "the native faint queue owns settlement")
  local queue = {}
  local cause = { kind = "damage", actionId = 3 }
  Fainting.detect(queue, { combatant = 1, activation = 7 }, cause, 1)
  cause.kind = "residual"
  Assert.equal(queue[1].cause.kind, "damage", "the queued report keeps the reported cause")
end

-- Settlement completes without a progression hook: every knockout still
-- emits exactly once and settled records are marked processed.
function T.settlement_completes_without_a_progression_hook()
  local Fainting = SessionFixture.requirePresent("libs.battle.src.gen4.Fainting", "the native faint queue owns settlement")
  local queue = {}
  Fainting.detect(queue, { combatant = 1, activation = 7 }, { kind = "damage" }, 1)
  local outcome = Fainting.step({ queue = queue }, Fainting.validateFrame({ kind = "faint", cursor = "start" }))
  Assert.isTrue(outcome.done, "a hookless settlement with no reserves waiting completes")
  Assert.equal(#outcome.events, 1, "the knockout still emits exactly once")
  Assert.isTrue(queue[1].processed, "the settled record is marked processed")
end

-- An open settlement repeats its replacement request without emitting
-- twice: re-stepping with reserves still waiting answers the same request
-- and adds no new faint events.
function T.open_settlement_repeats_its_replacement_request_without_emitting_twice()
  local Fainting = SessionFixture.requirePresent("libs.battle.src.gen4.Fainting", "the native faint queue owns settlement")
  local queue = {}
  Fainting.detect(queue, { combatant = 1, activation = 7 }, { kind = "damage" }, 1)
  local context = {
    queue = queue,
    reserves = { 5 },
    progress = function(_)
      return { kind = "progressed" }
    end,
  }
  local first = Fainting.step(context, Fainting.validateFrame({ kind = "faint", cursor = "start" }))
  Assert.isFalse(first.done, "a settlement with reserves waiting stays open")
  local request = first.needsReplacement
  Assert.notNil(request, "the open settlement names its replacement")
  local second = Fainting.step(context, first.frame)
  Assert.isFalse(second.done, "the settlement stays open while reserves wait")
  Assert.equal(second.needsReplacement, request, "the repeated step names the same replacement")
  Assert.equal(#second.events, 0, "the repeated step emits no new faint")
end

-- Outstanding replacements withhold capture and flight alike: no terminal
-- outcome escapes before replacement resolves.
function T.replacements_withhold_capture_and_flight()
  local OutcomePolicy = SessionFixture.requirePresent(
    "libs.battle.src.gen4.OutcomePolicy",
    "the terminal result selector owns result gates"
  )
  local kept = OutcomePolicy.evaluate({
    sides = { { id = 1, standing = 1, fled = false }, { id = 2, standing = 1, fled = false } },
    pendingReplacements = 1,
    captured = { 4 },
  })
  Assert.isNil(kept, "an outstanding replacement withholds capture")
  local fled = OutcomePolicy.evaluate({
    sides = { { id = 1, standing = 1, fled = true }, { id = 2, standing = 1, fled = false } },
    pendingReplacements = 2,
    captured = {},
  })
  Assert.isNil(fled, "outstanding replacements withhold flight")
end

-- A kept combatant selects capture even beside a fled side, and malformed
-- summaries fail instead of naming a result.
function T.capture_outranks_flight_and_malformed_summaries_fail()
  local OutcomePolicy = SessionFixture.requirePresent(
    "libs.battle.src.gen4.OutcomePolicy",
    "the terminal result selector owns result gates"
  )
  local kept = OutcomePolicy.evaluate({
    sides = { { id = 1, standing = 1, fled = true }, { id = 2, standing = 1, fled = false } },
    pendingReplacements = 0,
    captured = { 4 },
  })
  Assert.notNil(kept, "a kept combatant names its result")
  Assert.equal(kept.reason, "capture", "capture outranks flight")
  Assert.throws(function()
    OutcomePolicy.evaluate({ pendingReplacements = 0, captured = {} })
  end, "result selection reads side standings")
end

-- The odds boundary is strict: a roll equal to the odds fails while the
-- next lower roll escapes, each spending exactly one roll.
function T.equal_rolls_fail_the_strict_odds_boundary()
  local Escape = SessionFixture.requirePresent("libs.battle.src.gen4.Escape", "run, trap, and flee mechanics own leaving")
  ---@param draw integer scripted roll under test
  ---@return table flight outcome over the boundary odds of 64
  local function attemptAt(draw)
    return Escape.attempt({
      battleKind = "wild",
      trapped = false,
      guaranteed = false,
      attempts = 0,
      speeds = { player = 64, enemy = 128 },
      stream = scriptedStream({ draw }),
    })
  end
  local failed = attemptAt(64)
  Assert.isFalse(failed.escaped, "a roll equal to the odds fails")
  Assert.equal(failed.attempts, 1, "the boundary failure records its attempt")
  local escaped = attemptAt(63)
  Assert.isTrue(escaped.escaped, "the next lower roll escapes")
  Assert.equal(escaped.attempts, 0, "a successful run leaves the counter alone")
end

-- Faster combatants leave outright: no roll is spent and no attempt is
-- recorded.
function T.faster_combatants_leave_without_a_roll()
  local Escape = SessionFixture.requirePresent("libs.battle.src.gen4.Escape", "run, trap, and flee mechanics own leaving")
  local stream = scriptedStream({ 250 })
  local outcome = Escape.attempt({
    battleKind = "wild",
    trapped = false,
    guaranteed = false,
    attempts = 0,
    speeds = { player = 100, enemy = 10 },
    stream = stream,
  })
  Assert.isTrue(outcome.escaped, "the faster combatant leaves outright")
  Assert.equal(outcome.attempts, 0, "the outright exit records no attempt")
  Assert.deepEqual(stream:capture(), { used = 0 }, "the outright exit spends no roll")
end

-- The flight gate refuses trapped runs and trainer battles while free wild
-- runs stay permitted.
function T.flight_gate_refuses_trapped_and_trainer_runs()
  local Escape = SessionFixture.requirePresent("libs.battle.src.gen4.Escape", "run, trap, and flee mechanics own leaving")
  local trapped = Escape.canRun({ battleKind = "wild", trapped = true, guaranteed = false, attempts = 0 })
  Assert.isFalse(trapped.ok, "a trapped combatant cannot run")
  local trainer = Escape.canRun({ battleKind = "trainer", trapped = false, guaranteed = false, attempts = 0 })
  Assert.isFalse(trainer.ok, "trainer battles refuse flight")
  Assert.notNil(trainer.reason, "the refusal names its reason")
  local free = Escape.canRun({ battleKind = "wild", trapped = false, guaranteed = false, attempts = 0 })
  Assert.isTrue(free.ok, "a free wild run stays permitted")
end

-- Pending faints suspend the schedule under any operation budget without
-- touching queued actions; an empty queue with nothing pending stays quiet.
function T.pending_faints_suspend_under_any_operation_budget()
  local HgssSchedule = SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSchedule",
    "the native schedule owns interruption boundaries"
  )
  for _, budget in ipairs({ 1, 64 }) do
    local queue = { { id = 1, progress = "queued" } }
    local frame = {
      kind = HgssSchedule.KIND,
      version = HgssSchedule.VERSION,
      cursor = "execution",
      pendingFaints = { 2 },
    }
    local due = HgssSchedule.step(queue, frame, BattleRng.new(287454020), budget)
    Assert.isNil(due, "pending faints suspend the schedule at budget " .. tostring(budget))
    Assert.equal(queue[1].progress, "queued", "suspended actions stay queued at budget " .. tostring(budget))
  end
  local drained = HgssSchedule.step(
    {},
    { kind = HgssSchedule.KIND, version = HgssSchedule.VERSION, cursor = "execution", pendingFaints = {} },
    BattleRng.new(287454020),
    64
  )
  Assert.isNil(drained, "an empty queue with nothing pending stays quiet")
end

return { tests = T }
