-- Unmodeled damage semantics fail loudly through the native session: a move
-- whose handler is still gated on absent mechanics reports structured missing
-- behavior naming the move instead of settling as an ordinary failure, so
-- corpus coverage can never mistake a present handler for present semantics.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local NATIVE_SEED = 0x1BADB002
local GATED_PROBE_MOVE = "PSYCHO_BOOST"

---@return table frozen battle content carrying the native ruleset over the real chart
local function nativeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "gated-damage-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "gated-damage-tests"
  )
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@param level integer battle level for the underlying mon
---@param move string strike the combatant carries in its known slot
---@param pp integer power points behind the strike
---@return table combatant seed striking with the named move
local function strikingCombatant(id, seed, level, move, pp)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = level }))
  mon.moves = { { move = move, pp = pp, ppUps = 0 } }
  return { id = id, mon = mon }
end

---@return table<string, table<string, unknown>> immutable move facts for the gated probe
local function probeMoveFacts()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  return {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
    [GATED_PROBE_MOVE] = {
      nativeId = 354,
      name = GATED_PROBE_MOVE,
      description = "",
      effect = 0,
      category = "special",
      power = 140,
      moveType = "psychic",
      accuracy = 90,
      basePp = 5,
      effectChance = 100,
      range = 0,
      priority = 0,
      behavior = { key = "damage", params = {} },
      target = "range_0",
      flags = { dealsDamage = true, checksAccuracy = true },
    },
  }
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
---@return table<string, table<integer, table<string, unknown>>> static species facts for the seeds
local function probeSpeciesFacts(seeds)
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
    }
  end
  return facts
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

-- A strike with no modeled damage semantics reports structured missing
-- behavior through the ordinary native turn instead of settling quietly:
-- the attacking lead owns the gated move in its known slot, both sides
-- answer through the real executor, and the turn raises the missing
-- signal naming the move.
function T.unmodeled_damage_reports_missing_behavior_through_the_native_session()
  local Battle = require("gen4.battle")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local alpha = strikingCombatant(1, 11, 20, GATED_PROBE_MOVE, 10)
  local beta = strikingCombatant(2, 23, 5, "TACKLE", 35)
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
    moveFacts = probeMoveFacts(),
    speciesFacts = probeSpeciesFacts({ alpha, beta }),
    itemFacts = {},
  }, nativeContent())
  local opening = SessionFixture.driveUntilSettled(session)
  Assert.equal(opening.status, "waiting", "the probe turn asks for decisions")
  local alphaRequest = requestFor(opening, "alpha")
  local betaRequest = requestFor(opening, "beta")
  local alphaActor = assert(alphaRequest.actors[1], "the owning request addresses its lead")
  local betaActor = assert(betaRequest.actors[1], "the opposing request addresses its lead")
  local storedAlpha, alphaErr = session:submit(
    SessionFixture.replyFor(alphaRequest, {
      SessionFixture.attackChoice(alphaActor, 0, SessionFixture.positionTarget(2)),
    })
  )
  Assert.isTrue(storedAlpha, "the gated strike binds: " .. tostring(alphaErr))
  local storedBeta, betaErr = session:submit(
    SessionFixture.replyFor(betaRequest, {
      SessionFixture.attackChoice(betaActor, 0, SessionFixture.positionTarget(1)),
    })
  )
  Assert.isTrue(storedBeta, "the opposing strike binds: " .. tostring(betaErr))
  local ok, failure = pcall(function()
    return session:advance(1024)
  end)
  Assert.isFalse(ok, "the unmodeled strike reports its missing behavior instead of failing quietly")
  local record = failure --[[@as table<string, unknown>]]
  Assert.equal(record.code, "BATTLE_MISSING_BEHAVIOR", "the report carries the missing-behavior signal")
  Assert.isTrue(
    tostring(failure):find(GATED_PROBE_MOVE, 1, true) ~= nil,
    "the report names the unmodeled move"
  )
  session:dispose()
end

return { tests = T }
