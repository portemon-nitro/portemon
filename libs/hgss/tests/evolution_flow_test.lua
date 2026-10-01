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
-- pending learning: every target entry at or below the vector level is
-- already known.
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
  Assert.isTrue(Flow.start(pinLevel(makeMon(catalog, 313, {}), catalog, 9), vectorContext(), catalog) == nil, "an ineligible mon opens no flow")
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
  local cancelled = Flow.start(second, vectorContext({ party = { second, mate }, inventory = { POKE_BALL = 5 } }), catalog)
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
  Assert.isTrue(
    type(Flow.eligibleAfterBattle) == "function",
    "the flow owner rechecks eligibility after battles"
  )
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
  Assert.deepEqual(Flow.eligibleAfterBattle({ young }, "win", context, catalog), {}, "the pre-battle snapshot stages nothing")
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

-- A full move set pauses learning for explicit decisions: already-known
-- chances pass silently, replacements land in the named slot, declines keep
-- the set, and the capture carries every decision at once.
function T.full_sets_pause_learning_for_explicit_decisions()
  local Flow = requirePresent("libs.hgss.src.mons.EvolutionFlow", "concrete evolution flow owns staging")
  local catalog = vectorCatalog()
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
  Assert.equal(first.prompt, "learn_move", "a full set pauses on the first unknown chance")
  Assert.equal(first.move, "LEER", "already-known chances pass silently")
  Assert.deepEqual(first.currentMoves, { "SCRATCH", "GROWL", "RAZOR_LEAF", "POISONPOWDER" }, "the prompt names the held set")
  Flow.respond(flow, { choice = "replace", slot = 3 })
  local second = Flow.step(flow)
  Assert.equal(second.prompt, "learn_move", "the next unknown chance pauses as well")
  Assert.equal(second.move, "WATER_GUN", "learning follows learnset order")
  Flow.respond(flow, { choice = "decline" })
  Assert.equal(Flow.step(flow).prompt, "complete", "answered chances resolve the flow")
  local result = Flow.capture(flow)
  Assert.notNil(result, "the decided flow captures")
  Assert.equal(result.mon.moves[4].move, "LEER", "the replacement lands in the named slot")
  Assert.equal(result.mon.moves[4].pp, 30, "replacements reset to base power points")
  Assert.equal(#result.mon.moves, 4, "declines keep the set size")
  Assert.deepEqual(mon, before, "deciding never touches the live mon")
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

return { tests = T }
