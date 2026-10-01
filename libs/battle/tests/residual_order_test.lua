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
  local context = EffectFixture.residualContext(
    { [1] = 100, [2] = 80, [3] = 60 },
    { [1] = 4, [2] = 4, [3] = 8 },
    7
  )

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
    { "tick:1", "expire:1", "faint:1", "tick:2" },
    "the final tick precedes expiration, faint, and the survivor's tick"
  )
  Assert.equal(context.health[2], 16, "the survivor still ticks after the faint")
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

return { tests = T }
