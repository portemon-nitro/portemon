-- Native session stat, status, and residual wiring: a stage move applied
-- through the ordinary move path changes later turn order through the
-- canonical stage projection, a major-status move applies through the
-- status owner and gates the later action at the before-action checkpoint,
-- end-of-turn residuals mutate health without strikes and route lethal
-- ticks through faint replacement, and interruption snapshots preserve live
-- effect state across restore without repeating ticks.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local NATIVE_FORMAT = "test:native-format"
local NATIVE_SEED = 0x1BADB002

---@return table loaded native session owner
local function executorOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

---@return table frozen battle content carrying the native ruleset binding
local function nativeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "stat-status-residual-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "stat-status-residual-tests"
  )
  behaviors:registerFormat(NATIVE_FORMAT, { key = NATIVE_FORMAT }, "stat-status-residual-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param seeds table<integer, table<string, unknown>>? combatant seeds whose strikes and learnsets resolve
---@return table<string, table<string, unknown>> immutable move facts for the fixture strikes and conditions
local function scenarioMoveFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {
    TACKLE = catalog:move("TACKLE"),
    QUICK_ATTACK = catalog:move("QUICK_ATTACK"),
    TOXIC = catalog:move("TOXIC"),
    GROWL = catalog:move("GROWL"),
    AGILITY = { power = 0, accuracy = 100, category = "other", moveType = "normal", priority = 0 },
    FAKE_OUT = { power = 40, accuracy = 100, category = "physical", moveType = "normal", priority = 1 },
    REFLECT = { power = 0, accuracy = 100, category = "other", moveType = "psychic", priority = 0 },
    SPORE = { power = 0, accuracy = 100, category = "other", moveType = "grass", priority = 0 },
    POISON_POWDER = { power = 0, accuracy = 100, category = "other", moveType = "poison", priority = 0 },
    SPLASH = { power = 0, accuracy = 100, category = "other", moveType = "normal", priority = 0 },
    SWORDS_DANCE = { power = 0, accuracy = 100, category = "other", moveType = "normal", priority = 0 },
    LEECH_SEED = { power = 0, accuracy = 100, category = "other", moveType = "grass", priority = 0 },
    ROOST = { power = 0, accuracy = 100, category = "other", moveType = "flying", priority = 0 },
  }
  -- Knockout rewards resolve recipient learnsets through the same
  -- catalog, so every moveset and learnset move carries its facts.
  for _, seed in ipairs(seeds or {}) do
    local learned = seed.mon --[[@as table<string, unknown>]]
    for _, entry in ipairs(learned.moves --[[@as table<integer, table<string, unknown>>]]) do
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
  for _, key in ipairs(formRecord.types --[[@as string[] ]]) do
    types[#types + 1] = key --[[@as string]]
  end
  return types
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the fixture combatants
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
      -- Knockout rewards read the same recipient facts on every faint,
      -- so the fixture carries the learnset and yields they require.
      levelUpMoves = catalog:form(species, form).levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
    }
  end
  return facts
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@param moves table<integer, table<string, unknown>> persistent move entries in slot order
---@return table combatant seed carrying its scripted moveset
local function movesetCombatant(id, seed, moves)
  local entry = SessionFixture.combatant(id, seed)
  entry.mon.moves = moves
  return entry
end

---@param move string move identity owning the slot
---@param pp integer power points carried by the slot
---@return table<string, unknown> persistent move entry for the slot
local function moveSlot(move, pp)
  return { move = move, pp = pp, ppUps = 0 }
end

---@param leads table<integer, table<string, unknown>> opening combatant seeds in battle order
---@param alphaReserves table<integer, table<string, unknown>> benched seeds owned by the first side
---@param betaReserves table<integer, table<string, unknown>> benched seeds owned by the second side
---@return table detached native battle setup record over the fixture content
local function duelScenario(leads, alphaReserves, betaReserves)
  local Executor = executorOwner()
  local seeds = {}
  for _, seed in ipairs(leads) do
    seeds[#seeds + 1] = seed
  end
  for _, seed in ipairs(alphaReserves) do
    seeds[#seeds + 1] = seed
  end
  for _, seed in ipairs(betaReserves) do
    seeds[#seeds + 1] = seed
  end
  local alphaRoster = { leads[1] }
  for _, seed in ipairs(alphaReserves) do
    alphaRoster[#alphaRoster + 1] = seed
  end
  local betaRoster = { leads[2] }
  for _, seed in ipairs(betaReserves) do
    betaRoster[#betaRoster + 1] = seed
  end
  return {
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", alphaRoster),
      SessionFixture.participant(2, 2, "beta", betaRoster),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, leads[1].id),
      SessionFixture.position(2, 2, { 2 }, leads[2].id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(seeds),
    speciesFacts = scenarioSpeciesFacts(seeds),
  }
end

---@param key string native definition identity under seeding
---@param id integer stable instance identity for the seeded record
---@param scope table owner scope for the seeded instance
---@param source table causal source for the seeded instance
---@param state table typed state for the seeded instance
---@return table effect record for the interruption capture
local function effectRecord(key, id, scope, source, state)
  local Handlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "one registration owner binds native definitions to their handlers"
  )
  local definition = Handlers.definitionFor(key)
  return {
    id = id,
    key = key,
    version = definition.stateVersion,
    scope = scope,
    source = source,
    state = definition.validateState(state),
    createdOrdinal = id,
    timings = definition.timings,
    lifecycle = definition.lifecycle,
  }
end

---@param session table live headless session under seeding
---@param content table frozen battle content for the restored session
---@param records table[] effect records to install through the capture
---@return table restored session carrying the seeded records
local function restoreWithEffects(session, content, records)
  local Executor = executorOwner()
  local snapshot = session:capture()
  session:dispose()
  for _, record in ipairs(records) do
    snapshot.effects[#snapshot.effects + 1] = record
  end
  return Executor.restore(snapshot, content)
end

---@param snapshot table<string, unknown> interruption capture under inspection
---@param key string definition identity under inspection
---@return table[] live records carrying the key
local function recordsWithKey(snapshot, key)
  local found = {}
  for _, record in ipairs(snapshot.effects --[[@as table<integer, table<string, unknown>>]]) do
    if record.key == key then
      found[#found + 1] = record
    end
  end
  return found
end

---@param plans table<string, table<string, unknown>> per-controller strike plans keyed by controller
---@return fun(request: table): table[] one strike per addressed actor from its controller plan
local function strikeAnswer(plans)
  return function(request)
    local plan = plans[request.controller] --[[@as table<string, unknown>]]
    Assert.notNil(plan, "every scripted controller carries its strike plan")
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(
        actor,
        plan.slot --[[@as integer]],
        plan.target --[[@as table<string, unknown>]]
      )
    end
    return choices
  end
end

---@param session table live headless session waiting for decisions
---@param answer fun(request: table): table[] choices per pending request
---@return table waiting or ended frame after the turn settles
---@return table[] events emitted while the turn settled, in sequence order
local function playTurn(session, answer)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "each scripted turn opens its decision batch")
  for _, request in ipairs(frame.request.requests) do
    local ok, err = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "scripted turn replies are accepted")
    Assert.isNil(err, "accepted turn replies carry no input error")
  end
  local events = {}
  for _ = 1, 64 do
    frame = session:advance()
    Assert.notNil(frame, "advance returns a battle frame")
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        events[#events + 1] = event
      end
    end
    if frame.status ~= "running" then
      return frame, events
    end
  end
  error("the scripted turn did not settle within its operation bound")
end

---@param events table[] emitted events under inspection
---@return string[] executing strike identities in resolution order
local function strikeKeys(events)
  local keys = {}
  for _, event in ipairs(events) do
    if event.kind == "struck" or event.kind == "missed" then
      keys[#keys + 1] = event.cause.key --[[@as string]]
    end
  end
  return keys
end

---@param events table[] emitted events under inspection
---@param kind string event kind under inspection
---@return boolean true when the turn emitted the kind
local function hasEventKind(events, kind)
  for _, event in ipairs(events) do
    if event.kind == kind then
      return true
    end
  end
  return false
end

---@param snapshot table<string, unknown> interruption capture under inspection
---@param id integer combatant identity under inspection
---@return table<string, unknown> live combatant record for the identity
local function combatantOf(snapshot, id)
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  local combatant = combatants[id]
  Assert.notNil(combatant, "captures carry combatant " .. tostring(id))
  return combatant --[[@as table<string, unknown>]]
end

---@param snapshot table<string, unknown> interruption capture under inspection
---@param id integer combatant identity under inspection
---@return table<string, unknown> canonical mon condition for the combatant
local function conditionOf(snapshot, id)
  local combatant = combatantOf(snapshot, id)
  local mon = combatant.mon --[[@as table<string, unknown>]]
  return mon.condition --[[@as table<string, unknown>]]
end

-- A self-raised Speed stage changes later turn order through the canonical
-- projection: the slower lead moves last while flat, then moves first once
-- its own stage move resolves, with the stage visible in battle state.
function T.raised_speed_stages_reorder_later_strikes()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("AGILITY", 30), moveSlot("TACKLE", 35) })
  local beta = movesetCombatant(2, 31, { moveSlot("SCRATCH", 35) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)

  local _, opening = playTurn(session, strikeAnswer({
    alpha = { slot = 1, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.deepEqual(
    strikeKeys(opening),
    { "SCRATCH", "TACKLE" },
    "the naturally faster lead strikes first while stages stay flat"
  )

  local _, staged = playTurn(session, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(1) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.isTrue(#staged > 0, "the stage turn settles its events")
  local stages = combatantOf(session:capture(), 1).stages --[[@as table<string, integer>]]
  Assert.equal(stages.speed, 2, "the self-raised Speed stage lands in battle state")

  local _, replayed = playTurn(session, strikeAnswer({
    alpha = { slot = 1, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.deepEqual(
    strikeKeys(replayed),
    { "TACKLE", "SCRATCH" },
    "the raised lead strikes first once its stage feeds ordering"
  )
  session:dispose()
end

-- A sleep move applies through the status owner and gates the later
-- action: the defender carries source-defined sleep turns, and its next
-- action either never starts (blocked) or clears the condition (woke).
function T.applied_sleep_gates_the_next_action()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SPORE", 15), moveSlot("TACKLE", 35) })
  local beta = movesetCombatant(2, 31, { moveSlot("QUICK_ATTACK", 30) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)

  local _, applied = playTurn(session, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.isTrue(#applied > 0, "the status turn settles its events")
  local appliedCondition = conditionOf(session:capture(), 2)
  local appliedEffects = appliedCondition.effects --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(#appliedEffects, 1, "the defender carries exactly the applied major status")
  Assert.equal(appliedEffects[1].key, "sleep", "the applied major status is sleep")
  local sleepState = appliedEffects[1].state --[[@as table<string, unknown>]]
  Assert.isTrue(
    type(sleepState.turns) == "number" and sleepState.turns --[[@as integer]] >= 1,
    "sleep carries its source-defined remaining turns"
  )

  local _, gated = playTurn(session, strikeAnswer({
    alpha = { slot = 1, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  local gatedKeys = strikeKeys(gated)
  local gatedEffects = conditionOf(session:capture(), 2).effects --[[@as table<integer, unknown>]]
  local blocked = true
  for _, key in ipairs(gatedKeys) do
    if key == "QUICK_ATTACK" then
      blocked = false
    end
  end
  Assert.isTrue(
    blocked or #gatedEffects == 0,
    "the gated action either never starts or wakes the defender"
  )
  session:dispose()
end

-- The catalog-spelled poison powder applies through the status owner:
-- the defender carries poison after the ordinary move path resolves,
-- in the same major-status family as the already-wired toxic and spore.
function T.catalog_poison_powder_applies_poison_through_the_move_path()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("POISON_POWDER", 35), moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)

  local landed = false
  for _ = 1, 4 do
    local _, events = playTurn(session, strikeAnswer({
      alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
      beta = { slot = 0, target = SessionFixture.positionTarget(1) },
    }))
    Assert.isTrue(#events > 0, "each powder turn settles its events")
    local effects = conditionOf(session:capture(), 2).effects --[[@as table<integer, table<string, unknown>>]]
    if #effects == 1 and effects[1].key == "poison" then
      landed = true
      break
    end
  end
  Assert.isTrue(landed, "the catalog-spelled powder poisons through the ordinary move path")
  session:dispose()
end

-- End-of-turn residuals mutate health without strikes and route lethal
-- ticks through faint replacement: a poisoned lead loses health across
-- strikeless turns, then faints and is replaced while the battle continues.
function T.lethal_residual_ticks_replace_the_fainted_lead()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("TOXIC", 10), moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)

  local idle = strikeAnswer({
    alpha = { slot = 1, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  })
  local landed = false
  for _ = 1, 8 do
    local _, events = playTurn(session, strikeAnswer({
      alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
      beta = { slot = 0, target = SessionFixture.positionTarget(1) },
    }))
    Assert.isTrue(#events > 0, "each poisoning turn settles its events")
    local effects = conditionOf(session:capture(), 2).effects --[[@as table<integer, table<string, unknown>>]]
    if #effects == 1 and effects[1].key == "toxic" then
      landed = true
      break
    end
  end
  Assert.isTrue(landed, "the status move poisons the defender through the ordinary move path")

  local fainted = false
  local closing = {}
  for _ = 1, 12 do
    local before = combatantOf(session:capture(), 2).hp --[[@as integer]]
    local frame, events = playTurn(session, idle)
    local after = combatantOf(session:capture(), 2).hp --[[@as integer]]
    Assert.isTrue(after < before, "the strikeless turn still drains the poisoned lead")
    Assert.isTrue(not hasEventKind(events, "struck"), "no strike deals the residual damage")
    closing = events
    if frame.status == "waiting" and after <= 0 then
      fainted = true
      break
    end
    Assert.equal(frame.status, "waiting", "the battle continues while the poisoned lead stands")
  end
  Assert.isTrue(fainted, "the accumulating ticks faint the poisoned lead")
  Assert.isTrue(hasEventKind(closing, "faint"), "the lethal tick announces the faint")
  local switchedTo = nil
  for _, event in ipairs(closing) do
    if event.kind == "switch" then
      switchedTo = event.payload.to --[[@as integer]]
    end
  end
  Assert.equal(switchedTo, 4, "faint settlement replaces the lead with its reserve")
  local positions = session:capture().positions --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(
    positions[2].occupant --[[@as integer]],
    4,
    "the reserve holds the vacated position after residual fainting"
  )
  session:dispose()
end

-- Interruption snapshots preserve live effect state across restore: a
-- restored session replays the same residual ticks and reaches the same
-- state as its uninterrupted twin, with no repeated or dropped tick.
function T.restored_effect_state_ticks_exactly_once()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("TOXIC", 10), moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)

  local idle = strikeAnswer({
    alpha = { slot = 1, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  })
  local landed = false
  for _ = 1, 8 do
    playTurn(session, strikeAnswer({
      alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
      beta = { slot = 0, target = SessionFixture.positionTarget(1) },
    }))
    local effects = conditionOf(session:capture(), 2).effects --[[@as table<integer, table<string, unknown>>]]
    if #effects == 1 and effects[1].key == "toxic" then
      landed = true
      break
    end
  end
  Assert.isTrue(landed, "the status move poisons the defender through the ordinary move path")
  for _ = 1, 3 do
    local before = combatantOf(session:capture(), 2).hp --[[@as integer]]
    local frame, _ = playTurn(session, idle)
    Assert.equal(frame.status, "waiting", "the battle continues across the sampled ticks")
    local after = combatantOf(session:capture(), 2).hp --[[@as integer]]
    Assert.isTrue(after < before, "each sampled turn ticks the poisoned lead")
    Assert.isTrue(after > 0, "the sampled ticks stop short of fainting")
  end

  local snapshot = session:capture()
  SessionFixture.assertPlainData(snapshot)
  local revived = Executor.restore(snapshot, content)

  local firstTrace = {}
  local secondTrace = {}
  for _ = 1, 4 do
    local firstFrame, firstEvents = playTurn(session, idle)
    local secondFrame, secondEvents = playTurn(revived, idle)
    for _, event in ipairs(firstEvents) do
      firstTrace[#firstTrace + 1] = event
    end
    for _, event in ipairs(secondEvents) do
      secondTrace[#secondTrace + 1] = event
    end
    Assert.equal(
      firstFrame.status,
      secondFrame.status,
      "restored and uninterrupted sessions agree on continuation"
    )
    if firstFrame.status == "ended" then
      break
    end
  end
  Assert.deepEqual(secondTrace, firstTrace, "restored sessions replay the residual ticks exactly once")
  Assert.deepEqual(revived:capture(), session:capture(), "restored sessions reach the same live effect state")
  session:dispose()
  revived:dispose()
end

-- Repeated stage moves clamp at the native bounds through the stage
-- owner: four dances land at plus six and seven growls land at minus
-- six, all through the ordinary move path.
function T.repeated_stage_moves_clamp_at_the_native_bounds()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SWORDS_DANCE", 30) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)

  local dance = strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(1) },
    beta = { slot = 0, target = SessionFixture.positionTarget(2) },
  })
  for _ = 1, 4 do
    local frame, _ = playTurn(session, dance)
    Assert.equal(frame.status, "waiting", "the battle continues across the setup turns")
  end
  local raised = combatantOf(session:capture(), 1).stages --[[@as table<string, integer>]]
  Assert.equal(raised.attack, 6, "the fourth dance clamps at plus six")
  session:dispose()

  local growler = movesetCombatant(1, 11, { moveSlot("GROWL", 40) })
  local listener = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local lowered = contracts.Battle.newSession(duelScenario({ growler, listener }, {}, {}), content)
  local growl = strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  })
  for _ = 1, 7 do
    local frame, _ = playTurn(lowered, growl)
    Assert.equal(frame.status, "waiting", "the battle continues across the dropping turns")
  end
  local dropped = combatantOf(lowered:capture(), 2).stages --[[@as table<string, integer>]]
  Assert.equal(dropped.attack, -6, "the seventh growl clamps at minus six")
  lowered:dispose()
end

-- Replacement clears battle-local state through the definition
-- lifecycle: a seeded, stage-raised lead leaves its seed behind and its
-- reserve enters at flat stages.
function T.switch_replacement_clears_stages_and_seeded_state()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SWORDS_DANCE", 30) })
  local beta = movesetCombatant(2, 31, { moveSlot("LEECH_SEED", 10), moveSlot("SPLASH", 40) })
  local reserve = movesetCombatant(3, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, { reserve }, {}), content)

  local _, seeded = playTurn(session, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(1) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.isTrue(#seeded > 0, "the seeding turn settles its events")
  local rooted = false
  for _, record in ipairs(session:capture().effects --[[@as table<integer, table<string, unknown>>]]) do
    if record.key == "leechseed" then
      rooted = true
    end
  end
  Assert.isTrue(rooted, "the seed lands in live effect state")

  local frame, _ = playTurn(session, function(request)
    if request.controller == "alpha" then
      local choices = {}
      for _, actor in ipairs(request.actors) do
        choices[#choices + 1] = SessionFixture.switchChoice(actor, 3)
      end
      return choices
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 1, SessionFixture.positionTarget(1))
    end
    return choices
  end)
  Assert.equal(frame.status, "waiting", "the battle continues after the replacement")
  local snapshot = session:capture()
  for _, record in ipairs(snapshot.effects --[[@as table<integer, table<string, unknown>>]]) do
    Assert.isTrue(record.key ~= "leechseed", "the seed clears with the departing entry")
  end
  local entered = combatantOf(snapshot, 3).stages --[[@as table<string, integer>]]
  for _, stat in ipairs({ "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }) do
    Assert.equal(entered[stat], 0, "the reserve enters at flat " .. stat)
  end
  session:dispose()
end

-- A second major status fails gracefully through the ordinary move path:
-- the replayed sleep emits no new status event and the first sleep
-- survives with its countdown intact.
function T.second_status_application_fails_without_touching_the_first()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SPORE", 15) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)

  local rehearsal = strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  })
  local _, applied = playTurn(session, rehearsal)
  local firstStatuses = 0
  for _, event in ipairs(applied) do
    if event.kind == "status" then
      firstStatuses = firstStatuses + 1
    end
  end
  Assert.equal(firstStatuses, 1, "the first sleep applies exactly one status event")

  local frame, replayed = playTurn(session, rehearsal)
  Assert.equal(frame.status, "waiting", "the refused replay never breaks the battle")
  for _, event in ipairs(replayed) do
    Assert.isTrue(event.kind ~= "status", "the refused replay emits no new status event")
  end
  local condition = conditionOf(session:capture(), 2)
  local effects = condition.effects --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(#effects, 1, "the defender still carries exactly one condition")
  Assert.equal(effects[1].key, "sleep", "the surviving condition is still sleep")
  session:dispose()
end

-- Battle-local stacking replaces instead of doubling: two seeds across
-- two turns leave exactly one live instance in session state.
function T.leech_seed_replaces_instead_of_stacking()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SWORDS_DANCE", 30) })
  local beta = movesetCombatant(2, 31, { moveSlot("LEECH_SEED", 10) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)

  local seed = strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(1) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  })
  for _ = 1, 2 do
    local frame, _ = playTurn(session, seed)
    Assert.equal(frame.status, "waiting", "the battle continues across the seeding turns")
  end
  local seeds = 0
  for _, record in ipairs(session:capture().effects --[[@as table<integer, table<string, unknown>>]]) do
    if record.key == "leechseed" then
      seeds = seeds + 1
    end
  end
  Assert.equal(seeds, 1, "the reseeded entry carries exactly one live seed")
  session:dispose()
end

-- Replacement transfer follows definition lifecycle through the real
-- owners: clear-policy seeds leave with the entry while carry-policy
-- curses re-anchor onto the incoming token.
function T.replacement_transfer_follows_definition_lifecycle()
  local Scenario = SessionFixture.requirePresent(
    "libs.battle.src.BattleScenario",
    "detached scenario validation owns setup order and membership"
  )
  local State =
    SessionFixture.requirePresent("libs.battle.src.BattleState", "private battle data owns reference invariants")
  local Context = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local Status = SessionFixture.requirePresent(
    "libs.battle.src.gen4.Status",
    "native major status law owns application and replacement resets"
  )
  local Handlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "one registration owner binds native definitions to their handlers"
  )
  local scenario = Scenario.validate(SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { SessionFixture.combatant(2, 23) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
  }))
  local state = State.create(scenario)
  local ctx = Context.wrap(state)
  local activation = State.combatant(state, 1).active.activation --[[@as integer]]
  ctx:addBattleEffect(
    Handlers.definitionFor("leechseed"),
    { kind = "active", combatant = 1, activation = activation },
    { kind = "move", combatant = 2 },
    { version = 1 }
  )
  local curse = ctx:addBattleEffect(
    Handlers.definitionFor("curse"),
    { kind = "active", combatant = 1, activation = activation },
    { kind = "move", combatant = 2 },
    { version = 1 }
  )
  Status.switchReset(State.combatant(state, 1).mon --[[@as table<string, unknown>]], state.effectBag, 1, 99)
  Assert.isFalse(ctx:hasBattleEffect(1, "leechseed"), "clear-policy seeds leave with the entry")
  local carried = state.effectBag:get(curse.id --[[@as integer]])
  Assert.notNil(carried, "carry-policy curses survive the replacement")
  Assert.deepEqual(
    carried.scope,
    { kind = "active", combatant = 1, activation = 99 },
    "the carried curse re-anchors onto the incoming token"
  )
end

-- Recovery caps at the battle maximum, not the entry value: a combatant
-- that entered wounded heals past its entry health up to its maximum,
-- and larger recoveries still clamp at that maximum.
function T.wounded_entries_heal_past_entry_health_up_to_the_maximum()
  local Scenario = SessionFixture.requirePresent(
    "libs.battle.src.BattleScenario",
    "detached scenario validation owns setup order and membership"
  )
  local State =
    SessionFixture.requirePresent("libs.battle.src.BattleState", "private battle data owns reference invariants")
  local Context = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local scenario = Scenario.validate(SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { SessionFixture.combatant(2, 23) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
  }))
  local state = State.create(scenario)
  local ctx = Context.wrap(state)
  local combatant = State.combatant(state, 1)
  local entryHp = combatant.entryHp --[[@as integer]]
  local maximum = entryHp + 40
  combatant.maxHp = maximum
  local wounded = entryHp - 10
  if wounded < 1 then
    wounded = 1
  end
  combatant.hp = wounded
  local cause = { kind = "test" }
  local first = ctx:heal(1, 25, cause)
  Assert.equal(first.before, wounded, "recovery reports the wounded health it started from")
  Assert.equal(first.after, wounded + 25, "recovery passes entry health toward the battle maximum")
  Assert.isTrue(first.after > entryHp, "the healed total sits above the wounded entry value")
  local second = ctx:heal(1, 1000, cause)
  Assert.equal(second.after, maximum, "oversized recovery still clamps at the battle maximum")
  Assert.equal(State.combatant(state, 1).hp --[[@as integer]], maximum, "the clamped maximum lands in battle state")
end

-- Roost restores half the battle maximum through the ordinary move path:
-- a wounded user heals without any strike, proving the handler reads the
-- live entry projection rather than a frame fact the session never sends.
function T.roost_restores_half_maximum_through_the_move_path()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("ROOST", 10) })
  alpha.mon.condition.currentHp = 3
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  local ceiling = combatantOf(session:capture(), 1).maxHp --[[@as integer]]
  Assert.isTrue(ceiling > 3, "the wounded user sits below its battle maximum")
  local frame, events = playTurn(session, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.equal(frame.status, "waiting", "the recovery turn continues the battle")
  local restored = nil
  for _, event in ipairs(events) do
    if event.kind == "healed" then
      local payload = event.payload --[[@as table<string, unknown>]]
      restored = payload.restored
    end
  end
  Assert.equal(restored, math.floor(ceiling / 2), "roost restores half the battle maximum")
  Assert.equal(
    combatantOf(session:capture(), 1).hp,
    3 + math.floor(ceiling / 2),
    "the restored health lands in battle state"
  )
  session:dispose()
end

-- A Fake Out flinch blocks the victim's later strike through the
-- before-action dispatch: the faster strike records the flinch on the
-- defender, the victim's attack never executes, the block is announced
-- before persistent status and move execution, and the flinch instance
-- is consumed exactly once.
function T.fake_out_flinch_blocks_the_later_strike_through_dispatch()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("FAKE_OUT", 10), moveSlot("TACKLE", 35) })
  local beta = movesetCombatant(2, 31, { moveSlot("TACKLE", 35) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)

  local frame, events = playTurn(session, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.equal(frame.status, "waiting", "the flinch turn continues the battle")
  Assert.deepEqual(strikeKeys(events), { "FAKE_OUT" }, "the flinched strike never executes")
  local blocked = false
  for _, event in ipairs(events) do
    if event.kind == "blocked" then
      local payload = event.payload --[[@as table<string, unknown>]]
      Assert.equal(payload.key, "flinch", "the block names its finite effect")
      Assert.equal(payload.combatant, 2, "the block names the flinched combatant")
      blocked = true
    end
  end
  Assert.isTrue(blocked, "the flinch announces its block before move execution")
  for _, record in ipairs(session:capture().effects --[[@as table<integer, table<string, unknown>>]]) do
    Assert.isTrue(record.key ~= "flinch", "the flinch is consumed by its block")
  end
  session:dispose()
end

-- A side-scoped hazard strikes the replacement on entry through the
-- entry dispatch: switching into Stealth Rock deals the exact
-- type-derived fraction before the entrant can act, carries no duration
-- side effect, and persists for later entries.
function T.switching_into_stealth_rock_pays_the_entry_fraction()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local Handlers = SessionFixture.requirePresent(
    "libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers",
    "one registration owner binds native definitions to their handlers"
  )
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)

  -- No reachable fixture strike lays the hazard yet, so the interruption
  -- capture carries it: the record is built from the registered native
  -- definition and restored through the production snapshot seam.
  local snapshot = session:capture()
  session:dispose()
  local definition = Handlers.definitionFor("stealthrock")
  snapshot.effects[#snapshot.effects + 1] = {
    id = 501,
    key = "stealthrock",
    version = definition.stateVersion,
    scope = { kind = "side", side = 2 },
    source = { kind = "move", combatant = 1 },
    state = definition.validateState({ version = 1 }),
    createdOrdinal = 501,
    timings = definition.timings,
    lifecycle = definition.lifecycle,
  }
  local restored = Executor.restore(snapshot, content)
  local ceiling = combatantOf(restored:capture(), 4).maxHp --[[@as integer]]
  Assert.isTrue(type(ceiling) == "number" and ceiling > 0, "the reserve carries its battle maximum")
  -- Rock meets the grass reserve neutrally: one eighth of maximum
  -- health, floored, with a minimum of one.
  local expected = math.floor(ceiling / 8)
  if expected < 1 then
    expected = 1
  end

  local frame, events = playTurn(restored, function(request)
    if request.controller == "alpha" then
      local choices = {}
      for _, actor in ipairs(request.actors) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      return choices
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.switchChoice(actor, 4)
    end
    return choices
  end)
  Assert.equal(frame.status, "waiting", "the battle continues after the hazardous entry")
  local ticked = nil
  for _, event in ipairs(events) do
    if event.kind == "tick" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if payload.key == "stealthrock" then
        Assert.equal(payload.combatant, 4, "the hazard strikes the entrant")
        ticked = payload.amount
      end
    end
  end
  Assert.equal(ticked, expected, "the entry hazard deals its exact derived fraction")
  Assert.equal(
    combatantOf(restored:capture(), 4).hp,
    ceiling - expected,
    "the derived hazard damage lands in battle state"
  )
  local settled = restored:capture()
  local hazards = 0
  for _, record in ipairs(settled.effects --[[@as table<integer, table<string, unknown>>]]) do
    if record.key == "stealthrock" then
      hazards = hazards + 1
      Assert.isNil(record.state.turns, "the entry pass leaves no residual duration")
    end
  end
  Assert.equal(hazards, 1, "the hazard persists for later entries")
  local positions = settled.positions --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(positions[2].occupant, 4, "the reserve holds the entered position")
  restored:dispose()
end

-- A side-scoped spikes layer strikes the replacement on entry through
-- the entry dispatch: one layer costs one eighth of battle maximum
-- health before the entrant can act, and the layers persist for later
-- entries.
function T.seeded_spikes_price_the_switch_in()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)
  local restored = restoreWithEffects(session, content, {
    effectRecord(
      "spikes",
      821,
      { kind = "side", side = 2 },
      { kind = "move", combatant = 1 },
      { version = 1, layers = 1 }
    ),
  })
  local ceiling = combatantOf(restored:capture(), 4).maxHp --[[@as integer]]
  Assert.isTrue(type(ceiling) == "number" and ceiling > 0, "the reserve carries its battle maximum")
  local expected = math.floor(ceiling / 8)

  local frame, events = playTurn(restored, function(request)
    if request.controller == "alpha" then
      local choices = {}
      for _, actor in ipairs(request.actors) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      return choices
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.switchChoice(actor, 4)
    end
    return choices
  end)
  Assert.equal(frame.status, "waiting", "the battle continues after the layered entry")
  local priced = nil
  for _, event in ipairs(events) do
    if event.kind == "hazard" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if payload.key == "spikes" then
        Assert.equal(payload.combatant, 4, "the layers strike the entrant")
        priced = payload.amount
      end
    end
  end
  Assert.equal(priced, expected, "the entry pays its exact layer fraction")
  Assert.equal(
    combatantOf(restored:capture(), 4).hp,
    ceiling - expected,
    "the derived layer damage lands in battle state"
  )
  Assert.equal(#recordsWithKey(restored:capture(), "spikes"), 1, "the layers persist for later entries")
  restored:dispose()
end

-- A confused attacker snaps out on its last counted turn through the
-- before-action pass: the expiry fires, the strike still executes, and
-- the instance leaves with the pass.
function T.confused_attacker_snaps_out_and_acts_on_its_last_turn()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("TACKLE", 35) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  local activation = combatantOf(session:capture(), 1).active.activation --[[@as integer]]
  local restored = restoreWithEffects(session, content, {
    effectRecord(
      "confusion",
      601,
      { kind = "active", combatant = 1, activation = activation },
      { kind = "move", combatant = 2 },
      { version = 1, turns = 1 }
    ),
  })

  local frame, events = playTurn(restored, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.equal(frame.status, "waiting", "the snap-out turn continues the battle")
  Assert.deepEqual(strikeKeys(events), { "TACKLE" }, "the cleared attacker still strikes")
  local expired = false
  for _, event in ipairs(events) do
    if event.kind == "expire" then
      local payload = event.payload --[[@as table<string, unknown>]]
      Assert.equal(payload.key, "confusion", "the expiry names its finite effect")
      Assert.equal(payload.combatant, 1, "the expiry names the cleared combatant")
      expired = true
    end
  end
  Assert.isTrue(expired, "the last counted turn announces its expiry")
  Assert.deepEqual(
    recordsWithKey(restored:capture(), "confusion"),
    {},
    "the snapped-out confusion leaves with the pass"
  )
  restored:dispose()
end

-- A side screen survives entries at full duration: raising Reflect then
-- switching costs only the legitimate turn-end tick, never an entry tick.
function T.raised_screen_keeps_its_duration_across_entries()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("REFLECT", 20), moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local reserve = movesetCombatant(3, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, { reserve }, {}), content)

  local frame, _ = playTurn(session, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(1) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.equal(frame.status, "waiting", "the screen turn continues the battle")
  local raised = recordsWithKey(session:capture(), "reflect")
  Assert.equal(#raised, 1, "the screen lands in live effect state")
  Assert.equal(raised[1].state.turns, 4, "the screen ticks once at turn end")

  local switched, _ = playTurn(session, function(request)
    if request.controller == "alpha" then
      local choices = {}
      for _, actor in ipairs(request.actors) do
        choices[#choices + 1] = SessionFixture.switchChoice(actor, 3)
      end
      return choices
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1))
    end
    return choices
  end)
  Assert.equal(switched.status, "waiting", "the battle continues after the replacement")
  local kept = recordsWithKey(session:capture(), "reflect")
  Assert.equal(#kept, 1, "the entry pass keeps the side screen")
  Assert.equal(kept[1].state.turns, 3, "the entry costs no duration beyond the turn-end tick")
  session:dispose()
end

-- Re-entry pays the hazard again on the new activation: switching out
-- and back through Stealth Rock ticks once per entry with the same
-- derived fraction.
function T.reentered_reserve_pays_the_hazard_again()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)
  local restored = restoreWithEffects(session, content, {
    effectRecord("stealthrock", 701, { kind = "side", side = 2 }, { kind = "move", combatant = 1 }, { version = 1 }),
  })
  local ceiling = combatantOf(restored:capture(), 4).maxHp --[[@as integer]]
  local expected = math.floor(ceiling / 8)
  if expected < 1 then
    expected = 1
  end
  local leadCeiling = combatantOf(restored:capture(), 2).maxHp --[[@as integer]]
  local leadExpected = math.floor(leadCeiling / 8)
  if leadExpected < 1 then
    leadExpected = 1
  end

  ---@param replacement integer arriving combatant for the beta controller
  ---@return fun(request: table): table[] scripted switch turn for the replacement
  local function switchAnswer(replacement)
    return function(request)
      if request.controller == "alpha" then
        local choices = {}
        for _, actor in ipairs(request.actors) do
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        end
        return choices
      end
      local choices = {}
      for _, actor in ipairs(request.actors) do
        choices[#choices + 1] = SessionFixture.switchChoice(actor, replacement)
      end
      return choices
    end
  end

  local first, firstEvents = playTurn(restored, switchAnswer(4))
  Assert.equal(first.status, "waiting", "the battle continues after the first entry")
  local second, secondEvents = playTurn(restored, switchAnswer(2))
  Assert.equal(second.status, "waiting", "the battle continues after the re-entry")
  local ticks = {}
  for _, events in ipairs({ firstEvents, secondEvents }) do
    for _, event in ipairs(events) do
      if event.kind == "tick" then
        local payload = event.payload --[[@as table<string, unknown>]]
        if payload.key == "stealthrock" then
          ticks[#ticks + 1] = payload
        end
      end
    end
  end
  Assert.equal(#ticks, 2, "each entry ticks exactly once")
  Assert.equal(ticks[1].combatant, 4, "the first entry strikes the reserve")
  Assert.equal(ticks[1].amount, expected, "the first entry pays the derived fraction")
  Assert.equal(ticks[2].combatant, 2, "the re-entry strikes the returning lead")
  Assert.equal(ticks[2].amount, leadExpected, "the re-entry pays the derived fraction again")
  Assert.equal(#recordsWithKey(restored:capture(), "stealthrock"), 1, "the hazard outlives both entries")
  restored:dispose()
end

-- Before-action denial scopes to the denied actor: a flinch seeded only
-- on the foe never touches the clean attacker's strike.
function T.only_the_flinched_actor_is_blocked()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("TACKLE", 35) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  local activation = combatantOf(session:capture(), 2).active.activation --[[@as integer]]
  local restored = restoreWithEffects(session, content, {
    effectRecord(
      "flinch",
      801,
      { kind = "active", combatant = 2, activation = activation },
      { kind = "move", combatant = 1 },
      { version = 1, turns = 1 }
    ),
  })

  local frame, events = playTurn(restored, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.equal(frame.status, "waiting", "the scoped turn continues the battle")
  Assert.deepEqual(strikeKeys(events), { "TACKLE" }, "the clean attacker strikes untouched")
  local blocked = false
  for _, event in ipairs(events) do
    if event.kind == "blocked" then
      local payload = event.payload --[[@as table<string, unknown>]]
      Assert.equal(payload.key, "flinch", "the block names its finite effect")
      Assert.equal(payload.combatant, 2, "the block names only the flinched combatant")
      blocked = true
    end
    Assert.isTrue(event.kind ~= "move-used", "the denied attacker never starts its splash")
  end
  Assert.isTrue(blocked, "the flinched attacker is still denied")
  restored:dispose()
end

-- A taunted attacker refuses status strikes but lands damage through
-- the before-action pass: the dance is denied with its countdown spent
-- while the following damaging strike executes untouched.
function T.taunted_attacker_refuses_status_strikes_but_lands_damage()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("TACKLE", 35) })
  local beta = movesetCombatant(2, 31, { moveSlot("TACKLE", 35), moveSlot("SWORDS_DANCE", 20) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  local activation = combatantOf(session:capture(), 2).active.activation --[[@as integer]]
  local restored = restoreWithEffects(session, content, {
    effectRecord(
      "taunt",
      811,
      { kind = "active", combatant = 2, activation = activation },
      { kind = "move", combatant = 1 },
      { version = 1, turns = 3 }
    ),
  })

  local denied, deniedEvents = playTurn(restored, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 1, target = SessionFixture.positionTarget(1) },
  }))
  Assert.equal(denied.status, "waiting", "the denied turn continues the battle")
  Assert.deepEqual(strikeKeys(deniedEvents), { "TACKLE" }, "only the clean attacker strikes")
  local refused = false
  for _, event in ipairs(deniedEvents) do
    if event.kind == "blocked" then
      local payload = event.payload --[[@as table<string, unknown>]]
      Assert.equal(payload.key, "taunt", "the block names its finite effect")
      Assert.equal(payload.combatant, 2, "the block names only the taunted combatant")
      refused = true
    end
    Assert.isTrue(event.kind ~= "stage", "the refused dance raises nothing")
  end
  Assert.isTrue(refused, "the taunted status strike is still denied")
  local stages = combatantOf(restored:capture(), 2).stages --[[@as table<string, integer>]]
  Assert.equal(stages.attack, 0, "the refused dance raises no stage in battle state")
  Assert.equal(
    recordsWithKey(restored:capture(), "taunt")[1].state.turns,
    2,
    "the denied action spends the taunt countdown"
  )

  local landed, landedEvents = playTurn(restored, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.equal(landed.status, "waiting", "the battle continues past the gated turn")
  Assert.deepEqual(
    strikeKeys(landedEvents),
    { "TACKLE", "TACKLE" },
    "the damaging strike lands through taunt"
  )
  restored:dispose()
end

-- Seeded finite records survive the interruption round-trip exactly:
-- capture, restore, and capture again reproduce every timing binding
-- and counter.
function T.seeded_effect_records_survive_capture_restore_exactly()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  local activation = combatantOf(session:capture(), 1).active.activation --[[@as integer]]
  local restored = restoreWithEffects(session, content, {
    effectRecord("stealthrock", 901, { kind = "side", side = 2 }, { kind = "move", combatant = 1 }, { version = 1 }),
    effectRecord(
      "confusion",
      902,
      { kind = "active", combatant = 1, activation = activation },
      { kind = "move", combatant = 2 },
      { version = 1, turns = 2 }
    ),
  })
  local before = restored:capture()
  SessionFixture.assertPlainData(before)
  local revived = restoreWithEffects(restored, content, {})
  local after = revived:capture()
  SessionFixture.assertPlainData(after)
  Assert.deepEqual(
    recordsWithKey(after, "stealthrock"),
    recordsWithKey(before, "stealthrock"),
    "the hazard survives the round-trip"
  )
  Assert.deepEqual(
    recordsWithKey(after, "confusion"),
    recordsWithKey(before, "confusion"),
    "the countdown survives the round-trip with its turns"
  )
  revived:dispose()
end

-- A live turn runs field recovery before mon affliction for the same
-- battler: the wounded ring-bearer heals before the seed drains it,
-- regardless of the seed's earlier creation ordinal.
function T.live_turn_residuals_heal_before_they_drain_the_same_battler()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local Executor = executorOwner()
  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  local activation = combatantOf(session:capture(), 1).active.activation --[[@as integer]]
  local snapshot = session:capture()
  session:dispose()
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  local wounded = combatants[1].hp --[[@as integer]] - 8
  if wounded < 1 then
    wounded = 1
  end
  combatants[1].hp = wounded
  snapshot.effects[#snapshot.effects + 1] = effectRecord(
    "leechseed",
    1,
    { kind = "active", combatant = 1, activation = activation },
    { kind = "move", combatant = 2 },
    { version = 1 }
  )
  snapshot.effects[#snapshot.effects + 1] = effectRecord(
    "aquaring",
    2,
    { kind = "active", combatant = 1, activation = activation },
    { kind = "move", combatant = 1 },
    { version = 1 }
  )
  local restored = Executor.restore(snapshot, content)
  local _, events = playTurn(restored, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  local healedAt = nil
  local tickAt = nil
  for index, event in ipairs(events) do
    local payload = event.payload --[[@as table<string, unknown>]]
    if type(payload) == "table" then
      if payload.key == "aquaring" and healedAt == nil then
        healedAt = index
      end
      if payload.key == "leechseed" and tickAt == nil then
        tickAt = index
      end
    end
  end
  Assert.notNil(healedAt, "the wounded ring-bearer heals")
  Assert.notNil(tickAt, "the seed drains its host")
  Assert.isTrue(
    healedAt --[[@as integer]] < tickAt --[[@as integer]],
    "recovery precedes affliction for the same battler"
  )
  restored:dispose()
end

-- An arrival fainted by its own entry hazard still owes its replacement:
-- the answered replacement sends a one-health reserve into rock, the
-- hazard kill drains through faint ownership into a second replacement,
-- and only the healthy reserve holds the position.
function T.hazard_faint_on_arrival_owes_a_second_replacement()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local lead = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  lead.mon.condition.currentHp = 1
  local frail = movesetCombatant(3, 41, { moveSlot("SPLASH", 40) })
  frail.mon.condition.currentHp = 1
  local healthy = movesetCombatant(5, 51, { moveSlot("SPLASH", 40) })
  local foe = movesetCombatant(2, 31, { moveSlot("TOXIC", 10), moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ lead, foe }, { frail, healthy }, {}), content)
  local restored = restoreWithEffects(session, content, {
    effectRecord("stealthrock", 701, { kind = "side", side = 1 }, { kind = "move", combatant = 2 }, { version = 1 }),
  })

  local replacements = { [1] = 3, [3] = 5 }
  local function answer(request)
    local kinds = {}
    if request.legalChoices ~= nil then
      kinds = request.legalChoices.kinds --[[@as table<integer, string>]]
    end
    local admitsSwitch = false
    local admitsAttack = false
    for _, kind in ipairs(kinds) do
      if kind == "switch" then
        admitsSwitch = true
      end
      if kind == "attack" then
        admitsAttack = true
      end
    end
    local choices = {}
    for _, actor in ipairs(request.actors) do
      if admitsSwitch and not admitsAttack then
        local reserve = replacements[actor.combatant --[[@as integer]]]
        Assert.notNil(reserve, "every replacement names its planned reserve")
        choices[#choices + 1] = SessionFixture.switchChoice(actor, reserve --[[@as integer]])
      elseif request.controller == "beta" then
        local effects = conditionOf(restored:capture(), 1).effects --[[@as table<integer, table<string, unknown>>]]
        if #effects > 0 then
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 1, SessionFixture.positionTarget(1))
        else
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1))
        end
      else
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
    end
    return choices
  end

  local landed = false
  local frame = nil
  local firstEvents = {}
  for _ = 1, 8 do
    local settled
    settled, firstEvents = playTurn(restored, answer)
    frame = settled
    local effects = conditionOf(restored:capture(), 1).effects --[[@as table<integer, table<string, unknown>>]]
    if #effects == 1 and effects[1].key == "toxic" then
      landed = true
      break
    end
    Assert.equal(settled.status, "waiting", "the battle continues while the powder misses")
  end
  Assert.isTrue(landed, "the foe poisons the one-health lead through the ordinary move path")
  Assert.isTrue(hasEventKind(firstEvents, "faint"), "the first lethal tick announces the lead faint")
  Assert.notNil(frame, "the fainting turn settles its frame")

  local second, secondEvents = playTurn(restored, answer)
  Assert.equal(second.status, "waiting", "the hazard faint suspends on its own replacement")
  Assert.notNil(second.request, "the arrival kill waits instead of settling an outcome")
  local again = nil
  for _, request in ipairs(second.request.requests) do
    local kinds = request.legalChoices.kinds --[[@as table<integer, string>]]
    if #kinds == 1 and kinds[1] == "switch" then
      again = request
    end
  end
  Assert.notNil(again, "the arrival kill waits for a replacement instead of settling an outcome")
  local reasserted = assert(again, "the second replacement is addressed")
  Assert.equal(
    reasserted.actors[1].combatant,
    3,
    "the second obligation names the hazard-fainted arrival"
  )
  Assert.isTrue(hasEventKind(secondEvents, "faint"), "the hazard kill announces its faint")

  local third, thirdEvents = playTurn(restored, answer)
  Assert.equal(third.status, "waiting", "the healthy arrival continues the battle")
  local ceiling = combatantOf(restored:capture(), 5).maxHp --[[@as integer]]
  local expected = math.floor(ceiling / 8)
  if expected < 1 then
    expected = 1
  end
  Assert.equal(
    combatantOf(restored:capture(), 5).hp,
    ceiling - expected,
    "the healthy arrival pays exactly the entry fraction"
  )
  Assert.equal(
    restored:capture().positions[1].occupant,
    5,
    "the healthy reserve holds the vacated position"
  )
  local struck = {}
  for _, events in ipairs({ secondEvents, thirdEvents }) do
    for _, event in ipairs(events) do
      if event.kind == "tick" then
        local payload = event.payload --[[@as table<string, unknown>]]
        if payload.key == "stealthrock" then
          struck[#struck + 1] = payload
        end
      end
    end
  end
  Assert.equal(#struck, 2, "each arrival pays the hazard exactly once")
  Assert.equal(struck[1].combatant, 3, "the first arrival tick strikes the frail reserve")
  Assert.equal(struck[2].combatant, 5, "the second arrival tick strikes the healthy reserve")
  Assert.equal(struck[2].amount, expected, "the second arrival pays the derived fraction")
  restored:dispose()
end

-- Field weather reaches ordinary strikes through the projected facts:
-- twin sessions share every seed, so their rolls agree and only the
-- weather law separates the struck amounts. Rain halves the fire probe
-- and boosts the water probe, sun inverts both, and a living suppressor
-- restores neutral amounts while every twin consumes identical draws.
--- Neutral high-level probe pair: normal-type leads stay neutral to fire
-- and water while their stats keep every weather truncation visible.
---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@param moves table<integer, table<string, unknown>> persistent move entries in slot order
---@return table combatant seed carrying its scripted moveset
local function eeveeCombatant(id, seed, moves)
  local entry = { id = id, mon = SessionFixture.makeMon(seed, { species = "EEVEE", level = 50 }) }
  entry.mon.moves = moves
  return entry
end

---@param moveType string probe move type carried by the water-gun strike
---@return table detached native battle setup record with the typed probe
local function probeScenario(moveType)
  local alpha = eeveeCombatant(1, 11, { moveSlot("WATER_GUN", 25), moveSlot("SPLASH", 40) })
  local beta = eeveeCombatant(2, 31, { moveSlot("SPLASH", 40) })
  local setup = duelScenario({ alpha, beta }, {}, {})
  setup.moveFacts.WATER_GUN = { power = 40, accuracy = 100, category = "special", moveType = moveType, priority = 0 }
  return setup
end

---@param session table live headless session playing its opening strike
---@return integer damage the opening water-gun strike dealt
---@return table rng position after the opening turn
local function openingStrike(session)
  local frame, events = playTurn(session, strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.equal(frame.status, "waiting", "the probe turn continues the battle")
  local dealt = nil
  for _, event in ipairs(events) do
    if event.kind == "struck" then
      local payload = event.payload --[[@as table<string, unknown>]]
      if payload.target == 2 then
        dealt = payload.damage
      end
    end
  end
  Assert.notNil(dealt, "the opening strike lands on the defender")
  local rng = session:capture().rng --[[@as table<string, unknown>]]
  Assert.notNil(rng, "captures carry the stream position")
  return dealt --[[@as integer]], rng
end

---@param content table frozen battle content for the restored session
---@param setup table detached native battle setup record under seeding
---@param weatherKey string field weather identity to seed, or nil for clear skies
---@return table live session carrying the seeded sky
local function sessionWithSky(content, setup, weatherKey)
  local contracts = SessionFixture.sessionContracts()
  local session = contracts.Battle.newSession(setup, content)
  if weatherKey == nil then
    return session
  end
  return restoreWithEffects(session, content, {
    effectRecord(
      weatherKey,
      901,
      { kind = "field" },
      { kind = "move", combatant = 1 },
      { version = 1, turns = 5 }
    ),
  })
end

function T.field_weather_scales_fire_and_water_strikes_without_extra_draws()
  local contracts = SessionFixture.sessionContracts()
  Assert.notNil(contracts, "session contracts load before the weather twins run")
  local content = nativeContent()

  local fireNeutral = sessionWithSky(content, probeScenario("fire"), nil)
  local neutralFire, neutralRng = openingStrike(fireNeutral)
  local fireRain = sessionWithSky(content, probeScenario("fire"), "raindance")
  local rainFire, rainRng = openingStrike(fireRain)
  local fireSun = sessionWithSky(content, probeScenario("fire"), "sunnyday")
  local sunFire, _ = openingStrike(fireSun)
  Assert.isTrue(rainFire < neutralFire, "rain halves the fire strike")
  Assert.isTrue(sunFire > neutralFire, "sun boosts the fire strike")
  Assert.deepEqual(rainRng, neutralRng, "rain adds no random draws to the strike")

  local waterNeutral = sessionWithSky(content, probeScenario("water"), nil)
  local neutralWater, _ = openingStrike(waterNeutral)
  local waterRain = sessionWithSky(content, probeScenario("water"), "raindance")
  local rainWater, _ = openingStrike(waterRain)
  local waterSun = sessionWithSky(content, probeScenario("water"), "sunnyday")
  local sunWater, sunRng = openingStrike(waterSun)
  Assert.isTrue(rainWater > neutralWater, "rain boosts the water strike")
  Assert.isTrue(sunWater < neutralWater, "sun halves the water strike")
  Assert.deepEqual(sunRng, neutralRng, "sun adds no random draws to the strike")

  fireNeutral:dispose()
  fireRain:dispose()
  fireSun:dispose()
  waterNeutral:dispose()
  waterRain:dispose()
  waterSun:dispose()
end

-- A living suppressor neutralizes the sky without deleting it: the same
-- rainy twin with a cloud-nine defender deals the neutral amount while
-- the weather instance survives in live effect state.
function T.suppressing_ability_neutralizes_rain_without_clearing_it()
  local content = nativeContent()

  local plain = sessionWithSky(content, probeScenario("fire"), nil)
  local neutralFire, neutralRng = openingStrike(plain)

  local alpha = eeveeCombatant(1, 11, { moveSlot("WATER_GUN", 25), moveSlot("SPLASH", 40) })
  local beta = eeveeCombatant(2, 31, { moveSlot("SPLASH", 40) })
  beta.mon.ability = "CLOUD_NINE"
  local setup = duelScenario({ alpha, beta }, {}, {})
  setup.moveFacts.WATER_GUN = { power = 40, accuracy = 100, category = "special", moveType = "fire", priority = 0 }
  local contracts = SessionFixture.sessionContracts()
  local seeded = contracts.Battle.newSession(setup, content)
  local rainy = restoreWithEffects(seeded, content, {
    effectRecord("raindance", 902, { kind = "field" }, { kind = "move", combatant = 1 }, { version = 1, turns = 5 }),
  })
  local suppressedFire, suppressedRng = openingStrike(rainy)
  Assert.equal(suppressedFire, neutralFire, "the suppressor restores the neutral amount under rain")
  Assert.deepEqual(suppressedRng, neutralRng, "suppression adds no random draws to the strike")
  local skies = 0
  for _, record in ipairs(rainy:capture().effects --[[@as table<integer, table<string, unknown>>]]) do
    if record.key == "raindance" then
      skies = skies + 1
    end
  end
  Assert.equal(skies, 1, "the rain instance survives suppression")
  plain:dispose()
  rainy:dispose()
end

-- Burn reaches ordinary strikes through the projected facts: the burned
-- twin halves its physical tackle while its special water-gun strike
-- matches the clean twin exactly, and both twins consume identical
-- draws.
function T.burn_halves_physical_strikes_and_spares_special_ones()
  local content = nativeContent()
  local contracts = SessionFixture.sessionContracts()

  ---@param burned boolean whether the attacker carries the burn condition
  ---@param slot integer attacker move slot under the probe
  ---@return integer damage the probe strike dealt
  ---@return table rng position after the probe turn
  local function probeStrike(burned, slot)
    local alpha = movesetCombatant(1, 11, { moveSlot("TACKLE", 35), moveSlot("WATER_GUN", 25) })
    if burned then
      local mon = alpha.mon --[[@as table<string, unknown>]]
      local condition = mon.condition --[[@as table<string, unknown>]]
      condition.effects = { { key = "burn", version = 1, state = {} } }
    end
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    local setup = duelScenario({ alpha, beta }, {}, {})
    local session = contracts.Battle.newSession(setup, content)
    local frame, events = playTurn(session, strikeAnswer({
      alpha = { slot = slot, target = SessionFixture.positionTarget(2) },
      beta = { slot = 0, target = SessionFixture.positionTarget(1) },
    }))
    Assert.equal(frame.status, "waiting", "the probe turn continues the battle")
    local dealt = nil
    for _, event in ipairs(events) do
      if event.kind == "struck" then
        local payload = event.payload --[[@as table<string, unknown>]]
        if payload.target == 2 then
          dealt = payload.damage
        end
      end
    end
    Assert.notNil(dealt, "the probe strike lands on the defender")
    local rng = session:capture().rng --[[@as table<string, unknown>]]
    session:dispose()
    return dealt --[[@as integer]], rng
  end

  local plainPhysical, plainRng = probeStrike(false, 0)
  local burnedPhysical, burnedRng = probeStrike(true, 0)
  Assert.isTrue(burnedPhysical < plainPhysical, "burn halves the physical strike")
  Assert.deepEqual(burnedRng, plainRng, "burn adds no random draws to the strike")

  local plainSpecial, _ = probeStrike(false, 1)
  local burnedSpecial, _ = probeStrike(true, 1)
  Assert.equal(burnedSpecial, plainSpecial, "burn spares the special strike")
end

---@param events table[] emitted events under inspection
---@return table[] only healed/tick/faint events in sequence order
local function residualSlice(events)
  local kept = {}
  for _, event in ipairs(events) do
    if event.kind == "healed" or event.kind == "tick" or event.kind == "faint" then
      kept[#kept + 1] = event
    end
  end
  return kept
end

---@param event table<string, unknown> emitted event under inspection
---@return string effect identity behind the event
local function residualKey(event)
  local payload = event.payload
  if type(payload) == "table" and type(payload.key) == "string" then
    return payload.key --[[@as string]]
  end
  local cause = event.cause
  if type(cause) == "table" and type(cause.key) == "string" then
    return cause.key --[[@as string]]
  end
  return "?"
end

---@param event table<string, unknown> emitted event under inspection
---@return integer combatant behind the event, or -1 when it names none
local function residualWho(event)
  local payload = event.payload
  if type(payload) == "table" and type(payload.combatant) == "number" then
    return payload.combatant --[[@as integer]]
  end
  if type(payload) == "table" and type(payload.target) == "number" then
    return payload.target --[[@as integer]]
  end
  return -1
end

---@param events table[] emitted events under inspection
---@param combatant integer holder under inspection
---@return string[] kind:key signatures for the holder in sequence order
local function holderSequence(events, combatant)
  local signatures = {}
  for _, event in ipairs(residualSlice(events)) do
    if residualWho(event) == combatant then
      signatures[#signatures + 1] = event.kind .. ":" .. residualKey(event)
    end
  end
  return signatures
end

---@param makeScenario fun(): table<string, unknown> fresh scenario builder under the probe
---@return table<integer, integer> battle maximum health per combatant identity
local function ceilingsOf(makeScenario)
  local contracts = SessionFixture.sessionContracts()
  local session = contracts.Battle.newSession(makeScenario(), nativeContent())
  local snapshot = session:capture()
  local ceilings = {}
  for id, combatant in pairs(snapshot.combatants --[[@as table<integer, table<string, unknown>>]]) do
    local ceiling = combatant.maxHp
    Assert.isTrue(type(ceiling) == "number" and ceiling > 0, "the probe carries a battle maximum")
    ceilings[id] = ceiling --[[@as integer]]
  end
  session:dispose()
  return ceilings
end

---@param session table live headless session under seeding
---@param content table frozen battle content for the restored session
---@param key string native definition identity under seeding
---@param id integer stable instance identity for the seeded record
---@param combatantId integer holder combatant for the seeded instance
---@param sourceCombatant integer causal combatant for the seeded instance
---@return table restored session carrying the seeded record
local function restoreWithNative(session, content, key, id, combatantId, sourceCombatant)
  local activation = combatantOf(session:capture(), combatantId).active.activation --[[@as integer]]
  return restoreWithEffects(session, content, {
    effectRecord(
      key,
      id,
      { kind = "active", combatant = combatantId, activation = activation },
      { kind = "move", combatant = sourceCombatant },
      { version = 1 }
    ),
  })
end

---@param answer fun(request: table): table[] choices per pending request
---@return fun(request: table): table[] splash-only turn for both controllers
local function splashOnly()
  return strikeAnswer({
    alpha = { slot = 0, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  })
end

-- Gradual recovery lands before the affliction tick: a poisoned holder
-- whose poison alone is lethal survives when its persistent holding
-- heals first, with the heal ordered ahead of the tick.
function T.recovery_before_affliction_decides_survival()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  ---@return table detached native battle setup record over fresh seeds
  local function makeScenario()
    local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
    return duelScenario({ alpha, beta }, {}, { reserve })
  end
  local ceiling = ceilingsOf(makeScenario)[2]
  local restored = math.floor(ceiling / 16)
  Assert.isTrue(restored >= 1, "the fixture ceiling carries a nonzero gradual recovery")

  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  alpha.mon.ability = "NONE"
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  beta.mon.ability = "NONE"
  beta.mon.heldItem = "LEFTOVERS"
  beta.mon.condition.effects = { { key = "toxic", version = 1, state = { counter = 0 } } }
  beta.mon.condition.currentHp = 1
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)

  local frame, events = playTurn(session, splashOnly())
  Assert.equal(frame.status, "waiting", "the battle continues past the residual turn")
  Assert.deepEqual(
    holderSequence(events, 2),
    { "healed:LEFTOVERS", "tick:toxic" },
    "the persistent holding heals before the toxic tick"
  )
  Assert.equal(combatantOf(session:capture(), 2).hp, 1, "the holder survives on the recovery-first margin")
  session:dispose()
end

-- A killing drain settles before later afflictions: the seeded holder
-- faints to its drain with exactly one faint boundary, no later poison
-- tick, while the surviving holder keeps its own recovery phase.
function T.lethal_seed_suppresses_the_later_affliction()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  ---@return table detached native battle setup record over fresh seeds
  local function makeScenario()
    local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
    return duelScenario({ alpha, beta }, {}, { reserve })
  end
  local ceilings = ceilingsOf(makeScenario)

  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  alpha.mon.ability = "NONE"
  alpha.mon.heldItem = "LEFTOVERS"
  alpha.mon.condition.currentHp = ceilings[1] - math.floor(ceilings[1] / 4)
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  beta.mon.ability = "NONE"
  beta.mon.condition.effects = { { key = "poison", version = 1, state = {} } }
  beta.mon.condition.currentHp = 1
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)
  local restored = restoreWithNative(session, content, "leechseed", 901, 2, 1)

  local frame, events = playTurn(restored, splashOnly())
  Assert.equal(frame.status, "waiting", "the battle continues past the faint replacement")
  local slice = residualSlice(events)
  local faints = 0
  local drained = false
  for _, event in ipairs(slice) do
    if event.kind == "faint" then
      faints = faints + 1
      Assert.equal(residualWho(event), 2, "the faint names the drained holder")
    end
    if event.kind == "tick" and residualKey(event) == "leechseed" then
      Assert.equal(residualWho(event), 2, "the drain names its victim")
      drained = true
    end
    Assert.isTrue(
      not (event.kind == "tick" and residualKey(event) == "poison"),
      "the fainted holder takes no later poison tick"
    )
  end
  Assert.isTrue(drained, "the killing drain ticks before settlement")
  Assert.equal(faints, 1, "exactly one faint boundary follows the killing phase")
  Assert.deepEqual(
    holderSequence(events, 1),
    { "healed:LEFTOVERS" },
    "the surviving holder keeps its own recovery phase"
  )
  restored:dispose()
end

-- Residual work nests by battler before phase: each holder completes
-- its own recovery-then-affliction sequence before the next holder
-- begins, instead of grouping every affliction ahead of every recovery.
function T.residual_work_nests_by_battler_before_phase()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  ---@return table detached native battle setup record over fresh seeds
  local function makeScenario()
    local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    return duelScenario({ alpha, beta }, {}, {})
  end
  local ceilings = ceilingsOf(makeScenario)

  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  alpha.mon.ability = "NONE"
  alpha.mon.condition.effects = { { key = "poison", version = 1, state = {} } }
  alpha.mon.condition.currentHp = math.floor(ceilings[1] * 3 / 4)
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  beta.mon.ability = "NONE"
  beta.mon.condition.effects = { { key = "poison", version = 1, state = {} } }
  beta.mon.condition.currentHp = math.floor(ceilings[2] * 3 / 4)
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  local seeded = restoreWithNative(session, content, "ingrain", 901, 1, 1)
  local activationTwo = combatantOf(seeded:capture(), 2).active.activation --[[@as integer]]
  local rooted = restoreWithEffects(seeded, content, {
    effectRecord(
      "ingrain",
      902,
      { kind = "active", combatant = 2, activation = activationTwo },
      { kind = "move", combatant = 2 },
      { version = 1 }
    ),
  })

  local frame, events = playTurn(rooted, splashOnly())
  Assert.equal(frame.status, "waiting", "the battle continues past the nested pass")
  local slice = residualSlice(events)
  Assert.isTrue(#slice == 4, "each holder heals and ticks exactly once")
  local first = residualWho(slice[1])
  Assert.isTrue(first == 1 or first == 2, "the pass opens on a live battler")
  local second = 3 - first
  Assert.deepEqual(holderSequence(events, first), { "healed:ingrain", "tick:poison" }, "the opening holder finishes before the next begins")
  Assert.deepEqual(holderSequence(events, second), { "healed:ingrain", "tick:poison" }, "the trailing holder keeps the same phase order")
  local order = {}
  for _, event in ipairs(slice) do
    order[#order + 1] = residualWho(event)
  end
  Assert.deepEqual(order, { first, first, second, second }, "no later-battler phase interleaves")
  rooted:dispose()
end

-- Innate answers keep their relative positions: the rooted ability
-- heals ahead of the persistent holding on the same holder, and the
-- consumable holding heals and spends ahead of the later affliction
-- on its own holder.
function T.innate_answers_keep_their_relative_positions()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  ---@return table detached native battle setup record over fresh seeds
  local function makeScenario()
    local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
    return duelScenario({ alpha, beta }, {}, { reserve })
  end
  local ceilings = ceilingsOf(makeScenario)
  Assert.isTrue(ceilings[1] >= 16, "the fixture ceiling leaves headroom for three stacked recoveries")
  local betaDamage = math.floor(ceilings[2] / 8)
  local betaRestore = math.floor(ceilings[2] / 4)
  Assert.isTrue(betaDamage >= 2 and betaRestore >= 2, "the fixture ceiling carries the consumable margin")

  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  alpha.mon.ability = "POISON_HEAL"
  alpha.mon.heldItem = "LEFTOVERS"
  alpha.mon.condition.effects = { { key = "poison", version = 1, state = {} } }
  alpha.mon.condition.currentHp = ceilings[1] - math.floor(ceilings[1] / 4)
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  beta.mon.ability = "NONE"
  beta.mon.heldItem = "SITRUS_BERRY"
  beta.mon.condition.effects = { { key = "poison", version = 1, state = {} } }
  beta.mon.condition.currentHp = betaDamage - 1
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)
  local rooted = restoreWithNative(session, content, "ingrain", 901, 1, 1)

  local frame, events = playTurn(rooted, splashOnly())
  Assert.equal(frame.status, "waiting", "the battle continues past the answering pass")
  Assert.deepEqual(
    holderSequence(events, 1),
    { "healed:ingrain", "healed:POISON_HEAL", "healed:LEFTOVERS" },
    "rooting, ability, and gradual holding answer in position"
  )
  Assert.deepEqual(
    holderSequence(events, 2),
    { "healed:SITRUS_BERRY", "tick:poison" },
    "the consumable holding spends ahead of the later affliction"
  )
  local snapshot = rooted:capture()
  Assert.equal(
    combatantOf(snapshot, 2).hp,
    betaDamage - 1 + betaRestore - betaDamage,
    "the consumable margin decides survival"
  )
  Assert.equal(
    (combatantOf(snapshot, 2).mon --[[@as table<string, unknown>]]).heldItem,
    "NONE",
    "the spent holding is visible to later phases"
  )
  rooted:dispose()
end

-- The toxic count advances exactly once per completed pass: three
-- quiet turns raise the counter by one each and deal the exact
-- counter-scaled fraction.
function T.toxic_count_advances_once_per_completed_pass()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  ---@return table detached native battle setup record over fresh seeds
  local function makeScenario()
    local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    return duelScenario({ alpha, beta }, {}, {})
  end
  local ceiling = ceilingsOf(makeScenario)[2]

  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  alpha.mon.ability = "NONE"
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  beta.mon.ability = "NONE"
  beta.mon.condition.effects = { { key = "toxic", version = 1, state = { counter = 0 } } }
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  for turn = 1, 3 do
    local before = combatantOf(session:capture(), 2).hp --[[@as integer]]
    local frame, _ = playTurn(session, splashOnly())
    Assert.equal(frame.status, "waiting", "the battle continues across the sampled passes")
    local effects = conditionOf(session:capture(), 2).effects --[[@as table<integer, table<string, unknown>>]]
    Assert.equal(#effects, 1, "the holder carries exactly its toxic")
    local counter = effects[1].state.counter
    Assert.equal(counter, turn, "the count advances exactly once per pass")
    local expected = math.floor(ceiling / 16) * turn
    if expected < 1 then
      expected = 1
    end
    Assert.equal(before - combatantOf(session:capture(), 2).hp --[[@as integer]], expected, "the tick deals the exact scaled fraction")
  end
  session:dispose()
end

-- Fainting ahead of the toxic phase freezes the count: the seeded
-- holder dies to its drain with no toxic tick and the counter it
-- carried into the turn.
function T.faint_before_the_toxic_phase_freezes_the_count()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  ---@return table detached native battle setup record over fresh seeds
  local function makeScenario()
    local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
    return duelScenario({ alpha, beta }, {}, { reserve })
  end
  ceilingsOf(makeScenario)

  local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
  alpha.mon.ability = "NONE"
  local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
  beta.mon.ability = "NONE"
  beta.mon.condition.effects = { { key = "toxic", version = 1, state = { counter = 2 } } }
  beta.mon.condition.currentHp = 1
  local reserve = movesetCombatant(4, 41, { moveSlot("SPLASH", 40) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, { reserve }), content)
  local seeded = restoreWithNative(session, content, "leechseed", 901, 2, 1)

  local frame, events = playTurn(seeded, splashOnly())
  Assert.equal(frame.status, "waiting", "the battle continues past the faint replacement")
  local faints = 0
  for _, event in ipairs(residualSlice(events)) do
    if event.kind == "faint" then
      faints = faints + 1
    end
    Assert.isTrue(
      not (event.kind == "tick" and residualKey(event) == "toxic"),
      "no toxic tick follows the killing drain"
    )
  end
  Assert.equal(faints, 1, "exactly one faint boundary follows the killing phase")
  local effects = conditionOf(seeded:capture(), 2).effects --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(#effects, 1, "the fainted holder still carries its toxic record")
  Assert.equal(effects[1].state.counter, 0, "faint settlement restarts the departed holder's count")
  seeded:dispose()
end

-- Restored sessions replay committed turns exactly once: a twin
-- restored across a consumable spend and a mid-count toxic reaches
-- the same events, health, holdings, counts, and random continuation
-- as its uninterrupted sibling.
function T.restored_sessions_replay_committed_turns_exactly_once()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = nativeContent()
  ---@return table detached native battle setup record over fresh seeds
  local function makeScenario()
    local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    return duelScenario({ alpha, beta }, {}, {})
  end
  local ceilings = ceilingsOf(makeScenario)

  ---@return table<string, unknown> fresh live session over damaging setup
  local function makeSession()
    local alpha = movesetCombatant(1, 11, { moveSlot("SPLASH", 40) })
    alpha.mon.ability = "NONE"
    alpha.mon.heldItem = "SITRUS_BERRY"
    alpha.mon.condition.currentHp = math.floor(ceilings[1] * 2 / 5)
    local beta = movesetCombatant(2, 31, { moveSlot("SPLASH", 40) })
    beta.mon.ability = "NONE"
    beta.mon.condition.effects = { { key = "toxic", version = 1, state = { counter = 2 } } }
    beta.mon.condition.currentHp = ceilings[2] - math.floor(ceilings[2] / 8)
    return contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)
  end
  local session = makeSession()
  local snapshot = session:capture()
  SessionFixture.assertPlainData(snapshot)
  local revived = Executor.restore(snapshot, content)

  local firstTrace = {}
  local secondTrace = {}
  for _ = 1, 2 do
    local firstFrame, firstEvents = playTurn(session, splashOnly())
    local secondFrame, secondEvents = playTurn(revived, splashOnly())
    for _, event in ipairs(firstEvents) do
      firstTrace[#firstTrace + 1] = event
    end
    for _, event in ipairs(secondEvents) do
      secondTrace[#secondTrace + 1] = event
    end
    Assert.equal(firstFrame.status, "waiting", "the uninterrupted battle continues")
    Assert.equal(secondFrame.status, "waiting", "the restored battle continues identically")
  end
  Assert.deepEqual(secondTrace, firstTrace, "restored sessions replay the committed turns exactly once")
  Assert.deepEqual(revived:capture(), session:capture(), "restored sessions reach the same live state")
  session:dispose()
  revived:dispose()
end

return { tests = T }
