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
  local beta = movesetCombatant(2, 31, { moveSlot("QUICK_ATTACK", 30) })
  local session = contracts.Battle.newSession(duelScenario({ alpha, beta }, {}, {}), content)

  local _, opening = playTurn(session, strikeAnswer({
    alpha = { slot = 1, target = SessionFixture.positionTarget(2) },
    beta = { slot = 0, target = SessionFixture.positionTarget(1) },
  }))
  Assert.deepEqual(
    strikeKeys(opening),
    { "QUICK_ATTACK", "TACKLE" },
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
    { "TACKLE", "QUICK_ATTACK" },
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

return { tests = T }
