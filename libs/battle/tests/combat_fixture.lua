-- Shared frozen chart compositions for combat arithmetic suites: a closed
-- vanilla type set and a custom extension adding one extra type with
-- declared directed relations. Both compositions use the real content and
-- battle owners, so chart lookups exercise production assembly.

local Assert = require("tests.support.Assert")

local CombatFixture = {}

CombatFixture.VANILLA_RULESET = "test:combat-vanilla"
CombatFixture.CUSTOM_RULESET = "test:combat-custom"
CombatFixture.SOUND = "sound"

---@return string[] vanilla type keys in declared order
function CombatFixture.vanillaTypes()
  return { "normal", "fire", "water", "ground", "flying", "mystery" }
end

---@return string[] custom type keys in declared order
function CombatFixture.customTypes()
  return { "normal", "fire", "water", "ground", "flying", "mystery", "sound" }
end

---@param attack string
---@param defend string
---@param numerator integer
---@param denominator integer
---@return table<string, unknown>
local function relation(attack, defend, numerator, denominator)
  return { attack = attack, defend = defend, numerator = numerator, denominator = denominator }
end

-- Declared non-neutral directed pairs shared by both compositions, fixed as
-- literals: fire is resisted by fire and water, water is resisted by water
-- and super-effective into fire, ground cannot touch flying.
---@return table<string, table<string, unknown>>
local function sharedOverrides()
  return {
    ["fire|fire"] = relation("fire", "fire", 1, 2),
    ["fire|water"] = relation("fire", "water", 1, 2),
    ["water|fire"] = relation("water", "fire", 2, 1),
    ["water|water"] = relation("water", "water", 1, 2),
  }
end

---@param keys string[] closed type list for the composition
---@param custom boolean whether the extra custom relations apply
---@return table<string, table[]> relations per defending keyed type
local function relationsFor(keys, custom)
  local overrides = sharedOverrides()
  if custom then
    overrides["ground|flying"] = relation("ground", "flying", 1, 1)
    overrides["sound|water"] = relation("sound", "water", 2, 1)
    overrides["water|sound"] = relation("water", "sound", 1, 2)
  else
    overrides["ground|flying"] = relation("ground", "flying", 0, 1)
  end
  local grouped = {}
  for _, key in ipairs(keys) do
    grouped[key] = {}
  end
  for _, attack in ipairs(keys) do
    for _, defend in ipairs(keys) do
      local override = overrides[attack .. "|" .. defend]
      if override ~= nil then
        grouped[attack][#grouped[attack] + 1] = override
      else
        grouped[attack][#grouped[attack] + 1] = relation(attack, defend, 1, 1)
      end
    end
  end
  return grouped
end

---@param keys string[] closed type list for the composition
---@param ruleset string ruleset key owning the chart
---@param custom boolean whether the extra custom relations apply
---@return table frozen battle content for combat arithmetic suites
local function makeContent(keys, ruleset, custom)
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  local grouped = relationsFor(keys, custom)
  for _, key in ipairs(keys) do
    builder:define("types", key, { key = key, name = key, relations = grouped[key] }, "combat-tests")
  end
  behaviors:registerRuleset(ruleset, { key = ruleset, chart = ruleset }, "combat-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table frozen battle content over the vanilla type set
function CombatFixture.makeVanilla()
  return makeContent(CombatFixture.vanillaTypes(), CombatFixture.VANILLA_RULESET, false)
end

---@return table frozen battle content over the extended custom type set
function CombatFixture.makeCustom()
  return makeContent(CombatFixture.customTypes(), CombatFixture.CUSTOM_RULESET, true)
end

---@param content table frozen battle content under test
---@param ruleset string ruleset key owning the chart
---@return table isolated chart view over the composition type matrix
function CombatFixture.chart(content, ruleset)
  local view = content:typeChart(ruleset)
  Assert.notNil(view, "chart lookups publish an isolated view")
  return view
end

return CombatFixture
