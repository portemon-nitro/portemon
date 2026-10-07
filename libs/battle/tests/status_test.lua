-- Native major status law: one exclusive condition per mon, exact waking and
-- action gating under a fixed battle stream, cures that remove only their
-- own condition, and replacement resets that keep the condition while
-- restarting its transient counters. The persistent vocabulary itself is
-- owned by the mon domain and guarded where these suites consume it.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local EffectFixture = require("libs.battle.tests.effect_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded major-status law owner
local function statusOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Status", behavior)
end

---@return table healthy mon record owned by the mon domain
local function freshMon()
  return SessionFixture.makeMon(23)
end

---@param seed integer fixed generator state under test
---@return table labeled battle stream under test
local function fixedStream(seed)
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  return BattleRng.new(seed)
end

-- Major conditions are exclusive: the second application fails loudly and
-- the live record keeps its first condition, health, and shape.
function T.major_conditions_are_exclusive()
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  local hpBefore = mon.condition.currentHp
  Assert.isTrue(Status.apply(mon, "poison", EffectFixture.cause(2, 1), {}), "the first condition applies")

  Assert.throws(function()
    Status.apply(mon, "burn", EffectFixture.cause(2, 1), {})
  end)
  Assert.throws(function()
    Status.apply(mon, "sleep", EffectFixture.cause(2, 1), { turns = 3 })
  end)
  Assert.deepEqual(
    mon.condition.effects,
    { { key = "poison", version = 1, state = {} } },
    "rejected applications leave the live condition unchanged"
  )
  Assert.equal(mon.condition.currentHp, hpBefore, "rejected applications never touch health")
end

-- Conditions need a living mon: application onto zero health fails and the
-- empty record stays empty.
function T.the_fainted_cannot_gain_a_condition()
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  mon.condition.currentHp = 0
  Assert.throws(function()
    Status.apply(mon, "poison", EffectFixture.cause(2, 1), {})
  end)
  Assert.deepEqual(mon.condition.effects, {}, "failed applications publish nothing")
  Assert.equal(mon.condition.currentHp, 0, "failed applications never revive")
end

-- Sleep counts down one turn per gate, blocks action while any turn
-- remains, wakes exactly at zero with an event, and survives replacement
-- with its remaining turns intact.
function T.sleep_counts_down_and_wakes()
  local Status = statusOwner("native major status law owns application and replacement resets")
  local EffectBag = SessionFixture.requirePresent(
    "libs.battle.src.EffectBag",
    "scoped effect instances own their lifetimes"
  )

  local mon = freshMon()
  Assert.isTrue(Status.apply(mon, "sleep", EffectFixture.cause(2, 1), { turns = 2 }), "sleep applies with its turns")

  local first = Status.beforeAction(mon, fixedStream(7), EffectFixture.cause(1, 1))
  Assert.isFalse(first.acts, "a sleeping combatant cannot act")
  Assert.notNil(first.event, "the blocked gate names its condition")
  Assert.equal(first.event.outcome, "blocked", "unexpired sleep blocks without waking")
  Assert.deepEqual(
    mon.condition.effects,
    { { key = "sleep", version = 1, state = { turns = 1 } } },
    "the gate consumes exactly one sleep turn"
  )

  Status.switchReset(mon, EffectBag.new(), 1, 2)
  Assert.deepEqual(
    mon.condition.effects,
    { { key = "sleep", version = 1, state = { turns = 1 } } },
    "replacement never refreshes sleep turns"
  )

  local second = Status.beforeAction(mon, fixedStream(7), EffectFixture.cause(1, 2))
  Assert.isTrue(second.acts, "the final turn wakes the combatant")
  Assert.notNil(second.event, "waking emits its event")
  Assert.equal(second.event.outcome, "woke", "the zero turn wakes instead of blocking")
  Assert.deepEqual(mon.condition.effects, {}, "waking clears the condition record")
end

-- The paralysis gate is deterministic under a fixed stream: two runs from
-- the same seed agree on action and event, and a block always carries its
-- condition event while a success carries none.
function T.paralysis_gate_is_deterministic_under_a_fixed_stream()
  local Status = statusOwner("native major status law owns application and replacement resets")

  local first = freshMon()
  local second = freshMon()
  Assert.isTrue(Status.apply(first, "paralysis", EffectFixture.cause(2, 1), {}), "paralysis applies")
  Assert.isTrue(Status.apply(second, "paralysis", EffectFixture.cause(2, 1), {}), "paralysis applies twice alike")

  local early = Status.beforeAction(first, fixedStream(7), EffectFixture.cause(1, 1))
  local replay = Status.beforeAction(second, fixedStream(7), EffectFixture.cause(1, 1))
  Assert.equal(replay.acts, early.acts, "the fixed stream gates identically on replay")
  Assert.deepEqual(replay.event, early.event, "the fixed stream reports identically on replay")
  if early.acts then
    Assert.isNil(early.event, "an unblocked gate emits nothing")
  else
    Assert.notNil(early.event, "a blocked gate names its condition")
    Assert.equal(early.event.outcome, "blocked", "paralysis blocks without ending the condition")
  end
  Assert.equal(#first.condition.effects, 1, "the gate never cures the condition it checks")
end

-- The freeze gate is deterministic under a fixed stream with the same
-- replay contract: identical seeds agree, and only a thaw clears the ice.
function T.freeze_gate_is_deterministic_under_a_fixed_stream()
  local Status = statusOwner("native major status law owns application and replacement resets")

  local first = freshMon()
  local second = freshMon()
  Assert.isTrue(Status.apply(first, "freeze", EffectFixture.cause(2, 1), {}), "freeze applies")
  Assert.isTrue(Status.apply(second, "freeze", EffectFixture.cause(2, 1), {}), "freeze applies twice alike")

  local early = Status.beforeAction(first, fixedStream(7), EffectFixture.cause(1, 1))
  local replay = Status.beforeAction(second, fixedStream(7), EffectFixture.cause(1, 1))
  Assert.equal(replay.acts, early.acts, "the fixed stream gates identically on replay")
  Assert.deepEqual(replay.event, early.event, "the fixed stream reports identically on replay")
  if early.event ~= nil and early.event.outcome == "thawed" then
    Assert.isTrue(early.acts, "thawing restores the action")
    Assert.deepEqual(first.condition.effects, {}, "thawing clears the condition record")
  else
    Assert.isFalse(early.acts, "unthawed ice still blocks")
    Assert.equal(#first.condition.effects, 1, "the gate never cures the condition it checks")
  end
end

-- A healthy combatant passes the gate untouched: no event, no draw
-- ambiguity, action allowed.
function T.healthy_combatants_pass_the_gate_untouched()
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  local stream = fixedStream(7)
  local callsBefore = stream:capture().calls
  local result = Status.beforeAction(mon, stream, EffectFixture.cause(1, 1))
  Assert.isTrue(result.acts, "health never blocks")
  Assert.isNil(result.event, "health emits no gate event")
  Assert.equal(stream:capture().calls, callsBefore, "health draws nothing from the stream")
end

-- Cures remove exactly their own condition and report whether anything was
-- cured; curing an absent condition changes nothing.
function T.cure_removes_the_matching_condition()
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  Assert.isTrue(Status.apply(mon, "burn", EffectFixture.cause(2, 1), {}), "burn applies")
  Assert.isTrue(Status.cure(mon, "burn"), "the matching cure reports its work")
  Assert.deepEqual(mon.condition.effects, {}, "the cure empties the condition record")
  Assert.isFalse(Status.cure(mon, "burn"), "curing an absent condition reports no work")
  Assert.deepEqual(mon.condition.effects, {}, "curing absence changes nothing")
end

-- Replacement keeps burn, poison, paralysis, freeze, and sleep exactly as
-- they are, but restarts the toxic counter while the toxic itself persists.
function T.switch_keeps_the_condition_and_restarts_the_toxic_count()
  local Status = statusOwner("native major status law owns application and replacement resets")
  local EffectBag = SessionFixture.requirePresent(
    "libs.battle.src.EffectBag",
    "scoped effect instances own their lifetimes"
  )

  local toxic = freshMon()
  Assert.isTrue(Status.apply(toxic, "toxic", EffectFixture.cause(2, 1), { counter = 2 }), "toxic applies mid-count")
  Status.switchReset(toxic, EffectBag.new(), 1, 2)
  Assert.deepEqual(
    toxic.condition.effects,
    { { key = "toxic", version = 1, state = { counter = 0 } } },
    "replacement restarts the toxic counter without curing"
  )

  local burned = freshMon()
  Assert.isTrue(Status.apply(burned, "burn", EffectFixture.cause(2, 1), {}), "burn applies")
  Status.switchReset(burned, EffectBag.new(), 1, 2)
  Assert.deepEqual(
    burned.condition.effects,
    { { key = "burn", version = 1, state = {} } },
    "replacement leaves burn exactly alone"
  )
end

-- Refused reapplications keep the toxic count: a second toxic and an
-- incompatible burn both fail loudly while the first toxic keeps its
-- counter and health exactly.
function T.refused_reapplications_keep_the_toxic_count()
  local Status = statusOwner("native major status law owns application and replacement resets")

  local toxic = freshMon()
  local hpBefore = toxic.condition.currentHp
  Assert.isTrue(Status.apply(toxic, "toxic", EffectFixture.cause(2, 1), { counter = 2 }), "toxic applies mid-count")
  Assert.throws(function()
    Status.apply(toxic, "toxic", EffectFixture.cause(2, 1), { counter = 5 })
  end)
  Assert.throws(function()
    Status.apply(toxic, "burn", EffectFixture.cause(2, 1), {})
  end)
  Assert.deepEqual(
    toxic.condition.effects,
    { { key = "toxic", version = 1, state = { counter = 2 } } },
    "refused applications leave the counter untouched"
  )
  Assert.equal(toxic.condition.currentHp, hpBefore, "refused applications never touch health")
end

-- The mon domain already owns the persistent vocabulary: battle-transient
-- keys can never enter a canonical record, and native words round-trip.
-- This guards the boundary these suites consume rather than new behavior.
function T.transient_effects_never_enter_persistent_records()
  local StatusCodec = require("libs.mons.src.gen4.StatusCodec")

  Assert.throws(function()
    StatusCodec.checkEffect({ key = "confusion", version = 1, state = { turns = 2 } })
  end)
  Assert.throws(function()
    StatusCodec.checkEffect({ key = "substitute", version = 1, state = { hp = 12 } })
  end)
  Assert.throws(function()
    StatusCodec.project({ { key = "confusion", version = 1, state = { turns = 2 } } })
  end)
  local poisoned = StatusCodec.decode(0x8)
  Assert.deepEqual(poisoned, { { key = "poison", version = 1, state = {} } }, "native words keep their meaning")
  Assert.equal(StatusCodec.project(poisoned), 0x8, "persistent records project back exactly")
end

-- The freeze gate thaws on the exact native predicate: one labeled draw
-- thaws exactly when draw % 5 == 0. Draws 0 and 5 thaw while adjacent
-- draws 1, 4, 6 and 65534 stay frozen, and every case consumes exactly
-- one draw at the freeze site. The maximum draw 65535 is itself a
-- multiple of 5 (5 x 13107), so it thaws under the same predicate.
function T.freeze_gate_thaws_on_the_modulo_five_draw()
  local Status = statusOwner("native major status law owns application and replacement resets")

  local cases = {
    { draw = 0, thaws = true },
    { draw = 1, thaws = false },
    { draw = 4, thaws = false },
    { draw = 5, thaws = true },
    { draw = 6, thaws = false },
    { draw = 65534, thaws = false },
    { draw = 65535, thaws = true },
  }
  for _, case in ipairs(cases) do
    local mon = freshMon()
    Assert.isTrue(Status.apply(mon, "freeze", EffectFixture.cause(2, 1), {}), "freeze applies")
    local calls = 0
    local labels = {}
    local stream = {}
    function stream:nextU16(label, cause)
      calls = calls + 1
      assert(type(label) == "string" and label ~= "", "the thaw gate names its draw site")
      assert(type(cause) == "table", "the thaw gate carries its semantic cause")
      labels[#labels + 1] = label
      return case.draw
    end
    local result = Status.beforeAction(mon, stream, EffectFixture.cause(1, 1))
    if case.thaws then
      Assert.isTrue(result.acts, "draw " .. case.draw .. " thaws the frozen combatant")
      Assert.notNil(result.event, "thawing emits its event")
      Assert.equal(result.event.outcome, "thawed", "draw " .. case.draw .. " reports its thaw")
      Assert.deepEqual(mon.condition.effects, {}, "thawing clears the condition record")
    else
      Assert.isFalse(result.acts, "draw " .. case.draw .. " leaves the ice intact")
      Assert.notNil(result.event, "a blocked gate names its condition")
      Assert.equal(result.event.outcome, "blocked", "draw " .. case.draw .. " blocks without thawing")
      Assert.equal(#mon.condition.effects, 1, "the gate never cures the condition it checks")
    end
    Assert.equal(calls, 1, "draw " .. case.draw .. " consumes exactly one thaw draw")
    Assert.deepEqual(labels, { "freeze_thaw" }, "the thaw gate draws at its labeled site")
  end
end

-- Full paralysis blocks on remainder arithmetic: one labeled draw blocks
-- exactly when raw % 4 == 0. Healthy combatants act without drawing.
function T.paralysis_gate_blocks_on_remainder_four_draws()
  local Status = statusOwner("native major status law owns its action gate")

  local cases = {
    { draw = 0, acts = false },
    { draw = 1, acts = true },
    { draw = 4, acts = false },
    { draw = 65535, acts = true },
  }
  for _, case in ipairs(cases) do
    local mon = freshMon()
    Assert.isTrue(Status.apply(mon, "paralysis", EffectFixture.cause(2, 1), {}), "paralysis applies")
    local calls = 0
    local labels = {}
    local stream = {}
    function stream:nextU16(label, cause)
      calls = calls + 1
      assert(type(label) == "string" and label ~= "", "the paralysis gate names its draw site")
      assert(type(cause) == "table", "the paralysis gate carries its semantic cause")
      labels[#labels + 1] = label
      return case.draw
    end
    local result = Status.beforeAction(mon, stream, EffectFixture.cause(1, 1))
    if case.acts then
      Assert.isTrue(result.acts, "draw " .. case.draw .. " lets the paralyzed combatant act")
      Assert.isNil(result.event, "draw " .. case.draw .. " emits nothing when it acts")
    else
      Assert.isFalse(result.acts, "draw " .. case.draw .. " blocks the paralyzed combatant")
      Assert.notNil(result.event, "draw " .. case.draw .. " names its condition")
      Assert.equal(result.event.outcome, "blocked", "draw " .. case.draw .. " blocks without ending the condition")
    end
    Assert.equal(calls, 1, "draw " .. case.draw .. " consumes exactly one paralysis draw")
    Assert.deepEqual(labels, { "paralysis_check" }, "the paralysis gate draws at its labeled site")
    Assert.equal(#mon.condition.effects, 1, "the gate never cures the condition it checks")
  end

  local healthy = freshMon()
  local healthyCalls = 0
  local healthyStream = {}
  function healthyStream:nextU16(_label, _cause)
    healthyCalls = healthyCalls + 1
    return 0
  end
  local healthyResult = Status.beforeAction(healthy, healthyStream, EffectFixture.cause(1, 1))
  Assert.isTrue(healthyResult.acts, "health never blocks")
  Assert.isNil(healthyResult.event, "health emits no gate event")
  Assert.equal(healthyCalls, 0, "health draws nothing from the stream")
end

return { tests = T }
