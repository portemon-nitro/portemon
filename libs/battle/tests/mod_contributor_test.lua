-- Mod contribution composition: custom namespaced content composes through
-- the public battle facade without native identities, and contributor
-- declaration order decides patch resolution while source mechanics order
-- stays untouched by mod load order. Numeric contributor fields never become
-- battle timing, and compatibility contributions suppress exactly the named
-- canonical contributions.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@return table the public battle facade under test
local function battleFacade()
  local ok, loaded = pcall(require, "gen4.battle")
  Assert.isTrue(ok, "missing public battle facade (gen4.battle)")
  assert(loaded ~= nil, "the battle facade loads")
  return loaded --[[@as table]]
end

---@param facade table the public battle facade under test
---@param behavior string extension behavior the scenario needs
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

---@param attack string
---@param defend string
---@param numerator integer
---@param denominator integer
---@return table<string, unknown> one directed effectiveness relation
local function relation(attack, defend, numerator, denominator)
  return { attack = attack, defend = defend, numerator = numerator, denominator = denominator }
end

---@param owner string owning contributor name
---@return table contributor defining a namespaced type, move, effect, and ruleset
local function customContentContributor(owner)
  return {
    owner = owner,
    revision = "1",
    install = function(builder, behaviors)
      builder:define("types", "glimmer", {
        key = "glimmer",
        name = "Glimmer",
        relations = {
          relation("glimmer", "glimmer", 1, 1),
          relation("glimmer", "normal", 2, 1),
        },
      }, owner)
      builder:define("types", "normal", {
        key = "normal",
        name = "Normal",
        relations = {
          relation("normal", "glimmer", 1, 2),
          relation("normal", "normal", 1, 1),
        },
      }, owner)
      behaviors:registerMove(
        "glimmer:gleam",
        { module = "glimmer.gleam", version = 1, parameters = { power = 60 } },
        owner
      )
      behaviors:registerEffect("glimmer:shimmer", { module = "glimmer.shimmer", version = 1 }, owner)
      behaviors:registerRuleset("glimmer:rules", { key = "glimmer:rules", chart = "glimmer:rules" }, owner)
      behaviors:registerFormat("glimmer:skirmish", { key = "glimmer:skirmish", chart = "glimmer:rules" }, owner)
    end,
  }
end

---@param owner string owning contributor name
---@param value string patch payload this contributor writes
---@param extra table<string, unknown>|nil declared ordering and suppression fields
---@return table contributor patching one shared tuning record
local function tuningContributor(owner, value, extra)
  local contribution = {
    owner = owner,
    revision = "1",
    install = function(builder, _behaviors)
      builder:patch("tuning", "power", { { op = "set", path = { "value" }, value = value } }, owner)
    end,
  }
  for key, field in pairs(extra or {}) do
    contribution[key] = field
  end
  return contribution --[[@as table]]
end

---@return table contributor defining the shared tuning record both tuners patch
local function tuningBaseContributor()
  return {
    owner = "base-pack",
    revision = "1",
    install = function(builder, _behaviors)
      builder:define("tuning", "power", { value = "base" }, "base-pack")
    end,
  }
end

function T.custom_content_composes_without_native_identities()
  local facade = battleFacade()
  requireExtensionSurface(facade, "custom namespaced content")
  local resolved, _, content = facade.compose({ customContentContributor("glimmer-pack") })
  local record = resolved:get("types", "glimmer")
  assert(type(record) == "table", "the composed custom type resolves")
  Assert.isNil(record.nativeId, "custom content carries no native identity")
  local chart = content:typeChart("glimmer:rules")
  local strong = chart:effectiveness("glimmer", "normal")
  Assert.equal(strong.numerator, 2, "custom effectiveness applies inside its own ruleset")
  Assert.equal(strong.denominator, 1, "custom effectiveness keeps its exact denominator")
  local move = content:behavior("moves", "glimmer:gleam")
  assert(type(move) == "table", "the composed custom move resolves")
  local scenario = facade.createScenario({
    ruleset = "glimmer:rules",
    format = "glimmer:skirmish",
    seed = 7,
  })
  local session = facade.newSession(scenario, content)
  Assert.notNil(session, "custom content drives a live headless session through the public facade")
  session:dispose()
end

function T.custom_session_content_stays_isolated_from_native_sessions()
  local facade = battleFacade()
  requireExtensionSurface(facade, "isolated custom sessions")
  local _resolved, _bound2, custom = facade.compose({ customContentContributor("glimmer-pack") })
  local native = SessionFixture.makeContent()
  local customChart = custom:typeChart("glimmer:rules")
  local customPair = customChart:effectiveness("glimmer", "normal")
  Assert.equal(customPair.numerator, 2, "custom ruleset resolves its own relations")
  local nativeChart = native:typeChart(SessionFixture.RULESET)
  local nativePair = nativeChart:effectiveness("fire", "water")
  Assert.equal(nativePair.numerator, 1, "the native session keeps its own relations")
  Assert.equal(nativePair.denominator, 2, "the native session keeps its exact denominators")
  local ok = pcall(native.typeChart, native, "glimmer:rules")
  Assert.isFalse(ok, "the native composition never resolves the custom chart")
end

function T.declared_dependency_order_wins_regardless_of_contributor_input_order()
  local facade = battleFacade()
  local first = tuningContributor("alpha-pack", "alpha", { priority = 10 })
  local second = tuningContributor("beta-pack", "beta", { after = { "alpha-pack" }, priority = 1 })
  local forward = facade.compose({ tuningBaseContributor(), first, second })
  local backward = facade.compose({ tuningBaseContributor(), second, first })
  local forwardValue = forward:get("tuning", "power")
  local backwardValue = backward:get("tuning", "power")
  assert(type(forwardValue) == "table", "the forward composition resolves the patched record")
  assert(type(backwardValue) == "table", "the backward composition resolves the patched record")
  Assert.equal(forwardValue.value, "beta", "declared order applies the later contributor last")
  Assert.deepEqual(
    backwardValue,
    forwardValue,
    "contributor input order never changes the resolved patch outcome"
  )
  local cyclicA = tuningContributor("alpha-pack", "alpha", { after = { "beta-pack" } })
  local cyclicB = tuningContributor("beta-pack", "beta", { after = { "alpha-pack" } })
  Assert.throws(function()
    facade.compose({ tuningBaseContributor(), cyclicA, cyclicB })
  end, "dependency cycles fail instead of resolving in an arbitrary order")
end

function T.compatibility_suppression_removes_only_the_named_canonical_contribution()
  local facade = battleFacade()
  local canonical = {
    owner = "canon-moves",
    revision = "1",
    install = function(_builder, behaviors)
      behaviors:registerMove("canon:bolt", { module = "canon.bolt", version = 1 }, "canon-moves")
      behaviors:registerMove("canon:beam", { module = "canon.beam", version = 1 }, "canon-moves")
    end,
  }
  local compatibility = {
    owner = "compat-pack",
    revision = "2",
    suppresses = { { kind = "moves", key = "canon:bolt" } },
    install = function(_builder, _behaviors) end,
  }
  local _resolved, _bound, content = facade.compose({ canonical, compatibility })
  Assert.throws(function()
    content:behavior("moves", "canon:bolt")
  end, "a suppressed canonical contribution no longer resolves")
  local kept = content:behavior("moves", "canon:beam")
  assert(type(kept) == "table", "suppression keeps every contribution it does not name")
  local provenance = content:behavior("moves", "canon:beam")
  Assert.equal(provenance.module, "canon.beam", "kept contributions resolve to their canonical owner")
end

return { tests = T }
