-- Typed evolution flow: accepting stages the whole result at once while
-- the live roster stays untouched, cancelling stages nothing and stays
-- retryable, side products commit or cancel with their primary, and
-- post-battle eligibility rechecks final roster state behind the terminal
-- result instead of serving stale mid-battle snapshots.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Experience = require("libs.mons.src.gen4.Experience")
local ItemFixture = require("libs.items.tests.item_fixture")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonStats = require("libs.mons.src.gen4.MonStats")

local T = {}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded evolution flow owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing mon behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the mon module loads")
  return loaded --[[@as table]]
end

---@param value unknown
---@return unknown detached copy of plain test data
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

---@return table shared item catalog for the vector roster
local function testItemCatalog()
  local ItemFixture = require("libs.items.tests.item_fixture")
  return ItemFixture.makeCatalog()
end

---@param root table<string, unknown> mutable synthetic mon asset root
local function addLineSlots(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local chikorita = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
  chikorita[0].evolutions = {
    { method = "level", level = 16, target = "TOTODILE", form = 0 },
    { method = "has_move", move = "CUT", target = "TOTODILE", form = 0 },
  }
  local function stats(hp, attack, defense, speed, specialAttack, specialDefense)
    return {
      hp = hp,
      attack = attack,
      defense = defense,
      speed = speed,
      specialAttack = specialAttack,
      specialDefense = specialDefense,
    }
  end
  local held = {
    common = { item = "NONE", nativeId = 0 },
    rare = { item = "NONE", nativeId = 0 },
  }
  species.NINCADA = {
    nativeId = 290,
    name = "NINCADA",
    growthCurve = "erratic",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 15,
    eggGroups = { "bug", "bug" },
    catchRate = 255,
    baseExpYield = 65,
    evYield = stats(0, 0, 1, 0, 0, 0),
    heldItems = copy(held),
    color = 3,
    flip = false,
    forms = {
      [0] = {
        baseStats = stats(31, 45, 90, 40, 30, 30),
        types = { "bug", "ground" },
        abilities = { "COMPOUND_EYES" },
        tmhm = {},
        levelUpMoves = {
          { level = 1, move = "SCRATCH" },
          { level = 1, move = "HARDEN" },
        },
        evolutions = {
          { method = "level_ninjask", level = 20, target = "NINJASK", form = 0 },
          { method = "level_shedinja", level = 20, target = "SHEDINJA", form = 0 },
        },
        icon = "NINCADA/f0",
        portrait = "NINCADA/f0/male/plain",
      },
    },
  }
  species.NINJASK = {
    nativeId = 291,
    name = "NINJASK",
    growthCurve = "erratic",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 15,
    eggGroups = { "bug", "bug" },
    catchRate = 120,
    baseExpYield = 155,
    evYield = stats(0, 0, 0, 2, 0, 0),
    heldItems = copy(held),
    color = 3,
    flip = false,
    forms = {
      [0] = {
        baseStats = stats(61, 90, 45, 160, 50, 50),
        types = { "bug", "flying" },
        abilities = { "SPEED_BOOST" },
        tmhm = {},
        levelUpMoves = {
          { level = 1, move = "SCRATCH" },
          { level = 1, move = "HARDEN" },
        },
        evolutions = {},
        icon = "NINJASK/f0",
        portrait = "NINJASK/f0/male/plain",
      },
    },
  }
  local abilities = root.abilities --[[@as table<string, table<string, unknown>>]]
  abilities.COMPOUND_EYES = { nativeId = 14, name = "Compound Eyes", description = "Compound Eyes" }
  abilities.SPEED_BOOST = { nativeId = 3, name = "Speed Boost", description = "Speed Boost" }
end

---@return table mon catalog carrying the vector slots
local function vectorCatalog()
  local root = CatalogFixture.buildAssetRoot()
  addLineSlots(root)
  return MonCatalog.new(root, testItemCatalog())
end

-- Learning vectors need current-level target entries: retail only offers
-- the staged species' learnset entries whose level equals the current
-- level, and the base TOTODILE learnset carries nothing at the level-16
-- evolution vector. The learning catalog stages two level-16 entries in
-- learnset order so the corrected set stays provable without touching the
-- shared fixture.
---@return table mon catalog carrying current-level learning entries
local function learningCatalog()
  local root = CatalogFixture.buildAssetRoot()
  addLineSlots(root)
  root.species.TOTODILE.forms[0].levelUpMoves = {
    { level = 1, move = "SCRATCH" },
    { level = 1, move = "LEER" },
    { level = 6, move = "WATER_GUN" },
    { level = 16, move = "QUICK_ATTACK" },
    { level = 16, move = "SAND_ATTACK" },
  }
  return MonCatalog.new(root, testItemCatalog())
end

---@param catalog table mon catalog under test
---@param seed integer fixed generator state for this roster member
---@param overrides table<string, unknown>|nil generation request overrides
---@return table persistent mon record owned by the mon domain
local function makeMon(catalog, seed, overrides)
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return factory:createNormal(CatalogFixture.normalRequest(overrides or {}))
end

---@param mon table mon record under test
---@param catalog table mon catalog under test
---@param level integer pinned level for this vector
---@return table the same mon at exactly the pinned level with full health
local function pinLevel(mon, catalog, level)
  local species = catalog:species(mon.species)
  mon.experience = Experience.expFor(catalog:growthCurve(species.growthCurve), level)
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    mon.ivs[key] = 10
    mon.evs[key] = 0
  end
  mon.condition.currentHp = MonStats.derive(mon, catalog).maxHp
  return mon
end

---@param overrides table<string, unknown>|nil world and trigger facts for one vector
---@return table trigger context with frozen clock, location, and party facts
local function vectorContext(overrides)
  local context = {
    game = "heartgold",
    timeOfDay = "day",
    location = "route_29",
    party = {},
    inventory = {},
    trigger = { kind = "level" },
  }
  for key, value in pairs(overrides or {}) do
    context[key] = value
  end
  return context
end

-- Moves covering the target learnset so the confirmation flow carries no
-- pending learning: the vector level holds no current-level target
-- entries, so retail cursor semantics offer nothing either way.
---@param mon table mon record under test
---@return table the same mon knowing the full low-level target set
local function teachTargetSet(mon)
  mon.moves = {
    { move = "SCRATCH", pp = 35, ppUps = 0 },
    { move = "LEER", pp = 30, ppUps = 0 },
    { move = "WATER_GUN", pp = 25, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  return mon
end

---@param Flow table evolution flow owner under test
---@param flow table open flow under test
---@return table the terminal step descriptor after accepting everything
local function acceptAll(Flow, flow)
  for _ = 1, 5 do
    local descriptor = Flow.step(flow)
    Assert.notNil(descriptor, "an open flow always offers a step")
    if descriptor.prompt == "complete" then
      return descriptor
    end
    Assert.equal(descriptor.prompt, "confirm_evolution", "the vector flow only confirms")
    Flow.respond(flow, { choice = "accept" })
  end
  error("the flow never completed")
  return {}
end

-- An accepted flow publishes the whole staged result at once: the
-- evolved mon, the empty side products, and the empty spends arrive
-- together, the live input never moves, and capturing twice changes
-- nothing further.
function T.accepted_flows_publish_the_whole_result_at_once()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  Assert.isTrue(type(Flow.start) == "function", "the flow owner starts flows")
  Assert.isTrue(type(Flow.step) == "function", "the flow owner steps flows")
  Assert.isTrue(type(Flow.respond) == "function", "the flow owner answers prompts")
  Assert.isTrue(type(Flow.capture) == "function", "the flow owner captures staged results")
  local catalog = vectorCatalog()
  local mon = teachTargetSet(pinLevel(makeMon(catalog, 311, {}), catalog, 16))
  local before = copy(mon)
  local flow = Flow.start(mon, vectorContext(), catalog)
  Assert.notNil(flow, "an eligible mon opens a flow")
  local first = Flow.step(flow)
  Assert.equal(first.prompt, "confirm_evolution", "the flow opens on confirmation")
  Assert.equal(first.species, "TOTODILE", "confirmation names the staged target")
  Assert.isTrue(first.canCancel, "level confirmation stays cancellable")
  acceptAll(Flow, flow)
  Assert.deepEqual(mon, before, "driving the flow never touches the live mon")
  local result = Flow.capture(flow)
  Assert.notNil(result, "an accepted flow captures a result")
  Assert.equal(result.mon.species, "TOTODILE", "the staged mon carries the target species")
  Assert.deepEqual(result.additionalMons, {}, "an ordinary result stages no extra mons")
  Assert.deepEqual(result.inventoryDeltas, {}, "an ordinary result stages no spends")
  Assert.deepEqual(mon, before, "capturing still leaves the live mon alone")
  Assert.deepEqual(Flow.capture(flow), result, "capturing twice stages nothing further")
  Assert.isTrue(
    Flow.start(pinLevel(makeMon(catalog, 313, {}), catalog, 9), vectorContext(), catalog) == nil,
    "an ineligible mon opens no flow"
  )
end

-- A cancelled flow publishes nothing: capture reports no result, the
-- roster and the bag match their before-images exactly, and opening
-- again stays possible.
function T.cancelled_flows_publish_nothing_and_stay_retryable()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local catalog = vectorCatalog()
  local mon = teachTargetSet(pinLevel(makeMon(catalog, 317, {}), catalog, 16))
  local before = copy(mon)
  local context = vectorContext({ inventory = { POKE_BALL = 5 } })
  local bag = copy(context.inventory)
  local flow = Flow.start(mon, context, catalog)
  Assert.notNil(flow, "an eligible mon opens a flow")
  local first = Flow.step(flow)
  Assert.equal(first.prompt, "confirm_evolution", "the flow opens on confirmation")
  Flow.respond(flow, { choice = "cancel" })
  local terminal = Flow.step(flow)
  Assert.equal(terminal.prompt, "cancelled", "a declined confirmation ends cancelled")
  Assert.isTrue(Flow.capture(flow) == nil, "a cancelled flow captures nothing")
  Assert.deepEqual(mon, before, "cancelling touches no live mon")
  Assert.deepEqual(context.inventory, bag, "cancelling spends nothing")
  local retry = Flow.start(mon, context, catalog)
  Assert.notNil(retry, "cancelling stays retryable")
  acceptAll(Flow, retry)
  local result = Flow.capture(retry)
  Assert.notNil(result, "the retried flow captures after accepting")
  Assert.equal(result.mon.species, "TOTODILE", "the retried result carries the target")
end

-- Side products commit or cancel with their primary in one result: the
-- accepted capture carries the evolved primary, the extra mon, and the
-- ball spend together, while the declined capture carries nothing at all.
function T.side_products_commit_or_cancel_atomically()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local catalog = vectorCatalog()
  local mon = pinLevel(makeMon(catalog, 331, { species = "NINCADA" }), catalog, 20)
  mon.moves = {
    { move = "SCRATCH", pp = 35, ppUps = 0 },
    { move = "HARDEN", pp = 30, ppUps = 0 },
  }
  local mate = pinLevel(makeMon(catalog, 337, {}), catalog, 9)
  local before = copy(mon)
  local context = vectorContext({ party = { mon, mate }, inventory = { POKE_BALL = 5 } })
  local flow = Flow.start(mon, context, catalog)
  Assert.notNil(flow, "the line member opens a flow")
  acceptAll(Flow, flow)
  local result = Flow.capture(flow)
  Assert.notNil(result, "the accepted flow captures")
  Assert.equal(result.mon.species, "NINJASK", "the staged primary carries the line target")
  Assert.equal(#result.additionalMons, 1, "the accepted capture carries the extra mon")
  Assert.equal(result.additionalMons[1].species, "SHEDINJA", "the extra mon is the shed side product")
  local spent = false
  for _, delta in ipairs(result.inventoryDeltas) do
    if delta.item == "POKE_BALL" then
      Assert.equal(delta.delta, -1, "the capture spends exactly one ball")
      spent = true
    end
  end
  Assert.isTrue(spent, "the ball spend commits with the capture")
  Assert.deepEqual(mon, before, "accepting touches no live mon before publication")
  local second = pinLevel(makeMon(catalog, 341, { species = "NINCADA" }), catalog, 20)
  second.moves = copy(mon.moves)
  local frozen = copy(second)
  local cancelled =
    Flow.start(second, vectorContext({ party = { second, mate }, inventory = { POKE_BALL = 5 } }), catalog)
  Assert.notNil(cancelled, "the second line member opens a flow")
  Flow.respond(cancelled, { choice = "cancel" })
  Assert.equal(Flow.step(cancelled).prompt, "cancelled", "the decline ends cancelled")
  Assert.isTrue(Flow.capture(cancelled) == nil, "the declined capture carries nothing")
  Assert.deepEqual(second, frozen, "declining leaves the whole candidate untouched")
end

-- Post-battle eligibility rechecks final roster state behind the terminal
-- result: a move learned during the battle qualifies afterwards while the
-- pre-battle snapshot never did, wins and flights stage while losses
-- stage nothing even when the level alone would qualify.
function T.post_battle_eligibility_uses_final_state_and_terminal_results()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  Assert.isTrue(type(Flow.eligibleAfterBattle) == "function", "the flow owner rechecks eligibility after battles")
  local catalog = vectorCatalog()
  local grown = pinLevel(makeMon(catalog, 359, {}), catalog, 16)
  grown.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "CUT", pp = 30, ppUps = 0 },
  }
  local young = pinLevel(makeMon(catalog, 367, {}), catalog, 9)
  local context = vectorContext({ party = { young, grown } })
  Assert.deepEqual(
    Flow.eligibleAfterBattle({ young }, "win", context, catalog),
    {},
    "the pre-battle snapshot stages nothing"
  )
  Assert.deepEqual(
    Flow.eligibleAfterBattle({ grown }, "win", context, catalog),
    { 1 },
    "the final state stages after a win"
  )
  Assert.deepEqual(
    Flow.eligibleAfterBattle({ grown }, "fled", context, catalog),
    { 1 },
    "the final state stages after flight"
  )
  Assert.deepEqual(
    Flow.eligibleAfterBattle({ grown }, "caught", context, catalog),
    { 1 },
    "the final state stages after a capture"
  )
  Assert.deepEqual(
    Flow.eligibleAfterBattle({ grown }, "loss", context, catalog),
    {},
    "a loss stages nothing despite the qualifying level"
  )
  Assert.deepEqual(
    Flow.eligibleAfterBattle({ young, grown }, "win", context, catalog),
    { 2 },
    "party order survives eligibility"
  )
end

-- A full move set pauses learning for explicit decisions on the corrected
-- set: only the staged target's current-level entries are offered, in
-- learnset order; the unknown lower-level entries never surface even
-- though LEER and WATER_GUN stay unlearned. Replacements land in the
-- named slot, declines keep the set, and the capture carries every
-- decision at once.
function T.full_sets_pause_learning_for_explicit_decisions()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local catalog = learningCatalog()
  local mon = pinLevel(makeMon(catalog, 701, {}), catalog, 16)
  mon.moves = {
    { move = "SCRATCH", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 35, ppUps = 0 },
  }
  local before = copy(mon)
  local flow = Flow.start(mon, vectorContext(), catalog)
  Assert.notNil(flow, "an eligible mon opens a flow")
  Assert.equal(Flow.step(flow).prompt, "confirm_evolution", "the flow opens on confirmation")
  Flow.respond(flow, { choice = "accept" })
  local first = Flow.step(flow)
  Assert.equal(first.prompt, "learn_move", "a full set pauses on the first unknown current-level chance")
  Assert.equal(first.move, "QUICK_ATTACK", "only current-level entries surface, in learnset order")
  Assert.equal(first.level, 16, "the prompt names the current level")
  Assert.deepEqual(
    first.currentMoves,
    { "SCRATCH", "GROWL", "RAZOR_LEAF", "POISONPOWDER" },
    "the prompt names the held set"
  )
  Flow.respond(flow, { choice = "replace", slot = 3 })
  local second = Flow.step(flow)
  Assert.equal(second.prompt, "learn_move", "the next unknown chance pauses as well")
  Assert.equal(second.move, "SAND_ATTACK", "learning follows learnset order")
  Assert.equal(second.level, 16, "lower-level entries never surface")
  Flow.respond(flow, { choice = "decline" })
  Assert.equal(Flow.step(flow).prompt, "complete", "answered chances resolve the flow")
  local result = Flow.capture(flow)
  Assert.notNil(result, "the decided flow captures")
  Assert.equal(result.mon.moves[4].move, "QUICK_ATTACK", "the replacement lands in the named slot")
  Assert.equal(result.mon.moves[4].pp, 30, "replacements reset to base power points")
  Assert.equal(#result.mon.moves, 4, "declines keep the set size")
  Assert.deepEqual(mon, before, "deciding never touches the live mon")
end

-- Lower-level target moves are never offered after evolution: a mon with
-- free slots that knows none of the target set still completes at once
-- with its move set untouched, even though every target entry sits at or
-- below the current level.
function T.evolution_learning_ignores_lower_level_target_moves()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local catalog = vectorCatalog()
  local mon = pinLevel(makeMon(catalog, 709, {}), catalog, 16)
  mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
  }
  local before = copy(mon)
  local flow = Flow.start(mon, vectorContext(), catalog)
  Assert.notNil(flow, "an eligible mon opens a flow")
  Assert.equal(Flow.step(flow).prompt, "confirm_evolution", "the flow opens on confirmation")
  Flow.respond(flow, { choice = "accept" })
  Assert.equal(Flow.step(flow).prompt, "complete", "lower-level entries never pause the flow")
  local result = Flow.capture(flow)
  Assert.notNil(result, "the untouched flow captures")
  Assert.deepEqual(result.mon.moves, before.moves, "lower-level entries never fill free slots")
  Assert.deepEqual(mon, before, "driving the flow never touches the live mon")
end

-- Current-level target moves fill free slots silently: with room in the
-- set, every unknown current-level entry lands in learnset order without
-- pausing, and the flow completes at once.
function T.current_level_moves_fill_free_slots_silently()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local catalog = learningCatalog()
  local mon = pinLevel(makeMon(catalog, 703, {}), catalog, 16)
  mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
  }
  local before = copy(mon)
  local flow = Flow.start(mon, vectorContext(), catalog)
  Assert.notNil(flow, "an eligible mon opens a flow")
  Assert.equal(Flow.step(flow).prompt, "confirm_evolution", "the flow opens on confirmation")
  Flow.respond(flow, { choice = "accept" })
  Assert.equal(Flow.step(flow).prompt, "complete", "free slots fill without pausing")
  local result = Flow.capture(flow)
  Assert.notNil(result, "the silent flow captures")
  Assert.deepEqual(
    result.mon.moves,
    {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "QUICK_ATTACK", pp = 30, ppUps = 0 },
      { move = "SAND_ATTACK", pp = 15, ppUps = 0 },
    },
    "current-level entries fill free slots in learnset order"
  )
  Assert.deepEqual(mon, before, "filling never touches the live mon")
end

-- Already-known current-level moves pass silently: a full set holding one
-- of the current-level entries pauses only for the unknown one.
function T.known_current_level_moves_pass_silently()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local catalog = learningCatalog()
  local mon = pinLevel(makeMon(catalog, 727, {}), catalog, 16)
  mon.moves = {
    { move = "QUICK_ATTACK", pp = 30, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 35, ppUps = 0 },
  }
  local flow = Flow.start(mon, vectorContext(), catalog)
  Assert.notNil(flow, "an eligible mon opens a flow")
  Assert.equal(Flow.step(flow).prompt, "confirm_evolution", "the flow opens on confirmation")
  Flow.respond(flow, { choice = "accept" })
  local prompt = Flow.step(flow)
  Assert.equal(prompt.prompt, "learn_move", "the unknown chance still pauses")
  Assert.equal(prompt.move, "SAND_ATTACK", "the known current-level entry passes silently")
  Flow.respond(flow, { choice = "decline" })
  Assert.equal(Flow.step(flow).prompt, "complete", "the declined chance resolves the flow")
  local result = Flow.capture(flow)
  Assert.notNil(result, "the decided flow captures")
  Assert.equal(result.mon.moves[1].move, "QUICK_ATTACK", "declines keep the held set")
  Assert.equal(#result.mon.moves, 4, "declines keep the set size")
end

-- Rejected answers fail without moving state: a cancelled trade refuses to
-- cancel, garbage answers refuse everywhere, and captures before
-- completion stay empty while the confirmation waits.
function T.invalid_flow_answers_fail_without_moving_state()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local root = CatalogFixture.buildAssetRoot()
  local forms = root.species.CHIKORITA.forms
  forms[0].evolutions = {
    { method = "trade", target = "TOTODILE", form = 0 },
  }
  local tradeCatalog = MonCatalog.new(root, testItemCatalog())
  local factory = CatalogFixture.makeFactory(719, tradeCatalog)
  local trader = pinLevel(factory:createNormal(CatalogFixture.normalRequest({})), tradeCatalog, 12)
  trader.moves = {
    { move = "SCRATCH", pp = 35, ppUps = 0 },
    { move = "LEER", pp = 30, ppUps = 0 },
    { move = "WATER_GUN", pp = 25, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local flow = Flow.start(trader, vectorContext({ trigger = { kind = "trade" } }), tradeCatalog)
  Assert.notNil(flow, "a traded mon opens a flow")
  local first = Flow.step(flow)
  Assert.equal(first.prompt, "confirm_evolution", "the trade flow opens on confirmation")
  Assert.isFalse(first.canCancel, "traded results are not cancellable")
  Assert.throws(function()
    Flow.respond(flow, { choice = "cancel" })
  end, "cancelling a trade fails")
  Assert.throws(function()
    Flow.respond(flow, { choice = "maybe" })
  end, "a garbage confirmation fails")
  Assert.equal(Flow.step(flow).prompt, "confirm_evolution", "rejected answers leave the confirmation waiting")
  Assert.isTrue(Flow.capture(flow) == nil, "an unconfirmed flow captures nothing")
  Flow.respond(flow, { choice = "accept" })
  Assert.equal(Flow.step(flow).prompt, "complete", "a fully-known set completes at once")
  Assert.throws(function()
    Flow.respond(flow, { choice = "accept" })
  end, "answering a resolved flow fails")
  local result = Flow.capture(flow)
  Assert.notNil(result, "the accepted trade captures")
  Assert.equal(result.mon.species, "TOTODILE", "the capture carries the target")
  Assert.deepEqual(
    Flow.eligibleAfterBattle({ trader }, "draw", vectorContext(), tradeCatalog),
    {},
    "an unknown terminal result stages nothing"
  )
end

-- Trade triggers stage both native trade slots at the flow level: the
-- unconditional slot answers barehanded while the held-item slot answers
-- only while holding its named item, level triggers never open trade
-- slots, and every trade flow opens non-cancellable.
function T.trade_triggers_stage_plain_and_held_item_trade_evolutions()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local root = CatalogFixture.buildAssetRoot()
  root.species.CHIKORITA.forms[0].evolutions = {
    { method = "trade_item", item = "KINGS_ROCK", target = "EEVEE", form = 0 },
    { method = "trade", target = "TOTODILE", form = 0 },
  }
  local catalog = MonCatalog.new(root, testItemCatalog())
  local function tradeContext()
    return vectorContext({ trigger = { kind = "trade" } })
  end
  local bare = pinLevel(makeMon(catalog, 811, {}), catalog, 12)
  local bareFlow = Flow.start(bare, tradeContext(), catalog)
  Assert.notNil(bareFlow, "a bare mon opens a trade flow")
  local bareFirst = Flow.step(bareFlow)
  Assert.equal(bareFirst.prompt, "confirm_evolution", "the trade flow opens on confirmation")
  Assert.equal(bareFirst.species, "TOTODILE", "the bare trade slot stages its own target")
  Assert.isFalse(bareFirst.canCancel, "trade results are not cancellable")
  acceptAll(Flow, bareFlow)
  local bareResult = Flow.capture(bareFlow)
  Assert.notNil(bareResult, "the accepted trade captures")
  Assert.equal(bareResult.mon.species, "TOTODILE", "the capture carries the trade target")
  local holder = pinLevel(makeMon(catalog, 823, {}), catalog, 12)
  holder.heldItem = "KINGS_ROCK"
  local heldFlow = Flow.start(holder, tradeContext(), catalog)
  Assert.notNil(heldFlow, "a holder opens a trade flow")
  local heldFirst = Flow.step(heldFlow)
  Assert.equal(heldFirst.prompt, "confirm_evolution", "the held flow opens on confirmation")
  Assert.equal(heldFirst.species, "EEVEE", "the first matching held slot wins in source order")
  Assert.isFalse(heldFirst.canCancel, "held trade results are not cancellable")
  local itemOnly = CatalogFixture.buildAssetRoot()
  itemOnly.species.CHIKORITA.forms[0].evolutions = {
    { method = "trade_item", item = "KINGS_ROCK", target = "EEVEE", form = 0 },
  }
  local itemCatalog = MonCatalog.new(itemOnly, testItemCatalog())
  local emptyHanded = pinLevel(makeMon(itemCatalog, 829, {}), itemCatalog, 12)
  Assert.isTrue(
    Flow.start(emptyHanded, vectorContext({ trigger = { kind = "trade" } }), itemCatalog) == nil,
    "trade without the held item stages nothing"
  )
  Assert.isTrue(
    Flow.start(pinLevel(makeMon(catalog, 839, {}), catalog, 16), vectorContext(), catalog) == nil,
    "level triggers never open trade slots"
  )
end

-- Trade flows reject cancellation and consume held trade items on
-- capture: cancelling either the plain or the held-item flow fails, the
-- staged mon arrives barehanded with no bag spend, and the live mon keeps
-- its item until publication.
function T.trade_flows_reject_cancel_and_consume_held_trade_items()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local root = CatalogFixture.buildAssetRoot()
  root.species.CHIKORITA.forms[0].evolutions = {
    { method = "trade", target = "TOTODILE", form = 0 },
  }
  local catalog = MonCatalog.new(root, testItemCatalog())
  local plain = pinLevel(makeMon(catalog, 853, {}), catalog, 12)
  local plainFlow = Flow.start(plain, vectorContext({ trigger = { kind = "trade" } }), catalog)
  Assert.notNil(plainFlow, "a traded mon opens a flow")
  Assert.throws(function()
    Flow.respond(plainFlow, { choice = "cancel" })
  end, "cancelling a plain trade fails")
  local heldRoot = CatalogFixture.buildAssetRoot()
  heldRoot.species.CHIKORITA.forms[0].evolutions = {
    { method = "trade_item", item = "KINGS_ROCK", target = "EEVEE", form = 0 },
  }
  local heldCatalog = MonCatalog.new(heldRoot, testItemCatalog())
  local holder = pinLevel(makeMon(heldCatalog, 859, {}), heldCatalog, 12)
  holder.heldItem = "KINGS_ROCK"
  local before = copy(holder)
  local heldFlow = Flow.start(holder, vectorContext({ trigger = { kind = "trade" } }), heldCatalog)
  Assert.notNil(heldFlow, "a holder opens a flow")
  Assert.throws(function()
    Flow.respond(heldFlow, { choice = "cancel" })
  end, "cancelling a held trade fails")
  Assert.equal(Flow.step(heldFlow).prompt, "confirm_evolution", "rejected cancels leave the confirmation waiting")
  Flow.respond(heldFlow, { choice = "accept" })
  Assert.equal(Flow.step(heldFlow).prompt, "complete", "a fully-known set completes at once")
  local result = Flow.capture(heldFlow)
  Assert.notNil(result, "the accepted held trade captures")
  Assert.equal(result.mon.species, "EEVEE", "the capture carries the held trade target")
  Assert.equal(result.mon.heldItem, "NONE", "the held trade item is consumed")
  Assert.deepEqual(result.inventoryDeltas, {}, "held consumption stages no bag spend")
  Assert.deepEqual(holder, before, "driving the flow never touches the live mon")
end

-- The held blocker still stops trade checks at the flow level, with the
-- single source-named exemption: an Everstone holder stages nothing on
-- the trade trigger while KADABRA holding one still evolves.
function T.everstone_blocks_trade_evolutions_except_for_kadabra()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local root = CatalogFixture.buildAssetRoot()
  root.species.CHIKORITA.forms[0].evolutions = {
    { method = "trade", target = "TOTODILE", form = 0 },
  }
  root.species.KADABRA = {
    nativeId = 64,
    name = "KADABRA",
    growthCurve = "medium_slow",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 20,
    eggGroups = { "monster", "monster" },
    catchRate = 100,
    baseExpYield = 105,
    evYield = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 2, specialDefense = 0 },
    heldItems = {
      common = { item = "NONE", nativeId = 0 },
      rare = { item = "NONE", nativeId = 0 },
    },
    color = 3,
    flip = false,
    forms = {
      [0] = {
        baseStats = { hp = 40, attack = 35, defense = 30, speed = 105, specialAttack = 120, specialDefense = 70 },
        types = { "psychic" },
        abilities = { "STATIC" },
        tmhm = {},
        levelUpMoves = {
          { level = 1, move = "TACKLE" },
        },
        evolutions = {
          { method = "trade", target = "TOTODILE", form = 0 },
        },
        icon = "KADABRA/f0",
        portrait = "KADABRA/f0/male/plain",
      },
    },
  }
  local catalog = MonCatalog.new(root, testItemCatalog())
  local blocked = pinLevel(makeMon(catalog, 877, {}), catalog, 12)
  blocked.heldItem = "EVERSTONE"
  Assert.isTrue(
    Flow.start(blocked, vectorContext({ trigger = { kind = "trade" } }), catalog) == nil,
    "the held blocker stops the trade trigger"
  )
  local exempt = pinLevel(makeMon(catalog, 883, { species = "KADABRA" }), catalog, 12)
  exempt.heldItem = "EVERSTONE"
  exempt.moves = {
    { move = "SCRATCH", pp = 35, ppUps = 0 },
    { move = "LEER", pp = 30, ppUps = 0 },
    { move = "WATER_GUN", pp = 25, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local exemptFlow = Flow.start(exempt, vectorContext({ trigger = { kind = "trade" } }), catalog)
  Assert.notNil(exemptFlow, "the exempt species opens a trade flow while holding the blocker")
  Assert.isFalse(Flow.step(exemptFlow).canCancel, "the exempt trade stays non-cancellable")
  acceptAll(Flow, exemptFlow)
  local result = Flow.capture(exemptFlow)
  Assert.notNil(result, "the exempt trade captures")
  Assert.equal(result.mon.species, "TOTODILE", "the exempt capture carries the trade target")
end

-- Post-battle eligibility never fires trade evolutions: a mon carrying
-- only a trade slot stages nothing behind any terminal result, even
-- though the same mon evolves on the trade trigger itself.
function T.post_battle_level_rechecks_never_stage_trade_evolutions()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  Assert.isTrue(type(Flow.eligibleAfterBattle) == "function", "the flow owner rechecks eligibility after battles")
  local root = CatalogFixture.buildAssetRoot()
  root.species.CHIKORITA.forms[0].evolutions = {
    { method = "trade", target = "TOTODILE", form = 0 },
  }
  local catalog = MonCatalog.new(root, testItemCatalog())
  local trader = pinLevel(makeMon(catalog, 907, {}), catalog, 16)
  Assert.notNil(
    Flow.start(trader, vectorContext({ trigger = { kind = "trade" } }), catalog),
    "the vector mon evolves on the trade trigger"
  )
  local context = vectorContext()
  for _, outcome in ipairs({ "win", "caught", "fled" }) do
    Assert.deepEqual(
      Flow.eligibleAfterBattle({ trader }, outcome, context, catalog),
      {},
      "the level recheck stages no trade evolution after " .. outcome
    )
  end
  Assert.deepEqual(
    Flow.eligibleAfterBattle({ trader }, "loss", context, catalog),
    {},
    "a loss stages nothing either"
  )
end

return { tests = T }
