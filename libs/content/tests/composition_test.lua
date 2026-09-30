-- Ordered content composition: declared contributor order wins, provenance
-- names the owning contributor, aliases resolve before lookup, and invalid
-- composition fails without publishing a candidate.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

---@param module string
---@param behavior string
---@return table
local function requireContract(module, behavior)
  local ok, loaded = pcall(require, module)
  Assert.isTrue(ok, "missing composition contract " .. module .. ": " .. behavior)
  assert(loaded ~= nil, "the composition contract loads its module")
  return loaded --[[@as table]]
end

---@param overrides table<string, unknown>?
---@return table<string, unknown>
local function moveRecord(overrides)
  local record = {
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
    behavior = { key = "test:tackle" },
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

---@param builder table
---@param behaviors table
local function installVanilla(builder, behaviors)
  behaviors:registerMove("test:tackle", { module = "test.tackle", version = 1 }, "vanilla")
  builder:define("moves", "TACKLE", moveRecord(), "vanilla")
end

---@param err unknown
---@return string
local function diagnosticText(err)
  if Errors.is(err) then
    return Errors.format(err)
  end
  if type(err) == "table" and type(err.message) == "string" then
    return err.message
  end
  return tostring(err)
end

---@param builder table
---@param behaviors table
---@param installs table[]
---@return table
local function freezeOrdered(builder, behaviors, installs)
  for _, install in ipairs(installs) do
    install(builder, behaviors)
  end
  behaviors:freeze()
  return builder:freeze()
end

function T.declared_contribution_order_wins_with_owner_provenance()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed move behavior registration has no owner"
  )

  local function balance(builder)
    builder:patch("moves", "TACKLE", { { op = "set", path = { "power" }, value = 40 } }, "balance")
  end
  local function compat(builder)
    builder:patch("moves", "TACKLE", { { op = "set", path = { "power" }, value = 50 } }, "compat")
    builder:alias("moves", "OLD_TACKLE", "TACKLE", "compat")
  end

  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  local resolved = freezeOrdered(builder, behaviors, { installVanilla, balance, compat })

  Assert.equal(resolved:get("moves", "TACKLE").power, 50)
  Assert.equal(resolved:get("moves", "OLD_TACKLE").power, 50)
  Assert.equal(resolved:provenance("moves", "TACKLE").owner, "compat")

  -- The same contributors in a different declared order select deterministically.
  local reordered = ContentBuilder.new()
  local reorderedBehaviors = BattleBehaviorBuilder.new()
  local rerun = freezeOrdered(reordered, reorderedBehaviors, { installVanilla, compat, balance })
  Assert.equal(rerun:get("moves", "TACKLE").power, 40)
  Assert.equal(rerun:provenance("moves", "TACKLE").owner, "balance")
end

function T.invalid_composition_fails_without_publishing()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed move behavior registration has no owner"
  )

  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  local resolved = freezeOrdered(builder, behaviors, {
    installVanilla,
    function(build)
      build:patch("moves", "TACKLE", { { op = "set", path = { "power" }, value = 50 } }, "compat")
    end,
  })
  Assert.equal(resolved:get("moves", "TACKLE").power, 50)

  -- A duplicate definition names both owners and publishes nothing new.
  local duplicate = Assert.throws(function()
    builder:define("moves", "TACKLE", moveRecord(), "second-owner")
  end)
  local duplicateText = diagnosticText(duplicate)
  Assert.isTrue(duplicateText:find("vanilla", 1, true) ~= nil, "conflict names the first owner")
  Assert.isTrue(duplicateText:find("second-owner", 1, true) ~= nil, "conflict names the second owner")

  -- A patch names a missing identity instead of creating one.
  Assert.throws(function()
    builder:patch("moves", "MISSING", { { op = "set", path = { "power" }, value = 1 } }, "balance")
  end)

  -- An alias cycle fails at declaration or at freeze.
  local cyclic = ContentBuilder.new()
  cyclic:define("moves", "TACKLE", moveRecord(), "vanilla")
  cyclic:alias("moves", "OLD_TACKLE", "TACKLE", "compat")
  Assert.throws(function()
    cyclic:alias("moves", "TACKLE", "OLD_TACKLE", "compat")
    cyclic:freeze()
  end)

  -- Callers cannot mutate the frozen composition through a getter view.
  local seen = resolved:get("moves", "TACKLE")
  seen.power = 999
  Assert.equal(resolved:get("moves", "TACKLE").power, 50)
end

function T.patch_operation_shape_rejection_leaves_builder_unchanged()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed move behavior registration has no owner"
  )

  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  installVanilla(builder, behaviors)

  Assert.throws(function()
    builder:patch("moves", "TACKLE", { { op = "merge", path = { "power" }, value = 1 } }, "balance")
  end)
  Assert.throws(function()
    builder:patch("moves", "TACKLE", { { op = "set", path = {}, value = 1 } }, "balance")
  end)
  Assert.throws(function()
    builder:patch("moves", "TACKLE", { { op = "set", path = { "power" } } }, "balance")
  end)
  Assert.throws(function()
    builder:patch("moves", "TACKLE", { { op = "remove", path = { "power" }, value = 1 } }, "balance")
  end)

  -- A well-shaped operation with a missing target path records cleanly and
  -- fails at freeze instead.
  local deep = ContentBuilder.new()
  deep:define("moves", "TACKLE", moveRecord(), "vanilla")
  deep:patch("moves", "TACKLE", { { op = "remove", path = { "power", "deep" } } }, "balance")
  Assert.throws(function()
    deep:freeze()
  end)

  -- None of the rejected operations recorded a patch: the composed value
  -- is still the defined one.
  behaviors:freeze()
  local resolved = builder:freeze()
  Assert.equal(resolved:get("moves", "TACKLE").power, 35)
  Assert.equal(resolved:provenance("moves", "TACKLE").owner, "vanilla")
end

function T.remove_operation_deletes_a_field_and_replaces_arrays_whole()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )

  local builder = ContentBuilder.new()
  builder:define("flavor", "STEW", { text = "warming", extra = 1, list = { 1, 2 } }, "vanilla")
  builder:patch("flavor", "STEW", {
    { op = "remove", path = { "extra" } },
    { op = "set", path = { "list" }, value = { 3 } },
    { op = "set", path = { "nested", "deep" }, value = true },
  }, "seasoning")
  local resolved = builder:freeze()
  local seen = resolved:get("flavor", "STEW")
  Assert.equal(seen.text, "warming")
  Assert.isNil(seen.extra)
  Assert.deepEqual(seen.list, { 3 })
  Assert.isTrue(seen.nested.deep)
  Assert.equal(resolved:provenance("flavor", "STEW").owner, "seasoning")
end

function T.alias_chain_resolves_and_missing_destinations_fail_at_freeze()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )

  local builder = ContentBuilder.new()
  builder:define("moves", "TACKLE", moveRecord(), "vanilla")
  builder:alias("moves", "MID_TACKLE", "TACKLE", "compat")
  builder:alias("moves", "OLD_TACKLE", "MID_TACKLE", "compat")
  builder:patch("moves", "OLD_TACKLE", { { op = "set", path = { "power" }, value = 60 } }, "balance")
  local resolved = builder:freeze()
  Assert.equal(resolved:get("moves", "OLD_TACKLE").power, 60)
  Assert.equal(resolved:provenance("moves", "OLD_TACKLE").owner, "balance")

  -- A dangling destination fails at freeze, not at declaration.
  local dangling = ContentBuilder.new()
  dangling:define("moves", "TACKLE", moveRecord(), "vanilla")
  dangling:alias("moves", "GHOST", "NOWHERE", "compat")
  Assert.throws(function()
    dangling:freeze()
  end)
end

function T.failed_freeze_publishes_nothing_and_leaves_the_builder_usable()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )

  local builder = ContentBuilder.new()
  builder:define("moves", "TACKLE", moveRecord(), "vanilla")
  builder:patch("moves", "TACKLE", { { op = "set", path = { "power" }, value = 999 } }, "balance")
  Assert.throws(function()
    builder:freeze()
  end)
  -- The failed freeze locked nothing and changed no provenance: fixing the
  -- patch value produces a valid snapshot with the corrected owner.
  builder:patch("moves", "TACKLE", { { op = "set", path = { "power" }, value = 50 } }, "compat")
  local resolved = builder:freeze()
  Assert.equal(resolved:get("moves", "TACKLE").power, 50)
  Assert.equal(resolved:provenance("moves", "TACKLE").owner, "compat")
end

function T.freeze_is_idempotent_and_locks_the_builder()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed move behavior registration has no owner"
  )

  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  installVanilla(builder, behaviors)
  behaviors:freeze()
  local first = builder:freeze()
  local second = builder:freeze()
  Assert.equal(second:get("moves", "TACKLE").power, first:get("moves", "TACKLE").power)

  Assert.throws(function()
    builder:define("moves", "STRUGGLE", moveRecord({ key = "STRUGGLE" }), "late")
  end)
  Assert.throws(function()
    builder:patch("moves", "TACKLE", { { op = "set", path = { "power" }, value = 1 } }, "late")
  end)
  Assert.throws(function()
    builder:alias("moves", "LATE", "TACKLE", "late")
  end)
  -- The earlier snapshot survives the rejected mutations.
  Assert.equal(first:get("moves", "TACKLE").power, 35)
end

function T.self_alias_and_alias_collisions_fail()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )

  local builder = ContentBuilder.new()
  builder:define("moves", "TACKLE", moveRecord(), "vanilla")
  Assert.throws(function()
    builder:alias("moves", "TACKLE", "TACKLE", "compat")
  end)
  builder:alias("moves", "OLD_TACKLE", "TACKLE", "compat")
  local conflict = Assert.throws(function()
    builder:define("moves", "OLD_TACKLE", moveRecord({ key = "OLD_TACKLE" }), "second-owner")
  end)
  local conflictText = diagnosticText(conflict)
  Assert.isTrue(conflictText:find("compat", 1, true) ~= nil, "conflict names the alias owner")
  Assert.isTrue(conflictText:find("second-owner", 1, true) ~= nil, "conflict names the second owner")
  local repeated = Assert.throws(function()
    builder:alias("moves", "OLD_TACKLE", "TACKLE", "third-owner")
  end)
  local repeatedText = diagnosticText(repeated)
  Assert.isTrue(repeatedText:find("compat", 1, true) ~= nil, "conflict names the first alias owner")
  Assert.isTrue(repeatedText:find("third-owner", 1, true) ~= nil, "conflict names the repeated owner")
end

function T.kinds_and_keys_list_defined_identities_in_stable_order()
  local ContentBuilder = requireContract(
    "libs.content.src.ContentBuilder",
    "ordered definitions, patches, and aliases have no composition owner"
  )
  local BattleBehaviorBuilder = requireContract(
    "libs.battle.src.BattleBehaviorBuilder",
    "typed move behavior registration has no owner"
  )

  local builder = ContentBuilder.new()
  local behaviors = BattleBehaviorBuilder.new()
  installVanilla(builder, behaviors)
  builder:define("moves", "STRUGGLE", moveRecord({ key = "STRUGGLE", name = "Struggle" }), "vanilla")
  builder:alias("moves", "OLD_TACKLE", "TACKLE", "compat")
  behaviors:freeze()
  local resolved = builder:freeze()
  Assert.deepEqual(resolved:kinds(), { "moves" })
  -- Alias names are resolution conveniences, not definitions.
  Assert.deepEqual(resolved:keys("moves"), { "STRUGGLE", "TACKLE" })
  Assert.throws(function()
    resolved:keys("missing")
  end)
end

return { tests = T }
