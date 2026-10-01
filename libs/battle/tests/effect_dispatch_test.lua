-- Lower-level boundaries for the effect lifecycle owners: stacking
-- policies, unknown-identity reports, snapshot shape validation,
-- serializable state commitment, dispatch input validation and handler
-- result shapes, suppression, residual frame validation, and the status
-- vocabulary boundary. These pin the failure branches next to the
-- happy paths the lifecycle suites prove.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local EffectFixture = require("libs.battle.tests.effect_fixture")

local T = {}

---@return table the scoped-instance owner
local function bagOwner()
  return SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
end

---@return table the finite-dispatch owner
local function dispatchOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
end

---@return table the residual-continuation owner
local function residualsOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.Residuals",
    "native residual continuation owns phase and cursor structure"
  )
end

---@return table the major-status law owner
local function statusOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.Status",
    "native major status law owns application and replacement resets"
  )
end

---@param key string
---@param stacking string
---@param maxStacks integer?
---@return table definition record under test
local function lifecycleDefinition(key, stacking, maxStacks)
  return EffectFixture.define({ key = key, stacking = stacking, maxStacks = maxStacks })
end

-- Rejection stacking refuses a second live instance on the same scope and
-- keeps the first exactly as published.
function T.reject_stacking_refuses_seconds_and_keeps_first()
  local EffectBag = bagOwner()

  local bag = EffectBag.new()
  local definition = lifecycleDefinition("tests:ward", "reject")
  local first = bag:add(definition, EffectFixture.sideScope(1), EffectFixture.cause(1, 1), { version = 1 })
  Assert.throws(function()
    bag:add(definition, EffectFixture.sideScope(1), EffectFixture.cause(2, 1), { version = 1 })
  end)
  Assert.deepEqual(bag:get(first.id).state, { version = 1 }, "the rejected addition changes nothing")
  Assert.equal(#bag:capture(), 1, "only the first instance stays published")

  local other = bag:add(definition, EffectFixture.sideScope(2), EffectFixture.cause(2, 1), { version = 1 })
  Assert.notNil(bag:get(other.id), "a different scope is a different stacking family")
end

-- Counted stacking publishes up to its bound and fails before publishing
-- the excess instance.
function T.counted_stacking_enforces_its_bound()
  local EffectBag = bagOwner()

  local bag = EffectBag.new()
  local definition = lifecycleDefinition("tests:spikes", "stack", 2)
  bag:add(definition, EffectFixture.sideScope(1), EffectFixture.cause(1, 1), { version = 1, layers = 1 })
  bag:add(definition, EffectFixture.sideScope(1), EffectFixture.cause(1, 1), { version = 1, layers = 2 })
  Assert.throws(function()
    bag:add(definition, EffectFixture.sideScope(1), EffectFixture.cause(1, 1), { version = 1, layers = 2 })
  end)
  Assert.equal(#bag:capture(), 2, "the excess instance never publishes")
end

-- Unknown identities report absence instead of failing: removal reports
-- false, transfer and lookup report nil, state commitment reports false.
function T.unknown_identities_report_absence()
  local EffectBag = bagOwner()

  local bag = EffectBag.new()
  Assert.isFalse(bag:remove(41), "removing absence reports no work")
  Assert.isNil(bag:get(41), "reading absence reports nothing")
  Assert.isNil(bag:transfer(41, EffectFixture.fieldScope()), "transferring absence reports nothing")
  Assert.isFalse(bag:commitState(41, { version = 1 }), "committing absence reports no work")
  Assert.deepEqual(bag:capture(), {}, "absence reports publish nothing")
end

-- Malformed snapshots fail before a bag exists: non-records, missing
-- identities, and duplicated identities never restore.
function T.malformed_snapshots_fail_before_restore()
  local EffectBag = bagOwner()

  Assert.throws(function()
    EffectBag.new({ "loud" })
  end)
  Assert.throws(function()
    EffectBag.new({ { key = "tests:plain", version = 1 } })
  end)
  local record = {
    id = 1,
    key = "tests:plain",
    version = 1,
    scope = EffectFixture.fieldScope(),
    source = EffectFixture.cause(1, 1),
    state = { version = 1 },
    createdOrdinal = 1,
  }
  Assert.throws(function()
    EffectBag.new({ record, record })
  end)
end

-- Committed state stays serializable: function payloads fail, and the
-- stored record keeps its previous state.
function T.committed_state_stays_serializable()
  local EffectBag = bagOwner()

  local bag = EffectBag.new()
  local instance = bag:add(
    EffectFixture.define({ key = "tests:plain" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  Assert.throws(function()
    bag:commitState(instance.id, { version = 1, fn = function() end })
  end)
  Assert.deepEqual(bag:get(instance.id).state, { version = 1 }, "failed commitments change nothing")
  Assert.isTrue(bag:commitState(instance.id, { version = 1 }), "well-formed commitments report their work")
end

-- Collection and invocation accept only the finite timing vocabulary, and
-- budgets stay positive integers.
function T.dispatch_rejects_unknown_timings_and_budgets()
  local EffectBag = bagOwner()
  local EffectDispatch = dispatchOwner()

  local bag = EffectBag.new()
  local dispatch = EffectDispatch.new(bag, {})
  local context = EffectFixture.residualContext({}, {}, 7)
  Assert.throws(function()
    dispatch:collect("someday", context)
  end)
  Assert.throws(function()
    dispatch:invoke("someday", context)
  end)
  Assert.throws(function()
    dispatch:invoke("residual", context, 0)
  end)
  Assert.isTrue(EffectDispatch.validateBindings(EffectFixture.define({ key = "tests:plain" })), "finite bindings pass")
end

-- A bound instance without a handler fails loudly; the live bag keeps the
-- unhandled instance untouched.
function T.unhandled_instances_fail_loudly()
  local EffectBag = bagOwner()
  local EffectDispatch = dispatchOwner()

  local bag = EffectBag.new()
  local instance = bag:add(
    EffectFixture.define({ key = "tests:orphan" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  local dispatch = EffectDispatch.new(bag, {})
  Assert.throws(function()
    dispatch:invoke("residual", EffectFixture.residualContext({ [1] = 50 }, {}, 7))
  end)
  Assert.deepEqual(bag:get(instance.id).state, { version = 1 }, "failed passes change no live state")
end

-- Silent handlers emit nothing while the pass still completes, and single
-- events and arrays both land in emission order.
function T.handler_result_shapes_share_one_pass()
  local EffectBag = bagOwner()
  local EffectDispatch = dispatchOwner()

  local bag = EffectBag.new()
  bag:add(
    EffectFixture.define({ key = "tests:quiet" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  bag:add(
    EffectFixture.define({ key = "tests:loud" }),
    EffectFixture.activeScope(2, 1),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )
  local dispatch = EffectDispatch.new(bag, {
    ["tests:quiet"] = function(_, _)
      return nil
    end,
    ["tests:loud"] = function(instance, _)
      return { { kind = "tick", key = instance.key }, { kind = "tock", key = instance.key } }
    end,
  })
  local outcome = dispatch:invoke("residual", EffectFixture.residualContext({ [1] = 90, [2] = 10 }, {}, 7))
  Assert.isTrue(outcome.done, "a pass with silent handlers still completes")
  Assert.isNil(outcome.checkpoint, "a finished pass keeps no continuation")
  Assert.equal(#outcome.events, 2, "arrays emit every event while silence emits none")
  Assert.equal(outcome.events[1].kind, "tick", "array order is emission order")
end

-- Suppressed instances never fire: the handler stays uncalled, nothing
-- emits, and the instance stays published for later passes.
function T.suppression_mutes_marked_instances()
  local EffectBag = bagOwner()
  local EffectDispatch = dispatchOwner()

  local bag = EffectBag.new()
  local instance = bag:add(
    EffectFixture.define({ key = "tests:muted" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  local calls = 0
  local dispatch = EffectDispatch.new(bag, {
    ["tests:muted"] = function(_, _)
      calls = calls + 1
      return { kind = "tick", key = "tests:muted" }
    end,
  })
  local context = EffectFixture.residualContext({ [1] = 50 }, {}, 7)
  context.suppressedIds = { [instance.id] = true }
  local outcome = dispatch:invoke("residual", context)
  Assert.isTrue(outcome.done, "a fully suppressed pass still completes")
  Assert.equal(calls, 0, "suppressed handlers never run")
  Assert.deepEqual(outcome.events, {}, "suppressed instances emit nothing")
  Assert.notNil(bag:get(instance.id), "suppression mutes without removing")
end

-- Residual frames validate strictly: garbage, unknown identities, and
-- non-list settlements never resume.
function T.residual_frames_validate_strictly()
  local Residuals = residualsOwner()

  Assert.throws(function()
    Residuals.validateFrame(nil)
  end)
  Assert.throws(function()
    Residuals.validateFrame({})
  end)
  Assert.throws(function()
    Residuals.validateFrame({ kind = "gen4:residuals", version = 2, fainted = {} })
  end)
  Assert.throws(function()
    Residuals.validateFrame({ kind = "gen4:residuals", version = 1, fainted = { "one" } })
  end)
  Assert.isTrue(
    Residuals.validateFrame({ kind = "gen4:residuals", version = 1, checkpoint = nil, fainted = {} }).version == 1,
    "well-formed frames validate"
  )
end

-- An empty residual pass completes at once with no events and a valid
-- terminal frame.
function T.empty_residual_passes_complete_at_once()
  local EffectBag = bagOwner()
  local EffectDispatch = dispatchOwner()
  local Residuals = residualsOwner()

  local dispatch = EffectDispatch.new(EffectBag.new(), {})
  local outcome = Residuals.step(dispatch, EffectFixture.residualContext({}, {}, 7))
  Assert.isTrue(outcome.done, "an empty pass completes at once")
  Assert.deepEqual(outcome.events, {}, "an empty pass emits nothing")
  Residuals.validateFrame(outcome.frame)
  Assert.throws(function()
    Residuals.step(dispatch, EffectFixture.residualContext({}, {}, 7), 0)
  end, "residual budgets stay positive")
end

-- Transient battle keys can never enter the status law: application and
-- cure both name only native major conditions.
function T.status_law_rejects_transient_keys()
  local Status = statusOwner()

  local mon = SessionFixture.makeMon(31)
  Assert.throws(function()
    Status.apply(mon, "confusion", EffectFixture.cause(2, 1), { version = 1, turns = 2 })
  end)
  Assert.throws(function()
    Status.cure(mon, "confusion")
  end)
  Assert.deepEqual(mon.condition.effects, {}, "rejected keys publish nothing")
end

-- Replacement resets over an empty bag and a healthy mon report their
-- work while changing nothing observable.
function T.quiet_resets_change_nothing_observable()
  local EffectBag = bagOwner()
  local Status = statusOwner()

  local mon = SessionFixture.makeMon(33)
  local hpBefore = mon.condition.currentHp
  Assert.isTrue(Status.switchReset(mon, EffectBag.new(), 1, 2), "quiet resets report their work")
  Assert.deepEqual(mon.condition.effects, {}, "quiet resets add no condition")
  Assert.equal(mon.condition.currentHp, hpBefore, "quiet resets never touch health")
end

return { tests = T }
