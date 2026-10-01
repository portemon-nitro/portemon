-- Concrete native battle format policies: singles, doubles, allied-trainer,
-- partner, and facility/link battles keep separate controller, party, and
-- inventory ownership with per-format topology, action budgets, and
-- consequence policies instead of a fixed four-combatant kernel assumption.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local FORMATS_MODULE = "libs.battle.src.gen4.formats.NativeFormats"

local T = {}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded format owner
local function requireFormats(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing native format policies: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the native format owner loads")
  return loaded --[[@as table]]
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

---@return table scenario parts where two trainers ally on one side
local function alliedParts()
  return {
    sides = {
      SessionFixture.side(1, { 1, 2 }),
      SessionFixture.side(2, { 3 }),
    },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { SessionFixture.combatant(1, 11) }, "bag-alpha"),
      SessionFixture.participant(2, 1, "gamma", { SessionFixture.combatant(2, 31) }, "bag-gamma"),
      SessionFixture.participant(3, 2, "beta", {
        SessionFixture.combatant(3, 23),
        SessionFixture.combatant(4, 24),
      }, "bag-beta"),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 2 }, 2),
      SessionFixture.position(3, 2, { 3 }, 3),
      SessionFixture.position(4, 2, { 3 }, 4),
    },
    inventories = {
      SessionFixture.inventory("bag-alpha", { 1 }, { potion = 3 }),
      SessionFixture.inventory("bag-gamma", { 2 }, { potion = 1 }),
      SessionFixture.inventory("bag-beta", { 3 }, { potion = 5 }),
    },
  }
end

---@param formats table the native format owner under test
---@return table format policies keyed by native format key
local function nativePolicies(formats)
  Assert.equal(type(formats.register), "function", "native formats bind their concrete policies through register")
  Assert.equal(
    type(formats.validateScenario),
    "function",
    "native formats validate detached scenarios through validateScenario"
  )
  local policies = formats.register()
  assert(type(policies) == "table", "register binds the native policy set")
  for _, key in ipairs({ "singles", "doubles", "multi", "partner" }) do
    Assert.notNil(policies[key], "native policies bind " .. key)
  end
  return policies --[[@as table]]
end

---@param policy table one native format definition under test
---@param key string native format key under test
local function checkDefinitionShape(policy, key)
  Assert.equal(type(policy.validateScenario), "function", key .. " owns its scenario validation")
  Assert.equal(type(policy.actionBudgets), "function", key .. " owns its action budgets")
  Assert.equal(type(policy.resolveTargets), "function", key .. " owns its target resolution")
  Assert.equal(type(policy.checkOutcome), "function", key .. " owns its outcome check")
  Assert.notNil(policy.resultPolicy, key .. " owns its consequence policy")
end

function T.singles_accepts_one_active_per_side_and_rejects_a_doubles_layout()
  local contracts = SessionFixture.sessionContracts()
  local singles = SessionFixture.buildScenario(singlesParts())
  contracts.Scenario.validate(singles)
  local doubles = SessionFixture.buildScenario(doublesParts())
  contracts.Scenario.validate(doubles)
  local NativeFormats = requireFormats(
    FORMATS_MODULE,
    "concrete singles topology and consequence policies own format validation"
  )
  local policies = nativePolicies(NativeFormats)
  checkDefinitionShape(policies.singles, "singles")
  Assert.isTrue(
    NativeFormats.validateScenario("singles", singles),
    "singles accepts its one-active-per-side topology"
  )
  local accepted = pcall(NativeFormats.validateScenario, "singles", doubles)
  Assert.isFalse(accepted, "singles rejects a doubles layout instead of silently running it")
end

function T.doubles_keeps_each_side_at_two_active_slots_with_separate_authority()
  local contracts = SessionFixture.sessionContracts()
  local doubles = SessionFixture.buildScenario(doublesParts())
  contracts.Scenario.validate(doubles)
  local singles = SessionFixture.buildScenario(singlesParts())
  contracts.Scenario.validate(singles)
  local NativeFormats = requireFormats(
    FORMATS_MODULE,
    "concrete doubles topology and consequence policies own format validation"
  )
  local policies = nativePolicies(NativeFormats)
  checkDefinitionShape(policies.doubles, "doubles")
  Assert.isTrue(
    NativeFormats.validateScenario("doubles", doubles),
    "doubles accepts its two-active-per-side topology"
  )
  local accepted = pcall(NativeFormats.validateScenario, "doubles", singles)
  Assert.isFalse(accepted, "doubles rejects a singles layout instead of silently running it")
  Assert.isFalse(
    (policies.doubles.resultPolicy == policies.singles.resultPolicy)
      and (policies.doubles.actionBudgets == policies.singles.actionBudgets),
    "doubles carries its own budgets and consequences rather than aliasing singles"
  )
end

function T.allied_participants_share_a_side_without_sharing_party_or_inventory()
  local contracts = SessionFixture.sessionContracts()
  local allied = SessionFixture.buildScenario(alliedParts())
  contracts.Scenario.validate(allied)
  local NativeFormats = requireFormats(
    FORMATS_MODULE,
    "concrete multi and partner alliance policies own shared-side validation"
  )
  local policies = nativePolicies(NativeFormats)
  checkDefinitionShape(policies.multi, "multi")
  checkDefinitionShape(policies.partner, "partner")
  Assert.isTrue(
    NativeFormats.validateScenario("multi", allied),
    "allied trainers sharing one side validate under their own alliance policy"
  )
  local crossed = SessionFixture.buildScenario(alliedParts())
  crossed.participants[1].inventoryId = "bag-shared"
  crossed.participants[2].inventoryId = "bag-shared"
  crossed.inventories = {
    SessionFixture.inventory("bag-shared", { 1, 2 }, { potion = 4 }),
    SessionFixture.inventory("bag-beta", { 3 }, { potion = 5 }),
  }
  contracts.Scenario.validate(crossed)
  local shared = pcall(NativeFormats.validateScenario, "multi", crossed)
  Assert.isFalse(shared, "allied trainers never validate while sharing one inventory handle")
end

function T.facility_and_link_policies_own_their_consequences_separately()
  local contracts = SessionFixture.sessionContracts()
  local singles = SessionFixture.buildScenario(singlesParts())
  contracts.Scenario.validate(singles)
  local NativeFormats = requireFormats(
    FORMATS_MODULE,
    "battle-level facility and link restoration, reward, and legality policies own their consequences"
  )
  local policies = nativePolicies(NativeFormats)
  checkDefinitionShape(policies.singles, "singles")
  local seen = {}
  for _, key in ipairs({ "singles", "facility", "link" }) do
    local policy = policies[key]
    Assert.notNil(policy, "native policies bind battle-level " .. key .. " consequences")
    checkDefinitionShape(policy, key)
    Assert.notNil(policy.resultPolicy.restoration, key .. " names its restoration policy")
    Assert.notNil(policy.resultPolicy.reward, key .. " names its reward policy")
    Assert.notNil(policy.resultPolicy.legality, key .. " names its legality policy")
    local fingerprint = tostring(policy.resultPolicy.restoration)
      .. "/"
      .. tostring(policy.resultPolicy.reward)
      .. "/"
      .. tostring(policy.resultPolicy.legality)
    Assert.isNil(seen[fingerprint], key .. " carries consequences distinct from every other native policy")
    seen[fingerprint] = key
  end
  Assert.isTrue(
    NativeFormats.validateScenario("facility", singles),
    "battle-level facility policy validates its topology without owning facility progression"
  )
end

return { tests = T }
