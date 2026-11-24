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
---@param flags table<string, boolean|string|integer>? special ordering facts under test
---@return table ordering candidate in plain data
local function candidate(id, ordinal, kind, priority, speed, flags)
  local record = {
    id = id,
    actor = { combatant = id, activation = 1 },
    kind = kind,
    payload = {},
    selectedOrdinal = ordinal,
    priority = priority,
    speed = speed,
  }
  if flags ~= nil then
    for name, value in pairs(flags) do
      record[name] = value
    end
  end
  return record
end

---@param verdicts boolean[] scripted swap verdicts in consumption order
---@return table scripted stream recording every tie label
local function scriptedStream(verdicts)
  local stream = { _calls = 0, _labels = {} } ---@type table<string, unknown>
  function stream.nextU16(self, label, cause)
    assert(type(label) == "string" and label ~= "", "tie draws name their call site")
    assert(type(cause) == "table", "tie draws carry their semantic cause")
    local inner = self --[[@as table<string, unknown>]]
    local calls = inner._calls --[[@as integer]] + 1
    inner._calls = calls
    local labels = inner._labels --[[@as string[] ]]
    labels[#labels + 1] = label
    local verdict = verdicts[calls]
    assert(verdict ~= nil, "scripted tie draws cover every comparison")
    if verdict == true then
      return 1
    end
    return 0
  end
  function stream.capture(self)
    local inner = self --[[@as table<string, unknown>]]
    return { calls = inner._calls, labels = inner._labels }
  end
  return stream
end

---@param ids integer[] initial identities in selection order
---@param verdicts boolean[] swap verdicts per nested comparison
---@return integer[] expected order after the nested pairwise comparison sequence
local function pairwiseReference(ids, verdicts)
  local ordered = {}
  for _, id in ipairs(ids) do
    ordered[#ordered + 1] = id
  end
  local used = 0
  for i = 1, #ordered - 1 do
    for j = i + 1, #ordered do
      used = used + 1
      assert(verdicts[used] ~= nil, "reference draws cover every comparison")
      if verdicts[used] then
        ordered[i], ordered[j] = ordered[j], ordered[i]
      end
    end
  end
  return ordered
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
  Assert.isTrue(type(TurnOrder.orderEntrySpeed) == "function", "ordering owns the full entry speed sample")

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
  local entries = TurnOrder.orderEntrySpeed({
    { id = 1, speed = 100 },
    { id = 2, speed = 120 },
  }, { trickRoom = false }, BattleRng.new(11))
  Assert.deepEqual(memberIds(entries), { 1, 2 }, "entry sequencing keeps every entry")
  local entriesAgain = TurnOrder.orderEntrySpeed({
    { id = 1, speed = 100 },
    { id = 2, speed = 120 },
  }, { trickRoom = false }, BattleRng.new(11))
  Assert.deepEqual(orderIds(entriesAgain), orderIds(entries), "entry sequencing rebuilds identically")
end

function T.entry_speed_ties_draw_once_for_the_shared_order()
  local TurnOrder = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TurnOrder",
    "entry abilities share the native full-battler speed sample"
  )
  local stream = scriptedStream({ true })
  local entries = TurnOrder.orderEntrySpeed({
    { id = 1, speed = 100 },
    { id = 2, speed = 100 },
  }, { trickRoom = false }, stream)
  Assert.deepEqual(orderIds(entries), { 2, 1 }, "the full-set order retains its sampled tie result")
  Assert.equal(stream.capture(stream).calls, 1, "the native full-set comparison consumes one tie draw")

  local BattleRng = SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "entry ties use the battle stream")
  local sampled = BattleRng.new(19)
  TurnOrder.orderEntrySpeed({
    { id = 1, speed = 100 },
    { id = 2, speed = 100 },
  }, { trickRoom = false }, sampled)
  local expected = BattleRng.new(19)
  expected:nextU16("entry_tie", { kind = "entry_tie" })
  Assert.equal(
    sampled:nextU16("next", { kind = "next" }),
    expected:nextU16("next", { kind = "next" }),
    "the next battle value proves cross-phase comparisons advanced the stream"
  )
end

function T.battler_sort_keeps_living_slots_ahead_of_departed_and_vacant_slots()
  local TurnOrder = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TurnOrder",
    "controller slot order retains every native battler position"
  )
  local stream = scriptedStream({})
  local ordered = TurnOrder.orderSpeed({
    { id = 1, selectedOrdinal = 1, speed = 100, living = false },
    { id = 2, selectedOrdinal = 2, speed = 1, living = true },
    { id = 3, selectedOrdinal = 3, speed = 200, living = false },
    { id = 4, selectedOrdinal = 4, speed = 0, living = false },
  }, { trickRoom = false }, stream)
  Assert.deepEqual(orderIds(ordered), { 2, 3, 1, 4 }, "living slots lead while departed slots keep their Speed order")
  Assert.equal(stream:capture().calls, 0, "living-versus-departed comparisons spend no tie draws")

  local tied = scriptedStream({ true })
  local departedTie = TurnOrder.orderSpeed({
    { id = 1, selectedOrdinal = 1, speed = 100, living = false },
    { id = 2, selectedOrdinal = 2, speed = 100, living = false },
  }, { trickRoom = false }, tied)
  Assert.deepEqual(orderIds(departedTie), { 2, 1 }, "two departed equal-Speed slots retain the native tie draw")
  Assert.equal(tied:capture().calls, 1, "the departed tie consumes one source draw")
end

function T.action_and_battler_sorts_draw_independent_speed_ties()
  local TurnOrder = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TurnOrder",
    "native action and battler ordering own independent draws"
  )
  local stream = scriptedStream({ true, false })
  local battlers = TurnOrder.orderSpeed({
    { id = 1, speed = 100 },
    { id = 2, speed = 100 },
  }, { trickRoom = false }, stream)
  Assert.deepEqual(orderIds(battlers), { 2, 1 }, "the battler checkpoint keeps its own tie result")
  local actions = TurnOrder.buildActions({
    candidate(1, 1, "attack", 0, 100),
    candidate(2, 2, "attack", 0, 100),
  }, { trickRoom = false }, stream)
  Assert.deepEqual(orderIds(actions), { 1, 2 }, "the action pass may choose the opposite tied order")
  local calls = stream:capture(stream)
  Assert.equal(calls.calls, 2, "the independent native passes each spend their own tie draw")
  Assert.deepEqual(calls.labels, { "speed_tie", "speed_tie" }, "both passes use the native Speed-tie stream")
end

function T.initial_permutation_groups_source_input_categories_by_native_slot()
  local TurnOrder = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TurnOrder",
    "initial execution order follows controller input categories"
  )
  local actions = TurnOrder.buildActions({
    candidate(1, 1, "attack", 0, 100, { position = 1 }),
    candidate(2, 2, "item", 0, 1, { position = 3 }),
    candidate(3, 3, "switch", 0, 2, { position = 2 }),
    candidate(4, 4, "attack", 0, 1, { position = 4 }),
  }, { trickRoom = false }, scriptedStream({}))

  Assert.deepEqual(orderIds(actions), { 3, 2, 1, 4 }, "Pokemon and Bag selections lead in slot order before FIGHT inputs")
end

function T.pursuit_does_not_override_native_input_category_order()
  local TurnOrder = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TurnOrder",
    "Pursuit is resolved by the switch transaction rather than initial action ordering"
  )
  local actions = TurnOrder.buildActions({
    candidate(1, 1, "attack", 0, 100, { position = 1, selectedMove = "PURSUIT", targetPosition = 2 }),
    candidate(2, 2, "switch", 0, 1, { position = 2 }),
    candidate(3, 3, "item", 0, 1, { position = 3 }),
  }, { trickRoom = false }, scriptedStream({}))

  Assert.deepEqual(orderIds(actions), { 2, 3, 1 }, "native switch and item selections keep their input category order")
end

function T.different_move_priorities_place_the_action_tie_draw_only_inside_its_bracket()
  local TurnOrder = SessionFixture.requirePresent(
    "libs.battle.src.gen4.TurnOrder",
    "move priority controls when an action comparison reaches its tie draw"
  )
  local stream = scriptedStream({ false })
  local actions = TurnOrder.buildActions({
    candidate(1, 1, "attack", 1, 100),
    candidate(2, 2, "attack", 0, 100),
    candidate(3, 3, "attack", 0, 100),
  }, { trickRoom = false }, stream)
  Assert.deepEqual(orderIds(actions), { 1, 2, 3 }, "raised priority wins before the neutral tie is compared")
  Assert.equal(stream:capture(stream).calls, 1, "only the neutral same-priority pair draws")
end

function T.execution_resort_keeps_the_existing_permutation_and_compares_completed_slots()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "the native controller retains its execution permutation")
  local stream = scriptedStream({ false })
  local built = TurnOrder.buildActions({
    candidate(1, 1, "attack", 0, 100),
    candidate(2, 2, "switch", 0, 100),
    candidate(3, 3, "attack", 0, 100),
  }, { trickRoom = false }, scriptedStream({ false, false, false }))
  built[1], built[2], built[3] = built[3], built[2], built[1]
  built[2].progress = "complete"
  TurnOrder.resortExecution(built, {
    [1] = { priority = 0, speed = 100, boostedPriority = false, loweredPriority = false, stall = false },
    [2] = { priority = 0, speed = 100, boostedPriority = false, loweredPriority = false, stall = false },
    [3] = { priority = 0, speed = 100, boostedPriority = false, loweredPriority = false, stall = false },
  }, { trickRoom = false }, stream)
  Assert.deepEqual(orderIds(built), { 3, 1, 2 }, "re-sort retains the live slot permutation when the tied comparator does not swap")
  Assert.equal(stream:capture().calls, 1, "completed attack slots compare, while mixed input selections do not")
end

function T.execution_resort_places_living_slots_before_fainted_slots_before_priority()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "native re-sorts compare source slot state")
  local actions = TurnOrder.buildActions({
    candidate(1, 1, "attack", 1, 100),
    candidate(2, 2, "attack", 0, 100),
  }, { trickRoom = false }, scriptedStream({ false }))
  TurnOrder.resortExecution(actions, {
    [1] = { priority = 1, speed = 100, living = false, boostedPriority = false, loweredPriority = false, stall = false },
    [2] = { priority = 0, speed = 1, living = true, boostedPriority = false, loweredPriority = false, stall = false },
  }, { trickRoom = false }, scriptedStream({ false }))
  Assert.deepEqual(orderIds(actions), { 2, 1 }, "a living slot precedes a fainted slot despite lower move priority")
end

function T.staged_speeds_sample_through_exact_truncation()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "recorded traversal owns turn and action ordering")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local StatStages =
    SessionFixture.requirePresent("libs.battle.src.gen4.StatStages", "stage clamps and ratios own battle stat stages")
  Assert.equal(StatStages.effective(55, -6, "speed"), 13, "a fully lowered speed truncates down exactly")
  Assert.equal(StatStages.effective(55, 0, "speed"), 55, "an unstaged speed samples unchanged")
  Assert.equal(StatStages.effective(55, 6, "speed"), 220, "a fully raised speed quadruples exactly")

  local ordered = build(TurnOrder, BattleRng, {
    candidate(1, 1, "attack", 0, StatStages.effective(45, 6, "speed")),
    candidate(2, 2, "attack", 0, StatStages.effective(200, -6, "speed")),
  }, false, 7)
  Assert.deepEqual(orderIds(ordered), { 1, 2 }, "a fully raised slower base outruns a fully lowered faster base")
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
    TurnOrder.orderEntrySpeed({ { id = 1, speed = 100 } }, {}, stream)
  end, "entry sequencing names its speed dimension")
  Assert.equal(stream:capture().calls, 0, "rejected orderings never reach the stream")

  local fresh = TurnOrder.buildActions({ candidate(1, 1, "attack", 0, 100) }, { trickRoom = false }, stream)
  Assert.equal(#fresh, 1, "single candidates order alone")
  Assert.isNil(fresh[1].parentActionId, "fresh actions carry no parent linkage")
  Assert.equal(fresh[1].progress, "queued", "fresh actions wait queued")
end

function T.three_and_four_way_ties_follow_pairwise_draw_topology()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "recorded traversal owns turn and action ordering")

  local threeScript = { true, true, true }
  local threeStream = scriptedStream(threeScript)
  local three = TurnOrder.buildActions({
    candidate(3, 3, "attack", 0, 100),
    candidate(1, 1, "attack", 0, 100),
    candidate(2, 2, "attack", 0, 100),
  }, { trickRoom = false }, threeStream)
  Assert.deepEqual(orderIds(three), { 3, 2, 1 }, "three all-swap ties reverse through pairwise comparisons")
  local threeCalls = threeStream:capture()
  Assert.equal(threeCalls.calls, 3, "a three-way exact tie consumes three draws")
  Assert.deepEqual(
    threeCalls.labels,
    { "speed_tie", "speed_tie", "speed_tie" },
    "action ties draw from the labeled speed-tie stream"
  )

  local alternating = { true, false, true }
  local alternatingStream = scriptedStream(alternating)
  local mixed = TurnOrder.buildActions({
    candidate(1, 1, "attack", 0, 100),
    candidate(2, 2, "attack", 0, 100),
    candidate(3, 3, "attack", 0, 100),
  }, { trickRoom = false }, alternatingStream)
  Assert.deepEqual(
    orderIds(mixed),
    pairwiseReference({ 1, 2, 3 }, alternating),
    "alternating verdicts match the nested comparison sequence"
  )
  Assert.equal(alternatingStream:capture().calls, 3, "alternating verdicts still consume three draws")

  local fourScript = { true, true, true, true, true, true }
  local fourStream = scriptedStream(fourScript)
  local four = TurnOrder.buildActions({
    candidate(4, 4, "attack", 0, 100),
    candidate(3, 3, "attack", 0, 100),
    candidate(2, 2, "attack", 0, 100),
    candidate(1, 1, "attack", 0, 100),
  }, { trickRoom = false }, fourStream)
  Assert.deepEqual(orderIds(four), { 4, 3, 2, 1 }, "four all-swap ties reverse through pairwise comparisons")
  Assert.deepEqual(
    orderIds(four),
    pairwiseReference({ 1, 2, 3, 4 }, fourScript),
    "four-way order matches the nested comparison sequence"
  )
  Assert.equal(fourStream:capture().calls, 6, "a four-way exact tie consumes six draws")
end

function T.trick_room_reverses_only_the_plain_speed_branch()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "recorded traversal owns turn and action ordering")

  ---@param candidates table[] ordering candidates under the pair
  ---@param trickRoom boolean whether the speed dimension is reversed
  ---@return integer[] action identities in execution order
  ---@return integer tie draws consumed
  local function orderPair(candidates, trickRoom)
    local stream = scriptedStream({})
    local ordered = TurnOrder.buildActions(candidates, { trickRoom = trickRoom }, stream)
    return orderIds(ordered), stream:capture().calls
  end

  local fastFirst, fastDraws = orderPair({
    candidate(1, 1, "attack", 0, 90, { boostedPriority = true }),
    candidate(2, 2, "attack", 0, 110, { boostedPriority = true }),
  }, false)
  Assert.deepEqual(fastFirst, { 2, 1 }, "both boosted stays faster-first without reversal")
  Assert.equal(fastDraws, 0, "unequal boosted speeds draw nothing")
  local fastReversed = orderPair({
    candidate(1, 1, "attack", 0, 90, { boostedPriority = true }),
    candidate(2, 2, "attack", 0, 110, { boostedPriority = true }),
  }, true)
  Assert.deepEqual(fastReversed, { 2, 1 }, "both boosted stays faster-first under reversal")

  local slowFirst, slowDraws = orderPair({
    candidate(1, 1, "attack", 0, 90, { loweredPriority = true }),
    candidate(2, 2, "attack", 0, 110, { loweredPriority = true }),
  }, false)
  Assert.deepEqual(slowFirst, { 1, 2 }, "both lowered stays slower-first without reversal")
  Assert.equal(slowDraws, 0, "unequal lowered speeds draw nothing")
  local slowReversed = orderPair({
    candidate(1, 1, "attack", 0, 90, { loweredPriority = true }),
    candidate(2, 2, "attack", 0, 110, { loweredPriority = true }),
  }, true)
  Assert.deepEqual(slowReversed, { 1, 2 }, "both lowered stays slower-first under reversal")

  local stallFirst = orderPair({
    candidate(1, 1, "attack", 0, 90, { stall = true }),
    candidate(2, 2, "attack", 0, 110, { stall = true }),
  }, false)
  Assert.deepEqual(stallFirst, { 1, 2 }, "both stalled stays slower-first without reversal")
  local stallReversed = orderPair({
    candidate(1, 1, "attack", 0, 90, { stall = true }),
    candidate(2, 2, "attack", 0, 110, { stall = true }),
  }, true)
  Assert.deepEqual(stallReversed, { 1, 2 }, "both stalled stays slower-first under reversal")

  local plain = orderPair({
    candidate(1, 1, "attack", 0, 90),
    candidate(2, 2, "attack", 0, 110),
  }, false)
  Assert.deepEqual(plain, { 2, 1 }, "plain pairs stay faster-first without reversal")
  local plainReversed = orderPair({
    candidate(1, 1, "attack", 0, 90),
    candidate(2, 2, "attack", 0, 110),
  }, true)
  Assert.deepEqual(plainReversed, { 1, 2 }, "only plain pairs reverse under reversal")

  local boostedSlow = orderPair({
    candidate(1, 1, "attack", 0, 50, { boostedPriority = true }),
    candidate(2, 2, "attack", 0, 200),
  }, true)
  Assert.deepEqual(boostedSlow, { 1, 2 }, "one boosted action wins without consulting speed")
  local loweredSlow = orderPair({
    candidate(1, 1, "attack", 0, 50, { loweredPriority = true }),
    candidate(2, 2, "attack", 0, 200),
  }, true)
  Assert.deepEqual(loweredSlow, { 2, 1 }, "one lowered action loses without consulting reversal")
  local stalledFast = orderPair({
    candidate(1, 1, "attack", 0, 200, { stall = true }),
    candidate(2, 2, "attack", 0, 50),
  }, true)
  Assert.deepEqual(stalledFast, { 2, 1 }, "one stalled action loses without consulting reversal")

  local tiedStream = scriptedStream({ false })
  local tied = TurnOrder.buildActions({
    candidate(1, 1, "attack", 0, 100, { boostedPriority = true }),
    candidate(2, 2, "attack", 0, 100, { boostedPriority = true }),
  }, { trickRoom = true }, tiedStream)
  Assert.equal(tiedStream:capture().calls, 1, "equal boosted speeds draw exactly once")
  Assert.deepEqual(memberIds(tied), { 1, 2 }, "equal boosted ties keep every action")
end

function T.residual_and_entry_ties_follow_pairwise_topology()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "recorded traversal owns turn and action ordering")

  local residualScript = { true, true, true }
  local residualStream = scriptedStream(residualScript)
  local residuals = TurnOrder.orderResiduals({
    { id = 3, speed = 100 },
    { id = 1, speed = 100 },
    { id = 2, speed = 100 },
  }, { trickRoom = false }, residualStream)
  Assert.deepEqual(orderIds(residuals), { 3, 2, 1 }, "residual all-swap ties reverse pairwise")
  local residualCalls = residualStream:capture()
  Assert.equal(residualCalls.calls, 3, "a three-way residual tie consumes three draws")
  Assert.deepEqual(
    residualCalls.labels,
    { "residual_tie", "residual_tie", "residual_tie" },
    "residual ties draw from the labeled residual stream"
  )

  local entryStream = scriptedStream(residualScript)
  local entries = TurnOrder.orderEntrySpeed({
    { id = 1, speed = 100 },
    { id = 2, speed = 100 },
    { id = 3, speed = 100 },
  }, { trickRoom = false }, entryStream)
  Assert.deepEqual(orderIds(entries), pairwiseReference({ 1, 2, 3 }, residualScript), "entry ties match pairwise")
  local entryCalls = entryStream:capture()
  Assert.equal(entryCalls.calls, 3, "a three-way entry tie consumes three draws")
  Assert.deepEqual(
    entryCalls.labels,
    { "entry_tie", "entry_tie", "entry_tie" },
    "entry ties draw from the labeled entry stream"
  )
end

function T.malformed_special_order_facts_fail_before_any_draw()
  local TurnOrder =
    SessionFixture.requirePresent("libs.battle.src.gen4.TurnOrder", "recorded traversal owns turn and action ordering")
  local stream = scriptedStream({ true })
  local boosted = candidate(1, 1, "attack", 0, 100, { boostedPriority = "yes" })
  Assert.throws(function()
    TurnOrder.buildActions({ boosted }, { trickRoom = false }, stream)
  end, "boosted facts stay boolean")
  local lowered = candidate(1, 1, "attack", 0, 100, { loweredPriority = 1 })
  Assert.throws(function()
    TurnOrder.buildActions({ lowered }, { trickRoom = false }, stream)
  end, "lowered facts stay boolean")
  local stalled = candidate(1, 1, "attack", 0, 100, { stall = 0 })
  Assert.throws(function()
    TurnOrder.buildActions({ stalled }, { trickRoom = false }, stream)
  end, "stall facts stay boolean")
  Assert.equal(stream:capture().calls, 0, "rejected special facts never reach the stream")
end

return { tests = T }
