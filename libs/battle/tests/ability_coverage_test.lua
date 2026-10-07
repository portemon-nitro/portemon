-- Native ability and held-item behavior coverage: the full source binding
-- set resolves to executable handlers contributed by disjoint timing
-- families, an absent binding fails naming its identity through both the
-- registry check and the owned dispatch, handlers stay silent in
-- inapplicable contexts instead of looking unimplemented, and restoration
-- keeps consumed history distinct from live possession.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local EffectFixture = require("libs.battle.tests.effect_fixture")
local BattleSources = require("romdump.src.config.BattleSources")
local DomainErrors = require("libs.errors.src.Errors")

local T = {}

local NATIVE_SEED = 7

---@param behavior string missing owner under test
---@return table the loaded native passive registry
local function passiveRegistry(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.NativePassives", behavior)
end

---@return table<string, function> every native handler by source key
local function registeredHandlers()
  local NativePassives = passiveRegistry("native passive registration owns the ability and item binding set")
  local handlers = {}
  NativePassives.register(handlers)
  return handlers
end

---@param err unknown raised failure under test
---@param identity string source identity the failure must name
local function assertFailureNames(err, identity)
  if DomainErrors.is(err) then
    local context = (err --[[@as table]]).context
    if type(context) == "table" and (context.key == identity or context.identity == identity) then
      return
    end
  end
  local text = tostring(err)
  Assert.isTrue(text:find(identity, 1, true) ~= nil, "the failure names " .. identity .. ", got: " .. text)
end

---@return string[] sorted usable ability keys without the sentinel
local function usableAbilities()
  local keys = {}
  for key in pairs(BattleSources.abilityBindings) do
    if key ~= "NONE" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  return keys
end

---@param class string inventory binding class under test
---@return boolean true for bindings that can never attach to a combatant
local function neverHeld(class)
  return class == "ball" or class == "no_hold"
end

---@param extras table<string, unknown>|nil behavior inputs under test
---@return table dispatch context over fixed speeds, health, and random state
local function dispatchContext(extras)
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local context = {
    speeds = { [1] = 100, [2] = 80, [3] = 60 },
    health = { [1] = 30, [2] = 30, [3] = 30 },
    maxHealth = { [1] = 30, [2] = 30, [3] = 30 },
    stream = BattleRng.new(NATIVE_SEED),
  }
  if extras ~= nil then
    for key, value in pairs(extras) do
      context[key] = value
    end
  end
  return context
end

---@param bag table scoped instance owner under test
---@param key string effect identity under test
---@param timing string mechanics timing under test
---@param scope table owner scope under test
---@return table stored instance record
local function addBoundInstance(bag, key, timing, scope)
  local orderClass = "affliction"
  if timing == "entry" then
    orderClass = "weather"
  end
  local definition = EffectFixture.define({
    key = key,
    timings = { { timing = timing, handler = key, orderClass = orderClass } },
  })
  return bag:add(definition, scope, EffectFixture.cause(1, 1), { version = 1 })
end

---@param events table[] emitted events under test
---@param key string expected source identity
---@param combatant integer expected affected combatant
local function assertSingleEvent(events, key, combatant)
  Assert.equal(#events, 1, "exactly one event fires for " .. key)
  local event = events[1]
  Assert.equal(event.key, key, "the event carries its source identity")
  Assert.equal(event.combatant, combatant, "the event names its affected combatant")
end

-- Timing families each bind a nonempty handler set, sets never overlap, and
-- their union is exactly the native registration: behavior lives in grouped
-- timing owners rather than one shared switch, with no silent gaps.
function T.families_contribute_disjoint_handler_sets_without_a_single_switch()
  local NativePassives = passiveRegistry("native passive registration owns the ability and item binding set")
  local families = {
    {
      name = "entry abilities own source entry timing",
      path = "libs.battle.src.gen4.behaviors.abilities.EntryAbilities",
    },
    {
      name = "modifier abilities own arithmetic checkpoints",
      path = "libs.battle.src.gen4.behaviors.abilities.ModifierAbilities",
    },
    {
      name = "reactive abilities own action and turn responses",
      path = "libs.battle.src.gen4.behaviors.abilities.ReactiveAbilities",
    },
    { name = "passive items own held modifiers", path = "libs.battle.src.gen4.behaviors.items.PassiveItems" },
    { name = "triggered items own consumable responses", path = "libs.battle.src.gen4.behaviors.items.TriggeredItems" },
  }
  local union = {}
  local unionCount = 0
  for _, family in ipairs(families) do
    local owner = SessionFixture.requirePresent(family.path, family.name)
    Assert.equal(type(owner.register), "function", family.name .. " exposes its registration")
    local owned = {}
    owner.register(owned)
    local count = 0
    for key, handler in pairs(owned) do
      Assert.equal(type(handler), "function", family.name .. " binds executable handlers: " .. tostring(key))
      Assert.isNil(union[key], "native bindings have exactly one family owner: " .. tostring(key))
      union[key] = handler
      count = count + 1
    end
    Assert.isTrue(count > 0, family.name .. " binds its timing responsibility")
    unionCount = unionCount + count
  end
  local combined = {}
  NativePassives.register(combined)
  local combinedKeys = {}
  for key in pairs(combined) do
    combinedKeys[#combinedKeys + 1] = key
  end
  Assert.equal(#combinedKeys, unionCount, "the native registration is exactly the family union")
  for key in pairs(union) do
    Assert.equal(type(combined[key]), "function", "the native registration keeps the family binding: " .. tostring(key))
  end
end

-- Every usable source ability resolves through the registry check and owns
-- an executable handler: nothing usable is left unbound.
function T.every_source_ability_resolves_to_an_executable_handler()
  local NativePassives = passiveRegistry("native passive registration owns the ability and item binding set")
  local handlers = registeredHandlers()
  Assert.isTrue(NativePassives.assertCoverage(handlers, BattleSources))
  local missing = {}
  for _, key in ipairs(usableAbilities()) do
    if type(handlers[key]) ~= "function" then
      missing[#missing + 1] = key
    end
  end
  Assert.deepEqual(missing, {}, "every source ability resolves to an executable handler")
end

-- Every holdable item resolves while balls and mail stay explicitly
-- unheld: an instance naming an unheld key fails loudly through the owned
-- dispatch instead of running a silent fallback.
function T.every_holdable_item_resolves_while_balls_and_mail_stay_unheld()
  local NativePassives = passiveRegistry("native passive registration owns the ability and item binding set")
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  local handlers = registeredHandlers()
  Assert.isTrue(NativePassives.assertCoverage(handlers, BattleSources))
  local missing = {}
  for key, binding in pairs(BattleSources.heldItemBindings) do
    assert(type(binding) == "table", "held bindings carry their class record")
    local class = (binding --[[@as table]]).key
    if neverHeld(class) then
      Assert.isNil(handlers[key], "unheld bindings stay unbound: " .. tostring(key))
    elseif type(handlers[key]) ~= "function" then
      missing[#missing + 1] = key
    end
  end
  table.sort(missing)
  Assert.deepEqual(missing, {}, "every holdable item resolves to an executable handler")

  local bag = EffectBag.new()
  addBoundInstance(bag, "POKE_BALL", "residual", EffectFixture.activeScope(1, 1))
  local dispatch = EffectDispatch.new(bag, handlers)
  local err = Assert.throws(function()
    dispatch:invoke("residual", dispatchContext())
  end)
  assertFailureNames(err, "POKE_BALL")
end

-- Removing one ability binding fails the registry check naming exactly
-- that identity: the setup from the previous test still passes untouched.
function T.absent_ability_binding_fails_naming_its_identity()
  local NativePassives = passiveRegistry("native passive registration owns the ability and item binding set")
  local handlers = registeredHandlers()
  Assert.isTrue(NativePassives.assertCoverage(handlers, BattleSources))
  local broken = { abilityBindings = {}, heldItemBindings = BattleSources.heldItemBindings }
  for key, binding in pairs(BattleSources.abilityBindings) do
    if key ~= "STENCH" then
      broken.abilityBindings[key] = binding
    end
  end
  Assert.notNil(BattleSources.abilityBindings["STENCH"], "the source inventory carries the pruned binding")
  Assert.isNil(broken.abilityBindings["STENCH"], "the pruned inventory drops only its target")
  local err = Assert.throws(function()
    NativePassives.assertCoverage(handlers, broken)
  end)
  assertFailureNames(err, "STENCH")
end

-- Removing one held-item binding fails the registry check naming exactly
-- that identity.
function T.absent_item_binding_fails_naming_its_identity()
  local NativePassives = passiveRegistry("native passive registration owns the ability and item binding set")
  local handlers = registeredHandlers()
  Assert.isTrue(NativePassives.assertCoverage(handlers, BattleSources))
  local broken = { abilityBindings = BattleSources.abilityBindings, heldItemBindings = {} }
  for key, binding in pairs(BattleSources.heldItemBindings) do
    if key ~= "LEFTOVERS" then
      broken.heldItemBindings[key] = binding
    end
  end
  local err = Assert.throws(function()
    NativePassives.assertCoverage(handlers, broken)
  end)
  assertFailureNames(err, "LEFTOVERS")
end

-- Entry and modifier handlers announce in their applicable context and
-- stay silent when suppressed or inapplicable: silence is a real outcome,
-- never a missing binding.
function T.entry_and_modifier_handlers_announce_then_stay_silent_when_inapplicable()
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  local handlers = registeredHandlers()

  local entryBag = EffectBag.new()
  local herald = addBoundInstance(entryBag, "INTIMIDATE", "entry", EffectFixture.activeScope(1, 1))
  local entryDispatch = EffectDispatch.new(entryBag, handlers)
  local announced = entryDispatch:invoke("entry", dispatchContext())
  Assert.isTrue(announced.done, "the entry pass runs to completion")
  assertSingleEvent(announced.events, "INTIMIDATE", 1)

  local gagged = entryDispatch:invoke("entry", dispatchContext({ suppressedIds = { [herald.id] = true } }))
  Assert.isTrue(gagged.done, "a suppressed pass still completes")
  Assert.deepEqual(gagged.events, {}, "suppression silences the handler without unbinding it")

  local guardBag = EffectBag.new()
  addBoundInstance(guardBag, "LEVITATE", "beforeHit", EffectFixture.activeScope(2, 1))
  local guardDispatch = EffectDispatch.new(guardBag, handlers)
  local immune = guardDispatch:invoke("beforeHit", dispatchContext({ moveType = "ground" }))
  assertSingleEvent(immune.events, "LEVITATE", 2)
  local passing = guardDispatch:invoke("beforeHit", dispatchContext({ moveType = "fire" }))
  Assert.deepEqual(passing.events, {}, "an inapplicable immunity stays silent without failing")
end

-- Reactive and triggered handlers fire on their trigger and stay silent
-- otherwise, for both abilities and held items.
function T.reactive_and_triggered_handlers_fire_then_stay_silent_when_inapplicable()
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  local handlers = registeredHandlers()

  local sparkBag = EffectBag.new()
  addBoundInstance(sparkBag, "STATIC", "afterHit", EffectFixture.activeScope(2, 1))
  local sparkDispatch = EffectDispatch.new(sparkBag, handlers)
  local sparked = sparkDispatch:invoke("afterHit", dispatchContext({ contact = true }))
  assertSingleEvent(sparked.events, "STATIC", 2)
  local untouched = sparkDispatch:invoke("afterHit", dispatchContext({ contact = false }))
  Assert.deepEqual(untouched.events, {}, "a non-contact hit stays silent without failing")

  local crumbBag = EffectBag.new()
  addBoundInstance(crumbBag, "LEFTOVERS", "residual", EffectFixture.activeScope(2, 1))
  local crumbDispatch = EffectDispatch.new(crumbBag, handlers)
  local crumbs = { [1] = 30, [2] = 10, [3] = 30 }
  local recovering = crumbDispatch:invoke("residual", dispatchContext({ health = crumbs }))
  assertSingleEvent(recovering.events, "LEFTOVERS", 2)
  local full = crumbDispatch:invoke("residual", dispatchContext())
  Assert.deepEqual(full.events, {}, "full health stays silent without failing")

  local berryBag = EffectBag.new()
  addBoundInstance(berryBag, "SITRUS_BERRY", "residual", EffectFixture.activeScope(3, 1))
  local berryDispatch = EffectDispatch.new(berryBag, handlers)
  local low = { [1] = 30, [2] = 30, [3] = 10 }
  local eaten = berryDispatch:invoke("residual", dispatchContext({ health = low }))
  assertSingleEvent(eaten.events, "SITRUS_BERRY", 3)
  local healthy = berryDispatch:invoke("residual", dispatchContext())
  Assert.deepEqual(healthy.events, {}, "a healthy holder keeps its berry without failing")
end

-- Restoration distinguishes consequence history from live possession: a
-- restoring policy brings the consumed item back while keeping the
-- consumption on record, and a nonrestoring policy leaves possession empty
-- with the same history.
function T.restoration_keeps_consumed_history_distinct_from_live_possession()
  local HeldItems = SessionFixture.requirePresent(
    "libs.battle.src.gen4.HeldItems",
    "held-item state owns possession and consequence history"
  )
  local restoring = {
    original = "SITRUS_BERRY",
    current = "SITRUS_BERRY",
    originalOwner = 1,
    consumed = {},
    knockedOff = false,
    suppressed = false,
    transfers = {},
  }
  HeldItems.consume(restoring, EffectFixture.cause(2, 1))
  Assert.isNil(HeldItems.effective(restoring), "a consumed berry stops applying")
  Assert.deepEqual(restoring.consumed, { "SITRUS_BERRY" }, "consumption stays on record")
  HeldItems.restore(restoring, "restoring")
  Assert.equal(HeldItems.effective(restoring), "SITRUS_BERRY", "a restoring policy brings the berry back")
  Assert.deepEqual(restoring.consumed, { "SITRUS_BERRY" }, "restoration never rewrites consequence history")

  local lasting = {
    original = "SITRUS_BERRY",
    current = "SITRUS_BERRY",
    originalOwner = 1,
    consumed = {},
    knockedOff = false,
    suppressed = false,
    transfers = {},
  }
  HeldItems.consume(lasting, EffectFixture.cause(2, 1))
  HeldItems.restore(lasting, "nonrestoring")
  Assert.isNil(HeldItems.effective(lasting), "a nonrestoring policy leaves possession empty")
  Assert.deepEqual(lasting.consumed, { "SITRUS_BERRY" }, "the nonrestoring history matches the restoring one")
end

-- The registry check also guards its inputs: an inventory without the
-- binding tables fails as invalid state, an inventory entry without a
-- handler fails naming that entry, and a handler naming nothing in the
-- inventory fails naming the extra key.
function T.coverage_rejects_malformed_inventories_and_unknown_handlers()
  local NativePassives = passiveRegistry("native passive registration owns the ability and item binding set")
  local handlers = registeredHandlers()

  local shapeless = Assert.throws(function()
    NativePassives.assertCoverage(handlers, {})
  end)
  Assert.isTrue(DomainErrors.is(shapeless), "a shapeless inventory fails as invalid state")

  local small = { abilityBindings = { FOO_ABILITY = { key = "held" } }, heldItemBindings = {} }
  local absent = Assert.throws(function()
    NativePassives.assertCoverage(handlers, small)
  end)
  assertFailureNames(absent, "FOO_ABILITY")

  local extra = { STATIC = handlers.STATIC, FOO_EXTRA = handlers.STATIC }
  local tiny = { abilityBindings = { STATIC = { key = "ability_static" } }, heldItemBindings = {} }
  Assert.isTrue(NativePassives.assertCoverage({ STATIC = handlers.STATIC }, tiny), "the tiny inventory resolves")
  local unknown = Assert.throws(function()
    NativePassives.assertCoverage(extra, tiny)
  end)
  assertFailureNames(unknown, "FOO_EXTRA")
end

return { tests = T }
