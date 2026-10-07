-- Production-facade witness for composable battle formats: an asymmetric
-- five-active raid with an explicit boss budget, a mid-battle SOS join
-- through the normal decision path, custom namespaced content end to end,
-- and an overworld-styled presenter reusing the same session, controllers,
-- and semantic events. Everything here runs headless through the public
-- battle entrypoint with fixed seeds and ordered inputs; no rendering,
-- audio, wall clock, or dump capability is involved, and no step skips.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local FORMATS_MODULE = "libs.battle.src.gen4.formats.NativeFormats"
local TOPOLOGY_MODULE = "libs.battle.src.Topology"

local T = {
  metadata = {
    capabilities = {},
    tags = { "battle", "formats" },
  },
  tests = {},
}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded owner
local function requireOwner(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle owner loads")
  return loaded --[[@as table]]
end

---@param facade table the public battle facade under test
---@param behavior string extension behavior the journey needs
local function requireExtensionSurface(facade, behavior)
  Assert.equal(
    type(facade.registerFormat),
    "function",
    "missing versioned format registration for " .. behavior .. " (gen4.battle.registerFormat)"
  )
  Assert.equal(
    type(facade.registerAction),
    "function",
    "missing versioned action registration for " .. behavior .. " (gen4.battle.registerAction)"
  )
  Assert.equal(
    type(facade.createScenario),
    "function",
    "missing versioned scenario construction for " .. behavior .. " (gen4.battle.createScenario)"
  )
end

---@param owner string owning contributor name
---@return table contributor carrying the closed scripted ruleset over three base types
local function scriptedContributor(owner)
  local function relationsFor(key)
    local out = {}
    for _, other in ipairs({ "normal", "fire", "water" }) do
      local numerator, denominator = 1, 1
      if key == "fire" and other ~= "normal" then
        numerator, denominator = 1, 2
      elseif key == "water" and other == "fire" then
        numerator, denominator = 2, 1
      elseif key == "water" and other == "water" then
        numerator, denominator = 1, 2
      end
      out[#out + 1] = { attack = key, defend = other, numerator = numerator, denominator = denominator }
    end
    return out
  end
  return {
    owner = owner,
    revision = "1",
    install = function(builder, behaviors)
      for _, key in ipairs({ "normal", "fire", "water" }) do
        builder:define("types", key, { key = key, name = key, relations = relationsFor(key) }, owner)
      end
      behaviors:registerRuleset("test:scripted", { key = "test:scripted", chart = "test:scripted" }, owner)
      behaviors:registerFormat("test:scripted", { key = "test:scripted", chart = "test:scripted" }, owner)
    end,
  }
end

---@return table scenario parts for an asymmetric five-active raid lineup
local function raidParts()
  return {
    sides = {
      SessionFixture.side(1, { 1 }),
      SessionFixture.side(2, { 2, 3 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "boss", { SessionFixture.combatant(1, 91) }),
      SessionFixture.participant(2, 2, "alpha", {
        SessionFixture.combatant(2, 11),
        SessionFixture.combatant(3, 12),
      }),
      SessionFixture.participant(3, 2, "beta", {
        SessionFixture.combatant(4, 23),
        SessionFixture.combatant(5, 24),
      }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
      SessionFixture.position(3, 2, { 2 }, 3),
      SessionFixture.position(4, 2, { 3 }, 4),
      SessionFixture.position(5, 2, { 3 }, 5),
    },
  }
end

---@param request table pending decision request from the running battle
---@return table[] one opening strike per addressed actor
local function strikeEveryone(request)
  local choices = {}
  for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
    choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1))
  end
  return choices
end

function T.tests.raid_runs_five_active_combatants_with_an_explicit_boss_budget()
  local ok, Battle = pcall(require, "gen4.battle")
  Assert.isTrue(ok, "missing public battle facade (gen4.battle)")
  assert(Battle ~= nil, "the battle facade loads")
  requireExtensionSurface(Battle, "asymmetric raid formats")
  local NativeFormats = requireOwner(
    FORMATS_MODULE,
    "concrete raid topology, budget, and victory policies own format validation"
  )
  local Topology = requireOwner(
    TOPOLOGY_MODULE,
    "validated deterministic membership changes own raid assembly"
  )
  Assert.equal(type(Topology.prepareJoin), "function", "raid assembly stages through prepareJoin")
  Assert.equal(type(Topology.applyJoin), "function", "raid assembly publishes through applyJoin")
  Assert.equal(type(Topology.validateOwnership), "function", "raid assembly checks validateOwnership")
  local contracts = SessionFixture.sessionContracts()
  local raid = SessionFixture.buildScenario(raidParts())
  contracts.Scenario.validate(raid)
  Assert.isTrue(
    NativeFormats.validateScenario("raid", raid),
    "the raid policy accepts five simultaneous active combatants across asymmetric sides"
  )
  local staged = Topology.prepareJoin(raid, {
    reason = "raid-assembly",
    combatants = {},
    positions = {},
    settlementBoundary = "scenario-start",
  })
  Assert.notNil(staged, "raid assembly stages through the same validated join path as mid-battle joins")
  local _resolved, _bound, content = Battle.compose({ scriptedContributor("raid-proof") })
  local session = Battle.newSession(raid, content)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the same kernel waits for decisions under a raid topology")
  Assert.notNil(frame.request, "the waiting raid frame carries its decision batch")
  local actors = 0
  for _, request in ipairs(frame.request.requests) do
    actors = actors + #request.actors
  end
  Assert.equal(actors, 5, "all five raid combatants answer through the normal decision batch")
  session:dispose()
end

function T.tests.sos_join_enters_mid_battle_through_the_normal_decision_path()
  local ok, Battle = pcall(require, "gen4.battle")
  Assert.isTrue(ok, "missing public battle facade (gen4.battle)")
  assert(Battle ~= nil, "the battle facade loads")
  requireExtensionSurface(Battle, "mid-battle joins")
  local Topology = requireOwner(
    TOPOLOGY_MODULE,
    "validated deterministic membership changes own mid-battle joins"
  )
  local contracts = SessionFixture.sessionContracts()
  local parts = {
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
      SessionFixture.position(3, 2, { 2 }, nil),
    },
  }
  local scenario = SessionFixture.buildScenario(parts)
  contracts.Scenario.validate(scenario)
  local _resolved, _bound, content = Battle.compose({ scriptedContributor("sos-proof") })
  local session = Battle.newSession(scenario, content)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the kernel reaches its first decision batch before any join")
  for _, request in ipairs(frame.request.requests) do
    local accepted, _ = session:submit(SessionFixture.replyFor(request, strikeEveryone(request)))
    Assert.isTrue(accepted, "opening exchanges answer through the normal decision path")
  end
  local settled = SessionFixture.driveUntilSettled(session)
  Assert.isTrue(
    settled.status == "waiting" or settled.status == "ended",
    "the kernel settles exchanges at an explicit mechanics boundary before joining"
  )
  local staged = Topology.prepareJoin(session, {
    reason = "sos-call",
    participant = SessionFixture.participant(2, 2, "beta", { SessionFixture.combatant(5, 25) }),
    combatants = { SessionFixture.combatant(5, 25) },
    positions = { SessionFixture.position(3, 2, { 2 }, 5) },
    settlementBoundary = "round-end",
  })
  Assert.notNil(staged, "the SOS join stages against content and format policy at the boundary")
  local joined = Topology.applyJoin(session, staged)
  Assert.notNil(joined, "the staged SOS join publishes new identities without reusing old ones")
  session:dispose()
end

function T.tests.custom_content_battles_and_persists_while_native_export_refuses_it()
  local ok, Battle = pcall(require, "gen4.battle")
  Assert.isTrue(ok, "missing public battle facade (gen4.battle)")
  assert(Battle ~= nil, "the battle facade loads")
  requireExtensionSurface(Battle, "custom namespaced content")
  local contracts = SessionFixture.sessionContracts()
  local custom = {
    owner = "glimmer-proof",
    revision = "1",
    install = function(builder, behaviors)
      builder:define("types", "glimmer", {
        key = "glimmer",
        name = "Glimmer",
        relations = {
          { attack = "glimmer", defend = "glimmer", numerator = 1, denominator = 1 },
          { attack = "glimmer", defend = "normal", numerator = 2, denominator = 1 },
        },
      }, "glimmer-proof")
      builder:define("types", "normal", {
        key = "normal",
        name = "Normal",
        relations = {
          { attack = "normal", defend = "glimmer", numerator = 1, denominator = 2 },
          { attack = "normal", defend = "normal", numerator = 1, denominator = 1 },
        },
      }, "glimmer-proof")
      behaviors:registerRuleset("glimmer:rules", { key = "glimmer:rules", chart = "glimmer:rules" }, "glimmer-proof")
      behaviors:registerFormat(
        "glimmer:skirmish",
        { key = "glimmer:skirmish", chart = "glimmer:rules" },
        "glimmer-proof"
      )
    end,
  }
  local resolved, _, content = Battle.compose({ custom })
  local record = resolved:get("types", "glimmer")
  assert(type(record) == "table", "the custom type resolves through the public facade")
  Assert.isNil(record.nativeId, "custom content carries no native identity")
  local chart = content:typeChart("glimmer:rules")
  local pair = chart:effectiveness("glimmer", "normal")
  Assert.equal(pair.numerator, 2, "custom effectiveness resolves inside its own ruleset")
  local scenario = Battle.createScenario({
    ruleset = "glimmer:rules",
    format = "glimmer:skirmish",
    seed = 11,
  })
  local session = Battle.newSession(scenario, content)
  local captured = session:capture()
  SessionFixture.assertPlainData(captured, "custom session capture")
  local restored = contracts.Session.restore(captured, content)
  Assert.notNil(restored, "custom session state round-trips through snapshot restore")
  local native = SessionFixture.makeContent()
  local nativeOk = pcall(native.typeChart, native, "glimmer:rules")
  Assert.isFalse(nativeOk, "the native composition never resolves the custom chart")
  session:dispose()
  restored:dispose()
end

function T.tests.overworld_presenter_reuses_the_same_session_events_without_rendering()
  local ok, Battle = pcall(require, "gen4.battle")
  Assert.isTrue(ok, "missing public battle facade (gen4.battle)")
  assert(Battle ~= nil, "the battle facade loads")
  requireExtensionSurface(Battle, "overworld presentation")
  local NativeFormats = requireOwner(
    FORMATS_MODULE,
    "concrete native topology policies own the presented battle layout"
  )
  local contracts = SessionFixture.sessionContracts()
  local parts = {
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
  local scenario = SessionFixture.buildScenario(parts)
  contracts.Scenario.validate(scenario)
  local doublesOk = pcall(NativeFormats.validateScenario, "doubles", scenario)
  Assert.isFalse(doublesOk, "a singles lineup never validates as doubles before any presenter attaches")
  Assert.isTrue(
    NativeFormats.validateScenario("singles", scenario),
    "the presented battle validates under its native format before any presenter attaches"
  )
  local _resolved, _bound, content = Battle.compose({ scriptedContributor("overworld-proof") })
  local first = Battle.newSession(scenario, content)
  local presented = {}
  local presenter = {
    present = function(frame)
      presented[#presented + 1] = frame
    end,
  }
  for _ = 1, 64 do
    local frame = first:advance(nil)
    Assert.notNil(frame, "the presented session advances without any rendering backend")
    presenter.present(frame)
    if frame.status ~= "running" then
      break
    end
    if frame.status == "waiting" then
      for _, request in ipairs(frame.request.requests) do
        local accepted, _ = first:submit(SessionFixture.replyFor(request, strikeEveryone(request)))
        Assert.isTrue(accepted, "presenter-side answers travel the normal decision path")
      end
    end
  end
  Assert.isTrue(#presented > 0, "the overworld-styled presenter observed semantic frames")
  local seed = scenario.random.seed
  local second = Battle.newSession(SessionFixture.buildScenario(parts), content)
  local replayed = {}
  for _ = 1, 64 do
    local frame = second:advance(nil)
    Assert.notNil(frame, "the repeated session advances under the same seed")
    replayed[#replayed + 1] = frame.status
    if frame.status ~= "running" then
      break
    end
    if frame.status == "waiting" then
      for _, request in ipairs(frame.request.requests) do
        local accepted, _ = second:submit(SessionFixture.replyFor(request, strikeEveryone(request)))
        Assert.isTrue(accepted, "repeated answers travel the normal decision path")
      end
    end
  end
  Assert.equal(#replayed, #presented, "the same seed and command order replay identically under any presenter")
  Assert.equal(scenario.random.seed, seed, "presentation never mutates the simulation seed")
  first:dispose()
  second:dispose()
end

return T
