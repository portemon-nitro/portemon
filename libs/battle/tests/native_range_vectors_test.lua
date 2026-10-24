-- Native move-scope vectors: choice projection and execution follow the
-- source move range instead of the first foe. Selected-foe moves offer
-- the live foe slots, user/ally moves name their own side without a foe
-- picker, spread moves strike every recipient from one action and one
-- power-point spend, and side/field/random scopes settle where the source
-- puts them without spending randomness during read-only projection.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local DOUBLE_FORMAT = "double"
local SINGLE_FORMAT = "single"
local NATIVE_SEED = 0x1BADB002

---@return table loaded native session owner
local function executorOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

---@return table frozen battle content carrying the native ruleset binding
local function rangeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-range-vector-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-range-vector-tests"
  )
  behaviors:registerFormat(DOUBLE_FORMAT, { key = DOUBLE_FORMAT }, "native-range-vector-tests")
  behaviors:registerFormat(SINGLE_FORMAT, { key = SINGLE_FORMAT }, "native-range-vector-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table<string, unknown> detached copy of the catalog strike facts
local function tackleBase()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local facts = CatalogFixture.makeCatalog():move("TACKLE")
  local copy = {}
  for key, value in pairs(facts) do
    copy[key] = value
  end
  return copy
end

---@param range integer native source range carried by the probe move
---@return table<string, unknown> damaging probe facts fixed to always land
local function probeFacts(range)
  local facts = tackleBase()
  facts.range = range
  facts.accuracy = 100
  return facts
end

---@param name string catalog move identity under copying
---@param range integer native source range carried by the copied facts
---@return table<string, unknown> executable catalog facts pinned to the range
local function catalogCopy(name, range)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local facts = CatalogFixture.makeCatalog():move(name)
  local copy = {}
  for key, value in pairs(facts) do
    copy[key] = value
  end
  copy.range = range
  copy.accuracy = 100
  return copy
end

---@param seeds table<integer, table<string, unknown>>? combatant seeds whose strikes and learnsets resolve
---@param extra table<string, table<string, unknown>>? synthetic move facts pinned to native ranges
---@return table<string, table<string, unknown>> immutable move facts for the vector sessions
local function scenarioMoveFacts(seeds, extra)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {
    TACKLE = catalog:move("TACKLE"),
    SPLASH = { power = 0, accuracy = 100, category = "other", moveType = "normal", priority = 0 },
    REFLECT = { power = 0, accuracy = 100, category = "other", moveType = "psychic", priority = 0, range = 32 },
    RAIN_DANCE = { power = 0, accuracy = 100, category = "other", moveType = "water", priority = 0, range = 64 },
    CURSE = {
      nativeId = 174,
      effect = 109,
      power = 0,
      moveType = "mystery",
      category = "status",
      accuracy = 0,
      range = 0,
    },
  }
  for name, entry in pairs(extra or {}) do
    facts[name] = entry
  end
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

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the vector combatants
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
    local formRecord = catalog:form(species, form)
    local types = {}
    for _, key in ipairs(formRecord.types) do
      types[#types + 1] = key
    end
    bucket[form] = {
      baseStats = formRecord.baseStats,
      growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = types,
      levelUpMoves = formRecord.levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
    }
  end
  return facts
end

---@param id integer nonreused positive combatant identity
---@param species string catalog species for the vector mon
---@param level integer battle level for the vector mon
---@param seed integer fixed generator state for the underlying mon
---@return table combatant seed carrying the requested record
local function monSeed(id, species, level, seed)
  return { id = id, mon = SessionFixture.makeMon(seed, { species = species, level = level }) }
end

---@param seed table combatant seed under move assignment
---@param moves table<integer, table<string, unknown>> persistent move entries in slot order
---@return table the same seed striking with the assigned moveset
local function withMoves(seed, moves)
  seed.mon.moves = moves
  return seed
end

---@param move string move identity owning the slot
---@param pp integer power points carried by the slot
---@return table<string, unknown> persistent move entry for the slot
local function moveSlot(move, pp)
  return { move = move, pp = pp, ppUps = 0 }
end

---@param alpha table[] owning-side combatant seeds in battle order
---@param beta table[] opposing-side combatant seeds in battle order
---@param moveFacts table<string, table<string, unknown>> immutable move facts by move identity
---@param speciesFacts table<string, table<integer, table<string, unknown>>> static species facts
---@return table detached native doubles setup record over the vector content
local function doublesScenario(alpha, beta, moveFacts, speciesFacts)
  local Executor = executorOwner()
  return {
    ruleset = Executor.RULESET,
    format = DOUBLE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", alpha),
      SessionFixture.participant(2, 2, "beta", beta),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, alpha[1].id),
      SessionFixture.position(2, 2, { 2 }, beta[1].id),
      SessionFixture.position(3, 1, { 1 }, alpha[2].id),
      SessionFixture.position(4, 2, { 2 }, beta[2].id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = moveFacts,
    speciesFacts = speciesFacts,
  }
end

---@param alpha table owning-side combatant seed
---@param beta table opposing-side combatant seed
---@param moveFacts table<string, table<string, unknown>> immutable move facts by move identity
---@param speciesFacts table<string, table<integer, table<string, unknown>>> static species facts
---@return table detached native singles setup record over the vector content
local function singlesScenario(alpha, beta, moveFacts, speciesFacts)
  local Executor = executorOwner()
  return {
    ruleset = Executor.RULESET,
    format = SINGLE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alpha }),
      SessionFixture.participant(2, 2, "beta", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, alpha.id),
      SessionFixture.position(2, 2, { 2 }, beta.id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = moveFacts,
    speciesFacts = speciesFacts,
  }
end

---@param scenario table detached native setup record under test
---@return table live headless session waiting on its opening decisions
---@return table opening battle frame carrying the decision batch
local function openWaiting(scenario)
  local contracts = SessionFixture.sessionContracts()
  local session = contracts.Battle.newSession(scenario, rangeContent())
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the native session opens on its decisions")
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

---@param session table live headless session under test
---@param request table pending decision request under projection
---@return table detached options answering the request
local function optionsFor(session, request)
  local options = session:decisionOptions(request.requestId)
  Assert.notNil(options, "the open request projects its options")
  return options --[[@as table]]
end

---@param options table detached options under inspection
---@param combatant integer combatant identity owning the wanted entry
---@return table the actor entry addressed to the combatant
local function actorEntry(options, combatant)
  for _, entry in ipairs(options.actors) do
    if entry.combatant == combatant then
      return entry
    end
  end
  error("the options address no entry for combatant " .. tostring(combatant))
end

---@param entry table actor entry under inspection
---@param slot integer zero-based move slot under test
---@return table the move option projecting the slot
local function moveOption(entry, slot)
  for _, option in ipairs(entry.choices) do
    if option.id == "move:" .. tostring(slot) then
      return option
    end
  end
  error("the options carry no move slot " .. tostring(slot))
end

---@param option table move option under inspection
---@return integer[] positions named by its per-position variants in order
local function variantPositions(option)
  local out = {}
  if option.targets == nil then
    return out
  end
  for _, variant in ipairs(option.targets) do
    out[#out + 1] = variant.position
  end
  return out
end

---@param capture table interruption capture under inspection
---@param side integer side identity owning the wanted slots
---@return integer[] occupied position identities on the side in order
local function livePositionsBySide(capture, side)
  local out = {}
  for id, position in pairs(capture.positions) do
    if position.side == side and position.occupant ~= nil then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

---@param choice table projected choice fragment under copying
---@return table detached copy safe to mutate into a forged reply
local function copyChoice(choice)
  local copy = { actor = {}, kind = choice.kind, payload = {} } --[[@as table<string, unknown>]]
  local actor = copy.actor --[[@as table<string, unknown>]]
  for key, value in
    pairs(choice.actor --[[@as table<string, unknown>]])
  do
    actor[key] = value
  end
  local payload = copy.payload --[[@as table<string, unknown>]]
  for key, value in
    pairs(choice.payload --[[@as table<string, unknown>]])
  do
    if key == "target" and type(value) == "table" then
      local target = {}
      for targetKey, targetValue in
        pairs(value --[[@as table<string, unknown>]])
      do
        target[targetKey] = targetValue
      end
      payload[key] = target
    else
      payload[key] = value
    end
  end
  return copy
end

---@param request table pending decision request under addressing
---@param combatant integer combatant identity owning the wanted actor
---@return table the actor address answering for the combatant
local function requestActor(request, combatant)
  for _, actor in ipairs(request.actors) do
    if actor.combatant == combatant then
      return actor
    end
  end
  error("the request addresses no actor for combatant " .. tostring(combatant))
end

---@param session table live headless session under test
---@param frame table waiting battle frame carrying the batch
---@return table<string, table[]> one projected slot-zero strike per actor keyed by controller
local function projectedSlotZero(session, frame)
  local answers = {}
  for _, request in ipairs(frame.request.requests) do
    local options = optionsFor(session, request)
    local byCombatant = {}
    for _, entry in ipairs(options.actors) do
      byCombatant[entry.combatant] = entry
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      local entry = byCombatant[actor.combatant]
      Assert.notNil(entry, "every requested actor carries its projected entry")
      choices[#choices + 1] = copyChoice(moveOption(entry, 0).choice)
    end
    answers[request.controller] = choices
  end
  return answers
end

---@param session table live headless session under test
---@param answers table<string, table[]> scripted choices keyed by controller
---@return table waiting or ended frame after the turn settles
local function playAnswers(session, answers)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "each vector turn opens its decision batch")
  for _, request in ipairs(frame.request.requests) do
    local choices = answers[request.controller]
    Assert.notNil(choices, "every open controller carries its vector choices")
    local ok, err = session:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "vector replies are accepted: " .. tostring(err))
  end
  for _ = 1, 64 do
    frame = session:advance()
    Assert.notNil(frame, "advance returns a battle frame")
    if frame.status ~= "running" then
      return frame
    end
  end
  error("the vector turn did not settle within its operation bound")
end

---@param capture table interruption capture under inspection
---@param key string battle-local definition identity under test
---@param side integer side identity owning the wanted scope
---@return boolean true while the side carries a live instance of the key
local function hasSideEffect(capture, key, side)
  for _, record in ipairs(capture.effects or {}) do
    if record.key == key and type(record.scope) == "table" and record.scope.side == side then
      return true
    end
  end
  return false
end

---@param capture table interruption capture under inspection
---@param key string battle-local definition identity under test
---@return boolean true while the field carries a live instance of the key
local function hasFieldEffect(capture, key)
  for _, record in ipairs(capture.effects or {}) do
    if record.key == key and type(record.scope) == "table" and record.scope.kind == "field" then
      return true
    end
  end
  return false
end

-- The doubles projection names each move scope from its source range:
-- the selected-foe move offers both live foe slots while the user, ally,
-- and spread moves carry direct choices that never collapse onto the
-- single-foe fragment, and repeated reads stay byte-equivalent without
-- touching mechanics state or randomness.
function T.doubles_projection_names_each_move_scope()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA101), {
    moveSlot("PROBE_SINGLE", 35),
    moveSlot("PROBE_SELF", 30),
    moveSlot("PROBE_ALLY", 30),
    moveSlot("PROBE_SPREAD", 30),
  })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA202), { moveSlot("TACKLE", 35) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB101), { moveSlot("SPLASH", 40) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB202), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local extra = {
    PROBE_SINGLE = probeFacts(0),
    PROBE_SELF = probeFacts(16),
    PROBE_ALLY = probeFacts(256),
    PROBE_SPREAD = probeFacts(4),
  }
  local scenario = doublesScenario({ a1, a2 }, { b1, b2 }, scenarioMoveFacts(seeds, extra), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local held = session:capture()
  Assert.deepEqual(livePositionsBySide(held, 2), { 2, 4 }, "the foe side holds both far slots")
  local request = requestFor(frame, "alpha")
  local first = optionsFor(session, request)
  local entry = actorEntry(first, 1)

  local single = moveOption(entry, 0)
  Assert.deepEqual(variantPositions(single), { 2, 4 }, "the selected-foe move offers both live foe slots")

  local selfMove = moveOption(entry, 1)
  Assert.isTrue(selfMove.targets == nil, "the user move offers no foe picker")
  local selfTarget = (selfMove.choice.payload or {}).target or {}
  Assert.isTrue(selfTarget.position ~= 2 and selfTarget.position ~= 4, "the user move never names a foe slot")

  local ally = moveOption(entry, 2)
  Assert.isTrue(ally.targets == nil, "the ally move offers no foe picker")
  local allyTarget = (ally.choice.payload or {}).target or {}
  Assert.equal(allyTarget.position, 3, "the ally move names the live partner slot")

  local spread = moveOption(entry, 3)
  Assert.isTrue(spread.targets == nil, "the spread move is one direct choice without a picker")
  local spreadTarget = (spread.choice.payload or {}).target or {}
  local singleTarget = (single.choice.payload or {}).target or {}
  Assert.isTrue(
    spreadTarget.kind ~= singleTarget.kind or spreadTarget.position ~= singleTarget.position,
    "the spread choice never collapses onto the single-foe fragment"
  )

  local second = optionsFor(session, request)
  Assert.deepEqual(second, first, "repeated reads stay identical")
  Assert.deepEqual(session:capture(), held, "projection leaves mechanics state and randomness untouched")
  session:dispose()
end

-- Follow Me redirects a selected single-target foe strike onto its user
-- for the rest of the turn, while other attacks can still select either
-- foe slot on a later turn.
function T.follow_me_redirects_selected_foe_strikes()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA301), { moveSlot("FOLLOW_ME", 20) })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA302), { moveSlot("SPLASH", 40) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB301), { moveSlot("TACKLE", 35) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB302), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local followMe = tackleBase()
  followMe.nativeId = 266
  followMe.effect = 172
  followMe.power = 0
  followMe.priority = 2
  followMe.category = "other"
  followMe.range = 0
  local scenario = doublesScenario(
    { a1, a2 },
    { b1, b2 },
    scenarioMoveFacts(seeds, { FOLLOW_ME = followMe }),
    scenarioSpeciesFacts(seeds)
  )
  local session, frame = openWaiting(scenario)
  local answers = projectedSlotZero(session, frame)
  local betaChoices = answers.beta
  Assert.notNil(betaChoices, "the beta controller has both projected strikes")
  betaChoices[1].payload.target = { kind = "position", position = 3 }
  local before = session:capture()
  local settled = playAnswers(session, answers)
  local after = session:capture()
  Assert.isTrue(settled.status == "waiting" or settled.status == "ended", "the redirected turn settles")
  Assert.equal(after.combatants[1].hp, before.combatants[1].hp - 3, "Follow Me's user takes the selected foe strike")
  Assert.equal(after.combatants[3].hp, before.combatants[3].hp, "the selected ally remains unharmed")
  session:dispose()
end

-- Forged choices are refused before any mutation: a strike retargeted
-- onto the partner, a side or field fragment for a foe-scoped move, a
-- spent-slot strike while another slot stays usable, and a stale actor
-- token are each rejected without spending power points or randomness,
-- while the legitimately projected fragments still answer afterwards.
function T.forged_choices_are_refused_without_spending_state()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA111), {
    moveSlot("PROBE_SINGLE", 35),
    moveSlot("SPENT_PROBE", 0),
  })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA212), { moveSlot("TACKLE", 35) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB111), { moveSlot("SPLASH", 40) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB212), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local extra = {
    PROBE_SINGLE = probeFacts(0),
    SPENT_PROBE = probeFacts(0),
  }
  local scenario = doublesScenario({ a1, a2 }, { b1, b2 }, scenarioMoveFacts(seeds, extra), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local request = requestFor(frame, "alpha")
  local entry = actorEntry(optionsFor(session, request), 1)
  local partnerEntry = actorEntry(optionsFor(session, request), 3)
  local honestFirst = copyChoice(moveOption(entry, 0).choice)
  local honestPartner = copyChoice(moveOption(partnerEntry, 0).choice)
  local rngBefore = session:capture().rng.calls

  local function refusalsLeaveStateUntouched()
    local held = session:capture()
    Assert.equal(held.rng.calls, rngBefore, "refused choices draw no randomness")
    Assert.equal(held.combatants[1].mon.moves[1].pp, 35, "refused choices spend no power points")
  end

  local wrongSide = copyChoice(honestFirst)
  wrongSide.payload.target = { kind = "position", position = 3 }
  local stored, _ = session:submit(SessionFixture.replyFor(request, { wrongSide, copyChoice(honestPartner) }))
  Assert.isTrue(not stored, "a strike retargeted onto the partner is refused")
  refusalsLeaveStateUntouched()

  local wrongScope = copyChoice(honestFirst)
  wrongScope.payload.target = { kind = "side", side = 2 }
  local storedSide, _ = session:submit(SessionFixture.replyFor(request, { wrongScope, copyChoice(honestPartner) }))
  Assert.isTrue(not storedSide, "a side fragment for a foe-scoped move is refused")
  refusalsLeaveStateUntouched()

  local wrongField = copyChoice(honestFirst)
  wrongField.payload.target = { kind = "field" }
  local storedField, _ = session:submit(SessionFixture.replyFor(request, { wrongField, copyChoice(honestPartner) }))
  Assert.isTrue(not storedField, "a field fragment for a foe-scoped move is refused")
  refusalsLeaveStateUntouched()

  local spentSlot = SessionFixture.attackChoice(requestActor(request, 1), 1, SessionFixture.positionTarget(2))
  local storedSpent, _ = session:submit(SessionFixture.replyFor(request, { spentSlot, copyChoice(honestPartner) }))
  Assert.isTrue(not storedSpent, "a spent-slot strike is refused while another slot stays usable")
  refusalsLeaveStateUntouched()

  local staleToken = copyChoice(honestFirst)
  staleToken.actor.activation = 9999
  local storedStale, _ = session:submit(SessionFixture.replyFor(request, { staleToken, copyChoice(honestPartner) }))
  Assert.isTrue(not storedStale, "a stale actor token is refused")
  refusalsLeaveStateUntouched()

  local reopened = SessionFixture.driveUntilSettled(session)
  Assert.equal(reopened.status, "waiting", "refusals leave the battle waiting on its batch")
  local fresh = requestFor(reopened, "alpha")
  local freshOptions = optionsFor(session, fresh)
  local freshFirst = copyChoice(moveOption(actorEntry(freshOptions, 1), 0).choice)
  local freshPartner = copyChoice(moveOption(actorEntry(freshOptions, 3), 0).choice)
  local accepted, acceptErr = session:submit(SessionFixture.replyFor(fresh, { freshFirst, freshPartner }))
  Assert.isTrue(accepted, "projected fragments still answer after refusals: " .. tostring(acceptErr))
  session:dispose()
end

-- A spread strike finishes every recipient from one action: the wounded
-- foe falls yet the standing foe still takes its share computed from its
-- own facts, one power point is spent, and an identical seed replays the
-- identical recipient state.
function T.spread_strikes_finish_every_recipient_after_a_faint()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA121), { moveSlot("TACKLE", 35) })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA222), { moveSlot("SPLASH", 40) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB121), { moveSlot("SPLASH", 40) })
  b1.mon.condition.currentHp = 1
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB222), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local extra = { TACKLE = probeFacts(4) }
  local species = scenarioSpeciesFacts(seeds)

  local function openSpread()
    local scenario = doublesScenario({ a1, a2 }, { b1, b2 }, scenarioMoveFacts(seeds, extra), species)
    local opened, opening = openWaiting(scenario)
    return opened, opening
  end

  local session, frame = openSpread()
  local before = session:capture()
  local foeFull = before.combatants[4].hp
  Assert.isTrue(foeFull > 1, "the standing foe opens above one health")
  local settled = playAnswers(session, projectedSlotZero(session, frame))
  Assert.equal(settled.status, "waiting", "the spread turn leaves the battle waiting")
  local after = session:capture()
  Assert.equal(after.combatants[2].hp, 0, "the spread strike fells the wounded foe")
  Assert.isTrue(after.combatants[4].hp < foeFull, "the standing foe still takes its share after the faint")
  Assert.equal(after.combatants[1].mon.moves[1].pp, 34, "the spread action spends one power point")
  session:dispose()

  local replayed, replayFrame = openSpread()
  playAnswers(replayed, projectedSlotZero(replayed, replayFrame))
  Assert.deepEqual(replayed:capture(), after, "an identical seed replays the identical recipient state")
  replayed:dispose()
end

-- User and ally strikes land on their own side: neither foe loses health
-- while the striker takes its own share, so self and partner scopes never
-- substitute an opposing foe.
function T.self_and_ally_strikes_land_on_their_own_side()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA131), { moveSlot("TACKLE", 35) })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA232), { moveSlot("QUICK_ATTACK", 30) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB131), { moveSlot("SPLASH", 40) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB232), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local extra = {
    TACKLE = catalogCopy("TACKLE", 16),
    QUICK_ATTACK = catalogCopy("QUICK_ATTACK", 256),
  }
  local scenario = doublesScenario({ a1, a2 }, { b1, b2 }, scenarioMoveFacts(seeds, extra), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local before = session:capture()
  local settled = playAnswers(session, projectedSlotZero(session, frame))
  Assert.equal(settled.status, "waiting", "the self and ally turn leaves the battle waiting")
  local after = session:capture()
  Assert.equal(after.combatants[2].hp, before.combatants[2].hp, "the first foe takes no self-scoped damage")
  Assert.equal(after.combatants[4].hp, before.combatants[4].hp, "the second foe takes no ally-scoped damage")
  Assert.isTrue(after.combatants[1].hp < before.combatants[1].hp, "the striker takes its own user-scoped share")
  session:dispose()
end

-- A side screen settles on the user side from its side fragment: the
-- projection offers no foe picker, the side choice submits, and the turn
-- raises exactly one screen on the striker side for one power point.
function T.side_screens_settle_on_the_user_side()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA141), { moveSlot("REFLECT", 30) })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA242), { moveSlot("SPLASH", 40) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB141), { moveSlot("SPLASH", 40) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB242), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local scenario = doublesScenario({ a1, a2 }, { b1, b2 }, scenarioMoveFacts(seeds, nil), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local request = requestFor(frame, "alpha")
  local screen = moveOption(actorEntry(optionsFor(session, request), 1), 0)
  Assert.isTrue(screen.targets == nil, "the side move offers no foe picker")

  local answers = projectedSlotZero(session, frame)
  answers.alpha[1] = SessionFixture.attackChoice(requestActor(request, 1), 0, { kind = "side", side = 1 })
  local settled = playAnswers(session, answers)
  Assert.equal(settled.status, "waiting", "the screen turn leaves the battle waiting")
  local after = session:capture()
  Assert.isTrue(hasSideEffect(after, "reflect", 1), "the screen settles on the user side")
  Assert.isTrue(not hasSideEffect(after, "reflect", 2), "the screen never leaks onto the foe side")
  Assert.equal(after.combatants[1].mon.moves[1].pp, 29, "the side action spends one power point")
  session:dispose()
end

-- A field weather settles across the field from its field fragment: the
-- projection offers no foe picker and names no single foe, and the turn
-- raises the weather for one power point without dropping either foe.
function T.field_weather_settles_across_the_field()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA151), { moveSlot("RAIN_DANCE", 30) })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA252), { moveSlot("SPLASH", 40) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB151), { moveSlot("SPLASH", 40) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB252), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local scenario = doublesScenario({ a1, a2 }, { b1, b2 }, scenarioMoveFacts(seeds, nil), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local request = requestFor(frame, "alpha")
  local weather = moveOption(actorEntry(optionsFor(session, request), 1), 0)
  Assert.isTrue(weather.targets == nil, "the field move offers no foe picker")
  local weatherTarget = (weather.choice.payload or {}).target or {}
  Assert.isTrue(
    weatherTarget.position ~= 2 and weatherTarget.position ~= 4,
    "the field choice never collapses onto a foe slot"
  )

  local before = session:capture()
  local settled = playAnswers(session, projectedSlotZero(session, frame))
  Assert.equal(settled.status, "waiting", "the weather turn leaves the battle waiting")
  local after = session:capture()
  Assert.isTrue(hasFieldEffect(after, "raindance"), "the weather settles across the field")
  Assert.equal(after.combatants[2].hp, before.combatants[2].hp, "the weather drops no foe")
  Assert.equal(after.combatants[4].hp, before.combatants[4].hp, "the weather drops no second foe")
  Assert.equal(after.combatants[1].mon.moves[1].pp, 29, "the field action spends one power point")
  session:dispose()
end

-- A random-foe strike hits exactly one foe: the projection is a direct
-- choice that draws no randomness, polling reads never change the
-- outcome, and the turn spends one power point on one recipient.
function T.random_strikes_hit_one_foe_without_reads_spending_randomness()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA161), { moveSlot("TACKLE", 35) })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA262), { moveSlot("SPLASH", 40) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB161), { moveSlot("SPLASH", 40) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB262), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local extra = { TACKLE = catalogCopy("TACKLE", 2) }

  local function openRandom()
    local scenario = doublesScenario(
      { a1, a2 },
      { b1, b2 },
      scenarioMoveFacts(seeds, extra),
      scenarioSpeciesFacts(seeds)
    )
    return openWaiting(scenario)
  end

  local session, frame = openRandom()
  local request = requestFor(frame, "alpha")
  local held = session:capture()
  local strike = moveOption(actorEntry(optionsFor(session, request), 1), 0)
  Assert.isTrue(strike.targets == nil, "the random move offers no foe picker")
  Assert.deepEqual(session:capture(), held, "projecting the random move draws no randomness")

  local before = session:capture()
  local settled = playAnswers(session, projectedSlotZero(session, frame))
  Assert.equal(settled.status, "waiting", "the random turn leaves the battle waiting")
  local after = session:capture()
  local firstHit = after.combatants[2].hp < before.combatants[2].hp
  local secondHit = after.combatants[4].hp < before.combatants[4].hp
  Assert.isTrue(firstHit ~= secondHit, "the random strike lands on exactly one foe")
  Assert.equal(after.combatants[1].mon.moves[1].pp, 34, "the random action spends one power point")
  session:dispose()

  local polled, polledFrame = openRandom()
  local polledRequest = requestFor(polledFrame, "alpha")
  optionsFor(polled, polledRequest)
  optionsFor(polled, polledRequest)
  optionsFor(polled, polledRequest)
  playAnswers(polled, projectedSlotZero(polled, polledFrame))
  Assert.deepEqual(polled:capture(), after, "polling reads never change the sampled outcome")
  polled:dispose()
end

-- The curse answers its holder without ghost typing and the foe slots
-- with it: the ordinary user projects no picker and names its own slot
-- while the haunted user keeps the foe picker, so the dynamic follows
-- the user type rather than the static range alone.
function T.curse_answers_the_holder_without_ghost_typing()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local hauntedTypes = catalog:form("SHEDINJA", 0).types
  local haunted = false
  for _, key in ipairs(hauntedTypes) do
    if key == "ghost" then
      haunted = true
    end
  end
  Assert.isTrue(haunted, "the haunted vector user carries ghost typing")
  local plainTypes = catalog:form("CHIKORITA", 0).types
  for _, key in ipairs(plainTypes) do
    Assert.isTrue(key ~= "ghost", "the ordinary vector user carries no ghost typing")
  end

  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA171), { moveSlot("CURSE", 10) })
  local a2 = withMoves(monSeed(3, "SHEDINJA", 5, 0xA272), { moveSlot("CURSE", 10) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB171), { moveSlot("SPLASH", 40) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB272), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local scenario = doublesScenario({ a1, a2 }, { b1, b2 }, scenarioMoveFacts(seeds, nil), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local request = requestFor(frame, "alpha")
  local options = optionsFor(session, request)

  local plain = moveOption(actorEntry(options, 1), 0)
  Assert.isTrue(plain.targets == nil, "the ordinary curse offers no foe picker")
  local plainTarget = (plain.choice.payload or {}).target or {}
  Assert.equal(plainTarget.position, 1, "the ordinary curse names its holder slot")

  local hauntedOption = moveOption(actorEntry(options, 3), 0)
  Assert.deepEqual(variantPositions(hauntedOption), { 2, 4 }, "the haunted curse keeps both live foe slots")
  session:dispose()
end

-- Ally moves default to the user in singles: with no partner standing,
-- the projection names the striker slot directly instead of the lone foe.
function T.ally_moves_default_to_the_user_in_singles()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA181), { moveSlot("ALLY_PROBE", 30) })
  local b1 = withMoves(monSeed(2, "TOTODILE", 5, 0xB181), { moveSlot("SPLASH", 40) })
  local seeds = { a1, b1 }
  local extra = { ALLY_PROBE = probeFacts(256) }
  local Executor = executorOwner()
  local scenario = singlesScenario(a1, b1, scenarioMoveFacts(seeds, extra), scenarioSpeciesFacts(seeds))
  Assert.equal(scenario.ruleset, Executor.RULESET, "the singles vector runs the native ruleset")
  local session, frame = openWaiting(scenario)
  local request = requestFor(frame, "alpha")
  local ally = moveOption(actorEntry(optionsFor(session, request), 1), 0)
  Assert.isTrue(ally.targets == nil, "the singles ally move offers no picker")
  local allyTarget = (ally.choice.payload or {}).target or {}
  Assert.equal(allyTarget.position, 1, "the singles ally move defaults to the user slot")
  session:dispose()
end

---@param capture table interruption capture under inspection
---@param key string battle-local definition identity under test
---@param combatant integer combatant identity owning the wanted scope
---@return boolean true while the combatant carries a live instance of the key
local function hasUserMarker(capture, key, combatant)
  for _, record in ipairs(capture.effects or {}) do
    if record.key == key then
      local scope = record.scope --[[@as table<string, unknown>?]]
      if type(scope) == "table" and scope.kind == "active" and scope.combatant == combatant then
        return true
      end
    end
  end
  return false
end

-- Helping Hand boosts a live ally: the doubles attempt records its
-- cooperation marker on the user for one power point instead of failing.
function T.helping_hand_boosts_its_live_ally_in_doubles()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA191), { moveSlot("HELPING_HAND", 30) })
  local a2 = withMoves(monSeed(3, "TOTODILE", 5, 0xA292), { moveSlot("SPLASH", 40) })
  local b1 = withMoves(monSeed(2, "CHIKORITA", 5, 0xB191), { moveSlot("SPLASH", 40) })
  local b2 = withMoves(monSeed(4, "TOTODILE", 5, 0xB292), { moveSlot("SPLASH", 40) })
  local seeds = { a1, a2, b1, b2 }
  local extra = { HELPING_HAND = catalogCopy("HELPING_HAND", 256) }
  local scenario = doublesScenario({ a1, a2 }, { b1, b2 }, scenarioMoveFacts(seeds, extra), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local settled = playAnswers(session, projectedSlotZero(session, frame))
  Assert.equal(settled.status, "waiting", "the helping hand turn leaves the battle waiting")
  local after = session:capture()
  Assert.isTrue(hasUserMarker(after, "HELPING_HAND", 1), "the successful boost records its cooperation marker")
  Assert.equal(after.combatants[1].mon.moves[1].pp, 29, "the successful boost spends one power point")
  session:dispose()
end

-- Helping Hand fails with no ally standing: the singles attempt samples
-- only its user, so the kernel takes the failure branch without marking
-- and without a successful move-used, spending the attempt.
function T.helping_hand_fails_with_no_ally_in_singles()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA1A1), { moveSlot("HELPING_HAND", 30) })
  local b1 = withMoves(monSeed(2, "TOTODILE", 5, 0xB1A1), { moveSlot("SPLASH", 40) })
  local seeds = { a1, b1 }
  local extra = { HELPING_HAND = catalogCopy("HELPING_HAND", 256) }
  local scenario = singlesScenario(a1, b1, scenarioMoveFacts(seeds, extra), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local settled = playAnswers(session, projectedSlotZero(session, frame))
  Assert.equal(settled.status, "waiting", "the failed boost still leaves the battle waiting")
  local after = session:capture()
  Assert.isFalse(hasUserMarker(after, "HELPING_HAND", 1), "the failed boost records no cooperation marker")
  Assert.equal(after.combatants[1].mon.moves[1].pp, 29, "the failed attempt still spends its power point")
  session:dispose()
end

-- Self cooperation keeps succeeding on its own user: Charge marks its
-- own entry under the same shared body, so the ally guard never widens
-- onto user-scoped moves.
function T.charge_still_marks_its_user_in_singles()
  local a1 = withMoves(monSeed(1, "CHIKORITA", 5, 0xA1C1), { moveSlot("CHARGE", 30) })
  local b1 = withMoves(monSeed(2, "TOTODILE", 5, 0xB1C1), { moveSlot("SPLASH", 40) })
  local seeds = { a1, b1 }
  local extra = {
    CHARGE = { power = 0, accuracy = 100, category = "other", moveType = "electric", priority = 0, range = 16 },
  }
  local scenario = singlesScenario(a1, b1, scenarioMoveFacts(seeds, extra), scenarioSpeciesFacts(seeds))
  local session, frame = openWaiting(scenario)
  local settled = playAnswers(session, projectedSlotZero(session, frame))
  Assert.equal(settled.status, "waiting", "the charge turn leaves the battle waiting")
  local after = session:capture()
  Assert.equal(after.combatants[1].stages.specialDefense, 1, "Charge raises its user's Special Defense in singles")
  Assert.equal(after.combatants[1].mon.moves[1].pp, 29, "the self boost spends one power point")
  session:dispose()
end

return { tests = T }
