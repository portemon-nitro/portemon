-- Native ruleset sessions through the common battle entrypoint: strikes
-- run move mechanics with observable damage instead of the generic fixed
-- settlement, operation budgets only change responsiveness, terminal and
-- repeated disposal release exactly once, unbound native rulesets fail
-- before running, and snapshots resume deterministically or reject.

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
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-session-tests"
  )
  behaviors:registerFormat(NATIVE_FORMAT, { key = NATIVE_FORMAT }, "native-session-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table combatant seed striking with a single known move
local function tackleCombatant(id, seed)
  local entry = SessionFixture.combatant(id, seed)
  entry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return entry
end

---@return table combatant seed carrying no usable move entry over a real record
local function bareCombatant(id)
  local entry = SessionFixture.combatant(id, 23)
  entry.mon.moves = {}
  return entry
end

---@return table<string, table<string, unknown>> immutable move facts for the fixture strikes
local function scenarioMoveFacts()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  return {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal" },
  }
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
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
    }
  end
  return facts
end

---@return table detached native battle setup record
local function nativeScenario()
  local Executor = executorOwner()
  local alpha = tackleCombatant(1, 11)
  local beta = bareCombatant(2)
  return {
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
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts({ alpha, beta }),
  }
end

---@param request table pending decision request under test
---@return table[] one strike per addressed actor against the opposing slot
local function answer(request)
  local opposing = 2
  if request.controller == "beta" then
    opposing = 1
  end
  local choices = {}
  for _, actor in ipairs(request.actors) do
    choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(opposing))
  end
  return choices
end

---@param collected table[] emitted events under inspection
---@return integer fixed one-point strikes
---@return integer mechanic strikes dealing more than one point
local function classify(collected)
  local fixed, heavy = 0, 0
  for _, event in ipairs(collected) do
    if event.kind == "strike" then
      fixed = fixed + 1
    elseif event.kind == "struck" then
      local payload = event.payload --[[@as table<string, unknown>]]
      Assert.isTrue(type(payload.damage) == "number", "mechanic strikes report their damage")
      if
        payload.damage --[[@as integer]]
        > 1
      then
        heavy = heavy + 1
      end
    end
  end
  return fixed, heavy
end

function T.native_ruleset_strikes_run_move_mechanics_deterministically()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local first = contracts.Battle.newSession(nativeScenario(), content)
  local second = contracts.Battle.newSession(nativeScenario(), content)
  local firstEvents = SessionFixture.driveToEnd(first, 64, answer)
  local secondEvents = SessionFixture.driveToEnd(second, 64, answer)
  Assert.deepEqual(firstEvents, secondEvents, "one seed replays one event sequence")
  local fixed, heavy = classify(firstEvents)
  Assert.equal(fixed, 0, "native strikes never settle as fixed one-point strikes")
  Assert.isTrue(heavy > 0, "native strikes deal mechanic damage")
  Assert.deepEqual(first:capture(), second:capture(), "one seed replays one terminal state")
  first:dispose()
  second:dispose()
end

function T.operation_budgets_change_responsiveness_only()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local narrow = contracts.Battle.newSession(nativeScenario(), content)
  local wide = contracts.Battle.newSession(nativeScenario(), content)
  local narrowEvents = SessionFixture.driveToEnd(narrow, 1, answer)
  local wideEvents = SessionFixture.driveToEnd(wide, 64, answer)
  Assert.deepEqual(narrowEvents, wideEvents, "budgets never reorder events, actions, or draws")
  Assert.deepEqual(narrow:capture(), wide:capture(), "budgets never move terminal state")
  narrow:dispose()
  wide:dispose()
end

function T.terminal_and_repeated_disposal_release_exactly_once()
  local contracts = SessionFixture.sessionContracts()
  local content = nativeContent()
  local session = contracts.Battle.newSession(nativeScenario(), content)
  SessionFixture.driveToEnd(session, 64, answer)
  session:dispose()
  session:dispose()

  local fresh = contracts.Battle.newSession(nativeScenario(), content)
  fresh:dispose()
  fresh:dispose()
end

function T.unbound_native_bindings_fail_before_running()
  local contracts = SessionFixture.sessionContracts()
  Assert.throws(function()
    contracts.Battle.newSession(nativeScenario(), SessionFixture.makeContent())
  end, "native rulesets without a frozen binding never publish a session")
end

function T.snapshots_resume_deterministically_and_reject_garbage()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local content = nativeContent()
  local session = contracts.Battle.newSession(nativeScenario(), content)
  local waiting = SessionFixture.driveUntilSettled(session)
  Assert.equal(waiting.status, "waiting", "the first decision boundary opens")
  local snapshot = session:capture()
  SessionFixture.assertPlainData(snapshot)

  local revived = Executor.restore(snapshot, content)
  for _, live in ipairs({ session, revived }) do
    local frame = SessionFixture.driveUntilSettled(live)
    Assert.equal(frame.status, "waiting", "restored sessions reopen the same boundary")
    for _, request in ipairs(frame.request.requests) do
      local ok, replyErr = live:submit(SessionFixture.replyFor(request, answer(request)))
      Assert.isTrue(ok, "restored sessions accept the open replies")
      Assert.isNil(replyErr, "accepted replies carry no input error")
    end
  end
  local firstEvents = SessionFixture.driveToEnd(session, 16, answer)
  local secondEvents = SessionFixture.driveToEnd(revived, 16, answer)
  Assert.deepEqual(firstEvents, secondEvents, "restored sessions replay the same events")
  Assert.deepEqual(session:capture(), revived:capture(), "restored sessions reach the same state")
  session:dispose()
  revived:dispose()

  Assert.throws(function()
    Executor.restore({ version = 1 }, content)
  end, "malformed captures reject instead of resuming")
  snapshot.schedule = { kind = "other:schedule", version = 1, cursor = "opening", pendingFaints = {} }
  Assert.throws(function()
    Executor.restore(snapshot, content)
  end, "foreign schedule frames reject instead of resuming")
end

return { tests = T }
