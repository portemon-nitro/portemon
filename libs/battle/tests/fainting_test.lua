-- Faint settlement is a source-ordered queue drained before any terminal
-- outcome: each entry queues exactly once per entry token, settlement
-- follows detection order with each knockout progressed once, replacements
-- resolve before any result is named, and the terminal result is selected
-- from standings rather than raw health, keeping victory, draw, flight,
-- and capture reasons distinct.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded faint-settlement owner
local function faintingOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Fainting", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded terminal-result owner
local function outcomeOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.OutcomePolicy", behavior)
end

---@param combatant integer roster identity under test
---@param activation integer entry token under test
---@return table combatant reference pinned to one entry
local function target(combatant, activation)
  return { combatant = combatant, activation = activation }
end

---@param sides table[] side standings under test
---@param pending integer replacements still unresolved
---@param captured integer[] combatants kept through capture
---@return table settlement summary without any health readout
local function summary(sides, pending, captured)
  return { sides = sides, pendingReplacements = pending, captured = captured }
end

---@param id integer side identity under test
---@param standing integer combatants on that side still able to continue
---@return table side standing record
local function standing(id, standing)
  return { id = id, standing = standing, fled = false }
end

-- Each fainted entry queues exactly once: repeat reports for the same entry
-- token are absorbed, while a fresh entry token for the same combatant
-- queues again.
function T.each_fainted_entry_queues_exactly_once()
  local Fainting = faintingOwner("the native faint queue owns settlement order")
  Assert.isTrue(type(Fainting.detect) == "function", "the faint owner detects knockouts")
  Assert.isTrue(type(Fainting.step) == "function", "the faint owner steps settlement")
  Assert.isTrue(type(Fainting.validateFrame) == "function", "the faint owner validates frames")
  local queue = {}
  Fainting.detect(queue, target(1, 7), { kind = "damage", actionId = 3 }, 1)
  Assert.equal(#queue, 1, "the first report queues the entry")
  Fainting.detect(queue, target(1, 7), { kind = "damage", actionId = 3 }, 1)
  Assert.equal(#queue, 1, "a repeat report for the same entry token is absorbed")
  Fainting.detect(queue, target(1, 9), { kind = "residual", actionId = 4 }, 2)
  Assert.equal(#queue, 2, "a fresh entry token for the same combatant queues again")
  Fainting.detect(queue, target(2, 1), { kind = "damage", actionId = 3 }, 3)
  Assert.equal(#queue, 3, "a second combatant queues beside the first")
  Assert.isFalse(queue[1].processed, "queued records start unprocessed")
end

-- Settlement follows detection order and progresses each knockout exactly
-- once: faint events name entries in ordinal sequence, the progression hook
-- fires once per record, and re-stepping emits nothing new.
function T.settlement_follows_detection_order_and_progresses_each_ko_once()
  local Fainting = faintingOwner("the native faint queue owns settlement order")
  local queue = {}
  Fainting.detect(queue, target(2, 1), { kind = "residual", actionId = 4 }, 2)
  Fainting.detect(queue, target(1, 7), { kind = "damage", actionId = 3 }, 1)
  local progressed = {}
  local context = {
    queue = queue,
    progress = function(record)
      progressed[#progressed + 1] = record.target.combatant
      return { kind = "progressed", combatant = record.target.combatant }
    end,
  }
  local frame = Fainting.validateFrame({ kind = "faint", cursor = "start" })
  SessionFixture.assertPlainData(frame, "frame")
  local outcome = Fainting.step(context, frame)
  Assert.isTrue(outcome.done, "a fully supplied settlement completes")
  Assert.equal(#outcome.events, 2, "each queued knockout emits exactly one faint")
  Assert.equal(outcome.events[1].combatant, 1, "the earlier detection settles first")
  Assert.equal(outcome.events[2].combatant, 2, "the later detection settles second")
  Assert.deepEqual(progressed, { 1, 2 }, "each knockout is progressed exactly once in order")
  for _, record in ipairs(queue) do
    Assert.isTrue(record.processed, "settled records are marked processed")
  end
  local repeated = Fainting.step(context, outcome.frame)
  Assert.isTrue(repeated.done, "a drained settlement stays done")
  Assert.equal(#repeated.events, 0, "re-stepping a drained settlement emits nothing new")
end

-- Replacements resolve before any terminal outcome is named: while a
-- replacement is outstanding the result selector stays silent, and the
-- faint step asks for the replacement instead of finishing.
function T.replacements_come_before_any_terminal_outcome()
  local Fainting = faintingOwner("the native faint queue owns settlement order")
  local OutcomePolicy = outcomeOwner("the terminal result selector owns result gates")
  Assert.isTrue(type(OutcomePolicy.evaluate) == "function", "the result selector evaluates settlements")
  local gated = OutcomePolicy.evaluate(summary({ standing(1, 0), standing(2, 1) }, 1, {}))
  Assert.isNil(gated, "an outstanding replacement withholds every terminal outcome")
  local queue = {}
  Fainting.detect(queue, target(1, 7), { kind = "damage", actionId = 3 }, 1)
  local progressed = 0
  local outcome = Fainting.step({
    queue = queue,
    reserves = { 5 },
    progress = function(_)
      progressed = progressed + 1
      return { kind = "progressed" }
    end,
  }, Fainting.validateFrame({ kind = "faint", cursor = "start" }))
  Assert.isFalse(outcome.done, "a settlement with reserves waiting stays open")
  Assert.notNil(outcome.needsReplacement, "the open settlement names its replacement")
  Assert.equal(progressed, 1, "the knockout is still progressed exactly once")
end

-- A mutual knockout names both sides without extra work: both faints emit,
-- the queue drains, and the result carries both sides as losing with no
-- winner.
function T.mutual_knockout_names_both_sides_without_extra_work()
  local Fainting = faintingOwner("the native faint queue owns settlement order")
  local OutcomePolicy = outcomeOwner("the terminal result selector owns result gates")
  local queue = {}
  Fainting.detect(queue, target(1, 7), { kind = "damage", actionId = 3 }, 1)
  Fainting.detect(queue, target(2, 1), { kind = "damage", actionId = 3 }, 2)
  local outcome = Fainting.step({
    queue = queue,
    reserves = {},
    progress = function(_)
      return { kind = "progressed" }
    end,
  }, Fainting.validateFrame({ kind = "faint", cursor = "start" }))
  Assert.isTrue(outcome.done, "a reserveless mutual knockout drains fully")
  Assert.equal(#outcome.events, 2, "both faints emit before any result is named")
  local result = OutcomePolicy.evaluate(summary({ standing(1, 0), standing(2, 0) }, 0, {}))
  Assert.notNil(result, "a drained mutual knockout names its result")
  Assert.equal(result.reason, "draw", "a mutual knockout is a draw")
  Assert.deepEqual(result.winningSides, {}, "a draw names no winner")
  Assert.deepEqual(result.losingSides, { 1, 2 }, "a draw names both sides as losing")
end

-- Victory is selected from standings, never from raw health: the summary
-- carries no health readout at all, yet the surviving side is named.
function T.victory_is_selected_from_standings_never_raw_health()
  local OutcomePolicy = outcomeOwner("the terminal result selector owns result gates")
  local ongoing = OutcomePolicy.evaluate(summary({ standing(1, 2), standing(2, 1) }, 0, {}))
  Assert.isNil(ongoing, "two standing sides name no terminal outcome")
  local result = OutcomePolicy.evaluate(summary({ standing(1, 0), standing(2, 2) }, 0, {}))
  Assert.notNil(result, "a one-sided wipe names its result")
  Assert.equal(result.reason, "victory", "the surviving side wins")
  Assert.deepEqual(result.winningSides, { 2 }, "the result names the surviving side")
  Assert.deepEqual(result.losingSides, { 1 }, "the result names the wiped side")
end

-- Flight and capture reasons stay distinct from victory: a fled side loses
-- without a winner's honors, and kept combatants travel on the result.
function T.flight_and_capture_reasons_stay_distinct_from_victory()
  local OutcomePolicy = outcomeOwner("the terminal result selector owns result gates")
  local fled = OutcomePolicy.evaluate({
    sides = {
      { id = 1, standing = 1, fled = true },
      { id = 2, standing = 1, fled = false },
    },
    pendingReplacements = 0,
    captured = {},
  })
  Assert.notNil(fled, "a fled side names its result")
  Assert.equal(fled.reason, "flee", "flight keeps its own reason")
  Assert.deepEqual(fled.losingSides, { 1 }, "the result names the side that left")
  local kept = OutcomePolicy.evaluate(summary({ standing(1, 1), standing(2, 1) }, 0, { 4 }))
  Assert.notNil(kept, "a kept combatant names its result")
  Assert.equal(kept.reason, "capture", "capture keeps its own reason")
  Assert.deepEqual(kept.captured, { 4 }, "the result preserves the kept combatant identity")
end

-- Result records carry exactly their documented keys so no numeric outcome
-- code or field mutation leaks through the selector.
function T.result_records_carry_exact_keys()
  local OutcomePolicy = outcomeOwner("the terminal result selector owns result gates")
  local result = OutcomePolicy.evaluate(summary({ standing(1, 0), standing(2, 2) }, 0, {}))
  Assert.notNil(result, "a decided settlement yields a record")
  Assert.keySet(result, "captured,losingSides,reason,winningSides", "results carry exactly their keys")
  Assert.isTrue(
    result.nativeOutcome == nil or type(result.nativeOutcome) == "string",
    "numeric outcome codes stay host-owned"
  )
end

return { tests = T }
