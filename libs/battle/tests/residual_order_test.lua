-- Native residual ordering: end-of-turn ticks traverse in sampled speed
-- order, simultaneous faints settle in source sequence without cutting the
-- phase short, expirations follow their final tick, budgeted suspension and
-- snapshot restore never repeat completed work, attribution outlives its
-- source, and the native registries cover every residual family. The
-- mechanic stubs below are synthetic stand-ins that pin order and
-- lifecycle only; exact native quotients belong to the implementation
-- against its source vectors.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local EffectFixture = require("libs.battle.tests.effect_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded scoped-instance owner
local function bagOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.EffectBag", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded finite-dispatch owner
local function dispatchOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.EffectDispatch", behavior)
end

---@param behavior string missing owner under test
---@return table the loaded residual-continuation owner
local function residualsOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Residuals", behavior)
end

---@param key string effect key under test
---@param orderClass string source mechanic category under test
---@param transfer string transfer policy under test
---@return table test-local definition record
local function testDefinition(key, orderClass, transfer)
  return EffectFixture.define({
    key = key,
    timings = { { timing = "residual", handler = key, orderClass = orderClass } },
    transfer = transfer,
  })
end

---@param amount integer fixed damage per tick under test
---@return fun(instance: table, context: table): table handler draining health
local function fixedDamage(amount)
  return function(instance, context)
    local combatant = instance.scope.combatant
    context.health[combatant] = context.health[combatant] - amount
    return { kind = "tick", key = instance.key, combatant = combatant, amount = amount }
  end
end

---@param amount integer fixed recovery per tick under test
---@return fun(instance: table, context: table): table handler restoring health
local function fixedRecovery(amount)
  return function(instance, context)
    local combatant = instance.scope.combatant
    context.health[combatant] = context.health[combatant] + amount
    return { kind = "tick", key = instance.key, combatant = combatant, amount = -amount }
  end
end

---@return fun(instance: table, context: table): table leech handler attributing its source
local function attributedDrain()
  return function(instance, context)
    local combatant = instance.scope.combatant
    context.health[combatant] = context.health[combatant] - 4
    return {
      kind = "tick",
      key = instance.key,
      combatant = combatant,
      amount = 4,
      source = { kind = instance.source.kind, combatant = instance.source.combatant },
    }
  end
end

---@param amount integer fixed weather damage per combatant under test
---@return fun(instance: table, context: table): table[] handler draining every combatant in speed order
local function weatherDamage(amount)
  return function(instance, context)
    local order = {}
    for combatant in pairs(context.health) do
      order[#order + 1] = combatant
    end
    table.sort(order, function(a, b)
      return context.speeds[a] > context.speeds[b]
    end)
    local events = {}
    for _, combatant in ipairs(order) do
      context.health[combatant] = context.health[combatant] - amount
      events[#events + 1] = { kind = "tick", key = instance.key, combatant = combatant, amount = amount }
    end
    return events
  end
end

---@return fun(instance: table, context: table): table[] perish handler expiring at zero
local function perishCount()
  return function(instance, context)
    local combatant = instance.scope.combatant
    local remaining = instance.state.counter - 1
    instance.state.counter = remaining
    context.health[combatant] = context.health[combatant] - 4
    local events = { { kind = "tick", key = instance.key, combatant = combatant, amount = 4 } }
    if remaining <= 0 then
      context.health[combatant] = 0
      events[#events + 1] = { kind = "expire", key = instance.key, combatant = combatant }
    end
    return events
  end
end

-- Ticks traverse in sampled speed order: the faster afflicted combatant's
-- damage event precedes the slower one's, and health drops match.
function T.ticks_run_in_sampled_speed_order()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  local bag = EffectBag.new()
  bag:add(
    testDefinition("toxic", "affliction", "clear"),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )
  bag:add(
    testDefinition("toxic", "affliction", "clear"),
    EffectFixture.activeScope(2, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  local dispatch = EffectDispatch.new(bag, { toxic = fixedDamage(4) })
  local context = EffectFixture.residualContext({ [1] = 100, [2] = 50 }, { [1] = 20, [2] = 20 }, 7)

  local outcome = Residuals.step(dispatch, context)
  Assert.isTrue(outcome.done, "a quiet pass completes in one step")
  Residuals.validateFrame(outcome.frame)
  Assert.deepEqual(
    EffectFixture.eventSignatures(outcome.events),
    { "tick:1", "tick:2" },
    "affliction ticks follow sampled speed"
  )
  Assert.deepEqual(context.health, { [1] = 16, [2] = 16 }, "every tick drains exactly once")
end

-- Simultaneous faints settle in source sequence: each killing tick is
-- followed at once by its faint, and survivors still tick afterwards.
function T.simultaneous_faints_settle_in_source_sequence()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  local bag = EffectBag.new()
  for combatant = 1, 3 do
    bag:add(
      testDefinition("toxic", "affliction", "clear"),
      EffectFixture.activeScope(combatant, 1),
      EffectFixture.cause(4, 1),
      { version = 1 }
    )
  end
  bag:add(
    testDefinition("burn", "affliction", "clear"),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(4, 1),
    { version = 1 }
  )
  local dispatch = EffectDispatch.new(bag, { toxic = fixedDamage(4), burn = fixedDamage(4) })
  local context = EffectFixture.residualContext({ [1] = 100, [2] = 80, [3] = 60 }, { [1] = 4, [2] = 4, [3] = 8 }, 7)

  local outcome = Residuals.step(dispatch, context)
  Assert.isTrue(outcome.done, "the terminal pass completes")
  Assert.deepEqual(
    EffectFixture.eventSignatures(outcome.events),
    { "tick:1", "faint:1", "tick:2", "faint:2", "tick:3" },
    "faints settle in source sequence without ending the phase early"
  )
  for _, event in ipairs(outcome.events) do
    Assert.isTrue(event.key ~= "burn", "the fainted combatant's later instances stay silent")
  end
  Assert.deepEqual(context.health, { [1] = 0, [2] = 0, [3] = 4 }, "only the killed combatants reach zero")
end

-- Expiration follows its final tick and precedes the faint it causes, and
-- one combatant's end never cancels another's tick.
function T.perish_count_expires_after_its_final_tick()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  local bag = EffectBag.new()
  bag:add(
    testDefinition("perishsong", "expiration", "clear"),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(2, 1),
    { version = 1, counter = 1 }
  )
  bag:add(
    testDefinition("toxic", "affliction", "clear"),
    EffectFixture.activeScope(2, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  local dispatch = EffectDispatch.new(bag, { perishsong = perishCount(), toxic = fixedDamage(4) })
  local context = EffectFixture.residualContext({ [1] = 100, [2] = 50 }, { [1] = 10, [2] = 20 }, 7)

  local outcome = Residuals.step(dispatch, context)
  Assert.deepEqual(
    EffectFixture.eventSignatures(outcome.events),
    { "tick:2", "tick:1", "expire:1", "faint:1" },
    "the mon-phase tick precedes the extra-phase expiration and its faint"
  )
  Assert.equal(context.health[2], 16, "the survivor still ticks before the faint")
end

-- Budgeted suspension matches one unbounded run event for event, every
-- suspension validates, and continuations stay plain data.
function T.stepwise_and_unbounded_runs_agree_exactly()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  ---@return table bag carrying weather, affliction, and recovery instances
  local function buildBag()
    local bag = EffectBag.new()
    bag:add(
      testDefinition("sandstorm", "weather", "clear"),
      EffectFixture.fieldScope(),
      EffectFixture.cause(1, 1),
      { version = 1 }
    )
    bag:add(
      testDefinition("toxic", "affliction", "clear"),
      EffectFixture.activeScope(1, 1),
      EffectFixture.cause(2, 1),
      { version = 1 }
    )
    bag:add(
      testDefinition("toxic", "affliction", "clear"),
      EffectFixture.activeScope(2, 1),
      EffectFixture.cause(1, 1),
      { version = 1 }
    )
    bag:add(
      testDefinition("recovery", "recovery", "clear"),
      EffectFixture.activeScope(2, 1),
      EffectFixture.cause(2, 1),
      { version = 1 }
    )
    return bag
  end
  local handlers = { sandstorm = weatherDamage(2), toxic = fixedDamage(4), recovery = fixedRecovery(2) }
  local speeds = { [1] = 100, [2] = 50 }
  local wholeDispatch = EffectDispatch.new(buildBag(), handlers)
  local whole = Residuals.step(wholeDispatch, EffectFixture.residualContext(speeds, { [1] = 20, [2] = 20 }, 7))
  Assert.isTrue(whole.done, "the unbounded pass completes")

  local steppedDispatch = EffectDispatch.new(buildBag(), handlers)
  local steppedHealth = { [1] = 20, [2] = 20 }
  local stepped = {}
  local resume = nil
  while true do
    local context = EffectFixture.residualContext(speeds, steppedHealth, 7)
    context.resume = resume
    local outcome = Residuals.step(steppedDispatch, context, 1)
    Residuals.validateFrame(outcome.frame)
    for _, event in ipairs(outcome.events) do
      stepped[#stepped + 1] = event
    end
    if outcome.done then
      break
    end
    SessionFixture.assertPlainData(outcome.frame, "frame")
    resume = outcome.frame
  end
  Assert.deepEqual(stepped, whole.events, "suspension never repeats or skips residual work")
end

-- Restoring mid-pass resumes behind the saved cursor: completed ticks never
-- run twice, and the tail matches the uninterrupted pass.
function T.restore_mid_pass_never_repeats_completed_work()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  local speeds = { [1] = 100, [2] = 80, [3] = 60 }
  ---@return table bag with one affliction per combatant
  local function buildBag()
    local bag = EffectBag.new()
    for combatant = 1, 3 do
      bag:add(
        testDefinition("toxic", "affliction", "clear"),
        EffectFixture.activeScope(combatant, 1),
        EffectFixture.cause(4, 1),
        { version = 1 }
      )
    end
    return bag
  end
  local bag = buildBag()
  local dispatch = EffectDispatch.new(bag, { toxic = fixedDamage(4) })
  local health = { [1] = 20, [2] = 20, [3] = 20 }

  local firstContext = EffectFixture.residualContext(speeds, health, 7)
  local first = Residuals.step(dispatch, firstContext, 1)
  Assert.isFalse(first.done, "a unit budget suspends the pass")
  local secondContext = EffectFixture.residualContext(speeds, health, 7)
  secondContext.resume = first.frame
  local second = Residuals.step(dispatch, secondContext, 1)

  local revived = EffectBag.new(bag:capture())
  local resumedDispatch = EffectDispatch.new(revived, { toxic = fixedDamage(4) })
  local tailHealth = { [1] = health[1], [2] = health[2], [3] = health[3] }
  local tailContext = EffectFixture.residualContext(speeds, tailHealth, 7)
  tailContext.resume = second.frame
  local tail = {}
  local cursor = tailContext.resume
  while cursor ~= nil do
    local probe = EffectFixture.residualContext(speeds, tailHealth, 7)
    probe.resume = cursor
    local outcome = Residuals.step(resumedDispatch, probe, 1)
    for _, event in ipairs(outcome.events) do
      tail[#tail + 1] = event
    end
    if outcome.done then
      break
    end
    cursor = outcome.frame
  end

  local uninterrupted = Residuals.step(
    EffectDispatch.new(buildBag(), { toxic = fixedDamage(4) }),
    EffectFixture.residualContext(speeds, { [1] = 20, [2] = 20, [3] = 20 }, 7)
  )
  local headed = {}
  for _, event in ipairs(first.events) do
    headed[#headed + 1] = event
  end
  for _, event in ipairs(second.events) do
    headed[#headed + 1] = event
  end
  for _, event in ipairs(tail) do
    headed[#headed + 1] = event
  end
  Assert.deepEqual(headed, uninterrupted.events, "restore resumes exactly behind the saved cursor")
  Assert.deepEqual(
    EffectFixture.eventSignatures(headed),
    { "tick:1", "tick:2", "tick:3" },
    "no tick runs twice across the restore"
  )
end

-- Attribution survives its source leaving: the drain still names the
-- fainted combatant that seeded it.
function T.attribution_outlives_the_source()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  local bag = EffectBag.new()
  local seed = bag:add(
    testDefinition("leechseed", "affliction", "clear"),
    EffectFixture.activeScope(2, 1),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  local dispatch = EffectDispatch.new(bag, { leechseed = attributedDrain() })
  local context = EffectFixture.residualContext({ [1] = 10, [2] = 50 }, { [1] = 0, [2] = 20 }, 7)

  local outcome = Residuals.step(dispatch, context)
  Assert.isTrue(outcome.done, "the pass completes with a fainted source")
  Assert.equal(#outcome.events, 1, "the seed ticks once for its host")
  Assert.equal(outcome.events[1].source.combatant, 1, "the tick still names the departed source")
  Assert.deepEqual(
    bag:get(seed.id).source,
    { kind = "probe", combatant = 1, activation = 1 },
    "dispatch never rewrites stored attribution"
  )
end

---@param bag table live effect bag under the plan
---@param key string native definition identity under the instance
---@param scope table<string, unknown> owner scope for the instance
---@param state table<string, unknown> typed state for the instance
---@return table<string, unknown> stored instance record
local function addNative(bag, key, scope, state)
  local Handlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "one registration owner binds native definitions to their handlers"
  )
  return bag:add(Handlers.definitionFor(key), scope, EffectFixture.cause(2, 1), state)
end

---@param events table[] emitted event records under test
---@return string[] effect keys in emission order
local function eventKeys(events)
  local keys = {}
  for _, event in ipairs(events) do
    assert(type(event.key) == "string", "residual events name their effect")
    keys[#keys + 1] = event.key
  end
  return keys
end

---@param keys string[] effect keys under the recording handlers
---@return table<string, fun(instance: table, context: table): table> handlers emitting one keyed event
local function recordingHandlers(keys)
  local handlers = {}
  for _, key in ipairs(keys) do
    handlers[key] = function(instance, _)
      local scope = instance.scope --[[@as table<string, unknown>]]
      return { kind = "tick", key = instance.key, combatant = scope.combatant or 0 }
    end
  end
  return handlers
end

-- End-of-turn work follows the controller state order: field conditions in
-- source order, then every mon condition for the current battler in source
-- order, then the field-extra states. Creation order cannot move a
-- native-known instance out of its phase.
function T.end_of_turn_phases_follow_controller_state_order()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  local bag = EffectBag.new()
  -- Deliberately reversed creation order: extras first, field last.
  addNative(bag, "trickroom", EffectFixture.fieldScope(), { version = 1, turns = 5 })
  addNative(bag, "perishsong", EffectFixture.activeScope(1, 1), { version = 1, turns = 5 })
  addNative(bag, "futuresight", EffectFixture.positionScope(1), {
    version = 1,
    turns = 3,
    damage = 10,
    move = "FUTURE_SIGHT",
    attacker = 2,
    activation = 1,
    turn = 0,
  })
  bag:add(
    testDefinition("burn", "affliction", "clear"),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )
  bag:add(
    testDefinition("poison", "affliction", "clear"),
    EffectFixture.activeScope(1, 1),
    EffectFixture.cause(2, 1),
    { version = 1 }
  )
  addNative(bag, "leechseed", EffectFixture.activeScope(1, 1), { version = 1 })
  addNative(bag, "ingrain", EffectFixture.activeScope(1, 1), { version = 1 })
  addNative(bag, "sandstorm", EffectFixture.fieldScope(), { version = 1, turns = 5 })
  addNative(bag, "wish", EffectFixture.positionScope(1), { version = 1, turns = 5 })
  addNative(bag, "reflect", EffectFixture.sideScope(1), { version = 1, turns = 5 })

  local keys = {
    "trickroom",
    "perishsong",
    "futuresight",
    "burn",
    "poison",
    "leechseed",
    "ingrain",
    "sandstorm",
    "wish",
    "reflect",
  }
  local dispatch = EffectDispatch.new(bag, recordingHandlers(keys))
  local context = EffectFixture.residualContext({ [1] = 70 }, { [1] = 100 }, 7)
  local outcome = Residuals.step(dispatch, context)
  Assert.isTrue(outcome.done, "the phased pass completes")
  Assert.deepEqual(eventKeys(outcome.events), {
    "reflect",
    "wish",
    "sandstorm",
    "ingrain",
    "leechseed",
    "poison",
    "burn",
    "futuresight",
    "perishsong",
    "trickroom",
  }, "field states precede mon states precede extra states in source order")
end

-- The mon phase nests by battler: the faster battler's recovery and
-- affliction both complete before the slower battler's, and a budgeted
-- run restored halfway emits exactly the unbounded sequence with no
-- duplicate tick.
function T.per_battler_nesting_and_resume_match_unbounded_run()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  ---@return table bag with recovery and affliction on two battlers
  local function buildBag()
    local bag = EffectBag.new()
    bag:add(
      testDefinition("leechseed", "affliction", "clear"),
      EffectFixture.activeScope(2, 1),
      EffectFixture.cause(1, 1),
      { version = 1 }
    )
    bag:add(
      testDefinition("leechseed", "affliction", "clear"),
      EffectFixture.activeScope(1, 1),
      EffectFixture.cause(2, 1),
      { version = 1 }
    )
    addNative(bag, "ingrain", EffectFixture.activeScope(2, 1), { version = 1 })
    addNative(bag, "ingrain", EffectFixture.activeScope(1, 1), { version = 1 })
    return bag
  end
  local handlers = {
    ingrain = function(instance, context)
      local combatant = instance.scope.combatant
      context.health[combatant] = context.health[combatant] + 2
      return { kind = "healed", key = "ingrain", combatant = combatant, restored = 2 }
    end,
    leechseed = function(instance, context)
      local combatant = instance.scope.combatant
      context.health[combatant] = context.health[combatant] - 4
      return { kind = "tick", key = "leechseed", combatant = combatant, amount = 4 }
    end,
  }
  local speeds = { [1] = 100, [2] = 50 }

  local whole = Residuals.step(
    EffectDispatch.new(buildBag(), handlers),
    EffectFixture.residualContext(speeds, { [1] = 100, [2] = 100 }, 7)
  )
  Assert.isTrue(whole.done, "the unbounded pass completes")
  Assert.deepEqual(
    EffectFixture.eventSignatures(whole.events),
    { "healed:1", "tick:1", "healed:2", "tick:2" },
    "the faster battler's mon sequence completes before the slower's"
  )

  local steppedDispatch = EffectDispatch.new(buildBag(), handlers)
  local steppedHealth = { [1] = 100, [2] = 100 }
  local stepped = {}
  local resume = nil
  while true do
    local context = EffectFixture.residualContext(speeds, steppedHealth, 7)
    context.resume = resume
    local outcome = Residuals.step(steppedDispatch, context, 1)
    Residuals.validateFrame(outcome.frame)
    for _, event in ipairs(outcome.events) do
      stepped[#stepped + 1] = event
    end
    if outcome.done then
      break
    end
    resume = outcome.frame
  end
  Assert.deepEqual(stepped, whole.events, "budgeted suspension preserves the nested sequence")

  local bag = buildBag()
  local dispatch = EffectDispatch.new(bag, handlers)
  local health = { [1] = 100, [2] = 100 }
  local firstContext = EffectFixture.residualContext(speeds, health, 7)
  local first = Residuals.step(dispatch, firstContext, 1)
  Assert.isFalse(first.done, "a unit budget suspends the nested pass")

  local revived = EffectBag.new(bag:capture())
  local resumedDispatch = EffectDispatch.new(revived, handlers)
  local tailHealth = { [1] = health[1], [2] = health[2] }
  local tail = {}
  for _, event in ipairs(first.events) do
    tail[#tail + 1] = event
  end
  local cursor = first.frame
  while cursor ~= nil do
    local probe = EffectFixture.residualContext(speeds, tailHealth, 7)
    probe.resume = cursor
    local outcome = Residuals.step(resumedDispatch, probe, 1)
    Residuals.validateFrame(outcome.frame)
    for _, event in ipairs(outcome.events) do
      tail[#tail + 1] = event
    end
    if outcome.done then
      break
    end
    SessionFixture.assertPlainData(outcome.frame, "frame")
    cursor = outcome.frame
  end
  Assert.deepEqual(tail, whole.events, "restore resumes the nested pass without repeating ticks")
  Assert.deepEqual(
    EffectFixture.eventSignatures(tail),
    { "healed:1", "tick:1", "healed:2", "tick:2" },
    "no mon tick runs twice across the restore"
  )
end

-- Instances without a native source slot trail every planned entry
-- deterministically: a native-looking category on an unknown key never
-- jumps ahead of a known field or mon state.
function T.unknown_extension_instances_trail_native_order()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  local bag = EffectBag.new()
  bag:add(
    testDefinition("customgadget", "weather", "clear"),
    EffectFixture.fieldScope(),
    EffectFixture.cause(1, 1),
    { version = 1 }
  )
  addNative(bag, "sandstorm", EffectFixture.fieldScope(), { version = 1, turns = 5 })
  addNative(bag, "leechseed", EffectFixture.activeScope(1, 1), { version = 1 })
  local dispatch = EffectDispatch.new(bag, recordingHandlers({ "customgadget", "sandstorm", "leechseed" }))
  local outcome = Residuals.step(dispatch, EffectFixture.residualContext({ [1] = 70 }, { [1] = 100 }, 7))
  Assert.isTrue(outcome.done, "the mixed pass completes")
  Assert.deepEqual(
    eventKeys(outcome.events),
    { "sandstorm", "leechseed", "customgadget" },
    "unknown extensions trail every native-known state"
  )
end

-- Weather, recovery, and affliction share one stable pass: reversed
-- registration collects identically and every instance fires exactly once.
function T.weather_recovery_and_affliction_share_one_stable_order()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  ---@param keys string[] insertion order for this bag
  ---@return table bag with one instance per key
  local function buildBag(keys)
    local bag = EffectBag.new()
    for _, key in ipairs(keys) do
      local scope = EffectFixture.activeScope(1, 1)
      if key == "sandstorm" then
        scope = EffectFixture.fieldScope()
      end
      local orderClass = "affliction"
      if key == "sandstorm" then
        orderClass = "weather"
      elseif key == "recovery" then
        orderClass = "recovery"
      end
      bag:add(testDefinition(key, orderClass, "clear"), scope, EffectFixture.cause(2, 1), { version = 1 })
    end
    return bag
  end
  local keys = { "sandstorm", "toxic", "recovery" }
  local handlers = { sandstorm = weatherDamage(2), toxic = fixedDamage(4), recovery = fixedRecovery(2) }
  local forward = EffectDispatch.new(buildBag(keys), handlers)
  local backward = EffectDispatch.new(buildBag({ keys[3], keys[2], keys[1] }), handlers)
  local context = function()
    return EffectFixture.residualContext({ [1] = 70 }, { [1] = 20 }, 7)
  end

  local function orderOf(dispatch)
    local entries = dispatch:collect("residual", context())
    local order = {}
    for _, entry in ipairs(entries) do
      order[#order + 1] = entry.instance.key
    end
    return order
  end
  Assert.deepEqual(orderOf(backward), orderOf(forward), "mixed categories ignore insertion order")

  local runContext = context()
  local outcome = Residuals.step(forward, runContext)
  Assert.isTrue(outcome.done, "the mixed pass completes")
  local fired = {}
  for _, event in ipairs(outcome.events) do
    fired[#fired + 1] = event.key
  end
  table.sort(fired)
  Assert.deepEqual(fired, { "recovery", "sandstorm", "toxic" }, "every category fires exactly once")
  Assert.equal(runContext.health[1], 16, "weather, affliction, and recovery all apply their ticks")
end

-- A suspended pass that loses its nested progress must fail instead of
-- replaying: dropping the dispatch continuation while health already
-- carries the committed heal resumes as a fresh pass today, healing
-- twice and emitting a duplicate tick.
function T.suspended_frames_without_nested_progress_fail_instead_of_replaying()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  ---@return table bag with one recovery and two afflictions across three battlers
  local function buildBag()
    local bag = EffectBag.new()
    bag:add(
      testDefinition("ingrain", "recovery", "clear"),
      EffectFixture.activeScope(1, 1),
      EffectFixture.cause(2, 1),
      { version = 1 }
    )
    for combatant = 2, 3 do
      bag:add(
        testDefinition("toxic", "affliction", "clear"),
        EffectFixture.activeScope(combatant, 1),
        EffectFixture.cause(1, 1),
        { version = 1 }
      )
    end
    return bag
  end
  local handlers = {
    ingrain = function(instance, context)
      local combatant = instance.scope.combatant
      context.health[combatant] = context.health[combatant] + 2
      return { kind = "healed", key = "ingrain", combatant = combatant, restored = 2 }
    end,
    toxic = fixedDamage(4),
  }
  local speeds = { [1] = 100, [2] = 50, [3] = 60 }

  local uninterrupted = Residuals.step(
    EffectDispatch.new(buildBag(), handlers),
    EffectFixture.residualContext(speeds, { [1] = 10, [2] = 20, [3] = 20 }, 7)
  )
  Assert.isTrue(uninterrupted.done, "the unbounded pass completes")
  Assert.deepEqual(
    EffectFixture.eventSignatures(uninterrupted.events),
    { "healed:1", "tick:3", "tick:2" },
    "recovery for the fastest battler commits before the afflictions"
  )

  local bag = buildBag()
  local dispatch = EffectDispatch.new(bag, handlers)
  local health = { [1] = 10, [2] = 20, [3] = 20 }
  local first = Residuals.step(dispatch, EffectFixture.residualContext(speeds, health, 7), 1)
  Assert.isFalse(first.done, "a unit budget suspends behind the committed heal")
  Assert.equal(health[1], 12, "the committed heal already lands in battle-local health")

  local revived = EffectBag.new(bag:capture())
  local resumedDispatch = EffectDispatch.new(revived, handlers)
  local resumedHealth = { [1] = health[1], [2] = health[2], [3] = health[3] }
  local forged = {
    kind = first.frame.kind,
    version = first.frame.version,
    checkpoint = nil,
    fainted = first.frame.fainted,
  }
  local forgedContext = EffectFixture.residualContext(speeds, resumedHealth, 7)
  forgedContext.resume = forged
  local ok = pcall(Residuals.step, resumedDispatch, forgedContext)
  Assert.isFalse(ok, "resuming without the nested progress fails instead of replaying the heal")
end

-- Foreign frames and future versions fail before running: the validator
-- names the identity and the version it understands, and a well-formed
-- frame still validates.
function T.foreign_frames_and_future_versions_fail_before_running()
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  Assert.throws(function()
    Residuals.validateFrame({ kind = "other:residuals", version = 1, checkpoint = nil, fainted = {} })
  end)
  Assert.throws(function()
    Residuals.validateFrame({ kind = Residuals.KIND, version = 9999, checkpoint = nil, fainted = {} })
  end)
  local frame = Residuals.validateFrame({ kind = Residuals.KIND, version = 1, checkpoint = nil, fainted = {} })
  Assert.equal(frame.version, 1, "the current version still validates")
end

-- Empty passes stay deterministic under any budget: unbounded and
-- stepwise runs agree exactly and repeat runs match event for event.
function T.empty_passes_stay_deterministic_under_any_budget()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")

  local speeds = { [1] = 100, [2] = 50 }
  local health = { [1] = 20, [2] = 20 }
  local function run()
    return Residuals.step(
      EffectDispatch.new(EffectBag.new(), {}),
      EffectFixture.residualContext(speeds, { [1] = health[1], [2] = health[2] }, 7)
    )
  end
  local first = run()
  local second = run()
  Assert.isTrue(first.done and second.done, "quiet passes complete")
  Assert.deepEqual(first.events, {}, "quiet passes emit nothing")
  Assert.deepEqual(second.events, first.events, "repeated quiet passes match exactly")
  Assert.deepEqual(second.frame, first.frame, "repeated quiet passes leave identical frames")

  local steppedDispatch = EffectDispatch.new(EffectBag.new(), {})
  local steppedHealth = { [1] = 20, [2] = 20 }
  local steppedContext = EffectFixture.residualContext(speeds, steppedHealth, 7)
  local stepped = Residuals.step(steppedDispatch, steppedContext, 1)
  Assert.isTrue(stepped.done, "a budgeted quiet pass still completes")
  Assert.deepEqual(stepped.events, first.events, "budgeted quiet passes match the unbounded run")
end

-- The native registries cover every residual family with well-formed
-- definitions: volatile branches on one side, weather, screens, hazards,
-- and delayed slot effects on the other.
function T.native_registries_cover_the_residual_families()
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local VolatileEffects = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.VolatileEffects",
    "grouped native volatile definitions own every source branch"
  )
  local FieldEffects = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.FieldEffects",
    "weather and field/side/position definitions own exact lifetimes"
  )
  local BattleBehaviorBuilder = SessionFixture.requirePresent(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration owns the public definition surface"
  )

  local behaviors = BattleBehaviorBuilder.new()
  VolatileEffects.register(behaviors, "residual-tests")
  FieldEffects.register(behaviors, "residual-tests")
  local bound = behaviors:freeze()

  ---@param keys string[] definition keys that must exist
  local function containsAll(keys)
    local present = {}
    for _, key in ipairs(bound:keys("effects")) do
      present[key] = true
    end
    for _, key in ipairs(keys) do
      Assert.isTrue(present[key], "the native inventory covers " .. key)
    end
    return present
  end
  local volatile = {
    "confusion",
    "infatuation",
    "flinch",
    "substitute",
    "leechseed",
    "curse",
    "perishsong",
    "encore",
    "disable",
    "taunt",
    "torment",
    "embargo",
    "healblock",
    "imprison",
  }
  local field = {
    "reflect",
    "lightscreen",
    "safeguard",
    "mist",
    "stealthrock",
    "spikes",
    "toxicspikes",
    "raindance",
    "sunnyday",
    "sandstorm",
    "hail",
    "gravity",
    "trickroom",
    "futuresight",
    "wish",
  }
  local present = containsAll(volatile)
  containsAll(field)
  Assert.isTrue(#bound:keys("effects") >= #volatile + #field, "the inventory carries at least its named families")

  for key in pairs(present) do
    local definition = bound:get("effects", key)
    Assert.isTrue(
      type(definition.stateVersion) == "number" and definition.stateVersion >= 1,
      key .. " versions its typed state"
    )
    Assert.isTrue(type(definition.validateState) == "function", key .. " validates its typed state")
    Assert.isTrue(type(definition.timings) == "table" and #definition.timings > 0, key .. " binds a timing")
    Assert.isTrue(type(definition.lifecycle) == "table", key .. " declares its lifecycle policy")
    for _, binding in ipairs(definition.timings) do
      local known = false
      for _, timing in ipairs(EffectFixture.TIMINGS) do
        if binding.timing == timing then
          known = true
        end
      end
      Assert.isTrue(known, key .. " binds only finite known timings")
    end
    Assert.isTrue(EffectDispatch.validateBindings(definition), key .. " passes binding validation")
  end
end

-- A mixed perish, weather, affliction, recovery, and live-ability pass
-- agrees exactly across every budget partition: the unbounded run and
-- every stepwise suspension, including one mid-pass save/restore through
-- a recaptured bag, emit the same events, health, faint order, final
-- frame, and labeled draw trace. The unit budget visits every partition
-- boundary, so identical stepwise output proves budgeted suspension and
-- snapshot restore never repeat completed work.
function T.mixed_residual_pass_matches_across_every_budget_partition()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")

  -- Two tied leaders force one labeled tie draw; the trailer carries the
  -- perish count, poison, and the live ability answer.
  local speeds = { [1] = 100, [2] = 100, [3] = 60 }

  ---@return table bag with weather, afflictions, recovery, and a perish count
  local function buildBag()
    local bag = EffectBag.new()
    bag:add(
      testDefinition("sandstorm", "weather", "clear"),
      EffectFixture.fieldScope(),
      EffectFixture.cause(1, 1),
      { version = 1 }
    )
    for combatant = 1, 2 do
      bag:add(
        testDefinition("toxic", "affliction", "clear"),
        EffectFixture.activeScope(combatant, 1),
        EffectFixture.cause(3, 1),
        { version = 1 }
      )
    end
    bag:add(
      testDefinition("poison", "affliction", "clear"),
      EffectFixture.activeScope(3, 1),
      EffectFixture.cause(1, 1),
      { version = 1 }
    )
    bag:add(
      testDefinition("perishsong", "expiration", "clear"),
      EffectFixture.activeScope(3, 1),
      EffectFixture.cause(1, 1),
      { version = 1, counter = 3 }
    )
    return bag
  end
  local handlers = {
    sandstorm = weatherDamage(2),
    toxic = fixedDamage(4),
    poison = fixedDamage(4),
    perishsong = perishCount(),
  }

  ---@return table live battler answers behind the ability, holding, and condition phases
  local function liveHooks()
    return {
      ability = function(combatant)
        if combatant ~= 3 then
          return nil
        end
        return { events = { { kind = "ability", key = "synchronize", combatant = combatant } } }
      end,
      heldItem = function(_)
        return nil
      end,
      leftovers = function(combatant)
        return { events = { { kind = "healed", key = "leftovers", combatant = combatant, restored = 0 } } }
      end,
      condition = function(_, _)
        return nil
      end,
    }
  end

  ---@param health table<integer, integer> battle-local health under the run
  ---@param log table[] draw entries in call order under the run
  ---@return table pass context over an observing labeled stream
  local function watchContext(health, log)
    local inner = BattleRng.new(7)
    local stream = {
      nextU16 = function(_, label, cause)
        local value = inner:nextU16(label, cause)
        log[#log + 1] = { label = label, value = value }
        return value
      end,
      capture = function(_)
        return inner:capture()
      end,
    }
    return { speeds = speeds, health = health, stream = stream, live = liveHooks() }
  end

  ---@param budget integer? committed phases each step may spend before yielding
  ---@param restore boolean true to recapture the bag behind the first suspension
  ---@return table run record with events, health, faints, frame, and draws
  local function runPass(budget, restore)
    local bag = buildBag()
    local dispatch = EffectDispatch.new(bag, handlers)
    local health = { [1] = 6, [2] = 6, [3] = 24 }
    local events = {}
    local draws = {}
    local resume = nil
    local restored = false
    while true do
      local context = watchContext(health, draws)
      context.resume = resume
      local outcome = Residuals.step(dispatch, context, budget)
      Residuals.validateFrame(outcome.frame)
      for _, event in ipairs(outcome.events) do
        events[#events + 1] = event
      end
      if outcome.done then
        local faints = {}
        for _, event in ipairs(events) do
          if event.kind == "faint" then
            faints[#faints + 1] = event.combatant
          end
        end
        return { events = events, health = health, faints = faints, frame = outcome.frame, draws = draws }
      end
      SessionFixture.assertPlainData(outcome.frame, "frame")
      if restore and not restored then
        restored = true
        bag = EffectBag.new(bag:capture())
        dispatch = EffectDispatch.new(bag, handlers)
      end
      resume = outcome.frame
    end
  end

  local whole = runPass(nil, false)
  Assert.isTrue(#whole.draws >= 1, "the tied leaders draw the labeled tie exactly once")
  Assert.equal(whole.draws[1].label, "residual_tie", "the pass draws only its documented tie label")
  Assert.deepEqual(whole.health, { [1] = 0, [2] = 0, [3] = 14 }, "weather and ticks land exactly once")
  Assert.equal(#whole.faints, 2, "both fainting holders settle")
  local expired = false
  local abilities = 0
  for _, event in ipairs(whole.events) do
    if event.key == "perishsong" then
      Assert.equal(event.kind, "tick", "the perish count ticks without expiring")
    end
    if event.kind == "expire" then
      expired = true
    end
    if event.kind == "ability" then
      abilities = abilities + 1
      Assert.equal(event.combatant, 3, "only the live ability holder answers")
    end
  end
  Assert.isFalse(expired, "the unexpired count never emits its expiration")
  Assert.equal(abilities, 1, "the live ability answers exactly once")

  local partitions = { runPass(1, false), runPass(2, false), runPass(5, false), runPass(2, true) }
  for index, part in ipairs(partitions) do
    local where = "partition " .. tostring(index) .. " matches the unbounded pass"
    Assert.deepEqual(part.events, whole.events, where .. " event for event")
    Assert.deepEqual(part.health, whole.health, where .. " in battle-local health")
    Assert.deepEqual(part.faints, whole.faints, where .. " in faint order")
    Assert.deepEqual(part.frame, whole.frame, where .. " in residual frame data")
    Assert.deepEqual(part.draws, whole.draws, where .. " in labeled draw trace")
  end
end

-- Foreign, nested-cursor, and impossibly-mapped resume frames fail closed
-- through the pass entry: resuming at a nonzero budget raises the
-- structured snapshot error before any handler runs or any draw is taken.
function T.resume_frames_fail_closed_before_handlers_or_draws()
  local EffectBag = bagOwner("scoped effect instances own their lifetimes")
  local EffectDispatch = dispatchOwner("finite timing dispatch owns collection and liveness")
  local Residuals = residualsOwner("native residual continuation owns phase and cursor structure")
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local BattleErrors =
    SessionFixture.requirePresent("libs.battle.src.errors", "structured battle errors classify rejected snapshots")

  -- Tied speeds force a labeled tie draw on a fresh pass, so zero draws
  -- on a failed resume is a real observation rather than a quiet setup.
  local speeds = { [1] = 100, [2] = 100 }
  local drain = fixedDamage(4)
  local calls = 0
  local handlers = {
    toxic = function(instance, context)
      calls = calls + 1
      return drain(instance, context)
    end,
  }
  local draws = 0

  ---@param health table<integer, integer> battle-local health under the attempt
  ---@param resume table? continuation under the attempt
  ---@return table pass context over a draw-counting labeled stream
  local function watchContext(health, resume)
    local inner = BattleRng.new(7)
    local stream = {
      nextU16 = function(_, label, cause)
        draws = draws + 1
        return inner:nextU16(label, cause)
      end,
      capture = function(_)
        return inner:capture()
      end,
    }
    return { speeds = speeds, health = health, stream = stream, resume = resume }
  end

  ---@return table bag with one affliction per combatant
  local function buildBag()
    local bag = EffectBag.new()
    for combatant = 1, 2 do
      bag:add(
        testDefinition("toxic", "affliction", "clear"),
        EffectFixture.activeScope(combatant, 1),
        EffectFixture.cause(3 - combatant, 1),
        { version = 1 }
      )
    end
    return bag
  end

  local bag = buildBag()
  local dispatch = EffectDispatch.new(bag, handlers)
  local suspended = Residuals.step(dispatch, watchContext({ [1] = 20, [2] = 20 }, nil), 1)
  Assert.isFalse(suspended.done, "a unit budget suspends behind committed work")
  Residuals.validateFrame(suspended.frame)
  calls = 0
  draws = 0

  ---@param resume table forged continuation under the attempt
  ---@param why string malformed family under the attempt
  local function checkFailsClosed(resume, why)
    calls = 0
    draws = 0
    local health = { [1] = 20, [2] = 20 }
    local ok, err = pcall(Residuals.step, dispatch, watchContext(health, resume), 2)
    Assert.isFalse(ok, why .. " fails instead of running")
    Assert.equal(type(err), "table", why .. " raises a structured error")
    Assert.equal(err.code, BattleErrors.INCOMPATIBLE_SNAPSHOT, why .. " keeps the snapshot error family")
    Assert.equal(calls, 0, why .. " never reaches a handler")
    Assert.equal(draws, 0, why .. " never takes an RNG draw")
  end

  checkFailsClosed({ kind = Residuals.KIND, version = 9999, checkpoint = nil, fainted = {} }, "a future version")
  local nested = {
    kind = suspended.frame.kind,
    version = suspended.frame.version,
    checkpoint = { cursor = suspended.frame.cursor },
    fainted = suspended.frame.fainted,
    battlers = suspended.frame.battlers,
    cursor = suspended.frame.cursor,
    battler = suspended.frame.battler,
    phase = suspended.frame.phase,
  }
  checkFailsClosed(nested, "a nested checkpoint cursor")
  local mapped = {
    kind = suspended.frame.kind,
    version = suspended.frame.version,
    checkpoint = suspended.frame.checkpoint,
    fainted = suspended.frame.fainted,
    battlers = suspended.frame.battlers,
    cursor = suspended.frame.cursor,
    battler = 99999,
    phase = suspended.frame.phase,
  }
  checkFailsClosed(mapped, "an impossible holder mapping")
end

return { tests = T }
