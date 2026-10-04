-- Revenge-law strikes double their power on source conditions read from
-- the owning turn: revenge and avalanche double when the user was struck
-- by its target earlier in the turn, assurance doubles when its target
-- already took damage, and payback doubles when its target already acted.
-- Handler probes pin the exact staged damage for doubled and plain
-- branches; native-session turns prove the turn facts thread end to end.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local T = {}

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@return table level-100 combatant seed whose health survives doubled power
local function sturdyCombatant(id, seed)
  local mon = SessionFixture.makeMon(seed, { level = 100 })
  return { id = id, mon = mon }
end

local NATIVE_SEED = 0x5EED5EED
local HANDLER_SEED = 0x0E1CE0

---@return table frozen battle content carrying the native ruleset over the real chart
local function nativeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "revenge-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "revenge-tests"
  )
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table<string, unknown> session type chart over the complete native matrix
local function nativeChart(content)
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  return assert(content:typeChart(Executor.RULESET), "the native chart resolves for the revenge probes")
end

---@param move string strike identity under the probe
---@param power integer compiled base power under the probe
---@param moveType string compiled move type under the probe
---@return table<string, unknown> compiled-shaped move facts for the probe
local function strikeFacts(move, power, moveType)
  return {
    nativeId = 1,
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

---@return table<string, table<string, unknown>> immutable move facts for the probes
local function probeMoveFacts()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  return {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
    REVENGE = strikeFacts("REVENGE", 60, "fighting"),
    AVALANCHE = strikeFacts("AVALANCHE", 60, "ice"),
    ASSURANCE = strikeFacts("ASSURANCE", 50, "dark"),
    PAYBACK = strikeFacts("PAYBACK", 50, "dark"),
  }
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the seeds
local function probeSpeciesFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    if bucket[form] == nil then
      local record = catalog:form(species, form)
      local speciesRecord = catalog:species(species)
      local types = {}
      for _, key in ipairs(record.types --[[@as string[] ]]) do
        types[#types + 1] = key
      end
      bucket[form] = {
        baseStats = record.baseStats,
        growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
        types = types,
        levelUpMoves = record.levelUpMoves,
        baseExpYield = speciesRecord.baseExpYield,
        evYield = speciesRecord.evYield,
      }
    end
  end
  return facts
end

---@param moveKey string strike identity under execution
---@param facts table<string, table<string, unknown>> compiled-shaped move facts
---@param duel table<string, unknown> turn facts under the probe
---@return table terminal execution step plus observed damage
local function runStrike(moveKey, facts, duel)
  local Execution = SessionFixture.requirePresent(
    "libs.battle.src.gen4.MoveExecution",
    "the shared move continuation owns native hit progression"
  )
  local state = SessionFixture.requirePresent("libs.battle.src.BattleState", "live battle state owns the probe")
  local contracts = SessionFixture.sessionContracts()
  local scenario = SessionFixture.buildScenario({
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "scripted", { sturdyCombatant(1, 11) }),
      SessionFixture.participant(2, 2, "scripted", { sturdyCombatant(2, 23) }),
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
  local content = nativeContent()
  local beforeFoe = ctx:damage(2, 0, { kind = "probe" }).before
  local inputs = {
    actionId = 901,
    actor = { combatant = 1 },
    requestedMove = moveKey,
    executingMove = moveKey,
    ppOwnerSlot = 0,
    selectedTarget = SessionFixture.positionTarget(2),
    targets = { { combatant = 2 } },
    moves = { { move = moveKey, pp = 10, ppUps = 0 } },
    moveFacts = facts,
    combat = { level = 20, attack = 60, defense = 55 },
    attackerTypes = { "fighting" },
    defenderTypes = { [2] = { "normal" } },
    typeChart = nativeChart(content),
    stream = BattleRng.new(HANDLER_SEED),
    duel = duel,
  }
  local node = Execution.start(inputs)
  for _ = 1, 8 do
    node = Execution.step(ctx, node)
    local record = node --[[@as table<string, unknown>]]
    if record.kind == "complete" and record.frame == nil then
      break
    end
  end
  local finished = node --[[@as table<string, unknown>]]
  assert(finished.kind == "complete" and finished.frame == nil, "the strike settles")
  return {
    outcome = finished,
    dealt = beforeFoe - ctx:damage(2, 0, { kind = "probe" }).before,
  }
end

---@return table<string, unknown> turn facts with no prior action or damage
local function freshDuel()
  return {
    foeActed = false,
    foeHurt = false,
    userHurt = false,
    revengePhysical = nil,
    revengeSpecial = nil,
  }
end

function T.revenge_doubles_after_the_target_struck_first()
  local probe = runStrike("REVENGE", probeMoveFacts(), {
    foeActed = true,
    foeHurt = false,
    userHurt = true,
    revengePhysical = { attacker = 2, amount = 40 },
    revengeSpecial = nil,
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the answered revenge connects")
  Assert.equal(probe.dealt, 82, "revenge doubles its recorded physical answer")
end

function T.revenge_holds_base_power_when_unstruck()
  local probe = runStrike("REVENGE", probeMoveFacts(), freshDuel())
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the unanswered revenge connects")
  Assert.equal(probe.dealt, 43, "revenge holds base power without an answer")
end

function T.revenge_answers_special_strikes_from_its_target()
  local probe = runStrike("REVENGE", probeMoveFacts(), {
    foeActed = true,
    foeHurt = false,
    userHurt = true,
    revengePhysical = nil,
    revengeSpecial = { attacker = 2, amount = 40 },
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the specially answered revenge connects")
  Assert.equal(probe.dealt, 82, "revenge doubles its recorded special answer")
end

function T.avalanche_doubles_after_the_target_struck_first()
  local probe = runStrike("AVALANCHE", probeMoveFacts(), {
    foeActed = true,
    foeHurt = false,
    userHurt = true,
    revengePhysical = { attacker = 2, amount = 40 },
    revengeSpecial = nil,
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the answered avalanche connects")
  Assert.equal(probe.dealt, 27, "avalanche doubles its recorded answer")
end

function T.avalanche_holds_base_power_when_unstruck()
  local probe = runStrike("AVALANCHE", probeMoveFacts(), freshDuel())
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the unanswered avalanche connects")
  Assert.equal(probe.dealt, 14, "avalanche holds base power without an answer")
end

function T.assurance_doubles_after_its_target_took_damage()
  local probe = runStrike("ASSURANCE", probeMoveFacts(), {
    foeActed = true,
    foeHurt = true,
    userHurt = false,
    revengePhysical = nil,
    revengeSpecial = nil,
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the answered assurance connects")
  Assert.equal(probe.dealt, 22, "assurance doubles against a struck target")
end

function T.assurance_holds_base_power_against_an_unstruck_target()
  local probe = runStrike("ASSURANCE", probeMoveFacts(), freshDuel())
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the unanswered assurance connects")
  Assert.equal(probe.dealt, 11, "assurance holds base power against a fresh target")
end

function T.payback_doubles_after_its_target_acted()
  local probe = runStrike("PAYBACK", probeMoveFacts(), {
    foeActed = true,
    foeHurt = false,
    userHurt = false,
    revengePhysical = nil,
    revengeSpecial = nil,
  })
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the late payback connects")
  Assert.equal(probe.dealt, 22, "payback doubles against an acted target")
end

function T.payback_holds_base_power_when_first()
  local probe = runStrike("PAYBACK", probeMoveFacts(), freshDuel())
  local outcome = probe.outcome --[[@as table<string, unknown>]]
  Assert.equal(outcome.result, "hit", "the early payback connects")
  Assert.equal(probe.dealt, 11, "payback holds base power when first")
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@param species string catalog species for the combatant
---@param level integer battle level for the underlying mon
---@param move string strike the combatant carries in its known slot
---@param pp integer power points behind the strike
---@return table combatant seed striking with the named move
local function sessionCombatant(id, seed, species, level, move, pp)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  mon.moves = { { move = move, pp = pp, ppUps = 0 } }
  return { id = id, mon = mon }
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
  error("the " .. controller .. " request stays open", 0)
end

---@param userSpecies string slow or fast user species under the turn
---@param userMove string user strike under the turn
---@param foeSpecies string opposing species under the turn
---@return table<string, unknown> turn status plus foe health around the user strike
local function sessionStrikeDealt(userSpecies, userMove, foeSpecies)
  local Battle = require("gen4.battle")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local content = nativeContent()
  local facts = probeMoveFacts()
  facts.REVENGE.priority = -4
  local alpha = sessionCombatant(1, 11, userSpecies, 20, userMove, 10)
  local beta = sessionCombatant(2, 23, foeSpecies, 20, "TACKLE", 35)
  local alphaParticipant = SessionFixture.participant(1, 1, "alpha", { alpha })
  alphaParticipant.context = {}
  local betaParticipant = SessionFixture.participant(2, 2, "beta", { beta })
  betaParticipant.context = {}
  local session = Battle.newSession({
    ruleset = Executor.RULESET,
    format = "singles",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = { alphaParticipant, betaParticipant },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = facts,
    speciesFacts = probeSpeciesFacts({ alpha, beta }),
    itemFacts = {},
  }, content)
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the turn asks for decisions")
  local alphaRequest = requestFor(opening, "alpha")
  local betaRequest = requestFor(opening, "beta")
  local alphaActor = assert(alphaRequest.actors[1], "the owning request addresses its lead")
  local betaActor = assert(betaRequest.actors[1], "the opposing request addresses its lead")
  local before = session:capture()
  local foeBefore = before.combatants[2].hp --[[@as integer]]
  local storedAlpha, alphaErr = session:submit(
    SessionFixture.replyFor(alphaRequest, {
      SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
    })
  )
  Assert.isTrue(storedAlpha, "the user strike binds: " .. tostring(alphaErr))
  local storedBeta, betaErr = session:submit(
    SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
    })
  )
  Assert.isTrue(storedBeta, "the opposing strike binds: " .. tostring(betaErr))
  local turn = session:advance(1024)
  local after = session:capture()
  local foeAfter = after.combatants[2].hp --[[@as integer]]
  session:dispose()
  return { status = turn.status, dealt = foeBefore - foeAfter, foeAfter = foeAfter }
end

function T.revenge_turn_doubles_after_the_foe_struck_first()
  -- Slow totodile answers at priority -4, so the faster eevee strike
  -- lands first and arms the doubling through the real turn ledger.
  local turn = sessionStrikeDealt("TOTODILE", "REVENGE", "EEVEE")
  Assert.equal(turn.status, "ended", "the doubled answer knocks the lone foe out")
  Assert.equal(turn.foeAfter, 0, "the foe falls to the doubled answer")
  Assert.equal(turn.dealt, 57, "the doubled answer spends the whole foe health bar")
end

function T.revenge_turn_holds_power_when_first()
  -- Fast eevee strikes before the totodile tackle, so no recorded
  -- damage arms the doubling.
  local turn = sessionStrikeDealt("EEVEE", "REVENGE", "TOTODILE")
  Assert.equal(turn.status, "waiting", "the plain answer settles back to decisions")
  Assert.equal(turn.dealt, 23, "the unanswered answer holds base power")
end

return { tests = T }
