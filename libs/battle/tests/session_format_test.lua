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
