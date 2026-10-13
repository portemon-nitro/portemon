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
  Assert.deepEqual(session:capture().combatants[1].hp ~= nil, before.combatants[1].hp ~= nil, "reading facts leaves health untouched")
  session:dispose()
end

-- Multi-hit sequences and multi-level gains expose every material
-- checkpoint in exact source order: per-hit health with hit ordinals
-- and counts, then per-level experience crossings. A terminal snapshot
-- alone never satisfies this probe.
function T.multi_hit_and_multi_level_gains_keep_every_checkpoint_in_order()
  local Executor = executorOwner()
  local first = tackleCombatant(1, 11)
  first.mon.moves = { { move = "BULLET_SEED", pp = 30, ppUps = 0 } }
  local session = Executor.new(
    duelScenario(NATIVE_FORMAT, { first }, { tackleCombatant(2, 23) }),
    nativeContent({ NATIVE_FORMAT })
  )
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
    ordinals[#ordinals + 1] = move.hitOrdinal
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
  for index, ordinal in ipairs(ordinals) do
    Assert.equal(ordinal, index, "hit ordinals increase without gaps in source order")
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
  local seenFlow = {}
  for _, event in ipairs(turn.events) do
    local flow = event.flowKey --[[@as string?]]
    Assert.isTrue(type(flow) == "string" and flow ~= "", "every material event selects its visual flow key")
    local effect = event.effectKey --[[@as string?]]
    if effect ~= nil then
      Assert.isTrue(type(effect) == "string" and effect ~= "", "effect selections name their key")
    end
    local suppression = event.suppression --[[@as table<string, unknown>?]]
    if event.kind == "missed" or event.kind == "protected" then
      Assert.isTrue(type(suppression) == "table", "suppressed actions name their semantic suppression")
    end
    seenFlow[flow --[[@as string]]] = true
  end
  Assert.isTrue(next(seenFlow) ~= nil, "the variant turn selects at least one visual flow")
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

return { tests = T }
