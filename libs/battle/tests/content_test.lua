-- Frozen battle composition: session-scoped effectiveness charts resolve
-- every directed pair with exact rational arithmetic, and compositions stay
-- isolated across instances. Upward import directions are owned by the
-- architecture package policy gate, which carries the forbidden edges for
-- the composition packages alongside every other governed pair.

local Assert = require("tests.support.Assert")

local T = {}

---@param module string
---@param behavior string
---@return table
local function requireContract(module, behavior)
  local ok, loaded = pcall(require, module)
  Assert.isTrue(ok, "missing battle composition contract " .. module .. ": " .. behavior)
  assert(loaded ~= nil, "the battle composition contract loads its module")
  return loaded --[[@as table]]
end

---@param key string
---@param name string
---@param relations table[]
---@return table<string, unknown>
local function typeRecord(key, name, relations)
  return { key = key, name = name, relations = relations }
end

---@param attack string
---@param defend string
---@param numerator integer
---@param denominator integer
---@return table<string, unknown>
local function relation(attack, defend, numerator, denominator)
  return { attack = attack, defend = defend, numerator = numerator, denominator = denominator }
end

---@return table<string, unknown> relations among the three closed base types
local function baseRelations()
  return {
    relation("normal", "normal", 1, 1),
    relation("normal", "fire", 1, 1),
    relation("normal", "water", 1, 1),
    relation("fire", "normal", 1, 1),
    relation("fire", "fire", 1, 2),
    relation("fire", "water", 1, 2),
    relation("water", "normal", 1, 1),
    relation("water", "fire", 2, 1),
    relation("water", "water", 1, 2),
  }
end

---@return table<string, unknown> directed pairs between the extra type and every base type
local function extraRelations(extra)
  return {
    relation(extra, "normal", 1, 1),
    relation("normal", extra, 1, 2),
    relation(extra, "fire", 2, 1),
    relation("fire", extra, 1, 1),
    relation(extra, "water", 1, 1),
    relation("water", extra, 0, 1),
    relation(extra, extra, 1, 1),
  }
end

---@param builder table
---@param withExtra string?
---@param owner string
local function defineChartTypes(builder, withExtra, owner)
  local base = { "normal", "fire", "water" }
  local scoped = {}
  for _, key in ipairs(base) do
    scoped[#scoped + 1] = relation(key, key, 1, 1)
  end
  for _, pair in ipairs(baseRelations()) do
    if pair.attack ~= pair.defend then
      scoped[#scoped + 1] = pair
    end
  end
  builder:define("types", "normal", typeRecord("normal", "Normal", scoped), owner)
  builder:define("types", "fire", typeRecord("fire", "Fire", scoped), owner)
  builder:define("types", "water", typeRecord("water", "Water", scoped), owner)
  if withExtra ~= nil then
    local extra = {}
    for _, pair in ipairs(extraRelations(withExtra)) do
      extra[#extra + 1] = pair
    end
    builder:define("types", withExtra, typeRecord(withExtra, "Sound", extra), owner)
  end
end

---@param ContentBuilder table
---@param BattleBehaviorBuilder table
---@param withExtra string?
---@param owner string
---@return table chart view for the frozen composition
local function freezeChart(ContentBuilder, BattleBehaviorBuilder, withExtra, owner)
  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  defineChartTypes(builder, withExtra, owner)
  behaviors:registerRuleset("test:standard", { key = "test:standard", chart = "test:standard" }, owner)
  local bound = behaviors:freeze()
  local resolved = builder:freeze()
  local BattleContent = requireContract(
    "libs.battle.src.BattleContent",
    "frozen executable battle bindings have no owner"
  )
  local content = BattleContent.new(resolved, bound)
  return content:typeChart("test:standard")
end

---@param rational unknown
---@param numerator integer
---@param denominator integer
local function assertRational(rational, numerator, denominator)
  Assert.isTrue(type(rational) == "table", "effectiveness stays an exact rational, never a float")
  Assert.isTrue(type(rational.numerator) == "number", "rational numerator stays an integer")
  Assert.isTrue(type(rational.denominator) == "number", "rational denominator stays an integer")
  Assert.isTrue(rational.numerator % 1 == 0, "rational numerator stays an integer")
  Assert.isTrue(rational.denominator % 1 == 0, "rational denominator stays an integer")
  Assert.isTrue(rational.denominator > 0, "rational denominators stay strictly positive")
  Assert.equal(rational.numerator, numerator)
  Assert.equal(rational.denominator, denominator)
end

function T.chart_relations_stay_exact_and_isolated_to_their_composition()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered type definitions have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed ruleset registration has no owner"
  )

  local plain = freezeChart(ContentBuilder, BattleBehaviorBuilder, nil, "vanilla")
  assertRational(plain:effectiveness("fire", "water"), 1, 2)
  assertRational(plain:effectiveness("water", "fire"), 2, 1)
  assertRational(plain:effectiveness("normal", "normal"), 1, 1)

  local sounding = freezeChart(ContentBuilder, BattleBehaviorBuilder, "sound:SOUND", "sound")
  assertRational(sounding:effectiveness("fire", "water"), 1, 2)
  assertRational(sounding:effectiveness("sound:SOUND", "fire"), 2, 1)
  assertRational(sounding:effectiveness("normal", "sound:SOUND"), 1, 2)
  assertRational(sounding:effectiveness("water", "sound:SOUND"), 0, 1)

  -- The composition without the extra type never sees it.
  Assert.throws(function()
    plain:effectiveness("sound:SOUND", "normal")
  end)
  Assert.throws(function()
    plain:effectiveness("normal", "sound:SOUND")
  end)
end

function T.chart_with_a_missing_pair_fails_before_freeze()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered type definitions have no composition owner"
  )

  local builder = ContentBuilder.new()
  builder:define(
    "types",
    "normal",
    typeRecord("normal", "Normal", { relation("normal", "normal", 1, 1) }),
    "vanilla"
  )
  builder:define("types", "fire", typeRecord("fire", "Fire", { relation("fire", "fire", 1, 1) }), "vanilla")
  Assert.throws(function()
    builder:freeze()
  end)
end

function T.native_chart_covers_every_directed_pair_and_rejects_gaps()
  local NativeTypeChart = requireContract(
    "libs.battle.src.gen4.NativeTypeChart",
    "the native type matrix installs through content composition"
  )
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered type definitions have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed ruleset registration has no owner"
  )
  local BattleContent = requireContract(
    "libs.battle.src.BattleContent",
    "frozen executable battle bindings have no owner"
  )
  local universe = {
    "normal",
    "fighting",
    "flying",
    "poison",
    "ground",
    "rock",
    "bug",
    "ghost",
    "steel",
    "mystery",
    "fire",
    "water",
    "grass",
    "electric",
    "psychic",
    "ice",
    "dragon",
    "dark",
  }
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-chart-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset("test:native", { key = "test:native", chart = "test:native" }, "native-chart-tests")
  local content = BattleContent.new(builder:freeze(), behaviors:freeze())
  local chart = content:typeChart("test:native")
  for _, attack in ipairs(universe) do
    for _, defend in ipairs(universe) do
      local pair = chart:effectiveness(attack, defend)
      Assert.isTrue(
        type(pair.numerator) == "number" and type(pair.denominator) == "number",
        "the native chart resolves " .. attack .. " into " .. defend
      )
    end
  end
  assertRational(chart:effectiveness("fire", "grass"), 2, 1)
  assertRational(chart:effectiveness("water", "fire"), 2, 1)
  assertRational(chart:effectiveness("electric", "water"), 2, 1)
  assertRational(chart:effectiveness("fire", "water"), 1, 2)
  assertRational(chart:effectiveness("ghost", "steel"), 1, 2)
  assertRational(chart:effectiveness("normal", "ghost"), 0, 1)
  assertRational(chart:effectiveness("electric", "ground"), 0, 1)
  assertRational(chart:effectiveness("poison", "steel"), 0, 1)

  local gapped = ContentBuilder.new()
  NativeTypeChart.install(gapped, "native-chart-tests")
  gapped:patch("types", "fire", { { op = "remove", path = { "relations", 1 } } }, "native-chart-tests")
  Assert.throws(function()
    gapped:freeze()
  end, "a native chart missing one directed pair never freezes")
end

function T.separate_compositions_keep_independent_definitions()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration has no owner"
  )

  local function installPower(power, owner)
    return function(builder, behaviors)
      behaviors:registerMove("test:tackle", { module = "test.tackle", version = 1 }, owner)
      builder:define("moves", "TACKLE", {
        key = "TACKLE",
        name = "Tackle",
        description = "Charges the foe.",
        moveType = "normal",
        category = "physical",
        power = power,
        basePp = 35,
        accuracy = 95,
        priority = 0,
        target = "selected",
        flags = { contact = true },
        behavior = { key = "test:tackle" },
      }, owner)
    end
  end

  local firstBuilder = ContentBuilder.new()
  local firstBehaviors = BattleBehaviorBuilder.new()
  installPower(35, "first")(firstBuilder, firstBehaviors)
  firstBehaviors:freeze()
  local first = firstBuilder:freeze()

  local secondBuilder = ContentBuilder.new()
  local secondBehaviors = BattleBehaviorBuilder.new()
  installPower(55, "second")(secondBuilder, secondBehaviors)
  secondBehaviors:freeze()
  local second = secondBuilder:freeze()

  Assert.equal(first:get("moves", "TACKLE").power, 35)
  Assert.equal(second:get("moves", "TACKLE").power, 55)

  -- Existing native constructor users keep working alongside composition.
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local items = ItemCatalog.new(ItemFixture.buildAssetRoot())
  local catalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), items)
  Assert.equal(catalog:species("CHIKORITA").nativeId, 152)
  Assert.equal(catalog:move("TACKLE").nativeId, 33)
  Assert.equal(items:item("POKE_BALL").nativeId, 4)
end

---@param err unknown
---@return string
local function diagnosticText(err)
  local Errors = require("libs.errors.src.Errors")
  if Errors.is(err) then
    return Errors.format(err)
  end
  if type(err) == "table" and type(err.message) == "string" then
    return err.message
  end
  return tostring(err)
end

function T.duplicate_behavior_registration_names_both_owners_and_keeps_state()
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration has no owner"
  )

  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerMove("test:tackle", { module = "test.tackle", version = 1 }, "vanilla")
  local conflict = Assert.throws(function()
    behaviors:registerMove("test:tackle", { module = "other.tackle", version = 2 }, "second-owner")
  end)
  local conflictText = diagnosticText(conflict)
  Assert.isTrue(conflictText:find("vanilla", 1, true) ~= nil, "conflict names the first owner")
  Assert.isTrue(conflictText:find("second-owner", 1, true) ~= nil, "conflict names the second owner")

  -- The rejected registration recorded nothing: the first binding survives.
  local bound = behaviors:freeze()
  Assert.equal(bound:get("moves", "test:tackle").module, "test.tackle")
end

function T.behavior_registration_rejects_shapes_without_module_or_version()
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration has no owner"
  )

  local behaviors = BattleBehaviorBuilder.new()
  Assert.throws(function()
    behaviors:registerMove("test:vapor", { version = 1 }, "vanilla")
  end)
  Assert.throws(function()
    behaviors:registerMove("test:vapor", { module = "test.vapor", version = 0 }, "vanilla")
  end)
  Assert.throws(function()
    behaviors:registerEffect("test:echo", { module = "test.echo" }, "vanilla")
  end)
  Assert.throws(function()
    behaviors:registerRuleset("test:standard", { key = "test:other" }, "vanilla")
  end)

  -- Same keys stay separable across kinds.
  behaviors:registerMove("test:shared", { module = "test.shared_move", version = 1 }, "vanilla")
  behaviors:registerEffect("test:shared", { module = "test.shared_effect", version = 1 }, "vanilla")
  local bound = behaviors:freeze()
  Assert.equal(bound:get("moves", "test:shared").module, "test.shared_move")
  Assert.equal(bound:get("effects", "test:shared").module, "test.shared_effect")
end

function T.registering_after_freeze_fails_while_freeze_stays_idempotent()
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration has no owner"
  )

  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerMove("test:tackle", { module = "test.tackle", version = 1 }, "vanilla")
  local first = behaviors:freeze()
  local second = behaviors:freeze()
  Assert.equal(second:get("moves", "test:tackle").module, first:get("moves", "test:tackle").module)
  Assert.throws(function()
    behaviors:registerMove("test:late", { module = "test.late", version = 1 }, "late")
  end)
  Assert.throws(function()
    first:get("moves", "missing")
  end)
end

function T.unknown_rulesets_and_pairs_fail_without_a_neutral_fallback()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered type definitions have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed ruleset registration has no owner"
  )
  local BattleContent = requireContract(
    "libs.battle.src.BattleContent",
    "frozen executable battle bindings have no owner"
  )

  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  defineChartTypes(builder, nil, "vanilla")
  behaviors:registerRuleset("test:standard", { key = "test:standard", chart = "test:standard" }, "vanilla")
  local resolved = builder:freeze()
  local content = BattleContent.new(resolved, behaviors:freeze())

  Assert.throws(function()
    content:typeChart("test:missing")
  end)
  Assert.throws(function()
    content:ruleset("test:missing")
  end)
  local chart = content:typeChart("test:standard")
  Assert.throws(function()
    chart:effectiveness("missing", "fire")
  end)
  Assert.throws(function()
    chart:effectiveness("fire", "missing")
  end)

  -- Effectiveness answers are fresh values, never shared mutable state.
  local seen = chart:effectiveness("fire", "water")
  seen.numerator = 99
  assertRational(chart:effectiveness("fire", "water"), 1, 2)

  -- A ruleset naming a chart outside the composition fails at chart build.
  local stray = BattleBehaviorBuilder.new()
  stray:registerRuleset("test:stray", { key = "test:stray", chart = "test:elsewhere" }, "vanilla")
  local strayContent = BattleContent.new(resolved, stray:freeze())
  Assert.throws(function()
    strayContent:typeChart("test:stray")
  end)
end

---@param overrides table<string, unknown>?
---@return table<string, unknown>
local function customMoveRecord(overrides)
  local record = {
    key = "OVERDRIVE",
    name = "Overdrive",
    description = "Unleashes everything.",
    moveType = "fire",
    category = "special",
    power = 300,
    basePp = 80,
    accuracy = 150,
    priority = 200,
    target = "selected",
    flags = { contact = true },
    behavior = { key = "test:overdrive" },
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

function T.custom_move_numbers_beyond_native_limits_compose_without_clamping()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered move definitions have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration has no owner"
  )
  local BattleContent = requireContract(
    "libs.battle.src.BattleContent",
    "frozen executable battle bindings have no owner"
  )

  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerMove("test:overdrive", { module = "test.overdrive", version = 1 }, "mod")
  builder:define("moves", "OVERDRIVE", customMoveRecord(), "mod")
  -- A native-range move in the same composition keeps its exact values.
  builder:define("moves", "TACKLE", {
    key = "TACKLE",
    name = "Tackle",
    description = "Charges the foe.",
    moveType = "normal",
    category = "physical",
    power = 35,
    basePp = 35,
    accuracy = 95,
    priority = 0,
    target = "selected",
    flags = { contact = true },
    behavior = { key = "test:overdrive" },
  }, "vanilla")
  local resolved = builder:freeze()

  -- The resolved record carries the composed numbers unchanged: no native
  -- clamp is applied at composition.
  local seen = resolved:get("moves", "OVERDRIVE")
  Assert.equal(seen.power, 300)
  Assert.equal(seen.basePp, 80)
  Assert.equal(seen.accuracy, 150)
  Assert.equal(seen.priority, 200)
  local native = resolved:get("moves", "TACKLE")
  Assert.equal(native.power, 35)
  Assert.equal(native.basePp, 35)
  Assert.equal(native.accuracy, 95)
  Assert.equal(native.priority, 0)

  -- The composed behavior reference binds, so the move runs through the
  -- test behavior instead of failing composition.
  local content = BattleContent.new(resolved, behaviors:freeze())
  Assert.equal(content:behavior("moves", "test:overdrive").module, "test.overdrive")

  -- Non-finite, fractional, and negative numbers stay invalid where the
  -- composed record requires an integer count.
  local cases = {
    customMoveRecord({ key = "NAN_POWER", power = 0 / 0 }),
    customMoveRecord({ key = "INF_ACCURACY", accuracy = math.huge }),
    customMoveRecord({ key = "FRACTION_PP", basePp = 80.5 }),
    customMoveRecord({ key = "NEGATIVE_POWER", power = -1 }),
    customMoveRecord({ key = "NEGATIVE_PP", basePp = -1 }),
  }
  for _, record in ipairs(cases) do
    local bad = ContentBuilder.new()
    bad:define("moves", record.key, record, "mod")
    Assert.throws(function()
      bad:freeze()
    end, "invalid move number must fail composition")
  end
end

function T.composition_entrypoint_builds_an_isolated_bundle()
  requireContract(
    "libs.content.src.ContentBuilder",
    "ordered type definitions have no composition owner"
  )
  local Battle = require("gen4.battle")
  Assert.equal(Battle.API_VERSION, 1)

  local function install(builder, behaviors)
    defineChartTypes(builder, nil, "vanilla")
    behaviors:registerRuleset("test:standard", { key = "test:standard", chart = "test:standard" }, "vanilla")
  end
  local resolved, bound, content =
    Battle.compose({ { owner = "vanilla", revision = "1", install = install } })
  assertRational(content:typeChart("test:standard"):effectiveness("water", "fire"), 2, 1)
  Assert.equal(bound:get("rulesets", "test:standard").chart, "test:standard")
  Assert.isTrue(resolved:provenance("types", "fire").owner == "vanilla")

  -- A contributor without an installer fails before publishing anything.
  Assert.throws(function()
    Battle.compose({ { owner = "broken", revision = "1" } })
  end)

  -- The application composition root wires native catalogs to the same
  -- frozen bundle shape.
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local HgssBattleContent = require("game.hgss.src.battle.HgssBattleContent")
  local bundle = HgssBattleContent.build({
    monRoot = CatalogFixture.buildAssetRoot(),
    itemRoot = ItemFixture.buildAssetRoot(),
    contributors = { { owner = "vanilla", revision = "1", install = install } },
  })
  Assert.equal(bundle.mons:species("CHIKORITA").nativeId, 152)
  Assert.equal(bundle.items:item("POKE_BALL").nativeId, 4)
  assertRational(bundle.content:typeChart("test:standard"):effectiveness("fire", "water"), 1, 2)
  Assert.throws(function()
    HgssBattleContent.build({ monRoot = CatalogFixture.buildAssetRoot() })
  end)
end

function T.unbound_behavior_references_fail_at_bind_time_without_publishing()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed behavior registration has no owner"
  )
  local BattleContent = requireContract(
    "libs.battle.src.BattleContent",
    "frozen executable battle bindings have no owner"
  )

  local cases = {
    {
      kind = "moves",
      key = "TACKLE",
      record = {
        key = "TACKLE",
        name = "Tackle",
        description = "Charges the foe.",
        moveType = "normal",
        category = "physical",
        power = 35,
        basePp = 35,
        accuracy = 95,
        priority = 0,
        target = "selected",
        flags = { contact = true },
        behavior = { key = "test:missing-move" },
      },
      missing = "test:missing-move",
    },
    {
      kind = "effects",
      key = "TEST_EFFECT",
      record = { key = "TEST_EFFECT", behavior = { key = "test:missing-effect" } },
      missing = "test:missing-effect",
    },
    {
      kind = "actions",
      key = "TEST_ACTION",
      record = { key = "TEST_ACTION", behavior = { key = "test:missing-action" } },
      missing = "test:missing-action",
    },
  }
  for _, case in ipairs(cases) do
    local builder = ContentBuilder.new()
    local behaviors = BattleBehaviorBuilder.new()
    builder:define(case.kind, case.key, case.record, "vanilla")
    local resolved = builder:freeze()
    local bound = behaviors:freeze()
    local err = Assert.throws(function()
      BattleContent.new(resolved, bound)
    end, "dangling " .. case.kind .. " behavior reference must fail at bind time")
    local text = diagnosticText(err)
    Assert.isTrue(
      text:find(case.missing, 1, true) ~= nil,
      "bind failure names the missing behavior key " .. case.missing
    )
    Assert.isTrue(
      text:find(case.key, 1, true) ~= nil,
      "bind failure names the referring " .. case.kind .. " " .. case.key
    )
  end
end

return { tests = T }
