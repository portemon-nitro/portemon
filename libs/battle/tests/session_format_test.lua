-- Session format resolution: unknown format keys fail closed at
-- construction with a typed error naming the key, while registered custom
-- formats resolve through their own registered policy. Native keys
-- additionally validate their topology before anything runs: a mismatched
-- layout never falls back to a default vocabulary.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table contracts keyed by owner name
local function contracts()
  return SessionFixture.sessionContracts()
end

---@param formatKey string custom format identity under registration
---@param actionKinds string[]? admitted vocabulary the registration carries
---@return table frozen battle content carrying the scripted ruleset and the custom format
local function contentWithFormat(formatKey, actionKinds)
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    SessionFixture.RULESET,
    { key = SessionFixture.RULESET, chart = SessionFixture.RULESET },
    "format-tests"
  )
  local definition = { key = formatKey, chart = SessionFixture.RULESET }
  if actionKinds ~= nil then
    definition.actionKinds = actionKinds
  end
  behaviors:registerFormat(formatKey, definition, "format-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param parts table scenario topology parts
---@param formatKey string format identity the scenario carries
---@return table detached battle setup record
local function scenarioWithFormat(parts, formatKey)
  local scenario = SessionFixture.buildScenario(parts)
  scenario.format = formatKey
  return scenario
end

---@return table scenario parts for a one-active-per-side lineup
local function singlesParts()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { SessionFixture.combatant(1, 11) }),
      SessionFixture.participant(2, 2, "beta", { SessionFixture.combatant(2, 22) }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
  }
end

---@return table scenario parts for a two-active-per-side lineup
local function doublesParts()
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
      SessionFixture.position(2, 1, { 1 }, 2),
      SessionFixture.position(3, 2, { 2 }, 3),
      SessionFixture.position(4, 2, { 2 }, 4),
    },
  }
end

---@param err unknown construction failure under inspection
---@param key string format identity the failure must name
local function failureNamesKey(err, key)
  local Errors = require("libs.errors.src.Errors")
  local BattleErrors = require("libs.battle.src.errors")
  Assert.isTrue(Errors.is(err), "construction fails with a typed error instead of running")
  local failure = err --[[@as table<string, unknown>]]
  Assert.equal(
    failure.code,
    BattleErrors.MISSING_BEHAVIOR,
    "an unknown format is missing behavior, not a rejected reply"
  )
  local message = tostring(failure.message)
  local context = failure.context --[[@as table<string, unknown>]]
  Assert.isTrue(
    message:find(key, 1, true) ~= nil or tostring(context.format):find(key, 1, true) ~= nil,
    "the failure names the unknown format"
  )
end

function T.unknown_bare_format_key_fails_at_construction_naming_the_key()
  local owned = contracts()
  local scenario = scenarioWithFormat(singlesParts(), "singels")
  local content = SessionFixture.makeContent()
  local ok, err = pcall(owned.Battle.newSession, scenario, content)
  Assert.isFalse(ok, "a misspelled native format never runs on a default vocabulary")
  failureNamesKey(err, "singels")
end

function T.unregistered_namespaced_format_key_fails_at_construction_naming_the_key()
  local owned = contracts()
  local scenario = scenarioWithFormat(singlesParts(), "glimmer:unregistered")
  local content = SessionFixture.makeContent()
  local ok, err = pcall(owned.Battle.newSession, scenario, content)
  Assert.isFalse(ok, "an unregistered custom format never runs silently")
  failureNamesKey(err, "glimmer:unregistered")
end

function T.registered_custom_format_resolves_through_its_own_policy()
  local owned = contracts()
  local scenario = scenarioWithFormat(singlesParts(), "glimmer:skirmish")
  local content = contentWithFormat("glimmer:skirmish", { "attack", "confirm" })
  local session = owned.Battle.newSession(scenario, content)
  Assert.notNil(session, "a registered custom format constructs its session")
  local frame = session:advance(1024)
  Assert.equal(frame.status, "waiting", "the custom session waits for decisions")
  local batch = assert(frame.request, "the waiting frame carries its batch")
  for _, request in ipairs(batch.requests) do
    Assert.deepEqual(
      request.legalChoices.kinds,
      { "attack", "confirm" },
      "decisions admit exactly the registered custom vocabulary"
    )
  end
  session:dispose()
end

function T.registered_custom_format_without_a_vocabulary_runs_the_standard_kinds()
  local owned = contracts()
  local scenario = scenarioWithFormat(singlesParts(), "glimmer:open")
  local content = contentWithFormat("glimmer:open", nil)
  local session = owned.Battle.newSession(scenario, content)
  Assert.notNil(session, "a registered custom format without admitted kinds still constructs")
  local frame = session:advance(1024)
  Assert.equal(frame.status, "waiting", "the custom session waits for decisions")
  local batch = assert(frame.request, "the waiting frame carries its batch")
  for _, request in ipairs(batch.requests) do
    Assert.deepEqual(
      request.legalChoices.kinds,
      { "attack", "switch", "confirm", "item" },
      "an unadorned custom registration runs the standard vocabulary"
    )
  end
  session:dispose()
end

---@return table frozen battle content carrying the native ruleset binding for parity checks
local function parityNativeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "parity-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "parity-tests"
  )
  behaviors:registerFormat("parity:native", { key = "parity:native" }, "parity-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table detached native battle setup record with two striking leads
local function parityNativeScenario()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local catalog = CatalogFixture.makeCatalog()
  local seeds = { SessionFixture.combatant(1, 11), SessionFixture.combatant(2, 23) }
  for _, seed in ipairs(seeds) do
    seed.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  end
  local moveFacts = {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
  local speciesFacts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local speciesRecord = catalog:species(species)
    local formRecord = catalog:form(species, form)
    local types = {} ---@type string[]
    for _, key in ipairs(formRecord.types --[[@as string[] ]]) do
      types[#types + 1] = key --[[@as string]]
    end
    local bucket = speciesFacts[species]
    if bucket == nil then
      bucket = {}
      speciesFacts[species] = bucket
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
  return {
    ruleset = Executor.RULESET,
    format = "parity:native",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { seeds[1] }),
      SessionFixture.participant(2, 2, "beta", { seeds[2] }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = 0x1BADB002 },
    formatState = {},
    moveFacts = moveFacts,
    speciesFacts = speciesFacts,
  }
end

---@param value unknown plain value under detachment
---@return unknown detached copy of the value
local function copyPlain(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value --[[@as table<unknown, unknown>]]) do
    out[copyPlain(key)] = copyPlain(item)
  end
  return out
end

-- Both executors admit waiting snapshots through the same continuation
-- contract: unknown frame kinds and kind-mismatched frame states reject
-- as incompatible snapshots, unknown content rejects as missing
-- behavior, and valid captures restore with identical batches, drain the
-- same outbox exactly once, and refuse a duplicate reply.
function T.waiting_continuation_frames_reject_malformed_shapes_in_both_executors()
  local owned = contracts()
  local Errors = require("libs.errors.src.Errors")
  local BattleErrors = require("libs.battle.src.errors")
  local Executor = require("libs.battle.src.gen4.HgssSessionExecutor")
  local scriptedContent = SessionFixture.makeContent()
  local nativeContentValue = parityNativeContent()
  local cases = {
    {
      name = "scripted",
      scenario = SessionFixture.buildScenario(singlesParts()),
      content = scriptedContent,
      foreignContent = nativeContentValue,
      restore = owned.Session.restore,
    },
    {
      name = "native",
      scenario = parityNativeScenario(),
      content = nativeContentValue,
      foreignContent = scriptedContent,
      restore = Executor.restore,
    },
  }
  for _, case in ipairs(cases) do
    local session = owned.Battle.newSession(copyPlain(case.scenario), case.content)
    local waiting = SessionFixture.driveUntilSettled(session)
    Assert.equal(waiting.status, "waiting", "the " .. case.name .. " battle opens its decision boundary")
    local held = session:capture()
    SessionFixture.assertPlainData(held)
    Assert.equal(#held.frames, 1, "waiting captures hold one round frame")
    Assert.equal(held.frames[1].kind, "round", "the waiting frame names its round kind")
    local function rejectsAsSnapshot(mutated, what)
      local ok, err = pcall(case.restore, mutated, case.content)
      Assert.isFalse(ok, case.name .. " " .. what .. " rejects instead of resuming")
      Assert.isTrue(Errors.is(err), case.name .. " " .. what .. " fails with a typed error")
      Assert.equal(
        (err --[[@as table<string, unknown>]]).code,
        BattleErrors.INCOMPATIBLE_SNAPSHOT,
        case.name .. " " .. what .. " names an incompatible snapshot"
      )
    end
    local unknown = copyPlain(held) --[[@as table<string, unknown>]]
    local unknownFrames = unknown.frames --[[@as table<integer, table<string, unknown>>]]
    unknownFrames[1].kind = "mystery"
    rejectsAsSnapshot(unknown, "an unknown continuation kind")
    local empty = copyPlain(held) --[[@as table<string, unknown>]]
    local emptyFrames = empty.frames --[[@as table<integer, table<string, unknown>>]]
    emptyFrames[1].state = {}
    rejectsAsSnapshot(empty, "a round frame without its round")
    local crossed = copyPlain(held) --[[@as table<string, unknown>]]
    local crossedFrames = crossed.frames --[[@as table<integer, table<string, unknown>>]]
    crossedFrames[1].state = { combatant = 1, activation = 1 }
    rejectsAsSnapshot(crossed, "a round frame carrying action state")
    local missingOk, missingErr = pcall(case.restore, copyPlain(held), case.foreignContent)
    Assert.isFalse(missingOk, case.name .. " content without its ruleset rejects instead of running")
    Assert.isTrue(Errors.is(missingErr), case.name .. " missing content fails with a typed error")
    Assert.equal(
      (missingErr --[[@as table<string, unknown>]]).code,
      BattleErrors.MISSING_BEHAVIOR,
      case.name .. " missing content names missing behavior"
    )
    local revived = case.restore(copyPlain(held), case.content)
    Assert.notNil(revived, case.name .. " valid captures restore")
    local first = SessionFixture.driveUntilSettled(session)
    local second = SessionFixture.driveUntilSettled(revived)
    Assert.deepEqual(second.request, first.request, case.name .. " restores reopen the same batch")
    for _, live in ipairs({ session, revived }) do
      local frame = SessionFixture.driveUntilSettled(live)
      for _, request in ipairs(frame.request.requests) do
        local target = 2
        if request.controller == "beta" then
          target = 1
        end
        local choices = {}
        for _, actor in ipairs(request.actors) do
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(target))
        end
        local accepted, replyErr = live:submit(SessionFixture.replyFor(request, choices))
        Assert.isTrue(accepted, case.name .. " restores accept the open replies")
        Assert.isNil(replyErr, case.name .. " accepted replies carry no input error")
        local repeated, repeatErr = live:submit(SessionFixture.replyFor(request, choices))
        Assert.isFalse(repeated, case.name .. " duplicate replies are refused")
        Assert.notNil(repeatErr, case.name .. " refused replies report their input error")
      end
    end
    local firstFrame = session:advance(64)
    local secondFrame = revived:advance(64)
    Assert.deepEqual(secondFrame.events, firstFrame.events, case.name .. " restores drain the same outbox")
    Assert.deepEqual(revived:capture(), session:capture(), case.name .. " restores reach the same state")
    session:dispose()
    revived:dispose()
    local disposedOk = pcall(function()
      session:advance(1)
    end)
    Assert.isFalse(disposedOk, case.name .. " disposed sessions publish nothing further")
  end
end

function T.native_format_validates_its_topology_at_construction()
  local owned = contracts()
  local content = SessionFixture.makeContent()
  local valid = owned.Battle.newSession(scenarioWithFormat(singlesParts(), "singles"), content)
  Assert.notNil(valid, "a conforming native layout constructs")
  local frame = valid:advance(1024)
  Assert.equal(frame.status, "waiting", "the native session waits for decisions")
  valid:dispose()
  local crossed = scenarioWithFormat(doublesParts(), "singles")
  local ok, err = pcall(owned.Battle.newSession, crossed, content)
  Assert.isFalse(ok, "a doubles layout never runs as singles on a default vocabulary")
  Assert.isTrue(err ~= nil, "the topology rejection carries its failure")
end

return { tests = T }
