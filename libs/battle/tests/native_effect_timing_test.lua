-- Finite effect timing handlers through the single native dispatch: the
-- before-action timing gates confused, infatuated, flinching, encored,
-- disabled, taunted, tormented, and drowsy entries with their native
-- countdowns and verdicts, while the entry timing prices switch-in
-- hazards. Every handler resolves through handlersFor for its timing and
-- runs through the shared finite dispatch over constructed pass facts;
-- session checkpoint wiring consumes their verdict events.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

local FIXED_SEED = 918273645
local CONFUSION_HIT_THRESHOLD = 32768

---@param behavior string missing owner under test
---@return table the loaded native effect handler owner
local function handlersOwner(behavior)
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    behavior
  )
end

---@return table live effect bag over no instances
local function liveBag()
  local EffectBag = SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped instances own battle state")
  return EffectBag.new()
end

---@param bag table live effect bag under the instance
---@param key string definition identity under the instance
---@param scope table<string, unknown> owner scope for the instance
---@param state table<string, unknown> typed state for the instance
---@return table<string, unknown> stored instance record
local function addInstance(bag, key, scope, state)
  local Handlers = handlersOwner("native definitions resolve for typed battle-local writes")
  return bag:add(Handlers.definitionFor(key), scope, { kind = "move", combatant = 1 }, state)
end

---@param bag table live effect bag under dispatch
---@param handlers table<string, fun(instance: table, context: table): unknown> handlers under test
---@param timing string timing under invocation
---@param context table<string, unknown> pass context under invocation
---@return table dispatch outcome for the timing
local function invoke(bag, handlers, timing, context)
  local EffectDispatch = SessionFixture.requirePresent(
    "libs.battle.src.EffectDispatch",
    "one dispatcher owns finite timing order"
  )
  return EffectDispatch.new(bag, handlers):invoke(timing, context)
end

---@param overrides table<string, unknown>? fact overrides for the pass
---@return table<string, unknown> per-pass battle facts for combatant 2
local function beforeFacts(overrides)
  local facts = {
    maxHp = { [2] = 96 },
    types = { [2] = { "normal" } },
    occupants = { [1] = 2 },
    stats = { [2] = { level = 50, attack = 120, defense = 90 } },
  }
  for name, value in pairs(overrides or {}) do
    facts[name] = value
  end
  return facts
end

---@return table<string, unknown> session chart view resolving effectiveness
local function nativeChart()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "entry-hazard-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(Executor.RULESET, { key = Executor.RULESET, chart = Executor.RULESET }, "entry-hazard-tests")
  local BattleContent = require("libs.battle.src.BattleContent")
  local content = BattleContent.new(builder:freeze(), behaviors:freeze())
  return assert(content:typeChart(Executor.RULESET), "the native chart resolves for the entry probes")
end

---@param types string[] entrant types under the probe
---@param grounded boolean whether layers price the arrival
---@return table<string, unknown> per-pass battle facts for entrant 3
local function entryFacts(types, grounded)
  return {
    maxHp = { [3] = 96 },
    types = { [3] = types },
    occupants = { [1] = 3 },
    sides = { [3] = 2 },
    entrant = 3,
    grounded = grounded,
    chart = nativeChart(),
  }
end

---@param label string draw label under the scan
---@param cause table<string, unknown> draw cause under the scan
---@param pick fun(draw: integer): boolean whether the draw opens the wanted branch
---@return integer seed opening with the wanted first draw
local function probeSeed(label, cause, pick)
  for seed = 1, 4096 do
    local stream = BattleRng.new(seed)
    if pick(stream:nextU16(label, cause)) then
      return seed
    end
  end
  error("the probe found no seed for its branch")
end

-- Confused entries snap out at zero, act through on a missed roll, and
-- hurt themselves otherwise with staged typeless damage: every branch
-- spends exactly one countdown turn and denies the action only on the
-- self-hit.
function T.confusion_gates_actions_with_its_countdown()
  local Handlers = handlersOwner("before-action handlers gate confused entries")
  local scope = { kind = "active", combatant = 2, activation = 7 }

  local bag = liveBag()
  local spent = addInstance(bag, "confusion", scope, { version = 1, turns = 1 })
  local spentHealth = { [2] = 100 }
  local spentContext = { health = spentHealth, stream = BattleRng.new(FIXED_SEED) }
  local spentOutcome =
    invoke(bag, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", spentContext)
  Assert.isTrue(spentOutcome.done, "the confused pass completes")
  Assert.equal(#spentOutcome.events, 1, "the last counted turn answers exactly once")
  Assert.equal(spentOutcome.events[1].kind, "expire", "the zeroed countdown snaps out")
  Assert.isNil(spentContext.blockedBy, "snapping out denies nothing")
  Assert.equal(spentHealth[2], 100, "snapping out deals no damage")
  Assert.equal(bag:get(spent.id).state.turns, 0, "the zeroed countdown waits for the session sweep")

  local missSeed = probeSeed("confusion_hit", { kind = "confusion", combatant = 2 }, function(draw)
    return draw >= CONFUSION_HIT_THRESHOLD
  end)
  local missed = liveBag()
  addInstance(missed, "confusion", scope, { version = 1, turns = 5 })
  local missedHealth = { [2] = 100 }
  local missedContext = { health = missedHealth, stream = BattleRng.new(missSeed) }
  local missedOutcome =
    invoke(missed, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", missedContext)
  Assert.isTrue(missedOutcome.done, "the missed pass completes")
  Assert.equal(#missedOutcome.events, 0, "the missed roll stays silent")
  Assert.isNil(missedContext.blockedBy, "the missed roll denies nothing")
  Assert.equal(missedHealth[2], 100, "the missed roll deals no damage")

  local hitSeed = probeSeed("confusion_hit", { kind = "confusion", combatant = 2 }, function(draw)
    return draw < CONFUSION_HIT_THRESHOLD
  end)
  local struck = liveBag()
  local bound = addInstance(struck, "confusion", scope, { version = 1, turns = 5 })
  local struckHealth = { [2] = 100 }
  local struckContext = { health = struckHealth, stream = BattleRng.new(hitSeed) }
  local struckOutcome =
    invoke(struck, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", struckContext)
  Assert.isTrue(struckOutcome.done, "the self-hit pass completes")
  Assert.equal(#struckOutcome.events, 1, "the confused entry answers exactly once")
  Assert.equal(struckOutcome.events[1].kind, "tick", "the self-hit lands damage")
  Assert.isTrue(struckHealth[2] < 100, "the self-hit spends health")
  Assert.equal(struckContext.blockedBy, "confusion", "the self-hit denies the action")
  Assert.equal(struck:get(bound.id).state.turns, 4, "the self-hit spends one countdown turn")
end

-- Flinching entries always lose their action and spend the one-turn
-- mark: the block verdict carries the denial while the zeroed countdown
-- waits for the session sweep.
function T.flinch_blocks_and_spends_its_mark()
  local Handlers = handlersOwner("before-action handlers gate flinching entries")
  local bag = liveBag()
  local scope = { kind = "active", combatant = 2, activation = 7 }
  local mark = addInstance(bag, "flinch", scope, { version = 1, turns = 1 })
  local health = { [2] = 100 }
  local context = { health = health }
  local outcome = invoke(bag, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", context)
  Assert.isTrue(outcome.done, "the flinch pass completes")
  Assert.equal(#outcome.events, 1, "the flinch answers exactly once")
  Assert.equal(outcome.events[1].kind, "blocked", "the flinch emits its block")
  Assert.equal(outcome.events[1].key, "flinch", "the block names its finite effect")
  Assert.equal(context.blockedBy, "flinch", "the flinch denies the action")
  Assert.equal(bag:get(mark.id).state.turns, 0, "the block spends the one-turn mark for the sweep")
end

-- Infatuated entries immobilize on a fair draw and act through
-- otherwise, carrying no countdown either way.
function T.infatuation_immobilizes_on_a_fair_draw()
  local Handlers = handlersOwner("before-action handlers gate infatuated entries")
  local scope = { kind = "active", combatant = 2, activation = 7 }
  local cause = { kind = "infatuation", combatant = 2 }

  local heldSeed = probeSeed("infatuation_gate", cause, function(draw)
    return draw % 2 == 1
  end)
  local held = liveBag()
  addInstance(held, "infatuation", scope, { version = 1 })
  local heldHealth = { [2] = 100 }
  local heldContext = { health = heldHealth, stream = BattleRng.new(heldSeed) }
  local heldOutcome =
    invoke(held, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", heldContext)
  Assert.isTrue(heldOutcome.done, "the infatuation pass completes")
  Assert.equal(#heldOutcome.events, 1, "the immobilized entry answers exactly once")
  Assert.equal(heldOutcome.events[1].kind, "blocked", "infatuation emits its block")
  Assert.equal(heldContext.blockedBy, "infatuation", "infatuation denies the action")

  local sparedSeed = probeSeed("infatuation_gate", cause, function(draw)
    return draw % 2 == 0
  end)
  local spared = liveBag()
  addInstance(spared, "infatuation", scope, { version = 1 })
  local sparedHealth = { [2] = 100 }
  local sparedContext = { health = sparedHealth, stream = BattleRng.new(sparedSeed) }
  local sparedOutcome =
    invoke(spared, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", sparedContext)
  Assert.isTrue(sparedOutcome.done, "the spared pass completes")
  Assert.equal(#sparedOutcome.events, 0, "the spared entry acts through silently")
  Assert.isNil(sparedContext.blockedBy, "the spared entry denies nothing")
end

-- Taunted entries refuse status strikes and count down; damaging
-- strikes pass through, and the zeroed countdown expires silently.
function T.taunt_refuses_status_strikes_and_spares_damage()
  local Handlers = handlersOwner("before-action handlers gate restricted entries")
  local scope = { kind = "active", combatant = 2, activation = 7 }

  local refused = liveBag()
  addInstance(refused, "taunt", scope, { version = 1, turns = 3 })
  local refusedHealth = { [2] = 100 }
  local refusedContext = { health = refusedHealth, move = "SWORDS_DANCE", power = 0 }
  local refusedOutcome =
    invoke(refused, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", refusedContext)
  Assert.isTrue(refusedOutcome.done, "the taunt pass completes")
  Assert.equal(#refusedOutcome.events, 1, "the refused entry answers exactly once")
  Assert.equal(refusedOutcome.events[1].kind, "blocked", "taunt refuses status strikes")
  Assert.equal(refusedContext.blockedBy, "taunt", "taunt denies the status strike")

  local struck = liveBag()
  local striking = addInstance(struck, "taunt", scope, { version = 1, turns = 3 })
  local struckHealth = { [2] = 100 }
  local struckContext = { health = struckHealth, move = "TACKLE", power = 40 }
  local struckOutcome =
    invoke(struck, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", struckContext)
  Assert.isTrue(struckOutcome.done, "the damaging pass completes")
  Assert.equal(#struckOutcome.events, 0, "taunt spares damaging strikes")
  Assert.isNil(struckContext.blockedBy, "the damaging strike denies nothing")
  Assert.equal(struck:get(striking.id).state.turns, 2, "the spared strike still spends the countdown")

  local spent = liveBag()
  addInstance(spent, "taunt", scope, { version = 1, turns = 1 })
  local spentContext = { health = { [2] = 100 }, move = "SWORDS_DANCE", power = 0 }
  local spentOutcome =
    invoke(spent, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", spentContext)
  Assert.isTrue(spentOutcome.done, "the final pass completes")
  Assert.equal(#spentOutcome.events, 0, "the zeroed taunt expires silently")
  Assert.isNil(spentContext.blockedBy, "the expired taunt denies nothing")
end

-- Disabling entries refuse only their named strike, encored entries name
-- their forced strike while counting down, and torment preserves
-- silently for the selection owner; every zeroed countdown retires
-- without a second verdict.
function T.disable_encore_and_torment_gate_their_named_selections()
  local Handlers = handlersOwner("before-action handlers gate restricted entries")
  local scope = { kind = "active", combatant = 2, activation = 7 }

  local refused = liveBag()
  addInstance(refused, "disable", scope, { version = 1, turns = 3, move = "TACKLE" })
  local refusedContext = { health = { [2] = 100 }, move = "TACKLE", power = 40 }
  local refusedOutcome =
    invoke(refused, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", refusedContext)
  Assert.equal(#refusedOutcome.events, 1, "the named strike answers exactly once")
  Assert.equal(refusedOutcome.events[1].kind, "blocked", "disable refuses its named strike")
  Assert.equal(refusedContext.blockedBy, "disable", "disable denies the named strike")

  local spared = liveBag()
  local other = addInstance(spared, "disable", scope, { version = 1, turns = 3, move = "TACKLE" })
  local sparedContext = { health = { [2] = 100 }, move = "SPLASH", power = 0 }
  local sparedOutcome =
    invoke(spared, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", sparedContext)
  Assert.equal(#sparedOutcome.events, 0, "disable spares every other selection")
  Assert.isNil(sparedContext.blockedBy, "the spared selection denies nothing")
  Assert.equal(spared:get(other.id).state.turns, 2, "the spared selection still spends the countdown")

  local quiet = liveBag()
  addInstance(quiet, "disable", scope, { version = 1, turns = 1, move = "TACKLE" })
  local quietContext = { health = { [2] = 100 }, move = "TACKLE", power = 40 }
  local quietOutcome =
    invoke(quiet, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", quietContext)
  Assert.equal(#quietOutcome.events, 0, "the zeroed disable expires silently")
  Assert.isNil(quietContext.blockedBy, "the expired disable denies nothing")

  local forced = liveBag()
  addInstance(forced, "encore", scope, { version = 1, turns = 3, move = "TACKLE" })
  local forcedContext = { health = { [2] = 100 }, move = "SPLASH", power = 0 }
  local forcedOutcome =
    invoke(forced, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", forcedContext)
  Assert.equal(#forcedOutcome.events, 1, "the encored entry answers exactly once")
  Assert.equal(forcedOutcome.events[1].kind, "redirected", "encore names its forced strike")
  Assert.equal(forcedOutcome.events[1].move, "TACKLE", "the redirect carries the recorded strike")
  Assert.isNil(forcedContext.blockedBy, "the redirect is a verdict, not a denial")

  local released = liveBag()
  addInstance(released, "encore", scope, { version = 1, turns = 1, move = "TACKLE" })
  local releasedContext = { health = { [2] = 100 }, move = "TACKLE", power = 40 }
  local releasedOutcome =
    invoke(released, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", releasedContext)
  Assert.equal(#releasedOutcome.events, 1, "the last counted turn answers exactly once")
  Assert.equal(releasedOutcome.events[1].kind, "expire", "the zeroed encore expires")

  local marked = liveBag()
  addInstance(marked, "torment", scope, { version = 1 })
  local markedContext = { health = { [2] = 100 }, move = "TACKLE", power = 40 }
  local markedOutcome =
    invoke(marked, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", markedContext)
  Assert.isTrue(markedOutcome.done, "the torment pass completes")
  Assert.equal(#markedOutcome.events, 0, "torment preserves silently for selection")
  Assert.isNil(markedContext.blockedBy, "torment never denies the action itself")
end

-- Drowsy entries sleep on their second counted action through the
-- status owner and act before.
function T.yawn_sleeps_on_the_second_counted_action()
  local Handlers = handlersOwner("before-action handlers gate drowsy entries")
  local bag = liveBag()
  local scope = { kind = "active", combatant = 2, activation = 7 }
  addInstance(bag, "yawn", scope, { version = 1, turns = 2 })
  local applied = {}
  local context = {
    health = { [2] = 100 },
    applyStatus = function(target, key, state)
      applied[#applied + 1] = { target = target, key = key, state = state }
      return true
    end,
  }
  local first = invoke(bag, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", context)
  Assert.isTrue(first.done, "the first drowsy pass completes")
  Assert.equal(#first.events, 0, "the first counted action stays awake")
  Assert.equal(#applied, 0, "the first counted action writes no status")
  local second = invoke(bag, Handlers.handlersFor(beforeFacts(), "beforeAction"), "beforeAction", context)
  Assert.isTrue(second.done, "the second drowsy pass completes")
  Assert.equal(#second.events, 1, "the second counted action answers exactly once")
  Assert.equal(second.events[1].kind, "slept", "the second counted action sleeps")
  Assert.equal(#applied, 1, "drowsiness writes exactly one status")
  Assert.equal(applied[1].target, 2, "drowsiness sleeps its own entry")
  Assert.equal(applied[1].key, "sleep", "drowsiness sleeps through the status owner")
  Assert.equal(applied[1].state.turns, 2, "drowsiness sleeps the source-defined turns")
end

-- Switch-in hazards price the entry: stealth rock scales with rock
-- effectiveness, spikes scale with standing layers for grounded
-- arrivals only, and each hazard strikes its own side.
function T.entry_hazards_price_the_arrival()
  local Handlers = handlersOwner("entry handlers price switch-in hazards")
  Assert.isTrue(type(Handlers.handlersFor) == "function", "entry handlers resolve by timing")
  local handlers = Handlers.handlersFor(entryFacts({ "normal" }, true), "entry")
  Assert.isTrue(handlers.stealthrock ~= nil, "rock binds its entry handler")
  Assert.isTrue(handlers.spikes ~= nil, "spikes bind their entry handler")
  Assert.isTrue(handlers.toxicspikes ~= nil, "toxic spikes bind their entry handler")

  ---@param key string hazard definition identity under the probe
  ---@param state table<string, unknown> typed hazard state under the probe
  ---@param scope table<string, unknown> owner scope for the instance
  ---@param types string[] entrant types under the probe
  ---@param grounded boolean whether layers price the arrival
  ---@return table entry outcome for the hazard
  local function priceEntry(key, state, scope, types, grounded)
    local bag = liveBag()
    local instance = addInstance(bag, key, scope, state)
    local health = { [3] = 96 }
    local statused = {}
    local cleared = {}
    local context = {
      health = health,
      statused = statused,
      applyStatus = function(_, statusKey, _)
        statused[#statused + 1] = statusKey
        return true
      end,
      cleared = cleared,
      clearHazard = function()
        cleared[#cleared + 1] = instance.id
        return bag:remove(instance.id)
      end,
    }
    local probeHandlers = Handlers.handlersFor(entryFacts(types, grounded), "entry")
    local outcome = invoke(bag, probeHandlers, "entry", context)
    return { outcome = outcome, health = health, context = context, instance = instance, bag = bag }
  end
  local side = { kind = "side", side = 2 }
  local rock = priceEntry("stealthrock", { version = 1 }, side, { "fire", "flying" }, true)
  Assert.isTrue(rock.outcome.done, "the rock pass completes")
  Assert.equal(rock.health[3], 96 - 48, "doubly-weak arrivals pay one half")
  Assert.equal(rock.outcome.events[1].kind, "tick", "rock reports its damage tick")
  local spikes = priceEntry("spikes", { version = 1, layers = 1 }, side, { "normal" }, true)
  Assert.isTrue(spikes.outcome.done, "the spikes pass completes")
  Assert.equal(spikes.health[3], 96 - 12, "one layer costs one eighth")
  Assert.equal(spikes.outcome.events[1].kind, "hazard", "spikes report their hazard")
  Assert.equal(spikes.outcome.events[1].amount, 12, "spikes name their damage")
  local tiered = priceEntry("spikes", { version = 1, layers = 3 }, side, { "normal" }, true)
  Assert.equal(tiered.health[3], 96 - 24, "three layers cost one fourth")
  local aloft = priceEntry("spikes", { version = 1, layers = 3 }, side, { "flying" }, false)
  Assert.equal(aloft.health[3], 96, "levitating arrivals avoid the layers")
  Assert.equal(#aloft.outcome.events, 0, "avoided layers stay silent")
  local foreign = priceEntry("spikes", { version = 1, layers = 3 }, { kind = "side", side = 1 }, { "normal" }, true)
  Assert.equal(foreign.health[3], 96, "hazards spare the opposing side")
  Assert.equal(#foreign.outcome.events, 0, "foreign hazards stay silent")
end

-- Toxic spikes poison grounded arrivals (badly at two layers) instead
-- of dealing damage: poison arrivals absorb the layers through the
-- hazard clearer, and steel arrivals shrug them off.
function T.toxic_spikes_poison_absorb_or_repel()
  local Handlers = handlersOwner("entry handlers price toxic arrivals")

  ---@param state table<string, unknown> typed hazard state under the probe
  ---@param types string[] entrant types under the probe
  ---@param grounded boolean whether layers price the arrival
  ---@return table entry outcome for the toxic layers
  local function priceToxic(state, types, grounded)
    local bag = liveBag()
    local instance = addInstance(bag, "toxicspikes", { kind = "side", side = 2 }, state)
    local health = { [3] = 96 }
    local statused = {}
    local cleared = {}
    local context = {
      health = health,
      statused = statused,
      applyStatus = function(_, statusKey, _)
        statused[#statused + 1] = statusKey
        return true
      end,
      cleared = cleared,
      clearHazard = function()
        cleared[#cleared + 1] = instance.id
        return bag:remove(instance.id)
      end,
    }
    local probeHandlers = Handlers.handlersFor(entryFacts(types, grounded), "entry")
    local outcome = invoke(bag, probeHandlers, "entry", context)
    return { outcome = outcome, health = health, context = context, instance = instance, bag = bag }
  end
  local absorbed = priceToxic({ version = 1, layers = 1 }, { "poison" }, true)
  Assert.isTrue(absorbed.outcome.done, "the absorb pass completes")
  Assert.isNil(absorbed.bag:get(absorbed.instance.id), "poison arrivals absorb the toxic layers")
  Assert.equal(#absorbed.context.statused, 0, "absorbed layers poison nobody")
  Assert.equal(absorbed.outcome.events[1].kind, "absorb", "absorption announces itself")
  local warded = priceToxic({ version = 1, layers = 2 }, { "steel" }, true)
  Assert.equal(warded.health[3], 96, "steel arrivals take no toxic layers")
  Assert.equal(#warded.context.statused, 0, "steel arrivals wear no status")
  Assert.equal(#warded.outcome.events, 0, "repelled layers stay silent")
  local poisoned = priceToxic({ version = 1, layers = 1 }, { "normal" }, true)
  Assert.isTrue(poisoned.outcome.done, "the poison pass completes")
  Assert.equal(poisoned.health[3], 96, "toxic layers deal no damage")
  Assert.equal(#poisoned.context.statused, 1, "one layer poisons the arrival")
  Assert.equal(poisoned.context.statused[1], "poison", "one layer poisons plainly")
  Assert.equal(poisoned.outcome.events[1].kind, "hazard", "the poisoning announces its hazard")
  local badly = priceToxic({ version = 1, layers = 2 }, { "normal" }, true)
  Assert.equal(#badly.context.statused, 1, "two layers poison the arrival")
  Assert.equal(badly.context.statused[1], "toxic", "two layers poison badly")
  local aloft = priceToxic({ version = 1, layers = 2 }, { "normal" }, false)
  Assert.equal(#aloft.context.statused, 0, "levitating arrivals avoid the layers")
  Assert.equal(#aloft.outcome.events, 0, "avoided layers stay silent")
end

-- Residual handlers tick the new countdowns: nightmare drains
-- sleeping victims and expires on waking, binding drains and releases
-- on schedule, and flinch marks expire silently.
function T.residual_handlers_tick_the_new_countdowns()
  local Handlers = handlersOwner("residual handlers tick volatile countdowns")
  Assert.isTrue(type(Handlers.handlersFor) == "function", "residual handlers resolve by facts")
  local facts = {
    maxHp = { [2] = 96 },
    types = { [2] = { "normal" } },
    occupants = { [1] = 2 },
    slept = { [2] = true },
  }
  ---@param key string volatile identity under the tick
  ---@param state table<string, unknown> typed state under the tick
  ---@param health table<integer, integer> battle-local health under the tick
  ---@param extra table<string, unknown>|nil fact overrides for the tick
  ---@return table tick outcome with its health and events
  local function tick(key, state, health, extra)
    local bag = liveBag()
    addInstance(bag, key, { kind = "active", combatant = 2, activation = 7 }, state)
    local passFacts = {}
    for name, value in pairs(facts) do
      passFacts[name] = value
    end
    for name, value in pairs(extra or {}) do
      passFacts[name] = value
    end
    local handlers = Handlers.handlersFor(passFacts)
    local context = { health = health, speeds = { [2] = 10 }, stream = BattleRng.new(FIXED_SEED) }
    local outcome = invoke(bag, handlers, "residual", context)
    return { outcome = outcome, health = health, bag = bag }
  end
  local dream = tick("nightmare", { version = 1, turns = 1 }, { [2] = 96 })
  Assert.isTrue(dream.outcome.done, "the nightmare pass completes")
  Assert.equal(dream.health[2], 96 - 24, "nightmare drains one quarter")
  local woke = tick("nightmare", { version = 1, turns = 1 }, { [2] = 96 }, { slept = {} })
  Assert.equal(woke.health[2], 96, "waking takes no nightmare damage")
  local bound = tick("bind", { version = 1, turns = 3 }, { [2] = 96 })
  Assert.equal(bound.health[2], 96 - 6, "binding drains one sixteenth")
  local last = tick("bind", { version = 1, turns = 1 }, { [2] = 96 })
  Assert.equal(last.health[2], 96, "the zeroed countdown releases without damage")
  local flinched = tick("flinch", { version = 1, turns = 1 }, { [2] = 96 })
  Assert.isTrue(flinched.outcome.done, "the flinch pass completes")
  Assert.equal(#flinched.outcome.events, 0, "flinch expires silently")
end

return { tests = T }
