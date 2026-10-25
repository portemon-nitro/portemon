-- Unit coverage for the private event-time playback facts: route
-- selection for every emitted kind, suppression flags, deterministic
-- visual seeds without stream draws, actor/target resolution against
-- live entries, move pair and phase facts, turn-global hit ordinals,
-- and mechanics invariance across decorated runs. Pure projections run
-- over small synthetic states; transcript comparisons run the real
-- native session with fixed seeds.

local Assert = require("tests.support.Assert")
local PresentationFacts = require("libs.battle.src.gen4.PresentationFacts")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table<string, unknown> minimal live state with two entered combatants on opposing sides
local function twoUpState()
  return {
    turnStrikeOrdinal = 0,
    sequence = 0,
    combatants = {
      [1] = { participant = 1, hp = 20, maxHp = 25, active = { position = 1, activation = 7 } },
      [2] = { participant = 2, hp = 18, maxHp = 22, active = { position = 2, activation = 9 } },
    },
    participants = {
      [1] = { side = 1, controller = "alpha" },
      [2] = { side = 2, controller = "beta" },
    },
  }
end

---@param kind string event kind under emission
---@param cause table<string, unknown> semantic cause under emission
---@param payload table<string, unknown> event payload under emission
---@param sequence integer sequence ordinal under emission
---@return table<string, unknown> bare event as the emitters build it before decoration
local function bareEvent(kind, cause, payload, sequence)
  return {
    sequence = sequence,
    kind = kind,
    cause = cause,
    audience = "public",
    payload = payload,
    observation = {
      hp = { [1] = 20, [2] = 18 },
      combatants = {
        [1] = { participant = 1, position = 1, activation = 7, hp = 20, maxHp = 25, side = 1 },
        [2] = { participant = 2, position = 2, activation = 9, hp = 18, maxHp = 22, side = 2 },
      },
    },
  }
end

-- Every emitted kind selects a distinct non-empty playback route, and
-- unknown kinds keep their honest identity instead of vanishing.
function T.every_emitted_kind_selects_its_playback_route()
  local kinds = {
    "move-used",
    "struck",
    "strike",
    "missed",
    "protected",
    "charged",
    "delayed",
    "substitute-broke",
    "recoil",
    "drained",
    "healed",
    "tick",
    "faint",
    "fainted",
    "leveled",
    "transformed",
    "sketched",
    "mimicked",
    "status",
    "cured",
    "stage",
    "status-gate",
    "switch",
    "switch-intent",
    "item-intent",
    "item",
    "flee",
    "acknowledge",
    "join",
    "exp",
    "stats",
    "learn",
    "declined",
    "throw",
    "shake",
    "caught",
    "broke_free",
  }
  for _, kind in ipairs(kinds) do
    local route = PresentationFacts.flowKeyFor(kind)
    Assert.isTrue(type(route) == "string" and route ~= "", "the route names its flow: " .. kind)
  end
  Assert.equal(PresentationFacts.flowKeyFor("missed"), "miss", "a miss never shares its route")
  Assert.equal(PresentationFacts.flowKeyFor("protected"), "protect", "protection never shares its route")
  Assert.equal(PresentationFacts.flowKeyFor("charged"), "charge", "a charge never shares its route")
  Assert.equal(
    PresentationFacts.flowKeyFor("substitute-broke"),
    "substitute-break",
    "a substitute break never shares its route"
  )
  Assert.equal(PresentationFacts.flowKeyFor("transformed"), "transform", "a transform never shares its route")
  Assert.equal(PresentationFacts.flowKeyFor("mimicked"), "mimic", "a Mimic move uses its own playback route")
  Assert.equal(PresentationFacts.flowKeyFor("mystery-kind"), "mystery-kind", "unknown kinds keep their identity")
end

-- Suppression flags ride only on suppressed actions; connected actions
-- carry none.
function T.suppression_flags_mark_only_suppressed_actions()
  Assert.deepEqual(PresentationFacts.suppressionFor("missed"), { missed = true }, "misses suppress")
  Assert.deepEqual(PresentationFacts.suppressionFor("protected"), { protected = true }, "protection suppresses")
  Assert.isNil(PresentationFacts.suppressionFor("struck"), "connected strikes carry no suppression")
  Assert.isNil(PresentationFacts.suppressionFor("healed"), "recovery carries no suppression")
end

-- Visual seeds are deterministic per identity and never draw from a
-- stream: the same identity always answers the same seed.
function T.visual_seeds_stay_deterministic_without_stream_draws()
  Assert.equal(PresentationFacts.visualSeedFor(1), PresentationFacts.visualSeedFor(1), "one identity replays one seed")
  Assert.isTrue(type(PresentationFacts.visualSeedFor(1)) == "number", "visual seeds stay numeric particle facts")
  Assert.isTrue(
    PresentationFacts.visualSeedFor(1) ~= PresentationFacts.visualSeedFor(2),
    "distinct identities vary their particles"
  )
end

-- Move-route selections name the executed move; other kinds select no route.
function T.move_routes_name_the_executed_move()
  Assert.equal(PresentationFacts.effectKeyFor("struck", "TACKLE"), "TACKLE", "strikes route by execution")
  Assert.equal(PresentationFacts.effectKeyFor("move-used", "TAIL_WHIP"), "TAIL_WHIP", "uses route by execution")
  Assert.isNil(PresentationFacts.effectKeyFor("healed", "TACKLE"), "recovery selects no route")
  Assert.isNil(PresentationFacts.effectKeyFor("struck", nil), "a missing execution selects no route")
end

-- Decoration names the true user and recipient from the executing
-- scope, keeps the requested and executed move pair apart, and stamps
-- the charge phase on charging turns.
function T.decoration_names_the_true_user_and_move_pair()
  local state = twoUpState()
  local scope = {
    actor = { combatant = 1, activation = 7 },
    targets = { { combatant = 2 } },
    requestedMove = "METRONOME",
    executingMove = "TACKLE",
  }
  local event = bareEvent("struck", { key = "TACKLE" }, { target = 2, hitIndex = 1, damage = 4 }, 11)
  PresentationFacts.decorate(state, event, scope)
  Assert.equal(#event.actors, 1, "the strike names its single user")
  Assert.equal(event.actors[1].combatant, 1, "the user is the true attacker, never a nearby battler")
  Assert.equal(event.actors[1].activation, 7, "the user carries its stable entry token")
  Assert.equal(event.actors[1].side, 1, "the user carries its side")
  Assert.equal(#event.targets, 1, "the strike names its single recipient")
  Assert.equal(event.targets[1].combatant, 2, "the recipient is the true target")
  Assert.equal(event.move.selected, "METRONOME", "the selected identity survives beside the execution")
  Assert.equal(event.move.executed, "TACKLE", "the executed identity never collapses into the selection")
  Assert.equal(event.move.phase, "direct", "ordinary strikes carry the direct phase")
  Assert.equal(event.flowKey, "strike", "strikes select their route")
  Assert.equal(event.effectKey, "TACKLE", "strikes route by execution")
  Assert.isTrue(type(event.visualSeed) == "number", "strikes carry their independent visual seed")
  Assert.equal(#event.checkpoints, 2, "strikes keep every ordered display checkpoint")
  Assert.equal(event.checkpoints[1].hp, 20, "checkpoints keep displayed health in combatant order")
  Assert.equal(event.checkpoints[1].maxHp, 25, "checkpoints keep the health ceiling")
  local charged = bareEvent("charged", { key = "SOLAR_BEAM" }, { target = 1 }, 12)
  PresentationFacts.decorate(state, charged, scope)
  Assert.equal(charged.move.executed, "SOLAR_BEAM", "a stale scope never lends its move to another execution")
  Assert.equal(charged.move.phase, "charge", "charging turns carry their phase")
end

-- A stale scope from an earlier strike never lends its user to another
-- move: causes select their own scope by execution identity.
function T.stale_scopes_never_lend_their_user()
  local state = twoUpState()
  local scope = {
    actor = { combatant = 1, activation = 7 },
    targets = { { combatant = 2 } },
    requestedMove = "TACKLE",
    executingMove = "TACKLE",
  }
  local event = bareEvent("struck", { key = "EMBER" }, { target = 2, hitIndex = 1, damage = 4 }, 13)
  PresentationFacts.decorate(state, event, scope)
  Assert.equal(event.move.selected, "EMBER", "the selection follows the ordering cause")
  Assert.equal(event.move.executed, "EMBER", "the execution follows the ordering cause")
end

-- Multi-hit occurrences receive gapless turn-global ordinals in source
-- order, while the payload keeps its native target indexing untouched.
function T.multi_hit_occurrences_take_gapless_turn_ordinals()
  local state = twoUpState()
  local scope = {
    actor = { combatant = 1, activation = 7 },
    targets = { { combatant = 2 } },
    requestedMove = "BULLET_SEED",
    executingMove = "BULLET_SEED",
  }
  local ordinals = {}
  for index = 1, 3 do
    local event = bareEvent("struck", { key = "BULLET_SEED" }, { target = 2, hitIndex = 1, damage = 1 }, 20 + index)
    PresentationFacts.decorate(state, event, scope)
    ordinals[#ordinals + 1] = event.move.hitOrdinal
    Assert.equal(event.payload.hitIndex, 1, "the native target index stays untouched")
  end
  Assert.deepEqual(ordinals, { 1, 2, 3 }, "occurrences increase without gaps in source order")
end

-- Replacements name their arrival as the actor and their departure as
-- the target, carrying the departure token the cause still knows.
function T.replacements_name_arrival_and_departure_apart()
  local state = twoUpState()
  state.combatants[2] = { participant = 2, hp = 0, maxHp = 22, active = nil }
  state.combatants[4] = { participant = 2, hp = 20, maxHp = 20, active = { position = 2, activation = 11 } }
  local event = bareEvent(
    "switch",
    { kind = "faint", combatant = 2, activation = 9 },
    { position = 2, from = 2, to = 4 },
    30
  )
  PresentationFacts.decorate(state, event, nil)
  Assert.equal(#event.actors, 1, "the replacement names its arrival")
  Assert.equal(event.actors[1].combatant, 4, "the arrival is the incoming battler")
  Assert.equal(event.actors[1].activation, 11, "the arrival carries its own entry token")
  Assert.equal(#event.targets, 1, "the replacement names its departure")
  Assert.equal(event.targets[1].combatant, 2, "the departure is the prior occupant")
  Assert.equal(event.targets[1].activation, 9, "the departure keeps the token the cause still knows")
  Assert.equal(event.flowKey, "switch", "replacements select their route")
end

-- A resolved variable power snapshots onto the playback move fact only
-- for its own execution: the pinned scope value rides beside the move
-- pair, scopes without a resolved value omit the fact, a stale scope
-- never lends its value to another execution, and malformed values fail
-- loudly instead of publishing a guess.
function T.resolved_power_snapshots_only_for_its_own_execution()
  local state = twoUpState()
  local scope = {
    actor = { combatant = 1, activation = 7 },
    targets = { { combatant = 2 } },
    requestedMove = "MAGNITUDE",
    executingMove = "MAGNITUDE",
    animationPower = 90,
  }
  local event = bareEvent("struck", { key = "MAGNITUDE" }, { target = 2, hitIndex = 1, damage = 4 }, 14)
  PresentationFacts.decorate(state, event, scope)
  Assert.equal(event.move.power, 90, "the resolved value rides beside the move pair")
  scope.animationPower = 10
  Assert.equal(event.move.power, 90, "later scope edits never rewrite the emitted fact")
  local plain = bareEvent("struck", { key = "TACKLE" }, { target = 2, hitIndex = 1, damage = 4 }, 15)
  PresentationFacts.decorate(state, plain, {
    actor = { combatant = 1, activation = 7 },
    targets = { { combatant = 2 } },
    requestedMove = "TACKLE",
    executingMove = "TACKLE",
  })
  Assert.isNil(plain.move.power, "scopes without a resolved value omit the fact")
  local stale = bareEvent("struck", { key = "EMBER" }, { target = 2, hitIndex = 1, damage = 4 }, 16)
  PresentationFacts.decorate(state, stale, scope)
  Assert.isNil(stale.move.power, "a stale scope never lends its value to another execution")
  for _, bad in ipairs({ 1.5, -1, 65536, "90" }) do
    local broken = bareEvent("struck", { key = "MAGNITUDE" }, { target = 2, hitIndex = 1, damage = 4 }, 17)
    local tainted = {
      actor = { combatant = 1, activation = 7 },
      targets = { { combatant = 2 } },
      requestedMove = "MAGNITUDE",
      executingMove = "MAGNITUDE",
      animationPower = bad,
    }
    Assert.throws(function()
      PresentationFacts.decorate(state, broken, tainted)
    end, "a malformed resolved value fails loudly: " .. tostring(bad))
  end
end

-- Move-ordered causes carry their typed kind while lifecycle causes keep
-- theirs; decoration never rewrites an existing kind.
function T.move_causes_carry_their_typed_kind()
  local state = twoUpState()
  local struck = bareEvent("struck", { key = "TACKLE" }, { target = 2, hitIndex = 1, damage = 4 }, 40)
  PresentationFacts.decorate(state, struck, nil)
  Assert.equal(struck.cause.kind, "move", "move-ordered causes name their kind")
  Assert.equal(struck.cause.key, "TACKLE", "the move identity stays beside its kind")
  local gated = bareEvent("status-gate", { kind = "status-gate", combatant = 1 }, { combatant = 1, key = "sleep" }, 41)
  PresentationFacts.decorate(state, gated, nil)
  Assert.equal(gated.cause.kind, "status-gate", "lifecycle causes keep their kind")
  Assert.equal(#gated.actors, 1, "gate events name their gated battler")
  Assert.equal(gated.actors[1].combatant, 1, "the gated battler is the true subject")
end

-- Identical seeds replay identical mechanics with projection on: event
-- kinds, sequences, payloads, and terminal captures match exactly, so
-- reading facts never moves health, order, or randomness.
function T.identical_seeds_replay_identical_mechanics_with_projection()
  local function executorOwner()
    return SessionFixture.requirePresent(
      "libs.battle.src.gen4.HgssSessionExecutor",
      "the private native lifecycle owns sessions"
    )
  end
  local function content(formats)
    local ContentBuilder = require("libs.content.src.ContentBuilder")
    local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
    local BattleContent = require("libs.battle.src.BattleContent")
    local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
    local Executor = executorOwner()
    local builder = ContentBuilder.new()
    NativeTypeChart.install(builder, "native-facts-twins")
    local behaviors = BattleBehaviorBuilder.new()
    behaviors:registerRuleset(
      Executor.RULESET,
      { key = Executor.RULESET, chart = Executor.RULESET },
      "native-facts-twins"
    )
    for _, key in ipairs(formats) do
      behaviors:registerFormat(key, { key = key }, "native-facts-twins")
    end
    return BattleContent.new(builder:freeze(), behaviors:freeze())
  end
  local function combatant(id, seed)
    local entry = SessionFixture.combatant(id, seed)
    entry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    return entry
  end
  local function factsFor(seeds)
    local CatalogFixture = require("libs.mons.tests.catalog_fixture")
    local catalog = CatalogFixture.makeCatalog()
    local facts = {
      TACKLE = catalog:move("TACKLE"),
      STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
    }
    return facts
  end
  local function speciesFor(seeds)
    local CatalogFixture = require("libs.mons.tests.catalog_fixture")
    local catalog = CatalogFixture.makeCatalog()
    local facts = {}
    for _, seed in ipairs(seeds) do
      local mon = seed.mon
      local record = catalog:species(mon.species)
      local bucket = facts[mon.species]
      if bucket == nil then
        bucket = {}
        facts[mon.species] = bucket
      end
      local form = catalog:form(mon.species, mon.form)
      local types = {}
      for _, key in ipairs(form.types) do
        types[#types + 1] = key
      end
      bucket[mon.form] = {
        baseStats = form.baseStats,
        growthCurve = catalog:growthCurve(record.growthCurve),
        types = types,
        levelUpMoves = form.levelUpMoves,
        baseExpYield = record.baseExpYield,
        evYield = record.evYield,
        genderRatio = record.genderRatio,
      }
    end
    return facts
  end
  local function runTwin()
    local Executor = executorOwner()
    local alpha = { combatant(1, 11) }
    local beta = { combatant(2, 23) }
    local seeds = { alpha[1], beta[1] }
    local session = Executor.new({
      ruleset = Executor.RULESET,
      format = "test:native-facts-twins",
      sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
      participants = {
        SessionFixture.participant(1, 1, "alpha", alpha),
        SessionFixture.participant(2, 2, "beta", beta),
      },
      positions = {
        SessionFixture.position(1, 1, { 1 }, alpha[1].id),
        SessionFixture.position(2, 2, { 2 }, beta[1].id),
      },
      inventories = {},
      environment = { weather = "none" },
      random = { seed = 0x1BADB002 },
      formatState = {},
      moveFacts = factsFor(seeds),
      speciesFacts = speciesFor(seeds),
    }, content({ "test:native-facts-twins" }))
    local frame = SessionFixture.driveUntilSettled(session)
    local function requestFor(waiting, controller)
      for _, request in ipairs(waiting.request.requests) do
        if request.controller == controller then
          return request
        end
      end
      error("no request for " .. controller)
    end
    local alphaRequest = requestFor(frame, "alpha")
    local betaRequest = requestFor(frame, "beta")
    local alphaActor = assert(alphaRequest.actors[1])
    local betaActor = assert(betaRequest.actors[1])
    session:submit(SessionFixture.replyFor(alphaRequest, {
      SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
    }))
    session:submit(SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
    }))
    local turn = session:advance(1024)
    local snapshot = session:capture()
    session:dispose()
    return { events = turn.events, capture = snapshot }
  end
  local first = runTwin()
  local second = runTwin()
  local function mechanicsOf(events)
    local out = {}
    for _, event in ipairs(events) do
      out[#out + 1] = {
        sequence = event.sequence,
        kind = event.kind,
        cause = event.cause,
        payload = event.payload,
      }
    end
    return out
  end
  Assert.deepEqual(
    mechanicsOf(first.events),
    mechanicsOf(second.events),
    "one seed replays one mechanics transcript beside its facts"
  )
  Assert.deepEqual(first.capture, second.capture, "one seed replays one terminal state beside its facts")
end

return { tests = T }
