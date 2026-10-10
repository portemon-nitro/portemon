-- Event-time observations and pure decision options at the native
-- session owner: every emitted event carries its event-time checkpoint
-- beside its sequence/kind/cause/action/hit identity, observations never
-- leak unrevealed state, and the options projection answers the open
-- request without drawing, reserving, or sealing anything.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local NATIVE_FORMAT = "test:native-format"
local WILD_FORMAT = "wild-single"
local NATIVE_SEED = 0x1BADB002

---@return table loaded native session owner
local function executorOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

---@param formats string[] format identities carrying the native ruleset binding
---@return table frozen battle content for native observation tests
local function nativeContent(formats)
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-observation-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-observation-tests"
  )
  for _, key in ipairs(formats) do
    behaviors:registerFormat(key, { key = key }, "native-observation-tests")
  end
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table combatant seed striking with a single known move
local function tackleCombatant(id, seed)
  local entry = SessionFixture.combatant(id, seed)
  entry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return entry
end

---@param seeds table combatant seeds whose strikes and learnsets resolve
---@return table<string, table<string, unknown>> immutable move facts for the fixture strikes and learnsets
local function scenarioMoveFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
  for _, seed in ipairs(seeds or {}) do
    local learned = seed.mon --[[@as table<string, unknown>]]
    for _, entry in
      ipairs(learned.moves --[[@as table<integer, table<string, unknown>>]])
    do
      if type(entry) == "table" and type(entry.move) == "string" and facts[entry.move] == nil then
        facts[entry.move] = catalog:move(entry.move)
      end
    end
    local form = catalog:form(learned.species --[[@as string]], learned.form --[[@as integer]])
    for _, chance in ipairs(form.levelUpMoves) do
      if facts[chance.move] == nil then
        facts[chance.move] = catalog:move(chance.move)
      end
    end
  end
  return facts
end

---@param formRecord table<string, unknown> catalog form record carrying its semantic types
---@return string[] detached semantic types for the form
local function copyFormTypes(formRecord)
  local types = {} ---@type string[]
  for _, key in
    ipairs(formRecord.types --[[@as string[] ]])
  do
    types[#types + 1] = key --[[@as string]]
  end
  return types
end

---@param seeds table combatant seeds under fact resolution
---@return table<string, SpeciesFormFacts> static species facts for the fixture combatants
local function scenarioSpeciesFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local speciesRecord = catalog:species(species)
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    bucket[form] = {
      baseStats = catalog:form(species, form).baseStats,
      growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = copyFormTypes(catalog:form(species, form)),
      levelUpMoves = catalog:form(species, form).levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
      genderRatio = speciesRecord.genderRatio,
    }
  end
  return facts
end

---@param formatKey string format identity owning the encounter
---@param alpha table[] owning-side combatant seeds
---@param beta table[] opposing-side combatant seeds
---@param pack table? shared inventory seed for the owning side
---@return table detached native battle setup record
local function duelScenario(formatKey, alpha, beta, pack)
  local Executor = executorOwner()
  local seeds = {}
  for _, seed in ipairs(alpha) do
    seeds[#seeds + 1] = seed
  end
  for _, seed in ipairs(beta) do
    seeds[#seeds + 1] = seed
  end
  local alphaSpec = SessionFixture.participant(1, 1, "alpha", alpha)
  if pack ~= nil then
    alphaSpec.inventoryId = (pack --[[@as table<string, unknown>]]).id
  end
  local scenario = {
    ruleset = Executor.RULESET,
    format = formatKey,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      alphaSpec,
      SessionFixture.participant(2, 2, "beta", beta),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, alpha[1].id --[[@as integer]]),
      SessionFixture.position(2, 2, { 2 }, beta[1].id --[[@as integer]]),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(seeds),
    speciesFacts = scenarioSpeciesFacts(seeds),
  }
  if pack ~= nil then
    scenario.inventories = { pack }
  end
  return scenario
end

---@param formatKey string format identity owning the encounter
---@param alpha table[] owning-side combatant seeds
---@param beta table[] opposing-side combatant seeds
---@param pack table? shared inventory seed for the owning side
---@return table live native session waiting on its opening decisions
---@return table opening battle frame carrying the decision batch
local function openDuel(formatKey, alpha, beta, pack)
  local Executor = executorOwner()
  local session = Executor.new(duelScenario(formatKey, alpha, beta, pack), nativeContent({ formatKey }))
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the native duel opens on its decisions")
  return session, frame
end

---@param frame table waiting battle frame under inspection
---@param controller string decision producer owning the wanted request
---@return table the pending decision request for the controller
local function requestFor(frame, controller)
  for _, request in ipairs(frame.request.requests) do
    if request.controller == controller then
      return request
    end
  end
  error("the opening batch carries no request for " .. controller)
end

---@param value unknown
---@return string serialized shape without functions for privacy inspection
local function serializeShape(value)
  local parts = {}
  local function walk(node, depth)
    if depth > 6 then
      parts[#parts + 1] = "..."
      return
    end
    if type(node) ~= "table" then
      parts[#parts + 1] = tostring(node)
      return
    end
    parts[#parts + 1] = "{"
    local first = true
    for key, item in
      pairs(node --[[@as table<unknown, unknown>]])
    do
      if not first then
        parts[#parts + 1] = ","
      end
      first = false
      parts[#parts + 1] = tostring(key) .. "="
      walk(item, depth + 1)
    end
    parts[#parts + 1] = "}"
  end
  walk(value, 0)
  return table.concat(parts)
end

-- Checkpoints record event-time health: two strikes traded in one turn
-- carry distinct per-combatant health maps, while the checkpoint itself
-- stays a reduced semantic projection without moves, stock, randomness,
-- or continuation state.
function T.checkpoints_record_event_time_health()
  local alpha = tackleCombatant(1, 11)
  local beta = tackleCombatant(2, 23)
  local session, frame = openDuel(NATIVE_FORMAT, { alpha }, { beta })
  local alphaRequest = requestFor(frame, "alpha")
  local betaRequest = requestFor(frame, "beta")
  local alphaActor = assert(alphaRequest.actors[1], "the opening batch addresses its alpha lead")
  local betaActor = assert(betaRequest.actors[1], "the opening batch addresses its beta lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(alphaRequest, {
      SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
    })),
    "the alpha strike seals"
  )
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
    })),
    "the beta strike seals"
  )
  local turn = session:advance(1024)
  local struck = {}
  for _, event in ipairs(turn.events) do
    if event.kind == "struck" then
      struck[#struck + 1] = event
    end
  end
  Assert.isTrue(#struck >= 2, "the traded turn tells a strike on each side")
  local first = struck[1].observation --[[@as table<string, unknown>]]
  local second = struck[2].observation --[[@as table<string, unknown>]]
  Assert.isTrue(type(first) == "table", "struck events carry their event-time checkpoint")
  Assert.isTrue(type(second) == "table", "every struck event carries its own checkpoint")
  Assert.isTrue(type(first.hp) == "table", "checkpoints record observable health per combatant")
  Assert.isTrue(
    serializeShape(first.hp) ~= serializeShape(second.hp),
    "two hits in one turn carry different event-time health"
  )
  for _, checkpoint in ipairs({ first, second }) do
    Assert.isNil(checkpoint.moves, "checkpoints never carry move stores")
    Assert.isNil(checkpoint.inventories, "checkpoints never carry inventory stock")
    Assert.isNil(checkpoint.rng, "checkpoints never carry randomness")
    Assert.isNil(checkpoint.frames, "checkpoints never carry continuations")
    Assert.isNil(checkpoint.submitted, "checkpoints never carry sealed replies")
  end
  session:dispose()
end

-- Observations survive the interruption round trip: capturing and
-- restoring before a turn replays the identical events with identical
-- checkpoints.
function T.observations_survive_snapshot_round_trip()
  local alpha = tackleCombatant(1, 11)
  local beta = tackleCombatant(2, 23)
  local Executor = executorOwner()
  local content = nativeContent({ NATIVE_FORMAT })
  local session = Executor.new(duelScenario(NATIVE_FORMAT, { alpha }, { beta }), content)
  local frame = SessionFixture.driveUntilSettled(session)
  local captured = session:capture()
  local revived = Executor.restore(captured, content)
  local alphaRequest = requestFor(frame, "alpha")
  local betaRequest = requestFor(frame, "beta")
  local function answer(handle, request, target)
    local actor = assert(request.actors[1], "every decision addresses its combatant")
    local ok, err = handle:submit(SessionFixture.replyFor(request, {
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(target)),
    }))
    Assert.isTrue(ok, "both twins seal the identical strike: " .. tostring(err))
  end
  answer(session, alphaRequest, 2)
  answer(session, betaRequest, 1)
  local revivedFrame = SessionFixture.driveUntilSettled(revived)
  answer(revived, requestFor(revivedFrame, "alpha"), 2)
  answer(revived, requestFor(revivedFrame, "beta"), 1)
  local first = session:advance(1024)
  local second = revived:advance(1024)
  Assert.deepEqual(second.events, first.events, "restored sessions replay the same events with the same checkpoints")
  session:dispose()
  revived:dispose()
end

-- The options projection is pure: repeated reads agree, mutating a copy
-- changes no later read, and the captured mechanics state and generator
-- stay identical.
function T.decision_options_are_pure()
  local session, frame = openDuel(NATIVE_FORMAT, { tackleCombatant(1, 11) }, { tackleCombatant(2, 23) })
  local wanted = requestFor(frame, "alpha")
  Assert.isTrue(type(session.decisionOptions) == "function", "the session projects pure decision options")
  local before = session:capture()
  local first = session:decisionOptions(wanted.requestId)
  Assert.equal(first.requestId, wanted.requestId, "options answer the current request identity")
  Assert.equal(first.epoch, wanted.epoch, "options carry the current epoch")
  local second = session:decisionOptions(wanted.requestId)
  Assert.deepEqual(second, first, "repeated reads stay identical")
  first.actors[1].choices[1].enabled = "mutated"
  first.actors[1].choices[1].choice.actor.combatant = -9999
  local third = session:decisionOptions(wanted.requestId)
  Assert.deepEqual(third, second, "mutating a returned copy never reaches the kernel or a later read")
  Assert.deepEqual(session:capture(), before, "options reads leave mechanics state and randomness unchanged")
  session:dispose()
end

-- The action union projects selectable fragments: every move slot names
-- its zero-based slot with display facts, reserves and stocked items
-- project beside flight, and answering through a projected fragment
-- seals through the existing submission path.
function T.decision_options_cover_the_action_union()
  local alpha = tackleCombatant(1, 11)
  alpha.mon.condition.currentHp = 5
  local reserve = tackleCombatant(3, 31)
  local beta = tackleCombatant(2, 23)
  local pack = SessionFixture.inventory("alpha-bag", { 1 }, { POTION = 1, POKE_BALL = 2 })
  local itemFacts = {
    POTION = {
      partyUse = {
        kind = "medicine",
        restore = { kind = "fixed", amount = 20 },
        cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
        revive = "none",
        mood = 0,
      },
    },
  }
  local Executor = executorOwner()
  local scenario = duelScenario(WILD_FORMAT, { alpha, reserve }, { beta }, pack)
  scenario.itemFacts = itemFacts
  local session = Executor.new(scenario, nativeContent({ WILD_FORMAT }))
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the stocked duel opens on its decisions")
  local wanted = requestFor(frame, "alpha")
  local options = session:decisionOptions(wanted.requestId)
  Assert.equal(#options.actors, 1, "options address every requested actor once")
  local actorOptions = assert(options.actors[1], "the options address the lead")
  Assert.equal(actorOptions.kind, "action", "the opening options form the ordinary action union member")
  Assert.isTrue(#actorOptions.choices > 0, "the opening turn offers at least one selectable option")
  local seen = {}
  for _, option in ipairs(actorOptions.choices) do
    local entry = option --[[@as table<string, unknown>]]
    Assert.isTrue(type(entry.id) == "string" and entry.id ~= "", "selectable options carry a semantic identity")
    Assert.notNil(entry.display, "selectable options carry display facts")
    Assert.isTrue(type(entry.enabled) == "boolean", "selectable options name their availability")
    Assert.notNil(entry.choice, "selectable options carry a complete validated choice fragment")
    local choice = entry.choice --[[@as table<string, unknown>]]
    local choiceActor = choice.actor --[[@as table<string, unknown>]]
    Assert.equal(choiceActor.combatant, wanted.actors[1].combatant, "fragments address the requested entry")
  end
  local function choiceFor(role)
    for _, option in ipairs(actorOptions.choices) do
      local entry = option --[[@as table<string, unknown>]]
      if entry.role == role and entry.enabled == true then
        return entry.choice
      end
    end
    return nil
  end
  local move = choiceFor("move")
  Assert.notNil(move, "a usable move slot projects a selectable fragment")
  local moveChoice = move --[[@as table<string, unknown>]]
  local movePayload = moveChoice.payload --[[@as table<string, unknown>]]
  Assert.isTrue(type(movePayload.moveSlot) == "number", "move options name their zero-based slot")
  Assert.notNil(choiceFor("switch"), "an eligible reserve projects a selectable fragment")
  Assert.notNil(choiceFor("item"), "a stocked serving projects a selectable fragment")
  Assert.notNil(choiceFor("run"), "wild flight projects a selectable fragment")
  Assert.isTrue(
    session:submit({
      requestId = wanted.requestId,
      epoch = wanted.epoch,
      controller = wanted.controller,
      choices = {
        moveChoice,
      },
    }),
    "answering through the projected move fragment seals"
  )
  session:dispose()
end

-- Spent move slots disable with a reason while genuine all-no-PP
-- struggle stays an explicit kernel-owned option.
function T.decision_options_disable_spent_moves_and_project_struggle()
  local alpha = tackleCombatant(1, 11)
  alpha.mon.moves = { { move = "TACKLE", pp = 0, ppUps = 0 } }
  local beta = tackleCombatant(2, 23)
  local session, frame = openDuel(NATIVE_FORMAT, { alpha }, { beta })
  local wanted = requestFor(frame, "alpha")
  local options = session:decisionOptions(wanted.requestId)
  local actorOptions = assert(options.actors[1], "the options address the lead")
  local slotOption = nil
  local struggle = nil
  for _, option in ipairs(actorOptions.choices) do
    local entry = option --[[@as table<string, unknown>]]
    if entry.id == "move:0" then
      slotOption = entry
    end
    if entry.id == "move:struggle" then
      struggle = entry
    end
  end
  slotOption = assert(slotOption, "the spent slot still projects its option")
  Assert.isFalse(slotOption.enabled --[[@as boolean]], "the spent slot disables")
  Assert.isTrue(type(slotOption.reason) == "string", "the spent slot names its reason")
  struggle = assert(struggle, "genuine all-no-PP struggle projects its kernel-owned option")
  Assert.isTrue(struggle.enabled --[[@as boolean]], "struggle stays selectable")
  local fragment = struggle.choice --[[@as table<string, unknown>]]
  local ok, err = session:submit({
    requestId = wanted.requestId,
    epoch = wanted.epoch,
    controller = wanted.controller,
    choices = { fragment },
  })
  Assert.isTrue(ok, "the projected struggle seals: " .. tostring(err))
  session:dispose()
end

-- Trainer encounters refuse flight and capture through the projection:
-- the run and ball options disable with reasons instead of vanishing,
-- so the interface never invents an illegal selection.
function T.decision_options_refuse_trainer_flight_and_capture()
  local alpha = tackleCombatant(1, 11)
  local beta = tackleCombatant(2, 23)
  local pack = SessionFixture.inventory("alpha-bag", { 1 }, { POKE_BALL = 2 })
  local session, frame = openDuel(NATIVE_FORMAT, { alpha }, { beta }, pack)
  local wanted = requestFor(frame, "alpha")
  local options = session:decisionOptions(wanted.requestId)
  local actorOptions = assert(options.actors[1], "the options address the lead")
  local run = nil
  local ball = nil
  for _, option in ipairs(actorOptions.choices) do
    local entry = option --[[@as table<string, unknown>]]
    if entry.role == "run" then
      run = entry
    end
    local choice = entry.choice --[[@as table<string, unknown>]]
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "item" and payload.item == "POKE_BALL" then
      ball = entry
    end
  end
  run = assert(run, "flight still projects its option in trainer battles")
  Assert.isFalse(run.enabled --[[@as boolean]], "trainer flight disables")
  Assert.isTrue(type(run.reason) == "string", "trainer flight names its reason")
  ball = assert(ball, "the stocked ball still projects its option in trainer battles")
  Assert.isFalse(ball.enabled --[[@as boolean]], "trainer capture disables")
  Assert.isTrue(type(ball.reason) == "string", "trainer capture names its reason")
  session:dispose()
end

-- Answered requests go stale: options for a consumed request identity
-- fail instead of projecting against the new batch.
function T.decision_options_reject_stale_requests()
  local session, frame = openDuel(NATIVE_FORMAT, { tackleCombatant(1, 11) }, { tackleCombatant(2, 23) })
  local wanted = requestFor(frame, "alpha")
  local firstId = wanted.requestId --[[@as integer]]
  Assert.notNil(session:decisionOptions(firstId), "the open request projects")
  local betaRequest = requestFor(frame, "beta")
  local alphaActor = assert(wanted.actors[1], "the opening batch addresses its alpha lead")
  local betaActor = assert(betaRequest.actors[1], "the opening batch addresses its beta lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(wanted, {
      SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
    })),
    "the alpha strike seals"
  )
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
    })),
    "the beta strike seals"
  )
  session:advance(1024)
  local stale, staleErr = session:decisionOptions(firstId)
  Assert.isNil(stale, "the consumed request projects nothing")
  Assert.notNil(staleErr, "the consumed request names its staleness")
  session:dispose()
end

---@param formatKey string format identity owning the encounter
---@param alpha table[] owning-side combatant seeds
---@param beta table[] opposing-side combatant seeds
---@return table detached native battle setup record with two slots per side
local function doubleScenario(formatKey, alpha, beta)
  local Executor = executorOwner()
  local seeds = {}
  for _, seed in ipairs(alpha) do
    seeds[#seeds + 1] = seed
  end
  for _, seed in ipairs(beta) do
    seeds[#seeds + 1] = seed
  end
  return {
    ruleset = Executor.RULESET,
    format = formatKey,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", alpha),
      SessionFixture.participant(2, 2, "beta", beta),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, alpha[1].id --[[@as integer]]),
      SessionFixture.position(2, 1, { 1 }, alpha[2].id --[[@as integer]]),
      SessionFixture.position(3, 2, { 2 }, beta[1].id --[[@as integer]]),
      SessionFixture.position(4, 2, { 2 }, beta[2].id --[[@as integer]]),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(seeds),
    speciesFacts = scenarioSpeciesFacts(seeds),
  }
end

-- With two live foes every usable move projects one validated fragment
-- per admitted foe position in deterministic order: the default
-- fragment stays the first foe, variants never mutate the session, and
-- answering each entry through a different variant seals.
function T.decision_options_project_admitted_foe_positions_per_actor()
  local first = tackleCombatant(1, 11)
  local second = tackleCombatant(3, 31)
  second.mon.moves = { { move = "GROWL", pp = 40, ppUps = 0 } }
  local Executor = executorOwner()
  local session = Executor.new(
    doubleScenario(NATIVE_FORMAT, { first, second }, { tackleCombatant(2, 23), tackleCombatant(4, 41) }),
    nativeContent({
      NATIVE_FORMAT,
    })
  )
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the doubled session opens on its decisions")
  local wanted = requestFor(frame, "alpha")
  Assert.equal(#wanted.actors, 2, "the doubled request addresses both entries")
  local before = session:capture()
  local options = session:decisionOptions(wanted.requestId)
  Assert.equal(#options.actors, 2, "the projection addresses both entries")
  local replies = {}
  for index, entry in ipairs(options.actors) do
    local actorOptions = assert(entry, "the projection addresses its entry")
    local addressed = assert(wanted.actors[index], "the request addresses its entry")
    local moveOption = nil
    for _, option in ipairs(actorOptions.choices) do
      if option.role == "move" and option.enabled == true then
        moveOption = option
        break
      end
    end
    moveOption = assert(moveOption, "the entry projects its usable move")
    local variants = assert(moveOption.targets, "the doubled move projects its foe positions")
    Assert.equal(#variants, 2, "both live foes stay admitted")
    Assert.equal(variants[1].id, "target:0", "variant identities follow foe order")
    Assert.equal(variants[2].id, "target:1", "variant identities follow foe order")
    Assert.isTrue(variants[1].position ~= variants[2].position, "variants name distinct positions")
    Assert.isTrue(variants[1].enabled == true, "the first foe stays selectable")
    Assert.isTrue(variants[2].enabled == true, "the second foe stays selectable")
    for _, variant in ipairs(variants) do
      local fragment = assert(variant.choice, "variants carry complete fragments")
      local fragmentActor = fragment.actor --[[@as table<string, unknown>]]
      Assert.equal(fragmentActor.combatant, addressed.combatant, "variants address their own entry")
      Assert.equal(fragment.payload.target.kind, "position", "variants strike positions")
      Assert.equal(fragment.payload.target.position, variant.position, "variants bind their own position")
    end
    Assert.deepEqual(
      moveOption.choice,
      variants[1].choice,
      "the default fragment keeps the first foe for current consumers"
    )
    replies[#replies + 1] = variants[(index % 2) + 1].choice
  end
  Assert.deepEqual(session:capture(), before, "projecting variants leaves mechanics state unchanged")
  local betaRequest = requestFor(frame, "beta")
  local betaActor = assert(betaRequest.actors[1], "the beta request addresses its lead")
  local betaSecond = assert(betaRequest.actors[2], "the beta request addresses its second")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(wanted, replies)),
    "answering each entry through a different variant seals"
  )
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
      SessionFixture.attackChoice(betaSecond, 0, SessionFixture.positionTarget(1)),
    })),
    "the beta pair seals"
  )
  session:dispose()
end

return { tests = T }
