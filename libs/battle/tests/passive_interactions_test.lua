-- Ability interaction order follows the source: pressure charges once
-- per distinct foe on both ordinary and called paths, mold breaker opens
-- the immunity only for its own hit, natural cure cleans the canonical
-- condition on the way out while ordinary replacement keeps it, and
-- simultaneous weather entries resolve by sampled speed no matter how the
-- contributors were registered.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local EffectFixture = require("libs.battle.tests.effect_fixture")

local T = {}

local NATIVE_SEED = 11

---@param behavior string missing owner under test
---@return table<string, function> every native handler by source key
local function registeredHandlers(behavior)
  local NativePassives = SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.NativePassives", behavior)
  local handlers = {}
  NativePassives.register(handlers)
  return handlers
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
---@param orderClass string source mechanic category under test
---@param scope table owner scope under test
---@return table stored instance record
local function addBoundInstance(bag, key, timing, orderClass, scope)
  local definition = EffectFixture.define({
    key = key,
    timings = { { timing = timing, handler = key, orderClass = orderClass } },
  })
  return bag:add(definition, scope, EffectFixture.cause(1, 1), { version = 1 })
end

---@param events table[] emitted events under test
---@return integer total extra power points charged across the events
local function totalExtra(events)
  local total = 0
  for _, event in ipairs(events) do
    total = total + (event.extraPp or 0)
  end
  return total
end

-- One pressuring foe charges exactly one extra unit whether the move
-- spreads across several targets or arrives through a called path; two
-- pressuring foes charge two; a use avoiding every pressuring foe charges
-- nothing.
function T.pressure_charges_once_per_distinct_foe()
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  local handlers = registeredHandlers("native passive registration owns the ability and item binding set")

  local bag = EffectBag.new()
  addBoundInstance(bag, "PRESSURE", "beforeAction", "affliction", EffectFixture.activeScope(3, 1))
  local dispatch = EffectDispatch.new(bag, handlers)

  local spread =
    dispatch:invoke("beforeAction", dispatchContext({ moveUse = { user = 1, targets = { 2, 3 }, basePp = 10 } }))
  Assert.isTrue(spread.done, "the charging pass runs to completion")
  Assert.equal(#spread.events, 1, "one pressuring foe announces once across several targets")
  Assert.equal(spread.events[1].key, "PRESSURE", "the announcement carries its source identity")
  Assert.equal(totalExtra(spread.events), 1, "one pressuring foe charges one extra unit")

  local called = dispatch:invoke(
    "beforeAction",
    dispatchContext({ moveUse = { user = 1, targets = { 2, 3 }, basePp = 10, calledVia = "sleep-talk" } })
  )
  Assert.equal(#called.events, 1, "a called path still announces once")
  Assert.equal(totalExtra(called.events), 1, "a called path still charges one extra unit")

  local avoided =
    dispatch:invoke("beforeAction", dispatchContext({ moveUse = { user = 1, targets = { 2 }, basePp = 10 } }))
  Assert.deepEqual(avoided.events, {}, "a use avoiding every pressuring foe charges nothing")

  local crowded = EffectBag.new()
  addBoundInstance(crowded, "PRESSURE", "beforeAction", "affliction", EffectFixture.activeScope(2, 1))
  addBoundInstance(crowded, "PRESSURE", "beforeAction", "affliction", EffectFixture.activeScope(3, 1))
  local pairDispatch = EffectDispatch.new(crowded, handlers)
  local pair =
    pairDispatch:invoke("beforeAction", dispatchContext({ moveUse = { user = 1, targets = { 2, 3 }, basePp = 10 } }))
  Assert.equal(#pair.events, 2, "two pressuring foes announce once each")
  Assert.equal(totalExtra(pair.events), 2, "two pressuring foes charge one extra unit each")
end

-- Mold breaker opens the defender immunity for its own hit and nothing
-- else: the breaker hit announces suppression with no immunity event, the
-- following ordinary hit meets the immunity, and neither hit rewrites
-- battle state to fake the ordering.
function T.mold_breaker_suppresses_immunity_only_for_the_hit()
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  local handlers = registeredHandlers("native passive registration owns the ability and item binding set")

  local bag = EffectBag.new()
  addBoundInstance(bag, "MOLD_BREAKER", "beforeHit", "affliction", EffectFixture.activeScope(1, 1))
  addBoundInstance(bag, "LEVITATE", "beforeHit", "affliction", EffectFixture.activeScope(2, 1))
  local dispatch = EffectDispatch.new(bag, handlers)
  local settled = bag:capture()

  local opened = dispatch:invoke(
    "beforeHit",
    dispatchContext({ hit = { attacker = 1, defender = 2, moveType = "ground", attackerAbility = "MOLD_BREAKER" } })
  )
  Assert.isTrue(opened.done, "the breaker hit runs to completion")
  Assert.equal(#opened.events, 1, "the breaker hit emits only its suppression marker")
  Assert.equal(opened.events[1].key, "MOLD_BREAKER", "the marker carries its source identity")

  local warded = dispatch:invoke(
    "beforeHit",
    dispatchContext({ hit = { attacker = 1, defender = 2, moveType = "ground", attackerAbility = "STATIC" } })
  )
  Assert.equal(#warded.events, 1, "the ordinary hit meets exactly one response")
  Assert.equal(warded.events[1].key, "LEVITATE", "the ordinary hit meets the immunity")

  Assert.deepEqual(bag:capture(), settled, "suppression lives in the hit context, never in battle state")
end

-- Natural cure cleans the canonical condition on the way out: the leaving
-- pass announces the cure and empties the persistent record, the real
-- replacement then clears only activation state, and a holder without the
-- ability keeps its condition through the same replacement.
function T.natural_cure_cleans_the_canonical_condition_on_switch()
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  local Status =
    SessionFixture.requirePresent("libs.battle.src.gen4.Status", "native major status law owns replacement resets")
  local handlers = registeredHandlers("native passive registration owns the ability and item binding set")

  local mon = SessionFixture.makeMon(11)
  mon.ability = "NATURAL_CURE"
  local hpBefore = mon.condition.currentHp
  mon.condition.effects = { { key = "poison", version = 1, state = {} } }
  local bag = EffectBag.new()
  addBoundInstance(bag, "NATURAL_CURE", "leave", "affliction", EffectFixture.activeScope(1, 1))
  local dispatch = EffectDispatch.new(bag, handlers)

  local cured = dispatch:invoke("leave", dispatchContext({ mon = mon }))
  Assert.isTrue(cured.done, "the leaving pass runs to completion")
  Assert.equal(#cured.events, 1, "the cure announces exactly once")
  Assert.equal(cured.events[1].key, "NATURAL_CURE", "the announcement carries its source identity")
  Assert.deepEqual(mon.condition.effects, {}, "the cure empties the canonical condition")

  Status.switchReset(mon, bag, 1, 2)
  Assert.deepEqual(mon.condition.effects, {}, "replacement keeps the cured condition empty")
  Assert.equal(mon.condition.currentHp, hpBefore, "replacement never touches canonical health")
  Assert.deepEqual(bag:capture(), {}, "replacement clears the departing activation state")

  local plain = SessionFixture.makeMon(13)
  plain.ability = "STATIC"
  plain.condition.effects = { { key = "poison", version = 1, state = {} } }
  local stillBag = EffectBag.new()
  addBoundInstance(stillBag, "NATURAL_CURE", "leave", "affliction", EffectFixture.activeScope(2, 1))
  local stillDispatch = EffectDispatch.new(stillBag, handlers)
  local silent = stillDispatch:invoke("leave", dispatchContext({ mon = plain }))
  Assert.deepEqual(silent.events, {}, "a holder without the ability announces nothing")
  Status.switchReset(plain, stillBag, 2, 2)
  Assert.deepEqual(
    plain.condition.effects,
    { { key = "poison", version = 1, state = {} } },
    "ordinary replacement keeps the canonical condition"
  )
end

-- Simultaneous weather entries resolve by sampled speed with the slowest
-- holder's weather standing last, identically under both registration
-- orders: contributor order never breaks the tie.
function T.simultaneous_weather_follows_speed_not_registration_order()
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  local handlers = registeredHandlers("native passive registration owns the ability and item binding set")

  ---@param first string leading registration under test
  ---@param second string trailing registration under test
  ---@return table[] weather announcements in emission order
  local function announceInOrder(first, second)
    local bag = EffectBag.new()
    local scopes = { DRIZZLE = EffectFixture.activeScope(1, 1), DROUGHT = EffectFixture.activeScope(2, 1) }
    addBoundInstance(bag, first, "entry", "weather", scopes[first])
    addBoundInstance(bag, second, "entry", "weather", scopes[second])
    local dispatch = EffectDispatch.new(bag, handlers)
    local outcome = dispatch:invoke("entry", dispatchContext())
    Assert.isTrue(outcome.done, "the entry pass runs to completion")
    return outcome.events
  end

  local forward = announceInOrder("DRIZZLE", "DROUGHT")
  Assert.equal(#forward, 2, "both weather holders announce")
  Assert.equal(forward[1].key, "DRIZZLE", "the faster holder announces first")
  Assert.equal(forward[1].weather, "rain", "the faster announcement names its weather")
  Assert.equal(forward[2].key, "DROUGHT", "the slower holder announces last")
  Assert.equal(forward[2].weather, "sun", "the slower announcement names its weather")

  local backward = announceInOrder("DROUGHT", "DRIZZLE")
  Assert.deepEqual(backward, forward, "registration order never changes native entry order")
end

-- Boundaries: the holder's own use ignores its pressure, a berry fires
-- at exactly half health but not above it, and a hit-embedded
-- non-ground type leaves the ground immunity silent.
function T.passive_boundaries_hold_at_exact_thresholds()
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  local handlers = registeredHandlers("native passive registration owns the ability and item binding set")

  local selfBag = EffectBag.new()
  addBoundInstance(selfBag, "PRESSURE", "beforeAction", "affliction", EffectFixture.activeScope(1, 1))
  local selfDispatch = EffectDispatch.new(selfBag, handlers)
  local own =
    selfDispatch:invoke("beforeAction", dispatchContext({ moveUse = { user = 1, targets = { 2 }, basePp = 10 } }))
  Assert.deepEqual(own.events, {}, "the holder's own use charges nothing")

  local berryBag = EffectBag.new()
  addBoundInstance(berryBag, "SITRUS_BERRY", "residual", "recovery", EffectFixture.activeScope(1, 1))
  local berryDispatch = EffectDispatch.new(berryBag, handlers)
  local half = berryDispatch:invoke("residual", dispatchContext({ health = { [1] = 15, [2] = 30, [3] = 30 } }))
  Assert.equal(#half.events, 1, "exactly half health still eats the berry")
  Assert.equal(half.events[1].key, "SITRUS_BERRY", "the berry event carries its source identity")
  local above = berryDispatch:invoke("residual", dispatchContext({ health = { [1] = 16, [2] = 30, [3] = 30 } }))
  Assert.deepEqual(above.events, {}, "above half health keeps the berry")

  local guardBag = EffectBag.new()
  addBoundInstance(guardBag, "LEVITATE", "beforeHit", "affliction", EffectFixture.activeScope(2, 1))
  local guardDispatch = EffectDispatch.new(guardBag, handlers)
  local passing = guardDispatch:invoke(
    "beforeHit",
    dispatchContext({ hit = { attacker = 1, defender = 2, moveType = "fire", attackerAbility = "STATIC" } })
  )
  Assert.deepEqual(passing.events, {}, "a hit-embedded non-ground type stays silent")
end

return { tests = T }
