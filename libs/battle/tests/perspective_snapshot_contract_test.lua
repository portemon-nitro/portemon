-- Controller perspectives project detached permitted fields without
-- serializing the battle. Views never run explicit capture or snapshot
-- validation, never advance generator/outbox state, hide opposing detail,
-- and reject undeclared observers; explicit captures stay complete and
-- detached. Trusted debug reads stay a separate explicit operation.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local NATIVE_FORMAT = "test:native-perspective-format"

---@return table singles topology with reserves on both sides
local function singles()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", {
        SessionFixture.combatant(1, 11),
        SessionFixture.combatant(2, 12),
      }),
      SessionFixture.participant(2, 2, "beta", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 3),
    },
  }
end

---@param owner table module table owning the watched function
---@param name string function field under observation
---@return table watch with count/restore operations
local function watch(owner, name)
  local original = owner[name]
  assert(type(original) == "function", "watched seams stay functions")
  local calls = 0
  owner[name] = function(...)
    calls = calls + 1
    return original(...)
  end
  return {
    count = function()
      return calls
    end,
    restore = function()
      owner[name] = original
    end,
  }
end

---@param session table live headless session at its opening boundary
---@return table pending decision request owned by the controller
local function sealOneReply(session, controller)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "open battles wait for decisions")
  for _, request in ipairs(frame.request.requests) do
    if request.controller == controller then
      local choices = {}
      for _, actor in ipairs(request.actors) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local ok, replyErr = session:submit(SessionFixture.replyFor(request, choices))
      Assert.isTrue(ok, "the sealed reply is accepted")
      Assert.isNil(replyErr, "accepted replies carry no input error")
    end
  end
  return frame
end

---@param view table controller perspective under inspection
---@param activeId integer combatant identity holding the owned active slot
local function checkPerspectiveShape(view, activeId)
  Assert.keySet(
    view,
    "batch,combatants,controller,format,opponents,positions,round,ruleset,status",
    "perspectives carry exactly the permitted top-level fields"
  )
  Assert.keySet(view.batch, "epoch,id", "pending batches expose only identity")
  local owned = nil
  for _, entry in ipairs(view.combatants) do
    if entry.combatant == activeId then
      owned = entry
    else
      Assert.equal(entry.active, false, "benched reserves carry no entry")
      Assert.isNil(entry.position, "benched reserves name no position")
    end
  end
  Assert.notNil(owned, "the owned active entry is present")
  assert(owned ~= nil, "the owned active entry loads")
  Assert.keySet(
    owned,
    "activation,active,combatant,hp,mon,participant,position",
    "owned entries carry exactly the permitted fields"
  )
  Assert.isTrue(type(owned.mon) == "table", "owned roster details stay readable")
  for _, opponent in ipairs(view.opponents) do
    Assert.keySet(
      opponent,
      "combatant,hp,participant,position",
      "opponents read as public health bars only"
    )
  end
  for _, slot in ipairs(view.positions) do
    Assert.keySet(slot, "id,occupant,side", "positions expose only occupancy")
  end
end

---@param contracts table battle owners under test
---@param session table live headless session under test
---@param activeId integer combatant identity holding the owned active slot
local function checkViewsNeverSerialize(contracts, session, activeId)
  local captureWatch = watch(contracts.Snapshot, "capture")
  local validateWatch = watch(contracts.State, "validateSnapshot")
  local first = nil
  local ok, failure = pcall(function()
    first = session:view("alpha")
    checkPerspectiveShape(first, activeId)
    session:view("beta")
    session:view("alpha")
    session:view("beta")
  end)
  local captureCalls = captureWatch.count()
  local validateCalls = validateWatch.count()
  captureWatch.restore()
  validateWatch.restore()
  if not ok then
    error("perspective reads succeed: " .. tostring(failure), 0)
  end
  Assert.equal(captureCalls, 0, "ordinary views never run explicit capture")
  Assert.equal(validateCalls, 0, "ordinary views never run snapshot validation")
  assert(first ~= nil, "the first perspective loads")

  local beta = session:view("beta")
  for _, opponent in ipairs(beta.opponents) do
    Assert.isNil(opponent.mon, "opposing roster details never leak across controllers")
  end
  for _, entry in ipairs(beta.combatants) do
    Assert.isNil(entry.moves, "combatant entries carry no move lists")
  end

  local tampered = session:view("alpha")
  tampered.hp = -999
  tampered.combatants[1].hp = -999
  tampered.combatants[1].mon.condition.currentHp = -999
  tampered.extra = { injected = true }
  Assert.deepEqual(session:view("alpha"), first, "mutating a view never touches live state")

  local DomainErrors = contracts.DomainErrors
  local unknownErr = Assert.throws(function()
    session:view("ghost")
  end, "undeclared observers cannot open a perspective view")
  Assert.equal(unknownErr.code, DomainErrors.INPUT, "unknown observers fail as input errors")
end

function T.controller_views_read_without_serializing_the_battle()
  local contracts = SessionFixture.sessionContracts()
  local session = SessionFixture.newSession(contracts, SessionFixture.buildScenario(singles()))
  sealOneReply(session, "alpha")
  local before = session:capture()
  SessionFixture.assertPlainData(before, "before")

  checkViewsNeverSerialize(contracts, session, 1)

  Assert.deepEqual(session:capture(), before, "observations change no battle state")
  local debug = contracts.View.forDebug(session:capture())
  Assert.notNil(debug.participants, "trusted debug reads keep the full record")
  Assert.notNil(debug.rng, "trusted debug reads keep the generator record")
  session:dispose()
  local disposedErr = Assert.throws(function()
    session:view("alpha")
  end, "disposed sessions publish nothing further")
  Assert.equal(disposedErr.code, contracts.DomainErrors.INVALID_STATE, "disposed views fail as lifetime errors")
end

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
  NativeTypeChart.install(builder, "perspective-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "perspective-tests"
  )
  behaviors:registerFormat(NATIVE_FORMAT, { key = NATIVE_FORMAT }, "perspective-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@return table combatant seed striking with a single known move
local function tackleCombatant(id, seed)
  local entry = SessionFixture.combatant(id, seed)
  entry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return entry
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<string, unknown>> immutable move facts for the duel
local function duelMoveFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local learned = seed.mon --[[@as table<string, unknown>]]
    for _, entry in ipairs(learned.moves --[[@as table<integer, table<string, unknown>>]]) do
      if type(entry) == "table" and type(entry.move) == "string" and facts[entry.move] == nil then
        facts[entry.move] = catalog:move(entry.move)
      end
    end
  end
  return facts
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts for the duel
local function duelSpeciesFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local speciesRecord = catalog:species(species)
    local shape = catalog:form(species, form)
    local types = {}
    for _, key in ipairs(shape.types --[[@as string[] ]]) do
      types[#types + 1] = key
    end
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    bucket[form] = {
      baseStats = shape.baseStats,
      growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = types,
      levelUpMoves = shape.levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
    }
  end
  return facts
end

function T.native_controller_views_read_without_serializing_the_battle()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local alpha = tackleCombatant(1, 11)
  local beta = tackleCombatant(2, 23)
  local session = contracts.Battle.newSession({
    ruleset = Executor.RULESET,
    format = NATIVE_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alpha }),
      SessionFixture.participant(2, 2, "beta", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = 0x1BADB002 },
    formatState = {},
    moveFacts = duelMoveFacts({ alpha, beta }),
    speciesFacts = duelSpeciesFacts({ alpha, beta }),
  }, nativeContent())
  sealOneReply(session, "alpha")
  local before = session:capture()
  SessionFixture.assertPlainData(before, "before")

  checkViewsNeverSerialize(contracts, session, 1)

  Assert.deepEqual(session:capture(), before, "native observations change no battle state")
  Assert.notNil(before.trainerAi, "native captures keep their trainer record")
  Assert.notNil(before.moveFacts, "native captures keep their move facts")
  session:dispose()
end

return { tests = T }
