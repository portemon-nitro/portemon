-- Native action ordering: priority brackets dominate speed, faster combatants
-- move first inside a bracket, reversed dimensions invert only the speed
-- comparison, and equal speeds resolve deterministically from the recorded
-- selection order and the battle stream. Sampling freezes each action's
-- ordering facts, so later mutations and input array positions never reorder
-- already built actions.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param id integer stable action identity
---@param ordinal integer selection order recorded when the action was chosen
---@param kind string action class under test
---@param priority integer move priority bracket
---@param speed integer effective speed already folding outside adjustments
---@return table ordering candidate in plain data
local function candidate(id, ordinal, kind, priority, speed)
  return {
    id = id,
    actor = { combatant = id, activation = 1 },
    kind = kind,
    payload = {},
    selectedOrdinal = ordinal,
    priority = priority,
    speed = speed,
  }
end

---@param TurnOrder table native ordering owner under test
---@param BattleRng table labeled stream owner under test
---@param candidates table[] ordering candidates in an arbitrary array order
---@param trickRoom boolean whether the speed dimension is reversed
---@param seed integer fixed stream seed for tie resolution
---@return table[] built actions in execution order
---@return table stream snapshot after building
local function build(TurnOrder, BattleRng, candidates, trickRoom, seed)
  local stream = BattleRng.new(seed)
  local ordered = TurnOrder.buildActions(candidates, { trickRoom = trickRoom }, stream)
  return ordered, stream:capture()
end

---@param ordered table[] built actions in execution order
---@return integer[] action identities in execution order
local function orderIds(ordered)
  local ids = {}
  for index, action in ipairs(ordered) do
    ids[index] = action.id
  end
  return ids
end

---@param ordered table[] built actions or entries in execution order
---@return integer[] sorted member identities for completeness checks
local function memberIds(ordered)
  local ids = orderIds(ordered)
  table.sort(ids)
  return ids
end

function T.priority_speed_and_ties_follow_recorded_selection_order()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "recorded traversal owns turn and action ordering")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  Assert.isTrue(type(TurnOrder.buildActions) == "function", "ordering builds executable actions")
  Assert.isTrue(type(TurnOrder.orderResiduals) == "function", "ordering owns residual sequencing")
  Assert.isTrue(type(TurnOrder.orderEntryEffects) == "function", "ordering owns entry sequencing")

  local bracket = build(TurnOrder, BattleRng, {
    candidate(1, 1, "attack", 1, 50),
    candidate(2, 2, "attack", 0, 220),
    candidate(3, 3, "attack", -1, 300),
  }, false, 7)
  Assert.deepEqual(orderIds(bracket), { 1, 2, 3 }, "higher priority brackets move first at any speed")

  local swifts = build(TurnOrder, BattleRng, {
    candidate(4, 1, "attack", 0, 90),
    candidate(5, 2, "attack", 0, 110),
  }, false, 7)
  Assert.deepEqual(orderIds(swifts), { 5, 4 }, "faster combatants move first inside a bracket")

  local reversed = build(TurnOrder, BattleRng, {
    candidate(4, 1, "attack", 0, 90),
    candidate(5, 2, "attack", 0, 110),
  }, true, 7)
  Assert.deepEqual(orderIds(reversed), { 4, 5 }, "reversed dimensions move slower combatants first")

  local first, firstCalls = build(TurnOrder, BattleRng, {
    candidate(6, 1, "attack", 0, 100),
    candidate(7, 2, "attack", 0, 100),
    candidate(8, 3, "attack", 0, 80),
  }, false, 7)
  local second, secondCalls = build(TurnOrder, BattleRng, {
    candidate(8, 3, "attack", 0, 80),
    candidate(7, 2, "attack", 0, 100),
    candidate(6, 1, "attack", 0, 100),
  }, false, 7)
  Assert.deepEqual(orderIds(second), orderIds(first), "input array positions never decide vanilla order")
  Assert.deepEqual(secondCalls, firstCalls, "input array positions never change stream use")

  local tiedIds = orderIds(first)
  Assert.equal(#tiedIds, 3, "ties keep every action")
  Assert.equal(tiedIds[3], 8, "strictly slower combatants stay last under ties")
  local third, thirdCalls = build(TurnOrder, BattleRng, {
    candidate(6, 1, "attack", 0, 100),
    candidate(7, 2, "attack", 0, 100),
    candidate(8, 3, "attack", 0, 80),
  }, false, 7)
  Assert.deepEqual(orderIds(third), tiedIds, "same seed and selection order rebuild identically")
  Assert.deepEqual(thirdCalls, firstCalls, "rebuilds consume the stream identically")
  Assert.isTrue(firstCalls.calls > 0, "tied comparisons draw rather than sorting silently")

  local mutable = {
    candidate(4, 1, "attack", 0, 90),
    candidate(5, 2, "attack", 0, 110),
  }
  local frozen = build(TurnOrder, BattleRng, mutable, false, 7)
  mutable[1].speed = 500
  mutable[2].speed = 10
  Assert.deepEqual(orderIds(frozen), { 5, 4 }, "built actions ignore later speed mutations")
  Assert.equal(frozen[1].selectedOrdinal, 2, "built actions keep their selection order")
  Assert.equal(frozen[2].selectedOrdinal, 1, "built actions keep their selection order")
  Assert.equal(frozen[1].progress, "queued", "built actions wait queued")
  for _, action in ipairs(frozen) do
    Assert.notNil(action.sampledOrder, "built actions carry their sampled ordering facts")
  end
  Assert.equal(frozen[1].sampledOrder.speed, 110, "ordering facts record the sampled point")
  Assert.equal(frozen[2].sampledOrder.speed, 90, "ordering facts record the sampled point")

  local stream = BattleRng.new(11)
  local residuals = TurnOrder.orderResiduals({
    { id = 1, speed = 100 },
    { id = 2, speed = 120 },
  }, { trickRoom = false }, stream)
  Assert.deepEqual(memberIds(residuals), { 1, 2 }, "residual sequencing keeps every entry")
  local again = TurnOrder.orderResiduals({
    { id = 1, speed = 100 },
    { id = 2, speed = 120 },
  }, { trickRoom = false }, BattleRng.new(11))
  Assert.deepEqual(orderIds(again), orderIds(residuals), "residual sequencing rebuilds identically")
  local entries = TurnOrder.orderEntryEffects({
    { id = 1, speed = 100 },
    { id = 2, speed = 120 },
  }, { trickRoom = false }, BattleRng.new(11))
  Assert.deepEqual(memberIds(entries), { 1, 2 }, "entry sequencing keeps every entry")
  local entriesAgain = TurnOrder.orderEntryEffects({
    { id = 1, speed = 100 },
    { id = 2, speed = 120 },
  }, { trickRoom = false }, BattleRng.new(11))
  Assert.deepEqual(orderIds(entriesAgain), orderIds(entries), "entry sequencing rebuilds identically")
end

function T.malformed_candidates_fail_without_consuming_draws()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "recorded traversal owns turn and action ordering")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local stream = BattleRng.new(7)
  local empty = TurnOrder.buildActions({}, { trickRoom = false }, stream)
  Assert.deepEqual(empty, {}, "empty selections order nothing")
  Assert.equal(stream:capture().calls, 0, "empty selections draw nothing")

  local nameless = candidate(1, 1, "attack", 0, 100)
  nameless.kind = ""
  Assert.throws(function()
    TurnOrder.buildActions({ nameless }, { trickRoom = false }, stream)
  end, "candidates name their action class")
  local priorityless = candidate(1, 1, "attack", 0, 100)
  priorityless.priority = nil
  Assert.throws(function()
    TurnOrder.buildActions({ priorityless }, { trickRoom = false }, stream)
  end, "candidates carry their priority")
  local dimensionless = candidate(1, 1, "attack", 0, 100)
  Assert.throws(function()
    TurnOrder.buildActions({ dimensionless }, {}, stream)
  end, "ordering names its speed dimension")
  Assert.throws(function()
    TurnOrder.buildActions({ candidate(1, 1, "attack", 0, 100) }, { trickRoom = false }, {})
  end, "ordering draws ties from the battle stream")
  Assert.throws(function()
    TurnOrder.orderResiduals({ { id = 1 } }, { trickRoom = false }, stream)
  end, "sequenced entries sample their speed")
  Assert.throws(function()
    TurnOrder.orderEntryEffects({ { id = 1, speed = 100 } }, {}, stream)
  end, "entry sequencing names its speed dimension")
  Assert.equal(stream:capture().calls, 0, "rejected orderings never reach the stream")

  local fresh = TurnOrder.buildActions({ candidate(1, 1, "attack", 0, 100) }, { trickRoom = false }, stream)
  Assert.equal(#fresh, 1, "single candidates order alone")
  Assert.isNil(fresh[1].parentActionId, "fresh actions carry no parent linkage")
  Assert.equal(fresh[1].progress, "queued", "fresh actions wait queued")
end

return { tests = T }
