-- Scoped effect lifetimes, deterministic dispatch under mutation, and typed
-- custom effects: persistent conditions stay on the canonical mon while the
-- bag owns only battle state, replacement and faint move each scope by its
-- own transfer policy, mid-pass mutation never corrupts the pass, and
-- namespaced definitions round-trip through snapshots with strict state
-- validation.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local EffectFixture = require("libs.battle.tests.effect_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded effect bag owner
local function bagOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.EffectBag", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded dispatch owner
local function dispatchOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.EffectDispatch", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded major-status law owner
local function statusOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Status", behavior)
end

---@return table healthy mon record owned by the mon domain
local function freshMon()
  return SessionFixture.makeMon(11)
end

---@param mon table mon record under test
---@param key string persistent condition key under test
---@param state table typed condition state under test
local function setPersistent(mon, key, state)
  mon.condition.effects = { { key = key, version = 1, state = state } }
end

---@param definition table definition under test
---@param scope table owner scope under test
---@param source table causal source under test
---@param state table typed state under test
---@return table stored instance record
local function storedInstance(bag, definition, scope, source, state)
  local instance = bag:add(definition, scope, source, state)
  Assert.notNil(instance, "published additions return their stored instance")
  return instance
end

-- Persistent conditions belong on the canonical mon record: the bag refuses
-- them, and a replacement leaves the mon's own condition untouched.
function T.persistent_conditions_reject_the_bag_and_stay_on_the_mon()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  local hpBefore = mon.condition.currentHp
  setPersistent(mon, "poison", {})
  local bag = EffectBag.new()
  local persistent = EffectFixture.define({ key = "poison", persistent = true })

  Assert.throws(function()
    bag:add(persistent, EffectFixture.rosterScope(1), EffectFixture.cause(2, 1), { version = 1 })
  end)
  Assert.deepEqual(bag:capture(), {}, "rejected additions leave the published bag unchanged")

  Status.switchReset(mon, bag, 1, 2)
  Assert.deepEqual(
    mon.condition.effects,
    { { key = "poison", version = 1, state = {} } },
    "replacement keeps the canonical persistent condition"
  )
  Assert.equal(mon.condition.currentHp, hpBefore, "replacement resets never touch canonical health")
end

-- Replacement clears the departing activation's volatile state while side,
-- field, and roster scopes survive with their identities intact.
function T.replacement_clears_activation_state_and_keeps_wider_scopes()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  setPersistent(mon, "poison", {})
  local bag = EffectBag.new()
  local confusion = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:confusion" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )
  local substitute = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:substitute" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(1, 1),
    { version = 1, hp = 12 }
  )
  local screen = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:screen" }),
    EffectFixture.sideScope(1),
    EffectFixture.cause(1, 1),
    { version = 1, turns = 5 }
  )

  Status.switchReset(mon, bag, 1, 2)

  Assert.isNil(bag:get(confusion.id), "the departing activation loses its confusion")
  Assert.isNil(bag:get(substitute.id), "the departing activation loses its substitute")
  Assert.deepEqual(bag:get(screen.id).scope, { kind = "side", side = 1 }, "the side screen survives replacement")
  Assert.deepEqual(
    mon.condition.effects,
    { { key = "poison", version = 1, state = {} } },
    "the canonical condition is independent of activation state"
  )
  Assert.equal(#bag:capture(), 1, "only the side instance remains published")
end

-- Delayed state follows its position owner, not the occupant: switching the
-- combatant out leaves the position instance exactly where it was.
function T.delayed_position_state_outlives_its_occupant()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  local bag = EffectBag.new()
  local delayed = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:doom", transfer = "position" }),
    EffectFixture.positionScope(2),
    EffectFixture.cause(1, 1),
    { version = 1, turns = 3 }
  )
  local other = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:doom", transfer = "position" }),
    EffectFixture.positionScope(1),
    EffectFixture.cause(2, 1),
    { version = 1, turns = 2 }
  )

  Status.switchReset(mon, bag, 3, 2)

  local kept = bag:get(delayed.id)
  Assert.deepEqual(kept.scope, { kind = "position", position = 2 }, "the delayed instance stays on its position")
  Assert.deepEqual(kept.state, { version = 1, turns = 3 }, "position state keeps its own counters")
  Assert.notNil(bag:get(other.id), "the untouched position keeps its own instance")
end

-- Faint drops battle state without touching the canonical condition, and
-- revival never duplicates the persistent record.
function T.faint_and_revival_never_duplicate_persistent_state()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  setPersistent(mon, "poison", {})
  mon.condition.currentHp = 0
  local bag = EffectBag.new()
  local confusion = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:confusion" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )

  Status.switchReset(mon, bag, 1, 2)
  Assert.isNil(bag:get(confusion.id), "the fainted activation loses its volatile state")
  Assert.deepEqual(
    mon.condition.effects,
    { { key = "poison", version = 1, state = {} } },
    "faint keeps the canonical persistent condition"
  )

  mon.condition.currentHp = 20
  Status.switchReset(mon, bag, 1, 3)
  Assert.deepEqual(
    mon.condition.effects,
    { { key = "poison", version = 1, state = {} } },
    "revival restores health without duplicating the condition"
  )
  Assert.deepEqual(bag:capture(), {}, "no volatile counter leaks across the faint boundary")
end

-- Activation tokens isolate re-entries: the old token's instances are gone,
-- and the incoming token starts from fresh identities.
function T.activation_tokens_isolate_reentered_combatants()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  local bag = EffectBag.new()
  local first = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:confusion" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )

  Status.switchReset(mon, bag, 1, 2)
  Assert.isNil(bag:get(first.id), "the previous entry cannot write through its old token")

  local second = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:confusion" }),
    EffectFixture.activeScope(1, 2),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )
  Assert.isTrue(second.id ~= first.id, "re-entry allocates a fresh instance identity")
  Assert.deepEqual(second.scope, { kind = "active", combatant = 1, activation = 2 }, "the new entry owns its scope")
end

-- Carry policy moves a marked instance onto the incoming activation with its
-- identity and state intact instead of clearing it.
function T.transfer_policy_carries_marked_state_forward()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local Status = statusOwner("native major status law owns application and replacement resets")

  local mon = freshMon()
  local bag = EffectBag.new()
  local carried = storedInstance(
    bag,
    EffectFixture.define({ key = "tests:curse", transfer = "carry" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )

  Status.switchReset(mon, bag, 1, 2)
  local kept = bag:get(carried.id)
  Assert.notNil(kept, "carried state survives replacement")
  Assert.deepEqual(kept.scope, { kind = "active", combatant = 1, activation = 2 }, "carried state follows the entry")
  Assert.deepEqual(kept.state, { version = 1 }, "carried state keeps its counters")
end

-- An instance removed mid-pass never fires later in that pass, even though
-- it was collected before the removal.
function T.removed_instances_stay_silent_for_the_rest_of_the_pass()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")

  local bag = EffectBag.new()
  local alpha = bag:add(
    EffectFixture.define({ key = "tests:alpha" }),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  local beta = bag:add(
    EffectFixture.define({ key = "tests:beta" }),
    EffectFixture.activeScope(2, 1),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )
  local gamma = bag:add(
    EffectFixture.define({ key = "tests:gamma" }),
    EffectFixture.activeScope(3, 1),
    EffectFixture.cause(3, 1),
    { version = 1 }
  )
  local fired = {}
  local handlers = {
    ["tests:alpha"] = function(_, _)
      bag:remove(beta.id)
      fired[#fired + 1] = "alpha"
      return { kind = "tick", key = "tests:alpha", combatant = 1 }
    end,
    ["tests:beta"] = function(_, _)
      fired[#fired + 1] = "beta"
      return { kind = "tick", key = "tests:beta", combatant = 2 }
    end,
    ["tests:gamma"] = function(_, _)
      fired[#fired + 1] = "gamma"
      return { kind = "tick", key = "tests:gamma", combatant = 3 }
    end,
  }
  local dispatch = EffectDispatch.new(bag, handlers)
  local context = EffectFixture.residualContext({ [1] = 100, [2] = 80, [3] = 60 }, {}, 7)

  local collected = EffectFixture.collectedIds(dispatch:collect("residual", context))
  Assert.deepEqual(collected, { alpha.id, beta.id, gamma.id }, "collection sees every live instance first")

  local outcome = dispatch:invoke("residual", context)
  Assert.isTrue(outcome.done, "an unbounded pass runs to completion")
  Assert.deepEqual(fired, { "alpha", "gamma" }, "the removed instance never fires after its removal")
  Assert.equal(#outcome.events, 2, "removed instances emit nothing")
  Assert.isNil(bag:get(beta.id), "removal during dispatch still publishes")
end

-- Instances created mid-pass wait for the following pass: they never run
-- just because table iteration happened to notice them.
function T.instances_added_mid_pass_wait_for_the_next_checkpoint()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")

  local bag = EffectBag.new()
  local definition = function(key)
    return EffectFixture.define({ key = key })
  end
  bag:add(definition("tests:alpha"), EffectFixture.activeScope(1, 1), EffectFixture.cause(1, 1), { version = 1 })
  bag:add(definition("tests:beta"), EffectFixture.activeScope(2, 1), EffectFixture.cause(2, 1), { version = 1 })
  local fired = {}
  local handlers = {}
  handlers["tests:alpha"] = function(_, _)
    fired[#fired + 1] = "alpha"
    bag:add(definition("tests:delta"), EffectFixture.activeScope(4, 1), EffectFixture.cause(1, 1), { version = 1 })
    return { kind = "tick", key = "tests:alpha", combatant = 1 }
  end
  handlers["tests:beta"] = function(_, _)
    fired[#fired + 1] = "beta"
    return { kind = "tick", key = "tests:beta", combatant = 2 }
  end
  handlers["tests:delta"] = function(_, _)
    fired[#fired + 1] = "delta"
    return { kind = "tick", key = "tests:delta", combatant = 4 }
  end
  local dispatch = EffectDispatch.new(bag, handlers)
  local context = EffectFixture.residualContext({ [1] = 100, [2] = 80, [4] = 10 }, {}, 7)

  local first = dispatch:invoke("residual", context)
  Assert.deepEqual(fired, { "alpha", "beta" }, "the newborn instance waits out the running pass")

  local second = dispatch:invoke("residual", context)
  Assert.deepEqual(
    fired,
    { "alpha", "beta", "alpha", "beta", "delta" },
    "the following pass runs the newcomer once in source order"
  )
  Assert.equal(#first.events + 1, #second.events, "replacement stacking keeps exactly one newcomer alive")
end

-- Insertion order and operation budgets never change the pass: reversed
-- registration collects identically, and single-step suspension matches one
-- unbounded run event for event.
function T.insertion_order_and_budgets_share_one_sequence()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")

  local keys = { "tests:alpha", "tests:beta", "tests:gamma" }
  ---@param order string[] insertion order for this bag
  ---@return table bag with one instance per key
  local function buildBag(order)
    local bag = EffectBag.new()
    for _, key in ipairs(order) do
      local combatant = nil
      for position, canonical in ipairs(keys) do
        if canonical == key then
          combatant = position
        end
      end
      assert(combatant ~= nil, "test keys stay canonical")
      bag:add(
        EffectFixture.define({ key = key }),
        EffectFixture.activeScope(combatant, 1),
        EffectFixture.cause(combatant, 1),
        { version = 1 }
      )
    end
    return bag
  end
  local forward = buildBag(keys)
  local backward = buildBag({ keys[3], keys[2], keys[1] })

  ---@param instance table collected instance under test
  ---@return string dispatch identity under test
  local function identity(instance)
    return instance.key
  end
  local recorder = function(instance, _)
    return { kind = "tick", key = instance.key, combatant = instance.scope.combatant }
  end
  local speeds = { [1] = 60, [2] = 100, [3] = 80 }
  local forwardDispatch = EffectDispatch.new(forward, {
    ["tests:alpha"] = recorder,
    ["tests:beta"] = recorder,
    ["tests:gamma"] = recorder,
  })
  local backwardDispatch = EffectDispatch.new(backward, {
    ["tests:alpha"] = recorder,
    ["tests:beta"] = recorder,
    ["tests:gamma"] = recorder,
  })
  local function orderOf(dispatch)
    local context = EffectFixture.residualContext(speeds, {}, 7)
    local entries = dispatch:collect("residual", context)
    local order = {}
    for _, entry in ipairs(entries) do
      order[#order + 1] = identity(entry.instance)
    end
    return order
  end
  Assert.deepEqual(orderOf(backwardDispatch), orderOf(forwardDispatch), "collection ignores insertion order")
  Assert.deepEqual(
    orderOf(forwardDispatch),
    { "tests:beta", "tests:gamma", "tests:alpha" },
    "collection follows sampled speed order"
  )

  local whole = forwardDispatch:invoke("residual", EffectFixture.residualContext(speeds, {}, 7))
  Assert.isTrue(whole.done, "an unbounded pass completes")

  local stepped = {}
  local resume = nil
  while true do
    local context = EffectFixture.residualContext(speeds, {}, 7)
    context.resume = resume
    local outcome = backwardDispatch:invoke("residual", context, 1)
    for _, event in ipairs(outcome.events) do
      stepped[#stepped + 1] = event
    end
    if outcome.done then
      Assert.isNil(outcome.checkpoint, "a finished pass keeps no continuation")
      break
    end
    Assert.notNil(outcome.checkpoint, "a suspended pass publishes its continuation")
    SessionFixture.assertPlainData(outcome.checkpoint, "checkpoint")
    resume = outcome.checkpoint
  end
  Assert.deepEqual(stepped, whole.events, "budgeted suspension matches the unbounded pass exactly")
end

-- A namespaced typed effect composes through the same bag and dispatch and
-- survives an exact snapshot restore with its counters intact.
function T.custom_typed_state_survives_snapshot_restore()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local BattleBehaviorBuilder = SessionFixture.requirePresent(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration owns the public definition surface"
  )

  local definition = {
    module = "libs.battle.tests.effect_fixture",
    version = 2,
    key = "tests:wardrums",
    stateVersion = 2,
    validateState = EffectFixture.counterState(2, 0, 3),
    timings = { { timing = "residual", handler = "tests:wardrums", orderClass = "affliction" } },
    lifecycle = { stacking = "replace", transfer = "clear", persistent = false },
  }
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerEffect("tests:wardrums", definition, "lifecycle-tests")
  local bound = behaviors:freeze()
  local published = bound:get("effects", "tests:wardrums")
  Assert.equal(published.version, 2, "the frozen registry publishes the custom definition")
  published.lifecycle.stacking = "stack"
  Assert.equal(
    bound:get("effects", "tests:wardrums").lifecycle.stacking,
    "replace",
    "behavior views share no mutable state with the registry"
  )

  local bag = EffectBag.new()
  local instance = bag:add(
    definition,
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(1, 1),
    { version = 2, counter = 1 }
  )
  Assert.equal(instance.version, 2, "stored instances carry their definition version")
  local dispatch = EffectDispatch.new(bag, {
    ["tests:wardrums"] = function(target, _)
      return { kind = "tick", key = target.key, combatant = target.scope.combatant }
    end,
  })
  local context = EffectFixture.residualContext({ [1] = 50 }, {}, 7)
  local collected = dispatch:collect("residual", context)
  Assert.equal(#collected, 1, "the custom instance participates in the shared dispatch")
  Assert.equal(collected[1].binding.handler, "tests:wardrums", "the custom binding resolves its handler")

  local snapshot = bag:capture()
  SessionFixture.assertPlainData(snapshot, "snapshot")
  local revived = EffectBag.new(snapshot)
  Assert.deepEqual(revived:capture(), snapshot, "snapshot restore reproduces every instance exactly")
  Assert.deepEqual(
    revived:get(instance.id).state,
    { version = 2, counter = 1 },
    "validated counters survive the restore"
  )
end

-- Malformed versions and states fail before publication: the live bag keeps
-- its previous contents and unknown timings never validate.
function T.invalid_versions_and_states_fail_before_publication()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")

  local bag = EffectBag.new()
  local definition = {
    key = "tests:wardrums",
    stateVersion = 2,
    validateState = EffectFixture.counterState(2, 0, 3),
    timings = { { timing = "residual", handler = "tests:wardrums", orderClass = "affliction" } },
    lifecycle = { stacking = "replace", transfer = "clear", persistent = false },
  }

  Assert.throws(function()
    bag:add(definition, EffectFixture.activeScope(1, 1), EffectFixture.cause(1, 1), { version = 2, counter = 9 })
  end)
  Assert.throws(function()
    bag:add(definition, EffectFixture.activeScope(1, 1), EffectFixture.cause(1, 1), { version = 1, counter = 1 })
  end)
  Assert.throws(function()
    bag:add(definition, EffectFixture.activeScope(1, 1), EffectFixture.cause(1, 1), "loud")
  end)
  Assert.deepEqual(bag:capture(), {}, "failed validations publish nothing")

  local broken = EffectFixture.define({ key = "tests:broken" })
  broken.timings = { { timing = "someday", handler = "tests:broken", orderClass = "affliction" } }
  Assert.throws(function()
    EffectDispatch.validateBindings(broken)
  end, "unknown timings never validate")
  Assert.isTrue(
    EffectDispatch.validateBindings(EffectFixture.define({ key = "tests:plain" })),
    "well-formed definitions validate"
  )
end

-- Stored state never aliases caller tables: mutating the input after the
-- call or the output of a lookup leaves the published instance unchanged.
function T.stored_state_never_aliases_caller_tables()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")

  local bag = EffectBag.new()
  local definition = EffectFixture.define({ key = "tests:substitute" })
  local offered = { version = 1, hp = 12 }
  local instance = bag:add(definition, EffectFixture.activeScope(1, 1), EffectFixture.cause(1, 1), offered)
  offered.hp = 99
  Assert.deepEqual(bag:get(instance.id).state, { version = 1, hp = 12 }, "additions copy their state")

  local viewed = bag:get(instance.id)
  Assert.notNil(viewed, "stored instances remain readable")
  viewed.state.hp = 99
  viewed.scope.activation = 9
  local reread = bag:get(instance.id)
  Assert.deepEqual(reread.state, { version = 1, hp = 12 }, "lookups share no mutable state")
  Assert.deepEqual(
    reread.scope,
    { kind = "active", combatant = 1, activation = 1 },
    "lookups share no mutable scope"
  )
end

return { tests = T }
