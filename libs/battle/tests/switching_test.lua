-- Voluntary and forced exchanges run as an interruptible continuation:
-- eligibility and trapping gate the exchange before anything moves, the
-- departing entry keeps its identity while the arrival mints a fresh one,
-- only the declared subset travels, entry consequences settle before the
-- parent action resumes or cancels exactly once, reserves shared across
-- positions are never double-booked, and pending faints suspend the parent
-- continuation until replacement resolves.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local BattleErrors = require("libs.battle.src.errors")

local T = {}

local FIXED_SEED = 287454020

---@param behavior string missing owner under test
---@return table the loaded exchange-continuation owner
local function switchingOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Switching", behavior)
end

---@return table battle stream over fixed random state
local function fixedStream()
  return BattleRng.new(FIXED_SEED)
end

---@param overrides table<string, unknown>|nil field replacements for this seed
---@return table seed record for a voluntary exchange
local function voluntarySeed(overrides)
  local seed = {
    position = 1,
    outgoing = { combatant = 1, activation = 7 },
    incoming = 2,
    reason = "voluntary",
    trap = { held = false },
    reserves = { 2, 3 },
    stream = fixedStream(),
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      seed[key] = value
    end
  end
  return seed
end

---@param query table eligibility query under test
---@return table the eligibility verdict
local function checkEligible(query)
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  return Switching.eligible(query)
end

-- The voluntary exchange keeps the departing identity intact, allocates a
-- fresh entry token for the arrival, and stays plain data throughout.
function T.voluntary_exchange_keeps_outgoing_identity_and_mints_a_fresh_entry()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  Assert.isTrue(type(Switching.start) == "function", "the exchange owner starts continuations")
  Assert.isTrue(type(Switching.step) == "function", "the exchange owner steps continuations")
  Assert.isTrue(type(Switching.eligible) == "function", "the exchange owner judges eligibility")
  Assert.isTrue(type(Switching.validateFrame) == "function", "the exchange owner validates frames")
  local verdict = Switching.eligible({
    position = 1,
    incoming = 2,
    reason = "voluntary",
    trap = { held = false },
    reserves = { 2, 3 },
  })
  Assert.isTrue(verdict.ok, "a free exchange into a listed reserve is eligible")
  local frame = Switching.validateFrame(Switching.start(voluntarySeed()))
  Assert.equal(frame.position, 1, "the frame stays pinned to its position")
  Assert.equal(frame.outgoing.combatant, 1, "the departing combatant is captured")
  Assert.equal(frame.outgoing.activation, 7, "the departing entry token is captured")
  Assert.equal(frame.incoming, 2, "the frame names its arrival")
  Assert.equal(frame.reason, "voluntary", "the frame keeps its reason")
  Assert.isTrue(frame.voluntary, "only the voluntary reason counts as a voluntary exchange")
  Assert.isTrue(
    type(frame.activation) == "number" and frame.activation ~= 7,
    "the arrival mints a fresh entry token"
  )
  Assert.isTrue(type(frame.cursor) == "string" and frame.cursor ~= "", "the continuation names its cursor")
  SessionFixture.assertPlainData(frame, "frame")
end

-- A trapped departure is rejected as invalid input before anything moves:
-- no transfer, no entry token, and no random draw.
function T.trapped_departures_fail_as_input_without_touching_state()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local stream = fixedStream()
  local snapshot = stream:capture()
  local verdict = Switching.eligible({
    position = 1,
    incoming = 2,
    reason = "voluntary",
    trap = { held = true },
    reserves = { 2, 3 },
  })
  Assert.isFalse(verdict.ok, "a trapped departure is ineligible")
  Assert.notNil(verdict.reason, "the refusal names its reason")
  local failure = Assert.throws(function()
    Switching.start(voluntarySeed({ trap = { held = true }, stream = stream }))
  end)
  Assert.isTrue(
    type(failure) == "table" and failure.code == BattleErrors.INPUT,
    "a trapped departure fails as invalid input"
  )
  Assert.deepEqual(stream:capture(), snapshot, "the refused exchange draws nothing")
end

-- Forced replacement draws only from eligible reserves, repeats exactly
-- under fixed random state, and never counts as voluntary.
function T.forced_replacement_draws_only_eligible_reserves()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local refused = Switching.eligible({
    position = 1,
    incoming = 2,
    reason = "forced",
    trap = { held = false },
    reserves = { 2, 3, 4 },
    fainted = { 2 },
  })
  Assert.isFalse(refused.ok, "fainted reserves stay ineligible for forced replacement")
  ---@return table frame started from fixed random state
  local function forcedStart()
    return Switching.start({
      position = 1,
      outgoing = { combatant = 1, activation = 7 },
      reason = "forced",
      trap = { held = false },
      reserves = { 2, 3, 4 },
      fainted = { 2 },
      stream = fixedStream(),
    })
  end
  local first = Switching.validateFrame(forcedStart())
  local second = Switching.validateFrame(forcedStart())
  Assert.equal(first.incoming, second.incoming, "fixed random state repeats the forced pick")
  Assert.isTrue(
    first.incoming == 3 or first.incoming == 4,
    "the forced pick lands on an eligible reserve"
  )
  Assert.isFalse(first.voluntary, "forced replacement is not a voluntary exchange")
end

-- Only the declared subset travels with the exchange; everything else is
-- left behind and named as such on the settled frame.
function T.only_the_declared_subset_travels()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local frame = Switching.validateFrame(Switching.start(voluntarySeed({
    reason = "baton_pass",
    transfer = { "focus" },
    effects = { focus = { stages = 2 }, guard = { turns = 3 } },
  })))
  Assert.equal(frame.reason, "baton_pass", "the frame keeps its exchange reason")
  Assert.deepEqual(frame.transferredEffects, { "focus" }, "exactly the declared subset travels")
  Assert.isFalse(frame.voluntary, "a relayed exchange is not a voluntary exchange")
end

-- A pursuit-style departure still answers at its interception checkpoint:
-- the exchange waits while hit consequences are unsettled, then the parent
-- action resumes or cancels exactly once.
function T.departing_exchanges_wait_for_hit_consequences_then_answer_once()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local frame = Switching.validateFrame(Switching.start(voluntarySeed({
    reason = "u_turn",
    parentAction = 9,
    hitConsequences = "pending",
  })))
  local blocked = Switching.step({ stream = fixedStream(), hitConsequences = "pending" }, frame)
  Assert.isFalse(blocked.done, "the exchange waits while hit consequences are unsettled")
  Assert.isNil(blocked.parentResume, "no parent answer escapes before the exchange completes")
  SessionFixture.assertPlainData(blocked.frame, "frame")
  local settled = Switching.step({ stream = fixedStream(), hitConsequences = "settled" }, blocked.frame)
  Assert.isTrue(settled.done, "the exchange completes once hit consequences settle")
  Assert.isTrue(
    settled.parentResume == "resume" or settled.parentResume == "cancel",
    "the parent action resumes or cancels exactly once"
  )
  local repeated = Switching.step({ stream = fixedStream(), hitConsequences = "settled" }, settled.frame)
  Assert.isTrue(repeated.done, "a settled exchange stays settled")
  local answers = 0
  for _, outcome in ipairs({ settled, repeated }) do
    if outcome.parentResume ~= nil then
      answers = answers + 1
    end
  end
  Assert.equal(answers, 1, "the parent action answers exactly once across repeated steps")
end

-- Entry consequences settle before the parent action resumes: when hazards
-- fell the arrival, the frame asks for another replacement first and the
-- parent answer stays withheld.
function T.entry_consequences_settle_before_the_parent_action_resumes()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local frame = Switching.validateFrame(Switching.start(voluntarySeed({ parentAction = 9 })))
  local outcome = Switching.step({ stream = fixedStream(), entry = { damageToIncoming = 999 } }, frame)
  Assert.notNil(outcome.needsReplacement, "the felled arrival requests another replacement first")
  Assert.isNil(outcome.parentResume, "the parent answer waits behind the replacement")
  local followed = Switching.step(
    { stream = fixedStream(), entry = { damageToIncoming = 0 }, replacement = 3 },
    outcome.frame
  )
  Assert.isTrue(followed.done, "the supplied replacement completes the exchange")
  Assert.notNil(followed.parentResume, "the parent answers once the exchange completes")
end

-- Reserves shared across positions are never double-booked: once a
-- replacement is promised to one position, sibling requests for the same
-- reserve are refused until it is released, and valid choices settle by
-- decision order rather than arrival order.
function T.shared_reserves_are_never_double_booked()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local first = Switching.validateFrame(Switching.start({
    position = 1,
    outgoing = { combatant = 1, activation = 7 },
    incoming = 5,
    reason = "faint",
    trap = { held = false },
    reserves = { 5, 6 },
    reserved = {},
    stream = fixedStream(),
  }))
  Assert.equal(first.incoming, 5, "the first decided replacement holds its reserve")
  local conflict = checkEligible({
    position = 2,
    incoming = 5,
    reason = "faint",
    trap = { held = false },
    reserves = { 5, 6 },
    reserved = { 5 },
  })
  Assert.isFalse(conflict.ok, "a promised reserve is refused to sibling positions")
  Assert.notNil(conflict.reason, "the refusal names the reservation conflict")
  local alternative = checkEligible({
    position = 2,
    incoming = 6,
    reason = "faint",
    trap = { held = false },
    reserves = { 5, 6 },
    reserved = { 5 },
  })
  Assert.isTrue(alternative.ok, "an unreserved sibling reserve stays eligible")
  local second = Switching.validateFrame(Switching.start({
    position = 2,
    outgoing = { combatant = 4, activation = 3 },
    incoming = 6,
    reason = "faint",
    trap = { held = false },
    reserves = { 5, 6 },
    reserved = { 5 },
    stream = fixedStream(),
  }))
  Assert.isTrue(first.incoming ~= second.incoming, "simultaneous replacements arrive distinctly")
  local late = checkEligible({
    position = 2,
    incoming = 5,
    reason = "faint",
    trap = { held = false },
    reserves = { 5, 6 },
    reserved = {},
  })
  Assert.isTrue(late.ok, "a released reserve becomes eligible again")
end

-- Faint settlement suspends the parent continuation: with faints waiting,
-- no queued action is due until replacement resolves.
function T.pending_faints_suspend_the_parent_continuation()
  local HgssSchedule = SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSchedule",
    "the native schedule owns interruption boundaries"
  )
  local queue = { { id = 1, progress = "queued" } }
  local frame = {
    kind = HgssSchedule.KIND,
    version = HgssSchedule.VERSION,
    cursor = "execution",
    pendingFaints = { 2 },
  }
  HgssSchedule.validateFrame(frame)
  local due = HgssSchedule.step(queue, frame, fixedStream(), 64)
  Assert.isNil(due, "a pending faint suspends the parent action until replacement resolves")
  Assert.equal(queue[1].progress, "queued", "suspended actions stay queued")
end

-- With nothing pending, queued actions still drain in order through the
-- same schedule step.
function T.queued_actions_drain_when_nothing_is_pending()
  local HgssSchedule = SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSchedule",
    "the native schedule owns interruption boundaries"
  )
  local queue = { { id = 1, progress = "queued" } }
  local frame = {
    kind = HgssSchedule.KIND,
    version = HgssSchedule.VERSION,
    cursor = "execution",
    pendingFaints = {},
  }
  local due = HgssSchedule.step(queue, frame, fixedStream(), 64)
  Assert.notNil(due, "an unblocked schedule still yields its queued action")
  Assert.equal(due.id, 1, "the due action is the queued one")
end

return { tests = T }
