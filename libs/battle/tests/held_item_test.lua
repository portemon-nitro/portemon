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
      timing = "beforeHit",
      facts = {},
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

-- Metal Coat boosts Steel strikes like the other type boosters: the
-- evolving hold doubles as a battle booster, so Steel answers while
-- off-type strikes stay silent.
function T.metal_coat_boosts_steel_like_other_type_boosters()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param moveType string striking move type under test
  ---@return table[] emitted boost events for the pass
  local function boostedSteel(moveType)
    local bag = bagWith("METAL_COAT", "beforeHit", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(bag, handlers, "beforeHit", passiveContext({ moveType = moveType }))
    Assert.isTrue(outcome.done, "the item pass runs to completion")
    return outcome.events
  end

  Assert.equal(#boostedSteel("steel"), 1, "metal coat answers steel strikes")
  Assert.deepEqual(boostedSteel("fire"), {}, "metal coat stays silent off steel")
end

-- Light Ball doubles move power for Pikachu without touching stats: the
-- native strike multiplies power, so the handler announces power for
-- Pikachu and stays silent for any other holder.
function T.light_ball_doubles_power_for_pikachu_only()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param species string holder species under test
  ---@return table[] emitted boost events for the pass
  local function boostedPower(species)
    local bag = bagWith("LIGHT_BALL", "beforeHit", EffectFixture.activeScope(1, 1))
    local outcome =
      runPassive(bag, handlers, "beforeHit", passiveContext({ species = species, transformed = false }))
    Assert.isTrue(outcome.done, "the item pass runs to completion")
    return outcome.events
  end

  local pikachu = boostedPower("PIKACHU")
  Assert.equal(#pikachu, 1, "light ball answers for pikachu")
  Assert.equal(pikachu[1].power, "boosted", "light ball boosts power rather than stats")
  Assert.deepEqual(boostedPower("MEWTWO"), {}, "light ball stays silent for other holders")
end

-- Big Root answers leech recovery as well as drain: the native leech
-- boost covers stolen health beyond direct draining strikes.
function T.big_root_answers_leech_recovery()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param extra table<string, unknown> recovery context facts under test
  ---@return table[] emitted boost events for the pass
  local function boostedDrain(extra)
    local bag = bagWith("BIG_ROOT", "beforeHit", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(bag, handlers, "beforeHit", passiveContext(extra))
    Assert.isTrue(outcome.done, "the item pass runs to completion")
    return outcome.events
  end

  Assert.equal(#boostedDrain({ drain = true }), 1, "big root answers draining strikes")
  Assert.equal(#boostedDrain({ leech = true }), 1, "big root answers leech recovery")
  Assert.deepEqual(boostedDrain({}), {}, "big root stays silent without recovery")
end

-- Chilan answers normal-type hits without any effectiveness gate: the
-- native weaken-normal script skips the super-effective check the
-- resist family requires, so a plain normal strike eats the berry.
function T.chilan_answers_normal_hits_without_super_effectiveness()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param key string berry identity under test
  ---@param extra table<string, unknown> damage context facts under test
  ---@return table[] emitted resistance events for the pass
  local function resisted(key, extra)
    local bag = bagWith(key, "residual", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(bag, handlers, "residual", passiveContext(extra))
    Assert.isTrue(outcome.done, "the berry pass runs to completion")
    return outcome.events
  end

  Assert.equal(
    #resisted("CHILAN_BERRY", { moveType = "normal" }),
    1,
    "chilan answers a plain normal strike"
  )
  Assert.deepEqual(
    resisted("CHILAN_BERRY", { moveType = "fire", superEffective = true }),
    {},
    "chilan stays silent off normal"
  )
  Assert.equal(
    #resisted("OCCA_BERRY", { moveType = "fire", superEffective = true }),
    1,
    "the resist family still answers super-effective hits"
  )
  Assert.deepEqual(
    resisted("OCCA_BERRY", { moveType = "fire" }),
    {},
    "the resist family still needs the super-effective gate"
  )
end

-- Power items halve Speed like Macho Brace: every entry in the native
-- speed-halving list answers the Speed checkpoint and stays silent for
-- other stats.
function T.power_items_halve_speed_like_macho_brace()
  local handlers = nativeHandlers("native passive registration owns the item binding set")
  local halving = {
    "MACHO_BRACE",
    "IRON_BALL",
    "POWER_BRACER",
    "POWER_BELT",
    "POWER_LENS",
    "POWER_BAND",
    "POWER_ANKLET",
    "POWER_WEIGHT",
  }
  for _, key in ipairs(halving) do
    local bag = bagWith(key, "modifyStat", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(bag, handlers, "modifyStat", passiveContext({ stat = "speed" }))
    Assert.isTrue(outcome.done, "the item pass runs to completion")
    Assert.equal(#outcome.events, 1, key .. " halves speed")
    local offBag = bagWith(key, "modifyStat", EffectFixture.activeScope(1, 1))
    local offOutcome = runPassive(offBag, handlers, "modifyStat", passiveContext({ stat = "attack" }))
    Assert.deepEqual(offOutcome.events, {}, key .. " stays silent off speed")
  end
end

-- Flavor berries confuse holders that dislike the flavor instead of
-- healing: the native script runs the dislike branch from personality,
-- so a disliked holder gains confusion and no health.
function T.flavor_berries_confuse_disliked_holders_instead_of_healing()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param disliked boolean whether the holder dislikes the berry flavor
  ---@return table[] emitted berry events for the pass
  local function eaten(disliked)
    local bag = bagWith("FIGY_BERRY", "residual", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(
      bag,
      handlers,
      "residual",
      passiveContext({
        health = { [1] = 50, [2] = 30, [3] = 30 },
        maxHealth = { [1] = 100, [2] = 30, [3] = 30 },
        dislikedFlavor = disliked,
      })
    )
    Assert.isTrue(outcome.done, "the berry pass runs to completion")
    return outcome.events
  end

  local confused = eaten(true)
  Assert.equal(#confused, 1, "the disliked berry still triggers")
  Assert.isTrue(confused[1].confused, "the disliked berry confuses instead of healing")
  Assert.isNil(confused[1].recovered, "the disliked berry restores no health")
  local healed = eaten(false)
  Assert.equal(#healed, 1, "the liked berry still triggers")
  Assert.isTrue(healed[1].recovered, "the liked berry restores health")
end

-- Lum and Persim cure volatile confusion: the native scripts read the
-- confusion volatile beside major status, so a confused holder is
-- cured with no major condition present.
function T.lum_and_persim_cure_volatile_confusion()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param key string berry identity under test
  ---@param extra table<string, unknown> status context facts under test
  ---@return table[] emitted cure events for the pass
  local function cured(key, extra)
    local bag = bagWith(key, "residual", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(bag, handlers, "residual", passiveContext(extra))
    Assert.isTrue(outcome.done, "the berry pass runs to completion")
    return outcome.events
  end

  local persim = cured("PERSIM_BERRY", { confusion = true })
  Assert.equal(#persim, 1, "persim answers volatile confusion")
  Assert.equal(persim[1].cured, "confusion", "persim names the cured volatile")
  Assert.deepEqual(
    cured("PERSIM_BERRY", { status = "paralysis" }),
    {},
    "persim stays silent for major status"
  )
  local lum = cured("LUM_BERRY", { confusion = true })
  Assert.equal(#lum, 1, "lum answers volatile confusion")
  Assert.equal(lum[1].cured, "confusion", "lum names the cured volatile")
  local lumMajor = cured("LUM_BERRY", { status = "paralysis" })
  Assert.equal(#lumMajor, 1, "lum still answers major status")
  Assert.equal(lumMajor[1].cured, "paralysis", "lum still names the cured condition")
end

-- Pinch berries respect maxed stages and the Lansat focus gate: native
-- stat berries refuse a maxed stat, Lansat refuses a focused holder,
-- and Starf refuses when every stat is already maxed.
function T.pinch_berries_respect_maxed_stages_and_focus()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param key string berry identity under test
  ---@param extra table<string, unknown> residual context facts under test
  ---@return table[] emitted pinch events for the pass
  local function pinched(key, extra)
    local bag = bagWith(key, "residual", EffectFixture.activeScope(1, 1))
    local base = {
      health = { [1] = 25, [2] = 30, [3] = 30 },
      maxHealth = { [1] = 100, [2] = 30, [3] = 30 },
    }
    for name, value in pairs(extra) do
      base[name] = value
    end
    local outcome = runPassive(bag, handlers, "residual", passiveContext(base))
    Assert.isTrue(outcome.done, "the berry pass runs to completion")
    return outcome.events
  end

  Assert.deepEqual(
    pinched("LIECHI_BERRY", { statStages = { attack = 6 } }),
    {},
    "liechi stays silent with maxed attack"
  )
  Assert.equal(
    #pinched("LIECHI_BERRY", { statStages = { attack = 5 } }),
    1,
    "liechi answers below the stage cap"
  )
  Assert.deepEqual(
    pinched("LANSAT_BERRY", { focused = true }),
    {},
    "lansat stays silent for a focused holder"
  )
  Assert.equal(#pinched("LANSAT_BERRY", {}), 1, "lansat answers an unfocused holder")
  Assert.deepEqual(
    pinched("STARF_BERRY", {
      statStages = { attack = 6, defense = 6, speed = 6, specialAttack = 6, specialDefense = 6 },
    }),
    {},
    "starf stays silent when every stat is maxed"
  )
end

-- Starf names a concrete sharply-raised stat: the native script draws
-- the boosted stat and raises it by two, so the announcement carries
-- the drawn stat instead of a placeholder.
function T.starf_names_a_concrete_sharply_raised_stat()
  local handlers = nativeHandlers("native passive registration owns the item binding set")
  local bag = bagWith("STARF_BERRY", "residual", EffectFixture.activeScope(1, 1))
  local outcome = runPassive(
    bag,
    handlers,
    "residual",
    passiveContext({
      health = { [1] = 25, [2] = 30, [3] = 30 },
      maxHealth = { [1] = 100, [2] = 30, [3] = 30 },
      stream = { nextU16 = function(_, _, _)
        return 0
      end },
    })
  )
  Assert.isTrue(outcome.done, "the berry pass runs to completion")
  Assert.equal(#outcome.events, 1, "starf answers at the pinch gate")
  Assert.equal(outcome.events[1].stat, "attack", "starf names the drawn stat")
  Assert.equal(outcome.events[1].stages, "sharply-boosted", "starf raises by two stages")
end

-- Micle marks deferred accuracy for the next move: the native flag
-- multiplies the following accuracy check instead of boosting
-- immediately, so the announcement defers rather than applies.
function T.micle_marks_deferred_accuracy_for_the_next_move()
  local handlers = nativeHandlers("native passive registration owns the item binding set")
  local bag = bagWith("MICLE_BERRY", "residual", EffectFixture.activeScope(1, 1))
  local outcome = runPassive(
    bag,
    handlers,
    "residual",
    passiveContext({
      health = { [1] = 25, [2] = 30, [3] = 30 },
      maxHealth = { [1] = 100, [2] = 30, [3] = 30 },
    })
  )
  Assert.isTrue(outcome.done, "the berry pass runs to completion")
  Assert.equal(#outcome.events, 1, "micle answers at the pinch gate")
  Assert.isTrue(outcome.events[1].accuracyNext, "micle defers its boost to the next move")
  Assert.isNil(outcome.events[1].accuracy, "micle applies no immediate boost")
end

-- King's Rock and Razor Fang roll ten percent: the native flinch
-- chance draws per damaging hit, so a low roll announces and a high
-- roll -- or no stream at all -- stays silent.
function T.kings_rock_rolls_ten_percent()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param key string flinch item identity under test
  ---@param stream table<string, unknown>? fixed battle stream under test
  ---@return table[] emitted flinch events for the pass
  local function flinched(key, stream)
    local bag = bagWith(key, "residual", EffectFixture.activeScope(1, 1))
    local extra = { dealtDamage = true }
    if stream ~= nil then
      extra.stream = stream
    else
      extra.stream = nil
    end
    local context = passiveContext(extra)
    if stream == nil then
      context.stream = nil
    end
    local outcome = runPassive(bag, handlers, "residual", context)
    Assert.isTrue(outcome.done, "the item pass runs to completion")
    return outcome.events
  end

  local function fixedStream(value)
    return {
      nextU16 = function(_, _, _)
        return value
      end,
    }
  end

  for _, key in ipairs({ "KINGS_ROCK", "RAZOR_FANG" }) do
    Assert.equal(#flinched(key, fixedStream(0)), 1, key .. " announces on a low roll")
    Assert.deepEqual(flinched(key, fixedStream(65535)), {}, key .. " stays silent on a high roll")
    Assert.deepEqual(flinched(key, nil), {}, key .. " stays silent without a stream")
  end
end

-- Soul Dew stays silent in frontier formats: the native boost applies
-- outside the frontier only, so a frontier holder gains nothing.
function T.soul_dew_stays_silent_in_frontier_formats()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param frontier boolean whether the frontier format applies
  ---@return table[] emitted boost events for the pass
  local function boosted(frontier)
    local bag = bagWith("SOUL_DEW", "modifyStat", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(
      bag,
      handlers,
      "modifyStat",
      passiveContext({ stat = "specialAttack", species = "LATIAS", frontier = frontier })
    )
    Assert.isTrue(outcome.done, "the item pass runs to completion")
    return outcome.events
  end

  Assert.equal(#boosted(false), 1, "soul dew answers outside the frontier")
  Assert.deepEqual(boosted(true), {}, "soul dew stays silent in the frontier")
end

-- The metronome item scales from the second consecutive use: the first
-- repetition multiplies by ten over ten, so only a real streak boosts.
function T.metronome_item_scales_from_the_second_consecutive_use()
  local handlers = nativeHandlers("native passive registration owns the item binding set")

  ---@param streak integer consecutive uses under test
  ---@return table[] emitted boost events for the pass
  local function boostedStreak(streak)
    local bag = bagWith("METRONOME", "beforeHit", EffectFixture.activeScope(1, 1))
    local outcome =
      runPassive(bag, handlers, "beforeHit", passiveContext({ consecutiveUses = streak }))
    Assert.isTrue(outcome.done, "the item pass runs to completion")
    return outcome.events
  end

  Assert.deepEqual(boostedStreak(1), {}, "the first use gains no boost")
  Assert.equal(#boostedStreak(2), 1, "the second consecutive use boosts")
end

-- Quick Claw answers its supplied pre-turn sample without drawing: a
-- triggering sample announces early priority while a missing sample stays
-- silent, and neither consults the battle stream, so the live sorter can
-- feed the stored sample instead of spending a late roll.
function T.quick_claw_answers_from_a_supplied_sample_without_drawing()
  local handlers = nativeHandlers("native passive registration owns the order item binding set")

  ---@param raw integer pre-turn order sample carried by the context
  ---@param drawn string[] draw log receiving every stream label
  ---@return table[] emitted order events for the pass
  local function ordered(raw, drawn)
    local bag = bagWith("QUICK_CLAW", "beforeAction", EffectFixture.activeScope(1, 1))
    local stream = {
      nextU16 = function(_, label, _)
        drawn[#drawn + 1] = label
        return 0
      end,
    }
    local outcome = runPassive(
      bag,
      handlers,
      "beforeAction",
      passiveContext({ moveUse = { user = 1 }, rawOrderRoll = raw, stream = stream })
    )
    Assert.isTrue(outcome.done, "the order pass runs to completion")
    return outcome.events
  end

  local triggering = {}
  local fired = ordered(0, triggering)
  Assert.equal(#fired, 1, "a triggering sample announces early priority")
  Assert.equal(fired[1].order, "first", "the announcement moves the holder first")
  Assert.deepEqual(triggering, {}, "a triggering sample spends no battle draw")

  local missing = {}
  Assert.deepEqual(ordered(65534, missing), {}, "a missing sample stays silent")
  Assert.deepEqual(missing, {}, "a missing sample spends no battle draw")
end

-- Species-locked critical holdings gate on their native holder and
-- carry two stages: the punch answers for Chansey and the stick for
-- Farfetch'd while any other holder stays silent, and the lens and
-- the claw add one stage for any holder.
function T.species_locked_critical_holdings_gate_and_carry_two_stages()
  local handlers = nativeHandlers("native passive registration owns the critical holding set")

  ---@param key string holding identity under test
  ---@param species string holder species carried by the context
  ---@return table[] emitted critical events for the pass
  local function critical(key, species)
    local bag = bagWith(key, "beforeHit", EffectFixture.activeScope(1, 1))
    local outcome = runPassive(
      bag,
      handlers,
      "beforeHit",
      passiveContext({ criticalCheck = true, species = species, transformed = false })
    )
    Assert.isTrue(outcome.done, "the critical pass runs to completion")
    return outcome.events
  end

  local punch = critical("LUCKY_PUNCH", "CHANSEY")
  Assert.equal(#punch, 1, "the punch answers its native holder")
  Assert.equal(punch[1].critical, "boosted", "the punch raises the stage")
  Assert.equal(punch[1].stages, 2, "the punch carries two stages")
  Assert.deepEqual(critical("LUCKY_PUNCH", "EEVEE"), {}, "the punch stays silent for other holders")
  local stick = critical("STICK", "FARFETCH_D")
  Assert.equal(#stick, 1, "the stick answers its native holder")
  Assert.equal(stick[1].stages, 2, "the stick carries two stages")
  Assert.deepEqual(critical("STICK", "EEVEE"), {}, "the stick stays silent for other holders")
  local lens = critical("SCOPE_LENS", "EEVEE")
  Assert.equal(#lens, 1, "the lens answers any holder")
  Assert.equal(lens[1].stages, 1, "the lens carries one stage")
  local claw = critical("RAZOR_CLAW", "EEVEE")
  Assert.equal(#claw, 1, "the claw answers any holder")
  Assert.equal(claw[1].stages, 1, "the claw carries one stage")
end

-- Embargo suppresses the effective holding through the bridge while raw
-- possession stays: an embargoed claw holder reads empty-handed for
-- ordinary effects and never orders first, a stale entry token never
-- inherits the cover, and the live effect bag keeps only its finite
-- embargo with no materialized innate instance beside it.
function T.embargo_suppresses_the_effective_holding_through_the_bridge()
  local Bridge = SessionFixture.requirePresent(
    "libs.battle.src.gen4.NativePassiveBridge",
    "the private live composition owns effective possession"
  )
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local NativeEffectHandlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "one registration owner binds native definitions to their handlers"
  )

  ---@param activation integer entry token scoping the embargo instance
  ---@return table live battle state carrying a claw holder under the embargo
  local function embargoedState(activation)
    local bag = EffectBag.new()
    local definition = NativeEffectHandlers.definitionFor("embargo")
    bag:add(
      definition,
      { kind = "active", combatant = 1, activation = activation },
      { kind = "move", combatant = 2 },
      definition.validateState({ version = 1, turns = 3 })
    )
    return {
      round = 2,
      effectBag = bag,
      combatants = {
        [1] = {
          id = 1,
          participant = 1,
          mon = {
            ability = "STATIC",
            species = "PIKACHU",
            heldItem = "QUICK_CLAW",
            condition = { effects = {} },
          },
          active = { position = 1, activation = 7, entryTurn = 0 },
          hp = 20,
          maxHp = 30,
          entryHp = 30,
        },
      },
    }
  end

  local covered = embargoedState(7)
  local bridge = Bridge.wrap(covered)
  Assert.equal(bridge:rawHeldItem(1), "QUICK_CLAW", "suppression keeps the possession on record")
  Assert.isNil(bridge:effectiveHeldItem(1), "an active embargo empties the effective holding")
  local held = bridge:orderFacts(1, { moveUse = { user = 1 }, rawOrderRoll = 0 })
  Assert.isFalse(held.first, "a suppressed claw never orders first")
  Assert.equal(
    #(covered.effectBag:capture()),
    1,
    "the live bag keeps only its finite embargo"
  )

  local stale = embargoedState(9)
  local staleBridge = Bridge.wrap(stale)
  Assert.equal(
    staleBridge:effectiveHeldItem(1),
    "QUICK_CLAW",
    "a stale entry token never inherits the cover"
  )
  local freed = staleBridge:orderFacts(1, { moveUse = { user = 1 }, rawOrderRoll = 0 })
  Assert.isTrue(freed.first, "the uncovered claw orders first again")
end

return { tests = T }
