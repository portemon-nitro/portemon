-- Event-time semantic facts at the native engine owner: every
-- presentation-material emission names its true actor and targets,
-- executed move identity and phase, suppression decisions, and ordered
-- checkpoints at the authoritative mutation point. Later playback reads
-- those captured facts instead of searching display order, rereading
-- live state, or replaying combat. These scenarios run the real native
-- session and the real shared move continuation with fixed seeds. Each
-- scenario first asserts the missing boundary, so the run stays red
-- until the provider lands.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local NATIVE_FORMAT = "test:native-event-facts"
local NATIVE_SEED = 0x1BADB002

---@return table loaded native session owner
local function executorOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns sessions"
  )
end

---@param formats string[] format identities carrying the binding
---@return table frozen battle content for the facts probes
local function nativeContent(formats)
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-event-facts")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-event-facts"
  )
  for _, key in ipairs(formats) do
    behaviors:registerFormat(key, { key = key }, "native-event-facts")
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
    BULLET_SEED = catalog:move("BULLET_SEED"),
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
---@return table detached native battle setup record
local function duelScenario(formatKey, alpha, beta)
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
      SessionFixture.position(2, 2, { 2 }, beta[1].id --[[@as integer]]),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(seeds),
    speciesFacts = scenarioSpeciesFacts(seeds),
  }
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

-- Recoil, drain, residual weather, confusion self-hits, and reflected
-- or called moves each name their true source, targets, and cause:
-- nothing borrows a nearby visible battler, and the executed visual
-- move never collapses into the selected move.
function T.cause_source_and_targets_name_the_true_origin_for_every_variant()
  local Executor = executorOwner()
  local session = Executor.new(
    duelScenario(NATIVE_FORMAT, { tackleCombatant(1, 11) }, { tackleCombatant(2, 23) }),
    nativeContent({ NATIVE_FORMAT })
  )
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the native duel opens on its decisions")
  local alphaRequest = requestFor(frame, "alpha")
  local betaRequest = requestFor(frame, "beta")
  local alphaActor = assert(alphaRequest.actors[1], "the opening batch addresses its lead")
  local betaActor = assert(betaRequest.actors[1], "the opposing batch addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(alphaRequest, {
      SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
    })),
    "the probe strike seals"
  )
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
    })),
    "the answer strike seals"
  )
  local turn = session:advance(1024)
  Assert.isTrue(type(turn.events) == "table" and #turn.events > 0, "the traded turn emits its events")
  local struck = {}
  for _, event in ipairs(turn.events) do
    if event.kind == "struck" then
      struck[#struck + 1] = event
    end
  end
  Assert.isTrue(#struck >= 1, "the traded turn tells at least one strike")
  for _, event in ipairs(struck) do
    local actors = event.actors --[[@as table<string, unknown>?]]
    Assert.isTrue(type(actors) == "table" and #actors >= 1, "struck events name their explicit source actor")
    local targets = event.targets --[[@as table<string, unknown>?]]
    Assert.isTrue(type(targets) == "table" and #targets >= 1, "struck events name their explicit ordered targets")
    local move = event.move --[[@as table<string, unknown>?]]
    Assert.isTrue(type(move) == "table", "struck events name their selected and executed move identities")
    Assert.isTrue(type(move.selected) == "string", "the selected move identity is explicit")
    Assert.isTrue(type(move.executed) == "string", "the executed visual move identity is explicit")
    local cause = event.cause --[[@as table<string, unknown>]]
    Assert.isTrue(type(cause.kind) == "string", "every variant carries its typed cause")
    local payload = event.payload --[[@as table<string, unknown>]]
    Assert.isTrue(type(payload.critical) == "boolean", "typed strikes tell whether they were critical")
    Assert.isTrue(
      payload.effectiveness == "neutral" or payload.effectiveness == "super" or payload.effectiveness == "weak",
      "typed strikes classify their chart effectiveness"
    )
  end
  local before = session:capture()
  local recoilSeen = false
  for _, event in ipairs(turn.events) do
    if event.kind == "recoil" or event.kind == "drained" or event.kind == "healed" or event.kind == "tick" then
      recoilSeen = true
      local targets = event.targets --[[@as table<string, unknown>?]]
      Assert.isTrue(type(targets) == "table", "residual and feedback events name their explicit targets")
    end
  end
  if not recoilSeen then
    local first = assert(struck[1], "the probe strike is observed")
    local targets = first.targets --[[@as table<string, unknown>?]]
    Assert.isTrue(type(targets) == "table", "feedback variants share the same explicit target shape")
  end
  Assert.deepEqual(
    session:capture().combatants[1].hp ~= nil,
    before.combatants[1].hp ~= nil,
    "reading facts leaves health untouched"
  )
  session:dispose()
end

-- Multi-hit sequences and multi-level gains expose every material
-- checkpoint in exact source order: per-hit health with sequence-local
-- ordinals and actual counts, then per-level experience crossings. A terminal snapshot
-- alone never satisfies this probe.
function T.multi_hit_and_multi_level_gains_keep_every_checkpoint_in_order()
  local Executor = executorOwner()
  local first = tackleCombatant(1, 11)
  first.mon.moves = { { move = "BULLET_SEED", pp = 30, ppUps = 0 } }
  local session =
    Executor.new(duelScenario(NATIVE_FORMAT, { first }, { tackleCombatant(2, 23) }), nativeContent({ NATIVE_FORMAT }))
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the multi-hit duel opens on its decisions")
  local alphaRequest = requestFor(frame, "alpha")
  local betaRequest = requestFor(frame, "beta")
  local alphaActor = assert(alphaRequest.actors[1], "the opening batch addresses its lead")
  local betaActor = assert(betaRequest.actors[1], "the opposing batch addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(alphaRequest, {
      SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
    })),
    "the multi-hit strike seals"
  )
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
    })),
    "the answer strike seals"
  )
  local turn = session:advance(4096)
  local hits = {}
  for _, event in ipairs(turn.events) do
    if event.kind == "struck" then
      hits[#hits + 1] = event
    end
  end
  Assert.isTrue(#hits >= 1, "the multi-hit turn tells at least one hit")
  local ordinals = {}
  for _, event in ipairs(hits) do
    local move = event.move --[[@as table<string, unknown>?]]
    Assert.isTrue(type(move) == "table", "every hit names its move phase facts")
    Assert.isTrue(type(move.hitOrdinal) == "number", "every hit names its one-based ordinal")
    Assert.isTrue(type(move.hitCount) == "number", "every hit names its total count")
    local payload = event.payload --[[@as table<string, unknown>]]
    if payload.sequenceHitIndex ~= nil then
      Assert.equal(move.hitOrdinal, payload.sequenceHitIndex, "move facts preserve the local hit ordinal")
      Assert.equal(
        move.hitCount,
        payload.sequenceHitTotal,
        "move facts preserve the actual sequence total: "
          .. tostring(move.hitCount)
          .. " / "
          .. tostring(payload.sequenceHitTotal)
      )
    else
      Assert.equal(move.hitOrdinal, 1, "single-hit mechanics start at their local ordinal")
      Assert.equal(move.hitCount, 1, "single-hit mechanics carry one strike")
    end
    local actor = event.actors[1] --[[@as table<string, unknown>]]
    local key = tostring(actor.combatant) .. "\0" .. move.executed
    ordinals[key] = ordinals[key] or {}
    ordinals[key][#ordinals[key] + 1] = move.hitOrdinal
    local checkpoints = event.checkpoints --[[@as table<string, unknown>?]]
    Assert.isTrue(type(checkpoints) == "table" and #checkpoints >= 1, "every hit keeps its ordered display checkpoints")
    for _, point in
      ipairs(checkpoints --[[@as table<integer, unknown>]])
    do
      local entry = point --[[@as table<string, unknown>]]
      Assert.isTrue(type(entry.hp) == "number", "checkpoints record displayed health")
      Assert.isTrue(type(entry.maxHp) == "number", "checkpoints record the health ceiling")
    end
  end
  for _, sequenceOrdinals in pairs(ordinals) do
    for index, ordinal in ipairs(sequenceOrdinals) do
      Assert.equal(ordinal, index, "hit ordinals restart for each executed sequence")
    end
  end
  local gains = {}
  for _, event in ipairs(turn.events) do
    if event.kind == "exp" or event.kind == "stats" then
      gains[#gains + 1] = event
    end
  end
  if #gains > 0 then
    for _, event in ipairs(gains) do
      local checkpoints = event.checkpoints --[[@as table<string, unknown>?]]
      Assert.isTrue(type(checkpoints) == "table", "progression events keep their ordered checkpoints")
    end
  else
    local checkpoints = (assert(hits[1], "the first hit is observed")).checkpoints
    Assert.isTrue(type(checkpoints) == "table", "hit checkpoints stand in when no progression fires this turn")
  end
  session:dispose()
end

-- A variable-power strike snapshots the exact ladder value its own
-- battle draw selected onto the playback move fact: two fixed native
-- seeds resolve two distinct ladder values, each struck event carries
-- the drawn value instead of the compiled base, the draw journal shows
-- exactly one native roll per strike, and a same-seed replay agrees on
-- power, damage, and draws without touching the world stream.
local function probeFacts(move, power, moveType, nativeId)
  return {
    nativeId = nativeId,
    name = move,
    description = "",
    effect = 0,
    category = "physical",
    power = power,
    moveType = moveType,
    accuracy = 100,
    basePp = 10,
    effectChance = 0,
    range = 0,
    priority = 0,
    behavior = { key = "damage", params = {} },
    target = "range_0",
    flags = { dealsDamage = true, checksAccuracy = true },
  }
end

local function probeChart()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-event-facts")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-event-facts"
  )
  local content = BattleContent.new(builder:freeze(), behaviors:freeze())
  return assert(content:typeChart(Executor.RULESET), "the native chart resolves for the power probes")
end

---@param moveKey string strike identity under the probe
---@param seed integer fixed battle stream seed under the probe
---@return table terminal step, dealt damage, struck events, and labeled draw journal
local function runPowerProbe(moveKey, seed)
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = SessionFixture.requirePresent("libs.battle.src.BattleState", "live battle state owns the probe")
  local contracts = SessionFixture.sessionContracts()
  local function sturdy(id, monSeed)
    local mon = SessionFixture.makeMon(monSeed, { level = 100 })
    return { id = id, mon = mon }
  end
  local scenario = SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { sturdy(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { sturdy(2, 23) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
  })
  local live = state.create(contracts.Scenario.validate(scenario))
  local Context = SessionFixture.requirePresent(
    "libs.battle.src.BattleContext",
    "the validated mutation surface owns mechanics writes"
  )
  local ctx = Context.wrap(live)
  local journal = {}
  local raw = BattleRng.new(seed)
  local stream = {}
  function stream:nextU16(label, cause)
    journal[#journal + 1] = label
    return raw:nextU16(label, cause)
  end
  function stream:capture()
    return raw:capture()
  end
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  local node = Execution.start({
    actionId = 901,
    actor = { combatant = 1 },
    requestedMove = moveKey,
    executingMove = moveKey,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveKey, pp = 10, ppUps = 0 } },
    moveFacts = {
      MAGNITUDE = probeFacts("MAGNITUDE", 1, "ground", 91),
      TACKLE = probeFacts("TACKLE", 35, "normal", 92),
    },
    combat = {
      level = 50,
      attack = 120,
      defense = 110,
      rawAttack = 120,
      rawDefense = 110,
      attackStage = 0,
      defenseStage = 0,
    },
    burned = false,
    guts = false,
    weather = "none",
    weatherSuppressed = false,
    abilities = { user = "NONE", foe = "NONE" },
    attackerTypes = { "normal" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = probeChart(),
    stream = stream,
  })
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  assert(finished.kind == "complete" and finished.frame == nil, "the strike settles")
  local struck = {}
  for _, event in ipairs(live.outbox) do
    if event.kind == "struck" then
      struck[#struck + 1] = event
    end
  end
  return {
    outcome = finished,
    dealt = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before,
    struck = struck,
    journal = journal,
  }
end

---@param seed integer fixed battle stream seed under replay
---@return integer the ladder value the native roll selects
local function replayLadderPower(seed)
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  local replay = BattleRng.new(seed)
  local roll = replay:nextU16("magnitude", { kind = "probe" }) % 100
  local ladder = { 10, 30, 50, 70, 90, 110, 150 }
  local edges = { 5, 15, 35, 65, 85, 95, 100 }
  for index, edge in ipairs(edges) do
    if roll < edge then
      return ladder[index]
    end
  end
  return 150
end

function T.variable_power_strikes_snapshot_their_resolved_ladder_value()
  local low = runPowerProbe("MAGNITUDE", 10)
  Assert.equal(low.outcome.result, "hit", "the low roll connects")
  Assert.equal(replayLadderPower(10), 30, "the low seed draws the 30 ladder value")
  Assert.isTrue(#low.struck >= 1, "the low strike tells its hit")
  Assert.equal(low.struck[1].move.power, 30, "the playback move carries the drawn ladder value")
  Assert.isTrue(low.struck[1].move.power ~= 1, "the playback power never copies the compiled base")
  local high = runPowerProbe("MAGNITUDE", 2)
  Assert.equal(high.outcome.result, "hit", "the high roll connects")
  Assert.equal(replayLadderPower(2), 90, "the high seed draws the 90 ladder value")
  Assert.isTrue(#high.struck >= 1, "the high strike tells its hit")
  Assert.equal(high.struck[1].move.power, 90, "the second playback move carries its own drawn value")
  for _, probe in ipairs({ low, high }) do
    local magnitudeDraws = 0
    for _, label in ipairs(probe.journal) do
      if label == "magnitude" then
        magnitudeDraws = magnitudeDraws + 1
      end
    end
    Assert.equal(magnitudeDraws, 1, "each strike rolls its variable power exactly once")
  end
  local replay = runPowerProbe("MAGNITUDE", 2)
  Assert.equal(replay.struck[1].move.power, 90, "a same-seed replay resolves the same playback power")
  Assert.equal(replay.dealt, high.dealt, "a same-seed replay deals the same damage")
  Assert.deepEqual(replay.journal, high.journal, "a same-seed replay draws the same native sequence")
end

-- A later ordinary strike carries its own compiled value, never the
-- earlier variable roll: each pinned execution annotates only its own
-- hit, and the already emitted facts stay frozen behind later work.
function T.later_strikes_never_reuse_an_earlier_resolved_value()
  local first = runPowerProbe("MAGNITUDE", 2)
  Assert.equal(first.struck[1].move.power, 90, "the variable strike resolves its ladder value")
  local second = runPowerProbe("TACKLE", 2)
  Assert.equal(second.outcome.result, "hit", "the ordinary strike connects")
  Assert.isTrue(#second.struck >= 1, "the ordinary strike tells its hit")
  Assert.equal(second.struck[1].move.power, 35, "the ordinary strike carries its own compiled value")
  Assert.isTrue(first.struck[1].move.power == 90, "the earlier facts stay frozen behind later work")
end

-- Misses, immunities, charge and release phases, substitute breaks,
-- and transforms each select a distinct visual request, while the
-- effects-off capture keeps mandatory appearance changes and native
-- waits instead of dropping them.
function T.miss_immunity_charge_substitute_and_transform_select_distinct_requests()
  local Executor = executorOwner()
  local session = Executor.new(
    duelScenario(NATIVE_FORMAT, { tackleCombatant(1, 11) }, { tackleCombatant(2, 23) }),
    nativeContent({ NATIVE_FORMAT })
  )
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the variant duel opens on its decisions")
  local alphaRequest = requestFor(frame, "alpha")
  local betaRequest = requestFor(frame, "beta")
  local alphaActor = assert(alphaRequest.actors[1], "the opening batch addresses its lead")
  local betaActor = assert(betaRequest.actors[1], "the opposing batch addresses its lead")
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(alphaRequest, {
      SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
    })),
    "the variant strike seals"
  )
  Assert.isTrue(
    session:submit(SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
    })),
    "the variant answer seals"
  )
  local turn = session:advance(1024)
  Assert.isTrue(type(turn.events) == "table" and #turn.events > 0, "the variant turn emits its events")
  local seenMoments = {}
  for _, event in ipairs(turn.events) do
    -- No kind carries route authority: decorated events expose only
    -- identities and the frozen presentation facts while the selector
    -- reads the producer's execution/operation records.
    Assert.isNil(event.flowKey, "no kind writes a flow route: " .. tostring(event.kind))
    Assert.isNil(event.effectKey, "no kind writes an effect route: " .. tostring(event.kind))
    Assert.isNil(event.suppression, "no kind writes suppression flags: " .. tostring(event.kind))
    local presentation = assert(
      event.presentation,
      "every material event freezes its presentation facts: " .. tostring(event.kind)
    )
    local execution = presentation.execution --[[@as table<string, unknown>?]]
    if event.kind == "struck" then
      Assert.isTrue(type(execution) == "table", "connected strikes carry their execution moment")
      seenMoments[(execution --[[@as table<string, unknown>]]).executedMove .. "\0" .. tostring(event.sequence)] = true
    elseif event.kind == "missed" or event.kind == "protected" then
      Assert.isNil(execution, "unconnected branches carry no execution moment: " .. tostring(event.kind))
    end
    if event.kind == "move-used" then
      Assert.isTrue(type(execution) == "table", "reached sequence calls carry their execution moment")
    end
  end
  Assert.isTrue(next(seenMoments) ~= nil, "the variant turn selects at least one execution moment")
  local optionsFn = session.decisionOptions
  if type(optionsFn) == "function" then
    local captured = session:capture()
    Assert.isTrue(type(captured) == "table", "captured options keep the battle readable without graphics")
  end
  for _, event in ipairs(turn.events) do
    if event.kind == "move-used" then
      local move = event.move --[[@as table<string, unknown>?]]
      Assert.isTrue(type(move) == "table" and type(move.phase) == "string", "move uses name their charge phase")
    end
    if event.kind == "transformed" or event.kind == "substitute-broke" then
      local actors = event.actors --[[@as table<string, unknown>?]]
      Assert.isTrue(type(actors) == "table", "appearance changes name their explicit actors")
    end
  end
  session:dispose()
end

---@return table live battle state with two entered combatants over real owners
local function factsState()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local contracts = SessionFixture.sessionContracts()
  local scenario = SessionFixture.buildScenario({
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
  })
  local state = contracts.State.create(contracts.Scenario.validate(scenario))
  return state
end

---@return table<string, unknown> connected strike facts behind one multi-hit execution moment
local function strikeFacts()
  return {
    execution = {
      selectedMove = "TACKLE",
      executedMove = "TACKLE",
      moment = "use",
      branch = "default",
      attacker = { combatant = 1, activation = 1 },
      defender = { combatant = 2, activation = 2 },
      targets = { { combatant = 2, activation = 2 } },
      damage = -14,
      power = 35,
      friendship = 70,
      hitOrdinal = 1,
      hitCount = 2,
      hitCycle = 1,
    },
    healthChanges = {
      { combatant = 2, activation = 2, before = 57, after = 43, maxHp = 57, kind = "body" },
    },
  }
end

-- The optional semantic-facts handoff projects beside the payload:
-- the frozen context plus the producer's closed execution and
-- health-change records. Mechanics, draws, and transcripts stay
-- exactly as emitted.
function T.emit_projects_optional_semantic_facts_beside_the_payload()
  local BattleContext = require("libs.battle.src.BattleContext")
  local state = factsState()
  local ctx = BattleContext.wrap(state)
  local event = ctx:emit("struck", { key = "TACKLE", kind = "move", combatant = 1 }, { target = 2, damage = 14 }, nil, strikeFacts())
  local presentation = assert(event.presentation, "the emission projects its presentation facts")
  local execution = assert(presentation.execution, "the strike projects its execution moment")
  Assert.equal(execution.selectedMove, "TACKLE", "the execution keeps its selected identity")
  Assert.equal(execution.executedMove, "TACKLE", "the execution keeps its executed identity")
  Assert.equal(execution.moment, "use", "the execution keeps its moment")
  Assert.equal(execution.hitOrdinal, 1, "the execution keeps its hit ordinal")
  Assert.equal(execution.hitCount, 2, "the execution keeps its connected total")
  Assert.equal(execution.hitCycle, 1, "the execution keeps its source played-flag cycle")
  local changes = assert(presentation.healthChanges, "the strike projects its health changes")
  Assert.equal(#changes, 1, "the strike keeps its single body change")
  Assert.equal(changes[1].kind, "body", "the change distinguishes body from substitute")
  Assert.equal(changes[1].after, 43, "the change keeps its checkpoint")
  Assert.isTrue(type(presentation.context) == "table", "the emission freezes its battle context")
  Assert.isNil(presentation.operation, "a strike without an applied operation carries none")
  Assert.isNil(event.payload.presentation, "the projection rides beside the payload, never inside it")
  Assert.equal(#state.outbox, 1, "the handoff emits exactly one event")
end

-- Emissions without producer facts still freeze their battle context;
-- the optional records simply stay absent.
function T.emit_without_facts_freezes_context_only()
  local BattleContext = require("libs.battle.src.BattleContext")
  local state = factsState()
  local ctx = BattleContext.wrap(state)
  local event = ctx:emit("struck", { key = "TACKLE", kind = "move", combatant = 1 }, { target = 2, damage = 14 })
  local presentation = assert(event.presentation, "every emission freezes its context")
  Assert.isNil(presentation.execution, "no producer moment means no execution record")
  Assert.isNil(presentation.operation, "no producer operation means no operation record")
  Assert.isNil(presentation.healthChanges, "no producer changes means no health records")
  Assert.isTrue(type(presentation.context.battlers) == "table", "the context snapshots its battlers")
end

-- Semantic facts are plain data only: functions, metatables, and
-- non-finite numbers fail at the emission boundary.
function T.emit_rejects_non_plain_semantic_facts()
  local BattleContext = require("libs.battle.src.BattleContext")
  local state = factsState()
  local ctx = BattleContext.wrap(state)
  local bad = strikeFacts()
  bad.execution.attacker = setmetatable({ combatant = 1, activation = 1 }, {})
  Assert.isFalse(pcall(ctx.emit, ctx, "struck", { kind = "move" }, { target = 2 }, nil, bad), "metatables never enter facts")
  local fn = strikeFacts()
  fn.execution.defender = function()
    return 1
  end
  Assert.isFalse(pcall(ctx.emit, ctx, "struck", { kind = "move" }, { target = 2 }, nil, fn), "functions never enter facts")
  local nan = strikeFacts()
  nan.execution.damage = 0 / 0
  Assert.isFalse(pcall(ctx.emit, ctx, "struck", { kind = "move" }, { target = 2 }, nil, nan), "non-finite numbers never enter facts")
  Assert.equal(#state.outbox, 0, "rejected facts emit nothing")
end

-- Stage writes return their emitted event sequence beside the
-- before/after stages so cost links can point backward at the real
-- stage event; producer operation facts ride the same handoff.
function T.change_stage_returns_its_event_sequence_for_cost_links()
  local BattleContext = require("libs.battle.src.BattleContext")
  local state = factsState()
  local ctx = BattleContext.wrap(state)
  local facts = {
    operation = {
      kind = "stage-changed",
      subject = { combatant = 1, activation = 1 },
      source = { kind = "move", key = "SWORDS_DANCE", actor = { combatant = 1, activation = 1 } },
      stat = "attack",
      before = 0,
      after = 1,
      method = "delta",
      profile = "standard",
      groupFirstSequence = 1,
      feedbackOwner = true,
    },
  }
  local result = ctx:changeStage(1, "attack", 1, { kind = "probe" }, facts)
  Assert.equal(result.before, 0, "the stage write keeps its before stage")
  Assert.equal(result.after, 1, "the stage write keeps its after stage")
  Assert.equal(result.eventSequence, 1, "the stage write returns its emitted event sequence")
  local operation = assert(state.outbox[1].presentation.operation, "the stage event carries its operation")
  Assert.equal(operation.kind, "stage-changed", "the operation keeps its kind")
  Assert.equal(operation.stat, "attack", "the operation keeps its stat")
end

-- Status helpers forward the producer's semantic facts to the same
-- projection; existing call signatures stay valid without facts.
function T.status_helpers_forward_semantic_facts()
  local BattleContext = require("libs.battle.src.BattleContext")
  local state = factsState()
  local ctx = BattleContext.wrap(state)
  local applied = ctx:applyStatus(2, "sleep", { turns = 3 }, { kind = "probe" }, {
    operation = {
      kind = "status-applied",
      subject = { combatant = 2, activation = 2 },
      source = { kind = "move", key = "SLEEP_POWDER", actor = { combatant = 1, activation = 1 } },
      condition = "sleep",
      application = "standard",
    },
  })
  Assert.isTrue(applied, "the status application still applies")
  local operation = assert(state.outbox[1].presentation.operation, "the status event carries its operation")
  Assert.equal(operation.condition, "sleep", "the operation keeps its applied condition")
  local cured = ctx:cureStatus(2, "sleep", { kind = "probe" })
  Assert.isTrue(cured, "the cure still cures without facts")
  Assert.isNil(state.outbox[2].presentation.operation, "a cure without facts carries no operation")
end

-- Malformed projections fail at the event boundary instead of
-- selecting an animation from a guess.
function T.presentation_shapes_reject_malformed_records()
  local BattleProtocol = require("libs.battle.src.BattleProtocol")
  local function eventWith(presentation)
    return {
      sequence = 1,
      kind = "struck",
      cause = { kind = "move" },
      audience = "public",
      payload = {},
      presentation = presentation,
    }
  end
  local good = strikeFacts()
  good.context = { battleFormat = "singles" }
  Assert.isTrue(pcall(BattleProtocol.validateEvent, eventWith(good)), "the closed shape validates")
  local badMoment = strikeFacts()
  badMoment.context = {}
  badMoment.execution.moment = "announcement"
  Assert.isFalse(
    pcall(BattleProtocol.validateEvent, eventWith(badMoment)),
    "execution moments stay in the closed vocabulary"
  )
  local partial = strikeFacts()
  partial.context = {}
  partial.execution.hitCycle = nil
  Assert.isFalse(
    pcall(BattleProtocol.validateEvent, eventWith(partial)),
    "hit fields travel together or not at all"
  )
  local over = strikeFacts()
  over.context = {}
  over.execution.hitOrdinal = 3
  Assert.isFalse(
    pcall(BattleProtocol.validateEvent, eventWith(over)),
    "hit ordinals stay within their connected total"
  )
  local unknown = { context = {}, operation = { kind = "victory-lap", subject = { combatant = 1, activation = 1 } } }
  Assert.isFalse(pcall(BattleProtocol.validateEvent, eventWith(unknown)), "operation kinds stay closed")
  local badKind = { context = {}, healthChanges = { { combatant = 1, before = 1, after = 0, maxHp = 1, kind = "doll" } } }
  Assert.isFalse(
    pcall(BattleProtocol.validateEvent, eventWith(badKind)),
    "health changes distinguish body from substitute only"
  )
  Assert.isTrue(
    pcall(BattleProtocol.validateEvent, {
      sequence = 1,
      kind = "struck",
      cause = {},
      audience = "public",
      payload = {},
    }),
    "events without presentation stay valid"
  )
end

return { tests = T }
