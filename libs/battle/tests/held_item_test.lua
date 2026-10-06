-- Held-item possession and consequence history: transfers move the live
-- effect without copying the item, knocked-off items stay off the field
-- through every restoration policy, consumed berries keep their history
-- for later use under a restoring policy only, choice possession survives
-- replacement, and finalizing never duplicates or deletes outside history.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local EffectFixture = require("libs.battle.tests.effect_fixture")

local T = {}

local NATIVE_SEED = 11

---@param behavior string missing owner under test
---@return table<string, function> every native passive handler by source key
local function nativeHandlers(behavior)
  local NativePassives = SessionFixture.requirePresent("libs.battle.src.gen4.behaviors.NativePassives", behavior)
  local handlers = {}
  NativePassives.register(handlers)
  return handlers
end

---@param key string effect identity under test
---@param timing string mechanics timing under test
---@param scope table owner scope under test
---@return table bag holding the bound instance
local function bagWith(key, timing, scope)
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local bag = EffectBag.new()
  local definition = EffectFixture.define({
    key = key,
    timings = { { timing = timing, handler = key, orderClass = "affliction" } },
  })
  bag:add(definition, scope, EffectFixture.cause(1, 1), { version = 1 })
  return bag
end

---@param bag table scoped instance owner under test
---@param handlers table<string, function> registered native handlers under test
---@param timing string mechanics timing under test
---@param context table<string, unknown> dispatch context under test
---@return table dispatch outcome for the timing
local function runPassive(bag, handlers, timing, context)
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "finite timing dispatch owns collection and liveness"
  )
  return EffectDispatch.new(bag, handlers):invoke(timing, context)
end

---@param extras table<string, unknown>? behavior inputs under test
---@return table dispatch context over fixed speeds, health, and random state
local function passiveContext(extras)
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

---@param behavior string missing owner under test
---@return table the loaded held-item state owner
local function heldItems(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.HeldItems", behavior)
end

---@param owner integer combatant holding the item under test
---@param item string held item key under test
---@return table fresh history record with possession and empty consequences
local function historyFor(owner, item)
  return {
    original = item,
    current = item,
    originalOwner = owner,
    consumed = {},
    knockedOff = false,
    suppressed = false,
    transfers = {},
  }
end

---@param records table[] history records under test
---@return table<string, integer> live holdings per item key
local function liveHoldings(records, HeldItems)
  local holdings = {}
  for _, record in ipairs(records) do
    local held = HeldItems.effective(record)
    if held ~= nil then
      holdings[held] = (holdings[held] or 0) + 1
    end
  end
  return holdings
end

-- A swap moves possession and the live effect to the new holders: each
-- item exists exactly once across both records while both originals and
-- both transfer entries stay on record.
function T.trick_moves_possession_and_effect_without_copying_the_item()
  local HeldItems = heldItems("held-item state owns possession and consequence history")
  local first = historyFor(1, "CHOICE_BAND")
  local second = historyFor(2, "LEFTOVERS")

  HeldItems.transfer(first, second, EffectFixture.cause(1, 1))

  Assert.equal(HeldItems.effective(first), "LEFTOVERS", "the first holder now applies the swapped item")
  Assert.equal(HeldItems.effective(second), "CHOICE_BAND", "the second holder now applies the swapped item")
  Assert.deepEqual(
    liveHoldings({ first, second }, HeldItems),
    { LEFTOVERS = 1, CHOICE_BAND = 1 },
    "the swap copies neither item"
  )
  Assert.equal(first.original, "CHOICE_BAND", "the first original stays anchored")
  Assert.equal(second.original, "LEFTOVERS", "the second original stays anchored")
  Assert.equal(#first.transfers, 1, "the first record keeps its transfer entry")
  Assert.equal(#second.transfers, 1, "the second record keeps its transfer entry")
end

-- Knocked-off items stop applying, are not recorded as consumed, and no
-- restoration policy brings them back: the provenance stays readable while
-- the field stays empty.
function T.knock_off_suppresses_the_effect_and_survives_finalize()
  local HeldItems = heldItems("held-item state owns possession and consequence history")
  local record = historyFor(2, "ORAN_BERRY")

  HeldItems.knockOff(record, EffectFixture.cause(1, 1))

  Assert.isNil(HeldItems.effective(record), "a knocked-off item stops applying")
  Assert.isTrue(record.knockedOff, "the removal stays on record")
  Assert.deepEqual(record.consumed, {}, "a knocked-off item is not recorded as consumed")

  HeldItems.restore(record, "restoring")
  Assert.isNil(HeldItems.effective(record), "a restoring policy never revives knocked-off items")
  HeldItems.restore(record, "nonrestoring")
  Assert.isNil(HeldItems.effective(record), "a nonrestoring policy never revives knocked-off items")
  Assert.equal(record.original, "ORAN_BERRY", "the provenance survives every policy")
end

-- Berry consumption empties live possession while keeping the berry on
-- record; the restoring policy brings it back for later use and the
-- nonrestoring policy leaves the field empty with identical history.
function T.berry_consumption_leaves_recycle_history_and_restores_by_policy()
  local HeldItems = heldItems("held-item state owns possession and consequence history")

  local recycled = historyFor(1, "SITRUS_BERRY")
  HeldItems.consume(recycled, EffectFixture.cause(2, 1))
  Assert.isNil(HeldItems.effective(recycled), "a consumed berry stops applying")
  Assert.deepEqual(recycled.consumed, { "SITRUS_BERRY" }, "consumption stays on record")
  HeldItems.restore(recycled, "restoring")
  Assert.equal(HeldItems.effective(recycled), "SITRUS_BERRY", "a restoring policy returns the berry to the holder")
  Assert.deepEqual(recycled.consumed, { "SITRUS_BERRY" }, "later use keeps the earlier consumption on record")

  local spent = historyFor(1, "SITRUS_BERRY")
  HeldItems.consume(spent, EffectFixture.cause(2, 1))
  HeldItems.restore(spent, "nonrestoring")
  Assert.isNil(HeldItems.effective(spent), "a nonrestoring policy leaves the holder empty")
  Assert.deepEqual(spent.consumed, { "SITRUS_BERRY" }, "the nonrestoring history matches the restoring one")
end

-- Choice possession survives the activation turnover that replacement
-- publishes: the same history still applies after the real effect owner
-- clears the departing activation state.
function T.choice_possession_survives_replacement_without_duplication()
  local HeldItems = heldItems("held-item state owns possession and consequence history")
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local Status =
    SessionFixture.requirePresent("libs.battle.src.gen4.Status", "native major status law owns replacement resets")

  local record = historyFor(1, "CHOICE_BAND")
  local mon = SessionFixture.makeMon(11)
  local bag = EffectBag.new()
  Status.switchReset(mon, bag, 1, 2)

  Assert.equal(HeldItems.effective(record), "CHOICE_BAND", "replacement keeps applying the choice item")
  Assert.equal(record.original, "CHOICE_BAND", "replacement keeps the original anchored")
  Assert.deepEqual(record.consumed, {}, "replacement consumes nothing")
  Assert.deepEqual(record.transfers, {}, "replacement transfers nothing")
  Assert.deepEqual(bag:capture(), {}, "the departing activation keeps no battle state")
end

-- A full sequence of swap, consumption, and removal finalizes with exact
-- ownership: live items never duplicate, knocked-off items never return,
-- and every consequence stays readable per record.
function T.finalize_never_duplicates_or_deletes_outside_history()
  local HeldItems = heldItems("held-item state owns possession and consequence history")
  local first = historyFor(1, "LEFTOVERS")
  local second = historyFor(2, "SITRUS_BERRY")
  local third = historyFor(3, "CHOICE_BAND")

  HeldItems.transfer(first, second, EffectFixture.cause(1, 1))
  HeldItems.consume(first, EffectFixture.cause(2, 1))
  HeldItems.knockOff(third, EffectFixture.cause(1, 1))

  for _, record in ipairs({ first, second, third }) do
    HeldItems.restore(record, "restoring")
  end

  Assert.equal(HeldItems.effective(first), "SITRUS_BERRY", "the consumed berry returns to its holder")
  Assert.equal(HeldItems.effective(second), "LEFTOVERS", "the swapped item stays with its holder")
  Assert.isNil(HeldItems.effective(third), "the knocked-off item never returns")
  Assert.deepEqual(
    liveHoldings({ first, second, third }, HeldItems),
    { SITRUS_BERRY = 1, LEFTOVERS = 1 },
    "finalizing duplicates no live item"
  )
  Assert.deepEqual(first.consumed, { "SITRUS_BERRY" }, "the berry consumption stays on record")
  Assert.deepEqual(second.consumed, {}, "the untouched swap consumes nothing")
  Assert.isTrue(third.knockedOff, "the removal stays on record")
  Assert.equal(third.original, "CHOICE_BAND", "the removed provenance is never deleted")
end

-- Suppression silences the live effect without consuming, removing, or
-- rewriting provenance; spending an empty holder and restoring a holder
-- that never spent are no-ops; an unknown restoration policy fails.
function T.suppression_and_empty_holders_stay_stable()
  local HeldItems = heldItems("held-item state owns possession and consequence history")

  local gagged = historyFor(1, "LEFTOVERS")
  gagged.suppressed = true
  Assert.isNil(HeldItems.effective(gagged), "a suppressed item stops applying")
  Assert.equal(gagged.original, "LEFTOVERS", "suppression keeps the provenance anchored")
  Assert.deepEqual(gagged.consumed, {}, "suppression consumes nothing")
  gagged.suppressed = false
  Assert.equal(HeldItems.effective(gagged), "LEFTOVERS", "lifting suppression restores the effect")

  local empty = historyFor(2, "SITRUS_BERRY")
  empty.current = nil
  Assert.isFalse(HeldItems.consume(empty, EffectFixture.cause(1, 1)), "spending an empty holder reports no work")
  Assert.deepEqual(empty.consumed, {}, "spending an empty holder records nothing")
  Assert.isFalse(HeldItems.restore(empty, "restoring"), "restoring a never-spent holder refills nothing")
  Assert.isNil(HeldItems.effective(empty), "the never-spent holder stays empty")

  local policy = Assert.throws(function()
    HeldItems.restore(historyFor(3, "ORAN_BERRY"), "sometimes")
  end)
  Assert.isTrue(tostring(policy):find("policy", 1, true) ~= nil, "an unknown policy fails naming the policy")
end

-- Berry HP families split by their native gate: the confuse-healing
-- flavor berries answer at half health while the stat-pinch family
-- keeps its quarter-health gate.
function T.flavor_berries_trigger_at_half_health_while_stat_pinch_keeps_its_quarter_gate()
  local handlers = nativeHandlers("native passive registration owns the berry binding set")

  ---@param key string berry identity under test
  ---@param hp integer holder health under test
  ---@return table[] emitted trigger events for the pass
  local function firedAt(key, hp)
    local bag = bagWith(key, "residual", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(
      bag,
      handlers,
      "residual",
      passiveContext({ health = { [1] = hp, [2] = 30, [3] = 30 }, maxHealth = { [1] = 100, [2] = 30, [3] = 30 } })
    )
    Assert.isTrue(outcome.done, "the berry pass runs to completion")
    return outcome.events
  end

  Assert.deepEqual(firedAt("FIGY_BERRY", 51), {}, "the flavor berry stays silent above half health")
  Assert.equal(#firedAt("FIGY_BERRY", 50), 1, "the flavor berry answers at exactly half health")
  Assert.equal(#firedAt("FIGY_BERRY", 25), 1, "the flavor berry answers below half health")
  Assert.deepEqual(firedAt("LIECHI_BERRY", 50), {}, "the stat berry stays silent at half health")
  Assert.deepEqual(firedAt("LIECHI_BERRY", 26), {}, "the stat berry stays silent above a quarter")
  Assert.equal(#firedAt("LIECHI_BERRY", 25), 1, "the stat berry answers at exactly a quarter")
end

-- Gluttony halves only the quarter-health pinch divisor: stat, accuracy,
-- and priority pinch berries become eligible at half health under
-- Gluttony while the flavor family answers identically either way.
function T.gluttony_halves_only_the_quarter_pinch_divisor()
  local handlers = nativeHandlers("native passive registration owns the berry binding set")

  ---@param key string berry identity under test
  ---@param hp integer holder health under test
  ---@param ability string holder ability carried by the context
  ---@param extra table<string, unknown>? timing-specific context facts under test
  ---@param timing string mechanics timing under test
  ---@return table[] emitted trigger events for the pass
  local function firedWith(key, hp, ability, extra, timing)
    local bag = bagWith(key, timing, EffectFixture.activeScope(1, 1))
    local context = passiveContext({
      health = { [1] = hp, [2] = 30, [3] = 30 },
      maxHealth = { [1] = 100, [2] = 30, [3] = 30 },
      ability = ability,
    })
    if extra ~= nil then
      for name, value in pairs(extra) do
        context[name] = value
      end
    end
    local outcome = runPassive(bag, handlers, timing, context)
    Assert.isTrue(outcome.done, "the berry pass runs to completion")
    return outcome.events
  end

  Assert.equal(
    #firedWith("LIECHI_BERRY", 50, "GLUTTONY", nil, "residual"),
    1,
    "the stat berry answers at half health under Gluttony"
  )
  Assert.deepEqual(
    firedWith("LIECHI_BERRY", 50, "STATIC", nil, "residual"),
    {},
    "the stat berry stays silent at half health without Gluttony"
  )
  Assert.equal(
    #firedWith("FIGY_BERRY", 50, "GLUTTONY", nil, "residual"),
    1,
    "the flavor berry answers at half health under Gluttony"
  )
  Assert.equal(
    #firedWith("FIGY_BERRY", 50, "STATIC", nil, "residual"),
    1,
    "the flavor berry answers at half health without Gluttony"
  )
  Assert.equal(
    #firedWith("MICLE_BERRY", 50, "GLUTTONY", nil, "residual"),
    1,
    "the accuracy berry answers at half health under Gluttony"
  )
  Assert.deepEqual(
    firedWith("MICLE_BERRY", 50, "STATIC", nil, "residual"),
    {},
    "the accuracy berry stays silent at half health without Gluttony"
  )
  Assert.equal(
    #firedWith("CUSTAP_BERRY", 50, "GLUTTONY", { moveUse = { user = 1 } }, "beforeAction"),
    1,
    "the priority berry answers at half health under Gluttony"
  )
  Assert.deepEqual(
    firedWith("CUSTAP_BERRY", 50, "STATIC", { moveUse = { user = 1 } }, "beforeAction"),
    {},
    "the priority berry stays silent at half health without Gluttony"
  )
end

-- Species-locked held items apply only to their native holders: valid
-- species emit the existing boost while invalid holders stay silent,
-- including a transformed Giratina, and generic boosters are unaffected.
function T.species_locked_items_stay_silent_for_invalid_holders()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param key string item identity under test
  ---@param timing string mechanics timing under test
  ---@param facts table<string, unknown> holder and checkpoint facts under test
  ---@return table[] emitted boost events for the pass
  local function boosted(key, timing, facts)
    local bag = bagWith(key, timing, EffectFixture.activeScope(1, 1))
    local context = passiveContext(facts)
    local outcome = runPassive(bag, handlers, timing, context)
    Assert.isTrue(outcome.done, "the item pass runs to completion")
    return outcome.events
  end

  local cases = {
    {
      item = "SOUL_DEW",
      timing = "modifyStat",
      facts = { stat = "specialAttack" },
      valid = { "LATIAS", "LATIOS" },
      invalid = { "PIKACHU" },
    },
    {
      item = "LIGHT_BALL",
      timing = "modifyStat",
      facts = { stat = "attack" },
      valid = { "PIKACHU" },
      invalid = { "MEWTWO" },
    },
    {
      item = "THICK_CLUB",
      timing = "modifyStat",
      facts = { stat = "attack" },
      valid = { "CUBONE", "MAROWAK" },
      invalid = { "PIKACHU" },
    },
    {
      item = "METAL_POWDER",
      timing = "modifyStat",
      facts = { stat = "defense" },
      valid = { "DITTO" },
      invalid = { "MEWTWO" },
    },
    {
      item = "QUICK_POWDER",
      timing = "modifyStat",
      facts = { stat = "speed" },
      valid = { "DITTO" },
      invalid = { "MEWTWO" },
    },
    {
      item = "DEEPSEATOOTH",
      timing = "modifyStat",
      facts = { stat = "specialAttack" },
      valid = { "CLAMPERL" },
      invalid = { "MEWTWO" },
    },
    {
      item = "DEEPSEASCALE",
      timing = "modifyStat",
      facts = { stat = "specialDefense" },
      valid = { "CLAMPERL" },
      invalid = { "MEWTWO" },
    },
    {
      item = "ADAMANT_ORB",
      timing = "beforeHit",
      facts = { moveType = "steel" },
      valid = { "DIALGA" },
      invalid = { "PALKIA" },
    },
    {
      item = "LUSTROUS_ORB",
      timing = "beforeHit",
      facts = { moveType = "water" },
      valid = { "PALKIA" },
      invalid = { "DIALGA" },
    },
    {
      item = "GRISEOUS_ORB",
      timing = "beforeHit",
      facts = { moveType = "ghost" },
      valid = { "GIRATINA" },
      invalid = { "DIALGA" },
    },
  }
  for _, case in ipairs(cases) do
    for _, species in ipairs(case.valid) do
      local facts = { species = species, transformed = false }
      for name, value in pairs(case.facts) do
        facts[name] = value
      end
      Assert.equal(
        #boosted(case.item, case.timing, facts),
        1,
        case.item .. " boosts its native holder " .. species
      )
    end
    for _, species in ipairs(case.invalid) do
      local facts = { species = species, transformed = false }
      for name, value in pairs(case.facts) do
        facts[name] = value
      end
      Assert.deepEqual(
        boosted(case.item, case.timing, facts),
        {},
        case.item .. " stays silent for " .. species
      )
    end
  end
  local transformedFacts = { moveType = "ghost", species = "GIRATINA", transformed = true }
  Assert.deepEqual(
    boosted("GRISEOUS_ORB", "beforeHit", transformedFacts),
    {},
    "the origin orb stays silent for a transformed Giratina"
  )
  local genericFacts = { moveType = "fire", species = "MEWTWO", transformed = false }
  Assert.equal(
    #boosted("CHARCOAL", "beforeHit", genericFacts),
    1,
    "a generic type booster still answers for any holder"
  )
end

-- Species-locked items fail closed when the holder facts are absent:
-- without a holder species the handler emits nothing instead of
-- boosting universally.
function T.species_locked_items_fail_closed_without_holder_facts()
  local handlers = nativeHandlers("native passive registration owns the item binding set")
  local statBag = bagWith("SOUL_DEW", "modifyStat", EffectFixture.activeScope(1, 1))
  local statOutcome =
    runPassive(statBag, handlers, "modifyStat", passiveContext({ stat = "specialAttack" }))
  Assert.deepEqual(statOutcome.events, {}, "a stat booster without holder facts stays silent")
  local typeBag = bagWith("ADAMANT_ORB", "beforeHit", EffectFixture.activeScope(1, 1))
  local typeOutcome = runPassive(typeBag, handlers, "beforeHit", passiveContext({ moveType = "steel" }))
  Assert.deepEqual(typeOutcome.events, {}, "a type booster without holder facts stays silent")
end

return { tests = T }
